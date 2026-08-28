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
bool WlrCompositor::probe_dmabuf_vulkan_import() {
    if (!renderer || !allocator) return false;

    RenderingDevice *vrd = RenderingServer::get_singleton()->get_rendering_device();
    if (!vrd) return false;

    // Initialise les handles Vulkan depuis le RenderingDevice de Godot. En
    // cas d'échec, vulkan_import reste indisponible et on retombe sur Pixman.
    if (!vulkan_import.initialize(vrd)) {
        UtilityFunctions::print("waylandgodot: dmabuf probe: Vulkan not initialized");
        return false;
    }

    static constexpr int PROBE_W = 16;
    static constexpr int PROBE_H = 16;

    uint64_t linear_mod = DRM_FORMAT_MOD_LINEAR;
    struct wlr_drm_format linear_fmt = {};
    linear_fmt.format = DRM_FORMAT_ABGR8888;
    linear_fmt.modifiers = &linear_mod;
    linear_fmt.len = 1;

    wlr_buffer *probe_buf = wlr_allocator_create_buffer(allocator, PROBE_W, PROBE_H, &linear_fmt);
    if (!probe_buf) {
        UtilityFunctions::print("waylandgodot: dmabuf probe: gbm_bo_create failed");
        return false;
    }

    wlr_dmabuf_attributes attribs = {};
    if (!wlr_buffer_get_dmabuf(probe_buf, &attribs) || attribs.n_planes != 1) {
        UtilityFunctions::print("waylandgodot: dmabuf probe: no single-plane dmabuf");
        wlr_buffer_drop(probe_buf);
        return false;
    }

    VulkanDmaBufTexture vt = vulkan_import.import_dma_buf(
        attribs.fd[0], PROBE_W, PROBE_H, DRM_FORMAT_ABGR8888);

    if (vt.vk_image == VK_NULL_HANDLE) {
        UtilityFunctions::print("waylandgodot: dmabuf probe: Vulkan import failed "
            "(driver cannot import the dmabuf)");
        wlr_buffer_drop(probe_buf);
        return false;
    }

    // Pipeline validé — libère les ressources de test (déférées d'une frame).
    vulkan_import.release_texture(vt);
    wlr_buffer_drop(probe_buf);
    UtilityFunctions::print("waylandgodot: dmabuf probe: Vulkan import OK");
    return true;
}
void CaptureCache::reset(RenderingDevice *rd) {
    // Libérer les ressources Vulkan AVANT le wlr_buffer : le RID
    // wrappe un VkImageView qui référence le VkImage, lequel est backing
    // par le même fd DMA-BUF que le wlr_buffer.  Tant que le RID existe,
    // Godot peut encore interroger le VkImage.
    if (vulkan_import && (vk_image != VK_NULL_HANDLE || vulkan_rid.is_valid())) {
        // Chemin Vulkan : libère le VkImage + VkDeviceMemory + RID via
        // release_texture() (destruction différée au prochain flush_pending,
        // après vkDeviceWaitIdle — le GPU peut encore référencer l'image).
        // Avant ce fix, le reset d'une fenêtre en backend VULKAN libérait le
        // RID (seulement si `rd` était non-null) mais JAMAIS vkDestroyImage /
        // vkFreeMemory : chaque fermeture de fenêtre partagée fuyait le VkImage
        // et sa mémoire GPU.
        VulkanDmaBufTexture tex;
        tex.rid = vulkan_rid;
        tex.texture = rd_texture;
        tex.vk_image = vk_image;
        tex.vk_memory = vk_memory;
        vulkan_import->release_texture(tex);
    } else if (vulkan_rid.is_valid() && rd) {
        rd->free_rid(vulkan_rid);
    }
    vulkan_rid = RID();
    rd_texture = Ref<Texture2DRD>();
    vk_image = VK_NULL_HANDLE;
    vk_memory = VK_NULL_HANDLE;

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
static inline int round_up_capture_size(int v) {
    static constexpr int CAPTURE_SIZE_STEP = 64;
    return (v + CAPTURE_SIZE_STEP - 1) / CAPTURE_SIZE_STEP * CAPTURE_SIZE_STEP;
}
bool WlrCompositor::capture_surface(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    static bool printed_path = false;
    // Essayer d'abord le chemin Vulkan zero-copy (GPU→GPU, pas de CPU readback).
    if (gpu_pipeline_active && dmabuf_available &&
        capture_surface_vulkan(surface, tex, out_w, out_h, cache)) {
        if (!printed_path) {
            UtilityFunctions::print("waylandgodot: [diag] capture -> vulkan (gpu=", gpu_pipeline_active,
                " dmabuf=", dmabuf_available, ")");
            printed_path = true;
        }
        return true;
    }
    // Fallback : dmabuf + mmap CPU readback.
    if (dmabuf_available && capture_surface_dmabuf(surface, tex, out_w, out_h, cache)) {
        if (!printed_path) {
            UtilityFunctions::print("waylandgodot: [diag] capture -> dmabuf (gpu=", gpu_pipeline_active,
                " dmabuf=", dmabuf_available, ")");
            printed_path = true;
        }
        return true;
    }
    // Dernier recours : Pixman (rendu logiciel, buffer en RAM).
    bool ok = capture_surface_pixels(surface, tex, out_w, out_h, cache);
    if (!printed_path) {
        UtilityFunctions::print("waylandgodot: [diag] capture -> pixels ok=", ok,
            " (gpu=", gpu_pipeline_active, " dmabuf=", dmabuf_available, ")");
        printed_path = true;
    }
    return ok;
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
static void wait_for_dmabuf_gpu_writes(int dma_fd, int timeout_ms) {
    if (dma_fd < 0) return;

    // Tenter EXPORT_SYNC_FILE d'abord (sync GPU fiable cross-API).
    struct dma_buf_export_sync_file export_args = {};
    export_args.flags = DMA_BUF_SYNC_WRITE;
    if (ioctl(dma_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_args) == 0) {
        struct pollfd pfd;
        pfd.fd = export_args.fd;
        pfd.events = POLLIN;
        // Bloque jusqu'à l'achèvement GPU, borné à timeout_ms (10 ms en
        // régime normal, 4 ms sous pression — voir capture_poll_timeout_ms) :
        // si le sync_file ne signale pas (GPU saturé, stall pathologique), on
        // NE bloque PAS le thread principal indéfiniment — sinon le service
        // réseau n'est plus appelé et ENet finit par déconnecter le peer
        // (timeout). Au pire on lit un buffer pas encore synchronisé →
        // artefact visuel transitoire sur le quad, jamais un gel durable.
        poll(&pfd, 1, timeout_ms);
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
            UtilityFunctions::printerr("waylandgodot: renderer does not support WLR_BUFFER_CAP_DMABUF");
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
            UtilityFunctions::printerr("waylandgodot: unable to create a linear dmabuf buffer ",
                "(the GPU may only support tiled formats)");
            return false;
        }

        // Export dmabuf
        wlr_dmabuf_attributes attribs = {};
        if (!wlr_buffer_get_dmabuf(offscreen, &attribs)) {
            UtilityFunctions::printerr("waylandgodot: dmabuf: wlr_buffer_get_dmabuf failed");
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
            UtilityFunctions::printerr("waylandgodot: dmabuf: mmap failed");
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
        UtilityFunctions::printerr("waylandgodot: dmabuf: begin_buffer_pass failed");
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
        UtilityFunctions::printerr("waylandgodot: dmabuf: no subsurface with a texture to blit");
        return false;
    }

    timespec t_render_start, t_render_end;
    clock_gettime(CLOCK_MONOTONIC, &t_render_start);
    if (!wlr_render_pass_submit(pass)) {
        UtilityFunctions::printerr("waylandgodot: dmabuf: render_pass_submit failed");
        return false;
    }
    clock_gettime(CLOCK_MONOTONIC, &t_render_end);

    // Attendre que le render pass EGL/GLES2 soit terminé sur le GPU
    // AVANT de lire les pixels en mmap. Sans cette synchronisation,
    // le memcpy peut lire des données partiellement écrites par le GPU.
    wait_for_dmabuf_gpu_writes(cache.dma_fd, capture_poll_timeout_ms());

    // Partage vidéo inter-frame : soumet le DMA-BUF à l'encodeur (thread
    // worker). Le buffer vient d'être rendu et synchronisé — c'est le point
    // idéal pour le capture, sans copie CPU sur le thread principal (le
    // worker lit le fd en mmap). No-op si le partage vidéo est inactif.
    submit_video_frame(cache);

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
    if (cache.format == DRM_FORMAT_XBGR8888) {
        // RGBX : le 4e octet est un padding indéfini (souvent 0). Recopié
        // tel quel dans l'alpha RGBA de sortie, il rend la fenêtre « pleine-
        // ment transparente » pour tout lecteur du canal alpha (stream JPEG
        // LAN, analyse de transparence du mode focus). On force opaque.
        for (int y = 0; y < h; y++) {
            const uint8_t *row = cache.data + (size_t)y * cache.stride;
            for (int x = 0; x < w; x++) {
                dst[(y * w + x) * 4 + 0] = row[x * 4 + 0]; // R
                dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
                dst[(y * w + x) * 4 + 2] = row[x * 4 + 2]; // B
                dst[(y * w + x) * 4 + 3] = 255;            // A (padding X)
            }
        }
    } else if (cache.format == DRM_FORMAT_ABGR8888) {
        // RGBA avec alpha réel → copie directe par ligne (stride peut > w*4)
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

    if (!cache.debug_sampled) {
        cache.debug_sampled = true;
        const uint8_t *s = cache.bytes.ptr();
        auto px = [&](int x, int y) -> String {
            if (x < 0 || y < 0 || x >= w || y >= h) return String("out-of-buffer");
            const uint8_t *p = s + ((size_t)y * w + (size_t)x) * 4;
            return String::num(p[0]) + "," + String::num(p[1]) + "," +
                String::num(p[2]) + "," + String::num(p[3]);
        };
        UtilityFunctions::print("waylandgodot: [diag] dmabuf pixels ", w, "x", h,
            " fmt=0x", String::num_uint64(cache.format, 16),
            " stride=", cache.stride,
            " TL=", px(0, 0), " C=", px(w / 2, h / 2),
            " BR=", px(w - 1, h - 1));
    }

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
        cache.vulkan_import = &vulkan_import;

        // Libérer les anciennes ressources (détruit VkImage, VkDeviceMemory,
        // RID, et wlr_buffer). vkDeviceWaitIdle est appelé dedans pour
        // sérialiser avec le rendering thread de Godot.
        if (old_vt.vk_image != VK_NULL_HANDLE) {
            vulkan_import.release_texture(old_vt);
        }
        if (old_offscreen) {
            wlr_buffer_drop(old_offscreen);
        }

        // mmap du dmabuf pour la copie CPU synchrone (partage LAN). Même
        // principe que le chemin DMABUF : lecture fiable du contenu juste
        // après le rendu, contrairement au readback RD différé. Un échec de
        // mmap ne bloque PAS l'affichage zero-copy, il rend juste le partage
        // indisponible pour cette fenêtre.
        if (cache.map_base) {
            munmap(cache.map_base, cache.map_size);
            cache.map_base = nullptr;
            cache.map_size = 0;
            cache.data = nullptr;
            cache.stride = 0;
        }
        if (attribs.modifier == DRM_FORMAT_MOD_INVALID ||
            attribs.modifier == DRM_FORMAT_MOD_LINEAR) {
            long page_size = sysconf(_SC_PAGE_SIZE);
            off_t plane_offset = (off_t)attribs.offset[0];
            off_t map_offset = plane_offset & ~(off_t)(page_size - 1);
            size_t map_delta = (size_t)(plane_offset - map_offset);
            size_t map_size = map_delta + (size_t)attribs.stride[0] * (size_t)alloc_h;
            void *map_base = mmap(nullptr, map_size, PROT_READ, MAP_SHARED,
                                  attribs.fd[0], map_offset);
            if (map_base == MAP_FAILED) {
                UtilityFunctions::printerr("waylandgodot: vulkan: dmabuf mmap failed");
                map_base = nullptr;
            } else {
                cache.map_base = map_base;
                cache.map_size = map_size;
                cache.data = static_cast<uint8_t *>(map_base) + map_delta;
                cache.stride = attribs.stride[0];
            }
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

    timespec t_r0, t_r1, t_c0, t_c1;
    clock_gettime(CLOCK_MONOTONIC, &t_r0);

    // Attendre que le render pass EGL/GLES2 soit terminé sur le GPU
    // avant que Godot n'échantillonne le VkImage (backed par le même
    // DMA-BUF). DMA_BUF_IOCTL_EXPORT_SYNC_FILE exporte un sync_file
    // représentant les écritures GPU en cours, puis poll() bloque
    // jusqu'à leur achèvement. C'est la seule synchronisation fiable
    // entre deux API GPU (EGL wlroots ↔ Vulkan Godot).
    wait_for_dmabuf_gpu_writes(cache.dma_fd, capture_poll_timeout_ms());

    // Partage vidéo inter-frame : soumet le DMA-BUF à l'encodeur (thread
    // worker), juste après le rendu et la synchronisation GPU — aucun
    // memcpy sur le thread principal (contrairement au chemin JPEG).
    submit_video_frame(cache);
    clock_gettime(CLOCK_MONOTONIC, &t_r1);
    t_c0 = t_r1;

    // Copie CPU synchrone pour le partage LAN (get_window_cpu_image) : on
    // lit le dmabuf IMMÉDIATEMENT après le rendu, tant qu'il est encore le
    // buffer de capture de cette fenêtre. C'est le même principe fiable que
    // capture_surface_dmabuf — un readback RD différé (texture_get_data)
    // peut arriver trop tard et lire un buffer réutilisé par un autre rendu.
    // NB : l'AFFICHAGE des quads passe par le VkImage zero-copy (cache.rd_
    // texture), pas par cette copie. Elle n'est nécessaire que si le partage
    // LAN la lit (cpu_capture_requested). La bloquer (DMA_BUF_SYNC + memcpy/
    // swizzle) coûte 30-50 ms sur le thread principal pour une fenêtre
    // 1920×1080 : sans demande LAN, on la saute entièrement.
    if (cpu_capture_requested && cache.data && cache.stride > 0) {
        if (cache.bytes.size() != (int64_t)w * h * 4) {
            cache.bytes.resize((int64_t)w * h * 4);
        }
        uint8_t *dst = cache.bytes.ptrw();
        struct dma_buf_sync sync = {};
        sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
        ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
        bool has_alpha = (cache.format == DRM_FORMAT_ABGR8888 ||
                          cache.format == DRM_FORMAT_ARGB8888);
        if (cache.format == DRM_FORMAT_XBGR8888) {
            // RGBX : padding X indéfini → alpha forcé opaque (cf. capture
            // dmabuf).
            for (int y = 0; y < h; y++) {
                const uint8_t *row = cache.data + (size_t)y * cache.stride;
                for (int x = 0; x < w; x++) {
                    dst[(y * w + x) * 4 + 0] = row[x * 4 + 0]; // R
                    dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
                    dst[(y * w + x) * 4 + 2] = row[x * 4 + 2]; // B
                    dst[(y * w + x) * 4 + 3] = 255;            // A
                }
            }
        } else if (cache.format == DRM_FORMAT_ABGR8888) {
            // RGBA en mémoire → copie directe par ligne (stride peut > w*4)
            for (int y = 0; y < h; y++) {
                memcpy(dst + (size_t)y * w * 4,
                    cache.data + (size_t)y * cache.stride,
                    (size_t)w * 4);
            }
        } else {
            // BGRA en mémoire → swizzle B↔R par pixel (contenu opaque)
            for (int y = 0; y < h; y++) {
                const uint8_t *row = cache.data + (size_t)y * cache.stride;
                for (int x = 0; x < w; x++) {
                    dst[(y * w + x) * 4 + 0] = row[x * 4 + 2]; // R <- B
                    dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
                    dst[(y * w + x) * 4 + 2] = row[x * 4 + 0]; // B <- R
                    dst[(y * w + x) * 4 + 3] = has_alpha ? row[x * 4 + 3] : 255;
                }
            }
        }
        sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
        ioctl(cache.dma_fd, DMA_BUF_IOCTL_SYNC, &sync);
    }
    clock_gettime(CLOCK_MONOTONIC, &t_c1);

    auto cms = [](const timespec &a, const timespec &b) {
        return (b.tv_sec - a.tv_sec) * 1000.0 + (b.tv_nsec - a.tv_nsec) / 1e6;
    };
    double d_wait = cms(t_r0, t_r1);
    double d_copy = cms(t_c0, t_c1);
    double d_total = d_wait + d_copy;
    if (d_total > 1.0) { // ne log que les captures qui coûtent réellement
        UtilityFunctions::print("waylandgodot: [diag] vulkan capture ", w, "x", h,
            " wait_gpu=", d_wait, "ms cpu_copy=", d_copy, "ms TOTAL=", d_total, "ms");
    }

    tex = cache.rd_texture;
    out_w = w;
    out_h = h;
    return true;
}
bool WlrCompositor::capture_surface_pixels(wlr_surface *surface, Ref<Texture2D> &tex, int &out_w, int &out_h, CaptureCache &cache) {
    if (!renderer || !allocator) return false;

    wlr_texture *root_texture = wlr_surface_get_texture(surface);
    // Ne pas retourner false si root_texture est NULL : Firefox (entre
    // autres) dessine son contenu WebRender dans des sous-surfaces et peut
    // ne committer aucun buffer sur la surface racine (popups, menus en
    // cascade). wlr_surface_for_each_surface itérera quand même sur les
    // sous-surfaces (même logique que le chemin dmabuf).

    // Recadre sur la géométrie xdg effective (window_geometry) EN PREMIER
    // (même logique que les chemins dmabuf/vulkan).
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
    // taille brute du buffer (root_texture->width/height) : sur un client
    // HiDPI (buffer_scale > 1) le buffer physique est plus grand que la
    // taille affichée. Fallback quand la géométrie xdg n'est pas disponible
    // (fenêtres sans CSD, surfaces sans set_window_geometry).
    if (w <= 0 || h <= 0) {
        w = surface->current.width > 0 ? surface->current.width : (root_texture ? (int)root_texture->width : 0);
        h = surface->current.height > 0 ? surface->current.height : (root_texture ? (int)root_texture->height : 0);
    }
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
            UtilityFunctions::printerr("waylandgodot: DRM_FORMAT_ARGB8888 not supported for CPU read by this renderer");
            return false;
        }

        wlr_buffer *offscreen = wlr_allocator_create_buffer(allocator, alloc_w, alloc_h, fmt);
        if (!offscreen) {
            UtilityFunctions::printerr("waylandgodot: offscreen buffer allocation failed");
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
        UtilityFunctions::printerr("waylandgodot: begin_buffer_pass failed");
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

    // ---- Render pass: racine + sous-surfaces → buffer offscreen --------
    // Firefox (entre autres) dessine son contenu WebRender dans une
    // sous-surface enfant distincte de la surface racine (qui ne porte que
    // le chrome/CSD) : sans l'itération ci-dessous, seule la barre de titre
    // est capturée et le reste reste vide. Le chemin dmabuf/vulkan le fait
    // déjà ; ce chemin pixels (fallback CPU, utilisé en WSL/VM sans GPU)
    // doit faire pareil sinon le contenu des sous-surfaces disparaît.
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

    int blitted = 0;
    for (auto &inst : instances) {
        wlr_texture *sub_texture = wlr_surface_get_texture(inst.surface);
        if (!sub_texture) continue;

        int sub_w = inst.surface->current.width > 0
            ? inst.surface->current.width : (int)sub_texture->width;
        int sub_h = inst.surface->current.height > 0
            ? inst.surface->current.height : (int)sub_texture->height;

        // Décale dst_box de (-geo_x, -geo_y) pour ne rasteriser que la zone
        // de contenu (window_geometry). Les pixels d'ombre CSD en dehors de
        // cette zone tombent en dehors du buffer et sont clipés par le
        // render pass.
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

    timespec t_render_start, t_render_end;
    clock_gettime(CLOCK_MONOTONIC, &t_render_start);
    if (!wlr_render_pass_submit(pass)) {
        UtilityFunctions::printerr("waylandgodot: render_pass_submit failed");
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
        UtilityFunctions::printerr("waylandgodot: begin_data_ptr_access failed on the offscreen buffer");
        return false;
    }

    uint8_t *dst = cache.bytes.ptrw();
    const uint8_t *src = static_cast<const uint8_t *>(pixels);

    // DRM_FORMAT_ARGB8888 = BGRA en mémoire (little-endian) → swizzle RGBA.
    // L'alpha du buffer est préservée : le shader 3D discard les pixels à
    // alpha ≈ 0, donc forcer A=0 rendait TOUTES les fenêtres transparentes
    // dans ce chemin de secours CPU (alors que les chemins Vulkan/DMABUF
    // conservent l'alpha réel). Une fenêtre opaque rend A=255 ; seules les
    // zones réellement transparentes (coins arrondis, ombres CSD) restent à 0.
    timespec t_copy_start, t_copy_end;
    clock_gettime(CLOCK_MONOTONIC, &t_copy_start);
    for (int y = 0; y < h; y++) {
        const uint8_t *row = src + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            dst[(y * w + x) * 4 + 0] = row[x * 4 + 2]; // R <- B
            dst[(y * w + x) * 4 + 1] = row[x * 4 + 1]; // G
            dst[(y * w + x) * 4 + 2] = row[x * 4 + 0]; // B <- R
            dst[(y * w + x) * 4 + 3] = row[x * 4 + 3]; // A <- A (ARGB8888)
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t_copy_end);

    if (!cache.debug_sampled) {
        cache.debug_sampled = true;
        const uint8_t *s = cache.bytes.ptr();
        auto px = [&](int x, int y) -> String {
            if (x < 0 || y < 0 || x >= w || y >= h) return String("out-of-buffer");
            const uint8_t *p = s + ((size_t)y * w + (size_t)x) * 4;
            return String::num(p[0]) + "," + String::num(p[1]) + "," +
                String::num(p[2]) + "," + String::num(p[3]);
        };
        UtilityFunctions::print("waylandgodot: [diag] pixels pixels ", w, "x", h,
            " fmt=0x", String::num_uint64(px_format, 16),
            " stride=", stride,
            " TL=", px(0, 0), " C=", px(w / 2, h / 2),
            " BR=", px(w - 1, h - 1));
    }

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
Ref<Image> WlrCompositor::get_window_cpu_image(int window_id) {
    WindowState *ws = find_window(window_id);
    if (!ws) return Ref<Image>();
    CaptureCache &cache = ws->capture_cache;
    if (cache.bytes.is_empty() || cache.width <= 0 || cache.height <= 0) {
        return Ref<Image>();
    }
    // cache.bytes est RGBA8 tightly-packed, mis à jour de façon synchrone à
    // chaque capture (chemin Vulkan) ou par le chemin dmabuf/pixels.
    return Image::create_from_data(cache.width, cache.height, false,
        Image::FORMAT_RGBA8, cache.bytes);
}
void WlrCompositor::set_cpu_capture_requested(bool requested) {
    cpu_capture_requested = requested;
}
void WlrCompositor::submit_video_frame(CaptureCache &cache) {
    if (!video_share.is_active() || cache.wid < 0 || cache.dma_fd < 0 ||
        cache.stride == 0) {
        return;
    }
    video_share.submit_dmabuf(cache.wid, dup(cache.dma_fd), cache.stride,
        cache.format, cache.alloc_width, cache.alloc_height,
        cache.width, cache.height);
}
