#!/usr/bin/env python3
"""Production-source regression for the ml1420 unwind no-progress guard (aarch64 PE ntdll).

Device log: a thread spent a whole session in virtual_unwind with a constant stack pointer.
The guard must stop a walk whose steps stop changing Pc and Sp (after three identical steps),
never stop a walk that progresses, and do nothing with MADEIRA_UNWIND_GUARD=0.
"""
from pathlib import Path
import subprocess, tempfile, re
root = Path(__file__).resolve().parents[2]
src = (root / "wine/dlls/ntdll/signal_arm64.c").read_text()
def function(source, start):
    a = source.index(start); b = source.index("{", a); depth = 1; c = b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}"); c += 1
    return source[a:c]
seh = function(src, "NTSTATUS call_seh_handlers(")
assert re.search(r"virtual_unwind\( UNW_FLAG_EHANDLER.*\n.*return status;\n\s*if \(ios_unwind_stalled\( &progress, &context, rec, \"dispatch\" \)\) break;", seh), "dispatch loop guarded"
unw = function(src, "void WINAPI RtlUnwindEx(")
assert 'ios_unwind_stalled( &progress, &new_context, rec, "unwind" )' in unw and "raise_status( STATUS_INVALID_DISPOSITION, rec )" in unw, "unwind loop guarded"
a = src.index("struct ios_unwind_progress {")
block = src[a:src.index("/**********************************************************************\n *           virtual_unwind", a)]
code = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#include <wchar.h>
typedef int BOOL; typedef long LONG; typedef unsigned long ULONG; typedef unsigned long long ULONG64;
typedef unsigned short WCHAR; typedef int NTSTATUS;
#define TRUE 1
#define FALSE 0
typedef struct { ULONG64 Pc, Sp, Lr, Fp; } CONTEXT;
typedef struct { ULONG ExceptionCode; } EXCEPTION_RECORD;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
static void RtlInitUnicodeString(UNICODE_STRING *s, const WCHAR *w) { s->Buffer = (WCHAR *)w; s->Length = 0; }
static int queries;
static NTSTATUS RtlQueryEnvironmentVariable_U(void *env, UNICODE_STRING *name, UNICODE_STRING *val) {
    (void)env; (void)name; queries++;
    const char *v = getenv("MADEIRA_UNWIND_GUARD");
    if (!v) return 0xc0000100;
    val->Buffer[0] = v[0]; val->Length = 2; return 0;
}
static LONG InterlockedIncrement(LONG *p) { return ++*p; }
static int errs;
#define ERR(...) (errs++, fprintf(stderr, __VA_ARGS__))
""" + block.replace('L"MADEIRA_UNWIND_GUARD"', '(const WCHAR *)u"MADEIRA_UNWIND_GUARD"') + r"""
/* a walk: each step either progresses (new Pc/Sp) or sticks */
static int walk(int progress_steps, int limit) {
    struct ios_unwind_progress p = { 0 };
    CONTEXT c = { 0x1000, 0x8000, 0x1000, 0 };
    EXCEPTION_RECORD rec = { 0xc0000005 };
    for (int i = 0; i < limit; i++) {
        if (i < progress_steps) { c.Pc += 4; c.Sp += 16; }   /* else: Pc = Lr = Pc, no progress */
        if (ios_unwind_stalled(&p, &c, &rec, "dispatch")) return i;
    }
    return -1;
}
int main(int argc, char **argv) {
    if (argc > 1) setenv("MADEIRA_UNWIND_GUARD", "0", 1);
    if (argc > 1) { assert(walk(10, 5000) == -1); printf("guard off\n"); return 0; }
    assert(walk(100000, 100000) == -1 && queries == 0);        /* progressing walks never stop, env untouched */
    int s = walk(10, 5000);
    assert(s == 12 && queries == 1 && errs == 1);               /* first repeat at step 10, stop on the third */
    struct ios_unwind_progress p = { 0 };                         /* a Pc-only change is progress */
    CONTEXT c = { 0x1000, 0x8000, 0, 0 };
    for (int i = 0; i < 100; i++) { c.Pc = (i & 1) ? 0x1000 : 0x2000; assert(!ios_unwind_stalled(&p, &c, NULL, "unwind")); }
    for (int i = 0; i < 30; i++) walk(0, 10);                    /* log cap */
    assert(errs == 16);
    printf("guard on\n");
    return 0;
}
"""
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp)/"check.c"; exe = Path(tmp)/"check"; c.write_text(code)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-no-pie", str(c), "-o", str(exe)], check=True)
    on = subprocess.run([str(exe)], check=True, capture_output=True, text=True)
    assert "guard on" in on.stdout and "[unwind-stall] ml1420 dispatch code=c0000005" in on.stderr, on.stderr
    off = subprocess.run([str(exe), "rollback"], check=True, capture_output=True, text=True)
    assert "guard off" in off.stdout and "[unwind-stall]" not in off.stderr
    print("PASS: unwind guard stops walks after three no-progress steps, never stops progressing walks, caps its log; rollback keeps walking")
