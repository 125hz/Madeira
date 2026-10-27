#!/usr/bin/env python3
"""Test the production TLS sync call, including failed copy and bad arguments."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'build/ntdll-unix/virtual_ios.c').read_text()
a=s.index('NTSTATUS unixcall_ios_sync_pe_write(void *args)')
fn=s[a:s.index('\n}',a)+2]
loader=(root/'build/ntdll-unix/loader_ios.c').read_text()
pe=(root/'wine/dlls/ntdll/loader.c').read_text()
assert 'unix_ios_sync_pe_write' in (root/'wine/dlls/ntdll/unixlib.h').read_text()
assert 'ios_wrap_13,' in loader and 'wow64_ios_unsupported,               /* ios_sync_pe_write */' in loader
slot=pe[pe.index('static BOOL alloc_tls_slot('):pe.index('static void free_tls_slot(')]
assert slot.index('*(DWORD *)dir->AddressOfIndex = i;') < slot.index('WINE_UNIX_CALL( unix_ios_sync_pe_write') < slot.index('tls_dirs[i] = *dir;')
code=r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef uint32_t ULONG, NTSTATUS;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 1
#define STATUS_UNSUCCESSFUL 2
struct ios_sync_pe_write_params { void *address; ULONG size,synced; };
static ULONG original=9, copy;
static int copied=1, fail, calls;
static void *ios_jit_translate_addr(void *p) { return copied ? &copy : p; }
static void ios_jit_sync_write(void *p, ULONG size) { calls++; if(!fail) memcpy(&copy,p,size); }
FUNCTION
int main(void) {
    struct ios_sync_pe_write_params p={&original,sizeof(ULONG),99};
    assert(unixcall_ios_sync_pe_write(NULL)==STATUS_INVALID_PARAMETER);
    p.size=8; assert(unixcall_ios_sync_pe_write(&p)==STATUS_INVALID_PARAMETER && !calls);
    p.size=4; p.address=NULL; assert(unixcall_ios_sync_pe_write(&p)==STATUS_INVALID_PARAMETER);
    p.address=&original; copied=0;
    assert(!unixcall_ios_sync_pe_write(&p) && !p.synced && !calls);
    copied=1; assert(!unixcall_ios_sync_pe_write(&p) && p.synced && copy==original);
    fail=1; original++;
    assert(unixcall_ios_sync_pe_write(&p)==STATUS_UNSUCCESSFUL && !p.synced);
    puts("PASS: TLS index sync, absent copy, invalid requests and failed verification");
}
'''.replace('FUNCTION',fn)
with tempfile.TemporaryDirectory() as d:
    c,exe=Path(d)/'tls.c',Path(d)/'tls';c.write_text(code)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
