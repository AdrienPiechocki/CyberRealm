extends Node
## Tests du moteur de décorations de fenêtres (window_decorations.gd) et de
## son instantiation 3D (window_decoration_3d.gd).

const Runner := preload("res://tests/runner.gd")
const Decorations := preload("res://scripts/ui/window_decorations.gd")

const RES_TEST_JSON := "user://deco_test_res.json"
const USER_TEST_JSON := "user://deco_test_user.json"

## Repart d'un état propre : l'état statique du loader est partagé par TOUS les
## fichiers de test du runner (un seul process), donc chaque test qui touche aux
## metrics restaure le défaut du jeu et efface ses fichiers temporaires.
func _reset_deco() -> void:
	for p: String in [RES_TEST_JSON, USER_TEST_JSON]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	Decorations.load_config()
	Decorations.tick(10.0)

func _write(path: String, body: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()

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

func test_px_scale_is_isotropic() -> Variant:
	# 800x600 px sur 3.2x2.0 : 250 px/u en x, 300 en y. Un cadre doit garder la
	# MÊME épaisseur à l'écran sur les deux axes, donc on prend le plus petit —
	# soit 2.0/600, pas 3.2/800.
	var s: float = Decorations.px_scale(Vector2(800.0, 600.0), Vector2(3.2, 2.0))
	return Runner.assert_approx(s, minf(3.2 / 800.0, 2.0 / 600.0), 0.000001,
		"px_scale = min(3.2/800, 2.0/600)")

func test_px_scale_fallback_before_first_texture() -> Variant:
	var r = Runner.assert_eq(Decorations.px_scale(Vector2.ZERO, Vector2(3.2, 2.0)),
		Decorations.FALLBACK_PX_SCALE, "pas de surface connue = repli")
	if _fail(r):
		return r
	return Runner.assert_eq(Decorations.px_scale(Vector2(800.0, 600.0), Vector2.ZERO),
		Decorations.FALLBACK_PX_SCALE, "mesh vide = repli")

func test_world_metrics_scale_px() -> Variant:
	var m: Dictionary = Decorations.default_metrics()
	var w: Dictionary = Decorations.world(m, 0.005)
	var r = Runner.assert_eq(w["border"], 0.05, "10 px à 0,005 u/px")
	if _fail(r):
		return r
	r = Runner.assert_eq(w["titlebar"], 0.1, "20 px à 0,005 u/px")
	if _fail(r):
		return r
	return Runner.assert_true(w["button"] < w["titlebar"], "un bouton tient dans la barre")
func test_bundled_json_is_readable() -> Variant:
	_reset_deco()
	var m: Dictionary = Decorations.metrics()
	var r = Runner.assert_eq(m["titlebar_height"], 20.0, "défaut res://ui/decorations/decorations.json")
	if _fail(r):
		return r
	r = Runner.assert_eq(m["button_alignment"], "right", "alignement du fichier livré")
	if _fail(r):
		return r
	return Runner.assert_eq(m["border_size"], 10.0, "épaisseur du cadre")

func test_user_file_overrides_res_key_by_key() -> Variant:
	_reset_deco()
	_write(RES_TEST_JSON, '{"titlebar_height": 24, "button_gap": 9}')
	_write(USER_TEST_JSON, '{"titlebar_height": 30}')
	Decorations.load_config(RES_TEST_JSON, USER_TEST_JSON)
	var m: Dictionary = Decorations.metrics()
	var r = Runner.assert_eq(m["titlebar_height"], 30.0, "user:// gagne sur res://")
	if _fail(r):
		return r
	r = Runner.assert_eq(m["button_gap"], 9.0, "une clé absente du user reste celle du res://")
	if _fail(r):
		return r
	_reset_deco()
	return Runner.assert_eq(Decorations.metrics()["titlebar_height"], 20.0, "retour au défaut après reset")

func test_broken_user_file_keeps_the_bundled_values() -> Variant:
	_reset_deco()
	_write(USER_TEST_JSON, '{ "titlebar_height": ')
	Decorations.load_config(USER_TEST_JSON, USER_TEST_JSON)
	var r = Runner.assert_eq(Decorations.metrics()["titlebar_height"], 20.0,
		"un user:// cassé ne doit pas vider la configuration")
	if _fail(r):
		return r
	_reset_deco()
	return true

func test_tick_reloads_after_a_write() -> Variant:
	_reset_deco()
	# Le tick est cadencé à POLL_SECONDS : un tick dans la fenêtre de garde ne
	# regarde rien, même si un fichier vient d'être écrit.
	if Decorations.tick(0.1):
		return "un tick dans la fenêtre de garde ne doit rien faire"
	# `_reset_deco()` vient de supprimer le fichier et `load_config` mémorise le
	# mtime à 0 (absent). Le poll recharge les chemins qu'il a réellement chargés :
	# écrire ensuite change ce mtime pour de bon, sans dépendre de la résolution
	# en secondes de `get_modified_time`.
	Decorations.load_config(RES_TEST_JSON, USER_TEST_JSON)
	if Decorations.tick(0.1):
		return "un tick dans la fenêtre de garde ne doit rien faire"
	_write(USER_TEST_JSON, '{"border_size": 14}')
	if not Decorations.tick(10.0):
		return "un fichier surveillé doit déclencher un rechargement"
	var r = Runner.assert_eq(Decorations.metrics()["border_size"], 14.0,
		"la nouvelle valeur doit être appliquée")
	if _fail(r):
		return r
	if Decorations.tick(10.0):
		return "sans changement, pas de rechargement"
	_reset_deco()
	return true

func test_border_pieces_and_button_atlas() -> Variant:
	_reset_deco()
	var piece: AtlasTexture = Decorations.border_piece("topleft")
	if piece == null:
		return "border.svg absent ou pièce dégénérée"
	# La région doit venir des MÉTRIQUES (10×20 px), pas de la taille du fichier :
	# le test reste donc indépendant du ré-export de l'asset tant que celui-ci
	# reste un vrai 9-patch, assez grand pour être découpé.
	var tex_size: Vector2 = Decorations.texture("border").get_size()
	if tex_size.x < 20.0 or tex_size.y < 40.0:
		return "border.svg trop petit pour être un 9-patch: " + str(tex_size)
	var r = Runner.assert_eq(piece.region.size, Vector2(10.0, 20.0), "région du coin")
	if _fail(r):
		return r
	r = Runner.assert_eq(piece.atlas, Decorations.texture("border"), "atlas = border.svg")
	if _fail(r):
		return r
	# Deux appels doivent renvoyer le MÊME AtlasTexture (cache), sinon chaque
	# resync réalloue une texture.
	if Decorations.border_piece("topleft") != piece:
		return "le cache d'AtlasTexture ne fonctionne pas"
	var btn: AtlasTexture = Decorations.button_atlas("close", 0)
	if btn == null:
		return "close.svg absent"
	return Runner.assert_true(btn.region.size.x > 0.0, "région d'état non vide")

const Decoration := preload("res://scripts/windows/window_decoration_3d.gd")

const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

var win3d: Node3D
var player: Node3D

## Monde de test minimal : une fenêtre mappée, sans texture (les metas de
## surface sont écrites à la main, comme tests/test_window_top_resize.gd).
func _build_world() -> Variant:
	win3d = Node3D.new()
	win3d.set_script(Windows3DScript)
	player = Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0.0, 1.5, 0.0)
	player.add_child(cam)
	get_tree().root.add_child(player)
	get_tree().root.add_child(win3d)
	win3d.setup(null, player)
	win3d.on_window_mapped(3, "Test Window", "app")
	if not win3d.quads.has(3):
		return "le quad de la fenêtre 3 n'a pas été créé"
	var body: StaticBody3D = win3d.quads[3].get_child(0)
	body.set_meta("surface_size", Vector2(1000.0, 500.0))
	body.set_meta("content_offset", Vector2.ZERO)
	body.set_meta("content_size", Vector2(1000.0, 500.0))
	# Le décor a été construit sans surface connue, donc au repli de 0,005 u/px.
	# On resynchronise : c'est exactement ce que fait `on_texture_updated` quand
	# la première texture arrive.
	win3d._sync_decorations(win3d.quads[3])
	return true

func _quad() -> Node3D:
	return win3d.quads[3]

func _teardown() -> void:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()


func test_frame_piece_rects() -> Variant:
	var half := Vector2(100.0, 50.0)
	var t := 4.0
	var b := 8.0
	var r = Runner.assert_eq(Decoration.frame_piece_rect("left", half, t, b),
		[Vector2(-102.0, 0.0), Vector2(4.0, 100.0)], "bande gauche")
	if _fail(r):
		return r
	r = Runner.assert_eq(Decoration.frame_piece_rect("right", half, t, b),
		[Vector2(102.0, 0.0), Vector2(4.0, 100.0)], "bande droite")
	if _fail(r):
		return r
	r = Runner.assert_eq(Decoration.frame_piece_rect("bottom", half, t, b),
		[Vector2(0.0, -52.0), Vector2(200.0, 4.0)], "bande basse")
	if _fail(r):
		return r
	# Les coins hauts portent la HAUTEUR DE LA BARRE, pas celle du cadre : ils
	# sont les coins de la barre de titre, pas des coins de simple bordure.
	r = Runner.assert_eq(Decoration.frame_piece_rect("topleft", half, t, b),
		[Vector2(-102.0, 54.0), Vector2(4.0, 8.0)], "coin haut-gauche = hauteur de barre")
	if _fail(r):
		return r
	return Runner.assert_eq(Decoration.frame_piece_rect("bottomleft", half, t, b),
		[Vector2(-102.0, -52.0), Vector2(4.0, 4.0)], "coin bas-gauche = carré")

func test_button_positions_right_alignment() -> Variant:
	var xs: Array = Decoration.button_positions(3, "right", 10.0, 4.0, 7.0, 100.0)
	var r = Runner.assert_approx(xs[0], 88.0, 0.001, "fermé le plus à droite")
	if _fail(r):
		return r
	r = Runner.assert_approx(xs[1], 74.0, 0.001, "puis maximiser")
	if _fail(r):
		return r
	return Runner.assert_approx(xs[2], 60.0, 0.001, "puis réduire")

func test_button_positions_left_alignment() -> Variant:
	var xs: Array = Decoration.button_positions(3, "left", 10.0, 4.0, 7.0, 100.0)
	var r = Runner.assert_approx(xs[0], -88.0, 0.001, "fermé le plus à gauche")
	if _fail(r):
		return r
	return Runner.assert_approx(xs[2], -60.0, 0.001, "réduire le plus à droite du lot")

func test_titlebar_metrics_from_json() -> Variant:
	# `titlebar_metrics()` lit l'état statique du loader : on repart du défaut
	# pour que ce test ne dépende pas du fichier de test précédent.
	_reset_deco()
	var d: Dictionary = Decoration.titlebar_metrics(0.005)
	var r = Runner.assert_eq(d["border"], 0.05, "cadre 10 px")
	if _fail(r):
		return r
	r = Runner.assert_eq(d["titlebar"], 0.1, "barre 20 px")
	if _fail(r):
		return r
	return Runner.assert_eq(d["alignment"], "right", "alignement")

func test_decoration_nodes_are_built() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad := _quad()
	# Les chemins lus par on_window_title_changed et par
	# tests/test_window_top_resize.gd ne doivent pas bouger.
	for path: String in ["Titlebar", "Titlebar/BarBody", "Titlebar/Label3D",
			"Titlebar/BtnClose", "Titlebar/BtnMaximize", "Titlebar/BtnMinimize"]:
		if quad.get_node_or_null(path) == null:
			return "chemin manquant: " + path
	var deco := quad.get_node_or_null("Decoration") as Node3D
	if deco == null:
		return "Decoration manquant"
	for spec: Dictionary in Decoration.FRAME_PIECES:
		var node := deco.get_node_or_null(spec["node"]) as StaticBody3D
		if node == null:
			return "pièce manquante: " + spec["node"]
		if not node.has_meta("decoration_edge"):
			return "meta decoration_edge absente sur " + spec["node"]
		if str(node.get_meta("decoration_edge")) != str(spec["edge"]):
			return "mauvais edge sur " + spec["node"]
		if int(node.get_meta("window_of", -1)) != 3:
			return "meta window_of absente sur " + spec["node"]
	_teardown()
	return true

func test_frame_sizes_follow_the_metrics() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad := _quad()
	var mesh: QuadMesh = quad.mesh
	# mesh 3.2x2.0 sur 1000x500 px => 320 px/u en x, 250 en y.
	var s: float = Decorations.px_scale(Vector2(1000.0, 500.0), mesh.size)
	var d: Dictionary = Decoration.titlebar_metrics(s)
	var deco := quad.get_node_or_null("Decoration")
	var left := deco.get_node("FrameLeft") as StaticBody3D
	var shape: BoxShape3D = (left.get_child(0) as CollisionShape3D).shape
	var r = Runner.assert_approx(shape.size.y, mesh.size.y, 0.001, "bande gauche = hauteur du contenu")
	if _fail(r):
		return r
	r = Runner.assert_approx(shape.size.x, d["border"], 0.001, "épaisseur = border_size en monde")
	if _fail(r):
		return r
	var bottom := deco.get_node("FrameBottom") as StaticBody3D
	var bshape: BoxShape3D = (bottom.get_child(0) as CollisionShape3D).shape
	r = Runner.assert_approx(bshape.size.x, mesh.size.x, 0.001, "bande basse = largeur du contenu")
	if _fail(r):
		return r
	r = Runner.assert_approx(bshape.size.y, d["border"], 0.001, "bande basse fine")
	if _fail(r):
		return r
	# La barre fait toute la largeur du CONTENU, les coins portent le cadre.
	var titlebar := quad.get_node_or_null("Titlebar") as MeshInstance3D
	r = Runner.assert_approx((titlebar.mesh as QuadMesh).size.x, mesh.size.x, 0.001, "barre = largeur du contenu")
	if _fail(r):
		return r
	r = Runner.assert_approx(titlebar.position.y, mesh.size.y * 0.5 + d["titlebar"] * 0.5, 0.001,
		"barre collée au bord haut du contenu")
	if _fail(r):
		return r
	_teardown()
	return true

func test_frame_visibility_follows_ssd() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	win3d.on_window_decorations_changed(3, false)
	var deco := _quad().get_node_or_null("Decoration") as Node3D
	if deco == null:
		return "Decoration manquant"
	var r = Runner.assert_true(not deco.visible, "un client CSD dessine son propre cadre")
	if _fail(r):
		return r
	win3d.on_window_decorations_changed(3, true)
	r = Runner.assert_true(deco.visible, "un client SSD laisse le jeu dessiner le cadre")
	if _fail(r):
		return r
	_teardown()
	return true

func test_toggle_hide_disables_frame_colliders() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	win3d.toggle_hide(3)
	var left := (_quad().get_node_or_null("Decoration/FrameLeft") as StaticBody3D)
	if left == null:
		return "le cadre doit exister avant d'être caché"
	var col := left.get_child(0) as CollisionShape3D
	# Le décor est un Node3D intermédiaire : sans récursion Node3D, la fenêtre
	# cachée garderait un collider de cadre vivant et resterait attrapable.
	var r = Runner.assert_true(col.disabled, "le collider du cadre doit suivre le hide")
	if _fail(r):
		return r
	_teardown()
	return true

func test_visual_half_extent_includes_frame_and_bar() -> Variant:
	var d: Dictionary = Decoration.titlebar_metrics(0.01)
	var r = Runner.assert_approx(
		Windows3DScript.visual_half_extent(Vector2(3.2, 2.0), d).x, 1.7, 0.001,
		"demi-largeur visible = contenu + cadre")
	if _fail(r):
		return r
	return Runner.assert_approx(
		Windows3DScript.visual_half_extent(Vector2(3.2, 2.0), d).y, 1.15, 0.001,
		"demi-hauteur visible = contenu + barre + cadre")

func test_visual_center_is_offset_by_the_frame_asymmetry() -> Variant:
	var d: Dictionary = Decoration.titlebar_metrics(0.01)
	var up := Vector3(0.0, 1.0, 0.0)
	var r = Runner.assert_eq(Windows3DScript.visual_center(Vector3(2.0, 3.0, 4.0), up, d),
		Vector3(2.0, 3.05, 4.0), "centre visuel décalé vers le haut de (barre - cadre)/2")
	if _fail(r):
		return r
	# Cadre et barre de même épaisseur : plus rien à décaler.
	return Runner.assert_eq(
		Windows3DScript.visual_center(Vector3.ZERO, up,
			{"border": 0.2, "titlebar": 0.2}),
		Vector3.ZERO, "barre = cadre => aucun décalage")

func test_occluder_covers_the_frame() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var occ := _quad().get_node_or_null("Occluder") as OccluderInstance3D
	if occ == null:
		return "Occluder manquant"
	var box: BoxOccluder3D = occ.occluder
	var s: float = Decorations.px_scale(Vector2(1000.0, 500.0), _quad().mesh.size)
	var d: Dictionary = Decoration.titlebar_metrics(s)
	# L'occluder doit couvrir l'empreinte VISIBLE : sans cela le culling mange
	# les bords du décor quand deux fenêtres se font face.
	var r = Runner.assert_approx(box.size.x, 3.2 + d["border"] * 2.0, 0.001, "largeur + cadre des deux côtés")
	if _fail(r):
		return r
	r = Runner.assert_approx(box.size.y, 2.0 + d["titlebar"] + d["border"], 0.001, "hauteur + barre + cadre")
	if _fail(r):
		return r
	r = Runner.assert_approx(occ.position.y, (d["titlebar"] - d["border"]) * 0.5, 0.001,
		"occluder centré sur l'empreinte visible")
	if _fail(r):
		return r
	_teardown()
	return true

func test_occluder_survives_a_detach_reattach() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var occ := _quad().get_node_or_null("Occluder") as OccluderInstance3D
	if occ == null:
		return "Occluder manquant"
	var s: float = Decorations.px_scale(Vector2(1000.0, 500.0), _quad().mesh.size)
	var d: Dictionary = Decoration.titlebar_metrics(s)
	# Pendant un resize la boîte est détachée : elle ne vit plus que dans les
	# métadonnées. Le réattachement doit la remettre à jour malgré ça.
	win3d._set_window_occluder_active(3, false)
	if occ.occluder != null:
		return "l'occluder aurait dû être détaché"
	win3d._set_window_occluder_active(3, true)
	if occ.occluder == null:
		return "l'occluder aurait dû être réattaché"
	var box: BoxOccluder3D = occ.occluder
	var r = Runner.assert_approx(box.size.y, 2.0 + d["titlebar"] + d["border"], 0.001,
		"la boîte détachée doit être resynchronisée au réattachement")
	if _fail(r):
		return r
	_teardown()
	return true

func test_snap_zones_follow_the_frame() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad := _quad()
	var s: float = Decorations.px_scale(Vector2(1000.0, 500.0), quad.mesh.size)
	var d: Dictionary = Decoration.titlebar_metrics(s)
	var expected_x: float = quad.mesh.size.x * 0.5 + d["border"]
	var zone := quad.get_node_or_null("SnapLeft") as Area3D
	if zone == null:
		return "SnapLeft manquant"
	var box: BoxShape3D = (zone.get_child(0) as CollisionShape3D).shape
	var r = Runner.assert_approx(zone.position.x, -expected_x, 0.001, "zone Recentrée sur le bord du cadre")
	if _fail(r):
		return r
	return Runner.assert_approx(box.size.z, 0.3, 0.001, "épaisseur de capture inchangée")
