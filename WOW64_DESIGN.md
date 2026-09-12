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
should settle. **Stage 3 onward is blocked on it.**

### 7.3 Stages and file ownership

| Stage | Owner | Files | State |
|---|---|---|---|
| 1. i386 PE build stage; acceptance test; guest-pointer conversion mechanism | DXMT | `build/dxmt-ios/build-pe.sh`, `.xtool/build-dxmt.sh`, `build/x86-tests/d3d9-cube-x86.{c,exe}`, `build/x86-tests/build-d3d9-cube.sh`, `research/dxmt/{meson.build,src/winemetal/unix/winemetal_unix.c}` | **done, §7.8** |
| 2. Licensing decision + notices | fork owner | `research/dxmt/{LICENSE,COPYING.LIB}`, `LICENSE-MADEIRA.md`, `THIRD-PARTY-NOTICES.md` | **blocks 3–5** |
| 3. airconv DXSO/FFP import | DXMT | `research/dxmt/src/airconv/{dxso_header.hpp,dxso_decoder.hpp,dxso_compile.{hpp,cpp},ffp_compile.{hpp,cpp}}`, the DXSO half of `airconv_public.h`, deltas to `nt/air_builder.*`/`air_signature.*`/`air_operations.cpp`/`air_type.cpp`, `src/airconv/meson.build` | not started |
| 4. `src/d3d9` import + API reconciliation | DXMT | `research/dxmt/src/d3d9/**`, `src/meson.build` | not started |
| 5. Slot + wow64 table completion | DXMT | `src/winemetal/airconv_thunks.{h,c}`, `src/winemetal/unix/winemetal_unix.c`, regenerate `wmt_api_names.h` + `unix/wmt_remote_guard.h`, extend `gen_remote_guard.py` | mechanism done, 37+5 slots outstanding |
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
2. **APP — launch button.** Add one entry to `thirtyTwoBitTests`
   (`app/Madeira/ContentView.swift:858-863`), which is a
   `[(label: String, exe: String)]` rendered with `id: \.exe` at `:1518-1531`:
   `("D3D9 cube", "d3d9-cube-x86.exe"),`. Nothing else — the renderer already
   sets `MADEIRA_EXE`, and `WineProcessBridge.m` detects i386 by real PE
   machine (`:674-694`) and resolves it to
   `C:\windows\syswow64\d3d9-cube-x86.exe` (`:918-925`). The exe is already
   installed in `app/Madeira/i386-windows/`, which the probe at `:688-690`
   requires.
3. **Fork owner — licensing (§7.2).**
