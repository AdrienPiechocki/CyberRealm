extends Node
## Tests des fenêtres privées (noires dans le partage d'écran) : scripts/windows/capture_privacy.gd.

const Runner = preload("res://tests/runner.gd")
const Privacy = preload("res://scripts/windows/capture_privacy.gd")
const TEST_PATH := "user://test_private_apps.json"

# Stand-in minimal de windows_3d.gd : seuls les membres lus par capture_privacy.
class FakeWin3D extends Node:
	var window_app_ids := {}
	var window_private := {}
	var quads := {}
	var popup_quads := {}
	var popup_parent_info := {}
	func set_window_private(wid: int, on: bool) -> void:
		if on:
			window_private[wid] = true
		else:
			window_private.erase(wid)
	func is_window_private(wid: int) -> bool:
		return window_private.has(wid)

class FakeCompositor extends RefCounted:
	var calls := []
	func set_window_capture_private(wid: int, on: bool) -> void:
		calls.append([wid, on])

func _make(win: FakeWin3D, comp: FakeCompositor) -> Node:
	var p: Node = Privacy.new()
	p.save_path = TEST_PATH
	add_child(p)
	p.setup(comp, win, null, null, null)
	return p

func _cleanup() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

# ── Découpe au plan proche ─────────────────────────────────────────────────

func test_clip_near_all_in_front():
	var pts: Array[Vector3] = [Vector3(-1, -1, -5), Vector3(1, -1, -5), Vector3(1, 1, -5), Vector3(-1, 1, -5)]
	return Runner.assert_eq(Privacy.clip_near(pts, -0.1).size(), 4, "quad devant la caméra intact")

func test_clip_near_all_behind():
	var pts: Array[Vector3] = [Vector3(-1, -1, 2), Vector3(1, -1, 2), Vector3(1, 1, 2), Vector3(-1, 1, 2)]
	return Runner.assert_eq(Privacy.clip_near(pts, -0.1).size(), 0, "quad derrière la caméra : rien")

func test_clip_near_partial():
	# Quad au sol qui passe sous la caméra : deux coins devant, deux derrière.
	var pts: Array[Vector3] = [Vector3(-1, -1, -5), Vector3(1, -1, -5), Vector3(1, -1, 3), Vector3(-1, -1, 3)]
	var out := Privacy.clip_near(pts, -0.1)
	var r: Variant = Runner.assert_eq(out.size(), 4, "découpé en quadrilatère")
	if r is String: return r
	for p in out:
		if p.z > -0.1 + 1e-5:
			return "point resté derrière le plan proche : %s" % p
	return true

# ── Mémorisation par app ───────────────────────────────────────────────────

func test_toggle_remembers_app_and_follows_its_windows():
	_cleanup()
	var win := FakeWin3D.new()
	add_child(win)
	win.window_app_ids = {1: "vesktop", 2: "vesktop", 3: "firefox"}
	var comp := FakeCompositor.new()
	var p := _make(win, comp)
	var r: Variant = Runner.assert_true(p.toggle(1), "première bascule : privée")
	if r is String: return r
	r = Runner.assert_true(win.is_window_private(2), "l'autre fenêtre de l'app suit")
	if r is String: return r
	r = Runner.assert_true(not win.is_window_private(3), "une autre app n'est pas touchée")
	if r is String: return r
	r = Runner.assert_true(comp.calls.has([1, true]) and comp.calls.has([2, true]), "capture directe noircie")
	if r is String: return r
	# Nouvelle session : une fenêtre de la même app est privée dès sa création.
	var p2 := _make(win, comp)
	win.window_app_ids[7] = "vesktop"
	p2.on_window_created(7, null)
	r = Runner.assert_true(win.is_window_private(7), "mémorisé d'une session à l'autre")
	if r is String: return r
	r = Runner.assert_true(not p2.toggle(7), "seconde bascule : plus privée")
	if r is String: return r
	r = Runner.assert_true(not win.is_window_private(1) and not win.is_window_private(2), "toute l'app redevient visible")
	if r is String: return r
	var p3 := _make(win, comp)
	win.window_app_ids[8] = "vesktop"
	p3.on_window_created(8, null)
	r = Runner.assert_true(not win.is_window_private(8), "oubli mémorisé")
	for n in [p, p2, p3, win]:
		n.queue_free()
	_cleanup()
	return r

func test_window_without_app_id_not_remembered():
	_cleanup()
	var win := FakeWin3D.new()
	add_child(win)
	win.window_app_ids = {4: ""}
	var p := _make(win, FakeCompositor.new())
	p.toggle(4)
	var r: Variant = Runner.assert_true(win.is_window_private(4), "privée pour cette fenêtre")
	if r is String: return r
	r = Runner.assert_true(not FileAccess.file_exists(TEST_PATH), "rien d'écrit sans app_id")
	p.queue_free()
	win.queue_free()
	_cleanup()
	return r

# ── Masques ────────────────────────────────────────────────────────────────

func test_mask_keeps_previous_frame_and_margin():
	_cleanup()
	var win := FakeWin3D.new()
	add_child(win)
	var p := _make(win, FakeCompositor.new())
	var r: Variant = Runner.assert_eq(p.mask_polygons(Vector2(100, 100)).size(), 0, "aucune fenêtre privée : aucun masque")
	if r is String: return r
	# Zone de la frame précédente encore masquée (retard de la relecture), élargie de la marge.
	p._prev = [PackedVector2Array([Vector2(10, 10), Vector2(20, 10), Vector2(20, 20), Vector2(10, 20)])]
	var vp := get_viewport().get_visible_rect().size
	var out: Array = p.mask_polygons(vp)
	r = Runner.assert_eq(out.size(), 1, "zone précédente conservée une frame")
	if r is String: return r
	var poly: PackedVector2Array = out[0]
	var minx := INF
	for v in poly:
		minx = minf(minx, v.x)
	r = Runner.assert_approx(minx, 10.0 - Privacy.MASK_MARGIN_PX, 0.01, "marge appliquée")
	if r is String: return r
	r = Runner.assert_eq(p.mask_polygons(vp).size(), 0, "puis oubliée")
	p.queue_free()
	win.queue_free()
	return r

# ── Fenêtres passées devant une fenêtre privée ─────────────────────────────

# Rectangle vertical 2x2 centré en (x, 0, z), face à +Z (caméra en z = 10).
func _rect3(x: float, z: float) -> Array:
	return [Vector3(x - 1, -1, z), Vector3(x + 1, -1, z), Vector3(x + 1, 1, z), Vector3(x - 1, 1, z)]

func test_window_in_front_hides_private_one():
	var cam := Vector3(0, 0, 10)
	var r: Variant = Runner.assert_true(Privacy.quad_in_front(_rect3(0.5, 1.0), _rect3(0, 0), cam),
		"fenêtre plus proche de la caméra : devant")
	if r is String: return r
	r = Runner.assert_true(not Privacy.quad_in_front(_rect3(0.5, -1.0), _rect3(0, 0), cam),
		"fenêtre derrière la privée : ne retire rien au masque")
	if r is String: return r
	# Caméra passée de l'autre côté : l'ordre s'inverse.
	return Runner.assert_true(Privacy.quad_in_front(_rect3(0.5, -1.0), _rect3(0, 0), Vector3(0, 0, -10)),
		"vu de derrière, la fenêtre du fond passe devant")

func test_crossing_windows_keep_the_mask():
	# Fenêtre perpendiculaire qui traverse la privée : ni devant ni derrière.
	var cross := [Vector3(0, -1, -1), Vector3(0, -1, 1), Vector3(0, 1, 1), Vector3(0, 1, -1)]
	return Runner.assert_true(not Privacy.quad_in_front(cross, _rect3(0, 0), Vector3(3, 0, 10)),
		"deux fenêtres qui se traversent : le masque reste entier")

func test_overlay_rules():
	var q3 := {"poly": PackedVector2Array(), "corners": _rect3(0, 0)}
	var r: Variant = Runner.assert_true(Privacy.occludes({"z": 0}, q3, Vector3.ZERO), "un overlay 2D cache toujours la scène 3D")
	if r is String: return r
	r = Runner.assert_true(not Privacy.occludes(q3, {"z": 0}, Vector3.ZERO), "un quad 3D ne cache jamais un overlay")
	if r is String: return r
	r = Runner.assert_true(Privacy.occludes({"z": 2002}, {"z": 2001}, Vector3.ZERO), "overlay au-dessus dans la pile du focus")
	if r is String: return r
	return Runner.assert_true(not Privacy.occludes({"z": 2001}, {"z": 2002}, Vector3.ZERO), "overlay en dessous : rien de retiré")

func _area(polys: Array) -> float:
	var a := 0.0
	for p: PackedVector2Array in polys:
		var s := 0.0
		for i in p.size():
			s += p[i].x * p[(i + 1) % p.size()].y - p[(i + 1) % p.size()].x * p[i].y
		a += absf(s) * 0.5
	return a

func _sq(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])

func test_subtract_partial_overlap():
	var out := Privacy.subtract_polygon([_sq(0, 0, 100, 100)], _sq(50, -10, 150, 110))
	return Runner.assert_approx(_area(out), 5000.0, 1.0, "la moitié recouverte n'est plus masquée")

func test_subtract_inner_window_never_makes_a_hole():
	# Petite fenêtre opaque devant le milieu d'une grande fenêtre privée : le masque doit l'épargner
	# sans contour de trou (le remplissage C++ remplirait le trou).
	var out := Privacy.subtract_polygon([_sq(0, 0, 100, 100)], _sq(40, 40, 60, 60))
	var r: Variant = Runner.assert_approx(_area(out), 10000.0 - 400.0, 1.0, "seule la fenêtre de devant est retirée")
	if r is String: return r
	var cw := Geometry2D.is_polygon_clockwise(out[0])
	for p: PackedVector2Array in out:
		if Geometry2D.is_polygon_clockwise(p) != cw:
			return "contour de trou produit"
		if Geometry2D.is_point_in_polygon(Vector2(50, 50), p):
			return "le centre de la fenêtre de devant est encore masqué"
	return true

func test_subtract_full_cover_removes_mask():
	var out := Privacy.subtract_polygon([_sq(10, 10, 20, 20)], _sq(0, 0, 100, 100))
	return Runner.assert_eq(out.size(), 0, "entièrement cachée : plus rien à noircir")

func test_real_scene_window_in_front_is_cut_from_mask():
	# Vraie scène : windows_3d, caméra en z = 5 regardant -Z ; fenêtre privée 21 en z = 0, fenêtre opaque 22
	# devant (z = 1) sur sa moitié droite. Le masque ne doit plus couvrir le centre de 22.
	var Win3D: Script = load("res://scripts/windows/windows_3d.gd")
	var win3d := Node3D.new()
	win3d.set_script(Win3D)
	var player := Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	player.add_child(cam)
	# Viewport dimensionné : celui de la racine headless n'a pas de taille, la projection y est dégénérée.
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	add_child(vp)
	vp.add_child(player)
	vp.add_child(win3d)
	cam.global_position = Vector3(0, 0, 5)
	cam.current = true
	win3d.setup(null, player)
	win3d.on_window_mapped(21, "Private", "app")
	win3d.on_window_mapped(22, "Front", "app")
	(win3d.quads[21].mesh as QuadMesh).size = Vector2(2, 2)
	(win3d.quads[22].mesh as QuadMesh).size = Vector2(1, 1)
	win3d.quads[21].global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	win3d.quads[22].global_transform = Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 1))
	win3d._alpha_translucent[22] = false
	win3d.set_window_private(21, true)
	var p: Node = Privacy.new()
	p.save_path = TEST_PATH
	vp.add_child(p)
	p.setup(null, win3d, null, null, null)
	# Interpolation physique : la transform de rendu de la caméra ne suit qu'après une frame.
	await get_tree().physics_frame
	await get_tree().process_frame
	var front_center := cam.unproject_position(Vector3(0.5, 0, 1))
	var private_left := cam.unproject_position(Vector3(-0.8, 0, 0))
	var polys: Array = p._current_polygons()
	# `ps` en paramètre : une lambda GDScript capture `polys` par valeur, elle ne verrait pas sa réaffectation.
	var covers := func(ps: Array, pt: Vector2) -> bool:
		for poly: PackedVector2Array in ps:
			if Geometry2D.is_point_in_polygon(pt, poly):
				return true
		return false
	var r: Variant = Runner.assert_true(covers.call(polys, private_left), "la partie découverte de la fenêtre privée reste noire")
	if r is String:
		pass
	else:
		r = Runner.assert_true(not covers.call(polys, front_center), "la fenêtre passée devant n'est plus noircie")
	if not (r is String):
		# Fenêtre translucide devant : on voit la privée à travers, le masque reste entier.
		win3d._alpha_translucent[22] = true
		polys = p._current_polygons()
		r = Runner.assert_true(covers.call(polys, front_center), "à travers une fenêtre translucide, le masque reste")
	vp.free()
	return r
