#pragma once

#include <vulkan/vulkan.h>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <vector>

namespace godot {

// Holds all Vulkan resources for a single DMA-BUF-imported texture.
// Must be released via VulkanDmaBufImport::release_texture() before
// the backing wlr_buffer is destroyed.
struct VulkanDmaBufTexture {
    RID rid;
    Ref<Texture2DRD> texture;
    VkImage vk_image = VK_NULL_HANDLE;
    VkDeviceMemory vk_memory = VK_NULL_HANDLE;
};

// Holds deferred-release resources that must not be destroyed yet
// because Godot may still reference them in in-flight GPU commands.
struct PendingRelease {
    RID rid;
    VkImage vk_image = VK_NULL_HANDLE;
    VkDeviceMemory vk_memory = VK_NULL_HANDLE;
};

// Imports DMA-BUF file descriptors into Godot's Vulkan renderer as
// texture RIDs, enabling zero-copy GPU→GPU transfer from the wlroots
// compositor to Godot's rendering pipeline.
//
// The flow is:
//   1. wlroots renders a Wayland surface into a DMA-BUF offscreen buffer
//      (GPU, via EGL/GLES2).
//   2. This class imports the DMA-BUF fd into Vulkan as a VkImage, using
//      VK_KHR_external_memory_fd.
//   3. The VkImage is wrapped in a Godot RID via
//      RenderingDevice::texture_create_from_extension, then in a
//      Texture2DRD which can be used as a standard Texture2D in the scene.
//
// Falls back gracefully: is_available() returns false if the Vulkan device
// or extension is not supported, and import_dma_buf() returns a failed
// VulkanDmaBufTexture on any runtime error.
class VulkanDmaBufImport {
    bool available = false;

    // Vulkan handles obtained from Godot's RenderingDevice.
    // We do NOT own these — Godot manages their lifetime.
    VkInstance vk_instance = VK_NULL_HANDLE;
    VkPhysicalDevice vk_physical_device = VK_NULL_HANDLE;
    VkDevice vk_device = VK_NULL_HANDLE;
    VkQueue vk_queue = VK_NULL_HANDLE;

    // Function pointers loaded via dlopen/dlsym + vkGetDeviceProcAddr.
    PFN_vkGetInstanceProcAddr p_vkGetInstanceProcAddr = nullptr;
    PFN_vkGetDeviceProcAddr p_vkGetDeviceProcAddr = nullptr;

    // Instance-level.
    PFN_vkGetPhysicalDeviceMemoryProperties p_GetPhysicalDeviceMemoryProperties = nullptr;

    // Device-level (core).
    PFN_vkCreateImage p_CreateImage = nullptr;
    PFN_vkDestroyImage p_DestroyImage = nullptr;
    PFN_vkGetImageMemoryRequirements p_GetImageMemoryRequirements = nullptr;
    PFN_vkAllocateMemory p_AllocateMemory = nullptr;
    PFN_vkFreeMemory p_FreeMemory = nullptr;
    PFN_vkBindImageMemory p_BindImageMemory = nullptr;
    PFN_vkQueueWaitIdle p_QueueWaitIdle = nullptr;
    PFN_vkDeviceWaitIdle p_DeviceWaitIdle = nullptr;

    // Extension: VK_KHR_external_memory_fd.
    PFN_vkGetMemoryFdPropertiesKHR p_GetMemoryFdPropertiesKHR = nullptr;

    VkPhysicalDeviceMemoryProperties mem_properties = {};

    RenderingDevice *rd = nullptr;

    // Resources awaiting deferred destruction (one frame behind).
    std::vector<PendingRelease> pending;

    bool load_function_pointers();
    uint32_t find_memory_type(uint32_t type_bits, uint32_t fd_type_bits);

public:
    // Call once after Godot's RenderingDevice is ready. Returns true if
    // VK_KHR_external_memory_fd is available and all function pointers
    // loaded.
    bool initialize(RenderingDevice *p_rd);

    bool is_available() const { return available; }

    // Import a single-plane DMA-BUF fd into Vulkan and wrap it in a
    // Godot Texture2DRD.  Vulkan takes ownership of a dup() of `fd`.
    // Returns a VulkanDmaBufTexture with vk_image == VK_NULL_HANDLE on
    // failure.
    VulkanDmaBufTexture import_dma_buf(int fd, uint32_t width,
                                       uint32_t height, uint32_t drm_format);

    // Release a previously imported texture (RID + VkImage + VkDeviceMemory).
    // Safe to call with a failed/empty VulkanDmaBufTexture.
    // Resources are queued for deferred destruction (one frame behind)
    // to avoid stalling the main thread.
    void release_texture(VulkanDmaBufTexture &tex);

    // Actually destroy resources that were queued for deferred release.
    // Call once per frame, ideally at the start of the frame before
    // any new captures.  Calls vkDeviceWaitIdle internally.
    void flush_pending();

    // Release all state.  Call during extension shutdown.
    void cleanup();

    // DRM fourcc → Godot RenderingDevice::DataFormat.
    static uint32_t drm_to_rd_format(uint32_t drm_format);
};

} // namespace godot
