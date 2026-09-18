/* MADEIRA-TEMP: the self-test for the large-address-aware-by-default policy
 * (build/ntdll-unix/virtual_ios.c, ios_laa_forced / ios_wow_ceiling_for_charact
 * and the [laa] header patch in virtual_map_image).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * A 32-bit image that does not carry IMAGE_FILE_LARGE_ADDRESS_AWARE gets a 2 GB
 * user space on Windows.  On this port the same 2 GB also has to hold Wine's
 * builtin i386 DLL farm and the emulated D3D9 frontend's guest-visible heap, so
 * a program that fits on Windows does not fit here: the log shows the
 * allocator's 16 -> 8 -> 4 MB fallbacks all returning [va-scan] FAILED with a
 * 3.75 MB largest gap, and then the CRT calling exit(3).
 *
 * The fix is the policy Proton ships (WINE_LARGE_ADDRESS_AWARE=1 forced on):
 * a non-LAA 32-bit image is given the whole 4 GB window anyway.  MADEIRA_LAA=0
 * in Documents/madeira-env.txt restores the 2 GB ceiling.
 *
 * THIS FILE IS DELIBERATELY NOT LINKED --large-address-aware.  Every other test
 * here sets that bit (WOW64_DESIGN.md section 6); this one must NOT, because an
 * image that already has the bit would pass whether or not the policy works.
 * The build script asserts the bit is ABSENT, which is the inverse of the
 * assertion the other scripts make and the whole point of the test.
 *
 * WHAT IT CHECKS
 * --------------
 *  1. RESERVE.  VirtualAlloc(NULL, 64 MB, MEM_RESERVE, PAGE_NOACCESS) in a loop
 *     until it fails.  With a 2 GB ceiling this stops somewhere below 2048 MB
 *     (the image, the heaps and every loaded DLL are in the way); with a 4 GB
 *     ceiling it should pass 2600 MB comfortably.
 *  2. HIGH HALF.  At least one of those reservations must come back at an
 *     address >= 0x80000000.  A total alone is not enough: an implementation
 *     that raised some internal limit but still handed out only low addresses
 *     would not have fixed anything the failing title needs.
 *  3. EVIDENCE.  GlobalMemoryStatus's dwTotalVirtual is printed, because the
 *     guest's own kernel32 clamps it to MAXLONG by reading this image's PE
 *     characteristics (dlls/kernel32/heap.c) rather than by asking ntdll — so a
 *     value above 2 GB here is what proves the mapped header was patched too,
 *     and an application allocator that sizes itself from GlobalMemoryStatus
 *     sees the raised ceiling.
 *
 * EXIT CODES
 * ----------
 *   60  PASS: >= 2600 MB reserved AND at least one address >= 0x80000000.
 *   61  FAIL: anything else (this is the expected result with MADEIRA_LAA=0,
 *       which is how the knob itself is verified).
 *
 * Builds and runs under the same constraints as the other tests here: no CRT,
 * this file supplies `start' plus memset/memcpy, and it links kernel32 only.
 */

#include <stddef.h>
#include <windows.h>

#define CHUNK    (64u * 1024u * 1024u)   /* 64 MB reservations */
#define MAX_N    80u                     /* 5120 MB ceiling on the loop itself */
#define PASS_MB  2600u

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
    static const char digits[] = "0123456789abcdef";
    int i, started = 0;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4)
    {
        unsigned int d = (v >> i) & 0xf;
        if (!d && !started && i) continue;
        started = 1;
        *p++ = digits[d];
    }
    if (!started) *p++ = '0';
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

/* ------------------------------------------------------------------ test */

static UINT run_all( void )
{
    MEMORYSTATUS ms;
    void *highest = NULL;
    unsigned int reserved_mb = 0, n = 0, high_hits = 0;
    char buf[256], *p;

    memset( &ms, 0, sizeof(ms) );
    ms.dwLength = sizeof(ms);
    GlobalMemoryStatus( &ms );

    p = buf;
    p = put_str( p, "MADEIRA-LAA: GlobalMemoryStatus dwTotalVirtual=" );
    p = put_hex( p, (unsigned int)ms.dwTotalVirtual );
    p = put_str( p, " (" );
    p = put_uint( p, (unsigned int)(ms.dwTotalVirtual >> 20) );
    p = put_str( p, " MB) dwAvailVirtual=" );
    p = put_hex( p, (unsigned int)ms.dwAvailVirtual );
    *p++ = '\n'; *p = 0;
    out_str( buf );

    /* Reserve, never commit: this is a question about address space, and
     * committing 2.6 GB would be a question about the 4096 MB jetsam ceiling
     * instead.  PAGE_NOACCESS so nothing can accidentally touch it. */
    while (n < MAX_N)
    {
        void *ptr = VirtualAlloc( NULL, CHUNK, MEM_RESERVE, PAGE_NOACCESS );

        if (!ptr) break;
        n++;
        reserved_mb += CHUNK >> 20;
        if ((ULONG_PTR)ptr >= 0x80000000u) high_hits++;
        if ((ULONG_PTR)ptr > (ULONG_PTR)highest) highest = ptr;
    }

    p = buf;
    p = put_str( p, "MADEIRA-LAA: reserved " );
    p = put_uint( p, reserved_mb );
    p = put_str( p, " MB highest=" );
    p = put_hex( p, (unsigned int)(ULONG_PTR)highest );
    p = put_str( p, " chunks=" );
    p = put_uint( p, n );
    p = put_str( p, " above2g=" );
    p = put_uint( p, high_hits );
    *p++ = '\n'; *p = 0;
    out_str( buf );

    if (reserved_mb >= PASS_MB && high_hits)
    {
        out_str( "MADEIRA-LAA: PASS -- a non-large-address-aware image was given the 4 GB window\n" );
        return 60;
    }
    if (!high_hits)
        out_str( "MADEIRA-LAA: FAIL -- no reservation landed at or above 0x80000000\n" );
    else
        out_str( "MADEIRA-LAA: FAIL -- could not reserve 2600 MB\n" );
    return 61;
}

void __cdecl start( void )
{
    ExitProcess( run_all() );
}
