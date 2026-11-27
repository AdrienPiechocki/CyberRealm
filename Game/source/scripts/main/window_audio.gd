extends Node
## Son des fenêtres : spatialisé localement (option) et partagé par fenêtre en multijoueur.
##
## Option « Son des fenêtres » (menu pause > General) :
##  - Normal (défaut) : les apps jouent directement sur la sortie du système ;
##  - Spatialisé : le jeu crée la sortie muette « cyberrealm-spatial ». Les apps qu'il lance (PULSE_SINK, voir
##    WlrCompositor.set_app_env et cyberrealm-launch) y basculent d'elles-mêmes ; le jeu capture leur son (par PID)
##    et le rejoue depuis le quad de leur fenêtre (AudioStreamPlayer3D). Seules les apps réellement reliées à cette
##    sortie sont rejouées : une app qui joue encore directement n'est jamais entendue deux fois. Son d'une app sans
##    fenêtre : celui de la fenêtre de son ancêtre (un `paplay` lancé dans un terminal sort du terminal), sinon en 2D.
##    Fenêtre en mode focus : 2D à plein volume ; cachée : 2D atténuée ; épinglée (PiP) : 2D.
## En multijoueur, le son des fenêtres partagées est envoyé fenêtre par fenêtre (scripts/network/lan/audio_share.gd).
## Chez les autres, il suit leur propre option : depuis le quad distant en mode spatialisé, en 2D sinon.

const BUS := "Windows"
const BUFFER_SEC := 0.3
# Tampon de gigue du son distant (paquets OPUS de 20 ms, non fiables, relayés par
# le serveur) : sans coussin, le moindre retard réseau vidait le générateur → craquements.
# Silence d'amorce au démarrage, et à nouveau après chaque sous-alimentation (skips).
const REMOTE_PREBUFFER_SEC := 0.1
const REMOTE_REFILL_SEC := 0.06
const MAX_DISTANCE := 30.0
const HIDDEN_DB := -6.0
const ANCESTOR_DEPTH := 8
const REFRESH_SEC := 0.5
const OWNER_CACHE_MSEC := 2000

var compositor: Object = null
var win3d: Node = null
var focus: Node = null
var pins: Node = null
var lan: Node = null
var settings: Node = null                # pause_menu : get_window_audio_mode()

var _spatial := false
var _capture_on := false
var _targets: Array = []
var _routed: Dictionary = {}             # pid -> true : app reliée à la sortie muette
var _pid_wids: Dictionary = {}           # pid -> [wid] (fenêtres locales)
var _owner_cache: Dictionary = {}        # pid -> {wid, t}
var _last_owner: Dictionary = {}         # pid -> wid (dernière fenêtre de ce PID qui avait le focus)
var _players: Dictionary = {}            # clé -> {player, playback, mode}
var _refresh_cd := 0.0

func setup(p_compositor: Object, p_win3d: Node, p_focus: Node, p_pins: Node, p_lan: Node, p_settings: Node) -> void:
	compositor = p_compositor
	win3d = p_win3d
	focus = p_focus
	pins = p_pins
	lan = p_lan
	settings = p_settings
	lan.audio_share.window_audio_received.connect(_on_remote_audio)
	lan.audio_share.playout_delay_provider = remote_playout_msec
	_ensure_bus()

func _exit_tree() -> void:
	if compositor != null and _spatial:
		compositor.audio_set_spatial_sink(false)

func on_window_unmapped(wid: int) -> void:
	_free_player("l:%d" % wid)
	if compositor != null:
		compositor.audio_forget_encoder(wid)

# ── Boucle ─────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var spatial := String(settings.get_window_audio_mode()) == "spatial"
	if spatial != _spatial:
		_spatial = spatial
		compositor.audio_set_spatial_sink(spatial)
		if not spatial:
			_free_local_players()
	_refresh_cd -= delta
	if _refresh_cd <= 0.0:
		_refresh_cd = REFRESH_SEC
		_refresh_targets()
	if not _capture_on:
		return
	var share_ok := _share_ok()
	var data: Dictionary = compositor.audio_drain_pcm()
	for pid in data:
		var frames: PackedVector2Array = data[pid]
		if frames.is_empty():
			continue
		var wid := _owner_of(int(pid))
		if _spatial and _routed.has(int(pid)):
			_play_local(int(pid), wid, frames)
		if share_ok and wid != -1 and win3d.is_window_shared(wid) and _visible(wid):
			lan.audio_share.send_window_audio(wid, compositor.audio_encode(wid, frames))

func _share_ok() -> bool:
	return lan != null and lan.is_session_active() and not lan.window_share_restricted()

func _visible(wid: int) -> bool:
	var q = win3d.quads.get(wid)
	return q != null and is_instance_valid(q) and q.visible

## Qui capturer : en mode spatialisé, toutes les apps reliées à la sortie muette ; en session, les apps des fenêtres
## partagées (et leurs descendants qui jouent du son).
func _refresh_targets() -> void:
	_pid_wids.clear()
	for wid in win3d.quads:
		var pid := int(compositor.get_window_pid(wid))
		if pid > 0:
			if not _pid_wids.has(pid):
				_pid_wids[pid] = []
			_pid_wids[pid].append(int(wid))
	_owner_cache.clear()
	var targets: Array = []
	_routed.clear()
	if _capture_on or _spatial:
		for pid in compositor.audio_routed_pids():
			_routed[int(pid)] = true
			if _spatial:
				targets.append(int(pid))
	if _share_ok():
		var audio: Array = Array(compositor.audio_pids()) if _capture_on else []
		for pid in _pid_wids:
			for wid in _pid_wids[pid]:
				if win3d.is_window_shared(wid) and _visible(wid) and not targets.has(pid):
					targets.append(pid)
					for apid in audio:
						if not targets.has(apid) and _owner_of(int(apid)) == wid:
							targets.append(int(apid))
	targets.sort()
	var need := _spatial or not targets.is_empty()
	if need and not _capture_on:
		_capture_on = compositor.start_audio_share()
	elif not need and _capture_on:
		compositor.stop_audio_share()
		_capture_on = false
		_free_local_players()
	if _capture_on and targets != _targets:
		compositor.set_audio_share_pids(targets)
	_targets = targets

## Fenêtre d'où sort le son d'un PID : sa fenêtre (la dernière qui a eu le focus s'il en a plusieurs), sinon celle
## de son ancêtre le plus proche (app lancée depuis un terminal), sinon -1.
func _owner_of(pid: int) -> int:
	var now := Time.get_ticks_msec()
	var c: Dictionary = _owner_cache.get(pid, {})
	if not c.is_empty() and now - int(c["t"]) < OWNER_CACHE_MSEC:
		return _pick(int(c["root"]))
	var root := -1
	var p := pid
	for i in ANCESTOR_DEPTH:
		if _pid_wids.has(p):
			root = p
			break
		var info: Dictionary = compositor.get_process_info(p)
		p = int(info.get("ppid", -1))
		if p <= 1:
			break
	_owner_cache[pid] = {"root": root, "t": now}
	return _pick(root)

func _pick(root_pid: int) -> int:
	if root_pid <= 0 or not _pid_wids.has(root_pid):
		return -1
	var wids: Array = _pid_wids[root_pid]
	var fw := int(focus.get_focus_window_id()) if focus.is_active() and not focus.is_remote() else -1
	if wids.has(fw):
		return fw
	var hovered := int(win3d.get("focused_window_id"))
	if wids.has(hovered):
		_last_owner[root_pid] = hovered
		return hovered
	var last := int(_last_owner.get(root_pid, -1))
	return last if wids.has(last) else int(wids[0])

# ── Lecture ────────────────────────────────────────────────────────────

func _play_local(pid: int, wid: int, frames: PackedVector2Array) -> void:
	if wid == -1:
		_push("p:%d" % pid, null, "2d", 0.0, frames)
		return
	var quad = win3d.quads.get(wid)
	if quad == null or not is_instance_valid(quad):
		_push("p:%d" % pid, null, "2d", 0.0, frames)
		return
	if focus.is_active() and not focus.is_remote() and int(focus.get_focus_window_id()) == wid:
		_push("l:%d" % wid, null, "2d", 0.0, frames)
	elif not quad.visible:
		_push("l:%d" % wid, null, "2d", HIDDEN_DB, frames)
	elif pins.is_pinned(wid):
		_push("l:%d" % wid, null, "2d", 0.0, frames)
	else:
		_push("l:%d" % wid, quad, "3d", 0.0, frames)

func _on_remote_audio(from_id: int, wid: int, frames: PackedVector2Array) -> void:
	var quad = null
	if lan.window_share != null:
		quad = (lan.window_share._remote_window_quads.get(from_id, {}) as Dictionary).get(wid)
	var key := "r:%d:%d" % [from_id, wid]
	var in_remote_focus: bool = focus.is_active() and focus.is_remote() \
			and int(focus.get_remote_peer()) == from_id and int(focus.get_remote_wid()) == wid
	if _spatial and quad != null and is_instance_valid(quad) and not in_remote_focus:
		_push(key, quad, "3d", 0.0, frames)
	else:
		_push(key, null, "2d", 0.0, frames)

## Pousse des échantillons vers le lecteur `key` (créé ou recréé si son mode / son support change).
func _push(key: String, quad: Node3D, mode: String, db: float, frames: PackedVector2Array) -> void:
	var e: Dictionary = _players.get(key, {})
	var parent: Node = quad if mode == "3d" else self
	if not e.is_empty() and (not is_instance_valid(e["player"]) or e["mode"] != mode
			or (e["player"] as Node).get_parent() != parent):
		_free_player(key)
		e = {}
	if e.is_empty():
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = 48000
		gen.buffer_length = BUFFER_SEC
		var player: Node
		if mode == "3d":
			var p3 := AudioStreamPlayer3D.new()
			p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			p3.unit_size = 4.0
			p3.max_distance = MAX_DISTANCE
			player = p3
		else:
			player = AudioStreamPlayer.new()
		player.set("stream", gen)
		player.set("bus", BUS)
		parent.add_child(player)
		player.call("play")
		e = {"player": player, "playback": player.call("get_stream_playback"), "mode": mode, "skips": 0}
		_players[key] = e
		if key.begins_with("r:"):
			var pbc := e["playback"] as AudioStreamGeneratorPlayback
			if pbc != null:
				e["capacity"] = pbc.get_frames_available() # tampon vide : sa contenance
			_push_silence(e, REMOTE_PREBUFFER_SEC)
			var pb0 := e["playback"] as AudioStreamGeneratorPlayback
			if pb0 != null:
				e["skips"] = pb0.get_skips()
	e["player"].set("volume_db", db)
	var pb := e["playback"] as AudioStreamGeneratorPlayback
	if pb == null:
		return
	if key.begins_with("r:"):
		var skips := pb.get_skips()
		if skips != int(e.get("skips", 0)):
			# Le générateur a manqué d'échantillons : reconstituer un coussin.
			e["skips"] = skips
			_push_silence(e, REMOTE_REFILL_SEC)
	if key.begins_with("r:"):
		e["t_push"] = Time.get_ticks_msec()
	if pb.can_push_buffer(frames.size()):
		pb.push_buffer(frames)

## Retard (msec) entre l'arrivée du son de la fenêtre `wid` de `from` et sa sortie : échantillons en attente dans le
## générateur + latence de la sortie audio. 0 si cette fenêtre ne joue pas de son en ce moment.
func remote_playout_msec(from: int, wid: int) -> float:
	var e: Dictionary = _players.get("r:%d:%d" % [from, wid], {})
	if e.is_empty() or not e.has("capacity") or Time.get_ticks_msec() - int(e.get("t_push", 0)) > 250:
		return 0.0
	var pb := e["playback"] as AudioStreamGeneratorPlayback
	if pb == null:
		return 0.0
	var queued := int(e["capacity"]) - pb.get_frames_available()
	return maxf(0.0, float(queued) / 48.0 + AudioServer.get_output_latency() * 1000.0)

func _push_silence(e: Dictionary, sec: float) -> void:
	var pb := e["playback"] as AudioStreamGeneratorPlayback
	if pb == null:
		return
	var n := mini(int(48000.0 * sec), pb.get_frames_available())
	if n <= 0:
		return
	var silence := PackedVector2Array()
	silence.resize(n)
	pb.push_buffer(silence)

func _free_player(key: String) -> void:
	var e: Dictionary = _players.get(key, {})
	if not e.is_empty() and is_instance_valid(e["player"]):
		(e["player"] as Node).queue_free()
	_players.erase(key)

func _free_local_players() -> void:
	for key in _players.keys():
		if String(key).begins_with("l:") or String(key).begins_with("p:"):
			_free_player(key)

func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS)
		AudioServer.set_bus_send(idx, "Master")
