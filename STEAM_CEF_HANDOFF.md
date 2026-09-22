# Madeira — Steam/CEF on a jailed iPhone: state of play, evidence, and dead ends

**Purpose:** hand an outside agent enough context to propose *new* ideas. Written 2026-08-05.
Everything below is either **CONFIRMED** (log- or binary-verified), **REFUTED** (tested and
disproved — please don't re-propose these), or **OPEN**. I have been wrong several times on
this project by asserting plausible mechanisms without a discriminator, so the labels matter
more than the prose.

---

## 1. What this project is

Run real x86-64 Windows games and the real Steam client on a **stock, non-jailbroken iPhone 13
Pro (A15, iOS 27.0 db3)**, sideloaded with a **free Apple ID**.

Stack, top to bottom:

| Layer | What it is |
|---|---|
| SwiftUI/Metal host app | `app/` — iOS app, owns the window, compositor, input, audio |
| Wine 11.4 fork (**ARM64EC**) | Windows API. `wineserver` runs as a *thread*, not a process |
| FEX-Emu fork | x86-64 → ARM64 JIT, entered via `xtajit64.dll` (ARM64EC "Path B") |
| DXMT | D3D11 → Metal |

**The single most important architectural fact:** every Windows "process" (steam.exe,
steamwebhelper.exe, services.exe, rpcss…) is a **pseudo-process — a thread inside ONE Mach
task**. There is no process isolation. *Any* unhandled fault in *any* Windows "process" kills
the entire app. This is why so much effort goes into fault containment.

### Hard constraints (non-negotiable)

- **Free Apple ID sideloading only.** No paid entitlements, no jailbreak, 7-day provisioning,
  max 3 apps. JIT is obtained via **StikDebug** (a debugger attaches, we `BRK`, it grants
  `CS_DEBUGGED`). After the debugger detaches, **no new executable mappings can be created** —
  so all JIT memory must be reserved up front as one dual-mapped RX/RW pool.
- **Usable CPU virtual address space is ~64 GB**, not 512 GB. iOS reserves a GPU carveout at
  `[64G, 448G)` that is *xnu-proven undefeatable* (tested extensively; do not re-litigate).
  This is why Steam+CEF must be single-process.
- **Jetsam ceiling is exactly 4096 MB.** Runs currently peak ~3.0–3.4 GB.
- VA map, never to be violated: guest ≤ `0x73ffff0000` · CEF's four 16 GB PartitionAlloc pools
  `[0x74, 0x7c)` · FEX host + arena `[0x7c, 0x80)`.

### Status

- **Thumper (x86-64) is PLAYABLE** with audio, 142 FPS typical / 2286 peak.
- **Steam's CEF login window RENDERS AND IS INTERACTIVE** (hover works, clicking the QR-refresh
  works). This is the current frontier. It is reached via a ladder:
  `BrowserReady → transport (0 rejects) → GetDesiredSteamUIWindows → PopupHTMLWindow → BrowserReady 131073`.
- Steam CEF = **Chromium 126.0.6478.183**.
- **CrossOver on macOS runs this same Steam client correctly**, which is a useful control: the
  bugs below are in *our* stack, not in Steam or CEF.

---

## 2. The three open problem families

### 2.1 RENDER CORRUPTION — tile-granular displacement (OPEN, hardest)

**Symptom.** The Steam login/splash renders, but content is displaced. Duplicated Steam logos
appear in different tiles; there are visible seams at x=185 and at tile boundaries.

**CONFIRMED:**
- Chromium rasters **256×256 tiles with 1px border texels ⇒ 254px interior pitch**. Observed
  seams land on 254/508 — i.e. corruption is **tile-granular**, not pixel-random.
- A Hough-circle fit on the splash logo (robust to occlusion; template matching failed because
  the panel is too uniform) gave a displacement of exactly **(−254, −253)**.
- A constant **(−550, −97)** offset also appears; the QR "halo" displaces *independently* of its
  own QR code ⇒ **per-draw-op destination error**, not a whole-surface offset.
- **Every layer we own is exonerated**: our compositor, our flush path, `dibdrv_PutImage`
  (11/11 byte-exact), all four GDI entry points, alpha handling, and concurrency.
- Blit is exact (SRC ≡ SURF). Damage rectangles never land on the tile grid.
- Insensitive to AVX.

**REFUTED / SPENT (do not re-propose):**
- All three Chromium switches tried. ⛔ `--disable-threaded-compositing` is **VOID** — it breaks
  frame production entirely.
- All memory-ordering hypotheses: vector/memcpy TSO changes had **no effect** (reverted).
- SIMD-dropped-stores; missing-invalidate.
- The `srcwatch` probe family has a **hard ceiling** — it cannot see further. Stop iterating on it.
- Two of my own measurement claims were **RETRACTED**: (a) a (+1,−1) tile offset that turned out
  to be a menu artifact (the search only offered `{0, ±254, ±508}`) compounded by treating
  correlated samples as independent; (b) a whole-login-screen ±1-tile measurement where 0/77
  patches passed a ratio test. **Any offset claim must pass a ratio test** (best match vs. best
  match elsewhere) or it is noise.

**Current best hypothesis:** deterministic **misexecution of Chromium under FEX** — i.e. a JIT
correctness bug that produces wrong destination addresses in Skia's raster/compositing path.
Note that FEX passes a 28/28 float/SSE conformance test we wrote (`build/x64-tests/fpconf-x64.c`),
so it is not a basic FP/SSE issue.

**Untried idea worth considering:** lift Chromium 126's compositing code into a standalone test
PE so the failure can be reproduced and bisected offline without a 40–60 s device run.

**Separate, real, also open:** login-window black pixels are **alpha = 0** — Chromium composites
onto transparency and our BGRX surface renders RGB 0 as black. Needs a **per-window** alpha gate.

---

### 2.2 THE RECURRING CRASH — `libcef.dll+0x41258FB` (OPEN, newly characterized)

Every run that reaches the login window dies here. As of the latest run (ml559) we finally have
the **exact fatal fault**:

```
[fault_rip] cnt=127 rip=0x71e5a358f0 pc=0x14a59d140 addr=0x70f1ee0000
            kr=10 entryprot=3 nowprot=3 region=0x70f1ed0000+0x14000 [first]
[bus-reheal] #1 restored prot=3 on 0x70f1ee0000
             (wine says committed+readable; host had stripped it) — resuming
→ c0000005 at 0x71E5A358FB  (libcef.dll+0x41258FB)
→ VEH handlers all return 0 → SEH → NtTerminateProcess(0xffff7001)
```

**What is confirmed by these lines:**
- The faulting *data* address `0x70f1ee0000` is **inside** the reported region
  `[0x70f1ed0000, 0x70f1ee4000)` (20 pages).
- It was **RW at handler entry and still RW during the handler** (`entryprot=3 nowprot=3`).
  Mapped. Writable. Page-aligned.
- `kr=10` is **`KERN_MEMORY_ERROR`** — *not* `KERN_INVALID_ADDRESS` (1), *not*
  `KERN_PROTECTION_FAILURE` (2), *not* `EXC_ARM_DA_ALIGN` (257). It occurred **exactly once** in
  the entire run.
- FEX's own reconstruction (`D 120 pc: 14A59D140 rip: 71E5A358FB`) confirms the guest RIP. The
  code page is valid (`protect=0x20` = `PAGE_EXECUTE_READ`); the log states outright:
  *"fault is in the DATA the instruction touches, not the RIP"*.

**⚠️ An internal contradiction to chase.** `[bus-reheal]` reports *"host had stripped it"*, but
the `[fault_rip]` line for the very same fault reports `entryprot=3 nowprot=3` — protection was
**never** stripped. So the reheal path is **misdiagnosing a `KERN_MEMORY_ERROR` as a protection
strip**, "restoring" a protection that was already correct, resuming, and then dying. That makes
the existing heal a no-op for this failure mode. **This is the most concrete open lead.**

**What makes `KERN_MEMORY_ERROR` on a mapped RW page?** On XNU this is not a normal
protection/absence fault. Candidates (none yet tested): a **purgeable/volatile region that got
purged**; a **compressor decompression failure**; a mapping whose **backing memory entry was
destroyed or truncated**; a section/shared-memory object gone. Note the log shows
`[iOS-xrem] via=section tracker=…` activity, and Valve uses shared-memory sections heavily.

**Other fatal sites seen across runs** (the site varies, which is itself a clue):
- `libcef.dll+0x41258FB` — the clear routine (×4, dominant)
- `chrome_elf+0xD7D6E` — PartitionAlloc BackupRefPtr `refcount` CHECK, deliberately aborting (×1)
- `libcef+0x1af8dba` — NULL-`this`, `cmpq $0x0, 0x40(%rcx)` (×1)

**REFUTED for this crash (do not re-propose):**
- **Stale memory / zero-fill contract violation.** Converted the sampled probes into *unbounded
  censuses* on both sides: 1,075 + 32,768 commits and 744 + 20,480 decommits, **0 violations**.
  Fully refuted.
- **JIT-pool use-after-free.** Theory: a tail carve freed and recycled while a thread executed in
  it. Shipped a guard that scans every thread's PC before marking a carve free. Result:
  **52 frees, 51 reuses, 0 refusals** — no thread was *ever* inside a carve at free time. Refuted.
- **The `srcwatch` probe as crash cause** — exonerated.
- **Page reclamation** (`#53`) — refuted by a dedicated discriminator across two runs.

---

### 2.3 CM LOGIN / NETWORK (OPEN, above TCP)

Steam logs 84× `PingWebSocketCM() failed talking to cm` → `Failed to start auth session: result 3`.

**CONFIRMED it is NOT a TCP problem:** `[srv-conn-done]` shows dport=443 ×7 and 27018/27020/27022
all `OUT err=0` — handshakes complete. Some TLS works (`gnutls_handshake COMPLETED` ×3). So the
failure is at the **TLS/WebSocket layer**, above the socket.

**Real but NOT the blocker:** `GetAdaptersAddresses failed: 2` ×239 — our NSI bypass only serves
the TCP module; the NDIS path (`eb004a11`) returns table=0. (Fixed later in ml1290.)

**ml1350 — the UI transport (localhost WebSocket) was a WoW64 argument bug.** Every
`ws://localhost:6246x/transportsocket/` attempt logged `Unknown error 10038` (WSAENOTSOCK) in
cef_log.txt while the kernel connect completed. `WSAEnumNetworkEvents` passes its event HANDLE as
the InputBuffer of `IOCTL_AFD_GET_EVENTS`; the WoW64 thunk offset it as a guest pointer, so
`wine_server_obj_handle` returned `0xfffffff0` and the ioctl failed STATUS_INVALID_HANDLE. Fixed in
`wine/dlls/ntdll/unix/socket.c` (`afd_event_handle_arg`, `MADEIRA_AFD_EVENT_HANDLE=0` rolls back).
Device result: transport connected and the login window appeared (log prev 15).

**ml1360 — login window froze: winproc handles offset by the WoW64 thunks.** Every message to
the login window died in `KeUserModeCallback` → guest jump to 0xffff0036 (FEX NoExec), then
6770 `dispatch_user_callback ignoring exception`. 0xffff0036 is a Wine winproc handle;
`wow64win` converts `win_proc_params.func` (CallWindowProc) and `lpfnWndProc` (RegisterClass)
with `guest_ptr32`, so win32u's `get_winproc_ptr` did not recognise B+0xffff0036. Fixed in
`build/win32u-unix/class_ios.c` (`ios_winproc_handle_arg`, `MADEIRA_WINPROC_HANDLE=0`).
Separate, unexplained: log 163's transport on one port dropped after ~11 s and Chromium then
retried only ::1. Accept trace budgets split so the next run records completions.

---

## 3. Solved walls (context — these are done, and the *methods* may be reusable)

| # | Wall | Root cause & fix |
|---|---|---|
| #61 | **Steam draws no text** | `dwrite.dll` had **no unixlib on iOS**, so every `__wine_unix_call` failed, `get_glyph_bbox` never ran, every glyph reported an empty bbox — invisible text with *no error anywhere*. Fixed by building a dwrite unixlib. ⚠️ It compiled fine but was **silently not archived** until added to the explicit `ar rcs` list — "compiled OK" says nothing about shipping. |
| #67 | **~54 s freeze / whole-app stall** | Trigger was the StikDebug **debugger departing** (clean exit and jetsam-kill alike); it burns its 48 s-CPU/60 s budget in ~52 s, so departure mid-run was guaranteed. Fix: **detach the debugger early**, right after the JIT pool is granted. Cost 6–83 ms. **Side effect: Steam webhelper bring-up went 89 s → 9 s (~10×)**, which also killed the "Unexpected Transport Error" dialog. ⚠️ The 54 s *mechanism* is still unexplained; only trigger and cure are established. |
| #70 | **C00000FD infinite recursion** | Chromium default-font-init recursed on an empty wine-dwrite collection (stale macOS font paths in the registry). dwrite is **registry-only**; GDI **dir-scans**. Fixed by a registry-only font push. |
| #71 | Misaligned compare-exchange in Valve shm | Mach-side misaligned-atomic emulation (no code patching). ⚠️ The emulator is genuinely **non-atomic** (read/compare/write as 3 ops) — a real bug, but only ~28 firings/run, and **not** the render corruption. |
| #72 | V8 cage VA exhaustion | Aligned reservations, 8 GB sandbox holdback, 4 GB cppgc soft cap. |
| #74 | Steam watchdog cross-terminates threads holding FEX JIT locks | Verified fixed. `Failed to mprotect last page` is benign. |
| #79 | Steam pid-auth rejected 11/11 | Linux-vs-BSD **TCP state numbering** mismatch in `sock.c`'s fallback made listeners report ESTAB and real connections FIN_WAIT1. Now 0 rejects. |
| #83 | Misaligned 8-byte MOVs into a PA-band SM_COW region | `memcpy`-based unaligned emulation in the bus handler. |
| — | **Any Steam helper that faults = whole-app kill** | Gate them. `[proc-gate]` blocks: steamerrorreporter, gldriverquery, vulkandriverquery, steamsysinfo. |

Also fixed this session, both **self-inflicted**:
- A `[rsp-trunc]` diagnostic read TSD slot 275 as a Wine TEB. **Slot 275 is not ours** — on a
  native thread an Apple framework's value sits there; `TEB+0x1788` came back `0x40` and
  `*(0x40+0x30)` faulted. Its `rspq < 6` cap **could never engage** because the increment was
  emitted *below* the faulting load. 5,000+ faults.
- `pthread_exit_wrapper` dereferenced `ntdll_get_thread_data()` with a NULL TEB, so the
  fault-stuck breaker's divert to `abort_thread` re-entered it forever (sp marching down
  ~0x70/iteration).

---

## 4. Methodology rules learned the hard way

These are the project's own rules. An outside agent should assume they are load-bearing.

1. **No per-app/per-game fixes.** Fix the accuracy gap, not the symptom.
2. **A probe must not break what it measures**, and its bound must be *reachable* — spend the
   budget counter *before* the risky operation, never after.
3. **Confirm-only probes prove nothing.** Every probe must print the negative case too, so
   "nothing happened" is a real observation rather than silence.
4. **A constant delta means STALE data**, not a real signal.
5. **Offline disassembly is free — exhaust it before spending a device run.** A run costs 40–60 s
   plus pull-and-analyze time.
6. **Verify deploys by content**, e.g. `grep -ac '<marker>' <shipped binary>`. The `.a`s link
   into the main `Madeira` Mach-O; grep the bundle binary, not the intermediate.
7. **Read Steam's own logs first** (`drive_c/Program Files (x86)/Steam/logs/`) — they use
   cumulative clocks.
8. **Pull binaries from the phone prefix, not local copies.** A local `libcef.dll` was a
   *different build*, which invalidated a positive control.
9. `log collect --device-udid … --output X.logarchive` (needs root) is the **only** way to observe
   a whole-task stop, since every in-process probe dies with it. ⚠️ `log` is shadowed in zsh — use
   `/usr/bin/log`. `--start/--end` silently match nothing given fractional seconds. **Collect
   promptly and use a wide window** — I lost an attempt by using `--last 10m` when collection plus
   analysis took an hour.
10. Submodule `unix/*.c` fixes are **dead code** — the `_ios.c` forks are what build.
11. `setenv()` in `WineProcessBridge.m` does **not** reach `GetEnvironmentVariableW` (allowlist is
    `WINE*`, `DXVK_*`).
12. BSD `grep` silently suppresses output on NUL-containing logs without `-a`.

---

## 5. Where I would look next (ranked)

1. **The `KERN_MEMORY_ERROR` (kr=10) fault.** This is the freshest and most concrete lead. The
   `[bus-reheal]` path demonstrably misdiagnoses it. Determine what kind of mapping
   `0x70f1ed0000+0x14000` is (purgeable? section-backed? who created it?) and why a mapped,
   RW, page-aligned address returns `KERN_MEMORY_ERROR` exactly once. If it is a purged
   volatile region, the fix is ownership/lifetime, not protection.
2. **Reproduce the render corruption offline** by lifting Chromium 126's compositing path into a
   standalone test PE, so it can be bisected without device runs.
3. **The FEX ASM conformance harness** (`build/x64-tests/gen_asmconf.py`) is built and parked: it
   re-hosts FEX's own 1,283 ungated golden-value instruction tests in a Windows PE, so they run
   through *our* fork + ARM64EC + jitless, which upstream CI never exercises. It assembles
   1,284/0 and links. It is parked because test 17 kills the process (a fault on a repointed
   stack is not `__try`-catchable, and on device that is a whole-app kill). **Needs a statically
   filtered safe subset.** If FEX misexecution is really behind §2.1, this is the tool that finds it.
4. The alpha gate (§2.1) is small, real, and independent.
5. `#42`-family: `x17` (`REG_CALLRET_SP` on ARM64EC) is IP1 and gets zeroed across EC thunks. Open.

---

## 6. Repo orientation

```
app/                      iOS app (SwiftUI, Metal compositor, WineProcessBridge)
build/ntdll-unix/         our ntdll unix half — *_ios.c forks (signal_arm64_ios.c,
                          virtual_ios.c, thread_ios.c, process_ios.c) ← most fixes live here
build/wineserver/         wineserver-as-a-thread
build/win32u-unix/        win32u
build/dxmt-ios/           DXMT
build/x64-tests/          standalone test PEs (fpconf-x64.c, gen_asmconf.py)
wine/                     Wine 11.4 fork (submodule)
FEX/                      FEX fork (submodule)
```

Build chains: `build/ntdll-unix/build.sh` · `build/wineserver/build.sh` ·
`build/win32u-unix/build.sh` · `build/dxmt-ios/build.sh` + libtool · app via `xcodebuild`.
EC PE ntdll: `make -C dlls/ntdll` in `wine/build-arm64ec`, then strip + pad.
Nuke DerivedData when low-level libs change.

Both submodules are **forks that are never upstreamed**, so they can be modified freely.
(`FEX/CLAUDE.md` contains an upstream-oriented "no AI-generated code" line; the repo owner has
confirmed it does not apply to this private fork.)

---

## 7. What a fresh pair of eyes would most help with

- A mechanism for `KERN_MEMORY_ERROR` on a mapped, RW, page-aligned iOS address that fires
  exactly once and is not a protection or presence fault.
- Any way to make a **tile-granular, per-draw-op destination error** in Skia/Chromium fall out of
  a *specific* x86→ARM64 translation bug — i.e. what class of JIT miscompilation produces wrong
  destination pointers but otherwise correct pixels?
- A cheaper oracle than a 40–60 s device run for either bug.
