extends Node
## Audio des fenêtres partagées : capture (émetteur) et lecture (récepteur).
##
## Module de LanManager (nœud enfant « AudioShare »), créé par la façade : l'état partagé vit dans la façade
## (`lan`), l'état propre au module vit ici.

var lan: LanManager = null

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

# ── Audio partagé : capture (émetteur) + lecture (récepteur) ──────────

# Active/arrête la capture audio selon qu'il existe au moins une fenêtre
# locale partagée ET visible (même condition que le stream vidéo), puis
# envoie les paquets OPUS disponibles sur le canal 3 (non fiable).
# Depuis la capture « fenêtres seules » : on transmet au compositeur les PIDs
# des fenêtres partagées, seules leurs applications audio sont capturées.
func _sync_audio_state() -> void:
	if lan.compositor == null:
		return
	var want := false
	var pids: Array = []
	if lan.windows_provider.is_valid():
		for item in lan.windows_provider.call():
			if item is Dictionary \
					and bool(item.get("shared", false)) \
					and bool(item.get("visible", true)):
				want = true
				var pid := int(item.get("pid", -1))
				if pid > 0 and not pids.has(pid):
					pids.append(pid)
	if want and not _audio_active:
		_audio_share_pids = pids
		if lan.compositor.start_audio_share():
			lan.compositor.set_audio_share_pids(pids)
			_audio_active = true
			_audio_start_msec = Time.get_ticks_msec()
			_audio_send_count = 0
			_audio_no_data_warned = false
			print("[audio] capture started (audio of shared windows: %s)" % str(pids))
	elif want:
		# L'ensemble des fenêtres partagées a pu changer : on resynchronise.
		if pids != _audio_share_pids:
			_audio_share_pids = pids
			lan.compositor.set_audio_share_pids(pids)
			print("[audio] audio targets updated: %s" % str(pids))
	elif not want and _audio_active:
		lan.compositor.stop_audio_share()
		_audio_active = false
		_audio_share_pids = []
		_audio_send_count = 0
		_audio_no_data_warned = false
		print("[audio] capture stopped")
	if not _audio_active:
		return
	# Un seul poll par frame (~60/s pour ~50 paquets/s de 20 ms) : le paquet
	# est diffusé à tous les peers (un poll par peer alternerait les paquets
	# entre eux et diviserait la cadence effective par peer).
	var packet: Dictionary = lan.compositor.poll_audio_packet()
	if packet.is_empty():
		# Diagnostique : capture active mais aucun paquet OPUS produit.
		if _audio_send_count == 0 and not _audio_no_data_warned \
				and Time.get_ticks_msec() - _audio_start_msec > 3000:
			_audio_no_data_warned = true
			push_warning("[audio] capture active but no OPUS packet (PipeWire stream not connected?)")
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
	if lan.online_restricted():
		return      # partage de fenêtres / audio / vidéo coupé en session en ligne
	var from := multiplayer.get_remote_sender_id()
	if from == 0 or from == multiplayer.get_unique_id():
		return
	if bytes.is_empty() or lan.compositor == null:
		return
	var pcm: PackedByteArray = lan.compositor.audio_decode(bytes, from)
	if pcm.is_empty():
		if not _audio_decode_warned:
			_audio_decode_warned = true
			push_warning("[audio] packets received but OPUS decoding empty")
		return
	_audio_received_count += 1
	if not _audio_first_printed:
		_audio_first_printed = true
		print("[audio] first packet received and decoded (%d frames)" % (pcm.size() / 4))
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
	if _audio_active and lan.compositor != null:
		lan.compositor.stop_audio_share()
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
