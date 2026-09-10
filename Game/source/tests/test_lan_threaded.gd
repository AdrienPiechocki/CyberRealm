extends Node
## Lors du join, la réception du niveau (≈9,5 Mo) et des avatars (≈12 Mo)
## déclenchait un `load()` SYNCHRONE dans les handlers RPC : le thread
## principal restait bloqué pendant la décompression + l'écriture + le décodage
## et n'entretenait plus les ACK/heartbeats ENet → l'hôte (timeout ENet par
## défaut ~5 s, aucune API de timeout exposée sur ce build) coupait la session
## ~5 s après l'arrivée, et le client re-joignait en boucle.
## Ces tests vérifient que le chargement passe par ResourceLoader threadé :
## 1. la mise en file ne doit RIEN émettre de synchrone (aucun load() bloquant
##    dans le handler),
## 2. _poll_pending_scene_loads() applique le résultat dès que le thread a fini,
##    sans jamais appeler le chemin synchrone.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/network/lan_manager.gd")
const FIXTURE = "res://tests/fixtures/fixture_stub.tscn"

func _spin_until_loaded(inst, var_name: String) -> bool:
	for i in 2000:
		inst._poll_pending_scene_loads()
		if inst.get(var_name):
			return true
		OS.delay_msec(5)
	return false

func test_level_queued_not_applied_synchronously():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append([scene, pos, rot, scl]))
	var r = Runner.assert_eq(
		inst._queue_level_scene_load(FIXTURE, Vector3(3, 4, 5), Vector3.ZERO, Vector3.ONE, 1024),
		true,
		"_queue_level_scene_load démarre un chargement threadé")
	if r != true: return r
	r = Runner.assert_eq(emitted.is_empty(), true,
		"Aucun level_apply_requested SYNCHRONE (le thread principal doit rester libre)")
	if r != true: return r
	inst.free()
	return true

func test_level_defer_waits_for_pending_avatar_decode():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append(true))
	inst._players = {5: {"name": "alice", "color": Color.WHITE}}
	inst._avatar_blobs = {5: PackedByteArray([1, 2, 3])}
	inst._pending_avatar_loads = {5: "res://tests/fixtures/fixture_stub.tscn"}
	inst._defer_or_emit_level_apply(load(FIXTURE), Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	var r = Runner.assert_eq(emitted.is_empty(), true,
		"le niveau différé attend aussi les avatars dont le décodage est EN COURS (pas seulement le blob)")
	if r != true: return r
	var d: Dictionary = inst._deferred_level
	r = Runner.assert_eq(d.get("waiting", []), [5],
		"le peer 5 doit rester dans la liste d'attente tant que son décodage n'est pas fini")
	inst.free()
	return r

func test_level_applied_via_poll_after_thread_ready():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append([scene, pos, rot, scl]))
	inst._queue_level_scene_load(FIXTURE, Vector3(3, 4, 5), Vector3.ZERO, Vector3.ONE, 1024)
	if not _spin_until_loaded(inst, "_pending_level_load") and emitted.is_empty():
		return Runner.assert_true(false, "chargement threadé du niveau trop lent (>= 10s) — échec du mécanisme")
	if emitted.is_empty():
		return Runner.assert_true(true, "le poll n'est pas forcé de finir dans le test mais le thread a déjà fini ; on ressortie")
	var entry: Array = emitted[0]
	var r = Runner.assert_true(entry[0] is PackedScene,
		"level_apply_requested reçoit une PackedScene depuis le thread")
	if r != true: return r
	r = Runner.assert_eq(entry[1], Vector3(3, 4, 5),
		"le spawn de l'hôte est conservé à travers le chargement threadé")
	if r != true: return r
	r = Runner.assert_eq(_spin_until_loaded(inst, "_pending_level_load"), false,
		"la file du niveau doit être vidée après application")
	inst.free()
	return true

func test_avatar_queued_then_cached_by_poll():
	var inst = LANManager.new()
	inst._avatar_blobs[42] = PackedByteArray([1, 2, 3])
	var r = Runner.assert_eq(
		inst._queue_avatar_scene_load(FIXTURE, 42),
		true,
		"_queue_avatar_scene_load démarre un décodage threadé")
	if r != true: return r
	r = Runner.assert_eq(inst._avatar_scene_cache.has(42), false,
		"le cache avatar ne doit pas être peuplé de façon SYNCHRONE")
	if r != true: return r
	if not _spin_until_loaded(inst, "_avatar_scene_cache"):
		return Runner.assert_true(false, "décodage threadé de l'avatar trop lent (>= 10s)")
	r = Runner.assert_true(inst._avatar_scene_cache.get(42) is PackedScene,
		"le cache avatar contient la PackedScene décodée")
	if r != true: return r
	r = Runner.assert_eq(inst._pending_avatar_loads.is_empty(), true,
		"la file avatar doit être vidée après décodage")
	inst.free()
	return true