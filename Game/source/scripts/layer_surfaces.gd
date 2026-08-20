extends Node3D
## Layer surfaces (wlr-layer-shell-unstable-v1): waybar, rofi, notifications.
## Rendu en overlays 2D ancrés à l'écran (pas de quads 3D), positionnés aux
## coordonnées (x, y, width, height) calculées par arrange_layer_surfaces().
## Gère aussi le session lock (ext-session-lock-v1) et le routage du
## pointeur/clavier vers ces overlays.
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

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
# contenu 3D (quads) comme dans un compositeur classique ; les popups de
# layer passent encore au-dessus.
const LAYER_Z_BASE := 1000

# z_index du lockscreen (ext-session-lock-v1) : au-dessus de tout — layer
# surfaces, mode focus, PiP — car un session verrouillée ne doit montrer
# que le lockscreen.
const SESSION_LOCK_Z := 3000

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
		// Buffers Wayland pré-multipliés (wl_shm ARGB32, Cairo...) :
		// dé-pré-multiplier en sRGB et sortir la couleur droite avec son
		// alpha (blend_mix = straight alpha). Pas de pow(2.2) : contraire-
		// ment au shader spatial (3D, linéaire), le canvas 2D de Godot
		// composite en sRGB -> gamma-appliquer assombrissait les pixels
		// semi-transparents (halos, alpha cassé).
		vec3 unmultiplied = tex.a > 0.01 ? tex.rgb / max(tex.a, 0.001) : tex.rgb;
		COLOR = vec4(unmultiplied, tex.a);
	}
}
"""

var compositor: WlrCompositor
var player: Node3D
var ui: CanvasLayer
var focus: Node3D
var pause_menu: Control
var window_menu: Control

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

func setup(compositor_ref: WlrCompositor, player_ref: Node3D, ui_ref: CanvasLayer, focus_ref: Node3D, pause_menu_ref: Control, window_menu_ref: Control) -> void:
	compositor = compositor_ref
	player = player_ref
	ui = ui_ref
	focus = focus_ref
	pause_menu = pause_menu_ref
	window_menu = window_menu_ref

	layer_shader = Shader.new()
	layer_shader.code = LAYER_SHADER_CODE

	# Overlay plein écran recevant les TextureRect des layer surfaces.
	layer_overlay = Control.new()
	layer_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(layer_overlay)

func is_locked() -> bool:
	return session_locked

func keyboard_busy() -> bool:
	# Vrai quand un overlay keyboard-interactive (rofi, waybar...) détient le
	# focus clavier : les touches sont routées vers lui, aucun bind du jeu ne
	# doit se déclencher.
	return compositor.get_keyboard_focus_layer_id() >= 0

func _layer_z_index(layer: int, is_popup: bool = false) -> int:
	return LAYER_Z_BASE + layer * 100 + (500 if is_popup else 0)

# Forward d'un événement clavier vers la surface qui détient le focus
# clavier (layer interactive ou lockscreen). Renvoie true si consommé.
func forward_keyboard_event(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key_event := event as InputEventKey
	# Échos de répétition Godot : les consommer sans les forwarder, sinon
	# xkbcommon reçoit des DOWN non appariés → modificateur "coincé".
	if key_event.echo:
		return true
	var code = key_event.physical_keycode
	if code == 0:
		code = key_event.keycode
	# Chevrons AZERTY : la touche ISO (physique KEY_QUOTELEFT/96) donne '<'
	# non-shifté et '>' shifté — même touche evdev 86, le Shift est forwardé
	# à part. Remap par code physique (pas par unicode, nul au relâchement)
	# pour que l'UP parte avec le MÊME evdev que le DOWN : sinon la touche
	# reste enfoncée côté client (auto-repeat en boucle) et les appuis
	# suivants sont bloqués par le garde-fou pressed_keys.
	if key_event.unicode == 60 or key_event.unicode == 62 or code == KEY_QUOTELEFT:
		code = KEY_LESS
	compositor.forward_keyboard_key(code, key_event.location, key_event.pressed)
	get_viewport().set_input_as_handled()
	return true

# Routage complet du pointeur vers le lockscreen, appelé chaque frame par
# wayland_room.gd tant que la session est verrouillée.
func handle_locked_input() -> void:
	var mp := get_viewport().get_mouse_position()
	compositor.forward_pointer_motion_lock(mp.x, mp.y)
	if Input.is_action_just_pressed("left_click", false):
		compositor.forward_pointer_button_lock(0x110, true)
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button_lock(0x110, false)
	if Input.is_action_just_pressed("right_click", false):
		compositor.forward_pointer_button_lock(0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button_lock(0x111, false)
	if Input.is_action_just_pressed("scroll_up", false):
		compositor.forward_pointer_axis_lock(0.0, -50.0)
	if Input.is_action_just_pressed("scroll_down", false):
		compositor.forward_pointer_axis_lock(0.0, 50.0)

# Retour à la capture FPS après la fermeture d'un overlay interactif ou le
# déverrouillage, si aucun autre mode ne gère déjà la souris.
func recapture_if_needed() -> void:
	if not _any_interactive_layer() \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not focus.is_active() and not pause_menu.visible and not window_menu.visible:
		layer_interact_active = false
		layer_interact_manual = false
		player.layer_pointer_active = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# Quitte le mode "interaction layer" : à appeler par wayland_room quand un
# autre mode reprend la souris (focus, menu pause, menu fenêtres,
# interact_mode...). Réinitialise l'état même si le joueur n'a pas repassé
# Tab (layer_interact_manual) : quitter le mode layer doit le désactiver.
func deactivate_layer_interact() -> void:
	Input.warp_mouse(get_viewport().get_visible_rect().size / 2.0)
	layer_interact_active = false
	layer_interact_manual = false
	player.layer_pointer_active = false

func _any_interactive_layer() -> bool:
	for lid in layer_rects:
		var entry = layer_rects[lid]
		if int(entry.get("kb", 0)) != 0:
			return true
	return false

# Tab : bascule le mode "interaction layer" — libère la souris pour
# survoler/cliquer waybar, quickshell ou les overlays non interactifs
# (sinon elle est capturée et fait tourner la caméra FPS).
func toggle_layer_interact() -> void:
	# Si un overlay interactif (rofi...) a le focus clavier, la touche lui
	# est routée par _input : ne pas basculer le mode souris par-dessus.
	if _any_interactive_layer() and compositor.get_keyboard_focus_layer_id() >= 0:
		return
	if layer_interact_active:
		layer_interact_active = false
		layer_interact_manual = false
		player.layer_pointer_active = false
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		layer_interact_active = true
		layer_interact_manual = true
		player.layer_pointer_active = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _remove_layer_popups_for(layer_id: int) -> void:
	for pid in layer_popup_rects.keys():
		var entry = layer_popup_rects[pid]
		if entry.parent_layer_id == layer_id:
			if is_instance_valid(entry.rect):
				entry.rect.queue_free()
			layer_popup_rects.erase(pid)

func on_layer_surface_mapped(id: int, ns: String, layer: int, anchor: int, x: int, y: int, w: int, h: int, kb: int) -> void:
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
	# Overlay de fondu vers le verrouillage (dms:fade-to-lock) : écran noir
	# transitoire déclenché par l'inactivité. Il ne doit NI libérer la souris /
	# warper le curseur (→ events synthétiques), NI recevoir le pointeur chaque
	# frame (→ forward_pointer_motion_layer → notify_activity → l'idle est
	# ré-armé et le fondu annulé en boucle). On le marque no_pointer pour que
	# _layer_at l'ignore et on saute le bloc interactif ci-dessous.
	var no_pointer: bool = "fade-to-lock" in ns
	layer_rects[id] = {"rect": rect, "layer": layer, "anchor": anchor, "kb": kb, "no_pointer": no_pointer}
	if kb != 0 and not no_pointer:
		# App interactive en overlay (rofi, launcher...): libérer la souris
		# pour qu'elle soit utilisable sur l'overlay au lieu de tourner la
		# caméra FPS. La recapture se fait au unmapped (voir plus bas).
		layer_interact_active = true
		player.layer_pointer_active = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func on_layer_surface_unmapped(id: int) -> void:
	_remove_layer_popups_for(id)
	if layer_rects.has(id):
		var entry = layer_rects[id]
		if is_instance_valid(entry.rect):
			entry.rect.queue_free()
		layer_rects.erase(id)
	# Plus aucune app interactive en overlay → retour en mode FPS, sauf si on
	# est dans un autre mode qui gère déjà la souris (focus, menus).
	recapture_if_needed()

func on_layer_surface_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
	if not layer_rects.has(id):
		return
	var entry = layer_rects[id]
	# Note : PAS de garde "texture déjà en place" ici. Dans le chemin Vulkan,
	# une surface de taille stable est re-rendue dans le MÊME dmabuf →
	# même objet Texture2DRD mais contenu neuf : le set + queue_redraw est
	# indispensable. La redondance est éliminée côté C++ (flag dirty : une
	# seule émission par commit, jamais pour une surface statique).
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

func on_layer_surface_layout_changed(id: int, x: int, y: int, w: int, h: int) -> void:
	if not layer_rects.has(id):
		return
	var entry = layer_rects[id]
	entry.rect.position = Vector2(x, y)
	entry.rect.size = Vector2(max(w, 1), max(h, 1))

func on_layer_popup_mapped(popup_id: int, parent_layer_id: int, x: int, y: int, w: int, h: int) -> void:
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

# Unmapped d'un popup d'une layer surface -> true si ce popup était le nôtre
# (dans ce cas wayland_room.gd ne le dispatche pas aux quads 3D).
func on_popup_unmapped(id: int) -> bool:
	if not layer_popup_rects.has(id):
		return false
	if is_instance_valid(layer_popup_rects[id].rect):
		layer_popup_rects[id].rect.queue_free()
	layer_popup_rects.erase(id)
	return true

# Texture d'un popup d'une layer surface -> true si ce popup était le nôtre.
func on_popup_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> bool:
	if not layer_popup_rects.has(id):
		return false
	var popup_entry = layer_popup_rects[id]
	popup_entry.rect.texture = texture
	popup_entry.rect.set_meta("surface_size", Vector2(width, height))
	var popup_mat := popup_entry.rect.material as ShaderMaterial
	if popup_mat:
		popup_mat.set_shader_parameter("u_tex", texture)
		popup_mat.set_shader_parameter("u_content_size", Vector2(width, height))
	return true

func on_session_lock_locked() -> void:
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
	player.layer_pointer_active = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func on_session_lock_unlocked() -> void:
	session_locked = false
	session_lock_surface_id = -1
	if session_lock_rect != null and is_instance_valid(session_lock_rect):
		session_lock_rect.queue_free()
		session_lock_rect = null
	# Retour à l'état normal (capture FPS) sauf si un overlay interactif
	# ou un autre mode gère déjà la souris.
	recapture_if_needed()

func on_session_lock_surface_texture_updated(id: int, texture: Texture2D, width: int, height: int) -> void:
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
		if entry.get("no_pointer", false):
			continue
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

func _handle_pointer(hit: Dictionary, mouse_pos: Vector2) -> void:
	var uv := _layer_uv(hit, mouse_pos)
	if hit.kind == "layer_popup":
		compositor.forward_pointer_motion_popup(hit.id, uv.x, uv.y)
		if Input.is_action_just_pressed("left_click", false):
			compositor.forward_pointer_button_popup(hit.id, 0x110, true)
		if Input.is_action_just_released("left_click", false):
			compositor.forward_pointer_button_popup(hit.id, 0x110, false)
		if Input.is_action_just_pressed("right_click", false):
			compositor.forward_pointer_button_popup(hit.id, 0x111, true)
		if Input.is_action_just_released("right_click", false):
			compositor.forward_pointer_button_popup(hit.id, 0x111, false)
		return
	compositor.forward_pointer_motion_layer(hit.id, uv.x, uv.y)
	if Input.is_action_just_pressed("left_click", false):
		compositor.forward_pointer_button_layer(hit.id, 0x110, true)
	if Input.is_action_just_released("left_click", false):
		compositor.forward_pointer_button_layer(hit.id, 0x110, false)
	if Input.is_action_just_pressed("right_click", false):
		compositor.forward_pointer_button_layer(hit.id, 0x111, true)
	if Input.is_action_just_released("right_click", false):
		compositor.forward_pointer_button_layer(hit.id, 0x111, false)
	if Input.is_action_just_pressed("scroll_up", false):
		compositor.forward_pointer_axis_layer(hit.id, 0, -50.0)
	if Input.is_action_just_pressed("scroll_down", false):
		compositor.forward_pointer_axis_layer(hit.id, 0, 50.0)

# Routage du pointeur vers les overlays de layer surfaces, appelé chaque
# frame par wayland_room.gd quand la souris est visible. Renvoie true si la
# souris survolait une layer surface / popup (input consommé).
func handle_layer_pointer(mouse_pos: Vector2) -> bool:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return false
	if layer_rects.is_empty() and layer_popup_rects.is_empty():
		return false
	var hit := _layer_at(mouse_pos)
	if hit.is_empty():
		return false
	_handle_pointer(hit, mouse_pos)
	return true
