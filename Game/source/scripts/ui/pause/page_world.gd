extends Node
## Page World : choix du niveau et réglages de l'environnement (WorldEnvironment).
##
## Module de PauseMenu (nœud enfant « PageWorld »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

const LevelCatalogScript := preload("res://scripts/main/level_catalog.gd")
var _level_status_text := ""
var _level_status_label: Label = null

# Valeur d'un réglage d'environnement : la valeur persistée si présente,
# sinon l'état actuel du WorldEnvironment du niveau (le menu reflète ce qui
# s'affiche réellement), sinon le fallback passé.
func _env_default(key: String, fallback: Variant) -> Variant:
	var env: Dictionary = menu._settings.get("environment", {})
	if env.has(key):
		return env[key]
	var we := _find_world_environment()
	if we != null and we.environment != null:
		var v: Variant = we.environment.get(key)
		if v != null:
			return v
	return fallback

# Slider 0.0–2.0 (pas 0.05) pour un réglage "adjustment_*" : étiquette,
# curseur et valeur affichée (mise à jour en direct).
func _make_env_slider(label_text: String, key: String) -> HSlider:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.05
	slider.value = float(_env_default(key, 1.0))
	slider.custom_minimum_size = Vector2(0, 30)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(slider)
	var val := Label.new()
	val.text = "%.2f" % slider.value
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(val)
	slider.value_changed.connect(func(v: float):
		val.text = "%.2f" % v
	)
	return slider

func _find_world_environment() -> WorldEnvironment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _search_world_environment(scene)

func _search_world_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var found := _search_world_environment(child)
		if found != null:
			return found
	return null

# ── World : choix du niveau (environnement) ─────────────────────────
# Liste le niveau par défaut et tous les level.tscn de res://user/. Le choix
# est appliqué à chaud et persisté (rechargé au prochain démarrage). Verrouillé
# pendant une session multijoueur : seul le niveau sélectionné au moment
# d'héberger est baké et envoyé, il ne change pas en cours de partie.
func _show_levels() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "levels"

	menu.container.add_child(menu._make_title("WORLD"))

	var locked := menu._lan_connected
	var loading := menu._level_room != null and bool(menu._level_room.call("is_level_loading"))
	var current := String(menu._level_room.call("get_current_level_path")) if menu._level_room != null else ""

	var hint := Label.new()
	if locked:
		hint.text = "Locked during a multiplayer session: everyone plays the level\nselected when the game was hosted. Disconnect to change it."
	else:
		hint.text = "Pick the environment to play in. The choice is remembered.\nIn multiplayer, only the selected level is sent to other players."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	for lv in LevelCatalogScript.list_levels():
		var path := String(lv["path"])
		var is_current := path == current
		var btn := menu._make_btn(String(lv["name"]) + ("   — current" if is_current else ""), "nav-row")
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.tooltip_text = path
		btn.disabled = locked or loading or is_current
		btn.pressed.connect(func():
			if menu._lan_connected:
				_show_levels()
				return
			set_level_status("Loading %s…" % String(lv["name"]))
			menu.level_change_requested.emit(path)
		)
		menu.container.add_child(btn)

	_level_status_label = Label.new()
	_level_status_label.text = _level_status_text
	_level_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_level_status_label.add_theme_font_size_override("font_size", 13)
	_level_status_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(_level_status_label)

	# Pages ajoutées par le niveau courant (add_menu_page) : sous-pages de World.
	if not menu._extra_pages.is_empty():
		menu.container.add_child(menu._make_section("Current level"))
		for page in menu._extra_pages:
			menu.container.add_child(menu._make_nav_row(String(page["label"]),
				"Options of " + menu.shell._world_label(), page["show"]))

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func set_level_status(text: String) -> void:
	_level_status_text = text
	if _level_status_label != null and is_instance_valid(_level_status_label):
		_level_status_label.text = text

## Appelé par WaylandRoom une fois le nouveau niveau appliqué : persiste le
## choix et rafraîchit la page si elle est ouverte.
func on_level_changed(path: String) -> void:
	menu._settings[LevelCatalogScript.SETTING_KEY] = path
	menu._save_settings()
	set_level_status("%s loaded." % LevelCatalogScript.display_name(path))
	menu.shell._refresh_header()
	if menu.visible and menu._current_view == "levels":
		_show_levels()
