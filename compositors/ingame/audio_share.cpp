#include "audio_share.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/type.h>
#include <opus/opus.h>

#include <cstdlib>
#include <cstring>

namespace godot {

// Durées / formats
static constexpr uint32_t AUDIO_RATE = 48000;
static constexpr uint32_t AUDIO_CHANNELS = 2;
static constexpr int OPUS_FRAME_SIZE = 960; // 20 ms à 48 kHz
static constexpr size_t RING_CAPACITY_FRAMES = AUDIO_RATE; // 1 s de buffer

static const struct pw_registry_events g_registry_events = {
	.version = PW_VERSION_REGISTRY_EVENTS,
	.global = AudioShare::registry_global_cb,
	.global_remove = nullptr,
};

static const struct pw_metadata_events g_metadata_events = {
	.version = PW_VERSION_METADATA_EVENTS,
	.property = AudioShare::metadata_property_cb,
};

static const struct pw_stream_events g_stream_events = {
	.version = PW_VERSION_STREAM_EVENTS,
	.destroy = nullptr,
	.state_changed = nullptr,
	.control_info = nullptr,
	.io_changed = nullptr,
	.param_changed = nullptr,
	.process = AudioShare::stream_process_cb,
	.drained = nullptr,
};

AudioShare::AudioShare() {
	ring.resize(RING_CAPACITY_FRAMES * AUDIO_CHANNELS);
}

AudioShare::~AudioShare() {
	stop();
	if (opus_encoder) {
		opus_encoder_destroy(static_cast<OpusEncoder *>(opus_encoder));
	}
	if (opus_decoder) {
		opus_decoder_destroy(static_cast<OpusDecoder *>(opus_decoder));
	}
}

bool AudioShare::is_active() const {
	return thread_loop != nullptr;
}

bool AudioShare::start() {
	if (thread_loop) {
		return true; // déjà actif
	}
	pw_init(nullptr, nullptr);

	thread_loop = pw_thread_loop_new("cyberrealm-audio-share", nullptr);
	if (!thread_loop) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_thread_loop_new a échoué");
		return false;
	}
	context = pw_context_new(pw_thread_loop_get_loop((pw_thread_loop *)thread_loop), nullptr, 0);
	if (!context) {
		pw_thread_loop_destroy((pw_thread_loop *)thread_loop);
		thread_loop = nullptr;
		return false;
	}
	core = pw_context_connect((pw_context *)context, nullptr, 0);
	if (!core) {
		pw_context_destroy((pw_context *)context);
		context = nullptr;
		pw_thread_loop_destroy((pw_thread_loop *)thread_loop);
		thread_loop = nullptr;
		UtilityFunctions::printerr("waylandgodot: audio: pw_context_connect a échoué "
			"(pas de session PipeWire ?)");
		return false;
	}

	// Énumère les globals : on cherche le node dont le nom correspond au sink
	// par défaut (résolu via la metadata "default.audio.sink").
	registry = pw_core_get_registry((pw_core *)core, PW_VERSION_REGISTRY, 0);
	registry_hook = malloc(sizeof(struct spa_hook));
	pw_registry_add_listener((pw_registry *)registry,
			(struct spa_hook *)registry_hook, &g_registry_events, this);

	if (pw_thread_loop_start((pw_thread_loop *)thread_loop) < 0) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_thread_loop_start a échoué");
		stop();
		return false;
	}
	UtilityFunctions::print("waylandgodot: audio: capture PipeWire démarrée (monitor du sink par défaut)");
	return true;
}

void AudioShare::stop() {
	if (thread_loop) {
		pw_thread_loop_stop((pw_thread_loop *)thread_loop);
	}
	if (stream) {
		pw_stream_destroy((pw_stream *)stream);
		stream = nullptr;
	}
	if (metadata) {
		pw_proxy_destroy((pw_proxy *)metadata);
		metadata = nullptr;
	}
	if (registry) {
		pw_proxy_destroy((pw_proxy *)registry);
		registry = nullptr;
	}
	free(registry_hook);
	registry_hook = nullptr;
	free(metadata_hook);
	metadata_hook = nullptr;
	free(stream_hook);
	stream_hook = nullptr;
	if (core) {
		pw_core_disconnect((pw_core *)core);
		core = nullptr;
	}
	if (context) {
		pw_context_destroy((pw_context *)context);
		context = nullptr;
	}
	if (thread_loop) {
		pw_thread_loop_destroy((pw_thread_loop *)thread_loop);
		thread_loop = nullptr;
	}
	stream_connected = false;
	target_node_name.clear();
	node_name_seen = false;
	rescan_done = false;
	{
		std::lock_guard<std::mutex> lk(ring_mutex);
		ring_head = 0;
		ring_count = 0;
	}
	pw_deinit();
}

// ---------------------------------------------------------------------
// PipeWire callbacks
// ---------------------------------------------------------------------

void AudioShare::registry_global_cb(void *user_data, uint32_t id, uint32_t permissions,
		const char *type, uint32_t version, const struct ::spa_dict *props) {
	AudioShare *self = static_cast<AudioShare *>(user_data);
	self->on_registry_global(id, type, props);
	(void)permissions;
	(void)version;
}

void AudioShare::on_registry_global(uint32_t id, const char *type, const struct ::spa_dict *props) {
	if (type == nullptr) {
		return;
	}
	// Bind la metadata "default" pour connaître le sink audio par défaut.
		if (metadata == nullptr && strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
		const char *name = props ? spa_dict_lookup(props, "metadata.name") : nullptr;
		if (name && strcmp(name, "default") == 0) {
			metadata = static_cast<pw_metadata *>(pw_registry_bind((pw_registry *)registry,
					id, type, PW_VERSION_METADATA, sizeof(void *)));
			metadata_hook = malloc(sizeof(struct spa_hook));
			pw_metadata_add_listener((pw_metadata *)metadata,
					(struct spa_hook *)metadata_hook, &g_metadata_events, this);
			return;
		}
	}
	// Mémorise l'id du node qui correspond au sink par défaut (nom résolu).
	if (!target_node_name.empty() && !stream_connected &&
			strcmp(type, PW_TYPE_INTERFACE_Node) == 0 && props) {
		const char *node_name = spa_dict_lookup(props, "node.name");
		if (node_name && target_node_name == node_name) {
			node_name_seen = true;
			connect_stream(id);
		}
	}
}

int AudioShare::metadata_property_cb(void *user_data, uint32_t subject, const char *key,
		const char *type, const char *value) {
	AudioShare *self = static_cast<AudioShare *>(user_data);
	self->on_metadata_property(subject, key, value);
	(void)type;
	return 0;
}

void AudioShare::on_metadata_property(uint32_t subject, const char *key, const char *value) {
	(void)subject;
	if (key == nullptr || value == nullptr) {
		return;
	}
	if (stream_connected || strcmp(key, "default.audio.sink") != 0) {
		return;
	}
	// Valeur ":<id>" → id de node direct ; sinon un nom de node à résoudre via
	// le registry.
	if (value[0] == ':' && value[1] != '\0') {
		uint32_t id = (uint32_t)strtoul(value + 1, nullptr, 10);
		connect_stream(id);
		return;
	}
	target_node_name = value;
	if (node_name_seen) {
		return; // le node a déjà été trouvé et le stream connecté
	}
	if (rescan_done) {
		return; // ré-énumération déjà lancée (le node arrivera dessus)
	}
	// RACE (la cause classique du « pas d'audio partagé ») : la metadata
	// "default.audio.sink" peut arriver APRÈS l'énumération du registry. Le
	// node correspondant est alors déjà passé et ne sera plus jamais revu
	// sur cette instance de registry → le stream ne se connecte jamais.
	// Correction : on ré-énumère le registry une fois (nouveau proxy → tous
	// les globals sont re-émis, y compris le node du sink) ; le callback
	// global matchera alors target_node_name et connectera le stream.
	rescan_done = true;
	if (registry) {
		pw_proxy_destroy((pw_proxy *)registry);
		registry = nullptr;
	}
	free(registry_hook);
	registry_hook = nullptr;
	registry = pw_core_get_registry((pw_core *)core, PW_VERSION_REGISTRY, 0);
	registry_hook = malloc(sizeof(struct spa_hook));
	pw_registry_add_listener((pw_registry *)registry,
			(struct spa_hook *)registry_hook, &g_registry_events, this);
	UtilityFunctions::print("waylandgodot: audio: sink par défaut = ", value,
		" — node non encore vu, ré-énumération du registry");
}

void AudioShare::connect_stream(uint32_t target_node_id) {
	if (stream_connected || !core) {
		return;
	}
	stream = pw_stream_new((pw_core *)core, "cyberrealm-audio-share", nullptr);
	if (!stream) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_stream_new a échoué");
		return;
	}
	stream_hook = malloc(sizeof(struct spa_hook));
	pw_stream_add_listener((pw_stream *)stream, (struct spa_hook *)stream_hook,
			&g_stream_events, this);

	uint8_t data[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(data, sizeof(data));
	struct spa_pod_frame f;
	spa_pod_builder_push_object(&b, &f, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
	spa_pod_builder_add(&b,
		SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_audio),
		SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
		SPA_FORMAT_AUDIO_format, SPA_POD_Id(SPA_AUDIO_FORMAT_F32),
		SPA_FORMAT_AUDIO_rate, SPA_POD_Int((int)AUDIO_RATE),
		SPA_FORMAT_AUDIO_channels, SPA_POD_Int((int)AUDIO_CHANNELS),
		0);
	const struct spa_pod *params[1];
	params[0] = static_cast<const struct spa_pod *>(spa_pod_builder_pop(&b, &f));

	// Direction INPUT branchée sur le sink par défaut → capture son monitor
	// (l'audio qui y est joué). AUTOCONNECT laisse WirePlumber gérer le link.
	if (pw_stream_connect((pw_stream *)stream, PW_DIRECTION_INPUT, target_node_id,
			PW_STREAM_FLAG_AUTOCONNECT, params, 1) < 0) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_stream_connect a échoué");
		return;
	}
	stream_connected = true;
	UtilityFunctions::print("waylandgodot: audio: stream connecté au node ", target_node_id);
}

void AudioShare::stream_process_cb(void *user_data) {
	AudioShare *self = static_cast<AudioShare *>(user_data);
	if (!self->stream) {
		return;
	}
	struct pw_buffer *b = pw_stream_dequeue_buffer((pw_stream *)self->stream);
	if (!b) {
		return;
	}
	struct spa_data *d = &b->buffer->datas[0];
	uint8_t *data = static_cast<uint8_t *>(d->data);
	if (data == nullptr || d->chunk->size == 0) {
		pw_stream_queue_buffer((pw_stream *)self->stream, b);
		return;
	}
	uint32_t stride = d->chunk->stride > 0
		? (uint32_t)d->chunk->stride
		: AUDIO_CHANNELS * sizeof(float);
	uint32_t bytes = d->chunk->size;
	if (stride == 0) {
		pw_stream_queue_buffer((pw_stream *)self->stream, b);
		return;
	}
	uint32_t n_frames = bytes / stride;

	std::lock_guard<std::mutex> lk(self->ring_mutex);
	for (uint32_t i = 0; i < n_frames; i++) {
		float *frame = reinterpret_cast<float *>(data + (size_t)i * stride);
		if (self->ring_count < RING_CAPACITY_FRAMES) {
			size_t tail = (self->ring_head + self->ring_count) % RING_CAPACITY_FRAMES;
			self->ring[tail * AUDIO_CHANNELS + 0] = frame[0];
			self->ring[tail * AUDIO_CHANNELS + 1] = frame[1];
			self->ring_count++;
		} else {
			// Buffer plein : on écrase la plus ancienne (live, la fraîcheur prime).
			size_t tail = (self->ring_head + self->ring_count) % RING_CAPACITY_FRAMES;
			self->ring[tail * AUDIO_CHANNELS + 0] = frame[0];
			self->ring[tail * AUDIO_CHANNELS + 1] = frame[1];
			self->ring_head = (self->ring_head + 1) % RING_CAPACITY_FRAMES;
		}
	}
	pw_stream_queue_buffer((pw_stream *)self->stream, b);
}

// ---------------------------------------------------------------------
// OPUS encode / decode
// ---------------------------------------------------------------------

bool AudioShare::poll_opus_packet(PackedByteArray &r_out) {
	if (!thread_loop || !stream_connected) {
		return false;
	}
	if (!opus_encoder) {
		int error = 0;
		opus_encoder = opus_encoder_create(AUDIO_RATE, AUDIO_CHANNELS,
				OPUS_APPLICATION_AUDIO, &error);
		if (error != OPUS_OK || !opus_encoder) {
			opus_encoder = nullptr;
			return false;
		}
		opus_encoder_ctl(static_cast<OpusEncoder *>(opus_encoder),
				OPUS_SET_BITRATE(96000));
	}
	std::vector<float> frames(OPUS_FRAME_SIZE * AUDIO_CHANNELS);
	{
		std::lock_guard<std::mutex> lk(ring_mutex);
		if (ring_count < OPUS_FRAME_SIZE) {
			return false;
		}
		for (int i = 0; i < OPUS_FRAME_SIZE; i++) {
			size_t src = (ring_head + (size_t)i) % RING_CAPACITY_FRAMES;
			frames[i * AUDIO_CHANNELS + 0] = ring[src * AUDIO_CHANNELS + 0];
			frames[i * AUDIO_CHANNELS + 1] = ring[src * AUDIO_CHANNELS + 1];
		}
		ring_head = (ring_head + OPUS_FRAME_SIZE) % RING_CAPACITY_FRAMES;
		ring_count -= OPUS_FRAME_SIZE;
	}

	uint8_t packet[1500];
	int written = opus_encode_float(static_cast<OpusEncoder *>(opus_encoder),
			frames.data(), OPUS_FRAME_SIZE, packet, (opus_int32)sizeof(packet));
	if (written < 0) {
		return false;
	}
	r_out.resize(written);
	memcpy(r_out.ptrw(), packet, (size_t)written);
	return true;
}

PackedByteArray AudioShare::decode_opus_packet(const PackedByteArray &p_in) {
	PackedByteArray out;
	if (p_in.is_empty()) {
		return out;
	}
	if (!opus_decoder) {
		int error = 0;
		opus_decoder = opus_decoder_create(AUDIO_RATE, AUDIO_CHANNELS, &error);
		if (error != OPUS_OK || !opus_decoder) {
			opus_decoder = nullptr;
			return out;
		}
	}
	const int samples = OPUS_FRAME_SIZE * AUDIO_CHANNELS;
	out.resize(samples * (int)sizeof(int16_t));
	opus_int16 *pcm = reinterpret_cast<opus_int16 *>(out.ptrw());
	int decoded = opus_decode(static_cast<OpusDecoder *>(opus_decoder),
			reinterpret_cast<const unsigned char *>(p_in.ptr()), (opus_int32)p_in.size(),
			pcm, OPUS_FRAME_SIZE, 0);
	if (decoded < 0) {
		out.resize(0);
		return out;
	}
	// decoded = nombre de frames décodées (<= OPUS_FRAME_SIZE).
	out.resize(decoded * AUDIO_CHANNELS * (int)sizeof(int16_t));
	return out;
}

} // namespace godot
