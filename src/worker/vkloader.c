/*
 * vkloader.c — the ONLY three Vulkan symbols the ggml-vulkan backend calls directly instead of
 * through its dynamic dispatcher (VULKAN_HPP_DISPATCH_LOADER_DYNAMIC). We define them ourselves,
 * each forwarding to a Vulkan loader we dlopen LAZILY on first use — so the shipped binary has NO
 * load-time dependency on the Vulkan runtime. A machine with no GPU, or no loader installed at all
 * (a headless VM, a minimal container), still STARTS normally; the loader is only touched when the
 * engine probes for a device, and if it is absent vkGetInstanceProcAddr returns NULL, device
 * enumeration finds nothing, and the engine's fit ladder falls to the CPU path. This is what makes
 * "one binary, runs on any system" true for the GPU tier: link nothing, require nothing, degrade
 * cleanly. Compiled only in -Dvulkan builds (build.zig addVulkan).
 */
#include <vulkan/vulkan.h>
#include <string.h>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
static void * vk_dlopen(void) {
    /* vulkan-1.dll ships with every GPU driver and with the OS itself on modern Windows; absent
     * only on a truly graphics-less install, where NULL is the correct "no Vulkan here". */
    return (void *) LoadLibraryA("vulkan-1.dll");
}
static void * vk_dlsym(void * h, const char * name) {
    return (void *) GetProcAddress((HMODULE) h, name);
}
#else
#  include <dlfcn.h>
static void * vk_dlopen(void) {
    void * h = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) h = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    return h;
}
static void * vk_dlsym(void * h, const char * name) {
    return dlsym(h, name);
}
#endif

/* The bootstrap: resolve the loader's own vkGetInstanceProcAddr once. NULL (no loader on the box)
 * is cached as "tried and failed" via a separate flag so we never re-dlopen on every probe. We also
 * CAPTURE the instance the backend passes through us: instance-level functions cannot be resolved
 * with a NULL instance, and the backend creates its instance before it ever calls the two direct
 * functions below, so the last non-NULL instance seen is exactly the handle they need. */
static PFN_vkGetInstanceProcAddr veil_real_gipa = NULL;
static int veil_vk_tried = 0;
static VkInstance veil_instance = VK_NULL_HANDLE;

static PFN_vkGetInstanceProcAddr veil_boot(void) {
    if (!veil_vk_tried) {
        veil_vk_tried = 1;
        void * h = vk_dlopen();
        if (h) veil_real_gipa = (PFN_vkGetInstanceProcAddr) vk_dlsym(h, "vkGetInstanceProcAddr");
    }
    return veil_real_gipa;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char * pName) {
    if (instance != VK_NULL_HANDLE) veil_instance = instance;
    PFN_vkGetInstanceProcAddr gipa = veil_boot();
    if (!gipa) return NULL;
    return gipa(instance, pName);
}

/* The two calls ggml-vulkan makes as raw C. Each caches its resolved pointer (copyBuffer is on the
 * buffer-setup path, not per-token, so a one-time resolve is free), routed through the captured
 * instance so the loader trampolines to the right device. */
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice, VkPhysicalDeviceFeatures2 * pFeatures) {
    static PFN_vkGetPhysicalDeviceFeatures2 pfn = NULL;
    if (!pfn) {
        PFN_vkGetInstanceProcAddr gipa = veil_boot();
        if (gipa) pfn = (PFN_vkGetPhysicalDeviceFeatures2) gipa(veil_instance, "vkGetPhysicalDeviceFeatures2");
    }
    if (pfn) pfn(physicalDevice, pFeatures);
    else if (pFeatures) memset(&pFeatures->features, 0, sizeof(pFeatures->features));
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer commandBuffer, VkBuffer srcBuffer, VkBuffer dstBuffer, uint32_t regionCount, const VkBufferCopy * pRegions) {
    static PFN_vkCmdCopyBuffer pfn = NULL;
    if (!pfn) {
        PFN_vkGetInstanceProcAddr gipa = veil_boot();
        if (gipa) pfn = (PFN_vkCmdCopyBuffer) gipa(veil_instance, "vkCmdCopyBuffer");
    }
    if (pfn) pfn(commandBuffer, srcBuffer, dstBuffer, regionCount, pRegions);
}
