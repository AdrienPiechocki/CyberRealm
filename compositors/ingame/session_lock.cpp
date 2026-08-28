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

bool WlrCompositor::session_lock_active() const {
    return session_lock.lock != nullptr;
}
SessionLockSurfaceState *WlrCompositor::get_active_lock_surface() {
    for (auto &pair : session_lock.surfaces) {
        SessionLockSurfaceState &ss = pair.second;
        if (ss.lock_surface && ss.lock_surface->surface &&
            ss.lock_surface->surface->mapped) {
            return &ss;
        }
    }
    return nullptr;
}
void WlrCompositor::on_new_session_lock(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_session_lock_listener);
    auto *lock = static_cast<wlr_session_lock_v1 *>(data);

    // Le protocole interdit de demander un second verrou pendant qu'un
    // autre est actif ; si un client le fait quand même, on finit l'ancien
    // (cela détruit ses surfaces et vide session_lock.surfaces) avant de
    // prendre le nouveau.
    if (self->session_lock.lock) {
        wlr_session_lock_v1_destroy(self->session_lock.lock);
    }

    self->session_lock.lock = lock;
    self->session_lock.locked_sent = false;
    self->session_lock.surfaces.clear();
    self->session_lock.next_surface_id = 1;

    self->session_lock.new_surface_listener.notify = WlrCompositor::on_session_lock_new_surface;
    wl_signal_add(&lock->events.new_surface, &self->session_lock.new_surface_listener);

    self->session_lock.unlock_listener.notify = WlrCompositor::on_session_lock_unlock;
    wl_signal_add(&lock->events.unlock, &self->session_lock.unlock_listener);

    self->session_lock.destroy_listener.notify = WlrCompositor::on_session_lock_destroy;
    wl_signal_add(&lock->events.destroy, &self->session_lock.destroy_listener);

    UtilityFunctions::print("waylandgodot: session lock demandé");
}
void WlrCompositor::on_session_lock_new_surface(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, session_lock.new_surface_listener);
    auto *lock_surface = static_cast<wlr_session_lock_surface_v1 *>(data);

    if (!lock_surface->output) {
        lock_surface->output = self->headless_output;
    }

    int id = self->session_lock.next_surface_id++;
    SessionLockSurfaceState &ss = self->session_lock.surfaces[id];
    ss.id = id;
    ss.lock_surface = lock_surface;
    ss.owner = self;

    ss.map_listener.notify = WlrCompositor::on_session_lock_surface_map;
    wl_signal_add(&lock_surface->surface->events.map, &ss.map_listener);

    ss.unmap_listener.notify = WlrCompositor::on_session_lock_surface_unmap;
    wl_signal_add(&lock_surface->surface->events.unmap, &ss.unmap_listener);

    ss.destroy_listener.notify = WlrCompositor::on_session_lock_surface_destroy;
    wl_signal_add(&lock_surface->events.destroy, &ss.destroy_listener);

    ss.commit_listener.notify = WlrCompositor::on_session_lock_surface_commit;
    wl_signal_add(&lock_surface->surface->events.commit, &ss.commit_listener);

    // Pleine surface de l'output : le lockscreen quickshell attend ce
    // configure (avec les dimensions de l'écran) avant de committer.
    wlr_session_lock_surface_v1_configure(lock_surface, self->output_width, self->output_height);

    UtilityFunctions::print("waylandgodot: session lock surface id=", id);
}
void WlrCompositor::on_session_lock_surface_map(wl_listener *listener, void *data) {
    SessionLockSurfaceState *ss = wl_container_of(listener, ss, map_listener);
    WlrCompositor *self = ss->owner;
    if (!self->seat || !ss->lock_surface) return;

    // Le lockscreen détient tout l'input : focus clavier sur sa surface
    // (le champ password en a besoin), le pointeur y est envoyé en continu
    // par le script Godot tant que le session est verrouillée.
    self->keyboard_focus_layer_id = -1;
    wlr_seat_keyboard_notify_enter(self->seat, ss->lock_surface->surface,
        self->virtual_keyboard.keycodes,
        self->virtual_keyboard.num_keycodes,
        &self->virtual_keyboard.modifiers);

    if (self->capture_surface(ss->lock_surface->surface, ss->texture,
            ss->width, ss->height, ss->capture_cache)) {
        self->emit_signal("session_lock_surface_texture_updated",
            ss->id, ss->texture, ss->width, ss->height);
    }

    // Une fois une surface mappée, on peut annoncer "locked" au client :
    // c'est ce qui lui autorise unlock_and_destroy (le password submit).
    if (self->session_lock.lock && !self->session_lock.locked_sent) {
        self->session_lock.locked_sent = true;
        wlr_session_lock_v1_send_locked(self->session_lock.lock);
        UtilityFunctions::print("waylandgodot: session verrouillée (locked envoyé)");
    }

    self->emit_signal("session_lock_locked");
}
void WlrCompositor::on_session_lock_surface_unmap(wl_listener *listener, void *data) {
    SessionLockSurfaceState *ss = wl_container_of(listener, ss, unmap_listener);
    // La texture reste affichée côté Godot (le unlock détruit ensuite la
    // surface, ce qui la masquera proprement).
}
void WlrCompositor::on_session_lock_surface_destroy(wl_listener *listener, void *data) {
    SessionLockSurfaceState *ss = wl_container_of(listener, ss, destroy_listener);
    WlrCompositor *self = ss->owner;
    int id = ss->id;

    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    ss->capture_cache.reset(rd);

    wl_list_remove(&ss->map_listener.link);
    wl_list_remove(&ss->unmap_listener.link);
    wl_list_remove(&ss->destroy_listener.link);
    wl_list_remove(&ss->commit_listener.link);

    self->session_lock.surfaces.erase(id);
}
void WlrCompositor::on_session_lock_surface_commit(wl_listener *listener, void *data) {
    SessionLockSurfaceState *ss = wl_container_of(listener, ss, commit_listener);
    WlrCompositor *self = ss->owner;
    if (!ss->lock_surface || !ss->lock_surface->surface) return;

    if (!self->capture_surface(ss->lock_surface->surface, ss->texture,
            ss->width, ss->height, ss->capture_cache)) {
        return;
    }
    self->emit_signal("session_lock_surface_texture_updated",
        ss->id, ss->texture, ss->width, ss->height);
}
void WlrCompositor::on_session_lock_unlock(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, session_lock.unlock_listener);

    // Rendre le focus clavier à la fenêtre active s'il en existe une.
    if (self->seat && self->active_toplevel_id != -1) {
        if (WindowState *ws = self->find_window(self->active_toplevel_id)) {
            wlr_seat_keyboard_notify_enter(self->seat, ws->toplevel->base->surface,
                self->virtual_keyboard.keycodes,
                self->virtual_keyboard.num_keycodes,
                &self->virtual_keyboard.modifiers);
        }
    }

    // Le client détruit ensuite le lock et ses surfaces ; le script Godot
    // masque l'overlay du lockscreen dès ce signal.
    self->emit_signal("session_lock_unlocked");
}
void WlrCompositor::on_session_lock_destroy(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, session_lock.destroy_listener);

    // lock_destroy a déjà détruit toutes les surfaces (chaque destroy a
    // vidé session_lock.surfaces via on_session_lock_surface_destroy).
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    for (auto &pair : self->session_lock.surfaces) {
        pair.second.capture_cache.reset(rd);
    }
    self->session_lock.surfaces.clear();

    wl_list_remove(&self->session_lock.new_surface_listener.link);
    wl_list_remove(&self->session_lock.unlock_listener.link);
    wl_list_remove(&self->session_lock.destroy_listener.link);

    self->session_lock.lock = nullptr;
    self->session_lock.locked_sent = false;
    UtilityFunctions::print("waylandgodot: session lock détruit");
}
