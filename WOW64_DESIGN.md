# 32-bit (WoW64) support on Madeira — design and progress

Goal: run unmodified x86 32-bit Windows PEs with Wine running native ARM64 and
only the application's own x86 code emulated by FEX. Emulating a whole Linux
userspace (Boxedwine style) is not the production approach.

This document is the single handoff for the work. Sections 1–4 are the design
decision; section 5 is the plan; section 6 is the running status log.

## 1. Constraints (established, do not re-litigate)

- XNU requires a 4 GB hard `__PAGEZERO` for arm64 binaries; nothing can ever be
  mapped at host VA < 4 GB. 4–64 GB is reserved by malloc; usable CPU VA is one
  window `0x7038000000..0x7fffdf0000`. Conventions already in force: Wine
  "furniture"/guest ≤ `0x73ffff0000`, CEF pools `[0x74,0x7c)`, FEX host + arena
  `[0x7c,0x80)` (`STEAM_CEF_HANDOFF.md`, `app/Madeira/StikJITHelper.swift`).
- Every Windows "process" is a pseudo-process thread in one Mach task; they
  share the address space. Two 32-bit processes therefore cannot both own the
  guest range `[0, 4G)`.
- All JIT output must come from the one dual-mapped RX/RW pool reserved at
  startup (`app/Madeira/JITAllocator.c`, `FEXBridge.mm`).
- `KUSER_SHARED_DATA` at `0x7ffe0000` cannot be mapped; accesses are emulated
  in the fault handler (`build/ntdll-unix/signal_arm64_ios.c` ~1727, ~7746).
- Jetsam ceiling 4096 MB.

Classic WoW64 assumes guest address == host address for all 32-bit-visible
memory. That identity is impossible here. Hence:

## 2. Decision: shifted guest window with an explicit FEX base register

Each 32-bit pseudo-process gets a **guest window**: a single reserved host
range `[B, B+4G)` (page-aligned, 4 GB-aligned preferred) inside the furniture
band. Guest address `a` (what the x86 code sees, always < 4 GB) lives at host
address `B + a`.

- **FEX (32-bit mode only):** one ARM64 register is pinned to `B`. Host
  addresses are formed as `B + zext32(EA)`, using the existing
  `[Xbase, Wea, UXTW]` addressing form where possible (zero extra
  instructions), explicit `add` for `ldar/stlr` TSO forms, `Push/Pop`,
  `MemSet/MemCpy`, atomics. Instruction fetch reads from `B + RIP`. Guest
  registers, segment bases, RIP, LookupCache keys, and code-invalidation ranges
  stay in the **guest** namespace. The 64-bit path (ARM64EC, `xtajit64.dll`)
  is untouched: base is 0 / disabled when `Is64BitMode()`.
- **Why not segment bases:** rejected after source inspection. Segment caches
  are `uint32_t` and added at 32-bit width; unprefixed operands get no segment
  term at all; push/pop/call/ret never consult SS; instruction fetch ignores
  CS. See the inspection summary in §6.
- **Wine wow64 layer (`wow64.dll`, `wow64win.dll`):** conversions are already
  type-discriminated by helpers (`get_ptr`, `addr_32to64`, `put_addr`,
  `*_32to64`). Those helpers become window-aware (`+B` / `−B`, NULL stays
  NULL). Handles, sizes, packed APC params, IOSB cookies are **never** offset.
  No global macro rewrite of `ULongToPtr`/`PtrToUlong`.
- **ntdll unix (`build/ntdll-unix/*_ios.c`):** "low memory" for a WoW process
  means the window: TEB block/TEB32, 32-bit stacks, `build_wow64_parameters`,
  i386 image placement/relocation, `ldt_copy`, `HighestUserAddress`,
  `zero_bits` limits, USD emulation range. The window is reserved when a WoW
  process is created and released with it.
- **Single source of truth for B:** `NtQueryInformationProcess` with the
  Wine-private class `ProcessWineIosWowGuestBase = 1010` (declared next to
  `ProcessWineMakeProcessSystem` in `wine/include/winternl.h`). Returns a
  `ULONG_PTR` host address of guest 0 for the target process, 0 for a
  non-WoW process. Both `wow64.dll` and the FEX WoW64 module read it once at
  process init. No environment variables, no globals shared across processes.

## 3. Invariants

1. Any pointer that guest code can observe is a guest address (< 4 GB).
2. Any pointer the native side dereferences is a host address. Guest→host is
   always `+B` of the **owning process**, never the caller's B for
   cross-process operations.
3. `NULL`/0 converts to `NULL`/0 in both directions.
4. Handles, sizes, flags, packed values are never offset.
5. Exception records crossing the boundary convert `ExceptionAddress` **and**
   the address-valued `ExceptionInformation[1]` of access violations.
6. Code-invalidation and SMC tracking use one agreed namespace (guest) at the
   FEXCore/InvalidationTracker boundary.
7. Nothing in the window is ever mapped executable; only JIT output in the
   pool executes.
8. The 64-bit/ARM64EC path must behave identically before and after.

## 4. Pointer-boundary catalogue (from inspection; owners)

| Boundary | Owner | Rule |
|---|---|---|
| Syscall arg block, return addr, unix-call args off ESP | FEX `Source/Windows/WOW64/Module.cpp` | `+B` |
| BOP / unix-call code page | FEX WoW64 module | allocate inside window, publish guest addr |
| `Wow64Transition`, `WOW32Reserved` | `wine/dlls/wow64/syscall.c` | publish guest addr |
| Syscall pointer args / returned addrs | `wow64.dll` `get_ptr`/`put_addr` | `±B`, NULL stays NULL |
| Handles | `get_handle`/`put_handle` | never offset |
| Embedded struct pointers | ~25 `*_32to64` helpers | `+B`; self-relative SD offsets untouched |
| Exception record | `exception_record_32to64/64to32` | `±B` incl. `ExceptionInformation[1]` for AVs |
| TEB32 / FS base | ntdll unix TEB alloc + FEX `SetGDTBase` | TEB pair inside window; FS base = guest addr |
| 32-bit stacks | `thread_ios.c init_thread_stack` | allocate in window |
| i386 image base | `virtual_ios.c map_image_view` | place in window, relocate to guest base |
| KUSER_SHARED_DATA (32-bit view) | `signal_arm64_ios.c` | emulation range becomes `B+0x7ffe0000` |
| Code-invalidation ranges | FEXCore ↔ InvalidationTracker | guest namespace |
| `client_ptr_t` in wineserver requests | `server_ios.c` | one namespace per process (host) |
| IOSB `Pointer` cookie | `iosb_32to64` | host-only, never offset |
| Cross-process VM ops | `wow64/process.c`, `virtual.c` | target's B |

## 5. Plan

Milestone 1: execute a minimal real 32-bit PE (`hello-x86.exe`, i686 mingw,
imports only kernel32: `GetStdHandle`, `WriteFile`, `ExitProcess`) under
Madeira on the iPhone; its string reaches the app log through Wine and the iOS
runtime; exit code 42 is reported; the existing x86-64 path still runs.

Stages and file ownership (max two implementation agents at once):

| Stage | Owner | Files |
|---|---|---|
| A. i386 PE tree + aarch64 `wow64.dll`/`wow64win.dll` build, `hello-x86.exe`, bundle wiring, prefix `syswow64`/registry | BUILD (Sonnet) | `.xtool/*` (local), `build/x86-tests/*`, `scripts/*`, `app/Madeira/i386-windows/`, app resource lists |
| B. FEXCore base register (32-bit mode), WoW64 module iOS port + boundary offsets, `xtajit.dll` build | FEX (Opus) | `FEX/**` only |
| C. ntdll unix window + `ProcessWineIosWowGuestBase`, wow64/wow64win helpers, exception records | WINE (Opus) | `build/ntdll-unix/*`, `wine/dlls/wow64*/**`, `wine/dlls/ntdll/**`, `wine/include/winternl.h` |
| D. Independent review of pointer boundaries, truncation, protections, ABI | REVIEW (Opus) | read-only |
| E. App-side launch: i386 case for `MADEIRA_EXE`, `syswow64` symlink farm, exit-status logging, prefix registry `Wow64\x86` fix, and a launch button below the live view for the 32-bit program under test (same style as the existing test buttons) | APP (Sonnet) | `app/Madeira/WineProcessBridge.m`, `ContentView.swift`, `prefix-template.tar.gz` |
| F. IPA build, device test procedure | BUILD | `.xtool/build.sh` output |

Convention: every 32-bit test program we ship (`hello-x86.exe`, later the
D3D9 cube) gets its own button below the live view, like the existing
x86-64 test buttons.

Host-validatable without a device: i386/aarch64 PE builds and exports; FEXCore
and module compile for iOS; FEX ARM64 JIT unit behaviour under `qemu-aarch64`
user-mode in WSL (Linux aarch64 FEX build running 32-bit ASM tests with a
forced nonzero base) if setup cost is reasonable. Device-only: everything about
the real address space, JIT pool sharing, USD emulation, SMC alias path.

Later milestones: memory alloc/protect, TLS, threads, callbacks, exceptions
(M2); a no-graphics application (M3); D3D9 cube (M4); games (M5+).

M4 notes. Madeira's `research/dxmt` fork has only `src/d3d10` and `src/d3d11`.
BoxedVN pins `https://github.com/dacevedo12/dxmt.git` at tag `v0.4-d3d9`
(commit `e8dd4c656dcb74a6d970a30a397d1558b0e3fb2b`, strategy
"direct-d3d9-metal", `src/d3d9/*.cpp`, with a DXSO shader path) and ships it
runtime-enabled, so a D3D9→Metal frontend in the same DXMT family exists and is
MIT upstream. Plan: port `src/d3d9` from that tag onto Madeira's dxmt fork,
build it as an i386 PE (`d3d9.dll` in `i386-windows/`) whose unix calls cross
the WoW64 boundary via `wow64` unix-call thunks, and add
`build/x86-tests/d3d9-cube-x86.c` (own implementation; BoxedVN's
`tools/guest-probes/d3d9_cube.cpp` is a GPL-2.0-or-later reference for the
shape: FVF XYZRHW|DIFFUSE cube, software vertex processing, `-static-libgcc`,
imports only Wine-supplied DLLs, link `--large-address-aware`).

Rules for all work: never mention a game name in commits or code; never add
game-specific patches — every change must fix the emulator/runtime generically.

## 6. Status log

- 2026-09-13 — **PERF ROUND 3 (ml920): the four items from round 2's §(3) are
  IMPLEMENTED** (Opus; `FEX/FEXCore/**` only — `xtajit.dll` rebuilt, 0 new
  warnings, iOS-host FEXCore compile-checked separately). AUTHORISATION: the
  repository owner decided this fork's FEX subtree is maintained with AI
  assistance and is never contributed upstream (pushes to `125hz/FEX` only, no
  PRs), which is what round 2's item (3) was blocked on. Every change is gated
  to the 32-bit WoW64 CPU module: the new macro `FEX_CALLRET_STACK_UNUSED`
  (`ArchHelpers/Arm64Emitter.h:141`) and `LookupCache::L1_WAYS`
  (`LookupCache.h:188`) are both `FEX_IOS_HOST && !ARCHITECTURE_arm64ec`, so
  ARM64EC and every non-iOS build emit byte-identical code.
  **(1) The dead call-ret shadow stack is no longer written.** Confirmed both
  readers compiled out, and confirmed the WoW64 module is `ARCHITECTURE_arm64`
  (so `Dispatcher.cpp`'s EnterEC reader does not even exist there). Removed:
  the 9-instruction `EmitCallRetStackGuard` + `stp` at both CALL push sites
  (`JIT/BranchOps.cpp:174`, `:337`), the guard + `ldp` + already-dead `sub` at
  the RET pop (`:226`), the JITCallback sentinel push
  (`Dispatcher/Dispatcher.cpp:732`), and the `str`/`ldr` of `callret_sp` in
  Spill/FillStaticRegs (`ArchHelpers/Arm64Emitter.cpp:863`, `:974`).
  Guest CALL 11 instructions → 1; guest RET 11 → 0. **What is deliberately
  KEPT is the lone `adr TMP1, <l_CallReturn>` at a linked CALL**: it is not the
  push, it is the known-call marker `Arm64JITCore::ExitFunctionLink` sniffs to
  decide `bl` vs `b` when it backpatches a callsite (`JIT/JIT.cpp:630`). Drop
  it and every direct call relinks as `b`, unbalancing the hardware
  return-address stack against the `ret Xn` each guest RET emits — a
  mispredict per return, which would have eaten the win. Its immediate and the
  offset the linker reads it from both shrink by one instruction and are now
  derived from the same macro on both sides.
  **(2) The `[Xbase, Wea, UXTW]` fold is emitted.** `GetGuestMemAddr` takes an
  `AllowRegOffsetFold` flag (`JITClass.h:356`) and `GuestMemAddr` carries a
  `RegOffsetFold`/`IndexReg` pair (`:337`); a new `GenerateMemOperand`
  overload turns it into `[x19, wEA, uxtw #0]` (`JIT/MemoryOps.cpp:721`). Passed
  from `LoadMem`/`StoreMem` (all sizes but the 256-bit SVE lowering, whose
  operand has no extend field), from the FPR class of
  `LoadMemTSO`/`StoreMemTSO` — which is the whole x87/SSE path while
  `VectorTSOEnabled=0` — and hand-rolled into `Push` (`:1654`) and `Pop`
  (`:1809`). One `add` off every such access. The TSO GPR path is deliberately
  untouched: LDAPUR/STLUR/LDAPR/LDAR have no register-offset form and the
  unaligned back-patcher decodes them, exactly as §2 requires.
  **(3) The half-barrier `nop` is gated** on the option its only consumer is
  gated on, via the new `ContextImpl::IsHalfBarrierTSOEnabled()`
  (`Interface/Context/Context.h:441`), at all five sites. Default is on, so
  this changes nothing until `FEX_HALFBARRIERTSOENABLED=0` is set — at which
  point it is 4 bytes off every 16/32/64-bit TSO GPR access. A/B, not a win.
  **(4) The L1 is 2-way set-associative** for this module. Same array, same
  2MB/thread, one fewer index bit, two ways. `L1Mask` is now a pre-scaled SET
  mask (`LookupCache.h:416`); ways of a set are contiguous so each way is one
  `ldp`. Way-0 hit costs exactly what the direct-mapped probe cost (same
  instruction count, same registers) in both inline probes
  (`Dispatcher.cpp:281`, `BranchOps.cpp:306` — the latter needs TMP3 to keep
  the set pointer alive, which the direct-mapped form consumes); a way-0 miss
  pays `ldp`/`sub`/`cbz` before falling to the C++ path it would have taken
  anyway. C++ side: `FindBlock` probes both ways, `InsertL1` publishes into
  way 0 demoting way 0 → way 1 (a FIFO), and `InvalidateCache` clears EVERY
  way — missing that would leave a live branch target for invalidated host
  code. Both `InsertL1` callers hold a LookupCache lock and `InvalidateCache`
  requires the write lock, which is what closes the resurrect-a-just-cleared
  -mapping race that demotion would otherwise open. `DisableL2Cache` is
  untouched (round 2's warning about the 512-page L2 arena stands).
  **(5) `repeats~` is fixed and renamed `hot_weight`** (`Core.cpp:1981`). Two
  bugs: the `== 0` test and the `__sync_sub_and_fetch` were separate ops on a
  counter every thread writes, so a lost race wrapped the unsigned counter to
  ~1.8e19 and froze the candidate forever; and the field was never a repeat
  count, it is Boyer-Moore's candidate weight. Saturating CAS now.
  NOT DONE, and the highest-value immediate follow-up: the 16MB-per-thread
  call-ret stack is still RESERVED (`Source/Windows/Common/CallRetStack.h:78`)
  though nothing can now touch it. ml900 already removed its footprint cost, so
  what is left is ~16MB of guest-band VA per guest thread (~640MB at 40
  threads) that item (1) makes free to reclaim. Held back deliberately so this
  round's device A/B stays a single variable.
  A/B knobs for the device run, via `Documents/madeira-fex.txt`:
  `HalfBarrierTSOEnabled=0` (item 3's byte saving, a real ordering trade at
  unaligned sites), `DisableL2Cache=0` (still not obviously a win), and
  `DynamicL1Cache=0` (pins L1 at the 128K-entry ceiling, i.e. 64K sets × 2, so
  item 4 is measured without the growth heuristic moving underneath it). What
  to watch: `[fex-stats] cpp_dispatch/s` (target ≤ 5k/s, from 42-65k),
  `host_b/inst` (from 24), and `[CB_SUMMARY] hit_rate`.

- 2026-09-13 — **PERF ROUND 2: a real profiler, and the pool stops costing
  22 % of the jetsam budget** (Opus; `signal_arm64_ios.c`, `virtual_ios.c`
  pool/census only, `ContentView.swift`). Premise of the round: every
  perf claim so far was a guess, including mine. So the first deliverable
  is measurement, not a fix.
  (1) DONE — **`[prof]` continuous region sampler**
  (`signal_arm64_ios.c:11786`, thread body `:12010`, `ios_prof_start`
  `:12323`, started from the one-time exception-handler init at
  `:5293`). Every 5 ms it samples every thread and buckets the
  host PC by REGION — `jit` (FEX output in the pool tail), `fexrt` (the
  FEX runtime's pool copy), `pe` (each Wine PE pool copy, broken out by
  module), `poolhole`, `unix` (the Madeira binary), `mach` (the same but
  on `wine-x18-exc`), `metal`, `dylib`, `guest`, `fexhost` — plus a
  per-thread histogram (which is what separates DXMT / wineserver / guest
  threads inside the single `unix` bucket) and the top 8 host PCs
  symbolised to module+RVA, or to a guest RIP via ml688's native
  block-tail decoder for JIT PCs. Classification of pool addresses is a
  new lock-free, deref-free `ios_pool_classify_pc()`
  (`virtual_ios.c:2517`); module NAMES are read only at report cadence,
  through the fault-safe reader. `run_state` is consulted BEFORE
  `thread_get_state` on purpose: a running thread's saved state is stale
  and often still points into `libsystem_kernel`, so deciding "waiting"
  from the PC would report a spinning process as idle. The sampler
  measures its own CPU time every window, prints it as `cost=..%/core`,
  and halves its rate (to 40 ms) if that exceeds 2 % — it can never
  silently become the thing it measures. Knob
  `Documents/madeira-prof.txt` = `period_ms[,report_s]`, `0` = off,
  ABSENT = ON at 5 ms/10 s.
  (2) DONE — **pool residency.** (a) The `[pool-warmer]` RX pass is now
  1 cycle in 16 instead of every cycle (`virtual_ios.c:606`), and the
  cycle cost is measured (`cost=..us`). What the RX pass was for: RX and
  RW are two mach mappings of ONE vm object, so residency is established
  by the RW touch alone; what is NOT shared is the per-mapping pmap
  entry, so the RX pass only avoids SOFT faults (PTE install, no I/O) —
  never a decompress. Dropping it entirely would reintroduce a soft-fault
  burst on first execution after pressure; at 1/16 rate the worst case is
  ~9k soft faults spread over 32 s. `MADEIRA_POOL_WARM=0` disables
  touching for an A/B. (b) **The default pool is now session-shaped**
  (`ContentView.swift:2211`): 896 MB for a DESKTOP session (the fan-out
  case — ml364 measured an 858 MB bump there, so this must not move) and
  **512 MB for a direct launch**. The pool is dirty from birth (ml458) so
  its SIZE is the cost: 896 MB was 22 % of the 4096 MB ceiling for a
  measured high-water of head 180.5 + tail 48 = 228.6 MB across every
  direct-launch log on hand. 512 leaves 2.2x headroom and returns
  384 MB. `madeira-pool.txt` still overrides; the three `[jit-pool]
  EXHAUSTED` / `TAIL REFUSED` paths now name the knob and the current
  value in the failure line itself.
  (3) **NOT IMPLEMENTED — `FEX/CLAUDE.md` forbids AI-generated code in
  that subtree** ("AI must not be used to generate code for
  contributions to this project"). The investigation is complete and the
  edits are specified; a human must apply them. Findings, ranked:
  **(3a) The call-ret shadow stack is DEAD CODE on iOS and costs ~44
  bytes per guest CALL and ~44 per RET.** Both readers of the pushed
  `{guest_rip, host_label}` pairs are already compiled out —
  `JIT/BranchOps.cpp:266` (`(void)SkipFullLookup;`, ml305) and
  `Dispatcher/Dispatcher.cpp:199` (`(void)b(&LoopTop);`) — but the 9-
  instruction `EmitCallRetStackGuard` (`ArchHelpers/Arm64Emitter.cpp:535`)
  plus `adr`+`stp` still execute at `BranchOps.cpp:173-187` and `:297-310`,
  and the guard plus `ldp` plus a now-dead `sub` at `:226-235`. Nothing
  branches to the data. Removing the push/pop/guard under the same
  `FEX_IOS_HOST` gate is the single largest `host_b/inst` win available
  and is safe by the file's own contract ("purely a return-address
  PREDICTOR").
  **(3b) The `[Xbase, Wea, UXTW]` fold is never actually emitted.**
  `GetGuestMemAddr` (`JIT/MemoryOps.cpp:588-676`) always returns an
  invalid Offset once a window is active, so `GenerateMemOperand`
  (`:678-704`) always emits `[Xn, #0]` and the UXTW encodings at `:693`
  are unreachable. Every guest access pays one explicit `add x24, x19,
  wEA, uxtw`, and a second `add` when there is any displacement. For TSO
  GPR accesses the first add is unavoidable (LDAPUR/STLUR/LDAPR have no
  register-offset form — `CodeEmitter/LoadstoreOps.inl:1943`), but
  `VectorTSOEnabled=false` on this build, so EVERY SSE/MMX/x87 access and
  every `push`/`pop` is non-TSO and could use the fold: `push eax` is 3
  instructions where upstream emits 1 (`MemoryOps.cpp:1596-1621`).
  **(3c) The half-barrier `nop` is emitted unconditionally** at
  `MemoryOps.cpp:901, 916, 931, 2016, 2032` — 4 bytes on every TSO GPR
  access — while its only consumer is already gated on
  `HalfBarrierTSOEnabled` (`Utils/ArchHelpers/Arm64.cpp:2394-2434` via
  `Windows/Common/TSOHandlerConfig.h:14`). Gating the emission is free;
  the byte saving needs `HalfBarrierTSOEnabled=0`, which is a real
  ordering trade at unaligned sites — an A/B, not a free win. Confirmed:
  Apple Silicon has FEAT_LRCPC2, so it IS lowering to `LDAPUR`/`STLUR`,
  not DMB pairs (`Common/HostFeatures.cpp:633`), and hardware TSO is a
  no-op on iOS (`Windows/Common/FEXUnixLib.cpp:156`).
  **(3d) The dispatcher fallback: the inline probe is CORRECT; the L1 is
  the problem.** `Dispatcher/Dispatcher.cpp:277-289` is bit-identical to
  `LookupCache.h:198-201`, and `L1ptr == cacheL1` in every `[CB_SUMMARY]`
  kills the stale-pointer theory. The slow path DOES refill L1
  (`LookupCache.h:238`). The causes, in order: (i) **`DisableL2Cache=1`
  means there is no middle tier at all** — `Dispatcher.cpp:292` emits
  `b(&NoBlock)`, so every L1 miss is a full C++ round-trip with
  Spill/FillStaticRegs, a contended global atomic (`Core.cpp:1989`) and a
  shared read lock, instead of the inline L2 walk at `:296-349` which
  also back-fills L1; (ii) **the L1 is 1-way direct-mapped on
  `RIP & 0x1FFFF`** (`LookupCache.h:499-515`, capped at 128 K entries on
  iOS by ml363) while 39 k blocks x several entry points each
  (`Core.cpp:2373`) oversubscribe it — conflict misses are the only
  mechanism that explains a SUSTAINED 50 k/s after compile churn stops;
  (iii) **L1 is per-thread, the map is per-CodeBuffer/shared**
  (`Core.cpp:524` vs `CPUBackend.cpp:496`), so every thread pays its own
  first-touch for every entry RIP, renewed after each whole-L1 decommit
  (`ClearThreadLocalCaches`, `LookupCache.cpp:209`, reached from
  `JIT.cpp:803`, `JIT.cpp:1305`, `CPUBackend.cpp:439`); (iv) 3a's disabled
  RET predictor routes every guest RET through the probe, multiplying the
  absolute miss count. NOTE for whoever implements: naively flipping
  `DisableL2Cache=0` is NOT obviously a win here — `CODE_SIZE` is 32 MB
  and `SIZE_PER_PAGE` is 64 KB per guest code page, so the arena covers
  only 512 guest code pages before `ClearL2Cache` wipes it, and a 32-bit
  game's code spans far more. Associativity (2-way) or a larger
  `MAX_L1_ENTRIES` (`LookupCache.h:512`) is the better lever. It is
  testable without a rebuild via `FEX_DISABLEL2CACHE=0` in
  `madeira-fex.txt`.
  (4) DONE — **`[phys-map]` now interprets itself** (`virtual_ios.c`):
  VM tags are named (88 = IOSURFACE, 100 = IOACCELERATOR, 2 =
  MALLOC_SMALL, 0 = untagged anon = ours), and a new `[phys-map] interp`
  line states the two facts that were each mis-read once: the pool is
  counted TWICE in `total_dirty` (RX+RW are one vm object), and
  `hostlow` resident is mostly CLEAN file-backed memory (dyld shared
  cache, framework `__TEXT`, Metal shader libs) which is not charged to
  `phys_footprint` — only its dirty half (194 of 907 MB in the 301 s log)
  is ours. Nothing in `hostlow` is a target.
  Hottest guest RIP in that log resolves to `mmdevapi.dll+0x4056`
  (B = 0x7100000000), but `repeats~` is still the broken majority
  estimator, so treat it as a pointer, not a result — `[prof]` is what
  should decide the next round.

- 2026-09-13 — **Guest-window RELEASE and RE-ADOPTION** (Opus,
  `build/ntdll-unix/*` only). Device evidence (log 28): a 32-bit launcher
  exe ran as an i386 CHILD in the desktop, booted fully (apiset mapped,
  `[wow-syscall] translated 1540 …`), crashed in guest code with
  c0000005 and exited cleanly through `[Wine child exit]
  stage=abort_process` (the teardown fix held, the app survived). The
  user then double-clicked the main 32-bit exe and got
  `[wow-window] B=0x7100000000 REJECTED: its placeholder is already
  adopted …` → `BOOT FAILED at stage 'guest-window-reserve'` →
  `c00000e5`. "One 32-bit process per session, ever" is not acceptable:
  launcher → game is the normal shape of a 32-bit title.
  DESIGN CHOSEN: **release on next adopt** (deferred teardown), because
  the precondition everybody wants — "no thread of the owner is still
  running" — is *unprovable* here and the alternative is worse. On iOS
  `NtTerminateProcess` longjmps out of the CALLING thread only, nothing
  joins a pseudo-process's other threads, and its own boot TEB is never
  freed, so counting `teb_list` entries with `teb->Peb == dead_peb`
  always returns ≥ 1 and proves nothing; and at exit the dying thread is
  still standing ON a TEB (and possibly a stack) inside the range it
  would be replacing. So the EXIT path only marks: slot `dead`, owner
  PEB recorded, placeholder marked UNADOPTED, one line
  `[wow-window] released B=… (owner peb=… exit) — placeholder
  unadopted`. The TEARDOWN runs from `ios_wow_reclaim_dead_windows()` at
  the top of the NEXT `ios_wow_window_reserve()` — i.e. at least one
  process creation later — and, in order: deletes every `file_view`
  fully inside `[B, B+4G)` (images, anon views, the USD second view at
  `B+0x7ffe0000`, the apiset view, the wow64 params block, TEB/PEB
  pages, thread stacks, the BOP page at guest 0x250000), clears
  `pages_vprot` for the whole range, then replaces all 4 GB with **ONE**
  `mmap(MAP_FIXED, PROT_NONE, MAP_ANON|MAP_NORESERVE)` — no `munmap`,
  the reserved-area entry and the FB3 guard are kept exactly as they
  were, so there is never an instant in which the kernel could place a
  system framework in the slot. Then `ios_jit_reclaim_process(dead_peb)`
  + an explicit `ios_jit_purge_window()` (every `[jit-pool] image` and
  `[iOS-xrem]` anon alias describing memory in the window — the next
  process's ntdll/kernel32/exe land on the SAME guest addresses, so
  relying on purge-on-add would leave stale entries shadowing them),
  `[proc-ident]` and fd-cache slots for the dead PEB (its PEB address is
  re-used by the next child, so a survivor would answer for the new
  process), the Mach-port→TEB registry entries pointing into the window,
  and the session globals `wow_peb` / `user_space_wow_limit` / the
  session `peb` (the child path deliberately leaves the global `peb`
  pointing at the last child it booted — after a release that would
  dangle into PROT_NONE). Settle interval `IOS_WOW_SETTLE_SEC = 3`
  before the teardown (same rationale and value as the JIT pool's reuse
  grace); in the launcher→program case it has long expired and nothing
  sleeps. A laggard thread of the dead process now FAULTS on PROT_NONE
  instead of writing into the next process's memory.
  Two states are kept apart on purpose: RELEASED (dead, reclaimable)
  and ABANDONED/`leaked` (`ios_wow_window_retire_current()`, used only
  by env_ios.c's start.exe fallback, where the pseudo-process goes on
  LIVING inside the window — that slot is gone for the session).
  The release is driven from `process_exit_wrapper` keyed by the dying
  PEB (the chokepoint every pseudo-process exit reaches, on whichever
  thread called ExitProcess) with `ios_child_thread_entry`'s
  `release_current` left as the fallback for a child that died before
  binding its window.
  LIMITATION, unchanged and explicit: there is exactly ONE 4 GB-aligned
  slot below the cage holdback, so two 32-bit pseudo-processes cannot be
  alive at once. A 32-bit launcher that spawns the program and STAYS
  ALIVE still fails, now with a clearer message (`a 32-bit
  pseudo-process (peb=…) is running in this window right now`).
  Concurrent 32-bit pseudo-processes need a SECOND slot — which means
  freeing 4 GB of the band (shrinking the cage holdback or moving the
  CEF pools) — out of scope here.
  SAME ROUND, the launcher's own c0000005 SYMBOLIZED: guest RIP
  0x7BC52390 (the reconstructed eip; `[rsp-trunc] guest_rip=0x7bc52273`
  is the JIT block entry) = i386 `user32.dll` (guest base 0x7BC00000)
  RVA 0x52390 = `WPRINTF_GetLen()`'s `WPR_STRING` scan
  `for (len = 0; …) if (!*(arg->lpcstr_view + len)) break;`
  (`cmpb $0x0,(%esi,%edi,1)`, which FEX emits as
  `add w21,w10,w11 / add x24,x19,w21,uxtw / ldaprb w21,[x24]`).
  `[ec-fault-regs] x10=0x63 x11=0x0` → ESI = 0x63, EDI = 0: the STRING
  POINTER ITSELF is 0x63, read on the first iteration. NOT a
  NULL+0x63 field read, and not a pointer-namespace bug of ours —
  `wsprintfA`/`wvsprintfA` is pure i386 PE code with no thunk in the
  path, and Wine's own NULL guard (`arg->lpcstr_view = "(null)"`, one
  instruction earlier at RVA 0x52279) only covers NULL. The program fed
  `%s` a garbage non-NULL value. WHY: 22 lines earlier the log has
  `[dll-missing] L"C:\\windows\\system32\\dxdiagn.dll" status=c0000135`
  → `apartment_add_dll couldn't load in-process dll` →
  `com_get_class_object no class object
  {a65b8071-3bfe-4213-9a5b-491da4461ca7}` = **CLSID_DxDiagProvider**.
  i386 `dxdiagn.dll` is simply NOT IN THE 32-BIT FARM (Wine has it), so
  `CoCreateInstance(CLSID_DxDiagProvider)` fails and the launcher
  formats an uninitialised/garbage string from the failed query. GENERIC
  fix, owner BUILD: add `dxdiagn` and its import closure to
  `.xtool/build-wine-i386.sh` EXTRA_DLLS (any 32-bit program that asks
  DxDiag for system info hits this). Two diagnostics were misleading
  here and should be fixed when convenient: `[x86_live]` printed a host
  address as RSI and `State.RIP=0x0` (no FEX state on the thread —
  values unreliable, use `[ec-fault-regs]`), and `[x86_stk] vm_read
  RSP=0xd8faf4 kr=1` read the GUEST stack pointer without adding B, so
  the caller frame could not be walked. Also seen on the same thread
  before the fatal fault: 10× survivable c0000005 at guest eip
  0x7BB9FF61 = i386 `gdi32.dll` RVA 0x1FF61 inside `get_gdi_client_ptr`
  (`cmpb $0x0,0xe(%eax,%edx,8)`), reading guest 0x38F61B3E — the 32-bit
  GDI shared handle table pointer is garbage for a WoW process; separate
  generic bug, not yet assigned.
- 2026-09-12 — Desktop launch of the cube after the furniture-bias fix
  (IPA 08:22): bias confirmed (session PEB now 0x70ffff0000, TEBs
  0x70fff…), but `[wow-window] B=0x7100000000 REJECTED … next region
  0x71fc120000` — the top ~64 MB of the only slot is occupied by a
  non-Wine mapping: iOS's own top-down placement of anonymous memory for
  system frameworks lands directly below the holdback. Child boot fails
  cleanly now (`BOOT FAILED at stage 'guest-window-reserve'`,
  `NtCreateUserProcess … returning c00000e5` → the "invalid handle" dialog
  the user saw, instead of a hang). Fix assigned (Opus): reserve the
  slot as a PROT_NONE placeholder at session start next to the cage
  holdback and let the first 32-bit process adopt it. The custom-exe
  launcher crashed for the user during the JIT-pool BRK step (log ends at
  `JIT-pool pin chunk 0`, before any 32-bit code) and took two lines in
  the button row; per the user it is REMOVED and replaced by a dedicated
  one-line table entry with the game's full path (explicit user
  exception for app UI; commits and emulator code stay game-name-free).
  DONE (Opus, `virtual_ios.c` only): `ios_wow_reserve_placeholders()`
  runs as the last statement of `virtual_init`, right after the cage
  holdback, and takes every 4 GB-aligned slot in the furniture band as a
  PROT_NONE mapping + reserved area (today: slot 0x7100000000, guard
  borrowed from the holdback). `ios_wow_window_try()` ADOPTS the
  placeholder (no unmap/remap); `ios_wow_exclude_windows()` also hides
  unadopted placeholders from Wine placement and now keeps the side BELOW
  the slot (the side above is the dead holdback); `ios_wow_candidate_slot`
  skips held slots so the top-down bias goes quiet. Range diagnostics now
  say `PARTIALLY OCCUPIED: free a..b, then OCCUPIED b+len` and print
  "REFUSED A FREE ADDRESS" only when the range truly was free. Expected
  log: session start `[wow-window] placeholder reserved
  B=0x7100000000..0x7200000000 (+guard borrowed …) slot 0`; 32-bit child
  `[wow-window] adopted placeholder B=0x7100000000 … guard=borrowed` then
  `[Wine child] i386 image … reserve=0x0`. Cost: 64-bit-only sessions lose
  that slot as preferred furniture space (~2.9 GB below it remains).
- 2026-09-12 — Round with the placeholder IPA (12:14). Both runs confirm
  `[wow-window] placeholder reserved B=0x7100000000` at session start and
  `adopted placeholder` on the 32-bit launch (main path and child path).
  (a) Cube from the 64-bit desktop (child path): boots through wow64.dll,
  xtajit.dll, kernelbase; kernelbase then spawns `conhost.exe` for the
  console-subsystem exe and ntdll's upcase table lookup faults on a NULL
  NLS pointer in the child's ntdll .data pool copy (`[nls-probe] upcase
  ptr: pool[x16+0x4e0]=0xdead1 PE=0x0`, host pc ntdll+0x4b67c); the
  exception dispatch then calls through NULL in wow64.dll+0x1c2a0 and the
  runtime terminates after 2000 redeliveries. Main-process i386 path and
  64-bit children do not hit this. Assigned (Opus). (b) 32-bit main-process
  launch of a real program: window bound, FEX up, loader resolves imports
  and stops at `faultrep.DLL` / `d3dx10_35.dll` not found (stock Wine
  DLLs never added to the i386 set). Assigned (Sonnet: extend
  `.xtool/build-wine-i386.sh` EXTRA_DLLS with faultrep, d3dx10_33-43,
  d3dx11_42/43, d3dcompiler_33-46 and their imports). Also observed there:
  182× `[vmem-denied] set_vprot failed … size=0x1000 protect=0x2` inside
  i386 images (4 KB protections vs 16 KB host pages) — under diagnosis.
  RESOLVED (Opus): (a) root cause — the 64-bit ntdll's `loader_init`
  calls `init_wow64()` which never returns (`Wow64LdrpInitialize`), so
  `locale_init()` never runs in a WoW64 pseudo-process and `nls_info`
  case tables stay NULL; the faulting routine was `upcase_unicode_to_utf8`
  → `casemap()` while kernelbase built the `conhost.exe` path for a
  console-subsystem child (the main-process launch never runs that path,
  64-bit children run `locale_init` normally). Fix: `locale_init()` before
  `init_wow64` under `_WIN64` (`ntdll/loader.c:5518`), `casemap()` falls
  back to ASCII when the table is NULL (`locale.c:48`). The redelivery
  storm was `Wow64PrepareForException` calling
  `pBTCpuResetToConsistentState` unguarded before `load_cpu_dll` had bound
  it (`wow64/syscall.c:1557`, now NULL-checked). The `[nls-probe]`
  diagnostic is stale (assumes `adrp x16` form). (b) DLL set: 28 files
  added (faultrep, d3dx10_33-43, d3dx11_42/43, d3dcompiler_33-41/46, and
  the import closure d3d10_1/d3d10core/d3d11/dxgi as STOCK Wine i386 —
  no Metal backend for those on i386 yet); farm 169 → 197, cross-import
  check clean. (c) `[vmem-denied]` was not page-size: non-NX-compat i386
  modules turn on `force_exec_prot`, and `mprotect_exec` returned -1 when
  iOS refused the forced `+EXEC` without ever applying the plain
  `PROT_READ` requested — bookkeeping said READONLY while the host page
  stayed wider and the caller got ACCESS_DENIED. Now falls through to the
  unforced protection on iOS (`virtual_ios.c:8625`). Expected: i386 child
  logs `[nls-getptr] type=10/11/11` for its own PEB then `loader_init:
  [iOS] wow64 early locale_init done`; no `[vmem-denied] … protect=0x2`.
- 2026-09-12 — Round with the locale/DLL-set IPA (23:21). Confirmed: early
  `locale_init` runs in the i386 child, `[force-exec]` fallthrough applied
  (8 lines, no `[vmem-denied]`), the game loads d3d9/winemetal and 28 new
  DLLs resolve. Remaining, all generic: (a) CHILD path: no API-set map —
  `load_apiset_dll` runs only on the main path, the child clones the
  64-bit parent's PEB, so the 32-bit PEB has `ApiSetMap=0` and every
  `api-ms-win-crt-*` import of d3d9/winemetal fails (no farm ships
  forwarder DLLs; the schema must be mapped into the child's window per
  machine). The app then crashed after the failed child's MADEIRA-EXIT.
  Assigned (Opus #1: loader_ios/process_ios/thread_ios). (b) MAIN path:
  EXCEPTION_WINE_NAME_THREAD raised by 32-bit code reaches the 64-bit
  `dispatch_exception` with a GUEST pointer in ExceptionInformation[1] →
  SEGV in ntdll (§4 boundary miss in `exception_record_32to64`). (c) MAIN
  path: `Wow64SystemServiceEx` calls `ServiceTable[id]` from wow64win's
  read-only .rdata, whose entries are PE addresses → every 32-bit
  NtUser/NtGdi syscall takes a Mach redirect exception (~500k in a minute;
  stale-heal "rewrote 0 slots") — the likely black screen. Assigned (Opus
  #2: wow64/wow64win/virtual_ios/signal_arm64_ios/ntdll exception.c).
  Also seen: one EXECUTE fault on a raw guest address 0x7bf8cbdc on a
  second thread after a FEX CALLRET underflow (under review); missing
  d3d10.dll (delay-load; add to i386 set later), gameux/NVCPL/nvapi/
  PhysXLoader/AgPerfMon absent (expected).
  (a) DONE (Opus #1, loader_ios/thread_ios/process_ios): `wine_ios_child_main`
  never called `load_apiset_dll` for ANY child (64-bit children survived
  on the inherited host pointer); new `ios_child_load_apiset(machine)`
  maps the child's own `/i386-windows/apisetschema.dll` into the window
  via `map_section` and publishes `wow_peb->ApiSetMap` as a guest address
  (`[wow-apiset] child i386 schema mapped at host … = guest …`). The app
  crash was `abort_process()` → raw `_exit()` (not the shimmed `exit()`),
  taken because a child whose `loader_init` fails calls
  `NtTerminateProcess(self)` without the `NtTerminateProcess(0)` that sets
  `exiting_flag`; on iOS it now runs the per-pseudo-process teardown
  (`process_exit_wrapper`) and logs `[Wine child exit] stage=…`. Bonus
  find: `wow_peb` is a session global written only for 32-bit images, so
  a 64-bit child spawned BY an i386 child (conhost) ran
  `build_wow64_parameters` with an untranslated 2 GB ceiling → assert →
  abort; neutralised by saving/NULLing `wow_peb` around
  `unix_init_startup_info` in the child path (`[wow-peb] 64-bit child kept
  out of the WoW64 branch`). Proper home is `env_ios.c:2016` (`init_peb`
  should test `ios_wow_base()`); TODO. Audit leftovers (pre-existing for
  64-bit children too): per-process keyed event missing (`NtCreateKeyedEvent`
  only on the main path; handle tables are per pseudo-process — real
  latent bug), session globals `startup_info_size`/`main_argv` overwritten
  per child (safe only because spawns serialise), `current_machine` stays
  0xaa64 in an i386 child (harmless today), Mach-port→TEB registry misses
  the child's exception thread (`[reg-miss] … slot-0 fallback`).
  (b)+(c) DONE (Opus #2): `exception_record_32to64/64to32` now share one
  catalogue `get_exception_info_ptrs()` of pointer-carrying
  ExceptionInformation entries (AV/in-page [1]; WINE_NAME_THREAD [1] when
  [0]==0x1000; WINE_STUB [0] and [1] when [1]>>16; DBG_PRINTEXCEPTION_C/
  WIDE_C [1]); `dispatch_exception` refuses a sub-4 GB pointer when a
  guest base is published (`[exc-info] refusing to dereference …`). The
  storm was `wow64_NtUserPeekMessage` (wow64win+0x27854): `syscall_tables[1]`
  pointed at wow64win's PE-view .rdata ServiceTable (PE addresses; the
  stale-heal scans only pool copies, hence "rewrote 0"). New memory class
  `MemoryWineIosJitPoolAddress` (1005) in `NtQueryVirtualMemory` returns
  the pool address of a PE VA; wow64.dll copies each ServiceTable into a
  private translated array (`[wow-syscall] translated N ServiceTable
  entries for wow64win.dll`) and translates the 21 CPU-DLL `GET_PTR`
  targets (the other healed addresses were libwow64fex+0x1015a0/f0/638/748).
  Secondary: the EXECUTE fault at raw guest 0x7bf8cbdc is FEX-side — after
  a callret UNDERFLOW+RESET the JIT branched to a guest return address
  without adding B. Assigned (Opus #3, FEX only).
  DONE (Opus #3): NOT a missing base — the callret shadow stack ran away
  (1.3 M entries, 499 % of the 4 MB window, on tid 0040) into the thread's
  own `CpuStateFrame` and overwrote `Pointers.FallbackHandlerPointers[].Func`
  (16-byte-aligned `.Func` halves sit exactly where `stp {guest_rip, host}`
  writes the guest half), so the ABI stub's `blr x3` jumped to a raw guest
  RIP. Every inline callret bounds guard was `#ifdef ARCHITECTURE_arm64ec`,
  but `xtajit.dll` is plain aarch64 + `FEX_IOS_HOST` (same mis-gating class
  as `AllocatorHooks.h`), so this module had NO guard at all; the only reset
  ran at `CompileBlock` entry. Fix: shared `EmitCallRetStackGuard()` under
  `FEX_IOS_HOST` at the three BranchOps sites and the JITCallback push
  (window tightened 16 MB → 4 MB), reset zeroes the exposed frame and writes
  back `State.callret_sp`; `Core.cpp`/`CallRetStack.h` reject non-pool host
  halves after a reset (`[callret] rejected non-pool target host=… rip=…`).
  Expect `[callret] … used=N` ≤ 131072 entries, never `499%`. The leak
  source is expected (SEH unwind/longjmp abandon frames without RET). Also
  shipped: i386 farm +2 (d3d10, ddraw; stock Wine, farm = 199).
- 2026-09-13 — **MILESTONE: a real 32-bit D3D9 game runs on the iPhone**
  (391 s session, renders, takes input; user: "wow, it runs"), and the
  32-bit cube launches from the 64-bit desktop. Exception storms gone
  (`mach: msgs=697`), `[wow-syscall] translated 1540 ServiceTable entries`,
  hit_rate 99 %. Open items from the same batch of logs: (1) PERF — the
  process sits at phys 3.6 GB with 2.1 GB COMPRESSED: only 176 of 896 MB
  JIT pool resident, FEX per-thread 16 MB regions (36 threads) fully dirty
  and swapped (`fex=312 MB dirty`), guest 1138 MB; memory pressure, not
  exceptions, is now the first-order cost. FEX runs on compiled defaults
  (no Config.json found). Assigned (Opus: FEX footprint + generic 32-bit
  JIT settings/toggles + periodic stats line). (2) A 32-bit launcher →
  32-bit program sequence fails: the launcher adopted the only slot, and a
  retired window is never returned → second process `guest-window-reserve
  0xc0000017`. Assigned (Opus: real release via one MAP_FIXED PROT_NONE
  replacement + bookkeeping teardown + re-adoption). The launcher itself
  crashed on a guest NULL+0x63 read (guest RIP 0x7bc52273) — under review.
  (3) A 64-bit (x86_64/arm64ec) title launched from the desktop shows on
  the taskbar but its window is not visible; a 32-bit error dialog from
  explorer likewise not visible — display/compositing of child windows,
  next up. (4) Touch drag acts as left click; user wants a mouse-look
  joystick (and one in landscape fullscreen) — app UI + winios input,
  next up. Teardown fix confirmed: a crashed 32-bit child no longer kills
  the app (`[Wine child exit] stage=abort_process`, session continued).
  (2) DONE (Opus): release-on-next-adopt — exit marks the window dead
  (`[wow-window] released B=… placeholder unadopted`); the next 32-bit
  reserve tears it down under `virtual_mutex` (views inside the window
  deleted, TEBs unlinked from `teb_list`, `pages_vprot` cleared, ONE
  `anon_mmap_fixed(PROT_NONE)` over the 4 GB, jit-pool window purge,
  thread registry / proc-ident / fd cache / `wow_peb` / `user_space_wow_limit`
  / session `peb` reset) after a 3 s settle, then adopts. Concurrent 32-bit
  pseudo-processes still need a second slot (holdback/CEF move) — out of
  scope. The launcher crash was the program formatting a garbage string
  after `CoCreateInstance(CLSID_DxDiagProvider)` failed: i386 `dxdiagn.dll`
  is NOT in the farm → add `dxdiagn` + closure to the i386 set (TODO,
  build owner). Follow-ups found: 32-bit `gdi32` `get_gdi_client_ptr` reads
  a garbage shared handle-table pointer in a WoW process (10 survivable AVs
  — real generic bug, TODO); `[x86_live]`/`[x86_stk]` diagnostics print
  guest values unbased (TODO); `[fdtrace] CROSS! close … fd-cache-release`
  closes other pseudo-processes' fds on child exit (pre-existing, TODO).
  (3) assigned (Opus: win32u-unix driver — the 64-bit title's popup ended
  0x0 after `ChangeDisplaySettings('\\.\DISPLAY1') find_source FAILED`).
  (1) DONE (Opus, FEX only): the biggest sink was FEX's `ZeroScrub` read
  sweep — on Darwin a read fault on an absent anonymous page ALLOCATES a
  real zero page charged to phys_footprint (no shared zero page), so every
  16 MB callret stack and every lookup cache was fully materialised on
  every thread (`mincore_res 16384KB` with `dirty 10448KB`). Replaced by
  `VirtualDontNeed` (decommit+recommit = fresh zero mapping, zero
  footprint); pooled compiler buffers are decommitted when recycled
  (`ThreadPoolAllocator::Recycle`); the frontend decode arena is sized from
  `MaxInst` (640 KB instead of 8 MB per thread). Expected 200-350 MB off
  phys_footprint. Defaults kept (Multiblock, MaxInst 5000, mtrack SMC, TSO
  + half-barrier, L1-only); `X87ReducedPrecision`/`TSOEnabled` exposed via
  `Documents/madeira-fex.txt` (`NAME=VALUE` → `FEX_<NAME>`), not defaulted
  (correctness trade-offs). New lines: one-shot `[fex-cfg]`, periodic
  `[fex-stats] … cpp_dispatch=+N (N/s) hit_rate`. Findings for others:
  the `[phys-map]` census double-counts the pool (RX+RW aliases of one
  object); the pool starts 896 MB resident (~180 MB ever used) — testable
  now via `Documents/madeira-pool.txt` = 384; `[pool-warmer]` touches both
  aliases (362 MB read every 2 s; RX pass redundant for residency);
  hottest RIP is i386 `kernel32!VirtualAlloc` (guest allocator churn, not a
  spin); `repeats~` counter in CB_SUMMARY is a broken majority estimator;
  and 19 M `CompileBlock` entries at 99 % hit = ~49k/s dispatcher
  round-trips the inline L1 probe failed to resolve (L2 disabled → shared
  map under a lock) — the largest remaining generic CPU cost, next.
  (3) DONE (Opus, win32u-unix + IOSDisplayShim): the popup WAS resized to
  0x0 by the application, and the driver's `[win-pos]` gate on empty rects
  hid the transition (now logged as `vis=EMPTY … DEGENERATE` with the
  monitor rects the driver would report). Confirmed driver bug fixed:
  `NtUserChangeDisplaySettings('\\.\DISPLAY1')` failed with BADPARAM in the
  virtual-monitor regime (empty `sources`) although the driver synthesizes
  that name — now validated against the synthesized mode list. Second
  generic bug: win32u's process-global `zero_bits` (set to 0x7fffffff once a
  WoW64 TEB exists) is TASK-global here, so after the first 32-bit launch
  every later low-2 GB allocation in ANY pseudo-process failed
  (`[va-scan] FAILED window=0x10000..0x80000000`) — explorer's error
  dialog got no surface (`surf-create -> 0x0`) and was invisible; cleared
  after init (`syscall_ios.c` wrapper, `[zero-bits] … clearing it`), and a
  failed surface allocation keeps the previous surface. The app sizes a
  degenerate Metal layer from the swapchain as a fallback. Left open:
  `Winios.m` ignores `insert_after` (z-order = creation order).
  (4) DONE (Opus, ContentView only): root cause — the trackpad engine incl.
  Relative mode was gated on `MADEIRA_DESKTOP`, so every game launch used
  the bare path: touch-down = LEFTDOWN|ABSOLUTE, so a drag was a held
  click. Now: Relative mode on the live view posts pure relative MOVE with
  no button (tap still clicks); new aim stick (portrait, next to the
  directional stick; landscape `joystickMouse`) drives
  `winios_pointer(dx,dy,MOVE)` per display-link frame, velocity control
  with dead zone, `sensRel` scale; raw input receives unclamped deltas
  (`queue_ios.c:2290`), legacy `GetCursorPos` consumers still see the
  clamped cursor (would need driver re-centring). Launch table renamed
  `launchTargets` (either bitness; PE probe routes) + one 64-bit entry.
- 2026-09-13 — **REGRESSION (commit ccf6e46).** Clearing win32u's
  `zero_bits` was WRONG: its premise ("32-bit guests never receive a raw
  win32u pointer") is false — win32u hands the guest the GDI shared handle
  table (`init_gdi_shared`, read by i386 gdi32 through `peb64->
  GdiSharedHandleTable` TRUNCATED to 32 bits, which only works because B
  is 4 GB-aligned and the table sat inside the window), DIB pixel buffers,
  DC bucket entries and message return buffers. With `zero_bits`=0 every
  32-bit process now dies in gdi32 `get_gdi_client_ptr` at first GDI use
  (log 29: `addr=0x7138c9057e` = B + low32(host gdi_shared); wined3d
  DllMain → c0000005). Real root cause of BOTH symptoms: win32u
  "process-globals" (`zero_bits`, `gdi_shared`) are TASK-globals here —
  the first pseudo-process (64-bit explorer) allocates `gdi_shared` at a
  host address and every later 32-bit child truncates it (the 10 AVs in
  log 28), and a 32-bit process's `zero_bits` then breaks every later
  64-bit allocation. Fix in progress (Opus): per-pseudo-process
  `zero_bits` (function of the caller's WowTebOffset) and per-PEB GDI
  handle tables allocated with the owner's ceiling. Also this round: the
  `[win-pos] vis=EMPTY` diagnostic fires for ordinary zero-size child
  controls (explorer toolbars) — noisy, to be restricted to top-level
  WS_VISIBLE windows; the 64-bit title's button run (log 31) was still
  loading DLLs when the log ended (no window yet) — needs a longer run
  after the fix; the window release/re-adopt path WORKED (log 32: launcher
  exit → `teardown B=0x7100000000 … 46 view(s) deleted` → second 32-bit
  child adopted).
  DONE (Opus, win32u): `win32u_zero_bits()` per `(pid,peb)` (WoW caller →
  `HighestUserAddress|0x7fffffff`, else 0; routed through every former
  `zero_bits` reader incl. the dib.c section branch that leaked a host
  pointer). The GDI shared table stays ONE session table (dce_list and
  display_dc hand handles across pseudo-processes, so per-process tables
  would break the session) but is section-backed with the master view on
  the host and, for each 32-bit pseudo-process, a SECOND view of the same
  memory mapped inside its window (`[gdi-shared] … guest-view=0x71…`), so
  truncation yields the guest address and the window teardown cannot
  destroy the session table (the pre-regression state was a time bomb:
  the table lived inside the first 32-bit process's window). DC_ATTR
  buckets and cache DCEs are owner-tagged and never recycled across
  pseudo-processes (the other guest-dereferenced pointers). Expected:
  `[zero-bits] peb=… wow=1 ceiling=0xffffffff`, `[gdi-shared] session
  table …` once, `[gdi-shared] … guest-view=…` per 32-bit process, no
  `eip 0x7BA9FF61` AVs, no `[va-scan] FAILED window=0x10000..0x80000000`.
- 2026-09-13 — Round after the win32u fix. 32-bit MAIN path is healthy
  again (301 s run: `[gdi-shared] … guest-view=0x71039e0000`, no AVs; user
  reports ~7 fps in-game → perf round 2 assigned: sampling profiler
  `[prof]`, pool residency (621/896 MB resident, warmer touches both
  aliases, default size), dispatcher fallback 43-65k/s (inline L1 probe
  misses), `host_b/inst=24`). CHILD path: (a) `gdi_shared_section` is a
  HANDLE in the desktop's per-pseudo-process table → child's
  `NtMapViewOfSection` = 0xc0000024, table truncated (assigned: named
  section); (b) 64-bit ntdll RVA 0x39c3c (UTF-16 case-insensitive compare
  loop) read raw guest 0x3e4c78 — §4 miss in some wow64 thunk (assigned);
  (c) the title's main exe needs `msvfw32` (assigned to the same agent:
  i386 set). 64-bit title (arm64ec path, NOT WoW64): from the desktop it
  reaches DXMT but pays 5.6 M emulated stores/min (`[fault-cost] …
  faults=5590872 total=12398 ms`) — exec-downgraded/pool-alias store path;
  from the button it stalls in a lock while loading winhttp/jsproxy
  (`[lock-census] … lockval=0x0`). Read-only investigation assigned.
  RESULTS: (a) DONE — `gdi_shared_section` is now the NAMED object
  `\KernelObjects\__wine_ios_gdi_shared` (OBJ_OPENIF|OBJ_PERMANENT) opened
  per caller; the session `keyed_event` likewise became a per-PEB
  create-or-open of `\KernelObjects\CritSecOutOfMemoryEvent` (run-once
  waits in a child were using a handle from the wrong table). (b) DONE —
  the fault was `_wcsnicmp` called from `wow64!get_file_redirect`:
  `ps_attributes_32to64` copied `PS_ATTRIBUTE_IMAGE_NAME` (and
  GROUP_AFFINITY) `ValuePtr` raw; converted once; `get_file_redirect`
  refuses a sub-4 GB buffer (`[wow-ptr] refusing …`). (c) DONE: msvfw32 +
  avifil32 (farm = 202). 64-bit title investigation (read-only, Opus):
  button launch = DEADLOCK in `InvalidationTracker::HandleImageMap`
  (`std::shared_mutex IntervalsLock` taken per executable section with
  allocating `XIntervals.Insert` + `LogMan` inside → re-entry via
  `NotifyMemoryAlloc`; same signature FEX documents for two other titles);
  desktop launch = the managed runtime's ~42 MB of anon PAGE_EXECUTE_
  READWRITE regions are served as R+X pool aliases, so every plain data
  store faults (5.6 M/min, ~8 µs round trip each, ~1 MB/s); a 64-byte
  stride bulk copy dominates; W^X is off and page-granular; the mono
  bridge only captures SWP atomics; `flags=0x172` = a real resize to 0x0
  by the title (DXGI output `DesktopCoordinates` suspected zero; display
  device enumeration is dormant behind `is_service_process()`). No 64-bit
  title in any log has ever presented a frame. Perf round 2 (Opus): `[prof]`
  5 ms sampling profiler (`Documents/madeira-prof.txt`), pool default 512
  MB for direct launches / 896 desktop (`madeira-pool.txt`), warmer RX
  pass 1/16, census dedup + VM tags (88 IOSURFACE, 100 IOACCELERATOR, 2
  MALLOC_SMALL); `hostlow` 907 MB resident is clean shared-cache text, not
  charged. FEX items found but NOT implemented by that agent (it stopped
  at `FEX/CLAUDE.md`): callret writers are dead code on iOS (~44 B per
  CALL/RET), the `[Xbase,Wea,UXTW]` fold is never emitted, half-barrier
  `nop` unconditional, dispatcher misses = no L2 + 1-way L1 conflicts.
  DECISION (owner, recorded): this fork's FEX subtree IS maintained with AI
  assistance and is never contributed upstream; agents proceed in `FEX/**`.
  Assigned now: FEX codegen/dispatcher items 1-4 (Opus) and the
  InvalidationTracker deadlock + emulated-store write-window stopgap
  (Opus).
  DONE (Opus, ml760): `HandleImageMap` collects section ranges on the
  stack, inserts under ONE lock per batch, logs after release; a TEB-keyed
  (not thread_local — mingw TLS is NULL on early loader paths, ml412)
  re-entrancy guard at every tracker entry logs `[xins] RE-ENTRY …
  SKIPPED` instead of self-deadlocking; two more lock-held
  `NtProtectVirtualMemory` sites (`ProtectRWXIntervalsInternal`,
  `DisableSMCDetection`) scoped the same way. Store storm stopgap:
  `[store-batch]` — 64 consecutive fixed-stride faults arm a ≤512 KB RW
  window for 20 ms over the anon-RWX alias; an EXECUTE fault inside a
  window restores R+X and bans the range; knob `MADEIRA_STORE_BATCH`
  (default on); no FEX invalidation is queued (none existed before
  either; a FEX-side range-invalidate entry point is the durable fix).
  IMPORTANT build finding: `.xtool/build-fex.sh` only built the WOW64
  module — `xtajit64.dll` had never been rebuilt since import; new stage
  `.xtool/build-fex-arm64ec.sh` (gitignored) now produces
  `app/Madeira/arm64ec-windows/xtajit64.dll` (`[build-id] … compiled Sep
  13 2026`). `[waiters] over60s` bar lives in `wine/dlls/ntdll/unix/sync.c:
  3832/3883` — TODO lower to 5 s and print every INF park's address.
- 2026-09-13 — First `[prof]` run (32-bit D3D9 game, 3 min, 8-10 fps idle,
  0.1-0.2 fps while streaming). Not CPU-bound overall (busy≈2 cores,
  wait≈93 %); the serial main thread is: `dylib` 37-73 % = iOS filesystem
  syscalls from Wine's path resolution (`fstatat` 17-28 %, `getattrlistat`
  5-9 %, `__openat` 5-9 %, `read` 3-17 %, `lstat`, `listxattr`,
  `__getdirentries64`), `swtch_pri` 10-22 % (a yield loop), `jit` 22-53 %
  (mostly `hostPC outside block` = unattributed), `pe` 3-10 %, Metal
  ≤0.4 %. Only 64 NtCreateFile failures in the run (all at startup) — the
  cost is SUCCESSFUL lookups: per component `fstatat` +
  `get_dir_case_sensitivity` (`getattrlistat` for the FSID on every call)
  + `lstat` + `listxattr` (DOS-attribute xattr) per query. Codegen round
  confirmed: `host_b/inst` 24→19, `cpp_dispatch` 50k→0.7-4k/s. Footprint
  2.4 GB (pool 512, compressed 465 MB). Assigned: (a) Wine file lookup —
  `[fs-stats]`, per-device case-sensitivity from the existing stat,
  resolved-path cache, DOS-xattr skip flag, NtReadFile overhead (Opus,
  `ntdll/unix/file.c`); (b) profiler v2 — JIT PC → guest RIP → module,
  kernel-sample caller attribution, thread naming, `swtch_pri` source,
  x87/SSE/TSO counters, emulated-D3D9-frontend share and the native-side
  D3D9 design question (Opus, signal_arm64_ios.c + FEX).
  (a) DONE (ml910, `ntdll/unix/file.c` only): `[fs-stats]` 4-line report
  every 10 s (NT-level counts/µs, syscall counts, lookup depth histogram,
  exact-vs-scan, cache hit/miss); `get_dir_case_sensitivity` memoised per
  directory path (no syscall); resolved-name cache keyed by parent path +
  case-folded name, validated by one `fstatat`, whole-path and
  per-component, no negative entries; both DOS/reparse xattrs read with one
  `listxattr` and memoised per (dev,ino,ctime); `MADEIRA_FS_NOXATTR=1`
  A/B knob (off: xattrs from earlier runs would be missed); NtReadFile was
  already pread-based with a cached fd (one extra lseek for the file
  pointer). Expected: getattrlistat/getdirentries ≈0, fstatat ~2 per
  repeat open instead of ~5 per component, listxattr ≈0 on repeats.
  (b) DONE (ml930): FEX publishes a 64K-entry block ring (`IosProfMap.h`:
  host range → guest RIP + per-block x87/vec/TSO counts) via a DATA export
  `BTCpuIosProfMap` (never call PE exports from native — ml613); the
  sampler joins samples to blocks per window, walks the PEB32 loader list
  for the guest module map (the old x64 walk explained `guest=?`), names
  threads by `tid=`, attributes kernel samples to the caller via x30 (+1
  FP hop for shims), and splits a `jitdisp` bucket: the four hottest
  "jit" PCs in l35 were INSIDE FEX's dispatcher (+0x1858..+0x20b8 = the
  x87 F64 helpers / F80 softfloat ABI thunks) — about half the JIT bucket
  was emulator helpers, i.e. x87 softfloat is the prime suspect (VS2005
  msvcr80 = x87 float codegen); `X87ReducedPrecision=1` is a free A/B via
  `Documents/madeira-fex.txt`. `swtch_pri`: the only `sched_yield` is
  `NtYieldExecution` (`sync.c:2405`) with TWO `getrusage` around it (3
  syscalls per yield); callers: `NtUserPeekMessage` on every empty queue
  (`message_ios.c:3682`), `NtDelayExecution` unconditional (`sync.c:2451`),
  timed-out `server_wait` (`server_ios.c:1220`), DXMT's `D9RecursiveSpinlock`
  `SwitchToThread`. Assigned (Opus, small). Native-side D3D9 design written
  up (COM shim in guest memory, native DXMT behind one unix call per API
  call, §4/§7.5 rules) — DO NOT start until `jit by module` shows
  `d3d9.dll` dominating. `BTCpuSuspendThread` spin got a `yield` hint.
  Yields DONE (Opus): the `getrusage` pair was already dead on iOS
  (`RUSAGE_THREAD` is Linux-only) — `NtYieldExecution` = `sched_yield` +
  STATUS_SUCCESS; `NtDelayExecution` yields only for a zero timeout;
  `NtUserPeekMessage`/`wait_message` yield on every 64th CONSECUTIVE empty
  poll (≤1 per 200 µs, streak reset by any delivered message);
  `server_wait` yields only on every 64th consecutive zero-timeout poll.
  Per empty pump iteration: 1 → 0 syscalls; `Sleep(1)`: 2 → 1. Those
  yields were upstream Wine's, not Madeira's.
- 2026-09-14 — `[prof]` v2 A/B (logs 36/37): `X87ReducedPrecision=1` took
  `jitdisp` (x87 F80 softfloat ABI thunks) from 20-50 % of CPU to 0 and
  fps from ~8 to 15-20 (40 in simple views) → becomes the 32-bit default.
  File lookups are now ≈0 while playing (`[fs-stats]` open=0-15/window,
  `pcache` working). Remaining: `d3d9.dll` (emulated DXMT frontend) 20-28 %
  of ALL CPU on the render thread + `dxmt-encode-thr` (95 % JIT) — the
  native-D3D9 gate is MET; wineserver round trips 15-25 %
  (`read<-read_reply_data`, `read<-read_request`, `semaphore_timedwait_trap
  <-main_loop`, `semaphore_signal_trap<-server_call_unlock`); `Sleep(0)`
  yields 5-21 % (`swtch_pri<-NtDelayExecution+0x24c`); pool-warmer
  `mach_msg2_trap` 1-5 %. Memory: log 37 shows compressed=1714 MB of 2469
  (pressure state differs between runs). User also reports the on-screen
  sticks/buttons intermittently going dead. Assigned: input robustness
  (Opus: ring coalescing, drain trigger, gesture-state watchdogs);
  `[srv-stats]` + in-process fast sync design/first step + `Sleep(0)`
  streak throttle + x87 default (Opus). Next: the native-side D3D9 port.
  DONE: (a) input — the 256-slot event ring DROPPED THE NEWEST event when
  full (comment claimed oldest) and the 120 Hz aim stick filled it during
  streaming stalls, so key/button transitions were discarded (dead sticks,
  stuck keys); `AimStickDriver.holders` was a bare refcount that a missed
  `end()` pinned forever (self-sustaining 120 Hz flood); `TouchControlButton`
  had no `onDisappear`. Now: ring 1024, consecutive pure moves coalesce
  (relative deltas sum, absolute keep newest), transitions never dropped,
  `winios_release_all_keys()`, app-side `InputGuard` ownership model with a
  1 Hz reconciler against driver-held keys, tokens instead of a refcount,
  `@GestureState` + `onDisappear` on every held control, release-all on
  scene deactivation; `[input] ring …`/`[input] reconcile …` lines. Drain
  trigger already ran from `GetAsyncKeyState` — no driver thread needed.
  (b) `[srv-stats]` (5 lines/10 s: reqs/s, in-call time, top kinds with
  avg µs from a generated `req_names` table with a `C_ASSERT` on
  `REQ_NB_REQUESTS`, top threads, NT-level counters, the `select`
  classification `w1/wN × inf/fin/poll`, futex counters). DECISION: no
  fastsync yet — the alert ping-pong is futex-based on iOS (`USE_FUTEX` for
  `__APPLE__`, `sync.c:139`) and never touches the server; whether the
  round trips are pacing `select`s (fix client-side) or event/semaphore
  traffic (build fastsync) is decided by the `select:` line next run. The
  fastsync design is written and verified against upstream's `inproc_*`
  hooks (`sync.c:800-959`, dead on iOS) and server `*_sync` split
  (`event.c:127-150`): cell = state word + `srv_waiters` + client waiters +
  generation; Dekker pairing with `wait_on`/`check_wait` (`thread.c:1242,
  1304`); same wake primitive on both sides; fast waits capped at ~2 ms
  then fall through to `server_wait` (APCs/alerts/wait-all untouched).
  `Sleep(0)`: 16-call `isb` pause ladder then one `sched_yield` per 8 →
  123 syscalls per 1000 (8.1×); streak reset on real waits/non-zero sleeps.
  x87: `X87REDUCEDPRECISION=1` is now the 32-bit default unless the user
  set it (`[fex-cfg]` reports `X87ReducedPrecision(madeira-32bit-default)`).
  (c) §8 below: the native D3D9 plan (Opus, read-only investigation).
- 2026-09-14 — First `[srv-stats]` run (log 38): **38k server requests/s**,
  0.76 core in round trips; `get_message` 24k/s + `get_thread_info` 10k/s,
  26k/s of it from the game's MAIN thread, which spins `PeekMessage` +
  `Sleep(0)` (75k `Sleep(0)`/s) waiting for the render thread. Upstream's
  shared-queue fast path (`check_queue_bits` / `get_shared_queue`) should
  answer an empty peek without a server call — not engaging on iOS.
  `select:` line: w1 inf 5k, fin 2.9k, wN fin 1k, tmo_fin 1k — pacing waits
  are secondary. `event_op` 2.2k/s on the render/worker threads. Ring
  healthy (`dropped 0`), aim `holders=0` after a stray tap: SwiftUI
  `DragGesture` controls cancel on a second touch → UIKit multi-touch
  overlay assigned. `d3d9.dll` 21-24 %, `jit` 47 %, `dylib` 41-45 %.
  Assigned: shared-queue fast path + `get_thread_info` source + deeper
  `Sleep(0)` pause (Opus); UIKit multi-touch controls (Opus). In flight:
  D3D9 step 0 (census + nop bench) and step 2 (description + generator).
  NOTE: four implementation agents at once this round (user's 60 fps
  push; files disjoint).
  RESULTS: (1) `get_message` storm ROOT CAUSE — `check_queue_bits`'s
  hung-queue guard compares `get_tick_count()` (KUSER_SHARED_DATA
  TickCount, NEVER written on iOS unless `MADEIRA_USD_TIME=1` → reads 0)
  against the server's `mach_continuous_time` stamp → UINT64 underflow →
  `skip` never true → every empty peek a server round trip (also why
  `check_queue_masks` never skipped; the 2026-07-04 heartbeat was a
  workaround for the same bug). Fix: iOS `get_tick_count()` reads
  `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` (commpage; same epoch/unit
  as the server). `[msgq]` lines. `get_thread_info`: per-thread cache of
  the caller's own ThreadBasicInformation/affinity (`[thrinfo]` line
  names the class and self/other). `Sleep(0)`: after 512 consecutive
  spins the periodic rung becomes a 10 µs `futex_wait` park (`park=`
  counter). Expected `get_message` 243k → ~4 per 10 s per GUI thread.
  (2) Controls moved to a raw UIKit multi-touch `ControlOverlayView` in
  the controls window (per-touch ownership, no gesture arbitration;
  `[input] touch id=… began/ended on <control>`, `[input] controls: …`).
  (3) D3D9 step 0 DONE: `[d3d9-census]` (317 methods, summaries at
  Present 1/100/1000/every 5000, calls/frame, top 20, constant-register
  and lock-size histograms) and `unixcall-bench-x86.exe` (slot 150
  `_d3d9_nop`, `WMTNop`; prints `MADEIRA-BENCH: unix-call ns/call`, exit
  44). FINDING: the i386 DXMT PE stage built with meson's default
  `debug` (-O0) — the measured `d3d9.dll` was UNOPTIMISED; release is
  now the i386 default (Sonnet). (4) D3D9 step 2 DONE: `d3d9_api.py` (320
  slots: local 70 / sync 175 / defer 75), `gen_d3d9_thunks.py` → ~19.7k
  generated lines, 13 guard rails verified firing, API hash handshake,
  fixed-width blocks shared by both tables (no `_32` variants needed);
  five mirrors not four (`D3DPRESENTSTATS` differs: LARGE_INTEGER is
  4-byte aligned on i386); `D3DADAPTER_IDENTIFIER9` sizeof 1100 vs 1104
  (padding only); both sides syntax-clean (i386 clang; LP64 gcc + LLP64
  aarch64 clang). Next: steps 1 (native build mode) and 3 (shim
  hand-written parts).
- 2026-09-14 — Log 39 (queue-clock fix + release d3d9 + multi-touch):
  user reports "almost always above 30 fps" in the training level (was
  15-20). `[srv-stats]` 38k → 1.4k reqs/s, in-call 0.76 → 0.03 core;
  `[msgq] peek=2.8M skipped=2.8M served=414`; `[thrinfo] basic self=33k
  (cached=32k)`; controls: 42 touches began/ended, 0 cancelled/missed.
  `d3d9.dll` 20-28 % → 9-12 % (release build). NEW FINDINGS: (1)
  `[d3d9-census]`: **203,648 D3D9 calls per frame**, of which
  `Query::GetData` + `GetDataSize` = 85,695 each — the render thread
  busy-polls a query (GPU fence / occlusion) until the GPU finishes; then
  `SetSamplerState` 12.4k/frame, `SetRenderState` 6.8k, `SetTexture` 2.3k,
  `SetVertexShaderConstantF` 2.1k (mostly 1 or 3-4 registers),
  `DrawIndexedPrimitive` 608, `DrawIndexedPrimitiveUP` 201,
  `TestCooperativeLevel` 809 — the ring design (§8.6) must defer exactly
  these; the GetData spin needs a real wait (flush + block on the Metal
  command buffer completion, not a poll). (2) `mach_msg2_trap <-
  ios_pool_warmer_thread` 4.4-4.8 % of ALL CPU: the periodic `[phys-map]`
  walk over ~130k VM regions. (3) `[fs-stats] pcache=h87/m822/p0` — the
  resolved-name cache never stores; opens still 0.6 ms (`scan=635`,
  `dirscan=548`). (4) `Sleep(0)` at 288k/s on the main thread (waiting
  for the render thread) → 33k parks/s, `__ulock_wait2` 9-14 %.
  Render thread (tid 00c0) is the critical path: 32-34 % busy, jit 70 %.
  Assigned: census cost + park ladder (Opus, virtual_ios.c/sync.c);
  path-cache populate bug (Opus, file.c); the query spin waits for step 1
  to release `src/d3d9/**`.


- 2026-09-12 — M5 direction: the user's next target is a 32-bit UE3/D3D9
  game (name deliberately not recorded). Finding from the user: launching
  the D3D9 cube by double-clicking it in the Wine virtual desktop does
  nothing (the child-process path for an i386 image has never run on
  device; the button path makes the exe the main process). Work started
  (two agents): (a) full i386 Wine DLL set incl. d3dx9_*, d3dcompiler,
  xinput, dinput, dsound, xaudio2, msvcr*/msvcp*, ole32/oleaut32/shell32
  etc. via `.xtool/build-wine-i386.sh`; (b) child-launch trace/fix +
  generic "Custom exe" launcher in the app (text field persisted in
  UserDefaults, full Win32 path, working directory = exe folder; no
  hardcoded paths, no game names). Queued: 32-bit audio/nsi/dwrite
  unixlib tables. Limitation to remember: one 4 GB window slot → one
  32-bit process at a time (a 32-bit launcher spawning a 32-bit game
  cannot work yet).
- 2026-09-12 — Desktop double-click logs (cube and the 32-bit game exe,
  both from the Wine virtual desktop): NO `NtCreateUserProcess` line for
  either target, while `services.exe`/`rpcss.exe` in the same sessions
  log it and go through the child path normally. So the launch is
  swallowed BEFORE the process-creation syscall (explorer double-click
  handling on touch, shell32 `ShellExecute`, or kernelbase
  `CreateProcessInternalW` bailing early) — not the 32-bit child path.
  Discriminator for the user: double-click a 64-bit exe in the same
  explorer. The custom launcher (in progress) bypasses explorer entirely.
  CORRECTION (same day): that reading was wrong — the planner's grep had
  stopped short. Both logs DO contain `NtCreateUserProcess` for the
  target (18:4390, 19:4592) followed by `[Wine child thread] ENTRY …
  machine=0x14c` and `guest window reserve FAILED: 0xc0000017`. Root
  cause: the session's top-down furniture (TEBs at 0x71ffed0000…,
  parent PEB 0x71ffff0000) sits inside the ONLY 4 GB-aligned candidate
  `[0x7100000000, 0x7200000000)`, so a 32-bit CHILD can never reserve it
  (a 32-bit MAIN image reserves before its first TEB, which is why the
  button works). Fixes (Opus, main `0ab948b`): `map_view` top-down bias
  keeps the last aligned slot free (`virtual_ios.c:10564`, advisory via
  `ceiling_relaxable`; `ios_wow_candidate_slot()` `:5810`); the failed
  child leaked its server socket so the parent's `NtCreateUserProcess`
  waited forever (`process_ios.c:473`) — now returns an error; the
  owner-fallback in `ios_wow_slot_current` (`:5546`) refused a bound slot
  during the bind gap, so every 32-bit child's `TEB32->Peb` was a
  truncated host pointer — fixed; `init_thread_stack` status checked
  (`loader_ios.c:3406`); every child early-exit logs its stage
  (`CHILD_STAGE`/`CHILD_BOOT_FAIL`). Launcher: `@AppStorage`
  `madeiraCustomExePath`/`madeiraCustomExeArgs`, "Launch custom exe" row
  (`ContentView.swift:1564`); `WineProcessBridge.m`: PE-machine-driven
  farm choice for full paths, quote-aware `MADEIRA_ARGS`, exe folder as
  cwd, 1024-byte paths, bare names present in a 64-bit farm are not
  probed as i386 (the full i386 set now contains `explorer.exe`).
- 2026-09-12 — Full i386 DLL set built (Sonnet, `.xtool/build-wine-i386.sh`,
  reproducible; logs in `.xtool/logs/build-wine-i386*.log`): 169 files,
  87.5 MiB stripped, all PE32; 163 of 168 targets built; no i386 rule
  for `winecoreaudio.drv`, `conhost`, `rpcss`, `services`, `wineboot`;
  `wineios.drv` not in the i386 tree. Import closure clean except
  `d3d12.dll → dxgi.dll` (DXMT-owned i386 `dxgi`/`d3d11`/`d3d10core`
  exist from stage 1 and can be installed later for a 32-bit DX11 path).
  `apisetschema.dll` installed. `aarch64-windows/` ships no `.drv` at all
  — the audio agent must find how 64-bit audio binds its driver on iOS
  and replicate it for i386. Audio/nsi/dwrite table agent (Opus) started.
- 2026-09-12 — 32-bit audio/nsi/dwrite done (Opus; main `1541d46`, wine
  `87c1947`). Audio: `mmdevapi` binds the driver BY NAME
  (`__wine_load_unix_lib(L"wineios.drv")` → `MemoryWineLoadUnixLibByName`
  → Madeira's by-name fallback returns the table with a magic handle) —
  no `.drv` PE is ever mapped, so none is needed for i386; the real
  blocker was `MemoryWineLoadUnixLibByNameWow64` returning
  STATUS_NOT_SUPPORTED. Now `audio_null_ios_unix_call_wow64_funcs` (37
  slots, 20 new thunks, 37 `ios_wow_host_ptr` sites) registered by name
  (`virtual_ios.c:17946`) and by module (`:6427`); the render scratch
  buffer is allocated inside the guest window (`zero_bits=1` ceiling,
  refuses loudly otherwise); `get_loopback_capture_device` uninitialised
  result fixed. nsi: 1-slot wow64 table (struct derived from
  `wine/include/wine/nsi.h:496`; no `nsi/unixlib.c` in this tree).
  dwrite: 12 `ULongToPtr` → `ios_wow_host_ptr` in `freetype.c` incl.
  nested outline arrays. Expected lines: `[unixlib] audio_null_ios
  (wineios.drv) -> wow64 table`, `[unixlib] nsi … -> wow64 table`,
  `[unixlib] dwrite … -> wow64 table`. IPA rebuild started.


- 2026-09-12 — Cube test rework confirmed on device (IPA 00:43):
  `cull=CCW z=off seconds=15`, all presents hr=0, **frames presented =
  36765 in 15.00 s, avg fps = 2451.0** (uncapped; trivial scene — a
  crossing-overhead figure, not a game prediction), exit 43, no faults.
  Near faces render correctly with the driver's cull mapping. The x64
  DX11 cube runs fine on the same IPA → no 64-bit regression from the
  shared FEXCore/rpmalloc/driver changes. Buttons trimmed to the cube.
  M5 started: (a) full i386 Wine DLL set (Sonnet), (b) 32-bit audio /
  nsi / dwrite wow64 tables (Opus). Then a real 32-bit application.


- 2026-09-12 — **MILESTONE 4 PASSED (third cube run, IPA 23:58).** The
  32-bit D3D9 cube rendered on the iPhone: `first DrawPrimitive returned
  hr 0x00000000`, `present 1..3 hr=0x00000000`, frames 1–240 presented,
  `done, frames presented = 240`, `MADEIRA-EXIT: d3d9-cube-x86.exe
  status=43`, no faults, no allocator warnings. Screenshot shows the cube
  with the far faces visible instead of the near ones: the test's own
  software back-face culling (signed screen-space area, CULLMODE NONE) has
  an inverted sign for the y-down XYZRHW space — a test bug, not a
  renderer bug (the driver drew exactly the submitted triangles). Test
  being changed to use `D3DCULL_CCW` (exercises the port's cull mapping)
  and 900 frames. App overlay showed `Present: 240 | FPS: 0.9`; the FPS
  figure is the app's own counter and needs checking against the 32-bit
  present path later. Next: 64-bit regression check (x64 DX11 cube) since
  shared FEXCore/rpmalloc code changed; then M5 (real 32-bit programs:
  hooks lparam, 32-bit audio/nsi tables, guest threads, SEH, input).


- 2026-09-11 — SECOND D3D9 CUBE RUN (IPA 23:32): both previous fixes
  confirmed (`[unixlib] winemetal … -> wow64 table (0x105946d90)`; no x87
  fault). Reached: `Direct3DCreate9 ok`, `device created (software vertex
  processing)`, `dynamic vertex buffer created`, `first locked vertex
  pointer 0x0164a000` (guest), `frame 1`, `frame 2` — a 32-bit D3D9 device
  on Metal with draw calls through the thunks. Two remaining bugs: (A)
  survivable — `NtUserCallTwoParam`/`GetMonitorInfo` MONITORINFO* forwarded
  as a ULONG by wow64win (`get_monitor_info` read guest 0xc1f75c); (B)
  fatal — on DXMT worker threads, `dispatch_data_create` copied from
  `0x7159db4800` (= B + low32 of a HOST pointer): the compiled DXSO
  bitcode is returned to the 32-bit caller as a host pointer, truncated,
  then rebased by the `newLibrary` 32-bit thunk. Fix assigned (Opus):
  NtUserCall*Param pointer-code classification; bitcode kept host-side by
  handle (mirror SM50 thunk32 pattern), audit of host-pointer results.
  User observation: live view stayed black during frames 1–2 (no clear
  colour visible) — presentation not yet confirmed; a present log line is
  being added to the cube test.


- 2026-09-11 — FIRST D3D9 CUBE RUN (IPA 22:13): i386 `d3d9.dll` and
  `winemetal.dll` loaded; two independent bugs. (1) `load_builtin_unixlib`
  named the i386 winemetal `(unknown)` and bound the stub table: the PE
  export-directory parse used `IMAGE_NT_HEADERS64` on a PE32 image
  (`DataDirectory` at +96 vs +112 → read the resource dir). Fixed:
  `ios_module_export_name()` magic-dispatched PE32/PE32+
  (`virtual_ios.c:6146`), `ios_module_mapped_file_name()` wineserver
  fallback (`:6213`), unknown module for a WoW caller now
  `STATUS_NOT_SUPPORTED` + `[unixlib] UNRECOGNISED module …` (`:6394`).
  (2) FEX x87 stack-optimisation pass: `_FormContextAddress(STATE +
  idx*16)` (host) fed to `_LoadMemFPR/_StoreMemFPR` with `#0x420`
  (`x87StackOptimizationPass.cpp:441/477/610`) → `GetGuestMemAddr` applied
  the guest base to a HOST address → `str q2` at `B + low32(STATE+…)`;
  guest RIP = mingw `ceilf` in d3d9.dll (first x87 code any 32-bit test
  ran). The faulting region was plain unallocated window space, not a
  DXMT arena. Fix assigned (Opus, FEX/**): context-indexed ops + audit
  for other host addresses flowing into guest memory ops.


- 2026-09-11 — **MILESTONE 2 PASSED (thirteenth device run, IPA 21:38).**
  `window-x86.exe`: `created hwnd`, `painted`, `painted-via-updatewindow`,
  `invalidate-rect returned 1`, `update-window returned 1`, exit
  `status=43`, no faults, ZERO `[rpm-avail] ml607` lines (allocator
  invariant fix confirmed). `[paint-diag] hwnd=0x10028 swp=4000193f
  parent=0x10022 desktop=0x10022 parent_style=00000000 parent_vis=0` — the
  desktop window's style reads 0 for the 32-bit process, so `ShowWindow`
  took the style-toggle branch; the driver repaint covers it, but the
  style query is an M3 item (`NtUserGetWindowLong` on the desktop from a
  WoW thread, or `is_window_visible` in win32u). `d3d9-cube-x86.exe`:
  launch path works; `Library d3d9.dll not found` (exit 0xC0000135) —
  expected until stage 4 produces the i386 `d3d9.dll`.


- 2026-09-11 — **D3D9 stage 4 done: the i386 `d3d9.dll` compiles, links and is
  installed** (Opus; details in §7.11). All 107 compile errors from 39 distinct
  causes are closed, 21/21 `src/d3d9` translation units build as i386 PE, and
  `app/Madeira/i386-windows/d3d9.dll` is 3,280,896 B, Machine 0x14C, importing
  only `KERNEL32`/`USER32`/`GDI32`/`winemetal.dll` + the `api-ms-win-crt-*`
  sets and exporting `Direct3DCreate9`, `Direct3DCreate9Ex` and the `D3DPERF_*`
  family. The `MADEIRA-TEMP` `-Denable_d3d9` meson option is removed; d3d9 now
  builds unconditionally for Windows targets. d3d11/d3d10core/dxgi still build
  on both i386 and aarch64 (aarch64 checked with `--install none`, so the
  64-bit farms are untouched — §7.7 risk 8). The work was: 30 call-site renames
  in the imported sources; ~10 self-contained back-ports from the `v0.4-d3d9`
  tag; a winemetal ABI *command* extension (four render commands + one blit
  command, appended at the reference's own values, needing **no** new unix-call
  slot because they ride the already-converted `encodeCommands` chain); the
  per-chunk GPU-completion-target mechanism; and the resolve / stretch-blit /
  copy / optimize encoder commands with their five internal-library shaders.
  The texture-view model — §7.11's "genuinely invasive" item — was done
  **additively** instead: `Texture::fullView` is `static constexpr … = 0` and
  `TextureViewDescriptor` gained an identity-defaulted `swizzle`, so the
  reference's packed `TextureViewKey` was not taken and every d3d11 view is
  unchanged. Presentation needed no conversion, as §7.1 predicted, and that is
  now verified slot by slot. **The §7.5 audit found one real invariant break and
  fixed it:** `Buffer::allocate` created every non-`CpuInvisible` allocation
  with NULL memory and Shared storage — the Metal-allocated path
  `_MTLDevice_newBuffer32` refuses — and that is every d3d9 vertex and index
  buffer, so the first `CreateVertexBuffer` would have failed on a 32-bit
  guest; it now sets `CpuPlaced` under `#ifdef __i386__`, the same shape
  `Texture::allocate` already used. No `[buffer contents]` pointer reaches the
  application anywhere in `src/d3d9`. Open: the remote Metal backend rejects
  the new commands by name (needs `WMTW_OP_*` wire ops in
  `research/remote-metal/`, another component); nothing has run on a device yet.
- 2026-09-11 — D3D9 stages 3 and 5 landed; stage 4 imported but not yet
  compiling (Opus; details in §7.11). Licensing decision received from the
  fork owner: import under LGPL-2.1 §3 → GPL-3.0-or-later, so §7.2 is
  resolved and the notices are written (`research/dxmt/COPYING.LIB`,
  `research/dxmt/LICENSE-MADEIRA.md`, `THIRD-PARTY-NOTICES.md`).
  **Stage 3 done:** the DXSO/FFP airconv path compiles for iOS arm64 with
  only three additions to this fork's airconv (`air::InputPointCoord`,
  `OutputPointSize` in `FunctionOutput`, `AIRBuilder::FPBinOp::pow`) —
  22/22 unix translation units OK. **Stage 5 done:** both dispatch tables are
  now 150 slots (127-144 NULL by design, DXSO at 145-149) and the wow64 table
  has 38 new `_Foo32` variants that convert every embedded pointer with the
  guest-window conversion; `MTLDevice_newBuffer` refuses the Metal-allocated
  path loudly per §7.5. `gen_remote_guard.py` extended first (per-array guard
  set + base→base32 map), both generated headers regenerated. **Stage 4:**
  all 71 `src/d3d9` files imported; 16 of 21 translation units compile as
  i386 PE, 5 fail with 107 errors from 39 distinct `src/dxmt` APIs that
  postdate this fork — inventory in §7.11. The module is behind
  `-Denable_d3d9=true` so the tree keeps building. Also fixed:
  `.xtool/build-dxmt.sh` ran the workspace's stale copy of
  `build/dxmt-ios/build.sh`, so edits to the unix file list were silently
  ignored.
- 2026-09-11 — ELEVENTH DEVICE RUN (IPA 19:22): `window-x86.exe` printed
  `created hwnd` and exited with the expected `status=43` — RegisterClass,
  CreateWindowEx, timer, DestroyWindow, PostQuitMessage, message loop and
  the native→32-bit window-procedure callbacks all work. `painted` never
  printed: every callback's RETURN data pointer (on the 32-bit stack,
  0xc0faec/0xc0fb2c/0xc0fd5c) was read by `wow64win.dll+0x26610/+0x264f0`
  (from `KeUserModeCallback+0x184`) and by native win32u
  `handle_nc_calc_size+0x70` (0xc0fb6c) without `+B`; each AV was delivered
  to the guest and survived. Also `uxtheme.dll` missing for i386. Fix
  assigned (Opus): callback result path (`NtCallbackReturn` ret_ptr,
  wow64win copy-backs, params published as guest), uxtheme. PEB64 repair,
  unixlib bitness log (`[unixlib] … -> 64-bit table` for win32u stub and
  the CPU DLL) and imm32 all confirmed working.
- 2026-09-11 — Callback fault fixed (Opus, `wow64win/user.c` only). The
  RETURN path was already correct (`Wow64KiUserCallbackDispatcher`
  publishes with `host_ptr32`, `wow64_NtCallbackReturn` converts
  `ret_ptr`). Real bug: the INPUT direction — `message_call_32to64` used
  the guest `lparam` ULONG as a host pointer (`(CREATESTRUCT32*)lparam`,
  `(WINDOWPOS32*)lparam`, fall-through to native `NtUserMessageCall`),
  reached via 32-bit `DefWindowProcW` during `WM_NCCREATE`/`WM_NCCALCSIZE`/
  `WM_WINDOWPOSCHANGING`; `handle_nc_calc_size` was the same guest lparam
  reaching native win32u. Fix: `message_lparam_is_ptr()` (84 messages,
  from Wine's own `pack_message` table) and `message_wparam_is_ptr()`
  (3), converting once at function entry (`user.c:3418-3519`); handles
  and opaque values untouched. Latent, not fixed: `NtUserCallNextHookEx`
  forwards lparam raw (needs the hook id; belongs in win32u). i386
  `uxtheme.dll` (241,664 B) and `msimg32.dll` (28,672 B) built/installed.
  BUILD TRAP: `make -C dlls/<x> aarch64-windows/<x>.dll` silently does
  nothing if the DLL exists (stub Makefile, no prerequisites) — use
  `make -j6 dlls/<x>/aarch64-windows/<x>.dll` from `build-macos`.
  Decisions given: D3D9 stages 3–5 started (LGPL §3 basis); checkpoint
  commit started (wine, FEX, top-level; dxmt track excluded until its
  agent lands).
- 2026-09-11 — TWELFTH DEVICE RUN (IPA 19:43): `window-x86.exe` runs
  CLEAN — `created hwnd`, exit `status=43`, no faults at all (the
  message-lparam fix held). Two open items: (1) `painted` never printed —
  no WM_PAINT reached the wndproc though WM_TIMER/WM_DESTROY did, and no
  paint/expose activity in the log (`[win-pos] #5 flags=4000193f` shows
  the window shown with SWP_NOREDRAW); queue/update-region path for a
  WoW thread to be traced. (2) NEW `[rpm-avail] ml607 CORRUPT op=consume
  bad=0x20 class=1 page=0x7c01440000 …` ×16 (identical values) plus
  `RPMALLOC-REPAIR (converged)` — zero in both hello runs — rpmalloc span
  accounting in the CPU module corrupted once user32 traffic starts. Both
  assigned (Opus, one agent, A then B). Commit agent resumed after the
  user set git identity.
- 2026-09-11 — CHECKPOINT COMMITTED (local, not pushed): wine `97f11fd`
  (17 files), FEX `7b51304` (29 files; nested `External/rpmalloc`
  submodule committed first at `45f8676`), top-level `e5bb022` (49
  files). Excluded on purpose: `research/dxmt` pointer, `build/dxmt-ios/*`
  (D3D9 track, to be committed at its checkpoint). Stray untracked
  scratch files at top level to delete before the next commit:
  `FEX-status.tmp`, `diag-static.txt`. Commit procedure: one-off
  `git -c core.autocrlf=true` per command; explicit paths at top level.
- 2026-09-11 — PUSHED to the user's GitHub (never to willfaust/*; no
  PRs). Forks `125hz/{wine,FEX,rpmalloc,dxmt}`; every submodule's
  `origin` now points at the 125hz fork, `upstream` = willfaust
  fetch-only with push URL `DISABLED`. Pushed: wine `ios-build` @
  `97f11fd`, FEX `ios-port-2607` @ `afe2580` (adds `.gitmodules` →
  125hz/rpmalloc), rpmalloc `ios-madeira` @ `45f8676`, dxmt `ios-port` @
  `b4b89f0` (unchanged). Top-level `.gitmodules` now points at the forks;
  `main` @ `09d949e` pushed to `125hz/Madeira`. Scratch files deleted.
  Revert path: `git checkout 09d949e && git submodule update --init` on
  a fresh clone of `125hz/Madeira` reproduces this state.
- 2026-09-11 — D3D9 checkpoint committed+pushed: dxmt `3e8eed5` (96
  files), main `be1066b`. Stage-4 continuation (reconcile §7.11 API
  drift) running.
- 2026-09-11 — Paint + allocator fixed (Opus). (A) `[rpm-avail] ml607
  bad=0x20` was a FALSE POSITIVE: rpmalloc never cleared a page's `prev`
  on head removal/republish, and the census's "repair" then zeroed the
  class's available-list head, orphaning it (the ml614 store-at-0x30
  shape). Fix (`rpmalloc.c` ml623): make the invariant real —
  `page_full_to_available`, `page_available_to_free`,
  `page_available_to_full` clear stale `prev`/`next`, the corrupt branch
  advances instead of zeroing, a full page leaving via thread-free is
  handled explicitly. Generic; affects the 64-bit path too. (B) WM_PAINT:
  the server generates WM_PAINT only from `paint_count`
  (`queue_ios.c:3375`), set by `set_update_region`; both logged
  `[win-pos]` events carried SWP_NOREDRAW and neither had SWP_SHOWWINDOW —
  `ShowWindow` took the "parent not visible" style-toggle branch
  (`window.c:4855`), so no invalidate ever happened, and the iOS driver
  (unlike x11drv/macdrv) has no expose/damage path to compensate. Fix:
  `driver_ios.c:522-553` `winios_drv_window_pos_changed` requests
  `NtUserRedrawWindow(RDW_INVALIDATE|ERASE|FRAME|ALLCHILDREN)` for a
  visible surfaced window on SHOWWINDOW/FRAMECHANGED; hook installed
  unconditionally (`:1626`). Open: why `is_window_visible(parent)` is
  FALSE (`MADEIRA-TEMP [paint-diag]` line will say). wow64win thunks
  verified correct. Test now also does InvalidateRect+UpdateWindow and
  logs `painted-via-updatewindow`/`painted-via-queue`. IPA build started.


- 2026-09-11 — **MILESTONE 1 PASSED (ninth device run).** `hello-x86.exe`
  printed `MADEIRA-X86-32: hello from a 32-bit PE` and exited with
  `MADEIRA-EXIT: hello-x86.exe status=42`; the app reported `Wine exited
  with code 42`. Everything in the chain ran on hardware for the first
  time: FEX 32-bit JIT with the base register, TLS-free hooks, thread
  state in slot 14, BOP page (guest 0x250000, RW), syscalls through
  wow64.dll, native `WriteFile`, `ExitProcess`. The unaligned-access
  backpatcher fired inside the window and worked. Two follow-ups: (a) a
  survivable AV in `wow64.dll+0x1a910` (`ldrb w8,[x22,#4]`, x22 =
  B+1) — a thunk converted the non-pointer value 1 (handle/sentinel) with
  `+B`; guest RIP 0x7bf8d98c (i386 ntdll +0x4d98c) at the time, right
  after `bigfree addr=0x7100000001` (NtFreeVirtualMemory with guest addr
  1) — invariant-4 violation, fix before M2; (b) the app's post-run
  `jit26_detach` BRK fires after StikDebug already detached (app-side,
  pre-existing teardown, not the 32-bit path). Also seen: `Failed to
  mprotect last page of code buffer` (FEX guard on a pool buffer; iOS
  cannot reprotect pool RX; harmless, same as EC). Next: M2 windowed
  32-bit test (i386 user32/gdi32/win32u), D3D9 frontend port for M4,
  commit the work (see line-ending procedure above).
- 2026-09-11 — M2 test ready (Sonnet): `build/x86-tests/window-x86.c`
  (no CRT; RegisterClass/CreateWindowEx 320x240, WM_PAINT TextOut,
  100 ms timer × 20 → DestroyWindow → PostQuitMessage(43) →
  ExitProcess(43); imports only KERNEL32/USER32/GDI32), 10,752 B, shipped
  in `i386-windows/`. i386 DLL closure built/stripped/installed: win32u,
  gdi32, user32, advapi32, sechost, ucrtbase, msvcrt (+ existing ntdll,
  kernel32, kernelbase) — closed set, no api-ms-win-* imports, so no
  i386 apisetschema needed. Button `("32-bit window", "window-x86.exe")`
  at `ContentView.swift:862`. Expected: `MADEIRA-X86-32-WINDOW: created
  hwnd`, `… painted`, `MADEIRA-EXIT: window-x86.exe status=43`. Not
  built into an IPA yet. Tracks running: D3D9 port (Opus, section 7 to
  come), wow64.dll sentinel `+B` fault fix (Opus).
- 2026-09-11 — Sentinel fault fixed (Opus). `wow64.dll+0x1a910` =
  `wow64_NtContinueEx` (`syscall.c:589`): `NtContinue(ctx, BOOLEAN)` and
  `NtContinueEx(ctx, KCONTINUE_ARGUMENT*)` share the thunk and are told
  apart by value (`<= 0xff` = boolean); `get_ptr` had turned TRUE into
  B+1, which passed the test. Guest RIP 0x7bf8d98c = i386 ntdll
  `signal_start_thread` (`signal_i386.c:515-530`, `NtContinue(ctx, 1)` at
  the end of `LdrInitializeThunk`). Fix: discriminate on the raw ULONG,
  convert only real pointers (`syscall.c:571-598`). `[bigfree]` =
  `release_address_space()` (`loader.c:5381`, 32-bit only:
  `NtFreeVirtualMemory(addr=(void*)1)`), whose magic value 1 was
  `+B`-converted; fix: `wow64_NtFreeVirtualMemory` passes values below
  0x10000 through unconverted and skips the CPU notifications
  (`virtual.c:326-352`). Spec-driven audit of every thunk: three more
  handle-as-pointer sites fixed (`wow64win/gdi.c:2278, 2288`,
  `user.c:2487`); nothing else misrouted. Unix side needs no change (a
  bogus base already fails with STATUS_MEMORY_NOT_ALLOCATED; guest 0 is
  never mapped). Note: `NtTestAlert` now runs on the 32-bit path for the
  first time. wow64.dll/wow64win.dll rebuilt and installed. IPA built
  18:52 (also carries the M2 window test).
- 2026-09-11 — D3D9 stage 1 checkpoint (Opus; details in §7). LICENSING:
  the `v0.4-d3d9` tag is LGPL-2.1-or-later (post-v0.80 relicense by the
  DXMT author), not MIT; Madeira's fork branched in the MIT era.
  LGPL-2.1 §3 conversion to GPL-3.0-or-later is permitted and is exactly
  what this repo already did for its Wine fork (README), but it is the
  fork owner's decision — no LGPL source copied yet; stages 3–5 blocked on
  the user's go. Proven: all of DXMT's substrate (`src/util`, `src/dxmt`,
  `src/winemetal`) compiles as i386 PE — new `build/dxmt-ios/build-pe.sh`
  produced i386 `winemetal.dll` 65,536 B, `dxgi.dll` 1,298,432 B,
  `d3d11.dll` 4,870,144 B, `d3d10core.dll` 913,408 B (there was no PE
  build stage for DXMT in this checkout before). DXMT's existing wow64
  table (127 slots) converted embedded pointers with bare zero-extension;
  `UInt32ToPtr` is now `+B` under `TARGET_OS_IOS` (fixes 22 sites); 37
  shared slots still need wow64 variants. `meson.build` `DXMT_IOS` now
  keyed on host OS, not `aarch64`. `.xtool/build-dxmt.sh` now rsyncs the
  tracked dxmt tree (it was silently building HEAD). Cube test
  `build/x86-tests/d3d9-cube-x86.c` built (59,392 B, imports
  KERNEL32/USER32/d3d9, LAA). Found bug: `load_builtin_unixlib`
  (`virtual_ios.c:~6167`) ignores `wow` in the iOS static-table fallback
  → 32-bit callers get the 64-bit unixlib table (fix assigned, Opus).
  Needed app line: `("D3D9 cube", "d3d9-cube-x86.exe")` in
  `thirtyTwoBitTests`.
- 2026-09-11 — TENTH DEVICE RUN (IPA 18:52): `hello-x86.exe` passes again
  cleanly (no AV before the hello; `NtContinue`/`NtTestAlert` path OK).
  `window-x86.exe`: whole i386 set loaded (user32 0x717bc00000 … win32u
  0x717b910000); first fault in native win32u — `NtUserInitializeClientPfnArrays`
  → `init_user` → `gdi_init` → `font_init` → `RtlInitCodePageTable(0x350000)`:
  the 64-bit PEB's code-page-table pointer holds a GUEST address (identity
  assumption in PEB NLS setup; must be host in PEB64, guest in wow_peb).
  Fallout: AV delivered to the guest, `GetStockObject` assertion (`brk #1`),
  STATUS_ILLEGAL_INSTRUCTION undispatchable (`call_seh_handlers invalid
  frame` — frame on the kernel stack, outside the native stack limits),
  exit 0xC0000026. Also `imm32.dll` missing for i386 (user32 delay-load).
  Fix assigned (Opus): PEB64/wow_peb NLS pointers + audit of every
  PEB64/TEB64 field for the same assumption; report on the kernel-stack
  frame check; build i386 imm32. Running concurrently: unixlib wow table
  fix (Opus).
- 2026-09-11 — Unixlib table fix landed (Opus, `virtual_ios.c`). Path:
  32-bit `__wine_init_unix_call` → `NtQueryVirtualMemory(MemoryWineLoadUnixLib)`
  → wow64.dll rewrites to `MemoryWineLoadUnixLibWow64` (`virtual.c:753`)
  → `load_builtin_unixlib(module, wow=TRUE)`; bitness decided once at load
  (FEX forwards the handle verbatim, `Module.cpp:730`). ntdll's own table
  was already correct (`load_ntdll_wow64_functions` writes
  `unix_call_wow64_funcs` directly, `loader_ios.c:2257`). Static-table
  fallback (`virtual_ios.c:6147-6239`) ignored `wow` for every other lib —
  now `ios_bind_unixlib_table()` (`:6146-6173`) picks by bitness, refuses
  with `STATUS_NOT_SUPPORTED` + `ERR` when a lib has no wow64 table, logs
  `[unixlib] <lib> -> 64-bit|wow64 table`. Status per lib: ntdll, ws2_32,
  bcrypt, secur32, crypt32 = wow64 table + `+B` done; winemetal = table,
  only 9 SM50 slots converted (37 shared slots pending, §7); dwrite = HAS a
  wow64 table (upstream `freetype.c:1026`, via `#include`) but no `+B`
  pass (CORRECTS the earlier "no table" note); audio_null_ios and nsi =
  no wow64 table at all (32-bit audio driver / in-process NSI unusable
  until added). BUILD NOTE: the shipped `libdxmt_combined.a` predates the
  stage-1 winemetal edit and lacks `dxmt_winemetal_unix_call_wow64_funcs`,
  which `libntdll_unix.a` now references → run `wsl bash
  .xtool/build-dxmt.sh` before the next `build.sh` or the app link fails.
- 2026-09-11 — PEB64 NLS fix landed (Opus). Root cause: the three NLS
  pointers are set by the GUEST's own ntdll, `locale_init`
  (`wine/dlls/ntdll/locale.c:167-180`): `NtCurrentTeb()->Peb->X = ptr`
  (= wow_peb, guest, correct) **and** `peb64->X = PtrToUlong( ptr )` — the
  classic WoW64 identity, which zero-extends the guest value into a PEB64
  field the native side dereferences. `get_peb64()` (`locale.c:91`) reaches
  the real PEB64 because `teb64->Peb` truncated to 32 bits IS its guest
  address (B is 4 GB-aligned), so the guest writes the genuine 64-bit PEB.
  The NLS view itself is correctly inside the window (guest 0x350000).
  `init_peb` (`env_ios.c:1993-2044`) was already correct; nothing on the
  unix side wrote these fields. Fix (wine/** is read-only, so unix-side):
  `ios_wow_fixup_peb64_ptrs()` (`env_ios.c:2538`, declared `ios_wow.h:76`)
  converts any non-zero sub-4 GB PEB64 pointer to `B + v` — an EXACT test,
  not a heuristic, since __PAGEZERO forbids any host mapping below 4 GB.
  Called from `NtGetNlsSectionPtr` (`env_ios.c:2615`) and from
  `init_user()` before `gdi_init()` (`win32u-unix/class_ios.c:319`).
  Belt-and-braces at the dereference itself: `RtlInitCodePageTable`
  (`env_ios.c:2718`) converts a guest table pointer and logs
  `[nls-guestptr]`, covering every native NLS consumer. Audit of all other
  PEB64/TEB64 fields: the only other guest-side PEB64 writes in the tree
  are OS-version scalars (`loader.c:5358-5361`) and `GdiSharedHandleTable`
  in an `#ifndef _WIN64` branch that this build never compiles; TEB64 is
  clean (`virtual_ios.c:13016-13034` host, `:12985-12995` guest, the
  `#else` block at `:13000-13014` is dead on iOS). Two genuine finds, same
  class, opposite direction (host pointer published AS a guest address):
  `wow_peb->ApiSetMap = PtrToUlong(map)` (was `loader_ios.c:2604`, now
  `:2603-2615`) — the view
  is not in the window, so a truncated host pointer was published; now
  gated on `ios_wow_in_window()`, else 0 (= APISET_NOT_PRESENT, which is
  the truth: it is the 64-bit `pe_dir`'s schema anyway); and
  `wow_peb->SpareUlongs[0] = PtrToUlong( ldt_copy )`
  (`virtual_ios.c:13305`, iOS branch at `:13296` drops the `limit_4g`
  ceiling so `ldt_copy` is outside the window) — left alone, 16-bit-only
  consumer (`krnl386.exe16/selector.c:45`), noted for M3. Also correct only
  by construction and worth remembering: win32u's `gdi_shared` reaches
  32-bit gdi32 as `PtrToUlong(peb64->GdiSharedHandleTable)`
  (`gdi32/objects.c:74`), which works solely because
  `zero_bits = HighestUserAddress|0x7fffffff` (`win32u/syscall.c:179`) puts
  it in the window and B is 4 GB-aligned. Dispatch finding: a native trap
  inside a syscall must become a failing syscall status, never a user-mode
  exception — `is_valid_frame` (`ntdll_misc.h:64`) must NOT learn the
  kernel stack. `ill_handler` now calls `handle_syscall_fault()` before
  `setup_exception` (`signal_arm64_ios.c:8966`), mirroring `segv_handler`
  (`:8740`); upstream arm64 only does it for SIGSEGV
  (`wine/dlls/ntdll/unix/signal_arm64.c:1075`) because unix code never
  `brk`s there. `bus_handler` (`:9241`) and `trap_handler` (`:10146`) still
  lack it, as does the Mach delivery path
  (`ios_mach_deliver_guest_exception_inner`, `:6173-6205`, delivers
  best-effort with no is-inside-syscall test). i386 `imm32.dll` built and
  installed (167,936 B stripped from 368,640 B, Machine 0x14C,
  SizeOfImage 0x1B000); static imports are all in the shipped set
  (ntdll, kernel32, kernelbase, user32, gdi32, win32u, advapi32,
  ucrtbase); ole32 is DELAY-only (`CoInitializeEx`,
  `CoRegisterInitializeSpy`) so no ole32 closure needed. Builds clean:
  ntdll-unix 30/0, win32u-unix 46/0, wineserver OK, no new warnings.


- 2026-09-11 — FIRST DEVICE RUN of `hello-x86.exe`. Reached process
  bring-up; died in one allocation. Worked on device: i386 machine
  detection, `syswow64` farm, `argv[1]=C:\windows\syswow64\hello-x86.exe`,
  window reserved (TEB 0x71fffe0000, PEB 0x71ffff0000, B≈0x7100000000),
  TSD probe, i386 image map+relocate (`virtual_map_module=0x40000003
  Machine=0x14c`), `.text` copied executable into the JIT pool, wineserver
  `init_first_thread`/version-930 handshake. Died at
  `build_wow64_parameters` (`env_ios.c:1920` assert `!status`): its
  `NtAllocateVirtualMemory` for the 0x2000 params block searched the
  UNTRANSLATED guest low range (va-scan `0x10000..0x80000000`) instead of
  `[B, B+2G)`, so iOS refused it (nothing below 4 GB) → STATUS_NO_MEMORY.
  I.e. this one allocation missed `ios_wow_translate_limits` while TEB/stack
  did not. Also to verify: init-peb logged `module=0x158740000` (~5.5 GB,
  not in the window) — check whether the i386 image is actually in the
  window or that is a stale log value. Fix assigned to the Wine agent.
- 2026-09-11 — Build agent: `.xtool/build-fex.sh` now has a reproducible
  `xtajit.dll` stage (rsync the tracked FEX tree to Linux storage, run the
  parametrized `fex-host-guards.py` — a no-op for this build, both guards
  already in tracked source — configure the WOW64 cmake, `--target
  wow64fex`, strip, install). Verified twice: 4,669,440 B stripped,
  Machine 0xAA64, 24 exports. IPA rebuilt with the full payload
  (sha256 f352f0e8…) but this IPA PREDATES the params-allocation fix — do
  not re-test with it. Line-ending diagnosis: no Windows git present; per
  repo, commit with one-off `git -c core.autocrlf=true add/commit` so only
  real changes land (real-change lists verified to match
  `--ignore-cr-at-eol`: FEX 29 files, wine 17, top-level ~14, dxmt 0 text
  changes — its 2 dirty entries are submodule gitlinks, handle separately).
  Do NOT set `core.autocrlf` globally.
- 2026-09-11 — Root cause of the device failure (Opus): `hello-x86.exe` is
  the MAIN Wine process (`WineProcessBridge.m:946` → `__wine_main` →
  `start_main_thread`), and the window was only reserved on the
  `wine_ios_child_main` path. So `ios_wow_base()` was 0 for the whole boot:
  the chokepoint translated nothing, the TEB at 0x71xx was ordinary
  top-down furniture, and the image at 0x158740000 was a kernel pick (same
  cause, not a second bug). The earlier "no window path for an i386
  initial process is not needed" assumption was wrong. Fix: app publishes
  `ios_main_image_i386` (`WineProcessBridge.m:1014`, flag declared
  `virtual_ios.c:5415`, `ios_wow.h:43`) since only the app knows the main
  image arch before startup info is read; `start_main_thread` reserves the
  window before `virtual_alloc_first_teb` and binds it to the PEB right
  after (`loader_ios.c:2679, 2697`); `virtual_alloc_first_teb` passes a
  guest 4 GB ceiling when a window exists (`virtual_ios.c:12794`) so the
  first TEB/PEB go through the same chokepoint. 64-bit path unchanged.
  One-shot gated trace `[wow-params] … base=… in_window=…` at
  `env_ios.c:1928` for the next run. Native archives rebuilt clean; IPA
  rebuilt 02:21.
- 2026-09-11 — SECOND DEVICE RUN (two identical logs): `[wow-window]
  main-process reserve FAILED 0xc0000017`, then windowless boot to the same
  assert (`[wow-params] base=0x0`). Cause: `[cage] holdback reserved
  0x7200000000+0x1ffff0000` (pre-existing, rev=ml433) runs first and takes
  the 0x7200000000 slot; 0x7000000000 holds the JIT RW alias; the only
  candidate 0x7100000000 is exactly 4 GB free, and the FB3 guard page makes
  the reservation 4 GB + 16 KB, overlapping the holdback by one page. Fix in
  progress: accept an already-inaccessible neighbor (PROT_NONE region) as
  the guard when the extra page cannot be mapped; fail the 32-bit main
  process cleanly instead of booting windowless.
- 2026-09-11 — Guard fix landed (Opus). `virtual_ios.c`: per-slot
  `guard_owned` (`:5393`); `ios_wow_window_try` (`:5592`) tries 4 GB + guard,
  else reserves exactly 4 GB only if `mach_vm_region` proves the page at
  `B+4G` is inside an existing `VM_PROT_NONE` region (`:5576`, a hole or
  accessible memory rejects the candidate); pick bound is now
  `cand + 4G <= ceil` (`:5632`); exclusion/retire use the per-slot
  reservation size. `loader_ios.c:2680-2697`: main-process reserve failure
  now calls `fatal_error()` (`pthread_exit` of this pseudo-process only).
  Expected on device: 0x7100000000 accepted with `guard=borrowed` from the
  holdback's PROT_NONE region. Holdback is reserved at the end of
  `virtual_init` (`virtual_ios.c:12394`, `MAP_FIXED`, 8 GB-aligned by
  design); reordering not recommended (MAP_FIXED would silently clobber the
  guard page). Child path already fails cleanly (`loader_ios.c:3190`).
  Build clean, 0 new warnings. IPA rebuilt 02:45.
- 2026-09-11 — THIRD DEVICE RUN: window reserved (`guard=borrowed`) and
  bound at B=0x7100000000; app no longer crashes. New failure:
  `virtual_map_module = 0xc000000d Machine=0x14c` — the i386 main image
  cannot be mapped into the window (suspected: `load_main_exe` runs before
  `init_peb`, so `user_space_wow_limit` is still 0 when `map_image_view`'s
  wow branch computes its range). Loader then fell back to `start.exe`
  (64-bit) in the same pseudo-process, which kept the only window slot;
  its `NtCreateUserProcess` of the exe hit `guest window reserve FAILED`
  and the child exited cleanly. Also observed: first TEB/PEB at guest
  0xFFFE0000/0xFFFF0000 although the image is not large-address-aware
  (chars 0x102) — first TEB must use a 2 GB ceiling as upstream does.
  Fixes assigned (Opus): publish the 32-bit ceiling from the image's LAA
  bit before mapping; 2 GB first-TEB ceiling; no `start.exe` fallback
  for a valid i386 PE that failed to map (fail cleanly), or release the
  window before a genuine non-PE fallback.
- 2026-09-11 — Fix landed (Opus). Confirmed: `map_view`'s range check
  (`virtual_ios.c:10175`, `limit_low >= limit_high`) fired because the wow
  branch used `B + get_wow_user_space_limit()` with the limit still 0
  before `init_peb`. New `ios_wow_image_ceiling()` (`:5544-5602`) derives
  the ceiling from the image's LAA bit and PUBLISHES `user_space_wow_limit`
  for the main image before mapping; `map_image_view` uses it (`:12103`).
  First TEB ceiling `limit_2g-1` (`:12991`); `virtual_alloc_teb` and
  32-bit stack fallbacks likewise (`:13070`, `thread_ios.c:1428`). New
  `IOS_WOW_GUEST_FLOOR` 0x110000 applied inside the window
  (`:5517-5546`) — a bottom-up pick could otherwise return host B = guest
  0 = NULL. `env_ios.c:2181-2229`: a 32-bit main image that fails to map
  now fails the pseudo-process (`ios_fatal_startup_error`, pthread_exit)
  instead of falling back to `start.exe`; genuine non-PE fallbacks retire
  the window (leaked by design; the single slot cannot be reused). Expected
  guest layout for a non-LAA image: image 0x400000, params 0x110000,
  stack ≈0x420000, TEB64 0x7FFE0000, PEB 0x7FFF0000. Build clean; IPA
  rebuilt 03:14.
- 2026-09-11 — FOURTH DEVICE RUN: the whole Wine side of bring-up now
  works. Window bound; TEB/PEB at 0x717ffe0000/0x717fff0000 (guest
  0x7FFE0000/0x7FFF0000); main image at guest 0x400000; `[wow-params]
  status=0x0 … in_window=1`; i386 ntdll at 0x717bf40000; wow64.dll,
  wow64win.dll, win32u, ucrtbase, KERNEL32, kernelbase loaded;
  `load_cpu_dll` fell back to `xtajit.dll` (libwow64fex.dll at
  0x70ffb10000). Failure moved into FEX process init: the ntdll "band"
  probe that hands FEX its host arena (`ml706`) failed both candidates
  (`0x7c00000000 PROBE-FAIL`, `0xc00000000 PROBE-FAIL`, `NO BAND`), then
  `ml755 FATAL: no FEX arena` and the predicted null store at
  `libwow64fex.dll+0x137d2c` (addr 0x7f0). The same band was `MAPPABLE` at
  session start, so this is a WoW-process gap in the arena handshake
  (candidates: probe args translated into the guest window, window
  exclusion, or the WoW64 module not performing the EC module's
  handshake). Fix assigned (Opus, ntdll-unix + FEX/Source/Windows).
- 2026-09-11 — Fix landed (Opus). Root cause: `get_extended_params`
  (`virtual_ios.c:15553`) used session-wide `is_wow64()` to pick the
  ceiling for `MEM_ADDRESS_REQUIREMENTS`, so rpmalloc's band probe
  (`FEX/External/rpmalloc/rpmalloc.c:917` `ios_fex_band_select`,
  `VirtualAlloc2` Lowest=0x7c00000000) was rejected with
  STATUS_INVALID_PARAMETER against the 2 GB guest ceiling before any
  placement. There is no arena handshake in the EC module; it works only
  because a 64-bit process has no `wow_peb`. Fix: three-way discrimination
  keyed on the process's own window (guest ceiling iff a window exists and
  Highest < 4 GB, else host ceiling), upstream line kept for non-iOS;
  evidence line `[wow-hostreq]`. Module: `[wow-base] class 1010 -> …`
  log; flush the selector log and `ERROR_AND_DIE` naming the missing arena
  before `CreateNewContext`. rpmalloc: ml755 text made width-agnostic; a
  latent 1-byte overflow (`buf[224]` for 225 bytes) fixed. Verified
  correct: `ios_wow_translate_limits` leaves host requests alone,
  `ios_wow_exclude_windows` cannot reject the band, `GetWowTEB` and the BOP
  page path. Follow-up (FEXCore, not done): `AllocatorHooks.h:69` gates
  band steering on `ARCHITECTURE_arm64ec`, so WoW64-module host
  allocations use plain `VirtualAlloc(MEM_TOP_DOWN)` and land above the
  window; should be `|| FEX_IOS_HOST`. Cosmetic: the iOS FEXCore stage
  builds from the HEAD export, so `xtajit64.dll`/`libFEXCore_Base.a` still
  carry the old ml755 string. Builds clean; `xtajit.dll` rebuilt; IPA
  rebuilt 03:41.
- 2026-09-11 — FIFTH DEVICE RUN: band fix confirmed (`[wow-hostreq]`
  host ceiling, `ml706 cand0 PROBE-OK`, later `SELECTED`, arena pages
  committed at 0x7c00000000/0x7c01000000). New fault chain: (#1) unix
  `NtAllocateVirtualMemoryEx+0x3ec` (`ldr x9,[x29,x27]`) read exactly
  0x7038120000 — the top of the thread's kernel stack / start of the native
  stack's guard — with sp=0x703811fb90, right after the `[bigres]`
  caller-scan lines for rpmalloc's 256 MB reserve; suspected unbounded
  sp-relative diagnostic walk, exposed because F1 shrank the
  `WOW64_CPURESERVED` carve at the kernel-stack top for i386 threads so the
  syscall frame now sits ~0x470 from the top. (#3) the exception was
  delivered best-effort into `libwow64fex.dll+0xff9b0` before FEX thread
  state existed → NULL+0x40. (#5) `hlt #1` trap at
  `libwow64fex.dll+0x10220c` with no message; `[wow-base]`/`ml787` lines
  never appeared, so the trap precedes them or the message path does not
  reach the log. Fix assigned (Opus): bound all sp-relative diagnostic
  scans by the real stack region; module handler returns not-handled
  without thread state; fatal messages via a path that reaches the log.
- 2026-09-11 — Fix landed (Opus). Root cause of #1 confirmed: the
  `[bigres]` walkers in `NtAllocateVirtualMemory` (`virtual_ios.c:14925`)
  and `NtAllocateVirtualMemoryEx` (`:16232`) read 1024 raw slots upward
  from `__builtin_frame_address(0)` with no bound; `f87b7ba9` = `ldr x9,
  [x29, x27, lsl #3]`. Latent all along (read unrelated mappings); faulted
  now only because the neighbour was the 8 MB stack's guard. F1 was NOT
  involved: the CPU area is carved from a separate 256 KB 64-bit PE stack
  (`thread_ios.c:1406`), and the 0x470 gap (0x330 syscall frame + 0x140
  frames) is structural. Fix: `ios_stack_scan_end()` (`:2787-2851`,
  kernel-stack range → PE stack → `mach_vm_region` readable region) bounds
  both walkers, all slot reads via `ios_safe_read64`. #3:
  `BTCpuResetToConsistentStateImpl+0x68` dereferenced a NULL FEX
  ThreadState (`FEXCORE_PROFILE_ACCUMULATION`); guards added
  (`Module.cpp:1183-1217`, returns not-handled; general null guard belongs
  in FEXCore `Profiler.h`, not done). #5: `ForcedAssert` from
  `BTCpuProcessInit+0xae4` = `ntdll!ios_teb_tsd_offset missing or zero`
  (`Module.cpp:682`), silent because it precedes `Logging::Init()`. Now:
  `Logging::RawWrite` (`__wine_dbg_output`, usable before Init),
  `IosRawReport`/`IOS_WOW64_REPORT_AND_DIE` at all four fatal sites, TSD
  import reported unconditionally, `[wow-base]`/`ml787` via the raw path.
  Open: whether `ios_teb_tsd_offset` is published into the plain aarch64
  ntdll for a 32-bit MAIN process (`loader_ios.c:2029` session publish,
  `:2395` ec-child publish; the i386 child path `:3405-3453` does not
  re-publish it) — being checked before the next IPA. Builds clean;
  `xtajit.dll` 4,673,536 B, 24 exports.
- 2026-09-11 — Resolved from code + binaries: the shipped
  `aarch64-windows/ntdll.dll` is a stale prebuilt (PE timestamp
  2026-08-02, SizeOfImage 0xF0000, export tail 1450 dispatcher / 1451
  `p_ios_jit_reverse_translate_addr` / 1452 `__wine_unixlib_handle`) and
  does NOT export `ios_teb_tsd_offset`; `ntdll.spec:1757` declares it
  with no arch filter (arm64ec 1460 and i386 1475 have it). The session
  publish (`loader_ios.c:1987`/`:2522`) is already arch-agnostic and
  writes the right module; `find_named_export` just returns NULL. New
  explicit diagnostic `[teb-tsd] FATAL-FOR-WOW64: native ntdll … does NOT
  export ios_teb_tsd_offset` (`loader_ios.c:2027-2055`). No plain-aarch64
  PE build stage existed in this checkout (only build-macos/i386/arm64ec);
  Sonnet is rebuilding `aarch64-windows/ntdll.dll` from the current tree
  in `wine/build-macos` and rebuilding the IPA.
- 2026-09-11 — `aarch64-windows/ntdll.dll` rebuilt from the current tree
  (`make -C dlls/ntdll aarch64-windows/ntdll.dll` in `wine/build-macos`),
  stripped: 1,245,184 → 1,310,720 B, SizeOfImage 0xF0000 → 0x100000;
  export diff vs stale: none removed, only `ios_teb_tsd_offset` added
  (ordinal 1452 between `p_ios_jit_reverse_translate_addr` and
  `__wine_unixlib_handle`). Workspace already had all 17 wine edits
  synced. IPA rebuilt 04:23 with the new ntdll, `xtajit.dll` 4,673,536 B,
  wow64/wow64win, i386 set, `hello-x86.exe`.
- 2026-09-11 — SIXTH DEVICE RUN: FEX process init completes. `[teb-tsd]
  published`, `[wow64-init] found=1 value=0x8d0`, `[wow-base] B=
  0x7100000000`, `ml787 FEX host arena = [0x7c00000000, …]`. Crash is the
  FIRST JIT EMIT: `str w8,[x9,x10]` at `libwow64fex.dll+0x97450` with
  w8=0xa9bf53f3 (`stp x19,x20,[sp,#-16]!`), x9=0x70ff6b0000 (a plain 16 KB
  furniture allocation), x10=0x6ee3888000 (= pool RX→RW write offset) →
  unmapped 0xdfe2f38000. Cause: the WoW64 build's code buffers come from
  plain `VirtualAlloc` because FEXCore's iOS pool/alias steering is gated
  on `ARCHITECTURE_arm64ec` (`AllocatorHooks.h:69`, the follow-up noted
  earlier), yet the pool write offset is still applied. Secondary: the
  handler dereferenced `TlsSlots[16]` = 2 (non-NULL non-pointer). Fix
  assigned (Opus, FEX/** incl. FEXCore + ntdll-unix): gate on the iOS host
  build, code buffers from the pool via the same alias mechanism as EC,
  slot robustness, x18-free handler.
- 2026-09-11 — Fix landed (Opus). `AllocatorHooks.h:69` gate is now
  `ARCHITECTURE_arm64ec || FEX_IOS_HOST`, so WoW64 exec allocations go
  `VirtualAlloc2(EC_CODE attr)` → `NtAllocateVirtualMemoryEx` → JIT-pool
  tail carve (`virtual_ios.c:15992`) returning pool RX; the write offset
  (already `FEX_IOS_HOST`-gated at `JIT.cpp:1310`, `Dispatcher.cpp:53`)
  then yields pool RW. New invariant check refuses any Execute allocation
  outside `[ios_fex_jit_pool_rx, _end)` (`AllocatorHooks.h:149-175`,
  globals in `rpmalloc.c:862`, published by both modules from
  `WINE_IOS_JIT_RX/SIZE`). Second latent blocker fixed: FEX CRT
  `VirtualAlloc2` (`Common/WinAPI/Alloc.cpp:78-94`) always injected an
  address-requirements parameter, and `get_extended_params` rejects
  duplicates — would have broken `CallRetStack` allocation at thread init.
  `IosJitAlias`/push-aliases stay EC-only (they map native EC PE code to
  pool copies; WoW64 tracks only guest ranges). TLS slot 16 verified
  unused by Wine/Madeira (`TlsBitmap` reserves 0..18); handler now treats
  values < 0x10000 as uninitialised; `[wow64-tls]` line per thread.
  `Logging::RawWrite` no longer dereferences a null TEB. The app's
  `libFEXCore*.a` does not need the change (no `FEX_IOS_HOST`/`_WIN32`).
  `xtajit.dll` 4,677,632 B, 24 exports. Pending before IPA: the BOP page
  requests PAGE_EXECUTE_READWRITE inside the window, which iOS would
  carve from the pool → make it PAGE_READWRITE under `FEX_IOS_HOST`.
- 2026-09-11 — BOP page closed (Opus). Traced: a `PAGE_EXECUTE_READWRITE`
  `NtAllocateVirtualMemory` with a sub-4G ceiling in a WoW process lands
  in the window, then `mprotect_exec` (`virtual_ios.c:8071`) sees EXEC
  not granted, runs a 64 MB backward MZ scan, and takes the anonymous-RWX
  path (`:8527`): carves a 16 KiB pool slot, copies the page, `vm_remap`s
  pool RX over the window VA as R+X (`:8694-8715`) — a silent invariant-7
  violation with the trampoline write routed through the STR-fault
  emulator. Fix: `BopProt = PAGE_READWRITE` under `FEX_IOS_HOST`
  (`Module.cpp:948-952`); `HandleMemoryProtectionNotification(…,
  PAGE_EXECUTE)` kept so the range is in `XIntervals`;
  `QueryExecutableRange` answers from intervals only (never host
  protection); the constructor's `VirtualQuery` sweep runs before the
  allocation. No consumer inspects the page protection (wow64.dll stores
  the value verbatim; `map_wow64cpu` is the native-i386 branch). No other
  non-code-buffer exec requests in the module. `[wow-bop]` log line.
  `xtajit.dll` 4,677,632 B, 24 exports. IPA rebuilt 17:16.
- 2026-09-11 — SEVENTH DEVICE RUN: pool routing works. `fast-write
  enabled (WriteOffset=0x6edf888000 …)`, `exec allocations restricted to
  RX [0x120778000, 0x158778000)`, dispatcher carved from the pool tail
  (`[disp-addrs] dispatcher=[0x158774000, …)`), SMC interval added, main
  image registered at HOST 0x7100400000. Crash: `BTCpuProcessInit` →
  module `HandleImageMap` → `InvalidationTracker::HandleImageMap` →
  native `RtlImageNtHeader(0x7bf40000)` (`ntdll.dll+0x43f10`, `ldrh` of
  `e_magic`) — the module registered the i386 ntdll by its GUEST base
  from `LdrSystemDllInitBlock.ntdll_handle` (published guest by design,
  `loader_ios.c:2212`) without `+B`. Fix assigned (Opus, FEX/Source/
  Windows): `ToHost` at that boundary + audit of every externally supplied
  address (BTCpuNotify* args, PEB32/TEB32, init block, contexts).
- 2026-09-11 — Fix landed (Opus, `WOW64/Module.cpp` only). `:972-981`
  converts `LdrSystemDllInitBlock.ntdll_handle` with `GuestWindow::ToHost`
  before `HandleImageMap` (skips if 0); `[wow-image]` log line. Audit
  table (with Wine-side evidence lines) confirms every `BTCpuNotify*`
  argument, `PEB->ImageBaseAddress`, `WOW64INFO`, `TebBaseAddress`,
  contexts, `ExceptionInformation[1]` are HOST; only `ntdll_handle` and
  the `p*` entries are GUEST (the module never reads `p*`);
  `BTCpuNotifyProcessExecuteFlagsChange` is never called by this Wine
  tree. Contract comments added at each call site. Image naming: fallback
  to the PE export-directory name (bounds-checked) because wineserver does
  not know i386 modules; `HandleImageMap` now returns with `[wow-image] no
  PE header …` instead of letting the tracker dereference NULL.
  `xtajit.dll` 4,677,632 B, 24 exports. IPA rebuilt 17:37.
- 2026-09-11 — EIGHTH DEVICE RUN: reached the FIRST BLOCK COMPILE.
  i386 ntdll registered at host 0x717bf40000; BOP page guest 0x250000
  (RW); thread init complete (ThreadState 0x7c02001000, lookup cache,
  decoder, passmanager, JIT core buffer `FEXMemJIT` 0x155d20000 from the
  pool, CallRet stacks); `GenerateIR` called for guest RIP 0x7bf8e370
  (i386 ntdll `LdrInitializeThunk`). Crash: `GenerateIR` →
  `FEX_MadeiraIRCapClear` (`libwow64fex.dll+0xe5a70`) loads a NULL global
  and indexes it (`ldr x8,[x9,x8]`, x9=0) — a Madeira iOS IR-capture
  diagnostic whose state the WoW64 build never initialises. Also noted:
  `TlsSlots[16]` held 0x2 before the module claimed it. Fix assigned
  (Opus, FEX/**): null-safe hooks + parity init, audit of every Madeira/iOS
  hook FEXCore calls (EC-only vs Common), slot-16 writer.
- 2026-09-11 — Fix landed (Opus, FEX/** only). Root cause was NOT an
  uninitialised diagnostic: `IRCapRIP` was `thread_local`
  (`PassManager.cpp:220`) and the faulting instructions are the compiler's
  native-Windows TLS sequence — `ldr x9,[x18,#0x58]`
  (TEB->ThreadLocalStoragePointer) then `ldr x8,[x9,x8,lsl#3]`. NATIVE TLS IS
  PERMANENTLY UNAVAILABLE TO A CPU MODULE: Wine's loader enters it from
  `init_wow64()` (`wine/dlls/ntdll/loader.c:5518` initial thread, `:5585`
  every other) and that call never returns to the `alloc_thread_tls()` at
  `:5608`/`:5644`, so `ThreadLocalStoragePointer` is NULL for the whole life
  of every thread in a WoW64 process — and the sequence reads the TEB through
  x18, which iOS wipes (the reason for `WOW64/IosTeb.h`). This is upstream
  FEX's "banned in xtajit64" rule (`Core.cpp:1077`) with its mechanism named.
  Binary audit of the module found THREE `.tls` variables, not one:
  `IRCapRIP`, `AllocWatch::CurrentThreadId()::Anchor` (`AllocWatch.cpp:58`) —
  reached from `AllocWatch::Clear()`, which
  `RedundantFlagCalculationElimination.cpp:1018` calls on EVERY block compile,
  i.e. the guaranteed next crash — and libc++abi's
  `__cxa_get_globals()::eh_globals`. Fixes: `IRCapRIP` is a process-global
  `std::atomic<uint64_t>` and all three `FEX_MadeiraIRCap*` hooks return early
  when `FEX_MadeiraIRCapTarget == 0` (`PassManager.cpp:216-247, 444-467`);
  `CurrentThreadId()` reads `TPIDRRO_EL0` under
  `FEX_IOS_HOST && _WIN32 && __aarch64__` (`AllocWatch.cpp:55-84`). Verified
  in the PE: the three hooks are now plain `.data` accesses with no x18 and no
  TLS, `.tls` 0x30 → 0x20, and the only remaining `[x18,#0x58]` reads are
  `__cxa_get_globals`/`__cxa_get_globals_fast` (throw/catch only).
  TlsSlots[16] IS OWNED: it is Wine ntdll's `_errno()` cell
  (`wine/dlls/ntdll/ntdll_misc.h:36` `NTDLL_TLS_ERRNO 16`,
  `wine/dlls/ntdll/thread.c:445`, reserved `loader.c:5501`) and the 0x2 was
  ENOENT — a mutual corruption, not stale TEB content. ThreadState moved to
  slot 14 (`WOW64_TLS_MAX_NUMBER - 5`, `WOW64/Module.cpp:186-192`): 14 and 15
  are unassigned by Windows' WoW64 layout (which defines 1..13) and written
  nowhere in this Wine tree (only 1, 3, 5, 7, 8, 10 by wow64.dll/ntdll/win32u
  and 16 by errno), and both are inside the range `loader.c:5500` reserves, so
  TlsAlloc cannot hand them out either. Hook audit: every
  `FEX_Madeira*`/`Ios*`/`ios_fex_*` symbol FEXCore references is satisfied in
  this link (the PE imports only ntdll/wow64/UCRT apisets) —
  `IosCbEntryLog`/`IosFfsBypassLog`/`IosJitReverseTranslate` have non-EC
  stand-ins at `Core.cpp:1290-1303`, the whole mono-bridge set is provided by
  `WOW64/IosMonoBridge.cpp`, `IosSweep*`/`IosMaybeSweepCodeBuffers` live in
  FEXCore and run against an empty registry here, and `AllocWatch.cpp` IS
  linked (so it was never unreachable). One parity gap closed: FEXCore's
  C-linkage `IosTebTsdOffset` (`Arm64Emitter.cpp:29`, read by the emitters
  only under `ARCHITECTURE_arm64ec`) was never written in this build while the
  module set only its own namespaced copy — `BTCpuProcessInit` now publishes
  both (`WOW64/Module.cpp:92-104`, `:844`). `xtajit.dll` 4,677,632 B, Machine
  0xAA64, 24 exports; build clean (one pre-existing `unused function
  'EventName'` warning in AllocWatch.cpp, ml621 left it behind). Open, for the
  Wine agent: calling `alloc_thread_tls()` before `init_wow64()` would also
  make libc++abi's EH TLS safe; and ~37 `mov x8,x18` plus `[x18,#0x68]`
  (LastError) / `[x18,#0x60]` (PEB) sites remain in CRT/rpmalloc/logging code,
  which the x18 emulator only rescues while the base register is literally
  x18.
- 2026-09-11 — SECOND device run: main-path window reserve now ATTEMPTED
  (fix working) but FAILS `0xc0000017` (`[wow-window] main-process reserve
  FAILED`), so base=0 and the same params assert. Cause: the FB3 guard page
  has no room. At reserve time: JIT pool [0x7000000000,0x7038000000), free
  [0x7038000000,0x7200000000), cage holdback (ml433) [0x7200000000,
  0x73ffff0000) PROT_NONE. Only 4 GB-aligned base is 0x7100000000; the 4 GB
  window fits exactly abutting the cage, but the guard page at 0x7200000000
  collides with the cage. Fix: treat an already-inaccessible neighbour
  (existing PROT_NONE reservation like the cage) as satisfying the overrun
  guard instead of always owning a guard page; reserve exactly 4 GB, verify
  the page above is inaccessible (own it only if free), keep 4 GB alignment.
  Assigned to the Wine agent. IPA (02:21) still predates this fix — do not
  re-test until rebuilt.


- 2026-09-10 — Inspection complete (Opus, read-only). Segment-base hypothesis
  rejected; explicit base register selected. BoxedVN inspected (Sonnet): it
  uses Boxedwine's soft MMU (per-page host pages, 5–7 instructions per access),
  not a flat window, so it does not demonstrate a contiguous guest window;
  reusable ideas only (StikDebug dual-map handshake, arena sizing,
  probe-before-execute), no code. Toolchain check: `.xtool/toolchains/llvm-mingw`
  has i686, x86_64, aarch64, arm64ec targets. Wave 1 started: stages A and B.
- 2026-09-10 — Stage A (Sonnet) done except i386 `ntdll.dll`. Added a second
  configure tree `wine/build-i386` (`--enable-archs=i386`) in the local
  workspace; built and stripped i386 `kernel32.dll`, `kernelbase.dll` and
  aarch64 `wow64.dll` (28 exports incl. `Wow64LdrpInitialize`,
  `Wow64SystemServiceEx`, `Wow64KiUserCallbackDispatcher`), `wow64win.dll`.
  Wine never builds `wow64cpu` for aarch64 (`configure.ac:2385`); the CPU
  module is `xtajit.dll` = FEX. New `build/x86-tests/` with `hello-x86.exe`
  (imports only kernel32: `GetStdHandle`, `WriteFile`, `ExitProcess`) and a
  printf variant that needs the UCRT apiset DLLs (parked). `i386-windows/`
  added to the Xcode project as a folder reference; `prepare.py` picks it up.
  Findings handed to stage C: `wine/dlls/ntdll/loader.c:4123-4261`
  `iat_life_sweep` uses `xlate_ios_jit` without the `__arm64ec__` guard, so
  non-EC `ntdll.dll` cannot link; prefix template registry has
  `Wow64\x86 = "wow64cpu.dll"` (captured on x86_64); `system32`/`sysx64` are
  symlink farms built at launch by `WineProcessBridge.m:622-707`, so
  `syswow64` ← `i386-windows/` should be added there (app-side, later wave);
  `WineProcessBridge.m:604-618` has no i386 case for `MADEIRA_EXE`.
  `scripts/build-prefix-snapshot.sh` needs macOS Wine; cannot run on WSL.
  Stage C (Opus) started with the loader guard, contract class 1010, window
  reservation, wow64 helpers, wineserver audit, and a generic CPU-DLL fallback.
- 2026-09-11 — Stage C (Opus) done; all builds clean, no new warnings.
  `loader.c` guard fixed; i386 `ntdll.dll` built (imports nothing; i386
  closure for M1 is ntdll+kernelbase+kernel32). Contract class 1010 in
  `winternl.h:2042`, served by `process_ios.c:2741`. Window: interface
  `build/ntdll-unix/ios_wow.h`, implementation `virtual_ios.c:5367-5652`
  (per-PEB registry `ios_wow_windows[8]`, PROT_NONE reserve +
  `mmap_add_reserved_area`, 4 GB-aligned candidates below `0x7400000000`;
  reserved in `wine_ios_child_main` before `virtual_alloc_teb`
  (`loader_ios.c:3140`), released on child exit (`process_ios.c:470`)).
  Chokepoints: `allocate_virtual_memory:14127`, `virtual_map_section:12071`,
  `virtual_alloc_thread_stack:13107`, `map_image_view:11837`,
  `map_image_into_view:11490` (guest-based relocation), `init_teb:12621`,
  `virtual_alloc_teb:12744` (per-window TEB blocks), `env_ios.c` params,
  `load_ntdll_wow64_functions:2196` publishes guest addresses, a 32-bit child
  now calls `load_wow64_ntdll` (`loader_ios.c:3318`), USD second view at
  `B+0x7ffe0000` (`virtual_ios.c:13184`). wow64/wow64win: helper set
  `guest_ptr32/host_ptr32/…` in `wow64_private.h`; B read at
  `syscall.c:932`; cross-process B cache `syscall.c:105`;
  `ExceptionInformation[1]` converted; `load_cpu_dll` falls back to the
  platform default CPU DLL. wineserver: no changes needed; cosmetic
  `STATUS_IMAGE_NOT_AT_BASE` for i386 images is self-correcting.
  Decisions on stage C questions: (1) one 32-bit process at a time is the
  M1/M2 assumption; `wow_peb`/`user_space_wow_limit`/`main_image_info`
  go per-PEB in M3; (2) two 4 GB-aligned slots (0x7100000000, 0x7200000000)
  is enough for now; (3) wineserver learns B in M2 only if debug events or
  image-at-base reporting need it; (4) `Wow64AllocateTemp` stays host-only.
  Known-unfixed: cross-process `NtQueryInformationThread` TEB/stack info
  uses caller's B; system-wide enumeration addresses untranslated; no
  window path for an i386 *initial* process (the session's main image is the
  64-bit loader, so not needed). Stage E (app side) started.
- 2026-09-11 — Stage E (Sonnet) done; IPA builds (`xtool/Madeira.ipa`,
  54.9 MiB) but without `xtajit.dll` yet. `WineProcessBridge.m:359-379`
  reads the PE machine of the `MADEIRA_EXE` target; i386 targets resolve to
  `C:\windows\syswow64\<name>` (`:913-920`); `syswow64` ← `i386-windows/`
  farm added to the per-launch farm loop (`:763-786`); 64-bit routing
  unchanged. `process_ios.c:2264-2294` logs `MADEIRA-EXIT: <image>
  status=<n>` in `NtTerminateProcess(self)` (MADEIRA-TEMP tagged; reaches
  the log via the stdout/stderr dup to `Documents/madeira-log.txt`).
  `ContentView.swift:858-861` `thirtyTwoBitTests` table + button "32-bit
  hello" below the live view (one line per future 32-bit test). Device test
  not run. Without `xtajit.dll` the expected failure is `failed to load CPU
  backend` then `MADEIRA-EXIT: hello-x86.exe status=-1073741515`.
  Stage D review of the Wine half started while stage B (FEX) continues.
- 2026-09-11 — Stage B (Opus) done; compiles for iOS (FEXCore) and as
  aarch64 PE (`libwow64fex.dll`, Machine 0xAA64, 23 `BTCpu*` exports +
  `BTCpuIosSetMonoBridge`). Config `Guest32Base` (`Config.json.in:380`,
  `Context.h:325`, resolved `Core.cpp:135`, forced 0 in 64-bit mode).
  Reserved `REG_GUEST_BASE = x19`, `REG_GUEST_ADDR_TMP = x24` (callee-saved,
  only when base ≠ 0; `Arm64Emitter.h:115`, materialised in `FillStaticRegs`
  on every JIT entry/re-entry). Host address = `Base + zext32(EA + disp)`
  (displacement folded before the base so 4 GiB wrap stays in the window);
  atomics/acquire-release always use an explicit `add` into x24 so the
  backpatcher's `[Xn]` rewrite stays valid (`Arm64.cpp:2376` comment).
  Fetch reads `GuestBase + RIP` (`Core.cpp:804, 871`); SMC snapshot, Zydis,
  Mono probe, `ValidateCode`, `MemSet/MemCpy`, all atomics converted.
  Module: `GuestWindow` namespace (`Module.cpp:113`), base read at process
  init via class 1010, FS base = guest TEB32, syscall boundary `+B`
  (`:588`), BOP page published as guest (`:810`), fault addresses stay host
  (wow64.dll converts `ExceptionInformation[1]` — agreed: FEX passes host
  records, `exception_record_64to32` converts; no double conversion).
  `InvalidationTracker` internals stay host with conversion at the FEXCore
  boundary (invariant 6 met at the boundary). Host validation: qemu not
  possible (no qemu, no aarch64 sysroot, no sudo); used
  `CodeSizeValidation` on x86 host with 25 hand-encoded x86-32 cases, base 0
  vs 0x7c00000000 — e.g. `mov eax,[ebx]` → `add x24,x19,w6,uxtw; ldr
  w4,[x24]`; `push eax` → `sub w8,w8,#4; add x24,x19,w8,uxtw; stur w4,[x24]`;
  base-0 output matches upstream `Primary_32Bit.json`. Nothing executed on
  ARM64 yet. Build recipe: separate cmake configure with
  `Data/CMake/toolchain_mingw.cmake`, `-DMINGW_TRIPLE=aarch64-w64-mingw32`,
  `-DFEX_IOS_HOST_BUILD=ON -DCMAKE_{C,CXX}_FLAGS=-DFEX_IOS_HOST`,
  `--target wow64fex` → `Bin/libwow64fex.dll` → `aarch64-windows/xtajit.dll`.
  Open: unix-side `wow64_*` unixlib thunks (`loader_ios.c:1405` table and
  every other `__wine_unix_call_wow64_funcs` table compiled into Madeira)
  still read guest pointers embedded in argument blocks — assigned to the
  Wine agent. `IosMonoBridge` for WoW64 is unarmed (no publisher) — not
  needed for M1. FEX working tree shows CRLF-vs-LF noise under WSL git;
  review diffs with `--ignore-cr-at-eol`; resolve before committing.
  Policy: `FEX/CLAUDE.md` carries upstream's no-AI-contribution rule —
  nothing from this fork's FEX changes may be sent upstream (README says so).
- 2026-09-11 — Stage C follow-up (Opus) done. Helpers
  `ios_wow_host_ptr`/`ios_wow_guest_ptr32` in `wine/include/wine/unixlib.h:41-70`
  (identity off iOS). Converted every wow64 unixlib table linked into the app:
  ntdll (`loader_ios.c:1415`: dbg_write string, server_call iov/reply
  pointers `server_ios.c:3268-3271`, fd/handle output slots, spawnvp argv
  array and elements; the four iOS-private entries now return
  `STATUS_NOT_SUPPORTED` for 32-bit callers because their structs differ in
  layout), crypt32 (11 sites), ws2_32 (23), bcrypt (46), secur32 (30).
  dwrite's iOS replacement has no wow64 table (pre-existing gap; a 32-bit
  dwrite.dll would fail to load — M3 item). Deferred: `client_ptr_t` fields
  inside the raw `wine_server_call` request union (`server_ios.c:3272`
  comment lists them) — not on the M1 path; needs a per-request conversion
  table before M2 (threads/APCs/callbacks). Fault classification already
  uses ESR EC/WnR, not `si_code`; `bus_handler` now uses the same rule
  (`signal_arm64_ios.c:9516`). Exception records: FEX passes host,
  `exception_record_64to32` converts once; bug fixed in
  `Wow64RaiseException` (`syscall.c:1602-1659`) which synthesised records
  from guest values and would have been converted twice. Builds clean.
  Final IPA must be rebuilt after this native rebuild.
- 2026-09-11 — Stage D review of the Wine half (Opus, read-only). Verdict:
  not test-ready until F1–F3 fixed. F1 (M1-blocking): `thread_ios.c:1384,
  1389` size/tag `WOW64_CPURESERVED` from `main_image_info.Machine`, which
  `loader_ios.c:3307` has already restored to the 64-bit session image, so
  `get_cpu_area` returns NULL for the child and the initial i386 context is
  never written. F2: window release munmaps but leaves `file_view`s in
  `views_tree`, so a second 32-bit launch collides. F3 (64-bit regression):
  `wow_peb` is a session global; after any 32-bit child, `is_wow64()` is true
  for 64-bit threads with NULL CPU areas (crash in `get_cpu_area`), and
  `virtual_alloc_teb` gives them 32-bit stacks. F4: `NtWriteVirtualMemory`,
  `NtUnmapViewOfSectionEx` not retargeted. F5: non-NULL-preserving `−B`
  sites only work because B is 4 GB-aligned; the 256 MB fallback breaks
  that. F6: lock-free registry reads (deferred). F7: `PS_ATTRIBUTE_TEB_ADDRESS`
  uses caller's B. F8: `wow_guest_base_for_process` does a syscall per VM
  call even on native WoW64; racy cache. F9: no assert that the BOP page is
  inside the window. F10/F11 app-side trivia. F12: placement bias trims
  ~3 GB of low furniture from 64-bit scans while a window exists (deferred,
  noted). Verified correct: helper directions/NULL, non-pointer exclusions,
  ceiling chain with no off-by-one, fixed-address ops, image relocation
  delta, TEB/PEB self-references, USD view, loader guard, CPU-DLL fallback,
  exit log, PE header parse. Fixes F1–F5, F7–F11 assigned to the Wine agent;
  FEX-half review started.
- 2026-09-11 — Wine review fixes landed (Opus), 0 new warnings. F1:
  `thread_ios.c:1399-1408` sizes/tags the CPU area from the owning PEB's
  image machine. F3: `get_cpu_area` NULL guard (`:1339`); `virtual_alloc_teb`
  decides WoW from the process's own window (`virtual_ios.c:12788`);
  `virtual_set_large_address_space` uses `ios_wow_base()` (`:14126`).
  Still session-global: `wow_peb`, `user_space_wow_limit`, parts of
  `main_image_info` — one-32-bit-process-at-a-time assumption holds. F2:
  `ios_wow_window_retire()` (`:5620`) deliberately LEAKS the window on exit
  (unbind PEB, `leaked` flag, keep reservation, `ERR` once) because
  `exit_process` longjmps only the calling thread and never joins the
  pseudo-process's other threads; a real release needs `delete_view` of
  every view in the window plus a `teb_list` liveness proof (M2). F5: 4 GB
  alignment mandatory, no fallback; NULL-preserving `ios_wow_guest_in()`
  for entry/arg (`signal_arm64_ios.c:10595`) and `TO_GUEST()` for
  `ntdll_handle`/`GET_FUNC` (`loader_ios.c:2212-2221`, missing exports now
  publish 0 not −B). F9: `check_in_window()` in `wow64/syscall.c:778-795`
  at the four publish sites. F4/F7/F8 done (`PS_ATTRIBUTE_TEB_ADDRESS` for
  `NtCreateUserProcess` cannot know the child's B yet — the child reserves
  its window on its own thread — so it `ERR`s once instead of truncating).
  F10/F11 app-side done (inspection only; compiled by the IPA build).
- 2026-09-11 — Stage D review of the FEX half (Opus, read-only). Confirmed
  correct: `Base + zext32(EA + disp)` via one flag-free `add …, uxtw`, all
  atomics into the reserved x24, push/pop writeback in guest namespace,
  gather/MemSet/MemCpy/CacheLineZero, fetch split (`InstStream` guest,
  `AdjustedInstStream` host), single conversion point for every C++ guest
  read, register pools (x19/x24 outside SRA/pair/dynamic lists, callee-saved),
  `FillStaticRegs` on every entry/re-entry, base forced 0 outside 32-bit
  mode, module boundaries and `InvalidationTracker` namespaces, exception
  path single `−B`. Findings: FB1 (critical, cross-module) — FEX returns
  GUEST addresses from `BTCpuGetBopCode`/`__wine_get_unix_opcode` per §4,
  but `wow64/syscall.c:757, 1020, 1030-1031` applied `host_ptr32()` again
  (worked only by 4 GB alignment) — fix on the Wine side, assert raw value
  < 4 GB. FB3 — raw-immediate `ldp/stp`/non-temporal offsets add after the
  base, so an overrun near 0xFFFFFFFF lands at `B+4G`: mitigate by
  reserving 4 GB + one guard page. FB2 — `RA_GuestBase` restated, not
  derived; strengthen asserts. FB4 — `IosMonoBridge.cpp:119` raw
  `NtCurrentTeb()` (x18) on iOS. FB5/FB6 — build verification of the
  `BTCpuIosSetMonoBridge` export and of the DLL's import table. FB7/FB8
  diagnostics/naming. Fixes assigned: FB1/FB3 Wine agent; FB2/FB4-8 FEX
  agent. Policy (FB9): AI-written FEX changes stay in this fork only.
  Build agent (stage F) was cut off by a rate limit mid-task; resumes after
  the fixes.
- 2026-09-11 — Review fixes landed on both halves. Wine: FB1 —
  `wow64/syscall.c:785` `check_guest_addr()` validates the RAW CPU-DLL
  return values (nonzero, < 4 GB); the four publish sites (`:810, 1047-1051,
  1075`) store them verbatim (contract: the CPU DLL returns guest
  addresses). FB3 — `ios_wow_reservation_size()` = 4 GB + one host page
  (`virtual_ios.c:5404`); reservation, fit test, exclusion range and retire
  keep the guard page; the guest window itself stays exactly 4 GB. FEX:
  FB2 — `RA_GuestBase` derived from `RA` by pack expansion with four
  `static_assert`s (`Arm64Emitter.cpp:294-348`); FB4 — shared
  `WOW64/IosTeb.h` (`IOSLoadTEB`/`CurrentTEB` + TSD offset), used by
  `IosMonoBridge.cpp`; FB5 — `BTCpuIosSetMonoBridge` exported (ordinal 5)
  in the iOS build, correctly absent in the plain build; FB6 — imports are
  `ntdll.dll`, `wow64.dll` + the same 11 `api-ms-win-crt-*` API sets as the
  shipped `xtajit64.dll` (resolve via apisetschema → ucrtbase, both ARM64,
  present); FB7/FB8 done. Codegen re-verified byte-identical. All builds
  clean. Stage F resumed: reproducible `xtajit.dll` stage, final IPA,
  line-ending diagnosis.
- 2026-09-14 — **The virtual monitor is a real monitor now: it takes the
  device's shape, it lists modes, and `ChangeDisplaySettings` programs it.**
  Two generic defects, not one program's problem. (a) Every direct launch got
  a fixed 1024x768 virtual monitor whatever the device looked like, so a
  widescreen game rendered 4:3 and Fit pillarboxed it on a 19.5:9 phone —
  "the game runs in a smaller window in landscape". The `[display] mode=…`
  control added last round scales the presented surface and cannot touch
  that, because the aspect is decided inside the guest by the monitor it
  renders for. (b) `ios_virtual_change_display_settings` answered every mode
  request with DISP_CHANGE_SUCCESSFUL and changed nothing, which is worse
  than a clean failure: the game sizes its swapchain and its projection for a
  mode it is not running.

  **Default = the device's landscape shape.** `GuestDisplay`
  (`ContentView.swift:105`) holds the standard-mode list and
  `defaultMode(forLandscapeView:)` (`:130`) picks from it — nearest aspect
  first, then cheapest among modes of effectively the same aspect, with the
  candidate set limited to 0.9–2.1 MP because on a phone the render cost of a
  mode is the reason not to offer it. A 19.5:9 phone gets the nearest
  *standard* aspect (16:9) and Fit letterboxes the remaining sliver, rather
  than a 1560x720 that appears in nobody's mode list. `configureSessionDefault`
  (`:156`) exports `MADEIRA_SCREEN_W/H` plus a new `MADEIRA_SCREEN_SRC`;
  `Documents/madeira-screen.txt` holding `WxH` overrides it for a session
  (knob block, `:3830`). Desktop mode is untouched — explorer's buttons
  export their own `/desktop` size and `MADEIRA_SCREEN_SRC=desktop` at press
  time, after the block above has run.

  **win32u.** `ios_screen_size()` (`sysparams_ios.c:213`) is now a current
  mode plus a session default instead of a constant; it logs
  `[display] virtual monitor WxH (source=view|knob|desktop)` once.
  `ios_standard_modes[]` (`:3901`) + `ios_mode_at_index()` (`:3913`) are the
  mode table `NtUserEnumDisplaySettings` serves (`:3940`): index 0 is always
  the current mode, the rest are the standard modes capped at twice the
  current pixel count, all 32 bpp / 60 Hz. `ios_virtual_change_display_settings`
  (`:4087`) validates against that table (BADMODE for anything else, never
  BADPARAM for our own device name) and, for CDS_FULLSCREEN or 0, calls
  `ios_publish_screen_size()` (`:4031`), which is the whole propagation path:
  `update_display_cache(TRUE)` re-runs the virtual-monitor branch and pushes
  the new rectangle to the server, which moves `SM_C{X,Y}SCREEN`,
  `EnumDisplayMonitors`/`GetMonitorInfo` and the desktop window (win32u
  answers WND_DESKTOP rects from `get_primary_monitor_rect()`,
  `wine/dlls/win32u/window.c:1780`, so no `SetWindowPos` on a thread-less
  window is attempted); `NtUserClipCursor(NULL)` resets the desktop cursor
  clip, which absolute pointer input is clamped to
  (`build/wineserver/queue_ios.c` `update_desktop_cursor_pos`) and which the
  server seeds at a fixed size before any monitor exists; the weak
  `winios_display_mode_changed()` tells the app; then WM_DISPLAYCHANGE.
  `ios_publish_screen_size_once()` (`:4055`) runs the same path once for the
  session default, driven from the first `SM_CXSCREEN` query made after the
  desktop window handle is cached (`:7439`) — that is the one hot, lock-free
  place that is by definition about this value, and without it a monitor
  wider than the server's seed would have its pointer input clipped.
  `ChangeDisplaySettings(NULL, 0)` and CDS_RESET restore the session default,
  this port's equivalent of the registry mode.

  **App.** `IOSDisplayShim.m:84` `winios_screen_size()` is the accessor,
  `:96` `winios_display_mode_changed()` the sink win32u calls; it caches the
  size (seeded from the environment so a read before the first publish still
  answers) and posts `MadeiraDisplayModeChangedNotification` on the main
  queue. `MetalBackedView.guestSize()` (`ContentView.swift:454`) reads that
  accessor instead of `MADEIRA_SCREEN_W/H`, so `GameSurfaceLayout` — which
  sizes the presented layer's host view AND maps touches — follows the
  current mode; `GuestDisplay.observer` (`:187`) re-lays-out on the
  notification.

  **On a 2556x1179-point landscape view** the default is **1280x720**
  (16:9 is the nearest standard aspect to 2.168; 1280x720 is the cheapest
  16:9 mode in the MP window). Fit gives it the full height and a 2096x1179-pt
  rect — 230 pt of pillarbox each side, the 19.5:9-vs-16:9 sliver — where
  1024x768 gave 1572x1179 with 492 pt each side: 82 % of the width instead of
  61 %, and the picture is no longer 4:3-shaped. Fill crops that sliver to
  cover the view (2556x1438, 130 pt off top and bottom); Stretch distorts by
  2.168/1.778 = 1.22x. `EnumDisplaySettings` offers 14 modes there (everything
  up to 1.84 MP), so a game's resolution list works the way it does on
  Windows.

  **Test.** `build/x86-tests/dispmode-x86.c` (+ `build-dispmode-test.sh`,
  i386, kernel32/user32 only): enumerates modes (≥ 6, index 0 == current, all
  32 bpp / 60 Hz, 800x600 present), switches to 800x600 with CDS_FULLSCREEN,
  asserts `SM_C{X,Y}SCREEN`, `GetMonitorInfo`'s `rcMonitor` and
  ENUM_CURRENT_SETTINGS all report 800x600 and that WM_DISPLAYCHANGE arrived
  on a window it created carrying that size, then restores with
  `ChangeDisplaySettings(NULL, 0)` and asserts the original size is back.
  Exit 51 = pass; the header lists what 52–63 each mean. Launch row
  "Display modes" in `launchTargets` (`ContentView.swift:2560`).

  **Log to read:** `[display] virtual monitor 1280x720 (source=view)` once at
  start; `[iOS ChangeDisplaySettings] virtual display WxH: req=… -> 0 (mode
  programmed)` per switch; `[display] guest surface is now WxH` from the app;
  `[display] mode=Fit guest=WxH view=WxH -> rect=…` re-logged with the new
  guest size. `(mode is not in the virtual mode list)` means the game asked
  for something the table does not offer — add it to *both* lists, they are
  kept in step deliberately.

  **Reported, not changed:** DXMT's headless monitor
  (`research/dxmt/src/util/wsi_monitor_headless.cpp:105` `getDisplayMode`)
  still synthesizes the OLD three-entry list — 640x480, 800x600 and the
  current screen size — so the mode list a game sees through
  D3D9 `EnumAdapterModes`/DXGI is shorter than the one user32 now offers. It
  is not a correctness break: `getScreenSize()` there calls
  `GetSystemMetrics(SM_CXSCREEN)` live in the emulated build (`:49`), so
  DXGI's current mode and `getDesktopCoordinates` follow the switch and the
  two APIs never contradict each other about what is running. Bringing the
  two tables into line needs the i386 DXMT modules rebuilt, which is its own
  stage. The native D3D9 frontend caches no monitor size at device creation:
  `wsi_window_madeira.cpp:100` `getWindowSize` answers from the per-HWND
  client-size cache the shim refills at CreateDevice/Reset/Present
  (`d3d9_native_glue.cpp:1179`), so a fullscreen window that grew with the
  monitor is reported at its new client size with no hook needed.

- 2026-09-15 — **XInput: a controller paired to the phone is XInput user 0, and
  the same pad also presses the user's own on-screen controls.** Two roads, on
  purpose, because they serve two different halves of the library: anything
  written after roughly 2006 asks XInput for a pad, and everything older reads
  the keyboard and the mouse and has never heard of one. Neither road is a
  fallback for the other and both carry the pad at the same time — which is
  exactly what a PC with a controller and a key remapper does.

  **The transport, in full.** `HardwareInput.swift:1109` `padSample()` reads
  every `GCExtendedGamepad` on a dedicated `.userInteractive` queue driven by a
  `DispatchSourceTimer` at 4 ms (`:1093`), plus `valueChangedHandler` on that
  same queue so a button transition never waits out a tick. **Not a
  `CADisplayLink`:** it cannot exceed the refresh rate, and XInput's contract is
  a state that is current when you ask — a pad sampled at 60 Hz hands a
  1 kHz-polling game the same sample sixteen times and then jumps. Each sample
  is converted to XInput units (`:1289` `read`, `:1318` `axis`, `:1325`
  `trigger`) and published with `winios_gamepad_set_state`
  (`app/Madeira/Winios/Winios.m:1700`) into one of four slots. The slot is a
  **seqlock, not a queue and not a mutex** (`Winios.h`, the ml668 banner; the
  reader is `Winios.m:1749` `winios_gamepad_get_state`): a gamepad is a STATE,
  the reader is a guest thread possibly inside a frame's critical path in the
  same Mach task as the writer, and a bounded seqlock read cannot block it —
  four tries, then report "absent" for that one poll rather than hand a game a
  torn sample. The slot owns the **packet number** and bumps it only when a
  field actually differs (`Winios.m:1717`), because a packet that ticks on every
  resample defeats the one optimisation it exists for.

  **The syscall.** `NtUserCallTwoParam_GetGamepadState`
  (`wine/include/ntuser.h:1233`, appended to the end of the enum — those codes
  are an ABI between `win32u.dll` and the unix library and the farms are not
  rebuilt in lockstep), with `arg1` packing the user index in its low byte and a
  `NtUserGamepadOp_*` selector above it, `arg2` the output buffer, and the
  inline wrapper `NtUserGetGamepadState` at `:1249`. **No new syscall number,
  no `win32u.spec` change, no `win32syscalls.h` regeneration and no wow64win
  table change** — `NtUserCallTwoParam` is already a syscall on every arch, so
  the PE-side `win32u.dll` in all three farms needed no rebuild at all. Dispatch
  is `build/win32u-unix/sysparams_ios.c:8160` (and the same case, `#else return
  0;`, in upstream `wine/dlls/win32u/sysparams.c:7635`), body
  `build/win32u-unix/driver_ios.c:305` `ios_gamepad_query` — a plain memory
  read, no lock, no server round trip, because the app and the guest are one
  task (§2). Op 0 returns `XINPUT_STATE` (16 bytes), op 1 `XINPUT_CAPABILITIES`
  (20). `C_ASSERT`s at `driver_ios.c:288-290` pin both sizes and the shared
  struct's, since a silent layout drift there is garbage sticks and nothing
  else. The 32-bit half is `wine/dlls/wow64win/user.c:1902`: both payloads are
  pointer-free with identical 32- and 64-bit layout, so `guest_ptr32(arg2)` is
  the entire marshalling.

  **wine's xinput1_3** (`wine/dlls/xinput1_3/main.c:794` for the banner) tries
  the host slot FIRST in `XInputGetState`/`Ex` (`:934`), `XInputSetState`
  (`:911` — accepted and ignored; iOS cannot drive a pad's motors, and
  `ERROR_DEVICE_NOT_CONNECTED` would read to a game as the controller vanishing
  mid-frame), `XInputGetCapabilitiesEx` (`:1248`), `XInputGetBatteryInformation`
  (wired/full, the one answer that never draws a low-battery warning for a
  charge we cannot see) and `XInputGetKeystroke`, whose edge state machine was
  split out as `keystroke_from_state` (`:1064`) so the host path runs the
  identical logic over its own edge memory rather than a second copy of it.
  `XInputEnable` (`:883`) returns early when any host pad exists. All of that
  is **#ifdef-free**: a `win32u` that does not know the code falls into
  `default:` and returns 0, which is bit-for-bit "no pad in that slot", so a
  stock Wine keeps its HID path untouched. The host path also deliberately
  answers **before** `start_update_thread()` — that call builds a thread, a
  window, a device-notification registration and a setupapi enumeration that on
  a phone finds nothing, in every process that so much as asks once.

  **The on-screen half.** `TouchControl.padBinding`
  (`app/Madeira/ContentView.swift:4570`, a `PadButton` at `:4423`, raw-value
  Codable so the layout JSON stores a name and not an ordinal) names the
  physical button that ALSO presses that control. `HardwareInput`
  `applyPadBindings` (`:1179`) drives them through
  `ControlOverlayView.padPress`/`padRelease`/`padDir`/`padAim`
  (`ContentView.swift:2239-2318`), which take an `InputGuard` owner **per
  physical button** and hold that control's own `ControlRegionKind` — so the
  reconciler in `InputGuard.tick`, the coalescing ring and every owner count see
  one more finger and need to know nothing new. `padReleaseAll` is wired into
  `dropAllTouches` (`:2023`), so a pad hold dies with every other hold. The left
  stick 8-way-snaps into whatever dirstick it is bound to using the SAME
  `snap`/`stickKeys` convention a thumb uses (`HardwareInput.swift:1339`
  `snap8`); the right stick drives `AimStickDriver`, and does so even with no
  aim control on screen whenever `InputSettings.relative` is set, because in
  that mode nothing else on the phone can turn the camera with a pad. Defaults
  when a layout names no button at all (`bindingMap`, `:1232`): A/B/X/Y then
  LB/RB then Start/Back onto the layout's own buttons in creation order, left
  stick onto its first stick — one explicit binding anywhere turns the whole
  default set off, because a half-defaulted layout is the only thing more
  confusing than no defaults. The **on-screen** dpad and buttons still post
  keys and feed XInput nothing; the physical pad is the only thing in that slot.
  The mapping panel's controller tab (`ContentView.swift:5289`) now picks a
  binding instead of the `ControlAction.pad("A")` glyph chips it used to offer,
  which drew an Xbox letter and pressed nothing.

  **Farms.** `xinput1_1/1_2/1_3/1_4/9_1_0/xinputuap` built and installed for all
  three arches; `wow64win.dll` rebuilt for aarch64 (its thunk is the 32-bit half
  of the syscall, and a farm with the new `xinput1_3` and an old `wow64win` is
  the exact shape that fails only for 32-bit programs and only at runtime). The
  64-bit farm shipped **no xinput at all** before this, so a 64-bit title asking
  for a controller failed at `LoadLibrary` before any of the above could be
  wrong; `.xtool/build-wine-64.sh`'s default set and `build-wine-i386.sh`'s
  `EXTRA_DLLS` now carry the whole set. `xinput1_3` gained `win32u` in IMPORTS
  (and so did 1_1/1_2/1_4/uap, which share its `main.c` through `PARENTSRC`);
  `xinput9_1_0` forwards to `xinput1_4.dll` at runtime and needed nothing.

  **Test:** `build/x86-tests/xinput-x86.c`, built by `build-xinput-test.sh` into
  `xinput-x86.exe` (i386, no CRT, kernel32-only imports — `xinput1_3.dll` is
  `LoadLibrary`'d so "the DLL is missing" and "the DLL says no pad" are
  different exit codes). It polls `XInputGetState(0)` at 120 Hz for 15 s and
  prints `MADEIRA-XINPUT: packet=N buttons=0x…. lx=… ly=… lt=… rt=…` on every
  packet change, exiting **53** on the first change. **63** is the timeout, and
  the line above it says which failure it was: no pad ever in slot 0, or a pad
  connected whose packet number never moved. 32-bit specifically, because the
  wow64 thunk is on the 32-bit path only — a 64-bit program would pass this test
  with that thunk missing entirely.

  **What to look for in the next log:** `[xinput] pad0 connected vendor=…
  profile=extended` at pair time and `[winios] gamepad slot 0 connected` right
  behind it; then every 10 s `[xinput] pad0 packets=N last_buttons=0x…. lx=…
  ly=…` — N climbing while the pad is being handled and standing still while it
  is at rest is CORRECT, N standing still while a stick is being waggled is the
  sampler. The 1 Hz `[hwinput] keys_down=… pad=0x…. lx=… ly=…` line carries the
  raw sample, which separates "the pad is not reporting" from "the pad is
  reporting and nothing is bound". `[input] pad <button> down on ctl.… (label)
  kind=…` is one line per bound press, and `[input] app keys=… owners=…` should
  show the owner count rise by one per held pad button and fall back — an owner
  count that stays high after every button is released is a pad hold that
  outlived its release.

## 7. D3D9 path (M4)

Goal: a 32-bit PE calling Direct3D 9 renders through Metal on the phone.
The acceptance test is `build/x86-tests/d3d9-cube-x86.c` (§7.9).

Wine's own `d3d9.dll` cannot serve this. It is shipped for both 64-bit farms
(`app/Madeira/{aarch64,arm64ec}-windows/d3d9.dll`, 576 KB / 768 KB, importing
`wined3d.dll`), but `wined3d` needs OpenGL or Vulkan and this runtime has
neither: `load_builtin_unixlib` hands `opengl32` a GL-absent stub table whose
every `wgl`/`gl` entry returns `STATUS_NOT_SUPPORTED`
(`build/ntdll-unix/virtual_ios.c:6227-6232`), and Wine is configured
`--without-vulkan` (`.xtool/configure-wine.sh`). So D3D9 must be translated to
Metal directly, by a DXMT-family frontend.

### 7.1 Inspection results (the facts this plan rests on)

**The two trees.** Madeira's fork is `research/dxmt` = `willfaust/dxmt`
@ `b4b89f0` (`v0.73-83-gb4b89f0`), with
`src/{airconv,d3d10,d3d11,dxgi,dxmt,nativemetal,nvapi,nvngx,util,winemetal}`
and no `src/d3d9`. The reference is `dacevedo12/dxmt` @ `e8dd4c6` (tag
`v0.4-d3d9`), which adds `src/d3d9` (72 files, ~31.5k lines) and `src/d3d12`.
They are separate forks of the same upstream (`3Shain/dxmt`) with disjoint
object stores — no merge base is computable locally, so this is a port, not a
merge.

**The crossing.** A DXMT PE module calls its unix side through
`__wine_unix_call`, and **the call code is literally the index into
`__wine_unix_call_funcs[]`** — `gen_remote_guard.py` says it outright: "the
slot number is the ABI: a single inserted or dropped line silently sends every
later call to the wrong function." Our table has 127 entries
(`src/winemetal/unix/winemetal_unix.c:3933`), the reference 151. **Indices
0–126 are the same functions in the same order in both trees**; our fork just
interposes generated `_rmg_` remote-guard wrappers on 39 of them. The
`enum airconv_unixcalls` slot numbers (74–88) are identical, and all 13 SM50
param structs plus their 10 `*_params32` mirrors are byte-identical. Every
`SM50*` entry point already exists here under the same name. The reference
appends 18 new Metal calls (127–144), 5 DXSO calls (145–149) and one more
(150); **`src/d3d9` references none of the 18**, so none of them are needed.

**Why 32-bit mostly "just works", and where it does not.** DXMT already
designs its argument structs to be layout-identical on both sides: an embedded
pointer is wrapped in `struct WMTMemoryPointer` / `WMTConstMemoryPointer`
(`src/winemetal/winemetal.h:132-200`), 8 bytes on both, which on i386 is
`void *ptr; uint32_t high_part;` with `high_part` forced to 0. Metal objects
cross as `obj_handle_t` (`uint64_t`), never as host pointers — invariant 4 is
satisfied by construction for those. But the consequence of the wrapper is
that **a 64-bit handler reading `params->x.ptr` from a 32-bit caller gets a
zero-extended GUEST address**, which is exactly the classic-WoW64 identity
assumption this project cannot make (§1). Upstream's
`__wine_unix_call_wow64_funcs[]` exists (127 entries) but differs from the
64-bit table in only **9** slots — the SM50 shader thunks — and those convert
with `UInt32ToPtr`, a bare zero-extension. Under a shifted window that yields
a sub-4 GB address that is not mapped at all.

**Presentation is arch-neutral, and that is a real result.** In game mode a
single Swift-owned `CAMetalLayer` is the whole story: `MetalHostView.shared`
(`app/Madeira/ContentView.swift:26-79`) owns it, `MetalBackedView`
re-parents and sizes it on the main thread (`:133-174`), publishes it once via
`madeira_display_set_layer` (`app/Madeira/IOSDisplayShim.m:50-54`), and
`my_view_create_metal_view` returns that same layer **for every HWND**
(`IOSDisplayShim.m:108-132`). `_CreateMetalViewFromHWND`
(`winemetal_unix.c:2672-2721`) returns it as two `obj_handle_t` fields, and
the PE side stores them in `uint64_t` (`winemetal_thunks.c:738-748`) — so a
32-bit process holds the 64-bit layer handle without truncation and hands it
straight back to `MetalLayer_setProps` / `nextDrawable`. **No part of the
present path needs a guest-window conversion.** `drawableSize` is written only
by `_MetalLayer_setProps` (`:2586-2610`), and the RAW-vsync frame-skip gate
lives in `_MetalLayer_nextDrawable` (`:2536-2548`), which can return a nil
drawable the frontend must tolerate.

### 7.2 Licensing — the task's premise is wrong, and a decision is needed

**The `v0.4-d3d9` tag is not MIT.** Its repo root carries `LICENSE` =
**LGPL-2.1-or-later** ("Copyright (c) 2023-2026 Feifan He for CodeWeavers"),
the full text in `COPYING.LIB`, and a `LICENSE.OLD` recording that releases
"up to v0.80" were MIT. Our fork branched at or just before that relicense, so
`research/dxmt/LICENSE` is still the MIT one. The `src/d3d9` files carry **no
per-file headers at all** (they start at `#pragma once` or the first
`#include`), so the root files are the only statement of terms.

Consequences:

- Importing `src/d3d9` and the `dxso_*`/`ffp_*` airconv files brings
  LGPL-2.1-or-later code into a tree whose `LICENSE` says MIT. LGPL-2.1+ is
  upgradeable to GPL-3.0 through its "or later" clause, and this fork already
  declares its own modifications GPL-3.0-or-later and ships
  `COPYING.GPL-3.0`, so the combination is lawful — but it has to be stated.
- Required before the first file lands: add the LGPL-2.1 text, a notice
  naming the d3d9/DXSO-derived files and their upstream copyright, and
  reconcile `research/dxmt/LICENSE`, `LICENSE-MADEIRA.md` and
  `THIRD-PARTY-NOTICES.md`.
- BoxedVN's `THIRD_PARTY_NOTICES.md`, which describes these DXMT PE modules
  as MIT and shared with this project, is inaccurate for this tag. That is
  worth telling whoever maintains it.

This is a licensing decision for the fork owner, not something a port commit
should settle. ~~**Stage 3 onward is blocked on it.**~~ **Decided
2026-09-11: proceed** — import under LGPL-2.1 §3, converting the copy
distributed here to GPL-3.0-or-later, exactly as this repository already did
for its Wine fork. The notices that decision requires are written (§7.11);
`research/dxmt/LICENSE` deliberately stays MIT, because it states the terms of
what this fork took from *its* upstream, and the imported files are listed
separately in `research/dxmt/LICENSE-MADEIRA.md`.

### 7.3 Stages and file ownership

| Stage | Owner | Files | State |
|---|---|---|---|
| 1. i386 PE build stage; acceptance test; guest-pointer conversion mechanism | DXMT | `build/dxmt-ios/build-pe.sh`, `.xtool/build-dxmt.sh`, `build/x86-tests/d3d9-cube-x86.{c,exe}`, `build/x86-tests/build-d3d9-cube.sh`, `research/dxmt/{meson.build,src/winemetal/unix/winemetal_unix.c}` | **done, §7.8** |
| 2. Licensing decision + notices | fork owner | `research/dxmt/{LICENSE,COPYING.LIB}`, `LICENSE-MADEIRA.md`, `THIRD-PARTY-NOTICES.md` | **done** — proceed under LGPL-2.1 §3 → GPL-3.0-or-later, notices written (§7.11) |
| 3. airconv DXSO/FFP import | DXMT | `research/dxmt/src/airconv/{dxso_header.hpp,dxso_decoder.hpp,dxso_compile.{hpp,cpp},ffp_compile.{hpp,cpp}}`, the DXSO half of `airconv_public.h`, deltas to `nt/air_builder.*`/`air_signature.*`/`air_operations.cpp`/`air_type.cpp`, `src/airconv/meson.build` | **done, §7.11** |
| 4. `src/d3d9` import + API reconciliation | DXMT | `research/dxmt/src/d3d9/**`, `src/meson.build`, deltas to `src/dxmt/*`, `src/util/wsi_window*`, `src/winemetal/{winemetal.h,Metal.hpp,unix/winemetal_unix.c}` | **done, §7.11** — 21/21 TUs compile, `d3d9.dll` links and installs, `enable_d3d9` option removed |
| 5. Slot + wow64 table completion | DXMT | `src/winemetal/airconv_thunks.{h,c}`, `src/winemetal/unix/winemetal_unix.c`, regenerate `wmt_api_names.h` + `unix/wmt_remote_guard.h`, extend `gen_remote_guard.py` | **done, §7.11** (38 + 5 slots) |
| 6. 32-bit unixlib table selection | WINE | `build/ntdll-unix/virtual_ios.c` static-link fallback | **hand-off, §7.10** |
| 7. Launch button | APP | `app/Madeira/ContentView.swift` `thirtyTwoBitTests` | **hand-off, §7.10** |
| 8. IPA + device test | BUILD | `.xtool/build.sh` | after 3–7 |

### 7.4 What is 64-bit-only, and what needs the wow64 table

**64-bit-only, no work at all.** Everything inside `libdxmt_combined.a` runs
host-side and is always 64-bit: Metal itself, the airconv/DXSO translator and
its LLVM 15, the presentation layer, the shader cache. A 32-bit guest changes
nothing about them. The `nativemetal` path, `nvapi` and `nvngx` are not in
play. Metal objects, HWNDs, NT handles, unix-side `malloc` cookies
(`SharedEventListener`), inline `char` arrays, sizes, flags, enums and
`gpu_address` (a Metal GPU virtual address, not a CPU one) are **never**
offset — invariant 4.

**Needs the wow64 table.** Exactly those slots whose argument block carries an
embedded pointer. From the audit, **37 slots are currently shared verbatim
between the two tables and dereference caller memory**:

- 8 `NSString_getCString` (OUT) · 18 `MTLDevice_newBuffer` (INOUT, two
  levels) · 19 `newSamplerState` · 20 `newDepthStencilState` ·
  21 `MTLDevice_newTexture` · 22 `MTLBuffer_newTexture` ·
  26 `MTLLibrary_newFunction` · 29 `newComputePipelineState` (two levels) ·
  32 `renderCommandEncoder` · 34 `newRenderPipelineState` (two levels) ·
  35 `newMeshRenderPipelineState` (two levels)
- 36/37/38 the three `*CommandEncoder_encodeCommands` — **the hard ones**:
  each walks a caller-allocated singly linked list of `wmtcmd_*` records
  whose every `next` is a guest pointer, so conversion happens at every hop,
  not once; plus four payload pointers inside the chain
  (`wmtcmd_compute_setbytes.bytes`, `wmtcmd_render_setbytes.bytes`,
  `wmtcmd_render_setviewports.viewports`,
  `wmtcmd_render_setscissorrects.scissor_rects`)
- 45 `MTLTexture_replaceRegion` · 54 `startCapture` (two levels) ·
  56/57 `newTemporalScaler`/`newSpatialScaler` · 58 `encodeTemporalScale` ·
  60/61 `NSString_string`/`NSString_alloc_init` ·
  70/71 `MetalLayer_setProps`/`getProps` (71 INOUT) ·
  91 `MTLLogContainer_enumerate` (OUT array) ·
  96 `WMTGetDisplayDescription` (OUT) · 97 `MetalLayer_getEDRValue` (OUT) ·
  98 `newFunctionWithConstants` (two levels, array of
  `WMTFunctionConstant.data`) · 99/100/101 the display-setting trio ·
  107 `MTLBuffer_updateContents` · 114 `DispatchData_alloc_init` ·
  115–119 the five `cache.c` entries · 120 `newSharedTexture` (INOUT)

Plus the **9** existing `thunk32_SM50*` slots (74, 76, 77, 79, 81, 82, 84,
85, 88), which are already 32-bit-aware but convert with the wrong arithmetic
— fixed in stage 1 (§7.8) — and the **5** new DXSO slots from stage 5.

Rules for stage 5:

1. A `thunk32_*` must convert **every** embedded pointer with
   `ios_wow_host_ptr()` semantics, at every level of nesting, before any
   dereference. NULL stays NULL.
2. An OUT or INOUT pointer field written back for the guest must be converted
   the other way (`PtrToUInt32Ptr`, added in stage 1). Storing the guest
   address as a pointer value leaves `high_part` zero, which is what the
   i386 accessor asserts on.
3. Both tables must stay the **same length** and a 32-bit variant must sit at
   the **same index** as its 64-bit twin.
4. No fake success. A slot that has no 32-bit variant yet must fail, not
   silently dereference a guest address.
5. Slot numbering for DXSO: take the reference's `unix_dxso_initialize = 145`
   and leave 127–144 `NULL`, rather than packing DXSO into our next free slot
   127. The 18 dead slots cost nothing and keep any future cherry-pick from
   the reference landing on the same numbers; the tree already does exactly
   this for the `NULL` at slot 83.
6. `gen_remote_guard.py` must be extended before hand-writing anything: its
   `fix_table()` rewrites **both** tables from a `guarded` set computed off
   the 64-bit table only, so an `_rmg_Foo32` entry in the wow64 table gets
   silently rewritten to `_Foo32`, stripping the guard. It also only
   recognises handler bodies of the form
   `_Foo(void *obj) { struct unixcall_... *params = obj;`, so a 32-bit
   variant taking a mirror struct would not get its outputs zeroed. Give it a
   per-array `guarded` set and a `base -> base32` name map.
   `gen_api_names.py` hard-codes `WMT_API_COUNT 127` and must be regenerated
   too.

### 7.5 Mapped GPU memory and the guest window

This is the one place where the design genuinely constrains DXMT rather than
just relabelling pointers. `_MTLDevice_newBuffer`
(`winemetal_unix.c:337-351`) has two paths:

```
if (info->memory.ptr)  buffer = [device newBufferWithBytesNoCopy:info->memory.ptr ...];
else { buffer = [device newBufferWithLength:...];
       info->memory.ptr = ... [buffer contents]; }
```

- **Caller-supplied path (`memory.ptr` non-NULL).** This is DXMT's normal
  path: the ring bump allocator
  (`src/dxmt/dxmt_ring_bump_allocator.hpp`) hands in
  `block.mapped_address` from its own PE-side heap and then keeps writing
  argument-buffer contents through that same pointer — the unix side's own
  comment at `:311-318` warns that substituting a different allocation
  produces draws that render nothing. For a 32-bit caller that pointer is a
  **guest** address, so the thunk must add B. This works, and it works for
  the right reason: a `VirtualAlloc` inside a WoW pseudo-process already goes
  through the window chokepoint (`allocate_virtual_memory`, §5 stage C), so
  the memory is inside `[B, B+4G)` by construction and the 32-bit app can
  keep dereferencing it with 32-bit pointers.
- **Metal-allocated path (`memory.ptr` NULL).** `[buffer contents]` is a host
  pointer from Metal's own heap, which is **not** in the window, so there is
  no guest address that names it. Writing it back into a field the 32-bit
  side will read is unrepresentable. **`thunk32_MTLDevice_newBuffer` must
  therefore refuse this path loudly** (fail the call and log), not truncate.
  Stage 4 has to confirm that every `src/d3d9` buffer allocation supplies
  memory; if any does not, the fix is to route it through the ring allocator,
  not to relax this rule.
  **Confirmed and fixed in stage 4 (§7.11):** one allocation did not — the
  shared `Buffer::allocate`, which is every d3d9 vertex and index buffer. It
  now supplies its own memory on i386 rather than the rule being relaxed.

Two further constraints for stage 4:

- `newBufferWithBytesNoCopy:` requires a page-aligned base and length. The
  build defines `DXMT_PAGE_SIZE=4096` unconditionally
  (`research/dxmt/meson.build:155`) while the iOS host page is 16 KB. The
  64-bit path evidently copes today, but the i386 build must be checked
  against the real host page size rather than assumed.
- Anything the guest maps must be allocated by the 32-bit process's own
  allocation path (so the chokepoint applies) or with a sub-4 GB `zero_bits`.
  Never by the host side on the guest's behalf.

### 7.6 Build shape

`research/dxmt`'s own meson already knows about i386: `cpu_family == 'x86'`
selects `i386-windows` as both install dirs and adds
`--enable-stdcall-fixup`, `-Wl,--kill-at` and `-mpreferred-stack-boundary=2`
(`meson.build:174-215`). What did not exist in this checkout was **any** PE
build stage at all — the DLLs in `app/Madeira/{aarch64,arm64ec}-windows/` were
imported prebuilt, and `.xtool/build-dxmt.sh` only ever built the unix half.
Stage 1 added `build/dxmt-ios/build-pe.sh` (§7.8).

Notes that cost time to find:

- The upstream `build-win32.txt` cross file is unusable here: it names a 2023
  llvm-mingw at `@GLOBAL_SOURCE_ROOT@/toolchains/...` with `-gcc`/`-g++` tool
  names, and expects a `toolchains` symlink inside the submodule. `build-pe.sh`
  generates cross files with absolute paths into the workspace instead, so no
  untracked symlink is added to the submodule.
- `src/winemetal/meson.build` looks for `winebuild` at
  `<wine_build_path>/tools/winebuild/winebuild`, but on this host only
  `wine/build-tools` builds host tools. `build-pe.sh` aliases it in.
- `wine/build-i386` is the right `-Dwine_build_path` (it is the
  `--enable-archs=i386` tree from `.xtool/configure-wine.sh`) and already has
  `libntdll.a`, `libwinecrt0.a`, `libucrtbase.a`, `libuser32.a`, `libgdi32.a`.
  `dbghelp` resolves from llvm-mingw's own import library.
- `-Dwine_builtin_dll=true` is required, otherwise `windows_native_install_dir`
  becomes `syswow64` instead of `i386-windows`.
- The native workspace is a `git archive HEAD` export, so both the unix and PE
  stages now rsync the tracked `research/dxmt` over it first. Before this,
  `.xtool/build-dxmt.sh` silently built whatever HEAD contained — any
  uncommitted submodule change was invisible.
- `DXMT_IOS` was keyed on `cpu_family == 'aarch64'`, so it would have been
  undefined for the i386 target and an i386 module would have asked Metal for
  `storageMode` Managed, which iOS asserts on. Now keyed on
  `host_machine.system() == 'windows'` (§7.8).

### 7.7 Risks

1. **Licensing (§7.2)** — the only hard blocker, and it is not technical.
2. **`src/dxmt` divergence, the largest technical unknown.** `src/d3d9`
   includes 15 `src/dxmt` headers and 13 `src/util` headers. Between the two
   trees `dxmt_context.hpp` is +355/-82 and `dxmt_command.hpp` +141/-42.
   Most of that churn is D3D12/residency/heap/indirect-command-buffer work
   that `src/d3d9` does not touch — it includes **none** of the B-only
   `dxmt_*` files — but which of the APIs it *does* use changed shape needs a
   symbol-level pass. This is stage 4's real cost, not the 31.5k lines of
   `src/d3d9` itself, which drop in essentially unmodified.
3. **Do not take the reference's `winemetal.h` wholesale.** Three traps:
   `WMTRenderPassInfo` changes `render_target_array_length` from a `u16` at
   offset +2 to a `u8` at +1 (same total size — a silent wire-format break
   for every render pass); `WMTPixelFormat` replaces discrete swizzle flag
   bits with a packed 12-bit field at bits 12–23 (a value-level ABI break);
   and it lacks our `DXMT_IOS` storage-mode remap. `src/d3d9` needs none of
   the three, so keep our definitions.
4. **Separating the DXSO half of `airconv_public.h`'s +503 lines** from the
   `SM50_SHADER_ROOT_SIGNATURE`/D3D12 half. The fiddliest mechanical job in
   the port.
5. **Slot-number drift.** Any insertion in the middle of either table
   mis-dispatches every later call, with no diagnostic. Regenerate
   `wmt_api_names.h` and `wmt_remote_guard.h` in the same change, always.
6. **The command-chain thunks (36/37/38)** are the highest-risk conversion
   work: per-node pointer walks over guest memory in the hot path, on every
   draw. Getting them wrong produces plausible-looking frames with missing or
   corrupt geometry rather than a clean crash.
7. **One D3D9-specific behaviour to watch:** the reference gates `src/d3d9`
   on a cross build with the comment that "the Direct3D 9 frontend manages
   the app's window itself, which the API's focus and device window rules
   require." On iOS there is one Swift-owned layer for every HWND
   (§7.1), so whatever window management `d3d9_swapchain.cpp` does has to be
   neutralised the way `d3d11_swapchain.cpp` already is under `DXMT_IOS`
   (`src/d3d11/d3d11_swapchain.cpp:765-780` forces visible/foregrounded and
   disables the fullscreen transition).
8. **Shadowing.** Keep the DXMT `d3d9.dll` in `i386-windows/` only. The
   64-bit farms already ship Wine's `d3d9.dll` + `wined3d.dll`; there is no
   collision today because `i386-windows/` had no `d3d9`, and a 32-bit
   process must resolve `d3d9.dll` from `syswow64` before `system32`.

### 7.8 Stage 1 — what landed, and how it was verified

- **`build/dxmt-ios/build-pe.sh`** (new): the PE build stage. Syncs the
  tracked submodule into the workspace, generates cross/native machine files,
  aliases `winebuild`, configures and builds per arch, strips and installs.
  `--targets` limits what is built, `--install` what is copied into the app
  bundle (default `winemetal.dll d3d9.dll`, so a whole-tree compile check does
  not quietly add unwired DLLs to the bundle).
- **`.xtool/build-dxmt.sh`**: now rsyncs `research/dxmt` before building, and
  runs the PE stage after the unix stage (`MADEIRA_DXMT_PE_ARCHS` to widen).
- **`research/dxmt/meson.build:157-172`**: `DXMT_IOS` keyed on the Windows
  host system, so it covers i386 as well as aarch64/arm64ec.
- **`research/dxmt/src/winemetal/unix/winemetal_unix.c`**: `UInt32ToPtr` is
  now the `+B` conversion under `TARGET_OS_IOS` (`extern unsigned long
  ios_wow_base(void)`, resolved at app link time because DXMT's unix half is
  statically linked into the same binary), NULL-preserving, and the identity
  again when there is no window or off iOS. This is one edit covering all 22
  call sites in the existing `thunk32_SM50*` handlers — a latent
  invariant-2 violation that predates this milestone. Added the reverse
  helper `PtrToUInt32Ptr` for OUT fields, and renamed the wow64 table to
  `dxmt_winemetal_unix_call_wow64_funcs` on iOS so the ntdll side has a
  symbol to bind (§7.10).
- **`build/x86-tests/d3d9-cube-x86.c` + `build-d3d9-cube.sh`** (new): §7.9.

Verified:

| what | result |
|---|---|
| i386 PE build, whole tree | `ninja` exit 0; `winemetal.dll` 65,536 B, `dxgi.dll`, `d3d11.dll`, `d3d10core.dll` all **Machine 0x14C**; one pre-existing unused-variable warning |
| i386 install | `app/Madeira/i386-windows/winemetal.dll` 65,536 B |
| edited unix side, iOS arm64 | `clang -arch arm64 -miphoneos-version-min=18.0` exit 0; only two pre-existing tautological-compare warnings from `wmt_remote_pack.h`; `_ios_wow_base` present as an undefined import; both tables present as `_dxmt_winemetal_unix_call_funcs` / `_dxmt_winemetal_unix_call_wow64_funcs` |
| acceptance test | `d3d9-cube-x86.exe` 59,392 B, `pe-i386`, imports exactly `KERNEL32.dll`/`USER32.dll`/`d3d9.dll`, `LARGE_ADDRESS_AWARE` set |

The most useful of those is the first: **the entire DXMT C++ substrate that
`src/d3d9` depends on — all of `src/util`, `src/dxmt`, `src/winemetal` —
already compiles clean as 32-bit x86 PE code.** The build side of the port is
de-risked; the remaining cost is API reconciliation (§7.7 risk 2), not
toolchain work.

### 7.9 Acceptance test

`build/x86-tests/d3d9-cube-x86.c`, built by
`build/x86-tests/build-d3d9-cube.sh` (kept separate from `build.sh`, which
the 32-bit bring-up track owns). Own implementation; no CRT — it supplies
`start` and its own `memset`/`memcpy` and links `-nostdlib
-static-libgcc -Wl,--large-address-aware`, so its imports are exactly
`kernel32`, `user32` and `d3d9`, all Wine-supplied; the build script asserts
both the import set and the LAA bit.

It is deliberately the smallest program that still crosses every part of the
boundary: a 32-bit process loading an i386 `d3d9.dll` and reaching its unix
side through the wow64 table; a swapchain on a real HWND, so presentation has
to reach the app's Metal layer; and a `D3DUSAGE_DYNAMIC` `D3DPOOL_DEFAULT`
vertex buffer that the guest `Lock()`s and writes through a 32-bit pointer
every frame — which is the §7.5 constraint stated as a test. FVF
`XYZRHW|DIFFUSE` with `D3DCREATE_SOFTWARE_VERTEXPROCESSING`: vertices arrive
already in screen space, so no transform, lighting or texture state is needed.
No depth buffer — a cube is convex, and back faces are rejected on the CPU by
the sign of the screen-space signed area, so the image does not depend on the
layer's winding convention. No libm either: both rotations advance by
multiplying a unit rotor by a constant-angle rotor.

Exit status, reported as `MADEIRA-EXIT: d3d9-cube-x86.exe status=<n>`:
**43** success (240 frames presented, or closed after at least one frame);
20 `Direct3DCreate9` returned NULL; 21 `CreateDevice` failed;
22 `CreateVertexBuffer` failed; 23 `Lock` failed; 24 `Present` failed
unrecoverably; 25 window creation failed; 26 closed before any frame.
It logs `MADEIRA-D3D9:` progress lines throughout, including the first
`Lock()` pointer — which should be a guest address inside the window.

### 7.10 Hand-offs to other tracks

1. **WINE — 32-bit unixlib table selection (blocks any 32-bit DXMT call).**
   `load_builtin_unixlib` (`build/ntdll-unix/virtual_ios.c:6122-6172`) takes a
   `BOOL wow` that `get_unixlib_funcs` honours for a real `.so` (`:6034-6039`)
   — but the iOS static-table fallback **ignores it**, so the
   `strstr(match, "winemetal")` branch at `:6167-6172` hands a 32-bit caller
   the 64-bit table. It must select
   `dxmt_winemetal_unix_call_wow64_funcs` when `wow` is set. The same gap
   affects every other statically linked table (`ws2_32`, `bcrypt`,
   `secur32`, `crypt32`, `nsi`, `dwrite`), whose wow64 tables
   `build/ntdll-unix/build.sh:72` already renames to
   `<prefix>_unix_call_wow64_funcs` — so the fix is one shared mechanism, not
   a one-off. Until it lands, a 32-bit DXMT module gets `thunk_SM50*` instead
   of `thunk32_SM50*`.
   **Done** — `ios_bind_unixlib_table()` now picks by bitness (see the
   2026-09-11 log entry); with stage 5 below, a 32-bit DXMT module gets the
   `_Foo32` variants.
2. **APP — launch button. Done:** the one entry is in `thirtyTwoBitTests`
   (`app/Madeira/ContentView.swift:858-864`), which is a
   `[(label: String, exe: String)]` rendered with `id: \.exe` at `:1518-1531`:
   `("D3D9 cube", "d3d9-cube-x86.exe"),`. Nothing else — the renderer already
   sets `MADEIRA_EXE`, and `WineProcessBridge.m` detects i386 by real PE
   machine (`:674-694`) and resolves it to
   `C:\windows\syswow64\d3d9-cube-x86.exe` (`:918-925`). The exe is already
   installed in `app/Madeira/i386-windows/`, which the probe at `:688-690`
   requires.
3. **Fork owner — licensing (§7.2). Done** — proceed, see §7.11.

### 7.11 Stages 2, 3 and 5 — what landed; stage 4's remaining inventory

**Stage 2, licensing (done).** The fork owner's decision is to import under
LGPL-2.1 §3, converting the copy distributed here to GPL-3.0-or-later. Written
in the same change as the first imported file:

- `research/dxmt/COPYING.LIB` — the LGPL-2.1 text from the tag (new file).
- `research/dxmt/LICENSE-MADEIRA.md` — a new section naming the origin, tag and
  commit, the upstream licence, the §3 conversion, and a file-by-file list
  separating whole-file imports from blocks spliced into existing files.
  `research/dxmt/LICENSE` stays MIT on purpose: it states the terms of what
  this fork took from *its* upstream.
- `THIRD-PARTY-NOTICES.md` — a "DXMT — Direct3D 9 / DXSO frontend" row
  (origin, tag, commit, LGPL-2.1-or-later, §3 conversion) plus a pointer from
  the per-fork-notice list. It also records that describing these modules as
  MIT is wrong for this tag.

**Stage 3, DXSO/FFP (done).** Imported whole from the tag:
`src/airconv/{dxso_header.hpp,dxso_decoder.hpp,dxso_compile.{hpp,cpp},ffp_compile.{hpp,cpp}}`
(6 files, 7,373 lines). The fork's airconv needed exactly **three** additions,
not the wholesale header deltas §7.3 budgeted for:

- `air::InputPointCoord` + its `FunctionInput` slot and AIR metadata arm
  (`air.point_coord`, float2) — PS point-sprite substitution.
- `OutputPointSize` added to the `FunctionOutput` variant (the struct and the
  mesh-output arm already existed) + its `air.point_size` arm.
- `AIRBuilder::FPBinOp::pow` (one enum value, one `FnNames[]` entry).

Deliberately **not** taken from the reference's `airconv_public.h`: its
`AIRCONV_VERSION`, `SM50_BINDING_INDEX`, `SM50_SHADER_FLAG` (which adds a
`flags` field to `SM50_SHADER_COMMON_DATA`, an SM50 wire-format change),
`SM50_SHADER_ROOT_SIGNATURE` and the `ShaderType` relocation. DXSO references
none of them and this fork's d3d11 depends on the current SM50 layout.

**Stage 5, slots and the wow64 table (done).** Both tables are now **150**
entries. 127–144 are `NULL` by design (§7.4 rule 5) so DXSO sits at the
reference's own numbers, 145–149; ntdll fails a NULL slot rather than
dispatching it. `airconv_thunks.{h,c}` carry the five PE-side `DXSO*` thunks
(`winemetal.dll` exports them: ordinals 7–11), and the unix side carries
`thunk_DXSO*` plus `thunk32_DXSOInitialize/Compile/GetCompiledBitcode` and the
imported 32-bit argument-chain converter — which needed no arithmetic change
because this tree's `UInt32ToPtr` is already the `+B` conversion (§7.8).

The **38** shared slots that dereference caller memory now have `_Foo32`
variants in the wow64 table. They reuse the 64-bit argument struct rather than
a `*_params32` mirror, because every embedded pointer is a
`WMTMemoryPointer`/`WMTConstMemoryPointer` — 8 bytes on both sides — so the
blocks are layout-identical and only the pointer *values* differ. Each variant
converts in place, calls the 64-bit handler, and restores the guest values
(the block is the guest's own memory and DXMT reads its fields again).

| Slot(s) | Conversion |
|---|---|
| 8 `NSString_getCString` | `buffer_ptr` (raw `uint64_t` holding a guest pointer; the buffer is OUT, the pointer IN) |
| 18 `MTLDevice_newBuffer` | `info` → `WMTBufferInfo`, then `info->memory.ptr`; **refuses** the Metal-allocated path per §7.5 unless the storage mode is Private/Memoryless (where the handler leaves the field NULL); `gpu_address` untouched |
| 19, 20, 21, 120 | `info` (sampler / depth-stencil / texture / shared texture descriptors: handles and scalars only below) |
| 22 `MTLBuffer_newTexture` | `info` |
| 26 `MTLLibrary_newFunction` | `arg` is a guest pointer to the function-name string, not a value |
| 29, 34, 35 pipeline states | `info`, then `info->binary_archives_for_lookup` (second level; the archive handles inside are host handles) |
| 32 `renderCommandEncoder` | `arg` → `WMTRenderPassInfo` |
| 36, 37, 38 `*_encodeCommands` | the whole `wmtcmd_*` chain: every node's `next` at every hop, plus the payload pointer of `render_setbytes` / `render_setviewports` / `render_setscissorrects` / `compute_setbytes`; converted forward, then converted back node by node |
| 45 `MTLTexture_replaceRegion` | `data` |
| 54 `startCapture` | `info`, then `info->output_url` |
| 56, 57, 58 scalers | `info` / `props` |
| 60, 61 `NSString_string`/`alloc_init` | `buffer_ptr` |
| 70, 71 `MetalLayer_set/getProps` | `arg` (71 is INOUT) |
| 91 `MTLLogContainer_enumerate` | `buffer` (OUT array of handles) |
| 96, 97 | `arg` (display description / EDR value, OUT) |
| 98 `newFunctionWithConstants` | `name`, `constants`, then every `constants[i].data` (second level, array) |
| 99, 100, 101 display settings | `hdr_metadata` |
| 107 `MTLBuffer_updateContents` | `data` |
| 114 `DispatchData_alloc_init` | its `handle` field is the BYTES pointer, not a handle (`arg` is the length) |
| 115–119 `cache.c` | `path` / `key` |

`gen_remote_guard.py` was extended **first**, as §7.4 rule 6 warned: it now
reads both tables, keeps a per-array guarded set and a base→base32 map, and
emits `_rmg_Foo32` wrappers (inside `#ifndef DXMT_NATIVE`) for exactly the 10
variants whose 64-bit twin is guarded — previously it would have rewritten
`_rmg_Foo32` back to `_Foo32` and stripped the guard. It also refuses to run if
the two tables differ in length. `wmt_api_names.h` (150 entries) and
`unix/wmt_remote_guard.h` (49 guards, 10 of them 32-bit) were regenerated in
the same change; `gen_api_names.py` now strips the `_rmg_` wrapper prefix, so
regenerating the census no longer renames every guarded slot to
`rmg_<api>` (its committed copy predated the guards). The `NULL` block is written one entry per line because both
generators read the table with a per-line regex.

Verified: `wsl bash .xtool/build-dxmt.sh` to completion — unix side 22/22
translation units OK (was 20; `dxso_compile` and `ffp_compile` are new),
`libdxmt_unix.a` 4,399,928 B (was 3,927,648 B), `libdxmt_combined.a` relinked;
i386 PE stage `ninja` exit 0 with `winemetal.dll` 65,536 B, Machine 0x14C,
installed into `app/Madeira/i386-windows/` and now exporting `DXSOCompile`,
`DXSODestroy`, `DXSODestroyBitcode`, `DXSOGetCompiledBitcode`,
`DXSOInitialize`. Build-integration bug found and fixed on the way:
`.xtool/build-dxmt.sh` ran `$MADEIRA_WORK/build/dxmt-ios/build.sh`, which is
part of the `git archive HEAD` export, so the new translation units were
silently ignored; it now refreshes that copy from the tracked tree the same way
it refreshes the submodule.

**Stage 4, `src/d3d9` — done: it compiles, links and is installed.** All **71**
files of `src/d3d9` are imported (31,544 lines, including `meson.build`,
`d3d9.def` and `version.rc`) and wired into `src/meson.build`. All **21**
translation units now compile as i386 PE and `d3d9.dll` links: **107 errors
from 39 distinct causes → 0**. The `MADEIRA-TEMP` `-Denable_d3d9` option is
**gone** (removed from `meson.options`); `src/meson.build` builds `d3d9` for
every non-`dxmt_native` target, and `build-pe.sh` installs it by default.
Wine's wined3d-based `d3d9.dll` was only ever built for the two 64-bit farms,
so nothing in `app/Madeira/i386-windows/` was replaced and the §7.7 shadowing
concern stands unchanged. `d3d9` needs **no** `dxgi`: its meson dependencies
are `util_dep`, `winemetal_dep`, `airconv_forward_dep`, `dxmt_dep`, and
`dxmt_dep` pulls in `winemetal` only.

What closed the 39 causes, in the order §7.11 recommended:

1. **Pure renames in the imported call sites** (`research/dxmt/src/d3d9/`,
   `d3d9_device.cpp` and `d3d9_clear_quad.cpp` only): `ResourceAccess::Read/
   Write/ReadWrite` → `DXMT_ENCODER_RESOURCE_ACESS_*` (15 sites; the fork keeps
   the upstream `ACESS` typo). The reference also templates `access<>` on
   `PipelineStage` where this fork templates it on `bool PreRasterStage`, an
   error the `ResourceAccess` one had been masking: 15 further sites,
   `PipelineStage::Vertex` → `true`, `Pixel`/`Compute` → `false`. That
   parameter is inert in this fork (`trackBuffer`/`trackTexture` ignore it), so
   the mapping is faithful to intent, not just to types. `resolve_texture_cmd`
   and `signalEventByHandle` turned out **not** to be renames — see below.
2. **Additive back-ports from the tag** (each listed in
   `research/dxmt/LICENSE-MADEIRA.md`): `wsi::foregroundWindow()`
   (`src/util/wsi_window.hpp:110`, `wsi_window_win32.cpp:244`,
   `wsi_window_headless.cpp:87`); `Recall_sRGB_ForRenderTarget()`
   (`src/dxmt/dxmt_format.hpp:37-49`); `RingBumpState::preallocate()` /
   `seal_latest()` / the `single_writer` constructor argument
   (`dxmt_ring_bump_allocator.hpp:33-85,110-127`) — the tag's `__i386__`
   8 MB `kStagingBlockSize` came with it (`:14-23`), which matters here: a
   32-bit guest lives under a 2-3 GB VA ceiling and each 32 MB block costs a
   Metal address-space registration; `CommandQueue::HasDeviceError()` /
   `MarkDeviceError()` / `FrameLatencySignaled()` / `WaitFrameLatency()`
   (`dxmt_command_queue.hpp:207-216,294-310`, `.cpp:262-265`);
   `Presenter::setDisplaySyncEnabled()` (`dxmt_presenter.hpp:42`,
   `.cpp:106-113` — a no-op on iOS, where `_MetalLayer_setProps` compiles the
   field out and `getProps` reports `true`); `GetDXMTShaderCacheDirectory()`
   (`dxmt_shader_cache.hpp:11`, `.cpp:9-18`, which the existing `ShaderCache`
   constructor now calls instead of duplicating);
   `BufferAllocation::length()` (`dxmt_buffer.hpp:62-67`);
   `TextureAllocation::buffer()` (`dxmt_texture.hpp:107-114`); and the
   `out_minted_fresh` out-parameter of `DynamicBuffer::allocate`
   (`dxmt_dynamic.hpp:13-21`, `.cpp:31,148-149`) — §7.11 had called that last
   one `Buffer::mapped_address`'s second argument, which was a misreading.
3. **Mechanism back-ports.**
   - **Render-command ABI extension.** `WMTRenderCommandSetBlendFactor`,
     `SetFragmentSamplerState`, `SetVertexTexture`, `SetVertexSamplerState`
     appended to `WMTRenderCommandType` (`winemetal.h:1109-1128`) with
     `wmtcmd_render_setsamplerstate` (`:1181-1187`); decoded in
     `_MTLRenderCommandEncoder_encodeCommands`
     (`unix/winemetal_unix.c:1758-1789`). `SetBlendFactor` reuses
     `wmtcmd_render_setblendcolor` but sets **only** the blend colour: d3d9
     carries its stencil reference on the depth-stencil state, so the d3d11
     `SetBlendFactorAndStencilRef` behaviour would clobber it.
     `WMTBlitCommandOptimizeContentsForGPUAccess` +
     `wmtcmd_blit_optimize_contents` appended the same way
     (`winemetal.h:869-882`, `:960-967`; decoded at `winemetal_unix.c:1521-1531`,
     sized at `:1401-1402`). Three `WMTRenderCommandReserved*` and four
     `WMTBlitCommandReserved*` placeholders keep every value on the reference's
     own number, the same reasoning as §7.4 rule 5's NULL unix-call slots.
     **No new unix-call slot was needed** and neither dispatch table changed
     length: these are render/blit *commands*, which ride slots 36/38, whose
     `_MTLBlitCommandEncoder_encodeCommands32` /
     `_MTLRenderCommandEncoder_encodeCommands32` already walk the guest chain.
     `wow_cmd_payload()` needed no new arm — every new record carries only
     `obj_handle_t` values and scalars — and now says so explicitly
     (`winemetal_unix.c:4634-4641`) so the next addition does not miss it.
     PE-side helpers `setFragmentSamplerState` and `setDepthStencilState` added
     to `Metal.hpp:430-450`.
   - **GPU completion targets.** `GpuCompletionStatus`, `GpuCompletionTarget`,
     `CommandChunk::addCompletionTarget()` and its `completion_targets` vector
     + mutex (`dxmt_command_queue.hpp:24-42,155-172,199`), dispatched from the
     finish thread alongside the existing frame-latency signal
     (`dxmt_command_queue.cpp:181-184,194-196`), with `MarkDeviceError()` set
     from the same `WMTCommandBufferStatusError` test so `HasDeviceError()` and
     the `Failed` status agree.
   - **The three context commands.** `ArgumentEncodingContext::copyTexture()`,
     `optimizeTextureForGPUAccess()` and `stretchBlit()`, plus
     `resolveDepthTexture()` and an extended `resolveTexture()`
     (`dxmt_context.hpp:603-660`, `dxmt_context.cpp:443-575`). The extension is
     the important part: `resolveTexture`'s four new arguments are all
     defaulted, so **every d3d11 call site keeps its exact meaning** — a null
     `pso` still selects Metal's own `StoreActionStoreAndMultisampleResolve`
     attachment resolve. A non-null `pso` selects a new shader-resolve branch,
     which is the only way to express the sub-rect, offset destination or
     format-converting resolve that d3d9 `StretchRect` needs, and
     `is_depth` selects the depth-attachment variant. `EncoderType::StretchBlit`
     + `StretchBlitEncoderData` are new (`dxmt_context.hpp:85-90,206-240`,
     encode body `dxmt_context.cpp:1276-1320`).
     `ResolveTextureMode`/`ResolveTextureContext`/`StretchBlitContext` live in
     `dxmt_command.{hpp,cpp}` next to the other internal-library contexts, and
     their five shaders (`vs_resolve_msaa`, `fs_resolve_msaa_average`,
     `fs_resolve_msaa_depth`, `vs_blit_quad`, `fs_blit_quad`) were imported into
     `dxmt_command.metal:233-315`.
   - **The texture-view model, done additively** — the one item §7.11 warned
     was invasive, and it did not have to be. The reference turns
     `TextureViewKey` from this fork's `unsigned` index into a packed value
     carrying a descriptor and a mip range; **that change was not taken**,
     because `dxmt_texture.hpp` is shared with d3d11. Instead:
     `Texture::fullView` is a `static constexpr TextureViewKey = 0`
     (`dxmt_texture.hpp:262-267`) — both constructors push the whole-resource
     descriptor as view 0 and `createView()` only ever appends, so view 0 *is*
     the full view, as a fact about the constructors rather than about the
     number; `miplevelCount()` reads `info_.mipmap_level_count`;
     `checkViewUseMipRange()` and `checkViewUseSwizzle()` are two more
     derive-or-reuse helpers in the shape of the existing
     `checkViewUseFormat()` (`dxmt_texture.cpp:302-330`); and
     `TextureViewDescriptor` gains a `swizzle` field defaulting to the identity
     (`dxmt_texture.hpp:25-45`), which `createView()` now compares
     (`dxmt_texture.cpp:106-107`) and `TextureView`'s constructor passes through
     to `newTextureView` in place of the hard-coded identity it used before
     (`dxmt_texture.cpp:34-37`). Every d3d11 view keeps the identity swizzle, so
     it keeps the view it had.

**Presentation (§7.1 re-confirmed against the real code).** `d3d9_swapchain.cpp
:335` calls `WMT::CreateMetalViewFromHWND`, which on iOS returns the one
Swift-owned `CAMetalLayer` for every HWND, and hands it to the fork's own
`Presenter` (`:345`). No conversion is needed in that path and none was added.
Of the slots a `Present` touches, `CreateMetalViewFromHWND` (72),
`MetalLayer_nextDrawable` (67), `MetalDrawable_texture` (66) and
`presentDrawable` (47) carry **no** embedded pointer — their argument structs
are `uint64_t`/`obj_handle_t` only (`winemetal_thunks.h:17-20,225-230`), so
sharing the 64-bit handler is correct, not an oversight. The ones that do carry
a pointer all have `_Foo32` variants already: `MetalLayer_setProps`/`getProps`
(70/71), `WMTGetDisplayDescription` (96), `MetalLayer_getEDRValue` (97), the
display-setting trio (99-101), and `MTLRenderCommandEncoder_encodeCommands`
(38), which is the slot the new render commands ride.

**Mapped memory (§7.5): one real blocker found and fixed.** The §7.5 audit of
the imported frontend turned up a genuine invariant break, and it was on the
hottest path rather than a corner: `Buffer::allocate`
(`research/dxmt/src/dxmt/dxmt_buffer.cpp:148-193`) built its `WMTBufferInfo`
with `memory` NULL and `WMTResourceStorageModeShared` for every allocation that
is not `CpuInvisible`. That is exactly the Metal-allocated path
`_MTLDevice_newBuffer32` refuses, and **every d3d9 vertex and index buffer goes
through it** — `allocateD3D9BufferStorage` (`src/d3d9/d3d9_device.cpp:3209`) and
every `DynamicBuffer` rename (`src/dxmt/dxmt_dynamic.cpp:154`) ask for
`CpuWriteCombined`, never `CpuInvisible`. On a 32-bit guest the very first
`CreateVertexBuffer` would have failed the call. Fixed the way §7.5 prescribes
(supply the memory; do not relax the rule) and the way `Texture::allocate`
already did for its buffer-backed allocations
(`dxmt_texture.cpp:186-188`): under `#ifdef __i386__`, `Buffer::allocate` now
sets `BufferAllocationFlag::CpuPlaced` for any non-`CpuInvisible` allocation, so
`BufferAllocation`'s constructor `wsi::aligned_malloc`s the backing and its
destructor frees it. That memory is this PE module's own heap inside the WoW
pseudo-process, so it is inside `[B, B+4G)` by construction.

The rest of the audit came out clean, and worth stating because it is what
§7.5 was written to protect:

- **Nothing from `[buffer contents]` ever reaches the application.** There is no
  `contents()` call anywhere in `src/d3d9/**`. Every `Lock`/`LockRect`/`LockBox`
  out-pointer is PE-side memory the module owns: `wsi::aligned_malloc` mirrors
  for buffers (`d3d9_buffer.cpp:291`, `:513`) and surfaces
  (`d3d9_surface.cpp:524`), a `MapViewOfFile` chunk for volumes
  (`d3d9_volume.cpp:173` via `d3d9_mem.cpp`), or the application's own
  user-memory pointer. `d3d9_buffer_map.hpp:13-16` states the invariant
  outright: Lock returns a host mirror Metal has never seen.
- The three direct `device.newBuffer` calls inside `src/d3d9/**`
  (`d3d9_texture.cpp:268`, `d3d9_cube_texture.cpp:165`,
  `d3d9_device.cpp:10511`) all set `memory` from an `aligned_malloc`'d page.
- The upload/const rings d3d9 builds (`d3d9_device.cpp:534-550`) are
  `placed_buffer = true`, so their blocks are `malloc`ed by the ring.
- Two Managed + NULL-memory ring allocators exist and *would* trip the thunk:
  the queue's `staging_allocator` (`dxmt_command_queue.cpp:24-27`) and
  `gpu_command_heap_allocator` (`dxmt_resource_initializer.cpp:50-52`). Neither
  is reachable from d3d9 today — `AllocateStagingBuffer` has no d3d9 caller, and
  the imported code says why it avoids it
  (`d3d9_device.cpp:10621`, `d3d9_device.hpp:1597`: "that one is
  Metal-allocated"). Left alone rather than changed: the thunk refuses them
  loudly, which is the designed behaviour, and converting them would change
  d3d11's allocation shape on the 64-bit farms for no present gain.

**Still open after this session.**

- **The remote Metal backend does not know the new commands.**
  `src/winemetal/unix/wmt_remote_pack.h` fails them with
  `WMTW_PACK_UNSUPPORTED_OP` — loudly and by name, which is the right
  behaviour and not a fake success, but it means a d3d9 title cannot run with
  `wmtr_enabled()`. Closing it needs new `WMTW_OP_*` wire ops in
  `research/remote-metal/`, which is a different component's tree.
- **Sub-rect fidelity of the colour resolve is untested.** The shader-resolve
  branch is a faithful port, but nothing has executed it yet; the only resolve
  the acceptance test exercises is the full-extent MSAA backbuffer one, which
  takes the unchanged attachment path.
- **Nothing has run on a device.** Everything above is a compile/link result.
  §7.9's `d3d9-cube-x86.exe` is built and installed and its launch button is
  wired (§7.10), so the next step is an IPA and a device run.
- **Working-tree line endings.** The `research/dxmt` checkout is CRLF in the
  working tree while git stores LF, and git's stat cache currently hides that
  (`git status` reports files clean that differ from `HEAD` by line endings
  alone). Any file touched in this session therefore shows as a whole-file
  rewrite in `git diff`. Pre-existing, not introduced here, but the commit
  agent should normalise before committing or the D3D9 diff will be unreadable.

Verified this session: `wsl bash .xtool/build-dxmt.sh` to completion — unix
side **22/22** translation units OK, `libdxmt_unix.a` 4,400,808 B (was
4,399,928 B), `libdxmt_combined.a` relinked; i386 PE stage `ninja` exit 0 with
no new warnings, `d3d9.dll` **3,280,896 B** and `winemetal.dll` 65,536 B both
**Machine 0x14C**, installed into `app/Madeira/i386-windows/`. `llvm-objdump
-p` on the installed `d3d9.dll`: imports are exactly `KERNEL32`, `USER32`,
`GDI32`, `winemetal.dll` and the `api-ms-win-crt-*` sets; exports include
`Direct3DCreate9`, `Direct3DCreate9Ex`, `Direct3DShaderValidatorCreate9`,
`DebugSetLevel`/`DebugSetMute` and all seven `D3DPERF_*`. d3d11 still builds:
the i386 run produced `d3d11.dll` 32,276,480 B, `d3d10core.dll` 2,154,496 B and
`dxgi.dll` 5,173,248 B (built, deliberately not installed), and a separate
`build-pe.sh aarch64 --install none` run built the whole aarch64 farm clean
(`d3d11.dll` 31,870,976 B, Machine 0xAA64) without touching
`app/Madeira/aarch64-windows/`.


## 8. Native ARM64 D3D9 frontend behind a 32-bit shim (M4b) — PLAN

Premise (measured, §6 2026-09-14): the emulated `d3d9.dll` is 20-28 % of
all CPU at 15-20 fps, on the game's render thread and on DXMT's own encode
thread (95 % JIT there). Nothing about that code needs to be x86. Gate met.

### 8.1 Inventory

15 public interfaces, 320 vtable slots, 10 DLL exports, 1 private
interface (`IDxmtDiag9`, tests only). Slots: `IDirect3D9Ex` 22,
`IDirect3DDevice9Ex` 134, `SwapChain9Ex` 13, `Surface9` 17, `Texture9` 22,
`CubeTexture9` 22, `VolumeTexture9` 22, `Volume9` 11, `VertexBuffer9` 14,
`IndexBuffer9` 14, `VertexDeclaration9` 5, `VertexShader9` 5,
`PixelShader9` 5, `StateBlock9` 6, `Query9` 8. Exports in `d3d9.cpp`:
`Direct3DCreate9(Ex)`, seven `D3DPERF_*`, `DebugSetLevel/Mute`,
`Direct3DShaderValidatorCreate9` (+ its 6-slot private vtable).

Argument shapes (318/320 parsed): 125 no pointer; 91 one pointer; 78 two;
24 three+; 68 `**` out-params (45 of them identity queries answerable in
the shim); 18 interface-pointer inputs; 47 `const T*` inputs; 18 mapped-
memory methods (`Lock/Unlock` ×2 buffers, `LockRect/UnlockRect` ×3,
`LockBox/UnlockBox` ×2, `GetDC/ReleaseDC`) plus three transient cases
(`DrawPrimitiveUP`, `DrawIndexedPrimitiveUP`, the `pSharedHandle`
user-memory idiom); 1 callback (`shader_validator_cb`, never crosses).

Hot path today is a cheap shadow-array store + dirty bit (`SetRenderState`
`d3d9_device.cpp:6275-6306` always returns D3D_OK; `SetTexture` `:6524`;
`SetStreamSource` `:11502`; `Set*ShaderConstantF` `:11302`); the expensive
per-draw call is `DrawIndexedPrimitive` (`:6924`). CONSEQUENCE: a state
setter turned into a synchronous unix call is a REGRESSION for that call;
the win is in `Draw*`, `Lock/Unlock`, `Present`, shader compilation and —
largest — the encode thread. Hence §8.6's command ring is not optional.

### 8.2 Architecture

(a) RECOMMENDED: native ARM64 **unixlib** (extend `libdxmt_unix.a`; new
table pair bound by `load_builtin_unixlib` exactly like `winemetal`), NOT
an arm64ec PE. Reasons: DXMT already builds `dxmt_native`
(`research/dxmt/meson.build:10,39-41,150-153`, CI-tested); `src/meson.build:
15-22` excludes d3d9 from it only by our own comment; the winemetal boundary
disappears (`src/nativemetal/wineunixlib.h:9-11` makes `WINE_UNIX_CALL` a
table-indirect call — today EVERY winemetal call pays a full JIT exit,
`FEX/Source/Windows/WOW64/Module.cpp:642-663,733-752`, thousands per frame
from the encode thread — this win is independent of batching and probably
the largest single item); DXMT's threads become plain pthreads
(`src/util/thread.hpp:326-348`), removing guest stacks, 16 MB callret
reservations and all JIT for encode/finish/event/threadpool threads; Metal
object lifetime is host-side, so the §7.5 `CpuPlaced` arm in
`dxmt_buffer.cpp:148-193` and the 8 MB staging blocks
(`dxmt_ring_bump_allocator.hpp:14-23`) can revert toward the tag; plain
Itanium C++ EH; no JIT-pool residency (a 31.8 MB PE in the pool cost 22 %
of the jetsam budget in §6 round 2). REJECTED: arm64ec PE + wow64 thunk DLL
— no generic 32→64 PE thunk mechanism exists; `wow64win` works through the
SYSCALL tables (`syscall.c:59-62,1185-1187`), so this would need hand-rolled
syscall stubs + a `wow64d3d9.dll` converter + the PE: three modules, all
the same pointer work, plus pool residency.

(b) The i386 shim (`app/Madeira/i386-windows/d3d9.dll` becomes thin):
objects and vtables live in guest memory by construction (image mapped in
the window; `HeapAlloc` goes through the window chokepoint); vtables at a
stable address for the process lifetime (apps cache/patch them — which is
why `SetTexture` identifies textures via a registry, `:6530-6533`). Object
header `{vtbl, refcount, kind, uint64 native}`; `native` is a HANDLE
(index+generation into a native table — invariant 4, validated failure
instead of a wild host dereference, and the per-process sweep of §8.9-5).
Refcounting entirely guest-side, one native release at zero; D3D9's
private-reference rules (surface lifetime = texture's, `d3d9_texture.hpp:
219-229`) reproduced in parent/child tables. Identity answered LOCALLY with
no call: `GetTexture`, `GetStreamSource`, `GetIndices`, `Get*Shader`,
`GetVertexDeclaration`, `GetRenderTarget`, `GetDepthStencilSurface`,
`GetBackBuffer`, `GetSwapChain`, `GetDevice`, `GetContainer`,
`GetDirect3D`, `GetSurfaceLevel`, `GetCubeMapSurface`, `GetVolumeLevel`,
all `QueryInterface`s (~45 of the 68 `**` slots). MUST-NOT-FORGET:
`setupFpu()` (`d3d9_device.cpp:504-521`, x87 CW → 24-bit unless
`D3DCREATE_FPU_PRESERVE` `:556-558`) moves into the shim and runs on the
guest's creating thread. Also shim-local: `D3DPERF_*`, `DebugSet*`, the
whole shader-validator state machine (`d3d9.cpp:85-316`).

(c) Pointer rules: NO D3D9 struct contains an embedded pointer except
`pBits`. Four mirrors needed (i386 vs LP64 layout differs):
`D3DPRESENT_PARAMETERS` (HWND at +28/+32, size 56/64),
`D3DDEVICE_CREATION_PARAMETERS` (16/24), `D3DLOCKED_RECT` (8/16, `pBits`),
`D3DLOCKED_BOX` (12/16, `pBits`); everything else (`D3DCAPS9`,
`D3DADAPTER_IDENTIFIER9`, `D3DVERTEXELEMENT9[]`, display modes, matrices,
lights, materials, viewport, rects, boxes, constant arrays) is layout-
identical and pointed at in place after one `+B`. Rules: outer block
converted by FEX (`Module.cpp:751`); every nested pointer via
`ios_wow_host_ptr()` NULL-preserving; nesting ≤2 levels (`pSharedHandle`
— convert only when SYSTEMMEM + non-NULL = user-memory idiom;
`DrawIndexedPrimitiveUP`'s two buffers; `pBits`); OUT pointers written
back via `ios_wow_guest_ptr32()` — exactly one field, `pBits`; sizes,
enums, HWND/HMONITOR/HDC/HANDLE, native handles never offset; both tables
same length, 32-bit variant at the same index, generated; parameter blocks
use fixed-width fields (`uint32` guest ptr, `uint64` handle) so they are
layout-identical on both sides (the `WMTMemoryPointer` trick).

Mapped memory (§7.5) — the GUEST ARENA: every app-dereferenceable pointer
must be inside `[B,B+4G)`; `d3d9_buffer_map.hpp:13-54` states the contract
and `:36-47` why it can never change (a Metal-wrapped page written through
translated code livelocks at fault-service cadence; Metal allocates above
4 GB anyway). Native `wsi::aligned_malloc` returns host heap — unusable.
Mechanism: the shim `VirtualAlloc`s 64 MB chunks (window chokepoint ⇒ in
`[B,B+4G)` by construction) and registers `{guest_base,size}`; the native
side sub-allocates and computes guest addresses trivially; exhaustion
returns a distinguished status and the shim grows-and-retries (no upcall
machinery anywhere). Alignment 16384 (real iOS page; `DXMT_PAGE_SIZE=4096`
at `meson.build:155` is wrong here — assert `getpagesize()`). Split the
allocator: `dxmt::guest_alloc/guest_free`, `#define`d to
`wsi::aligned_malloc` off-Madeira; convert ONLY app-visible sites:
`d3d9_buffer.cpp:87,351`; `d3d9_surface.cpp:110,148`; texture/cube/volume
mirrors (`d3d9_cube_texture.cpp:160,171` etc.); `d3d9_device.cpp:3213,
3495,3621,5366,5408,5510,5560,10502` (backing pool `d3d9_device.hpp:1310`);
`d3d9_mem.cpp` chunks. Leave host: `dxmt_context.cpp:40`,
`dxmt_occlusion_query.hpp:169`, `dxmt_texture.cpp:187`, `dxmt_buffer.cpp:
27`, both staging rings (`dxmt_ring_bump_allocator.hpp:206,249`).
`d3d9_mem.cpp`'s reclaiming chunk allocator is gated `_WIN32 && !_WIN64`
(`d3d9_mem.hpp:29-31`) → false natively → MANAGED/SYSTEMMEM mirrors become
permanent guest-VA allocations; Phase 1 accepts and censuses it; Phase 2
may back chunks with decommittable arena chunks.

(d) Threading: DXMT threads become native pthreads (automatic in
`dxmt_native`); audited — command queue uses Metal shared events and
`obj_handle_t`, no Win32 sync anywhere in `src/dxmt`/`src/d3d9`.
`src/util/util_win32_compat.h` must NOT be used (every stub warns+fails);
new `util_madeira_compat.h` with real `GetCurrentThreadId`,
`SwitchToThread`, `SetThreadPriority`, `GetCurrentProcessId`, sentinels.
`D3DCREATE_MULTITHREADED` moves to the shim (recursive spinlock keyed by
`GetCurrentThreadId`; native device constructed `is_protected=false`);
encode/finish threads never took it (`d3d9_multithread.hpp:116-118`).
Callbacks into the guest: none (validator stays local;
`RegisterSoftwareDevice` returns NOTAVAILABLE `d3d9_interface.cpp:151`;
window messages are guest-pump-driven). All user32/gdi32 stays in the
shim: cursor `d3d9_device.cpp:1744-1844`, fullscreen styles `:1955-2015`,
focus hook/`focusWindowProc` `:2025-2077,2191-2256`, `onFocusActivation`
`:2086-2180`, `GetDC` via `D3DKMTCreateDCFromMemory` `d3d9_surface.cpp:
46-53`, `GetClientRect` `d3d9_interface.cpp:980`/`wsi_window_headless.cpp:
32`; a `wsi_window_madeira.cpp` takes client size from a shim-supplied
per-HWND cache updated at CreateDevice/Reset/Present.

(e) Presentation: unchanged (§7.1/§7.11): `d3d9_swapchain.cpp:336` →
`WMT::CreateMetalViewFromHWND` → the one Swift-owned CAMetalLayer
(`IOSDisplayShim.m:108-132`), handles cross as `obj_handle_t`; natively
these become direct calls. RAW-vsync nil-drawable gate unchanged.

### 8.3 Unix side
`dxmt_d3d9_unix_call_funcs[]` + `dxmt_d3d9_unix_call_wow64_funcs[]`, same
length/indices, generated; `virtual_ios.c` gains a `strstr(match,"d3d9")`
branch next to the winemetal one (`:7133-7136`) and externs (`:6936`);
`ios_bind_unixlib_table()` (`:7063-7081`) picks by bitness; the shim binds
via `__wine_init_unix_call()` → `NtQueryVirtualMemory(MemoryWineLoad
UnixLibWow64)` (`:18959-18971`); `ios_module_export_name()` handles PE32.

### 8.4 Cost of one unix call — MEASURE FIRST
Path: bridge page (`Module.cpp:1137`) → JIT exit + `SpillStaticRegs` →
`HandleSyscall` → `HandleSyscallImpl` (`:725-775`) → `UnlockJITContext` →
`WineUnixCall` → table → `_d3d9_Foo32` → `LockJITContext` (CAS + possible
`WOW_CPU_AREA_DIRTY` reload) → `FillStaticRegs`. Estimate 150-400 ns; do
not build on the estimate. Two measurements before any architecture work:
(1) `[d3d9-census]` per-method counters in the CURRENT i386 d3d9.dll
(modelled on `wmt_api_census.c`; divide by Present count → calls/frame);
(2) `_d3d9_nop` unix slot timed from `d3d9-cube-x86.exe` → ns/call. At an
assumed 13k calls/frame × 250 ns = 3.25 ms/frame: 6.5 % at 20 fps, 19 % of
a 16.7 ms frame at 60 fps — synchronous-everything is a wall at target.

### 8.5 Phase 1 — shim + native library, synchronous
Acceptance: cube passes (exit 43), the game renders correctly, fps ≥ −10 %,
`[prof]` `pe:d3d9.dll`/`jit:d3d9.dll` collapse, encode thread JIT → 0.
Files to create under `research/dxmt/src/d3d9shim/` (i386 PE):
`d3d9_api.py` (the single interface description: interface, ordinal, name,
return, per-arg shape tag `u32/u64/iface_in/iface_out/in_struct:T/
out_struct:T/in_array:T:count/out_ptr:T/locked_rect_out/handle`,
disposition `local/sync/defer` + validation predicate + constant return),
`gen_d3d9_thunks.py`, `d3d9shim_main.c` (DllMain, exports, D3DPERF, debug,
validator moved verbatim from `d3d9.cpp:44-316`), `d3d9shim_object.c/.h`,
`d3d9shim_window.c` (`d3d9_device.cpp:1744-2270`), `d3d9shim_fpu.c`
(`setupFpu`), `d3d9shim_arena.c`, `d3d9shim_lock.c`, generated
`d3d9shim_thunks.c` (320 bodies + 15 vtables) and `d3d9shim_ops.h`
(parameter blocks + ring opcodes, included by BOTH sides), `d3d9.def`,
`meson.build` (`cpu_family=='x86'`). Under `research/dxmt/src/d3d9/unix/`:
generated `d3d9_unix.c` (entries, `_32` variants, tables, init),
`d3d9_native_glue.cpp` (handle table, per-PEB registry, arena
sub-allocator, `guest_alloc`, `d3d9_native_process_teardown`). Under
`src/util/`: `wsi_platform_madeira.cpp`, `wsi_window_madeira.cpp`,
`util_madeira_compat.h`. Files to modify: `research/dxmt/meson.build`
(option `dxmt_madeira_native`, `-DDXMT_NATIVE=1 -DDXMT_MADEIRA=1`, keep
`DXMT_IOS` — `:171-174` keys on `system()=='windows'`, new darwin arm),
`src/meson.build:15-22`, `src/util/meson.build:26-47`, `src/d3d9/**`
(`guest_alloc` conversions, user32 excision behind `#ifdef DXMT_MADEIRA`,
multithread compat), `src/dxmt/dxmt_buffer.cpp:148-193` (`__i386__ &&
!DXMT_MADEIRA`), `dxmt_ring_bump_allocator.hpp:19-23` (+ A/B dropping
`seal_latest()` `:69-85`), `build/dxmt-ios/build.sh` (add TUs; need
`-fexceptions -frtti`), `build/dxmt-ios/build-pe.sh:60` (install shim AS
`d3d9.dll`), `.xtool/build-wine-i386.sh:36-41` (A/B name), `virtual_ios.c`
(binding branch; call `d3d9_native_process_teardown` from
`ios_wow_reclaim_dead_windows()` — §8.9-5), `ContentView.swift` launch
table (state test). A/B knob: ship both i386 modules — emulated frontend
as `d3d9-emulated.dll`, shim as `d3d9.dll`; `Documents/madeira-d3d9.txt`
(`native` default / `emulated`) read in the shim's DllMain; on `emulated`
the ten exports forward to `LoadLibraryA("d3d9-emulated.dll")`.

### 8.6 Phase 2 — guest-side command ring
Principle: the ring is a TRANSPORT, not a re-implementation — the native
side replays by calling the same `MTLD3D9Device::Set*`. One ring per
device, `VirtualAlloc`d in the window; `{head,tail,size,seq}` + records
`{u16 op; u16 len; u32 seq; POD args}`; single producer (serialised by the
shim's MULTITHREADED lock when requested), replay at flush. Records > ¼
ring force flush + direct call. Deferred (~40, essentially all per-draw
traffic): SetRenderState, SetTextureStageState, SetSamplerState,
SetTexture, SetStreamSource(Freq), SetIndices, SetVertexDeclaration,
SetFVF, Set*Shader, Set*ShaderConstant{F,I,B}, SetTransform,
MultiplyTransform, SetViewport, SetMaterial, SetLight, LightEnable,
SetClipPlane, SetClipStatus, SetScissorRect, SetNPatchMode,
SetSoftwareVertexProcessing, SetCurrentTexturePalette, SetPaletteEntries,
BeginScene, EndScene, Clear, DrawPrimitive, DrawIndexedPrimitive,
SetRenderTarget, SetDepthStencilSurface, resource SetPriority/PreLoad/
SetLOD/SetAutoGenFilterType, AddDirtyRect/Box, Query::Issue,
StateBlock::Apply, every final Release. Each either returns D3D_OK
unconditionally or has a shim-evaluable predicate (e.g.
`SetVertexShaderConstantF` `:11304-11315` needs only `m_vsConstFCount`;
`SetStreamSource` `:11506-11510` needs the stream count), written once in
`d3d9_api.py` and re-checked natively under `DXMT_DEBUG`. Synchronous
(flush then call): every Create*, CreateAdditionalSwapChain, CreateQuery,
state-block create/begin/end/Capture, Lock/LockRect/LockBox (DISCARD may
rename → new `pBits`), GetDC/ReleaseDC, Present(Ex), GetData/GetDataSize,
Reset(Ex), TestCooperativeLevel, CheckDeviceState, GetRenderTargetData,
GetFrontBufferData, StretchRect, ColorFill, UpdateSurface, UpdateTexture,
ProcessVertices, ValidateDevice, EvictManagedResources,
GetAvailableTextureMem, Draw*UP, SetCursorProperties, Set/GetGammaRamp,
SetDialogBoxMode, and every runtime-state Get* (`GetRenderState`'s
read-back quirks `:6313-6326` must NOT be shadowed). Local, no call:
~45 identity queries + QueryInterface/AddRef/non-final Release/GetType.
Flush triggers: ≥ ¾ full, any sync call, Present, Lock, GetData, device
destruction, EndScene watchdog. Ordering: per-record monotonic `seq`
asserted at replay. Expected: ~10-30 unix calls/frame instead of ~13,000.

### 8.7 Generator
`gen_d3d9_thunks.py` reads `d3d9_api.py` and emits `d3d9shim_thunks.c`
(every vtable slot filled; unimplemented = `E_NOTIMPL` stub, never a hole),
`d3d9shim_ops.h` (shared), `d3d9_unix.c` (entries, `_32` variants with
`ios_wow_host_ptr` conversions from shape tags, ring-replay switch),
`d3d9_unix_table.c` (both arrays), `_Static_assert`s on every mirror
(`COMPATIBLE_STRUCT32` pattern `airconv_thunks.h:164-168`). Guard rails:
generator owns BOTH tables and refuses length mismatch; slot number is the
ABI; "regenerate, do not edit" headers; disposition column is the single
source of defer/flush. Version handshake: shim sends a hash of
`d3d9_api.py` at init; native refuses a mismatch. ~8k generated lines
from ~400.

### 8.8 Test plan
1. Host-only: generator self-check; i386 PE build; `llvm-objdump -p`: imports
exactly KERNEL32/USER32/GDI32/api-ms-win-crt-*, NOT winemetal; exports
exactly the ten names; native half compiles with both tables present.
2. `build/x86-tests/d3d9-cube-x86.c` unchanged (exit 43); its first Lock()
pointer becomes the arena assertion (guest address inside the arena).
3. New `build/x86-tests/d3d9-state-x86.c`: every resource type, identity
round-trips (`SetTexture`/`GetTexture` same pointer, `GetSurfaceLevel(n)`
twice same pointer, `GetDevice`/`GetContainer`), refcounts after each
`Get*`, Lock/Unlock pointers < 4 GB, QueryInterface for
IDirect3DResource9/IDirect3DBaseTexture9; own exit code and
`MADEIRA-D3D9:` lines; launch-table entry.
4. Device: cube, state test, the game; `[prof]` (pe/jit d3d9 buckets → 0,
encode thread JIT → 0), `[d3d9-census]` calls/frame, `[d3d9-arena]`
high-water, fps A/B via `madeira-d3d9.txt` in one session.

### 8.9 Risks
1. Licence: shim is new GPL-3.0-or-later code; three pieces moved verbatim
from `d3d9.cpp` (validator `:85-316`, D3DPERF `:44-67`, `setupFpu`
`d3d9_device.cpp:512-521`) carry DXMT's LGPL provenance → extend
`research/dxmt/LICENSE-MADEIRA.md` and `THIRD-PARTY-NOTICES.md` (d3d9.dll
is now two modules with two provenances).
2. API drift vs `v0.4-d3d9`: every `src/d3d9` change behind `#ifdef
DXMT_MADEIRA`; `guest_alloc` defined to `aligned_malloc` off-Madeira;
record each site as §7.11 does; the `src/dxmt` reverts move TOWARD the tag.
3. Float state: (a) `setupFpu` must move to the shim (silent CPU-math
change otherwise); (b) DXMT's own float work now runs on ARM64 FPRs, not
under the guest x87 CW/MXCSR — almost certainly harmless, but a change
(the emulated build already used `-mfpmath=sse`, `meson.build:64-71`).
4. Exception propagation: a bad app pointer now faults in HOST code, not as
a guest c0000005 the app's SEH can catch. Mitigate: shim rejects NULL where
the API requires; every unix entry validates converted pointers with
`ios_wow_in_window()` (`ios_wow.h:70`) → `D3DERR_INVALIDCALL`; no C++
exception escapes (`catch(...)` → E_FAIL, as `d3d9_shader.cpp:424,582`).
Residual: a validly mapped but wrong pointer still faults hard.
5. MOST IMPORTANT — Metal object lifetime on guest leak: native objects and
Metal handles outlive the guest pseudo-process and hold host pointers INTO
the arena, i.e. into the 4 GB range `ios_wow_reclaim_dead_windows()`
replaces with PROT_NONE. Required: per-guest-process root keyed by the
same PEB the window registry uses; export `d3d9_native_process_teardown
(peb)`; call it BEFORE the PROT_NONE replace and before
`ios_jit_purge_window()`; assert the order: arena pointers dropped, then
Metal objects, then the remap.
6. Guest-window memory: net positive (staging rings, CpuPlaced backings,
argument buffers, DXMT thread stacks + 16 MB callret reservations leave
the window); what stays is exactly the Lock mirrors and MANAGED/SYSTEMMEM
mirrors (hundreds of MB possible; `d3d9_mem.cpp` reclamation off natively).
Arena grows in 64 MB chunks, `[d3d9-arena]` high-water line, exhaustion
names the cause (not opaque E_OUTOFMEMORY).
7. Ring correctness (Phase 2): wrong frames rather than crashes — `seq`
assert; `madeira-d3d9.txt` `native-nosync` makes every op synchronous for
one-run bisection; generator owns the classification.
8. Two-module ABI: opcode numbering + parameter-block layouts generated
from one description, one commit, build-hash handshake.

### 8.10 Sequencing
0. `[d3d9-census]` + `_d3d9_nop` micro-benchmark on the existing emulated
path → real calls/frame and ns/call on device.
1. `dxmt_madeira_native` build mode: `src/d3d9` + substrate compiled
iOS-arm64 into `libdxmt_unix.a`; `wsi_*_madeira.cpp`;
`util_madeira_compat.h`; no shim yet → compiles/links.
2. `d3d9_api.py` + generator; both tables; static asserts pass.
3. Shim: objects, identity, refcounts, vtables, `setupFpu`, arena, window
code → cube builds with the right imports.
4. Unix entries + `virtual_ios.c` binding + per-PEB teardown → cube passes
on device (exit 43).
5. `d3d9-state-x86.c` passes on device.
6. Game A/B via `madeira-d3d9.txt`; `[prof]` before/after → ≥ −10 % fps,
d3d9 buckets gone.
7. Phase 2 ring → calls/frame down two orders of magnitude; fps up.
Steps 1 and 3 can run in parallel once 2 exists.
Critical files: `research/dxmt/src/d3d9/d3d9_device.hpp` (134-slot
declaration the description must match), `d3d9_device.cpp` (hot bodies
`:6275,:6524,:11302,:11502`, `setupFpu` `:504-521`, user32 block
`:1744-2270`, `guest_alloc` sites), `src/nativemetal/wineunixlib.h`,
`build/ntdll-unix/virtual_ios.c` (`ios_bind_unixlib_table` `:7063`,
`load_builtin_unixlib` `:7083-7229`, `MemoryWineLoadUnixLib*` `:18959`,
window teardown), `src/winemetal/unix/winemetal_unix.c` (`_Foo32` pattern
`:4415-4460`, tables `:5077,:5243`), `src/d3d9/d3d9_buffer_map.hpp`.
- 2026-09-14 — Log 41 (mouse + native-build IPA, shim installed as
  d3d9.dll falling back to d3d9-emulated.dll — fallback WORKED, 30-40 fps
  in level 1). Mouse: works only with iOS AssistiveTouch on — confirmed
  by Apple's documentation that iPhone routes pointer devices ONLY through
  AssistiveTouch (no public HID path; `prefersPointerLocked` not honoured
  on iPhone), so the requirement cannot be removed by the app; with it on,
  `mouse path: gcmouse`, deltas fractional (AssistiveTouch-scaled), ~10-15
  handler events/s observed. Stutter cause hypothesis: AssistiveTouch
  synthesises TOUCHES for clicks → the game view's absolute touch path
  jumps the cursor (assigned: suppress synthesized touches while GCMouse
  is active, high-QoS handler queue, iPhone-aware lock, UI hint).
  Perf: `[d3d9-census] per_frame=117,841` (GetData/GetDataSize 49k each);
  `[srv-stats]` 4.4k/s, `event_op` 1.9k/s @55 µs + `select` 0.9k/s = the
  main↔render handoff → fastsync step 1 ASSIGNED (design in the ml951
  entry); `[fs-stats] open=1190/1987ms fail=1181` — failing opens 1.67 ms
  each (~11 fstatat + an unexplained remainder; `get_object_info=1122`
  per 10 s looks like the failure path hitting the server) → whole-path
  negative cache + phase breakdown ASSIGNED; `[vm-census]` off by default
  confirmed (`mach_msg2_trap<-warmer` gone). Threads: main 26-31 %, render
  31 %, encode 6-7 %. Resumed after rate limit: query busy-poll fix,
  generator gap fixes, farm install naming (emulated back as d3d9.dll).
- 2026-09-14 — fastsync step 1 DONE (ml952; wine `server/event.c`,
  `server/inproc_sync.c`, `server/thread.c`, `ntdll/unix/sync.c`,
  `server.c`, new `build/ntdll-unix/shims/ios_fastsync.h`). 8192 cells ×
  32 B in wineserver BSS, referenced across the archive boundary; a cell
  per handle-reachable event (`create_event_sync` only — device/async/
  process/thread syncs untouched). Client: seqlock-published cache keyed
  `(handle, pid)` + `gen`; `NtSetEvent`/`NtResetEvent` CAS the word and
  call the server only when `srv_waiters != 0` (Dekker: seq_cst store then
  load on both sides); single-handle non-alertable waits spin 96 then park
  on `os_sync_wait_on_address` ≤ 2 ms (`MADEIRA_FASTSYNC_CAP_US`, 50 µs–
  50 ms), then fall through to `server_wait` with the relative timeout
  reduced by the time spent; zero-timeout waits deliberately miss so the
  server produces `STATUS_TIMEOUT` + pending APCs. Server `signaled` CAS-
  claims SET→CLAIMED for auto-reset (so a client cannot steal a token the
  server already reported); WaitAll releases claims (`object_sync_unclaim`).
  PulseEvent disables the cell for good (folds state back into `signaled`).
  Knob `MADEIRA_FASTSYNC` (default on); banner `[fastsync] ON rev=ml952`;
  counters in `[srv-stats] futex(no server): fast hit/miss/wake/sleep`.
  Expected next log: `kinds: event_op` 19.3k → hundreds per 10 s,
  `select: w1 inf` 4.9k → <500, in-call 2.4 s → <1 s. If `w1 inf` stays
  high while `fast sleep` is large, handoffs exceed the cap → raise
  `MADEIRA_FASTSYNC_CAP_US`. Stress test `sync-x86.exe` (button "Fastsync
  stress": ping-pong parity, exactly-once over 4 waiters, manual release-
  all, 300 ms timeout; exit 46 = pass, 50–56 = which property broke).
  Semaphores not done (outside `event_op`, 0 % of measured traffic).
- 2026-09-14 — D3D9 native step 4 DONE (hooks 320/320 via generated
  `d3d9_native_gen.inc` + 6 hand-written; identity by find-before-create;
  arena root pinned per PEB; `D3D9_GUEST_PTR32` window assertion; binding
  branch in `load_builtin_unixlib` matches `d3d9shim` in match OR modname;
  `d3d9_native_process_teardown` before the PROT_NONE replace; shim ships
  as `d3d9.dll`, unset knob = forward to `d3d9-emulated.dll`, only
  `Documents/madeira-d3d9.txt` = `native` runs native; `TestCooperativeLevel`
  lock-free; `[d3d9-native-census]`; api hash `0xf49329770a2bc97b`).
  Log 42 (mid-round snapshot IPA the user sideloaded: fastsync ml952 +
  query fix + whole-path negative cache + profiler ml960 + shim forwarding):
  REGRESSION — not a hang: main thread guest AV reading NULL+0xc ~10 s in,
  right after the first three presents and a worker-created thread; the
  game's own crash-dump writer then called ReadProcessMemory on the NULL
  page and `NtReadVirtualMemory`'s `__TRY` did not catch the fault (caller
  on a stack outside TEB limits → "Exception frame is not in stack limits"
  → process gone). Native D3D9 was NOT active (forwarding confirmed). Died
  before the first `[srv-stats]` window, so no fastsync counters. Assigned:
  fastsync adversarial review + handshake stress (sync.c/server), negative
  cache review + `MADEIRA_FS_NEGCACHE` knob (file.c), fault-proof
  `NtReadVirtualMemory` via `mach_vm_read_overwrite` (virtual.c) +
  `readvm-x86.exe`. New generic knob file `Documents/madeira-env.txt`
  (NAME=VALUE, MADEIRA_*/DXMT_* only) for device-side bisects.
  Mouse: iPhone routes pointers only through AssistiveTouch (Apple);
  requirement cannot be removed; stutter mitigations shipped in this IPA.
- 2026-09-14 — fastsync ml962: DEFAULT OFF + three defects fixed
  (`ntdll/unix/sync.c`, `server/event.c`, `server/object.h`,
  `shims/ios_fastsync.h`, `shims/ios_srv_stats.h`, `server_ios.c`,
  `process_ios.c`, `x86-tests/sync-x86.c`). `MADEIRA_FASTSYNC=1` now
  ENABLES (unset/`0` = off, banner `[fastsync] OFF (MADEIRA_FASTSYNC=1
  enables)`); with it off `madeira_cell_alloc` returns −1 for every event,
  so every hook falls through to `signaled` and `get_inproc_sync_fd` is
  upstream's — off is the pre-ml952 path. (1) TORN CACHE PUBLISH —
  `madeira_fast_publish` marked the entry busy with a RELEASE STORE and
  then wrote the fields; a release store constrains only what precedes it,
  so compiler or core could land `handle`/`pid` BEFORE the odd marker and a
  reader saw a stable-looking entry with the NEW handle and the OLD
  cell/gen — a wait on handle B returning SUCCESS whenever unrelated event
  A was set, i.e. the log-42 NULL+small read in all three programs. Now a
  real C11 seqlock: relaxed odd marker, RELEASE FENCE, relaxed field
  stores, release fence, relaxed even marker; reader uses relaxed atomic
  loads and compares `handle`/`pid` inside the fenced region;
  `madeira_fast_close` tests the slot inside the section. (2) DOUBLE
  RELEASE — a client `NtSetEvent` with `srv_waiters != 0` CAS'd the cell
  and ALSO sent `event_op SET_EVENT`, whose `exchange(state, SET)` minted a
  second token if a fast waiter had consumed the first: two waiters
  released by one SetEvent. New private opcode `MADEIRA_EVENT_OP_WAKE`
  ('MAWA', `op` is a plain int + `default:` arm ⇒ no protocol.def change)
  runs `wake_up()` only, so `event_sync_signaled`'s CAS decides whether a
  token still exists. (3) LOST SET ON `MADEIRA_CELL_CLAIMED` — the client
  CAS'd CLAIMED→SET and `event_sync_satisfied` then stored RESET,
  swallowing the set; the fast op now yields to the server on CLAIMED
  (server is single-threaded, so the request is applied after the claim
  resolves). Also: the negative learn answer was NEVER cached (on iOS the
  reply is always `STATUS_NOT_IMPLEMENTED`, which the old code dropped), so
  every wait on a thread/process/mutex/semaphore/timer/file re-asked —
  `get_inproc_sync_fd` was the #1 request kind at 925–1837 per 10 s; now
  cached (negative entries are fail-safe: they can only route to the
  server). Plus: no fast path for a caller with no TEB (`pid == 0`),
  reply cell index bounds-checked, `event_sync_remove_queue` reads
  `event->cell` before `remove_queue`'s `release_object`. Observability:
  `[srv-stats] fastsync cache: learn_ev/learn_none/relearn/stale_gen/
  evict`, and `ios_srv_stats_report_now()` from the MADEIRA-EXIT path so a
  run that dies before the first 10 s window still leaves counters.
  `sync-x86.exe` gains tests 5–9 (fresh-event thread-start handshake ×20k
  with a NULL-pointer check, server-queued vs fast waiter exactly-once,
  manual "loader done" under cell churn, late-set timed waits, heap-node
  handshake ×5k); exits 57–61 name them, 46 = pass. Must be run BOTH ways:
  default (server path) and `MADEIRA_FASTSYNC=1`.
- 2026-09-14 — Logs 43/44/45 (same ml952 snapshot): a 64-bit title, the
  UE3 game and a VN boot menu (twice) all died with guest NULL+small reads
  seconds after thread creation → common cause = fastsync torn cache
  publish (ml962 entry above). Also seen: `get_inproc_sync_fd` 925-1837
  per 10 s (negative learn never cached; fixed), the VN launcher exiting 1
  ("not installed"), and `wholeneg=h31/p32` hits with no stores.
  Whole-path negative cache ml913 review (`file.c`): (1) stamp read AFTER
  the absence proof — the `<leaf>?` reparse probe re-ran `find_file_in_dir`
  and re-stamped, and the after-walk `fstatat` fallback stamped later still,
  so a create landing inside one directory scan produced an entry that
  never went stale (now `ios_dir_stamp_ok`: a stamp is usable only if read
  before the work that proved absence; fallback deleted); (2) key was
  case-FOLDED while the resolver prefers exact case per component (now the
  exact requested spelling); (3) whole-path and per-component entries
  shared a table AND a key string (`'\1'` namespace byte); (4) `readdir`
  error cached as absent (errno captured, store suppressed). DEFAULT OFF:
  `MADEIRA_FS_NEGCACHE=1` enables; `[fs-stats]` prints `wholeneg=OFF(...)`;
  `[fs-neg] hit key=… stamp_dir=…` first 16 distinct keys when on. Test
  `fs-x86.exe` (button "FS lookup stress", exit 47; 61-66 name the phase)
  — proven to catch the old semantics on a host model of the resolver.
  `NtReadVirtualMemory` iOS (`virtual_ios.c:19841-20072`): three-tier
  no-fault copy (vprot-proven → memmove; else one `mach_vm_read_overwrite`;
  else page-by-page → `STATUS_PARTIAL_COPY` with the real count); write
  path pre-checks the source. Test `readvm-x86.exe` (button
  "ReadProcessMemory", exit 48) incl. a read from a hand-switched stack.
  Proposal (not done): port the ml377 "bad frame on step 0 = ordinary
  unhandled exception" rule to `wine/dlls/ntdll/signal_arm64.c:274`, and
  widen `is_valid_frame()` on iOS to accept the currently executing stack.
  On-screen controls dying after a stray game-view tap: `ControlOverlayView`
  keyed touches by `ObjectIdentifier(UITouch)`; UIKit recycles UITouch
  objects, `begin()` overwrote an unclosed track without releasing its
  owner, and `InputGuard.sync()` posts the union of owners → a phantom
  owner pins a key/button DOWN for the session (re-press adds nothing, so
  "the button does nothing"). The game view used `touches.first` with one
  shared state set, so a second finger forged the click that triggered the
  arbitration. Fix: `reconcile(event)` rebuilds the table from UITouch
  identity on every callback (stale-gone/phase/view/absent), `begin()`
  finishes a reused address first, game view owns exactly one finger.
  Logs: `[input] recover region=… reason=…`, 5 s `[input] health
  held>5s=[…]`, `owners=N` in the InputGuard heartbeat. Removed: the
  on-screen aim/mouse joystick button, `JoystickPadState.aim`, the
  landscape "Aim" mapping (gamepad right stick still uses AimStickDriver).
  New: `Documents/madeira-env.txt` generic env passthrough.
- 2026-09-14 — Logs 46-54 (ml962 build, both features default off). The
  32-bit UE3 game RUNS AGAIN at "good framerate" (user). Triage:
  `sync-x86` with fastsync ON → exit 56: "timed wait returned after 0 ms,
  wanted 300 ms" (fast timed waits return instantly); the game with
  fastsync ON sits on its loading screen with `create_event`+`close_handle`
  ~8k/s and a critical section held > 60 s (a timed-wait loop gone busy);
  `readvm-x86` → 67 (`WriteProcessMemory` to PAGE_EXECUTE_READ refused
  server-side); `fs-x86` passed phases 1-6 (log rotated before the exit).
  Gameplay profile (10 min): `swtch_pri<-NtYieldExecution` 15.2 % +
  `__ulock_wait2<-NtDelayExecution` 8.6 % + `swtch_pri<-NtDelayExecution`
  3.7 % = ~28 % of all CPU in the Sleep(0) ladder (2.2 M Sleep(0)/10 s,
  435 k yields, 260 k parks); jit 31.6 % (63 % of JIT samples in TSO
  blocks, tso/mem 0.39); per-frame `dup_handle/get_object_info/
  close_handle/get_thread_context` ≈ 177/s and `set_thread_context` 295/s
  with no obvious owner; `[d3d9-census] per_frame=30,526` (was 117,841).
  Relative mouse: camera stops turning "after a bit" while the pause-menu
  cursor still moves (delta path vs cursor path). 64-bit title: same crash
  as log 43 — a push at sp≈0x10 right after `signal_set_full_context`,
  with `set_thread_context` traffic (context restore with a null SP).
  VN A: whole app died — a new 32-bit thread got a TEB OUTSIDE the 4 GB
  window (x18=0x70ffec0000; creator TEB also outside) → wild TEB32 reads
  → `[redeliv] terminating process`. VN B: boot-menu AV in 32-bit ntdll
  reading NULL+0x63; launcher "not installed" (exit 1); game exe exits 0
  in ~1 s with no window. VN C: error dialog, exit 0. Assigned: fastsync
  timed-wait + WriteProcessMemory RX; VN boots + `Documents/fonts` install;
  relative-mouse delta path + `[relmouse]` diagnostics; display-mode
  control (fit/fill/stretch); Sleep(0) ladder redesign + `[srv-stats]`
  caller attribution + TSO A/B recipe. 64-bit context-restore crash queued.

- 2026-09-14 — Relative-mouse camera death: ROOT CAUSE FOUND IN THE SERVER'S
  RAW-INPUT ROUTING, plus `[relmouse]` diagnostics at all three stages
  (ml667; `build/wineserver/queue_ios.c`, `build/win32u-unix/driver_ios.c`,
  `app/Madeira/Winios/Winios.m`, `app/Madeira/ContentView.swift`).
  Log 46 clears the app side completely: relative `drv_post_mouse`
  (`flags=0x1`) is still arriving at t+320 s (#2059, `drain move` n=2049),
  the ring never drops a move, and the relative-mode tap-click at t+301 s
  hit-tests to the game window at cursor (367,283) — so the finger, the ring,
  the driver, the desktop cursor and `gameTouch` are all alive when the
  camera is dead. Motion therefore reaches the server and dies between
  `queue_mouse_message` and the game's `WM_INPUT`.
  Mechanism: pointer motion has two consumers with different routing.
  `WM_MOUSEMOVE` is routed by HIT TEST (`find_hardware_message_window` →
  `shallow_window_from_point`), so the menu cursor keeps working as long as
  the game's window is under the pointer. `WM_INPUT` is routed by FOREGROUND:
  `queue_mouse_message` calls `dispatch_rawinput_message` only when
  `get_foreground_thread()` returns a thread, and that function resolves
  `foreground_input->focus`, else `->active`, else the window the DRIVER
  passed. Our driver deliberately passes `hwnd = NULL` (driver_ios.c:88, so
  the legacy path hit-tests), so the "assume the receiving window is"
  fallback the upstream comment promises has nothing to fall back to — and
  three ordinary events leave `focus`/`active` empty for good:
  `DECL_HANDLER(set_foreground_window)` stores `foreground_input = NULL`
  whenever the window made foreground IS the desktop window;
  `thread_input_destroy()` clears it when the foreground thread exits and
  nothing restores it; `thread_input_cleanup_window()` zeroes `focus` and
  `active` when their window is destroyed. From that moment every game
  reading the camera from raw input or DirectInput stops turning, silently
  and permanently, while the cursor keeps moving. Second, independent way in:
  `DECL_HANDLER(update_rawinput_devices)` drops the process out of
  `rawinput_processes` on an empty registration (RIDEV_REMOVE) and re-adds it
  ONLY by walking the input desktop's thread list — dinput takes that branch
  on every Unacquire/Acquire pair (`input_thread_update_device_list`, a pause
  menu), from its own hidden `di_em_win` thread, so a process whose thread is
  not on that list never comes back.
  Fixes (both generic, both strictly widen a path that currently delivers
  nothing): `get_foreground_thread()` now falls back to the caller's window
  and then to `desktop->cursor_win`, the same ground truth the legacy path
  uses — `focus`/`active` still win when they resolve; and
  `update_rawinput_devices` re-arms the registering process itself when the
  desktop walk did not cover it, guarded on list membership so it only fires
  in the broken case.
  Diagnostics — one `[relmouse] ml667` line per stage, every 5 s, only while
  RELATIVE moves are arriving (i.e. only in Relative pointer mode):
  `src=touch` (ContentView) posts/acc/trunc plus claims/refused and the
  `gameTouch` owner's phase and view, which is what would expose a recycled
  UITouch stranding the one-finger claim; `src=drv` (driver_ios) relative
  posts, failures, accumulated delta, `NtUserGetCursorInfo` position and the
  foreground window/thread as win32u sees it; and the server line: `rel_in`
  / `move_q` / `raw_disp` / `raw_q` with the four drop reasons
  (`nofg` no foreground thread, `nodev` no registered mouse device left,
  `notfg` not the foreground process without RIDEV_INPUTSINK, `nowin` no
  target window), the cursor position and clip rect, `cursor_win`,
  `foreground_input`/`focus`/`active`, the size of `rawinput_processes`, and
  whether the cursor window's process is still listed with which device
  flags and `hwndTarget`. Next log: find the line where `rel_in` keeps
  climbing and `raw_q` stops — the drop counter that moves with it names the
  gate, and `listed=0` / `devs=0` would mean the dinput re-registration path
  is the one still failing. `[input] ring` now also carries `rel=`.
  Built: `libwin32u_unix.a` and `libwineserver.a` rebuilt clean; app relinked.

- 2026-09-14 — Three 32-bit engines, four generic bugs (logs m2/m51/m52/m53/m54).
  **1. A recycled TEB from another pseudo-process killed the app on thread
  start.** `[teb-tsd] thread tid=0098 raw=0x70ffec0000` — a thread of the
  32-bit pseudo-process whose window is `B=0x7100000000` started on a TEB
  OUTSIDE that window, so `init_teb` derived its TEB32/FS base by truncating
  the host address and every TEB access from x86 code read guest
  `0xffecxxxx`: `BUS ... addr=0x71ffec2018` (= B + truncate(TEB) + teb_offset
  + `NtTib.Self`), 2,000 redeliveries, `[redeliv] terminating process`, whole
  app gone. `0x70ffec0000` was tid `0084`'s TEB (m53:2497, a 64-bit thread of
  a different pseudo-process, out of the SESSION block). m54 shows the same
  thing independently: tid `00b0` got tid `0094`'s `0x70ffea0000`, and in both
  runs the NEXT thread created got the correct in-window block. Root cause:
  `virtual_free_teb` (`build/ntdll-unix/virtual_ios.c`) chose the free list
  with `ios_wow_slot_current()` — **the window of whoever ran the free**.
  `exit_thread` (`thread_ios.c`, the `prev_teb` handoff) does not free its own
  TEB; it frees the PREVIOUS exiting thread's, and those two threads belong to
  different pseudo-processes routinely. A session-block TEB freed by a 32-bit
  thread therefore landed on that window's free list and the next thread of
  that process popped it. Fix: key the list on the ADDRESS of the block
  (`ios_wow_live_slot_for_addr`), which is exact in both directions and makes
  the old one-directional guard a sub-case. Plus a named, local failure
  instead of a task-wide death: `virtual_alloc_teb` now refuses a wow thread
  whose block is outside its window with `[teb-window] REFUSING thread` and
  `STATUS_NO_MEMORY` (the `done:` path in `RtlCreateUserThread` already closes
  the handle and the request pipe, so the guest just gets a failed
  `CreateThread`). Cross-process creation needs no change: `NtCreateThreadEx`
  for a foreign process goes through `APC_CREATE_THREAD`
  (`thread_ios.c:1621`), so `virtual_alloc_teb`/`init_thread_stack` always run
  ON a thread of the target process and already resolve the target's window.
  **2. AFD/winsock pointers crossed the boundary untranslated.** m52: a 32-bit
  program's startup socket call faulted in native code —
  `[mach_exc] UNHANDLED pc=...sock_ioctl_send+0xe8 addr=0xe8fa9c`, backtrace
  `sock_ioctl` -> `NtDeviceIoControlFile` -> `__wine_syscall_dispatcher` —
  reading the WSABUF array at the bare guest address `0xe8fa9c` instead of
  `B+0xe8fa9c`; the program then put up a modal error dialog
  (`[winios-tree] 0xc00b0 ... style=94c801c4` = icon + one-line static + OK)
  and exited 0. `wow64_NtDeviceIoControlFile` translates `in_buf`/`out_buf`
  but nothing translates the pointers INSIDE an AFD request, because on
  classic WoW64 they need no translation. Fixed in
  `wine/dlls/ntdll/unix/socket.c`: `afd_guest_ptr()` adds `ios_wow_base()`
  (NULL stays NULL) at every guest->host site — SENDMSG/RECVMSG
  `buffers_ptr`/`addr_ptr`/`addr_len_ptr`/`control_ptr`/`ws_flags_ptr`,
  `IOCTL_AFD_RECV`'s `params32->buffers`, both per-WSABUF loops,
  `wow64_translate_control`, and TransmitFile's `head_ptr`/`tail_ptr`. The
  struct-layout switches also moved from `in_wow64_call()` to
  `ios_wow_base() != 0`, for the same reason stage C review F3 changed
  `virtual_alloc_teb`: `is_wow64()` is SESSION-wide in this fork, so a 64-bit
  pseudo-process sharing a session with a 32-bit one reads `afd_wsabuf_32`
  off a 64-bit WSABUF array.
  **3. A 32-bit process cannot spawn a 32-bit process — ONE window slot.**
  Not a registry or file problem: m51:5203-5215 shows the launcher's
  `CreateProcess` returning `c00000e5` because
  `[wow-window] B=0x7100000000 REJECTED: a 32-bit pseudo-process is running in
  this window right now` and `B=0x7200000000 REJECTED: the 4GB range is not
  free`. The launcher's "not installed" dialog is the CONSEQUENCE, and its
  `[srv-stats]` shows it did essentially no registry work at all. The band
  `[0x7038000000, 0x7400000000)` holds exactly three 4 GB-aligned slots and
  the `[cage] holdback` (`IOS_CAGE_BASE 0x7200000000 + 8GB-64KB`,
  `virtual_ios.c:1412`) covers both of the other two, unconditionally, at
  `virtual_init` time, for a V8/cppgc reservation that only a CEF session ever
  asks for. NOT changed here — it trades directly against a documented CEF
  invariant and belongs to that owner. Minimal recommended change: when
  `ios_wow_window_pick()` finds no slot and `ios_cage_holdback_live` is still
  1 (nobody has taken the 8 GB), carve `[0x7200000000, 0x7300000000)` out of
  the holdback as a second window — its FB3 guard is then borrowed from the
  remaining holdback exactly as slot 0 borrows from it today — and log the
  trade. A CEF session and concurrent 32-bit pseudo-processes cannot both fit
  in 64 GB; whichever actually asks should win over the one that never does.
  **4. Missing farm modules.** `wbemprox.dll` is in NEITHER farm, so
  `system32\wbem` is empty, `CoCreateInstance(CLSID_WbemLocator
  {4590f811-1d3a-11d0-891f-00aa004b2e24})` fails, and BOTH 32-bit programs in
  m2/m51 die or give up within a few hundred instructions of that line — they
  reach it through `dxdiagn.dll` asking WMI about the display adapter
  (m2:4827-4829 for the boot stub, whose fault is then at
  `USER32+0x52390 = cmpb $0,(%esi,%edi)` in `WPRINTF_GetLen`, scanning a
  garbage `%s` argument of `0x63` — NOT ntdll, as the load addresses show
  ntdll at guest `0x7BF40000` and USER32 at `0x7BC00000`; m51:4393-4395 /
  m2:5632-5634 for the game exe, which exits 0 without ever calling
  `CreateWindow` or entering a message loop — its `[srv-stats]` shows no
  `get_message`, no `set_queue_mask`, no `open_key`). Added
  `wbemprox wmiutils wbemdisp` (+ `wmic`/`mofcomp`) to
  `.xtool/build-wine-i386.sh`, along with the DirectShow/VfW set a 32-bit
  multimedia program needs and neither farm has (`quartz devenum qcap qedit
  amstream mciqtz32 msdmo`, the `iccvid msvidc32 msrle32` VfW codecs and the
  `*.acm` audio codecs) and `riched20 riched32 msftedit usp10 mlang`. The
  farms are FLAT but WMI's registered `InprocServer32` paths are
  `C:\windows\system32\wbem\<name>`, so `WineProcessBridge.m` now also links
  wine.inf's five wbem modules into `system32\wbem` and into each farm's
  `wbem` (`[WineProc] system32\wbem: N/5 links`). The aarch64/arm64ec farms
  need the same three modules — that build script is not in scope here.
  Still open and unexplained on that path: every 32-bit run logs
  `fixme:actctx:parse_depend_manifests Could not find dependent assembly
  "Microsoft.Windows.Common-Controls" (6.0.0.0)` and
  `err:commdlg:DllMain failed to create activation context ... 14001`, because
  the prefix has no `C:\windows\winsxs\manifests` at all — Wine would install
  `dlls/comctl32_v6/comctl32.manifest` there. Non-fatal in Wine, but it means
  no program in this prefix can ever get a v6 common-controls activation
  context.
  **Fonts.** The backend is ALIVE, contrary to first appearances: freetype is
  statically linked and merged into `libwin32u_unix.a`
  (`build/win32u-unix/build.sh`, `freetype_ios.c`), `font_init()` ->
  `load_file_system_fonts()` scans `\??\C:\windows\fonts` FIRST, and the
  prefix template ships 14 TTFs there plus the `HKLM\...\CurrentVersion\Fonts`
  values. The single `[file-fail] #20 ... Madeira.app/fonts` in every log is
  the SECOND scan, Wine's DATA-dir fonts (`get_fonts_data_dir_path`), which
  the bundle does not ship; `[file-fail]` only logs failures, so the
  successful `C:\windows\fonts` scan leaves no line and the absence of the
  string "Fonts" in the logs proves nothing either way. `load_mac_fonts` is
  deliberately stubbed (`CTFontCollectionCreateFromAvailableFonts` -> NULL).
  New: any `.ttf/.otf/.ttc/.fon` the user drops into `Documents/fonts/` is
  installed into the prefix's `drive_c/windows/Fonts` at session start
  (`madeira_install_user_fonts`, called from `madeira_seed_prefix_if_needed`
  so it lands before the wineserver starts), logging
  `[fonts] installed <name>` per file and
  `[fonts] installed N from Documents/fonts`. No registry write is needed for
  that directory: Wine's own `load_directory_fonts` plus the
  `HKCU\Software\Wine\Fonts\Cache` key ARE the install, and
  `HKLM\...\CurrentVersion\Fonts` only carries fonts living OUTSIDE
  `C:\windows\fonts` (written by `update_external_font_keys()` from the face's
  real name, which the app side cannot know without parsing the TTF name
  table).
  **`[redeliv] terminating process` — not this file's to change.**
  `build/ntdll-unix/signal_arm64_ios.c:6950-6952` does
  `task_terminate(mach_task_self()); _exit(76); for(;;) pause();` — it kills
  the whole Mach task, i.e. every pseudo-process, for one wedged thread.
  Minimal change recommended: dump the forensics exactly as today, then take
  the pseudo-process path instead of the task path — `abort_process()`
  (`thread_ios.c`, which exists precisely because `_exit()` kills the app) for
  the faulting thread's own pseudo-process, keeping `task_terminate` only as
  the fallback when the faulting thread is the session's own boot thread or
  has no resolvable PEB. `process_ios.c:944` already records that
  per-pseudo-process termination is an open bug, so that owner should land it.
  Built: `libntdll_unix.a` rebuilt clean (30/30); `WineProcessBridge.m` passes
  `-fsyntax-only` against the iPhoneOS SDK. Next log: `[teb-window]` must
  never appear and every `[teb-tsd] thread` inside a 32-bit pseudo-process
  must read `0x71xxxxxxxx`; `[WineProc] system32\wbem: 5/5`;
  `[fonts] installed N`; no `sock_ioctl_send` fault and no
  `com_get_class_object ... {4590f811-...}`; and a second `[wow-window]` slot
  line if the cage trade is taken.
- 2026-09-14 — fastsync ml972 + server-side WriteProcessMemory
  (`ntdll/unix/sync.c`, `build/ntdll-unix/server_ios.c`,
  `build/wineserver/mach_ios.c`, `x86-tests/sync-x86.c`,
  `x86-tests/readvm-x86.c`). Four defects, all found from the ml962 device
  run (`MADEIRA_FASTSYNC=1`): `sync-x86.exe` exit 56 with "timed wait
  returned after 0 ms", the 32-bit title stuck on its loading screen with
  `create_event=79625 close_handle=79333` per 10 s and `[hot-lock]
  waiters=3` held > 60 s, and `readvm-x86.exe` exit 67
  `err=5 put=0`.
  (1) TIMED WAIT RETURNED IMMEDIATELY — `madeira_fast_wait`'s fall-through
  re-read the clock and subtracted the WHOLE measured interval from the
  caller's relative timeout, so the remainder was a MEASUREMENT where the
  design intends an INVARIANT: the fast path may consume at most
  `budget_ns = min(cap, the caller's timeout)`, never more. Any overshoot
  came straight off the caller (`left <= 0` → `store->QuadPart = 0` →
  `server_wait` with a ZERO timeout, which is Wine's POLL: `STATUS_TIMEOUT`
  with no wait at all). And there WAS a systematic overshoot: the budget was
  measured on `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`, which keeps
  incrementing while the system is asleep, while `madeira_fast_park` parks on
  `OS_CLOCK_MACH_ABSOLUTE_TIME` / `__ulock_wait`, which do not — two clocks
  for one interval, differing by exactly the sleep. Fixed both ends:
  `madeira_now_ns()` is now `CLOCK_UPTIME_RAW` (== `mach_absolute_time`, the
  clock the park counts, with a `mach_absolute_time`+timebase fallback because
  `clock_gettime_nsec_np` reports failure as 0), and the elapsed time is
  CLAMPED to `budget_ns` before it is subtracted, so `left > 0` whenever the
  caller's timeout exceeded the cap and `left == 0` only when the cap WAS the
  whole timeout. The park loop also got a 64-round bound so no clock
  behaviour can turn it into a spin. `os_sync_wait_on_address_with_timeout`'s
  `timeout_ns` is nanoseconds (SDK header checked) and the `__ulock_wait`
  fallback's µs conversion was already right — units were not the bug.
  (2) `madeira_fast_close()` WAS NEVER CALLED — `dlls/ntdll/unix/server.c`
  has carried the call since ml952, but `build/ntdll-unix/build.sh`
  substitutes `server_ios.c` for `server.c`, so the compiled `NtClose` (and
  the `DUPLICATE_CLOSE_SOURCE` path, and the APC-result path) dropped
  nothing from the handle→cell cache. `evict=0` in `[srv-stats] fastsync
  cache:` was a dead call site, not a quiet cache. This is a correctness
  bug, not a miss: a positive entry is validated against the CELL's
  generation, and a cell lives as long as the EVENT, not as long as the
  handle — so close one handle to an event something else still holds, let
  the handle VALUE be reissued, and `(handle, pid, gen)` all still match: a
  `NtSetEvent` on the new handle signals the OLD event and a wait on it is
  satisfied by the OLD event's token. Now called at all three sites.
  (3) A PARKED WAITER DID NOT RE-TEST `gen` — the park is the one unbounded
  pause in `madeira_fast_wait`, and across it the event can be destroyed and
  the cell handed to a new one (`madeira_cell_free` stores DISABLED and wakes,
  but `create_event` can re-alloc and store RESET/SET before the woken thread
  runs, and the word is then indistinguishable). The woken thread would
  CONSUME the new occupant's auto-reset token — a SetEvent delivered to a
  thread that never waited, and the real waiter never woken; with a loader
  churning events at 8 k/s that is a permanently lost handshake, which is what
  `[hot-lock] waiters=3` for > 60 s looks like. `madeira_fast_lookup` now
  returns the generation and the loop re-checks it after every park
  (`madeira_cell_alive`), as does `madeira_fast_event_op` before each CAS.
  (4) THE `waiters` COUNT COULD GO NEGATIVE — `madeira_cell_alloc` zeroes
  `waiters` for a recycled cell, so a stale parked thread's decrement took the
  NEW occupant to −1; the next genuine waiter's `waiters++` brought it back to
  0 and a setter's `if (waiters) wake` then did nothing, so that cell's every
  future handoff paid the full cap. The decrement is now skipped when the
  generation moved (over-counting only ever costs a spurious wake).
  Observability: `fastsync cache:` prints `value(running total)` for all five
  counters — a warm cache legitimately learns nothing for minutes, so a
  window delta of 0 could not distinguish "quiet" from "not wired", and a
  total still 0 after minutes now says unambiguously "go look at the call
  site".
  (5) WriteProcessMemory ALWAYS FAILED — `NtWriteVirtualMemory` has no
  current-process shortcut, so every write becomes a `write_process_memory`
  request, and that needs `get_process_port()` = `process->trace_data`, which
  is always 0 here (no per-guest Mach task). Every WriteProcessMemory on this
  port returned `STATUS_ACCESS_DENIED`, not just the PAGE_EXECUTE_READ one
  the test noticed. `get_process_port()` is NOT changed (its comment records
  that returning `mach_task_self()` also activates `read_process_memory` and
  regressed a guest into a SEGV + loader-lock deadlock). Instead
  `write_process_memory` gets an iOS same-task path, taken only when the
  target is the CALLER's own process (a 32-bit address was translated through
  the calling process's 4 GB window, so cross-process keeps today's
  behaviour exactly — this change can only turn a failure into a success):
  per Mach region, (a) already writable → store; (b) a live dual-map RW alias
  covers it (`ios_jit_anon_alias_lookup`, weak) → store through the alias,
  changing no protection, so an executable view never loses EXECUTE — the
  same mechanism `signal_arm64_ios.c`'s store emulator uses; (c)
  `vm_protect(current|WRITE)`, then `READ|WRITE`, then `READ|WRITE|COPY` —
  the same ladder and the same ordering rationale as `mprotect_exec`'s RW
  path (plain first so a MAP_SHARED section view is not privatised, COPY only
  for a mapping whose maxprot has no WRITE) — then restore, with a failure to
  restore EXECUTE logged as `[srv-wpm]` rather than swallowed; (d) otherwise
  `KERN_PROTECTION_FAILURE`. A `VM_PROT_NONE` region is refused outright.
  `PAGE_READONLY` is untouched: Wine refuses it one level up in
  `WriteProcessMemory`'s `default:` arm and never sends the request.
  Tests: `sync-x86.exe` (exit 46) test 4 now has THREE timed cases and keeps
  exit 56 — (a) 300 ms, longer than the cap, must be neither early nor
  absurdly late; (b) 1 ms, SHORTER than the cap, the one case where a zero
  remainder is right; (c) twenty 10 ms waits must add up to ≥ 100 ms, which is
  the direct regression test for "a timed wait that returns instantly", the
  shape that turns a loader's retry delay into a busy loop. Test 8 (late set)
  is unchanged and must still pass. `readvm-x86.exe` (exit 48) gains check 4c,
  a plain PAGE_READWRITE WriteProcessMemory under exit 67 — the case that was
  equally broken and had no coverage, so a fix that only understood
  executable pages could not pass. Both must be run BOTH ways: default
  (server path) and `MADEIRA_FASTSYNC=1`. Banner is now
  `[fastsync] ON rev=ml972`.

- 2026-09-14 — Log 46 (10 min, 40-60 fps): **the spin was never mostly
  `Sleep(0)`, and the per-frame context traffic was ours**. Three findings, two
  fixed, one measured.
  (1) `[srv-stats]` per 10 s: `sleep0` 1.27-2.01 M, `park` 108-196 k — and
  **`yield_sc` 8.2-14.3 M**, i.e. **1.15 M `sched_yield`/s**, seven times the
  `Sleep(0)` rate. `[prof]` puts it in one place:
  `swtch_pri<-NtYieldExecution+0x28` **13.9-15.2 % of ALL CPU**, `kern by
  thread` **100 % tid=00c0** (the render thread). That entry cannot be the
  ml950-ml960 ladder: `ios_delay_zero` is inlined into `NtDelayExecution`, so
  the ladder's own yield and park show as `NtDelayExecution+0x410` (2.8-3.7 %)
  and `__ulock_wait2<-NtDelayExecution+0x3f4` (6.6-8.6 %). `NtYieldExecution`'s
  exported entry has only three callers — win32u's `ios_pump_yield` (capped at
  5 k/s), `server_wait`'s poll streak (the whole process makes 3.7 k
  requests/s), and the guest's own `SwitchToThread` through wow64 — and the
  ladder can account for at most ~60 k of 11.5 M. So ~99.5 % of it is ONE
  32-bit guest thread spinning on `SwitchToThread`, with no throttle at all.
  Three rounds of Sleep(0) tuning had been aimed at the smaller spin.
  FIX (ml970, `sync.c`, `NtDelayExecution`/`NtYieldExecution` region only): ONE
  governor for both entry points, indexed by **elapsed spin time** instead of
  call count, and bounding the **kernel-entry rate** instead of the call rate.
  Between kernel entries: an `isb sy` pause that doubles every 8 calls (8→256,
  ~100 ns→~3 µs) — a userspace poll adds no handoff latency and costs no
  syscall. Kernel entries at most one per gap, gap by elapsed spin:
  `<50 µs`→20 µs, `<500 µs`→100 µs, `<5 ms`→300 µs, `≥5 ms`→500 µs; parks
  15/15/30/60 µs, hard cap 1 ms. The FIRST kernel entry of a streak is a real
  `sched_yield()`, so an isolated `Sleep(0)`/`SwitchToThread` — pacing, not
  spinning — is byte-for-byte unchanged, and a once-per-frame caller always
  starts a fresh streak (2 ms window). Parks stay SHORT on purpose and do not
  grow to fill the gap: the park hands the core over, it does not sleep through
  the handoff, so the chance a peer's progress lands inside a park is
  60/500 = 12 % and added handoff latency is 0 at the p50, ≤60 µs at the p88 —
  against ml960's 200 µs park. Anti-livelock is now STRONGER than the old
  ladder's "every 8th call": no governed thread spins more than 500 µs of wall
  time without descheduling, at any rung and any loop rate. Per-thread EWMA of
  finished-streak duration lets a thread whose spins historically run long skip
  the cheap rung (never past rung 2). Per-call-site keying was rejected with a
  reason: the wow64 CPU area's `Eip` is only valid after FEX flushes JIT state
  into it (itself a server round trip), and the unix-side return address is the
  syscall dispatcher for every 32-bit caller alike — so the estimator is
  per-thread, and the full distribution goes to the log instead.
  NEW LINES: `[sleep0] streaks= calls: sleep0= yield= | syscalls: yield= park=
  (N/s) | per-call=X.XXX% | to-progress p50= p80= warm= rev=ml970` plus
  `[sleep0]   hist calls:` and `[sleep0]   hist us:` (log2 buckets, a streak
  ends exactly when the thread makes progress, so the µs histogram IS the
  time-to-progress distribution the ladder is calibrated against).
  Arithmetic for the target: 2 permanently spinning threads × 1/500 µs = 4 k
  syscalls/s (target ≤5 k), from ~1.17 M/s today — a ~290× reduction.
  (2) `dup_handle=1770 get_object_info=1770 close_handle=1772
  get_thread_context=1770` and `set_thread_context=2950` per 10 s — 3 to 5 per
  frame, in a process where nothing should touch a thread context per frame.
  **Owner found by arithmetic, no instrumentation needed**: FEX's
  `BTCpuGetContext`/`BTCpuSetContext` (`FEX/Source/Windows/WOW64/Module.cpp`)
  each open with `FEX::Windows::ValidateHandleAccess` (→ `NtQueryObject` →
  `get_object_info`) + `DupHandle` (→ `dup_handle`) + `GetThreadTLS` (→
  `get_thread_info`) and close with `NtClose` (→ `close_handle`); Get then does
  `FlushThreadStateContext` (→ `set_thread_context`) + `RtlWow64GetThreadContext`
  (→ `get_thread_context`), Set does Flush + Set + Get. With G calls of
  BTCpuGetContext and S of BTCpuSetContext that is exactly G+S objinfo, G+S dup,
  G+S close, G+S get_ctx and **G+2S set_ctx** — and G=590, S=1180 reproduces all
  five measured numbers exactly. Every internal caller in
  `wine/dlls/wow64/syscall.c` (32-bit exception dispatch, `NtContinue`,
  `NtSetContextThread`, APC/callback) passes `GetCurrentThread()`, the
  PSEUDO-handle. So the triple was validating, duplicating and closing a handle
  to the calling thread itself — and the duplicate is what made the rest
  expensive, because Wine's `get_thread_wow64_context`/`set_thread_wow64_context`
  (`dlls/ntdll/unix/signal_arm64.c`) both start with
  `BOOL self = (handle == GetCurrentThread())` and read/write the caller's own
  CPU area with NO server call when that holds; a duplicated handle to the same
  thread does not compare equal, so every context transfer took the cross-thread
  path for nothing.
  FIX (ml970, FEX WOW64 module): `GetThreadTLS()` answers the pseudo-handle from
  `CurrentTEB()`, and `BTCpuGetContext`/`BTCpuSetContext` skip the access check
  (a thread always has full access to itself), the duplicate and the close when
  the target is the current thread, passing the pseudo-handle straight down. A
  real handle — what a guest-issued `GetThreadContext` on another thread arrives
  as — still takes the original path, access check included. Expected: all five
  kinds → ~0, and `get_thread_info` loses 1770 per 10 s: **~1180 requests/s of
  the measured ~3700/s, ~32 %**, plus ~45 ms/s of in-call wall time off the
  render thread's critical path.
  ALSO (ml970, `server_ios.c`): `[srv-stats]   kinds-by-caller:` — one return
  address per request, taken one guarded frame above `server_call_unlocked`
  (`wine_server_call`/`server_select` are thin wrappers, so depth 0 is rarely
  the interesting name) and resolved with `dladdr` at report time, top 2 callers
  for each of the top 8 kinds plus `+N more`. The frame hop validates the link
  (non-NULL, 16-byte aligned, strictly ascending, <64 KB) and falls back to
  depth 0, so it can degrade but never fault. It deliberately does NOT try to
  print a guest RIP — see (1) for why that value is not cheaply available on
  this side.
  (3) TSO: 63-64 % of jit samples are in blocks with TSO ops, tso/mem 0.34-0.39.
  `prof-disasm` on the 14 hot-block dumps (1477 host words) counts
  **72 `ldapr` + 12 `stlr`, 0 `ldar`, only 3 `dmb`, and 83 `nop`** — so TSO here
  is acquire/release, not barriers, and the half-barrier back-patch slots are
  **5.6 % of hot-block code**. The decisive pattern, one guest
  `add [reg-516], reg` in the densest block: `sub w20,w9,#516; add
  x24,x19,w20,uxtw; ldapr w20,[x24]; nop; add w20,w20,w7; sub w21,w9,#516; add
  x24,x19,w21,uxtw; nop; stlr w20,[x24]` — **9 host instructions**, of which the
  second address computation is a verbatim repeat of the first. Top 3 codegen
  inefficiencies: (a) the same guest EA is materialised twice for a
  load-modify-store, 2 of 9 instructions, ~17 % of that block — an addressing
  CSE/peephole in `Addressing.cpp`/the RA, not small; (b) NO displacement can be
  folded into a TSO op because `SupportsTSOImm9` is false on this host
  (`IREmitter.h:94` `IsSIMM9 &= (SupportsTSOImm9 || !TSO)`) and LDAPR/STLR have
  no offset form at all — with FEAT_LRCPC2 the pair becomes
  `ldapur/stlur w20,[x24,#-516]` and 4 of the 9 instructions disappear; (c) the
  `nop` slot itself, already gated by `HalfBarrierTSOEnabled` (ml920).
  FEX defaults confirmed unchanged across hosts (`Config.json.in`:
  `TSOEnabled=true`, `HalfBarrierTSOEnabled=true`, `VectorTSOEnabled=false`,
  `MemcpySetTSOEnabled=false`); the WOW64 module forces none of them, and
  hardware TSO is unconditionally unavailable here
  (`FEXUnixLib.cpp TryEnableHardwareTSO` returns false under `FEX_IOS_HOST`), so
  `IsAtomicTSOEnabled()` is always `Config.TSOEnabled`. `ParanoidTSO` no longer
  exists upstream. Implemented (ml970, `CPUFeatures.cpp`, ~14 lines, default
  OFF): `HOSTFEATURES=ENABLELRCPC2` in `Documents/madeira-fex.txt` sets
  `SupportsTSOImm9`. It is opt-in and not detected because this PE branch cannot
  reach `sysctl hw.optional.arm.FEAT_LRCPC2` (FEXUnixLib's table is not
  registered on the iOS host) and FEAT_LRCPC2 is ARMv8.4 while the app's iOS 18
  floor admits ARMv8.3 parts — on an A12/A13 an unconditional `true` would emit
  an undefined instruction in every block. The unaligned back-patcher already
  decodes and rewrites LDAPUR/STLUR (`ArchHelpers/Arm64.cpp:2202,2352,2412`), so
  nothing downstream needs changing.
  A/B RECIPE for `Documents/madeira-fex.txt`, one line per run, in this order —
  `[fex-cfg]` and `FEX: TSO config` echo what actually took effect:
  **A0** baseline (no TSO line). **A1** `HOSTFEATURES=ENABLELRCPC2` — A14/M1 or
  newer ONLY; no ordering change whatsoever (`ldapur`/`stlur` are the same
  acquire/release semantics with an offset), so the only risk is an undefined
  instruction on pre-A14 silicon, which fails loudly and immediately. **A2**
  `HALFBARRIERTSOENABLED=0` — removes the 4-byte back-patch slot from every
  TSO GPR access (~5.6 % of hot-block bytes) and switches the unaligned handler
  from `HalfBarrier` to `NonAtomic`; RISK: an unaligned access that faults is
  rewritten to a bare `ldr`/`str` with NO barrier at all, and any ALIGNED access
  later flowing through that same patched site loses its ordering too — a
  cross-thread visibility bug that shows up as rare, non-reproducible state
  corruption, never as a crash. **A3** `VECTORTSOENABLED=1` and/or
  **A4** `MEMCPYSETTSOENABLED=1` — these make things SLOWER (they add `dmb ish`
  to every vector access, and force `rep movs`/`rep stos` onto a per-element
  loop, losing FEAT_MOPS and the 32-byte `ldp`/`stp` path, and clear the
  guest-visible ERMS CPUID bit); run them only to test whether a suspected
  ordering bug is a vector/string-op accuracy gap, which ml512 already tried
  once with no change. **A5** `TSOENABLED=0` — the big one and the dangerous
  one: FEX's own text is "highly likely to break any multithreaded application".
  On this workload it would remove all 84 acquire/release ops and their address
  arithmetic from the hot blocks; treat any fps number it produces as an upper
  bound on what (a)+(b) could reach safely, NOT as a shippable setting.
  For a narrower experiment, `EXTENDEDVOLATILEMETADATA` takes per-module,
  per-instruction TSO overrides (WoW64/ARM64EC only) so one DLL can drop TSO
  without touching the global knob.
  Built: `libntdll_unix.a` 30/30 clean; `libwow64fex.dll` → `xtajit.dll` and
  `libarm64ecfex.dll` → `xtajit64.dll` both relinked. NEXT LOG should show
  `yield_sc` ≈ 20-50 k and `park` ≈ 20-40 k per 10 s (from 11.5 M / 160 k),
  `swtch_pri<-NtYieldExecution` and `__ulock_wait2<-NtDelayExecution` together
  under ~2 % of CPU (from ~24 %), `get_object_info`/`dup_handle`/`close_handle`/
  `get_thread_context`/`set_thread_context` absent from `kinds:`, `get_thread_info`
  ≈ 2000 per 10 s, total reqs ≈ 2.5 k/s, and the new `[sleep0] hist us:` line
  deciding whether the 20/100/300/500 µs gaps are the right ones.

- 2026-09-14 — **A SECOND guest-window slot, per-pseudo-process fault
  termination, and the winsxs/WMI prefix gaps** (Opus; `virtual_ios.c`,
  `signal_arm64_ios.c`'s `[redeliv]` terminal, `WineProcessBridge.m`, the farm
  scripts, one `ContentView.swift` launch row, `build/x86-tests/spawn-x86.c`).

  **1. A 32-bit process can now start a second 32-bit process — the [cage]
  trade, taken on demand.** `ios_wow_carve_holdback_slots()`
  (`build/ntdll-unix/virtual_ios.c:6587` comment, `:6648` code) runs from
  `ios_wow_window_pick()` (`:6736`) ONLY after every ordinary candidate has been
  refused and ONLY while `ios_cage_holdback_live == 1` (nobody has asked for the
  8 GB V8/cppgc cage). It replaces `[0x7200000000, 0x7300000000)` with one
  `MAP_FIXED` `PROT_NONE` mapping over VA the holdback already owns — no
  `munmap`, so the kernel never gets an instant in which it could place a system
  framework in the slot, the same reasoning as the session-start placeholders —
  adds the Wine reserved area, and records an unadopted placeholder that
  `ios_wow_window_try()` then adopts by the normal path. `[cage] CARVED
  guest-window slot 1 B=0x7200000000…` and `[cage] holdback TRADED` name the
  cost; `ios_cage_holdback_live` is cleared because the grant path in the jumbo
  walk `munmap`s the WHOLE `IOS_CAGE_REAL_SIZE` range, which would now unmap a
  live guest window.
  **TWO is the hard maximum, and the arithmetic is worth writing down so nobody
  re-derives it.** The furniture band is `[ios_usable_va_floor,
  ios_furniture_ceiling)` = `[0x7038000000, 0x73ffff0000)` and holds exactly two
  4 GB-ALIGNED slots that fit whole. `0x7300000000` is NOT a third: it needs
  `[0x73ffff0000, 0x7400000000)`, which is the PA guard pool's home base (the
  `guard_first` walk derives `slot - 64KB` from the ceiling, which is why the
  ceiling stops exactly there), and its FB3 overrun guard page at
  `0x7400000000` can neither be borrowed (that page is a FREE HOLE at the start
  of the CEF pools, and `ios_wow_guard_neighbour_blocked()` correctly refuses a
  hole) nor owned (`ios_wow_band_ok()` refuses a reservation crossing
  `IOS_WOW_CEF_POOLS_START`). A third window needs the CEF pool boundary moved;
  it is not a cage question.
  **Slot 0's FB3 guard is not lost to the carve** even though it borrows the
  holdback's first page — which is now slot 1's page 0. `IOS_WOW_GUEST_FLOOR`
  (0x110000) keeps every placement inside a window above guest 0x110000, so that
  page stays PROT_NONE for the life of the session and an overrun off the top of
  slot 0 still faults. The guarantee now rests on the guest floor rather than on
  a separate reservation; that floor is load-bearing, not cosmetic.
  **N-slot audit — everything that assumed one B.** Already correct, verified by
  reading: `ios_wow_base()` / `ios_wow_in_window()` / `ios_wow_guest_addr()` /
  `ios_wow_translate_limits()` all resolve through `ios_wow_slot_current()`,
  i.e. per CALLER (`:6040`); `ios_wow_live_slot_for_addr()` (`:6088`) keys TEB
  pooling on the block ADDRESS; `ios_wow_slot_for_peb()`, `ios_jit_purge_window(
  base, size)`, `d3d9_native_process_teardown(peb)`, `ios_wow_window_teardown(
  base, …)`, `ios_wow_reclaim_dead_windows()` (already loops all
  `IOS_WOW_MAX_WINDOWS`), `ios_wow_exclude_windows()`,
  `ios_wow_candidate_slot()` and `win32u_zero_bits()`
  (`build/win32u-unix/syscall_ios.c:112`, cached per (pid, peb)) are per-process
  already; there is no hard-coded `0x7100000000` anywhere outside comments.
  FIXED here: (a) `ios_wow_window_teardown()` no longer clears
  `user_space_wow_limit` when another live window remains (`:9322`,
  `[wow-limit] KEPT`) — it is a GUEST ceiling shared by every 32-bit
  pseudo-process, and stripping it mid-run would unbound every later placement
  in the survivor; (b) `ios_prof_wow_window()` (`:6174`) returned "the first
  live window" on the then-true assumption that there is exactly one — it now
  returns the most recently ADOPTED live window and says once, in the log, that
  a guest RIP sample cannot name its own process (FEX's per-process
  `guest_base` is still preferred whenever published).
  Logging: `[wow-window] slot k B=… adopted by pid … — n of m slot(s) now carry
  a live 32-bit pseudo-process` on bind (`:6966`), and
  `[wow-window] slot k B=… released` on exit.
  **REMAINING session-global, named rather than hidden:**
  `user_space_wow_limit` is published by the FIRST 32-bit main image's
  large-address-aware bit, so two concurrent 32-bit processes that DISAGREE
  about LAA share the first one's ceiling. Harmless when they agree; a real
  (small) divergence from Windows when they do not.

  **2. `[redeliv]` now kills ONE pseudo-process, not the app.**
  `build/ntdll-unix/signal_arm64_ios.c:7321` (the terminal; helpers at `:6672`
  watchdog, `:6701` thunk, `:6716` redirect). The forensics dump is unchanged.
  WHY A REDIRECT AND NOT A CALL: `abort_process()` → `process_exit_wrapper()` is
  keyed ENTIRELY by the CALLING thread — `ios_proc_socket_index()` resolves the
  pseudo-process through `ios_jit_current_peb()`, which reads the TEB out of
  that thread's TSD slot (`virtual_ios.c:3660`), and the `exit()` shim longjmps
  on the thread that owns the jmpbuf — while `[redeliv]` runs on the MACH
  EXCEPTION SERVER thread, which belongs to no pseudo-process at all. Calling
  `abort_process` there would have closed the SESSION's master socket and
  released nobody's window. So the faulting thread, already suspended with its
  register state in our hands, is pointed at a thunk (`x18` = its TEB, a private
  512 KB `mmap`ed stack because a JIT-executing thread's SP is not a usable C
  stack and its Windows stack is inside the process being torn down) and
  resumed; every lookup then resolves to the process that actually faulted,
  `[Wine child exit] stage=redeliv-abort` is logged, and `process_exit_wrapper`
  closes that process's socket, reclaims its JIT pool and calls
  `ios_wow_window_release( dead_peb )`.
  `task_terminate` survives for the two cases where nothing could be left alive
  — the faulting thread has no resolvable PEB, or its PEB is the session's own
  (`ios_session_peb_get()`, new, `virtual_ios.c:6118`) — and as the WATCHDOG
  fallback: a detached thread waits 10 s and, if the faulting thread still
  exists (`thread_get_state` succeeds), does exactly what this site used to do
  unconditionally. That bound is deliberate: the wedged thread CAN be holding a
  lock the teardown needs — the `[deliver-hold]` diagnostic exists precisely
  because a thread can hold FEX's shared lock at a guest redirect — and a hung
  app is worse than a dead one.
  **Adjacent bug, not this round's to change:** `process_exit_wrapper`
  (`server_ios.c:2864`) falls back to `close( fd_socket )` — the SESSION's
  master socket — whenever `ios_proc_socket_index()` returns -1, which is what a
  SECOND exit attempt by a sibling thread of an already-dead pseudo-process
  gets. Pre-existing, in a file this round does not own; it wants a server-side
  owner.

  **3. Prefix gaps.**
  (a) `C:\windows\winsxs` did not exist AT ALL, which is why every run logged
  `parse_depend_manifests Could not find dependent assembly
  "Microsoft.Windows.Common-Controls" (6.0.0.0)` and
  `commdlg:DllMain failed to create activation context … 14001`. The store is
  deleted from the shipped template (`scripts/build-prefix-snapshot.sh:71`) and
  nothing recreated it, because this port never runs wineboot's fake-DLL
  install. `app/Madeira/WineProcessBridge.m:1030-1128` now seeds it exactly the
  way `setupapi` does (`wine/dlls/setupapi/fakedll.c` `register_manifest` /
  `append_manifest_filename` / `create_manifest` / `create_winsxs_dll_path`):
  `windows\winsxs\manifests\<DIR>.manifest` plus
  `windows\winsxs\<DIR>\comctl32.dll`, with
  `<DIR> = <arch>_microsoft.windows.common-controls_6595b64144ccf1df_
  6.0.2600.2982_none_deadbeef` — lower case, publicKeyToken and version
  verbatim, and the literal `deadbeef` where Microsoft puts a content hash
  (ntdll's `actctx.c` `lookup_manifest_file` knows that constant and prefers a
  non-Wine assembly if one is ever present). The manifest bytes are
  `dlls/comctl32_v6/comctl32.manifest` with the empty
  `processorArchitecture=""` filled in — the substitution `fakedll.c:853-864`
  makes at install time, and which `actctx.c` then validates against the
  identity parsed out of the file NAME, so the two must agree.
  Three architectures are seeded: `x86` (every 32-bit process), `arm64` (BOTH
  aarch64 and arm64ec — `actctx.c:596-606` `current_archW` is `arm64` under
  `__arm64ec__`) and `amd64` (what an arm64ec `setupapi` would install, since
  `fakedll.c` has no `__arm64ec__` case and falls into the `__x86_64__` branch;
  `lookup_manifest_file`'s `__arm64ec__` branch rewrites an explicit `amd64_`
  request to the wildcard `a??64_`, which matches either).
  **An architecture whose farm has no `comctl32_v6.dll` is SKIPPED, loudly:** a
  manifest without the assembly's DLL makes `find_actctx_dll`
  (`wine/dlls/ntdll/loader.c:3625`) redirect every `comctl32.dll` load for that
  assembly into a directory that has none — strictly worse than no manifest.
  `comctl32_v6` is a SEPARATE module from `comctl32` (same sources built with
  `-D__WINE_COMCTL32_VERSION=6` plus its own button/combo/edit/listbox/static
  supersedes, `PARENTSRC = ../comctl32`), so the plain `comctl32.dll` cannot
  stand in for it; both farm scripts now build it.
  Log: `[WineProc] winsxs: n/3 Common-Controls 6.0 assemblies seeded`.
  (b) **The WMI modules were on the i386 list but had never been BUILT.**
  `wbemprox.dll`, `wmiutils.dll`, `wbemdisp.dll`, `wmic.exe` and `mofcomp.exe`
  were absent from all three farm directories, so both `system32\wbem` link
  passes could only ever have logged `0/5`. Ran `.xtool/build-wine-i386.sh`:
  221 modules installed, and the script's own import-closure check then reported
  two real gaps introduced by the new modules — `devenum -> avicap32` and
  `wbemprox -> winspool.drv` — both added to the script and rebuilt.
  Result: **0 missing cross-imports**, 234 files, all verified `pe-i386`.
  (c) **There was no 64-bit farm build script at all.** The aarch64 and arm64ec
  directories had been populated by hand, which is why "add wbemprox to the
  farms" had no runnable meaning for 64-bit — and why a module missing from the
  aarch64 farm is silently missing from the i386 one as well (the i386 script
  derives its ENTIRE target list from `app/Madeira/aarch64-windows/`). Added
  `.xtool/build-wine-64.sh`: named module list, one bulk make issued from the
  build ROOT (dodging the `make -C dlls/<x>` stub-Makefile trap recorded at
  `WOW64_DESIGN.md:1218`), strip, install, machine-type verify, `.drv`/`.cpl`
  atomic names handled, and a `--configure-arm64ec` stage. aarch64: `wbemprox
  wmiutils wbemdisp dxdiagn comctl32_v6 wmic mofcomp winspool.drv` all built,
  stripped, installed, verified `coff-arm64`. arm64ec (tree configured here for
  the first time): `wbemprox wmiutils wbemdisp dxdiagn comctl32_v6` built,
  verified `coff-arm64ec`. **`wmic.exe`/`mofcomp.exe` do not exist for arm64ec
  by construction** — that tree emits only `clean`/`.pot` rules for those
  programs, and the shipped arm64ec farm has never contained a single Wine
  program EXE (its 13 `.exe` files are all `*-x64` test binaries); Wine programs
  come from the aarch64 farm, which has both, and the `wbem` link loops skip
  what a farm does not build. So `Farm sysx64\wbem: 3/5` is the CORRECT reading
  there, not a gap.
  **Two fresh-configure traps, both fixed inside that script:**
  `config.status: creating Makefile` dies with
  `../dlls/ntdll/unix/sync.c:79: error: ios_srv_stats.h: No such file` because
  makedep scans EVERY `#include`, including the `#ifdef WINE_IOS` ones, while
  those headers live in `build/ntdll-unix/shims/` and are reached only through
  `-I` at compile time. `build-macos` and `build-i386` never saw it because
  their Makefiles predate those includes. `--configure-arm64ec` copies
  `ios_srv_stats.h` / `ios_spin_hist.h` / `ios_fastsync.h` next to the sources
  that include them first. Anyone reconfiguring any tree will need the same.
  Second trap, arm64ec only: every module with an `.idl` importlib (wbemdisp
  first) failed with a bare `error: cannot find stdole2.tlb`, because widl's
  `open_typelib()` (`wine/tools/widl/widl.c:644`) searches
  `<dir>/<module>/<pe_dir>/<name>` with
  `pe_dir = get_arch_dir({ target.cpu, PLATFORM_WINDOWS })`, and for an arm64ec
  target that collapses to `/aarch64-windows` — while the tree builds the
  typelib into `dlls/stdole2.tlb/arm64ec-windows/`. The script now aliases
  `dlls/*.tlb/aarch64-windows -> arm64ec-windows` before the make; with that,
  wbemdisp builds.

  **Test program.** `build/x86-tests/spawn-x86.c` + `build-spawn-test.sh`:
  a no-CRT i386 PE that `CreateProcess`es ITSELF three levels deep, every level
  staying ALIVE and blocked in `WaitForSingleObject` on its child, so each live
  32-bit pseudo-process needs its own window. Root exits **49** on a full chain;
  60-65 name exactly where it broke and propagate unchanged up the chain; a
  `CreateProcess` failure also prints `MADEIRA-SPAWN CONCURRENCY LIMIT: depth=N
  … N+1 concurrent 32-bit pseudo-process(es) fit in this address space`, which
  is the direct measurement. Launch row **"Spawn chain"** added to
  `launchTargets` in `app/Madeira/ContentView.swift` (the only edit made there).
  **Read the expected result correctly:** with TWO slots the chain reaches
  depth 1 and then reports the concurrency limit with exit 61. Reaching depth 1
  AT ALL is item 1's fix; **exit 49 requires a third slot**, i.e. the CEF pool
  boundary moving, and is the gate for whoever takes that on.

  **Built and verified here:** `libntdll_unix.a` rebuilt clean 30/30 three
  times, no new warnings (the three that remain are pre-existing and in other
  code); `WineProcessBridge.m` passes `-fsyntax-only` against the iPhoneOS SDK;
  `spawn-x86.exe` built i386 with its import set asserted kernel32-only and
  `LARGE_ADDRESS_AWARE` asserted; both farm builds ran to completion with their
  own verifiers.
  **Needs the device, and exactly what to look for:**
  `[cage] CARVED guest-window slot 1 B=0x7200000000` followed by
  `[wow-window] slot 1 B=0x7200000000 adopted by pid …` on a 32-bit program
  launched BY a 32-bit program — that one pair is the whole of item 1 — then
  `MADEIRA-SPAWN depth=0` / `depth=1` from the new button. Also
  `[WineProc] system32\wbem: 5/5 links`, `Farm syswow64\wbem: 5/5`,
  `Farm sysaa64\wbem: 5/5` and `Farm sysx64\wbem: 3/5` (arm64ec has no Wine
  program EXEs at all — see above); `[WineProc] winsxs: 3/3`; NO
  `parse_depend_manifests … Common-Controls`, NO `commdlg … 14001`, NO
  `com_get_class_object … {4590f811-…}`. For item 2: a guest fault that used to
  end the session must now log `[redeliv] terminating ONE pseudo-process` →
  `[Wine child exit] stage=redeliv-abort` → `[wow-window] slot k … released`
  with the desktop still alive; `[redeliv] the faulting thread is STILL ALIVE
  10 s after being redirected` would mean the teardown deadlocked on a lock the
  wedged thread holds, and names the next thing to fix.

- 2026-09-14 — **The x64 CONTEXT cannot carry six ARM registers, and FEX keeps
  live state in every one of them** (logs m50 / l43, same crash). A 64-bit
  title with a managed runtime died within seconds, twice in the same shape.
  Both faults are now fully accounted for, and the second one is arithmetically
  certain rather than inferred.

  **The mapping's hole.** `context_x64_to_arm()`
  (`wine/dlls/ntdll/unwind.h:144-153`) writes `X13 = X14 = X18 = X23 = X24 =
  X28 = 0` into every native ARM64 context it builds, because an x86-64
  `CONTEXT` has no field for them. On a stock arm64ec host that is harmless:
  those registers are the emulator's, and the emulator is always re-entered
  through `KiUserEmulationDispatcher`, which reloads its whole world from the
  CPU area. FEX's ARM64EC backend does not leave them spare —
  `FEX/FEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.cpp:142-146` puts
  **the guest RSP in x23** ("SP's register location isn't specified by the
  ARM64EC ABI, we choose to use r23"), `Arm64Emitter.h:33` puts **STATE, the
  CpuStateFrame pointer, in x28**, and `Arm64Emitter.h:63/66` and
  `Arm64Emitter.cpp:171` claim x13 (TMP4), x24 (REG_AF) and x14 (a dynamically
  allocated GPR). So EVERY register the x64 CONTEXT drops is one the JIT is
  using. Any resume that passes through an x64 CONTEXT and lands **natively**
  back on emitted code — an SEH continue, `RtlRestoreContext`, a user APC's
  `NtContinue`, `SetThreadContext` + `ResumeThread` — puts the guest back with
  RSP = 0 and no CPU-state pointer. That is precisely m50's
  `[x86_live] RSP=0x0 … State.RIP=0x0` on a thread whose HOST sp
  (`0x702080f398`) is a perfectly good stack address inside its own 8 MB stack
  region. FEX's own `NtContinueNative` is a direct syscall wrapper
  (`FEX/Source/Windows/ARM64EC/Module.S:362`) carrying a real ARM64 context, so
  it is not the producer — the EC CONTEXT wrappers are.

  **The second fault, proved not guessed.** `signal_set_full_context+0x1b4`
  stored to `0xfffffffffffffc70`. That number is exactly
  `-sizeof(ARM64 CONTEXT)` = `-0x390`, and the bounce at
  `build/ntdll-unix/signal_arm64_ios.c` computes
  `user_context = (frame->sp - sizeof(CONTEXT)) & ~15`. Disassembling the built
  `signal_arm64.o` shows the sequence verbatim: `ldr x8,[x21,#0xf8]` (frame->sp)
  / `and x8,x8,#~15` / `sub x20,x8,#0x390` / `str w8,[x20]` with
  `w8 = 0x400007 = CONTEXT_FULL`, and m50's `segv_handler` reports
  `x20=0xfffffffffffffc70`. So `frame->sp == 0`: `NtContinue` was called with a
  CONTEXT whose `Sp` (the caller's `Rsp`) was zero, and ntdll then dereferenced
  a wild pointer instead of failing. Fault #3/#4 is therefore DOWNSTREAM of
  fault #1 — the guest fault raised by the RSP-less thread was dispatched, and
  the continue that came back out of the dispatcher carried the zeroed context.

  **Why `GetThreadContext` cannot be trusted either.**
  `wine/dlls/ntdll/signal_arm64ec.c:1674` asks for the NATIVE ARM context
  unconditionally and runs it through `context_arm_to_x64()`, which maps `Sp` →
  `Rsp` and `Pc` → `Rip` verbatim. For a thread parked in FEX's emitted code
  that hands the caller the emulator's own stack pointer as the guest RSP and a
  code-cache address as the guest RIP — values it will hand straight back
  through `SetThreadContext`. The in-tree ml715/ml716 probes
  (`[ec-getctx]`, `[srv-getctx]`, `[ctx-frame]`/`MADEIRA_CTX_FRAME`) were
  written for exactly this and **have never run**: `[ec-getctx]` appears zero
  times in every log from l43 to m54, because
  `app/Madeira/arm64ec-windows/ntdll.dll` is dated 2026-09-10 21:45 while
  `signal_arm64ec.c` was last edited 21:57 — the PE ntdll has not been rebuilt
  since. Anything added to `signal_arm64ec.c` needs a full wine PE rebuild
  (`.xtool/build-wine-native.sh` + `.xtool/build.sh`) to reach the device;
  `.xtool/_ntdll.sh` only rebuilds the UNIX half.

  **A third defect found on the way, not yet fixed.** On iOS cross-thread
  `SetThreadContext` never reaches its target. `wine/server/thread.c:1343` only
  converts a resume into the fake-`STATUS_KERNEL_APC` context handback when
  `thread->suspend_cookie == cookie`, and that cookie is set only from the
  `select` request's suspend-context path (`thread.c:2155`), i.e. only from
  `wait_suspend()` (`build/ntdll-unix/thread_ios.c:1848`) — which on iOS runs
  only at thread start, because POSIX signal suspend is dead
  (`build/wineserver/mach_ios.c:407`). Worse, `stop_thread()`
  (`thread.c:974`) returns early whenever `thread->context` already exists, and
  nothing on the iOS path ever frees it, so the Mach snapshot taken at the FIRST
  suspend is what every later `GetThreadContext` returns. A stop-the-world
  therefore reads a stale context and its writes are silently dropped. Fixing
  that is the next step and is what `ctx-x64.exe` will measure.

  **Fixed here (ships with the ntdll-unix rebuild).**
  `build/ntdll-unix/signal_arm64_ios.c`, `signal_set_full_context()`: (a) it
  now snapshots `frame->x[13,14,23,24,28]` before the context is applied and
  restores any the incoming context zeroed, for arm64ec threads only — those
  values cannot be *requested* through an x64 CONTEXT, so a zero in one is
  never intent, and a native ARM64 context carries real values and is left
  alone; (b) a CONTEXT whose `Pc` is neither EC code nor a pool address (so the
  resume WILL bounce through `KiUserEmulationDispatcher`) and whose `Sp` is not
  a usable stack is now refused with `STATUS_INVALID_PARAMETER` before the
  frame is touched, instead of carving the dispatcher frame out of a null
  pointer. Both log through the new capped `[ctx]` channel.

  **Fixed at the source (needs a PE ntdll rebuild to take effect).**
  `wine/dlls/ntdll/signal_arm64ec.c`: `NtSetContextThread` merges the target's
  live x13/x14/x23/x24/x28 back in after `context_x64_to_arm()`; and, behind
  `MADEIRA_CTX_EMU=1`, `NtGetContextThread` reports the EMULATED pair for a
  target parked in non-EC code — `Rsp` from x23 and `Rip` from
  `CpuArea->EmulatorData[0]` + 0x18 (FEX's CpuStateFrame), cross-checked
  against x28 so a clobbered register cannot fabricate a RIP. Get and Set ride
  one switch on purpose: an `Rsp` handed out as a guest RSP has to come back as
  one.

  **New diagnostics, 16 lines per session total.** `[ctx] set` fires from the
  unix `NtSetContextThread` when the incoming `Sp`/`Pc` (which on arm64ec ARE
  the caller's `Rsp`/`Rip`) is not a stack the target owns or not inside any
  module the loader knows, and prints the caller's return address. `[ctx] get`
  is its counterpart on `NtGetContextThread`. `[ctx] continue REFUSED` and
  `[ctx] restored emulator-private regs` come from `signal_set_full_context`.

  **New test.** `build/x64-tests/ctx-x64.c` + launch row **"Thread context
  (x64)"** in `launchTargets` (`app/Madeira/ContentView.swift`, the only edit
  made there). Thread A spins in a loop with no calls in it; thread B does
  `SuspendThread` / `GetThreadContext` / assert `Rsp` inside A's stack and
  `Rip` inside the exe image / redirect `Rip` to a `landing` function via
  `SetThreadContext` / `ResumeThread` / wait for the landing flag / restore the
  original context and check A resumes spinning — 200 times. Exit 50 = pass;
  55 = a host stack pointer was reported as the guest RSP, 56 = a code-cache
  address was reported as the guest RIP, 59 = the redirect was lost, 60 = the
  restore did not take (the iOS `thread->context` defect above). Built with
  `build/x64-tests/build.sh ctx-x64`, whose hard-coded macOS toolchain and
  bundle paths now fall back to this checkout's `.xtool/toolchains/llvm-mingw`
  and `app/Madeira/arm64ec-windows`.

  **Built and verified here:** `libntdll_unix.a` rebuilt clean 30/30;
  `signal_arm64.o` disassembled to confirm the new register-rescue stores land
  at `frame->x[13]`=+0x68, `[14]`=+0x70, `[23]`=+0xb8, `[24]`=+0xc0,
  `[28]`=+0xe0 and that the `sub x20, x8, #0x390` crash site is now
  unreachable with a null `Sp`; `ctx-x64.exe` built x86-64 PE (109 568 bytes)
  and copied into the arm64ec farm.

  **Needs the device, and exactly what to look for.** Press **"Thread context
  (x64)"**: `MADEIRA-CTX PASS` / exit 50 means the round trip is honest. Exit
  **55** or **56** with the printed value is the direct measurement that
  `GetThreadContext` is still handing out host registers — that is the gate for
  turning on `MADEIRA_CTX_EMU=1`, which needs the PE ntdll rebuilt first. Exit
  **60** confirms the `thread->context` staleness above. In the title's own log,
  the signature to watch is `[ctx] restored emulator-private regs … x23(guest
  RSP)=…` — every line is a resume that WOULD have put the guest back with
  RSP = 0, i.e. one prevented crash; and `[ctx] continue REFUSED` replacing the
  old `signal_set_full_context+0x1b4` fault. If `[x86_live] RSP=0x0` still
  appears with no `[ctx]` line before it, the zeroing is reaching the thread by
  a path that does not go through `signal_set_full_context` — the cross-thread
  server handback — and the `thread->context` defect is then the whole story.

- 2026-09-15 — **DEP off for a non-NX-compat image: the emulator was never
  told, so code the program wrote into its own memory could not be executed**
  (log m55).

  **The death.** A 2001-era retail 32-bit title died within seconds, always the
  same way:

      [guest-code] pool_rip=0x1b4380f (PE 0x1b4380f) -- NO pool copy (identity translate)
      0090:err:seh:segv_handler SEGV #1: pc=0x151f74368 addr=0x0 ... x20=0x1b4380f
        [guest-state] rip=0x1b4380f rsp=0x108fb1c
      setup_exception for SEGV ... (virtual_handle_fault failed)
      [fault-rgn] addr=0x0 ... NO wine view
      wine: Unhandled page fault on execute access to 01B4380F at address 01B4380F

  Guest RIP `0x01B4380F` is in no PE image: it is memory the program allocated
  `PAGE_READWRITE` and wrote code into — an unpacker or copy-protection stage,
  the single most common thing a program of that vintage does.

  **Why it could not run.** On Windows a 32-bit image without
  `IMAGE_DLLCHARACTERISTICS_NX_COMPAT` runs with DEP disabled and executing any
  committed readable page is legal. Wine models that with `force_exec_prot`
  (`virtual_set_force_exec`), which ORs `PROT_EXEC` into every `PROT_READ`
  mapping. On this port that mechanism is inert and irrelevant: iOS TXM refuses
  `PROT_EXEC` outside the JIT pool, which is why `mprotect_exec` already
  deliberately ignores the force (`virtual_ios.c`, the `[force-exec]` note), and
  **nothing host-executes a guest page anyway** — guest code is decoded and run
  from the pool. The only thing that decides whether a guest address may be
  executed is FEX's `InvalidationTracker::XIntervals`, consulted through
  `QueryExecutableRange` -> `QueryGuestExecutableRange` ->
  `Decoder::CheckRangeExecutable`. A range that is not in it decodes as
  `NOEXEC`, `Core.cpp` raises `NoExecOp`, and the JIT branches to the
  dispatcher's `GuestSignal_SIGSEGV` trampoline (`Dispatcher.cpp:566`) whose
  whole body is `mov w1,#0 ; ldr x1,[x1]` — a deliberate read of address 0.
  **That is where `addr=0x0` came from: it is the trap, not the fault.**
  `virtual_handle_fault` and `[fault-rgn]` were both answering a question about
  page 0 that nobody had asked, and the address that mattered appeared only in a
  register.

  **The missing wire.** `BTCpuNotifyProcessExecuteFlagsChange` — the CPU
  backend's DEP hook, exported by `libwow64fex.dll` and implemented all the way
  down to `InvalidationTracker::HandleProcessExecuteFlagsChange` — **was never
  resolved or called by this Wine tree**. The 32-bit loader's
  `NtSetInformationProcess(ProcessExecuteFlags)` for a non-NX-compat image
  (`wine/dlls/ntdll/loader.c:1930`) was forwarded straight through at
  `wine/dlls/wow64/process.c:962` to the host ntdll, which set
  `force_exec_prot` and stopped. `DEPDisabled` stayed false for the life of
  every process. FEX's comment at `WOW64/Module.cpp:1869` had stated this
  exactly; nothing acted on it.

  **The fix, in three parts.**

  1. `wine/dlls/wow64/syscall.c` resolves and pool-translates
     `pBTCpuNotifyProcessExecuteFlagsChange` alongside the other `BTCpuNotify*`
     hooks, `wow64_private.h` declares it, and `wow64/process.c`
     `wow64_NtSetInformationProcess` gets `ProcessExecuteFlags` its own case: it
     forwards as before and, on success, notifies the backend. The handle is
     deliberately not examined, because ntdll's own implementation of this class
     ignores it too. This covers both the loader's automatic opt-out and
     `SetProcessDEPPolicy` at runtime (`kernel32/process.c:558` maps
     `PROCESS_DEP_ENABLE` to `MEM_EXECUTE_OPTION_DISABLE|PERMANENT`).

  2. `FEX/Source/Windows/Common/InvalidationTracker.cpp`
     `PromoteDEPRegionLocked()` is the one place a region becomes executable
     because DEP is off: `VirtualQuery` the address, and if it is committed,
     readable, not already executable and not a `PAGE_GUARD`/`PAGE_NOACCESS`
     page, insert it into `XIntervals`, into `RWXIntervals` when writable (so
     the SMC write-trap is armed — an unpacker writes, executes, rewrites and
     executes again), and into `DEPPromotedIntervals` so `GetTrapProt` /
     `GetUntrapProt` trap it with `PAGE_READONLY`/`PAGE_READWRITE` rather than
     the `PAGE_EXECUTE_*` pair the host page can never hold. Two callers:
     `HandleProcessExecuteFlagsChange`'s sweep, **now bounded to
     `[GuestBase, GuestBase+4GiB)`** — the upstream walk from 0 is correct only
     when guest and host share a 32-bit space, and here it would have marked
     FEX's own heap and the pool's RW alias as guest code *and* armed write
     traps on them; and, new, `QueryExecutableRange()`, which on a decode miss
     with DEP off promotes lazily and answers. Doing it at decode time rather
     than on the fault is what makes it usable: the block is compiled correctly
     the first time, instead of having to unwind a running block and re-enter
     the JIT at the same RIP from a signal handler. Only `IntervalsLock` is
     taken there and nothing is invalidated — nothing can have been compiled for
     a range the decoder is only now asking about — which matters because the
     caller already holds `CodeInvalidationMutex` shared and it has no
     shared-to-exclusive upgrade. A miss that is *not* a committed readable page
     still returns "not executable", so a genuine wild branch still faults: DEP
     off does not mean every address is code.

  3. `virtual_ios.c` `virtual_handle_fault` gains the host-side
     `EXCEPTION_EXECUTE_FAULT` branch (grant `VPROT_EXEC` on a committed
     readable page when `force_exec_prot`, and report success only if the kernel
     actually honoured it, since on iOS it usually cannot);
     `virtual_set_force_exec` logs the transition and publishes
     `ios_dep_disabled`; and `signal_arm64_ios.c` `ios_fex_noexec_trap_rip()`
     recognises the JIT trap by its two instruction words (`ldr x1,[x1]` with
     `x1` just zeroed — a pairing that cannot occur by accident) and reads the
     guest RIP from FEX's live `CpuStateFrame` at `x28+0x18`, falling back to
     `x20`. `segv_handler` now classifies that case **before** consulting the
     page machinery, so the log names the guest RIP and says whether DEP is off
     (a promotion gap) or on (a correct access violation) instead of printing a
     region report for page 0. The exception record is left untouched on
     purpose: FEX's `HandleGuestException` rewrites it into the execute AV the
     guest sees.

  **New diagnostics.** `[dep-off] DEP DISABLED/re-enabled for this process` from
  the unix side, one `[dep-off] promoting 0x…+0x… to executable for a
  non-NX-compat image (guest rip 0x…)` per promoted region (capped at 512, with
  the cap announced), `[dep-off] EXECUTE FAULT (FEX no-exec trap) at guest
  rip=…` from the fault handler, and a periodic `[dep-off] summary:` line on the
  same ~10 s clock as `[fex-stats]`, emitted from
  `WowSyscallHandler::PreCompile` and silent unless DEP is actually off. All
  four absent in a run that dies on an execute fault is itself the diagnosis.

  **New test.** `build/x86-tests/execrw-x86.c` +
  `build/x86-tests/build-execrw-test.sh`, which links the same source twice with
  opposite linker flags and asserts the `NX_COMPAT` bit actually differs, so a
  toolchain that ignored one flag cannot produce a green run that tested
  nothing: **`execrw-x86.exe`** (`--disable-nxcompat`, DEP off) and
  **`execrw-nx-x86.exe`** (`--nxcompat`, DEP on). The program reads its own PE
  header to decide which half to run. DEP off: execute `mov eax,42 ; ret` from
  `VirtualAlloc(PAGE_READWRITE)`; rewrite the immediate and call again, then 64
  more rewrite-and-call rounds **with no `FlushInstructionCache` anywhere** (an
  unpacker does not issue one either, so a stale translation fails loudly); the
  same stub from `HeapAlloc`'d memory; the same stub from a page committed
  separately inside an earlier `MEM_RESERVE`; and finally
  `SetProcessDEPPolicy(PROCESS_DEP_ENABLE)`, after which the very same buffer
  must stop being executable. DEP on: the first call must raise an access
  violation with `ExceptionInformation[0] == 8` at the address jumped to. No CRT
  and no `__try` (clang has no 32-bit x86 SEH): recovery is a vectored handler
  that redirects `Eip` to a stub returning a sentinel, which is safe because the
  faulting instruction is the callee's first byte so the stack is exactly what a
  `__cdecl` callee expects. Exit **52** = pass; 41/42 = DEP-off promotion is not
  happening, 43/44 = DEP is not being enforced, 45/46 = self-modifying code runs
  a stale translation, 47/48 = heap or late-commit memory was missed, 49-51 =
  the runtime opt-in did not take.

  **Built and verified here:** `libntdll_unix.a` 30/30 clean (no new warnings);
  `libwow64fex.dll` -> `aarch64-windows/xtajit.dll` and `libarm64ecfex.dll` ->
  `arm64ec-windows/xtajit64.dll` both rebuilt (`InvalidationTracker` is shared);
  `wow64.dll` rebuilt via `.xtool/build-wine-64.sh aarch64 wow64` and its new
  `BTCpuNotifyProcessExecuteFlagsChange` lookup string confirmed present in the
  installed binary, matching the export in the freshly built `xtajit.dll`; both
  test exes built i386 PE, kernel32-only imports, large-address-aware, and the
  `NX_COMPAT` bit confirmed 0 in one and 1 in the other.

  **Needs the device.** Two launch rows are wanted: **`execrw-x86.exe`** and
  **`execrw-nx-x86.exe`**. Both must end in `MADEIRA-EXIT … status=52`. In the
  DEP-off run the log must also carry `[dep-off] DEP DISABLED`, at least one
  `[dep-off] promoting …`, and a `[dep-off] summary:` line; in the `NX_COMPAT`
  run it must carry none of them. Then the title itself: the `[guest-code] … NO
  pool copy` / `Unhandled page fault on execute access` pair at a non-image RIP
  should be gone, replaced by a `[dep-off] promoting …` line for the region that
  RIP lies in. If the fault still happens, the new `[dep-off] EXECUTE FAULT …
  dep_disabled=` line decides it immediately: `dep_disabled=0` means the
  notification never arrived (wow64/backend wiring), `dep_disabled=1` means the
  region was not promoted (an `InvalidationTracker` gap), and the guest RIP it
  prints is the address to look up.
- 2026-09-15 — Log 55 (a 2001-era 32-bit retail title): the JIT's
  no-exec trap (`mov w1,#0; ldr x1,[x1]`) was being reported as a NULL
  fault; the real cause was DEP-off semantics never reaching the CPU
  backend (`BTCpuNotifyProcessExecuteFlagsChange` unresolved/uncalled by
  wow64) — fixed (see the agent entry above: lazy promotion on decode miss,
  bounded sweep, `[dep-off]` lines, `execrw-x86.exe`/`execrw-nx-x86.exe`
  exit 52). XInput end to end (`NtUserCallTwoParam_GetGamepadState`, seqlock
  slots in Winios, xinput1_x for all three farms, pad bindings on the
  landscape controls, `xinput-x86.exe` exit 53). UI: launch row reduced to
  five buttons + "Custom…" (path popup, `madeiraCustomExePath`); per-test
  buttons gone (run tests through the popup as `C:\windows\syswow64\<exe>`);
  display-mode button icon-only; landscape HUD cluster draggable (0.3 s
  long-press, persisted per orientation); keyboard button resolves its
  target from the window at tap time (`[keyboard] show …` lines). Build
  gotcha recorded: any make in `wine/build-macos` regenerates config.h and
  drops the GnuTLS defines prepare-wine.py appends → re-append before the
  ntdll-unix build.
- 2026-09-15 — Log 56 (second launch in one app run): `BAD POOL: no valid
  placement after retries. Killing in 10s` was a misdiagnosis, and the kill
  was the worst part of it. Session 1's pool was fine (`RX=0x11bfe0000,
  RW=0x13bfe0000`); the address space was never the problem. `[early-detach]`
  (ml524) drops StikDebug ~2 s after the pool is granted, so session 2's
  allocation BRK reached nobody — the log says it plainly two lines up
  (`[task-exc] BREAKPOINT #1 … jit26_prepare_region+0x28`, then `[brk-f00d]
  skipped stray StikDebug BRK`). x0 came back 0, the loop broke on attempt 0,
  and the `else` branch printed a canned "all placements landed in the
  forbidden guest 64G window" that was hard-coded rather than observed.
  A second pool would have been useless anyway: ntdll-unix reads
  `WINE_IOS_JIT_RX/RW/SIZE` exactly once behind `jit_pool_init_done`
  (`virtual_ios.c`), the dylib is never unloaded, and `wine_process_start()`
  only spawns another thread into `__wine_main` in the same process — so from
  session 2 on, Wine is already committed to the first pool's bump pointer,
  freelist, image and anon-alias tables, and the TEB trampoline at pool+8.
  Fix: **the pool is a process-lifetime resource.** `StikJITHelper.cachedPool`
  holds it and every later session gets the same mapping back after a
  validation probe (`jit_range_is_mapped`: no holes across the full range, plus
  R+X / R+W on the first page of each alias only — deeper pages legitimately
  change protection under W^X demotion and poisoning). Reuse is logged as
  `[jit-pool] reuse RX=… RW=… size=…MB (session N) — no debugger round trip`
  and removes a ~1.9 s whole-process BRK suspension from every launch after the
  first. **The pool is deliberately NOT scrubbed between sessions:** zeroing or
  madvise-ing it would destroy live ntdll-unix state that `jit_pool_init_done`
  guarantees will never be rebuilt (the pool+0/+8 trampoline, every image the
  alias tables point at, the freelist's accounting); reclaiming dead ranges is
  already ntdll-unix's job (`[jit-pool] RECLAIM peb=…`). When a pool really does
  have to be allocated, placement now makes progress instead of re-rolling:
  a rejected region is freed and then re-reserved at the same VA with
  `vm_allocate(VM_FLAGS_FIXED)` — reserve-only, so a blocked hole costs address
  space and no footprint — which is what ml595/ml596 lacked when the kernel
  handed back `0x7000000000` three times running; then, if eight rolls still
  fail, an explicit sweep places the range itself with `vm_allocate(FIXED)` and
  asks the debugger only to bless it (`jit26_prepare_region` with x0 ≠ 0;
  `_M` is ANYWHERE-only), 64 MB stride from the pin frontier then 1 GB out to
  64 G, every candidate **verified executable** before acceptance and released
  otherwise. Success logs `[jit-pool] placed at RX=… RW=… after K attempt(s)`.
  `exit(0)` is gone: failure logs `[jit-pool] NO POOL after K attempts — Wine
  will not start. The app stays usable`, names the real reason (debugger gone
  vs. every placement rejected), and leaves the UI and the log alive.
  Separately, the ml347 JIT-pool dump is now opt-in: every unhandled guest
  fault (and the first ILL) was writing the whole RW alias — 512 MB at the
  direct-launch default — synchronously from a fault handler into the synced
  Documents folder. `ios_jit_dump_enabled()` in `signal_arm64_ios.c` gates both
  sites on `MADEIRA_JIT_DUMP=1` (default off, settable from
  `Documents/madeira-env.txt`), and a stale `fex-jit-dump.bin` is deleted at
  session start when the knob is off. **Needs the device:** launch a program,
  quit it, launch a second one in the same app run — the second launch must
  print `[jit-pool] reuse RX=0x… RW=0x… (session 2)` within milliseconds, no
  `Allocating …MB JIT pool via debugger` line, no `BAD POOL`, no 10-second
  kill; and no `fex-jit-dump.bin` should appear in Documents unless
  `MADEIRA_JIT_DUMP=1` is set.
- 2026-09-15 — Logs 56-58. The 2001-era title now runs past DEP (24
  regions promoted) and exits 1 after opening `\??\Global\SecDrv` /
  `\??\SecDrv` fails: SafeDisc copy protection needs the secdrv kernel
  driver Windows removed in 2015 — not an emulator defect; not emulating
  it. "Nothing launched" from the Custom popup = that quick exit plus the
  second launch failing at "BAD POOL": root cause was the early-detached
  debugger no longer servicing the allocation BRK (fixed: pool cached for
  the app lifetime, reuse path, explicit hinted placement, no exit(0)).
  512 MB `fex-jit-dump.bin` now behind `MADEIRA_JIT_DUMP=1`. UI: Enable JIT
  first; `DisplayMode.fitHeight` (aspect kept, full height, side bars);
  on-screen gamepad controls are real XInput sources (`ControlAction.
  gamepad`, `.gamepadDPad`, `OnScreenPad` merge with the physical pad,
  `src=` in the `[xinput]` line) — the "L" glyph was `.mouseLeft`'s label
  because the controller tab only set `padBinding`; control size slider
  (`sizeScale` 0.5-2.0). Log 58 (UE3 game, this build): main thread
  `sleep0=3.4 M/10 s` but `yield_sc=1551`, `park=26 k` — the governor works;
  render thread 59 % (jit 17 %) — next perf target is that thread's non-JIT
  share (`kern` shows `NtDelayExecution` 5.2 %, server reads 6 %).
