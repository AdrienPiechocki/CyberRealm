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

void WlrCompositor::on_request_start_drag(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, request_start_drag_listener);
    if (!self->seat) return;
    wlr_seat_request_start_drag_event *event = (wlr_seat_request_start_drag_event *)data;

    static const bool dbg = getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    if (dbg) {
        fprintf(stderr, "waylandgodot: request_start_drag serial=%u drag_serial=%u focused=%p origin=%p "
            "origin_is_window=%d\n",
            event->serial, self->seat->pointer_state.grab_serial,
            (void *)self->seat->pointer_state.focused_surface,
            (void *)event->origin,
            event->origin ? (wlr_xdg_surface_try_from_wlr_surface(event->origin) != nullptr) : 0);
    }

    if (wlr_seat_validate_pointer_grab_serial(self->seat, event->origin, event->serial)) {
        wlr_seat_start_pointer_drag(self->seat, event->drag, event->serial);
        return;
    }

    struct wlr_touch_point *point;
    if (wlr_seat_validate_touch_grab_serial(self->seat, event->origin, event->serial, &point)) {
        wlr_seat_start_touch_drag(self->seat, event->drag, event->serial, point);
        return;
    }

    UtilityFunctions::print("waylandgodot: ignoring drag request, serial ", event->serial, " not valid");
}
void WlrCompositor::on_start_drag(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, start_drag_listener);
    wlr_drag *drag = (wlr_drag *)data;

    static const bool dbg = getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    if (dbg) {
        fprintf(stderr, "waylandgodot: drag STARTED icon=%p\n", (void *)(drag->icon ? drag->icon->surface : nullptr));
    }

    self->active_drag = drag;

    if (drag->icon && drag->icon->surface) {
        RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
        self->drag_icon_cache.reset(rd);
    }

    self->drag_destroy_listener.notify = WlrCompositor::on_drag_destroy;
    wl_signal_add(&drag->events.destroy, &self->drag_destroy_listener);
}
void WlrCompositor::on_drag_destroy(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, drag_destroy_listener);
    wl_list_remove(&self->drag_destroy_listener.link);
    self->active_drag = nullptr;
    self->drag_icon_texture = Ref<Texture2D>();
    self->drag_icon_width = 0;
    self->drag_icon_height = 0;
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    self->drag_icon_cache.reset(rd);
    self->emit_signal("drag_icon_removed");
}
#define FILE_DROP_URI_MIME "text/uri-list"
#define FILE_DROP_READ_TIMEOUT_MS 1000

bool WlrCompositor::extract_file_drop_start() {
    wlr_data_source *source = seat->drag->source;

    bool has_uris = false;
    char **mimes = (char **)source->mime_types.data;
    size_t mime_count = source->mime_types.size / sizeof(char *);
    for (size_t i = 0; i < mime_count; i++) {
        if (strcmp(mimes[i], FILE_DROP_URI_MIME) == 0) {
            has_uris = true;
            break;
        }
    }
    if (!has_uris) {
        return false; // pas des fichiers : comportement historique (annulation)
    }

    int fds[2];
    if (pipe(fds) != 0) {
        return false;
    }
    // La requête send part AVANT toute notification du relâchement : le
    // client verra .send puis .cancelled dans cet ordre.
    wlr_data_source_send(source, FILE_DROP_URI_MIME, fds[1]);
    close(fds[1]);

    const uint32_t time_msec = get_time_msec();
    const int button = (int)seat->pointer_state.grab_button;
    const int read_fd = fds[0];
    auto guard = alive_guard;

    std::thread([this, guard, read_fd, time_msec, button]() {
        std::string data;
        char buf[4096];
        const auto deadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(FILE_DROP_READ_TIMEOUT_MS);
        for (;;) {
            const auto now = std::chrono::steady_clock::now();
            long remain_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - now).count();
            if (remain_ms <= 0) break;
            pollfd p{};
            p.fd = read_fd;
            p.events = POLLIN;
            if (::poll(&p, 1, (int)remain_ms) <= 0) break;
            ssize_t r = ::read(read_fd, buf, sizeof(buf));
            if (r > 0) {
                data.append(buf, (size_t)r);
                continue; // EOF uniquement quand la source ferme son fd
            }
            break;
        }
        ::close(read_fd);

        PackedStringArray paths;
        size_t pos = 0;
        while (pos < data.size()) {
            size_t eol = data.find('\n', pos);
            if (eol == std::string::npos) eol = data.size();
            std::string line = data.substr(pos, eol - pos);
            pos = eol + 1;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            const std::string prefix = "file://";
            if (line.compare(0, prefix.size(), prefix) != 0) continue;
            std::string rest = line.substr(prefix.size());
            // file:///chemin → /chemin ; file://localhost/… accepté ; tout
            // autre hôte n'est pas un chemin local.
            if (!rest.empty() && rest[0] != '/') {
                size_t slash = rest.find('/');
                if (slash == std::string::npos || rest.substr(0, slash) != "localhost") {
                    continue;
                }
                rest = rest.substr(slash);
            }
            // Décodage %XX (%20 pour les espaces, %2F…).
            std::string decoded;
            for (size_t i = 0; i < rest.size(); i++) {
                if (rest[i] == '%' && i + 2 < rest.size() &&
                        isxdigit((unsigned char)rest[i + 1]) &&
                        isxdigit((unsigned char)rest[i + 2])) {
                    auto hexval = [](char c) -> int {
                        c |= 0x20; // minuscule
                        return c <= '9' ? c - '0' : c - 'a' + 10;
                    };
                    decoded += (char)((hexval(rest[i + 1]) << 4) | hexval(rest[i + 2]));
                    i += 2;
                } else {
                    decoded += rest[i];
                }
            }
            // String(const char*) interprète octet par octet (Latin-1) :
            // « é » devient « Ã© ». Il faut décoder l'UTF-8 explicitement.
            paths.append(String::utf8(decoded.c_str(), (int64_t)decoded.size()));
        }

        if (!guard->load()) return;
        call_deferred("_finish_file_drop", paths, time_msec, button);
    }).detach();
    return true;
}
void WlrCompositor::_finish_file_drop(PackedStringArray paths, uint32_t time_msec,
        int button) {
    static const bool dbg_drop =
        getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    if (dbg_drop) {
        UtilityFunctions::print("waylandgodot: file_drop n=", paths.size());
        for (int i = 0; i < paths.size(); i++) {
            UtilityFunctions::print("waylandgodot:   path[", i, "]=", paths[i]);
        }
    }
    if (!paths.is_empty()) {
        emit_signal("file_drop_received", paths);
    }
    if (!seat) return;
    wlr_seat_pointer_notify_button(seat, time_msec, (uint32_t)button,
        WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::on_request_set_selection(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, request_set_selection_listener);
    if (!self->seat) return;
    wlr_seat_request_set_selection_event *event = (wlr_seat_request_set_selection_event *)data;
    wlr_seat_set_selection(self->seat, event->source, event->serial);
}
void WlrCompositor::on_request_set_primary_selection(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, request_set_primary_selection_listener);
    if (!self->seat) return;
    wlr_seat_request_set_primary_selection_event *event = (wlr_seat_request_set_primary_selection_event *)data;
    wlr_seat_set_primary_selection(self->seat, event->source, event->serial);
}
bool WlrCompositor::is_drag_active() const {
    return active_drag != nullptr;
}
