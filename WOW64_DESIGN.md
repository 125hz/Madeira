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
     the `PAGE_EXECUTE_*` pair the host page can never hold. Its **only** caller
     is `QueryExecutableRange()`, which on a decode miss with DEP off promotes
     and answers — see the revision below for why there is no eager sweep.
     Doing it at decode time rather
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

  **REVISED THE SAME DAY, from the next device run: promotion is LAZY ONLY, and
  no log line a guest can drive is uncapped.** The first revision promoted
  eagerly in two places — a sweep of the guest window when DEP is switched off,
  and `HandleMemoryProtectionNotification` treating "DEP off + readable" as
  executable — and both were wrong for the same reason. Here a *writable*
  promoted region does not merely gain a bit in an interval list: it enters
  `RWXIntervals`, and `ProtectRWXIntervalsInternal` then arms a REAL host write
  trap (`NtProtectVirtualMemory` to `PAGE_READONLY`) on any page a block is
  compiled in. So eager promotion taxed every data page of a non-NX-compat
  image whether or not the program ever executed from one. Measured:

      [dep-off] summary: DEP off, 38 regions / 25280 KiB promoted (0 lazily)

  for a title that never executes from its data, and the resulting SMC
  bookkeeping printed `D D4 Add SMC interval: <start> - <end>` from the render
  thread roughly **100 times a second for the whole session** — a 77 MB /
  1.6 M-line log, with `[prof] kern` putting
  ``write<-Madeira`unixcall_wine_dbg_write`` at **3.2 % of all CPU**. The
  diagnostic had become the regression.

  Both eager paths are gone. `HandleMemoryProtectionNotification`
  (`InvalidationTracker.cpp:224-262`) is back to meaning exactly what the guest
  asked for — only a genuine `PAGE_EXECUTE_*` inserts — and
  `HandleProcessExecuteFlagsChange`'s disable branch
  (`InvalidationTracker.cpp:428-455`) now only sets the flag and invalidates
  cached code, so `PromoteDEPRegionLocked` has one caller left: the decode miss.
  An execute attempt is the only correct trigger and the frontend raises one
  before it emits anything, so a program that never runs code out of its own
  data pays **nothing** — not a VirtualQuery, not an interval, not a trap — and
  one that does pays a VirtualQuery and one insert, once, per region it jumps
  into. Removal stays DEP-aware so a lazily-promoted region still leaves
  `DEPPromotedIntervals` when it is reprotected or freed.

  The `Add SMC interval` line itself (`InvalidationTracker.cpp:254`) is capped
  at 64 per session with the cap announced, and so is `[dep-off] promoting`
  (`InvalidationTracker.cpp:388`, lowered from 512). The rule this codifies:
  **no log on a path the guest can drive at frame rate may be uncapped**, DFmt
  included — debug level is not a cap when debug output is on, and on this port
  every line costs a `unixcall` into the host writer.

  `regions=0` in the `[dep-off] summary` is therefore the EXPECTED reading for
  most non-NX-compat programs, and is the measurement that the sweep is gone.
  `build/x86-tests/execrw-x86.c` is unchanged and still covers everything: each
  of its five phases is an actual execute attempt, so each still promotes.

- 2026-09-15 — **A 32-bit DLL with no unix side killed the process, and dnsapi
  was that DLL** (logs n60/n62/n63/np3, identical). The sequence, host-side and
  entirely generic:

  ```
  0024:err:dnsapi:DllMain No libresolv support, expect problems
  [mach_exc] sym pc=Madeira`__wine_unix_call_dispatcher+0x5c
             insn f8617810 = ldr x16,[x0,x1,lsl #3]   x0=0 (table) x1=1 (code)
  [mach_exc] lr PE: libwow64fex.dll+0x1048c0          <- FEX's wow64 unix-call bridge
  [guest-state] rip=0x2a0002                          <- the 32-bit __wine_unix_call trampoline
  SEGV #1 addr=0x8 -> #2/#3 addr=0x0 -> SEGV LOOP DETECTED -> process dead
  ```

  `WINE_UNIX_CALL(code, args)` is
  `__wine_unix_call(__wine_unixlib_handle, code, args)`, and that handle is the
  unix call **table**. A PE DLL whose `DllMain` saw `__wine_init_unix_call()`
  fail leaves it at 0 — and upstream dnsapi then calls it anyway: `main.c`'s
  `DllMain` logs "No libresolv support, expect problems" and every later
  `DnsQuery_*` still expands `RESOLV_CALL()`. So `ldr x16, [x0, x1, lsl #3]`
  read host address `code*8`. A library that has no unix side on this port must
  produce a failed CALL, never a dead pseudo-process, and the two halves of
  that are fixed separately below.

  **1. The dispatcher no longer dereferences a table it was not given.**
  `signal_arm64_ios.c:12288-12292` adds three instructions in front of the load:
  `cbz x0` (no table), `cmp x1, #0x1000` + `b.hs` (a code past any builtin's
  `funcs_count` — the largest is opengl32's 3107, which is also why
  `virtual_ios.c`'s stub table is 4096 entries), and `cbz x16` after the load
  (a NULL entry inside a real table). All three branch to
  `Lunixcall_no_table` (`signal_arm64_ios.c:12322-12325`), which calls
  `ios_unixlib_null_call()` (`signal_arm64_ios.c:12192`) and rejoins the normal
  epilogue at `Lunixcall_return`, so the return path, the `restore_flags`
  check and the stack switch are the ones that were already there. The helper
  returns **STATUS_NOT_IMPLEMENTED** and logs, once per calling module:

  ```
  [unixlib] call with NULL handle from <module>+0x<off> code=N handle=0x0 -> STATUS_NOT_IMPLEMENTED
  ```

  naming the caller through `ios_jit_reverse_translate()` + `ios_pe_module_name()`
  for PE code in the JIT pool and `dladdr` otherwise. **One check covers both
  bitnesses**: FEX's wow64 bridge (`WOW64/Module.cpp:764`, the
  `BridgeInstrs::UnixCall` arm of `HandleSyscallImpl`) forwards the guest's
  handle verbatim into this same dispatcher, which is why n60's `lr` is inside
  `libwow64fex.dll`. Nothing was added to FEX. The faulting instruction is now
  at `__wine_unix_call_dispatcher+0x68`, not `+0x5c`, so older logs read
  against the new binary need that offset shifted.

  **2. dnsapi has a unix side.** `build/ntdll-unix/dnsapi_unixlib_ios.c` is
  upstream `dlls/dnsapi/libresolv.c` compiled into `libntdll_unix.a`
  (`build/ntdll-unix/build.sh:118-125`, `:174`) the way ws2_32's and dwrite's
  are, and bound by name in `load_builtin_unixlib` at
  `virtual_ios.c:7613` — both tables, `dnsapi_unix_call_funcs` and
  `dnsapi_unix_call_wow64_funcs`. Upstream expects configure to have linked
  `-lresolv`; this file instead resolves the three things libresolv.c actually
  uses out of `/usr/lib/libresolv.9.dylib` with `dlopen`/`dlsym` at first use —
  `res_9_ninit`, `res_9_nquery` and `__res_9_state` (the `_n` forms on purpose:
  they take the state explicitly and report through `state->res_h_errno`, so
  the object references neither the process-global `_res` nor `h_errno`).
  `llvm-nm -u` on the result names no new symbol beyond
  `dlopen`/`dlsym`/`pthread_once`, so **the app's final link is unchanged** —
  which is the whole reason for the `dlopen` over `-lresolv`. Every path has a
  no-libresolv fallback that RETURNS: an all-zero state (`nscount` 0 ->
  `DNS_ERROR_NO_DNS_SERVERS`) and `TRY_AGAIN` -> `map_h_errno` ->
  `DNS_ERROR_RCODE_SERVER_FAILURE`. A lookup that fails is a normal documented
  outcome for a Windows program; a process that dies inside the lookup is not.
  `HAVE_RES_GETSERVERS` and `HAVE_STRUCT___RES_STATE__U__EXT_NSCOUNT6` are
  deliberately left off — one fewer dynamic symbol and one fewer struct layout
  to match, at the cost of an IPv6-only server list, and queries use the
  state's own servers either way.

  **3. A second fault on the same path, found while building the test.** The
  wow64 bridge converts the outer argument-block pointer with plain arithmetic
  (`GuestWindow::ToHostPtr`: `host = B + guest`), because guest address 0 must
  map to the window's deliberately unmapped first page so a guest null
  dereference still faults. That is right for a pointer the guest dereferences
  and **wrong for an argument block that is allowed to be absent** — and
  `set_serverlist` is exactly that: `DnsQuery_UTF8` passes its `servers`
  parameter straight to `RESOLV_CALL( set_serverlist, servers )`, and that
  parameter is NULL for every `DnsQuery_A` that does not name its own servers.
  A 32-bit NULL therefore arrived at the unix side as `B`, which is not NULL,
  and `if (!addrs …)` would have read the unmapped page and faulted the HOST on
  the first query. `wine/dlls/dnsapi/libresolv.c:419-422` adds
  `wow64_resolv_set_serverlist`, which round-trips the block through
  `ios_wow_host_ptr( ios_wow_guest_ptr32( args ) )`: exact for a real block,
  NULL for `B`, and the identity off this port. **This is a generic hazard, not
  a dnsapi one** — any unixlib entry whose argument block may legitimately be
  NULL has it, and the one-line alternative is to make the bridge itself
  NULL-preserving (`Args ? ToHostPtr(Args) : nullptr`,
  `WOW64/Module.cpp:764`). That was left to FEX's owner rather than changed
  here, because only `libntdll_unix.a` was rebuilt in this pass and a FEX
  source change that is not in the shipped `libwow64fex.dll` is worse than no
  change at all.

  **4. Refusals are visible now.** `ios_bind_unixlib_table()` and the
  UNRECOGNISED-module branch logged their refusals with `ERR`, and
  `virtual_ios.c`'s debug channel is `virtual` while the app runs
  `WINEDEBUG=err+all,err-virtual` (`WineProcessBridge.m:505`) — so **every one
  of those lines has been invisible**, which is why n60 shows dnsapi's DllMain
  complaining and no `[unixlib]` line for it at all. Both now use `dprintf(2)`
  like the success lines, and both say `has no unix side on this port`
  (`virtual_ios.c:7479`, `:7665`). A library losing its unix side is the first
  half of every NULL-handle crash; it has to be loud.

  **Test.** `build/x86-tests/dns-x86.c`, built by `build-dns-test.sh` into
  **`dns-x86.exe`** (i386, no CRT, imports asserted to be dnsapi + kernel32
  only), run from the launcher's Custom path popup as
  `C:\windows\syswow64\dns-x86.exe`. It calls `DnsQuery_A("localhost",
  DNS_TYPE_A)` and `DnsQuery_A("madeira-dns-test.invalid", DNS_TYPE_A)` — both
  with `aipServers = NULL`, which is what exercises item 3 — then
  `DnsQueryConfig(DnsConfigDnsServerList)` twice (size, then fetch), whose
  argument block carries two guest pointers OUT of 32-bit code. It prints
  `MADEIRA-DNS: <what> status=<n> …` per call and exits **54** when every call
  RETURNED, whatever it returned: 9002 (`DNS_ERROR_RCODE_SERVER_FAILURE`) is
  the expected answer where the sandbox leaves libresolv with no nameservers
  and is a pass. 60 is a query that claimed `ERROR_SUCCESS` with no records —
  the "fake success" shape — and 61 an impossible size answer. **No
  `MADEIRA-EXIT` line at all is the original bug.** No launcher button was
  added: ContentView is another track's file this pass.

  **What to look for in the next log:** `[unixlib] dnsapi (module 0x…) ->
  wow64 table (0x…)` at load, `[unixlib] dnsapi: libresolv loaded (0x…)` (or
  the `NO libresolv on this device` line) at the first query, and **no**
  `err:dnsapi:DllMain No libresolv support`. If some other library still calls
  through a NULL handle, it now announces itself by name in one
  `[unixlib] call with NULL handle from …` line instead of taking the process
  with it.
- 2026-09-15 late — Logs 59-63 (DRM-free 1.10 build of the 2001 title,
  the UE3 game with a physical pad). Title crash moved to a HOST NULL read
  in `__wine_unix_call_dispatcher` (table=0): dnsapi's unix side never
  bound on this port ("No libresolv support") and its DnsQuery still
  issued the call → fixed twice: dispatcher refuses a NULL/short table
  with STATUS_NOT_IMPLEMENTED (`[unixlib] call with NULL handle from …`),
  and dnsapi is bound via `dnsapi_unixlib_ios.c` (libresolv.9 through
  dlopen, both tables) + `dns-x86.exe` (exit 54, run via the Custom popup).
  Also found: wow64 unix-call bridge converts a guest NULL arg block to B
  (documented; NULL-preserving bridge left to FEX). 77 MB log = FEX's
  `Add SMC interval` printed ~100/s from the eager DEP sweep arming write
  traps on every RW region (3.2 % CPU in `unixcall_wine_dbg_write`) → eager
  promotion removed entirely (lazy on decode miss only), log capped at 64.
  Physical thumbsticks dead: the pad slot was never published (per-sample
  `extendedGamepad` fetch could be nil → `continue`), `src=phys` was
  derived from the slot not the sample; profile now captured at attach,
  `lxf=…` raw floats + `ANALOGUE SILENCE` verdict + slot read-back in the
  10 s line. UI: HUD drag jitter = `.local` drag coordinate space on a
  moving view (→ `.global`); tiny landscape joystick = portrait
  `JoystickPadState.shared` face never hidden in landscape; dead landscape
  HUD buttons = `MadeiraMetalView` had no width constraint and covered the
  pillarbox bar (`.frame(width: gameW)`); `[hud] tap …` on every button;
  30 fps cap = vsync mode 3 (`presentDrawable:afterMinimumDuration:1/30`).
- 2026-09-16 — Logs 64/65: the 2001 title now passes DNS (dispatcher
  guard fired once, dnsapi bound) and exits 1 after
  `wined3d_adapter_create_output Failed to initialise output \.\DISPLAY1
  hr 0x80070057` (a wined3d DLL pulled in by dxdiagn) — assigned: wined3d
  output init against the virtual display, DXMT adapter mode list from the
  real mode table, `[d3d9-modes]` log, `d3d9modes-x86.exe` (exit 55).
  Landscape layout: the game placeholder was a `height*4/3` column (from
  the 1024x768 days) so every display mode operated inside a 4:3 box
  (Fill/Stretch looked horizontally stretched, Fit never grew); now the
  whole view is the game area, the FPS pill and display-mode button are
  portrait-only (user), and "Fill height" = uniform scale to the full
  height with side bars.
- 2026-09-16 — **`wined3d_adapter_create_output` E_INVALIDARG was never about a
  DEVMODE: the virtual-monitor regime's LAST unguarded win32u entry point.**
  Log 65, the 2001-era 32-bit title, exits 1 from its own renderer-init path
  with four `err:d3d:wined3d_adapter_create_output Failed to initialise output
  L"\.\DISPLAY1", hr 0x80070057` and nothing else. Traced the whole chain:
  `wined3d_adapter_init` (`wine/dlls/wined3d/directx.c:3441`) walks
  `EnumDisplayDevicesW`, gets our synthesized `\.\DISPLAY1` with
  `ATTACHED_TO_DESKTOP|PRIMARY`, and calls `wined3d_adapter_create_output`
  (`directx.c:3387`) → `wined3d_output_init` (`directx.c:3360`), whose FIRST
  statement is `D3DKMTOpenAdapterFromGdiDisplayName`, and whose only
  `E_INVALIDARG` is that call failing. Not `EnumDisplaySettingsExW`, not
  `GetMonitorInfo`, not `dmFields`/`dmSize`/`DM_POSITION`/registry-vs-current —
  none of those are reached. Below it,
  `d3dkmt_open_adapter_from_gdi_display_name` (`sysparams_ios.c`, now :4182)
  does `find_source(L"\.\DISPLAY1")`, and in this port the sources list is
  **empty** (`update_display_cache` takes the `is_service_process()` branch,
  `clear_display_devices()`, one `virtual_monitor`), so it returns
  STATUS_UNSUCCESSFUL for the very name this driver hands out.
  `NtUserEnumDisplayDevices`, `NtUserEnumDisplaySettings` and
  `NtUserChangeDisplaySettings` each already had an `ios_virtual_monitor_active()`
  branch for exactly this; the D3DKMT one did not. Fixed the same way: accept
  `ios_virtual_device_name()`, hand back a stable LUID (there is no `gpu` object
  either) through `NtGdiDdDDIOpenAdapterFromLuid` — which succeeds for any LUID,
  only WARNing that no Vulkan physical device matches — and `VidPnSourceId = 1`.
  **This is what every wined3d-based DLL needs**: with zero outputs `ddraw`,
  `d3d8`, `dxgi` and `d3d10/11` all report "no display attached". `ddraw.dll`
  was the loader here (log 65 line ~4795, before `dxdiagn` even loads); the
  title never reached `Direct3DCreate9` itself. Also stopped
  `GetMonitorInfo(MONITORINFOEXW)` reporting `szDevice = "WinDisc"` (Windows'
  name for a DISCONNECTED monitor) for the virtual monitor — it is
  `\.\DISPLAY1` now, which is what DXMT's win32 wsi feeds straight back into
  `EnumDisplaySettingsW`.
  DXMT side: the D3D9 adapter's mode list only ever had THREE entries
  (`640x480, 800x600, current`) in `wsi_monitor_headless.cpp` while user32 has
  reported 14+ since 2026-09-14 — it now reads `EnumDisplaySettingsExW`
  verbatim where user32 exists, and mirrors `ios_standard_modes[]` (same
  index-0-is-current, same ≤2× pixel-count filter) below the Win32 boundary
  where it does not. Note for anyone re-reading this: the **i386** PE
  `d3d9-emulated.dll` does not compile that file at all —
  `research/dxmt/src/util/meson.build` routes `cpu_family == 'x86' && windows`
  to `wsi_monitor_win32.cpp`, which was already going through user32; the
  headless copy serves the native ARM64 frontend and the aarch64 PE.
  `GetAdapterModeCount`/`EnumAdapterModes` (+ the `Ex` pair) also stopped
  rejecting everything but `X8R8G8B8`: the display behind them is the virtual
  monitor, whose `ChangeDisplaySettings` ignores `dmBitsPerPel` entirely, so
  `R5G6B5`/`X1R5G5B5`/`A2R10G10B10` really are settable — and `CheckDeviceType`
  gates a FULLSCREEN device on `GetAdapterModeCount(DisplayFormat) != 0`, so a
  title that offers 16-bit colour was being told the adapter has no modes at all.
  New `[d3d9-modes]` trace (`Logger::info`, both frontends): one line per
  process with the mode count, the current mode and the first eight modes, and
  one line per `CreateDevice`/`CreateDeviceEx`/`Reset` as
  `WxH fmt refresh= windowed= count= -> hr 0x…`.
  Test: `build/x86-tests/d3d9modes-x86.c` →
  `C:\windows\syswow64\d3d9modes-x86.exe` (`build-d3d9modes-test.sh`, imports
  kernel32+user32+d3d9 only). Asserts ≥ 6 modes, no degenerate entry, 640x480
  and 800x600 present, `GetAdapterDisplayMode == GetSystemMetrics(SM_CXSCREEN/
  SM_CYSCREEN)`, `CheckDeviceType(HAL, X8R8G8B8, fullscreen)` OK, then creates
  and presents a FULLSCREEN device at 800x600 and at 640x480 and restores the
  mode. **Exit 55 = pass**; 60-70 each name one failed check (see the file
  header).
  **What to look for in the next log:** the `err:d3d:wined3d_adapter_create_output`
  lines GONE, replaced by `[vmode] synthesized D3DKMTOpenAdapterFromGdiDisplayName
  -> hAdapter … vidpn 1` (≤ 4 times); then `info: [d3d9-modes] adapter 0
  count=N current=WxH@60 | …` with N in the teens, not 3; and — the point of
  the exercise — `info: [d3d9-modes] CreateDevice WxH FMT refresh=R windowed=0
  -> hr 0x…` naming the mode the title actually wants and the HRESULT it got.
  If the title still fails with a healthy count and no `CreateDevice` line at
  all, it is refusing before D3D9 and the next thing to read is what `ddraw`
  answers (`IDirectDraw7::EnumDisplayModes` / `GetDisplayMode`), not the mode
  table.
- 2026-09-16 — Logs 66-70. UE3 game: loading is 99 % failing file
  lookups (`open=4805/9889 ms fail=4805` per 10 s = 2 ms per miss, ~480/s,
  mostly DISTINCT probe names) → directory-contents cache assigned +
  whole-path negative cache to default ON. 55 MB log = DXMT `[mem-census]`/
  `[trim]` (22k reports × 8 lines) + `[iOS-xrem]` 42k lines → capped.
  2001 title: ddraw probe fails (`wined3d_adapter_gl_init` no GL), then
  `[d3d9-modes] count=14` and NO CreateDevice, process idles → NO3D
  fallback + `[d3d9-caps]` trace + legacy caps audit assigned. 2008 title:
  CreateDevice 800x600 OK then guest NULL+4 in game code (VC80 SxS
  manifest missing, DINPUT8/XINPUT loaded) → `[d3d9-last]` crash ring +
  VC runtime WineSxS manifests + full i386 farm audit + dinput joystick
  over the gamepad query assigned. 64-bit title: no new log this round.
- 2026-09-16 — Log qp4 (934 s play session, 55.8 MB) + q67: **the spin
  governor's pause loop is the largest single consumer of CPU in the process**,
  the census is the whole log, and an occlusion query that ends in an empty
  submission is never settled.
  (1) SPIN GOVERNOR (`ntdll/unix/sync.c:3254-3308`). `[prof]` names
  `ios_spin_governor+0x320` — the `isb sy` delay loop in `ios_cpu_pause()` —
  as `top1` in **79 of the session's 94** 10 s windows (`fstatat` takes it in
  12 of the remaining 15, during the file-lookup phases): **23.6-31.7 % of ALL
  CPU mid-game and 50.6-60.8 % during level loads**, ahead of the JIT
  (13-31 %) and ahead
  of the file lookups (19-42 %). `[sleep0]` says why: 2.6 M governed calls per
  10 s window out of ~500 streaks, i.e. ~2 µs of ISB per call for the whole
  length of a streak. The ml970 ladder escalates the GAP between kernel
  entries but not the PARK taken at each one, and the park is the only part
  that gives the core back, so the duty cycle ran backwards — 75 % parked on
  rung 0, then 15 %, 10 %, 12 % as the wait got longer and more hopeless.
  Retuned so park sits just under gap on every rung: gap
  `{20, 100, 250, 400} µs`, park `{15, 80, 240, 380} µs` → ~95 % parked.
  The latency this costs is bounded by the rung's park length and
  `[sleep0] hist us` prices it: 96 % of finished streaks are ≥ 2 ms, p50
  time-to-progress 8 ms, p80 16 ms, under 5 % finish inside 1 ms — so the
  deepest rung's 380 µs granularity is < 5 % of the median wait it applies
  to, against giving back ~0.7 of a core. Policy, rungs, the first-kernel-
  entry `sched_yield()` and the 1 ms `IOS_SPIN_PARK_MAX_NS` cap are all
  unchanged; only the two tables moved.
  (2) OCCLUSION QUERY LOST IN AN EMPTY SUBMISSION
  (`dxmt_context.cpp:865-893`, `dxmt_occlusion_query.hpp:129-144`).
  `VisibilityResultQuery::getValue` reports only once `seq_id_issued` reaches
  `seq_id_end`, and the only thing that advances `seq_id_issued` is
  `~VisibilityResultReadback` calling `issue()`. When `vro_state_.reset()`
  returns 0 — a submission that counted no visibility samples at all, e.g. a
  flush with no render encoder — no readback is built, so nothing ever issues
  for that `seqId`; the `erase_if` that follows then dropped every query whose
  END landed there out of `pending_queries_`, and a query is only ever issued
  through a readback that captured it, so no later submission could settle it
  either. `end()` already handled begin and end sharing one seq id and offset;
  what was unhandled is a query that BEGINS in one submission and ENDS in an
  empty one — permanently stranded, with D3D9 `GetData` polling it forever.
  Measured as `[d3d9-query] worst_ever` = **178 s in q67** (line 301509) and
  10.3 s in qp4 (line 413203) against `issue_to_complete_avg` of 34 ms. New
  `issueEmpty(seqId)` records the seq with nothing to accumulate, which with
  an empty submission is exactly the right value. This is the strongest
  candidate for the blank screen after a death transition: the game stops
  drawing the world, the flush that follows counts nothing, and whichever
  query ended in it never answers.
  (3) THE LOG WAS THE CENSUS. 441,203 of qp4's 454,514 lines and 54.2 MB of
  its 55.8 MB are `[mem-census]`/`[buf-site]`/`[dyn-census]`/`[trim]`/`[live]`
  (22,449 reports × ~31 ERR lines, ml684's per-30-seq trigger firing several
  times a second on the encode thread) plus `[iOS-xrem]` (58,854 lines: ml437's
  1-in-64 sample was calibrated against 4,234 events and the real rate is
  3.8 M). `mem_census_report` is now emitted once per 10 s — same cadence as
  `[prof]` and `[srv-stats]`, so the three line up — with `why` starting
  `warn` never throttled and the first report always emitted
  (`dxmt_mem_census.cpp:167-219`); the trigger stays on the fence where ml684
  put it. `[iOS-xrem]` goes to first 32 + 1-in-1024
  (`FEX/Source/Windows/Common/InvalidationTracker.cpp:768-784`). Nothing else
  in qp4 exceeds 1,000 lines. Expected: a 30 min session lands at ~4 MB, of
  which ~0.8 MB is the periodic census and ~0.4 MB `[iOS-xrem]`.
  (4) MEASURED, NOT CHANGED. `d3d9-emulated.dll` is **4.6 % of all CPU on
  average across the 47 mid-game windows (median 4.2 %, max 8.3 %)** — it
  straddles the 5 % bar rather than clearing it, and the native frontend has
  still never run on a device, so it stays an A/B rather than a new default:
  `Documents/madeira-d3d9.txt` containing `native` selects it, and the
  confirmation is `[d3d9] MADEIRA_D3D9=native` in place of the
  `MADEIRA_D3D9 unset: forwarding to d3d9-emulated.dll` line (qp4 line 1052),
  no `d3d9-emulated.dll` row in `[prof] jit by module`, and a
  `[d3d9-native-census]` table with the same per-frame shape as
  `[d3d9-census]` (SetSamplerState ~10.6 k/f, SetRenderState ~4.8 k/f,
  DrawIndexedPrimitive ~391/f, TestCooperativeLevel ~511/f).
  **`[fastsync] OFF` (qp4 line 207) is the biggest remaining server win and
  it is a knob, not a code change**: the device has
  `MADEIRA_FASTSYNC=0` in `Documents/madeira-env.txt` (line 13), so
  `event_op` — `NtSetEvent` 10-12 k + `NtResetEvent` 6.7-8.9 k per 10 s — is
  **half of all 36-45 k server requests**, and the ml972 fast path that would
  serve them in-process is inert (`fastsync cache: learn_ev=0` in every
  window). `MADEIRA_FS_NEGCACHE=1` is off the same way
  (`[fs-stats] wholeneg=OFF`). Boot, non-file contributors in order: the
  governor again (50.6-60.8 % of CPU in the t+60…130 s windows), wineserver
  IPC (~21 % of CPU in the t+50 s window: `read_reply_data` 7.5 %,
  `read_request` 5.0 %, `wait_select_reply` 2.6 %, `call_req_handler` 1.2 %,
  server `main_loop` 4.5 %), then JIT compilation (`libwow64fex.dll` 5.9 % of
  CPU in the first window, +7,306 blocks / 562,933 guest insts / 9.35 MB of
  host code in the t+40 s window alone; 38.8 k blocks for the session at a
  98 % cache hit rate). **PE image pool copies are NOT worth caching across
  sessions**: all 95 of them happen before the first present and total
  100.7 MB (`used=0x600c000`), which is ~0.1 s of a ~40 s boot. FEX codegen
  left alone this round — `[prof] jit tso` reports 33-41 % of memory ops
  carrying TSO semantics, so the imm9/EA ideas are real but worth ~1-2 % of
  total CPU against a 30-60 % item, and they are not provable from these
  20 `block#` dumps.
  **What to look for in the next log:** `ios_spin_governor` must be GONE from
  `[prof] top1..top8`; `[sleep0]` `sleep0`+`yield` per 10 s should fall from
  ~2.6 M to roughly 130 k with `park` rising only slightly, from ~2.5 k/s to
  ~3.0-3.2 k/s — the gaps shrank by ~20 %, so a streak takes about as many
  kernel entries as before, it just spends them asleep instead of awake — and
  `to-progress p50` must stay at 8192 µs (if it moves to 16384 µs the park is
  too long and rung 3 should go back to 240 µs); `busy` cores should drop
  from ~2.2 to ~1.5 at the same frame rate; `[d3d9-query] worst_ever` must
  stay within a few times `issue_to_complete_avg` instead of 10-178 s; and the
  log itself must come back under 5 MB with `[mem-census] ml678 why=seq`
  appearing once per 10 s next to each `[srv-stats]`.
- 2026-09-16 — ml915: directory-contents cache + whole-path fast path
  (`ntdll/unix/file.c` only; `build/x86-tests/fs-x86.c` phase 10). q66 said
  the UE3 title's load is `open=4805/9889.131ms fail=4805` per 10 s — 99 % of
  wall time in `lookup_unix_name` for opens that FAIL, 2.06 ms each — and the
  names are mostly DISTINCT (localised/variant package spellings), so ml912's
  per-COMPONENT and ml913's per-PATH negative entries are written once and
  read never: every probe still walked the path and scanned a directory of
  thousands. Two pieces, both keyed where the repetition actually is.
  (1) `ios_dc_*` (`file.c:1034-1424`): the first case-insensitive scan of a
  directory is read into a table — exact spellings in readdir order, plus an
  FNV hash of each name's `ntdll_towupper`-folded UTF-16 form, in an
  open-addressed index — keyed on `(dev, ino)` and stamped with ns `mtime`
  AND `ctime`. One `fstatat` of the directory revalidates the whole table, so
  any name in it, present or absent, is one syscall and a hash probe.
  Semantics are upstream's: the exact-case `fstatat` still runs first
  (`find_file_in_dir:4526`), the table is only consulted after the
  `is_legal_8dot3_name` and `get_dir_case_sensitivity` gates, a candidate is
  confirmed with a real `wcsnicmp` (equal-under-`wcsnicmp` implies equal
  hash, which is what makes a miss sound), the LOWEST readdir index wins so
  case siblings resolve as before, and 8.3 names bypass the table (they match
  a second way inside the same pass) while still building it. The scan that
  builds a table now reads to the END even after it matches (`:4676`) — one
  extra partial walk, once per directory. Bounds: 64 directories / 4 MB
  total, 1 MB and 65536 names per directory, LRU to get under the count and
  largest-first to get under the bytes. Stamp is read from the dir fd BEFORE
  the walk (ml914's rule), and every create path in this process also drops
  the table by path (`ios_dc_invalidate_path`, called from `NtCreateFile`
  when `created`, `NtDeleteFile`, rename and link) so a create-then-open
  inside one clock tick cannot read a table older than the create.
  (2) The table alone does not move the headline number: a failing open still
  paid ~7 `fstatat` walking the path. So `lookup_unix_name:5371` splits the
  question — a `'\2'`-namespaced, EXACT-spelling entry in `ios_pc` maps the
  requested PARENT path to its resolved directory (recorded at `:5686`,
  only on `STATUS_OBJECT_NAME_NOT_FOUND`, where `pos` is exactly the parent),
  and the leaf is answered by that directory's table. One `fstatat` validates
  both. Absent leaf AND absent `<leaf>?` ⇒ `STATUS_OBJECT_NAME_NOT_FOUND`
  returned before the shortcut stat: **one syscall for a whole failing open**.
  An EXACT-byte match in a directory whose resolved spelling is the requested
  one returns `STATUS_SUCCESS` with the buffer untouched, so a successful open
  is still one `fstatat`; every other kind of match falls through and is
  resolved the long way, so "exact case beats readdir order" is untouched.
  Guards are ml913's: never `open_reparse` (`NtQueryAttributesFile` passes it,
  so `GetFileAttributes` never takes this path), only `FILE_OPEN`/
  `FILE_OVERWRITE`, never a legal 8.3 leaf, never a relative `root_fd`, never
  a trailing separator. Residual hazard is ml913's and unchanged: a
  case-sibling directory created from outside this resolver can make a cached
  parent resolution wrong.
  (3) `MADEIRA_FS_NEGCACHE` now defaults ON (`=0` disables); new
  `MADEIRA_FS_DIRCACHE=0` disables the table and with it the fast path.
  `[fs-stats]` gains `open: … (fail=N fail_avg_us=N)`, a `dircache=` line
  (`dirs/entries/bytes/hits/misses/scans/evict/stale/inval/big`), a `dirfast:
  notfound/exact/nocache` line and a `wdir` phase.
  Proof before device: the `ios_dc_*` code was extracted verbatim and run on
  the host under ASan/UBSan against a brute-force model of the readdir loop —
  3600 names including case-sibling pairs, 30800 probes (own spelling, upper,
  lower, 20000 near-miss absentees); every answer, every returned spelling and
  every exact-vs-case-insensitive verdict matched, and the bounds and
  invalidation paths held. `fs-x86.exe` phase 10: 3000 files in one directory,
  then 5000 distinct absent names opened three times (two disjoint sets plus a
  repeat, each timed and printing `avg N us` — the same quantity as
  `fail_avg_us`), then create/delete/rename in the hot directory and
  flipped-case opens of files that exist. Phases 2-6 now check every
  transition with `CreateFile` as well as `GetFileAttributes`, because only
  the former reaches the whole-path caches. Exit 47 = pass.
  **What to look for in the next log:** `[fs-stats] open: … fail_avg_us=` must
  fall from ~2060 to ~150-350 (one `fstatat` in this sandbox is ~155 µs), and
  `lookup=9889ms/4805` to well under 1 s per 10 s; `dircache=ON: dirs=` a
  handful to a few dozen with `scans=` going to 0 after the first windows
  while `hits=` climbs into the thousands; `dirfast: notfound=` should be most
  of `fail=`, with `nocache=` only in the first windows. If `stale=` or
  `inval=` is large the game is writing into the directories it probes and the
  table is being rebuilt — look at `scans=` next. If `fail_avg_us` stays high
  while `dircache` hits are high, the cost is the walk, not the scan, and
  `dirfast: nocache=` will say the parent resolutions are not being reused.
  A/B: `MADEIRA_FS_DIRCACHE=0` restores the ml914 build (table and fast path
  both gone); adding `MADEIRA_FS_NEGCACHE=0` restores ml912.
- 2026-09-16 — ml760: **the farms stop being a list of the modules somebody
  already watched a program fail without.** Three things, one goal: a 32-bit
  game should at least BOOT without anyone having tested that game.

  **(1) The breadth round.** `.xtool/build-wine-i386.sh` derived its whole
  target list from the file names in `app/Madeira/aarch64-windows/` plus a
  hand-written `EXTRA_DLLS`. That can only ever contain what has already been
  missed, and the failure it misses is not a degradation — it is
  `err:module:import_dll Library FOO.dll (which is needed by L"…\game.exe") not
  found` and the process never reaches its first instruction. There is no
  partial symptom to notice, so the only way to discover a gap is to run the
  exact program that needs it. So the script now takes the complement: it reads
  every `dlls/<x>/i386-windows/<file>` and `programs/<x>/i386-windows/<file>`
  RULE out of the configured tree's `Makefile` (makedep emits one only for a
  module actually configured for this arch, which makes the rules both the
  complete list and the correct one) and builds all of them minus a named,
  justified skip list — `.xtool/build-wine-i386.sh:332` (`BREADTH_EXT_RE`),
  `:336` (`SKIP_BREADTH_REASON`), `:405` (the `HAS_RULE` prune). Reading rules
  also distinguishes, for the first time, "module not configured for i386"
  (conhost, services, wineboot, rpcss, winecoreaudio.drv — the WoW64 host side,
  built for the native arch only) from "build failed", which the name-based
  phase reported identically.
  Result: **+498 modules, 241 -> 742 files, 104.5 MB -> 177.2 MB**, `built: 720
  failed: 0`, all PE32/pe-i386, **0 missing cross-imports**.
  Skipped, with the reason in the script: the 19 `*.sys` kernel drivers plus
  `ntoskrnl.exe`/`winedevice.exe` (WoW64 runs drivers 64-bit only and this app
  ships no `services.exe`/`winedevice.exe` at all, so a 32-bit `.sys` is never
  loaded — this includes `hidclass.sys`, which is why the DirectInput work below
  does not go through HID); `winemac.drv`, `wineps.drv`, `winevulkan`/
  `vulkan-1`, `opencl`, `wpcap` (host backends with no iOS unixlib; the tree is
  configured `--without-vulkan` and graphics go through DXMT/Metal); `wow32`,
  `winevdm`, `vga`, `hal`, `w32skrnl` plus every `.dll16/.exe16/.drv16/.vxd`
  (the 16-bit NE layer, with no 16-bit modules under it in a WoW64 tree);
  `winemenubuilder`, `wineconsole`; and three that built fine and were then
  dropped on cost — `aero.msstyles` (7.4 MB of theme resources and nothing
  selects a visual style), `winedbg.exe` (4.5 MB, only ever spawned by a crash
  dialog this port does not show), and `ir50_32.dll`. That last one is worth
  recording precisely, because the usual assumption is wrong in both
  directions: **Wine DOES have `dlls/ir50_32`** — but it is a thin VfW wrapper
  whose decoder is `winegstreamer`'s, and the first full breadth run's closure
  check reported exactly one gap, `ir50_32.dll -> winegstreamer.dll`, which
  needs a GStreamer unixlib that is not built for iOS. Also absent from Wine
  entirely, so unbuildable rather than skipped: **`mfc*` — there is no
  `wine/dlls/mfc42` or any other MFC module**, which is why the VC80/VC90 MFC
  side-by-side assemblies below cannot be seeded either. Gecko and wine-mono
  remain external packages (`mshtml.dll` ships as the stub; `mscoree`/`fusion`
  now ship so the .NET detection path answers instead of failing at load).

  **(2) `windows\winsxs` for the Visual C++ runtimes.** A 32-bit title in the
  last log logged `Could not find dependent assembly "Microsoft.VC80.CRT"
  (8.0.50727.762)`. Unlike the Common-Controls message this port has logged
  forever, that one is fatal-shaped: a VS2005/2008 build carries its CRT as a
  side-by-side dependency in its own manifest and imports `MSVCR80.dll` by
  name, and every DLL it later loads with the same dependency fails the same
  way. `WineProcessBridge.m` already seeded ONE assembly; it now seeds the ten
  `WINE_MANIFEST` assemblies the tree actually has
  (`grep -rn WINE_MANIFEST wine/dlls --include=*.rc`): Common-Controls 6.0,
  **VC80.CRT / VC90.CRT** (each with its `msvcr`/`msvcp`/`msvcm` trio),
  **VC80.ATL / VC90.ATL**, GdiPlus 1.0 and 1.1, and MSXML 3 / 4 / 6 — for
  `x86`, `arm64` and `amd64`, from a table at
  `app/Madeira/WineProcessBridge.m:1135`, with the naming taken byte-for-byte
  from `dlls/setupapi/fakedll.c` `append_manifest_filename` (arch, name and
  language lower-cased and truncated, publicKeyToken and version verbatim, the
  literal `deadbeef` where Microsoft puts a content hash):
  `x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_8.0.50727.9672_none_deadbeef`.
  **An older request still matches**, which is what makes seeding these blind
  worth doing: `ntdll/actctx.c build_manifest_filter` pins only major.minor
  (`_%u.%u.*.*_`) and `lookup_manifest_file` then accepts any build/revision
  `>=` the requested one, so the 8.0.50727.**762** the title asked for is served
  by the 8.0.50727.**9672** Wine ships, and one assembly per major.minor covers
  every service pack of it. The manifest text and the assembly directory are
  now generated together from the same `<file>` list, so a farm missing (say)
  `msvcm80.dll` drops that name from BOTH rather than advertising a file that
  is not there — the same "never redirect a load into an empty directory" rule
  the Common-Controls seeding already had. VC100+ is NOT seeded and there is
  nothing to seed: VS2010 stopped deploying the CRT side-by-side.

  **(3) DirectInput can finally see the controller.** A pad reached Windows
  only as XInput (`NtUserCallTwoParam_GetGamepadState`). `dinput`'s only
  joystick backend, `joystick_hid.c`, enumerates devices `winebus.sys` creates
  — and there is no `winebus.sys` here, no driver host to load it into, and no
  HID transport under it. So `EnumDevices(DI8DEVCLASS_GAMECTRL)` returned
  NOTHING, and every DirectInput-era title saw no controller while XInput-era
  titles in the same prefix worked. New `wine/dlls/dinput/joystick_ios.c`
  synthesises ONE joystick from the same gamepad query, with the object set
  `winebus.sys` gives an XInput pad so a game's stock controller map lands where
  it expects: X/Y left stick, Rx/Ry right stick, Z/Rz triggers, an 8-way POV
  hat from the d-pad, and buttons 0..9 = A B X Y LB RB Back Start LThumb
  RThumb. It reuses dinput's own scaling (`scale_value`/`scale_axis_value`
  logic over `struct object_properties`) so `DIPROP_RANGE`/`DEADZONE`/
  `SATURATION` behave as they do on a HID device; it is offered ahead of the
  HID loop in `wine/dlls/dinput/dinput.c:391` and recognised by its fixed
  instance GUID in `wine/dlls/dinput/dinput.c:288`; force feedback is
  unsupported and says so (`guidFFDriver == GUID_NULL`, no
  `DIDC_FORCEFEEDBACK`) rather than accepting effects and dropping them;
  keyboard and mouse are untouched. **There is no `#ifdef`**:
  `NtUserGetGamepadState` is `NtUserCallTwoParam` with a code appended to the
  end of the enum, so a win32u that does not implement it answers 0 —
  bit-for-bit "no pad in that slot" — and on a stock Wine this file enumerates
  nothing and the HID path runs exactly as before. Sampling is buffered from
  polling: there is no report thread and no `read_event`, so
  `dinput_main.c`'s input thread skips the device (it requires both), and
  `device.c` calls `Poll` at the top of BOTH `GetDeviceState` and
  `GetDeviceData`, so a game that never calls `Poll` itself still works. The
  product ID is deliberately NOT Microsoft's `0x045e`: a family of DirectInput
  games filters that vendor out of their own enumeration on the assumption the
  device is already visible through XInput, which would make exactly the games
  this exists for ignore it (`wine/dlls/dinput/joystick_ios.c:120`, pid.codes
  `0x1209`). `dinput` + `dinput8` gain `win32u` in `IMPORTS` and are rebuilt
  for all three farms.
  **Test: `dinput-x86.exe`** (`build/x86-tests/dinput-x86.c`,
  `build/x86-tests/build-dinput-test.sh`) — i386 PE, no CRT, imports
  `dinput8` + `ole32` + `kernel32` only; enumerates `DI8DEVCLASS_GAMECTRL`
  printing every device it is offered, creates the first,
  `SetDataFormat(&c_dfDIJoystick2)`, acquires, and polls 10 s printing
  `MADEIRA-DINPUT:` lines on every state change.
  **58** = a device enumerated AND its state changed (it works), **68** = the
  enumeration produced nothing, **69** = it enumerated but never moved; 64/65/66
  are create/setup/acquire failures. Run `xinput-x86.exe` first to tell "no pad
  paired" apart from "dinput does not expose it".
  *(The launcher button for it has to be added by whoever owns ContentView.)*

  **(4) The 64-bit farms, and the budget.** The same "build everything"
  argument applies word for word to `aarch64-windows` and `arm64ec-windows`;
  what does not apply is the cost. A 64-bit PE here is roughly 2.5x the same
  module built for i386 (compare the two `shell32.dll`s) and there are two such
  farms, so the sweep would cost about 5x the i386 one — several hundred MB in
  an IPA with ~120 MB of room. `.xtool/build-wine-64.sh` therefore grows a
  curated `DEFAULT_DLLS` (`.xtool/build-wine-64.sh:150`) instead, documented
  entry by entry: the 2010/2012/2013 VC runtimes (the single largest block, and
  the one whose absence is unconditionally fatal at load),
  `d3dcompiler_43`/`_47` (neither 64-bit farm had ANY d3dcompiler),
  `d3dx9_43`/`d3dx11_43`/`d3dxof`, XAudio2 7/8/9 + `x3daudio1_7` +
  `xapofx1_5`, `dinput`+`dinput8`, `gdiplus`, `riched20`/`usp10`, `msvfw32`,
  and a launcher set (`mscoree fusion xmllite msxml6 wintypes sxs gameux
  normaliz`). It also gains the i386 script's two checks: machine type
  (llvm-objdump calls an ARM64 PE `coff-arm64`, not `pe-aarch64` — the old
  wording made every file look wrong) and **import closure**, which immediately
  found four gaps, two of them pre-existing and silent:
  `dxdiagn.dll -> ddraw.dll` and `bthprops.cpl -> bluetoothapis.dll`, i.e. two
  modules that had shipped in those farms unloadable the whole time. Both are
  now built. `d3dx10_43` (drags a second D3D10 stack in for a generation that
  barely existed in x64), the DirectShow stack (nothing to decode with:
  `winegstreamer` needs GStreamer and `winedmo` needs FFmpeg, neither built for
  iOS) and `msi`/`cabinet`/`msiexec` (the bootstrap EXE of a game installer is
  32-bit in practice) are deliberately left to the i386 farm. A third, smaller
  fix in the same script: targets with no rule for the requested arch are now
  pruned and reported as "not configured for this arch" instead of failing with
  an empty error line — which is what the arm64ec tree does with every program
  (it configures eight) and with `wow64win`.
  Result: aarch64 **148 -> 180 files, 129.5 -> 154.5 MB**; arm64ec **142 -> 164
  files, 145.4 -> 167.6 MB**; `failed: 0` on both, all ARM64 PE, **0 missing
  cross-imports** on both.
  Total farm growth this round: **+119.9 MB uncompressed** (i386 +72.7,
  aarch64 +25.0, arm64ec +22.3), inside the ~120 MB ceiling.

- 2026-09-16 — Logs q68 (a 2001-era D3D9 + ddraw title) and q69/q70 (a 2008-era
  D3D9 + DINPUT8 + XINPUT1_3 + d3dx9_38 title). **Neither title was stopped by
  D3D9, and the second one's null had nothing to do with D3D9 either.** What
  the two logs actually say, then four generic fixes and two instruments.
  **q68 — the 2001 title does not stop at the adapter; it stops in its intro
  movie.** After `[d3d9-modes] adapter 0 count=14` the log has no
  `CreateDevice` and no exit, which reads as "it enumerated modes and refused".
  It did not refuse. In order after the mode enumeration (`q68:1036-1081`) it
  loads `devenum`, `avicap32`, `winmm`, `msacm32`, `msdmo`, `quartz`,
  `msvfw32`, `msrle32`, `msvidc32`, `iccvid` — a DirectShow graph with the
  Video-for-Windows codec set — and immediately before that `dxdiagn`,
  `wbemprox`, `setupapi`, `cfgmgr32` and `mmdevapi`, i.e. a DirectX-diagnostics
  and WMI sweep. The only hard failure in the sequence is `[dll-missing] #1
  L"ir50_32.dll" status=c0000135` (the Indeo 5 video codec, which this port
  does not ship and Wine does not implement). It then creates two threads whose
  start addresses are inside `mmdevapi.dll` (`717b15b4a0` / `717b15ca00`
  against base `717B150000`) and **spins**: the second `[prof]` window is
  `tid=002c=96.7%(jit 82%)` with `top1..top8` all inside a ~200-byte JIT range
  (`0x1389ab7fc..0x1389ab8d0`) — ~97 % of a core in a handful of instructions,
  indefinitely. The audio side says where it stopped:
  `build/ntdll-unix/audio_null_ios.c` logs each entry point at call #1, and the
  log has `process_attach`, `test_connect`, `get_endpoint_ids`,
  `get_mix_format` and `is_format_supported` — and **never `create_stream`,
  `start`, `get_render_buffer`, `main_loop`, `timer_loop`,
  `get_current_padding` or `get_position`**. So the graph asked whether a
  format was supported (`audio_null_ios.c:968` accepts everything), never
  initialised a stream, and something in the graph now busy-waits for a frame
  or a clock that never arrives. It is not deadlocked, it is not showing a
  dialog we fail to draw, and it is not a D3D9 problem: the next step belongs
  to the DirectShow/VfW/audio track. The one thing this track owed it — a
  believable adapter identity for the diagnostics sweep it runs just before —
  is fixed below.
  **q70 — the 2008 title's null is an EMPTY `DISPLAY_DEVICE.DeviceID`, not a
  D3D9 return.** The device is created and presented (`[d3d9-modes] CreateDevice
  800x600 A8R8G8B8 ... -> hr 0x0`, then a full `[d3d9-census] summary 1` with
  2485 calls and `[iOS DXMT] nextDrawable #1`), so the renderer works. The
  fault is `bus_handler BUS #1 ... addr=0x7100000004 insn=0x38bfc31a`
  (`q70:5245`) — decoded, `ldrb w26,[x24]` with `x24 = guestbase + 4`, a
  **one-byte** read of guest address 4 — and the line immediately before it is
  `[vmode] synthesized EnumDisplayDevices adapter idx=0` (`q70:5154`), two WMI
  round-trips after `wbemprox`. `NtUserEnumDisplayDevices`' virtual-monitor arm
  in `build/win32u-unix/sysparams_ios.c` was returning `*info->DeviceID = 0`
  and `*info->DeviceKey = 0` — empty strings. An empty `DeviceID` is not a
  harmless omission: it is the field an application parses to find out which
  GPU it is on, with `p = strstr(dd.DeviceID, "VEN_"); vendor = strtoul(p + 4,
  ...)` and no null check, because on Windows the string is never empty.
  `p + 4` with `p == NULL` is a byte read of address 4. That is the fault,
  exactly. Both fields are now filled in the format the non-virtual path
  produces (`sysparams_ios.c:4340-4390`): adapter
  `PCI\VEN_106B&DEV_0001&SUBSYS_00000000&REV_00` plus a
  `...\Control\Video\{...}\0000` key; monitor
  `MONITOR\Default_Monitor\{4d36e96e-...}\0000` (or the
  `\\?\DISPLAY#...#{e6f07b5f-...}` interface path under
  `EDD_GET_DEVICE_INTERFACE_NAME`) plus a `...\Control\Class\{4d36e96e-...}\0000`
  key. The `[vmode]` trace now prints `flags=` too.
  **One identity, three interfaces.** `0x106B / 0x0001` above is not a new
  number: it is what `MTLD3D9Interface::GetAdapterIdentifier` has always
  reported (`d3d9_interface.cpp:600-612`). wined3d's no3d adapter reported
  `HW_VENDOR_SOFTWARE / CARD_WINE` — **vendor 0, device 0** — which is both what
  a period title's GPU table reads as "no adapter" AND a different GPU from the
  one D3D9 names on the same machine, so a title that asks both concludes it is
  looking at two cards. `wined3d_adapter_no3d_create`'s `gpu_description` is now
  `HW_VENDOR_APPLE / CARD_APPLE_GPU` (`wined3d/directx.c:3390`; enumerators
  added at `wined3d_private.h:2085` and `:2098`), description `"DXMT (Metal) 2D"`,
  vidmem left at the upstream 128 MB. All three answers now agree.
  **wined3d falls back to no3d itself.** There is no OpenGL and no Vulkan here,
  so `wined3d_adapter_gl_create` always fails in `wined3d_caps_gl_ctx_create`
  ("Failed to find a suitable pixel format", `adapter_gl.c:346`) and
  `wined3d_create` returned NULL. ddraw has always retried with `WINED3D_NO3D`
  — twice, at `ddraw.c:5136` and `main.c:469`, which is why q68 shows the
  pixel-format error four times in one run — but it is the **only** caller that
  does; d3d8, dxgi and dxcore have no retry and lost even the 2D, display-mode
  and adapter-identity surface no3d would have given them. `wined3d_init`
  (`directx.c:3575-3600`) now retries once with the flag, and sets it on the
  `wined3d` object rather than only the adapter: `wined3d_check_device_format`
  gates texture capabilities on `wined3d->flags & WINED3D_NO3D`, and an adapter
  that is no3d while its `wined3d` is not would advertise 3D nothing can back.
  The recovery announces itself as `err:winediag: Disabling 3D support: no
  OpenGL or Vulkan adapter is available.` The registry knob (`renderer=no3d`,
  `wined3d_main.c`) still short-circuits ahead of it.
  **`adapter_no3d_get_wined3d_caps` was empty**, so under no3d the only
  `DDSCAPS` ddraw reported were the generic ones (`FLIP`, `OFFSCREENPLAIN`,
  `PALETTE`, `PRIMARYSURFACE`, `TEXTURE`, `ZBUFFER`, `MIPMAP`), and every
  surface kind a flipping primary chain is made of read as unsupported — on a
  path where ddraw does the flipping itself and needs no 3D backend for any of
  it. It now adds `FRONTBUFFER | BACKBUFFER | COMPLEX | OWNDC | VIDEOMEMORY |
  LOCALVIDMEM` (`directx.c:2904-2935`). `WINEDDCAPS_3D`, `3DDEVICE` and
  `NONLOCALVIDMEM` stay off deliberately — their absence is what makes ddraw
  set its own `DDRAW_NO3D`, and there is no AGP aperture to describe.
  **Instrument 1, `[d3d9-caps]`** (`d3d9_interface.cpp:230-420` plus the call
  sites). Every `CheckDeviceType`, `CheckDeviceFormat`, `CheckDepthStencilMatch`,
  `CheckDeviceMultiSampleType`, `CheckDeviceFormatConversion`, `GetDeviceCaps`,
  `GetAdapterIdentifier` and `GetAdapterDisplayMode` prints its arguments and
  its HRESULT — **once per distinct query, capped at 256 lines**. Frame 1 of a
  real title issues thousands of these (the census measured 2016
  `EnumAdapterModes` and 144 `CheckDeviceType` in one frame), so a repeat costs
  one atomic load against a 1024-slot open-addressed set of the query's 64-bit
  FNV-1a hash. The hash is used rather than packed bit ranges because the
  fields do not fit side by side in 64 bits (`Usage` is 32 and a FOURCC is
  another 32) and overlapping shifted XORs alias one query onto another, which
  shows up as a line the trace never prints. `GetDeviceCaps` prints the fields
  a legacy title gates on across three lines (shader versions,
  `MaxSimultaneousTextures`, `MaxTexture*`, `MaxPrimitiveCount`,
  `MaxVertexShaderConst`, `NumSimultaneousRTs`, `Caps`/`Caps2`/`Caps3`,
  `DevCaps` with `HWTNL`/`PURE` called out, `TextureCaps` with `POW2` and
  `NONPOW2COND` called out, `RasterCaps`, `PrimitiveMiscCaps`, `StencilCaps`,
  `DeclTypes`). The five format probes are traced by WRAPPING: the bodies moved
  into non-virtual `...Probe` helpers (`d3d9_interface.hpp`), deliberately NOT
  `STDMETHODCALLTYPE` so `gen_d3d9_census.py` does not renumber all 317 methods
  (`--check` still reports `317 methods across 13 files; 0 stale`). Wrapping
  rather than editing returns because `CheckDeviceFormat` alone returns from two
  dozen places and a trace threaded through all of them drifts the first time
  one moves. Probes that one method makes of another are traced too, which is
  informative — it is what explains a `CheckDeviceType` refusal — rather than
  noise.
  **Instrument 2, `[d3d9-last]`** (`d3d9_census.{hpp,cpp}`). A 64-entry
  lock-free ring of the last D3D9 calls, pushed from the same generated
  `D3D9_CENSUS` macro that already sits at the top of all 317 vtable slots, so
  no call site was touched: one relaxed `fetch_add` plus six plain stores, with
  the sequence number written last so a torn slot is visible rather than
  quietly misleading. `LogPresentRequest` also pushes a RET entry carrying the
  HRESULT and the extent (`ringNote`, `d3d9_interface.cpp:475`), which covers
  CreateDevice / CreateDeviceEx / Reset / ResetEx / CreateAdditionalSwapChain;
  `D3D9_CENSUS_RET(code, hr, a0, a1)` exists for adding further return sites.
  **How it reaches the log is the interesting part.** The 32-bit frontend is
  guest code (`d3d9.dll` is the 114 KB shim forwarding to the 2.1 MB
  `d3d9-emulated.dll`), so the ring lives in guest memory and the host crash
  reporter cannot read it. So there are two dumps printing the same block: a
  vectored exception handler installed at DLL init (`d3d9_census.cpp:306` —
  first in the chain, returns `EXCEPTION_CONTINUE_SEARCH` unconditionally, and
  filters to the codes that end a process unhandled so C++ throws, thread-name
  notifications and `OutputDebugString` do not trigger it) covers the emulated
  frontend; and `extern "C" d3d9_dump_last_calls()` (`d3d9_census.cpp:519`),
  declared weak and called from the single site
  `build/ntdll-unix/signal_arm64_ios.c:6599,6608` on `STATUS_ACCESS_VIOLATION`,
  covers the native one. `DllMain(DLL_PROCESS_DETACH)` with a non-NULL
  `reserved` dumps on an orderly `ExitProcess`, i.e. the `MADEIRA-EXIT` case
  (`d3d9.cpp:29`). Three dumps per process, so a fault inside a fault cannot
  flood the log.
  **Caps audit, 2000-2010 expectations.** Everything below was already right
  and is now asserted by a test: DXT1-5 as 2D and cube textures;
  `R5G6B5`/`X1R5G5B5`/`A1R5G5B5` as render targets and textures and
  `A4R4G4B4` as a texture; `L8`/`A8`/`A8L8`/`L16`/`V8U8`/`Q8W8V8U8`;
  `D16`/`D24S8`/`D24X8` as depth-stencil, and all nine
  `{X8R8G8B8, A8R8G8B8, R5G6B5} x {D16, D24S8, D24X8}` matches;
  `CheckDeviceType` windowed and fullscreen for every display/backbuffer pair;
  ps/vs 3.0; `MaxPrimitiveCount = 0x555555` (>= `0xFFFFF`);
  `MaxSimultaneousTextures = 8`; `MaxVertexShaderConst = 256`;
  `NumSimultaneousRTs = 4`; `DevCaps` carrying `HWTRANSFORMANDLIGHT|PUREDEVICE`;
  the full `StencilCaps` and `DeclTypes`; and no `POW2` bit at all, which is
  the most permissive non-power-of-two answer there is. `AUTOGENMIPMAP` on a
  non-renderable format returns `D3DOK_NOAUTOGEN`, a SUCCESS code — the
  distinction matters, because a FAILED answer there sends a title down a
  no-mipmaps path.
  **One real defect found in the audit and fixed:** `CheckDeviceFormat` and
  `CheckDepthStencilMatch` accepted only `X8R8G8B8`/`R5G6B5`/`X1R5G5B5` as an
  adapter format, while `isEnumerableDisplayFormat` enumerates modes for
  `A2R10G10B10` as well. `CheckDeviceType` for a fullscreen device ends by
  asking `CheckDeviceFormat` whether the backbuffer is a render target AT THE
  DISPLAY FORMAT, so **every `A2R10G10B10` fullscreen probe was refused on an
  adapter that had just reported fourteen `A2R10G10B10` modes** — a mode list
  no device could be created from, with no second answer telling the caller to
  fall back. `A2R10G10B10` is a real render target here (`isColorRTFormat`), so
  it is accepted now (`d3d9_interface.cpp:863`, `:1173`).
  **Known gaps, deliberately not closed here** (each has a documented fallback
  a period title takes, and closing them means adding format support rather
  than changing a probe): `X8L8V8U8`, `L6V5U5` and `A2W10V10U10` are unmapped,
  so the 2002-2005 bump-map set stops at `V8U8`/`Q8W8V8U8`; `P8`/`A8P8`, packed
  YUV, `R8G8B8`, `R3G3B2`/`A8R3G3B2`, `A4L4` and `CxV8U8` are SCRATCH-only by
  design and the probe correctly refuses them; `D32` and `D16_LOCKABLE` are
  refused, matching wined3d and DXVK; `A4R4G4B4` is a texture but not a render
  target, matching DXVK. The test prints all of them as `[info]` so a
  regression in any one is visible without being a failure.
  **`d3d9.customVendorId` / `d3d9.customDeviceId` / `d3d9.customDeviceDesc`**
  (`d3d9_interface.cpp:540-585`, off by default). The defaults are honest —
  Apple's real vendor id and the Metal device's own name — because a
  translation layer should say what it is. The knob exists because a period
  title commonly carries a hard-coded vendor table with `0x10DE`/`0x1002`/
  `0x8086` and nothing else in it, and treats an unrecognised vendor the way it
  treats a broken driver. That is not something the adapter can fix from the
  inside, only something the user can A/B, so it is spelled the way DXVK spells
  it (four hex digits) and reaches the device through
  `Documents/madeira-dxmt.txt`, e.g.
  `d3d9.customVendorId = 10de; d3d9.customDeviceId = 05e2`. It moves the D3D9
  answer only — the ddraw and `EnumDisplayDevices` identities stay at
  `0x106B / 0x0001` — so an A/B that changes behaviour also tells you the title
  is reading D3D9's number rather than the display device's.
  **Tests.** `build/x86-tests/d3d9caps-x86.c` (`./build-d3d9caps-test.sh`;
  imports kernel32 + d3d9 only, and creates no window, because a title probes
  all of this before it has a renderer) walks the matrix above, prints every
  answer as `MADEIRA-D3D9CAPS: [ok  ]` / `[FAIL]` / `[info]`, and additionally
  asserts that `CheckDeviceType` and `CheckDeviceFormat` cannot disagree about
  a backbuffer — the defect class the `A2R10G10B10` bug belongs to. **Exit
  56** = every required expectation met; 60-73 name which one was not.
  `build/x86-tests/ddraw-x86.c` (`./build-ddraw-test.sh`; kernel32 + user32 +
  ddraw) creates `IDirectDraw7` with no window, checks `GetDeviceIdentifier` is
  non-degenerate, `EnumDisplayModes` >= 6 with 640x480 present, and `GetCaps`;
  then goes `EXCLUSIVE|FULLSCREEN` -> `SetDisplayMode(640,480,16)` -> flipping
  primary + 1 back buffer -> `Blt` colour fill -> `Flip` -> `Lock`/`Unlock` on
  the primary -> `RestoreDisplayMode`. **Exit 57**; 80-94 name the step. Run
  both from the Custom popup as `C:\windows\syswow64\d3d9caps-x86.exe` and
  `C:\windows\syswow64\ddraw-x86.exe`. App-side launch buttons are still owed
  by the app track (`ContentView.swift`).
  Built: `d3d9-emulated.dll` (i386) and `libdxmt_combined.a` via
  `.xtool/build-dxmt.sh`; `ddraw.dll` + `wined3d.dll` (i386; 720 modules, 0
  failures, 0 missing cross-imports) via `.xtool/build-wine-i386.sh`;
  `ntdll-unix` + `win32u-unix` via `.xtool/build-wine-native.sh`. All clean.
  **What to look for in the next log.** (1) `MADEIRA-D3D9CAPS: PASS` /
  `status=56` and `MADEIRA-DDRAW: PASS` / `status=57`, and the same
  `VendorId`/`DeviceId` pair printed by both. (2) In the ddraw run, the
  pixel-format error must now be followed by `err:winediag: Disabling 3D
  support` — the error appearing WITHOUT that line is the fallback not firing.
  (3) For the 2008 title, `[vmode] synthesized EnumDisplayDevices adapter
  idx=0 flags=...` should be followed by the title continuing rather than by
  `bus_handler BUS #1 ... addr=<guestbase>+4`. If it still faults there, the
  `[d3d9-last]` block from the vectored handler names what D3D9 was last asked
  for; if that block's newest entries are far in the past, the null is not
  D3D9's and the next suspect is the `wbemprox` `Win32_VideoController` answer
  two calls earlier. (4) For the 2001 title, `[d3d9-caps]` will show whether it
  probed anything at all before going to its intro movie; the question after
  that is `[ios_audio] create_stream #1`, which has never appeared, and the
  ~97 % spin in the `mmdevapi`-started thread.
  A/B: `MADEIRA_D3D9_CENSUS=0` turns off the census, the ring and both
  `[d3d9-last]` dumps together (they share `g_on`); `[d3d9-caps]` is
  unconditional and self-capping.
  **Two build stages were silently compiling stale sources, and both reported
  success.** Found while verifying the above, and worth more than the fixes it
  was blocking. `.xtool/build-fex.sh` and `.xtool/build-dxmt.sh` rsync their
  tracked trees into the `git archive HEAD` workspace before building, and say
  in a comment why. The other two stages did not:
  - `.xtool/build-wine-i386.sh` built `$WORK/wine/`, the exported HEAD, so the
    edits to `wine/dlls/wined3d/` above were invisible. The run said
    `built: 720  failed: 0`, stripped and installed `wined3d.dll` and
    `ddraw.dll` into `app/Madeira/i386-windows/` with fresh timestamps, and
    reported `0 missing cross-imports`. Nothing distinguished it from a real
    rebuild. It was caught only by grepping the installed DLL for a string the
    change adds — `grep -ac "DXMT (Metal) 2D" wined3d.dll` returned 0 while
    `grep -ac "WineD3D DirectDraw Emulation"` still returned 1.
  - `.xtool/build-wine-native.sh` is worse, because
    `prepare-native-scripts.py` copies each part's `build.sh` into the
    workspace but NOT its sources, so `build/ntdll-unix/*.c` and
    `build/win32u-unix/*.c` were compiled from the export. Both edits above
    live in those directories. `.xtool/run-ml760-wine-native.sh` exists as a
    one-file `cp` workaround for exactly this, which is the shape of a trap
    that has been hit before.
  Both now rsync the tracked tree first, with the same comment the other two
  carry. `build-wine-i386.sh` syncs `wine/` without `--delete` (wine's
  configure leaves generated files inside the source tree, and deleting
  everything untracked would force a full reconfigure every run) and excludes
  `build-*/` so the configured `build-i386` / `build-64` trees are not walked.
  `build-wine-native.sh` syncs `build/{ntdll-unix,win32u-unix,wineserver}`
  excluding `build.sh` (which `prepare-native-scripts.py` rewrites into the
  workspace) and `obj/`. After the fix the strings are present
  (`DXMT (Metal) 2D` and `Disabling 3D support: no OpenGL` both in the
  installed `wined3d.dll`, the old description gone), and the workspace copies
  of `sysparams_ios.c` and `signal_arm64_ios.c` carry the changes with
  `libntdll_unix.a` / `libwin32u_unix.a` rebuilt from them.
  The general lesson: a stage that builds out of the `git archive` workspace
  cannot be trusted to have built what is in the working tree unless it syncs,
  and "N built, 0 failed" is not evidence that it did. Verifying a change by
  grepping the produced binary for a string only that change introduces is
  cheap and is the only check here that would have caught it.

- 2026-09-16 — The q68 spin, named: **`mmdevapi`'s MIDI notify thread, burning
  a core because this port's audio driver answered `midi_notify_wait` with
  "success" and wrote nothing.** Nothing to do with format negotiation, which
  is where the entry-point log pointed and where the search started.
  **The identification.** The profiler had already printed the answer and it
  was read past: `[prof] threads: tid=002c"mmdevapi_midi_notify"=96.7%(jit
  82%)`. That name is set by `SetThreadDescription` in
  `wine/dlls/mmdevapi/main.c` `notify_thread`, and it is the second of the two
  thread start addresses in the log: `717b15ca00` against base `717B150000` is
  RVA `0xca00`, and `llvm-objdump -d` on the shipped `i386-windows/mmdevapi.dll`
  labels `0x1000ca00 <_notify_thread@4>` (the other, `717b15b4a0` = RVA
  `0xb4a0`, is `devenum.c`'s `_notif_thread_proc@4` — the device-change
  listener, and harmless). The hot range is the 31 bytes at `0x1000ca4c`:
  `push esi / push 0x23 / push handle / call __wine_unix_call` then
  `cmpl $0, quit` / `cmpl $0, notify.send_notify`, and `jmp` back. `0x23` is
  35, which is `midi_notify_wait` in `enum unix_funcs`. That is the whole loop.
  **The cause.** `notify_thread` is `while (1) { MIDI_CALL( midi_notify_wait );
  if (quit) break; ... }` with `quit` and `notify` as *uninitialised* locals —
  the call is defined to BLOCK until a notification arrives or the driver is
  released (`winecoreaudio.drv` and `winealsa.drv` both sit on a condition
  variable in it) and to write `*quit` on every return.
  `build/ntdll-unix/audio_null_ios.c` pointed all seven MIDI/aux slots of both
  its tables at one `ios_midi_stub` that returned `STATUS_SUCCESS` and touched
  nothing. That is not "no MIDI"; it is "success, and the answer is whatever
  was already on the caller's stack". Here the stack happened to hold zeros, so
  `quit` read false forever and the loop became a busy wait. Had it held
  garbage instead, `notify.send_notify` would have been true and
  `DriverCallback` would have jumped through an uninitialised function pointer
  — the same bug with a crash instead of a spin. The thread is created from
  `DriverProc`'s `DRV_LOAD`, which `winmm`'s `MMDRV_Install("mmdevapi", ...)`
  sends when *anything* first touches `mmdevapi.dll`, so no program has to use
  MIDI to pay for this.
  **The fix, in two independent places, because either alone would have been
  enough and the pair is what makes it not happen again.**
  1. `wine/dlls/mmdevapi/main.c:354` — `notify_thread` now resets both outputs
     before every call and defaults them to *stop*: `quit = TRUE`,
     `notify.send_notify = FALSE`, and the loop also breaks if the unix call
     itself fails. A backend that returns without filling them in now ends the
     thread instead of spinning. `midMessage` / `modMessage` clear
     `send_notify` before their calls for the same reason. Costs nothing when
     the driver behaves: every real one assigns `*quit` on every return.
  2. `build/ntdll-unix/audio_null_ios.c:1269-1375` — the one stub is replaced
     by an entry point per slot, and both the 64-bit and the WoW64 table get
     them (`*err` and `*quit` are 4-byte guest pointers for a 32-bit
     `mmdevapi`, so the 64-bit entries would have written them at the wrong
     offsets — `*quit` not landing where `notify_thread` reads it is precisely
     this bug). `midi_init` reports `DRV_FAILURE`, which is how
     `winecoreaudio.drv` says "this backend has no MIDI" and which makes
     `DRV_LOAD` fail so the thread is never created at all; `midi_notify_wait`
     answers `quit = TRUE`; `midi_in/out_message` and `aux_message` answer
     `MMSYSERR_NOTSUPPORTED` with `send_notify` cleared. Losing MIDI and `aux`
     through `winmm` is the truth being told for the first time — they never
     worked. `waveOut` is untouched: `mmdevapi.spec` exports no `wodMessage`,
     so `winmm`'s waveform path goes through the COM side, not `DriverProc`.
  **Three more things the same file was getting wrong, found while reading it
  against `winecoreaudio.drv`:**
  - `is_format_supported` returned `S_OK` for *everything*, including formats
    `create_stream` would then quietly drop to silent null-mode. It now
    validates what the RemoteIO unit can actually be spelled for (packed PCM
    or float32, 1-8 channels, 4-192 kHz, 8/16/24/32-bit, `nBlockAlign`
    consistent with the container) and answers `S_FALSE` otherwise, which
    `client.c` turns into a closest-match `GetMixFormat` for a shared-mode
    caller and into `AUDCLNT_E_UNSUPPORTED_FORMAT` for an exclusive one.
    `create_stream` refuses exactly the same set with
    `AUDCLNT_E_UNSUPPORTED_FORMAT`, so the two answers agree — a caller told a
    format is fine and then handed a stream that plays nothing has no way to
    recover. The null-mode fallback stays for what it is actually for: the unit
    failing to build (no audio session yet), where the format is fine and only
    the environment is not.
  - 8-bit PCM was marked `kAudioFormatFlagIsSignedInteger`. WAVE 8-bit is
    *unsigned* and everything wider is signed; the flag inverted the sign bit
    of every sample on the way to the hardware, which plays as full-scale buzz.
    Only formats above 8 bits get the flag now.
  - Every negotiation entry point now prints its ANSWER once per distinct
    outcome — `[audio] is_format_supported fmt=tag1/2ch/44100Hz/16bit/align4
    share=shared -> 0x00000000` — keyed on the format plus the HRESULT, with a
    fixed 64-slot table so a per-period call cannot flood the log. The existing
    `[ios_audio] <fn> #N` counters say how often an entry point was reached;
    they never said what it replied, and a negotiation that ends in silence is
    a sequence of replies.
  **Test: `build/x86-tests/audio-x86.c` -> `audio-x86.exe`**, run from the
  Custom path popup as `C:\windows\syswow64\audio-x86.exe`. One program, three
  paths, because they share one unix driver and nothing else: (a) WASAPI
  shared mode through `CoCreateInstance(MMDeviceEnumerator)` —
  `GetMixFormat`, `IsFormatSupported` for 16-bit 44.1 kHz stereo and 16-bit
  22 kHz mono, `GetDevicePeriod`, `Initialize`, `GetBufferSize`, 200 ms of
  silence through `IAudioRenderClient`, `Start`, and `GetCurrentPadding` must
  DRAIN (the one observable that separates a device consuming audio from one
  merely accepting it), `Stop`; (b) `DirectSoundCreate8`, primary buffer,
  200 ms secondary, `Play`, and the play cursor must move; (c) `waveOutOpen`
  at 22 kHz mono 8-bit — the case the sign-flag bug above corrupts — one
  prepared buffer, `waveOutWrite`, and the header must come back `WHDR_DONE`.
  Exit 59 = all three inside a 5 s budget; 60/61/62 name the failing path;
  63 = the budget expired. It is also the regression test for the spin without
  calling MIDI at all: the notify thread is created when `mmdevapi.dll` first
  initialises, which stage (a) does, so finishing inside the budget *is* the
  proof that the thread is not spinning. Built with
  `build/x86-tests/build-audio-test.sh`, which asserts the import set is
  `ole32/dsound/winmm/user32/kernel32` — `mmdevapi` is reached through COM, the
  way a real program reaches it, so the prefix's COM registration is part of
  what the test covers.
  Rebuilt: the i386 farm (`build-wine-i386.sh`, 720 built / 0 failed / 0
  missing cross-imports) and `libntdll_unix.a` (`build/ntdll-unix/build.sh`,
  31 succeeded / 0 failed). Verified in the produced binary rather than
  assumed, per the stale-workspace lesson above: the rebuilt
  `i386-windows/mmdevapi.dll` disassembles at `0x1000ca23` to
  `movl $0x1, -0xc(%ebp)` / `movl $0x0, -0x2c(%ebp)` — `quit = TRUE` and
  `send_notify = FALSE` — before the loop, and repeats both at `0x1000ca5c`
  inside it.

- 2026-09-16 — ml761: **the DirectInput joystick's TRIGGER axes rested at the
  end of the range instead of its centre, and a camera turned forever.**

  **The report.** With ml760's `joystick_ios.c` a 2008 DINPUT8 title ran for
  the first time, and its camera span constantly to the left. Neither the
  controller's right stick nor the touch mouse could turn it back. The XInput
  slot was all zeros throughout —
  `[xinput] pad0 packets=… buttons=0x0000 lx=0 ly=0 … slot(got=yes …)`,
  `[hwinput] … rx=0 ry=0` — so the sticks really were centred and the transport
  really was fine. That combination is the whole diagnosis: **all zeros is the
  state that triggers the bug**, which is why the log looked innocent.

  **The bug.** ml760 converted every axis to an UNSIGNED 0..65535 logical value
  and declared `logical_min = 0, logical_max = 65535` for all of them. For a
  stick that is harmless — XInput 0 becomes 32768, which is the declared centre
  — and the sticks were in fact correct. For a trigger it is fatal: XInput 0
  means RELEASED, it became logical 0, and `scale_axis_value` saturates that to
  `phy_min`. A released trigger therefore read as a **fully deflected axis** —
  `0` with dinput's default 0..65535 range, `-1000` with an app range of
  -1000..1000. Both `Z` (left trigger) and `Rz` (right trigger) sat there from
  the moment the device was acquired. A title of that era that maps "the third
  axis" to camera yaw sees a stick held hard over and never released; the right
  stick could not out-vote it because the pegged axis was saturated, and the
  mouse could not either because the game sums them.
  Confirmed by running ml760's exact arithmetic on the host: trigger released
  -> `0` (default range) and `-1000` (symmetric range), while a centred stick
  -> `32768` and `0`. Sticks fine, triggers pegged, exactly as reported.

  **The fix**, `wine/dlls/dinput/joystick_ios.c`:
  (1) **Nothing is pre-scaled any more.** Each object now declares the logical
  range its raw values actually live in and hands the raw value to the scaling
  (`ios_logical_stick`/`ios_logical_triggers`/`ios_logical_pov` at
  `joystick_ios.c:327`, `ios_init_object_properties` at `:494`). Axes are
  `logical_min = -32768, logical_max = 32767`, so logical 0 IS the centre; the
  hat stays 0..7 with an idle value of 8, deliberately outside the range, which
  is what makes `ios_scale_value` return -1 (0xffffffff) rather than 0 (= up).
  `scale_axis_value` derives the centre from the declared range, so
  `DIPROP_RANGE` keeps working: whatever the app sets, rest lands on the middle
  of it.
  (2) **Z is the COMBINED trigger axis, `left - right`, and there is no Rz**
  (`joystick_ios.c:354`). This is the Xbox 360 controller's DirectInput
  contract — Windows' XUSB DirectInput device reports exactly one combined,
  centred Z — and it is the ONLY arrangement in which a trigger axis can rest
  at the centre of the app's range instead of at one end of it. Two separate
  trigger axes are the modern XInput/raw-HID view, and a program that wants
  that has XInput, which this port has had since ml668. Keeping `Rz` as a
  separate right trigger would have left a second pegged axis to reproduce the
  same spin in the next title that happened to map it.
  The object set is now X, Y (left stick), Rx, Ry (right stick), Z (combined
  triggers), POV 0 (d-pad), buttons 0..9.
  (3) `ios_joystick_enum_device` re-states what it already did and now says so:
  the joystick is offered ONLY when the host slot reports a pad, re-checked on
  every `EnumDevices` and every `CreateDevice`, with no caching — so a session
  with no controller enumerates no joystick, and one paired mid-session is
  picked up by the next enumeration (`joystick_ios.c:401`).

  **Proof, before the device.** The scaling was extracted verbatim and run on
  the host against four app-configured ranges. At rest — sticks at 0, both
  triggers released, no d-pad — every axis reads the centre of the configured
  range and the POV reads -1:
  | range | centre | X | Y | Z | Rx | Ry | POV |
  |---|---|---|---|---|---|---|---|
  | 0..65535 (dinput default) | 32767 | 32768 | 32768 | 32768 | 32768 | 32768 | -1 |
  | -1000..1000 | 0 | 0 | 0 | 0 | 0 | 0 | -1 |
  | 0..1000 | 500 | 500 | 500 | 500 | 500 | 500 | -1 |
  | -32768..32767 | -1 | 0 | 0 | 0 | 0 | 0 | -1 |
  The one-LSB offsets (32768 for a 32767 centre) are Wine's own: `log_ctr =
  round((-32768 + 32767)/2.0) = -1`, and `joystick_hid.c` produces the same
  values for a winebus-backed pad. Extremes check out too: stick -32768 ->
  range minimum, 32767 -> maximum, left trigger full -> near maximum, right
  trigger full -> near minimum, both full -> centre. POV logical 0..7 ->
  0, 4500 … 31500 and idle -> -1.

  **Against a stale workspace.** `joystick_ios.c:129` now carries a build tag
  naming the axis contract —
  `MADEIRA-DINPUT-IOS ml761-combined-z axes=X,Y,Rx,Ry,Z(LT-RT)
  logical=-32768..32767 pov=0..7/idle8` — emitted from a TRACE so it survives
  into `.rdata`. All six shipped binaries were grepped for it after installing:
  `i386/dinput.dll`, `i386/dinput8.dll`, `aarch64/dinput.dll`,
  `aarch64/dinput8.dll`, `arm64ec/dinput.dll`, `arm64ec/dinput8.dll` — present
  in every one. The point is that ml760 and ml761 differ in no export and in no
  file size; without the tag "is the farm actually carrying the fix" is not a
  question a build can answer.

  **`dinput-x86.exe` gains a REST CHECK** (`build/x86-tests/dinput-x86.c:229`):
  after acquiring it asserts every axis is within 512 of 32767 and the POV is
  -1, and prints `REST-CHECK pass` or `REST-CHECK FAIL` naming the axis. It is
  a printed verdict rather than an exit code on purpose — a player holding a
  stick when the test starts would otherwise fail it — so the device log is
  grepped for `REST-CHECK`. Exit codes are unchanged (58 pass / 68 no device /
  69 no change / 64,65,66 setup failures), and `rz` is gone from its output.

  **`.xtool/build-wine-i386.sh` now takes module names**, matching
  `build-wine-64.sh`: `build-wine-i386.sh dinput dinput8` builds and installs
  just those two instead of re-running ~700 strip+install copies onto /mnt/c
  (`build-wine-i386.sh:71` for the argument parse, `:467` for the subset
  filter). Names resolve against the same Makefile rule table the breadth phase
  uses, so a typo is reported as "no i386 rule" rather than silently building
  nothing, and the verify and import-closure passes still scan the WHOLE farm —
  a subset build that breaks the closure has to say so. Rebuilt this way for
  all three farms: `built: 2 failed: 0` each, **0 missing cross-imports** on
  i386, aarch64 and arm64ec.

## 9. Running without `extended-virtual-addressing` ("lazy VA") — PLAN

Goal (upstream request): every feature of this fork must work when the app
has only the default iOS address space, so the 32-bit work can be merged
into upstream Madeira, which ships without the entitlement.

### 9.1 What the entitlement buys us today (facts from the tree)

- `com.apple.developer.kernel.extended-virtual-addressing` is NOT in
  `app/Madeira/Madeira.entitlements`; the sideloader injects it (the app's
  own tip says "use GetMoreRam"). With it the task's VA top is 512 GB and
  the map measured on the dev phone (ml92) was: `__PAGEZERO` 0-4 GB, 4-64 GB
  fully reserved by malloc's xzone, one usable ~63 GB window
  `0x7038000000..0x7fffdf0000` (448-512 GB). Every fixed address in the
  fork lives there: guest slot 0 `0x7100000000`, slot 1 / cage holdback
  `0x7200000000..0x7400000000`, CEF PartitionAlloc pools `[0x74,0x7c) GB`,
  FEX host heap + arena `[0x7c,0x80) GB`, Wine "furniture" (PE image copies,
  TEBs, heaps) top-down under `ios_furniture_ceiling`, JIT pool
  (kernel-placed, RW alias parked below the 64 GB carve-out floor).
- Hard-coded literals in that band: `virtual_ios.c` 104, `signal_arm64_ios.c`
  18, `StikJITHelper.swift` 14, `FEX/Source/Windows/ARM64EC/Module.cpp` 3,
  `wineserver/mapping_ios.c` 2, `thread_ios.c` 1, `win32u syscall_ios.c` 1.
- Without the entitlement the task's VA top is 64 GB (`MACH_VM_MAX_ADDRESS`
  for a stock iOS app). The 448-512 GB window does not exist, so today's
  layout cannot start Wine at all. Upstream (64-bit only, guest==host) fits
  in the low 64 GB; what this fork adds is two 4 GB-ALIGNED 4 GB guest
  windows, and that is the one thing the design cannot shrink: the guest
  address must equal the low 32 bits of the host address (`B` 4 GB-aligned,
  FEX `REG_GUEST_BASE`), and a window is a contiguous PROT_NONE reservation.

### 9.2 Unknown that decides everything — measure first (step 0)

We do not know the free map of a stock 64 GB task on this device: how much
of 4-64 GB malloc's xzone really reserves without the entitlement (the
"fully reserved" observation was made WITH it, where xzone sizes itself to
the big space), where dyld's shared cache and Metal/GPU mappings sit, and
whether a 4 GB-aligned 4 GB hole exists at all. Step 0 is a probe build
that runs with the entitlement absent: at launch walk
`mach_vm_region_recurse` and log every free hole >= 256 MB (`[va-map]`),
then try `mmap(PROT_NONE)` of 4 GB at every 4 GB-aligned base in 4-64 GB
and log which succeed (`[va-probe] slot k: ok|EBUSY`), plus the largest
free extent for the JIT pool (2 x pool size, dual-mapped) and the FEX heap.
Nothing else in this plan should be written before that log exists; it
tells us whether we have 1, 2 or 0 candidate guest slots and how much is
left for furniture. Expected budget if the map is like a normal iOS app:
~48-56 GB free, of which the fork needs: 2 slots 8 GB (lazy, see 9.3), JIT
pool 1-1.8 GB, FEX heap 2-4 GB (lazy), Wine furniture 4-8 GB, CEF cage 8 GB
ONLY when CEF runs (lazy), leaving >= 20 GB for games' own allocations.

### 9.3 Design: a discovered layout instead of constants, and lazy reservations

1. One layout table, computed at session start (`ios_va_layout` in
   `virtual_ios.c`, exported to Swift via a small C accessor and to FEX via
   the existing `NtQueryInformationProcess` classes): `va_top`,
   `usable_floor`, `furniture_ceiling`, `slot[k].base` (4 GB-aligned holes
   found by the probe, best-fit), `pool_hint`, `fex_heap_hint`, `cage_hint`
   (0 when no 8 GB-aligned hole exists -> CEF disabled with a clear log,
   not a crash). Every one of the ~143 literal sites reads the table;
   `0x7100000000` stops appearing anywhere except in the doc. Entitlement
   present -> the probe finds the old window and the table reproduces
   today's layout exactly, so the entitled build is a regression test for
   the refactor.
2. Lazy guest windows: no placeholder at session start. Slot k is reserved
   (`MAP_FIXED|PROT_NONE` at the probed base, re-probed at that moment)
   when the first 32-bit process needs it and released on exit
   (release-on-next-adopt already exists; make it release-on-exit so the
   VA returns to the pool of holes). `win32u_zero_bits()` and the GDI
   section view already take the base from the process.
3. Lazy FEX host heap: FEX's allocator hint region `[0x7c,0x80) GB` (16 GB)
   becomes a chunked reservation: 512 MB chunks reserved on demand from
   `fex_heap_hint`; the `[bigres]` steering table (`va-arena`) keeps them
   inside the layout. FEX only needs its heap below 2^48, not contiguous.
4. JIT pool: unchanged mechanism (one dual-mapped pool, debugger-blessed),
   but its hint list comes from the table and its size is bounded by the
   largest free extent / 2; keep the app-lifetime reuse.
5. Furniture: Wine's top-down furniture band `[usable_floor,
   furniture_ceiling)` is already a runtime pair (`ios_usable_va_floor_get`);
   it moves to the table. PE pool copies (100 MB) and TEB/heaps are small;
   the "14 GB" figure came from CEF-era reservations, not games.
6. CEF cage / PartitionAlloc pools: opt-in lazy reservations at CEF process
   start (`cage_hint`); the soft-pool broker stays; on a 64 GB map they may
   be unavailable -> CEF (Steam webhelper) is the one feature that can
   legitimately be "not supported without the entitlement". Games do not
   use it.
7. Second 32-bit slot exists only if the probe found two aligned holes;
   otherwise `[wow-window]` reports "1 slot" and a 32-bit process spawning
   a 32-bit process gets `STATUS_NO_MEMORY` with the existing loud line.

### 9.4 Risks

- The probe finds NO 4 GB-aligned hole in a stock task (xzone or the
  shared cache straddling every 4 GB boundary). Then the identity mapping
  is impossible without the entitlement and the fallback is a NON-identity
  window (`guest = host - B` with B not 4 GB-aligned): FEX already computes
  addresses as `B + guest32` (`REG_GUEST_BASE`), so the JIT side is fine;
  what breaks is every place that assumes `low32(host) == guest`
  (win32u `zero_bits` views, the GDI shared section, wow64 pointer
  truncation checks, the profiler's module map, `ios_wow_guest_ptr32`). A
  grep for 32-bit casts of host pointers in the wow64 path is the inventory
  for that fallback; it is a bigger change than 9.3 and only worth doing if
  step 0 says the aligned hole never exists.
- Memory (not VA) is unchanged: jetsam 4 GB; `increased-memory-limit` is a
  separate entitlement that upstream ships.
- Metal/DXMT map large buffers (staging rings, textures) in the same 64 GB;
  the `[mem-census]` numbers (about 1.5-2 GB) fit.

### 9.5 Sequencing and cost

0. Probe build + one device log without the entitlement (Sonnet-size,
   ~150 lines, no behaviour change). Decides 9.3 vs 9.4.
1. Layout table + literal sweep (Opus; mechanical but wide: ~143 sites;
   both builds must pass: entitled = identical layout, stock = probed).
2. Lazy windows + lazy FEX heap + pool hints from the table.
3. Cage/PA pools lazy and optional; CEF marked entitlement-dependent.
4. Device runs: entitled (regression) and stock (the goal): D3D9 cube,
   the 32-bit game, the spawn-chain test (slot count), a 64-bit title.
Everything here is emulator-generic; nothing is per-title.

- 2026-09-18 — Log r77, a 2008-era 32-bit title through XAudio2/XACT: "very
  staticky, and isn't playing the right audio". **The driver was opening one
  RemoteIO unit PER STREAM and handing a 5.1 stream straight to the hardware
  as if six interleaved channels were the route's own.** The negotiation
  logging added two days ago is what made this a five-line diagnosis instead
  of a search, and it also named the second half of the bug on its own.
  **What the log says.** Three `[ios-astream] CREATE` lines, three
  `RemoteIO ready` lines, `(3 now live)`:
  `create_stream fmt=tag65534/2ch/48000Hz/32bit/align8`, then
  `tag65534/6ch/48000Hz/32bit/align24`, then another stereo one — an XAudio2
  mastering voice plus two XACT cue banks, which is an ordinary shape and not
  an exotic one. Two independent faults, either of which alone is "static":
  1. **Six channels into a stereo route.** `RemoteIO ready: 48000 Hz, 6 ch,
     24 B/frame` — the unit accepted a 6-channel client format on a device
     whose output is two channels, and nothing downmixes in between. The
     hardware consumes the 24-byte frames as its own 8-byte ones, so playback
     runs three times too fast with every third sample drawn from a different
     speaker: audio-shaped static, which is exactly the report.
  2. **Three output units, no mixer.** Three RemoteIO instances rendering into
     one route with nothing arbitrating. WASAPI shared mode is *by definition*
     a mixer: one engine, one output format, every client summed into it. This
     port had N engines and no mixer, which the earlier single-stream titles
     never exposed.
  **The rewrite** (`build/ntdll-unix/audio_null_ios.c`), all of it inside the
  driver; no PE-side file changed.
  - **One engine, N clients** (`ios_engine_ensure` / `ios_engine_start` /
    `ios_engine_stop_if_idle` / `ios_engine_render_cb`, lines 897-1005). A
    single RemoteIO owned by the driver rather than by any stream, stereo
    float32, running at the rate the unit reports for the hardware side
    (`kAudioUnitProperty_StreamFormat`, output scope, element 0) rather than an
    assumed 48 kHz — a headset or Bluetooth route at 44.1 kHz used to make
    RemoteIO resample behind our back. The render callback walks the stream
    registry, sums each live stream, then clips to [-1, 1]: summing N clients
    exceeds full scale routinely and wrapping is the other thing that sounds
    like static. The unit stops when the last client stops, not when any one
    of them does.
  - **The downmix** (`ios_build_mix_gains`, line 694). A per-channel gain pair
    built once at create_stream from `dwChannelMask`, or from the channel count
    when there is no mask (plain WAVEFORMATEX — most of DirectSound, all of
    waveOut). Standard coefficients: L/R at unity to their own side, centre and
    back-centre at -3 dB to both, surrounds and sides at -3 dB to their side,
    LFE at -10 dB to both (dropping it loses the bass a game puts ONLY there),
    mono to both at unity rather than -3 dB so a mono title is not half as loud
    as a stereo one. Anything the mask does not name folds in at 0.5 rather
    than being silently dropped. The gains are printed at create_stream, so the
    next log shows the matrix and not just the channel count.
  - **SubFormat, not bit depth** (`ios_fmt_tag` / `ios_fmt_kind`, lines 599-650).
    32-bit is IEEE float OR PCM int32 and the two decode to completely
    different audio; the old `ios_fmt_is_float` looked at the first BYTE of the
    SubFormat GUID, which works only by luck of little-endian layout, and
    everything else keyed off `wBitsPerSample`. Now the sample kind comes from
    the first DWORD of the SubFormat GUID when the format is EXTENSIBLE, and
    u8/s16/s24/s32/f32 each have their own decoder.
    `wValidBitsPerSample` is read and reported: 24-in-32 needs no rescaling
    because WAVEFORMATEXTENSIBLE stores those samples MSB-justified, but a
    producer that right-justifies instead would be ~48 dB quiet and the log
    line is the only thing that would say why.
  - **Conversion moved off the render thread.** The ring is now the ENGINE's
    shape — stereo float32, two floats per client frame — and
    `release_render_buffer` decodes, downmixes and peak-tracks into it on the
    game's own thread (`ios_ingest_frames`, line 1441). The render thread is
    left with a resample and an add. It also fixes the accounting the old code
    got wrong for anything but stereo 16-bit: the ring used to be sized and
    indexed in the CLIENT's frame bytes, so a 24-byte 5.1 frame and an 8-byte
    stereo frame indexed the same buffer differently.
  - **Per-stream resampling** (`ios_resample_step` / `ios_mix_stream`, lines
    779-830). 16.16 linear interpolation from the client's rate to the engine's;
    a stream at the engine's own rate has step 0x10000 and the interpolation
    degenerates to a copy. `play_pos` stays in CLIENT frames, which is what
    `get_frequency` reports and what `get_position` has to be counted in.
    `set_sample_rate` recomputes the step — changing the rate without it played
    the stream at the wrong speed.
  - **The mix format is now the engine's**: 2ch float32 at the hardware rate
    (`get_mix_format`, line 1539), where it used to claim 16-bit PCM. Every
    modern client takes the mix format as the shape to hand over to avoid a
    conversion; being told 16-bit while the engine mixes float meant a
    conversion on every path with nothing checking the two agreed.
  - **Locking.** The registry is now read by the Core Audio render thread as
    well as by Wine threads, so mutating it takes `g_mix_lock` (mix) and
    `g_streams_lock` (handle validation), mix first; the render callback only
    ever TRY-locks, because blocking a render thread is never allowed, and a
    miss costs one buffer of silence and is counted. Handle validation — the
    hot path, once per device period per client — still takes the cheap lock
    only. `stream_unregister` holds the mix lock across the slot clear, which
    is what makes freeing the stream immediately afterwards safe.
  - **The 10 s census** (`ios_report_streams`, line 1007), driven from
    `get_current_padding` because that is the one entry point every active
    client hits at its period:
    `[audio] stream 0: fmt=f32/6ch/48000Hz/32bit(valid 32)/mask0x3f
    frames_written=… underruns=… peak=0.707 playing`, then one
    `[audio] engine: 48000 Hz, running, 3 client(s), mix-lock misses=0`. "Which
    of the three clients is the broken one" is the first question every one of
    these reports raises and the per-call counters could not answer it.
  **Test**: `build/x86-tests/audio-x86.c` gains stage (a2) — a six-channel
  float32 WAVE_FORMAT_EXTENSIBLE stream with the 5.1 mask, 440 Hz on FL/FR
  only and silence on centre/LFE/surrounds, 300 ms, padding must drain. The
  tone comes from a 64-point sine table stepped with a 16.16 phase
  accumulator, because there is no CRT here and so no `sinf`. Exit codes are
  unchanged: 59 still means every path passed, and this stage fails as 60 with
  the rest of the WASAPI path.
  **What the next log should show**: exactly ONE `[audio] engine ready: one
  RemoteIO, <rate> Hz stereo float32` for the whole session however many
  streams are created; a `downmix L=[1.00 0.00 0.71 0.32 0.71 0.00] R=[0.00
  1.00 0.71 0.32 0.00 0.71]` on the 5.1 `CREATE` line; no `RemoteIO ready`
  lines at all (the string is gone); and a `[audio] stream k:` census every
  10 s whose `peak` is non-zero for the streams that are audible and whose
  `underruns` stays near zero. A peak of 0 with a rising `frames_written` means
  the client is writing silence; a large `underruns` with a rising
  `frames_written` means the ring is being drained faster than it is filled,
  which would point at the resample step rather than at the downmix.
  Rebuilt `libntdll_unix.a` (31 succeeded / 0 failed, 1 839 192 bytes) and
  verified in the produced archive rather than assumed: `engine ready: one
  RemoteIO`, `stream %d: fmt=`, `downmix L=` and `mix-lock misses` are all
  present and the old `RemoteIO ready: %u Hz` is gone.

- 2026-09-18 — **Large-address-aware by default for 32-bit processes, Wine's
  own images pushed into the high half, and a census that names who ate the
  guest window.** Logs r76/r77/r78: a 2008-era open-world 32-bit D3D9 title
  boots, reaches gameplay, and a minute later calls `exit(3)` two lines after
  three `[va-scan] FAILED` lines — `window=0x7100110000..0x7180000000`
  (i.e. the scan tops out at guest `0x80000000`), sizes `0xfd0000` then
  `0x7e8000` then `0x3f4000`, `views=347 maxgap=0x3c0000
  stop=gaps-exhausted(bottom-up)`. That is the allocator's 16 → 8 → 4 MB
  fallback cascade failing in a 2 GB user space whose largest hole is 3.75 MB,
  and the CRT aborting on the NULL.
  **Why 2 GB is not 2 GB here.** The same title fits on Windows, so the
  difference is what we spend that Windows does not: Wine's builtin i386 DLL
  images (the farm is 742 modules and a large fraction of them now load) are
  all inside `[B, B+2G)`; the emulated D3D9 frontend's C++ heap and its
  `CpuPlaced` dynamic buffers are guest-visible *by construction*
  (`d3d9_guest_alloc.hpp` — a `Lock()` pointer must be nameable by 32-bit
  code), and the same run's `[mem-census]` measured `CpuPlaced=9444`,
  `DynamicBuffer LIVE=7009`, 184 MB; plus the fragmentation all of that leaves.
  On Windows a non-LAA program never sees any of it, because none of it exists.
  - **The policy (what Proton ships).** `WINE_LARGE_ADDRESS_AWARE=1` is forced
    on for 32-bit games upstream for precisely this failure. Here: a 32-bit main
    image that does **not** carry `IMAGE_FILE_LARGE_ADDRESS_AWARE` is given the
    whole 4 GB window as its user space anyway. `ios_laa_forced()`
    (`virtual_ios.c:6264`) is the knob — default ON, `MADEIRA_LAA=0` in
    `Documents/madeira-env.txt` restores 2 GB for an A/B — and
    `ios_wow_ceiling_for_charact()` (`:6282`) is now the ONE place the ceiling
    is spelled. Both sites that used to write
    `(charact & LARGE_ADDRESS_AWARE) ? limit_4g : limit_2g` call it:
    `ios_wow_image_ceiling()` (`:6378`), which publishes before `init_peb`
    because the main image is mapped first, and
    `virtual_set_large_address_space()` (`:16724`), which publishes at
    `init_peb`. They cannot disagree about the same image any more. Logs once:
    `[laa] 32-bit image is not large-address-aware; user space raised to 4 GB
    (MADEIRA_LAA=0 keeps 2 GB)`.
  - **`MaximumUserModeAddress` follows for free.** `user_space_wow_limit`
    becomes `limit_4g - 1`; `get_wow_user_space_limit()` rounds it to
    `0xFFFF0000` and `SystemBasicInformation.HighestUserAddress` is that minus
    one — `0xFFFEFFFF`, which is what Windows reports for a 4 GB-aware x86
    process. Every `zero_bits` translation, the 32-bit stack ceiling and
    `NtAllocateVirtualMemoryEx`'s `MEM_ADDRESS_REQUIREMENTS` validation read the
    same global, so they all move together.
  - **`GlobalMemoryStatus` needed one more thing.** The guest's own kernel32
    does not ask ntdll: it clamps `dwTotalVirtual`/`dwAvailVirtual` to `MAXLONG`
    by reading `nt->FileHeader.Characteristics` out of the MAPPED image
    (`dlls/kernel32/heap.c:466`, "values are limited to 2Gb unless the app has
    the IMAGE_FILE_LARGE_ADDRESS_AWARE flag"). An app allocator that sizes
    itself from that call would still have believed it had 2 GB. So the bit is
    set in the mapped header too, for the main image of a windowed
    pseudo-process only (`virtual_ios.c:14388`): the headers are a `MAP_PRIVATE`
    file mapping held at `VPROT_READ|VPROT_WRITECOPY`, so this opens the host
    page, stores, and closes it; the copy-on-write is private to the process,
    exactly as a guest write to its own header would be, and Wine's recorded
    vprot is untouched so a later guest write still faults and is handled
    normally. `SECTION_IMAGE_INFORMATION` is deliberately NOT patched —
    `main_image_info.ImageCharacteristics` keeps the file's real bit, which is
    what makes the `forced-laa=1` evidence honest.
  - **What stays below 2 GB.** `KUSER_SHARED_DATA` at guest `0x7ffe0000` and the
    process heap's first segment are untouched. TEB blocks now say out loud that
    they prefer the low half (`virtual_ios.c:15246`): the first block was already
    hardcoded to `limit_2g - 1`, and every later block now tries `limit_2g - 1`
    first and only falls back to the raised ceiling if the low half is full
    (`[laa] no room below guest 2 GB for a TEB block`). Windows keeps the TEB low
    even for an LAA program, and the third device run already showed what the
    alternative costs — TEB32 at guest `0xFFFE0000`, PEB32 at `0xFFFF0000`,
    unusable to code that reads the sign bit as an error flag. PREFER, not
    require: a TEB above 2 GB still beats a thread that cannot be created.
  - **Wine's furniture moves up (item 2, done, not deferred).** A BUILTIN image
    in a windowed process is Wine's furniture, not the app's — nothing the app
    does depends on where a system DLL lands, because the app never names one by
    address. `map_image_view()` now takes `is_builtin` (`:14129`) and, when a
    high half exists, places builtins top-down in `[B+2G, ceiling]` FIRST
    (`:14165`), before the preferred-base attempt, leaving the low half to the
    program. Gated on `IMAGE_FLAGS_ImageDynamicallyRelocated` — the same test
    the existing `top_down` uses, and the flag that means the server already
    assigned this image a randomized base, i.e. it is relocatable; an image
    without it keeps exactly today's placement, so nothing that cannot move is
    moved. NATIVE (app-supplied) DLLs are untouched and keep their preferred
    bases. Advisory, never fatal: a failure falls straight through to the
    ordinary preferred-base / full-window path.
  - **`[wow-va]` census (item 3).** `[va-scan] FAILED` said the window was full
    and never said what was in it, and `ios_furniture_census()` cannot answer —
    it walks the HOST furniture band, while every tenant of a guest window is a
    Wine view. `ios_wow_va_census()` (`:12054`) walks `views_tree` under the
    mutex `map_view` already holds and prints, for the first 4 failures per
    pseudo-process (keyed on the window base, so a later 32-bit process gets its
    own budget — `:12377`): totals, then per class — `image-builtin` (membership
    in `builtin_modules`, `ios_view_is_builtin()` at `:12045`), `image-native`,
    `file-mapping`, `reserved` (MEM_RESERVE, VA spent with no footprint), and
    `anon<64K` / `anon<1M` / `anon<16M` / `anon<64M` / `anon>=64M`, because
    "9444 small objects" and "one 512 MB reservation" are different problems
    with the same total. Anonymous views of exactly 0x4000000 are also counted
    as `d3d9-arena?` — that is `guest_alloc`'s chunk size. Then the 8 largest
    free gaps, which is what decides exhaustion versus fragmentation.
  **Test**: `build/x86-tests/laa-x86.c` + `build-laa-test.sh`, `laa-x86.exe`
  (i386 PE, kernel32 only, 13 824 B). It is the one test here that is
  deliberately **not** linked `--large-address-aware`, and its build script
  asserts the bit is ABSENT — the inverse of every other script's assertion,
  because an image carrying the bit would pass whether or not the policy works.
  It prints `GlobalMemoryStatus dwTotalVirtual`, then reserves 64 MB chunks
  (`MEM_RESERVE|PAGE_NOACCESS`, so this is a question about address space and
  not about the 4096 MB jetsam ceiling) until failure, and prints
  `MADEIRA-LAA: reserved N MB highest=0x…`. Exit 60 requires BOTH ≥ 2600 MB
  reserved AND at least one address ≥ `0x80000000` — a total alone would pass an
  implementation that raised a limit but still handed out only low addresses.
  Exit 61 otherwise, which is also how `MADEIRA_LAA=0` is verified: the same
  binary must then report under 2048 MB and exit 61. Run it from the Custom
  popup as `C:\windows\syswow64\laa-x86.exe`.
  **What the next log should show**: one `[laa] 32-bit image is not
  large-address-aware; user space raised to 4 GB` line, one `[laa] main image
  header at … patched`, a `[wow-limit] published guest 32-bit ceiling
  0xffffffff … forced-laa=1`, and a run of `[laa] builtin image #n placed in the
  high half at guest 0x8…` lines during loading. If a `[va-scan] FAILED` still
  happens, it is now followed by a `[wow-va] census` that names the owner class
  holding the window — and the discriminator is there in one line: if
  `image-builtin` has collapsed to near zero below 2 GB and the failure persists,
  the window is being eaten by the D3D9 arena and the anon buckets say at what
  granularity; if `free` is large and `gap#1` is small, it is fragmentation and
  not exhaustion. The failure that produced r76 should simply not recur: the
  three failing requests were 16 MB, 8 MB and 4 MB against a 3.75 MB largest gap
  in a half-window that now has a second half. Rebuilt `libntdll_unix.a`
  (31 succeeded / 0 failed, 1 839 552 bytes); the only compiler diagnostic is the
  pre-existing `MemoryWineIosJitPoolAddress` `-Wswitch` note.

### 9.6 Step 0 result (2026-09-18, device logs 79-83) — the entitlement is NOT required on the dev phone

The launch probe ran with and without `extended-virtual-addressing` on the
same device (iPhone18,3):

| | with entitlement | without |
|---|---|---|
| `[va-map] top` | `0x8000000000` (512 GB) | `0x8000000000` (512 GB) |
| free 4 GB-aligned slots | 112..127 (448-512 GB), 16 of 127 | identical |
| verdict | identity-layout-possible | identity-layout-possible |
| JIT pool | RX `0x1197..`, RW `0x1397..` | same band |
| guest slot 0 | `B=0x7100000000` adopted | same |
| result | games run | the UE3 title, the open-world title and `laa-x86.exe` (exit 60) all ran |

So on this hardware/OS the task's VA top is 512 GB regardless of the
entitlement, and the fork's fixed 448-512 GB layout works as is. The premise
of 9.1 ("without the entitlement the top is 64 GB") was wrong for this
device; it may still hold on older devices or OS versions, which is exactly
what the probe reports at every launch (`[va-probe] entitlement=… top=…
guest-slots=… verdict=…`). Consequences:

- Nothing in 9.3 is needed to run without the entitlement HERE. The layout
  table + lazy reservations remain the right design only for devices whose
  probe says `top` < 512 GB or `guest-slots=0`; do not start that work until
  a log from such a device exists.
- Cheap hardening worth doing anyway: make session start consult the probe
  result and refuse with a clear message (instead of failing deep inside
  Wine) when `guest-slots=0`.
- Tell upstream: the 32-bit work needs a free 4 GB-aligned slot in the
  448-512 GB band, not the entitlement; the probe is the portable check.

- 2026-09-18 — Log s79, the same title after the mixer landed: menu clean,
  "horrible audio stutter and static during gameplay and cutscenes". **The
  census written for the previous fix diagnosed this one by itself**, which is
  the whole argument for spending log lines on answers rather than on call
  counts: `[audio] stream 2: … frames_written=7338240 underruns=0 peak=7.991
  playing`. Peak 7.99 is +18 dB over full scale, and this driver was hard-
  clipping every one of those samples to 1.0.
  **Why that is legal and why clipping is not.** A float WASAPI client is not
  required to stay inside [-1, 1]; XAudio2 says so explicitly — voices sum
  without clamping and the endpoint copes. Windows' shared-mode engine copes
  with a limiter (its CAudioLimiter APO) that rides the gain down. Clipping a
  signal that is eight times too large does not make it quieter, it replaces
  it with a square wave, which is why the menu (one quiet voice, peak 0.313)
  was clean and gameplay (many voices summed) was static. The peak climbed
  0.815 → 4.006 → 5.007 → 6.992 → 7.991 across the session's 10 s windows, so
  the census had also been watching it arrive.
  **The three changes**, all in `build/ntdll-unix/audio_null_ios.c`:
  1. **A bus limiter on the mixed signal** (`ios_limit_block`, line 874). Per
     block: scan the block's peak BEFORE applying anything, move a peak
     envelope (instant attack, one-pole ~250 ms release whose coefficient is
     derived from the block length so the time constant does not depend on
     Core Audio's buffer size), take `gain = min(1, 0.98/envelope)`, and ramp
     from the previous block's gain to this one's. Ducking ramps over 1 ms so
     a transient is caught inside the block that contains it; releasing ramps
     over the whole block, because that is where zipper noise lives and the
     envelope's release is already slow. The hard clamp stays, as a safety net
     that now trims a fraction of a dB instead of 18. Cost is one max-scan and
     one multiply per sample on a buffer already being walked, and the whole
     path is skipped while gain is 1.0.
  2. **A stereo endpoint now says it is one** (`ios_is_format_supported`, line
     1722). s79 showed the title open a 5.1 stream beside its stereo one, feed
     it 48000 frames a second of pure silence for the entire session
     (`stream 1: … frames_written=5417760 … peak=0.000`), and put everything it
     actually played through the stereo one. Answering "yes, 5.1 is fine" is
     what a multichannel card says, and a client that hears it builds a
     multichannel graph. Shared mode with more than two channels now returns
     `S_FALSE`, which `mmdevapi`'s `client.c` turns into the stereo mix format
     as the closest match — so the client builds the graph that matches the
     hardware. `create_stream` still ACCEPTS more channels and downmixes them,
     for callers that ignore the advice or never ask; the decision is logged
     once.
  3. **The period event is driven by the hardware clock** (`ios_timer_loop`,
     line 1523). It was `usleep(10000); NtSetEvent();` — a clock SOURCE. On a
     loaded device, with the game's mixer thread under FEX translation, 10 ms
     of sleep is 10 ms plus whatever the scheduler adds, so wakeups drift
     against the device and then bunch when the backlog clears: the client
     mixes nothing for a while and then several periods at once. That is
     audible as stutter while `underruns` stays at 0..2 for a whole session,
     which is exactly what s79 reported — the ring never ran dry, and a game
     hears the RATE its buffers are consumed at, not whether the mixer
     starved. The thread is now a clock FOLLOWER: it signals when the engine
     has consumed another period's worth of frames and sleeps for about as
     long as the frames still queued will take, so a late wakeup signals at
     once and lateness never accumulates. `NtSetEvent` stays on this Wine
     thread — the Core Audio render thread must not enter Wine at all, which
     is why the signal is not sent from the callback itself.
     **With a liveness backstop**, which the clock-only version needs and does
     not have for free: `play_pos` stops advancing the moment the ring is
     empty, and the thing that refills the ring is this very event, so one
     underrun would otherwise wedge a client into permanent silence. Two
     periods of wall time with no signal forces one.
  **And the ring is deeper** (line 1353): the floor goes from 100 ms to 200 ms
  so a 60-80 ms stall of the game thread — a shader compile, a level chunk, the
  JIT meeting new code — is not audible. This changes how much a client may
  queue, not the latency the endpoint reports: `get_latency` (line 1831) and
  `get_device_period` still describe the engine's 10 ms period, which is what
  they are supposed to describe, and the two were conflated once already.
  **The 10 s line grows the three numbers this round needed** and the next one
  will: `limiter_min_gain=…` with a count of limited blocks on the engine line,
  and `event_signals=…` plus `max_gap_ms=…` (the longest interval between two
  `release_render_buffer` calls, line 1684) per stream. The `CREATE` line now
  also prints what the client ASKED for (`asked=…ms ring=…ms flags=0x…`), since
  "the ring is 200 ms" only means something next to the request it came from.
  **What the next log should show.** On the engine line,
  `limiter_min_gain=0.122 (N blocks limited)` for a client peaking near 8 —
  0.98/7.99 — and a gain that stays at 1.000 when nothing is hot; the
  per-stream `peak` stays the CLIENT's own pre-limiter peak, so peak 7.99 with
  min_gain 0.122 is the limiter working and peak 7.99 with min_gain 1.000 is
  the limiter not running. `[audio] is_format_supported 6ch shared -> S_FALSE`
  once, followed — if the client takes the advice — by no 6-channel
  `create_stream` at all and one fewer silent stream. Per stream,
  `event_signals` near 100 per second of playing (one per 10 ms period) rather
  than the ragged count a drifting timer gives, and `max_gap_ms` is the number
  that finally separates the two stories: a gap far above 10 ms with
  `underruns=0` is the client stalling (look at the game thread), while
  `underruns` climbing with `max_gap_ms` near the period is us failing to
  drain (look at the mixer). `ring=200ms` on every stream line.
  **Test**: `build/x86-tests/audio-x86.c` stage (a2) now writes its 440 Hz tone
  at x4 — +12 dB over full scale, which a float client is allowed to do — so
  the whole path is exercised with a hot buffer, and it documents that
  `S_FALSE` is the expected (not failing) answer to `IsFormatSupported(5.1)`
  while `Initialize` on the same format must still succeed. Exit codes
  unchanged: 59 = all paths passed.
  Rebuilt `libntdll_unix.a` (31 succeeded / 0 failed, 1 842 088 bytes) and
  checked the produced archive carries `limiter_min_gain`, `event_signals`,
  `max_gap_ms` and the `S_FALSE` decision line.
- 2026-09-19 — Logs r76/s79 (2008-era open-world 32-bit D3D9 title) + s81.
  **Three of the four items came back negative, and the negatives are the
  result**: LRCPC2 cannot pay on this port, the mystery 25.9 % module is our
  own audio mixer, and the D3D9 redundant-state filtering the round was meant
  to add is already there. One real bug fixed: the profiler has been printing
  garbage module names for every late-loaded 32-bit DLL.
  (1) LRCPC2 — DO NOT ENABLE. FEAT_LRCPC2's entire value is folding a
  displacement into the access as `ldapur/stlur wR, [Xn, #imm9]`, which needs
  the JIT to still HAVE the displacement when it emits the access. Behind a
  guest window it never does: `Arm64JITCore::GetGuestMemAddr`
  (`FEXCore/Source/Interface/Core/JIT/MemoryOps.cpp`) returns `NoOffset` on
  every non-identity path, deliberately — the base must be applied as
  `Base + zext32(EA + disp)`, and an imm9 would add the displacement on the far
  side of the window (`Base + zext32(EA) + disp`), which leaves the window
  whenever an x86 effective address wraps at 4 GiB (the ml920 rule). Only the
  `if (!GuestBase)` early return preserves `Offset`, and that is the Linux-host
  path. So `SupportsTSOImm9 = true` emits `ldapur [Xn, #0]` — the same access as
  `ldapr [Xn]`, one architecture version further up — and moves the displacement
  add somewhere worse. Counted for `add [ebp-516], reg`, the load-modify-store
  shape the hot blocks are full of: OFF = one IR `Add` for EA+disp that CSEs
  across the load and the store, plus one `ApplyGuestBase` per access = **3**
  address instructions; ON = `SelectAddressMode` peels the displacement so there
  is no shared IR `Add` left and each access re-emits `sub Tmp, base, #516` +
  `add Tmp, REG_GUEST_BASE, Tmp, UXTW` = **4**. A one-instruction REGRESSION per
  load-modify-store, on a workload whose hot blocks are 95.1 % TSO-carrying —
  and on an A12/A13 (ARMv8.3: LRCPC yes, LRCPC2 no) an unguarded enable emits an
  undefined instruction in every JIT block. The unaligned back-patcher is not the
  blocker and never was: it already decodes and rewrites both forms
  (`Utils/ArchHelpers/Arm64.cpp` LDAPUR_INST/STLUR_INST at :2202, :2352, :2412).
  The app now probes `hw.optional.arm.FEAT_LRCPC2` and REPORTS it without
  applying it (`app/Madeira/ContentView.swift:4315-4368`, one sysctl at startup,
  `[fex-cfg] FEAT_LRCPC2=…`); the wrong "what it buys" paragraph in
  `FEX/Source/Windows/Common/CPUFeatures.cpp:82-116` is corrected in place.
  Making this a win is a `GetGuestMemAddr` change (a window-safe displacement
  path), not a feature-bit change, and the sysctl result is what that work would
  gate on. NOTE: that CPUFeatures.cpp edit is comment-only and is NOT in the
  shipped `xtajit.dll` yet — it goes out with the next FEX rebuild.
  (2) "Zx" WAS NEVER A MODULE — IT WAS ARITHMETIC.
  `ios_pe_module_name` (`build/ntdll-unix/signal_arm64_ios.c:12356`) read the
  export directory at `e_lfanew + 0x88`, which is IMAGE_NT_HEADERS**64**'s
  DataDirectory[0]. In a 32-bit image OptionalHeader32 puts DataDirectory at
  +0x60, so the export directory is at `e_lfanew + 0x78` and +0x88 is
  DataDirectory[2] — RESOURCE. `exp_rva` was therefore the resource RVA,
  `name_rva` came from offset 0x0c of IMAGE_RESOURCE_DIRECTORY
  (`NumberOfNamedEntries | NumberOfIdEntries << 16`, a small plausible number
  that passes the range check), and the "name" was 63 arbitrary bytes from there.
  Hence `Zx`, and `PnQ`, and `Zx` printed TWICE in one table (r76:6858
  `Zx=42.4% … Zx=0.2%`) for two different images. `SizeOfImage` happens to sit at
  +0x50 in both layouts, which is why `ios_gmod32_probe`'s own reads were right
  and only the name was wrong. Now selected from `OptionalHeader.Magic`
  (0x10b → +0x78, 0x20b → +0x88), and a name that is not printable ASCII is
  reported as `?` rather than as a module, so the next instance of this
  announces itself instead of looking like a discovery.
  **Compounding half**: `ios_gmod32_build` latched on `ios_gmod32_from_ldr` and
  never re-walked, so the map was a snapshot of whatever was loaded the first
  time a sample landed in 32-bit code. In r76 it ran at :5164 with 50 modules and
  the guest then loaded seven more at :5708-:6701 — an XAudio2 implementation, an
  XACT engine, mfplat/mfreadwrite/rtworkq and two DMO codecs — none of which
  could ever be named from the loader again. It is re-walkable now and
  `ios_guest32_module_idx` asks the LOADER on a miss before falling back to the
  MZ probe (rate-limited 1-in-256, because a sample in a genuinely unlisted image
  would otherwise re-walk ~50 entries every 5 ms). The banner only reprints when
  the count changes.
  **WHAT IT IS**: guest base 0x79E30000 = the **XAudio2 implementation Wine
  loads for the guest** — our own software mixer, not the game's code, not
  middleware, and emphatically not a packer. The two hot blocks are a per-sample
  conversion loop (`cvtsi2sd`, a `movsd` of a constant from the same image at
  +0x2fe68, an 8-byte stack realign, vec=12/16 and mem=39/52 over ~100 guest
  insts) and the two of them alone are ~5 % of all CPU; the module is **21-44 %
  of all CPU** across the run. The largest single CPU consumer in this title is
  software audio mixing, not rendering.
  **AND THERE IS NO SMC / INVALIDATION STORM.** `blocks` rises monotonically and
  never falls (9478 → 21049) while `hit_rate` RISES 70 % → 85 %: that is an open
  world streaming in new code paths and a lookup cache warming, which is what
  `+1150 blocks/window` means here. Invalidation traffic is 55 `[iOS-xrem]` lines
  in the whole of r76. Nothing to fix. (`cpp_dispatch` is quantised to 16384
  steps, so its per-second rate is an artefact of the counter, not a measurement.)
  (3) PER-FRAME SERVER CALLS — the top one is ours and it is two round trips per
  window MESSAGE, not per frame. `get_window_property: NtUserGetProp+0x7c` is
  2088-2994 per 10 s in both logs, and the caller is the D3D9 focus-window
  subclass: `research/dxmt/src/d3d9shim/d3d9shim_window.c:332-333` opens every
  message with `GetPropW(hwnd, kFocusProcProp)` + `GetPropW(hwnd,
  kFocusDeviceProp)`, each a `get_window_property` server round trip at 42 µs.
  (The identical code in `d3d9/d3d9_device.cpp:2100-2101` is inside
  `#ifndef DXMT_MADEIRA` and is not the one running.) The shim INSTALLED the
  subclass, so it already knows both values: a small HWND-keyed process-local
  table with `GetPropW` kept only as the miss path removes both round trips.
  Left to the owner of that file. `set_cursor` is the app itself —
  `NtUserShowCursor+0x4c` 728-988 and `NtUserClipCursor+0x1f0` 364-494 per 10 s,
  i.e. a per-frame `ShowCursor`, in user32/win32u. `get_async_result:
  irp_completion+0x58` and `ioctl: server_ioctl_file+0x17c` are **976-978 per
  10 s in all three logs regardless of load** — a fixed ~97.7/s, i.e. a ~10.2 ms
  periodic overlapped-IRP poll (the shape of a HID/input device read), not
  per-frame work; at 70 µs the pair it is 0.7 % of one core and not worth a
  change this round. Whole-server cost is `in-call` 1.0-1.3 s per 10 s =
  0.10-0.12 core, so item (3)'s entire addressable budget is smaller than one of
  the two audio blocks in item (2).
  (4) D3D9 REDUNDANT-STATE FILTERING IS ALREADY IMPLEMENTED — all four methods,
  with the early-out after the validation gates and after the census hook,
  exactly as asked: `SetTexture` `if (m_textures[slot].ptr() == common) return
  D3D_OK` (`d3d9_device.cpp`, with a comment naming the "engines that re-issue
  every per-draw state-set" case), `SetRenderState` `if (m_renderStates[State] ==
  Value)`, `SetSamplerState` `if (m_samplerStates[slot][Type] == Value)`, and
  `SetVertexShaderConstantF` a `memcmp` short-circuit against the shadow array
  (hot registers and the >=256 overflow store both). Nothing to add. So the
  13.8 % of all CPU in `d3d9-emulated.dll` is NOT redundant work — it is the
  fixed per-call cost of 5540 i386 calls per frame going through the JIT, and the
  one remaining lever is the native ARM64 frontend. That matters more here than
  it did for the UE3 title (4.6 %): **13.8 % is well clear of the 5 % bar**, and
  the A/B is unchanged — `Documents/madeira-d3d9.txt` = `native`.
  One contained thing an owner of `d3d9_census.cpp` should weigh: `D3D9_CENSUS`
  runs `g_calls[code].fetch_add` AND `census::ringCall(code)`
  (`d3d9_census.cpp:415`, a second atomic RMW plus an out-of-line call and ~8
  stores) on every one of those 5540 calls/frame — ~220 k calls/s, ~440 k JIT'd
  `lock xadd`/s, on the hottest path of the hottest guest DLL. The counter is the
  measurement; the `[d3d9-last]` ring is crash forensics and could be gated
  separately without losing a number anyone reads.
  **What to look for in the next log:** no `Zx` and no `PnQ` in `[prof] jit by
  module` — the audio DLL named properly and appearing ONCE, and `?` only where a
  module genuinely has no readable export name; `[prof] ml930 guest32 modmap`
  reprinting with a rising count as the guest loads more DLLs (50 → ~57 in r76's
  shape); `[fex-cfg] FEAT_LRCPC2=1` on A14+ with the "NOT auto-enabled" text and
  no change to `jit tso`. Unchanged on purpose: `blocks`, `hit_rate`, the server
  `kinds` table, and `d3d9-emulated.dll`'s share.

- 2026-09-19 — **A 32-bit title died in `strlen` inside 64-bit ntdll, called
  from `libwow64fex.dll+0x1ca44` with `x0 = 0xfff95000`. It is NOT a missing
  `+ B`: it is an out-of-range subscript in FEXCore's CPUID brand-string
  emulation, and it can fire on any host, on any title that asks the CPU its
  name.** Log s83, ~1230 lines in, right after wininet/windowscodecs/propsys
  load: `SEGV pc=0x11aca4ffc addr=0xfff95000 x0=x19=0xfff95000`,
  `pc PE: ntdll.dll+0x68ffc`, `lr PE: libwow64fex.dll+0x1ca44`, insn stream
  `aa1f03e8 [38686809] 91000508 35ffffc9` — a `ldrb w9,[x0,x8]` strlen loop.
  **Naming the frame decides the whole diagnosis.** `llvm-objdump -d
  --start-address` over the SHIPPED `app/Madeira/aarch64-windows/xtajit.dll`
  (ImageBase `0x180000000`, so RVA `0x1ca44` becomes VA `0x18001ca44`) lands one
  instruction past `bl strlen` inside
  `_ZNK7FEXCore8CPUIDEmu19Function_8000_0002hEj` —
  `FEXCore::CPUIDEmu::Function_8000_0002h(uint32_t Leaf) const`, the
  **processor brand string**, CPUID leaf `0x8000'0002`. The caller-insn word in
  the log (`@lr-4 = 0x9406f54e`) is that `bl` exactly, and the guest state
  confirms it from the other side: `rax=0x80000002`, with `rbx=0x756e6547`
  ("Genu") and `rdx=0x49656e69` ("ineI") still in the registers from the
  `CPUID(0x8000'0000)` the guest issued one instruction earlier. Full chain:
  32-bit guest `cpuid` -> `Pointers.CPUIDFunction` (`JIT.cpp:750`, the
  NONCONSTANT path — leaves `0x8000'0002..4` and `0x1A` are marked
  `NONCONSTANT` in `CPUID.h`, so they are *not* constant-folded by
  `RegisterAllocationPass.cpp:533` and are resolved at runtime) ->
  `CPUIDEmu::RunFunction` -> `Function_8000_0002h(Leaf)` ->
  `PerCPUData[GetCPUID()].ProductName` -> `strlen`. `BTCpuSimulate` ->
  `BTCpuSimulateImpl` -> `ExecuteThread` is the outer frame; the `[exit-stk]`
  dump agrees.
  **Why it is not a pointer-namespace bug, stated so it cannot be re-litigated.**
  `PerCPUData[i].ProductName` is assigned in exactly three places
  (`CPUID.cpp:171`, `:391`, `:405`) and every one of them stores a
  `ProductNames::*` string literal — `.rdata` of this very module, which in
  log s83 is mapped at host `0x70ffcc…`. A correctly-indexed element therefore
  **cannot** hold `0xfff95000`, with or without a guest window, so no `+ B` is
  missing anywhere on this path. The disassembly shows what actually happened:
  `blr [this+0x40]` (`GetCPUID`), `ubfiz x9, x0, #4, #32`, `ldr x19, [x8, x9]`
  — an unchecked `<< 4` subscript into a `fextl::vector<CPUData>` of 16-byte
  entries. `0xfff95000` is whatever the neighbouring heap object held. (It has
  two flattering readings — guest `0xfff40000 + 0x55000`, i.e. inside the
  i386 ntdll that `[laa]` put in the high half yesterday, and the low 32 bits
  of host `0x70fff00000 + 0x95000`, the 64-bit ntdll — and both are
  coincidences of "near the top of a 4 GB region". Neither is reachable
  through this code.)
  **The mismatch that makes the subscript out of range.** `PerCPUData` is sized
  by `SetupHostHybridFlag` from `HostFeatures.CPUMIDRs`
  (`CPUID.cpp:159`; `Cores = CPUMIDRs.size()` at `:1346`). `GetCPUID()` answers
  from a completely unrelated source: on this branch
  `GetCPUID_Syscall` -> `FHU::Syscalls::getcpu` -> the `_WIN32` arm,
  `GetCurrentProcessorNumber()` (`Syscalls.h:123`) ->
  `FEX/Source/Windows/Common/WinAPI/Sync.cpp:130` ->
  `NtGetCurrentProcessorNumber` -> `build/ntdll-unix/thread_ios.c:3215` ->
  `pthread_cpu_number_np()`, i.e. the REAL core the thread is on, 0..N-1 on the
  device. And the iOS branch of `FEX::Windows::CPUFeatures::FetchHostFeatures`
  publishes **one** synthetic MIDR (`CPUFeatures.cpp:117`,
  `HostFeatures.CPUMIDRs.push_back(0u)`) because the `Hardware\…` registry keys
  the non-iOS branch reads do not exist here. So `PerCPUData.size() == 1` while
  `GetCPUID()` returns 0..5, and every brand-string CPUID taken on a core other
  than 0 read 16/32/48/64/80 bytes past a 16-byte allocation. Note also that
  `SupportsCPUIndexInTPIDRRO` is `!IsWine` (`CPUFeatures.cpp:145`), so under
  Wine the TPIDRRO fast path is off and the `getcpu` path above is the live one.
  **The fix (`ml980`), in FEXCore, generic, no placement involved.**
  `CPUID.h:188` adds `WrapCPUIndex()` — the ONE place a host CPU number becomes
  a `PerCPUData` subscript — and `:197` `CurrentCPUIndex()`. `RunFunctionName`
  (`:60-68`) now calls it instead of open-coding `CPU % PerCPUData.size()`,
  which also removes the divide-by-zero it would have taken on an empty list.
  The single-argument overloads the JIT actually calls are switched over:
  `CPUID.cpp:1116/:1120/:1124` (leaves `0x8000'0002/3/4`) and `:928`
  (`Function_1Ah`, the hybrid leaf — unreachable while there is one MIDR, but
  wrong in exactly the same way). `Function_01h`'s local APIC ID (`:466`) is
  bounded too: an APIC ID must be one of the `Cores` addressable IDs reported
  in the same EBX, and an unbounded one also made a leaf that FEX's own tables
  call NONCONSTANT vary by *which core ran it*. Wrapping rather than clamping
  keeps `RunFunctionName`'s existing behaviour bit-for-bit.
  **Deliberately NOT done: resizing `CPUMIDRs` to the real core count.** That
  is the other way to make the two numbers agree, and it is a guest-visible
  topology change — `Cores` feeds CPUID.01h EBX[23:16], "number of addressable
  logical cores", which is how legacy code counts CPUs. The guest already gets
  the true count from `peb->NumberOfProcessors` via `GetSystemInfo`, so the
  disagreement is cosmetic today; raising it would change how a title sizes its
  worker pools, which is a separate decision with its own A/B and not something
  to smuggle into a crash fix. The invariant that must hold either way is the
  one now enforced: **the index is bounded by the table, not by a hope that two
  independent sources of "how many cores" agree.**
  **Why it never fired before.** Not placement, and not luck about `[laa]`.
  Nothing else we have run issues `CPUID(0x8000'0002)`: no other log in the
  series contains a `libwow64fex.dll+0x1ca44` frame, or any frame in that
  function. It is a brand-string probe — a CRT / CPU-detection idiom a 2012-era
  title does at startup and that our test programs, the D3D9 cube and the other
  titles never do. Once a title *does* issue it the fault is near-certain
  rather than rare: roughly five cores in six give an out-of-range index, and
  the read only survives if the neighbouring heap word happens to be a readable
  host pointer — in which case the guest silently got a garbage CPU name, which
  is the "working by accident" outcome the same code would have produced on any
  earlier build. Before yesterday the same OOB read would have found a
  *different* garbage word; had it been a guest address it would have read
  `0x7bf95000` instead of `0xfff95000` and faulted identically. The high-half
  placement neither caused this nor is any part of the fix, and no builtin
  needs pinning back to its traditional base on this account.
  **Audit of the WOW64 module for the same class** (every value read from guest
  registers, guest memory or a guest image header that is then dereferenced or
  passed to a host function as a pointer). Already correct, with the evidence
  in place: `HandleSyscallImpl`'s `[ESP]` return address, the unix-call
  `StackLayout` and its `Args` block, and the `Wow64SystemServiceEx` argument
  block (`Module.cpp:742`, `:751`, `:764`, `:776`, all via
  `GuestWindow::ToHost`/`ToHostPtr`); `LdrSystemDllInitBlock.ntdll_handle`
  (`:1119-1121`, guest -> `ToHost` before `HandleImageMap`); TEB32 via
  `GetWowTEB` (`:400`) with a window assertion; the BOP page, published guest
  and tracked host (`:1217`); `LookupExecutableFileSection` /
  `QueryGuestExecutableRange` / `Mark*Range` (`:806-845` — `+B` in, `-B` out,
  and a `Contains()` rejection instead of arithmetic nonsense for anything
  outside the window); `BTCpuResetToConsistentStateImpl`'s
  `ExceptionInformation[1]` (`:1700`, kept HOST on purpose — `wow64.dll`'s
  `exception_record_64to32` owns the single `-B`); every `BTCpuNotify*`
  callback (`:1783-1900`, host by contract, each with its `wow64.dll` call site
  cited); `GetImageNameFromExports` (`:436`, RVA bounded by `SizeOfImage`);
  `InvalidationTracker::DetectMonoBackpatcherBlock`
  (`InvalidationTracker.cpp:927`, lifts a guest RIP by `GuestBase` before
  reading code bytes); `CallRetStack::RejectNonPoolTargets`
  (`CallRetStack.h:183`, refuses a frame whose host half is a guest address).
  `BTCpuIsProcessorFeaturePresent` and `BTCpuUpdateProcessorInformation` take
  no guest pointer at all. One incidental invariant worth recording: `B` is
  4 GiB-aligned, so `wow64_private.h`'s `host_ptr32()` (`(ULONG)(addr - B)`) is
  correct whether it is handed a host address in the window or a value that is
  already a guest address — which is why `HandleGuestException`
  (`Common/Exception.h:15`) writing a guest `Eip` into a 64-bit
  `EXCEPTION_RECORD` still produces the right 32-bit record.
  One latent gap, currently failing closed and left alone:
  `LoadImageVolatileMetadata` (`ImageTracker.cpp:51-57`) compares
  `LoadConfig->VolatileMetadataPointer` — a `ULONG` guest VA, since
  `ArchImageLoadConfigDirectory` is `_IMAGE_LOAD_CONFIG_DIRECTORY32` for this
  build — against `Address`, a HOST image base at or above `0x7100000000`. The
  test is therefore always true and the function returns before dereferencing
  anything, so volatile metadata is silently disabled for every windowed
  process. That is a missing `+ B`, but it costs an optimisation rather than
  correctness, and enabling a path that has never once run on this target does
  not belong in a crash fix.
  **Built**: `.xtool/build-fex.sh` (42/42, `libwow64fex.dll` ->
  `app/Madeira/aarch64-windows/xtajit.dll`, 4 702 208 B) and
  `.xtool/build-fex-arm64ec.sh` (`app/Madeira/arm64ec-windows/xtajit64.dll`,
  5 246 976 B), because `CPUID.cpp`/`CPUID.h` are FEXCore and shared with the
  ARM64EC module. Verified in both shipped binaries: `Function_8000_0002h` now
  emits `ldp x8, x9, [x19, #0x28]` -> size -> `cmp #2` -> `udiv`/`msub` before
  the `<< 4`, with a branch to index 0 for a one-entry table. `wow64.dll` was
  not touched.
  **What the next log should show**: one new line per process, early,
  `[cpuid] ml980 PerCPUData entries=1 host cpu now=<0..5> source=getcpu …`
  (`CPUID.cpp:1376`) — `entries=1` against a varying `host cpu` IS the
  mismatch, printed where a future reader can see it without a disassembler —
  and no `SEGV … lr PE: libwow64fex.dll+0x1ca44` at all. The title should walk
  past its brand-string probe and read back a CPU name of `Unknown ARM CPU`
  (the single `ARM_UNKNOWN` entry), which is cosmetic and correct; whatever it
  does next is where the next line of evidence has to come from.

- 2026-09-19 — **A DEBUG PROBE INSIDE `virtual_mutex` FAULTED, AND THE FAULT
  DEADLOCKED THE WHOLE PROCESS AGAINST THE EXCEPTION THREAD.** The 2012-era
  32-bit title from logs t85 (direct launch) / t86 (from the Wine desktop)
  loads ~60 DLLs, gets past the ml980 CPUID fix, creates its CRT worker
  threads and then stops dead: no `MADEIRA-EXIT`, no fault report, no
  `[srv-stuck]`, `[waiters] parked=0`, `[prof] busy=0.04 cores wait=99.7%`
  with only host UI threads sampled. All three silences have ONE cause, and
  none of the hypotheses the symptom suggests (missing child process, absent
  service, invisible modal, COM activation) is it: no `NtCreateUserProcess`
  line exists in either log, and the last guest work is a thread creation.
  **The chain, with line numbers.** t85:1119 and t85:1191 `[thr-create]
  start=0x71786af7d0` — both new threads start at `msvcr100.dll+0x5f7d0`
  (base `0x7178650000`, t85:784), i.e. `_beginthreadex`'s `_threadstartex`;
  t85:1190 is their `SetThreadName` exception (`code=406d1388`). One of them
  calls `VirtualAlloc(MEM_COMMIT)`, which takes `virtual_mutex` at the top of
  `NtAllocateVirtualMemory` and holds it across the commit branch
  (`virtual_ios.c:16930`). That branch ends in `ios_verify_commit_zero`
  (`:11665`, the ml293 "MEM_COMMIT must read back as zero" probe), which did
  a plain `ldrb` over the first 64 bytes of the freshly committed range —
  t85:1195 `[store-noalias] addr=0x71018f2000 insn=0x3869680a
  pc=0x10479e8a8 ... region 0x71018f0000+0x4000 prot=0 max=7`, t86:5280 the
  identical fault at `0x7101902000`. The page the commit had just reported
  `STATUS_SUCCESS` for is `PROT_NONE`, so the probe took `EXC_BAD_ACCESS`.
  **Naming the frame is what makes this readable.** `llvm-nm -n` over the
  shipped `.build/arm64-apple-ios/release/Madeira-App` gives
  `_ios_pool_warmer_thread` at `0x1001a639c` and `_madeira_get_present_count`
  at `0x10031c170`; the profiler prints both at runtime (`+0x33c` =
  `0x10479a6d8`, and `0x104910170`), so the slide is `0x45f4000` exactly and
  t85's `pc=0x10479e8a8` is `ios_verify_commit_zero+0x80` — the `ldrb
  w10,[x0,x9]` of `ios_first_nonzero`. The same nm resolves the register dump
  two lines later: t85:1213 `x0=0x1058db078` is `_virtual_mutex`
  (`0x1012e7078 + 0x45f4000`) and t85:1214 `x16=0x12d` is
  `__psynch_mutexwait`. **The main thread was already blocked on
  `virtual_mutex` two seconds into the process.**
  **Why the fault can never complete.** The Mach message goes to
  `wine-x18-exc`, and every route it can take to deliver the exception locks
  `virtual_mutex` (`virtual_handle_fault` `:15904`, the `[fault-rgn]` dumper
  `:16031`, `virtual_setup_exception`) — a lock held by the very thread whose
  fault it is servicing. t86's 20 s `[thread-stacks]` sampler states both ends
  outright, unchanged across three consecutive dumps 20 s apart (t86:5702,
  :6205, :6711): `port=0x1f9c3 "Core_5 - Thread 0"
  pc=Madeira!ios_verify_commit_zero+0x80 run=3 susp=0 cpu=0` — parked AT the
  faulting instruction — and (t86:5598, :6101, :6607) `port=0x10013
  "wine-x18-exc" pc=__psynch_mutexwait x8=0x1061a709f`, i.e. mutex
  `0x1061a7078` = `virtual_mutex` at t86's slide `0x4ec0000`. Neither ever
  runs again, and every later `VirtualAlloc`/`VirtualProtect`/`VirtualFree`,
  every page-fault fixup, every module load and every thread creation in the
  process queues behind them. That is precisely why the wineserver-side
  reporters said nothing: **nobody is in a server wait**, so `[srv-stuck]`
  has nothing to report and `[waiters] parked=0` is accurate. The ml378
  "BEST-EFFORT delivery on guest stack" line (t85:1197) is a red herring on
  this path — the thread never gets far enough to use the fabricated frame.
  **Fix 1 (`ml981`, the cause): a probe that runs under a process-wide lock
  may never take a fault.** `ios_verify_commit_zero` now reads through
  `mach_vm_read_overwrite` into a stack buffer instead of dereferencing the
  guest pointer: an inaccessible page comes back as a failed `kern_return`
  on the calling thread rather than an exception. The probe's own ml293
  comment claimed it "can never itself fault" because it checks the
  protection first — it checks the protection the CALLER ASKED FOR, not the
  one the page ended up with, and that gap is the entire bug. A refused read
  is now the loudest line in the log rather than a hang:
  `[commit-noaccess] ... *** COMMIT SUCCEEDED BUT PAGE IS UNREADABLE ***
  base=... size=... protect=... host_page_vprot=0x... unix_prot=0x...
  region=...+... prot=... max=... rev=ml981`.
  **What the next log must answer, and the standing hypothesis.**
  `host_page_vprot` is the field to read. iOS host pages are 16 KB and guest
  pages are 4 KB, `get_host_page_vprot` (`:8001`) ORs the four sub-page bytes
  together, and `get_unix_prot` returns `PROT_NONE` for ANY vprot carrying
  `VPROT_GUARD` (`0x10`, `:4532`). So a guest `MEM_COMMIT` of a 4 KB page
  that shares its 16 KB host page with a `PAGE_GUARD` page makes the whole
  host page inaccessible even though the commit itself is correct — which is
  what a 2012 engine committing heap adjacent to its own guard page would
  produce. If the next log prints `host_page_vprot` with bit `0x10` set, that
  is confirmed, and upstream's `virtual_handle_fault` guard branch (`:15916`)
  already self-heals it on first touch at the cost of one spurious
  `STATUS_GUARD_PAGE_VIOLATION`; if bit `0x10` is clear while `unix_prot`
  says `PROT_READ|PROT_WRITE`, then `mprotect_exec` is reporting a success it
  did not apply and the hunt moves there. Deliberately NOT changed now:
  `get_unix_prot`'s guard handling. Making a mixed guard/non-guard host page
  accessible changes when the guest sees its guard-page exception, and that
  is a behaviour decision that needs its own evidence, not a smuggled-in
  side effect of a crash fix.
  **Fix 2 (`ml981`, the diagnostic gap): `[thread-stacks]` is armed in every
  launch mode.** The 20 s sampler was created inside
  `winios_ensure_compositor` (`app/Madeira/Winios/Winios.m`), i.e. only when
  explorer's desktop attaches — t86 has 697 `[thread-stacks]` lines and t85,
  the direct launch of the same title hitting the same wedge, has **zero**.
  The one report that answers "what is each thread blocked in" was absent
  from exactly the mode being debugged. It now starts from
  `winios_freeze_watch_start`, which runs in every mode, and announces itself
  (`[thread-stacks] 20s sampler armed rev=ml981`) so its absence can never
  again be mistaken for "nothing to report".
  **Fix 3 (`ml981`): `[thread-stacks]` names the lock.** A thread stopped in
  `__psynch_mutexwait` carries the contended mutex in `x0` (and `x0+0x27` in
  `x8`). Printed raw it costs a slide reconstruction and an `llvm-nm` run —
  the detour this entry is made of. `ios_name_unix_lock` (`virtual_ios.c`,
  addresses only, reads no state, so it is safe from a sampler while the lock
  is held) maps the process-wide locks whose loss stops everything —
  `virtual_mutex`, `ios_pool_lock`, `ios_wow_mutex`, `fd_cache_mutex` — and
  the dump now appends ` lock=ntdll:virtual_mutex`. One line, and this class
  of hang identifies itself.
  **Not the cause, checked and ruled out.** The store-client loader DLL
  (t85:829) and `dbghelp.dll` (t85:1114) both load and return; the video
  codec DLL maps at its own fixed base (t85:839); the only `err:`/`fixme:`
  traffic after line 1000 is benign (`RtlSetHeapInformation`,
  `wow64_NtQuerySystemInformation class 61453`, the `\\.\Nsi` device,
  `set_native_thread_name`); the only `OutputDebugStringA` is our own d3d9
  forwarding notice (t85:951); and neither log contains a process-creation
  request of any kind.

- 2026-09-19 â€” **The native ARM64 D3D9 frontend's first two device runs: a
  four-byte struct-tail overrun that smashed the application's stack cookie,
  and a guest arena that was never created at all.** Both titles bound the
  unix side (`[unixlib] d3d9shim â€¦ -> wow64 table`), enumerated modes and got
  `CreateDevice â€¦ -> hr 0x0`, so the transport, the handle table, the object
  model and the vtables are right; both then died in guest code within a
  handful of calls. The two causes are unrelated and both are at the boundary.

  **(1) `0xC0000409` in the application's own epilogue (t90).** The last
  crossings in the log are `GetDeviceCaps`, `GetAdapterIdentifier` and two
  `CheckDeviceFormat`s, and the fault address is in the title, not in D3D9 â€”
  which is what a `/GS` cookie check looks like: the frame was corrupted
  earlier and the corruption is only detected when the function returns.
  `D3DADAPTER_IDENTIFIER9` is the one struct the boundary classifies
  "padding-only": every field at the same offset, but `sizeof()` is **1100**
  on i386 and **1104** on LP64, because `d3d9types.h` opens with
  `#pragma pack(push,4)` â€” which caps the `LARGE_INTEGER DriverVersion`
  member's alignment at 4 on i386 and leaves it at 8 on LP64, so only the tail
  padding differs. Measured, not assumed: `i686-w64-mingw32-clang` 1100,
  `x86_64-w64-mingw32-clang` 1104, both against the same header, and the pack
  directive is the SDK's, so an MSVC-built title has 1100 too. The unix entry
  pointed the frontend at the guest buffer *in place* (the window check
  already used `D3D9SHIM_SIZE32_*`, so only the write was wrong), and
  `MTLD3D9Interface::GetAdapterIdentifier` (`src/d3d9/d3d9_interface.cpp:594`)
  opens with `std::memset(pIdentifier, 0, sizeof(*pIdentifier))` â€” 1104 bytes
  into an 1100-byte buffer. Titles declare that struct as a stack local, so
  the four bytes past its end are the cookie. FIX: it bounces like a mirror.
  `gen_d3d9_thunks.py` emits a host-layout local, hands the frontend that, and
  copies back through a new `D3D9_COPY32_OUT(T, guest, host)` which copies
  exactly `D3D9SHIM_SIZE32_<T>` bytes and carries its own
  `_Static_assert(D3D9SHIM_SIZE32_##T <= sizeof(T))`; `D3D9_COPY32_IN` is the
  other direction. Those two macros are the whole copy surface for a
  padding-only struct, and `generator_self_check()` now **refuses to emit** any
  `out_struct`/`inout_struct` whose target is not a mirror, a padding-only
  bounce or a declared layout-identical struct â€” so the next struct added to
  the description cannot default to a host-sized write into a guest buffer.
  The audit behind that rule: `D3DCAPS9` 304/304, `D3DGAMMARAMP` 1536/1536,
  `D3DLIGHT9` 104, `D3DMATERIAL9` 68, `D3DVIEWPORT9` 24, `D3DSURFACE_DESC` 32,
  `D3DVOLUME_DESC` 28, `D3DVERTEXBUFFER_DESC` 24, `D3DINDEXBUFFER_DESC` 20,
  `D3DDISPLAYMODE(EX)` 16/24, `D3DRASTER_STATUS` 8, `D3DCLIPSTATUS9` 8,
  `RGNDATA` 36 â€” every one identical on both ABIs; the five mirrors already
  bounced; `D3DADAPTER_IDENTIFIER9` was the only in-place write whose two
  sizes differ, and it is the only one a title touches during device init.

  **(2) The guest arena was never registered (t89).** The log says it plainly,
  one line before `CreateDevice â€¦ -> hr 0x0`: `[d3d9-native] arena: no chunk
  registered â€” the shim has not called d3d9_native_arena_register yet, so every
  app-visible allocation fails`. `d3d9shim_arena_init()` only constructed its
  critical section, on the reading that the arena grows on demand â€” but it
  cannot, because the consumer is `dxmt::guest_alloc()` on the *native* side
  and the only caller of `d3d9shim_arena_grow()` is the shim's answer to
  `D3D9SHIM_STATUS_ARENA_EXHAUSTED`, which nothing ever produced. So the arena
  started empty and stayed empty: every Lock mirror, every MANAGED/SYSTEMMEM
  mirror and every backing-pool block was a NULL allocation while the create
  call it was made for still returned `S_OK`. FIX: `d3d9shim_arena_init()`
  (`d3d9shim_arena.c`) reserves and registers the first 64 MB chunk from the
  transport handshake, before any D3D9 object can exist; and the
  grow-and-retry path of Â§8.2(c) is now actually reachable â€” a `guest_alloc()`
  that cannot be served leaves a *per-thread* mark
  (`d3d9_native_arena_take_starved()`), the generated unix entry takes it
  after every `HRESULT` method and, if the call also failed, returns
  `D3D9SHIM_STATUS_ARENA_EXHAUSTED` so the shim grows and retries the same
  block once. Only on a failed `HRESULT`, so a retry can never repeat work
  that succeeded; per-thread so a starving DXMT worker cannot make an
  unrelated call on another thread look like an exhaustion.

  **What the bus fault in t89 is, and what it is not.** The store that faults
  (`addr=0x7103721e5b insn=strb w22,[x19,w21,uxtw]`, guest `0x03721e5b`) is
  **not** a `Lock` pointer: `[bus-rgn]` says `region=0x7103650000+0x33c000
  prot=1 max=1 share_mode=4`, and `[fault-rgn]` says `protect=0x800021`, i.e.
  `SEC_FILE | VPROT_READ | VPROT_COMMITTED` â€” a read-only **data-file** view,
  not arena memory and not an image. The arena was empty in that run, so it
  had handed the title no pointer at all. That fault therefore belongs to the
  file-mapping path (a view the guest expected copy-on-write, mapped
  `MAP_SHARED` read-only), not to D3D9, and is left to that owner; it is
  recorded here because the arena line sitting immediately above it in the log
  invites the opposite conclusion. What D3D9 owes is the ability to tell the
  two apart next time, which is (3).

  **(3) Two diagnostics the next log needs.** `MADEIRA_D3D9_LOCKCHECK=1` arms
  a writability assertion on every pointer handed back to the guest â€” the two
  `pBits` and the two buffer `Lock()`s' `ppbData`, all of which funnel through
  `d3d9_guest_ptr32()`. In-window is not the same thing as writable, so the
  pointer is looked up in the arena (a miss names a missed
  `dxmt::guest_alloc()` site) and the first and last byte of its allocation are
  read and written back unchanged: a non-writable mapping then faults on the
  guest's own thread inside a named function with the allocation printed,
  instead of thousands of translated instructions later. And `[d3d9-last]`:
  the census summary only prints on a Present cadence, so a title that dies
  during device init produced no census at all, and a fault in the
  application's own code carries no D3D9 frame â€” the same counter site now
  records a per-thread last opcode (printed by every census summary), and
  `MADEIRA_D3D9_TRACE=1` prints one line per crossing, the last of which names
  the call the guest was in when it died.

  **What the next log should show.** The `[d3d9-arena] chunk 0xâ€¦â€¦â€¦ size 64 MB,
  committed 64 MB` line during `Direct3DCreate9`, and **no** `arena: no chunk
  registered`; `GetAdapterIdentifier` still reporting `hr 0x0` with the same
  vendor/device/description, and the title getting past the caps-and-formats
  block that `0xC0000409` used to end â€” i.e. a first `Present`, and with it the
  first `[d3d9-native-census]` summary (which now also carries `[d3d9-last]`
  and the arena high-water). Under `MADEIRA_D3D9_LOCKCHECK=1`, a handful of
  `[d3d9-lockcheck] ok â€¦ writable` lines at the first `Lock`/`LockRect`; a
  `[d3d9-lockcheck] â€¦ the arena never allocated it` line instead would name an
  app-visible allocation site still on the host heap, and a fault *inside*
  `d3d9_native_lockcheck` would mean the arena chunk itself is not committed â€”
  either answer is a decisive one rather than a guest-side store with no
  provenance. Both halves rebuilt and both host-validation compiles are clean
  at `-Wall -Wextra`; `D3D9SHIM_API_HASH = 0xf49329770a2bc97b`, so a stale
  half refuses at `_d3d9_init` rather than running with the old layout.

- 2026-09-19 — **A WMA decoder MFT, on libavcodec, because there is no
  GStreamer on iOS.** Device log t84, the same 2008-era 32-bit title as s79:
  its PCM menu sounds were clean and everything else — gameplay music, cutscene
  dialogue — was static and "the wrong audio". Three lines say why:

      err:module:load_dll [dll-missing] L"C:\windows\system32\winegstreamer.dll"
                          status=c0000135
      err:ole:com_get_class_object no class object {5b4d4e54-…} could be created
      fixme:ole:CoCreateInstanceEx no instance created for interface
          {bf94c121-…} (IMFTransform) of class {2eeb4adf-4578-4d10-bca7-bb955f56320a}
          (CLSID_CWMADecMediaObject), hr 0x80070005

  The title's voices are xWMA. FAudio decodes one by asking COM for the
  Windows WMA decoder MFT (`wine/libs/faudio/src/FAudio_platform_win32_wmadec.c`:
  `CoCreateInstance(CLSID_CWMADecMediaObject, …, IID_IMFTransform, …)`); in Wine
  that CLSID is `wmadmod.dll`, which forwards to `CLSID_wg_wma_decoder`
  `{5b4d4e54-…}` in `winegstreamer.dll` (`wine/dlls/wmadmod/wmadmod.c:40`),
  whose decoder is a GStreamer pipeline on the unix side. **And FAudio, handed
  no decoder, submits the voice's COMPRESSED bytes to the mixer as if they were
  PCM.** That is not a missing-feature failure mode, it is a loud one: it is
  exactly the 8x-full-scale peaks the s79 audio census reported, and it is why
  the bus limiter from that entry could make the result quieter but never
  correct — a limiter on a bitstream is still a bitstream. A PCM menu sound
  needs no decoder at all, which is the entire reason the menu sounded fine.

  **Why the DLL was missing, and why the fix is not "turn it on".**
  `configure` sets `enable_winegstreamer=no` when the GStreamer development
  files are absent (`.xtool/logs/configure-wine-stageA.log`: "gstreamer-1.0
  base plugins development files not found"), which puts `dlls/winegstreamer`
  in the generated Makefile's `DISABLED_SUBDIRS` — so makedep emits its import
  library and its two resources and *no object or module rules at all*. But the
  gate is in `configure`, not in `Makefile.in`, and only the seven
  `#pragma makedep unix` files (`unixlib.c`, `wg_allocator.c`, `wg_format.c`,
  `wg_media_type.c`, `wg_muxer.c`, `wg_parser.c`, `wg_transform.c`) ever include
  `<gst/gst.h>`. The PE half — including `wma_decoder.c` — has never needed
  GStreamer. So the rules are written by the local stage scripts
  (`.xtool/build-wine-i386.sh`, `.xtool/build-wine-64.sh`) and handed to make as
  a second `-f` fragment that inherits `$(<arch>_CC/CFLAGS/LDFLAGS)` from the
  real Makefile; upstream's `configure.ac` and `Makefile.in` are untouched.
  `winegstreamer.dll` is now in the i386 farm (634,880 bytes) and the aarch64
  farm (983,040 bytes, with `wmadmod.dll` beside it); the arm64ec farm is
  unchanged because its build tree in this checkout is an include-only symlink
  directory (`build-wine-64.sh --configure-arm64ec` would have to run first).
  Nothing had to be registered: the shipped `app/Madeira/prefix-template.tar.gz`
  was snapshotted from a host Wine that ran `wine.inf`'s `RegisterDllsSection`,
  so `system.reg` already carries all 18 `wg_*` CLSIDs, `{2eeb4adf-…}` with its
  `DirectShow\MediaObjects` and `MediaFoundation\Transforms` category entries,
  and the `Wow6432Node` mirrors of both. **The registration was never the gap —
  the binary and its unix side were.**

  **The unix side** is `build/ntdll-unix/winegstreamer_unixlib_ios.c`, bound by
  name in `virtual_ios.c`'s `load_builtin_unixlib()` like every other
  statically-linked unixlib on this port, and backed by a minimal static FFmpeg
  7.1.1 (`.xtool/build-ffmpeg.sh`; `--disable-everything` plus
  `wmav1,wmav2,wmapro,wmalossless,xma1,xma2`, `--disable-gpl --disable-nonfree`,
  LGPL-2.1+, recorded in `THIRD-PARTY-NOTICES.md`; the tarball is fetched at
  build time and checked against a sha256 pinned in the script, never
  committed; 620 KiB + 872 KiB + 120 KiB of archives, of which only the reached
  objects are linked). It implements the `wg_transform` subset `wma_decoder.c`
  uses — create/destroy/push_data/read_data/get_output_type/set_output_type/
  drain/flush/get_status, with `notify_qos` a no-op and `wg_init_gstreamer` a
  benign success so `main.c`'s `init_gstreamer_proc` lets the DLL load. Details
  that are load-bearing:

  * **Refusal is a feature.** `wg_transform_create` returns
    `STATUS_NOT_SUPPORTED` for anything that is not a WMA-family
    `WAVEFORMATEX`, and for a rate change. winegstreamer also hosts the aac,
    h264, wmv, resampler and colour-converter transforms, and a transform that
    accepts an H.264 stream and then emits nothing is worse for its caller than
    one that never opened (§7.4 rule 4: no fake success). The rate check exists
    because resampling is `CLSID_wg_resampler`'s job, and silently doing it here
    would turn a negotiation bug into a pitch bug.
  * **Packetisation.** Every WMA decoder in libavcodec wants one packet of
    exactly `block_align` bytes; a pushed sample is one or more of those
    (FAudio submits whole xWMA blocks), so the bytes are staged and split here,
    and a trailing partial packet waits for the next push rather than being
    decoded short. libswresample converts sample format and channel layout
    only.
  * **The wow64 table is real, not the stub.** A 32-bit title is the entire
    reason this exists. `dlls/winegstreamer/unixlib.h` carries no 32-bit param
    structs (nothing upstream enters that unixlib from the other bitness), so
    they are written out in this file the way `nsi_unixlib_ios.c` writes
    `struct nsi_enumerate_all_ex32`. Three shapes differ, and were verified by
    compiling the same declarations for i686-windows and for the host:
    `struct wg_media_type`'s union is a POINTER, so the struct is 24 bytes with
    the format at +20 instead of 32 bytes with it at +24 (and
    `wg_transform_create_params` is 80 bytes with `output_type` at +32, not 96
    with it at +40); `..._push/read_data_params` puts `result` at +12, not +16.
    `struct wg_sample` is **identical** in both builds — every member is
    fixed-width and i386 aligns `INT64`/`UINT64` to 8 exactly as the host does —
    so it is used in place and only its `data` member, which holds a GUEST
    address, goes through `ios_wow_host_ptr()`. The entries that take a bare
    `wg_transform_t` or a block of same-offset scalars (destroy, drain, flush,
    get_status, notify_qos, init) share the 64-bit entry rather than getting a
    field-copying thunk that is a second place for the layout to drift.

  **The test.** `build/x86-tests/wma-x86.c` → `wma-x86.exe` (i386, no CRT,
  `build/x86-tests/build-wma-test.sh`, launch button below the live view). It
  walks FAudio's chain exactly: `CoCreateInstance(CLSID_CWMADecMediaObject,
  IID_IMFTransform)`, a WMA V2 input type (44100 Hz stereo, `block_align` 743,
  the 10 codec-private bytes in `MF_MT_USER_DATA`), a 16-bit PCM output type,
  one `ProcessInput` of 11 real WMA packets and `ProcessOutput` until dry. The
  embedded vector is 0.5 s of a 440 Hz sine at half full scale, encoded by a
  host FFmpeg 7.1.1 `wmav2` encoder; the same packets decoded through this
  file's exact code path on the host give 18432 samples/channel, peak 16488 and
  a 442 Hz fundamental. **The test asserts the frequency, not just
  non-silence**, because passing the compressed bytes through is loud too —
  silence was never the symptom. Exit 62 pass, 63 created but decode failed, 64
  class not registered (what the port did before this), 65 watchdog.

  **What the next device log should show.** No
  `[dll-missing] …winegstreamer.dll`, no `com_get_class_object` for
  `{5b4d4e54-…}` and no `CoCreateInstanceEx … 0x80070005` for `{2eeb4adf-…}`;
  a `[unixlib] winegstreamer (wma via libavcodec) (module …) -> wow64 table (…)`
  line when the DLL loads; one
  `[wma] decoder created fmt=wmav2 tag=0x161 44100Hz 2ch block=… extradata=… ->
  pcm float32 44100Hz 2ch 32bit` per voice; and — the measurement that matters —
  the audio census reporting `peak=` values at or below about 1.0 where s79
  reported 7.991, with the bus limiter's gain sitting at 1.0 instead of riding
  18 dB down.

- 2026-09-19 — **The WMA decoder's first device run, and the bit rate xWMA
  lies about.** Log u87: the chain works — `[unixlib] winegstreamer (wma via
  libavcodec) … -> wow64 table`, no `dll-missing`, no
  `com_get_class_object` — and two decoders are created:

      [wma] decoder created fmt=wmav2 tag=0x161 44100Hz 1ch block=139  extradata=10 …
      [wma] decoder created fmt=wmav2 tag=0x161 22050Hz 2ch block=1487 extradata=16 …
      [wma] avcodec_send_packet failed (-1), dropping 1487 bytes        ×4762

  The second one failed **every** packet, and the audio census still read
  `peak=65535.999`. Two defects, and the first is entirely about where those
  two streams' codec-private data comes from.

  **`extradata=10` is real; `extradata=16` is invented.** Ten bytes is an ASF
  WMA v2 codec-private blob — `{DWORD samples_per_block; WORD encode_options;
  DWORD super_block_align}` — and libavcodec reads
  `flags2 = AV_RL16(extradata + 4)` out of it (`wmadec.c wma_decode_init`).
  Sixteen bytes is not codec data at all: an xWMA RIFF's `fmt ` chunk is a
  plain WAVEFORMATEX with no tail, so FAudio has none to pass on and
  `FAudio_WMADEC_init` invents one —
  `static const uint8_t fake_codec_data[16] = {0,0,0,0,31,0,…}`
  (`wine/libs/faudio/src/FAudio_platform_win32_wmadec.c:249`). **That 31 is
  correct**, and independently so: FFmpeg's own xWMA demuxer writes the
  identical shape, six bytes with `[4] = 31`, under the comment "setup
  extradata with our experimentally obtained value"
  (`libavformat/xwma.c`). flags2 = 31 is exp-VLC + bit reservoir + variable
  block length, which is also why `block_align` is 1487 and not a couple of
  hundred bytes: with a bit reservoir a packet is a SUPERFRAME of several
  1024-sample frames. So the flags were never the problem.

  **The bit rate was**, and FFmpeg says so in as many words directly above the
  fixup this port now mirrors: *"XWMA encoder only allows a few channel/sample
  rate/bitrate combinations, but some create identical files with fake bitrate
  … Decoder needs correct bitrate to work, so it's normalized here."* 22050 Hz
  **stereo** is one of the listed rows (→ 32000). The bit rate is not cosmetic
  to libavcodec: `ff_wma_init` (`libavcodec/wma.c`) derives `bps` from it and
  then picks the coefficient VLC table (`:335-343`), the high band start
  (`:149-181`), whether noise coding is on (`:111`) and — decisively for a
  bit-reservoir stream — `byte_offset_bits` (`:141`), which is how many bits of
  the **superframe header** hold the first frame's offset. Get that wrong and
  every superframe is misparsed and `wma_decode_superframe` falls out of its
  `fail:` label, whose statement is a bare `return -1` (`wmadec.c:992`). The
  log's `(-1)` is that line and no other error path in the decoder — every
  other one returns an `AVERROR` tag.

  **It is a retry, not a table lookup, and that distinction is the point.**
  xwma.c's table is now in `winegstreamer_unixlib_ios.c`
  (`xwma_true_bit_rate`), but only as a CANDIDATE, because a table cannot be
  trusted from this side: the same entry point also serves honest ASF WMA v2 —
  that is the 44100 Hz stream that already worked — and "1ch 44100 Hz at
  96 kbps" is both a row in that table and a perfectly ordinary real file.
  Normalising unconditionally would have broken a working stream to fix a
  broken one. So the decoder opens at the rate the media type reported, and
  only if a packet fails **before any output has been produced** is it reopened
  once at the normalised rate and the same packet retried. That cannot touch a
  stream that already decodes, costs one reopen on one that does not, and logs
  which rate won — so the next log states it rather than leaving it to be
  inferred. The creation line now also carries `avg=`, `bitrate=` and
  `flags2=`, the three numbers whose absence made u87 take a source read
  instead of a glance.

  **A host reproduction is only partial, and saying so matters.** FFmpeg's own
  wmav2 ENCODER emits flags2 = 0x0001 — no bit reservoir, one frame per packet
  — so it cannot produce a superframe stream to reproduce the device failure
  exactly. What the host run does establish: that stream decoded with FAudio's
  16-byte blob fails all 22 packets at every bit rate tried (flags mismatch,
  as expected), and decodes cleanly with its own 10-byte blob. The bit-rate
  sensitivity is read from libavcodec's source and from FFmpeg's own xWMA
  fixup, not measured here, and the on-device retry is what will confirm it.

  **Defect 2: a dropped packet is not silence.** FAudio's decode loop
  (`FAudio_INTERNAL_DecodeWMAMF`) walks a voice with two independent cursors —
  `samples_pos`, which advances by what the VOICE consumed, and `output_pos`,
  by what the DECODER produced — and copies `output_buf + samples_pos`. That
  buffer is sized from the xWMA **dpds** table, the byte count the stream
  *promises*, and allocated with `pRealloc`, which does not zero. A decoder
  that returns fewer bytes than promised therefore leaves the tail of it
  holding whatever was in the heap, and a voice whose cursor has run past
  `output_pos` reads exactly that. So a packet that fails now emits SILENCE of
  the length it represented — the frame count of the last packet that did
  decode, or failing that its share of `nAvgBytesPerSec` — instead of nothing
  at all. The decoder's byte budget keeps matching the container's and the
  failure is inaudible rather than being someone else's uninitialised memory.
  The per-packet line is capped at 8 per decoder (u87 spent 4,762 identical
  lines, which is a way to lose a device log) with a one-line summary at flush
  and destroy.

  **The test grew two stages** (`build/x86-tests/wma-x86.c`, exit codes
  unchanged): B is 22050 Hz stereo at a low bit rate — the geometry of the
  stream that failed — and C is the same bytes declared with the 48 kbit/s
  figure xwma.c lists as a lie for that combination, which must still decode.

  **What the next log should show.** The creation line for the 22050 Hz stereo
  stream carrying its real `avg=`/`bitrate=`, then either no failures at all
  or a single `no packet decoded at N bit/s … retrying at 32000 bit/s` followed
  by `bit rate 32000 bit/s accepted; decoding resumed` — and at most eight
  failure lines in the whole log whatever happens. The census peak should come
  down off 65535.999; if it does not, the remaining garbage is not this
  decoder, because a failed packet can now only contribute zeroes.

- 2026-09-19 — **The 32-bit farm's `d3d11.dll` / `dxgi.dll` / `d3d10core.dll`
  are now DXMT's, not wined3d's.** A 2012-era 32-bit title got as far as
  loading `dxgi.dll`, `d3dcompiler_39` and `d3d11.dll` (log u93, lines
  ~1911-1919) and then died on a NULL read in its own code. The reason was one
  line of policy, not a bug: `.xtool/build-wine-i386.sh` built those three
  from stock Wine *on purpose*, purely so `d3dx10_43 -> d3d10_1 -> d3d10core +
  dxgi` closed. They are wined3d frontends, and **wined3d has no backend in
  this port at all** — no OpenGL, and the tree is configured
  `--without-vulkan` — so `D3D11CreateDevice` and `CreateDXGIFactory` could
  only ever hand back failure. The title was reading the NULL it had been
  given. The 64-bit farm has shipped DXMT's Metal-backed builds since the
  start; the 32-bit farm now does too.

  **Build.** `build/dxmt-ios/build-pe.sh` already compiled all three for i386
  (the meson tree has known about `cpu_family == 'x86'` since §7.6); what it
  did not do was install them, because §7's hand-off note said their 32-bit
  unix-call dispatch was still open. It is not — it is the same winemetal
  wow64 table the D3D9 path uses, audited below — so they joined the default
  install set (`build-pe.sh:65-66`), release buildtype like the d3d9 module.
  Stripped i386 sizes: **`d3d11.dll` 3,190,784**, **`dxgi.dll` 1,097,728**,
  **`d3d10core.dll` 872,448** (Wine's were 704,512 / 409,600 / 53,248 — the
  ratio is the whole Metal backend plus airconv). DXMT ships no `d3d10.dll` /
  `d3d10_1.dll`; Wine's stay, and their entire import surface is
  `D3D10CoreCreateDevice` + `CreateDXGIFactory`, both of which DXMT's modules
  export, so the closure that motivated the old policy still holds — it is now
  satisfied by modules that can actually create a device. `d3d12.dll`'s
  `CreateDXGIFactory2` resolves too. `wined3d.dll` itself stays in the farm:
  `d3d8` and `ddraw` still import it.

  **Keeping Wine's out.** Three guards, all in `.xtool/build-wine-i386.sh`,
  because the farm script has three independent paths that could re-create
  them: `EXCLUDE` (`:82-87`, the name phase, seeded from the aarch64 farm's
  listing), `NEVER_OVERWRITE` (`:81`, checked again in the breadth phase at
  `:542` and a third time at install at `:640`), and a `SKIP_BREADTH_REASON`
  entry (`:519`) so the run's policy-skip report says *why* rather than the
  three modules just silently not appearing.

  **The thunk audit, and what it found.** The 32-bit winemetal table
  (`winemetal_unix.c:5281-5441`) turned out to need **no new entries**. All
  151 slots are populated (127-144 are the reference tree's reserved NULLs,
  which nothing in this tree can call — `wmt_api_names.h` prints them as
  `<null slot>`), and the 13 slots the d3d11/dxgi path uses that the d3d9 path
  never touched — 92 `CGColorSpace_checkColorSpaceSupported`, 94/95
  `WMTGet{Primary,Secondary}DisplayId`, 96 `WMTGetDisplayDescription`, 97
  `MetalLayer_getEDRValue`, 101 `WMTQueryDisplaySettingForLayer`, 104
  `MTLSharedEvent_setWin32EventAtValue`, 108-110 `SharedEventListener_*`, 111
  `WMTGetOSVersion`, 121/122 `WMTBootstrap{Register,LookUp}` — either already
  have a `*32` variant (96, 97, 101) or carry no embedded pointer at all and
  correctly share the 64-bit handler (`unixcall_bootstrap` holds its name in a
  `char name[128]` inline array; `unixcall_get_os_version` is three
  `uint64_t`; slot 104's `event_handle` is an NT HANDLE in a 64-bit field,
  which zero-extends). The three command-chain thunks (36/37/38, §7.7 risk 6)
  were re-checked against every `wmtcmd_*` struct rather than against the d3d9
  call sites: exactly four carry a CPU payload pointer —
  `wmtcmd_render_setbytes`, `wmtcmd_render_setviewports`,
  `wmtcmd_render_setscissorrects`, `wmtcmd_compute_setbytes` — and
  `wow_cmd_payload()` (`winemetal_unix.c:4659-4686`) handles all four. d3d11 is
  the first caller to use the COMPUTE chain at all; its one payload command was
  already there. The SM50 (DXBC) thunks are likewise the first thing d3d11
  exercises that d3d9 did not — d3d9 goes through DXSO — and
  `sm50_compilation_argument32_convert()` covers all seven argument types, with
  `MTL_SHADER_REFLECTION` and `MTL_SM50_SHADER_ARGUMENT` both pointer-free.

  **The one real gap was on the DXMT side, not in the table.**
  `_MTLDevice_newBuffer32` refuses a CPU-visible buffer whose `memory.ptr` is
  NULL, because the handler would then write `[buffer contents]` — a pointer
  in Metal's own heap, outside the guest window — into a field a 32-bit caller
  reads (§7.5). Stage 4 fixed every d3d9 allocation site for this;
  `StagingBufferBlockAllocator` has a `placed_buffer` flag, and **three rings
  pass it false**, all of them on the d3d11 path and all of them
  `WMTResourceStorageModeManaged`, which `DXMT_IOS` remaps to **Shared**:
  `CommandQueue::staging_allocator` (`dxmt_command_queue.cpp:25-28`),
  `MTLD3D11CommandList::staging_allocator`
  (`d3d11_context_impl.cpp:5351-5353`) and
  `ResourceInitializer::gpu_command_heap_allocator`
  (`dxmt_resource_initializer.cpp:50-52`). d3d9 sidestepped all three with its
  own rings and said so (`d3d9_device.hpp:1597`, `d3d9_device.cpp:10799`); on
  i386 they would each have got `STATUS_INVALID_ADDRESS` and, under the
  release build's quiet `UNIX_CALL`, a **NULL `MTLBuffer` with no assertion**.
  Private storage is not an alternative either: these blocks are filled by
  `MTLBuffer_updateContents`, which memcpys into `[buffer contents]`, and that
  is NULL for a Private buffer. So `StagingBufferBlockAllocator::allocate`
  now forces the placed backing on `__i386__ && !DXMT_MADEIRA`
  (`dxmt_ring_bump_allocator.hpp:209-236`), exactly as `Buffer::allocate`
  (`dxmt_buffer.cpp:171-190`) and `Texture::allocate`
  (`dxmt_texture.cpp:186-188`) already do. Nothing reads `mapped_address` on
  those three rings, so the only cost is guest VA — which is why
  `kStagingBlockSize` is already 8 MB on i386 instead of 32 MB. Every other
  `newBuffer` call site was re-checked and was already correct:
  `dummy_cbuffer_` supplies memory unconditionally, the occlusion-query
  readback heap has its own `#ifdef __i386__`, `zero_buffer_` and
  `copy_temp_allocator` are Private, and `Buffer::allocate` forces `CpuPlaced`.

  **Mapped memory reaching the app.** Every `pMappedResource->pData` d3d11
  hands out (`d3d11_context_imm.cpp:169-258`, `d3d11_context_def.cpp:175-257`)
  comes from a `BufferAllocation`/`TextureAllocation` `mappedMemory`, and on
  i386 those are this PE module's own heap — so they go through the
  `allocate_virtual_memory` window chokepoint by construction and the 32-bit
  process can dereference them. That was already true before this change
  (`d3d11_buffer.cpp:92`, `d3d11_texture_dynamic.cpp:125`,
  `dxmt_staging.cpp:80`); the test below is what turns "already true" into
  "measured".

  **DXGI vs the virtual monitor.** On i386 `src/util/meson.build`'s `else` arm
  selects `wsi_monitor_win32.cpp` + `wsi_window_win32.cpp`, so output and mode
  enumeration go out through user32 to the port's virtual monitor — the same
  path `d3d9modes-x86.exe` already validates. `DXMT_IOS` is keyed on
  `host_machine.system() == 'windows'` (§7.8) and therefore *is* defined for
  i386, so `d3d11_swapchain.cpp:765-780` still forces visible/foregrounded and
  never takes the fullscreen-exit branch.

  **Test:** `build/x86-tests/d3d11-x86.c`, built by `build-d3d11-test.sh`
  into **`d3d11-x86.exe`** (i386, no CRT, no dxguid; imports are exactly
  `kernel32`/`user32`/`d3d11`/`dxgi`, asserted by the script, which also
  refuses to run if the installed `d3d11.dll`/`dxgi.dll`/`d3d10core.dll` still
  import `wined3d.dll`). It creates a 640x480 window, calls `CreateDXGIFactory`
  directly and logs every adapter, then `D3D11CreateDeviceAndSwapChain`
  (HARDWARE, feature levels 11_0/10_1/10_0, accepting >= 10_0), logs the
  containing output's desktop rect and the first eight display modes, exercises
  `ResizeTarget(640x480)` and `SetFullscreenState` both ways, creates a DYNAMIC
  vertex buffer and `Map`s it `WRITE_DISCARD`, clears the RTV to
  B=192 G=128 R=64 and `Present`s 30 frames, then reads the centre pixel back
  through a STAGING texture `Map(READ)`. Exit **66** = pass, **67** = device
  creation failed (HRESULT printed), **68** = a mapped pointer the 32-bit
  process cannot reach, **69** = readback mismatch; 60-65 name the earlier
  setup step that failed. The 68 check is the interesting one: inside a 32-bit
  process every pointer is 32 bits wide, so a truncated host address cannot
  show up as a large value — it shows up as a pointer naming nothing. The test
  therefore asks **`VirtualQuery`** whether the span is `MEM_COMMIT`,
  unguarded, writable and wholly inside one region, logs the region's base,
  size, state and protection either way, and only then writes a pattern and
  reads it back. A launch button ("D3D11 test", `ContentView.swift:3204-3208`)
  sits below the live view; it can also be run from the Custom popup as
  `C:\windows\syswow64\d3d11-x86.exe`.

  **What the next device log should show.** `MADEIRA-D3D11: CreateDXGIFactory
  hr=0x00000000` with at least one `adapter 0 vendor=... device=... vram_mb=...
  name=...` line (a vendor or device id of 0 is what a period title reads as
  "no adapter"), then `D3D11CreateDeviceAndSwapChain hr=0x00000000` and
  `feature level hr=0x0000b000` (11_0). `GetContainingOutput` and
  `GetDisplayModeList` must agree with the virtual monitor — the output rect
  and the mode list should match what `d3d9modes-x86.exe` prints, and a mode
  count of 0 means the user32 path is not seeing the monitor. `mapped pData`
  should be a plain low address with `region state 0x00001000` (MEM_COMMIT)
  and a read/write protection, followed by `dynamic buffer
  map/write/readback/unmap OK`. Then 30 `present` lines at `hr=0x00000000`,
  `staging RowPitch` at 2560 or more, and `pixel B=192 G=128 R=64 A=255`
  before `PASS` / `MADEIRA-EXIT: d3d11-x86.exe status=66`. On the unix side
  there must be **no** `winemetal: MTLDevice_newBuffer from a 32-bit caller
  with no caller-supplied memory` line at all — one of those means another
  allocation site was missed, and it names the length and options so the site
  can be identified.
- 2026-09-19 — Logs v95 (open-world 32-bit D3D9 title, gameplay) + u92 (UE3).
  Two measured costs removed, and the audio question answered: **FAudio's SSE2
  mixers are not in the i386 binary at all**, so no CPUID check can reach them.
  First, two round-3 changes confirmed in the field: `[prof] jit by module` now
  reads `xaudio2_2.dll=23-27%` instead of `Zx`, and `[fex-cfg] FEAT_LRCPC2=1 ->
  ... NOT auto-enabled` is in the log.
  (1) THE CENSUS WAS COSTING TWO EMULATED LOCKED RMWs PER D3D9 CALL.
  `[d3d9-census]` measures **10,548 calls per frame** in this title
  (`calls: per_frame=10547.9`), and `D3D9_CENSUS` paid `g_calls[code]
  .fetch_add` plus `ringCall`'s head bump on every one of them. In i386 under
  FEX a `lock xadd` is not one instruction, it is a TSO read-modify-write the
  JIT lowers to an exclusive-monitor sequence — and this is inside the DLL
  `[prof]` puts at **13-20 % of all CPU**. Neither atomic bought anything: each
  counter is a monotone tally whose only reader is the 5-second summary.
  The counters are now per thread (`d3d9_census.hpp:41-92` — `ThreadCounters`,
  a `thread_local` block pointer, allocated and linked on a thread's first D3D9
  call and never freed so a dead thread keeps contributing; summed by
  `callCount()` at report time, `d3d9_census.cpp:59-76`, used at :212). The
  counters stay `std::atomic` so the summing read and the counting write are a
  well-defined relaxed pair rather than a data race, but the write is a
  load/add/store, NOT `fetch_add` — on x86 three plain instructions with no lock
  prefix. Only the owning thread writes its own block, so the non-atomic RMW
  cannot lose a count.
  The `[d3d9-last]` ring is now opt-in, `MADEIRA_D3D9_LAST=1`
  (`d3d9_census.hpp:95-104`, `d3d9_census.cpp:358-399`). It is forensics, not a
  measurement: nothing in any report reads it and it only prints after the
  process is already dying. When it is off the vectored exception handler is not
  installed either, so a guest fault no longer walks through it, and
  `dumpLastCalls` prints "ring disabled" with the knob name rather than an empty
  ring (`d3d9_census.cpp:526-534`) — an empty ring reads as "D3D9 was never
  called" and has sent a reader the wrong way before.
  Net: ~21,000 emulated locked RMWs per frame become ~10,500 TLS-load-plus-
  increment pairs. Every census number is unchanged.
  (2) TWO SERVER ROUND TRIPS PER WINDOW MESSAGE, GONE. `focusWindowProc` opened
  every message with `GetPropW(kFocusProcProp)` + `GetPropW(kFocusDeviceProp)`,
  and a window property lives in the wineserver here: `[srv-stats]` puts
  `get_window_property: NtUserGetProp+0x7c` at 858-2646 per 10 s at 42-54 us,
  the third largest request kind in the process, purely to re-read two values
  this DLL set itself. Now an 8-slot process-local HWND table
  (`d3d9shim_window.c:56-122`), read at :404-408, written at :499, invalidated
  at :417 (WM_NCDESTROY), :526 (unhook, dropped BEFORE the proc reads it again
  so a dangling device pointer is impossible) and re-seeded at :545 when the app
  has re-subclassed on top of us and the property must stay. The properties are
  kept as the cross-DLL contract and as the miss path, so behaviour is identical
  in every case — the cache can only make it faster, never different.
  (3) MEASURED, NOT CHANGED.
  **Cursor caching: declined, with the number.** `set_cursor` is 572-1746 per
  10 s at 37-46 us = **2.5-8 ms per 10 s, 0.03-0.08 % of one core**. Against
  that: `NtUserShowCursor` has no unchanged case at all — every call moves a
  desktop-GLOBAL count by +/-1 and returns it, and apps spin on that return
  value (`while (ShowCursor(FALSE) >= 0)`), so a per-process cache is wrong the
  moment anything else touches it. `NtUserClipCursor`'s clip is likewise
  desktop-global and the server drops it on foreground changes that originate
  outside this process, so a stale "identical rect, skip the call" is a mouse
  that escapes the window in a first-person title. Wrong trade for 0.05 % of a
  core; the round trips stay.
  **memcpy/memset under TSO: FEX is already right, the guest CRT is not.**
  `[fex-cfg]` confirms `MemcpySetTSOEnabled=0` (with `TSOEnabled=1
  HalfBarrierTSOEnabled=1 VectorTSOEnabled=0`), and that flag is exactly what
  makes `CPUID.cpp:663` advertise ERMS to the guest and `MemoryOps.cpp:2127,
  :2371` take the non-atomic bulk path — so FEX's REP MOVS fast path IS active
  in 32-bit mode. The guest never asks for it: v95's hot ucrtbase block
  (`ucrtbase.dll+0x5c9cc`, 182 guest insts, **vec=0**, mem=73, tso=20, 1.8 % of
  all CPU) is a scalar word loop, neither `rep movsb` nor SSE. Making Wine's
  i386 CRT issue the string op FEX is waiting for is a CRT-source change with
  `memmove` overlap semantics attached, in someone else's tree; left alone.
  **The JIT is warm and is not a steady-state cost.** `blocks` 25040 -> 25943 at
  **2-37 blocks/s** across gameplay windows, `hit_rate` 92-93 %, `insts/blk=87`.
  Nothing to fix. (`cpp_dispatch` is still quantised to 16384, so its per-second
  rate remains an artefact of the counter.)
  **Server, ranked** (busiest v95 window, total `in-call` only 0.05-0.09 core):
  select 5881, event_op 4694 (fastsync stays OFF as instructed),
  get_window_property 2646 (item 2 above), set_cursor 1746,
  get_window_rectangles 1335, get_async_result 977 + ioctl 977, release_mutex
  898. The `get_async_result`+`ioctl` pair is **977-979 per 10 s in every window
  of every log and both titles** — a fixed ~97.8/s, i.e. a ~10.2 ms periodic
  overlapped-IRP poll in our own infrastructure, not per-frame work, 0.7 % of a
  core. u92 has a different shape worth someone's attention: `event_op=19537`
  per 10 s (5.9 % of a core), and `set_hook=898` + `remove_hook=898` per 10 s —
  a hook installed and removed **90 times a second**, 1796 round trips/s.
  LOADING-PHASE bursts are a different population again and neither of the two
  fixes above touches them: v95:2896 has `add_fd_completion=103180` in one 10 s
  window (10.3 k/s at 18 us = **1.9 % of a core**, overlapped file I/O
  completion during streaming) and v95:2414 has `release_mutex:
  NtReleaseMutant+0xec=3147` at 38 us (1.2 % of a core) alongside
  `create_file=478/549us`. Both are worth a look by whoever owns the streaming
  and file paths; they do not appear in the steady-state gameplay windows.
  (4) AUDIO: THE SSE2 MIXERS ARE NOT IN THE BINARY, SO CPUID IS NOT THE GATE.
  `FAudio_internal_simd.c:38-75` only defines `__SSE2__` for x86_64 and macOS;
  a 32-bit x86 build falls to the `#else` with `NEED_SCALAR_CONVERTER_FALLBACKS
  1`, so `HAVE_SSE2_INTRINSICS` is 0, the entire SSE2 section is preprocessed
  away, and `FAudio_INTERNAL_InitSIMDFunctions` takes the scalar fallbacks
  **whatever `IsProcessorFeaturePresent` returns**. `wine/libs/faudio/
  Makefile.in` passes no `-msse2`. The profile agrees: the two hot blocks
  (`xaudio2_2.dll+0x19080`, `+0x1a5b0`) are scalar-double — `cvtsi2sd`, a
  `movsd` of a constant from the same image at +0x2fe68 — with only 12-16 vector
  ops in ~100 guest instructions, which is not what a packed-single mixer looks
  like.
  The runtime gate would pass if the code existed: `ntdll/unix/system.c:727`
  sets `PF_XMMI64_INSTRUCTIONS_AVAILABLE = TRUE` whenever I386 is in
  `supported_machines`, which it is. **So `-msse2` on the faudio i386 build is
  the whole fix**, and it is one line in `wine/libs/faudio/Makefile.in`. NOT
  done here: `wine/libs/faudio` is another agent's this round.
  **The device graph is stereo** — `[audio] get_mix_format
  fmt=tag65534/2ch/48000Hz/32bit/align8 share=shared -> 0x00000000` and
  `[audio] stream 0: fmt=f32/2ch/48000Hz/32bit(valid 32)/mask0x3`. No 6-channel
  mastering voice; that question is closed.
  **Two observations to hand on.** `[audio] stream 0: ... peak=0.000` for the
  whole run while `FAudio_AudioClientThread` sits at **28.1 % of all CPU (jit
  99 %)** — either the peak meter is unwired or the mixer is spending a quarter
  of the machine producing silence, and those need different fixes.
  `[d3d9-query] worst_ever=35760929us` (35.8 s) against
  `issue_to_complete_avg=33945us` and `polls_per_completion=2.1`: steady state
  is healthy, so this is one outlier, most likely a load screen, but it is the
  same shape as the stranded query ml998 fixed and deserves a second look if it
  recurs.
  **What to look for in the next log:** `d3d9-emulated.dll` down from 13-20 % of
  all CPU by roughly the share the two locked RMWs were taking, with
  `[d3d9-census] per_frame` UNCHANGED at ~10,548 and every top-20 count
  unchanged (if a count moves, the per-thread summing is wrong, not the
  workload); `[srv-stats] get_window_property` falling out of the top four in
  the open-world title; `[d3d9-last]` appearing only as "ring disabled" unless
  someone sets `MADEIRA_D3D9_LAST=1`. Unchanged on purpose: `blocks`,
  `hit_rate`, `event_op`, `set_cursor`, and `xaudio2_2.dll`'s share — the audio
  fix is a build flag in another tree and nothing here touches it.

- 2026-09-19 — **An unaligned x86 atomic was delivered to the guest as an
  access violation, because the Mach fault path never read the ESR.** Log v96,
  a 2012-era 32-bit D3D9 title: the device is created, loading starts, and the
  process freezes with 13 parked waiters behind one guest critical section that
  is never released. One instruction did it —
  `BUS #1: pc=0x138181c94 addr=0x710553e32e insn=0xb8fa8304`, i.e. `swpal
  w26,w4,[x24]`, the JIT's translation of a guest `xchg [mem],reg`, on a DWORD
  at **2 mod 4**. x86 allows that; ARM64 LSE atomics do not, and FEX exists to
  catch the alignment fault and finish the access by hand. The `[bus-rgn]`
  probe already proved the memory was innocent (`prot=3`, anonymous, resident,
  page materialises), so nothing about the page was ever the problem.

  **The two delivery paths disagreed about the same fault, four lines apart.**
  This is the whole defect, and the log states it outright:

  ```
  bus_handler  [unaligned-guest] REFUSED-OTHER insn=0xb8fa8304 ... keeping 80000002
  [exc-disp]   raise tid=003c code=80000002
  D 3C         Handled unaligned atomic: new pc: 138181C98      <- FEX fixed it
  [mach-deliver] rev=ml369 #0 code=c0000005 pc=0x138181c94      <- same fault, AV
  D 3C         Reconstructing context
  D 3C         pc: 138181C94 eip: 2E3733C0                      <- into the guest
  ```

  So the answers to the three questions this was opened with are: (1) the
  signal path is **correct** — `bus_handler` reads `get_fault_esr`, keeps
  `EXCEPTION_DATATYPE_MISALIGNMENT`, and FEX's WOW64 hook
  (`FEX/Source/Windows/WOW64/Module.cpp:1758` -> `:643` ->
  `FEXCore/Source/Utils/ArchHelpers/Arm64.cpp`) resumes the **host** context at
  `pc+4`, exactly as designed; (2) `HandleUnalignedAccess` **does** handle the
  LSE `ATOMIC_MEM` class (`Arm64.cpp:2286` -> `HandleAtomicMemOp`, whose
  `DoCAS32`/`DoLoad32` helpers are themselves alignment-aware), for size=2 SWP
  with Rs != Rt and for the single-register addressing our 32-bit window uses;
  and (3) **no back-patch is involved**, so code-buffer writability never came
  into it. Everything on the FEX side worked.

  **What did not work was `ios_mach_deliver_guest_exception_inner`**
  (`build/ntdll-unix/signal_arm64_ios.c`). It set
  `rec.ExceptionCode = EXCEPTION_ACCESS_VIOLATION` for **every**
  `EXC_BAD_ACCESS` and only ever consulted the ESR to pick read/write/execute —
  the DFSC field that says "alignment fault" (`ISS[5:0] == 0b100001`, plainly
  visible in the same log as `esr=0x92000021`) was never examined. Which path a
  given fault took was then decided by the transient-retry debounce: faults #1
  and #2 declined to the BSD signal path and were fixed; the **third** was
  dispatched from the Mach path as `c0000005` at guest `eip 2E3733C0`, the
  thread unwound out of the locked region still holding the lock, and every
  later waiter parked forever.

  Why a third fault existed at all is the second half of the story, and it is
  not a bug: **FEX cannot back-patch an LSE atomic** — no single ARM64
  instruction has SWP's semantics — so `HandleAtomicMemOp` emulates and returns
  "skip 4" without rewriting the site. A guest spin-acquire therefore re-faults
  at the *same* host pc on *every* iteration. That is correct and only slow; it
  is also guaranteed to reach any rule that assumes a repeated fault is a
  pathology.

  **Fix.** `signal_arm64_ios.c`, in the Mach delivery path: classify
  `EC 0x24/0x25 && DFSC 0x21` as an alignment fault and treat it as serviceable
  rather than fatal. Plain loads/stores are emulated in place by the **same**
  `ios_emulate_unaligned_guest_access` the signal path uses (forward declared
  for it; it touches only GPRs, refuses SIMD, uses byte-wise copies and no wine
  log macros, so it is safe on the exception-server thread); everything else —
  LSE atomics, CAS/CASP, load/store-exclusive pairs, LDAPR/STLR — is dispatched
  as `STATUS_DATATYPE_MISALIGNMENT` so FEX's machinery gets the same shot it
  gets from `bus_handler`. Three consequences had to be handled with it:
  `ios_virtual_handle_fault_for_thread` is skipped (it ends with
  `rec->ExceptionCode = ret` and would put `c0000005` straight back); the
  `[av-detail]` discriminator does not fire (an alignment fault is not an AV and
  must not drain that budget); and both the transient-retry debounce and the
  **`[redeliv]` 2000-identical-redeliveries terminal** exempt alignment faults —
  its premise, that nothing legitimate redelivers the same `(thread,pc,addr)`
  thousands of times, stops holding the moment a spin-acquire on a misaligned
  word starts being serviced from here, and killing the pseudo-process for
  making progress would have been a worse bug than the one being fixed.
  Alignment faults still pass the guest-pc gate, so a host-side one is declined
  as before.

  **Census, because the cost is now the thing to watch.**
  `FEXCore/Source/Utils/ArchHelpers/Arm64.cpp` gained a thin wrapper around
  `HandleUnalignedAccess` — the return value alone says which happened (a byte
  count means the handler performed the access; `0`/`-4` means the site was
  rewritten and must re-run), so one wrapper covers all nine class branches
  without touching any of them. It emits `[unaligned-atomic] pc=... insn=...
  addr=... handled by emulation|patch`, deduplicated by host pc and capped at
  32 lines, and bumps `ua_emu` / `ua_patch` on the periodic `[fex-stats]` line
  (`Interface/Core/Core.cpp`), which is never capped. The Mach path prints its
  own `[unaligned-atomic] mach-path ...` line for the same reason.

  **Test.** `build/x86-tests/unaligned-x86.c` + `build-unaligned-test.sh`
  (i386, kernel32 only, no CRT), with a button below the live view. It asserts
  its own premise first (every word really is at 1, 2 or 3 mod 4 — offset 2 is
  the one the device died on), then checks `lock xadd` (including a negative
  addend), `lock cmpxchg` **taken and not taken**, `lock inc` across a carry,
  `xchg [mem],reg` and kernel32's exported `InterlockedExchange` for the exact
  value *and* the exact return value at all three offsets; then runs two threads
  x 1,000,000 iterations each of `lock xadd`, `lock inc` and a `lock cmpxchg`
  CAS loop, requiring exactly 2,000,000 — a short count is a lost update, which
  is the failure mode that turns a guest reference count into a use-after-free
  rather than a hang. The last phase is the device's own shape: a **misaligned
  `xchg` spinlock** guarding an ordinary non-atomic counter, which fails on a
  short count *and* on timeout, because "wedged" is the symptom under
  investigation. The build script disassembles the image and asserts the four
  mnemonics and the lock prefixes are really there, so a compiler that lowered
  `lock xadd` to a CAS loop cannot make the test pass while exercising nothing.
  Exit 70 = pass, 71 = wrong result, 72 = environment, 73 = the premise broke,
  74 = timeout. **No `MADEIRA-EXIT` line at all is the original bug** — a
  crashed run must never read as a fail-with-verdict.

  **What the next log should show.** From `unaligned-x86.exe`:
  `MADEIRA-UNALIGNED: all checks passed` and `MADEIRA-EXIT:
  unaligned-x86.exe status=70`, with the per-phase `ms=` figures giving the real
  per-fault round-trip cost. From the unix side: `[unaligned-atomic]` lines
  naming a handful of sites with `handled by emulation`, `ua_emu` climbing on
  `[fex-stats]` while `ua_patch` stays small, and — the actual regression
  check — **no `[mach-deliver] ... code=c0000005` at a pc whose `[bus-rgn]`
  reports `si_code=1`**, and no `Reconstructing context` / `pc: ... eip: ...`
  pair following a `DATATYPE_MISALIGNMENT`. On the title itself the `swpal` at
  the D3D9 loading path should show up once as an `[unaligned-atomic]` site line
  and then never again in the log, with loading continuing past it.

- 2026-09-19 — **The WMA decoder's second device run: the parameters are right,
  so the next question is the bytes — and the answer was already in the log.**
  Log v95: the retry fires and still every packet of every bit-reservoir
  stream fails. Five streams, five geometries, all failing: 32000 Hz 1ch
  block=1280, 32000 Hz 2ch block=2304, 22050 Hz 2ch block=1487, 44100 Hz 1ch
  block=2230, 44100 Hz 2ch block=4459.

  **The parameters are now independently confirmed, which removes them as
  suspects.** A WMA superframe holds `nb_frames` frames of `frame_len` samples
  in `block_align` bytes, so `bit_rate = block_align * 8 * rate /
  (nb_frames * frame_len)`. Running that over the five geometries with
  `frame_len` from `ff_wma_get_frame_len_bits` and an 8- or 6-frame superframe
  gives 20000, 48000, 32000, 48000 and 96000 bit/s — **every one of them
  exactly the value libavformat/xwma.c's table normalises to.** Two independent
  derivations agreeing is as far as a parameter theory can be taken from this
  side; the rate the retry adopts is right.

  **And libavcodec had been saying so all along.** wmadec explains each of its
  failures, and those lines were in v95 — with libavcodec's own
  `[wmav2 @ 0x…]` prefix, which a grep for this port's `[wma]` tag does not
  match, so they were nearly missed. Tabulated:

      2289  nb_frames is N bits left M            (the superframe header)
      3595  next/prev/block_len_bits N out of range
      1744  overflow (N > M) in spectral RLE
       863  frame_len overflow

  `nb_frames` is bits 4..7 of the packet's **first byte**, read before any
  parameter-derived field width is used. A packet whose nb_frames nibble is
  implausible is a packet that does not START where we think it does — a
  different class of bug from every rate or flags theory, and the most common
  complaint by a wide margin. `av_log_set_callback` now routes libavcodec's
  diagnostics through the `[wma]` tag (capped at 64), so the decoder's own
  account of itself is part of the log everyone reads.

  **What the next log decides.** Two measurements, neither of which existed
  before: `[wma] push #n size=… fifo=… block=…` for the first eight pushes,
  which flags any push that is not a multiple of block_align; and
  `[wma] pkt#n … <hex> | superframe index=… nb_frames nibble=… -> implies N
  bit/s` for the first two packets, which prints the bytes themselves. If the
  nibbles are 6–8 and consistent, the framing is right and the remaining
  suspect is the codec configuration; if they are noise, the bytes are not
  superframe-aligned and no parameter will ever help. This is the measurement
  that should have been taken a round earlier instead of a second parameter
  theory.

  **Fixed outright this round.** A trailing partial packet is no longer fed to
  the decoder — `buf_size < block_align` earns a bare "Input packet size too
  small" `AVERROR_INVALIDDATA`, which is where v95's `-1094995529` came from;
  it is dropped and counted. The parameter search gained two more
  self-validating candidates beyond xwma.c's table: the rate implied by the
  packet's own nb_frames nibble, and that rate with `use_variable_block_len`
  cleared (FFmpeg does exactly this itself for `flags2 == 0xd`, "this fixes
  issue1503"). Every candidate is kept only if a packet actually decodes, and
  each transition is logged.

  **And a real out-of-bounds read on the FAudio side, which is the better
  candidate for the census's `peak=65535.999`.**
  `FAudio_INTERNAL_DecodeWMAMF` chose its branch with
  `if (wfx->Format.wFormatTag == FAUDIO_FORMAT_EXTENSIBLE) { dpds path } else
  { XMA2 path }` and then read `dwBytesPerBlock` and `dwSamplesEncoded` — both
  `FAudioXMA2WaveFormat` fields — out of the caller's format struct. For an
  xWMA voice submitted as a plain WAVEFORMATEX with tag WMAUDIO2, which
  XAudio2 allows and which `FAudio_WMADEC_init` itself handles through its
  `type` switch rather than through `wFormatTag`, that is a read **past the end
  of the caller's struct**. The results become the decoder's input chunk size
  and the size of an uninitialised `pRealloc`'d output buffer that the voice
  then indexes by its own cursor. The branch is now keyed on the format
  actually being XMA2, and both `pRealloc` sites zero their newly grown tail —
  heap garbage played as float32 is arbitrarily loud, which is exactly what a
  peak of 65535.999 looks like.

  **i386 FAudio was also built with no SIMD at all.**
  `FAudio_internal_simd.c`'s detection chain has cases for aarch64, x86_64 and
  macOS and an `#else` for "all other hardware"; i686 fell into that `#else`,
  because nothing defines `__SSE2__` for an i686 PE target (verified: clang
  `-target i686-windows -dM -E` defines neither `__SSE2__` nor `__SSE__`,
  unlike x86_64-windows). `HAVE_SSE2_INTRINSICS` was therefore never defined,
  so `FAudio_INTERNAL_InitSIMDFunctions` had no SSE2 branch compiled in and the
  runtime `IsProcessorFeaturePresent(PF_XMMI64_INSTRUCTIONS_AVAILABLE)` check
  could not select one — scalar mixing and resampling for every XAudio2 title,
  profiled at 22–27% of all CPU under translation. i686 now gets
  `HAVE_SSE2_INTRINSICS` with the scalar fallbacks **kept** and the runtime
  check **kept**, since unlike x86_64 the ISA does not guarantee SSE2 here;
  all this does is make the SSE2 half exist to be chosen. It is done with
  `__attribute__((target("sse2")))` on the seven `_SSE2` functions rather than
  `-msse2` on the file, deliberately: a file-wide flag would also let the
  compiler emit SSE2 into the scalar fallbacks, which are the paths that have
  to keep running on a CPU without it. Verified in the rebuilt library:
  `FAudio_INTERNAL_InitSIMDFunctions` now references all seven `_SSE2` entries,
  `FAudio_INTERNAL_Mix_Generic_SSE2` disassembles to
  `movups/mulps/movaps/addps` on `%xmm`, and `ResampleStereo_SSE2` carries 14
  packed ops.

  **A build-system trap worth recording.** `.xtool/build-wine-i386.sh` counts a
  target as built if the output FILE EXISTS after the bulk make. A compile
  error inside a static library the modules link — here a `*/` inside a comment
  I added to `libs/faudio`, which closed the comment early — therefore reported
  "built: 35 failed: 0" while every DLL was the previous build. It was caught
  only because the build tag was missing from all 35. Any claim that a library
  change shipped needs a check on the ARTIFACT, not on the script's exit
  status; that is what the tag is for, and `strings <module>.dll` now answers
  it (22 of 35 i386 modules carry it — the 13 that do not are x3daudio/xapofx,
  which never reference the decoder).

- 2026-09-19 — **w2: the diagnostics worked, the "fix" did not, and the honest
  output for a stream we cannot decode is silence.** The new instrumentation
  answered its question immediately: `push #0..7 size=1487 fifo=0 block=1487`,
  so phase within a push is exact, and `pkt#0 … | superframe index=15
  nb_frames nibble=8 -> implies 32019 bit/s` is a **perfectly well-formed WMA
  superframe header** — eight frames, 32 kbit/s for 22050 Hz stereo at block
  1487, which is the XACT WMA block-align table's own value. The bytes at the
  start of a push are right and the parameters implied by them are right.

  `pkt#1 … | index=3 nb_frames nibble=1 -> implies 256158 bit/s` is not the
  successor of pkt#0 — a superframe index should step 15→0 and nb_frames stay
  near 8. Two adjacent packets cut from one FIFO, the first immaculate and the
  second not its continuation. That is the whole remaining mystery, and it is
  not a parameter question, so no further parameter guessing is warranted.

  **The candidate search was making things worse, and that is the important
  lesson.** It reported `accepted: 32019 bit/s with use_variable_block_len
  cleared; decoding resumed` and was then followed by 90 failures and
  `[audio] stream 2 … peak=9.406`. One packet decoding without an error is
  **not** evidence that a configuration is right: libavcodec will happily
  "decode" under the wrong flags and emit noise at many times full scale. A
  search whose accept test is weaker than its failure mode converts a silent
  bug into a loud one. Three changes, all of which apply whatever the root
  cause turns out to be:

  * **Every converted frame is sanity-checked** before it is appended. Float
    PCM from a WMA decoder lives in [-1, 1]; a frame containing a sample
    outside ±1.25, or a NaN, is rejected and the packet is treated as a decode
    failure. This is unconditional — it is not part of the search — so no
    configuration, chosen or stock, can put +19 dB noise into the mixer again.
  * **A candidate is provisional until `MADEIRA_WMA_ACCEPT_PACKETS` (3)
    consecutive sane packets.** A relapse reopens the search rather than
    keeping a guess that worked once.
  * **A decoder that exhausts its candidates MUTES** and emits silence for
    every later packet without calling libavcodec again. Garbage at +19 dB is
    worse than no audio; a stream this port cannot decode should be inaudible,
    not audible and wrong.

  **`bits_per_coded_sample` is set again.** It was dropped two rounds ago on
  the correct observation that no WMA decoder in libavcodec reads it — but
  gst-libav sets it from the caps `depth` (`gstavcodecmap.c`) and winegstreamer
  puts the WAVEFORMATEX depth in those caps, so the desktop path that decodes
  these streams does pass it. Matching the working path exactly is worth more
  than being right about which fields it needs.

  **And the measurement that ends the argument: `MADEIRA_WMA_DUMP=1`.**
  Honoured out of `Documents/madeira-env.txt` (the generic `MADEIRA_*`
  passthrough), it writes `Documents/wma-dump-<n>.bin` per decoder: magic
  `MADWMA01`, then codec tag, sample rate, channels, block_align,
  nAvgBytesPerSec and the extradata length as u32s, the extradata verbatim,
  then the first 64 pushed packets each with a u32 length prefix. Three rounds
  have now been spent arguing about bytes nobody could look at; this puts the
  exact bitstream on the host, where it can be decoded with the same libavcodec
  and the answer read off directly. The push lines also carry the transform
  pointer and a per-transform packet counter now, and `flush`/`drain` log
  themselves, so "is one transform being fed by two voices, or seeked between
  pushes" is answerable from the same log.

  Four other differences from the desktop path were checked and are NOT the
  bug: packets are built with `av_new_packet` + memcpy (so they carry zeroed
  `AV_INPUT_BUFFER_PADDING_SIZE`) and never point into the FIFO;
  `avcodec_receive_frame` is drained to EAGAIN after every send; each
  `wg_transform_create` allocates a zeroed context and `wma_decoder.c`'s
  `try_create_wg_transform` destroys the previous transform first, so no
  `block_align`/extradata can be stale across the two `SetInputType` calls the
  log shows; and `wma_decoder.c:transform_ProcessInput` already refuses any
  sample that is not a multiple of block_align.

- 2026-09-20 — **A 64-bit D3D11 title died in the loader on a D3DX9 import, and
  the 64-bit farms had ONE `d3dx9_*.dll`.** Logs w3/w4: `err:module:import_dll
  Library d3dx9_42.dll (which is needed by <main exe>) not found`, exit status
  0xC0000135, nothing else. Census of the three farms at that moment:
  `d3dx9_*` i386=20, aarch64=1, arm64ec=1 (only `_43`); same story for
  `d3dx10_*` and `d3dcompiler_*` (33..42 absent) and `d3d10.dll` / `d3d10_1.dll`
  (absent, so even the one `d3dx10_43.dll` could not load — the import-closure
  check had been flagging `d3dx10_43.dll -> d3d10_1.dll`). The 32-bit breadth
  build ("everything that compiles") was never mirrored on the 64-bit side,
  which stayed a curated list. Fixed generically with
  `.xtool/build-wine-64.sh all …`: d3dx9_24..43, d3dx10 + d3dx10_33..43,
  d3dx11_42/43, d3dcompiler_33..47, d3d10, d3d10_1, d2d1, quartz, glu32 for both
  aarch64 and arm64ec (arm64ec is what an x86-64 process loads). `d3d10.dll` /
  `d3d10_1.dll` import only `D3D10CoreCreateDevice` + `CreateDXGIFactory`, both
  exported by the Metal `d3d10core.dll` / `dxgi.dll` already in the farm
  (checked with `llvm-objdump -p`). Import closure now reports 0 missing for
  both farms. Farm sizes: aarch64 229 files, arm64ec 211. TODO: make the 64-bit
  farm a breadth build like i386 so this class of failure cannot recur one DLL
  at a time.
- 2026-09-19 — w1.txt line ~38948: the app died on a host BUS after a long
  healthy session. **It is not the profiler, and `msync()` is not a readability
  test.** The log symbolises the pc itself: `sym pc=Madeira`
  `ios_alert_waiter_dump+0x3d4`, `bt[0] ios_pump_sample+0x4c`,
  `bt[1] ios_pool_warmer_thread+0x6e4` — the pool-warmer thread, not the
  profiler sampler, and `wine/dlls/ntdll/unix/sync.c`, not
  `signal_arm64_ios.c`'s module-name code.
  ROOT CAUSE. ml441/ml442 guarded every lock-word probe with
  `if (!msync( page, 0x4000, MS_ASYNC ))`, reasoning that Darwin returns ENOMEM
  for an unmapped page. msync answers a question about the MAPPING and says
  nothing about the PROTECTION, so a region mapped `PROT_NONE` — exactly what a
  guest DLL being unloaded or reprotected looks like for the moment it takes —
  passes the guard and then faults on the load. The log has it in one line:
  `[bus-rgn] region=0x71774f0000+0xd8000 prot=0 max=7` with
  `VERDICT <== ANONYMOUS, NEVER RESIDENT`. The faulting
  `insn=0xb8404528 (ldr w8,[x9],#4)` is this function's own w0/w1 pair — the
  compiler folded `*(al)` and the `al + 4` address into one post-increment —
  at `sync.c:5022` as it stood.
  Fixed by reading OUT instead of dereferencing: new `ios_safe_read()`
  (`sync.c:4955-5002`, `mach_vm_read_overwrite` into a local) now backs the
  `[hot-lock]` 0x40-byte rows, the `[waiters]` w0/w1 probe, and
  `ios_orphan_check`'s lock-word read. The kernel does the permission check and
  reports failure as a return value instead of a signal, which is the only
  "is this readable" that is not a race in the first place: any protection test
  is stale by the next instruction, and this one cannot be, because the test IS
  the read. `w0`/`w1` keep their existing `0xdeaddead` poison when the read
  fails, so no log consumer had to learn a new spelling. The two REAP paths
  (`ios_wpm_reap_shared`, `ios_srw_reap_exclusive`) must stay real atomic RMWs
  on the guest word, so they get a `ios_safe_read` probe before the CAS loop
  instead — it catches the common "page is already gone" case; the residual
  reprotect-between-probe-and-CAS window is inherent to writing another
  process's lock and is what the orphan detector's three-strike verdict pays for.
  SECOND DEFECT, AND THE ONE THAT MADE IT FATAL. The first BUS was survivable;
  the REPORT of it was not. `ios_log_guest_exception+0x48`, insn `b9404808`
  (`ldr w8,[x0,#0x48]`) with `x0 = 0`: it opened with
  `NtCurrentTeb()->ClientId.UniqueThread`, a load at TEB+0x48, and
  `NtCurrentTeb()` is x18, which is 0 on every thread we did not create. So the
  handler faulted inside the handler on a thread with no TEB to adopt it, twice,
  and the process died. Now it prints `tid=0000` instead
  (`signal_arm64_ios.c:6611-6625`). Its two `DBG_PRINTEXCEPTION` buffers are
  GUEST pointers and were dereferenced straight into `%.*s` / a WCHAR loop; they
  are copied out through `ios_exc_safe_read_upto` now
  (`signal_arm64_ios.c:6588-6609`), which returns the longest readable prefix
  and appends `<unreadable tail>`. A logging helper must not be able to kill the
  process.
  AUDITED AND ALREADY CLEAN: the ml998 loader re-walk (`ios_gmod32_build`) reads
  every field through `ios_prof_read` (= `mach_vm_read_overwrite`) and is
  bounded to `IOS_GMOD32_MAX` = 160 entries; `ios_pe_module_name` reads the PE
  header and export directory the same way; `ios_gmod32_probe` and the
  `[prof] block#` guest byte dumps use `ios_prof_read` / `ios_prof_read_upto`;
  the `[thread-stacks]` sampler's TEB reads are `mach_vm_read_overwrite`. None
  of them can fault, which is why none of them is in the backtrace.
  **What to look for in the next log:** no `bus_handler` at
  `ios_alert_waiter_dump`; `[waiters]` rows with `w0=deaddead w1=deaddead` where
  a lock page has gone away (that is the fix working, not a new fault); and any
  `[exc-disp]` line from a no-TEB thread reading `tid=0000` rather than being
  the last line in the file.

- 2026-09-20 — **THE xWMA "DECODER BUG" WAS NEVER IN THE DECODER: a streaming
  wave bank that does not start at byte 0 of its file had its wave data read
  from the wrong place.** Four rounds went into libavcodec parameters. What
  ended it was reproducing on the HOST instead of reasoning from device logs:
  a minimal host ffmpeg built from the same 7.1.1 tree (`~/ffhost`), a 40-line
  harness that opens/sends exactly as `winegstreamer_unixlib_ios.c` does, and
  the wave-bank container files from a local install.
  1. The 16 packet-head bytes logged by `[wma] pkt#0` / `pkt#1` were searched
     for in the container: found, 1487 bytes apart (= block_align), so pushes
     ARE consecutive packets of SOMETHING.
  2. But the position was `entry_start + 22528` of an unrelated entry — not a
     multiple of block_align. For a second stream the position was
     `entry_start + 0xf000` of another unrelated entry. The offsets differ, so
     it is not a constant skew …
  3. … it is the BANK'S BASE OFFSET. The containers hold several `WBND` banks
     each; for both samples `logged position + bank base` is exactly the start
     of an entry whose rate/channels/block_align match what the decoder was
     created with. `FACT_INTERNAL_ParseWaveBank` adds
     `FACTStreamingParameters.offset` to every HEADER read (`SEEKSET`), but
     leaves `entries[i].PlayRegion.dwOffset` bank-relative, and the streaming
     path (`FACT_INTERNAL_OnBufferEnd` → `FACT_INTERNAL_ReadFile`) uses it as
     an ABSOLUTE file position. Correct format, wrong bytes: every WMA packet
     fails, PCM/ADPCM banks play the wrong sound. A bank at offset 0 (or in
     memory) is unaffected — which is why menus were fine and everything
     streamed from a multi-bank container was noise.
  Fix (`wine/libs/faudio/src/FACT_internal.c`, generic): after the entry
  length fix-ups, `if (isStreaming && offset) entries[i].PlayRegion.dwOffset +=
  offset`. Build tag `MADEIRA-FACT-2026-09-20-stream-base-offset` in every
  `xactengine*.dll`.
  Host measurements on the CORRECTLY located entries, same API calls as the
  device: 22050 Hz 2ch block 1487 — header rate 192000: 642 of 643 packets
  fail; 32000: 0 fail, 238 s decoded, peak 1.54. 32000 Hz 2ch block 2304 —
  192000: 87/87 fail; 48000: 0 fail. So (a) `libavformat/xwma.c`'s fake-rate
  table is REQUIRED, not optional: the decoder now opens at the table's rate
  up front when the codec-private data is the synthetic all-zero-but-flags2
  blob an xWMA caller fabricates (a real ASF header never is), keeping the
  header rate as the fallback candidate; (b) legitimate float peaks reach
  1.54, so last round's ±1.25 "sane frame" limit would have muted real audio —
  now 3.0 (garbage measured 4.5–15). Also worth keeping: a fresh WMA decoder
  fed a mid-stream packet fails SILENTLY (`exponents not initialized`, no
  av_log) — "no log line" does not mean "no error path".
  LESSON: when the bytes are available on the host, reproduce there first. The
  device log could only ever say "packets fail"; ten minutes with the real
  file said where the bytes came from.
  64-bit farms also gained xactengine2_*/3_*, xaudio2_0..6, x3daudio1_0..6 and
  xapofx1_1..4 (they had only the newest of each).

- 2026-09-21 — **Physical thumbsticks "do not work" while buttons do: the
  analogue half of the pad was reaching GameController only in bursts.**
  Device logs x100-x102: the `[xinput]` census shows buttons arriving normally
  but `axis_events` of 36-50 in 25,000-60,000 samples during minutes of play
  with the stick held (the one run with 606 was a held TRIGGER:
  `first axis motion … ltf=1.000`). The slot read-back, the win32u query and
  the struct layout are all correct, so the values never got to the app. Since
  iOS 18 the system also turns controller input into UIKit/SwiftUI focus
  navigation unless the hierarchy declares that it consumes the pad through
  GameController: `GCEventInteraction` (UIKit, `handledEventTypes = .gamepad`)
  and SwiftUI's `handlesGameControllerEvents(matching:)` (cross-import overlay
  `_GameController_SwiftUI`). Neither was installed. Now: `GamepadEventClaim`
  puts the interaction on the Metal host view, the Metal-backed surface and
  the control overlay, and the root SwiftUI view carries the modifier, both
  behind `#available(iOS 18)`. UNVERIFIED on device — what to read next time:
  `axis_events` should climb by hundreds per 10 s while a stick is held.
- 2026-09-21 — Profile of a job-system title in gameplay (x102): wineserver
  traffic 34-46k req/s (`select` 22k/s — half INFINITE single-object waits,
  half zero-timeout polls that time out — and `NtSetEvent` 11k/s), in-call
  0.7-1.06 core, and `read_request`/`read_reply_data`/`write` in the kernel
  ≈ 50 % of ALL CPU against 23 % for guest code. The frame rate there is the
  server's, not the GPU's or the JIT's. This is the workload the in-process
  event fast path was written for; see the fastsync entry that follows.
- 2026-09-21 — **Every x86-64 title died at the first call from ARM64EC code
  into x64 code, because our own x18 trampolines pushed a register onto a
  legally misaligned SP.** iOS reserves x18, so the JIT loader rewrites each
  `[x18, …]` reference in a PE's `.text` into a branch to a generated
  trampoline that fetches the TEB from our pthread TSD slot via
  `TPIDRRO_EL0`. The trampoline needed one scratch register and spilled it
  with `str x16,[sp,#-16]!`. AArch64 raises an **SP alignment fault on any
  SP-based memory access taken while SP is not 16-byte aligned**, and an
  8-mod-16 SP is normal on the EC→x64 dispatch path, which pushes an
  x64-style return address before reading the TEB. Result: BUS with fault
  address 0 inside a trampoline (`insn=f81f0ff0`, `sp=…3d8`), then a
  second-order mess because recovery runs with `x18=0` and clobbers `x17`.
  Note the constraint carefully: only SP-based *accesses* fault, `add`/`sub`
  on SP do not — but SP cannot be realigned, or copied into a register,
  without already having a scratch register, so the trampoline must avoid SP
  entirely and therefore must find a free register. There is none that is
  provably dead at an arbitrary mid-function site: x16/x17 are call-clobbered
  veneer registers, yet the dispatch sequences that reach these very
  instructions keep both live, and no per-thread spill slot helps because
  reaching one already needs the scratch. Taking the scratch from the patched
  instruction's own destination covers plain loads, `mov` and `add` — a census
  of the shipped ARM64 and ARM64EC PE images (4,780 patch sites) puts that at
  61 %, leaving 39 % (stores, compares, prefetches, SIMD transfers,
  register-offset loads whose destination is the index) with nothing.
  **The fix is to use x18 itself as the scratch**: it is the one register the
  whole pass exists to eliminate, the platform zeroes it at every context
  switch and signal return so nothing may rely on it, and with the TEB in x18
  the original instruction runs *unmodified*. No spill, one shape, 100 %
  coverage. Two bonuses: sites the pass skips then see a correct TEB instead
  of zero, and a signal delivered mid-trampoline returns with x18 zeroed, so
  the instruction faults exactly as an unpatched one would and the existing
  `x18==0` emulator finishes it — self-healing, where the old emitter left a
  half-restored x16/x17. The emitter now also self-checks every word it is
  about to install and refuses any that uses register 31 as an address base.
  LESSON: a generated code sequence inherits the *caller's* invariants, not
  the compiler's. "Push a scratch register" is only free in code that owns its
  stack discipline; injected code owns nothing, so it must spill into
  something it can prove is its own — and the register the rewrite is removing
  is exactly that. Second lesson: when a SIGBUS reports a fault address of 0
  or of SP itself, suspect SP alignment before suspecting the mapping; the BUS
  handler now says so in an `[sp-align]` line.
  Same log, unrelated: the sampler thread walked a guest PE export directory
  with raw loads and took a SEGV on a module whose process had just exited.
  That walk (and the module-name read next to it) now goes through
  `mach_vm_read_overwrite` with every offset bounded by the mapping size, the
  discipline the rest of the fault-path readers already follow.

- 2026-09-21 — fastsync ml982: AUDIT, a read-only default that ships, a
  watchdog, and a job-system stress test (`ntdll/unix/sync.c`,
  `ntdll/unix/unix_private.h`, `ntdll/unix/server.c`, `server/event.c`,
  `server/object.h`, `shims/ios_fastsync.h`, `shims/ios_srv_stats.h`,
  `build/ntdll-unix/server_ios.c`, `x86-tests/sync-x86.c`,
  `x86-tests/build-sync-test.sh`).
  MOTIVATION, from a 10 min device log of a title with a job system
  ("Core_N - Thread 0") in steady gameplay: `[srv-stats]` 33.8-46.5 k
  requests/s, in-call 0.73-1.06 core, and `[prof]` putting
  `read<-read_request` 31-33 % + `read<-read_reply_data` 12 % +
  `write<-call_req_handler` 5 % ≈ **half of all CPU inside the wineserver
  round trip**, against jit 22-24 %. The traffic is `select=223749/21us` +
  `event_op=112093/22us` per 10 s, i.e. `NtSetEvent` 110569, single-object
  waits 223277 — 105477 INFINITE and **116607 zero-timeout polls of which
  115920 time out**. The in-process event fast path that removes nearly
  all of it exists (ml952/ml962/ml972) and has been default OFF since
  ml962 because the ml972 round was never run on a device.
  **THE SPLIT.** The audit's main conclusion is that this mechanism is two
  mechanisms with very different risk. Taking or minting a token
  off-server (set / reset / park / wake) is the hard half: every
  lost-wakeup and double-release defect of ml952-ml972 lives there.
  ANSWERING "NOT SIGNALED" is not: it consumes nothing, releases nobody,
  writes nothing, and the word it reads IS the server's own state —
  `MADEIRA_CELL_RESET` is exactly the value `event_sync_signaled()`
  answers "no" for. So `MADEIRA_FASTSYNC` now selects four rungs (table at
  the head of `ios_fastsync.h`): `0`/`off` = no cells at all (pre-ml952,
  byte for byte); **unset = the new default: the server keeps event state
  in a cell and the client uses it for ONE read-only thing**; `auto` =
  that plus the wake path armed on traffic; `1`/`on` = the wake path from
  the first call. With no client participation a cell is a pure relocation
  of one bit — `signaled`/`satisfied`/`signal` read and write the cell
  exactly where they used to read and write `event->signaled`, and every
  CAS succeeds first time.
  **POLL PEEK** (`MADEIRA_FS_POLLPEEK`, default on): a zero-timeout
  single-object wait whose cell reads RESET returns `STATUS_TIMEOUT` with
  no request. The generation is re-read AFTER the state word, so an
  unchanged `gen` either side proves no recycle happened across the load
  and the RESET belonged to our event; SET/CLAIMED/DISABLED and every
  doubt go to the server. **One poll in 16 goes to the server anyway**,
  which is the whole safety argument: it bounds how long a pending system
  APC can sit undelivered behind a thread that does nothing but poll, and
  it makes a wrong cache entry self-correcting within 16 iterations of the
  caller's own loop (the worst a wrong peek can do is a spin, never a lost
  wakeup). Every 64th peeked poll yields, replacing `server_wait`'s poll
  streak for these calls; `ios_spin_reset()` is deliberately NOT called
  from the peek (a poll that does not block is not "a thread that
  blocked"), so a peeked poll no longer ends a Sleep(0) streak. Counter
  `pollpeek=N(total)` prints next to the surviving `w1 poll=`.
  **WATCHDOG.** A hang cannot live in the park loop — it caps at
  `madeira_fast_cap_ns` (2 ms) — it lives in the `server_wait` the
  fall-through does, so the fix is to stop making that wait infinite. When
  the wake path is live, an INFINITE single-object wait **on a cell-backed
  event** (thread/process/mutex/file keep the plain infinite wait,
  answered from the negative cache) becomes a 2 s wait that backs off x4
  to 60 s. On each expiry: if the cell says SET while the server has just
  said not-signaled, re-ask the server with a ZERO-timeout select — which
  is both the confirmation and the cure, since a genuinely signaled object
  satisfies the wait there and then. Only "server says no AND the cell
  still says SET" is a verdict: one
  `[fastsync] DESYNC handle=... cell=... gen=... state=.../... waiters=... srv_waiters=...`
  line per process, `desync=` in `[srv-stats]`, and
  `MADEIRA_EVENT_OP_DISABLE` (MADI) on that ONE object — a new opcode that
  runs `event_sync_disable_cell()`, the exit PulseEvent has always used,
  folding the cell state back into `signaled` and waking every parked
  client. It is the one opcode accepted on a SYNCHRONIZE handle, because
  the thread that notices is by construction a waiter. A false positive
  therefore costs one permanently slower event; a real incoherence costs a
  log line instead of a dead thread.
  **DEFECT FIXED: a positive cache entry outliving its process.** The
  `(handle, pid)` cache is invalidated by `madeira_fast_close()`, i.e. by
  THIS process closing the handle. Nothing invalidates the entries of a
  process that simply dies — and the server reuses process ids
  (`alloc_ptid` keeps a free list), so a later pseudo-process can be handed
  the same id, allocate the same low handle values, and hit a slot whose
  handle AND pid both match and whose cell is still live because the event
  is still alive elsewhere. That is a set or a wait landing on an
  unrelated object with no race at all — the ml962 torn-publish failure
  shape, reachable deterministically. `madeira_fast_flush_pid()` scans the
  2048 slots once from `server_init_process_done()`, where this process
  provably owns no handles, so any entry with our pid is a ghost.
  **AUDIT: what was checked and found sound.** Auto-reset with N waiters
  and M setters (the SET -> CLAIMED claim plus `MADEIRA_EVENT_OP_WAKE`
  make exactly-once hold: a client CAS cannot steal a token the server has
  reported, and the client's wake-only opcode cannot mint a second one);
  the two Dekker pairings (`store state; load srv_waiters` against
  `srv_waiters++; load state`, both seq_cst — and on arm64 STLR followed
  by LDAR is exactly the pair that forbids the store-buffering
  reordering); manual set/reset racing waiters; a poll consuming an
  auto-reset token exactly once; a handle waited on BOTH through the cell
  and through a server-side `select`, including `WaitForMultipleObjects`
  (the server's `check_wait` claims, `end_wait` satisfies, and nothing can
  run between them because the server is one thread); WaitAll claim
  release through `object_sync_unclaim`; handle close/reuse across a park
  (the `gen` re-check); `PulseEvent` (one-way exit, and every client op
  tests DISABLED); `NtSignalAndWaitForSingleObject` and keyed events
  (never fast-pathed); alertable waits (never fast-pathed);
  `NtSuspendThread`/`NtTerminateThread` of a parked thread (both are
  signal-delivered on this port, so the park returns EINTR and the loop
  re-checks; the cap bounds the rest).
  **RESIDUAL, documented not fixed.** (a) `madeira_cell_alive()` and the
  state CAS are not atomic with each other: between them the event can be
  destroyed and the cell re-allocated, and the CAS then touches a
  stranger's event. The window is tens of nanoseconds and reaching it
  needs the caller to be operating on a handle another thread is closing —
  undefined on Windows too — but the consequence here is a lost wakeup on
  an unrelated object. Closing it properly means packing {state, gen} into
  one 64-bit word and CASing both, with the futex still waiting on the low
  half; that is mechanical but touches every state access on both sides
  and is not worth doing blind. (b) A thread killed while parked leaks its
  `waiters` increment, so every later set on that cell pays one spurious
  `os_sync_wake_by_address` — cost only.
  **DEFAULT DECISION: the wake path stays OFF.** The brief allowed `auto`
  as the default if soundness could be argued case by case. It cannot, on
  two grounds: residual (a) above is a real lost-wakeup vector that was
  chosen not to be eliminated, and nothing in ml972 or ml982 has ever
  executed on a device. `auto` is implemented and is one env var away
  (`MADEIRA_FASTSYNC=auto`): the rule arms the wake path task-wide, once,
  never back, when a `[srv-stats]` window shows more than
  `MADEIRA_FS_AUTO_REQS` (20000, ~2 k/s) event+select operations — the
  measurement above is 338 k, a launcher is nowhere near, and the three
  programs that died on the ml952 snapshot were all quiet ones. It logs
  `[fastsync] AUTO-ENABLED after N ... ops in Nms (N/s, threshold N)`. The
  arm is task-wide rather than per-pseudo-process because this image is
  one Mach task and both the flag and the counters are single words in it.
  What ships enabled is the read-only half, which is `poll=116607` per
  10 s — a third of all requests — for no wake semantics at all.
  **TEST.** `sync-x86.exe` gains test 10, a job system: 6 workers rotating
  per iteration through `WaitForSingleObject` INFINITE / 1 ms / 0 ms poll /
  `WaitForMultipleObjects` over two handles at 50 ms, so the same event is
  continuously waited on through the client path AND queued in the
  server's select; a producer publishing bursts of 1-8 jobs, one in 16 of
  them signalled through a handle made by `DuplicateHandle` and closed
  immediately (fresh handle value, fresh cache slot, an eviction, against
  a live event); a churn thread recycling cells throughout; 10 s. Exact
  accounting — a job is claimed with an atomic decrement, so it can be
  taken only once — plus a ONE SECOND per-burst deadline, which is what
  turns a lost wakeup from a stall into a failure. Exits 62 (a job was not
  consumed in a second, or the counters did not balance), 63 (a
  multi-object wait was released by the wrong handle — the never-signalled
  second handle), 64 (a zero-timeout poll gave the wrong answer: a manual
  event must read signaled TWICE after one set and not-signalled after the
  reset, an auto-reset event must be consumed by a poll exactly once).
  Writing it caught a bug in itself: N `SetEvent` calls on an unwaited
  auto-reset event release ONE thread, not N, so the burst is published as
  a counter plus one signal and the released worker hands the baton on.
  **VERIFIED BY RUNNING:** both native archives rebuild clean (`ntdll-unix`
  32/32, `wineserver` all files, no new warnings), `sync-x86.exe` builds
  (i386 PE, kernel32-only import, LAA set), and the WHOLE of `sync-x86.c`
  — all ten tests — was compiled against a POSIX model of the Win32 event
  surface (one global mutex and condvar, so auto-reset consumption is
  correct by construction) and RUN on the build host: exit 46, with test
  10 turning over 494337 jobs in 109854 bursts, each consumed exactly
  once. That is evidence about the TEST, not about fastsync — a test that
  cannot pass against a known-correct implementation is evidence about
  nothing. **VERIFIED BY REASONING ONLY:** everything in the audit list
  above, the peek's coherence with `event_sync_signaled`, the watchdog's
  verdict rule, and that the default mode is behaviour-preserving for the
  server. Next device run should show `pollpeek=` large with `w1 poll=`
  collapsed and `reqs/s` down by about a third, with
  `learn_ev`/`learn_none` NOT tracking `pollpeek` 1:1 (if they do, the
  polled handles are being churned and `MADEIRA_FS_POLLPEEK=0` is the off
  switch). Then `MADEIRA_FASTSYNC=auto` for the other half.

- 2026-09-22 — **No 32-bit program could start on a device whose address space
  ends at 63 GB.** Tablet log (no `extended-virtual-addressing`): `[va-probe]
  entitlement=no top=0xfc0000000 guest-slots=12`, then `[wow-window]
  B=0x7100000000 REJECTED: 4GB+guard unavailable … (free to end of VA)`, the
  same for `0x7200000000`, `main-process reserve FAILED 0xc0000017`, and the
  user sees an unrelated-looking "invalid handle" box from the launcher. The
  64-bit side already adapts (TEBs at `0xfbffe0000`, §9.6 probe says
  `identity-layout-possible`); only the guest-window CANDIDATE BAND was still
  the constant `[0x7000000000 + pool, 0x73ffff0000)`. Nothing about a guest
  window needs a high address — FEX forms `B + zext32(EA)`, so B only has to be
  4 GB-aligned. New `ios_wow_band()` (virtual_ios.c, used by
  `ios_wow_candidate_slot`, `ios_wow_window_pick` and
  `ios_wow_reserve_placeholders`): when `TASK_VM_INFO.max_address` is below the
  normal band, candidates come from `[16 GB, 24 GB)` — two slots, above the
  image / malloc zones / shared cache / pool RW alias, below the top-down
  furniture. Two and not ten because every slot in the band is reserved as a
  placeholder at session start and `ios_wow_candidate_slot()` biases furniture
  below the first UNreserved one. Logged once as `[wow-window] SMALL ADDRESS
  SPACE …`. UNVERIFIED on the device. Known soft spots if it still fails
  there: the heuristics in signal_arm64_ios.c that classify
  `0x7000000000..0x7400000000` as "guest band" (:7355, :8623, :13891) do not
  know about a low window; registered threads do not depend on them.
- 2026-09-21 — **CORRECTION to the x18-trampoline entry above: "interruption is
  self-healing" was wrong, and x18-as-scratch everywhere regressed both a
  32-bit and a 64-bit title.** The claim only holds for instructions that FAULT
  when x18 is zero. The kernel zeroes the platform register on every exception
  return -- not just signals, but every Mach exception reply, and a running
  process takes ~10^5 of them for PE-page exec-fault redirects alone. So a
  trampoline that loads the TEB into x18 and consumes it in the NEXT
  instruction is racing the kernel, and loses often enough at a hot site to be
  deterministic. Both failures were the same shape, an address computation:
  `add x8, x18, x0, lsl #3` (64-bit, TLS slot index) and
  `add x8, x18, #0x2000` (32-bit, the TEB32 that sits 0x2000 above the TEB64)
  resumed with x18 == 0, produced x8 = index*8 and x8 = 0x2000, and the load
  ONE instruction later died on a tiny address that no emulator recognises as
  a TEB access. `add` does not fault, so there was nothing to heal. The
  device logs show the TSD slot itself was perfectly healthy at the moment of
  death (`[teb-tsd] … raw=0x7101890000 teb_key_val=0x7101890000`), which is
  what rules out the slot-offset and publication theories: the trampoline read
  the right TEB and the kernel threw it away. Note also that the previous
  build was immune for a reason worth stating plainly: **x16 and x17 survive an
  exception return and x18 does not**, so the old spill emitter could lose only
  its SP push, never its TEB.
  The rule now is: never keep a value in x18 across an instruction boundary
  unless a wrong value is guaranteed to fault. Three classes, chosen per site,
  counted per image in `[x18-tramp] shapes:`:
   1. **free destination** -- the instruction writes a GPR it does not read.
      Scratch = that register, with the x18 field rewritten to it. No SP, no
      x18, immune to everything. Both shapes above land here. 61.0 % of the
      4,804 sites in the shipped ARM64/ARM64EC images.
   2. **x18** -- a memory access based on x18 with no free destination
      (stores, pairs, SIMD, register-offset loads whose destination is the
      index). x18 is allowed here and ONLY here, because a zeroed x18 turns the
      access into a fault at a tiny address that the Mach handler's x18==0
      emulator completes against the real TEB and resumes at pc+4 -- the
      trampoline's own branch back. The patcher restricts this class to the
      encodings that emulator actually decodes, and the emulator gained the
      32-bit load/store pair it was missing. 38.4 %.
   3. **spill** -- everything else: x18 as a non-base operand, a destination
      that is also a source, a compare. A zeroed x18 would run silently, so
      these keep the TEB in x16 (x17 only if x16 is taken; the signal-return
      path redirects pool PCs through a veneer that overwrites x17) and spill
      through SP. The SP alignment fault those two words take on a legally
      8-mod-16 stack is now RECOVERABLE: the fault path recognises the exact
      push/pop encodings inside the pool, emulates them against the misaligned
      SP and resumes, logging `[x18-tramp] sp-spill emulated`. Only 0.6 % of
      sites -- 28 across five images -- so the cost of a Mach round trip there
      is irrelevant.
  Two decoder bugs fell out of the same review. `(top8 & 0x5F) == 0x11` and
  `== 0x0B` matched only the ADD forms of add/sub: every `sub xD,x18,#imm`,
  `cmp x18,#imm` and `cmp x18,xM` was going unpatched and running with a zeroed
  x18, silently and forever. They now use the exact class masks
  (`insn[28:23] == 0b100010`, `insn[28:24] == 0b01011`). And an instruction
  naming x18 in two register fields (`add x0,x18,x18`) was being half-rewritten,
  leaving a live x18 read behind; those are meaningless in real code, so the
  patcher skips them instead.
  LESSON: "it will fault if it is wrong" is a property of an instruction, not
  of a register, and it must be checked per encoding. A scratch register is
  only a scratch register if the kernel agrees.

- 2026-09-23 — **Host CPU features were ASSUMED, and a wrong `true` is silent
  corruption.** A 32-bit D3D9 title that is correct on the phone rendered
  garbage text and geometry on a tablet with an older core, same build, same
  data (menu background fine; every glyph quad and all in-game geometry
  scrambled — i.e. computed values wrong, uploaded bytes right).
  `FEX/Source/Windows/Common/CPUFeatures.cpp` cannot call sysctl (PE module,
  no unix table) and claimed a fixed list including `SupportsAFP`. With
  FEAT_AFP claimed on a core without it, FPCR.NEP is RES0: every scalar SSE
  operation zeroes the upper lanes of its destination instead of preserving
  them, which is exactly "vectors built with scalar ops come out wrong". The
  app now probes `hw.optional.arm.FEAT_{AFP,FlagM,FlagM2,FCMA,LRCPC,AES,PMULL,
  SHA256,LSE}` + `armv8_crc32` at session start, logs `[fex-cfg] host feature
  probe: AFP=0,…`, and exports `FEX_MADEIRA_HOSTPROBE`; CPUFeatures.cpp turns
  a feature off only on an explicit `=0` ("?" or no variable keeps the old
  assumption). UNVERIFIED on the tablet — the probe line in the next log says
  whether AFP was in fact the difference; if it reads AFP=1 there, this was
  not the cause and the next suspects are GPU-family differences in the D3D9
  layer.
- 2026-09-23 — **A desktop with NO foreground window drops every key press.**
  Log of a 32-bit SDL2 title: `foreground=0x0 fg_input=0x0 focus=00000000
  active=00000000` for the whole run; on-screen Esc/Space/Enter/arrow keys did
  nothing (`raw: drop(nofg=1)` for the mouse too). There is no window manager
  here to hand a new top-level window the focus, which every other driver
  relies on; most programs become foreground through ShowWindow activation or
  the first click, but a program whose active window was destroyed, or that
  is driven by keys only, is left orphaned. `ios_adopt_orphaned_foreground()`
  (build/win32u-unix/message_ios.c, called from `process_driver_events`, at
  most once a second): if the desktop has no foreground window, the pumping
  thread's topmost visible, enabled, non-tool top-level window is made
  foreground through the normal client path (WM_ACTIVATE/WM_SETFOCUS are
  delivered). Logs `[focus] desktop had no foreground window; adopted …`.
  It can only fill a vacuum.

- 2026-09-23 — **Every x86-64 call into ARM64EC code cost a Mach exception,
  for months, because a `.S` file was assembled without the define its C++
  neighbours were compiled with.** A 64-bit title made no progress at all: 100%
  CPU, `[x18-redir2]` at #446,464 in one run and #876,544 in another, three or
  four distinct PCs, the `wine-x18-exc` handler thread holding 25% of all CPU
  and `mach_msg2_trap` 23.6%. The redirect PCs came in PAIRS and that is what
  named the bug: `ucrtbase+0x17164` is `tolower`, `ucrtbase+0x90c5c` is
  `$ientry_thunk$cdecl$i8$i8`, and `0x17164 + (*(int32_t *)(0x17160) & ~3)`
  **is** `0x90c5c`. `_stricmp`/`+0x90cec`, `__wine_dbg_output` with
  `$ientry_thunk$cdecl$i8$i8i8i8`, and `kernelbase!VirtualAlloc2` are the same
  shape. That arithmetic — target plus the entry-thunk offset stored in the
  word before it — exists in exactly one place, `ExitFunctionEC` in FEX's
  `Source/Windows/ARM64EC/Module.S`, and it was being performed in **PE
  space**: two exec faults per guest call, one for the thunk and one for the
  function the thunk then `blr x9`s to.
  `Module.S` has carried an `#ifdef FEX_IOS_HOST` block since ml316 that
  translates that target through `IosAliasEntries` (PE VA -> JIT-pool copy)
  before branching. Disassembling the SHIPPED `xtajit64.dll` showed the block
  was not there — and `check_target_ec` opened with `ldr x16,[x18,#0x60]`, the
  `#else` arm. `.xtool/build-fex*.sh` passed the define in `-DCMAKE_C_FLAGS`
  and `-DCMAKE_CXX_FLAGS`; `project(FEX C CXX ASM)` builds a `.S` with the
  **ASM** language, whose flags are `CMAKE_ASM_FLAGS`. So the emulator's C++
  half was built for iOS and its assembly half was built for Windows, in one
  DLL, with no warning and no link error. Four mechanisms were silently absent:
  the alias translation, `ExitToX64`'s fast-forward-sequence bypass,
  `enter_jit`'s code-buffer sweep gate (whose C++ counterpart in
  `CPUBackend.cpp` has been setting the flag one-sidedly all along), and every
  `IOS_LOAD_TEB`.
  **THE FIX BELONGS TO THE TARGET, NOT THE SCRIPT.**
  `target_compile_definitions(arm64ecfex PRIVATE FEX_IOS_HOST)` feeds
  `<DEFINES>` to the ASM rule as well as C/C++, so the flag now lives with the
  thing it describes (`CMAKE_ASM_FLAGS` was added to the scripts too, as belt
  and braces). And because "it built and looked fine" is precisely what went
  wrong, `Module.S` now defines `IosEcAsmIosBuilt` inside its `#ifdef` and
  `Module.cpp` reads it: a future mismatch **fails to link**. It prints next to
  `[build-id]`.
  **FAST PATH.** The scan is O(images) — ~50 entries x 6 instructions per
  x64->EC call — so `ExitFunctionEC` gained a last-hit cache: `IosAliasHot`, a
  single 32-bit index, probed before the walk and republished on a scan hit. An
  INDEX and not a copy of the entry, deliberately: a naturally-aligned 32-bit
  load is atomic, and the entry is RE-TESTED against the target before it is
  believed, so a stale or out-of-range value costs one compare and can never
  produce a wrong answer. No generation counter, no barrier, no lock.
  `ExitToX64`'s FFS bypass — which reverse-translated its target to PE space to
  consult the EC bitmap and then deliberately branched to the PE VA "because
  this is RPC frequency" — now walks the same table forwards and branches to
  the copy that can actually run.
  **PROVE IT NEXT RUN:** `[ec-call] translated=N faulted=M` every 10 s from the
  profiler window. FEX counts both outcomes in `IosAliasStats`, exported as
  DATA; ntdll-unix reads it *through the pool copy* — the PE image's `.bss` is
  not what executes, which is the same lesson the `[ec-bind] POOL STALE` line
  records. `translated` climbing with `faulted` flat is the fix working;
  `translated` stuck at 0 means the assembly half was built wrong again, which
  is now also a link error.
  **TWO NEAR-MISSES FOUND ON THE WAY IN.** (1) `Module.S`'s TEB reads use a
  PLACEHOLDER TSD slot (`#0x898`) that virtual_ios.c's "Pass 0" rewrites to the
  real one before the image ever runs. That pass filtered literal-pool words
  with `data_map[i / 4]` — one BYTE per word — while `ios_x18_build_data_map`
  stores one BIT per word and the x18 pass beside it reads it correctly. For a
  2 MB `.text` that indexed ~512 KB past a 132 KB allocation, and whatever it
  found there could mark a real triplet as data and SKIP it, leaving the
  placeholder in place: a stranger's TSD word used as the TEB, with no fault to
  catch it. It had never mattered because no shipped image contained the
  triplet. Both readers now go through `IOS_X18_DATA_WORD()`. A host harness
  replays the filter and the matcher against the rebuilt DLL: 6 triplets, 6
  retargetable, 0 skipped. (2) The pass is skipped entirely when the slot
  offset is not yet known, silently fatal for the same reason; that case now
  logs, loudly, naming the image.
  **BISECT HANDLE.** Three of the four newly-live mechanisms are either
  verified statically or are the missing half of code already running; the FFS
  bypass is the one that changes dispatch for native EC callers and has never
  executed. `MADEIRA_EC_FFS_BYPASS=0` turns just that off and keeps the
  translation. Reported at `[build-id]`.
  32-bit runs were checked for the same pattern and do not have it: per-run
  `[x18-redir2]` totals of 10, 10, 10 and 8,192 against 446,464 and 876,544 for
  the 64-bit ones. The WOW64 module has no `.S` at all, and a 32-bit guest
  reaches builtins through the wow64 thunk path rather than an EC transition.
  LESSON: a build flag that reaches some translation units and not others is
  invisible to every test that only asks "did it build?". When a mechanism is
  supposed to be live and the evidence says it is not, **disassemble the
  artifact** before theorising about the source.

- 2026-09-23 — **A byte access reported as a datatype misalignment, and the
  emulator's own spin lock living in memory it cannot write to.** A 32-bit
  title died at startup with 0x80000002 twice in a row.
  FIRST, THE LABEL. JIT code executed `stlrb w20,[x24]` (insn 0x089fff14) to a
  read-execute page of a builtin image. ESR 0x9200004f: DFSC 0b001111, a
  level-3 PERMISSION fault, WnR=1. A byte access cannot be misaligned and the
  hardware never said it was — but Darwin reports **every** arm64 SIGBUS with
  `si_code == BUS_ADRALN`, including `KERN_PROTECTION_FAILURE`, and
  `bus_handler` gated on exactly that, so anything its emulators declined fell
  out of the bottom still labelled STATUS_DATATYPE_MISALIGNMENT. The target was
  the first byte of an exported syscall stub in `.text` — an inline hook a
  32-bit program tried to install — i.e. an ordinary, survivable access
  violation. The page is NOT mis-protected: `.text` is not writable in the PE
  and wine's own vprot for it is `0x25` (committed|read|exec), which is why the
  `[wr-strip]` machinery correctly answered "not a strip". `bus_handler` now
  classifies from ESR.ISS DFSC for EVERY encoding, decoded or not: only
  `0b100001` keeps 0x80000002, everything else is delivered as the c0000005 the
  record was already built for — and which FEX's `ResetToConsistentState` can
  reconstruct a guest RIP for, which it cannot do for a misalignment. Logged as
  `[esr-class] NOT an alignment fault: … dfsc=0x0f (permission) …`.
  SECOND, WHAT THE BOGUS LABEL RAN INTO. The 0x80000002 sent FEX to
  `HandleUnalignedAccess`, which takes a backpatch lock — and that lock is
  `JITCodeTail::SpinLockFutex`, which the block emitter appends INSIDE the JIT
  code buffer. On iOS that buffer's executable view has no write bit, so
  `ldaxr w9,[x24]` / `stlxr w9,w8,[x24]` faulted on the store, inside the
  handler, while it was already handling a fault. Dead process. `Arm64.cpp` now
  takes the futex through `DualMap::WriteAddr`. One call site, and every
  participant (the CAS and `SpinWaitLock::Wait`/`Wake`, which key on an
  ADDRESS) derives it from the same pointer, so they still agree; both views
  map the same physical page, so the pair is a genuine hardware atomic.
  Verified in both shipped emulator DLLs by disassembly: the lock address is
  now `header + tailoff + WriteOffset + 0x20`.
  THIRD, THE GENERAL CASE. The RX->RW alias store emulator learned the
  exclusive family (LDXR/LDAXR/STXR/STLXR and the XP pairs) and the
  store-release family (STLR/STLRB/STLRH), in both the Mach-thread decoder and
  `ios_emulate_store`. **An exclusive pair cannot be emulated instruction by
  instruction** — the monitor is lost with the exception, and the value the
  matching load observed is unknown here because that load did not fault. So
  the store is NOT performed and NOT faked: it is reported as a **spurious
  failure**, which the architecture explicitly permits, with status=1 — and the
  BASE REGISTER is moved to the writable alias. Every well-formed LL/SC loop
  branches back to its load on failure and re-reads its base, so the retry runs
  entirely on the RW view: real LDAXR, real STLXR, real monitor, full
  atomicity, and no further faults for that loop. The substitution is
  value-for-value because an exclusive access has NO offset operand, so Rn
  holds exactly the faulting address — the caller verifies that against its
  register file before applying anything. Refused by construction: an SP base,
  and a store whose status register is WZR (a fabricated failure would be
  invisible and the loop would believe it held the lock). Forward progress is
  guaranteed: each fault moves one base register from a view that faults to one
  that does not.
  Host-tested: the decoder is extracted verbatim from the source and run
  against both device encodings, all four widths in both directions, both pair
  forms, and nine near-miss encodings that must NOT be claimed — CASP in
  particular shares `o1 == 1` with STXP and is separated only by bit31.
  LESSON: `si_code` on Darwin arm64 carries no information about alignment.
  Anything that decides "this is a misalignment" must read the ESR, and the
  cost of guessing wrong is not a wrong log line — it is routing a survivable
  fault into an emulator path that faults again somewhere with no handler.

- 2026-09-24 — **DXTn textures on a GPU with no BC support were never decoded,
  and the two ways that failed looked like two different bugs.** A 32-bit D3D9
  title is correct on a phone that reports `supportsBCTextureCompression = YES`
  and is unreadable on a tablet that reports NO — menu text and every in-game
  texture are noise, while an uncompressed background image is fine.
  WHAT WAS ACTUALLY HAPPENING, AND WHY IT HAD TWO FACES. On a device without BC
  support `to_metal_pixel_format` (`winemetal_unix.c` `remap_unsupported_bc`)
  has always rewritten a BC descriptor to `RGBA8Unorm` / `R8Unorm` / `RG8Unorm`
  of the SAME texel extent, so the resource is real and samplable — but nothing
  above it ever decoded the blocks, and the D3D9 frontend kept uploading BC
  bytes with BC row pitch. The blit encoder's `texture_upload_pitch_ok` guard
  drops a copy whose `bytesPerRow` is smaller than `width * bpp`, and for the
  8-byte block formats that pitch is `ceil(w/4)*8 = 2w` against a required `4w`,
  so **BC1 uploads were silently discarded** and the texture showed its zero
  fill. For the 16-byte block formats the same arithmetic gives
  `ceil(w/4)*16 = 4w`, which passes the guard exactly — so **DXT3/DXT5 uploads
  went through and their block bytes were then sampled as RGBA8**. One missing
  decode, two symptoms: empty where BC1 was used, noise where BC2/BC3 was. The
  device log's thousands of `[bc-remap] ml678 130 -> 70` / `132 -> 70` /
  `134 -> 70` lines are the population: BC1, BC2 and BC3, no sRGB, all of it.
  THE FIX IS IN ONE FUNCTION, BECAUSE THERE IS ONLY ONE FUNNEL.
  `MTLD3D9Device::stageTextureUpload` (`d3d9_device.cpp:1410`) is the single
  CPU-to-GPU texel path in the D3D9 frontend: `UnlockRect` on a texture level, a
  cube face or a standalone surface, `AddDirtyRect`'s region push, the MANAGED
  pre-draw sweep, all six branches of `UpdateTexture`, `UpdateSurface` and
  `ColorFill`'s block fill all end there. It now carries a decode arm
  (`d3d9_device.cpp:1438-1520`) modelled on the 3Dc pitch rewrite immediately
  above it: when the upload is compressed and the adapter cannot sample BC, the
  LOGICAL format is read off `dst_alloc->pixelFormat()` — `WMTTextureInfo` is
  built on this side and the remap happens below the unix boundary, which never
  writes the field back, which is the same property the D3D11 initial-data path
  already relies on — and the staged bytes are produced by decoding straight
  into the upload-ring block. `origin` and `size` are texel counts and do not
  change; only the pitch, the block-row rounding and the contents do. There is
  no scratch buffer and no per-block allocation: the ring span is sized for the
  decoded layout and the decoder writes into it in one pass, on the thread that
  called Unlock. `StretchRect`, `GetRenderTargetData` and AUTOGENMIPMAP need no
  change at all — once both textures hold decoded texels those are ordinary
  same-format GPU copies, and `generateMipmaps`, which Metal refuses on a BC
  texture, now works because the storage is RGBA8.
  THE SHADOW HAD TO BE PINNED, AND ONE PATH WAS ACTIVELY CORRUPTING. A
  compressed resource's sysmem mirror is now its SOLE copy of the blocks,
  because nothing re-encodes the decoded texels. Two consequences.
  `MTLD3D9Texture::dropMirror` and `MTLD3D9CubeTexture::dropMirror` refuse to
  evict one (`d3d9_texture.cpp:317-331`, `d3d9_cube_texture.cpp:193-205`), which
  costs the compressed footprint — an eighth to a quarter of the decoded copy
  the adapter is already paying for — and buys a Lock that always returns real
  BC bytes at the correct block pitch. And `readbackSurfaceMirror`
  (`d3d9_device.cpp:1561`) now returns immediately for these formats: it used to
  allocate a ring span, encode a texture-to-buffer copy that the SAME pitch
  guard then refused, and `memcpy` the untouched ring block over the
  application's pixels. That is a pre-existing corruption of a read-Lock on a
  DEFAULT DXT surface, independent of the decode, and it is gone.
  THE DECODER IS NOW SHARED RATHER THAN NEARLY-SHARED. `dxmt_bcn.hpp` already
  held complete BC1/BC2/BC3/BC4/BC5/BC7 block decoders; what it did not hold was
  the per-image loop, which lived in `dxmt_resource_initializer.cpp` where only
  D3D11's creation-time path could reach it, alongside a second, older copy of
  the BC1 and BC3 block decoders. The loop moves to `dxmt_bcn.hpp:178`
  (`bcn_decode_image`, now taking an explicit destination pitch), the duplicate
  block decoders are deleted, and the initializer keeps thin forwarders so every
  existing D3D11 caller is unchanged. One implementation, three frontends.
  VERIFIED. A host unit test pins the block layout on the build machine against
  blocks whose correct output follows from the BC specification by hand —
  `build/dxmt-tests/bcn-host-test.cpp`, run by
  `build/dxmt-tests/build-bcn-host-test.sh`: BC1 in both the four-colour and the
  three-colour punch-through mode (where index 2 is a HALF blend and index 3 is
  transparent black, the rule cut-out foliage is made of), BC2's
  replicate-not-shift nibble expansion over a colour block that must not punch
  through, BC3's eight- and six-interpolant alpha tables, BC4/BC5, odd extents
  with guard bytes proving partial blocks are clipped rather than written past,
  and 2x2 / 1x1 levels. 47 checks, 0 failures. On device,
  `build/x86-tests/d3d9dxt-x86.c` drives the same four cases through a real
  MANAGED DXT texture, a point sampler and a pass-through blend chain into an
  offscreen A8R8G8B8 target, reads it back with `GetRenderTargetData` and
  compares; it also asserts `CheckDeviceFormat` still advertises DXT1..DXT5,
  since a title that cannot find them does not degrade, it refuses to start. Its
  render target is four times the texture in each axis and each texel is read
  from its cell centre, so a half-pixel convention error cannot masquerade as a
  decode error. Every expectation it hard-codes was cross-checked against the
  real decoder before shipping. Run it as
  `C:\windows\syswow64\d3d9dxt-x86.exe`; PASS is `status=57`.
  MEMORY DOES NOT GROW, WHICH IS THE OPPOSITE OF THE OBVIOUS ANSWER. The RGBA8
  allocation was ALREADY being made — `remap_unsupported_bc` has been creating
  these textures uncompressed since the day the device stopped rejecting them,
  and `mem_census_texel_bytes` already charges BC1 at four bytes per texel, so
  the `tex-private live=438MB` in the device log is the decoded footprint, not a
  compressed one. Decoding fills memory that was already reserved and previously
  held nothing. The only new cost is transient: a staged upload is now 4-8x
  larger, so the upload ring will carry bigger blocks (it already provisions
  >16MB blocks on demand). A 16-bit decode target for opaque BC1 was considered
  and NOT taken: it would save nothing, because the allocation is decided at
  create time by the unix remap while "are all of this texture's blocks opaque"
  is only knowable after every future upload has been seen.
  WHAT TO LOOK FOR IN THE NEXT DEVICE LOG. `d3d9: adapter has no BC texture
  support` once at device create, then a `[bc-decode] textures=N levels=N
  MB_in=... MB_out=... ms=... (xN expansion, N MB/s out)` line every ten seconds
  while streaming, on its own wall clock so it does not wait for the
  present-counted census summary. `MB_out/ms` is the decode throughput and `ms`
  per ten seconds is what it costs against the frame budget. A `d3d9: no ring
  block available` warning would mean a decoded upload outgrew the ring and was
  dropped.
  LESSON: a format remap that happens below an interface boundary is invisible
  to everything above it, including the code that has to feed it. The remap here
  was correct and necessary — without it the descriptor does not validate — but
  it silently changed the meaning of every pitch the layer above computes, and
  the only reason the failure looked like two unrelated bugs is that one block
  size happens to satisfy the guard that the other trips.

- 2026-09-24 — **Where the CPU actually goes in the 32-bit D3D9 path, measured,
  and what is left to win.** The goal is 30 fps sustained; `[prof]` puts
  `d3d9-emulated.dll` at 17.4 % of all CPU in one open-world title and 5.4 % in
  another, so the frontend is the obvious suspect. The measurement says it is
  not the whole story, and names what is.
  THE PER-CALL BUDGET DOES NOT ADD UP, WHICH IS THE FINDING. The census counts
  7,860 D3D9 calls per frame in the first title against `busy=2.43 cores`;
  17.4 % of that is 0.42 cores, which at the frame rates in that log is on the
  order of a microsecond per D3D9 call. The entry points cannot cost that: every
  hot one already short-circuits on an unchanged value before it touches
  anything (`SetRenderState` `d3d9_device.cpp:6426`, `SetSamplerState` `:6806`,
  `SetTexture` `:6683`, `SetVertexShaderConstantF` `:11490` all compare first and
  return), `SetTexture` identifies its argument by vtable pointer rather than by
  a call through it, and `DrawPrimitiveUP` already sub-allocates its inline
  vertex data from a ring instead of creating a buffer per call. The resolution
  is in the thread table: `tid="dxmt-encode-thr"=13.5%(jit 81%)` — the encode
  thread's code IS `d3d9-emulated.dll`, so the module's share is mostly per-DRAW
  resolve and encode work, not per-CALL entry-point work. Micro-optimising state
  setters therefore cannot reach the goal, and the shape of the remaining win is
  per-draw, not per-call.
  WHAT WAS FIXED ANYWAY, BECAUSE IT WAS FREE. The census instrument itself was
  still paying what ml999 removed from the method counters: `shaderConstF()`,
  `lockBytes()` and `queryPoll()` did a `fetch_add` on a file-scope atomic, which
  on i386 under FEX is not an instruction but a TSO read-modify-write lowered to
  an exclusive-monitor sequence. `shaderConstF` runs on EVERY
  `Set{Vertex,Pixel}ShaderConstantF` — 2,602 + 2,428 per frame in one measured
  title, 1,569 + 1,087 in the other — ahead of the device lock and ahead of the
  short-circuit that makes the rest of the call cheap. All three now count into
  the existing per-thread block (`d3d9_census.hpp` `ThreadCounters`,
  `d3d9_census.cpp` `bump()`), which the summary already knew how to sum.
  Verified by disassembling the shipped object: `shaderConstF` ends in a plain
  `incl 0x4f4(%eax,%esi,4)` with no `lock` prefix, where it previously ended in a
  locked add. Honest size: about 150k emulated locked read-modify-writes per
  second removed, worth a fraction of a percent of a core — real, but not a
  frame-rate change.
  WHAT WAS DELIBERATELY NOT DONE, AND WHY. (a) Sub-allocating the small dynamic
  buffers. The census makes this look urgent — `DynamicBuffer created=9309
  LIVE=7009`, `buffers <=4K = 7581` — and it is not: those 7,581 buffers hold
  4 MB of a 212 MB total, and `reuse-hit=15152/15298 = 99 %` says the recycler
  almost never allocates. It is an object-count and residency question, not a CPU
  one, and the CPU is what is short. (b) The recursive device lock. `LockDevice`
  degenerates to a no-op unless the app passed `D3DCREATE_MULTITHREADED`, and no
  log in hand records that flag, so any work there would be optimising a path
  that may not execute; logging the behaviour flags at create is the cheap first
  step. (c) The phase-2 guest-side command ring (section 8.6). It remains the
  only change with the right shape — it attacks per-draw crossing cost rather
  than per-call overhead — but it is not a change that can be landed and verified
  in one pass, and a half-built ring is worse than none.
  LESSON: a module's share of a profile is not the same as its entry points'
  share. `d3d9-emulated.dll` contains both the API surface and the encode thread,
  and reading the 17.4 % as "the vtable is expensive" would have sent three
  rounds of micro-optimisation at the wrong half of it.

- 2026-09-24 — **fastsync's residual closed and `auto` made the default; the
  ARM64EC exit stub stopped walking a table it could never match; the
  default-on diagnostics moved behind one knob** (`build/ntdll-unix/shims/ios_fastsync.h`,
  `wine/dlls/ntdll/unix/sync.c`, `wine/server/event.c`,
  `FEX/Source/Windows/ARM64EC/{Module.S,IosJitAlias.cpp,Module.cpp}`,
  `FEX/FEXCore/Source/Interface/Core/Core.cpp`,
  `build/ntdll-unix/{signal_arm64_ios.c,virtual_ios.c,server_ios.c,winegstreamer_unixlib_ios.c}`,
  new `build/host-tests/fastsync-cellrace.c`).

  **1. THE FASTSYNC RESIDUAL IS GONE, AND IT WAS REAL.** ml982 documented it
  and declined to default the wake path on because of it: `madeira_cell_alive()`
  and the state CAS were two operations, so a cell freed and re-allocated
  between them let a client CAS consume a token out of a stranger's event —
  a lost wakeup on an object the thread never waited for. ml990 removes the
  gap rather than narrowing it. `{gen:63..32, state:31..0}` now live in one
  64-bit word (`cell->sg`), so **the CAS that takes a token is also the
  generation check**. There is no interleaving in which it can succeed against
  a cell that changed hands, because a change of hands IS a change of the word
  the CAS compares. Every access on both sides is a 64-bit atomic; the server
  rebuilds the whole word from the generation it read in the same load, which
  is exactly as unconditional as the plain `state = RESET` store it replaces.
  The futex still waits on the LOW half (`madeira_cell_futex()`), so a pure
  generation bump cannot wake a parked waiter spuriously, and every recycle
  changes the low half too (a free stores DISABLED and the bump in one store,
  where ml982 needed two).
  **MEASURED, not argued.** `build/host-tests/fastsync-cellrace.c` compiles
  BOTH shapes from the real shipping header and runs six clients against a
  thread that destroys and recreates the event behind a cell continuously. Each
  token the server mints is stamped with the epoch that minted it, so a theft
  is detected exactly rather than inferred. With one `sched_yield()` modelling
  the preemption both shapes genuinely allow between their two steps:
  **ml982 stole 695051–903249 tokens of ~5.1 M consumed across three runs;
  ml990 stole 0 of ~5.2 M with the same delay in the same place**, and 0 again
  with no delay at all. That is the residual reproduced, then eliminated.
  Residual (b) — a thread killed while parked leaks its `waiters` increment —
  is unchanged and remains cost-only (one spurious `os_sync_wake` per set on
  that cell).

  **2. `MADEIRA_FASTSYNC` NOW DEFAULTS TO `auto`.** ml982 gave two reasons not
  to, and both are answered: the lost-wakeup vector is the item above, and
  "nothing in ml972 or ml982 has ever executed on a device" is no longer true.
  Log y104 ran the whole mechanism with `MADEIRA_FASTSYNC=auto` through a
  32-bit job-system title, armed it (`[fastsync] AUTO-ENABLED after 181468
  event/select ops in 10000ms`) and reported **`desync=0`, `stale_gen=0`,
  `relearn=0` in every window**, while total server traffic fell from
  **15296/s in the pre-arm window to ~5200/s** in the steady windows after it —
  `event_op` 72982 → ~7700 per 10 s, `select` 62419 → ~25700. For contrast,
  x102 (ml972, fastsync fully off) sat at **33814–46537 req/s with 0.73–1.06
  core of server in-call time alone**. The arm stays conditional on the task's
  own request rate, so a launcher or installer never exercises the wake
  semantics at all — which keeps the class of program that died on the ml952
  snapshot on the path it survives. `MADEIRA_FASTSYNC=0` still forces
  everything off including the cells, and a new `MADEIRA_FASTSYNC=cells`
  reaches the old default.
  **TRAP FOUND AND FIXED WHILE DOING IT.** The "auto" rule lived inside
  `ios_srv_stats_report()` — which item 4 below puts behind `MADEIRA_DIAG`.
  Left there, the new default would have been `auto` in name only: the wake
  path would never have armed in a shipping build. It now runs from the
  compact `[perf]` line, which is the thing that still executes every 10 s when
  the reporters are quiet. The two callers are mutually exclusive by
  construction. Verified in the built archive by relocation:
  `_ios_perf_line` carries an `ARM64_RELOC_BRANCH26` to
  `_madeira_fastsync_auto_arm`.

  **3. `ExitFunctionEC` WAS WALKING A TABLE THAT COULD NOT CONTAIN THE ANSWER.**
  q1's `fexrt=10.3%` resolved to ONE function: `libarm64ecfex.dll+0x110adc` is
  `ExitFunctionEC+0xc`, and `+0x110b40`/`+0x110b54` are inside
  `ios_ec_xlate_loop`. `[ec-call]` said `faulted` was climbing by **14 M per
  10 s** while the unix side's real exec-fault redirects moved by **~2100 in
  the same window** — four orders of magnitude apart, so those were never
  faults. They are the RETURN half of the transition: on a call, x9 is a PE
  virtual address that must be translated to its pool copy; on a return, x9 is
  the instruction after a `blr x16` in an exit thunk that is ALREADY EXECUTING,
  so it is already a pool address. The alias table maps PeBase to JitBase, so a
  return address matched nothing — after walking every live entry (~50 x 6
  instructions), bumping a counter labelled "faulted", and falling through with
  x9 unchanged. **Unchanged was the correct answer all along.**
  The fix is five instructions in front of the scan: `IosAliasJitSpan` is
  `{lo, hi-lo}` over every registered `JitBase..+Size`, and `(x9 - lo) < span`
  answers it. Behaviour is identical by construction — both paths leave x9
  alone — and the one case in which it would NOT be, a live PE range
  intersecting the Jit span, is **checked rather than asserted**:
  `MaintainJitSpan()` publishes a zero span the moment that becomes true, and a
  zero span makes the compare always fail, which is the pre-ml990 path
  instruction for instruction. `MADEIRA_EC_POOL_FASTOUT=0` installs the same
  zero, so the knob and the safety net share one mechanism and one tested code
  path. The counter is split: `[ec-call] translated=N faulted=M inpool=P`,
  where M is finally the "the alias table is missing an image" signal it was
  written to be. **EXPECTED GAIN: most of `fexrt=10.3%`** on a 64-bit title,
  of which `ExitFunctionEC+0xc` alone was 4.5–7.2 % of ALL CPU across fifteen
  gameplay windows. Verified in the shipped `xtajit64.dll` disassembly:
  `ldp x17, x4, [x16]` / `sub` / `cmp` / `b.lo <ios_ec_xlate_inpool>` at
  `0x180110afc`, ahead of the last-hit cache.

  **4. ONE KNOB FOR THE DIAGNOSTICS: `MADEIRA_DIAG`.** ml649 built
  `madeira_set_diag_enabled` and then gated two rate-limited trace lines with
  it, while everything that actually costs something stayed unconditionally on.
  `madeira_diag_on()` is now the single answer — the OR of `MADEIRA_DIAG=1` in
  `Documents/madeira-env.txt` and the live app switch — and the default is
  quiet. Gated: the 200 Hz `[prof]` sampler (~8–9 k Mach traps/s across ~40
  threads, plus a 27-line report every 10 s); the 20 s all-thread stack walk
  (`ios_dump_all_thread_stacks`, **1726 lines in x101, the loudest tag in the
  log** — gated at the walk, not at the timer, because the expense is the
  `thread_get_state`+`thread_info`+frame walk+`dladdr` per thread); the 10 s
  `ios_pump_sample()` bundle (`[waiters]`/`[hot-lock]`/`[alert-ring]`/
  `[lock-census]`, a few hundred traps per call); the `[srv-stats]` ten-line
  report **and with it the two `mach_absolute_time()` calls and the caller-PC
  frame hop on every server request**; the `[footprint]` six-field line; and
  FEX's `[CB_SUMMARY]` Boyer-Moore hot-RIP estimator, which did **two
  bus-locked RMWs on process-wide words on every C++ CompileBlock dispatch —
  42–65 k/s by its own `[fex-stats]` line** — to maintain a hint whose own
  comment says `[prof]` is what decides anything.
  Kept unconditional: every crash and boot diagnostic (SEGV/BUS handlers, Mach
  exception backtraces, `MADEIRA-EXIT` and its forced final `[srv-stats]`, the
  DEP and dispatcher banners, `[build-id]`), the `task_info()` that says how
  close the run got to the jetsam ceiling, and **one compact `[perf]` line
  every 10 s** carrying footprint, `srv=N/s` and the fastsync counters. Nothing
  in that line is measured for it: every number was already being counted for
  another reason. fps is deliberately absent — the app knows it.
  Two things are *reduced* rather than gated because they are crash
  diagnostics: `malloc_zone_check()` (which walks every block of a
  multi-gigabyte heap) drops from every 10 s to every 60 s, widening its
  corruption bracket from ~10 s to ~60 s of log for a 6x cost cut; and the
  `[wma]` per-packet lines — **~8 write(2) calls per audio packet on the audio
  thread, 1610 lines in x101** — gain a hard cap of 200, which keeps the start
  of a stream (where every interesting WMA failure is) and stops a failing
  stream turning a decode problem into a logging problem.
  A per-subsystem knob that is explicitly SET still wins, so `MADEIRA_PROF=5`
  arms the profiler in an otherwise quiet build and `MADEIRA_SRV_STATS=1`
  restores the full report.

  **5. THE L1 LOOKUP-CACHE QUESTION NOW HAS NUMBERS.** `DisableL2Cache=1`
  means every inline-L1 miss is a full C++ round trip under a shared read lock,
  and nothing reported how often that happened or what it cost. `[fex-stats]`
  gains `l1_miss_l3hit=+N (N/s, P% of dispatches)` — dispatches that did NOT
  end in a real compile, i.e. blocks the process had already compiled that only
  the locked L3 map could find. **That is precisely the traffic a bounded L2
  would absorb, and therefore the upper bound on what restoring one could
  recover**, in units that can be acted on. It also gains `l1_entries=N
  ways=W`, derived from the reporting thread's own `State.L1Mask`, which
  answers "what does `DynamicL1Cache` actually grow to?" — a question that had
  no data behind it because `CurrentL1Entries` was private and never printed.
  Both inputs were already being counted, so the line costs nothing new, and
  `g_cb_total` is now batched per thread (one un-contended thread-local
  increment per dispatch, one global add per 512) so the counter is no longer a
  contention artefact in the measurement it feeds.

  **INVESTIGATED AND REJECTED.**
  (a) **The 32-bit title's `unresolved=25.6%` of all CPU is a PROFILER
  ATTRIBUTION HOLE, not hidden dispatcher cost. Do not chase it.** Three
  things settle it. `jitdisp` — the bucket for PCs inside the published
  dispatcher extent `[0x139374000,0x13937645c)` — is **0.0–0.2 % in every
  window**, so the dispatcher is not where the time is. The unresolved PCs are
  at `0x138b1d8f8/0x138b1d944/0x138b1dd00`, ~8 MB BELOW the dispatcher, i.e.
  in the block pool. And the same host PCs **flip between resolved and
  unresolved from window to window** (x101: resolved at lines 3457, 4393,
  5040, 6441, 6606, 6932, 8339, 8790, 8956; unresolved at 3008, 3733, 4859,
  5411, 5589, 5902, 6117, 7109, 7461, 7654, 7979, 8792, 9317) while naming the
  same guest RIP (`rip=0x79e39207`) whenever they do resolve. A real
  dispatcher PC cannot be a guest block in alternate windows. The hole is in
  `ios_profmap`'s ring join, not in the emulator, and the emission counters
  confirm the ring is not wrapping (13509 blocks of a 65536 cap, +6 per window
  in steady state). **There is no quarter of the CPU to reclaim here** — the
  real distribution is the resolved one: main exe ~16 %, `d3d9-emulated.dll`
  ~15 %, `ucrtbase.dll` ~9 %.
  (b) **A bounded L2 was NOT built this round.** The measurement that decides
  its size and shape — `l1_miss_l3hit/s` — did not exist until item 5, and
  upstream's L2 reserves ~512 MB of VA per thread against a band that ml387
  already shrank the per-thread lookup allocation for twice. Building it blind
  would have repeated ml363/ml387. Read the number first.
  (c) **A semaphore analogue of fastsync was NOT built.** q1's gameplay
  regime is a rigid `select` / `release_semaphore` duopoly at ~96 % of all
  requests and a near-exact 1:1 pairing (47845/45774, 46570/44600,
  41493/39681, …), with `select` ~95 % `w1 inf` — so the shape is right and
  the win would be large. But a semaphore carries a COUNT, not a token, and
  `ReleaseSemaphore` has a previous-count return value and an overflow status
  that a client-side CAS would have to reproduce exactly; that is a different
  proof obligation from the event cell, not the same one with a different
  field. Doing it on the same evidence standard as ml990 needs its own round
  and its own host model. Flagged, not attempted.
  (d) **IOKit is not ours to fix from here.** q1's `mach_msg2_trap<-IOKit 4.5%`
  and `iokit_user_client_trap ~2.4%` (together **~5–10 % of all CPU**) are
  Metal, not input: the backtraces are IOKit's `IOConnectCallMethod` into
  IOGPU on the guest main thread, and `IOGPUCommandQueueSubmitCommandBuffers`
  on Metal's libdispatch threads. No repo source calls IOKit. The per-frame
  `nextDrawable`/commit lives in the prebuilt DXMT archive, which this round
  must not touch.
  (e) **`[d3d9-census]`'s per-call instrument is the largest remaining
  default-on diagnostic and belongs to another owner.** It is documented at
  **2602 + 2428 API calls per frame** and `readEnabled()` defaults it ON.
  `research/dxmt/**` was out of scope this round; it should get the same
  `MADEIRA_DIAG` treatment.

  **BUILD TRAP WORTH KNOWING.** A previous round left copies of
  `ios_fastsync.h` (and `ios_srv_stats.h`) next to the sources in the xtool
  workspace — `wine/server/`, `wine/dlls/ntdll/unix/`, `build/ntdll-unix/` —
  in addition to the canonical `build/ntdll-unix/shims/` one. A quoted
  `#include` searches the including file's own directory FIRST, so those stale
  copies silently win over `-I.../shims` and the first build of this round
  compiled the OLD struct against the NEW code. It failed loudly (17 errors)
  only because the struct member was renamed; a change that merely altered a
  VALUE would have built clean and shipped the wrong one. All four copies must
  be refreshed together.

  **VERIFIED BY BUILDING AND READING THE ARTIFACTS.** `ntdll-unix` 32/32,
  `wineserver` all 18 files, both FEX modules link clean. `libntdll_unix.a`
  1888760 B and `libwineserver.a` 1248328 B, `xtajit.dll` 4706304 B,
  `xtajit64.dll` 5255168 B. Content, not just timestamps:
  the `rev=ml990 … gen-packed` banner is present and the `rev=ml982 mode=`
  one is gone; `event.o` carries seven 64-bit `ldaxr x*`/`stlxr` pairs for the
  cell RMWs and two 32-bit ones for the `waiters` counters; `xtajit64.dll`
  disassembles to the new `b.lo <ios_ec_xlate_inpool>`; `[perf] rev=ml990`,
  `[ec-call] … inpool=%llu`, `l1_miss_l3hit` and the `[wma]` cap string are all
  in the archives; and `_ios_perf_line` relocates to
  `_madeira_fastsync_auto_arm`. Host models: `fastsync-cellrace` exit 0 (the
  contrast above), `sync-x86.c` all ten tests against the POSIX model exit 46
  with 488332 jobs each consumed exactly once. **VERIFIED BY REASONING ONLY:**
  the server-side 64-bit rebuild being equivalent to the 32-bit store it
  replaces, the in-pool fast-out's disjointness guard, and every claim about
  what the quiet default still prints.

  **WHAT TO READ IN THE NEXT DEVICE LOG — AND WHY IT TAKES TWO RUNS.**
  `[ec-call]` is printed from inside the `[prof]` reporter's window, and
  `[prof]` is now off by default, so **the mechanism run and the measurement
  run are different runs**, which is the right methodology anyway: one with
  `MADEIRA_DIAG=1` to confirm every mechanism did what it claims, and one
  without it to measure the fps the quiet default actually delivers. Comparing
  fps between the two also prices the diagnostics themselves, which nobody has
  ever measured directly.
  In BOTH runs: `[fastsync] rev=ml990 mode=auto`
  at boot, then `[fastsync] AUTO-ENABLED` within the first busy window, then
  `[perf]` every 10 s with `srv=` an order of magnitude below x102's
  33814–46537/s and `desync=0` — a non-zero `desync` is the one alarming
  number and demotes only the one object it names. `[fex-stats]` is not gated
  and prints in both.
  In the `MADEIRA_DIAG=1` run, `[ec-call]` should now show
  `faulted` nearly FLAT (it should track `exec-fault redirects`, ~200/s, not
  ~1.4 M/s) with `inpool` carrying what `faulted` used to; if `faulted` is
  still in the millions the in-pool test is not firing and `IosAliasJitSpan`
  is zero — check the `[build-id]` line for `EC in-pool fast-out ENABLED`.
  `[fex-stats]` gives `l1_miss_l3hit/s` and `l1_entries`: if `l1_entries` has
  settled at the 128 K ceiling and `l1_miss_l3hit/s` is still tens of
  thousands, the L1 is capacity-bound and the bounded L2 is worth building; if
  `l1_entries` is small, the growth heuristic is the thing to fix first. The
  log should otherwise be quiet — no `[prof]`, `[thread-stacks]`,
  `[srv-stats]` detail, `[hot-lock]` or `[footprint]` lines — and
  `MADEIRA_DIAG=1` should bring all of them back.

- 2026-09-25 — **REGRESSION, every program died at start on every device:
  a `thread_local` was added to the emulator module.** The previous round
  batched FEX's dispatch counter in a `static thread_local` inside
  `ContextImpl::CompileBlock` (FEXCore/Source/Interface/Core/Core.cpp). All five
  device logs die at the same instruction, `libwow64fex.dll+0x13770`:
  `ldr x9, [x10, x9, lsl #3]` with x10 = TEB->ThreadLocalStoragePointer = NULL
  — implicit TLS in a PE DLL is reached through the TEB's TLS vector, and the
  threads the emulator compiles on do not have one populated by this loader.
  Replaced by a plain unlocked increment of the shared word (a statistic may
  lose a count; it costs no bus lock either). Verified by disassembly: the site
  is now load/add/store, and `[x18,#0x58]` reads in the DLL went 3 → 2 (the two
  that remain predate the regression and shipped in working builds).
  RULE: no `thread_local` in `xtajit*.dll`; per-thread emulator state lives in
  the FEX thread object. The host model and the artifact checks of that round
  could not catch this — only a boot can; a change to the emulator DLLs should
  be assumed unverified until one has happened.

- 2026-09-26 — **Silent tablet, healthy engine: the audio SESSION, not the
  mixer.** Tablet logs show `[audio] stream … peak=1.618`, the RemoteIO IO
  thread running and the bus limiter engaging (`27 blocks limited`), i.e.
  samples with real signal are rendered — and the user hears nothing; the phone
  is fine. Everything downstream of the render callback belongs to
  AVAudioSession: category, activation, route, volume. A session that is not in
  the Playback category obeys the tablet's Silent Mode (a Control Centre toggle
  there) and is muted with no error anywhere. The old code set the category
  once at session start and reported through `os_log` only, so neither a
  failure nor a later override could appear in the exported log (last round's
  `[audio-route]` line went the same way and never showed up).
  `madeira_audio_session_ensure()` (app/Madeira/WineProcessBridge.m) now sets
  Playback + activates (retrying as mixable if a non-mixable activation is
  refused), writes category/options/active/outputs/outputVolume/sampleRate/
  otherAudioPlaying to stderr, and is re-run on interruption-ended, route
  change (not on our own category change) and media-services reset, and by the
  audio driver every time it starts the output unit (weak symbol in
  `audio_null_ios.c ios_engine_start`). UNVERIFIED on the tablet; the
  `[audio-route] why=…` lines in the next log name the cause if it persists
  (`outputVolume=0.00`, a non-Playback category, `active=0`, or an unexpected
  output port).

- 2026-09-27 — **A 64-bit managed-runtime engine title fast-fails (0xC0000409)
  before its first frame: its per-user data folder did not resolve.** Log t44:
  all DLLs load, then `[file-wfail] status=0xc000003a … name=\??\C:\<game
  dir>\<Company>\<Product>\output_log.txt` — a path RELATIVE to the current
  directory, i.e. the engine's base path for LocalAppDataLow came back EMPTY —
  and immediately `int 29` with code 5 (FAST_FAIL_INVALID_ARG) from the
  engine's runtime: the NULL stream from the failed open went into the CRT,
  whose invalid-parameter handler fast-fails. shell32 only answers a per-user
  known folder whose directory exists (no KF_FLAG_CREATE from the caller). The
  AppData skeleton was created once, marker-gated, under ONE hard-coded profile
  name; the live profile directory is named after the host account.
  `madeira_ensure_appdata()` (WineProcessBridge.m) now does `mkdir -p` of
  AppData/{Roaming,Local,Local/Temp,LocalLow} for EVERY directory under
  `drive_c/users` (except Public) on EVERY launch and logs `[profile] AppData
  skeleton ensured for: name(+created) …`. UNVERIFIED on device. If the title
  still fast-fails with the same relative path while `[profile]` shows the
  folder present, the next suspect is the known-folder lookup itself in the
  x86-64 shell32 (registry value for the LocalAppDataLow GUID / USERPROFILE).

- 2026-09-28 — **`GetTickCount64()` returned 0 to every guest program for the
  whole life of this port, and a 64-bit managed-runtime engine title turned
  that into an unkillable 100 %-CPU spin on its loading screen.**
  THE SYMPTOM. One worker thread of a 64-bit title sits at 100 % of a core
  (`jit 100 %`) for minutes inside ~0x80 bytes of the engine DLL, RVA
  0x112e463..0x112e4e1; every other worker is parked in
  `NtWaitForSingleObject`; `real_compile=+0`, no file I/O, no server request,
  no fault anywhere near it. Three logs, three devices, two OS versions, two
  address layouts (engine DLL at 0x70fccf0000 and at 0x3feaf0000), with
  `MADEIRA_FASTSYNC` on and off, different worker indices — byte-identical
  failure every time. Deterministic to that degree is not a race.
  WHAT THE LOOP IS. The function at engine RVA 0x112e430 is a Sleator top-down
  splay: `Node *splay(struct timeval key /*packed in rcx*/, Node *t)` over
  `{smaller@+0, larger@+8, same@+0x10, key@+0x18, payload@+0x20}`, with the
  header node on the stack at `[rsp]` and the searched key at
  `[rsp+0x40]/[rsp+0x44]`. It is **libcurl's timer splay** (`Curl_splay`),
  statically linked into the engine; the callers are `Curl_splayinsert`,
  `Curl_splayremove`, `Curl_splaygetbest`, `multi_timeout` and, above those,
  `Curl_expire`. The node is not allocated: it is an intrusive
  `struct Curl_tree` embedded in the easy handle at `+0x8a48`, with `payload`
  pointing back at the handle. The `[prof]` histogram (0x4c6, 0x4ca, 0x4d2,
  0x4d9, 0x4e1, 0x463) says the thread takes the right-right zig-zig arm on
  EVERY iteration and never once takes the left arm.
  IT IS A CYCLE, AND NO EMULATION DEFECT CAN PRODUCE IT. This was settled on
  the build machine rather than argued, by transcribing the loop
  instruction-for-instruction into a host model: (a) 20,000 random acyclic
  trees x random keys all terminate; (b) **50,000 acyclic shapes driven by an
  ARBITRARY comparator all terminate** — every arm of the loop moves `t` to a
  node reachable by one or two links of the ORIGINAL tree, so descent is
  structural, not predicate-driven, and therefore *no* wrong branch, lost
  NZCV, mis-set `setg`/`test`, or bad 32-bit signed compare can hang it; and
  (c) an exhaustive enumeration of every graph on <=3 nodes finds 5,555
  non-terminating shapes matching the device's instruction mix, all of which
  require a cycle whose nodes keep BOTH children inside the cycle. The
  hypothesis "guest flags lost across a host fault" is dead twice over: the
  Mach handler round-trips the whole `arm_thread_state64_t` (`__cpsr`
  included — nothing in `signal_arm64_ios.c` ever writes it), and no fault of
  any kind lands in that block during the hang (`[fault-class]` attributes
  every fault to blockRIPs in ntdll/FEX, never to the engine).
  THE CORRUPT NODE, READ OFF THE DEVICE. The existing `[spin]`/`[tree]`
  detectors already captured it. Tablet log, 64 bytes at the node:
  `smaller = larger = same = 0x30c8689d8` — **the node is its own left child,
  its own right child and its own duplicate-chain link** — `key =
  0xffffffffffffffff` = libcurl's `KEY_NOTUSED {-1,-1}`, and `payload =
  0x30c85ff90`, exactly `node - 0x8a48`. The phone logs show the same shape at
  a different address. A `-1` key is smaller than every real key, which is
  precisely why the left arm never runs.
  ROOT CAUSE: A CLOCK THAT DOES NOT TICK. The qword immediately before the
  node is `state.expiretime` (easy handle `+0x8a40`), and in all three runs it
  reads **`{tv_sec = 0, tv_usec = 1000}`** — minutes into the process.
  `Curl_tvnow()` on Windows is `GetTickCount64()` with
  `tv_sec = ms/1000, tv_usec = (ms%1000)*1000`, so that value is only
  reachable if `GetTickCount64()` returned **0**. It did, for every guest
  program this port has ever run: `GetTickCount`/`GetTickCount64` in
  kernelbase are nothing but three loads from `KUSER_SHARED_DATA.TickCount`,
  and that page was never written. The server's publication
  (`set_current_time()`, `build/wineserver/fd_ios.c:538`) and the writable
  alias that makes it possible (`create_user_data_mapping()`,
  `build/wineserver/mapping_ios.c:1547`) were both behind an opt-in
  `MADEIRA_USD_TIME=1`; a `SEC_COMMIT` mapping starts zeroed. ml951 found the
  same frozen page from the other side, fixed win32u's own `get_tick_count()`
  by reading `CLOCK_MONOTONIC_RAW` instead, and said in its comment that the
  guest-facing clock was "a separate, already-documented issue". It was the
  whole bug.
  HOW ZERO BECOMES A SELF-LINKED NODE. `Curl_expire(data, milli)` uses
  `data->state.expiretime == {0,0}` as its sentinel for "this node is NOT in
  the tree", and skips `Curl_splayremove` when it sees it. With the clock stuck
  at 0, `Curl_expire(data, 0)` computes `set = tvnow() + 0 = {0,0}`, removes
  and re-inserts correctly, and then stores `{0,0}` into `expiretime` — so the
  node is IN the tree while its own sentinel says it is not. The next
  `Curl_expire` therefore inserts a node that is already linked: `Curl_splay`
  brings it to the root, `compare(i, t->key) == 0` with `node == t`, and the
  equal-key arm executes `node->same = t; t->smaller = node; t->key =
  KEY_NOTUSED` with `t == node`, writing the node's own address into its own
  links and `{-1,-1}` into its own key. Every later splay walks that node
  forever. Nothing about this is program-specific: any guest that keys a
  container on the tick, or reserves 0 as "unset", collides every entry
  against every other one.
  THE FIX. `ios_usd_time_enabled()` now defaults ON, with `MADEIRA_USD_TIME=0`
  as the kill switch that restores the frozen page exactly (mapping included).
  The reason the gate existed is itself already fixed, and the comment that
  records it is in the build script: wineserver and ntdll-unix BOTH define
  `user_shared_data`, the single-process link merged them, and guest ntdll
  init (`user_shared_data = NULL; NtAllocateVirtualMemory(..., PAGE_READONLY)`)
  stole the server's pointer and aimed it at a read-only page — so the
  server's next store wedged the main loop. The `objcopy --redefine-sym
  _user_shared_data=_ws_user_shared_data` sweep in
  `build/wineserver/build.sh` removed that collision; the opt-in gate outlived
  the defect it was protecting against. `create_user_data_mapping()`
  additionally calls `set_current_time()` once, at creation, before any client
  exists, so the page is never observed at zero in the window before the
  server's event loop first runs — which matters because 0 is not merely a
  wrong time, it is a reserved value.
  MADE VISIBLE, BECAUSE A CLOCK ONLY REVEALS ITSELF THROUGH ITS VICTIM.
  `[usd-clock]` prints the guest's `GetTickCount64()` once, at the moment the
  page becomes readable, and says FROZEN AT ZERO in as many words if it is;
  and the quiet-default `[perf]` line gains `tick=Nms`, one relaxed 64-bit
  read every ten seconds, so "does the guest clock advance" is answerable from
  any log from now on without re-running anything.
  THE TIGHT-LOOP WATCHDOG (`[tight-loop]`, `ios_tight_loop_tick()` in
  `signal_arm64_ios.c`, called from the pool-warmer's 250 ms tick in
  `virtual_ios.c`). The `[spin]`/`[tree]` pair that produced the decisive
  evidence above lives inside the 200 Hz profiler, which is off by default —
  a shipping build could not have reported this at all. The watchdog is
  default-ON and silent: it samples at 2 Hz, gates on
  `thread_info().cpu_usage >= 900` before it costs a second trap, and prints
  nothing until a registered thread has stayed inside one 2 KB window of HOST
  pc for more than eight seconds. Then, once per episode and at most eight
  times per process, it dumps the guest x86-64 register file (out of FEX's
  `CpuStateFrame` via TEB+0x1788 -> +0x30, using the offsets FEX publishes in
  `[state-offsets]`), 128 bytes of guest code at rip, 64 bytes at every
  register that points at readable memory, and a bounded <=64-step chase of
  `*(reg+0)` and `*(reg+8)` from each of them reporting the FIRST REPEATED
  ADDRESS with the node's bytes. Those two offsets are the left/right or
  next/prev of essentially every intrusive node layout, so the cycle test is
  generic rather than tuned to this structure. Every guest byte is read with
  `mach_vm_read_overwrite` — there is not one guest dereference in it, which
  is the point, since the thread it samples is by definition sitting on
  corrupt memory — it takes no lock, allocates nothing, uses no
  `thread_local`, and `MADEIRA_TIGHTLOOP=0` turns it off. The window is
  measured on the host pc deliberately: FEX's published `State.rip` is
  block-granular and in t45 it named a different function from the one
  executing.
  THE 450/s EXEC-FAULT REDIRECTS: CHARACTERISED, NOT YET REMOVED. Steady state
  still takes ~450 `exec-fault redirects` a second, each a full Mach exception.
  The hot targets resolve exactly: ntdll is at 0x70ffcd0000+0x130000 -> pool
  0x1190a8000, so 0x70ffd38b58 is ntdll RVA 0x68b58 and 0x70ffd25100 is RVA
  0x55100; `[EXC_SAMPLE]` catches one with `insn=0xd10103ff`
  (`sub sp,sp,#0x40`) — a function PROLOGUE, i.e. a CALL through a stale PE VA,
  not a data access. `[stale-heal]` reports `rewrote 0 slot(s)` for both, and
  that is informative rather than a failure: its escalation pass scans every
  registered module copy's whole image minus `.text` for the exact 8-byte
  value, so the pointer is provably NOT in any module copy — it lives in an
  anon executable range, the guest heap, or an immediate inside emitted code,
  none of which the scanner can reach. The only thing that separates those is
  where the call came from, so the redirect path now prints `[stale-src]`
  (four lines per distinct target, then silent) carrying LR and whether LR is
  inside a registered module copy. That names the owner in the next log;
  nothing is rewritten on a guess.
  VERIFIED. `ntdll-unix`, `win32u-unix` and `wineserver` all build and link
  clean, and the archives are checked BY CONTENT for the new strings and
  symbols, not by exit status. The splay model and the shape enumeration are
  host-run, reproducible, and answer a question no device log could.
  UNVERIFIED ON DEVICE: that the clock now advances, that the title loads, and
  that the watchdog behaves — by construction it should now print nothing at
  all, which is the success condition. The next log should show
  `[usd-clock] … ticking` at boot, `[perf] … tick=` advancing by ~10000 per
  window, no `[tight-loop]` line, and `[stale-src]` naming the caller of the
  two ntdll redirect targets.
  LESSON. A stopped clock is not a missing feature, it is an API returning a
  wrong answer, and the cost of a wrong answer is paid by whichever data
  structure reserves that value as a sentinel — arbitrarily far from the
  clock, arbitrarily long after the call, and with a symptom (100 % CPU in a
  twenty-byte loop) that looks exactly like an emulation defect and is not. It
  had been known and documented for two rounds and left opt-in because the
  crash that originally motivated the gate was never re-attributed; that crash
  was a symbol collision, and something else had already fixed it.
