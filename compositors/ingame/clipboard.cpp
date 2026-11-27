// Passerelle presse-papier entre Godot et les fenêtres Wayland du compositeur.
//
// Sous le DisplayServer « kms », il n'y a aucun presse-papier système : le
// patch Godot garde le texte en mémoire (clipboard_set/get). Sans pont, un
// texte copié dans l'interface du jeu (code d'invitation du menu pause…) ne
// pouvait pas être collé dans une fenêtre, et inversement.
//
//   Godot -> Wayland : _process sonde DisplayServer::clipboard_get() (lecture
//     en mémoire, peu coûteuse) ; un changement devient la sélection du seat,
//     servie par une wlr_data_source à nous.
//   Wayland -> Godot : à chaque nouvelle sélection d'un client, on lit son
//     texte par un pipe (sans bloquer la boucle) puis clipboard_set().
//
// Sous X11/Wayland hôte, Godot a déjà un vrai presse-papier : pas de pont.

#include "wlr_compositor.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cerrno>
#include <cstring>
#include <thread>
#include <fcntl.h>
#include <unistd.h>

using namespace godot;

// Accès aux membres privés depuis les rappels C de la source (friend de WlrCompositor).
namespace godot {
struct WlrCompositorClipAccess {
    static void forget(WlrCompositor *c, wlr_data_source *src) {
        if (c && c->clip_godot_source == src) c->clip_godot_source = nullptr;
    }
};
} // namespace godot

namespace {

constexpr size_t CLIP_MAX_BYTES = 4 * 1024 * 1024;
constexpr uint64_t CLIP_POLL_INTERVAL_MS = 100;

const char *const TEXT_MIMES[] = {
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
    "TEXT",
    "STRING",
};

struct GodotClipSource {
    wlr_data_source base;
    WlrCompositor *owner;
    std::string text;   // texte, ou octets PNG pour une image
};

void godot_clip_send(wlr_data_source *base, const char *, int32_t fd) {
    GodotClipSource *src = wl_container_of(base, src, base);
    // Écriture hors de la boucle Wayland : un client lent à lire ne doit pas
    // geler le jeu (le pipe ne tient que 64 Kio).
    std::string text = src->text;
    std::thread([fd, text = std::move(text)]() {
        int flags = fcntl(fd, F_GETFL);
        if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
        size_t off = 0;
        while (off < text.size()) {
            ssize_t n = write(fd, text.data() + off, text.size() - off);
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            off += (size_t)n;
        }
        close(fd);
    }).detach();
}

void godot_clip_destroy(wlr_data_source *base) {
    GodotClipSource *src = wl_container_of(base, src, base);
    WlrCompositorClipAccess::forget(src->owner, base);
    delete src;
}

const wlr_data_source_impl godot_clip_impl = {
    .send = godot_clip_send,
    .accept = nullptr,
    .destroy = godot_clip_destroy,
    .dnd_drop = nullptr,
    .dnd_finish = nullptr,
    .dnd_action = nullptr,
};

} // namespace

void WlrCompositor::clipboard_init() {
    DisplayServer *ds = DisplayServer::get_singleton();
    clip_bridge = ds && seat && ds->get_name() == "kms";
    if (!clip_bridge) return;
    clip_synced = ds->clipboard_get().utf8().get_data();
    set_selection_listener.notify = WlrCompositor::on_set_selection;
    wl_signal_add(&seat->events.set_selection, &set_selection_listener);
    set_selection_listener_added = true;
}

void WlrCompositor::clipboard_shutdown() {
    if (clip_read_source) {
        wl_event_source_remove(clip_read_source);
        clip_read_source = nullptr;
    }
    if (clip_read_fd >= 0) {
        close(clip_read_fd);
        clip_read_fd = -1;
    }
    if (set_selection_listener_added) {
        wl_list_remove(&set_selection_listener.link);
        set_selection_listener_added = false;
    }
    clip_bridge = false;
}

void WlrCompositor::clipboard_poll() {
    if (!clip_bridge || !seat || !display) return;
    uint64_t now = get_time_msec();
    if (now - clip_poll_ms < CLIP_POLL_INTERVAL_MS) return;
    clip_poll_ms = now;

    DisplayServer *ds = DisplayServer::get_singleton();
    if (!ds) return;
    std::string cur = ds->clipboard_get().utf8().get_data();
    if (cur == clip_synced) return;
    clip_synced = cur;

    // Une lecture client en cours est périmée : Godot vient d'écrire plus récent.
    if (clip_read_source) {
        wl_event_source_remove(clip_read_source);
        clip_read_source = nullptr;
    }
    if (clip_read_fd >= 0) {
        close(clip_read_fd);
        clip_read_fd = -1;
    }

    if (cur.empty()) {
        wlr_seat_set_selection(seat, nullptr, wl_display_next_serial(display));
        return;
    }
    GodotClipSource *src = new GodotClipSource();
    wlr_data_source_init(&src->base, &godot_clip_impl);
    src->owner = this;
    src->text = std::move(cur);
    for (const char *mime : TEXT_MIMES) {
        char **slot = (char **)wl_array_add(&src->base.mime_types, sizeof(char *));
        if (slot) *slot = strdup(mime);
    }
    clip_godot_source = &src->base;
    // set_selection détruit l'ancienne source (y compris une des nôtres).
    wlr_seat_set_selection(seat, &src->base, wl_display_next_serial(display));
}

// Capture d'écran -> presse-papier : source « image/png » servie par nous.
// Fonctionne quel que soit le DisplayServer (la sélection du seat est celle
// des fenêtres du jeu) ; le presse-papier texte de Godot n'est pas touché,
// donc clipboard_poll ne remplace pas l'image tant que Godot ne copie rien.
void WlrCompositor::clipboard_set_image_png(const PackedByteArray &png) {
    if (!seat || !display || png.is_empty()) return;
    if (clip_read_source) {
        wl_event_source_remove(clip_read_source);
        clip_read_source = nullptr;
    }
    if (clip_read_fd >= 0) {
        close(clip_read_fd);
        clip_read_fd = -1;
    }
    GodotClipSource *src = new GodotClipSource();
    wlr_data_source_init(&src->base, &godot_clip_impl);
    src->owner = this;
    src->text.assign((const char *)png.ptr(), (size_t)png.size());
    char **slot = (char **)wl_array_add(&src->base.mime_types, sizeof(char *));
    if (slot) *slot = strdup("image/png");
    clip_godot_source = &src->base;
    wlr_seat_set_selection(seat, &src->base, wl_display_next_serial(display));
}

void WlrCompositor::on_set_selection(wl_listener *listener, void *) {
    WlrCompositor *self = wl_container_of(listener, self, set_selection_listener);
    if (!self->clip_bridge || !self->seat || !self->event_loop) return;
    wlr_data_source *source = self->seat->selection_source;
    if (!source || source == self->clip_godot_source) return;

    const char *mime = nullptr;
    for (const char *want : TEXT_MIMES) {
        char **types = (char **)source->mime_types.data;
        size_t count = source->mime_types.size / sizeof(char *);
        for (size_t i = 0; i < count; i++) {
            if (types[i] && strcmp(types[i], want) == 0) { mime = want; break; }
        }
        if (mime) break;
    }
    if (!mime) return;   // image, fichiers… : rien à mettre dans Godot

    // Abandonner une lecture précédente : seule la dernière sélection compte.
    if (self->clip_read_source) {
        wl_event_source_remove(self->clip_read_source);
        self->clip_read_source = nullptr;
    }
    if (self->clip_read_fd >= 0) {
        close(self->clip_read_fd);
        self->clip_read_fd = -1;
    }

    int fds[2];
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) return;
    wlr_data_source_send(source, mime, fds[1]);   // ferme fds[1]
    self->clip_read_fd = fds[0];
    self->clip_read_buf.clear();
    self->clip_read_source = wl_event_loop_add_fd(self->event_loop, fds[0],
        WL_EVENT_READABLE, WlrCompositor::on_clip_readable, self);
    if (!self->clip_read_source) {
        close(fds[0]);
        self->clip_read_fd = -1;
    }
}

int WlrCompositor::on_clip_readable(int fd, uint32_t mask, void *data) {
    WlrCompositor *self = (WlrCompositor *)data;
    char buf[8192];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            if (self->clip_read_buf.size() + (size_t)n > CLIP_MAX_BYTES) {
                self->clipboard_finish_read(false);
                return 0;
            }
            self->clip_read_buf.append(buf, (size_t)n);
            continue;
        }
        if (n == 0) {
            self->clipboard_finish_read(true);
            return 0;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) self->clipboard_finish_read(true);
            return 0;
        }
        self->clipboard_finish_read(false);
        return 0;
    }
}

void WlrCompositor::clipboard_finish_read(bool ok) {
    if (clip_read_source) {
        wl_event_source_remove(clip_read_source);
        clip_read_source = nullptr;
    }
    if (clip_read_fd >= 0) {
        close(clip_read_fd);
        clip_read_fd = -1;
    }
    std::string text;
    text.swap(clip_read_buf);
    if (!ok || !clip_bridge) return;
    DisplayServer *ds = DisplayServer::get_singleton();
    if (!ds) return;
    clip_synced = text;   // éviter que clipboard_poll le renvoie comme nouvelle source
    ds->clipboard_set(String::utf8(text.data(), (int)text.size()));
}
