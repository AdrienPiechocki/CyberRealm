extends PanelContainer

signal app_launch(command: String)

@onready var search_input: LineEdit = $VBoxContainer/SearchBar
@onready var scroll: ScrollContainer = $VBoxContainer/AppList
@onready var app_list: VBoxContainer = $VBoxContainer/AppList/AppListContent

const CATEGORY_ORDER := [
	"AudioVideo", "Development", "Education", "Game", "Graphics",
	"Network", "Office", "Settings", "System", "Utility"
]

const TERMINAL_WRAPPERS := ["konsole", "alacritty", "kitty", "xterm"]

var all_apps: Array[Dictionary] = []
var category_headers: Dictionary = {} # category_label -> Label node
var category_buttons: Dictionary = {} # category_label -> Array[Button]
var category_expanded: Dictionary = {} # category_label -> bool
var terminal_emulator: String = ""

var navigable_items: Array[Control] = []
var selected_idx: int = -1
var selected_style: StyleBoxFlat

func _ready() -> void:
	visible = false
	_detect_terminal()
	_load_desktop_files()
	search_input.text_changed.connect(_on_search_changed)
	_build_ui()
	_apply_styling()

	selected_style = StyleBoxFlat.new()
	selected_style.bg_color = Color(0.2, 0.3, 0.5, 0.9)
	selected_style.corner_radius_top_left = 3
	selected_style.corner_radius_top_right = 3
	selected_style.corner_radius_bottom_left = 3
	selected_style.corner_radius_bottom_right = 3
	selected_style.content_margin_left = 12
	selected_style.content_margin_right = 10
	selected_style.content_margin_top = 2
	selected_style.content_margin_bottom = 2

func _detect_terminal() -> void:
	for term in TERMINAL_WRAPPERS:
		var output: Array = []
		OS.execute("which", [term], output, true)
		if output.size() > 0 and output[0].strip_edges() != "":
			terminal_emulator = term
			return
	terminal_emulator = "xterm"

func _apply_styling() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	bg.border_color = Color(0.3, 0.3, 0.35)
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.corner_radius_top_left = 8
	bg.corner_radius_top_right = 8
	bg.corner_radius_bottom_left = 8
	bg.corner_radius_bottom_right = 8
	bg.content_margin_left = 0
	bg.content_margin_right = 0
	bg.content_margin_top = 0
	bg.content_margin_bottom = 0
	add_theme_stylebox_override("panel", bg)

	custom_minimum_size = Vector2(500, 400)
	size = Vector2(500, 400)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -250
	offset_right = 250
	offset_top = -200
	offset_bottom = 200

func _load_desktop_files() -> void:
	var dirs: PackedStringArray = PackedStringArray()
	dirs.append("/usr/share/applications")
	dirs.append("/usr/local/share/applications")
	var home := OS.get_environment("HOME")
	if home != "":
		dirs.append(home + "/.local/share/applications")
	var xdg_data := OS.get_environment("XDG_DATA_DIRS")
	if xdg_data != "":
		for d in xdg_data.split(":"):
			if d != "":
				dirs.append(d + "/applications")

	var seen: Dictionary = {}
	for dir_path in dirs:
		var da := DirAccess.open(dir_path)
		if da == null:
			continue
		da.list_dir_begin()
		var fname := da.get_next()
		while fname != "":
			if fname.ends_with(".desktop") and not fname.begins_with("."):
				var full_path := dir_path.path_join(fname)
				var entry := _parse_desktop_file(full_path)
				if entry.size() > 0 and not seen.has(entry["exec"]):
					seen[entry["exec"]] = true
					all_apps.append(entry)
			fname = da.get_next()
		da.list_dir_end()
	all_apps.sort_custom(func(a, b): return a["name"].nocasecmp_to(b["name"]) < 0)

func _parse_desktop_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var in_entry := false
	var name := ""
	var exec_cmd := ""
	var no_display := false
	var is_terminal := false
	var categories: PackedStringArray = PackedStringArray()
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "[Desktop Entry]":
			in_entry = true
			continue
		if line.begins_with("[") and in_entry:
			break
		if not in_entry:
			continue
		if line.begins_with("Name=") and name == "":
			name = line.substr(5).strip_edges()
		elif line.begins_with("Exec="):
			exec_cmd = line.substr(5).strip_edges()
		elif line.begins_with("NoDisplay=true"):
			no_display = true
		elif line.begins_with("Hidden=true"):
			no_display = true
		elif line.begins_with("Terminal=true"):
			is_terminal = true
		elif line.begins_with("Categories="):
			for cat in line.substr(11).split(";", false):
				var c := cat.strip_edges()
				if c != "":
					categories.append(c)
	f.close()
	if name == "" or exec_cmd == "" or no_display:
		return {}
	for suffix in ["%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k"]:
		exec_cmd = exec_cmd.replace(suffix, "").strip_edges()
	if is_terminal and terminal_emulator != "":
		var wrap := terminal_emulator
		if terminal_emulator == "kitty":
			wrap += " --single-instance"
		wrap += " -e"
		exec_cmd = wrap + " " + exec_cmd
	return {"name": name, "exec": exec_cmd, "categories": categories}

func _get_primary_category(entry: Dictionary) -> String:
	var cats: PackedStringArray = entry.get("categories", PackedStringArray())
	for cat in cats:
		if cat in CATEGORY_ORDER:
			return cat
	if cats.size() > 0:
		return cats[0]
	return "Other"

func _build_ui() -> void:
	var grouped: Dictionary = {} # category_label -> Array[Dictionary]
	for entry in all_apps:
		var cat := _get_primary_category(entry)
		if not grouped.has(cat):
			grouped[cat] = []
		grouped[cat].append(entry)

	var sorted_cats: Array = grouped.keys()
	sorted_cats.sort_custom(func(a, b):
		var ai := CATEGORY_ORDER.find(a)
		var bi := CATEGORY_ORDER.find(b)
		if ai == -1: ai = CATEGORY_ORDER.size()
		if bi == -1: bi = CATEGORY_ORDER.size()
		return ai < bi
	)

	for cat in sorted_cats:
		var apps_in_cat: Array = grouped[cat]
		category_expanded[cat] = false
		category_buttons[cat] = []

		var header := Label.new()
		header.text = "▶  " + cat + "  (" + str(apps_in_cat.size()) + ")"
		header.custom_minimum_size.y = 28
		header.add_theme_font_size_override("font_size", 14)

		var header_style := StyleBoxFlat.new()
		header_style.bg_color = Color(0.15, 0.15, 0.22, 0.9)
		header_style.content_margin_left = 8
		header_style.content_margin_right = 8
		header_style.content_margin_top = 4
		header_style.content_margin_bottom = 4
		header.add_theme_stylebox_override("normal", header_style)
		header.add_theme_stylebox_override("hover", header_style)
		header.mouse_filter = Control.MOUSE_FILTER_STOP
		header.set_meta("normal_style", header_style)

		var cat_label = cat
		header.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_toggle_category(cat_label)
		)
		header.mouse_entered.connect(func():
			if navigable_items.find(header) == selected_idx:
				return
			header.add_theme_stylebox_override("normal", header_style.duplicate())
			(header.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = Color(0.22, 0.22, 0.3, 0.9)
		)
		header.mouse_exited.connect(func():
			if navigable_items.find(header) == selected_idx:
				return
			header.add_theme_stylebox_override("normal", header_style)
		)

		app_list.add_child(header)
		category_headers[cat] = header

		for entry in apps_in_cat:
			var btn := Button.new()
			btn.text = "    " + entry["name"]
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.custom_minimum_size.y = 30

			var btn_style := StyleBoxFlat.new()
			btn_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
			btn_style.border_width_top = 0
			btn_style.border_width_bottom = 0
			btn_style.border_width_left = 0
			btn_style.border_width_right = 0
			btn_style.corner_radius_top_left = 3
			btn_style.corner_radius_top_right = 3
			btn_style.corner_radius_bottom_left = 3
			btn_style.corner_radius_bottom_right = 3
			btn_style.content_margin_left = 12
			btn_style.content_margin_right = 10
			btn_style.content_margin_top = 2
			btn_style.content_margin_bottom = 2
			btn.add_theme_stylebox_override("normal", btn_style)
			btn.set_meta("normal_style", btn_style)

			var hover_style := btn_style.duplicate()
			hover_style.bg_color = Color(0.25, 0.25, 0.35, 0.8)
			btn.add_theme_stylebox_override("hover", hover_style)

			var pressed_style := btn_style.duplicate()
			pressed_style.bg_color = Color(0.2, 0.3, 0.5, 0.9)
			btn.add_theme_stylebox_override("pressed", pressed_style)

			btn.add_theme_font_size_override("font_size", 15)

			var cmd = entry["exec"]
			btn.pressed.connect(func(): _on_app_clicked(cmd))
			btn.visible = false
			app_list.add_child(btn)
			category_buttons[cat].append(btn)

func _rebuild_navigable_list() -> void:
	navigable_items.clear()
	for child in app_list.get_children():
		if child.visible:
			navigable_items.append(child)

func _select_item(idx: int) -> void:
	if selected_idx >= 0 and selected_idx < navigable_items.size():
		var old: Control = navigable_items[selected_idx]
		var normal = old.get_meta("normal_style")
		old.add_theme_stylebox_override("normal", normal)
		if old is Label:
			old.add_theme_stylebox_override("hover", normal)

	selected_idx = idx

	if selected_idx >= 0 and selected_idx < navigable_items.size():
		var new: Control = navigable_items[selected_idx]
		new.add_theme_stylebox_override("normal", selected_style)
		if new is Label:
			new.add_theme_stylebox_override("hover", selected_style)
		scroll.ensure_control_visible(new)

func _toggle_category(cat: String) -> void:
	category_expanded[cat] = not category_expanded[cat]
	var expanded: bool = category_expanded[cat]
	var header: Label = category_headers[cat]
	var prefix := "▼  " if expanded else "▶  "
	var count = category_buttons[cat].size()
	header.text = prefix + cat + "  (" + str(count) + ")"
	for btn in category_buttons[cat]:
		btn.visible = expanded
	_rebuild_navigable_list()

func _on_app_clicked(command: String) -> void:
	app_launch.emit(command)
	hide_menu()

func _on_search_changed(query: String) -> void:
	var q := query.to_lower()
	for cat in category_headers:
		var header_visible := false
		var expanded = category_expanded.get(cat, false)
		for btn in category_buttons[cat]:
			var is_match = q == "" or btn.text.strip_edges().to_lower().contains(q)
			btn.visible = is_match and (expanded or q != "")
			if is_match:
				header_visible = true
		category_headers[cat].visible = header_visible
		if not header_visible:
			for btn in category_buttons[cat]:
				btn.visible = false
	_rebuild_navigable_list()
	if q != "":
		_select_item(-1)

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	visible = true
	search_input.text = ""
	_on_search_changed("")
	_select_item(-1)
	search_input.grab_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	visible = false
	_select_item(-1)
	search_input.text = ""
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		hide_menu()
		get_viewport().set_input_as_handled()
		return

	_rebuild_navigable_list()

	if event.keycode == KEY_DOWN:
		if selected_idx < 0:
			if navigable_items.size() > 0:
				_select_item(0)
		elif selected_idx < navigable_items.size() - 1:
			_select_item(selected_idx + 1)
		get_viewport().set_input_as_handled()

	elif event.keycode == KEY_UP:
		if selected_idx > 0:
			_select_item(selected_idx - 1)
		elif selected_idx == 0:
			_select_item(-1)
			search_input.grab_focus()
		get_viewport().set_input_as_handled()

	elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		if selected_idx >= 0 and selected_idx < navigable_items.size():
			var item := navigable_items[selected_idx]
			if item is Label:
				var cat := ""
				for k in category_headers:
					if category_headers[k] == item:
						cat = k
						break
				if cat != "":
					_toggle_category(cat)
					_rebuild_navigable_list()
					if selected_idx >= navigable_items.size():
						_select_item(maxi(navigable_items.size() - 1, 0))
					elif selected_idx >= 0:
						_select_item(selected_idx)
			elif item is Button:
				item.pressed.emit()
		get_viewport().set_input_as_handled()

	elif event.unicode > 0 and event.unicode != 32 and not event.ctrl_pressed and not event.meta_pressed:
		_select_item(-1)
		search_input.grab_focus()
		search_input.text += String.chr(event.unicode)
		search_input.caret_position = search_input.text.length()
		_on_search_changed(search_input.text)
		get_viewport().set_input_as_handled()
