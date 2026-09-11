extends Node
## Host service bridge — accès permissif aux services D-Bus du PC HÔTE via
## busctl (systemd ≥ 256, --json=short). Lire et contrôler n'importe quel
## service D-Bus ; l'affichage appartient aux scripts des objets de niveau.

const CACHE_TTL_MSEC := 500
const MONITOR_MAX_BYTES := 4 << 20
const MONITOR_KEEP_LINES := 200

var bus_address := ""
var _busctl_path := "busctl"
var _runtime_dir := ""
var _cache := {} # key -> {value: Variant, msec: int}
var _ui_layer: CanvasLayer = null
var _art_cache := {} # uri -> Texture2D

func _ready() -> void:
	add_to_group("host_services")

func set_bus_address(addr: String) -> void:
	bus_address = addr

func get_bus_address() -> String:
	return bus_address

func set_busctl_path(path: String) -> void:
	_busctl_path = path

func set_runtime_dir(dir: String) -> void:
	_runtime_dir = dir

func set_ui_layer(canvas: CanvasLayer) -> void:
	_ui_layer = canvas

func get_ui_layer() -> CanvasLayer:
	return _ui_layer

static func default_runtime_dir() -> String:
	var rt := OS.get_environment("XDG_RUNTIME_DIR")
	if rt.is_empty():
		rt = OS.get_temp_dir()
	return rt

func _resolved_runtime_dir() -> String:
	return _runtime_dir if not _runtime_dir.is_empty() else default_runtime_dir()

# ── busctl primitives ────────────────────────────────────────────────

func list_names() -> Array[String]:
	var out: Array[String] = []
	var r := _run_busctl(PackedStringArray(["--no-legend", "list"]))
	if not r.get("ok"):
		return out
	for line: String in String(r.get("out", "")).split("\n"):
		var name := line.strip_edges().split(" ", false)[0] if not line.strip_edges().is_empty() else ""
		if name.begins_with("org.mpris.MediaPlayer2."):
			out.append(name)
	return out

# Godot 4.7 ne permet pas de redéfinir `func call(...)` (Object.call est natif,
# signature figée) → méthode nommée `call_method` pour l'invocation D-Bus.
func call_method(dest: String, path: String, iface: String, method: String,
		signature := "", args: Array = []) -> Dictionary:
	var cache_key := "call|" + dest + "|" + path + "|" + iface + "|" + method
	var hit := _cache_get(cache_key, method)
	if hit[0]:
		return hit[1]
	var argv := PackedStringArray(["--json=short", "call", dest, path, iface, method])
	if not signature.is_empty():
		argv.append(signature)
		for a in args:
			argv.append(str(a))
	var raw := _run_busctl(argv)
	var result := {"ok": raw.get("ok", false), "data": null, "error": "", "exit": 0}
	if raw.get("ok"):
		if String(raw.get("out", "")).strip_edges().is_empty():
			result["data"] = null
		else:
			result["data"] = _decode_reply(String(raw.get("out", "")), true)
	else:
		result["error"] = String(raw.get("error", ""))
		result["exit"] = int(raw.get("exit", 1))
	_cache_put(cache_key, method, result)
	return result

func get_property(dest: String, path: String, iface: String, name: String) -> Variant:
	var cache_key := "prop|" + dest + "|" + path + "|" + iface + "|" + name
	var hit := _cache_get(cache_key, name)
	if hit[0]:
		return hit[1]
	var raw := _run_busctl(PackedStringArray(["--json=short", "get-property", dest, path, iface, name]))
	var value: Variant = null
	if raw.get("ok"):
		var line := String(raw.get("out", "")).strip_edges()
		if not line.is_empty():
			value = _decode_reply(line, false)
	_cache_put(cache_key, name, value)
	return value

func _run_busctl(args: PackedStringArray) -> Dictionary:
	if bus_address.is_empty():
		return {"ok": false, "out": "", "error": "no host bus address", "exit": 1}
	var full := PackedStringArray(["--user", "--address=" + bus_address])
	full.append_array(args)
	var out := []
	# read_stderr=true: stderr est fusionnée dans `out` (pas de param err séparé
	# dans cette build 4.7). Sur échec, out contient le message du service.
	var exit_code := OS.execute(_busctl_path, full, out, true)
	var joined := _join_out(out)
	return {"ok": exit_code == 0, "out": joined, "error": joined, "exit": exit_code}

static func _join_out(out: Array) -> String:
	var parts := PackedStringArray()
	for l in out:
		parts.append(str(l))
	return "\n".join(parts)

# ── cache ────────────────────────────────────────────────────────────

func _cache_get(key: String, name: String) -> Array:
	# returns [hit: bool, value: Variant] — stored value directly on hit
	if not _cache.has(key):
		return [false, null]
	var entry: Dictionary = _cache[key]
	if Time.get_ticks_msec() - int(entry.get("msec", 0)) >= CACHE_TTL_MSEC:
		_cache.erase(key)
		return [false, null]
	return [true, entry.get("value")]

func _cache_put(key: String, name: String, value: Variant) -> void:
	_cache[key] = {"value": value, "msec": Time.get_ticks_msec()}

# ── décodeur canonique ───────────────────────────────────────────────

func _decode_reply(json_line: String, from_call: bool) -> Variant:
	var parsed = JSON.parse_string(json_line)
	if not (parsed is Dictionary):
		return null
	var t := String(parsed.get("type", ""))
	if t.is_empty():
		return null
	var d = parsed.get("data")
	if not from_call:
		return _decode_value(t, d)
	# call: data = array of return args
	if d is Array:
		if d.size() == 0:
			return null
		if d.size() == 1:
			return _decode_value(t, d[0])
		var out: Array = []
		for a in d:
			out.append(_decode_value(t, a))
		return out
	return _decode_value(t, d)

static func _decode_value(type: String, value) -> Variant:
	# variant/object passthrough
	if value is Dictionary and value.has("type") and value.has("data"):
		return _decode_value(String(value.get("type", "")), value.get("data"))
	match type:
		"": return null
		"s", "o", "g": return String(value)
		"b": return bool(value)
		"y", "n", "q": return int(value)
		"i": return int(value)
		"u": return int(value)
		"x", "t": return int(value)
		"d": return float(value)
		"h": return int(value)
		"ay": return PackedByteArray(value)
		"v":
			return _decode_value(String(value.get("type", "")), value.get("data")) if value is Dictionary else value
		"as": return Array(value)
		_:
			pass
	if type.begins_with("a{"):
		var out := {}
		if value is Dictionary:
			for k in value:
				out[String(k)] = _decode_value("v", value[k])
		return out
	if type.begins_with("a"):
		var out2: Array = []
		var elem := type.substr(1)
		if value is Array:
			for v in value:
				out2.append(_decode_value(elem, v))
		return out2
	if type.begins_with("("):
		var out3: Array = []
		if value is Array:
			out3 = value.duplicate()
		return out3
	return value

# ── journal de signaux ────────────────────────────────────────────────

var _monitor_pids := {}       # journal_id -> pid
var _monitor_offsets := {}    # journal_id -> byte offset
var _journal_iface := {}      # journal_id -> String
var _journal_member := {}     # journal_id -> String
var _journal_dest := {}       # journal_id -> dest String

func subscribe(dest: String, iface := "", member := "") -> int:
	if bus_address.is_empty() or dest.is_empty():
		return 0
	var already := -1
	for k in _monitor_pids:
		if str(_journal_dest.get(k, "")) == dest:
			already = int(k)
			break
	if already != -1:
		return already
	var id := _next_journal_id()
	var rt := _resolved_runtime_dir()
	var log_path := rt.path_join("cyberrealm-svc-%d.log" % id)
	var cmd := "%s --user --address='%s' monitor --json=short %s > '%s' 2>&1 &" % [
		_busctl_path, bus_address, dest, log_path]
	var sh_ok := OS.execute("sh", ["-c", cmd], [], true)
	if sh_ok != 0:
		return 0
	# rewind past anything pre-existing
	var offset := 0
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f != null:
		f.seek_end()
		offset = f.get_position()
		f.close()
	_monitor_pids[id] = 0 # PID lookup unavailable via sh -c; tracked by parent process below
	_journal_iface[id] = iface
	_journal_member[id] = member
	_journal_dest[id] = dest
	_monitor_offsets[id] = offset
	# Record the actual child pid so unsubscribe can kill it precisely.
	var pid := _find_monitor_pid(log_path, dest)
	if pid > 0:
		_monitor_pids[id] = pid
	return id

var _journal_seq := 1000
func _next_journal_id() -> int:
	_journal_seq += 1
	return _journal_seq

func _find_monitor_pid(log_path: String, dest: String) -> int:
	var out := []
	var ec := OS.execute("pgrep", ["-f", "monitor --json=short " + dest], out, true)
	if ec == 0 and out.size() > 0:
		return int(String(out[0]).strip_edges())
	return 0

func read_events(id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _monitor_offsets.has(id):
		return out
	var rt := _resolved_runtime_dir()
	var log_path := rt.path_join("cyberrealm-svc-%d.log" % id)
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		return out
	var offset := int(_monitor_offsets[id])
	var size := f.get_length()
	if size > offset:
		f.seek(offset)
		var remaining := size - offset
		var buf := f.get_buffer(remaining)
		f.close()
		var data := buf.get_string_from_utf8()
		_monitor_offsets[id] = size
		var iface := String(_journal_iface.get(id, ""))
		var member := String(_journal_member.get(id, ""))
		for line: String in data.split("\n"):
			var ev := _parse_monitor_line(line)
			if ev.is_empty():
				continue
			if not iface.is_empty() and String(ev.get("interface", "")) != iface:
				continue
			if not member.is_empty() and String(ev.get("member", "")) != member:
				continue
			out.append(ev)
		_rotate_log(id, log_path)
	else:
		f.close()
	return out

func _parse_monitor_line(line: String) -> Dictionary:
	if line.strip_edges().is_empty():
		return {}
	if line.length() > 1 << 20:
		return {}
	var parsed = JSON.parse_string(line)
	if not (parsed is Dictionary):
		return {}
	var out := {}
	out["interface"] = String(parsed.get("interface", "")).strip_edges()
	out["member"] = String(parsed.get("member", "")).strip_edges()
	out["sender"] = String(parsed.get("sender", "")).strip_edges()
	out["args"] = parsed.get("args", [])
	out["ts_msec"] = Time.get_ticks_msec()
	return out

func _rotate_log(id: int, log_path: String) -> void:
	var fi := FileAccess.open(log_path, FileAccess.READ)
	if fi == null:
		return
	var size := fi.get_length()
	fi.close()
	if size <= MONITOR_MAX_BYTES:
		return
	var text := FileAccess.get_file_as_string(log_path)
	var lines := text.split("\n")
	if lines.size() > MONITOR_KEEP_LINES:
		text = "\n".join(lines.slice(lines.size() - MONITOR_KEEP_LINES))
	# a single over-long line can still exceed the cap: keep only the tail bytes
	if text.length() > MONITOR_MAX_BYTES:
		text = text.substr(text.length() - MONITOR_MAX_BYTES)
	var f := FileAccess.open(log_path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	_monitor_offsets[id] = 0

func unsubscribe(id: int) -> void:
	if not _monitor_pids.has(id):
		return
	var pid := int(_monitor_pids[id])
	if pid > 0:
		var ec := OS.execute("kill", ["-0", str(pid)], [], true)
		if ec == 0:
			OS.execute("kill", [str(pid)], [], true)
	_monitor_pids.erase(id)
	_monitor_offsets.erase(id)
	_journal_iface.erase(id)
	_journal_member.erase(id)
	_journal_dest.erase(id)

func _exit_tree() -> void:
	for id in _monitor_pids.keys():
		unsubscribe(id)

static func purge_stale_logs(runtime_dir: String) -> void:
	if runtime_dir.is_empty():
		return
	var d := DirAccess.open(runtime_dir)
	if d == null:
		return
	for name: String in d.get_files():
		if name.begins_with("cyberrealm-svc-") and name.ends_with(".log"):
			d.remove(name)
