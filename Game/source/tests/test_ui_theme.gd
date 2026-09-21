extends Node
## Tests du moteur de thème CSS.
const Runner = preload("res://tests/runner.gd")
const UIThemeScript = preload("res://scripts/ui/ui_theme.gd")

var _t: Node

func _init() -> void:
	_t = UIThemeScript.new()

## Le runner réutilise UNE instance par fichier pour tous les test_* : _rules
## s'accumule entre les tests. Chaque test démarre donc sur une instance neuve.
func _reset() -> void:
	_t = UIThemeScript.new()

func test_parse_and_rules() -> Variant:
	_reset()
	var err: String = _t.parse("button { background-color: #1f2433; }\nlabel.title { font-size: 22px; color: rgba(230,235,242,.95); }")
	if err != "":
		return "parse: " + err
	if _t._rules.size() != 2:
		return "rule count: %d" % _t._rules.size()
	var r: Dictionary = _t._rules[0]
	if r["element"] != "button" or r["class_name"] != "" or r["pseudo"] != "":
		return "rule0 selector mis-parsed"
	if _t._rules[1]["element"] != "label" or _t._rules[1]["class_name"] != "title":
		return "rule1 selector mis-parsed"
	if _t._rules[0]["props"]["background-color"] != "#1f2433":
		return "rule0 props"
	return Runner.assert_eq(_t._rules[1]["props"]["font-size"], "22px")

func test_comments_stripped() -> Variant:
	_reset()
	var err: String = _t.parse("/* un commentaire */\n.c { x: y; } /* fin */")
	if err != "":
		return "parse: " + err
	return Runner.assert_eq(_t._rules.size(), 1)

func test_invalid_selector_reports_error() -> Variant:
	_reset()
	var err: String = _t.parse("   { background-color: #fff; }")
	return Runner.assert_ne(err, "")

func test_later_rules_win() -> Variant:
	_reset()
	_t.parse("button { background-color: #111111; }\nbutton { background-color: #222222; }")
	var props: Dictionary = _t._rules[1]["props"]
	return Runner.assert_eq(props["background-color"], "#222222")

func test_theme_built_on_load() -> Variant:
	_reset()
	_t.parse("button { background-color: #1f2433; }")
	_t.theme = Theme.new()
	_t._rebuild_theme()
	if _t._stylebox_cache.is_empty():
		return "cache vide"
	return Runner.assert_ne(_t.theme, null)

func test_get_number_and_hex_short() -> Variant:
	_reset()
	_t.parse("radial { ring-radius: 180px; ring-color: #123456; }")
	var r = Runner.assert_eq(_t.get_number("radial", "ring-radius", -1.0), 180.0)
	if r != true:
		return r
	return Runner.assert_eq(_t.get_color("radial", "ring-color", Color(-1, -1, -1, -1)), Color(0x12 / 255.0, 0x34 / 255.0, 0x56 / 255.0))

func test_rgba_and_alpha_modes() -> Variant:
	_reset()
	_t.parse("a { c: rgba(15,15,20,.95); }")
	var bad := Color(-1, -1, -1, -1)
	var c: Color = _t.get_color("a", "c", bad)
	if absf(c.r - 15.0 / 255.0) > 0.001 or absf(c.g - 15.0 / 255.0) > 0.001 or absf(c.b - 20.0 / 255.0) > 0.001 or absf(c.a - 0.95) > 0.001:
		return "rgba float alpha: %s" % c
	_t.parse("b { c: rgba(255,255,255,128); }")
	var c2: Color = _t.get_color("b", "c", bad)
	if absf(c2.a - 128.0 / 255.0) > 0.001:
		return "rgba 255 alpha: %s" % c2
	return true

func test_getters_defaults() -> Variant:
	_reset()
	var r = Runner.assert_eq(_t.get_number("radial", "missing", 42.0), 42.0)
	if r != true:
		return r
	var bad := Color(-1, -1, -1, -1)
	var r2 = Runner.assert_eq(_t.get_color("radial", "missing", bad), bad)
	if r2 != true:
		return r2
	return Runner.assert_eq(_t.get_string("radial", "missing", "d"), "d")

func test_bare_class_ignored_by_getter() -> Variant:
	_reset()
	_t.parse(".title { font-size: 22px; }")
	return Runner.assert_eq(_t.get_number("title", "font-size", -1.0), -1.0)

## Régression : float("abc") == 0.0 (coercition permissive Godot), donc les
## valeurs invalides doivent tomber sur le défaut, pas devenir 0/noir.
func test_invalid_values_use_default() -> Variant:
	_reset()
	_t.parse("x { n: abc; c: #f0z; d: rgb(abc,1,1); }")
	var r = Runner.assert_eq(_t.get_number("x", "n", 42.0), 42.0)
	if r != true:
		return r
	var bad := Color(-1, -1, -1, -1)
	var r2 = Runner.assert_eq(_t.get_color("x", "c", bad), bad)
	if r2 != true:
		return r2
	return Runner.assert_eq(_t.get_color("x", "d", bad), bad)

func test_stylebox_normal_and_hover() -> Variant:
	_reset()
	_t.parse("button { background-color: #111111; corner-radius: 5px; padding: 8px 14px; }\nbutton:hover { background-color: #2e3859; }")
	var n: StyleBoxFlat = _t.get_stylebox("button", "normal")
	if n.bg_color != Color(0x11 / 255.0, 0x11 / 255.0, 0x11 / 255.0):
		return "normal bg: %s" % n.bg_color
	if n.corner_radius_top_left != 5:
		return "normal radius: %d" % n.corner_radius_top_left
	if n.content_margin_left != 14 or n.content_margin_right != 14 or n.content_margin_top != 8:
		return "normal padding: %s" % n
	var h: StyleBoxFlat = _t.get_stylebox("button", "hover")
	if h.bg_color != Color(0x2e / 255.0, 0x38 / 255.0, 0x59 / 255.0):
		return "hover bg: %s" % h.bg_color
	return Runner.assert_eq(h.corner_radius_top_left, 5)

func test_split_4_shorthands() -> Variant:
	_reset()
	var err: String = _t.parse(".x { padding: 1px 2px 3px 4px; }")
	if err != "":
		return "parse: " + err
	_t.parse(".y { padding: 2px 4px; }")
	_t.parse(".z { padding: 5px; }")
	var c := Button.new()
	_t.apply_class(c, "x")
	var b: StyleBoxFlat = c.get_theme_stylebox("normal")
	if b.content_margin_top != 1 or b.content_margin_bottom != 3:
		return "4-val top/bottom: %d/%d" % [b.content_margin_top, b.content_margin_bottom]
	if b.content_margin_left != 4 or b.content_margin_right != 2:
		return "4-val left/right: %d/%d" % [b.content_margin_left, b.content_margin_right]
	_t.apply_class(c, "y")
	if c.get_theme_stylebox("normal").content_margin_top != 2:
		return "2-val"
	_t.apply_class(c, "z")
	return Runner.assert_eq(c.get_theme_stylebox("normal").content_margin_top, 5)

func test_apply_class_and_meta_walk() -> Variant:
	_reset()
	_t.parse(".back-button { background-color: #2e2e40; }")
	var b := Button.new()
	_t.apply_class(b, "back-button")
	if b.get_theme_stylebox("normal").bg_color != Color(0x2e / 255.0, 0x2e / 255.0, 0x40 / 255.0):
		return "class bg: %s" % b.get_theme_stylebox("normal").bg_color
	var root := PanelContainer.new()
	var child := Button.new()
	child.set_meta("ui_class", "back-button")
	root.add_child(child)
	_t.apply_css(root)
	return Runner.assert_eq(root.get_child(0).get_theme_stylebox("normal").bg_color, Color(0x2e / 255.0, 0x2e / 255.0, 0x40 / 255.0))

func test_compound_class_prefers_element() -> Variant:
	_reset()
	_t.parse(".back-button { background-color: #000000; }\nbutton.back-button { background-color: #112233; }")
	var b := Button.new()
	_t.apply_class(b, "back-button")
	if b.get_theme_stylebox("normal").bg_color != Color(0x11 / 255.0, 0x22 / 255.0, 0x33 / 255.0):
		return "button.back-button bg: %s" % b.get_theme_stylebox("normal").bg_color
	var lbl := Label.new()
	_t.apply_class(lbl, "back-button")
	return Runner.assert_eq(lbl.get_theme_stylebox("normal").bg_color, Color(0, 0, 0))

func test_font_size_prop() -> Variant:
	_reset()
	_t.parse("label { font-size: 22px; color: #e6ebf2; }")
	_t._rebuild_theme()
	return Runner.assert_eq(_t.theme.get_font_size("Label", "font_size"), 22)

func test_default_css_loads() -> Variant:
	_reset()
	var txt := FileAccess.get_file_as_string("res://ui/style.css")
	if txt == "":
		return "style.css introuvable ou vide"
	var err: String = _t.parse(txt, "res://ui/style.css")
	if err != "":
		return "parse(default css): " + err
	if _t.get_stylebox("panel", "panel").bg_color.a <= 0.0:
		return "panel style"
	var r = Runner.assert_eq(_t.get_number("radial", "ring-radius", -1.0), 180.0)
	if r != true:
		return r
	return Runner.assert_eq(_t.get_number("radial", "gap-size", -1.0), 4.0)

func test_margin_px_shorthand() -> Variant:
	_reset()
	_t.parse("panel.p { margin: 20px 40px; }")
	var parent := Control.new()
	parent.size = Vector2(1000, 800)
	var c := PanelContainer.new()
	parent.add_child(c)
	_t.apply_class(c, "p")
	if c.anchor_left != 0.0 or c.anchor_right != 1.0 or c.anchor_top != 0.0 or c.anchor_bottom != 1.0:
		return "anchors full-rect absents: %s" % c.anchors_preset
	if c.offset_top != 20.0 or c.offset_bottom != -20.0:
		return "vert px: %s/%s" % [c.offset_top, c.offset_bottom]
	return Runner.assert_eq(c.offset_left, 40.0) if c.offset_left == 40.0 and c.offset_right == -40.0 else "horiz px: %s/%s" % [c.offset_left, c.offset_right]

func test_margin_percent() -> Variant:
	_reset()
	_t.parse("panel.q { margin: 10% 25%; }")
	var parent := Control.new()
	parent.size = Vector2(1000, 800)
	var c := PanelContainer.new()
	parent.add_child(c)
	_t.apply_class(c, "q")
	if absf(c.offset_top - 80.0) > 0.001 or absf(c.offset_bottom + 80.0) > 0.001:
		return "vert %%: %s/%s" % [c.offset_top, c.offset_bottom]
	if absf(c.offset_left - 250.0) > 0.001 or absf(c.offset_right + 250.0) > 0.001:
		return "horiz %%: %s/%s" % [c.offset_left, c.offset_right]
	return true

func test_multi_class_meta_applies_both() -> Variant:
	_reset()
	var err: String = _t.parse("panel.menu-panel { background-color: #111111; }\npanel.pause-menu { margin: 20%; }")
	if err != "":
		return "parse: " + err
	var parent := Control.new()
	parent.size = Vector2(1000, 800)
	var c := PanelContainer.new()
	parent.add_child(c)
	c.set_meta("ui_class", "menu-panel pause-menu")
	_t.apply_css(parent)
	if not c.has_theme_stylebox_override("panel"):
		return "pas de stylebox menu-panel"
	if c.get_theme_stylebox("panel").bg_color != Color(0x11 / 255.0, 0x11 / 255.0, 0x11 / 255.0):
		return "bg menu-panel: %s" % c.get_theme_stylebox("panel").bg_color
	if absf(c.offset_top - 160.0) > 0.001 or absf(c.offset_left - 200.0) > 0.001:
		return "marge pause-menu: %s/%s" % [c.offset_top, c.offset_left]
	return Runner.assert_eq(c.offset_right, -200.0) if absf(c.offset_right + 200.0) < 0.001 else "offset_right: %s" % c.offset_right