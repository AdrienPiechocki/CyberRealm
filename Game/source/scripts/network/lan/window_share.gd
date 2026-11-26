extends Node
## Fenêtres partagées : état des fenêtres, stream JPEG (encodage/décodage threadés), quads
## distants, curseur du propriétaire.
##
## Module de LanManager (nœud enfant « WindowShare »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

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
	if lan.compositor == null or not lan.compositor.has_method("set_cpu_capture_requested"):
		return
	var need := not cpu_capture_consumers.is_empty()
	if not need and LanManager.session_active and not lan._pending_join and lan.windows_provider.is_valid() and not multiplayer.get_peers().is_empty() and not lan.video_share._video_mode:
		for item in lan.windows_provider.call():
			if not item is Dictionary:
				continue
			if bool(item.get("shared", false)) and bool(item.get("visible", true)):
				need = true
				break
	lan.compositor.set_cpu_capture_requested(need)

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
	if LanManager.session_active:
		_windows_dirty = true

# Envoie l'état complet des fenêtres locales : immédiatement après un
# changement d'état, à haute cadence pendant un déplacement/redimensionnement,
# et périodiquement pour auto-réparer les paquets perdus (RPC unreliable).
func _sync_windows_state(delta: float) -> void:
	if not lan.windows_provider.is_valid():
		return
	var moving := false
	if lan.windows_moving_provider.is_valid():
		moving = bool(lan.windows_moving_provider.call())
	var gap := WINDOW_SYNC_GAP
	if moving:
		gap = WINDOW_SYNC_MOVE_GAP
	elif _windows_dirty:
		gap = 0.0
	_last_windows_send += delta
	if _last_windows_send < gap:
		return
	var list: Array = lan.windows_provider.call()
	# Rien à dire (aucune fenêtre, pas de changement en attente) : on n'envoie
	# pas de paquet vide périodique. Un changement d'état (dirty) part toujours.
	if list.is_empty() and not moving and not _windows_dirty:
		return
	_last_windows_send = 0.0
	_windows_dirty = false
	_sync_windows.rpc(list)

@rpc("any_peer", "unreliable")
func _sync_windows(windows: Array) -> void:
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
	if lan.video_share._video_mode:
		return # remplacé par le stream vidéo inter-frame (VideoShare C++)
	_last_windows_texture_send += delta
	if _last_windows_texture_send < WINDOW_TEXTURE_GAP:
		return
	_last_windows_texture_send = 0.0
	if not lan.windows_provider.is_valid() or not lan.window_image_provider.is_valid() or not lan.window_version_provider.is_valid():
		return
	var list: Array = lan.windows_provider.call()
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
		var version := int(lan.window_version_provider.call(wid))
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
		var img: Image = lan.window_image_provider.call(wid)
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
	if not lan.windows_provider.is_valid():
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
		print("[lan] diag tx: age=%dms enc=%dms rtt=%dms (n=%d) gap=%d send/s=%.1f bytes=%d" % [
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
		print("[lan] diag rx: applied/s=%d decode_q=%d rx_proc=%dms" % [
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
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
	_receive_share_frame(wid, version, bytes, false)

# Keyframe (seek / saut de contenu / keyframe périodique) : canal 4 fiable,
# indépendant du canal 2 → ne se met PAS en file derrière les frames pré-seek
# encore en transit. Le récepteur se recalibre immédiatement dessus : il
# ignore alors toute frame de version antérieure encore en file de décodage.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_window_keyframe(wid: int, version: int, bytes: PackedByteArray) -> void:
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
			lan.video_share._reset_video_stream(peer_id, wid)
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
		if lan.pins != null:
			lan.pins.unpin_remote(peer_id, wid)
		if lan.focus != null:
			lan.focus.handle_remote_window_removed(peer_id, wid)
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
			if lan.pins != null:
				lan.pins.on_remote_texture_updated(peer, wid, tex)
			if lan.focus != null:
				lan.focus.on_remote_texture_updated(peer, wid, tex)

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
	if lan.compositor != null and lan.compositor.has_method("video_decoder_reset"):
		if lan.video_share._video_configs.has(peer_id):
			for wid in lan.video_share._video_configs[peer_id]:
				lan.compositor.video_decoder_reset(lan.video_share._video_key(peer_id, wid))
	lan.video_share._video_configs.erase(peer_id)
	lan.video_share._video_applied.erase(peer_id)
	lan.video_share._video_chunks.erase(peer_id)
	lan.video_share._video_nack_last.erase(peer_id)
	lan.video_share._video_ack_pending.erase(peer_id)
	if lan.pins != null:
		lan.pins.unpin_peer(peer_id)
	if lan.focus != null:
		lan.focus.handle_peer_removed(peer_id)

func _erase_remote_cursor_state(peer_id: int, wid: int) -> void:
	if _remote_cursor_state.has(peer_id):
		_remote_cursor_state[peer_id].erase(wid)
		if _remote_cursor_state[peer_id].is_empty():
			_remote_cursor_state.erase(peer_id)
	if lan.focus != null:
		lan.focus.set_remote_cursor_state(peer_id, wid, null)

func _clear_all_remote_windows() -> void:
	for peer_id in _remote_windows.keys().duplicate():
		_clear_remote_windows(peer_id)
	_last_texture_versions.clear()
	_last_applied_version.clear()
	_last_acked_version.clear()

# Diffuse le curseur du propriétaire pour chaque fenêtre partagée visible :
# position du pointeur (rpc léger non fiable) + image du curseur custom quand
# le client en pose une (rpc rare). Le récepteur affiche ce curseur par-dessus
# l'overlay focus distant de la fenêtre quand le propriétaire le survole.
func _sync_cursor_state(delta: float) -> void:
	if not LanManager.session_active or lan._pending_join or multiplayer.get_unique_id() == 0:
		return
	if lan.compositor == null or not lan.compositor.has_method("get_window_pointer"):
		return
	if not lan.windows_provider.is_valid():
		return
	var list: Array = lan.windows_provider.call()
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
		var ptr: Dictionary = lan.compositor.get_window_pointer(wid)
		var inside: bool = bool(ptr.get("inside", false))
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		var px := float(ptr.get("x", 0.0))
		var py := float(ptr.get("y", 0.0))
		if inside and lan.compositor.has_method("get_window_geometry"):
			var geo: Dictionary = lan.compositor.get_window_geometry(wid)
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
		if lan.compositor.has_method("get_window_cursor"):
			var ci: Dictionary = lan.compositor.get_window_cursor(wid)
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
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
	if lan.focus != null:
		lan.focus.set_remote_cursor_state(from, wid, st)

# RPC émetteur → récepteurs : image du curseur custom du propriétaire (serial
# change quand le client en pose une nouvelle ; bytes vide si aucun curseur
# custom, ex. curseur système). Rare (≈ curseur posé une fois par app).
@rpc("any_peer", "reliable")
func _sync_window_cursor_image(wid: int, serial: int, hidden: bool, hx: int, hy: int, w: int, h: int, bytes: PackedByteArray) -> void:
	if lan.window_view_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
	if lan.focus != null:
		lan.focus.set_remote_cursor_state(from, wid, st)
