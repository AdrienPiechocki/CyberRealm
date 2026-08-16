#ifndef VIDEO_SHARE_H
#define VIDEO_SHARE_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <atomic>
#include <cstdint>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// Capture vidéo des fenêtres partagées et streaming inter-frame (le
// remplacement du JPEG par-frame) :
//  - côté ÉMETTEUR : les fenêtres partagées sont rendues par le compositeur
//    wlroots dans des DMA-BUF linéaires (CaptureCache). Au lieu de copier
//    chaque image en CPU puis de la compresser en JPEG, VideoShare soumet le
//    DMA-BUF à un encodeur vidéo inter-frame :
//      * VAAPI matériel (h264_vaapi / av1_vaapi) : un worker lit le DMA-BUF
//        (mmap), convertit RGB→NV12 par swscale (SIMD, quelques ms, hors
//        thread principal) puis uploade vers une surface NV12 du pool VAAPI
//        (av_hwframe_transfer_data / vaPutImage). L'encodage H.264/AV1 lui-
//        même est 100 % GPU.
//      * fallback logiciel (libx264) : même worker, encode CPU.
//    Le flux est stable (P-frames) : la bande passante est drastiquement
//    réduite par rapport à JPEG, mais les frames dépendent les unes des
//    autres → pas de drop possible, backpressure via un drapeau busy par
//    fenêtre (le compositeur ne re-rend PAS le buffer tant que le worker ne
//    l'a pas fini de lire) et via une file de sortie bornée (le compositeur
//    ne soumet pas de nouvelle frame tant que la file réseau ne se vide pas).
//    Toute la lecture/encode tourne sur le thread worker : le thread
//    principal ne fait que passer le fd — plus de copie CPU synchrone à
//    30-50 ms sur la boucle de jeu (le problème du JPEG par-frame).
//  - côté RÉCEPTEUR : decode_packet() décode un paquet H.264/AV1 en Image RGBA
//    (décodeur logiciel libavcodec, un contexte par flux identifié par la clé
//    (from, wid)). Les SPS/PPS voyagent en bande (devant chaque keyframe), le
//    récepteur n'a besoin que du codec + dimensions pour se synchroniser.
//
// Le lien fenêtre → flux se fait par wid (window id du compositeur). Les PIDs
// ne sont pas utilisés : le compositeur est aussi le serveur d'affichage, il
// connaît directement la fenêtre partagée.

// Forward declarations (types opaques FFmpeg, pour éviter d'exposer les
// headers système dans le .h).
struct AVCodecContext;
struct AVFrame;
struct AVPacket;
struct SwsContext;

namespace godot {

// Une fenêtre partagée en cours d'encodage. Le encode state (AVCodecContext,
// frames VAAPI, ...) est possédé uniquement par le thread worker ; les
// champs "queue" (busy, params du buffer soumis) sont protégés par encode_mutex.
struct VideoEncodeWindow {
	// ------- protégé par encode_mutex (lu/écrit des deux threads) -------
	std::mutex encode_mutex;
	int wid = -1;
	bool busy = false;            // un DMA-BUF est en cours de lecture/encodage
	bool backpressured = false;   // file de sortie pleine : ne pas soumettre
	bool queued = false;          // soumission acceptée, pas encore traitée
	bool stop_encoding = false;   // arrêt demandé pour cette fenêtre
	int fd = -1;                  // fd du DMA-BUF à encoder (dupliqué à la soumission)
	uint32_t stride = 0;
	uint32_t fourcc = 0;          // VA_FOURCC_* du buffer soumis
	int content_w = 0;            // contenu réel (le buffer peut être arrondi)
	int content_h = 0;
	bool force_keyframe = false;  // demande d'IDR pour la prochaine frame
	uint64_t seq = 0;             // numéro de frame émise (monotone par fenêtre)

	// ------- possédé uniquement par le thread worker -------
	AVCodecContext *avctx = nullptr;     // encodeur (VAAPI ou logiciel)
	AVFrame *sw_frame = nullptr;         // NV12/YUV420P sysmem (conversion swscale)
	AVFrame *hw_frame = nullptr;         // surface VAAPI NV12 (pool, upload via transfer_data)
	SwsContext *sws = nullptr;           // conversion RGBA→NV12/YUV420P
	int sws_w = 0;                       // dimensions du dernier ctx sws (re-créé au changement)
	int sws_h = 0;
	uint32_t sws_fourcc = 0;
	int enc_w = 0;                       // dimensions du dernier encodeur (re-créé au changement)
	int enc_h = 0;
	void *va_frames_ctx = nullptr;       // AVBufferRef* pool VAAPI NV12 (taille = contenu)
	void *packet = nullptr;              // AVPacket* (tampon d'encodage réutilisé)
	int64_t frame_index = 0;
};

// Un paquet vidéo prêt à être envoyé (file de sortie, vidée par poll_packets()).
struct VideoPacket {
	int wid = 0;
	uint64_t seq = 0;
	bool keyframe = false;
	PackedByteArray data;
};

class VideoShare {
public:
	VideoShare();
	~VideoShare();

	// Démarre/arrête le pipeline. start() tente d'abord le backend VAAPI
	// matériel (radeonsi), et retombe en logiciel (libx264) si indisponible.
	// codec = "h264" | "av1" ; bitrate = débit cible en bits/s (0 → défaut).
	// Renvoie false si aucun backend n'a pu démarrer.
	bool start(const String &codec, int bitrate);
	void stop();
	bool is_active() const;
	bool is_hardware() const;
	String active_codec() const;

	// Nouvel ensemble de fenêtres partagées (wids). Réconcilie les encodeurs
	// sur le thread worker : les fenêtres retirées sont arrêtées proprement,
	// les nouvelles sont créées à la première soumission.
	void set_encode_windows(const std::vector<int> &wids);

	// true si le buffer de la fenêtre peut être re-rendu (pas de lecture
	// d'encodage en cours). Appelé par le compositeur AVANT le render pass.
	bool window_ready(int wid) const;

	// true si la fenêtre fait partie de l'ensemble partagé (encodeur actif
	// pour elle). Le compositeur s'en sert pour choisir l'intervalle de
	// recapture (plus court pour le flux vidéo) et le cadrage.
	bool is_encode_window(int wid) const;

	// Soumet un DMA-BUF (main thread, juste après le render + sync GPU) pour
	// encodage. Le fd est dupliqué : le worker en garde une référence propre,
	// le buffer peut être réutilisé par le compositeur après le rendu suivant.
	// Renvoie false si la fenêtre est occupée (busy) ou en backpressure.
	bool submit_dmabuf(int wid, int fd, uint32_t stride, uint32_t fourcc,
			int alloc_w, int alloc_h, int content_w, int content_h);

	// Vide la file de sortie. Chaque entrée : { wid, seq, keyframe, data }.
	Array poll_packets();

	// Demande une keyframe (IDR) pour une fenêtre (nouveau pair, latence, ...).
	void request_keyframe(int wid);

	// Nombre de paquets en attente d'envoi (pour la backpressure / debounce).
	int pending_count() const;

	// ------- Décodeur (récepteur) -------
	// Crée/réinitialise le contexte de décodage d'un flux (codec = "h264" |
	// "av1"). key = encode (from_peer, wid) par l'appelant.
	void decoder_configure(const std::string &key, const String &codec, int width, int height);
	// Décode un paquet (config ou frame) en Image RGBA. keyframe signale un IDR
	// (le décodeur se resynchronise dessus). Renvoie une Image vide si le
	// paquet ne produit pas d'image (ou en cas d'erreur).
	Ref<Image> decoder_feed(const std::string &key, const PackedByteArray &data, bool keyframe);
	void decoder_reset(const std::string &key);
	void decoder_clear_all();

private:
	// Backend encodeur (thread worker uniquement).
	void worker_loop();
	void reconcile_windows();
	bool ensure_encoder(VideoEncodeWindow *w);
	void destroy_encoder(VideoEncodeWindow *w);
	// Traite un job soumis (lit le buffer, convertit, encode, remplit la file).
	void encode_window(VideoEncodeWindow *w, int fd, uint32_t stride, uint32_t fourcc,
			int alloc_w, int alloc_h, int content_w, int content_h);
	void push_packet(int wid, uint64_t seq, bool keyframe, const uint8_t *data, int size);

	// VAAPI.
	bool va_init();                      // ouvre le display DRM + hwdevice FFmpeg
	void va_cleanup();

	// Décodeur (thread appelant, protégé par dec_mutex).
	struct DecoderCtx;
	void decoder_destroy(DecoderCtx *d);
	Ref<Image> decode_to_image(DecoderCtx *d);

	// Mode actif (fixé au start, immuable pendant l'activité).
	bool hw_mode = false;
	bool hw_av1 = false;
	std::string codec_name;
	int bitrate = 0;
	std::atomic<bool> active{false};

	// Ensemble des encodeurs (fenêtres partagées). Créés/supprimés par le
	// thread worker ; consultés par le thread du jeu sous windows_mutex +
	// encode_mutex.
	mutable std::mutex windows_mutex;
	std::vector<int> target_wids;
	std::vector<VideoEncodeWindow *> windows;

	// File de sortie (worker → poll_packets).
	mutable std::mutex out_mutex;
	std::condition_variable out_cv;
	std::vector<VideoPacket *> out_queue;
	size_t out_max = 12;
	size_t out_high = 8;
	size_t out_low = 4;

	// Thread worker (encodage).
	std::thread worker_thread;
	std::mutex wake_mutex;
	std::condition_variable wake_cv;

	// VAAPI display / FFmpeg hwdevice (partagé par toutes les fenêtres,
	// utilisé uniquement par le thread worker après init).
	void *va_display = nullptr;          // VADisplay (vaGetDisplayDRM)
	int va_drm_fd = -1;
	void *hw_device_ctx = nullptr;       // AVBufferRef* hwdevice vaapi

	// Décodeurs (récepteur), protégés par dec_mutex.
	mutable std::mutex dec_mutex;
	struct DecoderCtx {
		AVCodecContext *avctx = nullptr;
		SwsContext *sws = nullptr;
		AVFrame *frame = nullptr;
		AVPacket *pkt = nullptr;
		int width = 0;
		int height = 0;
		int sws_fmt = -1; // format source du dernier ctx sws (recréé s'il change)
	};
	std::unordered_map<std::string, DecoderCtx *> decoders;
};

} // namespace godot

#endif
