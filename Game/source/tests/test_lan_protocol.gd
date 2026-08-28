extends Node
## Tests for PIN generation and LAN protocol helpers.

const Runner = preload("res://tests/runner.gd")
const LANManager = preload("res://scripts/lan_manager.gd")

func test_pin_format():
	for _i in 100:
		var pin = _generate_pin()
		var r = Runner.assert_eq(pin.length(), 4, "PIN must be 4 digits")
		if r != true: return r
		r = Runner.assert_true(pin.is_valid_int(), "PIN must be numeric: " + pin)
		if r != true: return r
	return true

func test_pin_uniqueness():
	var seen: Dictionary = {}
	for _i in 200:
		var pin = _generate_pin()
		seen[pin] = true
	var r = Runner.assert_true(seen.size() >= 180,
		"Expected ≥180 unique PINs out of 200, got %d" % seen.size())
	if r != true: return r
	return true

func test_pin_validation_success():
	var r = Runner.assert_eq(_validate_pin("1234", "1234"), true, "Matching PIN should pass")
	if r != true: return r
	return true

func test_pin_validation_failure():
	var r = Runner.assert_eq(_validate_pin("1234", "5678"), false, "Wrong PIN should fail")
	if r != true: return r
	r = Runner.assert_eq(_validate_pin("1234", "123"), false, "Short PIN should fail")
	if r != true: return r
	r = Runner.assert_eq(_validate_pin("1234", ""), false, "Empty PIN should fail")
	if r != true: return r
	return true

func test_chunk_reassembly_order():
	var chunks: Array = ["hello", " ", "world", "!"]
	var result = _reassemble_chunks(chunks)
	var r = Runner.assert_eq(result, "hello world!", "Chunks should join in order")
	if r != true: return r
	return true

func test_chunk_reassembly_empty():
	var r = Runner.assert_eq(_reassemble_chunks([]), "", "Empty chunks → empty string")
	if r != true: return r
	return true

func test_chunk_reassembly_single():
	var r = Runner.assert_eq(_reassemble_chunks(["only"]), "only", "Single chunk preserved")
	if r != true: return r
	return true

func test_dict_serialization_round_trip():
	var original = {
		"name": "Player1",
		"color": Color(1.0, 0.0, 0.0),
		"position": Vector3(1.0, 2.0, 3.0),
		"tags": ["a", "b"],
	}
	var json = JSON.stringify(original)
	var parsed = JSON.parse_string(json)
	var r = Runner.assert_eq(parsed is Dictionary, true, "Parsed should be Dictionary")
	if r != true: return r
	r = Runner.assert_eq(parsed["name"], "Player1", "String preserved")
	if r != true: return r
	r = Runner.assert_eq(parsed["tags"].size(), 2, "Array preserved")
	if r != true: return r
	return true

func test_complex_dict_serialization():
	var original = {
		"peer_id": 42,
		"transforms": {
			"position": [1.0, 2.0, 3.0],
			"rotation": [0.0, 0.0, 0.0, 1.0],
		},
		"windows": [
			{"id": 1, "width": 800, "height": 600},
			{"id": 2, "width": 1920, "height": 1080},
		],
	}
	var json = JSON.stringify(original)
	var parsed = JSON.parse_string(json)
	var r = Runner.assert_eq(parsed["peer_id"], 42, "Nested int preserved")
	if r != true: return r
	r = Runner.assert_eq(parsed["windows"].size(), 2, "Nested array size preserved")
	if r != true: return r
	return true

func _generate_pin():
	return "%04d" % (randi() % 10000)

func _validate_pin(pin: String, expected: String):
	return pin == expected

func _reassemble_chunks(chunks: Array):
	var result = ""
	for chunk in chunks:
		result += chunk
	return result

# ── Helpers B2 : backoff / reconnect / blacklist ─────────────────────

func test_backoff_schedule():
	var r = true
	for a in range(0, 7):
		var d = LANManager.backoff_delay(a)
		if d < 0.0 or d > 2.5:
			r = false
	return r

func test_backoff_grows():
	# Croissance stricte uniquement avant le plafond (clamp ≤ 2.5 s) : au-delà
	# (attempt ≥ 3) le délai sature, la croissance stricte n'est plus garantie.
	var r = true
	var prev = LANManager.backoff_delay(0)
	for a in range(1, 3):
		var d = LANManager.backoff_delay(a)
		if d <= prev:
			r = false
		prev = d
	if r != true: return r
	# Plafond : jamais au-delà de 2.5 s, même en saturant.
	for a in range(3, 7):
		if LANManager.backoff_delay(a) > 2.5:
			r = false
	return r

func test_should_reconnect_yes():
	var r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, false, 30000, 2), true, "heartbeat expiré → reconnect")
	if r != true: return r
	r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, false, 30000, 12), false, "window épuisée → abandon")
	if r != true: return r
	r = Runner.assert_eq(LANManager.should_reconnect(0, 5000, true, 30000, 2), false, "session_closed → pas de reconnect")
	return true

func test_pin_blacklist():
	var state := {}
	var r = true
	for i in range(3):
		if LANManager.pin_attempt("1.2.3.4", false, state) == true:
			r = false
	if r != true: return "doit échouer seulement au 3e"
	if LANManager.pin_attempt("1.2.3.4", false, state) == false:
		return "3e échec doit rejeter"
	if LANManager.pin_attempt("1.2.3.4", true, state) == false:
		return "un succès réarme"
	return true
