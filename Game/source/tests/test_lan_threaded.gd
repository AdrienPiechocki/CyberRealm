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

## Espion de _lan_log (revue finale, Issue 2) : seuls les appels à _lan_log
## sont capturés — les push_warning de production restent intacts, et aucun
## code de production n'est touché pour le test.
class LogSpyLanManager:
	extends LANManager
	var lan_logs: Array = []
	func _lan_log(msg: String, reset := false) -> void:
		lan_logs.append(msg)

## Libère un LANManager de test. Hors de l'arbre, _exit_tree() ne tourne pas : sans
## cette attente, une tâche de décodage encore en vol survit à l'objet et le
## moteur signale des RefCounted fuités à la sortie.
func _dispose(inst) -> void:
	if inst.level_transfer._level_decode_task >= 0:
		WorkerThreadPool.wait_for_task_completion(inst.level_transfer._level_decode_task)
		inst.level_transfer._level_decode_task = -1
	inst.free()

func _spin_until_loaded(inst, holder: Object, var_name: String) -> bool:
	for i in 2000:
		inst.level_transfer._poll_pending_scene_loads()
		if holder.get(var_name):
			return true
		OS.delay_msec(5)
	return false

func test_level_queued_not_applied_synchronously():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append([scene, pos, rot, scl]))
	var r = Runner.assert_eq(
		inst.level_transfer._queue_level_scene_load(FIXTURE, Vector3(3, 4, 5), Vector3.ZERO, Vector3.ONE, 1024),
		true,
		"_queue_level_scene_load démarre un chargement threadé")
	if r != true: return r
	r = Runner.assert_eq(emitted.is_empty(), true,
		"Aucun level_apply_requested SYNCHRONE (le thread principal doit rester libre)")
	if r != true: return r
	_dispose(inst)
	return true

func test_level_defer_waits_for_pending_avatar_decode():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append(true))
	inst._players = {5: {"name": "alice", "color": Color.WHITE}}
	inst.players._avatar_blobs = {5: PackedByteArray([1, 2, 3])}
	inst.players._pending_avatar_loads = {5: "res://tests/fixtures/fixture_stub.tscn"}
	inst.level_transfer._defer_or_emit_level_apply(load(FIXTURE), Vector3.ZERO, Vector3.ZERO, Vector3.ONE)
	var r = Runner.assert_eq(emitted.is_empty(), true,
		"le niveau différé attend aussi les avatars dont le décodage est EN COURS (pas seulement le blob)")
	if r != true: return r
	var d: Dictionary = inst.level_transfer._deferred_level
	r = Runner.assert_eq(d.get("waiting", []), [5],
		"le peer 5 doit rester dans la liste d'attente tant que son décodage n'est pas fini")
	_dispose(inst)
	return r

func test_level_applied_via_poll_after_thread_ready():
	var inst = LANManager.new()
	var emitted: Array = []
	inst.level_apply_requested.connect(func(scene, pos, rot, scl): emitted.append([scene, pos, rot, scl]))
	inst.level_transfer._queue_level_scene_load(FIXTURE, Vector3(3, 4, 5), Vector3.ZERO, Vector3.ONE, 1024)
	# On attend l'APPLICATION du niveau (signal émis par le poll), pas que
	# _pending_level_load soit non vide : il l'est dès la mise en file, ce qui
	# faisait sortir le test aussitôt sans rien vérifier (ni libérer inst).
	for i in 2000:
		inst.level_transfer._poll_pending_scene_loads()
		if not emitted.is_empty():
			break
		OS.delay_msec(5)
	if emitted.is_empty():
		_dispose(inst)
		return Runner.assert_true(false, "chargement threadé du niveau trop lent (>= 10s) — échec du mécanisme")
	var entry: Array = emitted[0]
	var r = Runner.assert_true(entry[0] is PackedScene,
		"level_apply_requested reçoit une PackedScene depuis le thread")
	if r != true:
		_dispose(inst)
		return r
	r = Runner.assert_eq(entry[1], Vector3(3, 4, 5),
		"le spawn de l'hôte est conservé à travers le chargement threadé")
	if r != true:
		_dispose(inst)
		return r
	r = Runner.assert_true(inst.level_transfer._pending_level_load.is_empty(),
		"la file du niveau doit être vidée après application")
	_dispose(inst)
	return r

func test_avatar_queued_then_cached_by_poll():
	var inst = LANManager.new()
	inst.players._avatar_blobs[42] = PackedByteArray([1, 2, 3])
	var r = Runner.assert_eq(
		inst.players._queue_avatar_scene_load(FIXTURE, 42),
		true,
		"_queue_avatar_scene_load démarre un décodage threadé")
	if r != true: return r
	r = Runner.assert_eq(inst.players._avatar_scene_cache.has(42), false,
		"le cache avatar ne doit pas être peuplé de façon SYNCHRONE")
	if r != true: return r
	if not _spin_until_loaded(inst, inst.players, "_avatar_scene_cache"):
		return Runner.assert_true(false, "décodage threadé de l'avatar trop lent (>= 10s)")
	r = Runner.assert_true(inst.players._avatar_scene_cache.get(42) is PackedScene,
		"le cache avatar contient la PackedScene décodée")
	if r != true: return r
	r = Runner.assert_eq(inst.players._pending_avatar_loads.is_empty(), true,
		"la file avatar doit être vidée après décodage")
	_dispose(inst)
	return true

func test_level_decode_is_not_synchronous() -> Variant:
	var inst = LANManager.new()
	# Payload réellement compressé ZSTD (T0 : decompress d'octets bruts
	# échouerait → chemin d'échec → le test ne pourrait jamais voir la file).
	# On compresse un minuscule PackedScene RÉEL (sauvegardé puis relu) : le
	# worker réécrit donc un fichier valide et le chargement threadé mis en
	# file par le poll passe sans erreur asynchrone — des octets factices
	# déclenchaient « Unrecognized binary resource file » dans la sortie.
	var tmp_node := Node3D.new()
	tmp_node.name = "T4Fixture"
	var tmp_scene := PackedScene.new()
	tmp_scene.pack(tmp_node)
	tmp_node.free()
	var save_err := ResourceSaver.save(tmp_scene, "user://t4_fixture.scn")
	var plain := FileAccess.get_file_as_bytes("user://t4_fixture.scn")
	# Nettoyage best-effort du fixture temporaire (non asserté) : ses octets
	# sont déjà en mémoire, plus besoin du fichier sur disque.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://t4_fixture.scn"))
	var r: Variant = Runner.assert_true(save_err == OK and not plain.is_empty(),
		"fixture de scène temporaire écrite (prérequis)")
	if r is String:
		_dispose(inst)
		return r
	var raw := plain.compress(FileAccess.COMPRESSION_ZSTD)
	r = Runner.assert_true(
		inst.level_transfer._begin_level_decode(raw, plain.size(), Vector3(1, 2, 3), Vector3.ZERO, Vector3.ONE),
		"décodage soumis au pool de threads")
	if r is String:
		_dispose(inst)
		return r
	r = Runner.assert_true(inst.level_transfer._pending_level_load.is_empty(),
		"le handler de chunk ne doit RIEN mettre en file de façon synchrone")
	if r is String:
		_dispose(inst)
		return r
	# Spin : le thread finit, _poll_level_decode met la file en place.
	for i in 2000:
		inst.level_transfer._poll_level_decode()
		if not inst.level_transfer._pending_level_load.is_empty():
			break
		OS.delay_msec(5)
	r = Runner.assert_true(not inst.level_transfer._pending_level_load.is_empty(),
		"la file de chargement est peuplée par le poll, pas par le handler")
	# Le poll a lancé un chargement threadé (ResourceLoader) que personne ne
	# réclame : on le récupère pour que le moteur n'en garde pas l'état à la sortie.
	if not inst.level_transfer._pending_level_load.is_empty():
		ResourceLoader.load_threaded_get(String(inst.level_transfer._pending_level_load["path"]))
	_dispose(inst)
	return r

func test_level_decode_failure_finalizes_join() -> Variant:
	var inst = LANManager.new()
	inst._pending_join = true
	# Arrangement de test uniquement (aucun changement production) :
	# _finalize_join → _announce_self émettrait un RPC depuis cette instance
	# nue hors arbre → « !is_inside_tree() » en sortie de suite. Annoncé d'ores
	# et déjà : l'annonce est sautée, l'assertion reste identique.
	inst._announced = true
	# Taille déclarée fausse mais modeste → decompress échoue sans grosse allocation.
	var raw := PackedByteArray([1, 2, 3])
	var r: Variant = Runner.assert_true(
		inst.level_transfer._begin_level_decode(raw, raw.size() + 100, Vector3.ZERO, Vector3.ZERO, Vector3.ONE),
		"tâche soumise")
	if r is String:
		_dispose(inst)
		return r
	for i in 2000:
		inst.level_transfer._poll_level_decode()
		if not inst._pending_join:
			break
		OS.delay_msec(5)
	r = Runner.assert_true(not inst._pending_join,
		"échec de décodage = _finalize_join (jamais de join bloqué)")
	_dispose(inst)
	return r

func test_level_decode_drop_when_load_already_pending() -> Variant:
	# Revue finale, Issue 2 : quand un chargement de niveau est DÉJÀ en file,
	# le résultat du décodage est déposé (comportement volontaire, maintenu) —
	# mais le log ne doit plus prétendre « queued threaded load » : un
	# diagnostic honnête doit dire que le résultat est dropped, et la file
	# déjà en attente ne doit surtout pas être écrasée.
	var inst = LogSpyLanManager.new()
	# Même montage que test_level_decode_is_not_synchronous : payload ZSTD
	# d'une minuscule scène RÉELLE (sauvegardée puis relue), pour que le
	# worker réussisse (ok = true) et que le chemin testé soit bien le DROP,
	# pas l'échec de décompression.
	var tmp_node := Node3D.new()
	tmp_node.name = "F2Fixture"
	var tmp_scene := PackedScene.new()
	tmp_scene.pack(tmp_node)
	tmp_node.free()
	var save_err := ResourceSaver.save(tmp_scene, "user://f2_fixture.scn")
	var plain := FileAccess.get_file_as_bytes("user://f2_fixture.scn")
	# Nettoyage best-effort du fixture temporaire (non asserté) : ses octets
	# sont déjà en mémoire, plus besoin du fichier sur disque.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://f2_fixture.scn"))
	var r: Variant = Runner.assert_true(save_err == OK and not plain.is_empty(),
		"fixture de scène temporaire écrite (prérequis)")
	if r is String:
		_dispose(inst)
		return r
	# File déjà peuplée : marqueur que le poll ne doit JAMAIS écraser.
	var marker := {"path": "user://already_pending.scn", "pos": Vector3(9, 9, 9),
		"rot": Vector3.ZERO, "scale": Vector3.ONE, "kb": 1}
	inst.level_transfer._pending_level_load = marker
	var raw := plain.compress(FileAccess.COMPRESSION_ZSTD)
	r = Runner.assert_true(
		inst.level_transfer._begin_level_decode(raw, plain.size(), Vector3(1, 2, 3), Vector3.ZERO, Vector3.ONE),
		"décodage soumis au pool de threads")
	if r is String:
		_dispose(inst)
		return r
	# Spin : le thread fini, _poll_level_decode doit solder la tâche.
	for i in 2000:
		inst.level_transfer._poll_level_decode()
		if inst.level_transfer._level_decode_task < 0:
			break
		OS.delay_msec(5)
	r = Runner.assert_eq(inst.level_transfer._level_decode_task, -1,
		"la tâche de décodage est soldée par le poll")
	if r is String:
		_dispose(inst)
		return r
	r = Runner.assert_eq(inst.level_transfer._pending_level_load, marker,
		"résultat DROPPÉ : la file déjà en attente n'est pas écrasée")
	if r is String:
		_dispose(inst)
		return r
	# Aspect log : aucun « queued » mensonger, et un diagnostic de drop
	# honnête doit être passé par _lan_log (le push_warning de succès ne
	# doit sortir que si la file a réellement été peuplée).
	var saw_drop_log := false
	for msg in inst.lan_logs:
		var m := String(msg)
		r = Runner.assert_true(not m.contains("queued"),
			"le log ne doit jamais dire « queued » quand la file est déjà pleine : " + m)
		if r is String:
			_dispose(inst)
			return r
		if m.contains("already pending") and m.contains("dropped"):
			saw_drop_log = true
	r = Runner.assert_true(saw_drop_log,
		"un diagnostic de drop honnête doit être loggé (« already pending … dropped »)")
	_dispose(inst)
	return r