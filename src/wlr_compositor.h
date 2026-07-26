#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <unordered_map>

extern "C" {
#include <wayland-server-core.h>
#include <xkbcommon/xkbcommon.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/pass.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_primary_selection_v1.h>
}

namespace godot {

// Un toplevel XDG mappé = une "fenêtre" côté Godot.
struct WindowState {
    int id = -1;
    wlr_xdg_toplevel *toplevel = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener new_popup_listener{};

    // Ref<Texture2D> au lieu de Ref<ImageTexture>: permet d'utiliser
    // différents types de texture selon le chemin de capture.
    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    class WlrCompositor *owner = nullptr;
};

struct PopupState {
    int id = -1;
    int parent_window_id = -1;
    int parent_popup_id = -1;
    wlr_xdg_popup *popup = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener reposition_listener{};
    wl_listener new_popup_listener{};

    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    class WlrCompositor *owner = nullptr;
};

class WlrCompositor : public Node {
    GDCLASS(WlrCompositor, Node)

    wl_display *display = nullptr;
    wl_event_loop *event_loop = nullptr;
    wlr_backend *backend = nullptr;
    wlr_renderer *renderer = nullptr;
    wlr_allocator *allocator = nullptr;
    wlr_compositor *compositor = nullptr;
    wlr_xdg_shell *xdg_shell = nullptr;
    wlr_seat *seat = nullptr;

    wlr_keyboard virtual_keyboard{};

    wl_listener new_toplevel_listener{};
    wl_listener keyboard_key_listener{};
    wl_listener keyboard_modifiers_listener{};

    static void on_keyboard_key(wl_listener *listener, void *data);
    static void on_keyboard_modifiers(wl_listener *listener, void *data);

    std::unordered_map<int, WindowState> windows;
    int next_window_id = 1;
    int active_toplevel_id = -1;

    std::unordered_map<int, PopupState> popups;
    int next_popup_id = 1;

    static void on_new_toplevel(wl_listener *listener, void *data);
    static void on_toplevel_map(wl_listener *listener, void *data);
    static void on_toplevel_unmap(wl_listener *listener, void *data);
    static void on_toplevel_destroy(wl_listener *listener, void *data);
    static void on_surface_commit(wl_listener *listener, void *data);

    static void on_new_popup(wl_listener *listener, void *data);
    static void on_new_popup_from_popup(wl_listener *listener, void *data);
    static void on_popup_map(wl_listener *listener, void *data);
    static void on_popup_unmap(wl_listener *listener, void *data);
    static void on_popup_destroy(wl_listener *listener, void *data);
    static void on_popup_commit(wl_listener *listener, void *data);
    static void on_popup_reposition(wl_listener *listener, void *data);

    void wire_popup(PopupState &ps, wlr_xdg_popup *popup);

    // Tente le chemin dmabuf (GPU render + mmap), puis retombe sur le
    // readback CPU (WLR_BUFFER_CAP_DATA_PTR). Retourne false si aucun
    // chemin n'a pu capturer la surface.
    bool capture_surface(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h);

    // Chemin dmabuf: rendu GPU (GLES2) vers buffer offscreen dmabuf,
    // puis mmap du fd pour accès direct à la mémoire. Évite le readback
    // GL par pixel et le swizzle si le format est ABGR8888 (RGBA mémoire).
    bool capture_surface_dmabuf(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h);

    // Fallback CPU: rendu offscreen + wlr_buffer_begin_data_ptr_access.
    // Nécessite un allocator qui supporte WLR_BUFFER_CAP_DATA_PTR
    // (Pixman ou GBM avec option shm).
    bool capture_surface_pixels(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h);

    WindowState *find_window(int id);
    PopupState *find_popup(int id);
    uint32_t get_time_msec();

    void notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y);

    void set_window_size(int window_id, int width, int height);

    void set_x11_display(const String &display_name);

    // Vérifie si le renderer supporte l'export dmabuf avec modifier linéaire
    // (requis pour mmap). Appelé une fois après l'init du renderer.
    bool check_dmabuf_linear_available();

    bool dmabuf_available = false;

protected:
    static void _bind_methods();

public:
    WlrCompositor();
    ~WlrCompositor() override;

    void start_headless();

    void _process(double delta) override;

    void forward_pointer_motion(int window_id, double surface_x, double surface_y);
    void forward_pointer_motion_popup(int popup_id, double surface_x, double surface_y);
    void forward_pointer_button(int window_id, int button, bool pressed);
    void forward_pointer_button_popup(int popup_id, int button, bool pressed);
    void forward_pointer_axis(int window_id, double delta_x, double delta_y);
    void forward_pointer_leave();
    void forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed);

    String get_wayland_socket_name() const;
    void launch_app(const String &command);
};

} // namespace godot
