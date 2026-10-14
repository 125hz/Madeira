#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Exercise production exec-child environment replacement with synthetic pools."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/env_ios.c').read_text()
find = source[source.index('static WCHAR *find_env_var('):source.index('static WCHAR *get_env_var(')]
setters = source[source.index('static void set_env_var('):source.index('static void add_path_var(')]
begin = source.index('            /* ml1331: exec-child startup')
replace = source[begin:source.index('\n        }\n    }\n#endif', begin)]
code = r'''
#define _GNU_SOURCE
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
typedef wchar_t WCHAR;
typedef size_t SIZE_T;
#define max(a,b) ((a)>(b)?(a):(b))
#define wcsnicmp wcsncasecmp
static void ascii_to_unicode(WCHAR *dst,const char *src,size_t n) { for(size_t i=0;i<n;i++)dst[i]=(unsigned char)src[i]; }
static size_t ntdll_umbstowcs(const char *src,size_t n,WCHAR *dst,size_t cap) { assert(n<=cap);ascii_to_unicode(dst,src,n);return n; }
''' + find + setters + r'''
static void dynamic(WCHAR **env,SIZE_T *pos,SIZE_T *size) {
''' + replace + r'''
}
static const WCHAR *value(WCHAR *env,size_t pos,const WCHAR *key) {
    WCHAR *v=find_env_var(env,pos,key,wcslen(key));return v ? v+wcslen(key)+1 : NULL;
}
int main(void) {
    const WCHAR original[]=L"WINE_IOS_JIT_RX=parent-rx\0WINE_IOS_JIT_RW=parent-rw\0WINE_IOS_JIT_SIZE=parent-size\0WINE_IOS_FD_SOCKET=5\0MADEIRA_FASTSYNC=auto\0KEEP=original\0";
    size_t pos=sizeof(original)/sizeof(*original)-1,size=pos+1;
    WCHAR *env=malloc(size*sizeof(*env));memcpy(env,original,sizeof(original));
    assert(!setenv("WINE_IOS_JIT_RX","100000000",1));
    assert(!setenv("WINE_IOS_JIT_RW","200000000",1));
    assert(!setenv("WINE_IOS_JIT_SIZE","20000000",1));
    assert(!setenv("FEX_MADEIRA_HOSTPROBE","AFP=1",1));
    dynamic(&env,&pos,&size);
    assert(!wcscmp(value(env,pos,L"WINE_IOS_JIT_RX"),L"100000000"));
    assert(!wcscmp(value(env,pos,L"WINE_IOS_JIT_RW"),L"200000000"));
    assert(!wcscmp(value(env,pos,L"WINE_IOS_JIT_SIZE"),L"20000000"));
    assert(!wcscmp(value(env,pos,L"MADEIRA_FASTSYNC"),L"0"));
    assert(!wcscmp(value(env,pos,L"KEEP"),L"original"));
    assert(!value(env,pos,L"WINE_IOS_FD_SOCKET"));
    assert(!unsetenv("WINE_IOS_JIT_RW"));
    dynamic(&env,&pos,&size);
    assert(!value(env,pos,L"WINE_IOS_JIT_RW")); // never keep a parent's alias when this task has none
    free(env);puts("process-host private pool environment: PASS");
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-private-pool-') as temp:
    path = Path(temp)
    (path / 'test.c').write_text(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(path / 'test.c'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
