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
signal lan_host_invite_requested
signal lan_join_invite_requested(code: String)
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

const SETTINGS_PATH := "user://settings.json"

# Le bouton Quit ne devient actif qu'après ce temps de jeu (secondes).
const QUIT_GAMEPLAY_DELAY := 3.0

var container: VBoxContainer

var _settings: Dictionary = {}
var _lan: Node = null
## Chat vocal (voice_manager.gd) : volume et sourdine par joueur depuis la page Multiplayer. Posé par wayland_room.
var voice_manager: Node = null

# ── Modules (nœuds enfants, créés dans _init : mêmes chemins de RPC chez le serveur et les clients) ──
const ShellModule := preload("res://scripts/ui/pause/shell.gd")
const PageGeneralModule := preload("res://scripts/ui/pause/page_general.gd")
const PageKeybindsModule := preload("res://scripts/ui/pause/page_keybinds.gd")
const PageStartupAppsModule := preload("res://scripts/ui/pause/page_startup_apps.gd")
const PageMultiplayerModule := preload("res://scripts/ui/pause/page_multiplayer.gd")
const PageWorldModule := preload("res://scripts/ui/pause/page_world.gd")
var shell: ShellModule = null
var page_general: PageGeneralModule = null
var page_keybinds: PageKeybindsModule = null
var page_startup_apps: PageStartupAppsModule = null
var page_multiplayer: PageMultiplayerModule = null
var page_world: PageWorldModule = null

func _init() -> void:
	shell = ShellModule.new()
	shell.name = "Shell"
	shell.menu = self
	add_child(shell)
	page_general = PageGeneralModule.new()
	page_general.name = "PageGeneral"
	page_general.menu = self
	add_child(page_general)
	page_keybinds = PageKeybindsModule.new()
	page_keybinds.name = "PageKeybinds"
	page_keybinds.menu = self
	add_child(page_keybinds)
	page_startup_apps = PageStartupAppsModule.new()
	page_startup_apps.name = "PageStartupApps"
	page_startup_apps.menu = self
	add_child(page_startup_apps)
	page_multiplayer = PageMultiplayerModule.new()
	page_multiplayer.name = "PageMultiplayer"
	page_multiplayer.menu = self
	add_child(page_multiplayer)
	page_world = PageWorldModule.new()
	page_world.name = "PageWorld"
	page_world.menu = self
	add_child(page_world)

## Réf. directe vers le lan_manager (retour de get_banned_ips/unban_ip dans
## la page admin). Injectée par wayland_room au setup LAN.
func set_lan_ref(lan: Node) -> void:
	_lan = lan

# Page « World » : WaylandRoom (niveau courant, chargement en cours) et
# dernier message d'état, conservé si la page est reconstruite.
var _level_room: Node = null

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
# Capture d'une touche pour un custom bind
var _custom_key_waiting := false
var _custom_keycode := 0
var _custom_is_mouse := false
var _custom_mods: Dictionary = {} # {"ctrl": bool, "shift": bool, "alt": bool, "super": bool}
var _custom_key_btn: Button = null
var _editing_index := -1 # index du custom bind en cours d'édition, -1 = aucun
var _quit_btn: Button = null
var _play_time := 0.0
var _keyboard: VirtualKeyboard = null
var _lan_roster: Array = []
var _lan_connected := false

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
	shell._build_shell()
	_apply_styling()
	UITheme.stylesheet_reloaded.connect(_on_stylesheet_reloaded)
	_settings = _load_settings()
	UITheme.set_accent_color(get_accent_color())
	page_keybinds._apply_saved_keybinds()

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
	shell._after_page_built.call_deferred()

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
	if shell._is_extra_page(_current_view):
		page_world._show_levels()
		return
	match _PARENT_VIEW.get(_current_view, "main"):
		"general": page_general._show_general()
		"graphics": page_general._show_graphics()
		"controls": page_general._show_controls()
		"lan": page_multiplayer._show_lan()
		"levels": page_world._show_levels()
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
	cards.add_child(shell._make_card("WORLD", shell._world_label(),
		"Locked during a multiplayer session" if _lan_connected else "Change it in World"))
	var players := _lan_roster.size()
	cards.add_child(shell._make_card("MULTIPLAYER",
		("Connected" if _lan_connected else "Offline"),
		("%d player%s" % [players, "" if players == 1 else "s"]) if _lan_connected else "Host or join in Multiplayer"))

	container.add_child(_make_spacer())

func get_keyboard_layout() -> Dictionary:
	return {
		"layout": String(_settings.get("keyboard_layout", "fr")),
		"variant": String(_settings.get("keyboard_variant", "")),
	}

# ── Polkit agent ────────────────────────────────────────────────────

func get_polkit_agent() -> String:
	return String(_settings.get("polkit_agent", ""))

# ── Screenshot folder ───────────────────────────────────────────────

# Dossier où sont enregistrées les captures (bind impr. écran + menu fenêtre).
# Réglage utilisateur s'il existe, sinon le dossier Pictures de la session
# ($(xdg-user-dir PICTURES)), sinon ~/Pictures en dernier recours.
func get_screenshot_folder() -> String:
	var saved := String(_settings.get("screenshot_folder", "")).strip_edges()
	if saved != "":
		return saved
	return page_general._default_screenshot_folder()

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

# Une app (VM, bureau à distance…) peut-elle capturer les raccourcis du jeu en mode focus
# (zwp_keyboard_shortcuts_inhibit_v1) ? (GENERAL). Défaut : oui.
func is_shortcut_inhibit_allowed() -> bool:
	return bool(_settings.get("allow_shortcut_inhibit", true))

# Reprise de la session précédente (window_layouts.gd) : les apps encore ouvertes à la fermeture du jeu sont
# relancées et les fenêtres retrouvent leur place. (GENERAL). Défaut : oui. Sans réglage enregistré, on reprend les
# deux anciennes options séparées (remember_window_layout / reopen_last_session) : décochée si l'une l'était.
# Chat vocal (MULTIPLAYER, voice_manager.gd). Mode : "off" (défaut : le micro n'est jamais ouvert), "ptt"
# (appuyer pour parler, action push_to_talk) ou "vad" (activation vocale au-dessus du seuil).
func get_voice_mode() -> String:
	var m := String(_settings.get("voice_mode", "off"))
	return m if m in ["off", "ptt", "vad"] else "off"

func get_voice_vad_threshold() -> float:
	return float(_settings.get("voice_vad_threshold", 0.02))

func is_voice_spatial() -> bool:
	return bool(_settings.get("voice_spatial", true))

func is_voice_echo_cancel() -> bool:
	return bool(_settings.get("voice_echo_cancel", false))

func get_voice_volume() -> float:
	return float(_settings.get("voice_volume", 1.0))

## Gain du micro (dB, 0 à +24) appliqué avant l'encodage (VoiceChat::set_gain_db).
func get_voice_mic_gain_db() -> float:
	return clampf(float(_settings.get("voice_mic_gain_db", 0.0)), 0.0, 24.0)

## Micro du chat vocal : nom du nœud PipeWire ("" = source par défaut). Voir scripts/main/mic_sources.gd.
func get_voice_mic() -> String:
	return String(_settings.get("voice_mic", ""))

# Son des fenêtres (GENERAL, window_audio.gd) : "normal" (défaut, les apps jouent directement) ou "spatial" (le son
# sort du quad de chaque fenêtre).
func get_window_audio_mode() -> String:
	var m := String(_settings.get("window_audio", "normal"))
	return m if m in ["normal", "spatial"] else "normal"

# Contenu des notifications dans le monde (GENERAL, objets du bureau) : "full" (défaut), "app" ou "count".
func get_notification_privacy() -> String:
	var m := String(_settings.get("notification_privacy", "full"))
	return m if m in ["full", "app", "count"] else "full"

# Clavier virtuel sur un champ de texte (GENERAL, text_input_osk.gd) : "pad" (défaut), "always" ou "never".
func get_osk_on_text_input() -> String:
	var m := String(_settings.get("osk_on_text_input", "pad"))
	return m if m in ["pad", "always", "never"] else "pad"

# Netteté selon la distance (GENERAL, window_sharpness.gd) : échelle maximale annoncée aux fenêtres vues de près.
# 1.0 = désactivée. Défaut : 1.5.
func get_window_sharpness_max() -> float:
	var v := float(_settings.get("window_sharpness", 1.5))
	return v if v in [1.0, 1.5, 2.0] else 1.5

# Bulles de chat au-dessus des avatars (MULTIPLAYER). Défaut : oui.
# Annotations éphémères (MULTIPLAYER, lot K) : un trait disparaît 4 s après avoir été tracé. Défaut : oui.
func is_annotation_ephemeral() -> bool:
	return bool(_settings.get("annotation_ephemeral", true))

func is_chat_bubbles_enabled() -> bool:
	return bool(_settings.get("chat_bubbles", true))

func is_session_restore_enabled() -> bool:
	if _settings.has("restore_session"):
		return bool(_settings["restore_session"])
	return bool(_settings.get("remember_window_layout", true)) and bool(_settings.get("reopen_last_session", true))

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

# Réglages environnement persistés (dictionnaire appliqué aux niveaux).
func get_environment_settings() -> Dictionary:
	return (_settings.get("environment", {}) as Dictionary).duplicate()

# ── Startup apps ─────────────────────────────────────────────────────

func get_startup_apps() -> Array:
	return _settings.get("startup_apps", [])

# ── Custom binds ─────────────────────────────────────────────────────

func get_custom_binds() -> Array:
	return _settings.get("custom_binds", [])
var _sidebar: VBoxContainer = null
var _content_root: Control = null
var _scroll: ScrollContainer = null
var _nav_buttons: Dictionary = {}       # vue -> Button de la sidebar
var _resume_btn: Button = null
var _extra_pages: Array = []            # [{id, label, show}] — pages ajoutées par le niveau
var _nav_scope: Node = null             # restreint _get_focusable (navigation pad par colonne)

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
	var active := shell._category_of(_current_view)
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
		var inner := shell._find_live_scroll(container)
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
				_custom_key_btn.text = page_keybinds._custom_key_label()
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
					_custom_key_btn.text = page_keybinds._custom_key_label()
			elif _waiting_action != "":
				page_keybinds._clear_bind()
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
			page_keybinds._clear_bind()
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
				_custom_mods = page_keybinds._mods_from_event(kev)
				custom_captured = true
		elif event is InputEventMouseButton and event.pressed:
			_custom_keycode = event.button_index
			_custom_is_mouse = true
			_custom_mods = page_keybinds._mods_from_event(event)
			custom_captured = true
		if custom_captured:
			_custom_key_waiting = false
			if _custom_key_btn:
				_custom_key_btn.text = page_keybinds._custom_key_label()
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
	page_keybinds._set_action_event(action, new_event)
	page_keybinds._set_cleared(action, "pad" if was_gamepad else "kb", false)
	page_keybinds._save_keybinds()
	_waiting_action = ""
	_waiting_gamepad = false
	var buttons := _gamepad_keybinds_buttons if was_gamepad else _keybinds_buttons
	if buttons.has(action):
		buttons[action].text = page_keybinds._gamepad_binding_text(action) if was_gamepad else page_keybinds._binding_text(action)
	get_viewport().set_input_as_handled()

# ── Relais vers les modules (API publique inchangée) ─────────────────

func set_level_status(text: String) -> void:
	page_world.set_level_status(text)

func set_lan_connected(connected: bool) -> void:
	page_multiplayer.set_lan_connected(connected)

func set_lan_status(text: String) -> void:
	page_multiplayer.set_lan_status(text)

func set_lan_players(roster: Array) -> void:
	page_multiplayer.set_lan_players(roster)

func set_lan_pin(pin: String) -> void:
	page_multiplayer.set_lan_pin(pin)

func set_lan_discovery_results(results: Array) -> void:
	page_multiplayer.set_lan_discovery_results(results)

func on_level_changed(path: String) -> void:
	page_world.on_level_changed(path)

func add_menu_page(id: String, label: String, show: Callable) -> void:
	shell.add_menu_page(id, label, show)

func remove_menu_page(id: String, rebuild := true) -> void:
	shell.remove_menu_page(id, rebuild)

func _apply_aa(mode: String) -> void:
	page_general._apply_aa(mode)

func _make_row_label(text: String) -> Label:
	return page_general._make_row_label(text)
