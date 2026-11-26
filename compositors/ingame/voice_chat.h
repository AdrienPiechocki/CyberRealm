#ifndef CYBERREALM_VOICE_CHAT_H
#define CYBERREALM_VOICE_CHAT_H

// Chat vocal : capture du micro (PipeWire, source par défaut ou cible
// choisie), encodage OPUS en trames de 20 ms, et décodage par interlocuteur
// avec dissimulation des pertes. Le transport (réseau, cadence, appuyer
// pour parler / activation vocale) est géré côté GDScript : cette classe ne
// fait que produire et consommer des trames.

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <map>
#include <mutex>
#include <vector>

namespace godot {

class VoiceChat {
public:
	static constexpr int RATE = 48000;
	static constexpr int FRAME = 960;           // 20 ms à 48 kHz
	static constexpr int BITRATE = 24000;
	static constexpr int MAX_PACKET = 400;      // octets (borne réseau, cf. scripts/network/lan/voice.gd)
	static constexpr int MAX_PLC_FRAMES = 3;    // pertes comblées au-delà : nouvelle prise de parole
	static constexpr float MAX_GAIN_DB = 24.0f;  // gain du micro : 0 à +24 dB

	VoiceChat();
	~VoiceChat();

	// Ouvre le micro. `target` : nom d'un nœud PipeWire (ex. "echo-cancel-source"),
	// "" = source par défaut. Non bloquant.
	bool start(const String &target);
	void stop();
	bool is_active() const;

	// Trames de 20 ms encodées depuis le dernier appel : [{data, rms}]. rms = niveau
	// de la trame (0..1) APRÈS le gain, pour l'activation vocale et l'indicateur de niveau.
	Array poll();

	// Gain appliqué au micro avant l'encodage (dB, borné à [0, MAX_GAIN_DB]) : un micro faible (micro intégré d'un
	// portable) arrive à un niveau normal chez les autres joueurs. Écrêtage doux au-delà de la pleine échelle.
	void set_gain_db(float db);
	float get_gain_db() const { return gain_db; }

	// Décode une trame d'un interlocuteur. `seq` : numéro de la trame chez
	// l'émetteur (les trous de 1 à MAX_PLC_FRAMES sont comblés). Renvoie des
	// échantillons stéréo (mono dupliqué), vide si la trame est invalide.
	PackedVector2Array decode(int peer, int seq, const PackedByteArray &data);
	void forget(int peer);

	// Injecte des échantillons mono comme s'ils venaient du micro (tests, sans
	// ouvrir de périphérique). Crée l'encodeur au besoin.
	void feed(const float *samples, int n);

	static void process_cb(void *user_data);

private:
	void *thread_loop = nullptr; // pw_thread_loop*
	void *stream = nullptr;      // pw_stream*
	void *hook = nullptr;        // spa_hook*
	void *encoder = nullptr;     // OpusEncoder*
	float gain_db = 0.0f;
	float gain = 1.0f;           // linéaire (lu par poll(), thread principal)

	std::mutex ring_mutex;
	std::vector<float> ring;     // mono, RATE
	size_t ring_head = 0;
	size_t ring_count = 0;

	struct PeerDecoder {
		void *decoder = nullptr; // OpusDecoder*
		int last_seq = -1;
	};
	std::map<int, PeerDecoder> decoders;

	void push_samples(const float *samples, uint32_t n, uint32_t stride_floats);
	bool ensure_encoder();
};

} // namespace godot

#endif
