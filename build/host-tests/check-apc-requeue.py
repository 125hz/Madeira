#!/usr/bin/env python3
"""Production-source regression for the ml1480 async APC requeue (wineserver); no Wine runs.

Device log 184: an accept's completion APC could not be queued because its issuing thread was
busy and a busy thread cannot be signalled on iOS. The APC was dropped and the async completed
with STATUS_ALERTED and 0 bytes. This compiles the production queue_apc, is_in_apc_wait,
get_apc_queue, is_thread_suspended and the ml1480 helpers against minimal server stubs whose
send_thread_signal always fails, as it does on iOS.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "wine/server/thread.c").read_text()


def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]


helpers = src[src.index("#ifdef WINE_IOS\n/* ml1480:"):src.index("/* queue an existing APC to a given thread */")]
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include "wine/list.h"
enum apc_type { APC_NONE, APC_USER, APC_ASYNC_IO, APC_VIRTUAL_ALLOC };
enum thread_state { RUNNING, TERMINATED };
#define SELECT_INTERRUPTIBLE 2
struct object { int refcount; };
struct inproc_sync { int n; };
struct thread_wait { int flags; };
struct process { struct list thread_list; int suspend; };
struct thread {
    struct object obj; struct list proc_entry; struct process *process; unsigned int id;
    enum thread_state state; struct thread_wait *wait; int suspend, bypass_proc_suspend;
    struct list system_apc, user_apc; struct inproc_sync *alert_sync; int woken;
};
union apc_call { enum apc_type type; struct { enum apc_type type; unsigned int status; } async_io; };
struct thread_apc { struct object obj; struct list entry; struct object *owner; union apc_call call; };
static void *grab_object( void *p ) { ((struct object *)p)->refcount++; return p; }
static int signals;
static int send_thread_signal( struct thread *t, int sig ) { (void)t; (void)sig; signals++; return 0; }
static void thread_cancel_apc( struct thread *t, struct object *o, enum apc_type ty ) { (void)t; (void)o; (void)ty; }
static void signal_inproc_sync( struct inproc_sync *s ) { s->n++; }
static void wake_thread( struct thread *t ) { t->woken++; }
""" + function(src, "static inline int is_thread_suspended( struct thread *thread )") + "\n" \
    + function(src, "static inline struct list *get_apc_queue( struct thread *thread, enum apc_type type )") + "\n" \
    + function(src, "static inline int is_in_apc_wait( struct thread *thread )") + "\n" \
    + helpers + "\n" + function(src, "static int queue_apc( struct process *process, struct thread *thread, struct thread_apc *apc )") + r"""
static struct process proc;
static struct thread T[4];
static struct thread_wait interruptible = { SELECT_INTERRUPTIBLE }, plain = { 0 };
static void reset( void )
{
    list_init( &proc.thread_list ); proc.suspend = 0;
    for (int i = 0; i < 4; i++)
    {
        memset( &T[i], 0, sizeof(T[i]) );
        T[i].process = &proc; T[i].id = 0x90 + 4 * i; T[i].state = RUNNING;
        list_init( &T[i].system_apc ); list_init( &T[i].user_apc );
        list_add_tail( &proc.thread_list, &T[i].proc_entry );
    }
}
static struct thread_apc *allocs[16];
static int nallocs;
static void free_all( void ) { while (nallocs) free( allocs[--nallocs] ); }
static struct thread_apc *apc( enum apc_type type )
{
    struct thread_apc *a = calloc( 1, sizeof(*a) );
    allocs[nallocs++] = a;
    a->obj.refcount = 1; a->call.type = type; if (type == APC_ASYNC_IO) a->call.async_io.status = 0x101;
    return a;
}
static int on( struct thread *t, struct thread_apc *a ) { return list_head( &t->system_apc ) == &a->entry; }
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); return 1; } } while (0)
int main( int argc, char **argv )
{
    int rollback = argc > 1;
    struct thread_apc *a;

    atexit( free_all );
    setvbuf( stdout, NULL, _IONBF, 0 );

    reset(); T[2].wait = &interruptible;               /* issuer T[1] busy, T[2] waiting */
    a = apc( APC_ASYNC_IO );
    if (rollback)
    {
        CHECK( queue_apc( &proc, &T[1], a ) == 0, "rollback drops the APC (upstream behaviour on iOS)" );
        CHECK( list_empty( &T[1].system_apc ) && list_empty( &T[2].system_apc ), "rollback queues nothing" );
        printf( "PASS: rollback reproduces the dropped async APC\n" );
        return 0;
    }
    CHECK( queue_apc( &proc, &T[1], a ) == 1, "busy issuer: APC queued" );
    CHECK( on( &T[2], a ) && list_empty( &T[1].system_apc ) && T[2].woken == 1, "busy issuer: handed to the waiting thread and woken" );
    CHECK( signals == 1, "the signal was tried first" );

    reset(); a = apc( APC_ASYNC_IO );                  /* nobody waiting */
    T[2].wait = &plain;                                /* a non-interruptible wait does not count */
    CHECK( queue_apc( &proc, &T[1], a ) == 1 && on( &T[1], a ), "no waiter: kept on the issuer for its next wait" );

    reset(); a = apc( APC_ASYNC_IO );                  /* suspended and terminated waiters are skipped */
    T[0].wait = &interruptible; T[0].suspend = 1;
    T[2].wait = &interruptible; T[2].state = TERMINATED;
    T[3].wait = &interruptible;
    CHECK( queue_apc( &proc, &T[1], a ) == 1 && on( &T[3], a ), "suspended and terminated waiters skipped" );

    reset(); a = apc( APC_ASYNC_IO );                  /* issuer itself waiting: upstream path, no signal */
    signals = 0; T[1].wait = &interruptible; T[2].wait = &interruptible;
    CHECK( queue_apc( &proc, &T[1], a ) == 1 && on( &T[1], a ) && signals == 0, "waiting issuer keeps its APC" );

    reset(); T[2].wait = &interruptible;               /* issuer busy with a queued APC: no signal needed */
    struct thread_apc *first = apc( APC_ASYNC_IO ), *second = apc( APC_ASYNC_IO );
    list_add_tail( &T[1].system_apc, &first->entry ); signals = 0;
    CHECK( queue_apc( &proc, &T[1], second ) == 1 && list_next( &T[1].system_apc, &first->entry ) == &second->entry && signals == 0,
           "second APC joins the issuer's non-empty queue as upstream" );

    reset(); T[2].wait = &interruptible;               /* other system APCs keep the upstream drop */
    a = apc( APC_VIRTUAL_ALLOC );
    CHECK( queue_apc( &proc, &T[1], a ) == 0 && list_empty( &T[2].system_apc ), "non-I/O system APC unchanged" );

    reset(); T[2].wait = &interruptible;               /* user APCs are not affected */
    a = apc( APC_USER );
    CHECK( queue_apc( &proc, &T[1], a ) == 1 && list_head( &T[1].user_apc ) == &a->entry, "user APC unchanged" );
    printf( "PASS: async APCs for busy threads go to a waiting thread of the process or stay queued; other APCs unchanged\n" );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "requeue.c"; c.write_text(code)
    exe = Path(t) / "requeue"
    subprocess.run(["cc", "-std=gnu11", "-DWINE_IOS=1", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                    "-I", str(root / "wine/include"), str(c), "-o", str(exe)], check=True)
    env = dict(os.environ); env.pop("MADEIRA_APC_REQUEUE", None)
    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[apc-requeue] ml1480 on" in out.stderr and "-> waiting thread 0098" in out.stderr and "-> kept on 0094" in out.stderr, out.stderr
    assert "APC status=00000101" in out.stderr, "the log names the APC status"
    env["MADEIRA_APC_REQUEUE"] = "0"
    out = subprocess.run([str(exe), "rollback"], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[apc-requeue] ml1480 off" in out.stderr and "#1" not in out.stderr

qa = function(src, "static int queue_apc( struct process *process, struct thread *thread, struct thread_apc *apc )")
assert qa.index("if (!send_thread_signal( thread, SIGUSR1 ))") < qa.index("ios_apc_requeue_target( thread, apc )"), \
    "requeue only after the signal failed"
assert "#else\n                return 0;\n#endif" in qa, "non-iOS builds keep the upstream drop"
print("PASS: requeue sits behind the failed signal, iOS only")
