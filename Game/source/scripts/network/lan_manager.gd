class_name LanManager
extends Node
## Multijoueur LAN : l'hôte est le serveur (autorité pour le spawn/despawn
## des avatars), chaque joueur diffuse sa propre transformation par RPC
## unreliable. Les fenêtres/compositeur restent locaux à chaque machine —
## seuls les avatars des autres joueurs sont visibles.

signal status_changed(text: String)
signal players_changed(roster: Array)
signal discovery_results(results: Array)
signal level_apply_requested(scene: PackedScene, spawn: Vector3, spawn_rotation: Vector3, spawn_scale: Vector3)
# Déconnexion d'une session : le client doit retrouver SON niveau personnel
# (wayland_room filtre : no-op si aucun niveau hôte n'avait été appliqué).
signal local_level_restore_requested
# Début / fin de session (hôte ou client). status_changed ne suffit pas : à la
# déconnexion, le dernier statut est émis AVANT que session_active repasse à
# false (ou pas du tout quand on quitte soi-même).
signal session_state_changed(active: bool)
# Émis quand le PIN de session est généré (hôte) ou reçu (client).
signal pin_changed(pin: String)

const PORT := 7777
const DISCOVERY_PORT := 9999
const MAX_PLAYERS := 4

# ── Transfert du niveau de l'hôte (maps custom jouables en LAN) ──────
# L'hôte bake son niveau (LevelBaker) en un blob binaire auto-suffisant
# (assets embarqués → pas besoin de builds identiques), le compresse en ZSTD
# puis l'envoie en chunks fiables (canal 0). Un chunk ≤ 24 Ko reste dans une
# vague ENet (32 fragments ≈ 44 KB) sans retomber en 2-3 vagues d'ACK.
# Port TCP du canal dédié au niveau (voir level_tcp.gd) : le blob ne passe plus
# par ENet, seul le jeton d'accès transite par le RPC (chiffré en DTLS).
const LEVEL_TCP_PORT := 7778
# PIN de la session LAN (4 chiffres). L'hôte le génère, les clients le saisissent.
var _pin: String = ""
# Serveur dédié (headless, sans joueur) : l'hôte n'est PAS un joueur — ni roster, ni avatar, ni synchro de transform ;
# il porte le niveau (blob prébaké), le PIN et le relais. Voir scripts/server/dedicated_server.gd.
var dedicated := false
## MODE ONLINE (serveur dédié exposé sur Internet). Durcit tout : certificat TLS réel (--tls-cert/--tls-key, p. ex.
## Let's Encrypt) au lieu de la clé embarquée ; authentification par mot de passe au niveau MOTEUR (aucun RPC n'est
## accepté d'un pair non authentifié) avec verrouillage progressif par IP ; pas de découverte UDP ; scripts d'avatar
## refusés ; partage de fenêtres/audio/vidéo/fichiers coupé ; intégrité du niveau vérifiée (SHA-256).
var online := false
var tls_cert_path := ""
var tls_key_path := ""
## Client : session « en ligne » (hôte joint par NOM, certificat vérifié, authentification moteur). Mêmes restrictions.
var session_online := false
## Client : la session a un serveur dédié (renseigné par le serveur à l'inscription). Le décor physique est alors
## simulé par le SERVEUR (autorité) ; le client n'envoie que des demandes (toucher, prendre, lancer…).
var session_dedicated := false
var forced_pin := ""                 # PIN imposé (sinon tiré au sort)
var max_players := MAX_PLAYERS
# Chiffrement DTLS de la session (toggle pause_menu). Exposé en var publique.
var encryption_enabled := true
# Annonce (registration + avatar) déjà envoyée à l'hôte : partagée entre le
# chemin nominal (dès la connexion, pour paralléliser l'échange d'avatars
# avec le téléchargement du niveau) et les chemins de secours (_finalize_join).
var _announced := false

static var session_active := false
var is_host := false
var session_encrypted := false
var player_name := ""
var player_color := Color(0.2, 0.6, 1.0)
var level_bake_provider: Callable = Callable() # host : renvoie le blob baked du niveau {bytes, spawn}
var windows_provider: Callable = Callable() # renvoie la liste des fenêtres locales (world)
var windows_moving_provider: Callable = Callable() # true si le joueur déplace/redimensionne une fenêtre
var window_image_provider: Callable = Callable() # Callable(window_id) -> Image (contenu réel, stream partage)
var window_version_provider: Callable = Callable() # Callable(window_id) -> int (version du contenu)
var compositor: Node = null # WlrCompositor (typé Node : le serveur dédié tourne SANS l'extension) pour start/stop_audio_share, poll_audio_packet, audio_decode
# Références vers les sous-systèmes locaux (posées par wayland_room) : mise à
# jour des PiP / overlays focus des fenêtres distantes (vue seule).
var pins = null
var focus = null
# Joueur local (posé par wayland_room) : transmis aux avatars distants pour la
# transparence de proximité (fondus sous 1 m).
var local_player: CharacterBody3D = null

var _level_root: Node3D = null
var _players_container: Node3D = null
var _players: Dictionary = {}       # peer_id -> nom
static var _remote_players: Dictionary = {} # peer_id -> Node (avatar)
var _last_status := ""
# Les avatars ne sont préchauffés (GPU, hors viewport principal) qu'une fois
# le niveau stable : le chargement du niveau compile ses propres shaders, et
# un prewarm + le 1er rendu de l'avatar simultanés font perdre le device
# Vulkan (TDR) combinés aux captures Wayland. Faux au démarrage d'une session,
# vrai une fois le niveau local appliqué/chargé.
var _level_stable := false
var _session_start_msec := 0 # filet de sécurité : si le niveau n'arrive jamais
# Client : vrai entre la connexion ENet et l'entrée EFFECTIVE dans la session.
# Le joueur charge d'abord la map de l'hôte (chunks fiables) : tant que
# _pending_join est vrai, il n'est pas enregistré auprès de l'hôte (aucun
# avatar chez les autres), ne reçoit pas les spawns et n'émet AUCUNE synchro
# (transform/fenêtres/curseur). Le join part à la fin du chargement
# (_finalize_join) ou après JOIN_FALLBACK_MSEC sans aucun chunk reçu.
var _pending_join := false
const JOIN_FALLBACK_MSEC := 15000
var _last_level_chunk_msec := 0 # dernier chunk de niveau reçu (client)

# ── Modules (nœuds enfants, créés dans _init : mêmes chemins de RPC chez le serveur et les clients) ──
const SessionModule := preload("res://scripts/network/lan/session.gd")
const PlayersModule := preload("res://scripts/network/lan/players.gd")
const LevelTransferModule := preload("res://scripts/network/lan/level_transfer.gd")
const WindowShareModule := preload("res://scripts/network/lan/window_share.gd")
const VideoShareModule := preload("res://scripts/network/lan/video_share.gd")
const AudioShareModule := preload("res://scripts/network/lan/audio_share.gd")
const DiscoveryModule := preload("res://scripts/network/lan/discovery.gd")
const LevelSyncModule := preload("res://scripts/network/lan/level_sync.gd")
const ChatModule := preload("res://scripts/network/lan/chat.gd")
const VoiceModule := preload("res://scripts/network/lan/voice.gd")
var session: SessionModule = null
var players: PlayersModule = null
var level_transfer: LevelTransferModule = null
var window_share: WindowShareModule = null
var video_share: VideoShareModule = null
var audio_share: AudioShareModule = null
var discovery: DiscoveryModule = null
var level_sync: LevelSyncModule = null
var chat: ChatModule = null
var voice: VoiceModule = null

func _init() -> void:
	session = SessionModule.new()
	session.name = "Session"
	session.lan = self
	add_child(session)
	players = PlayersModule.new()
	players.name = "Players"
	players.lan = self
	add_child(players)
	level_transfer = LevelTransferModule.new()
	level_transfer.name = "LevelTransfer"
	level_transfer.lan = self
	add_child(level_transfer)
	window_share = WindowShareModule.new()
	window_share.name = "WindowShare"
	window_share.lan = self
	add_child(window_share)
	video_share = VideoShareModule.new()
	video_share.name = "VideoShare"
	video_share.lan = self
	add_child(video_share)
	audio_share = AudioShareModule.new()
	audio_share.name = "AudioShare"
	audio_share.lan = self
	add_child(audio_share)
	discovery = DiscoveryModule.new()
	discovery.name = "Discovery"
	discovery.lan = self
	add_child(discovery)
	level_sync = LevelSyncModule.new()
	level_sync.name = "LevelSync"
	level_sync.lan = self
	add_child(level_sync)
	chat = ChatModule.new()
	chat.name = "Chat"
	chat.lan = self
	add_child(chat)
	voice = VoiceModule.new()
	voice.name = "Voice"
	voice.lan = self
	add_child(voice)
# Journal protocole (user://lan_debug.log) : diagnostic du join LAN.
func _lan_log(msg: String, reset := false) -> void:
	push_warning("LAN: " + msg)
	if reset:
		var f0 := FileAccess.open("user://lan_debug.log", FileAccess.WRITE)
		if f0 != null:
			f0.close()
			return
	var f := FileAccess.open("user://lan_debug.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://lan_debug.log", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("[%9.3f] %s" % [Time.get_ticks_msec() / 1000.0, msg])
		f.close()

func setup(level_root: Node3D, name: String, color: Color) -> void:
	_level_root = level_root
	player_name = name
	player_color = color
	# Charger la scène avatar custom si elle existe, sinon le défaut.
	if ResourceLoader.exists(PlayersModule.CUSTOM_AVATAR_PATH):
		players._avatar_scene = load(PlayersModule.CUSTOM_AVATAR_PATH)
	else:
		players._avatar_scene = load(PlayersModule.DEFAULT_AVATAR_PATH)
	_players_container = Node3D.new()
	_players_container.name = "Players"
	_players_parent(_level_root).add_child(_players_container)
	# Quads noirs des fenêtres des autres joueurs : dans l'espace monde, à
	# l'identité sous ce node (le LAN est enfant de la room), PAS sous le
	# niveau (dont la racine est rotée/décalée) — cohérent avec les fenêtres
	# locales qui vivent dans le monde.
	window_share._remote_windows_root = Node3D.new()
	window_share._remote_windows_root.name = "RemoteWindows"
	add_child(window_share._remote_windows_root)

func _generate_pin() -> String:
	return "%04d" % (randi() % 10000)

func get_pin() -> String:
	return _pin

static func is_session_active() -> bool:
	return session_active

# Client : vrai pendant le chargement de la map de l'hôte (avant le join
# effectif). wayland_room s'en sert pour geler le joueur local.
func is_waiting_for_host_map() -> bool:
	return _pending_join

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

## Conteneur des avatars distants (niveau courant) — utilisé par le partage
## de fichiers pour résoudre la cible d'un drop.
func get_players_container() -> Node3D:
	return _players_container


## Carte peer_id → nœud avatar (résolution par identité : les noms de nœuds
## ne sont pas fiables — Godot les renomme en cas de collision, et un nom
## auto-généré « @Node3D@N » casserait toute analyse par int(name)).
static func get_remote_players() -> Dictionary:
	return _remote_players

func disconnect_session() -> void:
	# Hôte : notifier proprement les clients avant de couper (pas de reconnexion).
	if is_host and session_active and multiplayer.multiplayer_peer != null:
		session.session_closed.rpc()
	_disconnect_session()

# L'id local n'existe que via multiplayer, absent hors arbre (tests/setup).
func _local_peer_id() -> int:
	var m = multiplayer
	return m.get_unique_id() if m != null else 0

# Appelé par wayland_room après avoir remplacé le niveau : bascule la racine
# et déplace les avatars distants vers un nouveau conteneur (l'ancien niveau
# est sur le point d'être libéré).
func on_level_swapped(new_level_root: Node3D) -> void:
	level_transfer._invalidate_level_send_cache()
	_level_root = new_level_root
	_players_container = Node3D.new()
	_players_container.name = "Players"
	_players_parent(new_level_root).add_child(_players_container)
	for id in _remote_players:
		var av: Node = _remote_players[id]
		if not is_instance_valid(av):
			_remote_players.erase(id)
			players._arrived_peers.erase(id)
			continue
		var p: Node = av.get_parent()
		if p and p != _players_container:
			p.remove_child(av)
		_players_container.add_child(av)
		# Les avatars déjà présents ont été spawnés selon la scène locale
		# d'origine (le blob de l'hôte n'était pas encore appliqué) : recaler
		# scale/rotation sur le spawn de l'hôte. La position est resynchronisée
		# par _sync_player_transform, mais le scale n'est jamais re-synchronisé.
		if not level_transfer._host_spawn_transform.is_empty():
			av.rotation = _spawn_rotation()
			av.scale = _spawn_scale()
	level_sync._refresh_level_sync()

func _has_streaming_window() -> bool:
	if not windows_provider.is_valid():
		return false
	for item in windows_provider.call():
		if item is Dictionary \
				and bool(item.get("shared", false)) \
				and bool(item.get("visible", true)):
			return true
	return false

# Le transform de spawn des avatars distants vient de la scène de l'HÔTE
# (importée via le blob — le Player en est exclu), pas de la scène locale
# d'origine. Sur le client, _level_root pointe d'abord vers le niveau local
# puis vers le niveau importé dont le Player est le joueur local réutilisé :
# aucun des deux ne porte le vrai spawn de l'hôte → on utilise le transform
# transmis dans le blob quand il est connu, sinon le Player local (hôte).
func _spawn_position() -> Vector3:
	if not level_transfer._host_spawn_transform.is_empty():
		return level_transfer._host_spawn_transform.get("pos", Vector3.ZERO)
	var player := _find_local_player() as Node3D
	return player.position if player != null else Vector3.ZERO

func _spawn_rotation() -> Vector3:
	if not level_transfer._host_spawn_transform.is_empty():
		return level_transfer._host_spawn_transform.get("rot", Vector3.ZERO)
	var player := _find_local_player() as Node3D
	return player.rotation if player != null else Vector3.ZERO

func _spawn_scale() -> Vector3:
	if not level_transfer._host_spawn_transform.is_empty():
		return level_transfer._host_spawn_transform.get("scale", Vector3.ONE)
	var player := _find_local_player() as Node3D
	return player.scale if player != null else Vector3.ONE

func _physics_process(delta: float) -> void:
	window_share._update_cpu_capture_request()
	level_transfer._drain_level_send()
	players._drain_avatar_send()
	# Applique les décodages threadés (niveau + avatars) dès qu'ils sont prêts.
	# Placé AVANT l'early return session : l'avance du join ne doit jamais
	# attendre un poll conditionné à un état qui dépend lui-même du décodage.
	level_transfer._poll_pending_scene_loads()
	if not session_active or _level_root == null:
		return
	# Filet de sécurité join : si le niveau de l'hôte n'arrive jamais (bake
	# impossible, transfert mort), entrer quand même dans la session après un
	# délai SANS AUCUN chunk reçu — on jouera sur la map locale. Un transfert
	# lent mais vivant (chunks réguliers) ne déclenche pas ce fallback.
	if _pending_join and _last_level_chunk_msec > 0 \
			and Time.get_ticks_msec() - _last_level_chunk_msec > JOIN_FALLBACK_MSEC:
		push_warning("LAN: host level never received — forced join on local map")
		session._finalize_join()
	# Filet de sécurité avatars : session rejointe mais niveau toujours pas
	# stable → préchauffer quand même (le niveau local est déjà stable).
	elif not _level_stable and _session_start_msec > 0 \
			and Time.get_ticks_msec() - _session_start_msec > 10000:
		players.mark_level_stable()
	# Niveau différé en attente des avatars : timeout de sécurité.
	level_transfer._maybe_flush_deferred_level()
	if multiplayer.get_peers().is_empty():
		return
	# Map de l'hôte encore en cours de réception : n'émettre aucune synchro —
	# le joueur local n'est pas encore entré dans la session.
	if _pending_join:
		return
	level_sync._sync_level_state(delta)
	var player := _find_local_player() as Node3D
	if player == null:
		return
	var camera := player.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	players._sync_player_transform.rpc(player.position, player.rotation.y, camera.rotation.x)
	window_share._sync_windows_state(delta)
	window_share._sync_windows_textures(delta)
	video_share._sync_video_state()
	window_share._drain_encoded_frames()
	video_share._drain_video_packets()
	video_share._process_video_receiver()
	audio_share._sync_audio_state()
	window_share._drain_decoded_frames()

func _process(_delta: float) -> void:
	if discovery._responder:
		discovery._poll_responder()
	if discovery._scanner:
		discovery._poll_scanner()
	window_share._sync_cursor_state(_delta)
	# Timeout client : si le PIN n'est pas vérifié à temps, déconnexion.
	if not is_host and session._auth_request_sent_msec > 0 and session_active:
		if Time.get_ticks_msec() - session._auth_request_sent_msec > SessionModule.AUTH_TIMEOUT_MSEC:
			_lan_log("auth timeout — no response from host")
			_set_status("Authentication timeout — host did not respond")
			_disconnect_session()
	# Heartbeat : l'hôte émet périodiquement, le client surveille le timeout.
	if session_active and multiplayer.multiplayer_peer != null:
		var now := Time.get_ticks_msec()
		if is_host:
			if now - session._last_heartbeat_sent_msec >= SessionModule.HEARTBEAT_INTERVAL_MSEC:
				# Émission en retard > 2× l'intervalle (T6). Ce bloc ne
				# s'exécute qu'une fois par intervalle (pas toutes les
				# frames) et la mise à jour juste après réinitialise
				# l'écart → un log par franchissement. Garde > 0 : la 1re
				# émission d'une session part de 0 (remis à zéro dans
				# host_game) et l'écart depuis le démarrage de
				# l'application serait un faux positif.
				var late := now - session._last_heartbeat_sent_msec
				if session._last_heartbeat_sent_msec > 0 and late > 2 * SessionModule.HEARTBEAT_INTERVAL_MSEC:
					_lan_log("heartbeat late by %d ms" % late)
				session._last_heartbeat_sent_msec = now
				session._host_heartbeat.rpc()
		elif not is_host and SessionModule.heartbeat_reconnect_should_arm(not _pending_join, session._last_heartbeat_msec, now, SessionModule.HOST_HEARTBEAT_TIMEOUT_MSEC, _last_level_chunk_msec):
			session._on_host_heartbeat_timeout()

# ── Helpers ──────────────────────────────────────────────────────────

func _local_ips() -> Array:
	# Les adresses des interfaces virtuelles (pont Docker 172.17.0.1, libvirt, veth…) passent EN DERNIER : un serveur
	# qui héberge des conteneurs affichait l'adresse du pont comme « son » IP, injoignable depuis le réseau.
	var real: Array = []
	var virtual: Array = []
	for itf in IP.get_local_interfaces():
		var nm := String(itf.get("name", ""))
		var is_virtual := false
		for prefix in ["docker", "br-", "veth", "virbr", "lxc", "lxd", "cni", "flannel", "podman"]:
			if nm.begins_with(prefix):
				is_virtual = true
				break
		for ip in itf.get("addresses", []):
			var a := String(ip)
			if a.begins_with("127.") or a.begins_with("169.254.") or ":" in a:
				continue
			(virtual if is_virtual else real).append(a)
	real.append_array(virtual)
	if real.is_empty():
		real.append("127.0.0.1")
	return real

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
	players._arrived_peers.clear()

func _disconnect_session(keep_context := false) -> void:
	audio_share._stop_audio_share()
	video_share._stop_video_share()
	session._pending_auth.clear()
	session._auth_request_sent_msec = 0
	_pin = ""
	# Canal TCP du niveau : threads joints AVANT de lâcher le cache/le peer.
	level_transfer._stop_level_tcp()
	# Différé de niveau : état borné à la session — sans ça, la reprise en
	# tête de _drain_level_send ré-enverrait des ids morts/recyclés au
	# prochain hébergement.
	level_transfer._defer_level_send.clear()
	level_transfer._level_send_deferred = false
	# Décodage du niveau encore en vol (déconnexion pendant la décompression) :
	# attendre la fin de la tâche, puis vider la file des résultats — un
	# résultat orphelin ne doit jamais arriver dans la session suivante.
	if level_transfer._level_decode_task >= 0:
		WorkerThreadPool.wait_for_task_completion(level_transfer._level_decode_task)
		level_transfer._level_decode_task = -1
	level_transfer._level_decode_mutex.lock()
	level_transfer._level_decode_results.clear()
	level_transfer._level_decode_mutex.unlock()
	level_transfer._invalidate_level_send_cache()
	level_transfer._host_spawn_transform.clear()
	players._avatar_send_queue.clear()
	players._avatar_receive_slots.clear()
	if compositor != null and compositor.has_method("video_decoder_clear_all"):
		compositor.video_decoder_clear_all()
	video_share._video_configs.clear()
	video_share._video_applied.clear()
	video_share._video_chunks.clear()
	video_share._video_nack_last.clear()
	video_share._video_ack_pending.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		# Retour à l'état « hors ligne » PAR DÉFAUT du moteur (OfflineMultiplayerPeer : is_server() = true, id 1). Avec
		# null, is_server() devenait false et get_unique_id() 0 : le joueur solo n'était plus « l'hôte » de son propre
		# niveau (options du niveau verrouillées après une déconnexion).
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_clear_remote_players()
	window_share._clear_all_remote_windows()
	window_share._last_texture_versions.clear()
	discovery._stop_responder()
	if discovery._scanner:
		# Invalider la coroutine discover_games() en attente AVANT de fermer :
		# à son réveil elle verra une génération périmée et n'utilisera pas ce
		# peer (set_dest_address sur un PacketPeerUDP fermé/null = crash).
		discovery._scan_generation += 1
		discovery._scanner.close()
		discovery._scanner = null
		discovery._scanning = false
		discovery._scan_results.clear()
	if multiplayer.peer_connected.is_connected(session._on_peer_connected):
		multiplayer.peer_connected.disconnect(session._on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(session._on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(session._on_peer_disconnected)
	if multiplayer.connected_to_server.is_connected(session._on_connected_to_server):
		multiplayer.connected_to_server.disconnect(session._on_connected_to_server)
	if multiplayer.connection_failed.is_connected(session._on_connection_failed):
		multiplayer.connection_failed.disconnect(session._on_connection_failed)
	if multiplayer.server_disconnected.is_connected(session._on_server_disconnected):
		multiplayer.server_disconnected.disconnect(session._on_server_disconnected)
	session_dedicated = false
	session_online = false
	session._auth_sent = false
	session._teardown_engine_auth()
	if session.admin:
		session.admin = false
		admin_changed.emit(false)
	session._admins.clear()
	session._admin_fails.clear()
	session_active = false
	is_host = false
	session_encrypted = false
	session_state_changed.emit(false)
	_announced = false
	players._avatar_sent_to.clear()
	players._avatar_send_cache = PackedByteArray()
	players._avatar_send_cache_raw_size = 0
	players._avatar_send_scripts_cache = {}
	# Annuler un join en attente (déconnexion pendant le chargement de la
	# map) et dégeler le joueur local.
	_pending_join = false
	if local_player != null and "input_locked" in local_player:
		local_player.input_locked = false
	_players.clear()
	players._avatar_blobs.clear()
	players._avatar_scene_cache.clear()
	level_transfer._deferred_level.clear()
	_emit_players()
	# Dernier, une fois les avatars distants libérés et l'état réinitialisé :
	# la restauration recrée le conteneur Players sous le niveau personnel via
	# on_level_swapped(). Sautée en reconnexion (on va rejoindre à nouveau).
	if not keep_context:
		local_level_restore_requested.emit()

func _exit_tree() -> void:
	level_transfer._stop_level_tcp()
	window_share._stop_encode_thread()
	window_share._stop_decode_thread()
	# Décodage du niveau encore en vol à la fermeture : aucun chemin (ni le
	# disconnect, ni la fermeture du peer) n'atteint l'attente de
	# _disconnect_session ici → sans cette jointure, la destruction de l'objet
	# libérerait le mutex/la file pendant que le worker les écrit (UAF).
	if level_transfer._level_decode_task >= 0:
		WorkerThreadPool.wait_for_task_completion(level_transfer._level_decode_task)
	level_transfer._level_decode_task = -1
	level_transfer._level_decode_mutex.lock()
	level_transfer._level_decode_results.clear()
	level_transfer._level_decode_mutex.unlock()
	audio_share._stop_audio_share()
	video_share._stop_video_share()
	if compositor != null and compositor.has_method("video_decoder_clear_all"):
		compositor.video_decoder_clear_all()
	discovery._stop_responder()
	if discovery._scanner:
		discovery._scanner.close()
		discovery._scanner = null
	window_share._clear_all_remote_windows()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()

# ── Messages de niveau (scripts du niveau <-> serveur) ───────────────
# Canal générique pour la logique d'un niveau sous autorité serveur (ex. physique du décor) : un client envoie une
# demande au serveur, le serveur diffuse le résultat. Les scripts du niveau écoutent `level_message`.
signal level_message(topic: String, data: Variant, from_peer: int)
signal level_peer_left(peer: int)       # serveur : un client est parti (libérer ses objets en main…)

func in_dedicated_session() -> bool:
	return dedicated or session_dedicated

## true en mode online (serveur ou client) : fonctions entre joueurs coupées (fenêtres, audio, vidéo, fichiers).
func online_restricted() -> bool:
	return online or session_online

# ── Administrateur (serveur dédié) ───────────────────────────────────
# Sur un serveur dédié personne n'est « l'hôte » : un joueur devient ADMIN en donnant le mot de passe du serveur
# (--admin-password / CYBERREALM_ADMIN_PASSWORD). Les scripts de niveau interrogent is_admin() pour réserver des
# réglages (ex. options du niveau) à ce joueur. Hors serveur dédié, l'hôte LAN est toujours admin de sa session.
signal admin_changed(is_admin: bool)       # client : mon statut d'admin a changé
var admin_password := ""                   # serveur : vide = pas d'admin possible

func _find_local_player() -> Node3D:
	if is_instance_valid(local_player):
		return local_player
	if _level_root == null:
		return null
	return _level_root.find_child("Player", true, false) as Node3D

func _players_parent(level_root: Node) -> Node:
	var p := _find_local_player()
	return p.get_parent() if p != null and p.get_parent() != null else level_root

# ── Relais vers les modules (API publique inchangée) ─────────────────

func update_local_color(color: Color) -> void:
	players.update_local_color(color)

func update_local_name(pname: String) -> void:
	players.update_local_name(pname)

func update_local_avatar() -> void:
	players.update_local_avatar()

func set_selected_avatar(path: String) -> void:
	players.set_selected_avatar(path)

func spawn_freecam_avatar(player: Node3D) -> Node:
	return players.spawn_freecam_avatar(player)

func mark_level_stable() -> void:
	players.mark_level_stable()

static func list_avatars() -> Array[Dictionary]:
	return PlayersModule.list_avatars()

static func avatar_scene_safe(scene: PackedScene) -> bool:
	return SessionModule.avatar_scene_safe(scene)

func set_cpu_capture_consumer(key: String, active: bool) -> void:
	window_share.set_cpu_capture_consumer(key, active)

func request_windows_sync() -> void:
	window_share.request_windows_sync()

func get_remote_window_texture(peer_id: int, wid: int) -> Texture2D:
	return window_share.get_remote_window_texture(peer_id, wid)

func set_video_settings(bitrate: int, codec: String, fps: int) -> void:
	video_share.set_video_settings(bitrate, codec, fps)

func discover_games() -> void:
	discovery.discover_games()

func is_admin(peer: int = 0) -> bool:
	return session.is_admin(peer)

func request_admin(password: String) -> void:
	session.request_admin(password)

func send_level_message(topic: String, data: Variant = null, reliable := true) -> void:
	level_sync.send_level_message(topic, data, reliable)

func broadcast_level_message(topic: String, data: Variant = null, reliable := true) -> void:
	level_sync.broadcast_level_message(topic, data, reliable)

func send_level_message_to(peer: int, topic: String, data: Variant = null) -> void:
	level_sync.send_level_message_to(peer, topic, data)

func register_level_sync(n: Node3D) -> void:
	level_sync.register_level_sync(n)

func unregister_level_sync(n: Node3D) -> void:
	level_sync.unregister_level_sync(n)

func host_game() -> bool:
	return session.host_game()

func join_game(ip: String, pin: String = "", encrypted: bool = false) -> bool:
	return session.join_game(ip, pin, encrypted)
