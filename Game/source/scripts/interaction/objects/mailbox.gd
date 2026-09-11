extends StaticBody3D
## Boîte aux lettres — lit les notifications du bureau (journal de signaux
## org.freedesktop.Notifications via le pont). Affichage construit en code.

const MAX_ENTRIES := 30

var _bridge = null
var _journal_id := 0
var _entries: Array = [] # [{app, summary, body, time, ts}]
var _panel: PanelContainer = null
var _list: VBoxContainer = null

func _ready() -> void:
	if _bridge == null:
		_bridge = get_tree().get_first_node_in_group("host_services")
	_subscribe()

func set_bridge(b) -> void:
	_bridge = b

func _subscribe() -> void:
	if _bridge == null or _journal_id != 0:
		return
	_journal_id = int(_bridge.subscribe("org.freedesktop.Notifications", "org.freedesktop.Notifications", "Notify"))

func get_interact_prompt() -> String:
	return "Mailbox"

func interact() -> void:
	_subscribe()
	refresh()
	if _panel != null:
		_set_panel_visible(not _panel.visible)
	else:
		_set_panel_visible(true)

func refresh() -> void:
	_subscribe()
	if _bridge == null or _journal_id == 0:
		return
	for ev in _bridge.read_events(_journal_id):
		var args = (ev as Dictionary).get("args", [])
		if not (args is Array) or args.size() < 5:
			continue
		_entries.append({
			"app": String(args[0]), "summary": String(args[3]),
			"body": String(args[4]), "time": _format_time(int((ev as Dictionary).get("ts_msec", 0))),
		})
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - MAX_ENTRIES)
	_render()

func get_entries() -> Array:
	return _entries

func _format_time(ts_msec: int) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(int(ts_msec / 1000))
	return "%02d:%02d" % [int(dt.get("hour", 0)), int(dt.get("minute", 0))]

func _set_panel_visible(v: bool) -> void:
	if v and _panel == null:
		_panel = _build_panel()
	if _panel == null:
		return
	_panel.visible = v
	if v:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		refresh()
	elif Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _render() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	for e in _entries.slice(maxi(_entries.size() - MAX_ENTRIES, 0)):
		var lb := Label.new()
		lb.text = "%s  %s — %s\n%s" % [e.get("time", ""), e.get("app", ""), e.get("summary", ""), e.get("body", "")]
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(lb)

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
	panel.offset_left = -320; panel.offset_right = 320
	panel.offset_top = -260;  panel.offset_bottom = -24
	panel.visible = false
	var sc := ScrollContainer.new()
	panel.add_child(sc)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_list)
	layer.add_child(panel)
	return panel
