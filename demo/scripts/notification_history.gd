extends PanelContainer

signal menu_closed()

var notifications: Array[Dictionary] = []
var container: VBoxContainer

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	_apply_styling()
	container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 4)
	add_child(container)

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

	custom_minimum_size = Vector2(420, 500)
	size = Vector2(420, 500)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -210
	offset_right = 210
	offset_top = -250
	offset_bottom = 250

func _make_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	lbl.custom_minimum_size = Vector2(0, 44)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

func _make_btn(text: String, color := Color(0.12, 0.14, 0.2, 0.9)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 36)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 14)

	var n := StyleBoxFlat.new()
	n.bg_color = color
	n.border_color = Color(0.3, 0.4, 0.6, 0.5)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 5; n.corner_radius_top_right = 5
	n.corner_radius_bottom_left = 5; n.corner_radius_bottom_right = 5
	n.content_margin_left = 14; n.content_margin_right = 14
	n.content_margin_top = 6; n.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", n)

	var h := n.duplicate()
	h.bg_color = Color(0.18, 0.22, 0.35, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.7)
	btn.add_theme_stylebox_override("hover", h)

	var p := n.duplicate()
	p.bg_color = Color(0.2, 0.3, 0.5, 0.95)
	btn.add_theme_stylebox_override("pressed", p)
	return btn

func add_notification(app_name: String, summary: String, body: String, app_icon: String, urgency: int) -> void:
	var entry := {
		app_name = app_name,
		summary = summary,
		body = body,
		app_icon = app_icon,
		urgency = urgency,
		time = Time.get_time_string_from_system()
	}
	notifications.push_front(entry)
	if notifications.size() > 100:
		notifications.pop_back()

func _clear_all() -> void:
	notifications.clear()
	if visible:
		_refresh()

func _refresh() -> void:
	for c in container.get_children():
		c.queue_free()

	container.add_child(_make_title("NOTIFICATIONS"))

	if notifications.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "  No notification  "
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_font_size_override("font_size", 14)
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
		empty_lbl.custom_minimum_size = Vector2(0, 60)
		empty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(empty_lbl)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 4)

		for entry in notifications:
			var row := _make_notif_row(entry)
			list.add_child(row)

		scroll.add_child(list)
		container.add_child(scroll)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.custom_minimum_size = Vector2(0, 4)
	container.add_child(spacer)

	var bottom_hbox := HBoxContainer.new()
	bottom_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_hbox.add_theme_constant_override("separation", 6)

	var clear_btn := _make_btn("Clear")
	clear_btn.pressed.connect(_clear_all)
	bottom_hbox.add_child(clear_btn)

	var close_btn := _make_btn("Close")
	close_btn.pressed.connect(hide_menu)
	bottom_hbox.add_child(close_btn)

	container.add_child(bottom_hbox)

func _make_notif_row(entry: Dictionary) -> PanelContainer:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.12, 0.17, 0.85)
	bg.corner_radius_top_left = 5
	bg.corner_radius_top_right = 5
	bg.corner_radius_bottom_left = 5
	bg.corner_radius_bottom_right = 5
	bg.content_margin_left = 10
	bg.content_margin_right = 10
	bg.content_margin_top = 6
	bg.content_margin_bottom = 6

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", bg)
	panel.add_child(vbox)

	var time_lbl := Label.new()
	time_lbl.text = entry["time"]
	time_lbl.add_theme_font_size_override("font_size", 10)
	time_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
	time_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(time_lbl)

	if entry["app_name"] != "":
		var app_lbl := Label.new()
		var prefix = "⚠ " if entry["urgency"] == 2 else ""
		app_lbl.text = prefix + entry["app_name"]
		app_lbl.add_theme_font_size_override("font_size", 13)
		app_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.9) if entry["urgency"] < 2 else Color(0.95, 0.6, 0.4))
		app_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(app_lbl)

	var summary = entry["summary"]
	var body = entry["body"]
	if summary != "":
		var s_lbl := Label.new()
		s_lbl.text = summary
		s_lbl.add_theme_font_size_override("font_size", 14)
		s_lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
		s_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		s_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(s_lbl)
	if body != "":
		var b_lbl := Label.new()
		b_lbl.text = body
		b_lbl.add_theme_font_size_override("font_size", 12)
		b_lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
		b_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		b_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(b_lbl)

	return panel

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	visible = true
	_refresh()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	visible = false
	menu_closed.emit()

func _process(delta: float) -> void:
	pass

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
