extends GameMenu
class_name VirtualKeyboard
## Clavier virtuel on-screen, pilotable à la souris et au D-PAD.
## Le layout est synchronisé avec les paramètres de clavier du jeu.
## Les key events sont forwardés au compositor via forward_keyboard_key().

signal keyboard_closed()

var _compositor: Node = null
var _pause_menu: Node = null
var _radial_menu: PanelContainer = null
var _container: VBoxContainer
var _title_label: Label
var _shift_locked := false
var _ctrl_locked := false
var _alt_locked := false
var _key_buttons: Array[Button] = []

# ── Layout data : physical keycode → {normal, shift} label ──────────────
# Les keycodes sont les positions physiques (US QWERTY = référence).
# Le label est le caractère produit par XKB avec le layout actif.

const LAYOUTS := {
	"fr": {
		"label": "Français (AZERTY)",
		# Row 0: number row
		KEY_QUOTELEFT: {"n": "²", "s": ""},
		KEY_1: {"n": "&", "s": "1"},
		KEY_2: {"n": "é", "s": "2"},
		KEY_3: {"n": "\"", "s": "3"},
		KEY_4: {"n": "'", "s": "4"},
		KEY_5: {"n": "(", "s": "5"},
		KEY_6: {"n": "-", "s": "6"},
		KEY_7: {"n": "è", "s": "7"},
		KEY_8: {"n": "_", "s": "8"},
		KEY_9: {"n": "ç", "s": "9"},
		KEY_0: {"n": "à", "s": "0"},
		KEY_MINUS: {"n": ")", "s": "°"},
		KEY_EQUAL: {"n": "=", "s": "+"},
		# Row 1: top letter row
		KEY_Q: {"n": "a", "s": "A"},
		KEY_W: {"n": "z", "s": "Z"},
		KEY_E: {"n": "e", "s": "E"},
		KEY_R: {"n": "r", "s": "R"},
		KEY_T: {"n": "t", "s": "T"},
		KEY_Y: {"n": "y", "s": "Y"},
		KEY_U: {"n": "u", "s": "U"},
		KEY_I: {"n": "i", "s": "I"},
		KEY_O: {"n": "o", "s": "O"},
		KEY_P: {"n": "p", "s": "P"},
		KEY_BRACKETLEFT: {"n": "^", "s": "¨"},
		KEY_BRACKETRIGHT: {"n": "$", "s": "£"},
		# Row 2: home row
		KEY_A: {"n": "q", "s": "Q"},
		KEY_S: {"n": "s", "s": "S"},
		KEY_D: {"n": "d", "s": "D"},
		KEY_F: {"n": "f", "s": "F"},
		KEY_G: {"n": "g", "s": "G"},
		KEY_H: {"n": "h", "s": "H"},
		KEY_J: {"n": "j", "s": "J"},
		KEY_K: {"n": "k", "s": "K"},
		KEY_L: {"n": "l", "s": "L"},
		KEY_SEMICOLON: {"n": "m", "s": "M"},
		KEY_APOSTROPHE: {"n": "ù", "s": "%"},
		# Row 3: bottom row
		KEY_Z: {"n": "w", "s": "W"},
		KEY_X: {"n": "x", "s": "X"},
		KEY_C: {"n": "c", "s": "C"},
		KEY_V: {"n": "v", "s": "V"},
		KEY_B: {"n": "b", "s": "B"},
		KEY_N: {"n": "n", "s": "N"},
		KEY_M: {"n": ",", "s": "?"},
		KEY_COMMA: {"n": ";", "s": "."},
		KEY_PERIOD: {"n": ":", "s": "/"},
		KEY_SLASH: {"n": "!", "s": "§"},
	},
	"us": {
		"label": "US (QWERTY)",
		KEY_QUOTELEFT: {"n": "`", "s": "~"},
		KEY_1: {"n": "1", "s": "!"},
		KEY_2: {"n": "2", "s": "@"},
		KEY_3: {"n": "3", "s": "#"},
		KEY_4: {"n": "4", "s": "$"},
		KEY_5: {"n": "5", "s": "%"},
		KEY_6: {"n": "6", "s": "^"},
		KEY_7: {"n": "7", "s": "&"},
		KEY_8: {"n": "8", "s": "*"},
		KEY_9: {"n": "9", "s": "("},
		KEY_0: {"n": "0", "s": ")"},
		KEY_MINUS: {"n": "-", "s": "_"},
		KEY_EQUAL: {"n": "=", "s": "+"},
		KEY_Q: {"n": "q", "s": "Q"},
		KEY_W: {"n": "w", "s": "W"},
		KEY_E: {"n": "e", "s": "E"},
		KEY_R: {"n": "r", "s": "R"},
		KEY_T: {"n": "t", "s": "T"},
		KEY_Y: {"n": "y", "s": "Y"},
		KEY_U: {"n": "u", "s": "U"},
		KEY_I: {"n": "i", "s": "I"},
		KEY_O: {"n": "o", "s": "O"},
		KEY_P: {"n": "p", "s": "P"},
		KEY_BRACKETLEFT: {"n": "[", "s": "{"},
		KEY_BRACKETRIGHT: {"n": "]", "s": "}"},
		KEY_A: {"n": "a", "s": "A"},
		KEY_S: {"n": "s", "s": "S"},
		KEY_D: {"n": "d", "s": "D"},
		KEY_F: {"n": "f", "s": "F"},
		KEY_G: {"n": "g", "s": "G"},
		KEY_H: {"n": "h", "s": "H"},
		KEY_J: {"n": "j", "s": "J"},
		KEY_K: {"n": "k", "s": "K"},
		KEY_L: {"n": "l", "s": "L"},
		KEY_SEMICOLON: {"n": ";", "s": ":"},
		KEY_APOSTROPHE: {"n": "'", "s": "\""},
		KEY_Z: {"n": "z", "s": "Z"},
		KEY_X: {"n": "x", "s": "X"},
		KEY_C: {"n": "c", "s": "C"},
		KEY_V: {"n": "v", "s": "V"},
		KEY_B: {"n": "b", "s": "B"},
		KEY_N: {"n": "n", "s": "N"},
		KEY_M: {"n": "m", "s": "M"},
		KEY_COMMA: {"n": ",", "s": "<"},
		KEY_PERIOD: {"n": ".", "s": ">"},
		KEY_SLASH: {"n": "/", "s": "?"},
	},
	"de": {
		"label": "Deutsch (QWERTZ)",
		KEY_QUOTELEFT: {"n": "^", "s": "°"},
		KEY_1: {"n": "1", "s": "!"},
		KEY_2: {"n": "2", "s": "\""},
		KEY_3: {"n": "3", "s": "§"},
		KEY_4: {"n": "4", "s": "$"},
		KEY_5: {"n": "5", "s": "%"},
		KEY_6: {"n": "6", "s": "&"},
		KEY_7: {"n": "7", "s": "/"},
		KEY_8: {"n": "8", "s": "("},
		KEY_9: {"n": "9", "s": ")"},
		KEY_0: {"n": "0", "s": "="},
		KEY_MINUS: {"n": "ß", "s": "?"},
		KEY_EQUAL: {"n": "´", "s": "`"},
		KEY_Q: {"n": "q", "s": "Q"},
		KEY_W: {"n": "w", "s": "W"},
		KEY_E: {"n": "e", "s": "E"},
		KEY_R: {"n": "r", "s": "R"},
		KEY_T: {"n": "t", "s": "T"},
		KEY_Z: {"n": "z", "s": "Z"},
		KEY_U: {"n": "u", "s": "U"},
		KEY_I: {"n": "i", "s": "I"},
		KEY_O: {"n": "o", "s": "O"},
		KEY_P: {"n": "p", "s": "P"},
		KEY_BRACKETLEFT: {"n": "ü", "s": "Ü"},
		KEY_BRACKETRIGHT: {"n": "+", "s": "*"},
		KEY_A: {"n": "a", "s": "A"},
		KEY_S: {"n": "s", "s": "S"},
		KEY_D: {"n": "d", "s": "D"},
		KEY_F: {"n": "f", "s": "F"},
		KEY_G: {"n": "g", "s": "G"},
		KEY_H: {"n": "h", "s": "H"},
		KEY_J: {"n": "j", "s": "J"},
		KEY_K: {"n": "k", "s": "K"},
		KEY_L: {"n": "l", "s": "L"},
		KEY_SEMICOLON: {"n": "ö", "s": "Ö"},
		KEY_APOSTROPHE: {"n": "ä", "s": "Ä"},
		KEY_Y: {"n": "y", "s": "Y"},
		KEY_X: {"n": "x", "s": "X"},
		KEY_C: {"n": "c", "s": "C"},
		KEY_V: {"n": "v", "s": "V"},
		KEY_B: {"n": "b", "s": "B"},
		KEY_N: {"n": "n", "s": "N"},
		KEY_M: {"n": "m", "s": "M"},
		KEY_COMMA: {"n": ",", "s": ";"},
		KEY_PERIOD: {"n": ".", "s": ":"},
		KEY_SLASH: {"n": "-", "s": "_"},
	},
}

# Row definitions by physical keycode positions
const ROWS := [
	# Row 0: numbers
	[KEY_QUOTELEFT, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUAL, KEY_BACKSPACE],
	# Row 1: top letters
	[KEY_TAB, KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y, KEY_U, KEY_I, KEY_O, KEY_P, KEY_BRACKETLEFT, KEY_BRACKETRIGHT],
	# Row 2: home row
	[KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H, KEY_J, KEY_K, KEY_L, KEY_SEMICOLON, KEY_APOSTROPHE, KEY_ENTER],
	# Row 3: bottom row
	[KEY_SHIFT, KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B, KEY_N, KEY_M, KEY_COMMA, KEY_PERIOD, KEY_SLASH, KEY_SHIFT],
	# Row 4: modifiers
	[KEY_CTRL, KEY_ALT, KEY_SPACE, KEY_ALT, KEY_CTRL],
]

const SPECIAL_LABELS := {
	KEY_BACKSPACE: "⌫",
	KEY_TAB: "⇥",
	KEY_ENTER: "↵",
	KEY_SHIFT: "⇧",
	KEY_CTRL: "Ctrl",
	KEY_ALT: "Alt",
	KEY_SPACE: "─────",
}

const MODIFIER_KEYS := [KEY_SHIFT, KEY_CTRL, KEY_ALT]


func _ready() -> void:
	visible = false
	_build_ui()


func setup(compositor_node: Node, pause_menu_node: Node, radial_menu_node: PanelContainer) -> void:
	_compositor = compositor_node
	_pause_menu = pause_menu_node
	_radial_menu = radial_menu_node


func _build_ui() -> void:
	# Panel styling
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.06, 0.08, 0.95)
	bg.border_color = Color(0.3, 0.4, 0.6, 0.8)
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.corner_radius_top_left = 10
	bg.corner_radius_top_right = 10
	bg.corner_radius_bottom_left = 10
	bg.corner_radius_bottom_right = 10
	add_theme_stylebox_override("panel", bg)

	custom_minimum_size = Vector2(720, 0)
	anchors_preset = Control.PRESET_CENTER_BOTTOM

	_container = VBoxContainer.new()
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_container.add_theme_constant_override("separation", 3)
	add_child(_container)

	# Title
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 16)
	_title_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	_title_label.custom_minimum_size = Vector2(0, 30)
	_container.add_child(_title_label)

	_rebuild_keys()


func _rebuild_keys() -> void:
	# Clear old buttons
	for btn in _key_buttons:
		btn.queue_free()
	_key_buttons.clear()
	for c in _container.get_children():
		if c != _title_label:
			c.queue_free()

	var layout_data := _get_current_layout()
	_title_label.text = "VIRTUAL KEYBOARD — %s" % layout_data.get("label", "?")

	var row_index := 0
	for row in ROWS:
		var row_box := HBoxContainer.new()
		row_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_box.alignment = BoxContainer.ALIGNMENT_CENTER
		row_box.add_theme_constant_override("separation", 3)
		_container.add_child(row_box)

		for col in row.size():
			var kc: int = row[col]
			var btn := _make_key_button(kc, layout_data)
			btn.set_meta("row", row_index)
			btn.set_meta("col", col)
			row_box.add_child(btn)
			_key_buttons.append(btn)
		row_index += 1


func _get_current_layout() -> Dictionary:
	if _pause_menu == null:
		return LAYOUTS.get("us", {})
	var kl: Dictionary = _pause_menu.get_keyboard_layout()
	var id: String = kl.get("layout", "us")
	return LAYOUTS.get(id, LAYOUTS.get("us", {}))


func _make_key_button(keycode: int, layout_data: Dictionary) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL

	# Label
	var is_mod: bool = keycode in MODIFIER_KEYS
	if SPECIAL_LABELS.has(keycode):
		btn.text = SPECIAL_LABELS[keycode]
	elif is_mod:
		btn.text = ""
	else:
		var entry: Dictionary = layout_data.get(keycode, {})
		btn.text = entry.get("n", "?")

	# Size
	match keycode:
		KEY_BACKSPACE, KEY_ENTER:
			btn.custom_minimum_size = Vector2(70, 36)
		KEY_TAB:
			btn.custom_minimum_size = Vector2(50, 36)
		KEY_SHIFT:
			btn.custom_minimum_size = Vector2(80, 36)
		KEY_SPACE:
			btn.custom_minimum_size = Vector2(300, 36)
		KEY_CTRL, KEY_ALT:
			btn.custom_minimum_size = Vector2(50, 36)
		_:
			btn.custom_minimum_size = Vector2(44, 36)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_size_override("font_size", 13)

	# Style
	var normal_color := Color(0.12, 0.14, 0.2, 0.9)
	if is_mod:
		normal_color = Color(0.15, 0.18, 0.28, 0.9)

	var n := StyleBoxFlat.new()
	n.bg_color = normal_color
	n.border_color = Color(0.3, 0.4, 0.6, 0.4)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 4; n.corner_radius_top_right = 4
	n.corner_radius_bottom_left = 4; n.corner_radius_bottom_right = 4
	n.content_margin_left = 4; n.content_margin_right = 4
	n.content_margin_top = 4; n.content_margin_bottom = 4
	btn.add_theme_stylebox_override("normal", n)

	var h := n.duplicate()
	h.bg_color = Color(0.18, 0.22, 0.35, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.7)
	btn.add_theme_stylebox_override("hover", h)

	var p := n.duplicate()
	p.bg_color = Color(0.2, 0.3, 0.5, 0.95)
	btn.add_theme_stylebox_override("pressed", p)

	var fb := n.duplicate()
	fb.border_color = Color(0.5, 0.7, 1.0, 0.8)
	btn.add_theme_stylebox_override("focus", fb)

	# Store keycode as metadata
	btn.set_meta("keycode", keycode)

	# Connect press
	btn.pressed.connect(_on_key_pressed.bind(keycode, btn))

	return btn


func _on_key_pressed(keycode: int, btn: Button) -> void:
	if _compositor == null:
		return

	var layout_data := _get_current_layout()

	# Toggle modifiers
	match keycode:
		KEY_SHIFT:
			_shift_locked = not _shift_locked
			_update_mod_button_style(btn, _shift_locked)
			_update_all_labels(layout_data)
			return
		KEY_CTRL:
			_ctrl_locked = not _ctrl_locked
			_update_mod_button_style(btn, _ctrl_locked)
			return
		KEY_ALT:
			_alt_locked = not _alt_locked
			_update_mod_button_style(btn, _alt_locked)
			return

	# Apply active modifiers
	if _shift_locked:
		_compositor.forward_keyboard_key(KEY_SHIFT, 0, true)
	if _ctrl_locked:
		_compositor.forward_keyboard_key(KEY_CTRL, 0, true)
	if _alt_locked:
		_compositor.forward_keyboard_key(KEY_ALT, 0, true)

	# Press the key
	_compositor.forward_keyboard_key(keycode, 0, true)
	_compositor.forward_keyboard_key(keycode, 0, false)

	# Release modifiers
	if _alt_locked:
		_compositor.forward_keyboard_key(KEY_ALT, 0, false)
	if _ctrl_locked:
		_compositor.forward_keyboard_key(KEY_CTRL, 0, false)
	if _shift_locked:
		_compositor.forward_keyboard_key(KEY_SHIFT, 0, false)


func _update_mod_button_style(btn: Button, active: bool) -> void:
	var p: StyleBoxFlat = btn.get_theme_stylebox("pressed") as StyleBoxFlat
	if p == null:
		return
	if active:
		var active_style := p.duplicate()
		active_style.bg_color = Color(0.25, 0.4, 0.65, 0.95)
		active_style.border_color = Color(0.5, 0.7, 1.0, 0.8)
		btn.add_theme_stylebox_override("normal", active_style)
		btn.add_theme_stylebox_override("pressed", active_style)
	else:
		var normal_color := Color(0.15, 0.18, 0.28, 0.9)
		var n := StyleBoxFlat.new()
		n.bg_color = normal_color
		n.border_color = Color(0.3, 0.4, 0.6, 0.4)
		n.border_width_top = 1; n.border_width_bottom = 1
		n.border_width_left = 1; n.border_width_right = 1
		n.corner_radius_top_left = 4; n.corner_radius_top_right = 4
		n.corner_radius_bottom_left = 4; n.corner_radius_bottom_right = 4
		n.content_margin_left = 4; n.content_margin_right = 4
		n.content_margin_top = 4; n.content_margin_bottom = 4
		btn.add_theme_stylebox_override("normal", n)
		btn.add_theme_stylebox_override("pressed", n)


func _update_all_labels(layout_data: Dictionary) -> void:
	for btn in _key_buttons:
		if not is_instance_valid(btn):
			continue
		var kc: int = btn.get_meta("keycode", -1)
		if kc in MODIFIER_KEYS or SPECIAL_LABELS.has(kc):
			continue
		var entry: Dictionary = layout_data.get(kc, {})
		if _shift_locked:
			btn.text = entry.get("s", entry.get("n", "?"))
		else:
			btn.text = entry.get("n", "?")


func _can_stick_input() -> bool:
	return _radial_menu == null or not _radial_menu.visible


func _input(event: InputEvent) -> void:
	if not visible or (_radial_menu != null and _radial_menu.visible):
		return
	# Consume gamepad stick to prevent passthrough
	if event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
	# Let ui_accept (A button) pass through so the focused Button receives it
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_A:
		return
	# Consume other gamepad buttons to prevent passthrough
	if event is InputEventJoypadButton:
		get_viewport().set_input_as_handled()


func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()


func show_menu() -> void:
	_shift_locked = false
	_ctrl_locked = false
	_alt_locked = false
	var layout_data := _get_current_layout()
	_update_all_labels(layout_data)
	# Reset mod button styles
	for btn in _key_buttons:
		if is_instance_valid(btn) and btn.get_meta("keycode", -1) in MODIFIER_KEYS:
			_update_mod_button_style(btn, false)
	visible = true
	# Focus first letter key
	for btn in _key_buttons:
		if is_instance_valid(btn):
			var kc: int = btn.get_meta("keycode", -1)
			if kc == KEY_A:
				btn.grab_focus()
				break


func hide_menu() -> void:
	visible = false
	keyboard_closed.emit()


func _get_focusable(action: String) -> Array:
	var current := get_viewport().gui_get_focus_owner()
	if current == null or not current.has_meta("row"):
		return _key_buttons

	var cur_row: int = current.get_meta("row", 0)
	var cur_col: int = current.get_meta("col", 0)
	var num_rows: int = ROWS.size()

	match action:
		"ui_up":
			return _find_in_row((cur_row - 1 + num_rows) % num_rows, cur_col)
		"ui_down":
			return _find_in_row((cur_row + 1) % num_rows, cur_col)
		"ui_left":
			var max_col: int = ROWS[cur_row].size() - 1
			return _find_in_row_col(cur_row, (cur_col - 1 + max_col + 1) % (max_col + 1))
		"ui_right":
			var max_col: int = ROWS[cur_row].size() - 1
			return _find_in_row_col(cur_row, (cur_col + 1) % (max_col + 1))
	return _key_buttons


func _find_in_row(target_row: int, prefer_col: int) -> Array:
	var candidates: Array = []
	for btn in _key_buttons:
		if not is_instance_valid(btn):
			continue
		if btn.get_meta("row", -1) == target_row:
			candidates.append(btn)
	if candidates.is_empty():
		return []
	# Pick the one closest to prefer_col
	var best = candidates[0]
	var best_dist := absf(best.get_meta("col", 0) - prefer_col)
	for i in range(1, candidates.size()):
		var d := absf(candidates[i].get_meta("col", 0) - prefer_col)
		if d < best_dist:
			best = candidates[i]
			best_dist = d
	return [best]


func _find_in_row_col(target_row: int, target_col: int) -> Array:
	for btn in _key_buttons:
		if not is_instance_valid(btn):
			continue
		if btn.get_meta("row", -1) == target_row and btn.get_meta("col", -1) == target_col:
			return [btn]
	return []
