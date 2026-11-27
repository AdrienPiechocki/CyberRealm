extends Node
## Transfert du niveau de l'hôte : cache d'envoi, canal TCP, scripts, décodage threadé,
## chargement différé des scènes.
##
## Module de LanManager (nœud enfant « LevelTransfer »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

var _level_sha256 := PackedByteArray()      # serveur : empreinte du blob compressé envoyé
var _level_expect_sha := PackedByteArray()  # client : empreinte annoncée par le serveur (canal authentifié)
# Client : empreinte du niveau de l'hôte en cours de chargement (vérifiée), puis du niveau effectivement appliqué
# (on_level_swapped). Une reconnexion au même niveau garde celui qui est affiché : pas de retéléchargement, pas de
# seconde copie de 400+ Mo à côté de la première (processus tué faute de mémoire sur le niveau Morrowind).
var _incoming_level_sha := PackedByteArray()
var _applied_level_sha := PackedByteArray()
# Chargements threadés en cours côté client. Le sync `load()` du niveau et
# des avatars bloquait le thread principal pendant 12-45 ms (repris → plusieurs
# secondes sur les machines lentes) : les ACK/heartbeats ENet n'étaient plus
# servis et l'hôte, au timeout ENet par défaut (~5 s, inmodifiable sur ce
# build — aucune API peer_set_timeout exposée), coupait la session en pleine
# réception → boucle de rejoin. On route donc tout décodage par
# ResourceLoader threadé, lesté dans _poll_pending_scene_loads().
var _pending_level_load: Dictionary = {} # {path, pos, rot, scale, kb}
# Niveau client reçu mais pas encore appliqué : retenu tant que les blobs
# d'avatars attendus ne sont pas arrivés, pour que tous les avatars
# apparaissent EN MÊME TEMPS que le niveau (et pas après). Timeout inclus :
# un pair muet ne bloque jamais l'entrée en session au-delà du délai.
var _deferred_level: Dictionary = {} # {scene, pos, rot, scl, waiting, deadline}
const AVATAR_LEVEL_WAIT_TIMEOUT_MSEC := 8000
# Transform de spawn de la scène de l'HÔTE (transmis dans le blob du niveau :
# le Player en est exclu). Une fois connu, _spawn_* l'utilise à la place du
# Player de la scène locale d'origine. Vidé au début de chaque session.
var _host_spawn_transform: Dictionary = {}
# Canal TCP dédié au niveau. Hôte : serveur (thread dédié) qui lit les jetons
# et écrit le blob. Client : récepteur (thread dédié) qui lit le blob.
var _level_tcp_server: LevelTcp.Server = null
var _level_tcp_rx: LevelTcp.Receiver = null
var _level_tcp_rx_meta: Dictionary = {} # {size, spawn, rotation, scale} de l'offre
var _level_tcp_rx_bytes := 0
var _level_tcp_rx_pct := -1
# Cache (host) du blob baked : re-baké uniquement quand le niveau change.
var _level_baked_cache: Dictionary = {}
# Cachés ensemble : le blob bake ET sa compression ZSTD, préparés AU DÉMARRAGE
# de l'hébergement (host_game), jamais dans le handler RPC _register_player —
# compresser 379 Mo dans le RPC gelait _process pendant ~10 s, les heartbeats
# cessaient, le watchdog client expirait au garde-fou de 10 s → boucle de
# rejoin. Une seule compression par session : chaque join la refaisait aussi.
var _level_compressed_cache := PackedByteArray()
# Peers en attente du niveau alors que le cache n'est pas prêt (miss de
# _send_level_to) : reprise en tête de _drain_level_send, hors RPC.
var _defer_level_send: Array = []
var _level_send_deferred := false

## Découpe le blob compressé EN UNE passe. Le résultat est stocké dans la
## file d'envoi : _drain_level_send ne lit qu'un élément de 24 Ko par tick
## (progression lisible via chunks.size()), sans dépendre des sémantiques de
## partage/copy du gros buffer Variant (ambiguïté relevée par T0).
static func build_level_chunks(compressed: PackedByteArray, chunk_size: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	if compressed.is_empty() or chunk_size < 1:
		return out
	var count := ceili(float(compressed.size()) / float(chunk_size))
	out.resize(count)
	for i in count:
		var start := i * chunk_size
		out[i] = compressed.slice(start, mini(start + chunk_size, compressed.size()))
	return out

func _level_send_cache_ready() -> bool:
	return not _level_baked_cache.is_empty() and not _level_compressed_cache.is_empty()

# Prépare bake + compression UNE fois, au clic Héberger (host_game) — jamais
# appelé depuis un handler RPC. Journalise les durées (T6) pour mesurer le
# gel évité sur le chemin RPC. Renvoie false si indisponible : jamais fatal,
# le miss de _send_level_to ratera de façon différée et dégradera proprement.
func _prepare_level_send_cache() -> bool:
	var t0 := Time.get_ticks_msec()
	if _level_baked_cache.is_empty():
		if not lan.level_bake_provider.is_valid():
			push_warning("LAN: level_bake_provider invalid — cannot prepare level cache")
			return false
		_level_baked_cache = lan.level_bake_provider.call()
		if _level_baked_cache.is_empty() \
				or int(_level_baked_cache.get("bytes", PackedByteArray()).size()) == 0:
			push_warning("LAN: empty level bake — nothing to send")
			_level_baked_cache = {}
			return false
		lan._lan_log("level bake in %d ms — %d KB raw" % [Time.get_ticks_msec() - t0,
			int((_level_baked_cache["bytes"] as PackedByteArray).size()) / 1024])
	if _level_compressed_cache.is_empty():
		var scn: PackedByteArray = _level_baked_cache["bytes"]
		var payload := LevelBaker.pack_payload(_level_baked_cache.get("assets", {}), scn)
		_level_baked_cache["payload_size"] = payload.size()
		var tc := Time.get_ticks_msec()
		_level_compressed_cache = payload.compress(FileAccess.COMPRESSION_ZSTD)
		if _level_compressed_cache.is_empty():
			_level_compressed_cache = payload
		lan._lan_log("level compress in %d ms — %d KB → %d KB" % [Time.get_ticks_msec() - tc,
			payload.size() / 1024, _level_compressed_cache.size() / 1024])
		_level_sha256 = LanManager.SessionModule._sha256_of(_level_compressed_cache)
	return true

# Vide les deux caches (bake + compressé) : le niveau a changé ou la session
# se termine, tout doit être re-prêté au prochain hébergement.
func _invalidate_level_send_cache() -> void:
	_level_baked_cache.clear()
	_level_compressed_cache = PackedByteArray()

# L'hôte transmet son niveau (celui que tous doivent voir) au joueur qui
# rejoint : le blob binaire auto-suffisant produit par LevelBaker (meshes/
# matériaux/textures embarqués → jouable même avec des builds différents),
# compressé en ZSTD puis envoyé en chunks fiables. Le blob est mis en cache :
# re-baké seulement si le niveau change (on_level_swapped).
func _send_level_to(id: int) -> void:
	# JAMAIS de bake/compress ici : cette fonction tourne dans le handler RPC
	# _register_player, et le thread principal doit rester libre (heartbeats,
	# ACK ENet). Miss de cache → préparation DIFFÉRÉE, l'envoi repart au tick
	# suivant, le pair patiente sur le manifeste qui partira alors.
	if not _level_send_cache_ready():
		push_warning("LAN: level cache not ready — deferring bake for peer %d" % id)
		lan._set_status("Preparing host level…")
		if id not in _defer_level_send:
			_defer_level_send.append(id)
		# (Re)programme la préparation à CHAQUE peer en miss, sans garde : le
		# taux est par peer qui s'enregistre (jamais par tick) donc pas de
		# martèlement, l'appel est sans effet si le cache est déjà chaud, et
		# un bake échoué est retenté au join suivant au lieu de rester bloqué.
		_level_send_deferred = true
		_prepare_level_send_cache.call_deferred()
		return
	var data: Dictionary = _level_baked_cache
	# Manifeste des scripts utilisateur : envoyé AVANT les chunks (même canal
	# fiable → ordre garanti). À l'arrivée du dernier chunk le pair écrit déjà
	# ses fichiers miroir et load(blob) résout les ext_resource des scripts.
	var manifest: Dictionary = data.get("scripts", {})
	if not manifest.is_empty():
		_receive_level_scripts.rpc_id(id, manifest)
	# Canal TCP dédié : jeton à usage unique, lié à l'IP du pair ENet, transmis
	# par le RPC (chiffré si la session l'est). Jamais de bake/compress ici.
	var ip := lan.session._remote_ip(id)
	if ip == "":
		lan._lan_log("level tcp: no remote address for peer %d — level not sent" % id)
		return
	if not _ensure_level_tcp_server():
		lan._set_status("Level TCP channel unavailable (port %d busy?)" % LanManager.LEVEL_TCP_PORT)
		return
	_level_tcp_server.set_payload(_level_compressed_cache)
	var token := LevelTcp.new_token()
	_level_tcp_server.add_token(id, ip, token)
	if _level_sha256.is_empty():
		_level_sha256 = LanManager.SessionModule._sha256_of(_level_compressed_cache)
	_receive_level_baked.rpc_id(id, LanManager.LEVEL_TCP_PORT, token, _level_compressed_cache.size(),
			int(data.get("payload_size", 0)), data.get("spawn", Vector3.ZERO),
			data.get("spawn_rotation", Vector3.ZERO), data.get("spawn_scale", Vector3.ONE), _level_sha256)
	push_warning("LAN: level offered to peer %d — raw %d KB, compressed %d KB (TCP %d)" % [id,
		int(data.get("bytes", PackedByteArray()).size()) / 1024,
		_level_compressed_cache.size() / 1024, LanManager.LEVEL_TCP_PORT])
	lan._set_status("Sending host level to %d (%d KB)…" % [id, _level_compressed_cache.size() / 1024])

## Client : le niveau offert (empreinte `sha256`) est-il celui qui est déjà affiché ?
func level_already_applied(sha256: PackedByteArray) -> bool:
	return sha256.size() == 32 and sha256 == _applied_level_sha and lan._level_root != null \
			and is_instance_valid(lan._level_root)

## Niveau remplacé (wayland_room._swap_level) : celui de l'hôte s'il vient d'être chargé, sinon un niveau local.
func on_level_swapped() -> void:
	_level_unloaded_for_load = false # un niveau complet est de nouveau en place
	_applied_level_sha = _incoming_level_sha
	_incoming_level_sha = PackedByteArray()

func _ensure_level_tcp_server() -> bool:
	if _level_tcp_server != null and _level_tcp_server.is_running():
		return true
	var srv := LevelTcp.Server.new()
	var err := srv.start(LanManager.LEVEL_TCP_PORT)
	if err != OK:
		lan._lan_log("level tcp: listen on %d failed (%s)" % [LanManager.LEVEL_TCP_PORT, error_string(err)])
		return false
	_level_tcp_server = srv
	lan._lan_log("level tcp: listening on %d" % LanManager.LEVEL_TCP_PORT)
	return true

func _stop_level_tcp_rx() -> void:
	if _level_tcp_rx != null:
		_level_tcp_rx.stop()
		_level_tcp_rx = null
	_level_tcp_rx_meta = {}
	_level_tcp_rx_bytes = 0
	_level_tcp_rx_pct = -1

## Arrête les deux extrémités du canal (jointure des threads). Appelé à la
## déconnexion et à la fermeture : jamais de thread qui survit à la session.
func _stop_level_tcp() -> void:
	if _level_tcp_server != null:
		_level_tcp_server.stop()
		_level_tcp_server = null
	_stop_level_tcp_rx()

# Reprise du niveau différé (cache pas prêt au join) + journalisation des
# évènements du thread TCP hôte. Tick _physics_process, hors handler RPC.
func _drain_level_send() -> void:
	if _level_send_deferred and _level_send_cache_ready():
		_level_send_deferred = false
		for id in _defer_level_send:
			_send_level_to(id)
		_defer_level_send.clear()
	if _level_tcp_server != null:
		for e in _level_tcp_server.take_events():
			lan._lan_log(String(e))

# Manifeste des scripts utilisateur de l'hôte (UserScriptMirror) : reçu une
# fois par session, AVANT les chunks du niveau. Installé immédiatement dans le
# miroir disque — quand le blob sera complet, load() résoudra ses ext_resource
# (et les preload/extends des scripts) vers de vrais fichiers locaux.
# MÊME CANAL (6) que les chunks : l'ordre fiable ENet n'est garanti que
# intra-canal, il faut que ce RPC précède toujours le premier chunk.
@rpc("any_peer", "call_remote", "reliable", 6)
func _receive_level_scripts(manifest: Dictionary) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if manifest.is_empty() or not UserScriptMirror.valid(manifest):
		return
	var count := UserScriptMirror.install(manifest)
	push_warning("LAN: host-level user scripts installed (%d files)" % count)
	lan._lan_log("host-level scripts — batch installed (%d files)" % count)

# ── Anciens helpers du transfert par chunks ENet : plus appelés à l'exécution
# (le blob passe par LevelTcp). Conservés tant que des tests y font référence.
## État de réception du blob de niveau — buffer membre brut. T0 a prouvé que
## l'append en place sur variable typée est O(chunk) (partage, pas de copie) :
## on accumule donc directement dans `state["buf"]`, sans tableau de chunks ni
## concaténation finale. INTERDIT : `(state["buf"] as PackedByteArray)` — le
## cast détache/copierait les 136 Mo accumulés (piège T0).
static func bake_recv_init(state: Dictionary, total: int, uncompressed_size: int,
		spawn: Vector3, rot: Vector3, scl: Vector3) -> void:
	state.clear()
	state["buf"] = PackedByteArray()
	state["next"] = 0
	state["bytes"] = 0
	state["total"] = total
	state["size"] = uncompressed_size
	state["spawn"] = spawn
	state["rotation"] = rot
	state["scale"] = scl

## Accepte le chunk d'indice `index` s'il est exactement le suivant (le canal
## fiable ENet garantit l'ordre ; tout écart = on ignore, comme avant).
## Renvoie "more" / "complete" / "reject".
static func bake_recv_append(state: Dictionary, index: int, chunk: PackedByteArray) -> String:
	var total := int(state.get("total", -1))
	var next := int(state.get("next", 0))
	if total < 1 or chunk.is_empty() or index < 0 or index >= total:
		return "reject"
	if index != next:
		return "reject"
	var buf: PackedByteArray = state["buf"]
	buf.append_array(chunk)
	state["buf"] = buf
	state["next"] = index + 1
	state["bytes"] = int(state.get("bytes", 0)) + chunk.size()
	return "complete" if index + 1 >= total else "more"

## Buffer assemblé — à lire uniquement après "complete". Variable typée (partage
## sans copie), jamais de cast.
static func bake_recv_payload(state: Dictionary) -> PackedByteArray:
	var out: PackedByteArray = state["buf"]
	return out

## Garde de (ré)initialisation de l'état de réception (revue finale, Issue 1) :
## un `total` identique ne prouve PAS la continuité — l'hôte peut relancer le
## même blob à l'identique (double _register_player en cours de transfert).
## Sur le canal fiable ENet (ordonné, aucun réordonnancement intra-transfert),
## un `index == 0` alors que `next > 0` ne peut alors être qu'un redémarrage :
## sans ré-init, les chunks 0..next-1 de la nouvelle série seraient rejetés
## puis le chunk 0 APPENDÉ au vieux buffer partiel — corruption silencieuse si
## le contenu diffère jamais (décompression en échec → « kept local level »,
## mais la machine à état doit rester cohérente). Les cas « pas de total » et
## « total différent » gardent un comportement identique à l'ancienne condition.
static func bake_recv_needs_init(state: Dictionary, total: int, index: int) -> bool:
	if not state.has("total") or int(state.get("total", -1)) != total:
		return true
	return index == 0 and int(state.get("next", 0)) > 0

# Offre de transfert du niveau — canal ENet 6, donc APRÈS le manifeste des
# scripts (même canal fiable, ordre garanti). Le RPC ne porte plus le blob :
# seulement le jeton d'accès au canal TCP dédié (chiffré avec la session DTLS).
# L'adresse TCP est celle du pair ENet de l'hôte, jamais une valeur du RPC.
@rpc("any_peer", "call_remote", "reliable", 6)
func _receive_level_baked(port: int, token: PackedByteArray, wire_size: int, uncompressed_size: int, spawn: Vector3, spawn_rotation: Vector3, spawn_scale: Vector3, sha256: PackedByteArray) -> void:
	if lan.is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if port < 1 or port > 65535 or token.size() != LevelTcp.TOKEN_SIZE \
			or wire_size < 1 or wire_size > LevelTcp.MAX_PAYLOAD or uncompressed_size < 1:
		return
	var host_ip := lan.session._remote_ip(1)
	if host_ip == "":
		host_ip = lan.session._reconnect_ip
	if host_ip == "":
		lan._lan_log("level tcp: host address unknown — offer dropped")
		return
	# Reconnexion au MÊME niveau (même empreinte que celui affiché) : on le garde, sans transfert ni rechargement.
	if level_already_applied(sha256):
		_stop_level_tcp_rx()
		_host_spawn_transform = {"pos": spawn, "rot": spawn_rotation, "scale": spawn_scale}
		lan._lan_log("level unchanged (same SHA-256) — current level kept, no download")
		lan._set_status("Host level unchanged — kept")
		lan.mark_level_stable()          # entrée dans la session + état courant du décor (instantané)
		return
	# Nouvelle offre (ex. double _register_player) : l'ancien récepteur est coupé.
	_stop_level_tcp_rx()
	_level_tcp_rx_meta = {"size": uncompressed_size, "spawn": spawn,
			"rotation": spawn_rotation, "scale": spawn_scale}
	_level_expect_sha = sha256
	lan._last_level_chunk_msec = Time.get_ticks_msec()
	var rx := LevelTcp.Receiver.new()
	var err := rx.start(host_ip, port, token, wire_size)
	if err != OK:
		lan._lan_log("level tcp: receiver start failed (%s)" % error_string(err))
		_level_tcp_rx_meta = {}
		return
	_level_tcp_rx = rx
	lan._lan_log("level tcp: connecting to %s:%d (%d KB)" % [host_ip, port, wire_size / 1024])

## Thread principal : progression + passage du blob reçu au décodage threadé.
## `_last_level_chunk_msec` est alimenté ici (watchdog heartbeat / fallback du
## join) tant que des octets arrivent.
func _poll_level_tcp_rx() -> void:
	if _level_tcp_rx == null:
		return
	var pr := _level_tcp_rx.progress()
	if pr.x > _level_tcp_rx_bytes:
		_level_tcp_rx_bytes = pr.x
		lan._last_level_chunk_msec = Time.get_ticks_msec()
		var pct := int(pr.x * 100.0 / maxf(float(pr.y), 1.0))
		if pct != _level_tcp_rx_pct:
			_level_tcp_rx_pct = pct
			lan._set_status("Loading host map… %d%%" % pct)
			if pct % 10 == 0:
				lan._lan_log("level rx %d%%" % pct)
	if not _level_tcp_rx.is_finished():
		return
	var res := _level_tcp_rx.take_result()
	var meta := _level_tcp_rx_meta
	_level_tcp_rx = null
	_level_tcp_rx_meta = {}
	if not bool(res.get("ok", false)):
		lan._lan_log("level tcp: transfer failed — %s" % String(res.get("err", "?")))
		lan._set_status("Host level transfer failed — kept local level")
		lan.session._finalize_join()
		return
	# Intégrité : le canal TCP n'est pas chiffré, l'empreinte arrive par le canal authentifié (RPC, TLS). Un blob
	# altéré en route (scripts de niveau !) est refusé.
	if _level_expect_sha.size() == 32 and LanManager.SessionModule._sha256_of(res["raw"]) != _level_expect_sha:
		lan._lan_log("level tcp: EMPREINTE INVALIDE — blob rejeté")
		lan._set_status("Host level rejected (integrity check failed) — kept local level")
		lan.session._finalize_join()
		return
	lan._last_level_chunk_msec = Time.get_ticks_msec()
	_incoming_level_sha = _level_expect_sha if _level_expect_sha.size() == 32 else PackedByteArray()
	if not _begin_level_decode(res["raw"], int(meta["size"]), meta["spawn"],
			meta["rotation"], meta["scale"]):
		lan._lan_log("level decode already in flight — dropped")


# Décodage des blobs scènes par ResourceLoader threadé (voir les commentaires
# sur _pending_level_load) : le handler RPC ne fait que mettre en file, le
# thread principal reste libre pour les ACK/heartbeats ENet.

## Décompression (136→379 Mo) + écriture du fichier : synchrone dans le
## handler RPC du dernier chunk, ce bloc gelait le thread principal plusieurs
## secondes → ACK/heartbeats ENet servis trop tard → session coupée (même
## classe de bug que le load() sync historique, cf. test_lan_threaded.gd).
## Retour main = _poll_level_decode(), qui enchaîne sur le chargement
## threadé existant (_queue_level_scene_load).
var _level_decode_task := -1
var _level_decode_results: Array = []
var _level_decode_mutex := Mutex.new()

func _begin_level_decode(raw: PackedByteArray, uncompressed_size: int,
		spawn: Vector3, rot: Vector3, scl: Vector3) -> bool:
	if _level_decode_task >= 0:
		return false
	var spec := {"raw": raw, "size": uncompressed_size, "path": "user://lan_level.scn",
		"spawn": spawn, "rotation": rot, "scale": scl}
	_level_decode_task = WorkerThreadPool.add_task(_level_decode_worker.bind(spec))
	return true

## Tâche du WORKER THREAD : ni arbre de scène, ni état du LanManager — uniquement
## le payload + un résultat poussé dans une file sous mutex (un seul décodage
## de niveau à la fois, mais le mutex ne coûte rien et documente le contrat).
func _level_decode_worker(spec: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var res := {"ok": false, "err": "", "kb": 0, "ms": 0, "spec": spec}
	var raw: PackedByteArray = spec["raw"]
	var bytes := raw.decompress(int(spec["size"]), FileAccess.COMPRESSION_ZSTD)
	if bytes.is_empty() or bytes.size() != int(spec["size"]):
		res["err"] = "decompress failed (%d ≠ %d)" % [bytes.size(), int(spec["size"])]
	else:
		var scn := bytes
		var ok := true
		if LevelBaker.is_packed(bytes):
			var parsed := LevelBaker.unpack_payload(bytes)
			if not bool(parsed.get("ok", false)):
				ok = false
				res["err"] = "invalid asset container"
			else:
				var assets: Dictionary = parsed["assets"]
				for p in assets:
					if not UserScriptMirror.write_bytes(String(p), assets[p]):
						push_warning("LAN: cannot write asset %s" % p)
				scn = bytes.slice(int(parsed["offset"]))
		if ok:
			var f := FileAccess.open(String(spec["path"]), FileAccess.WRITE)
			if f == null:
				res["err"] = "could not write %s" % String(spec["path"])
			else:
				f.store_buffer(scn)
				f.close()
				res["ok"] = true
				res["kb"] = scn.size() / 1024
	res["ms"] = Time.get_ticks_msec() - t0
	_level_decode_mutex.lock()
	_level_decode_results.append(res)
	_level_decode_mutex.unlock()

func _poll_level_decode() -> void:
	if _level_decode_task < 0:
		return
	if not WorkerThreadPool.is_task_completed(_level_decode_task):
		return
	WorkerThreadPool.wait_for_task_completion(_level_decode_task)
	_level_decode_task = -1
	_level_decode_mutex.lock()
	var res: Dictionary = _level_decode_results.pop_front() if not _level_decode_results.is_empty() else {}
	_level_decode_mutex.unlock()
	if res.is_empty():
		return
	var spec: Dictionary = res["spec"]
	lan._lan_log("level decode+write in %d ms — %d KB" % [int(res["ms"]), int(res["kb"])])
	if not bool(res["ok"]):
		push_warning("LAN: level decode failed — " + str(res["err"]))
		lan._set_status("Host level corrupted — kept local level")
		lan.session._finalize_join()
		return
	# Revue finale, Issue 2 : le message « queued » ne doit sortir QUE si la
	# file a réellement été peuplée — _queue_level_scene_load refuse (sans
	# effet de bord) quand un chargement est déjà en attente, auquel cas le
	# résultat du décodage est déposé (comportement volontaire) et le log doit
	# le dire honnêtement. Fichier manquant : _queue_level_scene_load a déjà
	# son propre push_warning → pas de doublon ici.
	if _queue_level_scene_load(String(spec["path"]), spec["spawn"], spec["rotation"],
			spec["scale"], int(res["kb"])):
		push_warning("LAN: level received — %d KB decompressed, queued threaded load" % int(res["kb"]))
	elif not _pending_level_load.is_empty():
		lan._lan_log("level decode ready but scene load already pending — result dropped")

# Images d'attente entre le déchargement du niveau courant et le chargement
# du niveau de l'hôte : queue_free agit en fin d'image, puis le RenderingDevice
# ne libère la mémoire GPU qu'une fois les images en vol terminées (2-3).
const LEVEL_UNLOAD_SETTLE_FRAMES := 5
# Le niveau courant a été vidé pour ce chargement : en cas d'échec, il faut
# recharger le niveau personnel (sinon le joueur reste dans le vide).
var _level_unloaded_for_load := false

func _queue_level_scene_load(path: String, pos: Vector3, rot: Vector3, scl: Vector3, kb: int) -> bool:
	if not _pending_level_load.is_empty():
		return false
	if not FileAccess.file_exists(path):
		push_warning("LAN: level scene file missing (%s)" % path)
		return false
	# Libérer le niveau courant AVANT de charger celui de l'hôte (le chargement
	# envoie ses ressources au GPU) : pas de pic à deux niveaux, pas de
	# fragmentation de l'allocateur GPU. Sans niveau à libérer (aucun écouteur :
	# serveur, tests), le chargement part immédiatement.
	var unloading := lan.level_unload_requested.get_connections().size() > 0
	_pending_level_load = {"path": path, "pos": pos, "rot": rot, "scale": scl, "kb": kb,
		"start_frame": Engine.get_process_frames() + (LEVEL_UNLOAD_SETTLE_FRAMES if unloading else 0),
		"requested": false}
	if unloading:
		_level_unloaded_for_load = true
		lan.level_unload_requested.emit()
	return true

# Échec du chargement du niveau de l'hôte : le niveau courant a été vidé →
# retour au niveau personnel.
func _restore_after_failed_load() -> void:
	if _level_unloaded_for_load:
		_level_unloaded_for_load = false
		lan.local_level_restore_requested.emit()

func _poll_pending_scene_loads() -> void:
	# Blob reçu par le canal TCP → décodage threadé (même tick, en tête).
	_poll_level_tcp_rx()
	# Résultat du décodage/écriture du niveau (worker thread) : en tête pour
	# que le chainement sur _queue_level_scene_load parte le plus tôt possible.
	_poll_level_decode()
	if not _pending_level_load.is_empty() and not bool(_pending_level_load.get("requested", true)):
		if Engine.get_process_frames() >= int(_pending_level_load["start_frame"]):
			_pending_level_load["requested"] = true
			ResourceLoader.load_threaded_request(String(_pending_level_load["path"]), "", false, ResourceLoader.CACHE_MODE_REPLACE)
	if not _pending_level_load.is_empty() and bool(_pending_level_load.get("requested", true)):
		var spec: Dictionary = _pending_level_load
		var status := ResourceLoader.load_threaded_get_status(String(spec["path"]))
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var scene := ResourceLoader.load_threaded_get(String(spec["path"])) as PackedScene
			_pending_level_load = {}
			if scene == null:
				push_warning("LAN: cannot load received level scene (%s)" % String(spec["path"]))
				lan._set_status("Host level unreadable — back to local level")
				_restore_after_failed_load()
				lan.session._finalize_join()
				return
			push_warning("LAN: level scene loaded OK")
			_level_unloaded_for_load = false # apply_host_level remplace le niveau vidé
			# Mémoriser le transform de spawn de la scène de l'hôte : les avatars
			# distants sont spawnés selon LUI (pas le Player local de la scène
			# d'origine), que le niveau soit déjà appliqué ou pas.
			_host_spawn_transform = {"pos": spec["pos"], "rot": spec["rot"], "scale": spec["scale"]}
			# Le statut AVANT l'emit : apply_host_level → mark_level_stable →
			# _finalize_join() pose "Joined session", qui doit rester le message final.
			lan._set_status("Host level loaded (%d KB)" % int(spec["kb"]))
			# L'application peut être différée : on attend les avatars des pairs
			# (voir _defer_or_emit_level_apply) pour qu'ils apparaissent avec le
			# niveau, pas quelques secondes après.
			_defer_or_emit_level_apply(scene, spec["pos"], spec["rot"], spec["scale"])
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_warning("LAN: threaded load failed (%s, status %d)" % [String(spec["path"]), status])
			_pending_level_load = {}
			lan._set_status("Host level unreadable — back to local level")
			_restore_after_failed_load()
			lan.session._finalize_join()
	if lan.players._pending_avatar_loads.is_empty():
		return
	for peer_id in lan.players._pending_avatar_loads.keys():
		var path := String(lan.players._pending_avatar_loads[peer_id])
		var status := ResourceLoader.load_threaded_get_status(path)
		if status != ResourceLoader.THREAD_LOAD_LOADED:
			if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				lan._lan_log("avatar[%d]: decode failed (status %d)" % [peer_id, status])
				lan.players._pending_avatar_loads.erase(peer_id)
			continue
		lan.players._pending_avatar_loads.erase(peer_id)
		var loaded := ResourceLoader.load_threaded_get(path) as PackedScene
		if loaded == null:
			lan._lan_log("avatar[%d]: decode failed (null scene)" % peer_id)
			continue
		lan._lan_log("avatar[%d]: decoded (%d KB)" % [peer_id, lan.players._avatar_blobs.get(peer_id, PackedByteArray()).size() / 1024])
		if lan.online_restricted() and not LanManager.SessionModule.avatar_scene_safe(loaded):
			lan._lan_log("avatar[%d]: REFUSÉ (scripts / ressources actives) — avatar par défaut" % peer_id)
			lan.players._avatar_blobs.erase(peer_id)
			lan.players._finish_avatar_decode(peer_id)
			continue
		lan.players._avatar_scene_cache[peer_id] = loaded
		lan.players._finish_avatar_decode(peer_id)

# Retient l'application du niveau tant que des blobs d'avatars attendus
# (roster courant, hors joueur local) manquent ; sinon applique immédiatement.
func _defer_or_emit_level_apply(scene: PackedScene, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	var waiting: Array = LanManager.PlayersModule._waiting_avatar_ids(lan._players, lan.players._avatar_blobs, lan.players._pending_avatar_loads, lan._local_peer_id())
	lan._lan_log("level ready — roster=%s blobs=%s → %s" % [
		str(lan._players.keys()), str(lan.players._avatar_blobs.keys()),
		"applied immediately" if waiting.is_empty() else "deferred (waiting for %s)" % str(waiting)])
	if waiting.is_empty():
		lan.level_apply_requested.emit(scene, pos, rot, scl)
		return
	waiting.sort()
	_deferred_level = {
		"scene": scene, "pos": pos, "rot": rot, "scl": scl,
		"waiting": waiting,
		"deadline": Time.get_ticks_msec() + AVATAR_LEVEL_WAIT_TIMEOUT_MSEC,
	}
	lan._set_status("Loading players' avatars… (%d pending)" % waiting.size())
	push_warning("LAN: level deferred — waiting for avatars from peers %s" % str(waiting))

# Applique le niveau différé dès que plus personne n'est attendu (ou au
# timeout ; un pair parti/disconnecté cesse d'être attendu).
func _maybe_flush_deferred_level() -> void:
	if _deferred_level.is_empty():
		return
	var waiting: Array = []
	var m = multiplayer
	for id in _deferred_level["waiting"]:
		if m != null and m.multiplayer_peer != null and m.get_peers().has(int(id)):
			if not lan.players._avatar_blobs.has(int(id)) or lan.players._pending_avatar_loads.has(int(id)):
				waiting.append(int(id))
	_deferred_level["waiting"] = waiting
	var expired: bool = Time.get_ticks_msec() >= int(_deferred_level["deadline"])
	if waiting.is_empty() or expired:
		if expired and not waiting.is_empty():
			push_warning("LAN: avatar timeout (%s) — applying level without them" % str(waiting))
		lan._lan_log("flush deferred level — %s" % ("timeout, missing %s" % str(waiting) if not waiting.is_empty() else "blobs complete"))
		var d: Dictionary = _deferred_level
		_deferred_level = {}
		lan.level_apply_requested.emit(d["scene"], d["pos"], d["rot"], d["scl"])
