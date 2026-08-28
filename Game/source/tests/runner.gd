#!/usr/bin/env godot --headless --script
## Minimalist test runner for CyberRealm GDScript tests.
## Usage: godot --headless --script tests/runner.gd
##
## Discovers all test_*.gd files in the same directory, instantiates them,
## runs every public test_*() method, and reports PASS/FAIL with a summary.

extends SceneTree

var _total := 0
var _passed := 0
var _failed := 0
var _errors: PackedStringArray = []

func _init() -> void:
	var dir_path := ProjectSettings.globalize_path("res://tests/")
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("runner: cannot open tests/ directory: " + dir_path)
		quit(1)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			_run_test_script("res://tests/" + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	print("")
	print("═══════════════════════════════════════════════")
	print("  RESULTS: %d passed, %d failed, %d total" % [_passed, _failed, _total])
	print("═══════════════════════════════════════════════")
	if not _errors.is_empty():
		print("")
		for e in _errors:
			print("  FAIL: " + e)
	quit(1 if _failed > 0 else 0)

func _run_test_script(resource_path: String) -> void:
	var script: Script = load(resource_path)
	if script == null:
		push_error("runner: cannot load " + resource_path)
		return

	var instance = Node.new()
	instance.set_script(script)
	root.add_child(instance)

	for method in instance.get_method_list():
		var mname: String = method["name"]
		if mname.begins_with("test_") and (method["flags"] & METHOD_FLAG_CONST) == 0:
			_total += 1
			var short := resource_path.get_file() + "::" + mname
			var result = instance.call(mname)
			if result == true:
				_passed += 1
				print("  ✓ " + short)
			else:
				_failed += 1
				var msg := str(result) if result != false else "assertion failed"
				print("  ✗ " + short + " — " + msg)
				_errors.append(short + " — " + msg)

	instance.free()

# ── Assertion helpers ──────────────────────────────────────────────────
static func assert_true(condition: bool, msg: String = ""):
	if not condition:
		return "assert_true: " + msg if msg != "" else "assert_true failed"
	return true

static func assert_eq(a, b, msg: String = ""):
	if a != b:
		return "assert_eq: %s != %s — %s" % [str(a), str(b), msg if msg != "" else ""]
	return true

static func assert_ne(a, b, msg: String = ""):
	if a == b:
		return "assert_ne: %s == %s — %s" % [str(a), str(b), msg if msg != "" else ""]
	return true

static func assert_approx(a: float, b: float, tolerance: float = 0.01, msg: String = ""):
	if absf(a - b) > tolerance:
		return "assert_approx: |%f - %f| > %f — %s" % [a, b, tolerance, msg if msg != "" else ""]
	return true
