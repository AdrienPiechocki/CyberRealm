extends Node
## Page Startup apps : applications lancées au démarrage du jeu.
##
## Module de PauseMenu (nœud enfant « PageStartupApps »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

func _show_startup_apps() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "startup"

	menu.container.add_child(menu._make_title("STARTUP APPS"))

	var hint := Label.new()
	hint.text = "Apps launched when the compositor starts."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	menu.container.add_child(scroll)

	var apps: Array = menu._settings.get("startup_apps", [])
	if apps.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no startup apps)"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
		list.add_child(empty_label)
	else:
		for i in apps.size():
			var app := String(apps[i])
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var label := Label.new()
			label.text = app
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			label.add_theme_font_size_override("font_size", 14)
			label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
			row.add_child(label)

			var launch_btn := menu._make_btn("Launch")
			launch_btn.custom_minimum_size = Vector2(100, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(_launch_app.bind(app))
			row.add_child(launch_btn)

			var edit_btn := menu._make_btn("Edit", "success-button")
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_startup_app.bind(i))
			row.add_child(edit_btn)

			var remove_btn := menu._make_btn("Remove", "remove-button")
			remove_btn.custom_minimum_size = Vector2(100, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_startup_app.bind(app))
			row.add_child(remove_btn)

			list.add_child(row)

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := menu._make_line_edit()
	if menu._editing_index >= 0 and menu._editing_index < apps.size():
		le.text = String(apps[menu._editing_index])
		le.placeholder_text = "edit command"
	else:
		le.placeholder_text = "command (ex: firefox, konsole)"
	le.text_submitted.connect(func(text: String):
		_add_startup_app(text.strip_edges())
	)
	add_row.add_child(le)
	var add_btn := menu._make_btn("Save" if menu._editing_index >= 0 and menu._editing_index < apps.size() else "Add")
	add_btn.custom_minimum_size = Vector2(90, 36)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_btn.pressed.connect(_add_from_line_edit.bind(le))
	add_row.add_child(add_btn)
	menu.container.add_child(add_row)

	menu.container.add_child(menu._make_back_btn())

func _launch_app(app: String) -> void:
	menu.app_launch_requested.emit(app)

func _add_from_line_edit(le: LineEdit) -> void:
	_add_startup_app(le.text.strip_edges())

func _edit_startup_app(index: int) -> void:
	menu._editing_index = index
	_show_startup_apps()

func _add_startup_app(cmd: String) -> void:
	if cmd == "":
		return
	var apps: Array = menu._settings.get("startup_apps", [])
	if menu._editing_index >= 0 and menu._editing_index < apps.size():
		# Mode édition : remplace la commande à cet index.
		apps[menu._editing_index] = cmd
	else:
		if not apps.has(cmd):
			apps.append(cmd)
	menu._editing_index = -1
	menu._settings["startup_apps"] = apps
	menu._save_settings()
	_show_startup_apps()

func _remove_startup_app(cmd: String) -> void:
	var apps: Array = menu._settings.get("startup_apps", [])
	apps.erase(cmd)
	menu._settings["startup_apps"] = apps
	menu._editing_index = -1
	menu._save_settings()
	_show_startup_apps()
