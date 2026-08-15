extends PanelContainer

signal app_launch_requested(command: String)
signal quit_requested
signal keyboard_layout_changed(layout: String, variant: String)
signal polkit_agent_changed(path: String)
signal pins_layer_changed(above: bool)
signal pins_opacity_changed(percent: int)
signal pins_position_changed(position: String)
signal lan_host_requested
signal lan_join_requested(ip: String)
signal lan_disconnect_requested
signal lan_discover_requested
signal lan_color_changed(color: Color)

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
	"interact_mode", "window_menu",
	"grab", "focus_window", "pin_window", "kill_window", "layer_interact",
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
var _quit_btn: Button = null
var _play_time := 0.0
# Page LAN
var _lan_status_label: Label = null
var _lan_players_label: Label = null
var _lan_results_box: VBoxContainer = null
var _lan_status_text := ""
var _lan_roster: Array = []

func _process(delta: float) -> void:
	if _play_time < QUIT_GAMEPLAY_DELAY:
		_play_time += delta
	if _quit_btn:
		_quit_btn.disabled = _play_time < QUIT_GAMEPLAY_DELAY

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

func show_menu() -> void:
	visible = true
	_show_main()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func hide_menu() -> void:
	_waiting_action = ""
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

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
		for app in apps:
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
			launch_btn.custom_minimum_size = Vector2(110, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(_launch_app.bind(app))
			row.add_child(launch_btn)

			var remove_btn := _make_btn("Remove", Color(0.25, 0.1, 0.1, 0.9))
			remove_btn.custom_minimum_size = Vector2(110, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_startup_app.bind(app))
			row.add_child(remove_btn)

			list.add_child(row)

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var le := _make_line_edit()
	le.placeholder_text = "command (ex: firefox, konsole)"
	le.text_submitted.connect(func(text: String):
		_add_startup_app(text.strip_edges())
	)
	add_row.add_child(le)
	var add_btn := _make_btn("Add")
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
	_custom_keycode = 0
	_custom_is_mouse = false
	_custom_mods = {}

	container.add_child(_make_title("CUSTOM BINDS"))

	var hint := Label.new()
	hint.text = "A key launches a command (hold Ctrl/Shift/Alt/Super to set modifiers)."
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

	var binds: Array = _settings.get("custom_binds", [])
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

			var remove_btn := _make_btn("Remove", Color(0.25, 0.1, 0.1, 0.9))
			remove_btn.custom_minimum_size = Vector2(100, 36)
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
	_custom_cmd_edit.text_submitted.connect(func(_t: String):
		_add_custom_bind()
	)
	add_row.add_child(_custom_cmd_edit)

	var add_btn := _make_btn("Add")
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

func get_lan_player_name() -> String:
	var nm := String(_settings.get("lan_player_name", "")).strip_edges()
	if nm == "":
		return OS.get_environment("USER")
	return nm

func get_lan_player_color() -> Color:
	var fallback := Color(0.2, 0.6, 1.0)
	var v = _settings.get("lan_player_color", fallback)
	if v is Color:
		return v
	if v is String:
		var s := (v as String).strip_edges()
		# Nouveau format : hex "#rrggbbaa".
		if s.begins_with("#"):
			return Color.from_string(s, fallback)
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

func _show_lan() -> void:
	_clear()
	_waiting_action = ""
	_current_view = "lan"

	container.add_child(_make_title("LAN GAME"))

	var hint := Label.new()
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
	color_btn.color = get_lan_player_color()
	color_btn.custom_minimum_size = Vector2(64, 30)
	color_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	color_btn.color_changed.connect(func(c: Color):
		_settings["lan_player_color"] = c.to_html(true)
		_save_settings()
		lan_color_changed.emit(c)
	)
	color_row.add_child(color_btn)
	container.add_child(color_row)

	var host_btn := _make_btn("Host Game")
	host_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		lan_host_requested.emit()
	)
	container.add_child(host_btn)

	var join_row := HBoxContainer.new()
	join_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ip_edit := _make_line_edit()
	ip_edit.placeholder_text = "Host IP (ex: 192.168.1.5)"
	join_row.add_child(ip_edit)
	var join_btn := _make_btn("Join")
	join_btn.custom_minimum_size = Vector2(100, 36)
	join_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	join_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		var ip := ip_edit.text.strip_edges()
		if ip != "":
			lan_join_requested.emit(ip)
	)
	join_row.add_child(join_btn)
	container.add_child(join_row)

	var discover_btn := _make_btn("Discover LAN games")
	discover_btn.pressed.connect(func():
		_save_lan_name(name_edit)
		lan_discover_requested.emit()
	)
	container.add_child(discover_btn)

	_lan_results_box = VBoxContainer.new()
	_lan_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lan_results_box.add_theme_constant_override("separation", 4)
	container.add_child(_lan_results_box)

	var lan_hint := Label.new()
	lan_hint.text = "Astuce : si un PC ne voit pas l'autre, vérifiez qu'ils sont sur le même réseau, que le pare-feu de l'hôte laisse passer UDP 7777/9999, et désactivez l'isolation AP du routeur."
	lan_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lan_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lan_hint.add_theme_font_size_override("font_size", 11)
	lan_hint.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
	container.add_child(lan_hint)

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
		lan_join_requested.emit(ip)

# ── Startup apps ─────────────────────────────────────────────────────

func get_startup_apps() -> Array:
	return _settings.get("startup_apps", [])

func _launch_app(app: String) -> void:
	app_launch_requested.emit(app)

func _add_from_line_edit(le: LineEdit) -> void:
	_add_startup_app(le.text.strip_edges())

func _add_startup_app(cmd: String) -> void:
	if cmd == "":
		return
	var apps: Array = _settings.get("startup_apps", [])
	if not apps.has(cmd):
		apps.append(cmd)
	_settings["startup_apps"] = apps
	_save_settings()
	_show_startup_apps()

func _remove_startup_app(cmd: String) -> void:
	var apps: Array = _settings.get("startup_apps", [])
	apps.erase(cmd)
	_settings["startup_apps"] = apps
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
	if _custom_keycode == 0:
		return "Set key"
	var key_text := ""
	if _custom_is_mouse:
		key_text = _mouse_button_name(_custom_keycode)
	else:
		key_text = OS.get_keycode_string(_custom_keycode)
	var mods := _mods_to_string(_custom_mods)
	if mods != "":
		return mods + "+" + key_text
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
	if not _custom_cmd_edit or not _custom_keycode or _custom_cmd_edit.text.strip_edges() == "":
		return
	var binds: Array = _settings.get("custom_binds", [])
	binds.append({
		"type": "mouse" if _custom_is_mouse else "key",
		"code": _custom_keycode,
		"mods": _custom_mods,
		"command": _custom_cmd_edit.text.strip_edges(),
	})
	_settings["custom_binds"] = binds
	_save_settings()
	_show_custom_binds()

func _remove_custom_bind(index: int) -> void:
	var binds: Array = _settings.get("custom_binds", [])
	if index >= 0 and index < binds.size():
		binds.remove_at(index)
	_settings["custom_binds"] = binds
	_save_settings()
	_show_custom_binds()

# ── Keybinds ─────────────────────────────────────────────────────────

func _binding_text(action: String) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "None"
	var ev: InputEvent = events[0]
	if ev is InputEventKey:
		var kev := ev as InputEventKey
		var code := kev.physical_keycode
		if code == 0:
			code = kev.keycode
		if code == 0:
			return "None"
		var text := OS.get_keycode_string(code)
		var mods := _mods_to_string(_mods_from_event(kev))
		if mods != "":
			return mods + "+" + text
		return text
	if ev is InputEventMouseButton:
		var text := _mouse_button_name(ev.button_index)
		var mods := _mods_to_string(_mods_from_event(ev))
		if mods != "":
			return mods + "+" + text
		return text
	return "None"

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
		match bind.get("type", ""):
			"mouse":
				var ev := InputEventMouseButton.new()
				ev.button_index = bind.get("button", MOUSE_BUTTON_LEFT)
				_apply_mods(ev, bind.get("mods", {}))
				InputMap.action_erase_events(action)
				InputMap.action_add_event(action, ev)
			"key":
				var code: int = bind.get("code", 0)
				if code != 0:
					var kev := InputEventKey.new()
					kev.physical_keycode = code
					_apply_mods(kev, bind.get("mods", {}))
					InputMap.action_erase_events(action)
					InputMap.action_add_event(action, kev)

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
		var events := InputMap.action_get_events(action)
		if events.is_empty():
			continue
		var ev: InputEvent = events[0]
		if ev is InputEventKey:
			var kev := ev as InputEventKey
			var code := kev.physical_keycode
			if code == 0:
				code = kev.keycode
			if code != 0:
				binds[action] = {"type": "key", "code": code, "mods": _mods_from_event(kev)}
		elif ev is InputEventMouseButton:
			binds[action] = {"type": "mouse", "button": ev.button_index, "mods": _mods_from_event(ev)}
	_settings["keybinds"] = binds
	_save_settings()

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
	if not visible:
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
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, new_event)
	_save_keybinds()
	_waiting_action = ""
	if _keybinds_buttons.has(action):
		_keybinds_buttons[action].text = _binding_text(action)
	get_viewport().set_input_as_handled()
