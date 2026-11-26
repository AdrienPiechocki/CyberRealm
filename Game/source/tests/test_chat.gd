extends Node
## Tests du chat textuel et des emotes : scripts/network/lan/chat.gd, scripts/ui/chat_box.gd, emotes de l'avatar.

const Runner = preload("res://tests/runner.gd")
const Chat = preload("res://scripts/network/lan/chat.gd")
const ChatBox = preload("res://scripts/ui/chat_box.gd")
const AvatarScript = preload("res://scripts/player/avatar.gd")

# ── Logique pure ───────────────────────────────────────────────────────────

func test_clean_text():
	var r: Variant = Runner.assert_eq(Chat.clean_text("  salut \t\n  toi  "), "salut toi", "blancs réduits")
	if r is String: return r
	r = Runner.assert_eq(Chat.clean_text("a" + String.chr(1) + "b" + String.chr(7) + "c" + String.chr(0x202E) + "d"), "abcd", "contrôles et bidi retirés")
	if r is String: return r
	r = Runner.assert_eq(Chat.clean_text("[b]gras[/b] 👋"), "[b]gras[/b] 👋", "BBCode conservé tel quel (jamais interprété)")
	if r is String: return r
	r = Runner.assert_eq(Chat.clean_text("x".repeat(400)).length(), Chat.MAX_LEN, "borné à MAX_LEN")
	if r is String: return r
	return Runner.assert_eq(Chat.clean_text(" \n\t "), "", "vide")

func test_rate_limit_sliding_window():
	var t := {}
	for i in 5:
		if not Chat.rate_ok(t, 7, 1000 + i * 10, 5, 5000):
			return "message %d refusé à tort" % i
	var r: Variant = Runner.assert_true(not Chat.rate_ok(t, 7, 1100, 5, 5000), "6e message dans la fenêtre refusé")
	if r is String: return r
	r = Runner.assert_true(Chat.rate_ok(t, 8, 1100, 5, 5000), "un autre pair n'est pas concerné")
	if r is String: return r
	return Runner.assert_true(Chat.rate_ok(t, 7, 6100, 5, 5000), "accepté de nouveau après la fenêtre")

func test_parse_command():
	var r: Variant = Runner.assert_eq(Chat.parse_command("/WAVE"), {"emote": "wave"}, "emote connue, casse ignorée")
	if r is String: return r
	r = Runner.assert_eq(Chat.parse_command("bonjour"), {}, "texte normal")
	if r is String: return r
	r = Runner.assert_eq(Chat.parse_command("//slash"), {}, "« // » : message qui commence par /")
	if r is String: return r
	return Runner.assert_true(Chat.parse_command("/fly").has("error"), "commande inconnue")

func test_catalog_has_emoji_and_verb_and_looping_subset():
	for id in Chat.EMOTES:
		var e: Array = Chat.EMOTES[id]
		if e.size() != 2 or String(e[0]) == "" or String(e[1]) == "":
			return "emote %s incomplète" % id
	for id in Chat.LOOPING_EMOTES:
		if not Chat.EMOTES.has(id):
			return "emote en boucle inconnue : %s" % id
	return true

# ── Hôte : validation ──────────────────────────────────────────────────────

class FakeSession extends Node:
	var _pending_auth: Dictionary = {}

class FakeLan extends Node:
	var _players: Dictionary = {}
	var is_host := true
	var dedicated := false
	var session := FakeSession.new()
	func is_session_active() -> bool: return true

func _host_chat_module() -> Node:
	var lan := FakeLan.new()
	lan._players = {1: {"name": "Hôte", "color": Color.RED}, 5: {"name": "Bob", "color": Color.BLUE}}
	lan.session._pending_auth = {9: true}
	var c: Node = Chat.new()
	c.lan = lan
	return c

func _free_module(c: Node) -> void:
	c.lan.session.free()
	c.lan.free()
	c.free()

func test_host_refuses_unregistered_and_pending_peers():
	var c := _host_chat_module()
	var got: Array = []
	c.chat_received.connect(func(from, text): got.append([from, text]))
	c._host_chat(5, "salut")        # pair inscrit
	c._host_chat(42, "intrus")      # inconnu
	c._host_chat(9, "pas encore")   # PIN pas vérifié
	c._host_emote(42, "wave")
	var r: Variant = Runner.assert_eq(got, [[5, "salut"]], "seul le pair inscrit est diffusé")
	_free_module(c)
	return r

func test_host_rejects_unknown_emote_and_throttles():
	var c := _host_chat_module()
	var got: Array = []
	c.emote_received.connect(func(from, e): got.append(e))
	c._host_emote(5, "fly")
	c._host_emote(5, "wave")
	c._host_emote(5, "clap")          # < 1 s après : refusée
	var r: Variant = Runner.assert_eq(got, ["wave"], "emote inconnue et emote trop rapprochée refusées")
	_free_module(c)
	return r

# ── Boîte de chat ──────────────────────────────────────────────────────────

class FakeChatApi extends Node:
	signal chat_received(from_id: int, text: String)
	signal emote_received(from_id: int, emote: String)
	const EMOTES := Chat.EMOTES
	const LOOPING_EMOTES := Chat.LOOPING_EMOTES
	var muted: Dictionary = {}
	func is_muted(id: int) -> bool: return muted.has(id)
	func player_name(id: int) -> String: return "P%d" % id
	func player_color(_id: int) -> Color: return Color.WHITE
	func submit(_l: String) -> String: return ""

class FakeLanUi extends Node:
	signal players_changed(roster: Array)
	signal session_state_changed(active: bool)
	var chat := FakeChatApi.new()

class FakeAvatar extends Node:
	var bubbles: Array = []
	var emotes: Array = []
	func show_chat_bubble(t: String) -> void: bubbles.append(t)
	func play_emote(id: String, _emoji: String, looping: bool) -> void: emotes.append([id, looping])

func _texts(box: Control) -> Array:
	var out: Array = []
	for l in box._lines:
		var parts: Array = []
		for c in (l["node"] as Node).get_children():
			parts.append((c as Label).text)
		out.append(" ".join(parts))
	return out

func test_chat_box_messages_mute_bubbles_and_roster():
	var lan := FakeLanUi.new()
	var box: Control = ChatBox.new()
	add_child(box)
	box.setup(lan, null)
	var av := FakeAvatar.new()
	box.avatar_for = func(_id: int) -> Node: return av
	lan.session_state_changed.emit(true)
	lan.players_changed.emit([{"id": 1, "name": "Hôte"}])            # premier roster : pas d'annonce
	lan.players_changed.emit([{"id": 1, "name": "Hôte"}, {"id": 5, "name": "Bob"}])
	lan.chat.chat_received.emit(5, "salut")
	lan.chat.emote_received.emit(5, "dance")
	lan.chat.muted[5] = true
	lan.chat.chat_received.emit(5, "ignoré")
	lan.players_changed.emit([{"id": 1, "name": "Hôte"}])
	var t := _texts(box)
	var r: Variant = Runner.assert_eq(t, ["Bob joined", "P5: salut", "* P5 dances 💃", "Bob left"], "lignes du chat")
	if r is String: box.free(); lan.chat.free(); lan.free(); av.free(); return r
	r = Runner.assert_eq(av.bubbles, ["salut"], "bulle au-dessus de l'avatar")
	if r is String: box.free(); lan.chat.free(); lan.free(); av.free(); return r
	r = Runner.assert_eq(av.emotes, [["dance", true]], "emote jouée, en boucle pour dance")
	box.free(); lan.chat.free(); lan.free(); av.free()
	return r

func test_chat_box_history_is_bounded_and_enter_does_not_reopen():
	var lan := FakeLanUi.new()
	var box: Control = ChatBox.new()
	add_child(box)
	box.setup(lan, null)
	for i in ChatBox.HISTORY + 10:
		box.add_system("ligne %d" % i)
	var r: Variant = Runner.assert_eq(box._lines.size(), ChatBox.HISTORY, "historique borné")
	if r is String: box.free(); lan.chat.free(); lan.free(); return r
	box.open()
	box._on_submitted("bonjour")
	r = Runner.assert_true(not box.is_typing() and box.just_closed(), "fermée par l'envoi, l'Entrée ne la rouvre pas")
	box.free(); lan.chat.free(); lan.free()
	return r

# ── Avatar : emote jouée puis interrompue ──────────────────────────────────

func test_avatar_plays_emote_animation_and_stops_when_walking():
	var av: Node3D = AvatarScript.new()
	av.anim_idle = &"idle"
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	var lib := AnimationLibrary.new()
	for n in ["idle", "emote_wave"]:
		var a := Animation.new()
		a.length = 1.0
		lib.add_animation(n, a)
	ap.add_animation_library("", lib)
	av.add_child(ap)
	add_child(av)
	av.setup(2, "Bob", Color.WHITE)
	av.play_emote("wave", "👋", false)
	var r: Variant = Runner.assert_eq(String(ap.current_animation), "emote_wave", "animation emote_wave jouée")
	if r is String: av.free(); return r
	r = Runner.assert_true(av._emote_icon != null and av._emote_icon.visible and av._emote_icon.text == "👋", "emoji au-dessus de la tête")
	if r is String: av.free(); return r
	av._relative_speed_h = 3.0       # le joueur repart
	av._speed_smooth = 3.0
	av._update_animation(0.1)
	r = Runner.assert_eq(av._emote_anim, &"", "emote interrompue par le mouvement")
	av.free()
	return r

func test_avatar_without_emote_animation_only_shows_emoji():
	var av: Node3D = AvatarScript.new()
	add_child(av)
	av.setup(2, "Bob", Color.WHITE)
	av.play_emote("clap", "👏", false)
	var r: Variant = Runner.assert_true(av._emote_anim == &"" and av._emote_icon.text == "👏", "repli : emoji seul")
	av.free()
	return r

func test_chat_avoids_bottom_and_left_bars():
	var vp := Vector2(1920, 1080)
	var rects := [
		# DankMaterialShell : barre en bas sur toute la largeur (calque top)
		{"rect": Rect2(0, 1032, 1920, 48), "layer": 2, "anchor": 2 | 4 | 8},
		# dock centré en bas, hors de la colonne du chat : ignoré
		{"rect": Rect2(800, 980, 320, 100), "layer": 2, "anchor": 2},
		# barre verticale à gauche sur toute la hauteur
		{"rect": Rect2(0, 0, 60, 1080), "layer": 2, "anchor": 1 | 2 | 4},
		# lanceur (calque overlay) : ignoré
		{"rect": Rect2(0, 600, 1920, 480), "layer": 3, "anchor": 2},
		# barre du haut : ignorée
		{"rect": Rect2(0, 0, 1920, 40), "layer": 2, "anchor": 1 | 4 | 8},
	]
	var res: Vector2 = ChatBox.reserved_margins(rects, vp, 580.0)
	var r: Variant = Runner.assert_eq(res, Vector2(60, 48), "au-dessus de la barre du bas, à droite de la barre gauche")
	if r is String: return r
	var dock_wide := [{"rect": Rect2(400, 980, 1120, 100), "layer": 2, "anchor": 2}]
	return Runner.assert_eq(ChatBox.reserved_margins(dock_wide, vp, 580.0), Vector2(0, 100), "dock qui chevauche la colonne du chat")
