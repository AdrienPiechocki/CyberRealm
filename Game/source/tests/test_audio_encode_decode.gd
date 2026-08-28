extends Node
## Tests for audio PCM buffer handling and signal processing.

const Runner = preload("res://tests/runner.gd")

const SAMPLE_RATE = 48000
const CHANNELS = 2

func test_pcm_buffer_size():
	var samples = SAMPLE_RATE
	var buffer = PackedByteArray()
	buffer.resize(samples * CHANNELS * 2)
	var r = Runner.assert_eq(buffer.size(), samples * CHANNELS * 2,
		"1s stereo 16-bit buffer should be %d bytes" % (samples * CHANNELS * 2))
	if r != true: return r
	return true

func test_pcm_sample_write():
	var buffer = PackedByteArray()
	buffer.resize(4)
	var sample = 1000
	buffer[0] = sample & 0xFF
	buffer[1] = (sample >> 8) & 0xFF
	var readback = buffer[0] | (buffer[1] << 8)
	var r = Runner.assert_eq(readback, 1000, "Sample write/read round-trip")
	if r != true: return r
	return true

func test_sine_wave_generation():
	var freq = 440.0
	var duration_samples = 4800
	var pcm = _generate_sine(freq, duration_samples)
	var r = Runner.assert_eq(pcm.size(), duration_samples * CHANNELS,
		"Sine buffer size mismatch")
	if r != true: return r
	return true

func test_sine_wave_amplitude():
	var pcm = _generate_sine(440.0, 4800)
	var max_val = 0.0
	for i in pcm.size():
		max_val = maxf(max_val, absf(pcm[i]))
	var r = Runner.assert_true(max_val <= 1.0,
		"Sine amplitude should be ≤1.0, got %f" % max_val)
	if r != true: return r
	r = Runner.assert_true(max_val > 0.5,
		"Sine amplitude should be >0.5, got %f" % max_val)
	if r != true: return r
	return true

func test_sine_wave_frequency_content():
	var freq = 440.0
	var duration_samples = 48000
	var pcm = _generate_sine(freq, duration_samples)
	var crossings = 0
	for i in range(1, pcm.size()):
		if (pcm[i - 1] >= 0.0 and pcm[i] < 0.0) or (pcm[i - 1] < 0.0 and pcm[i] >= 0.0):
			crossings += 1
	var r = Runner.assert_true(crossings >= 800 and crossings <= 960,
		"Expected ~880 zero crossings, got %d" % crossings)
	if r != true: return r
	return true

func test_stereo_interleave():
	var left = PackedFloat32Array([1.0, 3.0, 5.0])
	var right = PackedFloat32Array([2.0, 4.0, 6.0])
	var interleaved = _interleave_stereo(left, right)
	var r = Runner.assert_eq(interleaved.size(), 6, "Interleaved size = 2 × num_samples")
	if r != true: return r
	r = Runner.assert_eq(interleaved[0], 1.0, "L0")
	if r != true: return r
	r = Runner.assert_eq(interleaved[1], 2.0, "R0")
	if r != true: return r
	r = Runner.assert_eq(interleaved[4], 5.0, "L2")
	if r != true: return r
	r = Runner.assert_eq(interleaved[5], 6.0, "R2")
	if r != true: return r
	return true

func test_stereo_deinterleave():
	var interleaved = PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
	var result = _deinterleave_stereo(interleaved)
	var left: PackedFloat32Array = result[0]
	var right: PackedFloat32Array = result[1]
	var r = Runner.assert_eq(left.size(), 3, "Left channel size")
	if r != true: return r
	r = Runner.assert_eq(left[0], 1.0, "L0")
	if r != true: return r
	r = Runner.assert_eq(right[0], 2.0, "R0")
	if r != true: return r
	r = Runner.assert_eq(left[2], 5.0, "L2")
	if r != true: return r
	r = Runner.assert_eq(right[2], 6.0, "R2")
	if r != true: return r
	return true

func test_audio_buffer_merge():
	var buf1 = PackedByteArray([1, 2, 3])
	var buf2 = PackedByteArray([4, 5, 6])
	var merged = buf1
	merged.append_array(buf2)
	var r = Runner.assert_eq(merged.size(), 6, "Merged size")
	if r != true: return r
	r = Runner.assert_eq(merged[3], 4, "First byte of buf2")
	if r != true: return r
	return true

func _generate_sine(freq: float, num_samples: int):
	var pcm = PackedFloat32Array()
	pcm.resize(num_samples * CHANNELS)
	for i in num_samples:
		var t = float(i) / float(SAMPLE_RATE)
		var sample = sin(2.0 * PI * freq * t)
		pcm[i * CHANNELS] = sample
		pcm[i * CHANNELS + 1] = sample
	return pcm

func _interleave_stereo(left: PackedFloat32Array, right: PackedFloat32Array):
	var result = PackedFloat32Array()
	result.resize(left.size() * 2)
	for i in left.size():
		result[i * 2] = left[i]
		result[i * 2 + 1] = right[i]
	return result

func _deinterleave_stereo(interleaved: PackedFloat32Array):
	var left = PackedFloat32Array()
	var right = PackedFloat32Array()
	var num_samples = interleaved.size() / 2
	left.resize(num_samples)
	right.resize(num_samples)
	for i in num_samples:
		left[i] = interleaved[i * 2]
		right[i] = interleaved[i * 2 + 1]
	return [left, right]
