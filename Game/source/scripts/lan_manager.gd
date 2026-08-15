extends Node
## Multijoueur LAN : l'hôte est le serveur (autorité pour le spawn/despawn
## des avatars), chaque joueur diffuse sa propre transformation par RPC
## unreliable. Les fenêtres/compositeur restent locaux à chaque machine —
## seuls les avatars des autres joueurs sont visibles.

signal status_changed(text: String)
signal players_changed(roster: Array)
signal discovery_results(results: Array)

const PORT := 7777
const DISCOVERY_PORT := 9999
const MAX_PLAYERS := 4
const DISCOVERY_TIMEOUT := 1.6
const DISCOVERY_RETRY_INTERVAL := 0.4
const DISCOVERY_QUERY := "CYBERREALM_DISCOVER"

const REMOTE_PLAYER_SCENE := preload("res://scenes/remote_player.tscn")

var session_active := false
var is_host := false
var player_name := ""
var player_color := Color(0.2, 0.6, 1.0)

var _level_root: Node3D = null
var _players_container: Node3D = null
var _players: Dictionary = {}       # peer_id -> nom
var _remote_players: Dictionary = {} # peer_id -> Node (avatar)
var _last_status := ""

var _responder: PacketPeerUDP = null # host : répond aux requêtes de découverte
var _scanner: PacketPeerUDP = null   # client : scanne le réseau
var _scanning := false
var _scan_results: Array = []

func setup(level_root: Node3D, name: String, color: Color) -> void:
	_level_root = level_root
	player_name = name
	player_color = color
	_players_container = Node3D.new()
	_players_container.name = "Players"
	_level_root.add_child(_players_container)

func is_session_active() -> bool:
	return session_active

# Met à jour la couleur locale et la diffuse si une session est en cours.
func update_local_color(color: Color) -> void:
	player_color = color
	if not session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not _players.has(my_id):
		return
	_players[my_id]["color"] = color
	if is_host:
		for id in _players:
			var entry: Dictionary = _players[id]
			_spawn_player.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	else:
		_register_player.rpc_id(1, player_name, color)

func get_last_status() -> String:
	return _last_status

func get_players_roster() -> Array:
	var roster: Array = []
	for id in _players:
		var entry: Dictionary = _players[id]
		roster.append({"id": id, "name": entry.get("name", ""), "color": entry.get("color", Color.WHITE)})
	roster.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	return roster

# ── Host ─────────────────────────────────────────────────────────────

func host_game() -> bool:
	if session_active:
		_set_status("Déjà en session LAN")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		_set_status("Erreur hôte : " + error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	session_active = true
	is_host = true
	_players.clear()
	_players[multiplayer.get_unique_id()] = {"name": player_name, "color": player_color}
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_start_responder()
	_set_status("Hébergement sur %s:%d — ouvrez le port UDP %d (et %d) dans le pare-feu si un client ne se connecte pas" % [_local_ip(), PORT, PORT, DISCOVERY_PORT])
	_emit_players()
	return true

# ── Join ─────────────────────────────────────────────────────────────

func join_game(ip: String) -> bool:
	if session_active:
		_set_status("Déjà en session LAN")
		return false
	ip = ip.strip_edges()
	if ip == "":
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		_set_status("Erreur connexion : " + error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_set_status("Connexion à %s:%d…" % [ip, PORT])
	return true

func disconnect_session() -> void:
	_disconnect_session()

func _on_connected_to_server() -> void:
	session_active = true
	is_host = false
	_players.clear()
	_players[multiplayer.get_unique_id()] = {"name": player_name, "color": player_color}
	_set_status("Connecté au serveur")
	_emit_players()
	# S'annoncer : le serveur va re-broadcaster le spawn de tous les avatars.
	_register_player.rpc_id(1, player_name, player_color)

func _on_connection_failed() -> void:
	_disconnect_session()
	_set_status("Connexion échouée — IP inaccessible. Vérifiez : même réseau, pare-feu (UDP %d/%d ouvert côté hôte), isolation AP du routeur." % [PORT, DISCOVERY_PORT])

func _on_server_disconnected() -> void:
	_disconnect_session()
	_set_status("Déconnecté du serveur")

# ── Spawn / despawn des avatars ──────────────────────────────────────

# Le client annonce son nom au serveur ; le serveur re-broadcaste le spawn
# de tous les joueurs connus pour que tout le monde (late-join compris)
# converge vers le même état.
@rpc("any_peer", "reliable")
func _register_player(pname: String, color: Color) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or not is_host:
		return
	_players[from] = {"name": pname, "color": color}
	_set_status("Joueur %d (%s) a rejoint" % [from, pname])
	for id in _players:
		var entry: Dictionary = _players[id]
		_spawn_player.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	_emit_players()

# Chaque pair saute son propre peer_id (il a déjà son joueur local).
@rpc("any_peer", "reliable", "call_local")
func _spawn_player(peer_id: int, pname: String, color: Color) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	if _remote_players.has(peer_id):
		_remote_players[peer_id].setup(peer_id, pname, color)
		return
	var avatar := REMOTE_PLAYER_SCENE.instantiate()
	avatar.name = str(peer_id)
	avatar.setup(peer_id, pname, color)
	avatar.position = _spawn_position(peer_id)
	_players_container.add_child(avatar)
	_remote_players[peer_id] = avatar
	_emit_players()

@rpc("any_peer", "reliable", "call_local")
func _remove_player(peer_id: int) -> void:
	if _remote_players.has(peer_id):
		_remote_players[peer_id].queue_free()
		_remote_players.erase(peer_id)
	_players.erase(peer_id)
	_emit_players()

func _on_peer_connected(id: int) -> void:
	if is_host:
		_set_status("Joueur %d connecté…" % id)

func _on_peer_disconnected(id: int) -> void:
	if is_host:
		_players.erase(id)
		_remove_player.rpc(id)
	else:
		_remove_player(id)
	_set_status("Joueur %d déconnecté" % id)

func _spawn_position(peer_id: int) -> Vector3:
	var player := _level_root.get_node_or_null("Player") as Node3D
	var base := player.position if player != null else Vector3.ZERO
	return base + Vector3(float((peer_id - 1) % MAX_PLAYERS) * 1.5, 0.0, 3.0)

# ── Sync des transformations ─────────────────────────────────────────

@rpc("any_peer", "unreliable")
func _sync_player_transform(pos: Vector3, yaw: float) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0:
		return
	if not _remote_players.has(from):
		return
	_remote_players[from].apply_transform(pos, yaw)

func _physics_process(_delta: float) -> void:
	if not session_active or _level_root == null:
		return
	if multiplayer.get_peers().is_empty():
		return
	var player := _level_root.get_node_or_null("Player") as Node3D
	if player == null:
		return
	_sync_player_transform.rpc(player.position, player.rotation.y)

# ── Découverte LAN ───────────────────────────────────────────────────

func discover_games() -> void:
	if _scanning:
		return
	_scanning = true
	_scan_results.clear()
	_scanner = PacketPeerUDP.new()
	_scanner.set_broadcast_enabled(true)
	if _scanner.bind(0) != OK:
		_scanner.close()
		_scanner = null
		_scanning = false
		_set_status("Erreur scan réseau")
		return
	# Requête en unicast sur tout le /24 (fiable, et teste le même chemin
	# réseau que le join) + broadcasts, renvoyés plusieurs fois (UDP non fiable).
	_send_unicast_sweep(_scanner)
	_send_broadcast_queries(_scanner)
	_set_status("Recherche de parties…")
	var elapsed := 0.0
	while elapsed < DISCOVERY_TIMEOUT:
		await get_tree().create_timer(DISCOVERY_RETRY_INTERVAL).timeout
		elapsed += DISCOVERY_RETRY_INTERVAL
		_poll_scanner()
		_send_broadcast_queries(_scanner)
	_poll_scanner()
	_scanner.close()
	_scanner = null
	_scanning = false
	if _scan_results.is_empty():
		_set_status("Aucune partie trouvée — vérifiez que les 2 PC sont sur le même réseau (pare-feu, isolation AP du routeur)")
	else:
		_set_status("%d partie(s) trouvée(s)" % _scan_results.size())
	discovery_results.emit(_scan_results.duplicate())

func _send_unicast_sweep(udp: PacketPeerUDP) -> void:
	for ip in _local_ips():
		var octets := String(ip).split(".")
		if octets.size() != 4:
			continue
		var prefix := "%s.%s.%s" % [octets[0], octets[1], octets[2]]
		for i in range(1, 255):
			udp.set_dest_address("%s.%d" % [prefix, i], DISCOVERY_PORT)
			udp.put_packet(DISCOVERY_QUERY.to_utf8_buffer())

func _send_broadcast_queries(udp: PacketPeerUDP) -> void:
	var targets := ["255.255.255.255"]
	for ip in _local_ips():
		var octets := String(ip).split(".")
		if octets.size() == 4:
			var b := "%s.%s.%s.255" % [octets[0], octets[1], octets[2]]
			if not targets.has(b):
				targets.append(b)
	for target in targets:
		udp.set_dest_address(target, DISCOVERY_PORT)
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

func _process(_delta: float) -> void:
	if _responder:
		_poll_responder()
	if _scanner:
		_poll_scanner()

# Répondeur du host : répond aux requêtes de découverte sur le port fixe.
func _start_responder() -> void:
	if _responder != null:
		return
	_responder = PacketPeerUDP.new()
	_responder.set_broadcast_enabled(true)
	if _responder.bind(DISCOVERY_PORT) != OK:
		push_warning("Découverte LAN indisponible (port %d)." % DISCOVERY_PORT)
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
		var payload := "%s|%s|%d" % [player_name, ",".join(_local_ips()), PORT]
		_responder.set_dest_address(addr, port)
		_responder.put_packet(payload.to_utf8_buffer())

# ── Helpers ──────────────────────────────────────────────────────────

func _local_ips() -> Array:
	var ips: Array = []
	for ip in IP.get_local_addresses():
		if ip.begins_with("127.") or ip.begins_with("169.254.") or ":" in ip:
			continue
		ips.append(ip)
	if ips.is_empty():
		ips.append("127.0.0.1")
	return ips

func _local_ip() -> String:
	return _local_ips()[0]

func _set_status(text: String) -> void:
	_last_status = text
	status_changed.emit(text)

func _emit_players() -> void:
	players_changed.emit(get_players_roster())

func _clear_remote_players() -> void:
	for id in _remote_players:
		_remote_players[id].queue_free()
	_remote_players.clear()

func _disconnect_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	_clear_remote_players()
	_stop_responder()
	if _scanner:
		_scanner.close()
		_scanner = null
		_scanning = false
		_scan_results.clear()
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	session_active = false
	is_host = false
	_players.clear()
	_emit_players()

func _exit_tree() -> void:
	_stop_responder()
	if _scanner:
		_scanner.close()
		_scanner = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
