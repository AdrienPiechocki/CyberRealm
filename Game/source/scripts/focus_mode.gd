extends Node3D
## Mode focus : affiche une fenêtre en 2D plein écran (TextureRect) et route
## tout l'input clavier + souris vers elle, jusqu'à la sortie (même raccourci
## que l'entrée, ex. Super+F).
## Gère une PILE de fenêtres : une nouvelle fenêtre ouverte pendant le mode
## focus s'ajoute par-dessus la fenêtre active (auto via window_mapped, voir
## wayland_room.gd) ; la fermeture de la fenêtre active (kill) fait retomber
## le focus sur la précédente. Chaque fenêtre conserve son propre état (taille
## d'origine, position du curseur, pointer lock, popups).
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const FOCUS_Z_BASE := 2000 # au-dessus des layer surfaces et de leurs popups
const FOCUS_POPUP_Z := FOCUS_Z_BASE + 50

# Écart (m) entre les fenêtres de la pile à la sortie du mode focus : chacune
# est posée STACK_Z_OFFSET devant la précédente, vers la caméra.
const STACK_Z_OFFSET := -0.1

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
# Pile des fenêtres focalisées : le DERNIER élément est la fenêtre active
# (celle qui reçoit l'input et dont l'overlay est au-dessus des autres).
var focus_stack: Array = []
# window_id (int) -> TextureRect plein écran affichant la fenêtre en overlay 2D.
var focus_rects: Dictionary = {}
# window_id (int) -> état propre à la fenêtre : original_size, mouse_captured,
# mouse_uv, surface_size, content_offset, content_size.
var focus_states: Dictionary = {}
# La seule fenêtre de la pile passée en plein écran côté compositeur (la
# première entrée en focus). Les suivantes conservent leur taille d'origine.
var focus_fullscreen_id := -1
# popup_id (int) -> TextureRect overlay en mode focus. Seuls les popups de la
# fenêtre ACTIVE sont overlayés : les fenêtres du dessous sont couvertes par
# l'overlay actif et leurs popups sont recréés à la réactivation.
var focus_popup_rects: Dictionary = {}

# DEBUG temporaire (CYBERREALM_INPUT_DEBUG=1) : log des transitions de lock et
# de ce qui est forwardé. CYBERREALM_FORCE_VISIBLE=1 : ignore le pointer lock et
# reste sur le chemin "souris visible" (pour tester l'hypothèse du chemin LOCKED).
var input_debug := false
var force_visible := false
var _dbg_rel_sum := Vector2.ZERO
var _dbg_rel_count := 0
var _dbg_last_log := 0.0

# Curseur custom de la fenêtre active dessiné en overlay 2D (TextureRect
# positionné sur le pointeur). Contrairement à Input.set_custom_mouse_cursor
# (curseur KWin, qui peut se réinitialiser et laisser la flèche système
# réapparaître), l'overlay est composité dans le viewport : il reste affiché
# tant que le compositeur conserve l'image capturée. cursor_overlay_serial =
# serial de la dernière image appliquée (-1 si aucune) ; on ne re-crée la
# texture que quand le client en pose une nouvelle (commits de la surface).
var cursor_overlay: TextureRect
var cursor_overlay_tex: ImageTexture
var cursor_overlay_serial := -1

func setup(compositor_ref: WlrCompositor, player_ref: Node3D, ui_ref: CanvasLayer, windows_ref: Node3D) -> void:
	compositor = compositor_ref
	player = player_ref
	ui = ui_ref
	windows = windows_ref

	popup_crop_shader = Shader.new()
	popup_crop_shader.code = POPUP_CROP_SHADER_CODE
	input_debug = OS.get_environment("CYBERREALM_INPUT_DEBUG") == "1"
	force_visible = OS.get_environment("CYBERREALM_FORCE_VISIBLE") == "1"

	cursor_overlay = TextureRect.new()
	cursor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cursor_overlay.z_index = FOCUS_POPUP_Z + 50
	cursor_overlay.visible = false
	ui.add_child(cursor_overlay)

func is_active() -> bool:
	return focus_mode

func get_focus_window_id() -> int:
	return _active_id()

func _active_id() -> int:
	return focus_stack[-1] if not focus_stack.is_empty() else -1

func _state(id: int) -> Dictionary:
	if not focus_states.has(id):
		focus_states[id] = {
			"original_size": Vector2.ONE,
			"mouse_captured": false,
			"mouse_uv": Vector2(0.5, 0.5),
			"surface_size": Vector2(1, 1),
			"content_offset": Vector2.ZERO,
			"content_size": Vector2(1, 1),
		}
	return focus_states[id]

func enter_focus(id: int) -> void:
	if not windows.quads.has(id) or not is_instance_valid(windows.quads[id]):
		return
	if focus_stack.has(id):
		return
	var entering := not focus_mode
	focus_mode = true
	focus_stack.append(id)

	var info: Dictionary = windows.get_quad_info(id)
	var st := _state(id)
	st["mouse_captured"] = false
	st["mouse_uv"] = Vector2(0.5, 0.5)
	st["original_size"] = info.get("surface_size", Vector2(1, 1))

	# Passer en plein écran côté compositeur : seule la première fenêtre de la
	# pile l'est ; les suivantes conservent leur taille (leur overlay 2D plein
	# écran les affiche quand même à l'écran).
	if focus_fullscreen_id == -1:
		compositor.set_window_fullscreen(id, true)
		focus_fullscreen_id = id

	# TextureRect dédié à cette fenêtre : la première (plein écran) couvre
	# tout l'écran, les suivantes sont centrées à taille naturelle (la
	# fenêtre plein écran reste visible autour). L'overlay de la fenêtre
	# active porte le z le plus haut (FOCUS_Z_BASE + position dans la pile).
	var is_fullscreen := focus_fullscreen_id == id
	var rect := TextureRect.new()
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_PASS
	rect.visible = true
	if is_fullscreen:
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.z_index = FOCUS_Z_BASE + focus_stack.size()
	ui.add_child(rect)
	focus_rects[id] = rect

	# Récupérer la texture courante depuis le quad 3D
	rect.texture = info.get("texture")
	st["surface_size"] = info.get("surface_size", Vector2(1, 1))
	st["content_offset"] = info.get("content_offset", Vector2.ZERO)
	st["content_size"] = info.get("content_size", st["surface_size"])
	_refresh_rect_layout(id)

	# Cacher le quad 3D, l'overlay 2D prend le relais
	windows.set_quad_visible(id, false)

	# Bloquer le player à la première entrée en mode focus
	if entering:
		player.focus_mode_active = true

	_activate_window(id)

func exit_focus() -> void:
	if not focus_mode:
		return

	compositor.release_all_keys()

	# Restaurer la fenêtre passée en plein écran (seule la première de la pile
	# l'était) et réafficher les quads 3D de toute la pile. Les fenêtres déjà
	# fermées (kill) ne sont plus dans quads et sont ignorées.
	if focus_fullscreen_id != -1 and windows.quads.has(focus_fullscreen_id) \
		and is_instance_valid(windows.quads[focus_fullscreen_id]):
		compositor.set_window_fullscreen(focus_fullscreen_id, false)
		var st := _state(focus_fullscreen_id)
		compositor.set_window_size(focus_fullscreen_id, int(st["original_size"].x), int(st["original_size"].y))
	# Réafficher les quads 3D en les empilant l'un devant l'autre : la
	# première fenêtre garde sa position, chacune des suivantes est posée
	# STACK_Z_OFFSET devant la précédente (le long de la normale du quad,
	# vers la caméra). Les fenêtres déjà fermées (kill) ne sont plus dans
	# quads et sont ignorées.
	var stack_index := 0
	var first_quad: MeshInstance3D = null
	for id in focus_stack:
		if windows.quads.has(id) and is_instance_valid(windows.quads[id]):
			var quad: MeshInstance3D = windows.quads[id]
			if first_quad != null:
				quad.global_basis = first_quad.global_basis
				quad.global_position = first_quad.global_position \
					- first_quad.global_basis.z.normalized() * STACK_Z_OFFSET * stack_index
			else:
				first_quad = quad
			windows.set_quad_visible(id, true)
			stack_index += 1

	_reset_focus_ui()

func on_window_unmapped(id: int) -> void:
	if not focus_mode or not focus_stack.has(id):
		return
	var was_active := id == _active_id()
	focus_stack.erase(id)
	if focus_rects.has(id):
		if is_instance_valid(focus_rects[id]):
			focus_rects[id].queue_free()
		focus_rects.erase(id)
	focus_states.erase(id)
	# Si la fenêtre plein écran quitte la pile, promouvoir la nouvelle
	# première fenêtre : le mode focus garde toujours exactement une fenêtre
	# plein écran côté compositeur.
	if focus_fullscreen_id == id and not focus_stack.is_empty():
		compositor.set_window_fullscreen(focus_stack[0], true)
		focus_fullscreen_id = focus_stack[0]
	if focus_stack.is_empty():
		# Plus aucune fenêtre dans la pile : sortir du mode focus
		compositor.release_all_keys()
		_reset_focus_ui()
	elif was_active:
		# La fenêtre active s'est fermée : retomber sur la précédente
		_activate_window(_active_id())

func on_pointer_lock_changed(window_id: int, locked: bool) -> void:
	# Un jeu a demandé le pointer lock (zwp_pointer_constraints_v1::lock_pointer)
	if not focus_mode or window_id != _active_id():
		return
	var st := _state(window_id)
	if input_debug:
		print("[focus:dbg] lock_changed id=", window_id, " locked=", locked,
			" force_visible=", force_visible, " was_captured=", st["mouse_captured"],
			" uv=", st["mouse_uv"])
	if force_visible:
		st["mouse_captured"] = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	# xwayland-satellite ignore le mouvement relatif (il ne voit que du
	# mouvement absolu) : garder la position réelle du curseur (chemin
	# VISIBLE) même quand le client X11 demande un pointer lock, sinon la
	# position absolue forwardée diverge du curseur réel puis saute
	# (caméra FPS qui "snap-back").
	if compositor.is_window_xwayland(window_id):
		st["mouse_captured"] = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if locked:
		st["mouse_captured"] = true
		_hide_cursor_overlay()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		st["mouse_captured"] = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# Warper le curseur réel sur la position virtuelle courante (mouse_uv)
		# et non au centre : si le client relâche puis re-grab la souris
		# (flap de lock), la position absolue forwardée ne doit pas sauter.
		var rect: TextureRect = focus_rects.get(window_id)
		if rect and is_instance_valid(rect):
			var geometry := _visible_geometry(rect, rect.texture)
			var displayed_size: Vector2 = geometry["displayed_size"]
			if displayed_size.x > 0.0 and displayed_size.y > 0.0:
				Input.warp_mouse(
					geometry["offset"] + Vector2(st["mouse_uv"].x, st["mouse_uv"].y) * displayed_size)
				return
		Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)

# Géométrie de la zone réellement affichée par un TextureRect plein écran
# (displayed_size respectant l'aspect ratio + offset de centrage). Utilisée
# à la fois pour mapper le curseur réel -> UV (branche "souris visible") et
# pour l'inverse UV -> position viewport (warp de continuité au unlock).
func _visible_geometry(rect: TextureRect, tex: Texture2D) -> Dictionary:
	var geometry := {"displayed_size": Vector2.ZERO, "offset": Vector2.ZERO}
	if not tex or not is_instance_valid(rect):
		return geometry
	var tex_size := tex.get_size()
	var tex_rect := rect.get_global_rect()
	var aspect := tex_size.x / tex_size.y
	var rect_aspect := tex_rect.size.x / tex_rect.size.y
	var displayed_size: Vector2
	if aspect > rect_aspect:
		displayed_size = Vector2(tex_rect.size.x, tex_rect.size.x / aspect)
	else:
		displayed_size = Vector2(tex_rect.size.y * aspect, tex_rect.size.y)
	geometry["displayed_size"] = displayed_size
	geometry["offset"] = tex_rect.position + (tex_rect.size - displayed_size) / 2.0
	return geometry

func on_window_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not focus_mode or not focus_rects.has(id):
		return
	focus_rects[id].texture = texture
	# Utiliser la taille réelle de la texture (pas width/height qui
	# sont la taille du contenu). Dans le path Vulkan, le VkImage est
	# alloué plus grand que le contenu (round_up_capture_size) — le
	# UV est calculé depuis tex.get_size(), donc la conversion
	# UV → surface doit utiliser la même base.
	var st := _state(id)
	st["surface_size"] = texture.get_size()
	var geo := compositor.get_window_geometry(id)
	st["content_offset"] = Vector2(geo["x"], geo["y"])
	st["content_size"] = Vector2(geo["width"], geo["height"])
	# Nouvelle fenêtre / resize : ajuster la taille de l'overlay des fenêtres
	# non plein écran à la nouvelle taille de surface.
	_refresh_rect_layout(id)

func _nonfullscreen_display_size(surface_size: Vector2, viewport_size: Vector2) -> Vector2:
	if surface_size.x <= 0.0 or surface_size.y <= 0.0:
		return Vector2.ZERO
	var scale := minf(
		viewport_size.x / surface_size.x,
		viewport_size.y / surface_size.y)
	scale = minf(scale, 1.0)
	return surface_size * scale

func _refresh_rect_layout(id: int) -> void:
	var rect: TextureRect = focus_rects.get(id)
	if not rect or id == focus_fullscreen_id:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var display_size := _nonfullscreen_display_size(_state(id)["surface_size"], viewport_size)
	rect.size = display_size
	rect.position = (viewport_size - display_size) / 2.0

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
	elif focus_mode and parent_window_id == _active_id():
		return _compute_focus_displayed_info()
	return {}

func _compute_focus_displayed_info() -> Dictionary:
	"""Calcule l'offset, la taille et le scale de la zone affichée du TextureRect
	de la fenêtre ACTIVE."""
	var active_id := _active_id()
	if active_id == -1 or not focus_rects.has(active_id):
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var rect: TextureRect = focus_rects[active_id]
	var tex := rect.texture
	if not tex:
		return {"offset": Vector2.ZERO, "size": Vector2.ZERO, "scale": Vector2.ONE}
	var tex_size := tex.get_size()
	var tex_rect := rect.get_global_rect()
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

# Rend la fenêtre courante de la pile la fenêtre active : met à jour le focus
# clavier 3D, l'état de la souris et les popups overlayés (seuls ceux de la
# fenêtre active sont affichés).
func _activate_window(id: int) -> void:
	windows.focused_window_id = id
	# Donner le focus clavier du seat à la fenêtre : les touches forwardées
	# par forward_keyboard_key partent vers la surface qui détient le focus
	# clavier (pas vers un window_id). Sans ça, une nouvelle fenêtre active de
	# la pile recevrait la souris mais pas le clavier (l'enter clavier du
	# compositeur reste sur l'ancienne fenêtre).
	compositor.set_window_keyboard_focus(id)
	var st := _state(id)
	# Resynchroniser l'état de pointer lock : le signal pointer_lock_changed
	# n'est émis qu'à la création/destruction du constraint, et ignoré s'il
	# arrive avant l'entrée en mode focus. Un jeu qui a demandé le lock à son
	# démarrage (SDL/FPS) est donc déjà en mode relatif côté client sans que
	# mouse_captured soit vrai — sans ça la caméra FPS reste figée car le
	# mouvement relatif n'est jamais forwardé. Le compositeur garde l'état
	# réel (is_window_pointer_locked) comme source de vérité.
	st["mouse_captured"] = compositor.is_window_pointer_locked(id)
	if force_visible or compositor.is_window_xwayland(id):
		st["mouse_captured"] = false
	if input_debug:
		print("[focus:dbg] activate_window id=", id,
			" locked=", compositor.is_window_pointer_locked(id),
			" force_visible=", force_visible,
			" xwayland=", compositor.is_window_xwayland(id),
			" mouse_captured=", st["mouse_captured"])
	# Restaurer l'état souris de la fenêtre redevenue active
	_hide_cursor_overlay()
	if st["mouse_captured"]:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)
	# Rafraîchir les popups overlayés
	_clear_popup_overlays()
	for popup_id in windows.popup_parent_info:
		var pinfo = windows.popup_parent_info[popup_id]
		if pinfo.parent_window_id == id or \
			(pinfo.parent_popup_id != -1 and focus_popup_rects.has(pinfo.parent_popup_id)):
			_create_popup_overlay(popup_id, pinfo.parent_window_id, pinfo.parent_popup_id,
				pinfo.x, pinfo.y, pinfo.width, pinfo.height)

func _clear_popup_overlays() -> void:
	for popup_id in focus_popup_rects:
		if is_instance_valid(focus_popup_rects[popup_id]):
			focus_popup_rects[popup_id].queue_free()
	focus_popup_rects.clear()

func _reset_focus_ui() -> void:
	_clear_popup_overlays()
	for id in focus_rects:
		if is_instance_valid(focus_rects[id]):
			focus_rects[id].queue_free()
	focus_rects.clear()
	focus_states.clear()
	focus_stack.clear()
	focus_fullscreen_id = -1
	focus_mode = false
	# Restaurer le curseur système (l'overlay custom de la fenêtre focalisée
	# ne doit pas survivre à la sortie du mode focus).
	_hide_cursor_overlay()
	Input.set_custom_mouse_cursor(null)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player.focus_mode_active = false

# Dessine en overlay 2D le curseur posé par l'application en focus
# (wl_pointer.set_cursor, remonté via xwayland-satellite pour les fenêtres
# X11). Le curseur KWin est masqué (MOUSE_MODE_HIDDEN) pour éviter un double
# curseur ; sans image custom capturée, on retombe sur le curseur système.
func _update_cursor_overlay(window_id: int, mouse_pos: Vector2, display_scale: Vector2) -> void:
	var cursor_info := compositor.get_window_cursor(window_id)
	if cursor_info.is_empty():
		_show_system_cursor()
		return
	var serial: int = cursor_info["serial"]
	if serial != cursor_overlay_serial:
		var img: Image = cursor_info["image"]
		if not img or img.is_empty():
			_show_system_cursor()
			return
		cursor_overlay_tex = ImageTexture.create_from_image(img)
		cursor_overlay.texture = cursor_overlay_tex
		cursor_overlay_serial = serial
		if input_debug:
			print("[focus:dbg] custom cursor serial=", serial, " size=", img.get_size(),
				" hotspot=", Vector2(cursor_info["hotspot_x"], cursor_info["hotspot_y"]),
				" xwayland=", compositor.is_window_xwayland(window_id))
	var hotspot := Vector2(cursor_info["hotspot_x"], cursor_info["hotspot_y"])
	var img_size := cursor_overlay_tex.get_size()
	if img_size.x <= 0.0 or img_size.y <= 0.0:
		_show_system_cursor()
		return
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	cursor_overlay.size = img_size * display_scale
	cursor_overlay.position = mouse_pos - hotspot * display_scale
	cursor_overlay.visible = true

func _show_system_cursor() -> void:
	if cursor_overlay and cursor_overlay.visible:
		cursor_overlay.visible = false
		cursor_overlay_serial = -1
		if input_debug:
			print("[focus:dbg] system cursor")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _hide_cursor_overlay() -> void:
	if cursor_overlay:
		cursor_overlay.visible = false
	cursor_overlay_serial = -1

# Routage souris/clavier du mode focus, appelé chaque frame par
# wayland_room.gd tant que le mode est actif. L'input va à la fenêtre active.
func handle_focus_input() -> void:
	var active_id := _active_id()
	if active_id == -1 or not focus_rects.has(active_id):
		return
	var st := _state(active_id)
	var rect: TextureRect = focus_rects[active_id]
	var surf_x: float
	var surf_y: float

	# Souris capturée: maintenir le pointer focus + forward relatif via _input
	if st["mouse_captured"]:
		# Maintenir le pointer focus sur la surface (nécessaire pour que
		# wlr_relative_pointer_manager_v1_send_relative_motion livre les events)
		surf_x = st["mouse_uv"].x * st["surface_size"].x + st["content_offset"].x
		surf_y = st["mouse_uv"].y * st["surface_size"].y + st["content_offset"].y
		compositor.forward_pointer_motion(active_id, surf_x, surf_y)
		if input_debug and Time.get_ticks_msec() - _dbg_last_log > 500:
			_dbg_last_log = Time.get_ticks_msec()
			print("[focus:dbg] LOCKED uv=", st["mouse_uv"],
				" surf=", Vector2(surf_x, surf_y),
				" surf_size=", st["surface_size"],
				" rel_sum=", _dbg_rel_sum, " n=", _dbg_rel_count)
			_dbg_rel_sum = Vector2.ZERO
			_dbg_rel_count = 0
	else:
		# Souris visible: position absolue, curseur custom suit la souris
		var mouse_pos := get_viewport().get_mouse_position()

		# Utiliser la zone réelle affichée par le TextureRect pour le mapping
		# (plus précis que de recalculer avec surface_size)
		var tex := rect.texture
		var geometry := _visible_geometry(rect, tex)
		var displayed_size: Vector2 = geometry["displayed_size"]
		var offset: Vector2 = geometry["offset"]
		if displayed_size.x > 0.0 and displayed_size.y > 0.0:
			var local_pos := mouse_pos - offset
			st["mouse_uv"] = Vector2(
				clampf(local_pos.x / displayed_size.x, 0.0, 1.0),
				clampf(local_pos.y / displayed_size.y, 0.0, 1.0)
			)
		else:
			st["mouse_uv"] = Vector2(0.5, 0.5)

		# Adopter le curseur custom posé par l'application en focus
		# (wl_pointer.set_cursor) : dessiné en overlay 2D sur le pointeur,
		# sinon flèche système par défaut.
		var display_scale := Vector2.ONE
		if displayed_size.x > 0.0 and st["surface_size"].x > 0.0:
			display_scale = displayed_size / st["surface_size"]
		_update_cursor_overlay(active_id, mouse_pos, display_scale)

		surf_x = st["mouse_uv"].x * st["surface_size"].x + st["content_offset"].x
		surf_y = st["mouse_uv"].y * st["surface_size"].y + st["content_offset"].y
		compositor.forward_pointer_motion(active_id, surf_x, surf_y)
		if input_debug and Time.get_ticks_msec() - _dbg_last_log > 500:
			_dbg_last_log = Time.get_ticks_msec()
			print("[focus:dbg] VISIBLE mouse_pos=", get_viewport().get_mouse_position(),
				" uv=", st["mouse_uv"], " surf=", Vector2(surf_x, surf_y),
				" displayed=", displayed_size, " offset=", offset)

	compositor.set_window_pointer(active_id, surf_x, surf_y, true)

	if Input.is_action_just_pressed("left_click"):
		compositor.forward_pointer_button(active_id, 0x110, true)
	if Input.is_action_just_released("left_click"):
		compositor.forward_pointer_button(active_id, 0x110, false)

	if Input.is_action_just_pressed("right_click"):
		compositor.forward_pointer_button(active_id, 0x111, true)
	if Input.is_action_just_released("right_click"):
		compositor.forward_pointer_button(active_id, 0x111, false)

	# Clic molette (BTN_MIDDLE) : forwardé comme les clics gauche/droit.
	if Input.is_action_just_pressed("middle_click"):
		compositor.forward_pointer_button(active_id, 0x112, true)
	if Input.is_action_just_released("middle_click"):
		compositor.forward_pointer_button(active_id, 0x112, false)

	if Input.is_action_just_pressed("scroll_up"):
		compositor.forward_pointer_axis(active_id, 0, -100.0)
	if Input.is_action_just_pressed("scroll_down"):
		compositor.forward_pointer_axis(active_id, 0, 100.0)

# Gère un InputEvent en mode focus (clavier + tracking souris capturée).
# Renvoie true si l'événement a été consommé (toujours le cas en mode focus).
func handle_input_event(event: InputEvent) -> bool:
	if not focus_mode or focus_stack.is_empty():
		return false
	var active_id := _active_id()
	var st := _state(active_id)
	if event is InputEventKey:
		var key_event := event as InputEventKey
		# Échos de répétition Godot : les consommer sans les forwarder, sinon
		# xkbcommon reçoit des DOWN non appariés → modificateur "coincé".
		if key_event.echo:
			return true
		# Raccourcis clavier gérés par le jeu lui-même (le raccourci focus
		# pour sortir, la touche de fermeture de la fenêtre) : les consommer
		# SANS les forwarder au client. Sinon la touche est tapée dans la
		# fenêtre avant que l'action (exit_focus / close_window) ne s'exécute
		# dans _process. _is_compositor_shortcut ne matche que le bind exact
		# (modifieurs compris) ET uniquement l'appui : le relâchement est
		# forwardé (dropé comme orphelin par le garde-fou du compositeur si
		# nécessaire), pour ne jamais laisser une touche enfoncée côté client.
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
	elif st["mouse_captured"] and event is InputEventMouseMotion:
		# Tracker la position UV + forward le mouvement relatif au client
		var viewport_size := get_viewport().get_visible_rect().size
		var tex_size: Vector2 = st["surface_size"]
		if tex_size.x <= 0 or tex_size.y <= 0:
			tex_size = viewport_size
		var scale := minf(viewport_size.x / tex_size.x, viewport_size.y / tex_size.y)
		var displayed_size := tex_size * scale
		st["mouse_uv"].x += event.relative.x / displayed_size.x
		st["mouse_uv"].y += event.relative.y / displayed_size.y
		st["mouse_uv"].x = clampf(st["mouse_uv"].x, 0.0, 1.0)
		st["mouse_uv"].y = clampf(st["mouse_uv"].y, 0.0, 1.0)
		compositor.forward_pointer_relative_motion(
			active_id,
			event.relative.x, event.relative.y,
			event.relative.x, event.relative.y)
		if input_debug:
			_dbg_rel_sum += event.relative
			_dbg_rel_count += 1
			if Time.get_ticks_msec() - _dbg_last_log > 500:
				_dbg_last_log = Time.get_ticks_msec()
				print("[focus:dbg] motion event relative=", event.relative,
					" warped=", event.warped,
					" uv_after=", st["mouse_uv"])
	return true

# True si l'événement clavier correspond à un raccourci géré par le jeu
# (et non par le client) pendant le mode focus : la touche ne doit pas
# être forwardée. Les actions sont celles vérifiées dans _process de
# wayland_room.gd (sortie de focus, fermeture de la fenêtre).
# On utilise exact_match=true : seules les touches correspondant au bind
# exact (modifieurs compris, ex. Super+F) sont consommées. F seul — et
# ses combinaisons Ctrl/Shift/Alt+F — partent donc normalement vers le
# client, même si le raccourci focus utilise le modifieur Super.
# Seul l'APPUI est consommé : le relâchement est toujours forwardé. Si on
# avalait aussi le keyup, un F dont l'appui a déjà été forwardé (tapé dans
# la fenêtre) et qui est relâché pendant que Super est encore enfoncé serait
# perdu → la touche resterait enfoncée côté client (auto-repeat en boucle).
func _is_compositor_shortcut(event: InputEventKey) -> bool:
	if not event.pressed:
		return false
	for action in ["focus_window", "kill_window"]:
		if InputMap.event_is_action(event, action, true):
			return true
	return false
