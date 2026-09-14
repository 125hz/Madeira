/*
 * iOS-Madeira ml950: shared counter block for the [srv-stats] report.
 *
 * The report itself lives in build/ntdll-unix/server_ios.c (it is printed from
 * whichever thread first notices the 10 s deadline at the end of a server
 * call).  The Nt* entry-point counters below are incremented from
 * wine/dlls/ntdll/unix/sync.c, which is a different translation unit, so the
 * storage is declared here and defined once in server_ios.c.
 *
 * Every counter is written with __ATOMIC_RELAXED and is allowed to lose an
 * increment to a race; these are rates, not ledgers.  Nothing reads them
 * except the reporter, which exchanges them to zero once per window.
 */

#ifndef __IOS_SRV_STATS_H
#define __IOS_SRV_STATS_H

enum ios_srv_nt_counter
{
    IOS_NT_SET_EVENT,          /* NtSetEvent                                 */
    IOS_NT_RESET_EVENT,        /* NtResetEvent / NtClearEvent                */
    IOS_NT_PULSE_EVENT,        /* NtPulseEvent                               */
    IOS_NT_WAIT_SINGLE,        /* NtWaitForSingleObject                      */
    IOS_NT_WAIT_MULTI,         /* NtWaitForMultipleObjects (count > 1)       */
    IOS_NT_SIGNAL_AND_WAIT,    /* NtSignalAndWaitForSingleObject             */
    IOS_NT_RELEASE_SEM,        /* NtReleaseSemaphore                         */
    IOS_NT_RELEASE_MUTANT,     /* NtReleaseMutant                            */
    IOS_NT_DELAY_ZERO,         /* NtDelayExecution with a zero timeout       */
    IOS_NT_DELAY_NONZERO,      /* NtDelayExecution with a real timeout       */
    IOS_NT_YIELD_SYSCALL,      /* sched_yield() actually issued              */
    IOS_NT_ALERT_WAIT,         /* NtWaitForAlertByThreadId (futex, no server)*/
    IOS_NT_ALERT_WAKE,         /* NtAlertThreadByThreadId  (futex, no server)*/
    /* fast-path outcomes, see MADEIRA_FASTSYNC in sync.c */
    IOS_NT_FAST_HIT,           /* completed with no server round trip        */
    IOS_NT_FAST_MISS,          /* fell back to the server                    */
    IOS_NT_FAST_WAKE,          /* os_sync_wake_by_address issued             */
    IOS_NT_FAST_SLEEP,         /* os_sync_wait_on_address entered            */

    /* Breakdown of the `select` request, which is the one request kind whose
     * count says nothing about its cause: NtWaitForSingleObject, a multi-object
     * wait, NtSignalAndWaitForSingleObject, a keyed event and an alertable
     * NtDelayExecution all arrive as REQ_select.  These buckets are what
     * separate "a handful of threads parked on an infinite wait" (free — the
     * thread is descheduled and the request happened once) from "a pacing loop
     * paying a full round trip per millisecond to be told it timed out"
     * (candidate (a) of the ml950 brief), which look identical in reqs=.
     * Counted in server_wait, which still has the caller's own timeout. */
    IOS_SEL_WAIT1_INF,         /* 1 handle,  no timeout                      */
    IOS_SEL_WAIT1_FIN,         /* 1 handle,  finite timeout                  */
    IOS_SEL_WAIT1_POLL,        /* 1 handle,  zero timeout (a state query)    */
    IOS_SEL_WAITN_INF,         /* >1 handle, no timeout                      */
    IOS_SEL_WAITN_FIN,         /* >1 handle, finite timeout                  */
    IOS_SEL_WAITN_POLL,        /* >1 handle, zero timeout                    */
    IOS_SEL_WAITALL,           /* SELECT_WAIT_ALL, any timeout               */
    IOS_SEL_SIGWAIT,           /* SELECT_SIGNAL_AND_WAIT                     */
    IOS_SEL_KEYED,             /* SELECT_KEYED_EVENT_WAIT / _RELEASE         */
    IOS_SEL_DELAY_ALERT,       /* select_op == NULL: alertable NtDelayExecution */
    IOS_SEL_OTHER,
    IOS_SEL_RET_TIMEOUT,       /* ... of all of the above, returned TIMEOUT   */
    IOS_SEL_RET_TIMEOUT_FIN,   /* ... of the FINITE ones only                */

    IOS_NT_COUNTER_MAX
};

extern unsigned int ios_srv_nt_counts[IOS_NT_COUNTER_MAX];

static inline void ios_srv_nt_count( enum ios_srv_nt_counter which )
{
    __atomic_fetch_add( &ios_srv_nt_counts[which], 1, __ATOMIC_RELAXED );
}

#endif /* __IOS_SRV_STATS_H */
