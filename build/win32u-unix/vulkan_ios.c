/* Wine Vulkan core with a statically linked iOS backend.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Restrict the loader override to this translation unit and a named backend.
 */
#include "config.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

extern void *madeira_vulkan_symbol(const char *name);
static char ios_vulkan_token;
static void *ios_vulkan_open(const char *name, int flags)
{
    if (strcmp(name, "madeira-static-moltenvk")) return dlopen(name, flags);
    fprintf(stderr, "[vk-win32u] binding statically linked MoltenVK backend\n");
    return &ios_vulkan_token;
}
static void *ios_vulkan_sym(void *handle, const char *name)
{
    if (handle != &ios_vulkan_token) return dlsym(handle, name);
    return madeira_vulkan_symbol(name);
}
static int ios_vulkan_close(void *handle)
{
    return handle == &ios_vulkan_token ? 0 : dlclose(handle);
}
#undef SONAME_LIBVULKAN
#define SONAME_LIBVULKAN "madeira-static-moltenvk"
#define dlopen ios_vulkan_open
#define dlsym ios_vulkan_sym
#define dlclose ios_vulkan_close
#include "../../wine/dlls/win32u/vulkan.c"

#include "vulkan_surface_ios.c"
