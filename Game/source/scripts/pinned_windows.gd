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
var pinned_windows: Dictionary = {} # window_id (int) -> TextureRect
# True : la fenêtre épinglée s'affiche au-dessus du layer focus.
var pins_above_focus := false
# Pourcentage de transparence de la fenêtre épinglée (0 = opaque, 100 = invisible).
var pins_opacity := 0

func setup(ui_ref: CanvasLayer) -> void:
	ui = ui_ref

func _pin_z_index() -> int:
	return PIN_Z_ABOVE_FOCUS if pins_above_focus else PIN_Z_BASE

func _pin_alpha() -> float:
	return 1.0 - float(pins_opacity) / 100.0

func is_pinned(id: int) -> bool:
	return pinned_windows.has(id)

func pin(id: int, texture: Texture2D) -> void:
	# Si la fenêtre est déjà épinglée, on ne fait rien
	if pinned_windows.has(id):
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

	# Position fixe dans le coin supérieur gauche
	border.position = Vector2(PIN_MARGIN, PIN_MARGIN)
	pip.set_meta("window_id", id)
	ui.add_child(border)
	pinned_windows[id] = border

func unpin(id: int) -> void:
	if not pinned_windows.has(id):
		return
	var pip: Control = pinned_windows[id]
	if is_instance_valid(pip):
		pip.queue_free()
	pinned_windows.erase(id)

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

func on_window_texture_updated(id: int, texture: Texture2D) -> void:
	if pinned_windows.has(id) and is_instance_valid(pinned_windows[id]):
		var pip_tex: TextureRect = pinned_windows[id].get_child(0)
		pip_tex.texture = texture
