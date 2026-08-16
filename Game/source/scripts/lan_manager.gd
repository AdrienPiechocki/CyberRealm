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
# Références vers les sous-systèmes locaux (posées par wayland_room) : mise à
# jour des PiP / overlays focus des fenêtres distantes (vue seule).
var pins = null
var focus = null
# Joueur local (posé par wayland_room) : transmis aux avatars distants pour la
# transparence de proximité (fondus sous 1 m).
var local_player: Node3D = null

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
# peer_id -> {wid -> ImageTexture} : textures REUTILISÉES du récepteur. Chaque
# frame décodée est appliquée en place (tex.update) au lieu d'allouer une
# nouvelle ImageTexture + upload GPU complet à chaque frame → moins de churn
# GPU, la vidéo distante est moins saccadée.
var _remote_textures: Dictionary = {}
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
var _diag_sent_in_sec := 0
var _diag_applied_count := 0
var _diag_last_applied := 0
var _diag_rx_proc_sum := 0
var _diag_rx_proc_n := 0
const WINDOW_SYNC_GAP := 1.0 # resync périodique (auto-réparation des paquets perdus)
const WINDOW_SYNC_MOVE_GAP := 0.05 # cadence pendant un déplacement/redimensionnement
# Cadence et qualités du stream vidéo partagé. Le stream passe par des
# paquets UDP fragmentés (non fiables) : en le gardant léger on évite la
# congestion du lien WiFi (perte → throttle ENet → lag) et les timeout de
# déconnexion pendant une vidéo.
const WINDOW_TEXTURE_GAP := 0.02 # cadence d'enqueue (50/s max) — le débit réel est borné par le flow control + la capture (~30/s)
const WINDOW_TEXTURE_MAX_SIDE := 1920 # cap de résolution pour l'encodage JPEG
const WINDOW_TEXTURE_QUALITY := 0.85 # qualité JPEG du partage
const WINDOW_VIDEO_MAX_SIDE := 1024 # cap vidéo : ≤ ~40KB/frame (≤ 32 fragments ENet) pour une livraison fiable en 1 vague → RTT bas → 30 ips
const WINDOW_VIDEO_QUALITY := 0.7 # qualité réduite pour une fenêtre en mouvement continu
const WINDOW_FRAME_MAX_BYTES := 40000 # plafond dur : ré-encodage à qualité décroissante au-delà (fenêtre fiable ENet = 32 fragments ≈ 44KB)
const WINDOW_FRAME_MIN_QUALITY := 0.4 # qualité minimale du ré-encodage d'appoint
const WINDOW_CONTENT_JUMP_THRESHOLD := 0.2 # diff moyenne/pixel > 20% entre 2 frames = saut de contenu (seek) → keyframe
const WINDOW_KEYFRAME_GAP_MSEC := 1500 # keyframe périodique : borne la dérive résiduelle du stream
const WINDOW_MAX_AHEAD := 3 # flow control : au plus 3 frames non appliquées en route. Pipelinage : 3 frames en vol × ~20ms/frame de livraison → ~30 ips à faible RTT

# ── Stream vidéo inter-frame (H.264/AV1) ─────────────────────────────
# Remplace le JPEG par-frame : le compositeur rend les fenêtres partagées
# dans des DMA-BUF qu'un encodeur (VAAPI matériel, fallback libx264) convertit
# en flux inter-frame sur un thread worker C++ (VideoShare). Le thread
# principal ne fait que poller les paquets et les diffuser. Les frames sont
# petites (P-frames) mais dépendantes : pas de drop possible (le compositeur
# saute une capture si l'encodeur lit encore le buffer), les keyframes
# resynchronisent.
const VIDEO_BITRATE := 6_000_000 # débit cible par fenêtre (bits/s) ; total = n_fenêtres × ceci. 6 Mb/s à 60 ips ≈ 12,5 KB/frame, tenable en LAN et suffisant pour du 1080p fluide
const VIDEO_CODEC_PREF := ["h264", "av1"] # essai dans cet ordre. h264 VAAPI d'abord : l'encodeur AV1 matériel de Mesa est lent/instable sur RDNA3 (le worker VAAPI tombait à ~6 ips alors que h264_vaapi encodera confortablement le 1080p à 60 ips). av1 = matériel seulement (pas de fallback logiciel)
const VIDEO_PACKET_SINGLE_MAX := 40000 # paquet ≤ ceci : 1 RPC (≤ 32 fragments ENet, 1 vague)
const VIDEO_CHUNK_SIZE := 30000 # au-delà : découpage, chaque morceau ≤ 1 vague ENet
const VIDEO_CHUNK_STALE_MSEC := 2000 # purge des assemblages de chunks incomplets
const VIDEO_MAX_AHEAD := 6 # flow control : ≤ 6 frames non appliquées en vol par peer. À 60 ips (16,7 ms/frame) et ~20 ms de RTT ACK, il faut ≥ 2-3 frames en vol : 6 laisse la marge contre les sursauts réseau sans gonfler la latence
const VIDEO_NACK_GAP_MSEC := 500 # demande de keyframe (NACK) au plus 2×/s par fenêtre

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
# L'audio diffusé est celui des SEULES fenêtres partagées : le compositeur
# capture les applications dont le PID figure dans _audio_share_pids
# (matching avec application.process.id des nodes PipeWire).
# Paquets OPUS 20 ms (48 kHz stéréo) sur le canal 3 (non fiable) : un paquet
# perdu = 20 ms de silence, sans blocage. La lecture côté récepteur utilise
# AudioStreamGenerator (push_buffer) : si le buffer est plein on laisse
# tomber les frames, la fraîcheur prime.
var _audio_active := false
var _audio_share_pids: Array = []
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

# ── Stream vidéo inter-frame (encodeur C++ VideoShare) ───────────────
var _video_mode := false # encodeur vidéo actif (video_share_start réussi)
var _video_codec := ""   # codec actif ("h264" | "av1")
var _video_windows_sent := PackedInt32Array() # dernier ensemble envoyé à set_video_share_windows
# wid -> [codec, w, h] : dernière config annoncée (détection de changement de
# taille → re-annonce → le récepteur recrée son décodeur).
var _video_config_last := {}
# peer -> {wid -> true} : configs déjà envoyées à ce peer.
var _video_config_sent := {}
# peer -> {wid -> seq} : dernière seq envoyée (flow control de l'émetteur).
var _video_last_sent := {}
# peer -> {wid -> seq} : dernière seq que le récepteur a confirmée appliquée.
var _video_acked := {}
# from -> {wid -> {codec, w, h}} : configs reçues (côté récepteur).
var _video_configs := {}
# from -> {wid -> seq} : dernière seq appliquée sur le quad distant.
var _video_applied := {}
# from -> {wid -> seq} : ACK en attente d'envoi (batching par tick).
var _video_ack_pending := {}
# from -> {wid -> {seq, total, parts, t}} : assemblage de paquets chunkés.
var _video_chunks := {}
# from -> {wid -> msec} : dernier NACK envoyé (throttle).
var _video_nack_last := {}
# Diagnostics du flux vidéo.
var _video_diag_last_log := 0
var _video_geom_warn_last := 0
var _video_diag_sent := 0
var _video_diag_bytes := 0
var _video_diag_last_applied := 0
var _video_diag_applied := 0
# Décodeur vidéo sur thread worker (même mécanique que le décodeur JPEG) :
# à 60 ips, le décodage AVCodec + la conversion swscale (~5-8 ms en 1080p)
# NE doivent PAS bloquer le thread principal (sinon saccade du jeu ET du
# stream). Le thread principal ne fait que réassembler les chunks, enfiler
# et appliquer les images décodées (tex.update) à la cadence du tick.
var _video_decode_thread: Thread = null
var _video_decode_mutex := Mutex.new()
var _video_decode_sem := Semaphore.new()
var _video_decode_queue: Array = []     # {from, wid, seq, keyframe, bytes}
var _video_decode_results: Array = []   # {from, wid, seq, keyframe, img}
var _video_decode_stop := false

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
	var err := peer.create_server(PORT, MAX_PLAYERS, 8)
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
	var err := peer.create_client(ip, PORT, 8)
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
	avatar.local_player = local_player
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
	_video_last_sent.erase(id)
	_video_acked.erase(id)
	_video_config_sent.erase(id)
	_video_ack_pending.erase(id)
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
	_update_cpu_capture_request()
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
	_sync_video_state()
	_drain_encoded_frames()
	_drain_video_packets()
	_process_video_receiver()
	_sync_audio_state()
	_drain_decoded_frames()

# Active/désactive la copie CPU synchrone des fenêtres dans le compositeur.
# Celle-ci (DMA_BUF_SYNC + memcpy/swizzle) ne sert QU'au stream LAN ; sur le
# chemin Vulkan zero-copy l'affichage des quads passe par le VkImage importé.
# Sans session ou sans fenêtre partagée, elle ne doit PAS tourner : elle
# coûte 30-50 ms par capture 1920×1080 sur le thread principal (chute de FPS
# dès qu'une fenêtre animée est ouverte). En mode vidéo inter-frame elle ne
# doit pas non plus tourner : l'encodeur C++ lit le DMA-BUF directement
# (thread worker), la copie CPU ne sert plus à rien.
func _update_cpu_capture_request() -> void:
	if compositor == null or not compositor.has_method("set_cpu_capture_requested"):
		return
	var need := false
	if session_active and windows_provider.is_valid() and not multiplayer.get_peers().is_empty() and not _video_mode:
		for item in windows_provider.call():
			if not item is Dictionary:
				continue
			if bool(item.get("shared", false)) and bool(item.get("visible", true)):
				need = true
				break
	compositor.set_cpu_capture_requested(need)

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
	if _video_mode:
		return # remplacé par le stream vidéo inter-frame (VideoShare C++)
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
			_diag_sent_in_sec += 1
	# Diagnostics périodiques (1/s) : âge du contenu à l'envoi, RTT ACK,
	# temps d'encodage, écart ACK (flow control) et cadence d'envoi.
	if now - _diag_last_log >= 1000 and not results.is_empty():
		_diag_last_log = now
		var last: Dictionary = results[results.size() - 1]
		var age_ms: int = _frame_enqueued_msec.get(int(last.get("wid", -1)), -1)
		var last_bytes: PackedByteArray = last.get("bytes", PackedByteArray())
		var rtt_ms := -1
		if _diag_rtt_count > 0:
			rtt_ms = _diag_rtt_sum / _diag_rtt_count
		var gap := -99
		var lwid := int(last.get("wid", -1))
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			var s: int = int(_last_texture_versions.get(pid, {}).get(lwid, -1))
			var a: int = int(_last_acked_version.get(pid, {}).get(lwid, -1))
			if a >= 0:
				gap = s - a
			break
		print("[lan] diag env: age=%dms enc=%dms rtt=%dms (n=%d) gap=%d send/s=%.1f bytes=%d" % [
			age_ms, int(last.get("enc_us", 0)) / 1000, rtt_ms, _diag_rtt_count,
			gap, float(_diag_sent_in_sec), last_bytes.size()])
		_diag_rtt_sum = 0
		_diag_rtt_count = 0
		_diag_sent_in_sec = 0

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
		var max_side := int(job.get("max_side", WINDOW_TEXTURE_MAX_SIDE))
		var quality := float(job.get("quality", WINDOW_TEXTURE_QUALITY))
		var bytes := _encode_share_frame(img, max_side, quality)
		# Plafond dur sur la taille : au-delà, la frame dépasse la fenêtre
		# fiable ENet (32 fragments ≈ 44KB) et sa livraison retombe en 2-3
		# vagues d'ACK (RTT ~150ms au lieu de ~50ms). Ré-encodage à qualité
		# décroissante pour rester en 1 vague, la qualité s'adapte au contenu.
		if bytes.size() > WINDOW_FRAME_MAX_BYTES and quality > WINDOW_FRAME_MIN_QUALITY:
			bytes = _encode_share_frame(img, max_side, maxf(WINDOW_FRAME_MIN_QUALITY, quality * 0.78))
		if bytes.size() > WINDOW_FRAME_MAX_BYTES and quality > WINDOW_FRAME_MIN_QUALITY:
			bytes = _encode_share_frame(img, max_side, WINDOW_FRAME_MIN_QUALITY)
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
			"t_recv": int(job.get("t_recv", 0)),
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
		var t_recv := int(result.get("t_recv", 0))
		if t_recv > 0:
			_diag_rx_proc_sum += Time.get_ticks_msec() - t_recv
			_diag_rx_proc_n += 1
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
		var tex: Texture2D = _make_or_update_remote_texture(from, wid, img)
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
	# Diagnostic récepteur : cadence d'application + file de décodage restante
	# + temps local réception→application (décodage + upload GPU).
	_diag_applied_count += results.size()
	if Time.get_ticks_msec() - _diag_last_applied >= 1000:
		var rx_ms := -1
		if _diag_rx_proc_n > 0:
			rx_ms = _diag_rx_proc_sum / _diag_rx_proc_n
		print("[lan] diag rx: appliquées/s=%d decode_q=%d rx_proc=%dms" % [
			_diag_applied_count, _decode_queue.size(), rx_ms])
		_diag_applied_count = 0
		_diag_rx_proc_sum = 0
		_diag_rx_proc_n = 0
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
	_decode_queue.append({"from": from, "wid": wid, "version": version, "bytes": bytes, "t_recv": Time.get_ticks_msec()})
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
# Depuis la capture « fenêtres seules » : on transmet au compositeur les PIDs
# des fenêtres partagées, seules leurs applications audio sont capturées.
func _sync_audio_state() -> void:
	if compositor == null:
		return
	var want := false
	var pids: Array = []
	if windows_provider.is_valid():
		for item in windows_provider.call():
			if item is Dictionary \
					and bool(item.get("shared", false)) \
					and bool(item.get("visible", true)):
				want = true
				var pid := int(item.get("pid", -1))
				if pid > 0 and not pids.has(pid):
					pids.append(pid)
	if want and not _audio_active:
		_audio_share_pids = pids
		if compositor.start_audio_share():
			compositor.set_audio_share_pids(pids)
			_audio_active = true
			_audio_start_msec = Time.get_ticks_msec()
			_audio_send_count = 0
			_audio_no_data_warned = false
			print("[audio] capture démarrée (audio des fenêtres partagées: %s)" % str(pids))
	elif want:
		# L'ensemble des fenêtres partagées a pu changer : on resynchronise.
		if pids != _audio_share_pids:
			_audio_share_pids = pids
			compositor.set_audio_share_pids(pids)
			print("[audio] cibles audio mises à jour: %s" % str(pids))
	elif not want and _audio_active:
		compositor.stop_audio_share()
		_audio_active = false
		_audio_share_pids = []
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

# ── Stream vidéo inter-frame (H.264/AV1) ─────────────────────────────
# Émetteur : VideoShare (C++) encode les DMA-BUF des fenêtres partagées sur
# un thread worker ; on poll les paquets et on les diffuse aux peers (canal 2
# frames, canal 4 keyframes/config, canal 5 ACK), avec flow control par peer.
# Récepteur : on recrée un décodeur AVCodec par flux (clé from|wid) à partir
# de la config annoncée, on réassemble les paquets chunkés et on applique
# l'image décodée sur le quad distant (même mécanique que le JPEG : pending
# textures + _set_remote_quad_texture). Le décodage AVCodec (~5-8 ms en
# 1080p) tourne sur un thread worker (_video_decode_worker) : à 60 ips il ne
# doit pas bloquer le thread principal. L'encode tourne aussi hors thread
# principal (VideoShare C++).

func _video_key(from: int, wid: int) -> String:
	return "%d|%d" % [from, wid]

# Active/arrête l'encodeur vidéo selon la présence de fenêtres partagées
# (même condition que le stream JPEG) et maintient l'ensemble des fenêtres
# partagées + la config annoncée aux peers. Si l'encodeur ne démarre pas
# (AV1 matériel indisponible, pas de libx264), on reste en JPEG :
# cpu_capture_requested reste à true.
func _sync_video_state() -> void:
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
	if want and not _video_mode:
		_start_video_share()
	if not _video_mode:
		return
	if not want:
		_stop_video_share()
		return
	_update_video_windows()
	_announce_video_configs(false)

func _start_video_share() -> void:
	if compositor == null or not compositor.has_method("video_share_start"):
		return
	for codec in VIDEO_CODEC_PREF:
		if compositor.video_share_start(codec, VIDEO_BITRATE):
			_video_mode = true
			_video_codec = compositor.video_share_codec()
			var hw := compositor.video_share_hardware()
			print("[video] partage inter-frame démarré: codec=%s matériel=%s bitrate=%d" % [
				_video_codec, "oui" if hw else "non", VIDEO_BITRATE])
			return
	print("[video] encodeur vidéo indisponible — partage en JPEG")

func _stop_video_share() -> void:
	if _video_mode and compositor != null and compositor.has_method("video_share_stop"):
		compositor.video_share_stop()
	_video_mode = false
	_video_codec = ""
	_video_windows_sent = PackedInt32Array()
	_video_config_last.clear()
	_video_config_sent.clear()
	_video_last_sent.clear()
	_video_acked.clear()

# Maintient l'ensemble des fenêtres partagées envoyé à l'encodeur (C++).
func _update_video_windows() -> void:
	var wids := PackedInt32Array()
	if windows_provider.is_valid():
		for item in windows_provider.call():
			if item is Dictionary \
					and bool(item.get("shared", false)) \
					and bool(item.get("visible", true)):
				wids.append(int(item.get("wid", -1)))
	wids.sort()
	if wids != _video_windows_sent:
		compositor.set_video_share_windows(wids)
		# Une fenêtre retirée du partage : le récepteur a libéré son décodeur.
		# Si elle est re-partagée, sa config doit être re-annoncée (sinon le
		# récepteur n'aurait jamais de config → NACK en boucle).
		for wid in _video_config_last.keys():
			if not wids.has(wid):
				_video_config_last.erase(wid)
		_video_windows_sent = wids

# Annonce la config (codec + dimensions pixels) des fenêtres partagées aux
# peers : nécessaire au récepteur pour créer son décodeur AVCodec. Envoyée à
# un nouveau peer, ou à tous quand la config change (démarrage/redémarrage du
# flux, changement de taille). `force` envoie à tous les peers.
func _announce_video_configs(force: bool) -> void:
	if not _video_mode or compositor == null \
			or not compositor.has_method("get_window_geometry"):
		return
	for wid in _video_windows_sent:
		var geo: Dictionary = compositor.get_window_geometry(wid)
		var w := int(geo.get("width", 0))
		var h := int(geo.get("height", 0))
		if w <= 0 or h <= 0:
			# Fenêtre pas encore géométrée (X11/xwayland sans window_geometry) :
			# on ne peut pas créer le décodeur côté récepteur. Réessayé au prochain
			# tick (dès que la géométrie est connue, la config part et les frames
			# reprennent). Diagnostic throttlé pour ne pas spammer.
			var now2 := Time.get_ticks_msec()
			if now2 - _video_geom_warn_last >= 2000:
				_video_geom_warn_last = now2
				print("[video] wid=%d : géométrie indisponible (%dx%d) — config différée" % [wid, w, h])
			continue
		var cfg := [_video_codec, w, h]
		var changed: bool = _video_config_last.get(wid, []) != cfg
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			var sent: Dictionary = _video_config_sent.get(pid, {})
			if force or changed or not sent.has(wid):
				_sync_video_config.rpc_id(pid, wid, _video_codec, w, h)
				sent[wid] = true
				_video_config_sent[pid] = sent
		if changed:
			_video_config_last[wid] = cfg

# Poll des paquets vidéo produits par l'encodeur (thread worker C++) et
# diffusion aux peers, avec flow control par peer (≤ VIDEO_MAX_AHEAD frames
# non appliquées en vol). Appelé chaque tick : un paquet part dès qu'il est
# prêt, sans attendre la prochaine fenêtre d'enqueue de la capture.
func _drain_video_packets() -> void:
	if not _video_mode or compositor == null or not compositor.has_method("video_share_poll"):
		return
	_check_video_new_peers()
	var packets: Array = compositor.video_share_poll()
	for packet in packets:
		var wid := int(packet.get("wid", -1))
		var seq := int(packet.get("seq", -1))
		var keyframe := bool(packet.get("keyframe", false))
		var data: PackedByteArray = packet.get("data", PackedByteArray())
		if wid < 0 or seq < 0 or data.is_empty():
			continue
		for pid in multiplayer.get_peers():
			if pid == multiplayer.get_unique_id():
				continue
			if not _video_last_sent.has(pid):
				_video_last_sent[pid] = {}
			var sent: Dictionary = _video_last_sent[pid]
			var acked := int(_video_acked.get(pid, {}).get(wid, -1))
			if seq <= acked:
				continue
			if not keyframe:
				# Flow control : si ce peer a déjà VIDEO_MAX_AHEAD frames non
				# appliquées en route, on saute les P-frames (la prochaine
				# keyframe le resynchronisera) pour ne pas saturer ENet.
				var last_sent: int = sent.get(wid, -1)
				if acked >= 0 and last_sent - acked >= VIDEO_MAX_AHEAD:
					sent[wid] = seq
					continue
			if not _video_config_sent.get(pid, {}).has(wid):
				# Config pas encore partie (peer qui vient de se connecter) :
				# inutile d'envoyer des frames qu'il ne peut pas décoder.
				_announce_video_configs(false)
				continue
			_send_video_packet(pid, wid, seq, keyframe, data)
			sent[wid] = seq
			_video_diag_sent += 1
			_video_diag_bytes += data.size()
	var now := Time.get_ticks_msec()
	if now - _video_diag_last_log >= 1000:
		_video_diag_last_log = now
		if _video_diag_sent > 0:
			print("[video] diag env: %d pkt/s %.1f KB/s pending=%d windows=%d" % [
				_video_diag_sent, float(_video_diag_bytes) / 1024.0,
				compositor.video_share_pending(), _video_windows_sent.size()])
		_video_diag_sent = 0
		_video_diag_bytes = 0

# Un nouveau peer (join en cours de partie) reçoit immédiatement la config et
# une keyframe par fenêtre partagée pour se synchroniser sans attendre la
# keyframe périodique du gop.
func _check_video_new_peers() -> void:
	for pid in multiplayer.get_peers():
		if pid == multiplayer.get_unique_id():
			continue
		if _video_last_sent.has(pid):
			continue
		_video_last_sent[pid] = {}
		_video_acked[pid] = {}
		_announce_video_configs(false)
		for wid in _video_windows_sent:
			compositor.video_share_request_keyframe(wid)
		print("[video] peer %d rejoint : config + keyframes demandées (%d fenêtre(s))" % [
			pid, _video_windows_sent.size()])

# Paquets ≤ VIDEO_PACKET_SINGLE_MAX : 1 RPC (≤ 32 fragments ENet, 1 vague).
# Au-delà (surtout les keyframes) : découpage en morceaux ≤ VIDEO_CHUNK_SIZE,
# chaque morceau reste dans une vague fiable ENet.
func _send_video_packet(pid: int, wid: int, seq: int, keyframe: bool, data: PackedByteArray) -> void:
	if data.size() <= VIDEO_PACKET_SINGLE_MAX:
		if keyframe:
			_sync_video_keyframe.rpc_id(pid, wid, seq, 0, 1, data)
		else:
			_sync_video_frame.rpc_id(pid, wid, seq, 0, 1, data)
		return
	var total := ceili(float(data.size()) / float(VIDEO_CHUNK_SIZE))
	for i in total:
		var start := i * VIDEO_CHUNK_SIZE
		var slice := data.slice(start, mini(start + VIDEO_CHUNK_SIZE, data.size()))
		if keyframe:
			_sync_video_keyframe.rpc_id(pid, wid, seq, i, total, slice)
		else:
			_sync_video_frame.rpc_id(pid, wid, seq, i, total, slice)

# Frame vidéo (P-frame ou keyframe) : canal 2 fiable, indépendant de la sync
# des avatars (canal 0). Réassemblée puis décodée (video_decoder_feed) sur le
# thread principal — le décodage AVCodec (~2-5 ms en 720p) est bien plus léger
# que le JPEG par-frame, et l'encode tourne déjà sur un thread worker C++.
@rpc("any_peer", "call_remote", "reliable", 2)
func _sync_video_frame(wid: int, seq: int, index: int, total: int, bytes: PackedByteArray) -> void:
	_receive_video_frame(wid, seq, index, total, bytes, false)

# Keyframe : canal 4 fiable (comme le JPEG) → ne se met PAS en file derrière
# le backlog du canal 2 → le récepteur se recalibre immédiatement.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_video_keyframe(wid: int, seq: int, index: int, total: int, bytes: PackedByteArray) -> void:
	_receive_video_frame(wid, seq, index, total, bytes, true)

# Config du flux (codec + dimensions pixels) d'une fenêtre d'un peer : permet
# au récepteur de créer son contexte de décodage AVCodec. Reçue aussi sur un
# redémarrage du flux émetteur (les seq repartent de 0) → reset du décodeur.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_video_config(wid: int, codec: String, width: int, height: int) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if (codec != "h264" and codec != "av1") or width <= 0 or height <= 0:
		return
	if compositor == null or not compositor.has_method("video_decoder_configure"):
		return
	# Toujours recréer le décodeur : une config (même identique) signale aussi
	# un redémarrage du flux émetteur → les seq repartent de 0 et seules les
	# keyframes suivantes sont décodables.
	if not _video_configs.has(from):
		_video_configs[from] = {}
	_video_configs[from][wid] = {"codec": codec, "w": width, "h": height}
	compositor.video_decoder_configure(_video_key(from, wid), codec, width, height)
	if not _video_applied.has(from):
		_video_applied[from] = {}
	_video_applied[from][wid] = -1
	if _video_chunks.has(from):
		_video_chunks[from].erase(wid)
	_request_video_keyframe(from, wid)

# NACK du récepteur : l'émetteur émet une keyframe pour cette fenêtre
# (récepteur pas encore synchronisé, décodeur désynchronisé, config changée).
@rpc("any_peer", "call_remote", "reliable", 4)
func _video_need_keyframe(wid: int) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if _video_mode and compositor != null and compositor.has_method("video_share_request_keyframe"):
		compositor.video_share_request_keyframe(wid)

# ACK du récepteur : dernières seq appliquées par fenêtre (petits, fiables,
# canal 5 dédié comme l'ACK JPEG → pas de file derrière les gros RPC).
@rpc("any_peer", "call_remote", "reliable", 5)
func _ack_video_seq(seqs: Dictionary) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	var cur: Dictionary = _video_acked.get(from, {})
	for wid in seqs:
		var s := int(seqs[wid])
		if s > int(cur.get(wid, -1)):
			cur[wid] = s
	_video_acked[from] = cur

# Réception d'une frame vidéo : chunké ou non, on vérifie la séquence, on
# enfile le paquet pour le décodeur worker (qui applique ensuite la texture
# sur le quad distant via _drain_video_decoded).
# Une frame déjà appliquée (ou plus ancienne, reçue en retard via le canal 2
# après une keyframe du canal 4) ne doit jamais régresser l'affichage.
func _receive_video_frame(wid: int, seq: int, index: int, total: int, bytes: PackedByteArray, keyframe: bool) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if wid < 0 or seq < 0 or total < 1 or bytes.is_empty():
		return
	if compositor == null or not compositor.has_method("video_decoder_feed"):
		return
	if seq <= int(_video_applied.get(from, {}).get(wid, -1)):
		return
	var data := bytes
	if total > 1:
		data = _collect_video_chunk(from, wid, seq, index, total, bytes)
		if data.is_empty():
			return # assemblage incomplet
	if not _video_configs.get(from, {}).has(wid):
		# Course config/frame (canaux différents) : on ne peut pas décoder.
		_request_video_keyframe(from, wid)
		return
	# Décodage délégué au thread worker (cf. _video_decode_worker) : le thread
	# principal ne doit pas bloquer sur AVCodec + swscale à 60 ips. L'ACK de
	# la version appliquée est envoyé depuis _drain_video_decoded au prochain
	# tick (flow control de l'émetteur inchangé, juste un tick de plus).
	_start_video_decode_thread()
	_video_decode_mutex.lock()
	_video_decode_queue.append({"from": from, "wid": wid, "seq": seq, "keyframe": keyframe, "bytes": data})
	_video_decode_mutex.unlock()
	_video_decode_sem.post()

func _start_video_decode_thread() -> void:
	if _video_decode_thread != null:
		return
	_video_decode_stop = false
	_video_decode_thread = Thread.new()
	_video_decode_thread.start(_video_decode_worker)

func _video_decode_worker() -> void:
	while true:
		_video_decode_sem.wait()
		_video_decode_mutex.lock()
		var stopping := _video_decode_stop
		var job: Dictionary = _video_decode_queue.pop_front() if not _video_decode_queue.is_empty() else {}
		_video_decode_mutex.unlock()
		if stopping:
			return
		if job.is_empty():
			continue
		var from := int(job.get("from", -1))
		var wid := int(job.get("wid", -1))
		var seq := int(job.get("seq", -1))
		var keyframe := bool(job.get("keyframe", false))
		var img: Image = null
		if compositor != null and compositor.has_method("video_decoder_feed"):
			# video_decoder_feed est un appel GDExtension protégé par son
			# propre mutex C++ (dec_mutex) : appelable depuis un worker.
			img = compositor.video_decoder_feed(_video_key(from, wid),
				job.get("bytes", PackedByteArray()), keyframe)
		_video_decode_mutex.lock()
		_video_decode_results.append({
			"from": from, "wid": wid, "seq": seq, "keyframe": keyframe, "img": img,
		})
		_video_decode_mutex.unlock()

func _stop_video_decode_thread() -> void:
	if _video_decode_thread == null:
		return
	_video_decode_mutex.lock()
	_video_decode_stop = true
	_video_decode_queue.clear()
	_video_decode_results.clear()
	_video_decode_mutex.unlock()
	_video_decode_sem.post()
	_video_decode_thread.wait_to_finish()
	_video_decode_thread = null

# Applique les images décodées par le thread worker sur les quads distants
# (cadence du tick réseau), puis ACK les versions appliquées (flow control).
func _drain_video_decoded() -> void:
	_video_decode_mutex.lock()
	var results: Array = _video_decode_results
	_video_decode_results = []
	_video_decode_mutex.unlock()
	for result in results:
		var from := int(result.get("from", -1))
		var wid := int(result.get("wid", -1))
		var seq := int(result.get("seq", -1))
		var keyframe := bool(result.get("keyframe", false))
		var img: Image = result.get("img")
		if img == null or img.is_empty():
			# Décodeur désynchronisé (paquet corrompu, config change) : une
			# keyframe le resynchronisera. Throttlé (≤ 2×/s par fenêtre).
			if not keyframe:
				_request_video_keyframe(from, wid)
			continue
		# Une version déjà appliquée (ou plus ancienne, reçue en retard) ne
		# doit jamais régresser l'affichage.
		if seq <= int(_video_applied.get(from, {}).get(wid, -1)):
			continue
		if not _video_applied.has(from):
			_video_applied[from] = {}
		_video_applied[from][wid] = seq
		var tex: Texture2D = _make_or_update_remote_texture(from, wid, img)
		# Bufferiser la texture même si l'état `shared` n'est pas encore arrivé
		# (course 1re frame vs état) : _apply_remote_windows la réappliquera.
		if not _pending_remote_textures.has(from):
			_pending_remote_textures[from] = {}
		_pending_remote_textures[from][wid] = tex
		if _remote_window_quads.has(from) and _remote_window_quads[from].has(wid):
			_set_remote_quad_texture(_remote_window_quads[from][wid], tex)
		# ACK en lot (vidé par _flush_video_acks au prochain tick).
		if not _video_ack_pending.has(from):
			_video_ack_pending[from] = {}
		_video_ack_pending[from][wid] = seq
		_video_diag_applied += 1

# Accumule les morceaux d'un paquet chunké ; renvoie le paquet complet une
# fois tous les morceaux reçus (canal fiable → pas de perte, l'ordre intra-
# canal est garanti), sinon un buffer vide.
func _collect_video_chunk(from: int, wid: int, seq: int, index: int, total: int, bytes: PackedByteArray) -> PackedByteArray:
	if not _video_chunks.has(from):
		_video_chunks[from] = {}
	var per: Dictionary = _video_chunks[from]
	if not per.has(wid) or int(per[wid].get("seq", -1)) != seq:
		per[wid] = {"seq": seq, "total": total, "parts": {index: bytes}, "t": Time.get_ticks_msec()}
	else:
		per[wid]["t"] = Time.get_ticks_msec()
		(per[wid]["parts"] as Dictionary)[index] = bytes
	var entry: Dictionary = per[wid]
	if (entry["parts"] as Dictionary).size() < total:
		return PackedByteArray()
	var data := PackedByteArray()
	for i in total:
		data.append_array(entry["parts"][i])
	per.erase(wid)
	return data

# Purge les assemblages de chunks incomplets (la clé de déblocage est la
# keyframe suivante — l'assemblage en cours est périmé).
func _purge_video_chunks() -> void:
	if _video_chunks.is_empty():
		return
	var now := Time.get_ticks_msec()
	for from in _video_chunks.keys():
		var per: Dictionary = _video_chunks[from]
		for wid in per.keys():
			if now - int(per[wid].get("t", 0)) > VIDEO_CHUNK_STALE_MSEC:
				per.erase(wid)
		if per.is_empty():
			_video_chunks.erase(from)

func _flush_video_acks() -> void:
	if _video_ack_pending.is_empty():
		return
	for from in _video_ack_pending:
		if from in multiplayer.get_peers():
			_ack_video_seq.rpc_id(from, _video_ack_pending[from])
	_video_ack_pending.clear()

# Côté récepteur : maintenance du flux vidéo, exécutée chaque tick (indépen-
# damment du mode émetteur local). ACK en lot, purge des chunks, application
# des frames décodées par le worker, diagnostics.
func _process_video_receiver() -> void:
	_drain_video_decoded()
	_flush_video_acks()
	_purge_video_chunks()
	if Time.get_ticks_msec() - _video_diag_last_applied >= 1000:
		_video_diag_last_applied = Time.get_ticks_msec()
		if _video_diag_applied > 0:
			print("[video] diag rx: appliquées/s=%d" % _video_diag_applied)
		_video_diag_applied = 0

# Demande une keyframe à l'émetteur (décodeur désynchronisé, config manquante
# ou changée). Throttlé pour ne pas flooder (au plus 2×/s par fenêtre).
func _request_video_keyframe(from: int, wid: int) -> void:
	var now := Time.get_ticks_msec()
	if not _video_nack_last.has(from):
		_video_nack_last[from] = {}
	if now - int(_video_nack_last[from].get(wid, -999999)) < VIDEO_NACK_GAP_MSEC:
		return
	_video_nack_last[from][wid] = now
	if from in multiplayer.get_peers():
		_video_need_keyframe.rpc_id(from, wid)

# Libère le décodeur d'un flux distant (fenêtre non partagée / supprimée).
func _reset_video_stream(from: int, wid: int) -> void:
	if compositor != null and compositor.has_method("video_decoder_reset"):
		compositor.video_decoder_reset(_video_key(from, wid))
	if _video_configs.has(from):
		_video_configs[from].erase(wid)
	if _video_applied.has(from):
		_video_applied[from].erase(wid)
	if _video_chunks.has(from):
		_video_chunks[from].erase(wid)
	if _video_nack_last.has(from):
		_video_nack_last[from].erase(wid)

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
			# Métas pour le raycast (F/P, voir _raycast_window_target de
			# wayland_room.gd) et pour la mise à jour texture (pins/focus).
			quad.set_meta("remote_peer", peer_id)
			quad.set_meta("remote_wid", wid)
			var remote_body: StaticBody3D = quad.get_node_or_null("RemoteCollision") as StaticBody3D
			if remote_body != null:
				remote_body.set_meta("remote_window", {"peer_id": peer_id, "wid": wid})
		quad.global_transform = item.get("transform", Transform3D.IDENTITY)
		if quad.mesh is QuadMesh:
			(quad.mesh as QuadMesh).size = item.get("size", Vector2.ONE)
		_sync_remote_quad_collision(quad)
		quad.visible = bool(item.get("visible", true))
		var remote_body2: StaticBody3D = quad.get_node_or_null("RemoteCollision") as StaticBody3D
		if remote_body2 != null:
			remote_body2.disabled = not quad.visible
		# SHARE OFF : le quad redevient noir (placeholder) et le décodeur
		# vidéo du flux est libéré. SHARE ON : les frames streamées (rpc
		# _sync_window_texture / _sync_video_frame) textureront le quad.
		if not shared:
			_set_remote_quad_texture(quad, null)
			_reset_video_stream(peer_id, wid)
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
		if _remote_textures.has(peer_id):
			_remote_textures[peer_id].erase(wid)
		if pins != null:
			pins.unpin_remote(peer_id, wid)
		if focus != null:
			focus.handle_remote_window_removed(peer_id, wid)
	if quads.is_empty():
		_clear_remote_windows(peer_id)

# Quad représentant une fenêtre distante : noir tant que la fenêtre n'est pas
# partagée (SHARE OFF), texturé par le contenu réel quand les frames arrivent
# (SHARE ON). Unshaded, transparent, double face, sans ombre.
# Porte un corps de collision (meta "remote_window" posée par
# _apply_remote_windows) pour être visable au raycast F/P : vue seule, aucune
# interaction possible (aucun input n'est forwardé vers ces fenêtres).
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
	var body := StaticBody3D.new()
	body.name = "RemoteCollision"
	body.collision_layer = 2
	body.collision_mask = 2
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 1.0, 0.01)
	col.shape = shape
	body.add_child(col)
	quad.add_child(body)
	return quad

# Aligne la CollisionShape3D du quad distant sur la taille du mesh.
func _sync_remote_quad_collision(quad: MeshInstance3D) -> void:
	if quad == null or not is_instance_valid(quad):
		return
	var body: StaticBody3D = quad.get_node_or_null("RemoteCollision") as StaticBody3D
	if body == null:
		return
	var col: CollisionShape3D = body.get_child(0) as CollisionShape3D
	if col == null:
		return
	var shape: BoxShape3D = col.shape as BoxShape3D
	if shape != null and quad.mesh is QuadMesh:
		var s: Vector2 = (quad.mesh as QuadMesh).size
		shape.size = Vector3(s.x, s.y, 0.01)

# Pose/retire la texture du contenu réel sur le quad distant. Sans texture, le
# quad revient au noir (placeholder, SHARE OFF). Quand une texture est posée,
# on répercute aussi sur les PiP (pins) et l'overlay focus distant (vue seule).
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
		var peer: int = int(quad.get_meta("remote_peer", -1))
		var wid: int = int(quad.get_meta("remote_wid", -1))
		if peer >= 0 and wid >= 0:
			if pins != null:
				pins.on_remote_texture_updated(peer, wid, tex)
			if focus != null:
				focus.on_remote_texture_updated(peer, wid, tex)

# Renvoie la texture actuellement affichée sur un quad distant (null si la
# fenêtre n'est pas partagée / pas de frames reçues). Pour les PiP/overlays.
func get_remote_window_texture(peer_id: int, wid: int) -> Texture2D:
	if _remote_window_quads.has(peer_id) and _remote_window_quads[peer_id].has(wid):
		var quad: MeshInstance3D = _remote_window_quads[peer_id][wid]
		if is_instance_valid(quad):
			var mat: StandardMaterial3D = quad.material_override
			if mat != null and mat.albedo_texture != null:
				return mat.albedo_texture
	return null

# Réutilise l'ImageTexture de la fenêtre distante (update en place) quand la
# taille/format ne change pas, sinon en crée une nouvelle. Évite d'allouer une
# texture GPU + upload complet à CHAQUE frame décodée (30/s pour une vidéo) :
# le churn GPU est la cause principale de la saccade de la vidéo distante.
func _make_or_update_remote_texture(from: int, wid: int, img: Image) -> Texture2D:
	if img == null or img.is_empty():
		return null
	var tex: ImageTexture = _remote_textures.get(from, {}).get(wid, null)
	if tex == null or not is_instance_valid(tex) \
			or tex.get_width() != img.get_width() or tex.get_height() != img.get_height() \
			or tex.get_format() != img.get_format():
		tex = ImageTexture.create_from_image(img)
		if not _remote_textures.has(from):
			_remote_textures[from] = {}
		_remote_textures[from][wid] = tex
	else:
		tex.update(img)
	return tex

func _clear_remote_windows(peer_id: int) -> void:
	var container: Node3D = _remote_windows.get(peer_id)
	if container != null and is_instance_valid(container):
		container.queue_free()
	_remote_windows.erase(peer_id)
	_remote_window_quads.erase(peer_id)
	_remote_shared.erase(peer_id)
	_pending_remote_textures.erase(peer_id)
	_remote_textures.erase(peer_id)
	_last_applied_version.erase(peer_id)
	# Libère les décodeurs vidéo des flux de ce peer.
	if compositor != null and compositor.has_method("video_decoder_reset"):
		if _video_configs.has(peer_id):
			for wid in _video_configs[peer_id]:
				compositor.video_decoder_reset(_video_key(peer_id, wid))
	_video_configs.erase(peer_id)
	_video_applied.erase(peer_id)
	_video_chunks.erase(peer_id)
	_video_nack_last.erase(peer_id)
	_video_ack_pending.erase(peer_id)
	if pins != null:
		pins.unpin_peer(peer_id)
	if focus != null:
		focus.handle_peer_removed(peer_id)

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
	_stop_video_decode_thread()
	_stop_audio_share()
	_stop_video_share()
	if compositor != null and compositor.has_method("video_decoder_clear_all"):
		compositor.video_decoder_clear_all()
	_video_configs.clear()
	_video_applied.clear()
	_video_chunks.clear()
	_video_nack_last.clear()
	_video_ack_pending.clear()
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
	_stop_video_decode_thread()
	_stop_audio_share()
	_stop_video_share()
	if compositor != null and compositor.has_method("video_decoder_clear_all"):
		compositor.video_decoder_clear_all()
	_stop_responder()
	if _scanner:
		_scanner.close()
		_scanner = null
	_clear_all_remote_windows()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
