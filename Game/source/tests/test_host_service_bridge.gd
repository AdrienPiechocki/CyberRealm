extends Node

const Runner = preload("res://tests/runner.gd")
const BridgeScript = preload("res://scripts/interaction/host_service_bridge.gd")
const FAKE_BUSCTL := "res://tests/fixtures/fake_busctl.sh"
const MPRIS := "org.mpris.MediaPlayer2.spotify"
const MPRIS_OBJ := "/org/mpris/MediaPlayer2"
const MPRIS_IFACE := "org.mpris.MediaPlayer2.Player"
const NOTIF := "org.freedesktop.Notifications"
const MONITOR_LINE := '{"type":"signal","sender":"org.freedesktop.DBus","destination":":1.2","path":"/org/freedesktop/Notifications","interface":"org.freedesktop.Notifications","member":"Notify","args":["sway",0,"dialog-information","Build done","OK",[],5000]}'

func _make_bridge() -> BridgeScript:
	var bridge = BridgeScript.new()
	bridge.set_busctl_path(ProjectSettings.globalize_path(FAKE_BUSCTL))
	bridge.set_runtime_dir(OS.get_temp_dir())
	bridge.set_bus_address("unix:path=/tmp/fake-bus")
	return bridge

func _tmp_runtime_dir(test_name: String) -> String:
	var d := OS.get_temp_dir().path_join("hsb-" + test_name)
	DirAccess.make_dir_recursive_absolute(d)
	return d

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

func test_subscribe_creates_log_and_reads_events():
	OS.set_environment("FAKE_MONITOR_JSON", MONITOR_LINE)
	var b := _make_bridge()
	var rt := _tmp_runtime_dir("subscribe")
	b.set_runtime_dir(rt)
	var id := b.subscribe(NOTIF, "org.freedesktop.Notifications", "Notify")
	if id <= 0: return Runner.assert_true(false, "subscribe returns id>0")
	var found := false
	for f in DirAccess.open(rt).get_files():
		if f.begins_with("cyberrealm-svc-"): found = true
	if not found: return Runner.assert_true(false, "dump file created in runtime dir")
	# fake monitor echoes MONITOR_LINE on spawn; read it
	OS.delay_msec(50)
	var events := b.read_events(id)
	if events.is_empty(): return Runner.assert_true(false, "at least one event read")
	var ev: Dictionary = events[0]
	var r = Runner.assert_eq(String(ev.get("member", "")), "Notify", "member kept")
	if r != true: return r
	r = Runner.assert_eq(String(ev.get("interface", "")), "org.freedesktop.Notifications", "iface kept")
	if r != true: return r
	r = Runner.assert_eq(String((ev.get("args", []) as Array)[0]), "sway", "args decoded")
	if r != true: return r
	b.free()
	return true

func test_read_events_incremental_offset():
	OS.set_environment("FAKE_MONITOR_JSON", MONITOR_LINE)
	var b := _make_bridge()
	var rt := _tmp_runtime_dir("incremental")
	b.set_runtime_dir(rt)
	var id := b.subscribe(NOTIF)
	OS.delay_msec(50)
	var first := b.read_events(id)
	if first.is_empty(): return Runner.assert_true(false, "first batch non-empty")
	# append a second fixture line directly to the dump
	var f := FileAccess.open(rt.path_join("cyberrealm-svc-%d.log" % id), FileAccess.READ_WRITE)
	if f == null: return Runner.assert_true(false, "dump openable")
	f.seek_end()
	f.store_line(MONITOR_LINE.replace("Build done", "Second"))
	f.close()
	var second := b.read_events(id)
	if second.is_empty(): return Runner.assert_true(false, "second batch non-empty")
	if not str(second[0]).contains("Second"): return Runner.assert_true(false, "only new event returned")
	b.free()
	return true

func test_subscribe_filter_excludes_other_members():
	OS.set_environment("FAKE_MONITOR_JSON", MONITOR_LINE)
	var b := _make_bridge()
	var rt := _tmp_runtime_dir("filter")
	b.set_runtime_dir(rt)
	var id := b.subscribe(NOTIF, "org.freedesktop.Notifications", "ActionInvoked")
	OS.delay_msec(50)
	var events := b.read_events(id)
	var r = Runner.assert_eq(events.is_empty(), true, "Notify event filtered out of ActionInvoked journal")
	b.free()
	return r

func test_rotation_truncates_oversize_dump():
	OS.set_environment("FAKE_MONITOR_JSON", MONITOR_LINE)
	var b := _make_bridge()
	var rt := _tmp_runtime_dir("rotate")
	b.set_runtime_dir(rt)
	var id := b.subscribe(NOTIF)
	var log_path := rt.path_join("cyberrealm-svc-%d.log" % id)
	OS.delay_msec(50)
	b.read_events(id)
	# oversize dump with a tail of fresh lines
	var f := FileAccess.open(log_path, FileAccess.WRITE)
	var big := ""
	for i in 50000: big += "x"
	big = big.repeat(100)
	f.store_string(big + "\n" + MONITOR_LINE + "\n" + MONITOR_LINE)
	f.close()
	b._monitor_offsets[id] = 0
	var events := b.read_events(id)
	b.unsubscribe(id)
	var now_size := FileAccess.get_file_as_string(log_path).length()
	if now_size > BridgeScript.MONITOR_MAX_BYTES: return Runner.assert_true(false, "file rotated below max")
	if events.is_empty(): return Runner.assert_true(false, "tail events survived rotation")
	b.free()
	return true

func test_purge_stale_logs():
	var rt := _tmp_runtime_dir("purge")
	var f := FileAccess.open(rt.path_join("cyberrealm-svc-1234.log"), FileAccess.WRITE)
	f.store_string("x"); f.close()
	var keep := FileAccess.open(rt.path_join("keep.txt"), FileAccess.WRITE)
	keep.store_string("x"); keep.close()
	BridgeScript.purge_stale_logs(rt)
	var r = Runner.assert_eq(FileAccess.file_exists(rt.path_join("cyberrealm-svc-1234.log")), false, "svc log purged")
	if r != true: return r
	r = Runner.assert_eq(FileAccess.file_exists(rt.path_join("keep.txt")), true, "other files untouched")
	return r
