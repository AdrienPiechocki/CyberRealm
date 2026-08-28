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

static const std::unordered_map<int, uint32_t> GODOT_TO_EVDEV = {
    {(int)Key::KEY_ESCAPE, 1},
    {(int)Key::KEY_1, 2}, {(int)Key::KEY_2, 3}, {(int)Key::KEY_3, 4},
    {(int)Key::KEY_4, 5}, {(int)Key::KEY_5, 6}, {(int)Key::KEY_6, 7},
    {(int)Key::KEY_7, 8}, {(int)Key::KEY_8, 9}, {(int)Key::KEY_9, 10},
    {(int)Key::KEY_0, 11},
    {(int)Key::KEY_MINUS, 12}, {(int)Key::KEY_EQUAL, 13},
    {(int)Key::KEY_BACKSPACE, 14}, {(int)Key::KEY_TAB, 15},
    {(int)Key::KEY_Q, 16}, {(int)Key::KEY_W, 17}, {(int)Key::KEY_E, 18},
    {(int)Key::KEY_R, 19}, {(int)Key::KEY_T, 20}, {(int)Key::KEY_Y, 21},
    {(int)Key::KEY_U, 22}, {(int)Key::KEY_I, 23}, {(int)Key::KEY_O, 24},
    {(int)Key::KEY_P, 25},
    {(int)Key::KEY_BRACKETLEFT, 26}, {(int)Key::KEY_BRACKETRIGHT, 27},
    {(int)Key::KEY_ENTER, 28}, {(int)Key::KEY_CTRL, 29},
    {(int)Key::KEY_A, 30}, {(int)Key::KEY_S, 31}, {(int)Key::KEY_D, 32},
    {(int)Key::KEY_F, 33}, {(int)Key::KEY_G, 34}, {(int)Key::KEY_H, 35},
    {(int)Key::KEY_J, 36}, {(int)Key::KEY_K, 37}, {(int)Key::KEY_L, 38},
    {(int)Key::KEY_SEMICOLON, 39}, {(int)Key::KEY_APOSTROPHE, 40},
    {(int)Key::KEY_QUOTELEFT, 86}, // Touche ISO (xkb 94) : '<' / '>' sur AZERTY, '\' sur US
    {(int)Key::KEY_SHIFT, 42},
    {(int)Key::KEY_BACKSLASH, 43},
    {(int)Key::KEY_Z, 44}, {(int)Key::KEY_X, 45}, {(int)Key::KEY_C, 46},
    {(int)Key::KEY_V, 47}, {(int)Key::KEY_B, 48}, {(int)Key::KEY_N, 49},
    {(int)Key::KEY_M, 50},
    {(int)Key::KEY_COMMA, 51}, {(int)Key::KEY_PERIOD, 52}, {(int)Key::KEY_SLASH, 53},
    {(int)Key::KEY_ALT, 56},
    {(int)Key::KEY_SPACE, 57},
    {(int)Key::KEY_CAPSLOCK, 58},
    {(int)Key::KEY_F1, 59}, {(int)Key::KEY_F2, 60}, {(int)Key::KEY_F3, 61},
    {(int)Key::KEY_F4, 62}, {(int)Key::KEY_F5, 63}, {(int)Key::KEY_F6, 64},
    {(int)Key::KEY_F7, 65}, {(int)Key::KEY_F8, 66}, {(int)Key::KEY_F9, 67},
    {(int)Key::KEY_F10, 68}, {(int)Key::KEY_F11, 87}, {(int)Key::KEY_F12, 88},
    {(int)Key::KEY_HOME, 102}, {(int)Key::KEY_UP, 103}, {(int)Key::KEY_PAGEUP, 104},
    {(int)Key::KEY_LEFT, 105}, {(int)Key::KEY_RIGHT, 106}, {(int)Key::KEY_END, 107},
    {(int)Key::KEY_DOWN, 108}, {(int)Key::KEY_PAGEDOWN, 109},
    {(int)Key::KEY_INSERT, 110}, {(int)Key::KEY_DELETE, 111},
    {(int)Key::KEY_META, 125},
    {(int)Key::KEY_MENU, 139},
    {(int)Key::KEY_LESS, 86},
    {(int)Key::KEY_GREATER, 86}, // '<' et '>' partagent la même touche physique (86/ISO) ; le décalage Shift est porté par l'état xkb.
    {(int)Key::KEY_SECTION, 41}, // '²' sur AZERTY / backquote sur US (xkb 49)
    // Touche AZERTY '^'/'¨' (physique US '[') = evdev 26. Godot rapporte le
    // keysym du layout actif comme physical_keycode (comme '<'/'>'→KEY_LESS) :
    // sur AZERTY c'est dead_circumflex / dead_diaeresis, pas KEY_BRACKETLEFT.
    // Valeurs en dur (keysyms X11, stables) : l'enum Key exposée par
    // GDExtension ne contient pas KEY_DEAD_* ni KEY_DIAERESIS.
    {(int)Key::KEY_ASCIICIRCUM, 26},
    {132, 26},     // KEY_DIAERESIS (0x84, XK_diaeresis)
    {65106, 26},   // KEY_DEAD_CIRCUMFLEX (0xfe52) : '^'
    {65111, 26},   // KEY_DEAD_DIAERESIS (0xfe57) : '¨' (Shift+^)
    // Touche AZERTY '$'/'£'/'¤' (physique US ']') = evdev 27. Idem remarque
    // ci-dessus : le keysym du layout actif arrive en physical_keycode.
    // Observé sur le terrain (logs CYBERREALM_INPUT_DEBUG) : physical=125
    // (KEY_BRACERIGHT, symbole US shifté de la position) et keycode=36
    // (KEY_DOLLAR). Pas de Key::KEY_STERLING/CURRENCY dans l'enum
    // GDExtension → valeurs X11 en dur ('£' = 0xa3, '¤' = 0xa4).
    {(int)Key::KEY_BRACERIGHT, 27},
    {(int)Key::KEY_DOLLAR, 27},
    {163, 27},     // XK_sterling : '£' (Shift+$)
    {164, 27},     // XK_currency : '¤' (AltGr+$)
    {(int)Key::KEY_NUMLOCK, 69},
    // Numpad (fallback when keycode is already KP_*)
    {(int)Key::KEY_KP_0, 82}, {(int)Key::KEY_KP_1, 79},
    {(int)Key::KEY_KP_2, 80}, {(int)Key::KEY_KP_3, 81},
    {(int)Key::KEY_KP_4, 75}, {(int)Key::KEY_KP_5, 76},
    {(int)Key::KEY_KP_6, 77}, {(int)Key::KEY_KP_7, 71},
    {(int)Key::KEY_KP_8, 72}, {(int)Key::KEY_KP_9, 73},
    {(int)Key::KEY_KP_PERIOD, 83},
    {(int)Key::KEY_KP_ADD, 78},
    {(int)Key::KEY_KP_SUBTRACT, 74},
    {(int)Key::KEY_KP_MULTIPLY, 55},
    {(int)Key::KEY_KP_DIVIDE, 98},
    {(int)Key::KEY_KP_ENTER, 96},
};
static const std::unordered_map<int, uint32_t> NUMPAD_EVDEV = {
    {(int)Key::KEY_0, 82}, {(int)Key::KEY_1, 79},
    {(int)Key::KEY_2, 80}, {(int)Key::KEY_3, 81},
    {(int)Key::KEY_4, 75}, {(int)Key::KEY_5, 76},
    {(int)Key::KEY_6, 77}, {(int)Key::KEY_7, 71},
    {(int)Key::KEY_8, 72}, {(int)Key::KEY_9, 73},
    {(int)Key::KEY_PERIOD, 83},
    {(int)Key::KEY_SLASH, 98},
    {(int)Key::KEY_ASTERISK, 55},
    {(int)Key::KEY_MINUS, 74},
    {(int)Key::KEY_EQUAL, 78}, // numpad + (unshifted =)
    {(int)Key::KEY_ENTER, 96},
};
void WlrCompositor::on_keyboard_key(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, keyboard_key_listener);
    auto *event = static_cast<wlr_keyboard_key_event *>(data);
    wlr_seat_set_keyboard(self->seat, &self->virtual_keyboard);
    wlr_seat_keyboard_notify_key(self->seat, event->time_msec, event->keycode, event->state);
}
void WlrCompositor::on_keyboard_modifiers(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, keyboard_modifiers_listener);
    wlr_seat_set_keyboard(self->seat, &self->virtual_keyboard);
    wlr_seat_keyboard_notify_modifiers(self->seat, &self->virtual_keyboard.modifiers);
}
void WlrCompositor::notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y) {
    if (!surface || !seat) return;
    uint32_t time = get_time_msec();

    static const bool dbg = getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    if (dbg && seat->drag) {
        wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
        fprintf(stderr, "waylandgodot: drag motion -> surface=%p xdg=%p role=%d focus=%p\n",
            (void *)surface, (void *)xdg,
            xdg ? (int)xdg->role : -1,
            (void *)seat->drag->focus);
    }
    if (dbg && seat->pointer_state.button_count > 0 && !seat->drag) {
        wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
        fprintf(stderr, "waylandgodot: motion held -> surface=%p xdg=%p role=%d focused=%d\n",
            (void *)surface, (void *)xdg,
            xdg ? (int)xdg->role : -1,
            (int)(seat->pointer_state.focused_surface == surface));
    }

    // Tant qu'un bouton est enfoncé (le clic qui vient d'ouvrir un menu,
    // grab implicite), ne pas déplacer le focus pointeur vers un popup :
    // entrer le popup pendant le clic est interprété par GTK/Firefox comme
    // une violation de grab et ferme le menu à l'instant de l'enter (même
    // bug corrigé dans mutter, "wayland: Do not force pointer focus on
    // popups"). Le focus bougera vers le popup au mouvement suivant, une
    // fois le bouton relâché.
    // IMPORTANT : ce garde ne doit PAS s'appliquer si le focus pointeur est
    // déjà sur ce popup (seul un ENTER vers un popup non focusé pendant un
    // clic ferme le menu) : sans lui, un drag-and-drop initié depuis un popup
    // (ex. glisser un marque-page Firefox) serait impossible — les mouvements
    // pendant le maintien du bouton seraient avalés et le client verrait un
    // simple clic (il ne peut pas lancer start_drag sans mouvement).
    // EXCEPTION : pendant un drag actif (wl_data_device), il n'y a plus de
    // grab popup (le grab drag l'a remplacé) et entrer les popups doit être
    // permis pour que la cible de drop puisse être un popup.
    if (seat->pointer_state.focused_surface != surface &&
        seat->pointer_state.button_count > 0 && !seat->drag) {
        wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
        if (xdg && xdg->role == WLR_XDG_SURFACE_ROLE_POPUP) {
            return;
        }
    }

    if (seat->pointer_state.focused_surface != surface) {
        wlr_seat_pointer_notify_enter(seat, surface, surface_x, surface_y);
    }
    wlr_seat_pointer_notify_motion(seat, time, surface_x, surface_y);
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_motion(int window_id, double surface_x, double surface_y) {
    notify_activity();
    WindowState *ws = find_window(window_id);
    if (!ws) return;
    notify_pointer_motion_on_surface(ws->toplevel->base->surface, surface_x, surface_y);
}
void WlrCompositor::forward_pointer_motion_popup(int popup_id, double surface_x, double surface_y) {
    notify_activity();
    PopupState *ps = find_popup(popup_id);
    if (!ps) return;
    notify_pointer_motion_on_surface(ps->popup->base->surface, surface_x, surface_y);
}
void WlrCompositor::release_stale_button(uint32_t button) {
    if (!seat) return;
    for (size_t i = 0; i < seat->pointer_state.button_count; i++) {
        struct wlr_seat_pointer_button *b = &seat->pointer_state.buttons[i];
        if (b->button == button && b->n_pressed > 0) {
            wlr_seat_pointer_notify_button(seat, get_time_msec(), button,
                WL_POINTER_BUTTON_STATE_RELEASED);
            wlr_seat_pointer_notify_frame(seat);
            return;
        }
    }
}
void WlrCompositor::forward_pointer_button(int window_id, int button, bool pressed) {
    notify_activity();
    if (!seat) return;
    // ws peut être nullptr : relâchement du clic en dehors de toute fenêtre
    // (ex: drop d'un drag-and-drop dans le vide de la scène 3D). Dans ce cas
    // on doit quand même notifier le seat (qui route vers la surface ayant
    // le focus pointeur) et traiter l'abandon du drag ci-dessous.
    WindowState *ws = find_window(window_id);

    static const bool dbg_btn =
        getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    if (dbg_btn) {
        UtilityFunctions::print("waylandgodot: button id=", window_id,
            " pressed=", pressed,
            " t=", get_time_msec(),
            " focus_ok=", (ws && seat->pointer_state.focused_surface == ws->toplevel->base->surface));
    }

    if (!pressed) {
        // Drop de fichiers sur le monde 3D : interception AVANT toute
        // notification du relâchement. Notifier d'abord terminerait le grab
        // du drag immédiatement (drag détruit, source annulée) et
        // l'extraction text/uri-list n'aurait alors plus rien à lire.
        if (!ws && seat->drag != nullptr && seat->drag->focus == nullptr &&
                seat->drag->source != nullptr &&
                (uint32_t)button == seat->pointer_state.grab_button &&
                extract_file_drop_start()) {
            return; // relâchement différé (délivré par _finish_file_drop)
        }
    } else {
        release_stale_button((uint32_t)button);
    }

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);

    if (pressed) {
        if (!ws) return; // pas de fenêtre sous le curseur, rien à activer/focaliser

        if (active_toplevel_id != window_id && ws->toplevel->base->initialized) {
            wlr_xdg_toplevel_set_activated(ws->toplevel, true);
            active_toplevel_id = window_id;
        }

        keyboard_focus_layer_id = -1;

        wlr_seat_keyboard_notify_enter(seat, ws->toplevel->base->surface,
            virtual_keyboard.keycodes,
            virtual_keyboard.num_keycodes,
            &virtual_keyboard.modifiers);
    } else {
        // Gestion de l'abandon de Drag and Drop : relâché hors de toute
        // fenêtre (ws == nullptr) ou hors de la surface qui a le focus du
        // drag -> on annule la source, ce qui déclenchera on_drag_destroy
        // et donc l'émission de drag_icon_removed côté GDScript.
        if (seat->drag != nullptr) {
            if (seat->drag->focus == nullptr || !ws) {
                if (seat->drag->source) {
                    wlr_data_source_destroy(seat->drag->source);
                }
            }
        }
    }
}
void WlrCompositor::on_pointer_grab_begin(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, pointer_grab_begin_listener);
    (void)data;
}
void WlrCompositor::on_pointer_grab_end(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, pointer_grab_end_listener);
    (void)data;
}
void WlrCompositor::forward_pointer_button_popup(int popup_id, int button, bool pressed) {
    notify_activity();
    PopupState *ps = find_popup(popup_id);
    if (!ps || !seat) return;

    if (pressed) {
        release_stale_button((uint32_t)button);
    }

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_axis(int window_id, double delta_x, double delta_y) {
    notify_activity();
    WindowState *ws = find_window(window_id);
    if (!ws || !seat) return;

    // delta values are in v120 units (120 = one standard wheel notch).
    // Convert to degrees for the continuous value parameter:
    // 120 v120 = 15° (standard 15° click-angle mouse).
    constexpr double V120_TO_DEGREES = 15.0 / 120.0;
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y * V120_TO_DEGREES, (int32_t)delta_y,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x * V120_TO_DEGREES, (int32_t)delta_x,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_leave() {
    if (!seat) return;
    wlr_seat_pointer_notify_clear_focus(seat);
}
void WlrCompositor::forward_pointer_motion_layer(int layer_id, double surface_x, double surface_y) {
    notify_activity();
    LayerSurfaceState *ls = find_layer_surface(layer_id);
    if (!ls || !ls->layer_surface) return;
    notify_pointer_motion_on_surface(ls->layer_surface->surface, surface_x, surface_y);
}
void WlrCompositor::forward_pointer_button_layer(int layer_id, int button, bool pressed) {
    notify_activity();
    LayerSurfaceState *ls = find_layer_surface(layer_id);
    if (!ls || !ls->layer_surface || !seat) return;

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);

    // keyboard-interactive = on_demand/exclusive: un clic donne le focus
    // clavier à la layer surface (indispensable pour rofi).
    if (pressed) {
        uint32_t ki = ls->layer_surface->current.keyboard_interactive;
        if (ki == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND ||
            ki == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE) {
            focus_layer_surface(*ls);
        }
    }
}
void WlrCompositor::forward_pointer_axis_layer(int layer_id, double delta_x, double delta_y) {
    notify_activity();
    LayerSurfaceState *ls = find_layer_surface(layer_id);
    if (!ls || !ls->layer_surface || !seat) return;
    constexpr double V120_TO_DEGREES = 15.0 / 120.0;
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y * V120_TO_DEGREES, (int32_t)delta_y,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x * V120_TO_DEGREES, (int32_t)delta_x,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_motion_lock(double surface_x, double surface_y) {
    notify_activity();
    SessionLockSurfaceState *ss = get_active_lock_surface();
    if (!ss || !ss->lock_surface || !ss->lock_surface->surface) return;
    notify_pointer_motion_on_surface(ss->lock_surface->surface, surface_x, surface_y);
}
void WlrCompositor::forward_pointer_button_lock(int button, bool pressed) {
    notify_activity();
    SessionLockSurfaceState *ss = get_active_lock_surface();
    if (!ss || !ss->lock_surface || !seat) return;

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_axis_lock(double delta_x, double delta_y) {
    notify_activity();
    SessionLockSurfaceState *ss = get_active_lock_surface();
    if (!ss || !ss->lock_surface || !seat) return;
    constexpr double V120_TO_DEGREES = 15.0 / 120.0;
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y * V120_TO_DEGREES, (int32_t)delta_y,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x * V120_TO_DEGREES, (int32_t)delta_x,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::forward_pointer_pinch(double factor, double dx, double dy) {
    notify_activity();
    if (!pointer_gestures || !seat) return;
    if (factor <= 0.0) return;
    uint32_t time = get_time_msec();
    if (!pinch_active) {
        // Godot ne génère des gestes magnify que pour 2 doigts, et les
        // clients ciblés (Gwenview…) n'écoutent que le pinch.
        wlr_pointer_gestures_v1_send_pinch_begin(pointer_gestures, seat, time, 2);
        pinch_scale = 1.0;
        pinch_active = true;
    }
    pinch_scale *= factor;
    if (pinch_scale < 0.0001) pinch_scale = 0.0001;
    wlr_pointer_gestures_v1_send_pinch_update(pointer_gestures, seat, time,
        dx, dy, pinch_scale, 0.0);
    pinch_last_update_ms = time;
    UtilityFunctions::print("[gesture] forward_pinch factor=", factor, " scale=", pinch_scale,
        " focus=", (seat && seat->pointer_state.focused_surface) ? "oui" : "non");
}
void WlrCompositor::forward_pointer_pinch_end(bool cancelled) {
    notify_activity();
    if (!pointer_gestures || !seat || !pinch_active) {
        pinch_active = false;
        return;
    }
    UtilityFunctions::print("[gesture] pinch_end cancelled=", cancelled);
    wlr_pointer_gestures_v1_send_pinch_end(pointer_gestures, seat,
        get_time_msec(), cancelled);
    pinch_active = false;
}
void WlrCompositor::forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed) {
    notify_activity();
    if (!seat) return;

    static const bool dbg = getenv("CYBERREALM_INPUT_DEBUG") && getenv("CYBERREALM_INPUT_DEBUG")[0] == '1';
    auto log_unmapped = [&](int code) {
        if (dbg) {
            fprintf(stderr, "waylandgodot: keyboard keycode non mappé godot=%d loc=%d pressed=%d\n",
                code, key_location, pressed);
        }
    };

    uint32_t evdev_code;
    if (godot_physical_keycode == (int)Key::KEY_ALT && key_location == 2) {
        evdev_code = 100; // KEY_RIGHTALT / AltGr
    } else if (key_location == 3) {
        // Numpad: try location-aware map first, fall back to generic map
        auto np = NUMPAD_EVDEV.find(godot_physical_keycode);
        if (np != NUMPAD_EVDEV.end()) {
            evdev_code = np->second;
        } else {
            auto it = GODOT_TO_EVDEV.find(godot_physical_keycode);
            if (it == GODOT_TO_EVDEV.end()) {
                log_unmapped(godot_physical_keycode);
                return;
            }
            evdev_code = it->second;
        }
    } else {
        auto it = GODOT_TO_EVDEV.find(godot_physical_keycode);
        if (it == GODOT_TO_EVDEV.end()) {
            log_unmapped(godot_physical_keycode);
            return;
        }
        evdev_code = it->second;
    }

    // Garde-fou : ne forwarder que des DOWN/UP appariés. wlroots keycodes est
    // un ensemble (déjà protégé des doublons), mais xkb_state_update_key, lui,
    // compte chaque DOWN/UP : un DOWN répété (écho) sans UP ou un UP orphelin
    // désynchronise l'état xkb (modificateur "coincé" jusqu'au reload keymap).
    if (pressed) {
        if (!pressed_keys.insert(evdev_code).second) {
            return;
        }
    } else {
        if (pressed_keys.erase(evdev_code) == 0) {
            return;
        }
    }

    wlr_keyboard_key_event event = {};
    event.time_msec = get_time_msec();
    event.keycode = evdev_code;
    event.update_state = true;
    event.state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED;

    wlr_keyboard_notify_key(&virtual_keyboard, &event);
}
void WlrCompositor::release_all_keys() {
    if (!seat) return;
    if (virtual_keyboard.num_keycodes == 0) {
        // Rien à relâcher, mais il faut quand même vider pressed_keys : sinon
        // une entrée obsolète (désync avec wlroots keycodes, ex. après un
        // wlr_seat_keyboard_enter qui resynchronise le client) rendrait le
        // DOWN suivant "dupliqué" (ignoré) et son UP "orphelin" (ignoré) —
        // la touche resterait enfoncée côté client (auto-repeat en boucle).
        pressed_keys.clear();
        return;
    }
    uint32_t time = get_time_msec();
    // Copie car wlr_keyboard_notify_key modifie le tableau
    uint32_t saved[WLR_KEYBOARD_KEYS_CAP];
    int n = virtual_keyboard.num_keycodes;
    if (n > WLR_KEYBOARD_KEYS_CAP) n = WLR_KEYBOARD_KEYS_CAP;
    memcpy(saved, virtual_keyboard.keycodes, n * sizeof(uint32_t));

    for (int i = 0; i < n; i++) {
        wlr_keyboard_key_event ev = {};
        ev.time_msec = time;
        ev.keycode = saved[i];
        ev.update_state = true;
        ev.state = WL_KEYBOARD_KEY_STATE_RELEASED;
        wlr_keyboard_notify_key(&virtual_keyboard, &ev);
    }
    // Ces touches ne sont plus considérées comme enfoncées : un éventuel
    // relâchement forwardé plus tard (touche libérée pendant que le menu
    // pause était ouvert, par ex.) sera ignoré au lieu de casser l'état xkb.
    pressed_keys.clear();
}
void WlrCompositor::set_window_keyboard_focus(int window_id) {
    if (!seat) return;
    WindowState *ws = find_window(window_id);
    if (!ws) return;
    keyboard_focus_layer_id = -1;
    focus_surface(ws->toplevel->base->surface);
}
void WlrCompositor::reload_keymap() {
    CharString layout_utf8 = keyboard_layout.utf8();
    CharString variant_utf8 = keyboard_variant.utf8();
    xkb_rule_names rule_names = {
        .rules = nullptr,
        .model = nullptr,
        .layout = layout_utf8.get_data(),
        .variant = keyboard_variant.is_empty() ? nullptr : variant_utf8.get_data(),
        .options = nullptr,
    };

    xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx) return;
    xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &rule_names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) {
        UtilityFunctions::printerr("waylandgodot: impossible de compiler le keymap xkb (layout=",
            keyboard_layout, ", variant=", keyboard_variant, ")");
        xkb_context_unref(ctx);
        return;
    }
    wlr_keyboard_set_keymap(&virtual_keyboard, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);

    // Enable NumLock by default (comportement repris de l'init d'origine).
    xkb_keymap *kmap = xkb_state_get_keymap(virtual_keyboard.xkb_state);
    xkb_mod_index_t num_mod = xkb_keymap_mod_get_index(kmap, XKB_MOD_NAME_NUM);
    if (num_mod != XKB_MOD_INVALID) {
        xkb_state_update_mask(virtual_keyboard.xkb_state,
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_DEPRESSED),
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_LATCHED),
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_LOCKED) | (1u << num_mod),
            0, 0, 0);
        wlr_keyboard_notify_modifiers(&virtual_keyboard,
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_DEPRESSED),
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_LATCHED),
            xkb_state_serialize_mods(virtual_keyboard.xkb_state, XKB_STATE_MODS_LOCKED),
            xkb_state_serialize_layout(virtual_keyboard.xkb_state, XKB_STATE_LAYOUT_EFFECTIVE));
    }
}
void WlrCompositor::set_keyboard_layout(const String &layout, const String &variant) {
    keyboard_layout = layout;
    keyboard_variant = variant;
    // Aucun keymap encore appliqué (avant start_headless) : reload_keymap()
    // sera appelé à l'init avec ces valeurs.
    if (!virtual_keyboard.keymap) return;
    reload_keymap();
}
String WlrCompositor::get_keyboard_layout() const {
    return keyboard_layout;
}
String WlrCompositor::get_keyboard_variant() const {
    return keyboard_variant;
}
void WlrCompositor::on_new_constraint(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_constraint_listener);
    wlr_pointer_constraint_v1 *constraint = (wlr_pointer_constraint_v1 *)data;

    int window_id = self->find_window_id_by_surface(constraint->surface);
    UtilityFunctions::print("waylandgodot: new_constraint window_id=", window_id,
        " type=", constraint->type == WLR_POINTER_CONSTRAINT_V1_LOCKED ? "LOCKED" : "CONFINED");
    if (window_id == -1) return;

    wlr_pointer_constraint_v1_send_activated(constraint);

    // Un confinement (zwp_pointer_constraints_v1::confine_pointer) laisse le
    // curseur visible : le client continue de recevoir du mouvement absolu
    // (borné à la région) et gère lui-même son curseur. Ne pas le traiter
    // comme un lock — SDL notamment, quand il relâche le mode relatif d'un
    // jeu, détruit le locked_pointer puis crée immédiatement un confine pour
    // garder le pointeur dans la fenêtre (menu ouvert). Traiter ce confine
    // comme un lock recapturait la souris → curseur invisible dans le menu.
    if (constraint->type == WLR_POINTER_CONSTRAINT_V1_CONFINED) {
        return;
    }

    self->window_pointer_locked[window_id] = true;
    self->emit_signal("pointer_lock_changed", window_id, true);

    // Écouter la destruction du constraint (client déverrouille ou surface détruite)
    struct ConstraintDestroyData {
        WlrCompositor *self;
        int window_id;
        wl_listener listener;
    };
    auto *cdata = new ConstraintDestroyData{self, window_id, {}};
    cdata->listener.notify = [](wl_listener *l, void *) {
        ConstraintDestroyData *cd = wl_container_of(l, cd, listener);
        wl_list_remove(&cd->listener.link);
        cd->self->window_pointer_locked[cd->window_id] = false;
        cd->self->emit_signal("pointer_lock_changed", cd->window_id, false);
        delete cd;
    };
    wl_signal_add(&constraint->events.destroy, &cdata->listener);
}
bool WlrCompositor::is_window_pointer_locked(int window_id) const {
    auto it = window_pointer_locked.find(window_id);
    return it != window_pointer_locked.end() && it->second;
}
int WlrCompositor::get_window_pid(int window_id) {
    WindowState *ws = find_window(window_id);
    if (!ws) return -1;
    if (ws->xwayland) {
        // Le PID du client Wayland est celui du satellite, pas de l'app.
        // Résout le vrai PID de l'application X11 via le serveur X du
        // satellite (_NET_WM_PID, matching sur titre + WM_CLASS). -1 tant que
        // le résolveur n'a pas le snapshot (le refresh est déclenché au map /
        // au changement de titre / périodiquement par resolve()).
        std::string app_id = ws->toplevel && ws->toplevel->app_id
            ? ws->toplevel->app_id : "";
        std::string title = ws->toplevel && ws->toplevel->title
            ? ws->toplevel->title : "";
        return x11_resolver.resolve(app_id, title);
    }
    return (int)ws->pid;
}
void WlrCompositor::set_audio_share_pids(Array pids) {
    std::vector<int> targets;
    targets.reserve((size_t)pids.size());
    for (int i = 0; i < pids.size(); i++) {
        int pid = (int)pids[i];
        if (pid > 0) {
            targets.push_back(pid);
        }
    }
    audio_share.set_target_pids(targets);
}
void WlrCompositor::forward_pointer_relative_motion(int window_id, double dx, double dy, double dx_unaccel, double dy_unaccel) {
    notify_activity();
    if (!relative_pointer_manager || !seat) return;
    uint64_t time_usec = get_time_msec() * 1000;
    wlr_relative_pointer_manager_v1_send_relative_motion(
        relative_pointer_manager, seat, time_usec, dx, dy, dx_unaccel, dy_unaccel);
    // Toujours terminer par un frame : SDL3 (OpenMW) et GLFW (Minecraft)
    // bufferisent le relatif dans pending_frame et ne le dispatch qu'à
    // l'arrivée d'un wl_pointer.frame. Depuis qu'on n'envoie plus de
    // wl_pointer.motion absolu pendant un pointer lock, ce frame est
    // indispensable — sinon aucun mouvement relatif n'arrive au client.
    wlr_seat_pointer_notify_frame(seat);
}
void WlrCompositor::set_cursor_position(double x, double y) {
    cursor_x = x;
    cursor_y = y;
}
void WlrCompositor::set_cursor_visible(bool visible) {
    cursor_visible = visible;
}
void WlrCompositor::set_window_pointer(int window_id, double x, double y, bool inside) {
    if (window_id < 0 || !inside) {
        // Le pointeur ne survole aucune fenêtre : efface l'état de toutes
        // pour qu'aucune capture de fenêtre ne conserve un curseur périmé.
        for (auto &pair : windows) {
            pair.second.pointer_inside = false;
        }
        return;
    }
    WindowState *ws = find_window(window_id);
    if (!ws) {
        return;
    }
    ws->pointer_inside = true;
    ws->pointer_x = x;
    ws->pointer_y = y;
}
Dictionary WlrCompositor::get_window_pointer(int window_id) {
    Dictionary result;
    result["inside"] = false;
    result["x"] = 0.0;
    result["y"] = 0.0;
    WindowState *ws = find_window(window_id);
    if (!ws) {
        return result;
    }
    result["inside"] = ws->pointer_inside;
    result["x"] = ws->pointer_x;
    result["y"] = ws->pointer_y;
    return result;
}
static bool cursor_debug_enabled() {
    const char *e = getenv("CYBERREALM_INPUT_DEBUG");
    return e && e[0] == '1';
}
void WlrCompositor::on_cursor_surface_client_commit(wl_listener *listener, void *data) {
    WindowCursorState *cs = wl_container_of(listener, cs, client_commit_listener);
    (void)data;
    WlrCompositor *self = cs->owner;
    if (!self || !cs->surface) {
        return;
    }
    wlr_buffer *buffer = cs->surface->pending.buffer;
    if (!buffer) {
        return;
    }
    int prev = cs->serial;
    bool ok = self->capture_window_cursor(*cs, buffer);
    if (cursor_debug_enabled()) {
        // fprintf (pas UtilityFunctions::print) : ces logs partent du
        // thread Wayland, où la construction de Variant/String Godot
        // n'est pas sûre (crash constaté).
        int w = -1, h = -1;
        if (cs->image.is_valid()) { w = cs->image->get_width(); h = cs->image->get_height(); }
        uint32_t committed = cs->surface->pending.committed;
        bool frame_in_commit = (committed & WLR_SURFACE_STATE_FRAME_CALLBACK_LIST) != 0;
        bool attach_in_commit = (committed & WLR_SURFACE_STATE_BUFFER) != 0;
        fprintf(stderr, "waylandgodot: cursor commit surface=%p window=%d serial %llu -> %llu captured=%s w=%d h=%d committed=%u attach=%d frame_cb=%d cb_pending=%d\n",
            (void *)cs->surface, cs->window_id,
            (unsigned long long)prev, (unsigned long long)cs->serial, ok ? "yes" : "no", w, h,
            (unsigned)committed, attach_in_commit ? 1 : 0, frame_in_commit ? 1 : 0,
            wl_list_empty(&cs->surface->current.frame_callback_list) ? 0 : 1);
    }
}
void WlrCompositor::on_cursor_surface_commit(wl_listener *listener, void *data) {
    WindowCursorState *cs = wl_container_of(listener, cs, commit_listener);
    (void)data;
    WlrCompositor *self = cs->owner;
    if (!self || !cs->surface) {
        return;
    }
    // Xwayland ne (ré)uploade son curseur que lorsqu'il a reçu le frame
    // callback de l'upload précédent (voir xwl_seat_set_cursor dans
    // xwayland-cursor.c : "if (xwl_cursor->frame_cb) { needs_update =
    // TRUE; return; }"). Comme on ne rend jamais cette surface sur un
    // output, wlroots n'enverrait pas de frame done → le callback
    // resterait pendant indéfiniment et Xwayland avalerait silencieusement
    // TOUT changement de curseur après le premier upload. On simule donc
    // l'affichage : dès qu'on a consommé l'image (au client_commit), on
    // libère Xwayland.
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_surface_send_frame_done(cs->surface, &now);
}
void WlrCompositor::on_cursor_surface_destroy(wl_listener *listener, void *data) {
    WindowCursorState *cs = wl_container_of(listener, cs, destroy_listener);
    (void)data;
    // Le client a détruit sa surface curseur : on conserve la dernière image
    // capturée (l'overlay du mode focus continue de l'afficher), on se
    // contente de détacher le suivi de la surface.
    if (cursor_debug_enabled()) {
        fprintf(stderr, "waylandgodot: cursor surface destroyed surface=%p window=%d serial=%llu kept_image=%s\n",
            (void *)cs->surface, cs->window_id, (unsigned long long)cs->serial,
            cs->image.is_valid() ? "yes" : "no");
    }
    cs->surface = nullptr;
    wl_list_remove(&cs->commit_listener.link);
    wl_list_remove(&cs->client_commit_listener.link);
    wl_list_remove(&cs->destroy_listener.link);
    wl_list_init(&cs->commit_listener.link);
    wl_list_init(&cs->client_commit_listener.link);
    wl_list_init(&cs->destroy_listener.link);
}
void WlrCompositor::on_request_set_cursor(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, request_set_cursor_listener);
    wlr_seat_pointer_request_set_cursor_event *event =
        (wlr_seat_pointer_request_set_cursor_event *)data;
    bool dbg = cursor_debug_enabled();
    if (!self->seat) {
        if (dbg) fprintf(stderr, "waylandgodot: set_cursor ignored (no seat)\n");
        return;
    }
    if (!event->seat_client || event->seat_client != self->seat->pointer_state.focused_client) {
        if (dbg) fprintf(stderr, "waylandgodot: set_cursor ignored (wrong seat client)\n");
        return;
    }

    // Fenêtre du client : le curseur est posé depuis la surface qui a le
    // focus pointeur (le toplevel actif), pas depuis la surface curseur.
    int window_id = -1;
    if (self->seat->pointer_state.focused_surface) {
        wlr_surface *root = wlr_surface_get_root_surface(
            self->seat->pointer_state.focused_surface);
        window_id = root ? self->find_window_id_by_surface(root) : -1;
    }
    if (window_id == -1) {
        if (dbg) fprintf(stderr, "waylandgodot: set_cursor ignored (no focused window)\n");
        return;
    }

    if (event->surface) {
        WindowCursorState &cs = self->window_cursor[window_id];
        cs.window_id = window_id;
        cs.hidden = false;
        if (cs.surface != event->surface) {
            if (cs.surface) {
                wl_list_remove(&cs.commit_listener.link);
                wl_list_remove(&cs.client_commit_listener.link);
                wl_list_remove(&cs.destroy_listener.link);
                wl_list_init(&cs.commit_listener.link);
                wl_list_init(&cs.client_commit_listener.link);
                wl_list_init(&cs.destroy_listener.link);
            }
            cs.surface = event->surface;
            cs.owner = self;
            cs.commit_listener.notify = WlrCompositor::on_cursor_surface_commit;
            cs.client_commit_listener.notify = WlrCompositor::on_cursor_surface_client_commit;
            cs.destroy_listener.notify = WlrCompositor::on_cursor_surface_destroy;
            wl_signal_add(&cs.surface->events.commit, &cs.commit_listener);
            wl_signal_add(&cs.surface->events.client_commit, &cs.client_commit_listener);
            wl_signal_add(&cs.surface->events.destroy, &cs.destroy_listener);
        }
        cs.hotspot_x = event->hotspot_x;
        cs.hotspot_y = event->hotspot_y;
        // Le buffer peut déjà être committé au moment du set_cursor (wlroots
        // appelle aussi pointer_cursor_surface_handle_commit avant l'émission).
        bool ok = self->capture_window_cursor(cs, cs.surface ? cs.surface->current.buffer : nullptr);
        if (dbg) {
            wlr_buffer *buf = cs.surface && cs.surface->current.buffer ? cs.surface->current.buffer : nullptr;
            fprintf(stderr, "waylandgodot: set_cursor window=%d surface=%p buf=%p captured=%s serial=%llu\n",
                window_id, (void *)cs.surface, (void *)buf, ok ? "yes" : "no", (unsigned long long)cs.serial);
        }
    } else {
        // set_cursor(NULL) : le client masque son curseur. On CONSERVE la
        // dernière image capturée : certains clients (ex. OpenMW via SDL, qui
        // masque son curseur pendant le grab du pointer lock) ne renvoient
        // pas toujours un set_cursor après le relâchement du grab → sans cette
        // rétention le curseur disparaît définitivement (l'overlay du mode
        // focus retomberait sur la flèche système). Pendant la souris capturée
        // l'overlay est masqué de toute façon.
        // set_cursor(NULL) : le client demande l'absence de curseur OS. On
        // crée l'état s'il n'existe pas encore (jeux qui ne posent jamais de
        // surface curseur mais masquent simplement le curseur système, ex.
        // Papers Please/Unity) pour que l'overlay se masque au lieu de
        // retomber sur la flèche système.
        WindowCursorState &cs = self->window_cursor[window_id];
        cs.window_id = window_id;
        cs.hidden = true;
        if (cs.surface) {
            wl_list_remove(&cs.commit_listener.link);
            wl_list_remove(&cs.client_commit_listener.link);
            wl_list_remove(&cs.destroy_listener.link);
            wl_list_init(&cs.commit_listener.link);
            wl_list_init(&cs.client_commit_listener.link);
            wl_list_init(&cs.destroy_listener.link);
        }
        cs.surface = nullptr;
        if (dbg) fprintf(stderr, "waylandgodot: set_cursor NULL window=%d kept_image=%s serial=%llu\n",
            window_id, cs.image.is_valid() ? "yes" : "no", (unsigned long long)cs.serial);
    }
}
void WlrCompositor::clear_window_cursor(int window_id) {
    auto it = window_cursor.find(window_id);
    if (it == window_cursor.end()) {
        return;
    }
    WindowCursorState &cs = it->second;
    if (cursor_debug_enabled()) {
        fprintf(stderr, "waylandgodot: clear_window_cursor window=%d surface=%p serial=%llu\n",
            window_id, (void *)cs.surface, (unsigned long long)cs.serial);
    }
    if (cs.surface) {
        wl_list_remove(&cs.commit_listener.link);
        wl_list_remove(&cs.client_commit_listener.link);
        wl_list_remove(&cs.destroy_listener.link);
        wl_list_init(&cs.commit_listener.link);
        wl_list_init(&cs.client_commit_listener.link);
        wl_list_init(&cs.destroy_listener.link);
        cs.surface = nullptr;
    }
    cs.image = godot::Ref<godot::Image>();
    cs.serial++;
    window_cursor.erase(it);
}
bool WlrCompositor::capture_window_cursor(WindowCursorState &cs, wlr_buffer *buffer) {
    bool dbg = cursor_debug_enabled();
    if (!buffer) {
        if (dbg) fprintf(stderr, "waylandgodot: capture cursor skipped (no buffer)\n");
        return false;
    }
    void *data = nullptr;
    uint32_t format = 0;
    size_t stride = 0;
    if (!wlr_buffer_begin_data_ptr_access(buffer, WLR_BUFFER_DATA_PTR_ACCESS_READ,
            &data, &format, &stride)) {
        if (dbg) fprintf(stderr, "waylandgodot: capture cursor failed (data ptr access, fmt=%x)\n", (unsigned)format);
        return false;
    }
    if (format != DRM_FORMAT_ARGB8888) {
        if (dbg) fprintf(stderr, "waylandgodot: capture cursor skipped (fmt=%x not ARGB8888)\n", (unsigned)format);
        wlr_buffer_end_data_ptr_access(buffer);
        return false;
    }
    int w = buffer->width;
    int h = buffer->height;
    if (w <= 0 || h <= 0) {
        if (dbg) fprintf(stderr, "waylandgodot: capture cursor skipped (bad size %dx%d)\n", w, h);
        wlr_buffer_end_data_ptr_access(buffer);
        return false;
    }
    // ARGB8888 (DRM) = BGRA little-endian, alpha prémultipliée.
    // Conversion en RGBA8 Godot (alpha straight).
    PackedByteArray px;
    px.resize((int64_t)w * h * 4);
    uint8_t *dst = px.ptrw();
    const uint8_t *src = static_cast<const uint8_t *>(data);
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
    wlr_buffer_end_data_ptr_access(buffer);
    godot::Ref<godot::Image> img = godot::Image::create_from_data(
        w, h, false, godot::Image::FORMAT_RGBA8, px);
    cs.image = img;
    cs.serial++;
    return true;
}
Dictionary WlrCompositor::get_window_cursor(int window_id) {
    Dictionary result;
    auto it = window_cursor.find(window_id);
    if (it == window_cursor.end()) {
        return result;
    }
    WindowCursorState &cs = it->second;
    if (!cs.image.is_valid()) {
        // Aucune image capturée : ne signaler quelque chose que si le client
        // a explicitement masqué son curseur (set_cursor NULL, ex. jeux Unity
        // type Papers Please qui dessinent leur propre curseur), pour que
        // l'overlay se cache au lieu de retomber sur le curseur système.
        // Sinon (entrée sans image ET non masquée) on renvoie le dictionnaire
        // vide comme avant, pour ne pas changer le comportement des autres
        // fenêtres (et ne pas casser le serial dans focus_mode.gd).
        if (cs.hidden) {
            result["hidden"] = true;
        }
        return result;
    }
    int32_t scale = cs.surface ? cs.surface->current.scale : 1;
    result["serial"] = (uint64_t)cs.serial;
    result["image"] = cs.image;
    result["hidden"] = cs.hidden;
    result["hotspot_x"] = (double)cs.hotspot_x * scale;
    result["hotspot_y"] = (double)cs.hotspot_y * scale;
    result["width"] = cs.image->get_width();
    result["height"] = cs.image->get_height();
    return result;
}
