extends Node3D
## Exemple minimal: instancie un quad texturé par fenêtre Wayland mappée,
## et route les clics/raycasts de la caméra vers le compositeur.
## À brancher sur une scène avec un Camera3D enfant nommé "Camera3D".

@onready var compositor: WlrCompositor = $WlrCompositor
@onready var window_menu = $Player/WindowMenuLayer/WindowMenu
@onready var pause_menu = $Player/PauseMenuLayer/PauseMenu
var quads: Dictionary = {} # window_id (int) -> MeshInstance3D
var popup_quads: Dictionary = {} # popup_id (int) -> MeshInstance3D
var window_textures: Dictionary = {} # window_id (int) -> Texture2D
var xray_windows: Dictionary = {} # window_id (int) -> bool
var xray_time: float = 0.0
var xray_overlay: StandardMaterial3D # material pour l'effet X-RAY (no_depth_test)
var flash_windows: Dictionary = {} # window_id (int) -> {mat, elapsed} — flash blanc à l'ouverture
const FLASH_DURATION := 0.2
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
#var focus_close_button: Button
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

# Layer surfaces (wlr-layer-shell-unstable-v1): waybar, rofi, notifications.
# Rendu en overlays 2D ancrés à l'écran (pas de quads 3D), positionnés aux
# coordonnées (x, y, width, height) calculées par arrange_layer_surfaces().
const LAYER_BACKGROUND := 0
const LAYER_BOTTOM := 1
const LAYER_TOP := 2
const LAYER_OVERLAY := 3
# Fond d'écran (couche background, quickshell/DankMaterialShell) : on ne le
# rend pas, il cacherait le contenu 3D du jeu.
const SHOW_BACKGROUND_LAYER := false
const ANCHOR_TOP := 1
const ANCHOR_BOTTOM := 2
const ANCHOR_LEFT := 4
const ANCHOR_RIGHT := 8
# z_index de base pour les overlays de layer surfaces. Toujours au-dessus du
# contenu 3D et des fenêtres épinglées (PiP, z_index par défaut 0) comme dans
# un compositeur classique ; les popups de layer passent encore au-dessus.
const LAYER_Z_BASE := 1000

# z_index du mode focus : la fenêtre focus s'affiche au-dessus des layer
# surfaces (layers jusqu'à LAYER_Z_BASE + 800) et de leurs popups.
const FOCUS_Z_BASE := 2000
const FOCUS_POPUP_Z := FOCUS_Z_BASE + 50
const FOCUS_CLOSE_Z := FOCUS_Z_BASE + 100

# z_index du lockscreen (ext-session-lock-v1) : au-dessus de tout — layer
# surfaces, mode focus, PiP — car un session verrouillée ne doit montrer
# que le lockscreen.
const SESSION_LOCK_Z := 3000

var layer_rects: Dictionary = {} # layer_id (int) -> {rect, layer, anchor}
var layer_popup_rects: Dictionary = {} # popup_id (int) -> {rect, parent_layer_id}
var layer_overlay: Control
var layer_shader: Shader
# Mode "interaction layer" (touche Tab): souris libérée pour interagir avec
# les overlays non interactifs (waybar, quickshell bar). Faux quand la souris
# a été recapturée par un autre moyen.
var layer_interact_active := false
var layer_interact_manual := false

# Session lock (ext-session-lock-v1): quand true, le lockscreen quickshell
# est affiché plein écran et reçoit tout l'input (pointeur + clavier).
var session_locked := false
var session_lock_rect: TextureRect
var session_lock_surface_id := -1

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

# Shader des overlays 2D de layer surfaces: remappe le UV sur la zone de
# contenu réelle. Le buffer d'allocation est arrondi au palier de 64 px
# (round_up_capture_size côté C++, ex: barre waybar de 30 px -> buffer 64 px
# de haut); sans ce remap le TextureRect étire toute la texture dans son
# rectangle -> image écrasée. Même principe que WAYLAND_SHADER_CODE (3D) mais
# en espace canvas_item. Gère aussi le buffer_scale (contenu en haut-gauche).
const LAYER_SHADER_CODE = """
shader_type canvas_item;

uniform sampler2D u_tex : filter_linear;
uniform vec2 u_content_size = vec2(0.0, 0.0);

void fragment() {
	if (u_content_size.x <= 0.0 || u_content_size.y <= 0.0) {
		// Pas encore de texture capturée -> invisible.
		COLOR = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		vec2 ts = vec2(textureSize(u_tex, 0));
		vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0)
			? UV * u_content_size / ts : UV;
		vec4 tex = texture(u_tex, mapped_uv);
		// Buffers Wayland pré-multipliés (wl_shm ARGB32, Cairo...):
		// dé-pré-multiplier puis convertir sRGB -> linéaire (affichage 2D).
		vec3 unmultiplied = tex.a > 0.01 ? tex.rgb / max(tex.a, 0.001) : tex.rgb;
		COLOR = vec4(pow(unmultiplied, vec3(2.2)), tex.a);
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
	compositor.layer_surface_mapped.connect(_on_layer_surface_mapped)
	compositor.layer_surface_unmapped.connect(_on_layer_surface_unmapped)
	compositor.layer_surface_texture_updated.connect(_on_layer_surface_texture_updated)
	compositor.layer_popup_mapped.connect(_on_layer_popup_mapped)
	compositor.session_lock_locked.connect(_on_session_lock_locked)
	compositor.session_lock_unlocked.connect(_on_session_lock_unlocked)
	compositor.session_lock_surface_texture_updated.connect(_on_session_lock_surface_texture_updated)
	compositor.start_headless()
	layer_shader = Shader.new()
	layer_shader.code = LAYER_SHADER_CODE
	# Les layer surfaces sont ancrées à l'écran : le compositeur doit
	# connaître la taille du viewport pour le layout (arrange_layer_surfaces).
	compositor.set_output_size(int(get_viewport().get_visible_rect().size.x),
		int(get_viewport().get_visible_rect().size.y))
	compositor.launch_app("xwayland-satellite :1")
	await get_tree().create_timer(0.2).timeout
	compositor.set_x11_display(":1")
	# Apps à lancer automatiquement au démarrage (configurées depuis le menu pause)
	for cmd in pause_menu.get_startup_apps():
		compositor.launch_app(cmd)
	# Setup du menu de navigation entre fenêtres
	window_menu.setup(compositor, _get_window_texture)
	window_menu.action_grab.connect(_on_window_menu_grab)
	window_menu.action_focus.connect(_on_window_menu_focus)
	window_menu.action_toggle_hide.connect(_on_window_menu_toggle_hide)
	window_menu.action_find.connect(_on_window_menu_find)
	window_menu.action_pin.connect(_on_window_menu_pin)
	window_menu.action_quit.connect(_on_window_menu_quit)
	window_menu.menu_closed.connect(_on_window_menu_closed)

	pause_menu.visibility_changed.connect(_on_pause_menu_visibility_changed)
	pause_menu.app_launch_requested.connect(compositor.launch_app)

	# TextureRect plein écran pour le mode focus
	focus_texture_rect = TextureRect.new()
	focus_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	focus_texture_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	focus_texture_rect.visible = false
	focus_texture_rect.z_index = FOCUS_Z_BASE
	focus_texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	$Player/UI.add_child(focus_texture_rect)

	# TextureRect pour l'icône de drag-and-drop
	drag_icon_rect = TextureRect.new()
	drag_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	drag_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_icon_rect.visible = false
	drag_icon_rect.z_index = 100
	$Player/UI.add_child(drag_icon_rect)

	# Overlay plein écran recevant les TextureRect des layer surfaces.
	layer_overlay = Control.new()
	layer_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Player/UI.add_child(layer_overlay)

# Position de spawn des nouvelles fenêtres : on caste un rayon de
# SPAWN_RAY_DISTANCE m depuis la caméra ; s'il touche une fenêtre, la
# nouvelle fenêtre apparaît juste devant celle-ci (sur l'axe caméra ->
# fenêtre) au lieu de 1 m devant la caméra.
const SPAWN_RAY_DISTANCE := 1.0 # m, longueur du raycast de spawn
const SPAWN_IN_FRONT_DISTANCE := 0.1 # m devant la fenêtre touchée

func next_spawn_pos() -> Vector3:
	var camera: Camera3D = $Player/Camera3D
	var cam_pos: Vector3 = camera.global_position
	var cam_forward: Vector3 = -camera.global_basis.z
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		cam_pos, cam_pos + cam_forward * SPAWN_RAY_DISTANCE)
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		var body: Node3D = hit.collider
		if body.has_meta("window_id"):
			var hit_dist: float = cam_pos.distance_to(hit.position)
			return cam_pos + cam_forward * (hit_dist - SPAWN_IN_FRONT_DISTANCE)
	return cam_pos + cam_forward

func _enter_focus_mode(id: int) -> void:
	if not quads.has(id) or not is_instance_valid(quads[id]):
		return
	focus_mode = true
	focus_window_id = id
	focused_window_id = id
	focus_mouse_captured = false
	focus_mouse_uv = Vector2(0.5, 0.5)

	# Passer la fenêtre en plein écran pendant le mode focus
	compositor.set_window_fullscreen(id, true)

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
	#focus_close_button.visible = true

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

	# Sortir la fenêtre du plein écran
	if focus_window_id != -1:
		compositor.set_window_fullscreen(focus_window_id, false)

	# Réafficher le quad 3D
	if quads.has(focus_window_id) and is_instance_valid(quads[focus_window_id]):
		quads[focus_window_id].visible = true

	# Cacher le overlay, libérer la texture
	focus_texture_rect.visible = false
	focus_texture_rect.texture = null
	#focus_close_button.visible = false
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
	popup_tex_rect.z_index = FOCUS_POPUP_Z
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

	var surf_x: float
	var surf_y: float

	# Souris capturée: maintenir le pointer focus + forward relatif via _input
	if focus_mouse_captured:
		# Maintenir le pointer focus sur la surface (nécessaire pour que
		# wlr_relative_pointer_manager_v1_send_relative_motion livre les events)
		surf_x = focus_mouse_uv.x * focus_surface_size.x + focus_content_offset.x
		surf_y = focus_mouse_uv.y * focus_surface_size.y + focus_content_offset.y
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

		surf_x = focus_mouse_uv.x * focus_surface_size.x + focus_content_offset.x
		surf_y = focus_mouse_uv.y * focus_surface_size.y + focus_content_offset.y
		compositor.forward_pointer_motion(focus_window_id, surf_x, surf_y)

	if Input.is_action_just_pressed("left_click", true):
		compositor.forward_pointer_button(focus_window_id, 0x110, true)
	if Input.is_action_just_released("left_click", true):
		compositor.forward_pointer_button(focus_window_id, 0x110, false)

	if Input.is_action_just_pressed("right_click", true):
		compositor.forward_pointer_button(focus_window_id, 0x111, true)
	if Input.is_action_just_released("right_click", true):
		compositor.forward_pointer_button(focus_window_id, 0x111, false)

	if Input.is_action_just_pressed("scroll_up", true):
		compositor.forward_pointer_axis(focus_window_id, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down", true):
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
	# Épaisseur fine : la face avant du boîtier reste proche du plan visuel
	# du quad, sinon le raycast renvoie un point décalé en incidence rasant.
	shape.size = Vector3(mesh.size.x, mesh.size.y, 0.01)
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

	_start_flash(id, quad)
	
	#print("Fenêtre mappée: ", title, " (", app_id, ") id=", id)

func _on_window_unmapped(id: int) -> void:
	if focus_mode and focus_window_id == id:
		_exit_focus_mode()
	if focused_window_id == id:
		focused_window_id = -1
	_unpin_window(id)
	window_textures.erase(id)
	xray_windows.erase(id)
	_end_flash(id)
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
		shape.size = Vector3(mesh.size.x, mesh.size.y, 0.01)
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
	# Popup d'une layer surface: overlay 2D, pas de quad 3D.
	if layer_popup_rects.has(id):
		if is_instance_valid(layer_popup_rects[id].rect):
			layer_popup_rects[id].rect.queue_free()
		layer_popup_rects.erase(id)
		return

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
	# Popup d'une layer surface: on met simplement à jour l'overlay 2D.
	if layer_popup_rects.has(id):
		var popup_entry = layer_popup_rects[id]
		popup_entry.rect.texture = texture
		popup_entry.rect.set_meta("surface_size", Vector2(width, height))
		var popup_mat := popup_entry.rect.material as ShaderMaterial
		if popup_mat:
			popup_mat.set_shader_parameter("u_tex", texture)
			popup_mat.set_shader_parameter("u_content_size", Vector2(width, height))
		return

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

# ── Layer surfaces (waybar, rofi...) ─────────────────────────────────
# Le compositeur calcule le layout (position + taille) dans
# arrange_layer_surfaces() ; ici on ne fait que positionner les TextureRect
# aux coordonnées reçues, dans l'ordre des couches du protocole.

func _layer_z_index(layer: int, is_popup: bool = false) -> int:
	return LAYER_Z_BASE + layer * 100 + (500 if is_popup else 0)

func _on_layer_surface_mapped(id: int, ns: String, layer: int, anchor: int, x: int, y: int, w: int, h: int, kb: int) -> void:
	if layer_rects.has(id):
		return
	if layer == LAYER_BACKGROUND and not SHOW_BACKGROUND_LAYER:
		return
	var rect := TextureRect.new()
	rect.texture = null
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.position = Vector2(x, y)
	rect.size = Vector2(max(w, 1), max(h, 1))
	rect.z_index = _layer_z_index(layer)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = layer_shader
	mat.set_shader_parameter("u_content_size", Vector2(w, h))
	rect.material = mat
	rect.set_meta("layer_id", id)
	layer_overlay.add_child(rect)
	layer_rects[id] = {"rect": rect, "layer": layer, "anchor": anchor, "kb": kb}
	if kb != 0:
		# App interactive en overlay (rofi, launcher...): libérer la souris
		# pour qu'elle soit utilisable sur l'overlay au lieu de tourner la
		# caméra FPS. La recapture se fait au unmapped (voir plus bas).
		layer_interact_active = true
		$Player.layer_pointer_active = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		var r := rect.get_global_rect()
		if r.size.x > 0.0 and r.size.y > 0.0:
			Input.warp_mouse(r.get_center())

func _remove_layer_popups_for(layer_id: int) -> void:
	for pid in layer_popup_rects.keys():
		var entry = layer_popup_rects[pid]
		if entry.parent_layer_id == layer_id:
			if is_instance_valid(entry.rect):
				entry.rect.queue_free()
			layer_popup_rects.erase(pid)

func _any_interactive_layer() -> bool:
	for lid in layer_rects:
		var entry = layer_rects[lid]
		if int(entry.get("kb", 0)) != 0:
			return true
	return false

func _toggle_layer_interact() -> void:
	# Si un overlay interactif (rofi...) a le focus clavier, la touche lui
	# est routée par _input : ne pas basculer le mode souris par-dessus.
	if _any_interactive_layer() and compositor.get_keyboard_focus_layer_id() >= 0:
		return
	if layer_interact_active:
		layer_interact_active = false
		$Player.layer_pointer_active = false
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		layer_interact_active = true
		$Player.layer_pointer_active = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_layer_surface_unmapped(id: int) -> void:
	_remove_layer_popups_for(id)
	if layer_rects.has(id):
		var entry = layer_rects[id]
		if is_instance_valid(entry.rect):
			entry.rect.queue_free()
		layer_rects.erase(id)
	# Plus aucune app interactive en overlay → retour en mode FPS, sauf si on
	# est dans un autre mode qui gère déjà la souris (focus, menus).
	if not layer_interact_manual and not _any_interactive_layer() \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
			and not focus_mode and not pause_menu.visible and not window_menu.visible:
		layer_interact_active = false
		$Player.layer_pointer_active = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_layer_surface_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not layer_rects.has(id):
		return
	var entry = layer_rects[id]
	entry.rect.texture = texture
	var mat := entry.rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("u_tex", texture)
		mat.set_shader_parameter("u_content_size", Vector2(width, height))
	# Taille réelle du buffer capturé (peut dépasser la géométrie logique
	# du signal mapped, GTK/Qt ajoutent une marge d'ombre). Le TextureRect
	# garde la position calculée par le compositeur, seules les dimensions
	# servent à la conversion souris -> coordonnées de surface.
	entry.rect.set_meta("surface_size", Vector2(width, height))
	# Le layout peut évoluer après le map (une autre layer surface qui se
	# mappe, un redimensionnement du client...): re-synchroniser la
	# position/taille calculée côté compositeur.
	var info := compositor.get_layer_surface_info(id)
	if not info.is_empty():
		entry.rect.position = Vector2(info["x"], info["y"])
		entry.rect.size = Vector2(max(int(info["width"]), 1), max(int(info["height"]), 1))

func _on_layer_popup_mapped(popup_id: int, parent_layer_id: int, x: int, y: int, w: int, h: int) -> void:
	if not layer_rects.has(parent_layer_id):
		return
	var parent_entry = layer_rects[parent_layer_id]
	var rect := TextureRect.new()
	rect.texture = null
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.position = parent_entry.rect.position + Vector2(x, y)
	rect.size = Vector2(max(w, 1), max(h, 1))
	rect.z_index = _layer_z_index(LAYER_OVERLAY, true)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = layer_shader
	mat.set_shader_parameter("u_content_size", Vector2(w, h))
	rect.material = mat
	rect.set_meta("popup_id", popup_id)
	layer_overlay.add_child(rect)
	layer_popup_rects[popup_id] = {"rect": rect, "parent_layer_id": parent_layer_id}

# ----------------------------------------------------------------------
# Session lock (ext-session-lock-v1): le lockscreen quickshell/dms est
# affiché plein écran (z_index SESSION_LOCK_Z, au-dessus de tout) et
# reçoit tout l'input — pointeur ET clavier — jusqu'à l'unlock.
# ----------------------------------------------------------------------

func _on_session_lock_locked() -> void:
	session_locked = true
	session_lock_surface_id = -1
	if session_lock_rect == null or not is_instance_valid(session_lock_rect):
		session_lock_rect = TextureRect.new()
		session_lock_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		session_lock_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		session_lock_rect.stretch_mode = TextureRect.STRETCH_SCALE
		session_lock_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		session_lock_rect.z_index = SESSION_LOCK_Z
		var mat := ShaderMaterial.new()
		mat.shader = layer_shader
		session_lock_rect.material = mat
		layer_overlay.add_child(session_lock_rect)
	# Le lockscreen détient la souris et le clavier jusqu'à l'unlock.
	layer_interact_active = true
	$Player.layer_pointer_active = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _on_session_lock_unlocked() -> void:
	session_locked = false
	session_lock_surface_id = -1
	if session_lock_rect != null and is_instance_valid(session_lock_rect):
		session_lock_rect.queue_free()
		session_lock_rect = null
	# Retour à l'état normal (capture FPS) sauf si un overlay interactif
	# ou un autre mode gère déjà la souris.
	if not _any_interactive_layer() \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
			and not focus_mode and not pause_menu.visible and not window_menu.visible:
		layer_interact_active = false
		$Player.layer_pointer_active = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_session_lock_surface_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	session_lock_surface_id = id
	if session_lock_rect == null or not is_instance_valid(session_lock_rect):
		return
	session_lock_rect.texture = texture
	var mat := session_lock_rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("u_tex", texture)
		mat.set_shader_parameter("u_content_size", Vector2(width, height))

# La layer surface la plus en avant contenant pos (les popups de layer
# passent devant les layer surfaces, elles-mêmes devant les fenêtres 3D).
# À z égal, on préfère une surface keyboard-interactive : les surfaces
# décoratives plein écran (dms:frame, mask vide, kb=0) captureraient sinon
# tout l'input d'une app interactive du même layer (le launcher dms:spotlight).
func _layer_at(pos: Vector2) -> Dictionary:
	var best := {}
	var best_z := -1
	var best_interactive := false
	for pid in layer_popup_rects:
		var entry = layer_popup_rects[pid]
		if is_instance_valid(entry.rect) and entry.rect.get_global_rect().has_point(pos):
			var z: int = entry.rect.z_index
			if z > best_z or (z == best_z and not best_interactive):
				best_z = z
				best_interactive = true
				best = {"kind": "layer_popup", "id": pid, "rect": entry.rect}
	for lid in layer_rects:
		var entry = layer_rects[lid]
		if is_instance_valid(entry.rect) and entry.rect.get_global_rect().has_point(pos):
			var z: int = entry.rect.z_index
			var interactive: bool = int(entry.get("kb", 0)) != 0
			if z > best_z or (z == best_z and interactive and not best_interactive):
				best_z = z
				best_interactive = interactive
				best = {"kind": "layer", "id": lid, "rect": entry.rect}
	return best

# Conversion position souris -> coordonnées de surface (pixels buffer).
func _layer_uv(hit: Dictionary, pos: Vector2) -> Vector2:
	var rect: TextureRect = hit.rect
	var local: Rect2 = rect.get_global_rect()
	var size_px: Vector2 = rect.get_meta("surface_size", rect.size)
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		return Vector2(
			(pos.x - local.position.x) / rect.size.x * size_px.x,
			(pos.y - local.position.y) / rect.size.y * size_px.y
		)
	return Vector2.ZERO

func _handle_layer_pointer(hit: Dictionary, mouse_pos: Vector2) -> void:
	var uv := _layer_uv(hit, mouse_pos)
	if hit.kind == "layer_popup":
		compositor.forward_pointer_motion_popup(hit.id, uv.x, uv.y)
		if Input.is_action_just_pressed("left_click", true):
			compositor.forward_pointer_button_popup(hit.id, 0x110, true)
		if Input.is_action_just_released("left_click", true):
			compositor.forward_pointer_button_popup(hit.id, 0x110, false)
		if Input.is_action_just_pressed("right_click", true):
			compositor.forward_pointer_button_popup(hit.id, 0x111, true)
		if Input.is_action_just_released("right_click", true):
			compositor.forward_pointer_button_popup(hit.id, 0x111, false)
		return
	compositor.forward_pointer_motion_layer(hit.id, uv.x, uv.y)
	if Input.is_action_just_pressed("left_click", true):
		compositor.forward_pointer_button_layer(hit.id, 0x110, true)
	if Input.is_action_just_released("left_click", true):
		compositor.forward_pointer_button_layer(hit.id, 0x110, false)
	if Input.is_action_just_pressed("right_click", true):
		compositor.forward_pointer_button_layer(hit.id, 0x111, true)
	if Input.is_action_just_released("right_click", true):
		compositor.forward_pointer_button_layer(hit.id, 0x111, false)
	if Input.is_action_just_pressed("scroll_up", true):
		compositor.forward_pointer_axis_layer(hit.id, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down", true):
		compositor.forward_pointer_axis_layer(hit.id, 0, 50.0)

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

# Vrai quand un overlay keyboard-interactive (rofi, waybar...) détient le
# focus clavier : les touches sont routées vers lui, aucun bind du jeu ne
# doit se déclencher.
func _keyboard_busy() -> bool:
	return compositor.get_keyboard_focus_layer_id() >= 0

# Détecte si l'événement correspond à un custom bind et lance sa commande.
# Renvoie true si l'événement a été consommé.
func _try_custom_bind(event: InputEvent) -> bool:
	if _keyboard_busy() or interact_mode_active:
		return false
	var binds: Array = pause_menu.get_custom_binds()
	for bind in binds:
		if not bind is Dictionary:
			continue
		var command: String = bind.get("command", "")
		if command == "":
			continue
		var matched := false
		if bind.get("type", "") == "mouse":
			if event is InputEventMouseButton and event.pressed:
				matched = event.button_index == int(bind.get("code", -1)) \
					and _event_matches_mods(event, bind.get("mods", {}))
		else:
			if event is InputEventKey and event.pressed and not event.echo:
				var kev := event as InputEventKey
				var code := kev.physical_keycode
				if code == 0:
					code = kev.keycode
				matched = code == int(bind.get("code", 0)) \
					and _event_matches_mods(kev, bind.get("mods", {}))
		if matched:
			compositor.launch_app(command)
			return true
	return false

# Vrai si les modificateurs de l'événement correspondent exactement à ceux du bind.
func _event_matches_mods(event: InputEvent, mods: Dictionary) -> bool:
	var ev := event as InputEventWithModifiers
	if ev == null:
		return mods.is_empty()
	return ev.ctrl_pressed == mods.get("ctrl", false) \
		and ev.shift_pressed == mods.get("shift", false) \
		and ev.alt_pressed == mods.get("alt", false) \
		and ev.meta_pressed == mods.get("super", false)

func _process(delta: float) -> void:
	_update_xray(delta)
	_update_flashes(delta)

	# Suivi de l'icône de drag-and-drop
	if drag_icon_rect and drag_icon_rect.visible:
		var mouse_pos := get_viewport().get_mouse_position()
		drag_icon_rect.position = mouse_pos - drag_icon_size / 2.0

	# Session verrouillée : tout le pointeur part vers la surface de
	# verrouillage (le curseur y est visible), rien ne va au jeu.
	if session_locked:
		var _mp := get_viewport().get_mouse_position()
		compositor.forward_pointer_motion_lock(_mp.x, _mp.y)
		if Input.is_action_just_pressed("left_click", true):
			compositor.forward_pointer_button_lock(0x110, true)
		if Input.is_action_just_released("left_click", true):
			compositor.forward_pointer_button_lock(0x110, false)
		if Input.is_action_just_pressed("right_click", true):
			compositor.forward_pointer_button_lock(0x111, true)
		if Input.is_action_just_released("right_click", true):
			compositor.forward_pointer_button_lock(0x111, false)
		if Input.is_action_just_pressed("scroll_up", true):
			compositor.forward_pointer_axis_lock(0.0, -50.0)
		if Input.is_action_just_pressed("scroll_down", true):
			compositor.forward_pointer_axis_lock(0.0, 50.0)
		return

	if Input.is_action_just_pressed("window_menu", true) and not interact_mode_active and not focus_mode and not _keyboard_busy():
		window_menu.toggle_menu()

	# Tab : bascule le mode "interaction layer" — libère la souris pour
	# survoler/cliquer waybar, quickshell ou les overlays non interactifs
	# (sinon elle est capturée et fait tourner la caméra FPS).
	if Input.is_action_just_pressed("layer_interact", true) and not interact_mode_active and not focus_mode and not _keyboard_busy():
		_toggle_layer_interact()
		if layer_interact_active:
			layer_interact_manual = true
		else:
			layer_interact_manual = false

	# Si la souris est repassée en mode FPS autrement (clic hors overlay,
	# fermeture d'un overlay interactif...), resynchroniser l'état.
	#if layer_interact_active and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		#layer_interact_active = false

	if window_menu.visible:
		return

	# Mode focus: F pour sortir, sinon router les inputs souris/clavier
	if focus_mode:
		if Input.is_action_just_pressed("focus_window"):
			_exit_focus_mode()
			return
		_handle_focus_input()
		return

	# Layer surfaces (waybar/rofi): quand la souris est visible et survole
	# une layer surface ou son popup, on forward l'input vers elle et on
	# laisse le raycast 3D de côté (les overlays 2D passent devant la scène).
	if not pause_menu.visible and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and (not layer_rects.is_empty() or not layer_popup_rects.is_empty()):
		var _mouse_pos := get_viewport().get_mouse_position()
		var hit := _layer_at(_mouse_pos)
		# Signale à player.gd si la souris est sur une layer : le prochain
		# clic ne doit pas recapturer la souris mais partir vers l'overlay.
		#$Player.layer_pointer_active = not hit.is_empty()
		if not hit.is_empty():
			_handle_layer_pointer(hit, _mouse_pos)
			return
	#else:
		#$Player.layer_pointer_active = false

	# Clavier occupé par un overlay keyboard-interactive (rofi, waybar...):
	# les touches partent vers l'overlay, les binds du jeu (focus, pin,
	# interact_mode, grab...) ne doivent pas se déclencher.
	if _keyboard_busy():
		return

	# F en visant une fenêtre → entrer en mode focus
	if Input.is_action_just_pressed("focus_window", true) and not interact_mode_active:
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
	if Input.is_action_just_pressed("pin_window", true) and not interact_mode_active:
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

	# K en visant une fenêtre → demander sa fermeture (close)
	if Input.is_action_just_pressed("kill_window", true) and not interact_mode_active:
		var cam := $Player/Camera3D
		var mouse_pos := get_viewport().get_mouse_position()
		# En MOUSE_MODE_CAPTURED, get_mouse_position() reste figée au point de
		# capture : le viseur étant au centre du viewport, c'est ce centre qui
		# doit guider le rayon (comme le raycast pointeur principal).
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			mouse_pos = get_viewport().get_visible_rect().size / 2.0
		var ray_origin = cam.project_ray_origin(mouse_pos)
		var ray_dir = cam.project_ray_normal(mouse_pos)
		var to = ray_origin + ray_dir * 1000.0
		var space := get_world_3d().direct_space_state
		var params := PhysicsRayQueryParameters3D.create(ray_origin, to)
		var hit := space.intersect_ray(params)
		if not hit.is_empty():
			var body: Node3D = hit.collider
			if body.has_meta("window_id"):
				compositor.close_window(body.get_meta("window_id"))
				return

	# On inverse l'état du mode interaction à chaque fois que la touche est pressée
	if Input.is_action_just_pressed("interact_mode", true):
		if interact_mode_active:
			compositor.release_all_keys()
		interact_mode_active = not interact_mode_active
		$Player.interact_mode_active = not $Player.interact_mode_active

	var cam: Camera3D = $Player/Camera3D
	var mouse_pos := get_viewport().get_mouse_position()
	# En MOUSE_MODE_CAPTURED (souris FPS), get_mouse_position() reste figée
	# à l'endroit où le curseur était au moment de la capture — pas au centre
	# de l'écran. Le viseur est au centre du viewport : c'est donc ce centre
	# qui doit guider le rayon, sinon les clics sont décalés d'autant.
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		mouse_pos = get_viewport().get_visible_rect().size / 2.0
	var ray_origin := cam.project_ray_origin(mouse_pos)
	var ray_dir := cam.project_ray_normal(mouse_pos)

	# Une prise en cours (déplacement/redimensionnement) continue d'être mise
	# à jour même si le viseur ne pointe plus sur la fenêtre: en
	# MOUSE_MODE_CAPTURED (souris FPS), get_viewport().get_mouse_position()
	# reste figée au centre de l'écran - seule l'orientation de la caméra
	# bouge - donc on pilote le drag via le rayon caméra, pas via une
	# position écran qui ne varie jamais pendant le drag.
	if is_moving:
		if Input.is_action_just_pressed("scroll_up", true):
			move_depth += 0.25
		if Input.is_action_just_pressed("scroll_down", true):
			move_depth -= 0.25
		_update_move(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("grab", true):
			is_moving = false
			active_window_id = -1
		return
	if is_resizing:
		_update_resize(ray_origin, ray_dir)
		if Input.is_action_just_released("left_click", true):
			is_resizing = false
			resizing_edge = ""
			active_window_id = -1
		return
	if is_moving_2d:
		_update_move_2d(ray_origin, ray_dir, delta)
		if Input.is_action_just_released("left_click", true):
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
		_handle_popup_pointer(body, hit, ray_origin, ray_dir)
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
	compositor.forward_pointer_motion(wid,
		uv.x * win_size.x + content_offset_fwd.x,
		uv.y * win_size.y + content_offset_fwd.y)

	if Input.is_action_just_pressed("grab", true) and not interact_mode_active:
		active_window_id = wid
		is_moving = true
		move_depth = cam.global_position.distance_to(quad.global_position)
	if Input.is_action_just_released("grab", true):
		active_window_id = wid
		is_moving = false
		move_depth = 0.0
	if Input.is_action_just_pressed("left_click", true):
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
	if Input.is_action_just_released("left_click", true):
		compositor.forward_pointer_button(wid, 0x110, false)

	if Input.is_action_just_pressed("right_click", true):
		focused_window_id = wid
		compositor.forward_pointer_button(wid, 0x111, true)
	if Input.is_action_just_released("right_click", true):
		compositor.forward_pointer_button(wid, 0x111, false)

	if Input.is_action_just_pressed("scroll_up", true):
		compositor.forward_pointer_axis(wid, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down", true):
		compositor.forward_pointer_axis(wid, 0, 50.0)

# Hover + clic gauche sur un popup (menu, dropdown) - même calcul d'uv que
# pour une fenêtre, mais routé vers forward_pointer_motion_popup/
# forward_pointer_button_popup puisqu'un popup n'a pas de window_id.
#
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

func _handle_popup_pointer(body: StaticBody3D, hit: Dictionary, ray_origin: Vector3, ray_dir: Vector3) -> void:
	var quad: MeshInstance3D = body.get_parent()
	var win_size: Vector2 = body.get_meta("surface_size", Vector2(1, 1))
	var mesh: QuadMesh = quad.mesh

	# Même correction que pour une fenêtre : l'UV se calcule sur le plan
	# visuel du quad, pas sur la face avant du boîtier de collision.
	var uv := _uv_at_plane(quad, mesh, ray_origin, ray_dir, hit.position)
	var pid: int = body.get_meta("popup_id")
	compositor.forward_pointer_motion_popup(pid, uv.x * win_size.x, uv.y * win_size.y)

	if Input.is_action_just_pressed("left_click", true):
		compositor.forward_pointer_button_popup(pid, 0x110, true)
	if Input.is_action_just_released("left_click", true):
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

	# Session verrouillée : tout le clavier part vers le lockscreen (le
	# champ password de quickshell), aucun bind du jeu ne doit répondre.
	if session_locked and event is InputEventKey:
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
		return

	# Une layer surface keyboard-interactive (rofi, waybar menu) détient le
	# focus clavier : forward vers elle, quel que soit le mode de la souris.
	if event is InputEventKey and compositor.get_keyboard_focus_layer_id() >= 0:
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

	# Custom binds: une touche enregistrée lance une commande/app.
	if not interact_mode_active and not _keyboard_busy() and not window_menu.visible:
		if _try_custom_bind(event):
			get_viewport().set_input_as_handled()
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

func _start_flash(id: int, quad: MeshInstance3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.4, .4)
	mat.no_depth_test = true
	mat.render_priority = 10
	quad.material_overlay = mat
	flash_windows[id] = {"mat": mat, "elapsed": 0.0}

func _end_flash(id: int) -> void:
	if not flash_windows.has(id):
		return
	var entry: Dictionary = flash_windows[id]
	if quads.has(id) and is_instance_valid(quads[id]):
		quads[id].material_overlay = null
	flash_windows.erase(id)

func _update_flashes(delta: float) -> void:
	if flash_windows.is_empty():
		return
	for id in flash_windows.keys():
		var entry: Dictionary = flash_windows[id]
		entry["elapsed"] += delta
		var t: float = entry["elapsed"] / FLASH_DURATION
		if t >= 1.0:
			_end_flash(id)
		else:
			var mat: StandardMaterial3D = entry.get("mat")
			if mat:
				mat.albedo_color.a = (1.0 - t) * 0.9

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
