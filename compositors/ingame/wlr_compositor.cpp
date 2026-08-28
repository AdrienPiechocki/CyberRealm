#include "wlr_compositor.h"
#include "wlr_layer_shell_helpers.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/os.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <algorithm>
#include <thread>
#include <cctype>
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
#include <sys/stat.h>
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
#include <wlr/types/wlr_output.h>
}

#include "ext-image-capture-source-v1-protocol.h"

using namespace godot;

// =====================================================================
// Capture de fenêtres pour xdg-desktop-portal-wlr
// (ext_foreign_toplevel_image_capture_source_manager_v1 — manager absent
// de wlroots 0.19.3, voir ext_foreign_toplevel_image_capture_source.c)
// =====================================================================













// ---------------------------------------------------------------------
// Table de correspondance Key (Godot, physical_keycode) -> evdev keycode
// ---------------------------------------------------------------------

// Numpad evdev codes when location == 3 but physical_keycode is a regular key

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
    ClassDB::bind_method(D_METHOD("set_window_keyboard_focus", "window_id"),
        &WlrCompositor::set_window_keyboard_focus);
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
    ClassDB::bind_method(D_METHOD("forward_pointer_pinch", "factor", "dx", "dy"),
        &WlrCompositor::forward_pointer_pinch);
    ClassDB::bind_method(D_METHOD("forward_pointer_pinch_end", "cancelled"),
        &WlrCompositor::forward_pointer_pinch_end);
    ClassDB::bind_method(D_METHOD("get_wayland_socket_name"), &WlrCompositor::get_wayland_socket_name);
    ClassDB::bind_method(D_METHOD("launch_app", "command"), &WlrCompositor::launch_app);
    ClassDB::bind_method(D_METHOD("shutdown_apps"), &WlrCompositor::shutdown_apps);
    ClassDB::bind_method(D_METHOD("set_window_size", "window_id", "width", "height"), &WlrCompositor::set_window_size);
    ClassDB::bind_method(D_METHOD("set_window_fullscreen", "window_id", "fullscreen"), &WlrCompositor::set_window_fullscreen);
    ClassDB::bind_method(D_METHOD("set_x11_display", "display_name"), &WlrCompositor::set_x11_display);
    ClassDB::bind_method(D_METHOD("get_window_geometry", "window_id"), &WlrCompositor::get_window_geometry);
    ClassDB::bind_method(D_METHOD("get_window_cpu_image", "window_id"), &WlrCompositor::get_window_cpu_image);
    ClassDB::bind_method(D_METHOD("set_cpu_capture_requested", "requested"), &WlrCompositor::set_cpu_capture_requested);
    ClassDB::bind_method(D_METHOD("start_audio_share"), &WlrCompositor::start_audio_share);
    ClassDB::bind_method(D_METHOD("stop_audio_share"), &WlrCompositor::stop_audio_share);
    ClassDB::bind_method(D_METHOD("poll_audio_packet"), &WlrCompositor::poll_audio_packet);
    ClassDB::bind_method(D_METHOD("audio_decode", "packet", "sender_id"), &WlrCompositor::audio_decode);
    ClassDB::bind_method(D_METHOD("video_share_start", "codec", "bitrate"), &WlrCompositor::video_share_start);
    ClassDB::bind_method(D_METHOD("video_share_stop"), &WlrCompositor::video_share_stop);
    ClassDB::bind_method(D_METHOD("video_share_active"), &WlrCompositor::video_share_active);
    ClassDB::bind_method(D_METHOD("video_share_hardware"), &WlrCompositor::video_share_hardware);
    ClassDB::bind_method(D_METHOD("video_share_codec"), &WlrCompositor::video_share_codec);
    ClassDB::bind_method(D_METHOD("set_video_share_windows", "wids"), &WlrCompositor::set_video_share_windows);
    ClassDB::bind_method(D_METHOD("video_share_poll"), &WlrCompositor::video_share_poll);
    ClassDB::bind_method(D_METHOD("video_share_request_keyframe", "window_id"), &WlrCompositor::video_share_request_keyframe);
    ClassDB::bind_method(D_METHOD("video_share_pending"), &WlrCompositor::video_share_pending);
    ClassDB::bind_method(D_METHOD("video_decoder_configure", "key", "codec", "width", "height"),
        &WlrCompositor::video_decoder_configure);
    ClassDB::bind_method(D_METHOD("video_decoder_feed", "key", "packet", "keyframe"),
        &WlrCompositor::video_decoder_feed);
    ClassDB::bind_method(D_METHOD("video_decoder_reset", "key"), &WlrCompositor::video_decoder_reset);
    ClassDB::bind_method(D_METHOD("video_decoder_clear_all"), &WlrCompositor::video_decoder_clear_all);
    ClassDB::bind_method(D_METHOD("is_window_pointer_locked", "window_id"), &WlrCompositor::is_window_pointer_locked);
    ClassDB::bind_method(D_METHOD("is_window_xwayland", "window_id"), &WlrCompositor::is_window_xwayland);
    ClassDB::bind_method(D_METHOD("get_window_pid", "window_id"), &WlrCompositor::get_window_pid);
    ClassDB::bind_method(D_METHOD("set_audio_share_pids", "pids"), &WlrCompositor::set_audio_share_pids);
    ClassDB::bind_method(D_METHOD("is_drag_active"), &WlrCompositor::is_drag_active);
    ClassDB::bind_method(D_METHOD("get_window_cursor", "window_id"), &WlrCompositor::get_window_cursor);
    ClassDB::bind_method(D_METHOD("get_window_pointer", "window_id"), &WlrCompositor::get_window_pointer);
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
    ClassDB::bind_method(D_METHOD("set_window_pointer", "window_id", "x", "y", "inside"), &WlrCompositor::set_window_pointer);


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
    ADD_SIGNAL(MethodInfo("file_drop_received",
        PropertyInfo(Variant::PACKED_STRING_ARRAY, "paths")));

    ClassDB::bind_method(D_METHOD("_finish_file_drop", "paths", "time_msec", "button"),
        &WlrCompositor::_finish_file_drop);

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
    alive_guard = std::make_shared<std::atomic_bool>(true);
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
    // Les threads lecteurs de drop vérifient ce garde avant de toucher au
    // cycle de messages Godot (call_deferred) : après destruction, silence.
    if (alive_guard) {
        alive_guard->store(false);
    }
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
    if (cursor_image_buffer) {
        wlr_buffer_drop(cursor_image_buffer);
        cursor_image_buffer = nullptr;
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
        if (!wl_list_empty(&request_set_cursor_listener.link))
            wl_list_remove(&request_set_cursor_listener.link);

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


// =====================================================================
// probe_dmabuf_vulkan_import — Valide le pipeline complet
// dmabuf → import Vulkan avant de l'activer.
// =====================================================================
// `check_dmabuf_linear_available()` ne fait que QUERY les formats annoncés
// par le renderer. Certains drivers annoncent le dmabuf mais échouent à
// l'utilisation réelle — typiquement les VMs sans accélération 3D
// (virtio-gpu sans virgl/venus) ou les pilotes logiciels (lavapipe) :
// gbm_bo_create échoue, et l'import dans le Vulkan de Godot renvoie
// VK_ERROR_INCOMPATIBLE_DRIVER. Sans sonde, le jeu démarre alors sur le
// pipeline GPU cassé et boucle sur ces erreurs, sans jamais afficher de
// fenêtre (les fallbacks dmabuf/mmap et data_ptr échouent aussi car le
// buffer reste un dmabuf GPU).
//
// La sonde alloue ici un petit buffer LINEAR ABGR8888 via l'allocateur et
// tente un vrai import Vulkan dessus. Si ça échoue, le renderer GPU est
// abandonné au profit du renderer Pixman (CPU, fallback).
// =====================================================================


// =====================================================================
// CaptureCache — libération du buffer/mapping mis en cache
// =====================================================================


// Arrondit une dimension au palier supérieur pour l'allocation du buffer
// offscreen. Évite de réallouer le buffer GPU/dmabuf à chaque frame
// pendant un resize continu (drag de bordure) - tant que la nouvelle
// taille tient dans le palier déjà alloué, on réutilise le buffer existant
// et on ne rend/copie que la sous-région w x h réellement utile.

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

// Intervalle minimum entre deux recaptures d'une fenêtre dirty. Une vidéo
// est dirty à CHAQUE frame : la recapturer à chaque frame coûte un render
// pass GL + une sync GPU bloquante + un import Vulkan par frame sur le
// thread principal → surcharge (lag du partage LAN, risque de déconnexion
// ENet). En mode partage vidéo inter-frame, la copie CPU est supprimée (le
// worker encode le DMA-BUF en mmap) : le coût par capture est un render pass
// + une sync (poll court) + un submit, tenable à 60/s pour un stream fluide.
//
// DEUX cadences : 60/s (16 667 µs) pour les fenêtres ACTUELLEMENT partagées
// en vidéo (le stream en a besoin pour être fluide), 30/s (33 333 µs) pour
// les autres fenêtres dirty — elles ne servent qu'à rafraîchir leurs quads
// 3D, 30/s est suffisant et moitié moins de render passes libère le GPU et
// la mémoire (des captures non partagées à 60/s saturaient le GPU : sws
// lents → encodeur à ~6 ips au lieu de 60). Ce sont des intervalles de TEMPS
// (pas un décompte de frames) : le taux reste ~60/s (resp. ~30/s) quel que
// soit le max_fps du jeu. Si une fenêtre est en backpressure (réseau/encodeur
// en retard), window_ready renvoie false et on saute la capture → la cadence
// réelle retombe sans accumuler de retard, jamais plus vite que la vidéo ne
// peut être livrée.
//
// Cadence adaptative : sur un iGPU, chaque capture (render pass EGL + poll
// DMA-BUF jusqu'à 25 ms) se met en file derrière le rendu du jeu. Quand
// plusieurs fenêtres se redessinent en continu (systemmonitor, vidéo,
// curseur de terminal), la somme sature le GPU et les FPS du jeu s'effondrent
// — chaque poll atteint alors son plafond de 25 ms (visible dans les logs
// [diag] vulkan capture wait_gpu=25.x). On mesure donc l'EMA du temps de
// frame principal et on allonge les intervalles par paliers : moins de
// captures → GPU libéré → le temps de frame redescend. Les fenêtres
// partagées en vidéo sont dégradées aussi, mais moins (le stream doit rester
// fluide) ; CYBERREALM_CAPTURE_UNTHROTTLED=1 force le niveau 0 pour comparer.
static constexpr double CAPTURE_PRESSURE_FRAME_MS = 25.0;   // < ~40 fps
static constexpr double CAPTURE_CRITICAL_FRAME_MS = 40.0;   // < ~25 fps
static constexpr uint64_t SLOW_INTERVALS_US[3] = {33'333, 100'000, 200'000}; // 30/10/5 par s
static constexpr uint64_t FAST_INTERVALS_US[3] = {16'667, 33'333, 50'000};   // 60/30/20 par s

// Budget anti-stall : au plus N captures de fenêtres NON partagées par frame
// passée dans _process. Chaque capture peut bloquer jusqu'à timeout ms dans
// le poll DMA-BUF ; sans budget, plusieurs fenêtres dues à la même frame
// s'additionnent (2 × 25 ms de stall = frame à 40 ms garantie). Les fenêtres
// au-delà du budget restent "due" (last_capture_us n'est pas mis à jour) et
// sont servies aux frames suivantes — leur quad garde l'ancienne texture,
// invisible à ces cadences. Les fenêtres partagées vidéo ne comptent pas :
// le stream doit rester fluide.
static constexpr int MAX_WINDOW_CAPTURES_PER_FRAME = 2;

// Timeout (en frames) sans update pour clôturer un geste pinch : Godot
// n'émet pas d'événement de fin de magnify, donc le compositeur envoie
// pinch_end si aucun update n'arrive pendant cette durée.
static constexpr int PINCH_END_TIMEOUT_MS = 250;

CaptureCache::~CaptureCache() {
    reset();
}

// =====================================================================
// capture_surface — dispatch: dmabuf d'abord, fallback CPU ensuite
// =====================================================================


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


// =====================================================================
// capture_surface_pixels — Fallback CPU (readback via DATA_PTR)
// =====================================================================


// =====================================================================
// Callbacks wlroots
// =====================================================================




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







// --- Capture fenêtre (ext_foreign_toplevel_image_capture_source_manager) --





// Recopie la sous-région w×h de l'offscreen (pad'dé à 64px) vers le buffer
// exact-size de la source, une fois par frame dans _process. C'est ce buffer
// que copy_frame présente à wlroots lors des captures de fenêtre.

// Pilote la source de curseur d'une capture de fenêtre (mode METADATA) :
// synchronise entered/position/hotspot et réarme le damage de la session
// curseur. Appelé chaque frame dans _process pour les sources qui ont une
// source de curseur initialisée (portal-wlr a demandé create_pointer_cursor_
// session). Position en coordonnées de la capture (géométrie de contenu) :
// les coordonnées surface du pointeur moins l'origine de la géométrie
// (offset des ombres CSD).



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


// --- XDG toplevel requests ------------------------------------------------
// Le protocole xdg-shell exige que le compositeur réponde à chaque
// demande (fullscreen, maximize, etc.) par un configure, même s'il
// ignore la demande. Ne pas le faire est une violation de protocole.





// --- Popups ------------------------------------------------------------












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

// Calcule la boîte (dans l'output, origine haut-gauche) d'une layer surface
// depuis son état courant et la zone utilisable. Miroir exact de
// wlr_scene_layer_surface_v1_configure de wlroots.










// =====================================================================
// ext-session-lock-v1 (lockscreen quickshell/dms)
// =====================================================================


// Renvoie la première surface de verrouillage mappée (il ne devrait y en
// avoir qu'une : le protocole autorise une surface par output, et ce
// compositeur n'a qu'un seul output virtuel).









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

    // Try GPU renderer first — enables DMA-BUF + Vulkan zero-copy. Le
    // pipeline est validé par une VRAIE sonde (buffer dmabuf + import
    // Vulkan) : certains environnements (VM sans accélération 3D,
    // virtio-gpu, lavapipe) annoncent le dmabuf mais échouent ensuite à
    // gbm_bo_create / vkAllocateMemory (VK_ERROR_INCOMPATIBLE_DRIVER) →
    // boucle d'erreurs et fenêtres noires. La sonde détecte ça dès le
    // démarrage et on bascule alors sur Pixman.
    if (!renderer) {
        renderer = wlr_renderer_autocreate(backend);
        if (renderer) {
            allocator = wlr_allocator_autocreate(backend, renderer);
            if (check_dmabuf_linear_available() && probe_dmabuf_vulkan_import()) {
                dmabuf_available = true;
                gpu_pipeline_active = true;
                UtilityFunctions::print("waylandgodot: renderer GPU (GLES2/GBM), "
                    "pipeline Vulkan zero-copy actif (DMA-BUF → VkImage → Texture2DRD)");
            } else {
                dmabuf_available = false;
                gpu_pipeline_active = false;
                UtilityFunctions::print("waylandgodot: renderer GPU créé mais pipeline "
                    "dmabuf/Vulkan inutilisable (sonde échouée), fallback Pixman");
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
            // La sonde a pu laisser vulkan_import initialisé (init OK mais
            // import échoué) : on remet tout à zéro avant de repartir en CPU.
            vulkan_import.cleanup();
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
        gpu_pipeline_active = false;
        UtilityFunctions::print("waylandgodot: utilisation du renderer Pixman (CPU, fallback)");
    }

    wlr_renderer_init_wl_display(renderer, display);

    // wl_shm : indispensable pour les clients qui rendent en CPU via des
    // buffers partagés (waybar/Cairo, et le fallback des toolkits quand le
    // dma-buf est indisponible). Sans ce global, waybar échoue avec
    // "Failed to acquire the required resources" (le global wl_shm n'est
    // jamais annoncé), et GTK/Qt en shm-fallback ne peuvent pas committer.
    // NOTE : wlr_renderer_init_wl_display() ci-dessus crée DÉJÀ wl_shm (et
    // zwp_linux_dmabuf_v1 si le renderer expose des formats DMABUF). Ne pas
    // rappeler wlr_renderer_init_wl_shm() / wlr_linux_dmabuf_v1_create_* ici :
    // un double global wl_shm fait segfault les clients Qt5 (QWaylandShm::
    // handle_format lors du roundtrip du registry), et le double dmabuf est
    // inutile.

    // --- Initialiser le pipeline Vulkan zero-copy si possible ---------
    //     Déjà fait par probe_dmabuf_vulkan_import() pendant la sélection
    //     du renderer : la sonde a validé l'import réel d'un dmabuf dans
    //     le RenderingDevice de Godot avant d'activer le pipeline.

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
    // NOTE : déjà créé par wlr_renderer_init_wl_display() (cf. plus haut).
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

    // zwp_pointer_gestures_v1 : les clients (Gwenview, Firefox, Qt/KDE…)
    // créent des objets de geste (pinch/swipe/hold) depuis le pointeur du
    // seat. Sans ce global, Qt annonce l'extension en version 0 : les
    // proxies restent NULL, et Gwenview appelle release() sur un proxy NULL
    // dans le destructeur de WaylandGestures → wl_proxy_get_version(NULL) →
    // segfault à chaque navigation d'image. Annoncer le protocole suffit à
    // désamorcer le crash ; les événements de geste (touchpad) restent à
    // implémenter via wlr_pointer_gestures_v1_send_*_*.
    pointer_gestures = wlr_pointer_gestures_v1_create(display);
    if (!pointer_gestures) {
        UtilityFunctions::printerr("waylandgodot: échec création global zwp_pointer_gestures_v1");
    }

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

    // Curseur custom des clients : wl_pointer.set_cursor → surface curseur
    // capturée par fenêtre pour que le mode focus adopte l'apparence du
    // curseur de l'application en focus.
    request_set_cursor_listener.notify = WlrCompositor::on_request_set_cursor;
    wl_signal_add(&seat->events.request_set_cursor, &request_set_cursor_listener);

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

    // Clôturer un geste pinch resté sans update depuis trop longtemps.
    if (pinch_active && pointer_gestures && seat &&
        (get_time_msec() - pinch_last_update_ms) > PINCH_END_TIMEOUT_MS) {
        wlr_pointer_gestures_v1_send_pinch_end(pointer_gestures, seat,
            get_time_msec(), false);
        pinch_active = false;
    }



    timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    // EMA du temps de frame principal → niveau de pression de capture.
    // Ce delta inclut le rendu Godot ET les captures de la frame précédente :
    // c'est exactement la charge qu'on veut réguler.
    {
        uint64_t now_us = (uint64_t)now.tv_sec * 1000000u + (uint64_t)(now.tv_nsec / 1000);
        if (capture_last_frame_us != 0) {
            double dt_ms = (double)(now_us - capture_last_frame_us) / 1000.0;
            // Ignore les deltas aberrants (pause, gdb, première frame après
            // un long gel) pour ne pas fausser l'EMA.
            if (dt_ms > 0.0 && dt_ms < 500.0) {
                capture_frame_ms_ema = capture_frame_ms_ema == 0.0
                    ? dt_ms : capture_frame_ms_ema * 0.9 + dt_ms * 0.1;
            }
        }
        capture_last_frame_us = now_us;
        if (OS::get_singleton()->get_environment("CYBERREALM_CAPTURE_UNTHROTTLED") == "1") {
            capture_pressure = 0;
        } else {
            // Hystérésis : montée d'un palier immédiate (protéger le FPS),
            // descente d'un palier seulement après ~2 s d'accalmie durable
            // (EMA sous le seuil bas) — sinon on oscille à chaque frame
            // entre dégrader et relâcher, ce qui fait varier la cadence
            // sans jamais stabiliser le GPU.
            static constexpr uint64_t CAPTURE_PRESSURE_GRACE_US = 2'000'000;
            int candidate = capture_frame_ms_ema >= CAPTURE_CRITICAL_FRAME_MS ? 2 :
                capture_frame_ms_ema >= CAPTURE_PRESSURE_FRAME_MS ? 1 : 0;
            if (candidate > capture_pressure) {
                capture_pressure = candidate;
                capture_below_since_us = 0;
            } else if (candidate < capture_pressure) {
                if (capture_frame_ms_ema < CAPTURE_PRESSURE_FRAME_MS) {
                    if (capture_below_since_us == 0) {
                        capture_below_since_us = now_us;
                    } else if (now_us - capture_below_since_us >= CAPTURE_PRESSURE_GRACE_US) {
                        capture_pressure--;
                        // Réarme pour le palier suivant (descente progressive).
                        capture_below_since_us = now_us;
                    }
                } else {
                    capture_below_since_us = 0;
                }
            } else {
                capture_below_since_us = 0;
            }
        }
        if (capture_pressure != capture_pressure_logged) {
            UtilityFunctions::print("waylandgodot: [capture] frame=", capture_frame_ms_ema,
                "ms -> pression ", capture_pressure, " (fenêtres non partagées: ",
                SLOW_INTERVALS_US[capture_pressure] / 1000, " ms, partagées: ",
                FAST_INTERVALS_US[capture_pressure] / 1000, " ms)");
            capture_pressure_logged = capture_pressure;
        }
    }

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
    int window_captures_this_frame = 0;
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (ws.toplevel && ws.toplevel->base && ws.toplevel->base->surface) {
            sync_window_subsurfaces(ws);
            // Limite de fréquence de recapture : une fenêtre dirty (vidéo)
            // n'est recapturée que toutes les WINDOW_CAPTURE_INTERVAL_US µs
            // (temporel, pas un compteur de frames — voir la constante).
            // Sans ça, la capture tournerait à chaque frame pendant une
            // vidéo → surcharge du thread principal → lag du partage LAN,
            // risque de déconnexion.
            uint64_t now_us = (uint64_t)now.tv_sec * 1000000u + (uint64_t)(now.tv_nsec / 1000);
            // Cadence par fenêtre, modulée par la pression GPU : 60/s pour
            // les fenêtres partagées vidéo (le stream doit rester fluide),
            // 30/s pour les autres dirty (rafraîchissement des quads 3D).
            // Sous pression, les deux cadences sont allongées par paliers
            // (voir SLOW_INTERVALS_US / FAST_INTERVALS_US).
            bool shared = video_share.is_shared(ws.id);
            uint64_t interval = shared ? FAST_INTERVALS_US[capture_pressure]
                                       : SLOW_INTERVALS_US[capture_pressure];
            bool due = ws.dirty &&
                (ws.last_capture_us == 0 || now_us - ws.last_capture_us >= interval);
            bool safety = !ws.dirty && (frame_counter % WINDOW_SAFETY_RECAPTURE_INTERVAL) == 0;
            if (due || safety) {
                // Budget anti-stall (voir MAX_WINDOW_CAPTURES_PER_FRAME) :
                // au-delà, la fenêtre reste due pour une frame suivante.
                if (!shared && window_captures_this_frame >= MAX_WINDOW_CAPTURES_PER_FRAME) {
                    continue;
                }
                ws.last_capture_us = now_us;
                // Partage vidéo inter-frame : le DMA-BUF de la fenêtre est
                // réutilisé à chaque capture (même mémoire GPU). Si l'encodeur
                // (thread worker) est encore en train de le lire, on ne le
                // re-rend PAS — un nouveau render pass écraserait les données
                // pendant l'encodage → corruption vidéo. On saute cette frame
                // (la texture locale garde le contenu précédent, un frame
                // sautée à ~60 fps est imperceptible).
                ws.capture_cache.wid = ws.id;
                if (video_share.is_active() && !video_share.window_ready(ws.id)) {
                    continue;
                }
                if (capture_surface(ws.toplevel->base->surface,
                        ws.texture, ws.width, ws.height, ws.capture_cache)) {
                    window_captures_this_frame++;
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
                // Émettre le frame event après chaque blit tant qu'une
                // session capture est active. wlroots ne rappelle
                // schedule_frame que si le damage de la session est non vide
                // — or wlr_ext_image_copy_capture_frame_v1_ready() le vide à
                // chaque frame — donc sans cette émission continue la capture
                // fenêtre restait figée après la première image (le capture
                // suivant ne déclenchait plus rien). La source output de
                // wlroots émet de même à chaque commit ; ici on émet à
                // chaque frame présentée, ce qui réarme le damage de la
                // session. Sans frame en vol copy_frame n'est pas appelé
                // (seule l'union de damage coûte) et le prochain capture de
                // la session est servi immédiatement.
                if (ws.width > 0 && ws.height > 0) {
                    pixman_region32_t damage;
                    pixman_region32_init_rect(&damage, 0, 0, ws.width, ws.height);
                    wlr_ext_image_capture_source_v1_frame_event event = { .damage = &damage };
                    wl_signal_emit_mutable(&src->base.events.frame, &event);
                    pixman_region32_fini(&damage);
                }
                src->needs_frame = false;
            }
        }
    }

    // Capture de fenêtres pour OBS (xdg-desktop-portal-wlr) : suivre les
    // contraintes (taille) de chaque source sur la géométrie courante de la
    // fenêtre. Les frame events, eux, sont émis dans la boucle de blit
    // ci-dessus.
    for (auto &pair : windows) {
        WindowState &ws = pair.second;
        if (!ws.image_source) continue;
        WlrCompositorToplevelSource *src = ws.image_source;
        if (ws.width > 0 && ws.height > 0 &&
                (ws.width != (int)src->base.width || ws.height != (int)src->base.height)) {
            update_toplevel_source_constraints(src);
        }
        // Source de curseur METADATA : synchroniser entered/position/
        // hotspot + frames avec l'état courant du pointeur du jeu.
        if (src->cursor.initialized) {
            update_toplevel_cursor(src);
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
    // Sous pression GPU, ralentir aussi le filet de sécurité des popups
    // (1 frame sur 2 → 1 sur 4/8) : chaque capture coûte un render pass +
    // une sync DMA-BUF, précisément ce qu'on cherche à économiser.
    uint64_t popup_modulo = capture_pressure >= 2 ? 8u : capture_pressure == 1 ? 4u : 2u;
    if ((frame_counter % popup_modulo) == 0) {
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
        // Filet de sécurité espacé sous pression GPU (les commits posent
        // dirty de toute façon, ce n'est qu'un rattrapage périodique).
        uint64_t layer_interval = (uint64_t)LAYER_SAFETY_RECAPTURE_INTERVAL * (capture_pressure + 1);
        if (!ls.dirty && (frame_counter % layer_interval) != 0) {
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




// Auto-guérison des boutons "perdus" : si on reçoit un appui alors que le
// bouton est déjà marqué enfoncé (un relâchement précédent s'est perdu, par
// ex. tombé dans le vide ou sur un popup sans gestion du clic droit),
// wlroots incrémenterait n_pressed et AVALERAIT le relâchement suivant : le
// client croirait le bouton enfoncé pour toujours (menu qui reste "coincé").
// On émet donc d'abord un relâchement synthétique vers la surface focusée
// (ce qui rétablit la cohérence côté client), puis le nouvel appui part
// normalement.

// Début du grab pointeur posé par un popup xdg (xdg_popup.grab) : GTK/
// Firefox vient de demander un popup menu et wlroots a instauré le grab.

// Fin du grab pointeur xdg-popup : wlroots a appelé xdg_popup_grab_end(),
// c'est-à-dire que popup_done a été envoyé à TOUS les popups du grab (GTK
// ferme alors le menu). C'est LE signal qui distingue une fermeture décidée
// par le compositeur (popup_done) d'une fermeture initiée par le client.














// Donne le focus clavier à une fenêtre (mode focus) : les touches forwardées
// par forward_keyboard_key partent vers la surface qui détient le focus
// clavier du seat, pas vers un window_id. Quand une nouvelle fenêtre devient
// active dans la pile, il faut donc lui rendre l'enter clavier.










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

// --- Drop de fichiers sur le monde 3D --------------------------------------
// Lit text/uri-list depuis la source du drag via un tube. La remontée du
// bouton relâché au grab wlroots est différée à la fin de la lecture : sans
// ce délai, la source (Dolphin, Nautilus…) peut recevoir l'annulation du
// drag avant d'avoir écrit les données demandées et abandonner le transfert.
// Timeout de sécurité si la source ne répond pas (sélection géante, app
// bloquée) : le drag se termine alors normalement, éventuellement sans
// données.
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

// Fil d'exécution principal : émission vers GDScript puis délivrance du
// relâchement différé au grab wlroots (qui annule le drag sans focus client,
// comme avant cette fonctionnalité).
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






// Le buffer d'une surface curseur est lu au signal client_commit, PAS à
// events.commit : surface_commit_state appelle surface_apply_damage AVANT
// d'émettre events.commit, et pour un ré-upload de même taille
// wlr_client_buffer_apply_damage → wlr_texture_update_from_buffer réussit
// (texture existante mise à jour) puis unlock + NULLe surface->current.buffer.
// Notre handler de commit verrait donc "no buffer" sur tous les ré-uploads de
// même taille. Au signal client_commit (émis avant surface_commit_state),
// surface_finalize_pending a déjà placé le buffer verrouillé dans
// surface->pending.buffer, que rien n'a encore consommé.



// Validation standard de wl_pointer.set_cursor : seul le client qui a le
// focus pointeur peut poser son curseur (sinon une fenêtre en arrière-plan
// pourrait écraser le curseur de la fenêtre active). wlroots n'impose pas
// cette règle lui-même : il livre l'événement tel quel.




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

// Lance `command` via /bin/sh dans le dossier `cwd` (fork + setsid), renvoie
// le pid de l'enfant ou -1 si fork échoue. launch_app() l'utilise avec $HOME ;
// launch_portals() avec le dossier du binaire du jeu pour résoudre ses chemins
// relatifs (portal-wlr dans build/portal) sans imposer ce CWD aux apps.
static pid_t fork_launch(const String &command, const String &cwd) {
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        if (!cwd.is_empty()) chdir(cwd.utf8().get_data());
        CharString cmd = command.utf8();
        execl("/bin/sh", "sh", "-c", cmd.get_data(), (char *)nullptr);
        _exit(127);
    }
    return pid;
}

void WlrCompositor::launch_app(const String &command) {
    const char *home = getenv("HOME");
    pid_t pid = fork_launch(command, home ? String(home) : String());
    if (pid > 0) {
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
    // il faut le chemin absolu pour que sh -c le trouve. Le portal-wlr local
    // est lancé via fork_launch avec pour cwd le dossier du binaire du jeu
    // (Game/build) : son chemin relatif ../../build/portal pointe vers
    // build/portal, où qu'ait été déplacé le projet, sans changer le CWD des
    // apps lancées par launch_app() ($HOME).
    const String bin_dir = OS::get_singleton()->get_executable_path().get_base_dir();
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
    String portal_cmd = "../../build/portal/libexec/xdg-desktop-portal-wlr";
    if (!portal_config.is_empty()) {
        portal_cmd += " -c " + portal_config;
    }
    portal_cmd += " -l INFO";
    pid_t pid = fork_launch(portal_cmd, bin_dir);
    if (pid > 0) {
        child_pids.push_back(pid);
    } else {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour launch_portals");
    }
    launch_secrets_daemon();
}

// Lance le secret service (org.freedesktop.secrets) dans le bus privé du jeu.
// Un gnome-keyring-daemon isolé est indispensable : activé via D-Bus, le
// daemon hôte de la session Plasma est détecté par --start via le socket de
// contrôle partagé ($XDG_RUNTIME_DIR/keyring/control → discover_other_daemon:
// 1) et sort sans prendre le nom → les apps attendent l'activation (timeout
// service_start_timeout 120s). Un --control-directory dédié (cyberrealm-keyring)
// évite cette détection. Sans --start, le daemon s'installe directement dans
// le bus privé (DBUS_SESSION_BUS_ADDRESS hérité). Il est enfant du jeu :
// terminé avec lui (child_pids). Désactivable via WAYLANDGODOT_SECRETS=0.
void WlrCompositor::launch_secrets_daemon() {
    const char *skip = getenv("WAYLANDGODOT_SECRETS");
    if (skip && strcmp(skip, "0") == 0) {
        return;
    }
    const char *daemon = "/usr/bin/gnome-keyring-daemon";
    if (access(daemon, X_OK) != 0) {
        UtilityFunctions::print("waylandgodot: gnome-keyring-daemon absent, org.freedesktop.secrets non servi");
        return;
    }
    const char *rt = getenv("XDG_RUNTIME_DIR");
    if (!rt || rt[0] == '\0') {
        return;
    }
    std::string dir = std::string(rt) + "/cyberrealm-keyring";
    mkdir(dir.c_str(), 0700);
    chmod(dir.c_str(), 0700);
    std::string cmd = std::string(daemon) + " --foreground --components=secrets --control-directory=" + dir;
    pid_t pid = fork_launch(String(cmd.c_str()), String());
    if (pid > 0) {
        child_pids.push_back(pid);
        UtilityFunctions::print("waylandgodot: lancé gnome-keyring-daemon (org.freedesktop.secrets, pid ", pid, ")");
    } else {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour gnome-keyring-daemon");
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



void WlrCompositor::set_x11_display(const String &display_name) {
    setenv("DISPLAY", display_name.utf8().get_data(), 1);
    // Résolveur du vrai PID des fenêtres X11 (audio LAN) : le serveur X du
    // satellite est démarré, on lance la résolution asynchrone.
    x11_resolver.set_display(display_name.utf8().get_data());
    x11_resolver.start();
}




// ---------------------------------------------------------------------
// Partage audio (stream LAN) : capture PipeWire + OPUS.
// ---------------------------------------------------------------------

bool WlrCompositor::start_audio_share() {
    return audio_share.start();
}

void WlrCompositor::stop_audio_share() {
    audio_share.stop();
}

Dictionary WlrCompositor::poll_audio_packet() {
    Dictionary result;
    PackedByteArray packet;
    if (!audio_share.poll_opus_packet(packet)) {
        return result;
    }
    result["data"] = packet;
    return result;
}

PackedByteArray WlrCompositor::audio_decode(const PackedByteArray &packet, int sender_id) {
    return audio_share.decode_opus_packet(packet, sender_id);
}

// ---------------------------------------------------------------------
// Partage vidéo (stream LAN) : encodeur inter-frame (VideoShare).
// ---------------------------------------------------------------------

bool WlrCompositor::video_share_start(const String &codec, int bitrate) {
    return video_share.start(codec, bitrate);
}

void WlrCompositor::video_share_stop() {
    video_share.stop();
}

bool WlrCompositor::video_share_active() {
    return video_share.is_active();
}

bool WlrCompositor::video_share_hardware() {
    return video_share.is_hardware();
}

String WlrCompositor::video_share_codec() {
    return video_share.active_codec();
}

void WlrCompositor::set_video_share_windows(const PackedInt32Array &wids) {
    std::vector<int> ids;
    for (int i = 0; i < wids.size(); i++) {
        ids.push_back(wids[i]);
    }
    video_share.set_encode_windows(ids);
}

Array WlrCompositor::video_share_poll() {
    return video_share.poll_packets();
}

void WlrCompositor::video_share_request_keyframe(int window_id) {
    video_share.request_keyframe(window_id);
}

int WlrCompositor::video_share_pending() {
    return video_share.pending_count();
}

void WlrCompositor::video_decoder_configure(const String &key, const String &codec, int width, int height) {
    std::string k = key.utf8().get_data();
    video_share.decoder_configure(k, codec, width, height);
}

Ref<Image> WlrCompositor::video_decoder_feed(const String &key, const PackedByteArray &packet, bool keyframe) {
    std::string k = key.utf8().get_data();
    return video_share.decoder_feed(k, packet, keyframe);
}

void WlrCompositor::video_decoder_reset(const String &key) {
    std::string k = key.utf8().get_data();
    video_share.decoder_reset(k);
}

void WlrCompositor::video_decoder_clear_all() {
    video_share.decoder_clear_all();
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

bool WlrCompositor::ensure_cursor_image_buffer() {
    struct wlr_xcursor *xcursor = cursor_manager
        ? wlr_xcursor_manager_get_xcursor(cursor_manager, "default", 1.0f)
        : nullptr;
    if (!xcursor || xcursor->image_count <= 0) {
        return false;
    }
    int frame = wlr_xcursor_frame(xcursor, 0);
    if (frame < 0 || frame >= (int)xcursor->image_count) {
        return false;
    }
    struct wlr_xcursor_image *img = xcursor->images[frame];
    if (!img || !img->buffer || img->width <= 0 || img->height <= 0) {
        return false;
    }

    cursor_image_hotspot_x = (int)img->hotspot_x;
    cursor_image_hotspot_y = (int)img->hotspot_y;

    // Recréer le buffer uniquement si la taille change (l'image xcursor ne
    // change pas à chaud) : les textures dérivées (output cursor, copies)
    // restent valides tant que le contenu ne bouge pas.
    if (!cursor_image_buffer ||
            cursor_image_width != (int)img->width ||
            cursor_image_height != (int)img->height) {
        if (cursor_image_buffer) {
            wlr_buffer_drop(cursor_image_buffer);
            cursor_image_buffer = nullptr;
        }
        cursor_image_buffer = present_shm_buffer_create(
            (int)img->width, (int)img->height, DRM_FORMAT_ARGB8888);
        if (!cursor_image_buffer) {
            cursor_image_width = 0;
            cursor_image_height = 0;
            return false;
        }
        cursor_image_width = (int)img->width;
        cursor_image_height = (int)img->height;

        // Recopie de l'image xcursor (ARGB8888 mémoire BGRA, pas de padding
        // de ligne) vers le buffer shm (stride aligné à 32).
        void *data = nullptr;
        uint32_t format = 0;
        size_t stride = 0;
        if (!wlr_buffer_begin_data_ptr_access(cursor_image_buffer,
                WLR_BUFFER_DATA_PTR_ACCESS_WRITE, &data, &format, &stride)) {
            return false;
        }
        const uint8_t *src = img->buffer;
        uint8_t *dst = static_cast<uint8_t *>(data);
        for (uint32_t y = 0; y < img->height; y++) {
            memcpy(dst + (size_t)y * stride, src + (size_t)y * img->width * 4,
                (size_t)img->width * 4);
        }
        wlr_buffer_end_data_ptr_access(cursor_image_buffer);
    }
    return true;
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
    //
    // Le curseur n'est composité que si au moins une session de capture
    // active l'a demandé (options PAINT_CURSORS). wlroots pose ce verrou
    // sur l'output via wlr_output_lock_software_cursors (source output
    // ext_image_capture, et wlr-screencopy avec overlay_cursor) ; sans ce
    // garde, le curseur reste baken dans le buffer même quand OBS décoche
    // "capturer le curseur" — la session recréée sans PAINT_CURSORS copie
    // pourtant ce buffer tel quel (wlr_ext_image_copy_capture_frame_v1_
    // copy_buffer copie le buffer committé, curseur compris).
    if (cursor_manager && cursor && cursor_visible &&
            headless_output && headless_output->software_cursor_locks > 0) {
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

    // Curseur de l'output headless pour le mode METADATA de la capture écran.
    // wlroots alimente la source de curseur ext_image_capture depuis
    // output->cursor_front_buffer, produit par le chemin "matériel"
    // (output_cursor_attempt_hardware) qui n'opère QUE si aucun verrou
    // logiciel n'est posé (software_cursor_locks == 0, i.e. aucune session
    // EMBEDDED active — dans ce cas c'est le bake ci-dessus qui fournit le
    // curseur à la capture). L'output cursor est piloté AVANT le commit ci-
    // dessous pour que l'événement de commit synchronise la position/image.
    // Masqué quand le jeu est en mode caméra (cursor_visible = false).
    if (headless_output) {
        if (!output_cursor) {
            output_cursor = wlr_output_cursor_create(headless_output);
        }
        if (output_cursor) {
            bool want_visible = cursor_visible && ensure_cursor_image_buffer();
            if (want_visible) {
                if (!output_cursor_buffer_set) {
                    wlr_output_cursor_set_buffer(output_cursor, cursor_image_buffer,
                        cursor_image_hotspot_x, cursor_image_hotspot_y);
                    output_cursor_buffer_set = true;
                }
                wlr_output_cursor_move(output_cursor, cursor_x, cursor_y);
            } else if (output_cursor_buffer_set) {
                wlr_output_cursor_set_buffer(output_cursor, nullptr, 0, 0);
                output_cursor_buffer_set = false;
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


