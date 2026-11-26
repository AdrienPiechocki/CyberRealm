// wp_cursor_shape_v1 : curseurs demandés par FORME (« text », « pointer »…).
//
// GTK 4 et Qt ≥ 6.6 préfèrent ce protocole quand il est annoncé : au lieu
// d'attacher une surface curseur (wl_pointer.set_cursor), ils nomment une
// forme. On la convertit en image xcursor (thème du wlr_xcursor_manager) et on
// la range dans le MÊME WindowCursorState que les curseurs-surfaces : le jeu
// interroge get_window_cursor() comme avant (mode focus, overlay KMS, miroir
// du curseur chez les autres joueurs), sans distinguer les deux origines.

#include "wlr_compositor.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdio>
#include <cstdlib>

using namespace godot;

// Même variable que les traces curseur d'input.cpp.
static bool cursor_debug_enabled() {
    const char *e = getenv("CYBERREALM_INPUT_DEBUG");
    return e && e[0] == '1';
}

Ref<Image> WlrCompositor::image_from_argb8888(const uint8_t *src, int w, int h, size_t stride) {
    // ARGB8888 (DRM) = BGRA little-endian, alpha prémultipliée.
    // Conversion en RGBA8 Godot (alpha straight).
    PackedByteArray px;
    px.resize((int64_t)w * h * 4);
    uint8_t *dst = px.ptrw();
    for (int y = 0; y < h; y++) {
        const uint8_t *srow = src + (size_t)y * stride;
        uint8_t *drow = dst + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            uint8_t b = srow[x * 4 + 0];
            uint8_t g = srow[x * 4 + 1];
            uint8_t r = srow[x * 4 + 2];
            uint8_t a = srow[x * 4 + 3];
            if (a == 0) {
                r = g = b = 0;
            } else if (a != 255) {
                r = (uint8_t)(((int)r * 255) / a);
                g = (uint8_t)(((int)g * 255) / a);
                b = (uint8_t)(((int)b * 255) / a);
            }
            drow[x * 4 + 0] = r;
            drow[x * 4 + 1] = g;
            drow[x * 4 + 2] = b;
            drow[x * 4 + 3] = a;
        }
    }
    return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, px);
}

void WlrCompositor::detach_cursor_surface(WindowCursorState &cs) {
    if (cs.surface) {
        wl_list_remove(&cs.commit_listener.link);
        wl_list_remove(&cs.client_commit_listener.link);
        wl_list_remove(&cs.destroy_listener.link);
        wl_list_init(&cs.commit_listener.link);
        wl_list_init(&cs.client_commit_listener.link);
        wl_list_init(&cs.destroy_listener.link);
    }
    cs.surface = nullptr;
}

int WlrCompositor::pointer_focus_window_id() {
    if (!seat || !seat->pointer_state.focused_surface) {
        return -1;
    }
    wlr_surface *root = wlr_surface_get_root_surface(seat->pointer_state.focused_surface);
    return root ? find_window_id_by_surface(root) : -1;
}

void WlrCompositor::on_cursor_shape_request(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, cursor_shape_request_listener);
    auto *event = static_cast<wlr_cursor_shape_manager_v1_request_set_shape_event *>(data);
    bool dbg = cursor_debug_enabled();
    // Pas de tablette graphique dans le jeu : seules les formes du pointeur
    // comptent. Même filtre que wl_pointer.set_cursor : seul le client qui a
    // le focus pointeur peut changer le curseur.
    if (event->device_type != WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER) {
        return;
    }
    if (!self->seat || !event->seat_client
            || event->seat_client != self->seat->pointer_state.focused_client) {
        if (dbg) fprintf(stderr, "waylandgodot: cursor shape ignored (wrong seat client)\n");
        return;
    }
    int window_id = self->pointer_focus_window_id();
    if (window_id == -1) {
        if (dbg) fprintf(stderr, "waylandgodot: cursor shape ignored (no focused window)\n");
        return;
    }
    if (!self->cursor_manager) {
        return;
    }
    const char *name = wlr_cursor_shape_v1_name(event->shape);
    if (!name) {
        name = "default";
    }
    WindowCursorState &cs = self->window_cursor[window_id];
    cs.window_id = window_id;
    cs.owner = self;
    // Même forme que la dernière fois, toujours affichée : rien à refaire
    // (GTK renvoie la forme à chaque entrée du pointeur dans un widget).
    if (!cs.surface && !cs.hidden && cs.shape_name == name && cs.image.is_valid()) {
        return;
    }
    wlr_xcursor *xcursor = wlr_xcursor_manager_get_xcursor(self->cursor_manager, name, 1.0f);
    if (!xcursor) {
        // Thème sans cette forme (thèmes anciens : noms X11 seulement) :
        // la flèche plutôt que rien.
        xcursor = wlr_xcursor_manager_get_xcursor(self->cursor_manager, "default", 1.0f);
    }
    if (!xcursor || xcursor->image_count == 0 || !xcursor->images[0]) {
        if (dbg) fprintf(stderr, "waylandgodot: cursor shape %s: no xcursor image\n", name);
        return;
    }
    wlr_xcursor_image *img = xcursor->images[0];
    if (img->width == 0 || img->height == 0 || !img->buffer) {
        return;
    }
    detach_cursor_surface(cs);
    cs.hidden = false;
    cs.shape_name = name;
    cs.image = image_from_argb8888(img->buffer, (int)img->width, (int)img->height,
        (size_t)img->width * 4);
    cs.hotspot_x = (int32_t)img->hotspot_x;
    cs.hotspot_y = (int32_t)img->hotspot_y;
    cs.serial++;
    if (dbg) {
        fprintf(stderr, "waylandgodot: cursor shape window=%d shape=%s %ux%u serial=%llu\n",
            window_id, name, img->width, img->height, (unsigned long long)cs.serial);
    }
}
