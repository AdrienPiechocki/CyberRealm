#ifndef AUDIO_SHARE_H
#define AUDIO_SHARE_H

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// Capture audio de la session du jeu (monitor du sink PipeWire par défaut)
// et streaming :
//  - côté ÉMETTEUR : un thread PipeWire capture le monitor du sink par défaut
//    (F32, 48 kHz, stéréo), remplit un ring buffer, et le thread du jeu
//    consomme des paquets de 20 ms qu'il encode en OPUS (poll_opus_packet).
//  - côté RÉCEPTEUR : decode_opus_packet() décode un paquet OPUS en PCM s16
//    interleaved (stéréo 48 kHz) pour Godot (AudioStreamGeneratorPlayback).
//
// Il n'existe pas de lien standard « fenêtre → flux audio » en Wayland :
// on partage l'audio de sortie de la session (comme un écran partagé classique).

// Forward-declaration du type spa au scope global : sans elle, "struct spa_dict"
// à l'intérieur du namespace godot serait résolu en un type godot::spa_dict
// incomplet (différent du spa_dict global utilisé par PipeWire).
struct spa_dict;

namespace godot {

class AudioShare {
public:
	AudioShare();
	~AudioShare();

	// Démarre/arrête la capture PipeWire. start() est rapide et non bloquant :
	// le thread de capture est lancé et le stream se connecte en asynchrone.
	bool start();
	void stop();
	bool is_active() const;

	// Encodé un paquet OPUS (20 ms, stéréo 48 kHz) depuis le ring buffer.
	// Renvoie false si moins de 20 ms de données sont disponibles.
	bool poll_opus_packet(PackedByteArray &r_out);

	// Décode un paquet OPUS → PCM s16 interleaved (stéréo 48 kHz). Renvoie un
	// tableau vide si le paquet est invalide.
	PackedByteArray decode_opus_packet(const PackedByteArray &p_in);

	// Callbacks statiques PipeWire (publiques : référencées par les tables de
	// pointeurs const au namespace scope). Les types spa sont qualifiés avec
	// :: pour désigner le namespace global (sinon le struct serait résolu en
	// godot::spa_dict et serait un type incomplet différent).
	static void stream_process_cb(void *user_data);
	static void registry_global_cb(void *user_data, uint32_t id, uint32_t permissions,
			const char *type, uint32_t version, const struct ::spa_dict *props);
	static int metadata_property_cb(void *user_data, uint32_t subject, const char *key,
			const char *type, const char *value);

private:
	void on_registry_global(uint32_t id, const char *type, const struct ::spa_dict *props);
	void on_metadata_property(uint32_t subject, const char *key, const char *value);
	void connect_stream(uint32_t target_node_id);

	// Pipelines (main loop PipeWire, tourne dans son propre thread).
	void *thread_loop = nullptr; // pw_thread_loop*
	void *context = nullptr;     // pw_context*
	void *core = nullptr;        // pw_core*
	void *registry = nullptr;    // pw_registry*
	void *metadata = nullptr;    // pw_metadata*
	void *stream = nullptr;      // pw_stream*

	// Hooks spa (persistants — les compound literals C++ n'ont pas d'adresse stable).
	void *registry_hook = nullptr;
	void *metadata_hook = nullptr;
	void *stream_hook = nullptr;

	bool stream_connected = false;
	bool node_name_seen = false;
	bool rescan_done = false; // registry ré-énuméré une fois pour retrouver le sink
	std::string target_node_name; // nom du sink par défaut (résolu via metadata)

	// Ring buffer : échantillons F32 interleaved (L,R), 48 kHz.
	std::mutex ring_mutex;
	std::vector<float> ring;
	size_t ring_head = 0; // prochaine position de lecture (indice /2)
	size_t ring_count = 0;

	// Encoder / decoder OPUS.
	void *opus_encoder = nullptr; // OpusEncoder*
	void *opus_decoder = nullptr; // OpusDecoder*
};

} // namespace godot

#endif
