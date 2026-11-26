#include "voice_chat.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <opus/opus.h>

#include <cmath>
#include <cstdlib>
#include <cstring>

using namespace godot;

static constexpr size_t RING_CAPACITY = VoiceChat::RATE; // 1 s de marge

static const struct pw_stream_events g_voice_events = {
	.version = PW_VERSION_STREAM_EVENTS,
	.destroy = nullptr,
	.state_changed = nullptr,
	.control_info = nullptr,
	.io_changed = nullptr,
	.param_changed = nullptr,
	.process = VoiceChat::process_cb,
	.drained = nullptr,
};

VoiceChat::VoiceChat() {}

VoiceChat::~VoiceChat() {
	stop();
	for (auto &kv : decoders) {
		if (kv.second.decoder) {
			opus_decoder_destroy(static_cast<OpusDecoder *>(kv.second.decoder));
		}
	}
	decoders.clear();
}

bool VoiceChat::is_active() const {
	return thread_loop != nullptr;
}

bool VoiceChat::ensure_encoder() {
	if (encoder) {
		return true;
	}
	int err = 0;
	OpusEncoder *enc = opus_encoder_create(RATE, 1, OPUS_APPLICATION_VOIP, &err);
	if (!enc || err != OPUS_OK) {
		UtilityFunctions::printerr("waylandgodot: voice: opus_encoder_create failed (", err, ")");
		return false;
	}
	opus_encoder_ctl(enc, OPUS_SET_BITRATE(BITRATE));
	opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
	opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(10));
	opus_encoder_ctl(enc, OPUS_SET_DTX(1));
	opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
	encoder = enc;
	std::lock_guard<std::mutex> lk(ring_mutex);
	ring.assign(RING_CAPACITY, 0.0f);
	ring_head = 0;
	ring_count = 0;
	return true;
}

void VoiceChat::feed(const float *samples, int n) {
	if (n > 0 && ensure_encoder()) {
		push_samples(samples, (uint32_t)n, 1);
	}
}

bool VoiceChat::start(const String &target) {
	if (thread_loop) {
		return true;
	}
	pw_init(nullptr, nullptr);
	if (!ensure_encoder()) {
		return false;
	}

	pw_thread_loop *loop = pw_thread_loop_new("cyberrealm-voice", nullptr);
	if (!loop) {
		stop();
		return false;
	}
	thread_loop = loop;

	pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_ROLE, "Communication",
		PW_KEY_APP_NAME, "CyberRealm",
		PW_KEY_NODE_NAME, "cyberrealm-voice",
		PW_KEY_NODE_DESCRIPTION, "CyberRealm voice chat",
		nullptr);
	CharString tgt = target.utf8();
	if (tgt.length() > 0) {
		pw_properties_set(props, PW_KEY_TARGET_OBJECT, tgt.get_data());
	}
	pw_stream *s = pw_stream_new_simple(pw_thread_loop_get_loop(loop), "cyberrealm-voice", props,
		&g_voice_events, this);
	if (!s) {
		UtilityFunctions::printerr("waylandgodot: voice: pw_stream_new_simple failed");
		stop();
		return false;
	}
	stream = s;

	uint8_t buf[1024];
	spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
	spa_audio_info_raw info = {};
	info.format = SPA_AUDIO_FORMAT_F32;
	info.rate = RATE;
	info.channels = 1;
	info.position[0] = SPA_AUDIO_CHANNEL_MONO;
	const spa_pod *params[1];
	params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);
	if (pw_stream_connect(s, PW_DIRECTION_INPUT, PW_ID_ANY,
			(pw_stream_flags)(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS),
			params, 1) < 0) {
		UtilityFunctions::printerr("waylandgodot: voice: pw_stream_connect failed");
		stop();
		return false;
	}
	if (pw_thread_loop_start(loop) < 0) {
		UtilityFunctions::printerr("waylandgodot: voice: pw_thread_loop_start failed");
		stop();
		return false;
	}
	UtilityFunctions::print("waylandgodot: voice: microphone opened",
		tgt.length() > 0 ? String(" (target ") + target + ")" : String(""));
	return true;
}

void VoiceChat::stop() {
	if (thread_loop) {
		pw_thread_loop_stop(static_cast<pw_thread_loop *>(thread_loop));
	}
	if (stream) {
		pw_stream_destroy(static_cast<pw_stream *>(stream));
		stream = nullptr;
	}
	if (thread_loop) {
		pw_thread_loop_destroy(static_cast<pw_thread_loop *>(thread_loop));
		thread_loop = nullptr;
	}
	if (encoder) {
		opus_encoder_destroy(static_cast<OpusEncoder *>(encoder));
		encoder = nullptr;
	}
	std::lock_guard<std::mutex> lk(ring_mutex);
	ring_count = 0;
}

void VoiceChat::process_cb(void *user_data) {
	auto *self = static_cast<VoiceChat *>(user_data);
	pw_stream *s = static_cast<pw_stream *>(self->stream);
	if (!s) {
		return;
	}
	pw_buffer *b = pw_stream_dequeue_buffer(s);
	if (!b || !b->buffer) {
		return;
	}
	spa_data *d = &b->buffer->datas[0];
	if (d && d->chunk && d->data && d->chunk->size > 0) {
		uint32_t stride = d->chunk->stride > 0 ? (uint32_t)d->chunk->stride : sizeof(float);
		uint32_t n = d->chunk->size / stride;
		const float *samples = reinterpret_cast<const float *>(
			static_cast<uint8_t *>(d->data) + d->chunk->offset);
		self->push_samples(samples, n, stride / sizeof(float));
	}
	pw_stream_queue_buffer(s, b);
}

void VoiceChat::push_samples(const float *samples, uint32_t n, uint32_t stride_floats) {
	std::lock_guard<std::mutex> lk(ring_mutex);
	if (ring.empty()) {
		return;
	}
	for (uint32_t i = 0; i < n; i++) {
		float v = samples[(size_t)i * stride_floats];
		size_t tail = (ring_head + ring_count) % RING_CAPACITY;
		ring[tail] = v;
		if (ring_count < RING_CAPACITY) {
			ring_count++;
		} else {
			ring_head = (ring_head + 1) % RING_CAPACITY; // plein : on garde le plus récent
		}
	}
}

// Écrêtage doux : linéaire jusqu'à ±0,8, puis courbe tanh vers ±1 (un gain fort sur un éclat de voix ne sature pas
// brutalement le signal envoyé).
static inline float soft_clip(float x) {
	const float knee = 0.8f;
	float a = std::fabs(x);
	if (a <= knee) {
		return x;
	}
	float y = knee + (1.0f - knee) * std::tanh((a - knee) / (1.0f - knee));
	return x < 0.0f ? -y : y;
}

void VoiceChat::set_gain_db(float db) {
	gain_db = std::fmin(std::fmax(db, 0.0f), MAX_GAIN_DB);
	gain = std::pow(10.0f, gain_db / 20.0f);
}

bool VoiceChat::take_frame(float *frame, double &rms) {
	{
		std::lock_guard<std::mutex> lk(ring_mutex);
		if (ring_count < (size_t)FRAME) {
			return false;
		}
		for (int i = 0; i < FRAME; i++) {
			frame[i] = ring[(ring_head + i) % RING_CAPACITY];
		}
		ring_head = (ring_head + FRAME) % RING_CAPACITY;
		ring_count -= FRAME;
	}
	double sum = 0.0;
	for (int i = 0; i < FRAME; i++) {
		if (gain != 1.0f) {
			frame[i] = soft_clip(frame[i] * gain);
		}
		sum += (double)frame[i] * frame[i];
	}
	rms = std::sqrt(sum / FRAME);
	return true;
}

Array VoiceChat::poll() {
	Array out;
	if (!encoder) {
		return out;
	}
	float frame[FRAME];
	unsigned char packet[MAX_PACKET];
	double rms = 0.0;
	while (take_frame(frame, rms)) {
		int len = opus_encode_float(static_cast<OpusEncoder *>(encoder), frame, FRAME, packet, MAX_PACKET);
		if (len <= 0) {
			continue;
		}
		PackedByteArray data;
		data.resize(len);
		memcpy(data.ptrw(), packet, len);
		Dictionary e;
		e["data"] = data;
		e["rms"] = rms;
		out.push_back(e);
	}
	return out;
}

Array VoiceChat::poll_raw() {
	Array out;
	if (!encoder) {
		return out;
	}
	float frame[FRAME];
	double rms = 0.0;
	while (take_frame(frame, rms)) {
		PackedFloat32Array pcm;
		pcm.resize(FRAME);
		memcpy(pcm.ptrw(), frame, sizeof(frame));
		Dictionary e;
		e["pcm"] = pcm;
		e["rms"] = rms;
		out.push_back(e);
	}
	return out;
}

PackedByteArray VoiceChat::encode(const PackedFloat32Array &pcm) {
	PackedByteArray data;
	if (pcm.size() != FRAME || !ensure_encoder()) {
		return data;
	}
	unsigned char packet[MAX_PACKET];
	int len = opus_encode_float(static_cast<OpusEncoder *>(encoder), pcm.ptr(), FRAME, packet, MAX_PACKET);
	if (len > 0) {
		data.resize(len);
		memcpy(data.ptrw(), packet, len);
	}
	return data;
}

PackedVector2Array VoiceChat::decode(int peer, int seq, const PackedByteArray &data) {
	PackedVector2Array out;
	if (data.is_empty() || data.size() > MAX_PACKET) {
		return out;
	}
	PeerDecoder &pd = decoders[peer];
	if (!pd.decoder) {
		int err = 0;
		pd.decoder = opus_decoder_create(RATE, 1, &err);
		if (!pd.decoder || err != OPUS_OK) {
			pd.decoder = nullptr;
			return out;
		}
	}
	OpusDecoder *dec = static_cast<OpusDecoder *>(pd.decoder);
	float pcm[FRAME * 6];
	std::vector<float> all;
	if (pd.last_seq >= 0) {
		int gap = seq - pd.last_seq - 1;
		if (gap < 0 && gap > -1000) {
			return out; // trame en retard (réordonnancement) : ignorée
		}
		if (gap >= 1 && gap <= MAX_PLC_FRAMES) {
			// Trames perdues : la dernière est reconstruite depuis la FEC de celle-ci,
			// les précédentes par dissimulation.
			for (int i = 0; i < gap - 1; i++) {
				int n = opus_decode_float(dec, nullptr, 0, pcm, FRAME, 0);
				if (n > 0) all.insert(all.end(), pcm, pcm + n);
			}
			int n = opus_decode_float(dec, data.ptr(), data.size(), pcm, FRAME, 1);
			if (n > 0) all.insert(all.end(), pcm, pcm + n);
		}
	}
	pd.last_seq = seq;
	int n = opus_decode_float(dec, data.ptr(), data.size(), pcm, FRAME * 6, 0);
	if (n <= 0) {
		return out;
	}
	all.insert(all.end(), pcm, pcm + n);
	out.resize((int64_t)all.size());
	Vector2 *w = out.ptrw();
	for (size_t i = 0; i < all.size(); i++) {
		w[i] = Vector2(all[i], all[i]);
	}
	return out;
}

void VoiceChat::forget(int peer) {
	auto it = decoders.find(peer);
	if (it == decoders.end()) {
		return;
	}
	if (it->second.decoder) {
		opus_decoder_destroy(static_cast<OpusDecoder *>(it->second.decoder));
	}
	decoders.erase(it);
}
