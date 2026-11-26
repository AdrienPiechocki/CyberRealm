extends Node
## Tests du pont avec le bureau (scripts/main/desktop_bridge.gd) et des objets (scripts/objects/).

const Runner = preload("res://tests/runner.gd")
const Bridge = preload("res://scripts/main/desktop_bridge.gd")
const Board = preload("res://scripts/objects/notification_board.gd")
const Media = preload("res://scripts/objects/media_player.gd")

func test_current_player_prefers_playing():
	var b: Node = Bridge.new()
	b.handle_event({"type": "media", "bus": "host", "name": "a", "status": "Paused", "title": "A"})
	b.handle_event({"type": "media", "bus": "game", "name": "b", "status": "Playing", "title": "B"})
	var r: Variant = Runner.assert_eq(b.current_player()["title"], "B", "le lecteur en lecture")
	if r is String: b.free(); return r
	b.handle_event({"type": "media_removed", "bus": "game", "name": "b"})
	r = Runner.assert_eq(b.current_player()["title"], "A", "lecteur retiré : l'autre")
	b.free()
	return r

func test_notifications_capped_and_replaced():
	var b: Node = Bridge.new()
	for i in 25:
		b.handle_event({"type": "notification", "bus": "game", "id": i, "app": "x", "summary": str(i)})
	b.handle_event({"type": "notification", "bus": "game", "id": 24, "app": "x", "summary": "remplacée"})
	var list: Array = b.notifications()
	var r: Variant = Runner.assert_eq([list.size(), list[0]["summary"], list[1]["summary"]], [20, "remplacée", "23"],
		"20 dernières, remplacement par id")
	b.free()
	return r

func test_privacy_and_time_format():
	var n := {"time": 0, "app": "Firefox", "summary": "Secret"}
	var r: Variant = Runner.assert_true(Board.row_text(n, "full").contains("Secret") and not Board.row_text(n, "app").contains("Secret"),
		"« application seulement » cache le résumé")
	if r is String: return r
	return Runner.assert_eq([Media.fmt_time(0), Media.fmt_time(185000000)], ["0:00", "3:05"], "format du temps")
