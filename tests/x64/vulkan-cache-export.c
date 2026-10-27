/* Generic Vulkan cache export regression. SPDX-License-Identifier: MIT
 * Exercises direct empty/populated-cache reads, size-query reads and short
 * buffers. Uses valid test shaders only. No game data or fabricated results. */
#ifdef _WIN32
#define VK_NO_PROTOTYPES
#include <windows.h>
#endif
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define VULKAN_FUNCTIONS(X) \
    X(vkCreateInstance) \
    X(vkDestroyInstance) \
    X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkEnumerateDeviceExtensionProperties) \
    X(vkCreateDevice) \
    X(vkDestroyDevice) \
    X(vkCreatePipelineLayout) \
    X(vkDestroyPipelineLayout) \
    X(vkCreateRenderPass) \
    X(vkDestroyRenderPass) \
    X(vkCreateShaderModule) \
    X(vkDestroyShaderModule) \
    X(vkCreatePipelineCache) \
    X(vkDestroyPipelineCache) \
    X(vkGetPipelineCacheData) \
    X(vkCreateGraphicsPipelines) \
    X(vkDestroyPipeline)
#define DECLARE(name) static PFN_##name name;
VULKAN_FUNCTIONS(DECLARE)
#undef DECLARE
#endif
#define CHECK(expr) do{VkResult r=(expr);if(r!=VK_SUCCESS){fprintf(stderr,"FAIL %s = %d\n",#expr,r);exit(2);}}while(0)
static const uint32_t vs[]={0x07230203,0x00010000,0,13,0,
 (2<<16)|17,1, (3<<16)|14,0,1,
 (7<<16)|15,0,10,0x6e69616d,0,7,8,
 (4<<16)|71,7,30,3, (4<<16)|71,8,11,0,
 (2<<16)|19,1, (3<<16)|22,2,32, (4<<16)|23,3,2,4,
 (4<<16)|32,4,1,3, (4<<16)|32,5,3,3, (3<<16)|33,6,1,
 (4<<16)|59,4,7,1, (4<<16)|59,5,8,3,
 (5<<16)|54,1,10,0,6, (2<<16)|248,11,
 (4<<16)|61,3,12,7, (3<<16)|62,8,12, (1<<16)|253, (1<<16)|56};
static VkDevice device;
static VkPipelineLayout layout;
static VkRenderPass pass;
static VkShaderModule shader;
static VkResult attempt(VkPipelineCache cache,unsigned location,int attributes,const char *name){
 VkVertexInputBindingDescription binding={0,16,VK_VERTEX_INPUT_RATE_VERTEX};
 VkVertexInputAttributeDescription attr={location,0,VK_FORMAT_R32G32B32A32_SFLOAT,0};
 VkPipelineVertexInputStateCreateInfo vi={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
 .vertexBindingDescriptionCount=attributes,.pVertexBindingDescriptions=&binding,
 .vertexAttributeDescriptionCount=attributes,.pVertexAttributeDescriptions=&attr};
 VkPipelineShaderStageCreateInfo stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_VERTEX_BIT,.module=shader,.pName="main"};
 VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
 VkViewport vp={0,0,16,16,0,1};VkRect2D sc={{0,0},{16,16}};
 VkPipelineViewportStateCreateInfo viewport={.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,.viewportCount=1,.pViewports=&vp,.scissorCount=1,.pScissors=&sc};
 VkPipelineRasterizationStateCreateInfo raster={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.rasterizerDiscardEnable=VK_TRUE,.polygonMode=VK_POLYGON_MODE_FILL,.lineWidth=1};
 VkPipelineMultisampleStateCreateInfo ms={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};
 VkPipelineColorBlendAttachmentState attachment={.colorWriteMask=15};
 VkPipelineColorBlendStateCreateInfo blend={.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,.attachmentCount=1,.pAttachments=&attachment};
 VkGraphicsPipelineCreateInfo info={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=1,.pStages=&stage,
 .pVertexInputState=&vi,.pInputAssemblyState=&ia,.pViewportState=&viewport,.pRasterizationState=&raster,.pMultisampleState=&ms,.pColorBlendState=&blend,.layout=layout,.renderPass=pass};
 VkPipeline pipeline=VK_NULL_HANDLE;VkResult r=vkCreateGraphicsPipelines(device,cache,1,&info,NULL,&pipeline);
 printf("%s location=%u attributes=%d result=%d pipeline=%p\n",name,location,attributes,r,(void*)pipeline);fflush(stdout);
 if(pipeline)vkDestroyPipeline(device,pipeline,NULL);return r;
}
int main(void){
 setvbuf(stdout,NULL,_IONBF,0);
#ifdef _WIN32
 HMODULE module=LoadLibraryA("vulkan-1.dll");if(!module){puts("FAIL vulkan-1.dll missing");return 2;}
#define LOAD(name) do { \
    name = (PFN_##name)GetProcAddress(module, #name); \
    if (!name) { fprintf(stderr, "FAIL missing %s\n", #name); return 2; } \
} while (0);
 VULKAN_FUNCTIONS(LOAD)
#undef LOAD

#endif


 VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Pipeline cache direct export regression",.apiVersion=VK_API_VERSION_1_1};
 VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
 VkInstance instance;CHECK(vkCreateInstance(&ici,NULL,&instance));
 uint32_t n=0; CHECK(vkEnumeratePhysicalDevices(instance,&n,NULL));
 if (!n) { fputs("FAIL no physical device\n",stderr); return 2; }
 VkPhysicalDevice *devices=calloc(n,sizeof(*devices));if(!devices)return 2;
 CHECK(vkEnumeratePhysicalDevices(instance,&n,devices));
 VkPhysicalDevice physical=devices[0];free(devices);
 VkPhysicalDeviceProperties props;vkGetPhysicalDeviceProperties(physical,&props);printf("GPU=%s\n",props.deviceName);
 VkQueueFamilyProperties families[32];n=32;vkGetPhysicalDeviceQueueFamilyProperties(physical,&n,families);uint32_t q=0;while(q<n && !(families[q].queueFlags&VK_QUEUE_GRAPHICS_BIT))q++;if(q==n)return 2;
 float priority=1;VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=q,.queueCount=1,.pQueuePriorities=&priority};
 const char *deviceExt="VK_KHR_portability_subset";
 uint32_t ec=0;CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,NULL));
 VkExtensionProperties *extensions=calloc(ec,sizeof(*extensions));if(ec && !extensions)return 2;
 CHECK(vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,extensions));uint32_t hasSubset=0;
 for(uint32_t i=0;i<ec;i++)if(!strcmp(extensions[i].extensionName,deviceExt))hasSubset=1;
 free(extensions);
 VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi,.enabledExtensionCount=hasSubset,.ppEnabledExtensionNames=&deviceExt};CHECK(vkCreateDevice(physical,&di,NULL,&device));
 VkPipelineLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};CHECK(vkCreatePipelineLayout(device,&li,NULL,&layout));
 VkAttachmentDescription ad={.format=VK_FORMAT_R8G8B8A8_UNORM,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.storeOp=VK_ATTACHMENT_STORE_OP_DONT_CARE,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED,.finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
 VkAttachmentReference ref={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&ref};
 VkRenderPassCreateInfo ri={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=1,.pAttachments=&ad,.subpassCount=1,.pSubpasses=&sub};CHECK(vkCreateRenderPass(device,&ri,NULL,&pass));
 VkShaderModuleCreateInfo si={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=sizeof(vs),.pCode=vs};CHECK(vkCreateShaderModule(device,&si,NULL,&shader));

 int failed=0;
 VkPipelineCacheCreateInfo ci={.sType=VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};
 for(int populated=0;populated<2;populated++) {
  VkPipelineCache cache;CHECK(vkCreatePipelineCache(device,&ci,NULL,&cache));
  if(populated && attempt(cache,3,1,"valid populated-cache pipeline")!=VK_SUCCESS)return 2;
  static unsigned char data[1024*1024],direct_data[1024*1024];
  memset(data,0xcc,sizeof(data));size_t direct=sizeof(data),query=0;
  VkResult rd=vkGetPipelineCacheData(device,cache,&direct,data);
  if(direct>sizeof(data))return 2;
  memcpy(direct_data,data,direct);
  VkResult rq=vkGetPipelineCacheData(device,cache,&query,NULL);size_t after=sizeof(data);
  VkResult rr=vkGetPipelineCacheData(device,cache,&after,data);
  printf("CACHE_EXPORT populated=%d direct_result=%d direct_bytes=%zu query_result=%d query_bytes=%zu queried_write_result=%d queried_write_bytes=%zu\n",populated,rd,direct,rq,query,rr,after);fflush(stdout);
  if(rd!=VK_SUCCESS || rq!=VK_SUCCESS || rr!=VK_SUCCESS ||
     direct<32 || direct>query || after!=direct || memcmp(direct_data,data,direct))failed=1;
  if(direct>=32){
   uint32_t header[4];memcpy(header,direct_data,sizeof(header));
   if(header[0]<32 || header[0]>direct || header[1]!=VK_PIPELINE_CACHE_HEADER_VERSION_ONE ||
      header[2]!=props.vendorID || header[3]!=props.deviceID ||
      memcmp(direct_data+16,props.pipelineCacheUUID,VK_UUID_SIZE))failed=1;
  }
  memset(data,0xcc,sizeof(data));size_t short_size=1;VkResult rs=vkGetPipelineCacheData(device,cache,&short_size,data);
  printf("CACHE_EXPORT short_buffer_result=%d written=%zu\n",rs,short_size);fflush(stdout);
  if(rs!=VK_INCOMPLETE || short_size>1)failed=1;
  for(size_t i=1;i<sizeof(data);i++)if(data[i]!=0xcc){failed=1;break;}
  vkDestroyPipelineCache(device,cache,NULL);
 }
 vkDestroyShaderModule(device,shader,NULL);vkDestroyRenderPass(device,pass,NULL);vkDestroyPipelineLayout(device,layout,NULL);vkDestroyDevice(device,NULL);vkDestroyInstance(instance,NULL);
 printf("[vk-cache-export-test] %s\n",failed?"FAIL":"PASS");
 return failed;
}
