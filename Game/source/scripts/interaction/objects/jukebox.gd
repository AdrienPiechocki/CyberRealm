extends StaticBody3D
## Jukebox — lit le lecteur MPRIS du poste (titre/artiste/cover) et le
## contrôle (Play/Pause, Next). Affichage construit en code (remplaçable).

const REFRESH_MSEC := 1000

var _bridge = null
var _player := ""
var _poll_last_msec := 0
var _panel: PanelContainer = null
var _cover: TextureRect = null
var _title: Label = null
var _state := ""
var _now_meta = {}

func _ready() -> void:
	if _bridge == null:
		_bridge = get_tree().get_first_node_in_group("host_services")

func set_bridge(b) -> void:
	_bridge = b

func _resolve_bridge() -> void:
	if _bridge == null:
		_bridge = get_tree().get_first_node_in_group("host_services")

func get_interact_prompt() -> String:
	return "Jukebox"

func interact_focus(aimed: bool) -> void:
	if not aimed:
		_set_panel_visible(false)

func interact() -> void:
	if _bridge == null:
		return
	update_display()
	if _panel != null:
		_set_panel_visible(not _panel.visible)
	else:
		_set_panel_visible(true)

func get_state_text() -> String:
	return _state

func get_now_playing_name() -> String:
	return "%s — %s" % [_title_text(), _artist_text()]

func _process(delta: float) -> void:
	_resolve_bridge()
	if _bridge == null or not visible:
		return
	if Time.get_ticks_msec() - _poll_last_msec >= REFRESH_MSEC:
		_poll_last_msec = Time.get_ticks_msec()
		update_display()

func update_display() -> void:
	_resolve_bridge()
	if _bridge == null:
		_state = "Service unavailable"
		return
	var names = _bridge.list_names()
	_player = ""
	for n in names:
		if String(n).begins_with("org.mpris.MediaPlayer2."):
			_player = String(n)
			break
	if _player.is_empty():
		_state = "No MPRIS player"
		return
	var meta = _bridge.get_property(_player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Metadata")
	if meta == null:
		_state = "Player unavailable"
		return
	_now_meta = meta
	_state = "%s — %s" % [_title_text(), _artist_text()]
	_apply_panel()

func _title_text() -> String:
	return String(_now_meta.get("xesam:title", "?")) if _now_meta is Dictionary else "?"

func _artist_text() -> String:
	var a = _now_meta.get("xesam:artist", []) if _now_meta is Dictionary else []
	if a is Array and a.size() > 0:
		return String(a[0])
	return "?"

func play_toggle() -> void:
	_resolve_bridge()
	if _bridge == null or _player.is_empty(): return
	_bridge.call_method(_player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "PlayPause")

func next() -> void:
	_resolve_bridge()
	if _bridge == null or _player.is_empty(): return
	_bridge.call_method(_player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Next")

func _apply_panel() -> void:
	var art := ""
	if _now_meta is Dictionary:
		art = String(_now_meta.get("mpris:artUrl", ""))
	if _cover != null:
		var tex = _bridge.art_uri_to_texture(art) if _bridge != null and not art.is_empty() else null
		_cover.texture = tex
	if _title != null:
		_title.text = get_now_playing_name()

func _set_panel_visible(v: bool) -> void:
	if v and _panel == null:
		_panel = _build_panel()
	if _panel == null:
		return
	_panel.visible = v
	if v:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		update_display()
	elif Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_panel() -> PanelContainer:
	var layer: CanvasLayer = _bridge.get_ui_layer() if _bridge != null else null
	if layer == null:
		return null
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 1.0
	panel.anchor_right = 0.5
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = -260; panel.offset_right = 260
	panel.offset_top = -180;  panel.offset_bottom = -24
	panel.visible = false
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	_cover = TextureRect.new()
	_cover.custom_minimum_size = Vector2(240, 110)
	_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vb.add_child(_cover)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	var pp := Button.new(); pp.text = "Play/Pause"; pp.pressed.connect(play_toggle)
	var nx := Button.new(); nx.text = "Next"; nx.pressed.connect(next)
	hb.add_child(pp); hb.add_child(nx)
	layer.add_child(panel)
	return panel
