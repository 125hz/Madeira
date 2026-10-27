/* Fixed-address VirtualAlloc contract regression; no game-specific inputs.
 * Run in a fresh Madeira session. Reserves VA, commits only 64 KiB explicitly.
 * Build with llvm-mingw x86_64-w64-mingw32-clang -O2 fixed-reserve.c -o fixed-reserve.exe
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static unsigned failed, skipped;

static void conflict(void *arena, SIZE_T size, DWORD type)
{
    void *result = VirtualAlloc(arena, size, type, PAGE_READWRITE);
    if (result)
    {
        printf("FAIL: occupied fixed request %p size=%llx type=%lx returned %p\n",
               arena, (unsigned long long)size, (unsigned long)type, result);
        failed++;
        if (result != arena) VirtualFree(result, 0, MEM_RELEASE);
    }
    else printf("PASS: occupied fixed request rejected size=%llx type=%lx error=%lu\n",
                (unsigned long long)size, (unsigned long)type, GetLastError());
}

int main(void)
{
    const SIZE_T gib = (SIZE_T)1 << 30;
    void *arena = VirtualAlloc(NULL, gib + 0x10000, MEM_RESERVE, PAGE_READWRITE);
    if (!arena)
    {
        printf("INCOMPLETE: no room for test arena, error=%lu\n", GetLastError());
        return 2;
    }
    void *page = VirtualAlloc(arena, 0x10000, MEM_COMMIT, PAGE_READWRITE);
    if (page != arena)
    {
        printf("FAIL: commit inside automatic reservation returned %p\n", page);
        VirtualFree(arena, 0, MEM_RELEASE);
        return 1;
    }
    *(volatile DWORD *)page = 0x1234abcd;
    conflict(arena, 0x10000, MEM_RESERVE);
    conflict(arena, gib, MEM_RESERVE);
    conflict(arena, gib + 0x10000, MEM_RESERVE);
    conflict(arena, gib, MEM_RESERVE | MEM_COMMIT);
    if (*(volatile DWORD *)page != 0x1234abcd)
    {
        puts("FAIL: conflicting request changed the original mapping");
        failed++;
    }
    else puts("PASS: original committed data preserved");
    if (!VirtualFree(arena, 0, MEM_RELEASE))
    {
        puts("FAIL: original reservation release failed");
        failed++;
    }

    /* A caller that needs an aligned arena can select its own next address.
     * Do not assume the device has the VA capacity to grant one. */
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    uintptr_t first = ((uintptr_t)info.lpMinimumApplicationAddress + gib - 1) & ~(gib - 1);
    uintptr_t high = (uintptr_t)info.lpMaximumApplicationAddress;
    arena = NULL;
    for (uintptr_t addr = first; addr <= high && high - addr >= gib - 1; addr += gib)
    {
        void *result = VirtualAlloc((void *)addr, gib, MEM_RESERVE, PAGE_READWRITE);
        if (!result) continue;
        if (result != (void *)addr)
        {
            printf("FAIL: aligned fixed request %p redirected to %p\n", (void *)addr, result);
            failed++;
            VirtualFree(result, 0, MEM_RELEASE);
            break;
        }
        arena = result;
        break;
    }
    if (arena)
    {
        page = VirtualAlloc((char *)arena + 0x20000, 0x10000, MEM_COMMIT, PAGE_READWRITE);
        if (page != (char *)arena + 0x20000)
        {
            puts("FAIL: commit inside aligned arena failed");
            failed++;
        }
        else
        {
            *(volatile DWORD *)page = 0x4567cdef;
            if (*(volatile DWORD *)page != 0x4567cdef) failed++;
            else puts("PASS: caller-selected aligned arena supports commit/read/write");
        }
        if (!VirtualFree(arena, 0, MEM_RELEASE)) failed++;
    }
    else
    {
        puts("SKIP: no aligned arena granted (or redirect already reported)");
        skipped++;
    }
    printf("SUMMARY: failed=%u skipped=%u\n", failed, skipped);
    return failed ? 1 : skipped ? 2 : 0;
}
