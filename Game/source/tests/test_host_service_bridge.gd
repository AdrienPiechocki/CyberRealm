extends Node

const Runner = preload("res://tests/runner.gd")
const BridgeScript = preload("res://scripts/interaction/host_service_bridge.gd")
const FAKE_BUSCTL := "res://tests/fixtures/fake_busctl.sh"
const MPRIS := "org.mpris.MediaPlayer2.spotify"
const MPRIS_OBJ := "/org/mpris/MediaPlayer2"
const MPRIS_IFACE := "org.mpris.MediaPlayer2.Player"

func _make_bridge() -> Node:
	var bridge = BridgeScript.new()
	bridge.set_busctl_path(ProjectSettings.globalize_path(FAKE_BUSCTL))
	bridge.set_runtime_dir(OS.get_temp_dir())
	bridge.set_bus_address("unix:path=/tmp/fake-bus")
	return bridge

func test_no_bus_address_does_not_spawn():
	var b := BridgeScript.new()
	b.set_busctl_path(ProjectSettings.globalize_path(FAKE_BUSCTL))
	var r = b._run_busctl(PackedStringArray(["list"]))
	if r.get("ok") != false: return Runner.assert_true(false, "no bus address -> ok=false")
	if not str(r.get("error", "")).contains("bus"): return Runner.assert_true(false, "error mentions missing bus")
	b.free()
	return true

func test_list_names_returns_mpris_players():
	var b := _make_bridge()
	var r = b.list_names()
	if not (r is Array): return Runner.assert_true(false, "list_names returns Array")
	if not (r.has(MPRIS)): return Runner.assert_true(false, "spotify listed: " + str(r))
	var notif_count: int = 0
	for n in r: if String(n).begins_with("org.freedesktop.Notifications"): notif_count += 1
	if notif_count != 0: return Runner.assert_true(false, "notification service filtered out of names")
	b.free()
	return true

func test_get_property_playback_status():
	var b := _make_bridge()
	var v = b.get_property(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "PlaybackStatus")
	var r = Runner.assert_eq(v, "Playing", "s decoded to String")
	if r != true: return r
	b.free()
	return true

func test_get_property_metadata_decoded_dict():
	var b := _make_bridge()
	var md = b.get_property(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "Metadata")
	if not (md is Dictionary): return Runner.assert_true(false, "a{sv} -> Dictionary")
	var r = Runner.assert_eq(String(md.get("xesam:title", "")), "Bad Guy", "title decoded")
	if r != true: return r
	r = Runner.assert_eq(String(MD_artist(md)), "Billie Eilish", "artist array unwrapped")
	if r != true: return r
	r = Runner.assert_eq(String(md.get("mpris:artUrl", "")), "file:///tmp/opencode/cover.png", "artUrl decoded")
	b.free()
	return r

func MD_artist(md) -> String:
	var a = md.get("xesam:artist", [])
	if a is Array and a.size() > 0:
		return String(a[0])
	return ""

func test_get_property_position_is_int():
	var b := _make_bridge()
	var r = Runner.assert_eq(b.get_property(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "Position"), 42000000, "x decoded to int")
	b.free()
	return r

func test_call_control_methods_ok():
	var b := _make_bridge()
	var r = b.call_method(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "PlayPause")
	if r.get("ok") != true: return Runner.assert_true(false, "PlayPause ok=true: " + str(r))
	if r.get("data") != null: return Runner.assert_true(false, "void call -> data null")
	var n = b.call_method(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "Next")
	if n.get("ok") != true: return Runner.assert_true(false, "Next ok=true")
	b.free()
	return true

func test_call_unknown_method_error_contract():
	var b := _make_bridge()
	var r = b.call_method(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "BogusMethod")
	if r.get("ok") != false: return Runner.assert_true(false, "unknown method -> ok=false")
	if not str(r.get("error", "")).contains("not found"): return Runner.assert_true(false, "stderr surfaced: " + str(r))
	if int(r.get("exit", 0)) == 0: return Runner.assert_true(false, "exit code != 0")
	b.free()
	return true

func test_cache_limits_subprocesses():
	var b := _make_bridge()
	var log := OS.get_temp_dir().path_join("fake-busctl-call-log.txt")
	DirAccess.remove_absolute(log)
	OS.set_environment("FAKE_CALL_LOG", log)
	b._cache.clear()
	var v = b.get_property(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "PlaybackStatus")
	var w = b.get_property(MPRIS, MPRIS_OBJ, MPRIS_IFACE, "PlaybackStatus")
	OS.set_environment("FAKE_CALL_LOG", "")
	b.free()
	if v != w: return Runner.assert_true(false, "cached value consistent")
	if not FileAccess.file_exists(log): return Runner.assert_true(false, "fake busctl was invoked")
	var f := FileAccess.open(log, FileAccess.READ)
	var lines = f.get_as_text().strip_edges().split("\n") if f != null else []
	if f != null: f.close()
	return Runner.assert_true(lines.size() == 1, "one subprocess per cache window, got %d" % lines.size())