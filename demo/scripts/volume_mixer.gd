extends PanelContainer

signal menu_closed()

const PACTL := "pactl"

var sink_idx := -1
var sink_inputs: Array = []
var stream_rows: Dictionary = {} # pactl_index -> PanelContainer (la ligne UI)
var dragging: Dictionary = {} # slider -> true

var compositor_ref = null
var known_apps: Dictionary = {} # lowercase app_id -> true

var container: VBoxContainer
var master_slider: HSlider
var master_mute_btn: Button
var master_panel: PanelContainer
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
	_refresh()

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

func _clear() -> void:
	for c in container.get_children():
		c.queue_free()
	stream_rows.clear()

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

func _make_stream_row(label_text: String, pct: float, is_muted: bool, pactl_id: Variant) -> PanelContainer:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.custom_minimum_size = Vector2(0, 44)
	hbox.add_theme_constant_override("separation", 6)

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.12, 0.17, 0.85)
	bg.corner_radius_top_left = 5
	bg.corner_radius_top_right = 5
	bg.corner_radius_bottom_left = 5
	bg.corner_radius_bottom_right = 5
	bg.content_margin_left = 8
	bg.content_margin_right = 8
	bg.content_margin_top = 4
	bg.content_margin_bottom = 4

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", bg)
	panel.add_child(hbox)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(120, 0)
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(lbl)

	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(80, 0)
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.value = pct
	slider.add_theme_color_override("slider_color", Color(0.3, 0.5, 0.9, 0.8))
	slider.add_theme_color_override("grabber_icon_color", Color(0.5, 0.7, 1.0, 0.9))
	slider.scrollable = false
	dragging[slider] = false
	var row_id = pactl_id
	slider.value_changed.connect(func(val: float):
		if dragging.get(slider, false):
			_set_volume(row_id, int(val))
	)
	slider.drag_started.connect(func():
		dragging[slider] = true
	)
	slider.drag_ended.connect(func(_changed: bool):
		dragging[slider] = false
		_set_volume(row_id, int(slider.value))
	)
	hbox.add_child(slider)

	var pct_lbl := Label.new()
	pct_lbl.text = "%d%%" % pct
	pct_lbl.custom_minimum_size = Vector2(40, 0)
	pct_lbl.add_theme_font_size_override("font_size", 12)
	pct_lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	pct_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(pct_lbl)

	var mute_btn := Button.new()
	mute_btn.text = "🔇" if is_muted else "🔊"
	mute_btn.custom_minimum_size = Vector2(36, 0)
	mute_btn.add_theme_font_size_override("font_size", 14)
	mute_btn.tooltip_text = "Mute/Unmute"
	hbox.add_child(mute_btn)

	var mn := StyleBoxFlat.new()
	mn.bg_color = Color(0.15, 0.17, 0.25, 0.9)
	mn.border_color = Color(0.3, 0.4, 0.6, 0.5)
	mn.border_width_top = 1; mn.border_width_bottom = 1
	mn.border_width_left = 1; mn.border_width_right = 1
	mn.corner_radius_top_left = 4; mn.corner_radius_top_right = 4
	mn.corner_radius_bottom_left = 4; mn.corner_radius_bottom_right = 4
	mn.content_margin_left = 4; mn.content_margin_right = 4
	mn.content_margin_top = 2; mn.content_margin_bottom = 2
	mute_btn.add_theme_stylebox_override("normal", mn)

	mute_btn.pressed.connect(func():
		var current_muted = panel.get_meta("muted")
		var new_muted = not current_muted
		_set_mute(row_id, new_muted)
		panel.set_meta("muted", new_muted)
		mute_btn.text = "🔇" if new_muted else "🔊"
	)
	
	panel.set_meta("row_id", row_id)
	var slider_ref = slider
	var pct_ref = pct_lbl
	var mute_ref = mute_btn
	panel.set_meta("slider", slider_ref)
	panel.set_meta("pct_label", pct_ref)
	panel.set_meta("mute_btn", mute_ref)
	panel.set_meta("muted", is_muted)
	return panel

func _refresh() -> void:
	_clear()

	container.add_child(_make_title("VOLUME MIXER"))

	var master_data := _get_master_volume()
	if master_data.is_empty():
		var err := Label.new()
		err.text = "  No audio sink found  "
		err.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		err.add_theme_font_size_override("font_size", 14)
		err.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 0.8))
		err.custom_minimum_size = Vector2(0, 60)
		err.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(err)
		return

	sink_idx = master_data["index"]
	var row := _make_stream_row("Master", master_data["pct"], master_data["mute"], "sink:" + str(sink_idx))
	container.add_child(row)
	master_panel = row
	master_slider = row.get_meta("slider")
	master_mute_btn = row.get_meta("mute_btn")

	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	container.add_child(sep)

	var apps_label := Label.new()
	apps_label.text = "Applications"
	apps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	apps_label.add_theme_font_size_override("font_size", 15)
	apps_label.add_theme_color_override("font_color", Color(0.8, 0.82, 0.88))
	apps_label.custom_minimum_size = Vector2(0, 30)
	apps_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(apps_label)

	sink_inputs = _get_sink_inputs()
	if sink_inputs.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "  (no applications)  "
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_font_size_override("font_size", 13)
		empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.7))
		empty_lbl.custom_minimum_size = Vector2(0, 30)
		empty_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(empty_lbl)
	else:
		var scroll := ScrollContainer.new()
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 4)

		for entry in sink_inputs:
			var app_name := _get_app_name(entry)
			var pct := _calc_pct(entry)
			var muted = entry.get("mute", false)
			var inp_row := _make_stream_row(app_name, pct, muted, "input:" + str(entry["index"]))
			list.add_child(inp_row)
			stream_rows[entry["index"]] = inp_row

		scroll.add_child(list)
		container.add_child(scroll)

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

func _get_master_volume() -> Dictionary:
	var default_name := ""
	var info: Array[String] = []
	if OS.execute(PACTL, ["get-default-sink"], info, true) == 0 and not info.is_empty():
		default_name = info[0].strip_edges()
	if default_name == "":
		info.clear()
		if OS.execute(PACTL, ["info"], info, true) == 0:
			for line in info[0].split("\n"):
				line = line.strip_edges()
				if line.begins_with("Default Sink:"):
					default_name = line.substr("Default Sink:".length()).strip_edges()
					break

	var output: Array[String] = []
	var exit := OS.execute(PACTL, ["-f", "json", "list", "sinks"], output, true)
	if exit != 0:
		return {}
	var parsed = JSON.parse_string(output[0])
	if not parsed is Array or parsed.is_empty():
		return {}
	var sink: Dictionary
	if default_name != "":
		for s in parsed:
			if s.get("name", "") == default_name:
				sink = s
				break
	if sink.is_empty():
		sink = parsed[0]
	var pct := _calc_pct(sink)
	return {"index": sink["index"], "name": sink["name"], "pct": pct, "mute": sink.get("mute", false)}

func _update_known_apps() -> void:
	known_apps.clear()
	if not compositor_ref:
		return
	var windows = compositor_ref.get_window_list()
	for w in windows:
		var app_id = w.get("app_id", "")
		if app_id == "":
			continue
		var parts = app_id.rfind(".")
		var short = app_id.substr(parts + 1).to_lower() if parts != -1 else app_id.to_lower()
		known_apps[short] = true
		known_apps[app_id.to_lower()] = true

func _app_is_known(entry: Dictionary) -> bool:
	if not compositor_ref or known_apps.is_empty():
		return false
	var props = entry.get("properties", {})
	var name = props.get("application.name", "").to_lower()
	var binary = props.get("application.process.binary", "").to_lower()
	if name != "" and known_apps.has(name):
		return true
	if binary != "" and known_apps.has(binary):
		return true
	return false

func _get_sink_inputs() -> Array:
	var output: Array[String] = []
	var exit := OS.execute(PACTL, ["-f", "json", "list", "sink-inputs"], output, true)
	if exit != 0:
		return []
	var parsed = JSON.parse_string(output[0])
	if parsed == null:
		return []
	_update_known_apps()
	var filtered: Array = []
	for entry in parsed:
		if _app_is_known(entry):
			filtered.append(entry)
	return filtered

func _calc_pct(entry: Dictionary) -> int:
	var vol = entry.get("volume")
	if vol == null:
		return 100
	var front_left = vol.get("front-left", {})
	var front_right = vol.get("front-right", {})
	var avg := 0.0
	var count := 0
	if front_left.has("value_percent"):
		avg += float(front_left["value_percent"].trim_suffix("%"))
		count += 1
	if front_right.has("value_percent"):
		avg += float(front_right["value_percent"].trim_suffix("%"))
		count += 1
	if count == 0:
		return 100
	return int(round(avg / count))

func _get_app_name(entry: Dictionary) -> String:
	var props = entry.get("properties", {})
	return props.get("application.name", props.get("node.name", "Application #" + str(entry["index"])))

func _set_volume(target: Variant, pct: int) -> void:
	var args: PackedStringArray
	if target is String and target.begins_with("sink:"):
		var idx = int(target.trim_prefix("sink:"))
		args = ["set-sink-volume", str(idx), "%d%%" % pct]
	elif target is String and target.begins_with("input:"):
		var idx = int(target.trim_prefix("input:"))
		args = ["set-sink-input-volume", str(idx), "%d%%" % pct]
	else:
		return
	OS.execute(PACTL, args, [], true)

func _set_mute(target: Variant, muted: bool) -> void:
	var flag := "1" if muted else "0"
	var args: PackedStringArray
	if target is String and target.begins_with("sink:"):
		var idx = int(target.trim_prefix("sink:"))
		args = ["set-sink-mute", str(idx), flag]
	elif target is String and target.begins_with("input:"):
		var idx = int(target.trim_prefix("input:"))
		args = ["set-sink-input-mute", str(idx), flag]
	else:
		return
	OS.execute(PACTL, args, [], true)

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
	if refresh_timer < 0.1:
		return
	refresh_timer = 0.0
	_update_volumes()

func _update_volumes() -> void:
	var master_data := _get_master_volume()
	if master_data.is_empty():
		return
	var master_pct = master_data["pct"]
	if master_slider and not dragging.get(master_slider, false):
		master_slider.value = master_pct
	if master_panel and is_instance_valid(master_panel):
		var pct_lbl := master_panel.get_meta("pct_label") as Label
		if pct_lbl:
			pct_lbl.text = "%d%%" % master_pct

	var inputs := _get_sink_inputs()
	var indices: Array = []
	for entry in inputs:
		indices.append(entry["index"])

	var changed := indices.size() != stream_rows.size()
	if not changed:
		for idx in indices:
			if not stream_rows.has(idx):
				changed = true
				break

	if changed:
		_refresh()
		return

	var input_map: Dictionary = {}
	for entry in inputs:
		input_map[entry["index"]] = entry

	for idx in stream_rows:
		var panel = stream_rows[idx]
		if not is_instance_valid(panel):
			continue
		var slider := panel.get_meta("slider") as HSlider
		var pct_label := panel.get_meta("pct_label") as Label
		var mute_btn := panel.get_meta("mute_btn") as Button
		var muted = panel.get_meta("muted")

		if input_map.has(idx):
			var entry = input_map[idx]
			var pct = _calc_pct(entry)
			var new_muted = entry.get("mute", false)
			if slider and not dragging.get(slider, false):
				slider.value = pct
			if pct_label:
				pct_label.text = "%d%%" % pct
			if new_muted != muted:
				mute_btn.text = "🔇" if new_muted else "🔊"
				panel.set_meta("muted", new_muted)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
