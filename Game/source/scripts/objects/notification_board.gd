extends "res://scripts/objects/desktop_object.gd"
## Tableau des notifications (lot L) : les dernières notifications du joueur (apps du jeu et bureau). Clic sur une
## notification : son action par défaut (notifications des apps du jeu servies par le pont). Option de
## confidentialité (General) : contenu complet, application seulement ou nombre seulement.

const SIZE := Vector2(0.6, 0.8)
const ROWS := 8

var _header: Label3D
var _rows: Array = []            # [button, label]
var _shown: Array = []

func _ready() -> void:
	make_panel(SIZE)
	make_body(SIZE)
	_header = make_label("Notifications", Vector2(-SIZE.x / 2.0 + 0.03, SIZE.y / 2.0 - 0.03), 44, Color(1, 1, 1))
	for i in ROWS:
		var y := SIZE.y / 2.0 - 0.13 - i * 0.082
		var b := make_button("", Vector2(0, y), Vector2(SIZE.x - 0.04, 0.072), _on_row.bind(i), "Left click: open")
		var l := make_label("", Vector2(-SIZE.x / 2.0 + 0.035, y + 0.03), 24, Color(0.9, 0.92, 0.95), SIZE.x - 0.07)
		l.position.z = 0.032
		_rows.append([b, l])
	var br := bridge()
	if br != null:
		br.notification_received.connect(func(_n): _refresh())
		br.notification_closed.connect(func(_b, _i): _refresh())
	_refresh()

static func row_text(n: Dictionary, privacy: String) -> String:
	var t := Time.get_time_string_from_unix_time(int(n.get("time", 0)) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60).substr(0, 5)
	var app := String(n.get("app", "")) if String(n.get("app", "")) != "" else "?"
	if privacy == "app":
		return "%s  %s" % [t, app]
	var summary := String(n.get("summary", ""))
	return "%s  %s — %s" % [t, app, summary.substr(0, 60)]

func _privacy() -> String:
	var br := bridge()
	return String(br.privacy.call()) if br != null and "privacy" in br and br.privacy.is_valid() else "full"

func _refresh() -> void:
	var br := bridge()
	var list: Array = br.notifications() if br != null else []
	var privacy := _privacy()
	_header.text = "Notifications (%d)" % list.size() if br != null else "Notifications — bridge unavailable"
	_shown = list.slice(0, ROWS) if privacy != "count" else []
	for i in ROWS:
		var b: Node3D = _rows[i][0]
		var l: Label3D = _rows[i][1]
		b.visible = i < _shown.size()
		l.text = row_text(_shown[i], privacy) if i < _shown.size() else ""

func _on_row(player_id: int, i: int) -> void:
	if not is_local_player(player_id) or i >= _shown.size():
		return
	var br := bridge()
	if br != null:
		br.notification_action(_shown[i])
