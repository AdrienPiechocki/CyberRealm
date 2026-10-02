extends Node
## Stub minimal du compositeur pour les tests de focus_mode.
## Node simple (PAS un sous-classe de WlrCompositor) : focus_mode duck-type
## son compositeur, un objet ordinaire suffit et reste pilotable.

var _requests: Dictionary = {}
var fullscreen_calls: Array = []
# La fenêtre en cadence prioritaire (focus) : id, -1 = aucune. Piloté par
# set_focus_capture_priority_window, inchangé — le zéro-copy en dépend.
var focus_priority_id := -1
# La fenêtre épinglée en cadence prioritaire (PiP) : id, -1 = aucune. Un slot
# suffit : pinned_windows garantit qu'il n'y a qu'un PiP à la fois.
var pin_priority_id := -1
var pin_priority_calls: Array = []

func _init() -> void:
	fullscreen_calls.clear()
	pin_priority_calls.clear()

func set_focus_capture_priority_window(id: int) -> void:
	focus_priority_id = id

func set_pin_capture_priority_window(id: int, active: bool) -> void:
	pin_priority_calls.append([id, active])
	pin_priority_id = id if active else -1

func is_capture_priority(id: int) -> bool:
	return id != -1 and id == pin_priority_id

func request_fullscreen(id: int, requested: bool) -> void:
	_requests[id] = requested

func clear_requests() -> void:
	_requests.clear()

func is_window_fullscreen_requested(id: int) -> bool:
	if _requests.has(id):
		return _requests[id]
	return false

func set_window_fullscreen(id: int, fs: bool) -> void:
	fullscreen_calls.append([id, fs])

func set_window_keyboard_focus(_id: int) -> void:
	pass

func release_all_keys() -> void:
	pass

func forward_keyboard_key(_godot_physical_keycode: int, _key_location: int, _pressed: bool) -> void:
	pass

func forward_pointer_motion(_window_id: int, _surface_x: float, _surface_y: float) -> void:
	pass

func forward_pointer_motion_popup(_window_id: int, _surface_x: float, _surface_y: float) -> void:
	pass

func forward_pointer_relative_motion(_time_msec: int, _delta_x: float, _delta_y: float, _delta_unaccel_x: float, _delta_unaccel_y: float) -> void:
	pass

func forward_pointer_axis(_window_id: int, _delta_x: float, _delta_y: float) -> void:
	pass

func forward_pointer_axis_popup(_window_id: int, _delta_x: float, _delta_y: float) -> void:
	pass

func forward_pointer_button(_window_id: int, _button: int, _pressed: bool) -> void:
	pass

func forward_pointer_button_popup(_window_id: int, _button: int, _pressed: bool) -> void:
	pass

func is_drag_active() -> bool:
	return false

func get_window_geometry(_id: int) -> Dictionary:
	return {"x": 0, "y": 0, "width": 800, "height": 600}

func get_window_cursor(_id: int) -> int:
	return 0

func set_window_pointer(_window_id: int, _hotspot_x: float, _hotspot_y: float, _locked: bool) -> void:
	pass

func set_window_size(_id: int, _w: int, _h: int) -> void:
	pass

func shutdown_apps() -> void:
	pass

func set_x11_display(_n: String) -> void:
	pass

func get_window_cpu_image(_id: int) -> Image:
	return Image.new()
