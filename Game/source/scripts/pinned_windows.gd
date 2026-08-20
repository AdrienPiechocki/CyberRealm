extends Node3D

const PIN_SIZE := Vector2(640, 360)
const PIN_MARGIN := 8
# En dessous du layer focus (FOCUS_Z_BASE = 2000) : le PiP est caché quand
# une fenêtre est en mode focus.
const PIN_Z_BASE := 1900
# Au-dessus du layer focus (y compris ses popups, FOCUS_POPUP_Z = 2050) : le
# PiP reste visible pendant le mode focus. Choix via le menu pause.
const PIN_Z_ABOVE_FOCUS := 2100

var ui: CanvasLayer
var pinned_windows: Dictionary = {} # clé (int window_id local, ou String "r:peer:wid" distant) -> TextureRect
# True : la fenêtre épinglée s'affiche au-dessus du layer focus.
var pins_above_focus := false
# Pourcentage de transparence de la fenêtre épinglée (0 = opaque, 100 = invisible).
var pins_opacity := 0
# Coin de l'écran où est affichée la fenêtre épinglée.
# "top_left" | "top_right" | "bottom_left" | "bottom_right"
var pins_position := "top_left"
var _hover_tween: Tween
var _is_hovering := false

func setup(ui_ref: CanvasLayer) -> void:
	ui = ui_ref
	if ui != null and ui.get_viewport() != null:
		ui.get_viewport().size_changed.connect(_reposition_all)

func _pin_z_index() -> int:
	return PIN_Z_ABOVE_FOCUS if pins_above_focus else PIN_Z_BASE

func _pin_alpha() -> float:
	return 1.0 - float(pins_opacity) / 100.0

func _pin_position() -> Vector2:
	var size := Vector2(PIN_MARGIN, PIN_MARGIN)
	if ui != null and ui.get_viewport() != null:
		size = ui.get_viewport().get_visible_rect().size
	var px := PIN_SIZE.x + 4.0 + PIN_MARGIN
	var py := PIN_SIZE.y + 4.0 + PIN_MARGIN
	match pins_position:
		"top_right":
			return Vector2(size.x - px, PIN_MARGIN)
		"bottom_left":
			return Vector2(PIN_MARGIN, size.y - py)
		"bottom_right":
			return Vector2(size.x - px, size.y - py)
	return Vector2(PIN_MARGIN, PIN_MARGIN)

func _reposition_all() -> void:
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.position = _pin_position()

func is_pinned(id: int) -> bool:
	return pinned_windows.has(id)

func pin(id: int, texture: Texture2D) -> void:
	_add_pin(id, texture)

# Clé de PiP unique pour une fenêtre distante (un wid local et un wid distant
# peuvent coïncider numériquement : on préfixe par le peer).
func _remote_key(peer_id: int, wid: int) -> String:
	return "r:%d:%d" % [peer_id, wid]

func is_pinned_remote(peer_id: int, wid: int) -> bool:
	return pinned_windows.has(_remote_key(peer_id, wid))

func pin_remote(peer_id: int, wid: int, texture: Texture2D) -> void:
	_add_pin(_remote_key(peer_id, wid), texture)

func unpin_remote(peer_id: int, wid: int) -> void:
	unpin(_remote_key(peer_id, wid))

# Retire tous les PiP des fenêtres d'un joueur distant (déconnexion, fin de
# session, plus aucune fenêtre partagée).
func unpin_peer(peer_id: int) -> void:
	var prefix := "r:%d:" % peer_id
	for key in pinned_windows.keys().duplicate():
		if key is String and key.begins_with(prefix):
			unpin(key)

func _add_pin(key, texture: Texture2D) -> void:
	# Si la fenêtre est déjà épinglée, on ne fait rien
	if pinned_windows.has(key):
		return

	# Si une AUTRE fenêtre est déjà épinglée, on la retire d'abord
	unpin_all()

	var pip := TextureRect.new()
	pip.texture = texture
	pip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pip.size = PIN_SIZE
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Bordure
	var border := PanelContainer.new()
	border.size = PIN_SIZE + Vector2(4, 4)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color.TRANSPARENT
	border.add_theme_stylebox_override("panel", bg)
	border.add_child(pip)
	border.z_index = _pin_z_index()
	border.modulate.a = _pin_alpha()

	border.position = _pin_position()
	pip.set_meta("window_id", key)
	ui.add_child(border)
	pinned_windows[key] = border

func unpin(key) -> void:
	if not pinned_windows.has(key):
		return
	var pip: Control = pinned_windows[key]
	if is_instance_valid(pip):
		pip.queue_free()
	pinned_windows.erase(key)
	if pinned_windows.is_empty():
		_is_hovering = false
		if _hover_tween:
			_hover_tween.kill()
			_hover_tween = null

## Retire toutes les fenêtres épinglées (pour garantir 1 seule fenêtre max)
func unpin_all() -> void:
	for current_id in pinned_windows.keys():
		unpin(current_id)

func on_window_unmapped(id: int) -> void:
	unpin(id)

# Met à jour la couche d'affichage des fenêtres épinglées par rapport au layer
# focus (réglage du menu pause) : s'applique immédiatement aux PiP existants.
func set_pins_above_focus(above: bool) -> void:
	if pins_above_focus == above:
		return
	pins_above_focus = above
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.z_index = _pin_z_index()

# Applique la transparence (0-100 %) aux PiP existants.
func set_pins_opacity(percent: int) -> void:
	percent = clampi(percent, 0, 100)
	if pins_opacity == percent:
		return
	pins_opacity = percent
	var alpha := _pin_alpha()
	for current_id in pinned_windows:
		var pip: Control = pinned_windows[current_id]
		if is_instance_valid(pip):
			pip.modulate.a = alpha

# Déplace la fenêtre épinglée dans le coin choisi (s'applique immédiatement).
func set_pins_position(position: String) -> void:
	if not position in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		return
	if pins_position == position:
		return
	pins_position = position
	_reposition_all()

func on_window_texture_updated(id: int, texture: Texture2D) -> void:
	if pinned_windows.has(id) and is_instance_valid(pinned_windows[id]):
		var pip_tex: TextureRect = pinned_windows[id].get_child(0)
		pip_tex.texture = texture

# Mise à jour de la texture d'une fenêtre distante épinglée (appelé par
# lan_manager à chaque frame streamée reçue).
func on_remote_texture_updated(peer_id: int, wid: int, texture: Texture2D) -> void:
	var key := _remote_key(peer_id, wid)
	if pinned_windows.has(key) and is_instance_valid(pinned_windows[key]):
		var pip_tex: TextureRect = pinned_windows[key].get_child(0)
		pip_tex.texture = texture

func _process(_delta: float) -> void:
	if pinned_windows.is_empty():
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var hovering := false
	for key in pinned_windows:
		var pip: Control = pinned_windows[key]
		if is_instance_valid(pip) and pip.get_global_rect().has_point(mouse_pos):
			hovering = true
			break
	if hovering == _is_hovering:
		return
	_is_hovering = hovering
	if _hover_tween:
		_hover_tween.kill()
	_hover_tween = create_tween()
	var target_alpha := 0.0 if hovering else _pin_alpha()
	for key in pinned_windows:
		var pip: Control = pinned_windows[key]
		if is_instance_valid(pip):
			_hover_tween.tween_property(pip, "modulate:a", target_alpha, 0.15)
