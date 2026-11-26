// linux_drm_syncobj_v1 (lot M) : synchronisation explicite des buffers clients.
//
// Derrière CYBERREALM_EXPLICIT_SYNC=1 (jusqu'à validation) et seulement si le renderer gère les timelines
// (renderer->features.timeline ; le backend headless ne présente jamais de buffer client sur un écran, sa propre
// prise en charge n'entre pas en jeu et n'est que journalisée).
//   - Point d'acquisition : les rendus de capture (cap_surface.cpp, chemins vulkan / dmabuf / pixels) attendent le
//     point du client via wait_timeline / wait_point de wlr_render_pass_add_texture (apply_syncobj_wait).
//   - Chemin zéro-copie (BO du client importé tel quel dans Vulkan) : Godot ne permet pas d'attendre un sémaphore
//     dans son RenderingDevice ; une surface en synchronisation explicite passe donc par le chemin vulkan (rendu
//     wlroots qui, lui, attend le point) — surface_uses_syncobj().
//   - Point de libération : à chaque commit d'une surface qui en fournit un,
//     wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer() le signale quand wlroots relâche le buffer
//     (plus aucun verrou : remplacé par le commit suivant et plus utilisé par une capture). Sans ça, le client
//     attendrait indéfiniment ce point avant de réutiliser son buffer.

#include "wlr_compositor.h"

#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdlib>
#include <cstring>

extern "C" {
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
}

using namespace godot;

namespace godot {

struct SyncSurface {
    WlrCompositor *comp = nullptr;
    wlr_surface *surface = nullptr;
    wl_listener commit{}, destroy{};
};

static void sync_surface_commit(wl_listener *l, void *) {
    SyncSurface *s = wl_container_of(l, s, commit);
    wlr_linux_drm_syncobj_surface_v1_state *st = wlr_linux_drm_syncobj_v1_get_surface_state(s->surface);
    if (st && st->release_timeline && s->surface->buffer) {
        wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(st, &s->surface->buffer->base);
    }
}

static void sync_surface_destroy(wl_listener *l, void *) {
    SyncSurface *s = wl_container_of(l, s, destroy);
    wl_list_remove(&s->commit.link);
    wl_list_remove(&s->destroy.link);
    delete s;
}

void WlrCompositor::on_new_surface_for_sync(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_surface_sync_listener);
    auto *surface = static_cast<wlr_surface *>(data);
    SyncSurface *s = new SyncSurface();
    s->comp = self;
    s->surface = surface;
    s->commit.notify = sync_surface_commit;
    wl_signal_add(&surface->events.commit, &s->commit);
    s->destroy.notify = sync_surface_destroy;
    wl_signal_add(&surface->events.destroy, &s->destroy);
}

void WlrCompositor::setup_explicit_sync() {
    const bool renderer_ok = renderer && renderer->features.timeline;
    const bool backend_ok = backend && backend->features.timeline;
    const int drm_fd = renderer ? wlr_renderer_get_drm_fd(renderer) : -1;
    const char *env = getenv("CYBERREALM_EXPLICIT_SYNC");
    const bool wanted = env && strcmp(env, "1") == 0;
    explicit_sync_info = Dictionary();
    explicit_sync_info["renderer_timeline"] = renderer_ok;
    explicit_sync_info["backend_timeline"] = backend_ok;
    explicit_sync_info["drm_fd"] = drm_fd >= 0;
    explicit_sync_info["requested"] = wanted;
    explicit_sync_info["enabled"] = false;
    UtilityFunctions::print("waylandgodot: explicit sync — renderer timeline=", renderer_ok, " backend timeline=",
        backend_ok, " drm fd=", drm_fd >= 0, wanted ? " (CYBERREALM_EXPLICIT_SYNC=1)" : " (off: CYBERREALM_EXPLICIT_SYNC!=1)");
    if (!wanted || !renderer_ok || drm_fd < 0) {
        return;
    }
    syncobj_manager = wlr_linux_drm_syncobj_manager_v1_create(display, 1, drm_fd);
    if (!syncobj_manager) {
        UtilityFunctions::printerr("waylandgodot: failed to create wp_linux_drm_syncobj_manager_v1 global");
        return;
    }
    new_surface_sync_listener.notify = WlrCompositor::on_new_surface_for_sync;
    wl_signal_add(&compositor->events.new_surface, &new_surface_sync_listener);
    new_surface_sync_listening = true;
    explicit_sync = true;
    explicit_sync_info["enabled"] = true;
    UtilityFunctions::print("waylandgodot: wp_linux_drm_syncobj_manager_v1 announced");
}

void WlrCompositor::teardown_explicit_sync_listeners() {
    if (new_surface_sync_listening) {
        wl_list_remove(&new_surface_sync_listener.link);
        new_surface_sync_listening = false;
    }
}

bool WlrCompositor::surface_uses_syncobj(wlr_surface *surface) {
    if (!explicit_sync || !surface) return false;
    wlr_linux_drm_syncobj_surface_v1_state *st = wlr_linux_drm_syncobj_v1_get_surface_state(surface);
    return st && st->acquire_timeline;
}

void WlrCompositor::apply_syncobj_wait(wlr_surface *surface, wlr_render_texture_options &opts) {
    if (!explicit_sync || !surface) return;
    wlr_linux_drm_syncobj_surface_v1_state *st = wlr_linux_drm_syncobj_v1_get_surface_state(surface);
    if (st && st->acquire_timeline) {
        opts.wait_timeline = st->acquire_timeline;
        opts.wait_point = st->acquire_point;
    }
}

Dictionary WlrCompositor::get_explicit_sync_info() {
    return explicit_sync_info;
}

} // namespace godot
