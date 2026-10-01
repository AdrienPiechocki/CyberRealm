extends Node
## Tests de la CHARNIÈRE de redimensionnement (windows_3d.gd).
##
## La charnière est conditionnelle : elle n'existe que si le bord TIRÉ est
## PARTAGÉ avec une fenêtre collée. Sans voisin, le redimensionnement est plan
## sur les quatre côtés — c'est la règle vérifiée ici.
##
## Trois pièces à verrouiller :
##  - le choix du mode (hinge_mode_for) : "" plan, "yaw" bord latéral tiré,
##    "pitch" bord haut/bas tiré, un coin dont les deux côtés sont partagés
##    gardant le lacet ;
##  - la géométrie pure (resize_hinge) : le bord opposé reste fixe, le bord tiré
##    suit le viseur, et la profondeur vient du regard le long de l'axe du
##    pivot — sauf pendant un drag de coin, où ce regard règle déjà l'autre axe ;
##  - l'arming réel (_start_resize) sur une fenêtre réellement collée.

const Runner := preload("res://tests/runner.gd")
const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

const WID := 7
const NEI := 8
const SURFACE := Vector2(800.0, 600.0)
const MESH := Vector2(3.2, 2.0)

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
	win3d.on_window_mapped(NEI, "Neighbour", "app")
	for wid in [WID, NEI]:
		if not win3d.quads.has(wid):
			return "le quad de la fenêtre %d n'a pas été créé" % wid
		var body: StaticBody3D = win3d.quads[wid].get_child(0)
		body.set_meta("surface_size", SURFACE)
		body.set_meta("content_offset", Vector2(4.0, 4.0))
		body.set_meta("content_size", SURFACE)
		(win3d.quads[wid].mesh as QuadMesh).size = MESH
	return true

func _teardown() -> void:
	if is_instance_valid(win3d):
		win3d.free()
	if is_instance_valid(player):
		player.free()

# Collage explicite de la voisine NEI sur le côté `our_side` de WID : le graphe
# de collage est construit normalement par le raycast, on n'installe ici que l'état.
func _snap_neighbour(our_side: String) -> void:
	win3d.snapped_to[WID] = {"wid": NEI, "side": _opposite(our_side), "our_side": our_side}
	win3d.snapped_to[NEI] = {"wid": WID, "side": our_side, "our_side": _opposite(our_side)}

func _opposite(side: String) -> String:
	match side:
		"left": return "right"
		"right": return "left"
		"top": return "bottom"
		_: return "top"

func _aim() -> Array:
	var cam: Camera3D = player.get_node("Camera3D")
	var quad: Node3D = win3d.quads[WID]
	var dir: Vector3 = (quad.global_position - cam.global_position).normalized()
	return [cam.global_position, dir]

func _fail(res: Variant) -> bool:
	return res is String and res != ""

func test_hinge_mode_needs_a_shared_pulled_side() -> Variant:
	# Aucun voisin partagé : les quatre côtés restent plans, y compris les
	# latéraux, qui perdaient du coup leur lacet.
	var res: Variant = Runner.assert_eq(Windows3DScript.hinge_mode_for("right", []), "",
		"un bord latéral sans voisine doit rester plan")
	if _fail(res):
		return res
	res = Runner.assert_eq(Windows3DScript.hinge_mode_for("top", []), "",
		"un bord haut sans voisine doit rester plan")
	if _fail(res):
		return res
	# Une voisine partagée mais sur un AUTRE côté ne dit rien du bord tiré.
	res = Runner.assert_eq(Windows3DScript.hinge_mode_for("right", ["top"]),
		"", "une voisine sur le haut n'arme pas un drag à droite")
	if _fail(res):
		return res
	return true

func test_hinge_mode_follows_the_pulled_side() -> Variant:
	var res: Variant = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("left", ["left"]), "yaw",
		"un bord latéral partagé pivote en lacet")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("top", ["top"]), "pitch",
		"un bord haut partagé pivote en tangage")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("bottom", ["bottom"]), "pitch",
		"un bord bas partagé pivote en tangage")
	if _fail(res):
		return res
	# Un coin dont les deux côtés sont partagés : le lacet l'emporte.
	res = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("bottomright", ["right", "bottom"]), "yaw",
		"un coin entièrement partagé garde le lacet")
	if _fail(res):
		return res
	# Coin partiellement partagé : seul le côté réellement partagé compte.
	res = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("bottomleft", ["bottom"]), "pitch",
		"un coin partagé par le bas seulement pivote en tangage")
	if _fail(res):
		return res
	res = Runner.assert_eq(
		Windows3DScript.hinge_mode_for("bottomleft", ["left"]), "yaw",
		"un coin partagé par la gauche seulement reste en lacet")
	if _fail(res):
		return res
	res = Runner.assert_eq(Windows3DScript.hinge_mode_for("", ["top", "left"]), "",
		"sans côté tiré, aucune charnière")
	if _fail(res):
		return res
	return true

func test_hinge_grows_along_the_pulled_side() -> Variant:
	# Lacet : tirer à droite de 0.5 unité sur une fenêtre de 3.2 → 3.7.
	var h: Dictionary = Windows3DScript.resize_hinge("yaw", "right",
		Basis.IDENTITY, MESH, Vector3(0.5, 0.0, 0.0))
	var res: Variant = Runner.assert_approx((h["delta"] as Vector2).x, 0.5, 0.0001,
		"un déplacement latéral pur doit être la croissance")
	if _fail(res):
		return res
	res = Runner.assert_eq(h["delta"], Vector2(0.5, 0.0),
		"le lacet ne doit toucher que la largeur")
	if _fail(res):
		return res
	# Rien n'a bougé en profondeur : la base ne doit pas bouger non plus.
	res = Runner.assert_approx(h["basis"].x.normalized().dot(Vector3.RIGHT), 1.0, 0.0001,
		"un déplacement purement latéral ne pivote pas")
	if _fail(res):
		return res
	# Tangage : tirer vers le haut de 0.5 sur une hauteur de 2.0 → 2.5.
	h = Windows3DScript.resize_hinge("pitch", "top",
		Basis.IDENTITY, MESH, Vector3(0.0, 0.5, 0.0))
	res = Runner.assert_eq(h["delta"], Vector2(0.0, 0.5),
		"le tangage ne doit toucher que la hauteur")
	if _fail(res):
		return res
	res = Runner.assert_approx(h["basis"].y.normalized().dot(Vector3.UP), 1.0, 0.0001,
		"un déplacement purement vertical ne pivote pas")
	if _fail(res):
		return res
	# Sens : tirer le bord bas vers le bas grandit aussi. Le delta renvoyé est
	# celui que consomme resized_surface_size, qui applique lui-même le sens
	# d'extérieur de chaque bord : c'est donc la taille FINALE qu'il faut vérifier.
	h = Windows3DScript.resize_hinge("pitch", "bottom",
		Basis.IDENTITY, MESH, Vector3(0.0, -0.5, 0.0))
	var ppu := Vector2(SURFACE.x / MESH.x, SURFACE.y / MESH.y)
	var grown: Vector2 = Windows3DScript.resized_surface_size(SURFACE, "bottom",
		h["delta"], ppu)
	res = Runner.assert_approx(grown.y, SURFACE.y + 0.5 * ppu.y, 0.001,
		"tirer le bord bas vers le bas doit agrandir la hauteur")
	if _fail(res):
		return res
	res = Runner.assert_approx(grown.x, SURFACE.x, 0.001,
		"et ne doit jamais toucher la largeur")
	if _fail(res):
		return res
	return true

func test_hinge_depth_comes_from_the_gaze() -> Variant:
	# Lacet : regarder plus haut éloigne le bord tiré vers le fond.
	var h: Dictionary = Windows3DScript.resize_hinge("yaw", "right",
		Basis.IDENTITY, MESH, Vector3(0.0, 0.4, 0.0))
	var growth: float = (h["delta"] as Vector2).x
	var expected := sqrt(MESH.x * MESH.x + 0.4 * 0.4) - MESH.x
	var res: Variant = Runner.assert_approx(growth, expected, 0.0001,
		"le regard vertical doit piloter la profondeur, pas la largeur")
	if _fail(res):
		return res
	res = Runner.assert_true(growth > 0.0,
		"reculer le bord en grandissant légèrement est la signature de l'arc")
	if _fail(res):
		return res
	# La base pivote autour de la VERTICALE, du côté vers le fond (-Z).
	res = Runner.assert_approx(
		h["basis"].x.normalized().signed_angle_to(
			Vector3(MESH.x, 0.0, -0.4).normalized(), Vector3.UP),
		0.0, 0.0001, "le lacet doit tourner autour de la verticale, vers le fond")
	if _fail(res):
		return res
	# Tangage : le regard HORIZONTAL remplace le vertical, symétriquement.
	h = Windows3DScript.resize_hinge("pitch", "top",
		Basis.IDENTITY, MESH, Vector3(0.4, 0.0, 0.0))
	res = Runner.assert_approx((h["delta"] as Vector2).y,
		sqrt(MESH.y * MESH.y + 0.4 * 0.4) - MESH.y, 0.0001,
		"le tangage se pilote au regard horizontal")
	if _fail(res):
		return res
	res = Runner.assert_approx(
		h["basis"].y.normalized().signed_angle_to(
			Vector3(0.0, MESH.y, -0.4).normalized(), Vector3.RIGHT),
		0.0, 0.0001, "le tangage doit tourner autour de l'horizontale, vers le fond")
	if _fail(res):
		return res
	return true

func test_corner_drag_never_reads_depth() -> Variant:
	# Coin : le regard le long de l'axe du pivot règle DÉJÀ l'autre dimension,
	# il ne doit donc pas être rejoué en profondeur — sinon la fenêtre pivote
	# pendant qu'on ajuste sa taille.
	var h: Dictionary = Windows3DScript.resize_hinge("yaw", "bottomright",
		Basis.IDENTITY, MESH, Vector3(0.0, 0.4, 0.0))
	var res: Variant = Runner.assert_eq(h["delta"], Vector2.ZERO,
		"un regard vertical ne doit rien modifier pendant un coin")
	if _fail(res):
		return res
	res = Runner.assert_approx(h["basis"].x.normalized().dot(Vector3.RIGHT), 1.0, 0.0001,
		"aucune rotation parasite pendant un coin")
	if _fail(res):
		return res
	h = Windows3DScript.resize_hinge("pitch", "topleft",
		Basis.IDENTITY, MESH, Vector3(0.4, 0.0, 0.0))
	res = Runner.assert_eq(h["delta"], Vector2.ZERO,
		"symétrique : un regard horizontal ne modifie rien pendant un coin")
	if _fail(res):
		return res
	# Mode plan : la fonction ne doit rien faire.
	h = Windows3DScript.resize_hinge("", "right", Basis.IDENTITY, MESH,
		Vector3(0.5, 0.4, 0.0))
	res = Runner.assert_eq(h["delta"], Vector2.ZERO,
		"sans charnière, le delta est nul (le mode plan s'en charge)")
	if _fail(res):
		return res
	return true

func test_start_resize_arms_the_hinge_from_the_real_snap() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad: Node3D = win3d.quads[WID]
	var aim := _aim()
	# Sans voisin : les deux côtés testés restent plans.
	win3d._start_resize(WID, quad, aim[0], aim[1], "right")
	var res: Variant = Runner.assert_eq(win3d.resize_hinge_mode, "",
		"un bord latéral sans voisin doit rester plan")
	if _fail(res):
		return res
	# Voisine collée à gauche, bord gauche tiré : lacet.
	_snap_neighbour("left")
	win3d._start_resize(WID, quad, aim[0], aim[1], "left")
	res = Runner.assert_eq(win3d.resize_hinge_mode, "yaw",
		"un bord latéral partagé doit armer le lacet")
	if _fail(res):
		return res
	# …mais le bord opposé, non partagé, reste plan : la charnière suit le bord
	# TIRÉ, pas la simple présence d'une voisine.
	win3d._start_resize(WID, quad, aim[0], aim[1], "right")
	res = Runner.assert_eq(win3d.resize_hinge_mode, "",
		"le bord opposé non partagé doit rester plan")
	if _fail(res):
		return res
	_teardown()
	return true

func test_shared_top_edge_pitches_the_titlebar() -> Variant:
	var build: Variant = _build_world()
	if _fail(build):
		return build
	var quad: Node3D = win3d.quads[WID]
	var aim := _aim()
	_snap_neighbour("top")
	win3d._start_resize(WID, quad, aim[0], aim[1], "top")
	var res: Variant = Runner.assert_eq(win3d.resize_hinge_mode, "pitch",
		"une barre de titre sous une voisine doit pivoter en tangage")
	if _fail(res):
		return res
	res = Runner.assert_eq(win3d.resizing_edge, "top",
		"le drag de barre de titre reste un resize par le haut")
	if _fail(res):
		return res
	win3d._end_group_resize()
	res = Runner.assert_eq(win3d.resize_hinge_mode, "",
		"le relâchement doit désarmer la charnière")
	if _fail(res):
		return res
	_teardown()
	return true
