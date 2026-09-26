#!/usr/bin/env python3
"""Compile production heap allocation paths with a fault-injecting VM backend.

This checks call semantics and bounded growth, not on-device memory/FPS gains.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'wine/dlls/ntdll/heap.c').read_text()


def function(signature):
    begin = source.index(signature)
    return source[begin:source.index('\n}', begin) + 2]


code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
typedef size_t SIZE_T;
typedef unsigned ULONG;
typedef int NTSTATUS;
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
#define ROUND_SIZE(a,m) (((a)+(m)) & ~(SIZE_T)(m))
#define HEAP_MAX_GROW_SIZE 0xfd0000
#define REGION_ALIGN 0x10000
#define MADEIRA_HEAP_COMPACT 1
#define MADEIRA_HEAP_COMBINED 2
#define HEAP_GROWABLE 2
#define VER_PLATFORM_WIN32_WINDOWS 1
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_RELEASE 0x8000
#define WARN(...) ((void)0)
#define TRACE(...) ((void)0)
static unsigned madeira_heap_policy;
static struct { struct { unsigned OSPlatformId; } *Peb; } teb;
static struct { unsigned OSPlatformId; } peb;
#define NtCurrentTeb() (&teb)
#define NtCurrentProcess() ((void *)-1)
static unsigned get_protection_type(unsigned flags) { return 4; }
struct heap { SIZE_T grow_size; };
struct entry { uintptr_t dummy[2]; };
typedef struct { uintptr_t dummy[4]; } SUBHEAP;
static SUBHEAP fake_subheap;
static unsigned calls, frees, fail_call, types[4], protections[4];
static SIZE_T sizes[4];
static void *release_address;
static NTSTATUS NtAllocateVirtualMemory(void *process, void **address, SIZE_T zero,
                                       SIZE_T *size, unsigned type, unsigned protect)
{
    assert(calls < 4);
    types[calls] = type; sizes[calls] = *size; protections[calls] = protect;
    if (++calls == fail_call) return -1;
    if (type & MEM_RESERVE) { assert(!*address); *address = (void *)0x10000000; }
    else assert(*address == (void *)0x10000000);
    *size = ROUND_SIZE(*size, 0x3fff);
    return 0;
}
static NTSTATUS NtFreeVirtualMemory(void *process, void **address, SIZE_T *size, unsigned type)
{
    assert(!*size && type == MEM_RELEASE);
    release_address = *address; ++frees; return 0;
}
static void reset(unsigned policy, unsigned failure)
{
    madeira_heap_policy = policy; calls = frees = 0; fail_call = failure;
    release_address = NULL; memset(types, 0, sizeof(types));
}
'''
for signature in ['static SIZE_T madeira_heap_grow_limit(',
                  'static SIZE_T madeira_heap_retry_size(', 'static void *allocate_region(']:
    code += '\n' + function(signature) + '\n'

# Compile the actual growth/retry control flow, with only create_subheap mocked.
begin = source.index('    heap->grow_size = min( heap->grow_size, madeira_heap_grow_limit() );')
end = source.index('\n    TRACE( "created new sub-heap', begin)
code += r'''
static SIZE_T available, requests[32];
static unsigned attempts;
static SUBHEAP *create_subheap(struct heap *heap, ULONG flags, SIZE_T total, SIZE_T commit)
{
    assert(attempts < 32 && total >= commit);
    requests[attempts++] = total;
    return total <= available ? &fake_subheap : NULL;
}
static SUBHEAP *grow(struct heap *heap, SIZE_T total_size)
{
    unsigned flags = HEAP_GROWABLE;
    SUBHEAP *subheap;
''' + source[begin:end] + r'''
    return subheap;
}
int main(void)
{
    struct heap heap = {0x100000};
    SIZE_T reserve, commit;
    teb.Peb = (void *)&peb; peb.OSPlatformId = 2;
    for (unsigned policy = 0; policy < 4; ++policy)
    {
        reset(policy, 0);
        reserve = commit = 0x240000;
        assert(allocate_region(&heap, HEAP_GROWABLE, &reserve, &commit));
        assert(reserve == 0x240000 && commit == reserve);
        assert(calls == ((policy & MADEIRA_HEAP_COMBINED) ? 1 : 2));
        assert(types[0] == ((policy & MADEIRA_HEAP_COMBINED) ? 0x3000 : MEM_RESERVE));
        assert(protections[0] == 4 && !frees);
        reset(policy, 1); reserve = commit = 0x240000;
        assert(!allocate_region(&heap, HEAP_GROWABLE, &reserve, &commit));
        assert(calls == 1 && !frees); // no retry with a smaller requested block
        reset(policy, 0); reserve = 0x200000; commit = 0x10000;
        assert(allocate_region(&heap, HEAP_GROWABLE, &reserve, &commit));
        assert(calls == 2 && types[0] == MEM_RESERVE && types[1] == MEM_COMMIT);
        assert(sizes[0] == 0x200000 && sizes[1] == 0x10000);
        reset(policy, 2); reserve = 0x200000; commit = 0x10000;
        assert(!allocate_region(&heap, HEAP_GROWABLE, &reserve, &commit));
        assert(frees == !!policy); // opt-in closes the split-path reserve leak
        if (policy) assert(release_address == (void *)0x10000000);
        reset(policy, 0); reserve = commit = 0x10000;
        assert(!allocate_region(&heap, 0, &reserve, &commit));
        assert(!calls); // non-growable heap contract retained
        reset(policy, 0); reserve = 0x240001;
        assert(allocate_region(&heap, HEAP_GROWABLE, &reserve, &reserve));
        assert(reserve >= 0x240001); // large block's aliased size arguments
    }
    for (unsigned compact = 0; compact < 2; ++compact)
    {
        reset(compact, 0); attempts = 0; heap.grow_size = 0x100000;
        available = SIZE_MAX;
        for (unsigned i = 0; i < 16; ++i) assert(grow(&heap, 0x90000));
        for (unsigned i = 0; i < attempts; ++i)
            assert(requests[i] <= (compact ? 0x200000 : HEAP_MAX_GROW_SIZE));
        assert(heap.grow_size == (compact ? 0x200000 : HEAP_MAX_GROW_SIZE));
    }
    reset(1, 0); attempts = 0; heap.grow_size = 0xfd0000; available = 0x100000;
    assert(grow(&heap, 0x90000));
    assert(attempts == 2 && requests[0] == 0x200000 && requests[1] == 0x100000);
    attempts = 0; heap.grow_size = 0x200000; available = 0xa0000;
    assert(grow(&heap, 0x90001));
    assert(requests[attempts-1] == 0xa0000); // final exact aligned requirement
    attempts = 0; heap.grow_size = 0x200000; available = 0x90000;
    assert(!grow(&heap, 0x90001) && attempts < 8); // finite failure
    reset(0, 0); attempts = 0; heap.grow_size = 0xfd0000; available = 0x100000;
    assert(!grow(&heap, 0x90000)); // original 4MB retry floor in rollback mode
    puts("PASS: production heap VM contracts, single-call full commit, failure cleanup, bounded growth and retry/rollback");
}
'''

loader = (root / 'wine/dlls/ntdll/loader.c').read_text()
assert loader.index('init_user_process_params();') < loader.index('heap_init_madeira_policy();')
content = (root / 'app/Madeira/ContentView.swift').read_text()
assert 'setenv("MADEIRA_HEAP_COMPACT", "1", 0)' in content
assert 'setenv("MADEIRA_HEAP_COMBINED", "1", 0)' in content
with tempfile.TemporaryDirectory(prefix='madeira-heap-') as folder:
    folder = Path(folder)
    (folder / 'check.c').write_text(code)
    subprocess.run(['cc', '-std=c11', '-g', '-fsanitize=address,undefined',
                    str(folder / 'check.c'), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
