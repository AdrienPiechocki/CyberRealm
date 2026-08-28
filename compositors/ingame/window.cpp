#include "wlr_compositor.h"

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

void WlrCompositor::on_new_toplevel(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_toplevel_listener);
    auto *toplevel = static_cast<wlr_xdg_toplevel *>(data);

    int id = self->next_window_id++;    WindowState &ws = self->windows[id];
    ws.id = id;
    ws.toplevel = toplevel;
    ws.owner = self;

    ws.map_listener.notify = WlrCompositor::on_toplevel_map;
    wl_signal_add(&toplevel->base->surface->events.map, &ws.map_listener);

    ws.unmap_listener.notify = WlrCompositor::on_toplevel_unmap;
    wl_signal_add(&toplevel->base->surface->events.unmap, &ws.unmap_listener);

    ws.destroy_listener.notify = WlrCompositor::on_toplevel_destroy;
    wl_signal_add(&toplevel->events.destroy, &ws.destroy_listener);

    ws.commit_listener.notify = WlrCompositor::on_surface_commit;
    wl_signal_add(&toplevel->base->surface->events.commit, &ws.commit_listener);

    ws.new_popup_listener.notify = WlrCompositor::on_new_popup;
    wl_signal_add(&toplevel->base->events.new_popup, &ws.new_popup_listener);

    ws.request_fullscreen_listener.notify = WlrCompositor::on_request_fullscreen;
    wl_signal_add(&toplevel->events.request_fullscreen, &ws.request_fullscreen_listener);

    ws.request_maximize_listener.notify = WlrCompositor::on_request_maximize;
    wl_signal_add(&toplevel->events.request_maximize, &ws.request_maximize_listener);

    ws.request_minimize_listener.notify = WlrCompositor::on_request_minimize;
    wl_signal_add(&toplevel->events.request_minimize, &ws.request_minimize_listener);

    ws.request_move_listener.notify = WlrCompositor::on_request_move;
    wl_signal_add(&toplevel->events.request_move, &ws.request_move_listener);

    ws.request_resize_listener.notify = WlrCompositor::on_request_resize;
    wl_signal_add(&toplevel->events.request_resize, &ws.request_resize_listener);

    ws.set_title_listener.notify = WlrCompositor::on_toplevel_set_title;
    wl_signal_add(&toplevel->events.set_title, &ws.set_title_listener);

    UtilityFunctions::print("waylandgodot: new_toplevel received, id=", id,
        " app_id=", toplevel->app_id ? String::utf8(toplevel->app_id) : String("(not set yet)"));

    (void)id;
}
void WlrCompositor::on_toplevel_decoration_request_mode(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, decoration_request_mode_listener);
    auto *decoration = static_cast<wlr_xdg_toplevel_decoration_v1 *>(data);

    if (ws->toplevel->base->initialized) {
        enum wlr_xdg_toplevel_decoration_v1_mode mode = decoration->requested_mode;
        if (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_NONE) {
            mode = WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
        }
        wlr_xdg_toplevel_decoration_v1_set_mode(decoration, mode);
        ws->decoration_server_side = (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        ws->decoration_mode_pending = false;
    } else {
        ws->decoration_mode_pending = true;
    }
}
void WlrCompositor::on_toplevel_decoration_destroy(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, decoration_destroy_listener);
    ws->decoration = nullptr;
    ws->decoration_mode_pending = false;
    wl_list_remove(&ws->decoration_request_mode_listener.link);
    wl_list_remove(&ws->decoration_destroy_listener.link);
}
void WlrCompositor::on_toplevel_map(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, map_listener);
    WlrCompositor *self = ws->owner;

    String title = ws->toplevel->title ? String::utf8(ws->toplevel->title) : String();
    String app_id = ws->toplevel->app_id ? String::utf8(ws->toplevel->app_id) : String();

    // PID du client Wayland de la fenêtre : servi au partage audio « fenêtres
    // seules » (matching avec application.process.id du node PipeWire).
    ws->pid = -1;
    wl_client *map_client = ws->toplevel->base->surface->resource
        ? wl_resource_get_client(ws->toplevel->base->surface->resource) : nullptr;
    if (map_client) {
        pid_t pid = 0;
        uid_t uid = 0;
        gid_t gid = 0;
        wl_client_get_credentials(map_client, &pid, &uid, &gid);
        ws->pid = pid;
    }

    // true si la fenêtre vient du client xwayland-satellite (toutes les apps
    // X11 de la session). /proc/<pid>/comm est limité à TASK_COMM_LEN (15
    // caractères + NUL) : "xwayland-satellite" (18) apparaît donc comme
    // "xwayland-satell".
    ws->xwayland = false;
    if (ws->pid > 0) {
        std::string comm_path = "/proc/" + std::to_string((long)ws->pid) + "/comm";
        std::ifstream comm_file(comm_path);
        std::string comm;
        if (comm_file.is_open() && std::getline(comm_file, comm)) {
            ws->xwayland = (comm == "xwayland-satell");
        }
    }

    // Une nouvelle fenêtre (surtout X11) : le vrai PID sera lu sur le serveur
    // X ; on réveille le résolveur pour qu'il ré-énumère sans attendre le
    // throttling interne de get_window_pid().
    self->x11_resolver.request_refresh();

    // Handle ext-foreign-toplevel-list-v1 : c'est ce que le chooser de
    // portal-wlr liste pour proposer la "capture fenêtre" à OBS.
    if (self->foreign_toplevel_list) {
        wlr_ext_foreign_toplevel_handle_v1_state state = {
            .title = ws->toplevel->title ? ws->toplevel->title : "",
            .app_id = ws->toplevel->app_id ? ws->toplevel->app_id : "",
        };
        ws->foreign_handle = wlr_ext_foreign_toplevel_handle_v1_create(self->foreign_toplevel_list, &state);
        if (ws->foreign_handle) {
            ws->foreign_handle->data = ws;
        }
    }

    UtilityFunctions::print("waylandgodot: toplevel mapped id=", ws->id,
        " app_id=", app_id, " title=\"", title, "\" size=",
        ws->toplevel->base->surface->current.width, "x",
        ws->toplevel->base->surface->current.height);

    self->emit_signal("window_mapped", ws->id, title, app_id);

    // Annonce la présence (ou l'absence) d'une décoration gérée par le jeu :
    // le client a créé son objet xdg-decoration avant son premier commit
    // (donc avant le map) s'il en voulait une, et on répond toujours
    // SERVER_SIDE. server_side=false => le client dessine ses propres
    // décorations, le jeu doit cacher sa barre de titre.
    self->emit_signal("window_decorations_changed", ws->id, ws->decoration_server_side);
}
void WlrCompositor::on_toplevel_unmap(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, unmap_listener);
    WlrCompositor *self = ws->owner;
    self->emit_signal("window_unmapped", ws->id);
    // Fenêtre fermée : rafraîchit le snapshot X11 (fenêtres/apps retirées).
    self->x11_resolver.request_refresh();
}
void WlrCompositor::on_toplevel_set_title(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, set_title_listener);
    WlrCompositor *self = ws->owner;

    // Synchronise le handle ext-foreign-toplevel-list-v1 (titre affiché par
    // portal-wlr dans le chooser de capture OBS).
    if (ws->foreign_handle) {
        wlr_ext_foreign_toplevel_handle_v1_state state = {
            .title = ws->toplevel->title ? ws->toplevel->title : "",
            .app_id = ws->toplevel->app_id ? ws->toplevel->app_id : "",
        };
        wlr_ext_foreign_toplevel_handle_v1_update_state(ws->foreign_handle, &state);
    }

    // Le titre peut changer à tout moment (xdg-shell set_title, avant OU
    // après le map) : le jeu met à jour l'étiquette de sa barre de titre.
    self->emit_signal("window_title_changed", ws->id,
        ws->toplevel->title ? String::utf8(ws->toplevel->title) : String());
    // Le matching fenêtre X11 → PID (audio) se fait sur le titre : un
    // changement de titre doit rafraîchir le snapshot.
    if (ws->xwayland) {
        self->x11_resolver.request_refresh();
    }
}
void WlrCompositor::on_toplevel_destroy(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, destroy_listener);
    WlrCompositor *self = ws->owner;
    int id = ws->id;

    if (self->active_toplevel_id == id) {
        self->active_toplevel_id = -1;
    }

    // Capture fenêtre : stopper une éventuelle source ext_image_capture
    // (envoie "stopped" à portal-wlr) et retirer le handle foreign-toplevel.
    self->destroy_toplevel_image_source(ws->image_source);
    if (ws->foreign_handle) {
        wlr_ext_foreign_toplevel_handle_v1_destroy(ws->foreign_handle);
        ws->foreign_handle = nullptr;
    }

    // Retire les trackers de sous-surfaces (et leurs listeners des signaux
    // des surfaces, qui peuvent survivre à la fenêtre).
    ws->clear_sub_surface_trackers();

    wl_list_remove(&ws->map_listener.link);
    wl_list_remove(&ws->unmap_listener.link);
    wl_list_remove(&ws->destroy_listener.link);
    wl_list_remove(&ws->commit_listener.link);
    wl_list_remove(&ws->new_popup_listener.link);
    wl_list_remove(&ws->request_fullscreen_listener.link);
    wl_list_remove(&ws->request_maximize_listener.link);
    wl_list_remove(&ws->request_minimize_listener.link);
    wl_list_remove(&ws->request_move_listener.link);
    wl_list_remove(&ws->request_resize_listener.link);
    wl_list_remove(&ws->set_title_listener.link);

    self->windows.erase(id);
    self->clear_window_cursor(id);
}
void WlrCompositor::on_surface_commit(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, commit_listener);
    WlrCompositor *self = ws->owner;

    if (ws->toplevel->base->initial_commit) {
        // Taille de l'output virtuel (= viewport Godot) : base de la taille
        // initiale des fenêtres.
        int vw = 1920, vh = 1080;
        if (Viewport *vp = self->get_viewport()) {
            Rect2 vr = vp->get_visible_rect();
            vw = (int)vr.size.x;
            vh = (int)vr.size.y;
        }
        if (ws->toplevel->requested.fullscreen) {
            // Honorer le plein écran demandé avant le commit initial
            // (ex. Firefox), sinon on l'écraserait avec la taille par défaut.
            wlr_xdg_toplevel_set_fullscreen(ws->toplevel, true);
            wlr_xdg_toplevel_set_size(ws->toplevel, vw, vh);
        } else if (ws->toplevel->requested.maximized) {
            // Le client a lui-même demandé d'ouvrir maximisé avant le commit
            // initial (restauration d'une session) : on l'honore.
            wlr_xdg_toplevel_set_maximized(ws->toplevel, true);
            wlr_xdg_toplevel_set_size(ws->toplevel, vw, vh);
        } else {
            // Ouverture à la taille naturelle du client : le configure
            // envoyé ci-dessous sans dimension laisse le client utiliser sa
            // propre taille préférée (ex. un dialogue polkit s'ouvre petit,
            // pas en plein viewport). Ne plus imposer maximize + taille du
            // viewport, sinon TOUTES les fenêtres s'ouvrent plein écran.
        }
        // Si une décoration xdg-decoration-v1 attend encore sa confirmation
        // de mode (request_mode reçu avant le premier commit), c'est ici
        // que la surface est enfin initialisée : on peut la confirmer
        // (SERVER_SIDE, cf. on_toplevel_decoration_request_mode).
        if (ws->decoration && ws->decoration_mode_pending) {
            enum wlr_xdg_toplevel_decoration_v1_mode mode = ws->decoration->requested_mode;
            if (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_NONE) {
                mode = WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;
            }
            wlr_xdg_toplevel_decoration_v1_set_mode(ws->decoration, mode);
            ws->decoration_server_side = (mode == WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            ws->decoration_mode_pending = false;
        }
        wlr_xdg_surface_schedule_configure(ws->toplevel->base);
        return;
    }

    // Un commit = nouveau contenu. On marque la fenêtre dirty et on laisse
    // _process faire la capture (une seule fois par frame et par fenêtre,
    // même si le client commite plusieurs fois). Capturer ici ET dans
    // _process faisait rendre chaque fenêtre active deux fois par frame.
    ws->dirty = true;
}
void WlrCompositor::sync_window_subsurfaces(WindowState &ws) {
    if (!ws.toplevel || !ws.toplevel->base || !ws.toplevel->base->surface) return;
    wlr_surface *root = ws.toplevel->base->surface;

    wlr_surface_for_each_surface(root,
        +[](wlr_surface *surface, int, int, void *data) {
            auto *window = static_cast<WindowState *>(data);
            // La racine est déjà écoutée par WindowState::commit_listener.
            if (surface == window->toplevel->base->surface) return;
            auto [it, inserted] = window->sub_surface_trackers.try_emplace(surface);
            if (!inserted) return;
            SurfaceCommitTracker &tracker = it->second;
            tracker.surface = surface;
            tracker.ws = window;
            tracker.commit.notify = SurfaceCommitTracker::on_commit;
            tracker.destroy.notify = SurfaceCommitTracker::on_destroy;
            wl_signal_add(&surface->events.commit, &tracker.commit);
            wl_signal_add(&surface->events.destroy, &tracker.destroy);
        }, &ws);
}
void WlrCompositor::on_request_fullscreen(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, request_fullscreen_listener);
    wlr_xdg_toplevel *toplevel = ws->toplevel;
    bool fullscreen = toplevel->requested.fullscreen;

    // Un client peut demander le plein écran avant son commit initial
    // (surface non initialisée). Les setters wlr_xdg_toplevel_set_* appellent
    // wlr_xdg_surface_schedule_configure() en interne, qui fait un assert.
    // L'état demandé reste dans toplevel->requested et est appliqué lors du
    // commit initial dans on_surface_commit().
    if (!toplevel->base->initialized) {
        return;
    }

    // Récupère la taille du viewport Godot pour dimensionner le plein écran.
    int fw = 1920, fh = 1080;
    if (Viewport *vp = ws->owner->get_viewport()) {
        Rect2 vr = vp->get_visible_rect();
        fw = (int)vr.size.x;
        fh = (int)vr.size.y;
    }

    wlr_xdg_toplevel_set_fullscreen(toplevel, fullscreen);
    if (fullscreen) {
        wlr_xdg_toplevel_set_size(toplevel, fw, fh);
    }
    wlr_xdg_surface_schedule_configure(toplevel->base);
    ws->owner->emit_signal("window_fullscreen_changed", ws->id, fullscreen);
}
void WlrCompositor::on_request_maximize(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, request_maximize_listener);
    wlr_xdg_toplevel *toplevel = ws->toplevel;

    // Même remarque que on_request_fullscreen : les setters
    // wlr_xdg_toplevel_set_* ne doivent pas être appelés avant le commit
    // initial (assert dans wlr_xdg_surface_schedule_configure()).
    if (!toplevel->base->initialized) {
        return;
    }

    int mw = 1920, mh = 1080;
    if (Viewport *vp = ws->owner->get_viewport()) {
        Rect2 vr = vp->get_visible_rect();
        mw = (int)vr.size.x;
        mh = (int)vr.size.y;
    }

    wlr_xdg_toplevel_set_maximized(toplevel, toplevel->requested.maximized);
    if (toplevel->requested.maximized) {
        wlr_xdg_toplevel_set_size(toplevel, mw, mh);
    }
    wlr_xdg_surface_schedule_configure(toplevel->base);
}
void WlrCompositor::on_request_minimize(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, request_minimize_listener);
    // On ignore la minimisation (pas de concept de "taskbar" dans ce compositeur 3D)
    // mais on doit quand même répondre par un configure.
    if (ws->toplevel->base->initialized) {
        wlr_xdg_surface_schedule_configure(ws->toplevel->base);
    }
}
void WlrCompositor::on_request_move(wl_listener *listener, void *data) {
    // Le déplacement est déjà géré via le middle-click drag dans le script GDScript.
    // On ignore la demande mais on doit respecter le protocole.
}
void WlrCompositor::on_request_resize(wl_listener *listener, void *data) {
    // Le redimensionnement est déjà géré via les bords de fenêtre dans le script GDScript.
    // On ignore la demande mais on doit respecter le protocole.
}
void WlrCompositor::wire_popup(PopupState &ps, wlr_xdg_popup *popup) {
    ps.popup = popup;
    ps.owner = this;

    ps.map_listener.notify = WlrCompositor::on_popup_map;
    wl_signal_add(&popup->base->surface->events.map, &ps.map_listener);

    ps.unmap_listener.notify = WlrCompositor::on_popup_unmap;
    wl_signal_add(&popup->base->surface->events.unmap, &ps.unmap_listener);

    ps.destroy_listener.notify = WlrCompositor::on_popup_destroy;
    wl_signal_add(&popup->events.destroy, &ps.destroy_listener);

    ps.commit_listener.notify = WlrCompositor::on_popup_commit;
    wl_signal_add(&popup->base->surface->events.commit, &ps.commit_listener);

    ps.reposition_listener.notify = WlrCompositor::on_popup_reposition;
    wl_signal_add(&popup->events.reposition, &ps.reposition_listener);

    ps.new_popup_listener.notify = WlrCompositor::on_new_popup_from_popup;
    wl_signal_add(&popup->base->events.new_popup, &ps.new_popup_listener);
}
void WlrCompositor::on_new_popup(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, new_popup_listener);
    WlrCompositor *self = ws->owner;
    auto *popup = static_cast<wlr_xdg_popup *>(data);

    int id = self->next_popup_id++;
    PopupState &ps = self->popups[id];
    ps.id = id;
    ps.parent_window_id = ws->id;
    ps.parent_popup_id = -1;
    self->wire_popup(ps, popup);

    UtilityFunctions::print("waylandgodot: new_popup received, id=", id, " parent_window_id=", ws->id);
}
void WlrCompositor::on_new_popup_from_popup(wl_listener *listener, void *data) {
    PopupState *parent_ps = wl_container_of(listener, parent_ps, new_popup_listener);
    WlrCompositor *self = parent_ps->owner;
    auto *popup = static_cast<wlr_xdg_popup *>(data);

    int id = self->next_popup_id++;
    PopupState &ps = self->popups[id];
    ps.id = id;
    ps.parent_window_id = parent_ps->parent_window_id;
    ps.parent_popup_id = parent_ps->id;
    self->wire_popup(ps, popup);

    UtilityFunctions::print("waylandgodot: new_popup (submenu) received, id=", id,
        " parent_popup_id=", parent_ps->id);
}
void WlrCompositor::focus_surface(wlr_surface *surface) {
    if (!seat || !surface) return;
    // wlr_seat_keyboard_enter et NON notify_enter : pendant le grab clavier
    // d'un popup xdg (xdg_popup.grab envoyé par GTK/Firefox), notify_enter
    // est routé vers xdg_keyboard_grab_enter qui est un NO-OP (wlroots
    // considère que le focus clavier doit rester sur le popup, et laisse au
    // compositeur le soin de l'y mettre). wlr_seat_keyboard_enter ignore les
    // grabs et envoie l'enter directement au popup.
    wlr_seat_keyboard_enter(seat, surface,
        virtual_keyboard.keycodes,
        virtual_keyboard.num_keycodes,
        &virtual_keyboard.modifiers);
}
void WlrCompositor::restore_focus_after_popup(PopupState &ps) {
    if (!seat) return;

    // Re-donne le focus à un popup ancêtre encore vivant (sous-menu qui se
    // ferme alors que le menu parent reste ouvert), sinon à la fenêtre active.
    if (ps.parent_popup_id != -1) {
        if (PopupState *parent_ps = find_popup(ps.parent_popup_id)) {
            focus_surface(parent_ps->popup->base->surface);
            return;
        }
    }
    if (ps.parent_window_id != -1) {
        if (WindowState *ws = find_window(ps.parent_window_id)) {
            focus_surface(ws->toplevel->base->surface);
            return;
        }
    }
    if (active_toplevel_id != -1) {
        if (WindowState *ws = find_window(active_toplevel_id)) {
            focus_surface(ws->toplevel->base->surface);
        }
    }
}
void WlrCompositor::emit_popup_mapped(PopupState &ps) {
    if (ps.mapped_emitted) return;
    ps.mapped_emitted = true;

    // Focus clavier sur le popup UNIQUEMENT s'il a un grab xdg actif
    // (xdg_popup.grab, popup->seat est alors non NULL) : sans grab, les
    // compositeurs de référence (mutter, sway) laissent le focus clavier sur
    // la fenêtre parente. Forcer un enter clavier sur un popup sans grab
    // fait fermer le menu par GTK/Firefox peu après l'ouverture (menu
    // burger), le client voyant un focus non sollicité. Firefox n'envoie
    // jamais xdg_popup.grab.
    if (ps.popup->seat != nullptr) {
        focus_surface(ps.popup->base->surface);
    }

    wlr_box geo = ps.popup->current.geometry;

    // Popup attaché à une layer surface (tooltip waybar, menus...) : c'est
    // un signal distinct, le script Godot le positionne par rapport à
    // l'overlay de la layer surface plutôt qu'à un quad 3D.
    if (ps.parent_layer_id >= 0) {
        UtilityFunctions::print("waylandgodot: layer_popup_mapped id=", ps.id,
            " parent_layer=", ps.parent_layer_id,
            " x=", geo.x, " y=", geo.y, " w=", geo.width, " h=", geo.height);
        emit_signal("layer_popup_mapped", ps.id, ps.parent_layer_id,
            geo.x, geo.y, geo.width, geo.height);
        return;
    }

    UtilityFunctions::print("waylandgodot: popup_mapped id=", ps.id,
        " parent=", ps.parent_window_id,
        " parent_popup=", ps.parent_popup_id,
        " x=", geo.x, " y=", geo.y, " w=", geo.width, " h=", geo.height);
    emit_signal("popup_mapped", ps.id, ps.parent_window_id, ps.parent_popup_id,
        geo.x, geo.y, geo.width, geo.height);
}
void WlrCompositor::on_popup_map(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, map_listener);
    WlrCompositor *self = ps->owner;
    self->emit_popup_mapped(*ps);
}
void WlrCompositor::on_popup_unmap(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, unmap_listener);
    WlrCompositor *self = ps->owner;
    ps->mapped_emitted = false;
    self->restore_focus_after_popup(*ps);
    self->emit_signal("popup_unmapped", ps->id);
}
void WlrCompositor::on_popup_reposition(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, reposition_listener);
    WlrCompositor *self = ps->owner;

    // wlr_xdg_popup_unconstrain_from_box() appelle aussi
    // wlr_xdg_surface_schedule_configure() en interne : ne pas l'appeler
    // avant le commit initial du popup.
    if (!ps->popup->base->initialized) {
        return;
    }

    if (WindowState *parent = self->find_window(ps->parent_window_id)) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        constraint_box.width = parent->width > 0 ? parent->width : 800;
        constraint_box.height = parent->height > 0 ? parent->height : 600;
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
    } else if (LayerSurfaceState *parent_ls = self->find_layer_surface(ps->parent_layer_id)) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        constraint_box.width = parent_ls->width > 0 ? parent_ls->width : 1920;
        constraint_box.height = parent_ls->height > 0 ? parent_ls->height : 1080;
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
    }

    wlr_xdg_surface_schedule_configure(ps->popup->base);
}
void WlrCompositor::on_popup_destroy(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, destroy_listener);
    WlrCompositor *self = ps->owner;
    int id = ps->id;

    // Un popup visible mais jamais "mapped" côté wlroots (racine sans
    // buffer, contenu dans des sous-surfaces) ne reçoit jamais l'événement
    // unmap (wlr_surface_unmap est sans effet si !mapped) : on signale
    // l'arrêt ici pour que Godot libère le quad.
    if (ps->mapped_emitted) {
        self->restore_focus_after_popup(*ps);
        self->emit_signal("popup_unmapped", id);
    }

    wl_list_remove(&ps->map_listener.link);
    wl_list_remove(&ps->unmap_listener.link);
    wl_list_remove(&ps->destroy_listener.link);
    wl_list_remove(&ps->commit_listener.link);
    wl_list_remove(&ps->reposition_listener.link);
    wl_list_remove(&ps->new_popup_listener.link);

    self->popups.erase(id);
}
void WlrCompositor::on_popup_commit(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, commit_listener);
    WlrCompositor *self = ps->owner;

    if (ps->popup->base->initial_commit) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        if (WindowState *parent = self->find_window(ps->parent_window_id)) {
            constraint_box.width = parent->width > 0 ? parent->width : 800;
            constraint_box.height = parent->height > 0 ? parent->height : 600;
        } else if (LayerSurfaceState *parent_ls = self->find_layer_surface(ps->parent_layer_id)) {
            constraint_box.width = parent_ls->width > 0 ? parent_ls->width : 1920;
            constraint_box.height = parent_ls->height > 0 ? parent_ls->height : 1080;
        } else {
            constraint_box.width = 800;
            constraint_box.height = 600;
        }
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
        wlr_xdg_surface_schedule_configure(ps->popup->base);
        return;
    }

    // Un popup dont la surface racine n'a jamais de buffer (sous-popups
    // Firefox, contenu WebRender dans une sous-surface) ne déclenche pas
    // l'événement map de wlroots (wlr_surface_map exige un buffer racine) :
    // le signal popup_mapped est émis ici dès que l'arbre a du contenu
    // (extents non vides, sous-surfaces comprises). Pour un popup normal
    // (racine avec buffer), on_popup_map a déjà émis le signal au premier
    // commit et mapped_emitted est déjà vrai : no-op.
    if (!ps->mapped_emitted) {
        wlr_box extents;
        wlr_surface_get_extents(ps->popup->base->surface, &extents);
        if (!wlr_box_empty(&extents)) {
            self->emit_popup_mapped(*ps);
        }
    }

    if (!self->capture_surface(ps->popup->base->surface, ps->texture, ps->width, ps->height, ps->capture_cache)) {
        return;
    }
    self->emit_signal("popup_texture_updated", ps->id, ps->texture, ps->width, ps->height);
}
bool WlrCompositor::is_window_xwayland(int window_id) {
    WindowState *ws = find_window(window_id);
    if (!ws) return false;
    // Déterminé une fois au map (lecture de /proc/<pid>/comm) — voir
    // on_toplevel_map. "xwayland-satellite" est tronqué en "xwayland-satell".
    return ws->xwayland;
}
void WlrCompositor::set_window_size(int window_id, int width, int height) {
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel) return;

    if (width < 50) width = 50;
    if (height < 50) height = 50;

    if (!ws->toplevel->base->initialized) {
        return;
    }

    wlr_xdg_toplevel_set_size(ws->toplevel, width, height);
    wlr_xdg_surface_schedule_configure(ws->toplevel->base);
}
void WlrCompositor::set_window_fullscreen(int window_id, bool fullscreen) {
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel) return;

    if (!ws->toplevel->base->initialized) {
        return;
    }

    wlr_xdg_toplevel_set_fullscreen(ws->toplevel, fullscreen);
    if (fullscreen) {
        int fw = 1920, fh = 1080;
        if (Viewport *vp = get_viewport()) {
            Rect2 vr = vp->get_visible_rect();
            fw = (int)vr.size.x;
            fh = (int)vr.size.y;
        }
        wlr_xdg_toplevel_set_size(ws->toplevel, fw, fh);
    }
    wlr_xdg_surface_schedule_configure(ws->toplevel->base);
    emit_signal("window_fullscreen_changed", ws->id, fullscreen);
}
Dictionary WlrCompositor::get_window_geometry(int window_id) {
    Dictionary result;
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel || !ws->toplevel->base) {
        result["x"] = 0;
        result["y"] = 0;
        result["width"] = 0;
        result["height"] = 0;
        return result;
    }
    // current.geometry = zone de contenu définie par le client via
    // set_window_geometry. Pour les clients CSD (Firefox, GTK, Qt), c'est
    // la zone réelle du contenu sans les ombres/décorations transparentes.
    // x,y = décalage du contenu dans la surface (marge d'ombre).
    // width,height = taille du contenu (sans ombres).
    // NB : les clients X11/xwayland (jeux, apps X11) n'appellent JAMAIS
    // set_window_geometry → current.geometry reste (0,0,0,0) → les consom-
    // mateurs (partage vidéo, focus mode, UV des quads) recevaient une
    // géométrie vide. Fallback identique au chemin de capture : géométrie
    // xdg calculée par wlroots (xdg->geometry, intersection de la window_
    // geometry avec les extents de la surface), puis taille logique de la
    // surface, puis taille de la texture.
    wlr_surface *surface = ws->toplevel->base->surface;
    wlr_box geo = ws->toplevel->base->current.geometry;
    if (geo.width <= 0 || geo.height <= 0) {
        wlr_xdg_surface *xdg = surface ? wlr_xdg_surface_try_from_wlr_surface(surface) : nullptr;
        if (xdg && xdg->geometry.width > 0 && xdg->geometry.height > 0) {
            geo = xdg->geometry;
        }
    }
    if (surface && (geo.width <= 0 || geo.height <= 0)) {
        geo.x = 0;
        geo.y = 0;
        geo.width = surface->current.width;
        geo.height = surface->current.height;
    }
    if (surface && (geo.width <= 0 || geo.height <= 0)) {
        wlr_texture *tex = wlr_surface_get_texture(surface);
        if (tex) {
            geo.x = 0;
            geo.y = 0;
            geo.width = (int)tex->width;
            geo.height = (int)tex->height;
        }
    }
    result["x"] = geo.x;
    result["y"] = geo.y;
    result["width"] = geo.width;
    result["height"] = geo.height;
    return result;
}
bool WlrCompositor::popup_accepts_input(int popup_id) {
    PopupState *ps = find_popup(popup_id);
    if (!ps || !ps->popup || !ps->popup->base || !ps->popup->base->surface) return false;
    // Les tooltips ont une région d'input vide (wl_surface_set_input_region
    // avec une region empty). Les menus/dropdowns ont une région non vide.
    bool ok = !pixman_region32_empty(&ps->popup->base->surface->current.input);
    return ok;
}
Array WlrCompositor::get_window_list() {
    Array result;
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (!ws.toplevel || !ws.toplevel->base) continue;
        Dictionary entry;
        entry["id"] = ws.id;
        entry["title"] = ws.toplevel->title ? String::utf8(ws.toplevel->title) : String();
        entry["app_id"] = ws.toplevel->app_id ? String::utf8(ws.toplevel->app_id) : String();
        result.append(entry);
    }
    return result;
}
void WlrCompositor::close_window(int window_id) {
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel) return;
    wlr_xdg_toplevel_send_close(ws->toplevel);
}
