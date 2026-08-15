extends Node
## Multijoueur LAN : l'hôte est le serveur (autorité pour le spawn/despawn
## des avatars), chaque joueur diffuse sa propre transformation par RPC
## unreliable. Les fenêtres/compositeur restent locaux à chaque machine —
## seuls les avatars des autres joueurs sont visibles.

signal status_changed(text: String)
signal players_changed(roster: Array)
signal discovery_results(results: Array)
signal level_apply_requested(scene: PackedScene)

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
var level_text_provider: Callable = Callable() # host : renvoie le texte de la scène Level
var windows_provider: Callable = Callable() # renvoie la liste des fenêtres locales (world)
var windows_moving_provider: Callable = Callable() # true si le joueur déplace/redimensionne une fenêtre
var window_image_provider: Callable = Callable() # Callable(window_id) -> Image (contenu réel, stream partage)
var window_version_provider: Callable = Callable() # Callable(window_id) -> int (version du contenu)
var compositor: WlrCompositor = null # pour start/stop_audio_share, poll_audio_packet, audio_decode

var _level_root: Node3D = null
var _players_container: Node3D = null
var _players: Dictionary = {}       # peer_id -> nom
var _remote_players: Dictionary = {} # peer_id -> Node (avatar)
var _last_status := ""

# Fenêtres des autres joueurs, rendues en quads noirs dans le MONDE (pas
# dans le repère du niveau) : chaque machine diffuse son propre état.
var _remote_windows_root: Node3D = null
var _remote_windows: Dictionary = {}      # peer_id -> Node3D (conteneur des quads)
var _remote_window_quads: Dictionary = {} # peer_id -> {wid -> MeshInstance3D}
var _remote_shared: Dictionary = {} # peer_id -> {wid -> bool} (partage en cours côté émetteur)
# peer_id -> {wid -> Texture2D} : dernière texture reçue, même pour une fenêtre
# pas encore marquée `shared` par l'état (course 1re frame vs état). Réappliquée
# par _apply_remote_windows quand le quad est recréé/que l'état arrive.
var _pending_remote_textures: Dictionary = {}
var _windows_dirty := false # un changement d'état de fenêtre est en attente
var _last_windows_send := 0.0
var _last_windows_texture_send := 0.0
var _last_texture_versions: Dictionary = {} # peer_id -> {wid -> int} (dernière version envoyée)
# wid -> float : cadence de changement de contenu (décroît à chaque tick de
# _sync_windows_textures). Une fenêtre qui change quasi à chaque tick (vidéo)
# est encodée en résolution/qualité réduites pour borner le coût CPU + réseau.
var _window_change_rates: Dictionary = {}
var _last_seen_version: Dictionary = {} # wid -> dernière version observée localement
# wid -> ticks ms de la dernière keyframe envoyée (borne la dérive du stream).
var _last_keyframe_msec: Dictionary = {}
# wid -> empreinte basse résolution de la dernière frame encodée (accédée
# uniquement par le worker d'encodage → pas de mutex nécessaire).
var _frame_fingerprint_last: Dictionary = {}
# from -> {wid -> version} : dernière version que le peer distante a CONFIRMÉ
# avoir appliquée (via _ack_window_versions). Flow control de l'émetteur.
var _last_acked_version: Dictionary = {}
# ── Diagnostics (latence du stream) ────────────────────────────────────
# pid -> {wid -> {version: msec}} : historique des frames envoyées, pour
# mesurer le RTT ACK (l'ACK accuse une version passée, pas la dernière).
var _frame_sent_log: Dictionary = {}
var _frame_enqueued_msec: Dictionary = {} # wid -> {version: msec} à l'enqueue
var _diag_last_log := 0
var _diag_rtt_sum := 0
var _diag_rtt_count := 0
var _diag_applied_count := 0
var _diag_last_applied := 0
const WINDOW_SYNC_GAP := 1.0 # resync périodique (auto-réparation des paquets perdus)
const WINDOW_SYNC_MOVE_GAP := 0.05 # cadence pendant un déplacement/redimensionnement
# Cadence et qualités du stream vidéo partagé. Le stream passe par des
# paquets UDP fragmentés (non fiables) : en le gardant léger on évite la
# congestion du lien WiFi (perte → throttle ENet → lag) et les timeout de
# déconnexion pendant une vidéo.
const WINDOW_TEXTURE_GAP := 0.06 # ~17 ips de stream par fenêtre partagée (fiables, retransmises)
const WINDOW_TEXTURE_MAX_SIDE := 1920 # cap de résolution pour l'encodage JPEG
const WINDOW_TEXTURE_QUALITY := 0.85 # qualité JPEG du partage
const WINDOW_VIDEO_MAX_SIDE := 1280 # cap réduit pour une fenêtre en mouvement continu
const WINDOW_VIDEO_QUALITY := 0.7 # qualité réduite pour une fenêtre en mouvement continu
const WINDOW_CONTENT_JUMP_THRESHOLD := 0.2 # diff moyenne/pixel > 20% entre 2 frames = saut de contenu (seek) → keyframe
const WINDOW_KEYFRAME_GAP_MSEC := 1500 # keyframe périodique : borne la dérive résiduelle du stream
const WINDOW_MAX_AHEAD := 1 # flow control : au plus 1 frame non appliquée en route (envoyée − ACKée) par peer

# ── Encodage JPEG sur un thread de travail ───────────────────────────
# L'encodage JPEG (~2-8 ms en 720p-1080p) ne doit pas bloquer le thread
# principal : c'est la cause principale du lag du stream partagé (et, par
# famine du service réseau, du risque de déconnexion ENet pendant une
# vidéo). Le thread principal ne fait que CAPTURER l'image (copie CPU
# rapide), le worker encode, le thread principal diffuse via RPC.
var _encode_thread: Thread = null
var _encode_mutex := Mutex.new()
var _encode_sem := Semaphore.new()
var _encode_queue: Array = []     # {wid, version, img, max_side, quality}
var _encode_results: Array = []   # {wid, version, bytes}
var _encode_inflight: Dictionary = {} # wid -> version (job déjà soumis)
var _encode_stop := false

# ── Audio partagé (stream LAN) ───────────────────────────────────────
# L'audio diffusé est le monitor du sink PipeWire par défaut de la machine
# émettrice (audio de la session, pas d'adressage fenêtre→flux en Wayland).
# Paquets OPUS 20 ms (48 kHz stéréo) sur le canal 3 (non fiable) : un paquet
# perdu = 20 ms de silence, sans blocage. La lecture côté récepteur utilise
# AudioStreamGenerator (push_buffer) : si le buffer est plein on laisse
# tomber les frames, la fraîcheur prime.
var _audio_active := false
var _audio_player: AudioStreamPlayer = null
var _audio_playback: AudioStreamGeneratorPlayback = null
var _audio_start_msec := 0
var _audio_send_count := 0
var _audio_no_data_warned := false
var _audio_received_count := 0
var _audio_first_printed := false
var _audio_decode_warned := false
const AUDIO_MIX_RATE := 48000
const AUDIO_BUFFER_SEC := 0.5

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
	# Quads noirs des fenêtres des autres joueurs : dans l'espace monde, à
	# l'identité sous ce node (le LAN est enfant de la room), PAS sous le
	# niveau (dont la racine est rotée/décalée) — cohérent avec les fenêtres
	# locales qui vivent dans le monde.
	_remote_windows_root = Node3D.new()
	_remote_windows_root.name = "RemoteWindows"
	add_child(_remote_windows_root)

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
	var err := peer.create_server(PORT, MAX_PLAYERS, 4)
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
	var err := peer.create_client(ip, PORT, 4)
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
	# Timeouts ENet généreux côté client (voir _on_peer_connected).
	_set_peer_timeout(1)
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
	_clear_remote_windows(peer_id)
	_emit_players()

func _on_peer_connected(id: int) -> void:
	if is_host:
		_set_status("Joueur %d connecté…" % id)
		# Timeouts ENet généreux : pendant un stream partagé (vidéo/audio), le
		# thread principal fait de l'encodage/décodage JPEG par frame ; un à-coup
		# de quelques secondes ne doit pas faire tomber la session (défaut ENet :
		# déconnexion après ~5 s sans ACK).
		_set_peer_timeout(id)
		_send_level_to(id)

# L'hôte transmet son niveau (celui que tous doivent voir) au joueur qui
# rejoint : le texte de la scène, ré-écrit côté client puis instancié.
func _send_level_to(id: int) -> void:
	if not level_text_provider.is_valid():
		return
	var text := String(level_text_provider.call())
	if text.is_empty():
		return
	_receive_level.rpc_id(id, text)

@rpc("any_peer", "reliable")
func _receive_level(scene_text: String) -> void:
	if is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if scene_text.is_empty():
		return
	var tmp := "user://lan_level.tscn"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_set_status("Impossible d'écrire le niveau de l'hôte")
		return
	f.store_string(scene_text)
	f.close()
	var scene: PackedScene = load(tmp)
	if scene == null:
		_set_status("Niveau de l'hôte illisible (assets manquants ?), niveau local conservé")
		return
	level_apply_requested.emit(scene)
	_set_status("Niveau de l'hôte chargé")

# Appelé par wayland_room après avoir remplacé le niveau : bascule la racine
# et déplace les avatars distants vers un nouveau conteneur (l'ancien niveau
# est sur le point d'être libéré).
func on_level_swapped(new_level_root: Node3D) -> void:
	_level_root = new_level_root
	_players_container = Node3D.new()
	_players_container.name = "Players"
	_level_root.add_child(_players_container)
	for id in _remote_players:
		var av: Node = _remote_players[id]
		if not is_instance_valid(av):
			_remote_players.erase(id)
			continue
		var p: Node = av.get_parent()
		if p and p != _players_container:
			p.remove_child(av)
		_players_container.add_child(av)

# Timeouts ENet généreux (limit, min, max) pour résister aux à-coups du
# thread principal pendant un stream partagé. Défaut ENet (5000/30000 ms)
# coupe la session après ~5 s sans ACK, trop juste quand l'encodage/décodage
# JPEG vidéo monopolise le thread principal.
const ENET_TIMEOUT_LIMIT := 64
const ENET_TIMEOUT_MIN := 15000
const ENET_TIMEOUT_MAX := 90000

func _set_peer_timeout(id: int) -> void:
	var mp = multiplayer.multiplayer_peer
	if mp == null or not (mp is ENetMultiplayerPeer):
		return
	var peer = (mp as ENetMultiplayerPeer).get_peer(id)
	if peer == null:
		return
	peer.set_timeout(ENET_TIMEOUT_LIMIT, ENET_TIMEOUT_MIN, ENET_TIMEOUT_MAX)

func _on_peer_disconnected(id: int) -> void:
	# Diagnostique : la déconnexion survient pendant un partage vidéo. ENet
	# déconnecte quand une commande reliable (ping/ACK) reste non-acknowledgée
	# ≥15 s (timeout min) — soit un lien saturé, soit un thread principal
	# bloqué. Ce log permet de corréler avec les symptômes (lag → déconnexion).
	print("[lan] peer %d déconnecté — état: video_stream=%s audio=%s nframes=%d" % [
		id,
		_has_streaming_window(),
		"on" if _audio_active else "off",
		_audio_send_count + _audio_received_count,
	])
	if is_host:
		_players.erase(id)
		_remove_player.rpc(id)
	else:
		_remove_player(id)
	_last_texture_versions.erase(id)
	_last_applied_version.erase(id)
	_last_acked_version.erase(id)
	_set_status("Joueur %d déconnecté" % id)

func _has_streaming_window() -> bool:
	if not windows_provider.is_valid():
		return false
	for item in windows_provider.call():
		if item is Dictionary \
				and bool(item.get("shared", false)) \
				and bool(item.get("visible", true)):
			return true
	return false

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

func _physics_process(delta: float) -> void:
	if not session_active or _level_root == null:
		return
	if multiplayer.get_peers().is_empty():
		return
	var player := _level_root.get_node_or_null("Player") as Node3D
	if player == null:
		return
	_sync_player_transform.rpc(player.position, player.rotation.y)
	_sync_windows_state(delta)
	_sync_windows_textures(delta)
	_drain_encoded_frames()
	_sync_audio_state()
	_drain_decoded_frames()

# ── Sync des fenêtres (quads noirs des autres joueurs) ───────────────

# Marque un changement d'état de fenêtre local (emit de windows_state_changed) :
# le prochain tick enverra l'état complet sans attendre la cadence périodique.
func request_windows_sync() -> void:
	if session_active:
		_windows_dirty = true

# Envoie l'état complet des fenêtres locales : immédiatement après un
# changement d'état, à haute cadence pendant un déplacement/redimensionnement,
# et périodiquement pour auto-réparer les paquets perdus (RPC unreliable).
func _sync_windows_state(delta: float) -> void:
	if not windows_provider.is_valid():
		return
	var moving := false
	if windows_moving_provider.is_valid():
		moving = bool(windows_moving_provider.call())
	var gap := WINDOW_SYNC_GAP
	if moving:
		gap = WINDOW_SYNC_MOVE_GAP
	elif _windows_dirty:
		gap = 0.0
	_last_windows_send += delta
	if _last_windows_send < gap:
		return
	var list: Array = windows_provider.call()
	# Rien à dire (aucune fenêtre, pas de changement en attente) : on n'envoie
	# pas de paquet vide périodique. Un changement d'état (dirty) part toujours.
	if list.is_empty() and not moving and not _windows_dirty:
		return
	_last_windows_send = 0.0
	_windows_dirty = false
	_sync_windows.rpc(list)

@rpc("any_peer", "unreliable")
func _sync_windows(windows: Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	_apply_remote_windows(from, windows)

# ── Stream du partage (SHARE ON = vraie fenêtre diffusée) ─────────────

# À cadence fixe (~10 ips), envoie le contenu réel des fenêtres partagées et
# visibles, encodé en JPEG (LAN). Les fenêtres non partagées (SHARE OFF) ne
# sont jamais streamées : leur quad reste noir chez les autres joueurs.
# Seule la version du contenu est comparée : une fenêtre statique n'est pas
# ré-encodée/re-envoyée (le compositeur ne recapture que si elle est dirty).
# Envoi par peer : un client qui se connecte en cours de route reçoit aussi
# la dernière frame.
func _sync_windows_textures(delta: float) -> void:
	_last_windows_texture_send += delta
	if _last_windows_texture_send < WINDOW_TEXTURE_GAP:
		return
	_last_windows_texture_send = 0.0
	if not windows_provider.is_valid() or not window_image_provider.is_valid() or not window_version_provider.is_valid():
		return
	var list: Array = windows_provider.call()
	if list.is_empty():
		return
	# Capturer + soumettre à l'encodage (thread de travail) UNE fois par
	# fenêtre à envoyer : le JPEG est hors du thread principal. L'envoi des
	# frames encodées est fait par _drain_encoded_frames(), appelé chaque tick
	# (latence réduite : une frame encodée part dès qu'elle est prête, sans
	# attendre la prochaine fenêtre d'enqueue).
	_start_encode_thread()
	for item in list:
		if not item is Dictionary:
			continue
		if not bool(item.get("shared", false)):
			continue
		if not bool(item.get("visible", true)):
			continue
		var wid := int(item.get("wid", -1))
		if wid < 0:
			continue
		var version := int(window_version_provider.call(wid))
		# Cadence de changement : décroît à chaque tick, +1 par changement.
		var rate: float = _window_change_rates.get(wid, 0.0)
		if version != _last_seen_version.get(wid, -1):
			_last_seen_version[wid] = version
			rate += 1.0
		_window_change_rates[wid] = rate * 0.9
		var video := rate >= 2.0
		var max_side := WINDOW_VIDEO_MAX_SIDE if video else WINDOW_TEXTURE_MAX_SIDE
		var quality := WINDOW_VIDEO_QUALITY if video else WINDOW_TEXTURE_QUALITY
		# Un job pour cette version est déjà en cours d'encodage ?
		if _encode_inflight.get(wid, -1) == version:
			continue
		# Au moins un peer attend une version plus récente ?
		var need_send := false
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			var sent: Dictionary = _last_texture_versions.get(pid, {})
			if sent.get(wid, -1) != version:
				need_send = true
				break
		if not need_send:
			continue
		# Keyframe périodique : borne la dérive résiduelle du stream (le
		# récepteur resynchronise dessus, version en main pour ignorer les
		# frames plus anciennes encore en transit).
		var force_key := false
		if Time.get_ticks_msec() - int(_last_keyframe_msec.get(wid, -999999)) > WINDOW_KEYFRAME_GAP_MSEC:
			force_key = true
		# Flow control : si TOUS les peers ont déjà WINDOW_MAX_AHEAD frames
		# non appliquées en route (dernière envoyée − dernière ACKée), on ne
		# enqueue PAS sauf si une keyframe est due. NB : la comparaison se fait
		# sur la version ENVOYÉE, pas la version courante — les captures
		# tournent à ~30/s (plus vite que le stream) ; comparer à la version
		# courante bloquait le flux quelques secondes après le début du partage.
		var all_behind := true
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			var sent_v: int = int(_last_texture_versions.get(pid, {}).get(wid, -1))
			var acked: int = int(_last_acked_version.get(pid, {}).get(wid, -1))
			if acked < 0 or sent_v - acked < WINDOW_MAX_AHEAD:
				all_behind = false
				break
		if all_behind and not force_key:
			continue
		var img: Image = window_image_provider.call(wid)
		if img == null or img.is_empty():
			continue
		if _debug_dump_once(0):
			img.save_png("user://share_sender.png")
			print("[share] sender: ", img.get_width(), "x", img.get_height(),
				" format=", img.get_format())
		_encode_mutex.lock()
		_encode_queue.append({
			"wid": wid,
			"version": version,
			"img": img,
			"max_side": max_side,
			"quality": quality,
			"force_key": force_key,
			"t_msec": Time.get_ticks_msec(),
		})
		_encode_mutex.unlock()
		_encode_inflight[wid] = version
		_encode_sem.post()

# Drain des frames encodées par le worker → diffusion aux peers, appelé à
# chaque tick (indépendant de la cadence d'enqueue) : une frame encodée part
# dès qu'elle est prête. Le flow control saute un peer dont l'ACK accuse un
# retard > WINDOW_MAX_AHEAD : inutile de lui pousser des frames intermédiaires,
# la prochaine (récente) rattrapera le temps perdu.
func _drain_encoded_frames() -> void:
	if _encode_thread == null:
		return
	_encode_mutex.lock()
	var results: Array = _encode_results
	_encode_results = []
	_encode_mutex.unlock()
	if results.is_empty():
		return
	if not windows_provider.is_valid():
		return
	var now := Time.get_ticks_msec()
	for result in results:
		var wid := int(result.get("wid", -1))
		var version := int(result.get("version", -1))
		var bytes: PackedByteArray = result.get("bytes", PackedByteArray())
		var keyframe := bool(result.get("keyframe", false))
		var t_enc := int(result.get("t_msec", 0))
		if _encode_inflight.get(wid, -1) == version:
			_encode_inflight.erase(wid)
		if keyframe:
			_last_keyframe_msec[wid] = now
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			if not _last_texture_versions.has(pid):
				_last_texture_versions[pid] = {}
			var sent: Dictionary = _last_texture_versions[pid]
			if sent.get(wid, -1) == version:
				continue
			if not keyframe:
				# Flow control par peer : pas plus de WINDOW_MAX_AHEAD frames
				# non appliquées en route (dernière envoyée − dernière ACKée).
				# Les keyframes passent TOUJOURS : elles servent justement à
				# resynchroniser un récepteur en retard.
				var last_sent: int = sent.get(wid, -1)
				var acked: int = int(_last_acked_version.get(pid, {}).get(wid, -1))
				if acked >= 0 and last_sent - acked >= WINDOW_MAX_AHEAD:
					sent[wid] = version
					continue
			if keyframe:
				# Canal 4 (fiables) : ne se met PAS en file derrière le backlog
				# du canal 2 → le récepteur se recalibre immédiatement sur un
				# saut de contenu (seek). La version permet d'ignorer les
				# frames pré-seek encore en transit sur le canal 2.
				_sync_window_keyframe.rpc_id(pid, wid, version, bytes)
			else:
				_sync_window_texture.rpc_id(pid, wid, version, bytes)
			sent[wid] = version
			# Diagnostic : timestamp d'envoi (historique par version).
			if not _frame_sent_log.has(pid):
				_frame_sent_log[pid] = {}
			if not _frame_sent_log[pid].has(wid):
				_frame_sent_log[pid][wid] = {}
			_frame_sent_log[pid][wid][version] = now
			if t_enc > 0:
				_frame_enqueued_msec[wid] = now - t_enc
	# Diagnostics périodiques (1/s) : âge du contenu à l'envoi, RTT ACK,
	# temps d'encodage.
	if now - _diag_last_log >= 1000 and not results.is_empty():
		_diag_last_log = now
		var last: Dictionary = results[results.size() - 1]
		var age_ms: int = _frame_enqueued_msec.get(int(last.get("wid", -1)), -1)
		var rtt_ms := -1
		if _diag_rtt_count > 0:
			rtt_ms = _diag_rtt_sum / _diag_rtt_count
		print("[lan] diag env: age=%dms enc=%dms rtt=%dms (n=%d)" % [
			age_ms, int(last.get("enc_us", 0)) / 1000, rtt_ms, _diag_rtt_count])
		_diag_rtt_sum = 0
		_diag_rtt_count = 0

func _start_encode_thread() -> void:
	if _encode_thread != null:
		return
	_encode_stop = false
	_encode_thread = Thread.new()
	_encode_thread.start(_encode_worker)

# Empreinte basse résolution (24×14 RGBA) d'une image : sert à détecter un
# saut de contenu (seek) entre deux frames encodées. S'exécute sur le worker.
func _frame_fingerprint(img: Image) -> PackedByteArray:
	var fp_img := img.duplicate()
	fp_img.resize(24, 14, Image.INTERPOLATE_NEAREST)
	if fp_img.get_format() != Image.FORMAT_RGBA8:
		fp_img.convert(Image.FORMAT_RGBA8)
	return fp_img.get_data()

# true si la frame courante diffère fortement de la précédente pour cette
# fenêtre (seek, changement de scène) → elle doit être une keyframe.
func _is_content_jump(wid: int, fp: PackedByteArray) -> bool:
	var prev: PackedByteArray = _frame_fingerprint_last.get(wid, PackedByteArray())
	_frame_fingerprint_last[wid] = fp
	if prev.is_empty():
		return true # première frame du stream = keyframe
	var n := mini(prev.size(), fp.size())
	if n == 0:
		return false
	var total := 0.0
	for i in range(n):
		total += absf(float(prev[i]) - float(fp[i]))
	return total / float(n) / 255.0 > WINDOW_CONTENT_JUMP_THRESHOLD

# Boucle du thread de travail : encode les images soumises (resize + JPEG),
# hors du thread principal. Lit _encode_stop sous mutex pour un arrêt propre.
func _encode_worker() -> void:
	while true:
		_encode_sem.wait()
		_encode_mutex.lock()
		var stopping := _encode_stop
		var job: Dictionary = _encode_queue.pop_front() if not _encode_queue.is_empty() else {}
		_encode_mutex.unlock()
		if stopping:
			return
		if job.is_empty():
			continue
		var img: Image = job.get("img")
		if img == null or img.is_empty():
			continue
		var wid := int(job.get("wid", -1))
		var t_enc := Time.get_ticks_usec()
		var bytes := _encode_share_frame(img,
			int(job.get("max_side", WINDOW_TEXTURE_MAX_SIDE)),
			float(job.get("quality", WINDOW_TEXTURE_QUALITY)))
		if bytes.is_empty():
			continue
		# Détection d'un saut de contenu (seek / changement de scène) : une
		# empreinte basse résolution de la frame précédente est comparée à la
		# courante. Gros écart ⇒ keyframe (le récepteur resynchronise dessus).
		var keyframe := bool(job.get("force_key", false))
		if not keyframe and _is_content_jump(wid, _frame_fingerprint(img)):
			keyframe = true
		_encode_mutex.lock()
		_encode_results.append({
			"wid": wid,
			"version": int(job.get("version", -1)),
			"bytes": bytes,
			"keyframe": keyframe,
			"t_msec": int(job.get("t_msec", 0)),
			"enc_us": Time.get_ticks_usec() - t_enc,
		})
		_encode_mutex.unlock()

func _stop_encode_thread() -> void:
	if _encode_thread == null:
		return
	_encode_mutex.lock()
	_encode_stop = true
	_encode_queue.clear()
	_encode_results.clear()
	_encode_inflight.clear()
	_encode_mutex.unlock()
	_encode_sem.post()
	_encode_thread.wait_to_finish()
	_encode_thread = null

# ── Décodage JPEG côté récepteur (thread de travail) ─────────────────
# Symétrique de l'encode : le décodage d'une vidéo partagée (plusieurs
# frames/s × 720p) sur le thread principal figeait la lecture distante.
# Le thread décode le JPEG (CPU pur), le thread principal ne fait plus que
# l'upload GPU (ImageTexture) + le swap de texture, à chaque tick.

var _decode_thread: Thread = null
var _decode_mutex := Mutex.new()
var _decode_sem := Semaphore.new()
var _decode_queue: Array = []   # {from, wid, version, bytes}
var _decode_results: Array = [] # {from, wid, version, img}
var _decode_stop := false
# from -> {wid -> version} : dernière version APPLIQUÉE sur le quad distant.
# Toute frame reçue/extraite avec une version ≤ celle-ci est ignorée (sévérité
# contre la régression après une keyframe / une réception en retard).
var _last_applied_version: Dictionary = {}

func _start_decode_thread() -> void:
	if _decode_thread != null:
		return
	_decode_stop = false
	_decode_thread = Thread.new()
	_decode_thread.start(_decode_worker)

func _decode_worker() -> void:
	while true:
		_decode_sem.wait()
		_decode_mutex.lock()
		var stopping := _decode_stop
		var job: Dictionary = _decode_queue.pop_front() if not _decode_queue.is_empty() else {}
		_decode_mutex.unlock()
		if stopping:
			return
		if job.is_empty():
			continue
		var img := Image.new()
		var err := img.load_jpg_from_buffer(job.get("bytes", PackedByteArray()))
		if err != OK or img.is_empty():
			continue
		_decode_mutex.lock()
		_decode_results.append({
			"from": int(job.get("from", -1)),
			"wid": int(job.get("wid", -1)),
			"version": int(job.get("version", -1)),
			"img": img,
		})
		_decode_mutex.unlock()

func _stop_decode_thread() -> void:
	if _decode_thread == null:
		return
	_decode_mutex.lock()
	_decode_stop = true
	_decode_queue.clear()
	_decode_results.clear()
	_decode_mutex.unlock()
	_decode_sem.post()
	_decode_thread.wait_to_finish()
	_decode_thread = null

func _drain_decoded_frames() -> void:
	_decode_mutex.lock()
	var results: Array = _decode_results
	_decode_results = []
	_decode_mutex.unlock()
	var acked_senders := {}
	for result in results:
		var from := int(result.get("from", -1))
		var wid := int(result.get("wid", -1))
		var version := int(result.get("version", -1))
		var img: Image = result.get("img")
		if img == null or img.is_empty():
			continue
		# Frame périmée (keyframe plus récente déjà appliquée) : ne pas
		# régresser l'affichage (ex. frame pré-seek arrivée après la keyframe).
		if version <= int(_last_applied_version.get(from, {}).get(wid, -1)):
			continue
		if _debug_dump_once(100000 + from):
			img.save_png("user://share_receiver_%d.png" % from)
			print("[share] receiver: ", img.get_width(), "x", img.get_height(), " wid=", wid)
		if not _last_applied_version.has(from):
			_last_applied_version[from] = {}
		_last_applied_version[from][wid] = version
		acked_senders[from] = true
		var tex: Texture2D = ImageTexture.create_from_image(img)
		# Bufferiser la texture même si l'état `shared` n'est pas encore arrivé
		# (course 1re frame vs état) : _apply_remote_windows la réappliquera.
		if not _pending_remote_textures.has(from):
			_pending_remote_textures[from] = {}
		_pending_remote_textures[from][wid] = tex
		if _remote_window_quads.has(from) and _remote_window_quads[from].has(wid):
			_set_remote_quad_texture(_remote_window_quads[from][wid], tex)
	# ACK immédiat de la version appliquée (fiables, minuscules) : l'émetteur
	# sait presque en temps réel où en est le récepteur → flow control précis.
	for from in acked_senders:
		if from in multiplayer.get_peers():
			_ack_window_versions.rpc_id(from, _last_applied_version[from])
	# Diagnostic récepteur : cadence d'application + file de décodage restante.
	_diag_applied_count += results.size()
	if Time.get_ticks_msec() - _diag_last_applied >= 1000:
		print("[lan] diag rx: appliquées/s=%d decode_q=%d" % [
			_diag_applied_count, _decode_queue.size()])
		_diag_applied_count = 0
		_diag_last_applied = Time.get_ticks_msec()

# Redimensionne (si plus grand que le cap) puis encode en JPEG.
func _encode_share_frame(img: Image, max_side: int, quality: float) -> PackedByteArray:
	var w := img.get_width()
	var h := img.get_height()
	var longest := maxi(w, h)
	if longest > max_side:
		var scale := float(max_side) / float(longest)
		var work := img.duplicate()
		work.resize(maxi(1, int(w * scale)), maxi(1, int(h * scale)), Image.INTERPOLATE_BILINEAR)
		img = work
		w = img.get_width()
		h = img.get_height()
	# Pas de duplicate si le redimensionnement n'est pas nécessaire : économise
	# une copie complète de l'image (chère sur une vidéo 720p streamée en continu).
	# S'exécute sur le thread de travail (_encode_worker).
	return img.save_jpg_to_buffer(quality)

var _debug_dumped := {}
func _debug_dump_once(key: int) -> bool:
	if _debug_dumped.has(key):
		return false
	_debug_dumped[key] = true
	return true

# Réception d'une frame partagée : décodée puis appliquée sur le quad distant.
# Les frames en retard pour une fenêtre désormais non partagée sont ignorées.
# FIABLE (canal 2) : les frames JPEG (grosses, fragmentées par ENet) sont
# retransmises en cas de perte. En mode non fiable, un seul fragment perdu
# sur le WiFi faisait tomber TOUTE la frame → la vidéo distante sautillait
# ("pas fluide du tout"). Fiables, les fragments perdus sont retransmis (le
# récepteur les re-séquence) et seules les frames incomplètes sont ignorées.
# Canal 2 séparé : la sync des avatars (canal 0) n'est jamais retardée.
@rpc("any_peer", "call_remote", "reliable", 2)
func _sync_window_texture(wid: int, version: int, bytes: PackedByteArray) -> void:
	_receive_share_frame(wid, version, bytes, false)

# Keyframe (seek / saut de contenu / keyframe périodique) : canal 4 fiable,
# indépendant du canal 2 → ne se met PAS en file derrière les frames pré-seek
# encore en transit. Le récepteur se recalibre immédiatement dessus : il
# ignore alors toute frame de version antérieure encore en file de décodage.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_window_keyframe(wid: int, version: int, bytes: PackedByteArray) -> void:
	_receive_share_frame(wid, version, bytes, true)

func _receive_share_frame(wid: int, version: int, bytes: PackedByteArray, is_keyframe: bool) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if bytes.is_empty():
		return
	# Une version déjà appliquée (ou plus ancienne, reçue en retard via le
	# canal 2 après une keyframe) ne doit jamais régresser l'affichage.
	var last: int = int(_last_applied_version.get(from, {}).get(wid, -1))
	if version <= last:
		return
	if is_keyframe:
		# Vider la file de décodage des frames antérieures de cette fenêtre :
		# elles sont périmées, inutile de perdre du CPU à les décoder.
		_decode_mutex.lock()
		var kept: Array = []
		for j in _decode_queue:
			if int(j.get("from", -1)) == from \
					and int(j.get("wid", -1)) == wid \
					and int(j.get("version", -1)) < version:
				continue
			kept.append(j)
		_decode_queue = kept
		_decode_mutex.unlock()
	_start_decode_thread()
	_decode_mutex.lock()
	_decode_queue.append({"from": from, "wid": wid, "version": version, "bytes": bytes})
	_decode_mutex.unlock()
	_decode_sem.post()

# ACK du récepteur vers l'émetteur : dernière version appliquée par fenêtre.
# Fiables (petits) → quasi jamais perdus ; s'ils sont retardés, l'émetteur
# saute des frames (le backlog ne grossit pas) et reprend dès leur arrivée.
# Canal 5 dédié : ne se met pas en file derrière les RPC fiables volumineux
# du canal 0 (niveau, états) qui pourraient retarder le flow control.
@rpc("any_peer", "call_remote", "reliable", 5)
func _ack_window_versions(versions: Dictionary) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	# Max par fenêtre : un ACK reçu en retard ne doit pas régresser l'écart.
	var cur: Dictionary = _last_acked_version.get(from, {})
	for wid in versions:
		if int(versions[wid]) > int(cur.get(wid, -1)):
			cur[wid] = versions[wid]
	_last_acked_version[from] = cur
	# Diagnostic RTT : aller-retour envoi → application distante → ACK.
	# L'ACK accuse une version passée : on la retrouve dans l'historique
	# d'envoi (et on purge les entrées trop anciennes).
	var sent_log: Dictionary = _frame_sent_log.get(from, {})
	for wid in versions:
		var v := int(versions[wid])
		if sent_log.has(wid) and sent_log[wid].has(v):
			var sent_t: int = int(sent_log[wid][v])
			_diag_rtt_sum += Time.get_ticks_msec() - sent_t
			_diag_rtt_count += 1
	var now_m := Time.get_ticks_msec()
	for wid in sent_log:
		var to_purge: Array = []
		for v in sent_log[wid]:
			if now_m - int(sent_log[wid][v]) > 2000:
				to_purge.append(v)
		for v in to_purge:
			sent_log[wid].erase(v)

# ── Audio partagé : capture (émetteur) + lecture (récepteur) ──────────

# Active/arrête la capture audio selon qu'il existe au moins une fenêtre
# locale partagée ET visible (même condition que le stream vidéo), puis
# envoie les paquets OPUS disponibles sur le canal 3 (non fiable).
func _sync_audio_state() -> void:
	if compositor == null:
		return
	var want := false
	if windows_provider.is_valid():
		for item in windows_provider.call():
			if item is Dictionary \
					and bool(item.get("shared", false)) \
					and bool(item.get("visible", true)):
				want = true
				break
	if want and not _audio_active:
		if compositor.start_audio_share():
			_audio_active = true
			_audio_start_msec = Time.get_ticks_msec()
			_audio_send_count = 0
			_audio_no_data_warned = false
			print("[audio] capture démarrée (audio de session)")
	elif not want and _audio_active:
		compositor.stop_audio_share()
		_audio_active = false
		_audio_send_count = 0
		_audio_no_data_warned = false
		print("[audio] capture arrêtée")
	if not _audio_active:
		return
	# Un seul poll par frame (~60/s pour ~50 paquets/s de 20 ms) : le paquet
	# est diffusé à tous les peers (un poll par peer alternerait les paquets
	# entre eux et diviserait la cadence effective par peer).
	var packet: Dictionary = compositor.poll_audio_packet()
	if packet.is_empty():
		# Diagnostique : capture active mais aucun paquet OPUS produit.
		if _audio_send_count == 0 and not _audio_no_data_warned \
				and Time.get_ticks_msec() - _audio_start_msec > 3000:
			_audio_no_data_warned = true
			push_warning("[audio] capture active mais aucun paquet OPUS (stream PipeWire non connecté ?)")
		return
	_audio_send_count += 1
	var data: PackedByteArray = packet.get("data", PackedByteArray())
	if data.is_empty():
		return
	for pid in multiplayer.get_peers():
		if pid == multiplayer.get_unique_id():
			continue
		_sync_audio.rpc_id(pid, data)

# Réception d'un paquet OPUS (20 ms) : décodé puis poussé dans le générateur
# audio. Canal 3 séparé + non fiable : un paquet perdu = 20 ms de silence,
# le flux ne bloque jamais (fiable re-séquencerait tout derrière la perte).
@rpc("any_peer", "call_remote", "unreliable", 3)
func _sync_audio(bytes: PackedByteArray) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if bytes.is_empty() or compositor == null:
		return
	var pcm: PackedByteArray = compositor.audio_decode(bytes)
	if pcm.is_empty():
		if not _audio_decode_warned:
			_audio_decode_warned = true
			push_warning("[audio] paquets reçus mais décodage OPUS vide")
		return
	_audio_received_count += 1
	if not _audio_first_printed:
		_audio_first_printed = true
		print("[audio] premier paquet reçu et décodé (%d frames)" % (pcm.size() / 4))
	_ensure_audio_player()
	var frames := PackedVector2Array()
	var n := pcm.size() / 4
	frames.resize(n)
	for i in n:
		var s := i * 4
		var l := float(pcm.decode_s16(s)) / 32768.0
		var r := float(pcm.decode_s16(s + 2)) / 32768.0
		frames[i] = Vector2(l, r)
	if _audio_playback != null and is_instance_valid(_audio_playback):
		_audio_playback.push_buffer(frames)

# Crée le lecteur de flux audio distant au premier paquet reçu. Le buffer du
# générateur (0.5 s) absorbe la gigue réseau ; push_buffer laisse tomber les
# frames quand il est plein (la fraîcheur prime sur la continuité).
func _ensure_audio_player() -> void:
	if _audio_player != null and is_instance_valid(_audio_player):
		return
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AUDIO_MIX_RATE
	gen.buffer_length = AUDIO_BUFFER_SEC
	_audio_player = AudioStreamPlayer.new()
	_audio_player.stream = gen
	add_child(_audio_player)
	_audio_player.play()
	_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback

func _stop_audio_share() -> void:
	if _audio_active and compositor != null:
		compositor.stop_audio_share()
	_audio_active = false
	_audio_start_msec = 0
	_audio_send_count = 0
	_audio_no_data_warned = false
	if _audio_player != null and is_instance_valid(_audio_player):
		_audio_player.stop()
		_audio_player.queue_free()
		_audio_player = null
	_audio_playback = null
	_audio_received_count = 0
	_audio_first_printed = false
	_audio_decode_warned = false

# Crée/met à jour/supprime les quads noirs représentant les fenêtres d'un
# joueur distant. Diff sur les wid : ceux absents du paquet sont retirés.
func _apply_remote_windows(peer_id: int, windows: Array) -> void:
	if windows.is_empty():
		_clear_remote_windows(peer_id)
		return
	if _remote_windows_root == null or not is_instance_valid(_remote_windows_root):
		return
	var container: Node3D = _remote_windows.get(peer_id)
	if container == null or not is_instance_valid(container):
		container = Node3D.new()
		container.name = "Win" + str(peer_id)
		_remote_windows_root.add_child(container)
		_remote_windows[peer_id] = container
		_remote_window_quads[peer_id] = {}
		_remote_shared[peer_id] = {}
	var quads: Dictionary = _remote_window_quads[peer_id]
	var shared_dict: Dictionary = _remote_shared[peer_id]
	var seen := {}
	for item in windows:
		if not item is Dictionary:
			continue
		var wid := int(item.get("wid", -1))
		if wid < 0:
			continue
		seen[wid] = true
		var shared: bool = bool(item.get("shared", false))
		shared_dict[wid] = shared
		var quad: MeshInstance3D = quads.get(wid)
		if quad == null or not is_instance_valid(quad):
			quad = _make_remote_quad()
			quad.name = str(wid)
			container.add_child(quad)
			quads[wid] = quad
		quad.global_transform = item.get("transform", Transform3D.IDENTITY)
		if quad.mesh is QuadMesh:
			(quad.mesh as QuadMesh).size = item.get("size", Vector2.ONE)
		quad.visible = bool(item.get("visible", true))
		# SHARE OFF : le quad redevient noir (placeholder). SHARE ON : les
		# frames streamées (rpc _sync_window_texture) le textureront en direct.
		if not shared:
			_set_remote_quad_texture(quad, null)
		else:
			# Course 1re frame vs état : si une texture a déjà été reçue,
			# l'appliquer maintenant (le quad vient peut-être d'être recréé).
			var pending: Dictionary = _pending_remote_textures.get(peer_id, {})
			if pending.has(wid):
				_set_remote_quad_texture(quad, pending[wid])
	for wid in quads.keys():
		if seen.has(wid):
			continue
		var q: Node3D = quads[wid]
		if is_instance_valid(q):
			q.queue_free()
		quads.erase(wid)
	if quads.is_empty():
		_clear_remote_windows(peer_id)

# Quad représentant une fenêtre distante : noir tant que la fenêtre n'est pas
# partagée (SHARE OFF), texturé par le contenu réel quand les frames arrivent
# (SHARE ON). Unshaded, transparent, double face, sans ombre.
func _make_remote_quad() -> MeshInstance3D:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	quad.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.albedo_color = Color.BLACK
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material_override = mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return quad

# Pose/retire la texture du contenu réel sur le quad distant. Sans texture, le
# quad revient au noir (placeholder, SHARE OFF).
func _set_remote_quad_texture(quad: MeshInstance3D, tex: Texture2D) -> void:
	if quad == null or not is_instance_valid(quad):
		return
	var mat: StandardMaterial3D = quad.material_override
	if mat == null:
		return
	if tex == null:
		mat.albedo_texture = null
		mat.albedo_color = Color.BLACK
	else:
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE

func _clear_remote_windows(peer_id: int) -> void:
	var container: Node3D = _remote_windows.get(peer_id)
	if container != null and is_instance_valid(container):
		container.queue_free()
	_remote_windows.erase(peer_id)
	_remote_window_quads.erase(peer_id)
	_remote_shared.erase(peer_id)
	_pending_remote_textures.erase(peer_id)
	_last_applied_version.erase(peer_id)

func _clear_all_remote_windows() -> void:
	for peer_id in _remote_windows.keys().duplicate():
		_clear_remote_windows(peer_id)
	_last_texture_versions.clear()
	_last_applied_version.clear()
	_last_acked_version.clear()

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
	_stop_audio_share()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	_clear_remote_players()
	_clear_all_remote_windows()
	_last_texture_versions.clear()
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
	_stop_encode_thread()
	_stop_decode_thread()
	_stop_audio_share()
	_stop_responder()
	if _scanner:
		_scanner.close()
		_scanner = null
	_clear_all_remote_windows()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
