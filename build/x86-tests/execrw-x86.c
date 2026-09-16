/* MADEIRA-TEMP: the DEP-policy self-test — execrw-x86.exe / execrw-nx-x86.exe.
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * On Windows a 32-bit image WITHOUT IMAGE_DLLCHARACTERISTICS_NX_COMPAT runs with DEP
 * disabled: executing from ANY committed readable page is legal.  Essentially every
 * pre-Vista 32-bit program is built that way, and a large fraction of them depend on it —
 * copy-protection wrappers, self-decrypting unpackers and runtime thunk generators all
 * write machine code into ordinary PAGE_READWRITE memory and jump into it.
 *
 * On this port nothing host-executes a guest page: guest code is decoded by the emulator
 * and run out of the JIT pool, so "is this page executable" is a question answered by the
 * emulator's own bookkeeping rather than by the MMU.  That bookkeeping has to be told about
 * DEP, and it has to be told again every time such a page appears.  When it is not, the
 * frontend decodes the target as non-executable, raises its no-exec trap, and the thread
 * dies on what looks like a null dereference.  This file is the regression test for that
 * whole chain — the loader's NX_COMPAT check, its NtSetInformationProcess(ProcessExecuteFlags),
 * the wow64 notification, the emulator's promotion of the page, the write-trap that keeps
 * self-modifying code correct, and the runtime opt-in through SetProcessDEPPolicy.
 *
 * ONE SOURCE, TWO IMAGES.  The expectations are the exact opposite in the two DEP modes, and
 * the mode is a property of the IMAGE, so the program reads its OWN PE header rather than
 * being told by a #define — an exe that was linked with the wrong flag then fails loudly
 * instead of silently testing the other half.
 *
 *   execrw-x86.exe      linked --disable-nxcompat : DEP off.  Executing written-to
 *                       PAGE_READWRITE memory must WORK, including after rewriting it.
 *   execrw-nx-x86.exe   linked --nxcompat         : DEP on.   The same call must raise
 *                       STATUS_ACCESS_VIOLATION, and specifically an EXECUTE fault
 *                       (ExceptionInformation[0] == 8) at the address jumped to.
 *
 * THE PHASES (DEP-off image runs all of them; DEP-on image runs 1 and stops)
 *
 *   1. VirtualAlloc PAGE_READWRITE, write `mov eax,42 ; ret`, call through a function
 *      pointer.  The base case, and the one the device died on.
 *   2. SELF-MODIFYING: rewrite the immediate to 43 and call again WITHOUT any
 *      FlushInstructionCache, then 64 more rewrite-and-call rounds.  A cached translation
 *      of the old bytes returns the old value, so this fails loudly if the write-trap that
 *      invalidates translated code is not armed on a DEP-promoted page.  The deliberate
 *      absence of a cache flush is the point: an unpacker does not issue one either.
 *   3. HEAP: the same stub in HeapAlloc'd memory.  DEP-off applies to every committed
 *      readable page, not only to VirtualAlloc'd ones, and the heap reaches the emulator
 *      through a different notification than a fresh reservation does.
 *   4. RESERVE-THEN-COMMIT: MEM_RESERVE a region, MEM_COMMIT one page of it later, and
 *      execute from that.  Covers the commit-time path rather than the reserve-time one.
 *   5. RUNTIME OPT-IN: SetProcessDEPPolicy(PROCESS_DEP_ENABLE) turns DEP back ON for a
 *      process that started without it.  Every page promoted in phases 1-4 must stop being
 *      executable, so the first call afterwards must raise an execute access violation.
 *
 * HOW THE ACCESS VIOLATION IS CAUGHT.  There is no CRT and no __try here (clang's SEH is not
 * available for 32-bit x86), so recovery is a vectored exception handler that redirects Eip
 * to a tiny stub which just returns a sentinel.  The faulting instruction is the first byte
 * of the callee, so the stack is exactly as a called function expects it and the stub's
 * `ret` unwinds correctly.  The handler only claims faults inside the code buffer, and only
 * while a fault is expected, so a genuine bug elsewhere is still fatal and still reported.
 *
 * Deliberate restrictions, as in the other tests here: no CRT (this file supplies `start'
 * plus memset/memcpy and links -nostdlib, so its only import is kernel32), no 64-bit
 * division, no int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *
 *   52  PASS — every phase for this image's DEP mode behaved correctly
 *   40  VirtualAlloc(PAGE_READWRITE) failed
 *   41  DEP off: the call returned the wrong value
 *   42  DEP off: the call raised an access violation (DEP-off promotion is not happening)
 *   43  DEP on:  the call SUCCEEDED (DEP is not being enforced)
 *   44  DEP on:  a fault, but not an execute fault at the address jumped to
 *   45  DEP off: the single self-modifying rewrite returned the OLD value (stale translation)
 *   46  DEP off: the self-modifying loop returned a wrong value
 *   47  DEP off: executing from heap memory failed
 *   48  DEP off: executing from separately-committed memory failed
 *   49  SetProcessDEPPolicy(PROCESS_DEP_ENABLE) failed
 *   50  GetProcessDEPPolicy did not report DEP enabled afterwards
 *   51  DEP enabled at runtime, yet the call still succeeded
 *   53  AddVectoredExceptionHandler failed
 *   54  could not read this image's own PE header
 */

#include <stddef.h>
#include <windows.h>

#ifndef PROCESS_DEP_ENABLE
#define PROCESS_DEP_ENABLE 0x00000001
#endif

#define SMC_ROUNDS 64u
#define AV_SENTINEL 0x5A5AF00D

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

static void line_hex( const char *a, unsigned int v, const char *b )
{
    char buf[256], *p = buf;
    p = put_str( p, a );
    p = put_hex( p, v );
    p = put_str( p, b );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------- fault interception */

typedef int (__cdecl *codefn)(void);

static volatile DWORD guard_lo, guard_hi;   /* the code buffer faults are expected in */
static volatile LONG  expect_av;            /* non-zero while a fault is expected */
static volatile LONG  av_seen;              /* faults claimed by the handler */
static volatile DWORD av_addr;              /* ExceptionAddress of the last one */
static volatile DWORD av_kind;              /* ExceptionInformation[0]: 0 read, 1 write, 8 exec */
static volatile DWORD av_target;            /* ExceptionInformation[1] */

/* Reached only by the handler redirecting Eip here.  The faulting instruction was the
 * callee's first byte, so the stack still holds exactly the return address a __cdecl
 * function with no arguments expects, and this returns to the caller normally. */
static int __cdecl av_recover(void)
{
    return AV_SENTINEL;
}

static LONG CALLBACK exec_veh( EXCEPTION_POINTERS *ep )
{
    EXCEPTION_RECORD *rec = ep->ExceptionRecord;
    DWORD at;

    if (rec->ExceptionCode != (DWORD)EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_CONTINUE_SEARCH;
    if (!expect_av) return EXCEPTION_CONTINUE_SEARCH;

    at = (DWORD)(ULONG_PTR)rec->ExceptionAddress;
    /* Only faults raised BY the code buffer are ours.  A fault raised by our own .text while
     * writing to the buffer (which would mean the write-trap leaked through to the guest) is
     * deliberately left unhandled, so it is reported rather than papered over. */
    if (at < guard_lo || at >= guard_hi) return EXCEPTION_CONTINUE_SEARCH;

    av_seen++;
    av_addr   = at;
    av_kind   = rec->NumberParameters >= 1 ? (DWORD)rec->ExceptionInformation[0] : 0xffffffffu;
    av_target = rec->NumberParameters >= 2 ? (DWORD)rec->ExceptionInformation[1] : 0;
    ep->ContextRecord->Eip = (DWORD)(ULONG_PTR)av_recover;
    return EXCEPTION_CONTINUE_EXECUTION;
}

/* Call `fn`, tolerating an access violation raised at its entry.  Returns the function's
 * value, or AV_SENTINEL when it faulted. */
static int call_guarded( codefn fn, void *base, unsigned int size )
{
    int r;

    guard_lo  = (DWORD)(ULONG_PTR)base;
    guard_hi  = guard_lo + size;
    expect_av = 1;
    r = fn();
    expect_av = 0;
    return r;
}

/* ------------------------------------------------------------- code emission */

/* mov eax, <imm32> ; ret  — the whole program under test. */
static void emit_stub( void *dst, unsigned int value )
{
    unsigned char *p = dst;
    p[0] = 0xb8;
    p[1] = (unsigned char)(value      );
    p[2] = (unsigned char)(value >>  8);
    p[3] = (unsigned char)(value >> 16);
    p[4] = (unsigned char)(value >> 24);
    p[5] = 0xc3;
}

/* Rewrite only the immediate, leaving the opcode in place — the shape a self-patching
 * thunk actually has, and the one that most needs the translation to be invalidated. */
static void patch_stub( void *dst, unsigned int value )
{
    unsigned char *p = dst;
    p[1] = (unsigned char)(value      );
    p[2] = (unsigned char)(value >>  8);
    p[3] = (unsigned char)(value >> 16);
    p[4] = (unsigned char)(value >> 24);
}

/* ------------------------------------------------------------ own PE header */

/* Non-zero when this image declares IMAGE_DLLCHARACTERISTICS_NX_COMPAT, i.e. DEP is on.
 * Returns -1 when the header could not be read. */
static int image_is_nx_compat(void)
{
    const unsigned char *base = (const unsigned char *)GetModuleHandleA( NULL );
    const IMAGE_DOS_HEADER *dos;
    const IMAGE_NT_HEADERS32 *nt;

    if (!base) return -1;
    dos = (const IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return -1;
    nt = (const IMAGE_NT_HEADERS32 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return -1;
    return (nt->OptionalHeader.DllCharacteristics & IMAGE_DLLCHARACTERISTICS_NX_COMPAT) ? 1 : 0;
}

/* --------------------------------------------------------------- the phases */

static void *page;          /* phase 1/2/5 buffer */
static SIZE_T page_size = 0x1000;

static int phase_basic( int nx )
{
    int r;

    page = VirtualAlloc( NULL, page_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    if (!page) { line_0( "MADEIRA-EXECRW: VirtualAlloc(PAGE_READWRITE) failed" ); return 40; }
    line_hex( "MADEIRA-EXECRW: buffer at ", (unsigned int)(ULONG_PTR)page, " (PAGE_READWRITE)" );

    emit_stub( page, 42 );
    /* The one flush in this file: a well-behaved program issues it after generating code,
     * and phase 2 then proves the emulator does not NEED it. */
    FlushInstructionCache( GetCurrentProcess(), page, 6 );

    av_seen = 0;
    r = call_guarded( (codefn)page, page, (unsigned int)page_size );

    if (!nx)
    {
        if (r == AV_SENTINEL)
        {
            line_hex( "MADEIRA-EXECRW: DEP is OFF but the call FAULTED, kind=", av_kind,
                      " (8 = execute) — the page was never promoted to executable" );
            return 42;
        }
        if (r != 42) { line_1( "MADEIRA-EXECRW: call returned ", (unsigned int)r, ", expected 42" ); return 41; }
        line_0( "MADEIRA-EXECRW: phase 1 OK — executed from PAGE_READWRITE memory, returned 42" );
        return 0;
    }

    if (r != AV_SENTINEL)
    {
        line_1( "MADEIRA-EXECRW: DEP is ON yet the call SUCCEEDED and returned ", (unsigned int)r,
                " — DEP is not being enforced" );
        return 43;
    }
    if (av_seen != 1 || av_kind != 8 || av_addr != (DWORD)(ULONG_PTR)page)
    {
        line_1( "MADEIRA-EXECRW: faulted, but seen=", (unsigned int)av_seen, " times" );
        line_hex( "MADEIRA-EXECRW:   kind=", av_kind, " (expected 8 = execute)" );
        line_hex( "MADEIRA-EXECRW:   at=", av_addr, "" );
        line_hex( "MADEIRA-EXECRW:   expected at=", (unsigned int)(ULONG_PTR)page, "" );
        return 44;
    }
    line_0( "MADEIRA-EXECRW: phase 1 OK — DEP on, execute access violation raised at the target" );
    return 0;
}

static int phase_smc(void)
{
    unsigned int i;
    int r;

    /* No FlushInstructionCache anywhere below: this is the unpacker's actual behaviour, and
     * detecting it is what the write-trap on a DEP-promoted page exists for. */
    patch_stub( page, 43 );
    r = call_guarded( (codefn)page, page, (unsigned int)page_size );
    if (r != 43)
    {
        line_1( "MADEIRA-EXECRW: after rewriting the immediate the call returned ", (unsigned int)r,
                ", expected 43 (a stale translation of the old bytes)" );
        return 45;
    }

    for (i = 0; i < SMC_ROUNDS; i++)
    {
        patch_stub( page, 1000 + i );
        r = call_guarded( (codefn)page, page, (unsigned int)page_size );
        if (r != (int)(1000 + i))
        {
            line_1( "MADEIRA-EXECRW: self-modifying round ", i, " returned the wrong value" );
            line_1( "MADEIRA-EXECRW:   got ", (unsigned int)r, "" );
            line_1( "MADEIRA-EXECRW:   expected ", 1000 + i, "" );
            return 46;
        }
    }
    line_1( "MADEIRA-EXECRW: phase 2 OK — ", SMC_ROUNDS + 1,
            " self-modifying rewrites all executed the NEW bytes" );
    return 0;
}

static int phase_heap(void)
{
    HANDLE heap = GetProcessHeap();
    void *block;
    int r;

    block = HeapAlloc( heap, 0, 256 );
    if (!block) { line_0( "MADEIRA-EXECRW: HeapAlloc failed" ); return 47; }

    emit_stub( block, 44 );
    r = call_guarded( (codefn)block, block, 256 );
    if (r != 44)
    {
        line_hex( "MADEIRA-EXECRW: executing from heap memory at ", (unsigned int)(ULONG_PTR)block,
                  " failed" );
        line_1( "MADEIRA-EXECRW:   returned ", (unsigned int)r, ", expected 44" );
        HeapFree( heap, 0, block );
        return 47;
    }
    HeapFree( heap, 0, block );
    line_0( "MADEIRA-EXECRW: phase 3 OK — executed from heap memory" );
    return 0;
}

static int phase_late_commit(void)
{
    void *reserved, *committed;
    int r;

    reserved = VirtualAlloc( NULL, 0x10000, MEM_RESERVE, PAGE_NOACCESS );
    if (!reserved) { line_0( "MADEIRA-EXECRW: MEM_RESERVE failed" ); return 48; }

    committed = VirtualAlloc( (char *)reserved + 0x2000, 0x1000, MEM_COMMIT, PAGE_READWRITE );
    if (!committed) { line_0( "MADEIRA-EXECRW: MEM_COMMIT inside the reservation failed" ); return 48; }

    emit_stub( committed, 45 );
    r = call_guarded( (codefn)committed, committed, 0x1000 );
    if (r != 45)
    {
        line_hex( "MADEIRA-EXECRW: executing from separately-committed memory at ",
                  (unsigned int)(ULONG_PTR)committed, " failed" );
        line_1( "MADEIRA-EXECRW:   returned ", (unsigned int)r, ", expected 45" );
        return 48;
    }
    line_0( "MADEIRA-EXECRW: phase 4 OK — executed from a page committed after the reservation" );
    return 0;
}

static int phase_runtime_optin(void)
{
    DWORD flags = 0;
    BOOL permanent = FALSE;
    int r;

    if (!SetProcessDEPPolicy( PROCESS_DEP_ENABLE ))
    {
        line_1( "MADEIRA-EXECRW: SetProcessDEPPolicy(PROCESS_DEP_ENABLE) failed, error ",
                (unsigned int)GetLastError(), "" );
        return 49;
    }
    if (!GetProcessDEPPolicy( GetCurrentProcess(), &flags, &permanent ) || !(flags & PROCESS_DEP_ENABLE))
    {
        line_hex( "MADEIRA-EXECRW: after enabling DEP, GetProcessDEPPolicy reports flags=", flags, "" );
        return 50;
    }
    line_0( "MADEIRA-EXECRW: DEP enabled at runtime via SetProcessDEPPolicy" );

    /* The very same buffer that phases 1 and 2 executed happily must now be refused. */
    patch_stub( page, 46 );
    av_seen = 0;
    r = call_guarded( (codefn)page, page, (unsigned int)page_size );
    if (r != AV_SENTINEL)
    {
        line_1( "MADEIRA-EXECRW: DEP was enabled at runtime, yet the call returned ",
                (unsigned int)r, " — the promotion was never withdrawn" );
        return 51;
    }
    if (av_kind != 8)
    {
        line_hex( "MADEIRA-EXECRW: faulted after enabling DEP, but kind=", av_kind,
                  " (expected 8 = execute)" );
        return 44;
    }
    line_0( "MADEIRA-EXECRW: phase 5 OK — the promoted page stopped being executable" );
    return 0;
}

/* --------------------------------------------------------------- driver */

static int run_all(void)
{
    int nx = image_is_nx_compat();
    int rc;

    if (nx < 0) { line_0( "MADEIRA-EXECRW: cannot read this image's own PE header" ); return 54; }

    if (!AddVectoredExceptionHandler( 1, exec_veh ))
    {
        line_0( "MADEIRA-EXECRW: AddVectoredExceptionHandler failed" );
        return 53;
    }

    line_0( nx ? "MADEIRA-EXECRW: image declares NX_COMPAT — DEP is ON, execute faults expected"
               : "MADEIRA-EXECRW: image has no NX_COMPAT — DEP is OFF, writable memory is executable" );

    if ((rc = phase_basic( nx ))) return rc;
    if (nx)
    {
        /* Nothing further is meaningful with DEP on: every remaining phase asserts that
         * execution SUCCEEDS.  Enforcement was the whole question, and it was answered. */
        line_0( "MADEIRA-EXECRW: all checks passed" );
        return 52;
    }

    if ((rc = phase_smc())) return rc;
    if ((rc = phase_heap())) return rc;
    if ((rc = phase_late_commit())) return rc;
    if ((rc = phase_runtime_optin())) return rc;

    line_0( "MADEIRA-EXECRW: all checks passed" );
    return 52;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
