#!/usr/bin/env python3
"""Host-only regressions for reused image addresses and guest exit publication."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
native = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
process = (root / 'build/ntdll-unix/process_ios.c').read_text()
server = (root / 'build/ntdll-unix/server_ios.c').read_text()

def function(source, signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'

# The lifetime transition must precede unmapping, under the view lock. Failed
# unmaps/in-use shared builtins return before delete_view, preserving live code.
delete = function(native, 'static void delete_view(')
assert delete.index('ios_jit_retire_image') < delete.index('unmap_area(')
assert 'if (view->protect & SEC_IMAGE) ios_jit_retire_image' in delete
unmap = function(native, 'static NTSTATUS unmap_view_of_section(')
assert unmap.index('builtin->refcount--') < unmap.index('if (!status)') < unmap.index('delete_view( view )')
wrapper = function(server, 'void process_exit_wrapper(')
assert wrapper.index('ios_notify_process_exit( status )') < wrapper.index('close(')
assert 'wine_process_did_exit' not in process
assert 'exit_process( exit_code )' in function(process, 'NTSTATUS WINAPI NtTerminateProcess(')

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
struct mapping { void *pe_base, *jit_base; size_t size; void *owner; };
static struct mapping ios_jit_mappings[8];
static int ios_jit_mapping_count;
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
void wine_dock_exit_reset(void);
void wine_process_did_exit(const char *, int);
int wine_dock_exit_status(int *);
typedef uint16_t WCHAR;
typedef struct { struct { unsigned short Length; WCHAR *Buffer; } ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { PEB *Peb; } TEB;
static TEB *current_teb;
static TEB *NtCurrentTeb(void) { return current_teb; }
'''
code += function(native, 'static void ios_jit_retire_image(')
bridge_code = '#include <stdint.h>\n#include <stddef.h>\n#include <strings.h>\nstatic uint64_t g_dock_exit;\n'
for signature in ['void wine_dock_exit_reset(', 'void wine_process_did_exit(', 'int wine_dock_exit_status(']:
    bridge_code += function(bridge, signature)
code += function(server, 'static void ios_notify_process_exit(')
code += r'''
static void *lookup(uintptr_t addr) {
    for (int i=0;i<ios_jit_mapping_count;i++) {
        uintptr_t p=(uintptr_t)ios_jit_mappings[i].pe_base;
        if (p && addr>=p && addr-p<ios_jit_mappings[i].size)
            return (char *)ios_jit_mappings[i].jit_base+(addr-p);
    }
    return NULL;
}
static void *publish(void *arg) {
    for (int i=0;i<1000;i++) {
        wine_process_did_exit("other.exe", 99);
        wine_process_did_exit("DOCKHOST.EXE", (int)(intptr_t)arg);
    }
    return NULL;
}
int main(void) {
    const uintptr_t base=0x70fb8a0000ULL;
    char old_code[64], new_code[64], neighbor[64];
    ios_jit_mapping_count=3;
    ios_jit_mappings[0]=(struct mapping){(void *)base,old_code,0x90000,(void *)1};
    ios_jit_mappings[1]=(struct mapping){(void *)base,old_code,0x90000,(void *)2};
    ios_jit_mappings[2]=(struct mapping){(void *)(base+0x90000),neighbor,0x10000,(void *)3};
    assert(lookup(base)==old_code);
    setenv("MADEIRA_JIT_IMAGE_RETIRE","0",1);
    ios_jit_retire_image((void *)base,0x90000);
    assert(lookup(base)==old_code); // reproduce rollback's stale translation
    unsetenv("MADEIRA_JIT_IMAGE_RETIRE");
    ios_jit_retire_image((void *)base,0x90000);
    assert(!lookup(base));
    assert(!ios_jit_mappings[0].pe_base && !ios_jit_mappings[1].pe_base);
    assert(lookup(base+0x90000)==neighbor); // adjacency is not overlap
    // The same base and image size now require a fresh executable copy.
    ios_jit_mappings[0]=(struct mapping){(void *)base,new_code,0x90000,(void *)2};
    assert(lookup(base)==new_code);
    ios_jit_retire_image((void *)(base+0x80000),0x10000);
    assert(!lookup(base)); // retire aliases overlapping the unmapped range
    ios_jit_retire_image((void *)(base+0x90000),0);
    assert(lookup(base+0x90000)==neighbor);
    int status=123;
    wine_dock_exit_reset();
    assert(!wine_dock_exit_status(&status) && status==123);
    wine_process_did_exit(NULL,1);
    wine_process_did_exit("explorer.exe",1);
    assert(!wine_dock_exit_status(&status));
    wine_process_did_exit("dockhost.exe",(int32_t)0xc0000005);
    assert(wine_dock_exit_status(&status) && (uint32_t)status==0xc0000005);
    wine_process_did_exit("dockhost.exe",0);
    assert(wine_dock_exit_status(&status) && (uint32_t)status==0xc0000005);
    wine_dock_exit_reset();
    wine_process_did_exit("dockhost.exe",0);
    assert(wine_dock_exit_status(&status) && status==0); // zero != no event
    wine_dock_exit_reset();
    pthread_t workers[8];
    for (intptr_t i=0;i<8;i++) assert(!pthread_create(&workers[i],NULL,publish,(void *)(i+1)));
    for (int i=0;i<8;i++) assert(!pthread_join(workers[i],NULL));
    assert(wine_dock_exit_status(&status) && status>=1 && status<=8);
    wine_dock_exit_reset();
    assert(!wine_dock_exit_status(&status));
    // The real normal-exit wrapper extracts a bounded UTF-16 basename before
    // teardown. These paths exercise the ml1850 missed normal-exit regression.
    WCHAR path[256];
    const char *ascii = "C:\\windows\\system32\\DOCKHOST.EXE";
    for (size_t i=0;i<strlen(ascii);i++) path[i]=(WCHAR)ascii[i];
    RTL_USER_PROCESS_PARAMETERS params = {{strlen(ascii)*2,path}};
    PEB peb = {&params}; TEB teb = {&peb}; current_teb=&teb;
    ios_notify_process_exit(30);
    assert(wine_dock_exit_status(&status) && status==30);
    wine_dock_exit_reset(); ios_notify_process_exit(0);
    assert(wine_dock_exit_status(&status) && status==0);
    wine_dock_exit_reset(); current_teb=NULL; ios_notify_process_exit(30);
    current_teb=&teb; teb.Peb=NULL; ios_notify_process_exit(30); teb.Peb=&peb;
    params.ImagePathName.Buffer=NULL; ios_notify_process_exit(30);
    params.ImagePathName.Buffer=path; path[strlen(ascii)-1]=0x100;
    ios_notify_process_exit(30);
    assert(!wine_dock_exit_status(&status));
    for (unsigned i=0;i<256;i++) path[i]='x';
    params.ImagePathName.Length=sizeof(path); ios_notify_process_exit(30);
    assert(!wine_dock_exit_status(&status));
    puts("PASS: image unload/reuse, shared translations, adjacent ranges, rollback, atomic exit status and session reset");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-runtime-') as directory:
    folder=Path(directory)
    source=folder/'check.c'; source.write_text(code)
    bridge_source=folder/'bridge.c'; bridge_source.write_text(bridge_code)
    executable=folder/'check'
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-g','-fsanitize=address,undefined',
                    '-pthread',str(source),str(bridge_source),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
