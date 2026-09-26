#!/usr/bin/env python3
"""ml2000 regressions, from production source; no Wine, FEX JIT or device runs.

1. Kill switches and log tags for the ml2000 changes are present.
2. The Mach-thread forwarding predicate (signal_arm64_ios.c) claims exactly a
   split CASAL from FEX JIT code, and nothing when MADEIRA_SPLITLOCK_FEX=0.
3. FEXCore's DoCAS16/32/64 split paths, extracted verbatim from Arm64.cpp,
   repair a torn dual CAS (upper half stored, lower half changed underneath)
   instead of leaving the word torn; MADEIRA_SPLITLOCK_ROLLBACK=0 reproduces
   the upstream tear, proving the test reaches the path. A threaded stress run
   with the strict split-lock mutex keeps an exact count while a neighbour
   writer keeps changing the lower half's other bytes.
"""
from pathlib import Path
import os, re, subprocess, tempfile

root = Path(__file__).resolve().parents[2]
sig = (root / "build/ntdll-unix/signal_arm64_ios.c").read_text()
srv = (root / "build/ntdll-unix/server_ios.c").read_text()
arm = (root / "FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp").read_text()
wow = (root / "FEX/Source/Windows/WOW64/Module.cpp").read_text()
d9 = (root / "research/dxmt/src/d3d9/d3d9_multithread.hpp").read_text()
shim = (root / "research/dxmt/src/d3d9shim/d3d9shim_lock.c").read_text()


def function(source, start):
    a = source.index(start)
    b = source.index("{", a)
    depth, c = 1, b + 1
    while depth:
        depth += (source[c] == "{") - (source[c] == "}")
        c += 1
    return source[a:c]


# ---- 1. switches and tags ---------------------------------------------------
for text, needles in [
    (srv, ["MADEIRA_SPIN_PROBE", "[spin-probe] ml2000", "ios_spin_long_waits", "ios_spin_probe( sp_ids"]),
    (sig, ["MADEIRA_SPLITLOCK_FEX", "[splitlock] ml2000", "ios_splitlock_forward_to_fex( insn,"]),
    (arm, ["MADEIRA_SPLITLOCK_ROLLBACK", "[splitlock] ml2000"]),
    (wow, ["MADEIRA_STRICT_SPLITLOCK", "CONFIG_STRICTINPROCESSSPLITLOCKS, \"1\"", "[splitlock] ml2000"]),
    (d9, ["MADEIRA_D9_LOCK_DIAG", "MADEIRA_D9_LOCK_BACKOFF", "[d3d9-lock-spin] ml2000"]),
    (shim, ["MADEIRA_D9_LOCK_DIAG", "MADEIRA_D9_LOCK_BACKOFF", "[d3d9-lock-spin] ml2000"]),
]:
    for n in needles:
        assert n in text, f"missing {n!r}"
assert arm.count("SplitCASRollback<") == 4, "all four dual-CAS tear sites must roll back"
# The strict default must be applied before the context reads its config.
assert wow.index("CONFIG_STRICTINPROCESSSPLITLOCKS, \"1\"") < wow.index("Context::CreateNewContext("),"strict default applied too late"
assert "thread_local" not in function(arm, "static bool SplitCASRollbackEnabled(")
assert "thread_local" not in function(arm, "static bool SplitCASRollback(")

# ---- 2. forwarding predicate -----------------------------------------------
fwd = function(sig, "static int ios_splitlock_forward_to_fex(")
code_c = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
static uintptr_t image_lo, image_hi;
int ios_jit_pool_image_pc( uintptr_t pc, uintptr_t *pe ) { (void)pe; return pc >= image_lo && pc < image_hi; }
""" + fwd + r"""
int main(int argc, char **argv) {
    const uint32_t casal_w = 0x88E0FC00u | (24u << 5) | 4u;   /* CASAL w0, w4, [x24] */
    const uint32_t casal_x = 0xC8E0FC00u | (24u << 5) | 4u;
    const uint32_t cas_w   = 0x88A07C00u | (24u << 5) | 4u;   /* plain CAS */
    const uint32_t casa_w  = 0x88E07C00u | (24u << 5) | 4u;   /* CASA */
    const uint32_t ldaddal = 0xb8e40304u;
    image_lo = 0x1000; image_hi = 0x2000;
    if (argc > 1) { assert(!ios_splitlock_forward_to_fex(casal_w, 0x711014001e, 0x161ffae30)); puts("PASS: disabled"); return 0; }
    assert(ios_splitlock_forward_to_fex(casal_w, 0x711014001e, 0x161ffae30));   /* the device word */
    assert(ios_splitlock_forward_to_fex(casal_w, 0x100d, 0x161ffae30));         /* 13+4 > 16 */
    assert(!ios_splitlock_forward_to_fex(casal_w, 0x100c, 0x161ffae30));        /* 12+4 == 16: no split */
    assert(!ios_splitlock_forward_to_fex(casal_w, 0x1001, 0x161ffae30));        /* misaligned, inside 16 */
    assert(ios_splitlock_forward_to_fex(casal_x, 0x1009, 0x161ffae30));
    assert(!ios_splitlock_forward_to_fex(casal_x, 0x1008, 0x161ffae30));
    assert(!ios_splitlock_forward_to_fex(cas_w, 0x711014001e, 0x161ffae30));    /* FEX JIT handler claims CASAL only */
    assert(!ios_splitlock_forward_to_fex(casa_w, 0x711014001e, 0x161ffae30));
    assert(!ios_splitlock_forward_to_fex(ldaddal, 0x711014001e, 0x161ffae30)); /* not this path's job */
    assert(!ios_splitlock_forward_to_fex(casal_w, 0x711014001e, 0x1800));      /* pool-copied PE image code */
    puts("PASS: split CASAL from JIT forwarded; non-split, non-CASAL and image code kept");
    return 0;
}
"""

# ---- 3. FEX split CAS -------------------------------------------------------
pieces = [
    function(arm, "static uint64_t LoadAcquire64("),
    function(arm, "static uint32_t LoadAcquire32("),
    function(arm, "static uint8_t LoadAcquire8("),
    function(arm, "static bool SplitCASRollbackEnabled("),
    "template<typename T>\n" + function(arm, "static bool SplitCASRollback("),
    "template<typename T>\nusing CASExpectedFn = T (*)(T Src, T Expected);\ntemplate<typename T>\nusing CASDesiredFn = T (*)(T Src, T Desired);\n",
    "template<bool Retry>\n" + function(arm, "static uint16_t DoCAS16("),
    "template<bool Retry>\n" + function(arm, "static uint32_t DoCAS32("),
    "template<bool Retry>\n" + function(arm, "static uint64_t DoCAS64("),
]
code_cpp = r"""
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <thread>
#include <vector>
#define FEXCORE_TELEMETRY_SET(a, b) do {} while (0)
namespace LogMan::Msg { template<typename... A> void IFmt(const char*, A&&...) {} }
namespace FEXCore::Utils::SpinWaitLock {
template<typename T> struct UniqueSpinMutex {
  T* M;
  explicit UniqueSpinMutex(T* m) : M(m) { T z = 0; auto a = std::atomic_ref<T>(*M); while (!a.compare_exchange_weak(z, 1)) { z = 0; } }
  ~UniqueSpinMutex() { std::atomic_ref<T>(*M).store(0); }
};
}
// Tear injection: the next CAS on `inject_addr` first flips a NEIGHBOUR byte in
// that dword (not part of the operand), exactly what another thread's plain or
// aligned access to adjacent data does between the two halves.
static uint64_t inject_addr; static int inject_byte = -1;
static void maybe_inject(uint64_t Addr) {
  if (inject_byte >= 0 && Addr == inject_addr) { reinterpret_cast<volatile uint8_t*>(Addr)[inject_byte] ^= 0x5a; inject_byte = -1; }
}
static bool StoreCAS64(uint64_t& E, uint64_t V, uint64_t A) { maybe_inject(A); return std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(A)).compare_exchange_strong(E, V); }
static bool StoreCAS32(uint32_t& E, uint32_t V, uint64_t A) { maybe_inject(A); return std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(A)).compare_exchange_strong(E, V); }
static bool StoreCAS8(uint8_t& E, uint8_t V, uint64_t A) { maybe_inject(A); return std::atomic_ref<uint8_t>(*reinterpret_cast<uint8_t*>(A)).compare_exchange_strong(E, V); }
""" + "\n".join(pieces) + r"""
static uint32_t ExpId32(uint32_t, uint32_t E) { return E; }
static uint32_t DesId32(uint32_t, uint32_t D) { return D; }
static uint32_t Nop32(uint32_t S, uint32_t) { return S; }
static uint32_t Add32(uint32_t S, uint32_t D) { return S + D; }
static uint64_t ExpId64(uint64_t, uint64_t E) { return E; }
static uint64_t DesId64(uint64_t, uint64_t D) { return D; }
static uint16_t ExpId16(uint16_t, uint16_t E) { return E; }
static uint16_t DesId16(uint16_t, uint16_t D) { return D; }
alignas(64) static uint8_t buf[64];
static uint32_t rd32(int off) { uint32_t v; memcpy(&v, buf + off, 4); return v; }
static uint64_t rd64(int off) { uint64_t v; memcpy(&v, buf + off, 8); return v; }
int main(int argc, char** argv) {
  const bool upstream = argc > 1;   // run with MADEIRA_SPLITLOCK_ROLLBACK=0
  // (a) 32-bit CAS on the device word shape: offset 14, crosses 16. -1 -> 0.
  memset(buf, 0, sizeof buf); buf[12] = 0x11; buf[13] = 0x22; buf[18] = 0x33; buf[19] = 0x44;
  uint32_t m1 = 0xffffffffu; memcpy(buf + 14, &m1, 4);
  inject_addr = reinterpret_cast<uint64_t>(buf + 12); inject_byte = 0;
  uint32_t r = DoCAS32<false>(0, 0xffffffffu, reinterpret_cast<uint64_t>(buf + 14), ExpId32, DesId32, nullptr);
  if (!upstream) {
    assert(r == 0xffffffffu && rd32(14) == 0);                   // swapped, whole word new
    assert(buf[12] == (0x11 ^ 0x5a) && buf[13] == 0x22 && buf[18] == 0x33 && buf[19] == 0x44);
  } else {
    assert(r != 0xffffffffu && rd32(14) == 0x0000ffffu);         // upstream: reported failed, word torn
  }
  // (b) 32-bit LOCK XADD (Retry): 0x0000ffff + 1 must be 0x00010000.
  memset(buf, 0, sizeof buf); uint32_t v = 0x0000ffffu; memcpy(buf + 14, &v, 4);
  inject_addr = reinterpret_cast<uint64_t>(buf + 12); inject_byte = 1;
  r = DoCAS32<true>(1, 0, reinterpret_cast<uint64_t>(buf + 14), Nop32, Add32, nullptr);
  if (!upstream) assert(r == 0x0000ffffu && rd32(14) == 0x00010000u);
  else assert(rd32(14) != 0x00010000u);                          // upstream: increment lost/doubled
  // (c) 64-bit CAS crossing 16 at offset 12.
  memset(buf, 0, sizeof buf); uint64_t q = ~0ull; memcpy(buf + 12, &q, 8);
  inject_addr = reinterpret_cast<uint64_t>(buf + 8); inject_byte = 0;
  uint64_t r64 = DoCAS64<false>(0x0123456789abcdefull, ~0ull, reinterpret_cast<uint64_t>(buf + 12), ExpId64, DesId64, nullptr);
  if (!upstream) assert(r64 == ~0ull && rd64(12) == 0x0123456789abcdefull);
  else assert(rd64(12) != 0x0123456789abcdefull && rd64(12) != ~0ull);
  // (d) 16-bit CAS at offset 15.
  memset(buf, 0, sizeof buf); buf[15] = 0xff; buf[16] = 0xff;
  inject_addr = reinterpret_cast<uint64_t>(buf + 15); inject_byte = -1;   // 8-bit halves: no neighbour bits, just check success path
  uint16_t r16 = DoCAS16<false>(0x1234, 0xffff, reinterpret_cast<uint64_t>(buf + 15), ExpId16, DesId16, nullptr);
  assert(r16 == 0xffff && buf[15] == 0x34 && buf[16] == 0x12);
  if (upstream) { puts("PASS: upstream (rollback off) reproduces the torn word"); return 0; }
  // (e) stress: 4 split XADD threads (strict mutex on) + 1 neighbour writer.
  memset(buf, 0, sizeof buf); inject_byte = -1;
  uint32_t strict = 0; std::atomic<bool> stop{false};
  std::thread neighbour([&] { auto a = std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(buf + 12));
                               while (!stop.load()) { a.fetch_add(1); for (int k = 0; k < 64; k++) asm volatile("" ::: "memory"); } });   // bumps bytes 12..13 only (wraps within 16 bits rarely)
  std::vector<std::thread> t;
  for (int i = 0; i < 4; i++) t.emplace_back([&] { for (int k = 0; k < 20000; k++)
      DoCAS32<true>(1u << 16, 0, reinterpret_cast<uint64_t>(buf + 14), Nop32, Add32, &strict); });
  for (auto& x : t) x.join();
  stop = true; neighbour.join();
  uint32_t word; memcpy(&word, buf + 14, 4);
  // The operand starts at byte 14; the neighbour writer's carries can reach byte 14 only after 65536
  // increments of bytes 12..13, so compare the upper 16 bits of the operand, which only XADD touches.
  assert((word >> 16) == ((80000u) & 0xffff));
  puts("PASS: DoCAS16/32/64 torn split CAS rolled back and retried; 4x20000 split XADD exact under a neighbour writer");
  return 0;
}
"""

with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    (t / "fwd.c").write_text(code_c)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=address,undefined", "-o", str(t / "fwd"), str(t / "fwd.c")], check=True)
    subprocess.run([str(t / "fwd")], check=True, env={**os.environ, "MADEIRA_SPLITLOCK_FEX": "1"})
    subprocess.run([str(t / "fwd"), "off"], check=True, env={**os.environ, "MADEIRA_SPLITLOCK_FEX": "0"})
    (t / "cas.cpp").write_text(code_cpp)
    subprocess.run(["c++", "-std=c++20", "-O1", "-g", "-pthread", "-o", str(t / "cas"), str(t / "cas.cpp"), "-latomic"], check=True)
    subprocess.run([str(t / "cas")], check=True, env={**os.environ, "MADEIRA_SPLITLOCK_ROLLBACK": "1"})
    subprocess.run([str(t / "cas"), "upstream"], check=True, env={**os.environ, "MADEIRA_SPLITLOCK_ROLLBACK": "0"})
print("PASS: ml2000 split-lock / spin-probe / d3d9-lock checks")
