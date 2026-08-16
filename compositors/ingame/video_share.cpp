// Implémentation de VideoShare : encodeur vidéo inter-frame pour le partage
// LAN des fenêtres (remplacement du JPEG par-frame). Voir video_share.h pour
// l'architecture. Backend VAAPI matériel (radeonsi) ou logiciel (libx264).
//
// Pipelines de flux de données (les deux s'exécutent sur le thread worker) :
//   VAAPI :  mmap fd → swscale RGBA→NV12 (sysmem) → av_hwframe_get_buffer
//            (surface NV12 du pool) → av_hwframe_transfer_data (vaPutImage)
//            → avcodec_send_frame (encode GPU) → avcodec_receive_packet.
//   logiciel : mmap fd → swscale RGBA→YUV420P → avcodec_send_frame (libx264).
//
// L'encodeur FFmpeg vaapi exige une entrée NV12/YUV (le profil est dérivé de
// hw_frames_ctx->sw_format) : on ne peut pas lui passer directement une
// surface RGB — d'où la conversion swscale. Celle-ci coûte quelques ms et
// tourne HORS thread principal.

#include "video_share.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <fcntl.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_set>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
#include <va/va.h>
#include <va/va_drm.h>
}

using namespace godot;

namespace {

// Convertit un format DMA-BUF du compositeur (DRM_FORMAT_*) en format
// AV_PIX_FMT pour swscale. Le compositeur produit des buffers linéaires
// single-plane : ABGR8888/XBGR8888 = RGBA en mémoire, ARGB8888/XRGB8888 =
// BGRA en mémoire (cf. les chemins capture_surface_vulkan/dmabuf).
AVPixelFormat drm_fourcc_to_avfmt(uint32_t fourcc) {
	switch (fourcc) {
	case 0x34324241 /* DRM_FORMAT_ABGR8888 */:
	case 0x34324258 /* DRM_FORMAT_XBGR8888 */:
		return AV_PIX_FMT_RGBA;
	case 0x34324152 /* DRM_FORMAT_ARGB8888 */:
	case 0x34324158 /* DRM_FORMAT_XRGB8888 */:
		return AV_PIX_FMT_BGRA;
	default:
		return AV_PIX_FMT_NONE;
	}
}

// Format de sortie des encodeurs : NV12 pour VAAPI (exigé par les profils
// h264/av1), YUV420P pour libx264.
AVPixelFormat target_pix_fmt(bool hw) {
	return hw ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
}

} // namespace

VideoShare::VideoShare() {
	av_log_set_level(AV_LOG_WARNING);
}

VideoShare::~VideoShare() {
	stop();
	decoder_clear_all();
}

// ---------------------------------------------------------------------------
// Cycle de vie
// ---------------------------------------------------------------------------

bool VideoShare::start(const String &codec, int bitrate) {
	if (active.load()) return false;

	this->bitrate = bitrate > 0 ? bitrate : 8'000'000;
	codec_name = (codec == "av1") ? "av1" : "h264";
	hw_av1 = (codec_name == "av1");

	// Encodage MATÉRIEL désactivé par défaut : sur cette machine (RDNA3 /
	// radeonsi) le chemin VAAPI est peu fiable — h264_vaapi comme av1_vaapi
	// plafonnent à ~8 img/s (~130 ms/frame, coût hors lecture DMA-BUF) puis
	// gèlent le GPU (freeze total du jeu). On encode donc en logiciel
	// (libx264, thread worker) par défaut ; l'accélération VAAPI reste
	// accessible à des fins de test via CYBERREALM_VIDEO_HW=1.
	const char *hw_env = getenv("CYBERREALM_VIDEO_HW");
	bool want_hw = hw_env && strcmp(hw_env, "1") == 0;

	if (want_hw) {
		hw_mode = va_init();
	} else {
		hw_mode = false;
	}

	if (!hw_mode) {
		if (hw_av1) {
			// AV1 matériel seulement : pas de fallback logiciel dans cette
			// version (libsvtav1 non lié). L'appelant retente avec le codec
			// suivant de la préférence (h264 → libx264).
			va_cleanup();
			UtilityFunctions::print("waylandgodot: video_share: AV1 sans accélération VAAPI "
				"(CYBERREALM_VIDEO_HW=1 requis) et pas de fallback logiciel — partage vidéo désactivé");
			return false;
		}
		const AVCodec *c = avcodec_find_encoder_by_name("libx264");
		if (!c) {
			va_cleanup();
			UtilityFunctions::print("waylandgodot: video_share: libx264 introuvable — "
				"partage vidéo désactivé");
			return false;
		}
	}

	active = true;
	worker_thread = std::thread(&VideoShare::worker_loop, this);
	return true;
}

void VideoShare::stop() {
	if (!active.exchange(false) && !worker_thread.joinable()) return;
	wake_cv.notify_all();
	if (worker_thread.joinable()) worker_thread.join();

	{
		std::lock_guard<std::mutex> g(windows_mutex);
		for (auto *w : windows) {
			destroy_encoder(w);
			delete w;
		}
		windows.clear();
		target_wids.clear();
	}
	// Fenêtres retirées du partage (destruction différée) : libérées ici,
	// après join() du worker — plus aucune copie en vol possible.
	for (auto *w : retired_windows) {
		destroy_encoder(w);
		delete w;
	}
	retired_windows.clear();
	{
		std::lock_guard<std::mutex> g(out_mutex);
		for (auto *p : out_queue) delete p;
		out_queue.clear();
	}
	va_cleanup();
	hw_mode = false;
}

bool VideoShare::is_active() const {
	return active.load();
}

bool VideoShare::is_hardware() const {
	return hw_mode;
}

String VideoShare::active_codec() const {
	return codec_name.c_str();
}

// ---------------------------------------------------------------------------
// Fenêtres partagées / soumission
// ---------------------------------------------------------------------------

void VideoShare::set_encode_windows(const std::vector<int> &wids) {
	{
		std::lock_guard<std::mutex> g(windows_mutex);
		target_wids = wids;
	}
	wake_cv.notify_all();
}

bool VideoShare::window_ready(int wid) const {
	if (!active.load()) return true;
	std::vector<VideoEncodeWindow *> ws;
	{
		std::lock_guard<std::mutex> g(windows_mutex);
		ws = windows;
	}
	for (auto *w : ws) {
		if (w->wid == wid) {
			std::lock_guard<std::mutex> g(w->encode_mutex);
			return !w->busy && !w->stop_encoding;
		}
	}
	return true; // fenêtre non partagée → capture normale
}

bool VideoShare::submit_dmabuf(int wid, int fd, uint32_t stride, uint32_t fourcc,
		int alloc_w, int alloc_h, int content_w, int content_h) {
	if (!active.load()) return false;
	if (fd < 0 || stride == 0) return false;

	std::vector<VideoEncodeWindow *> ws;
	{
		std::lock_guard<std::mutex> g(windows_mutex);
		ws = windows;
	}
	VideoEncodeWindow *w = nullptr;
	for (auto *x : ws) {
		if (x->wid == wid) { w = x; break; }
	}
	if (!w) return false;

	int dupfd = dup(fd);
	if (dupfd < 0) return false;

	{
		std::lock_guard<std::mutex> g(w->encode_mutex);
		if (w->busy || w->backpressured || w->stop_encoding) {
			close(dupfd);
			return false;
		}
		size_t q;
		{
			std::lock_guard<std::mutex> og(out_mutex);
			q = out_queue.size();
		}
		if (q >= out_max) {
			close(dupfd);
			return false;
		}
		w->fd = dupfd;
		w->stride = stride;
		w->fourcc = fourcc;
		w->content_w = content_w > 0 ? content_w : alloc_w;
		w->content_h = content_h > 0 ? content_h : alloc_h;
		w->queued = true;
		w->busy = true;
	}
	wake_cv.notify_all();
	return true;
}

void VideoShare::request_keyframe(int wid) {
	if (!active.load()) return;
	std::vector<VideoEncodeWindow *> ws;
	{
		std::lock_guard<std::mutex> g(windows_mutex);
		ws = windows;
	}
	for (auto *w : ws) {
		if (w->wid == wid) {
			std::lock_guard<std::mutex> g(w->encode_mutex);
			w->force_keyframe = true;
			return;
		}
	}
}

int VideoShare::pending_count() const {
	std::lock_guard<std::mutex> g(out_mutex);
	return (int)out_queue.size();
}

Array VideoShare::poll_packets() {
	Array result;
	std::vector<VideoPacket *> drained;
	{
		std::lock_guard<std::mutex> g(out_mutex);
		drained.swap(out_queue);
	}
	for (auto *p : drained) {
		Dictionary d;
		d["wid"] = p->wid;
		d["seq"] = (int64_t)p->seq;
		d["keyframe"] = p->keyframe;
		d["data"] = p->data;
		result.append(d);
		delete p;
	}

	// Backpressure : dès que la file repasse sous le seuil bas, on réautorise
	// la capture des fenêtres bloquées (le compositeur reprend les soumissions).
	size_t sz;
	{
		std::lock_guard<std::mutex> g(out_mutex);
		sz = out_queue.size();
	}
	if (sz < out_low) {
		std::vector<VideoEncodeWindow *> ws;
		{
			std::lock_guard<std::mutex> g(windows_mutex);
			ws = windows;
		}
		for (auto *w : ws) {
			std::lock_guard<std::mutex> g(w->encode_mutex);
			if (w->backpressured) {
				w->backpressured = false;
				w->busy = false;
			}
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// Thread worker : réconciliation des fenêtres + encodage
// ---------------------------------------------------------------------------

void VideoShare::worker_loop() {
	// Diagnostic : timing d'encodage cumulé sur 1 s (ce thread).
	using clock = std::chrono::steady_clock;
	auto stat_start = clock::now();
	long stat_frames = 0;
	double stat_sum_ms = 0.0, stat_max_ms = 0.0;

	while (active.load()) {
		reconcile_windows();

		std::vector<VideoEncodeWindow *> snapshot;
		{
			std::lock_guard<std::mutex> g(windows_mutex);
			snapshot = windows;
		}

		bool any = false;
		for (auto *w : snapshot) {
			int fd = -1;
			uint32_t stride = 0, fourcc = 0;
			int aw = 0, ah = 0, cw = 0, ch = 0;
			bool have = false;
			{
				std::lock_guard<std::mutex> g(w->encode_mutex);
				if (w->stop_encoding) continue;
				if (w->queued) {
					w->queued = false;
					fd = w->fd;
					stride = w->stride;
					fourcc = w->fourcc;
					aw = w->content_w;
					ah = w->content_h;
					cw = w->content_w;
					ch = w->content_h;
					have = true;
				}
			}
			if (!have) continue;
			any = true;

			auto t0 = clock::now();
			encode_window(w, fd, stride, fourcc, aw, ah, cw, ch);
			auto t1 = clock::now();
			double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
			stat_frames++;
			stat_sum_ms += ms;
			stat_max_ms = std::max(stat_max_ms, ms);

			// Lecture terminée → le buffer peut être re-rendu. Si la file de
			// sortie est pleine (réseau lent), on retient la fenêtre en
			// backpressure pour ne pas accumuler de retard d'encodage.
			size_t out_sz;
			{
				std::lock_guard<std::mutex> g(out_mutex);
				out_sz = out_queue.size();
			}
			{
				std::lock_guard<std::mutex> g(w->encode_mutex);
				w->fd = -1;
				if (w->stop_encoding) {
					// la fenêtre sera supprimée à la prochaine réconciliation
				} else if (out_sz >= out_high) {
					w->backpressured = true;
					w->busy = false;
				} else {
					w->backpressured = false;
					w->busy = false;
				}
			}
		}

		// Diagnostic 1×/s : coût réel d'encodage (thread worker) pour
		// confirmer si le goulot est l'encodeur ou le thread principal.
		if (stat_frames > 0 &&
				std::chrono::duration<double>(clock::now() - stat_start).count() >= 1.0) {
			UtilityFunctions::print("waylandgodot: [video] worker diag: ",
				stat_frames, " img/s, moy ", String::num(stat_sum_ms / stat_frames, 1),
				" ms, max ", String::num(stat_max_ms, 1), " ms");
			stat_start = clock::now();
			stat_frames = 0;
			stat_sum_ms = 0.0;
			stat_max_ms = 0.0;
		}

		if (!any) {
			std::unique_lock<std::mutex> lk(wake_mutex);
			wake_cv.wait_for(lk, std::chrono::milliseconds(50), [&] {
				if (!active.load()) return true;
				std::lock_guard<std::mutex> g(windows_mutex);
				for (auto *w : windows) {
					std::lock_guard<std::mutex> wg(w->encode_mutex);
					if (w->queued) return true;
				}
				return false;
			});
		}
	}
}

void VideoShare::reconcile_windows() {
	std::vector<VideoEncodeWindow *> to_delete;
	{
		std::lock_guard<std::mutex> g(windows_mutex);
		std::unordered_set<int> wanted(target_wids.begin(), target_wids.end());

		for (auto it = windows.begin(); it != windows.end();) {
			VideoEncodeWindow *w = *it;
			if (wanted.count(w->wid) == 0) {
				{
					std::lock_guard<std::mutex> wg(w->encode_mutex);
					w->stop_encoding = true;
					if (w->fd >= 0) {
						close(w->fd);
						w->fd = -1;
						w->queued = false;
					}
				}
				to_delete.push_back(w);
				it = windows.erase(it);
			} else {
				++it;
			}
		}
		std::unordered_set<int> have;
		for (auto *w : windows) have.insert(w->wid);
		for (int wid : target_wids) {
			if (have.count(wid)) continue;
			auto *w = new VideoEncodeWindow();
			w->wid = wid;
			windows.push_back(w);
		}
	}
	// Destruction différée : d'autres threads (window_ready, submit_dmabuf,
	// request_keyframe, poll_packets) copient `windows` sous windows_mutex
	// puis verrouillent encode_mutex sur ces pointeurs bruts. Un delete ici
	// libérerait un encode_mutex encore en cours de verrouillage → use-
	// after-free → corruption du tas ("malloc(): invalid size (unsorted)").
	// Les encodeurs retirés sont libérés, les objets restent vivants jusqu'à
	// stop() (après join() du worker). encode_mutex est pris pour attendre
	// toute soumission (thread principal) encore en cours.
	for (auto *w : to_delete) {
		std::lock_guard<std::mutex> g(w->encode_mutex);
		destroy_encoder(w);
	}
	retired_windows.insert(retired_windows.end(), to_delete.begin(), to_delete.end());
}

// ---------------------------------------------------------------------------
// Encodage
// ---------------------------------------------------------------------------

void VideoShare::push_packet(int wid, uint64_t seq, bool keyframe, const uint8_t *data, int size) {
	auto *p = new VideoPacket();
	p->wid = wid;
	p->seq = seq;
	p->keyframe = keyframe;
	p->data.resize(size);
	if (size > 0 && data) {
		memcpy(p->data.ptrw(), data, (size_t)size);
	}
	std::lock_guard<std::mutex> g(out_mutex);
	if (out_queue.size() < out_max) {
		out_queue.push_back(p);
	} else {
		// Ne devrait pas arriver (backpressure), mais un drop casserait la
		// chaîne de P-frames → on force une keyframe pour la resynchronisation.
		delete p;
		UtilityFunctions::print("waylandgodot: video_share: paquet vidéo dropé (file pleine), "
			"keyframe demandée");
		request_keyframe(wid);
	}
	out_cv.notify_all();
}

bool VideoShare::ensure_encoder(VideoEncodeWindow *w) {
	if (w->avctx && w->enc_w == w->content_w && w->enc_h == w->content_h) {
		return true;
	}
	destroy_encoder(w);
	w->enc_w = w->content_w;
	w->enc_h = w->content_h;

	if (hw_mode) {
		AVBufferRef *frames_ref = av_hwframe_ctx_alloc((AVBufferRef *)hw_device_ctx);
		if (!frames_ref) {
			UtilityFunctions::printerr("waylandgodot: video_share: av_hwframe_ctx_alloc a échoué");
			return false;
		}
		AVHWFramesContext *frames = (AVHWFramesContext *)frames_ref->data;
		frames->format = AV_PIX_FMT_VAAPI;
		frames->width = w->content_w;
		frames->height = w->content_h;
		frames->sw_format = AV_PIX_FMT_NV12;
		// Pool généreux : av_hwframe_get_buffer BLOQUE tant que toutes les
		// surfaces sont prises (frames de référence + frame courante). Avec un
		// pool de 4, un encodeur qui garde des références peut mettre le worker
		// en attente (dégradation du débit). 8 = marge confortable, la surface
		// d'un frame rendu est libérée dès l'avcodec_send_frame.
		frames->initial_pool_size = 8;
		if (av_hwframe_ctx_init(frames_ref) < 0) {
			UtilityFunctions::printerr("waylandgodot: video_share: av_hwframe_ctx_init a échoué");
			av_buffer_unref(&frames_ref);
			return false;
		}

		const char *name = hw_av1 ? "av1_vaapi" : "h264_vaapi";
		const AVCodec *codec = avcodec_find_encoder_by_name(name);
		if (!codec) {
			UtilityFunctions::printerr("waylandgodot: video_share: encodeur ", name, " introuvable");
			av_buffer_unref(&frames_ref);
			return false;
		}
		AVCodecContext *ctx = avcodec_alloc_context3(codec);
		if (!ctx) {
			av_buffer_unref(&frames_ref);
			return false;
		}
		ctx->width = w->content_w;
		ctx->height = w->content_h;
		ctx->time_base = (AVRational){1, 60};
		ctx->framerate = (AVRational){60, 1};
		ctx->pix_fmt = AV_PIX_FMT_VAAPI;
		ctx->hw_frames_ctx = av_buffer_ref(frames_ref);
		ctx->bit_rate = bitrate;
		ctx->gop_size = 60;
		// Pas de B-frames : pour du contenu d'écran (texte fin, UI), le gain de
		// débit est marginal et cela double les surfaces retenues par le driver
		// (références) + la latence d'ordonnancement. IPPP pur = moins de
		// pression sur le pool et un flux plus réactif.
		ctx->max_b_frames = 0;
		// Qualité : sur un réseau local le débit n'est pas limité, c'est la
		// qualité perçue qui prime (jeux : texte net, pas d'artefacts).
		//   - h264_vaapi : CQP (qualité constante) — le débit réel s'adapte au
		//     contenu (~8 Mbps à qp 24 sur un 1080p test pattern).
		//   - av1_vaapi : n'expose PAS d'option qp (pas de CQP contrôlable, le
		//     CQP par défaut encode à un débit non maîtrisé) → VBR avec un
		//     débit généreux (12 Mbps) : qualité sans artefacts pour du 1080p.
		// En cas d'échec de av_opt_set (pilote trop ancien), on retombe
		// silencieusement sur le VBR paramétré par ctx->bit_rate.
		if (hw_av1) {
			av_opt_set(ctx->priv_data, "rc_mode", "VBR", 0);
		} else {
			av_opt_set(ctx->priv_data, "rc_mode", "CQP", 0);
			av_opt_set(ctx->priv_data, "qp", "24", 0);
		}
		if (avcodec_open2(ctx, codec, nullptr) < 0) {
			UtilityFunctions::printerr("waylandgodot: video_share: avcodec_open2(", name, ") a échoué");
			av_buffer_unref(&frames_ref);
			avcodec_free_context(&ctx);
			return false;
		}
		w->avctx = ctx;
		w->va_frames_ctx = frames_ref;
		return true;
	}

	const AVCodec *codec = avcodec_find_encoder_by_name("libx264");
	if (!codec) {
		UtilityFunctions::printerr("waylandgodot: video_share: libx264 introuvable");
		return false;
	}
	AVCodecContext *ctx = avcodec_alloc_context3(codec);
	if (!ctx) return false;
	ctx->width = w->content_w;
	ctx->height = w->content_h;
	ctx->time_base = (AVRational){1, 60};
	ctx->framerate = (AVRational){60, 1};
	ctx->pix_fmt = AV_PIX_FMT_YUV420P;
	ctx->gop_size = 60;
	ctx->max_b_frames = 2;
	av_opt_set(ctx->priv_data, "preset", "veryfast", 0);
	// SPS/PPS devant chaque keyframe : le récepteur peut se synchroniser à
	// n'importe quelle IDR sans recevoir d'extradata séparé.
	av_opt_set(ctx->priv_data, "x264-params", "repeat-headers=1", 0);
	// Qualité constante (CRF 20) comme en matériel (CQP) : le débit cible
	// (ctx->bit_rate) est ignoré en CRF — sur LAN la qualité prime.
	ctx->bit_rate = 0;
	av_opt_set(ctx->priv_data, "crf", "20", 0);
	if (avcodec_open2(ctx, codec, nullptr) < 0) {
		UtilityFunctions::printerr("waylandgodot: video_share: avcodec_open2(libx264) a échoué");
		avcodec_free_context(&ctx);
		return false;
	}
	w->avctx = ctx;
	return true;
}

void VideoShare::destroy_encoder(VideoEncodeWindow *w) {
	if (w->avctx) {
		avcodec_free_context(&w->avctx);
		w->avctx = nullptr;
	}
	if (w->va_frames_ctx) {
		av_buffer_unref((AVBufferRef **)&w->va_frames_ctx);
		w->va_frames_ctx = nullptr;
	}
	if (w->sw_frame) {
		av_frame_free(&w->sw_frame);
		w->sw_frame = nullptr;
	}
	if (w->hw_frame) {
		av_frame_free(&w->hw_frame);
		w->hw_frame = nullptr;
	}
	if (w->sws) {
		sws_freeContext(w->sws);
		w->sws = nullptr;
	}
	if (w->packet) {
		av_packet_free((AVPacket **)&w->packet);
		w->packet = nullptr;
	}
	w->sws_w = w->sws_h = 0;
	w->sws_fourcc = 0;
	w->enc_w = w->enc_h = 0;
	w->frame_index = 0;
}

void VideoShare::encode_window(VideoEncodeWindow *w, int fd, uint32_t stride, uint32_t fourcc,
		int alloc_w, int alloc_h, int content_w, int content_h) {
	// NOTE: alloc_w/h ne sont plus utilisés ici : on encode uniquement le
	// contenu (content_w/h), le stride réel du buffer source étant celui du
	// compositor (stride). Les paramètres restent dans la signature pour
	// tracer d'éventuelles évolutions (encode de la zone pleine).

	if (!ensure_encoder(w)) {
		UtilityFunctions::printerr("waylandgodot: video_share: échec de création de l'encodeur "
			"(wid=", w->wid, ")");
		close(fd);
		return;
	}
	AVCodecContext *ctx = w->avctx;
	AVFrame *frame = w->sw_frame;
	if (!frame) frame = w->sw_frame = av_frame_alloc();
	if (!frame) {
		close(fd);
		return;
	}

	// Accès direct au DMA-BUF (même principe que le chemin CPU du compositeur,
	// mais hors thread principal). Le buffer est garanti synchronisé par le
	// compositeur avant la soumission (wait_for_dmabuf_gpu_writes) ; on
	// ré-invalide quand même le cache CPU pour lire les données fraîches.
	//
	// Diagnostic par étape : si une frame dépasse ~25 ms (pilote VAAPI RDNA3
	// suspecté de plafonner à ~130 ms/frame), on veut le détail du coût :
	// lecture DMA-BUF + conversion, upload VAAPI, ou encode lui-même.
	using sclock = std::chrono::steady_clock;
	auto t_mm = sclock::now();
	auto t_sw = t_mm;
	auto t_up = t_mm;
	auto t_end = t_mm;

	long page_size = sysconf(_SC_PAGE_SIZE);
	off_t plane_offset = 0; // buffers GBM single-plane → offset 0
	off_t map_offset = plane_offset & ~(off_t)(page_size - 1);
	size_t map_delta = (size_t)(plane_offset - map_offset);
	size_t map_size = map_delta + (size_t)stride * (size_t)alloc_h;
	void *map = mmap(nullptr, map_size, PROT_READ, MAP_SHARED, fd, map_offset);
	if (map == MAP_FAILED) {
		UtilityFunctions::printerr("waylandgodot: video_share: mmap dmabuf a échoué (wid=", w->wid, ")");
		close(fd);
		return;
	}
	const uint8_t *src = static_cast<const uint8_t *>(map) + map_delta;
	struct dma_buf_sync sync = {};
	sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
	ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);

	AVPixelFormat src_fmt = drm_fourcc_to_avfmt(fourcc);
	AVPixelFormat dst_fmt = target_pix_fmt(hw_mode);

	// Re-création du contexte swscale au changement de format/taille.
	if (!w->sws || w->sws_w != content_w || w->sws_h != content_h || w->sws_fourcc != fourcc) {
		if (w->sws) sws_freeContext(w->sws);
		w->sws = sws_getContext(content_w, content_h, src_fmt,
			content_w, content_h, dst_fmt, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
		w->sws_w = content_w;
		w->sws_h = content_h;
		w->sws_fourcc = fourcc;
	}
	if (!w->sws) {
		UtilityFunctions::printerr("waylandgodot: video_share: sws_getContext a échoué (wid=", w->wid, ")");
		sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
		ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
		munmap(map, map_size);
		close(fd);
		return;
	}

	// Frame sysmem cible (NV12 ou YUV420P), allouée/redimensionnée au besoin.
	if (frame->format != dst_fmt || frame->width != content_w || frame->height != content_h) {
		av_frame_unref(frame);
		frame->format = dst_fmt;
		frame->width = content_w;
		frame->height = content_h;
		if (av_frame_get_buffer(frame, 32) < 0) {
			UtilityFunctions::printerr("waylandgodot: video_share: av_frame_get_buffer a échoué (wid=", w->wid, ")");
			sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
			ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
			munmap(map, map_size);
			close(fd);
			return;
		}
	}

	const uint8_t *src_slices[4] = { src, nullptr, nullptr, nullptr };
	const int src_linesize[4] = { (int)stride, 0, 0, 0 };
	sws_scale(w->sws, src_slices, src_linesize, 0, content_h,
		frame->data, frame->linesize);
	t_sw = sclock::now();

	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
	ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
	munmap(map, map_size);
	close(fd);

	// Keyframe à la demande (nouveau pair, latence, drop...).
	{
		std::lock_guard<std::mutex> g(w->encode_mutex);
		if (w->force_keyframe) {
			frame->pict_type = AV_PICTURE_TYPE_I;
			w->force_keyframe = false;
		} else {
			frame->pict_type = AV_PICTURE_TYPE_NONE;
		}
	}
	frame->pts = w->frame_index++;

	// Envoi : VAAPI via surface NV12 du pool (upload GPU), logiciel direct.
	AVFrame *input = frame;
	if (hw_mode) {
		if (!w->hw_frame) w->hw_frame = av_frame_alloc();
		if (w->hw_frame && av_hwframe_get_buffer((AVBufferRef *)w->va_frames_ctx, w->hw_frame, 0) == 0) {
			if (av_hwframe_transfer_data(w->hw_frame, frame, 0) == 0) {
				w->hw_frame->pts = frame->pts;
				w->hw_frame->pict_type = frame->pict_type;
				input = w->hw_frame;
			} else {
				UtilityFunctions::printerr("waylandgodot: video_share: av_hwframe_transfer_data a échoué (wid=", w->wid, ")");
				av_frame_unref(w->hw_frame);
				input = nullptr;
			}
		} else {
			UtilityFunctions::printerr("waylandgodot: video_share: av_hwframe_get_buffer a échoué (wid=", w->wid, ")");
			input = nullptr;
		}
	}
	t_up = sclock::now();

	if (input) {
		int ret = avcodec_send_frame(ctx, input);
		av_frame_unref(input);
		if (ret < 0) {
			UtilityFunctions::printerr("waylandgodot: video_share: avcodec_send_frame a échoué (", ret, ") (wid=", w->wid, ")");
		} else {
			if (!w->packet) w->packet = av_packet_alloc();
			while (w->packet && avcodec_receive_packet(ctx, (AVPacket *)w->packet) == 0) {
				AVPacket *pkt = (AVPacket *)w->packet;
				bool kf = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
				uint64_t seq;
				{
					std::lock_guard<std::mutex> g(w->encode_mutex);
					seq = w->seq++;
				}
				push_packet(w->wid, seq, kf, pkt->data, pkt->size);
				av_packet_unref(pkt);
			}
		}
	} else {
		// L'échec d'upload laisse une frame sans encodage → demande une
		// keyframe pour resynchroniser le récepteur sur la suivante.
		request_keyframe(w->wid);
	}
	t_end = sclock::now();

	// Frame lente (> 25 ms) : détail du coût, throttlé à 1 ligne/s pour ne
	// pas noyer le log (un worker bloqué à 8 img/s = ~8 lignes par seconde
	// sans throttle).
	double d_read = std::chrono::duration<double, std::milli>(t_sw - t_mm).count();
	double d_upload = std::chrono::duration<double, std::milli>(t_up - t_sw).count();
	double d_enc = std::chrono::duration<double, std::milli>(t_end - t_up).count();
	if (d_read + d_upload + d_enc > 25.0) {
		static auto last_slow = sclock::time_point{};
		if (sclock::now() - last_slow >= std::chrono::seconds(1)) {
			last_slow = sclock::now();
			UtilityFunctions::print("waylandgodot: [video] frame lente: total ",
				String::num(d_read + d_upload + d_enc, 1), " ms (lecture+conv ",
				String::num(d_read, 1), " ms, upload ", String::num(d_upload, 1),
				" ms, encode ", String::num(d_enc, 1), " ms) ", w->content_w, "x",
				w->content_h, " hw=", hw_mode ? "1" : "0");
		}
	}
}

// ---------------------------------------------------------------------------
// VAAPI
// ---------------------------------------------------------------------------

bool VideoShare::va_init() {
	// Vérifie que l'encodeur matériel existe AVANT d'ouvrir le display.
	const char *probe_name = hw_av1 ? "av1_vaapi" : "h264_vaapi";
	if (!avcodec_find_encoder_by_name(probe_name)) {
		UtilityFunctions::print("waylandgodot: video_share: encodeur ", probe_name, " absent — backend logiciel");
		return false;
	}

	// Ouvre un render node DRM (pas de X11/Wayland ici : le jeu EST le
	// compositeur). Le display doit être initialisé une fois ; le fd est
	// gardé ouvert jusqu'à va_cleanup.
	for (int minor = 128; minor <= 129; minor++) {
		char path[64];
		snprintf(path, sizeof(path), "/dev/dri/renderD%d", minor);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0) continue;
		VADisplay dpy = vaGetDisplayDRM(fd);
		if (!dpy) {
			close(fd);
			continue;
		}
		int maj = 0, min = 0;
		if (vaInitialize(dpy, &maj, &min) != VA_STATUS_SUCCESS) {
			close(fd);
			continue;
		}
		va_display = dpy;
		va_drm_fd = fd;
		UtilityFunctions::print("waylandgodot: video_share: VAAPI display ouvert sur ", path,
			" (v", maj, ".", min, ")");
		break;
	}
	if (!va_display) {
		UtilityFunctions::print("waylandgodot: video_share: aucun render node VAAPI — backend logiciel");
		return false;
	}

	// Construit le hwdevice FFmpeg sur notre display.
	AVBufferRef *ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VAAPI);
	if (!ref) {
		va_cleanup();
		return false;
	}
	AVHWDeviceContext *hwdev = (AVHWDeviceContext *)ref->data;
	AVVAAPIDeviceContext *va = (AVVAAPIDeviceContext *)hwdev->hwctx;
	va->display = va_display;
	if (av_hwdevice_ctx_init(ref) < 0) {
		UtilityFunctions::printerr("waylandgodot: video_share: av_hwdevice_ctx_init a échoué — backend logiciel");
		av_buffer_unref(&ref);
		va_cleanup();
		return false;
	}
	hw_device_ctx = ref;
	return true;
}

void VideoShare::va_cleanup() {
	if (hw_device_ctx) {
		av_buffer_unref((AVBufferRef **)&hw_device_ctx);
		hw_device_ctx = nullptr;
	}
	if (va_display) {
		vaTerminate((VADisplay)va_display);
		va_display = nullptr;
	}
	if (va_drm_fd >= 0) {
		close(va_drm_fd);
		va_drm_fd = -1;
	}
}

// ---------------------------------------------------------------------------
// Décodeur (récepteur)
// ---------------------------------------------------------------------------

void VideoShare::decoder_configure(const std::string &key, const String &codec, int width, int height) {
	std::lock_guard<std::mutex> g(dec_mutex);
	auto it = decoders.find(key);
	if (it != decoders.end()) {
		decoder_destroy(it->second);
		delete it->second;
		decoders.erase(it);
	}

	AVCodecID cid = (codec == "av1") ? AV_CODEC_ID_AV1 : AV_CODEC_ID_H264;
	const AVCodec *cd = avcodec_find_decoder(cid);
	if (!cd) return;

	auto *d = new DecoderCtx();
	d->avctx = avcodec_alloc_context3(cd);
	d->frame = av_frame_alloc();
	d->pkt = av_packet_alloc();
	d->width = width;
	d->height = height;
	if (!d->avctx || !d->frame || !d->pkt ||
		avcodec_open2(d->avctx, cd, nullptr) < 0) {
		decoder_destroy(d);
		delete d;
		return;
	}
	decoders[key] = d;
}

Ref<Image> VideoShare::decoder_feed(const std::string &key, const PackedByteArray &data, bool keyframe) {
	(void)keyframe; // l'IDR est un point de resynchronisation naturel, pas de flush
	std::lock_guard<std::mutex> g(dec_mutex);
	auto it = decoders.find(key);
	if (it == decoders.end() || !it->second->avctx) return Ref<Image>();
	DecoderCtx *d = it->second;
	if (data.size() <= 0) return Ref<Image>();

	// Pas d'avcodec_flush_buffers() sur un IDR : le contexte de décodage est
	// propre à chaque flux (clé (from,wid), recréé à la config) et l'IDR est
	// déjà un point de resynchronisation. Un flush détruirait l'état SPS/PPS
	// déjà parsé : le paquet suivant (P-frame, ou IDR sans SPS/PPS en bande,
	// typique de h264_vaapi) échouerait → boucle de demandes de keyframe
	// (peu de frames appliquées + latence + risque de décodage d'état dégradé).

	// Paquet refcounté avec padding (AV_INPUT_BUFFER_PADDING_SIZE) : les
	// lecteurs de bitstream h264 lisent jusqu'à 8 octets au-delà de la fin du
	// buffer. Un packet pointant sur la mémoire Godot (data.ptr(), sans
	// padding) est fragile ; on copie dans un buffer av_packet correctement
	// dimensionné. Le décodeur ne garde alors aucune référence vers `data`.
	av_packet_unref(d->pkt);
	if (av_new_packet(d->pkt, (int)data.size()) < 0) {
		return Ref<Image>();
	}
	memcpy(d->pkt->data, data.ptr(), (size_t)data.size());
	int ret = avcodec_send_packet(d->avctx, d->pkt);
	av_packet_unref(d->pkt);
	if (ret < 0 && ret != AVERROR(EAGAIN)) {
		diag_decode_error("send", ret);
		return Ref<Image>();
	}
	int r = avcodec_receive_frame(d->avctx, d->frame);
	if (r == 0) {
		Ref<Image> img = decode_to_image(d);
		av_frame_unref(d->frame);
		return img;
	}
	if (r != AVERROR(EAGAIN)) {
		diag_decode_error("recv", r);
	}
	return Ref<Image>();
}

void VideoShare::diag_decode_error(const char *stage, int err) {
	// Appelé sous dec_mutex : les compteurs et l'horodatage sont sûrs.
	using sclock = std::chrono::steady_clock;
	if (strcmp(stage, "send") == 0) {
		diag_send_err++;
	} else {
		diag_recv_err++;
	}
	auto now = sclock::now();
	uint64_t now_ms = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
		now.time_since_epoch()).count();
	if (now_ms - diag_last_err_ms < 1000) return;
	diag_last_err_ms = now_ms;
	char eb[AV_ERROR_MAX_STRING_SIZE] = {0};
	av_strerror(err, eb, sizeof(eb));
	printf("[video] decode_%s erreur=%d (%s) | cumul send=%u recv=%u\n",
		stage, err, eb, diag_send_err, diag_recv_err);
}

Ref<Image> VideoShare::decode_to_image(DecoderCtx *d) {
	int w = d->frame->width;
	int h = d->frame->height;
	if (w <= 0 || h <= 0) return Ref<Image>();

	AVPixelFormat src_fmt = (AVPixelFormat)d->frame->format;
	if (!d->sws || d->width != w || d->height != h || d->sws_fmt != (int)src_fmt) {
		if (d->sws) sws_freeContext(d->sws);
		d->sws = sws_getContext(w, h, src_fmt, w, h, AV_PIX_FMT_RGBA,
			SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
		d->width = w;
		d->height = h;
		d->sws_fmt = (int)src_fmt;
	}
	if (!d->sws) return Ref<Image>();

	PackedByteArray pba;
	pba.resize((int64_t)w * h * 4);
	uint8_t *dst = pba.ptrw();
	// Source = frame décodée (plans YUV), destination = buffer RGBA.
	const uint8_t *slines[4] = { d->frame->data[0], d->frame->data[1],
		d->frame->data[2], d->frame->data[3] };
	const int sls[4] = { d->frame->linesize[0], d->frame->linesize[1],
		d->frame->linesize[2], d->frame->linesize[3] };
	uint8_t *dlines[4] = { dst, nullptr, nullptr, nullptr };
	const int dls[4] = { w * 4, 0, 0, 0 };
	sws_scale(d->sws, slines, sls, 0, h, dlines, dls);
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, pba);
}

void VideoShare::decoder_reset(const std::string &key) {
	std::lock_guard<std::mutex> g(dec_mutex);
	auto it = decoders.find(key);
	if (it == decoders.end()) return;
	decoder_destroy(it->second);
	delete it->second;
	decoders.erase(it);
}

void VideoShare::decoder_clear_all() {
	std::lock_guard<std::mutex> g(dec_mutex);
	for (auto &kv : decoders) {
		decoder_destroy(kv.second);
		delete kv.second;
	}
	decoders.clear();
}

void VideoShare::decoder_destroy(DecoderCtx *d) {
	if (d->avctx) {
		avcodec_free_context(&d->avctx);
		d->avctx = nullptr;
	}
	if (d->sws) {
		sws_freeContext(d->sws);
		d->sws = nullptr;
	}
	if (d->frame) {
		av_frame_free(&d->frame);
		d->frame = nullptr;
	}
	if (d->pkt) {
		av_packet_free(&d->pkt);
		d->pkt = nullptr;
	}
}
