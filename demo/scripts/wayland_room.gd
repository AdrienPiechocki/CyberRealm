extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".

@onready var compositor: WlrCompositor = $WlrCompositor
@onready var launcher_menu = $Player/LauncherLayer/LauncherMenu
@onready var window_menu = $Player/WindowMenuLayer/WindowMenu
@onready var pause_menu = $Player/PauseMenuLayer/PauseMenu
var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var window_textures: Dictionary = {} # window_id (int) -> Texture2D
var xray_windows: Dictionary = {} # window_id (int) -> bool
var xray_time: float = 0.0
var xray_overlay: StandardMaterial3D # material pour l'effet X-RAY (no_depth_test)
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
var focus_close_button: Button
var focus_surface_size := Vector2.ZERO
var focus_content_offset := Vector2.ZERO
var focus_content_size := Vector2.ZERO
var focus_mouse_captured := false
var focus_mouse_uv := Vector2(0.5, 0.5) # position tracking en mode capturé
var focus_popup_rects: Dictionary = {} # popup_id (int) -> TextureRect overlay en mode focus

# Info parent de chaque popup (pour créer les overlays focus quand on entre
# en mode focus alors que des popups existent déjà).
var popup_parent_info: Dictionary = {} # popup_id -> {parent_window_id, parent_popup_id, x, y, width, height}

# PiP pinning: clones 2D des fenêtres épinglées dans le coin supérieur-gauche
var pinned_windows: Dictionary = {} # window_id (int) -> TextureRect

const PIN_SIZE := Vector2(640, 360)
const PIN_MARGIN := 8

# Drag-and-drop icon overlay
var drag_icon_rect: TextureRect
var drag_icon_size := Vector2.ZERO

# Toast notifications — pile d'alertes
var toasts: Array[Dictionary] = []
var toast_spacing := 44

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
	# Matériau X-RAY: transparent, passe devant tout (no_depth_test)
	xray_overlay = StandardMaterial3D.new()
	xray_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	xray_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	xray_overlay.albedo_color = Color(1.0, 0.15, 0.15, 0.6)
	xray_overlay.no_depth_test = true
	xray_overlay.render_priority = 10

	compositor.window_mapped.connect(_on_window_mapped)
	compositor.window_unmapped.connect(_on_window_unmapped)
	compositor.window_texture_updated.connect(_on_texture_updated)
	compositor.popup_mapped.connect(_on_popup_mapped)
	compositor.popup_unmapped.connect(_on_popup_unmapped)
	compositor.popup_texture_updated.connect(_on_popup_texture_updated)
	compositor.pointer_lock_changed.connect(_on_pointer_lock_changed)
	compositor.drag_icon_updated.connect(_on_drag_icon_updated)
	compositor.drag_icon_removed.connect(_on_drag_icon_removed)
	compositor.notification_received.connect(_on_notification_received)
	compositor.start_headless()
	compositor.launch_app("xwayland-satellite :1")
	await get_tree().create_timer(0.2).timeout
	compositor.set_x11_display(":1")
	launcher_menu.app_launch.connect(func(cmd): compositor.launch_app(cmd))

	# Setup du menu de navigation entre fenêtres
	window_menu.setup(compositor, _get_window_texture)
	window_menu.action_grab.connect(_on_window_menu_grab)
	window_menu.action_focus.connect(_on_window_menu_focus)
	window_menu.action_toggle_hide.connect(_on_window_menu_toggle_hide)
	window_menu.action_find.connect(_on_window_menu_find)
	window_menu.action_pin.connect(_on_window_menu_pin)
	window_menu.action_quit.connect(_on_window_menu_quit)
	window_menu.menu_closed.connect(_on_window_menu_closed)

	pause_menu.fps_toggled.connect(func(v): $Player/UI/FPS.visible = v)
	pause_menu.capture_label_toggled.connect(func(v): $Player/UI/Label.visible = v)
	pause_menu.terminal_changed.connect(func(t): launcher_menu.terminal_emulator = t)
	pause_menu.portal_backend_changed.connect(func(b): compositor.set_portal_backend(b))
	pause_menu.polkit_agent_changed.connect(func(p): compositor.set_polkit_agent(p))
	pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)
	pause_menu.quit_requested.connect(_on_quit_requested)
	
	# Appliquer les réglages persistés
	compositor.set_portal_backend(pause_menu.selected_portal_backend)
	compositor.set_polkit_agent(pause_menu.selected_polkit_agent)
	if pause_menu.selected_terminal != "":
		launcher_menu.terminal_emulator = pause_menu.selected_terminal

	# TextureRect plein écran pour le mode focus
	focus_texture_rect = TextureRect.new()
	focus_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	focus_texture_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	focus_texture_rect.visible = false
	focus_texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	$Player/UI.add_child(focus_texture_rect)

	# Bouton X pour quitter le mode focus
	focus_close_button = Button.new()
	focus_close_button.text = "✕"
	focus_close_button.custom_minimum_size = Vector2(40, 40)
	focus_close_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	focus_close_button.offset_left = -50
	focus_close_button.offset_top = 10
	focus_close_button.offset_right = -10
	focus_close_button.offset_bottom = 50
	focus_close_button.z_index = 20
	focus_close_button.visible = false
	focus_close_button.pressed.connect(_exit_focus_mode)
	focus_close_button.mouse_filter = Control.MOUSE_FILTER_STOP
	$Player/UI.add_child(focus_close_button)

	# TextureRect pour l'icône de drag-and-drop
	drag_icon_rect = TextureRect.new()
	drag_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	drag_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_icon_rect.visible = false
	drag_icon_rect.z_index = 100
	$Player/UI.add_child(drag_icon_rect)

	# Toast notifications — rien à initialiser, créé à la volée

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
	focus_close_button.visible = true

	# Libérer la souris pour interagir avec la fenêtre, centrée sur l'écran
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)

	# Créer les overlays pour les popups déjà ouverts de cette fenêtre
	for popup_id in popup_parent_info:
		var info = popup_parent_info[popup_id]
		if info.parent_window_id == focus_window_id or \
			(info.parent_popup_id != -1 and focus_popup_rects.has(info.parent_popup_id)):
			_create_focus_popup_overlay(popup_id, info.parent_window_id, info.parent_popup_id,
				info.x, info.y, info.width, info.height)

	# Bloquer le player
	$Player.focus_mode_active = true

func _exit_focus_mode() -> void:
	if not focus_mode:
		return

	compositor.release_all_keys()

	# Réafficher le quad 3D
	if quads.has(focus_window_id) and is_instance_valid(quads[focus_window_id]):
		quads[focus_window_id].visible = true

	# Cacher le overlay, libérer la texture
	focus_texture_rect.visible = false
	focus_texture_rect.texture = null
	focus_close_button.visible = false
	focus_mode = false
	focus_window_id = -1
	focus_mouse_captured = false

	# Nettoyer les overlays popup du mode focus
	for popup_id in focus_popup_rects:
		if is_instance_valid(focus_popup_rects[popup_id]):
			focus_popup_rects[popup_id].queue_free()
	focus_popup_rects.clear()

	# Restaurer la souris capturée
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Débloquer le player
	$Player.focus_mode_active = false

func _compute_focus_displayed_info() -> Dictionary:
	"""Calcule l'offset, la taille et le scale de la zone affichée du TextureRect focus."""
	var tex := focus_texture_rect.texture
	if not tex:
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var tex_size := tex.get_size()
	var tex_rect := focus_texture_rect.get_global_rect()
	var aspect = tex_size.x / max(tex_size.y, 1.0)
	var rect_aspect = tex_rect.size.x / max(tex_rect.size.y, 1.0)
	var displayed_size: Vector2
	if aspect > rect_aspect:
		displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
	else:
		displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
	var offset := tex_rect.position + (tex_rect.size - displayed_size) / 2.0
	var scale := Vector2(displayed_size.x / max(tex_size.x, 1), displayed_size.y / max(tex_size.y, 1))
	return {"offset": offset, "size": displayed_size, "scale": scale}

func _create_focus_popup_overlay(popup_id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, pw: int, ph: int) -> void:
	"""Crée un TextureRect overlay pour un popup en mode focus."""
	var popup_scale: Vector2
	var popup_offset: Vector2

	# Sous-menu: calculer la zone affichée du parent (STRETCH_KEEP_ASPECT_CENTERED
	# centre la texture, donc la zone utile ≠ parent_rect.size).
	if parent_popup_id != -1 and focus_popup_rects.has(parent_popup_id):
		var parent_rect: TextureRect = focus_popup_rects[parent_popup_id]
		var parent_tex := parent_rect.texture
		if not parent_tex:
			return
		var pts := parent_tex.get_size()
		var p_aspect = pts.x / max(pts.y, 1.0)
		var pr_aspect = parent_rect.size.x / max(parent_rect.size.y, 1.0)
		var p_displayed: Vector2
		if p_aspect > pr_aspect:
			p_displayed = Vector2(parent_rect.size.x, parent_rect.size.x / p_aspect)
		else:
			p_displayed = Vector2(parent_rect.size.y * p_aspect, parent_rect.size.y)
		popup_scale = Vector2(p_displayed.x / max(pts.x, 1), p_displayed.y / max(pts.y, 1))
		popup_offset = parent_rect.position + (parent_rect.size - p_displayed) / 2.0
	elif focus_mode and parent_window_id == focus_window_id:
		var info := _compute_focus_displayed_info()
		popup_scale = info.scale
		popup_offset = info.offset
	else:
		return

	var popup_tex_rect := TextureRect.new()
	popup_tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	popup_tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	popup_tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup_tex_rect.size = Vector2(pw, ph) * popup_scale
	popup_tex_rect.position = popup_offset + Vector2(x, y) * popup_scale
	$Player/UI.add_child(popup_tex_rect)
	focus_popup_rects[popup_id] = popup_tex_rect

	# Appliquer la texture disponible dès maintenant
	if popup_quads.has(popup_id) and is_instance_valid(popup_quads[popup_id]):
		var quad: MeshInstance3D = popup_quads[popup_id]
		var mat: ShaderMaterial = quad.material_override as ShaderMaterial
		if mat:
			popup_tex_rect.texture = mat.get_shader_parameter("window_texture")

func _pin_window(id: int) -> void:
	if pinned_windows.has(id):
		return
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return

	var quad: MeshInstance3D = quads[id]
	var mat: ShaderMaterial = quad.material_override as ShaderMaterial
	var tex: Texture2D = mat.get_shader_parameter("window_texture")

	var pip := TextureRect.new()
	pip.texture = tex
	pip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pip.size = PIN_SIZE
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Bordure
	var border := PanelContainer.new()
	border.size = PIN_SIZE + Vector2(4, 4)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.08, 0.9)
	bg.border_color = Color(0.4, 0.6, 1.0, 0.8)
	bg.border_width_top = 2
	bg.border_width_bottom = 2
	bg.border_width_left = 2
	bg.border_width_right = 2
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	border.add_theme_stylebox_override("panel", bg)
	border.add_child(pip)

	var idx := pinned_windows.size()
	border.position = Vector2(PIN_MARGIN, PIN_MARGIN + idx * (PIN_SIZE.y + PIN_MARGIN + 4))
	pip.set_meta("window_id", id)
	$Player/UI.add_child(border)
	pinned_windows[id] = border

func _unpin_window(id: int) -> void:
	if not pinned_windows.has(id):
		return
	var pip: Control = pinned_windows[id]
	if is_instance_valid(pip):
		pip.queue_free()
	pinned_windows.erase(id)

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
		var mouse_pos := get_viewport().get_mouse_position()

		# Utiliser la zone réelle affichée par le TextureRect pour le mapping
		# (plus précis que de recalculer avec focus_surface_size)
		var tex := focus_texture_rect.texture
		if tex:
			var tex_size := tex.get_size()
			# Rect2 global du TextureRect après layout Godot
			var tex_rect := focus_texture_rect.get_global_rect()
			# Taille affichée respectant l'aspect ratio
			var aspect := tex_size.x / tex_size.y
			var rect_aspect := tex_rect.size.x / tex_rect.size.y
			var displayed_size: Vector2
			if aspect > rect_aspect:
				displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
			else:
				displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
			var offset := tex_rect.position + (tex_rect.size - displayed_size) / 2.0

			var local_pos := mouse_pos - offset
			focus_mouse_uv = Vector2(
				clampf(local_pos.x / displayed_size.x, 0.0, 1.0),
				clampf(local_pos.y / displayed_size.y, 0.0, 1.0)
			)
		else:
			focus_mouse_uv = Vector2(0.5, 0.5)

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
	_unpin_window(id)
	window_textures.erase(id)
	xray_windows.erase(id)
	if quads.has(id):
		var quad = quads[id]
		if is_instance_valid(quad):
			quad.queue_free()
		quads.erase(id)

func _on_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	# Tracker la texture pour le menu de navigation
	window_textures[id] = texture
	# Rafraîchir la preview du menu si ouvert
	if window_menu.visible:
		window_menu.refresh_preview()

	# Mettre à jour le clone PiP si la fenêtre est épinglée
	if pinned_windows.has(id) and is_instance_valid(pinned_windows[id]):
		var pip_tex: TextureRect = pinned_windows[id].get_child(0)
		pip_tex.texture = texture

	# Mettre à jour le overlay 2D en mode focus
	if focus_mode and id == focus_window_id:
		focus_texture_rect.texture = texture
		# Utiliser la taille réelle de la texture (pas width/height qui
		# sont la taille du contenu). Dans le path Vulkan, le VkImage est
		# alloué plus grand que le contenu (round_up_capture_size) — le
		# UV est calculé depuis tex.get_size(), donc la conversion
		# UV → surface doit utiliser la même base.
		focus_surface_size = texture.get_size()
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

	# Stocker les infos parent pour le mode focus
	popup_parent_info[id] = {
		"parent_window_id": parent_window_id,
		"parent_popup_id": parent_popup_id,
		"x": x, "y": y, "width": width, "height": height
	}

	# Créer l'overlay focus si on est en mode focus et que ce popup
	# appartient à la fenêtre focalisée
	if focus_mode:
		_create_focus_popup_overlay(id, parent_window_id, parent_popup_id, x, y, width, height)

func _on_popup_unmapped(id: int) -> void:
	if popup_quads.has(id):
		if is_instance_valid(popup_quads[id]):
			popup_quads[id].queue_free()
		popup_quads.erase(id)
	popup_parent_info.erase(id)

	# Nettoyer l'overlay focus
	if focus_popup_rects.has(id):
		if is_instance_valid(focus_popup_rects[id]):
			focus_popup_rects[id].queue_free()
		focus_popup_rects.erase(id)

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

	# Mettre à jour l'overlay focus si le popup est affiché en mode focus
	if focus_popup_rects.has(id) and is_instance_valid(focus_popup_rects[id]):
		var popup_tex_rect: TextureRect = focus_popup_rects[id]
		popup_tex_rect.texture = texture
		# Recalculer la taille avec le scale du parent
		if popup_parent_info.has(id):
			var info = popup_parent_info[id]
			var popup_scale := Vector2.ONE
			var popup_offset := Vector2.ZERO
			if info.parent_popup_id != -1 and focus_popup_rects.has(info.parent_popup_id):
				var parent_rect: TextureRect = focus_popup_rects[info.parent_popup_id]
				var parent_tex := parent_rect.texture
				if parent_tex:
					var pts := parent_tex.get_size()
					var p_aspect = pts.x / max(pts.y, 1.0)
					var pr_aspect = parent_rect.size.x / max(parent_rect.size.y, 1.0)
					var p_displayed: Vector2
					if p_aspect > pr_aspect:
						p_displayed = Vector2(parent_rect.size.x, parent_rect.size.x / p_aspect)
					else:
						p_displayed = Vector2(parent_rect.size.y * p_aspect, parent_rect.size.y)
					popup_scale = Vector2(p_displayed.x / max(pts.x, 1), p_displayed.y / max(pts.y, 1))
					popup_offset = parent_rect.position + (parent_rect.size - p_displayed) / 2.0
			elif focus_mode and focus_window_id == info.parent_window_id:
				var fi := _compute_focus_displayed_info()
				popup_scale = fi.scale
				popup_offset = fi.offset
			popup_tex_rect.size = Vector2(info.width, info.height) * popup_scale
			popup_tex_rect.position = popup_offset + Vector2(info.x, info.y) * popup_scale

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
	_update_xray(delta)

	# Suivi de l'icône de drag-and-drop
	if drag_icon_rect and drag_icon_rect.visible:
		var mouse_pos := get_viewport().get_mouse_position()
		drag_icon_rect.position = mouse_pos - drag_icon_size / 2.0

	if Input.is_action_just_pressed("launcher") and not interact_mode_active and not launcher_menu.visible and not focus_mode and not window_menu.visible:
		launcher_menu.toggle_menu()

	if Input.is_action_just_pressed("window_menu") and not interact_mode_active and not launcher_menu.visible and not focus_mode:
		window_menu.toggle_menu()

	if launcher_menu.visible or window_menu.visible:
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

	# P en visant une fenêtre → pin/unpin PiP
	if Input.is_action_just_pressed("pin_window") and not interact_mode_active:
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
				var wid: int = body.get_meta("window_id")
				if pinned_windows.has(wid):
					_unpin_window(wid)
				else:
					_pin_window(wid)
				return

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	if Input.is_action_just_pressed("interact_mode"):
		if interact_mode_active:
			compositor.release_all_keys()
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
	if pause_menu.visible:
		return

	# Quick-launch favoris F1-F12 (hors launcher, hors focus, hors interact)
	if not launcher_menu.visible and not window_menu.visible and not focus_mode and not interact_mode_active:
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode >= KEY_F1 and event.keycode <= KEY_F12:
				var slot = event.keycode - KEY_F1 + 1
				if slot >= 1 and slot <= 12:
					var fav = launcher_menu.get_favorite(slot)
					if fav.size() > 0:
						compositor.launch_app(fav["exec"])
						_show_toast("F" + str(slot) + "  →  " + fav["name"])
						get_viewport().set_input_as_handled()
						return

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

func _on_drag_icon_updated(texture: Texture2D, width: int, height: int) -> void:
	drag_icon_rect.texture = texture
	drag_icon_size = Vector2(width, height)
	drag_icon_rect.visible = true
	drag_icon_rect.pivot_offset = drag_icon_size / 2.0

func _on_drag_icon_removed() -> void:
	drag_icon_rect.visible = false
	drag_icon_rect.texture = null

# ── Window menu helpers ──────────────────────────────────────────────

func _get_window_texture(wid: int) -> Texture2D:
	return window_textures.get(wid, null)

func _on_window_menu_grab(wid: int) -> void:
	# Fermer le menu, sélectionner la fenêtre et initier le grab
	window_menu.hide_menu()
	if not quads.has(wid) or not is_instance_valid(quads[wid]):
		return
	var quad: MeshInstance3D = quads[wid]
	var cam := $Player/Camera3D
	active_window_id = wid
	is_moving = true
	move_depth = cam.global_position.distance_to(quad.global_position)

func _on_window_menu_focus(wid: int) -> void:
	window_menu.hide_menu()
	_enter_focus_mode(wid)

func _on_window_menu_toggle_hide(wid: int) -> void:
	if not quads.has(wid) or not is_instance_valid(quads[wid]):
		return
	var quad: MeshInstance3D = quads[wid]
	quad.visible = not quad.visible
	var body: StaticBody3D = quad.get_child(0)
	if body is StaticBody3D:
		body.get_child(0).disabled = not quad.visible
	if window_menu.visible:
		window_menu.refresh_preview()

func _on_window_menu_find(wid: int) -> void:
	window_menu.hide_menu()
	xray_windows[wid] = not xray_windows.get(wid, false)
	var active: bool = xray_windows.get(wid, false)
	if quads.has(wid) and is_instance_valid(quads[wid]):
		if not active:
			quads[wid].material_overlay = null
		else:
			quads[wid].material_overlay = xray_overlay

func _update_xray(delta: float) -> void:
	if xray_windows.is_empty():
		return
	xray_time += delta
	var pulse := (sin(xray_time * 6.0) * 0.5 + 0.5) # 0..1, ~1 Hz
	xray_overlay.albedo_color.a = 0.3 + pulse * 0.5

func _on_window_menu_quit(wid: int) -> void:
	compositor.close_window(wid)

func _on_window_menu_pin(wid: int) -> void:
	if pinned_windows.has(wid):
		_unpin_window(wid)
	else:
		_pin_window(wid)
	window_menu.hide_menu()

func _on_window_menu_closed() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_pause_menu_visibility_changed() -> void:
	if pause_menu.visible:
		if interact_mode_active:
			compositor.release_all_keys()
			interact_mode_active = false
			$Player.interact_mode_active = false
		if focus_mode:
			_exit_focus_mode()

func _on_notification_received(app_name: String, summary: String, body: String, app_icon: String, urgency: int) -> void:
	var text := ""
	if summary != "":
		text = summary
		if body != "":
			text += ": " + body
	elif body != "":
		text = body
	else:
		text = "Notification"
	if app_icon != "":
		text = "[ " + app_name + " ] " + text
	if urgency == 2:
		text = "⚠ " + text
	_show_toast(text)

func _show_toast(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.z_index = 50
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.14, 0.9)
	bg.corner_radius_top_left = 6
	bg.corner_radius_top_right = 6
	bg.corner_radius_bottom_left = 6
	bg.corner_radius_bottom_right = 6
	bg.content_margin_left = 16
	bg.content_margin_right = 16
	bg.content_margin_top = 6
	bg.content_margin_bottom = 6
	label.add_theme_stylebox_override("normal", bg)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Player/UI.add_child(label)

	var vp := get_viewport().get_visible_rect().size
	label.reset_size()
	var y_base := vp.y - 80

	# Pousser les toasts existants vers le haut (uniquement le tween position)
	var entry := {label = label, pos_tween = null, life_tween = null}
	for t in toasts:
		if is_instance_valid(t.label):
			var off = t.label.position.y - toast_spacing
			if t.pos_tween and t.pos_tween.is_valid():
				t.pos_tween.kill()
			t.pos_tween = create_tween().set_trans(Tween.TRANS_CUBIC)
			t.pos_tween.tween_property(t.label, "position:y", off, 0.25)
	toasts.append(entry)

	label.position = Vector2((vp.x - label.size.x) / 2.0, y_base)
	label.modulate.a = 1.0

	# Cycle de vie (jamais tué) : attendre → fondre → supprimer
	entry.life_tween = create_tween().set_trans(Tween.TRANS_CUBIC)
	entry.life_tween.tween_interval(2.0)
	entry.life_tween.tween_property(label, "modulate:a", 0.0, 0.5)
	entry.life_tween.tween_callback(_remove_toast.bind(label))

func _remove_toast(label: Label) -> void:
	if not is_instance_valid(label): return
	label.queue_free()
	for i in toasts.size():
		if toasts[i].label == label:
			toasts.remove_at(i)
			break

func _on_quit_requested() -> void:
	for wid in quads.keys():
		compositor.close_window(wid)

	await get_tree().create_timer(0.2).timeout

	get_tree().quit()
