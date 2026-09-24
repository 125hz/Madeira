#!/usr/bin/env python3
"""ml1520 nsi.dll change requests with no \\\\.\\Nsi device stay pending; no Wine runs.

Compiles the production nsi_notify_pending_enabled / nsi_never_signaled / nsi_pending_notification
and NsiCancelChangeNotification (wine/dlls/nsi/nsi.c) against recording Win32 stubs and checks: an
overlapped request is left STATUS_PENDING with its event reset and a never-signalled handle, the
same handle serves every request, cancelling completes it with STATUS_CANCELLED and sets the
event, a finished request cannot be cancelled, MADEIRA_NSI_NOTIFY_PENDING=0 turns it off, and the
request path only takes it for the missing-device error.
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/nsi/nsi.c").read_text()
a = src.index("static HANDLE nsi_never_event;")
b = src.index("DWORD WINAPI NsiAllocateAndGetTable(")
c = src.index("DWORD WINAPI NsiCancelChangeNotification( OVERLAPPED *ovr )")
d = src.index("DWORD WINAPI NsiEnumerateObjectsAllParameters(")
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int BOOL; typedef unsigned int DWORD; typedef long LONG; typedef void *HANDLE; typedef int WCHAR;
typedef uintptr_t ULONG_PTR;
typedef struct { ULONG_PTR Internal, InternalHigh; DWORD Offset, OffsetHigh; HANDLE hEvent; } OVERLAPPED;
#define WINAPI
#define TRUE 1
#define FALSE 0
#define INFINITE 0xffffffffu
#define INVALID_HANDLE_VALUE ((HANDLE)(intptr_t)-1)
#define ERROR_SUCCESS 0
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_NOT_FOUND 1168
#define ERROR_IO_PENDING 997
#define STATUS_PENDING 0x103
#define STATUS_CANCELLED 0xc0000120
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define ERR(...) fprintf( stderr, __VA_ARGS__ )
#define TRACE(...) ((void)0)

static int events_made, resets, sets, waits; static HANDLE last_reset, last_set;
static HANDLE CreateEventW( void *a, BOOL m, BOOL s, void *n ) { (void)a; (void)m; (void)s; (void)n; events_made++; return (HANDLE)(ULONG_PTR)(0x1000 + 4 * events_made); }
static BOOL ResetEvent( HANDLE h ) { resets++; last_reset = h; return TRUE; }
static BOOL SetEvent( HANDLE h ) { sets++; last_set = h; return TRUE; }
static DWORD WaitForSingleObject( HANDLE h, DWORD t ) { (void)h; (void)t; waits++; return 0; }
static BOOL CloseHandle( HANDLE h ) { (void)h; return TRUE; }
static DWORD GetLastError( void ) { return 8; }
static LONG InterlockedExchange( LONG *p, LONG v ) { LONG o = *p; *p = v; return o; }
static void *InterlockedCompareExchangePointer( void **p, void *v, void *cmp ) { void *o = *p; if (o == cmp) *p = v; return o; }
static DWORD GetEnvironmentVariableW( const void *name, WCHAR *out, DWORD n ) {
    const char *v = getenv( "MADEIRA_NSI_NOTIFY_PENDING" ); DWORD i;
    (void)name; if (!v) return 0; for (i = 0; v[i] && i + 1 < n; i++) out[i] = v[i]; out[i] = 0; return (DWORD)strlen( v ); }
static BOOL nsi_unix_fallback( void ) { return TRUE; }
static HANDLE get_nsi_device( BOOL async ) { (void)async; return INVALID_HANDLE_VALUE; }
static BOOL CancelIoEx( HANDLE h, OVERLAPPED *o ) { (void)h; (void)o; return FALSE; }
""" + src[a:b] + src[c:d] + r"""
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); return 1; } } while (0)
int main( int argc, char **argv ) {
    OVERLAPPED o1 = { 0 }, o2 = { 0 }; HANDLE h1 = 0, h2 = 0;
    if (argc > 1) { CHECK( !nsi_notify_pending_enabled(), "MADEIRA_NSI_NOTIFY_PENDING=0: off" );
        printf( "PASS: MADEIRA_NSI_NOTIFY_PENDING=0 fails requests as before\n" ); return 0; }
    CHECK( nsi_notify_pending_enabled(), "on by default with the fallback" );
    o1.hEvent = (HANDLE)0x2001;   /* low bit: no completion port */
    CHECK( nsi_pending_notification( &o1, &h1 ) == ERROR_IO_PENDING, "overlapped request: ERROR_IO_PENDING" );
    CHECK( o1.Internal == STATUS_PENDING && o1.InternalHigh == 0, "left STATUS_PENDING" );
    CHECK( resets == 1 && last_reset == (HANDLE)0x2000, "its event is reset (completion-port bit masked)" );
    CHECK( h1 && h1 == nsi_never_event, "handle is the never-signalled event" );
    CHECK( nsi_pending_notification( &o2, &h2 ) == ERROR_IO_PENDING && h2 == h1 && events_made == 1, "one event serves every request" );
    CHECK( resets == 1, "no event, nothing reset" );
    CHECK( NsiCancelChangeNotification( &o1 ) == ERROR_SUCCESS && o1.Internal == STATUS_CANCELLED, "cancel completes it CANCELLED" );
    CHECK( sets == 1 && last_set == (HANDLE)0x2000, "and wakes its waiter" );
    CHECK( NsiCancelChangeNotification( &o1 ) == ERROR_NOT_FOUND, "a finished request cannot be cancelled" );
    CHECK( NsiCancelChangeNotification( 0 ) == ERROR_NOT_FOUND, "no OVERLAPPED: not found" );
    CHECK( nsi_pending_notification( 0, 0 ) == ERROR_SUCCESS && waits == 1, "synchronous request waits" );
    printf( "PASS: change requests without the device stay pending until cancelled\n" );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    cfile = Path(t) / "notify.c"; cfile.write_text(harness)
    exe = Path(t) / "notify"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined", str(cfile), "-o", str(exe)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    assert "change requests stay pending" in out.stderr and out.stderr.count("stay pending") == 1, out.stderr
    out = subprocess.run([str(exe), "off"], env=dict(env, MADEIRA_NSI_NOTIFY_PENDING="0"), capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr

req = src[src.index("DWORD WINAPI NsiRequestChangeNotificationEx("):]
req = req[:req.index("\n}\n")]
assert "if (err == ERROR_FILE_NOT_FOUND && nsi_notify_pending_enabled())" in req, "request path uses it for the missing device only"
assert req.index("nsi_pending_notification( params->ovr, params->handle )") < req.index("malloc( in_size )"), "before any device I/O"
print("PASS: NsiRequestChangeNotificationEx takes the pending path only for the missing-device error")
