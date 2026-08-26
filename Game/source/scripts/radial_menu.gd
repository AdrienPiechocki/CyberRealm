extends GameMenu
class_name RadialMenu
## Menu radial contextuel (style anneau/segments).
## B toggle l'ouverture, stick gauche pour naviguer, A pour valider, ECHAP pour quitter.

signal radial_action(action: String)

# Géométrie
const RADIUS := 180.0
const RING_WIDTH := 50.0
const CENTER_RADIUS := 100.0
const GAP_SIZE := 4.0
const SELECTOR_WIDTH := 5.0
const DECORATOR_WIDTH := 4.0
const STICK_DEADZONE := 0.35

# Couleurs (thème dark du projet de référence)
const BG_COLOR := Color(0.125, 0.125, 0.125, 0.9)
const SELECTED_BG := Color(0.22, 0.58, 0.89, 0.9)
const STROKE_COLOR := Color(0.16, 0.32, 0.48, 1.0)
const SELECTOR_COLOR := Color(0.53, 0.78, 1.0, 1.0)
const DECORATOR_COLOR := Color(0.0, 0.45, 0.73, 1.0)
const CENTER_BG := Color(0.098, 0.098, 0.098, 0.83)
const CENTER_STROKE := Color(0.19, 0.56, 0.78, 1.0)
const TITLE_COLOR := Color(0.55, 0.55, 0.55, 1.0)

var _items: Array[Dictionary] = []
var _selected_index: int = 0
var _is_open := false
var _open_scale := 0.0
var _center_offset := Vector2.ZERO
var _emoji_font: Font


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Charger une police supportant les emoji (disponible via fontconfig)
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Noto Color Emoji", "DejaVu Sans", "Noto Sans Symbols 2"])
	_emoji_font = sf


func _can_stick_input() -> bool:
	return false


func show_menu(context: String, target_wid: int = -1, binds: Array = []) -> void:
	_build_items(context, target_wid, binds)
	_selected_index = 0
	_is_open = true
	_open_scale = 0.0
	_calc_geometry()
	visible = true
	queue_redraw()


func hide_menu() -> void:
	_is_open = false
	visible = false
	_items.clear()
	_selected_index = 0
	queue_redraw()


func _build_items(context: String, _target_wid: int = -1, binds: Array = []) -> void:
	_items.clear()
	match context:
		"fps":
			_items.append({label = "WINDOW MENU", emoji = "🪟", action = "window_menu"})
			_items.append({label = "MOUSE MODE", emoji = "🖱️", action = "layer_interact"})
			_items.append({label = "KEYBOARD MODE", emoji = "⌨️", action = "interact"})
			_items.append({label = "BINDS", emoji = "🎮", action = "binds"})
		"window":
			_items.append({label = "WINDOW MENU", emoji = "🪟", action = "window_menu"})
			_items.append({label = "MOUSE MODE", emoji = "🖱️", action = "layer_interact"})
			_items.append({label = "KEYBOARD MODE", emoji = "⌨️", action = "interact"})
			_items.append({label = "BINDS", emoji = "🎮", action = "binds"})
			_items.append({label = "GRAB", emoji = "✊", action = "grab"})
			_items.append({label = "FOCUS", emoji = "🔍", action = "focus"})
			_items.append({label = "HIDE", emoji = "🫣", action = "hide"})
			_items.append({label = "KILL", emoji = "💀", action = "kill"})
			_items.append({label = "PIN", emoji = "📌", action = "pin"})
			_items.append({label = "SHARE", emoji = "🔗", action = "share"})
		"focus":
			_items.append({label = "EXIT FOCUS", emoji = "↩️", action = "exit_focus"})
			_items.append({label = "VIRTUAL KEYBOARD", emoji = "⌨️", action = "keyboard"})
			_items.append({label = "KILL", emoji = "💀", action = "kill_focused"})
		"binds":
			if binds.size() > 0:
				for bind in binds:
					var cmd: String = bind.get("command", "")
					var label := ""
					var emoji := "⌨️"
					var code: int = bind.get("code", 0)
					var is_mouse: bool = bind.get("type", "") == "mouse"
					if is_mouse:
						emoji = "🖱️"
						label = "Mouse %d" % code
					else:
						var mods: Dictionary = bind.get("mods", {})
						var mod_str := ""
						if mods.get("ctrl", false): mod_str += "Ctrl+"
						if mods.get("shift", false): mod_str += "Shift+"
						if mods.get("alt", false): mod_str += "Alt+"
						if mods.get("super", false): mod_str += "Super+"
						label = mod_str + OS.get_keycode_string(code)
					_items.append({label = label, emoji = emoji, action = "bind:" + cmd})
			else:
				hide_menu()


func _calc_geometry() -> void:
	var n := _items.size()
	if n == 0:
		return
	# Le control est full-rect, donc le centre local = centre de l'écran
	_center_offset = size / 2.0


func _process(delta: float) -> void:
	if not _is_open:
		return

	# Animation d'ouverture (toujours, avant les early returns)
	if _open_scale < 1.0:
		_open_scale = minf(_open_scale + delta * 12.0, 1.0)
		queue_redraw()

	# ECHAP : fermer sans valider (PAS B — B est géré par wayland_room pour le toggle)
	if Input.is_action_just_pressed("ui_cancel", true) and not Input.is_joy_button_pressed(0, JOY_BUTTON_B):
		hide_menu()
		return

	# A pour confirmer la sélection
	if Input.is_action_just_pressed("ui_accept", true):
		if _selected_index >= 0 and _selected_index < _items.size():
			var action_name: String = _items[_selected_index].action
			hide_menu()
			radial_action.emit(action_name)
		else:
			hide_menu()
		return

	# Stick gauche : sélection par angle, garde la dernière sélection au centre
	var stick := Vector2(
		Input.get_joy_axis(0, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	)
	if stick.length() < STICK_DEADZONE:
		return

	# atan2(y, x) : 0 = droite, PI/2 = bas, PI = gauche, 3PI/2 = haut
	# Correspond à la convention de dessin (cos, sin) dans les coords écran.
	var angle := atan2(stick.y, stick.x)
	if angle < 0:
		angle += TAU

	var n := _items.size()
	var item_angle := TAU / float(n)
	# start_angle = premier bord de l'item 0 (haut, sens horaire)
	var start_angle := -PI / 2.0 - item_angle * (n / 2.0)
	var rel_angle := fmod(angle - start_angle + TAU, TAU)
	var index := int(rel_angle / item_angle) % n
	if index != _selected_index:
		_selected_index = index
		queue_redraw()


func _input(event: InputEvent) -> void:
	if not _is_open:
		return
	# Laisser B et A passer pour le toggle et la validation
	if event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_B or event.button_index == JOY_BUTTON_A:
			return
	# Laisser ECHAP passer
	if event is InputEventKey and event.keycode == KEY_ESCAPE:
		return
	# Consommer le reste
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion:
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if not _is_open or _items.is_empty():
		return

	var n := _items.size()
	var item_angle := TAU / float(n)
	var ease := _ease_out_cubic(_open_scale)
	if ease < 0.05:
		return
	var s := maxf(ease, 0.01)
	var inner := (RADIUS - RING_WIDTH - SELECTOR_WIDTH - DECORATOR_WIDTH) * s
	var outer := (RADIUS - SELECTOR_WIDTH - DECORATOR_WIDTH) * s
	var half_n := n / 2.0
	var start_angle := -PI / 2.0 - item_angle * half_n

	# 1. Decorator ring
	for i in range(n):
		var sa := start_angle + i * item_angle
		var ea := start_angle + (i + 1) * item_angle
		var dec_inner := inner - DECORATOR_WIDTH * s
		var dec_outer := inner
		var coords: PackedVector2Array
		if _has_gaps():
			coords = _calc_faux_ring_segment(dec_inner, dec_outer, GAP_SIZE * 0.5, sa, ea, _center_offset)
		else:
			coords = _calc_ring_segment(dec_inner, dec_outer, sa, ea, _center_offset)
		if coords.size() >= 3:
			_draw_poly(coords, DECORATOR_COLOR)

	# 2. Item ring segments
	for i in range(n):
		var sa := start_angle + i * item_angle
		var ea := start_angle + (i + 1) * item_angle
		var bg := SELECTED_BG if i == _selected_index else BG_COLOR
		var stroke := SELECTOR_COLOR if i == _selected_index else STROKE_COLOR
		var coords: PackedVector2Array
		if _has_gaps():
			coords = _calc_faux_ring_segment(inner, outer, GAP_SIZE, sa, ea, _center_offset)
		else:
			coords = _calc_ring_segment(inner, outer, sa, ea, _center_offset)
		if coords.size() >= 3:
			_draw_poly(coords, bg)
			_draw_polyline(coords, stroke, 1.0)

	# 2.5. Emojis on ring segments
	var emoji_size := 20
	for i in range(n):
		var emoji_text: String = _items[i].get("emoji", "")
		if emoji_text.is_empty():
			continue
		var mid_angle := start_angle + (i + 0.5) * item_angle
		var mid_radius := (inner + outer) * 0.5
		var emoji_pos := Vector2(cos(mid_angle), sin(mid_angle)) * mid_radius * s + _center_offset
		var es := _emoji_font.get_string_size(emoji_text, HORIZONTAL_ALIGNMENT_CENTER, -1, emoji_size)
		draw_string(_emoji_font, emoji_pos - Vector2(es.x / 2.0, -es.y / 2.5), emoji_text, HORIZONTAL_ALIGNMENT_LEFT, -1, emoji_size, Color.WHITE)

	# 3. Selector ring segment
	if _selected_index >= 0 and _selected_index < n:
		var sa := start_angle + _selected_index * item_angle
		var ea := start_angle + (_selected_index + 1) * item_angle
		var sel_inner := outer
		var sel_outer := outer + SELECTOR_WIDTH * s
		var coords := _calc_ring_segment(sel_inner, sel_outer, sa, ea, _center_offset)
		if coords.size() >= 3:
			_draw_poly(coords, SELECTOR_COLOR)

	# 4. Center circle
	var center_r := CENTER_RADIUS * s
	draw_circle(_center_offset, center_r, CENTER_BG)
	draw_arc(_center_offset, center_r, 0, TAU, int(center_r), CENTER_STROKE, 2.0, true)

	# 5. Titre de l'item sélectionné dans le centre
	if _selected_index >= 0 and _selected_index < _items.size():
		var label: String = _items[_selected_index].label
		var font := ThemeDB.fallback_font
		var font_size := 14
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var max_text_w := center_r * 1.6
		if text_size.x < max_text_w:
			var pos := _center_offset - Vector2(text_size.x / 2.0, -font.get_descent())
			draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TITLE_COLOR)
		else:
			var words := label.split(" ")
			var line := ""
			var lines: PackedStringArray = []
			for w in words:
				var test := line + (" " if line != "" else "") + w
				if font.get_string_size(test, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x < max_text_w:
					line = test
				else:
					if line != "":
						lines.append(line)
					line = w
			if line != "":
				lines.append(line)
			if lines.is_empty():
				lines.append("...")
			var total_h := lines.size() * (font_size + 2)
			var y_start := _center_offset.y - total_h / 2.0 + font_size
			for li in lines.size():
				var ls := font.get_string_size(lines[li], HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
				var pos := Vector2(_center_offset.x - ls.x / 2.0, y_start + li * (font_size + 2))
				draw_string(font, pos, lines[li], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, TITLE_COLOR)


# ── Drawing helpers ────────────────────────────────────────────────

func _has_gaps() -> bool:
	return GAP_SIZE > 0 and _items.size() > 2


func _draw_poly(coords: PackedVector2Array, color: Color) -> void:
	if coords.size() < 3:
		return
	draw_colored_polygon(coords, color)


func _draw_polyline(coords: PackedVector2Array, color: Color, w: float) -> void:
	if coords.size() < 2:
		return
	draw_polyline(coords, color, w, true)
	draw_line(coords[-1], coords[0], color, w, true)


func _calc_ring_segment(inner: float, outer: float, start: float, end: float, offset: Vector2) -> PackedVector2Array:
	if abs(outer - inner) < 0.5 or outer < 1.0:
		return PackedVector2Array()
	var coords := PackedVector2Array()
	var n_outer = max(2, int(outer * abs(end - start) / TAU))
	var n_inner = max(2, int(inner * abs(end - start) / TAU))
	var step := (end - start) / float(n_outer)
	for i in range(n_outer + 1):
		var a := start + i * step
		coords.append(Vector2(cos(a), sin(a)) * outer + offset)
	step = (end - start) / float(n_inner)
	for i in range(n_inner + 1):
		var a := end - i * step
		coords.append(Vector2(cos(a), sin(a)) * inner + offset)
	return coords


func _calc_faux_ring_segment(inner: float, outer: float, sep: float, start: float, end: float, offset: Vector2) -> PackedVector2Array:
	if abs(outer - inner) < 0.5 or outer < 1.0:
		return PackedVector2Array()
	var sep_inner := asin(clampf(sep / maxf(inner, 0.1), -1.0, 1.0))
	var sep_outer := asin(clampf(sep / maxf(outer, 0.1), -1.0, 1.0))
	var limit := 0.18 * (end - start)
	sep_inner = minf(sep_inner, limit)
	sep_outer = minf(sep_outer, limit)
	var inner_start := start + sep_inner
	var inner_end := end - sep_inner
	var outer_start := start + sep_outer
	var outer_end := end - sep_outer
	var coords := PackedVector2Array()
	var n_outer = max(2, int(outer * (outer_end - outer_start) / TAU))
	var step := (outer_end - outer_start) / float(n_outer)
	for i in range(n_outer + 1):
		var a := outer_start + i * step
		coords.append(Vector2(cos(a), sin(a)) * outer + offset)
	var n_inner = max(2, int(inner * (inner_end - inner_start) / TAU))
	step = (inner_end - inner_start) / float(n_inner)
	for i in range(n_inner + 1):
		var a := inner_end - i * step
		coords.append(Vector2(cos(a), sin(a)) * inner + offset)
	return coords


func _ease_out_cubic(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)
