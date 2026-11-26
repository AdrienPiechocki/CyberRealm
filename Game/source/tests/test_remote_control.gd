extends Node
## Tests de la prise de contrôle d'une fenêtre partagée (scripts/network/lan/remote_control.gd), côté propriétaire
## et invité, sans réseau (émetteur explicite).

const Runner = preload("res://tests/runner.gd")
const RC = preload("res://scripts/network/lan/remote_control.gd")

class FakeComp extends Node:
	var calls: Array = []
	func forward_pointer_motion(w, x, y): calls.append(["motion", w, x, y])
	func forward_pointer_button(w, b, p): calls.append(["button", w, b, p])
	func forward_pointer_axis(w, dx, dy): calls.append(["axis", w, dx, dy])
	func forward_keyboard_key(c, l, p): calls.append(["key", c, l, p])
	func set_window_keyboard_focus(w): calls.append(["focus", w])

class FakeLan extends Node:
	var compositor: Node = null
	var focus = null
	var _players := {7: {"name": "Bob", "color": Color.RED}}
	func is_session_active() -> bool: return true
	func online_restricted() -> bool: return false
	func window_share_restricted() -> bool: return false

class FakeWin3D extends Node:
	var quads: Dictionary = {}
	var shared: Dictionary = {}
	func is_window_shared(w: int) -> bool: return shared.has(w)

var _n: Array = []

func _make() -> Node:
	var comp := FakeComp.new()
	var lan := FakeLan.new()
	lan.compositor = comp
	var w := FakeWin3D.new()
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	var body := StaticBody3D.new()
	body.set_meta("surface_size", Vector2(800, 600))
	body.set_meta("content_offset", Vector2(10, 20))
	quad.add_child(body)
	add_child(quad)
	w.quads[5] = quad
	w.shared[5] = true
	var rc: Node = RC.new()
	rc.lan = lan
	rc.win3d = w
	_n.append_array([comp, lan, w, quad, rc])
	return rc

func _done(r: Variant) -> Variant:
	for n in _n:
		if is_instance_valid(n): n.free()
	_n.clear()
	return r

func test_request_answer_and_inputs():
	var rc := _make()
	var asked: Array = []
	rc.control_requested.connect(func(p, w): asked.append([p, w]))
	rc._on_request(7, 5)
	var r: Variant = Runner.assert_eq(asked, [[7, 5]], "demande transmise au propriétaire")
	if r is String: return _done(r)
	rc._on_request(8, 5)                             # deuxième demande pendant la première : refusée d'office
	r = Runner.assert_eq(rc._pending.size(), 1, "une demande à la fois")
	if r is String: return _done(r)
	rc.answer(5, true)
	r = Runner.assert_eq(rc.controller_of(5), 7, "contrôle accordé")
	if r is String: return _done(r)
	var comp: Node = rc.lan.compositor
	rc._on_pointer(9, 5, 0.5, 0.5)                   # pas l'invité : ignoré
	rc._on_pointer(7, 5, 0.5, 0.5)
	r = Runner.assert_eq(comp.calls, [["motion", 5, 410.0, 320.0]], "(u, v) -> coordonnées de la fenêtre")
	if r is String: return _done(r)
	comp.calls.clear()
	rc._on_key(7, 5, KEY_A, 0, true)
	rc._on_button(7, 5, 0x110, true)
	rc._on_button(7, 5, 0x999, true)                 # bouton inconnu
	r = Runner.assert_eq(comp.calls, [["focus", 5], ["key", KEY_A, 0, true], ["button", 5, 0x110, true]], "touches et clic")
	if r is String: return _done(r)
	comp.calls.clear()
	rc.revoke(5)
	r = Runner.assert_eq(comp.calls.size(), 2, "reprise de la main : touche et bouton tenus relâchés")
	if r is String: return _done(r)
	return _done(Runner.assert_eq(rc.controller_of(5), -1, "plus de contrôleur"))

func test_vt_switch_filtered_and_rate_limited():
	var rc := _make()
	rc._on_request(7, 5)
	rc.answer(5, true)
	var comp: Node = rc.lan.compositor
	rc._on_key(7, 5, KEY_CTRL, 0, true)
	rc._on_key(7, 5, KEY_ALT, 0, true)
	comp.calls.clear()
	rc._on_key(7, 5, KEY_F2, 0, true)
	var r: Variant = Runner.assert_eq(comp.calls, [], "Ctrl+Alt+F2 filtré")
	if r is String: return _done(r)
	for i in 200:
		rc._on_pointer(7, 5, 0.1, 0.1)
	var n := 0
	for c in comp.calls:
		if c[0] == "motion": n += 1
	return _done(Runner.assert_eq(n, RC.MAX_POINTER_PER_SEC, "au plus 120 mouvements par seconde"))

func test_unshared_window_refused():
	var rc := _make()
	rc.win3d.shared.clear()
	var asked: Array = []
	rc.control_requested.connect(func(p, w): asked.append(p))
	rc._on_request(7, 5)
	return _done(Runner.assert_true(asked.is_empty() and rc._pending.is_empty(), "fenêtre non partagée : refus"))

func test_guest_side_state():
	var rc := _make()
	rc._requested[RC.key_of(1, 5)] = 0
	var changes: Array = []
	rc.control_changed.connect(func(o, w, a): changes.append([o, w, a]))
	rc._on_answer(2, 5, true)                        # réponse d'un autre joueur que le propriétaire : ignorée
	rc._on_answer(1, 5, true)
	var r: Variant = Runner.assert_true(rc.is_controlling(1, 5) and changes == [[1, 5, true]], "contrôle accordé côté invité")
	if r is String: return _done(r)
	rc._on_revoke(1, 5)
	return _done(Runner.assert_true(not rc.is_controlling(1, 5) and changes.size() == 2, "contrôle retiré"))
