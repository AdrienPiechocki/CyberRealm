extends PanelContainer

signal menu_closed()

var notifications: Array[Dictionary] = []
var container: VBoxContainer
var compositor_ref = null

func setup(compositor) -> void:
	compositor_ref = compositor

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

func add_notification(app_name: String, summary: String, body: String, app_icon: String, urgency: int, id: int = 0, actions: PackedStringArray = PackedStringArray()) -> void:
	var entry := {
		app_name = app_name,
		summary = summary,
		body = body,
		app_icon = app_icon,
		urgency = urgency,
		time = Time.get_time_string_from_system(),
		id = id,
		actions = actions,
	}
	notifications.push_front(entry)
	if notifications.size() > 100:
		notifications.pop_back()

func _remove_notification(entry: Dictionary) -> void:
	notifications.erase(entry)
	if visible:
		_refresh()

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

	var bg_hover := bg.duplicate()
	bg_hover.bg_color = Color(0.18, 0.22, 0.35, 0.92)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", bg)
	panel.add_child(vbox)

	# Click on body -> invoke default action
	panel.mouse_entered.connect(func():
		panel.add_theme_stylebox_override("panel", bg_hover)
	)
	panel.mouse_exited.connect(func():
		panel.add_theme_stylebox_override("panel", bg)
	)

	var can_invoke = compositor_ref != null and entry.id > 0 and not entry.actions.is_empty()
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if can_invoke else Control.CURSOR_ARROW

	if can_invoke:
		panel.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_invoke_default(entry)
		)

	var time_hbox := HBoxContainer.new()
	time_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var time_lbl := Label.new()
	time_lbl.text = entry["time"]
	time_lbl.add_theme_font_size_override("font_size", 10)
	time_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))
	time_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	time_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_hbox.add_child(time_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(22, 22)
	close_btn.add_theme_font_size_override("font_size", 10)
	var cb_n := StyleBoxFlat.new()
	cb_n.bg_color = Color(0.2, 0.05, 0.05, 0.6)
	cb_n.corner_radius_top_left = 3; cb_n.corner_radius_top_right = 3
	cb_n.corner_radius_bottom_left = 3; cb_n.corner_radius_bottom_right = 3
	cb_n.content_margin_left = 2; cb_n.content_margin_right = 2
	cb_n.content_margin_top = 0; cb_n.content_margin_bottom = 0
	close_btn.add_theme_stylebox_override("normal", cb_n)
	var cb_h := cb_n.duplicate()
	cb_h.bg_color = Color(0.4, 0.1, 0.1, 0.8)
	close_btn.add_theme_stylebox_override("hover", cb_h)
	close_btn.pressed.connect(_remove_notification.bind(entry))
	time_hbox.add_child(close_btn)

	vbox.add_child(time_hbox)

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

	# Action buttons
	var actions: PackedStringArray = entry.get("actions", PackedStringArray())
	if can_invoke and actions.size() >= 2:
		var action_hbox := HBoxContainer.new()
		action_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_hbox.add_theme_constant_override("separation", 4)
		var i := 0
		while i + 1 < actions.size():
			var key = actions[i]
			var label = actions[i + 1]
			var btn := _make_small_btn(label)
			var notif_id = entry.id
			btn.pressed.connect(func(k = key):
				_invoke_action(notif_id, k)
			)
			action_hbox.add_child(btn)
			i += 2
		vbox.add_child(action_hbox)

	return panel

func _make_small_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 28)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_size_override("font_size", 12)

	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.15, 0.17, 0.25, 0.9)
	n.border_color = Color(0.3, 0.4, 0.6, 0.4)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 4; n.corner_radius_top_right = 4
	n.corner_radius_bottom_left = 4; n.corner_radius_bottom_right = 4
	n.content_margin_left = 10; n.content_margin_right = 10
	n.content_margin_top = 2; n.content_margin_bottom = 2
	btn.add_theme_stylebox_override("normal", n)

	var h := n.duplicate()
	h.bg_color = Color(0.25, 0.3, 0.45, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.6)
	btn.add_theme_stylebox_override("hover", h)

	return btn

func _invoke_default(entry: Dictionary) -> void:
	var actions: PackedStringArray = entry.get("actions", PackedStringArray())
	for i in actions.size():
		if actions[i] == "default" and i + 1 < actions.size():
			_invoke_action(entry.id, "default")
			return
	# If no "default" action, invoke the first action
	if actions.size() >= 2:
		_invoke_action(entry.id, actions[0])

func _invoke_action(notif_id: int, action_key: String) -> void:
	if not compositor_ref or notif_id <= 0:
		return
	compositor_ref.notif_invoke_action(notif_id, action_key)

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
