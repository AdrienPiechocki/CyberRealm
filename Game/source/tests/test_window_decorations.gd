extends Node
## Tests du moteur de décorations de fenêtres (window_decorations.gd) et de
## son instantiation 3D (window_decoration_3d.gd).

const Runner := preload("res://tests/runner.gd")
const Decorations := preload("res://scripts/ui/window_decorations.gd")

func _fail(res: Variant) -> bool:
	return res is String and res != ""

func test_strip_comments_keeps_res_paths() -> Variant:
	# Un chemin "res://..." contient "//" : un stripper naïf mangerait la fin de
	# la ligne. C'est LE piège du parseur de ce projet.
	var src := '{\n  // commentaire\n  "path": "res://ui/decorations/close.svg",\n  "n": 3\n}'
	var out: String = Decorations.strip_comments(src)
	if not out.contains("res://ui/decorations/close.svg"):
		return "le chemin res:// a été amputé: " + out
	if out.contains("// commentaire"):
		return "le commentaire n'a pas été retiré: " + out
	return true

func test_strip_comments_block_form() -> Variant:
	var out: String = Decorations.strip_comments('{ /* a */ "n": 1 }')
	return Runner.assert_true(not out.contains("/*"), "bloc /* */ non retiré: " + out)

func test_strip_trailing_commas() -> Variant:
	var out: String = Decorations.strip_trailing_commas('{ "a": 1, "b": [2, 3, ], }')
	if out.contains(", }") or out.contains(",]"):
		return "virgules finales conservées: " + out
	return Runner.assert_true(out.contains('"a": 1'), "contenu perdu: " + out)

func test_parse_config_defaults_on_garbage() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	var err: String = Decorations.parse_config("pas du json", m, "test")
	if err == "":
		return "un JSON invalide doit renvoyer un message"
	var r = Runner.assert_eq(m["titlebar_height"], 20.0, "le défaut doit survivre")
	if _fail(r):
		return r
	return Runner.assert_eq(m["border_size"], 10.0, "défaut border_size")

func test_parse_config_reads_valid_keys() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	var err: String = Decorations.parse_config(
		'{"titlebar_height": 26, "button_alignment": "left", "label_color": "#ff8800"}', m, "test")
	if _fail(err):
		return err
	var r = Runner.assert_eq(m["titlebar_height"], 26.0, "titlebar_height")
	if _fail(r):
		return r
	r = Runner.assert_eq(m["button_alignment"], "left", "button_alignment")
	if _fail(r):
		return r
	# Comparaison contre la même expression que le parseur : assert_eq() est un
	# != exact et 136/255 vaut 0.5333, pas 0.533.
	return Runner.assert_eq(m["label_color"], Color.from_string("#ff8800", Color.MAGENTA),
		"label_color #ff8800")

func test_parse_config_ignores_bad_values() -> Variant:
	# Régression de forme : float("abc") == 0.0 et Color("#zz") == noir, donc
	# une valeur illisible ne doit ni valider un 0 ni noirer le texte.
	var m: Dictionary = Decorations.default_metrics()
	var err: String = Decorations.parse_config(
		'{"titlebar_height": "abc", "border_size": -4, "label_color": "#zz", "button_alignment": 7}', m, "test")
	if _fail(err):
		return err
	var r = Runner.assert_eq(m["titlebar_height"], 20.0, "un texte non numérique doit retomber sur le défaut")
	if _fail(r):
		return r
	r = Runner.assert_eq(m["border_size"], 10.0, "une valeur négative doit retomber sur le défaut")
	if _fail(r):
		return r
	r = Runner.assert_true(m["label_color"] != Color(0, 0, 0), "un hex invalide ne doit pas virer au noir")
	if _fail(r):
		return r
	return Runner.assert_eq(m["button_alignment"], "right", "un type faux retombe sur le défaut")

func test_default_metrics_keys() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	for k: String in ["titlebar_height", "border_size", "label_size", "label_color",
			"button_size", "button_gap", "button_margin", "button_alignment", "button_states"]:
		if not m.has(k):
			return "clé absente des défauts: " + k
	return Runner.assert_eq(m["button_states"], 3.0, "button_states par défaut")