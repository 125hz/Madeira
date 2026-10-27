/* SPDX-License-Identifier: GPL-3.0-or-later
 * With the additional permission in LICENSE-EXCEPTION.md.
 * Ordinary x64 COM activation: no manual registration or direct factory fallback.
 */
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <stdio.h>

static unsigned failures;

static int check_hr(const char *operation, HRESULT hr)
{
    printf("[taskbarlist] %s hr=%#lx\n", operation, (unsigned long)hr);
    if (FAILED(hr)) failures++;
    fflush(stdout);
    return SUCCEEDED(hr);
}

int main(void)
{
    HRESULT hr;
    WCHAR path[MAX_PATH];
    HMODULE module;
    UINT length;
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("[taskbarlist] BEGIN Windows x64 COM smoke test\n");
    length = GetSystemDirectoryW(path, MAX_PATH);
    if (!length || length + ARRAYSIZE(L"\\explorerframe.dll") > MAX_PATH)
    {
        printf("[taskbarlist] FAIL GetSystemDirectoryW error=%lu\n", GetLastError());
        return 1;
    }
    lstrcatW(path, L"\\explorerframe.dll");
    module = LoadLibraryW(path);
    printf("[taskbarlist] LoadLibrary(system32/explorerframe.dll) module=%p error=%lu\n",
           (void *)module, module ? 0 : GetLastError());
    if (!module) failures++;
    else FreeLibrary(module);
    if (!check_hr("CoInitializeEx(STA)", CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)))
        return 1;
    for (unsigned round = 0; round < 2; round++)
    {
        ITaskbarList *taskbar = NULL;
        ITaskbarList4 *extended = NULL;
        printf("[taskbarlist] round=%u\n", round + 1);
        hr = CoCreateInstance(&CLSID_TaskbarList, NULL, CLSCTX_INPROC_SERVER,
                              &IID_ITaskbarList, (void **)&taskbar);
        if (!check_hr("CoCreateInstance(CLSID_TaskbarList, ITaskbarList)", hr)) continue;
        if (!taskbar) { failures++; continue; }
        check_hr("ITaskbarList::HrInit", ITaskbarList_HrInit(taskbar));
        hr = ITaskbarList_QueryInterface(taskbar, &IID_ITaskbarList4, (void **)&extended);
        if (check_hr("QueryInterface(ITaskbarList4)", hr))
        {
            if (!extended) failures++;
            else ITaskbarList4_Release(extended);
        }
        ITaskbarList_Release(taskbar);
        CoFreeUnusedLibraries();
    }
    CoUninitialize();
    printf("[taskbarlist] END failed=%u\n", failures);
    return failures != 0;
}
