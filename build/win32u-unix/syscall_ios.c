/*
 * iOS-Madeira override for wine/dlls/win32u/syscall.c.
 *
 * Upstream win32u keeps one process-global, `zero_bits`, which is set at
 * unix-lib init when the process has a WoW64 TEB:
 *
 *     if (NtCurrentTeb()->WowTebOffset)
 *         zero_bits = (ULONG_PTR)info.HighestUserAddress | 0x7fffffff;
 *
 * Every later NtAllocateVirtualMemory in win32u passes it, so window-surface
 * DIBs (dib.c NtGdiCreateDIBSection), the GDI shared block (gdiobj.c), DC
 * bucket entries (dc.c) and message return buffers (message.c) are all forced
 * below 2 GB so 32-bit guest code can address them.
 *
 * Two things make that fatal on Madeira:
 *
 *   1. Madeira runs EVERY Windows process inside one Mach task, so this
 *      "process-global" is really task-global. The first 32-bit pseudo-process
 *      to load win32u sets it, and it stays set for every other pseudo-process
 *      afterwards -- including the 64-bit desktop -- even after that child has
 *      died.
 *   2. iOS never maps the low 2 GB of a 64-bit process. The allocator's scan
 *      reports `window=0x10000..0x80000000 ... views=0 ... no-views-in-range`
 *      and returns STATUS_NO_MEMORY for every request, so an allocation that
 *      honours zero_bits can only ever fail.
 *
 * Together they meant: launch one 32-bit program, and from that moment on
 * every newly shown window in the session lost its backing surface.
 * window_surface_create() returned NULL, the window was never flushed and
 * never presented -- visible on the taskbar, invisible on screen. Windows
 * created before the first 32-bit launch kept working, which is exactly the
 * before/after split seen in the logs.
 *
 * 32-bit guests here execute under FEX inside its own 4 GB window high in the
 * address space and never receive a raw win32u pointer, so the low-2 GB
 * constraint buys nothing. Keep zero_bits at 0.
 */

#include <unistd.h>

/* Compile upstream syscall.c with its init entry point renamed, then wrap it.
 * build.sh already maps __wine_unix_lib_init -> win32u_unix_lib_init; this
 * pushes that one step further so the wrapper below can own the real name. */
#define win32u_unix_lib_init win32u_unix_lib_init_upstream
#include "../../wine/dlls/win32u/syscall.c"
#undef win32u_unix_lib_init

NTSTATUS win32u_unix_lib_init(void)
{
    NTSTATUS status = win32u_unix_lib_init_upstream();

    if (zero_bits)
    {
        dprintf( 2, "[zero-bits] ml750 win32u init asked for low-2GB allocations "
                    "(zero_bits=%#lx) -- clearing it: iOS maps nothing below 2GB and this "
                    "global is shared by every pseudo-process in the task\n",
                 (unsigned long)zero_bits );
        zero_bits = 0;
    }
    return status;
}
