/* MADEIRA-TEMP: the self-test for the ml962 non-faulting ReadProcessMemory /
 * WriteProcessMemory path (build/ntdll-unix/virtual_ios.c,
 * ios_probe_range_readable / ios_copy_in_no_fault).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * Upstream's NtReadVirtualMemory implements the current-process case as
 * `__TRY { memmove } __EXCEPT { STATUS_PARTIAL_COPY }`, i.e. the DOCUMENTED
 * failure mode of ReadProcessMemory is a caught fault.  On this port that
 * assumption is not safe.  A guest program crashed, its own in-process
 * crash-dump writer called ReadProcessMemory(GetCurrentProcess(), 0x8, ...)
 * while running on a stack it had switched to itself -- so a stack outside the
 * TEB's Tib.StackLimit/Tib.StackBase -- and the fault inside _platform_memmove
 * could not be dispatched:
 *
 *   [mach_exc] sym pc=libsystem_platform.dylib`_platform_memmove+0x1bc
 *              lr=Madeira`NtReadVirtualMemory+0xf0
 *   [mach-deliver] rev=ml378 no TEB owns sp=0x702010fbd0 -> BEST-EFFORT delivery
 *   err:seh:call_seh_handlers invalid frame 702010fbd0 (7020118000-70290FD20)
 *   err:seh:NtRaiseException Exception frame is not in stack limits
 *   err:process:NtTerminateProcess exit_code=0xc0000005
 *
 * The whole process died over a probe that was supposed to return FALSE.  Any
 * crash reporter, minidump writer, anti-tamper check or debugger-like scan
 * reaches that code, so this is a generic robustness hole, not one program's
 * bug -- and it is invisible until something reads an unmapped address.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. NULL PAGE.  ReadProcessMemory(self, (void *)8, ...) must return FALSE
 *     with ERROR_PARTIAL_COPY or ERROR_NOACCESS -- and, the actual point, must
 *     RETURN at all rather than take the process down.
 *  2. VALID RANGE.  A read of an ordinary committed buffer must copy every
 *     byte unchanged; the no-fault path must not be a no-op that silently
 *     "succeeds".
 *  3. STRADDLE.  A range whose first half is committed and whose second half
 *     is only reserved must report a PARTIAL copy with the exact readable
 *     prefix count, which is what Windows' ERROR_PARTIAL_COPY means.  A
 *     whole-range probe that gave up on the first unreadable byte would return
 *     0 here and pass check 1 while still being wrong.
 *  4. WRITE TO READ-ONLY, matching WINE UPSTREAM, not the MSDN summary:
 *     kernelbase's WriteProcessMemory (wine/dlls/kernelbase/memory.c:633)
 *     only reprotects PAGE_EXECUTE and PAGE_EXECUTE_READ; every other
 *     non-writable protection, PAGE_READONLY included, falls into its
 *     `default:` and returns STATUS_ACCESS_VIOLATION.  So PAGE_READONLY must
 *     FAIL with ERROR_NOACCESS and PAGE_EXECUTE_READ must SUCCEED with the
 *     bytes landing and the protection restored.  Checks 4b and 4c are the
 *     only coverage here for the server-side write path
 *     (build/wineserver/mach_ios.c write_process_memory): 4b is the executable
 *     page, which has to be made writable and put back, and 4c (ml972) is a
 *     plain PAGE_READWRITE page, which kernelbase hands straight to
 *     NtWriteVirtualMemory.  4c exists because the port's failure was in the
 *     server routine itself, so EVERY WriteProcessMemory failed and not just
 *     the interesting one -- a fix that only understood executable pages would
 *     have passed 4b and left the common case broken.
 *  5. ALT STACK.  Checks 1 and 3 again from a stack this program allocated with
 *     VirtualAlloc and entered by moving ESP in inline asm -- no TEB describes
 *     it, which is exactly the condition that turned the original failure
 *     fatal.  Same results as on the normal stack, or the fix is incomplete.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' plus memset/memcpy and links
 * -nostdlib, so its only import is kernel32), no 64-bit division, no
 * int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   48  every check passed
 *   60  VirtualAlloc/VirtualProtect setup failed -- nothing was tested
 *   61  reading the NULL page SUCCEEDED (it must not)
 *   62  reading the NULL page failed with an unexpected GetLastError
 *   63  reading a valid buffer failed, or the bytes came back wrong
 *   64  the straddling read did not report a partial copy
 *   65  the straddling read reported the wrong readable-prefix length
 *   66  WriteProcessMemory to PAGE_READONLY did not fail the way Wine does
 *   67  WriteProcessMemory to PAGE_EXECUTE_READ or PAGE_READWRITE failed, or
 *       the bytes / the restored protection did not come back right
 *   68  a check behaved differently on the manually switched stack
 *   69  a zero-length read was not a success
 */
#include <stddef.h>
#include <windows.h>

#define BLOCK      0x10000u   /* 64K: >= any host page size, so the committed /
                               * reserved boundary in check 3 is a real page
                               * boundary on a 16K-page device too. */
#define ALT_STACK  0x40000u   /* 256K for the manually entered stack */

/* -nostdlib: clang may still lower a struct initialisation to memset/memcpy. */
void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

/* ---------------------------------------------------------------- logging */

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static char *put_uint( char *p, unsigned int v )
{
    char tmp[16];
    int n = 0;
    if (!v) { *p++ = '0'; return p; }
    while (v) { tmp[n++] = (char)('0' + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static void line_0( const char *a )
{
    char buf[256], *p = buf;
    p = put_str( p, a );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void line_1( const char *a, unsigned int v, const char *b )
{
    char buf[256], *p = buf;
    p = put_str( p, a );
    p = put_uint( p, v );
    p = put_str( p, b );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void line_2( const char *a, unsigned int v, const char *b, unsigned int w, const char *c )
{
    char buf[256], *p = buf;
    p = put_str( p, a );
    p = put_uint( p, v );
    p = put_str( p, b );
    p = put_uint( p, w );
    p = put_str( p, c );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------- the checks */

/* Shared setup, built once and reused by both the normal-stack and the
 * alt-stack passes so the two are comparing the same addresses. */
static char *straddle;        /* BLOCK committed RW, then BLOCK reserved */
static char *pattern;         /* BLOCK committed RW, filled with a pattern */
static char  sink[64];

static int check_null_page(void)
{
    char buf[16];
    SIZE_T got = 0xdeadbeef;
    DWORD err;

    /* The literal address from the device log. Deliberately unaligned and in
     * the guest's NULL page: no view, no vprot entry, no Mach region. */
    SetLastError( 0 );
    if (ReadProcessMemory( GetCurrentProcess(), (const void *)8, buf, sizeof(buf), &got ))
    {
        line_1( "MADEIRA-READVM: reading the NULL page SUCCEEDED, got=", (unsigned int)got, " bytes" );
        return 61;
    }
    err = GetLastError();
    if (err != ERROR_PARTIAL_COPY && err != ERROR_NOACCESS)
    {
        line_1( "MADEIRA-READVM: NULL-page read failed with unexpected error ", (unsigned int)err, "" );
        return 62;
    }
    line_2( "MADEIRA-READVM: NULL-page read returned FALSE err=", (unsigned int)err,
            " got=", (unsigned int)got, " OK" );
    return 0;
}

static int check_valid(void)
{
    char buf[64];
    SIZE_T got = 0;
    unsigned int i;

    for (i = 0; i < sizeof(buf); i++) buf[i] = 0;
    if (!ReadProcessMemory( GetCurrentProcess(), pattern + 0x2000, buf, sizeof(buf), &got )
        || got != sizeof(buf))
    {
        line_2( "MADEIRA-READVM: valid read failed err=", (unsigned int)GetLastError(),
                " got=", (unsigned int)got, "" );
        return 63;
    }
    for (i = 0; i < sizeof(buf); i++)
    {
        if ((unsigned char)buf[i] != (unsigned char)((0x2000 + i) * 7 + 3))
        {
            line_1( "MADEIRA-READVM: valid read returned wrong byte at offset ", i, "" );
            return 63;
        }
    }
    line_0( "MADEIRA-READVM: 64-byte read of a committed buffer matched OK" );
    return 0;
}

static int check_straddle(void)
{
    char buf[32];
    SIZE_T got = 0xdeadbeef;
    DWORD err;

    /* 8 readable bytes at the end of the committed half, then 8 bytes of the
     * reserved half. Windows: FALSE / ERROR_PARTIAL_COPY / 8 bytes read. */
    SetLastError( 0 );
    if (ReadProcessMemory( GetCurrentProcess(), straddle + BLOCK - 8, buf, 16, &got ))
    {
        line_1( "MADEIRA-READVM: straddling read SUCCEEDED, got=", (unsigned int)got, " bytes" );
        return 64;
    }
    err = GetLastError();
    if (err != ERROR_PARTIAL_COPY)
    {
        line_1( "MADEIRA-READVM: straddling read failed with error ", (unsigned int)err,
                " (wanted ERROR_PARTIAL_COPY 299)" );
        return 64;
    }
    if (got != 8)
    {
        line_2( "MADEIRA-READVM: straddling read reported ", (unsigned int)got,
                " readable bytes, wanted ", 8, "" );
        return 65;
    }
    line_0( "MADEIRA-READVM: straddling read gave ERROR_PARTIAL_COPY with an 8-byte prefix OK" );
    return 0;
}

static int check_zero_length(void)
{
    SIZE_T got = 0xdeadbeef;

    /* A zero-length read of a hopeless address is still a success on Windows:
     * nothing is copied, so nothing can fail. */
    if (!ReadProcessMemory( GetCurrentProcess(), (const void *)8, sink, 0, &got ) || got != 0)
    {
        line_2( "MADEIRA-READVM: zero-length read failed err=", (unsigned int)GetLastError(),
                " got=", (unsigned int)got, "" );
        return 69;
    }
    line_0( "MADEIRA-READVM: zero-length read succeeded with 0 bytes OK" );
    return 0;
}

static int check_write_readonly(void)
{
    static const char src[4] = { 'W', 'P', 'M', '!' };
    char *page;
    DWORD old = 0;
    SIZE_T put = 0xdeadbeef;
    DWORD err;

    page = VirtualAlloc( NULL, BLOCK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    if (!page) return 60;
    page[0] = 'x'; page[1] = 'x'; page[2] = 'x'; page[3] = 'x';
    if (!VirtualProtect( page, BLOCK, PAGE_READONLY, &old )) return 60;

    /* 4a: PAGE_READONLY. Wine's WriteProcessMemory reprotects only
     * PAGE_EXECUTE / PAGE_EXECUTE_READ (wine/dlls/kernelbase/memory.c:644);
     * PAGE_READONLY hits the `default:` and is refused. */
    SetLastError( 0 );
    if (WriteProcessMemory( GetCurrentProcess(), page, src, 4, &put ))
    {
        line_1( "MADEIRA-READVM: write to PAGE_READONLY SUCCEEDED (Wine refuses it), put=",
                (unsigned int)put, "" );
        return 66;
    }
    err = GetLastError();
    if (err != ERROR_NOACCESS)
    {
        line_1( "MADEIRA-READVM: write to PAGE_READONLY failed with error ", (unsigned int)err,
                " (wanted ERROR_NOACCESS 998)" );
        return 66;
    }
    if (page[0] != 'x')
    {
        line_0( "MADEIRA-READVM: write to PAGE_READONLY was refused but the bytes changed anyway" );
        return 66;
    }
    line_1( "MADEIRA-READVM: write to PAGE_READONLY refused with err=", (unsigned int)err,
            " as Wine does OK" );

    /* 4b: PAGE_EXECUTE_READ -- the one protection Wine DOES make writable, and
     * the only exercise here of the server's mach_vm_protect/mach_vm_write/
     * restore sequence. */
    if (!VirtualProtect( page, BLOCK, PAGE_EXECUTE_READ, &old )) return 60;
    put = 0;
    SetLastError( 0 );
    if (!WriteProcessMemory( GetCurrentProcess(), page, src, 4, &put ) || put != 4)
    {
        line_2( "MADEIRA-READVM: write to PAGE_EXECUTE_READ failed err=",
                (unsigned int)GetLastError(), " put=", (unsigned int)put, "" );
        return 67;
    }
    if (page[0] != 'W' || page[1] != 'P' || page[2] != 'M' || page[3] != '!')
    {
        line_0( "MADEIRA-READVM: write to PAGE_EXECUTE_READ reported success but the bytes did not land" );
        return 67;
    }
    {
        MEMORY_BASIC_INFORMATION info;
        memset( &info, 0, sizeof(info) );
        if (!VirtualQuery( page, &info, sizeof(info) ) || info.Protect != PAGE_EXECUTE_READ)
        {
            line_1( "MADEIRA-READVM: PAGE_EXECUTE_READ was not restored, protect is now ",
                    (unsigned int)info.Protect, "" );
            return 67;
        }
    }
    line_0( "MADEIRA-READVM: write to PAGE_EXECUTE_READ landed and the protection was restored OK" );

    /* 4c: PAGE_READWRITE, i.e. the case kernelbase does NOT reprotect for --
     * it calls NtWriteVirtualMemory directly.  ml972: nothing covered this, and
     * on this port it was broken in exactly the same place as 4b and for
     * exactly the same reason (write_process_memory needs a Mach task port that
     * no pseudo-process has, so every WriteProcessMemory returned
     * ERROR_ACCESS_DENIED).  4b alone could be "fixed" by something that only
     * looks at executable pages; this says the ordinary path works too. */
    if (!VirtualProtect( page, BLOCK, PAGE_READWRITE, &old )) return 60;
    page[0] = 'x'; page[1] = 'x'; page[2] = 'x'; page[3] = 'x';
    put = 0;
    SetLastError( 0 );
    if (!WriteProcessMemory( GetCurrentProcess(), page, src, 4, &put ) || put != 4)
    {
        line_2( "MADEIRA-READVM: write to PAGE_READWRITE failed err=",
                (unsigned int)GetLastError(), " put=", (unsigned int)put, "" );
        return 67;
    }
    if (page[0] != 'W' || page[1] != 'P' || page[2] != 'M' || page[3] != '!')
    {
        line_0( "MADEIRA-READVM: write to PAGE_READWRITE reported success but the bytes did not land" );
        return 67;
    }
    line_0( "MADEIRA-READVM: write to PAGE_READWRITE landed OK" );
    return 0;
}

/* ------------------------------------------------- the manually switched stack */

/* Runs with ESP pointing into a VirtualAlloc'd block, so NtCurrentTeb()'s
 * StackLimit/StackBase do NOT describe the stack in use -- the condition under
 * which the original fault became fatal. Re-runs the two checks that depend on
 * a read failing. */
static int __attribute__((noinline)) alt_stack_body(void)
{
    int rc;
    if ((rc = check_null_page())) return rc;
    if ((rc = check_straddle())) return rc;
    return 0;
}

static int run_on_alt_stack( void *stack_top )
{
    int rc = 0;
    int (*body)(void) = alt_stack_body;

    /* edi holds the old esp across the call: cdecl makes ebx/esi/edi/ebp
     * callee-saved, so the callee cannot lose it. The inputs are "r"-
     * constrained, so they stay in registers that survive the esp move, and
     * neither can be edi because edi is clobbered. */
    __asm__ __volatile__(
        "movl %%esp, %%edi\n\t"
        "movl %1, %%esp\n\t"
        "call *%2\n\t"
        "movl %%edi, %%esp"
        : "=a" (rc)
        : "r" (stack_top), "r" (body)
        : "edi", "ecx", "edx", "cc", "memory" );
    return rc;
}

static int check_alt_stack(void)
{
    char *stack = VirtualAlloc( NULL, ALT_STACK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    int rc;

    if (!stack) return 60;
    line_0( "MADEIRA-READVM: repeating the NULL-page and straddle checks on a manually switched stack" );
    rc = run_on_alt_stack( stack + ALT_STACK - 64 );
    if (rc)
    {
        line_1( "MADEIRA-READVM: a check returned ", (unsigned int)rc,
                " on the switched stack but passed on the normal one" );
        return 68;
    }
    line_0( "MADEIRA-READVM: both checks behaved identically off-stack OK" );
    return 0;
}

/* --------------------------------------------------------------- driver */

static int setup(void)
{
    unsigned int i;

    /* BLOCK committed followed by BLOCK reserved-only, in ONE reservation so
     * the two halves are adjacent with no other mapping in between. */
    straddle = VirtualAlloc( NULL, 2 * BLOCK, MEM_RESERVE, PAGE_NOACCESS );
    if (!straddle) return 60;
    if (!VirtualAlloc( straddle, BLOCK, MEM_COMMIT, PAGE_READWRITE )) return 60;
    for (i = 0; i < BLOCK; i++) straddle[i] = (char)(i * 5 + 1);

    pattern = VirtualAlloc( NULL, BLOCK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    if (!pattern) return 60;
    for (i = 0; i < BLOCK; i++) pattern[i] = (char)(i * 7 + 3);
    return 0;
}

static int run_all(void)
{
    int rc;

    out_str( "MADEIRA-READVM: ReadProcessMemory/WriteProcessMemory robustness test starting\n" );

    if ((rc = setup())) return rc;
    if ((rc = check_null_page())) return rc;
    if ((rc = check_valid())) return rc;
    if ((rc = check_straddle())) return rc;
    if ((rc = check_zero_length())) return rc;
    if ((rc = check_write_readonly())) return rc;
    if ((rc = check_alt_stack())) return rc;

    out_str( "MADEIRA-READVM: all checks passed\n" );
    return 48;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
