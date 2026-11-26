extends Node
## Chat vocal côté joueur : micro, appuyer pour parler / activation vocale, restitution spatialisée.
##
## Le micro n'est ouvert que pendant une session multijoueur et si un mode est choisi (menu pause > Multiplayer,
## désactivé par défaut). Trames OPUS de 20 ms (compositeur : voice_poll) envoyées par scripts/network/lan/voice.gd ;
## à la réception, décodage par interlocuteur (voice_decode) et lecture par un AudioStreamPlayer3D accroché à son
## avatar (atténuation avec la distance), ou un lecteur 2D si la voix spatialisée est coupée. Bus audio « Voice ».
## Indicateur de parole : 🔊 devant le nom de l'avatar tant que ses trames arrivent.

const VAD_HANGOVER_MSEC := 300   # l'activation vocale reste ouverte après la dernière trame forte (fins de mots)
const SPEAKING_MSEC := 300       # sans trame depuis ce délai : l'interlocuteur ne parle plus
const BUFFER_SEC := 0.25
const MAX_DISTANCE := 25.0
const MicSources := preload("res://scripts/main/mic_sources.gd")
const BUS := "Voice"

var compositor: Object = null
var lan: Node = null
var settings: Node = null                # pause_menu : get_voice_mode(), …
var avatar_for := Callable()             # Callable(peer_id) -> Node (avatar) ou null
var can_push_to_talk := Callable()       # Callable() -> bool : appuyer pour parler possible (pas de chat, pas de focus)

var volumes: Dictionary = {}             # peer -> volume linéaire (0..2), 1 par défaut
var muted: Dictionary = {}               # peer -> true : voix coupée (local)

var _mic_target := "<closed>"            # cible du micro ouverte ("" = source par défaut)
var _seq := 0
var _last_loud := -100000
var _players: Dictionary = {}            # peer -> {player, playback, spatial}
var _last_heard: Dictionary = {}         # peer -> ms
var _speaking_shown: Dictionary = {}     # peer -> bool
var local_speaking := false
## Test du micro (page Multiplayer du menu pause ouverte) : le micro s'ouvre même hors session, rien n'est envoyé.
var mic_test := false
## Niveau du micro (rms des dernières trames, retombe doucement) : indicateur de la page Multiplayer.
var mic_level := 0.0
## Annulation d'écho demandée mais module echo-cancel absent : le micro choisi est utilisé à la place.
var echo_cancel_missing := false
## Sources micro PipeWire (remplacé dans les tests) : voir MicSources.list_sources.
var sources_provider := func() -> Array: return MicSources.list_sources()
var _target_key := ""                    # réglages (écho, micro) qui ont donné _target
var _target := ""
var _target_msec := -100000
# Diagnostic (CYBERREALM_VOICE_DEBUG=1), une ligne par seconde : envoi (trames, volume moyen du micro) et, par
# interlocuteur, réception (trames, décodées, refusées, volume moyen décodé, lecteur 2D/3D, distance, bus).
var _dbg := OS.get_environment("CYBERREALM_VOICE_DEBUG") == "1"
var _dbg_t := 0
var _dbg_tx := {"n": 0, "rms": 0.0, "polled": 0}
var _dbg_rx: Dictionary = {}             # peer -> {n, dec, empty, refused, rms}

func setup(p_compositor: Object, p_lan: Node, p_settings: Node) -> void:
	compositor = p_compositor
	lan = p_lan
	settings = p_settings
	lan.voice.voice_packet.connect(_on_packet)
	lan.session_state_changed.connect(func(active: bool):
		if not active:
			_clear_players())
	_ensure_bus()

func _exit_tree() -> void:
	_close_mic()

# ── Micro et envoi ─────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_ensure_bus()
	var mode := String(settings.get_voice_mode())
	var in_session: bool = lan.is_session_active() and mode != "off" and not lan.voice.disabled
	var testing: bool = mic_test and bool(settings.get("visible"))
	var want := in_session or testing
	var target := _voice_target() if want else _mic_target
	if want and _mic_target != target:
		_close_mic()
		if compositor.voice_start(target):
			_mic_target = target
	elif not want and _mic_target != "<closed>":
		_close_mic()
	local_speaking = false
	if _mic_target == "<closed>":
		mic_level = 0.0
	else:
		var now := Time.get_ticks_msec()
		var threshold := float(settings.get_voice_vad_threshold())
		var ptt: bool = mode == "ptt" and Input.is_action_pressed("push_to_talk") \
				and (not can_push_to_talk.is_valid() or bool(can_push_to_talk.call()))
		mic_level *= exp(-delta * 6.0)       # retombe en ~0,5 s, quelle que soit la cadence d'affichage
		for frame in compositor.voice_poll():
			if _dbg:
				_dbg_tx["polled"] += 1
			mic_level = maxf(mic_level, float(frame["rms"]))
			if not in_session:
				continue                 # test du micro hors session : niveau seulement, rien n'est envoyé
			var send := false
			if mode == "ptt":
				send = ptt
			elif mode == "vad":
				if float(frame["rms"]) >= threshold:
					_last_loud = now
				send = now - _last_loud <= VAD_HANGOVER_MSEC
			if send:
				_seq += 1
				lan.voice.send(_seq, frame["data"])
				local_speaking = true
				if _dbg:
					_dbg_tx["n"] += 1
					_dbg_tx["rms"] += float(frame["rms"])
	_update_speaking()
	if _dbg:
		_dbg_print(mode)

func _dbg_print(mode: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _dbg_t < 1000:
		return
	_dbg_t = now
	if _dbg_tx["polled"] > 0 or _dbg_tx["n"] > 0:
		print("[voice tx] mode=%s mic=%s polled=%d sent=%d mic_rms=%.4f" % [mode, _mic_target, _dbg_tx["polled"],
				_dbg_tx["n"], _dbg_tx["rms"] / maxf(_dbg_tx["n"], 1)])
	_dbg_tx = {"n": 0, "rms": 0.0, "polled": 0}
	var bus := AudioServer.get_bus_index(BUS)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	for peer in _dbg_rx:
		var d: Dictionary = _dbg_rx[peer]
		var e: Dictionary = _players.get(peer, {})
		var kind := "none"
		var dist := -1.0
		var playing := false
		if not e.is_empty() and is_instance_valid(e["player"]):
			kind = "3d" if bool(e["spatial"]) else "2d"
			playing = bool(e["player"].get("playing"))
			if e["player"] is Node3D and cam != null:
				dist = (e["player"] as Node3D).global_position.distance_to(cam.global_position)
		print("[voice rx %d] recv=%d played=%d empty=%d refused=%d rms=%.4f player=%s playing=%s dist=%.1f vol=%.2f muted=%s bus=%d bus_db=%.1f bus_mute=%s paused=%s" % [
				peer, d["n"], d["dec"], d["empty"], d["refused"], d["rms"] / maxf(d["dec"], 1), kind, playing, dist,
				float(volumes.get(peer, 1.0)), muted.has(peer), bus,
				AudioServer.get_bus_volume_db(bus) if bus >= 0 else 0.0, AudioServer.is_bus_mute(bus) if bus >= 0 else false,
				get_tree().paused if is_inside_tree() else false])
	_dbg_rx.clear()

## Cible du micro (MicSources.voice_target), recalculée quand les réglages changent et au plus toutes les 5 s (la
## liste des sources vient de pw-dump : jamais à chaque frame).
func _voice_target() -> String:
	var echo := bool(settings.is_voice_echo_cancel())
	var chosen := String(settings.get_voice_mic()) if settings.has_method("get_voice_mic") else ""
	var key := "%s|%s" % [echo, chosen]
	var now := Time.get_ticks_msec()
	if key == _target_key and now - _target_msec < 5000:
		return _target
	var sources: Array = sources_provider.call()
	var missing := echo and not MicSources.echo_cancel_available(sources)
	if missing and not echo_cancel_missing:
		push_warning("voice: annulation d'écho demandée mais le module echo-cancel de PipeWire est absent — micro choisi utilisé")
	echo_cancel_missing = missing
	_target = MicSources.voice_target(echo, chosen, sources)
	_target_key = key
	_target_msec = now
	return _target

func _close_mic() -> void:
	if compositor != null and _mic_target != "<closed>":
		compositor.voice_stop()
	_mic_target = "<closed>"

# ── Réception ──────────────────────────────────────────────────────────

func _on_packet(from_id: int, seq: int, data: PackedByteArray) -> void:
	_last_heard[from_id] = Time.get_ticks_msec()
	if muted.has(from_id):
		return
	var pcm: PackedVector2Array = compositor.voice_decode(from_id, seq, data)
	var d: Dictionary = {}
	if _dbg:
		d = _dbg_rx.get(from_id, {"n": 0, "dec": 0, "empty": 0, "refused": 0, "rms": 0.0})
		_dbg_rx[from_id] = d
		d["n"] += 1
	if pcm.is_empty():
		if _dbg:
			d["empty"] += 1
		return
	var pb := _playback_for(from_id)
	if pb != null and pb.can_push_buffer(pcm.size()):
		pb.push_buffer(pcm)
		if _dbg:
			d["dec"] += 1
			var sum := 0.0
			for v in pcm:
				sum += v.x * v.x
			d["rms"] += sqrt(sum / pcm.size())
	elif _dbg:
		d["refused"] += 1

func _playback_for(peer: int) -> AudioStreamGeneratorPlayback:
	var spatial := bool(settings.is_voice_spatial())
	var av: Variant = avatar_for.call(peer) if avatar_for.is_valid() else null
	var has_av: bool = av != null and is_instance_valid(av) and av is Node3D
	var e: Dictionary = _players.get(peer, {})
	var want_spatial := spatial and has_av
	if not e.is_empty() and (not is_instance_valid(e["player"]) or bool(e["spatial"]) != want_spatial
			or (want_spatial and (e["player"] as Node).get_parent() != av)):
		_free_player(peer)
		e = {}
	if e.is_empty():
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = 48000
		gen.buffer_length = BUFFER_SEC
		var player: Node
		if want_spatial:
			var p3 := AudioStreamPlayer3D.new()
			p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			p3.unit_size = 3.0
			p3.max_distance = MAX_DISTANCE
			p3.position = (av as Node).call("voice_anchor") if (av as Node).has_method("voice_anchor") else Vector3(0, 1.6, 0)
			p3.stream = gen
			p3.bus = BUS
			(av as Node).add_child(p3)
			player = p3
		else:
			var p2 := AudioStreamPlayer.new()
			p2.stream = gen
			p2.bus = BUS
			add_child(p2)
			player = p2
		player.call("play")
		e = {"player": player, "playback": player.call("get_stream_playback"), "spatial": want_spatial}
		_players[peer] = e
	_apply_volume(peer)
	return e["playback"] as AudioStreamGeneratorPlayback

func _apply_volume(peer: int) -> void:
	var e: Dictionary = _players.get(peer, {})
	if e.is_empty() or not is_instance_valid(e["player"]):
		return
	var v := float(volumes.get(peer, 1.0))
	e["player"].set("volume_db", linear_to_db(maxf(v, 0.0001)))

func set_volume(peer: int, v: float) -> void:
	volumes[peer] = clampf(v, 0.0, 2.0)
	_apply_volume(peer)

func set_muted(peer: int, on: bool) -> void:
	if on:
		muted[peer] = true
	else:
		muted.erase(peer)

func forget_peer(peer: int) -> void:
	_free_player(peer)
	_last_heard.erase(peer)
	_speaking_shown.erase(peer)
	if compositor != null:
		compositor.voice_forget(peer)

func _free_player(peer: int) -> void:
	var e: Dictionary = _players.get(peer, {})
	if not e.is_empty() and is_instance_valid(e["player"]):
		(e["player"] as Node).queue_free()
	_players.erase(peer)

func _clear_players() -> void:
	for peer in _players.keys():
		forget_peer(int(peer))

## 🔊 devant le nom des joueurs qui parlent (trames reçues récemment, voix non coupée).
func _update_speaking() -> void:
	var now := Time.get_ticks_msec()
	for peer in _last_heard:
		var on: bool = now - int(_last_heard[peer]) < SPEAKING_MSEC and not muted.has(peer)
		if bool(_speaking_shown.get(peer, false)) == on:
			continue
		_speaking_shown[peer] = on
		var av: Variant = avatar_for.call(peer) if avatar_for.is_valid() else null
		if av != null and is_instance_valid(av) and av.has_method("set_speaking"):
			av.set_speaking(on)

func is_speaking(peer: int) -> bool:
	return bool(_speaking_shown.get(peer, false))

func _ensure_bus() -> void:
	var idx := AudioServer.get_bus_index(BUS)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS)
		AudioServer.set_bus_send(idx, "Master")
	var v := float(settings.get_voice_volume()) if settings != null else 1.0
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
