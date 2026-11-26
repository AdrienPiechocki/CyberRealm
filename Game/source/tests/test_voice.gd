extends Node
## Tests du chat vocal : codec (extension, sans ouvrir de micro), relais réseau (voice.gd), gestionnaire (voice_manager.gd).

const Runner = preload("res://tests/runner.gd")
const Voice = preload("res://scripts/network/lan/voice.gd")
const VoiceManager = preload("res://scripts/main/voice_manager.gd")

# ── Codec OPUS (extension) ─────────────────────────────────────────────────

func _sine(n: int, freq := 440.0, amp := 0.3) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		s[i] = amp * sin(TAU * freq * float(i) / 48000.0)
	return s

func test_codec_round_trip_and_loss_concealment():
	if not ClassDB.class_exists("WlrCompositor"):
		return true   # extension absente (serveur) : rien à tester
	var comp: Object = ClassDB.instantiate("WlrCompositor")
	comp.voice_feed_samples(_sine(48000))           # 1 s
	var frames: Array = comp.voice_poll()
	var r: Variant = Runner.assert_eq(frames.size(), 50, "50 trames de 20 ms par seconde")
	if r is String: comp.free(); return r
	var rms := float(frames[25]["rms"])
	r = Runner.assert_approx(rms, 0.3 / sqrt(2.0), 0.02, "niveau RMS d'une sinusoïde d'amplitude 0,3")
	if r is String: comp.free(); return r
	var max_len := 0
	for f in frames:
		max_len = maxi(max_len, (f["data"] as PackedByteArray).size())
	r = Runner.assert_true(max_len > 0 and max_len <= Voice.MAX_PACKET, "paquets sous la borne réseau (%d octets)" % max_len)
	if r is String: comp.free(); return r
	var out := 0
	var energy := 0.0
	for i in 20:
		var pcm: PackedVector2Array = comp.voice_decode(7, i + 1, frames[i]["data"])
		out += pcm.size()
		for v in pcm:
			energy += v.x * v.x
	r = Runner.assert_eq(out, 20 * 960, "20 trames décodées, stéréo")
	if r is String: comp.free(); return r
	r = Runner.assert_true(sqrt(energy / out) > 0.1, "le son décodé n'est pas du silence")
	if r is String: comp.free(); return r
	# Trame 22 perdue : la 23 la reconstruit (FEC) en plus d'elle-même.
	var pcm_gap: PackedVector2Array = comp.voice_decode(7, 22, frames[21]["data"])
	r = Runner.assert_eq(pcm_gap.size(), 1920, "trame perdue comblée")
	if r is String: comp.free(); return r
	r = Runner.assert_eq(comp.voice_decode(7, 10, frames[22]["data"]).size(), 0, "trame en retard ignorée")
	if r is String: comp.free(); return r
	r = Runner.assert_eq(comp.voice_decode(8, 1, PackedByteArray()).size(), 0, "trame vide refusée")
	comp.voice_forget(7)
	comp.free()
	return r

# ── Relais (hôte) ──────────────────────────────────────────────────────────

func test_budget_per_second():
	var b := {}
	for i in 60:
		if not Voice.budget_ok(b, 3, 1000 + i, 60):
			return "trame %d refusée à tort" % i
	var r: Variant = Runner.assert_true(not Voice.budget_ok(b, 3, 1100, 60), "61e trame de la seconde refusée")
	if r is String: return r
	return Runner.assert_true(Voice.budget_ok(b, 3, 2001, 60), "nouvelle seconde")

class FakeSession extends Node:
	var _pending_auth: Dictionary = {}

class FakeLan extends Node:
	var _players: Dictionary = {}
	var is_host := true
	var dedicated := false
	var session := FakeSession.new()
	func is_session_active() -> bool: return true

func test_host_relay_validates_sender_and_size():
	var lan := FakeLan.new()
	lan._players = {5: {"name": "Bob"}}
	lan.session._pending_auth = {9: true}
	var v: Node = Voice.new()
	v.lan = lan
	var got: Array = []
	v.voice_packet.connect(func(from, seq, data): got.append([from, seq]))
	v._host_relay(5, 1, PackedByteArray([1, 2, 3]))         # inscrit : joué chez l'hôte
	v._host_relay(42, 1, PackedByteArray([1]))              # inconnu
	v._host_relay(9, 1, PackedByteArray([1]))               # PIN pas vérifié
	var big := PackedByteArray()
	big.resize(Voice.MAX_PACKET + 1)
	v._host_relay(5, 2, big)                                # trop gros
	v.disabled = true
	v._host_relay(5, 3, PackedByteArray([1]))               # --no-voice
	var r: Variant = Runner.assert_eq(got, [[5, 1]], "seule la trame valide d'un pair inscrit passe")
	lan.session.free(); lan.free(); v.free()
	return r

# ── Gestionnaire (joueur) ──────────────────────────────────────────────────

class FakeVoiceNet extends Node:
	signal voice_packet(from_id: int, seq: int, data: PackedByteArray)
	var disabled := false
	var sent: Array = []
	func send(seq: int, data: PackedByteArray) -> void: sent.append(seq)

class FakeLanV extends Node:
	signal session_state_changed(active: bool)
	var voice := FakeVoiceNet.new()
	var active := true
	func is_session_active() -> bool: return active

class FakeComp extends Node:
	var frames: Array = []
	var opened: Array = []
	var stopped := 0
	func voice_start(target: String) -> bool: opened.append(target); return true
	func voice_stop() -> void: stopped += 1
	func voice_poll() -> Array:
		var f := frames
		frames = []
		return f
	func voice_decode(_p: int, _s: int, _d: PackedByteArray) -> PackedVector2Array:
		var a := PackedVector2Array()
		a.resize(960)
		return a
	func voice_forget(_p: int) -> void: pass

class FakeSettings extends Node:
	var mode := "vad"
	var echo := false
	var spatial := true
	func get_voice_mode() -> String: return mode
	func get_voice_vad_threshold() -> float: return 0.05
	func is_voice_spatial() -> bool: return spatial
	func is_voice_echo_cancel() -> bool: return echo
	func get_voice_volume() -> float: return 1.0

func _frame(rms: float) -> Dictionary:
	return {"data": PackedByteArray([1, 2]), "rms": rms}

func _manager() -> Node:
	var vm: Node = VoiceManager.new()
	var comp := FakeComp.new()
	var lan := FakeLanV.new()
	var st := FakeSettings.new()
	add_child(vm)
	vm.setup(comp, lan, st)
	return vm

func _free_manager(vm: Node) -> void:
	var comp: Node = vm.compositor
	var lan: Node = vm.lan
	var st: Node = vm.settings
	vm.free()
	lan.voice.free(); lan.free(); comp.free(); st.free()

func test_mic_opens_only_in_session_and_follows_echo_option():
	var vm := _manager()
	vm.settings.mode = "off"
	vm._process(0.016)
	var r: Variant = Runner.assert_eq(vm.compositor.opened, [], "mode Off : micro jamais ouvert")
	if r is String: _free_manager(vm); return r
	vm.settings.mode = "vad"
	vm._process(0.016)
	vm.settings.echo = true
	vm._process(0.016)
	r = Runner.assert_eq(vm.compositor.opened, ["", VoiceManager.ECHO_CANCEL_SOURCE], "rouvert sur la source echo-cancel")
	if r is String: _free_manager(vm); return r
	vm.lan.active = false
	vm._process(0.016)
	r = Runner.assert_true(vm.compositor.stopped >= 2, "fermé en quittant la session")
	_free_manager(vm)
	return r

func test_voice_activation_with_hangover():
	var vm := _manager()
	vm._process(0.016)
	vm.compositor.frames = [_frame(0.001), _frame(0.2), _frame(0.001)]   # silence, voix, fin de mot
	vm._process(0.016)
	var r: Variant = Runner.assert_eq(vm.lan.voice.sent, [1, 2], "trame forte + maintien de la suivante, pas le silence d'avant")
	_free_manager(vm)
	return r

func test_push_to_talk_respects_guard():
	var vm := _manager()
	vm.settings.mode = "ptt"
	vm._process(0.016)
	vm.compositor.frames = [_frame(0.2)]
	vm._process(0.016)
	var r: Variant = Runner.assert_eq(vm.lan.voice.sent, [], "touche non pressée : rien n'est envoyé")
	if r is String: _free_manager(vm); return r
	Input.action_press("push_to_talk")
	vm.can_push_to_talk = func() -> bool: return false   # chat ouvert / mode focus
	vm.compositor.frames = [_frame(0.2)]
	vm._process(0.016)
	r = Runner.assert_eq(vm.lan.voice.sent, [], "garde (chat, focus) respectée")
	if r is String: Input.action_release("push_to_talk"); _free_manager(vm); return r
	vm.can_push_to_talk = func() -> bool: return true
	vm.compositor.frames = [_frame(0.0)]
	vm._process(0.016)
	Input.action_release("push_to_talk")
	r = Runner.assert_eq(vm.lan.voice.sent, [1], "touche pressée : envoyé même en silence")
	_free_manager(vm)
	return r

func test_received_voice_plays_from_avatar_or_2d_and_mute():
	var vm := _manager()
	var av := Node3D.new()
	add_child(av)
	vm.avatar_for = func(_p: int) -> Node: return av
	vm.lan.voice.voice_packet.emit(5, 1, PackedByteArray([1]))
	var p: Node = vm._players[5]["player"]
	var r: Variant = Runner.assert_true(p is AudioStreamPlayer3D and p.get_parent() == av, "voix spatialisée : lecteur 3D sur l'avatar")
	if r is String: av.free(); _free_manager(vm); return r
	vm.settings.spatial = false
	vm.lan.voice.voice_packet.emit(5, 2, PackedByteArray([1]))
	p = vm._players[5]["player"]
	r = Runner.assert_true(p is AudioStreamPlayer and not p is AudioStreamPlayer3D, "option coupée : lecteur 2D")
	if r is String: av.free(); _free_manager(vm); return r
	vm.set_muted(6, true)
	vm.lan.voice.voice_packet.emit(6, 1, PackedByteArray([1]))
	r = Runner.assert_true(not vm._players.has(6), "joueur en sourdine : rien n'est joué")
	av.free()
	_free_manager(vm)
	return r
