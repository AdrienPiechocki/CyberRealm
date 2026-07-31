extends PanelContainer

signal quit_requested
signal app_launch_requested(command: String)

const SETTINGS_PATH := "user://settings.json"

var container: VBoxContainer

# Actions remappables depuis le menu (ordre d'affichage).
const REMAPPABLE_ACTIONS := [
	"forward", "back", "left", "right", "jump",
	"interact_mode", "launcher", "window_menu",
	"grab", "focus_window", "pin_window", "layer_interact",
	"left_click", "right_click", "scroll_up", "scroll_down",
]

var _settings: Dictionary = {}
var _current_view := "main" # "main" | "keybinds" | "startup" | "launcher"
var _waiting_action := "" # action en cours de rebind, "" = aucun
var _keybinds_buttons: Dictionary = {} # action -> Button

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 6)
	add_child(container)
	_apply_styling()
	_settings = _load_settings()
	_apply_saved_keybinds()

func _apply_styling() -> void:
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

	custom_minimum_size = Vector2(520, 460)
	size = Vector2(520, 460)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -260
	offset_right = 260
	offset_top = -230
	offset_bottom = 230

func _clear() -> void:
	for c in container.get_children():
		c.queue_free()

func _make_spacer() -> Control:
	var s := Control.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s

func _make_btn(text: String, color := Color(0.12, 0.14, 0.2, 0.9)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 42)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 15)

	var n := StyleBoxFlat.new()
	n.bg_color = color
	n.border_color = Color(0.3, 0.4, 0.6, 0.5)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 5; n.corner_radius_top_right = 5
	n.corner_radius_bottom_left = 5; n.corner_radius_bottom_right = 5
	n.content_margin_left = 14; n.content_margin_right = 14
	n.content_margin_top = 8; n.content_margin_bottom = 8
	btn.add_theme_stylebox_override("normal", n)

	var h := n.duplicate()
	h.bg_color = Color(0.18, 0.22, 0.35, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.7)
	btn.add_theme_stylebox_override("hover", h)

	var p := n.duplicate()
	p.bg_color = Color(0.2, 0.3, 0.5, 0.95)
	btn.add_theme_stylebox_override("pressed", p)
	return btn

func _make_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	lbl.custom_minimum_size = Vector2(0, 50)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

func _make_back_btn() -> Button:
	var back := _make_btn("Back", Color(0.18, 0.18, 0.25, 0.9))
	back.pressed.connect(_show_main)
	return back

func _make_line_edit() -> LineEdit:
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 36)
	le.add_theme_font_size_override("font_size", 14)

	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	n.border_color = Color(0.3, 0.4, 0.6, 0.5)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 5; n.corner_radius_top_right = 5
	n.corner_radius_bottom_left = 5; n.corner_radius_bottom_right = 5
	n.content_margin_left = 12; n.content_margin_right = 12
	le.add_theme_stylebox_override("normal", n)

	var f := n.duplicate()
	f.border_color = Color(0.4, 0.6, 1.0, 0.7)
	le.add_theme_stylebox_override("focus", f)

	le.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	le.add_theme_color_override("font_placeholder_color", Color(0.5, 0.52, 0.58))
	le.add_theme_color_override("caret_color", Color(0.9, 0.92, 0.95))
	return le

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	visible = true
	_show_main()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true

func hide_menu() -> void:
	_waiting_action = ""
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false

# ── Pages ────────────────────────────────────────────────────────────

func _show_main() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "main"

	container.add_child(_make_title("MAIN MENU"))

	container.add_child(_make_spacer())

	var keybinds_btn := _make_btn("Remap keybinds")
	keybinds_btn.pressed.connect(_show_keybinds)
	container.add_child(keybinds_btn)

	var startup_btn := _make_btn("Startup Apps")
	startup_btn.pressed.connect(_show_startup_apps)
	container.add_child(startup_btn)

	var launcher_btn := _make_btn("Launcher Command")
	launcher_btn.pressed.connect(_show_launcher)
	container.add_child(launcher_btn)

	var quit_btn := _make_btn("Quit", Color(0.25, 0.1, 0.1, 0.9))
	quit_btn.pressed.connect(func():
		quit_requested.emit()
	)
	container.add_child(quit_btn)

func _show_keybinds() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "keybinds"

	container.add_child(_make_title("REMAP KEYBINDS"))

	var hint := Label.new()
	hint.text = "Click an action, then press a key or mouse button (Escape = cancel)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	container.add_child(scroll)

	_keybinds_buttons.clear()
	for action in REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var label := Label.new()
		label.text = action
		label.custom_minimum_size = Vector2(190, 0)
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
		row.add_child(label)

		var btn := _make_btn(_binding_text(action))
		btn.custom_minimum_size = Vector2(170, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(_start_rebind.bind(action))
		row.add_child(btn)
		_keybinds_buttons[action] = btn

		list.add_child(row)

	container.add_child(_make_back_btn())

func _show_startup_apps() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "startup"

	container.add_child(_make_title("STARTUP APPS"))

	var hint := Label.new()
	hint.text = "Apps launched when the compositor starts."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	container.add_child(scroll)

	var apps: Array = _settings.get("startup_apps", [])
	if apps.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no startup apps)"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
		list.add_child(empty_label)
	else:
		for app in apps:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var label := Label.new()
			label.text = app
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			label.add_theme_font_size_override("font_size", 14)
			label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
			row.add_child(label)

			var launch_btn := _make_btn("Launch")
			launch_btn.custom_minimum_size = Vector2(110, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(_launch_app.bind(app))
			row.add_child(launch_btn)

			var remove_btn := _make_btn("Remove", Color(0.25, 0.1, 0.1, 0.9))
			remove_btn.custom_minimum_size = Vector2(110, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_startup_app.bind(app))
			row.add_child(remove_btn)

			list.add_child(row)

	container.add_child(_make_spacer())

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := _make_line_edit()
	le.placeholder_text = "command (ex: firefox, konsole)"
	le.text_submitted.connect(func(text: String):
		_add_startup_app(text.strip_edges())
	)
	add_row.add_child(le)
	var add_btn := _make_btn("Add")
	add_btn.custom_minimum_size = Vector2(90, 36)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_btn.pressed.connect(_add_from_line_edit.bind(le))
	add_row.add_child(add_btn)
	container.add_child(add_row)

	container.add_child(_make_back_btn())

func _show_launcher() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "launcher"

	container.add_child(_make_title("LAUNCHER COMMAND"))

	var hint := Label.new()
	hint.text = "Command launched by the launcher key."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	container.add_child(_make_spacer())

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := _make_line_edit()
	le.text = get_launcher_command()
	le.select_all()
	row.add_child(le)
	container.add_child(row)

	container.add_child(_make_spacer())

	var save_btn := _make_btn("Save")
	save_btn.pressed.connect(_save_launcher_command_from_edit.bind(le))
	container.add_child(save_btn)

	container.add_child(_make_back_btn())

# ── Startup apps ─────────────────────────────────────────────────────

func get_startup_apps() -> Array:
	return _settings.get("startup_apps", [])

func _launch_app(app: String) -> void:
	app_launch_requested.emit(app)

func _add_from_line_edit(le: LineEdit) -> void:
	_add_startup_app(le.text.strip_edges())

func _add_startup_app(cmd: String) -> void:
	if cmd == "":
		return
	var apps: Array = _settings.get("startup_apps", [])
	if not apps.has(cmd):
		apps.append(cmd)
	_settings["startup_apps"] = apps
	_save_settings()
	_show_startup_apps()

func _remove_startup_app(cmd: String) -> void:
	var apps: Array = _settings.get("startup_apps", [])
	apps.erase(cmd)
	_settings["startup_apps"] = apps
	_save_settings()
	_show_startup_apps()

# ── Launcher command ─────────────────────────────────────────────────

func get_launcher_command() -> String:
	var cmd: String = _settings.get("launcher_command", "")
	if cmd == "":
		cmd = "konsole"
	return cmd

func _save_launcher_command_from_edit(le: LineEdit) -> void:
	var cmd := le.text.strip_edges()
	if cmd == "":
		return
	_settings["launcher_command"] = cmd
	_save_settings()
	_show_launcher()

func _test_launcher_from_edit(le: LineEdit) -> void:
	var cmd := le.text.strip_edges()
	if cmd != "":
		app_launch_requested.emit(cmd)

# ── Keybinds ─────────────────────────────────────────────────────────

func _binding_text(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "None"
	var ev: InputEvent = events[0]
	if ev is InputEventKey:
		var kev := ev as InputEventKey
		var code := kev.physical_keycode
		if code == 0:
			code = kev.keycode
		if code == 0:
			return "None"
		return OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		return _mouse_button_name(ev.button_index)
	return "None"

func _mouse_button_name(button: int) -> String:
	match button:
		MOUSE_BUTTON_LEFT: return "Left Click"
		MOUSE_BUTTON_RIGHT: return "Right Click"
		MOUSE_BUTTON_MIDDLE: return "Middle Click"
		MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
		MOUSE_BUTTON_WHEEL_LEFT: return "Wheel Left"
		MOUSE_BUTTON_WHEEL_RIGHT: return "Wheel Right"
	return "Mouse %d" % button

func _start_rebind(action: String) -> void:
	_waiting_action = action
	for a in _keybinds_buttons:
		_keybinds_buttons[a].text = _binding_text(a)
	if _keybinds_buttons.has(action):
		_keybinds_buttons[action].text = "Press key / click..."

func _cancel_rebind() -> void:
	var pending := _waiting_action
	_waiting_action = ""
	if pending != "" and _keybinds_buttons.has(pending):
		_keybinds_buttons[pending].text = _binding_text(pending)

func _apply_saved_keybinds() -> void:
	var binds: Dictionary = _settings.get("keybinds", {})
	for action in binds:
		if not InputMap.has_action(action):
			continue
		if not binds[action] is Dictionary:
			continue
		var bind: Dictionary = binds[action]
		match bind.get("type", ""):
			"mouse":
				var ev := InputEventMouseButton.new()
				ev.button_index = bind.get("button", MOUSE_BUTTON_LEFT)
				InputMap.action_erase_events(action)
				InputMap.action_add_event(action, ev)
			"key":
				var code: int = bind.get("code", 0)
				if code != 0:
					var kev := InputEventKey.new()
					kev.physical_keycode = code
					InputMap.action_erase_events(action)
					InputMap.action_add_event(action, kev)

func _save_keybinds() -> void:
	var binds := {}
	for action in REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var events := InputMap.action_get_events(action)
		if events.is_empty():
			continue
		var ev: InputEvent = events[0]
		if ev is InputEventKey:
			var kev := ev as InputEventKey
			var code := kev.physical_keycode
			if code == 0:
				code = kev.keycode
			if code != 0:
				binds[action] = {"type": "key", "code": code}
		elif ev is InputEventMouseButton:
			binds[action] = {"type": "mouse", "button": ev.button_index}
	_settings["keybinds"] = binds
	_save_settings()

# ── Persistance ──────────────────────────────────────────────────────

func _load_settings() -> Dictionary:
	var data := {}
	if FileAccess.file_exists(SETTINGS_PATH):
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				data = parsed
	return data

func _save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_settings, "  "))

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _waiting_action != "":
				_cancel_rebind()
			elif _current_view == "main":
				hide_menu()
			else:
				_show_main()
			get_viewport().set_input_as_handled()
			return

	if _waiting_action == "":
		return

	var new_event: InputEvent = null
	if event is InputEventKey and event.pressed and not event.echo:
		var ev := InputEventKey.new()
		ev.physical_keycode = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if ev.physical_keycode != 0:
			new_event = ev
	elif event is InputEventMouseButton and event.pressed:
		var ev := InputEventMouseButton.new()
		ev.button_index = event.button_index
		new_event = ev

	if new_event == null:
		return

	var action := _waiting_action
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, new_event)
	_save_keybinds()
	_waiting_action = ""
	if _keybinds_buttons.has(action):
		_keybinds_buttons[action].text = _binding_text(action)
	get_viewport().set_input_as_handled()
