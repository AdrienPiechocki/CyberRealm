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

# ── Instantané du niveau (arrivants, persistance) ──────────────────────────

const LevelSync = preload("res://scripts/network/lan/level_sync.gd")

class Snap extends Node3D:
	var applied: Array = []
	var resets := 0
	func net_reset() -> void: resets += 1
	func net_snapshot() -> Array: return [["b", 3], ["m", 4, Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))]]
	func net_apply_snapshot(e: Array) -> void: applied = e

func test_snapshot_validation_and_chunks():
	var r: Variant = Runner.assert_eq(LevelSync.chunk_entries(range(600), 256).map(func(c): return c.size()), [256, 256, 88], "découpage")
	if r is String: return r
	r = Runner.assert_eq(LevelSync.chunk_entries([], 256), [[]], "partie vide : un morceau vide")
	if r is String: return r
	r = Runner.assert_true(LevelSync.snapshot_part_ok("sync") and LevelSync.snapshot_part_ok("Interiors/Props"), "parties valides")
	if r is String: return r
	r = Runner.assert_true(not LevelSync.snapshot_part_ok("../../LAN") and not LevelSync.snapshot_part_ok("/root/X"), "pas de sortie du niveau")
	if r is String: return r
	r = Runner.assert_true(LevelSync.snapshot_entry_ok(["m", 4, Transform3D()]), "entrée simple")
	if r is String: return r
	return Runner.assert_true(not LevelSync.snapshot_entry_ok([[[["trop profond"]]]]) and not LevelSync.snapshot_entry_ok([Object.new()]),
		"entrées refusées (profondeur, objets)")

func _world(is_host: bool) -> Array:
	var lan: Node = LANManager.new()
	add_child(lan)
	var level := Node3D.new()
	level.name = "Level"
	add_child(level)
	var crate := Node3D.new()
	crate.name = "Crate"
	level.add_child(crate)
	var props := Snap.new()
	props.name = "Props"
	level.add_child(props)
	props.add_to_group("net_snapshot")
	lan._level_root = level
	lan.is_host = is_host
	return [lan, level, crate, props]

func test_snapshot_build_on_host_and_apply_on_client():
	var host := _world(true)
	host[2].position = Vector3(5, 0, 0)
	host[0].level_sync._level_sync_by_path["Crate"] = host[2]
	var parts: Dictionary = host[0].level_sync.build_snapshot()
	var r: Variant = Runner.assert_eq(parts.keys(), ["sync", "Props"], "parties : sync + nœud du groupe net_snapshot")
	if r is String: host[0].free(); host[1].free(); return r
	var client := _world(false)
	var ls: Node = client[0].level_sync
	ls.request_snapshot.call()       # remise à zéro du compteur (l'envoi est ignoré hors session)
	for part in parts:
		var chunks: Array = LevelSync.chunk_entries(parts[part], 1)       # morceaux d'une entrée : réassemblage
		for i in chunks.size():
			ls._receive_snapshot_chunk(1, part, i, chunks.size(), chunks[i])
	ls._receive_snapshot_chunk(42, "Props", 0, 1, [["b", 9]])           # pas le serveur : ignoré
	r = Runner.assert_eq(client[3].applied, parts["Props"], "net_apply_snapshot reçoit les entrées du serveur")
	if r is String: host[0].free(); host[1].free(); client[0].free(); client[1].free(); return r
	r = Runner.assert_eq(ls._level_sync_target.get("Crate"), host[2].transform, "transformation du décor à appliquer")
	host[0].free(); host[1].free(); client[0].free(); client[1].free()
	return r

# ── Persistance du monde (serveur dédié) ───────────────────────────────────

const DedicatedServer = preload("res://scripts/server/dedicated_server.gd")
const STATE := "user://test_world.state"

func _server_with_world() -> Array:
	var w := _world(true)
	var ds: Node = DedicatedServer.new()
	ds.lan = w[0]
	ds.state_path = STATE
	ds._blob_sha = "blob-A"
	return [ds] + w

func _free_server(x: Array) -> void:
	x[0].free(); x[1].free(); x[2].free()

func test_world_state_saved_and_reloaded():
	if FileAccess.file_exists(STATE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE))
	var a := _server_with_world()
	a[3].position = Vector3(7, 0, 0)
	a[1].level_sync._level_sync_by_path["Crate"] = a[3]
	a[0]._save_state()
	_free_server(a)
	var b := _server_with_world()
	b[1].is_host = false                    # au rechargement le serveur n'héberge pas encore
	b[0]._load_state()
	var r: Variant = Runner.assert_eq(b[3].position, Vector3(7, 0, 0), "transformation du décor rechargée")
	if r is String: _free_server(b); return r
	r = Runner.assert_eq(b[4].applied.size(), 2, "net_apply_snapshot reçoit les objets enregistrés")
	_free_server(b)
	if r is String: return r
	var c := _server_with_world()
	c[0]._blob_sha = "blob-B"                 # niveau réexporté
	c[0]._load_state()
	r = Runner.assert_true(c[4].applied.is_empty() and FileAccess.file_exists(STATE + ".old") and not FileAccess.file_exists(STATE),
		"autre niveau : état ignoré et mis de côté (.old)")
	_free_server(c)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE + ".old"))
	return r

func test_reset_world_only_for_admin_on_dedicated():
	var w := _world(true)
	var lan: Node = w[0]
	lan.dedicated = true
	var asked: Array = []
	lan.world_reset_requested.connect(func(p): asked.append(p))
	lan._players[5] = {"name": "Bob"}
	lan.level_sync._accept_admin_reset_for_test(5)
	var r: Variant = Runner.assert_eq(asked, [], "non-admin : refusé")
	if r is String: w[0].free(); w[1].free(); return r
	lan.session._admins[5] = true
	lan.level_sync._accept_admin_reset_for_test(5)
	r = Runner.assert_eq(asked, [5], "admin : demande transmise")
	w[0].free(); w[1].free()
	return r

func test_reset_world_in_place():
	var host := _world(true)
	var sent: Array = []
	host[0].level_sync.reset_world()
	var r: Variant = Runner.assert_eq(host[3].resets, 1, "serveur : net_reset sur les nœuds du groupe")
	host[0].free(); host[1].free()
	if r is String: return r
	var client := _world(false)
	var ls: Node = client[0].level_sync
	ls._level_sync_target["Crate"] = Transform3D(Basis.IDENTITY, Vector3(9, 9, 9))
	ls._reset_local()
	r = Runner.assert_true(client[3].resets == 1 and ls._level_sync_target.is_empty(),
		"client : net_reset et plus de cible de synchro (les objets ne repartent pas vers l'ancienne place)")
	client[0].free(); client[1].free()
	return r
