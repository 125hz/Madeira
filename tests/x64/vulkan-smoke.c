/* Windows Vulkan API end-to-end tests. No native Metal calls or stub fallback.
 * Build once normally (M1), once with -DVULKAN_CLEAR_TEST (M2).
 * SPDX-License-Identifier: MIT
 */
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FUNCTIONS(X) \
 X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) \
 X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceFeatures) \
 X(vkEnumerateDeviceExtensionProperties) X(vkEnumerateInstanceExtensionProperties) \
 X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) \
 X(vkGetPhysicalDeviceFormatProperties) X(vkCreateDevice) X(vkDestroyDevice) \
 X(vkGetDeviceQueue) X(vkCreateImage) X(vkDestroyImage) X(vkGetImageMemoryRequirements) \
 X(vkAllocateMemory) X(vkFreeMemory) X(vkBindImageMemory) X(vkCreateBuffer) \
 X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkBindBufferMemory) \
 X(vkMapMemory) X(vkUnmapMemory) X(vkInvalidateMappedMemoryRanges) X(vkFlushMappedMemoryRanges) \
 X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
 X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCmdPipelineBarrier) \
 X(vkCmdClearColorImage) X(vkCmdCopyImageToBuffer) X(vkCreateFence) \
 X(vkDestroyFence) X(vkQueueSubmit) X(vkWaitForFences)
#define DECLARE(n) static PFN_##n p_##n;
FUNCTIONS(DECLARE)
#undef DECLARE

static int extensions(VkPhysicalDevice physical, int *portability)
{
    uint32_t count = 0;
    VkResult result;
    VkExtensionProperties *props = NULL;
    do
    {
        free(props); props = NULL; count = 0;
        result = physical ? p_vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL)
                          : p_vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
        if (result != VK_SUCCESS || count > 16384) return 1;
        if (!count) break;
        props = calloc(count, sizeof(*props));
        if (!props) return 1;
        result = physical ? p_vkEnumerateDeviceExtensionProperties(physical, NULL, &count, props)
                          : p_vkEnumerateInstanceExtensionProperties(NULL, &count, props);
    } while (result == VK_INCOMPLETE);
    if (result != VK_SUCCESS) { free(props); return 1; }
    for (uint32_t i = 0; i < count; i++)
    {
        printf("[vk-test] %s-extension %s version=%u\n", physical ? "device" : "instance",
               props[i].extensionName, props[i].specVersion);
        if (portability && !strcmp(props[i].extensionName, "VK_KHR_portability_subset")) *portability = 1;
    }
    free(props);
    return 0;
}

#ifdef VULKAN_CLEAR_TEST
static uint32_t memory_type(const VkPhysicalDeviceMemoryProperties *props, uint32_t bits, VkMemoryPropertyFlags flags)
{
    for (uint32_t i = 0; i < props->memoryTypeCount; i++)
        if ((bits & (1u << i)) && (props->memoryTypes[i].propertyFlags & flags) == flags) return i;
    return UINT32_MAX;
}

static int clear_readback(VkPhysicalDevice physical, int portability)
{
    enum { WIDTH = 16, HEIGHT = 16, BYTES = WIDTH * HEIGHT * 4 };
    int failed = 1, mapped = 0, submitted = 0, completed = 0;
    VkDevice device = VK_NULL_HANDLE;
    VkImage image = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE, buffer_memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    void *bytes = NULL;
    uint32_t family_count = 0, family = UINT32_MAX;
    VkQueueFamilyProperties *families = NULL;
    VkPhysicalDeviceMemoryProperties memory;
    VkMemoryRequirements requirements;
    VkFormatProperties format;
    VkCommandBuffer cmd;
    VkQueue queue;
    VkResult result;
    float priority = 1.0f;
    const char *device_extensions[] = {"VK_KHR_portability_subset"};
#define CHECK(call) do { result = (call); printf("[vk-test] %s result=%d\n", #call, result); \
    if (result != VK_SUCCESS) goto done; } while (0)

    p_vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, &format);
    if ((format.optimalTilingFeatures & (VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT))
        != (VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT))
    { puts("[vk-test] M2 FAIL: RGBA8 optimal image transfer unsupported"); goto done; }
    p_vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, NULL);
    if (!family_count || family_count > 1024) goto done;
    families = calloc(family_count, sizeof(*families));
    if (!families) goto done;
    p_vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families);
    for (uint32_t i = 0; i < family_count; i++)
        if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family = i; break; }
    free(families); families = NULL;
    if (family == UINT32_MAX) goto done;
    VkDeviceQueueCreateInfo qinfo = {.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex=family, .queueCount=1, .pQueuePriorities=&priority};
    VkDeviceCreateInfo dinfo = {.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount=1, .pQueueCreateInfos=&qinfo,
        .enabledExtensionCount=portability ? 1 : 0, .ppEnabledExtensionNames=device_extensions};
    CHECK(p_vkCreateDevice(physical, &dinfo, NULL, &device));
    p_vkGetDeviceQueue(device, family, 0, &queue);
    p_vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    VkImageCreateInfo image_info = {.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType=VK_IMAGE_TYPE_2D, .format=VK_FORMAT_R8G8B8A8_UNORM,
        .extent={WIDTH,HEIGHT,1}, .mipLevels=1, .arrayLayers=1, .samples=VK_SAMPLE_COUNT_1_BIT,
        .tiling=VK_IMAGE_TILING_OPTIMAL, .usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode=VK_SHARING_MODE_EXCLUSIVE, .initialLayout=VK_IMAGE_LAYOUT_UNDEFINED};
    CHECK(p_vkCreateImage(device, &image_info, NULL, &image));
    p_vkGetImageMemoryRequirements(device, image, &requirements);
    uint32_t index = memory_type(&memory, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (index == UINT32_MAX) index = memory_type(&memory, requirements.memoryTypeBits, 0);
    if (index == UINT32_MAX) goto done;
    VkMemoryAllocateInfo alloc = {.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize=requirements.size, .memoryTypeIndex=index};
    CHECK(p_vkAllocateMemory(device, &alloc, NULL, &image_memory));
    CHECK(p_vkBindImageMemory(device, image, image_memory, 0));
    VkBufferCreateInfo buffer_info = {.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size=BYTES, .usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode=VK_SHARING_MODE_EXCLUSIVE};
    CHECK(p_vkCreateBuffer(device, &buffer_info, NULL, &buffer));
    p_vkGetBufferMemoryRequirements(device, buffer, &requirements);
    index = memory_type(&memory, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (index == UINT32_MAX) index = memory_type(&memory, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (index == UINT32_MAX) goto done;
    alloc.allocationSize = requirements.size; alloc.memoryTypeIndex = index;
    CHECK(p_vkAllocateMemory(device, &alloc, NULL, &buffer_memory));
    CHECK(p_vkBindBufferMemory(device, buffer, buffer_memory, 0));
    CHECK(p_vkMapMemory(device, buffer_memory, 0, VK_WHOLE_SIZE, 0, &bytes));
    mapped = 1;
    memset(bytes, 0x5a, BYTES); /* Readback cannot pass by observing untouched CPU bytes. */
    VkMappedMemoryRange range = {.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
        .memory=buffer_memory, .offset=0, .size=VK_WHOLE_SIZE};
    CHECK(p_vkFlushMappedMemoryRanges(device, 1, &range));
    VkCommandPoolCreateInfo pool_info = {.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex=family};
    CHECK(p_vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo cmd_info = {.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool=pool, .level=VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount=1};
    CHECK(p_vkAllocateCommandBuffers(device, &cmd_info, &cmd));
    VkCommandBufferBeginInfo begin = {.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    CHECK(p_vkBeginCommandBuffer(cmd, &begin));
    VkImageSubresourceRange subresource = {VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
    VkImageMemoryBarrier barrier = {.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout=VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED, .image=image, .subresourceRange=subresource};
    p_vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    VkClearColorValue color = {.float32={1.0f,0.0f,1.0f,1.0f}};
    p_vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &subresource);
    barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    p_vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);
    VkBufferImageCopy copy = {.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1}, .imageExtent={WIDTH,HEIGHT,1}};
    p_vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    VkBufferMemoryBarrier readback = {.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask=VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
        .buffer=buffer, .offset=0, .size=VK_WHOLE_SIZE};
    p_vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
        0, 0, NULL, 1, &readback, 0, NULL);
    CHECK(p_vkEndCommandBuffer(cmd));
    VkFenceCreateInfo fence_info = {.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    CHECK(p_vkCreateFence(device, &fence_info, NULL, &fence));
    VkSubmitInfo submit = {.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount=1, .pCommandBuffers=&cmd};
    CHECK(p_vkQueueSubmit(queue, 1, &submit, fence));
    submitted = 1;
    CHECK(p_vkWaitForFences(device, 1, &fence, VK_TRUE, 10000000000ull));
    completed = 1;
    CHECK(p_vkInvalidateMappedMemoryRanges(device, 1, &range));
    unsigned mismatches = 0;
    uint64_t hash = 14695981039346656037ull;
    const unsigned char expected[] = {255,0,255,255};
    for (unsigned i = 0; i < BYTES; i++)
    {
        unsigned char value = ((const unsigned char *)bytes)[i];
        if (value != expected[i % 4]) mismatches++;
        hash = (hash ^ value) * 1099511628211ull;
    }
    printf("[vk-test] M2 %s bytes=%u dimensions=%ux%u first=%02x%02x%02x%02x mismatches=%u fnv64=%016llx\n",
        mismatches ? "FAIL" : "PASS", BYTES, WIDTH, HEIGHT,
        ((unsigned char *)bytes)[0],((unsigned char *)bytes)[1],((unsigned char *)bytes)[2],((unsigned char *)bytes)[3],
        mismatches, (unsigned long long)hash);
    failed = mismatches != 0;
done:
    free(families);
    if (submitted && !completed)
    {
        puts("[vk-test] M2 FAIL: GPU completion unproven; restart Madeira before another run");
        return 2; /* Do not destroy objects that the GPU may still be using. */
    }
    if (device)
    {
        if (fence) p_vkDestroyFence(device,fence,NULL);
        if (pool) p_vkDestroyCommandPool(device,pool,NULL);
        if (mapped) p_vkUnmapMemory(device,buffer_memory);
        if (buffer) p_vkDestroyBuffer(device,buffer,NULL);
        if (image) p_vkDestroyImage(device,image,NULL);
        if (buffer_memory) p_vkFreeMemory(device,buffer_memory,NULL);
        if (image_memory) p_vkFreeMemory(device,image_memory,NULL);
        p_vkDestroyDevice(device,NULL);
    }
    return failed;
#undef CHECK
}
#endif

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[vk-test] Windows x64 Vulkan %s begin build=milestones-1\n",
#ifdef VULKAN_CLEAR_TEST
        "clear/readback"
#else
        "enumeration"
#endif
    );
    HMODULE loader = LoadLibraryA("vulkan-1.dll");
    if (!loader) { printf("[vk-test] FAIL LoadLibrary error=%lu\n",GetLastError()); return 1; }
    char path[2048];
    if (GetModuleFileNameA(loader,path,sizeof(path))) printf("[vk-test] loader=%s\n",path);
#define LOAD(n) p_##n=(PFN_##n)(void *)GetProcAddress(loader,#n); \
    if (!p_##n) { printf("[vk-test] FAIL missing export %s\n",#n); return 1; }
    FUNCTIONS(LOAD)
#undef LOAD
    if (extensions(VK_NULL_HANDLE, NULL)) return 1;
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName="Madeira Vulkan milestone", .apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo info={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo=&app};
    VkInstance instance=VK_NULL_HANDLE;
    VkResult result=p_vkCreateInstance(&info,NULL,&instance);
    printf("[vk-test] vkCreateInstance result=%d instance=%p\n",result,(void *)instance);
    if (result!=VK_SUCCESS) return 1;
    uint32_t count=0;
    result=p_vkEnumeratePhysicalDevices(instance,&count,NULL);
    printf("[vk-test] vkEnumeratePhysicalDevices(count) result=%d count=%u\n",result,count);
    if (result!=VK_SUCCESS || !count || count>1024) { p_vkDestroyInstance(instance,NULL); return 1; }
    VkPhysicalDevice *devices=calloc(count,sizeof(*devices));
    if (!devices) { p_vkDestroyInstance(instance,NULL); return 1; }
    result=p_vkEnumeratePhysicalDevices(instance,&count,devices);
    printf("[vk-test] vkEnumeratePhysicalDevices(list) result=%d count=%u\n",result,count);
    int failed=result!=VK_SUCCESS || !count, portability=0;
    if (!failed) for (uint32_t i=0;i<count;i++)
    {
        VkPhysicalDeviceProperties props;
        VkPhysicalDeviceFeatures features;
        p_vkGetPhysicalDeviceProperties(devices[i],&props);
        p_vkGetPhysicalDeviceFeatures(devices[i],&features);
        printf("[vk-test] GPU[%u] name=\"%s\" vendor=%#x device=%#x type=%u api=%u.%u.%u\n",
            i,props.deviceName,props.vendorID,props.deviceID,props.deviceType,
            VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion),VK_VERSION_PATCH(props.apiVersion));
        printf("[vk-test] core-feature robustBufferAccess=%u\n",features.robustBufferAccess);
        printf("[vk-test] core-feature fullDrawIndexUint32=%u\n",features.fullDrawIndexUint32);
        printf("[vk-test] core-feature imageCubeArray=%u\n",features.imageCubeArray);
        printf("[vk-test] core-feature independentBlend=%u\n",features.independentBlend);
        printf("[vk-test] core-feature geometryShader=%u\n",features.geometryShader);
        printf("[vk-test] core-feature tessellationShader=%u\n",features.tessellationShader);
        printf("[vk-test] core-feature sampleRateShading=%u\n",features.sampleRateShading);
        printf("[vk-test] core-feature dualSrcBlend=%u\n",features.dualSrcBlend);
        printf("[vk-test] core-feature logicOp=%u\n",features.logicOp);
        printf("[vk-test] core-feature multiDrawIndirect=%u\n",features.multiDrawIndirect);
        printf("[vk-test] core-feature drawIndirectFirstInstance=%u\n",features.drawIndirectFirstInstance);
        printf("[vk-test] core-feature depthClamp=%u\n",features.depthClamp);
        printf("[vk-test] core-feature depthBiasClamp=%u\n",features.depthBiasClamp);
        printf("[vk-test] core-feature fillModeNonSolid=%u\n",features.fillModeNonSolid);
        printf("[vk-test] core-feature depthBounds=%u\n",features.depthBounds);
        printf("[vk-test] core-feature wideLines=%u\n",features.wideLines);
        printf("[vk-test] core-feature largePoints=%u\n",features.largePoints);
        printf("[vk-test] core-feature alphaToOne=%u\n",features.alphaToOne);
        printf("[vk-test] core-feature multiViewport=%u\n",features.multiViewport);
        printf("[vk-test] core-feature samplerAnisotropy=%u\n",features.samplerAnisotropy);
        printf("[vk-test] core-feature textureCompressionETC2=%u\n",features.textureCompressionETC2);
        printf("[vk-test] core-feature textureCompressionASTC_LDR=%u\n",features.textureCompressionASTC_LDR);
        printf("[vk-test] core-feature textureCompressionBC=%u\n",features.textureCompressionBC);
        printf("[vk-test] core-feature occlusionQueryPrecise=%u\n",features.occlusionQueryPrecise);
        printf("[vk-test] core-feature pipelineStatisticsQuery=%u\n",features.pipelineStatisticsQuery);
        printf("[vk-test] core-feature vertexPipelineStoresAndAtomics=%u\n",features.vertexPipelineStoresAndAtomics);
        printf("[vk-test] core-feature fragmentStoresAndAtomics=%u\n",features.fragmentStoresAndAtomics);
        printf("[vk-test] core-feature shaderTessellationAndGeometryPointSize=%u\n",features.shaderTessellationAndGeometryPointSize);
        printf("[vk-test] core-feature shaderImageGatherExtended=%u\n",features.shaderImageGatherExtended);
        printf("[vk-test] core-feature shaderStorageImageExtendedFormats=%u\n",features.shaderStorageImageExtendedFormats);
        printf("[vk-test] core-feature shaderStorageImageMultisample=%u\n",features.shaderStorageImageMultisample);
        printf("[vk-test] core-feature shaderStorageImageReadWithoutFormat=%u\n",features.shaderStorageImageReadWithoutFormat);
        printf("[vk-test] core-feature shaderStorageImageWriteWithoutFormat=%u\n",features.shaderStorageImageWriteWithoutFormat);
        printf("[vk-test] core-feature shaderUniformBufferArrayDynamicIndexing=%u\n",features.shaderUniformBufferArrayDynamicIndexing);
        printf("[vk-test] core-feature shaderSampledImageArrayDynamicIndexing=%u\n",features.shaderSampledImageArrayDynamicIndexing);
        printf("[vk-test] core-feature shaderStorageBufferArrayDynamicIndexing=%u\n",features.shaderStorageBufferArrayDynamicIndexing);
        printf("[vk-test] core-feature shaderStorageImageArrayDynamicIndexing=%u\n",features.shaderStorageImageArrayDynamicIndexing);
        printf("[vk-test] core-feature shaderClipDistance=%u\n",features.shaderClipDistance);
        printf("[vk-test] core-feature shaderCullDistance=%u\n",features.shaderCullDistance);
        printf("[vk-test] core-feature shaderFloat64=%u\n",features.shaderFloat64);
        printf("[vk-test] core-feature shaderInt64=%u\n",features.shaderInt64);
        printf("[vk-test] core-feature shaderInt16=%u\n",features.shaderInt16);
        printf("[vk-test] core-feature shaderResourceResidency=%u\n",features.shaderResourceResidency);
        printf("[vk-test] core-feature shaderResourceMinLod=%u\n",features.shaderResourceMinLod);
        printf("[vk-test] core-feature sparseBinding=%u\n",features.sparseBinding);
        printf("[vk-test] core-feature sparseResidencyBuffer=%u\n",features.sparseResidencyBuffer);
        printf("[vk-test] core-feature sparseResidencyImage2D=%u\n",features.sparseResidencyImage2D);
        printf("[vk-test] core-feature sparseResidencyImage3D=%u\n",features.sparseResidencyImage3D);
        printf("[vk-test] core-feature sparseResidency2Samples=%u\n",features.sparseResidency2Samples);
        printf("[vk-test] core-feature sparseResidency4Samples=%u\n",features.sparseResidency4Samples);
        printf("[vk-test] core-feature sparseResidency8Samples=%u\n",features.sparseResidency8Samples);
        printf("[vk-test] core-feature sparseResidency16Samples=%u\n",features.sparseResidency16Samples);
        printf("[vk-test] core-feature sparseResidencyAliased=%u\n",features.sparseResidencyAliased);
        printf("[vk-test] core-feature variableMultisampleRate=%u\n",features.variableMultisampleRate);
        printf("[vk-test] core-feature inheritedQueries=%u\n",features.inheritedQueries);
        puts("[vk-test] feature-scope=Vulkan 1.0 core; extended pNext features not assessed");
        int subset=0;
        if (extensions(devices[i],&subset)) failed=1;
        if (!i) portability=subset;
    }
    if (!failed) puts("[vk-test] M1 API PASS (compare GPU identity with native host log)");
#ifdef VULKAN_CLEAR_TEST
    if (!failed) failed=clear_readback(devices[0],portability);
    if (failed==2)
    {
        puts("[vk-test] END failed=1 GPU completion unproven; instance kept alive until app restart");
        free(devices);
        return 1;
    }
#else
    (void)portability;
#endif
    free(devices);
    p_vkDestroyInstance(instance,NULL);
    FreeLibrary(loader);
    printf("[vk-test] END failed=%d\n",failed);
    return failed;
}
