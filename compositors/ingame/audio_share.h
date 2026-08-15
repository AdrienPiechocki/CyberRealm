#ifndef AUDIO_SHARE_H
#define AUDIO_SHARE_H

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// Capture audio des SEULES fenêtres partagées (émetteur) et streaming :
//  - côté ÉMETTEUR : un thread PipeWire surveille les nodes audio de la
//    session et capture la sortie de chaque application dont le PID figure
//    dans target_pids (set_target_pids), i.e. les fenêtres partagées par le
//    jeu. Un stream PW par application ciblée, chaque stream remplit son
//    propre ring buffer ; poll_opus_packet() mélange tous les rings puis
//    encode 20 ms en OPUS. L'audio local n'est PAS modifié : l'application
//    reste branchée sur son sink par défaut, on ajoute seulement une prise
//    de capture sur ses ports de sortie.
//  - côté RÉCEPTEUR : decode_opus_packet() décode un paquet OPUS en PCM s16
//    interleaved (stéréo 48 kHz) pour Godot (AudioStreamGeneratorPlayback).
//
// Le lien fenêtre → flux audio se fait par PID : le PID du client Wayland de
// la fenêtre (compositeur) doit égaler application.process.id du node PW.
// Limitation connue : les apps X11 (via xwayland) ont un PID de client
// Wayland différent (le satellite), le matching par PID ne les trouve pas.

// Forward-declaration du type spa au scope global : sans elle, "struct spa_dict"
// à l'intérieur du namespace godot serait résolu en un type godot::spa_dict
// incomplet (différent du spa_dict global utilisé par PipeWire).
struct spa_dict;
struct pw_node_info;

namespace godot {

// Un stream de capture = une application audio ciblée par PID. Le user_data
// des callbacks PW (process) est ce struct, pas l'AudioShare : chaque stream
// possède son propre ring.
struct AudioCaptureStream {
	void *stream = nullptr; // pw_stream*
	void *hook = nullptr;   // spa_hook*
	int pid = -1;           // application.process.id ciblé
	uint32_t node_id = 0;   // id du node ciblé

	// Ring buffer : échantillons F32 interleaved (L,R), 48 kHz.
	std::mutex ring_mutex;
	std::vector<float> ring;
	size_t ring_head = 0; // prochaine position de lecture (indice /2)
	size_t ring_count = 0;
};

class AudioShare {
public:
	AudioShare();
	~AudioShare();

	// Démarre/arrête la capture PipeWire. start() est rapide et non bloquant :
	// le thread de capture est lancé et les streams se connectent en asynchrone
	// au fur et à mesure que set_target_pids() est appelé.
	bool start();
	void stop();
	bool is_active() const;

	// Nouvel ensemble de PIDs à capturer (les fenêtres partagées). Appelé
	// depuis le thread du jeu ; la réconciliation (création/destruction de
	// streams) est exécutée sur le thread PipeWire via pw_thread_loop_invoke.
	void set_target_pids(const std::vector<int> &pids);

	// Encode un paquet OPUS (20 ms, stéréo 48 kHz) mélangé depuis tous les
	// rings. Renvoie false si moins de 20 ms de données sont disponibles.
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
	static void registry_global_remove_cb(void *user_data, uint32_t id);
	static void node_info_cb(void *user_data, const struct pw_node_info *info);

private:
	void on_registry_global(uint32_t id, const char *type, const struct ::spa_dict *props);
	void on_registry_global_remove(uint32_t id);
	void on_node_info(uint32_t id, const struct pw_node_info *info);
	// Bind un node pour lire ses props complètes (les props globales du
	// registry n'exposent pas toujours application.process.id). Le résultat
	// arrive de façon asynchrone dans on_node_info ; le NodeBind est rangé
	// dans pending_node_binds jusqu'à l'event info.
	void bind_node_for_info(uint32_t id);
	struct NodeBind;
	std::unordered_map<uint32_t, NodeBind *> pending_node_binds;

	// Exécutée sur le thread PipeWire : aligne les streams sur target_pids
	// (détruit ceux dont le PID n'est plus ciblé, connecte ceux qui manquent).
	void apply_targets();
	AudioCaptureStream *find_stream_for_pid(int pid) const;
	AudioCaptureStream *find_stream_for_node(uint32_t node_id) const;
	void create_stream_for(uint32_t node_id, int pid);
	void connect_stream(AudioCaptureStream *s);

	// Pipelines (main loop PipeWire, tourne dans son propre thread).
	void *thread_loop = nullptr; // pw_thread_loop*
	void *context = nullptr;     // pw_context*
	void *core = nullptr;        // pw_core*
	void *registry = nullptr;    // pw_registry*
	void *registry_hook = nullptr; // spa_hook* (persistant)

	// node_id -> application.process.id (vus au registry). Lu/écrit
	// exclusivement sur le thread PipeWire.
	std::unordered_map<uint32_t, int> node_pids;
	// PIDs ciblés (fenêtres partagées). N'écrit que sur le thread PipeWire
	// (set_target_pids délègue via invoke) ; poll_opus_packet ne le lit pas.
	std::vector<int> target_pids;
	// Streams actifs, indexés par node_id. Protégé par streams_mutex
	// (poll_opus_packet du thread du jeu les lit pour mélanger).
	std::vector<AudioCaptureStream *> streams;
	std::mutex streams_mutex;

	// Encoder / decoder OPUS.
	void *opus_encoder = nullptr; // OpusEncoder*
	void *opus_decoder = nullptr; // OpusDecoder*
};

} // namespace godot

#endif
