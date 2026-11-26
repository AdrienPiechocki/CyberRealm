extends Node
## Pages General / Graphics / Controls : profil, apparence, clavier, agent polkit, captures d'écran,
## fenêtres épinglées, rendu, sensibilités.
##
## Module de PauseMenu (nœud enfant « PageGeneral »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

const LanManagerScript := preload("res://scripts/network/lan_manager.gd")

# Layouts clavier proposés (mêmes identifiants que setxkbmap / xkbcommon).
const KEYBOARD_LAYOUTS := [
	{ "layout": "fr", "variant": "", "label": "Français (AZERTY)" },
	{ "layout": "fr", "variant": "oss", "label": "Français bépo" },
	{ "layout": "us", "variant": "", "label": "US (QWERTY)" },
	{ "layout": "us", "variant": "intl", "label": "US International" },
	{ "layout": "us", "variant": "colemak", "label": "US Colemak" },
	{ "layout": "us", "variant": "dvorak", "label": "US Dvorak" },
	{ "layout": "gb", "variant": "", "label": "UK (QWERTY)" },
	{ "layout": "de", "variant": "", "label": "Deutsch (QWERTZ)" },
	{ "layout": "de", "variant": "neo", "label": "Deutsch Neo" },
	{ "layout": "be", "variant": "", "label": "Belge (AZERTY)" },
	{ "layout": "es", "variant": "", "label": "Español (QWERTY)" },
	{ "layout": "it", "variant": "", "label": "Italiano (QWERTY)" },
	{ "layout": "pt", "variant": "", "label": "Português (QWERTY)" },
	{ "layout": "br", "variant": "", "label": "Brasileiro (ABNT2)" },
	{ "layout": "ca", "variant": "", "label": "Canadien multilingue" },
	{ "layout": "ch", "variant": "", "label": "Suisse" },
	{ "layout": "se", "variant": "", "label": "Svenska (QWERTY)" },
	{ "layout": "no", "variant": "", "label": "Norsk (QWERTY)" },
	{ "layout": "dk", "variant": "", "label": "Dansk" },
	{ "layout": "ru", "variant": "", "label": "Русский (ЙЦУКЕН)" },
]

# ── Pages catégories du hub ───────────────────────────────────────────

func _show_general() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "general"
	menu._editing_index = -1

	menu.container.add_child(menu._make_title("GENERAL"))

	menu.container.add_child(menu._make_nav_row("Startup Apps", "Apps launched with the game", menu.page_startup_apps._show_startup_apps))
	menu.container.add_child(menu._make_nav_row("Polkit Agent", "Authentication dialog used in game", _show_polkit))
	menu.container.add_child(menu._make_nav_row("Screenshot Folder", "Where captures are saved", _show_screenshots))

	_add_profile_rows()

	menu.container.add_child(menu._make_section("Performance"))
	# ── Max FPS (appliqué immédiatement) ──
	var fps_label := _make_row_label("Max FPS")
	menu.container.add_child(fps_label)

	var fps_slider := HSlider.new()
	fps_slider.min_value = 30
	fps_slider.max_value = 240
	fps_slider.step = 10
	fps_slider.value = menu.get_fps_limit()
	fps_slider.custom_minimum_size = Vector2(0, 30)
	fps_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(fps_slider)

	var fps_val := Label.new()
	fps_val.text = "%d" % int(fps_slider.value)
	fps_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fps_val.add_theme_font_size_override("font_size", 13)
	fps_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(fps_val)

	fps_slider.value_changed.connect(func(v: float):
		fps_val.text = "%d" % int(v)
		menu._settings["fps_limit"] = int(v)
		menu._save_settings()
		Engine.max_fps = int(v)
		menu.graphics_settings_changed.emit(menu.get_aa_mode(), int(v))
	)


	menu.container.add_child(menu._make_section("Behaviour"))
	# ── Collage des fenêtres ──
	# Appliqué comme le Max FPS ci-dessus : cette page n'a pas de bouton Apply,
	# la case est donc pré-appliquée dès qu'on la coche.
	var snap_check := CheckButton.new()
	snap_check.text = "Disable Window Snapping"
	snap_check.button_pressed = menu.is_snapping_disabled()
	snap_check.custom_minimum_size = Vector2(0, 36)
	snap_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snap_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(snap_check)

	snap_check.toggled.connect(func(on: bool):
		menu._settings["snapping_disabled"] = on
		menu._save_settings()
		menu.snapping_disabled_changed.emit(on)
	)

	# toggle_ui masque aussi les noms des joueurs (Label3D des avatars).
	var names_check := CheckButton.new()
	names_check.text = "toggle_ui hides player names"
	names_check.button_pressed = menu.does_toggle_ui_hide_names()
	names_check.custom_minimum_size = Vector2(0, 36)
	names_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(names_check)

	names_check.toggled.connect(func(on: bool):
		menu._settings["toggle_ui_hides_names"] = on
		menu._save_settings()
		menu.ui_hides_names_changed.emit(on)
	)

	# Full body awareness : voir son propre corps (tête cachée) en vue 1ère personne.
	var body_check := CheckButton.new()
	body_check.text = "Full body awareness (see your own body in first person)"
	body_check.button_pressed = menu.is_fullbody_enabled()
	body_check.custom_minimum_size = Vector2(0, 36)
	body_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(body_check)

	body_check.toggled.connect(func(on: bool):
		menu._settings["fullbody_awareness"] = on
		menu._save_settings()
		menu.fullbody_changed.emit(on)
	)

	# Raccourcis capturés par une app en mode focus (VM, bureau à distance : Super, Alt+Tab…).
	# Lu à chaque frame par toplevel_bridge.gd : aucun signal nécessaire.
	var inhibit_check := CheckButton.new()
	inhibit_check.text = "Let apps capture shortcuts in focus mode (VMs, remote desktop)"
	inhibit_check.button_pressed = menu.is_shortcut_inhibit_allowed()
	inhibit_check.custom_minimum_size = Vector2(0, 36)
	inhibit_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inhibit_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(inhibit_check)

	inhibit_check.toggled.connect(func(on: bool):
		menu._settings["allow_shortcut_inhibit"] = on
		menu._save_settings()
	)

	# Disposition des fenêtres retrouvée d'une session à l'autre (lu par window_layouts.gd).
	var layout_check := CheckButton.new()
	layout_check.text = "Remember window positions (per level)"
	layout_check.button_pressed = menu.is_window_layout_enabled()
	layout_check.custom_minimum_size = Vector2(0, 36)
	layout_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(layout_check)

	layout_check.toggled.connect(func(on: bool):
		menu._settings["remember_window_layout"] = on
		menu._save_settings()
	)

	# Reprise de session : relancer au démarrage les apps encore ouvertes à la fermeture du jeu.
	var reopen_check := CheckButton.new()
	reopen_check.text = "Reopen the apps of the previous session at startup"
	reopen_check.button_pressed = menu.is_session_restore_enabled()
	reopen_check.custom_minimum_size = Vector2(0, 36)
	reopen_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reopen_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(reopen_check)

	reopen_check.toggled.connect(func(on: bool):
		menu._settings["reopen_last_session"] = on
		menu._save_settings()
	)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

# Profil joueur (nom, couleur, avatar) : affiché dans GENERAL, utilisé en multijoueur.
func _add_profile_rows() -> void:
	menu.container.add_child(menu._make_section("Profile"))
	var name_label := Label.new()
	name_label.text = "Player name"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(name_label)

	var name_edit := menu._make_line_edit()
	name_edit.text = menu.get_lan_player_name()
	name_edit.placeholder_text = "Player name"
	name_edit.text_submitted.connect(func(_t: String):
		menu.page_multiplayer._save_lan_name(name_edit)
	)
	name_edit.focus_exited.connect(func():
		if name_edit.text.strip_edges() != menu.get_lan_player_name():
			menu.page_multiplayer._save_lan_name(name_edit)
	)
	menu.container.add_child(name_edit)

	var color_row := HBoxContainer.new()
	color_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var color_label := Label.new()
	color_label.text = "Avatar color"
	color_label.add_theme_font_size_override("font_size", 13)
	color_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	color_row.add_child(color_label)
	var color_btn := ColorPickerButton.new()
	color_btn.focus_mode = Control.FOCUS_ALL
	color_btn.color = menu.get_lan_player_color()
	color_btn.custom_minimum_size = Vector2(64, 30)
	color_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	color_row.add_child(color_btn)
	var apply_color := func(c: Color) -> void:
		menu._settings["lan_player_color"] = c.to_html(true)
		menu._save_settings()
		menu.lan_color_changed.emit(c)
	if menu._lan_connected:
		# Connecté : on n'envoie qu'à la fermeture du sélecteur, pour ne pas
		# inonder le réseau pendant le glissé.
		color_btn.popup_closed.connect(func():
			if color_btn.color.to_html(true) != menu.get_lan_player_color().to_html(true):
				apply_color.call(color_btn.color)
		)
	else:
		color_btn.color_changed.connect(apply_color)
	menu.container.add_child(color_row)

	# Choix de l'avatar incarné : tous les avatar.tscn trouvés dans le
	# projet, nommés d'après le nœud racine de chaque scène. Persisté comme
	# le nom/couleur ; "" = avatar par défaut (auto).
	var avatar_row := HBoxContainer.new()
	avatar_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avatar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var avatar_label := Label.new()
	avatar_label.text = "Avatar"
	avatar_label.add_theme_font_size_override("font_size", 13)
	avatar_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	avatar_row.add_child(avatar_label)
	var avatar_opt := OptionButton.new()
	var saved_avatar := menu.get_lan_avatar_path()
	var sel_idx := -1
	for a in LanManagerScript.list_avatars():
		var path := String(a["path"])
		if path == saved_avatar:
			sel_idx = avatar_opt.item_count
		avatar_opt.add_item(String(a["name"]))
		avatar_opt.set_item_metadata(avatar_opt.item_count - 1, path)
	if avatar_opt.item_count > 0:
		avatar_opt.select(maxi(sel_idx, 0))
		avatar_opt.item_selected.connect(func(idx: int):
			var p := String(avatar_opt.get_item_metadata(idx))
			menu._settings["lan_avatar_path"] = p
			menu._save_settings()
			menu.lan_avatar_changed.emit(p)
		)
		avatar_row.add_child(avatar_opt)
	else:
		avatar_label.queue_free()
		avatar_row.queue_free()
	menu.container.add_child(avatar_row)

func _show_graphics() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "graphics"
	menu._editing_index = -1

	menu.container.add_child(menu._make_title("GRAPHICS"))

	menu.container.add_child(menu._make_nav_row("General", "Anti-aliasing, effects, color adjustments", _show_graphics_general))
	menu.container.add_child(menu._make_nav_row("Pinned Windows", "Layer, opacity, position and size of pins", _show_pins))

	menu.container.add_child(menu._make_section("Appearance"))
	_add_appearance_rows()

	menu.container.add_child(menu._make_spacer())

	menu.container.add_child(menu._make_back_btn())

func _show_controls() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "controls"
	menu._editing_index = -1

	menu.container.add_child(menu._make_title("CONTROLS"))

	menu.container.add_child(menu._make_nav_row("General", "Mouse, stick and gyro sensitivity", _show_controls_general))
	menu.container.add_child(menu._make_nav_row("Remap Keybinds", "Keyboard and gamepad bindings", menu.page_keybinds._show_keybinds))
	menu.container.add_child(menu._make_nav_row("Custom Binds", "Shortcuts that run your own commands", menu.page_keybinds._show_custom_binds))
	menu.container.add_child(menu._make_nav_row("Keyboard Layout", "Layout used by in-game apps", _show_keyboard_layout))

	menu.container.add_child(menu._make_spacer())

	menu.container.add_child(menu._make_back_btn())

# ── Keyboard layout ─────────────────────────────────────────────────

func _show_keyboard_layout() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "keyboard_layout"

	menu.container.add_child(menu._make_title("KEYBOARD LAYOUT"))

	var hint := Label.new()
	hint.text = "Layout sent to the Wayland apps in the game (same as setxkbmap)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	var cur := _current_keyboard_layout()
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0, 40)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 14)
	for i in KEYBOARD_LAYOUTS.size():
		var entry: Dictionary = KEYBOARD_LAYOUTS[i]
		opt.add_item(String(entry.get("label", "")), i)
		if entry.get("layout", "") == cur.get("layout", "") \
				and entry.get("variant", "") == cur.get("variant", ""):
			opt.selected = i
	menu.container.add_child(opt)

	opt.item_selected.connect(func(_idx: int):
		_apply_keyboard_layout(opt)
	)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func _apply_keyboard_layout(opt: OptionButton) -> void:
	var idx := opt.selected
	if idx < 0 or idx >= KEYBOARD_LAYOUTS.size():
		return
	var entry: Dictionary = KEYBOARD_LAYOUTS[idx]
	var layout := String(entry.get("layout", ""))
	var variant := String(entry.get("variant", ""))
	menu._settings["keyboard_layout"] = layout
	menu._settings["keyboard_variant"] = variant
	menu._save_settings()
	menu.keyboard_layout_changed.emit(layout, variant)

func _current_keyboard_layout() -> Dictionary:
	return menu.get_keyboard_layout()

func _show_polkit() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "polkit"

	menu.container.add_child(menu._make_title("POLKIT AGENT"))

	var hint := Label.new()
	hint.text = "Path to the polkit authentication agent.\nEmpty: auto-detect (KDE agent).\n\nThe game stops plasma-polkit-agent while it runs\nand restores it on exit."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	var line_edit := menu._make_line_edit()
	line_edit.text = menu.get_polkit_agent()
	line_edit.placeholder_text = "/usr/lib/polkit-kde-authentication-agent-1"
	line_edit.text_submitted.connect(func(_t: String):
		_apply_polkit_agent(line_edit)
	)
	line_edit.focus_exited.connect(func():
		_apply_polkit_agent(line_edit)
	)
	menu.container.add_child(line_edit)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func _apply_polkit_agent(line_edit: LineEdit) -> void:
	var cmd := line_edit.text.strip_edges()
	if cmd == menu.get_polkit_agent():
		return
	menu._settings["polkit_agent"] = cmd
	menu._save_settings()
	menu.polkit_agent_changed.emit(cmd)

func _default_screenshot_folder() -> String:
	var out: Array = []
	if OS.execute("xdg-user-dir", ["PICTURES"], out) == 0 \
			and not String(out[0]).strip_edges().is_empty():
		return String(out[0]).strip_edges()
	return OS.get_environment("HOME") + "/Pictures"

func _show_screenshots() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "screenshots"

	menu.container.add_child(menu._make_title("SCREENSHOT FOLDER"))

	var hint := Label.new()
	hint.text = "Folder where screenshots are saved\n(screen keybind + window menu button)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	var line_edit := menu._make_line_edit()
	line_edit.text = menu.get_screenshot_folder()
	line_edit.placeholder_text = "$(xdg-user-dir PICTURES)"
	line_edit.text_submitted.connect(func(_t: String):
		_apply_screenshot_folder(line_edit)
	)
	line_edit.focus_exited.connect(func():
		_apply_screenshot_folder(line_edit)
	)
	menu.container.add_child(line_edit)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func _apply_screenshot_folder(line_edit: LineEdit) -> void:
	var folder := line_edit.text.strip_edges()
	if folder == menu.get_screenshot_folder():
		return
	menu._settings["screenshot_folder"] = folder
	menu._save_settings()
const PIN_SIZE_DIVISOR_STEP := 0.1

func _show_pins() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "pins"

	menu.container.add_child(menu._make_title("PINNED WINDOWS"))

	var hint := Label.new()
	hint.text = "Settings for the pinned (PiP) window."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(hint)

	var layer_label := Label.new()
	layer_label.text = "Layer (relative to the focus mode overlay)"
	layer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer_label.add_theme_font_size_override("font_size", 13)
	layer_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(layer_label)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0, 40)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 14)
	opt.add_item("Below the focus layer")
	opt.add_item("Above the focus layer")
	opt.selected = 1 if menu.get_pins_above_focus() else 0
	menu.container.add_child(opt)

	var pos_label := Label.new()
	pos_label.text = "Position"
	pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pos_label.add_theme_font_size_override("font_size", 13)
	pos_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(pos_label)

	var pos_opt := OptionButton.new()
	pos_opt.custom_minimum_size = Vector2(0, 40)
	pos_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pos_opt.add_theme_font_size_override("font_size", 14)
	var cur_pos := menu.get_pins_position()
	for i in PauseMenu.PIN_POSITIONS.size():
		var entry: Dictionary = PauseMenu.PIN_POSITIONS[i]
		pos_opt.add_item(String(entry.get("label", "")), i)
		if String(entry.get("id", "")) == cur_pos:
			pos_opt.selected = i
	menu.container.add_child(pos_opt)

	var transp_label := Label.new()
	transp_label.text = "Transparency"
	transp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	transp_label.add_theme_font_size_override("font_size", 13)
	transp_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(transp_label)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = menu.get_pins_opacity()
	slider.custom_minimum_size = Vector2(0, 30)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(slider)

	var slider_val := Label.new()
	slider_val.text = "%d%%" % menu.get_pins_opacity()
	slider_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slider_val.add_theme_font_size_override("font_size", 13)
	slider_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(slider_val)

	slider.value_changed.connect(func(value: float):
		slider_val.text = "%d%%" % int(value)
	)

	var size_label := Label.new()
	size_label.text = "Size (viewport ÷ %.1f)" % PauseMenu.PIN_SIZE_DIVISOR_MIN
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_label.add_theme_font_size_override("font_size", 13)
	size_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(size_label)

	var size_slider := HSlider.new()
	size_slider.min_value = PauseMenu.PIN_SIZE_DIVISOR_MIN
	size_slider.max_value = PauseMenu.PIN_SIZE_DIVISOR_MAX
	size_slider.step = PIN_SIZE_DIVISOR_STEP
	size_slider.value = menu.get_pins_size_divisor()
	size_slider.custom_minimum_size = Vector2(0, 30)
	size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(size_slider)

	# Le diviseur seul ne dit rien à l'écran : on montre la taille qu'il
	# produit, sinon impossible de savoir si l'on agrandit ou réduit le pin.
	var size_val := Label.new()
	size_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_val.add_theme_font_size_override("font_size", 13)
	size_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(size_val)

	var _refresh_size := func(value: float) -> void:
		var vp := menu.get_viewport().get_visible_rect().size
		size_val.text = "÷ %.1f  →  %d×%d" % [value, int(vp.x / value), int(vp.y / value)]
	_refresh_size.call(size_slider.value)
	size_slider.value_changed.connect(func(value: float):
		_refresh_size.call(value)
	)

	# Auto-apply : chaque changement est sauvegardé et émis immédiatement.
	var auto_apply := func(_v = null) -> void:
		_apply_pins_settings(opt, pos_opt, slider, size_slider)
	opt.item_selected.connect(auto_apply)
	pos_opt.item_selected.connect(auto_apply)
	slider.value_changed.connect(auto_apply)
	size_slider.value_changed.connect(auto_apply)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func _apply_pins_settings(opt: OptionButton, pos_opt: OptionButton, slider: HSlider,
		size_slider: HSlider) -> void:
	var above := opt.selected == 1
	var percent: int = clampi(int(slider.value), 0, 100)
	var pos := "top_left"
	if pos_opt.selected >= 0 and pos_opt.selected < PauseMenu.PIN_POSITIONS.size():
		pos = String(PauseMenu.PIN_POSITIONS[pos_opt.selected].get("id", "top_left"))
	var divisor := clampf(snappedf(size_slider.value, PIN_SIZE_DIVISOR_STEP),
		PauseMenu.PIN_SIZE_DIVISOR_MIN, PauseMenu.PIN_SIZE_DIVISOR_MAX)
	var old_above := menu.get_pins_above_focus()
	var old_percent := menu.get_pins_opacity()
	var old_pos := menu.get_pins_position()
	var old_divisor := menu.get_pins_size_divisor()
	menu._settings["pins_above_focus"] = above
	menu._settings["pins_opacity"] = percent
	menu._settings["pins_position"] = pos
	menu._settings["pins_size_divisor"] = divisor
	menu._save_settings()
	# N'émet que ce qui a réellement changé (les curseurs appellent ceci à chaque cran).
	if above != old_above:
		menu.pins_layer_changed.emit(above)
	if percent != old_percent:
		menu.pins_opacity_changed.emit(percent)
	if pos != old_pos:
		menu.pins_position_changed.emit(pos)
	if not is_equal_approx(divisor, old_divisor):
		menu.pins_size_divisor_changed.emit(divisor)

func _set_accent_color(c: Color) -> void:
	c.a = 1.0
	menu._settings["accent_color"] = c.to_html(false)
	menu._save_settings()
	UITheme.set_accent_color(c)
	menu.accent_color_changed.emit(c)

# Apparence des applications : couleur d'accentuation + thème clair/sombre, en
# deux lignes compactes. Appliqués
# immédiatement et publiés aux apps via le portail Settings.
func _add_appearance_rows() -> void:
	var accent_row := HBoxContainer.new()
	accent_row.add_theme_constant_override("separation", 8)
	menu.container.add_child(accent_row)
	accent_row.add_child(_make_row_label("Accent color"))

	var accent_btn := ColorPickerButton.new()
	accent_btn.focus_mode = Control.FOCUS_ALL
	accent_btn.edit_alpha = false
	accent_btn.color = menu.get_accent_color()
	accent_btn.custom_minimum_size = Vector2(64, 30)
	accent_row.add_child(accent_btn)
	accent_btn.color_changed.connect(_set_accent_color)

	var accent_reset := menu._make_btn("Reset", "action-button")
	accent_reset.custom_minimum_size = Vector2(0, 30)
	accent_reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	accent_reset.pressed.connect(func():
		accent_btn.color = UITheme.DEFAULT_ACCENT
		_set_accent_color(UITheme.DEFAULT_ACCENT)
	)
	accent_row.add_child(accent_reset)

	var scheme_row := HBoxContainer.new()
	scheme_row.add_theme_constant_override("separation", 8)
	menu.container.add_child(scheme_row)
	scheme_row.add_child(_make_row_label("App theme"))

	var scheme_opt := OptionButton.new()
	scheme_opt.add_item("Dark")
	scheme_opt.add_item("Light")
	scheme_opt.selected = 1 if menu.get_color_scheme() == "light" else 0
	scheme_opt.custom_minimum_size = Vector2(0, 32)
	scheme_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scheme_row.add_child(scheme_opt)
	scheme_opt.item_selected.connect(func(i: int):
		var v := "light" if i == 1 else "dark"
		menu._settings["color_scheme"] = v
		menu._save_settings()
		menu.color_scheme_changed.emit(v)
	)

func _make_row_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	return lbl

func _show_graphics_general() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "graphics_general"

	menu.container.add_child(menu._make_title("GRAPHICS — GENERAL"))

	# ── Antialiasing ──
	var aa_label := Label.new()
	aa_label.text = "Antialiasing"
	aa_label.add_theme_font_size_override("font_size", 14)
	aa_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(aa_label)

	var aa_opt := OptionButton.new()
	aa_opt.add_item("Off", 0)       # index 0 → "off"
	aa_opt.add_item("FXAA", 1)      # index 1 → "fxaa"
	aa_opt.add_item("MSAA 2x", 2)   # index 2 → "msaa_2x"
	aa_opt.add_item("MSAA 4x", 3)   # index 3 → "msaa_4x"
	aa_opt.add_item("MSAA 8x", 4)   # index 4 → "msaa_8x"
	aa_opt.custom_minimum_size = Vector2(0, 36)
	aa_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	aa_opt.add_theme_font_size_override("font_size", 14)
	var current_aa := menu.get_aa_mode()
	match current_aa:
		"fxaa": aa_opt.selected = 1
		"msaa_2x": aa_opt.selected = 2
		"msaa_4x": aa_opt.selected = 3
		"msaa_8x": aa_opt.selected = 4
		_: aa_opt.selected = 0
	menu.container.add_child(aa_opt)

	# ── Environment (WorldEnvironment du niveau courant) ──
	menu.container.add_child(menu._make_section("Effects"))

	var env_btns := {}
	for pair in ENVIRONMENT_TOGGLES:
		var env_btn := CheckButton.new()
		env_btn.text = String(pair[1])
		env_btn.button_pressed = bool(menu.page_world._env_default(String(pair[0]), false))
		env_btn.custom_minimum_size = Vector2(0, 36)
		env_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		env_btn.add_theme_font_size_override("font_size", 14)
		menu.container.add_child(env_btn)
		env_btns[String(pair[0])] = env_btn

	menu.container.add_child(menu._make_section("Color Adjustments"))

	var brightness_s := menu.page_world._make_env_slider("Brightness", "adjustment_brightness")
	var contrast_s := menu.page_world._make_env_slider("Contrast", "adjustment_contrast")
	var saturation_s := menu.page_world._make_env_slider("Saturation", "adjustment_saturation")

	# ── Auto-apply ──
	var auto_apply := func(_v = null) -> void:
		_apply_graphics(aa_opt, env_btns, brightness_s, contrast_s, saturation_s)
	aa_opt.item_selected.connect(auto_apply)
	for key in env_btns:
		(env_btns[key] as CheckButton).toggled.connect(auto_apply)
	brightness_s.value_changed.connect(auto_apply)
	contrast_s.value_changed.connect(auto_apply)
	saturation_s.value_changed.connect(auto_apply)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

func _show_controls_general() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "controls_general"

	menu.container.add_child(menu._make_title("CONTROLS — GENERAL"))

	# ── Mouse sensitivity ──
	var mouse_label := Label.new()
	mouse_label.text = "Mouse Sensitivity"
	mouse_label.add_theme_font_size_override("font_size", 14)
	mouse_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(mouse_label)

	var mouse_slider := HSlider.new()
	mouse_slider.min_value = 0.5
	mouse_slider.max_value = 3.0
	mouse_slider.step = 0.1
	mouse_slider.value = menu.get_mouse_sens_mult()
	mouse_slider.custom_minimum_size = Vector2(0, 30)
	mouse_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(mouse_slider)

	var mouse_val := Label.new()
	mouse_val.text = "%.1fx" % mouse_slider.value
	mouse_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mouse_val.add_theme_font_size_override("font_size", 13)
	mouse_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(mouse_val)

	mouse_slider.value_changed.connect(func(v: float):
		mouse_val.text = "%.1fx" % v
	)

	# ── Right stick sensitivity ──
	var pad_label := Label.new()
	pad_label.text = "Right Stick Sensitivity"
	pad_label.add_theme_font_size_override("font_size", 14)
	pad_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(pad_label)

	var pad_slider := HSlider.new()
	pad_slider.min_value = 0.5
	pad_slider.max_value = 3.0
	pad_slider.step = 0.1
	pad_slider.value = menu.get_pad_look_sens_mult()
	pad_slider.custom_minimum_size = Vector2(0, 30)
	pad_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(pad_slider)

	var pad_val := Label.new()
	pad_val.text = "%.1fx" % pad_slider.value
	pad_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pad_val.add_theme_font_size_override("font_size", 13)
	pad_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(pad_val)

	pad_slider.value_changed.connect(func(v: float):
		pad_val.text = "%.1fx" % v
	)

	# ── Gyroscope aim ──

	var gyro_check := CheckButton.new()
	gyro_check.text = "Gyroscope Aim"
	gyro_check.button_pressed = menu.is_gyro_aim_enabled()
	gyro_check.custom_minimum_size = Vector2(0, 36)
	gyro_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gyro_check.add_theme_font_size_override("font_size", 14)
	menu.container.add_child(gyro_check)

	var gyro_label := Label.new()
	gyro_label.text = "Gyro Sensitivity"
	gyro_label.add_theme_font_size_override("font_size", 14)
	gyro_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(gyro_label)

	var gyro_slider := HSlider.new()
	gyro_slider.min_value = 0.1
	gyro_slider.max_value = 2.0
	gyro_slider.step = 0.1
	gyro_slider.value = menu.get_gyro_sens_mult()
	gyro_slider.custom_minimum_size = Vector2(0, 30)
	gyro_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(gyro_slider)

	var gyro_val := Label.new()
	gyro_val.text = "%.1fx" % gyro_slider.value
	gyro_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gyro_val.add_theme_font_size_override("font_size", 13)
	gyro_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(gyro_val)

	gyro_slider.value_changed.connect(func(v: float):
		gyro_val.text = "%.1fx" % v
	)

	# ── Focus mode stick sensitivity ──
	var focus_label := Label.new()
	focus_label.text = "Focus Mode Stick Sensitivity"
	focus_label.add_theme_font_size_override("font_size", 14)
	focus_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	menu.container.add_child(focus_label)

	var focus_slider := HSlider.new()
	focus_slider.min_value = 0.5
	focus_slider.max_value = 3.0
	focus_slider.step = 0.1
	focus_slider.value = menu.get_focus_stick_sens_mult()
	focus_slider.custom_minimum_size = Vector2(0, 30)
	focus_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.container.add_child(focus_slider)

	var focus_val := Label.new()
	focus_val.text = "%.1fx" % focus_slider.value
	focus_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	focus_val.add_theme_font_size_override("font_size", 13)
	focus_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	menu.container.add_child(focus_val)

	focus_slider.value_changed.connect(func(v: float):
		focus_val.text = "%.1fx" % v
	)

	# ── Auto-apply ──
	var auto_apply := func(_v = null) -> void:
		_apply_controls(mouse_slider, pad_slider, focus_slider, gyro_check, gyro_slider)
	mouse_slider.value_changed.connect(auto_apply)
	pad_slider.value_changed.connect(auto_apply)
	focus_slider.value_changed.connect(auto_apply)
	gyro_check.toggled.connect(auto_apply)
	gyro_slider.value_changed.connect(auto_apply)

	menu.container.add_child(menu._make_spacer())
	menu.container.add_child(menu._make_back_btn())

const AA_MODES := ["off", "fxaa", "msaa_2x", "msaa_4x", "msaa_8x"]

func _apply_aa(mode: String) -> void:
	var vp := menu.get_viewport()
	match mode:
		"fxaa":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.msaa_3d = Viewport.MSAA_DISABLED
		"msaa_2x":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.msaa_3d = Viewport.MSAA_2X
		"msaa_4x":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.msaa_3d = Viewport.MSAA_4X
		"msaa_8x":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.msaa_3d = Viewport.MSAA_8X
		_:
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.msaa_3d = Viewport.MSAA_DISABLED

func _apply_graphics(aa_opt: OptionButton, env_btns: Dictionary, brightness_s: HSlider, contrast_s: HSlider, saturation_s: HSlider) -> void:
	var aa_idx := aa_opt.selected
	if aa_idx < 0 or aa_idx >= AA_MODES.size():
		aa_idx = 0
	var aa_mode = AA_MODES[aa_idx]

	menu._settings["aa_mode"] = aa_mode
	menu._save_settings()

	_apply_aa(aa_mode)

	var env := {}
	for key in env_btns:
		env[key] = (env_btns[key] as CheckButton).button_pressed
	# Les ajustements couleurs restent actifs (pilotés par les curseurs — le
	# toggle dédié a été retiré) ; 1.0 sur les trois reste neutre.
	env["adjustment_enabled"] = true
	env["adjustment_brightness"] = brightness_s.value
	env["adjustment_contrast"] = contrast_s.value
	env["adjustment_saturation"] = saturation_s.value
	menu._settings["environment"] = env
	menu._save_settings()
	menu.environment_settings_changed.emit(env)

func _apply_controls(mouse_s: HSlider, pad_s: HSlider, focus_s: HSlider, gyro_btn: CheckButton, gyro_s: HSlider) -> void:
	var mouse_mult: float = mouse_s.value
	var pad_mult: float = pad_s.value
	var focus_mult: float = focus_s.value
	var gyro_enabled: bool = gyro_btn.button_pressed
	var gyro_mult: float = gyro_s.value

	var old_mouse := menu.get_mouse_sens_mult()
	var old_pad := menu.get_pad_look_sens_mult()
	var old_focus := menu.get_focus_stick_sens_mult()
	var old_gyro_on := menu.is_gyro_aim_enabled()
	var old_gyro := menu.get_gyro_sens_mult()

	menu._settings["mouse_sens_mult"] = mouse_mult
	menu._settings["pad_look_sens_mult"] = pad_mult
	menu._settings["focus_stick_sens_mult"] = focus_mult
	menu._settings["gyro_aim_enabled"] = gyro_enabled
	menu._settings["gyro_sens_mult"] = gyro_mult
	menu._save_settings()

	# N'émet que ce qui a réellement changé (appelé à chaque cran de curseur).
	if not is_equal_approx(mouse_mult, old_mouse):
		menu.mouse_sens_changed.emit(mouse_mult)
	if not is_equal_approx(pad_mult, old_pad):
		menu.pad_look_sens_changed.emit(pad_mult)
	if not is_equal_approx(focus_mult, old_focus):
		menu.focus_stick_sens_changed.emit(focus_mult)
	if gyro_enabled != old_gyro_on:
		menu.gyro_aim_changed.emit(gyro_enabled)
	if not is_equal_approx(gyro_mult, old_gyro):
		menu.gyro_sens_changed.emit(gyro_mult)

# ── Environment (réglages WorldEnvironment) ───────────────────────────

# Toggles d'effet exposés dans GRAPHICS → General (clé Environment → libellé).
# Appliqués au WorldEnvironment du niveau courant.
const ENVIRONMENT_TOGGLES := [
	["ssr_enabled", "SSR"],
	["ssao_enabled", "SSAO"],
	["ssil_enabled", "SSIL"],
	["sdfgi_enabled", "SDFGI"],
	["glow_enabled", "Glow"],
	["fog_enabled", "Fog"],
	["volumetric_fog_enabled", "Volumetric Fog"],
]
