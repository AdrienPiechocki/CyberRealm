# CyberRealm — GDScript Tests

Minimalist test framework for the CyberRealm project. No external dependencies — runs with Godot 4.7 headless.

## Running

```bash
cd Game/source
godot --headless --script tests/runner.gd
```

## Test Files

| File | Description |
|------|-------------|
| `test_lan_protocol.gd` | PIN generation, validation, chunk reassembly, Dictionary serialization |
| `test_capture_cache.gd` | Capture size rounding (64-byte alignment), image buffer sizing |
| `test_video_encode_decode.gd` | JPEG/PNG encode/decode round-trip, quality/size tradeoff |
| `test_audio_encode_decode.gd` | PCM buffer handling, sine wave generation, stereo interleave |

## Writing Tests

Create a new `test_*.gd` file extending `Node`. Each `test_*()` method must return:
- `true` for pass
- A `String` (error message) for fail

Use `Runner.assert_eq()`, `Runner.assert_true()`, `Runner.assert_approx()` for assertions.

```gdscript
extends Node

const Runner := preload("res://tests/test_runner.gd")

func test_example() -> void:
	var r := Runner.assert_eq(2 + 2, 4, "Basic math")
	if r != true: return r
	return true
```

## Exit Codes

- `0` — All tests passed
- `1` — One or more tests failed
