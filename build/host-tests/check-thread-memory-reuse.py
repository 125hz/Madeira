#!/usr/bin/env python3
"""ml2000 host checks: delayed reuse of an exited thread's TLS memory and TEB.

Never runs Wine, FEX or iOS.  Compiles the PRODUCTION blocks under ASan/UBSan:

  * wine/dlls/ntdll/loader.c TLS quarantine (tls_quarantine_* / tls_check_reuse):
    an exited thread's TLS array and blocks are parked, not freed; the ring holds
    TLS_QUARANTINE_DEPTH exits and then frees the OLDEST entry (FIFO) exactly
    once; MADEIRA_TLS_QUARANTINE=0 frees immediately; [tls-reuse] reports a new
    thread whose TLS memory was just freed by an exit, capped, and
    MADEIRA_TLS_REUSE_LOG=0 silences it;
  * build/ntdll-unix/virtual_ios.c teb_fifo_take_oldest(): with frees pushed at
    the head, allocation takes the tail (oldest), only with >= min_free blocks,
    leaves the rest intact, and MADEIRA_TEB_FIFO=0 disables it;
  * source wiring: LdrShutdownThread/alloc_thread_tls/process init call the new
    helpers, virtual_alloc_teb uses the FIFO in both paths, the [x86_live] x32
    register map matches FEX's x32::SRA, and the sechost notification thread's
    persistence has its kill switch.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
loader = (root / 'wine/dlls/ntdll/loader.c').read_text(encoding='utf-8')
vir = (root / 'build/ntdll-unix/virtual_ios.c').read_text(encoding='utf-8')
sig = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text(encoding='utf-8')
sechost = (root / 'wine/dlls/sechost/service.c').read_text(encoding='utf-8')
emitter = (root / 'FEX/FEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.cpp').read_text(encoding='utf-8')


def function(source, start):
    a = source.index(start)
    b = source.index('{', a)
    depth, c = 1, b + 1
    while depth:
        depth += (source[c] == '{') - (source[c] == '}')
        c += 1
    return source[a:c]


# ---------------------------------------------------------------- wiring
shutdown = function(loader, 'void WINAPI LdrShutdownThread(void)')
assert 'tls_quarantine_thread_data( pointers, tls_module_count );' in shutdown
assert 'RtlFreeHeap( GetProcessHeap(), 0, pointers[i] )' not in shutdown, 'no direct free left in LdrShutdownThread'
assert 'tls_check_reuse( pointers, tls_module_count );' in function(loader, 'static NTSTATUS alloc_thread_tls(void)')
assert loader.count('tls_quarantine_init();') == 1
init_at = loader.index('tls_quarantine_init();')
assert loader.rindex('init_user_process_params();', 0, init_at) > loader.rindex('if (!imports_fixup_done)', 0, init_at), \
    'quarantine policy is read after the environment is ready, during process init'
assert '[tls-quarantine] ml2000' in loader and '[tls-reuse] ml2000' in loader

alloc_teb = function(vir, 'NTSTATUS virtual_alloc_teb( TEB **ret_teb )')
assert 'teb_fifo_take_oldest( p_next_free_teb, TEB_FIFO_MIN_FREE )' in alloc_teb
assert 'teb_fifo_take_oldest( p_next_free_teb, 1 )' in alloc_teb, 'reservation failure reuses a TEB before failing'
assert 'teb_ready:' in alloc_teb and alloc_teb.index('teb_ready:') < alloc_teb.index('init_teb( ptr, is_wow )')
assert alloc_teb.index('teb_ready:') < alloc_teb.index('[teb-window] REFUSING'), 'recycled TEBs still pass the window check'
assert '[teb-fifo] ml2000' in vir

# FEX x32 static register allocation: EAX..EDI -> x4 x7 x5 x6 x8 x9 x10 x11
x32 = emitter[emitter.index('namespace x32 {'):]
sra = x32[x32.index('SRA = {'):x32.index('};', x32.index('SRA = {'))]
fex_map = [int(r) for r in re.findall(r'Reg::r(\d+)', sra)[:8]]
assert fex_map == [4, 7, 5, 6, 8, 9, 10, 11], fex_map
assert 'x32_host[8] = { 4, 7, 5, 6, 8, 9, 10, 11 }' in sig
assert sig.count('getenv( "MADEIRA_WOW32_DIAG" )') == 2
assert '[x86_live] ml2000 wow32' in sig and '[rsp-trunc] ml2000 wow32' in sig
assert '(mach_vm_address_t)(cs[0] + w32_base)' in sig, 'guest RIP read through the window base'

assert 'MADEIRA_DEVNOTIFY_PERSIST' in sechost and '[devnotify] ml2000' in sechost
proc = function(sechost, 'static DWORD WINAPI device_notify_proc( void *arg )')
assert 'if (!persist) return 1;' in proc and 'Sleep( retry_ms );' in proc

# ---------------------------------------------------------------- TLS quarantine
q_start = loader.index('#define TLS_QUARANTINE_DEPTH')
q_end = loader.index('/*************************************************************************\n *              alloc_thread_tls')
quarantine = loader[q_start:q_end]

tls_prelude = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
typedef unsigned int UINT;
typedef unsigned long ULONG;
typedef wchar_t WCHAR;
typedef int NTSTATUS;
typedef void *HANDLE;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { struct { HANDLE UniqueProcess, UniqueThread; } ClientId; } TEB;
static TEB teb;
static TEB *NtCurrentTeb(void) { return &teb; }
#define HandleToULong(h) ((ULONG)(uintptr_t)(h))
#define min(a,b) ((a) < (b) ? (a) : (b))
static int errs, reuse_lines, evict_lines;
#define ERR(...) do { char l_[512]; snprintf(l_, sizeof(l_), __VA_ARGS__); errs++; \
    reuse_lines += !!strstr(l_, "[tls-reuse]"); \
    evict_lines += !!strstr(l_, "ring full"); } while (0)
static const WCHAR *env_q, *env_r;
static void RtlInitUnicodeString( UNICODE_STRING *s, const WCHAR *w )
{ s->Buffer = (WCHAR *)w; s->Length = wcslen(w) * sizeof(WCHAR); s->MaximumLength = s->Length; }
static NTSTATUS RtlQueryEnvironmentVariable_U( void *env, UNICODE_STRING *name, UNICODE_STRING *value )
{
    const WCHAR *v = !wcscmp(name->Buffer, L"MADEIRA_TLS_QUARANTINE") ? env_q :
                     !wcscmp(name->Buffer, L"MADEIRA_TLS_REUSE_LOG") ? env_r : NULL;
    if (!v) return 0xc0000100;
    if ((wcslen(v) + 1) * sizeof(WCHAR) > value->MaximumLength) return 0xc0000023;
    wcscpy( value->Buffer, v ); value->Length = wcslen(v) * sizeof(WCHAR);
    return 0;
}
static int frees;
#define GetProcessHeap() ((HANDLE)1)
static int RtlFreeHeap( HANDLE h, ULONG f, void *p ) { if (p) { frees++; free(p); } return 1; }
'''

tls_main = r'''
static void **make_thread( UINT count, void **blocks )
{
    void **a = calloc( count, sizeof(void *) );
    UINT i;
    for (i = 0; i < count; i++) if (i != 3) a[i] = malloc( 32 + i );   /* slot 3 empty */
    if (blocks) memcpy( blocks, a, count * sizeof(void *) );
    return a;
}

static void reset(void)
{
    UINT k;
    for (k = 0; k < TLS_QUARANTINE_DEPTH; k++)   /* free parked entries: keep LeakSanitizer quiet */
        if (tls_quarantine[k].pointers) tls_release_thread_data( tls_quarantine[k].pointers, tls_quarantine[k].count );
    memset( tls_quarantine, 0, sizeof(tls_quarantine) );
    memset( tls_freed_addr, 0, sizeof(tls_freed_addr) );
    tls_quarantine_pos = tls_freed_pos = 0; tls_freed_count = 0;
    frees = errs = reuse_lines = evict_lines = 0;
}

int main(void)
{
    UINT count = 8, i;
    void *first_blocks[8], **first;

    /* default: on */
    env_q = env_r = NULL; tls_quarantine_init();
    assert( tls_quarantine_on == 1 && tls_reuse_log_on == 1 );

    reset();
    first = make_thread( count, first_blocks );
    tls_quarantine_thread_data( first, count );
    assert( frees == 0 && tls_freed_count == 0 );          /* parked, not freed */
    for (i = 1; i < TLS_QUARANTINE_DEPTH; i++) tls_quarantine_thread_data( make_thread( count, NULL ), count );
    assert( frees == 0 );                                   /* ring holds DEPTH exits */
    tls_quarantine_thread_data( make_thread( count, NULL ), count );
    assert( frees == (int)count - 1 + 1 );                  /* oldest: 7 blocks + array */
    assert( tls_freed_count == 1 && evict_lines == 1 );
    /* the freed entry was the FIRST thread's (FIFO) and its slot now holds the newest */
    for (i = 0; i < TLS_REUSE_HISTORY; i++)
        if (tls_freed_addr[i] == (void *)first) break;
    assert( i < TLS_REUSE_HISTORY );
    assert( tls_quarantine[0].pointers != first && tls_quarantine_pos == 1 );
    for (i = 0; i < 3 * TLS_QUARANTINE_DEPTH; i++) tls_quarantine_thread_data( make_thread( count, NULL ), count );
    assert( evict_lines == 1 );                             /* logged once */
    assert( tls_freed_count == 1 + 3 * TLS_QUARANTINE_DEPTH );

    /* reuse detection: fabricate a "new" thread whose array/blocks are freed ones */
    {
        void *fake[8] = { 0 };
        fake[0] = tls_freed_addr[(tls_freed_pos + TLS_REUSE_HISTORY - 1) % TLS_REUSE_HISTORY];
        tls_check_reuse( fake, count );
        assert( reuse_lines == 1 );
        tls_check_reuse( (void **)fake, 1 );
        for (i = 0; i < 40; i++) tls_check_reuse( fake, count );
        assert( reuse_lines == 16 );                       /* capped */
    }

    /* kill switch: immediate free, no parking */
    env_q = L"0"; env_r = NULL; tls_quarantine_init(); reset();
    assert( tls_quarantine_on == 0 );
    tls_quarantine_thread_data( make_thread( count, NULL ), count );
    assert( frees == (int)count && tls_quarantine[0].pointers == NULL );

    /* reuse log off: nothing recorded, nothing printed */
    env_q = NULL; env_r = L"0"; tls_quarantine_init(); reset();
    tls_quarantine_on = 0;
    {
        void *blocks[8], **arr = make_thread( count, blocks );
        void **again;
        tls_quarantine_thread_data( arr, count );
        again = calloc( count, sizeof(void *) );
        again[0] = blocks[0];                              /* stale value, never dereferenced */
        tls_check_reuse( again, count );
        assert( reuse_lines == 0 && tls_freed_addr[0] == NULL );
        free( again );
    }
    /* values other than exactly "0" keep defaults */
    env_q = L"00"; env_r = L"1"; tls_quarantine_init();
    assert( tls_quarantine_on == 1 && tls_reuse_log_on == 1 );

    /* drain parked entries so ASan's leak check sees a clean ring */
    for (i = 0; i < TLS_QUARANTINE_DEPTH; i++)
        if (tls_quarantine[i].pointers) tls_release_thread_data( tls_quarantine[i].pointers, tls_quarantine[i].count );
    reset();
    tls_quarantine_on = 1;
    puts( "tls quarantine: ok" );
    return 0;
}
'''

# ---------------------------------------------------------------- TEB FIFO
f_start = vir.index('#define TEB_FIFO_MIN_FREE')
f_end = vir.index('/***********************************************************************\n *           virtual_alloc_teb')
fifo = vir[f_start:f_end]

teb_prelude = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
'''

teb_main = r'''
static void *head;
static void push( void *p ) { *(void **)p = head; head = p; }   /* virtual_free_teb */
static unsigned len(void) { unsigned n = 0; void *p = head; while (p) { n++; p = *(void **)p; } return n; }

int main(void)
{
    static void *blocks[32][8];
    unsigned i;

    unsetenv( "MADEIRA_TEB_FIFO" );
    assert( teb_fifo_enabled() == 1 );
    void ***h = (void ***)&head;
    assert( teb_fifo_take_oldest( h, TEB_FIFO_MIN_FREE ) == NULL );   /* empty */
    for (i = 0; i < TEB_FIFO_MIN_FREE - 1; i++) push( blocks[i] );
    assert( teb_fifo_take_oldest( h, TEB_FIFO_MIN_FREE ) == NULL );   /* below minimum: fresh block */
    assert( len() == TEB_FIFO_MIN_FREE - 1 );
    push( blocks[TEB_FIFO_MIN_FREE - 1] );
    /* the most recently freed block (the old LIFO answer) is never handed out */
    assert( teb_fifo_take_oldest( h, TEB_FIFO_MIN_FREE ) == blocks[0] );
    assert( len() == TEB_FIFO_MIN_FREE - 1 && head == blocks[TEB_FIFO_MIN_FREE - 1] );
    for (i = TEB_FIFO_MIN_FREE; i < 20; i++)
    {
        push( blocks[i] );
        assert( teb_fifo_take_oldest( h, TEB_FIFO_MIN_FREE ) == blocks[i - TEB_FIFO_MIN_FREE + 1] );
        assert( len() == TEB_FIFO_MIN_FREE - 1 );
    }
    /* reservation-failure fallback: any free block, oldest first, down to empty */
    while (len())
    {
        void *tail = head; while (*(void **)tail) tail = *(void **)tail;
        assert( teb_fifo_take_oldest( h, 1 ) == tail );
    }
    assert( head == NULL && teb_fifo_take_oldest( h, 1 ) == NULL );
    /* single block */
    push( blocks[30] );
    assert( teb_fifo_take_oldest( h, 1 ) == blocks[30] && head == NULL );
    /* cycle guard: never loops forever */
    *(void **)blocks[31] = blocks[31]; head = blocks[31];
    assert( teb_fifo_take_oldest( h, 1 ) == NULL );
    puts( "teb fifo: ok" );
    return 0;
}
'''

teb_off_main = r'''
#include <stdlib.h>
int main(void)
{
    setenv( "MADEIRA_TEB_FIFO", "0", 1 );
    assert( teb_fifo_enabled() == 0 );
    puts( "teb fifo kill switch: ok" );
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    for name, body in (('tls', tls_prelude + quarantine + tls_main),
                       ('teb', teb_prelude + fifo + teb_main),
                       ('teboff', teb_prelude + fifo + teb_off_main)):
        (folder / f'{name}.c').write_text(body, encoding='utf-8')
        subprocess.run(['cc', '-std=gnu11', '-g', '-Wall', '-Wno-unused-function', '-Wno-format',
                        '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                        str(folder / f'{name}.c'), '-o', str(folder / name)], check=True)
        subprocess.run([str(folder / name)], check=True)

print('check-thread-memory-reuse: all ml2000 checks passed')
