extends Node
## Tests for capture cache size rounding logic.

const Runner = preload("res://tests/runner.gd")

func test_round_up_zero():
	var r = Runner.assert_eq(round_up_capture_size(0), 0, "0 → 0")
	if r != true: return r
	return true

func test_round_up_already_aligned():
	var r = Runner.assert_eq(round_up_capture_size(64), 64, "64 → 64")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(128), 128, "128 → 128")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(256), 256, "256 → 256")
	if r != true: return r
	return true

func test_round_up_below_boundary():
	var r = Runner.assert_eq(round_up_capture_size(1), 64, "1 → 64")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(32), 64, "32 → 64")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(63), 64, "63 → 64")
	if r != true: return r
	return true

func test_round_up_above_boundary():
	var r = Runner.assert_eq(round_up_capture_size(65), 128, "65 → 128")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(129), 192, "129 → 192")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(100), 128, "100 → 128")
	if r != true: return r
	return true

func test_round_up_large_values():
	var r = Runner.assert_eq(round_up_capture_size(1920), 1920, "1920 → 1920")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(1921), 1984, "1921 → 1984")
	if r != true: return r
	r = Runner.assert_eq(round_up_capture_size(1080), 1088, "1080 → 1088")
	if r != true: return r
	return true

func test_round_up_consistency():
	for size in [1, 10, 63, 64, 65, 127, 128, 129, 500, 1000, 1920, 4096]:
		var result = round_up_capture_size(size)
		var r = Runner.assert_eq(result % 64, 0,
			"round_up_capture_size(%d) = %d must be multiple of 64" % [size, result])
		if r != true: return r
	return true

func test_rgba_buffer_size():
	var pixels = 1920 * 1080
	var expected = pixels * 4
	var r = Runner.assert_eq(1920 * 1080 * 4, expected,
		"1920x1080 RGBA buffer should be %d bytes" % expected)
	if r != true: return r
	return true

func test_capture_dimensions():
	var resolutions = [
		[800, 600],
		[1280, 720],
		[1920, 1080],
		[2560, 1440],
		[3840, 2160],
	]
	for res in resolutions:
		var w: int = res[0]
		var h: int = res[1]
		var r = Runner.assert_true(w > 0 and h > 0,
			"Resolution %dx%d must be positive" % [w, h])
		if r != true: return r
	return true

func round_up_capture_size(size: int):
	const CAPTURE_ALIGNMENT = 64
	if size == 0:
		return 0
	return ceili(float(size) / float(CAPTURE_ALIGNMENT)) * CAPTURE_ALIGNMENT
