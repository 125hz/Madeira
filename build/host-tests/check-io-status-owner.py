#!/usr/bin/env python3
"""Production-source I/O ABI regression; no Wine or guest executable runs."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
f = (root / "wine/dlls/ntdll/unix/file.c").read_text()
h = (root / "wine/dlls/ntdll/unix/unix_private.h").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
code = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
typedef int BOOL;
typedef uint32_t NTSTATUS;
typedef uintptr_t ULONG_PTR, client_ptr_t;
typedef struct { union { NTSTATUS Status; void *Pointer; }; ULONG_PTR Information; } IO_STATUS_BLOCK;
typedef struct { uint32_t Status, Information; } IO_STATUS_BLOCK32;
#define FILE_SYNCHRONOUS_IO_ALERT 0x10
#define FILE_SYNCHRONOUS_IO_NONALERT 0x20
#define WINE_IOS 1
#define WriteRelease(p,v) __atomic_store_n(p,v,__ATOMIC_RELEASE)
static int is_win64 = 1, session_wow;
static ULONG_PTR caller_base;
static BOOL is_wow64(void) { return session_wow; }
static ULONG_PTR ios_wow_base(void) { return caller_base; }
static client_ptr_t wine_server_client_ptr(void *p) { return (uintptr_t)p; }
static void *wine_server_get_ptr(client_ptr_t p) { return (void *)p; }
"""
code += function(f, "BOOL ios_in_wow64_call(void)")
code += function(h, "static inline BOOL in_wow64_call(void)")
code += function(h, "static inline void set_async_iosb(")
code += function(h, "static inline client_ptr_t iosb_client_ptr(")
code += function(f, "static void set_sync_iosb(")
code += r"""
int main(int argc, char **argv) {
    if (argc > 1) {
        setenv("MADEIRA_IO_STATUS_OWNER", "0", 1);
        caller_base = 0; session_wow = 1; assert(in_wow64_call());
        caller_base = 0x7100000000ull; session_wow = 0; assert(!in_wow64_call());
        puts("PASS: legacy rollback predicate"); return 0;
    }
    for (unsigned pass = 0; pass < 100; ++pass) {
        session_wow = pass & 1;
        caller_base = 0;
        IO_STATUS_BLOCK native = {.Status = 0x103, .Information = 0xabcdef};
        assert(!in_wow64_call()); assert(iosb_client_ptr(&native) == (uintptr_t)&native);
        set_sync_iosb(&native, 0, 0x100000005ull, 0);
        assert(native.Status == 0 && native.Information == 0x100000005ull);
        set_async_iosb((uintptr_t)&native, 0xc0000001, 0x200000006ull);
        assert(native.Status == 0xc0000001 && native.Information == 0x200000006ull);
        caller_base = 0x7100000000ull + (pass % 3) * 0x100000000ull;
        struct { uint32_t guard1; IO_STATUS_BLOCK32 io; uint32_t guard2; } guest = {0x12345678,{0x103,0},0x87654321};
        IO_STATUS_BLOCK cookie = {.Pointer=&guest.io, .Information=0xfeed};
        assert(in_wow64_call()); assert(iosb_client_ptr(&cookie) == (uintptr_t)&guest.io);
        set_sync_iosb(&cookie, 0, 4, 0);
        assert(guest.io.Status == 0 && guest.io.Information == 4);
        assert(cookie.Pointer == &guest.io);
        set_async_iosb(iosb_client_ptr(&cookie), 0xc0000001, 5);
        assert(guest.io.Status == 0xc0000001 && guest.io.Information == 5);
        assert(guest.guard1 == 0x12345678 && guest.guard2 == 0x87654321);
        set_sync_iosb(&cookie, 0, 6, FILE_SYNCHRONOUS_IO_NONALERT);
        assert(cookie.Status == 0 && cookie.Information == 6);
    }
    assert(iosb_client_ptr(NULL) == 0); set_async_iosb(0, 1, 1);
    puts("PASS: mixed native/WoW I/O status, cookie lifetime, full-width count, canaries, loader flag changes");
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe=Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-no-pie", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    subprocess.run([str(exe), "rollback"], check=True)
