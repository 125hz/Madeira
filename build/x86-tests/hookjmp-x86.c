/* MADEIRA-TEMP: the inline-detour self-test — hookjmp-x86.exe.
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * A large class of 32-bit software installs INLINE DETOURS: it overwrites the
 * first five bytes of a function with `E9 rel32`, copies the displaced bytes to
 * a trampoline of its own, and appends a second `E9 rel32` back to
 * function+5.  Copy-protection wrappers, file-redirection shims, overlay
 * injectors, profilers and every general-purpose hook library work this way.
 *
 * On x86 the displacement is 32 bits and the target is computed MODULO 2^32:
 * `next_eip + rel32` wraps, so a detour can reach any address in the 4 GB space
 * from any other, and the distance between a low and a high address is never
 * larger than 4 GB even when the signed reading of it is absurd.  A port that
 * computes the same branch in 64 bits, or that sign-extends before adding, gets
 * an address above 4 GB instead — and on THIS port that question is live,
 * because the guest window is [B, B+4G) and the two ends of a detour routinely
 * sit in opposite halves of it: this port places Wine's builtin i386 images in
 * the HIGH half (guest ntdll around 0xfff40000) while a program and the DLLs it
 * ships load LOW, so a detour on a system DLL spans about 2.26 GB — just past
 * what a signed 32-bit displacement can express, and therefore exactly the case
 * a 64-bit computation gets wrong.
 *
 * The other half of the same subject is whether the WRITE lands at all.  On
 * this port a guest image page is not host-executable — the emulator decodes
 * the bytes and runs a translation out of the JIT pool — so patching one has to
 * go through the VirtualProtect bookkeeping, the write trap and the
 * translation invalidation before the new bytes can run.  A page that reports
 * PAGE_EXECUTE_READWRITE and then silently drops stores is invisible to every
 * check except reading the bytes back, so this test reads them back.
 *
 * Nothing here is specific to any program: the shapes it relocates are the two
 * five-byte prologues that Windows and Wine actually emit for a patchable
 * export, and the exports it patches were chosen only for being no-argument and
 * side-effect free.
 *
 * THE PHASES
 *
 *   1. BASELINE, both ends low.  Build a stub in a low PAGE_EXECUTE_READWRITE
 *      page, detour it into a function in this image, trampoline in another low
 *      page, call it.  If this fails nothing later means anything.
 *   2. ACROSS 2 GB.  The same stub placed in a page reserved at an explicit
 *      base above 0x80000000, detoured to a LOW handler whose trampoline jumps
 *      back HIGH.  Both `E9`s now carry a displacement whose signed reading is
 *      beyond +/-2 GB, and only modulo-2^32 arithmetic reaches the target.
 *      Skipped (with its own exit status, not a failure) when no page above
 *      2 GB can be reserved, which is the correct outcome in a 2 GB user space.
 *   3. A REAL SYSTEM DLL, syscall-thunk prologue.  Detour a no-argument ntdll
 *      export whose first instruction is `mov eax, imm32` — the shape every
 *      native-API stub has, and the shape a hook library parses and re-emits.
 *      The target is wherever the port put ntdll, so on this port phase 3 IS
 *      the cross-2 GB case against real code rather than against our own page.
 *   4. A REAL SYSTEM DLL, hot-patch prologue.  The same, on an export that
 *      begins with a two-byte pad plus `push ebp; mov ebp,esp` — Windows
 *      spells the pad `8B FF`, Wine's toolchain `66 90`, and both are accepted.
 *      This pass also proves the restore, by reading the bytes back and by
 *      calling the export once more with the detour removed.
 *
 * Every patch is undone before the program exits, and every phase checks BOTH
 * halves of the detour: that the handler ran (the forward `E9` arrived) and
 * that the trampoline reached the original code (the backward `E9` arrived).
 * A test that only checked the first would pass with a trampoline that jumps
 * into hyperspace as long as nothing ever called it.
 *
 * HOW A WILD BRANCH IS CAUGHT.  There is no CRT and no __try here (clang has no
 * SEH for 32-bit x86), so a vectored exception handler redirects Eip to a stub
 * that returns a sentinel.  It only claims faults while a call is in flight, so
 * an unrelated fault is still fatal and still reported.
 *
 * Deliberate restrictions, as in the other tests here: no CRT (this file
 * supplies `start' plus memset/memcpy and links -nostdlib, so its only import
 * is kernel32), no 64-bit division, no int-to-double conversion.
 *
 * THE IMAGE IS DELIBERATELY NOT LARGE-ADDRESS-AWARE.  That is the header the
 * subject software carries, and it is what makes phase 2 a question about this
 * port's placement policy (ios_wow_laa_synth in virtual_ios.c) rather than a
 * question the linker already answered.  build-hookjmp-test.sh asserts the bit
 * is ABSENT, the same inverted assertion build-laa-test.sh makes.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *
 *   60  PASS — every phase, including the one across 2 GB
 *   61  PASS — but phase 2 was skipped: no page above 2 GB could be reserved
 *              (the correct result with MADEIRA_LAA=0, i.e. a 2 GB user space)
 *   62  VirtualAlloc for the low code pages failed
 *   63  phase 1: the handler did not run (forward E9 did not arrive)
 *   64  phase 1: the trampoline did not reach the original (backward E9)
 *   65  phase 2: the handler did not run — a >2 GB rel32 did not reach
 *   66  phase 2: the trampoline did not reach the original — same, other way
 *   67  GetModuleHandle("ntdll.dll") or GetProcAddress failed
 *   68  VirtualQuery says the export's page is not committed+executable
 *   69  no candidate export had a 5-byte relocatable prologue
 *   70  VirtualProtect(PAGE_EXECUTE_READWRITE) on the export failed
 *   71  the patch bytes did not read back — the page dropped the stores
 *   72  phase 3: the handler did not run
 *   73  phase 3: the trampoline did not reach the original
 *   74  the restore did not take — the export still runs the detour
 *   75  phase 4: the handler did not run
 *   76  phase 4: the trampoline did not reach the original
 *   77  AddVectoredExceptionHandler failed
 */

#include <stddef.h>
#include <windows.h>

#define AV_SENTINEL 0x5A5AF00Du
#define STUB_MAGIC  0xDEADBEEFu

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

static char *put_hex( char *p, unsigned int v )
{
    static const char d[] = "0123456789abcdef";
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = d[(v >> i) & 0xf];
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static void line_0( const char *s )
{
    char buf[320];
    char *p = put_str( buf, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void line_hex( const char *a, unsigned int v, const char *b )
{
    char buf[320];
    char *p = put_str( buf, a );
    p = put_hex( p, v );
    p = put_str( p, b );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

static void line_hex3( const char *a, unsigned int v1, const char *b, unsigned int v2,
                       const char *c, unsigned int v3, const char *d )
{
    char buf[384];
    char *p = put_str( buf, a );
    p = put_hex( p, v1 );
    p = put_str( p, b );
    p = put_hex( p, v2 );
    p = put_str( p, c );
    p = put_hex( p, v3 );
    p = put_str( p, d );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* -------------------------------------------------- fault recovery (VEH) */

static volatile LONG fault_expected;
static volatile LONG fault_seen;
static unsigned char *av_stub;          /* `mov eax, AV_SENTINEL ; ret` */

static LONG CALLBACK veh( EXCEPTION_POINTERS *ep )
{
    if (fault_expected && av_stub &&
        ep->ExceptionRecord->ExceptionCode == (DWORD)EXCEPTION_ACCESS_VIOLATION)
    {
        fault_seen = 1;
        /* The faulting instruction is the first byte of a callee, so the stack
         * is exactly as a called function expects it and the stub's `ret`
         * unwinds correctly — the same trick execrw-x86.c uses. */
        ep->ContextRecord->Eip = (DWORD)(ULONG_PTR)av_stub;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

/* ------------------------------------------------------- the detour engine
 *
 * Five bytes, two shapes, no disassembler.  These are the only shapes a
 * five-byte detour may legally displace without decoding the whole stream:
 *
 *     B8 imm32                     mov eax, imm32      (every native-API stub)
 *     66 90 | 8B FF ; 55 ; 8B EC | 89 E5
 *                                  2-byte pad; push ebp; mov ebp,esp
 *
 * Anything else returns 0 and the caller reports it rather than corrupting the
 * function — which is what a careful hook library does too. */
static unsigned prologue_len5( const unsigned char *p )
{
    if (p[0] == 0xb8) return 5;                                  /* mov eax, imm32 */
    if ((p[0] == 0x66 && p[1] == 0x90) || (p[0] == 0x8b && p[1] == 0xff))
    {
        if (p[2] != 0x55) return 0;                              /* push ebp */
        if (p[3] == 0x8b && p[4] == 0xec) return 5;              /* mov ebp,esp (MS) */
        if (p[3] == 0x89 && p[4] == 0xe5) return 5;              /* mov ebp,esp (GNU) */
    }
    return 0;
}

/* Emit `E9 rel32` at `at` so that control reaches `to`.  The whole point: the
 * displacement is computed in 32-bit unsigned arithmetic and therefore wraps,
 * which is what makes a low->high or high->low detour reachable at all. */
static DWORD emit_jmp32( unsigned char *at, const void *to )
{
    DWORD disp = (DWORD)((ULONG_PTR)to - ((ULONG_PTR)at + 5));

    at[0] = 0xe9;
    at[1] = (unsigned char)(disp & 0xff);
    at[2] = (unsigned char)((disp >> 8) & 0xff);
    at[3] = (unsigned char)((disp >> 16) & 0xff);
    at[4] = (unsigned char)((disp >> 24) & 0xff);
    return disp;
}

/* Build `<displaced bytes> ; E9 -> target+n` in `tramp`. */
static void build_trampoline( unsigned char *tramp, const unsigned char *target, unsigned n )
{
    unsigned k;
    for (k = 0; k < n; k++) tramp[k] = target[k];
    emit_jmp32( tramp + n, target + n );
}

/* `mov eax, imm32 ; ret` — six bytes whose first instruction is exactly the
 * five-byte shape a detour displaces. */
static void write_stub( unsigned char *p, unsigned int imm )
{
    p[0] = 0xb8;
    p[1] = (unsigned char)(imm & 0xff);
    p[2] = (unsigned char)((imm >> 8) & 0xff);
    p[3] = (unsigned char)((imm >> 16) & 0xff);
    p[4] = (unsigned char)((imm >> 24) & 0xff);
    p[5] = 0xc3;
}

/* ---------------------------------------------------------- the handlers */

typedef ULONG (WINAPI *noarg_fn)(void);

static volatile LONG handler_ran;
static noarg_fn orig_low;               /* phase 1 trampoline */
static noarg_fn orig_high;              /* phase 2 trampoline */
static noarg_fn orig_sys;               /* phases 3 and 4 trampoline */

static ULONG WINAPI handler_low(void)   { handler_ran = 1; return orig_low() + 1; }
static ULONG WINAPI handler_high(void)  { handler_ran = 1; return orig_high() + 1; }
static ULONG WINAPI handler_sys(void)   { handler_ran = 1; return orig_sys(); }

static ULONG call_guarded( noarg_fn fn )
{
    ULONG r;
    fault_seen = 0;
    fault_expected = 1;
    r = fn();
    fault_expected = 0;
    return r;
}

/* Reserve+commit one RWX block at an explicit base above 2 GB.  An explicit
 * base is deliberate: it is the one request a placement policy cannot redirect,
 * so this asks about the process CEILING and nothing else.  Walks up so a
 * single occupied slot does not decide the phase. */
static unsigned char *alloc_high_page(void)
{
    ULONG_PTR a;

    for (a = 0x90000000u; a < 0xf0000000u; a += 0x4000000u)
    {
        unsigned char *p = VirtualAlloc( (void *)a, 0x10000, MEM_RESERVE | MEM_COMMIT,
                                         PAGE_EXECUTE_READWRITE );
        if (p) return p;
    }
    return NULL;
}

/* ------------------------------------------------------- phases 3 and 4 */

/* Candidates per pass, tried in order until one has a prologue this test can
 * relocate in five bytes.  Every name here is a NO-ARGUMENT, side-effect-free
 * export, and each list is two deep so that one toolchain's choice of prologue
 * for one function cannot decide the phase.  Pass 0 wants the native-API stub
 * shape (`mov eax, imm32`), pass 1 the hot-patch shape; the first candidate in
 * each list carries that shape in both a Microsoft-built and a Wine-built
 * 32-bit ntdll, which is what makes the same binary meaningful in both. */
static const char * const sys_names[2][3] = {
    { "NtGetCurrentProcessorNumber", "NtYieldExecution",          NULL },
    { "RtlGetSystemTimePrecise",     "RtlGetLongestNtPathLength", NULL },
};

static unsigned phase_system_export( HMODULE ntdll, unsigned pass, unsigned char *tramp_sys )
{
    unsigned char *target = NULL, saved[8], readback[8];
    MEMORY_BASIC_INFORMATION mbi;
    DWORD old_prot = 0, tmp_prot = 0, disp_fwd;
    unsigned k, n = 0, c;
    ULONG r;

    for (c = 0; c < 3 && sys_names[pass][c]; c++)
    {
        target = (unsigned char *)GetProcAddress( ntdll, sys_names[pass][c] );
        if (!target) continue;

        /* the precheck every hook library makes before touching anything */
        memset( &mbi, 0, sizeof(mbi) );
        VirtualQuery( target, &mbi, sizeof(mbi) );
        line_hex3( "MADEIRA-HOOKJMP: export=", (unsigned)(ULONG_PTR)target,
                   " state=", (unsigned)mbi.State, " protect=", (unsigned)mbi.Protect, "" );
        if (mbi.State != MEM_COMMIT || !(mbi.Protect & 0xf0))
        {
            line_0( "MADEIRA-HOOKJMP: the export's page does not report committed+executable "
                    "— a hook library refuses here and never patches" );
            return 68;
        }
        if ((n = prologue_len5( target )) == 5) break;
        line_hex( "MADEIRA-HOOKJMP: candidate has an unrelocatable prologue, first byte=",
                  (unsigned)target[0], " — trying the next one" );
    }
    if (!target) { line_0( "MADEIRA-HOOKJMP: GetProcAddress failed for every candidate" ); return 67; }
    if (n != 5)
    {
        line_0( "MADEIRA-HOOKJMP: no candidate export has a 5-byte relocatable prologue" );
        return 69;
    }
    for (k = 0; k < 5; k++) saved[k] = target[k];

    if (!VirtualProtect( target, 8, PAGE_EXECUTE_READWRITE, &old_prot ))
    {
        line_hex( "MADEIRA-HOOKJMP: VirtualProtect failed, err=", GetLastError(), "" );
        return 70;
    }

    build_trampoline( tramp_sys, target, 5 );
    orig_sys = (noarg_fn)tramp_sys;
    disp_fwd = emit_jmp32( target, (const void *)handler_sys );

    /* a page that reports writable and silently drops stores is invisible to
     * every other check, so read the bytes back before trusting them */
    for (k = 0; k < 5; k++) readback[k] = target[k];
    VirtualProtect( target, 8, old_prot, &tmp_prot );
    FlushInstructionCache( GetCurrentProcess(), target, 8 );
    if (readback[0] != 0xe9 ||
        readback[1] != (unsigned char)(disp_fwd & 0xff) ||
        readback[4] != (unsigned char)((disp_fwd >> 24) & 0xff))
    {
        line_hex( "MADEIRA-HOOKJMP: the patch did not read back, byte0=",
                  (unsigned)readback[0], "" );
        return 71;
    }
    line_hex3( "MADEIRA-HOOKJMP: patched export=", (unsigned)(ULONG_PTR)target,
               " handler=", (unsigned)(ULONG_PTR)handler_sys,
               " forward rel32=", (unsigned)disp_fwd, "" );

    handler_ran = 0;
    r = call_guarded( (noarg_fn)target );
    /* handler_ran FIRST: if the forward E9 arrived and the trampoline then
     * faulted, fault_seen is also set, and testing it first would blame the
     * wrong half of the detour. */
    if (!handler_ran)
    {
        line_hex( "MADEIRA-HOOKJMP: the detoured export did not reach the handler, r=",
                  (unsigned)r, "" );
        return pass ? 75 : 72;
    }
    /* The trampoline is `<displaced bytes> ; E9 -> export+5`; had the backward
     * jump not arrived we would have faulted, and the VEH answers AV_SENTINEL. */
    if (fault_seen || r == AV_SENTINEL)
    {
        line_0( "MADEIRA-HOOKJMP: the trampoline did not reach the original code" );
        return pass ? 76 : 73;
    }
    line_hex( "MADEIRA-HOOKJMP: detoured export returned ", (unsigned)r,
              " through the trampoline" );

    /* restore, and prove the restore landed */
    if (!VirtualProtect( target, 8, PAGE_EXECUTE_READWRITE, &old_prot ))
    {
        line_0( "MADEIRA-HOOKJMP: VirtualProtect for restore failed" );
        return 70;
    }
    for (k = 0; k < 5; k++) target[k] = saved[k];
    for (k = 0; k < 5; k++) readback[k] = target[k];
    VirtualProtect( target, 8, old_prot, &tmp_prot );
    FlushInstructionCache( GetCurrentProcess(), target, 8 );
    for (k = 0; k < 5; k++)
        if (readback[k] != saved[k])
        {
            line_hex( "MADEIRA-HOOKJMP: the restore did not read back, byte0=",
                      (unsigned)readback[0], "" );
            return 74;
        }
    handler_ran = 0;
    r = call_guarded( (noarg_fn)target );
    if (fault_seen || handler_ran)
    {
        line_0( "MADEIRA-HOOKJMP: the export still runs the detour after restore" );
        return 74;
    }
    line_0( "MADEIRA-HOOKJMP: export restored and running its own code again" );
    return 0;
}

/* ---------------------------------------------------------------- entry */

static unsigned run_all(void)
{
    unsigned char *low, *tramp_low, *tramp_high, *tramp_sys, *high;
    HMODULE ntdll;
    unsigned skipped_high = 0, pass, rc;
    ULONG r;

    line_0( "MADEIRA-HOOKJMP: start (inline detour / rel32 wrap self-test)" );

    if (!AddVectoredExceptionHandler( 1, veh ))
    {
        line_0( "MADEIRA-HOOKJMP: AddVectoredExceptionHandler failed" );
        return 77;
    }

    /* one low RWX block holds the phase-1 stub, the AV stub and the trampolines */
    low = VirtualAlloc( NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    if (!low) { line_0( "MADEIRA-HOOKJMP: VirtualAlloc(low) failed" ); return 62; }
    av_stub    = low + 0x100;
    tramp_low  = low + 0x200;
    tramp_high = low + 0x300;
    tramp_sys  = low + 0x400;
    write_stub( av_stub, AV_SENTINEL );

    /* ------------------------------------------------ phase 1: both ends low */
    write_stub( low, STUB_MAGIC );
    build_trampoline( tramp_low, low, 5 );
    orig_low = (noarg_fn)tramp_low;
    line_hex3( "MADEIRA-HOOKJMP: phase 1 stub=", (unsigned)(ULONG_PTR)low,
               " handler=", (unsigned)(ULONG_PTR)handler_low,
               " forward rel32=", (unsigned)emit_jmp32( low, (const void *)handler_low ), "" );
    FlushInstructionCache( GetCurrentProcess(), low, 0x1000 );
    handler_ran = 0;
    r = call_guarded( (noarg_fn)low );
    if (!handler_ran)        /* see phase_system_export: this order names the right half */
    {
        line_hex( "MADEIRA-HOOKJMP: phase 1 handler did not run, r=", (unsigned)r, "" );
        return 63;
    }
    if (fault_seen || r != STUB_MAGIC + 1)
    {
        line_hex( "MADEIRA-HOOKJMP: phase 1 trampoline wrong, r=", (unsigned)r, "" );
        return 64;
    }
    line_0( "MADEIRA-HOOKJMP: phase 1 OK — detour and trampoline both arrived (low -> low)" );

    /* ------------------------------------------- phase 2: the stub above 2 GB */
    high = alloc_high_page();
    if (!high)
    {
        skipped_high = 1;
        line_0( "MADEIRA-HOOKJMP: phase 2 SKIPPED — no page above 2 GB could be reserved "
                "(a 2 GB user space; the expected result with MADEIRA_LAA=0)" );
    }
    else
    {
        write_stub( high, STUB_MAGIC );
        build_trampoline( tramp_high, high, 5 );
        orig_high = (noarg_fn)tramp_high;
        line_hex3( "MADEIRA-HOOKJMP: phase 2 stub=", (unsigned)(ULONG_PTR)high,
                   " handler=", (unsigned)(ULONG_PTR)handler_high,
                   " forward rel32=",
                   (unsigned)emit_jmp32( high, (const void *)handler_high ),
                   " (reaches only modulo 2^32)" );
        FlushInstructionCache( GetCurrentProcess(), high, 0x1000 );
        handler_ran = 0;
        r = call_guarded( (noarg_fn)high );
        if (!handler_ran)
        {
            line_hex( "MADEIRA-HOOKJMP: phase 2 handler did not run, r=", (unsigned)r, "" );
            return 65;
        }
        if (fault_seen || r != STUB_MAGIC + 1)
        {
            line_hex( "MADEIRA-HOOKJMP: phase 2 trampoline wrong, r=", (unsigned)r, "" );
            return 66;
        }
        line_0( "MADEIRA-HOOKJMP: phase 2 OK — a detour whose two ends straddle 0x80000000 "
                "arrived in both directions" );
    }

    /* ------------------------------- phases 3 and 4: a real system DLL export */
    ntdll = GetModuleHandleA( "ntdll.dll" );
    if (!ntdll) { line_0( "MADEIRA-HOOKJMP: GetModuleHandleA(ntdll.dll) failed" ); return 67; }
    line_hex( "MADEIRA-HOOKJMP: ntdll base=", (unsigned)(ULONG_PTR)ntdll,
              " (a base above 0x80000000 means this port placed it in the high half)" );

    for (pass = 0; pass < 2; pass++)
        if ((rc = phase_system_export( ntdll, pass, tramp_sys ))) return rc;

    if (skipped_high)
    {
        line_0( "MADEIRA-HOOKJMP: all checks passed, phase 2 skipped (2 GB user space)" );
        return 61;
    }
    line_0( "MADEIRA-HOOKJMP: all checks passed" );
    return 60;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
