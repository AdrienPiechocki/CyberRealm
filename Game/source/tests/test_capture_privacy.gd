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
