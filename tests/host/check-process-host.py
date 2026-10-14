#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml1331 host regression checks for private framing and launcher environments.

Runs production socket I/O and the production environment-edit block on Linux.
Mach operations, JIT and extension lifecycle still require an iOS device.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/process_ios.c').read_text()
start = source.index('    {\n        const char *names[]={"steam.exe","steamwebhelper.exe"};')
end = source.index('    if (cur)\n    {', start)
environment = source[start:end].replace('return STATUS_NO_MEMORY;', 'abort();')

code = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <wchar.h>
#include <sys/time.h>
#include "ProcessHostControl.h"
typedef wchar_t WCHAR;
struct params { WCHAR *Environment; size_t EnvironmentSize; };
static WCHAR *clean(const WCHAR *image, WCHAR *env) {
    struct params params={env,0}; WCHAR *clean_env=NULL;
''' + environment + r'''
    return clean_env;
}
struct writer { int fd; unsigned char *bytes; size_t size; };
static void *fragment(void *arg) {
    struct writer *w=arg;
    for(size_t i=0;i<w->size;i++)assert(ph_control_transfer(w->fd,w->bytes+i,1,1));
    close(w->fd);return NULL;
}
int main(void) {
    _Static_assert(sizeof(PHControlRequest)==64,"wire ABI changed");
    int pair[2];assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    size_t size=PH_CONTROL_LIMIT+113;
    unsigned char *bytes=malloc(size), *got=malloc(size);
    assert(bytes && got);
    for(size_t i=0;i<size;i++)bytes[i]=(unsigned char)(i*17);
    struct writer w={pair[1],bytes,size};pthread_t thread;
    assert(!pthread_create(&thread,NULL,fragment,&w));
    assert(ph_control_transfer(pair[0],got,size,0));
    assert(!memcmp(bytes,got,size));assert(!ph_control_transfer(pair[0],got,1,0));
    pthread_join(thread,NULL);close(pair[0]);
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    assert(ph_control_transfer(pair[1],bytes,17,1));close(pair[1]);
    memset(got,0xaa,32);assert(!ph_control_transfer(pair[0],got,32,0));
    assert(got[17]==0xaa);close(pair[0]);
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    struct timeval timeout={0,20000};
    assert(!setsockopt(pair[0],SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout));
    assert(!ph_control_transfer(pair[0],got,1,0));close(pair[0]);close(pair[1]);
    WCHAR env[]=L"SteamAppId=42\0steamGAMEid=43\0SteamAppPath=C:\\data\0PATH=C:\\windows\0SteamAppIdExtra=keep\0";
    WCHAR before[sizeof env/sizeof *env];memcpy(before,env,sizeof env);
    const WCHAR *images[]={L"C:\\client\\steam.exe",L"D:\\Steam\\bin\\STEAMWEBHELPER.EXE"};
    for(size_t i=0;i<2;i++) {
        WCHAR *result=clean(images[i],env);assert(result);
        assert(!wcscmp(result,L"PATH=C:\\windows"));
        assert(!wcscmp(result+wcslen(result)+1,L"SteamAppIdExtra=keep"));
        assert(!memcmp(before,env,sizeof env));free(result);
    }
    assert(!clean(L"C:\\windows\\system32\\cmd.exe",env));
    assert(!setenv("MADEIRA_SESSION_CLEAN_STEAM_ENV","0",1));
    assert(!clean(images[0],env));
    free(bytes);free(got);puts("process-host framing and launcher environment: PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-process-host-') as temp:
    path = Path(temp)
    (path / 'test.c').write_text(code)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-pthread', '-I' + str(root / 'app/Madeira'), str(path / 'test.c'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True, timeout=20)

extension = (root / 'app/MadeiraProcessHost/ProcessHost.m').read_text()
assert 'xpc_dictionary_set_mach_send' not in extension, 'guarded task-port transfer returned'
assert 'wineserver_inject_client_fd(' not in (root / 'app/Madeira/ProcessHostClient.m').read_text(), 'parentless boot returned'
assert 'wine_ios_child_main' not in extension, 'remote boot must use __wine_main'
assert 'madsync is active in this session' in source, 'remote madsync refusal missing'
print('process-host launch contract: PASS (source checks; device behavior unverified)')

# ml1334: Wine's data directory in an app extension. The production resolver from
# loader_ios.c runs against synthetic bundle trees; the extension's own image directory
# (App.app/PlugIns/<name>.appex) has no nls/, its host app does.
loader = (root / 'build/ntdll-unix/loader_ios.c').read_text()
resolver = loader[loader.index('static int ios_dir_has_nls('):loader.index('#endif\n\nstatic void init_paths(void)')]
assert 'ios_resolve_bundle_dir( exe_path, sizeof(exe_path) );' in loader, 'init_paths no longer resolves the bundle'
assert 'setenv("MADEIRA_BUNDLE_DIR"' in extension, 'the extension no longer names its host bundle'
assert '"MADEIRA_BUNDLE_DIR=",19' in extension, 'an app-supplied MADEIRA_BUNDLE_DIR could override the extension'
probe = r'''
#define _GNU_SOURCE
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
''' + resolver + r'''
int main(int argc, char **argv) {
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", argv[1]);
    ios_resolve_bundle_dir(dir, sizeof dir);
    printf("%s\n", dir);
    return argc < 2;
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-bundle-dir-') as temp:
    path = Path(temp)
    (path / 'probe.c').write_text(probe)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', str(path / 'probe.c'),
                    '-o', str(path / 'probe')], check=True)
    app = path / 'Application' / 'App.app'
    appex = app / 'PlugIns' / 'MadeiraProcessHost.appex'
    (app / 'nls').mkdir(parents=True)
    appex.mkdir(parents=True)
    lonely = path / 'Other' / 'PlugIns' / 'Lonely.appex'
    lonely.mkdir(parents=True)

    def resolve(image, bundle=None):
        env = {k: v for k, v in os.environ.items() if k != 'MADEIRA_BUNDLE_DIR'}
        if bundle is not None:
            env['MADEIRA_BUNDLE_DIR'] = str(bundle)
        run = subprocess.run([str(path / 'probe'), str(image)], env=env, capture_output=True, text=True, check=True)
        return run.stdout.strip(), run.stderr

    out, err = resolve(app)                       # the app itself: unchanged and silent
    assert out == str(app) and err == '', (out, err)
    out, err = resolve(appex)                     # the extension, no hint: its containing bundle
    assert out == str(app) and f'data dir: {app} (appex parent)' in err, (out, err)
    out, err = resolve(appex, app)                # the extension's hint wins
    assert out == str(app) and f'data dir: {app} (bundle env)' in err, (out, err)
    out, err = resolve(appex, path / 'Other')     # a hint without nls/ is ignored, loudly
    assert out == str(app) and 'ignored' in err and '(appex parent)' in err, (out, err)
    out, err = resolve(lonely)                    # nothing anywhere: stays, and says so
    assert out == str(lonely) and 'NO nls/ here' in err, (out, err)
print('process-host data directory (app bundle from an .appex): PASS')
