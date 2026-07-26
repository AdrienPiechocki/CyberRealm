#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
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
#include <wlr/interfaces/wlr_keyboard.h> // wlr_keyboard_init/wlr_keyboard_impl: API "implémenteur", pas dans types/
#include <wlr/types/wlr_input_device.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_primary_selection_v1.h>
}

namespace godot {

// Un toplevel XDG mappé = une "fenêtre" côté Godot.
// id: identifiant stable exposé côté GDScript (meta "window_id" sur le quad).
struct WindowState {
    int id = -1;
    wlr_xdg_toplevel *toplevel = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener new_popup_listener{}; // menus/dropdowns créés par ce toplevel

    Ref<ImageTexture> texture;
    int width = 0;
    int height = 0;

    class WlrCompositor *owner = nullptr; // pour retrouver l'instance depuis les callbacks C
};

// Un popup (menu burger, dropdown, tooltip...) - même cycle de vie qu'un
// toplevel (map/unmap/commit/destroy sur sa propre surface), mais rattaché
// à un parent et positionné en relatif à celui-ci plutôt que placé
// librement dans le monde 3D. Pas de sous-menus imbriqués dans cette
// version (on n'écoute pas events.new_popup sur les popups eux-mêmes).
struct PopupState {
    int id = -1;
    int parent_window_id = -1; // fenêtre racine, toujours renseigné
    int parent_popup_id = -1;  // popup parent immédiat si sous-menu, -1 sinon
    wlr_xdg_popup *popup = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener reposition_listener{};
    wl_listener new_popup_listener{}; // sous-menus créés depuis CE popup

    Ref<ImageTexture> texture;
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

    // Pas de wlr_input_device: le backend headless ne fournit pas
    // wlr_headless_add_input_device dans cette version de wlroots.
    // wlr_seat_pointer_notify_* opère directement sur le seat sans device.
    // Le clavier a besoin d'un wlr_keyboard pour porter la keymap - on en
    // construit un autonome, non rattaché à un backend (même principe que
    // l'implémentation interne de wlr_virtual_keyboard_v1).
    wlr_keyboard virtual_keyboard{};

    wl_listener new_toplevel_listener{};
    wl_listener keyboard_key_listener{};
    wl_listener keyboard_modifiers_listener{};

    static void on_keyboard_key(wl_listener *listener, void *data);
    static void on_keyboard_modifiers(wl_listener *listener, void *data);

    std::unordered_map<int, WindowState> windows;
    int next_window_id = 1;
    int active_toplevel_id = -1; // xdg_toplevel actuellement ACTIVATED (état visuel de focus)

    std::unordered_map<int, PopupState> popups;
    int next_popup_id = 1;

    static void on_new_toplevel(wl_listener *listener, void *data);
    static void on_toplevel_map(wl_listener *listener, void *data);
    static void on_toplevel_unmap(wl_listener *listener, void *data);
    static void on_toplevel_destroy(wl_listener *listener, void *data);
    static void on_surface_commit(wl_listener *listener, void *data);

    static void on_new_popup(wl_listener *listener, void *data);
    static void on_new_popup_from_popup(wl_listener *listener, void *data); // sous-menus
    static void on_popup_map(wl_listener *listener, void *data);
    static void on_popup_unmap(wl_listener *listener, void *data);
    static void on_popup_destroy(wl_listener *listener, void *data);
    static void on_popup_commit(wl_listener *listener, void *data);
    static void on_popup_reposition(wl_listener *listener, void *data);

    // Câblage commun des listeners d'un popup (utilisé qu'il descende d'un
    // toplevel ou d'un autre popup - même cycle de vie dans les deux cas).
    void wire_popup(PopupState &ps, wlr_xdg_popup *popup);

    // Pipeline texture->buffer offscreen->lecture CPU, partagé entre
    // fenêtres et popups. Retourne false sans rien modifier si aucune
    // texture n'est encore disponible pour ce commit.
    bool capture_surface_pixels(wlr_surface *surface, Ref<ImageTexture> &tex, int &out_w, int &out_h);

    WindowState *find_window(int id);
    PopupState *find_popup(int id);
    uint32_t get_time_msec();

    // Enter+motion+frame, commun aux fenêtres et aux popups.
    void notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y);
    
    // Permet de forcer la taille d'une fenêtre depuis Godot (lors d'un redimensionnement à la souris)
    void set_window_size(int window_id, int width, int height);


    void set_x11_display(const String &display_name);

protected:
    static void _bind_methods();

public:
    WlrCompositor();
    ~WlrCompositor() override;

    // Démarre un compositeur "headless" : aucune fenêtre créée chez l'hôte,
    // aucun scanout — Godot est la seule sortie visuelle. Les clients se
    // connectent via WAYLAND_DISPLAY (exporté automatiquement dans
    // l'environnement du process Godot après start_headless()).
    void start_headless();

    void _process(double delta) override;

    // --- Input, appelé depuis GDScript après un raycast ---
    void forward_pointer_motion(int window_id, double surface_x, double surface_y);
    void forward_pointer_motion_popup(int popup_id, double surface_x, double surface_y);
    void forward_pointer_button(int window_id, int button, bool pressed);
    void forward_pointer_button_popup(int popup_id, int button, bool pressed);
    void forward_pointer_axis(int window_id, double delta_x, double delta_y);
    void forward_pointer_leave();
    void forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed);

    // --- Utilitaires exposés à GDScript ---
    String get_wayland_socket_name() const;
    void launch_app(const String &command); // fork+exec avec WAYLAND_DISPLAY positionné
};

bool export_surface_dmabuf(
    wlr_surface *surface,
    wlr_dmabuf_attributes &attribs
);

} // namespace godot
