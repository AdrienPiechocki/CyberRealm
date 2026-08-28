#include "vulkan_dmauf.h"

#include <dlfcn.h>
#include <unistd.h>
#include <libdrm/drm_fourcc.h>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// =====================================================================
// DRM fourcc → Godot RenderingDevice::DataFormat
// =====================================================================

uint32_t VulkanDmaBufImport::drm_to_rd_format(uint32_t drm_format) {
    switch (drm_format) {
        case DRM_FORMAT_ABGR8888:
        case DRM_FORMAT_XBGR8888:
            return RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM;
        case DRM_FORMAT_ARGB8888:
        case DRM_FORMAT_XRGB8888:
            return RenderingDevice::DATA_FORMAT_B8G8R8A8_UNORM;
        default:
            return RenderingDevice::DATA_FORMAT_MAX;
    }
}

// =====================================================================
// initialize — acquire Vulkan handles from Godot, load function pointers
// =====================================================================

bool VulkanDmaBufImport::initialize(RenderingDevice *p_rd) {
    rd = p_rd;
    if (!rd) return false;

    // --- Load Vulkan loader via dlopen --------------------------------
    void *vklib = dlopen("libvulkan.so.1", RTLD_LAZY);
    if (!vklib) vklib = dlopen("libvulkan.so", RTLD_LAZY);
    if (!vklib) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: impossible de charger libvulkan");
        return false;
    }

    p_vkGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        dlsym(vklib, "vkGetInstanceProcAddr"));
    if (!p_vkGetInstanceProcAddr) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: vkGetInstanceProcAddr introuvable");
        return false;
    }

    // --- Get handles from Godot's RenderingDevice ---------------------
    vk_instance = reinterpret_cast<VkInstance>(
        rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_INSTANCE, RID(), 0));
    vk_physical_device = reinterpret_cast<VkPhysicalDevice>(
        rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_PHYSICAL_DEVICE, RID(), 0));
    vk_device = reinterpret_cast<VkDevice>(
        rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_DEVICE, RID(), 0));
    vk_queue = reinterpret_cast<VkQueue>(
        rd->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_VULKAN_QUEUE, RID(), 0));

    if (!vk_instance || !vk_physical_device || !vk_device || !vk_queue) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: handles invalides depuis RenderingDevice");
        return false;
    }

    if (!load_function_pointers()) return false;

    // Query physical device memory properties.
    p_GetPhysicalDeviceMemoryProperties(vk_physical_device, &mem_properties);

    // The extension function must have loaded — otherwise
    // VK_KHR_external_memory_fd is not supported by this driver.
    if (!p_GetMemoryFdPropertiesKHR) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "VK_KHR_external_memory_fd non supporté par le pilote");
        return false;
    }

    available = true;
    UtilityFunctions::print("waylandgodot: Vulkan DMA-BUF import initialisé "
        "(VK_KHR_external_memory_fd)");
    return true;
}

// =====================================================================
// load_function_pointers — instance-level + device-level + extension
// =====================================================================

bool VulkanDmaBufImport::load_function_pointers() {
    // Device-level entry point (via VK_KHR_get_device_proc_addr or
    // implicitly from vkGetInstanceProcAddr on most drivers).
    p_vkGetDeviceProcAddr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
        p_vkGetInstanceProcAddr(vk_instance, "vkGetDeviceProcAddr"));
    if (!p_vkGetDeviceProcAddr) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: vkGetDeviceProcAddr introuvable");
        return false;
    }

    // Instance-level.
    p_GetPhysicalDeviceMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        p_vkGetInstanceProcAddr(vk_instance, "vkGetPhysicalDeviceMemoryProperties"));

    // Device-level core.
    p_CreateImage = reinterpret_cast<PFN_vkCreateImage>(
        p_vkGetDeviceProcAddr(vk_device, "vkCreateImage"));
    p_DestroyImage = reinterpret_cast<PFN_vkDestroyImage>(
        p_vkGetDeviceProcAddr(vk_device, "vkDestroyImage"));
    p_GetImageMemoryRequirements = reinterpret_cast<PFN_vkGetImageMemoryRequirements>(
        p_vkGetDeviceProcAddr(vk_device, "vkGetImageMemoryRequirements"));
    p_AllocateMemory = reinterpret_cast<PFN_vkAllocateMemory>(
        p_vkGetDeviceProcAddr(vk_device, "vkAllocateMemory"));
    p_FreeMemory = reinterpret_cast<PFN_vkFreeMemory>(
        p_vkGetDeviceProcAddr(vk_device, "vkFreeMemory"));
    p_BindImageMemory = reinterpret_cast<PFN_vkBindImageMemory>(
        p_vkGetDeviceProcAddr(vk_device, "vkBindImageMemory"));
    p_QueueWaitIdle = reinterpret_cast<PFN_vkQueueWaitIdle>(
        p_vkGetDeviceProcAddr(vk_device, "vkQueueWaitIdle"));
    p_DeviceWaitIdle = reinterpret_cast<PFN_vkDeviceWaitIdle>(
        p_vkGetDeviceProcAddr(vk_device, "vkDeviceWaitIdle"));

    // Fence functions (for non-blocking flush_pending).
    p_CreateFence = reinterpret_cast<PFN_vkCreateFence>(
        p_vkGetDeviceProcAddr(vk_device, "vkCreateFence"));
    p_DestroyFence = reinterpret_cast<PFN_vkDestroyFence>(
        p_vkGetDeviceProcAddr(vk_device, "vkDestroyFence"));
    p_GetFenceStatus = reinterpret_cast<PFN_vkGetFenceStatus>(
        p_vkGetDeviceProcAddr(vk_device, "vkGetFenceStatus"));
    p_ResetFences = reinterpret_cast<PFN_vkResetFences>(
        p_vkGetDeviceProcAddr(vk_device, "vkResetFences"));
    p_QueueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(
        p_vkGetDeviceProcAddr(vk_device, "vkQueueSubmit"));

    // Extension: VK_KHR_external_memory_fd.
    p_GetMemoryFdPropertiesKHR = reinterpret_cast<PFN_vkGetMemoryFdPropertiesKHR>(
        p_vkGetDeviceProcAddr(vk_device, "vkGetMemoryFdPropertiesKHR"));

    if (!p_CreateImage || !p_DestroyImage || !p_GetImageMemoryRequirements ||
        !p_AllocateMemory || !p_FreeMemory || !p_BindImageMemory ||
        !p_DeviceWaitIdle) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "fonctions Vulkan core manquantes");
        return false;
    }

    // Fence functions are optional — fallback to vkDeviceWaitIdle if missing.
    if (!p_CreateFence || !p_DestroyFence || !p_GetFenceStatus ||
        !p_ResetFences || !p_QueueSubmit) {
        UtilityFunctions::print("waylandgodot: Vulkan: "
            "fonctions fence manquantes, fallback vkDeviceWaitIdle");
    }

    return true;
}

// =====================================================================
// find_memory_type — pick a memory type compatible with both the image
// requirements and the imported DMA-BUF.
// =====================================================================

uint32_t VulkanDmaBufImport::find_memory_type(uint32_t type_bits,
                                               uint32_t fd_type_bits) {
    uint32_t compatible = type_bits & fd_type_bits;

    // Prefer DEVICE_LOCAL for best GPU sampling performance.
    for (uint32_t i = 0; i < mem_properties.memoryTypeCount; i++) {
        if ((compatible & (1u << i)) &&
            (mem_properties.memoryTypes[i].propertyFlags &
             VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            return i;
        }
    }
    // Fallback: any compatible type (may be HOST_VISIBLE on some drivers).
    for (uint32_t i = 0; i < mem_properties.memoryTypeCount; i++) {
        if (compatible & (1u << i)) {
            return i;
        }
    }
    return UINT32_MAX;
}

// =====================================================================
// import_dma_buf — the core import: DMA-BUF fd → VkImage → RID → Texture2DRD
// =====================================================================

VulkanDmaBufTexture VulkanDmaBufImport::import_dma_buf(int fd,
                                                       uint32_t width,
                                                       uint32_t height,
                                                       uint32_t drm_format) {
    VulkanDmaBufTexture result;

    if (!available) return result;

    RenderingDevice::DataFormat rd_format =
        static_cast<RenderingDevice::DataFormat>(drm_to_rd_format(drm_format));
    if (rd_format == RenderingDevice::DATA_FORMAT_MAX) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "format DRM non mappé: 0x", String::num_uint64(drm_format));
        return result;
    }

    // Vulkan format = Godot DataFormat + 1 (Godot's enum is offset by 1
    // relative to the Vulkan spec for backward-compat reasons).
    VkFormat vk_format = static_cast<VkFormat>(static_cast<int>(rd_format) + 1);

    // Dup the fd — Vulkan takes ownership of the dup on import.
    int dup_fd = dup(fd);
    if (dup_fd < 0) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: dup() a échoué pour dmabuf fd");
        return result;
    }

    // --- Serialize with Godot's rendering thread -----------------------
    //     Raw Vulkan device calls MUST NOT race with Godot's rendering
    //     thread which uses the same VkDevice. vkDeviceWaitIdle drains
    //     all submitted GPU work so the device is quiescent.
    if (p_DeviceWaitIdle) {
        p_DeviceWaitIdle(vk_device);
    }

    // --- Query memory properties for this DMA-BUF fd ------------------
    VkMemoryFdPropertiesKHR fd_props = {};
    fd_props.sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR;

    VkResult res = p_GetMemoryFdPropertiesKHR(
        vk_device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        dup_fd, &fd_props);
    if (res != VK_SUCCESS) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "vkGetMemoryFdPropertiesKHR a échoué: ", String::num_int64(res));
        close(dup_fd);
        return result;
    }

    // --- Create VkImage with external memory --------------------------
    VkExternalMemoryImageCreateInfo ext_mem_info = {};
    ext_mem_info.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
    ext_mem_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;

    VkImageCreateInfo image_info = {};
    image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.pNext = &ext_mem_info;
    image_info.imageType = VK_IMAGE_TYPE_2D;
    image_info.format = vk_format;
    image_info.extent = {width, height, 1};
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    // LINEAR tiling: matches the DMA-BUF's DRM_FORMAT_MOD_LINEAR layout.
    // Using OPTIMAL here causes GPUVM faults because the driver sets up
    // GPU page tables for a tiled layout while the actual backing memory
    // is linear → the GPU reads garbage addresses.
    image_info.tiling = VK_IMAGE_TILING_LINEAR;
    image_info.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkImage vk_image = VK_NULL_HANDLE;
    res = p_CreateImage(vk_device, &image_info, nullptr, &vk_image);
    if (res != VK_SUCCESS) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: vkCreateImage a échoué: ",
            String::num_int64(res));
        close(dup_fd);
        return result;
    }

    // --- Get memory requirements for the image ------------------------
    VkMemoryRequirements mem_reqs = {};
    p_GetImageMemoryRequirements(vk_device, vk_image, &mem_reqs);

    // --- Find compatible memory type ----------------------------------
    uint32_t mem_type = find_memory_type(mem_reqs.memoryTypeBits,
                                         fd_props.memoryTypeBits);
    if (mem_type == UINT32_MAX) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "aucun type de mémoire compatible entre image et dmabuf");
        p_DestroyImage(vk_device, vk_image, nullptr);
        close(dup_fd);
        return result;
    }

    // --- Import DMA-BUF fd as VkDeviceMemory -------------------------
    //     Vulkan takes ownership of dup_fd from here.
    VkImportMemoryFdInfoKHR import_info = {};
    import_info.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR;
    import_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    import_info.fd = dup_fd;

    VkMemoryAllocateInfo alloc_info = {};
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.pNext = &import_info;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = mem_type;

    VkDeviceMemory vk_memory = VK_NULL_HANDLE;
    res = p_AllocateMemory(vk_device, &alloc_info, nullptr, &vk_memory);
    if (res != VK_SUCCESS) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "vkAllocateMemory (import dmabuf) a échoué: ",
            String::num_int64(res));
        p_DestroyImage(vk_device, vk_image, nullptr);
        close(dup_fd); // Ownership NOT transferred on failure
        return result;
    }

    // --- Bind memory to image -----------------------------------------
    res = p_BindImageMemory(vk_device, vk_image, vk_memory, 0);
    if (res != VK_SUCCESS) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "vkBindImageMemory a échoué: ", String::num_int64(res));
        p_FreeMemory(vk_device, vk_memory, nullptr);
        p_DestroyImage(vk_device, vk_image, nullptr);
        return result;
    }

    // --- Create a VkFence for deferred-release synchronization ---------
    //     The fence is created already signaled so that flush_pending()
    //     can safely destroy the resources once the previous frame's GPU
    //     work is guaranteed complete (import_dma_buf calls
    //     vkDeviceWaitIdle before this point).
    VkFence import_fence = VK_NULL_HANDLE;
    if (p_CreateFence) {
        VkFenceCreateInfo fence_info = {};
        fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        VkResult fres = p_CreateFence(vk_device, &fence_info, nullptr, &import_fence);
        if (fres != VK_SUCCESS) {
            UtilityFunctions::printerr("waylandgodot: Vulkan: "
                "vkCreateFence a échoué: ", String::num_int64(fres));
            import_fence = VK_NULL_HANDLE;
        }
    }

    // --- Cross-device sync (EGL → Vulkan) ----------------------------
    //     On AMD/Intel with Mesa, implicit sync via the DMA-BUF
    //     reservation object handles cross-device synchronisation.
    //     We do NOT call vkQueueWaitIdle here: it would block the main
    //     thread on Godot's own Vulkan queue and deadlock if Godot's
    //     rendering thread also has pending work on that queue.

    // --- Wrap VkImage in a Godot RID via RenderingDevice --------------
    RID rid = rd->texture_create_from_extension(
        RenderingDevice::TEXTURE_TYPE_2D,
        rd_format,
        RenderingDevice::TEXTURE_SAMPLES_1,
        RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
            RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT,
        reinterpret_cast<uint64_t>(vk_image),
        width, height, 1, 1);

    if (!rid.is_valid()) {
        UtilityFunctions::printerr("waylandgodot: Vulkan: "
            "texture_create_from_extension a échoué");
        p_FreeMemory(vk_device, vk_memory, nullptr);
        p_DestroyImage(vk_device, vk_image, nullptr);
        return result;
    }

    // --- Wrap RID in a Texture2DRD (a Texture2D subclass) ------------
    Ref<Texture2DRD> tex_rd;
    tex_rd.instantiate();
    tex_rd->set_texture_rd_rid(rid);

    result.rid = rid;
    result.texture = tex_rd;
    result.vk_image = vk_image;
    result.vk_memory = vk_memory;
    result.fence = import_fence;

    return result;
}

// =====================================================================
// release_texture — free a previously imported texture
// =====================================================================

void VulkanDmaBufImport::release_texture(VulkanDmaBufTexture &tex) {
    // Defer the destruction: Godot may still reference the RID in
    // in-flight GPU command buffers.  We queue the resources and
    // destroy them once the fence signals (checked non-blockingly in
    // flush_pending).
    if (tex.rid.is_valid() || tex.vk_image != VK_NULL_HANDLE) {
        PendingRelease pr;
        pr.rid = tex.rid;
        pr.vk_image = tex.vk_image;
        pr.vk_memory = tex.vk_memory;
        pr.fence = tex.fence;
        pending.push_back(pr);
        tex.rid = RID();
        tex.vk_image = VK_NULL_HANDLE;
        tex.vk_memory = VK_NULL_HANDLE;
        tex.fence = VK_NULL_HANDLE;
    }
    tex.texture.unref();
}

// =====================================================================
// flush_pending — destroy resources from the previous frame
// =====================================================================

void VulkanDmaBufImport::flush_pending() {
    if (pending.empty()) return;

    // Safety net: if pending grows too large (e.g., fence functions
    // unavailable or fence never signaled), force a full device wait
    // to prevent unbounded memory growth.
    constexpr size_t MAX_PENDING = 16;
    bool force_wait = !p_GetFenceStatus || !p_DestroyFence ||
                      !p_FreeMemory || pending.size() > MAX_PENDING;

    if (force_wait) {
        // Fallback: wait for all GPU work to complete.
        if (p_DeviceWaitIdle) {
            p_DeviceWaitIdle(vk_device);
        }
        for (auto &pr : pending) {
            if (pr.rid.is_valid() && rd) {
                rd->free_rid(pr.rid);
            }
            if (pr.vk_image != VK_NULL_HANDLE && p_DestroyImage) {
                p_DestroyImage(vk_device, pr.vk_image, nullptr);
            }
            if (pr.vk_memory != VK_NULL_HANDLE && p_FreeMemory) {
                p_FreeMemory(vk_device, pr.vk_memory, nullptr);
            }
            if (pr.fence != VK_NULL_HANDLE && p_DestroyFence) {
                p_DestroyFence(vk_device, pr.fence, nullptr);
            }
        }
        pending.clear();
        return;
    }

    // Fast path: check each fence non-blockingly.  Resources whose
    // fence has signaled are safe to destroy immediately.  The rest
    // stay in `pending` for the next frame.
    size_t dst = 0;
    for (size_t src = 0; src < pending.size(); ++src) {
        auto &pr = pending[src];
        bool ready = true;

        if (pr.fence != VK_NULL_HANDLE) {
            VkResult fres = p_GetFenceStatus(vk_device, pr.fence);
            ready = (fres == VK_SUCCESS);
        }

        if (ready) {
            if (pr.rid.is_valid() && rd) {
                rd->free_rid(pr.rid);
            }
            if (pr.vk_image != VK_NULL_HANDLE && p_DestroyImage) {
                p_DestroyImage(vk_device, pr.vk_image, nullptr);
            }
            if (pr.vk_memory != VK_NULL_HANDLE && p_FreeMemory) {
                p_FreeMemory(vk_device, pr.vk_memory, nullptr);
            }
            if (pr.fence != VK_NULL_HANDLE && p_DestroyFence) {
                p_DestroyFence(vk_device, pr.fence, nullptr);
            }
        } else {
            // Not ready yet — keep in pending.
            if (dst != src) {
                pending[dst] = std::move(pr);
            }
            ++dst;
        }
    }
    pending.resize(dst);
}

// =====================================================================
// cleanup — release all state (called at extension shutdown)
// =====================================================================

void VulkanDmaBufImport::cleanup() {
    available = false;

    // Destroy any remaining pending resources (including fences).
    for (auto &pr : pending) {
        if (pr.rid.is_valid() && rd) {
            rd->free_rid(pr.rid);
        }
        if (pr.vk_image != VK_NULL_HANDLE && p_DestroyImage) {
            p_DestroyImage(vk_device, pr.vk_image, nullptr);
        }
        if (pr.vk_memory != VK_NULL_HANDLE && p_FreeMemory) {
            p_FreeMemory(vk_device, pr.vk_memory, nullptr);
        }
        if (pr.fence != VK_NULL_HANDLE && p_DestroyFence) {
            p_DestroyFence(vk_device, pr.fence, nullptr);
        }
    }
    pending.clear();

    // We do NOT own vk_device / vk_instance — Godot does.
    vk_instance = VK_NULL_HANDLE;
    vk_physical_device = VK_NULL_HANDLE;
    vk_device = VK_NULL_HANDLE;
    vk_queue = VK_NULL_HANDLE;
    p_vkGetInstanceProcAddr = nullptr;
    p_vkGetDeviceProcAddr = nullptr;
    p_GetPhysicalDeviceMemoryProperties = nullptr;
    p_CreateImage = nullptr;
    p_DestroyImage = nullptr;
    p_GetImageMemoryRequirements = nullptr;
    p_AllocateMemory = nullptr;
    p_FreeMemory = nullptr;
    p_BindImageMemory = nullptr;
    p_QueueWaitIdle = nullptr;
    p_DeviceWaitIdle = nullptr;
    p_CreateFence = nullptr;
    p_DestroyFence = nullptr;
    p_GetFenceStatus = nullptr;
    p_ResetFences = nullptr;
    p_QueueSubmit = nullptr;
    p_GetMemoryFdPropertiesKHR = nullptr;
    rd = nullptr;
}
