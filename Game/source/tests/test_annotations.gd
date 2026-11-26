extends Node
## Tests des annotations sur une fenêtre partagée (scripts/network/lan/annotations.gd), sans réseau.

const Runner = preload("res://tests/runner.gd")
const Ann = preload("res://scripts/network/lan/annotations.gd")

class FakeLan extends Node:
	var shared := {}               # "owner:wid" -> true (fenêtres distantes partagées)
	func is_session_active() -> bool: return true
	func online_restricted() -> bool: return false
	func window_share_restricted() -> bool: return false
	func is_remote_window_shared(o: int, w: int) -> bool: return shared.has("%d:%d" % [o, w])

class FakeWin3D extends Node:
	var quads := {}
	var shared := {}
	func is_window_shared(w: int) -> bool: return shared.has(w)

func _make() -> Array:
	var lan := FakeLan.new()
	var w := FakeWin3D.new()
	var a: Node = Ann.new()
	a.lan = lan
	a.win3d = w
	return [a, lan, w]

func _free(x: Array) -> void:
	for n in x: n.free()

func test_local_stroke_and_eraser():
	var x := _make()
	var a: Node = x[0]
	a.begin_stroke(1, 5, Color.RED, 4.0, Vector2(0.1, 0.1))
	var r: Variant = Runner.assert_true(a.strokes(1, 5).is_empty(), "fenêtre non partagée : pas d'annotation")
	if r is String: _free(x); return r
	x[2].shared[5] = true
	a.begin_stroke(1, 5, Color.RED, 4.0, Vector2(0.1, 0.1))
	a.add_point(Vector2(0.2, 0.2))
	a.end_stroke()
	var s: Dictionary = a.strokes(1, 5).values()[0]
	r = Runner.assert_eq((s["points"] as PackedVector2Array).size(), 2, "trait de 2 points")
	if r is String: _free(x); return r
	a.erase_near(1, 5, Vector2(0.2, 0.21))
	r = Runner.assert_true(a.strokes(1, 5).is_empty(), "gomme : son propre trait effacé")
	_free(x)
	return r

func test_remote_rules():
	var x := _make()
	var a: Node = x[0]
	x[1].shared["7:3"] = true
	a._on_begin(9, 7, 3, 1, Color.BLUE, 4.0, false, Vector2(0.5, 0.5))
	a._on_points(9, 7, 3, 1, PackedVector2Array([Vector2(0.6, 0.6)]))
	a._on_end(9, 7, 3, 1)
	var r: Variant = Runner.assert_eq(a.strokes(7, 3).size(), 1, "trait d'un autre joueur reçu")
	if r is String: _free(x); return r
	a._on_erase(8, 7, 3, 1)                       # pas son trait
	a._on_clear(9, 7, 3)                          # pas le propriétaire
	r = Runner.assert_eq(a.strokes(7, 3).size(), 1, "gomme et effacement réservés (auteur / propriétaire)")
	if r is String: _free(x); return r
	a._on_clear(7, 7, 3)
	r = Runner.assert_true(a.strokes(7, 3).is_empty(), "le propriétaire efface tout")
	if r is String: _free(x); return r
	for i in 50:
		a._on_begin(9, 7, 3, 100 + i, Color.BLUE, 4.0, false, Vector2.ZERO)
	r = Runner.assert_true(a.strokes(7, 3).size() < 50, "au plus 40 messages par seconde et par pair")
	_free(x)
	return r

func test_ephemeral_and_unshare():
	var x := _make()
	var a: Node = x[0]
	x[2].shared[5] = true
	a.ephemeral = true
	a.begin_stroke(1, 5, Color.RED, 4.0, Vector2(0.1, 0.1))
	a.end_stroke()
	var k: String = a.strokes(1, 5).keys()[0]
	a.strokes(1, 5)[k]["ended_at"] = a._now() - Ann.EPHEMERAL_SEC - 1.0
	a._process(0.0)
	var r: Variant = Runner.assert_true(a.strokes(1, 5).is_empty(), "trait éphémère effacé après 4 s")
	if r is String: _free(x); return r
	a.ephemeral = false
	a.begin_stroke(1, 5, Color.RED, 4.0, Vector2(0.1, 0.1))
	a.end_stroke()
	x[2].shared.clear()
	a._process(0.0)
	r = Runner.assert_true(a.strokes(1, 5).is_empty(), "partage arrêté : annotations effacées")
	_free(x)
	return r
