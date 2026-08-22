extends Node3D
## Quads 3D des fenêtres Wayland mappées et de leurs popups, plus toute la
## logique de pointage raycast : hover, clic, grab, déplacement et
## redimensionnement depuis la caméra du joueur.
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

signal window_created(window_id: int, quad: MeshInstance3D)
# Émis quand l'ensemble des fenêtres locales change (map/unmap, hide/show,
# taille, fin de déplacement/redimensionnement, plein écran) : le LAN s'en
# sert pour resynchroniser les quads noirs des autres joueurs.
signal windows_state_changed

const BORDER_MARGIN = 5 # en pixels sur la texture, zone de bord = redimensionnement
const CORNER_MARGIN = 20 # px, zone de coin (carrée, plus large que BORDER_MARGIN
						 # pour rester cliquable via raycast) = redimensionnement diagonal
const MIN_SURFACE_SIZE = 500 # px, garde-fou anti-fenêtre-écrasée
# Multiplicateur de taille des quads en unités monde : agrandit l'affichage
# 3D des fenêtres sans toucher à la résolution de l'image (les pixels par
# unité monde sont divisés d'autant, l'échantillonnage reste le même).
const WINDOW_QUAD_SCALE := 2.0

# Barre de titre du jeu (décorations server-side). Le compositeur répond
# SERVER_SIDE à xdg-decoration-v1 : les clients (dont xwayland-satellite,
# qui crashe si on lui laisse dessiner ses barres) ne dessinent rien, c'est
# le jeu qui affiche la barre au-dessus du contenu de chaque fenêtre.
const TITLEBAR_HEIGHT = 0.06
const TITLEBAR_BG = Color(0.13, 0.15, 0.22)
const TITLEBAR_FG = Color(0.85, 0.88, 0.96)
# Boutons de la barre de titre (droite) : fermer / réduire / agrandir.
const TITLEBAR_BTN_CLOSE := Color(0.9, 0.25, 0.25)
const TITLEBAR_BTN_MIN := Color(0.95, 0.7, 0.2)
const TITLEBAR_BTN_MAX := Color(0.3, 0.78, 0.42)
const TITLEBAR_BUTTON_SIZE_RATIO := 0.55 # taille d'un bouton = 55% de la hauteur de barre
const TITLEBAR_BUTTON_GAP_RATIO := 0.22 # espace entre boutons = 22% de la hauteur de barre
# Épaisseur (m) du BoxOccluder3D plaqué sur chaque quad fenêtre : assez fine
# pour rester proche du plan visuel, assez épaisse pour être rasterisée
# proprement par l'occlusion culling.
const WINDOW_OCCLUDER_DEPTH := 0.04
const TITLEBAR_BUTTON_MARGIN_RATIO := 0.35 # marge du bord droit de la barre

# Position de spawn des nouvelles fenêtres : toujours 1 m devant la caméra,
# mais décalée de STACK_Z_OFFSET derrière la précédente pour chaque fenêtre
# déjà présente à cet endroit, pour que deux fenêtres ouvertes coup sur coup
# ne s'empilent pas au même endroit. Même empilement qu'à la sortie du mode
# focus (voir focus_mode.gd).
const STACK_Z_OFFSET := 0.1 # m entre deux fenêtres empilées
const SPAWN_STACK_RADIUS := 0.5 # m, portée de détection des fenêtres déjà empilées au point de spawn

const WAYLAND_SHADER_CODE = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_always;

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

var compositor: WlrCompositor
var player: Node3D

var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var window_textures: Dictionary = {} # window_id (int) -> Texture2D
var window_titles: Dictionary = {} # window_id (int) -> String
var window_shared: Dictionary = {} # window_id (int) -> bool (visible par les autres joueurs)
var _texture_versions: Dictionary = {} # window_id (int) -> int (version du contenu, pour le LAN)
var fullscreen_windows: Dictionary = {} # window_id (int) -> bool (plein écran)
var popup_parent_info: Dictionary = {} # popup_id -> {parent_window_id, parent_popup_id, x, y, width, height}

# Shader UNIQUE partagé par toutes les fenêtres/popups. Le créer une seule
# fois évite à Godot de recompiler le shader à chaque ouverture de fenêtre
# (compile synchrone sur le thread principal au premier dessin → gros stall /
# chute de FPS perceptible). Le ShaderMaterial reste propre à chaque quad
# (uniformes window_texture/content_size), seule la ressource Shader est
# partagée.
var _shared_window_shader: Shader = null

var focused_window_id := -1 # fenêtre qui reçoit le clavier après un clic, -1 = aucune

var resizing_edge := "" # "left", "right", "bottom", etc.
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

var pre_fullscreen_mesh_sizes: Dictionary = {} # wid (int) -> Vector2
var pre_fullscreen_surface_sizes: Dictionary = {} # wid (int) -> Vector2

func setup(compositor_ref: WlrCompositor, player_ref: Node3D) -> void:
	compositor = compositor_ref
	player = player_ref

func _camera() -> Camera3D:
	return player.get_node("Camera3D") as Camera3D

func _window_shader() -> Shader:
	if _shared_window_shader == null:
		_shared_window_shader = Shader.new()
		_shared_window_shader.code = WAYLAND_SHADER_CODE
	return _shared_window_shader

func next_spawn_pos() -> Vector3:
	var camera: Camera3D = _camera()
	var cam_pos: Vector3 = camera.global_position
	var cam_forward: Vector3 = -camera.global_basis.z
	# Position de base : 2 m devant la caméra.
	var base_pos := cam_pos + cam_forward * 2.0
	# Compter les fenêtres visibles déjà à cet endroit : chaque fenêtre dans
	# le rayon SPAWN_STACK_RADIUS du point de spawn décale la nouvelle de
	# STACK_Z_OFFSET derrière la précédente.
	var offset := 0.0
	for wid in quads:
		var quad: MeshInstance3D = quads[wid]
		if not is_instance_valid(quad) or not quad.visible:
			continue
		if quad.global_position.distance_to(base_pos) < SPAWN_STACK_RADIUS:
			offset += STACK_Z_OFFSET
	return base_pos - cam_forward * offset

func get_window_texture(wid: int) -> Texture2D:
	return window_textures.get(wid, null)

# État des fenêtres locales pour le partage LAN (quads des autres joueurs) :
# une entrée par fenêtre (partagée OU non), en coordonnées MONDE (le quad vit
# sous Windows3D, à l'identité de la room, pas dans le repère du niveau).
# « shared » vaut false → le quad distant reste noir (placeholder) ;
# « shared » vaut true → le contenu réel est streamé (voir get_window_image).
func get_windows_state() -> Array:
	var list: Array = []
	for wid in quads:
		var quad: MeshInstance3D = quads[wid]
		if not is_instance_valid(quad):
			continue
		var size := Vector2.ONE
		if quad.mesh is QuadMesh:
			size = (quad.mesh as QuadMesh).size
		list.append({
			"wid": wid,
			"transform": quad.global_transform,
			"size": size,
			"visible": quad.visible,
			"shared": window_shared.get(wid, false),
			"pid": compositor.get_window_pid(wid) if compositor != null else -1,
		})
	return list

# Image CPU actuelle d'une fenêtre, pour le stream « partage » vers les autres
# joueurs. Renvoie null si la fenêtre n'a pas encore de contenu.
# Deux chemins possibles côté compositeur :
#  - fallback CPU → ImageTexture : get_image() est direct ;
#  - chemin Vulkan zero-copy → Texture2DRD : get_image() renvoie null, on lit
#    alors l'image CPU que le compositeur a produite de façon synchrone à la
#    capture (get_window_cpu_image) — le readback RD différé lisait parfois un
#    buffer réutilisé (contenu de la scène au lieu de la fenêtre).
func get_window_image(wid: int) -> Image:
	var tex: Texture2D = window_textures.get(wid)
	if tex == null or not is_instance_valid(tex):
		return null
	if tex is Texture2DRD:
		# Chemin Vulkan zero-copy : l'affichage in-game échantillonne le
		# VkImage (correct), mais tex.get_image() ferait un readback RD
		# DIFFÉRÉ (texture_get_data exécuté plus tard sur le thread de rendu)
		# qui peut lire un buffer réutilisé → contenu de la scène au lieu de
		# la fenêtre. On lit donc la copie CPU faite de façon SYNCHRONE à la
		# capture (get_window_cpu_image), juste après le render pass et la
		# synchro DMA-BUF : elle ne peut pas être « tardive ».
		if compositor != null and compositor.has_method("get_window_cpu_image"):
			var cimg: Image = compositor.get_window_cpu_image(wid)
			if cimg != null and not cimg.is_empty():
				if not _debug_share_path.has(wid):
					_debug_share_path[wid] = "cpu_image"
					print("[share] ", wid, " path=cpu_image ", cimg.get_width(), "x", cimg.get_height())
				return cimg
			if not _debug_share_path.has(wid):
				_debug_share_path[wid] = "cpu_image_null"
				print("[share] ", wid, " path=cpu_image NULL (texte ", tex.get_class(), ")")
		return null
	var img := tex.get_image()
	if img != null and not img.is_empty():
		if not _debug_share_path.has(wid):
			_debug_share_path[wid] = "image_texture"
			print("[share] ", wid, " path=image_texture ", tex.get_width(), "x", tex.get_height(),
				" title=", _window_title(wid), " app=", _window_app_id(wid))
		return img
	return null

var _debug_share_path := {}

func _window_title(wid: int) -> String:
	if compositor == null or not compositor.has_method("get_window_list"):
		return ""
	for entry in compositor.get_window_list():
		if int(entry.get("id", -1)) == wid:
			return str(entry.get("title", ""))
	return ""

func _window_app_id(wid: int) -> String:
	if compositor == null or not compositor.has_method("get_window_list"):
		return ""
	for entry in compositor.get_window_list():
		if int(entry.get("id", -1)) == wid:
			return str(entry.get("app_id", ""))
	return ""

# Version du contenu d'une fenêtre (incrémentée à chaque capture). Le LAN ne
# stream une frame que si la version a changé, pour ne pas ré-encoder une
# fenêtre statique à chaque tick.
func get_window_texture_version(wid: int) -> int:
	return int(_texture_versions.get(wid, 0))

# Active/désactive la visibilité d'une fenêtre pour les autres joueurs
# (partage « screenshare » : aucun contrôle distant, juste l'affichage).
func set_window_shared(wid: int, shared: bool) -> void:
	window_shared[wid] = shared
	windows_state_changed.emit()

func is_window_shared(wid: int) -> bool:
	return window_shared.get(wid, false)

# Vrai si le joueur local déplace ou redimensionne une fenêtre : pendant
# ce temps le LAN envoie l'état des fenêtres à haute fréquence.
func is_window_interacting() -> bool:
	return is_moving or is_resizing or is_moving_2d

# Infos nécessaires au mode focus pour basculer la fenêtre en overlay 2D.
func get_quad_info(id: int) -> Dictionary:
	var info := {}
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return info
	var quad: MeshInstance3D = quads[id]
	var mat := quad.material_override as ShaderMaterial
	info["texture"] = mat.get_shader_parameter("window_texture") if mat else null
	var body: StaticBody3D = quad.get_child(0)
	info["surface_size"] = body.get_meta("surface_size", Vector2(1, 1))
	info["content_offset"] = body.get_meta("content_offset", Vector2.ZERO)
	info["content_size"] = body.get_meta("content_size", Vector2(1, 1))
	return info

func set_quad_visible(id: int, visible: bool) -> void:
	if quads.has(id) and is_instance_valid(quads[id]):
		var quad: MeshInstance3D = quads[id]
		quad.visible = visible
		_set_quad_interactive(quad, visible)

# Active/désactive toutes les collisions d'un quad (corps du contenu, barre
# de titre, boutons) : un quad invisible ne doit plus être touchable.
func _set_quad_interactive(quad: MeshInstance3D, enabled: bool) -> void:
	for child in quad.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D:
					shape_node.disabled = not enabled
		elif child is MeshInstance3D:
			_set_quad_interactive(child, enabled)

# La fenêtre actuellement déplacée (grab menu), -1 si aucune.
func get_grabbed_window_id() -> int:
	return active_window_id if is_moving else -1

func is_window_grabbed(wid: int) -> bool:
	return is_moving and active_window_id == wid

func release_window_grab(wid: int) -> void:
	if not is_window_grabbed(wid):
		return
	is_moving = false
	active_window_id = -1
	windows_state_changed.emit()

# Toggle grab depuis le menu fenêtres : reprend une fenêtre déjà en cours de
# déplacement (is_moving) ou lâche la prise et la pose à sa position actuelle.
func toggle_grab_window(wid: int) -> void:
	if is_window_grabbed(wid):
		release_window_grab(wid)
		return
	if not quads.has(wid) or not is_instance_valid(quads[wid]):
		return
	var quad: MeshInstance3D = quads[wid]
	var cam := _camera()
	active_window_id = wid
	is_moving = true
	move_depth = cam.global_position.distance_to(quad.global_position)
	windows_state_changed.emit()

func toggle_hide(id: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var quad: MeshInstance3D = quads[id]
	quad.visible = not quad.visible
	_set_quad_interactive(quad, quad.visible)
	windows_state_changed.emit()

func on_window_mapped(id: int, title: String, _app_id: String) -> void:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.6, 1.0) * WINDOW_QUAD_SCALE # ratio ajusté au premier texture_updated
	quad.mesh = mesh

	var shader := _window_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 0
	quad.material_override = mat
	# Surface plane qui projette une ombre : acné d'ombrage/aliasing au bord
	# (l'ombre "scintille" au sol/mur autour de la fenêtre). Une surface
	# d'app n'a pas vocation à jeter une ombre dure : on la désactive.
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var body := StaticBody3D.new()
	
	body.collision_layer = 2
	body.collision_mask = 2
	
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# Épaisseur fine : la face avant du boîtier reste proche du plan visuel
	# du quad, sinon le raycast renvoie un point décalé en incidence rasant.
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.01)
	col.shape = shape
	body.add_child(col)
	body.set_meta("window_id", id)
	quad.add_child(body)

	# Occlusion culling : boîte fine alignée sur le quad. Enfant du quad →
	# suit grab/déplacement/rotation sans code par frame, et se désactive
	# automatiquement quand la fenêtre est cachée (hide/minimise/focus).
	# La dimension est tenue à jour par _sync_titlebar(), appelée après
	# chaque changement de taille du mesh.
	var occ := OccluderInstance3D.new()
	occ.name = "Occluder"
	var occ_box := BoxOccluder3D.new()
	occ_box.size = Vector3(mesh.size.x, mesh.size.y, WINDOW_OCCLUDER_DEPTH)
	occ.occluder = occ_box
	quad.add_child(occ)

	# Barre de titre du jeu (SSD) : quad coloré + Label3D posés AU-DESSUS du
	# contenu (ne recouvre jamais le contenu de l'app). Ajoutée APRÈS body
	# pour que quad.get_child(0) continue de renvoyer le corps du contenu.
	window_titles[id] = title
	var titlebar := MeshInstance3D.new()
	titlebar.name = "Titlebar"
	# Visible seulement si le client a accepté des décorations gérées par le
	# jeu (SERVER_SIDE) : le signal window_decorations_changed suit le map.
	titlebar.visible = false
	titlebar.mesh = QuadMesh.new() # dimensionné par _sync_titlebar
	var bar_mat := StandardMaterial3D.new()
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bar_mat.albedo_color = TITLEBAR_BG
	bar_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	titlebar.material_override = bar_mat
	titlebar.set_meta("titlebar_of", id)
	titlebar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bar_body := StaticBody3D.new()
	bar_body.name = "BarBody"
	bar_body.collision_layer = 2
	bar_body.collision_mask = 2
	var bar_col := CollisionShape3D.new()
	var bar_shape := BoxShape3D.new()
	bar_shape.size = Vector3(mesh.size.x, TITLEBAR_HEIGHT, 0.02)
	bar_col.shape = bar_shape
	bar_body.add_child(bar_col)
	bar_body.set_meta("titlebar_of", id)
	titlebar.add_child(bar_body)
	_make_titlebar_button(titlebar, id, "minimize", TITLEBAR_BTN_MIN)
	_make_titlebar_button(titlebar, id, "maximize", TITLEBAR_BTN_MAX)
	_make_titlebar_button(titlebar, id, "close", TITLEBAR_BTN_CLOSE)
	var bar_label := Label3D.new()
	bar_label.name = "Label3D"
	bar_label.text = title
	bar_label.double_sided = true
	bar_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	bar_label.font_size = 6
	bar_label.outline_size = 0
	bar_label.modulate = TITLEBAR_FG
	bar_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar_label.position = Vector3(0.0, 0.0, 0.001)
	titlebar.add_child(bar_label)
	bar_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.add_child(titlebar)
	_sync_titlebar(quad)

	add_child(quad)
	quads[id] = quad
	window_shared[id] = false
	quad.global_position = next_spawn_pos()
	var camera := _camera()

	quad.global_transform = Transform3D(
		camera.global_transform.basis,
		quad.global_position
	)

	window_created.emit(id, quad)
	windows_state_changed.emit()

# Le client peut changer son titre à tout moment (xdg-shell set_title) :
# met à jour l'étiquette de la barre de titre du jeu.
func on_window_title_changed(id: int, title: String) -> void:
	window_titles[id] = title
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	var bar_label: Label3D = quads[id].get_node_or_null("Titlebar/Label3D")
	if bar_label != null:
		bar_label.text = title
	windows_state_changed.emit()

# Recalcule la barre de titre après un changement de taille du contenu : la
# barre reste collée au bord supérieur du contenu et suit sa largeur.
func _sync_titlebar(quad: MeshInstance3D) -> void:
	var titlebar: MeshInstance3D = quad.get_node_or_null("Titlebar")
	if titlebar == null or not is_instance_valid(titlebar):
		return
	var mesh: QuadMesh = quad.mesh
	var bar_h: float = TITLEBAR_HEIGHT
	var bar_mesh: QuadMesh = titlebar.mesh
	if bar_mesh == null:
		bar_mesh = QuadMesh.new()
		titlebar.mesh = bar_mesh
	bar_mesh.size = Vector2(mesh.size.x, bar_h)
	titlebar.position = Vector3(0.0, mesh.size.y * 0.5 + bar_h * 0.5, 0.0)
	var bar_body: StaticBody3D = titlebar.get_node("BarBody")
	var bar_shape: BoxShape3D = bar_body.get_child(0).shape
	bar_shape.size = Vector3(mesh.size.x, bar_h, 0.02)

	# L'occludeur suit la taille du contenu (appelé après chaque resize,
	# ratio du premier frame inclus).
	var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
	if occ != null and occ.occluder is BoxOccluder3D:
		(occ.occluder as BoxOccluder3D).size = Vector3(
			mesh.size.x, mesh.size.y, WINDOW_OCCLUDER_DEPTH)

	# Boutons alignés à droite : maximiser, réduire, fermer (de gauche à droite).
	var btn_size := bar_h * TITLEBAR_BUTTON_SIZE_RATIO
	var gap := bar_h * TITLEBAR_BUTTON_GAP_RATIO
	var x := mesh.size.x * 0.5 - bar_h * TITLEBAR_BUTTON_MARGIN_RATIO - btn_size * 0.5
	for btn_name in ["BtnClose", "BtnMaximize", "BtnMinimize"]:
		var btn: StaticBody3D = titlebar.get_node_or_null(btn_name)
		if btn != null:
			btn.position = Vector3(x, 0.0, 0.001)
			var btn_col: CollisionShape3D = btn.get_child(0)
			(btn_col.shape as BoxShape3D).size = Vector3(btn_size, btn_size, 0.03)
			var visual: MeshInstance3D = btn.get_child(1)
			(visual.mesh as QuadMesh).size = Vector2(btn_size, btn_size)
		x -= btn_size + gap

# Crée un bouton carré de la barre de titre (StaticBody3D + collision +
# mesh coloré). Le clic est géré via la meta "titlebar_button".
func _make_titlebar_button(titlebar: MeshInstance3D, wid: int, action: String, color: Color) -> void:
	var btn := StaticBody3D.new()
	btn.name = "Btn" + action.capitalize()
	btn.collision_layer = 2
	btn.collision_mask = 2
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.05, 0.05, 0.03)
	col.shape = shape
	btn.add_child(col)
	var visual := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	visual.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	visual.material_override = mat
	visual.position = Vector3(0.0, 0.0, 0.001)
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	btn.add_child(visual)
	btn.set_meta("titlebar_button", {"wid": wid, "action": action})
	titlebar.add_child(btn)

# Active/désactive les collisions des éléments de la barre de titre
# (BarBody de drag + boutons) quand la décoration est masquée.
func _set_titlebar_interactive(titlebar: MeshInstance3D, enabled: bool) -> void:
	for child in titlebar.get_children():
		if child is StaticBody3D:
			for shape_node in child.get_children():
				if shape_node is CollisionShape3D:
					shape_node.disabled = not enabled

# Montre/cache les boutons minimiser/maximiser/fermer de la barre de titre.
func _set_titlebar_buttons(titlebar: MeshInstance3D, enabled: bool) -> void:
	for btn_name in ["BtnClose", "BtnMaximize", "BtnMinimize"]:
		var btn := titlebar.get_node_or_null(btn_name) as StaticBody3D
		if btn == null:
			continue
		btn.visible = enabled
		for shape_node in btn.get_children():
			if shape_node is CollisionShape3D:
				shape_node.disabled = not enabled

# Montre/cache la barre de titre du jeu selon la décoration : SERVER_SIDE =>
# le compositeur gère la décoration (le jeu la dessine, boutons inclus) ;
# sinon le client dessine la sienne (CSD, ex. Firefox) : on affiche quand
# même la barre du jeu (titre + zone de drag) mais SANS les boutons, car le
# client a déjà ses propres boutons dans son contenu.
func on_window_decorations_changed(id: int, server_side: bool) -> void:
	if not quads.has(id):
		return
	var quad: MeshInstance3D = quads[id]
	var titlebar: MeshInstance3D = quad.get_node_or_null("Titlebar")
	if titlebar == null:
		return
	titlebar.visible = true
	_set_titlebar_interactive(titlebar, true)
	_set_titlebar_buttons(titlebar, server_side)

func on_window_unmapped(id: int) -> void:
	if focused_window_id == id:
		focused_window_id = -1
	window_textures.erase(id)
	window_shared.erase(id)
	_texture_versions.erase(id)
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			quad.queue_free()
		quads.erase(id)
	windows_state_changed.emit()

func on_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	# Tracker la texture pour le menu de navigation
	window_textures[id] = texture
	# Version du contenu : incrémentée à chaque nouvelle capture, utilisée par
	# le LAN pour n'envoyer une frame que quand la fenêtre a réellement changé.
	_texture_versions[id] = _texture_versions.get(id, 0) + 1

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
	# Fenêtre fraîche (jamais redimensionnée à la main) : on dimensionne le
	# quad d'après sa taille naturelle en pixels, la hauteur du viewport
	# servant de référence (viewport_height px -> 1.0 unité monde). Sans ça,
	# une fenêtre de 300 px de haut s'ouvrirait aussi grande qu'une fenêtre
	# plein écran. Dès que le joueur a redimensionné la fenêtre (user_sized),
	# la taille monde choisie est conservée, seule l'aspect suit le client.
	if not body.get_meta("user_sized", false):
		var vh: float = get_viewport().get_visible_rect().size.y
		if vh > 0.0:
			current_h = float(height) / vh
		current_h = max(current_h, 0.05)
		# WINDOW_QUAD_SCALE s'applique uniquement à la hauteur calculée
		# depuis les pixels. Pour une fenêtre user_sized, current_h est
		# déjà une hauteur monde échelonnée (mesh.size.y) : la re-multiplier
		# doublerait la fenêtre à chaque texture_updated → croissance infinie.
		current_h *= WINDOW_QUAD_SCALE
	mesh.size = Vector2(current_h * aspect, current_h)

	# La CollisionShape3D doit suivre la même taille que le mesh, sinon le
	# raycast teste une zone qui ne correspond plus à ce qui est affiché.
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
	_sync_titlebar(quad)
	windows_state_changed.emit()

func on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
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
	print("popup_layout: id=", id, " x=", x, " y=", y, " w=", width, " h=", height,
		" scale=", _scale, " quad_pos=", quad.position, " mesh_size=", mesh.size)

	var shader := _window_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.render_priority = 1 # Force l'affichage au-dessus des fenêtres
	quad.material_override = mat
	# Idem fenêtres : pas d'ombre (surface plate) pour éviter le scintillement.
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Les tooltips ont une région d'input vide: on les affiche mais on ne
	# crée pas de collision body, pour que le raycast passe au travers et
	# atteigne la fenêtre/le popup en dessous. Attention: Firefox committe
	# parfois l'input region dans le MÊME commit que le buffer (hamburger
	# menu) - au moment de popup_mapped elle est encore vide, donc on
	# re-vérifiera dans _on_popup_texture_updated quand le buffer arrive.
	if compositor.popup_accepts_input(id):
		_add_popup_collider(quad, id, width, height)
	else:
		quad.set_meta("tooltip", true)

	parent_quad.add_child(quad)
	popup_quads[id] = quad

	# Stocker les infos parent pour le mode focus
	popup_parent_info[id] = {
		"parent_window_id": parent_window_id,
		"parent_popup_id": parent_popup_id,
		"x": x, "y": y, "width": width, "height": height
	}

# Crée le collider du popup (raycast → hover/clic vers le client).
func _add_popup_collider(quad: MeshInstance3D, id: int, width: int, height: int) -> void:
	if quad.get_child_count() > 0:
		return
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3((quad.mesh as QuadMesh).size.x, (quad.mesh as QuadMesh).size.y, 0.01)
	col.shape = shape
	body.add_child(col)
	body.set_meta("popup_id", id)
	body.set_meta("surface_size", Vector2(width, height))
	quad.add_child(body)

func on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)
	popup_parent_info.erase(id)

func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not popup_quads.has(id) or not is_instance_valid(popup_quads[id]):
		return
	var quad: MeshInstance3D = popup_quads[id]
	(quad.material_override as ShaderMaterial).set_shader_parameter("window_texture", texture)
	(quad.material_override as ShaderMaterial).set_shader_parameter("content_size", Vector2(width, height))
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

	# Les tooltips n'ont pas de collision body (pas d'input region). Si le
	# popup a été marqué tooltip au map mais que l'input region a été
	# committée avec le buffer (Firefox hamburger menu), on crée le collider
	# tardivement ici. Sinon on resynchronise sa taille sur le buffer.
	if quad.get_child_count() == 0 and quad.has_meta("tooltip") and compositor.popup_accepts_input(id):
		_add_popup_collider(quad, id, width, height)
		quad.remove_meta("tooltip")
		print("popup_collider_late: id=", id, " w=", width, " h=", height)
	elif quad.get_child_count() > 0:
		var body: StaticBody3D = quad.get_child(0)
		body.set_meta("surface_size", Vector2(width, height))
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)

# Pointage raycast principal, appelé à chaque frame par wayland_room.gd.
# Gère hover/clic/scroll vers les fenêtres et popups, ainsi que les grabs
# de déplacement (G) et de redimensionnement (bords/coins).
func process_raycast(ray_origin: Vector3, ray_dir: Vector3, delta: float, interact_active: bool) -> void:
	# Efface le pointeur wayland de toutes les fenêtres : il n'est re-posé
	# que si le raycast atteint une fenêtre ci-dessous. Les branches de
	# retour (drag, raycast dans le vide) laissent ainsi les captures de
	# fenêtre OBS sans curseur.
	compositor.set_window_pointer(-1, 0, 0, false)
	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if is_moving:
		if Input.is_action_just_pressed("scroll_up", false):
			move_depth += 0.25
		if Input.is_action_just_pressed("scroll_down", false):
			move_depth -= 0.25
		_update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab", true):
			is_moving = false
			active_window_id = -1
			windows_state_changed.emit()
		return
	if is_resizing:
		_update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click", false):
			is_resizing = false
			resizing_edge = ""
			active_window_id = -1
			windows_state_changed.emit()
		return
	if is_moving_2d:
		_update_move_2d(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("left_click", false):
			is_moving_2d = false
			active_window_id = -1
			windows_state_changed.emit()
		return

	var to := ray_origin + ray_dir * 1000.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
	var hit := space.intersect_ray(params)

	if hit.is_empty():
		is_in_window = false
		compositor.forward_pointer_leave()
		# Relâchement du clic dans le vide (ex: drop d'un drag-and-drop hors
		# de toute fenêtre) : window_id=-1 -> le compositeur route quand même
		# l'événement au seat et annule un drag actif le cas échéant.
		if Input.is_action_just_released("left_click", false):
			compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			compositor.forward_pointer_button(-1, 0x111, false)
		return

	var body: Node3D = hit.collider

	if body.has_meta("popup_id"):
		is_in_window = true
		_handle_popup_pointer(body, hit, ray_origin, ray_dir)
		return

	if body.has_meta("titlebar_button"):
		# Clic sur un bouton de la barre de titre : fermer/réduire/agrandir.
		# Pas de forward du pointeur vers l'app (ce n'est pas du contenu).
		is_in_window = true
		_handle_titlebar_button(body)
		return

	if body.has_meta("titlebar_of"):
		# Clic sur la barre de titre du jeu : on déplace la fenêtre, on ne
		# forward rien à l'app (la barre n'est pas du contenu applicatif).
		is_in_window = true
		_handle_titlebar(body, ray_origin, ray_dir)
		return

	if not body.has_meta("window_id"):
		is_in_window = false
		compositor.forward_pointer_leave()
		# Idem : relâchement sur un collider sans fenêtre (mur, sol, etc.)
		# doit pouvoir annuler un drag-and-drop en cours.
		if Input.is_action_just_released("left_click", false):
			compositor.forward_pointer_button(-1, 0x110, false)
		if Input.is_action_just_released("right_click", false):
			compositor.forward_pointer_button(-1, 0x111, false)
		return
	else:
		is_in_window = true
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh
	
	# Le point de contact du raycast est sur la FACE AVANT du boîtier de
	# collision (0.05 m d'épaisseur), pas sur le plan visuel du quad (z=0).
	# En incidence rasant — fenêtre proche, regard levé vers la barre de
	# titre — la face avant est décalée du plan visuel de ~0.025·tan(angle):
	# à 60° ça fait ~3 cm ≈ 20+ px trop bas, de quoi rater la croix et
	# cliquer le bouton juste en dessous. On réintersecte donc le rayon
	# avec le plan exact du quad.
	var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
	var wid: int = body.get_meta("window_id")
	# La texture est découpée à la window_geometry, donc UV * surface_size
	# donne des coordonnées dans le repère geometry. Le client Wayland
	# attend des coordonnées dans le repère surface (incluant les ombres),
	# d'où l'ajout de content_offset.
	var content_offset_fwd: Vector2 = body.get_meta("content_offset", Vector2.ZERO)
	if not popup_quads.is_empty():
		print("raycast: WINDOW wid=", wid, " uv=", uv, " px=",
			uv.x * win_size.x + content_offset_fwd.x, " py=",
			uv.y * win_size.y + content_offset_fwd.y,
			" content_offset=", content_offset_fwd, " surf_size=", win_size)
	compositor.forward_pointer_motion(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y)
	# Position du pointeur dans la fenêtre (coordonnées surface, y vers le
	# bas) : servira à composer le curseur dans la capture fenêtre OBS quand
	# la source a coché « afficher le curseur ».
	compositor.set_window_pointer(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y, true)

	if Input.is_action_just_pressed("grab", true) and not interact_active:
		active_window_id = wid
		is_moving = true
		move_depth = _camera().global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab", true):
		active_window_id = wid
		is_moving = false
		move_depth = 0.0
	if Input.is_action_just_pressed("left_click", false):
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
		# La zone de drag "virtuelle" (haut du contenu) n'est utile que si la
		# barre 3D n'est pas affichée. Depuis qu'elle l'est toujours (SSD et
		# CSD), on la désactive : sinon le haut du contenu (ex. les onglets
		# de Firefox en CSD) déclencherait un drag au lieu de cliquer l'app.
		var titlebar3d: MeshInstance3D = quad.get_node_or_null("Titlebar")
		var no_3d_titlebar := titlebar3d == null or not titlebar3d.visible
		var in_titlebar := no_3d_titlebar and titlebar_py >= 0 and titlebar_py < (win_size.y * TITLEBAR_HEIGHT) \
			and titlebar_px > 75 and titlebar_px < content_size.x - 75

		if edge != "":
			# Bord de la fenêtre -> redimensionnement.
			active_window_id = wid
			resizing_edge = edge
			is_resizing = true
			resize_depth = _camera().global_position.distance_to(quad.global_position)
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
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click", false):
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up", false):
		compositor.forward_pointer_axis(wid, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down", false):
		compositor.forward_pointer_axis(wid, 0, 100.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var mesh: QuadMesh = quad.mesh
	var pid: int = body.get_meta("popup_id")
	var info: Dictionary = popup_parent_info.get(pid, {})
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))

	var px: float
	var py: float
	if info.get("parent_popup_id", -1) == -1 and quads.has(info.get("parent_window_id", -1)):
		# Popup directement parenté à une fenêtre : les coordonnées envoyées
		# au client doivent être celles du plan de la FENÊTRE, pas du plan 3D
		# du popup. Le popup est avancé de z=0.02 devant la fenêtre (anti
		# z-fighting) : le rayon coupe les deux plans à des points différents
		# selon l'angle de la caméra (parallaxe), ce qui décalait les
		# coordonnées de ~7-9 px (suffisant pour que Firefox ferme le menu).
		# On réintersecte donc le rayon avec le plan de la fenêtre pour avoir
		# la position réelle du curseur, puis on retranche l'origine du popup
		# (géométrie xdg-shell = coordonnées surface du parent).
		var window_quad: MeshInstance3D = quads[info.parent_window_id]
		var window_body: StaticBody3D = window_quad.get_child(0)
		var window_mesh: QuadMesh = window_quad.mesh
		var window_surface_size: Vector2 = window_body.get_meta("surface_size", Vector2(1, 1))
		var window_content_offset: Vector2 = window_body.get_meta("content_offset", Vector2.ZERO)
		var window_uv := _uv_at_plane(window_quad, window_mesh, ray_origin, ray_dir, hit.position)
		var surface_pos := Vector2(
			window_uv.x * window_surface_size.x + window_content_offset.x,
			window_uv.y * window_surface_size.y + window_content_offset.y)
		px = surface_pos.x - float(info.x)
		py = surface_pos.y - float(info.y)
	else:
		# Sous-menu (parenté à un autre popup) : calcul direct sur le plan du
		# popup, même convention que précédemment.
		var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
		px = uv.x * win_size.x
		py = uv.y * win_size.y
	print("raycast: POPUP pid=", pid, " px=", px, " py=", py,
		" surf_size=", win_size, " quad_pos=", quad.global_position,
		" mesh_size=", mesh.size)
	compositor.forward_pointer_motion_popup(pid, px, py)

	if Input.is_action_just_pressed("left_click", false):
		compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button_popup(pid, 0x110, false)

	# Le clic droit doit aussi être relayé quand le curseur est au-dessus
	# d'un popup : sans relâchement, button_count reste bloqué à 1 dans
	# wlroots et le compositeur ne peut plus entrer le popup (hover/clic
	# impossibles). wlroots route les boutons vers la surface focusée, donc
	# le relâchement d'un clic parti sur la fenêtre y retombe correctement.
	if Input.is_action_just_pressed("right_click", false):
		compositor.forward_pointer_button_popup(pid, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button_popup(pid, 0x111, false)

# Clic sur un bouton de la barre de titre.
func _handle_titlebar_button(body: StaticBody3D) -> void:
	if not Input.is_action_just_pressed("left_click", false):
		return
	var info: Dictionary = body.get_meta("titlebar_button")
	var wid: int = info["wid"]
	var action: String = info["action"]
	match action:
		"minimize":
			# xdg-shell n'a pas de minimize : on cache le quad (restauration
			# via le menu fenêtres, bouton HIDE/SHOW).
			toggle_hide(wid)
		"maximize":
			var is_fs: bool = fullscreen_windows.get(wid, false)
			toggle_window_fullscreen(wid, not is_fs)
		"close":
			compositor.close_window(wid)

func toggle_window_fullscreen(id: int, fullscreen: bool) -> void:
	fullscreen_windows[id] = fullscreen

	if not quads.has(id) or not is_instance_valid(quads[id]):
		return

	var quad: MeshInstance3D = quads[id]
	var mesh: QuadMesh = quad.mesh
	var body: StaticBody3D = quad.get_child(0)

	if fullscreen:
		# 1. Store state prior to toggling fullscreen
		pre_fullscreen_mesh_sizes[id] = mesh.size
		pre_fullscreen_surface_sizes[id] = body.get_meta("surface_size", Vector2(1024, 768))

		# 2. Request viewport dimensions from the Wayland surface
		var vp_size := get_viewport().get_visible_rect().size
		var aspect = vp_size.x / max(vp_size.y, 1.0)
		
		# Standardized 3D height facing camera (1.0 meter high)
		mesh.size = Vector2(1.0 * aspect, 1.0) * WINDOW_QUAD_SCALE
		
		# Update collision shape to match mesh size
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		_sync_titlebar(quad)

		# Notify Wayland client buffer of target size
		compositor.set_window_size(id, int(vp_size.x), int(vp_size.y))

	else:
		# 1. Restore Quad Mesh Size
		if pre_fullscreen_mesh_sizes.has(id):
			mesh.size = pre_fullscreen_mesh_sizes[id]
			pre_fullscreen_mesh_sizes.erase(id)

		# Restore collision shape
		var col: CollisionShape3D = body.get_child(0)
		var shape: BoxShape3D = col.shape
		shape.size = Vector3(mesh.size.x, mesh.size.y, shape.size.z)
		_sync_titlebar(quad)

		# 2. Restore original Wayland client surface size
		if pre_fullscreen_surface_sizes.has(id):
			var orig_surf: Vector2 = pre_fullscreen_surface_sizes[id]
			compositor.set_window_size(id, int(orig_surf.x), int(orig_surf.y))
			pre_fullscreen_surface_sizes.erase(id)
	windows_state_changed.emit()

# Clic sur la barre de titre du jeu -> déplacer la fenêtre sur son plan 2D
# (même mécanique que le drag sur la tranche supérieure du contenu).
func _handle_titlebar(body: StaticBody3D, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var titlebar: MeshInstance3D = body.get_parent()
	var quad: MeshInstance3D = titlebar.get_parent()
	var wid: int = body.get_meta("titlebar_of")
	if Input.is_action_just_pressed("left_click", false):
		focused_window_id = wid
		active_window_id = wid
		is_moving_2d = true
		var normal = quad.global_transform.basis.z.normalized()
		move_2d_plane = Plane(normal, quad.global_position)
		var _hit = move_2d_plane.intersects_ray(ray_origin, ray_dir)
		if _hit != null:
			move_2d_offset = quad.global_position - _hit
	if Input.is_action_just_released("left_click", false):
		active_window_id = -1
		is_moving_2d = false
		move_2d_offset = Vector3.ZERO

# UV exact sur le plan visuel du quad : le point renvoyé par le raycast est
# sur la face avant du boîtier de collision (épais), donc décalé du plan
# z=0 du quad de ~0.025·tan(angle). Négligeable de loin, mais à bout
# portant ça décale le clic de plusieurs dizaines de pixels vers le bas.
func _uv_at_plane(quad: MeshInstance3D, mesh: QuadMesh, ray_origin: Vector3, ray_dir: Vector3, fallback: Vector3) -> Vector2:
	var quad_plane := Plane(quad.global_transform.basis.z.normalized(), quad.global_position)
	var plane_hit = quad_plane.intersects_ray(ray_origin, ray_dir)
	if plane_hit == null:
		plane_hit = fallback
	var local := quad.to_local(plane_hit)
	return Vector2(
		(local.x / mesh.size.x) + 0.5,
		0.5 - (local.y / mesh.size.y)
	)

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

	# Bords simples: bande fine (BORDER_MARGIN), hors des zones de coin.
	var edge := ""
	if py > content_size.y - BORDER_MARGIN:
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
	var cam: Camera3D = _camera()
	var target_pos = ray_origin + ray_dir * move_depth
	# Déplacement fluide
	quad.global_position = quad.global_position.lerp(
		target_pos,
		10.0 * delta
	)
	# Rotation
	quad.global_basis = cam.global_basis

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
	if "bottom" in resizing_edge:
		new_h = window_start_size.y - local_dy * px_per_unit_y

	new_w = max(new_w, MIN_SURFACE_SIZE)
	new_h = max(new_h, MIN_SURFACE_SIZE)

	# set_window_size envoie les dimensions de la SURFACE (buffer) au client
	# Wayland, pas la geometry. Les ombres CSD sont typiquement symétriques,
	# donc surface = geometry + 2 * content_offset.
	var surface_w := int(new_w) + int(window_start_content_offset.x) * 2
	var surface_h := int(new_h) + int(window_start_content_offset.y) * 2
	compositor.set_window_size(active_window_id, surface_w, surface_h)
	fullscreen_windows[active_window_id] = false
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
	# Une fenêtre redimensionnée à la main garde sa taille monde : on_texture_updated
	# ne doit plus la recalculer d'après les pixels (voir user_sized là-bas).
	body.set_meta("user_sized", true)
	var col: CollisionShape3D = body.get_child(0)
	var shape: BoxShape3D = col.shape
	shape.size = Vector3(new_mesh_w, new_mesh_h, shape.size.z)
	_sync_titlebar(quad)

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
