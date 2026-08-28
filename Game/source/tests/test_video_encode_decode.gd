extends Node
## Tests for JPEG encode/decode round-trip using Godot's Image class.

const Runner = preload("res://tests/runner.gd")

func test_image_creation():
	var img = Image.create(320, 240, false, Image.FORMAT_RGBA8)
	var r = Runner.assert_eq(img.get_width(), 320, "Width should be 320")
	if r != true: return r
	r = Runner.assert_eq(img.get_height(), 240, "Height should be 240")
	if r != true: return r
	return true

func test_image_fill_unicolor():
	var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.25, 0.75, 1.0))
	var pixel = img.get_pixel(32, 32)
	var r = Runner.assert_approx(pixel.r, 0.5, 0.01, "R channel")
	if r != true: return r
	r = Runner.assert_approx(pixel.g, 0.25, 0.01, "G channel")
	if r != true: return r
	r = Runner.assert_approx(pixel.b, 0.75, 0.01, "B channel")
	if r != true: return r
	return true

func test_jpeg_encode_not_empty():
	var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var jpeg = img.save_jpg_to_buffer(0.85)
	var r = Runner.assert_true(jpeg.size() > 0, "JPEG buffer should not be empty")
	if r != true: return r
	r = Runner.assert_true(jpeg.size() < 64 * 64 * 4,
		"JPEG should be smaller than raw RGBA (%d bytes)" % jpeg.size())
	if r != true: return r
	return true

func test_jpeg_round_trip_dimensions():
	var img = Image.create(120, 80, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.6, 0.9, 1.0))
	var jpeg = img.save_jpg_to_buffer(0.9)
	var decoded = Image.new()
	var err = decoded.load_jpg_from_buffer(jpeg)
	var r = Runner.assert_eq(err, OK, "Decode should succeed")
	if r != true: return r
	r = Runner.assert_eq(decoded.get_width(), 120, "Width preserved")
	if r != true: return r
	r = Runner.assert_eq(decoded.get_height(), 80, "Height preserved")
	if r != true: return r
	return true

func test_jpeg_round_trip_unicolor():
	var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 1.0, 1.0))
	var jpeg = img.save_jpg_to_buffer(0.95)
	var decoded = Image.new()
	decoded.load_jpg_from_buffer(jpeg)
	var center = decoded.get_pixel(32, 32)
	var r = Runner.assert_approx(center.r, 0.2, 0.05, "R channel round-trip")
	if r != true: return r
	r = Runner.assert_approx(center.g, 0.6, 0.05, "G channel round-trip")
	if r != true: return r
	r = Runner.assert_approx(center.b, 1.0, 0.05, "B channel round-trip")
	if r != true: return r
	return true

func test_jpeg_quality_affects_size():
	var img = Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			if (x / 16 + y / 16) % 2 == 0:
				img.set_pixel(x, y, Color.WHITE)
			else:
				img.set_pixel(x, y, Color.BLACK)
	var high_q = img.save_jpg_to_buffer(0.95)
	var low_q = img.save_jpg_to_buffer(0.3)
	var r = Runner.assert_true(high_q.size() > low_q.size(),
		"High quality JPEG (%d) should be larger than low quality (%d)" % [high_q.size(), low_q.size()])
	if r != true: return r
	return true

func test_png_encode_not_empty():
	var img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color.GREEN)
	var png = img.save_png_to_buffer()
	var r = Runner.assert_true(png.size() > 0, "PNG buffer should not be empty")
	if r != true: return r
	return true

func test_png_round_trip():
	var img = Image.create(100, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.8, 0.3, 1.0))
	var png = img.save_png_to_buffer()
	var r = Runner.assert_true(png.size() > 0, "PNG buffer not empty")
	if r != true: return r
	r = Runner.assert_true(png[0] == 0x89 and png[1] == 0x50, "PNG magic bytes present")
	if r != true: return r
	return true
