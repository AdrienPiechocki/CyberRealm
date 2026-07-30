extends PanelContainer

signal menu_closed()

var compositor_ref = null
var container: VBoxContainer
var refresh_timer: float = 0.0

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

	custom_minimum_size = Vector2(320, 400)
	size = Vector2(320, 400)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -160
	offset_right = 160
	offset_top = -200
	offset_bottom = 200

func _make_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	lbl.custom_minimum_size = Vector2(0, 40)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

func _refresh() -> void:
	for c in container.get_children():
		c.queue_free()

	container.add_child(_make_title("SYSTEM TRAY"))

	if not compositor_ref:
		var lbl := Label.new()
		lbl.text = "  No compositor  "
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
		lbl.custom_minimum_size = Vector2(0, 60)
		container.add_child(lbl)
		_add_bottom_buttons()
		return

	var items = compositor_ref.get_tray_items()
	if items.is_empty():
		var lbl := Label.new()
		lbl.text = "  No tray items  "
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
		lbl.custom_minimum_size = Vector2(0, 60)
		container.add_child(lbl)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 4)

		for item in items:
			var row := _make_item_row(item)
			list.add_child(row)

		scroll.add_child(list)
		container.add_child(scroll)

	_add_bottom_buttons()

func _add_bottom_buttons() -> void:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.custom_minimum_size = Vector2(0, 4)
	container.add_child(spacer)

	var bottom_hbox := HBoxContainer.new()
	bottom_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_hbox.add_theme_constant_override("separation", 6)

	var refresh_btn := _make_btn("Refresh")
	refresh_btn.pressed.connect(_refresh)
	bottom_hbox.add_child(refresh_btn)

	var close_btn := _make_btn("Close")
	close_btn.pressed.connect(hide_menu)
	bottom_hbox.add_child(close_btn)

	container.add_child(bottom_hbox)

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

func _make_item_row(item: Dictionary) -> PanelContainer:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.custom_minimum_size = Vector2(0, 44)
	hbox.add_theme_constant_override("separation", 8)

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
	panel.add_child(hbox)

	var idx = item["index"]

	# Icon placeholder
	var icon_lbl := Label.new()
	icon_lbl.text = "🖥"
	icon_lbl.custom_minimum_size = Vector2(32, 0)
	icon_lbl.add_theme_font_size_override("font_size", 18)
	hbox.add_child(icon_lbl)

	# Title
	var title_lbl := Label.new()
	title_lbl.text = item.get("id", "App #" + str(idx))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 14)
	title_lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	hbox.add_child(title_lbl)

	var activate_btn := _make_small_btn("Open")
	activate_btn.pressed.connect(func():
		if compositor_ref:
			compositor_ref.tray_item_activate(idx)
	)
	hbox.add_child(activate_btn)

	var menu_btn := _make_small_btn("Menu")
	menu_btn.pressed.connect(func():
		if compositor_ref:
			compositor_ref.tray_item_context_menu(idx)
	)
	hbox.add_child(menu_btn)

	return panel

func _make_small_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 28)
	btn.add_theme_font_size_override("font_size", 11)
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.15, 0.17, 0.25, 0.9)
	n.border_color = Color(0.3, 0.4, 0.6, 0.4)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 4; n.corner_radius_top_right = 4
	n.corner_radius_bottom_left = 4; n.corner_radius_bottom_right = 4
	n.content_margin_left = 8; n.content_margin_right = 8
	n.content_margin_top = 2; n.content_margin_bottom = 2
	btn.add_theme_stylebox_override("normal", n)
	var h := n.duplicate()
	h.bg_color = Color(0.25, 0.3, 0.45, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.6)
	btn.add_theme_stylebox_override("hover", h)
	return btn

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
	if not visible:
		return
	refresh_timer += delta
	if refresh_timer < 1.0:
		return
	refresh_timer = 0.0
	_refresh()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
