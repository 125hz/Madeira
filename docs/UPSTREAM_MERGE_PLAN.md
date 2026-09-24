# Plan: bring Will Faust's upstream Madeira into the 125hz fork (and later offer our work back)

Prepared 2026-09-23 (researched against upstream as fetched that day; upstream HEAD is dated 2026-09-24 +0800).
Plan only. Nothing was rebased, merged, checked out, committed or pushed.

## 0. What was done to produce this (the only state changes)

```sh
# top-level: new fetch-only remote (push URL disabled)
git remote add upstream https://github.com/willfaust/Madeira.git
git remote set-url --push upstream DISABLED
git fetch upstream --tags          # also tried to fetch submodule pins from origin (125hz) and failed harmlessly: "not our ref"
# submodules (already had fetch-only upstream remotes)
git -C FEX fetch upstream --tags
git -C research/dxmt fetch upstream --tags
git -C wine fetch upstream --tags
```

Everything else used read-only commands: `merge-base`, `rev-list --count`, `log`, `diff --stat/--numstat/-I`,
`show`, `ls-tree`, `branch -r`, and `git merge-tree --trivial-merge <base> <ours> <theirs>`. That last command is the old
read-only mode. It prints a three-way merge with conflict markers to stdout and writes no objects, refs, index or
working-tree files. The conflict-hunk counts below come from it, and a real `ort` merge will be a little better than
that (for example, it detects renames). Upstream PR data came from `curl https://api.github.com/repos/willfaust/Madeira/pulls?state=all`.

Scratch outputs (numstat lists, merge-tree dumps) are next to this file: `top-mt.txt`, `fex-mt.txt`, `dx-mt.txt`, `wine-mt.txt`.

---

## 1. Where each repository stands

| Repo | Our HEAD (branch) | Upstream branch Will develops on / HEAD | Merge base | Ours since MB | Theirs since MB | Date ranges |
|---|---|---|---|---|---|---|
| **Madeira** (top) | `db4b7fd` (`main`, equal to `origin/main`) | `upstream/main` `5a82d39` (the only branch) | `97e2ce2` 2026-08-29 "Show a frame-rate readout in the host window title" | **125** (all 125hz) | **9** (all Will) | ours 09-11 → 09-23; theirs 09-16 → 09-24 |
| **FEX** | `e6f6280` (detached, = `origin/ios-port-2607`) | `upstream/ios-port-2607` `0f8edf8` (other branches: `ios-port` 07-06 and `main` 03-04 are stale) | `053c385` 2026-08-28 | **28** | **7** | ours 09-11 → 09-23; theirs 09-16 → 09-24 |
| FEX/External/**rpmalloc** | `e0a3eae` (`origin/ios-madeira`) | upstream FEX pins `1f271c0` | `e60293e` 2026-08-28 | 2 | 5 (2 code, 3 licence) | — |
| **wine** | `932a390` (detached, = `origin/ios-build`) | **`upstream/madeira-lgpl` `e828644`**. `upstream/ios-build` `abf22e0` is retired | vs ios-build: `7817e22` 2026-08-28 (47 ours / 1 theirs). vs madeira-lgpl: `cc893ef` = **Wine 11.4 release** (98 ours / 54 theirs, **separate histories**) | 47 | 3 code commits (`abf22e0`/`90455e3`, `d88d55e`, `e828644`) + 1 licence commit | ours 09-11 → 09-23 |
| **research/dxmt** | `49dbb94` (detached, = `origin/ios-port`) | `upstream/ios-port` `0cb9766` (`main` is 3Shain's upstream, 04-23; the `feat/*`, `refactor/*` and `chore/*` branches are old DXMT branches) | `b4b89f0` 2026-08-29 | **21** | **6** (3 code, 3 licence) | ours 09-11 → 09-22 |

Submodule pins in the top-level trees:

| | merge base `97e2ce2` | ours `HEAD` | upstream `5a82d39` |
|---|---|---|---|
| FEX | `053c385` | `e6f6280` | `0f8edf8` |
| wine | `7817e22` | `932a390` | `e828644` (**madeira-lgpl**) |
| research/dxmt | `b4b89f0` | `49dbb94` | `0cb9766` |

`.gitmodules` changes. Upstream changed `wine` to `branch = madeira-lgpl` and kept the willfaust URLs. We changed all three URLs to `125hz`.
**Wine is the key structural fact.** Upstream moved its Wine fork to a new branch, `madeira-lgpl`: Wine 11.4 plus the same
51 Madeira commits, cherry-picked with `-x`. It skips the commit that converted the tree to GPL-3.0 (`0224441925d`).
I checked this. `git diff -I'^\s*(/?\*)' -I'^\s*$' 7817e22 6d3c1d6` (ios-build pin vs its madeira-lgpl twin) leaves only
`COPYING`, `CONTRIBUTING.md` and `LICENSE-MADEIRA.md`. The two branches are code-identical and differ only in licence
notices (5,741 files). Our 47 Wine commits sit on the retired GPL branch.

## 2. What upstream did (9 top-level commits, +50,369/−334 in 157 files)

| Commit | Summary |
|---|---|
| `b334510` 09-16 | **Native D3D12 runtime** (`research/madeira-d3d12`, now tracked): static samplers, RTV/DSV sub-views, geometry shaders through Metal Shader Converter mesh emulation, every texture as an array (ForceTextureArray), capture tooling, remote-Metal host ops. Also ntdll/wineserver iOS fixes and rebuilt DLLs. The commit says a UE5 SM6 title renders in-game with lighting **through the remote Metal host** (rmetald on a Mac). |
| `6c79f03`, `aaee87b`, `a6361ec`, `68ea734`, `5a82d39` | **Licensing overhaul**: `COPYING` (GPL-3.0), `LICENSE-EXCEPTION.md` ("Madeira Converter Exception", **adopted 2026-09-24**), `docs/LICENSING.md`, `docs/wine-lgpl-provenance.md`, `app/Madeira/licenses/*`, `build/stage-licenses.sh`, `.githooks/pre-push`, DCO sign-off in CONTRIBUTING, Wine moved to `madeira-lgpl`, `docs/BUILDING.md` (clean-checkout build record). |
| `8a8cabe` | Tracks Apple's **`libmetalirconverter.dylib`** (Metal Shader Converter 4.0 beta 2, iOS, ~30 MB) in `app/Madeira/d3d12/` with Apple's agreement and NOTICE. |
| `8848944` 09-23 | D3D12: tessellation (hull/domain as object/mesh pipelines), occlusion queries, one MTLFence per device, vertex-slot binding fix, a fixed 2304 MB VRAM budget, frame capture (the "CAP" pill), perf census. **One config file, `Documents/madeira.cfg`** (`build/madeira_cfg.h` + `MadeiraConfig.swift`). Legacy `madeira-<key>.txt` files are migrated into it. **`build/madsync/`**: a userspace ntsync. Wine is built with `HAVE_LINUX_NTSYNC_H=1`, and `/dev/ntsync` is served in-process, **on by default** (`inproc-sync`). Also a file-backed "swap" data tier and memory canaries. |
| `873fe25` 09-24 | Lock-free GPU address lookup; an **ECO QoS switch** (guest threads at utility QoS; pill + `eco`/`eco-qos`); `fence-chain=6` mode; CPU/power probes; **JIT pool diagnostics**; `calltest-x64`. |

**New dirs/files**: `research/madeira-d3d12/` (PE runtime `src/pe/madeira_d3d12.c` 10k lines; unix `src/unix/madeira_ir_unix.mm`,
`madeira_sm5_ia.cpp`; tests; shaders), `build/madeira-d3d12/*.sh`, `build/madsync/`, `build/madeira_cfg.h`, `build/tools/*.py`
(DXBC disassembler, capture-to-PNG, `ec-ffs-pad.py`), `build/wine-pe/build-ntdll.sh`, `build/fex-arm64ec/build.sh`,
`build/fex-ios/build.sh`, `build/x64-tests/calltest-x64.*`, `scripts/deploy-vm.sh`, `research/remote-metal/*` (host daemon and wire
protocol changes), and planning notes (`research/HANDOFF-rdr2-arm64ec-hooks.md` 9k lines, `research/madeira-d3d12/HANDOFF-empire-black-scene.md`,
`PARKED-2026-09-16-ue5-state.md`).

**The open-world title (RDR2), from upstream's notes.** Work ran on a vphone VM and an iPhone 18 Pro. Upstream diagnosed an
anti-tamper DLL that installs x64 inline hooks on ARM64EC exports; one fix attempt was reverted. It also relocated the fixed-base
main image, because the title's `.exe` has no relocations and must load at `0x140000000`. That led to the **VA changes below**.
Other work: JIT-pool starvation (the pool is shrunk by a 31 MB intruder mapping), a GPU budget, and ECO for thermal/energy clamping.
The app still says it is blocked or at low FPS in places. Treat all of this as research-grade.

**App (Swift/ObjC)**:
- `ContentView.swift` (+201/−64). This adds **per-test launch buttons**: "D3D12 cube", "D3D12 M2 ABI", "x64 call cost", and a UE5 demo. It also adds the D3D12 canary gate, the CAP and ECO pills, and `desktop-size`.
- `StikJITHelper.swift` (+270): reserves the executable window **before** RX, takes a hole census, sizes the pool to fit, plugs lower holes, and warns about a small pool.
- `JITAllocator.c` (+67): a **constructor(101) that claims `[0x140000000,+128MB)` plus 256 MB–1 GB above it at image load**.
- `WineProcessBridge.m` (+218): the cfg, swap tier, canaries, and the `madeira-env.txt` / `env.NAME` export of **all** names, including `FEX_*`.
- `MadeiraConfig.swift`, `FPSOverlay.swift`, `Info.plist` (Game Mode keys).
- pbxproj: the d3d12 and licenses folders, a "Sign bundled dylibs" phase that also fails the build when the licence copies are stale, **bundle ID changed to `com.willfaust.madeora`, team `V8NU3FX3TL`**.

**Unix side** (the hot port files):
- `virtual_ios.c` +3689: placement fallbacks (ml1025/1027), jumbo holdback keep-floor (opt-in), reclaimed code-buffer head ranges, native heap census, a file-backed data tier, and no page touches under `virtual_mutex`.
- `signal_arm64_ios.c` +2173: store/pair-load emulation fixes, SMC write verification, fault budgets per PC, EXC_BAD_ACCESS reordering, guest-RIP resume probes.
- `server_ios.c` +1285: madsync hookup, thread sampler and CPU split, worker profiler, `[xp-api]` reporter, fd-cache release, and fixed-base main-image hand-back.
- `audio_null_ios.c` +345/−79: **one RemoteIO endpoint per process with a mixer**, and a float mix format.
- `thread_ios.c`: ECO QoS.
- wineserver `fd/mach/mapping/queue/request_ios.c`.
- `win32u sysparams/driver_ios.c`: desktop size.

**Build system (upstream)**. The build is macOS-only: `xcrun`, and `toolchains/llvm-mingw-20260421-ucrt-macos-universal`. It is driven per part by
`build/*/build.sh`, followed by `xcodebuild`. `docs/BUILDING.md` lists the inputs that are not in the repo (llvm-mingw, the iOS LLVM build,
**Metal Shader Converter 4.0 beta 2 .pkg** for its headers, and the x64 vcruntime). Compared with our side:
- **`.xtool/` (gitignored, WSL)** is our adapter. It rsyncs `build/{ntdll-unix,win32u-unix,wineserver,crypto-unix}` except `build.sh`. `prepare-native-scripts.py` rewrites each `build.sh`, and `prepare.py` reads the pbxproj Resources list.
- New upstream inputs the adapter must learn:
  - `build/madsync/` and `build/madeira_cfg.h`. These sit outside the synced parts, and the rewritten `build.sh` must keep `madsync.o` plus `-I../madsync -DHAVE_LINUX_NTSYNC_H=1`.
  - the D3D12 unix objects inside `build/dxmt-ios/build.sh`. These are compiled only if `deps.sh` finds the .pkg with SHA-256 `1acc33c8…`. `deps.sh` uses `shasum` and pkg extraction, so a WSL port is needed.
  - `build/madeira-d3d12/build-pe.sh`. It hardcodes the macOS llvm-mingw path; point it at `.xtool/toolchains/llvm-mingw`.
  - signing of `d3d12/libmetalirconverter.dylib`, which Xcode does in a script phase. xtool/sideloaders must sign it, or it must move to `Frameworks/`.
  - the `licenses/` folder.

## 3. Overlap and conflicts

### 3.1 Top level: 37 files changed on both sides; 63 textual conflict hunks (`merge-tree --trivial-merge`)

| Rank | File | Ours (+/−) | Theirs (+/−) | Conflict hunks | Notes |
|---|---|---|---|---|---|
| 1 | `build/ntdll-unix/virtual_ios.c` (17.8k→ours 23.2k / theirs 21.4k lines) | 5800/442 | 3689/85 | 9 | Our WoW64 4 GB windows (`[wow-window]`, 421 refs) vs their placement fallbacks, jumbo keep, data tier, reclaimed heads. **Semantic risk is higher than the hunk count suggests.** |
| 2 | `build/ntdll-unix/signal_arm64_ios.c` | 4883/104 | 2173/22 | 8 | Both changed fault delivery and store emulation. Our WoW64 guest-window fault paths vs their EXC_BAD_ACCESS reorder (ml953). |
| 3 | `build/ntdll-unix/audio_null_ios.c` | 1930/173 | 345/79 | **18** | **Duplicate feature.** Both built "one mixed engine per process". Keep ours (it has the 32-bit unixlib tables, limiter and period events), then port their float mix-format item if it is missing. |
| 4 | `app/Madeira/ContentView.swift` | 5561/813 | 201/64 | 7 | Drop their per-test buttons (hard rule 5). Keep the canary gate, pills and cfg. |
| 5 | `app/Madeira/StikJITHelper.swift` | 367/28 | 270/4 | 4 | Our process-lifetime pool, early allocation and remembered size (ml962/1330/1420) vs their window-first placement and hole census (ml1034/1036/1040). **Must be designed together** (see 5.2). |
| 6 | `build/ntdll-unix/server_ios.c` | 1479/13 | 1285/15 | 2 | madsync hookup vs our sync, NSI and Steam paths. |
| 7 | `app/Madeira/Winios/Winios.m`, `project.pbxproj`, `build/dxmt-ios/build.sh` | | | 2 each | pbxproj: **keep our bundle ID `com.willfaust.mythicemu` and team.** Changing it creates a new app with an empty container: prefixes and Steam login are lost. |
| 8 | `JITAllocator.c`, `FPSOverlay.swift`, `thread_ios.c`, `loader_ios.c`, `driver_ios.c`, `sysparams_ios.c`, `ntdll-unix/build.sh`, `wineserver/build.sh`, `.gitmodules` | | | 1 each | `.gitmodules`: keep the 125hz URLs and take `branch = madeira-lgpl` for wine (or our re-homed branch name). |
| — | Clean auto-merges: `env_ios.c`, wineserver `fd/mach/mapping/queue/request_ios.c`, `WineProcessBridge.m`, `Info.plist`, `Madeira-Bridging-Header.h`, `JITAllocator.h`, `.gitignore` | | | 0 | Still need review. For example, `WineProcessBridge.m` now exports `FEX_*` from `madeira-env.txt`, while our ContentView filter says those names are ignored. |
| — | **Binary conflicts**: `arm64ec-windows/{d3d11,dxgi,ntdll,winemetal,xtajit64}.dll` | | | binary | Neither side's copy is right. **Rebuild from the merged sources.** Take upstream-only binaries (`d3d12.dll`, `madeira_d3d12.dll`, `d3d12-*-x64.exe`, `calltest-x64.exe`) as they are at first. |

Top-level: 109 files are upstream-only additions and conflict-free. Our 1,345 changed files are mostly `i386-windows/` (56% of files),
`aarch64-windows/`, `nls/`, `build/x86-tests`, `build/host-tests`, Steam Swift and docs. Upstream never touches them.

### 3.2 wine (plan: re-home our 47 commits onto `madeira-lgpl`)
- A three-way run with base `7817e22`, ours `HEAD` and theirs `upstream/madeira-lgpl` gives **1 conflict hunk: `dlls/ntdll/unix/sync.c`**.
- Files both sides touched: `ntdll/loader.c`, `ntdll.spec`, `signal_arm64ec.c`, `unix/file.c`, `unix/sync.c`, `server/event.c`, `server/inproc_sync.c`, `server/thread.c`.
- **Semantic hotspot.** Upstream's madsync turns on Wine's own ntsync/inproc-sync path, on by default. Our in-process fast path (event cells, semaphore fast path, spin governor, `MADEIRA_FASTSYNC_*`) was written assuming "/dev/ntsync is dead here", and also uses `get_inproc_sync_fd`. With both active, the two designs compete for the same waits. Pick one default and keep the other behind a switch:
  - Recommendation: keep ours as the default at first, since it is proven on device and handles 32-bit. Build madsync in but default `inproc-sync = 0`, then A/B it on device. The `fastsync-*race` host tests should also run against madsync.
- Licence: our new `dlls/dinput/joystick_ios.c` carries a **GPL-3 header**. Change it to the LGPL-2.1+ Wine header when it moves onto `madeira-lgpl`. Our other commits touch no notice lines.

### 3.3 FEX: 14 files on both sides; 10 conflict hunks
- Hunks by file: `ARM64EC/Module.S` (3), `IosJitAlias.cpp` (2), `CPUBackend.cpp` (2), `libarm64ecfex.def`, `Module.cpp`, `CPUBackend.h` (1 each).
- Clean auto-merges: `Core.cpp`, `Frontend.cpp`, `LookupCache.h`, `OpcodeDispatcher.cpp`, `Allocator.cpp`, `AllocatorHooks.h`, `CallRetStack.h`.
- Upstream touched **no WOW64 module code**. Its new code is `Common/ArenaManager.*`, `ArenaSelfTest.cpp`, `CRT/Alloc.cpp`, and the call-ret stack hardening. There is no `thread_local` in upstream's additions, which I checked. Our rule 4 must still hold after the merge.
- Duplicates to reconcile:
  - Their sweep retry "while holders were skipped" vs our "sweeper moves WOW64 threads blocked in syscalls" and "code buffer size only grows".
  - Their last-hit alias cache and L1-miss log vs our "returns into the pool skip the alias walk" and two-way L1.
- rpmalloc: ours is the available-list invariant fix. Theirs is `0b96482` "guard page-list repair / CAS quarantine" and `044436f` "TEB->Self thread id and **serialise the allocator on iOS**". Both address the same corruption class. Merge both and measure: global serialisation may cost 32-bit performance.

### 3.4 dxmt: 12 files on both sides; 14 conflict hunks
- Hunks by file: `winemetal_unix.c` (7), `wmt_api_names.h` (2), `winemetal_thunks.c`, `winemetal.h`, `gen_remote_guard.py`, `d3d11_pipeline_{gs,ts}.cpp` (1 each). Modify/delete: `wmt_remote_guard.h`, which upstream deleted. It is generated, so regenerate it.
- **Unix-call slot ABI.** Both sides extend past slot 126:
  - Ours deliberately left **127–144 NULL**, then uses 145–150 (DXSO ×4, `registryID`, `rmg_waitUntilSignaledValue`, `d3d9_nop`), so our count is 151.
  - Upstream uses **127–138** (`madeira_ir_convert` … `madeira_ctl`), so its count is 139. It already added `_wow64` `STATUS_NOT_IMPLEMENTED` stubs at the same indices.
  - Merge: 127–138 upstream, 139–144 NULL, 145–150 ours, count 151, in both the 64-bit and the wow64 tables. Then rebuild `winemetal.dll` for **i386, aarch64 and arm64ec**, `d3d9*.dll`, `d3d11/dxgi` and `madeira_d3d12.dll`.
  - Also merge upstream's `rmg_` renames in the generated names header.
- Licence: our D3D9/DXSO import from `dacevedo12/dxmt v0.4-d3d9` is **LGPL-2.1 code (CodeWeavers copyright) converted to GPL-3 via §3**. This recreates the Wine problem upstream just fixed: third-party GPL code cannot receive the converter exception. Consider distributing that import under its original LGPL-2.1 instead. This needs a decision, and a lawyer before release. It is not legal advice.
- Cleanup: `src/d3d9shim/__pycache__/*.pyc` is tracked in our dxmt.

### 3.5 Uncommitted work that must be committed or parked before anything
The working tree is **live**: it changed while this plan was being written.
- Top level: 40 modified files, 2 dirty submodule pointers (wine, dxmt) and 12 untracked paths:
  - docs: `STEAM_INTEGRATION.md`, `WOW64_DESIGN.md`
  - `project.pbxproj`
  - Swift: `ContentView`, `Library`, `LogStore`, `SteamAccount`, `SteamFiles`, `SteamLibrary`, `SteamStoreViews`, `SwiftSteam/Install/AppManifestWriter`
  - `WineProcessBridge.m`, `Winios.{h,m}`
  - rebuilt DLLs in `aarch64-/arm64ec-/i386-windows` (d3d9, d3d11, dxgi, nsi, winemetal, d3d10core, d3d9-emulated, d3d9shim)
  - `build/host-tests/check-steam-{library,native}.py`
  - `build/ntdll-unix/{nsi_network,process,server,signal_arm64,virtual}_ios.c`, `build/wineserver/fd_ios.c`
  - untracked: `app/Madeira/Onboarding.swift`, 7 new host-test scripts, `fastsync-*` host-test binaries, `build/dxmt-tests/out-host/`
- wine (dirty): `dlls/nsi/nsi.c`, `dlls/ntdll/unix/file.c`, `dlls/ntdll/unix/sync.c`
- dxmt (dirty): `src/d3d9/d3d9_{device.cpp,device.hpp,surface.cpp}`, `src/dxmt/dxmt_resource_initializer.{cpp,hpp}`
- FEX and rpmalloc: clean. All submodule HEADs and top-level `main` are already pushed to the 125hz forks.

---

## 4. Recommended strategy

**Merge, don't rebase.**
- Top level, FEX, rpmalloc, dxmt: merge upstream into an integration branch in each 125hz fork.
  - Upstream is small: 9, 7 and 6 commits. We have 125, 28 and 21 commits built over about 55 device rounds.
  - A rebase would replay 125 commits through the same hot files. Many carry rebuilt binaries, and each would need its own conflict resolution and would leave an unbuildable intermediate state.
  - A merge resolves each file once, keeps our commit and SHA history (which `WOW64_DESIGN.md`/`HANDOFF.md` cite), and records upstream's pin.
- **wine** is the exception: *re-home* our 47 commits onto `upstream/madeira-lgpl` with `git cherry-pick -x 7817e22..932a390`.
  - Merging `madeira-lgpl` into our `ios-build` would silently keep our side's GPL-3 notices in all 5,741 files. Only our side changed those lines relative to Wine 11.4, so the merge picks ours.
  - Cherry-picking gives the licensing upstream intends, with one expected conflict (`sync.c`).
  - Push it as a new branch, e.g. `125hz/wine: madeira-lgpl-125hz`. Leave `ios-build` untouched as the fallback.
- **Porting instead of merging** for pieces we do not want as they are. Resolve these to our side and cherry-pick hunks by hand:
  - the per-test buttons
  - upstream's audio rewrite
  - bundle-ID/team changes
  - the RDR2/VM-specific scripts (`scripts/deploy-vm.sh`) and handoff docs (can be kept; they are harmless docs)

### Order of operations (submodules first, then the pins at the top level)
1. **Phase 0: freeze (0.5 day).**
   - Finish or commit the in-flight round per rule 9, or commit it on a `wip/pre-upstream-2026-09` branch in each repo and push to 125hz.
   - Tag backups: `pre-upstream-merge` in the top level, wine, FEX, dxmt and rpmalloc.
   - Record the current IPA SHA as the baseline.
2. **Phase 1: FEX + rpmalloc (0.5–1 day).**
   - rpmalloc: merge `1f271c0` into `ios-madeira`. FEX: merge `upstream/ios-port-2607` into a branch from `e6f6280`.
   - Resolve `Module.S`, `IosJitAlias.cpp`, `CPUBackend.*` and `libarm64ecfex.def` by keeping both sets of exports and ordinals.
   - Gates: grep for `thread_local`/`__thread` in the DLL targets; `.xtool/build-fex.sh`; `build-fex-arm64ec.sh` (xtajit64); the WOW64 xtajit build; `fex-host-guards.py`.
3. **Phase 2: wine (1–1.5 days).**
   - Cherry-pick the 47 commits onto `madeira-lgpl`, fix `sync.c` and the `joystick_ios.c` header, then add the currently uncommitted wine edits.
   - Decide the madsync vs fastsync default. Keep the 32-bit (`build-wine-i386.sh`) and 64-bit PE farms building.
   - Gates: `build-wine-tools.sh`, `configure-wine.sh`, `build-wine-64.sh`, `build-wine-i386.sh`, `build-wine-native.sh` (32/32 and 46/46 objects as in earlier rounds), `build/host-tests/fastsync-*`, `check-nsi-*`, `check-thread-qos.py`.
4. **Phase 3: dxmt (0.5–1 day).**
   - Merge `upstream/ios-port`, then apply the slot-table plan above and regenerate `wmt_remote_guard.h` and the api names.
   - Gates: `build-dxmt.sh` with the i386 PE archs plus arm64ec, `check-d9-upload-commit.py` and the D3D9 host tests, and `build/dxmt-tests`.
5. **Phase 4: top level (2–4 days).**
   - Merge `upstream/main`, resolve the table in 3.1, and point the submodules at the results of phases 1–3.
   - Unify the config layer: adopt `madeira.cfg` + `madeira_cfg.h`, but keep **our `madeira-env.txt` path working even when `madeira.cfg` exists**, so hard rule 6 and the owner's device files keep working. One reader, one name filter.
   - Teach `.xtool` about madsync, `madeira_cfg.h`, the D3D12 unix objects, the licenses and d3d12 resources, and dylib signing. The D3D12 unix side is optional: upstream's script skips it when the converter .pkg is absent. If skipped, `madeira_ir_convert` is **unresolved at link**, so either obtain the .pkg (headers) or add a weak/stub symbol in the adapter.
   - Rebuild **every** DLL farm (i386, aarch64, arm64ec) and the static libs.
   - Gates: all `build/host-tests/*.py`, the latest `verify-ml13xx/14xx.py`-style IPA content check (Info.plist + CodeResources changed, expected DLL list, **compare the IPA entry list with the previous IPA**, per the Defender memory), `.xtool/build-round` label.
6. **Phase 5: device checkpoints (3–6 owner rounds).** In order, each with a log:
   - (a) app starts and the JIT pool is obtained. Check `ml1040` early claim, pool size, and `[wow-window] B=0x7100000000` accepted.
   - (b) 64-bit baseline title (D3D11).
   - (c) 32-bit D3D9 cube, then the owner's 32-bit titles. Compare FPS with the pre-merge IPA.
   - (d) Steam client launch path.
   - (e) madsync A/B.
   - (f) D3D12 cube via Custom… (`C:\windows\system32\d3d12-cube-x64.exe`, once the test exes are installed into the prefix, not as buttons).
   - (g) audio.
7. Only then advance the 125hz `main` / `ios-build`→new branch / `ios-port*` and push (125hz only).

Estimated effort: **about 5–8 working days plus 3–6 device rounds**. Phase 4 and the device rounds carry most of the uncertainty.

### Risk list
1. **VA layout collision** (highest). Upstream's constructor pins `[0x140000000, 0x148000000)` plus up to 1 GB above it at image load, before `main`. It releases the pool placeholder just before the debugger RX allocation and plugs lower holes.
   - Our design allocates the pool once per app run, early (ml1330), and reuses it across sessions. Our WoW64 windows live at 448–512 GB, so they do not overlap, but the **small-VA iPad "low band"** path must be checked against the new low claims.
   - The intended combination: claim early, and let our early-pool path consume the placeholder.
2. **Two sync accelerators at once** (madsync on by default + our fastsync). This risks deadlocks or lost wakes. Default one of them off.
3. **Binary artefacts**. Every committed DLL must be rebuilt from merged sources. A stale `winemetal.dll` with the wrong slot table fails silently or calls the wrong handler.
4. **Build adapter drift**. `.xtool` skips `build.sh`, so upstream's `build.sh` edits (madsync, the ntsync define) only arrive through `prepare-native-scripts.py`. Its markers may no longer match.
5. **Config semantics**. With `madeira.cfg` present, upstream ignores every legacy `madeira-*.txt`. Its bridge exports every `madeira-env.txt` name, including `FEX_*`. Users' existing files may change behaviour.
6. **D3D12 path always on for x64**. `arm64ec-windows/d3d12.dll` is now Madeira's runtime. A 64-bit game that previously failed D3D12 creation and fell back to D3D11 may now take D3D12. Keep a switch (a DLL override or cfg) to restore the old DLL.
7. **Licensing**. Wine must move to LGPL. The D3D9 import's GPL conversion and 125hz's own GPL-3 code have no converter exception. Shipping the proprietary `libmetalirconverter.dylib` with them needs the owner's grant and a decision on the D3D9 import (legal review).
8. **Game-name/test-button rules**. Upstream code comments name titles and add buttons. Do not carry the buttons. Decide whether upstream's comments stay verbatim (they are Will's text) or get neutral wording in our resolutions. Our own new lines must stay name-free.
9. **`mlNNNN` tag collisions**. Both forks use `ml9xx–ml14xx` labels (for example, both have an ml961/ml962). Log greps and dated notes become ambiguous. Prefix ours from now on, e.g. `nx1450`, or keep ours above ml1400 and note the overlap in `WOW64_DESIGN.md`.
10. Defender may quarantine new PE files (upstream's d3d12 test exes, `calltest-x64.exe`). Check the IPA entry lists.

## 5. Compatibility checks

| Question | Finding |
|---|---|
| Does upstream support 32-bit/WoW64? | **No.** There is no `i386-windows`, no WOW64 code in FEX, Wine or the ports, and no 32-bit mentions in the new code except data widths. Nothing to reuse and nothing that removes our support. Upstream's dxmt already puts `_wow64` stubs in the wow64 table for its new slots. |
| VA layout / JIT pool? | **Changed.** There is the image-load claim at 0x140000000 described above, window-first RX placement, hole census, "SMALL JIT POOL" warnings, reclaimed code-buffer head ranges, and an opt-in jumbo-holdback keep floor. The 448–512 GB bands (`pa` 0x74–0x7c, FEX 0x7c–0x80) are unchanged, and our guest slots 0x71/0x72 GB are not touched. **Recheck:** small-VA iPad band selection, and our process-lifetime pool vs their release-then-reallocate placeholder. |
| wineserver-as-thread / pseudo-process design? | Unchanged in principle. Upstream adds madsync (objects shared in-process), a fixed-base image hand-back at process retirement (ml987/988), and per-pseudo-process inproc caches keyed by PEB. These must be checked against our session retirement and mixed 32/64-bit sessions (`fcd54f1`, `a82b468`). |
| D3D12 requirements on device | Needs **argument buffers tier 2**. A15 passes; the Apple7+ family is used for mesh-based GS/tessellation emulation. `MTLResidencySet` needs **iOS 18** (our minimum is iOS 18, so fine). It uses Apple's converter dylib (~30 MB more IPA). It advertises a fixed 2304 MB VRAM. Big titles were run on iPhone 18 Pro / vphone and partly through a **remote Mac Metal host**, so on-device performance of large D3D12 titles is unproven. **64-bit (ARM64EC) only.** |
| Upstream fixes that duplicate ours (candidates to drop one side) | 1. Per-process audio mixer (upstream ml1026 vs our `08f4a77`). 2. `madeira-env.txt` passthrough (upstream ml1062 vs our ml961). 3. In-process sync (madsync vs our fastsync). 4. rpmalloc page-list repair. 5. FEX code-buffer sweep starvation. 6. QoS (their ECO vs our "thread priority keeps the QoS class"). 7. JIT pool placement and diagnostics. Keep ours where it is 32-bit-aware; take theirs where it is a strict superset. |
| Upstream items that help us | `madeira.cfg` single config, ECO switch, lock-free profiler/census tooling, `ec-ffs-pad.py` + `build-ntdll.sh` (arm64ec ntdll pad), `docs/BUILDING.md`, licensing structure, store-emulation fixes in `signal_arm64_ios.c`, and D3D12 for 64-bit titles. |

---

## 6. Upstream merge request plan

> **HARD GATES — do not start submitting until BOTH hold:**
> 1. **The owner explicitly says to open the merge request(s).** Until then: no PR, no push to any `willfaust/*` repo (hard rule 2). The `upstream` remotes stay fetch-only (`DISABLED` push URL).
> 2. **Steam works properly on device.** Client-routed game launches through the Windows Steam client must start and run reliably, proven by the owner's device logs. Status 2026-09-24: Steam client setup and sign-in work on the iPhone and the A16 iPad on the merged build (ml1680); client-routed game launches are still to be confirmed.

### 6.1 What upstream accepts today (checked read-only)
- `willfaust/Madeira`: 436 stars, 124 forks. **No external PR has ever been merged.** PRs #5–#19 are all open or closed-unmerged. Examples: XInput host controllers (#16), resolution presets (#11), iPad game mode (#10), JIT disconnect hardening (#7), CI workflow (#18, #5). Will commits directly to `main`.
- CONTRIBUTING: GPL-3.0-or-later **plus the Madeira Converter Exception**. Contributors must agree that their code carries it. **DCO sign-off (`git commit -s`)** is required. Do not alter upstream notices. Each submodule fork has its own `LICENSE-MADEIRA.md`/`CONTRIBUTING.md`.
- README: "do not submit AI-generated changes from this fork upstream" **to FEX-Emu**, which applies to the real FEX project, not willfaust/FEX. Our work is AI-assisted. Say so in the PR text, as Will's own commits do with `Co-Authored-By: Claude …` trailers.
- Style: Will's subjects are topic-first (`Native D3D12: …`, `Licensing: …`, `ntdll iOS: …`). Bodies are measured-evidence narratives. `mlNNNN` tags are used heavily in code. There is no CI and no clang-format config. Heavy comments are house style, the same as ours.
- Upstream tracks built binaries: 268 DLL/EXE files, the dylib, `libdxmt_unix.a` and the GnuTLS archives. Ours tracks **1,235**, of which the i386 farm is 174 MB.

### 6.2 Split into focused PRs, in dependency order (rev. 2026-09-24)

Will asked (Discord, 2026-09-23) for separate PRs: 32-bit, Steam/UI and controller support. The owner added the new front end and XInput. The series below follows those lines. Each PR has a submodule part (to `willfaust/FEX` `ios-port-2607`, `willfaust/wine` `madeira-lgpl`, `willfaust/dxmt` `ios-port`) and a top-level part that bumps the pins only after its submodule parts have landed. Every new behaviour keeps its kill switch, moved onto a `madeira.cfg` key with the env name kept as an alias.

| # | PR | Repos | Scope | Depends on |
|---|---|---|---|---|
| **0** | **Fixes to upstream found during the merge** (warm-up; no features) | FEX, wine, Madeira | FEX `AllocatorHooks.cpp`: no `IOS_RPM_GUARD` in the system-malloc path (the iOS-host FEXCore build fails). wine: commit the missing `dlls/ntdll/arm64ec_x64_export_iat.c` (upstream's `loader.c` includes it; Will's copy is untracked, so upstream does not build from a clean clone. Ask Will for his file rather than ours.) and `config.h` first in `unix/sync.c` (makedep rejects the current order). `StikJITHelper`: the pool census drops the free space after the last mapping (shrinks the pool on 512 GB maps); the RW-alias hint `0x7000000000` is above the task map on 63 GB devices (no pool at all); release the early placeholder once. `server_ios.c`/`thread_ios.c`: an exiting thread releases `fd_cache_mutex` (seen wedging whole sessions). win32u `driver_ios.c`: child-window layers framed in desktop coordinates (swapchains in child windows drew at the desktop origin). | — |
| 1 | rpmalloc available-list invariant | rpmalloc | Small allocator fix. | — |
| **2** | **32-bit (WoW64) support** | FEX, wine, Madeira | FEX: the WOW64 module on iOS (guest-window base register, 32-bit dispatcher/codegen, x87 default, DEP promotion, syscall-blocked thread sweeper). wine: window-aware pointer conversion (ntdll/wow64, wow64win, dwrite, dnsapi, process attributes), per-thread `is_wow64()`, exception params, per-process zero_bits/GDI, initial-context retry. Madeira: `virtual_ios.c` 4 GB windows (512 GB and 63 GB layouts, small-VA band), guest fault routing in `signal_arm64_ios.c`, 32-bit unixlib tables (ntdll, winemetal wow64 slots), i386 farm build script (macOS form, not the WSL adapter), `docs/WOW64.md`. **Coexistence with upstream (must ship with it):** sub-floor relocation/windows for PE32+ only (`MADEIRA_SUBFLOOR_PE32`); no FEX arena reservation on maps without the high band (`MADEIRA_FEX_ARENA_SMALL`); JIT pool outranks the 0x140000000 window when only giving the window back makes the pool fit (`MADEIRA_POOL_OVER_EXE_WINDOW`). Must not regress 64-bit titles: Will's RDR2 run is the check. | 0 |
| 3 | D3D9 via DXMT | dxmt, Madeira | D3D9 frontend + i386 DXMT build + wow64 thunks + d3d9shim, DXTn CPU decode; app wiring. **Licence decision on the D3D9 import first.** | 2 |
| **4** | **Controllers and XInput** | wine, Madeira | wine: XInput through win32u (host gamepads), dinput host joystick (opt-in). Madeira: `HardwareInput.swift`, on-screen controls, the layout editor, **control presets** (save/load; built-in Xbox preset offered, never auto-loaded). Replaces/extends upstream's own open PR #16 (XInput host controllers); check with Will which he prefers. | 0 (independent of 2) |
| **5** | **New front end** | Madeira | Library UI (default front end, switch to the developer UI and back with a restart notice), game details, in-game menu (touch controls/edit/keyboard on top, overlay settings at the bottom, red Quit), build stamp on the Library and Settings. No Steam code; Steam entries appear only once 6 lands. Launch rows follow Will's app conventions. | 0 |
| **6** | **Steam** | wine, Madeira | Madeira: SwiftSteam sign-in (password + Steam Guard, QR; **field-number fix for typed passwords**), library and depot downloads, the Windows Steam client path (installer keep-alive, headless consoles, `-cef-disable-hang-timeouts`, web-helper QoS, launch-progress view), onboarding (install client, sign in, restart prompt, "Run setup again"), the Steam button. wine: NSI pending change requests, loopback accept/socket fixes, async/APC hand-off. **Credited to Jfishin**; get his explicit OK for GPL-3 + converter exception. **No DRM circumvention** (none exists in this fork). **Gate 2 applies.** | 2, 5 |
| 7 | Sync and I/O fast paths | wine | fastsync cells (opt-in while madsync is upstream's default; benchmark both first, as Will suggested), FS directory/case cache, negative lookup (off by default). | 2 |
| 8 | ARM64EC/iOS FEX perf | FEX | Lock-free JIT test, two-way L1, pool-return fast path, CPUID bound, unaligned-atomic counters. | 1 |

**Order:** 0 → (1) → 2 → 4 and 5 in parallel → 3 → 6 → 7/8. PR 0 lands useful fixes for Will's own tree with nothing to argue about and shows how he reviews. PR 2 is the core value and the heaviest review. PR 6 goes last because of Gate 2 and its provenance and ToS sensitivity.

**Test matrix per PR** (device, owner): iPhone (512 GB map) and A16 iPad (63 GB map), each series built alone on the then-current upstream head. 32-bit: a D3D9 title and the Steam client install. Front end: fresh install and "Run setup again". Controllers: a USB pad and on-screen controls. Steam: fresh onboarding, QR sign-in and typed-password sign-in, a client-routed launch. Every PR: one 64-bit title, and ask Will to run RDR2.

**Build-side caveat:** Will builds with Xcode on macOS; this fork builds with the WSL/xtool adapter. Every PR must express its build changes in `build/*/build.sh` + the Xcode project. We cannot run Will's Xcode build here, so ask Will (or a macOS machine) for one clean build of each PR before merging.

### 6.3 Clean-up before submitting
- **Branch hygiene**: build each PR on a fresh branch off the then-current upstream head. Squash our `ml`-series into logical commits using the topic-first subject style, with `Signed-off-by` (DCO) and the Co-Authored-By trailer. Keep full history on the 125hz `main` for reference and link it in the PR text.
- **Never include**: `.xtool/`, `xtool/`, `xtool.yml`, `Package.swift`, `AGENTS.md`, `CLAUDE.md`, `HANDOFF.md`, logs, IPAs, `.pyc`/`__pycache__` (currently tracked in dxmt), `build/dxmt-tests/out-host/`, and host-test binaries (`fastsync-*`).
- **Build integration**: express any build change in upstream's macOS `build/*/build.sh` + Xcode terms. The i386 farm needs a real `build/wine-i386/build.sh`-style script, not the WSL adapter. Offer `.xtool` separately as an optional "Windows/WSL build" doc if Will wants it.
- **Binaries**: ask Will first. Offer (a) the scripts only, so Will rebuilds, or (b) a separate artefact PR. Do not put 174 MB of i386 DLLs into a code PR.
- **Diagnostics**: keep the always-on low-volume tags that match upstream's style. Remove one-shot probes, spent censuses and experiment toggles that never shipped enabled. Keep `mlNNNN` references only where they cite a documented finding, and consider re-tagging ours to avoid clashing with Will's numbers.
- **Kill switches**: keep them as feature flags, but move them onto `madeira.cfg` keys (and env) to match upstream's single config. Default-off anything upstream may not want (fastsync if madsync stays, dinput host pad, negative cache).
- **Game names**: none in code or commits (already our rule). Also scrub existing name-bearing log strings.
- **Docs**: `WOW64_DESIGN.md` (14.9k lines) and `STEAM_INTEGRATION.md` are working logs. Write condensed upstream-facing docs, for example `docs/WOW64.md` (architecture, VA layout, invariants, switches) and `docs/STEAM.md` (scope, what was removed: DRM, launch emulator and cloud). Keep the logs in the fork.
- **Licensing**:
  - The owner grants the Madeira Converter Exception for 125hz code (the CONTRIBUTING requirement).
  - Wine work is LGPL-2.1+ on `madeira-lgpl`.
  - D3D9 import decision (keep LGPL-2.1 rather than the §3 GPL conversion).
  - Merge our THIRD-PARTY-NOTICES rows (FFmpeg LGPL build, zstd BSD, liblzma, SwiftSteam/Jfishin, D3D9 import) into upstream's `app/Madeira/licenses/THIRD-PARTY-NOTICES.txt` and `docs/LICENSING.md`.
  - The FFmpeg fetch/build script must become a tracked `build/` script.
- **Bundle ID / team**: PRs must not change upstream's bundle ID (`com.willfaust.madeora`) or team. That is fork-local.

### 6.4 Checklist and rough effort (after the Section 4 integration is done and both gates hold)
1. [ ] Owner says "open the MR", and Steam client launches have been confirmed on device.
2. [ ] Fetch upstream again. Re-run section 1's counts. If upstream moved, merge again first.
3. [ ] Licence items settled: exception grant, D3D9 import licence, Jfishin permission. (Owner action; lawyer optional.)
4. [ ] Create per-PR branches and squash into logical commits with DCO sign-off (about 1 day per large series: FEX, wine, top-level WoW64).
5. [ ] Write the condensed docs (about 1 day).
6. [ ] Diagnostics and flag clean-up per series (1–2 days).
7. [ ] Build each series on a clean upstream base using upstream's build scripts, plus a device smoke test of each series alone. Upstream's layout must not regress 64-bit titles: 3–5 device rounds.
8. [ ] Open PRs in order: 1/3/11 → 2/4 → 5/6/7 → 8 → 9/10 → 12 → 13. One or two at a time, following Will's feedback.

Total: about **1.5–3 weeks** of preparation plus review latency. Upstream has merged nothing external so far, so expect long or no review.

### 6.5 Risks for the MR
- Will may decline large series (WoW64, Steam) or prefer to re-implement. Keep everything behind flags so partial acceptance works, and keep our fork viable regardless.
- Steam code has provenance (Jfishin) and ToS sensitivity. Upstream may not want it at all, so offer it last and separately.
- The licensing prerequisites (converter exception, the LGPL D3D9 import) are blockers, not nice-to-haves.
- Upstream moves fast: 50k lines in one week. Long-lived PR branches will rot, so submit small and early once the gates open.
- AI-assistance disclosure: fine for willfaust repos (Will uses it too). Nothing from these forks may go to FEX-Emu/FEX upstream.

## 7. Status (2026-09-23, end of session)

- **Phase 0 done.** Every repo has its work committed on `wip/pre-upstream-2026-09`, and the pre-work HEADs are tagged `pre-upstream-merge`; both are pushed to the 125hz forks.

  | Repo | wip commit | tag |
  |---|---|---|
  | Madeira | `4466fb6` | `db4b7fd` |
  | FEX | `a1832c199` | `e6f628092` |
  | rpmalloc | `214482d` | `e0a3eae` |
  | wine | `1c10390f305` | `932a390d9cb` |
  | dxmt | `9dd016e` | `49dbb94` |

  The IPA at that state is ml1620 (SHA-256 1885b73b…). The phone's setup is verified on device; the tablet's client start is device-unverified (ml1620 turns off the client's browser-hang kill).
- **Phase 1, rpmalloc: done**, on branch `upstream-merge` (pushed).
  - Merge `1f271c0`: clean.
  - Then `42fe7b5` makes the 12 GB small-map arena a constant. The ml1600 version read `MADEIRA_FEX_ARENA_WIDE` with GetEnvironmentVariableA inside `ios_fex_band_select`, which upstream notes runs before the ARM64EC TEB exists, where that call faults. Our shipped WOW64 xtajit.dll (ml1600-ml1620) worked on device, but the arm64ec build would not have.
  - FEX's pin has NOT been moved to it yet.
- **Phase 1, FEX: started and aborted, nothing committed.** Trial merge of `upstream/ios-port-2607` into a branch from the wip commit. Conflicts:
  - External/rpmalloc: take `42fe7b5`.
  - CPUBackend.cpp and CPUBackend.h.
  - ARM64EC: IosJitAlias.cpp, Module.S, Module.cpp, libarm64ecfex.def.
  - The ARM64EC alias-translation fast path exists on both sides with different designs: ours is an `IosAliasHot` index plus `IosAliasJitSpan` fast-out, walking forward; upstream's is an `IosAliasLast` pointer, newest-first. Upstream's auto-merged lines assume the backward walk, so the stub cannot be mixed hunk by hunk.
  - Plan: keep our xlate stub whole (device-measured), then re-add upstream's `IOS_XP_COUNT`/`IosXpFex` transition counters and its reverse-lookup and pool-placement changes (Module.cpp, CPUBackend) by hand.
  - Build both FEX targets, then the arm64ec x64 baseline on device.
- **Next:** finish the FEX merge as above, then wine (cherry-pick onto `madeira-lgpl`), then dxmt, then the top level, with the gates in section 4.

### Status update (2026-09-23, later)

- **rpmalloc `upstream-merge` `42fe7b5`: done.**
- **FEX `upstream-merge` `49b0f3f1e`: done and pushed.** Both targets built (WOW64 xtajit.dll, arm64ec xtajit64.dll).
  - Ours kept: CPUBackend (our ml630 lock + lock-free ranges; upstream's 128 MB-per-thread code buffers would exhaust our shared pool) and our ExitFunctionEC stub, whole.
  - Both kept: upstream's IosXpFex counters, sub-floor windows, FFS last-hit and exports.
  - The WOW64 module got identity sub-floor lookups for FEXCore's new references.
  - No new thread_local.
- **wine `madeira-lgpl-125hz` `6bd1cdd7ad4`: done and pushed.**
  - All 48 of our commits were cherry-picked with -x onto `upstream/madeira-lgpl`.
  - Verified: for every code file under dlls/server/programs/include/loader, the wip→branch difference equals upstream's own change since 6d3c1d6 (licence lines ignored).
  - LGPL headers kept.
  - A first attempt was discarded: an unanchored conflict-marker regex had truncated unix_private.h.
- **dxmt `upstream-merge` `08d7aab`: done and pushed.**
  - Slots: 127-138 upstream, 139-144 NULL, 145-150 ours; 151 in both tables.
  - The generated headers were regenerated.
  - Not built yet: it needs the top level's `build/madeira_cfg.h` (Phase 4).
- **Next: Phase 4, the top level.** Merge upstream/main, point the submodules at the three branches above, adapt `.xtool` (madsync, madeira_cfg.h, the D3D12 objects using the converter at `C:\Program Files\Metal Shader Converter`), rebuild every farm, run the gates, then device checkpoints.

### Status update (Phase 4, top level)

- **Madeira `upstream-merge` `434a6e0`: merge of `upstream/main` `5a82d39` committed locally.**
  - Submodule pins: FEX `upstream-merge`, wine `madeira-lgpl-125hz` `6bd1cdd7ad4`, dxmt `upstream-merge` `08d7aab`. `.gitmodules` keeps the 125hz URLs.
  - **Sync default:** madsync is built in but **off by default** (`madeira.cfg inproc-sync = 1` opts in). The fastsync cells stay the in-process wait path, so the two designs never compete for the same waits. A/B on device before flipping.
  - **JIT pool:** ours (process-lifetime cached pool, early allocation, remembered size, fallback sizes, re-roll with blocked holes, explicit placement) plus upstream's executable-window hold at 0x140000000, early placeholder release, hole census/shrink and first-fit plugs. Every placement check also rejects the window. The placeholder is released once, so a fallback retry cannot unmap the debugger's range. The `pool` override is read through `MadeiraConfig`, so it survives upstream's legacy-file migration.
  - **Kept ours:** bundle ID `com.willfaust.mythicemu` and team `UT49TA9TA4`; the library/launch UI; the desktop size from the session's virtual monitor; no per-test launch buttons (upstream's D3D12 cube/M2/clock/call-cost buttons run through Custom…).
  - **Took upstream:** the virtual-monitor adapter open (it adopts the registered GPU LUID), the checked surface snapshot (`winios_surface_present` returns int), abort_process teardown (ours kept, same design), CAP/ECO pills, `madeira.cfg`.
  - **wow64 unix-call table:** stub for the `get_fex_arena` slot, so both tables have 13 entries.
- **`.xtool` adapter (gitignored):** syncs `build/madsync` and `build/madeira_cfg.h` for the native parts. For DXMT it syncs `research/madeira-d3d12` and takes the converter headers from `C:\Program Files\Metal Shader Converter` (4.0.1). That install has no `metal_irconverter_runtime` header, so the in-app M1 canary is replaced by a stub that reports "not built". The conversion service (`madeira_ir_unix`, `madeira_sm5_ia`) is compiled normally.
- **Build fixes found by the first full rebuild (ml1630):**
  - FEX `039dd4051`: upstream's `AllocatorHooks.cpp` called `IOS_RPM_GUARD()` in the non-rpmalloc `malloc_usable_size`, where the macro is undefined.
  - dxmt `2d0a3bf`: `WMTNop` lost its closing brace in the merge, so the D3D12 thunks after it did not compile.
  - wine `5d373ab8036`: upstream's `loader.c` includes `arm64ec_x64_export_iat.c`, which upstream never committed (its handoff calls it an untracked review candidate). Reconstructed from the handoff's description: a slot is kept x64-facing when one of the module's own exports outside native code is `FF 25 disp32` pointing at it. Also `config.h` before `madeira_cfg.h` in `unix/sync.c`, since makedep requires it. **The IAT classifier is a reconstruction and unverified on device.**
  - `virtual_ios.c`: our ml901 block lost its closing brace when upstream's ml1074 loop was merged beside it. `signal_arm64_ios.c`: upstream's sub-floor path now passes the guest address as our store emulator's fourth argument. `server_ios.c`: the xtool SDK has no `ri_page_wait_time_mach`, so `[xp] pgw` prints 0.
  - Checkout hygiene: with `core.autocrlf=true`, the wine checkout was CRLF and `config.status` produced a `config.h` with no `HAVE_*` defines. The wine repo is now `core.autocrlf=false`/`core.eol=lf`; the adapter strips CR from `config.h.in`.
- **ml1630 IPA verified:** 1365 -> 1387 entries against ml1620, 0 gone, 22 new (d3d12/, licenses/, four x64 test exes, madeira_d3d12.dll); archive clean; bundle ID and build label correct. The farms rebuilt ntdll (i386, aarch64, arm64ec), DXMT (i386, aarch64, arm64ec), xtajit and xtajit64.
- **Device baseline:** ml1620 (pre-merge) installed and signed in to the Steam client on the A16 iPad as well as the iPhone. Any regression in Steam setup on ml1630 is therefore the merge.
- **Host tests:** all 42 `build/host-tests/check-*.py` suites pass on the merged tree.
- **Open:** `libmetalirconverter.dylib` signing under xtool (only the D3D12 path dlopens it); `madeira_d3d12.dll` is upstream's prebuilt copy until `build/madeira-d3d12/build-pe.sh` is pointed at `.xtool/toolchains/llvm-mingw`; device checkpoints (Steam client setup on iPhone and iPad, a D3D9/D3D11 title, a 32-bit title, then an upstream D3D12 title).
