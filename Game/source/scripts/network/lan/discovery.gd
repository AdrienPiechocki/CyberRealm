extends Node
## Découverte LAN : répondeur UDP (hôte) et scan broadcast + balayage /24 (client).
##
## Module de LanManager (nœud enfant « Discovery »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

const DISCOVERY_TIMEOUT := 1.6
const DISCOVERY_RETRY_INTERVAL := 0.4
const DISCOVERY_QUERY := "CYBERREALM_DISCOVER"

var _responder: PacketPeerUDP = null # host : répond aux requêtes de découverte
var _scanner: PacketPeerUDP = null   # client : scanne le réseau
var _scanning := false
var _scan_results: Array = []
# Génération du scan en cours : incrémentée à chaque discover_games() et à
# chaque fermeture du scanner (déconnexion). Une coroutine discover_games()
# réveillée après un await vérifie sa génération : périmée → elle abandonne
# sans toucher au scanner courant (fermé, ou remplacé par un nouveau scan).
var _scan_generation := 0

# ── Découverte LAN ───────────────────────────────────────────────────

func discover_games() -> void:
	if _scanning:
		return
	_scanning = true
	_scan_generation += 1
	var generation := _scan_generation
	_scan_results.clear()
	_scanner = PacketPeerUDP.new()
	_scanner.set_broadcast_enabled(true)
	if _scanner.bind(0) != OK:
		_scanner.close()
		_scanner = null
		_scanning = false
		lan._set_status("Network scan error")
		return
	# Requête en unicast sur tout le /24 (fiable, et teste le même chemin
	# réseau que le join) + broadcasts, renvoyés plusieurs fois (UDP non fiable).
	lan._set_status("Searching for games…")
	_send_unicast_sweep(_scanner)
	_send_broadcast_queries(_scanner)
	var elapsed := 0.0
	while elapsed < DISCOVERY_TIMEOUT:
		await get_tree().create_timer(DISCOVERY_RETRY_INTERVAL).timeout
		# Déconnexion (ou quit) pendant l'attente : _disconnect_session() a
		# fermé/vidé le scanner — abandonner sans y toucher (sinon crash sur
		# null et écrasement du statut "Disconnected"). Un scan relancé
		# entre-temps a incrémenté la génération : cette instance est périmée.
		if generation != _scan_generation or _scanner == null:
			return
		elapsed += DISCOVERY_RETRY_INTERVAL
		_poll_scanner()
		_send_broadcast_queries(_scanner)
	_poll_scanner()
	_scanner.close()
	_scanner = null
	_scanning = false
	if _scan_results.is_empty():
		lan._set_status("No games found — make sure both PCs are on the same network (firewall, router AP isolation)")
	else:
		lan._set_status("%d game(s) found" % _scan_results.size())
	lan.discovery_results.emit(_scan_results.duplicate())

func _send_unicast_sweep(udp: PacketPeerUDP) -> void:
	for ip in lan._local_ips():
		var octets := String(ip).split(".")
		if octets.size() != 4:
			continue
		var prefix := "%s.%s.%s" % [octets[0], octets[1], octets[2]]
		for i in range(1, 255):
			udp.set_dest_address("%s.%d" % [prefix, i], LanManager.DISCOVERY_PORT)
			udp.put_packet(DISCOVERY_QUERY.to_utf8_buffer())

func _send_broadcast_queries(udp: PacketPeerUDP) -> void:
	var targets := ["255.255.255.255"]
	for ip in lan._local_ips():
		var octets := String(ip).split(".")
		if octets.size() == 4:
			var b := "%s.%s.%s.255" % [octets[0], octets[1], octets[2]]
			if not targets.has(b):
				targets.append(b)
	for target in targets:
		udp.set_dest_address(target, LanManager.DISCOVERY_PORT)
		udp.put_packet(DISCOVERY_QUERY.to_utf8_buffer())

func _poll_scanner() -> void:
	if _scanner == null:
		return
	while _scanner.get_available_packet_count() > 0:
		var data := _scanner.get_packet()
		var text := String(data.get_string_from_utf8()).strip_edges()
		var parts := text.split("|")
		if parts.size() < 3:
			continue
		var port := int(parts[2])
		var ips := parts[1].split(",")
		var key_ip := String(ips[0]) if ips.size() > 0 else ""
		var exists := false
		for r in _scan_results:
			if String(r.get("ip", "")) == key_ip and int(r.get("port", 0)) == port:
				exists = true
				break
		if not exists:
			_scan_results.append({"name": parts[0], "ip": key_ip, "ips": ips, "port": port})

# Répondeur du host : répond aux requêtes de découverte sur le port fixe.
func _start_responder() -> void:
	if _responder != null:
		return
	_responder = PacketPeerUDP.new()
	_responder.set_broadcast_enabled(true)
	if _responder.bind(LanManager.DISCOVERY_PORT) != OK:
		push_warning("LAN discovery unavailable (port %d)." % LanManager.DISCOVERY_PORT)
		_responder.close()
		_responder = null

func _stop_responder() -> void:
	if _responder:
		_responder.close()
		_responder = null

func _poll_responder() -> void:
	while _responder.get_available_packet_count() > 0:
		var data := _responder.get_packet()
		if String(data.get_string_from_utf8()).strip_edges() != DISCOVERY_QUERY:
			continue
		var addr: String = _responder.get_packet_ip()
		var port := _responder.get_packet_port()
		var payload := "%s|%s|%d" % [lan.player_name, ",".join(lan._local_ips()), LanManager.PORT]
		_responder.set_dest_address(addr, port)
		_responder.put_packet(payload.to_utf8_buffer())
