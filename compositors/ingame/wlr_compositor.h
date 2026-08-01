#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <unordered_map>

#include <string>

#include "vulkan_dmauf.h"

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
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
// wlr_layer_shell_v1.h (et le header de protocole généré) sont du C qui
// utilise `namespace` comme nom de membre/paramètre, mot-clé C++. Le
// `#define` temporaire les rend parsables depuis du C++ (le champ n'est
// alors accessible que via le shim C wlr_layer_shell_helpers.c).
#define namespace wlr_namespace_field
#include <wlr/types/wlr_layer_shell_v1.h>
#undef namespace
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_xdg_output_v1.h>
}

namespace godot {

// Cache de capture par fenêtre/popup, réutilisé entre les frames pour
// éviter de recréer le buffer dmabuf, de le ré-exporter et de le re-mmaper
// à chaque frame - c'est là que se concentre le gros du coût du pipeline
// de capture CPU readback. Tant que la taille de la surface ne change pas,
// le buffer et son mapping mémoire persistent; seuls le render pass GPU
// (contenu qui change) et la copie CPU vers `bytes` se refont à chaque
// frame.
struct CaptureCache {
    enum class Backend { NONE, VULKAN, DMABUF, PIXELS };
    Backend backend = Backend::NONE;

    wlr_buffer *offscreen = nullptr;
    void *map_base = nullptr;
    size_t map_size = 0;
    uint8_t *data = nullptr; // pointeur mappé, offset delta déjà appliqué
    int dma_fd = -1;
    uint32_t stride = 0;
    uint32_t format = 0;
    int width = 0;
    int height = 0;
    // Taille RÉELLE allouée pour offscreen/map_base (>= width/height,
    // arrondie au palier CAPTURE_SIZE_STEP). Tant que width/height restent
    // sous cette capacité, on ne touche ni à l'allocateur GPU, ni à
    // l'export dmabuf, ni à mmap - seul le render pass + la copie CPU se
    // refont. Sans ça, un resize continu (drag de bordure) déclenche
    // alloc/export/mmap à chaque frame, ce qui est la cause principale des
    // chutes de FPS pendant un resize.
    int alloc_width = 0;
    int alloc_height = 0;
    PackedByteArray bytes; // tampon CPU réutilisé (évite un malloc/frame)

    // --- Vulkan zero-copy DMA-BUF import ------------------------------
    // Ces champs sont utilisés lorsque le pipeline GPU Vulkan est actif.
    // Le RID et la Texture2DRD remplacent le ImageTexture classique : pas
    // de mmap, pas de memcpy — la texture est directement un VkImage GPU.
    RID vulkan_rid;
    Ref<Texture2DRD> rd_texture;
    VkImage vk_image = VK_NULL_HANDLE;
    VkDeviceMemory vk_memory = VK_NULL_HANDLE;

    // Démappe et libère le buffer courant, remet le cache à zéro. Appelé
    // avant de recréer un buffer à une nouvelle taille, et depuis le
    // destructeur.  Si vulkan_rid est valide, elle est libérée via `rd`.
    void reset(RenderingDevice *rd = nullptr);
    ~CaptureCache();
};

// Un toplevel XDG mappé = une "fenêtre" côté Godot.
struct WindowState {
    int id = -1;
    wlr_xdg_toplevel *toplevel = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener new_popup_listener{};
    wl_listener request_fullscreen_listener{};
    wl_listener request_maximize_listener{};
    wl_listener request_minimize_listener{};
    wl_listener request_move_listener{};
    wl_listener request_resize_listener{};

    // Ref<Texture2D> au lieu de Ref<ImageTexture>: permet d'utiliser
    // différents types de texture selon le chemin de capture.
    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    // Buffer/mapping/tampon CPU réutilisés d'une frame à l'autre pour la
    // capture (voir CaptureCache).
    CaptureCache capture_cache;

    class WlrCompositor *owner = nullptr;
};

struct PopupState {
    int id = -1;
    int parent_window_id = -1;
    int parent_popup_id = -1;
    int parent_layer_id = -1; // popup attaché à une layer surface (>= 0), sinon -1
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

    // Buffer/mapping/tampon CPU réutilisés d'une frame à l'autre pour la
    // capture (voir CaptureCache).
    CaptureCache capture_cache;

    class WlrCompositor *owner = nullptr;
};

// Une surface wlr-layer-shell (waybar, rofi, notifications...). Dans ce
// compositeur 3D, les layer surfaces sont rendues côté Godot comme des
// overlays 2D ancrés à l'écran (le "output" = le viewport), avec la même
// sémantique que wlr-layer-shell: chaque surface est ancrée à un bord, a
// une taille, une marge, une exclusive zone et un niveau de couche
// (background/bottom/top/overlay).
struct LayerSurfaceState {
    int id = -1;
    wlr_layer_surface_v1 *layer_surface = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};
    wl_listener new_popup_listener{};

    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    // Position calculée par le layout (arrange_layer_surfaces), relative à
    // l'origine de l'output (0,0 = coin haut-gauche). Utilisée par le
    // script Godot pour positionner l'overlay, et pour le hit-testing.
    int x = 0;
    int y = 0;

    // Buffer/mapping/tampon CPU réutilisés d'une frame à l'autre pour la
    // capture (voir CaptureCache).
    CaptureCache capture_cache;

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
    wlr_pointer_constraints_v1 *pointer_constraints = nullptr;
    wlr_relative_pointer_manager_v1 *relative_pointer_manager = nullptr;
    wlr_layer_shell_v1 *layer_shell = nullptr;
    // Output layout: nécessaire pour zxdg_output_v1 (waybar 0.15 échoue avec
    // "Failed to acquire required resources." si le global est absent).
    wlr_output_layout *output_layout = nullptr;

    wlr_keyboard virtual_keyboard{};

    wl_listener new_toplevel_listener{};
    wl_listener new_layer_surface_listener{};
    wl_listener new_constraint_listener{};
    wl_listener request_start_drag_listener{};
    wl_listener start_drag_listener{};
    wl_listener drag_destroy_listener{};
    wl_listener request_set_selection_listener{};
    wl_listener request_set_primary_selection_listener{};
    wl_listener keyboard_key_listener{};
    wl_listener keyboard_modifiers_listener{};

    static void on_keyboard_key(wl_listener *listener, void *data);
    static void on_keyboard_modifiers(wl_listener *listener, void *data);

    std::unordered_map<int, WindowState> windows;
    int next_window_id = 1;
    int active_toplevel_id = -1;

    std::unordered_map<int, PopupState> popups;
    int next_popup_id = 1;

    // Layer surfaces (wlr-layer-shell): rendues côté Godot en overlays 2D.
    std::unordered_map<int, LayerSurfaceState> layer_surfaces;
    int next_layer_surface_id = 1;

    // "Output" virtuel utilisé pour le layout des layer surfaces. Par
    // défaut la résolution du fake output headless; le script Godot le
    // synchronise avec la taille réelle de son viewport via set_output_size.
    int output_width = 1920;
    int output_height = 1080;
    wlr_output *headless_output = nullptr;

    // Layer surface qui reçoit actuellement le focus clavier, -1 = aucune.
    int keyboard_focus_layer_id = -1;

    // Compteur de frames pour throttler la recapture "de sécurité" des
    // popups dans _process (voir commentaire dans _process).
    uint64_t frame_counter = 0;

    static void on_new_toplevel(wl_listener *listener, void *data);
    static void on_new_layer_surface(wl_listener *listener, void *data);
    static void on_layer_surface_map(wl_listener *listener, void *data);
    static void on_layer_surface_unmap(wl_listener *listener, void *data);
    static void on_layer_surface_destroy(wl_listener *listener, void *data);
    static void on_layer_surface_commit(wl_listener *listener, void *data);
    static void on_layer_new_popup(wl_listener *listener, void *data);
    static void on_new_constraint(wl_listener *listener, void *data);
    static void on_request_start_drag(wl_listener *listener, void *data);
    static void on_start_drag(wl_listener *listener, void *data);
    static void on_drag_destroy(wl_listener *listener, void *data);

    // Presse-papier (wl_data_device) + sélection primaire (Ctrl+V vs
    // clic molette). Un client demande à devenir la source du
    // presse-papier via ces requêtes ; il faut valider le serial et
    // accepter explicitement, sinon aucune donnée n'est jamais partagée
    // entre les fenêtres/clients.
    static void on_request_set_selection(wl_listener *listener, void *data);
    static void on_request_set_primary_selection(wl_listener *listener, void *data);
    static void on_toplevel_map(wl_listener *listener, void *data);
    static void on_toplevel_unmap(wl_listener *listener, void *data);
    static void on_toplevel_destroy(wl_listener *listener, void *data);
    static void on_surface_commit(wl_listener *listener, void *data);
    static void on_request_fullscreen(wl_listener *listener, void *data);
    static void on_request_maximize(wl_listener *listener, void *data);
    static void on_request_minimize(wl_listener *listener, void *data);
    static void on_request_move(wl_listener *listener, void *data);
    static void on_request_resize(wl_listener *listener, void *data);

    static void on_new_popup(wl_listener *listener, void *data);
    static void on_new_popup_from_popup(wl_listener *listener, void *data);
    static void on_popup_map(wl_listener *listener, void *data);
    static void on_popup_unmap(wl_listener *listener, void *data);
    static void on_popup_destroy(wl_listener *listener, void *data);
    static void on_popup_commit(wl_listener *listener, void *data);
    static void on_popup_reposition(wl_listener *listener, void *data);

    void wire_popup(PopupState &ps, wlr_xdg_popup *popup);

    // Recalcule la position/taille de chaque layer surface en fonction de
    // ses ancres, marges, exclusive zones et du niveau de couche, puis
    // envoie les configures. À appeler après chaque commit et quand la
    // taille de l'output change.
    void arrange_layer_surfaces();

    // Donne/reprend le focus clavier d'une layer surface keyboard-interactive.
    void focus_layer_surface(LayerSurfaceState &ls);
    void unfocus_layer_surface(LayerSurfaceState &ls);

    LayerSurfaceState *find_layer_surface(int id);

    // Tente le chemin dmabuf (GPU render + mmap), puis retombe sur le
    // readback CPU (WLR_BUFFER_CAP_DATA_PTR). Retourne false si aucun
    // chemin n'a pu capturer la surface. `cache` persiste entre les
    // appels (un par fenêtre/popup) pour éviter de recréer le buffer
    // offscreen et son mapping à chaque frame.
    bool capture_surface(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache);

    // Chemin Vulkan zero-copy: rendu GPU (EGL) vers buffer offscreen
    // dmabuf, puis import du fd dans le Vulkan de Godot via
    // VK_KHR_external_memory_fd → RID → Texture2DRD. Aucun mmap, aucun
    // memcpy CPU : la texture est directement un VkImage échantillonné
    // par le shader. Le buffer offscreen est conservé dans `cache` d'une
    // frame à l'autre ; seuls le render pass GPU et l'attente de
    // synchronisation se refont à chaque appel.
    bool capture_surface_vulkan(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache);

    // Chemin dmabuf: rendu GPU (GLES2) vers buffer offscreen dmabuf,
    // puis mmap du fd pour accès direct à la mémoire. Évite le readback
    // GL par pixel et le swizzle si le format est ABGR8888 (RGBA mémoire).
    // Le buffer et son mapping sont conservés dans `cache` d'une frame à
    // l'autre; seuls le render pass et la copie CPU se refont à chaque appel.
    bool capture_surface_dmabuf(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache);

    // Fallback CPU: rendu offscreen + wlr_buffer_begin_data_ptr_access.
    // Nécessite un allocator qui supporte WLR_BUFFER_CAP_DATA_PTR
    // (Pixman ou GBM avec option shm). Réutilise aussi `cache.offscreen`
    // et `cache.bytes` d'une frame à l'autre.
    bool capture_surface_pixels(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache);

    WindowState *find_window(int id);
    int find_window_id_by_surface(wlr_surface *surface);
    PopupState *find_popup(int id);
    uint32_t get_time_msec();

    void notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y);

    void set_window_size(int window_id, int width, int height);
    void set_window_fullscreen(int window_id, bool fullscreen);

    void set_x11_display(const String &display_name);

    // Vérifie si le renderer supporte l'export dmabuf avec modifier linéaire
    // (requis pour mmap). Appelé une fois après l'init du renderer.
    bool check_dmabuf_linear_available();

    bool dmabuf_available = false;

    // --- Vulkan zero-copy DMA-BUF pipeline ----------------------------
    VulkanDmaBufImport vulkan_import;
    bool gpu_pipeline_active = false;

    // --- Portal backend (XDG_CURRENT_DESKTOP) ---------------------------
    String portal_backend = "KDE";

    // --- Polkit agent ---------------------------------------------------
    String polkit_agent_path = "";
    pid_t polkit_agent_pid = -1;
    void launch_polkit_agent();



    // --- Child processes ------------------------------------------------
    std::vector<pid_t> child_pids;

    // --- Drag-and-drop icon -------------------------------------------
    wlr_drag *active_drag = nullptr;
    CaptureCache drag_icon_cache;
    Ref<Texture2D> drag_icon_texture;
    int drag_icon_width = 0;
    int drag_icon_height = 0;

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
    void forward_pointer_relative_motion(int window_id, double dx, double dy, double dx_unaccel, double dy_unaccel);
    void forward_pointer_motion_layer(int layer_id, double surface_x, double surface_y);
    void forward_pointer_button_layer(int layer_id, int button, bool pressed);
    void forward_pointer_axis_layer(int layer_id, double delta_x, double delta_y);
    void forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed);
    void release_all_keys();

    String get_wayland_socket_name() const;
    void launch_app(const String &command);
    void set_portal_backend(const String &backend);
    String get_portal_backend() const;

    void set_polkit_agent(const String &path);
    String get_polkit_agent() const;

    // Renvoie la géométrie de contenu (sans les ombres CSD) d'une fenêtre:
    // Dictionary { x, y, width, height } en pixels, relatifs à la surface.
    Dictionary get_window_geometry(int window_id);

    // Taille de l'output virtuel (viewport Godot) pour le layout des layer
    // surfaces. À appeler par le script dès qu'il connaît sa taille réelle
    // et à chaque changement de résolution.
    void set_output_size(int width, int height);

    // Infos complètes d'une layer surface pour le positionnement côté Godot:
    // Dictionary { namespace, layer, anchor, keyboard_interactive,
    // margin_top/right/bottom/left, x, y, width, height }.
    Dictionary get_layer_surface_info(int layer_id);

    // Id de la layer surface qui détient le focus clavier, -1 si aucune.
    int get_keyboard_focus_layer_id() const;

    // Demande la fermeture d'une layer surface (waybar/rofi...).
    void close_layer_surface(int layer_id);

    // Renvoie true si le popup a une région d'input non vide (menus,
    // dropdowns). Les tooltips ont une région d'input vide et ne doivent
    // pas intercepter les clics.
    bool popup_accepts_input(int popup_id);
    void apply_content_opacity(uint8_t *dst, int w, int h, const wlr_box &geo);
    bool is_drag_active() const;

    // Renvoie un Array de Dictionaries décrivant toutes les fenêtres ouvertes.
    // Chaque entrée contient: { "id": int, "title": String, "app_id": String }.
    Array get_window_list();

    // Envoie une requête de fermeture (xdg_toplevel.close) à la fenêtre.
    void close_window(int window_id);


};

} // namespace godot