/* Static MoltenVK entry points for Wine's iOS Unix side.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * No handles, extensions, features or results are synthesized here.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static VkResult VKAPI_CALL create_instance(const VkInstanceCreateInfo *info,
        const VkAllocationCallbacks *allocator, VkInstance *instance)
{
    fprintf(stderr, "[vk-host] -> MoltenVK vkCreateInstance api=%#x\n",
            info && info->pApplicationInfo ? info->pApplicationInfo->apiVersion : 0);
    VkResult result = vkCreateInstance(info, allocator, instance);
    fprintf(stderr, "[vk-host] <- MoltenVK vkCreateInstance result=%d instance=%p\n",
            result, result == VK_SUCCESS ? (void *)*instance : NULL);
    return result;
}

static VkResult VKAPI_CALL enumerate_devices(VkInstance instance, uint32_t *count,
        VkPhysicalDevice *devices)
{
    VkResult result = vkEnumeratePhysicalDevices(instance, count, devices);
    fprintf(stderr, "[vk-host] MoltenVK vkEnumeratePhysicalDevices result=%d count=%u list=%d\n",
            result, (result == VK_SUCCESS || result == VK_INCOMPLETE) ? *count : 0, devices != NULL);
    if (devices && (result == VK_SUCCESS || result == VK_INCOMPLETE))
        for (uint32_t i = 0; i < *count; i++)
        {
            VkPhysicalDeviceProperties props;
            vkGetPhysicalDeviceProperties(devices[i], &props);
            fprintf(stderr, "[vk-host] physical-device[%u] name=\"%s\" vendor=%#x device=%#x api=%#x type=%u\n",
                    i, props.deviceName, props.vendorID, props.deviceID, props.apiVersion, props.deviceType);
        }
    return result;
}

static VkResult VKAPI_CALL create_device(VkPhysicalDevice physical, const VkDeviceCreateInfo *info,
        const VkAllocationCallbacks *allocator, VkDevice *device)
{
    /* Wine's generated client extension set does not expose portability_subset.
     * Honor the native driver's mandatory extension without changing guest
     * capabilities or enabling optional feature bits. VUID-pProperties-04451. */
    const char *subset = "VK_KHR_portability_subset";
    VkExtensionProperties *properties = NULL;
    uint32_t count = 0;
    VkResult result;
    int required = 0, enabled = 0;
    do
    {
        free(properties); properties = NULL;
        result = vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL);
        if (result != VK_SUCCESS) return result;
        if (!count) break;
        properties = calloc(count, sizeof(*properties));
        if (!properties) return VK_ERROR_OUT_OF_HOST_MEMORY;
        result = vkEnumerateDeviceExtensionProperties(physical, NULL, &count, properties);
    } while (result == VK_INCOMPLETE);
    if (result != VK_SUCCESS) { free(properties); return result; }
    for (uint32_t i = 0; i < count; i++)
        if (!strcmp(properties[i].extensionName, subset)) required = 1;
    free(properties);
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++)
        if (!strcmp(info->ppEnabledExtensionNames[i], subset)) enabled = 1;
    VkDeviceCreateInfo host = *info;
    const char **extensions = NULL;
    if (required && !enabled)
    {
        if (info->enabledExtensionCount == UINT32_MAX) return VK_ERROR_OUT_OF_HOST_MEMORY;
        extensions = calloc((size_t)info->enabledExtensionCount + 1, sizeof(*extensions));
        if (!extensions) return VK_ERROR_OUT_OF_HOST_MEMORY;
        for (uint32_t i = 0; i < info->enabledExtensionCount; i++) extensions[i] = info->ppEnabledExtensionNames[i];
        extensions[info->enabledExtensionCount] = subset;
        host.enabledExtensionCount++;
        host.ppEnabledExtensionNames = extensions;
        fprintf(stderr, "[vk-host] enabling native-required VK_KHR_portability_subset (no feature bits added)\n");
    }
    result = vkCreateDevice(physical, &host, allocator, device);
    free(extensions);
    fprintf(stderr, "[vk-host] MoltenVK vkCreateDevice result=%d\n", result);
    return result;
}

static int trace_call(unsigned long *counter)
{
    const char *setting = getenv("MADEIRA_VK_DIAGNOSTICS");
    if (!setting || strcmp(setting, "1")) return 0;
    unsigned long n = __atomic_add_fetch(counter, 1, __ATOMIC_RELAXED);
    return n <= 8 || n % 120 == 0;
}

static void VKAPI_CALL clear_image(VkCommandBuffer cmd, VkImage image, VkImageLayout layout,
        const VkClearColorValue *color, uint32_t count, const VkImageSubresourceRange *ranges)
{
    static unsigned long count_calls;
    if (trace_call(&count_calls))
        fprintf(stderr, "[vk-host] MoltenVK vkCmdClearColorImage (recording, execution not yet proven)\n");
    vkCmdClearColorImage(cmd, image, layout, color, count, ranges);
}

static VkResult VKAPI_CALL queue_submit(VkQueue queue, uint32_t count, const VkSubmitInfo *submits,
        VkFence fence)
{
    VkResult result = vkQueueSubmit(queue, count, submits, fence);
    static unsigned long count_calls;
    if (trace_call(&count_calls) || result < 0)
        fprintf(stderr, "[vk-host] MoltenVK vkQueueSubmit count=%u result=%d\n", count, result);
    return result;
}

static VkResult VKAPI_CALL wait_fences(VkDevice device, uint32_t count, const VkFence *fences,
        VkBool32 all, uint64_t timeout)
{
    VkResult result = vkWaitForFences(device, count, fences, all, timeout);
    static unsigned long count_calls;
    if (trace_call(&count_calls) || result < 0)
        fprintf(stderr, "[vk-host] MoltenVK vkWaitForFences result=%d\n", result);
    return result;
}

static VkResult VKAPI_CALL present_queue(VkQueue queue, const VkPresentInfoKHR *info)
{
    VkResult result = vkQueuePresentKHR(queue, info);
    static unsigned long count;
    if (trace_call(&count) || result < 0)
    {
        fprintf(stderr, "[vk-host] MoltenVK vkQueuePresentKHR count=%u result=%d\n",
                info->swapchainCount, result);
        if (info->pResults)
            for (uint32_t i = 0; i < info->swapchainCount; i++)
                fprintf(stderr, "[vk-host] present swapchain[%u] result=%d\n", i, info->pResults[i]);
    }
    return result;
}

static VkResult VKAPI_CALL create_swapchain(VkDevice device,
        const VkSwapchainCreateInfoKHR *info, const VkAllocationCallbacks *allocator,
        VkSwapchainKHR *swapchain)
{
    VkResult result = vkCreateSwapchainKHR(device, info, allocator, swapchain);
    static unsigned long count;
    if (trace_call(&count) || result < 0)
        fprintf(stderr, "[vk-host] MoltenVK vkCreateSwapchainKHR extent=%ux%u result=%d\n",
                info->imageExtent.width, info->imageExtent.height, result);
    return result;
}

static void log_acquire(const char *name, VkResult result)
{
    static unsigned long count;
    if (trace_call(&count) || result < 0)
        fprintf(stderr, "[vk-host] MoltenVK %s result=%d\n", name, result);
}

static VkResult VKAPI_CALL acquire_image(VkDevice device, VkSwapchainKHR swapchain,
        uint64_t timeout, VkSemaphore semaphore, VkFence fence, uint32_t *index)
{
    VkResult result = vkAcquireNextImageKHR(device, swapchain, timeout, semaphore, fence, index);
    log_acquire("vkAcquireNextImageKHR", result);
    return result;
}

static VkResult VKAPI_CALL acquire_image2(VkDevice device,
        const VkAcquireNextImageInfoKHR *info, uint32_t *index)
{
    VkResult result = vkAcquireNextImage2KHR(device, info, index);
    log_acquire("vkAcquireNextImage2KHR", result);
    return result;
}

static PFN_vkVoidFunction VKAPI_CALL device_proc(VkDevice device, const char *name)
{
    PFN_vkVoidFunction proc = vkGetDeviceProcAddr(device, name);
    if (!proc) return NULL;
    if (!strcmp(name, "vkCreateSwapchainKHR")) return (PFN_vkVoidFunction)create_swapchain;
    if (!strcmp(name, "vkAcquireNextImageKHR")) return (PFN_vkVoidFunction)acquire_image;
    if (!strcmp(name, "vkAcquireNextImage2KHR")) return (PFN_vkVoidFunction)acquire_image2;
    if (!strcmp(name, "vkQueuePresentKHR")) return (PFN_vkVoidFunction)present_queue;
    if (!strcmp(name, "vkCmdClearColorImage")) return (PFN_vkVoidFunction)clear_image;
    if (!strcmp(name, "vkQueueSubmit")) return (PFN_vkVoidFunction)queue_submit;
    if (!strcmp(name, "vkWaitForFences")) return (PFN_vkVoidFunction)wait_fences;
    return proc;
}

static PFN_vkVoidFunction VKAPI_CALL instance_proc(VkInstance instance, const char *name)
{
    PFN_vkVoidFunction proc = vkGetInstanceProcAddr(instance, name);
    if (!proc) return NULL;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)create_instance;
    if (!strcmp(name, "vkEnumeratePhysicalDevices")) return (PFN_vkVoidFunction)enumerate_devices;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)create_device;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)device_proc;
    return proc;
}

void *madeira_vulkan_symbol(const char *name)
{
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (void *)instance_proc;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (void *)device_proc;
    return NULL;
}
