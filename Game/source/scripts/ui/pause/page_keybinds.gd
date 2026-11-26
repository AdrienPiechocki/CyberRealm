extends Node
## Pages Keybinds et Custom binds : affichage, remappage (clavier/souris et manette), sérialisation.
##
## Module de PauseMenu (nœud enfant « PageKeybinds »), créé par la façade : l'état partagé vit dans la façade
## (`menu`), l'état propre au module vit ici.

const PauseMenu := preload("res://scripts/ui/pause_menu.gd")
var menu: PauseMenu = null

# Actions remappables depuis le menu (ordre d'affichage).
const REMAPPABLE_ACTIONS := [
	"forward", "back", "left", "right", "jump",
	"look_up", "look_down", "look_left", "look_right",
	"interact_mode", "layer_interact", "window_menu", "radial_menu",
	"grab", "focus_window", "pin_window", "kill_window", "hide_window", "share_window",
	"screenshot", "force_game", "release_shortcuts", "freecam", "toggle_tps", "toggle_ui", "chat",
	"emote_wave", "emote_point", "emote_clap", "emote_thumbsup", "emote_laugh", "emote_dance", "emote_sit", "emote_shrug",
	"left_click", "right_click", "middle_click", "scroll_up", "scroll_down",
]
var _cleared_keybinds: Dictionary = {} # action -> {"kb": bool, "pad": bool} (bind passé à None)>
var _custom_cmd_edit: LineEdit = null

func _show_keybinds() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "keybinds"

	menu.container.add_child(menu._make_title("REMAP KEYBINDS"))

	var hint := Label.new()
	hint.text = "Click an action, then press a key/mouse button or gamepad input (Escape/Start = clear this binding)."
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

	menu._keybinds_buttons.clear()
	menu._gamepad_keybinds_buttons.clear()
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

		var btn := menu._make_btn(_binding_text(action))
		btn.custom_minimum_size = Vector2(170, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.pressed.connect(_start_rebind.bind(action, false))
		row.add_child(btn)
		menu._keybinds_buttons[action] = btn

		var gp_btn := menu._make_btn(_gamepad_binding_text(action))
		gp_btn.custom_minimum_size = Vector2(170, 36)
		gp_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		gp_btn.pressed.connect(_start_rebind.bind(action, true))
		row.add_child(gp_btn)
		menu._gamepad_keybinds_buttons[action] = gp_btn

		list.add_child(row)

	menu.container.add_child(menu._make_back_btn())

func _show_custom_binds() -> void:
	menu._clear()
	menu._waiting_action = ""
	menu._current_view = "custom"
	menu._custom_key_waiting = false
	var binds: Array = menu._settings.get("custom_binds", [])
	if menu._editing_index >= 0 and menu._editing_index < binds.size():
		var edit_bind: Dictionary = binds[menu._editing_index]
		menu._custom_is_mouse = String(edit_bind.get("type", "key")) == "mouse"
		menu._custom_keycode = int(edit_bind.get("code", 0))
		menu._custom_mods = edit_bind.get("mods", {})
	else:
		menu._editing_index = -1
		menu._custom_keycode = 0
		menu._custom_is_mouse = false
		menu._custom_mods = {}

	menu.container.add_child(menu._make_title("CUSTOM BINDS"))

	var hint := Label.new()
	hint.text = "A key launches a command.\nHold Ctrl/Shift/Alt/Super for keyboard modifiers."
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

			var launch_btn := menu._make_btn("Launch")
			launch_btn.custom_minimum_size = Vector2(100, 36)
			launch_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			launch_btn.pressed.connect(menu.page_startup_apps._launch_app.bind(String(bind.get("command", ""))))
			row.add_child(launch_btn)

			var edit_btn := menu._make_btn("Edit", "success-button")
			edit_btn.custom_minimum_size = Vector2(90, 36)
			edit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			edit_btn.pressed.connect(_edit_custom_bind.bind(i))
			row.add_child(edit_btn)

			var remove_btn := menu._make_btn("Remove", "remove-button")
			remove_btn.custom_minimum_size = Vector2(90, 36)
			remove_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			remove_btn.pressed.connect(_remove_custom_bind.bind(i))
			row.add_child(remove_btn)

			list.add_child(row)

	var add_row := HBoxContainer.new()
	add_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	menu._custom_key_btn = menu._make_btn(_custom_key_label())
	menu._custom_key_btn.custom_minimum_size = Vector2(110, 36)
	menu._custom_key_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	menu._custom_key_btn.pressed.connect(_start_custom_key_capture)
	add_row.add_child(menu._custom_key_btn)

	_custom_cmd_edit = menu._make_line_edit()
	_custom_cmd_edit.placeholder_text = "command to launch"
	if menu._editing_index >= 0 and menu._editing_index < binds.size():
		_custom_cmd_edit.text = String(binds[menu._editing_index].get("command", ""))
	_custom_cmd_edit.text_submitted.connect(func(_t: String):
		_add_custom_bind()
	)
	add_row.add_child(_custom_cmd_edit)

	var add_btn := menu._make_btn("Save" if menu._editing_index >= 0 else "Add")
	add_btn.custom_minimum_size = Vector2(80, 36)
	add_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_btn.pressed.connect(_add_custom_bind)
	add_row.add_child(add_btn)

	menu.container.add_child(add_row)

	menu.container.add_child(menu._make_back_btn())

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
	if menu._custom_keycode == 0:
		return "Set key"
	if menu._custom_keycode != 0:
		if menu._custom_is_mouse:
			key_text = _mouse_button_name(menu._custom_keycode)
		else:
			key_text = OS.get_keycode_string(menu._custom_keycode)
		var mods := _mods_to_string(menu._custom_mods)
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
	menu._custom_key_waiting = true
	if menu._custom_key_btn:
		menu._custom_key_btn.text = "Press key..."

func _add_custom_bind() -> void:
	if not _custom_cmd_edit or _custom_cmd_edit.text.strip_edges() == "":
		return
	if menu._custom_keycode == 0:
		return
	var binds: Array = menu._settings.get("custom_binds", [])
	var entry := {
		"type": "mouse" if menu._custom_is_mouse else "key",
		"code": menu._custom_keycode,
		"mods": menu._custom_mods,
		"command": _custom_cmd_edit.text.strip_edges(),
	}
	if menu._editing_index >= 0 and menu._editing_index < binds.size():
		binds[menu._editing_index] = entry
	else:
		binds.append(entry)
	menu._settings["custom_binds"] = binds
	menu._editing_index = -1
	menu._save_settings()
	_show_custom_binds()

func _edit_custom_bind(index: int) -> void:
	menu._editing_index = index
	_show_custom_binds()

func _remove_custom_bind(index: int) -> void:
	var binds: Array = menu._settings.get("custom_binds", [])
	if index >= 0 and index < binds.size():
		binds.remove_at(index)
	menu._settings["custom_binds"] = binds
	menu._editing_index = -1
	menu._save_settings()
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
	menu._waiting_action = action
	menu._waiting_gamepad = gamepad
	for a in menu._keybinds_buttons:
		menu._keybinds_buttons[a].text = _binding_text(a)
	for a in menu._gamepad_keybinds_buttons:
		menu._gamepad_keybinds_buttons[a].text = _gamepad_binding_text(a)
	var buttons := menu._gamepad_keybinds_buttons if gamepad else menu._keybinds_buttons
	if buttons.has(action):
		buttons[action].text = "Press gamepad..." if gamepad else "Press key / click..."

## Échap/Start pendant un rebind : passe le bind de la colonne remappée à None
## (clavier/souris retirés pour la colonne KB, pad retiré pour la colonne
## Gamepad) et sauvegarde. L'autre colonne reste intacte.
func _clear_bind() -> void:
	var action := menu._waiting_action
	var gamepad := menu._waiting_gamepad
	menu._waiting_action = ""
	menu._waiting_gamepad = false
	if action == "":
		return
	var cls := "pad" if gamepad else "kb"
	_remove_events_of_class(action, cls)
	_set_cleared(action, cls, true)
	var buttons := menu._gamepad_keybinds_buttons if gamepad else menu._keybinds_buttons
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
	var binds: Dictionary = menu._settings.get("keybinds", {})
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
	menu._settings["keybinds"] = binds
	menu._save_settings()

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
