extends Node3D
## Mode focus : affiche une fenêtre en 2D plein écran (TextureRect) et route
## tout l'input clavier + souris vers elle, jusqu'à la sortie avec F.
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const FOCUS_Z_BASE := 2000 # au-dessus des layer surfaces et de leurs popups
const FOCUS_POPUP_Z := FOCUS_Z_BASE + 50

# Recadre la texture de capture sur la zone de contenu réelle. Le buffer
# d'allocation (VkImage / offscreen) est arrondi au palier supérieur
# (round_up_capture_size, multiple de 64) alors que le signal ne reporte
# que la taille du contenu : sans recadrage, le UV [0,1] couvre la totalité
# de la texture (zone transparente incluse) et STRETCH_SCALE écrase l'image.
# TEXTURE = le TextureRect.texture (le contrôle ne dessine que s'il est
# renseigné) ; la texture de capture est réutilisée telle quelle.
const POPUP_CROP_SHADER_CODE = """
shader_type canvas_item;
uniform vec2 content_size = vec2(0.0, 0.0);

void fragment() {
	vec2 ts = vec2(textureSize(TEXTURE, 0));
	vec2 mapped_uv = (ts.x > 0.0 && ts.y > 0.0 && content_size.x > 0.0)
		? UV * content_size / ts : UV;
	COLOR = texture(TEXTURE, mapped_uv);
}
"""

var popup_crop_shader: Shader

var compositor: WlrCompositor
var player: Node3D
var ui: CanvasLayer
var windows: Node3D

var focus_mode := false
var focus_window_id := -1
var focus_texture_rect: TextureRect
var focus_surface_size := Vector2.ZERO
var focus_content_offset := Vector2.ZERO
var focus_content_size := Vector2.ZERO
var focus_mouse_captured := false
var focus_mouse_uv := Vector2(0.5, 0.5) # position tracking en mode capturé
var focus_popup_rects: Dictionary = {} # popup_id (int) -> TextureRect overlay en mode focus

func setup(compositor_ref: WlrCompositor, player_ref: Node3D, ui_ref: CanvasLayer, windows_ref: Node3D) -> void:
	compositor = compositor_ref
	player = player_ref
	ui = ui_ref
	windows = windows_ref

	popup_crop_shader = Shader.new()
	popup_crop_shader.code = POPUP_CROP_SHADER_CODE

	# TextureRect plein écran pour le mode focus
	focus_texture_rect = TextureRect.new()
	focus_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	focus_texture_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	focus_texture_rect.visible = false
	focus_texture_rect.z_index = FOCUS_Z_BASE
	focus_texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(focus_texture_rect)

func is_active() -> bool:
	return focus_mode

func get_focus_window_id() -> int:
	return focus_window_id

func enter_focus(id: int) -> void:
	if not windows.quads.has(id) or not is_instance_valid(windows.quads[id]):
		return
	focus_mode = true
	focus_window_id = id
	windows.focused_window_id = id
	focus_mouse_captured = false
	focus_mouse_uv = Vector2(0.5, 0.5)

	# Passer la fenêtre en plein écran pendant le mode focus
	compositor.set_window_fullscreen(id, true)

	# Récupérer la texture courante depuis le quad 3D
	var info: Dictionary = windows.get_quad_info(id)
	focus_texture_rect.texture = info.get("texture")
	focus_surface_size = info.get("surface_size", Vector2(1, 1))
	focus_content_offset = info.get("content_offset", Vector2.ZERO)
	focus_content_size = info.get("content_size", focus_surface_size)

	# Cacher le quad 3D, afficher le overlay 2D
	windows.set_quad_visible(id, false)
	focus_texture_rect.visible = true

	# Libérer la souris pour interagir avec la fenêtre, centrée sur l'écran
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)

	# Créer les overlays pour les popups déjà ouverts de cette fenêtre
	for popup_id in windows.popup_parent_info:
		var pinfo = windows.popup_parent_info[popup_id]
		if pinfo.parent_window_id == focus_window_id or \
			(pinfo.parent_popup_id != -1 and focus_popup_rects.has(pinfo.parent_popup_id)):
			_create_popup_overlay(popup_id, pinfo.parent_window_id, pinfo.parent_popup_id,
				pinfo.x, pinfo.y, pinfo.width, pinfo.height)

	# Bloquer le player
	player.focus_mode_active = true

func exit_focus() -> void:
	if not focus_mode:
		return

	compositor.release_all_keys()

	# Sortir la fenêtre du plein écran
	if focus_window_id != -1:
		compositor.set_window_fullscreen(focus_window_id, false)

	# Réafficher le quad 3D
	windows.set_quad_visible(focus_window_id, true)

	# Cacher le overlay, libérer la texture
	focus_texture_rect.visible = false
	focus_texture_rect.texture = null
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
	player.focus_mode_active = false

func on_window_unmapped(id: int) -> void:
	if focus_mode and focus_window_id == id:
		exit_focus()

func on_pointer_lock_changed(window_id: int, locked: bool) -> void:
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

func on_window_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not focus_mode or id != focus_window_id:
		return
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

func on_popup_mapped(id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, width: int, height: int) -> void:
	if not focus_mode:
		return
	_create_popup_overlay(id, parent_window_id, parent_popup_id, x, y, width, height)

func on_popup_unmapped(id: int) -> void:
	if focus_popup_rects.has(id):
		if is_instance_valid(focus_popup_rects[id]):
			focus_popup_rects[id].queue_free()
		focus_popup_rects.erase(id)

func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not focus_popup_rects.has(id) or not is_instance_valid(focus_popup_rects[id]):
		return
	var popup_tex_rect: TextureRect = focus_popup_rects[id]
	# texture = propriété du TextureRect : sans elle le contrôle ne dessine
	# pas ; le shader échantillonne ce TEXTURE avec le recadrage.
	popup_tex_rect.texture = texture
	var mat: ShaderMaterial = popup_tex_rect.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("content_size", Vector2(width, height))
	popup_tex_rect.set_meta("content_size", Vector2(width, height))
	# Recalculer la taille avec le scale du parent
	if windows.popup_parent_info.has(id):
		var info = windows.popup_parent_info[id]
		var layout := _compute_popup_layout(info.parent_window_id, info.parent_popup_id)
		if layout.is_empty():
			return
		var popup_scale: Vector2 = layout["scale"]
		var popup_offset: Vector2 = layout["offset"]
		# width/height (signal) = taille du contenu réel, à la différence de
		# info.width/height qui vient de popup_mapped (géométrie logique).
		popup_tex_rect.size = Vector2(width, height) * popup_scale
		popup_tex_rect.position = popup_offset + Vector2(info.x, info.y) * popup_scale

func _compute_popup_layout(parent_window_id: int, parent_popup_id: int) -> Dictionary:
	"""Scale/offset du popup dans l'espace écran du mode focus."""
	if parent_popup_id != -1 and focus_popup_rects.has(parent_popup_id):
		var parent_rect: TextureRect = focus_popup_rects[parent_popup_id]
		var p_content: Vector2 = parent_rect.get_meta("content_size", parent_rect.size)
		return {
			"scale": Vector2(
				parent_rect.size.x / max(p_content.x, 1.0),
				parent_rect.size.y / max(p_content.y, 1.0)),
			"offset": parent_rect.position,
		}
	elif focus_mode and parent_window_id == focus_window_id:
		return _compute_focus_displayed_info()
	return {}

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

func _create_popup_overlay(popup_id: int, parent_window_id: int, parent_popup_id: int, x: int, y: int, pw: int, ph: int) -> void:
	"""Crée un TextureRect overlay pour un popup en mode focus."""
	var layout := _compute_popup_layout(parent_window_id, parent_popup_id)
	if layout.is_empty():
		return
	var popup_scale: Vector2 = layout["scale"]
	var popup_offset: Vector2 = layout["offset"]

	var popup_tex_rect := TextureRect.new()
	# EXPAND_IGNORE_SIZE permet d'imposer exactement la taille calculée
	popup_tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# STRETCH_SCALE étire la texture exactement aux bornes du Control ; le
	# shader de recadrage garantit que seul le contenu (pas la zone de
	# padding du buffer arrondi) est étiré.
	popup_tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	popup_tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Force le filtre linéaire pour éviter le flou de scaling de l'UI 2D
	popup_tex_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	var mat := ShaderMaterial.new()
	mat.shader = popup_crop_shader
	mat.set_shader_parameter("content_size", Vector2(pw, ph))
	popup_tex_rect.material = mat

	popup_tex_rect.size = Vector2(pw, ph) * popup_scale
	popup_tex_rect.position = popup_offset + Vector2(x, y) * popup_scale
	popup_tex_rect.z_index = FOCUS_POPUP_Z
	popup_tex_rect.set_meta("content_size", Vector2(pw, ph))
	ui.add_child(popup_tex_rect)
	focus_popup_rects[popup_id] = popup_tex_rect

	# Appliquer la texture disponible dès maintenant
	if windows.popup_quads.has(popup_id) and is_instance_valid(windows.popup_quads[popup_id]):
		var quad: MeshInstance3D = windows.popup_quads[popup_id]
		var qmat: ShaderMaterial = quad.material_override as ShaderMaterial
		if qmat:
			var tex: Texture2D = qmat.get_shader_parameter("window_texture")
			if tex:
				popup_tex_rect.texture = tex

# Routage souris/clavier du mode focus, appelé chaque frame par
# wayland_room.gd tant que le mode est actif.
func handle_focus_input() -> void:
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

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button(focus_window_id, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(focus_window_id, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		compositor.forward_pointer_button(focus_window_id, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(focus_window_id, 0x111, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(focus_window_id, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(focus_window_id, 0, 100.0)

# Gère un InputEvent en mode focus (clavier + tracking souris capturée).
# Renvoie true si l'événement a été consommé (toujours le cas en mode focus).
func handle_input_event(event: InputEvent) -> bool:
	if not focus_mode or focus_window_id == -1:
		return false
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# Raccourcis clavier gérés par le jeu lui-même (SUPER+F = sortir du
		# focus, la touche de fermeture de la fenêtre) : les consommer SANS
		# les forwarder au client. Sinon la touche est tapée dans la fenêtre
		# avant que l'action (exit_focus / close_window) ne s'exécute dans
		# _process. event_is_action couvre l'appui ET le relâchement (et les
		# echoes) avec les modifieurs exacts du raccourci.
		if _is_compositor_shortcut(key_event):
			return true
		var code = key_event.physical_keycode
		if code == 0:
			code = key_event.keycode
		if key_event.unicode == 60 or code == 167:
			code = KEY_LESS
		elif key_event.unicode == 62:
			code = KEY_GREATER
		compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
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
	return true

# True si l'événement clavier correspond à un raccourci géré par le jeu
# (et non par le client) pendant le mode focus : la touche ne doit pas
# être forwardée. Les actions sont celles vérifiées dans _process de
# wayland_room.gd (sortie de focus, fermeture de la fenêtre).
func _is_compositor_shortcut(event: InputEventKey) -> bool:
	for action in ["focus_window", "kill_window"]:
		if InputMap.event_is_action(event, action, false):
			return true
	return false
