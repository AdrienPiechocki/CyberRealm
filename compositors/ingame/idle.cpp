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

void WlrCompositor::notify_activity() {
    if (idle_notifier && seat) {
        wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
    }
}
void WlrCompositor::update_idle_inhibited() {
    bool inhibited = false;
    for (auto &pair : idle_inhibitors) {
        IdleInhibitorState &state = pair.second;
        if (state.inhibitor && state.inhibitor->surface &&
            state.inhibitor->surface->mapped) {
            inhibited = true;
            break;
        }
    }
    if (idle_notifier) {
        wlr_idle_notifier_v1_set_inhibited(idle_notifier, inhibited);
    }
}
void WlrCompositor::on_new_idle_inhibitor(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_idle_inhibitor_listener);
    auto *inhibitor = static_cast<wlr_idle_inhibitor_v1 *>(data);
    UtilityFunctions::print("[idle] NEW inhibitor, surface mapped=", inhibitor->surface->mapped);

    IdleInhibitorState &state = self->idle_inhibitors[inhibitor];
    state.inhibitor = inhibitor;
    state.owner = self;

    state.destroy_listener.notify = WlrCompositor::on_idle_inhibitor_destroy;
    wl_signal_add(&inhibitor->events.destroy, &state.destroy_listener);

    state.surface_map_listener.notify = WlrCompositor::on_idle_inhibitor_surface_map;
    wl_signal_add(&inhibitor->surface->events.map, &state.surface_map_listener);

    state.surface_unmap_listener.notify = WlrCompositor::on_idle_inhibitor_surface_unmap;
    wl_signal_add(&inhibitor->surface->events.unmap, &state.surface_unmap_listener);

    self->update_idle_inhibited();
}
void WlrCompositor::on_idle_inhibitor_destroy(wl_listener *listener, void *data) {
    IdleInhibitorState *state = wl_container_of(listener, state, destroy_listener);
    WlrCompositor *self = state->owner;
    UtilityFunctions::print("[idle] inhibitor DESTROYED, remaining=", self->idle_inhibitors.size() - 1);

    wl_list_remove(&state->destroy_listener.link);
    wl_list_remove(&state->surface_map_listener.link);
    wl_list_remove(&state->surface_unmap_listener.link);

    self->idle_inhibitors.erase(state->inhibitor);
    self->update_idle_inhibited();
}
void WlrCompositor::on_idle_inhibitor_surface_map(wl_listener *listener, void *data) {
    IdleInhibitorState *state = wl_container_of(listener, state, surface_map_listener);
    (void)data;
    state->owner->update_idle_inhibited();
}
void WlrCompositor::on_idle_inhibitor_surface_unmap(wl_listener *listener, void *data) {
    IdleInhibitorState *state = wl_container_of(listener, state, surface_unmap_listener);
    (void)data;
    state->owner->update_idle_inhibited();
}
