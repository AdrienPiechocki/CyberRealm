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
# Émis quand le PIN de session est généré (hôte) ou reçu (client).
signal pin_changed(pin: String)

const PORT := 7777
const DISCOVERY_PORT := 9999
const MAX_PLAYERS := 4
const DISCOVERY_TIMEOUT := 1.6
const DISCOVERY_RETRY_INTERVAL := 0.4
const DISCOVERY_QUERY := "CYBERREALM_DISCOVER"

# ── Transfert du niveau de l'hôte (maps custom jouables en LAN) ──────
# L'hôte bake son niveau (LevelBaker) en un blob binaire auto-suffisant
# (assets embarqués → pas besoin de builds identiques), le compresse en ZSTD
# puis l'envoie en chunks fiables (canal 0). Un chunk ≤ 24 Ko reste dans une
# vague ENet (32 fragments ≈ 44 KB) sans retomber en 2-3 vagues d'ACK.
const LEVEL_CHUNK_SIZE := 24000
const LEVEL_CHUNKS_PER_TICK := 24

const CUSTOM_AVATAR_PATH := "res://user/avatar.tscn"
const DEFAULT_AVATAR_PATH := "res://scenes/avatar.tscn"

var _avatar_scene: PackedScene = null
var _avatar_blobs: Dictionary = {} # peer_id -> PackedByteArray (scène binaire)
# PIN de la session LAN (4 chiffres). L'hôte le génère, les clients le saisissent.
var _pin: String = ""
# peer_id -> true : client en attente de vérification du PIN par l'hôte.
var _pending_auth: Dictionary = {}
# Chiffrement DTLS de la session (toggle pause_menu). Exposé en var publique.
var encryption_enabled := true
# anti brute-force PIN : adresse IP -> timestamp (ms) du dernier échec (purge).
var _pin_blacklist: Dictionary = {}
# Compteur d'échecs PIN consécutifs par adresse (alimenté par pin_attempt).
var _pin_fail_counts: Dictionary = {}
# Chiffrement demandé pour le dernier join (réutilisé à la reconnexion).
var _last_join_encrypted := false
# Timeout de vérification PIN côté client (ms). Si l'hôte ne répond pas, déconnexion.
const AUTH_TIMEOUT_MSEC := 10000

# ── Reconnexion & anti brute-force PIN (B2) ──────────────────────────
const RECONNECT_WINDOW_MSEC := 30000
const RECONNECT_MAX_ATTEMPTS := 12
const HEARTBEAT_INTERVAL_MSEC := 1000
const HOST_HEARTBEAT_TIMEOUT_MSEC := 4000
const PIN_FAIL_LIMIT := 3
const PIN_BLACKLIST_MSEC := 30000

## Délai d'attente (secondes) avant la tentative de reconnexion n°attempt.
static func backoff_delay(attempt: int) -> float:
	var base := 0.5 * pow(2.0, float(attempt))
	var jitter := randf_range(-0.3, 0.3) * base
	return clampf(base + jitter, 0.0, 2.5)

## Décide si une reconnexion est encore pertinente. `closed` = on a reçu
## session_closed (l'hôte a fermé proprement → pas de reconnect). `attempts`
## = nombre de tentatives déjà effectuées. `window` = fenêtre de tolérance.
static func should_reconnect(last_hb: int, now: int, closed: bool, window: int, attempts: int) -> bool:
	if closed or attempts >= RECONNECT_MAX_ATTEMPTS:
		return false
	if attempts == 0:
		return true
	return (now - last_hb) <= window

## Enregistre une tentative de PIN. Retourne true si l'adresse doit être
## rejetée (≥ PIN_FAIL_LIMIT échecs consécutifs). Un succès (ok=true) réarme.
## `state` est une Dictionary externe (testable) : addr -> nb échecs consécutifs.
static func pin_attempt(addr: String, ok: bool, state: Dictionary) -> bool:
	if ok:
		state.erase(addr)
		return false
	var fails: int = int(state.get(addr, 0)) + 1
	state[addr] = fails
	return fails >= PIN_FAIL_LIMIT
# Timestamp (ms) de l'envoi de la requête auth par le client.
var _auth_request_sent_msec := 0
# Scènes avatar décodées à l'avance : peer_id -> PackedScene. Le coût du
# load() (parse + ressources embarquées des avatars lourds, plusieurs
# secondes) est payé dès l'arrivée du blob — idéalement pendant l'écran de
# chargement — et non au spawn, où il faisait surgir l'avatar en retard.
var _avatar_scene_cache: Dictionary = {}
# Niveau client reçu mais pas encore appliqué : retenu tant que les blobs
# d'avatars attendus ne sont pas arrivés, pour que tous les avatars
# apparaissent EN MÊME TEMPS que le niveau (et pas après). Timeout inclus :
# un pair muet ne bloque jamais l'entrée en session au-delà du délai.
var _deferred_level: Dictionary = {} # {scene, pos, rot, scl, waiting, deadline}
const AVATAR_LEVEL_WAIT_TIMEOUT_MSEC := 8000
# Annonce (registration + avatar) déjà envoyée à l'hôte : partagée entre le
# chemin nominal (dès la connexion, pour paralléliser l'échange d'avatars
# avec le téléchargement du niveau) et les chemins de secours (_finalize_join).
var _announced := false
# Avatars déjà envoyés à chaque pair cette session : une inscription
# re-diffuse tous les spawns, il ne faut pas renvoyer le blob à chaque fois.
var _avatar_sent_to: Dictionary = {}
# Blob de l'avatar LOCAL baké puis compressé, une fois par session : le bake
# (clone de scène + textures) coûte des secondes et ne doit JAMAIS tourner
# dans un handler réseau — sinon l'hôte gèle et les broadcasts partent en retard.
var _avatar_send_cache: PackedByteArray = PackedByteArray()
# Taille DÉCOMPRIMÉE du blob ci-dessus (nécessaire au decompress côté pair).
var _avatar_send_cache_raw_size := 0
# Manifeste de scripts utilisateur de l'avatar local (voir UserScriptMirror /
# LevelBaker.prepare_user_scripts) : envoyé aux pairs juste avant les chunks.
var _avatar_send_scripts_cache: Dictionary = {}
# Avatar choisi dans le menu LAN (res://…/avatar.tscn). Vide = mode auto :
# user/avatar.tscn si présent, sinon l'avatar par défaut.
var _selected_avatar_path := ""

var session_active := false
var is_host := false
var player_name := ""
var player_color := Color(0.2, 0.6, 1.0)
var level_bake_provider: Callable = Callable() # host : renvoie le blob baked du niveau {bytes, spawn}
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
var local_player: CharacterBody3D = null

var _level_root: Node3D = null
var _players_container: Node3D = null
var _players: Dictionary = {}       # peer_id -> nom
var _remote_players: Dictionary = {} # peer_id -> Node (avatar)
# peer_id -> {pos, rot} : position à préserver lors du respawn d'un avatar
# (changement de couleur/avatar en cours de partie).
var _respawn_positions: Dictionary = {}
# Un avatar n'est visible que pour ces pairs (sinon corps fantôme au spawn
# pendant que le joueur charge encore le niveau).
var _arrived_peers: Dictionary = {}
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
# Transform de spawn de la scène de l'HÔTE (transmis dans le blob du niveau :
# le Player en est exclu). Une fois connu, _spawn_* l'utilise à la place du
# Player de la scène locale d'origine. Vidé au début de chaque session.
var _host_spawn_transform: Dictionary = {}
# peer_id -> {bytes, spawn, total, sent} : blob baked du niveau en cours
# d'envoi vers un client qui vient de se connecter.
var _level_send_queue: Dictionary = {}
# Réception (client) du blob de l'hôte : {data, spawn, total, next}.
var _level_bake_receive: Dictionary = {}
# Cache (host) du blob baked : re-baké uniquement quand le niveau change.
var _level_baked_cache: Dictionary = {}

# Avatar chunked transfer (même pattern que les niveaux).
var _avatar_send_queue: Dictionary = {} # peer_id -> {bytes, total, sent}
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

# Réception d'avatars : UN SLOT PAR ÉMETTEUR — les blobs circulent en
# parallèle sur le canal 1 (maille complète), un slot unique serait
# réinitialisé à chaque entrelacement de transferts.
var _avatar_receive_slots: Dictionary = {} # from_id -> {data, size, total, next}

# Fenêtres des autres joueurs, rendues en quads noirs dans le MONDE (pas
# dans le repère du niveau) : chaque machine diffuse son propre état.
# Épaisseur (m) du BoxOccluder3D plaqué sur chaque quad distant — même
# valeur que WINDOW_OCCLUDER_DEPTH des fenêtres locales (windows_3d.gd).
const REMOTE_WINDOW_OCCLUDER_DEPTH := 0.04
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
# ── Curseur du propriétaire (remote focus) ─────────────────────────
# wid -> dernier état {inside, x, y} envoyé : on n'émet _sync_window_pointer
# qu'en cas de changement ou à ~30/s tant que le pointeur est dans la fenêtre.
var _last_cursor_pointer_send: Dictionary = {}
# wid -> serial du dernier curseur custom envoyé (-1 si aucun) : on n'émet
# _sync_window_cursor_image que quand le client change son curseur (rare).
var _last_cursor_image_send: Dictionary = {}
var _cursor_send_timer := 0.0
# peer_id -> {wid -> {inside, x, y, serial, hidden, hotspot, tex}} : état du
# curseur du propriétaire reçu pour les fenêtres distantes (remote focus).
var _remote_cursor_state: Dictionary = {}
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

var _responder: PacketPeerUDP = null # host : répond aux requêtes de découverte
var _scanner: PacketPeerUDP = null   # client : scanne le réseau
var _scanning := false
var _scan_results: Array = []
# Génération du scan en cours : incrémentée à chaque discover_games() et à
# chaque fermeture du scanner (déconnexion). Une coroutine discover_games()
# réveillée après un await vérifie sa génération : périmée → elle abandonne
# sans toucher au scanner courant (fermé, ou remplacé par un nouveau scan).
var _scan_generation := 0

func setup(level_root: Node3D, name: String, color: Color) -> void:
	_level_root = level_root
	player_name = name
	player_color = color
	# Charger la scène avatar custom si elle existe, sinon le défaut.
	if ResourceLoader.exists(CUSTOM_AVATAR_PATH):
		_avatar_scene = load(CUSTOM_AVATAR_PATH)
	else:
		_avatar_scene = load(DEFAULT_AVATAR_PATH)
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

func _generate_pin() -> String:
	return "%04d" % (randi() % 10000)

func get_pin() -> String:
	return _pin

func is_session_active() -> bool:
	return session_active

# Client : vrai pendant le chargement de la map de l'hôte (avant le join
# effectif). wayland_room s'en sert pour geler le joueur local.
func is_waiting_for_host_map() -> bool:
	return _pending_join

# Met à jour la couleur locale et la diffuse si une session est en cours.
func update_local_color(color: Color) -> void:
	player_color = color
	if not session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not _players.has(my_id) or _pending_join:
		return
	_players[my_id]["color"] = color
	if is_host:
		_broadcast_player_info()
	else:
		_update_player_info.rpc_id(1, my_id, player_name, color)
	update_local_avatar()

func update_local_name(pname: String) -> void:
	player_name = pname
	if not session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not _players.has(my_id) or _pending_join:
		return
	_players[my_id]["name"] = pname
	if is_host:
		_broadcast_player_info()
	else:
		_update_player_info.rpc_id(1, my_id, pname, _players[my_id].get("color", player_color))

func update_local_avatar() -> void:
	if not session_active:
		return
	var my_id := multiplayer.get_unique_id()
	if not _players.has(my_id) or _pending_join:
		return
	# Invalider le cache d'envoi pour rebake l'avatar avec le nouveau choix.
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	# Envoyer le nouvel avatar à tous les pairs connectés.
	for id in multiplayer.get_peers():
		if id == my_id:
			continue
		_avatar_sent_to.erase(id)
		_send_avatar_to(id)

## Diffuse l'info (nom + couleur) de TOUS les joueurs à tous les pairs.
## Appelé par l'hôte quand un joueur change son nom/couleur.
func _broadcast_player_info() -> void:
	for id in _players:
		var entry: Dictionary = _players[id]
		_update_player_info.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))

@rpc("any_peer", "reliable", "call_local")
func _update_player_info(target_id: int, pname: String, color: Color) -> void:
	# Si target_id == 0, c'est une diffusion de TOUS les joueurs (snapshot).
	if target_id == 0:
		return
	var from := multiplayer.get_remote_sender_id()
	# L'hôte peut broadcaster ses propres joueurs (from = 0 = local call).
	# Un client ne peut modifier que son propre profil.
	if from != 0 and from != target_id and not is_host:
		return
	if not _players.has(target_id):
		_players[target_id] = {"name": pname, "color": color}
	else:
		_players[target_id]["name"] = pname
		_players[target_id]["color"] = color
	# Mettre à jour l'avatar distant si déjà instancié.
	if _remote_players.has(target_id):
		var av: Node = _remote_players[target_id]
		if is_instance_valid(av) and av.has_method("setup"):
			av.setup(target_id, pname, color)
			if _level_stable and av.has_method("start_prewarm"):
				av.start_prewarm()
			if _arrived_peers.has(target_id) and av.has_method("set_arrived"):
				av.set_arrived(true)
	# Relayer aux autres pairs si c'est l'hôte qui reçoit la MàJ d'un client.
	if is_host and from != 0:
		_relay_player_info.rpc(target_id, pname, color)
	_emit_players()

@rpc("authority", "reliable", "call_remote")
func _relay_player_info(target_id: int, pname: String, color: Color) -> void:
	if is_host:
		return
	_players[target_id] = {"name": pname, "color": color}
	if _remote_players.has(target_id):
		var av: Node = _remote_players[target_id]
		if is_instance_valid(av) and av.has_method("setup"):
			av.setup(target_id, pname, color)
			if _level_stable and av.has_method("start_prewarm"):
				av.start_prewarm()
			if _arrived_peers.has(target_id) and av.has_method("set_arrived"):
				av.set_arrived(true)
	_emit_players()

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
func get_remote_players() -> Dictionary:
	return _remote_players

# ── DTLS (chiffrement de session) & anti brute-force PIN ─────────────

func _load_dtls_options() -> TLSOptions:
	var key := load("res://certs/lan_key.pem") as CryptoKey
	var cert := load("res://certs/lan_cert.crt") as X509Certificate
	if key == null or cert == null:
		_lan_log("DTLS: clé/cert introuvables, chiffrement désactivé")
		return null
	return TLSOptions.server(key, cert)

func _dtls_client_options() -> TLSOptions:
	var cert := load("res://certs/lan_cert.crt") as X509Certificate
	if cert == null:
		_lan_log("DTLS: cert introuvable, chiffrement désactivé")
		return null
	return TLSOptions.client(cert)

## true si l'adresse est actuellement blacklistée (verrou intact et non expiré).
func _pin_blocked(ip: String) -> bool:
	if ip == "" or not _pin_blacklist.has(ip):
		return false
	if Time.get_ticks_msec() - int(_pin_blacklist[ip]) >= PIN_BLACKLIST_MSEC:
		_pin_blacklist.erase(ip)
		_pin_fail_counts.erase(ip)
		return false
	return true

## Enregistre un échec de PIN depuis une adresse IP. Retourne true si
## l'adresse doit être blacklistée (verrou atteint).
func _on_pin_fail(ip: String) -> bool:
	if ip == "":
		return false
	_pin_blacklist[ip] = Time.get_ticks_msec()
	var rejected := pin_attempt(ip, false, _pin_fail_counts)
	if rejected:
		_lan_log("PIN brute-force: %s blacklisté (%d échecs)" % [ip, PIN_FAIL_LIMIT])
	else:
		_lan_log("PIN fail depuis %s (%d)" % [ip, int(_pin_fail_counts.get(ip, 0))])
	return rejected

## Réarme l'anti brute-force après un PIN valide d'une adresse donnée.
func _on_pin_success(ip: String) -> void:
	if ip == "":
		return
	pin_attempt(ip, true, _pin_fail_counts)
	_pin_blacklist.erase(ip)

## Adresse IP d'un peer distant (côté hôte). "" si indisponible.
func _remote_ip(peer_id: int) -> String:
	var mp := multiplayer.multiplayer_peer
	if mp == null or not mp is ENetMultiplayerPeer:
		return ""
	var p = mp.get_peer(peer_id)
	if p == null or not p is ENetPacketPeer:
		return ""
	return String(p.get_remote_address())

# ── Host ─────────────────────────────────────────────────────────────

func host_game() -> bool:
	if session_active:
		_set_status("Already in a LAN session")
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS, 8)
	if err != OK:
		_set_status("Host error: " + error_string(err))
		return false
	if encryption_enabled:
		var dtls := _load_dtls_options()
		if dtls != null:
			if peer.host.dtls_server_setup(dtls) != OK:
				_lan_log("DTLS: échec setup serveur, session non chiffrée")
			else:
				_lan_log("DTLS: session chiffrée (serveur)")
	multiplayer.multiplayer_peer = peer
	session_active = true
	is_host = true
	_pin = _generate_pin()
	pin_changed.emit(_pin)
	_lan_log("host PIN: " + _pin)
	# Miroir des scripts utilisateur reparti à zéro pour cette session (les
	# manifests reçus — avatars des clients — réinstallent leurs lots).
	UserScriptMirror.clear()
	# L'hôte a déjà son niveau chargé (compilé au boot) : avatars immédiatement
	# préchauffables.
	_level_stable = true
	_session_start_msec = Time.get_ticks_msec()
	_host_spawn_transform.clear()
	_players.clear()
	_players[multiplayer.get_unique_id()] = {"name": player_name, "color": player_color}
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_start_responder()
	_announced = false
	_avatar_sent_to.clear()
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	_lan_log("host_game — en attente de clients", true)
	_set_status("Hosting on %s:%d — open UDP port %d (and %d) in the firewall if a client can't connect" % [_local_ip(), PORT, PORT, DISCOVERY_PORT])
	_emit_players()
	return true

# ── Join ─────────────────────────────────────────────────────────────

func join_game(ip: String, pin: String = "", encrypted: bool = false) -> bool:
	if session_active:
		_set_status("Already in a LAN session")
		return false
	ip = ip.strip_edges()
	if ip == "":
		return false
	_last_join_encrypted = encrypted
	_pin = pin.strip_edges()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT, 8)
	if err != OK:
		_set_status("Connection error: " + error_string(err))
		return false
	if encrypted:
		var dtls := _dtls_client_options()
		if dtls != null:
			if peer.host.dtls_client_setup(ip, dtls) != OK:
				_lan_log("DTLS: échec setup client, session non chiffrée")
			else:
				_lan_log("DTLS: session chiffrée (client → %s)" % ip)
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_set_status("Connecting to %s:%d…" % [ip, PORT])
	return true

func disconnect_session() -> void:
	_disconnect_session()

func _on_connected_to_server() -> void:
	session_active = true
	is_host = false
	# Miroir des scripts utilisateur reparti à zéro : le niveau et les avatars
	# de CETTE session réinstalleront leurs lots avant tout chargement de blob.
	UserScriptMirror.clear()
	# Le niveau de l'hôte arrive plus tard (chunks fiables) : les avatars
	# restent invisibles jusqu'à mark_level_stable() (fin de apply_host_level).
	_level_stable = false
	_session_start_msec = Time.get_ticks_msec()
	_last_level_chunk_msec = _session_start_msec
	_host_spawn_transform.clear()
	_players.clear()
	_players[multiplayer.get_unique_id()] = {"name": player_name, "color": player_color}
	# Timeouts ENet généreux côté client (voir _on_peer_connected).
	_set_peer_timeout(1)
	_announced = false
	_avatar_sent_to.clear()
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	_lan_log("connecté à l'hôte — auth en cours (pending_join)", true)
	_set_status("Connected to server — authenticating…")
	_emit_players()
	# S'annoncer DÈS la connexion : envoyer le PIN pour vérification.
	# L'hôte répondra par auth_result ; _announce_self() partira uniquement
	# si le PIN est valide.
	_pending_join = true
	_auth_request_sent_msec = Time.get_ticks_msec()
	auth_request.rpc_id(1, _pin)

# Entrée effective dans la session : la map de l'hôte est appliquée (ou le
# délai de secours a expiré — on joue alors sur la map locale). L'annonce
# part normalement dès la connexion (_announce_self) ; ce rappel ne sert
# qu'aux chemins de secours où elle n'a pas encore eu lieu.
func _finalize_join() -> void:
	if not _pending_join:
		return
	_pending_join = false
	_lan_log("finalize_join — synchros dégelées")
	if local_player != null and "input_locked" in local_player:
		local_player.input_locked = false
	_set_status("Joined session")
	_announce_self()

# Annonce au serveur : registration (l'hôte re-broadcaste le spawn de tous)
# + envoi de notre avatar. Idempotent sur toute la session.
func _announce_self() -> void:
	if _announced:
		return
	_announced = true
	_lan_log("annonce: register + avatar → hôte")
	_register_player.rpc_id(1, player_name, player_color)
	_send_avatar_to(1)

# ── Authentification PIN ─────────────────────────────────────────────

## Le client envoie le PIN saisi au serveur (hôte) pour vérification.
@rpc("authority", "reliable")
func auth_request(pin: String) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or not is_host:
		return
	_lan_log("auth_request de %d — PIN=%s (attendu=%s)" % [from, pin, _pin])
	if pin == _pin:
		_pending_auth.erase(from)
		# PIN valide → réarme l'anti brute-force pour cette adresse.
		_on_pin_success(_remote_ip(from))
		_set_status("Player %d authenticated (PIN OK)" % from)
		auth_result.rpc_id(from, true)
		# Enregistrer le joueur (registration) et démarrer les transferts.
		# On utilise les mêmes paramètres que _register_player mais via le
		# canal auth pour éviter les courses.
		_players[from] = {"name": "Player %d" % from, "color": Color.WHITE}
		_register_player.rpc_id(from, player_name, player_color)
	else:
		var ip := _remote_ip(from)
		if _pin_blocked(ip):
			_lan_log("auth REJETÉ %d — IP %s blacklistée (trop d'échecs PIN)" % [from, ip])
			_set_status("Player %d rejected (IP blacklisted)" % from)
			auth_result.rpc_id(from, false)
			await get_tree().create_timer(0.5).timeout
			multiplayer.multiplayer_peer.disconnect_peer(from)
			return
		_lan_log("auth FAIL de %d — PIN incorrect" % from)
		_set_status("Player %d rejected (wrong PIN)" % from)
		auth_result.rpc_id(from, false)
		if ip != "" and _on_pin_fail(ip):
			_lan_log("PIN brute-force — déconnexion de %d (%s)" % [from, ip])
			await get_tree().create_timer(0.5).timeout
			multiplayer.multiplayer_peer.disconnect_peer(from)

## Réponse du serveur (hôte) à la tentative d'authentification du client.
@rpc("any_peer", "reliable")
func auth_result(ok: bool) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from != 1:
		return
	_auth_request_sent_msec = 0
	if ok:
		_lan_log("auth OK — annonce et envoi avatar")
		_announce_self()
	else:
		_lan_log("auth REJETÉ par l'hôte")
		_set_status("Authentication rejected by host (wrong PIN)")
		_disconnect_session()

func _on_connection_failed() -> void:
	_disconnect_session()
	_set_status("Connection failed — IP unreachable. Check: same network, host firewall (UDP %d/%d open), router AP isolation." % [PORT, DISCOVERY_PORT])

func _on_server_disconnected() -> void:
	_disconnect_session()
	_set_status("Disconnected from server")

# ── Spawn / despawn des avatars ──────────────────────────────────────

# Le client annonce son nom au serveur ; le serveur re-broadcaste le spawn
# de tous les joueurs connus pour que tout le monde (late-join compris)
# converge vers le même état.
@rpc("any_peer", "reliable")
func _register_player(pname: String, color: Color) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id() or not is_host:
		return
	# Rejeter les registrations de pairs non authentifiés (PIN vérifié).
	if _pending_auth.has(from):
		_lan_log("registration rejetée de %d — pas encore authentifié" % from)
		return
	_players[from] = {"name": pname, "color": color}
	_set_status("Player %d (%s) joined" % [from, pname])
	_lan_log("registration reçue de %d — broadcast spawns (roster=%d)" % [from, _players.size()])
	# Snapshot du roster envoyé IMMÉDIATEMENT au nouvel arrivant : minuscule,
	# il part devant les floods de chunks. Sans lui, le client ne connaît le
	# roster qu'aux broadcasts (souvent après l'application du niveau) et le
	# différé « attente des avatars » n'a rien à attendre.
	var snapshot: Array = []
	for id in _players:
		snapshot.append([id, String(_players[id].get("name", "")), Color(_players[id].get("color", Color.WHITE))])
	_roster_snapshot.rpc_id(from, snapshot)
	for id in _players:
		var entry: Dictionary = _players[id]
		_spawn_player.rpc(id, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	_emit_players()
	# Contrôle parti depuis un tube vide (snapshot + broadcasts ci-dessus) →
	# SEULEMENT MAINTENANT démarrer les transferts lourds vers ce pair.
	_send_level_to(from)
	_send_avatar_to(from)

# Roster complet envoyé par l'hôte dès la registration du client : peuplé
# AVANT tout transfert lourd, il permet au différé de niveau de connaître
# les avatars attendus.
@rpc("any_peer", "call_remote", "reliable")
func _roster_snapshot(entries: Array) -> void:
	if is_host or multiplayer.get_remote_sender_id() != 1:
		return
	for e in entries:
		if e.size() < 3:
			continue
		var pid := int(e[0])
		if pid == multiplayer.get_unique_id() or _players.has(pid):
			continue
		_players[pid] = {"name": String(e[1]), "color": e[2]}
	_lan_log("snapshot roster hôte — %s (blobs=%s)" % [str(_players.keys()), str(_avatar_blobs.keys())])
	_emit_players()
	# Si le niveau est déjà différé et que le snapshot révèle de nouveaux
	# joueurs, étendre l'attente (même deadline).
	if not _deferred_level.is_empty():
		var waiting: Array = _deferred_level["waiting"]
		for pid in _players:
			pid = int(pid)
			if pid == multiplayer.get_unique_id():
				continue
			if not _avatar_blobs.has(pid) and not waiting.has(pid):
				waiting.append(pid)
		waiting.sort()
		_deferred_level["waiting"] = waiting

# Chaque pair saute son propre peer_id (il a déjà son joueur local).
@rpc("any_peer", "reliable", "call_local")
func _spawn_player(peer_id: int, pname: String, color: Color) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	if _remote_players.has(peer_id):
		_remote_players[peer_id].setup(peer_id, pname, color)
		if _level_stable and _remote_players[peer_id].has_method("start_prewarm"):
			_remote_players[peer_id].start_prewarm()
		if _arrived_peers.has(peer_id) and _remote_players[peer_id].has_method("set_arrived"):
			_remote_players[peer_id].set_arrived(true)
		return
	# Le client découvre le roster via ce broadcast (_register_player ne
	# tourne que chez l'hôte) — nécessaire au différé de niveau comme à
	# l'affichage des joueurs.
	if not _players.has(peer_id):
		_players[peer_id] = {"name": pname, "color": color}
		_lan_log("roster += %d (n=%d, blobs=%s)" % [peer_id, _players.size(), str(_avatar_blobs.keys())])
	# Échange d'avatars en maille complète : si je n'ai pas encore envoyé le
	# mien à CE pair, je le lui envoie (une inscription re-diffuse tous les
	# spawns ; _send_avatar_to marque lui-même _avatar_sent_to, et le blob
	# est déjà baké/compressé en cache → envoi quasi gratuit).
	if session_active and not _avatar_sent_to.has(peer_id):
		_send_avatar_to(peer_id)
	var scene := _avatar_scene
	# Utiliser l'avatar reçu du peer si disponible (scène décodée à l'arrivée
	# du blob → spawn instantané ; sinon décodage à la volée).
	if _avatar_scene_cache.has(peer_id):
		scene = _avatar_scene_cache[peer_id]
	elif _avatar_blobs.has(peer_id):
		var tmp := "user://avatar_peer_%d.scn" % peer_id
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f != null:
			f.store_buffer(_avatar_blobs[peer_id])
			f.close()
			var loaded: PackedScene = ResourceLoader.load(tmp, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
			if loaded != null:
				scene = loaded
				_avatar_scene_cache[peer_id] = loaded
	var avatar := scene.instantiate()
	avatar.name = str(peer_id)
	avatar.setup(peer_id, pname, color)
	avatar.local_player = local_player
	# Utiliser la position préservée (respawn après changement d'avatar/couleur)
	# sinon le spawn par défaut.
	if _respawn_positions.has(peer_id):
		var rp: Dictionary = _respawn_positions[peer_id]
		avatar.position = rp.get("pos", _spawn_position())
		avatar.rotation = rp.get("rot", _spawn_rotation())
		_respawn_positions.erase(peer_id)
	else:
		avatar.position = _spawn_position()
		avatar.rotation = _spawn_rotation()
	avatar.scale = _spawn_scale()
	# Invisible jusqu'à la première synchro de transform du pair : tant
	# qu'il charge le niveau (_pending_join) il n'en émet aucune, et on ne
	# veut pas d'un corps fantôme planté au spawn côté des autres joueurs.
	avatar.set_arrived(_arrived_peers.has(peer_id))
	_add_drop_target(avatar)
	_players_container.add_child(avatar)
	_remote_players[peer_id] = avatar
	if _level_stable:
		avatar.start_prewarm()
	_emit_players()


## Les avatars distants sont purement visuels (Node3D, « pas de collision »
## cf. avatar.gd) : sans collider, aucun raycast ne peut les toucher — le
## ciblage du drag & drop de fichiers (et toute visée monde) les traverse.
## On ajoute un corps cinématique capsule au spawn. Layer 2 : le joueur
## local (mask 1) continue de traverser les autres joueurs, mais les
## raycasts (mask par défaut = tout) les voient.
func _add_drop_target(avatar: Node3D) -> void:
	if avatar == null or not is_instance_valid(avatar):
		return
	if avatar.has_node("DropTarget"):
		return
	var body := AnimatableBody3D.new()
	body.name = "DropTarget"
	# sync_to_physics=true fige le corps dans le serveur physique à sa
	# transform de création : le mouvement du parent n'est jamais propagé et
	# les raycasts touchent une position obsolète. false = le collider suit
	# l'avatar (aucune mécanique de plateforme n'est attendue ici).
	body.sync_to_physics = false
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position = Vector3(0, 0.5, 0)
	body.add_child(cs)
	avatar.add_child(body)


# Le niveau vient d'être appliqué (client : fin de apply_host_level ; l'hôte
# est stable dès host_game). Quelques frames de latence pour laisser le
# nouveau niveau compiler ses variants de shaders (le 1er rendu du SubViewport
# du prewarm ne doit pas s'empiler dessus), puis tous les avatars distants
# sont préchauffés hors viewport principal. Appelé sans await par le jeu :
# le début est synchrone (_level_stable = true), la suite est différée.
func mark_level_stable() -> void:
	if _level_stable:
		return
	_level_stable = true
	# Le niveau (hôte ou local restauré) est appliqué : le client peut
	# maintenant entrer dans la session s'il chargait encore la map.
	_finalize_join()
	for _f in 5:
		await get_tree().process_frame
	for id in _remote_players:
		var av: Node = _remote_players[id]
		if is_instance_valid(av) and av.has_method("start_prewarm"):
			av.start_prewarm()

@rpc("any_peer", "reliable", "call_local")
func _remove_player(peer_id: int) -> void:
	if _remote_players.has(peer_id):
		_remote_players[peer_id].queue_free()
		_remote_players.erase(peer_id)
	_arrived_peers.erase(peer_id)
	_players.erase(peer_id)
	_avatar_blobs.erase(peer_id)
	_avatar_scene_cache.erase(peer_id)
	_clear_remote_windows(peer_id)
	_emit_players()

func _on_peer_connected(id: int) -> void:
	if is_host:
		_set_status("Player %d connected — waiting for PIN…" % id)
		# Timeouts ENet généreux : pendant un stream partagé (vidéo/audio), le
		# thread principal fait de l'encodage/décodage JPEG par frame ; un à-coup
		# de quelques secondes ne doit pas faire tomber la session (défaut ENet :
		# déconnexion après ~5 s sans ACK).
		_set_peer_timeout(id)
		_pending_auth[id] = true
		# PAS d'envoi de niveau/avatar ici : attendre la registration du pair
		# (voir _register_player). Les paquets de contrôle (snapshot roster,
		# broadcasts) doivent partir sur un tube VIDE — s'ils se disputent le
		# socket avec des mégaoctets de chunks, ils sont perdus dès le burst
		# initial et ne se récupèrent que par retransmissions ENet (~5-8 s).

# L'hôte transmet son niveau (celui que tous doivent voir) au joueur qui
# rejoint : le blob binaire auto-suffisant produit par LevelBaker (meshes/
# matériaux/textures embarqués → jouable même avec des builds différents),
# compressé en ZSTD puis envoyé en chunks fiables. Le blob est mis en cache :
# re-baké seulement si le niveau change (on_level_swapped).
func _send_level_to(id: int) -> void:
	if not level_bake_provider.is_valid():
		push_warning("LAN: level_bake_provider invalide")
		return
	if _level_baked_cache.is_empty():
		_level_baked_cache = level_bake_provider.call()
	var data: Dictionary = _level_baked_cache
	if data.is_empty():
		push_warning("LAN: bake du niveau vide — rien à envoyer")
		return
	var bytes: PackedByteArray = data.get("bytes", PackedByteArray())
	if bytes.is_empty():
		push_warning("LAN: blob du niveau vide")
		return
	var compressed := bytes.compress(FileAccess.COMPRESSION_ZSTD)
	if compressed.is_empty():
		compressed = bytes
	# Manifeste des scripts utilisateur : envoyé AVANT les chunks (même canal
	# fiable → ordre garanti). À l'arrivée du dernier chunk le pair écrit déjà
	# ses fichiers miroir et load(blob) résout les ext_resource des scripts.
	var manifest: Dictionary = data.get("scripts", {})
	if not manifest.is_empty():
		_receive_level_scripts.rpc_id(id, manifest)
	_level_send_queue[id] = {
		"bytes": compressed,
		"spawn": data.get("spawn", Vector3.ZERO),
		"rotation": data.get("spawn_rotation", Vector3.ZERO),
		"scale": data.get("spawn_scale", Vector3.ONE),
		"size": bytes.size(),
		"total": ceili(float(compressed.size()) / float(LEVEL_CHUNK_SIZE)),
		"sent": 0,
	}
	push_warning("LAN: envoi niveau vers peer %d — brut %d KB, compressé %d KB, %d chunks" % [id, bytes.size() / 1024, compressed.size() / 1024, ceili(float(compressed.size()) / float(LEVEL_CHUNK_SIZE))])
	_set_status("Sending host level to %d (%d KB)…" % [id, compressed.size() / 1024])

# Pousse quelques chunks du niveau vers les peers qui viennent de se connecter,
# étalé sur plusieurs ticks (pas de flood ENet d'un seul coup). Chaque chunk
# reste dans une vague fiable ENet (~24 Ko) ; le canal fiable garantit l'ordre.
func _drain_level_send() -> void:
	if _level_send_queue.is_empty():
		return
	for id in _level_send_queue.keys():
		var entry: Dictionary = _level_send_queue[id]
		for i in LEVEL_CHUNKS_PER_TICK:
			var sent: int = int(entry["sent"])
			var total: int = int(entry["total"])
			if sent >= total:
				_level_send_queue.erase(id)
				break
			var bytes: PackedByteArray = entry["bytes"]
			var start := sent * LEVEL_CHUNK_SIZE
			var end := mini(start + LEVEL_CHUNK_SIZE, bytes.size())
			_receive_level_baked.rpc_id(id, sent, total, entry["size"], entry["spawn"], entry.get("rotation", Vector3.ZERO), entry.get("scale", Vector3.ONE), bytes.slice(start, end))
			entry["sent"] = sent + 1

# Manifeste des scripts utilisateur de l'hôte (UserScriptMirror) : reçu une
# fois par session, AVANT les chunks du niveau. Installé immédiatement dans le
# miroir disque — quand le blob sera complet, load() résoudra ses ext_resource
# (et les preload/extends des scripts) vers de vrais fichiers locaux.
# MÊME CANAL (6) que les chunks : l'ordre fiable ENet n'est garanti que
# intra-canal, il faut que ce RPC précède toujours le premier chunk.
@rpc("any_peer", "call_remote", "reliable", 6)
func _receive_level_scripts(manifest: Dictionary) -> void:
	if is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if manifest.is_empty() or not UserScriptMirror.valid(manifest):
		return
	var count := UserScriptMirror.install(manifest)
	push_warning("LAN: scripts utilisateur du niveau installés (%d fichiers)" % count)
	_lan_log("scripts niveau hôte — lot installé (%d fichiers)" % count)

# Canal ENet dédié (6) : les milliers de chunks du niveau ne doivent PAS
# bloquer (ordre fiable) les RPC de contrôle sur le canal 0 — sinon le
# broadcast de spawn et le roster n'arrivent qu'après tout le niveau.
@rpc("any_peer", "call_remote", "reliable", 6)
func _receive_level_baked(index: int, total: int, uncompressed_size: int, spawn: Vector3, spawn_rotation: Vector3, spawn_scale: Vector3, chunk: PackedByteArray) -> void:
	if is_host or multiplayer.get_remote_sender_id() != 1:
		return
	if total < 1 or uncompressed_size < 1 or chunk.is_empty() or index < 0 or index >= total:
		return
	# Nouveau transfert (le blob baked diffère d'une session à l'autre) : on
	# repart de zéro. Le canal fiable garantit l'ordre intra-transfert.
	if not _level_bake_receive.has("total") or int(_level_bake_receive.get("total", -1)) != total:
		_level_bake_receive = {"data": PackedByteArray(), "spawn": spawn, "rotation": spawn_rotation, "scale": spawn_scale, "size": uncompressed_size, "total": total, "next": 0}
	if index < int(_level_bake_receive.get("next", 0)):
		return
	# Passer par une variable locale : l'append_array sur un accès direct
	# `(dict["data"] as PackedByteArray)` travaille sur une copie détachée et
	# l'assemblage ne grossit jamais (→ decompress sur un buffer vide).
	var data: PackedByteArray = _level_bake_receive["data"]
	data.append_array(chunk)
	_level_bake_receive["data"] = data
	_level_bake_receive["next"] = index + 1
	_last_level_chunk_msec = Time.get_ticks_msec()
	if index + 1 < total:
		# Progression du chargement : le joueur est gelé jusqu'au join final.
		_set_status("Loading host map… %d%%" % int((index + 1) * 100.0 / total))
		return
	var raw: PackedByteArray = _level_bake_receive["data"]
	var recv_spawn: Vector3 = _level_bake_receive["spawn"]
	var recv_rotation: Vector3 = _level_bake_receive["rotation"]
	var recv_scale: Vector3 = _level_bake_receive["scale"]
	var recv_size: int = int(_level_bake_receive["size"])
	_level_bake_receive.clear()
	var bytes := raw.decompress(recv_size, FileAccess.COMPRESSION_ZSTD)
	if bytes.is_empty() or bytes.size() != recv_size:
		push_warning("LAN: décompress échoué — reçu %d octets, attendu %d" % [bytes.size(), recv_size])
		_set_status("Host level corrupted (decompress failed) — kept local level")
		# Transfert mort : ne pas rester bloqué en attente de join.
		_finalize_join()
		return
	push_warning("LAN: niveau reçu — %d KB décompressé" % [bytes.size() / 1024])
	var tmp := "user://lan_level.scn"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_set_status("Could not write the host's level")
		_finalize_join()
		return
	f.store_buffer(bytes)
	f.close()
	var scene: PackedScene = load(tmp)
	if scene == null:
		push_warning("LAN: impossible de charger la scène du niveau reçu (%s)" % tmp)
		_set_status("Host level unreadable — kept local level")
		_finalize_join()
		return
	push_warning("LAN: scène du niveau chargée OK")
	# Mémoriser le transform de spawn de la scène de l'hôte : les avatars
	# distants sont spawnés selon LUI (pas le Player local de la scène
	# d'origine), que le niveau soit déjà appliqué ou pas.
	_host_spawn_transform = {"pos": recv_spawn, "rot": recv_rotation, "scale": recv_scale}
	# Le statut AVANT l'emit : apply_host_level → mark_level_stable →
	# _finalize_join() pose "Joined session", qui doit rester le message final.
	_set_status("Host level loaded (%d KB)" % [bytes.size() / 1024])
	# L'application peut être différée : on attend les avatars des pairs
	# (voir _defer_or_emit_level_apply) pour qu'ils apparaissent avec le
	# niveau, pas quelques secondes après.
	_defer_or_emit_level_apply(scene, recv_spawn, recv_rotation, recv_scale)


func _cache_avatar_scene(peer_id: int) -> void:
	if not _avatar_blobs.has(peer_id) or _avatar_scene_cache.has(peer_id):
		return
	var tmp := "user://avatar_peer_%d.scn" % peer_id
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(_avatar_blobs[peer_id])
	f.close()
	var t0 := Time.get_ticks_msec()
	# CACHE_MODE_REPLACE pour forcer le rechargement depuis le disque quand
	# l'avatar change : load() garde en cache l'ancienne scène PackedScene du
	# même chemin, même après écriture d'un nouveau blob.
	var loaded: PackedScene = ResourceLoader.load(tmp, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	push_warning("LAN: avatar peer %d décodé en %d ms" % [peer_id, Time.get_ticks_msec() - t0])
	if loaded != null:
		_avatar_scene_cache[peer_id] = loaded

# Retient l'application du niveau tant que des blobs d'avatars attendus
# (roster courant, hors joueur local) manquent ; sinon applique immédiatement.
func _defer_or_emit_level_apply(scene: PackedScene, pos: Vector3, rot: Vector3, scl: Vector3) -> void:
	var waiting: Array = []
	for id in _players:
		if int(id) == multiplayer.get_unique_id():
			continue
		if not _avatar_blobs.has(int(id)):
			waiting.append(int(id))
	_lan_log("niveau prêt — roster=%s blobs=%s → %s" % [
		str(_players.keys()), str(_avatar_blobs.keys()),
		"application immédiate" if waiting.is_empty() else "différé (attente %s)" % str(waiting)])
	if waiting.is_empty():
		level_apply_requested.emit(scene, pos, rot, scl)
		return
	waiting.sort()
	_deferred_level = {
		"scene": scene, "pos": pos, "rot": rot, "scl": scl,
		"waiting": waiting,
		"deadline": Time.get_ticks_msec() + AVATAR_LEVEL_WAIT_TIMEOUT_MSEC,
	}
	_set_status("Loading players' avatars… (%d pending)" % waiting.size())
	push_warning("LAN: niveau différé — avatars attendus des peers %s" % str(waiting))

# Applique le niveau différé dès que plus personne n'est attendu (ou au
# timeout ; un pair parti/disconnecté cesse d'être attendu).
func _maybe_flush_deferred_level() -> void:
	if _deferred_level.is_empty():
		return
	var waiting: Array = []
	for id in _deferred_level["waiting"]:
		if multiplayer.multiplayer_peer != null and multiplayer.get_peers().has(int(id)):
			if not _avatar_blobs.has(int(id)):
				waiting.append(int(id))
	_deferred_level["waiting"] = waiting
	var expired: bool = Time.get_ticks_msec() >= int(_deferred_level["deadline"])
	if waiting.is_empty() or expired:
		if expired and not waiting.is_empty():
			push_warning("LAN: timeout avatars (%s) — application du niveau sans eux" % str(waiting))
		_lan_log("flush niveau différé — %s" % ("timeout, manquants %s" % str(waiting) if not waiting.is_empty() else "blobs complets"))
		var d: Dictionary = _deferred_level
		_deferred_level = {}
		level_apply_requested.emit(d["scene"], d["pos"], d["rot"], d["scl"])

# Appelé par wayland_room après avoir remplacé le niveau : bascule la racine
# et déplace les avatars distants vers un nouveau conteneur (l'ancien niveau
# est sur le point d'être libéré).
func on_level_swapped(new_level_root: Node3D) -> void:
	_level_baked_cache.clear()
	_level_root = new_level_root
	_players_container = Node3D.new()
	_players_container.name = "Players"
	_level_root.add_child(_players_container)
	for id in _remote_players:
		var av: Node = _remote_players[id]
		if not is_instance_valid(av):
			_remote_players.erase(id)
			_arrived_peers.erase(id)
			continue
		var p: Node = av.get_parent()
		if p and p != _players_container:
			p.remove_child(av)
		_players_container.add_child(av)
		# Les avatars déjà présents ont été spawnés selon la scène locale
		# d'origine (le blob de l'hôte n'était pas encore appliqué) : recaler
		# scale/rotation sur le spawn de l'hôte. La position est resynchronisée
		# par _sync_player_transform, mais le scale n'est jamais re-synchronisé.
		if not _host_spawn_transform.is_empty():
			av.rotation = _spawn_rotation()
			av.scale = _spawn_scale()

# ── Transfert des avatars custom ─────────────────────────────────────
# Chaque joueur envoie sa scène avatar (custom ou défaut) aux autres
# pour que chacun voie l'avatar réel de l'autre.

# ── Choix de l'avatar (menu LAN) ─────────────────────────────────────

## Liste tous les avatar.tscn présents dans le projet : scan récursif de
## res:// (DirAccess liste aussi le contenu du PCK exporté). Chaque entrée
## est {path, name} — name = nom du nœud racine de la scène. L'avatar par
## défaut est toujours listé en premier, les autres par ordre de chemin.
static func list_avatars() -> Array[Dictionary]:
	var found: Array = []
	_scan_avatars("res://", found)
	# Build exporté : les ressources texte sont converties en binaire et
	# remplacées par un fichier « *.remap » dans le PCK. Normalisation vers
	# le chemin logique, que ResourceLoader sait résoudre (remap inclus).
	for i in found.size():
		found[i] = String(found[i]).trim_suffix(".remap")
	found.erase(DEFAULT_AVATAR_PATH)
	found.sort()
	found.push_front(DEFAULT_AVATAR_PATH)
	# Dédoublonnage défensif (avatar.tscn ET avatar.tscn.remap vus ensemble).
	var uniq: Array = []
	for p in found:
		if not uniq.has(p):
			uniq.append(p)
	var out: Array[Dictionary] = []
	var seen := {}
	for p in uniq:
		var path := String(p)
		var nm := _avatar_display_name(path)
		if nm == "":
			continue
		# Homonymes (deux scènes dont la racine porte le même nom) :
		# suffixe numérique pour que le menu reste lisible.
		if seen.has(nm):
			seen[nm] = int(seen[nm]) + 1
			nm = "%s (%d)" % [nm, seen[nm]]
		else:
			seen[nm] = 1
		out.append({"path": path, "name": nm})
	return out

static func _scan_avatars(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not f.begins_with("."):
			var p := dir_path.path_join(f)
			if d.current_is_dir():
				_scan_avatars(p, out)
			# « .remap » : forme prise par les .tscn dans un PCK exporté.
			elif f == "avatar.tscn" or f == "avatar.tscn.remap":
				out.append(p)
		f = d.get_next()
	d.list_dir_end()

# Nom affiché : celui du nœud racine de la scène, lu depuis son SceneState
# (load() sans instantiate — les dépendances GLB restent en cache pour le
# bake ultérieur).
static func _avatar_display_name(path: String) -> String:
	var ps := load(path) as PackedScene
	if ps == null:
		return ""
	var st := ps.get_state()
	if st != null and st.get_node_count() > 0:
		return st.get_node_name(0)
	return ""

## Applique l'avatar choisi dans le menu LAN. "" (ou les chemins historiques)
## remet le mode auto. La scène est validée : elle doit charger et porter un
## script exposant setup() (celui d'avatar.gd), sinon on retombe en auto.
func set_selected_avatar(path: String) -> void:
	var old_path := _selected_avatar_path
	_selected_avatar_path = ""
	# La sélection effective change dans tous les cas (nouveau chemin ou
	# retour en auto) → le blob baké n'est plus valable.
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	if path.is_empty() or path == CUSTOM_AVATAR_PATH or path == DEFAULT_AVATAR_PATH:
		if session_active and old_path != path:
			update_local_avatar()
		return
	if not ResourceLoader.exists(path):
		push_warning("LAN: avatar choisi introuvable : %s" % path)
		return
	var ps := load(path) as PackedScene
	if ps == null:
		push_warning("LAN: avatar illisible : %s" % path)
		return
	var inst := ps.instantiate()
	if inst == null or not inst.has_method("setup"):
		push_warning("LAN: scène sans script avatar (setup manquant) : %s" % path)
		if inst != null:
			inst.free()
		return
	inst.free()
	_selected_avatar_path = path
	if session_active and old_path != path:
		update_local_avatar()


func _bake_avatar() -> Dictionary:
	# Retour : {bytes, scripts} — bytes = blob binaire auto-suffisant,
	# scripts = manifeste UserScriptMirror (vide si aucun script utilisateur).
	# Scène à incarner : le choix du menu LAN s'il est valide, sinon le
	# comportement historique (custom user/avatar.tscn, sinon défaut).
	var src := _avatar_scene
	if _selected_avatar_path != "":
		var sel := load(_selected_avatar_path) as PackedScene
		if sel != null:
			src = sel
	if src == null:
		return {}
	# Deep-clone la scène pour embarquer les meshes/materials/textures
	# (sinon les references .fbx/.glb ne seront pas résolues côté peer).
	# Limiter les textures à 256 px pour éviter un crash Vulkan côté client.
	LevelBaker.max_texture_size = 256
	LevelBaker.keep_surface_format = true
	var root := src.instantiate() as Node3D
	if root == null:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	# Scripts utilisateur de l'avatar : collecte + remappage miroir AVANT le
	# clonage (_clone attache les copies miroir ; voir LevelBaker).
	var manifest := LevelBaker.prepare_user_scripts(root)
	var cache := {}
	var baked := LevelBaker._clone(root, null, cache) as Node3D
	if baked == null:
		root.queue_free()
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	baked.name = "Avatar"
	baked.owner = null
	LevelBaker._own_all(baked, baked)
	# Diagnostic : compter meshes / matériaux / textures dans le bake.
	var diag := {"meshes": 0, "mats": 0, "textures": 0, "verts": 0}
	_diag_count_res(baked, diag)
	push_warning("LAN: avatar bake diag — %s cache=%d" % [str(diag), cache.size()])
	var scene := PackedScene.new()
	if scene.pack(baked) != OK:
		baked.queue_free()
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	baked.queue_free()
	var tmp := "user://avatar_send.scn"
	if ResourceSaver.save(scene, tmp) != OK:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	var f := FileAccess.open(tmp, FileAccess.READ)
	if f == null:
		LevelBaker.max_texture_size = 0
		LevelBaker.keep_surface_format = false
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	push_warning("LAN: avatar baked — %d KB (%d scripts user)" % [bytes.size() / 1024, manifest.size()])
	LevelBaker.max_texture_size = 0
	LevelBaker.keep_surface_format = false
	return {"bytes": bytes, "scripts": manifest}


func _diag_count_res(node: Node, diag: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			diag["meshes"] += 1
			if mi.mesh is ArrayMesh:
				var am := mi.mesh as ArrayMesh
				for s in am.get_surface_count():
					diag["verts"] += am.surface_get_array_len(s)
					var mat = am.surface_get_material(s)
					if mat != null:
						diag["mats"] += 1
						for p in mat.get_property_list():
							if mat.get(p["name"]) is Texture2D:
								diag["textures"] += 1
	if node is Label3D:
		pass
	for c in node.get_children():
		_diag_count_res(c, diag)

func _send_avatar_to(id: int) -> void:
	# Bake + compression une seule fois par session (voir _avatar_send_cache).
	if _avatar_send_cache.is_empty():
		var t0 := Time.get_ticks_msec()
		var res: Dictionary = _bake_avatar()
		if res.is_empty():
			return
		var raw: PackedByteArray = res.get("bytes", PackedByteArray())
		if raw.is_empty():
			return
		_avatar_send_scripts_cache = res.get("scripts", {})
		var compressed := raw.compress(FileAccess.COMPRESSION_ZSTD)
		if compressed.is_empty():
			compressed = raw
		_avatar_send_cache = compressed
		_avatar_send_cache_raw_size = raw.size()
		_lan_log("avatar local baké en %d ms — %d KB brut, %d KB compressé, %d scripts" % [
			Time.get_ticks_msec() - t0, raw.size() / 1024, compressed.size() / 1024,
			_avatar_send_scripts_cache.size()])
	var bytes := _avatar_send_cache
	# Marquage centralisé : tout envoi (connect, annonce, maille) compte.
	_avatar_sent_to[id] = true
	# Manifeste de scripts AVANT les chunks (même canal fiable → ordre garanti :
	# le miroir est peuplé quand le blob complet sera décodé).
	if not _avatar_send_scripts_cache.is_empty():
		_avatar_scripts.rpc_id(id, multiplayer.get_unique_id(), _avatar_send_scripts_cache)
	var total := ceili(float(bytes.size()) / float(LEVEL_CHUNK_SIZE))
	_avatar_send_queue[id] = {
		"bytes": bytes,
		"size": _avatar_send_cache_raw_size,
		"total": total,
		"sent": 0,
	}
	push_warning("LAN: envoi avatar vers peer %d — compressé %d KB, %d chunks" % [id, bytes.size() / 1024, total])

func _drain_avatar_send() -> void:
	if _avatar_send_queue.is_empty():
		return
	for id in _avatar_send_queue.keys():
		var entry: Dictionary = _avatar_send_queue[id]
		for i in LEVEL_CHUNKS_PER_TICK:
			var sent: int = int(entry["sent"])
			var total: int = int(entry["total"])
			if sent >= total:
				_avatar_send_queue.erase(id)
				break
			var bytes: PackedByteArray = entry["bytes"]
			var start := sent * LEVEL_CHUNK_SIZE
			var end := mini(start + LEVEL_CHUNK_SIZE, bytes.size())
			_avatar_recv_chunk.rpc_id(id, multiplayer.get_unique_id(), sent, total, entry["size"], bytes.slice(start, end))
			entry["sent"] = sent + 1

# Manifeste des scripts utilisateur d'un avatar (UserScriptMirror) : envoyé
# par chaque pair juste avant ses chunks, sur le même canal fiable (ordre
# garanti) — le miroir est peuplé quand le blob complet sera décodé.
@rpc("any_peer", "call_remote", "reliable", 1)
func _avatar_scripts(from_id: int, manifest: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != from_id:
		return
	if manifest.is_empty() or not UserScriptMirror.valid(manifest):
		return
	var count := UserScriptMirror.install(manifest)
	_lan_log("scripts avatar[%d] — lot installé (%d fichiers)" % [from_id, count])

# Canal ENet dédié (1) : l'avatar de l'hôte part juste après les chunks de
# niveau sur sa connexion — sans canal propre il resterait bloqué derrière
# tout le transfert (ordre fiable du canal 0).
@rpc("any_peer", "call_remote", "reliable", 1)
func _avatar_recv_chunk(from_id: int, index: int, total: int, uncompressed_size: int, chunk: PackedByteArray) -> void:
	if total < 1 or uncompressed_size < 1 or chunk.is_empty() or index < 0 or index >= total:
		return
	# Nouveau transfert de cet émetteur : repart de zéro.
	var slot: Dictionary = _avatar_receive_slots.get(from_id, {})
	if slot.is_empty() or int(slot.get("total", -1)) != total or int(slot.get("size", -1)) != uncompressed_size:
		slot = {"data": PackedByteArray(), "size": uncompressed_size, "total": total, "next": 0}
		_avatar_receive_slots[from_id] = slot
		_lan_log("avatar[%d]: début (%d chunks)" % [from_id, total])
	if index < int(slot["next"]):
		return
	var data: PackedByteArray = slot["data"]
	data.append_array(chunk)
	slot["data"] = data
	slot["next"] = index + 1
	if index + 1 < total:
		return
	var raw: PackedByteArray = slot["data"]
	var recv_size: int = int(slot["size"])
	var recv_from: int = from_id
	_avatar_receive_slots.erase(from_id)
	var bytes := raw.decompress(recv_size, FileAccess.COMPRESSION_ZSTD)
	if bytes.is_empty() or bytes.size() != recv_size:
		push_warning("LAN: avatar décompress échoué — reçu %d octets, attendu %d" % [bytes.size(), recv_size])
		return
	push_warning("LAN: avatar reçu de peer %d — %d KB" % [recv_from, bytes.size() / 1024])
	_avatar_blobs[recv_from] = bytes
	# Décodage immédiat : le coût du load() est payé ici (pendant l'attente
	# du niveau) plutôt qu'au spawn. Invalider le cache précédent pour que la
	# nouvelle scène soit décodée (un avatar changé doit remplacer l'ancien).
	_avatar_scene_cache.erase(recv_from)
	_cache_avatar_scene(recv_from)
	if _remote_players.has(recv_from):
		var av: Node = _remote_players[recv_from]
		# Préserver la position pour le respawn : l'avatar va être détruit et
		# recréé, on ne veut pas le repositionner au spawn.
		if av is Node3D:
			_respawn_positions[recv_from] = {
				"pos": (av as Node3D).global_position,
				"rot": (av as Node3D).rotation,
			}
		av.queue_free()
		_remote_players.erase(recv_from)
	var entry: Dictionary = _players.get(recv_from, {})
	_spawn_player(recv_from, String(entry.get("name", "")), Color(entry.get("color", Color.WHITE)))
	_maybe_flush_deferred_level()

@rpc("any_peer", "reliable")
func _avatar_send_blob(from_id: int, blob: PackedByteArray) -> void:
	pass

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
	_avatar_blobs.erase(id)
	_avatar_send_queue.erase(id)
	_pending_auth.erase(id)
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
		_level_send_queue.erase(id)
	else:
		_remove_player(id)
		if id == 1:
			_level_bake_receive.clear()
	_last_texture_versions.erase(id)
	_last_applied_version.erase(id)
	_last_acked_version.erase(id)
	_video_last_sent.erase(id)
	_video_acked.erase(id)
	_video_config_sent.erase(id)
	_video_ack_pending.erase(id)
	_set_status("Player %d disconnected" % id)

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
	if not _host_spawn_transform.is_empty():
		return _host_spawn_transform.get("pos", Vector3.ZERO)
	var player := _level_root.get_node_or_null("Player") as Node3D
	return player.position if player != null else Vector3.ZERO

func _spawn_rotation() -> Vector3:
	if not _host_spawn_transform.is_empty():
		return _host_spawn_transform.get("rot", Vector3.ZERO)
	var player := _level_root.get_node_or_null("Player") as Node3D
	return player.rotation if player != null else Vector3.ZERO

func _spawn_scale() -> Vector3:
	if not _host_spawn_transform.is_empty():
		return _host_spawn_transform.get("scale", Vector3.ONE)
	var player := _level_root.get_node_or_null("Player") as Node3D
	return player.scale if player != null else Vector3.ONE

# ── Sync des transformations ─────────────────────────────────────────

@rpc("any_peer", "unreliable")
func _sync_player_transform(pos: Vector3, yaw: float, pitch: float) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0:
		return
	if not _remote_players.has(from):
		return
	_reveal_peer(from)
	_remote_players[from].apply_transform(pos, yaw, pitch)

## Première preuve de vie d'un pair. Il émet une synchro de transform à
## chaque frame physique dès qu'il est en session — et AUCUNE tant qu'il
## charge le niveau. Révéler ici = il apparaît quand il arrive vraiment.
func _reveal_peer(peer_id: int) -> void:
	if _arrived_peers.has(peer_id):
		return
	_arrived_peers[peer_id] = true
	var av: Node = _remote_players.get(peer_id)
	if av != null and is_instance_valid(av) and av.has_method("set_arrived"):
		av.set_arrived(true)

func _physics_process(delta: float) -> void:
	_update_cpu_capture_request()
	_drain_level_send()
	_drain_avatar_send()
	if not session_active or _level_root == null:
		return
	# Filet de sécurité join : si le niveau de l'hôte n'arrive jamais (bake
	# impossible, transfert mort), entrer quand même dans la session après un
	# délai SANS AUCUN chunk reçu — on jouera sur la map locale. Un transfert
	# lent mais vivant (chunks réguliers) ne déclenche pas ce fallback.
	if _pending_join and _last_level_chunk_msec > 0 \
			and Time.get_ticks_msec() - _last_level_chunk_msec > JOIN_FALLBACK_MSEC:
		push_warning("LAN: niveau hôte jamais reçu — join forcé sur la map locale")
		_finalize_join()
	# Filet de sécurité avatars : session rejointe mais niveau toujours pas
	# stable → préchauffer quand même (le niveau local est déjà stable).
	elif not _level_stable and _session_start_msec > 0 \
			and Time.get_ticks_msec() - _session_start_msec > 10000:
		mark_level_stable()
	# Niveau différé en attente des avatars : timeout de sécurité.
	_maybe_flush_deferred_level()
	if multiplayer.get_peers().is_empty():
		return
	# Map de l'hôte encore en cours de réception : n'émettre aucune synchro —
	# le joueur local n'est pas encore entré dans la session.
	if _pending_join:
		return
	var player := _level_root.get_node_or_null("Player") as Node3D
	if player == null:
		return
	var camera := player.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	_sync_player_transform.rpc(player.position, player.rotation.y, camera.rotation.x)
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
# Consommateurs additionnels de la copie CPU synchrone (clé -> true) : ex.
# focus_mode pour analyser la transparence de la fenêtre focus. Tant que non
# vide, la copie est demandée même sans partage LAN actif.
var cpu_capture_consumers: Dictionary = {}

func _update_cpu_capture_request() -> void:
	if compositor == null or not compositor.has_method("set_cpu_capture_requested"):
		return
	var need := not cpu_capture_consumers.is_empty()
	if not need and session_active and not _pending_join and windows_provider.is_valid() and not multiplayer.get_peers().is_empty() and not _video_mode:
		for item in windows_provider.call():
			if not item is Dictionary:
				continue
			if bool(item.get("shared", false)) and bool(item.get("visible", true)):
				need = true
				break
	compositor.set_cpu_capture_requested(need)

# Enregistre/libère un consommateur de copie CPU (ex. salve du mode focus).
func set_cpu_capture_consumer(key: String, active: bool) -> void:
	var changed := false
	if active and not cpu_capture_consumers.has(key):
		cpu_capture_consumers[key] = true
		changed = true
	elif not active and cpu_capture_consumers.has(key):
		cpu_capture_consumers.erase(key)
		changed = true
	if changed:
		_update_cpu_capture_request()

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
	var pcm: PackedByteArray = compositor.audio_decode(bytes, from)
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
# textures + _set_remote_quad_texture). Le décodage AVCodec (~2-5 ms en 1080p)
# tourne sur le thread principal : un thread worker appelant video_decoder_feed
# sur le compositor (Node GDExtension) a fait crasher le récepteur.

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
	# Décodage sur le thread PRINCIPAL (retour à la version stable) : un
	# thread worker appelant video_decoder_feed (un Node, GDExtension) depuis
	# une Thread Godot a fait crasher le récepteur pendant le partage vidéo.
	# Le décodage d'une frame (~2-5 ms en 1080p) reste léger tant que
	# l'émetteur n'atteint pas 60 ips ; on le re-déplacera sur un worker
	# quand le flux sera sain (côté C++ de préférence).
	var img: Image = compositor.video_decoder_feed(_video_key(from, wid), data, keyframe)
	if img == null or img.is_empty():
		if not keyframe:
			_request_video_keyframe(from, wid)
		return
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
# damment du mode émetteur local). ACK en lot, purge des chunks, diagnostics.
func _process_video_receiver() -> void:
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
		# Collision active seulement si la fenêtre est visible : `disabled`
		# porte sur la CollisionShape3D enfant (le StaticBody3D n'a pas cette
		# propriété).
		var remote_body2: StaticBody3D = quad.get_node_or_null("RemoteCollision") as StaticBody3D
		if remote_body2 != null:
			var col: CollisionShape3D = remote_body2.get_child(0) as CollisionShape3D
			if col != null:
				col.disabled = not quad.visible
		# SHARE OFF : le quad redevient noir (placeholder) et le décodeur
		# vidéo du flux est libéré. SHARE ON : les frames streamées (rpc
		# _sync_window_texture / _sync_video_frame) textureront le quad.
		if not shared:
			_set_remote_quad_texture(quad, null)
			_reset_video_stream(peer_id, wid)
			_erase_remote_cursor_state(peer_id, wid)
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
			var occ := q.get_node_or_null("Occluder") as OccluderInstance3D
			if occ != null:
				occ.queue_free()
				await get_tree().physics_frame
			q.queue_free()
		quads.erase(wid)
		if _remote_textures.has(peer_id):
			_remote_textures[peer_id].erase(wid)
		if pins != null:
			pins.unpin_remote(peer_id, wid)
		if focus != null:
			focus.handle_remote_window_removed(peer_id, wid)
		_erase_remote_cursor_state(peer_id, wid)
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
	# Occlusion culling : boîte fine plaquée sur le quad (même recette que les
	# fenêtres locales) — le quad noir masque ce qui est derrière lui. Enfant
	# du quad → suit déplacement/rotation sans code par frame ; la taille est
	# tenue à jour par _sync_remote_quad_collision().
	var occ := OccluderInstance3D.new()
	occ.name = "Occluder"
	var occ_box := BoxOccluder3D.new()
	occ_box.size = Vector3(1.0, 1.0, REMOTE_WINDOW_OCCLUDER_DEPTH)
	occ.occluder = occ_box
	quad.add_child(occ)
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
	var occ := quad.get_node_or_null("Occluder") as OccluderInstance3D
	if occ != null and occ.occluder is BoxOccluder3D and quad.mesh is QuadMesh:
		var s2: Vector2 = (quad.mesh as QuadMesh).size
		(occ.occluder as BoxOccluder3D).size = Vector3(s2.x, s2.y, REMOTE_WINDOW_OCCLUDER_DEPTH)

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
	_remote_cursor_state.erase(peer_id)
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

func _erase_remote_cursor_state(peer_id: int, wid: int) -> void:
	if _remote_cursor_state.has(peer_id):
		_remote_cursor_state[peer_id].erase(wid)
		if _remote_cursor_state[peer_id].is_empty():
			_remote_cursor_state.erase(peer_id)
	if focus != null:
		focus.set_remote_cursor_state(peer_id, wid, null)

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
	_scan_generation += 1
	var generation := _scan_generation
	_scan_results.clear()
	_scanner = PacketPeerUDP.new()
	_scanner.set_broadcast_enabled(true)
	if _scanner.bind(0) != OK:
		_scanner.close()
		_scanner = null
		_scanning = false
		_set_status("Network scan error")
		return
	# Requête en unicast sur tout le /24 (fiable, et teste le même chemin
	# réseau que le join) + broadcasts, renvoyés plusieurs fois (UDP non fiable).
	_set_status("Searching for games…")
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
		_set_status("No games found — make sure both PCs are on the same network (firewall, router AP isolation)")
	else:
		_set_status("%d game(s) found" % _scan_results.size())
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
	_sync_cursor_state(_delta)
	# Timeout client : si le PIN n'est pas vérifié à temps, déconnexion.
	if not is_host and _auth_request_sent_msec > 0 and session_active:
		if Time.get_ticks_msec() - _auth_request_sent_msec > AUTH_TIMEOUT_MSEC:
			_lan_log("auth timeout — pas de réponse de l'hôte")
			_set_status("Authentication timeout — host did not respond")
			_disconnect_session()

# Diffuse le curseur du propriétaire pour chaque fenêtre partagée visible :
# position du pointeur (rpc léger non fiable) + image du curseur custom quand
# le client en pose une (rpc rare). Le récepteur affiche ce curseur par-dessus
# l'overlay focus distant de la fenêtre quand le propriétaire le survole.
func _sync_cursor_state(delta: float) -> void:
	if not session_active or _pending_join or multiplayer.get_unique_id() == 0:
		return
	if compositor == null or not compositor.has_method("get_window_pointer"):
		return
	if not windows_provider.is_valid():
		return
	var list: Array = windows_provider.call()
	if list.is_empty():
		return
	_cursor_send_timer += delta
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
		# Position du pointeur (coordonnées surface) → coordonnées du contenu
		# vidéo (la texture partagée est découpée à la window_geometry).
		var ptr: Dictionary = compositor.get_window_pointer(wid)
		var inside: bool = bool(ptr.get("inside", false))
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		var px := float(ptr.get("x", 0.0))
		var py := float(ptr.get("y", 0.0))
		if inside and compositor.has_method("get_window_geometry"):
			var geo: Dictionary = compositor.get_window_geometry(wid)
			px -= float(geo.get("x", 0.0))
			py -= float(geo.get("y", 0.0))
			var cw := float(geo.get("width", 0))
			var ch := float(geo.get("height", 0))
			if cw > 0.0 and ch > 0.0:
				if px < 0.0 or py < 0.0 or px >= cw or py >= ch:
					inside = false
		var last: Dictionary = _last_cursor_pointer_send.get(wid, {})
		var changed := bool(last.get("inside", false)) != inside \
			or bool(last.get("captured", false)) != captured \
			or absf(float(last.get("x", -1e9)) - px) > 0.5 \
			or absf(float(last.get("y", -1e9)) - py) > 0.5
		# Émettre si changement, ou à ~30/s tant que le pointeur est dedans
		# (pour les clients qui se connectent en cours de route).
		if changed or (inside and _cursor_send_timer >= 0.033):
			_last_cursor_pointer_send[wid] = {"inside": inside, "captured": captured, "x": px, "y": py}
			_sync_window_pointer.rpc(wid, inside, captured, px, py)
		# Image du curseur custom (wl_pointer.set_cursor) : seulement quand le
		# client en pose une nouvelle (serial change) ou masque/restaure.
		if compositor.has_method("get_window_cursor"):
			var ci: Dictionary = compositor.get_window_cursor(wid)
			var serial := int(ci.get("serial", -1))
			var hidden := bool(ci.get("hidden", false))
			var last_serial := int(_last_cursor_image_send.get(wid, -2))
			if last_serial != serial:
				_last_cursor_image_send[wid] = serial if not hidden else -1
				var img: Image = ci.get("image")
				var bytes := PackedByteArray()
				var iw := 0
				var ih := 0
				if img != null and not img.is_empty():
					bytes = img.get_data()
					iw = img.get_width()
					ih = img.get_height()
				_sync_window_cursor_image.rpc(wid, serial, hidden,
					int(ci.get("hotspot_x", 0)), int(ci.get("hotspot_y", 0)),
					iw, ih, bytes)
	if _cursor_send_timer >= 0.033:
		_cursor_send_timer = 0.0

# RPC émetteur → récepteurs : position du curseur du propriétaire dans la
# fenêtre (coordonnées du contenu, y vers le bas) + `captured` (le propriétaire
# a capturé sa souris → ne pas afficher de curseur fantôme). Non fiable et
# minuscule.
@rpc("any_peer", "unreliable")
func _sync_window_pointer(wid: int, inside: bool, captured: bool, x: float, y: float) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if wid < 0:
		return
	if not _remote_cursor_state.has(from):
		_remote_cursor_state[from] = {}
	if not _remote_cursor_state[from].has(wid):
		_remote_cursor_state[from][wid] = {
			"inside": false, "captured": false, "x": 0.0, "y": 0.0,
			"serial": -1, "hidden": false,
			"hotspot": Vector2.ZERO, "tex": null,
		}
	var st: Dictionary = _remote_cursor_state[from][wid]
	st["inside"] = inside
	st["captured"] = captured
	st["x"] = x
	st["y"] = y
	if focus != null:
		focus.set_remote_cursor_state(from, wid, st)

# RPC émetteur → récepteurs : image du curseur custom du propriétaire (serial
# change quand le client en pose une nouvelle ; bytes vide si aucun curseur
# custom, ex. curseur système). Rare (≈ curseur posé une fois par app).
@rpc("any_peer", "reliable")
func _sync_window_cursor_image(wid: int, serial: int, hidden: bool, hx: int, hy: int, w: int, h: int, bytes: PackedByteArray) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if wid < 0:
		return
	if not _remote_cursor_state.has(from):
		_remote_cursor_state[from] = {}
	if not _remote_cursor_state[from].has(wid):
		_remote_cursor_state[from][wid] = {
			"inside": false, "captured": false, "x": 0.0, "y": 0.0,
			"serial": -1, "hidden": false,
			"hotspot": Vector2.ZERO, "tex": null,
		}
	var st: Dictionary = _remote_cursor_state[from][wid]
	st["serial"] = serial
	st["hidden"] = hidden
	st["hotspot"] = Vector2(hx, hy)
	st["tex"] = null
	if w > 0 and h > 0 and not bytes.is_empty():
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
		if not img.is_empty():
			st["tex"] = ImageTexture.create_from_image(img)
	if focus != null:
		focus.set_remote_cursor_state(from, wid, st)

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
	_arrived_peers.clear()

func _disconnect_session() -> void:
	_stop_audio_share()
	_stop_video_share()
	_pending_auth.clear()
	_auth_request_sent_msec = 0
	_pin = ""
	_level_send_queue.clear()
	_level_bake_receive.clear()
	_level_baked_cache.clear()
	_host_spawn_transform.clear()
	_avatar_send_queue.clear()
	_avatar_receive_slots.clear()
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
		# Invalider la coroutine discover_games() en attente AVANT de fermer :
		# à son réveil elle verra une génération périmée et n'utilisera pas ce
		# peer (set_dest_address sur un PacketPeerUDP fermé/null = crash).
		_scan_generation += 1
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
	_announced = false
	_avatar_sent_to.clear()
	_avatar_send_cache = PackedByteArray()
	_avatar_send_cache_raw_size = 0
	_avatar_send_scripts_cache = {}
	# Annuler un join en attente (déconnexion pendant le chargement de la
	# map) et dégeler le joueur local.
	_pending_join = false
	if local_player != null and "input_locked" in local_player:
		local_player.input_locked = false
	_players.clear()
	_avatar_blobs.clear()
	_avatar_scene_cache.clear()
	_deferred_level.clear()
	_emit_players()
	# Dernier, une fois les avatars distants libérés et l'état réinitialisé :
	# la restauration recrée le conteneur Players sous le niveau personnel via
	# on_level_swapped().
	local_level_restore_requested.emit()

func _exit_tree() -> void:
	_stop_encode_thread()
	_stop_decode_thread()
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
