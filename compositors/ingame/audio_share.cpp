#include "audio_share.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/type.h>
#include <opus/opus.h>

#include <cctype>
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
	.global_remove = AudioShare::registry_global_remove_cb,
};

// Un bind node en attente d'event info (pour lire application.process.id).
struct AudioShare::NodeBind {
	AudioShare *self;
	uint32_t id;
	struct spa_hook hook;
	struct pw_proxy *proxy;
};

static const struct pw_node_events g_node_events = {
	.version = PW_VERSION_NODE_EVENTS,
	.info = AudioShare::node_info_cb,
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

AudioShare::AudioShare() {}

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

	// Énumère les globals : on collecte tous les nodes audio avec leur PID
	// (application.process.id). Les streams de capture seront connectés aux
	// nodes des apps partagées (set_target_pids), pas au sink par défaut.
	registry = pw_core_get_registry((pw_core *)core, PW_VERSION_REGISTRY, 0);
	registry_hook = malloc(sizeof(struct spa_hook));
	pw_registry_add_listener((pw_registry *)registry,
			(struct spa_hook *)registry_hook, &g_registry_events, this);

	if (pw_thread_loop_start((pw_thread_loop *)thread_loop) < 0) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_thread_loop_start a échoué");
		stop();
		return false;
	}
	UtilityFunctions::print("waylandgodot: audio: capture PipeWire démarrée "
		"(audio des fenêtres partagées, par PID)");
	return true;
}

void AudioShare::stop() {
	if (thread_loop) {
		pw_thread_loop_stop((pw_thread_loop *)thread_loop);
	}
	{
		std::lock_guard<std::mutex> lk(streams_mutex);
		for (AudioCaptureStream *s : streams) {
			if (s->stream) {
				pw_stream_destroy((pw_stream *)s->stream);
			}
			free(s->hook);
			delete s;
		}
		streams.clear();
	}
	if (registry) {
		pw_proxy_destroy((pw_proxy *)registry);
		registry = nullptr;
	}
	free(registry_hook);
	registry_hook = nullptr;
	for (auto &kv : pending_node_binds) {
		NodeBind *nb = kv.second;
		pw_proxy_destroy(nb->proxy);
		free(nb);
	}
	pending_node_binds.clear();
	node_pids.clear();
	target_pids.clear();
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
	// Diagnostique (temporaire) : confirme que les globals arrivent bien, et
	// ce qu'ils portent. À retirer une fois le matching fenêtre→node validé.
	const char *dbg_name = props ? spa_dict_lookup(props, "node.name") : nullptr;
	if (dbg_name == nullptr) {
		dbg_name = props ? spa_dict_lookup(props, "metadata.name") : nullptr;
	}
	if (dbg_name == nullptr) {
		dbg_name = props ? spa_dict_lookup(props, "object.name") : nullptr;
	}
	const char *dbg_media = props ? spa_dict_lookup(props, "media.class") : nullptr;
	const char *dbg_pid = props ? spa_dict_lookup(props, "application.process.id") : nullptr;
	UtilityFunctions::print("waylandgodot: audio: [reg] ", id, " type=",
		type ? type : "?", " name=", dbg_name ? dbg_name : "?",
		" media=", dbg_media ? dbg_media : "?", " pid=", dbg_pid ? dbg_pid : "?");
	if (type == nullptr) {
		return;
	}
	// Un node audio = une application en sortie (ou un sink/mic). Les props
	// GLOBALES du registry sont minimales (parfois sans media.class ni
	// application.process.id) : on bind systématiquement le node pour lire ses
	// props complètes via l'event info (asynchrone → on_node_info).
	if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
		node_pids[id] = -1;
		bind_node_for_info(id);
	}
}

void AudioShare::registry_global_remove_cb(void *user_data, uint32_t id) {
	AudioShare *self = static_cast<AudioShare *>(user_data);
	self->on_registry_global_remove(id);
}

void AudioShare::node_info_cb(void *user_data, const struct pw_node_info *info) {
	auto *nb = static_cast<NodeBind *>(user_data);
	if (nb) {
		nb->self->on_node_info(nb->id, info);
	}
}

void AudioShare::on_node_info(uint32_t id, const struct pw_node_info *info) {
	// L'event info initial peut arriver SANS props (délivrance incrémentale) :
	// on garde le bind vivant tant que les props complètes ne sont pas là.
	if (info != nullptr && info->props != nullptr) {
		const char *proc_id = spa_dict_lookup(info->props, "application.process.id");
		int pid = (proc_id && *proc_id) ? (int)strtol(proc_id, nullptr, 10) : -1;
		node_pids[id] = pid;
		if (pid > 0) {
			const char *node_name = spa_dict_lookup(info->props, "node.name");
			UtilityFunctions::print("waylandgodot: audio: node ", id, " (",
				node_name ? node_name : "?", ") → pid ", pid);
			apply_targets();
		} else {
			const char *node_name = spa_dict_lookup(info->props, "node.name");
			UtilityFunctions::print("waylandgodot: audio: node ", id, " (",
				node_name ? node_name : "?", ") props reçues sans application.process.id");
		}
		auto it = pending_node_binds.find(id);
		if (it != pending_node_binds.end()) {
			NodeBind *nb = it->second;
			pending_node_binds.erase(it);
			pw_proxy_destroy(nb->proxy);
			free(nb);
		}
	}
}

void AudioShare::bind_node_for_info(uint32_t id) {
	if (pending_node_binds.find(id) != pending_node_binds.end()) {
		return; // déjà en cours
	}
	struct pw_proxy *proxy = static_cast<struct pw_proxy *>(pw_registry_bind(
			(pw_registry *)registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE,
			sizeof(void *)));
	if (!proxy) {
		return;
	}
	auto *nb = new NodeBind();
	nb->self = this;
	nb->id = id;
	nb->proxy = proxy;
	pw_proxy_add_object_listener(proxy, &nb->hook, &g_node_events, nb);
	pending_node_binds[id] = nb;
}

void AudioShare::on_registry_global_remove(uint32_t id) {
	node_pids.erase(id);
	auto it = pending_node_binds.find(id);
	if (it != pending_node_binds.end()) {
		NodeBind *nb = it->second;
		pending_node_binds.erase(it);
		pw_proxy_destroy(nb->proxy);
		free(nb);
	}
	// Si on capturait ce node (app fermée), on détruit son stream.
	std::lock_guard<std::mutex> lk(streams_mutex);
	AudioCaptureStream *s = find_stream_for_node(id);
	if (s) {
		for (auto it2 = streams.begin(); it2 != streams.end(); ++it2) {
			if (*it2 == s) {
				streams.erase(it2);
				break;
			}
		}
		pw_stream_destroy((pw_stream *)s->stream);
		free(s->hook);
		delete s;
	}
}

// ---------------------------------------------------------------------
// Ciblage par PID des fenêtres partagées
// ---------------------------------------------------------------------

void AudioShare::set_target_pids(const std::vector<int> &pids) {
	if (!thread_loop) {
		return;
	}
	// Sous pw_thread_loop_lock, les callbacks PW (registry, process) sont
	// suspendus : la réconciliation est atomique et ne court contre rien.
	pw_thread_loop_lock((pw_thread_loop *)thread_loop);
	target_pids = pids;
	apply_targets();
	pw_thread_loop_unlock((pw_thread_loop *)thread_loop);
}

AudioCaptureStream *AudioShare::find_stream_for_pid(int pid) const {
	for (AudioCaptureStream *s : streams) {
		if (s->pid == pid) {
			return s;
		}
	}
	return nullptr;
}

AudioCaptureStream *AudioShare::find_stream_for_node(uint32_t node_id) const {
	for (AudioCaptureStream *s : streams) {
		if (s->node_id == node_id) {
			return s;
		}
	}
	return nullptr;
}

void AudioShare::apply_targets() {
	// streams_mutex est détenu tout du long : find_stream_for_* /
	// create_stream_for / les frees supposent le verrou pris (poll_opus_packet
	// du thread du jeu itère le même vecteur sous ce mutex).
	std::lock_guard<std::mutex> lk(streams_mutex);
	// 1. On détruit les streams dont le PID n'est plus ciblé.
	for (auto it = streams.begin(); it != streams.end();) {
		AudioCaptureStream *s = *it;
		bool wanted = false;
		for (int pid : target_pids) {
			if (pid == s->pid) {
				wanted = true;
				break;
			}
		}
		if (wanted) {
			++it;
			continue;
		}
		it = streams.erase(it);
		pw_stream_destroy((pw_stream *)s->stream);
		free(s->hook);
		delete s;
	}
	// 2. On connecte un stream pour chaque PID ciblé dont un node est connu.
	for (int pid : target_pids) {
		if (find_stream_for_pid(pid) != nullptr) {
			continue; // déjà capturé
		}
		for (const auto &kv : node_pids) {
			if (kv.second == pid) {
				create_stream_for(kv.first, pid);
				break;
			}
		}
	}
}

void AudioShare::create_stream_for(uint32_t node_id, int pid) {
	auto *s = new AudioCaptureStream();
	s->pid = pid;
	s->node_id = node_id;
	s->ring.resize(RING_CAPACITY_FRAMES * AUDIO_CHANNELS);

	s->stream = pw_stream_new((pw_core *)core, "cyberrealm-audio-share", nullptr);
	if (!s->stream) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_stream_new a échoué (pid ", pid, ")");
		delete s;
		return;
	}
	s->hook = malloc(sizeof(struct spa_hook));
	pw_stream_add_listener((pw_stream *)s->stream, (struct spa_hook *)s->hook,
			&g_stream_events, s);

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

	// INPUT branché sur le node de l'application ciblée (ses ports de sortie,
	// "monitor de l'app") : même mécanisme que pour le monitor d'un sink.
	// AUTOCONNECT laisse WirePlumber créer le lien node → notre stream. Le
	// lien app → sink par défaut n'est PAS touché (l'audio local continue de
	// sortir normalement ; on ne fait qu'ajouter une prise de capture).
	if (pw_stream_connect((pw_stream *)s->stream, PW_DIRECTION_INPUT, node_id,
			PW_STREAM_FLAG_AUTOCONNECT, params, 1) < 0) {
		UtilityFunctions::printerr("waylandgodot: audio: pw_stream_connect a échoué (node ",
			node_id, ", pid ", pid, ")");
		pw_stream_destroy((pw_stream *)s->stream);
		free(s->hook);
		delete s;
		return;
	}
	UtilityFunctions::print("waylandgodot: audio: capture connectée au node ", node_id,
		" (pid ", pid, ")");
	// L'appelant (apply_targets) détient déjà streams_mutex.
	streams.push_back(s);
}

// Limiteur simple : ~1,4 dB de marge + clamp à ±1. Le mélange de plusieurs
// apps peut dépasser 0 dBFS ; sans limite, le décodage OPUS en s16 côté
// récepteur WRAP au-delà de ±32767 → distorsion dure (signal « saturé »).
static float limit_sample(float v) {
	v *= 0.85f;
	if (v > 1.0f) {
		return 1.0f;
	}
	if (v < -1.0f) {
		return -1.0f;
	}
	return v;
}

void AudioShare::stream_process_cb(void *user_data) {
	auto *s = static_cast<AudioCaptureStream *>(user_data);
	if (!s || !s->stream) {
		return;
	}
	struct pw_buffer *b = pw_stream_dequeue_buffer((pw_stream *)s->stream);
	if (!b) {
		return;
	}
	struct spa_data *d = &b->buffer->datas[0];
	uint8_t *data = static_cast<uint8_t *>(d->data);
	if (data == nullptr || d->chunk->size == 0) {
		pw_stream_queue_buffer((pw_stream *)s->stream, b);
		return;
	}
	uint32_t stride = d->chunk->stride > 0
		? (uint32_t)d->chunk->stride
		: AUDIO_CHANNELS * sizeof(float);
	uint32_t bytes = d->chunk->size;
	if (stride == 0) {
		pw_stream_queue_buffer((pw_stream *)s->stream, b);
		return;
	}
	uint32_t n_frames = bytes / stride;

	std::lock_guard<std::mutex> lk(s->ring_mutex);
	for (uint32_t i = 0; i < n_frames; i++) {
		float *frame = reinterpret_cast<float *>(data + (size_t)i * stride);
		float l = limit_sample(frame[0]);
		float r = limit_sample(frame[1]);
		if (s->ring_count < RING_CAPACITY_FRAMES) {
			size_t tail = (s->ring_head + s->ring_count) % RING_CAPACITY_FRAMES;
			s->ring[tail * AUDIO_CHANNELS + 0] = l;
			s->ring[tail * AUDIO_CHANNELS + 1] = r;
			s->ring_count++;
		} else {
			// Buffer plein : on écrase la plus ancienne (live, la fraîcheur prime).
			size_t tail = (s->ring_head + s->ring_count) % RING_CAPACITY_FRAMES;
			s->ring[tail * AUDIO_CHANNELS + 0] = l;
			s->ring[tail * AUDIO_CHANNELS + 1] = r;
			s->ring_head = (s->ring_head + 1) % RING_CAPACITY_FRAMES;
		}
	}
	pw_stream_queue_buffer((pw_stream *)s->stream, b);
}

// ---------------------------------------------------------------------
// OPUS encode / decode
// ---------------------------------------------------------------------

bool AudioShare::poll_opus_packet(PackedByteArray &r_out) {
	if (!thread_loop) {
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
	// Mélange : somme des rings de tous les streams actifs, clampé. Un stream
	// qui n'a pas encore 20 ms (démarrage) est compté comme silence.
	std::vector<float> frames(OPUS_FRAME_SIZE * AUDIO_CHANNELS, 0.0f);
	bool have_any = false;
	bool have_data = false;
	{
		std::lock_guard<std::mutex> lk(streams_mutex);
		for (AudioCaptureStream *s : streams) {
			have_any = true;
			std::lock_guard<std::mutex> rlk(s->ring_mutex);
			if (s->ring_count < (size_t)OPUS_FRAME_SIZE) {
				continue;
			}
			have_data = true;
			for (int i = 0; i < OPUS_FRAME_SIZE; i++) {
				size_t src = (s->ring_head + (size_t)i) % RING_CAPACITY_FRAMES;
				frames[i * AUDIO_CHANNELS + 0] += s->ring[src * AUDIO_CHANNELS + 0];
				frames[i * AUDIO_CHANNELS + 1] += s->ring[src * AUDIO_CHANNELS + 1];
			}
			s->ring_head = (s->ring_head + OPUS_FRAME_SIZE) % RING_CAPACITY_FRAMES;
			s->ring_count -= OPUS_FRAME_SIZE;
		}
	}
	if (!have_any || !have_data) {
		return false;
	}
	for (float &v : frames) {
		v = limit_sample(v);
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
