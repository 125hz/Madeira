#!/usr/bin/env python3
"""ml1380: the winios Vulkan driver finds VK_EXT_metal_surface in the library's
extension list when the library exports only vkGetInstanceProcAddr (a Mesa driver
such as KosmicKrisp), not just when vkCreateMetalSurfaceEXT is an exported symbol.

Compiles the production winios_vk_library_has_extension() from
build/win32u-unix/vulkan_ios.c against a fake library. No Wine, SDK or device.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/win32u-unix/vulkan_ios.c').read_text()
start = src.index('static BOOL winios_vk_library_has_extension(')
end = src.index('\n}\n', start) + 3
func = src[start:end]
init = src[src.index('UINT winios_VulkanInit('):]
assert 'MADEIRA_VK_SURFACE_QUERY' in init and 'winios_vk_library_has_extension' in init, \
    'winios_VulkanInit no longer asks the extension list'

prelude = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL;
#define TRUE 1
#define FALSE 0
typedef int VkResult;
typedef struct { char extensionName[256]; uint32_t specVersion; } VkExtensionProperties;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(void *instance, const char *name);
typedef VkResult (*PFN_vkEnumerateInstanceExtensionProperties)(const char *layer, uint32_t *count,
                                                               VkExtensionProperties *props);
static const char *const *fake_list;
static int fake_has_gipa;
static VkResult fake_enumerate(const char *layer, uint32_t *count, VkExtensionProperties *props)
{
    uint32_t n = 0, i;
    (void)layer;
    while (fake_list[n]) n++;
    if (!props) { *count = n; return 0; }
    for (i = 0; i < n && i < *count; i++) strcpy(props[i].extensionName, fake_list[i]);
    *count = i;
    return 0;
}
static PFN_vkVoidFunction fake_gipa(void *instance, const char *name)
{
    if (!instance && !strcmp(name, "vkEnumerateInstanceExtensionProperties"))
        return (PFN_vkVoidFunction)fake_enumerate;
    return NULL;
}
static void *dlsym(void *handle, const char *name)
{
    (void)handle;
    if (fake_has_gipa && !strcmp(name, "vkGetInstanceProcAddr")) return (void *)fake_gipa;
    return NULL;   /* like KosmicKrisp: no vkCreateMetalSurfaceEXT export */
}
'''
tests = r'''
int main(void)
{
    static const char *const metal[] = { "VK_KHR_surface", "VK_EXT_metal_surface", NULL };
    static const char *const headless[] = { "VK_KHR_surface", "VK_EXT_headless_surface", NULL };
    static const char *const neither[] = { "VK_KHR_surface", NULL };
    BOOL h;
    fake_has_gipa = 1;
    fake_list = metal;
    assert(winios_vk_library_has_extension((void *)1, "VK_EXT_metal_surface", &h) && !h);
    fake_list = headless;
    assert(!winios_vk_library_has_extension((void *)1, "VK_EXT_metal_surface", &h) && h);
    fake_list = neither;
    assert(!winios_vk_library_has_extension((void *)1, "VK_EXT_metal_surface", &h) && !h);
    fake_has_gipa = 0;
    fake_list = metal;
    assert(!winios_vk_library_has_extension((void *)1, "VK_EXT_metal_surface", &h) && !h);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-vk-surface-') as tmp:
    c = Path(tmp) / 'check.c'
    exe = Path(tmp) / 'check'
    c.write_text(prelude + func + tests)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O1',
                    str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: VK_EXT_metal_surface found through vkGetInstanceProcAddr + the extension list (ml1380); '
      'headless and neither cases; no vkGetInstanceProcAddr export')
