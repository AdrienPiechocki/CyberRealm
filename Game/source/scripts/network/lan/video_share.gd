extends Node
## Stream vidéo inter-frame (H.264/AV1, encodeur C++ VideoShare) des fenêtres partagées.
##
## Module de LanManager (nœud enfant « VideoShare »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

# ── Stream vidéo inter-frame (H.264/AV1) ─────────────────────────────
# Remplace le JPEG par-frame : le compositeur rend les fenêtres partagées
# dans des DMA-BUF qu'un encodeur (VAAPI matériel, fallback libx264) convertit
# en flux inter-frame sur un thread worker C++ (VideoShare). Le thread
# principal ne fait que poller les paquets et les diffuser. Les frames sont
# petites (P-frames) mais dépendantes : pas de drop possible (le compositeur
# saute une capture si l'encodeur lit encore le buffer), les keyframes
# resynchronisent.
var _video_bitrate := 6_000_000 # débit cible par fenêtre (bits/s) ; total = n_fenêtres × ceci. 6 Mb/s à 60 ips ≈ 12,5 KB/frame, tenable en LAN et suffisant pour du 1080p fluide
# codecs à essayer, dans cet ordre. h264 VAAPI d'abord : l'encodeur AV1 matériel
# de Mesa est lent/instable sur RDNA3 (le worker VAAPI tombait à ~6 ips alors que
# h264_vaapi encodera confortablement le 1080p à 60 ips). av1 = matériel
# seulement (pas de fallback logiciel). Réglable (menu pause) : ["h264"] / ["av1"]
# / ["h264", "av1"] (auto).
var _video_codec_pref: Array = ["h264", "av1"]
var _video_fps := 60 # cadence d'encodage (10-60) ; divise la charge CPU quand baissée
const VIDEO_PACKET_SINGLE_MAX := 40000 # paquet ≤ ceci : 1 RPC (≤ 32 fragments ENet, 1 vague)
const VIDEO_CHUNK_SIZE := 30000 # au-delà : découpage, chaque morceau ≤ 1 vague ENet
const VIDEO_CHUNK_STALE_MSEC := 2000 # purge des assemblages de chunks incomplets
const VIDEO_MAX_AHEAD := 6 # flow control : ≤ 6 frames non appliquées en vol par peer. À 60 ips (16,7 ms/frame) et ~20 ms de RTT ACK, il faut ≥ 2-3 frames en vol : 6 laisse la marge contre les sursauts réseau sans gonfler la latence
const VIDEO_NACK_GAP_MSEC := 500 # demande de keyframe (NACK) au plus 2×/s par fenêtre

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
	if lan.compositor == null:
		return
	var want := false
	if lan.windows_provider.is_valid():
		for item in lan.windows_provider.call():
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
	if lan.compositor == null or not lan.compositor.has_method("video_share_start"):
		return
	for codec in _video_codec_pref:
		if lan.compositor.video_share_start(codec, _video_bitrate, _video_fps):
			_video_mode = true
			_video_codec = lan.compositor.video_share_codec()
			var hw = lan.compositor.video_share_hardware()
			print("[video] inter-frame sharing started: codec=%s hardware=%s bitrate=%d fps=%d" % [
				_video_codec, "yes" if hw else "no", _video_bitrate, _video_fps])
			return
	print("[video] video encoder unavailable — sharing in JPEG")

func _stop_video_share() -> void:
	if _video_mode and lan.compositor != null and lan.compositor.has_method("video_share_stop"):
		lan.compositor.video_share_stop()
	_video_mode = false
	_video_codec = ""
	_video_windows_sent = PackedInt32Array()
	_video_config_last.clear()
	_video_config_sent.clear()
	_video_last_sent.clear()
	_video_acked.clear()

# Applique les réglages de partage vidéo (menu pause) : bitrate (bits/s),
# codec ("auto" | "h264" | "av1") et fps. Si le partage est actif, il est
# redémarré pour prendre effet immédiatement.
func set_video_settings(bitrate: int, codec: String, fps: int) -> void:
	_video_bitrate = maxi(bitrate, 0)
	_video_fps = clampi(fps, 10, 60)
	match codec:
		"h264", "av1":
			_video_codec_pref = [codec]
		_:
			_video_codec_pref = ["h264", "av1"]
	_compositor_video_restart()

func _compositor_video_restart() -> void:
	if _video_mode and lan.compositor != null and lan.compositor.has_method("video_share_start"):
		_stop_video_share()
		_start_video_share()
		_announce_video_configs(true)
# Maintient l'ensemble des fenêtres partagées envoyé à l'encodeur (C++).
func _update_video_windows() -> void:
	var wids := PackedInt32Array()
	if lan.windows_provider.is_valid():
		for item in lan.windows_provider.call():
			if item is Dictionary \
					and bool(item.get("shared", false)) \
					and bool(item.get("visible", true)):
				wids.append(int(item.get("wid", -1)))
	wids.sort()
	if wids != _video_windows_sent:
		lan.compositor.set_video_share_windows(wids)
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
	if not _video_mode or lan.compositor == null \
			or not lan.compositor.has_method("get_window_geometry"):
		return
	for wid in _video_windows_sent:
		var geo: Dictionary = lan.compositor.get_window_geometry(wid)
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
				print("[video] wid=%d : geometry unavailable (%dx%d) — config deferred" % [wid, w, h])
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
	if not _video_mode or lan.compositor == null or not lan.compositor.has_method("video_share_poll"):
		return
	_check_video_new_peers()
	var packets: Array = lan.compositor.video_share_poll()
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
			print("[video] diag tx: %d pkt/s %.1f KB/s pending=%d windows=%d" % [
				_video_diag_sent, float(_video_diag_bytes) / 1024.0,
				lan.compositor.video_share_pending(), _video_windows_sent.size()])
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
			lan.compositor.video_share_request_keyframe(wid)
		print("[video] peer %d joined : config + keyframes requested (%d window(s))" % [
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
	if lan.window_share_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
	_receive_video_frame(wid, seq, index, total, bytes, false)

# Keyframe : canal 4 fiable (comme le JPEG) → ne se met PAS en file derrière
# le backlog du canal 2 → le récepteur se recalibre immédiatement.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_video_keyframe(wid: int, seq: int, index: int, total: int, bytes: PackedByteArray) -> void:
	if lan.window_share_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
	_receive_video_frame(wid, seq, index, total, bytes, true)

# Config du flux (codec + dimensions pixels) d'une fenêtre d'un peer : permet
# au récepteur de créer son contexte de décodage AVCodec. Reçue aussi sur un
# redémarrage du flux émetteur (les seq repartent de 0) → reset du décodeur.
@rpc("any_peer", "call_remote", "reliable", 4)
func _sync_video_config(wid: int, codec: String, width: int, height: int) -> void:
	if lan.window_share_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if (codec != "h264" and codec != "av1") or width <= 0 or height <= 0:
		return
	if lan.compositor == null or not lan.compositor.has_method("video_decoder_configure"):
		return
	# Toujours recréer le décodeur : une config (même identique) signale aussi
	# un redémarrage du flux émetteur → les seq repartent de 0 et seules les
	# keyframes suivantes sont décodables.
	if not _video_configs.has(from):
		_video_configs[from] = {}
	_video_configs[from][wid] = {"codec": codec, "w": width, "h": height}
	lan.compositor.video_decoder_configure(_video_key(from, wid), codec, width, height)
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
	if lan.window_share_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if _video_mode and lan.compositor != null and lan.compositor.has_method("video_share_request_keyframe"):
		lan.compositor.video_share_request_keyframe(wid)

# ACK du récepteur : dernières seq appliquées par fenêtre (petits, fiables,
# canal 5 dédié comme l'ACK JPEG → pas de file derrière les gros RPC).
@rpc("any_peer", "call_remote", "reliable", 5)
func _ack_video_seq(seqs: Dictionary) -> void:
	if lan.window_share_restricted():
		return      # vue des fenêtres coupée (session par code d'invitation non approuvée)
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
	if lan.compositor == null or not lan.compositor.has_method("video_decoder_feed"):
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
	var img: Image = lan.compositor.video_decoder_feed(_video_key(from, wid), data, keyframe)
	if img == null or img.is_empty():
		if not keyframe:
			_request_video_keyframe(from, wid)
		return
	if not _video_applied.has(from):
		_video_applied[from] = {}
	_video_applied[from][wid] = seq
	var tex: Texture2D = lan.window_share._make_or_update_remote_texture(from, wid, img)
	# Bufferiser la texture même si l'état `shared` n'est pas encore arrivé
	# (course 1re frame vs état) : _apply_remote_windows la réappliquera.
	if not lan.window_share._pending_remote_textures.has(from):
		lan.window_share._pending_remote_textures[from] = {}
	lan.window_share._pending_remote_textures[from][wid] = tex
	if lan.window_share._remote_window_quads.has(from) and lan.window_share._remote_window_quads[from].has(wid):
		lan.window_share._set_remote_quad_texture(lan.window_share._remote_window_quads[from][wid], tex)
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
			print("[video] diag rx: applied/s=%d" % _video_diag_applied)
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
	if lan.compositor != null and lan.compositor.has_method("video_decoder_reset"):
		lan.compositor.video_decoder_reset(_video_key(from, wid))
	if _video_configs.has(from):
		_video_configs[from].erase(wid)
	if _video_applied.has(from):
		_video_applied[from].erase(wid)
	if _video_chunks.has(from):
		_video_chunks[from].erase(wid)
	if _video_nack_last.has(from):
		_video_nack_last[from].erase(wid)
