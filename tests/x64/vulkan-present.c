/* Windows Vulkan WSI test: real HWND, swapchain image clears and presentation.
 * No Metal APIs, capability overrides, shaders or game-specific paths.
 * SPDX-License-Identifier: MIT
 */
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#define FUNCTIONS(X) \
 X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) \
 X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceQueueFamilyProperties) \
 X(vkCreateWin32SurfaceKHR) X(vkDestroySurfaceKHR) X(vkGetPhysicalDeviceSurfaceSupportKHR) \
 X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
 X(vkCreateDevice) X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkCreateSwapchainKHR) \
 X(vkDestroySwapchainKHR) X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) \
 X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkResetCommandPool) \
 X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCmdPipelineBarrier) X(vkCmdClearColorImage) \
 X(vkCreateSemaphore) X(vkDestroySemaphore) X(vkCreateFence) X(vkDestroyFence) X(vkResetFences) \
 X(vkQueueSubmit) X(vkWaitForFences) X(vkQueuePresentKHR) X(vkQueueWaitIdle) X(vkDeviceWaitIdle)
#define DECL(n) static PFN_##n p_##n;
FUNCTIONS(DECL)
#undef DECL
#define TRY(call) do { VkResult r_=(call); if(r_!=VK_SUCCESS) { \
 printf("[vk-present-test] FAIL %s result=%d\n",#call,r_);return 1; } } while(0)
static int cancelled;
static LRESULT CALLBACK window_proc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp)
{
    if(msg==WM_CLOSE){cancelled=1;return 0;}
    return DefWindowProcW(hwnd,msg,wp,lp);
}
static void messages(void) { MSG msg;while(PeekMessageW(&msg,NULL,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);} }
static int present_window(VkInstance instance,VkPhysicalDevice physical,unsigned round)
{
    HINSTANCE module=GetModuleHandleW(NULL);
    HWND hwnd=CreateWindowExW(0,L"MadeiraVulkanWSI",round ? L"Vulkan round 2 - larger window" : L"Vulkan round 1",
            WS_OVERLAPPEDWINDOW|WS_VISIBLE,40,40,round?800:640,round?450:360,NULL,NULL,module,NULL);
    if(!hwnd){printf("[vk-present-test] FAIL CreateWindow error=%lu\n",GetLastError());return 1;}
    messages();
    VkSurfaceKHR surface;
    VkWin32SurfaceCreateInfoKHR si={.sType=VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,.hinstance=module,.hwnd=hwnd};
    TRY(p_vkCreateWin32SurfaceKHR(instance,&si,NULL,&surface));
    printf("[vk-present-test] round=%u HWND=%p Win32 surface created\n",round+1,(void *)hwnd);
    uint32_t count=0,family=UINT32_MAX;
    p_vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,NULL);
    if(!count || count>1024)return 1;
    VkQueueFamilyProperties *families=calloc(count,sizeof(*families));if(!families)return 1;
    p_vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,families);
    for(uint32_t i=0;i<count;i++) {
        VkBool32 supported=VK_FALSE;
        TRY(p_vkGetPhysicalDeviceSurfaceSupportKHR(physical,i,surface,&supported));
        if(supported && families[i].queueCount && (families[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)){family=i;break;}
    }
    free(families);
    if(family==UINT32_MAX){puts("[vk-present-test] FAIL no native graphics/present queue");return 1;}
    float priority=1;
    VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
    const char *extension=VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=1,.ppEnabledExtensionNames=&extension};
    VkDevice device;VkQueue queue;
    TRY(p_vkCreateDevice(physical,&di,NULL,&device));p_vkGetDeviceQueue(device,family,0,&queue);
    VkSurfaceCapabilitiesKHR caps;TRY(p_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical,surface,&caps));
    if(!(caps.supportedUsageFlags&VK_IMAGE_USAGE_TRANSFER_DST_BIT)){puts("[vk-present-test] FAIL swapchain image cannot be cleared via transfer");return 1;}
    TRY(p_vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,NULL));
    if(!count || count>1024)return 1;
    VkSurfaceFormatKHR *formats=calloc(count,sizeof(*formats));if(!formats)return 1;
    TRY(p_vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&count,formats));
    VkSurfaceFormatKHR format=formats[0];
    for(uint32_t i=0;i<count;i++)if(formats[i].format==VK_FORMAT_B8G8R8A8_UNORM){format=formats[i];break;}
    free(formats);
    if(format.format==VK_FORMAT_UNDEFINED)format.format=VK_FORMAT_B8G8R8A8_UNORM;
    VkExtent2D extent=caps.currentExtent;
    if(extent.width==UINT32_MAX){RECT rect;GetClientRect(hwnd,&rect);extent.width=rect.right;extent.height=rect.bottom;}
    if(extent.width<caps.minImageExtent.width)extent.width=caps.minImageExtent.width;
    if(extent.height<caps.minImageExtent.height)extent.height=caps.minImageExtent.height;
    if(extent.width>caps.maxImageExtent.width)extent.width=caps.maxImageExtent.width;
    if(extent.height>caps.maxImageExtent.height)extent.height=caps.maxImageExtent.height;
    VkCompositeAlphaFlagBitsKHR alpha=VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if(!(caps.supportedCompositeAlpha&alpha))alpha=(VkCompositeAlphaFlagBitsKHR)(caps.supportedCompositeAlpha&(~caps.supportedCompositeAlpha+1));
    uint32_t images_count=caps.minImageCount+1;
    if(caps.maxImageCount && images_count>caps.maxImageCount)images_count=caps.maxImageCount;
    VkSwapchainCreateInfoKHR sci={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,.surface=surface,
        .minImageCount=images_count,.imageFormat=format.format,.imageColorSpace=format.colorSpace,.imageExtent=extent,
        .imageArrayLayers=1,.imageUsage=VK_IMAGE_USAGE_TRANSFER_DST_BIT,.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE,
        .preTransform=caps.currentTransform,.compositeAlpha=alpha,.presentMode=VK_PRESENT_MODE_FIFO_KHR,.clipped=VK_TRUE};
    VkSwapchainKHR swapchain;TRY(p_vkCreateSwapchainKHR(device,&sci,NULL,&swapchain));
    TRY(p_vkGetSwapchainImagesKHR(device,swapchain,&images_count,NULL));
    if(!images_count || images_count>64)return 1;
    VkImage *images=calloc(images_count,sizeof(*images));if(!images)return 1;
    TRY(p_vkGetSwapchainImagesKHR(device,swapchain,&images_count,images));
    printf("[vk-present-test] swapchain %ux%u images=%u format=%u queue=%u\n",extent.width,extent.height,images_count,format.format,family);
    VkCommandPool pool;VkCommandBuffer cmd;VkFence fence;VkSemaphore available,rendered;
    VkCommandPoolCreateInfo pci={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=family};
    TRY(p_vkCreateCommandPool(device,&pci,NULL,&pool));
    VkCommandBufferAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
    TRY(p_vkAllocateCommandBuffers(device,&ai,&cmd));
    VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};TRY(p_vkCreateFence(device,&fi,NULL,&fence));
    VkSemaphoreCreateInfo sem={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    TRY(p_vkCreateSemaphore(device,&sem,NULL,&available));TRY(p_vkCreateSemaphore(device,&sem,NULL,&rendered));
    const float colors[3][4]={{1,0,0,1},{0,1,0,1},{0,0,1,1}};
    for(unsigned frame=0;frame<180 && !cancelled;frame++) {
        messages();
        uint32_t index;VkResult result=p_vkAcquireNextImageKHR(device,swapchain,10000000000ull,available,VK_NULL_HANDLE,&index);
        if(result!=VK_SUCCESS && result!=VK_SUBOPTIMAL_KHR){printf("[vk-present-test] FAIL acquire result=%d\n",result);return 1;}
        if(index>=images_count)return 1;
        TRY(p_vkResetCommandPool(device,pool,0));
        VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
        TRY(p_vkBeginCommandBuffer(cmd,&begin));
        VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VkImageMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout=VK_IMAGE_LAYOUT_UNDEFINED,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.image=images[index],.subresourceRange=range};
        p_vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&barrier);
        VkClearColorValue color;for(unsigned k=0;k<4;k++)color.float32[k]=colors[frame/60][k];
        p_vkCmdClearColorImage(cmd,images[index],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&color,1,&range);
        barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=0;
        barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;barrier.newLayout=VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        p_vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,NULL,0,NULL,1,&barrier);
        TRY(p_vkEndCommandBuffer(cmd));TRY(p_vkResetFences(device,1,&fence));
        VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.waitSemaphoreCount=1,.pWaitSemaphores=&available,.pWaitDstStageMask=&stage,
            .commandBufferCount=1,.pCommandBuffers=&cmd,.signalSemaphoreCount=1,.pSignalSemaphores=&rendered};
        TRY(p_vkQueueSubmit(queue,1,&submit,fence));TRY(p_vkWaitForFences(device,1,&fence,VK_TRUE,10000000000ull));
        VkResult per_swapchain=VK_SUCCESS;
        VkPresentInfoKHR present={.sType=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,.waitSemaphoreCount=1,.pWaitSemaphores=&rendered,
            .swapchainCount=1,.pSwapchains=&swapchain,.pImageIndices=&index,.pResults=&per_swapchain};
        result=p_vkQueuePresentKHR(queue,&present);
        if((result!=VK_SUCCESS && result!=VK_SUBOPTIMAL_KHR)||(per_swapchain!=VK_SUCCESS && per_swapchain!=VK_SUBOPTIMAL_KHR)) {
            printf("[vk-present-test] FAIL present result=%d per-swapchain=%d\n",result,per_swapchain);return 1;
        }
        TRY(p_vkQueueWaitIdle(queue));
        if(frame%60==0)printf("[vk-present-test] round=%u frame=%u color=%s present=%d per-swapchain=%d (verify visible output)\n",round+1,frame,frame<60?"RED":frame<120?"GREEN":"BLUE",result,per_swapchain);
        Sleep(33);
    }
    TRY(p_vkDeviceWaitIdle(device));
    p_vkDestroySemaphore(device,rendered,NULL);p_vkDestroySemaphore(device,available,NULL);p_vkDestroyFence(device,fence,NULL);
    p_vkDestroyCommandPool(device,pool,NULL);p_vkDestroySwapchainKHR(device,swapchain,NULL);free(images);
    p_vkDestroyDevice(device,NULL);p_vkDestroySurfaceKHR(instance,surface,NULL);DestroyWindow(hwnd);messages();
    printf("[vk-present-test] round=%u cleaned up HWND/surface/swapchain\n",round+1);
    return cancelled?1:0;
}
int main(void)
{
    setvbuf(stdout,NULL,_IONBF,0);puts("[vk-present-test] Windows x64 WSI begin build=metal-surface-1");
    HMODULE loader=LoadLibraryA("vulkan-1.dll");if(!loader)return 1;
#define LOAD(n) p_##n=(PFN_##n)(void *)GetProcAddress(loader,#n);if(!p_##n){puts("[vk-present-test] FAIL missing "#n);return 1;}
    FUNCTIONS(LOAD)
#undef LOAD
    WNDCLASSW wc={.lpfnWndProc=window_proc,.hInstance=GetModuleHandleW(NULL),.lpszClassName=L"MadeiraVulkanWSI"};
    if(!RegisterClassW(&wc))return 1;
    const char *extensions[]={VK_KHR_SURFACE_EXTENSION_NAME,VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Madeira real window Vulkan test",.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.enabledExtensionCount=2,.ppEnabledExtensionNames=extensions};
    VkInstance instance;TRY(p_vkCreateInstance(&ci,NULL,&instance));
    uint32_t count=0;TRY(p_vkEnumeratePhysicalDevices(instance,&count,NULL));if(!count || count>64)return 1;
    VkPhysicalDevice *devices=calloc(count,sizeof(*devices));if(!devices)return 1;
    TRY(p_vkEnumeratePhysicalDevices(instance,&count,devices));
    VkPhysicalDeviceProperties props;p_vkGetPhysicalDeviceProperties(devices[0],&props);
    printf("[vk-present-test] GPU=%s vendor=%#x device=%#x\n",props.deviceName,props.vendorID,props.deviceID);
    for(unsigned round=0;round<2;round++)if(present_window(instance,devices[0],round)){
        puts("[vk-present-test] END FAIL; restart Madeira before another run");return 1;
    }
    free(devices);p_vkDestroyInstance(instance,NULL);FreeLibrary(loader);
    puts("[vk-present-test] API PASS two HWND/surface lifecycles; visible RED/GREEN/BLUE confirmation still required");return 0;
}
