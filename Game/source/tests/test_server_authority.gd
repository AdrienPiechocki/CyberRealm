extends Node
## Tests de l'autorité serveur : positions des pairs et distances (lan_manager), relais des interactions.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")
const Interactor = preload("res://scripts/interaction/world_interactor.gd")

func test_peer_position_known_stale_and_within():
	var lan: Node = LANManager.new()
	lan.note_peer_position(5, Vector3(10, 0, 0))
	var r: Variant = Runner.assert_eq(lan.peer_position(5), Vector3(10, 0, 0), "position connue")
	if r is String: lan.free(); return r
	r = Runner.assert_true(lan.peer_within(5, Vector3(12, 0, 0), 3.0) and not lan.peer_within(5, Vector3(20, 0, 0), 3.0), "distance")
	if r is String: lan.free(); return r
	r = Runner.assert_eq(lan.peer_position(6), Vector3.INF, "pair inconnu")
	if r is String: lan.free(); return r
	lan._peer_pos[5]["t"] = Time.get_ticks_msec() - LANManager.PEER_POSITION_STALE_MSEC - 1
	r = Runner.assert_true(not lan.peer_within(5, Vector3(10, 0, 0), 3.0), "position périmée : refusé")
	lan.free()
	return r

class Target extends Node3D:
	var calls := 0
	func interact(_p: int) -> void: calls += 1

class FakeLan extends Node:
	var is_host := true
	var pos: Dictionary = {}
	func peer_position(peer: int) -> Vector3: return pos.get(peer, Vector3.INF)
	func peer_within(peer: int, p: Vector3, radius: float) -> bool:
		return pos.has(peer) and (pos[peer] as Vector3).distance_to(p) <= radius

func test_net_interaction_rejected_from_too_far():
	var root := Node.new()
	add_child(root)
	var level := Node3D.new()
	level.name = "Level"
	root.add_child(level)
	var t := Target.new()
	t.name = "Lever"
	level.add_child(t)
	var it: Node = Interactor.new()
	root.add_child(it)
	var lan := FakeLan.new()
	it.lan = lan
	var path := String(t.get_path())
	lan.pos[7] = Vector3(50, 0, 0)               # loin
	it._apply_net_interact(7, path, 7)
	var r: Variant = Runner.assert_eq(t.calls, 0, "trop loin : refusé")
	if r is String: root.free(); lan.free(); return r
	it._net_last_msec.clear()
	lan.pos[7] = Vector3(2, 0, 0)                # à portée
	it._apply_net_interact(7, path, 7)
	r = Runner.assert_eq(t.calls, 1, "à portée : accepté")
	if r is String: root.free(); lan.free(); return r
	it._net_last_msec.clear()
	it._apply_net_interact(8, path, 8)           # position inconnue, cette machine est l'hôte
	r = Runner.assert_eq(t.calls, 1, "position inconnue sur l'hôte : refusé")
	if r is String: root.free(); lan.free(); return r
	lan.is_host = false
	it._net_last_msec.clear()
	it._apply_net_interact(8, path, 8)           # client : il n'a pas forcément la position, il suit l'hôte
	r = Runner.assert_eq(t.calls, 2, "position inconnue sur un client : accepté")
	root.free()
	lan.free()
	return r
