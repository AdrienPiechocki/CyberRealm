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

func test_border_source_rects() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	var rects: Dictionary = Decorations.border_source_rects(Vector2(310.0, 190.0), m)
	var r = Runner.assert_eq(rects["topleft"], Rect2(0.0, 0.0, 10.0, 20.0), "coin haut-gauche")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects["top"], Rect2(10.0, 0.0, 290.0, 20.0), "bande haute")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects["left"], Rect2(0.0, 20.0, 10.0, 160.0), "bande gauche")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects["right"], Rect2(300.0, 20.0, 10.0, 160.0), "bande droite")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects["bottomleft"], Rect2(0.0, 180.0, 10.0, 10.0), "coin bas-gauche")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects["bottom"], Rect2(10.0, 180.0, 290.0, 10.0), "bande basse")
	if _fail(r):
		return r
	return Runner.assert_eq(rects["bottomright"], Rect2(300.0, 180.0, 10.0, 10.0), "coin bas-droit")

func test_border_source_rects_follow_the_metrics() -> Variant:
	# Les marges ne viennent PAS de la texture mais des métriques : un cadre plus
	# épais doit déplacer les découpes d'autant.
	var m: Dictionary = Decorations.default_metrics()
	m["border_size"] = 14.0
	m["titlebar_height"] = 24.0
	var rects: Dictionary = Decorations.border_source_rects(Vector2(310.0, 190.0), m)
	return Runner.assert_eq(rects["top"], Rect2(14.0, 0.0, 282.0, 24.0), "marge pilotée par le JSON")

func test_border_source_rects_clamped_on_small_texture() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	var rects: Dictionary = Decorations.border_source_rects(Vector2(8.0, 8.0), m)
	# Rien ne dépasse la texture, et une découpe impossible vaut zéro.
	for k: String in rects.keys():
		var rect: Rect2 = rects[k]
		if rect.position.x < 0.0 or rect.position.y < 0.0 \
				or rect.position.x + rect.size.x > 8.0 or rect.position.y + rect.size.y > 8.0:
			return "rect hors texture pour %s: %s" % [k, str(rect)]
	return Runner.assert_eq(rects["top"].size.x, 0.0, "bande haute impossible = taille nulle")

func test_button_state_rects_gapless() -> Variant:
	var rects: Array = Decorations.button_state_rects(Vector2(66.0, 22.0), 3.0)
	if rects.size() != 3:
		return "3 états attendus, obtenu %d" % rects.size()
	var r = Runner.assert_eq(rects[0], Rect2(0.0, 0.0, 22.0, 22.0), "état 0 collé à gauche")
	if _fail(r):
		return r
	r = Runner.assert_eq(rects[2], Rect2(44.0, 0.0, 22.0, 22.0), "état 2")
	if _fail(r):
		return r
	return Runner.assert_eq(rects[1].position.x, 22.0, "état 1")

func test_button_state_rects_gapped() -> Variant:
	# Le pas est DÉRIVÉ de la largeur, pas supposé : un strip espacé doit donner
	# les mêmes cellules carrées.
	var rects: Array = Decorations.button_state_rects(Vector2(82.0, 22.0), 3.0)
	var r = Runner.assert_eq(rects[1], Rect2(30.0, 0.0, 22.0, 22.0), "pas de 30 px")
	if _fail(r):
		return r
	return Runner.assert_eq(rects[2], Rect2(60.0, 0.0, 22.0, 22.0), "état 2 espacé")

func test_button_state_rects_single_cell() -> Variant:
	var rects: Array = Decorations.button_state_rects(Vector2(22.0, 22.0), 1.0)
	if rects.size() != 1:
		return "1 état attendu, obtenu %d" % rects.size()
	return Runner.assert_eq(rects[0], Rect2(0.0, 0.0, 22.0, 22.0), "région unique = texture entière")