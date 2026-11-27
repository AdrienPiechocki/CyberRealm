extends Node
## Tests du son des fenêtres : codec par fenêtre (extension), gestionnaire scripts/main/window_audio.gd.

const Runner = preload("res://tests/runner.gd")
const WindowAudio = preload("res://scripts/main/window_audio.gd")

# ── Codec par fenêtre (extension) ──────────────────────────────────────────

func test_per_window_codec_round_trip():
	if not ClassDB.class_exists("WlrCompositor"):
		return true
	var comp: Object = ClassDB.instantiate("WlrCompositor")
	var pcm := PackedVector2Array()
	pcm.resize(48000)
	for i in 48000:
		var v := 0.3 * sin(TAU * 440.0 * i / 48000.0)
		pcm[i] = Vector2(v, -v)
	var packets: Array = comp.audio_encode(3, pcm)
	var r: Variant = Runner.assert_eq(packets.size(), 50, "50 paquets de 20 ms")
	if r is String: comp.free(); return r
	var n := 0
	var e := 0.0
	for i in 40:
		var f: PackedVector2Array = comp.audio_decode_window("7:3", packets[i])
		n += f.size()
		for v in f: e += v.x * v.x
	r = Runner.assert_eq(n, 40 * 960, "40 trames décodées")
	if r is String: comp.free(); return r
	r = Runner.assert_true(sqrt(e / n) > 0.15, "son présent après décodage")
	if r is String: comp.free(); return r
	r = Runner.assert_eq((comp.audio_decode_window("7:3", packets[42]) as PackedVector2Array).size(), 3 * 960, "2 pertes comblées")
	if r is String: comp.free(); return r
	r = Runner.assert_eq((comp.audio_decode_window("7:3", packets[10]) as PackedVector2Array).size(), 0, "paquet en retard ignoré")
	if r is String: comp.free(); return r
	r = Runner.assert_eq((comp.audio_decode_window("8:3", packets[45]) as PackedVector2Array).size(), 960, "autre émetteur : décodeur séparé")
	comp.audio_forget("7:3")
	comp.audio_forget_encoder(3)
	comp.free()
	return r

# ── Gestionnaire ───────────────────────────────────────────────────────────

class FakeComp extends Node:
	var pids: Dictionary = {}        # wid -> pid
	var ppids: Dictionary = {}       # pid -> ppid
	var routed: Array = []
	var audio: Array = []
	var pcm: Dictionary = {}
	var sink_calls: Array = []
	var targets: Array = []
	var encoded: Array = []
	var started := false
	func audio_set_spatial_sink(on: bool) -> bool: sink_calls.append(on); started = started or on; return true
	func start_audio_share() -> bool: started = true; return true
	func stop_audio_share() -> void: started = false
	func set_audio_share_pids(p: Array) -> void: targets = p
	func get_window_pid(wid: int) -> int: return int(pids.get(wid, -1))
	func get_process_info(pid: int) -> Dictionary: return {"ppid": int(ppids.get(pid, 1))}
	func audio_routed_pids() -> PackedInt32Array: return PackedInt32Array(routed)
	func audio_pids() -> PackedInt32Array: return PackedInt32Array(audio)
	func audio_drain_pcm() -> Dictionary:
		var d := pcm
		pcm = {}
		return d
	func audio_encode(key: int, _f: PackedVector2Array) -> Array: encoded.append(key); return [PackedByteArray([1])]
	func audio_forget_encoder(_k: int) -> void: pass

class FakeWin3D extends Node:
	var quads: Dictionary = {}
	var shared: Dictionary = {}
	var focused_window_id := -1
	func is_window_shared(wid: int) -> bool: return shared.has(wid)

class FakeFocus extends Node:
	var fid := -1
	func is_active() -> bool: return fid != -1
	func is_remote() -> bool: return false
	func get_focus_window_id() -> int: return fid
	func get_remote_peer() -> int: return -1
	func get_remote_wid() -> int: return -1

class FakePins extends Node:
	var pinned: Dictionary = {}
	func is_pinned(wid: int) -> bool: return pinned.has(wid)

class FakeAudioShare extends Node:
	signal window_audio_received(from_id: int, wid: int, frames: PackedVector2Array)
	var sent: Array = []
	var playout_delay_provider := Callable()
	func send_window_audio(wid: int, packets: Array) -> void: sent.append([wid, packets.size()])

class FakeWindowShare extends Node:
	var _remote_window_quads: Dictionary = {}

class FakeLan extends Node:
	var audio_share := FakeAudioShare.new()
	var window_share := FakeWindowShare.new()
	var session := false
	func is_session_active() -> bool: return session
	func online_restricted() -> bool: return false
	func window_share_restricted() -> bool: return false

class FakeSettings extends Node:
	var mode := "spatial"
	func get_window_audio_mode() -> String: return mode

var _nodes: Array = []

func _frames() -> PackedVector2Array:
	var f := PackedVector2Array()
	f.resize(960)
	return f

func _make() -> Node:
	var comp := FakeComp.new()
	var w := FakeWin3D.new()
	var f := FakeFocus.new()
	var p := FakePins.new()
	var lan := FakeLan.new()
	var st := FakeSettings.new()
	var wa: Node = WindowAudio.new()
	add_child(w)
	for wid in [1, 2]:
		var q := Node3D.new()
		w.add_child(q)
		w.quads[wid] = q
	add_child(wa)
	wa.setup(comp, w, f, p, lan, st)
	_nodes.append_array([comp, w, f, p, lan.audio_share, lan.window_share, lan, st, wa])
	return wa

func _cleanup() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()

func _tick(wa: Node) -> void:
	wa._refresh_cd = 0.0
	wa._process(0.016)

func test_only_routed_apps_are_replayed_from_their_window():
	var wa := _make()
	wa.compositor.pids = {1: 100, 2: 200}
	wa.compositor.routed = [100, 300]          # 200 joue encore directement (non redirigée)
	wa.compositor.ppids = {300: 100}           # 300 = paplay lancé depuis la fenêtre 1 (terminal)
	_tick(wa)
	var r: Variant = Runner.assert_eq(wa.compositor.sink_calls, [true], "sortie muette créée en mode spatialisé")
	if r is String: _cleanup(); return r
	r = Runner.assert_eq(wa.compositor.targets, [100, 300], "seules les apps redirigées sont capturées")
	if r is String: _cleanup(); return r
	wa.compositor.pcm = {100: _frames(), 300: _frames(), 200: _frames()}
	_tick(wa)
	var p: Node = wa._players["l:1"]["player"]
	r = Runner.assert_true(p is AudioStreamPlayer3D and p.get_parent() == wa.win3d.quads[1], "son joué depuis le quad de la fenêtre")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(not wa._players.has("l:2"), "app non redirigée jamais rejouée (pas de double son)")
	_cleanup()
	return r

func test_focus_hidden_and_pinned_play_in_2d():
	var wa := _make()
	wa.compositor.pids = {1: 100, 2: 200}
	wa.compositor.routed = [100, 200]
	_tick(wa)
	wa.focus.fid = 1
	wa.win3d.quads[2].visible = false
	wa.compositor.pcm = {100: _frames(), 200: _frames()}
	_tick(wa)
	var p1: Node = wa._players["l:1"]["player"]
	var p2: Node = wa._players["l:2"]["player"]
	var r: Variant = Runner.assert_true(p1 is AudioStreamPlayer and not p1 is AudioStreamPlayer3D, "fenêtre en mode focus : 2D")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(p2 is AudioStreamPlayer and is_equal_approx(p2.volume_db, WindowAudio.HIDDEN_DB), "fenêtre cachée : 2D atténuée")
	if r is String: _cleanup(); return r
	wa.focus.fid = -1
	wa.win3d.quads[2].visible = true
	wa.pins.pinned[2] = true
	wa.compositor.pcm = {100: _frames(), 200: _frames()}
	_tick(wa)
	r = Runner.assert_true(wa._players["l:1"]["player"] is AudioStreamPlayer3D, "focus quitté : de nouveau en 3D")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(not wa._players["l:2"]["player"] is AudioStreamPlayer3D, "fenêtre épinglée : 2D")
	_cleanup()
	return r

func test_normal_mode_only_shares_and_never_replays_locally():
	var wa := _make()
	wa.settings.mode = "normal"
	wa.lan.session = true
	wa.compositor.pids = {1: 100, 2: 200}
	wa.win3d.shared[1] = true
	wa.compositor.audio = [100, 200]
	_tick(wa)                                   # démarre la capture
	_tick(wa)
	var r: Variant = Runner.assert_eq(wa.compositor.targets, [100], "seule l'app de la fenêtre partagée est capturée")
	if r is String: _cleanup(); return r
	wa.compositor.pcm = {100: _frames()}
	_tick(wa)
	r = Runner.assert_eq(wa.lan.audio_share.sent, [[1, 1]], "son de la fenêtre 1 envoyé")
	if r is String: _cleanup(); return r
	r = Runner.assert_true(wa._players.is_empty(), "mode normal : rien n'est rejoué localement")
	if r is String: _cleanup(); return r
	wa.lan.session = false
	_tick(wa)
	r = Runner.assert_true(not wa.compositor.started, "plus rien à capturer : capture arrêtée")
	_cleanup()
	return r

func test_remote_window_audio_plays_from_remote_quad():
	var wa := _make()
	_tick(wa)                                   # mode spatialisé pris en compte
	var rq := Node3D.new()
	add_child(rq)
	wa.lan.window_share._remote_window_quads = {5: {9: rq}}
	wa.lan.audio_share.window_audio_received.emit(5, 9, _frames())
	var p: Node = wa._players["r:5:9"]["player"]
	var r: Variant = Runner.assert_true(p is AudioStreamPlayer3D and p.get_parent() == rq, "joué depuis le quad distant")
	if r is String: rq.free(); _cleanup(); return r
	wa.lan.audio_share.window_audio_received.emit(6, 1, _frames())   # quad inconnu
	r = Runner.assert_true(not wa._players["r:6:1"]["player"] is AudioStreamPlayer3D, "quad inconnu : 2D")
	rq.free()
	_cleanup()
	return r

func test_remote_window_audio_follows_local_normal_mode():
	var wa := _make()
	wa.settings.mode = "normal"
	_tick(wa)
	var rq := Node3D.new()
	add_child(rq)
	wa.lan.window_share._remote_window_quads = {5: {9: rq}}
	wa.lan.audio_share.window_audio_received.emit(5, 9, _frames())
	var p: Node = wa._players["r:5:9"]["player"]
	var r: Variant = Runner.assert_true(not p is AudioStreamPlayer3D, "mode normal : son distant en 2D, pas depuis le quad")
	rq.free()
	_cleanup()
	return r

func test_catch_up_plan():
	var r: Variant = Runner.assert_eq(WindowAudio.catch_up_plan(10.0, 0.2), 1.0, "proche de la cible : tel quel")
	if r is String: return r
	r = Runner.assert_eq(WindowAudio.catch_up_plan(80.0, 0.0), 0.0, "silence en trop : jeté")
	if r is String: return r
	r = Runner.assert_approx(WindowAudio.catch_up_plan(80.0, 0.2), 1.04, 0.001, "son en trop : accéléré")
	if r is String: return r
	r = Runner.assert_approx(WindowAudio.catch_up_plan(200.0, 0.2), 1.05, 0.001, "accélération plafonnée")
	if r is String: return r
	return Runner.assert_eq(WindowAudio.catch_up_plan(400.0, 0.2), 0.0, "très loin : paquet jeté")

func test_time_compress_keeps_ends():
	var f := PackedVector2Array()
	for i in 960:
		f.append(Vector2(i, -i))
	var out := WindowAudio.time_compress(f, 1.05)
	var r: Variant = Runner.assert_eq(out.size(), 914, "960 / 1,05")
	if r is String: return r
	return Runner.assert_true(out[0] == f[0] and out[out.size() - 1].is_equal_approx(f[959]), "extrémités conservées")

func test_remote_delay_drains_back_to_target():
	var wa := _make()
	wa.settings.mode = "normal"
	_tick(wa)
	# Paquets silencieux en rafale (aucun mixage en headless) : le tampon ne dépasse pas cible + tolérance.
	for i in 30:
		wa.lan.audio_share.window_audio_received.emit(5, 9, _frames())
	var e: Dictionary = wa._players["r:5:9"]
	var q: float = wa._queued_msec(e, e["playback"])
	_cleanup()
	return Runner.assert_true(q <= 100.0 + 20.0 + 20.0, "retard contenu : %.0f ms" % q)
