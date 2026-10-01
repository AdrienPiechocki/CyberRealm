extends Node
## Tests du redimensionnement par le HAUT d'une fenêtre : le drag de la barre de
## titre du jeu (windows_3d.gd).
##
## Avant, la barre de titre DÉPLAÇAIT la fenêtre dans son plan 2D. Elle la
## redimensionne désormais par le haut : le bord haut reste sous le regard, le
## bord bas descend (ou monte), la largeur ne bouge pas.
##
## Trois pièces à verrouiller :
##  - le clic sur la barre démarre un resize "top" (et rien d'autre : le mode
##    move_2d, qui déplaçait la fenêtre dans son plan, a disparu) ;
##  - l'état de départ est bien celui d'un resize de bord — et, sans voisine
##    collée sur le haut, SANS charnière (resize_hinge_mode vide) : le regard
##    vertical doit rester la hauteur, sinon la fenêtre pivoterait pendant le
##    drag. La charnière elle-même est couverte par tests/test_resize_hinge.gd ;
##  - le signe du calcul : tirer vers le HAUT grandit. C'est le piège de lecture
##    (le bas grandit en tirant vers le bas), d'où le test explicite.

const Runner := preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

const WID := 7
const SURFACE := Vector2(800.0, 600.0)
const CONTENT_OFFSET := Vector2(4.0, 4.0)

var win3d: Node3D
var player: Node3D

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
	win3d.on_window_mapped(WID, "Test Window", "app")
	if not win3d.quads.has(WID):
		return "le quad de la fenêtre %d n'a pas été créé" % WID
	# on_texture_updated n'est jamais appelé dans ce monde de test : on écrit
	# à la main les metas que le resize lit, pour que le ratio px/unité monde
	# soit un vrai ratio.
	var body: StaticBody3D = win3d.quads[WID].get_child(0)
	body.set_meta("surface_size", SURFACE)
	body.set_meta("content_offset", CONTENT_OFFSET)
	body.set_meta("content_size", SURFACE)
	return true

func _quad() -> Node3D:
	return win3d.quads[WID]

# Le corps statique de la barre de titre : c'est ce que le raycast touche quand
# le viseur est sur la barre.
func _titlebar_body() -> Node3D:
	return _quad().get_node_or_null("Titlebar/BarBody")

func _teardown() -> void:
	Input.action_release("left_click")
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()

# Un rayon qui part de la caméra et vise le quad de face.
func _aim() -> Array:
	var cam: Camera3D = player.get_node("Camera3D")
	var quad: Node3D = _quad()
	var dir: Vector3 = (quad.global_position - cam.global_position).normalized()
	return [cam.global_position, dir]

func _fail(res: Variant) -> bool:
	return res is String and res != ""

func test_titlebar_click_starts_a_top_resize() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var bar_body: Node3D = _titlebar_body()
	if bar_body == null:
		return "pas de BarBody sur la barre de titre de la fenêtre %d" % WID
	if int(bar_body.get_meta("titlebar_of", -1)) != WID:
		return "le BarBody ne porte pas le meta titlebar_of=%d" % WID
	var aim := _aim()
	Input.action_press("left_click")
	win3d._handle_titlebar(bar_body, aim[0], aim[1])
	var res: Variant = Runner.assert_true(win3d.is_resizing,
		"le clic sur la barre de titre doit démarrer un redimensionnement")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.resizing_edge, "top",
		"la barre de titre doit tirer le bord HAUT")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.active_window_id, WID,
		"la fenêtre saisie doit être celle de la barre cliquée")
	if _fail(res):
		return res
	_teardown()
	return true

func test_unshared_top_resize_stays_flat() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad: Node3D = _quad()
	var aim := _aim()
	win3d._start_resize(WID, quad, aim[0], aim[1], "top")
	var res: Variant = Runner.assert_true(win3d.is_resizing,
		"_start_resize doit armer le redimensionnement")
	if _fail(res):
		return res
	# Sans voisine sur le haut, le resize par le haut reste plan : le regard
	# vertical est la hauteur, il ne doit pas devenir de la profondeur.
	res = Runner.assert_eq(win3d.resize_hinge_mode, "",
		"un redimensionnement par le haut sans voisine ne doit pas être en charnière")
	if _fail(res):
		return res
	# L'état de départ est celui d'un resize de bord, sinon le premier frame de
	# drag partirait d'une référence fausse (mesh, position, ratio px/unité).
	res = Runner.assert_eq(win3d.window_start_size, SURFACE,
		"la taille de surface de départ doit être figée")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.window_start_content_offset, CONTENT_OFFSET,
		"le content_offset de départ doit être figé")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.window_start_mesh_size, (quad.mesh as QuadMesh).size,
		"la taille monde de départ doit être figée")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.window_start_local_pos, quad.position,
		"la position locale de départ doit être figée")
	if _fail(res):
		return res
	var cam: Camera3D = player.get_node("Camera3D")
	res = Runner.assert_approx(win3d.resize_depth,
		cam.global_position.distance_to(quad.global_position), 0.001,
		"la profondeur de drag doit être la distance caméra -> quad")
	if _fail(res):
		return res
	_teardown()
	return true

func test_top_resize_detaches_the_occluder() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad: Node3D = _quad()
	var aim := _aim()
	win3d._start_resize(WID, quad, aim[0], aim[1], "top")
	var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
	if occ == null:
		return "Occluder manquant sur le quad %d" % WID
	var res: Variant = Runner.assert_true(occ.occluder == null,
		"l'occluder doit être détaché pendant le drag (reconstruction Embree)")
	if _fail(res):
		return res
	_teardown()
	return true

func test_pulling_up_grows_the_window() -> Variant:
	# 800x600 px sur un mesh de 3.2x2.0 unités monde => 250 px par unité en x,
	# 300 px par unité en y.
	var px_per_unit := Vector2(SURFACE.x / 3.2, SURFACE.y / 2.0)
	var res: Variant = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "top",
			Vector2(0.0, 0.2), px_per_unit),
		Vector2(800.0, 660.0),
		"tirer le bord haut vers le HAUT doit agrandir (et rien d'autre)")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "top",
			Vector2(0.0, -0.2), px_per_unit),
		Vector2(800.0, 540.0),
		"tirer vers le bas doit rétrécir, le bord haut reste en place")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "top",
			Vector2(0.5, 0.2), px_per_unit),
		Vector2(800.0, 660.0),
		"un drag de hauteur ne doit jamais toucher la largeur")
	if _fail(res):
		return res
	return true

func test_other_edges_keep_their_axis() -> Variant:
	var px_per_unit := Vector2(250.0, 300.0)
	# Sens opposé en bas : grandit vers l'extérieur, donc vers le BAS.
	var res: Variant = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "bottom",
			Vector2(0.0, 0.2), px_per_unit),
		Vector2(800.0, 540.0),
		"bord bas tiré vers le haut : la fenêtre rétrécit")
	if _fail(res):
		return res
	# Coin bas-gauche : les deux axes bougent, un bord haut/bas ne l'est pas.
	res = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "bottomleft",
			Vector2(0.2, 0.1), px_per_unit),
		Vector2(750.0, 570.0),
		"un coin déplace les deux axes")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "right",
			Vector2(0.2, 0.4), px_per_unit),
		Vector2(850.0, 600.0),
		"un bord latéral ignore le déplacement vertical")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.resized_surface_size(SURFACE, "",
			Vector2(0.2, 0.4), px_per_unit),
		SURFACE,
		"sans côté tiré, rien ne bouge")
	if _fail(res):
		return res
	return true