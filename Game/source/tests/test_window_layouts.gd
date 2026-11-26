extends Node
## Tests de scripts/main/window_layouts.gd : disposition des fenêtres retrouvée d'une session à l'autre.

const Runner = preload("res://tests/runner.gd")
const Layouts = preload("res://scripts/main/window_layouts.gd")
const SAVE := "user://test_window_layouts.json"

# ── Doublures ─────────────────────────────────────────────────────────────

class FakeCompositor extends Node:
	var parents: Dictionary = {}
	var sizes: Dictionary = {}
	func get_window_parent_id(id: int) -> int: return int(parents.get(id, -1))
	func set_window_size(id: int, w: int, h: int) -> void: sizes[id] = Vector2i(w, h)

class FakeWin3D extends Node:
	var window_app_ids: Dictionary = {}
	var window_titles: Dictionary = {}
	var layouts: Dictionary = {}       # id -> layout renvoyé par get_window_layout
	var applied: Dictionary = {}       # id -> [xform, size, user_sized]
	var hidden: Dictionary = {}
	var is_moving := false
	var is_resizing := false
	func get_window_layout(id: int) -> Dictionary: return layouts.get(id, {})
	func apply_saved_layout(id: int, xform: Transform3D, size: Vector2, user_sized: bool) -> void:
		applied[id] = [xform, size, user_sized]
	func toggle_hide(id: int) -> void: hidden[id] = not hidden.get(id, false)

class FakeFocus extends Node:
	var focus_stack: Array = []
	var forced: Dictionary = {}
	func is_active() -> bool: return not focus_stack.is_empty()
	func get_force_game(id: int) -> int: return int(forced.get(id, -1))
	func set_force_game(id: int, on: bool) -> void: forced[id] = 1 if on else 0

class FakePins extends Node:
	var pinned: Dictionary = {}
	func is_pinned(id: int) -> bool: return pinned.has(id)
	func pin(id: int, _t: Texture2D) -> void: pinned[id] = true

var _nodes: Array = []

func _session(key := "lvl") -> Node:
	var c := FakeCompositor.new()
	var w := FakeWin3D.new()
	var f := FakeFocus.new()
	var p := FakePins.new()
	var l: Node = Layouts.new()
	_nodes.append_array([c, w, f, p, l])
	l.save_path = SAVE
	l.level_key = func() -> String: return key
	l.setup(c, w, f, p)
	return l

func _map(l: Node, id: int, app: String, title: String) -> void:
	l.win3d.window_app_ids[id] = app
	l.win3d.window_titles[id] = title
	l.on_window_created(id, null)

func _layout(origin: Vector3, hidden := false) -> Dictionary:
	return {"transform": Transform3D(Basis.IDENTITY, origin), "size": Vector2(3, 2), "user_sized": true,
		"surface_size": Vector2(1280, 720), "hidden": hidden}

func _cleanup() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	if FileAccess.file_exists(SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))

# ── Logique pure ───────────────────────────────────────────────────────────

func test_match_prefers_exact_title_then_inclusion_then_recent():
	var e := [
		{"uid": "a", "app_id": "kitty", "title": "zsh", "last_seen": 5},
		{"uid": "b", "app_id": "kitty", "title": "vim main.c", "last_seen": 1},
		{"uid": "c", "app_id": "kitty", "title": "htop", "last_seen": 9},
		{"uid": "d", "app_id": "firefox", "title": "zsh", "last_seen": 99},
	]
	var r: Variant = Runner.assert_eq(Layouts.match_entry(e, "kitty", "zsh", {}), 0, "titre identique")
	if r is String: return r
	r = Runner.assert_eq(Layouts.match_entry(e, "kitty", "main.c", {}), 1, "titre inclus")
	if r is String: return r
	r = Runner.assert_eq(Layouts.match_entry(e, "kitty", "bash", {}), 2, "sinon la plus récente")
	if r is String: return r
	r = Runner.assert_eq(Layouts.match_entry(e, "kitty", "zsh", {"a": true}), 2, "entrée déjà attribuée sautée")
	if r is String: return r
	return Runner.assert_eq(Layouts.match_entry(e, "gimp", "zsh", {}), -1, "autre app_id : aucune")

func test_trim_keeps_most_recent():
	var e: Array = []
	for i in 10:
		e.append({"uid": str(i), "last_seen": i})
	var kept := Layouts.trim_entries(e, 3)
	return Runner.assert_eq(kept.map(func(x): return x["uid"]), ["9", "8", "7"], "3 plus récentes")

func test_transform_round_trip_and_invalid():
	var t := Transform3D(Basis(Vector3.UP, 0.7), Vector3(1, 2, 3))
	var back: Variant = Layouts.array_to_transform(Layouts.transform_to_array(t))
	var r: Variant = Runner.assert_true(back is Transform3D and (back as Transform3D).is_equal_approx(t), "aller-retour")
	if r is String: return r
	r = Runner.assert_true(Layouts.array_to_transform([1, 2]) == null, "taille invalide")
	if r is String: return r
	var zero := [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]
	return Runner.assert_true(Layouts.array_to_transform(zero) == null, "base dégénérée")

# ── Cycle complet : session 1 -> fichier -> session 2 ──────────────────────

func test_window_found_again_next_session():
	var l := _session()
	_map(l, 1, "kitty", "zsh")
	l.win3d.layouts[1] = _layout(Vector3(4, 1, -2), true)
	l.pins.pinned[1] = true
	l.focus.forced[1] = 1
	l.on_window_unmapped(1)          # relevé à la fermeture
	l.save_now()
	_cleanup_nodes_only()

	var l2 := _session()
	_map(l2, 7, "kitty", "zsh")
	var applied: Array = l2.win3d.applied.get(7, [])
	var r: Variant = Runner.assert_true(not applied.is_empty() and (applied[0] as Transform3D).origin.is_equal_approx(Vector3(4, 1, -2)),
		"position restaurée")
	if r is String: _cleanup(); return r
	r = Runner.assert_eq(l2.compositor.sizes.get(7), Vector2i(1280, 720), "taille en pixels redemandée")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(l2.win3d.hidden.get(7, false), "cachée comme avant")
	if r is String: _cleanup(); return r
	r = Runner.assert_eq(l2.focus.forced.get(7), 1, "force_game reposé")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(not l2.pins.pinned.has(7), "épinglage attendu à la première image")
	if r is String: _cleanup(); return r
	l2.on_window_texture_updated(7, ImageTexture.new(), 10, 10)
	r = Runner.assert_true(l2.pins.pinned.has(7), "épinglée à la première image")
	_cleanup()
	return r

func test_two_windows_same_app_get_distinct_entries():
	var l := _session()
	_map(l, 1, "kitty", "zsh")
	_map(l, 2, "kitty", "zsh")
	l.win3d.layouts[1] = _layout(Vector3(1, 0, 0))
	l.win3d.layouts[2] = _layout(Vector3(2, 0, 0))
	l.on_window_unmapped(1)
	l.on_window_unmapped(2)
	l.save_now()
	_cleanup_nodes_only()

	var l2 := _session()
	_map(l2, 5, "kitty", "zsh")
	_map(l2, 6, "kitty", "zsh")
	var a: Vector3 = (l2.win3d.applied[5][0] as Transform3D).origin
	var b: Vector3 = (l2.win3d.applied[6][0] as Transform3D).origin
	var r: Variant = Runner.assert_true(not a.is_equal_approx(b), "deux places distinctes")
	_cleanup()
	return r

func test_ignored_windows_and_inactive_cases():
	# Boîte de dialogue, app_id vide, niveau sans clé, option désactivée : rien n'est suivi.
	var l := _session()
	l.compositor.parents[2] = 1
	_map(l, 2, "firefox", "Open file")
	_map(l, 3, "", "no app id")
	var r: Variant = Runner.assert_true(l._live.is_empty(), "dialogue et app_id vide ignorés")
	if r is String: _cleanup(); return r
	var l_lan := _session("")
	_map(l_lan, 4, "kitty", "zsh")
	r = Runner.assert_true(l_lan._live.is_empty(), "niveau reçu d'un hôte LAN : inactif")
	if r is String: _cleanup(); return r
	var l_off := _session()
	l_off.enabled = func() -> bool: return false
	_map(l_off, 5, "kitty", "zsh")
	r = Runner.assert_true(l_off._live.is_empty(), "option désactivée : inactif")
	_cleanup()
	return r

func test_no_snapshot_while_in_focus_or_moving():
	var l := _session()
	_map(l, 1, "kitty", "zsh")
	l.win3d.layouts[1] = _layout(Vector3(1, 0, 0))
	l._snapshot(1)
	l.win3d.layouts[1] = _layout(Vector3(9, 9, 9))
	l.focus.focus_stack = [1]
	l._snapshot(1)
	l.focus.focus_stack = []
	l.win3d.is_moving = true
	l._snapshot(1)
	var entry: Dictionary = l._find("lvl", l._live[1]["uid"])
	var r: Variant = Runner.assert_eq(entry["transform"].slice(9, 12), [1.0, 0.0, 0.0], "dernier état stable conservé")
	_cleanup()
	return r

func _cleanup_nodes_only() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()

# ── windows_3d réel : relevé et restauration de la disposition ──────────────

const Windows3DScript := preload("res://scripts/windows/windows_3d.gd")

func test_windows_3d_layout_round_trip():
	var w3d := Node3D.new()
	w3d.set_script(Windows3DScript)
	var player := Node3D.new()
	player.name = "Player"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	player.add_child(cam)
	get_tree().root.add_child(player)
	get_tree().root.add_child(w3d)
	w3d.setup(null, player)
	w3d.on_window_mapped(3, "Test", "app")
	var xform := Transform3D(Basis(Vector3.UP, 1.2), Vector3(5, 2, -3))
	w3d.apply_saved_layout(3, xform, Vector2(2.5, 1.5), true)
	var lay: Dictionary = w3d.get_window_layout(3)
	var r: Variant = Runner.assert_true((lay["transform"] as Transform3D).is_equal_approx(xform), "transform restauré")
	if r is String: player.free(); w3d.free(); return r
	r = Runner.assert_eq(lay["size"], Vector2(2.5, 1.5), "taille monde restaurée")
	if r is String: player.free(); w3d.free(); return r
	r = Runner.assert_true(lay["user_sized"], "user_sized posé")
	if r is String: player.free(); w3d.free(); return r
	w3d.toggle_hide(3)
	r = Runner.assert_true(w3d.get_window_layout(3)["hidden"], "état caché relevé")
	player.free()
	w3d.free()
	return r
