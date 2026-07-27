#include "wlr_compositor.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <vector>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>

extern "C" {
#include <wlr/types/wlr_buffer.h>
#include <wlr/render/dmabuf.h>
#include <libdrm/drm_fourcc.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_xdg_shell.h>
}

using namespace godot;

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
    ClassDB::bind_method(D_METHOD("get_wayland_socket_name"), &WlrCompositor::get_wayland_socket_name);
    ClassDB::bind_method(D_METHOD("launch_app", "command"), &WlrCompositor::launch_app);
    ClassDB::bind_method(D_METHOD("set_window_size", "window_id", "width", "height"), &WlrCompositor::set_window_size);
    ClassDB::bind_method(D_METHOD("set_x11_display", "display_name"), &WlrCompositor::set_x11_display);
    ClassDB::bind_method(D_METHOD("get_window_geometry", "window_id"), &WlrCompositor::get_window_geometry);
    ClassDB::bind_method(D_METHOD("popup_accepts_input", "popup_id"), &WlrCompositor::popup_accepts_input);

    ADD_SIGNAL(MethodInfo("window_mapped",
        PropertyInfo(Variant::INT, "id"),
        PropertyInfo(Variant::STRING, "title"),
        PropertyInfo(Variant::STRING, "app_id")));
    ADD_SIGNAL(MethodInfo("window_unmapped", PropertyInfo(Variant::INT, "id")));
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
}

WlrCompositor::WlrCompositor() {}

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
    vulkan_import.flush_pending();
    vulkan_import.cleanup();

    if (display) {
        wl_display_destroy_clients(display);
        wl_display_destroy(display);
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

PopupState *WlrCompositor::find_popup(int id) {
    auto it = popups.find(id);
    return it == popups.end() ? nullptr : &it->second;
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

bool WlrCompositor::capture_surface_dmabuf(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    if (!renderer || !allocator) return false;

    wlr_texture *root_texture = wlr_surface_get_texture(surface);
    // Ne pas retourner false si root_texture est NULL : Firefox peut ne
    // committer aucun buffer sur la surface racine d'un popup, tout le
    // contenu vivant dans des sous-surfaces. wlr_surface_for_each_surface
    // ci-dessous itérera quand même sur les sous-surfaces.

    // Taille LOGIQUE de la surface (surface->current.width/height), pas la
    // taille brute du buffer (texture->width/height). Sur un client HiDPI
    // (buffer_scale > 1), le buffer physique est plus grand que la taille
    // affichée - mélanger les deux donne une image mal mise à l'échelle.
    int w = surface->current.width > 0 ? surface->current.width : (root_texture ? (int)root_texture->width : 0);
    int h = surface->current.height > 0 ? surface->current.height : (root_texture ? (int)root_texture->height : 0);
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
        opts.dst_box.x = inst.sx;
        opts.dst_box.y = inst.sy;
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

    // Synchronisation CPU/GPU: sans DMA_BUF_IOCTL_SYNC, on peut lire des
    // données incohérentes (cache GPU non flushé vers la RAM).
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

    // Récupérer la géométrie de la surface (zone de contenu réel)
    wlr_box geo = {0};
    wlr_xdg_surface *xdg_surface = wlr_xdg_surface_try_from_wlr_surface(surface);
    if (xdg_surface) {
        geo = xdg_surface->current.geometry;
    }

    timespec t_copy_start, t_copy_end, t_opacity_end;
    clock_gettime(CLOCK_MONOTONIC, &t_copy_start);
    if (cache.format == DRM_FORMAT_ABGR8888 ||
        cache.format == DRM_FORMAT_XBGR8888) {
        // RGBA en mémoire → copie directe par ligne (stride peut > w*4)
        for (int y = 0; y < h; y++) {
            memcpy(dst + (size_t)y * w * 4,
                cache.data + (size_t)y * cache.stride,
                (size_t)w * 4);
        }
        clock_gettime(CLOCK_MONOTONIC, &t_copy_end);
        // Appliquer l'opacité uniquement dans la zone de contenu
        apply_content_opacity(dst, w, h, geo);
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
        clock_gettime(CLOCK_MONOTONIC, &t_copy_end);
        // Appliquer l'opacité uniquement dans la zone de contenu
        apply_content_opacity(dst, w, h, geo);
    }
    clock_gettime(CLOCK_MONOTONIC, &t_opacity_end);

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
    double d_opacity = ms(t_copy_end, t_opacity_end);
    double d_sync2 = ms(t_sync2_start, t_sync2_end);
    double d_tex = ms(t_tex_start, t_tex_end);
    double d_total = d_render + d_sync1 + d_memcpy + d_opacity + d_sync2 + d_tex;
    if (d_total > 2.0) { // ne log que les captures qui coûtent réellement
        UtilityFunctions::print("waylandgodot: capture ", w, "x", h,
            " render=", d_render, "ms sync_start=", d_sync1,
            "ms memcpy=", d_memcpy, "ms opacity=", d_opacity,
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

    int w = surface->current.width > 0 ? surface->current.width : (root_texture ? (int)root_texture->width : 0);
    int h = surface->current.height > 0 ? surface->current.height : (root_texture ? (int)root_texture->height : 0);
    if (w <= 0 || h <= 0) return false;

    // ---- (Re)création du buffer offscreen + import Vulkan -------------
    // Réallouer si le backend ne correspond pas, ou si la taille a changé.
    if (!cache.offscreen || cache.backend != CaptureCache::Backend::VULKAN ||
        w != cache.alloc_width || h != cache.alloc_height) {
        // On crée les NOUVELLES ressources AVANT de libérer les anciennes
        // pour éviter un frame sans texture (causerait tearing/lacune visuelle).

        int alloc_w = w;
        int alloc_h = h;

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
        opts.dst_box.x = inst.sx;
        opts.dst_box.y = inst.sy;
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
    // DMA-BUF). Sans cette synchronisation, le render pass peut encore
    // écrire dans le buffer au moment où Godot le lit → tearing.
    if (cache.dma_fd >= 0) {
        struct dma_buf_sync sync = {};
        sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
        ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
        sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
        ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
    }

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

    wlr_render_texture_options opts = {};
    opts.texture = texture;
    opts.dst_box.x = 0;
    opts.dst_box.y = 0;
    opts.dst_box.width = w;
    opts.dst_box.height = h;
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

    // Récupérer la géométrie de la surface (zone de contenu réel)
    wlr_box geo = {0};
    wlr_xdg_surface *xdg_surface = wlr_xdg_surface_try_from_wlr_surface(surface);
    if (xdg_surface) {
        geo = xdg_surface->current.geometry;
    }

    timespec t_copy_start, t_copy_end, t_opacity_end;
    clock_gettime(CLOCK_MONOTONIC, &t_copy_start);
    // DRM_FORMAT_ARGB8888 = BGRA en mémoire (little-endian) → swizzle RGBA
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

    // Appliquer l'opacité uniquement dans la zone de contenu
    apply_content_opacity(dst, w, h, geo);
    clock_gettime(CLOCK_MONOTONIC, &t_opacity_end);

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
    double d_opacity = ms(t_copy_end, t_opacity_end);
    double d_tex = ms(t_tex_start, t_tex_end);
    double d_total = d_render + d_memcpy + d_opacity + d_tex;
    if (d_total > 2.0) {
        UtilityFunctions::print("waylandgodot: [CPU_READBACK] capture ", w, "x", h,
            " render=", d_render, "ms memcpy=", d_memcpy,
            "ms opacity=", d_opacity, "ms tex_upload=", d_tex,
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

    int id = self->next_window_id++;
    WindowState &ws = self->windows[id];
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

    UtilityFunctions::print("waylandgodot: new_toplevel reçu, id=", id,
        " app_id=", toplevel->app_id ? toplevel->app_id : "(pas encore fixé)");

    (void)id;
}

void WlrCompositor::on_toplevel_map(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, map_listener);
    WlrCompositor *self = ws->owner;

    String title = ws->toplevel->title ? String(ws->toplevel->title) : String("");
    String app_id = ws->toplevel->app_id ? String(ws->toplevel->app_id) : String("");
    self->emit_signal("window_mapped", ws->id, title, app_id);
}

void WlrCompositor::on_toplevel_unmap(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, unmap_listener);
    WlrCompositor *self = ws->owner;
    self->emit_signal("window_unmapped", ws->id);
}

void WlrCompositor::on_toplevel_destroy(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, destroy_listener);
    WlrCompositor *self = ws->owner;
    int id = ws->id;

    if (self->active_toplevel_id == id) {
        self->active_toplevel_id = -1;
    }

    wl_list_remove(&ws->map_listener.link);
    wl_list_remove(&ws->unmap_listener.link);
    wl_list_remove(&ws->destroy_listener.link);
    wl_list_remove(&ws->commit_listener.link);
    wl_list_remove(&ws->new_popup_listener.link);

    self->windows.erase(id);
}

void WlrCompositor::on_surface_commit(wl_listener *listener, void *data) {
    WindowState *ws = wl_container_of(listener, ws, commit_listener);
    WlrCompositor *self = ws->owner;

    if (ws->toplevel->base->initial_commit) {
        wlr_xdg_toplevel_set_size(ws->toplevel, 1280, 720);
        wlr_xdg_surface_schedule_configure(ws->toplevel->base);
        return;
    }

    if (!self->capture_surface(ws->toplevel->base->surface, ws->texture, ws->width, ws->height, ws->capture_cache)) {
        return;
    }
    self->emit_signal("window_texture_updated", ws->id, ws->texture, ws->width, ws->height);
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

void WlrCompositor::on_popup_map(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, map_listener);
    WlrCompositor *self = ps->owner;

    wlr_box geo = ps->popup->current.geometry;
    UtilityFunctions::print("waylandgodot: popup_mapped id=", ps->id,
        " parent=", ps->parent_window_id,
        " parent_popup=", ps->parent_popup_id,
        " x=", geo.x, " y=", geo.y, " w=", geo.width, " h=", geo.height);
    self->emit_signal("popup_mapped", ps->id, ps->parent_window_id, ps->parent_popup_id,
        geo.x, geo.y, geo.width, geo.height);
}

void WlrCompositor::on_popup_unmap(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, unmap_listener);
    WlrCompositor *self = ps->owner;
    self->emit_signal("popup_unmapped", ps->id);
}

void WlrCompositor::on_popup_reposition(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, reposition_listener);
    WlrCompositor *self = ps->owner;

    if (WindowState *parent = self->find_window(ps->parent_window_id)) {
        wlr_box constraint_box = {};
        constraint_box.x = 0;
        constraint_box.y = 0;
        constraint_box.width = parent->width > 0 ? parent->width : 800;
        constraint_box.height = parent->height > 0 ? parent->height : 600;
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
    }

    wlr_xdg_surface_schedule_configure(ps->popup->base);
}

void WlrCompositor::on_popup_destroy(wl_listener *listener, void *data) {
    PopupState *ps = wl_container_of(listener, ps, destroy_listener);
    WlrCompositor *self = ps->owner;
    int id = ps->id;

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
        } else {
            constraint_box.width = 800;
            constraint_box.height = 600;
        }
        wlr_xdg_popup_unconstrain_from_box(ps->popup, &constraint_box);
        wlr_xdg_surface_schedule_configure(ps->popup->base);
        return;
    }

    if (!self->capture_surface(ps->popup->base->surface, ps->texture, ps->width, ps->height, ps->capture_cache)) {
        return;
    }
    self->emit_signal("popup_texture_updated", ps->id, ps->texture, ps->width, ps->height);
}

// =====================================================================
// Cycle de vie
// =====================================================================

void WlrCompositor::start_headless() {
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

    wlr_output *fake_output = wlr_headless_add_output(backend, 1920, 1080);
    if (fake_output) {
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

    compositor = wlr_compositor_create(display, 6, renderer);
    xdg_shell = wlr_xdg_shell_create(display, 3);
    wlr_viewporter_create(display);
    wlr_subcompositor_create(display);

    // Nécessaire pour les clients qui rendent via GPU/dmabuf (ex: Firefox
    // + WebRender). Sans ce global, ces clients tentent de committer des
    // buffers dmabuf que le compositeur ne peut pas interpréter -> la
    // fenêtre se mappe (xdg-shell OK) mais rien n'est jamais affiché.
    if (!wlr_linux_dmabuf_v1_create_with_renderer(display, 4, renderer)) {
        UtilityFunctions::printerr("waylandgodot: échec création global linux-dmabuf-v1");
    }
    seat = wlr_seat_create(display, "seat0");

    wlr_data_device_manager_create(display);
    wlr_primary_selection_v1_device_manager_create(display);

    wlr_keyboard_init(&virtual_keyboard, &waylandgodot_KEYBOARD_IMPL, "waylandgodot-vkbd");

    xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    xkb_rule_names rule_names = {
        .rules = nullptr,
        .model = nullptr,
        .layout = "fr",
        .variant = nullptr,
        .options = nullptr,
    };
    xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &rule_names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    wlr_keyboard_set_keymap(&virtual_keyboard, keymap);
    xkb_keymap_unref(keymap);
    xkb_context_unref(ctx);

    wlr_seat_set_keyboard(seat, &virtual_keyboard);
    wlr_seat_set_capabilities(seat, WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

    keyboard_key_listener.notify = WlrCompositor::on_keyboard_key;
    wl_signal_add(&virtual_keyboard.events.key, &keyboard_key_listener);
    keyboard_modifiers_listener.notify = WlrCompositor::on_keyboard_modifiers;
    wl_signal_add(&virtual_keyboard.events.modifiers, &keyboard_modifiers_listener);

    new_toplevel_listener.notify = WlrCompositor::on_new_toplevel;
    wl_signal_add(&xdg_shell->events.new_toplevel, &new_toplevel_listener);

    const char *socket = wl_display_add_socket_auto(display);
    if (!socket) {
        UtilityFunctions::printerr("waylandgodot: impossible de créer le socket Wayland");
        return;
    }
    setenv("WAYLAND_DISPLAY", socket, 1);

    if (!wlr_backend_start(backend)) {
        UtilityFunctions::printerr("waylandgodot: échec démarrage backend");
        return;
    }

    UtilityFunctions::print("waylandgodot: compositeur headless prêt sur ", socket);
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
        wlr_surface_send_frame_done(ws.toplevel->base->surface, &now);
    }
    for (auto &pair : popups) {
        PopupState &ps = pair.second;
        if (ps.popup && ps.popup->base && ps.popup->base->surface) {
            wlr_surface_send_frame_done(ps.popup->base->surface, &now);
        }
    }

    // Recapture la fenêtre active à chaque frame : le commit_listener de la
    // surface racine ne suffit pas pour les clients (Firefox, etc.) dont le
    // contenu réel vit dans une sous-surface qui committe indépendamment
    // (souvent en mode désynchronisé) - sans ça l'image reste figée entre
    // deux commits de la racine, d'où l'effet de lag.
    if (active_toplevel_id != -1) {
        WindowState *active = find_window(active_toplevel_id);
        if (active && capture_surface(active->toplevel->base->surface,
                active->texture, active->width, active->height, active->capture_cache)) {
            emit_signal("window_texture_updated", active->id, active->texture,
                active->width, active->height);
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
}

// --- Input ---------------------------------------------------------------

void WlrCompositor::notify_pointer_motion_on_surface(wlr_surface *surface, double surface_x, double surface_y) {
    if (!surface || !seat) return;
    uint32_t time = get_time_msec();

    if (seat->pointer_state.focused_surface != surface) {
        wlr_seat_pointer_notify_enter(seat, surface, surface_x, surface_y);
    }
    wlr_seat_pointer_notify_motion(seat, time, surface_x, surface_y);
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_pointer_motion(int window_id, double surface_x, double surface_y) {
    WindowState *ws = find_window(window_id);
    if (!ws) return;
    notify_pointer_motion_on_surface(ws->toplevel->base->surface, surface_x, surface_y);
}

void WlrCompositor::forward_pointer_motion_popup(int popup_id, double surface_x, double surface_y) {
    PopupState *ps = find_popup(popup_id);
    if (!ps) return;
    notify_pointer_motion_on_surface(ps->popup->base->surface, surface_x, surface_y);
}

void WlrCompositor::forward_pointer_button(int window_id, int button, bool pressed) {
    WindowState *ws = find_window(window_id);
    if (!ws || !seat) return;

    UtilityFunctions::print("waylandgodot: button id=", window_id,
        " pressed=", pressed,
        " focus_ok=", (seat->pointer_state.focused_surface == ws->toplevel->base->surface));

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);

    if (pressed) {
        if (active_toplevel_id != window_id) {
            if (WindowState *prev = find_window(active_toplevel_id)) {
                wlr_xdg_toplevel_set_activated(prev->toplevel, false);
            }
            wlr_xdg_toplevel_set_activated(ws->toplevel, true);
            active_toplevel_id = window_id;
        }

        wlr_seat_keyboard_notify_enter(seat, ws->toplevel->base->surface,
            virtual_keyboard.keycodes,
            virtual_keyboard.num_keycodes,
            &virtual_keyboard.modifiers);
    }
}

void WlrCompositor::forward_pointer_button_popup(int popup_id, int button, bool pressed) {
    PopupState *ps = find_popup(popup_id);
    if (!ps || !seat) return;

    wlr_seat_pointer_notify_button(seat, get_time_msec(), (uint32_t)button,
        pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    wlr_seat_pointer_notify_frame(seat);
}

void WlrCompositor::forward_pointer_axis(int window_id, double delta_x, double delta_y) {
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

void WlrCompositor::forward_keyboard_key(int godot_physical_keycode, int key_location, bool pressed) {
    if (!seat) return;

    uint32_t evdev_code;
    if (godot_physical_keycode == (int)Key::KEY_ALT && key_location == 2) {
        evdev_code = 100; // KEY_RIGHTALT / AltGr
    } else {
        auto it = GODOT_TO_EVDEV.find(godot_physical_keycode);
        if (it == GODOT_TO_EVDEV.end()) {
            return;
        }
        evdev_code = it->second;
    }

    wlr_keyboard_key_event event = {};
    event.time_msec = get_time_msec();
    event.keycode = evdev_code;
    event.update_state = true;
    event.state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED;

    wlr_keyboard_notify_key(&virtual_keyboard, &event);
}

// --- Utilitaires -----------------------------------------------------------

String WlrCompositor::get_wayland_socket_name() const {
    const char *s = getenv("WAYLAND_DISPLAY");
    return s ? String(s) : String("");
}

void WlrCompositor::launch_app(const String &command) {
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        CharString cmd = command.utf8();
        execl("/bin/sh", "sh", "-c", cmd.get_data(), (char *)nullptr);
        _exit(127);
    } else if (pid < 0) {
        UtilityFunctions::printerr("waylandgodot: fork() a échoué pour launch_app");
    }
}

void WlrCompositor::set_window_size(int window_id, int width, int height) {
    WindowState *ws = find_window(window_id);
    if (!ws || !ws->toplevel) return;

    if (width < 50) width = 50;
    if (height < 50) height = 50;

    wlr_xdg_toplevel_set_size(ws->toplevel, width, height);
    wlr_xdg_surface_schedule_configure(ws->toplevel->base);
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
    return !pixman_region32_empty(&ps->popup->base->surface->current.input);
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