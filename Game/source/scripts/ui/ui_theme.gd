extends Node
## Moteur de thème CSS pour l'UI de CyberRealm.
## Parse user://style.css (après res://ui/style.css), construit un Theme Godot,
## et recharge automatiquement quand un fichier change.

signal stylesheet_reloaded

const RES_CSS_PATH := "res://ui/style.css"
const USER_CSS_PATH := "user://style.css"

var theme: Theme
var _rules: Array = []
var _stylebox_cache: Dictionary = {}
var _res_mtime := -1
var _user_mtime := -1
var _watch_timer := 0.0

func _ready() -> void:
	load_css()

func _process(delta: float) -> void:
	_watch_timer -= delta
	if _watch_timer > 0.0:
		return
	_watch_timer = 0.5
	if _file_mtime(RES_CSS_PATH) != _res_mtime or _file_mtime(USER_CSS_PATH) != _user_mtime:
		load_css()

func _file_mtime(path: String) -> int:
	var t := FileAccess.get_modified_time(path)
	return t if t > 0 else -1

func load_css() -> void:
	_res_mtime = _file_mtime(RES_CSS_PATH)
	_user_mtime = _file_mtime(USER_CSS_PATH)
	_rules.clear()
	_stylebox_cache.clear()
	theme = Theme.new()
	var err := parse(FileAccess.get_file_as_string(RES_CSS_PATH), RES_CSS_PATH)
	if err != "":
		push_error("UITheme(" + RES_CSS_PATH + "): " + err)
	err = parse(FileAccess.get_file_as_string(USER_CSS_PATH), USER_CSS_PATH)
	if err != "":
		push_error("UITheme(" + USER_CSS_PATH + "): " + err)
	_rebuild_theme()
	stylesheet_reloaded.emit()

## Parse des règles CSS « subset ». Retourne "" ou un message d'erreur.
func parse(css_text: String, source := "") -> String:
	if css_text == "":
		return ""
	var text := css_text.replace("/*", "\u2028").replace("*/", "\u2028")
	var chunks := text.split("\u2028")
	var cleaned := ""
	for i in chunks.size():
		if i % 2 == 0:
			cleaned += chunks[i]
	var idx := 0
	while idx < cleaned.length():
		var open := cleaned.find("{", idx)
		if open == -1:
			break
		var close := cleaned.find("}", open)
		if close == -1:
			return (source + ": block ouvert jamais fermé") if source != "" else "block ouvert jamais fermé"
		var selector := cleaned.substr(idx, open - idx).strip_edges()
		if selector == "":
			return (source + ": sélecteur vide") if source != "" else "sélecteur vide"
		var rule: Variant = _parse_selector(selector)
		if rule == null:
			return (source + ": sélecteur invalide « " + selector + " »") if source != "" else "sélecteur invalide"
		rule["props"] = _parse_declarations(cleaned.substr(open + 1, close - open - 1))
		_rules.append(rule)
		idx = close + 1
	return ""

func _parse_selector(selector: String) -> Variant:
	var pseudo := ""
	var klass := ""
	var element := ""
	var s := selector.strip_edges()
	var p := s.find(":")
	if p != -1:
		pseudo = s.substr(p + 1).strip_edges()
		s = s.substr(0, p)
	var c := s.find(".")
	if c != -1:
		klass = s.substr(c + 1).strip_edges()
		s = s.substr(0, c)
	element = s.strip_edges()
	if element == "" and klass == "" and pseudo == "":
		return null
	return {"element": element.to_lower(), "class_name": klass, "pseudo": pseudo, "props": {}}

func _parse_declarations(body: String) -> Dictionary:
	var props: Dictionary = {}
	for decl in body.split(";"):
		var d := decl.strip_edges()
		if d == "":
			continue
		var sep := d.find(":")
		if sep == -1:
			continue
		var name := d.substr(0, sep).strip_edges().to_lower()
		var value := d.substr(sep + 1).strip_edges()
		if name != "" and value != "":
			props[name] = value
	return props

func _rebuild_theme() -> void:
	if theme == null:
		theme = Theme.new()
	for key in _STYLES:
		var element: String = key
		var godot_type := _godot_theme_type(element)
		for state in _STYLES[key]:
			var sb := get_stylebox(element, state)
			var item: String = "panel" if element == "panel" else state
			for tt in godot_type:
				theme.set_stylebox(tt, item, sb)
		var fp := _element_state_props(element, "normal")
		if fp.has("font-size"):
			var fs := int(_parse_num(fp["font-size"]))
			if fs > 0:
				for tt in godot_type:
					theme.set_font_size(tt, "font_size", fs)
		if fp.has("color"):
			var c := _parse_color(fp["color"])
			if c.a >= 0.0:
				for tt in godot_type:
					theme.set_color(tt, "font_color", c)
	for r in _rules:
		var rl: Dictionary = r
		var element: String = rl["element"]
		if element == "":
			continue
		var godot_type := _godot_theme_type(element)
		if godot_type.is_empty():
			continue
		var fp := _element_state_props(element, "normal")
		if fp.has("font-size"):
			var fs := int(_parse_num(fp["font-size"]))
			if fs > 0:
				for tt in godot_type:
					theme.set_font_size(tt, "font_size", fs)
		if fp.has("color"):
			var c := _parse_color(fp["color"])
			if c.a >= 0.0:
				for tt in godot_type:
					theme.set_color(tt, "font_color", c)

func get_color(element: String, prop: String, default: Color) -> Color:
	var v := _prop_value(element, prop)
	if v == "":
		return default
	var c := _parse_color(v)
	return c if c.a >= 0.0 else default

func get_number(element: String, prop: String, default: float) -> float:
	var v := _prop_value(element, prop)
	if v == "":
		return default
	var n := _parse_num(v)
	return default if is_nan(n) else n

func get_string(element: String, prop: String, default: String) -> String:
	var v := _prop_value(element, prop)
	return default if v == "" else v

func _prop_value(element: String, prop: String) -> String:
	for i in range(_rules.size() - 1, -1, -1):
		var r: Dictionary = _rules[i]
		if r["pseudo"] != "":
			continue
		if r["element"] != "" and r["element"] != element:
			continue
		if r["class_name"] != "":
			continue
		if r["props"].has(prop):
			return r["props"][prop]
	return ""

## Parse une couleur : #rgb, #rrggbb, #rrggbbaa, rgb(), rgba().
func _parse_color(v: String) -> Color:
	var s := v.strip_edges()
	if s.begins_with("#"):
		var hex := s.substr(1).strip_edges()
		match hex.length():
			3:
				var expanded := hex[0].repeat(2) + hex[1].repeat(2) + hex[2].repeat(2)
				return Color.from_string(expanded, Color(-1, -1, -1, -1))
			6, 8:
				return Color.from_string(hex, Color(-1, -1, -1, -1))
		return Color(-1, -1, -1, -1)
	if s.begins_with("rgb"):
		var inner := s.substr(s.find("(") + 1, s.rfind(")") - s.find("(") - 1)
		var parts := inner.split(",")
		if parts.size() < 3 or parts.size() > 4:
			return Color(-1, -1, -1, -1)
		var r := _chan(parts[0])
		var g := _chan(parts[1])
		var b := _chan(parts[2])
		var a := 1.0
		if parts.size() == 4:
			var av := parts[3].strip_edges()
			a = _parse_num(av) if av.find(".") != -1 else _chan(av)
		if is_nan(r) or is_nan(g) or is_nan(b) or is_nan(a):
			return Color(-1, -1, -1, -1)
		return Color(r, g, b, a)
	return Color(-1, -1, -1, -1)

func _chan(s: String) -> float:
	return _parse_num(s.strip_edges()) / 255.0

## Parse un nombre avec suffixe px optionnel. NAN si invalide.
## NB: float("abc") == 0.0 en Godot (coercition permissive) — is_valid_float est
## indispensable, sinon toute valeur CSS invalide deviendrait 0 au lieu du défaut.
func _parse_num(v: String) -> float:
	var s := v.strip_edges()
	if s.ends_with("px"):
		s = s.substr(0, s.length() - 2).strip_edges()
	if not s.is_valid_float():
		return NAN
	return float(s)

const _STYLES := {"button": ["normal", "hover", "pressed", "focus"], "line-edit": ["normal"], "panel": ["panel"]}

func get_stylebox(element: String, state: String) -> StyleBoxFlat:
	var key := element + "/" + state
	if _stylebox_cache.has(key):
		return _stylebox_cache[key]
	var sb := _build_stylebox(element, state)
	_stylebox_cache[key] = sb
	return sb

func _build_stylebox(element: String, state: String) -> StyleBoxFlat:
	var normal := _element_state_props(element, "normal")
	var base: StyleBoxFlat = null
	if _has_stylebox_props(normal):
		base = StyleBoxFlat.new()
		_apply_stylebox_props(base, normal)
	var props := normal.duplicate()
	for k in _element_state_props(element, state):
		props[k] = _element_state_props(element, state)[k]
	var set := StyleBoxFlat.new()
	if base != null:
		set = base.duplicate()
	_apply_stylebox_props(set, props)
	return set

func _has_stylebox_props(props: Dictionary) -> bool:
	for k in props:
		if _is_stylebox_prop(k):
			return true
	return false

func _is_stylebox_prop(name: String) -> bool:
	return name in ["background-color", "border-color", "border-width",
		"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
		"corner-radius", "corner-top-left-radius", "corner-top-right-radius",
		"corner-bottom-left-radius", "corner-bottom-right-radius",
		"padding", "padding-left", "padding-right", "padding-top", "padding-bottom"]

func _apply_stylebox_props(sb: StyleBoxFlat, props: Dictionary) -> void:
	if props.has("background-color"):
		var c := _parse_color(props["background-color"])
		if c.a >= 0.0:
			sb.bg_color = c
	if props.has("border-color"):
		var bc := _parse_color(props["border-color"])
		if bc.a >= 0.0:
			sb.border_color = bc
	var w: String = props.get("border-width", "")
	if w != "":
		var sides := _split_4(w)
		sb.border_width_top = sides[0]
		sb.border_width_bottom = sides[1]
		sb.border_width_left = sides[2]
		sb.border_width_right = sides[3]
	if props.has("border-top-width"):
		sb.border_width_top = int(_parse_num(props["border-top-width"]))
	if props.has("border-bottom-width"):
		sb.border_width_bottom = int(_parse_num(props["border-bottom-width"]))
	if props.has("border-left-width"):
		sb.border_width_left = int(_parse_num(props["border-left-width"]))
	if props.has("border-right-width"):
		sb.border_width_right = int(_parse_num(props["border-right-width"]))
	var cr: String = props.get("corner-radius", "")
	if cr != "":
		var r := _split_4(cr)
		sb.corner_radius_top_left = int(r[0])
		sb.corner_radius_bottom_left = int(r[1])
		sb.corner_radius_top_right = int(r[2])
		sb.corner_radius_bottom_right = int(r[3])
	if props.has("corner-top-left-radius"):
		sb.corner_radius_top_left = int(_parse_num(props["corner-top-left-radius"]))
	if props.has("corner-bottom-left-radius"):
		sb.corner_radius_bottom_left = int(_parse_num(props["corner-bottom-left-radius"]))
	if props.has("corner-top-right-radius"):
		sb.corner_radius_top_right = int(_parse_num(props["corner-top-right-radius"]))
	if props.has("corner-bottom-right-radius"):
		sb.corner_radius_bottom_right = int(_parse_num(props["corner-bottom-right-radius"]))
	var pad: String = props.get("padding", "")
	if pad != "":
		var p := _split_4(pad)
		sb.content_margin_left = int(p[2])
		sb.content_margin_right = int(p[3])
		sb.content_margin_top = int(p[0])
		sb.content_margin_bottom = int(p[1])
	if props.has("padding-top"):
		sb.content_margin_top = int(_parse_num(props["padding-top"]))
	if props.has("padding-bottom"):
		sb.content_margin_bottom = int(_parse_num(props["padding-bottom"]))
	if props.has("padding-left"):
		sb.content_margin_left = int(_parse_num(props["padding-left"]))
	if props.has("padding-right"):
		sb.content_margin_right = int(_parse_num(props["padding-right"]))

## 1 valeur = tout ; 2 = [vert, horiz] ; 4 = [top, right, bottom, left].
func _split_4(v: String) -> Array:
	var parts := _split_ws(v)
	if parts.size() == 1:
		return [parts[0], parts[0], parts[0], parts[0]]
	if parts.size() == 2:
		return [parts[0], parts[0], parts[1], parts[1]]
	return [parts[0], parts[2], parts[3], parts[1]]

func _split_ws(v: String) -> Array:
	var out: Array = []
	for p in v.split(" "):
		var t := p.strip_edges()
		if t != "":
			out.append(_parse_num(t))
	return out

## Une règle sans pseudo est l'état "normal". Les règles avec classe sont
## exclues (elles s'appliquent via apply_class).
func _element_state_props(element: String, state: String) -> Dictionary:
	var out: Dictionary = {}
	for r in _rules:
		var rl: Dictionary = r
		if rl["element"] != element or rl["class_name"] != "":
			continue
		if rl["pseudo"] != state and not (state == "normal" and rl["pseudo"] == ""):
			continue
		for k in rl["props"]:
			out[k] = rl["props"][k]
	return out

func _godot_theme_type(element: String) -> Array:
	match element:
		"button": return ["Button"]
		"label": return ["Label"]
		"line-edit": return ["LineEdit"]
		"check-button": return ["CheckButton"]
		"option-button": return ["OptionButton"]
		"slider": return ["Slider", "HSlider", "VSlider"]
		"scroll": return ["ScrollContainer"]
		"panel": return ["Panel", "PanelContainer"]
	return []

func _element_of(control: Control) -> String:
	if control is Button:
		return "button"
	if control is LineEdit:
		return "line-edit"
	if control is PanelContainer or control is Panel:
		return "panel"
	if control is Label:
		return "label"
	return ""

func apply_class(control: Control, klass: String) -> void:
	if klass == "":
		return
	for token in klass.split(" "):
		if token != "":
			_apply_one_class(control, token)

func _apply_one_class(control: Control, klass: String) -> void:
	var element := _element_of(control)
	for state in ["normal", "hover", "pressed", "focus"]:
		var props := _class_state_props(element, klass, state)
		if props.is_empty():
			continue
		if _has_stylebox_props(props):
			var item: String = "panel" if (control is Panel or control is PanelContainer) and state == "normal" else state
			control.add_theme_stylebox_override(item, _build_stylebox_class(element, klass, state))
		if props.has("color"):
			var c := _parse_color(props["color"])
			if c.a >= 0.0:
				control.add_theme_color_override("font_color", c)
		if props.has("font-size"):
			control.add_theme_font_size_override("font_size", int(_parse_num(props["font-size"])))
		if props.has("separation") and control is BoxContainer:
			(control as BoxContainer).add_theme_constant_override("separation", int(_parse_num(props["separation"])))
	var normal := _class_state_props(element, klass, "normal")
	if _has_margin_prop(normal):
		_apply_margins(control, normal)

## Une classe : la règle compound element.class d'abord (si elle matche le
## type du contrôle), sinon la règle .class nue. La dernière en ordre gagne.
func _class_state_props(element: String, klass: String, state: String) -> Dictionary:
	var out: Dictionary = {}
	for r in _rules:
		var rl: Dictionary = r
		if rl["class_name"] != klass:
			continue
		if rl["element"] != "" and rl["element"] != element:
			continue
		if rl["pseudo"] != state and not (state == "normal" and rl["pseudo"] == ""):
			continue
		for k in rl["props"]:
			out[k] = rl["props"][k]
	return out

func _build_stylebox_class(element: String, klass: String, state: String) -> StyleBoxFlat:
	var base := _build_stylebox(element, state)
	var props := _class_state_props(element, klass, state)
	_apply_stylebox_props(base, props)
	return base

func _has_margin_prop(props: Dictionary) -> bool:
	return props.has("margin") or props.has("margin-top") or props.has("margin-right") \
		or props.has("margin-bottom") or props.has("margin-left")

## Applique les marges : ancre pleine vue + offsets négatifs. La taille du
## contrôle devient (vue - marges) ; hors du cadre, l'input n'est pas capté.
func _apply_margins(control: Control, props: Dictionary) -> void:
	var ref := _size_ref(control)
	var t := 0.0
	var r := 0.0
	var b := 0.0
	var l := 0.0
	if props.has("margin"):
		var sides := _split_4_margin(props["margin"])  # [top, bottom, left, right]
		t = _parse_len(sides[0], ref.y)
		b = _parse_len(sides[1], ref.y)
		l = _parse_len(sides[2], ref.x)
		r = _parse_len(sides[3], ref.x)
	if props.has("margin-top"):
		t = _parse_len(props["margin-top"], ref.y)
	if props.has("margin-right"):
		r = _parse_len(props["margin-right"], ref.x)
	if props.has("margin-bottom"):
		b = _parse_len(props["margin-bottom"], ref.y)
	if props.has("margin-left"):
		l = _parse_len(props["margin-left"], ref.x)
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = l
	control.offset_top = t
	control.offset_right = -r
	control.offset_bottom = -b

## Référence de taille pour les % : parent Control si présent (taille > 0),
## sinon la vue, sinon un défaut raisonnable hors arbre (tests).
func _size_ref(control: Control) -> Vector2:
	var parent := control.get_parent()
	if parent is Control:
		var ps := (parent as Control).size
		if ps.x > 0.0 and ps.y > 0.0:
			return ps
	if control.is_inside_tree():
		return control.get_viewport_rect().size
	return Vector2(1920, 1080)

## Longueur CSS : "Npx" ou "N%" (% de la référence). Invalide → 0.0.
func _parse_len(v: String, ref: float) -> float:
	var s := v.strip_edges()
	if s.ends_with("%"):
		var n := _parse_num(s.substr(0, s.length() - 1).strip_edges())
		return n / 100.0 * ref if not is_nan(n) else 0.0
	var n := _parse_num(s)
	return n if not is_nan(n) else 0.0

## Shorthand margin 1/2/4 → [top, bottom, left, right] (chaînes brutes).
func _split_4_margin(v: String) -> Array:
	var parts := _split_ws_str(v)
	if parts.size() == 1:
		return [parts[0], parts[0], parts[0], parts[0]]
	if parts.size() == 2:
		return [parts[0], parts[0], parts[1], parts[1]]
	return [parts[0], parts[2], parts[3], parts[1]]

func _split_ws_str(v: String) -> Array:
	var out: Array = []
	for p in v.split(" "):
		var t := p.strip_edges()
		if t != "":
			out.append(t)
	return out

func apply_css(root: Control) -> void:
	_walk_css(root)

func _walk_css(node: Node) -> void:
	if node is Control:
		var c: String = (node as Control).get_meta("ui_class", "") if (node as Control).has_meta("ui_class") else ""
		if c != "":
			apply_class(node, c)
	for child in node.get_children():
		_walk_css(child)