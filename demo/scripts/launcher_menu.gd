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

var favorites: Dictionary = {} # slot (1-12) -> {"name": String, "exec": String}
var favorites_bar: HBoxContainer
var favorites_bar_labels: Dictionary = {} # slot -> Label

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

	_load_favorites()
	_update_favorite_indicators()
	_build_favorites_bar()

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
	return {"name": name, "exec": exec_cmd, "is_terminal": is_terminal, "categories": categories}

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

			btn.set_meta("app_name", entry["name"])
			btn.set_meta("app_exec", entry["exec"])
			btn.set_meta("app_terminal", entry.get("is_terminal", false))
			var cmd = entry["exec"]
			var term = entry.get("is_terminal", false)
			btn.pressed.connect(func(): _on_app_clicked(cmd, term))
			btn.gui_input.connect(func(event: InputEvent):
				if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
					_show_fav_popup(btn, event.global_position)
					get_viewport().set_input_as_handled()
			)
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

func _load_favorites() -> void:
	var f := FileAccess.open("user://favorites.json", FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		for key in parsed:
			var slot := int(key)
			if slot >= 1 and slot <= 12 and parsed[key] is Dictionary:
				favorites[slot] = parsed[key]

func _save_favorites() -> void:
	var f := FileAccess.open("user://favorites.json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(favorites))
	f.close()

func get_favorite(slot: int) -> Dictionary:
	var fav = favorites.get(slot, {})
	if fav.is_empty():
		return {}
	var result = fav.duplicate()
	if result.get("is_terminal", false):
		result["exec"] = _wrap_terminal(result["exec"])
	return result

func _toggle_favorite(slot: int) -> void:
	if selected_idx < 0 or selected_idx >= navigable_items.size():
		return
	var item := navigable_items[selected_idx]
	if not item is Button:
		return
	var app_name: String = item.get_meta("app_name", "")
	var app_exec: String = item.get_meta("app_exec", "")
	var app_terminal: bool = item.get_meta("app_terminal", false)
	if app_name == "" or app_exec == "":
		return

	if favorites.has(slot) and favorites[slot]["exec"] == app_exec:
		favorites.erase(slot)
	else:
		favorites[slot] = {"name": app_name, "exec": app_exec, "is_terminal": app_terminal}
	_save_favorites()
	_update_favorite_indicators()
	_update_favorites_bar()

func _show_fav_popup(btn: Button, pos: Vector2) -> void:
	var popup := PopupMenu.new()
	var app_name: String = btn.get_meta("app_name", "")
	var app_exec: String = btn.get_meta("app_exec", "")
	var app_terminal: bool = btn.get_meta("app_terminal", false)
	for slot in range(1, 13):
		var label := "F" + str(slot)
		if favorites.has(slot):
			if favorites[slot]["exec"] == app_exec:
				label += "  ✓  " + favorites[slot]["name"] + "  (retirer)"
			else:
				label += "  →  " + favorites[slot]["name"]
		else:
			label += "  (vide)"
		popup.add_item(label, slot)
	popup.id_pressed.connect(func(id: int):
		var slot := id
		if favorites.has(slot) and favorites[slot]["exec"] == app_exec:
			favorites.erase(slot)
		else:
			favorites[slot] = {"name": app_name, "exec": app_exec, "is_terminal": app_terminal}
		_save_favorites()
		_update_favorite_indicators()
		_update_favorites_bar()
		popup.queue_free()
	)
	popup.popup_hide.connect(func(): popup.queue_free())
	popup.position = Vector2i(pos)
	popup.min_size = Vector2i(280, 0)
	add_child(popup)
	popup.popup()

func _update_favorite_indicators() -> void:
	for cat in category_buttons:
		for btn in category_buttons[cat]:
			var app_exec: String = btn.get_meta("app_exec", "")
			var slot_label := ""
			for slot in favorites:
				if favorites[slot]["exec"] == app_exec:
					slot_label = "  ★ F" + str(slot)
					break
			btn.text = "    " + btn.get_meta("app_name", "") + slot_label

func _build_favorites_bar() -> void:
	favorites_bar = HBoxContainer.new()
	favorites_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	favorites_bar.add_theme_constant_override("separation", 6)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.06, 0.06, 0.08, 0.85)
	bar_bg.border_color = Color(0.25, 0.25, 0.3)
	bar_bg.border_width_top = 1
	bar_bg.border_width_bottom = 0
	bar_bg.border_width_left = 0
	bar_bg.border_width_right = 0
	bar_bg.content_margin_left = 10
	bar_bg.content_margin_right = 10
	bar_bg.content_margin_top = 4
	bar_bg.content_margin_bottom = 4
	favorites_bar.add_theme_stylebox_override("panel", bar_bg)

	favorites_bar.anchors_preset = Control.PRESET_BOTTOM_WIDE
	favorites_bar.offset_top = -30
	favorites_bar.offset_bottom = 0
	favorites_bar.offset_left = 0
	favorites_bar.offset_right = 0
	favorites_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	get_parent().add_child.call_deferred(favorites_bar)
	_update_favorites_bar()

func _update_favorites_bar() -> void:
	for child in favorites_bar.get_children():
		child.queue_free()
	favorites_bar_labels.clear()

	var has_any := false
	for slot in range(1, 13):
		if favorites.has(slot):
			has_any = true
			var fav: Dictionary = favorites[slot]
			var lbl := Label.new()
			lbl.text = "F" + str(slot) + " " + fav["name"]
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85, 0.9))
			lbl.tooltip_text = fav["exec"]
			favorites_bar.add_child(lbl)
			favorites_bar_labels[slot] = lbl

	if not has_any:
		var hint := Label.new()
		hint.text = "F1-F12 dans le launcher pour assigner des favoris"
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55, 0.6))
		favorites_bar.add_child(hint)

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

func _wrap_terminal(exec: String) -> String:
	if terminal_emulator == "":
		return exec
	var wrap := terminal_emulator
	if terminal_emulator == "kitty":
		wrap += " --single-instance"
	wrap += " -e"
	return wrap + " " + exec

func _on_app_clicked(command: String, is_terminal: bool) -> void:
	if is_terminal:
		command = _wrap_terminal(command)
	else: 
		var env_vars = "env -u DBUS_SESSION_BUS_ADDRESS "
		command = env_vars + command
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

	elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER or event.keycode == KEY_RIGHT:
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
		search_input.caret_column = search_input.text.length()
		_on_search_changed(search_input.text)
		get_viewport().set_input_as_handled()

	elif event.keycode >= KEY_F1 and event.keycode <= KEY_F12:
		var slot = event.keycode - KEY_F1 + 1
		if slot >= 1 and slot <= 12:
			_toggle_favorite(slot)
		get_viewport().set_input_as_handled()
