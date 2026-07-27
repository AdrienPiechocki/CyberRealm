extends PanelContainer

signal app_launch(command: String)

@onready var search_input: LineEdit = $VBoxContainer/SearchBar
@onready var scroll: ScrollContainer = $VBoxContainer/AppList
@onready var app_list: VBoxContainer = $VBoxContainer/AppList/AppListContent

var all_apps: Array[Dictionary] = []
var app_buttons: Array[Button] = []

func _ready() -> void:
	visible = false
	_load_desktop_files()
	search_input.text_changed.connect(_on_search_changed)
	_build_ui()
	_apply_styling()

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
	f.close()
	if name == "" or exec_cmd == "" or no_display:
		return {}
	# Nettoyer les variables d'exécution (%f, %F, %u, %U, etc.)
	for suffix in ["%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k"]:
		exec_cmd = exec_cmd.replace(suffix, "").strip_edges()
	return {"name": name, "exec": exec_cmd}

func _build_ui() -> void:
	for entry in all_apps:
		var btn := Button.new()
		btn.text = entry["name"]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size.y = 32

		var btn_style := StyleBoxFlat.new()
		btn_style.bg_color = Color(0.15, 0.15, 0.2, 0.0)
		btn_style.border_width_top = 0
		btn_style.border_width_bottom = 0
		btn_style.border_width_left = 0
		btn_style.border_width_right = 0
		btn_style.corner_radius_top_left = 4
		btn_style.corner_radius_top_right = 4
		btn_style.corner_radius_bottom_left = 4
		btn_style.corner_radius_bottom_right = 4
		btn_style.content_margin_left = 10
		btn_style.content_margin_right = 10
		btn_style.content_margin_top = 4
		btn_style.content_margin_bottom = 4
		btn.add_theme_stylebox_override("normal", btn_style)

		var hover_style := btn_style.duplicate()
		hover_style.bg_color = Color(0.25, 0.25, 0.35, 0.8)
		btn.add_theme_stylebox_override("hover", hover_style)

		var pressed_style := btn_style.duplicate()
		pressed_style.bg_color = Color(0.2, 0.3, 0.5, 0.9)
		btn.add_theme_stylebox_override("pressed", pressed_style)

		btn.add_theme_font_size_override("font_size", 16)

		var cmd = entry["exec"]
		btn.pressed.connect(func(): _on_app_clicked(cmd))
		app_list.add_child(btn)
		app_buttons.append(btn)

func _on_app_clicked(command: String) -> void:
	app_launch.emit(command)
	hide_menu()

func _on_search_changed(query: String) -> void:
	var q := query.to_lower()
	for i in range(app_buttons.size()):
		var show = q == "" or all_apps[i]["name"].to_lower().contains(q)
		app_buttons[i].visible = show

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

func show_menu() -> void:
	visible = true
	search_input.text = ""
	_on_search_changed("")
	search_input.grab_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	visible = false
	search_input.text = ""
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
