extends Control
## Boîte de chat (bas gauche de l'écran) : messages des joueurs, emotes et messages système.
##
## L'action « chat » (Super+T, remappable) ouvre la saisie, Échap la ferme, Entrée envoie. Fermée, la boîte ne
## montre que les messages récents, qui s'estompent après `fade-delay` secondes ; ouverte, tout l'historique
## (HISTORY lignes). Une ligne « /wave », « /dance »… joue une emote. Texte toujours affiché sans BBCode.
## Thème CSS : élément `chat` (background-color, color, font-size, fade-delay).

signal typing_changed(typing: bool)

const HISTORY := 50
const SYSTEM_COLOR := Color(0.65, 0.7, 0.8)

var lan: Node = null
var keyboard: Node = null                # clavier virtuel (manette)
var avatar_for := Callable()             # Callable(peer_id) -> Node (avatar) ou null
var bubbles_enabled := Callable()        # Callable() -> bool : bulles au-dessus des avatars

var input: LineEdit = null
var _panel: PanelContainer = null
var _lines_box: VBoxContainer = null
var _lines: Array = []                   # [{node, time}]
var _typing := false
var _closed_frame := -1                  # frame de fermeture (l'Entrée d'envoi ne doit pas rouvrir la saisie)
var _known_players: Dictionary = {}      # peer -> nom (messages d'arrivée / de départ)
var _roster_primed := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	position = Vector2(20, -20)
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.custom_minimum_size = Vector2(560, 0)
	add_child(_panel)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(v)
	_lines_box = VBoxContainer.new()
	_lines_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines_box.add_theme_constant_override("separation", 2)
	v.add_child(_lines_box)
	input = LineEdit.new()
	input.max_length = 280
	input.placeholder_text = "Say something… (/wave, /dance… for emotes)"
	input.visible = false
	input.text_submitted.connect(_on_submitted)
	v.add_child(input)
	UITheme.stylesheet_reloaded.connect(_apply_theme)
	_apply_theme()
	_refresh_visibility()

func setup(p_lan: Node, p_keyboard: Node) -> void:
	lan = p_lan
	keyboard = p_keyboard
	lan.chat.chat_received.connect(_on_chat)
	lan.chat.emote_received.connect(_on_emote)
	lan.players_changed.connect(_on_roster)
	lan.session_state_changed.connect(_on_session_state)

func is_typing() -> bool:
	return _typing

## Ouvre la saisie. `with_keyboard` : clavier virtuel (ouverture à la manette).
func open(with_keyboard := false) -> void:
	if _typing:
		return
	_typing = true
	input.visible = true
	input.text = ""
	input.grab_focus()
	_refresh_visibility()
	typing_changed.emit(true)
	if with_keyboard and keyboard != null:
		keyboard.show_menu(input)

## Fermée pendant cette frame ou la précédente : l'action « chat » (Entrée) ne doit pas la rouvrir aussitôt.
func just_closed() -> bool:
	return Engine.get_process_frames() - _closed_frame <= 1

func close() -> void:
	if not _typing:
		return
	_typing = false
	_closed_frame = Engine.get_process_frames()
	input.release_focus()
	input.visible = false
	if keyboard != null and keyboard.visible:
		keyboard.hide_menu()
	_refresh_visibility()
	typing_changed.emit(false)

func _input(event: InputEvent) -> void:
	if _typing and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

func _on_submitted(text: String) -> void:
	var err := String(lan.chat.submit(text)) if lan != null else ""
	if err != "":
		add_system(err)
	close()

# ── Messages ────────────────────────────────────────────────────────────

func _on_chat(from_id: int, text: String) -> void:
	if lan.chat.is_muted(from_id):
		return
	_add_line(lan.chat.player_name(from_id), lan.chat.player_color(from_id), text)
	if not bubbles_enabled.is_valid() or bool(bubbles_enabled.call()):
		var av: Variant = avatar_for.call(from_id) if avatar_for.is_valid() else null
		if av != null and is_instance_valid(av) and av.has_method("show_chat_bubble"):
			av.show_chat_bubble(text)

func _on_emote(from_id: int, emote: String) -> void:
	if lan.chat.is_muted(from_id):
		return
	var e: Array = lan.chat.EMOTES[emote]
	add_system("* %s %s %s" % [lan.chat.player_name(from_id), e[1], e[0]])
	var av: Variant = avatar_for.call(from_id) if avatar_for.is_valid() else null
	if av != null and is_instance_valid(av) and av.has_method("play_emote"):
		av.play_emote(emote, String(e[0]), lan.chat.LOOPING_EMOTES.has(emote))

func _on_session_state(active: bool) -> void:
	_known_players.clear()
	_roster_primed = false
	if not active:
		add_system("Left the multiplayer session")

func _on_roster(roster: Array) -> void:
	var now := {}
	for p in roster:
		now[int(p.get("id", 0))] = String(p.get("name", "?"))
	if _roster_primed:
		for id in now:
			if not _known_players.has(id):
				add_system("%s joined" % now[id])
		for id in _known_players:
			if not now.has(id):
				add_system("%s left" % _known_players[id])
	_roster_primed = true
	_known_players = now

func add_system(text: String) -> void:
	_add_line("", SYSTEM_COLOR, text)

func _add_line(who: String, color: Color, text: String) -> void:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if who != "":
		var n := Label.new()
		n.text = who + ":"
		n.add_theme_color_override("font_color", color)
		n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(n)
	var t := Label.new()
	t.text = text                     # Label : jamais d'interprétation BBCode
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if who == "":
		t.add_theme_color_override("font_color", color)
	row.add_child(t)
	_apply_line_theme(row)
	_lines_box.add_child(row)
	_lines.append({"node": row, "time": Time.get_ticks_msec()})
	while _lines.size() > HISTORY:
		(_lines.pop_front()["node"] as Node).queue_free()
	_refresh_visibility()

# ── Affichage ───────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _typing:
		_refresh_visibility()

## Ouverte : tout l'historique et le fond. Fermée : seulement les lignes récentes, estompées après fade-delay.
func _refresh_visibility() -> void:
	var fade_ms := UITheme.get_number("chat", "fade-delay", 10.0) * 1000.0
	var now := Time.get_ticks_msec()
	var any := false
	for l in _lines:
		var node: Control = l["node"]
		if _typing:
			node.visible = true
			node.modulate.a = 1.0
		else:
			var age := float(now - int(l["time"]))
			var a := 1.0 if age < fade_ms else clampf(1.0 - (age - fade_ms) / 1000.0, 0.0, 1.0)
			node.visible = a > 0.0
			node.modulate.a = a
		any = any or node.visible
	_panel.self_modulate.a = 1.0 if _typing else 0.0
	visible = _typing or any

func _apply_theme() -> void:
	var bg := UITheme.get_color("chat", "background-color", Color(0.05, 0.06, 0.09, 0.75))
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	_panel.add_theme_stylebox_override("panel", sb)
	for l in _lines:
		_apply_line_theme(l["node"])

func _apply_line_theme(row: Control) -> void:
	var fs := int(UITheme.get_number("chat", "font-size", 16.0))
	var col := UITheme.get_color("chat", "color", Color(0.92, 0.94, 1.0))
	for c in row.get_children():
		var lab := c as Label
		if lab == null:
			continue
		lab.add_theme_font_size_override("font_size", fs)
		lab.add_theme_constant_override("outline_size", 4)
		lab.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		if not lab.has_theme_color_override("font_color"):
			lab.add_theme_color_override("font_color", col)
