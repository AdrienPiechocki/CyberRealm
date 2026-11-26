extends Node
## Tests de scripts/main/toplevel_bridge.gd : fenêtre autorisée à capturer les raccourcis
## (keyboard-shortcuts-inhibit) et exécution des requêtes de barre de tâches (foreign-toplevel-management).

const Runner = preload("res://tests/runner.gd")
const Bridge = preload("res://scripts/main/toplevel_bridge.gd")

# ── Doublures ─────────────────────────────────────────────────────────────

class FakeCompositor extends Node:
	signal toplevel_request(window_id: int, action: String, value: bool)
	signal shortcuts_inhibit_changed(window_id: int, active: bool)
	var calls: Array = []
	var inhibit_window := -1
	func set_toplevel_minimized(id: int, v: bool) -> void: calls.append(["minimized", id, v])
	func set_toplevel_fullscreen(id: int, v: bool) -> void: calls.append(["fullscreen", id, v])
	func set_window_keyboard_focus(id: int) -> void: calls.append(["kbfocus", id])
	func close_window(id: int) -> void: calls.append(["close", id])
	func set_shortcuts_inhibit_window(id: int) -> void: inhibit_window = id
	func is_shortcuts_inhibited() -> bool: return false

class FakeWin3D extends Node:
	signal window_hidden_changed(window_id: int, hidden: bool)
	var quads: Dictionary = {}
	var window_titles: Dictionary = {}
	func toggle_hide(id: int) -> void:
		quads[id].visible = not quads[id].visible
		window_hidden_changed.emit(id, not quads[id].visible)

class FakeFocus extends Node:
	signal shortcuts_release_requested
	var focus_stack: Array = []
	var remote := false
	func is_active() -> bool: return not focus_stack.is_empty() or remote
	func is_remote() -> bool: return remote
	func get_focus_window_id() -> int: return -1 if focus_stack.is_empty() else int(focus_stack[-1])
	func enter_focus(id: int) -> void:
		if not focus_stack.has(id): focus_stack.append(id)
	func exit_focus() -> void: focus_stack.clear()

class FakeFx extends Node:
	var flashed: Array = []
	func flash_window(id: int) -> void: flashed.append(id)

class FakeMenu extends Node:
	var allow := true
	func is_shortcut_inhibit_allowed() -> bool: return allow

var _nodes: Array = []

func _make() -> Node:
	var comp := FakeCompositor.new()
	var w := FakeWin3D.new()
	for id in [1, 2]:
		var q := Node3D.new()
		w.quads[id] = q
		_nodes.append(q)
	var f := FakeFocus.new()
	var fx := FakeFx.new()
	var m := FakeMenu.new()
	var b: Node = Bridge.new()
	_nodes.append_array([comp, w, f, fx, m, b])
	b.setup(comp, w, f, fx, m)
	return b

func _free_all() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()

# ── Raccourcis : fenêtre autorisée ─────────────────────────────────────────

func test_inhibit_candidate_only_local_focus_when_allowed():
	var r: Variant = Runner.assert_eq(Bridge.inhibit_candidate(true, true, false, 7), 7, "focus local autorisé")
	if r is String: return r
	r = Runner.assert_eq(Bridge.inhibit_candidate(false, true, false, 7), -1, "option désactivée")
	if r is String: return r
	r = Runner.assert_eq(Bridge.inhibit_candidate(true, false, false, 7), -1, "hors mode focus (3D)")
	if r is String: return r
	return Runner.assert_eq(Bridge.inhibit_candidate(true, true, true, 7), -1, "focus distant (vue seule)")

func test_release_holds_until_focus_changes():
	# Reprise sur la fenêtre 7 : refusée tant qu'elle reste en focus.
	var r: Variant = Runner.assert_eq(Bridge.inhibit_window(7, 7), [-1, 7], "reprise active")
	if r is String: return r
	# Sortie du focus : la reprise est oubliée.
	r = Runner.assert_eq(Bridge.inhibit_window(-1, 7), [-1, -1], "sortie du focus")
	if r is String: return r
	# Autre fenêtre en focus : autorisée.
	return Runner.assert_eq(Bridge.inhibit_window(8, 7), [8, -1], "autre fenêtre")

func test_release_shortcuts_clears_window_until_refocus():
	var b := _make()
	b.focus.focus_stack = [1]
	b.process()
	var r: Variant = Runner.assert_eq(b.compositor.inhibit_window, 1, "fenêtre en focus autorisée")
	if r is String: _free_all(); return r
	b.release_shortcuts()
	b.process()
	r = Runner.assert_eq(b.compositor.inhibit_window, -1, "reprise : plus aucune fenêtre autorisée")
	if r is String: _free_all(); return r
	b.focus.focus_stack = []
	b.process()
	b.focus.focus_stack = [1]
	b.process()
	r = Runner.assert_eq(b.compositor.inhibit_window, 1, "nouveau focus : de nouveau autorisée")
	_free_all()
	return r

# ── Barre de tâches ────────────────────────────────────────────────────────

func test_minimize_hides_and_reports_state():
	var b := _make()
	b.compositor.toplevel_request.emit(1, "minimize", true)
	var r: Variant = Runner.assert_true(not b.win3d.quads[1].visible, "quad caché")
	if r is String: _free_all(); return r
	r = Runner.assert_true(b.compositor.calls.has(["minimized", 1, true]), "état minimized renvoyé")
	if r is String: _free_all(); return r
	b.compositor.toplevel_request.emit(1, "minimize", true)   # déjà caché : pas de bascule
	r = Runner.assert_true(not b.win3d.quads[1].visible, "toujours caché (pas de bascule)")
	_free_all()
	return r

func test_activate_unhides_focuses_and_flashes():
	var b := _make()
	b.win3d.toggle_hide(2)
	b.compositor.toplevel_request.emit(2, "activate", true)
	var r: Variant = Runner.assert_true(b.win3d.quads[2].visible, "fenêtre réaffichée")
	if r is String: _free_all(); return r
	r = Runner.assert_true(b.compositor.calls.has(["kbfocus", 2]), "focus clavier donné")
	if r is String: _free_all(); return r
	r = Runner.assert_eq(b.fx.flashed, [2], "flash pour la repérer")
	_free_all()
	return r

func test_fullscreen_enters_and_leaves_focus_and_reports():
	var b := _make()
	b.compositor.toplevel_request.emit(1, "fullscreen", true)
	b.process()
	var r: Variant = Runner.assert_eq(b.focus.focus_stack, [1], "mode focus ouvert")
	if r is String: _free_all(); return r
	r = Runner.assert_true(b.compositor.calls.has(["fullscreen", 1, true]), "état fullscreen renvoyé")
	if r is String: _free_all(); return r
	b.compositor.toplevel_request.emit(1, "fullscreen", false)
	b.process()
	r = Runner.assert_true(b.focus.focus_stack.is_empty() and b.compositor.calls.has(["fullscreen", 1, false]),
		"sortie du focus et état renvoyé")
	_free_all()
	return r

func test_fullscreen_refused_when_focus_not_allowed():
	var b := _make()
	b.can_enter_focus = func() -> bool: return false
	b.compositor.toplevel_request.emit(1, "maximize", true)
	var r: Variant = Runner.assert_true(b.focus.focus_stack.is_empty(), "pas de focus en vue libre / menu ouvert")
	_free_all()
	return r

func test_close_and_unknown_window():
	var b := _make()
	b.compositor.toplevel_request.emit(1, "close", true)
	b.compositor.toplevel_request.emit(99, "close", true)   # fenêtre inconnue : ignorée
	var r: Variant = Runner.assert_eq(b.compositor.calls, [["close", 1]], "seule la fenêtre connue est fermée")
	_free_all()
	return r
