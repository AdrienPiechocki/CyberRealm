class_name LevelTcp
extends RefCounted
## Canal TCP dédié au transfert du niveau baked (hôte → client).
##
## Protocole (un transfert = une connexion) :
##   client → hôte : TOKEN_SIZE octets (jeton reçu par le RPC chiffré)
##   hôte → client : u64 (little-endian) = taille du payload, puis le payload
##   puis l'hôte ferme. Jeton invalide / expiré / IP différente : fermeture
##   immédiate, sans aucune réponse (pas d'oracle).
##
## Le jeton est aléatoire (256 bits), à usage unique, lié à l'IP du peer ENet
## et expire après TOKEN_TTL_MSEC. Il ne protège PAS la confidentialité du flux
## TCP (qui n'est pas chiffré) : il empêche qu'un tiers du LAN récupère le niveau.
##
## Threads : Server (hôte) lit les jetons et écrit les blobs, Receiver (client)
## lit le blob. Aucun des deux ne touche à l'arbre de scène ni à LanManager :
## tout passe par des files sous mutex, consommées depuis le thread principal.

const TOKEN_SIZE := 32
const TOKEN_TTL_MSEC := 30000
const HANDSHAKE_TIMEOUT_MSEC := 5000
const CONNECT_TIMEOUT_MSEC := 8000
const STALL_TIMEOUT_MSEC := 15000
const MAX_CONNECTIONS := 8
const MAX_PAYLOAD := 1 << 30 # 1 GiB : borne dure contre un en-tête hostile
const WRITE_SLICE := 65536
const WRITE_BUDGET := 1 << 20 # octets max par connexion et par tour de boucle
const READ_SLICE := 1 << 20
const IDLE_SLEEP_MSEC := 2


static func new_token() -> PackedByteArray:
	return Crypto.new().generate_random_bytes(TOKEN_SIZE)


## IPv4 vue par un socket dual-stack ("::ffff:a.b.c.d") → "a.b.c.d".
static func normalize_ip(ip: String) -> String:
	if ip.begins_with("::ffff:"):
		return ip.substr(7)
	return ip


static func constant_time_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0


# ═════════════════════════════════════════════════════════════════════
# HÔTE
# ═════════════════════════════════════════════════════════════════════
class Server extends RefCounted:
	var _thread: Thread = null
	var _mutex := Mutex.new()
	var _server: TCPServer = null
	var _stop := false
	var _tokens: Array = []   # {token, peer_id, ip, expires}
	var _aborted: Array = []  # peer_id à couper (déconnectés)
	var _events: Array = []   # messages de log pour le thread principal
	var _payload := PackedByteArray()

	## Écoute (synchrone → l'erreur est connue tout de suite) puis lance le thread.
	func start(port: int) -> Error:
		if _thread != null:
			return OK
		_server = TCPServer.new()
		var err := _server.listen(port)
		if err != OK:
			_server = null
			return err
		_stop = false
		_thread = Thread.new()
		_thread.start(_run)
		return OK

	func is_running() -> bool:
		return _thread != null

	func stop() -> void:
		if _thread == null:
			return
		_mutex.lock()
		_stop = true
		_tokens.clear()
		_mutex.unlock()
		_thread.wait_to_finish()
		_thread = null
		_server = null

	## Payload courant (blob compressé). Copy-on-write : le thread garde sa propre
	## référence pour les transferts en cours, un changement n'affecte que les suivants.
	func set_payload(bytes: PackedByteArray) -> void:
		_mutex.lock()
		_payload = bytes
		_mutex.unlock()

	func add_token(peer_id: int, ip: String, token: PackedByteArray) -> void:
		var now := Time.get_ticks_msec()
		_mutex.lock()
		for i in range(_tokens.size() - 1, -1, -1):
			if int(_tokens[i]["expires"]) <= now or int(_tokens[i]["peer_id"]) == peer_id:
				_tokens.remove_at(i)
		_tokens.append({
			"token": token,
			"peer_id": peer_id,
			"ip": LevelTcp.normalize_ip(ip),
			"expires": now + LevelTcp.TOKEN_TTL_MSEC,
		})
		_mutex.unlock()

	## Peer déconnecté : jetons révoqués + transfert en cours coupé.
	func revoke(peer_id: int) -> void:
		_mutex.lock()
		for i in range(_tokens.size() - 1, -1, -1):
			if int(_tokens[i]["peer_id"]) == peer_id:
				_tokens.remove_at(i)
		_aborted.append(peer_id)
		_mutex.unlock()

	## Messages produits par le thread (à journaliser côté principal).
	func take_events() -> Array:
		_mutex.lock()
		var out := _events
		_events = []
		_mutex.unlock()
		return out

	func _log(msg: String) -> void:
		_mutex.lock()
		_events.append(msg)
		_mutex.unlock()

	func _run() -> void:
		var conns: Array = []
		while true:
			_mutex.lock()
			var stopping := _stop
			var aborted := _aborted
			_aborted = []
			_mutex.unlock()
			if stopping:
				break
			var moved := false
			while _server.is_connection_available():
				var p := _server.take_connection()
				if p == null:
					break
				if conns.size() >= LevelTcp.MAX_CONNECTIONS:
					p.disconnect_from_host()
					continue
				conns.append({
					"peer": p,
					"t0": Time.get_ticks_msec(),
					"ip": LevelTcp.normalize_ip(p.get_connected_host()),
					"state": 0,
					"peer_id": -1,
					"sent": 0,
					"size": 0,
					"last": Time.get_ticks_msec(),
				})
				moved = true
			var i := conns.size() - 1
			while i >= 0:
				var c: Dictionary = conns[i]
				var keep := true
				if int(c["peer_id"]) in aborted:
					_log("level tcp: transfer to peer %d aborted (disconnected)" % int(c["peer_id"]))
					keep = false
				else:
					keep = _step(c)
					if bool(c.get("moved", false)):
						moved = true
						c["moved"] = false
				if not keep:
					(c["peer"] as StreamPeerTCP).disconnect_from_host()
					conns.remove_at(i)
				i -= 1
			if not moved:
				OS.delay_msec(LevelTcp.IDLE_SLEEP_MSEC)
		for c in conns:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
		_server.stop()

	## Un pas de la machine à états d'une connexion. false = fermer.
	func _step(c: Dictionary) -> bool:
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return false
		var now := Time.get_ticks_msec()
		if int(c["state"]) == 0:
			# ── Lecture du jeton ─────────────────────────────────────
			if now - int(c["t0"]) > LevelTcp.HANDSHAKE_TIMEOUT_MSEC:
				_log("level tcp: %s — handshake timeout" % c["ip"])
				return false
			if peer.get_available_bytes() < LevelTcp.TOKEN_SIZE:
				return true
			var r := peer.get_data(LevelTcp.TOKEN_SIZE)
			if int(r[0]) != OK:
				return false
			var entry := _consume_token(r[1], String(c["ip"]), now)
			if entry.is_empty():
				_log("level tcp: %s — token rejected" % c["ip"])
				return false
			c["peer_id"] = int(entry["peer_id"])
			var payload: PackedByteArray = entry["payload"]
			if payload.is_empty():
				_log("level tcp: %s — no payload ready" % c["ip"])
				return false
			peer.put_u64(payload.size())
			c["payload"] = payload
			c["size"] = payload.size()
			c["state"] = 1
			c["last"] = now
			c["t_start"] = now
			c["moved"] = true
			_log("level tcp: peer %d (%s) authenticated — sending %d KB" % [
				int(c["peer_id"]), c["ip"], payload.size() / 1024])
			return true
		# ── Envoi du payload ─────────────────────────────────────────
		var size: int = c["size"]
		var sent: int = c["sent"]
		if sent >= size:
			_log("level tcp: peer %d done — %d KB in %d ms" % [
				int(c["peer_id"]), size / 1024, now - int(c["t_start"])])
			return false
		var data: PackedByteArray = c["payload"]
		var budget := LevelTcp.WRITE_BUDGET
		while budget > 0 and sent < size:
			var end := mini(sent + LevelTcp.WRITE_SLICE, size)
			var w := peer.put_partial_data(data.slice(sent, end))
			if int(w[0]) != OK:
				_log("level tcp: peer %d write error %d at %d/%d" % [
					int(c["peer_id"]), int(w[0]), sent, size])
				return false
			var n := int(w[1])
			if n <= 0:
				break
			sent += n
			budget -= n
			c["last"] = now
			c["moved"] = true
		c["sent"] = sent
		if now - int(c["last"]) > LevelTcp.STALL_TIMEOUT_MSEC:
			_log("level tcp: peer %d stalled at %d/%d" % [int(c["peer_id"]), sent, size])
			return false
		return true

	## Vérifie et CONSOMME le jeton (usage unique). {} si invalide.
	## Le jeton d'une autre IP n'est pas consommé (le vrai client peut encore l'utiliser).
	func _consume_token(candidate: PackedByteArray, ip: String, now: int) -> Dictionary:
		var out := {}
		_mutex.lock()
		for i in range(_tokens.size() - 1, -1, -1):
			var e: Dictionary = _tokens[i]
			if int(e["expires"]) <= now:
				_tokens.remove_at(i)
				continue
			# Pas de sortie anticipée : on compare tous les jetons (temps constant).
			if LevelTcp.constant_time_equal(candidate, e["token"]) and String(e["ip"]) == ip:
				out = {"peer_id": int(e["peer_id"]), "payload": _payload}
				_tokens.remove_at(i)
		_mutex.unlock()
		return out


# ═════════════════════════════════════════════════════════════════════
# CLIENT
# ═════════════════════════════════════════════════════════════════════
class Receiver extends RefCounted:
	var _thread: Thread = null
	var _mutex := Mutex.new()
	var _stop := false
	var _finished := false
	var _rx := 0
	var _total := 0
	var _result: Dictionary = {}

	func start(ip: String, port: int, token: PackedByteArray, expected_size: int) -> Error:
		if _thread != null:
			return ERR_ALREADY_IN_USE
		if token.size() != LevelTcp.TOKEN_SIZE:
			return ERR_INVALID_PARAMETER
		_total = expected_size
		_thread = Thread.new()
		return _thread.start(_run.bind(ip, port, token, expected_size))

	## (octets reçus, octets attendus)
	func progress() -> Vector2i:
		_mutex.lock()
		var v := Vector2i(_rx, _total)
		_mutex.unlock()
		return v

	func is_finished() -> bool:
		_mutex.lock()
		var f := _finished
		_mutex.unlock()
		return f

	## À appeler une fois is_finished() vrai. {ok, raw, err}.
	func take_result() -> Dictionary:
		if _thread != null:
			_thread.wait_to_finish()
			_thread = null
		return _result

	func stop() -> void:
		if _thread == null:
			return
		_mutex.lock()
		_stop = true
		_mutex.unlock()
		_thread.wait_to_finish()
		_thread = null

	func _should_stop() -> bool:
		_mutex.lock()
		var s := _stop
		_mutex.unlock()
		return s

	func _finish(res: Dictionary) -> void:
		_mutex.lock()
		_result = res
		_finished = true
		_mutex.unlock()

	func _fail(err: String) -> void:
		_finish({"ok": false, "err": err, "raw": PackedByteArray()})

	func _run(ip: String, port: int, token: PackedByteArray, expected_size: int) -> void:
		var peer := StreamPeerTCP.new()
		var err := peer.connect_to_host(ip, port)
		if err != OK:
			_fail("connect_to_host error %d" % err)
			return
		var t0 := Time.get_ticks_msec()
		while true:
			if _should_stop():
				peer.disconnect_from_host()
				_fail("cancelled")
				return
			peer.poll()
			var st := peer.get_status()
			if st == StreamPeerTCP.STATUS_CONNECTED:
				break
			if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE \
					or Time.get_ticks_msec() - t0 > LevelTcp.CONNECT_TIMEOUT_MSEC:
				peer.disconnect_from_host()
				_fail("connect failed (status %d)" % st)
				return
			OS.delay_msec(LevelTcp.IDLE_SLEEP_MSEC)
		if peer.put_data(token) != OK:
			peer.disconnect_from_host()
			_fail("token write failed")
			return
		var size := -1
		var buf := PackedByteArray()
		var last := Time.get_ticks_msec()
		while true:
			if _should_stop():
				peer.disconnect_from_host()
				_fail("cancelled")
				return
			peer.poll()
			# get_available_bytes() sur un socket fermé = erreur moteur : statut d'abord.
			var avail := peer.get_available_bytes() if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED else 0
			if avail > 0:
				if size < 0:
					if avail < 8:
						OS.delay_msec(LevelTcp.IDLE_SLEEP_MSEC)
						continue
					size = peer.get_u64()
					if size < 1 or size > LevelTcp.MAX_PAYLOAD or size != expected_size:
						peer.disconnect_from_host()
						_fail("bad payload size %d (expected %d)" % [size, expected_size])
						return
					continue
				var want := mini(mini(avail, size - buf.size()), LevelTcp.READ_SLICE)
				var r := peer.get_data(want)
				if int(r[0]) != OK:
					peer.disconnect_from_host()
					_fail("read error %d" % int(r[0]))
					return
				buf.append_array(r[1])
				last = Time.get_ticks_msec()
				_mutex.lock()
				_rx = buf.size()
				_mutex.unlock()
				if buf.size() >= size:
					break
				continue
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_fail("connection closed early (%d/%d)" % [buf.size(), maxi(size, 0)])
				return
			if Time.get_ticks_msec() - last > LevelTcp.STALL_TIMEOUT_MSEC:
				peer.disconnect_from_host()
				_fail("transfer stalled (%d/%d)" % [buf.size(), maxi(size, 0)])
				return
			OS.delay_msec(LevelTcp.IDLE_SLEEP_MSEC)
		peer.disconnect_from_host()
		_finish({"ok": true, "err": "", "raw": buf})
