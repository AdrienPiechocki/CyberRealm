#include "wlr_compositor.h"
#include "ext-image-capture-source-v1-protocol.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <chrono>
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <thread>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <poll.h>
#include <linux/dma-buf.h>

extern "C" {
#include <wlr/types/wlr_buffer.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/interfaces/wlr_ext_image_capture_source_v1.h>
#include <wlr/util/log.h>
#include <wlr/util/box.h>
#include <libdrm/drm_fourcc.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_output.h>
}

using namespace godot;

void WlrCompositor::toplevel_source_start(wlr_ext_image_capture_source_v1 *base, bool with_cursors) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    source->num_started++;
    // with_cursors == PAINT_CURSORS demandé par la session (case « afficher
    // le curseur » d'OBS) : mémorisé pour composer le curseur dans la
    // capture de fenêtre, comme le fait la source output via
    // wlr_output_lock_software_cursors pour la capture écran.
    source->with_cursors = with_cursors;
}
void WlrCompositor::toplevel_source_stop(wlr_ext_image_capture_source_v1 *base) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    if (source->num_started > 0) {
        source->num_started--;
    }
}
void WlrCompositor::toplevel_source_schedule_frame(wlr_ext_image_capture_source_v1 *base) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    source->needs_frame = true;
}
void WlrCompositor::toplevel_source_copy_frame(wlr_ext_image_capture_source_v1 *base,
        wlr_ext_image_copy_capture_frame_v1 *frame,
        wlr_ext_image_capture_source_v1_frame_event *event) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    WindowState *ws = source->window;
    // Le buffer exact-size contient le dernier rendu de la fenêtre (recopié
    // depuis offscreen dans _process à chaque frame) ; copie GPU→buffer
    // client par wlroots. On ne peut pas passer capture_cache.offscreen
    // directement : il est pad'dé à 64px alors que copy_buffer exige des
    // tailles identiques (BUFFER_CONSTRAINTS sinon).
    if (!ws || !source->capture_buffer) {
        UtilityFunctions::printerr("waylandgodot: toplevel_source_copy_frame FAIL: ws=",
            (intptr_t)ws, " capture_buffer=", (intptr_t)source->capture_buffer);
        wlr_ext_image_copy_capture_frame_v1_fail(frame,
            EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
        return;
    }
    if (!wlr_ext_image_copy_capture_frame_v1_copy_buffer(frame,
            source->capture_buffer, source->compositor->renderer)) {
        return;
    }
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_ext_image_copy_capture_frame_v1_ready(frame, WL_OUTPUT_TRANSFORM_NORMAL, &now);
}
static const wlr_ext_image_capture_source_v1_interface toplevel_cursor_impl = {
    .start = WlrCompositor::toplevel_cursor_start,
    .stop = WlrCompositor::toplevel_cursor_stop,
    .schedule_frame = WlrCompositor::toplevel_cursor_schedule_frame,
    .copy_frame = WlrCompositor::toplevel_cursor_copy_frame,
};
wlr_ext_image_capture_source_v1_cursor *WlrCompositor::toplevel_source_get_pointer_cursor(
        wlr_ext_image_capture_source_v1 *base, wlr_seat *seat) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    WlrCompositorToplevelSource::ToplevelCursorSource &tc = source->cursor;
    WlrCompositor *compositor = source->compositor;
    (void)seat;
    if (!tc.initialized) {
        wlr_ext_image_capture_source_v1_cursor_init(&tc.base, &toplevel_cursor_impl);
        tc.initialized = true;
        // Contraintes (taille + formats shm) fixées depuis l'image xcursor
        // courante : portal-wlr les lit à la création de sa session curseur
        // (session_send_constraints) pour allouer un buffer de frame adapté.
        // L'image xcursor est chargée à l'init du compositeur, donc déjà
        // disponible ici. dmabuf_formats laissé vide : portal-wlr allouera
        // un buffer shm, copié via copy_shm par wlroots.
        if (compositor && compositor->ensure_cursor_image_buffer()) {
            tc.base.base.width = (uint32_t)compositor->cursor_image_width;
            tc.base.base.height = (uint32_t)compositor->cursor_image_height;
            tc.base.base.shm_formats_len = 1;
            tc.base.base.shm_formats = (uint32_t *)malloc(sizeof(uint32_t));
            if (tc.base.base.shm_formats) {
                tc.base.base.shm_formats[0] = DRM_FORMAT_ARGB8888;
            } else {
                tc.base.base.shm_formats_len = 0;
            }
        }
    }
    return &tc.base;
}
void WlrCompositor::toplevel_cursor_start(wlr_ext_image_capture_source_v1 *base,
        bool with_cursors) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, cursor.base.base);
    (void)with_cursors; // METADATA : le curseur n'est jamais composité dans la capture
    source->cursor.num_started++;
}
void WlrCompositor::toplevel_cursor_stop(wlr_ext_image_capture_source_v1 *base) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, cursor.base.base);
    if (source->cursor.num_started > 0) {
        source->cursor.num_started--;
    }
}
void WlrCompositor::toplevel_cursor_schedule_frame(wlr_ext_image_capture_source_v1 *base) {
    // Le pilote _process émet déjà un frame event à chaque frame tant qu'au
    // moins une session curseur est active : rien à faire ici.
    (void)base;
}
void WlrCompositor::toplevel_cursor_copy_frame(wlr_ext_image_capture_source_v1 *base,
        wlr_ext_image_copy_capture_frame_v1 *frame,
        wlr_ext_image_capture_source_v1_frame_event *event) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, cursor.base.base);
    (void)event;
    wlr_buffer *image = source->compositor ? source->compositor->cursor_image_buffer : nullptr;
    if (image) {
        if (wlr_ext_image_copy_capture_frame_v1_copy_buffer(frame, image,
                source->compositor->renderer)) {
            timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            wlr_ext_image_copy_capture_frame_v1_ready(frame, WL_OUTPUT_TRANSFORM_NORMAL, &now);
            return;
        }
    }
    wlr_ext_image_copy_capture_frame_v1_fail(frame,
        EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
}
static const wlr_ext_image_capture_source_v1_interface toplevel_source_impl = {
    .start = WlrCompositor::toplevel_source_start,
    .stop = WlrCompositor::toplevel_source_stop,
    .schedule_frame = WlrCompositor::toplevel_source_schedule_frame,
    .copy_frame = WlrCompositor::toplevel_source_copy_frame,
    .get_pointer_cursor = WlrCompositor::toplevel_source_get_pointer_cursor,
};
static const struct ext_foreign_toplevel_image_capture_source_manager_v1_interface foreign_toplevel_source_manager_impl = {
    .create_source = WlrCompositor::on_foreign_toplevel_source_manager_create_source,
    .destroy = WlrCompositor::on_foreign_toplevel_source_manager_destroy,
};
void WlrCompositor::on_foreign_toplevel_source_manager_bind(wl_client *client,
        void *data, uint32_t version, uint32_t id) {
    WlrCompositor *self = static_cast<WlrCompositor *>(data);
    wl_resource *resource = wl_resource_create(client,
        &ext_foreign_toplevel_image_capture_source_manager_v1_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &foreign_toplevel_source_manager_impl, self, nullptr);
}
void WlrCompositor::on_foreign_toplevel_source_manager_create_source(wl_client *client,
        wl_resource *resource, uint32_t source, wl_resource *toplevel_handle) {
    WlrCompositor *self = static_cast<WlrCompositor *>(wl_resource_get_user_data(resource));

    wlr_ext_foreign_toplevel_handle_v1 *handle = nullptr;
    if (toplevel_handle) {
        handle = wlr_ext_foreign_toplevel_handle_v1_from_resource(toplevel_handle);
    }
    WindowState *ws = nullptr;
    if (handle) {
        ws = static_cast<WindowState *>(handle->data);
    }
    if (!ws || !self->foreign_toplevel_list) {
        // Source inerte : pas de capture possible (fenêtre déjà fermée ou
        // handle inconnu). Le client recevra "stopped" dès qu'il essaiera.
        wlr_ext_image_capture_source_v1_create_resource(nullptr, client, source);
        return;
    }

    if (!ws->image_source) {
        auto *src = new WlrCompositorToplevelSource();
        src->compositor = self;
        src->window = ws;
        wlr_ext_image_capture_source_v1_init(&src->base, &toplevel_source_impl);
        ws->image_source = src;
        self->update_toplevel_source_constraints(src);
    }
    wlr_ext_image_capture_source_v1_create_resource(&ws->image_source->base, client, source);
}
void WlrCompositor::on_foreign_toplevel_source_manager_destroy(wl_client *client,
        wl_resource *resource) {
    wl_resource_destroy(resource);
}
void WlrCompositor::update_toplevel_source_constraints(WlrCompositorToplevelSource *source) {
    WindowState *ws = source->window;
    if (!ws || !renderer || !allocator) return;
    if (ws->width <= 0 || ws->height <= 0) return;

    // Le buffer de capture exact-size (w×h) : recopié depuis offscreen dans
    // _process, et c'est lui que copy_frame fournit à wlroots (tailles
    // identiques exigées par wlr_ext_image_copy_capture_frame_v1_copy_buffer).
    // Même format linéaire que le buffer offscreen des fenêtres (le renderer
    // peut le cibler via begin_buffer_pass, en GPU comme en fallback pixman).
    if (!source->capture_buffer ||
            source->capture_buffer->width != ws->width ||
            source->capture_buffer->height != ws->height) {
        if (source->capture_buffer) {
            wlr_buffer_drop(source->capture_buffer);
            source->capture_buffer = nullptr;
        }
        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
        if (formats) {
            static const uint32_t preferred[] = {
                DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888,
                DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888,
            };
            for (uint32_t f : preferred) {
                const wlr_drm_format *fmt = wlr_drm_format_set_get(formats, f);
                if (!fmt) continue;
                uint64_t linear_mod = DRM_FORMAT_MOD_LINEAR;
                struct wlr_drm_format linear_fmt = {};
                linear_fmt.format = f;
                linear_fmt.modifiers = &linear_mod;
                linear_fmt.len = 1;
                wlr_buffer *buf = wlr_allocator_create_buffer(
                    allocator, ws->width, ws->height, &linear_fmt);
                if (buf) {
                    source->capture_buffer = buf;
                    break;
                }
            }
        }
    }

    // Les contraintes annoncées à portal-wlr (tailles/formats/dmabuf device)
    // sont extraites d'un swapchain temporaire, comme le fait wlroots pour
    // les sources output. Le swapchain est détruit juste après : wlroots en
    // copie les formats et la largeur/hauteur.
    const wlr_drm_format_set *formats = wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
    const wlr_drm_format *fmt = formats ? wlr_drm_format_set_get(formats, DRM_FORMAT_XRGB8888) : nullptr;
    if (!fmt) return;

    wlr_swapchain *swapchain = wlr_swapchain_create(allocator, ws->width, ws->height, fmt);
    if (!swapchain) return;
    wlr_ext_image_capture_source_v1_set_constraints_from_swapchain(
        &source->base, swapchain, renderer);
    wlr_swapchain_destroy(swapchain);
}
void WlrCompositor::blit_toplevel_capture(WlrCompositorToplevelSource *source) {
    WindowState *ws = source->window;
    if (!ws || !source->capture_buffer || !ws->capture_cache.offscreen) return;
    if (!renderer) return;
    if (source->capture_buffer->width != ws->width ||
            source->capture_buffer->height != ws->height) {
        update_toplevel_source_constraints(source);
        // update_toplevel_source_constraints peut libérer capture_buffer (drop)
        // sans réussir à en allouer un neuf (formats indisponibles, échec
        // d'allocation) : ne pas passer un buffer NULL à begin_buffer_pass.
        if (!source->capture_buffer) return;
    }

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(
        renderer, source->capture_buffer, nullptr);
    if (!pass) return;

    wlr_render_rect_options clear = {};
    clear.box.x = 0;
    clear.box.y = 0;
    clear.box.width = source->capture_buffer->width;
    clear.box.height = source->capture_buffer->height;
    clear.color = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    wlr_render_pass_add_rect(pass, &clear);

    wlr_texture *tex = wlr_texture_from_buffer(renderer, ws->capture_cache.offscreen);
    if (tex) {
        wlr_render_texture_options opts = {};
        opts.texture = tex;
        opts.dst_box.x = 0;
        opts.dst_box.y = 0;
        opts.dst_box.width = ws->width;
        opts.dst_box.height = ws->height;
        opts.src_box.x = 0;
        opts.src_box.y = 0;
        opts.src_box.width = ws->width;
        opts.src_box.height = ws->height;
        opts.transform = WL_OUTPUT_TRANSFORM_NORMAL;
        opts.filter_mode = WLR_SCALE_FILTER_NEAREST;
        wlr_render_pass_add_texture(pass, &opts);
        wlr_texture_destroy(tex);
    }

    // Curseur dans la capture de fenêtre : composé uniquement si la session
    // l'a demandé (PAINT_CURSORS — case « afficher le curseur » d'OBS),
    // comme la source output le fait via wlr_output_lock_software_cursors
    // pour la capture écran. Positionné à la position du pointeur du jeu
    // dans la fenêtre (coordonnées surface, y vers le bas), fournie par le
    // script Godot via set_window_pointer. Masqué si le jeu est en mode
    // caméra (cursor_visible = false) — cohérent avec la capture écran.
    if (source->with_cursors && cursor_manager && cursor && cursor_visible
            && ws->pointer_inside) {
        struct wlr_xcursor *xcursor = wlr_xcursor_manager_get_xcursor(
            cursor_manager, "default", 1.0f);
        if (xcursor && xcursor->image_count > 0) {
            int frame = wlr_xcursor_frame(xcursor, 0);
            if (frame >= 0 && frame < (int)xcursor->image_count) {
                struct wlr_xcursor_image *img = xcursor->images[frame];
                if (img && img->buffer) {
                    // L'image xcursor est en DRM_FORMAT_ARGB8888 non
                    // pré-multiplié ; le blend par défaut
                    // (WLR_RENDER_BLEND_MODE_PREMULTIPLIED) est le même que
                    // celui utilisé par wlroots pour dessiner ses propres
                    // curseurs logiciels.
                    wlr_texture *curtex = wlr_texture_from_pixels(renderer,
                        DRM_FORMAT_ARGB8888, (uint32_t)((size_t)img->width * 4),
                        (uint32_t)img->width, (uint32_t)img->height, img->buffer);
                    if (curtex) {
                        wlr_render_texture_options copts = {};
                        copts.texture = curtex;
                        copts.dst_box.x = (int)ws->pointer_x - (int)img->hotspot_x;
                        copts.dst_box.y = (int)ws->pointer_y - (int)img->hotspot_y;
                        copts.dst_box.width = img->width;
                        copts.dst_box.height = img->height;
                        copts.transform = WL_OUTPUT_TRANSFORM_NORMAL;
                        copts.filter_mode = WLR_SCALE_FILTER_NEAREST;
                        wlr_render_pass_add_texture(pass, &copts);
                        wlr_texture_destroy(curtex);
                    }
                }
            }
        }
    }
    wlr_render_pass_submit(pass);
}
void WlrCompositor::update_toplevel_cursor(WlrCompositorToplevelSource *source) {
    WlrCompositorToplevelSource::ToplevelCursorSource &tc = source->cursor;
    if (!tc.initialized) return;
    WindowState *ws = source->window;
    if (!ws || !ws->toplevel || !ws->toplevel->base) return;

    // Image du curseur : buffer shm partagé avec l'output cursor. Une fois
    // disponible, les sessions curseur peuvent être servies en frames.
    if (ensure_cursor_image_buffer()) {
        tc.image_ready = true;
    }

    bool entered = cursor_visible && ws->pointer_inside;
    int x = 0;
    int y = 0;
    if (entered) {
        wlr_box geo = ws->toplevel->base->current.geometry;
        x = (int)ws->pointer_x - geo.x;
        y = (int)ws->pointer_y - geo.y;
    }

    if (entered != tc.base.entered || x != tc.base.x || y != tc.base.y ||
            cursor_image_hotspot_x != tc.base.hotspot.x ||
            cursor_image_hotspot_y != tc.base.hotspot.y) {
        tc.base.entered = entered;
        tc.base.x = x;
        tc.base.y = y;
        tc.base.hotspot.x = cursor_image_hotspot_x;
        tc.base.hotspot.y = cursor_image_hotspot_y;
        wl_signal_emit_mutable(&tc.base.events.update, NULL);
    }

    // Réarme le damage de la session curseur à chaque frame tant qu'au moins
    // une session est active (même mécanisme que la capture fenêtre :
    // ready() vide le damage de session, sans réémission le prochain capture
    // de portal-wlr ne serait jamais servi).
    if (tc.num_started > 0 && tc.image_ready && cursor_image_width > 0 &&
            cursor_image_height > 0) {
        pixman_region32_t damage;
        pixman_region32_init_rect(&damage, 0, 0,
            cursor_image_width, cursor_image_height);
        wlr_ext_image_capture_source_v1_frame_event event = { .damage = &damage };
        wl_signal_emit_mutable(&tc.base.base.events.frame, &event);
        pixman_region32_fini(&damage);
    }
}
void WlrCompositor::destroy_toplevel_image_source(WlrCompositorToplevelSource *source) {
    if (!source) return;
    WindowState *ws = source->window;
    if (ws && ws->image_source == source) {
        ws->image_source = nullptr;
    }
    if (source->cursor.initialized) {
        // La fin (events.destroy) détruit les sessions curseur attachées
        // (leurs listeners update/frame sont retirés dans session_destroy),
        // ce qui satisfait les asserts de wlr_ext_image_capture_source_v1_
        // cursor_finish.
        wlr_ext_image_capture_source_v1_cursor_finish(&source->cursor.base);
        source->cursor.initialized = false;
    }
    if (source->capture_buffer) {
        wlr_buffer_drop(source->capture_buffer);
        source->capture_buffer = nullptr;
    }
    wlr_ext_image_capture_source_v1_finish(&source->base);
    delete source;
}
