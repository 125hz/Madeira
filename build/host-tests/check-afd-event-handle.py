#!/usr/bin/env python3
"""Production-source regression for the AFD event-handle argument; no Wine or guest runs.

Chain under test: a 32-bit caller's WSAEnumNetworkEvents passes an event HANDLE as the
InputBuffer of IOCTL_AFD_GET_EVENTS -> wow64 get_ptr (guest_ptr32) offsets it by the
window base -> ntdll unix afd_event_handle_arg -> wine_server_obj_handle.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
sock = (root / "wine/dlls/ntdll/unix/socket.c").read_text()
server = (root / "wine/include/wine/server.h").read_text()
wow = (root / "wine/dlls/wow64/wow64_private.h").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
assert "afd_event_handle_arg( in_buffer )" in sock, "GET_EVENTS does not use the helper"
code = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
typedef void *HANDLE;
typedef int32_t LONG;
typedef uint32_t ULONG, obj_handle_t;
typedef uintptr_t ULONG_PTR;
typedef intptr_t INT_PTR;
#define LongToHandle(h) ((HANDLE)(INT_PTR)(LONG)(h))
static ULONG_PTR caller_base, wow_guest_base;
static ULONG_PTR ios_wow_base(void) { return caller_base; }
"""
code += function(wow, "static inline void *guest_ptr32(") + "\n"
code += function(server, "static inline obj_handle_t wine_server_obj_handle(") + "\n"
code += function(sock, "static HANDLE afd_event_handle_arg(") + "\n"
code += r"""
static obj_handle_t through_thunk(ULONG guest_handle) {
    wow_guest_base = caller_base;
    return wine_server_obj_handle(afd_event_handle_arg(guest_ptr32(guest_handle)));
}
int main(int argc, char **argv) {
    if (argc > 1) {
        setenv("MADEIRA_AFD_EVENT_HANDLE", "0", 1);
        caller_base = 0x7200000000ull;
        assert(through_thunk(0x3a4) == 0xfffffff0u);   /* the device failure: invalid handle */
        puts("PASS: rollback reproduces the invalid-handle conversion"); return 0;
    }
    ULONG handles[] = {0x4, 0x3a4, 0x1000, 0x7ffc, 0xfffffffc};
    for (int w = 0; w < 4; ++w) {
        caller_base = 0x7100000000ull + (ULONG_PTR)w * 0x100000000ull;
        for (unsigned i = 0; i < sizeof(handles)/sizeof(*handles); ++i)
            assert(through_thunk(handles[i]) == handles[i]);
        assert(through_thunk(0) == 0);                                  /* no event stays NULL */
        assert(afd_event_handle_arg((HANDLE)0x3a4) == (HANDLE)0x3a4);   /* already a bare handle */
        assert(afd_event_handle_arg((HANDLE)(caller_base + 0x100000000ull + 8))
               == (HANDLE)(caller_base + 0x100000000ull + 8));          /* outside the window: untouched */
    }
    caller_base = 0;                                                    /* native 64-bit caller */
    assert(afd_event_handle_arg((HANDLE)0x3a4) == (HANDLE)0x3a4);
    assert(afd_event_handle_arg((HANDLE)0x7200000010ull) == (HANDLE)0x7200000010ull);
    assert(afd_event_handle_arg(NULL) == NULL);
    puts("PASS: 32-bit event handles survive the buffer conversion in four windows; NULL, native and out-of-window values unchanged");
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
    subprocess.run([str(exe), "rollback"], check=True)
