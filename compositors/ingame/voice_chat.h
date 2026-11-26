#ifndef CYBERREALM_VOICE_CHAT_H
#define CYBERREALM_VOICE_CHAT_H

// Chat vocal : capture du micro (PipeWire, source par défaut ou cible
// choisie), encodage OPUS en trames de 20 ms, et décodage par interlocuteur
// avec dissimulation des pertes. Le transport (réseau, cadence, appuyer
// pour parler / activation vocale) est géré côté GDScript : cette classe ne
// fait que produire et consommer des trames.

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
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
	static constexpr float MAX_GAIN_DB = 40.0f;  // gain du micro : 0 à +40 dB (micros numériques intégrés AMD : son vers -60 dB, aucun gain matériel)

	VoiceChat();
	~VoiceChat();

	// Ouvre le micro. `target` : nom d'un nœud PipeWire (ex. "echo-cancel-source"),
	// "" = source par défaut. Non bloquant.
	bool start(const String &target);
	void stop();
	bool is_active() const;

	// Trames de 20 ms encodées depuis le dernier appel : [{data, rms}]. rms = niveau
	// de la trame (0..1) APRÈS le gain, pour l'activation vocale et l'indicateur de niveau.
	// ATTENTION : toutes les trames passent par l'encodeur. Si l'appelant n'en envoie qu'une partie
	// (activation vocale), le décodeur d'en face n'a plus la même suite de trames que l'encodeur (OPUS
	// code chaque trame par rapport aux précédentes) : son dégradé et 20-30 dB trop faible. Utiliser
	// poll_raw() + encode() pour n'encoder que les trames envoyées.
	Array poll();

	// Trames de 20 ms NON encodées depuis le dernier appel : [{pcm: PackedFloat32Array (FRAME, mono, gain
	// appliqué), rms}]. L'appelant choisit lesquelles envoyer et les passe à encode(), dans l'ordre.
	Array poll_raw();
	// Encode une trame (FRAME échantillons mono) ; vide si la taille est fausse ou en cas d'erreur.
	PackedByteArray encode(const PackedFloat32Array &pcm);

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
	// Filtre anti-composante continue (passe-haut ~40 Hz), avant le gain et la mesure : certains micros (micro
	// numérique intégré d'un portable) sortent un décalage de zéro bien plus fort que le son lui-même. Sans lui, le
	// niveau affiché et l'activation vocale mesuraient ce décalage, que l'encodeur OPUS supprime ensuite (voix reçue
	// ~24 dB plus bas qu'affiché).
	float dc_x1 = 0.0f;
	float dc_y1 = 0.0f;

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
	bool take_frame(float *frame, double &rms); // une trame du tampon, gain appliqué ; false si pas assez d'échantillons
	bool ensure_encoder();
};

} // namespace godot

#endif
