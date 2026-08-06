extends Node3D
## PiP pinning : clones 2D des fenêtres épinglées (touche P ou menu) dans le
## coin supérieur-gauche, au-dessus des layer surfaces mais sous le mode focus.
## Créé et configuré par wayland_room.gd (setup), piloté par ses signaux.

const PIN_SIZE := Vector2(640, 360)
const PIN_MARGIN := 8
# z_index des fenêtres épinglées (PiP) : au-dessus de toutes les layer
# surfaces (jusqu'au layer overlay LAYER_Z_BASE + 3*100, popups +500 inclus)
# mais sous le mode focus.
const PIN_Z_BASE := 1900

var ui: CanvasLayer
var pinned_windows: Dictionary = {} # window_id (int) -> TextureRect

func setup(ui_ref: CanvasLayer) -> void:
	ui = ui_ref

func is_pinned(id: int) -> bool:
	return pinned_windows.has(id)

func pin(id: int, texture: Texture2D) -> void:
	if pinned_windows.has(id):
		return

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
	border.z_index = PIN_Z_BASE

	var idx := pinned_windows.size()
	border.position = Vector2(PIN_MARGIN, PIN_MARGIN + idx * (PIN_SIZE.y + PIN_MARGIN + 4))
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

func on_window_unmapped(id: int) -> void:
	unpin(id)

func on_window_texture_updated(id: int, texture: Texture2D) -> void:
	if pinned_windows.has(id) and is_instance_valid(pinned_windows[id]):
		var pip_tex: TextureRect = pinned_windows[id].get_child(0)
		pip_tex.texture = texture
