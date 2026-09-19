/* MADEIRA-TEMP: the self-test for UNALIGNED x86 ATOMICS under the WoW64 + FEX
 * JIT (WOW64_DESIGN.md section 6, 2026-09-19 entry).
 *
 * WHY THIS TEST EXISTS
 * --------------------
 * x86 allows a `lock`-prefixed read-modify-write, and a plain `xchg [mem],reg`,
 * on ANY address; the operation stays atomic even when it straddles a cache
 * line.  ARM64 does not: the LSE atomics FEX translates them into (SWP, LDADD,
 * LDCLR, LDEOR, LDSET, CAS, CASP) and the load/store-exclusive pairs all raise
 * an ALIGNMENT fault when the address is not naturally aligned.  FEX exists to
 * catch that fault and finish the access by hand, so on a correct port the
 * guest can never tell the difference.
 *
 * On this port it could tell.  A 2012-era 32-bit title froze right after its
 * D3D9 device came up, with thirteen threads parked behind one guest critical
 * section that was never released.  The trigger was one instruction: the JIT's
 * `swpal w26,w4,[x24]` for a guest `xchg`, on a DWORD at 2 mod 4.  The fault
 * reached FEX correctly down the signal path and was emulated; the very next
 * execution of the same instruction reached the Mach exception path instead,
 * which labelled every EXC_BAD_ACCESS an ACCESS VIOLATION without ever looking
 * at the ESR, and delivered c0000005 into the middle of a locked region.  The
 * thread unwound out of the critical section still holding it.
 *
 * So the property under test is not "unaligned atomics are fast".  It is:
 *   (a) they must not raise a guest exception, EVER, on any delivery path, and
 *   (b) they must remain ATOMIC — two threads hammering one misaligned word
 *       must not lose a single update, which is what tells an emulated
 *       read-modify-write apart from a correct one.
 *
 * WHAT IT CHECKS
 * --------------
 *  0. ALIGNMENT PREMISE.  Every word used below is asserted to be misaligned
 *     (address mod 4 != 0) before anything else runs.  A packed struct that the
 *     compiler quietly padded would make every later check pass for the wrong
 *     reason, so this failure is reported separately (exit 73).
 *
 *  1. SINGLE-THREADED SEMANTICS, at offsets 1, 2 and 3 from a DWORD boundary.
 *     `lock xadd`, `lock cmpxchg` (both the taken and the not-taken outcome),
 *     `lock inc`, `xchg [mem],reg` and kernel32's exported InterlockedExchange
 *     each have to produce the exact value AND the exact return value an
 *     aligned run would.  An emulator that reconstructs the wrong operand width
 *     or byte order fails here immediately, with no threading to obscure it.
 *     Offset 2 is included because that is the one the device died on, and
 *     offsets 1 and 3 because a 4-byte access at 1 or 3 mod 4 can straddle a
 *     16-byte granule that offset 2 does not.
 *
 *  2. LOST-UPDATE STRESS, two threads, 1,000,000 iterations each.  Both threads
 *     run `lock xadd [misaligned],1`; the final value must be exactly 2,000,000.
 *     Any value below that is a lost update — the handler did the read and the
 *     write non-atomically — and that is the defect that turns a guest
 *     reference count into a use-after-free rather than a hang.
 *
 *  3. LOCK INC STRESS.  The same shape with `lock inc`, which FEX translates to
 *     a different LSE op (LDADD with a discarded result) and therefore takes a
 *     different branch of the fixup.
 *
 *  4. CAS STRESS.  A `lock cmpxchg` retry loop, i.e. the CAS/CASAL class.
 *
 *  5. XCHG SPINLOCK — THE SHAPE THAT ACTUALLY FROZE THE DEVICE.  A misaligned
 *     lock word is acquired with `xchg` (spin while the old value is 1) and
 *     released with a plain store; inside the lock each thread increments an
 *     ordinary, non-atomic counter.  The counter must reach exactly 200,000.
 *     Two things can go wrong and both matter: a non-atomic `xchg` lets both
 *     threads inside and the counter comes out short, and a guest exception
 *     raised while the lock is held wedges the other thread forever — which is
 *     why the test also fails on TIMEOUT rather than hanging (exit 74).
 *
 * Each phase prints its elapsed milliseconds.  That is deliberate: FEX cannot
 * back-patch an LSE atomic (no single ARM64 instruction has the semantics), so
 * every one of these accesses faults EVERY time it executes, and the per-access
 * cost of a fault round trip is the number that says whether a guest spinning
 * on a misaligned word will make progress or merely appear hung.
 *
 * EXIT CODES
 * ----------
 *   70  PASS: every check above held.
 *   71  FAIL: a wrong result (lost update, wrong return value, wrong operand).
 *   72  could not create a thread / event (environment problem, not a verdict).
 *   73  the test's own premise broke: a word that should be misaligned is not.
 *   74  a phase timed out — a thread is wedged, which is the frozen-title
 *       symptom itself.
 *   NO "MADEIRA-EXIT" LINE AT ALL: the process died on the unaligned access.
 *       That is the original bug, and its absence is the whole point of the
 *       test; a crashed run must never be mistaken for a fail-with-verdict.
 *
 * Builds and runs under the same constraints as the other tests here: no CRT,
 * this file supplies `start' plus memset/memcpy, it links kernel32 only, and it
 * uses no 64-bit division and no int-to-double conversion.
 */

#include <stddef.h>
#include <windows.h>

#define STRESS_ITERS  1000000u   /* per thread, phases 2-4 */
#define SPIN_ITERS     100000u   /* per thread, phase 5 (each iteration takes a lock) */
#define PHASE_TIMEOUT   600000u  /* ms; generous — every access is a fault round trip */

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

/* ------------------------------------------------ the misaligned words

 * One 4 KB page, and every word used by the test is placed at a DELIBERATE
 * offset from a DWORD boundary.  A packed struct would be the obvious way to
 * write this, but a struct layout is the compiler's to choose and a quiet
 * realignment would make the whole file test nothing; raw offsets into a byte
 * array cannot be renegotiated, and check_premise() asserts them anyway. */
static unsigned char arena[4096] __attribute__((aligned(64)));

/* offsets chosen so each word is at 1, 2 and 3 mod 4 respectively; the stress
 * words sit two cache lines apart so the phases cannot alias each other. */
#define OFF_SCRATCH1   65u    /* 1 mod 4 */
#define OFF_SCRATCH2  130u    /* 2 mod 4 — the offset the device died on */
#define OFF_SCRATCH3  195u    /* 3 mod 4 */
#define OFF_XADD      258u    /* 2 mod 4 */
#define OFF_INC       322u
#define OFF_CAS       386u
#define OFF_SPINLOCK  450u
#define OFF_GUARDED   514u    /* plain counter, only ever touched under the lock */

#define WORD(off) ((volatile LONG *)(arena + (off)))

/* ------------------------------------------------------- the x86 primitives

 * Written as inline asm rather than through the Interlocked* intrinsics so the
 * test controls the EXACT encoding it is checking.  mingw may lower
 * InterlockedExchangeAdd to `lock xadd` or to a CAS loop depending on flags,
 * and a CAS loop would silently test the wrong instruction class.  kernel32's
 * exported InterlockedExchange is exercised separately, by pointer, in
 * check_single_threaded(). */

static LONG x86_lock_xadd( volatile LONG *p, LONG add )
{
    LONG old = add;
    __asm__ __volatile__( "lock xaddl %0, %1" : "+r"(old), "+m"(*p) :: "memory", "cc" );
    return old;   /* value BEFORE the add */
}

/* returns the value that was in memory (EAX after the instruction) */
static LONG x86_lock_cmpxchg( volatile LONG *p, LONG expected, LONG desired )
{
    LONG prev;
    __asm__ __volatile__( "lock cmpxchgl %2, %1"
                          : "=a"(prev), "+m"(*p)
                          : "r"(desired), "0"(expected)
                          : "memory", "cc" );
    return prev;
}

static void x86_lock_inc( volatile LONG *p )
{
    __asm__ __volatile__( "lock incl %0" : "+m"(*p) :: "memory", "cc" );
}

/* `xchg` with a memory operand is atomic WITHOUT a lock prefix on x86 — the
 * bus lock is implicit.  This is the instruction the frozen title used. */
static LONG x86_xchg( volatile LONG *p, LONG val )
{
    __asm__ __volatile__( "xchgl %0, %1" : "+r"(val), "+m"(*p) :: "memory" );
    return val;   /* value BEFORE the swap */
}

/* ------------------------------------------------------------- phase 0 */

static int check_premise( void )
{
    static const unsigned int offs[] = {
        OFF_SCRATCH1, OFF_SCRATCH2, OFF_SCRATCH3, OFF_XADD,
        OFF_INC, OFF_CAS, OFF_SPINLOCK, OFF_GUARDED
    };
    unsigned int i;
    int ok = 1;

    for (i = 0; i < sizeof(offs) / sizeof(offs[0]); i++)
    {
        char line[128], *p = line;
        unsigned int addr = (unsigned int)(ULONG_PTR)WORD( offs[i] );
        p = put_str( p, "MADEIRA-UNALIGNED: word " );
        p = put_uint( p, i );
        p = put_str( p, " at " );
        p = put_hex( p, addr );
        p = put_str( p, " mod4=" );
        p = put_uint( p, addr & 3u );
        if (!(addr & 3u)) { p = put_str( p, "  *** ALIGNED — premise broken ***" ); ok = 0; }
        p = put_str( p, "\n" );
        *p = 0;
        out_str( line );
    }
    return ok;
}

/* ------------------------------------------------------------- phase 1 */

static int fail_val( const char *what, LONG got, LONG want )
{
    char line[160], *p = line;
    p = put_str( p, "MADEIRA-UNALIGNED: FAIL " );
    p = put_str( p, what );
    p = put_str( p, " got=" );
    p = put_hex( p, (unsigned int)got );
    p = put_str( p, " want=" );
    p = put_hex( p, (unsigned int)want );
    p = put_str( p, "\n" );
    *p = 0;
    out_str( line );
    return 0;
}

typedef LONG (WINAPI *interlocked_exchange_t)( LONG volatile *, LONG );

static int check_one_offset( unsigned int off, interlocked_exchange_t pIE )
{
    volatile LONG *w = WORD( off );
    LONG r;

    /* lock xadd: returns the old value, memory holds old+add */
    *w = 0x11112222;
    r = x86_lock_xadd( w, 0x00010001 );
    if (r != 0x11112222) return fail_val( "xadd return", r, 0x11112222 );
    if (*w != 0x11122223) return fail_val( "xadd memory", *w, 0x11122223 );

    /* lock xadd with a negative addend — sign handling across the emulated
     * read-modify-write, and a borrow out of the low half */
    *w = 0x00010000;
    r = x86_lock_xadd( w, -1 );
    if (r != 0x00010000) return fail_val( "xadd neg return", r, 0x00010000 );
    if (*w != 0x0000ffff) return fail_val( "xadd neg memory", *w, 0x0000ffff );

    /* lock cmpxchg, TAKEN */
    *w = 0x0badf00d;
    r = x86_lock_cmpxchg( w, 0x0badf00d, 0x5eed1234 );
    if (r != 0x0badf00d) return fail_val( "cmpxchg taken return", r, 0x0badf00d );
    if (*w != 0x5eed1234) return fail_val( "cmpxchg taken memory", *w, 0x5eed1234 );

    /* lock cmpxchg, NOT taken — memory must be untouched.  An emulator that
     * writes unconditionally passes the taken case and fails only here. */
    r = x86_lock_cmpxchg( w, 0x0badf00d, 0xdeadbeef );
    if (r != 0x5eed1234) return fail_val( "cmpxchg untaken return", r, 0x5eed1234 );
    if (*w != 0x5eed1234) return fail_val( "cmpxchg untaken memory", *w, 0x5eed1234 );

    /* lock inc, including the carry out of the low byte and low half */
    *w = 0x0000ffff;
    x86_lock_inc( w );
    if (*w != 0x00010000) return fail_val( "lock inc", *w, 0x00010000 );

    /* xchg [mem],reg */
    *w = 0x01020304;
    r = x86_xchg( w, 0x0a0b0c0d );
    if (r != 0x01020304) return fail_val( "xchg return", r, 0x01020304 );
    if (*w != 0x0a0b0c0d) return fail_val( "xchg memory", *w, 0x0a0b0c0d );

    /* kernel32's exported InterlockedExchange on the same misaligned word */
    if (pIE)
    {
        r = pIE( w, 0x77665544 );
        if (r != 0x0a0b0c0d) return fail_val( "InterlockedExchange return", r, 0x0a0b0c0d );
        if (*w != 0x77665544) return fail_val( "InterlockedExchange memory", *w, 0x77665544 );
    }
    return 1;
}

/* ------------------------------------------------------- stress phases */

static volatile LONG start_gun;

static void wait_for_gun( void )
{
    while (!start_gun) Sleep( 0 );
}

static DWORD WINAPI xadd_thread( LPVOID arg )
{
    unsigned int i;
    (void)arg;
    wait_for_gun();
    for (i = 0; i < STRESS_ITERS; i++) x86_lock_xadd( WORD( OFF_XADD ), 1 );
    return 0;
}

static DWORD WINAPI inc_thread( LPVOID arg )
{
    unsigned int i;
    (void)arg;
    wait_for_gun();
    for (i = 0; i < STRESS_ITERS; i++) x86_lock_inc( WORD( OFF_INC ) );
    return 0;
}

static DWORD WINAPI cas_thread( LPVOID arg )
{
    unsigned int i;
    (void)arg;
    wait_for_gun();
    for (i = 0; i < STRESS_ITERS; i++)
    {
        volatile LONG *w = WORD( OFF_CAS );
        for (;;)
        {
            LONG old = *w;
            if (x86_lock_cmpxchg( w, old, old + 1 ) == old) break;
        }
    }
    return 0;
}

/* The device's shape: acquire a MISALIGNED lock word with xchg, touch an
 * ordinary counter, release with a plain store. */
static DWORD WINAPI spin_thread( LPVOID arg )
{
    unsigned int i;
    (void)arg;
    wait_for_gun();
    for (i = 0; i < SPIN_ITERS; i++)
    {
        volatile LONG *lock = WORD( OFF_SPINLOCK );
        volatile LONG *guarded = WORD( OFF_GUARDED );
        while (x86_xchg( lock, 1 ) != 0) Sleep( 0 );
        *guarded = *guarded + 1;          /* deliberately NOT atomic */
        *lock = 0;
    }
    return 0;
}

/* returns 1 = ok, 0 = wrong result, -1 = timeout, -2 = environment */
static int run_two_threads( LPTHREAD_START_ROUTINE fn, const char *name,
                            unsigned int off, LONG expect, DWORD *elapsed_out )
{
    HANDLE th[2];
    DWORD t0, wr;
    char line[192], *p = line;
    LONG got;

    *WORD( off ) = 0;
    if (off == OFF_SPINLOCK) *WORD( OFF_GUARDED ) = 0;
    start_gun = 0;

    th[0] = CreateThread( NULL, 0, fn, NULL, 0, NULL );
    th[1] = CreateThread( NULL, 0, fn, NULL, 0, NULL );
    if (!th[0] || !th[1]) return -2;

    t0 = GetTickCount();
    start_gun = 1;
    wr = WaitForMultipleObjects( 2, th, TRUE, PHASE_TIMEOUT );
    *elapsed_out = GetTickCount() - t0;
    CloseHandle( th[0] );
    CloseHandle( th[1] );
    if (wr == WAIT_TIMEOUT) return -1;

    got = (off == OFF_SPINLOCK) ? *WORD( OFF_GUARDED ) : *WORD( off );

    p = put_str( p, "MADEIRA-UNALIGNED: " );
    p = put_str( p, name );
    p = put_str( p, " got=" );
    p = put_uint( p, (unsigned int)got );
    p = put_str( p, " want=" );
    p = put_uint( p, (unsigned int)expect );
    p = put_str( p, " ms=" );
    p = put_uint( p, *elapsed_out );
    p = put_str( p, "\n" );
    *p = 0;
    out_str( line );

    return got == expect;
}

/* ------------------------------------------------------------------ main */

static UINT run_all( void )
{
    interlocked_exchange_t pIE;
    unsigned int i;
    static const unsigned int single_offs[] = { OFF_SCRATCH1, OFF_SCRATCH2, OFF_SCRATCH3 };
    static const struct { LPTHREAD_START_ROUTINE fn; const char *name; unsigned int off; LONG expect; } phases[] = {
        { xadd_thread, "lock xadd  x2 threads", OFF_XADD,     (LONG)(2u * STRESS_ITERS) },
        { inc_thread,  "lock inc   x2 threads", OFF_INC,      (LONG)(2u * STRESS_ITERS) },
        { cas_thread,  "lock cmpxchg CAS loop", OFF_CAS,      (LONG)(2u * STRESS_ITERS) },
        { spin_thread, "xchg spinlock         ", OFF_SPINLOCK, (LONG)(2u * SPIN_ITERS) },
    };

    out_str( "MADEIRA-UNALIGNED: unaligned x86 atomics test starting\n" );

    if (!check_premise()) return 73;

    pIE = (interlocked_exchange_t)GetProcAddress( GetModuleHandleA( "kernel32.dll" ),
                                                  "InterlockedExchange" );
    if (!pIE) out_str( "MADEIRA-UNALIGNED: note: kernel32!InterlockedExchange not found, skipping that check\n" );

    for (i = 0; i < sizeof(single_offs) / sizeof(single_offs[0]); i++)
    {
        char line[96], *p = line;
        p = put_str( p, "MADEIRA-UNALIGNED: single-threaded checks at mod4=" );
        p = put_uint( p, (unsigned int)(ULONG_PTR)WORD( single_offs[i] ) & 3u );
        p = put_str( p, "\n" );
        *p = 0;
        out_str( line );
        if (!check_one_offset( single_offs[i], pIE )) return 71;
    }
    out_str( "MADEIRA-UNALIGNED: single-threaded semantics OK at offsets 1, 2 and 3\n" );

    for (i = 0; i < sizeof(phases) / sizeof(phases[0]); i++)
    {
        DWORD ms = 0;
        int r = run_two_threads( phases[i].fn, phases[i].name, phases[i].off,
                                 phases[i].expect, &ms );
        if (r == -2) return 72;
        if (r == -1)
        {
            out_str( "MADEIRA-UNALIGNED: FAIL timeout — a thread is wedged on a misaligned atomic\n" );
            return 74;
        }
        if (!r) return 71;
    }

    out_str( "MADEIRA-UNALIGNED: all checks passed\n" );
    return 70;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
