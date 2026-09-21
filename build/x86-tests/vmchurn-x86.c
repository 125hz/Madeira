/* MADEIRA-TEMP: the guest virtual-memory churn self-test — vmchurn-x86.exe.
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * A 32-bit program that allocates in large blocks drives an enormous amount of
 * traffic through NtAllocateVirtualMemory/NtFreeVirtualMemory without ever
 * calling either by name: Wine's heap sends any block above ~508 KB straight to
 * VirtualAlloc, so a program whose working set churns half-megabyte buffers
 * makes thousands of reserve/commit/release round trips a second.  A device
 * session measured ~3,400 a second at 704 KB each.
 *
 * Every one of those goes through the global virtual mutex, a placement search,
 * a host mapping call, the view tree, the per-page protection bytes and a
 * notification into the emulator's invalidation tracker.  The obvious
 * optimisation is to keep a small cache of recently released regions and hand
 * them straight back — and the obvious optimisation is also the one that
 * silently breaks Windows' rules if it is written from the syscall names alone.
 * THIS TEST IS THAT RULE SET, written down as assertions, so a cache can be
 * built against something better than intuition:
 *
 *   - re-allocated memory MUST read back as ZERO.  A cache that hands a region
 *     back with the previous tenant's bytes in it is an information leak and a
 *     source of bugs that appear only under memory pressure.
 *   - released memory MUST FAULT if touched, and MUST report MEM_FREE.  A cache
 *     that parks a region while keeping its view answers VirtualQuery wrongly,
 *     and a program that walks its own address space (every allocator, every
 *     crash handler, every anti-debug check) sees memory it does not own.
 *   - a released range MUST be re-reservable AT ITS OWN ADDRESS.  This is the
 *     case a parked region breaks hardest: the explicit-base request collides
 *     with a reservation the program believes it gave back.
 *   - decommitted pages MUST report MEM_RESERVE, MUST fault, and MUST read back
 *     as zero when recommitted — the reserve stays, the contents do not.
 *   - the protection actually installed MUST be the protection asked for, on
 *     the first allocation and on every recycled one.
 *
 * It also TIMES the cycle, because the point of a cache is throughput and a
 * correctness test that cannot say what the baseline was is only half the
 * instrument.  The `cycle` numbers below are microseconds per full
 * reserve+commit / touch / release round trip, measured with
 * QueryPerformanceCounter, and are directly comparable between the host's own
 * WoW64 (the reference implementation) and this port.
 *
 * Nothing here is specific to any program: the sizes are the generic
 * consequence of a heap's large-block threshold, and every assertion is a
 * documented Win32 guarantee.
 *
 * HOW "THIS MUST NOT BE READABLE" IS ASKED, AND WHY NOT WITH A FAULT.  There is
 * no CRT here and clang has no SEH for 32-bit x86, so the usual recovery is
 * execrw-x86.c's: a vectored exception handler that redirects Eip to a stub
 * which returns a sentinel.  That trick is only safe when the faulting
 * instruction is the FIRST byte of a no-argument callee, because only then is
 * the stack exactly what the stub's `ret` expects — and here the fault is an
 * ordinary data load somewhere inside a function whose prologue has already
 * run, so the redirect returns through a stack that is off by a frame.  An
 * early draft of this test did exactly that and crashed on real Windows.
 *
 * So the question is asked of the KERNEL instead: ReadProcessMemory on our own
 * process returns FALSE for a page that is not readable and never raises, and
 * VirtualQuery reports the state and protection the memory manager actually
 * holds.  Between them they assert everything a fault would have, and they
 * assert it the way a crash handler or an allocator walking its own address
 * space would — which is the code that a wrong answer actually breaks.
 *
 * Deliberate restrictions, as in the other tests here: no CRT (this file
 * supplies `start' plus memset/memcpy and links -nostdlib, so its only import
 * is kernel32), no 64-bit division, no int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *
 *   80  PASS — every phase behaved as Windows requires
 *   61  phase 1: the first reserve+commit failed
 *   62  phase 1: fresh memory did not read back as zero
 *   63  phase 1: a recycled region did not read back as zero
 *   64  phase 1: a recycled region reported the wrong protection
 *   65  phase 2: VirtualQuery on released memory did not report MEM_FREE
 *   66  phase 2: released memory was still readable
 *   67  phase 3: re-reserving the released range at its own base failed
 *   68  phase 4: commit inside a reservation failed
 *   69  phase 4: VirtualQuery after decommit did not report MEM_RESERVE
 *   70  phase 4: a decommitted page was still readable
 *   71  phase 4: a recommitted page did not read back as zero
 *   72  phase 5: PAGE_READONLY memory was not readable
 *   73  phase 5: VirtualQuery reported a protection that was not asked for
 *   74  a VirtualAlloc failed part way through the timed churn loop
 */

#include <stddef.h>
#include <windows.h>

/* The size the measured device session actually churns: 0xb0000.  Nothing
 * depends on the exact value — it is here so the timing number means the same
 * thing as the one the log reports. */
#define CHURN_SIZE   0xb0000u
#define CHURN_ROUNDS 512u

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

static void line_2( const char *a, unsigned int v, const char *b, unsigned int w,
                    const char *c )
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

/* ------------------------------------------------------ readability probe */

/* Is the first byte of [p] readable?  Asked of the kernel, so it neither raises
 * nor depends on what the compiler did with a load.  ReadProcessMemory on the
 * current process reads through the memory manager and fails cleanly for a page
 * that is not present or not readable. */
static int readable( const void *p )
{
    unsigned char b = 0;
    SIZE_T got = 0;
    if (!ReadProcessMemory( GetCurrentProcess(), p, &b, 1, &got )) return 0;
    return got == 1;
}

/* ------------------------------------------------------------- assertions */

/* Every byte of [p, p+n) must be zero.  Returns the offset of the first
 * non-zero byte, or n. */
static unsigned int first_nonzero( const unsigned char *p, unsigned int n )
{
    unsigned int i;
    for (i = 0; i < n; i++) if (p[i]) return i;
    return n;
}

static void fill_pattern( unsigned char *p, unsigned int n )
{
    unsigned int i;
    for (i = 0; i < n; i += 4096u) p[i] = (unsigned char)(0xa5 + i);
    p[n - 1] = 0x5a;
}

/* ------------------------------------------------------------------ main */

static int fail( int code, const char *why )
{
    line_1( "MADEIRA-VMCHURN: FAIL status=", (unsigned int)code, "" );
    line_0( why );
    return code;
}

int __cdecl churn_main( void )
{
    SYSTEM_INFO si;
    MEMORY_BASIC_INFORMATION mbi;
    LARGE_INTEGER freq, t0, t1;
    unsigned char *p, *first;
    unsigned int i, nz, alloc_gran, page;
    unsigned int reused = 0;
    unsigned int elapsed_us, per_cycle_ns;

    line_0( "MADEIRA-VMCHURN: start" );

    GetSystemInfo( &si );
    alloc_gran = si.dwAllocationGranularity;
    page = si.dwPageSize;
    line_2( "MADEIRA-VMCHURN: page=", page, " granularity=", alloc_gran, "" );
    line_hex( "MADEIRA-VMCHURN: churn size=", CHURN_SIZE, "" );

    /* --- PHASE 1: zero-fill on first use AND on every recycle -------------
     *
     * This is the assertion a region cache is most likely to break, so it runs
     * first and it runs many times: a cache that zeroes only sometimes (say,
     * only when the OS happened to hand back a fresh mapping) passes a single
     * round and fails here. */
    first = NULL;
    for (i = 0; i < 32; i++)
    {
        p = VirtualAlloc( NULL, CHURN_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
        if (!p) return fail( 61, "VirtualAlloc(MEM_RESERVE|MEM_COMMIT, PAGE_READWRITE) failed" );
        if (!first) first = p;
        else if (p == first) reused++;

        nz = first_nonzero( p, CHURN_SIZE );
        if (nz != CHURN_SIZE)
        {
            line_1( "MADEIRA-VMCHURN: non-zero byte at offset ", nz, " of a fresh region" );
            return fail( i ? 63 : 62, "re-allocated memory must read back as zero" );
        }

        if (!VirtualQuery( p, &mbi, sizeof(mbi) ) || mbi.Protect != PAGE_READWRITE)
        {
            line_hex( "MADEIRA-VMCHURN: protect=", (unsigned int)mbi.Protect, " expected PAGE_READWRITE" );
            return fail( 64, "a recycled region reported the wrong protection" );
        }

        fill_pattern( p, CHURN_SIZE );
        VirtualFree( p, 0, MEM_RELEASE );
    }
    line_1( "MADEIRA-VMCHURN: phase 1 OK (32 rounds, same base reused ", reused, " times)" );

    /* --- PHASE 2: released memory reports MEM_FREE and faults ------------- */
    p = VirtualAlloc( NULL, CHURN_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
    if (!p) return fail( 61, "VirtualAlloc failed before phase 2" );
    fill_pattern( p, CHURN_SIZE );
    VirtualFree( p, 0, MEM_RELEASE );

    if (!VirtualQuery( p, &mbi, sizeof(mbi) ) || mbi.State != MEM_FREE)
    {
        line_hex( "MADEIRA-VMCHURN: state=", (unsigned int)mbi.State, " expected MEM_FREE (0x10000)" );
        return fail( 65, "released memory must report MEM_FREE" );
    }
    if (readable( p ))
        return fail( 66, "released memory must not be readable" );
    line_0( "MADEIRA-VMCHURN: phase 2 OK (MEM_FREE and not readable)" );

    /* --- PHASE 3: the released range is re-reservable at its own base ------
     *
     * The explicit base is the one request a placement policy — or a region
     * cache — cannot redirect, so this asks the question directly. */
    {
        void *again = VirtualAlloc( p, CHURN_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
        if (again != p)
            return fail( 67, "a released range must be re-reservable at its own base" );
        nz = first_nonzero( again, CHURN_SIZE );
        if (nz != CHURN_SIZE)
            return fail( 63, "the re-reserved range did not read back as zero" );
        VirtualFree( again, 0, MEM_RELEASE );
    }
    line_0( "MADEIRA-VMCHURN: phase 3 OK (explicit-base re-reserve)" );

    /* --- PHASE 4: commit / decommit / recommit inside one reservation ------ */
    p = VirtualAlloc( NULL, CHURN_SIZE, MEM_RESERVE, PAGE_NOACCESS );
    if (!p) return fail( 61, "VirtualAlloc(MEM_RESERVE) failed" );

    if (!VirtualAlloc( p, page * 4u, MEM_COMMIT, PAGE_READWRITE ))
        return fail( 68, "MEM_COMMIT inside a reservation failed" );
    fill_pattern( p, page * 4u );

    if (!VirtualFree( p, page * 4u, MEM_DECOMMIT ))
        return fail( 69, "MEM_DECOMMIT failed" );
    if (!VirtualQuery( p, &mbi, sizeof(mbi) ) || mbi.State != MEM_RESERVE)
    {
        line_hex( "MADEIRA-VMCHURN: state=", (unsigned int)mbi.State, " expected MEM_RESERVE (0x2000)" );
        return fail( 69, "decommitted pages must still report MEM_RESERVE" );
    }
    if (readable( p ))
        return fail( 70, "a decommitted page must not be readable" );

    if (!VirtualAlloc( p, page * 4u, MEM_COMMIT, PAGE_READWRITE ))
        return fail( 68, "recommit failed" );
    nz = first_nonzero( p, page * 4u );
    if (nz != page * 4u)
    {
        line_1( "MADEIRA-VMCHURN: non-zero byte at offset ", nz, " after recommit" );
        return fail( 71, "recommitted pages must read back as zero" );
    }
    VirtualFree( p, 0, MEM_RELEASE );
    line_0( "MADEIRA-VMCHURN: phase 4 OK (commit/decommit/recommit)" );

    /* --- PHASE 5: the protection asked for is the protection installed ----- */
    p = VirtualAlloc( NULL, page * 4u, MEM_RESERVE | MEM_COMMIT, PAGE_READONLY );
    if (!p) return fail( 61, "VirtualAlloc(PAGE_READONLY) failed" );
    if (!VirtualQuery( p, &mbi, sizeof(mbi) ) || mbi.Protect != PAGE_READONLY)
    {
        line_hex( "MADEIRA-VMCHURN: protect=", (unsigned int)mbi.Protect, " expected PAGE_READONLY" );
        return fail( 73, "VirtualQuery reported a protection that was not asked for" );
    }
    /* Readable, and recorded as read-only.  The WRITE half is deliberately not
     * probed with a store: WriteProcessMemory would silently re-protect the page
     * on Windows and so proves nothing, and a raw store cannot be recovered from
     * here (see the header).  VirtualQuery above is the assertion that matters
     * for a region cache -- it is what a program asks. */
    if (!readable( p ))
        return fail( 72, "PAGE_READONLY memory must still be readable" );
    VirtualFree( p, 0, MEM_RELEASE );
    line_0( "MADEIRA-VMCHURN: phase 5 OK (protection is honoured)" );

    /* --- THE TIMED CHURN --------------------------------------------------
     *
     * One full reserve+commit / first-touch / release cycle, which is what the
     * device session does thousands of times a second.  The first touch is
     * included deliberately: a cache that avoids the mapping call but pushes
     * the cost into page faults has not saved anything, and only a number that
     * includes the touch can say so.  Division is 32-bit throughout (no CRT
     * 64-bit helpers here), so the loop count is chosen to keep the microsecond
     * total inside 32 bits. */
    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < CHURN_ROUNDS; i++)
    {
        unsigned int off;
        p = VirtualAlloc( NULL, CHURN_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE );
        if (!p) return fail( 74, "VirtualAlloc failed inside the timed churn" );
        for (off = 0; off < CHURN_SIZE; off += 4096u) p[off] = (unsigned char)off;
        VirtualFree( p, 0, MEM_RELEASE );
    }
    QueryPerformanceCounter( &t1 );

    /* (ticks * 1e6) / freq, without 64-bit division: the counter is 10 MHz on
     * Windows and 24 MHz on this device's timebase, so ticks/1000 then
     * *1e6/(freq/1000) keeps everything in 32 bits for any plausible run. */
    {
        unsigned int ticks = (unsigned int)(t1.QuadPart - t0.QuadPart);
        /* LowPart, not QuadPart / 1000: a 64-bit divide would pull in the CRT's
         * __divdi3 and this links -nostdlib.  Every performance counter this
         * runs on is well inside 32 bits (10 MHz on Windows, 24 MHz on the
         * device's timebase). */
        unsigned int khz = freq.LowPart / 1000u;
        elapsed_us = khz ? (ticks * 1000u) / khz : 0;
        per_cycle_ns = elapsed_us ? (elapsed_us * 1000u) / CHURN_ROUNDS : 0;
    }
    line_2( "MADEIRA-VMCHURN: churn ", CHURN_ROUNDS, " cycles in ", elapsed_us, " us" );
    line_1( "MADEIRA-VMCHURN: per cycle ", per_cycle_ns, " ns (reserve+commit, touch every page, release)" );

    line_0( "MADEIRA-VMCHURN: PASS status=80" );
    return 80;
}

void __cdecl start( void )
{
    ExitProcess( (UINT)churn_main() );
}
