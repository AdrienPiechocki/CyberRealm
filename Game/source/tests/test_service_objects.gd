extends Node

const Runner = preload("res://tests/runner.gd")
const JukeboxScript = preload("res://scripts/interaction/objects/jukebox.gd")

class BridgeStub:
	extends RefCounted
	var calls: Array = []
	var now_playing := {
		"player": "org.mpris.MediaPlayer2.spotify",
		"title": "Bad Guy", "artist": "Billie Eilish",
		"art": "file://" + ProjectSettings.globalize_path("res://tests/fixtures/cover.png"),
		"position": 42000000,
	}
	var available := true
	var events: Array = [{"interface":"org.freedesktop.Notifications","member":"Notify","args":["sway",0,"","Build done","OK",[],5000]}]
	var layer: CanvasLayer = null
	func set_ui_layer(c: CanvasLayer): layer = c
	func get_ui_layer(): return layer
	func list_names() -> Array: return ["org.mpris.MediaPlayer2.spotify"] if available else []
	func get_property(dest, path, iface, name) -> Variant:
		calls.append(["get_property", dest, name])
		match name:
			"PlaybackStatus": return "Playing"
			"Position": return now_playing.position
			"Metadata": return {
				"xesam:title": now_playing.title, "xesam:artist": [now_playing.artist],
				"mpris:artUrl": now_playing.art}
		return null
	func call_method(dest, path, iface, method, signature := "", args := []) -> Dictionary:
		calls.append(["call_method", dest, method])
		if not available: return {"ok": false, "error": "no player", "exit": 1}
		return {"ok": true, "data": null}
	func art_uri_to_texture(uri: String):
		return null
	func subscribe(dest, iface := "", member := "") -> int: return 0
	func read_events(id: int) -> Array: return events
	func unsubscribe(id: int) -> void: pass

func _make_jukebox(stub) -> Node:
	var j = JukeboxScript.new()
	j.set_bridge(stub)
	return j

func test_jukebox_detects_no_player():
	var b := BridgeStub.new()
	b.available = false
	var j := _make_jukebox(b)
	j.update_display()
	var r = Runner.assert_eq(j.get_state_text(), "No MPRIS player", "clean state text")
	j.free()
	return r

func test_jukebox_parses_now_playing():
	var b := BridgeStub.new()
	var j := _make_jukebox(b)
	j.update_display()
	var r = Runner.assert_eq(j.get_now_playing_name(), "Bad Guy — Billie Eilish", "title — artist")
	j.free()
	return r

func test_jukebox_controls_drive_bridge_calls():
	var b := BridgeStub.new()
	var j := _make_jukebox(b)
	j.update_display()
	j.play_toggle()
	var has_pp := false
	for c in b.calls:
		if c[0] == "call_method" and c[2] == "PlayPause": has_pp = true
	var r = Runner.assert_true(has_pp, "PlayPause issued via bridge")
	if r != true: return r
	j.next()
	j.free()
	for c in b.calls:
		if c[0] == "call_method" and c[2] == "Next": return Runner.assert_true(true, "Next issued")
	return Runner.assert_true(false, "Next issued")
