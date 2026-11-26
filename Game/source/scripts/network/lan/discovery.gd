extends Node
## Découverte LAN : répondeur UDP (hôte) et scan broadcast + balayage /24 (client).
##
## Module de LanManager (nœud enfant « Discovery »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

const DISCOVERY_TIMEOUT := 1.6
const DISCOVERY_RETRY_INTERVAL := 0.4
const DISCOVERY_QUERY := "CYBERREALM_DISCOVER"
## Serveur EN LIGNE joint par son nom depuis son propre réseau local : la box ne renvoie pas toujours vers l'intérieur
## un paquet adressé à sa propre IP publique (pas de « NAT loopback »), le nom public est alors injoignable du LAN.
## Le client demande « qui sert <domaine> ? » sur le réseau local ; le serveur répond (au LAN seulement) et le client
## s'y connecte directement, en vérifiant TOUJOURS le certificat contre le nom : une réponse usurpée ne mène qu'à
## un échec de poignée de main, jamais à une session non vérifiée.
const LOCATE_QUERY := "CYBERREALM_LOCATE"
const LOCATE_REPLY := "CYBERREALM_HERE"
const LOCATE_TIMEOUT := 0.45
const LOCATE_STEP := 0.15

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
		var text := String(data.get_string_from_utf8()).strip_edges()
		var addr: String = _responder.get_packet_ip()
		var port := _responder.get_packet_port()
		if lan.online:
			# En ligne : seule la localisation par nom, et seulement pour le réseau local (rien ne fuit vers Internet).
			_answer_locate(text, addr, port)
			continue
		if text != DISCOVERY_QUERY:
			continue
		var payload := "%s|%s|%d" % [lan.player_name, ",".join(lan._local_ips()), LanManager.PORT]
		_responder.set_dest_address(addr, port)
		_responder.put_packet(payload.to_utf8_buffer())

# ── Localisation d'un serveur en ligne sur le réseau local ───────────

static func is_private_ipv4(a: String) -> bool:
	var o := a.split(".")
	if o.size() != 4:
		return false
	for part in o:
		if not part.is_valid_int():
			return false
	var b0 := int(o[0])
	var b1 := int(o[1])
	return b0 == 10 or (b0 == 172 and b1 >= 16 and b1 <= 31) or (b0 == 192 and b1 == 168)

func _answer_locate(text: String, addr: String, port: int) -> void:
	if not text.begins_with(LOCATE_QUERY + "|") or not is_private_ipv4(addr):
		return
	var domain := text.substr(LOCATE_QUERY.length() + 1).to_lower()
	if lan.online_domain != "" and domain != lan.online_domain.to_lower():
		return
	_responder.set_dest_address(addr, port)
	_responder.put_packet(("%s|%s" % [LOCATE_REPLY, domain]).to_utf8_buffer())

## Client : adresse LAN du serveur qui sert `domain`, ou "" (absent du réseau local → passer par le nom public).
## Broadcasts seulement (renvoyés à chaque pas, UDP non fiable) : un balayage unicast du /24 comme discover_games()
## coûte plusieurs secondes d'envois bloquants, payées à CHAQUE join hors de chez soi.
func locate_online_server(domain: String) -> String:
	domain = domain.to_lower()
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	if udp.bind(0) != OK:
		return ""
	var query := ("%s|%s" % [LOCATE_QUERY, domain]).to_utf8_buffer()
	var expected := "%s|%s" % [LOCATE_REPLY, domain]
	var targets: Array = ["255.255.255.255"]
	for ip in lan._local_ips():
		var o := String(ip).split(".")
		if o.size() == 4 and is_private_ipv4(String(ip)):
			var b := "%s.%s.%s.255" % [o[0], o[1], o[2]]
			if not targets.has(b):
				targets.append(b)
	var found := ""
	var elapsed := 0.0
	while found == "" and elapsed < LOCATE_TIMEOUT:
		for t in targets:
			udp.set_dest_address(t, LanManager.DISCOVERY_PORT)
			udp.put_packet(query)
		await get_tree().create_timer(LOCATE_STEP).timeout
		elapsed += LOCATE_STEP
		while udp.get_available_packet_count() > 0:
			var data := udp.get_packet()
			var from := udp.get_packet_ip()
			if found == "" and is_private_ipv4(from) \
					and String(data.get_string_from_utf8()).strip_edges() == expected:
				found = from
	udp.close()
	return found
