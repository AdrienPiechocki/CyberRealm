#ifndef AUDIO_SHARE_H
#define AUDIO_SHARE_H

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
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
// Pour les fenêtres X11 (via xwayland-satellite), le client Wayland est le
// satellite et son PID ne correspond à aucun node : le compositeur résout le
// vrai PID de l'application sur le serveur X (_NET_WM_PID, voir
// x11_pid_resolver.h) et le transmet ici — l'app X11 est elle-même un client
// PipeWire (natif ou via pipewire-pulse) avec son propre PID. Seules les apps
// sans _NET_WM_PID restent non capturées.

// Forward-declaration du type spa au scope global : sans elle, "struct spa_dict"
// à l'intérieur du namespace godot serait résolu en un type godot::spa_dict
// incomplet (différent du spa_dict global utilisé par PipeWire).
struct spa_dict;
struct pw_node_info;
struct pw_client_info;

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
	// streams) est exécutée directement sous pw_thread_loop_lock (les
	// callbacks PW sont suspendus → atomique, cf. set_target_pids).
	void set_target_pids(const std::vector<int> &pids);

	// Encode un paquet OPUS (20 ms, stéréo 48 kHz) mélangé depuis tous les
	// rings. Renvoie false si moins de 20 ms de données sont disponibles.
	// Format émis : [seq u32 LE][payload OPUS] — la séquence sert à la PLC
	// côté récepteur.
	bool poll_opus_packet(PackedByteArray &r_out);

	// Décode un paquet OPUS ([seq u32 LE][payload]) → PCM s16 interleaved
	// (stéréo 48 kHz). p_sender identifie l'émetteur (suivi de séquence par
	// peer) ; les pertes détectées sont comblées par la concealment OPUS.
	// Renvoie un tableau vide si le paquet est invalide.
	PackedByteArray decode_opus_packet(const PackedByteArray &p_in, int p_sender);

	// --- Son par fenêtre (spatialisé localement, flux par fenêtre en LAN) ---
	// Vide les rings et renvoie le PCM capturé PAR PID ({pid: PackedVector2Array},
	// stéréo 48 kHz). Ne pas mélanger avec poll_opus_packet (les deux vident les rings).
	Dictionary drain_pcm();
	// PIDs des applications qui ont actuellement un flux de sortie audio.
	PackedInt32Array audio_pids();
	// PIDs dont le flux de sortie est relié à la sortie `sink_name` : seules ces apps doivent être rejouées par le
	// jeu (une app non redirigée joue déjà directement : la rejouer la ferait entendre deux fois).
	PackedInt32Array routed_pids(const String &sink_name);
	// Encode le PCM d'une clé (fenêtre) en paquets OPUS de 20 ms ([seq u32 LE][payload]).
	Array encode_pcm(int key, const PackedVector2Array &pcm);
	// Décode un paquet d'une clé (émetteur:fenêtre) ; pertes comblées comme decode_opus_packet.
	PackedVector2Array decode_pcm(const String &key, const PackedByteArray &packet);
	void forget_codec(const String &key);
	void forget_encoder(int key);
	// Sortie muette `name` (null sink) liée à la connexion PipeWire : les apps lancées par le jeu y sont dirigées
	// (PULSE_SINK / PIPEWIRE_NODE) ; elle disparaît avec le jeu, même en cas de crash. Démarre la capture au besoin.
	bool set_spatial_sink(bool on, const String &name);

	// Callbacks statiques PipeWire (publiques : référencées par les tables de
	// pointeurs const au namespace scope). Les types spa sont qualifiés avec
	// :: pour désigner le namespace global (sinon le struct serait résolu en
	// godot::spa_dict et serait un type incomplet différent).
	static void stream_process_cb(void *user_data);
	static void registry_global_cb(void *user_data, uint32_t id, uint32_t permissions,
			const char *type, uint32_t version, const struct ::spa_dict *props);
	static void registry_global_remove_cb(void *user_data, uint32_t id);
	static void node_info_cb(void *user_data, const struct pw_node_info *info);
	static void client_info_cb(void *user_data, const struct pw_client_info *info);
	static int metadata_property_cb(void *user_data, uint32_t subject, const char *key, const char *type,
			const char *value);

private:
	void on_registry_global(uint32_t id, const char *type, const struct ::spa_dict *props);
	void on_registry_global_remove(uint32_t id);
	void on_node_info(uint32_t id, const struct pw_node_info *info);
	void on_client_info(uint32_t id, const struct pw_client_info *info);
	// Bind un node pour lire ses props complètes (les props globales du
	// registry n'exposent pas toujours media.class ni client.id). Le résultat
	// arrive de façon asynchrone dans on_node_info ; le NodeBind est rangé
	// dans pending_node_binds jusqu'à l'event info.
	void bind_node_for_info(uint32_t id);
	void bind_client_for_info(uint32_t id);
	struct NodeBind;
	struct ClientBind;
	std::unordered_map<uint32_t, NodeBind *> pending_node_binds;
	std::unordered_map<uint32_t, ClientBind *> pending_client_binds;
	// node_id → client_id (client.id lu dans les props du node).
	std::unordered_map<uint32_t, uint32_t> node_clients;
	// client_id → pid (application.process.id du client, fiable : fixé par le
	// core depuis les credentials du socket, contrairement aux props du node).
	std::unordered_map<uint32_t, int> client_pids;

	// Aligne les streams sur target_pids (détruit ceux dont le PID n'est plus
	// ciblé, connecte ceux qui manquent). Exécutée sous streams_mutex, depuis
	// le thread du jeu (set_target_pids sous lock de la boucle) ou depuis un
	// callback PW (on_node_info / on_client_info, sur le thread de la boucle).
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

	// node_id -> application.process.id (vus au registry). Lu/écrit sur le
	// thread PipeWire (callbacks registry/node/client) ou sous
	// pw_thread_loop_lock (set_target_pids → apply_targets).
	std::unordered_map<uint32_t, int> node_pids;
	// node_id -> media.class (« Stream/Output/Audio » = une app qui joue du son).
	std::unordered_map<uint32_t, std::string> node_classes;
	std::unordered_map<uint32_t, std::string> node_names;      // node_id -> node.name
	std::unordered_map<uint32_t, std::pair<uint32_t, uint32_t>> links; // link_id -> (nœud de sortie, nœud d'entrée)
	void *spatial_sink_proxy = nullptr; // pw_proxy* de la sortie muette
	std::string spatial_sink_name;

	// Retour automatique des apps vers la sortie muette quand on la recrée. Quand elle disparaît (option coupée),
	// WirePlumber renvoie leurs flux sur la sortie par défaut puis pose `target.node = -1` (« suivre la sortie par
	// défaut », comme PulseAudio) dans la métadonnée « default » ; cette clé l'emporte ensuite sur leur
	// `target.object` et elles ne reviendraient plus d'elles-mêmes. Tant que la sortie existe, on efface ce -1 pour
	// les flux de sortie qui la visent : WirePlumber relance le routage et les y ramène. Effacer n'ajoute rien à son
	// état mémorisé (stream-properties) : -1 y est déjà enregistré comme « pas de cible ».
	void *metadata = nullptr;      // pw_metadata* « default »
	void *metadata_hook = nullptr; // spa_hook*
	uint32_t metadata_id = 0;
	std::unordered_map<uint32_t, std::string> node_targets; // node_id -> target.object (props du node)
	std::unordered_map<uint32_t, uint8_t> follow_default;   // node_id -> clés à -1 (1 : target.node, 2 : target.object)
	std::unordered_map<uint32_t, int> released;             // node_id -> effacements depuis la création de la sortie
	void release_spatial_targets();
	void on_metadata_property(uint32_t subject, const char *key, const char *value);
	struct KeyEncoder {
		void *enc = nullptr;           // OpusEncoder*
		std::vector<float> pending;    // stéréo entrelacé, < 20 ms
		uint32_t seq = 0;
	};
	struct KeyDecoder {
		void *dec = nullptr;           // OpusDecoder*
		uint32_t last = 0;
		bool first = true;
	};
	std::unordered_map<int, KeyEncoder> key_encoders;
	std::unordered_map<std::string, KeyDecoder> key_decoders;
	// PIDs ciblés (fenêtres partagées). Protégé par le lock de la boucle PW ;
	// poll_opus_packet ne le lit pas.
	std::vector<int> target_pids;
	// Streams actifs, indexés par node_id. Protégé par streams_mutex
	// (poll_opus_packet du thread du jeu les lit pour mélanger).
	std::vector<AudioCaptureStream *> streams;
	std::mutex streams_mutex;

	// Encoder / decoder OPUS.
	void *opus_encoder = nullptr; // OpusEncoder*
	void *opus_decoder = nullptr; // OpusDecoder*

	// Numérotation des paquets émis (poll_opus_packet, thread du jeu) et
	// dernier seq vu par émetteur (decode_opus_packet, thread du jeu).
	uint32_t tx_seq = 0;
	std::unordered_map<int, uint32_t> rx_last_seq;
};

} // namespace godot

#endif
