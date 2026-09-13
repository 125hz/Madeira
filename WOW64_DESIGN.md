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
