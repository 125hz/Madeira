/* MADEIRA-TEMP: the stress self-test for the ml910/ml912/ml913/ml915 NT-path
 * resolution caches in wine/dlls/ntdll/unix/file.c (WOW64_DESIGN.md section 6:
 * "ml910", "negative", "whole-path", "dircache").
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * Four caches sit between a Windows path and the unix file it names:
 *
 *   1. get_dir_case_sensitivity() memoised per directory path;
 *   2. a resolved-name cache with per-component NEGATIVE entries stamped with
 *      the parent directory's (dev, ino, nanosecond mtime);
 *   3. a WHOLE-PATH negative cache, keyed on the path and stamped with the
 *      deepest directory that does exist, so a failing open costs one fstatat;
 *   4. a DIRECTORY-CONTENTS cache: one directory read once into a hash table
 *      keyed on (dev, ino) and stamped with its mtime and ctime, after which
 *      any name in it -- present or absent -- is one fstatat plus a probe.
 *
 * All four answer "does this path exist" without touching the file system,
 * and all four are revalidated against a directory mtime.  Every way that can
 * go wrong has the same signature from a program's point of view: an open that
 * returns NOT_FOUND for a file that is there (or SUCCESS for one that is not),
 * with no error anywhere else.  Engines that probe a list of candidate paths
 * per asset turn that into a NULL dereference several seconds later, in code
 * that has nothing to do with the file system, so it has to be caught here.
 *
 * The test keeps a ground-truth model of 2000 paths and asserts every single
 * observation against it.  The phases are ordered to walk each cache through
 * the transition that invalidates it:
 *
 *   1  PROBE-ALL-MISSING.  2000 paths across 7 directories, none of which
 *      exist.  Populates every negative entry there is; also asserts that a
 *      missing leaf reports ERROR_FILE_NOT_FOUND and a missing intermediate
 *      directory reports ERROR_PATH_NOT_FOUND, because only a real ENOENT on
 *      the final component may ever be cached.
 *   2  CREATE-THEN-PROBE.  Creates half of them and probes each one back
 *      IMMEDIATELY.  This is the transition a negative entry has to survive:
 *      the entry was recorded microseconds ago, and the create must have
 *      invalidated it.  A stamp read after the probe that proved absence
 *      rather than before it fails here.
 *   3  SWEEP.  Every path probed again, in a different order.
 *   4  CASE CHURN.  Every path probed again in the opposite ASCII case.  Wine
 *      resolves a component case-insensitively, so the answer must be
 *      identical to phase 3 for all 2000 -- both for the ones that exist and
 *      for the ones that do not.  A cache keyed on a case-folded whole path
 *      conflates spellings that this resolver does NOT treat as equivalent
 *      (it prefers the exact case at every component), and fails here.
 *   5  RENAME.  MoveFile of an existing file onto a name that phase 1 recorded
 *      as absent; both ends probed.
 *   6  DELETE.  The reverse transition: a positive answer must not outlive the
 *      file, including when the name is recreated in a different case.
 *   7  DIRECTORY CHURN.  RemoveDirectory then CreateDirectory of a directory
 *      in the middle of a path, with a child probed at every step -- the case
 *      a whole-path entry stamps on a GRANDparent, and the one where the
 *      NAME/PATH_NOT_FOUND distinction flips.
 *   9  CASE-SIBLING DIRECTORIES.  The one sequence that separates a cache
 *      keyed on the case-FOLDED path from one keyed on the exact path, and
 *      the shape of a launcher reporting "not installed correctly" while the
 *      files are right there.  Two directories that differ only in case,
 *      "CaseA" and "casea", are created; if the volume keeps them apart, then
 *      probing casea\\only.dat (absent) followed by creating CaseA\\only.dat
 *      and probing THAT must find it.  A folded key makes the second probe
 *      reuse the first's answer -- and the first's answer is still perfectly
 *      valid for its own directory, whose mtime never moved, so it never goes
 *      stale.  Skipped with a log line on a case-insensitive volume, where
 *      the two directories are one.
 *   8  CONCURRENT CREATE.  A second thread creates a file while the main
 *      thread is probing it; after the handshake the main thread must see it.
 *      This is the race a stamp taken too late makes permanent: the create
 *      lands after the directory scan that proved absence but before the mtime
 *      that the entry is stamped with, so the entry is born already matching
 *      the live directory and never goes stale.
 *
 *  10  DIRECTORY-CONTENTS CACHE.  3000 files in one directory, then 5000
 *      DISTINCT absent names probed in it, twice with two disjoint name sets
 *      and once repeating the first set.  Distinct names are what the device
 *      log actually shows (an engine probing localised package spellings), and
 *      they are exactly what a per-NAME cache cannot help with: without a
 *      directory table every one of them re-reads 3000 entries.  Each pass
 *      prints its wall time and the mean microseconds per failing probe, so a
 *      device log carries the same number [fs-stats] prints as fail_avg_us.
 *      Then the three transitions that must invalidate the table while it is
 *      hot: a create in the cached directory probed back immediately (the
 *      same-tick case the create paths invalidate by path for), a delete, and
 *      a rename in and out.  Finally a flipped-case probe of a file that does
 *      exist, which must still resolve to its real spelling -- that is the
 *      answer that now comes out of the table instead of a readdir walk.
 *
 * Deliberate restrictions, the same as the other tests in this directory: no
 * CRT (this file supplies `start' plus memset/memcpy and links -nostdlib, so
 * its only import is kernel32), no 64-bit division, no int-to-double.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   47  every check passed
 *   60  could not set up the test directory tree
 *   61  a path that EXISTS was reported missing
 *   62  a path that does NOT exist was reported present
 *   63  a missing path reported the wrong error (NAME vs PATH not found)
 *   64  a CreateFile/DeleteFile/MoveFile/CreateDirectory call failed outright
 *   65  a file was still reported missing immediately after being created
 *   66  a directory was still reported missing after being recreated
 *   67  CreateThread/CreateEvent failed
 *
 * A/B: run it with MADEIRA_FS_NEGCACHE=0 and without (the whole-path negative
 * cache is on by default since ml915), and with MADEIRA_FS_DIRCACHE=0 and
 * without.  All four combinations must give 47; only the phase 10 timings
 * should differ, and they are the point.
 */
#include <stddef.h>
#include <windows.h>

#define NPATHS     2000u
#define NDIRS      7u
#define RELMAX     64
#define PATHMAX    320
#define CONC_ROUNDS 200u
/* phase 10: one directory big enough that a case-insensitive scan of it is
 * expensive (the device log's directories hold thousands of package files),
 * and more distinct absent probes than it has entries. */
#define NBIG        3000u
#define NMISS       5000u
#define NFRESH      64u

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
    if (!v) { *p++ = 48; *p = 0; return p; }
    while (v) { tmp[n++] = (char)(48 + v % 10); v /= 10; }
    while (n--) *p++ = tmp[n];
    /* NUL-terminate without advancing: callers chain str_cat() straight onto
     * the returned pointer, and str_cat scans for the terminator first. */
    *p = 0;
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
}

static void line_1( const char *a, unsigned int v, const char *b )
{
    char buf[512], *p = buf;
    p = put_str( p, a );
    p = put_uint( p, v );
    p = put_str( p, b );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* the failing path always goes in the log: without it a device run says only
 * that something was denied, not what. */
static void fail_path( const char *what, const char *path, unsigned int err )
{
    char buf[512], *p = buf;
    p = put_str( p, "MADEIRA-FS: " );
    p = put_str( p, what );
    p = put_str( p, " path=" );
    p = put_str( p, path );
    p = put_str( p, " err=" );
    p = put_uint( p, err );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------------- tiny string */

static unsigned int str_len( const char *s )
{
    const char *e = s;
    while (*e) e++;
    return (unsigned int)(e - s);
}

static char *str_cat( char *dst, const char *src )
{
    while (*dst) dst++;
    while (*src) *dst++ = *src++;
    *dst = 0;
    return dst;
}

static int str_eq( const char *a, const char *b )
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* ASCII case flip of the LAST path component only: the directory part keeps
 * its on-disk spelling, so phase 4 varies exactly one thing. */
static void flip_leaf_case( char *s )
{
    char *leaf = s, *p;
    for (p = s; *p; p++) if (*p == '\\') leaf = p + 1;
    for (p = leaf; *p; p++)
    {
        if (*p >= 'a' && *p <= 'z') *p = (char)(*p - 'a' + 'A');
        else if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
    }
}

/* xorshift32: the shuffles and the create/keep decisions must be identical on
 * every run so a failure can be reproduced from the exit code alone. */
static unsigned int rng_state = 0x1234567u;

static unsigned int rng_next(void)
{
    unsigned int x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

/* --------------------------------------------------------------- the model */

struct ent
{
    char rel[RELMAX];       /* "<dir>\<name>", the spelling that was created */
    unsigned char exists;
};

static struct ent model[NPATHS];
static char base[PATHMAX];            /* "<temp>\madeira-fs-test\" */

static const char * const dirs[NDIRS] =
{
    "Alpha", "beta", "GAMMA", "GAMMA\\Delta", "e1", "e1\\e2", "e1\\e2\\e3"
};

static void make_full( char *out, const char *rel )
{
    out[0] = 0;
    str_cat( out, base );
    str_cat( out, rel );
}

/* 1 = present, 0 = absent; *err gets GetLastError() when absent. */
static int probe( const char *rel, unsigned int *err )
{
    char full[PATHMAX];
    DWORD attr;

    make_full( full, rel );
    SetLastError( 0 );
    attr = GetFileAttributesA( full );
    if (attr != INVALID_FILE_ATTRIBUTES) return 1;
    *err = (unsigned int)GetLastError();
    return 0;
}

/* GetFileAttributes reaches the resolver with open_reparse=TRUE, which the
 * whole-path caches deliberately refuse to serve.  A real open does not, and a
 * real open is what the device log is full of, so phase 10 times this one. */
static int probe_open( const char *rel, unsigned int *err )
{
    char full[PATHMAX];
    HANDLE h;

    make_full( full, rel );
    SetLastError( 0 );
    h = CreateFileA( full, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
    if (h != INVALID_HANDLE_VALUE) { CloseHandle( h ); return 1; }
    *err = (unsigned int)GetLastError();
    return 0;
}

static int create_file_at( const char *rel )
{
    char full[PATHMAX];
    HANDLE h;

    make_full( full, rel );
    h = CreateFileA( full, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (h == INVALID_HANDLE_VALUE) return 0;
    CloseHandle( h );
    return 1;
}

/* ------------------------------------------------------------- phase 0 */

static int setup(void)
{
    char full[PATHMAX];
    unsigned int i, n;

    n = (unsigned int)GetTempPathA( PATHMAX - 64, base );
    if (!n || n >= PATHMAX - 64) return 60;
    if (base[str_len( base ) - 1] != '\\') str_cat( base, "\\" );
    str_cat( base, "madeira-fs-test\\" );

    /* a leftover tree from an earlier run would make phase 1 fail for the
     * right reason in the wrong place, so it is emptied first. */
    full[0] = 0;
    str_cat( full, base );
    full[str_len( full ) - 1] = 0;
    if (!CreateDirectoryA( full, NULL ) && GetLastError() != ERROR_ALREADY_EXISTS) return 60;

    for (i = 0; i < NDIRS; i++)
    {
        make_full( full, dirs[i] );
        if (!CreateDirectoryA( full, NULL ) && GetLastError() != ERROR_ALREADY_EXISTS) return 60;
    }

    for (i = 0; i < NPATHS; i++)
    {
        char *p = model[i].rel;
        p[0] = 0;
        p = str_cat( p, dirs[i % NDIRS] );
        p = str_cat( p, "\\" );
        /* two spellings, so phase 4's flip lands on a name that really was
         * created in the other case half the time. */
        p = str_cat( p, (i & 1) ? "f" : "F" );
        p = put_uint( p, i );
        p = str_cat( p, (i & 1) ? ".dat" : ".Dat" );
        *p = 0;
        model[i].exists = 0;

        make_full( full, model[i].rel );
        DeleteFileA( full );
    }
    return 0;
}

/* ------------------------------------------------------------- phase 1 */

static int phase_probe_all_missing(void)
{
    unsigned int i, err;
    char rel[RELMAX];

    for (i = 0; i < NPATHS; i++)
    {
        if (probe( model[i].rel, &err ))
        {
            fail_path( "phase1 present but should be absent", model[i].rel, 0 );
            return 62;
        }
        if (err != ERROR_FILE_NOT_FOUND)
        {
            fail_path( "phase1 wrong error for a missing leaf", model[i].rel, err );
            return 63;
        }
    }

    /* a missing INTERMEDIATE component is a different status, and only a real
     * ENOENT of the final component may ever be remembered as a leaf miss. */
    for (i = 0; i < NDIRS; i++)
    {
        rel[0] = 0;
        str_cat( rel, "no_such_dir\\" );
        str_cat( rel, dirs[i % NDIRS] );
        str_cat( rel, "\\x.dat" );
        if (probe( rel, &err ))
        {
            fail_path( "phase1 present under a missing directory", rel, 0 );
            return 62;
        }
        if (err != ERROR_PATH_NOT_FOUND)
        {
            fail_path( "phase1 wrong error for a missing directory", rel, err );
            return 63;
        }
    }
    out_str( "MADEIRA-FS: phase 1 (2000 absent paths, error codes) OK\n" );
    return 0;
}

/* ------------------------------------------------------------- phase 2 */

static int phase_create_then_probe(void)
{
    unsigned int i, err, made = 0;

    for (i = 0; i < NPATHS; i++)
    {
        if (rng_next() & 1) continue;
        if (!create_file_at( model[i].rel ))
        {
            fail_path( "phase2 CreateFile failed", model[i].rel, (unsigned int)GetLastError() );
            return 64;
        }
        model[i].exists = 1;
        made++;
        /* the whole point: the negative entry for this path is microseconds
         * old and the create has to have killed it. */
        if (!probe( model[i].rel, &err ) || !probe_open( model[i].rel, &err ))
        {
            fail_path( "phase2 missing right after CreateFile", model[i].rel, err );
            return 65;
        }
    }
    line_1( "MADEIRA-FS: phase 2 (created ", made, " files, each probed back) OK" );
    return 0;
}

/* ------------------------------------------------------------- phase 3/4 */

static int sweep( int flip, int phase )
{
    unsigned int n, i, err;
    char rel[RELMAX];

    /* a different visiting order than the one that populated the caches */
    for (n = 0; n < NPATHS; n++)
    {
        i = rng_next() % NPATHS;

        rel[0] = 0;
        str_cat( rel, model[i].rel );
        if (flip) flip_leaf_case( rel );

        if (probe( rel, &err ))
        {
            if (!model[i].exists)
            {
                fail_path( phase == 3 ? "phase3 present but absent in the model"
                                      : "phase4 present but absent in the model", rel, 0 );
                return 62;
            }
            if (!probe_open( rel, &err ))
            {
                fail_path( "sweep attributes found it but an open did not", rel, err );
                return 61;
            }
        }
        else
        {
            if (model[i].exists)
            {
                fail_path( phase == 3 ? "phase3 missing but present in the model"
                                      : "phase4 missing under the other case", rel, err );
                return 61;
            }
            if (err != ERROR_FILE_NOT_FOUND)
            {
                fail_path( "sweep wrong error for a missing leaf", rel, err );
                return 63;
            }
            if (probe_open( rel, &err ))
            {
                fail_path( "sweep an open found a file the model says is absent", rel, 0 );
                return 62;
            }
        }
    }
    line_1( "MADEIRA-FS: phase ", (unsigned int)phase, flip
            ? " (2000 probes, leaf case flipped) OK" : " (2000 probes, shuffled) OK" );
    return 0;
}

/* ------------------------------------------------------------- phase 5 */

static int phase_rename(void)
{
    unsigned int i, err, moved = 0;
    char from[PATHMAX], to[PATHMAX];

    for (i = 0; i + 1 < NPATHS; i += 2)
    {
        if (!model[i].exists || model[i + 1].exists) continue;

        make_full( from, model[i].rel );
        make_full( to, model[i + 1].rel );
        if (!MoveFileA( from, to ))
        {
            fail_path( "phase5 MoveFile failed", model[i].rel, (unsigned int)GetLastError() );
            return 64;
        }
        model[i].exists = 0;
        model[i + 1].exists = 1;
        moved++;

        if (probe( model[i].rel, &err ) )
        {
            fail_path( "phase5 rename source still present", model[i].rel, 0 );
            return 62;
        }
        /* the destination was recorded absent in phase 1; a rename INTO it
         * only bumps the parent's mtime, nothing about the name itself. */
        if (!probe( model[i + 1].rel, &err ))
        {
            fail_path( "phase5 rename target missing", model[i + 1].rel, err );
            return 65;
        }
        if (moved > 300) break;
    }
    line_1( "MADEIRA-FS: phase 5 (", moved, " renames onto negative-cached names) OK" );
    return 0;
}

/* ------------------------------------------------------------- phase 6 */

static int phase_delete_and_recreate(void)
{
    unsigned int i, err, done = 0;
    char full[PATHMAX], rel[RELMAX];

    for (i = 0; i < NPATHS; i += 3)
    {
        if (!model[i].exists) continue;

        make_full( full, model[i].rel );
        if (!DeleteFileA( full ))
        {
            fail_path( "phase6 DeleteFile failed", model[i].rel, (unsigned int)GetLastError() );
            return 64;
        }
        model[i].exists = 0;
        if (probe( model[i].rel, &err ))
        {
            fail_path( "phase6 deleted file still present", model[i].rel, 0 );
            return 62;
        }

        /* recreate under the OTHER case: a positive entry that still names the
         * old spelling must not be believed, and on a case-insensitive volume
         * the two are one file either way. */
        rel[0] = 0;
        str_cat( rel, model[i].rel );
        flip_leaf_case( rel );
        if (!create_file_at( rel ))
        {
            fail_path( "phase6 CreateFile (flipped case) failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        rel[RELMAX - 1] = 0;
        model[i].rel[0] = 0;
        str_cat( model[i].rel, rel );
        model[i].exists = 1;

        if (!probe( model[i].rel, &err ))
        {
            fail_path( "phase6 recreated file missing", model[i].rel, err );
            return 65;
        }
        done++;
    }
    line_1( "MADEIRA-FS: phase 6 (", done, " delete + recreate-in-other-case) OK" );
    return 0;
}

/* ------------------------------------------------------------- phase 7 */

static int phase_directory_churn(void)
{
    static const char *churn_dir = "churn";
    char dirfull[PATHMAX], full[PATHMAX], rel[RELMAX];
    unsigned int round, err;

    for (round = 0; round < 40; round++)
    {
        rel[0] = 0;
        str_cat( rel, churn_dir );
        str_cat( rel, "\\c" );
        {
            char *p = rel;
            while (*p) p++;
            p = put_uint( p, round );
            p = str_cat( p, ".dat" );
            *p = 0;
        }

        make_full( dirfull, churn_dir );
        make_full( full, rel );

        /* the directory does not exist: the child must be PATH_NOT_FOUND, and
         * that answer is the one a whole-path entry stamps on the GRANDparent */
        if (probe( rel, &err ))
        {
            fail_path( "phase7 child present with no directory", rel, 0 );
            return 62;
        }
        if (err != ERROR_PATH_NOT_FOUND)
        {
            fail_path( "phase7 wrong error with no directory", rel, err );
            return 63;
        }

        if (!CreateDirectoryA( dirfull, NULL ))
        {
            fail_path( "phase7 CreateDirectory failed", churn_dir, (unsigned int)GetLastError() );
            return 64;
        }
        /* now the directory is there and the child is merely absent */
        if (probe( rel, &err ))
        {
            fail_path( "phase7 child present in a fresh directory", rel, 0 );
            return 62;
        }
        if (err != ERROR_FILE_NOT_FOUND)
        {
            fail_path( "phase7 wrong error in a fresh directory", rel, err );
            return 63;
        }

        if (!create_file_at( rel ))
        {
            fail_path( "phase7 CreateFile failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        if (!probe( rel, &err ))
        {
            fail_path( "phase7 child missing after create", rel, err );
            return 66;
        }

        if (!DeleteFileA( full ) || !RemoveDirectoryA( dirfull ))
        {
            fail_path( "phase7 teardown failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        if (probe( rel, &err ))
        {
            fail_path( "phase7 child present after rmdir", rel, 0 );
            return 62;
        }
        if (err != ERROR_PATH_NOT_FOUND)
        {
            fail_path( "phase7 wrong error after rmdir", rel, err );
            return 63;
        }
    }
    out_str( "MADEIRA-FS: phase 7 (40 rmdir/mkdir rounds, NAME vs PATH not found) OK\n" );
    return 0;
}

/* ------------------------------------------------------------- phase 8 */

static HANDLE ev_go, ev_done;
static char conc_rel[RELMAX];
static volatile LONG conc_fail;

static DWORD WINAPI conc_thread( LPVOID unused )
{
    unsigned int i;

    (void)unused;
    for (i = 0; i < CONC_ROUNDS; i++)
    {
        if (WaitForSingleObject( ev_go, 20000 ) != WAIT_OBJECT_0) { conc_fail = 1; return 0; }
        if (!create_file_at( conc_rel )) conc_fail = 1;
        SetEvent( ev_done );
    }
    return 0;
}

static int phase_concurrent_create(void)
{
    static const char *conc_dir = "conc";
    char dirfull[PATHMAX], full[PATHMAX];
    HANDLE th;
    unsigned int i, err, spins;

    make_full( dirfull, conc_dir );
    if (!CreateDirectoryA( dirfull, NULL ) && GetLastError() != ERROR_ALREADY_EXISTS) return 60;

    ev_go = CreateEventA( NULL, FALSE, FALSE, NULL );
    ev_done = CreateEventA( NULL, FALSE, FALSE, NULL );
    if (!ev_go || !ev_done) return 67;
    th = CreateThread( NULL, 0, conc_thread, NULL, 0, NULL );
    if (!th) return 67;

    for (i = 0; i < CONC_ROUNDS; i++)
    {
        char *p = conc_rel;
        p[0] = 0;
        p = str_cat( p, conc_dir );
        p = str_cat( p, "\\p" );
        p = put_uint( p, i );
        p = str_cat( p, ".bin" );
        *p = 0;

        /* Release the creator FIRST and start probing immediately.  The path
         * is fresh, so the first probe is a guaranteed cache miss and walks
         * the whole thing -- which is what has to still be in flight when the
         * create lands.  A negative entry stamped after that point is born
         * matching the live directory and can never go stale, which is the
         * defect this phase exists to catch; probing before the handshake
         * instead would only ever record a stamp the create then invalidates. */
        SetEvent( ev_go );
        for (spins = 0; spins < 16; spins++) probe( conc_rel, &err );
        if (WaitForSingleObject( ev_done, 20000 ) != WAIT_OBJECT_0) return 67;
        if (conc_fail) return 64;

        /* the create is complete and ordered before this probe by the event */
        if (!probe( conc_rel, &err ))
        {
            fail_path( "phase8 missing after a concurrent create", conc_rel, err );
            return 65;
        }
        make_full( full, conc_rel );
        DeleteFileA( full );
    }

    CloseHandle( th );
    CloseHandle( ev_go );
    CloseHandle( ev_done );
    RemoveDirectoryA( dirfull );
    line_1( "MADEIRA-FS: phase 8 (", CONC_ROUNDS, " create/probe races) OK" );
    return 0;
}

/* ------------------------------------------------------------- phase 9 */

static int phase_case_siblings(void)
{
    static const char *lower = "casea";
    static const char *upper = "CaseA";
    char lo[PATHMAX], up[PATHMAX];
    char rel_lo[RELMAX], rel_up[RELMAX];
    unsigned int err;

    make_full( lo, lower );
    make_full( up, upper );
    RemoveDirectoryA( lo );
    RemoveDirectoryA( up );

    if (!CreateDirectoryA( up, NULL ))
    {
        fail_path( "phase9 CreateDirectory failed", upper, (unsigned int)GetLastError() );
        return 64;
    }
    if (!CreateDirectoryA( lo, NULL ))
    {
        /* one directory, not two: this volume folds case and the sequence
         * below cannot be constructed.  Not a failure. */
        RemoveDirectoryA( up );
        out_str( "MADEIRA-FS: phase 9 skipped (case-insensitive volume)\n" );
        return 0;
    }

    rel_lo[0] = 0;
    str_cat( rel_lo, lower );
    str_cat( rel_lo, "\\only.dat" );
    rel_up[0] = 0;
    str_cat( rel_up, upper );
    str_cat( rel_up, "\\only.dat" );

    /* 1. the lower-case spelling is absent -- this is what gets remembered */
    if (probe( rel_lo, &err ))
    {
        fail_path( "phase9 present before anything was created", rel_lo, 0 );
        return 62;
    }

    /* 2. create it under the OTHER directory.  Only CaseA's mtime moves;
     *    casea, which the remembered answer is stamped against, does not. */
    if (!create_file_at( rel_up ))
    {
        fail_path( "phase9 CreateFile failed", rel_up, (unsigned int)GetLastError() );
        return 64;
    }

    /* 3. and now the file that exists must be found */
    if (!probe( rel_up, &err ))
    {
        fail_path( "phase9 case-sibling file missing (folded cache key)", rel_up, err );
        return 61;
    }
    /* 4. while the other one must still be absent */
    if (probe( rel_lo, &err ))
    {
        fail_path( "phase9 case-sibling file wrongly present", rel_lo, 0 );
        return 62;
    }

    make_full( up, upper );
    str_cat( up, "\\only.dat" );
    DeleteFileA( up );
    make_full( lo, lower );
    make_full( up, upper );
    RemoveDirectoryA( lo );
    RemoveDirectoryA( up );
    out_str( "MADEIRA-FS: phase 9 (case-sibling directories) OK\n" );
    return 0;
}

/* ------------------------------------------------------------ phase 10 */

static const char *big_dir = "bigdir";

/* "bigdir\\b<i>_Pkg.upk" -- the files that really are there */
static void big_rel( char *rel, unsigned int i )
{
    char *p = rel;
    p[0] = 0;
    p = str_cat( p, big_dir );
    p = str_cat( p, "\\b" );
    p = put_uint( p, i );
    p = str_cat( p, "_Pkg.upk" );
    *p = 0;
}

/* "bigdir\\<tag><i>_LOC_INT.upk" -- distinct names that are never created.
 * The shape is the device's: an engine asking for localised variants of a
 * package, a different spelling every time, so a per-name negative entry is
 * written once and never read again. */
static void miss_rel( char *rel, const char *tag, unsigned int i )
{
    char *p = rel;
    p[0] = 0;
    p = str_cat( p, big_dir );
    p = str_cat( p, "\\" );
    p = str_cat( p, tag );
    p = put_uint( p, i );
    p = str_cat( p, "_LOC_INT.upk" );
    *p = 0;
}

/* 5000 absent probes, timed.  Returns 0, or the failing exit code. */
static int miss_pass( const char *tag, unsigned int pass, unsigned int *ms_out )
{
    char rel[RELMAX];
    unsigned int i, err, t0, t1, ms;

    t0 = (unsigned int)GetTickCount();
    for (i = 0; i < NMISS; i++)
    {
        miss_rel( rel, tag, i );
        if (probe_open( rel, &err ))
        {
            fail_path( "phase10 absent name opened", rel, 0 );
            return 62;
        }
        if (err != ERROR_FILE_NOT_FOUND)
        {
            fail_path( "phase10 wrong error for a missing leaf", rel, err );
            return 63;
        }
    }
    t1 = (unsigned int)GetTickCount();
    ms = t1 - t0;                        /* unsigned: correct across a wrap */
    *ms_out = ms;
    {
        char buf[256], *p = buf;
        p = put_str( p, "MADEIRA-FS: phase 10 pass " );
        p = put_uint( p, pass );
        p = put_str( p, ": " );
        p = put_uint( p, NMISS );
        p = put_str( p, " distinct absent probes in " );
        p = put_uint( p, ms );
        p = put_str( p, " ms, avg " );
        p = put_uint( p, ms * 1000u / NMISS );   /* 32-bit only, on purpose */
        p = put_str( p, " us each" );
        *p++ = '\n';
        *p = 0;
        out_str( buf );
    }
    return 0;
}

static int phase_dircache(void)
{
    char rel[RELMAX], rel2[RELMAX], full[PATHMAX], full2[PATHMAX], dirfull[PATHMAX];
    unsigned int i, err, ms1, ms2, ms3;
    int rc;

    make_full( dirfull, big_dir );
    if (!CreateDirectoryA( dirfull, NULL ) && GetLastError() != ERROR_ALREADY_EXISTS) return 60;

    for (i = 0; i < NBIG; i++)
    {
        big_rel( rel, i );
        if (!create_file_at( rel ))
        {
            fail_path( "phase10 CreateFile failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
    }
    line_1( "MADEIRA-FS: phase 10 directory populated with ", NBIG, " files" );

    /* pass 1 reads the directory once and answers the other 4999 from the
     * table; pass 2 uses names pass 1 never saw, so it can only be the table;
     * pass 3 repeats pass 1's names, which the whole-path negative cache
     * answers before find_file_in_dir is even reached. */
    if ((rc = miss_pass( "m", 1, &ms1 ))) return rc;
    if ((rc = miss_pass( "n", 2, &ms2 ))) return rc;
    if ((rc = miss_pass( "m", 3, &ms3 ))) return rc;

    /* a file that DOES exist, asked for in the wrong case: this is the answer
     * that now comes out of the table, and it must be the same one the
     * readdir walk gave. */
    for (i = 0; i < NBIG; i += 97)
    {
        big_rel( rel, i );
        if (!probe_open( rel, &err ))
        {
            fail_path( "phase10 existing file could not be opened", rel, err );
            return 61;
        }
        flip_leaf_case( rel );
        if (!probe( rel, &err ))
        {
            fail_path( "phase10 existing file missing under the other case", rel, err );
            return 61;
        }
        if (!probe_open( rel, &err ))
        {
            fail_path( "phase10 existing file could not be opened in the other case", rel, err );
            return 61;
        }
    }

    /* CREATE IN A HOT DIRECTORY.  The table for bigdir was built moments ago
     * and every probe above re-validated it, so this is the create-then-open
     * that a stamp alone could miss inside one clock tick. */
    for (i = 0; i < NFRESH; i++)
    {
        rel[0] = 0;
        str_cat( rel, big_dir );
        str_cat( rel, "\\fresh" );
        {
            char *p = rel;
            while (*p) p++;
            p = put_uint( p, i );
            p = str_cat( p, ".dat" );
            *p = 0;
        }
        if (probe( rel, &err ))
        {
            fail_path( "phase10 fresh name present before it was created", rel, 0 );
            return 62;
        }
        if (!create_file_at( rel ))
        {
            fail_path( "phase10 CreateFile failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        if (!probe( rel, &err ))
        {
            fail_path( "phase10 missing right after a create in a cached directory", rel, err );
            return 65;
        }
        if (!probe_open( rel, &err ))
        {
            fail_path( "phase10 unopenable right after a create in a cached directory", rel, err );
            return 65;
        }
    }

    /* DELETE FROM A HOT DIRECTORY */
    for (i = 0; i < NBIG; i += 211)
    {
        big_rel( rel, i );
        make_full( full, rel );
        if (!DeleteFileA( full ))
        {
            fail_path( "phase10 DeleteFile failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        if (probe( rel, &err ) || probe_open( rel, &err ))
        {
            fail_path( "phase10 deleted file still present in a cached directory", rel, 0 );
            return 62;
        }
        if (err != ERROR_FILE_NOT_FOUND)
        {
            fail_path( "phase10 wrong error after a delete", rel, err );
            return 63;
        }
    }

    /* RENAME WITHIN A HOT DIRECTORY, onto a name pass 1 recorded as absent */
    for (i = 1; i < NBIG; i += 307)
    {
        big_rel( rel, i );
        miss_rel( rel2, "m", i );
        make_full( full, rel );
        make_full( full2, rel2 );
        if (!MoveFileA( full, full2 ))
        {
            fail_path( "phase10 MoveFile failed", rel, (unsigned int)GetLastError() );
            return 64;
        }
        if (probe( rel, &err ) || probe_open( rel, &err ))
        {
            fail_path( "phase10 rename source still present", rel, 0 );
            return 62;
        }
        if (!probe( rel2, &err ) || !probe_open( rel2, &err ))
        {
            fail_path( "phase10 rename target missing", rel2, err );
            return 65;
        }
        /* and back, so the cleanup below is simple */
        if (!MoveFileA( full2, full ))
        {
            fail_path( "phase10 MoveFile back failed", rel2, (unsigned int)GetLastError() );
            return 64;
        }
        if (probe( rel2, &err ) || probe_open( rel2, &err ))
        {
            fail_path( "phase10 rename target still present after moving back", rel2, 0 );
            return 62;
        }
        if (!probe( rel, &err ) || !probe_open( rel, &err ))
        {
            fail_path( "phase10 rename source missing after moving back", rel, err );
            return 65;
        }
    }

    /* teardown: 3000 files plus the fresh ones */
    for (i = 0; i < NBIG; i++)
    {
        big_rel( rel, i );
        make_full( full, rel );
        DeleteFileA( full );
    }
    for (i = 0; i < NFRESH; i++)
    {
        rel[0] = 0;
        str_cat( rel, big_dir );
        str_cat( rel, "\\fresh" );
        {
            char *p = rel;
            while (*p) p++;
            p = put_uint( p, i );
            p = str_cat( p, ".dat" );
            *p = 0;
        }
        make_full( full, rel );
        DeleteFileA( full );
    }
    make_full( dirfull, big_dir );
    RemoveDirectoryA( dirfull );

    out_str( "MADEIRA-FS: phase 10 (directory-contents cache) OK\n" );
    return 0;
}

/* --------------------------------------------------------------- driver */

static void cleanup(void)
{
    char full[PATHMAX];
    unsigned int i;

    for (i = 0; i < NPATHS; i++)
    {
        if (!model[i].exists) continue;
        make_full( full, model[i].rel );
        DeleteFileA( full );
    }
    for (i = NDIRS; i > 0; i--)
    {
        make_full( full, dirs[i - 1] );
        RemoveDirectoryA( full );
    }
    full[0] = 0;
    str_cat( full, base );
    full[str_len( full ) - 1] = 0;
    RemoveDirectoryA( full );
}

static int run_all(void)
{
    int rc;

    out_str( "MADEIRA-FS: path-cache stress test starting\n" );
    if ((rc = setup())) return rc;
    out_str( "MADEIRA-FS: tree ready\n" );

    if ((rc = phase_probe_all_missing())) return rc;
    if ((rc = phase_create_then_probe())) return rc;
    if ((rc = sweep( 0, 3 ))) return rc;
    if ((rc = sweep( 1, 4 ))) return rc;
    if ((rc = phase_rename())) return rc;
    if ((rc = sweep( 0, 3 ))) return rc;
    if ((rc = phase_delete_and_recreate())) return rc;
    if ((rc = sweep( 1, 4 ))) return rc;
    if ((rc = phase_directory_churn())) return rc;
    if ((rc = phase_case_siblings())) return rc;
    if ((rc = phase_concurrent_create())) return rc;
    if ((rc = phase_dircache())) return rc;

    cleanup();
    out_str( "MADEIRA-FS: all checks passed\n" );
    return 47;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
