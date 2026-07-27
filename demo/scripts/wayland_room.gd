extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".

@onready var compositor: WlrCompositor = $WlrCompositor
@onready var launcher_menu = $Player/LauncherLayer/LauncherMenu
var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune
var interact_mode_active := false

var resizing_edge := "" # "left", "right", "top", "bottom", "topleft", etc.
var is_resizing := false
var is_moving := false
var active_window_id := -1
var is_in_window := false
# Déplacement: distance (caméra -> fenêtre) figée au moment du grab, la
# fenêtre suit ensuite le viseur le long de ce rayon.
var move_depth := 0.0

var is_moving_2d := false
var move_2d_plane := Plane()
var move_2d_offset := Vector3.ZERO

# Redimensionnement: même principe de rayon à profondeur fixe, mais on
# garde aussi la base locale du quad et ses dimensions de départ pour
# convertir le déplacement du viseur (unités monde) en pixels de surface.
var resize_depth := 0.0
var resize_start_world := Vector3.ZERO
var resize_right_dir := Vector3.RIGHT
var resize_up_dir := Vector3.UP
var window_start_size := Vector2.ZERO # taille geometry (px) au moment du grab
var window_start_mesh_size := Vector2.ONE # taille quad (unités monde) au moment du grab
var window_start_local_pos := Vector3.ZERO # position locale du quad au moment du grab
var window_start_content_offset := Vector2.ZERO # offset geometry dans la surface au moment du grab

const BORDER_MARGIN = 5 # en pixels sur la texture, zone de bord = redimensionnement
const CORNER_MARGIN = 20 # px, zone de coin (carrée, plus large que BORDER_MARGIN
						  # pour rester cliquable via raycast) = redimensionnement diagonal
const MIN_SURFACE_SIZE = 500 # px, garde-fou anti-fenêtre-écrasée

# Mode focus: affiche une fenêtre en 2D fullscreen avec input clavier+souris
var focus_mode := false
var focus_window_id := -1
var focus_texture_rect: TextureRect
var focus_surface_size := Vector2.ZERO
var focus_content_offset := Vector2.ZERO
var focus_content_size := Vector2.ZERO
var focus_mouse_captured := false
var focus_mouse_uv := Vector2(0.5, 0.5) # position tracking en mode capturé

const WAYLAND_SHADER_CODE = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled;

uniform sampler2D window_texture : filter_linear_mipmap;
uniform vec2 content_size = vec2(0.0, 0.0);

void fragment() {
    // Quand le buffer d'allocation (VkImage / texture) est plus grand que
    // le contenu réel (allocation arrondie au palier supérieur, ou surface
    // réduite sans réallocation), le UV doit être remappé pour n'échantil-
    // lonner que la zone de contenu. Sans ça, UV [0,1] couvre la totalité
    // de la texture (y compris la zone transparente/stale), déformant
    // l'image.
    vec2 ts = vec2(textureSize(window_texture, 0));
    vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
        ? UV * content_size / ts : UV;
    vec4 tex = texture(window_texture, mapped_uv);
    if (tex.a > 0.01) {
        vec3 unmultiplied = tex.rgb / max(tex.a, 0.001);
        ALBEDO = pow(unmultiplied, vec3(2.2));
        ALPHA = clamp(tex.a * 2.0, 0.0, 1.0);
    } else {
        discard;
    }
}
"""

func _ready() -> void:
	compositor.window_mapped.connect(_on_window_mapped)
	compositor.window_unmapped.connect(_on_window_unmapped)
	compositor.window_texture_updated.connect(_on_texture_updated)
	compositor.popup_mapped.connect(_on_popup_mapped)
	compositor.popup_unmapped.connect(_on_popup_unmapped)
	compositor.popup_texture_updated.connect(_on_popup_texture_updated)
	compositor.pointer_lock_changed.connect(_on_pointer_lock_changed)
	compositor.start_headless()
	compositor.launch_app("xwayland-satellite :1")
	await get_tree().create_timer(0.2).timeout
	compositor.set_x11_display(":1")
	launcher_menu.app_launch.connect(func(cmd): compositor.launch_app(cmd))

	# TextureRect plein écran pour le mode focus
	focus_texture_rect = TextureRect.new()
	focus_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	focus_texture_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	focus_texture_rect.visible = false
	focus_texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	$Player/UI.add_child(focus_texture_rect)

func spawn_test_client() -> void:
	compositor.launch_app("konsole")

func next_spawn_pos() -> Vector3:
	var camera := $Player/Camera3D
	return camera.global_position - camera.global_basis.z

func _enter_focus_mode(id: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	focus_mode = true
	focus_window_id = id
	focused_window_id = id
	focus_mouse_captured = false
	focus_mouse_uv = Vector2(0.5, 0.5)

	# Récupérer la texture courante depuis le shader
	var quad: MeshInstance3D = quads[id]
	var mat: ShaderMaterial = quad.material_override as ShaderMaterial
	var tex: Texture2D = mat.get_shader_parameter("window_texture")
	focus_texture_rect.texture = tex

	# Récupérer les métadonnées de taille
	var body: StaticBody3D = quad.get_child(0)
	focus_surface_size = body.get_meta("surface_size", Vector2(1, 1))
	focus_content_offset = body.get_meta("content_offset", Vector2.ZERO)
	focus_content_size = body.get_meta("content_size", focus_surface_size)

	# Cacher le quad 3D, afficher le overlay 2D
	quad.visible = false
	focus_texture_rect.visible = true

	# Libérer la souris pour interagir avec la fenêtre, centrée sur l'écran
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)

	# Bloquer le player
	$Player.focus_mode_active = true

func _exit_focus_mode() -> void:
	if not focus_mode:
		return

	# Réafficher le quad 3D
	if quads.has(focus_window_id) and is_instance_valid(quads[focus_window_id]):
		quads[focus_window_id].visible = true

	# Cacher le overlay, libérer la texture
	focus_texture_rect.visible = false
	focus_texture_rect.texture = null
	focus_mode = false
	focus_window_id = -1
	focus_mouse_captured = false

	# Restaurer la souris capturée
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Débloquer le player
	$Player.focus_mode_active = false

func _handle_focus_input() -> void:

	# Souris capturée: maintenir le pointer focus + forward relatif via _input
	if focus_mouse_captured:
		# Maintenir le pointer focus sur la surface (nécessaire pour que
		# wlr_relative_pointer_manager_v1_send_relative_motion livre les events)
		var surf_x := focus_mouse_uv.x * focus_surface_size.x + focus_content_offset.x
		var surf_y := focus_mouse_uv.y * focus_surface_size.y + focus_content_offset.y
		compositor.forward_pointer_motion(focus_window_id, surf_x, surf_y)
	else:
		# Souris visible: position absolue, curseur custom suit la souris
		var viewport_size := get_viewport().get_visible_rect().size
		var mouse_pos := get_viewport().get_mouse_position()
		var tex_size := focus_surface_size
		if tex_size.x <= 0 or tex_size.y <= 0:
			tex_size = viewport_size
		var scale := minf(viewport_size.x / tex_size.x, viewport_size.y / tex_size.y)
		var displayed_size := tex_size * scale
		var offset := (viewport_size - displayed_size) / 2.0
		var local_pos := mouse_pos - offset
		focus_mouse_uv = Vector2(
			clampf(local_pos.x / displayed_size.x, 0.0, 1.0),
			clampf(local_pos.y / displayed_size.y, 0.0, 1.0)
		)
		# Déplacer le curseur custom à la position souris
		var surf_x := focus_mouse_uv.x * focus_surface_size.x + focus_content_offset.x
		var surf_y := focus_mouse_uv.y * focus_surface_size.y + focus_content_offset.y
		compositor.forward_pointer_motion(focus_window_id, surf_x, surf_y)

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button(focus_window_id, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(focus_window_id, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		compositor.forward_pointer_button(focus_window_id, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(focus_window_id, 0x111, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(focus_window_id, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(focus_window_id, 0, 50.0)

func _on_pointer_lock_changed(window_id: int, locked: bool) -> void:
	# Un jeu a demandé le pointer lock (zwp_pointer_constraints_v1::lock_pointer)
	if not focus_mode or window_id != focus_window_id:
		return
	if locked:
		focus_mouse_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		focus_mouse_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)

func _on_window_mapped(id: int, _title: String, _app_id: String) -> void:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.6, 1.0) # ratio ajusté au premier texture_updated
	quad.mesh = mesh

	var shader := Shader.new()
	shader.code = WAYLAND_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 0
	quad.material_override = mat

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.05)
	col.shape = shape
	body.add_child(col)
	body.set_meta("window_id", id)
	quad.add_child(body)

	add_child(quad)
	quads[id] = quad
	quad.global_position = next_spawn_pos()
	var camera := $Player/Camera3D

	quad.global_transform = Transform3D(
		camera.global_transform.basis,
		quad.global_position
	)
	
	#print("Fenêtre mappée: ", title, " (", app_id, ") id=", id)

func _on_window_unmapped(id: int) -> void:
	if focus_mode and focus_window_id == id:
		_exit_focus_mode()
	if focused_window_id == id:
		focused_window_id = -1
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			quad.queue_free()
		quads.erase(id)

func _on_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	# Mettre à jour le overlay 2D en mode focus
	if focus_mode and id == focus_window_id:
		focus_texture_rect.texture = texture
		focus_surface_size = Vector2(width, height)
		var geo := compositor.get_window_geometry(id)
		focus_content_offset = Vector2(geo["x"], geo["y"])
		focus_content_size = Vector2(geo["width"], geo["height"])
		return

	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	# Toujours mettre à jour la texture du shader : le pipeline Vulkan peut
	# avoir créé un nouveau VkImage/Texture2DRD si la taille a changé, et
	# l'ancien a été libéré. Ne pas mettre à jour laissait le shader
	# échantillonner un VkImage libéré → tearing/corruption GPU.
	(quad.material_override as ShaderMaterial).set_shader_parameter("window_texture", texture)
	# content_size = taille réelle du contenu (w × h). Le shader s'en
	# sert pour remapper UV quand le buffer d'allocation est plus grand
	# (round_up_capture_size) — sans ça, le contenu serait comprimé
	# dans le coin supérieur-gauche du mesh.
	(quad.material_override as ShaderMaterial).set_shader_parameter("content_size", Vector2(width, height))

	# Toujours synchroniser les métadonnées (surface_size, content_offset,
	# content_size) même pendant un resize : le calcul UV pour le forwarding
	# des événements pointeur utilise surface_size, et les détections de
	# bord utilisent content_size/content_offset. Sans ça, les UV sont
	# wrong dès que le client commite la nouvelle taille.
	var body: StaticBody3D = quad.get_child(0)
	body.set_meta("surface_size", Vector2(width, height))
	var geo := compositor.get_window_geometry(id)
	body.set_meta("content_offset", Vector2(geo["x"], geo["y"]))
	body.set_meta("content_size", Vector2(geo["width"], geo["height"]))

	# Pendant un redimensionnement actif, _update_resize contrôle la taille
	# du mesh, la position du quad et la CollisionShape3D. Ne pas écraser
	# ces valeurs ici : la texture capturée est probablement encore à
	# l'ancienne taille (le client n'a pas encore committé le buffer à la
	# nouvelle taille), donc recalculer le mesh sur sa base causerait un
	# flickering entre l'aspect cible et l'aspect stale à chaque frame.
	if is_resizing and active_window_id == id:
		return

	# Garde le ratio d'aspect réel de la fenêtre. Utilise la hauteur
	# courante du mesh (pas un hardcoded 3.0) pour éviter un saut de
	# taille après un resize où la hauteur a été interpolée.
	var aspect := float(width) / float(max(height, 1))
	var mesh: QuadMesh = quad.mesh
	var current_h: float = mesh.size.y if mesh.size.y > 0.0 else 3.0
	mesh.size = Vector2(current_h * aspect, current_h)

	# La CollisionShape3D doit suivre la même taille que le mesh, sinon le
	# raycast teste une zone qui ne correspond plus à ce qui est affiché.
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

func _on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	var parent_quad: MeshInstance3D = null
	var parent_px_size := Vector2(1, 1)

	if parent_popup_id != -1 and popup_quads.has(parent_popup_id) and is_instance_valid(popup_quads[parent_popup_id]):
		# Sous-menu: parenté sur le popup qui l'a ouvert, pas sur la fenêtre racine.
		parent_quad = popup_quads[parent_popup_id]
		parent_px_size = parent_quad.get_meta("surface_size", Vector2(1, 1))
	elif quads.has(parent_window_id) and is_instance_valid(quads[parent_window_id]):
		parent_quad = quads[parent_window_id]
		var parent_body: StaticBody3D = parent_quad.get_child(0)
		parent_px_size = parent_body.get_meta("surface_size", Vector2(1, 1))

	if parent_quad == null:
		return

	var parent_mesh: QuadMesh = parent_quad.mesh

	# Conversion pixels -> mètres, en réutilisant l'échelle déjà connue du
	# parent immédiat (mêmes unités que sa propre capture de texture).
	var _scale := Vector2(
		parent_mesh.size.x / max(parent_px_size.x, 1.0),
		parent_mesh.size.y / max(parent_px_size.y, 1.0)
	)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(max(width * _scale.x, 0.01), max(height * _scale.y, 0.01))
	quad.mesh = mesh
	# Mémorisé pour qu'un éventuel sous-sous-menu puisse recalculer son
	# échelle à partir de CE popup plutôt que de la fenêtre racine, et pour
	# que _on_popup_texture_updated puisse redimensionner le mesh sur la
	# même base quand le buffer réel (potentiellement plus grand que la
	# géométrie logique ci-dessus) arrive.
	quad.set_meta("surface_size", Vector2(width, height))
	quad.set_meta("px_scale", _scale)

	# (x, y) = coin haut-gauche du popup relatif au coin haut-gauche de la
	# géométrie du parent immédiat. Le quad parent est centré sur son
	# origine locale, d'où le décalage de -size/2 pour repartir du vrai
	# coin haut-gauche.
	var local_left := -parent_mesh.size.x / 2.0 + x * _scale.x
	var local_top := parent_mesh.size.y / 2.0 - y * _scale.y
	quad.position = Vector3(
		local_left + mesh.size.x / 2.0,
		local_top - mesh.size.y / 2.0,
		0.02 # léger décalage devant le parent pour éviter le z-fighting
	)

	var shader := Shader.new()
	shader.code = WAYLAND_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 1 # Force l'affichage au-dessus des fenêtres
	quad.material_override = mat

	# Les tooltips ont une région d'input vide: on les affiche mais on ne
	# crée pas de collision body, pour que le raycast passe au travers et
	# atteigne la fenêtre/le popup en dessous.
	if compositor.popup_accepts_input(id):
		var body := StaticBody3D.new()
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(mesh.size.x, mesh.size.y, 0.05)
		col.shape = shape
		body.add_child(col)
		body.set_meta("popup_id", id)
		body.set_meta("surface_size", Vector2(width, height))
		quad.add_child(body)
	else:
		quad.set_meta("tooltip", true)

	parent_quad.add_child(quad)
	popup_quads[id] = quad

func _on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)

func _on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not popup_quads.has(id) or not is_instance_valid(popup_quads[id]):
		return
	var quad: MeshInstance3D = popup_quads[id]
	(quad.material_override as ShaderMaterial).set_shader_parameter("window_texture", texture)

	# popup_mapped donne la géométrie logique (xdg_surface.set_window_geometry),
	# utilisée uniquement pour le placement relatif au parent. Le buffer
	# réellement capturé ici peut être plus grand (marge d'ombre ajoutée par
	# le client, GTK/Qt notamment) - sans cette resynchronisation, le hover
	# convertissait les uv avec l'échelle de la géométrie logique au lieu de
	# celle du buffer affiché, envoyant des coordonnées fausses au client.
	var mesh: QuadMesh = quad.mesh
	var old_size := mesh.size
	var aspect := float(width) / float(max(height, 1))
	mesh.size = Vector2(old_size.y * aspect, old_size.y) if old_size.y > 0.0 else Vector2(1, 1)

	quad.set_meta("surface_size", Vector2(width, height)) # utilisé par un éventuel sous-menu

	# Les tooltips n'ont pas de collision body (pas d'input region).
	if quad.get_child_count() > 0:
		var body: StaticBody3D = quad.get_child(0)
		body.set_meta("surface_size", Vector2(width, height))
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

# La fenêtre glisse le long de son propre plan d'orientation initial.
func _update_move_2d(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
		
	var quad: MeshInstance3D = quads[active_window_id]
	var hit = move_2d_plane.intersects_ray(ray_origin, ray_dir)
	
	if hit != null:
		var target_pos = hit + move_2d_offset
		# Déplacement fluide uniquement sur les axes X/Y locaux du plan
		quad.global_position = quad.global_position.lerp(target_pos, 15.0 * delta)

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("launcher") and not interact_mode_active and not launcher_menu.visible and not focus_mode:
		launcher_menu.toggle_menu()

	if launcher_menu.visible:
		return

	# Mode focus: F pour sortir, sinon router les inputs souris/clavier
	if focus_mode:
		#if Input.is_action_just_pressed("focus_window"):
			#_exit_focus_mode()
			#return
		_handle_focus_input()
		return

	# F en visant une fenêtre → entrer en mode focus
	if Input.is_action_just_pressed("focus_window") and not interact_mode_active:
		var cam := $Player/Camera3D
		var mouse_pos := get_viewport().get_mouse_position()
		var ray_origin = cam.project_ray_origin(mouse_pos)
		var ray_dir = cam.project_ray_normal(mouse_pos)
		var to = ray_origin + ray_dir * 1000.0
		var space := get_world_3d().direct_space_state
		var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
		var hit := space.intersect_ray(params)
		if not hit.is_empty():
			var body: Node3D = hit.collider
			if body.has_meta("window_id"):
				_enter_focus_mode(body.get_meta("window_id"))
				return

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	if Input.is_action_just_pressed("interact_mode"):
		interact_mode_active = not interact_mode_active
		$Player.interact_mode_active = not $Player.interact_mode_active

	var cam: Camera3D = $Player/Camera3D
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := cam.project_ray_origin(mouse_pos)
	var ray_dir := cam.project_ray_normal(mouse_pos)

	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if is_moving:
		if Input.is_action_just_pressed("scroll_up"):
			move_depth += 0.25
		if Input.is_action_just_pressed("scroll_down"):
			move_depth -= 0.25
		_update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab"):
			is_moving = false
			active_window_id = -1
		return
	if is_resizing:
		_update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click"):
			is_resizing = false
			resizing_edge = ""
			active_window_id = -1
		return
	if is_moving_2d:
		_update_move_2d(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("left_click"):
			is_moving_2d = false
			active_window_id = -1
		return
	
	var to := ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	var hit := space.intersect_ray(params)

	if hit.is_empty():
		is_in_window = false
		compositor.forward_pointer_leave()
		return

	var body: Node3D = hit.collider

	if body.has_meta("popup_id"):
		is_in_window = true
		_handle_popup_pointer(body, hit)
		return

	if not body.has_meta("window_id"):
		is_in_window = false
		compositor.forward_pointer_leave()
		return
	else:
		is_in_window = true
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh

	var local := quad.to_local(hit.position)
	var uv := Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)
	var wid: int = body.get_meta("window_id")
	# La texture est découpée à la window_geometry, donc UV * surface_size
	# donne des coordonnées dans le repère geometry. Le client Wayland
	# attend des coordonnées dans le repère surface (incluant les ombres),
	# d'où l'ajout de content_offset.
	var content_offset_fwd: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	compositor.forward_pointer_motion(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y)

	if Input.is_action_just_pressed("grab") and not interact_mode_active:
		active_window_id = wid
		is_moving = true
		move_depth = cam.global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab"):
		active_window_id = wid
		is_moving = false
		move_depth = 0.0
	if Input.is_action_just_pressed("left_click"):
		focused_window_id = wid
		var edge := _border_edge(uv, win_size, body)
		# UV * win_size donne directement les coordonnées dans le repère
		# contenu (la texture est découpée à la geometry), donc la zone
		# de barre de titre est relative au bord visible du contenu.
		var content_offset: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
		var content_size: Vector2 = body.get_meta("content_size", win_size)
		if content_size.x <= 0 or content_size.y <= 0:
			content_offset = Vector2.ZERO
			content_size = win_size
		var titlebar_px := uv.x * win_size.x
		var titlebar_py := uv.y * win_size.y
		var in_titlebar := titlebar_py >= 0 and titlebar_py < BORDER_MARGIN * BORDER_MARGIN \
			and titlebar_px > 75 and titlebar_px < content_size.x - 75

		if edge != "":
			# Bord de la fenêtre -> redimensionnement.
			active_window_id = wid
			resizing_edge = edge
			is_resizing = true
			resize_depth = cam.global_position.distance_to(quad.global_position)
			resize_start_world = ray_origin + ray_dir * resize_depth
			resize_right_dir = quad.global_transform.basis.x.normalized()
			resize_up_dir = quad.global_transform.basis.y.normalized()
			window_start_size = win_size
			window_start_content_offset = content_offset
			window_start_mesh_size = mesh.size
			window_start_local_pos = quad.position

		elif in_titlebar:
			# Move on a 2D plane (simulation de barre de titre)
			active_window_id = wid
			is_moving_2d = true
			
			# On crée un plan infini basé sur l'orientation de la fenêtre (axe Z)
			var normal = quad.global_transform.basis.z.normalized()
			move_2d_plane = Plane(normal, quad.global_position)
			
			# Calcul de l'offset initial pour éviter que la fenêtre "saute" au centre du curseur
			var _hit = move_2d_plane.intersects_ray(ray_origin, ray_dir)
			if _hit != null:
				move_2d_offset = quad.global_position - _hit
		
		else:
			compositor.forward_pointer_button(wid, 0x110, true) # BTN_LEFT (evdev)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(wid, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(wid, 0, 50.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh

	var local := quad.to_local(hit.position)
	var uv := Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)
	var pid: int = body.get_meta("popup_id")
	compositor.forward_pointer_motion_popup(pid, uv.x * win_size.x, uv.y * win_size.y)

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button_popup(pid, 0x110, false)

# Bord touché (marge en pixels de texture) -> "" si le clic est dans le
# corps de la fenêtre.
func _border_edge(uv: Vector2, win_size: Vector2, body: StaticBody3D) -> String:
	# Récupère la géométrie de contenu (sans ombres CSD). Si le client n'a
	# pas défini de géométrie (par ex. application SSD), on retombe sur la
	# taille complète de la surface.
	var _content_offset: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	var content_size: Vector2 = body.get_meta("content_size", win_size)
	if content_size.x <= 0 or content_size.y <= 0:
		_content_offset = Vector2.ZERO
		content_size = win_size
	# Convertit les coordonnées UV en pixels de contenu. La texture est
	# découpée à la window_geometry, donc UV * win_size donne directement
	# les coordonnées dans le repère contenu (pas besoin de soustraire
	# content_offset). BORDER_MARGIN est relatif au bord visible du contenu.
	var px := uv.x * win_size.x
	var py := uv.y * win_size.y

	# Coins du bas: zone carrée large (CORNER_MARGIN), facile à viser via
	# raycast - aucun risque de conflit, pas de boutons de fenêtre en bas.
	var near_bottom_wide := py > content_size.y - CORNER_MARGIN
	var near_left_wide := px < CORNER_MARGIN
	var near_right_wide := px > content_size.x - CORNER_MARGIN
	if near_bottom_wide and near_left_wide:
		return "bottomleft"
	if near_bottom_wide and near_right_wide:
		return "bottomright"

	# Coins du haut: zone fine (BORDER_MARGIN), volontairement petite pour ne
	# pas voler les clics destinés aux boutons fermer/réduire/agrandir, qui
	# vivent dans cette même région (voir zone reservée 75px plus bas dans
	# le handler de clic).
	var near_top := py < BORDER_MARGIN
	var near_left := px < BORDER_MARGIN
	var near_right := px > content_size.x - BORDER_MARGIN
	if near_top and near_left:
		return "topleft"
	if near_top and near_right:
		return "topright"

	# Bords simples: bande fine (BORDER_MARGIN), hors des zones de coin.
	var edge := ""
	if py < BORDER_MARGIN:
		edge += "top"
	elif py > content_size.y - BORDER_MARGIN:
		edge += "bottom"
	if px < BORDER_MARGIN:
		edge += "left"
	elif px > content_size.x - BORDER_MARGIN:
		edge += "right"
	return edge

# La fenêtre suit le viseur le long du rayon caméra, à profondeur figée
# (distance capturée au moment du grab) - fonctionne même si la souris ne
# se déplace jamais à l'écran (mode capturé), puisque seule l'orientation
# de la caméra entre ici en jeu.
func _update_move(ray_origin: Vector3, ray_dir: Vector3, delta: float) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var cam: Camera3D = $Player/Camera3D
	var target_pos = ray_origin + ray_dir * move_depth
	# Déplacement fluide
	quad.global_position = quad.global_position.lerp(
		target_pos,
		10.0 * delta
	)
	# Rotation
	quad.global_basis = cam.global_basis

func _update_resize(ray_origin: Vector3, ray_dir: Vector3) -> void:
	if active_window_id == -1 or not quads.has(active_window_id):
		return
	var quad: MeshInstance3D = quads[active_window_id]
	var mesh: QuadMesh = quad.mesh

	# Delta du viseur (unités monde) projeté sur la même profondeur figée
	# qu'au moment du grab, puis exprimé dans la base locale du quad.
	var cur_world := ray_origin + ray_dir * resize_depth
	var world_delta := cur_world - resize_start_world
	var local_dx := world_delta.dot(resize_right_dir)
	var local_dy := world_delta.dot(resize_up_dir)

	# Ratio pixels de surface / unité monde, figé au grab (le mesh ne
	# change pas de taille pendant le drag, seul window_texture_updated
	# le fera une fois le client redessiné à la nouvelle taille).
	var px_per_unit_x: float = window_start_size.x / max(window_start_mesh_size.x, 0.001)
	var px_per_unit_y: float = window_start_size.y / max(window_start_mesh_size.y, 0.001)

	var new_w := window_start_size.x
	var new_h := window_start_size.y
	if "right" in resizing_edge:
		new_w = window_start_size.x + local_dx * px_per_unit_x
	elif "left" in resizing_edge:
		new_w = window_start_size.x - local_dx * px_per_unit_x
	if "top" in resizing_edge:
		new_h = window_start_size.y + local_dy * px_per_unit_y
	elif "bottom" in resizing_edge:
		new_h = window_start_size.y - local_dy * px_per_unit_y

	new_w = max(new_w, MIN_SURFACE_SIZE)
	new_h = max(new_h, MIN_SURFACE_SIZE)

	# set_window_size envoie les dimensions de la SURFACE (buffer) au client
	# Wayland, pas la geometry. Les ombres CSD sont typiquement symétriques,
	# donc surface = geometry + 2 * content_offset.
	var surface_w := int(new_w) + int(window_start_content_offset.x) * 2
	var surface_h := int(new_h) + int(window_start_content_offset.y) * 2
	compositor.set_window_size(active_window_id, surface_w, surface_h)

	# Met à jour la taille du mesh ET la position en même temps pour que
	# le bord fixe reste immobile pendant le drag. Sans cette mise à jour,
	# seul le position changeait → le bord "fixe" dérivait car le mesh
	# gardait l'ancienne taille (causant le tearing visible pendant le
	# resize).
	var new_mesh_w: float = window_start_mesh_size.x * (new_w / max(window_start_size.x, 1.0))
	var new_mesh_h: float = window_start_mesh_size.y * (new_h / max(window_start_size.y, 1.0))
	mesh.size = Vector2(new_mesh_w, new_mesh_h)

	# La CollisionShape3D doit suivre la même taille que le mesh.
	var body: StaticBody3D = quad.get_child(0)
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(new_mesh_w, new_mesh_h, shape.size.z)

	# Repositionne le bord fixe: le shift compense exactement la moitié
	# du delta taille, de sorte que le bord opposé ne bouge pas.
	var delta_w_world: float = (new_mesh_w - window_start_mesh_size.x) / 2.0
	var delta_h_world: float = (new_mesh_h - window_start_mesh_size.y) / 2.0
	var shift := Vector3.ZERO
	if "left" in resizing_edge:
		shift -= resize_right_dir * delta_w_world
	elif "right" in resizing_edge:
		shift += resize_right_dir * delta_w_world
	if "top" in resizing_edge:
		shift += resize_up_dir * delta_h_world
	elif "bottom" in resizing_edge:
		shift -= resize_up_dir * delta_h_world
	quad.position = window_start_local_pos + shift

func _input(event: InputEvent) -> void:
	# En mode focus, forward le clavier et tracker la souris capturée
	if focus_mode and focus_window_id != -1:
		if event is InputEventKey:
			var key_event := event as InputEventKey
			var code = key_event.physical_keycode
			if code == 0:
				code = key_event.keycode
			if key_event.unicode == 60 or code == 167:
				code = KEY_LESS
			elif key_event.unicode == 62:
				code = KEY_GREATER
			compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
			get_viewport().set_input_as_handled()
		elif focus_mouse_captured and event is InputEventMouseMotion:
			# Tracker la position UV + forward le mouvement relatif au client
			var viewport_size := get_viewport().get_visible_rect().size
			var tex_size := focus_surface_size
			if tex_size.x <= 0 or tex_size.y <= 0:
				tex_size = viewport_size
			var scale := minf(viewport_size.x / tex_size.x, viewport_size.y / tex_size.y)
			var displayed_size := tex_size * scale
			focus_mouse_uv.x += event.relative.x / displayed_size.x
			focus_mouse_uv.y += event.relative.y / displayed_size.y
			focus_mouse_uv.x = clampf(focus_mouse_uv.x, 0.0, 1.0)
			focus_mouse_uv.y = clampf(focus_mouse_uv.y, 0.0, 1.0)
			compositor.forward_pointer_relative_motion(
				focus_window_id,
				event.relative.x, event.relative.y,
				event.relative.x, event.relative.y)
		return

	if focused_window_id == -1 or not interact_mode_active:
		return
	
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code = key_event.physical_keycode
		if code == 0:
			code = key_event.keycode
			
		# Correction spécifique pour les chevrons sur clavier AZERTY / ISO
		if key_event.unicode == 60 or code == 167: # '<' ou touche bizarre associée
			code = KEY_LESS
		elif key_event.unicode == 62: # '>'
			code = KEY_GREATER # ou KEY_LESS selon le mapping evdev si '>' partage la même touche physique avec Shift
		
		compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
		get_viewport().set_input_as_handled()
