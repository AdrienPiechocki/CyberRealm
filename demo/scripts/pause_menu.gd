extends PanelContainer

signal fps_toggled(visible: bool)
signal capture_label_toggled(visible: bool)
signal terminal_changed(terminal: String)

enum Page { MAIN, RESOLUTION, TERMINAL, KEYBINDS }

var current_page := Page.MAIN
var container: VBoxContainer
var selected_terminal := ""
var _binding_action := ""

const RESOLUTIONS := [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

var _default_keybinds: Dictionary = {}

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_detect_terminal()
	_save_default_keybinds()
	container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 6)
	add_child(container)
	_apply_styling()

func _save_default_keybinds() -> void:
	var actions := [	"forward", "back", "left", "right", "jump",
		"interact_mode", "launcher", "window_menu",
		"grab", "focus_window", "pin_window"]
	for action in actions:
		_default_keybinds[action] = InputMap.action_get_events(action).duplicate()

func _detect_terminal() -> void:
	var output: Array = []
	if OS.execute("which", ["konsole"], output, true) == 0 and output[0].strip_edges() != "":
		selected_terminal = "konsole"
	else:
		selected_terminal = "xterm"

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

	custom_minimum_size = Vector2(500, 600)
	size = Vector2(500, 600)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -250
	offset_right = 250
	offset_top = -300
	offset_bottom = 300

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

func _make_cb(text: String, checked: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 42)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.14, 0.2, 0.9)
	bg.corner_radius_top_left = 5; bg.corner_radius_top_right = 5
	bg.corner_radius_bottom_left = 5; bg.corner_radius_bottom_right = 5
	bg.content_margin_left = 16; bg.content_margin_right = 14
	bg.content_margin_top = 6; bg.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", bg)

	var bg_hover := bg.duplicate()
	bg_hover.bg_color = Color(0.18, 0.22, 0.35, 0.95)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(hbox)

	var cb := CheckBox.new()
	cb.button_pressed = checked
	cb.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("disabled", StyleBoxEmpty.new())
	hbox.add_child(cb)

	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(label)

	cb.toggled.connect(func(v: bool):
		panel.modulate = Color(1, 1, 1, 1) if v else Color(0.7, 0.7, 0.75, 0.8)
	)

	panel.mouse_entered.connect(func():
		panel.add_theme_stylebox_override("panel", bg_hover)
	)
	panel.mouse_exited.connect(func():
		panel.add_theme_stylebox_override("panel", bg)
	)
	panel.set_meta("checkbox", cb)
	return panel

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
	var btn := _make_btn("← Back")
	btn.pressed.connect(_show_main)
	return btn

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
	visible = false
	_binding_action = ""
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	get_tree().paused = false

func _show_main() -> void:
	current_page = Page.MAIN
	_clear()

	container.add_child(_make_title("MAIN MENU"))

	var res_btn := _make_btn("Change Resolution")
	res_btn.pressed.connect(_show_resolution)
	container.add_child(res_btn)

	var is_fs := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	var fs_cb := _make_cb("Fullscreen", is_fs)
	fs_cb.get_meta("checkbox").toggled.connect(func(v: bool):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if v else DisplayServer.WINDOW_MODE_WINDOWED)
	)
	container.add_child(fs_cb)

	var term_btn := _make_btn("Choose Terminal")
	term_btn.pressed.connect(_show_terminal)
	container.add_child(term_btn)

	var kb_btn := _make_btn("Change Keybinds")
	kb_btn.pressed.connect(_show_keybinds)
	container.add_child(kb_btn)

	var fps_cb := _make_cb("Show FPS", true)
	fps_cb.get_meta("checkbox").toggled.connect(func(v: bool):
		fps_toggled.emit(v)
	)
	container.add_child(fps_cb)

	var cap_cb := _make_cb("Show \"Keyboard Capture\"", true)
	cap_cb.get_meta("checkbox").toggled.connect(func(v: bool):
		capture_label_toggled.emit(v)
	)
	container.add_child(cap_cb)

	container.add_child(_make_spacer())

	var quit_btn := _make_btn("Quit", Color(0.25, 0.1, 0.1, 0.9))
	quit_btn.pressed.connect(func():
		get_tree().quit()
	)
	container.add_child(quit_btn)

func _show_resolution() -> void:
	current_page = Page.RESOLUTION
	_clear()

	container.add_child(_make_back_btn())
	container.add_child(_make_title("Resolution"))

	for res in RESOLUTIONS:
		var btn := _make_btn("%d × %d" % [res.x, res.y])
		btn.pressed.connect(func(r = res):
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(r)
			var screen := DisplayServer.window_get_current_screen()
			var screen_rect := DisplayServer.screen_get_usable_rect(screen)
			DisplayServer.window_set_position(Vector2i(
				screen_rect.position.x + (screen_rect.size.x - r.x) / 2,
				screen_rect.position.y + (screen_rect.size.y - r.y) / 2
			))
		)
		container.add_child(btn)

	container.add_child(_make_spacer())

func _show_terminal() -> void:
	current_page = Page.TERMINAL
	_clear()

	container.add_child(_make_back_btn())
	container.add_child(_make_title("Terminal"))

	var hint := Label.new()
	hint.text = "Terminal launch command\n(e.g. konsole, alacritty, xterm)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
	hint.custom_minimum_size = Vector2(0, 40)
	container.add_child(hint)

	var line_edit := LineEdit.new()
	line_edit.text = selected_terminal
	line_edit.placeholder_text = "konsole"
	line_edit.custom_minimum_size = Vector2(0, 42)
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_edit.add_theme_font_size_override("font_size", 16)

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.14, 0.2, 0.9)
	bg.border_color = Color(0.3, 0.4, 0.6, 0.5)
	bg.border_width_top = 1; bg.border_width_bottom = 1
	bg.border_width_left = 1; bg.border_width_right = 1
	bg.corner_radius_top_left = 5; bg.corner_radius_top_right = 5
	bg.corner_radius_bottom_left = 5; bg.corner_radius_bottom_right = 5
	bg.content_margin_left = 14; bg.content_margin_right = 14
	bg.content_margin_top = 8; bg.content_margin_bottom = 8
	line_edit.add_theme_stylebox_override("normal", bg)

	var focus_bg := bg.duplicate()
	focus_bg.border_color = Color(0.4, 0.6, 1.0, 0.7)
	line_edit.add_theme_stylebox_override("focus", focus_bg)

	container.add_child(line_edit)

	var save_btn := _make_btn("Apply")
	save_btn.pressed.connect(func():
		var cmd := line_edit.text.strip_edges()
		if cmd != "":
			selected_terminal = cmd
			terminal_changed.emit(cmd)
		_show_main()
	)
	container.add_child(save_btn)

	container.add_child(_make_spacer())

func _show_keybinds() -> void:
	current_page = Page.KEYBINDS
	_clear()

	container.add_child(_make_back_btn())
	container.add_child(_make_title("Keybinds"))

	if _binding_action != "":
		var binding_hint := Label.new()
		binding_hint.text = "Press a key for\n« %s » (Escape to cancel)" % _binding_action
		binding_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		binding_hint.add_theme_font_size_override("font_size", 14)
		binding_hint.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		binding_hint.custom_minimum_size = Vector2(0, 44)
		binding_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(binding_hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_theme_constant_override("separation", 0)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var action_order := [
		{"key": "forward", "name": "Move Forward"},
		{"key": "back", "name": "Move Back"},
		{"key": "left", "name": "Strafe Left"},
		{"key": "right", "name": "Strafe Right"},
		{"key": "jump", "name": "Jump"},
		{"key": "interact_mode", "name": "Interact Mode"},
		{"key": "launcher", "name": "App Launcher"},
		{"key": "window_menu", "name": "Window Menu"},
		{"key": "grab", "name": "Grab Window"},
		{"key": "focus_window", "name": "Focus Window"},
		{"key": "pin_window", "name": "Pin Window"},
	]

	for entry in action_order:
		var hbox := HBoxContainer.new()
		hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.custom_minimum_size = Vector2(0, 40)
		hbox.add_theme_constant_override("separation", 8)

		var mc := MarginContainer.new()
		mc.add_theme_constant_override("margin_left", 16)
		mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(mc)

		var name_lbl := Label.new()
		name_lbl.text = entry["name"]
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 14)
		name_lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mc.add_child(name_lbl)

		var key_btn := Button.new()
		key_btn.text = _get_key_name(entry["key"])
		key_btn.custom_minimum_size = Vector2(150, 0)
		key_btn.add_theme_font_size_override("font_size", 14)

		var n := StyleBoxFlat.new()
		n.bg_color = Color(0.12, 0.14, 0.2, 0.9)
		n.border_color = Color(0.3, 0.4, 0.6, 0.5)
		n.border_width_top = 1; n.border_width_bottom = 1
		n.border_width_left = 1; n.border_width_right = 1
		n.corner_radius_top_left = 4; n.corner_radius_top_right = 4
		n.corner_radius_bottom_left = 4; n.corner_radius_bottom_right = 4
		n.content_margin_left = 10; n.content_margin_right = 10
		n.content_margin_top = 6; n.content_margin_bottom = 6
		key_btn.add_theme_stylebox_override("normal", n)

		var h := n.duplicate()
		h.bg_color = Color(0.18, 0.22, 0.35, 0.95)
		key_btn.add_theme_stylebox_override("hover", h)

		var action_key = entry["key"]
		key_btn.pressed.connect(func(a = action_key):
			_start_binding(a)
		)
		hbox.add_child(key_btn)

		list.add_child(hbox)

	scroll.add_child(list)
	container.add_child(scroll)

	var reset_btn := _make_btn("Reset Keybinds")
	reset_btn.pressed.connect(_reset_keybinds)
	container.add_child(reset_btn)

func _get_key_name(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "—"
	var e := events[0]
	if e is InputEventKey:
		return OS.get_keycode_string(e.physical_keycode)
	if e is InputEventMouseButton:
		match e.button_index:
			MOUSE_BUTTON_LEFT: return "Left Click"
			MOUSE_BUTTON_RIGHT: return "Right Click"
			MOUSE_BUTTON_MIDDLE: return "Middle Click"
			_: return "Mouse %d" % e.button_index
	return "?"

func _start_binding(action: String) -> void:
	_binding_action = action
	_show_keybinds()

func _reset_keybinds() -> void:
	for action in _default_keybinds:
		InputMap.action_erase_events(action)
		for event in _default_keybinds[action]:
			InputMap.action_add_event(action, event)
	_binding_action = ""
	_show_keybinds()

func _input(event: InputEvent) -> void:
	if not visible:
		return

	if _binding_action != "":
		if event is InputEventKey and event.pressed:
			if event.keycode == KEY_ESCAPE:
				_binding_action = ""
				_show_keybinds()
				get_viewport().set_input_as_handled()
				return
			InputMap.action_erase_events(_binding_action)
			InputMap.action_add_event(_binding_action, event)
			_binding_action = ""
			_show_keybinds()
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.pressed:
			InputMap.action_erase_events(_binding_action)
			InputMap.action_add_event(_binding_action, event)
			_binding_action = ""
			_show_keybinds()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				match current_page:
					Page.MAIN:
						hide_menu()
					_:
						_show_main()
				get_viewport().set_input_as_handled()
