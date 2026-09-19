/* MADEIRA-TEMP: the stress self-test for the ml952 in-process event fast path
 * ("fastsync", WOW64_DESIGN.md section 6 / build/ntdll-unix/shims/ios_fastsync.h).
 *
 * WHAT IT CHECKS, AND WHY EACH CHECK IS HERE
 * ------------------------------------------
 * fastsync moves SetEvent / ResetEvent / WaitForSingleObject off the wineserver
 * and onto a shared cell word, which means the properties the server used to
 * guarantee structurally are now guaranteed by compare-and-swap ordering
 * instead.  Three of them can be broken without the game crashing -- it would
 * just deadlock, or run one frame ahead of itself -- so they are asserted here
 * rather than left to be noticed on a device:
 *
 *  1. PING-PONG (auto-reset, two threads).  100,000 round trips over a pair of
 *     auto-reset events, each side asserting that the shared counter has the
 *     exact value its turn implies.  A lost wakeup hangs; a doubled wakeup
 *     (two threads released by one SetEvent) shows up immediately as a
 *     counter that moved twice.  This is the exact shape of the traffic
 *     [srv-stats] measured on the 32-bit title: main thread <-> render thread,
 *     an auto-reset event in each direction.
 *
 *  2. EXACTLY-ONCE (auto-reset, many waiters).  Four threads wait on ONE
 *     auto-reset event; the main thread sets it N times with a full handshake
 *     between sets.  Exactly N wakeups must be observed in total -- never
 *     N+1, which is what a client CAS racing the server's claim would produce.
 *
 *  3. RELEASE-ALL (manual-reset).  Four threads wait on one manual-reset
 *     event; one SetEvent must release all four, and a following ResetEvent
 *     must make the next wait block again.  A manual event that is consumed
 *     like an auto-reset one passes test 1 and fails only here.
 *
 *  4. TIMEOUT, three ways.  A wait with a finite timeout on an event nobody
 *     sets must return WAIT_TIMEOUT, and must not return early -- the fast
 *     path adjusts a relative timeout by the time it already spent, and an
 *     arithmetic slip there turns every timed wait into a spin.  (a) 300 ms,
 *     longer than the fast-path cap, so the server gets a remainder: it must
 *     be neither short nor absurdly long.  (b) 1 ms, SHORTER than the cap, the
 *     one case where handing the server a zero remainder is right.  (c) twenty
 *     10 ms waits in a row must add up to at least 100 ms of real time -- a
 *     timed wait that returns instantly passes (a) and (b) only by luck but
 *     can never pass this, and "returns instantly" is exactly what turns a
 *     loader's retry delay into a busy loop that starves what it waits for.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' plus memset/memcpy and links
 * -nostdlib, so its only import is kernel32), no 64-bit division, no
 * int-to-double conversion.
 *
 *  5. THREAD-START HANDSHAKE with handle reuse (ml962).  This is the shape the
 *     device actually died on: a worker publishes a pointer and then signals a
 *     private auto-reset event, and its creator wakes and dereferences that
 *     pointer.  If the wait returns for any reason other than that SetEvent --
 *     because the handle resolved to ANOTHER event's cell, or because one set
 *     released two waiters -- the pointer is still NULL and a real program
 *     faults at NULL+small.  The event is created and closed FRESH on every one
 *     of 20,000 iterations so that handle values, cells and the client cache
 *     slot for that handle are all recycled under the test, which is what the
 *     seqlock-publish race needs.
 *
 *  6. SERVER-QUEUED waiter vs FAST-PATH waiter (ml962).  The fast path only
 *     parks for its cap (2 ms) and then hands the wait to the wineserver, so a
 *     slow handoff puts a waiter in the SERVER's queue while a second waiter is
 *     still on the cell.  One SetEvent must still release exactly one of them.
 *     ml952 released both: the client updated the cell AND sent `event_op
 *     SET_EVENT', and if the fast waiter took the token first the server's own
 *     set re-signalled the cell and woke a queued thread as well.  Round trips
 *     here are deliberately >5 ms so the server queue is the normal case.
 *
 *  7. MANUAL-RESET "loader done" under cell churn.  Four waiters park on one
 *     manual event while another thread creates and closes several hundred
 *     unrelated events, recycling cells and handle values underneath them.
 *     One SetEvent must release all four and no waiter may be released early.
 *
 *  8. TIMEOUT WITH A LATE SET.  A timed wait that IS satisfied, late enough to
 *     have passed through the fast path's cap and into the server, must report
 *     WAIT_OBJECT_0 -- and a timed wait whose set comes after the deadline must
 *     still report WAIT_TIMEOUT.  Both halves check the elapsed time.
 *
 *  9. EVENT INSIDE A FREED AND REALLOCATED STRUCT.  Same handshake as 5, but
 *     the handle and the payload live in a heap node that is freed and
 *     re-allocated every round, so the node address is recycled as well.
 *
 * 10. JOB SYSTEM (ml982).  Tests 1-9 each isolate one property with one wait
 *     shape.  This one reproduces the shape the device measurement actually
 *     showed -- a title whose worker pool is fed by one producer over a single
 *     auto-reset event, with every wait shape in the mix at once:
 *
 *       - 6 workers rotating, per iteration, through WaitForSingleObject
 *         INFINITE / 1 ms / 0 ms poll / WaitForMultipleObjects over TWO
 *         handles with a 50 ms timeout.  The same event is therefore waited on
 *         through the client fast path AND queued in the wineserver's own
 *         select at the same time, by different threads, continuously -- which
 *         is the one interleaving that needs the client and the server views
 *         of the signaled state to stay coherent (`waitN' was 474 per 10 s in
 *         the measurement, i.e. rare but always present).
 *       - a producer publishing bursts of 1-8 jobs, some of them SET through a
 *         handle freshly created by DuplicateHandle and closed straight after,
 *         so handle values and client cache slots for a LIVE event churn too.
 *       - a churn thread creating and closing unrelated events throughout, so
 *         server cells are recycled under everybody.
 *
 *     EXACT ACCOUNTING, which is what makes this a test rather than a soak:
 *     every job is produced once and, because a job is claimed with an atomic
 *     decrement of the outstanding count, can be consumed exactly once.  After
 *     each burst the producer waits for consumed == produced with a ONE SECOND
 *     deadline, and at the end the outstanding count must be zero: a lost
 *     wakeup that a soak test would hide as a stall is a failure here, and it
 *     names the counters.
 *
 *     It also asserts the two poll answers every round, because the read-only
 *     zero-timeout answer (MADEIRA_FS_POLLPEEK) is the half of this mechanism
 *     that is ON by default: a manual-reset event must read signaled TWICE
 *     after one SetEvent and not-signaled after ResetEvent, and an auto-reset
 *     event must be consumed by a poll EXACTLY once.
 *
 * Deliberate restrictions, the same ones the other tests in this directory
 * work under: no CRT (this file supplies `start' plus memset/memcpy and links
 * -nostdlib, so its only import is kernel32), no 64-bit division, no
 * int-to-double conversion.
 *
 * Exit status (the runtime reports it as "MADEIRA-EXIT: ... status=<n>"):
 *   46  every check passed
 *   50  CreateEvent/CreateThread failed
 *   51  ping-pong: a counter had the wrong value for whose turn it was
 *   52  ping-pong: a wait did not complete within the watchdog
 *   53  exactly-once: the wakeup total was not N
 *   54  manual-reset: SetEvent did not release every waiter
 *   55  manual-reset: the event stayed signaled after ResetEvent
 *   56  a finite-timeout wait did not return WAIT_TIMEOUT, or returned early
 *   57  handshake: the wait returned before the producer published its pointer
 *   58  server-queue vs fast path: one SetEvent released more than one waiter
 *   59  manual-reset under churn: released early, or not all waiters released
 *   60  late set: a satisfied timed wait reported the wrong result or time
 *   61  heap-node handshake: the wait returned before the producer published
 *   62  job system: a produced job was not consumed within one second
 *   63  job system: a multi-object wait was released by the wrong handle
 *   64  job system: a zero-timeout poll gave the wrong answer for the event
 */
#include <stddef.h>
#include <windows.h>

#define ROUNDS        100000u   /* ping-pong round trips */
#define WAITERS       4u        /* threads in tests 2 and 3 */
#define ONCE_ROUNDS   2000u     /* sets in the exactly-once test */
#define HS_ROUNDS     20000u    /* fresh-event handshakes, test 5 */
#define NODE_ROUNDS   5000u     /* heap-node handshakes, test 9 */
#define DR_ROUNDS     300u      /* slow sets in the server-queue test 6 */
#define CHURN_EVENTS  400u      /* events created/closed per churn pass, test 7 */
#define WATCHDOG_MS   20000u    /* no single wait in this test may take longer */
#define JOB_WORKERS   6u        /* worker threads in test 10                   */
#define JOB_MS        10000u    /* how long the job system runs, test 10       */
#define JOB_DRAIN_MS  1000u     /* per-burst deadline: no job may take longer  */

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

/* --------------------------------------------------------------- state */

static HANDLE ev_a, ev_b;           /* ping-pong, auto-reset, one per direction */
static HANDLE ev_once, ev_ack;      /* exactly-once: the event and its handshake */
static HANDLE ev_manual, ev_seen;   /* release-all: the event and its handshake  */

static volatile LONG counter;       /* ping-pong turn counter  */
static volatile LONG once_wakeups;  /* total wakeups, test 2   */
static volatile LONG manual_seen;   /* waiters released, test 3 */
static volatile LONG failure;       /* first failing exit code */

static void fail( LONG code )
{
    InterlockedCompareExchange( (LONG *)&failure, code, 0 );
}

/* A wait that must not block forever: a lost wakeup is the failure mode this
 * whole file exists to catch, and a hung test program reports nothing. */
static int wait_guarded( HANDLE h )
{
    DWORD r = WaitForSingleObject( h, WATCHDOG_MS );
    if (r == WAIT_OBJECT_0) return 1;
    fail( 52 );
    return 0;
}

/* ------------------------------------------------- 1: auto-reset ping-pong */

static DWORD WINAPI pong_thread( LPVOID arg )
{
    unsigned int i;

    for (i = 0; i < ROUNDS; i++)
    {
        if (!wait_guarded( ev_a )) return 1;
        /* our turn: the counter must be exactly odd-numbered here */
        if ((InterlockedExchangeAdd( (LONG *)&counter, 0 ) & 1) != 1) { fail( 51 ); return 1; }
        InterlockedIncrement( (LONG *)&counter );
        SetEvent( ev_b );
    }
    return 0;
}

static int run_pingpong(void)
{
    HANDLE thread;
    DWORD id;
    unsigned int i;

    counter = 0;
    if (!(thread = CreateThread( NULL, 0, pong_thread, NULL, 0, &id ))) return 50;

    for (i = 0; i < ROUNDS; i++)
    {
        if ((InterlockedExchangeAdd( (LONG *)&counter, 0 ) & 1) != 0) { fail( 51 ); break; }
        InterlockedIncrement( (LONG *)&counter );
        SetEvent( ev_a );
        if (!wait_guarded( ev_b )) break;
    }

    /* let the peer out if we broke early */
    SetEvent( ev_a );
    WaitForSingleObject( thread, WATCHDOG_MS );
    CloseHandle( thread );

    if (failure) return failure;
    if ((DWORD)counter != ROUNDS * 2)
    {
        line_2( "MADEIRA-SYNC: ping-pong counter=", (unsigned int)counter,
                " expected=", ROUNDS * 2, "" );
        return 51;
    }
    line_1( "MADEIRA-SYNC: ping-pong ", ROUNDS, " round trips OK" );
    return 0;
}

/* --------------------------------------------- 2: auto-reset exactly-once */

static DWORD WINAPI once_thread( LPVOID arg )
{
    for (;;)
    {
        if (WaitForSingleObject( ev_once, WATCHDOG_MS ) != WAIT_OBJECT_0) return 1;
        if (InterlockedExchangeAdd( (LONG *)&once_wakeups, 0 ) < 0) return 0;  /* shutdown */
        InterlockedIncrement( (LONG *)&once_wakeups );
        SetEvent( ev_ack );
    }
}

static int run_exactly_once(void)
{
    HANDLE threads[WAITERS];
    DWORD id;
    unsigned int i;

    once_wakeups = 0;
    for (i = 0; i < WAITERS; i++)
        if (!(threads[i] = CreateThread( NULL, 0, once_thread, NULL, 0, &id ))) return 50;

    /* One set, one acknowledgement.  If a single SetEvent ever released two of
     * the four waiters, two of them would increment and the total would run
     * ahead of the number of sets. */
    for (i = 0; i < ONCE_ROUNDS; i++)
    {
        SetEvent( ev_once );
        if (!wait_guarded( ev_ack )) break;
        if ((DWORD)InterlockedExchangeAdd( (LONG *)&once_wakeups, 0 ) != i + 1)
        {
            line_2( "MADEIRA-SYNC: exactly-once wakeups=",
                    (unsigned int)once_wakeups, " after sets=", i + 1, "" );
            fail( 53 );
            break;
        }
    }

    if ((DWORD)once_wakeups != ONCE_ROUNDS && !failure) fail( 53 );

    /* drain the waiters: push the counter negative so they return */
    InterlockedExchange( (LONG *)&once_wakeups, -1 );
    for (i = 0; i < WAITERS; i++) SetEvent( ev_once );
    for (i = 0; i < WAITERS; i++)
    {
        SetEvent( ev_once );
        WaitForSingleObject( threads[i], WATCHDOG_MS );
        CloseHandle( threads[i] );
    }

    if (failure) return failure;
    line_1( "MADEIRA-SYNC: exactly-once ", ONCE_ROUNDS, " sets, one wakeup each OK" );
    return 0;
}

/* ------------------------------------------- 3: manual-reset release-all */

static DWORD WINAPI manual_thread( LPVOID arg )
{
    if (WaitForSingleObject( ev_manual, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 54 ); return 1; }
    InterlockedIncrement( (LONG *)&manual_seen );
    SetEvent( ev_seen );
    return 0;
}

static int run_manual(void)
{
    HANDLE threads[WAITERS];
    DWORD id;
    unsigned int i;

    manual_seen = 0;
    for (i = 0; i < WAITERS; i++)
        if (!(threads[i] = CreateThread( NULL, 0, manual_thread, NULL, 0, &id ))) return 50;

    /* give them time to actually park rather than to find the event already set */
    Sleep( 50 );
    SetEvent( ev_manual );

    for (i = 0; i < WAITERS; i++)
    {
        WaitForSingleObject( threads[i], WATCHDOG_MS );
        CloseHandle( threads[i] );
    }
    if (failure) return failure;
    if ((DWORD)manual_seen != WAITERS)
    {
        line_2( "MADEIRA-SYNC: manual released=", (unsigned int)manual_seen,
                " expected=", WAITERS, "" );
        return 54;
    }

    /* still signaled (manual events are not consumed), then not */
    if (WaitForSingleObject( ev_manual, 0 ) != WAIT_OBJECT_0) return 55;
    ResetEvent( ev_manual );
    if (WaitForSingleObject( ev_manual, 0 ) != WAIT_TIMEOUT) return 55;

    line_1( "MADEIRA-SYNC: manual-reset released all ", WAITERS, " waiters OK" );
    return 0;
}

/* ------------------------------------------------------------ 4: timeout */

static int run_timeout(void)
{
    DWORD t0, spent, r;
    unsigned int i;

    /* (a) LONGER THAN THE FAST-PATH CAP.  The fast path parks for at most its
     *     cap (2 ms) and then hands the REMAINDER to the server.  If that
     *     subtraction is wrong the wait comes back early -- and "early" here
     *     means a remainder of zero, which server_wait treats as a poll, so
     *     the whole 300 ms evaporates and WAIT_TIMEOUT arrives instantly. */
    ResetEvent( ev_a );
    t0 = GetTickCount();
    r = WaitForSingleObject( ev_a, 300 );
    spent = GetTickCount() - t0;

    if (r != WAIT_TIMEOUT)
    {
        line_1( "MADEIRA-SYNC: timed wait returned ", (unsigned int)r, " not WAIT_TIMEOUT" );
        return 56;
    }
    if (spent + 30 < 300)
    {
        line_2( "MADEIRA-SYNC: timed wait returned after ", spent, " ms, wanted ", 300, " ms" );
        return 56;
    }
    /* ... and not absurdly LATE either: the remainder must be the caller's
     * timeout less the park, not the caller's timeout plus it. */
    if (spent > 2000)
    {
        line_2( "MADEIRA-SYNC: timed wait took ", spent, " ms for a ", 300, " ms timeout" );
        return 56;
    }
    line_1( "MADEIRA-SYNC: 300 ms timed wait returned WAIT_TIMEOUT after ", spent, " ms OK" );

    /* (b) SHORTER THAN THE FAST-PATH CAP.  Here the fast path is allowed to
     *     consume the whole timeout and hand the server a zero remainder --
     *     the one case where that is the right answer.  It must still be a
     *     WAIT_TIMEOUT and it must still come back promptly. */
    ResetEvent( ev_a );
    t0 = GetTickCount();
    r = WaitForSingleObject( ev_a, 1 );
    spent = GetTickCount() - t0;
    if (r != WAIT_TIMEOUT)
    {
        line_1( "MADEIRA-SYNC: 1 ms timed wait returned ", (unsigned int)r, " not WAIT_TIMEOUT" );
        return 56;
    }
    if (spent > 500)
    {
        line_2( "MADEIRA-SYNC: 1 ms timed wait took ", spent, " ms, wanted about ", 1, " ms" );
        return 56;
    }

    /* (c) A RUN OF TIMED WAITS MUST ACCUMULATE REAL TIME.  This is the shape a
     *     loader uses a timed wait for -- as a sleep, or as a retry delay -- and
     *     it is what turns a wait that returns instantly into a busy loop that
     *     never lets the thing it is waiting for run.  Twenty 10 ms waits on an
     *     event nobody sets cannot take less than 100 ms in total. */
    ResetEvent( ev_a );
    t0 = GetTickCount();
    for (i = 0; i < 20; i++)
    {
        if (WaitForSingleObject( ev_a, 10 ) != WAIT_TIMEOUT)
        {
            line_1( "MADEIRA-SYNC: 10 ms timed wait ", i, " was not WAIT_TIMEOUT" );
            return 56;
        }
    }
    spent = GetTickCount() - t0;
    if (spent < 100)
    {
        line_2( "MADEIRA-SYNC: 20 x 10 ms timed waits took ", spent,
                " ms, cannot be under ", 100, " ms" );
        return 56;
    }
    line_1( "MADEIRA-SYNC: sub-cap + repeated timed waits OK (20 x 10 ms took ", spent, " ms)" );
    return 0;
}

/* ------------------------------------------- 5: thread-start handshake */

/* The device failure, reduced: the creator wakes on the worker's SetEvent and
 * immediately dereferences what the worker published.  Everything the fast
 * path can get wrong -- a handle resolving to a stranger's cell, one set
 * releasing two waiters, a token surviving from a previous round -- shows up
 * here as a NULL read, which is precisely what the three device logs showed.
 *
 * The event is CreateEvent'd and CloseHandle'd every round on purpose: handle
 * values, server cells and the client's (handle >> 2) cache slot are all
 * recycled thousands of times a second, which is the state the publish race
 * needs and which a long-lived event never reaches. */
static HANDLE  hs_start;
static volatile HANDLE hs_ev;        /* this round's fresh auto-reset event */
static volatile LONG  *hs_ptr;       /* what the worker publishes */
static volatile LONG   hs_payload;
static volatile LONG   hs_stop;

static DWORD WINAPI hs_thread( LPVOID arg )
{
    for (;;)
    {
        HANDLE ev;

        if (WaitForSingleObject( hs_start, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 52 ); return 1; }
        if (InterlockedExchangeAdd( (LONG *)&hs_stop, 0 )) return 0;

        ev = hs_ev;
        /* publish the payload, THEN signal: the creator may only observe the
         * signal after the store, which is what the wait is supposed to mean */
        hs_payload = 0x5eed;
        InterlockedExchange( (LONG *)&hs_ptr, (LONG)(LONG_PTR)&hs_payload );
        SetEvent( ev );
    }
}

static int run_handshake(void)
{
    HANDLE thread;
    DWORD id;
    unsigned int i;

    hs_stop = 0;
    if (!(thread = CreateThread( NULL, 0, hs_thread, NULL, 0, &id ))) return 50;

    for (i = 0; i < HS_ROUNDS; i++)
    {
        HANDLE ev = CreateEventA( NULL, FALSE, FALSE, NULL );   /* auto-reset, fresh */

        if (!ev) { fail( 50 ); break; }
        InterlockedExchange( (LONG *)&hs_ptr, 0 );
        hs_ev = ev;
        SetEvent( hs_start );

        if (WaitForSingleObject( ev, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 52 ); CloseHandle( ev ); break; }
        if (!InterlockedExchangeAdd( (LONG *)&hs_ptr, 0 ))
        {
            line_1( "MADEIRA-SYNC: handshake round ", i, " woke with a NULL pointer" );
            fail( 57 );
            CloseHandle( ev );
            break;
        }
        if (*hs_ptr != 0x5eed) { fail( 57 ); CloseHandle( ev ); break; }
        CloseHandle( ev );
    }

    InterlockedExchange( (LONG *)&hs_stop, 1 );
    SetEvent( hs_start );
    WaitForSingleObject( thread, WATCHDOG_MS );
    CloseHandle( thread );

    if (failure) return failure;
    line_1( "MADEIRA-SYNC: thread-start handshake ", HS_ROUNDS, " fresh events OK" );
    return 0;
}

/* --------------------------- 6: server-queued waiter vs fast-path waiter */

/* Two waiters park long enough (>5 ms, the fast path caps at 2 ms) that they
 * are sitting in the WINESERVER's wait queue, while a third polls the same
 * event with a short timeout and therefore keeps arriving fresh on the cell.
 * Each SetEvent must be paid out exactly once no matter which of the three
 * collects it. */
static HANDLE dr_ev, dr_ack;
static volatile LONG dr_count;
static volatile LONG dr_stop;

static DWORD WINAPI dr_parked_thread( LPVOID arg )
{
    while (!InterlockedExchangeAdd( (LONG *)&dr_stop, 0 ))
    {
        if (WaitForSingleObject( dr_ev, 200 ) != WAIT_OBJECT_0) continue;
        InterlockedIncrement( (LONG *)&dr_count );
        SetEvent( dr_ack );
    }
    return 0;
}

static DWORD WINAPI dr_poll_thread( LPVOID arg )
{
    while (!InterlockedExchangeAdd( (LONG *)&dr_stop, 0 ))
    {
        if (WaitForSingleObject( dr_ev, 1 ) != WAIT_OBJECT_0) continue;
        InterlockedIncrement( (LONG *)&dr_count );
        SetEvent( dr_ack );
    }
    return 0;
}

static int run_double_release(void)
{
    HANDLE threads[3];
    DWORD id;
    unsigned int i;

    dr_count = 0;
    dr_stop  = 0;
    if (!(threads[0] = CreateThread( NULL, 0, dr_parked_thread, NULL, 0, &id ))) return 50;
    if (!(threads[1] = CreateThread( NULL, 0, dr_parked_thread, NULL, 0, &id ))) return 50;
    if (!(threads[2] = CreateThread( NULL, 0, dr_poll_thread,   NULL, 0, &id ))) return 50;

    for (i = 0; i < DR_ROUNDS; i++)
    {
        /* long enough that the parked pair has given its wait to the server */
        Sleep( 6 );
        SetEvent( dr_ev );
        if (!wait_guarded( dr_ack )) break;
        if ((DWORD)InterlockedExchangeAdd( (LONG *)&dr_count, 0 ) != i + 1)
        {
            line_2( "MADEIRA-SYNC: server-queue wakeups=", (unsigned int)dr_count,
                    " after sets=", i + 1, "" );
            fail( 58 );
            break;
        }
    }

    InterlockedExchange( (LONG *)&dr_stop, 1 );
    for (i = 0; i < 3; i++)
    {
        SetEvent( dr_ev );
        WaitForSingleObject( threads[i], WATCHDOG_MS );
        CloseHandle( threads[i] );
    }

    if (failure) return failure;
    line_1( "MADEIRA-SYNC: server-queued vs fast waiter ", DR_ROUNDS, " sets, one wakeup each OK" );
    return 0;
}

/* ------------------------------- 7: manual-reset "loader done" under churn */

static HANDLE ld_ev;
static volatile LONG ld_seen;
static volatile LONG ld_early;
static volatile LONG ld_open;      /* 0 until the setter is allowed to signal */
static volatile LONG ld_churn_stop;

static DWORD WINAPI ld_thread( LPVOID arg )
{
    if (WaitForSingleObject( ld_ev, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 59 ); return 1; }
    /* released before the setter ever signalled => a stranger's cell, or a
     * token left over from an earlier event that owned this cell */
    if (!InterlockedExchangeAdd( (LONG *)&ld_open, 0 )) InterlockedIncrement( (LONG *)&ld_early );
    InterlockedIncrement( (LONG *)&ld_seen );
    return 0;
}

static DWORD WINAPI ld_churn_thread( LPVOID arg )
{
    while (!InterlockedExchangeAdd( (LONG *)&ld_churn_stop, 0 ))
    {
        unsigned int i;
        for (i = 0; i < CHURN_EVENTS; i++)
        {
            HANDLE e = CreateEventA( NULL, (i & 1) ? TRUE : FALSE, (i & 2) ? TRUE : FALSE, NULL );
            if (!e) return 1;
            SetEvent( e );
            ResetEvent( e );
            CloseHandle( e );
        }
    }
    return 0;
}

static int run_loader_manual(void)
{
    HANDLE threads[WAITERS], churn;
    DWORD id;
    unsigned int i;

    ld_seen = ld_early = ld_open = ld_churn_stop = 0;
    if (!(ld_ev = CreateEventA( NULL, TRUE, FALSE, NULL ))) return 50;
    if (!(churn = CreateThread( NULL, 0, ld_churn_thread, NULL, 0, &id ))) return 50;
    for (i = 0; i < WAITERS; i++)
        if (!(threads[i] = CreateThread( NULL, 0, ld_thread, NULL, 0, &id ))) return 50;

    Sleep( 200 );                       /* everyone is parked, cells are churning */
    InterlockedExchange( (LONG *)&ld_open, 1 );
    SetEvent( ld_ev );

    for (i = 0; i < WAITERS; i++)
    {
        WaitForSingleObject( threads[i], WATCHDOG_MS );
        CloseHandle( threads[i] );
    }
    InterlockedExchange( (LONG *)&ld_churn_stop, 1 );
    WaitForSingleObject( churn, WATCHDOG_MS );
    CloseHandle( churn );

    if (failure) return failure;
    if (ld_early)
    {
        line_1( "MADEIRA-SYNC: loader manual released ", (unsigned int)ld_early, " waiters EARLY" );
        return 59;
    }
    if ((DWORD)ld_seen != WAITERS)
    {
        line_2( "MADEIRA-SYNC: loader manual released=", (unsigned int)ld_seen,
                " expected=", WAITERS, "" );
        return 59;
    }
    if (WaitForSingleObject( ld_ev, 0 ) != WAIT_OBJECT_0) return 59;
    ResetEvent( ld_ev );
    if (WaitForSingleObject( ld_ev, 0 ) != WAIT_TIMEOUT) return 59;
    CloseHandle( ld_ev );

    line_1( "MADEIRA-SYNC: manual 'loader done' under cell churn, ", WAITERS, " waiters OK" );
    return 0;
}

/* -------------------------------------------------- 8: timeout + late set */

static HANDLE lt_ev;
static volatile LONG lt_delay_ms;

static DWORD WINAPI lt_thread( LPVOID arg )
{
    Sleep( (DWORD)InterlockedExchangeAdd( (LONG *)&lt_delay_ms, 0 ) );
    SetEvent( lt_ev );
    return 0;
}

static int run_late_set(void)
{
    HANDLE thread;
    DWORD id, t0, spent, r;

    if (!(lt_ev = CreateEventA( NULL, FALSE, FALSE, NULL ))) return 50;

    /* (a) the set lands well past the 2 ms fast-path cap but inside the
     *     caller's 400 ms: the wait must be SATISFIED, not timed out */
    InterlockedExchange( (LONG *)&lt_delay_ms, 150 );
    if (!(thread = CreateThread( NULL, 0, lt_thread, NULL, 0, &id ))) return 50;
    t0 = GetTickCount();
    r = WaitForSingleObject( lt_ev, 400 );
    spent = GetTickCount() - t0;
    WaitForSingleObject( thread, WATCHDOG_MS );
    CloseHandle( thread );
    if (r != WAIT_OBJECT_0)
    {
        line_1( "MADEIRA-SYNC: late set gave ", (unsigned int)r, " not WAIT_OBJECT_0" );
        CloseHandle( lt_ev );
        return 60;
    }
    if (spent + 40 < 150)
    {
        line_2( "MADEIRA-SYNC: late set woke after ", spent, " ms, set was at ", 150, " ms" );
        CloseHandle( lt_ev );
        return 60;
    }

    /* (b) the set lands AFTER the deadline: WAIT_TIMEOUT, and the leftover
     *     token must not satisfy a later wait that nobody set */
    ResetEvent( lt_ev );
    InterlockedExchange( (LONG *)&lt_delay_ms, 400 );
    if (!(thread = CreateThread( NULL, 0, lt_thread, NULL, 0, &id ))) { CloseHandle( lt_ev ); return 50; }
    t0 = GetTickCount();
    r = WaitForSingleObject( lt_ev, 150 );
    spent = GetTickCount() - t0;
    if (r != WAIT_TIMEOUT || spent + 30 < 150)
    {
        line_2( "MADEIRA-SYNC: post-deadline set gave ", (unsigned int)r, " after ", spent, " ms" );
        WaitForSingleObject( thread, WATCHDOG_MS );
        CloseHandle( thread );
        CloseHandle( lt_ev );
        return 60;
    }
    WaitForSingleObject( thread, WATCHDOG_MS );
    CloseHandle( thread );
    /* the set did happen, so exactly one token is owed and exactly one wait
     * may collect it */
    if (WaitForSingleObject( lt_ev, 1000 ) != WAIT_OBJECT_0) { CloseHandle( lt_ev ); return 60; }
    if (WaitForSingleObject( lt_ev, 0 ) != WAIT_TIMEOUT) { CloseHandle( lt_ev ); return 60; }
    CloseHandle( lt_ev );

    line_1( "MADEIRA-SYNC: late-set timed waits OK (", spent, " ms timeout leg)" );
    return 0;
}

/* --------------------------- 9: event inside a freed/reallocated struct */

struct node
{
    HANDLE        ev;
    volatile LONG value;
};

static volatile LONG nd_node;     /* struct node *, published to the worker */
static HANDLE nd_start;
static volatile LONG nd_stop;

static DWORD WINAPI nd_thread( LPVOID arg )
{
    for (;;)
    {
        struct node *n;

        if (WaitForSingleObject( nd_start, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 52 ); return 1; }
        if (InterlockedExchangeAdd( (LONG *)&nd_stop, 0 )) return 0;
        n = (struct node *)(LONG_PTR)InterlockedExchangeAdd( (LONG *)&nd_node, 0 );
        if (!n) { fail( 61 ); return 1; }
        InterlockedExchange( (LONG *)&n->value, 0x1dea );
        SetEvent( n->ev );
    }
}

static int run_node_handshake(void)
{
    HANDLE thread, heap = GetProcessHeap();
    DWORD id;
    unsigned int i;

    nd_stop = 0;
    if (!(thread = CreateThread( NULL, 0, nd_thread, NULL, 0, &id ))) return 50;

    for (i = 0; i < NODE_ROUNDS; i++)
    {
        struct node *n = (struct node *)HeapAlloc( heap, 0, sizeof(*n) );

        if (!n) { fail( 50 ); break; }
        n->value = 0;
        if (!(n->ev = CreateEventA( NULL, FALSE, FALSE, NULL ))) { HeapFree( heap, 0, n ); fail( 50 ); break; }
        InterlockedExchange( (LONG *)&nd_node, (LONG)(LONG_PTR)n );
        SetEvent( nd_start );

        if (WaitForSingleObject( n->ev, WATCHDOG_MS ) != WAIT_OBJECT_0) { fail( 52 ); }
        else if (InterlockedExchangeAdd( (LONG *)&n->value, 0 ) != 0x1dea )
        {
            line_1( "MADEIRA-SYNC: node round ", i, " woke before the producer wrote" );
            fail( 61 );
        }
        CloseHandle( n->ev );
        InterlockedExchange( (LONG *)&nd_node, 0 );
        HeapFree( heap, 0, n );
        if (failure) break;
    }

    InterlockedExchange( (LONG *)&nd_stop, 1 );
    SetEvent( nd_start );
    WaitForSingleObject( thread, WATCHDOG_MS );
    CloseHandle( thread );

    if (failure) return failure;
    line_1( "MADEIRA-SYNC: heap-node handshake ", NODE_ROUNDS, " rounds OK" );
    return 0;
}

/* ------------------------------------------------------- 10: job system */

/* jb_ready is the ONE auto-reset event every worker contends for; jb_idle is a
 * manual-reset event that is never set, and exists so that a quarter of the
 * waits are WaitForMultipleObjects over two handles -- which is a wineserver
 * select on jb_ready, running concurrently with the other workers' fast-path
 * waits on the same object.  jb_mr / jb_solo are the producer's own poll
 * assertions. */
static HANDLE jb_ready, jb_idle, jb_mr, jb_solo;
static volatile LONG jb_avail;      /* jobs published and not yet taken      */
static volatile LONG jb_produced;   /* total published                       */
static volatile LONG jb_consumed;   /* total taken                           */
static volatile LONG jb_spurious;   /* releases that found no job (legal)    */
static volatile LONG jb_stop;       /* 1 = drain and exit                    */
static volatile LONG jb_exited;     /* workers that have left the loop       */
static volatile LONG jb_churn_stop;

/* AN AUTO-RESET EVENT IS A FLAG, NOT A COUNT -- which is why this is modelled
 * the way a real job system models it.  N SetEvent calls on an unwaited
 * auto-reset event release ONE thread, not N, so a burst is published as a
 * counter plus ONE signal and the released worker hands the baton on: take one
 * job, and if the counter is still positive signal the next worker.  The chain
 * cannot break, because the only worker that does not signal is the one that
 * took the last job.
 *
 * A release that finds the counter empty is therefore LEGAL here (a leftover
 * signal from a previous burst, or two workers racing for the last job) and is
 * counted rather than failed -- "exactly one waiter per SetEvent" is what
 * tests 2 and 6 assert, with handshakes that make it unambiguous.  What this
 * test asserts is the property those cannot: over ten seconds of every wait
 * shape at once, every job is taken exactly once and none takes longer than a
 * second, which is what a lost wakeup destroys. */
static DWORD WINAPI jb_worker( LPVOID arg )
{
    unsigned int idx = (unsigned int)(LONG_PTR)arg, n = 0;

    for (;;)
    {
        HANDLE two[2];
        DWORD r;
        LONG left;

        if (InterlockedExchangeAdd( (LONG *)&jb_stop, 0 )) break;

        /* every shape, interleaved, on the same handle */
        switch ((idx + n++) & 3)
        {
        case 0:
            r = WaitForSingleObject( jb_ready, INFINITE );
            break;
        case 1:
            r = WaitForSingleObject( jb_ready, 1 );
            break;
        case 2:
            r = WaitForSingleObject( jb_ready, 0 );
            break;
        default:
            two[0] = jb_ready;
            two[1] = jb_idle;
            r = WaitForMultipleObjects( 2, two, FALSE, 50 );
            /* jb_idle is created reset and never set: a release on it means a
             * handle resolved to the wrong object, which is the shape the
             * ml962 torn cache publish failed in */
            if (r == WAIT_OBJECT_0 + 1) { fail( 63 ); goto out; }
            break;
        }

        if (r != WAIT_OBJECT_0) continue;            /* timed out: go round again */
        if (InterlockedExchangeAdd( (LONG *)&jb_stop, 0 )) break;   /* draining */

        if ((left = InterlockedDecrement( (LONG *)&jb_avail )) < 0)
        {
            InterlockedIncrement( (LONG *)&jb_avail );
            InterlockedIncrement( (LONG *)&jb_spurious );
            continue;
        }
        InterlockedIncrement( (LONG *)&jb_consumed );
        if (left > 0) SetEvent( jb_ready );          /* pass the baton on */
    }
out:
    InterlockedIncrement( (LONG *)&jb_exited );
    return 0;
}

static DWORD WINAPI jb_churn_thread( LPVOID arg )
{
    while (!InterlockedExchangeAdd( (LONG *)&jb_churn_stop, 0 ))
    {
        unsigned int i;
        for (i = 0; i < CHURN_EVENTS; i++)
        {
            HANDLE e = CreateEventA( NULL, (i & 1) ? TRUE : FALSE, (i & 2) ? TRUE : FALSE, NULL );
            if (!e) return 1;
            SetEvent( e );
            ResetEvent( e );
            CloseHandle( e );
        }
        Sleep( 1 );
    }
    return 0;
}

/* The two poll answers, asserted once per burst.  These are cheap and they are
 * the exact properties the read-only zero-timeout answer has to have. */
static int jb_check_polls(void)
{
    /* manual-reset: one set, signaled for ever (twice in a row proves the poll
     * did not consume it), then not signaled after the reset */
    SetEvent( jb_mr );
    if (WaitForSingleObject( jb_mr, 0 ) != WAIT_OBJECT_0) return 64;
    if (WaitForSingleObject( jb_mr, 0 ) != WAIT_OBJECT_0) return 64;
    ResetEvent( jb_mr );
    if (WaitForSingleObject( jb_mr, 0 ) != WAIT_TIMEOUT) return 64;

    /* auto-reset: one set, consumed by exactly one poll */
    SetEvent( jb_solo );
    if (WaitForSingleObject( jb_solo, 0 ) != WAIT_OBJECT_0) return 64;
    if (WaitForSingleObject( jb_solo, 0 ) != WAIT_TIMEOUT) return 64;
    return 0;
}

static int run_job_system(void)
{
    HANDLE workers[JOB_WORKERS], churn;
    DWORD id, t_end, deadline;
    unsigned int i, round = 0, rc = 0;

    jb_avail = jb_produced = jb_consumed = jb_spurious = 0;
    jb_stop = jb_exited = jb_churn_stop = 0;

    if (!(jb_ready = CreateEventA( NULL, FALSE, FALSE, NULL ))) return 50;
    if (!(jb_idle  = CreateEventA( NULL, TRUE,  FALSE, NULL ))) return 50;
    if (!(jb_mr    = CreateEventA( NULL, TRUE,  FALSE, NULL ))) return 50;
    if (!(jb_solo  = CreateEventA( NULL, FALSE, FALSE, NULL ))) return 50;
    if (!(churn = CreateThread( NULL, 0, jb_churn_thread, NULL, 0, &id ))) return 50;
    for (i = 0; i < JOB_WORKERS; i++)
        if (!(workers[i] = CreateThread( NULL, 0, jb_worker, (LPVOID)(LONG_PTR)i, 0, &id )))
            return 50;

    t_end = GetTickCount() + JOB_MS;
    while ((int)(t_end - GetTickCount()) > 0)
    {
        unsigned int burst = 1 + (round & 7), k;

        /* publish the whole burst BEFORE the signal: a worker must never see a
         * token without a job behind it any earlier than it has to */
        for (k = 0; k < burst; k++)
        {
            InterlockedIncrement( (LONG *)&jb_avail );
            InterlockedIncrement( (LONG *)&jb_produced );
        }

        if ((round & 15) == 0)
        {
            /* a SECOND live handle to the same event, used once and closed: a
             * fresh handle value, a fresh client cache slot and an eviction,
             * all against an event that stays alive throughout */
            HANDLE dup = NULL;
            if (DuplicateHandle( GetCurrentProcess(), jb_ready, GetCurrentProcess(),
                                 &dup, 0, FALSE, DUPLICATE_SAME_ACCESS ) && dup)
            {
                SetEvent( dup );
                CloseHandle( dup );
            }
            else SetEvent( jb_ready );
        }
        else SetEvent( jb_ready );

        /* Every job must be taken, and taken within a second.  This is where a
         * lost wakeup lands: the counters simply stop converging. */
        deadline = GetTickCount() + JOB_DRAIN_MS;
        for (;;)
        {
            LONG done = InterlockedExchangeAdd( (LONG *)&jb_consumed, 0 );
            LONG made = InterlockedExchangeAdd( (LONG *)&jb_produced, 0 );

            if (failure) { rc = failure; goto stop; }
            if (done == made) break;
            if ((int)(deadline - GetTickCount()) <= 0)
            {
                line_2( "MADEIRA-SYNC: job system stalled, consumed=", (unsigned int)done,
                        " produced=", (unsigned int)made, "" );
                rc = 62;
                goto stop;
            }
            Sleep( 0 );
        }

        if ((rc = jb_check_polls())) goto stop;
        round++;
    }

stop:
    /* Drain: workers in an INFINITE wait need one token each to notice.  Keep
     * setting until every one of them has left, bounded so a genuine hang is
     * still reported rather than hanging the test. */
    InterlockedExchange( (LONG *)&jb_stop, 1 );
    for (i = 0; i < 20000u && (DWORD)InterlockedExchangeAdd( (LONG *)&jb_exited, 0 ) < JOB_WORKERS; i++)
    {
        SetEvent( jb_ready );
        Sleep( 1 );
    }
    for (i = 0; i < JOB_WORKERS; i++)
    {
        WaitForSingleObject( workers[i], WATCHDOG_MS );
        CloseHandle( workers[i] );
    }
    InterlockedExchange( (LONG *)&jb_churn_stop, 1 );
    WaitForSingleObject( churn, WATCHDOG_MS );
    CloseHandle( churn );
    CloseHandle( jb_ready );
    CloseHandle( jb_idle );
    CloseHandle( jb_mr );
    CloseHandle( jb_solo );

    if (rc) return rc;
    if (failure) return failure;
    if (jb_consumed != jb_produced || jb_avail)
    {
        line_2( "MADEIRA-SYNC: job system consumed=", (unsigned int)jb_consumed,
                " produced=", (unsigned int)jb_produced, "" );
        return 62;
    }
    line_2( "MADEIRA-SYNC: job system ", (unsigned int)jb_produced,
            " jobs over ", round, " bursts, each consumed exactly once OK" );
    line_2( "MADEIRA-SYNC:   workers=", JOB_WORKERS, " spurious_wakes=",
            (unsigned int)jb_spurious, " OK" );
    return 0;
}

/* --------------------------------------------------------------- driver */

static int run_all(void)
{
    int rc;

    ev_a      = CreateEventA( NULL, FALSE, FALSE, NULL );   /* auto-reset */
    ev_b      = CreateEventA( NULL, FALSE, FALSE, NULL );
    ev_once   = CreateEventA( NULL, FALSE, FALSE, NULL );
    ev_ack    = CreateEventA( NULL, FALSE, FALSE, NULL );
    ev_manual = CreateEventA( NULL, TRUE,  FALSE, NULL );   /* manual-reset */
    ev_seen   = CreateEventA( NULL, FALSE, FALSE, NULL );
    hs_start  = CreateEventA( NULL, FALSE, FALSE, NULL );
    dr_ev     = CreateEventA( NULL, FALSE, FALSE, NULL );
    dr_ack    = CreateEventA( NULL, FALSE, FALSE, NULL );
    nd_start  = CreateEventA( NULL, FALSE, FALSE, NULL );
    if (!ev_a || !ev_b || !ev_once || !ev_ack || !ev_manual || !ev_seen) return 50;
    if (!hs_start || !dr_ev || !dr_ack || !nd_start) return 50;

    out_str( "MADEIRA-SYNC: fastsync stress test starting\n" );

    if ((rc = run_pingpong())) return rc;
    if ((rc = run_exactly_once())) return rc;
    if ((rc = run_manual())) return rc;
    if ((rc = run_timeout())) return rc;
    if ((rc = run_handshake())) return rc;
    if ((rc = run_double_release())) return rc;
    if ((rc = run_loader_manual())) return rc;
    if ((rc = run_late_set())) return rc;
    if ((rc = run_node_handshake())) return rc;
    if ((rc = run_job_system())) return rc;

    out_str( "MADEIRA-SYNC: all checks passed\n" );
    return 46;
}

void __cdecl start(void)
{
    ExitProcess( (UINT)run_all() );
}
