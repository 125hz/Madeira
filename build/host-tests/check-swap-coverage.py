#!/usr/bin/env python3
"""ml2013: swap-tier coverage, free-space coalescing, whole-host-page copy-back
and the [swap] ml2013 census (virtual_ios.c "ml2013 swap-tier core").

1. Compiles the production swap-tier core (between the "ml2013 swap-tier core"
   markers) against small stubs for Wine's view/protection helpers and runs it
   on real memory with a real sparse backing file:
   - policy parsing: default "blocks" (1 MB floor), "wide", "classic",
     MADEIRA_SWAP_MIN_KB / _WIDE / _RESERVE overrides, MADEIRA_SWAP_ML2013=0
     restores the ml1077 8 MB/band rule;
   - eligibility reasons (prot, view, placeholder, FEX arena, JIT pool, band,
     small) in every mode;
   - randomized take/give against a model: free ranges never overlap live
     ranges, and after everything is given back the file offset space is
     empty again (bump 0, no free entries);
   - commit-time backing keeps data through a copy-back of an unaligned
     sub-range, copy-back covers whole 16 KB host pages and every remaining
     extent stays host-page aligned;
   - opt-in reserve-time backing maps PROT_NONE, a later commit (mprotect) is
     zero-filled, is not backed twice ("present"), and a decommit splits it;
   - the census line names every reason and the coverage.
2. Source-checks the call sites in allocate_virtual_memory(), the kill switch
   and the Settings picker in Library.swift.
Device runs are still required: this proves the bookkeeping, not iOS paging.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
virt = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
library = (root / 'app/Madeira/Library.swift').read_text(encoding='utf-8')

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def body_of(src, signature):
    start = src.index(signature)
    brace = src.index('{', start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
    raise AssertionError('unterminated body: ' + signature)


begin = virt.index('/* ml2013 swap-tier core begin */')
end = virt.index('/* ml2013 swap-tier core end */')
core = virt[begin:end]

prelude = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <linux/falloc.h>
typedef unsigned long ULONG_PTR;
#define VPROT_READ       0x01
#define VPROT_WRITE      0x02
#define VPROT_EXEC       0x04
#define VPROT_WRITECOPY  0x08
#define VPROT_GUARD      0x10
#define VPROT_COMMITTED  0x20
#define VPROT_WRITEWATCH 0x40
#define VPROT_ARM64EC          0x0100
#define VPROT_SYSTEM           0x0200
#define VPROT_PLACEHOLDER      0x0400
#define VPROT_FREE_PLACEHOLDER 0x0800
#define SEC_FILE    0x00800000
#define SEC_IMAGE   0x01000000
#define SEC_RESERVE 0x04000000
#define SEC_COMMIT  0x08000000
struct file_view { void *base; size_t size; unsigned int protect; };
static inline int is_view_valloc( const struct file_view *view )
{ return !(view->protect & (SEC_FILE | SEC_RESERVE | SEC_COMMIT)); }
static uintptr_t host_page_mask = 0x3fff;
ULONG_PTR ios_fex_arena_base_unix = 0x7c00000000ULL, ios_fex_arena_end_unix = 0x8000000000ULL;
void *ios_jit_rw_base_global = (void *)0x7000000000ULL;   /* numerically inside the band on purpose */
void *ios_jit_rx_base_global = (void *)0x119400000ULL;
size_t ios_jit_pool_size_global = 0x20000000;
static int get_unix_prot( unsigned int v )
{
    int p = 0;
    if (!(v & VPROT_COMMITTED)) return PROT_NONE;
    if (v & VPROT_READ) p |= PROT_READ;
    if (v & VPROT_WRITE) p |= PROT_READ | PROT_WRITE;
    return p;
}
static void *anon_mmap_fixed( void *a, size_t l, int prot, int flags )
{ (void)flags; return mmap( a, l, prot, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0 ); }
struct fpunchhole { unsigned fp_flags; unsigned reserved; off_t fp_offset; off_t fp_length; };
#define F_PUNCHHOLE 99
static int test_fcntl( int fd, int cmd, struct fpunchhole *ph )
{ (void)cmd; return fallocate( fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, ph->fp_offset, ph->fp_length ); }
#define fcntl( fd, cmd, arg ) test_fcntl( fd, cmd, arg )
'''

harness = r'''
static unsigned long long ios_swap_footprint_mb( void ) { return 4321; }
static int bad;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL: %s (line %d)\n", what, __LINE__); bad++; } } while (0)

static void reset_tier( void )
{
    ios_swap_n = 0; ios_swap_nfree = 0; ios_swap_bump = 0; ios_swap_bytes = 0; ios_swap_peak = 0;
    memset( ios_swap_why_bytes, 0, sizeof(ios_swap_why_bytes) );
}
static void env( const char *cov, const char *mn, const char *wide, const char *resv, const char *v2 )
{
    const char *n[5] = { "MADEIRA_SWAP_COVERAGE", "MADEIRA_SWAP_MIN_KB", "MADEIRA_SWAP_WIDE", "MADEIRA_SWAP_RESERVE", "MADEIRA_SWAP_ML2013" };
    const char *v[5] = { cov, mn, wide, resv, v2 };
    int i;
    for (i = 0; i < 5; i++) { if (v[i]) setenv( n[i], v[i], 1 ); else unsetenv( n[i] ); }
    ios_swap_config();
}

static void test_config( void )
{
    env( NULL, NULL, NULL, NULL, NULL );
    CHECK( ios_swap_v2 && !strcmp( ios_swap_mode, "blocks" ) && ios_swap_min == (1u << 20) && !ios_swap_wide && !ios_swap_resv, "default = blocks, 1 MB" );
    env( "wide", NULL, NULL, NULL, NULL );
    CHECK( !strcmp( ios_swap_mode, "wide" ) && ios_swap_wide && ios_swap_resv && ios_swap_min == (1u << 20), "wide preset" );
    env( "Wide", NULL, "0", NULL, NULL );
    CHECK( !ios_swap_wide && ios_swap_resv, "MADEIRA_SWAP_WIDE=0 overrides the preset" );
    env( "classic", NULL, NULL, NULL, NULL );
    CHECK( ios_swap_v2 && ios_swap_min == (8u << 20) && !ios_swap_wide && !ios_swap_resv, "classic preset" );
    env( NULL, "512", NULL, "1", NULL );
    CHECK( ios_swap_min == (512u << 10) && ios_swap_resv && !ios_swap_wide, "MIN_KB and RESERVE overrides" );
    env( NULL, "1", NULL, NULL, NULL );
    CHECK( ios_swap_min == (64u << 10), "MIN_KB clamped to 64 KB" );
    env( "wide", "256", "1", "1", "0" );
    CHECK( !ios_swap_v2 && ios_swap_min == (8u << 20) && !ios_swap_wide && !ios_swap_resv, "MADEIRA_SWAP_ML2013=0 ignores every ml2013 knob" );
}

static void test_why( void )
{
    struct file_view v = { 0, 0, 0 }, ph = { 0, 0, VPROT_PLACEHOLDER }, img = { 0, 0, SEC_IMAGE }, sys = { 0, 0, VPROT_SYSTEM };
    void *g = (void *)0x7050000000ULL, *low = (void *)0x1000000000ULL, *fex = (void *)0x7c10000000ULL;
    unsigned rw = VPROT_READ | VPROT_WRITE;

    env( NULL, NULL, NULL, NULL, NULL );
    CHECK( ios_swap_why( g, 1u << 20, rw, &v ) == IOS_SW_BACKED, "blocks: 1 MB guest RW backed" );
    CHECK( ios_swap_why( g, (1u << 20) - 0x1000, rw, &v ) == IOS_SW_SMALL, "blocks: below 1 MB small" );
    CHECK( ios_swap_why( g, 1u << 20, rw | VPROT_EXEC, &v ) == IOS_SW_PROT, "exec never" );
    CHECK( ios_swap_why( g, 1u << 20, VPROT_READ, &v ) == IOS_SW_PROT, "read-only never" );
    CHECK( ios_swap_why( g, 1u << 20, rw | VPROT_WRITEWATCH, &v ) == IOS_SW_PROT, "write-watch never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &img ) == IOS_SW_VIEW, "image never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &sys ) == IOS_SW_VIEW, "system view never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, &ph ) == IOS_SW_VIEW, "placeholder never" );
    CHECK( ios_swap_why( g, 1u << 20, rw, NULL ) == IOS_SW_VIEW, "no view never" );
    CHECK( ios_swap_why( low, 64u << 20, rw, &v ) == IOS_SW_BAND, "blocks: outside band" );
    CHECK( ios_swap_why( fex, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "FEX arena labelled" );
    CHECK( ios_swap_why( (void *)0x7000100000ULL, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "JIT pool RW alias never" );
    CHECK( ios_swap_why( (void *)0x7c00000000ULL - 0x100000, 0x200000, rw, &v ) == IOS_SW_FEXJIT, "straddling the arena never" );

    env( "wide", NULL, NULL, NULL, NULL );
    CHECK( ios_swap_why( low, 1u << 20, rw, &v ) == IOS_SW_BACKED, "wide: outside band backed" );
    CHECK( ios_swap_why( fex, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "wide: FEX arena still never" );
    CHECK( ios_swap_why( (void *)0x119500000ULL, 64u << 20, rw, &v ) == IOS_SW_FEXJIT, "wide: JIT pool RX never" );

    env( "classic", NULL, NULL, NULL, NULL );
    CHECK( ios_swap_why( g, 4u << 20, rw, &v ) == IOS_SW_SMALL, "classic: 4 MB small" );
    CHECK( ios_swap_why( g, 8u << 20, rw, &v ) == IOS_SW_BACKED, "classic: 8 MB backed" );

    env( NULL, NULL, NULL, NULL, "0" );   /* exact ml1077 predicate */
    CHECK( ios_swap_why( g, 8u << 20, rw, &v ) == IOS_SW_BACKED, "ml1077: 8 MB band backed" );
    CHECK( ios_swap_why( g, (8u << 20) - 1, rw, &v ) != IOS_SW_BACKED, "ml1077: under 8 MB refused" );
    CHECK( ios_swap_why( low, 64u << 20, rw, &v ) != IOS_SW_BACKED, "ml1077: band only" );
}

/* model check of take/give with coalescing */
static void test_freelist( void )
{
    enum { N = 400 };
    uint64_t off[N], len[N];
    int live[N], i, step;
    unsigned seed = 2013;
    env( NULL, NULL, NULL, NULL, NULL );
    reset_tier();
    memset( live, 0, sizeof(live) );
    for (step = 0; step < 20000; step++)
    {
        seed = seed * 1103515245u + 12345u;
        i = (seed >> 8) % N;
        if (!live[i])
        {
            len[i] = (uint64_t)(1 + ((seed >> 20) % 64)) << 14;
            off[i] = ios_swap_take( len[i] );
            if (off[i] == (uint64_t)-1) continue;
            live[i] = 1;
        }
        else { ios_swap_give( off[i], len[i] ); live[i] = 0; }
    }
    /* invariants: live ranges disjoint from each other and from free ranges */
    for (i = 0; i < N; i++) if (live[i])
    {
        unsigned f; int j;
        CHECK( off[i] + len[i] <= ios_swap_bump, "live range below bump" );
        for (f = 0; f < ios_swap_nfree; f++)
            if (off[i] < ios_swap_free[f].off + ios_swap_free[f].len && ios_swap_free[f].off < off[i] + len[i]) { CHECK( 0, "free overlaps live" ); break; }
        for (j = i + 1; j < N; j++) if (live[j] && off[i] < off[j] + len[j] && off[j] < off[i] + len[i]) { CHECK( 0, "live ranges overlap" ); break; }
    }
    {
        unsigned f, g;
        for (f = 0; f < ios_swap_nfree; f++)
            for (g = f + 1; g < ios_swap_nfree; g++)
                if (ios_swap_free[f].off + ios_swap_free[f].len == ios_swap_free[g].off ||
                    ios_swap_free[g].off + ios_swap_free[g].len == ios_swap_free[f].off) { CHECK( 0, "adjacent free ranges left unmerged" ); f = g = ios_swap_nfree; }
    }
    for (i = 0; i < N; i++) if (live[i]) { ios_swap_give( off[i], len[i] ); live[i] = 0; }
    CHECK( ios_swap_bump == 0 && ios_swap_nfree == 0, "all offsets returned: bump 0, free list empty" );
    printf( "freelist: merges=%llu bump-backs=%llu drops=%llu\n", ios_swap_merges, ios_swap_bump_back, ios_swap_free_drop );
}

static char *region( uintptr_t at, size_t len )
{
    void *p = mmap( (void *)at, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0 );
    if (p == MAP_FAILED || p != (void *)at) { printf( "FAIL: cannot map test region at %p (errno %d)\n", (void *)at, errno ); exit( 2 ); }
    return p;
}

static void test_commit_copyback( void )
{
    struct file_view v = { 0, 0, 0 };
    unsigned rw = VPROT_READ | VPROT_WRITE;
    char *r = region( 0x7050000000ULL, 4u << 20 );
    size_t i;
    unsigned k;
    env( NULL, NULL, NULL, NULL, NULL );
    reset_tier();
    v.base = r; v.size = 4u << 20;
    /* MEM_RESERVE|MEM_COMMIT of 0x110000 (a 1 MB heap block + header) */
    anon_mmap_fixed( r, 0x110000, PROT_READ | PROT_WRITE, 0 );
    ios_swap_commit( r, 0x110000, rw, &v );
    CHECK( ios_swap_n == 1 && ios_swap_bytes == 0x110000, "1 MB heap block backed whole" );
    CHECK( ios_swap_why_bytes[IOS_SW_BACKED] == 0x110000, "census counts it as backed" );
    for (i = 0; i < 0x110000; i++) r[i] = (char)(i * 7 + 3);
    /* EXEC on an unaligned 8 KB piece: must copy back whole host pages */
    ios_swap_release_range( r + 0x5000, 0x2000, 1 );
    for (k = 0; k < ios_swap_n; k++)
        CHECK( !((uintptr_t)ios_swap_ext[k].va & 0x3fff) && !(ios_swap_ext[k].len & 0x3fff), "extents stay host-page aligned" );
    CHECK( ios_swap_n == 2 && ios_swap_bytes == 0x110000 - 0x4000, "exactly the one host page left the tier" );
    CHECK( !ios_swap_overlaps( r + 0x4000, 0x4000 ) && ios_swap_overlaps( r, 0x4000 ) && ios_swap_overlaps( r + 0x8000, 0x4000 ), "neighbours still backed" );
    for (i = 0; i < 0x110000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "data preserved through copy-back" ); break; }
    /* the file punched only the copied page: remaining backed data intact after a re-read */
    msync( r, 0x110000, MS_SYNC );
    for (i = 0x8000; i < 0x110000; i++) if (r[i] != (char)(i * 7 + 3)) { CHECK( 0, "file-backed neighbours intact" ); break; }
    /* a fresh small commit is refused as small and counted */
    ios_swap_commit( r + 0x200000, 0x60000, rw, &v );
    CHECK( ios_swap_why_bytes[IOS_SW_SMALL] == 0x60000, "small commit counted" );
    ios_swap_release_range( r, v.size, 0 );   /* MEM_RELEASE */
    CHECK( ios_swap_n == 0 && ios_swap_bytes == 0 && ios_swap_bump == 0 && ios_swap_nfree == 0, "release returns all file space" );
    munmap( r, 4u << 20 );
}

static void test_reserve( void )
{
    struct file_view v = { 0, 0, 0 };
    unsigned rw = VPROT_READ | VPROT_WRITE;
    char *r = region( 0x7060000000ULL, 16u << 20 );
    size_t i;
    env( "wide", NULL, NULL, NULL, NULL );
    reset_tier();
    v.base = r; v.size = 0xfd0000;
    ios_swap_reserve( r, 0xfd0000, rw, &v );   /* a Wine subheap: MEM_RESERVE PAGE_READWRITE */
    CHECK( ios_swap_n == 1 && ios_swap_resv_n == 1, "writable reservation backed at reserve time" );
    CHECK( mprotect( r, 0x10000, PROT_READ | PROT_WRITE ) == 0, "commit = mprotect of file pages" );
    for (i = 0; i < 0x10000; i++) if (r[i]) { CHECK( 0, "fresh commit reads zero" ); break; }
    memset( r, 0x5a, 0x10000 );
    ios_swap_commit( r, 0x10000, rw, &v );
    CHECK( ios_swap_n == 1 && ios_swap_why_bytes[IOS_SW_PRESENT] == 0x10000, "commit inside a backed reservation is not backed twice" );
    /* decommit the middle: extent splits in two */
    ios_swap_release_range( r + 0x400000, 0x100000, 0 );
    anon_mmap_fixed( r + 0x400000, 0x100000, PROT_READ | PROT_WRITE, 0 );
    CHECK( ios_swap_n == 2, "decommit splits the reserve extent" );
    for (i = 0; i < 0x10000; i++) if (r[i] != 0x5a) { CHECK( 0, "data before the hole intact" ); break; }
    /* reserve-time backing is refused for committed, oversized, exec or non-writable requests */
    ios_swap_reserve( r, 0x100000, rw | VPROT_COMMITTED, &v );
    ios_swap_reserve( r, 0x20000000, rw, &v );
    ios_swap_reserve( r, 0x100000, VPROT_READ, &v );
    CHECK( ios_swap_resv_n == 1, "reserve-time backing refused where it must be" );
    env( NULL, NULL, NULL, NULL, NULL );   /* blocks: reserve-time off */
    ios_swap_reserve( r + 0xfd0000, 0x20000, rw, &v );
    CHECK( ios_swap_resv_n == 1, "blocks mode never backs a reservation" );
    ios_swap_release_range( r, 16u << 20, 0 );
    CHECK( ios_swap_n == 0 && ios_swap_bump == 0 && ios_swap_nfree == 0, "reservation release returns all file space" );
    munmap( r, 16u << 20 );
}

int main( int argc, char **argv )
{
    char path[] = "/tmp/madeira-swap-XXXXXX";
    int fd = mkstemp( path );
    if (fd < 0) return 2;
    close( fd );
    setenv( "MADEIRA_SWAP_FILE", path, 1 );
    setenv( "MADEIRA_SWAP_MB", "256", 1 );
    ios_swap_init();
    unlink( path );
    if (ios_swap_fd < 0) { printf( "FAIL: tier did not start\n" ); return 1; }
    test_config();
    test_why();
    test_freelist();
    test_commit_copyback();
    test_reserve();
    env( NULL, NULL, NULL, NULL, NULL );
    ios_swap_tick( 1 );
    printf( "%d failures\n", bad );
    return bad != 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'swap.c'
    exe = Path(tmp) / 'swap'
    c.write_text(prelude + core + harness)
    subprocess.run(['cc', '-O1', '-Wall', '-Wno-unused-function', '-Werror', '-o', str(exe), str(c)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True, env=dict(os.environ))
    print(r.stdout.strip())
    check(r.returncode == 0, 'swap-tier core run failed:\n' + r.stdout + r.stderr)
    err = r.stderr
    check('[swap] ml2013 coverage=blocks min=1024KB' in err, 'config line printed at tier start')
    census = [l for l in err.splitlines() if l.startswith('[swap] ml2013 file-backed now=')]
    check(len(census) >= 1, 'census line printed')
    if census:
        for name in ('backed=', 'small=', 'band=', 'fex/jit=', 'prot=', 'view=', 'recommit=', 'present=', 'refused=', 'mapfail='):
            check(name in census[-1], 'census names ' + name)
        check('footprint=4321MB' in census[-1] and 'coverage=blocks' in census[-1], 'census carries footprint and coverage')

# ------------------------------------------------------------ source checks
avm = body_of(virt, 'static NTSTATUS allocate_virtual_memory(')
check('if (type & MEM_COMMIT) ios_swap_commit( base, size, vprot, view );' in avm, 'reserve path: commit-time backing through ios_swap_commit')
check('else if (!ios_ec_code_request) ios_swap_reserve( base, size, vprot, view );' in avm, 'reserve-only path: opt-in reserve backing, never for EC code')
check('if (any_committed) ios_swap_note( IOS_SW_RECOMMIT, size );' in avm, 'commit path: already-committed counted, never backed')
check('else if (!get_vprot_flags( protect, &sv, 0 )) ios_swap_commit( base, size, sv, view );' in avm, 'commit path: fresh commit through ios_swap_commit')
check('ios_swap_eligible( base, size' not in avm, 'no direct ml1077 calls left in allocate_virtual_memory')
commit = body_of(virt, 'static void ios_swap_commit( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{')
check('if (!ios_swap_v2) { if (ios_swap_eligible( base, size, vprot, view )) ios_swap_back( base, size, vprot ); return; }' in commit,
      'MADEIRA_SWAP_ML2013=0 runs the exact ml1077 commit rule')
check('getenv( "MADEIRA_SWAP_ML2013" )' in virt or '"MADEIRA_SWAP_ML2013", 1' in virt, 'kill switch read')
check('static int ios_swap_back( void *base, size_t size, unsigned int vprot );' in virt, 'forward declaration updated')
check('return ios_swap_map( base, size, get_unix_prot( vprot | VPROT_COMMITTED ) );' in virt, 'ml1082: commit-time extents mapped committed')
check('ios_swap_map( base, size, get_unix_prot( vprot ) )' in body_of(virt, 'static void ios_swap_reserve( void *base, size_t size, unsigned int vprot, struct file_view *view )\n{'),
      'reserve-time extents keep the reservation protection (PROT_NONE)')
check('[swap] ml2013' in virt, 'ml2013 log tag')

# Settings picker
for needle, what in [
    ('MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", tag.isEmpty ? nil : tag)', 'picker writes env.MADEIRA_SWAP_COVERAGE, default removes it'),
    ('[runtime-settings] ml2013 swap-coverage=', 'picker logs its choice'),
    ('SwapCoverage(tag: "wide", label: "Wide (heaps too)")', 'wide choice'),
    ('SwapCoverage(tag: "classic", label: "Original (8 MB+)")', 'classic choice'),
    ('if swapMB > 0 {', 'coverage shown only with the tier on'),
]:
    check(needle in library, 'Library.swift: ' + what)

if failures:
    print('FAIL:')
    for f in failures:
        print('  - ' + f)
    raise SystemExit(1)
print('PASS: ml2013 swap-tier coverage, coalescing, copy-back and census')
