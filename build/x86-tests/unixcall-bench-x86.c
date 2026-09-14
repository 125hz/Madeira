/* MADEIRA-TEMP: WOW64_DESIGN.md section 8.4, measurement 2 -- what does ONE
 * unix call cost a 32-bit guest?
 *
 * Section 8 proposes moving the Direct3D 9 frontend to a native ARM64 unixlib
 * behind a thin i386 shim, and section 8.4 says the viability of doing that
 * SYNCHRONOUSLY is (D3D9 calls per frame) x (cost of one unix call). It
 * estimates that cost at 150-400 ns from the code path -- bridge page
 * (FEX/Source/Windows/WOW64/Module.cpp:1137) -> JIT exit + SpillStaticRegs ->
 * HandleSyscallImpl (:725-775) -> UnlockJITContext -> WineUnixCall -> the
 * dispatch table -> LockJITContext (a CAS, plus a possible WOW_CPU_AREA_DIRTY
 * reload) -> FillStaticRegs -- and then says, in terms: do not build on the
 * estimate. This program replaces it with a number.
 *
 * It calls winemetal.dll's WMTNop() a million times. WMTNop is slot 150, whose
 * unix handler (`_d3d9_nop`, research/dxmt/src/winemetal/unix/winemetal_unix.c)
 * returns STATUS_SUCCESS and does nothing else, so what the loop measures is
 * the crossing itself with no work hiding inside it. Two reference loops run
 * alongside it for scale:
 *
 *   - a plain in-process function call, which stays inside the JIT and never
 *     leaves the guest at all. This is the floor: the difference between it
 *     and the unix call IS the cost of the boundary.
 *   - GetTickCount(), as section 8.4 asks for. Read the printed number with
 *     care rather than as "a syscall": under Wine, GetTickCount normally reads
 *     the shared user-data page in user mode and traps only if that page is
 *     unavailable, so on this runtime it is usually a THIRD point between the
 *     other two -- an intra-guest cross-DLL call -- not a kernel transition.
 *     The output labels it for what it measures rather than for what it is
 *     assumed to be.
 *
 * The headline line, the one section 8.4 needs, is exactly:
 *
 *     MADEIRA-BENCH: unix-call ns/call = N
 *
 * Deliberate restrictions, the same ones d3d9-cube-x86.c works under:
 *   - No CRT. This file supplies its own PE entry point (`start`, which the
 *     i386 Windows C ABI mangles to `_start`) and its own memset/memcpy, and
 *     links -nostdlib, so its only import is kernel32 -- Wine-supplied, and
 *     asserted by the build script. winemetal.dll is reached with
 *     LoadLibraryA/GetProcAddress rather than an import, because llvm-mingw
 *     ships no import library for it and because an unresolved import would
 *     fail the process at load time with nothing printed.
 *   - No 64-bit integer division or int-to-double conversion: -nostdlib leaves
 *     no compiler-rt to satisfy a __divdi3/__floatdidf helper. ll_to_double()
 *     below does the conversion with 32-bit pieces, as the cube does.
 *
 * Exit status (reported by the runtime as "MADEIRA-EXIT: ... status=<n>"):
 *   44  success -- all three loops ran and the numbers were printed
 *   45  winemetal.dll would not load
 *   46  winemetal.dll has no WMTNop export (an old DLL: the slot is new)
 *   47  QueryPerformanceFrequency returned 0, so nothing can be timed
 *   48  the unix-call loop measured an implausibly small time, which means the
 *       call did not actually reach the unix side -- reporting 0.0 ns/call as
 *       a result would be worse than failing
 */
#include <stddef.h>
#include <windows.h>

/* One million, as section 8.4's measurement asks for. Large enough that the
 * QPC read at each end is noise, small enough to finish in well under a second
 * even at the pessimistic end of the 150-400 ns estimate. */
#define ITERATIONS 1000000u

/* Enough to fault in the DLL, warm the JIT for the call sequence, and let the
 * bridge page's first-use work happen outside the timed region. */
#define WARMUP 10000u

/* Only used to turn the measured ns/call into the ms/frame number section 8.4
 * reasons with. [d3d9-census] replaces this assumption with a real count; the
 * line is printed so the two can be multiplied without a calculator. */
#define ASSUMED_CALLS_PER_FRAME 13000u

typedef void (__cdecl *pfn_nop)( unsigned __int64 a, unsigned __int64 b );

/* -nostdlib: clang may still lower a struct initialisation to a memset or
 * memcpy call, so provide them rather than hoping it does not. */
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

/* Prints a non-negative double with a fixed number of decimal digits, rounded
 * to nearest -- no CRT snprintf/dtoa available. Saturates rather than wrapping,
 * because a wrapped number in a benchmark result reads as a real measurement. */
static char *put_fixed( char *p, double v, int decimals )
{
    double scale = 1.0;
    double scaled;
    unsigned int whole, frac, d, uscale = 1;
    int i;

    if (!(v >= 0.0)) v = 0.0;                 /* also catches NaN */
    for (i = 0; i < decimals; i++) { scale *= 10.0; uscale *= 10u; }
    scaled = v * scale + 0.5;
    if (scaled > 4294967000.0) scaled = 4294967000.0;
    whole = (unsigned int)(scaled / scale);
    frac  = (unsigned int)scaled % uscale;

    p = put_uint( p, whole );
    *p++ = '.';
    d = uscale / 10u;
    while (d)
    {
        *p++ = (char)('0' + (frac / d) % 10u);
        d /= 10u;
    }
    return p;
}

/* Converts a 64-bit tick delta to a double using only 32-bit-to-double
 * conversions (all native, no compiler-rt call): -nostdlib means a direct
 * (double)(LONGLONG) cast could silently need a __floatdidf helper we cannot
 * link. Same helper as d3d9-cube-x86.c's. */
static double ll_to_double( LONGLONG v )
{
    LONG  hi = (LONG)(v >> 32);
    DWORD lo = (DWORD)(v & 0xFFFFFFFFu);
    return (double)hi * 4294967296.0 + (double)lo;
}

static void log_result( const char *label, double ns, double total_ms )
{
    char buf[192];
    char *p = buf;
    p = put_str( p, "MADEIRA-BENCH: " );
    p = put_str( p, label );
    p = put_str( p, " ns/call = " );
    p = put_fixed( p, ns, 1 );
    p = put_str( p, "   (" );
    p = put_uint( p, ITERATIONS );
    p = put_str( p, " calls in " );
    p = put_fixed( p, total_ms, 3 );
    p = put_str( p, " ms)\n" );
    *p = 0;
    out_str( buf );
}

static void log_note( const char *s )
{
    char buf[256];
    char *p = buf;
    p = put_str( p, "MADEIRA-BENCH: " );
    p = put_str( p, s );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------ the loops */

/* The in-process reference. `volatile` on the sink and `noinline` on the
 * callee together stop the compiler from hoisting the loop away -- an elided
 * loop would report a few picoseconds per call and look like a spectacular
 * result rather than a missing measurement. */
static volatile unsigned int g_sink;

__attribute__((noinline)) static void local_nop( unsigned __int64 a, unsigned __int64 b )
{
    g_sink += (unsigned int)(a + b);
}

/* ---------------------------------------------------------------- main */

void start( void )
{
    HMODULE winemetal;
    pfn_nop nop;
    LARGE_INTEGER freq, t0, t1;
    double freq_d, ns_unix, ns_local, ns_tick, ms_unix, ms_local, ms_tick;
    unsigned int i;

    out_str( "MADEIRA-BENCH: 32-bit unix-call benchmark starting\n" );

    if (!QueryPerformanceFrequency( &freq ) || !freq.QuadPart)
    {
        log_note( "QueryPerformanceFrequency returned 0; nothing can be timed" );
        ExitProcess( 47 );
    }
    freq_d = ll_to_double( freq.QuadPart );

    winemetal = LoadLibraryA( "winemetal.dll" );
    if (!winemetal)
    {
        log_note( "LoadLibraryA(winemetal.dll) failed" );
        ExitProcess( 45 );
    }
    /* mingw exports a cdecl __declspec(dllexport) undecorated, and the i386
     * DXMT build additionally links with -Wl,--kill-at; try the decorated
     * spelling too rather than assume which one survived. */
    nop = (pfn_nop)GetProcAddress( winemetal, "WMTNop" );
    if (!nop) nop = (pfn_nop)GetProcAddress( winemetal, "_WMTNop" );
    if (!nop)
    {
        log_note( "winemetal.dll has no WMTNop export -- rebuild DXMT's PE side" );
        ExitProcess( 46 );
    }

    /* Warm-up, outside every timed region: first-touch faults on the DLL's
     * pages, the JIT's first translation of this loop, and the bridge page's
     * first crossing all belong to setup, not to the steady-state cost. */
    for (i = 0; i < WARMUP; i++) nop( i, 1 );
    for (i = 0; i < WARMUP; i++) local_nop( i, 1 );
    for (i = 0; i < WARMUP; i++) g_sink += GetTickCount();

    /* -------- 1. the unix call (the number section 8.4 is waiting for) */
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < ITERATIONS; i++) nop( i, 1 );
    QueryPerformanceCounter( &t1 );
    ms_unix = ll_to_double( t1.QuadPart - t0.QuadPart ) / freq_d * 1000.0;
    ns_unix = ms_unix * 1000000.0 / (double)ITERATIONS;

    /* -------- 2. a plain in-process call: the floor */
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < ITERATIONS; i++) local_nop( i, 1 );
    QueryPerformanceCounter( &t1 );
    ms_local = ll_to_double( t1.QuadPart - t0.QuadPart ) / freq_d * 1000.0;
    ns_local = ms_local * 1000000.0 / (double)ITERATIONS;

    /* -------- 3. GetTickCount, for scale (see the header comment) */
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < ITERATIONS; i++) g_sink += GetTickCount();
    QueryPerformanceCounter( &t1 );
    ms_tick = ll_to_double( t1.QuadPart - t0.QuadPart ) / freq_d * 1000.0;
    ns_tick = ms_tick * 1000000.0 / (double)ITERATIONS;

    log_result( "unix-call", ns_unix, ms_unix );
    log_result( "local-call", ns_local, ms_local );
    log_result( "GetTickCount", ns_tick, ms_tick );

    {
        char buf[256];
        char *p = buf;
        p = put_str( p, "boundary cost = " );
        p = put_fixed( p, ns_unix > ns_local ? ns_unix - ns_local : 0.0, 1 );
        p = put_str( p, " ns (unix-call minus local-call); at " );
        p = put_uint( p, ASSUMED_CALLS_PER_FRAME );
        p = put_str( p, " calls/frame that is " );
        p = put_fixed( p, ns_unix * (double)ASSUMED_CALLS_PER_FRAME / 1000000.0, 2 );
        p = put_str( p, " ms/frame" );
        *p = 0;
        log_note( buf );
    }
    log_note( "GetTickCount is NOT necessarily a kernel transition on this "
              "runtime -- Wine usually serves it from the shared user-data "
              "page; treat it as a cross-DLL guest call unless proven otherwise" );

    /* A crossing that costs less than a nanosecond did not happen. Failing is
     * the honest outcome: the alternative is a plausible-looking 0.0 that
     * section 8.5 would then be designed around. */
    if (ns_unix < 1.0)
    {
        log_note( "the unix-call loop measured under 1 ns/call -- the call did "
                  "not reach the unix side" );
        ExitProcess( 48 );
    }

    out_str( "MADEIRA-BENCH: done\n" );
    ExitProcess( 44 );
}
