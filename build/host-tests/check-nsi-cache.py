#!/usr/bin/env python3
"""ml1510 network-table fixes; no Wine runs.

Part A compiles the production ios_nsi_cached_enumerate (nsi_network_ios.c) against a counting
provider and checks: repeats inside the TTL are served from the cache with the provider's exact
results, a too-small buffer gets STATUS_BUFFER_OVERFLOW with the count untouched, different
requests do not share entries, expiry and MADEIRA_NSI_CACHE_MS=0 reach the provider.
Part B checks nsi.dll's missing-device memo (source invariants).
"""
from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/nsi_network_ios.c").read_text()
a = src.index("#include <pthread.h>\n#include <time.h>")
b = src.index("NTSTATUS nsi_enumerate_all_ex( struct nsi_enumerate_all_ex *params )\n{")
cache = src[a:b]
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef int BOOL; typedef unsigned int UINT; typedef unsigned int ULONG; typedef long NTSTATUS;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_BUFFER_OVERFLOW ((NTSTATUS)0x80000005)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
typedef struct { unsigned int Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } GUID;
typedef struct { unsigned short Length, Type; GUID Guid; } NPI_MODULEID;
static BOOL NmrIsEqualNpiModuleId( const NPI_MODULEID *a, const NPI_MODULEID *b ) { return !memcmp( a, b, sizeof(*a) ); }
/* ml1520 reader attribution */
typedef unsigned short WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { void *UniqueProcess, *UniqueThread; } CLIENT_ID;
typedef struct { CLIENT_ID ClientId; PEB *Peb; } TEB;
#define HandleToULong(h) ((unsigned long)(unsigned long long)(h))
static TEB test_teb; static TEB *NtCurrentTeb( void ) { return &test_teb; }
struct nsi_enumerate_all_ex { void *unknown[2]; const NPI_MODULEID *module; UINT table, first_arg, second_arg;
    void *key_data; UINT key_size; void *rw_data; UINT rw_size; void *dynamic_data; UINT dynamic_size;
    void *static_data; UINT static_size; UINT count; };
struct module_table { UINT table; UINT sizes[4];
    NTSTATUS (*enumerate_all)( void *, UINT, void *, UINT, void *, UINT, void *, UINT, UINT * ); };
static int provider_calls; static UINT rows_now = 3; static int generation = 1;
static NTSTATUS provider( void *k, UINT ks, void *rw, UINT rs, void *d, UINT ds, void *s, UINT ss, UINT *count ) {
    (void)rw; (void)rs; (void)d; (void)ds; (void)s; (void)ss; provider_calls++;
    if (k && rows_now > *count) return STATUS_BUFFER_OVERFLOW;
    for (UINT i = 0; k && i < rows_now; i++) ((int *)k)[i] = generation * 100 + (int)i;
    *count = rows_now; return STATUS_SUCCESS; }
""" + cache + r"""
#define CHECK(c, m) do { if (!(c)) { printf( "FAIL: %s\n", m ); return 1; } } while (0)
int main( int argc, char **argv ) {
    NPI_MODULEID ndis = { 0, 0, { 0xeb004a11 } }, ip = { 0, 0, { 0xeb004a00 } };
    struct module_table entry = { 0, { 4, 0, 0, 0 }, provider };
    int keys[8]; void *data[4] = { keys, 0, 0, 0 }; UINT sizes[4] = { 4, 0, 0, 0 };
    struct nsi_enumerate_all_ex p;
    #define CALL(mod, tbl, cap) (memset( &p, 0, sizeof(p) ), p.module = &(mod), p.table = (tbl), p.key_data = keys, \
        p.key_size = 4, p.count = (cap), ios_nsi_cached_enumerate( &p, &entry, data, sizes ))
    if (argc > 1) {  /* MADEIRA_NSI_CACHE_MS=0 */
        CALL( ndis, 0, 8 ); CALL( ndis, 0, 8 );
        CHECK( provider_calls == 2, "switch off: every read reaches the provider" );
        printf( "PASS: MADEIRA_NSI_CACHE_MS=0 reads live every time\n" ); return 0;
    }
    CHECK( CALL( ndis, 0, 8 ) == STATUS_SUCCESS && p.count == 3 && provider_calls == 1, "first read reaches the provider" );
    generation = 2;  /* the host changed, but inside the TTL the answer is the cached one */
    memset( keys, 0, sizeof(keys) );
    CHECK( CALL( ndis, 0, 8 ) == STATUS_SUCCESS && p.count == 3 && keys[0] == 100 && keys[2] == 102 && provider_calls == 1,
           "repeat inside the TTL is served from the cache with the same rows" );
    p.count = 0;
    CHECK( CALL( ndis, 0, 2 ) == STATUS_BUFFER_OVERFLOW && p.count == 2 && provider_calls == 1, "small buffer: overflow, count untouched" );
    CHECK( CALL( ndis, 1, 8 ) == STATUS_SUCCESS && provider_calls == 2, "another table is a separate entry" );
    CHECK( CALL( ip, 0, 8 ) == STATUS_SUCCESS && provider_calls == 3, "another module is a separate entry" );
    usleep( 600 * 1000 );
    CHECK( CALL( ndis, 0, 8 ) == STATUS_SUCCESS && keys[0] == 200 && provider_calls == 4, "expired entry is read live again" );
    rows_now = 9;
    CHECK( CALL( ndis, 3, 8 ) == STATUS_BUFFER_OVERFLOW && provider_calls == 5, "provider overflow is not cached" );
    CHECK( CALL( ndis, 3, 8 ) == STATUS_BUFFER_OVERFLOW && provider_calls == 6, "and is asked again" );
    printf( "PASS: identical reads inside the TTL come from the cache with the provider's exact results and overflow rule\n" );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "nsi.c"; c.write_text(harness)
    exe = Path(t) / "nsi"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined", str(c), "-o", str(exe), "-lpthread"], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_")}
    out = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr
    env["MADEIRA_NSI_CACHE_MS"] = "0"
    out = subprocess.run([str(exe), "off"], env=env, capture_output=True, text=True)
    print(out.stdout, end=""); assert out.returncode == 0, out.stdout + out.stderr

nsi = (root / "wine/dlls/nsi/nsi.c").read_text()
dev = nsi[nsi.index("static inline HANDLE get_nsi_device( BOOL async )"):nsi.index("DWORD WINAPI NsiAllocateAndGetTable")]
assert dev.index("if (nsi_device_missing[async ? 1 : 0])") < dev.index("CreateFileW( L\"\\\\\\\\.\\\\Nsi\""), "memo checked before any open"
assert "err == ERROR_FILE_NOT_FOUND && nsi_unix_fallback() && nsi_missing_cache_enabled()" in dev, "only a missing device with the fallback present"
assert "SetLastError( nsi_device_missing_err[async ? 1 : 0] );" in dev and "SetLastError( err );" in dev, "callers see the original error"
assert 'L"MADEIRA_NSI_DEVICE_CACHE"' in nsi
print("PASS: nsi.dll opens a missing device once and repeats the original error after that")
