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

func test_row_and_time_format():
	var n := {"time": 0, "app": "Firefox", "summary": "Secret"}
	var r: Variant = Runner.assert_true(Board.row_text(n).contains("Firefox") and Board.row_text(n).contains("Secret"),
		"application et résumé affichés")
	if r is String: return r
	return Runner.assert_eq([Media.fmt_time(0), Media.fmt_time(185000000)], ["0:00", "3:05"], "format du temps")

func test_cover_from_bytes():
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	img.fill(Color.RED)
	var png := img.save_png_to_buffer()
	var jpg := img.save_jpg_to_buffer()
	var r: Variant = Runner.assert_true(Media.texture_from_bytes(png) != null and Media.texture_from_bytes(jpg) != null,
		"PNG et JPEG reconnus par leur contenu")
	if r is String: return r
	return Runner.assert_true(Media.texture_from_bytes("pas une image du tout".to_utf8_buffer()) == null, "contenu inconnu : rien")
