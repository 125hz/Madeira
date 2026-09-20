/* MADEIRA ml1010: host model of the fastsync SEMAPHORE cell protocol.
 *
 * The event model next door (fastsync-cellrace.c) reproduces one specific
 * residual.  This one is an exact-accounting model of the whole semaphore
 * protocol, because a semaphore carries a COUNT rather than a token and the
 * properties that have to hold are arithmetic ones that a soak test would hide
 * as a stall:
 *
 *   A. CONSERVATION.  Every token produced is consumed at most once, and no
 *      token is lost: produced == consumed + whatever is left in the cell.
 *      Enforced by a shadow ledger -- each consumer that wins a CAS takes one
 *      unit off a separate atomic "real work" counter which the producers add
 *      to BEFORE they release, so a consumer that proceeds without a token
 *      drives that counter negative and is caught exactly.
 *   B. NO LOST WAKEUP.  Consumers park on the cell with the shipping Dekker
 *      pairing (waiters++ / load count, against CAS count += n / load
 *      waiters).  At the end, with the producers stopped and every token
 *      drained, no consumer may still be parked.
 *   C. TIMED WAITS.  A consumer that reports a timeout must not be holding a
 *      token: a timed-out waiter performs no successful CAS, which the ledger
 *      would otherwise catch as a token that was consumed and dropped.
 *   D. OVERFLOW.  count + n > max refuses the WHOLE release and changes
 *      nothing, single- and multi-threaded.
 *   E. GENERATION.  A cell destroyed and handed to a different semaphore under
 *      a consumer's feet must never let that consumer's CAS succeed.
 *
 * The server half is modelled too -- a thread that CAS-claims tokens the way
 * semaphore_sync_signaled() does and hands them to "queued" waiters -- so the
 * mixed client/server case is under test, not just the client one.
 *
 * Everything is compiled against the REAL shipping header
 * (build/ntdll-unix/shims/ios_fastsync.h), so the packing, the accessors, the
 * sign handling and the struct layout under test are the shipping ones.
 *
 * Exit 0 = every check passed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "ios_fastsync.h"

#define NPRODUCERS      3
#define NCONSUMERS      6
#define NSERVER         1           /* threads modelling the wineserver queue  */
#define RUN_MS       2500
#define SEM_MAX        64

/* ------------------------------------------------------------------------
 * The cell under test, plus the futex the header would use.  os_sync_* does
 * not exist on Linux, so the park/wake pair is modelled with a condvar keyed
 * on the SAME word the shipping code parks on (the state half of `sg'):
 * madeira_fast_park( addr, val, ns ) == "sleep while *addr == val".  The
 * protocol under test is the CAS ordering and the waiter accounting, which
 * are identical whichever primitive delivers the wake.
 * ---------------------------------------------------------------------- */

static struct madeira_sync_cell cell;

static pthread_mutex_t park_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  park_cnd = PTHREAD_COND_INITIALIZER;

static void park_on( const int *addr, int val, unsigned long long ns )
{
    struct timespec ts;

    pthread_mutex_lock( &park_mtx );
    if (atomic_load_explicit( (const _Atomic int *)addr, memory_order_seq_cst ) == val)
    {
        clock_gettime( CLOCK_REALTIME, &ts );
        ts.tv_nsec += (long)(ns % 1000000000ull);
        ts.tv_sec  += (time_t)(ns / 1000000000ull);
        if (ts.tv_nsec >= 1000000000L) { ts.tv_nsec -= 1000000000L; ts.tv_sec++; }
        pthread_cond_timedwait( &park_cnd, &park_mtx, &ts );
    }
    pthread_mutex_unlock( &park_mtx );
}

static void wake_all( void )
{
    pthread_mutex_lock( &park_mtx );
    pthread_cond_broadcast( &park_cnd );
    pthread_mutex_unlock( &park_mtx );
}

/* ------------------------------------------------------------------------
 * The ledger.  `work' is incremented by a producer BEFORE it publishes the
 * tokens and decremented by a consumer AFTER it has won a CAS, so a consumer
 * that proceeds without a real token takes it below zero.
 * ---------------------------------------------------------------------- */

static _Atomic long  work;
static _Atomic unsigned long produced, consumed, timeouts, parked_now;
static _Atomic unsigned long overflow_refused, srv_served, parks, no_work;
static _Atomic int stop;                 /* harness only, atomic so a TSan
                                          * report can only ever be about the
                                          * protocol under test */
static unsigned int my_gen;          /* the generation every thread resolved */

/* ---- the CLIENT's release, verbatim in shape with the shipping
 * madeira_fast_sem_release() in ntdll/unix/sync.c -------------------------- */

static int client_release( unsigned int gen, unsigned int n, unsigned int *prev )
{
    uint64_t sg;
    int cur;

    for (;;)
    {
        sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
        if (MADEIRA_SG_GEN( sg ) != gen) return -1;              /* recycled: server */
        cur = MADEIRA_SG_STATE( sg );
        if (cur < 0) return -1;                                  /* DISABLED */
        if (n > cell.smax || (unsigned int)cur + n > cell.smax)
        {
            atomic_fetch_add_explicit( &overflow_refused, 1, memory_order_relaxed );
            return 0;                                            /* LIMIT_EXCEEDED */
        }
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( gen, cur + (int)n ),
                memory_order_seq_cst, memory_order_seq_cst )) break;
    }
    if (prev) *prev = (unsigned int)cur;

    /* Dekker half #2: the CAS above and this load are both seq_cst. */
    if (n && atomic_load_explicit( (_Atomic int *)&cell.waiters, memory_order_seq_cst ))
        wake_all();
    return 1;
}

/* ---- the CLIENT's "take one token", verbatim in shape with
 * madeira_fast_try()'s semaphore arm ------------------------------------- */

static int client_try( unsigned int gen )
{
    uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (MADEIRA_SG_GEN( sg ) != gen) return 0;
        if (cur <= 0) return 0;
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( gen, cur - 1 ),
                memory_order_seq_cst, memory_order_seq_cst )) return 1;
    }
}

/* ---- the CLIENT's park loop, verbatim in shape with madeira_fast_wait() -- */

static int client_wait( unsigned int gen, unsigned long long budget_ns )
{
    int rounds;

    if (client_try( gen )) return 1;
    for (rounds = 0; rounds < 64 && !stop; rounds++)
    {
        int st;
        uint64_t sg;

        /* Dekker half #1: waiters++ then load state, both seq_cst. */
        atomic_fetch_add_explicit( (_Atomic int *)&cell.waiters, 1, memory_order_seq_cst );
        atomic_fetch_add_explicit( &parked_now, 1, memory_order_relaxed );
        sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );
        if (MADEIRA_SG_GEN( sg ) != gen)
        {
            /* leave `waiters' alone: it belongs to the new occupant's count */
            atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );
            return -1;
        }
        st = MADEIRA_SG_STATE( sg );
        if (st == MADEIRA_CELL_RESET)
        {
            atomic_fetch_add_explicit( &parks, 1, memory_order_relaxed );
            park_on( madeira_cell_futex( &cell ), MADEIRA_CELL_RESET, budget_ns );
        }

        if (MADEIRA_SG_GEN( atomic_load_explicit( (_Atomic uint64_t *)&cell.sg,
                                                  memory_order_seq_cst ) ) != gen)
        {
            atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );
            return -1;
        }
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.waiters, 1, memory_order_seq_cst );
        atomic_fetch_sub_explicit( &parked_now, 1, memory_order_relaxed );

        if (st < 0) return -1;                       /* DISABLED: the server */
        if (client_try( gen )) return 1;
    }
    return 0;                                        /* timed out: NO token held */
}

/* ---- the SERVER's claim, verbatim in shape with semaphore_cell_take() --- */

static int server_take( void )
{
    uint64_t sg = atomic_load_explicit( (_Atomic uint64_t *)&cell.sg, memory_order_seq_cst );

    for (;;)
    {
        int cur = MADEIRA_SG_STATE( sg );

        if (cur <= 0) return 0;
        if (atomic_compare_exchange_strong_explicit(
                (_Atomic uint64_t *)&cell.sg, &sg, MADEIRA_SG( MADEIRA_SG_GEN( sg ), cur - 1 ),
                memory_order_seq_cst, memory_order_seq_cst )) return 1;
    }
}

/* ------------------------------------------------------------------ threads */

static void *producer( void *arg )
{
    unsigned int s = 7717 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        unsigned int n = 1 + ((s = s * 1103515245u + 12345u) >> 16) % 4u;
        unsigned int prev = 0;

        /* publish the WORK before the tokens: a consumer must never find a
         * token with nothing behind it */
        atomic_fetch_add_explicit( &work, (long)n, memory_order_seq_cst );
        if (client_release( my_gen, n, &prev ) == 1)
            atomic_fetch_add_explicit( &produced, n, memory_order_relaxed );
        else
            atomic_fetch_sub_explicit( &work, (long)n, memory_order_seq_cst );  /* refused */
        /* Idle now and then, so the cell genuinely empties and the consumers
         * genuinely PARK.  Without this the count never reaches zero and the
         * whole park/wake half of the protocol is never exercised -- which is
         * the half a lost wakeup lives in. */
        if (!(s & 0x30)) sched_yield();
        if (!(s & 0xf00)) usleep( 200 );
    }
    return NULL;
}

static void *consumer( void *arg )
{
    unsigned int s = 31337 + (unsigned int)(uintptr_t)arg;

    while (!stop)
    {
        unsigned long long budget = 50000ull + ((s = s * 1103515245u + 12345u) >> 18) % 400000ull;
        int r = client_wait( my_gen, budget );

        if (r == 1)
        {
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
        }
        else if (!r) atomic_fetch_add_explicit( &timeouts, 1, memory_order_relaxed );
    }
    return NULL;
}

/* The wineserver's own queue: claims tokens with the same CAS the real
 * semaphore_sync_signaled() uses and hands them to its queued threads.  This
 * is the mixed-waiter case -- fast waiters and server waiters on one object. */
static void *server_thread( void *arg )
{
    while (!stop)
    {
        atomic_fetch_add_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
        sched_yield();
        if (server_take())
        {
            atomic_fetch_add_explicit( &srv_served, 1, memory_order_relaxed );
            atomic_fetch_add_explicit( &consumed, 1, memory_order_relaxed );
            if (atomic_fetch_sub_explicit( &work, 1, memory_order_seq_cst ) <= 0)
                atomic_fetch_add_explicit( &no_work, 1, memory_order_relaxed );
        }
        atomic_fetch_sub_explicit( (_Atomic int *)&cell.srv_waiters, 1, memory_order_seq_cst );
    }
    return NULL;
}

/* ------------------------------------------------------------------- checks */

static void cell_init( unsigned int gen, unsigned int initial, unsigned int max )
{
    memset( (void *)&cell, 0, sizeof(cell) );
    cell.kind = MADEIRA_CELL_KIND_SEM;
    cell.smax = max;
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg, MADEIRA_SG( gen, (int)initial ),
                           memory_order_seq_cst );
}

static int check_layout( void )
{
    struct madeira_sync_cell c;

    printf( "MADEIRA-SEM: sizeof(struct madeira_sync_cell)=%zu (must be 32)\n", sizeof(c) );
    if (sizeof(c) != 32) return 70;

    c.sg = MADEIRA_SG( 0xAABBCCDDu, MADEIRA_CELL_DISABLED );
    if (*madeira_cell_futex( &c ) != MADEIRA_CELL_DISABLED) return 71;
    if (MADEIRA_SG_GEN( c.sg ) != 0xAABBCCDDu ||
        MADEIRA_SG_STATE( c.sg ) != MADEIRA_CELL_DISABLED) return 72;

    /* the largest count a semaphore may hold must survive the round trip as a
     * POSITIVE number, i.e. must not collide with DISABLED */
    c.sg = MADEIRA_SG( 1u, 0x7fffffff );
    if (MADEIRA_SG_STATE( c.sg ) != 0x7fffffff) return 72;
    c.kind = MADEIRA_CELL_KIND_SEM;
    if (madeira_cell_kind( &c ) != MADEIRA_CELL_KIND_SEM) return 72;
    printf( "MADEIRA-SEM: layout, futex half, sign and max-count round trip OK\n" );
    return 0;
}

/* D: overflow refuses the whole release and changes nothing. */
static int check_overflow( void )
{
    unsigned int prev = 0xdeadbeef;

    cell_init( 5u, 60, SEM_MAX );
    if (client_release( 5u, 4, &prev ) != 1 || prev != 60) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 64) return 73;
    /* at max: one more must be refused and the count must not move */
    prev = 0xdeadbeef;
    if (client_release( 5u, 1, &prev ) != 0) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 64) return 73;
    /* a release larger than max is refused whatever the count */
    cell_init( 5u, 0, SEM_MAX );
    if (client_release( 5u, SEM_MAX + 1, NULL ) != 0) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 0) return 73;
    /* count == 0 is the "wake your queue" request: legal, changes nothing */
    cell_init( 5u, 7, SEM_MAX );
    prev = 0;
    if (client_release( 5u, 0, &prev ) != 1 || prev != 7) return 73;
    if (MADEIRA_SG_STATE( cell.sg ) != 7) return 73;
    printf( "MADEIRA-SEM: overflow refuses the whole release, count==0 is a no-op OK\n" );
    return 0;
}

/* E: a cell handed to a different semaphore must reject a stale consumer. */
static int check_generation( void )
{
    cell_init( 9u, 4, SEM_MAX );
    if (!client_try( 9u )) return 74;
    /* the object is destroyed (gen bump + DISABLED) and the cell re-allocated
     * to a stranger, already holding tokens */
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg,
                           MADEIRA_SG( 10u, MADEIRA_CELL_DISABLED ), memory_order_seq_cst );
    atomic_store_explicit( (_Atomic uint64_t *)&cell.sg, MADEIRA_SG( 11u, 8 ),
                           memory_order_seq_cst );
    if (client_try( 9u )) return 74;                 /* would be a stolen token */
    if (client_release( 9u, 1, NULL ) != -1) return 74;
    if (MADEIRA_SG_STATE( cell.sg ) != 8) return 74; /* stranger untouched */
    if (!client_try( 11u )) return 74;               /* the new owner still works */
    printf( "MADEIRA-SEM: a recycled cell rejects the stale generation, both ways OK\n" );
    return 0;
}

static int check_stress( void )
{
    pthread_t th[NPRODUCERS + NCONSUMERS + NSERVER];
    int i, n = 0;
    long left, w;
    unsigned long p, c;

    my_gen = 3u;
    cell_init( my_gen, 0, SEM_MAX );
    atomic_store( &work, 0 ); atomic_store( &produced, 0 ); atomic_store( &consumed, 0 );
    atomic_store( &timeouts, 0 ); atomic_store( &parked_now, 0 ); atomic_store( &no_work, 0 );
    atomic_store( &overflow_refused, 0 ); atomic_store( &srv_served, 0 );
    atomic_store( &parks, 0 );
    stop = 0;

    for (i = 0; i < NPRODUCERS; i++)
        pthread_create( &th[n++], NULL, producer, (void *)(uintptr_t)i );
    for (i = 0; i < NCONSUMERS; i++)
        pthread_create( &th[n++], NULL, consumer, (void *)(uintptr_t)i );
    for (i = 0; i < NSERVER; i++)
        pthread_create( &th[n++], NULL, server_thread, (void *)(uintptr_t)i );

    usleep( RUN_MS * 1000 );
    stop = 1;
    for (i = 0; i < 200; i++) { wake_all(); usleep( 1000 ); }
    for (i = 0; i < n; i++) pthread_join( th[i], NULL );

    left = MADEIRA_SG_STATE( cell.sg );
    p = atomic_load( &produced );
    c = atomic_load( &consumed );
    w = atomic_load( &work );

    printf( "MADEIRA-SEM: produced=%lu consumed=%lu left_in_cell=%ld timeouts=%lu "
            "parks=%lu srv_served=%lu refused=%lu\n",
            p, c, left, atomic_load( &timeouts ), atomic_load( &parks ),
            atomic_load( &srv_served ), atomic_load( &overflow_refused ) );

    /* A: conservation.  Every token is accounted for exactly once. */
    if ((unsigned long)left + c != p)
    {
        printf( "MADEIRA-SEM: FAIL - consumed+left=%lu but produced=%lu\n",
                (unsigned long)left + c, p );
        return 75;
    }
    /* A/C: no consumer ever proceeded without a token behind it, which also
     * proves no timed-out waiter consumed one and dropped it (the ledger would
     * be short by exactly that many). */
    if (atomic_load( &no_work ))
    {
        printf( "MADEIRA-SEM: FAIL - %lu consumers proceeded with no work behind the token\n",
                atomic_load( &no_work ) );
        return 76;
    }
    if (w != left)
    {
        printf( "MADEIRA-SEM: FAIL - ledger %ld but %ld tokens left in the cell\n", w, left );
        return 76;
    }
    /* B: nobody is still parked, and `waiters' has come back to zero. */
    if (atomic_load( &parked_now ) || cell.waiters || cell.srv_waiters)
    {
        printf( "MADEIRA-SEM: FAIL - parked=%lu waiters=%d srv_waiters=%d at rest\n",
                atomic_load( &parked_now ), cell.waiters, cell.srv_waiters );
        return 77;
    }
    if (!p || !c || !atomic_load( &parks ) || !atomic_load( &srv_served ))
    {
        printf( "MADEIRA-SEM: FAIL - the stress did not reach the paths it exists for"
                " (produced=%lu consumed=%lu parks=%lu srv_served=%lu)\n",
                p, c, atomic_load( &parks ), atomic_load( &srv_served ) );
        return 78;
    }
    printf( "MADEIRA-SEM: conservation, no-work-behind-a-token, waiter accounting OK\n" );
    return 0;
}

int main( void )
{
    int rc, pass;

    if ((rc = check_layout())) return rc;
    if ((rc = check_overflow())) return rc;
    if ((rc = check_generation())) return rc;
    /* three passes: the interleavings that matter here are timing-dependent
     * and a single 2.5 s window is one sample, not a result */
    for (pass = 0; pass < 3; pass++)
        if ((rc = check_stress())) return rc;

    printf( "MADEIRA-SEM: all checks passed\n" );
    return 0;
}
