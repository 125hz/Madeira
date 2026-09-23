#!/usr/bin/env python3
"""Production-source regression for the ml1410 async cancellation hold; no Wine or guest runs.

Device failure (log 170): a client cancelled I/O whose owning thread had already left
(read_request EOF -> kill_thread). The completion APC could not be queued, so the async
completed inside cancel_async(), dropped its last reference and was freed; the
list_remove() that followed in cancel_process_async() faulted and the wineserver stopped.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
src = (root / "wine/server/async.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
a = src.index("/* iOS-Madeira ml1410: keep each async alive")
block = src[a:src.index("static int cancel_process_async(", a)] + function(src, "static int cancel_process_async(")
assert "ios_completed = 1;" in function(src, "void async_set_result("), "async_set_result records completion"
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "wine/list.h"
typedef unsigned long long client_ptr_t; typedef unsigned int obj_handle_t;
#define SYNCHRONIZE 0x00100000
enum { RUNNING, TERMINATED };
struct object { int refcount; void (*destroy)(struct object *); };
static void *grab_object(void *p) { ((struct object *)p)->refcount++; return p; }
static void release_object(void *p) {
    struct object *o = p;
    if (--o->refcount) return;
    if (o->destroy) o->destroy(o);
    free(o);
}
struct process { struct list asyncs; };
struct thread { unsigned int id; int state; };
struct fd { struct object *user; };
static struct object *get_fd_user(struct fd *fd) { return fd->user; }
struct async_cancel { struct object obj; int count; int signaled; };
static int cancels_live;
static void cancel_destroy(struct object *o) { (void)o; cancels_live--; }
static struct async_cancel *create_async_cancel(struct process *p) {
    struct async_cancel *c = calloc(1, sizeof(*c)); (void)p;
    c->obj.refcount = 1; c->obj.destroy = cancel_destroy; cancels_live++; return c;
}
static obj_handle_t alloc_handle(struct process *p, void *obj, unsigned int access, int attr) {
    (void)p; (void)access; (void)attr; grab_object(obj); return 4;
}
struct async_data { client_ptr_t iosb; client_ptr_t user; };
struct async {
    struct object obj; struct thread *thread; struct list process_entry; int queued; struct fd *fd;
    struct async_data data;
    unsigned int signaled :1, terminated :1, canceled :1, is_system :1, ios_completed :1;
    struct async_cancel *async_cancel;
};
static int asyncs_live, apc_fails;
static void async_destroy(struct object *o) {
    struct async *async = (struct async *)o;
    assert(!async->async_cancel);                       /* as in the server */
    list_remove(&async->process_entry);
    asyncs_live--;
}
static void async_complete_cancel(struct async *async) {
    struct async_cancel *c = async->async_cancel;
    if (!c) return;
    async->async_cancel = NULL;
    if (!--c->count) { c->signaled = 1; release_object(c); }
}
/* async_set_result(): the final result; the queue drops its reference */
static void complete(struct async *async) {
    async->terminated = 1; async->ios_completed = 1;
    if (!async->signaled) async->signaled = 1;
    async_complete_cancel(async);
    if (async->queued) { async->queued = 0; release_object(async); }
}
/* async_terminate() via cancel_async(): the completion APC holds a reference until the
 * client answers; when it cannot be queued (owner gone) the result is stored at once */
static struct async *apc_owner[16]; static int apcs;
static void cancel_async(struct async *async) {
    async->canceled = 1; async->terminated = 1;
    grab_object(async);
    if (async->thread->state == TERMINATED || apc_fails) complete(async);
    else apc_owner[apcs++] = grab_object(async);
    release_object(async);
}
static void deliver_apcs(void) {
    for (int i = 0; i < apcs; i++) { complete(apc_owner[i]); release_object(apc_owner[i]); }
    apcs = 0;
}
static struct async *new_async(struct process *p, struct thread *t, struct fd *fd, client_ptr_t iosb, int signaled) {
    struct async *a = calloc(1, sizeof(*a));
    a->obj.refcount = 1; a->obj.destroy = async_destroy;   /* the queue's reference */
    a->queued = 1; a->thread = t; a->fd = fd; a->data.iosb = iosb; a->signaled = signaled;
    list_add_tail(&p->asyncs, &a->process_entry); asyncs_live++;
    return a;
}
""" + block + r"""
int main(int argc, char **argv) {
    struct process p; struct thread gone = { 0x240, TERMINATED }, alive = { 0x244, RUNNING };
    struct object file = { 1, NULL }, other = { 1, NULL };
    struct fd fd = { &file }, fd2 = { &other };
    obj_handle_t wait = 0;
    list_init(&p.asyncs);
    if (argc > 1) {
        setenv("MADEIRA_ASYNC_CANCEL_HOLD", "0", 1);
        new_async(&p, &gone, &fd, 0x10, 0);
        cancel_process_async(&p, &file, NULL, 0, &wait);   /* heap-use-after-free: the device fault */
        puts("rollback did not fault"); return 0;
    }
    /* the device case: owner thread gone, NtCancelIoFileEx from another thread */
    new_async(&p, &gone, &fd, 0x10, 0);
    new_async(&p, &gone, &fd, 0x20, 1);                  /* pending non-blocking: already signaled */
    struct async *keep = new_async(&p, &alive, &fd, 0x30, 1);
    struct async *untouched = new_async(&p, &alive, &fd2, 0x40, 0);   /* another file */
    assert(cancel_process_async(&p, &file, NULL, 0, &wait) == 3);
    assert(asyncs_live == 2 && list_count(&p.asyncs) == 2 && keep->canceled && apcs == 1);
    deliver_apcs();
    assert(asyncs_live == 1 && list_count(&p.asyncs) == 1);
    /* NtCancelIoFile from the owning thread: a result stored during the cancel gets no
     * cancel object (nothing would ever release it) and no wait handle */
    wait = 0; apc_fails = 1;
    new_async(&p, &alive, &fd, 0x50, 1);
    assert(cancel_process_async(&p, &file, &alive, 0, &wait) == 1);
    assert(wait == 0 && cancels_live == 0 && asyncs_live == 1);
    /* the normal case is unchanged: the cancel waits for the client's result */
    apc_fails = 0;
    new_async(&p, &alive, &fd, 0x60, 1);
    assert(cancel_process_async(&p, &file, &alive, 0x60, &wait) == 1);
    assert(wait == 4 && cancels_live == 1 && apcs == 1 && asyncs_live == 2);
    struct async_cancel *c = apc_owner[0]->async_cancel;
    assert(c && c->count == 1 && !c->signaled);
    grab_object(c); deliver_apcs();
    assert(c->signaled && c->count == 0 && asyncs_live == 1);
    release_object(c); release_object(c);                  /* the wait handle, then ours */
    assert(cancels_live == 0 && !untouched->canceled);
    release_object(untouched);
    assert(asyncs_live == 0 && list_empty(&p.asyncs));
    puts("PASS: cancelled asyncs stay valid through synchronous completion; waits attach only to pending results");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", "-I", str(root / "wine/include"), str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    rollback = subprocess.run([str(exe), "rollback"], capture_output=True, text=True)
    assert rollback.returncode != 0 and "heap-use-after-free" in rollback.stderr, rollback.stderr[-2000:]
    print("PASS: rollback reproduces the use-after-free in cancel_process_async")
