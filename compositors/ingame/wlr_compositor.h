#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <unordered_map>

#include <set>
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
#include <wlr/types/wlr_xdg_decoration_v1.h>
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
#include <wlr/types/wlr_session_lock_v1.h>
#include <wlr/types/wlr_ext_image_copy_capture_v1.h>
#include <wlr/types/wlr_ext_image_capture_source_v1.h>
#include <wlr/types/wlr_ext_foreign_toplevel_list_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_xcursor_manager.h>
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

// Suit les commits de chaque surface (sous-surfaces comprises) de l'arbre
// d'une fenêtre. Le signal commit de la surface RACINE est déjà capté par
// WindowState::commit_listener, mais les sous-surfaces (vidéo DMABUF,
// overlays Firefox…) commitent indépendamment : sans écoute, un contenu
// purement sous-surface resterait figé. Un tracker est attaché par
// sync_window_subsurfaces et se supprime lui-même quand sa surface meurt.
struct WindowState; // forward

struct SurfaceCommitTracker {
    wl_listener commit{};
    wl_listener destroy{};
    wlr_surface *surface = nullptr;
    WindowState *ws = nullptr;

    static void on_commit(wl_listener *listener, void *data);
    static void on_destroy(wl_listener *listener, void *data);
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
    wl_listener set_title_listener{};

    // Décoration xdg-decoration-v1 du toplevel (demandée par
    // xwayland-satellite et les clients natifs). Toujours confirmée en
    // SERVER_SIDE : le jeu dessine lui-même la barre de titre de chaque
    // fenêtre. Répondre CLIENT_SIDE à xwayland-satellite le ferait redessiner
    // ses barres et ajouter leur hauteur au max size → min > max → protocol
    // error → panic. Le mode ne peut être confirmé qu'après l'initialisation
    // de la surface (set_mode() appelle schedule_configure() qui assert
    // sinon), d'où le report au premier commit via decoration_mode_pending.
    wlr_xdg_toplevel_decoration_v1 *decoration = nullptr;
    wl_listener decoration_request_mode_listener{};
    wl_listener decoration_destroy_listener{};
    bool decoration_mode_pending = false;

    // Ref<Texture2D> au lieu de Ref<ImageTexture>: permet d'utiliser
    // différents types de texture selon le chemin de capture.
    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    // true = un commit (racine ou sous-surface) a changé le contenu depuis
    // la dernière capture. Posé par on_surface_commit et les trackers de
    // sous-surfaces, consommé par _process : une fenêtre n'est recapturée
    // QUE si son contenu a réellement changé, et jamais pour une surface
    // statique. Sans ça, TOUTES les fenêtres étaient re-rendues (render
    // pass GL + synchronisation DMA-BUF bloquante + import Vulkan) à
    // chaque frame, même celles qui n'affichent rien de nouveau : le coût
    // total grossissait linéairement avec le nombre de fenêtres ouvertes.
    bool dirty = true;

    // Trackers de commits attachés à chaque sous-surface de l'arbre (voir
    // SurfaceCommitTracker). Indexés par surface ; retirés par leur propre
    // handler de destroy ou par clear_sub_surface_trackers() à la
    // destruction de la fenêtre.
    std::unordered_map<wlr_surface*, SurfaceCommitTracker> sub_surface_trackers;
    void clear_sub_surface_trackers();

    // Buffer/mapping/tampon CPU réutilisés d'une frame à l'autre pour la
    // capture (voir CaptureCache).
    CaptureCache capture_cache;

    // Handle ext-foreign-toplevel-list-v1 annoncé à portal-wlr (titre de la
    // fenêtre pour la capture fenêtre). Créé au map, détruit au destroy.
    wlr_ext_foreign_toplevel_handle_v1 *foreign_handle = nullptr;

    // Source de capture fenêtre (ext-foreign-toplevel-image-capture-source-v1),
    // créée à la demande quand portal-wlr capture cette fenêtre. NULL tant que
    // personne ne la capture.
    struct WlrCompositorToplevelSource *image_source = nullptr;

    class WlrCompositor *owner = nullptr;
    bool decoration_server_side = false;
};

// Source de capture fenêtre pour ext_image_copy_capture : permet à portal-wlr
// de streamer le contenu d'une fenêtre individuelle dans OBS.
struct WlrCompositorToplevelSource {
    wlr_ext_image_capture_source_v1 base;
    class WlrCompositor *compositor = nullptr;
    WindowState *window = nullptr;
    size_t num_started = 0;
    bool needs_frame = false;
    // Buffer à la taille EXACTE de la fenêtre (w×h), recopié chaque frame
    // depuis capture_cache.offscreen (padded à 64px). wlr_ext_image_copy_
    // capture_frame_v1_copy_buffer exige src->width == dst->width, donc on
    // ne peut pas passer offscreen (padded) directement.
    wlr_buffer *capture_buffer = nullptr;
};

struct PopupState {
    int id = -1;
    int parent_window_id = -1;
    int parent_popup_id = -1;
    int parent_layer_id = -1; // popup attaché à une layer surface (>= 0), sinon -1
    wlr_xdg_popup *popup = nullptr;

    // true une fois que le signal popup_mapped a été émis pour ce popup.
    // Un popup dont la surface racine n'a jamais de buffer (sous-popups
    // Firefox, contenu WebRender dans des sous-surfaces) ne déclenche jamais
    // l'événement map de wlroots : le signal est alors émis depuis
    // on_popup_commit dès que l'arbre a du contenu.
    bool mapped_emitted = false;

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

    // true = le client a committé un nouveau buffer depuis la dernière
    // capture. Posé par on_layer_surface_commit, consommé par _process :
    // la capture n'a lieu QU'UNE FOIS par frame pour une surface qui
    // commit, et jamais pour une surface statique. Sans ça, une surface
    // animée (barre quickshell, notification, launcher) était capturée
    // DEUX fois par frame (une fois dans le commit handler, une fois dans
    // la boucle _process) et une surface statique était rendue/re-samplée
    // inutilement à chaque frame — le gros du coût étant le render pass
    // GPU + la synchronisation DMA-BUF bloquante (poll) + le signal.
    bool dirty = true;

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

// Une surface ext-session-lock-v1 (lockscreen quickshell/dms). Le
// lockscreen est rendu plein écran, au-dessus de toutes les layer surfaces
// et du contenu 3D : c'est le seul élément visible tant que le session est
// verrouillée.
struct SessionLockSurfaceState {
    int id = -1;
    wlr_session_lock_surface_v1 *lock_surface = nullptr;

    wl_listener map_listener{};
    wl_listener unmap_listener{};
    wl_listener destroy_listener{};
    wl_listener commit_listener{};

    Ref<Texture2D> texture;
    int width = 0;
    int height = 0;

    CaptureCache capture_cache;

    class WlrCompositor *owner = nullptr;
};

// État global d'un ext-session-lock-v1 actif. Un seul verrou à la fois
// (le protocole interdit qu'un client en demande un second pendant qu'un
// autre est actif).
struct SessionLockState {
    wlr_session_lock_v1 *lock = nullptr;
    bool locked_sent = false;

    wl_listener new_surface_listener{};
    wl_listener unlock_listener{};
    wl_listener destroy_listener{};

    std::unordered_map<int, SessionLockSurfaceState> surfaces;
    int next_surface_id = 1;
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
    // xdg-decoration-unstable-v1 : nécessaire pour que xwayland-satellite
    // délègue ses décorations au lieu de les dessiner lui-même. Sans ce
    // global il ajoute la hauteur de sa barre de titre au "max size" d'un
    // toplevel, ce qui produit un min > max pour les fenêtres sans taille
    // max (ICCCM max=0) → XDG_TOPLEVEL_ERROR_INVALID_SIZE → panic (crash de
    // xwayland-satellite avec github-desktop/Electron). On confirme toujours
    // SERVER_SIDE : le jeu dessine les barres de titre lui-même.
    wlr_xdg_decoration_manager_v1 *xdg_decoration_manager = nullptr;
    wlr_seat *seat = nullptr;
    wlr_pointer_constraints_v1 *pointer_constraints = nullptr;
    wlr_relative_pointer_manager_v1 *relative_pointer_manager = nullptr;
    wlr_layer_shell_v1 *layer_shell = nullptr;
    // Output layout: nécessaire pour zxdg_output_v1 (waybar 0.15 échoue avec
    // "Failed to acquire required resources." si le global est absent).
    wlr_output_layout *output_layout = nullptr;

    // Curseur Wayland (wlr_cursor + wlr_cursor_manager) : requis pour que
    // zwlr_screencopy_v1 et ext_image_capture supportent le cursor mode
    // embedded (mode 1). Sans wlr_cursor, xdg-desktop-portal-wlr rejette la
    // demande avec "Unavailable cursor mode 1" → OBS ne peut pas capturer.
    wlr_cursor *cursor = nullptr;
    struct wlr_xcursor_manager *cursor_manager = nullptr;
    double cursor_x = 0;
    double cursor_y = 0;
    bool cursor_visible = true;

    // --- Capture (xdg-desktop-portal-wlr) -------------------------------
    // ext_image_copy_capture_v1 : sessions/frames fournies par wlroots, avec
    // les sources "output" (capture écran = vue 3D du jeu) et les sources
    // "foreign toplevel" (capture fenêtre, implémentées ici).
    wlr_ext_image_copy_capture_manager_v1 *image_copy_capture_manager = nullptr;
    wlr_ext_output_image_capture_source_manager_v1 *output_image_capture_source_manager = nullptr;
    wl_global *foreign_toplevel_source_manager = nullptr; // ext_foreign_toplevel_image_capture_source_manager_v1 (custom)
    wlr_ext_foreign_toplevel_list_v1 *foreign_toplevel_list = nullptr;
    // Fallback zwlr_screencopy_v1 (ancien protocole) : en wlroots 0.19 il
    // capture aussi depuis les commits output, donc marche avec le buffer de
    // present_viewport_frame. Sert si un client n'utilise que ce protocole.
    wlr_screencopy_manager_v1 *screencopy_manager = nullptr;

    // Buffer présenté à l'output headless à chaque frame : contient la vue 3D
    // du jeu (readback du viewport Godot). C'est ce buffer que capturent
    // wlr-screencopy / ext_image_capture (source output).
    wlr_buffer *present_buffer = nullptr;
    int present_width = 0;
    int present_height = 0;

    // Cycle de vie des sources de capture fenêtre.
    void update_toplevel_source_constraints(WlrCompositorToplevelSource *source);
    void blit_toplevel_capture(WlrCompositorToplevelSource *source);
    void destroy_toplevel_image_source(WlrCompositorToplevelSource *source);

    wlr_keyboard virtual_keyboard{};

    // Codes evdev des touches dont on a forwardé l'appui vers wlr_keyboard
    // (uniquement via forward_keyboard_key). Garantit que chaque DOWN est
    // apparié à un UP pour l'état xkbcommon : les échos clavier et les
    // relâchements non appariés sont ignorés, sinon un modificateur peut
    // rester "coincé" tant qu'on ne recharge pas le keymap.
    std::set<uint32_t> pressed_keys;

    wl_listener new_toplevel_listener{};
    wl_listener new_toplevel_decoration_listener{};
    wl_listener new_layer_surface_listener{};
    wl_listener new_constraint_listener{};
    wl_listener request_start_drag_listener{};
    wl_listener start_drag_listener{};
    wl_listener drag_destroy_listener{};
    wl_listener request_set_selection_listener{};
    wl_listener request_set_primary_selection_listener{};
    wl_listener keyboard_key_listener{};
    wl_listener keyboard_modifiers_listener{};
    wl_listener pointer_grab_begin_listener{};
    wl_listener pointer_grab_end_listener{};

    static void on_keyboard_key(wl_listener *listener, void *data);
    static void on_keyboard_modifiers(wl_listener *listener, void *data);
    static void on_pointer_grab_begin(wl_listener *listener, void *data);
    static void on_pointer_grab_end(wl_listener *listener, void *data);

    std::unordered_map<int, WindowState> windows;
    int next_window_id = 1;
    int active_toplevel_id = -1;

    std::unordered_map<int, PopupState> popups;
    int next_popup_id = 1;

    // Layer surfaces (wlr-layer-shell): rendues côté Godot en overlays 2D.
    std::unordered_map<int, LayerSurfaceState> layer_surfaces;
    int next_layer_surface_id = 1;

    // Session lock (ext-session-lock-v1): manager + état du verrou actif.
    // Le lockscreen est rendu plein écran par-dessus tout le reste.
    wlr_session_lock_manager_v1 *session_lock_manager = nullptr;
    wl_listener new_session_lock_listener{};
    SessionLockState session_lock;

    bool session_lock_active() const;
    SessionLockSurfaceState *get_active_lock_surface();

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
    static void on_new_toplevel_decoration(wl_listener *listener, void *data);
    static void on_toplevel_decoration_request_mode(wl_listener *listener, void *data);
    static void on_toplevel_decoration_destroy(wl_listener *listener, void *data);
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

    static void on_new_session_lock(wl_listener *listener, void *data);
    static void on_session_lock_new_surface(wl_listener *listener, void *data);
    static void on_session_lock_surface_map(wl_listener *listener, void *data);
    static void on_session_lock_surface_unmap(wl_listener *listener, void *data);
    static void on_session_lock_surface_destroy(wl_listener *listener, void *data);
    static void on_session_lock_surface_commit(wl_listener *listener, void *data);
    static void on_session_lock_unlock(wl_listener *listener, void *data);
    static void on_session_lock_destroy(wl_listener *listener, void *data);

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
    static void on_toplevel_set_title(wl_listener *listener, void *data);
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

    // Émet popup_mapped (ou layer_popup_mapped) une seule fois pour un popup.
    // Peut être appelé depuis on_popup_map (surface racine avec buffer) ou
    // depuis on_popup_commit (racine sans buffer, contenu dans des
    // sous-surfaces).
    void emit_popup_mapped(PopupState &ps);

    // Donne le focus clavier à une surface (popup, fenêtre...). Les popups
    // menus de GTK/Firefox font xdg_popup.grab : tant que la surface du
    // popup n'a pas le focus clavier, le client ne considère pas le menu
    // comme actif (pas de highlight au survol, pas de sous-menu).
    void focus_surface(wlr_surface *surface);

    // Rend le focus clavier à la fenêtre active (ou à son popup encore
    // vivant) après la fermeture d'un popup.
    void restore_focus_after_popup(PopupState &ps);

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

    // Attache un SurfaceCommitTracker à chaque sous-surface de l'arbre de
    // la fenêtre qui n'en a pas encore (les trackers existants sont
    // conservés). À appeler une fois par frame pour rattraper les
    // sous-surfaces créées entre-temps ; un commit de n'importe quelle
    // surface marque alors la fenêtre dirty.
    void sync_window_subsurfaces(WindowState &ws);

    WindowState *find_window(int id);
    int find_window_id_by_surface(wlr_surface *surface);
    PopupState *find_popup(int id);
    uint32_t get_time_msec();

    void notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y);

    // Compile et applique le keymap xkb du clavier virtuel à partir de
    // keyboard_layout/keyboard_variant, puis ré-active NumLock et notifie
    // les modificateurs. Appelé à l'init de start_headless et à chaque
    // set_keyboard_layout.
    void reload_keymap();

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
    // "dwl:wlr" : le daemon xdg-desktop-portal split sur ':' et cherche
    // "<desktop>-portals.conf" pour chaque entrée. "dwl" seul ne matche
    // AUCUN fichier de config ni aucun UseIn des backends installés → pas de
    // backend ScreenCast pour OBS. Le suffixe ":wlr" fait charger
    // /usr/share/xdg-desktop-portal/wlr-portals.conf (default=wlr) → backend
    // xdg-desktop-portal-wlr. Overridable via WAYLANDGODOT_PORTAL_BACKEND.
    String portal_backend = "dwl:wlr";

    // --- Polkit agent ---------------------------------------------------
    String polkit_agent_path = "";
    pid_t polkit_agent_pid = -1;
    void launch_polkit_agent();



    // --- Child processes ------------------------------------------------
    std::vector<pid_t> child_pids;
    // Bus D-Bus privé de la session du jeu : les portails et les apps lancées
    // par le jeu s'y connectent, isolés du bus de la session de login (sinon
    // xdg-desktop-portal de la session hôte garde le nom et le backend wlr ne
    // sert jamais OBS).
    int dbus_daemon_pid = -1;

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
    void release_stale_button(uint32_t button);
    void forward_pointer_button(int window_id, int button, bool pressed);
    void forward_pointer_button_popup(int popup_id, int button, bool pressed);
    void forward_pointer_axis(int window_id, double delta_x, double delta_y);
    void forward_pointer_leave();
    void forward_pointer_relative_motion(int window_id, double dx, double dy, double dx_unaccel, double dy_unaccel);
    void forward_pointer_motion_layer(int layer_id, double surface_x, double surface_y);
    void forward_pointer_button_layer(int layer_id, int button, bool pressed);
    void forward_pointer_axis_layer(int layer_id, double delta_x, double delta_y);
    void forward_pointer_motion_lock(double surface_x, double surface_y);
    void forward_pointer_button_lock(int button, bool pressed);
    void forward_pointer_axis_lock(double delta_x, double delta_y);
    void forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed);
    void release_all_keys();

    // Layout clavier (xkbcommon) transmis aux clients Wayland : même format
    // que setxkbmap ("fr", "us", "de"... + variante "oss", "intl", ...).
    // Configure le keymap du clavier virtuel à chaud (apps déjà ouvertes
    // incluses). À appeler au démarrage avec la valeur sauvegardée.
    void set_keyboard_layout(const String &layout, const String &variant = "");
    String get_keyboard_layout() const;
    String get_keyboard_variant() const;
    String keyboard_layout = "fr";
    String keyboard_variant = "";

    String get_wayland_socket_name() const;
    void launch_app(const String &command);
    void shutdown_apps();
    void set_portal_backend(const String &backend);
    String get_portal_backend() const;

    // Positionne le curseur Wayland à des coordonnées absolues (output space).
    // Appelé par le script Godot pour synchroniser la position du curseur
    // avec le pointeur de la caméra 3D — nécessaire pour que le curseur
    // soit rendu dans la capture screencopy (OBS).
    void set_cursor_position(double x, double y);

    // Affiche/masque le curseur composé dans le buffer présenté (et donc dans
    // les captures écran). Masqué quand le jeu est en mode caméra
    // (Input.mouse_mode = MOUSE_MODE_CAPTURED) : le curseur ne doit pas
    // apparaître dans la capture OBS pendant le focus caméra.
    void set_cursor_visible(bool visible);

    void set_polkit_agent(const String &path);
    String get_polkit_agent() const;

    // Lance xdg-desktop-portal + xdg-desktop-portal-wlr dans la session du
    // jeu (backend wlr grâce à XDG_CURRENT_DESKTOP=dwl). À appeler une fois
    // le compositeur démarré (socket prêt).
    void launch_portals();
    // Démarre un dbus-daemon de session privé et bascule la variable
    // d'environnement DBUS_SESSION_BUS_ADDRESS dessus (héritée par les
    // enfants). Appelé automatiquement par launch_portals().
    void start_private_dbus();
    // Écrit la config de xdg-desktop-portal-wlr (chooser_type=none : capture
    // auto du premier output, sans slurp/dmenu interactif) et renvoie le
    // chemin — passé à portal-wlr via -c. Renvoie "" en cas d'échec.
    String write_portal_config() const;

    // Renvoie la géométrie de contenu (sans les ombres CSD) d'une fenêtre:
    // Dictionary { x, y, width, height } en pixels, relatifs à la surface.
    Dictionary get_window_geometry(int window_id);

    // Taille de l'output virtuel (viewport Godot) pour le layout des layer
    // surfaces. À appeler par le script dès qu'il connaît sa taille réelle
    // et à chaque changement de résolution.
    void set_output_size(int width, int height);

    // Présente une frame RGBA8 (PackedByteArray) sur l'output headless — la
    // "capture écran" de portal-wlr. Appelé par le script Godot avec l'image
    // du viewport (ce que le joueur voit).
    void present_viewport_frame(const PackedByteArray &rgba, int width, int height);

    // Vrai si un client capture réellement l'output headless
    // (xdg-desktop-portal-wlr via ext_image_copy_capture — verrou posé pour
    // toute la durée de la session — ou screencopy/export_dmabuf — verrou
    // posé tant qu'une frame est en vol). Basé sur
    // wlr_output->attach_render_locks > 0, pas sur needs_frame : ce dernier
    // n'est vrai qu'après un capture avec damage en attente et retomberait
    // sinon en dépendance circulaire (présenter ← needs_frame ← damage ←
    // commit ← présenter). Permet au script Godot de ne faire le coûteux
    // readback GPU→CPU du viewport que quand une capture est active.
    bool has_active_capture() const;

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

    // --- Capture fenêtre pour xdg-desktop-portal-wlr -------------------
    // Callbacks ext_foreign_toplevel_image_capture_source_manager_v1
    // (manager implémenté ici, absent de wlroots 0.19) et implémentation
    // wlr_ext_image_capture_source_v1 des sources fenêtre. Publiques car
    // référencées par des tables de pointeurs au namespace scope.
    static void on_foreign_toplevel_source_manager_bind(wl_client *client, void *data, uint32_t version, uint32_t id);
    static void on_foreign_toplevel_source_manager_create_source(wl_client *client, wl_resource *resource, uint32_t source, wl_resource *toplevel_handle);
    static void on_foreign_toplevel_source_manager_destroy(wl_client *client, wl_resource *resource);

    static void toplevel_source_start(wlr_ext_image_capture_source_v1 *base, bool with_cursors);
    static void toplevel_source_stop(wlr_ext_image_capture_source_v1 *base);
    static void toplevel_source_schedule_frame(wlr_ext_image_capture_source_v1 *base);
    static void toplevel_source_copy_frame(wlr_ext_image_capture_source_v1 *base,
        wlr_ext_image_copy_capture_frame_v1 *frame,
        wlr_ext_image_capture_source_v1_frame_event *event);
    static wlr_ext_image_capture_source_v1_cursor *toplevel_source_get_pointer_cursor(
        wlr_ext_image_capture_source_v1 *base, wlr_seat *seat);


};

} // namespace godot