#include "wlr_compositor.h"
#include "wlr_layer_shell_helpers.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#ifdef HAVE_DBUS
#include <dbus/dbus.h>
#endif
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <dirent.h>
#include <poll.h>
#include <linux/dma-buf.h>

extern "C" {
#include <wlr/types/wlr_buffer.h>
#include <wlr/interfaces/wlr_buffer.h>
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
#include <wlr/types/wlr_xcursor_manager.h>
}

#include "ext-image-capture-source-v1-protocol.h"

using namespace godot;

// =====================================================================
// Capture de fenêtres pour xdg-desktop-portal-wlr
// (ext_foreign_toplevel_image_capture_source_manager_v1 — manager absent
// de wlroots 0.19.3, voir ext_foreign_toplevel_image_capture_source.c)
// =====================================================================

void WlrCompositor::toplevel_source_start(wlr_ext_image_capture_source_v1 *base, bool with_cursors) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    source->num_started++;
}

void WlrCompositor::toplevel_source_stop(wlr_ext_image_capture_source_v1 *base) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    if (source->num_started > 0) {
        source->num_started--;
    }
}

void WlrCompositor::toplevel_source_schedule_frame(wlr_ext_image_capture_source_v1 *base) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    source->needs_frame = true;
}

void WlrCompositor::toplevel_source_copy_frame(wlr_ext_image_capture_source_v1 *base,
        wlr_ext_image_copy_capture_frame_v1 *frame,
        wlr_ext_image_capture_source_v1_frame_event *event) {
    WlrCompositorToplevelSource *source = wl_container_of(base, source, base);
    WindowState *ws = source->window;
    // Le buffer exact-size contient le dernier rendu de la fenêtre (recopié
    // depuis offscreen dans _process à chaque frame) ; copie GPU→buffer
    // client par wlroots. On ne peut pas passer capture_cache.offscreen
    // directement : il est pad'dé à 64px alors que copy_buffer exige des
    // tailles identiques (BUFFER_CONSTRAINTS sinon).
    if (!ws || !source->capture_buffer) {
        wlr_ext_image_copy_capture_frame_v1_fail(frame,
            EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED);
        return;
    }
    if (!wlr_ext_image_copy_capture_frame_v1_copy_buffer(frame,
            source->capture_buffer, source->compositor->renderer)) {
        return;
    }
    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    wlr_ext_image_copy_capture_frame_v1_ready(frame, WL_OUTPUT_TRANSFORM_NORMAL, &now);
}

wlr_ext_image_capture_source_v1_cursor *WlrCompositor::toplevel_source_get_pointer_cursor(
        wlr_ext_image_capture_source_v1 *base, wlr_seat *seat) {
    return nullptr;
}

static const wlr_ext_image_capture_source_v1_interface toplevel_source_impl = {
    .start = WlrCompositor::toplevel_source_start,
    .stop = WlrCompositor::toplevel_source_stop,
    .schedule_frame = WlrCompositor::toplevel_source_schedule_frame,
    .copy_frame = WlrCompositor::toplevel_source_copy_frame,
    .get_pointer_cursor = WlrCompositor::toplevel_source_get_pointer_cursor,
};

static const struct ext_foreign_toplevel_image_capture_source_manager_v1_interface foreign_toplevel_source_manager_impl = {
    .create_source = WlrCompositor::on_foreign_toplevel_source_manager_create_source,
    .destroy = WlrCompositor::on_foreign_toplevel_source_manager_destroy,
};

// ---------------------------------------------------------------------
// Table de correspondance Key (Godot, physical_keycode) -> evdev keycode
// ---------------------------------------------------------------------
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
    {(int)Key::KEY_QUOTELEFT, 41},
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

// Numpad evdev codes when location == 3 but physical_keycode is a regular key
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

// ---------------------------------------------------------------------
// Impl minimal pour un wlr_keyboard non rattaché à un backend matériel.
// ---------------------------------------------------------------------
static void waylandgodot_keyboard_led_update(wlr_keyboard *keyboard, uint32_t leds) {
    (void)keyboard;
    (void)leds;
}

static const wlr_keyboard_impl waylandgodot_KEYBOARD_IMPL = {
    .name = "waylandgodot-vkbd",
    .led_update = waylandgodot_keyboard_led_update,
};

void WlrCompositor::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start_headless"), &WlrCompositor::start_headless);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion", "window_id", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion_popup", "popup_id", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion_popup);
    ClassDB::bind_method(D_METHOD("forward_pointer_button", "window_id", "button", "pressed"),
        &WlrCompositor::forward_pointer_button);
    ClassDB::bind_method(D_METHOD("forward_pointer_button_popup", "popup_id", "button", "pressed"),
        &WlrCompositor::forward_pointer_button_popup);
    ClassDB::bind_method(D_METHOD("forward_pointer_axis", "window_id", "delta_x", "delta_y"),
        &WlrCompositor::forward_pointer_axis);
    ClassDB::bind_method(D_METHOD("forward_pointer_leave"), &WlrCompositor::forward_pointer_leave);
    ClassDB::bind_method(D_METHOD("forward_keyboard_key", "godot_physical_keycode", "key_location", "pressed"),
        &WlrCompositor::forward_keyboard_key);
    ClassDB::bind_method(D_METHOD("notify_activity"), &WlrCompositor::notify_activity);
    ClassDB::bind_method(D_METHOD("set_keyboard_layout", "layout", "variant"),
        &WlrCompositor::set_keyboard_layout);
    ClassDB::bind_method(D_METHOD("get_keyboard_layout"), &WlrCompositor::get_keyboard_layout);
    ClassDB::bind_method(D_METHOD("get_keyboard_variant"), &WlrCompositor::get_keyboard_variant);
    ClassDB::bind_method(D_METHOD("forward_pointer_relative_motion", "window_id", "dx", "dy", "dx_unaccel", "dy_unaccel"),
        &WlrCompositor::forward_pointer_relative_motion);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion_layer", "layer_id", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion_layer);
    ClassDB::bind_method(D_METHOD("forward_pointer_button_layer", "layer_id", "button", "pressed"),
        &WlrCompositor::forward_pointer_button_layer);
    ClassDB::bind_method(D_METHOD("forward_pointer_axis_layer", "layer_id", "delta_x", "delta_y"),
        &WlrCompositor::forward_pointer_axis_layer);
    ClassDB::bind_method(D_METHOD("forward_pointer_motion_lock", "surface_x", "surface_y"),
        &WlrCompositor::forward_pointer_motion_lock);
    ClassDB::bind_method(D_METHOD("forward_pointer_button_lock", "button", "pressed"),
        &WlrCompositor::forward_pointer_button_lock);
    ClassDB::bind_method(D_METHOD("forward_pointer_axis_lock", "delta_x", "delta_y"),
        &WlrCompositor::forward_pointer_axis_lock);
    ClassDB::bind_method(D_METHOD("get_wayland_socket_name"), &WlrCompositor::get_wayland_socket_name);
    ClassDB::bind_method(D_METHOD("launch_app", "command"), &WlrCompositor::launch_app);
    ClassDB::bind_method(D_METHOD("shutdown_apps"), &WlrCompositor::shutdown_apps);
    ClassDB::bind_method(D_METHOD("set_window_size", "window_id", "width", "height"), &WlrCompositor::set_window_size);
    ClassDB::bind_method(D_METHOD("set_window_fullscreen", "window_id", "fullscreen"), &WlrCompositor::set_window_fullscreen);
    ClassDB::bind_method(D_METHOD("set_x11_display", "display_name"), &WlrCompositor::set_x11_display);
    ClassDB::bind_method(D_METHOD("get_window_geometry", "window_id"), &WlrCompositor::get_window_geometry);
    ClassDB::bind_method(D_METHOD("popup_accepts_input", "popup_id"), &WlrCompositor::popup_accepts_input);

    ClassDB::bind_method(D_METHOD("set_output_size", "width", "height"), &WlrCompositor::set_output_size);
    ClassDB::bind_method(D_METHOD("present_viewport_frame", "rgba", "width", "height"), &WlrCompositor::present_viewport_frame);
    ClassDB::bind_method(D_METHOD("has_active_capture"), &WlrCompositor::has_active_capture);
    ClassDB::bind_method(D_METHOD("get_layer_surface_info", "layer_id"), &WlrCompositor::get_layer_surface_info);
    ClassDB::bind_method(D_METHOD("get_keyboard_focus_layer_id"), &WlrCompositor::get_keyboard_focus_layer_id);
    ClassDB::bind_method(D_METHOD("close_layer_surface", "layer_id"), &WlrCompositor::close_layer_surface);

    ClassDB::bind_method(D_METHOD("get_window_list"), &WlrCompositor::get_window_list);
    ClassDB::bind_method(D_METHOD("close_window", "window_id"), &WlrCompositor::close_window);

    ClassDB::bind_method(D_METHOD("release_all_keys"), &WlrCompositor::release_all_keys);

    ClassDB::bind_method(D_METHOD("set_portal_backend", "backend"), &WlrCompositor::set_portal_backend);
    ClassDB::bind_method(D_METHOD("get_portal_backend"), &WlrCompositor::get_portal_backend);

    ClassDB::bind_method(D_METHOD("set_polkit_agent", "path"), &WlrCompositor::set_polkit_agent);
    ClassDB::bind_method(D_METHOD("get_polkit_agent"), &WlrCompositor::get_polkit_agent);
    ClassDB::bind_method(D_METHOD("launch_portals"), &WlrCompositor::launch_portals);

    ClassDB::bind_method(D_METHOD("set_cursor_position", "x", "y"), &WlrCompositor::set_cursor_position);
    ClassDB::bind_method(D_METHOD("set_cursor_visible", "visible"), &WlrCompositor::set_cursor_visible);


    ADD_SIGNAL(MethodInfo("window_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "title"),
        PropertyInfo(Variant::STRING, "app_id")));
    ADD_SIGNAL(MethodInfo("window_unmapped", PropertyInfo(Variant::INT, "id")));
    ADD_SIGNAL(MethodInfo("window_decorations_changed",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::BOOL, "server_side")));
    ADD_SIGNAL(MethodInfo("window_title_changed",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "title")));
    ADD_SIGNAL(MethodInfo("window_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));

    ADD_SIGNAL(MethodInfo("popup_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::INT, "parent_window_id"),
        PropertyInfo(Variant::INT, "parent_popup_id"),
        PropertyInfo(Variant::INT, "x"),
        PropertyInfo(Variant::INT, "y"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
    ADD_SIGNAL(MethodInfo("popup_unmapped", PropertyInfo(Variant::INT, "id")));
    ADD_SIGNAL(MethodInfo("popup_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));

    ADD_SIGNAL(MethodInfo("pointer_lock_changed",
        PropertyInfo(Variant::INT, "window_id"),
        PropertyInfo(Variant::BOOL, "locked")));

    ADD_SIGNAL(MethodInfo("window_fullscreen_changed",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::BOOL, "fullscreen")));

    ADD_SIGNAL(MethodInfo("drag_icon_updated",
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
    ADD_SIGNAL(MethodInfo("drag_icon_removed"));

    ADD_SIGNAL(MethodInfo("layer_surface_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "namespace"),
        PropertyInfo(Variant::INT, "layer"),
        PropertyInfo(Variant::INT, "anchor"),
        PropertyInfo(Variant::INT, "x"),
        PropertyInfo(Variant::INT, "y"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height"),
        PropertyInfo(Variant::INT, "keyboard_interactive")));
    ADD_SIGNAL(MethodInfo("layer_surface_unmapped", PropertyInfo(Variant::INT, "id")));
    ADD_SIGNAL(MethodInfo("layer_surface_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
    // Position/taille (layout) recalculées par arrange_layer_surfaces.
    // Émis UNIQUEMENT quand la boîte change (pas à chaque commit) : le
    // script positionne le TextureRect sans avoir à re-requérir
    // get_layer_surface_info (allocation d'un Dictionary) à chaque frame.
    ADD_SIGNAL(MethodInfo("layer_surface_layout_changed",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::INT, "x"),
        PropertyInfo(Variant::INT, "y"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));
    ADD_SIGNAL(MethodInfo("layer_popup_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::INT, "parent_layer_id"),
        PropertyInfo(Variant::INT, "x"),
        PropertyInfo(Variant::INT, "y"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));

    ADD_SIGNAL(MethodInfo("session_lock_locked"));
    ADD_SIGNAL(MethodInfo("session_lock_unlocked"));
    ADD_SIGNAL(MethodInfo("session_lock_surface_texture_updated",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::OBJECT, "texture"),
        PropertyInfo(Variant::INT, "width"),
        PropertyInfo(Variant::INT, "height")));

}

WlrCompositor::WlrCompositor() {
    const char *env = getenv("XDG_CURRENT_DESKTOP");
    if (env) {
        portal_backend = String(env);
    }
    // Adopte les orphelins de nos descendants : sans quoi les apps lancées par
    // un script (ex. `dms run`) qui se détachent (setsid / double fork) sont
    // réparées vers init et échappent à shutdown_apps(). Avec ce subreaper,
    // tout ce qui descend du jeu reste dans son arbre /proc tant que le jeu
    // vit, et shutdown_apps() peut le tuer.
    prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
}

WlrCompositor::~WlrCompositor() {
    // Libérer les ressources Vulkan tant que RenderingDevice est encore
    // valide (avant que les maps windows/popups ne détruisent les
    // CaptureCache via leurs destructeurs).
    RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
    for (auto &pair : windows) {
        pair.second.capture_cache.reset(rd);
    }
    for (auto &pair : popups) {
        pair.second.capture_cache.reset(rd);
    }
    for (auto &pair : layer_surfaces) {
        pair.second.capture_cache.reset(rd);
    }
    for (auto &pair : session_lock.surfaces) {
        pair.second.capture_cache.reset(rd);
    }
    drag_icon_cache.reset(rd);
    vulkan_import.flush_pending();
    vulkan_import.cleanup();

    if (present_buffer) {
        wlr_buffer_drop(present_buffer);
        present_buffer = nullptr;
    }

    if (display) {
        // Retirer TOUS les listeners attachés aux objets wlr AVANT de
        // détruire le display. wlroots exige que les signaux de
        // xdg_shell (new_surface/new_toplevel/new_popup/destroy) soient
        // sans listener à la destruction : wlr_xdg_shell_destroy() fait
        // assert(wl_list_empty(...)) et abort() sinon (crash 23:08).
        // Les listeners per-objets (toplevel/popup/layer/drag/constraint)
        // sont retirés par leurs propres handlers lors de
        // wl_display_destroy_clients() ci-dessous, il ne faut donc pas
        // les toucher ici.
        if (!wl_list_empty(&new_toplevel_listener.link))
            wl_list_remove(&new_toplevel_listener.link);
        if (!wl_list_empty(&new_toplevel_decoration_listener.link))
            wl_list_remove(&new_toplevel_decoration_listener.link);
        if (!wl_list_empty(&new_layer_surface_listener.link))
            wl_list_remove(&new_layer_surface_listener.link);
        if (!wl_list_empty(&new_session_lock_listener.link))
            wl_list_remove(&new_session_lock_listener.link);
        if (!wl_list_empty(&new_idle_inhibitor_listener.link))
            wl_list_remove(&new_idle_inhibitor_listener.link);
        if (!wl_list_empty(&request_start_drag_listener.link))
            wl_list_remove(&request_start_drag_listener.link);
        if (!wl_list_empty(&start_drag_listener.link))
            wl_list_remove(&start_drag_listener.link);
        if (!wl_list_empty(&request_set_selection_listener.link))
            wl_list_remove(&request_set_selection_listener.link);
        if (!wl_list_empty(&request_set_primary_selection_listener.link))
            wl_list_remove(&request_set_primary_selection_listener.link);
        if (!wl_list_empty(&new_constraint_listener.link))
            wl_list_remove(&new_constraint_listener.link);
        if (!wl_list_empty(&keyboard_key_listener.link))
            wl_list_remove(&keyboard_key_listener.link);
        if (!wl_list_empty(&keyboard_modifiers_listener.link))
            wl_list_remove(&keyboard_modifiers_listener.link);
        if (!wl_list_empty(&pointer_grab_begin_listener.link))
            wl_list_remove(&pointer_grab_begin_listener.link);
        if (!wl_list_empty(&pointer_grab_end_listener.link))
            wl_list_remove(&pointer_grab_end_listener.link);

        // Détruire le curseur AVANT le display (wlr_cursor/wlr_cursor_manager
        // dépendent du display pour leurs ressources internes).
        if (cursor_manager) {
            wlr_xcursor_manager_destroy(cursor_manager);
            cursor_manager = nullptr;
        }
        if (cursor) {
            wlr_cursor_destroy(cursor);
            cursor = nullptr;
        }

        wl_display_destroy_clients(display);
        wl_display_destroy(display);
    }

    // Tuer tous les processus enfants lancés par launch_app() : SIGTERM,
    // période de grâce puis SIGKILL aux survivants (voir shutdown_apps()).
    shutdown_apps();

    // Terminer le bus D-Bus privé de la session du jeu
    if (dbus_daemon_pid > 0) {
        kill(dbus_daemon_pid, SIGTERM);
        waitpid(dbus_daemon_pid, nullptr, WNOHANG);
        dbus_daemon_pid = -1;
    }

    // Nettoyer le fichier d'adresse D-Bus utilisé par les apps lancées dans
    // le jeu (cyberrealm-launch, compositors/kwin/cyberrealm-launch)
    {
        const char *rt = getenv("XDG_RUNTIME_DIR");
        if (rt) {
            std::string path = std::string(rt) + "/cyberrealm-session-bus";
            unlink(path.c_str());
        }
    }


}

uint32_t WlrCompositor::get_time_msec() {
    using namespace std::chrono;
    return (uint32_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

WindowState *WlrCompositor::find_window(int id) {
    auto it = windows.find(id);
    return it == windows.end() ? nullptr : &it->second;
}

int WlrCompositor::find_window_id_by_surface(wlr_surface *surface) {
    for (auto &pair : windows) {
        if (pair.second.toplevel && pair.second.toplevel->base->surface == surface) {
            return pair.first;
        }
    }
    return -1;
}

PopupState *WlrCompositor::find_popup(int id) {
    auto it = popups.find(id);
    return it == popups.end() ? nullptr : &it->second;
}

LayerSurfaceState *WlrCompositor::find_layer_surface(int id) {
    auto it = layer_surfaces.find(id);
    return it == layer_surfaces.end() ? nullptr : &it->second;
}

// =====================================================================
// check_dmabuf_linear_available — Teste si le renderer + allocateur
// supportent l'export dmabuf avec modifier linéaire.
// =====================================================================

bool WlrCompositor::check_dmabuf_linear_available() {
    if (!renderer || !allocator) return false;

    const wlr_drm_format_set *formats =
        wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
    if (!formats) return false;

    static const uint32_t check[] = {
        DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888,
        DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888,
    };

    for (uint32_t f : check) {
        const wlr_drm_format *fmt = wlr_drm_format_set_get(formats, f);
        if (!fmt) continue;

        for (size_t i = 0; i < fmt->len; i++) {
            if (fmt->modifiers[i] == DRM_FORMAT_MOD_LINEAR ||
                fmt->modifiers[i] == DRM_FORMAT_MOD_INVALID) {
                return true;
            }
        }
    }
    return false;
}

// =====================================================================
// CaptureCache — libération du buffer/mapping mis en cache
// =====================================================================

void CaptureCache::reset(RenderingDevice *rd) {
    // Libérer les ressources Vulkan AVANT le wlr_buffer : le RID
    // wrappe un VkImageView qui référence le VkImage, lequel est backing
    // par le même fd DMA-BUF que le wlr_buffer.  Tant que le RID existe,
    // Godot peut encore interroger le VkImage.
    if (vulkan_rid.is_valid() && rd) {
        rd->free_rid(vulkan_rid);
        vulkan_rid = RID();
    }
    rd_texture.unref();

    if (map_base && map_base != MAP_FAILED) {
        munmap(map_base, map_size);
    }
    map_base = nullptr;
    map_size = 0;
    data = nullptr;
    dma_fd = -1;
    stride = 0;
    format = 0;
    if (offscreen) {
        wlr_buffer_drop(offscreen);
        offscreen = nullptr;
    }
    width = 0;
    height = 0;
    alloc_width = 0;
    alloc_height = 0;
    backend = Backend::NONE;
}

// Arrondit une dimension au palier supérieur pour l'allocation du buffer
// offscreen. Évite de réallouer le buffer GPU/dmabuf à chaque frame
// pendant un resize continu (drag de bordure) - tant que la nouvelle
// taille tient dans le palier déjà alloué, on réutilise le buffer existant
// et on ne rend/copie que la sous-région w x h réellement utile.
static inline int round_up_capture_size(int v) {
    static constexpr int CAPTURE_SIZE_STEP = 64;
    return (v + CAPTURE_SIZE_STEP - 1) / CAPTURE_SIZE_STEP * CAPTURE_SIZE_STEP;
}

// Filet de sécurité pour la recapture des layer surfaces : même sans commit
// de la surface racine, une sous-surface peut committer (bloc clock, module
// avec son propre wl_surface...). On re-capture alors périodiquement les
// surfaces non-dirty. 20 ≈ une fois par seconde à 60 FPS.
static constexpr int LAYER_SAFETY_RECAPTURE_INTERVAL = 20;

// Filet de sécurité pour la recapture des fenêtres. En temps normal une
// fenêtre n'est recapturée QUE si une de ses surfaces a committé
// (on_surface_commit + trackers de sous-surfaces). Ce filet très lent
// (60 ≈ une fois par seconde à 60 FPS) couvre les cas où une sous-surface
// apparaît et committe entre deux sync_window_subsurfaces : à défaut son
// contenu resterait figé jusqu'au prochain commit racine.
static constexpr int WINDOW_SAFETY_RECAPTURE_INTERVAL = 60;

CaptureCache::~CaptureCache() {
    reset();
}

// =====================================================================
// capture_surface — dispatch: dmabuf d'abord, fallback CPU ensuite
// =====================================================================

bool WlrCompositor::capture_surface(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    // Essayer d'abord le chemin Vulkan zero-copy (GPU→GPU, pas de CPU readback).
    if (gpu_pipeline_active && dmabuf_available &&
        capture_surface_vulkan(surface, tex, out_w, out_h, cache)) {
        return true;
    }
    // Fallback : dmabuf + mmap CPU readback.
    if (dmabuf_available && capture_surface_dmabuf(surface, tex, out_w, out_h, cache)) {
        return true;
    }
    // Dernier recours : Pixman (rendu logiciel, buffer en RAM).
    return capture_surface_pixels(surface, tex, out_w, out_h, cache);
}

// =====================================================================
// wait_for_dmabuf_gpu_writes — Attend que les écritures GPU (EGL/GLES2)
// sur un DMA-BUF soient terminées.
// =====================================================================
// Utilise DMA_BUF_IOCTL_EXPORT_SYNC_FILE (Linux 5.20+) qui exporte un
// sync_file représentant l'achèvement de toutes les opérations d'écriture
// GPU sur le DMA-BUF. On poll() dessus pour bloquer jusqu'à ce que le
// render pass wlroots ait terminé d'écrire. C'est la seule façon fiable
// de synchroniser deux API GPU différentes (EGL wlroots ↔ Vulkan Godot)
// sur tous les pilotes (Mesa, NVIDIA, etc.).
//
// Fallback: DMA_BUF_IOCTL_SYNC (sync CPU uniquement, n'attend PAS le
// GPU sur les pilotes sans sync implicite → tearing possible).
// =====================================================================
static void wait_for_dmabuf_gpu_writes(int dma_fd) {
    if (dma_fd < 0) return;

    // Tenter EXPORT_SYNC_FILE d'abord (sync GPU fiable cross-API).
    struct dma_buf_export_sync_file export_args = {};
    export_args.flags = DMA_BUF_SYNC_WRITE;
    if (ioctl(dma_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_args) == 0) {
        struct pollfd pfd;
        pfd.fd = export_args.fd;
        pfd.events = POLLIN;
        poll(&pfd, 1, -1); // bloque jusqu'à l'achèvement GPU
        close(export_args.fd);
        return;
    }

    // Fallback noyau < 5.20 : DMA_BUF_IOCTL_SYNC (cache CPU seulement,
    // pas de garantie d'attente GPU sur certains pilotes).
    struct dma_buf_sync sync = {};
    sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
    ioctl(dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
    ioctl(dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
}

// =====================================================================
// capture_surface_dmabuf — Rendu GPU + mmap dmabuf
// =====================================================================
// Flux:
//   1. Récupère la texture wlroots de la surface (déjà sur GPU)
//   2. Crée un buffer offscreen dmabuf (allocateur GBM, renderer EGL/GLES2)
//   3. Render pass: dessine la texture dans le buffer (GPU, pas de software)
//   4. Exporte les attributs dmabuf du buffer (fd, stride, format, modifier)
//   5. Vérifie que le modifier est linéaire (requis pour mmap)
//   6. mmap le fd → accès direct à la mémoire du buffer
//   7. Copie les pixels en respectant le stride, avec swizzle BGRA→RGBA
//      si nécessaire (pas besoin si format = DRM_FORMAT_ABGR8888)
//   8. munmap + drop buffer
//   9. Crée/met à jour l'ImageTexture Godot
//
// Avantages vs Pixman + readback CPU:
//   - Rendu GPU (GLES2) au lieu de software rendering (Pixman)
//   - Accès mémoire direct (mmap) au lieu de wlr_buffer_begin_data_ptr_access
//   - memcpy par ligne si format ABGR8888 (pas de swizzle par pixel)
// =====================================================================

// Boîte de recadrage pour la capture d'une surface xdg : sa géométrie
// effective (window_geometry). On utilise xdg_surface->geometry et NON
// xdg_surface->current.geometry :
//   - current.geometry est la valeur brute de set_window_geometry, vide
//     (0,0,0,0) si le client ne l'a jamais appelée ;
//   - xdg_surface->geometry est recalculée par wlroots à CHAQUE commit
//     (update_geometry) : intersection de la window_geometry avec les
//     extents de la surface, ou extents seuls sinon. wlr_surface_get_extents
//     inclut les sous-surfaces.
// C'est exactement le cas des sous-popups de Firefox (menus en cascade) :
// la surface racine (MozContainer) n'a jamais de buffer, tout le contenu
// vit dans une sous-surface WebRender, donc surface->current.width == 0 et
// root_texture == NULL. Les extents (racine + sous-surfaces) donnent alors
// la taille réelle du contenu, même sans set_window_geometry.
// Retourne false si la surface n'est pas une xdg_surface ou si la géométrie
// est vide (pas encore de contenu).
static bool capture_crop_box(wlr_surface *surface, wlr_box &out) {
    wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
    if (!xdg) return false;
    wlr_box geo = xdg->geometry;
    if (geo.width <= 0 || geo.height <= 0) return false;
    out = geo;
    return true;
}

bool WlrCompositor::capture_surface_dmabuf(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    if (!renderer || !allocator) return false;

    wlr_texture *root_texture = wlr_surface_get_texture(surface);
    // Ne pas retourner false si root_texture est NULL : Firefox peut ne
    // committer aucun buffer sur la surface racine d'un popup (surtout les
    // sous-popups / cascading menus), tout le contenu vivant dans des
    // sous-surfaces. wlr_surface_for_each_surface ci-dessous itérera
    // quand même sur les sous-surfaces.

    // Recadre sur la géométrie xdg effective (window_geometry) EN PREMIER :
    // pour les sous-popups Firefox, la surface racine n'a pas de buffer
    // (tout vit dans des sous-surfaces), donc surface->current.width == 0 et
    // root_texture == NULL.
    int geo_x = 0, geo_y = 0;
    int w = 0, h = 0;
    wlr_box crop;
    if (capture_crop_box(surface, crop)) {
        geo_x = crop.x;
        geo_y = crop.y;
        w = crop.width;
        h = crop.height;
    }

    // Taille LOGIQUE de la surface (surface->current.width/height), pas la
    // taille brute du buffer (texture->width/height). Sur un client HiDPI
    // (buffer_scale > 1), le buffer physique est plus grand que la taille
    // affichée - mélanger les deux donne une image mal mise à l'échelle.
    // Utiliser comme fallback quand la géométrie xdg n'est pas disponible
    // (fenêtres sans CSD, surfaces sans set_window_geometry).
    if (w <= 0 || h <= 0) {
        w = surface->current.width > 0 ? surface->current.width : (root_texture ? (int)root_texture->width : 0);
        h = surface->current.height > 0 ? surface->current.height : (root_texture ? (int)root_texture->height : 0);
    }
    if (w <= 0 || h <= 0) return false;

    // ---- (Re)création du buffer offscreen + de son mapping -------------
    // Seulement si c'est le premier appel ou si la taille a changé. Le
    // reste du temps on réutilise cache.offscreen (déjà rendu-cible GPU
    // valide) et cache.data (déjà mmap) sans repasser par
    // wlr_allocator_create_buffer / wlr_buffer_get_dmabuf / mmap - ce sont
    // ces appels (alloc GPU, export dmabuf, syscall mmap) qui coûtaient le
    // plus cher à refaire à chaque frame.
    // Réallocation si aucun buffer n'existe, si le backend propriétaire
    // ne correspond pas (changement de pipeline entre dmabuf/pixels/vulkan),
    // ou si la taille dépasse la capacité allouée.
    if (!cache.offscreen || cache.backend != CaptureCache::Backend::DMABUF ||
        w > cache.alloc_width || h > cache.alloc_height) {
        cache.reset(RenderingServer::get_singleton()->get_rendering_device());

        int alloc_w = round_up_capture_size(w);
        int alloc_h = round_up_capture_size(h);

        // Formats dmabuf supportés par le renderer. On préfère ABGR8888
        // (RGBA en mémoire little-endian) pour éviter le swizzle BGRA→RGBA.
        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
        if (!formats) {
            UtilityFunctions::printerr("waylandgodot: renderer ne supporte pas WLR_BUFFER_CAP_DMABUF");
            return false;
        }

        // Cherche un format qui supporte le modifier linéaire (requis pour
        // mmap). On crée un wlr_drm_format avec uniquement
        // DRM_FORMAT_MOD_LINEAR pour forcer l'allocateur à créer un buffer
        // linéaire (pas tiled).
        static const uint32_t preferred[] = {
            DRM_FORMAT_ABGR8888, // RGBA en mémoire → pas de swizzle
            DRM_FORMAT_XBGR8888, // RGB en mémoire → pas de swizzle
            DRM_FORMAT_ARGB8888, // BGRA en mémoire → swizzle
            DRM_FORMAT_XRGB8888, // BGR en mémoire → swizzle
        };

        wlr_buffer *offscreen = nullptr;
        uint32_t chosen_format = 0;

        for (uint32_t f : preferred) {
            const wlr_drm_format *fmt = wlr_drm_format_set_get(formats, f);
            if (!fmt) continue;

            bool linear_ok = false;
            for (size_t i = 0; i < fmt->len; i++) {
                if (fmt->modifiers[i] == DRM_FORMAT_MOD_LINEAR ||
                    fmt->modifiers[i] == DRM_FORMAT_MOD_INVALID) {
                    linear_ok = true;
                    break;
                }
            }
            if (!linear_ok) continue;

            uint64_t linear_mod = DRM_FORMAT_MOD_LINEAR;
            struct wlr_drm_format linear_fmt = {};
            linear_fmt.format = f;
            linear_fmt.modifiers = &linear_mod;
            linear_fmt.len = 1;

            offscreen = wlr_allocator_create_buffer(allocator, alloc_w, alloc_h, &linear_fmt);
            if (offscreen) {
                chosen_format = f;
                break;
            }
        }

        if (!offscreen) {
            UtilityFunctions::printerr("waylandgodot: impossible de créer un buffer dmabuf linéaire ",
                "(le GPU ne supporte peut-être que des formats tiled)");
            return false;
        }

        // Export dmabuf
        wlr_dmabuf_attributes attribs = {};
        if (!wlr_buffer_get_dmabuf(offscreen, &attribs)) {
            UtilityFunctions::printerr("waylandgodot: dmabuf: wlr_buffer_get_dmabuf a échoué");
            wlr_buffer_drop(offscreen);
            return false;
        }

        // Seulement les formats single-plane
        if (attribs.n_planes != 1) {
            wlr_buffer_drop(offscreen);
            return false;
        }

        // mmap nécessite un format linéaire (tiled = données illisibles directement)
        if (attribs.modifier != DRM_FORMAT_MOD_INVALID &&
            attribs.modifier != DRM_FORMAT_MOD_LINEAR) {
            wlr_buffer_drop(offscreen);
            return false;
        }

        // mmap le dmabuf, une seule fois, gardé ouvert dans le cache.
        // L'offset du plan peut ne pas être aligné sur une page: on aligne
        // vers le bas pour mmap, puis on ajuste le pointeur.
        long page_size = sysconf(_SC_PAGE_SIZE);
        off_t plane_offset = (off_t)attribs.offset[0];
        off_t map_offset = plane_offset & ~(off_t)(page_size - 1);
        size_t map_delta = (size_t)(plane_offset - map_offset);
        size_t map_size = map_delta + (size_t)attribs.stride[0] * (size_t)alloc_h;

        void *map_base = mmap(nullptr, map_size, PROT_READ, MAP_SHARED,
                              attribs.fd[0], map_offset);
        if (map_base == MAP_FAILED) {
            UtilityFunctions::printerr("waylandgodot: dmabuf: mmap a échoué");
            wlr_buffer_drop(offscreen);
            return false;
        }

        cache.offscreen = offscreen;
        cache.map_base = map_base;
        cache.map_size = map_size;
        cache.data = static_cast<uint8_t *>(map_base) + map_delta;
        cache.dma_fd = attribs.fd[0];
        cache.stride = attribs.stride[0];
        cache.format = attribs.format;
        cache.alloc_width = alloc_w;
        cache.alloc_height = alloc_h;
        cache.backend = CaptureCache::Backend::DMABUF;
    }
    // La taille logique (w, h) et le tampon CPU tightly-packed se
    // mettent à jour à chaque appel, même quand le buffer GPU/dmabuf est
    // réutilisé tel quel (resize qui reste sous la capacité allouée).
    cache.width = w;
    cache.height = h;
    if (cache.bytes.size() != (int64_t)w * h * 4) {
        cache.bytes.resize((int64_t)w * h * 4);
    }

    // ---- Render pass: racine + sous-surfaces → buffer offscreen --------
    // C'est la seule partie qui doit obligatoirement se refaire à chaque
    // frame: le buffer est réutilisé mais son contenu change.
    struct SubSurfaceInstance {
        wlr_surface *surface;
        int sx, sy;
    };
    std::vector<SubSurfaceInstance> instances;

    // Parcourt la surface racine ET ses sous-surfaces (wl_subsurface).
    // Firefox (entre autres) dessine son contenu WebRender dans une
    // sous-surface enfant distincte de la surface racine (qui ne porte
    // que le chrome/CSD) - sans ça, seule la barre de titre est capturée
    // et le reste reste noir/vide.
    wlr_surface_for_each_surface(surface,
        +[](wlr_surface *sub, int sx, int sy, void *data) {
            auto *out = static_cast<std::vector<SubSurfaceInstance> *>(data);
            out->push_back({sub, sx, sy});
        }, &instances);

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, cache.offscreen, nullptr);
    if (!pass) {
        UtilityFunctions::printerr("waylandgodot: dmabuf: begin_buffer_pass a échoué");
        return false;
    }

    // wlroots 0.18 ne fait aucun clear à begin_buffer_pass : l'offscreen est
    // réutilisé entre les frames et le contenu semi-transparent s'accumule
    // (alpha → 1 après quelques frames → fond opaque/noir). On efface donc
    // explicitement avec un rect (0,0,0,0) en écriture directe (blend NONE)
    // avant de re-rasteriser la surface par-dessus.
    wlr_render_rect_options clear = {};
    clear.box.x = 0;
    clear.box.y = 0;
    clear.box.width = cache.offscreen->width;
    clear.box.height = cache.offscreen->height;
    clear.color = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    wlr_render_pass_add_rect(pass, &clear);

    int blitted = 0;
    for (auto &inst : instances) {
        wlr_texture *sub_texture = wlr_surface_get_texture(inst.surface);
        if (!sub_texture) continue;

        int sub_w = inst.surface->current.width > 0
            ? inst.surface->current.width : (int)sub_texture->width;
        int sub_h = inst.surface->current.height > 0
            ? inst.surface->current.height : (int)sub_texture->height;

        // Décale dst_box de (-geo_x, -geo_y) pour ne rasteriser que la
        // zone de contenu (window_geometry). Les pixels d'ombre CSD en
        // dehors de cette zone tombent en dehors du buffer et sont
        // clipés par le render pass — pas besoin de apply_content_opacity
        // ni de transparent overlay.
        wlr_render_texture_options opts = {};
        opts.texture = sub_texture;
        opts.dst_box.x = inst.sx - geo_x;
        opts.dst_box.y = inst.sy - geo_y;
        opts.dst_box.width = sub_w;
        opts.dst_box.height = sub_h;
        wlr_render_pass_add_texture(pass, &opts);
        blitted++;
    }

    if (blitted == 0) {
        UtilityFunctions::printerr("waylandgodot: dmabuf: aucune sous-surface avec texture à blitter");
        return false;
    }

    timespec t_render_start, t_render_end;
    clock_gettime(CLOCK_MONOTONIC, &t_render_start);
    if (!wlr_render_pass_submit(pass)) {
        UtilityFunctions::printerr("waylandgodot: dmabuf: render_pass_submit a échoué");
        return false;
    }
    clock_gettime(CLOCK_MONOTONIC, &t_render_end);

    // Attendre que le render pass EGL/GLES2 soit terminé sur le GPU
    // AVANT de lire les pixels en mmap. Sans cette synchronisation,
    // le memcpy peut lire des données partiellement écrites par le GPU.
    wait_for_dmabuf_gpu_writes(cache.dma_fd);

    // Synchronisation CPU/GPU: DMA_BUF_IOCTL_SYNC invalide le cache
    // CPU pour que mmap lise les données fraîches du GPU.
    timespec t_sync1_start, t_sync1_end;
    clock_gettime(CLOCK_MONOTONIC, &t_sync1_start);
    struct dma_buf_sync sync = {};
    sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
    ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
    clock_gettime(CLOCK_MONOTONIC, &t_sync1_end);

    // Copie des pixels avec gestion du stride et swizzle si nécessaire,
    // dans le tampon CPU réutilisé (cache.bytes, pas de realloc/frame).
    uint8_t *dst = cache.bytes.ptrw();
    bool has_alpha = (cache.format == DRM_FORMAT_ABGR8888 ||
                    cache.format == DRM_FORMAT_ARGB8888);

    timespec t_copy_start, t_copy_end;
    clock_gettime(CLOCK_MONOTONIC, &t_copy_start);
    if (cache.format == DRM_FORMAT_ABGR8888 ||
        cache.format == DRM_FORMAT_XBGR8888) {
        // RGBA en mémoire → copie directe par ligne (stride peut > w*4)
        for (int y = 0; y < h; y++) {
            memcpy(dst + (size_t)y * w * 4,
                cache.data + (size_t)y * cache.stride,
                (size_t)w * 4);
        }
    } else {
        // BGRA en mémoire → swizzle B↔R par pixel
        for (int y = 0; y < h; y++) {
            const uint8_t *row = cache.data + (size_t)y * cache.stride;
            for (int x = 0; x < w; x++) {
                dst[(y * w + x) * 4 + 0] = row[x * 4 + 2]; // R <- B
                dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
                dst[(y * w + x) * 4 + 2] = row[x * 4 + 0]; // B <- R
                dst[(y * w + x) * 4 + 3] = has_alpha ? row[x * 4 + 3] : 0; // Alpha (transparence par défaut)
            }
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t_copy_end);

    timespec t_sync2_start, t_sync2_end;
    clock_gettime(CLOCK_MONOTONIC, &t_sync2_start);
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
    ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
    clock_gettime(CLOCK_MONOTONIC, &t_sync2_end);

    // Crée/met à jour l'ImageTexture
    timespec t_tex_start, t_tex_end;
    clock_gettime(CLOCK_MONOTONIC, &t_tex_start);
    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, cache.bytes);

    Ref<ImageTexture> img_tex = Object::cast_to<ImageTexture>(tex.ptr());
    if (img_tex.is_null() || out_w != w || out_h != h) {
        img_tex = ImageTexture::create_from_image(img);
        tex = img_tex;
    } else {
        img_tex->update(img);
    }
    clock_gettime(CLOCK_MONOTONIC, &t_tex_end);

    auto ms = [](const timespec &a, const timespec &b) {
        return (b.tv_sec - a.tv_sec) * 1000.0 + (b.tv_nsec - a.tv_nsec) / 1e6;
    };
    double d_render = ms(t_render_start, t_render_end);
    double d_sync1 = ms(t_sync1_start, t_sync1_end);
    double d_memcpy = ms(t_copy_start, t_copy_end);
    double d_sync2 = ms(t_sync2_start, t_sync2_end);
    double d_tex = ms(t_tex_start, t_tex_end);
    double d_total = d_render + d_sync1 + d_memcpy + d_sync2 + d_tex;
    if (d_total > 2.0) { // ne log que les captures qui coûtent réellement
        UtilityFunctions::print("waylandgodot: capture ", w, "x", h,
            " render=", d_render, "ms sync_start=", d_sync1,
            "ms memcpy=", d_memcpy,
            "ms sync_end=", d_sync2,
            "ms tex_upload=", d_tex, "ms TOTAL=", d_total, "ms");
    }
    out_w = w;
    out_h = h;
    return true;
}

// =====================================================================
// capture_surface_vulkan — Zero-copy GPU→GPU via Vulkan DMA-BUF import
// =====================================================================
// Flux:
//   1. Récupère la texture wlroots de la surface (déjà sur GPU)
//   2. Crée un buffer offscreen dmabuf (allocateur GBM, renderer EGL/GLES2)
//   3. Render pass: dessine la surface + sous-surfaces dans le buffer
//   4. Exporte les attributs dmabuf du buffer (fd, stride, format)
//   5. Importe le fd dans le Vulkan de Godot via VK_KHR_external_memory_fd
//      → VkImage + VkDeviceMemory
//   6. Enveloppe le VkImage dans un RID via texture_create_from_extension,
//      puis dans une Texture2DRD (sous-classe de Texture2D)
//
// Le buffer offscreen est conservé dans `cache` d'une frame à l'autre.
// Tant que la taille ne change pas, le même VkImage est réutilisé : le
// render pass GPU écrit dans le DMA-BUF, et le VkImage reflète ces
// changements automatiquement (même mémoire physique).
// =====================================================================

bool WlrCompositor::capture_surface_vulkan(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    if (!renderer || !allocator || !gpu_pipeline_active) return false;

    wlr_texture *root_texture = wlr_surface_get_texture(surface);

    // Géométrie effective AVANT le test de taille : la surface racine d'un
    // sous-popup Firefox peut ne pas avoir de buffer (contenu WebRender dans
    // des sous-surfaces), donc surface->current.width == 0 et root_texture
    // == NULL. Le crop box (xdg_surface->geometry, extents racine +
    // sous-surfaces) fournit alors la taille réelle du contenu.
    int geo_x = 0, geo_y = 0;
    int w = 0, h = 0;
    wlr_box crop;
    if (capture_crop_box(surface, crop)) {
        geo_x = crop.x;
        geo_y = crop.y;
        w = crop.width;
        h = crop.height;
    }

    // Taille LOGIQUE de la surface (surface->current.width/height), pas la
    // taille brute du buffer (texture->width/height). Fallback quand la
    // géométrie xdg effective n'est pas disponible (surfaces sans
    // window_geometry, layer surfaces, surfaces non xdg).
    if (w <= 0 || h <= 0) {
        w = surface->current.width > 0 ? surface->current.width : (root_texture ? (int)root_texture->width : 0);
        h = surface->current.height > 0 ? surface->current.height : (root_texture ? (int)root_texture->height : 0);
    }
    if (w <= 0 || h <= 0) return false;

    // ---- (Re)création du buffer offscreen + import Vulkan -------------
    // Réallouer si le backend ne correspond pas, ou si la taille dépasse
    // la capacité allouée. Le round_up_capture_size évite de réallouer à
    // chaque frame pendant un resize continu : tant que la nouvelle taille
    // tient dans le palier déjà alloué, on réutilise le buffer existant
    // (la régión stale est effacée avant le rendu).
    if (!cache.offscreen || cache.backend != CaptureCache::Backend::VULKAN ||
        w > cache.alloc_width || h > cache.alloc_height ||
        (cache.alloc_width > 0 && (w < cache.width || h < cache.height))) {
        // On crée les NOUVELLES ressources AVANT de libérer les anciennes
        // pour éviter un frame sans texture (causerait tearing/lacune visuelle).

        int alloc_w = round_up_capture_size(w);
        int alloc_h = round_up_capture_size(h);

        // Chercher un format dmabuf linéaire.
        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
        if (!formats) return false;

        static const uint32_t preferred[] = {
            DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888,
            DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888,
        };

        wlr_buffer *offscreen = nullptr;
        uint32_t chosen_format = 0;

        for (uint32_t f : preferred) {
            const wlr_drm_format *fmt = wlr_drm_format_set_get(formats, f);
            if (!fmt) continue;

            bool linear_ok = false;
            for (size_t i = 0; i < fmt->len; i++) {
                if (fmt->modifiers[i] == DRM_FORMAT_MOD_LINEAR ||
                    fmt->modifiers[i] == DRM_FORMAT_MOD_INVALID) {
                    linear_ok = true;
                    break;
                }
            }
            if (!linear_ok) continue;

            uint64_t linear_mod = DRM_FORMAT_MOD_LINEAR;
            struct wlr_drm_format linear_fmt = {};
            linear_fmt.format = f;
            linear_fmt.modifiers = &linear_mod;
            linear_fmt.len = 1;

            wlr_buffer *buf = wlr_allocator_create_buffer(allocator, alloc_w, alloc_h, &linear_fmt);
            if (buf) {
                offscreen = buf;
                chosen_format = f;
                break;
            }
        }

        if (!offscreen) return false;

        // Export dmabuf
        wlr_dmabuf_attributes attribs = {};
        if (!wlr_buffer_get_dmabuf(offscreen, &attribs) || attribs.n_planes != 1) {
            wlr_buffer_drop(offscreen);
            offscreen = nullptr;
            return false;
        }

        // Import dans le Vulkan de Godot
        VulkanDmaBufTexture vt = vulkan_import.import_dma_buf(
            attribs.fd[0], alloc_w, alloc_h, chosen_format);

        if (vt.vk_image == VK_NULL_HANDLE) {
            wlr_buffer_drop(offscreen);
            offscreen = nullptr;
            return false;
        }

        // NOUVELLES ressources prêtes — maintenant on peut libérer les
        // anciennes sans laisser un frame sans texture.
        VulkanDmaBufTexture old_vt = {cache.vulkan_rid, cache.rd_texture,
                                       cache.vk_image, cache.vk_memory};
        wlr_buffer *old_offscreen = cache.offscreen;

        cache.offscreen = offscreen;
        cache.alloc_width = alloc_w;
        cache.alloc_height = alloc_h;
        cache.vulkan_rid = vt.rid;
        cache.rd_texture = vt.texture;
        cache.vk_image = vt.vk_image;
        cache.vk_memory = vt.vk_memory;
        cache.format = chosen_format;
        cache.dma_fd = attribs.fd[0];
        cache.backend = CaptureCache::Backend::VULKAN;

        // Libérer les anciennes ressources (détruit VkImage, VkDeviceMemory,
        // RID, et wlr_buffer). vkDeviceWaitIdle est appelé dedans pour
        // sérialiser avec le rendering thread de Godot.
        if (old_vt.vk_image != VK_NULL_HANDLE) {
            vulkan_import.release_texture(old_vt);
        }
        if (old_offscreen) {
            wlr_buffer_drop(old_offscreen);
        }
        // NOTE: on ne PAS appeler cache.reset() ici car vulkan_rid et
        // offscreen pointent maintenant vers les nouvelles ressources.
        // Les anciennes ont été libérées ci-dessus.
    }

    cache.width = w;
    cache.height = h;

    // ---- Render pass: racine + sous-surfaces → buffer offscreen --------
    struct SubSurfaceInstance {
        wlr_surface *surface;
        int sx, sy;
    };
    std::vector<SubSurfaceInstance> instances;

    wlr_surface_for_each_surface(surface,
        +[](wlr_surface *sub, int sx, int sy, void *data) {
            auto *out = static_cast<std::vector<SubSurfaceInstance> *>(data);
            out->push_back({sub, sx, sy});
        }, &instances);

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, cache.offscreen, nullptr);
    if (!pass) return false;

    wlr_render_rect_options clear = {};
    clear.box.x = 0;
    clear.box.y = 0;
    clear.box.width = cache.offscreen->width;
    clear.box.height = cache.offscreen->height;
    clear.color = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    wlr_render_pass_add_rect(pass, &clear);

    int blitted = 0;
    for (auto &inst : instances) {
        wlr_texture *sub_texture = wlr_surface_get_texture(inst.surface);
        if (!sub_texture) continue;

        int sub_w = inst.surface->current.width > 0
            ? inst.surface->current.width : (int)sub_texture->width;
        int sub_h = inst.surface->current.height > 0
            ? inst.surface->current.height : (int)sub_texture->height;

        wlr_render_texture_options opts = {};
        opts.texture = sub_texture;
        opts.dst_box.x = inst.sx - geo_x;
        opts.dst_box.y = inst.sy - geo_y;
        opts.dst_box.width = sub_w;
        opts.dst_box.height = sub_h;

        wlr_render_pass_add_texture(pass, &opts);
        blitted++;
    }

    if (blitted == 0) {
        wlr_render_pass_submit(pass);
        return false;
    }

    if (!wlr_render_pass_submit(pass)) return false;

    // Attendre que le render pass EGL/GLES2 soit terminé sur le GPU
    // avant que Godot n'échantillonne le VkImage (backed par le même
    // DMA-BUF). DMA_BUF_IOCTL_EXPORT_SYNC_FILE exporte un sync_file
    // représentant les écritures GPU en cours, puis poll() bloque
    // jusqu'à leur achèvement. C'est la seule synchronisation fiable
    // entre deux API GPU (EGL wlroots ↔ Vulkan Godot).
    wait_for_dmabuf_gpu_writes(cache.dma_fd);

    tex = cache.rd_texture;
    out_w = w;
    out_h = h;
    return true;
}

// =====================================================================
// capture_surface_pixels — Fallback CPU (readback via DATA_PTR)
// =====================================================================

bool WlrCompositor::capture_surface_pixels(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    wlr_texture *texture = wlr_surface_get_texture(surface);
    if (!texture) return false;

    int w = (int)texture->width;
    int h = (int)texture->height;
    if (w <= 0 || h <= 0) return false;

    // Recadre sur la géométrie xdg effective (même logique que les paths
    // dmabuf/vulkan).
    int geo_x = 0, geo_y = 0;
    wlr_box crop;
    if (capture_crop_box(surface, crop)) {
        geo_x = crop.x;
        geo_y = crop.y;
        w = crop.width;
        h = crop.height;
    }

    // Recrée le buffer offscreen si le backend ne correspond pas ou si la
    // capacité est dépassée.
    if (!cache.offscreen || cache.backend != CaptureCache::Backend::PIXELS ||
        w > cache.alloc_width || h > cache.alloc_height) {
        cache.reset(RenderingServer::get_singleton()->get_rendering_device());

        int alloc_w = round_up_capture_size(w);
        int alloc_h = round_up_capture_size(h);

        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DATA_PTR);
        const wlr_drm_format *fmt = formats ? wlr_drm_format_set_get(formats, DRM_FORMAT_ARGB8888) : nullptr;
        if (!fmt) {
            UtilityFunctions::printerr("waylandgodot: DRM_FORMAT_ARGB8888 non supporté en lecture CPU par ce renderer");
            return false;
        }

        wlr_buffer *offscreen = wlr_allocator_create_buffer(allocator, alloc_w, alloc_h, fmt);
        if (!offscreen) {
            UtilityFunctions::printerr("waylandgodot: échec allocation buffer offscreen");
            return false;
        }

        cache.offscreen = offscreen;
        cache.alloc_width = alloc_w;
        cache.alloc_height = alloc_h;
        cache.backend = CaptureCache::Backend::PIXELS;
    }
    cache.width = w;
    cache.height = h;
    if (cache.bytes.size() != (int64_t)w * h * 4) {
        cache.bytes.resize((int64_t)w * h * 4);
    }

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(renderer, cache.offscreen, nullptr);
    if (!pass) {
        UtilityFunctions::printerr("waylandgodot: échec begin_buffer_pass");
        return false;
    }

    wlr_render_rect_options clear = {};
    clear.box.x = 0;
    clear.box.y = 0;
    clear.box.width = cache.offscreen->width;
    clear.box.height = cache.offscreen->height;
    clear.color = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    wlr_render_pass_add_rect(pass, &clear);

    wlr_render_texture_options opts = {};
    opts.texture = texture;
    opts.dst_box.x = -geo_x;
    opts.dst_box.y = -geo_y;
    opts.dst_box.width = texture->width;
    opts.dst_box.height = texture->height;
    wlr_render_pass_add_texture(pass, &opts);

    timespec t_render_start, t_render_end;
    clock_gettime(CLOCK_MONOTONIC, &t_render_start);
    if (!wlr_render_pass_submit(pass)) {
        UtilityFunctions::printerr("waylandgodot: échec render_pass_submit");
        return false;
    }
    clock_gettime(CLOCK_MONOTONIC, &t_render_end);

    // begin/end_data_ptr_access encadre juste l'accès mémoire (pas de
    // syscall coûteux pour un buffer Pixman, déjà en RAM) - se refait donc
    // chaque frame sans souci, contrairement à l'alloc/mmap dmabuf.
    void *pixels = nullptr;
    uint32_t px_format = 0;
    size_t stride = 0;
    if (!wlr_buffer_begin_data_ptr_access(cache.offscreen, WLR_BUFFER_DATA_PTR_ACCESS_READ,
            &pixels, &px_format, &stride)) {
        UtilityFunctions::printerr("waylandgodot: begin_data_ptr_access a échoué sur le buffer offscreen");
        return false;
    }

    uint8_t *dst = cache.bytes.ptrw();
    const uint8_t *src = static_cast<const uint8_t *>(pixels);

    // DRM_FORMAT_ARGB8888 = BGRA en mémoire (little-endian) → swizzle RGBA
    timespec t_copy_start, t_copy_end;
    clock_gettime(CLOCK_MONOTONIC, &t_copy_start);
    for (int y = 0; y < h; y++) {
        const uint8_t *row = src + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            dst[(y * w + x) * 4 + 0] = row[x * 4 + 2]; // R <- B
            dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
            dst[(y * w + x) * 4 + 2] = row[x * 4 + 0]; // B <- R
            dst[(y * w + x) * 4 + 3] = 0; // Alpha initialisé à 0 (transparent)
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t_copy_end);

    wlr_buffer_end_data_ptr_access(cache.offscreen);

    timespec t_tex_start, t_tex_end;
    clock_gettime(CLOCK_MONOTONIC, &t_tex_start);
    Ref<Image> img = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, cache.bytes);

    Ref<ImageTexture> img_tex = Object::cast_to<ImageTexture>(tex.ptr());
    if (img_tex.is_null() || out_w != w || out_h != h) {
        img_tex = ImageTexture::create_from_image(img);
        tex = img_tex;
    } else {
        img_tex->update(img);
    }
    clock_gettime(CLOCK_MONOTONIC, &t_tex_end);

    auto ms = [](const timespec &a, const timespec &b) {
        return (b.tv_sec - a.tv_sec) * 1000.0 + (b.tv_nsec - a.tv_nsec) / 1e6;
    };
    double d_render = ms(t_render_start, t_render_end);
    double d_memcpy = ms(t_copy_start, t_copy_end);
    double d_tex = ms(t_tex_start, t_tex_end);
    double d_total = d_render + d_memcpy + d_tex;
    if (d_total > 2.0) {
        UtilityFunctions::print("waylandgodot: [CPU_READBACK] capture ", w, "x", h,
            " render=", d_render, "ms memcpy=", d_memcpy,
            "ms tex_upload=", d_tex,
            "ms TOTAL=", d_total, "ms");
    }
    out_w = w;
    out_h = h;
    return true;
}

// =====================================================================
// Callbacks wlroots
// =====================================================================

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

    UtilityFunctions::print("waylandgodot: new_toplevel reçu, id=", id,
        " app_id=", toplevel->app_id ? String::utf8(toplevel->app_id) : String("(pas encore fixé)"));

    (void)id;
}

void WlrCompositor::on_new_toplevel_decoration(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, new_toplevel_decoration_listener);
    auto *decoration = static_cast<wlr_xdg_toplevel_decoration_v1 *>(data);

    // Associer la décoration à la WindowState du toplevel correspondant
    // (xwayland-satellite la demande juste après avoir créé le toplevel).
    for (auto &[id, ws] : self->windows) {
        if (ws.toplevel == decoration->toplevel) {
            ws.decoration = decoration;
            ws.decoration_mode_pending = true;
            ws.decoration_request_mode_listener.notify = WlrCompositor::on_toplevel_decoration_request_mode;
            wl_signal_add(&decoration->events.request_mode, &ws.decoration_request_mode_listener);
            ws.decoration_destroy_listener.notify = WlrCompositor::on_toplevel_decoration_destroy;
            wl_signal_add(&decoration->events.destroy, &ws.decoration_destroy_listener);
            // Ne PAS appeler set_mode() ici : à ce stade (get_toplevel_decoration)
            // la surface n'a pas encore fait son premier commit, et set_mode()
            // appelle schedule_configure() qui assert sur initialized → crash.
            // La confirmation est différée au premier commit (on_surface_commit).
            return;
        }
    }
    // Toplevel pas encore enregistré (rare) : sans listener, aucun mode ne
    // sera confirmé. Le client retombe alors sur son comportement par défaut
    // (CSD pour GTK/Qt, pas de barre pour xwayland-satellite).
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
}

// --- Capture fenêtre (ext_foreign_toplevel_image_capture_source_manager) --

void WlrCompositor::on_foreign_toplevel_source_manager_bind(wl_client *client,
        void *data, uint32_t version, uint32_t id) {
    WlrCompositor *self = static_cast<WlrCompositor *>(data);
    wl_resource *resource = wl_resource_create(client,
        &ext_foreign_toplevel_image_capture_source_manager_v1_interface, version, id);
    if (!resource) {
        wl_client_post_no_memory(client);
        return;
    }
    wl_resource_set_implementation(resource, &foreign_toplevel_source_manager_impl, self, nullptr);
}

void WlrCompositor::on_foreign_toplevel_source_manager_create_source(wl_client *client,
        wl_resource *resource, uint32_t source, wl_resource *toplevel_handle) {
    WlrCompositor *self = static_cast<WlrCompositor *>(wl_resource_get_user_data(resource));

    wlr_ext_foreign_toplevel_handle_v1 *handle = nullptr;
    if (toplevel_handle) {
        handle = wlr_ext_foreign_toplevel_handle_v1_from_resource(toplevel_handle);
    }
    WindowState *ws = nullptr;
    if (handle) {
        ws = static_cast<WindowState *>(handle->data);
    }
    if (!ws || !self->foreign_toplevel_list) {
        // Source inerte : pas de capture possible (fenêtre déjà fermée ou
        // handle inconnu). Le client recevra "stopped" dès qu'il essaiera.
        wlr_ext_image_capture_source_v1_create_resource(nullptr, client, source);
        return;
    }

    if (!ws->image_source) {
        auto *src = new WlrCompositorToplevelSource();
        src->compositor = self;
        src->window = ws;
        wlr_ext_image_capture_source_v1_init(&src->base, &toplevel_source_impl);
        ws->image_source = src;
        self->update_toplevel_source_constraints(src);
    }
    wlr_ext_image_capture_source_v1_create_resource(&ws->image_source->base, client, source);
}

void WlrCompositor::on_foreign_toplevel_source_manager_destroy(wl_client *client,
        wl_resource *resource) {
    wl_resource_destroy(resource);
}

void WlrCompositor::update_toplevel_source_constraints(WlrCompositorToplevelSource *source) {
    WindowState *ws = source->window;
    if (!ws || !renderer || !allocator) return;
    if (ws->width <= 0 || ws->height <= 0) return;

    // Le buffer de capture exact-size (w×h) : recopié depuis offscreen dans
    // _process, et c'est lui que copy_frame fournit à wlroots (tailles
    // identiques exigées par wlr_ext_image_copy_capture_frame_v1_copy_buffer).
    // Même format linéaire que le buffer offscreen des fenêtres (le renderer
    // peut le cibler via begin_buffer_pass, en GPU comme en fallback pixman).
    if (!source->capture_buffer ||
            source->capture_buffer->width != ws->width ||
            source->capture_buffer->height != ws->height) {
        if (source->capture_buffer) {
            wlr_buffer_drop(source->capture_buffer);
            source->capture_buffer = nullptr;
        }
        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
        if (formats) {
            static const uint32_t preferred[] = {
                DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888,
                DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888,
            };
            for (uint32_t f : preferred) {
                const wlr_drm_format *fmt = wlr_drm_format_set_get(formats, f);
                if (!fmt) continue;
                uint64_t linear_mod = DRM_FORMAT_MOD_LINEAR;
                struct wlr_drm_format linear_fmt = {};
                linear_fmt.format = f;
                linear_fmt.modifiers = &linear_mod;
                linear_fmt.len = 1;
                wlr_buffer *buf = wlr_allocator_create_buffer(
                    allocator, ws->width, ws->height, &linear_fmt);
                if (buf) {
                    source->capture_buffer = buf;
                    break;
                }
            }
        }
    }

    // Les contraintes annoncées à portal-wlr (tailles/formats/dmabuf device)
    // sont extraites d'un swapchain temporaire, comme le fait wlroots pour
    // les sources output. Le swapchain est détruit juste après : wlroots en
    // copie les formats et la largeur/hauteur.
    const wlr_drm_format_set *formats = wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF);
    const wlr_drm_format *fmt = formats ? wlr_drm_format_set_get(formats, DRM_FORMAT_XRGB8888) : nullptr;
    if (!fmt) return;

    wlr_swapchain *swapchain = wlr_swapchain_create(allocator, ws->width, ws->height, fmt);
    if (!swapchain) return;
    wlr_ext_image_capture_source_v1_set_constraints_from_swapchain(
        &source->base, swapchain, renderer);
    wlr_swapchain_destroy(swapchain);
}

// Recopie la sous-région w×h de l'offscreen (pad'dé à 64px) vers le buffer
// exact-size de la source, une fois par frame dans _process. C'est ce buffer
// que copy_frame présente à wlroots lors des captures de fenêtre.
void WlrCompositor::blit_toplevel_capture(WlrCompositorToplevelSource *source) {
    WindowState *ws = source->window;
    if (!ws || !source->capture_buffer || !ws->capture_cache.offscreen) return;
    if (!renderer) return;
    if (source->capture_buffer->width != ws->width ||
            source->capture_buffer->height != ws->height) {
        update_toplevel_source_constraints(source);
    }

    wlr_render_pass *pass = wlr_renderer_begin_buffer_pass(
        renderer, source->capture_buffer, nullptr);
    if (!pass) return;

    wlr_render_rect_options clear = {};
    clear.box.x = 0;
    clear.box.y = 0;
    clear.box.width = source->capture_buffer->width;
    clear.box.height = source->capture_buffer->height;
    clear.color = {0.0f, 0.0f, 0.0f, 0.0f};
    clear.blend_mode = WLR_RENDER_BLEND_MODE_NONE;
    wlr_render_pass_add_rect(pass, &clear);

    wlr_texture *tex = wlr_texture_from_buffer(renderer, ws->capture_cache.offscreen);
    if (tex) {
        wlr_render_texture_options opts = {};
        opts.texture = tex;
        opts.dst_box.x = 0;
        opts.dst_box.y = 0;
        opts.dst_box.width = ws->width;
        opts.dst_box.height = ws->height;
        opts.src_box.x = 0;
        opts.src_box.y = 0;
        opts.src_box.width = ws->width;
        opts.src_box.height = ws->height;
        opts.transform = WL_OUTPUT_TRANSFORM_NORMAL;
        opts.filter_mode = WLR_SCALE_FILTER_NEAREST;
        wlr_render_pass_add_texture(pass, &opts);
        wlr_texture_destroy(tex);
    }
    wlr_render_pass_submit(pass);
}

void WlrCompositor::destroy_toplevel_image_source(WlrCompositorToplevelSource *source) {
    if (!source) return;
    WindowState *ws = source->window;
    if (ws && ws->image_source == source) {
        ws->image_source = nullptr;
    }
    if (source->capture_buffer) {
        wlr_buffer_drop(source->capture_buffer);
        source->capture_buffer = nullptr;
    }
    wlr_ext_image_capture_source_v1_finish(&source->base);
    delete source;
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

// =====================================================================
// SurfaceCommitTracker — détection des commits de sous-surfaces
// =====================================================================
// La surface racine commit (on_surface_commit) ne suffit pas : une
// sous-surface (vidéo DMABUF, overlay WebRender…) commite indépendamment.
// Un tracker par sous-surface marque alors la fenêtre dirty, pour que
// _process la recapture à la prochaine frame.

void SurfaceCommitTracker::on_commit(wl_listener *listener, void *data) {
    SurfaceCommitTracker *tracker = wl_container_of(listener, tracker, commit);
    if (tracker->ws) {
        tracker->ws->dirty = true;
    }
}

void SurfaceCommitTracker::on_destroy(wl_listener *listener, void *data) {
    SurfaceCommitTracker *tracker = wl_container_of(listener, tracker, destroy);
    WindowState *ws = tracker->ws;
    auto *surface = static_cast<wlr_surface *>(data);

    // Retirer les listeners AVANT de supprimer le tracker : la surface est
    // en cours de destruction et wlroots va la libérer juste après (sinon
    // la liste de signaux garderait un pointeur vers de la mémoire libre).
    wl_list_remove(&tracker->commit.link);
    wl_list_remove(&tracker->destroy.link);

    auto it = ws->sub_surface_trackers.find(surface);
    if (it != ws->sub_surface_trackers.end()) {
        ws->sub_surface_trackers.erase(it);
    }
}

void WindowState::clear_sub_surface_trackers() {
    for (auto &[surface, tracker] : sub_surface_trackers) {
        wl_list_remove(&tracker.commit.link);
        wl_list_remove(&tracker.destroy.link);
    }
    sub_surface_trackers.clear();
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

// --- XDG toplevel requests ------------------------------------------------
// Le protocole xdg-shell exige que le compositeur réponde à chaque
// demande (fullscreen, maximize, etc.) par un configure, même s'il
// ignore la demande. Ne pas le faire est une violation de protocole.
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

// --- Popups ------------------------------------------------------------

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

    UtilityFunctions::print("waylandgodot: new_popup reçu, id=", id, " parent_window_id=", ws->id);
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

    UtilityFunctions::print("waylandgodot: new_popup (sous-menu) reçu, id=", id,
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

// =====================================================================
// Layer shell (wlr-layer-shell-unstable-v1) — waybar, rofi, notifications
// =====================================================================
// Les layer surfaces sont des surfaces "ancrées" à l'output : le layout
// (position + taille) est calculé ici en fonction des ancres, marges et
// exclusive zones, exactement comme dans un compositeur 2D classique. Le
// script Godot ne fait que positionner un overlay 2D aux coordonnées
// (x, y, width, height) calculées ici.

// Retire la zone occupée par une layer surface exclusive du "usable area"
// pour les surfaces suivantes (algorithme standard de wlr-layer-shell).
// Réserve l'espace exclusif dans la zone utilisable. Miroir exact de
// layer_surface_exclusive_zone de wlroots : seule l'arête ancrée est
// réduite (switch sur la combinaison d'ancres), pas toutes les arêtes.
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

// Calcule la boîte (dans l'output, origine haut-gauche) d'une layer surface
// depuis son état courant et la zone utilisable. Miroir exact de
// wlr_scene_layer_surface_v1_configure de wlroots.
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

// =====================================================================
// ext-session-lock-v1 (lockscreen quickshell/dms)
// =====================================================================

bool WlrCompositor::session_lock_active() const {
    return session_lock.lock != nullptr;
}

// Renvoie la première surface de verrouillage mappée (il ne devrait y en
// avoir qu'une : le protocole autorise une surface par output, et ce
// compositeur n'a qu'un seul output virtuel).
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

// =====================================================================
// Cycle de vie
// =====================================================================

void WlrCompositor::start_headless() {
    // Journal wlroots : honorer WLR_LOGGER (debug/info/error). Par défaut on
    // reste en WLR_ERROR (comportement historique). Sans wlr_log_init(), la
    // variable d'environnement est ignorée et les logs DEBUG sont perdus —
    // gênant pour diagnostiquer les captures (wlr_screencopy/ext_image_capture).
    enum wlr_log_importance wlr_level = WLR_ERROR;
    const char *wlr_logger = getenv("WLR_LOGGER");
    if (wlr_logger) {
        if (strcmp(wlr_logger, "debug") == 0) wlr_level = WLR_DEBUG;
        else if (strcmp(wlr_logger, "info") == 0) wlr_level = WLR_INFO;
    }
    wlr_log_init(wlr_level, nullptr);

    display = wl_display_create();
    event_loop = wl_display_get_event_loop(display);

    backend = wlr_headless_backend_create(event_loop);
    if (!backend) {
        UtilityFunctions::printerr("waylandgodot: échec création backend headless");
        return;
    }

    // Désormais, le pipeline Vulkan zero-copy importe les DMA-BUF
    // directement comme VkImage — pas de readback CPU. Le renderer GPU
    // (GLES2/GBM) est donc préféré car il active DMA-BUF, nécessaire pour
    // l'import Vulkan. Pixman n'est que le fallback si le GPU indisponible.
    if (getenv("WAYLANDGODOT_FORCE_PIXMAN")) {
        setenv("WLR_RENDERER", "pixman", 1);
        renderer = wlr_renderer_autocreate(backend);
        if (!renderer) {
            UtilityFunctions::printerr("waylandgodot: wlr_renderer_autocreate a échoué ",
                "(même Pixman n'est pas disponible ?)");
            return;
        }
        allocator = wlr_allocator_autocreate(backend, renderer);
        dmabuf_available = false;
        UtilityFunctions::print("waylandgodot: utilisation du renderer Pixman (CPU, forcé)");
    }

    // Try GPU renderer first — enables DMA-BUF + Vulkan zero-copy.
    if (!renderer) {
        renderer = wlr_renderer_autocreate(backend);
        if (renderer) {
            allocator = wlr_allocator_autocreate(backend, renderer);
            if (check_dmabuf_linear_available()) {
                dmabuf_available = true;
                UtilityFunctions::print("waylandgodot: renderer GPU (GLES2/GBM), ",
                    "dmabuf linéaire disponible");
            } else {
                UtilityFunctions::print("waylandgodot: renderer GPU créé mais ",
                    "dmabuf linéaire indisponible");
            }
        }
    }

    // Fallback: Pixman (rendu logiciel, pas de DMA-BUF)
    if (!renderer || (!dmabuf_available && !getenv("WAYLANDGODOT_FORCE_PIXMAN"))) {
        if (renderer) {
            wlr_allocator_destroy(allocator);
            wlr_renderer_destroy(renderer);
            renderer = nullptr;
            allocator = nullptr;
        }
        setenv("WLR_RENDERER", "pixman", 1);
        renderer = wlr_renderer_autocreate(backend);
        if (!renderer) {
            UtilityFunctions::printerr("waylandgodot: wlr_renderer_autocreate a échoué ",
                "(même Pixman n'est pas disponible ?)");
            return;
        }
        allocator = wlr_allocator_autocreate(backend, renderer);
        dmabuf_available = false;
        UtilityFunctions::print("waylandgodot: utilisation du renderer Pixman (CPU, fallback)");
    }

    wlr_renderer_init_wl_display(renderer, display);

    // wl_shm : indispensable pour les clients qui rendent en CPU via des
    // buffers partagés (waybar/Cairo, et le fallback des toolkits quand le
    // dma-buf est indisponible). Sans ce global, waybar échoue avec
    // "Failed to acquire the required resources" (le global wl_shm n'est
    // jamais annoncé), et GTK/Qt en shm-fallback ne peuvent pas committer.
    if (!wlr_renderer_init_wl_shm(renderer, display)) {
        UtilityFunctions::printerr("waylandgodot: échec initialisation du global wl_shm");
    }

    // --- Initialiser le pipeline Vulkan zero-copy si possible ---------
    //     Si VK_KHR_external_memory_fd est supporté par le pilote GPU,
    //     on pourra importer les DMA-BUF directement comme VkImage dans
    //     le RenderingDevice de Godot, sans passer par le mmap + copie CPU.
    if (dmabuf_available) {
        RenderingDevice *vrd = RenderingServer::get_singleton()->get_rendering_device();
        if (vulkan_import.initialize(vrd)) {
            gpu_pipeline_active = true;
            UtilityFunctions::print("waylandgodot: pipeline Vulkan zero-copy actif "
                "(DMA-BUF → VkImage → Texture2DRD)");
        } else {
            UtilityFunctions::print("waylandgodot: Vulkan DMA-BUF import indisponible, "
                "utilisation du fallback mmap CPU");
        }
    }

    wlr_output *fake_output = wlr_headless_add_output(backend, 1280, 720);
    if (fake_output) {
        headless_output = fake_output;
        // Attacher renderer + allocator à l'output. Sans cela, dès qu'un
        // client (portal-wlr/OBS, via zwlr_screencopy_v1 ou la source
        // ext_image_capture "output") déclenche wlr_output_configure_
        // primary_swapchain, wlroots tue le processus dans create_swapchain
        // (assertion output->allocator != NULL, types/output/swapchain.c).
        if (!wlr_output_init_render(fake_output, allocator, renderer)) {
            UtilityFunctions::printerr("waylandgodot: wlr_output_init_render a échoué "
                "(caps allocator/renderer incompatibles avec le backend headless)");
        }
        wlr_output_state state;
        wlr_output_state_init(&state);
        wlr_output_state_set_enabled(&state, true);
        wlr_output_state_set_custom_mode(&state, 1920, 1080, 0);
        wlr_output_commit_state(fake_output, &state);
        wlr_output_state_finish(&state);
        wlr_output_create_global(fake_output, display);
    } else {
        UtilityFunctions::printerr("waylandgodot: échec création output factice");
    }

    // zxdg_output_manager_v1 : requis par waybar 0.15 (et ses modules GTK),
    // qui échoue avec "Failed to acquire required resources." si le global
    // n'est pas annoncé. Le layout est minimal (un seul output à l'origine).
    output_layout = wlr_output_layout_create(display);
    if (output_layout) {
        wlr_output_layout_add_auto(output_layout, fake_output);
        if (!wlr_xdg_output_manager_v1_create(display, output_layout)) {
            UtilityFunctions::printerr("waylandgodot: échec création global zxdg_output_manager_v1");
        }
    } else {
        UtilityFunctions::printerr("waylandgodot: échec création output layout");
    }

    compositor = wlr_compositor_create(display, 6, renderer);
    xdg_shell = wlr_xdg_shell_create(display, 3);
    wlr_viewporter_create(display);
    wlr_subcompositor_create(display);

    // xdg-decoration-unstable-v1 : voir commentaire dans le header. Sans ce
    // global, xwayland-satellite dessine ses propres décorations et produit
    // des min/max invalides pour les fenêtres sans taille max (Electron,
    // github-desktop) → protocol error → panic → plus aucun X11 ne marche.
    xdg_decoration_manager = wlr_xdg_decoration_manager_v1_create(display);
    if (!xdg_decoration_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global xdg_decoration_manager_v1");
    } else {
        new_toplevel_decoration_listener.notify = WlrCompositor::on_new_toplevel_decoration;
        wl_signal_add(&xdg_decoration_manager->events.new_toplevel_decoration,
            &new_toplevel_decoration_listener);
    }

    // wlr-layer-shell-unstable-v1 (waybar, rofi, notifications...). Le
    // header de protocole est généré depuis protocols/ par le SConstruct.
    layer_shell = wlr_layer_shell_v1_create(display, 4);
    if (!layer_shell) {
        UtilityFunctions::printerr("waylandgodot: échec création global wlr-layer-shell-v1");
    } else {
        new_layer_surface_listener.notify = WlrCompositor::on_new_layer_surface;
        wl_signal_add(&layer_shell->events.new_surface, &new_layer_surface_listener);
    }

    // ext-session-lock-v1 : le lockscreen de quickshell/dms (WlSessionLock
    // → ext_session_lock_manager_v1). Sans ce global, `dms ipc lock lock`
    // passe bien le shell en mode verrouillé mais aucune surface de
    // verrouillage ne peut être créée → écran noir/rien ne s'affiche.
    session_lock_manager = wlr_session_lock_manager_v1_create(display);
    if (!session_lock_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_session_lock_manager_v1");
    } else {
        new_session_lock_listener.notify = WlrCompositor::on_new_session_lock;
        wl_signal_add(&session_lock_manager->events.new_lock, &new_session_lock_listener);
    }

    // Session idle : ext_idle_notifier_v1 (les clients s'abonnent pour être
    // notifiés quand la session devient idle) + zwp_idle_inhibit_v1 (les
    // clients comme les lecteurs vidéo inhibent l'idle). wlroots gère le
    // comptage des timeouts ; le compositeur notifie chaque activité via
    // notify_activity() (voir les forward d'input) et bascule l'inhibition
    // via update_idle_inhibited().
    idle_notifier = wlr_idle_notifier_v1_create(display);
    if (!idle_notifier) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_idle_notifier_v1");
    }
    idle_inhibit_manager = wlr_idle_inhibit_v1_create(display);
    if (!idle_inhibit_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global zwp_idle_inhibit_manager_v1");
    } else {
        new_idle_inhibitor_listener.notify = WlrCompositor::on_new_idle_inhibitor;
        wl_signal_add(&idle_inhibit_manager->events.new_inhibitor, &new_idle_inhibitor_listener);
    }

    // Capture pour xdg-desktop-portal-wlr (OBS). wlroots fournit le manager
    // ext_image_copy_capture_v1 (sessions/frames), les sources "output"
    // (capture écran, alimentées par les commits de headless_output — voir
    // present_viewport_frame) et la liste des toplevels. Le manager de
    // sources "foreign toplevel" (capture fenêtre) n'existe pas dans
    // wlroots 0.19.3 : on l'implémente ici (voir
    // ext_foreign_toplevel_image_capture_source.c).
    image_copy_capture_manager = wlr_ext_image_copy_capture_manager_v1_create(display, 1);
    if (!image_copy_capture_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_image_copy_capture_manager_v1");
    }
    output_image_capture_source_manager = wlr_ext_output_image_capture_source_manager_v1_create(display, 1);
    if (!output_image_capture_source_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_output_image_capture_source_manager_v1");
    }
    foreign_toplevel_list = wlr_ext_foreign_toplevel_list_v1_create(display, 1);
    if (!foreign_toplevel_list) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_foreign_toplevel_list_v1");
    }
    foreign_toplevel_source_manager = wl_global_create(display,
        &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1, this,
        WlrCompositor::on_foreign_toplevel_source_manager_bind);
    if (!foreign_toplevel_source_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global ext_foreign_toplevel_image_capture_source_manager_v1");
    }
    // Fallback zwlr_screencopy_v1 pour les clients qui ne connaissent que ce
    // protocole (capture depuis les commits output, cf. present_viewport_frame).
    screencopy_manager = wlr_screencopy_manager_v1_create(display);
    if (!screencopy_manager) {
        UtilityFunctions::printerr("waylandgodot: échec création global zwlr_screencopy_manager_v1");
    }

    // Nécessaire pour les clients qui rendent via GPU/dmabuf (ex: Firefox
    // + WebRender). Sans ce global, ces clients tentent de committer des
    // buffers dmabuf que le compositeur ne peut pas interpréter -> la
    // fenêtre se mappe (xdg-shell OK) mais rien n'est jamais affiché.
    if (!wlr_linux_dmabuf_v1_create_with_renderer(display, 4, renderer)) {
        UtilityFunctions::printerr("waylandgodot: échec création global linux-dmabuf-v1");
    }
    seat = wlr_seat_create(display, "seat0");

    // Drag-and-drop: écouter les demandes de drag des clients (Dolphin, etc.)
    // et les accepter pour que le protocole wl_data_device fonctionne.
    request_start_drag_listener.notify = WlrCompositor::on_request_start_drag;
    wl_signal_add(&seat->events.request_start_drag, &request_start_drag_listener);

    // Drag-and-drop icon: suivre le drag actif pour afficher l'icône.
    start_drag_listener.notify = WlrCompositor::on_start_drag;
    wl_signal_add(&seat->events.start_drag, &start_drag_listener);

    wlr_data_device_manager_create(display);
    wlr_primary_selection_v1_device_manager_create(display);

    // Presse-papier fonctionnel entre fenêtres : sans ces deux listeners,
    // les globals ci-dessus sont bien annoncés aux clients mais aucune
    // source n'est jamais acceptée par le seat -> copier dans une fenêtre
    // et coller dans une autre ne fait rien.
    request_set_selection_listener.notify = WlrCompositor::on_request_set_selection;
    wl_signal_add(&seat->events.request_set_selection, &request_set_selection_listener);

    request_set_primary_selection_listener.notify = WlrCompositor::on_request_set_primary_selection;
    wl_signal_add(&seat->events.request_set_primary_selection, &request_set_primary_selection_listener);

    // Pointer constraints (zwp_pointer_constraints_v1) + relative pointer
    // (zwp_relative_pointer_v1) — nécessaires pour les jeux FPS qui
    // demandent un pointer lock via zwp_pointer_constraints_v1::lock_pointer.
    pointer_constraints = wlr_pointer_constraints_v1_create(display);
    relative_pointer_manager = wlr_relative_pointer_manager_v1_create(display);

    new_constraint_listener.notify = WlrCompositor::on_new_constraint;
    wl_signal_add(&pointer_constraints->events.new_constraint, &new_constraint_listener);

    wlr_keyboard_init(&virtual_keyboard, &waylandgodot_KEYBOARD_IMPL, "waylandgodot-vkbd");

    // Keymap xkb par défaut (layout "fr"). Configurable depuis le jeu via
    // set_keyboard_layout (menu pause) : reload_keymap() est réappelé à chaud.
    reload_keymap();

    wlr_seat_set_keyboard(seat, &virtual_keyboard);
    wlr_seat_set_capabilities(seat, WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

    keyboard_key_listener.notify = WlrCompositor::on_keyboard_key;
    wl_signal_add(&virtual_keyboard.events.key, &keyboard_key_listener);
    keyboard_modifiers_listener.notify = WlrCompositor::on_keyboard_modifiers;
    wl_signal_add(&virtual_keyboard.events.modifiers, &keyboard_modifiers_listener);

    // Diagnostics popups : début/fin du grab pointeur xdg-popup. La fin du
    // grab == popup_done envoyé aux clients == menu fermé par le compositeur.
    pointer_grab_begin_listener.notify = WlrCompositor::on_pointer_grab_begin;
    wl_signal_add(&seat->events.pointer_grab_begin, &pointer_grab_begin_listener);
    pointer_grab_end_listener.notify = WlrCompositor::on_pointer_grab_end;
    wl_signal_add(&seat->events.pointer_grab_end, &pointer_grab_end_listener);

    new_toplevel_listener.notify = WlrCompositor::on_new_toplevel;
    wl_signal_add(&xdg_shell->events.new_toplevel, &new_toplevel_listener);

    // Socket à nom STABLE ("cyberrealm-0") : les apps lancées dans le jeu
    // (cyberrealm-launch depuis Plasma, ou launc_app in-game) utilisent ce
    // nom de socket via WAYLAND_DISPLAY pour se connecter au compositeur du
    // jeu. Un socket orphelin (crash précédent) est supprimé d'abord, sinon
    // wl_display_add_socket échoue. En cas de collision, repli sur un nom
    // aléatoire (dans ce cas les apps du bureau ne seront pas redirigées).
    const char *socket = nullptr;
    {
        const char *rt = getenv("XDG_RUNTIME_DIR");
        if (rt) {
            std::string path = std::string(rt) + "/cyberrealm-0";
            unlink(path.c_str());
        }
        if (wl_display_add_socket(display, "cyberrealm-0") == 0) {
            socket = "cyberrealm-0";
        } else {
            socket = wl_display_add_socket_auto(display);
        }
    }
    if (!socket) {
        UtilityFunctions::printerr("waylandgodot: impossible de créer le socket Wayland");
        return;
    }
    setenv("WAYLAND_DISPLAY", socket, 1);
    setenv("XDG_CURRENT_DESKTOP", portal_backend.utf8().get_data(), 1);
    
    // --- VARIABLES D'ENVIRONNEMENT WAYLAND ET SYSTÈME ---
    
    // 1. Session et Toolkits Wayland
    setenv("XDG_SESSION_TYPE", "wayland", 0);
    setenv("GDK_BACKEND", "wayland", 0);       
    setenv("QT_QPA_PLATFORM", "wayland", 0);   
    setenv("MOZ_ENABLE_WAYLAND", "1", 0);      
    setenv("_JAVA_AWT_WM_NONREPARENTING", "1", 0);

    // 2. Désactiver les portails (très utile pour éviter les blocages sur les FileDialogs GTK)
    // On utilise '1' pour forcer l'écrasement quoi qu'il arrive
    setenv("GTK_USE_PORTAL", "0", 1);
    setenv("GIO_USE_PORTALS", "0", 1);
    // ----------------------------------------------------

    // 3. Thème sombre : force les apps GTK (GTK3/GTK4, et Firefox qui suit la
    // préférence GTK) à s'ouvrir en sombre, cohérent avec l'ambiance du jeu.
    // Écrasement forcé : le thème sombre prime sur un éventuel GTK_THEME.
    // setenv("GTK_THEME", "Adwaita:dark", 1);
    // 4. Qt/KDE : sans XDG_CURRENT_DESKTOP=KDE, Qt choisit un platformtheme
    // générique qui ignore kdeglobals → apps KDE (Dolphin...) en clair. Forcer
    // le platformtheme "kde" (KDEPlasmaPlatformTheme6 de plasma-integration)
    // fait lire ~/.config/kdeglobals directement → même rendu sombre que le
    // host. Laisse XDG_CURRENT_DESKTOP=dwl:wlr intact pour la capture OBS.
    setenv("QT_QPA_PLATFORMTHEME", "kde", 0);
    // ----------------------------------------------------
    


    if (!polkit_agent_path.is_empty()) {
        launch_polkit_agent();
    }

    if (!wlr_backend_start(backend)) {
        UtilityFunctions::printerr("waylandgodot: échec démarrage backend");
        return;
    }

    // Curseur Wayland : wlr_cursor + wlr_xcursor_manager. Le curseur est
    // requis pour que zwlr_screencopy_v1 et ext_image_capture supportent le
    // cursor mode embedded (mode 1). Sans lui, xdg-desktop-portal-wlr rejette
    // la demande → "Unavailable cursor mode 1" → OBS ne peut pas capturer.
    // Le curseur est rendu dans le frame screencopy par wlroots
    // automatiquement lorsque le wlr_cursor est attaché à l'output layout.
    // INIT APRÈS wlr_backend_start : l'output headless doit être démarré
    // avant toute opération cursor (attach/warp/set_xcursor).
    UtilityFunctions::print("waylandgodot: init cursor...");
    cursor = wlr_cursor_create();
    if (cursor) {
        cursor_manager = wlr_xcursor_manager_create(nullptr, 24);
        if (cursor_manager) {
            wlr_xcursor_manager_load(cursor_manager, 1.0f);
            UtilityFunctions::print("waylandgodot: wlr_cursor + xcursor_manager OK");
        } else {
            UtilityFunctions::printerr("waylandgodot: échec création xcursor_manager");
        }
    } else {
        UtilityFunctions::printerr("waylandgodot: échec création wlr_cursor");
    }

    UtilityFunctions::print("waylandgodot: compositeur headless prêt sur ", socket);
}

static void wlr_surface_send_frame_done_tree(wlr_surface *surface,
                                             const timespec *now) {
    if (!surface) {
        return;
    }
    wlr_surface_for_each_surface(surface,
        +[](wlr_surface *sub, int, int, void *data) {
            wlr_surface_send_frame_done(sub, static_cast<const timespec *>(data));
        },
        const_cast<timespec *>(now));
}

void WlrCompositor::_process(double delta) {
    if (!event_loop) return;

    // Flush deferred Vulkan releases from last frame BEFORE dispatching
    // new events (which may trigger new captures).
    if (gpu_pipeline_active) {
        vulkan_import.flush_pending();
    }

    wl_event_loop_dispatch(event_loop, 0);
    if (display) wl_display_flush_clients(display);



    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        wlr_surface_send_frame_done_tree(ws.toplevel->base->surface, &now);
    }
    for (auto &pair : popups) {
        PopupState &ps = pair.second;
        if (ps.popup && ps.popup->base && ps.popup->base->surface) {
            wlr_surface_send_frame_done_tree(ps.popup->base->surface, &now);
        }
    }
    for (auto &pair : layer_surfaces) {
        LayerSurfaceState &ls = pair.second;
        wlr_surface *surf = ls.layer_surface ? ls.layer_surface->surface : nullptr;
        if (surf && surf->mapped) {
            wlr_surface_send_frame_done_tree(surf, &now);
        }
    }
    for (auto &pair : session_lock.surfaces) {
        SessionLockSurfaceState &ss = pair.second;
        wlr_surface *surf = ss.lock_surface ? ss.lock_surface->surface : nullptr;
        if (surf && surf->mapped) {
            wlr_surface_send_frame_done_tree(surf, &now);
        }
    }

    // Recapture des fenêtres : uniquement celles dont le contenu a changé.
    // Un commit (racine via on_surface_commit, ou n'importe quelle
    // sous-surface via les SurfaceCommitTracker) pose ws.dirty. Dans un
    // compositeur 3D toutes les fenêtres sont visibles simultanément, mais
    // une fenêtre statique ne doit PAS être re-rendue à chaque frame : le
    // render pass GL + la synchronisation DMA-BUF bloquante + l'import
    // Vulkan coûtent chacun plusieurs ms, et le total grossissait
    // linéairement avec le nombre de fenêtres ouvertes. Le filet de
    // sécurité périodique (WINDOW_SAFETY_RECAPTURE_INTERVAL) rattrape les
    // sous-surfaces apparues entre deux sync.
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (ws.toplevel && ws.toplevel->base && ws.toplevel->base->surface) {
            sync_window_subsurfaces(ws);
            if (ws.dirty || (frame_counter % WINDOW_SAFETY_RECAPTURE_INTERVAL) == 0) {
                if (capture_surface(ws.toplevel->base->surface,
                        ws.texture, ws.width, ws.height, ws.capture_cache)) {
                    ws.dirty = false;
                    emit_signal("window_texture_updated", ws.id, ws.texture,
                        ws.width, ws.height);
                }
            }
        }
        // Capture fenêtre OBS : copier l'offscreen (toujours valide, même
        // sans recapture à cette frame) vers le buffer exact-size de la
        // source (s'il y a une session active).
        if (ws.image_source) {
            WlrCompositorToplevelSource *src = ws.image_source;
            if (src->num_started > 0 || src->needs_frame) {
                blit_toplevel_capture(src);
            }
        }
    }

    // Capture de fenêtres pour OBS (xdg-desktop-portal-wlr) : produire les
    // frames demandées par les sessions ext_image_copy_capture actives.
    // Le buffer offscreen vient d'être re-rendu juste au-dessus ; les
    // contraintes (taille) suivent la géométrie courante de la fenêtre.
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (!ws.image_source) continue;
        WlrCompositorToplevelSource *src = ws.image_source;
        if (ws.width > 0 && ws.height > 0 &&
                (ws.width != (int)src->base.width || ws.height != (int)src->base.height)) {
            update_toplevel_source_constraints(src);
        }
        if (src->needs_frame && ws.width > 0 && ws.height > 0) {
            pixman_region32_t damage;
            pixman_region32_init_rect(&damage, 0, 0, ws.width, ws.height);
            wlr_ext_image_capture_source_v1_frame_event event = { .damage = &damage };
            wl_signal_emit_mutable(&src->base.events.frame, &event);
            pixman_region32_fini(&damage);
            src->needs_frame = false;
        }
    }

    // Recapture des popups à chaque frame (throttlé à 1 frame sur 2) :
    // Firefox rend le contenu des popups dans des sous-surfaces qui
    // committent indépendamment de la surface racine. Le commit_listener
    // du popup ne se déclenche pas sur ces commits, donc sans recapture
    // périodique la texture reste vide (alpha=0 -> shader discard -> popup
    // totalement transparent). Le contenu d'un popup (menu, dropdown,
    // tooltip) n'a pas besoin de suivre à 60Hz : recapturer à ~30Hz divise
    // par deux le coût (render pass + sync GPU + copie CPU + reupload
    // texture) de chaque popup ouvert, sans lag perceptible. Un popup
    // reste par ailleurs recapturé immédiatement sur son propre commit via
    // on_popup_commit, cette boucle n'est qu'un filet de sécurité pour les
    // sous-surfaces désynchronisées.
    frame_counter++;
    if ((frame_counter & 1) == 0) {
        for (auto &pair : popups) {
            PopupState &ps = pair.second;
            if (ps.popup && ps.popup->base && ps.popup->base->surface) {
                if (capture_surface(ps.popup->base->surface,
                        ps.texture, ps.width, ps.height, ps.capture_cache)) {
                    emit_signal("popup_texture_updated", ps.id, ps.texture,
                        ps.width, ps.height);
                }
            }
        }
    }

    // Recapture des layer surfaces : uniquement celles qui ont committé
    // depuis la dernière capture (dirty posé par on_layer_surface_commit),
    // plus un filet de sécurité périodique pour les sous-surfaces qui
    // committent indépendamment de la surface racine (rare côté quickshell,
    // mais le rendu passe alors par wlr_surface_for_each_surface). Une
    // surface statique (barre sans animation) n'est plus rendue/re-samplée
    // à chaque frame, et une surface animée n'est plus capturée deux fois
    // (commit handler + boucle).
    for (auto &pair : layer_surfaces) {
        LayerSurfaceState &ls = pair.second;
        wlr_surface *surf = ls.layer_surface ? ls.layer_surface->surface : nullptr;
        if (!surf || !surf->mapped) continue;
        // La couche background (fond d'écran) n'est jamais rendue côté Godot.
        if (ls.layer_surface->current.layer == ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND) {
            ls.dirty = false;
            continue;
        }
        if (!ls.dirty && (frame_counter % LAYER_SAFETY_RECAPTURE_INTERVAL) != 0) {
            continue;
        }
        if (!capture_surface(surf, ls.texture, ls.width, ls.height, ls.capture_cache)) {
            continue;
        }
        ls.dirty = false;
        emit_signal("layer_surface_texture_updated", ls.id, ls.texture,
            ls.width, ls.height);
    }

    // Recapture des surfaces de verrouillage (le lockscreen anime son fond
    // et son champ password; on le resample comme les autres surfaces).
    for (auto &pair : session_lock.surfaces) {
        SessionLockSurfaceState &ss = pair.second;
        wlr_surface *surf = ss.lock_surface ? ss.lock_surface->surface : nullptr;
        if (!surf || !surf->mapped) continue;
        if (!capture_surface(surf, ss.texture, ss.width, ss.height, ss.capture_cache)) {
            continue;
        }
        emit_signal("session_lock_surface_texture_updated", ss.id, ss.texture,
            ss.width, ss.height);
    }

    // Recapture du drag icon si un drag est actif.
    if (active_drag && active_drag->icon && active_drag->icon->surface) {
        if (capture_surface(active_drag->icon->surface,
                drag_icon_texture, drag_icon_width, drag_icon_height,
                drag_icon_cache)) {
            emit_signal("drag_icon_updated", drag_icon_texture,
                drag_icon_width, drag_icon_height);
        }
    } else if (drag_icon_texture.is_valid()) {
        drag_icon_texture = Ref<Texture2D>();
        drag_icon_width = 0;
        drag_icon_height = 0;
        RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
        drag_icon_cache.reset(rd);
        emit_signal("drag_icon_removed");
    }
}

// --- Input ---------------------------------------------------------------

// =====================================================================
// Session idle (ext-idle-notify-v1 + zwp_idle_inhibit-v1)
// =====================================================================

// Signale une activité utilisateur (input) au notifier idle : wlroots
// réarme ses timers et reporte les notifications idle aux clients abonnés.
// Appelé par toutes les fonctions de forward d'input ci-dessous, et exposé
// à Godot pour couvrir l'input du joueur qui ne vise aucune surface.
void WlrCompositor::notify_activity() {
    UtilityFunctions::print("[idle] notify_activity called");
    if (idle_notifier && seat) {
        wlr_idle_notifier_v1_notify_activity(idle_notifier, seat);
    }
}

// Recalcule l'état inhibé : vrai si au moins un inhibiteur zwp_idle_inhibit_v1
// a sa surface visible (mapped). Un inhibiteur posé sur une fenêtre masquée
// ou un popup fermé ne doit pas bloquer l'idle.
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

void WlrCompositor::notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y) {
    if (!surface || !seat) return;
    uint32_t time = get_time_msec();

    // Tant qu'un bouton est enfoncé (le clic qui vient d'ouvrir un menu,
    // grab implicite), ne pas déplacer le focus pointeur vers un popup :
    // entrer le popup pendant le clic est interprété par GTK/Firefox comme
    // une violation de grab et ferme le menu à l'instant de l'enter (même
    // bug corrigé dans mutter, "wayland: Do not force pointer focus on
    // popups"). Le focus bougera vers le popup au mouvement suivant, une
    // fois le bouton relâché.
    if (seat->pointer_state.button_count > 0) {
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

// Auto-guérison des boutons "perdus" : si on reçoit un appui alors que le
// bouton est déjà marqué enfoncé (un relâchement précédent s'est perdu, par
// ex. tombé dans le vide ou sur un popup sans gestion du clic droit),
// wlroots incrémenterait n_pressed et AVALERAIT le relâchement suivant : le
// client croirait le bouton enfoncé pour toujours (menu qui reste "coincé").
// On émet donc d'abord un relâchement synthétique vers la surface focusée
// (ce qui rétablit la cohérence côté client), puis le nouvel appui part
// normalement.
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

    UtilityFunctions::print("waylandgodot: button id=", window_id,
        " pressed=", pressed,
        " t=", get_time_msec(),
        " focus_ok=", (ws && seat->pointer_state.focused_surface == ws->toplevel->base->surface));

    if (pressed) {
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
// Début du grab pointeur posé par un popup xdg (xdg_popup.grab) : GTK/
// Firefox vient de demander un popup menu et wlroots a instauré le grab.
void WlrCompositor::on_pointer_grab_begin(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, pointer_grab_begin_listener);
    (void)data;
}

// Fin du grab pointeur xdg-popup : wlroots a appelé xdg_popup_grab_end(),
// c'est-à-dire que popup_done a été envoyé à TOUS les popups du grab (GTK
// ferme alors le menu). C'est LE signal qui distingue une fermeture décidée
// par le compositeur (popup_done) d'une fermeture initiée par le client.
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
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y, (int32_t)delta_y, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x, (int32_t)delta_x, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
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
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y, (int32_t)delta_y, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x, (int32_t)delta_x, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
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
    uint32_t time = get_time_msec();
    if (delta_y != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_VERTICAL_SCROLL,
            delta_y, (int32_t)delta_y, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    if (delta_x != 0.0) {
        wlr_seat_pointer_notify_axis(seat, time, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
            delta_x, (int32_t)delta_x, WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed) {
    notify_activity();
    if (!seat) return;

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
                return;
            }
            evdev_code = it->second;
        }
    } else {
        auto it = GODOT_TO_EVDEV.find(godot_physical_keycode);
        if (it == GODOT_TO_EVDEV.end()) {
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
        cd->self->emit_signal("pointer_lock_changed", cd->window_id, false);
        delete cd;
    };
    wl_signal_add(&constraint->events.destroy, &cdata->listener);
}

void WlrCompositor::on_request_start_drag(wl_listener *listener, void *data) {
    WlrCompositor *self = wl_container_of(listener, self, request_start_drag_listener);
    if (!self->seat) return;
    wlr_seat_request_start_drag_event *event = (wlr_seat_request_start_drag_event *)data;

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

void WlrCompositor::forward_pointer_relative_motion(int window_id, double dx, double dy, double dx_unaccel, double dy_unaccel) {
    notify_activity();
    if (!relative_pointer_manager || !seat) return;
    uint64_t time_usec = get_time_msec() * 1000;
    wlr_relative_pointer_manager_v1_send_relative_motion(
        relative_pointer_manager, seat, time_usec, dx, dy, dx_unaccel, dy_unaccel);
}

// --- Utilitaires -----------------------------------------------------------

String WlrCompositor::get_wayland_socket_name() const {
    const char *s = getenv("WAYLAND_DISPLAY");
    return s ? String(s) : String("");
}

void WlrCompositor::set_portal_backend(const String &backend) {
    portal_backend = backend;
    setenv("XDG_CURRENT_DESKTOP", backend.utf8().get_data(), 1);
}

String WlrCompositor::get_portal_backend() const {
    return portal_backend;
}

void WlrCompositor::set_cursor_position(double x, double y) {
    cursor_x = x;
    cursor_y = y;
}

void WlrCompositor::set_cursor_visible(bool visible) {
    cursor_visible = visible;
}

void WlrCompositor::set_polkit_agent(const String &path) {
    polkit_agent_path = path;
    if (!polkit_agent_path.is_empty()) {
        launch_polkit_agent();
    }
}

String WlrCompositor::get_polkit_agent() const {
    return polkit_agent_path;
}

void WlrCompositor::launch_polkit_agent() {
    if (polkit_agent_path.is_empty() || polkit_agent_pid > 0) return;
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        CharString cmd = polkit_agent_path.utf8();
        execl("/bin/sh", "sh", "-c", cmd.get_data(), (char *)nullptr);
        _exit(127);
    } else if (pid > 0) {
        polkit_agent_pid = pid;
        child_pids.push_back(pid);
        UtilityFunctions::print("waylandgodot: lancé agent polkit (pid ", pid, ")");
    } else {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour polkit_agent");
    }
}

void WlrCompositor::launch_app(const String &command) {
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        const char *home = getenv("HOME");
        if (home) chdir(home);
        CharString cmd = command.utf8();
        execl("/bin/sh", "sh", "-c", cmd.get_data(), (char *)nullptr);
        _exit(127);
    } else if (pid > 0) {
        child_pids.push_back(pid);
    } else {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour launch_app");
    }
}

// Liste tous les descendants directs ou indirects de `root` en parcourant
// /proc (chaîne PPID). Utilisé par shutdown_apps() pour atteindre aussi les
// processus qui ont quitté le groupe de leur parent via setsid()/setpgid()
// (apps lancées par un script de démarrage comme `dms run`) et qui
// échapperaient à un kill(-pid) de groupe. Vrai car le jeu est
// PR_SET_CHILD_SUBREAPER : les orphelins redeviennent ses enfants et la
// chaîne PPID reste fiable.
static void collect_descendants(pid_t root, std::vector<pid_t> &out) {
    std::unordered_map<pid_t, pid_t> ppid;
    DIR *dir = opendir("/proc");
    if (!dir) {
        return;
    }
    dirent *ent;
    while ((ent = readdir(dir)) != nullptr) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') {
            continue;
        }
        pid_t pid = (pid_t)atoi(ent->d_name);
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
        FILE *f = fopen(path, "r");
        if (!f) {
            continue;
        }
        char buf[1024];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        if (n == 0) {
            continue;
        }
        buf[n] = '\0';
        // Format : "pid (comm) state ppid ..." — comm peut contenir des
        // parenthèses, on cherche donc la DERNIÈRE ')'.
        char *rp = strrchr(buf, ')');
        if (!rp) {
            continue;
        }
        char state;
        pid_t parent = -1;
        if (sscanf(rp + 1, " %c %d", &state, &parent) == 2 && parent > 0) {
            ppid[pid] = parent;
        }
    }
    closedir(dir);

    // Parcours en largeur depuis la racine : un processus est un descendant
    // si son parent est la racine ou est lui-même déjà un descendant.
    std::set<pid_t> descendants;
    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto &kv : ppid) {
            if (descendants.count(kv.first)) {
                continue;
            }
            if (kv.second == root || descendants.count(kv.second)) {
                descendants.insert(kv.first);
                changed = true;
            }
        }
    }
    out.assign(descendants.begin(), descendants.end());
}

// True si `pid` est un processus réellement vivant (un zombie compte comme
// "existant" pour kill(pid, 0) mais disparaît dès qu'il est récolté : il ne
// doit pas retarder la période de grâce).
static bool process_is_alive(pid_t pid) {
    if (pid <= 0 || kill(pid, 0) != 0) {
        return false;
    }
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) {
        return true; // /proc indisponible ou PID réapparu : conservateur
    }
    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) {
        return true;
    }
    buf[n] = '\0';
    char *rp = strrchr(buf, ')');
    if (!rp || rp[1] == '\0') {
        return true;
    }
    return rp[1] != 'Z';
}

static bool any_alive(const std::vector<pid_t> &pids) {
    for (pid_t pid : pids) {
        if (process_is_alive(pid)) {
            return true;
        }
    }
    return false;
}

static void reap_zombies() {
    int status;
    while (waitpid(-1, &status, WNOHANG) > 0) {
    }
}

// Termine proprement toutes les applications lancées dans le jeu via
// launch_app() : SIGTERM à TOUT l'arbre des descendants du jeu (pas seulement
// aux groupes des enfants directs — des daemons lancés par un script comme
// `dms run` font setsid()/setpgid() et échappent à leur groupe), période de
// grâce de 2 s pour laisser un arrêt propre, puis SIGKILL aux survivants.
// Appelé par le script Godot juste avant get_tree().quit() et par le
// destructeur.
void WlrCompositor::shutdown_apps() {
    if (child_pids.empty() && dbus_daemon_pid <= 0) {
        return;
    }

    // 1. SIGTERM à tous les descendants (via la chaîne PPID dans /proc).
    std::vector<pid_t> descendants;
    collect_descendants(getpid(), descendants);
    for (pid_t pid : descendants) {
        kill(pid, SIGTERM);
    }
    // Repli si /proc est indisponible : SIGTERM aux groupes connus.
    if (descendants.empty() && !child_pids.empty()) {
        for (pid_t pid : child_pids) {
            if (pid > 0) {
                kill(-pid, SIGTERM);
            }
        }
    }
    if (dbus_daemon_pid > 0) {
        kill(dbus_daemon_pid, SIGTERM);
        dbus_daemon_pid = -1;
    }

    // 2. Période de grâce : attendre la disparition de tout l'arbre (max 2 s).
    // L'arbre est re-scanné à chaque itération pour rattraper les processus
    // respawnés par un superviseur (script de démarrage, systemd user...).
    for (int i = 0; i < 40; ++i) {
        reap_zombies();
        descendants.clear();
        collect_descendants(getpid(), descendants);
        if (!any_alive(descendants)) {
            break;
        }
        usleep(50 * 1000);
    }

    // 3. SIGKILL aux survivants (arbre re-scanné : inclut les respawns et les
    // orphelins réparés vers le jeu pendant la grâce).
    descendants.clear();
    collect_descendants(getpid(), descendants);
    for (pid_t pid : descendants) {
        if (process_is_alive(pid)) {
            kill(pid, SIGKILL);
        }
    }
    if (descendants.empty() && !child_pids.empty()) {
        for (pid_t pid : child_pids) {
            if (pid > 0 && kill(-pid, 0) == 0) {
                kill(-pid, SIGKILL);
            }
        }
    }

    // 4. Récolter les zombies (les orphelins restants sont réparés à init à
    // la sortie du jeu, qui les récolte).
    reap_zombies();
    child_pids.clear();
}

// Lance xdg-desktop-portal + xdg-desktop-portal-wlr dans la session du jeu.
// Le daemon principal choisit son backend d'après XDG_CURRENT_DESKTOP
// ("dwl" → wlr-portals.conf → backend wlr), et portal-wlr se connecte au
// compositeur via WAYLAND_DISPLAY (cyberrealm-0).
//
// IMPORTANT : tout doit tourner sur un bus D-Bus SESSION privé. La session de
// login (host KDE) partage le bus utilisateur /run/user/$UID/bus : le daemon
// xdg-desktop-portal du host y possède déjà le nom org.freedesktop.portal.Desktop
// et route ScreenCast vers le backend kde (inutilisable sans kwin) — le
// nôtre quitterait aussitôt. On démarre donc d'abord un dbus-daemon privé.
// Écrit la config de xdg-desktop-portal-wlr dans $XDG_RUNTIME_DIR et renvoie
// son chemin. Sans chooser_type=none, le backend lance un chooser interactif
// (slurp, puis wmenu/wofi/rofi/bemenu...) pour choisir la source à partager :
// dans le compositeur du jeu ça échoue aussitôt (slurp exige un pointeur et
// une interaction ; les dmenu ne sont pas installés) → OBS reçoit
// "Failed to select source, denied or cancelled by user". Avec
// chooser_type=none, portal-wlr demande la cible au jeu via le sélecteur
// (fichiers cyberrealm-capture-pending / cyberrealm-capture-choice), et en
// dernier recours sélectionne le premier output (l'output headless 1920x1080
// présenté par present_viewport_frame).
String WlrCompositor::write_portal_config() const {
    const char *rt = getenv("XDG_RUNTIME_DIR");
    if (!rt || !rt[0]) {
        return String();
    }
    std::string path = std::string(rt) + "/cyberrealm-portal-wlr.conf";
    FILE *f = fopen(path.c_str(), "w");
    if (!f) {
        UtilityFunctions::printerr("waylandgodot: impossible d'écrire la config portal-wlr ",
            path.c_str());
        return String();
    }
    fprintf(f, "[screencast]\nchooser_type=none\n");
    fclose(f);
    return String(path.c_str());
}

void WlrCompositor::launch_portals() {
    start_private_dbus();
    // Les binaires portal sont dans /usr/lib/ (pas dans $PATH sur Arch) :
    // il faut les chemins absolus pour que sh -c les trouve.
    String portal_config = write_portal_config();
    launch_app("/usr/lib/xdg-desktop-portal");
    // xdg-desktop-portal-wlr local, patché pour la capture fenêtre (le chooser
    // "none" écrit $XDG_RUNTIME_DIR/cyberrealm-capture-pending quand une source
    // OBS est ajoutée ; le jeu ouvre alors le sélecteur et répond via
    // cyberrealm-capture-choice). Compilé depuis compositors/portal-wlr
    // (source xdg-desktop-portal-wlr 0.8.2 + patch).
    // -l INFO (MAJUSCULES, niveaux de logger.c) : sans quoi le niveau par
    // défaut (ERROR) supprime le log "window capture target" utile pour
    // vérifier quelle fenêtre est capturée. Un niveau inconnu fait exit(1).
    if (!portal_config.is_empty()) {
        launch_app("/home/adrien/Projets/CyberRealm/build/portal/libexec/xdg-desktop-portal-wlr -c " + portal_config + " -l INFO");
    } else {
        launch_app("/home/adrien/Projets/CyberRealm/build/portal/libexec/xdg-desktop-portal-wlr -l INFO");
    }
}

// Démarre un dbus-daemon de session privé (socket neuf dans /tmp) et bascule
// DBUS_SESSION_BUS_ADDRESS dessus. L'adresse est lue sur le pipe créé avant
// fork ; le daemon tourne en avant-plan (--nofork) comme enfant du jeu, il
// sera terminé dans le destructeur.
void WlrCompositor::start_private_dbus() {
    if (dbus_daemon_pid > 0) return;

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        UtilityFunctions::printerr("waylandgodot: pipe() a échoué pour le bus D-Bus privé");
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execl("/usr/bin/dbus-daemon", "dbus-daemon", "--session",
            "--nofork", "--nopidfile", "--print-address=1", (char *)nullptr);
        _exit(127);
    } else if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour le bus D-Bus privé");
        return;
    }

    close(pipefd[1]);
    char buf[2048] = {0};
    ssize_t n = read(pipefd[0], buf, sizeof(buf) - 1);
    close(pipefd[0]);

    if (n > 0) {
        char *nl = strchr(buf, '\n');
        if (nl) *nl = '\0';
        if (buf[0] != '\0') {
            setenv("DBUS_SESSION_BUS_ADDRESS", buf, 1);
            dbus_daemon_pid = pid;

            // Écrire l'adresse du bus dans un fichier pour que
            // cyberrealm-launch (compositors/kwin/cyberrealm-launch) la
            // propage aux apps lancées depuis Plasma.
            // Sans ça, les apps héritent du bus D-Bus système (KDE) et
            // ne trouvent pas les portails CyberRealm → OBS ne voit pas
            // les sources screencast.
            const char *rt = getenv("XDG_RUNTIME_DIR");
            if (rt) {
                std::string path = std::string(rt) + "/cyberrealm-session-bus";
                FILE *f = fopen(path.c_str(), "w");
                if (f) {
                    fprintf(f, "%s\n", buf);
                    fclose(f);
                }
            }

            return;
        }
    }
    // Échec de lecture (le daemon n'a pas imprimé d'adresse) : on le tue.
    kill(pid, SIGTERM);
    waitpid(pid, nullptr, WNOHANG);
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

void WlrCompositor::set_x11_display(const String &display_name) {
    setenv("DISPLAY", display_name.utf8().get_data(), 1);
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
    wlr_box geo = ws->toplevel->base->current.geometry;
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

void WlrCompositor::set_output_size(int width, int height) {
    if (width < 1 || height < 1) return;
    if (width == output_width && height == output_height) return;
    output_width = width;
    output_height = height;
    arrange_layer_surfaces();

    // Le lockscreen doit toujours couvrir toute la surface de l'output :
    // on le reconfigure à la nouvelle taille (le client recommittera).
    if (session_lock.lock) {
        for (auto &pair : session_lock.surfaces) {
            wlr_session_lock_surface_v1_configure(pair.second.lock_surface,
                width, height);
        }
    }
}

// =====================================================================
// present_viewport_frame — présente la vue 3D du jeu sur l'output headless
// =====================================================================
// C'est le buffer affiché par l'output virtuel : wlr-screencopy et la source
// ext_image_capture "output" (capture écran de portal-wlr/OBS) le copient à
// chaque commit. Le script Godot appelle cette méthode chaque frame avec
// l'image du viewport racine (ce que le joueur voit réellement).
// =====================================================================

// --- Buffer shm minimaliste pour l'output headless --------------------
// wlroots n'expose pas wlr_shm_allocator_create (header privé), et les
// buffers GBM (wlr_allocator_create_buffer) ne supportent PAS
// begin_data_ptr_access (impl = get_dmabuf uniquement) : present_viewport_
// frame ne pouvait donc pas écrire ses pixels et l'output n'était JAMAIS
// committé → grim/OBS attendaient indéfiniment. On fournit donc notre
// propre buffer shm (memfd + mmap) conforme à wlr_buffer_impl.
// ---------------------------------------------------------------------
struct PresentShmBuffer {
    struct wlr_buffer base;
    int fd;
    size_t size;
    uint32_t format;
    size_t stride;
    void *data;
};

static void present_shm_buffer_destroy(struct wlr_buffer *wlr_buffer) {
    struct PresentShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);
    wlr_buffer_finish(wlr_buffer);
    munmap(buffer->data, buffer->size);
    close(buffer->fd);
    free(buffer);
}

static bool present_shm_buffer_get_shm(struct wlr_buffer *wlr_buffer,
        struct wlr_shm_attributes *attribs) {
    struct PresentShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);
    *attribs = {};
    attribs->fd = buffer->fd;
    attribs->format = buffer->format;
    attribs->width = buffer->base.width;
    attribs->height = buffer->base.height;
    attribs->stride = (int)buffer->stride;
    attribs->offset = 0;
    return true;
}

static bool present_shm_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buffer,
        uint32_t flags, void **data, uint32_t *format, size_t *stride) {
    struct PresentShmBuffer *buffer = wl_container_of(wlr_buffer, buffer, base);
    *data = buffer->data;
    *format = buffer->format;
    *stride = buffer->stride;
    return true;
}

static void present_shm_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buffer) {}

static const struct wlr_buffer_impl present_shm_buffer_impl = {
    .destroy = present_shm_buffer_destroy,
    .get_shm = present_shm_buffer_get_shm,
    .begin_data_ptr_access = present_shm_buffer_begin_data_ptr_access,
    .end_data_ptr_access = present_shm_buffer_end_data_ptr_access,
};

static int present_shm_alloc_fd(size_t size) {
    static int counter = 0;
    char name[64];
    snprintf(name, sizeof(name), "/cyberrealm-present-%d-%d",
        (int)getpid(), counter++);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return -1;
    shm_unlink(name);
    if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static struct wlr_buffer *present_shm_buffer_create(int width, int height, uint32_t format) {
    size_t stride = ((size_t)width * 4 + 31) & ~(size_t)31;
    size_t size = stride * (size_t)height;
    int fd = present_shm_alloc_fd(size);
    if (fd < 0) return nullptr;
    void *data = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        close(fd);
        return nullptr;
    }
    struct PresentShmBuffer *buffer =
        (struct PresentShmBuffer *)calloc(1, sizeof(*buffer));
    if (!buffer) {
        munmap(data, size);
        close(fd);
        return nullptr;
    }
    wlr_buffer_init(&buffer->base, &present_shm_buffer_impl, width, height);
    buffer->fd = fd;
    buffer->size = size;
    buffer->format = format;
    buffer->stride = stride;
    buffer->data = data;
    return &buffer->base;
}

bool WlrCompositor::has_active_capture() const {
    // attach_render_locks > 0 ⟺ au moins un consommateur capture l'output :
    // la session ext_image_copy_capture (portal-wlr) pose le verrou via
    // wlr_output_lock_attach_render pour toute sa durée, et screencopy /
    // export_dmabuf tant qu'une frame est en vol. Contrairement à
    // needs_frame, ce signal ne dépend pas d'un damage déjà présent, donc
    // pas de dépendance circulaire avec notre propre présent.
    return headless_output && headless_output->attach_render_locks > 0;
}

void WlrCompositor::present_viewport_frame(const PackedByteArray &rgba, int width, int height) {
    if (!renderer || !allocator || !headless_output) return;
    if (width <= 0 || height <= 0) return;
    if (rgba.size() < (int64_t)width * height * 4) {
        wlr_log(WLR_ERROR, "waylandgodot: present: rgba.size=%lld < %dx%d*4 "
            "(image non-RGBA8 ?)",
            (long long)rgba.size(), width, height);
        return;
    }

    // (Re)crée le buffer présenté si le format/taille change. Buffer shm
    // (memfd) : seul ce type supporte begin_data_ptr_access pour écrire les
    // pixels en CPU. Le commit d'un buffer shm est copié via le renderer
    // (wlr_texture_from_buffer) par wlr-screencopy et la source output —
    // même chemin que les surfaces fenêtres shm déjà affichées.
    if (!present_buffer || present_width != width || present_height != height) {
        if (present_buffer) {
            wlr_buffer_drop(present_buffer);
            present_buffer = nullptr;
        }
        const wlr_drm_format_set *formats =
            wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DATA_PTR);
        const wlr_drm_format *fmt = formats
            ? wlr_drm_format_set_get(formats, DRM_FORMAT_ARGB8888)
            : nullptr;
        if (!fmt) {
            UtilityFunctions::printerr("waylandgodot: present: ARGB8888 non supporté en DATA_PTR");
            return;
        }
        present_buffer = present_shm_buffer_create(width, height, fmt->format);
        if (!present_buffer) {
            UtilityFunctions::printerr("waylandgodot: present: échec allocation buffer");
            wlr_log(WLR_ERROR, "waylandgodot: present: échec allocation buffer");
            return;
        }
        wlr_log(WLR_DEBUG, "waylandgodot: present: buffer shm %dx%d créé",
            width, height);
        present_width = width;
        present_height = height;
    }

    // Upload RGBA8 (Godot) → ARGB8888 en mémoire (BGRA little-endian).
    void *data = nullptr;
    uint32_t format = 0;
    size_t stride = 0;
    if (!wlr_buffer_begin_data_ptr_access(present_buffer,
            WLR_BUFFER_DATA_PTR_ACCESS_WRITE, &data, &format, &stride)) {
        wlr_log(WLR_ERROR, "waylandgodot: present: begin_data_ptr_access a échoué "
            "(buffer non-shm ?)");
        return;
    }
    const uint8_t *src = rgba.ptr();
    uint8_t *dst = static_cast<uint8_t *>(data);
    for (int y = 0; y < height; y++) {
        const uint8_t *srow = src + (size_t)y * width * 4;
        uint8_t *drow = dst + (size_t)y * stride;
        for (int x = 0; x < width; x++) {
            drow[x * 4 + 0] = srow[x * 4 + 2]; // B <- R
            drow[x * 4 + 1] = srow[x * 4 + 1]; // G
            drow[x * 4 + 2] = srow[x * 4 + 0]; // R <- B
            drow[x * 4 + 3] = 0xFF;            // A
        }
    }
    wlr_buffer_end_data_ptr_access(present_buffer);

    // Dessiner le curseur xcursor dans le buffer présenté pour qu'il
    // apparaisse dans la capture screencopy (OBS). Le cursor_manager a
    // chargé le thème xcursor ; on récupère l'image "default" et on la
    // composit dans le buffer ARGB8888 à la position (cursor_x, cursor_y).
    // Masqué en mode caméra (Input.mouse_mode = MOUSE_MODE_CAPTURED) via
    // set_cursor_visible(false) : le curseur ne doit pas apparaître dans la
    // capture OBS pendant le focus caméra.
    if (cursor_manager && cursor && cursor_visible) {
        struct wlr_xcursor *xcursor = wlr_xcursor_manager_get_xcursor(
            cursor_manager, "default", 1.0f);
        if (xcursor && xcursor->image_count > 0) {
            int frame = wlr_xcursor_frame(xcursor, 0);
            if (frame >= 0 && frame < (int)xcursor->image_count) {
                struct wlr_xcursor_image *img = xcursor->images[frame];
                if (img && img->buffer) {
                    // Re-mapper le buffer pour dessiner le cursor
                    void *buf_data = nullptr;
                    uint32_t buf_format = 0;
                    size_t buf_stride = 0;
                    if (wlr_buffer_begin_data_ptr_access(present_buffer,
                            WLR_BUFFER_DATA_PTR_ACCESS_WRITE,
                            &buf_data, &buf_format, &buf_stride)) {
                        int cx = (int)cursor_x - (int)img->hotspot_x;
                        int cy = (int)cursor_y - (int)img->hotspot_y;
                        // Dessiner le cursor image (ARGB8888) avec alpha blend
                        uint8_t *dst_base = static_cast<uint8_t *>(buf_data);
                        const uint8_t *src_img = img->buffer;
                        for (uint32_t iy = 0; iy < img->height; iy++) {
                            int dy = cy + (int)iy;
                            if (dy < 0 || dy >= height) continue;
                            uint8_t *drow = dst_base + (size_t)dy * buf_stride;
                            const uint8_t *srow = src_img + (size_t)iy * img->width * 4;
                            for (uint32_t ix = 0; ix < img->width; ix++) {
                                int dx = cx + (int)ix;
                                if (dx < 0 || dx >= width) continue;
                                // src = ARGB8888 (little-endian: B,G,R,A)
                                uint8_t sa = srow[ix * 4 + 3];
                                if (sa == 0) continue;
                                uint8_t sr = srow[ix * 4 + 2];
                                uint8_t sg = srow[ix * 4 + 1];
                                uint8_t sb = srow[ix * 4 + 0];
                                uint8_t *dp = drow + dx * 4;
                                if (sa == 255) {
                                    dp[0] = sb;
                                    dp[1] = sg;
                                    dp[2] = sr;
                                    dp[3] = 0xFF;
                                } else {
                                    // Alpha blend
                                    float a = sa / 255.0f;
                                    dp[0] = (uint8_t)(sb * a + dp[0] * (1.0f - a));
                                    dp[1] = (uint8_t)(sg * a + dp[1] * (1.0f - a));
                                    dp[2] = (uint8_t)(sr * a + dp[2] * (1.0f - a));
                                    dp[3] = 0xFF;
                                }
                            }
                        }
                        wlr_buffer_end_data_ptr_access(present_buffer);
                    }
                }
            }
        }
    }

    wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);
    if (!headless_output->current_mode ||
            (int)headless_output->current_mode->width != width ||
            (int)headless_output->current_mode->height != height) {
        wlr_output_state_set_custom_mode(&state, width, height, 0);
    }
    wlr_output_state_set_buffer(&state, present_buffer);
    pixman_region32_t damage;
    pixman_region32_init_rect(&damage, 0, 0, width, height);
    wlr_output_state_set_damage(&state, &damage);
    pixman_region32_fini(&damage);
    if (!wlr_output_commit_state(headless_output, &state)) {
        UtilityFunctions::printerr("waylandgodot: present: échec commit output");
        wlr_log(WLR_ERROR, "waylandgodot: present: échec commit output");
    } else {
        wlr_log(WLR_DEBUG, "waylandgodot: present: commit %dx%d OK",
            width, height);
    }
    wlr_output_state_finish(&state);
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

// =====================================================================
// Fonction helper pour appliquer l'opacité uniquement dans la zone de contenu.
// =====================================================================
void WlrCompositor::apply_content_opacity(uint8_t *dst, int w, int h, const wlr_box &geo) {
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            bool in_content = (x >= geo.x && x < geo.x + geo.width &&
                              y >= geo.y && y < geo.y + geo.height);
            if (in_content) {
                dst[(y * w + x) * 4 + 3] = 255; // Force opaque dans la zone de contenu
            } else {
                dst[(y * w + x) * 4 + 3] = 0; // Transparent en dehors
            }
        }
    }
}


