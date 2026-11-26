extends "res://scripts/objects/desktop_object.gd"
## Moniteur système (lot L) : CPU, RAM, GPU, température de la machine du joueur, lus dans /proc et /sys (pas de
## pont, pas de processus). Une mesure par seconde.

const SIZE := Vector2(0.5, 0.42)

var _bars: Dictionary = {}
var _labels: Dictionary = {}
var _prev_cpu: Array = []
var _tick := 0.0

func _ready() -> void:
	make_panel(SIZE)
	make_label("System", Vector2(-SIZE.x / 2.0 + 0.03, SIZE.y / 2.0 - 0.03), 40, Color(1, 1, 1))
	var y := SIZE.y / 2.0 - 0.12
	for k in ["CPU", "RAM", "GPU", "TEMP"]:
		_labels[k] = make_label(k, Vector2(-SIZE.x / 2.0 + 0.03, y + 0.02), 26, Color(0.75, 0.8, 0.9))
		_bars[k] = make_bar(Vector2(-SIZE.x / 2.0 + 0.03, y - 0.035), Vector2(SIZE.x - 0.06, 0.018),
			{"CPU": Color(0.3, 0.75, 1), "RAM": Color(0.55, 0.85, 0.4), "GPU": Color(0.95, 0.6, 0.2), "TEMP": Color(1, 0.35, 0.3)}[k])
		y -= 0.085

func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0:
		return
	_tick = 1.0
	var cpu := cpu_usage()
	_show("CPU", cpu, "CPU  %d %%" % roundi(cpu * 100.0) if cpu >= 0.0 else "CPU  —")
	var mem := mem_usage()
	_show("RAM", mem[0], "RAM  %.1f / %.1f GiB" % [mem[1], mem[2]] if mem[0] >= 0.0 else "RAM  —")
	var gpu := gpu_usage()
	_show("GPU", gpu, "GPU  %d %%" % roundi(gpu * 100.0) if gpu >= 0.0 else "GPU  —")
	var t := temperature()
	_show("TEMP", (t - 30.0) / 70.0 if t > 0.0 else 0.0, "TEMP  %d °C" % roundi(t) if t > 0.0 else "TEMP  —")

func _show(k: String, ratio: float, text: String) -> void:
	set_bar(_bars[k], maxf(ratio, 0.0))
	_labels[k].text = text

## Lecture ligne à ligne : les fichiers de /proc et /sys annoncent une taille nulle (get_as_text les lirait vides).
static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var lines := PackedStringArray()
	while not f.eof_reached() and lines.size() < 256:
		lines.append(f.get_line())
	f.close()
	return "\n".join(lines)

## Part du CPU occupée depuis la mesure précédente (0..1), -1 à la première mesure ou si /proc est illisible.
func cpu_usage() -> float:
	var line := _read("/proc/stat").get_slice("\n", 0)
	if not line.begins_with("cpu "):
		return -1.0
	var v: Array = []
	for x in line.substr(4).strip_edges().split(" ", false):
		v.append(int(x))
	var idle: int = v[3] + (v[4] if v.size() > 4 else 0)
	var total := 0
	for x in v:
		total += x
	var out := -1.0
	if not _prev_cpu.is_empty() and total > _prev_cpu[0]:
		out = 1.0 - float(idle - _prev_cpu[1]) / float(total - _prev_cpu[0])
	_prev_cpu = [total, idle]
	return out

## [ratio, utilisée GiB, totale GiB] ; ratio -1 si illisible.
static func mem_usage() -> Array:
	var total := 0
	var avail := 0
	for l in _read("/proc/meminfo").split("\n"):
		if l.begins_with("MemTotal:"):
			total = int(l.split(":")[1].strip_edges().split(" ")[0])
		elif l.begins_with("MemAvailable:"):
			avail = int(l.split(":")[1].strip_edges().split(" ")[0])
	if total <= 0:
		return [-1.0, 0.0, 0.0]
	return [1.0 - float(avail) / total, (total - avail) / 1048576.0, total / 1048576.0]

## Occupation du GPU (amdgpu / i915 récents : gpu_busy_percent), -1 si indisponible.
static func gpu_usage() -> float:
	for i in 4:
		var s := _read("/sys/class/drm/card%d/device/gpu_busy_percent" % i).strip_edges()
		if s.is_valid_int():
			return int(s) / 100.0
	return -1.0

## Température du processeur (k10temp, coretemp, zenpower) sinon du premier capteur, en °C ; 0 si indisponible.
static func temperature() -> float:
	var fallback := 0.0
	for i in 16:
		var base := "/sys/class/hwmon/hwmon%d" % i
		var name := _read(base + "/name").strip_edges()
		if name == "":
			continue
		var v := _read(base + "/temp1_input").strip_edges()
		if not v.is_valid_int():
			continue
		var c := int(v) / 1000.0
		if name in ["k10temp", "coretemp", "zenpower", "cpu_thermal"]:
			return c
		if fallback == 0.0:
			fallback = c
	return fallback
