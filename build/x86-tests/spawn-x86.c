/* MADEIRA-TEMP: the 32-bit SPAWN CHAIN self-test, spawn-x86.exe.
 *
 * WHAT IT CHECKS, AND WHY
 * -----------------------
 * Every Windows "process" in this port is a pseudo-process thread inside ONE
 * Mach task, and a 32-bit one needs a private 4 GB-aligned guest window
 * [B, B+4G) because guest addresses are all below 4 GB and host addresses are
 * all above it (WOW64_DESIGN.md sections 2-3).  For most of this port's life
 * there was exactly ONE such window slot in the usable address band, so the
 * second concurrent 32-bit pseudo-process of a session could not start:
 *
 *     [wow-window] B=0x7100000000 REJECTED: a 32-bit pseudo-process is
 *                  running in this window right now
 *     [wow-window] B=0x7200000000 REJECTED: the 4GB range is not free
 *     ... CreateProcess -> c00000e5
 *
 * launcher -> program is the NORMAL shape of a 32-bit title, so that is a
 * bring-up blocker rather than a curiosity.  This program is the smallest
 * possible reproduction and regression test for it: it CreateProcess()es
 * ITSELF three levels deep, each level staying ALIVE and blocked in
 * WaitForSingleObject on its child, so all four processes (depths 0, 1, 2, 3)
 * are live at the same time and each 32-bit one needs its own window.
 *
 * It therefore exercises, per level:
 *   - a fresh guest window reservation and its adoption by a new PEB,
 *   - the per-pseudo-process TEB block inside that window (a TEB from another
 *     process's free list is the ml-2026-09-14 bug this cannot tolerate),
 *   - image placement and relocation inside the new window,
 *   - the parent's CreateProcess/wait/exit-code path across the boundary,
 *   - and, on the way back out, release-on-next-adopt: each level exits while
 *     its parent is still running, so the freed slot must be re-adoptable.
 *
 * CHAIN AND EXIT CODES
 * --------------------
 * A process at depth d < 3 spawns `spawn-x86.exe <d+1>` and waits for it.
 * A process at depth d > 0 exits with exactly d when its subtree succeeded.
 * The ROOT (depth 0) exits 49 when the whole chain succeeded.
 *
 *   49  PASS  -- four live 32-bit pseudo-processes, chain verified
 *    1,2,3    -- an inner level's own success code (never seen at the top)
 *   60  GetModuleFileNameA failed (cannot name the image to re-spawn)
 *   61  CreateProcess FAILED -- the line before it carries GetLastError().
 *                              This is the failure the test exists for:
 *                              0x0000007f/0x000003e6-style errors mean a real
 *                              loader problem, while a guest-window refusal
 *                              surfaces as ERROR_NOT_ENOUGH_MEMORY / a
 *                              c00000e5-derived code, with [wow-window]
 *                              REJECTED lines in the unix log.
 *   62  the child never exited within the watchdog
 *   63  GetExitCodeProcess failed
 *   64  the child exited with an unexpected code (the line before it carries
 *       the code that was actually seen)
 *   65  the depth argument was out of range
 *
 * Codes >= 60 PROPAGATE unchanged up the chain, so the root reports where the
 * chain broke, not merely that it did.
 *
 * Deliberate restrictions, the same ones the other tests in this directory work
 * under: no CRT (this file supplies `start` plus memset/memcpy and links
 * -nostdlib), so its only import is kernel32, and the image is linked
 * --large-address-aware because the guest window is a full 4 GB.
 */
#include <stddef.h>
#include <windows.h>

#define MAX_DEPTH    3u
#define PASS_CODE    49u
#define WATCHDOG_MS  120000u    /* a cold child boot maps a whole i386 ntdll */

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
    int i;
    *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    return p;
}

static char *put_str( char *p, const char *s )
{
    while (*s) *p++ = *s++;
    return p;
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

static void line_hex( const char *a, unsigned int v, const char *b, unsigned int w, const char *c )
{
    char buf[256], *p = buf;
    p = put_str( p, a );
    p = put_uint( p, v );
    p = put_str( p, b );
    p = put_hex( p, w );
    p = put_str( p, c );
    *p++ = '\n';
    *p = 0;
    out_str( buf );
}

/* ------------------------------------------------------- command line */

/* The depth this process was started at.
 *
 * The command line is always built by the level above as
 *     "<full path to spawn-x86.exe>" <depth>
 * so the parse is: skip a quoted or unquoted argv[0], skip blanks, then read
 * decimal digits.  No argument at all (the launch-button case, and the one a
 * human types) means depth 0.  Anything that is not a plain small number is
 * refused rather than guessed at — a misparse here would silently turn the
 * test into an infinite process fork bomb. */
static unsigned int parse_depth( int *bad )
{
    const char *p = GetCommandLineA();
    unsigned int v = 0;
    int digits = 0;

    *bad = 0;
    if (!p) return 0;

    if (*p == '"')
    {
        p++;
        while (*p && *p != '"') p++;
        if (*p == '"') p++;
    }
    else while (*p && *p != ' ' && *p != '\t') p++;

    while (*p == ' ' || *p == '\t') p++;
    if (!*p) return 0;

    while (*p >= '0' && *p <= '9')
    {
        v = v * 10u + (unsigned int)(*p - '0');
        p++;
        if (++digits > 2) { *bad = 1; return 0; }
    }
    while (*p == ' ' || *p == '\t') p++;
    if (!digits || *p) { *bad = 1; return 0; }
    if (v > MAX_DEPTH) { *bad = 1; return 0; }
    return v;
}

/* ------------------------------------------------------------- the chain */

static unsigned int spawn_child( unsigned int depth )
{
    char exe[MAX_PATH + 1];
    char cmd[MAX_PATH + 16];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD len, code = 0, wr;
    char *p;

    memset( exe, 0, sizeof(exe) );
    len = GetModuleFileNameA( NULL, exe, MAX_PATH );
    if (!len || len >= MAX_PATH)
    {
        line_2( "MADEIRA-SPAWN depth=", depth, " GetModuleFileNameA failed len=", (unsigned)len, "" );
        return 60;
    }

    p = cmd;
    *p++ = '"';
    p = put_str( p, exe );
    *p++ = '"';
    *p++ = ' ';
    p = put_uint( p, depth + 1u );
    *p = 0;

    memset( &si, 0, sizeof(si) );
    si.cb = sizeof(si);
    memset( &pi, 0, sizeof(pi) );

    if (!CreateProcessA( NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi ))
    {
        line_hex( "MADEIRA-SPAWN depth=", depth, " CreateProcess FAILED err=",
                  (unsigned)GetLastError(),
                  " -- if the unix log shows [wow-window] ... REJECTED on every slot, this is "
                  "the guest-window CONCURRENCY LIMIT, not a loader fault" );
        line_2( "MADEIRA-SPAWN CONCURRENCY LIMIT: depth=", depth,
                " is the deepest level reached, i.e. ", depth + 1u,
                " concurrent 32-bit pseudo-process(es) fit in this address space" );
        return 61;
    }
    line_2( "MADEIRA-SPAWN depth=", depth, " started child pid=", (unsigned)pi.dwProcessId,
            " -- both are now live 32-bit pseudo-processes" );

    wr = WaitForSingleObject( pi.hProcess, WATCHDOG_MS );
    if (wr != WAIT_OBJECT_0)
    {
        line_hex( "MADEIRA-SPAWN depth=", depth, " wait on child returned ", (unsigned)wr, "" );
        CloseHandle( pi.hThread );
        CloseHandle( pi.hProcess );
        return 62;
    }
    if (!GetExitCodeProcess( pi.hProcess, &code ))
    {
        line_hex( "MADEIRA-SPAWN depth=", depth, " GetExitCodeProcess failed err=",
                  (unsigned)GetLastError(), "" );
        CloseHandle( pi.hThread );
        CloseHandle( pi.hProcess );
        return 63;
    }
    CloseHandle( pi.hThread );
    CloseHandle( pi.hProcess );

    /* propagate a diagnosed failure unchanged, so the root names the level */
    if (code >= 60u && code <= 65u)
    {
        line_2( "MADEIRA-SPAWN depth=", depth, " child failed with ", (unsigned)code,
                " -- propagating" );
        return (unsigned int)code;
    }
    if (code != depth + 1u)
    {
        line_2( "MADEIRA-SPAWN depth=", depth, " child exited ", (unsigned)code,
                " but the chain requires it to exit with its own depth" );
        return 64;
    }
    line_2( "MADEIRA-SPAWN depth=", depth, " child exited ", (unsigned)code, " OK" );
    return 0;
}

static unsigned int run_all(void)
{
    unsigned int depth, rc;
    int bad = 0;

    depth = parse_depth( &bad );
    if (bad)
    {
        out_str( "MADEIRA-SPAWN: unusable depth argument -- refusing to spawn\n" );
        return 65;
    }

    line_2( "MADEIRA-SPAWN depth=", depth, " pid=", (unsigned)GetCurrentProcessId(), " alive" );

    if (depth >= MAX_DEPTH)
    {
        line_2( "MADEIRA-SPAWN depth=", depth, " leaf reached: ", MAX_DEPTH + 1u,
                " 32-bit pseudo-processes are live at once" );
        return depth;
    }

    if ((rc = spawn_child( depth ))) return rc;

    if (!depth)
    {
        out_str( "MADEIRA-SPAWN: chain of 4 live 32-bit pseudo-processes verified\n" );
        return PASS_CODE;
    }
    return depth;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
