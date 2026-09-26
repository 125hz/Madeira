#!/usr/bin/env python3
"""Exercise production LFH reclamation with concurrent frees and ownership checks."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'wine/dlls/ntdll/heap.c').read_text()
start = source.index('static unsigned int madeira_heap_reclaim(')
function = source[start:source.index('\n}', start) + 2]
code = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define BLOCK_SIZE_BIN_COUNT 3
#define GROUP_FLAG_FREE (1u << 31)
#define MADEIRA_HEAP_RECLAIM 4
#define ERR(...) ((void)0)
typedef unsigned ULONG;
typedef struct slist { struct slist *Next; } SLIST_ENTRY;
struct group { SLIST_ENTRY entry; _Atomic unsigned free_bits; unsigned released; };
struct bin { SLIST_ENTRY *groups; void *affinity[4]; };
struct heap { struct bin *bins; };
static unsigned madeira_heap_policy, affinity_mapping[4];
static int release_error;
static unsigned long released_total;
static SLIST_ENTRY *RtlInterlockedFlushSList(SLIST_ENTRY **p) { SLIST_ENTRY *old = *p; *p = NULL; return old; }
static void RtlInterlockedPushEntrySList(SLIST_ENTRY **p, SLIST_ENTRY *e) { e->Next = *p; *p = e; }
static void *InterlockedExchangePointer(void **p, void *v) { void *old = *p; *p = v; return old; }
static void **bin_get_affinity_group(struct bin *b, unsigned j) { return &b->affinity[j]; }
#define ReadAcquire(p) atomic_load_explicit((p), memory_order_acquire)
#define CONTAINING_RECORD(p,t,m) ((t *)((char *)(p) - offsetof(t,m)))
static int group_release(struct heap *h, ULONG flags, struct bin *b, struct group *g)
{
    assert(atomic_load(&g->free_bits) == ~GROUP_FLAG_FREE);
    assert(!g->released);
    g->released = 1; released_total++;
    return release_error;
}
''' + function + r'''
static void *finish_free(void *arg)
{
    struct group *g = arg;
    atomic_fetch_or(&g->free_bits, 1u);
    return NULL;
}
int main(void)
{
    struct bin bins[3] = {0};
    struct heap heap = {bins};
    struct group empty = {.free_bits = 0x7fffffff}, partial = {.free_bits = 0x7ffffffe};
    bins[0].affinity[0] = &empty;
    bins[1].groups = &partial.entry;
    assert(!madeira_heap_reclaim(&heap, 0) && bins[0].affinity[0] == &empty);
    madeira_heap_policy = 4;
    assert(madeira_heap_reclaim(&heap, 0) == 1 && empty.released);
    assert(!partial.released && bins[1].groups == &partial.entry);
    assert(!madeira_heap_reclaim(&heap, 0));
    atomic_fetch_or(&partial.free_bits, 1u);
    assert(madeira_heap_reclaim(&heap, 0) == 1 && partial.released);
    assert(!bins[1].groups);
    heap.bins = NULL;
    assert(!madeira_heap_reclaim(&heap, 0));
    heap.bins = bins;
    for (unsigned i = 0; i < 2000; i++)
    {
        struct group concurrent = {.free_bits = 0x7ffffffe};
        pthread_t t;
        bins[0].affinity[i % 4] = &concurrent;
        assert(!pthread_create(&t, NULL, finish_free, &concurrent));
        unsigned n = madeira_heap_reclaim(&heap, 0);
        pthread_join(t, NULL);
        if (!n) assert(madeira_heap_reclaim(&heap, 0) == 1);
        assert(concurrent.released && !bins[0].groups);
    }
    /* Failed backend release must not be reported as successful recovery. */
    struct group failure = {.free_bits = 0x7fffffff};
    bins[0].groups = &failure.entry;
    release_error = 1;
    assert(!madeira_heap_reclaim(&heap, 0));
    puts("PASS: production pressure reclaim, rollback, partial/live preservation, 2000 concurrent frees, error reporting");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / 'test.c').write_text(code)
    subprocess.run(['clang', '-std=c11', '-g', '-O1', '-fsanitize=address,undefined',
                    '-pthread', str(path/'test.c'), '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True)

# Production retry is bounded and real failures retain the Windows status.
assert 'if (status == STATUS_NO_MEMORY && heap && !reclaimed)' in source
assert 'reclaimed = TRUE;' in source and 'if (released) goto retry;' in source
assert 'heap->madeira_large_ops = heap->madeira_large_frees = 0;' in source
