// zwlr_foreign_toplevel_management_v1 : barres de tâches lancées DANS le jeu
// (module wlr/taskbar de waybar, lswt…).
//
// Un handle par fenêtre locale mappée (créé au map, détruit à l'unmap), qui
// publie titre, app_id, parent, output, et l'état activated / minimized /
// fullscreen. Les requêtes de la barre ne sont pas exécutées ici : elles
// remontent au jeu par le signal toplevel_request(window_id, action, value),
// qui décide (cacher le quad, mode focus, fermer…) et renvoie l'état réel par
// set_toplevel_minimized / set_toplevel_fullscreen. « activated » suit le
// focus clavier du seat (on_keyboard_focus_change).
//
// Le focus clavier sert aussi aux inhibiteurs de raccourcis
// (shortcuts_inhibit.cpp) : le listener unique est ici.

#include "wlr_compositor.h"

#include <godot_cpp/variant/utility_functions.hpp>

extern "C" {
#include <wlr/types/wlr_xdg_shell.h>
}

using namespace godot;

int WlrCompositor::window_id_for_surface(wlr_surface *surface) {
    // Une surface focalisée peut être un popup (menu GTK, liste déroulante) :
    // remonter la chaîne des popups jusqu'au toplevel propriétaire.
    for (int depth = 0; surface && depth < 32; depth++) {
        wlr_surface *root = wlr_surface_get_root_surface(surface);
        if (!root) {
            return -1;
        }
        int id = find_window_id_by_surface(root);
        if (id != -1) {
            return id;
        }
        wlr_xdg_popup *popup = wlr_xdg_popup_try_from_wlr_surface(root);
        if (!popup) {
            return -1;
        }
        surface = popup->parent;
    }
    return -1;
}

int WlrCompositor::keyboard_focus_window_id() {
    if (!seat || !seat->keyboard_state.focused_surface) {
        return -1;
    }
    return window_id_for_surface(seat->keyboard_state.focused_surface);
}

void WlrCompositor::on_keyboard_focus_change(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, keyboard_focus_change_listener);
    // Destruction en cours (~WlrCompositor ferme les clients, ce qui change
    // le focus) : ne plus rien émettre vers un objet Godot à demi détruit.
    if (!self->alive_guard || !self->alive_guard->load()) {
        return;
    }
    self->sync_toplevel_mgmt_activated();
    self->update_shortcuts_inhibitors();
    // text_input_v3 : enter / leave suivent le focus clavier (text_input.cpp).
    auto *ev = static_cast<wlr_seat_keyboard_focus_change_event *>(data);
    self->text_input_focus_changed(ev ? ev->new_surface : nullptr);
}

void WlrCompositor::sync_toplevel_mgmt_activated() {
    int focused = keyboard_focus_window_id();
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (ws.mgmt_handle) {
            wlr_foreign_toplevel_handle_v1_set_activated(ws.mgmt_handle, pair.first == focused);
        }
    }
}

void WlrCompositor::create_toplevel_mgmt_handle(WindowState &ws) {
    if (!foreign_toplevel_manager || ws.mgmt_handle || !ws.toplevel) {
        return;
    }
    wlr_foreign_toplevel_handle_v1 *h = wlr_foreign_toplevel_handle_v1_create(foreign_toplevel_manager);
    if (!h) {
        return;
    }
    ws.mgmt_handle = h;
    h->data = &ws;
    wlr_foreign_toplevel_handle_v1_set_title(h, ws.toplevel->title ? ws.toplevel->title : "");
    wlr_foreign_toplevel_handle_v1_set_app_id(h, ws.toplevel->app_id ? ws.toplevel->app_id : "");
    if (headless_output) {
        wlr_foreign_toplevel_handle_v1_output_enter(h, headless_output);
    }
    // Fenêtre fille (boîte de dialogue) : la barre la regroupe sous son parent.
    if (ws.toplevel->parent) {
        int parent_id = find_window_id_by_surface(ws.toplevel->parent->base->surface);
        if (WindowState *parent = find_window(parent_id)) {
            if (parent->mgmt_handle) {
                wlr_foreign_toplevel_handle_v1_set_parent(h, parent->mgmt_handle);
            }
        }
    }
    wlr_foreign_toplevel_handle_v1_set_activated(h, keyboard_focus_window_id() == ws.id);

    ws.mgmt_request_activate_listener.notify = WlrCompositor::on_mgmt_request_activate;
    wl_signal_add(&h->events.request_activate, &ws.mgmt_request_activate_listener);
    ws.mgmt_request_minimize_listener.notify = WlrCompositor::on_mgmt_request_minimize;
    wl_signal_add(&h->events.request_minimize, &ws.mgmt_request_minimize_listener);
    ws.mgmt_request_maximize_listener.notify = WlrCompositor::on_mgmt_request_maximize;
    wl_signal_add(&h->events.request_maximize, &ws.mgmt_request_maximize_listener);
    ws.mgmt_request_fullscreen_listener.notify = WlrCompositor::on_mgmt_request_fullscreen;
    wl_signal_add(&h->events.request_fullscreen, &ws.mgmt_request_fullscreen_listener);
    ws.mgmt_request_close_listener.notify = WlrCompositor::on_mgmt_request_close;
    wl_signal_add(&h->events.request_close, &ws.mgmt_request_close_listener);
    ws.mgmt_destroy_listener.notify = WlrCompositor::on_mgmt_destroy;
    wl_signal_add(&h->events.destroy, &ws.mgmt_destroy_listener);
}

// Retire nos listeners du handle (avant sa destruction, ou quand wlroots le
// détruit lui-même avec le manager) et oublie le pointeur.
static void detach_mgmt_listeners(WindowState &ws) {
    wl_list_remove(&ws.mgmt_request_activate_listener.link);
    wl_list_remove(&ws.mgmt_request_minimize_listener.link);
    wl_list_remove(&ws.mgmt_request_maximize_listener.link);
    wl_list_remove(&ws.mgmt_request_fullscreen_listener.link);
    wl_list_remove(&ws.mgmt_request_close_listener.link);
    wl_list_remove(&ws.mgmt_destroy_listener.link);
    ws.mgmt_handle = nullptr;
}

void WlrCompositor::destroy_toplevel_mgmt_handle(WindowState &ws) {
    if (!ws.mgmt_handle) {
        return;
    }
    wlr_foreign_toplevel_handle_v1 *h = ws.mgmt_handle;
    detach_mgmt_listeners(ws);
    wlr_foreign_toplevel_handle_v1_destroy(h);
}

void WlrCompositor::on_mgmt_destroy(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_destroy_listener);
    (void)data;
    detach_mgmt_listeners(*ws);
}

void WlrCompositor::on_mgmt_request_activate(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_request_activate_listener);
    (void)data;
    ws->owner->emit_signal("toplevel_request", ws->id, String("activate"), true);
}

void WlrCompositor::on_mgmt_request_minimize(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_request_minimize_listener);
    auto *event = static_cast<wlr_foreign_toplevel_handle_v1_minimized_event *>(data);
    ws->owner->emit_signal("toplevel_request", ws->id, String("minimize"), event->minimized);
}

void WlrCompositor::on_mgmt_request_maximize(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_request_maximize_listener);
    auto *event = static_cast<wlr_foreign_toplevel_handle_v1_maximized_event *>(data);
    ws->owner->emit_signal("toplevel_request", ws->id, String("maximize"), event->maximized);
}

void WlrCompositor::on_mgmt_request_fullscreen(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_request_fullscreen_listener);
    auto *event = static_cast<wlr_foreign_toplevel_handle_v1_fullscreen_event *>(data);
    ws->owner->emit_signal("toplevel_request", ws->id, String("fullscreen"), event->fullscreen);
}

void WlrCompositor::on_mgmt_request_close(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, mgmt_request_close_listener);
    (void)data;
    ws->owner->emit_signal("toplevel_request", ws->id, String("close"), true);
}

void WlrCompositor::set_toplevel_minimized(int window_id, bool minimized) {
    WindowState *ws = find_window(window_id);
    if (ws && ws->mgmt_handle) {
        wlr_foreign_toplevel_handle_v1_set_minimized(ws->mgmt_handle, minimized);
    }
}

void WlrCompositor::set_toplevel_fullscreen(int window_id, bool fullscreen) {
    WindowState *ws = find_window(window_id);
    if (ws && ws->mgmt_handle) {
        wlr_foreign_toplevel_handle_v1_set_fullscreen(ws->mgmt_handle, fullscreen);
    }
}
