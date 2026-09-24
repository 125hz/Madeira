#!/usr/bin/env python3
"""ml1560 window-less consoles for listed programs (kernelbase console.c) and the checked initial
32-bit context (wow64 syscall.c thread_init); no Wine runs.

Part A compiles the production madeira_headless_console against stub environment/PEB types and
checks list matching (base name, case, separators, full paths), the switch and the missing list.
Part B checks thread_init's source: the result and Esp are checked before the context is copied,
with bounded retries, a clean exit, and a switch.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/kernelbase/console.c").read_text()
a = src.index("static BOOL madeira_headless_console( const RTL_USER_PROCESS_PARAMETERS *params )\n{")
b = src.index("void init_console( void )")
func = src[a:b]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


#include <stddef.h>
typedef int BOOL; typedef unsigned int DWORD; typedef wchar_t WCHAR;   /* 2 bytes: -fshort-wchar */
static size_t w_len( const WCHAR *s ) { size_t n = 0; while (s[n]) n++; return n; }
static int w_cmp( const WCHAR *a, const WCHAR *b ) { while (*a && *a == *b) { a++; b++; } return *a - *b; }
static void w_cpy( WCHAR *d, const WCHAR *s ) { while ((*d++ = *s++)); }
static WCHAR w_lower( WCHAR c ) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
#define TRUE 1
#define FALSE 0
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
static const WCHAR *env_list, *env_flag;
static DWORD GetEnvironmentVariableW( const WCHAR *name, WCHAR *out, DWORD n ) {
    const WCHAR *v = !w_cmp( name, L"MADEIRA_HEADLESS_CONSOLE_EXES" ) ? env_list : !w_cmp( name, L"MADEIRA_HEADLESS_CONSOLES" ) ? env_flag : NULL;
    DWORD len; if (!v) return 0; len = w_len( v ); if (len >= n) return len + 1; w_cpy( out, v ); return len; }
static int wcsnicmp( const WCHAR *a, const WCHAR *b, size_t n ) { for (size_t i = 0; i < n; i++) { WCHAR x = w_lower( a[i] ), y = w_lower( b[i] ); if (x != y) return x - y; if (!x) return 0; } return 0; }
static const char *debugstr_wn( const WCHAR *s, DWORD n ) { static char b[64]; DWORD i; for (i = 0; i < n && i < 63; i++) b[i] = (char)s[i]; b[i] = 0; return b; }
#define ERR(...) fprintf( stderr, __VA_ARGS__ )
""" + func + r"""
static BOOL is( const WCHAR *path ) {
    static WCHAR buf[260]; RTL_USER_PROCESS_PARAMETERS p;
    w_cpy( buf, path ); p.ImagePathName.Buffer = buf; p.ImagePathName.Length = w_len( buf ) * sizeof(WCHAR);
    return madeira_headless_console( &p );
}
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); return 1; } } while (0)
int main( void ) {
    CHECK( !is( L"C:\\windows\\system32\\cmd.exe" ), "no list: every console keeps its window" );
    env_list = L"cmd.exe;helper.exe,other.exe";
    CHECK( is( L"C:\\windows\\system32\\cmd.exe" ), "listed: window-less" );
    CHECK( is( L"C:\\Program Files (x86)\\App\\bin\\HELPER.EXE" ), "case-insensitive, full path" );
    CHECK( is( L"other.exe" ), "comma separator, bare name" );
    CHECK( !is( L"C:\\x\\game.exe" ) && !is( L"C:\\x\\xcmd.exe" ) && !is( L"C:\\x\\cmd.exe.bak" ), "exact base names only" );
    env_flag = L"0";
    CHECK( !is( L"C:\\windows\\system32\\cmd.exe" ), "MADEIRA_HEADLESS_CONSOLES=0: windows again" );
    printf( "PASS: listed console programs get window-less consoles; exact names only; switch works\n" );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "con.c"; c.write_text(harness)
    exe = Path(t) / "con"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fshort-wchar", "-fsanitize=address,undefined", str(c), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "[console-headless] ml1560 cmd.exe" in out.stderr, out.stderr

init = src[src.index("void init_console( void )"):]
alloc = init[init.index("CONSOLE_HANDLE_ALLOC_NO_WINDOW;"):]
assert alloc.index("madeira_headless_console( params )") < alloc.index("alloc_console( no_window )"), "decided before the console is made"
print("PASS: the allocation path asks before it creates the console")

wow = (root / "wine/dlls/wow64/syscall.c").read_text()
t_init = wow[wow.index("static void thread_init(void)"):]
t_init = t_init[:t_init.index("\n}\n")]
assert t_init.index("status = pBTCpuGetContext(") < t_init.index("ctx_ptr = (I386_CONTEXT *)guest_ptr32( ctx.Esp ) - 1;"), "checked before the copy"
assert "(status || !ctx.Esp) && wow_init_ctx_retry_enabled()" in t_init and "tries < 64" in t_init, "bounded retry on failure or Esp 0"
assert "NtTerminateProcess( GetCurrentProcess(), status ? status : STATUS_INVALID_PARAMETER )" in t_init, "clean exit instead of a wild write"
assert "MADEIRA_WOW_INIT_CTX_RETRY" in wow
print("PASS: wow64 thread_init checks the initial context before building the 32-bit start frame")
assert 'return alloc_console( madeira_headless_console( RtlGetCurrentPeb()->ProcessParameters ) );' in src, 'AllocConsole asks too'
print("PASS: AllocConsole goes through the same check")
