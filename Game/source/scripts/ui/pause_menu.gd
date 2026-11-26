extends GameMenu

signal app_launch_requested(command: String)
signal quit_requested
signal keyboard_layout_changed(layout: String, variant: String)
signal polkit_agent_changed(path: String)
signal pins_layer_changed(above: bool)
signal pins_opacity_changed(percent: int)
signal pins_position_changed(position: String)
signal pins_size_divisor_changed(divisor: float)
signal lan_host_requested
signal lan_join_requested(ip: String, pin: String, encrypted: bool)
signal lan_video_settings_changed(bitrate: int, codec: String, fps: int)
signal tutorial_requested
signal respawn_requested
signal lan_disconnect_requested
signal lan_discover_requested
signal lan_color_changed(color: Color)
signal accent_color_changed(color: Color)
signal color_scheme_changed(scheme: String)
signal lan_avatar_changed(path: String)
signal level_change_requested(path: String)
signal lan_name_changed(name: String)

signal graphics_settings_changed(aa_mode: String, fps_limit: int)
signal snapping_disabled_changed(disabled: bool)
signal ui_hides_names_changed(enabled: bool)
signal fullbody_changed(enabled: bool)
signal mouse_sens_changed(mult: float)
signal pad_look_sens_changed(mult: float)
signal focus_stick_sens_changed(mult: float)
signal gyro_aim_changed(enabled: bool)
signal gyro_sens_changed(mult: float)
signal environment_settings_changed(settings: Dictionary)

const LanManagerScript := preload("res://scripts/network/lan_manager.gd")
const LevelCatalogScript := preload("res://scripts/main/level_catalog.gd")

const SETTINGS_PATH := "user://settings.json"

# Le bouton Quit ne devient actif qu'après ce temps de jeu (secondes).
const QUIT_GAMEPLAY_DELAY := 3.0

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

var container: VBoxContainer

# Actions remappables depuis le menu (ordre d'affichage).
const REMAPPABLE_ACTIONS := [
	"forward", "back", "left", "right", "jump",
	"look_up", "look_down", "look_left", "look_right",
	"interact_mode", "layer_interact", "window_menu", "radial_menu",
	"grab", "focus_window", "pin_window", "kill_window", "hide_window", "share_window",
	"screenshot", "force_game", "freecam", "toggle_tps", "toggle_ui",
	"left_click", "right_click", "middle_click", "scroll_up", "scroll_down",
]

var _settings: Dictionary = {}
var _lan: Node = null

## Réf. directe vers le lan_manager (retour de get_banned_ips/unban_ip dans
## la page admin). Injectée par wayland_room au setup LAN.
func set_lan_ref(lan: Node) -> void:
	_lan = lan

# Page « Worlds » : WaylandRoom (niveau courant, chargement en cours) et
# dernier message d'état, conservé si la page est reconstruite.
var _level_room: Node = null
var _level_status_text := ""
var _level_status_label: Label = null

func set_level_ref(room: Node) -> void:
	_level_room = room

# Pages du menu (catégories + sous-pages). La catégorie "main" est le hub.
var _current_view := "main"

# Page parente de chaque sous-page : Back / Échap / B y reviennent au lieu de
# tout renvoyer au hub. "graphics"/"controls" sont ici les pages catégories
# (rubriques), distinctes des sous-pages "graphics_general"/"controls_general".
const _PARENT_VIEW := {
	"general": "main",
	"graphics": "main",
	"controls": "main",
	"lan": "main",
	"levels": "main",
	"startup": "general",
	"polkit": "general",
	"screenshots": "general",
	"graphics_general": "graphics",
	"pins": "graphics",
	"controls_general": "controls",
	"keybinds": "controls",
	"custom": "controls",
	"keyboard_layout": "controls",
}
var _waiting_action := "" # action en cours de rebind, "" = aucun
var _waiting_gamepad := false # true = on attend un event manette pour le rebind
var _keybinds_buttons: Dictionary = {} # action -> Button
var _gamepad_keybinds_buttons: Dictionary = {} # action -> Button (colonne manette)
var _cleared_keybinds: Dictionary = {} # action -> {"kb": bool, "pad": bool} (bind passé à None)>
# Capture d'une touche pour un custom bind
var _custom_key_waiting := false
var _custom_keycode := 0
var _custom_is_mouse := false
var _custom_mods: Dictionary = {} # {"ctrl": bool, "shift": bool, "alt": bool, "super": bool}
var _custom_key_btn: Button = null
var _custom_cmd_edit: LineEdit = null
var _editing_index := -1 # index du custom bind en cours d'édition, -1 = aucun
var _quit_btn: Button = null
var _play_time := 0.0
var _keyboard: VirtualKeyboard = null
# Page LAN
var _lan_status_label: Label = null
var _lan_players_label: Label = null
var _lan_results_box: VBoxContainer = null
var _lan_status_text := ""
var _lan_roster: Array = []
var _lan_connected := false
var _lan_pin_label: Label = null
var _lan_pin_value := ""
var _lan_pin_visible := true
var _lan_pin_toggle_btn: Button = null
var _lan_ip_edit: LineEdit = null
var _lan_pin_edit: LineEdit = null
var _lan_encryption_btn: CheckButton = null
var _lan_disconnect_btn: Button = null

func _can_stick_input() -> bool:
	if _keyboard != null and _keyboard.visible:
		return false
	if not _waiting_action == "" or _custom_key_waiting:
		return false
	if _is_popup_open():
		return false
	return true

func _is_popup_open() -> bool:
	return _has_visible_popup(container)

func _has_visible_popup(node: Node) -> bool:
	for child in node.get_children():
		if child is OptionButton and child.get_popup().visible:
			return true
		if child is ColorPickerButton and child.get_popup().visible:
			return true
		if child.get_child_count() > 0 and _has_visible_popup(child):
			return true
	return false

func _find_open_color_picker() -> ColorPickerButton:
	return _find_open_color_picker_in(container)

func _find_open_color_picker_in(node: Node) -> ColorPickerButton:
	for child in node.get_children():
		if child is ColorPickerButton and child.get_popup().visible:
			return child
		if child.get_child_count() > 0:
			var found := _find_open_color_picker_in(child)
			if found != null:
				return found
	return null

func _process(delta: float) -> void:
	super(delta)  # GameMenu : nav/scroll stick
	if _play_time < QUIT_GAMEPLAY_DELAY:
		_play_time += delta
	if _quit_btn:
		_quit_btn.disabled = _play_time < QUIT_GAMEPLAY_DELAY
	# ColorPicker joystick control
	if visible:
		var cb := _find_open_color_picker()
		if cb != null:
			if _ui_events_backup.is_empty():
				_disable_joypad_navigation()
			_handle_color_picker_joystick(delta)
		elif not _ui_events_backup.is_empty():
			_restore_joypad_navigation()

var _popup_focus_backup: Array = [] # [{ctrl, original_mode}]
var _ui_events_backup: Dictionary = {} # action_name → [events]

func _handle_color_picker_joystick(delta: float) -> void:
	var cb := _find_open_color_picker()
	if cb == null:
		return
	var picker: ColorPicker = cb.get_picker()
	if picker == null:
		return
	# Désactiver la navigation joypad dans le popup (y compris widgets créés tard)
	_disable_popup_nav_focus(cb.get_popup())
	var c := cb.color
	var moved := false
	# Left stick : saturation (X) + value (Y)
	var lx := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var ly := Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	if absf(lx) > 0.15:
		c.s = clampf(c.s + lx * delta * 0.8, 0.0, 1.0)
		moved = true
	if absf(ly) > 0.15:
		c.v = clampf(c.v - ly * delta * 0.8, 0.0, 1.0)
		moved = true
	# Right stick : hue
	var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(ry) > 0.15:
		c.h = fmod(c.h + ry * delta * 0.8, 1.0)
		if c.h < 0.0:
			c.h += 1.0
		moved = true
	if moved:
		picker.set_pick_color(c)
		cb.color = c

func _disable_joypad_navigation() -> void:
	for action in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		var events := InputMap.action_get_events(action)
		_ui_events_backup[action] = events.duplicate()
		for event in events:
			if event is InputEventJoypadButton or event is InputEventJoypadMotion:
				InputMap.action_erase_event(action, event)

func _restore_joypad_navigation() -> void:
	for action in _ui_events_backup:
		for event in _ui_events_backup[action]:
			InputMap.action_add_event(action, event)
	_ui_events_backup.clear()

func _disable_popup_nav_focus(node: Node) -> void:
	for child in node.get_children():
		if child is Control and child.focus_mode != Control.FOCUS_NONE:
			_popup_focus_backup.append({"ctrl": child, "mode": child.focus_mode})
			child.focus_mode = Control.FOCUS_NONE
		if child.get_child_count() > 0:
			_disable_popup_nav_focus(child)

func _restore_popup_nav_focus() -> void:
	for entry in _popup_focus_backup:
		var ctrl = entry["ctrl"]
		if is_instance_valid(ctrl):
			ctrl.focus_mode = entry["mode"]
	_popup_focus_backup.clear()

func _ready() -> void:
	visible = false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_build_shell()
	_apply_styling()
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)
	_settings = _load_settings()
	UITheme.set_accent_color(get_accent_color())
	_apply_saved_keybinds()

func _apply_styling() -> void:
	theme = UITheme.theme
	set_meta("ui_class", "menu-panel pause-menu")
	# Toute la coque (en-tête, sidebar, contenu) porte des classes CSS.
	UITheme.apply_css(self)

func _on_stylesheet_reloaded() -> void:
	theme = UITheme.theme
	UITheme.apply_css(self)

func _clear() -> void:
	_waiting_action = ""
	_waiting_gamepad = false
	for c in container.get_children():
		c.queue_free()
	# Focus pad + habillage (fil d'Ariane, sidebar, scroll) : différés, donc
	# exécutés APRÈS la fin de construction de la page par le _show_* appelant.
	_after_page_built.call_deferred()

func _make_spacer() -> Control:
	var s := Control.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s

func _make_btn(text: String, klass := "") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 42)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if klass != "":
		btn.set_meta("ui_class", klass)
		UITheme.apply_class(btn, klass)
	return btn

## Titre de page : affiché en tête du panneau de contenu. Les titres
## historiques « GRAPHICS — GENERAL » sont réduits à leur dernier segment
## (« General ») : la catégorie parente est déjà dans le fil d'Ariane.
func _make_title(text: String) -> Label:
	var t := text
	var dash := t.rfind("—")
	if dash >= 0:
		t = t.substr(dash + 1)
	var lbl := Label.new()
	lbl.text = _title_case(t.strip_edges())
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.set_meta("ui_class", "page-title")
	UITheme.apply_class(lbl, "page-title")
	lbl.custom_minimum_size = Vector2(0, 40)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

static func _title_case(t: String) -> String:
	var words: PackedStringArray = []
	for w in t.split(" ", false):
		words.append(w.substr(0, 1).to_upper() + w.substr(1).to_lower())
	return " ".join(words)

## Bouton retour des sous-pages. Sur une page de premier niveau (parent =
## accueil), la sidebar fait office de navigation : bouton masqué (rendu
## quand même, les appelants l'ajoutent tous à la page).
func _make_back_btn() -> Button:
	var back := _make_btn("‹  Back", "back-button")
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.custom_minimum_size = Vector2(140, 38)
	back.pressed.connect(_go_back)
	if String(_PARENT_VIEW.get(_current_view, "main")) == "main":
		back.visible = false
	return back

## Ligne de navigation vers une sous-page (« Startup Apps  › »), avec un
## sous-titre optionnel décrivant ce qu'on y règle.
func _make_nav_row(text: String, subtitle: String, target: Callable) -> Button:
	var btn := _make_btn(text, "nav-row")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0, 56 if subtitle != "" else 44)
	if subtitle != "":
		btn.text = text + "\n" + subtitle
		btn.add_theme_font_size_override("font_size", 14)
	var chevron := Label.new()
	chevron.text = "›"
	chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chevron.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	chevron.offset_left = -32
	chevron.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chevron.set_meta("ui_class", "nav-chevron")
	UITheme.apply_class(chevron, "nav-chevron")
	btn.add_child(chevron)
	btn.pressed.connect(target)
	return btn

## Intertitre de section dans une page (« EFFECTS », « COLOR ADJUSTMENTS »).
func _make_section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.set_meta("ui_class", "section-title")
	UITheme.apply_class(lbl, "section-title")
	lbl.custom_minimum_size = Vector2(0, 30)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return lbl

# Retour à la page parente (catégorie), ou fermeture du menu depuis le hub.
func _go_back() -> void:
	match _PARENT_VIEW.get(_current_view, "main"):
		"general": _show_general()
		"graphics": _show_graphics()
		"controls": _show_controls()
		"lan": _show_lan()
		_: _show_main()

func _make_line_edit() -> LineEdit:
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 36)

	le.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	le.add_theme_color_override("font_placeholder_color", Color(0.5, 0.52, 0.58))
	le.add_theme_color_override("caret_color", Color(0.9, 0.92, 0.95))
	return le

func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()

## Navigation manette : après construction d'une page (tous les _show_*
## passent par _clear()), poser le focus sur le premier contrôle pilotable
## (bouton/option/case — pas les LineEdit : le clavier leur appartiendrait).
## Les actions ui_up/down/left/right et ui_accept ont des liaisons pad par
## défaut dans Godot (d-pad + stick gauche + A).
func _focus_first_deferred() -> void:
	var stack: Array[Node] = [container]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n.is_queued_for_deletion():
			continue
		for c in n.get_children():
			stack.push_back(c)
		if (n is BaseButton or n is OptionButton or n is CheckBox) and (n as Control).visible:
			n.grab_focus()
			return
	# Page sans contrôle (accueil) : focus sur la sidebar.
	_focus_sidebar_active()

func setup_keyboard(kb: VirtualKeyboard) -> void:
	_keyboard = kb

func show_menu() -> void:
	visible = true
	_show_main()
	# Ne pas forcer MOUSE_MODE_VISIBLE ici : la souris n'apparaît que si
	# l'utilisateur bouge la souris (géré dans player._input). Les users
	# pad naviguent au d-pad sans voir le curseur.

func hide_menu() -> void:
	_waiting_action = ""
	_waiting_gamepad = false
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not _ui_events_backup.is_empty():
		_restore_joypad_navigation()
	if not _popup_focus_backup.is_empty():
		_restore_popup_nav_focus()

func _quit_game() -> void:
	# Le compositeur (wayland_room._on_quit_requested) ferme d'abord toutes
	# les apps lancées dans le jeu, puis quitte Godot (le destructeur de
	# WlrCompositor termine xwayland-satellite et le bus D-Bus privé).
	quit_requested.emit()

# ── Pages ────────────────────────────────────────────────────────────

func _show_main() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "main"
	_editing_index = -1

	container.add_child(_make_title("Paused"))

	var hint := Label.new()
	hint.text = "Pick a category on the left.  Esc / B goes back."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.set_meta("ui_class", "hint")
	UITheme.apply_class(hint, "hint")
	container.add_child(hint)

	# Cartes d'état : monde courant et session multijoueur (lecture seule —
	# les actions sont dans la sidebar).
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 12)
	container.add_child(cards)
	cards.add_child(_make_card("WORLD", _world_label(),
		"Locked during a multiplayer session" if _lan_connected else "Change it in Worlds"))
	var players := _lan_roster.size()
	cards.add_child(_make_card("MULTIPLAYER",
		("Connected" if _lan_connected else "Offline"),
		("%d player%s" % [players, "" if players == 1 else "s"]) if _lan_connected else "Host or join in Multiplayer"))

	container.add_child(_make_spacer())

# ── Pages catégories du hub ───────────────────────────────────────────

func _show_general() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "general"
	_editing_index = -1

	container.add_child(_make_title("GENERAL"))

	container.add_child(_make_nav_row("Startup Apps", "Apps launched with the game", _show_startup_apps))
	container.add_child(_make_nav_row("Polkit Agent", "Authentication dialog used in game", _show_polkit))
	container.add_child(_make_nav_row("Screenshot Folder", "Where captures are saved", _show_screenshots))

	_add_profile_rows()

	container.add_child(_make_section("Performance"))
	# ── Max FPS (appliqué immédiatement) ──
	var fps_label := _make_row_label("Max FPS")
	container.add_child(fps_label)

	var fps_slider := HSlider.new()
	fps_slider.min_value = 30
	fps_slider.max_value = 240
	fps_slider.step = 10
	fps_slider.value = get_fps_limit()
	fps_slider.custom_minimum_size = Vector2(0, 30)
	fps_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(fps_slider)

	var fps_val := Label.new()
	fps_val.text = "%d" % int(fps_slider.value)
	fps_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fps_val.add_theme_font_size_override("font_size", 13)
	fps_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(fps_val)

	fps_slider.value_changed.connect(func(v: float):
		fps_val.text = "%d" % int(v)
		_settings["fps_limit"] = int(v)
		_save_settings()
		Engine.max_fps = int(v)
		graphics_settings_changed.emit(get_aa_mode(), int(v))
	)


	container.add_child(_make_section("Behaviour"))
	# ── Collage des fenêtres ──
	# Appliqué comme le Max FPS ci-dessus : cette page n'a pas de bouton Apply,
	# la case est donc pré-appliquée dès qu'on la coche.
	var snap_check := CheckButton.new()
	snap_check.text = "Disable Window Snapping"
	snap_check.button_pressed = is_snapping_disabled()
	snap_check.custom_minimum_size = Vector2(0, 36)
	snap_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snap_check.add_theme_font_size_override("font_size", 14)
	container.add_child(snap_check)

	snap_check.toggled.connect(func(on: bool):
		_settings["snapping_disabled"] = on
		_save_settings()
		snapping_disabled_changed.emit(on)
	)

	# toggle_ui masque aussi les noms des joueurs (Label3D des avatars).
	var names_check := CheckButton.new()
	names_check.text = "toggle_ui hides player names"
	names_check.button_pressed = does_toggle_ui_hide_names()
	names_check.custom_minimum_size = Vector2(0, 36)
	names_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names_check.add_theme_font_size_override("font_size", 14)
	container.add_child(names_check)

	names_check.toggled.connect(func(on: bool):
		_settings["toggle_ui_hides_names"] = on
		_save_settings()
		ui_hides_names_changed.emit(on)
	)

	# Full body awareness : voir son propre corps (tête cachée) en vue 1ère personne.
	var body_check := CheckButton.new()
	body_check.text = "Full body awareness (see your own body in first person)"
	body_check.button_pressed = is_fullbody_enabled()
	body_check.custom_minimum_size = Vector2(0, 36)
	body_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_check.add_theme_font_size_override("font_size", 14)
	container.add_child(body_check)

	body_check.toggled.connect(func(on: bool):
		_settings["fullbody_awareness"] = on
		_save_settings()
		fullbody_changed.emit(on)
	)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

# Profil joueur (nom, couleur, avatar) : affiché dans GENERAL, utilisé en multijoueur.
func _add_profile_rows() -> void:
	container.add_child(_make_section("Profile"))
	var name_label := Label.new()
	name_label.text = "Player name"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(name_label)

	var name_edit := _make_line_edit()
	name_edit.text = get_lan_player_name()
	name_edit.placeholder_text = "Player name"
	name_edit.text_submitted.connect(func(_t: String):
		_save_lan_name(name_edit)
	)
	name_edit.focus_exited.connect(func():
		if name_edit.text.strip_edges() != get_lan_player_name():
			_save_lan_name(name_edit)
	)
	container.add_child(name_edit)

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
	color_btn.color = get_lan_player_color()
	color_btn.custom_minimum_size = Vector2(64, 30)
	color_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	color_row.add_child(color_btn)
	var apply_color := func(c: Color) -> void:
		_settings["lan_player_color"] = c.to_html(true)
		_save_settings()
		lan_color_changed.emit(c)
	if _lan_connected:
		# Connecté : on n'envoie qu'à la fermeture du sélecteur, pour ne pas
		# inonder le réseau pendant le glissé.
		color_btn.popup_closed.connect(func():
			if color_btn.color.to_html(true) != get_lan_player_color().to_html(true):
				apply_color.call(color_btn.color)
		)
	else:
		color_btn.color_changed.connect(apply_color)
	container.add_child(color_row)

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
	var saved_avatar := get_lan_avatar_path()
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
			_settings["lan_avatar_path"] = p
			_save_settings()
			lan_avatar_changed.emit(p)
		)
		avatar_row.add_child(avatar_opt)
	else:
		avatar_label.queue_free()
		avatar_row.queue_free()
	container.add_child(avatar_row)

func _show_graphics() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "graphics"
	_editing_index = -1

	container.add_child(_make_title("GRAPHICS"))

	container.add_child(_make_nav_row("General", "Anti-aliasing, effects, color adjustments", _show_graphics_general))
	container.add_child(_make_nav_row("Pinned Windows", "Layer, opacity, position and size of pins", _show_pins))

	container.add_child(_make_section("Appearance"))
	_add_appearance_rows()

	container.add_child(_make_spacer())

	container.add_child(_make_back_btn())

func _show_controls() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "controls"
	_editing_index = -1

	container.add_child(_make_title("CONTROLS"))

	container.add_child(_make_nav_row("General", "Mouse, stick and gyro sensitivity", _show_controls_general))
	container.add_child(_make_nav_row("Remap Keybinds", "Keyboard and gamepad bindings", _show_keybinds))
	container.add_child(_make_nav_row("Custom Binds", "Shortcuts that run your own commands", _show_custom_binds))
	container.add_child(_make_nav_row("Keyboard Layout", "Layout used by in-game apps", _show_keyboard_layout))

	container.add_child(_make_spacer())

	container.add_child(_make_back_btn())

func _show_keybinds() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "keybinds"

	container.add_child(_make_title("REMAP KEYBINDS"))

	var hint := Label.new()
	hint.text = "Click an action, then press a key/mouse button or gamepad input (Escape/Start = clear this binding)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	container.add_child(scroll)

	# Header row
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var _hdr_action := Label.new()
	_hdr_action.text = "Action"
	_hdr_action.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hdr_action.custom_minimum_size = Vector2(190, 0)
	_hdr_action.add_theme_font_size_override("font_size", 12)
	_hdr_action.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
	header.add_child(_hdr_action)
	var _hdr_kb := Label.new()
	_hdr_kb.text = "Keyboard / Mouse"
	_hdr_kb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hdr_kb.custom_minimum_size = Vector2(170, 0)
	_hdr_kb.add_theme_font_size_override("font_size", 12)
	_hdr_kb.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
	header.add_child(_hdr_kb)
	var _hdr_pad := Label.new()
	_hdr_pad.text = "Gamepad"
	_hdr_pad.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hdr_pad.custom_minimum_size = Vector2(170, 0)
	_hdr_pad.add_theme_font_size_override("font_size", 12)
	_hdr_pad.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
	header.add_child(_hdr_pad)
	list.add_child(header)

	_keybinds_buttons.clear()
	_gamepad_keybinds_buttons.clear()
	for action in REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var label := Label.new()
		label.text = action
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.custom_minimum_size = Vector2(190, 0)
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
		row.add_child(label)

		var btn := _make_btn(_binding_text(action))
		btn.custom_minimum_size = Vector2(170, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(_start_rebind.bind(action, false))
		row.add_child(btn)
		_keybinds_buttons[action] = btn

		var gp_btn := _make_btn(_gamepad_binding_text(action))
		gp_btn.custom_minimum_size = Vector2(170, 36)
		gp_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		gp_btn.pressed.connect(_start_rebind.bind(action, true))
		row.add_child(gp_btn)
		_gamepad_keybinds_buttons[action] = gp_btn

		list.add_child(row)

	container.add_child(_make_back_btn())

func _show_startup_apps() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "startup"

	container.add_child(_make_title("STARTUP APPS"))

	var hint := Label.new()
	hint.text = "Apps launched when the compositor starts."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	container.add_child(scroll)

	var apps: Array = _settings.get("startup_apps", [])
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

			var launch_btn := _make_btn("Launch")
			launch_btn.custom_minimum_size = Vector2(100, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(_launch_app.bind(app))
			row.add_child(launch_btn)

			var edit_btn := _make_btn("Edit", "success-button")
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_startup_app.bind(i))
			row.add_child(edit_btn)

			var remove_btn := _make_btn("Remove", "remove-button")
			remove_btn.custom_minimum_size = Vector2(100, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_startup_app.bind(app))
			row.add_child(remove_btn)

			list.add_child(row)

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := _make_line_edit()
	if _editing_index >= 0 and _editing_index < apps.size():
		le.text = String(apps[_editing_index])
		le.placeholder_text = "edit command"
	else:
		le.placeholder_text = "command (ex: firefox, konsole)"
	le.text_submitted.connect(func(text: String):
		_add_startup_app(text.strip_edges())
	)
	add_row.add_child(le)
	var add_btn := _make_btn("Save" if _editing_index >= 0 and _editing_index < apps.size() else "Add")
	add_btn.custom_minimum_size = Vector2(90, 36)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_btn.pressed.connect(_add_from_line_edit.bind(le))
	add_row.add_child(add_btn)
	container.add_child(add_row)

	container.add_child(_make_back_btn())

func _show_custom_binds() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "custom"
	_custom_key_waiting = false
	var binds: Array = _settings.get("custom_binds", [])
	if _editing_index >= 0 and _editing_index < binds.size():
		var edit_bind: Dictionary = binds[_editing_index]
		_custom_is_mouse = String(edit_bind.get("type", "key")) == "mouse"
		_custom_keycode = int(edit_bind.get("code", 0))
		_custom_mods = edit_bind.get("mods", {})
	else:
		_editing_index = -1
		_custom_keycode = 0
		_custom_is_mouse = false
		_custom_mods = {}

	container.add_child(_make_title("CUSTOM BINDS"))

	var hint := Label.new()
	hint.text = "A key launches a command.\nHold Ctrl/Shift/Alt/Super for keyboard modifiers."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	container.add_child(scroll)

	if binds.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no custom binds)"
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_font_size_override("font_size", 13)
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
		list.add_child(empty_label)
	else:
		for i in binds.size():
			var bind: Dictionary = binds[i]
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

			var label := Label.new()
			label.text = _custom_bind_text(bind)
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			label.add_theme_font_size_override("font_size", 14)
			label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
			row.add_child(label)

			var launch_btn := _make_btn("Launch")
			launch_btn.custom_minimum_size = Vector2(100, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(_launch_app.bind(String(bind.get("command", ""))))
			row.add_child(launch_btn)

			var edit_btn := _make_btn("Edit", "success-button")
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_custom_bind.bind(i))
			row.add_child(edit_btn)

			var remove_btn := _make_btn("Remove", "remove-button")
			remove_btn.custom_minimum_size = Vector2(90, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_custom_bind.bind(i))
			row.add_child(remove_btn)

			list.add_child(row)

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_custom_key_btn = _make_btn(_custom_key_label())
	_custom_key_btn.custom_minimum_size = Vector2(110, 36)
	_custom_key_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_custom_key_btn.pressed.connect(_start_custom_key_capture)
	add_row.add_child(_custom_key_btn)

	_custom_cmd_edit = _make_line_edit()
	_custom_cmd_edit.placeholder_text = "command to launch"
	if _editing_index >= 0 and _editing_index < binds.size():
		_custom_cmd_edit.text = String(binds[_editing_index].get("command", ""))
	_custom_cmd_edit.text_submitted.connect(func(_t: String):
		_add_custom_bind()
	)
	add_row.add_child(_custom_cmd_edit)

	var add_btn := _make_btn("Save" if _editing_index >= 0 else "Add")
	add_btn.custom_minimum_size = Vector2(80, 36)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_btn.pressed.connect(_add_custom_bind)
	add_row.add_child(add_btn)

	container.add_child(add_row)

	container.add_child(_make_back_btn())

# ── Keyboard layout ─────────────────────────────────────────────────

func _show_keyboard_layout() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "keyboard_layout"

	container.add_child(_make_title("KEYBOARD LAYOUT"))

	var hint := Label.new()
	hint.text = "Layout sent to the Wayland apps in the game (same as setxkbmap)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

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
	container.add_child(opt)

	opt.item_selected.connect(func(_idx: int):
		_apply_keyboard_layout(opt)
	)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_keyboard_layout(opt: OptionButton) -> void:
	var idx := opt.selected
	if idx < 0 or idx >= KEYBOARD_LAYOUTS.size():
		return
	var entry: Dictionary = KEYBOARD_LAYOUTS[idx]
	var layout := String(entry.get("layout", ""))
	var variant := String(entry.get("variant", ""))
	_settings["keyboard_layout"] = layout
	_settings["keyboard_variant"] = variant
	_save_settings()
	keyboard_layout_changed.emit(layout, variant)

func _current_keyboard_layout() -> Dictionary:
	return get_keyboard_layout()

func get_keyboard_layout() -> Dictionary:
	return {
		"layout": String(_settings.get("keyboard_layout", "fr")),
		"variant": String(_settings.get("keyboard_variant", "")),
	}

# ── Polkit agent ────────────────────────────────────────────────────

func get_polkit_agent() -> String:
	return String(_settings.get("polkit_agent", ""))

func _show_polkit() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "polkit"

	container.add_child(_make_title("POLKIT AGENT"))

	var hint := Label.new()
	hint.text = "Path to the polkit authentication agent.\nEmpty: auto-detect (KDE agent).\n\nThe game stops plasma-polkit-agent while it runs\nand restores it on exit."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var line_edit := _make_line_edit()
	line_edit.text = get_polkit_agent()
	line_edit.placeholder_text = "/usr/lib/polkit-kde-authentication-agent-1"
	line_edit.text_submitted.connect(func(_t: String):
		_apply_polkit_agent(line_edit)
	)
	line_edit.focus_exited.connect(func():
		_apply_polkit_agent(line_edit)
	)
	container.add_child(line_edit)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_polkit_agent(line_edit: LineEdit) -> void:
	var cmd := line_edit.text.strip_edges()
	if cmd == get_polkit_agent():
		return
	_settings["polkit_agent"] = cmd
	_save_settings()
	polkit_agent_changed.emit(cmd)

# ── Screenshot folder ───────────────────────────────────────────────

# Dossier où sont enregistrées les captures (bind impr. écran + menu fenêtre).
# Réglage utilisateur s'il existe, sinon le dossier Pictures de la session
# ($(xdg-user-dir PICTURES)), sinon ~/Pictures en dernier recours.
func get_screenshot_folder() -> String:
	var saved := String(_settings.get("screenshot_folder", "")).strip_edges()
	if saved != "":
		return saved
	return _default_screenshot_folder()

func _default_screenshot_folder() -> String:
	var out: Array = []
	if OS.execute("xdg-user-dir", ["PICTURES"], out) == 0 \
			and not String(out[0]).strip_edges().is_empty():
		return String(out[0]).strip_edges()
	return OS.get_environment("HOME") + "/Pictures"

func _show_screenshots() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "screenshots"

	container.add_child(_make_title("SCREENSHOT FOLDER"))

	var hint := Label.new()
	hint.text = "Folder where screenshots are saved\n(screen keybind + window menu button)."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var line_edit := _make_line_edit()
	line_edit.text = get_screenshot_folder()
	line_edit.placeholder_text = "$(xdg-user-dir PICTURES)"
	line_edit.text_submitted.connect(func(_t: String):
		_apply_screenshot_folder(line_edit)
	)
	line_edit.focus_exited.connect(func():
		_apply_screenshot_folder(line_edit)
	)
	container.add_child(line_edit)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_screenshot_folder(line_edit: LineEdit) -> void:
	var folder := line_edit.text.strip_edges()
	if folder == get_screenshot_folder():
		return
	_settings["screenshot_folder"] = folder
	_save_settings()

# ── Pinned windows layer ─────────────────────────────────────────────

func get_pins_above_focus() -> bool:
	return bool(_settings.get("pins_above_focus", false))

# Pourcentage de transparence de la fenêtre épinglée (0 = opaque, 100 = invisible).
func get_pins_opacity() -> int:
	return clampi(int(_settings.get("pins_opacity", 0)), 0, 100)

# Emplacements possibles de la fenêtre épinglée.
const PIN_POSITIONS := [
	{ "id": "top_left", "label": "Top Left" },
	{ "id": "top_right", "label": "Top Right" },
	{ "id": "bottom_left", "label": "Bottom Left" },
	{ "id": "bottom_right", "label": "Bottom Right" },
]

func get_pins_position() -> String:
	var pos := String(_settings.get("pins_position", "top_left"))
	for entry in PIN_POSITIONS:
		if String(entry.get("id", "")) == pos:
			return pos
	return "top_left"

# Taille de la fenêtre épinglée : viewport / diviseur. Diviseur plus petit =
# pin plus grand. Les bornes du slider sont les MÊMES que celles du clamp dans
# pinned_windows.gd (duplicate plutôt que const partagée : les deux scripts
# ne se préchargent pas l'un l'autre, et un test vérifie qu'elles concordent).
const PIN_SIZE_DIVISOR_MIN := 2.0
const PIN_SIZE_DIVISOR_MAX := 4.0
const PIN_SIZE_DIVISOR_STEP := 0.1

func get_pins_size_divisor() -> float:
	var d = _settings.get("pins_size_divisor", 3.0)
	if not (d is float or d is int):
		return 3.0
	return clampf(float(d), PIN_SIZE_DIVISOR_MIN, PIN_SIZE_DIVISOR_MAX)

func get_aa_mode() -> String:
	return _settings.get("aa_mode", "off")

func get_mouse_sens_mult() -> float:
	return _settings.get("mouse_sens_mult", 1.0)

func get_pad_look_sens_mult() -> float:
	return _settings.get("pad_look_sens_mult", 1.0)

func get_focus_stick_sens_mult() -> float:
	return _settings.get("focus_stick_sens_mult", 1.0)

func is_gyro_aim_enabled() -> bool:
	return bool(_settings.get("gyro_aim_enabled", false))

func get_gyro_sens_mult() -> float:
	return _settings.get("gyro_sens_mult", 1.0)

func get_fps_limit() -> int:
	return _settings.get("fps_limit", 60)

# Collage des fenêtres coupé ? (GENERAL). Absent du réglage = collage actif :
# un défaut inversé le désactiverait pour tout le monde, en silence.
func is_snapping_disabled() -> bool:
	return bool(_settings.get("snapping_disabled", false))

# toggle_ui masque-t-il aussi les noms des joueurs ? (GENERAL). Défaut : non.
func does_toggle_ui_hide_names() -> bool:
	return bool(_settings.get("toggle_ui_hides_names", false))

# Full body awareness : corps du joueur visible en 1ère personne ? (GENERAL). Défaut : oui.
func is_fullbody_enabled() -> bool:
	return bool(_settings.get("fullbody_awareness", true))

func _show_pins() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "pins"

	container.add_child(_make_title("PINNED WINDOWS"))

	var hint := Label.new()
	hint.text = "Settings for the pinned (PiP) window."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	var layer_label := Label.new()
	layer_label.text = "Layer (relative to the focus mode overlay)"
	layer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer_label.add_theme_font_size_override("font_size", 13)
	layer_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(layer_label)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0, 40)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 14)
	opt.add_item("Below the focus layer")
	opt.add_item("Above the focus layer")
	opt.selected = 1 if get_pins_above_focus() else 0
	container.add_child(opt)

	var pos_label := Label.new()
	pos_label.text = "Position"
	pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pos_label.add_theme_font_size_override("font_size", 13)
	pos_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(pos_label)

	var pos_opt := OptionButton.new()
	pos_opt.custom_minimum_size = Vector2(0, 40)
	pos_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pos_opt.add_theme_font_size_override("font_size", 14)
	var cur_pos := get_pins_position()
	for i in PIN_POSITIONS.size():
		var entry: Dictionary = PIN_POSITIONS[i]
		pos_opt.add_item(String(entry.get("label", "")), i)
		if String(entry.get("id", "")) == cur_pos:
			pos_opt.selected = i
	container.add_child(pos_opt)

	var transp_label := Label.new()
	transp_label.text = "Transparency"
	transp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	transp_label.add_theme_font_size_override("font_size", 13)
	transp_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(transp_label)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = get_pins_opacity()
	slider.custom_minimum_size = Vector2(0, 30)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(slider)

	var slider_val := Label.new()
	slider_val.text = "%d%%" % get_pins_opacity()
	slider_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slider_val.add_theme_font_size_override("font_size", 13)
	slider_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(slider_val)

	slider.value_changed.connect(func(value: float):
		slider_val.text = "%d%%" % int(value)
	)

	var size_label := Label.new()
	size_label.text = "Size (viewport ÷ %.1f)" % PIN_SIZE_DIVISOR_MIN
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_label.add_theme_font_size_override("font_size", 13)
	size_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(size_label)

	var size_slider := HSlider.new()
	size_slider.min_value = PIN_SIZE_DIVISOR_MIN
	size_slider.max_value = PIN_SIZE_DIVISOR_MAX
	size_slider.step = PIN_SIZE_DIVISOR_STEP
	size_slider.value = get_pins_size_divisor()
	size_slider.custom_minimum_size = Vector2(0, 30)
	size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(size_slider)

	# Le diviseur seul ne dit rien à l'écran : on montre la taille qu'il
	# produit, sinon impossible de savoir si l'on agrandit ou réduit le pin.
	var size_val := Label.new()
	size_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	size_val.add_theme_font_size_override("font_size", 13)
	size_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(size_val)

	var _refresh_size := func(value: float) -> void:
		var vp := get_viewport().get_visible_rect().size
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

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_pins_settings(opt: OptionButton, pos_opt: OptionButton, slider: HSlider,
		size_slider: HSlider) -> void:
	var above := opt.selected == 1
	var percent: int = clampi(int(slider.value), 0, 100)
	var pos := "top_left"
	if pos_opt.selected >= 0 and pos_opt.selected < PIN_POSITIONS.size():
		pos = String(PIN_POSITIONS[pos_opt.selected].get("id", "top_left"))
	var divisor := clampf(snappedf(size_slider.value, PIN_SIZE_DIVISOR_STEP),
		PIN_SIZE_DIVISOR_MIN, PIN_SIZE_DIVISOR_MAX)
	var old_above := get_pins_above_focus()
	var old_percent := get_pins_opacity()
	var old_pos := get_pins_position()
	var old_divisor := get_pins_size_divisor()
	_settings["pins_above_focus"] = above
	_settings["pins_opacity"] = percent
	_settings["pins_position"] = pos
	_settings["pins_size_divisor"] = divisor
	_save_settings()
	# N'émet que ce qui a réellement changé (les curseurs appellent ceci à chaque cran).
	if above != old_above:
		pins_layer_changed.emit(above)
	if percent != old_percent:
		pins_opacity_changed.emit(percent)
	if pos != old_pos:
		pins_position_changed.emit(pos)
	if not is_equal_approx(divisor, old_divisor):
		pins_size_divisor_changed.emit(divisor)

# ── LAN multiplayer ──────────────────────────────────────────────────

func get_tutorial_seen() -> bool:
	return bool(_settings.get("tutorial_seen", false))

func set_tutorial_seen(val: bool) -> void:
	if bool(_settings.get("tutorial_seen", false)) == val:
		return
	_settings["tutorial_seen"] = val
	_save_settings()

func get_lan_player_name() -> String:
	var nm := String(_settings.get("lan_player_name", "")).strip_edges()
	if nm == "":
		return OS.get_environment("USER")
	return nm

func get_lan_avatar_path() -> String:
	return String(_settings.get("lan_avatar_path", ""))

# Couleur d'accentuation : hex "#rrggbb" ; repli sur le défaut si illisible.
func get_accent_color() -> Color:
	var s := String(_settings.get("accent_color", "")).strip_edges()
	if s == "":
		return UITheme.DEFAULT_ACCENT
	if not s.begins_with("#"):
		s = "#" + s
	var c := Color.from_string(s, UITheme.DEFAULT_ACCENT)
	c.a = 1.0
	return c

# Thème clair/sombre annoncé aux applications ; sombre par défaut (ambiance du jeu).
func get_color_scheme() -> String:
	return "light" if String(_settings.get("color_scheme", "dark")) == "light" else "dark"

func _set_accent_color(c: Color) -> void:
	c.a = 1.0
	_settings["accent_color"] = c.to_html(false)
	_save_settings()
	UITheme.set_accent_color(c)
	accent_color_changed.emit(c)

func get_lan_player_color() -> Color:
	var fallback := Color(0.2, 0.6, 1.0)
	var v = _settings.get("lan_player_color", fallback)
	if v is Color:
		return v
	if v is String:
		var s := (v as String).strip_edges()
		# Nouveau format : hex "#rrggbbaa". NB : en Godot 4 Color.to_html()
		# renvoie l'hex SANS '#' ("rrggbbaa") → accepter aussi ce format.
		if s.begins_with("#"):
			return Color.from_string(s, fallback)
		if s.length() == 6 or s.length() == 8:
			return Color.from_string("#" + s, fallback)
		# Ancien format (Color stringifié par JSON) : "(r, g, b, a)".
		if s.begins_with("(") and s.ends_with(")"):
			var parts := s.substr(1, s.length() - 2).split(",")
			if parts.size() >= 3:
				return Color(
					parts[0].strip_edges().to_float(),
					parts[1].strip_edges().to_float(),
					parts[2].strip_edges().to_float(),
					1.0 if parts.size() < 4 else parts[3].strip_edges().to_float())
	return fallback

func _save_lan_name(edit: LineEdit) -> void:
	var nm := edit.text.strip_edges()
	if nm == "":
		nm = OS.get_environment("USER")
		edit.text = nm
	_settings["lan_player_name"] = nm
	_save_settings()
	lan_name_changed.emit(nm)

# Apparence des applications : couleur d'accentuation + thème clair/sombre, en
# deux lignes compactes. Appliqués
# immédiatement et publiés aux apps via le portail Settings.
func _add_appearance_rows() -> void:
	var accent_row := HBoxContainer.new()
	accent_row.add_theme_constant_override("separation", 8)
	container.add_child(accent_row)
	accent_row.add_child(_make_row_label("Accent color"))

	var accent_btn := ColorPickerButton.new()
	accent_btn.focus_mode = Control.FOCUS_ALL
	accent_btn.edit_alpha = false
	accent_btn.color = get_accent_color()
	accent_btn.custom_minimum_size = Vector2(64, 30)
	accent_row.add_child(accent_btn)
	accent_btn.color_changed.connect(_set_accent_color)

	var accent_reset := _make_btn("Reset", "action-button")
	accent_reset.custom_minimum_size = Vector2(0, 30)
	accent_reset.size_flags_horizontal = Control.SIZE_SHRINK_END
	accent_reset.pressed.connect(func():
		accent_btn.color = UITheme.DEFAULT_ACCENT
		_set_accent_color(UITheme.DEFAULT_ACCENT)
	)
	accent_row.add_child(accent_reset)

	var scheme_row := HBoxContainer.new()
	scheme_row.add_theme_constant_override("separation", 8)
	container.add_child(scheme_row)
	scheme_row.add_child(_make_row_label("App theme"))

	var scheme_opt := OptionButton.new()
	scheme_opt.add_item("Dark")
	scheme_opt.add_item("Light")
	scheme_opt.selected = 1 if get_color_scheme() == "light" else 0
	scheme_opt.custom_minimum_size = Vector2(0, 32)
	scheme_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scheme_row.add_child(scheme_opt)
	scheme_opt.item_selected.connect(func(i: int):
		var v := "light" if i == 1 else "dark"
		_settings["color_scheme"] = v
		_save_settings()
		color_scheme_changed.emit(v)
	)

func _make_row_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(110, 0)
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	return lbl

func _show_graphics_general() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "graphics_general"

	container.add_child(_make_title("GRAPHICS — GENERAL"))

	# ── Antialiasing ──
	var aa_label := Label.new()
	aa_label.text = "Antialiasing"
	aa_label.add_theme_font_size_override("font_size", 14)
	aa_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(aa_label)

	var aa_opt := OptionButton.new()
	aa_opt.add_item("Off", 0)       # index 0 → "off"
	aa_opt.add_item("FXAA", 1)      # index 1 → "fxaa"
	aa_opt.add_item("MSAA 2x", 2)   # index 2 → "msaa_2x"
	aa_opt.add_item("MSAA 4x", 3)   # index 3 → "msaa_4x"
	aa_opt.add_item("MSAA 8x", 4)   # index 4 → "msaa_8x"
	aa_opt.custom_minimum_size = Vector2(0, 36)
	aa_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	aa_opt.add_theme_font_size_override("font_size", 14)
	var current_aa := get_aa_mode()
	match current_aa:
		"fxaa": aa_opt.selected = 1
		"msaa_2x": aa_opt.selected = 2
		"msaa_4x": aa_opt.selected = 3
		"msaa_8x": aa_opt.selected = 4
		_: aa_opt.selected = 0
	container.add_child(aa_opt)

	# ── Environment (WorldEnvironment du niveau courant) ──
	container.add_child(_make_section("Effects"))

	var env_btns := {}
	for pair in ENVIRONMENT_TOGGLES:
		var env_btn := CheckButton.new()
		env_btn.text = String(pair[1])
		env_btn.button_pressed = bool(_env_default(String(pair[0]), false))
		env_btn.custom_minimum_size = Vector2(0, 36)
		env_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		env_btn.add_theme_font_size_override("font_size", 14)
		container.add_child(env_btn)
		env_btns[String(pair[0])] = env_btn

	container.add_child(_make_section("Color Adjustments"))

	var brightness_s := _make_env_slider("Brightness", "adjustment_brightness")
	var contrast_s := _make_env_slider("Contrast", "adjustment_contrast")
	var saturation_s := _make_env_slider("Saturation", "adjustment_saturation")

	# ── Auto-apply ──
	var auto_apply := func(_v = null) -> void:
		_apply_graphics(aa_opt, env_btns, brightness_s, contrast_s, saturation_s)
	aa_opt.item_selected.connect(auto_apply)
	for key in env_btns:
		(env_btns[key] as CheckButton).toggled.connect(auto_apply)
	brightness_s.value_changed.connect(auto_apply)
	contrast_s.value_changed.connect(auto_apply)
	saturation_s.value_changed.connect(auto_apply)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _show_controls_general() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "controls_general"

	container.add_child(_make_title("CONTROLS — GENERAL"))

	# ── Mouse sensitivity ──
	var mouse_label := Label.new()
	mouse_label.text = "Mouse Sensitivity"
	mouse_label.add_theme_font_size_override("font_size", 14)
	mouse_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(mouse_label)

	var mouse_slider := HSlider.new()
	mouse_slider.min_value = 0.5
	mouse_slider.max_value = 3.0
	mouse_slider.step = 0.1
	mouse_slider.value = get_mouse_sens_mult()
	mouse_slider.custom_minimum_size = Vector2(0, 30)
	mouse_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(mouse_slider)

	var mouse_val := Label.new()
	mouse_val.text = "%.1fx" % mouse_slider.value
	mouse_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mouse_val.add_theme_font_size_override("font_size", 13)
	mouse_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(mouse_val)

	mouse_slider.value_changed.connect(func(v: float):
		mouse_val.text = "%.1fx" % v
	)

	# ── Right stick sensitivity ──
	var pad_label := Label.new()
	pad_label.text = "Right Stick Sensitivity"
	pad_label.add_theme_font_size_override("font_size", 14)
	pad_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(pad_label)

	var pad_slider := HSlider.new()
	pad_slider.min_value = 0.5
	pad_slider.max_value = 3.0
	pad_slider.step = 0.1
	pad_slider.value = get_pad_look_sens_mult()
	pad_slider.custom_minimum_size = Vector2(0, 30)
	pad_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(pad_slider)

	var pad_val := Label.new()
	pad_val.text = "%.1fx" % pad_slider.value
	pad_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pad_val.add_theme_font_size_override("font_size", 13)
	pad_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(pad_val)

	pad_slider.value_changed.connect(func(v: float):
		pad_val.text = "%.1fx" % v
	)

	# ── Gyroscope aim ──

	var gyro_check := CheckButton.new()
	gyro_check.text = "Gyroscope Aim"
	gyro_check.button_pressed = is_gyro_aim_enabled()
	gyro_check.custom_minimum_size = Vector2(0, 36)
	gyro_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gyro_check.add_theme_font_size_override("font_size", 14)
	container.add_child(gyro_check)

	var gyro_label := Label.new()
	gyro_label.text = "Gyro Sensitivity"
	gyro_label.add_theme_font_size_override("font_size", 14)
	gyro_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(gyro_label)

	var gyro_slider := HSlider.new()
	gyro_slider.min_value = 0.1
	gyro_slider.max_value = 2.0
	gyro_slider.step = 0.1
	gyro_slider.value = get_gyro_sens_mult()
	gyro_slider.custom_minimum_size = Vector2(0, 30)
	gyro_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(gyro_slider)

	var gyro_val := Label.new()
	gyro_val.text = "%.1fx" % gyro_slider.value
	gyro_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gyro_val.add_theme_font_size_override("font_size", 13)
	gyro_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(gyro_val)

	gyro_slider.value_changed.connect(func(v: float):
		gyro_val.text = "%.1fx" % v
	)

	# ── Focus mode stick sensitivity ──
	var focus_label := Label.new()
	focus_label.text = "Focus Mode Stick Sensitivity"
	focus_label.add_theme_font_size_override("font_size", 14)
	focus_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	container.add_child(focus_label)

	var focus_slider := HSlider.new()
	focus_slider.min_value = 0.5
	focus_slider.max_value = 3.0
	focus_slider.step = 0.1
	focus_slider.value = get_focus_stick_sens_mult()
	focus_slider.custom_minimum_size = Vector2(0, 30)
	focus_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(focus_slider)

	var focus_val := Label.new()
	focus_val.text = "%.1fx" % focus_slider.value
	focus_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	focus_val.add_theme_font_size_override("font_size", 13)
	focus_val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(focus_val)

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

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

const AA_MODES := ["off", "fxaa", "msaa_2x", "msaa_4x", "msaa_8x"]

func _apply_aa(mode: String) -> void:
	var vp := get_viewport()
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

	_settings["aa_mode"] = aa_mode
	_save_settings()

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
	_settings["environment"] = env
	_save_settings()
	environment_settings_changed.emit(env)

func _apply_controls(mouse_s: HSlider, pad_s: HSlider, focus_s: HSlider, gyro_btn: CheckButton, gyro_s: HSlider) -> void:
	var mouse_mult: float = mouse_s.value
	var pad_mult: float = pad_s.value
	var focus_mult: float = focus_s.value
	var gyro_enabled: bool = gyro_btn.button_pressed
	var gyro_mult: float = gyro_s.value

	var old_mouse := get_mouse_sens_mult()
	var old_pad := get_pad_look_sens_mult()
	var old_focus := get_focus_stick_sens_mult()
	var old_gyro_on := is_gyro_aim_enabled()
	var old_gyro := get_gyro_sens_mult()

	_settings["mouse_sens_mult"] = mouse_mult
	_settings["pad_look_sens_mult"] = pad_mult
	_settings["focus_stick_sens_mult"] = focus_mult
	_settings["gyro_aim_enabled"] = gyro_enabled
	_settings["gyro_sens_mult"] = gyro_mult
	_save_settings()

	# N'émet que ce qui a réellement changé (appelé à chaque cran de curseur).
	if not is_equal_approx(mouse_mult, old_mouse):
		mouse_sens_changed.emit(mouse_mult)
	if not is_equal_approx(pad_mult, old_pad):
		pad_look_sens_changed.emit(pad_mult)
	if not is_equal_approx(focus_mult, old_focus):
		focus_stick_sens_changed.emit(focus_mult)
	if gyro_enabled != old_gyro_on:
		gyro_aim_changed.emit(gyro_enabled)
	if not is_equal_approx(gyro_mult, old_gyro):
		gyro_sens_changed.emit(gyro_mult)

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

# Réglages environnement persistés (dictionnaire appliqué aux niveaux).
func get_environment_settings() -> Dictionary:
	return (_settings.get("environment", {}) as Dictionary).duplicate()

# Valeur d'un réglage d'environnement : la valeur persistée si présente,
# sinon l'état actuel du WorldEnvironment du niveau (le menu reflète ce qui
# s'affiche réellement), sinon le fallback passé.
func _env_default(key: String, fallback: Variant) -> Variant:
	var env: Dictionary = _settings.get("environment", {})
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
	container.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 2.0
	slider.step = 0.05
	slider.value = float(_env_default(key, 1.0))
	slider.custom_minimum_size = Vector2(0, 30)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(slider)
	var val := Label.new()
	val.text = "%.2f" % slider.value
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(val)
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

# ── Worlds : choix du niveau (environnement) ─────────────────────────
# Liste le niveau par défaut et tous les level.tscn de res://user/. Le choix
# est appliqué à chaud et persisté (rechargé au prochain démarrage). Verrouillé
# pendant une session multijoueur : seul le niveau sélectionné au moment
# d'héberger est baké et envoyé, il ne change pas en cours de partie.
func _show_levels() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "levels"

	container.add_child(_make_title("WORLDS"))

	var locked := _lan_connected
	var loading := _level_room != null and bool(_level_room.call("is_level_loading"))
	var current := String(_level_room.call("get_current_level_path")) if _level_room != null else ""

	var hint := Label.new()
	if locked:
		hint.text = "Locked during a multiplayer session: everyone plays the level\nselected when the game was hosted. Disconnect to change it."
	else:
		hint.text = "Pick the environment to play in. The choice is remembered.\nIn multiplayer, only the selected level is sent to other players."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	for lv in LevelCatalogScript.list_levels():
		var path := String(lv["path"])
		var is_current := path == current
		var btn := _make_btn(String(lv["name"]) + ("   — current" if is_current else ""), "nav-row")
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.tooltip_text = path
		btn.disabled = locked or loading or is_current
		btn.pressed.connect(func():
			if _lan_connected:
				_show_levels()
				return
			set_level_status("Loading %s…" % String(lv["name"]))
			level_change_requested.emit(path)
		)
		container.add_child(btn)

	_level_status_label = Label.new()
	_level_status_label.text = _level_status_text
	_level_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_level_status_label.add_theme_font_size_override("font_size", 13)
	_level_status_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(_level_status_label)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func set_level_status(text: String) -> void:
	_level_status_text = text
	if _level_status_label != null and is_instance_valid(_level_status_label):
		_level_status_label.text = text

## Appelé par WaylandRoom une fois le nouveau niveau appliqué : persiste le
## choix et rafraîchit la page si elle est ouverte.
func on_level_changed(path: String) -> void:
	_settings[LevelCatalogScript.SETTING_KEY] = path
	_save_settings()
	set_level_status("%s loaded." % LevelCatalogScript.display_name(path))
	_refresh_header()
	if visible and _current_view == "levels":
		_show_levels()

func _show_lan() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "lan"

	container.add_child(_make_title("MULTIPLAYER"))

	var hint := Label.new()
	if _lan_connected:
		hint.text = "Connected — changes are broadcast to other players automatically."
	else:
		hint.text = "Multiplayer on your local network (2-4 players).\nEach player keeps their own desktop; you see each other's avatar."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

	container.add_child(_make_section("Session"))
	var host_btn := _make_btn("Host Game")
	host_btn.pressed.connect(func():
		lan_host_requested.emit()
	)
	container.add_child(host_btn)

	# PIN label (visible when hosting — shows the generated PIN) + bouton 👁
	# pour le masquer à l'écran sans l'oublier (état persistant dans le membre).
	var pin_row := HBoxContainer.new()
	pin_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pin_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_lan_pin_label = Label.new()
	_lan_pin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_lan_pin_label.add_theme_font_size_override("font_size", 16)
	_lan_pin_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_lan_pin_label.visible = false
	pin_row.add_child(_lan_pin_label)
	_lan_pin_toggle_btn = Button.new()
	_lan_pin_toggle_btn.text = "👁"
	_lan_pin_toggle_btn.flat = true
	_lan_pin_toggle_btn.tooltip_text = "Mask / show the session PIN"
	_lan_pin_toggle_btn.visible = false
	_lan_pin_toggle_btn.pressed.connect(_toggle_lan_pin_visibility)
	pin_row.add_child(_lan_pin_toggle_btn)
	container.add_child(pin_row)
	# Le PIN vit dans le lan_manager : on le restaure après un rebuild de l'UI
	# (BACK → retour dans le menu LAN) au lieu de le perdre.
	if _lan != null and bool(_lan.get("is_host")) and String(_lan.get_pin()) != "":
		set_lan_pin(String(_lan.get_pin()))

	var join_row := HBoxContainer.new()
	join_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_ip_edit = _make_line_edit()
	_lan_ip_edit.placeholder_text = "Host IP or name (ex: 192.168.1.5 / play.example.org)"
	join_row.add_child(_lan_ip_edit)
	_lan_pin_edit = _make_line_edit()
	_lan_pin_edit.placeholder_text = "PIN / password"
	_lan_pin_edit.custom_minimum_size = Vector2(150, 36)
	_lan_pin_edit.secret = true
	_lan_pin_edit.max_length = 64          # PIN (4 chiffres) en LAN, mot de passe long pour un serveur en ligne
	join_row.add_child(_lan_pin_edit)
	_lan_encryption_btn = CheckButton.new()
	_lan_encryption_btn.text = "TLS"
	_lan_encryption_btn.tooltip_text = "Encrypt the session (DTLS) with the embedded certificates"
	_lan_encryption_btn.button_pressed = true
	join_row.add_child(_lan_encryption_btn)
	var join_btn := _make_btn("Join")
	join_btn.custom_minimum_size = Vector2(100, 36)
	join_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	join_btn.pressed.connect(func():
		var ip := _lan_ip_edit.text.strip_edges()
		var pin := _lan_pin_edit.text.strip_edges()
		if ip != "":
			lan_join_requested.emit(ip, pin, _lan_encryption_btn.button_pressed)
	)
	join_row.add_child(join_btn)
	container.add_child(join_row)

	var find_btn := _make_btn("Find LAN games")
	find_btn.pressed.connect(func():
		lan_discover_requested.emit()
	)
	container.add_child(find_btn)

	_lan_results_box = VBoxContainer.new()
	_lan_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_results_box.add_theme_constant_override("separation", 4)
	container.add_child(_lan_results_box)
	
	_lan_status_label = Label.new()
	_lan_status_label.text = _lan_status_text
	_lan_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_status_label.add_theme_font_size_override("font_size", 13)
	_lan_status_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(_lan_status_label)

	_lan_players_label = Label.new()
	_lan_players_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_players_label.add_theme_font_size_override("font_size", 13)
	_lan_players_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(_lan_players_label)
	_update_lan_players_label()
	
	container.add_child(_make_section("Video share"))

	var codec_row := HBoxContainer.new()
	codec_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var codec_label := Label.new()
	codec_label.text = "Codec"
	codec_label.custom_minimum_size = Vector2(90, 36)
	codec_row.add_child(codec_label)
	var codec_opt := OptionButton.new()
	codec_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	codec_opt.add_item("Auto (h264, av1)")
	codec_opt.add_item("H.264")
	codec_opt.add_item("AV1")
	codec_opt.select(0)
	codec_opt.tooltip_text = "H.264 VAAPI is the most reliable; AV1 is hardware only (may be slow/unstable depending on the GPU)"
	codec_row.add_child(codec_opt)
	container.add_child(codec_row)

	var bitrate_row := HBoxContainer.new()
	bitrate_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bitrate_label := Label.new()
	bitrate_label.text = "Bitrate (Mb/s)"
	bitrate_label.custom_minimum_size = Vector2(90, 36)
	bitrate_row.add_child(bitrate_label)
	var bitrate_spin := SpinBox.new()
	bitrate_spin.min_value = 1.0
	bitrate_spin.max_value = 20.0
	bitrate_spin.step = 1.0
	bitrate_spin.value = 6.0
	bitrate_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bitrate_spin.tooltip_text = "Target bitrate per shared window (bits/s ÷ 1e6). Raise it on fast wired LAN for less compression"
	bitrate_row.add_child(bitrate_spin)
	container.add_child(bitrate_row)

	var fps_row := HBoxContainer.new()
	fps_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fps_label := Label.new()
	fps_label.text = "FPS"
	fps_label.custom_minimum_size = Vector2(90, 36)
	fps_row.add_child(fps_label)
	var fps_spin := SpinBox.new()
	fps_spin.min_value = 10.0
	fps_spin.max_value = 60.0
	fps_spin.step = 1.0
	fps_spin.value = 60.0
	fps_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_spin.tooltip_text = "Encoding framerate (10-60). 30 halves the CPU load"
	fps_row.add_child(fps_spin)
	container.add_child(fps_row)

	var emit_video := func() -> void:
		var codec := "auto"
		if codec_opt.selected == 1:
			codec = "h264"
		elif codec_opt.selected == 2:
			codec = "av1"
		lan_video_settings_changed.emit(int(bitrate_spin.value) * 1_000_000, codec, int(fps_spin.value))
	codec_opt.item_selected.connect(func(_i: int): emit_video.call())
	bitrate_spin.value_changed.connect(func(_v: float): emit_video.call())
	fps_spin.value_changed.connect(func(_v: float): emit_video.call())

	container.add_child(_make_spacer())
	
	var disconnect_btn := _make_btn("Disconnect", "warning-button")
	disconnect_btn.pressed.connect(func():
		lan_disconnect_requested.emit()
	)
	disconnect_btn.visible = _lan_connected
	container.add_child(disconnect_btn)
	_lan_disconnect_btn = disconnect_btn

	container.add_child(_make_back_btn())

func set_lan_status(text: String) -> void:
	_lan_status_text = text
	if _lan_status_label:
		_lan_status_label.text = text
	_refresh_header()

func set_lan_players(roster: Array) -> void:
	_lan_roster = roster
	_update_lan_players_label()
	_refresh_header()

func set_lan_connected(connected: bool) -> void:
	var changed := connected != _lan_connected
	_lan_connected = connected
	# Page Worlds ouverte : (dé)verrouiller la liste dès que la session change.
	if changed and visible and _current_view == "levels":
		_show_levels.call_deferred()
	if _lan_disconnect_btn != null and is_instance_valid(_lan_disconnect_btn):
		_lan_disconnect_btn.visible = connected
	_refresh_header()

func set_lan_pin(pin: String) -> void:
	_lan_pin_value = pin
	if _lan_pin_label == null or _lan_pin_toggle_btn == null:
		return
	if pin != "":
		_lan_pin_label.visible = true
		_lan_pin_toggle_btn.visible = true
		_render_lan_pin()
	else:
		_lan_pin_label.visible = false
		_lan_pin_toggle_btn.visible = false

func _toggle_lan_pin_visibility() -> void:
	_lan_pin_visible = not _lan_pin_visible
	_render_lan_pin()

func _render_lan_pin() -> void:
	if _lan_pin_label == null:
		return
	if _lan_pin_visible:
		_lan_pin_label.text = "Session PIN: %s" % _lan_pin_value
	else:
		var masked := ""
		for i in _lan_pin_value.length():
			masked += "• "
		_lan_pin_label.text = "Session PIN: %s" % masked.strip_edges()

func _update_lan_players_label() -> void:
	if _lan_players_label == null:
		return
	if _lan_roster.is_empty():
		_lan_players_label.text = ""
		return
	var parts: PackedStringArray = []
	for p in _lan_roster:
		parts.append("• %s (%d)" % [String(p.get("name", "?")), int(p.get("id", 0))])
	_lan_players_label.text = "Players:\n" + "\n".join(parts)

func set_lan_discovery_results(results: Array) -> void:
	if _current_view != "lan" or _lan_results_box == null:
		return
	for c in _lan_results_box.get_children():
		c.queue_free()
	for r in results:
		var ips: Array = r.get("ips", [])
		var ip := ""
		if ips.size() > 0:
			ip = String(ips[0])
		else:
			ip = String(r.get("ip", ""))
		var btn := _make_btn("%s — %s" % [String(r.get("name", "?")), ip])
		btn.custom_minimum_size = Vector2(0, 34)
		btn.pressed.connect(_join_discovered.bind(ip))
		_lan_results_box.add_child(btn)

func _join_discovered(ip: String) -> void:
	if _lan_ip_edit == null:
		return
	_lan_ip_edit.text = ip
	_lan_pin_edit.text = ""
	_lan_pin_edit.grab_focus()
	set_lan_status("Game selected — enter the host's PIN (shown on the host), then press Join.")

# ── Startup apps ─────────────────────────────────────────────────────

func get_startup_apps() -> Array:
	return _settings.get("startup_apps", [])

func _launch_app(app: String) -> void:
	app_launch_requested.emit(app)

func _add_from_line_edit(le: LineEdit) -> void:
	_add_startup_app(le.text.strip_edges())

func _edit_startup_app(index: int) -> void:
	_editing_index = index
	_show_startup_apps()

func _add_startup_app(cmd: String) -> void:
	if cmd == "":
		return
	var apps: Array = _settings.get("startup_apps", [])
	if _editing_index >= 0 and _editing_index < apps.size():
		# Mode édition : remplace la commande à cet index.
		apps[_editing_index] = cmd
	else:
		if not apps.has(cmd):
			apps.append(cmd)
	_editing_index = -1
	_settings["startup_apps"] = apps
	_save_settings()
	_show_startup_apps()

func _remove_startup_app(cmd: String) -> void:
	var apps: Array = _settings.get("startup_apps", [])
	apps.erase(cmd)
	_settings["startup_apps"] = apps
	_editing_index = -1
	_save_settings()
	_show_startup_apps()

# ── Custom binds ─────────────────────────────────────────────────────

func get_custom_binds() -> Array:
	return _settings.get("custom_binds", [])

func _custom_bind_text(bind: Dictionary) -> String:
	var key_text := ""
	if bind.get("type", "") == "mouse":
		key_text = _mouse_button_name(bind.get("code", 0))
	else:
		key_text = OS.get_keycode_string(bind.get("code", 0))
	var mods := _mods_to_string(bind.get("mods", {}))
	if mods != "":
		key_text = mods + "+" + key_text
	var cmd: String = bind.get("command", "")
	return "%s → %s" % [key_text, cmd]

func _custom_key_label() -> String:
	var key_text := ""
	if _custom_keycode == 0:
		return "Set key"
	if _custom_keycode != 0:
		if _custom_is_mouse:
			key_text = _mouse_button_name(_custom_keycode)
		else:
			key_text = OS.get_keycode_string(_custom_keycode)
		var mods := _mods_to_string(_custom_mods)
		if mods != "":
			key_text = mods + "+" + key_text
	return key_text

func _mods_from_event(event: InputEvent) -> Dictionary:
	if event is InputEventWithModifiers:
		var ev := event as InputEventWithModifiers
		return {
			"ctrl": ev.ctrl_pressed,
			"shift": ev.shift_pressed,
			"alt": ev.alt_pressed,
			"super": ev.meta_pressed,
		}
	return {}

func _mods_to_string(mods: Dictionary) -> String:
	var parts: PackedStringArray = []
	if mods.get("ctrl", false):
		parts.append("Ctrl")
	if mods.get("shift", false):
		parts.append("Shift")
	if mods.get("alt", false):
		parts.append("Alt")
	if mods.get("super", false):
		parts.append("Super")
	return "+".join(parts)

func _event_matches_mods(event: InputEvent, mods: Dictionary) -> bool:
	var ev := event as InputEventWithModifiers
	if ev == null:
		return mods.is_empty()
	return ev.ctrl_pressed == mods.get("ctrl", false) \
		and ev.shift_pressed == mods.get("shift", false) \
		and ev.alt_pressed == mods.get("alt", false) \
		and ev.meta_pressed == mods.get("super", false)

func _start_custom_key_capture() -> void:
	_custom_key_waiting = true
	if _custom_key_btn:
		_custom_key_btn.text = "Press key..."

func _add_custom_bind() -> void:
	if not _custom_cmd_edit or _custom_cmd_edit.text.strip_edges() == "":
		return
	if _custom_keycode == 0:
		return
	var binds: Array = _settings.get("custom_binds", [])
	var entry := {
		"type": "mouse" if _custom_is_mouse else "key",
		"code": _custom_keycode,
		"mods": _custom_mods,
		"command": _custom_cmd_edit.text.strip_edges(),
	}
	if _editing_index >= 0 and _editing_index < binds.size():
		binds[_editing_index] = entry
	else:
		binds.append(entry)
	_settings["custom_binds"] = binds
	_editing_index = -1
	_save_settings()
	_show_custom_binds()

func _edit_custom_bind(index: int) -> void:
	_editing_index = index
	_show_custom_binds()

func _remove_custom_bind(index: int) -> void:
	var binds: Array = _settings.get("custom_binds", [])
	if index >= 0 and index < binds.size():
		binds.remove_at(index)
	_settings["custom_binds"] = binds
	_editing_index = -1
	_save_settings()
	_show_custom_binds()

# ── Keybinds ─────────────────────────────────────────────────────────

func _binding_text(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "None"
	var kb := ""
	for ev in events:
		if kb == "" and (ev is InputEventKey or ev is InputEventMouseButton):
			kb = _kb_event_text(ev)
	if kb == "":
		return "None"
	return kb

func _kb_event_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var kev := ev as InputEventKey
		var code := kev.physical_keycode
		if code == 0:
			code = kev.keycode
		if code == 0:
			return ""
		var text := OS.get_keycode_string(code)
		var mods := _mods_to_string(_mods_from_event(kev))
		return mods + "+" + text if mods != "" else text
	if ev is InputEventMouseButton:
		var text := _mouse_button_name(ev.button_index)
		var mods := _mods_to_string(_mods_from_event(ev))
		return mods + "+" + text if mods != "" else text
	return ""

## Premier binding manette de l'action ("A", "LB", "Left Stick X+", "None"...).
func _gamepad_binding_text(action: String) -> String:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return _joypad_button_name(ev.button_index)
		if ev is InputEventJoypadMotion:
			var mev := ev as InputEventJoypadMotion
			return _joypad_axis_name(mev.axis) + ("+" if mev.axis_value >= 0 else "-")
	return "None"

func _joypad_button_name(btn: int) -> String:
	match btn:
		JOY_BUTTON_A: return "A"
		JOY_BUTTON_B: return "B"
		JOY_BUTTON_X: return "X"
		JOY_BUTTON_Y: return "Y"
		JOY_BUTTON_BACK: return "Select"
		JOY_BUTTON_START: return "Start"
		JOY_BUTTON_DPAD_UP: return "D-Pad Up"
		JOY_BUTTON_DPAD_DOWN: return "D-Pad Down"
		JOY_BUTTON_DPAD_LEFT: return "D-Pad Left"
		JOY_BUTTON_DPAD_RIGHT: return "D-Pad Right"
		JOY_BUTTON_LEFT_STICK: return "L3"
		JOY_BUTTON_RIGHT_STICK: return "R3"
		JOY_BUTTON_LEFT_SHOULDER: return "LB"
		JOY_BUTTON_RIGHT_SHOULDER: return "RB"
		JOY_BUTTON_GUIDE: return "Guide"
	return "Pad %d" % btn

func _joypad_axis_name(axis: int) -> String:
	match axis:
		JOY_AXIS_LEFT_X: return "Left Stick X"
		JOY_AXIS_LEFT_Y: return "Left Stick Y"
		JOY_AXIS_RIGHT_X: return "Right Stick X"
		JOY_AXIS_RIGHT_Y: return "Right Stick Y"
		JOY_AXIS_TRIGGER_LEFT: return "LT"
		JOY_AXIS_TRIGGER_RIGHT: return "RT"
	return "Axis %d" % axis

## Remplace uniquement les événements de la MÊME classe d'entrée : rebinde
## clavier ne détruit plus la liaison pad d'une action, et vice-versa.
func _event_class(ev: InputEvent) -> String:
	if ev is InputEventKey:
		return "key"
	if ev is InputEventMouseButton:
		return "mouse"
	if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
		return "pad"
	return "other"

func _set_action_event(action: String, new_ev: InputEvent) -> void:
	var cls := _event_class(new_ev)
	var kept: Array[InputEvent] = []
	for ev in InputMap.action_get_events(action):
		if _event_class(ev) != cls:
			kept.append(ev)
	InputMap.action_erase_events(action)
	for ev in kept:
		InputMap.action_add_event(action, ev)
	InputMap.action_add_event(action, new_ev)

func _mouse_button_name(button: int) -> String:
	match button:
		MOUSE_BUTTON_LEFT: return "Left Click"
		MOUSE_BUTTON_RIGHT: return "Right Click"
		MOUSE_BUTTON_MIDDLE: return "Middle Click"
		MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
		MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
		MOUSE_BUTTON_WHEEL_LEFT: return "Wheel Left"
		MOUSE_BUTTON_WHEEL_RIGHT: return "Wheel Right"
	return "Mouse %d" % button

func _start_rebind(action: String, gamepad: bool = false) -> void:
	_waiting_action = action
	_waiting_gamepad = gamepad
	for a in _keybinds_buttons:
		_keybinds_buttons[a].text = _binding_text(a)
	for a in _gamepad_keybinds_buttons:
		_gamepad_keybinds_buttons[a].text = _gamepad_binding_text(a)
	var buttons := _gamepad_keybinds_buttons if gamepad else _keybinds_buttons
	if buttons.has(action):
		buttons[action].text = "Press gamepad..." if gamepad else "Press key / click..."

## Échap/Start pendant un rebind : passe le bind de la colonne remappée à None
## (clavier/souris retirés pour la colonne KB, pad retiré pour la colonne
## Gamepad) et sauvegarde. L'autre colonne reste intacte.
func _clear_bind() -> void:
	var action := _waiting_action
	var gamepad := _waiting_gamepad
	_waiting_action = ""
	_waiting_gamepad = false
	if action == "":
		return
	var cls := "pad" if gamepad else "kb"
	_remove_events_of_class(action, cls)
	_set_cleared(action, cls, true)
	var buttons := _gamepad_keybinds_buttons if gamepad else _keybinds_buttons
	if buttons.has(action):
		buttons[action].text = "None"
	_save_keybinds()

func _set_cleared(action: String, cls: String, cleared: bool) -> void:
	var e: Dictionary = _cleared_keybinds.get(action, {})
	e[cls] = cleared
	_cleared_keybinds[action] = e

func _is_cleared(action: String, cls: String) -> bool:
	return (_cleared_keybinds.get(action, {}) as Dictionary).get(cls, false)

func _apply_saved_keybinds() -> void:
	var binds: Dictionary = _settings.get("keybinds", {})
	for action in binds:
		if not InputMap.has_action(action):
			continue
		if not binds[action] is Dictionary:
			continue
		var bind: Dictionary = binds[action]
		if bind.has("kb") or bind.has("pad"):
			_apply_bind(action, bind)
			continue
		# Ancien format mono-entrée (avant le support pad).
		var prev_ev := _deserialize_event(bind)
		if prev_ev != null:
			_apply_mods(prev_ev, bind.get("mods", {}))
			_set_action_event(action, prev_ev)
			_set_cleared(action, "kb", false)

func _apply_mods(event: InputEvent, mods: Dictionary) -> void:
	if event is InputEventWithModifiers:
		var ev := event as InputEventWithModifiers
		ev.ctrl_pressed = mods.get("ctrl", false)
		ev.shift_pressed = mods.get("shift", false)
		ev.alt_pressed = mods.get("alt", false)
		ev.meta_pressed = mods.get("super", false)

func _save_keybinds() -> void:
	var binds := {}
	for action in REMAPPABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var kb = null
		var pad = null
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey or ev is InputEventMouseButton:
				if kb == null:
					kb = _serialize_event(ev)
			elif ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
				if pad == null:
					pad = _serialize_event(ev)
		var kb_cleared := _is_cleared(action, "kb")
		var pad_cleared := _is_cleared(action, "pad")
		if kb != null or pad != null or kb_cleared or pad_cleared:
			binds[action] = {}
			if kb != null or kb_cleared:
				binds[action]["kb"] = kb if kb != null else {}
			if pad != null or pad_cleared:
				binds[action]["pad"] = pad if pad != null else {}
	_settings["keybinds"] = binds
	_save_settings()

## Descripteur JSON d'un événement d'entrée (clé, souris ou pad).
func _serialize_event(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var kev := ev as InputEventKey
		var code := kev.physical_keycode
		if code == 0:
			code = kev.keycode
		return {"type": "key", "code": code, "mods": _mods_from_event(kev)}
	if ev is InputEventMouseButton:
		return {"type": "mouse", "button": ev.button_index, "mods": _mods_from_event(ev)}
	if ev is InputEventJoypadButton:
		return {"type": "padbutton", "button": ev.button_index}
	if ev is InputEventJoypadMotion:
		var mev := ev as InputEventJoypadMotion
		return {"type": "padaxis", "axis": mev.axis, "axis_value": 1.0 if mev.axis_value >= 0.0 else -1.0}
	return {}

## Reconstruit un InputEvent depuis un descripteur JSON (null si inconnu).
static func _deserialize_event(d: Dictionary) -> InputEvent:
	match d.get("type", ""):
		"key":
			var kev := InputEventKey.new()
			kev.physical_keycode = int(d.get("code", 0))
			return kev
		"mouse":
			var mev := InputEventMouseButton.new()
			mev.button_index = int(d.get("button", MOUSE_BUTTON_LEFT))
			return mev
		"padbutton":
			var jbev := InputEventJoypadButton.new()
			jbev.device = -1
			jbev.button_index = int(d.get("button", 0))
			jbev.pressed = true
			return jbev
		"padaxis":
			var jmev := InputEventJoypadMotion.new()
			jmev.device = -1
			jmev.axis = int(d.get("axis", 0))
			jmev.axis_value = 1.0 if float(d.get("axis_value", 1.0)) >= 0.0 else -1.0
			return jmev
	return null

## Applique une liaison sauvegardée : remplace la classe correspondante sans
## toucher à l'autre (rebinde clavier ne tue plus le pad, et inversement).
func _apply_bind(action: String, bind: Dictionary) -> void:
	for slot in ["kb", "pad"]:
		var d = bind.get(slot)
		if d is Dictionary:
			if d.is_empty():
				# Liaison explicitement passée à None : on retire la classe
				# concernée (clavier+souris pour "kb", pad pour "pad").
				if InputMap.has_action(action):
					_remove_events_of_class(action, slot)
				_set_cleared(action, slot, true)
				continue
			var ev := _deserialize_event(d)
			if ev != null:
				_apply_mods(ev, d.get("mods", {}))
				if InputMap.has_action(action):
					_set_action_event(action, ev)
				_set_cleared(action, slot, false)

## Retire tous les événements d'une classe donnée pour une action. "kb"
## retire à la fois les événements clavier ET souris (colonne Keyboard/Mouse).
func _remove_events_of_class(action: String, cls: String) -> void:
	var kept: Array[InputEvent] = []
	for ev in InputMap.action_get_events(action):
		var ec := _event_class(ev)
		var matches := (cls == "kb" and ec in ["key", "mouse"]) or ec == cls
		if not matches:
			kept.append(ev)
	InputMap.action_erase_events(action)
	for ev in kept:
		InputMap.action_add_event(action, ev)

# ── Coque : en-tête + sidebar + panneau de contenu ───────────────────
# Le menu est un panneau large : catégories toujours visibles à gauche, page
# courante à droite. Toutes les pages (_show_*) construisent toujours leur
# contenu dans `container`, désormais le panneau de droite ; les pages ajoutées
# par un niveau (add_menu_page) aussi.

const SIDEBAR_WIDTH := 230
const CONTENT_MAX_WIDTH := 820

## Catégories de la sidebar : [vue, libellé]. Les pages de niveau
## (add_menu_page) s'insèrent après « Worlds ».
const _CATEGORIES := [
	["general", "General"],
	["graphics", "Graphics"],
	["controls", "Controls"],
	["lan", "Multiplayer"],
	["levels", "Worlds"],
]

var _header_status: Label = null
var _crumb: Label = null
var _sidebar: VBoxContainer = null
var _content_root: Control = null
var _content_margin: MarginContainer = null
var _scroll: ScrollContainer = null
var _nav_buttons: Dictionary = {}       # vue -> Button de la sidebar
var _resume_btn: Button = null
var _extra_pages: Array = []            # [{id, label, show}] — pages ajoutées par le niveau
var _nav_scope: Node = null             # restreint _get_focusable (navigation pad par colonne)

func _build_shell() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# En-tête : marque + état (monde, session).
	var header := PanelContainer.new()
	header.set_meta("ui_class", "pm-header")
	root.add_child(header)
	var hrow := HBoxContainer.new()
	hrow.add_theme_constant_override("separation", 16)
	header.add_child(hrow)
	var brand := Label.new()
	brand.text = "CYBERREALM"
	brand.set_meta("ui_class", "pm-brand")
	hrow.add_child(brand)
	_header_status = Label.new()
	_header_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_header_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_status.set_meta("ui_class", "pm-status")
	hrow.add_child(_header_status)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)

	# Sidebar (persistante : seuls ses états changent d'une page à l'autre).
	var side_panel := PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(SIDEBAR_WIDTH, 0)
	side_panel.set_meta("ui_class", "pm-sidebar")
	body.add_child(side_panel)
	_sidebar = VBoxContainer.new()
	_sidebar.add_theme_constant_override("separation", 2)
	side_panel.add_child(_sidebar)
	_rebuild_sidebar()

	# Contenu : fil d'Ariane + page défilante, largeur bornée et centrée.
	_content_root = VBoxContainer.new()
	_content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_root.add_theme_constant_override("separation", 0)
	body.add_child(_content_root)
	_content_margin = MarginContainer.new()
	_content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_root.add_child(_content_margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_content_margin.add_child(col)
	_crumb = Label.new()
	_crumb.set_meta("ui_class", "pm-crumb")
	_crumb.custom_minimum_size = Vector2(0, 18)
	col.add_child(_crumb)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	col.add_child(_scroll)
	container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 8)
	_scroll.add_child(container)
	_content_root.resized.connect(_layout_content)

## Marges du panneau de contenu : la page garde une largeur lisible
## (CONTENT_MAX_WIDTH) même sur un très grand écran.
func _layout_content() -> void:
	if _content_margin == null:
		return
	var side := maxi(28, int((_content_root.size.x - CONTENT_MAX_WIDTH) * 0.5))
	_content_margin.add_theme_constant_override("margin_left", side)
	_content_margin.add_theme_constant_override("margin_right", side)
	_content_margin.add_theme_constant_override("margin_top", 18)
	_content_margin.add_theme_constant_override("margin_bottom", 18)

func _rebuild_sidebar() -> void:
	if _sidebar == null:
		return
	for c in _sidebar.get_children():
		_sidebar.remove_child(c)
		c.queue_free()
	_nav_buttons.clear()

	_resume_btn = _make_side_btn("▶  Resume", "nav-item nav-resume")
	_resume_btn.pressed.connect(hide_menu)
	_sidebar.add_child(_resume_btn)

	_sidebar.add_child(_make_side_section("Settings"))
	for cat in _CATEGORIES:
		_add_category_btn(String(cat[0]), String(cat[1]), _show_category.bind(String(cat[0])))
		if String(cat[0]) == "controls":
			_sidebar.add_child(_make_side_section("Session"))
	for page in _extra_pages:
		_add_category_btn(String(page["id"]), String(page["label"]), page["show"])

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sidebar.add_child(spacer)

	var tutorial_btn := _make_side_btn("Tutorial", "nav-item")
	tutorial_btn.pressed.connect(func():
		hide_menu()
		tutorial_requested.emit()
	)
	_sidebar.add_child(tutorial_btn)
	var respawn_btn := _make_side_btn("Respawn", "nav-item")
	respawn_btn.pressed.connect(func():
		hide_menu()
		respawn_requested.emit()
	)
	_sidebar.add_child(respawn_btn)
	_quit_btn = _make_side_btn("Quit", "nav-item nav-quit")
	_quit_btn.pressed.connect(_quit_game)
	_quit_btn.disabled = _play_time < QUIT_GAMEPLAY_DELAY
	_sidebar.add_child(_quit_btn)
	_refresh_sidebar()

func _add_category_btn(view: String, label: String, show: Callable) -> void:
	var btn := _make_side_btn(label, "nav-item")
	btn.pressed.connect(func(): show.call())
	_sidebar.add_child(btn)
	_nav_buttons[view] = btn

func _make_side_btn(text: String, klass: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.set_meta("ui_class", klass)
	UITheme.apply_class(btn, klass)
	btn.add_theme_stylebox_override("disabled", btn.get_theme_stylebox("normal"))
	return btn

func _make_side_section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.custom_minimum_size = Vector2(0, 30)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	lbl.set_meta("ui_class", "nav-section")
	UITheme.apply_class(lbl, "nav-section")
	return lbl

func _show_category(view: String) -> void:
	match view:
		"general": _show_general()
		"graphics": _show_graphics()
		"controls": _show_controls()
		"lan": _show_lan()
		"levels": _show_levels()
		_:
			for page in _extra_pages:
				if String(page["id"]) == view:
					(page["show"] as Callable).call()
					return
			_show_main()

## Catégorie de premier niveau d'une vue (remonte _PARENT_VIEW jusqu'à
## l'accueil). Une page de niveau (add_menu_page) est sa propre catégorie.
func _category_of(view: String) -> String:
	var v := view
	for _i in 8:
		var parent := String(_PARENT_VIEW.get(v, "main"))
		if parent == "main":
			return v
		v = parent
	return v

func _category_label(view: String) -> String:
	for cat in _CATEGORIES:
		if String(cat[0]) == view:
			return String(cat[1])
	for page in _extra_pages:
		if String(page["id"]) == view:
			return String(page["label"])
	return ""


func _refresh_sidebar() -> void:
	var active := _category_of(_current_view)
	for view in _nav_buttons:
		var btn: Button = _nav_buttons[view]
		if not is_instance_valid(btn):
			continue
		var klass := "nav-item-selected" if view == active and _current_view != "main" else "nav-item"
		btn.set_meta("ui_class", klass)
		UITheme.apply_class(btn, klass)

## Fil d'Ariane au-dessus du titre de page : « GRAPHICS › » sur une sous-page.
func _refresh_crumb() -> void:
	if _crumb == null:
		return
	var parent := String(_PARENT_VIEW.get(_current_view, "main"))
	if _current_view == "main":
		_crumb.text = ""
	elif parent == "main":
		_crumb.text = ""
	else:
		var lbl := _category_label(_category_of(_current_view))
		_crumb.text = (lbl.to_upper() + "  ›") if lbl != "" else ""

func _world_label() -> String:
	if _level_room != null and _level_room.has_method("get_current_level_label"):
		return String(_level_room.call("get_current_level_label"))
	return "—"

func _refresh_header() -> void:
	if _header_status == null:
		return
	var parts: PackedStringArray = ["World: " + _world_label()]
	if _lan_connected:
		var n := _lan_roster.size()
		parts.append("Multiplayer: %d player%s" % [n, "" if n == 1 else "s"])
	else:
		parts.append("Offline")
	_header_status.text = "   ·   ".join(parts)

func _make_card(caption: String, value: String, detail: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.set_meta("ui_class", "pm-card")
	UITheme.apply_class(card, "pm-card")
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)
	for pair in [[caption, "card-caption"], [value, "card-value"], [detail, "hint"]]:
		var l := Label.new()
		l.text = String(pair[0])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.set_meta("ui_class", String(pair[1]))
		UITheme.apply_class(l, String(pair[1]))
		v.add_child(l)
	return card

## Après construction d'une page : état de la sidebar, fil d'Ariane, en-tête,
## et mode de défilement. Une page qui gère son propre ScrollContainer (listes
## de raccourcis, d'apps…) remplit le panneau sans défilement externe, sinon
## le panneau défile.
func _after_page_built() -> void:
	_normalize_page_layout()
	_focus_first_deferred()
	_refresh_sidebar()
	_refresh_crumb()
	_refresh_header()
	if _scroll == null:
		return
	var inner := _find_live_scroll(container)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if inner != null \
			else ScrollContainer.SCROLL_MODE_AUTO
	_scroll.scroll_vertical = 0
	_layout_content()

const ROW_LABEL_WIDTH := 230

## Mise en forme commune des pages, appliquée après leur construction (y
## compris les pages ajoutées par un niveau) : les pages empilent souvent
## « libellé / curseur / valeur » ou « libellé / champ » sur plusieurs lignes ;
## ils sont regroupés sur UNE ligne (libellé à gauche, contrôle à droite).
## Les libellés courts centrés sont réalignés à gauche, comme les lignes
## centrées commençant par un libellé.
func _normalize_page_layout() -> void:
	var kids: Array = []
	for c in container.get_children():
		if not c.is_queued_for_deletion():
			kids.append(c)
	var i := 0
	while i < kids.size():
		var n: Node = kids[i]
		var next: Node = kids[i + 1] if i + 1 < kids.size() else null
		if n is Label and _is_short_label(n as Label) and next != null \
				and (next is HSlider or next is LineEdit or next is OptionButton):
			var value: Label = null
			if next is HSlider and i + 2 < kids.size() and kids[i + 2] is Label \
					and (kids[i + 2] as Label).text.length() <= 12:
				value = kids[i + 2]
			_make_row_from(n as Label, next as Control, value)
			i += 3 if value != null else 2
			continue
		if n is Label and (n as Label).horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER \
				and not (n as Label).has_meta("ui_keep_center"):
			(n as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		elif n is HBoxContainer and n.get_child_count() > 1 and n.get_child(0) is Label \
				and _is_short_label(n.get_child(0) as Label):
			# Ligne « libellé + contrôle » déjà construite par la page : même
			# colonne de libellés que les lignes regroupées ci-dessus.
			if (n as HBoxContainer).alignment == BoxContainer.ALIGNMENT_CENTER:
				(n as HBoxContainer).alignment = BoxContainer.ALIGNMENT_BEGIN
			var lbl := n.get_child(0) as Label
			lbl.custom_minimum_size.x = ROW_LABEL_WIDTH
			lbl.add_theme_font_size_override("font_size", 14)
		i += 1

func _is_short_label(l: Label) -> bool:
	return not l.text.contains("\n") and l.text.length() <= 40 \
			and l.autowrap_mode == TextServer.AUTOWRAP_OFF

func _make_row_from(label: Label, ctrl: Control, value: Label) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(row)
	container.move_child(row, label.get_index())
	for n: Node in [label, ctrl, value]:
		if n != null:
			n.reparent(row, false)
	label.custom_minimum_size.x = ROW_LABEL_WIDTH
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctrl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if value != null:
		value.custom_minimum_size.x = 56
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value.size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _find_live_scroll(node: Node) -> ScrollContainer:
	for c in node.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is ScrollContainer:
			return c
		var found := _find_live_scroll(c)
		if found != null:
			return found
	return null

## Pages ajoutées par le niveau courant (ex. options Morrowind) : entrée dans
## la sidebar, construite par `show` dans `container` comme les autres pages.
## `id` doit être la valeur que `show` donne à _current_view.
func add_menu_page(id: String, label: String, show: Callable) -> void:
	remove_menu_page(id, false)
	_extra_pages.append({"id": id, "label": label, "show": show})
	_rebuild_sidebar()

func remove_menu_page(id: String, rebuild := true) -> void:
	for i in range(_extra_pages.size() - 1, -1, -1):
		if String(_extra_pages[i]["id"]) == id:
			_extra_pages.remove_at(i)
	if rebuild:
		_rebuild_sidebar()
		if _current_view == id and visible:
			_show_main()

# ── Navigation manette par colonnes ──────────────────────────────────
# Haut/bas restent dans la colonne courante (sidebar ou contenu). Droite
# depuis la sidebar entre dans la page ; gauche depuis la page revient sur la
# catégorie active quand il n'y a plus rien à gauche sur la même ligne.

func _get_focusable(_action: String) -> Array:
	var items: Array = []
	_collect_focusable(_nav_scope if _nav_scope != null else self, items)
	return items

func _move_focus(action: String) -> void:
	var cur := get_viewport().gui_get_focus_owner()
	if cur == null or _sidebar == null or not is_ancestor_of(cur):
		_nav_scope = null
		super(action)
		return
	var in_side := _sidebar.is_ancestor_of(cur)
	if cur is HSlider and action in ["ui_left", "ui_right"]:
		_nav_scope = null
		super(action)
		return
	if action in ["ui_up", "ui_down"]:
		_nav_scope = _sidebar if in_side else _content_root
		super(action)
		_nav_scope = null
		return
	if in_side:
		if action == "ui_right":
			_focus_content_first()
		return
	# Contenu : voisin sur la même ligne, sinon la sidebar (gauche).
	if _has_row_neighbor(cur, action):
		_nav_scope = _content_root
		super(action)
		_nav_scope = null
	elif action == "ui_left":
		_focus_sidebar_active()

func _has_row_neighbor(cur: Control, action: String) -> bool:
	var items: Array = []
	_collect_focusable(_content_root, items)
	var cp := cur.global_position + cur.size * 0.5
	for item in items:
		if item == cur:
			continue
		var ic: Vector2 = (item as Control).global_position + (item as Control).size * 0.5
		if absf(ic.y - cp.y) >= cur.size.y * 0.6:
			continue
		if (action == "ui_left" and ic.x < cp.x - 2.0) or (action == "ui_right" and ic.x > cp.x + 2.0):
			return true
	return false

func _focus_sidebar_active() -> void:
	var active := _category_of(_current_view)
	var btn: Button = _nav_buttons.get(active, null)
	if btn == null or not is_instance_valid(btn):
		btn = _resume_btn
	if btn != null:
		btn.grab_focus()

func _focus_content_first() -> void:
	var items: Array = []
	_collect_focusable(_content_root, items)
	for it in items:
		if not (it as Node).is_queued_for_deletion() and not (it is LineEdit):
			(it as Control).grab_focus()
			return

## Le stick droit fait défiler la liste interne d'une page quand le panneau
## lui-même ne défile pas.
func _scroll_visible_container(amount: int) -> void:
	if _scroll != null and _scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED:
		var inner := _find_live_scroll(container)
		if inner != null:
			inner.scroll_vertical += amount
			return
	if _scroll != null:
		_scroll.scroll_vertical += amount
		return
	super(amount)

# ── Persistance ──────────────────────────────────────────────────────

func _load_settings() -> Dictionary:
	var data := {}
	if FileAccess.file_exists(SETTINGS_PATH):
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				data = parsed
	return data

func _save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_settings, "  "))

func _input(event: InputEvent) -> void:
	# ColorPicker ouvert : empêcher la navigation joypad
	if visible and _find_open_color_picker() != null \
			and (event is InputEventJoypadMotion \
				or (event is InputEventJoypadButton and event.pressed \
					and event.button_index in DPAD_BUTTONS)):
		get_viewport().set_input_as_handled()
		return
	if visible and not _is_popup_open():
		super(event)  # GameMenu : consomme les JoypadMotion
	if not visible:
		return

	# A sur un LineEdit → ouvrir le clavier virtuel
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index == JOY_BUTTON_A \
			and _keyboard != null and not _keyboard.visible:
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit:
			_keyboard.show_menu(focus_owner)
			get_viewport().set_input_as_handled()
			return

	# B : pendant un rebind manette, laissé capturable (fall-through à la
	# capture ci-dessous). Pendant un rebind clavier, consommé sans modifier
	# (ni clear ni retour). Sinon : ferme le clavier / retour / annule un
	# custom bind.
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B \
			and not (_waiting_action != "" and _waiting_gamepad):
		if _waiting_action != "":
			get_viewport().set_input_as_handled()
			return
		# Clavier virtuel ouvert : B le referme seulement, sans retour dans le
		# menu (la navigation arrière reste assurée par START).
		if _keyboard != null and _keyboard.visible:
			_keyboard.hide_menu()
			get_viewport().set_input_as_handled()
			return
		if _custom_key_waiting:
			_custom_key_waiting = false
			if _custom_key_btn:
				_custom_key_btn.text = _custom_key_label()
		elif _current_view == "main":
			hide_menu()
		else:
			_go_back()
		get_viewport().set_input_as_handled()
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _custom_key_waiting:
				_custom_key_waiting = false
				if _custom_key_btn:
					_custom_key_btn.text = _custom_key_label()
			elif _waiting_action != "":
				_clear_bind()
			elif _current_view == "main":
				hide_menu()
			else:
				_go_back()
			get_viewport().set_input_as_handled()
			return

	# Manette : START = Échap (ferme la page principale, remonte d'une
	# sous-page). Pendant un rebind, START clear le bind (comme Échap) :
	# START n'est donc pas réassignable via la capture.
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index == JOY_BUTTON_START \
			and not _custom_key_waiting:
		if _waiting_action != "":
			_clear_bind()
		else:
			if _keyboard != null and _keyboard.visible:
				_keyboard.hide_menu()
			if _current_view == "main":
				hide_menu()
			else:
				_go_back()
		get_viewport().set_input_as_handled()
		return

	if _custom_key_waiting:
		var custom_captured := false
		if event is InputEventKey and event.pressed and not event.echo:
			var kev := event as InputEventKey
			var k := kev.physical_keycode if kev.physical_keycode != 0 else kev.keycode
			if k != 0 and not k in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
				_custom_keycode = k
				_custom_is_mouse = false
				_custom_mods = _mods_from_event(kev)
				custom_captured = true
		elif event is InputEventMouseButton and event.pressed:
			_custom_keycode = event.button_index
			_custom_is_mouse = true
			_custom_mods = _mods_from_event(event)
			custom_captured = true
		if custom_captured:
			_custom_key_waiting = false
			if _custom_key_btn:
				_custom_key_btn.text = _custom_key_label()
			get_viewport().set_input_as_handled()
			return

	if _waiting_action == "":
		return

	var new_event: InputEvent = null
	if event is InputEventKey and event.pressed and not event.echo:
		var kev := event as InputEventKey
		var code := kev.physical_keycode if kev.physical_keycode != 0 else kev.keycode
		if code != 0 and not code in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			var ev := InputEventKey.new()
			ev.physical_keycode = code
			ev.ctrl_pressed = kev.ctrl_pressed
			ev.shift_pressed = kev.shift_pressed
			ev.alt_pressed = kev.alt_pressed
			ev.meta_pressed = kev.meta_pressed
			new_event = ev
	elif event is InputEventMouseButton and event.pressed:
		var mbtn := event as InputEventMouseButton
		var ev := InputEventMouseButton.new()
		ev.button_index = mbtn.button_index
		ev.ctrl_pressed = mbtn.ctrl_pressed
		ev.shift_pressed = mbtn.shift_pressed
		ev.alt_pressed = mbtn.alt_pressed
		ev.meta_pressed = mbtn.meta_pressed
		new_event = ev
	elif _waiting_gamepad and event is InputEventJoypadButton and event.pressed:
		var jbtn := event as InputEventJoypadButton
		var ev := InputEventJoypadButton.new()
		ev.device = -1
		ev.button_index = jbtn.button_index
		ev.pressed = true
		new_event = ev
	elif _waiting_gamepad and event is InputEventJoypadMotion \
			and absf(event.axis_value) >= 0.5:
		var jmot := event as InputEventJoypadMotion
		var ev := InputEventJoypadMotion.new()
		ev.device = -1
		ev.axis = jmot.axis
		ev.axis_value = 1.0 if jmot.axis_value >= 0.0 else -1.0
		new_event = ev

	if new_event == null:
		return

	var action := _waiting_action
	var was_gamepad := _waiting_gamepad
	_set_action_event(action, new_event)
	_set_cleared(action, "pad" if was_gamepad else "kb", false)
	_save_keybinds()
	_waiting_action = ""
	_waiting_gamepad = false
	var buttons := _gamepad_keybinds_buttons if was_gamepad else _keybinds_buttons
	if buttons.has(action):
		buttons[action].text = _gamepad_binding_text(action) if was_gamepad else _binding_text(action)
	get_viewport().set_input_as_handled()
