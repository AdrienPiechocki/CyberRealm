extends Node
## Tests de la netteté selon la distance (scripts/main/window_sharpness.gd).

const Runner = preload("res://tests/runner.gd")
const Sharp = preload("res://scripts/main/window_sharpness.gd")

func test_quantize_and_pressure():
	var r: Variant = Runner.assert_eq([Sharp.quantize(0.7, 2.0), Sharp.quantize(1.2, 2.0), Sharp.quantize(1.45, 2.0), Sharp.quantize(3.0, 2.0)],
		[1.0, 1.25, 1.5, 2.0], "paliers (10 % de tolérance)")
	if r is String: return r
	r = Runner.assert_eq(Sharp.quantize(3.0, 1.5), 1.5, "borné par l'option")
	if r is String: return r
	return Runner.assert_eq([Sharp.pressure_cap(2.0, 0), Sharp.pressure_cap(2.0, 1), Sharp.pressure_cap(2.0, 2)], [2.0, 1.25, 1.0],
		"sous pression GPU, l'échelle redescend d'abord")

class FakeComp extends Node:
	var scales: Dictionary = {}
	var pressure := 0
	var calls: Array = []
	func set_window_scale(id: int, s: float) -> void: scales[id] = s; calls.append([id, s])
	func get_window_scale(id: int) -> float: return float(scales.get(id, 1.0))
	func get_capture_pressure() -> int: return pressure

class FakeWin3D extends Node:
	var quads: Dictionary = {}
	func is_window_interacting() -> bool: return false

class FakeSettings extends Node:
	var max_scale := 2.0
	func get_window_sharpness_max() -> float: return max_scale

class FakeFocus extends Node:
	var active := false
	func is_active() -> bool: return active

class TestSharp extends "res://scripts/main/window_sharpness.gd":
	var want := 2.0
	func desired_scale(_c, _q, _w, _cur) -> float: return want

func _tick(s: Node, n := 1) -> void:
	for i in n:
		s._cd = 0.0
		s._process(0.0)

func test_hysteresis_and_focus():
	var comp := FakeComp.new()
	var w := FakeWin3D.new()
	var quad := MeshInstance3D.new()
	add_child(quad)
	w.quads[1] = quad
	var st := FakeSettings.new()
	var f := FakeFocus.new()
	var s := TestSharp.new()
	add_child(s)
	s.setup(comp, w, f, null, st)
	_tick(s)
	var r: Variant = Runner.assert_eq(comp.calls, [], "pas d'application avant 1 s de stabilité")
	if r is String: return _done([comp, w, quad, st, f, s], r)
	s._pending[1]["since"] = Time.get_ticks_msec() / 1000.0 - 2.0
	_tick(s)
	r = Runner.assert_eq(comp.scales.get(1), 2.0, "échelle appliquée après stabilité")
	if r is String: return _done([comp, w, quad, st, f, s], r)
	f.active = true
	_tick(s)
	r = Runner.assert_eq(comp.scales.get(1), 1.0, "mode focus : retour immédiat à 1")
	if r is String: return _done([comp, w, quad, st, f, s], r)
	f.active = false
	st.max_scale = 1.0
	_tick(s, 3)
	return _done([comp, w, quad, st, f, s], Runner.assert_eq(comp.scales.get(1), 1.0, "option désactivée : reste à 1"))

func _done(nodes: Array, r: Variant) -> Variant:
	for n in nodes:
		if is_instance_valid(n): n.free()
	return r
