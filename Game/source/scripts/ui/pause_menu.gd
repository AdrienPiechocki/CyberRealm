extends GameMenu

signal app_launch_requested(command: String)
signal quit_requested
signal keyboard_layout_changed(layout: String, variant: String)
signal polkit_agent_changed(path: String)
signal pins_layer_changed(above: bool)
signal pins_opacity_changed(percent: int)
signal pins_position_changed(position: String)
signal lan_host_requested
signal lan_join_requested(ip: String, pin: String, encrypted: bool)
signal lan_video_settings_changed(bitrate: int, codec: String, fps: int)
signal tutorial_requested
signal lan_disconnect_requested
signal lan_discover_requested
signal lan_color_changed(color: Color)
signal lan_avatar_changed(path: String)
signal lan_name_changed(name: String)

signal graphics_settings_changed(aa_mode: String, fps_limit: int)
signal mouse_sens_changed(mult: float)
signal pad_look_sens_changed(mult: float)
signal focus_stick_sens_changed(mult: float)

const LanManagerScript := preload("res://scripts/network/lan_manager.gd")

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
	"interact_mode", "layer_interact", "window_menu",
	"grab", "focus_window", "pin_window", "kill_window", "hide_window", "share_window",
	"left_click", "right_click", "middle_click", "scroll_up", "scroll_down",
]

var _settings: Dictionary = {}
var _current_view := "main" # "main" | "keybinds" | "startup" | "custom" | "keyboard_layout" | "polkit" | "lan"
var _waiting_action := "" # action en cours de rebind, "" = aucun
var _keybinds_buttons: Dictionary = {} # action -> Button
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
	container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 6)
	add_child(container)
	_apply_styling()
	_settings = _load_settings()
	_apply_saved_keybinds()

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

	custom_minimum_size = Vector2(520, 460)
	size = Vector2(520, 460)
	anchors_preset = Control.PRESET_CENTER
	offset_left = -260
	offset_right = 260
	offset_top = -230
	offset_bottom = 230

func _clear() -> void:
	_quit_btn = null
	for c in container.get_children():
		c.queue_free()
	# Focus pad : différé, donc exécuté APRÈS la fin de construction de la
	# page par le _show_* appelant.
	_focus_first_deferred.call_deferred()

func _make_spacer() -> Control:
	var s := Control.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s

func _make_btn(text: String, color := Color(0.12, 0.14, 0.2, 0.9)) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 42)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 15)

	var n := StyleBoxFlat.new()
	n.bg_color = color
	n.border_color = Color(0.3, 0.4, 0.6, 0.5)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 5; n.corner_radius_top_right = 5
	n.corner_radius_bottom_left = 5; n.corner_radius_bottom_right = 5
	n.content_margin_left = 14; n.content_margin_right = 14
	n.content_margin_top = 8; n.content_margin_bottom = 8
	btn.add_theme_stylebox_override("normal", n)

	var h := n.duplicate()
	h.bg_color = Color(0.18, 0.22, 0.35, 0.95)
	h.border_color = Color(0.4, 0.6, 1.0, 0.7)
	btn.add_theme_stylebox_override("hover", h)

	var p := n.duplicate()
	p.bg_color = Color(0.2, 0.3, 0.5, 0.95)
	btn.add_theme_stylebox_override("pressed", p)
	return btn

func _make_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95))
	lbl.custom_minimum_size = Vector2(0, 50)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lbl

func _make_back_btn() -> Button:
	var back := _make_btn("Back", Color(0.18, 0.18, 0.25, 0.9))
	back.pressed.connect(_show_main)
	return back

func _make_line_edit() -> LineEdit:
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 36)
	le.add_theme_font_size_override("font_size", 14)

	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	n.border_color = Color(0.3, 0.4, 0.6, 0.5)
	n.border_width_top = 1; n.border_width_bottom = 1
	n.border_width_left = 1; n.border_width_right = 1
	n.corner_radius_top_left = 5; n.corner_radius_top_right = 5
	n.corner_radius_bottom_left = 5; n.corner_radius_bottom_right = 5
	n.content_margin_left = 12; n.content_margin_right = 12
	le.add_theme_stylebox_override("normal", n)

	var f := n.duplicate()
	f.border_color = Color(0.4, 0.6, 1.0, 0.7)
	le.add_theme_stylebox_override("focus", f)

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
		if n is BaseButton or n is OptionButton or n is CheckBox:
			n.grab_focus()
			return

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

	container.add_child(_make_title("MAIN MENU"))

	var keybinds_btn := _make_btn("Remap keybinds")
	keybinds_btn.pressed.connect(_show_keybinds)
	container.add_child(keybinds_btn)

	var startup_btn := _make_btn("Startup Apps")
	startup_btn.pressed.connect(_show_startup_apps)
	container.add_child(startup_btn)

	var custom_btn := _make_btn("Custom Binds")
	custom_btn.pressed.connect(_show_custom_binds)
	container.add_child(custom_btn)

	var kb_btn := _make_btn("Keyboard Layout")
	kb_btn.pressed.connect(_show_keyboard_layout)
	container.add_child(kb_btn)

	var polkit_btn := _make_btn("Polkit Agent")
	polkit_btn.pressed.connect(_show_polkit)
	container.add_child(polkit_btn)

	var pins_btn := _make_btn("Pinned Windows")
	pins_btn.pressed.connect(_show_pins)
	container.add_child(pins_btn)
	
	var lan_btn := _make_btn("LAN Game")
	lan_btn.pressed.connect(_show_lan)
	container.add_child(lan_btn)

	var gc_btn := _make_btn("Graphics & Controls")
	gc_btn.pressed.connect(_show_graphics_controls)
	container.add_child(gc_btn)

	var tutorial_btn := _make_btn("Tutorial")
	tutorial_btn.pressed.connect(func():
		hide_menu()
		tutorial_requested.emit()
	)
	container.add_child(tutorial_btn)
	
	container.add_child(_make_spacer())
	
	var back_btn := _make_btn("Back")
	back_btn.pressed.connect(hide_menu)
	container.add_child(back_btn)

	var quit_btn := _make_btn("Quit", Color(0.3, 0.08, 0.08, 0.9))
	quit_btn.pressed.connect(_quit_game)
	quit_btn.disabled = _play_time < QUIT_GAMEPLAY_DELAY
	container.add_child(quit_btn)
	_quit_btn = quit_btn

func _show_keybinds() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "keybinds"

	container.add_child(_make_title("REMAP KEYBINDS"))

	var hint := Label.new()
	hint.text = "Click an action, then press a key or mouse button (hold Ctrl/Shift/Alt/Super for modifiers, Escape = cancel)."
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

	_keybinds_buttons.clear()
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
		btn.pressed.connect(_start_rebind.bind(action))
		row.add_child(btn)
		_keybinds_buttons[action] = btn

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

			var edit_btn := _make_btn("Edit", Color(0.1, 0.25, 0.15, 0.9))
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_startup_app.bind(i))
			row.add_child(edit_btn)

			var remove_btn := _make_btn("Remove", Color(0.25, 0.1, 0.1, 0.9))
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
	hint.text = "A key launches a command.\nHold Ctrl/Shift/Alt/Super for keyboard modifiers. Gamepad binds require LT held."
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

			var edit_btn := _make_btn("Edit", Color(0.1, 0.25, 0.15, 0.9))
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_custom_bind.bind(i))
			row.add_child(edit_btn)

			var remove_btn := _make_btn("Remove", Color(0.25, 0.1, 0.1, 0.9))
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

	var apply_btn := _make_btn("Apply")
	apply_btn.pressed.connect(_apply_keyboard_layout.bind(opt))
	container.add_child(apply_btn)

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
	container.add_child(line_edit)

	var apply_btn := _make_btn("Apply")
	apply_btn.pressed.connect(_apply_polkit_agent.bind(line_edit))
	container.add_child(apply_btn)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_polkit_agent(line_edit: LineEdit) -> void:
	var cmd := line_edit.text.strip_edges()
	_settings["polkit_agent"] = cmd
	_save_settings()
	polkit_agent_changed.emit(cmd)
	_show_main()

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

func get_aa_mode() -> String:
	return _settings.get("aa_mode", "off")

func get_mouse_sens_mult() -> float:
	return _settings.get("mouse_sens_mult", 1.0)

func get_pad_look_sens_mult() -> float:
	return _settings.get("pad_look_sens_mult", 1.0)

func get_focus_stick_sens_mult() -> float:
	return _settings.get("focus_stick_sens_mult", 1.0)

func get_fps_limit() -> int:
	return _settings.get("fps_limit", 60)

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

	var apply_btn := _make_btn("Apply")
	apply_btn.pressed.connect(_apply_pins_settings.bind(opt, pos_opt, slider))
	container.add_child(apply_btn)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func _apply_pins_settings(opt: OptionButton, pos_opt: OptionButton, slider: HSlider) -> void:
	var above := opt.selected == 1
	var percent: int = clampi(int(slider.value), 0, 100)
	var pos := "top_left"
	if pos_opt.selected >= 0 and pos_opt.selected < PIN_POSITIONS.size():
		pos = String(PIN_POSITIONS[pos_opt.selected].get("id", "top_left"))
	_settings["pins_above_focus"] = above
	_settings["pins_opacity"] = percent
	_settings["pins_position"] = pos
	_save_settings()
	pins_layer_changed.emit(above)
	pins_opacity_changed.emit(percent)
	pins_position_changed.emit(pos)
	_show_main()

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

func _show_graphics_controls() -> void:
	_clear()
	_current_view = "graphics_controls"

	container.add_child(_make_title("GRAPHICS & CONTROLS"))

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

	container.add_child(_make_spacer())

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

	# ── FPS limit ──
	var fps_label := Label.new()
	fps_label.text = "FPS Limit"
	fps_label.add_theme_font_size_override("font_size", 14)
	fps_label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
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
	)

	# ── Apply ──
	container.add_child(_make_spacer())

	var apply_btn := _make_btn("Apply")
	apply_btn.pressed.connect(_apply_graphics_controls.bind(aa_opt, mouse_slider, pad_slider, focus_slider, fps_slider))
	container.add_child(apply_btn)

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

func _apply_graphics_controls(aa_opt: OptionButton, mouse_s: HSlider, pad_s: HSlider, focus_s: HSlider, fps_s: HSlider) -> void:
	var aa_idx := aa_opt.selected
	if aa_idx < 0 or aa_idx >= AA_MODES.size():
		aa_idx = 0
	var aa_mode := AA_MODES[aa_idx]
	var mouse_mult: float = mouse_s.value
	var pad_mult: float = pad_s.value
	var focus_mult: float = focus_s.value
	var fps_limit: int = int(fps_s.value)

	_settings["aa_mode"] = aa_mode
	_settings["mouse_sens_mult"] = mouse_mult
	_settings["pad_look_sens_mult"] = pad_mult
	_settings["focus_stick_sens_mult"] = focus_mult
	_settings["fps_limit"] = fps_limit
	_save_settings()

	_apply_aa(aa_mode)
	Engine.max_fps = fps_limit
	graphics_settings_changed.emit(aa_mode, fps_limit)
	mouse_sens_changed.emit(mouse_mult)
	pad_look_sens_changed.emit(pad_mult)
	focus_stick_sens_changed.emit(focus_mult)
	_show_main()

func _show_lan() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "lan"

	container.add_child(_make_title("LAN GAME"))

	var hint := Label.new()
	if _lan_connected:
		hint.text = "Connected — click Apply to broadcast changes to other players."
	else:
		hint.text = "Multiplayer on your local network (2-4 players).\nEach player keeps their own desktop; you see each other's avatar."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	container.add_child(hint)

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
	if not _lan_connected:
		color_btn.color_changed.connect(func(c: Color):
			_settings["lan_player_color"] = c.to_html(true)
			_save_settings()
			lan_color_changed.emit(c)
		)
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
		if not _lan_connected:
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

	# Bouton Apply unifié : sauvegarde nom/couleur/avatar et émet les signaux
	if _lan_connected:
		var apply_btn := _make_btn("Apply", Color(0.1, 0.25, 0.15, 0.9))
		apply_btn.custom_minimum_size = Vector2(0, 36)
		apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		apply_btn.pressed.connect(func():
			_save_lan_name(name_edit)
			_settings["lan_player_color"] = color_btn.color.to_html(true)
			var idx := avatar_opt.selected
			if idx >= 0:
				_settings["lan_avatar_path"] = String(avatar_opt.get_item_metadata(idx))
			_save_settings()
			lan_color_changed.emit(color_btn.color)
			if idx >= 0:
				lan_avatar_changed.emit(String(avatar_opt.get_item_metadata(idx)))
		)
		container.add_child(apply_btn)

	var host_btn := _make_btn("Host Game")
	host_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		lan_host_requested.emit()
	)
	container.add_child(host_btn)

	# PIN label (visible when hosting — shows the generated PIN).
	_lan_pin_label = Label.new()
	_lan_pin_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lan_pin_label.add_theme_font_size_override("font_size", 16)
	_lan_pin_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_lan_pin_label.visible = false
	container.add_child(_lan_pin_label)

	var join_row := HBoxContainer.new()
	join_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ip_edit := _make_line_edit()
	ip_edit.placeholder_text = "Host IP (ex: 192.168.1.5)"
	join_row.add_child(ip_edit)
	var pin_edit := _make_line_edit()
	pin_edit.placeholder_text = "PIN"
	pin_edit.custom_minimum_size = Vector2(80, 36)
	pin_edit.max_length = 4
	join_row.add_child(pin_edit)
	var encryption_btn := CheckButton.new()
	encryption_btn.text = "TLS"
	encryption_btn.tooltip_text = "Encrypt the session (DTLS) with the embedded certificates"
	encryption_btn.button_pressed = true
	join_row.add_child(encryption_btn)
	var join_btn := _make_btn("Join")
	join_btn.custom_minimum_size = Vector2(100, 36)
	join_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	join_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		var ip := ip_edit.text.strip_edges()
		var pin := pin_edit.text.strip_edges()
		if ip != "":
			lan_join_requested.emit(ip, pin, encryption_btn.button_pressed)
	)
	join_row.add_child(join_btn)
	container.add_child(join_row)

	var find_btn := _make_btn("Find LAN games")
	find_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		lan_discover_requested.emit()
	)
	container.add_child(find_btn)

	var video_title := Label.new()
	video_title.text = "Video share"
	video_title.add_theme_font_size_override("font_size", 16)
	video_title.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	container.add_child(video_title)

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

	var apply_video_btn := _make_btn("Apply video settings")
	apply_video_btn.pressed.connect(func():
		var codec := "auto"
		if codec_opt.selected == 1:
			codec = "h264"
		elif codec_opt.selected == 2:
			codec = "av1"
		lan_video_settings_changed.emit(int(bitrate_spin.value) * 1_000_000, codec, int(fps_spin.value))
	)
	container.add_child(apply_video_btn)

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

	var disconnect_btn := _make_btn("Disconnect", Color(0.3, 0.2, 0.1, 0.9))
	disconnect_btn.pressed.connect(func():
		lan_disconnect_requested.emit()
	)
	container.add_child(disconnect_btn)

	container.add_child(_make_spacer())
	container.add_child(_make_back_btn())

func set_lan_status(text: String) -> void:
	_lan_status_text = text
	if _lan_status_label:
		_lan_status_label.text = text

func set_lan_players(roster: Array) -> void:
	_lan_roster = roster
	_update_lan_players_label()

func set_lan_connected(connected: bool) -> void:
	_lan_connected = connected

func set_lan_pin(pin: String) -> void:
	if _lan_pin_label == null:
		return
	if pin != "":
		_lan_pin_label.text = "Session PIN: %s" % pin
		_lan_pin_label.visible = true
	else:
		_lan_pin_label.visible = false

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
	if ip != "":
		lan_join_requested.emit(ip, "", true)

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

## Remplace uniquement les événements de la MÊME classe d'entrée : rebinde
## clavier ne détruit plus la liaison pad d'une action, et vice-versa.
func _event_class(ev: InputEvent) -> String:
	if ev is InputEventKey:
		return "key"
	if ev is InputEventMouseButton:
		return "mouse"
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

func _start_rebind(action: String) -> void:
	_waiting_action = action
	for a in _keybinds_buttons:
		_keybinds_buttons[a].text = _binding_text(a)
	if _keybinds_buttons.has(action):
		_keybinds_buttons[action].text = "Press key / click..."

func _cancel_rebind() -> void:
	var pending := _waiting_action
	_waiting_action = ""
	if pending != "" and _keybinds_buttons.has(pending):
		_keybinds_buttons[pending].text = _binding_text(pending)

func _apply_saved_keybinds() -> void:
	var binds: Dictionary = _settings.get("keybinds", {})
	for action in binds:
		if not InputMap.has_action(action):
			continue
		if not binds[action] is Dictionary:
			continue
		var bind: Dictionary = binds[action]
		if bind.has("kb"):
			_apply_bind(action, bind)
			continue
		# Ancien format mono-entrée (avant le support pad).
		var prev_ev := _deserialize_event(bind)
		if prev_ev != null:
			_apply_mods(prev_ev, bind.get("mods", {}))
			_set_action_event(action, prev_ev)

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
		for ev in InputMap.action_get_events(action):
			if kb == null and (ev is InputEventKey or ev is InputEventMouseButton):
				kb = _serialize_event(ev)
		if kb != null:
			binds[action] = {"kb": kb}
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
	return null

## Applique une liaison sauvegardée : remplace la classe correspondante sans
## toucher à l'autre (rebinde clavier ne tue plus le pad, et inversement).
func _apply_bind(action: String, bind: Dictionary) -> void:
	for slot in ["kb"]:
		var d = bind.get(slot)
		if d is Dictionary and not d.is_empty():
			var ev := _deserialize_event(d)
			if ev != null:
				_apply_mods(ev, d.get("mods", {}))
				if InputMap.has_action(action):
					_set_action_event(action, ev)
			elif slot == "kb" and InputMap.has_action(action):
				# Liaison clavier explicitement vide : on retire l'ancienne
				# (l'utilisateur a voulu la vider), le pad reste intact.
				pass

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

	# B button closes the keyboard
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B:
		_keyboard.hide_menu()
		if _custom_key_waiting:
			_custom_key_waiting = false
			if _custom_key_btn:
				_custom_key_btn.text = _custom_key_label()
		elif _waiting_action != "":
			_cancel_rebind()
		elif _current_view == "main":
			hide_menu()
		else:
			_show_main()
		get_viewport().set_input_as_handled()
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _custom_key_waiting:
				_custom_key_waiting = false
				if _custom_key_btn:
					_custom_key_btn.text = _custom_key_label()
			elif _waiting_action != "":
				_cancel_rebind()
			elif _current_view == "main":
				hide_menu()
			else:
				_show_main()
			get_viewport().set_input_as_handled()
			return

	# Manette : Start/B = Échap (ferme la page principale, remonte d'une
	# sous-page). Inactif pendant une capture de touche (rebind/custom) :
	# on ne rebind pas Start/B avec eux-mêmes ; Échap reste l'annulateur.

	if event is InputEventJoypadButton and event.pressed \
			and event.button_index in [JOY_BUTTON_START, JOY_BUTTON_B] \
			and not _custom_key_waiting and _waiting_action == "":
		if _current_view == "main":
			hide_menu()
		else:
			_show_main()
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

	if new_event == null:
		return

	var action := _waiting_action
	_set_action_event(action, new_event)
	_save_keybinds()
	_waiting_action = ""
	if _keybinds_buttons.has(action):
		_keybinds_buttons[action].text = _binding_text(action)
	get_viewport().set_input_as_handled()
