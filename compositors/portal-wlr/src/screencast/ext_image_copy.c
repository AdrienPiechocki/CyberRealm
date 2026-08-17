#include "wlr_screencast.h"

#include "linux-dmabuf-unstable-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"
#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <assert.h>
#include <wayland-client-protocol.h>
#include <xf86drm.h>
#include <sys/types.h>

#include "ext_image_copy.h"
#include "screencast.h"
#include "pipewire_screencast.h"
#include "xdpw.h"
#include "logger.h"

static void ext_session_buffer_size(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1,
		uint32_t width, uint32_t height) {
	struct xdpw_screencast_instance *cast = data;

	cast->pending_constraints.width = width;
	cast->pending_constraints.height = height;
	cast->pending_constraints.dirty = true;
}

static void ext_session_shm_format(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1,
		uint32_t format) {
	struct xdpw_screencast_instance *cast = data;

	uint32_t fourcc = xdpw_format_drm_fourcc_from_wl_shm(format);

	char *fmt_name = drmGetFormatName(fourcc);
	struct xdpw_shm_format *fmt;
	wl_array_for_each(fmt, &cast->pending_constraints.shm_formats) {
		if (fmt->fourcc == fourcc) {
			logprint(TRACE, "ext: skipping duplicated format: %s (%X)", fmt_name, fourcc);
			goto done;
		}
	}
	if (xdpw_bpp_from_drm_fourcc(fourcc) <= 0) {
		logprint(WARN, "ext: unsupported shm format: %s (%X)", fmt_name, fourcc);
		goto done;
	}

	fmt = wl_array_add(&cast->pending_constraints.shm_formats, sizeof(*fmt));
	if (fmt == NULL) {
		logprint(WARN, "ext: allocation for shm format %s (%X) failed", fmt_name, fourcc);
		goto done;
	}
	fmt->fourcc = fourcc;
	// Stride will be calculated when session_done is received
	fmt->stride = 0;
	cast->pending_constraints.dirty = true;
	logprint(TRACE, "ext: shm_format: %s (%X)", fmt_name, fourcc);

done:
	free(fmt_name);
}

static void ext_session_dmabuf_device(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1,
		struct wl_array *device_arr) {
	struct xdpw_screencast_instance *cast = data;

	dev_t device;
	assert(device_arr->size == sizeof(device));
	memcpy(&cast->pending_constraints.dmabuf_device, device_arr->data, sizeof(device));
	cast->pending_constraints.dirty = true;
	logprint(TRACE, "ext: dmabuf_device handler");
}

static void ext_session_dmabuf_format(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1,
		uint32_t format, struct wl_array *modifiers) {
	struct xdpw_screencast_instance *cast = data;

	char *fmt_name = drmGetFormatName(format);
	uint64_t *modifier;
	wl_array_for_each(modifier, modifiers) {
		struct xdpw_format_modifier_pair *fm_pair;
		bool new = true;
		wl_array_for_each(fm_pair, &cast->pending_constraints.dmabuf_format_modifier_pairs) {
			if (fm_pair->fourcc == format && fm_pair->modifier == *modifier) {
				new = false;
				break;
			}
		}
		if (!new) {
			logprint(TRACE, "ext: skipping duplicated format %s (%X, %lu)", fmt_name, format, *modifier);
			continue;
		}

		fm_pair = wl_array_add(&cast->pending_constraints.dmabuf_format_modifier_pairs, sizeof(*fm_pair));
		fm_pair->fourcc = format;
		fm_pair->modifier = *modifier;

		char *modifier_name = drmGetFormatModifierName(*modifier);
		logprint(TRACE, "ext: dmabuf_format handler: %s (%X), modifier: %s (%X)", fmt_name, format, modifier_name, *modifier);
		free(modifier_name);
	}

	cast->pending_constraints.dirty = true;
	free(fmt_name);
}

static void ext_session_done(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1) {
	struct xdpw_screencast_instance *cast = data;

	logprint(INFO, "ext: done handler initialized=%d", cast->initialized);

	// We can only calculate the stride now we have both formats and width
	struct xdpw_shm_format *fmt;
	wl_array_for_each(fmt, &cast->pending_constraints.shm_formats) {
		int bpp = xdpw_bpp_from_drm_fourcc(fmt->fourcc);
		assert(bpp > 0);
		fmt->stride = bpp * cast->pending_constraints.width;
	}

	if (xdpw_buffer_constraints_move(&cast->current_constraints, &cast->pending_constraints)) {
		logprint(DEBUG, "ext: buffer constraints changed");
		xdpw_gbm_device_update(cast);
		pwr_update_stream_param(cast);
		return;
	}

	if (!cast->initialized) {
		return;
	}
}

static void ext_session_stopped(void *data,
		struct ext_image_copy_capture_session_v1 *ext_image_copy_capture_session_v1) {
	struct xdpw_screencast_instance *cast = data;

	logprint(INFO, "ext: session_stopped (target_type=%d, initialized=%d)",
		cast->target ? cast->target->type : 0, cast->initialized);
	xdpw_screencast_instance_destroy(cast);
	logprint(TRACE, "ext: session_stopped handler");
}

static const struct ext_image_copy_capture_session_v1_listener ext_session_listener = {
	.buffer_size = ext_session_buffer_size,
	.shm_format = ext_session_shm_format,
	.dmabuf_device = ext_session_dmabuf_device,
	.dmabuf_format = ext_session_dmabuf_format,
	.done = ext_session_done,
	.stopped = ext_session_stopped,
};

static void ext_frame_transform(void *data,
		struct ext_image_copy_capture_frame_v1 *ext_image_copy_capture_frame_v1,
		uint32_t transform) {
	struct xdpw_screencast_instance *cast = data;
	logprint(TRACE, "ext: transform handler %u", transform);
	cast->current_frame.transformation = transform;
}

static void ext_frame_damage(void *data,
		struct ext_image_copy_capture_frame_v1 *ext_image_copy_capture_frame_v1,
		int32_t x, int32_t y, int32_t width, int32_t height) {
	struct xdpw_screencast_instance *cast = data;

	logprint(TRACE, "ext: damage: %"PRId32",%"PRId32"x%"PRId32",%"PRId32, x, y, width, height);

	// Our damage tracking
	struct xdpw_buffer *buffer;
	wl_list_for_each(buffer, &cast->buffer_list, link) {
		struct xdpw_frame_damage *damage = wl_array_add(&buffer->damage, sizeof(*damage));
		*damage = (struct xdpw_frame_damage){ .x = x, .y = y, .width = width, .height = height };
	}

	struct xdpw_frame_damage *damage = wl_array_add(&cast->current_frame.damage, sizeof(*damage));
	*damage = (struct xdpw_frame_damage){ .x = x, .y = y, .width = width, .height = height };
}

static void ext_frame_presentation_time(void *data,
		struct ext_image_copy_capture_frame_v1 *ext_image_copy_capture_frame_v1,
		uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
	struct xdpw_screencast_instance *cast = data;

	cast->current_frame.tv_sec = ((((uint64_t)tv_sec_hi) << 32) | tv_sec_lo);
	cast->current_frame.tv_nsec = tv_nsec;
	logprint(TRACE, "ext: timestamp %"PRIu64":%"PRIu32, cast->current_frame.tv_sec, cast->current_frame.tv_nsec);
}

static void ext_frame_ready(void *data,
		struct ext_image_copy_capture_frame_v1 *ext_image_copy_capture_frame_v1) {
	struct xdpw_screencast_instance *cast = data;

	logprint(TRACE, "ext: ready event handler");

	if (cast->ext_session.frame) {
		ext_image_copy_capture_frame_v1_destroy(cast->ext_session.frame);
		cast->ext_session.frame = NULL;
	}

	struct xdpw_buffer *buffer = cast->current_frame.xdpw_buffer;
	cast->current_frame.completed = true;
	xdpw_pwr_enqueue_buffer(cast);
	if (buffer) {
		// Clear damage for the buffer that was just submitted
		buffer->damage.size = 0;
	}
	cast->current_frame.damage.size = 0;
}

static void ext_frame_failed(void *data,
		struct ext_image_copy_capture_frame_v1 *ext_image_copy_capture_frame_v1,
		uint32_t reason) {
	struct xdpw_screencast_instance *cast = data;

	logprint(ERROR, "ext: FRAME FAILED reason=%u target_type=%d",
		reason, cast->target ? cast->target->type : 0);

	if (cast->ext_session.frame) {
		ext_image_copy_capture_frame_v1_destroy(cast->ext_session.frame);
		cast->ext_session.frame = NULL;
	}

	switch (reason) {
	case EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_UNKNOWN:
		logprint(ERROR, "ext: frame capture failed: unknown reason");
		xdpw_screencast_instance_destroy(cast);
		return;
	case EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS:
		logprint(ERROR, "ext: frame capture failed: buffer constraint mismatch");
		xdpw_pwr_enqueue_buffer(cast);
		return;
	case EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED:
		logprint(INFO, "ext: frame capture failed: capture session stopped");
		xdpw_screencast_instance_destroy(cast);
		return;
	default:
		abort();
	}
}

static const struct ext_image_copy_capture_frame_v1_listener ext_frame_listener = {
	.transform = ext_frame_transform,
	.damage = ext_frame_damage,
	.presentation_time = ext_frame_presentation_time,
	.ready = ext_frame_ready,
	.failed = ext_frame_failed,
};

// ---------------------------------------------------------------------------
// Curseur METADATA : session ext_image_copy_capture_cursor_session + capture
// de l'image du curseur (mode 4 d'OBS). Le compositeur n'inclut pas le curseur
// dans la capture (pas d'option PAINT_CURSORS) ; on le récupère à part et on
// l'envoie via SPA_META_Cursor dans pipewire_screencast.c.
// ---------------------------------------------------------------------------

static void ext_cursor_session_enter(void *data,
		struct ext_image_copy_capture_cursor_session_v1 *session) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->entered = true;
	logprint(TRACE, "ext: cursor entered capture area");
}

static void ext_cursor_session_leave(void *data,
		struct ext_image_copy_capture_cursor_session_v1 *session) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->entered = false;
	cast->cursor->image_valid = false;
	logprint(TRACE, "ext: cursor left capture area");
}

static void ext_cursor_session_position(void *data,
		struct ext_image_copy_capture_cursor_session_v1 *session,
		int32_t x, int32_t y) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->x = x;
	cast->cursor->y = y;
	logprint(TRACE, "ext: cursor position %d,%d", x, y);
}

static void ext_cursor_session_hotspot(void *data,
		struct ext_image_copy_capture_cursor_session_v1 *session,
		int32_t x, int32_t y) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->hotspot_x = x;
	cast->cursor->hotspot_y = y;
	logprint(TRACE, "ext: cursor hotspot %d,%d", x, y);
}

static const struct ext_image_copy_capture_cursor_session_v1_listener ext_cursor_session_listener = {
	.enter = ext_cursor_session_enter,
	.leave = ext_cursor_session_leave,
	.position = ext_cursor_session_position,
	.hotspot = ext_cursor_session_hotspot,
};

static void ext_cursor_image_buffer_size(void *data,
		struct ext_image_copy_capture_session_v1 *session,
		uint32_t width, uint32_t height) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->width = width;
	cast->cursor->height = height;
	logprint(TRACE, "ext: cursor image size %ux%u", width, height);
}

static void ext_cursor_image_shm_format(void *data,
		struct ext_image_copy_capture_session_v1 *session,
		uint32_t format) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	uint32_t fourcc = xdpw_format_drm_fourcc_from_wl_shm(format);
	if (fourcc != DRM_FORMAT_ARGB8888) {
		logprint(WARN, "ext: unsupported cursor image format %X, expected ARGB8888", fourcc);
	}
}

// Alloue le buffer shm qui reçoit les frames de l'image du curseur (image
// xcursor DRM_FORMAT_ARGB8888 = BGRA en mémoire) + le cliché pixels.
static int ext_cursor_shm_alloc(struct xdpw_screencast_instance *cast) {
	struct xdpw_cursor_state *cs = cast->cursor;
	struct xdpw_screencast_context *ctx = cast->ctx;

	if (cs->width == 0 || cs->height == 0) {
		return -1;
	}
	if (cs->buffer_allocated) {
		return 0;
	}

	cs->stride = cs->width * 4;
	cs->size = cs->stride * cs->height;

	char name[] = "/xdpw-cursor-XXXXXX";
	int retries = 100;
	do {
		randname(name + strlen(name) - 6);
		--retries;
		cs->fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
		if (cs->fd >= 0) {
			shm_unlink(name);
			break;
		}
	} while (retries > 0 && errno == EEXIST);
	if (cs->fd < 0) {
		logprint(ERROR, "ext: unable to create anonymous filedescriptor for cursor");
		return -1;
	}
	if (ftruncate(cs->fd, cs->size) < 0) {
		logprint(ERROR, "ext: unable to truncate cursor buffer");
		close(cs->fd);
		cs->fd = -1;
		return -1;
	}
	cs->data = mmap(NULL, cs->size, PROT_READ | PROT_WRITE, MAP_SHARED, cs->fd, 0);
	if (cs->data == MAP_FAILED) {
		logprint(ERROR, "ext: unable to map cursor buffer");
		close(cs->fd);
		cs->fd = -1;
		cs->data = NULL;
		return -1;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(ctx->shm, cs->fd, cs->size);
	cs->buffer = wl_shm_pool_create_buffer(pool, 0, cs->width, cs->height,
			cs->stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	if (cs->buffer == NULL) {
		logprint(ERROR, "ext: unable to create wl_buffer for cursor");
		munmap(cs->data, cs->size);
		close(cs->fd);
		cs->data = NULL;
		cs->fd = -1;
		return -1;
	}

	cs->pixels = malloc(cs->size);
	if (cs->pixels == NULL) {
		wl_buffer_destroy(cs->buffer);
		cs->buffer = NULL;
		munmap(cs->data, cs->size);
		close(cs->fd);
		cs->data = NULL;
		cs->fd = -1;
		return -1;
	}
	memset(cs->pixels, 0, cs->size);

	cs->buffer_allocated = true;
	logprint(DEBUG, "ext: cursor image buffer allocated (%ux%u)", cs->width, cs->height);
	return 0;
}

// Constraintes dmabuf ignorées : l'image du curseur est toujours allouée en
// shm (le compositeur fournit un format shm via buffer_size/shm_format/done).
// Les handlers sont obligatoires sinon libwayland-client avorte le process
// ("listener function for opcode X is NULL") quand le compositeur les envoie.
static void ext_cursor_image_dmabuf_device(void *data,
		struct ext_image_copy_capture_session_v1 *session,
		struct wl_array *device_arr) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	logprint(TRACE, "ext: cursor dmabuf_device handler (ignored, shm only)");
}

static void ext_cursor_image_dmabuf_format(void *data,
		struct ext_image_copy_capture_session_v1 *session,
		uint32_t format, struct wl_array *modifiers) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	logprint(TRACE, "ext: cursor dmabuf_format handler (ignored, shm only)");
}

static void ext_cursor_image_done(void *data,
		struct ext_image_copy_capture_session_v1 *session) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	ext_cursor_shm_alloc(cast);
}

static void ext_cursor_image_stopped(void *data,
		struct ext_image_copy_capture_session_v1 *session) {
	struct xdpw_screencast_instance *cast = data;
	if (!cast->cursor) return;
	cast->cursor->image_valid = false;
	logprint(TRACE, "ext: cursor image capture session stopped");
}

static const struct ext_image_copy_capture_session_v1_listener ext_cursor_image_session_listener = {
	.buffer_size = ext_cursor_image_buffer_size,
	.shm_format = ext_cursor_image_shm_format,
	.dmabuf_device = ext_cursor_image_dmabuf_device,
	.dmabuf_format = ext_cursor_image_dmabuf_format,
	.done = ext_cursor_image_done,
	.stopped = ext_cursor_image_stopped,
};

static void ext_cursor_frame_ready(void *data,
		struct ext_image_copy_capture_frame_v1 *frame) {
	struct xdpw_screencast_instance *cast = data;
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) return;

	if (cs->frame) {
		ext_image_copy_capture_frame_v1_destroy(cs->frame);
		cs->frame = NULL;
	}

	if (cs->buffer_allocated && cs->data && cs->pixels) {
		memcpy(cs->pixels, cs->data, cs->size);
		cs->image_valid = true;
	}
	logprint(TRACE, "ext: cursor image frame ready");
}

static void ext_cursor_frame_failed(void *data,
		struct ext_image_copy_capture_frame_v1 *frame,
		uint32_t reason) {
	struct xdpw_screencast_instance *cast = data;
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) return;

	if (cs->frame) {
		ext_image_copy_capture_frame_v1_destroy(cs->frame);
		cs->frame = NULL;
	}
	cs->image_valid = false;
	logprint(WARN, "ext: cursor image frame failed (reason %u)", reason);
}

// Les événements transform/damage/presentation_time sont émis par le
// compositeur sur TOUT frame servi (wlr_ext_image_copy_capture_frame_v1_ready
// les envoie systématiquement avant ready). Sans handlers, libwayland-client
// avorte le process ("listener function for opcode X is NULL") dès qu'un
// frame de curseur est servi — la capture de l'image du curseur est toute
// petite et toujours copiée en entier, ces infos ne servent à rien ici.
static void ext_cursor_frame_transform(void *data,
		struct ext_image_copy_capture_frame_v1 *frame,
		uint32_t transform) {
	struct xdpw_screencast_instance *cast = data;
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) return;
	logprint(TRACE, "ext: cursor frame transform handler %u", transform);
}

static void ext_cursor_frame_damage(void *data,
		struct ext_image_copy_capture_frame_v1 *frame,
		int32_t x, int32_t y, int32_t width, int32_t height) {
	struct xdpw_screencast_instance *cast = data;
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) return;
	logprint(TRACE, "ext: cursor frame damage %d,%d %dx%d", x, y, width, height);
}

static void ext_cursor_frame_presentation_time(void *data,
		struct ext_image_copy_capture_frame_v1 *frame,
		uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
	struct xdpw_screencast_instance *cast = data;
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) return;
	logprint(TRACE, "ext: cursor frame presentation_time");
}

static const struct ext_image_copy_capture_frame_v1_listener ext_cursor_frame_listener = {
	.transform = ext_cursor_frame_transform,
	.damage = ext_cursor_frame_damage,
	.presentation_time = ext_cursor_frame_presentation_time,
	.ready = ext_cursor_frame_ready,
	.failed = ext_cursor_frame_failed,
};

void xdpw_ext_ic_cursor_frame_capture(struct xdpw_screencast_instance *cast) {
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs || !cs->image_session || !cs->buffer_allocated) {
		return;
	}
	if (cs->frame) {
		return;
	}
	cs->frame = ext_image_copy_capture_session_v1_create_frame(cs->image_session);
	ext_image_copy_capture_frame_v1_add_listener(cs->frame, &ext_cursor_frame_listener, cast);
	ext_image_copy_capture_frame_v1_attach_buffer(cs->frame, cs->buffer);
	ext_image_copy_capture_frame_v1_capture(cs->frame);
	logprint(TRACE, "ext: cursor image frame capture requested");
}

int xdpw_ext_ic_cursor_session_init(struct xdpw_screencast_instance *cast) {
	struct xdpw_screencast_context *ctx = cast->ctx;
	struct xdpw_cursor_state *cs;

	if (ctx->ext_image_copy_capture_manager == NULL
			|| cast->ext_session.source == NULL
			|| ctx->seat == NULL || ctx->pointer == NULL) {
		logprint(INFO, "ext: cursor session: wl_seat/wl_pointer unavailable");
		return -1;
	}

	cs = calloc(1, sizeof(*cs));
	if (cs == NULL) {
		return -1;
	}
	cs->fd = -1;
	cast->cursor = cs;

	cs->cursor_session = ext_image_copy_capture_manager_v1_create_pointer_cursor_session(
			ctx->ext_image_copy_capture_manager, cast->ext_session.source, ctx->pointer);
	ext_image_copy_capture_cursor_session_v1_add_listener(cs->cursor_session,
			&ext_cursor_session_listener, cast);

	cs->image_session = ext_image_copy_capture_cursor_session_v1_get_capture_session(
			cs->cursor_session);
	if (cs->image_session == NULL) {
		// Session curseur inerte (compositeur sans source de curseur pour ce
		// type de source) : sans listener, wl_display_roundtrip() ferait une
		// boucle infinie.
		logprint(INFO, "ext: cursor session inert (no cursor source), disabling cursor");
		xdpw_ext_ic_cursor_session_close(cast);
		return -1;
	}
	ext_image_copy_capture_session_v1_add_listener(cs->image_session,
			&ext_cursor_image_session_listener, cast);
	logprint(DEBUG, "ext: cursor session registered");
	return 0;
}

void xdpw_ext_ic_cursor_session_close(struct xdpw_screencast_instance *cast) {
	struct xdpw_cursor_state *cs = cast->cursor;
	if (!cs) {
		return;
	}
	if (cs->frame) {
		ext_image_copy_capture_frame_v1_destroy(cs->frame);
		cs->frame = NULL;
	}
	if (cs->image_session) {
		ext_image_copy_capture_session_v1_destroy(cs->image_session);
		cs->image_session = NULL;
	}
	if (cs->cursor_session) {
		ext_image_copy_capture_cursor_session_v1_destroy(cs->cursor_session);
		cs->cursor_session = NULL;
	}
	if (cs->buffer) {
		wl_buffer_destroy(cs->buffer);
		cs->buffer = NULL;
	}
	if (cs->data) {
		munmap(cs->data, cs->size);
		cs->data = NULL;
	}
	if (cs->fd >= 0) {
		close(cs->fd);
		cs->fd = -1;
	}
	free(cs->pixels);
	free(cs);
	cast->cursor = NULL;
}

static int ext_register_session_cb(struct xdpw_screencast_instance *cast) {
	struct ext_image_capture_source_v1 *source = NULL;
	logprint(INFO, "ext: register_session target_type=%d with_cursor=%d with_cursor_meta=%d",
		cast->target->type, cast->target->with_cursor, cast->target->with_cursor_meta);
	switch (cast->target->type) {
	case MONITOR:
		if (cast->ctx->ext_output_image_capture_source_manager == NULL) {
			logprint(INFO, "ext: screencast output: unsupported");
			return -1;
		}
		source = ext_output_image_capture_source_manager_v1_create_source(
			cast->ctx->ext_output_image_capture_source_manager,
			cast->target->output->output);
		break;
	case WINDOW:
		if (cast->ctx->ext_foreign_toplevel_image_capture_source_manager == NULL) {
			logprint(INFO, "ext: screencast window: unsupported");
			return -1;
		}
		source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(
			cast->ctx->ext_foreign_toplevel_image_capture_source_manager,
			cast->target->toplevel->handle);
		break;
	}
	assert(source != NULL);
	cast->ext_session.source = source;

	cast->ext_session.capture_session = ext_image_copy_capture_manager_v1_create_session(
			cast->ctx->ext_image_copy_capture_manager, source,
			cast->target->with_cursor ? EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS : 0);
	ext_image_copy_capture_session_v1_add_listener(cast->ext_session.capture_session,
			&ext_session_listener, cast);

	if (cast->target->with_cursor_meta && !cast->cursor) {
		int cret = xdpw_ext_ic_cursor_session_init(cast);
		logprint(INFO, "ext: cursor session init result=%d cursor=%p", cret, (void*)cast->cursor);
	}
	logprint(TRACE, "ext: session callbacks registered");
	return 0;
}

static void ext_register_frame_cb(struct xdpw_screencast_instance *cast) {
	if (!cast->ext_session.capture_session) {
		logprint(INFO, "ext: register_frame_cb: no capture_session, registering session first");
		if (ext_register_session_cb(cast) != 0) {
			logprint(ERROR, "ext: failed to register session");
			return;
		}
	}
	// Détruire un frame éventuel non complété (resté du frame précédent quand
	// le buffer n'était pas encore prêt). Sans cela, create_frame sur la même
	// session provoque "session already has a frame object" → crash Wayland.
	if (cast->ext_session.frame) {
		logprint(INFO, "ext: register_frame_cb: destroying leftover frame before creating new one");
		ext_image_copy_capture_frame_v1_destroy(cast->ext_session.frame);
		cast->ext_session.frame = NULL;
	}
	// Frame curseur demandé AVANT le frame principal : le compositeur le sert
	// en premier, donc image_valid est à jour quand le frame principal devient
	// prêt et que xdpw_pwr_enqueue_buffer écrit le meta curseur.
	xdpw_ext_ic_cursor_frame_capture(cast);
	cast->ext_session.frame = ext_image_copy_capture_session_v1_create_frame(
			cast->ext_session.capture_session);
	ext_image_copy_capture_frame_v1_add_listener(cast->ext_session.frame,
			&ext_frame_listener, cast);

	if (!cast->current_frame.xdpw_buffer) {
		logprint(ERROR, "ext: register_frame_cb: no xdpw_buffer!");
		return;
	}
	ext_image_copy_capture_frame_v1_attach_buffer(cast->ext_session.frame,
			cast->current_frame.xdpw_buffer->buffer);
	struct xdpw_frame_damage *damage;
	wl_array_for_each(damage, &cast->current_frame.xdpw_buffer->damage) {
		ext_image_copy_capture_frame_v1_damage_buffer(
				cast->ext_session.frame, damage->x, damage->y, damage->width, damage->height);
	}
	ext_image_copy_capture_frame_v1_capture(cast->ext_session.frame);

	logprint(TRACE, "ext: frame callbacks registered");
}

void xdpw_ext_ic_frame_capture(struct xdpw_screencast_instance *cast) {
	logprint(TRACE, "ext: start screencopy");
	if (!cast->ext_session.capture_session) {
		logprint(WARN, "ext: frame capture on destroyed session, skipping");
		return;
	}
	if (cast->current_frame.xdpw_buffer == NULL) {
		logprint(ERROR, "ext: started frame without buffer");
		return;
	}

	ext_register_frame_cb(cast);
}

void xdpw_ext_ic_session_close(struct xdpw_screencast_instance *cast) {
	if (cast->ext_session.frame) {
		ext_image_copy_capture_frame_v1_destroy(cast->ext_session.frame);
		cast->ext_session.frame = NULL;
	}
	if (cast->ext_session.capture_session) {
		ext_image_copy_capture_session_v1_destroy(cast->ext_session.capture_session);
		cast->ext_session.capture_session = NULL;
	}
	xdpw_ext_ic_cursor_session_close(cast);
}

int xdpw_ext_ic_session_init(struct xdpw_screencast_instance *cast) {
	if (cast->ctx->ext_image_copy_capture_manager == NULL) {
		logprint(INFO, "ext: unsupported");
		return -1;
	}
	if (ext_register_session_cb(cast) != 0) {
		return -1;
	}

	// process at least one frame so that we know
	// some of the metadata required for the pipewire
	// remote state connected event
	return wl_display_roundtrip(cast->ctx->state->wl_display);
}
