#include "wlr_compositor.h"
#include "wlr_layer_shell_helpers.h"

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

static void layer_apply_exclusive(wlr_box *usable_area, uint32_t anchor, int32_t exclusive,
        int32_t margin_top, int32_t margin_right, int32_t margin_bottom, int32_t margin_left) {
    if (exclusive <= 0) return;

    const uint32_t T = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
    const uint32_t B = ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
    const uint32_t L = ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
    const uint32_t R = ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

    switch (anchor) {
    case T:
    case (T | L | R):
        usable_area->y += exclusive + margin_top;
        usable_area->height -= exclusive + margin_top;
        break;
    case B:
    case (B | L | R):
        usable_area->height -= exclusive + margin_bottom;
        break;
    case L:
    case (T | B | L):
        usable_area->x += exclusive + margin_left;
        usable_area->width -= exclusive + margin_left;
        break;
    case R:
    case (T | B | R):
        usable_area->width -= exclusive + margin_right;
        break;
    }

    if (usable_area->width < 0) usable_area->width = 0;
    if (usable_area->height < 0) usable_area->height = 0;
}
static wlr_box layer_surface_box(const wlr_layer_surface_v1_state &state, const wlr_box &bounds) {
    const uint32_t T = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
    const uint32_t B = ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
    const uint32_t L = ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
    const uint32_t R = ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

    wlr_box box = {};
    box.width = state.desired_width;
    box.height = state.desired_height;

    // Axe horizontal: desired_width == 0 => étire sur toute la zone (les
    // ancres gauche+droite sont alors obligatoires côté client), sinon une
    // ou deux ancres positionnent/centrent la boîte.
    if (box.width == 0) {
        box.x = bounds.x + state.margin.left;
        box.width = bounds.width - (state.margin.left + state.margin.right);
    } else if ((state.anchor & (L | R)) == (L | R)) {
        box.x = bounds.x + bounds.width / 2 - box.width / 2;
    } else if (state.anchor & L) {
        box.x = bounds.x + state.margin.left;
    } else if (state.anchor & R) {
        box.x = bounds.x + bounds.width - box.width - state.margin.right;
    } else {
        box.x = bounds.x + bounds.width / 2 - box.width / 2;
    }
    if (box.width < 0) box.width = 0;

    // Axe vertical: même logique.
    if (box.height == 0) {
        box.y = bounds.y + state.margin.top;
        box.height = bounds.height - (state.margin.top + state.margin.bottom);
    } else if ((state.anchor & (T | B)) == (T | B)) {
        box.y = bounds.y + bounds.height / 2 - box.height / 2;
    } else if (state.anchor & T) {
        box.y = bounds.y + state.margin.top;
    } else if (state.anchor & B) {
        box.y = bounds.y + bounds.height - box.height - state.margin.bottom;
    } else {
        box.y = bounds.y + bounds.height / 2 - box.height / 2;
    }
    if (box.height < 0) box.height = 0;

    return box;
}
void WlrCompositor::arrange_layer_surfaces() {
    if (!layer_shell) return;

    static const uint32_t layer_order[] = {
        ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
    };

    wlr_box usable = {0, 0, output_width, output_height};
    wlr_box full_area = usable;

    // Deux passes: les surfaces avec exclusive_zone > 0 d'abord (elles
    // réduisent le usable area), puis les autres. Chaque couche est
    // parcourue de la plus haute à la plus basse, comme dans sway.
    for (int pass = 0; pass < 2; pass++) {
        bool exclusive_pass = (pass == 0);
        for (uint32_t layer : layer_order) {
            for (auto &pair : layer_surfaces) {
                LayerSurfaceState &ls = pair.second;
                wlr_layer_surface_v1 *lsrf = ls.layer_surface;
                if (!lsrf || !lsrf->initialized) continue;

                wlr_layer_surface_v1_state &state = lsrf->current;
                if ((int)state.layer != (int)layer) continue;
                if ((state.exclusive_zone > 0) != exclusive_pass) continue;

                // La boîte est calculée depuis la zone utilisable AVANT de
                // réserver l'exclusive_zone de cette surface elle-même
                // (sinon une barre exclusive rétrécirait sa propre zone,
                // exactement ce que fait wlr_scene_layer_surface_v1_configure
                // de wlroots). exclusive_zone == -1 => pleine surface.
                wlr_box bounds = (state.exclusive_zone == -1) ? full_area : usable;
                wlr_box box = layer_surface_box(state, bounds);

                // Ne configure que si la boîte change réellement : éviter de
                // renvoyer un configure à chaque commit si rien n'a bougé
                // (sinon ack/commit en boucle côté client).
                if (ls.x != box.x || ls.y != box.y || ls.width != box.width || ls.height != box.height) {
                    ls.x = box.x;
                    ls.y = box.y;
                    ls.width = box.width;
                    ls.height = box.height;
                    wlr_layer_surface_v1_configure(lsrf, box.width, box.height);
                    emit_signal("layer_surface_layout_changed",
                        ls.id, ls.x, ls.y, ls.width, ls.height);
                }

                // Réserve l'espace exclusif pour les surfaces SUIVANTES
                // (uniquement si la surface est mappée, comme sway).
                if (state.exclusive_zone > 0 && lsrf->surface->mapped) {
                    layer_apply_exclusive(&usable, state.anchor, state.exclusive_zone,
                        state.margin.top, state.margin.right, state.margin.bottom, state.margin.left);
                }
            }
        }
    }
}
void WlrCompositor::focus_layer_surface(LayerSurfaceState &ls) {
    if (!seat || !ls.layer_surface || !ls.layer_surface->surface) return;

    uint32_t ki = ls.layer_surface->current.keyboard_interactive;
    if (ki == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) return;

    keyboard_focus_layer_id = ls.id;
    wlr_seat_keyboard_notify_enter(seat, ls.layer_surface->surface,
        virtual_keyboard.keycodes,
        virtual_keyboard.num_keycodes,
        &virtual_keyboard.modifiers);
}
void WlrCompositor::unfocus_layer_surface(LayerSurfaceState &ls) {
    if (keyboard_focus_layer_id != ls.id) return;
    keyboard_focus_layer_id = -1;

    if (!seat) return;
    // Rend le focus clavier à la fenêtre active si elle existe encore,
    // sinon on vide le focus (wlroots le fait lui-même à l'unmap).
    if (active_toplevel_id != -1) {
        if (WindowState *ws = find_window(active_toplevel_id)) {
            wlr_seat_keyboard_notify_enter(seat, ws->toplevel->base->surface,
                virtual_keyboard.keycodes,
                virtual_keyboard.num_keycodes,
                &virtual_keyboard.modifiers);
        }
    }
}
void WlrCompositor::on_new_layer_surface(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_layer_surface_listener);
    auto *layer_surface = static_cast<wlr_layer_surface_v1 *>(data);

    if (!layer_surface->output) {
        layer_surface->output = self->headless_output;
    }

    int id = self->next_layer_surface_id++;
    LayerSurfaceState &ls = self->layer_surfaces[id];
    ls.id = id;
    ls.layer_surface = layer_surface;
    ls.owner = self;

    ls.map_listener.notify = WlrCompositor::on_layer_surface_map;
    wl_signal_add(&layer_surface->surface->events.map, &ls.map_listener);

    ls.unmap_listener.notify = WlrCompositor::on_layer_surface_unmap;
    wl_signal_add(&layer_surface->surface->events.unmap, &ls.unmap_listener);

    ls.destroy_listener.notify = WlrCompositor::on_layer_surface_destroy;
    wl_signal_add(&layer_surface->events.destroy, &ls.destroy_listener);

    ls.commit_listener.notify = WlrCompositor::on_layer_surface_commit;
    wl_signal_add(&layer_surface->surface->events.commit, &ls.commit_listener);

    ls.new_popup_listener.notify = WlrCompositor::on_layer_new_popup;
    wl_signal_add(&layer_surface->events.new_popup, &ls.new_popup_listener);

    UtilityFunctions::print("waylandgodot: new_layer_surface id=", id,
        " namespace=", waylandgodot_layer_surface_get_namespace(layer_surface)
            ? String::utf8(waylandgodot_layer_surface_get_namespace(layer_surface)) : String("(vide)"),
        " layer=", (int)layer_surface->pending.layer);
}
void WlrCompositor::on_layer_surface_map(wl_listener *listener, void *data) {
    LayerSurfaceState *ls = wl_container_of(listener, ls, map_listener);
    WlrCompositor *self = ls->owner;

    self->arrange_layer_surfaces();

    wlr_layer_surface_v1_state &state = ls->layer_surface->current;

    // Focus clavier automatique pour les surfaces EXCLUSIVE (waybar).
    // Jamais pour la couche background (fond d'écran) : elle est invisible
    // et ne doit pas avaler le clavier.
    if (state.layer != ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND &&
        state.keyboard_interactive == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE) {
        self->focus_layer_surface(*ls);
    }

    String ns = waylandgodot_layer_surface_get_namespace(ls->layer_surface)
        ? String::utf8(waylandgodot_layer_surface_get_namespace(ls->layer_surface)) : String();
    self->emit_signal("layer_surface_mapped", ls->id, ns,
        (int)state.layer, (int)state.anchor,
        ls->x, ls->y, ls->width, ls->height,
        (int)state.keyboard_interactive);
}
void WlrCompositor::on_layer_surface_unmap(wl_listener *listener, void *data) {
    LayerSurfaceState *ls = wl_container_of(listener, ls, unmap_listener);
    WlrCompositor *self = ls->owner;
    self->unfocus_layer_surface(*ls);
    self->emit_signal("layer_surface_unmapped", ls->id);
}
void WlrCompositor::on_layer_surface_destroy(wl_listener *listener, void *data) {
    LayerSurfaceState *ls = wl_container_of(listener, ls, destroy_listener);
    WlrCompositor *self = ls->owner;
    int id = ls->id;

    if (self->keyboard_focus_layer_id == id) {
        self->keyboard_focus_layer_id = -1;
    }

    wl_list_remove(&ls->map_listener.link);
    wl_list_remove(&ls->unmap_listener.link);
    wl_list_remove(&ls->destroy_listener.link);
    wl_list_remove(&ls->commit_listener.link);
    wl_list_remove(&ls->new_popup_listener.link);

    self->layer_surfaces.erase(id);
}
void WlrCompositor::on_layer_surface_commit(wl_listener *listener, void *data) {
    LayerSurfaceState *ls = wl_container_of(listener, ls, commit_listener);
    WlrCompositor *self = ls->owner;

    self->arrange_layer_surfaces();

    // La capture effective (render pass offscreen + synchronisation + signal)
    // est déléguée à _process, qui capture AU PLUS UNE FOIS par frame par
    // surface. Capturer ici EN PLUS de la boucle _process faisait que chaque
    // surface qui commit était rendue deux fois par frame (render pass GPU +
    // sync DMA-BUF bloquante + signal en double) — cause directe de jank sur
    // les overlays animés (barres quickshell, notifications, launcher).
    ls->dirty = true;
}
void WlrCompositor::on_layer_new_popup(wl_listener *listener, void *data) {
    LayerSurfaceState *ls = wl_container_of(listener, ls, new_popup_listener);
    WlrCompositor *self = ls->owner;
    auto *popup = static_cast<wlr_xdg_popup *>(data);

    int id = self->next_popup_id++;
    PopupState &ps = self->popups[id];
    ps.id = id;
    ps.parent_window_id = -1;
    ps.parent_popup_id = -1;
    ps.parent_layer_id = ls->id;
    self->wire_popup(ps, popup);

    UtilityFunctions::print("waylandgodot: new_popup (layer) id=", id, " parent_layer_id=", ls->id);
}
Dictionary WlrCompositor::get_layer_surface_info(int layer_id) {
    Dictionary result;
    LayerSurfaceState *ls = find_layer_surface(layer_id);
    if (!ls || !ls->layer_surface) return result;

    wlr_layer_surface_v1_state &state = ls->layer_surface->current;
    const char *ns_cstr = waylandgodot_layer_surface_get_namespace(ls->layer_surface);
    result["namespace"] = ns_cstr ? String::utf8(ns_cstr) : String();
    result["layer"] = (int)state.layer;
    result["anchor"] = (int)state.anchor;
    result["keyboard_interactive"] = (int)state.keyboard_interactive;
    result["margin_top"] = state.margin.top;
    result["margin_right"] = state.margin.right;
    result["margin_bottom"] = state.margin.bottom;
    result["margin_left"] = state.margin.left;
    result["x"] = ls->x;
    result["y"] = ls->y;
    result["width"] = ls->width;
    result["height"] = ls->height;
    return result;
}
int WlrCompositor::get_keyboard_focus_layer_id() const {
    return keyboard_focus_layer_id;
}
void WlrCompositor::close_layer_surface(int layer_id) {
    LayerSurfaceState *ls = find_layer_surface(layer_id);
    if (!ls || !ls->layer_surface) return;
    wlr_layer_surface_v1_destroy(ls->layer_surface);
}
