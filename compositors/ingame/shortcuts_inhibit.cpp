// zwp_keyboard_shortcuts_inhibit_v1 : une VM, remote-viewer, un client de
// bureau à distance… demande à recevoir les raccourcis (Super, Alt+Tab…).
//
// Politique : un inhibiteur n'est ACTIF que si
//   1. le jeu a désigné sa fenêtre (set_shortcuts_inhibit_window : la fenêtre
//      en mode focus, si l'option du menu pause l'autorise),
//   2. et cette fenêtre a le focus clavier du seat.
// En 3D le jeu a besoin de ses touches : il ne désigne aucune fenêtre. Le jeu
// lit is_shortcuts_inhibited() pour court-circuiter ses propres raccourcis ;
// shortcuts_inhibit_changed(window_id, active) lui sert à prévenir le joueur.

#include "wlr_compositor.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>

using namespace godot;

void WlrCompositor::on_new_shortcuts_inhibitor(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_shortcuts_inhibitor_listener);
    auto *inhibitor = static_cast<wlr_keyboard_shortcuts_inhibitor_v1 *>(data);
    if (inhibitor->seat != self->seat) {
        return; // un seul seat dans le jeu ; un autre ne peut pas exister
    }
    auto *st = new ShortcutsInhibitorState();
    st->inhibitor = inhibitor;
    st->owner = self;
    st->destroy_listener.notify = WlrCompositor::on_shortcuts_inhibitor_destroy;
    wl_signal_add(&inhibitor->events.destroy, &st->destroy_listener);
    self->shortcuts_inhibitors.push_back(st);
    UtilityFunctions::print("waylandgodot: shortcuts inhibitor requested by window ",
        self->window_id_for_surface(inhibitor->surface));
    self->update_shortcuts_inhibitors();
}

void WlrCompositor::on_shortcuts_inhibitor_destroy(wl_listener *listener, void *data) {
    ShortcutsInhibitorState *st = wl_container_of(listener, st, destroy_listener);
    (void)data;
    WlrCompositor *self = st->owner;
    wl_list_remove(&st->destroy_listener.link);
    auto &v = self->shortcuts_inhibitors;
    v.erase(std::remove(v.begin(), v.end(), st), v.end());
    delete st;
    self->update_shortcuts_inhibitors();
}

void WlrCompositor::update_shortcuts_inhibitors() {
    int focused = keyboard_focus_window_id();
    int active_window = -1;
    for (ShortcutsInhibitorState *st : shortcuts_inhibitors) {
        wlr_keyboard_shortcuts_inhibitor_v1 *inh = st->inhibitor;
        int wid = window_id_for_surface(inh->surface);
        bool want = wid != -1 && wid == shortcuts_inhibit_window_id && wid == focused;
        if (want && !inh->active) {
            wlr_keyboard_shortcuts_inhibitor_v1_activate(inh);
        } else if (!want && inh->active) {
            wlr_keyboard_shortcuts_inhibitor_v1_deactivate(inh);
        }
        if (want) {
            active_window = wid;
        }
    }
    // Destruction en cours : état interne seulement, aucun signal.
    bool can_emit = alive_guard && alive_guard->load();
    if (active_window != shortcuts_inhibit_active_window_id && !can_emit) {
        shortcuts_inhibit_active_window_id = active_window;
        return;
    }
    if (active_window != shortcuts_inhibit_active_window_id) {
        int previous = shortcuts_inhibit_active_window_id;
        shortcuts_inhibit_active_window_id = active_window;
        if (previous != -1) {
            emit_signal("shortcuts_inhibit_changed", previous, false);
        }
        if (active_window != -1) {
            emit_signal("shortcuts_inhibit_changed", active_window, true);
        }
    }
}

void WlrCompositor::set_shortcuts_inhibit_window(int window_id) {
    if (window_id == shortcuts_inhibit_window_id) {
        return;
    }
    shortcuts_inhibit_window_id = window_id;
    update_shortcuts_inhibitors();
}

bool WlrCompositor::is_shortcuts_inhibited() const {
    return shortcuts_inhibit_active_window_id != -1;
}

bool WlrCompositor::window_requests_shortcuts_inhibit(int window_id) {
    for (ShortcutsInhibitorState *st : shortcuts_inhibitors) {
        if (window_id_for_surface(st->inhibitor->surface) == window_id) {
            return true;
        }
    }
    return false;
}
