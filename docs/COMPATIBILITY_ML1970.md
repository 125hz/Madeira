# ml1970: Dock launch readiness, pool guard, start modes and controls

This round answers the owner's 2026-09-25 list and device logs 66–72 (build
ml1960). Every behaviour below is generic, has a `MADEIRA_*` kill switch and an
ml1970 log tag. Nothing here is proven on device yet.

| Log | App | Finding | Change |
| --- | --- | --- | --- |
| 66, 67 | 220 | Repair (ml1960) wrote shared depots 340/380/389/420 into the game's own `InstalledDepots`. Valve's client moved them to `SharedDepots`, marked owner apps 340/380/420 "Update Required" and refused the launch: `Failed running app 220 (required app 340 not ready)`, `launch-client-error=17`. Dock gave up 5 s later (code 45). | Downloader writes Valve's record shape; Dock waits for Valve's client to finish required content, then asks again. |
| prev 4, 68, 69 | 22380 | The launcher does start the game. The game's ntdll copy lands on JIT-pool pages already non-executable (`[pool-poison] HANDED OUT NON-EXEC` from the exact end of the SteamStub payload's pool copy), faults at its first instruction, 2000 redeliveries, `c0000005`. | Clamp the image-copy section protection; quarantine poisoned ranges. |
| 70 | 304430 | Not rendering-related: a stop-the-world deadlock. Steam creates the game suspended and resumes it before init; the first thread's ml1330 start-context wait stayed armed, so the GC's GetThreadContext on the main thread waited forever after one Present. The ml1960 CAS fix did engage. | Clear the wait in `init_process_done`. |
| 71 | 3525970 | Godot 4.7: Vulkan missing (expected), D3D12 driver fails on `LoadLibrary("Dcomp.dll")`, OpenGL refused on ARM64 hosts, exit 1. | Ship Wine's `dcomp`/`ktmw32` for arm64ec; D3D12 reports typed UAV loads. |
| 72 | 17410 | ml1960's D3D9 batch budget billed each tiny state/query flush a full 4×64 KiB reserve: ~200 forced submissions/s, render thread at 60–84 % CPU, 0.5 s-step stalls. Periodic diagnostics were ruled out (present during smooth 60 fps windows). | Charge bytes actually used, trim sparse captures, 16 MiB threshold. |

## Madeira Dock (private host, stripped EXE staged)

`launch.c`: when Valve's `LaunchApp` result is 17 (dependency not ready), 19
(update required) or 20 (busy), Dock keeps Valve's client alive while its own
scheduler installs/updates the content, and asks again after 10 s, 20 s, then
every 30 s, up to 6 hours. Only Valve's own later success starts the game;
licence, connection and every other refusal still fail closed. Repeated
results are logged only when they change (bounded report file). New report
fields `launch-update-wait/retry/ready` (round ml1970); a wait that ends without
success is host result 48. `MADEIRA_DOCK_CONTENT_WAIT=0` restores the immediate
failure. The app now explains Valve's refusal codes in words (license,
connection, content, missing executable, region, release).

## Shared-depot install records

A depot taken from another app (`depotfromapp`) is written the way Valve's
client writes it: under the game's `SharedDepots` (depot → owner app), not its
`InstalledDepots`, plus a merged `appmanifest_<owner>.acf` listing exactly the
depots installed (owner's name/public build; its other depots kept). Owner
records are written only when the owner installs to the same folder (where the
files are). Uninstall removes owner records for that folder. The downloader
fetches owner metadata for this (`[steam-shared-record] ml1970`).
`MADEIRA_STEAM_SHARED_RECORDS=0` restores the single record. Existing installs
need no reinstall: with the Dock wait, Valve's client repairs its own records
(it reuses the files already present); "Repair installed files" rewrites them.

## One-time installs under Madeira Dock

Dock launches through Valve's app manager, the step after the desktop client's
launch tasks, so install scripts are never evaluated under Dock (no
`RunningInstallScript` in any Dock log; desktop logs show it). Madeira now does
it (`[dock-installers] ml1970`, `MADEIRA_DOCK_INSTALLERS=0` restores ml1780):
programs Madeira's Wine provides (DirectX, Visual C++, .NET installers — which
failed under emulation per ml1780) are marked done; every other not-yet-done
program (OpenAL, PhysX, publisher setup…) is written to
`C:\madeira-dock-installers.cmd`, which the Dock session runs with `cmd.exe`
before `dockhost.exe`; each is marked done (both registry views) only after it
exits with status 0, so later starts skip it. Arguments with shell operators
and paths outside the folder are refused. The game's "Also run DirectX and
Visual C++ installers" option queues the provided ones too. Registry values
from install scripts keep being applied by ml1960's SteamInstallRegistry.

## Runtime

* `wine/server/process.c` `init_process_done`: a first thread told not to park
  clears `ios_start_pending` (`[ctx-start] ml1970`); `MADEIRA_CTX_START_WAIT=0`
  still rolls back all of ml1330.
* `virtual_ios.c`: the image-copy and child-ntdll writable-section `mprotect`
  never reaches past the copy's own pages (`[pool-guard] ml1970`,
  `MADEIRA_POOL_SECTION_CLAMP=0`); a range handed out non-executable is left
  allocated and the next taken, up to 16 tries / 64 MiB per session
  (`[pool-quarantine] ml1970`, `MADEIRA_POOL_QUARANTINE=0`). The clamp is the
  inferred cause (the only pool protection change in that window); the
  quarantine protects the next process regardless.
* D3D9 (`d3d9_batch_budget.hpp`, `FlushDrawBatch`): used-bytes charge,
  sparse-capture trim, 16 MiB threshold (`[d9-batch-budget] ml1970`,
  `MADEIRA_D3D9_BATCH_USED=0`; `MADEIRA_D3D9_BATCH_BUDGET=0` still disables all).
* `madeira_d3d12.dll` (rebuilt locally, same exports/imports):
  `TypedUAVLoadAdditionalFormats` matches FORMAT_SUPPORT (`[d3d12-caps] ml1970`,
  `MADEIRA_D3D12_TYPED_UAV_LOAD=0`). `dcomp.dll`, `ktmw32.dll` added to
  arm64ec-windows (zero missing imports). Whether Godot's shaders then convert
  and render is unproven.

## App UI

* Library top bar: the Steam button is hidden (`MADEIRA_LIBRARY_STEAM_BUTTON=1` shows it).
* Settings › Windows Steam client: "Regular Steam" status, **Download and install
  Steam** (Valve's installer, or Steam's own bootstrapper when Dock's components
  are present), **Boot Steam** / Big Picture on a Wine desktop, enabled once the
  regular client (its web helper) is installed. `MADEIRA_STEAM_REGULAR_ACTIONS=0`.
* Game details › Start with: **Madeira Dock** (default), **The game**, **Steam
  (more usage)** (greyed out until regular Steam is installed; field
  `steamDesktopLaunch`, `[steam-start] ml1970`).
* Artwork: PICS `library_assets_full`/`header_image`/`parent` names are cached;
  cards try the hashed capsule, the legacy URL, a demo's full game, then the
  store header image (`MADEIRA_STEAM_ARTWORK=0`). The library list refetches once.
* Touch controls: loading a layout now rebuilds and re-arms the controls like
  the off/on toggle did (`[controls-layout] ml1970`, `MADEIRA_CONTROLS_LAYOUT_REFRESH=0`).
  Editor: **Done** replaces the exit arrows, the controller and pencil glyphs are
  hidden, edits to a custom layout are kept (`MADEIRA_CONTROLS_EDITOR_DONE=0`).
  Session menu: **Controller layout** (only while Touch controls is on) — Xbox
  (default for games without a layout, `MADEIRA_CONTROLS_XBOX_DEFAULT=0`), Custom
  Layout 1…N, **Create new layout** (opens the editor on an empty layout).

## Validation

Dock: portable ASan/UBSan tests (25 validation cases incl. content-wait), both
PE builds with `-Werror`, privacy check; staged EXE SHA-256
`44f1b0ccbba229cbb9fce4c7b5067bf8975a15e6da522d2e3e52f5b8f5ac862a`. Host:
`check-ml1970.py` (install-script parsing, marks, batch, shared records, desktop
detection; 30 checks), `check-compatibility.py` (batch accounting incl. the
ml1960 over-submission case), control-presets, controls-edit, steam-native,
steam-library, onboarding and launch-view suites pass. Native ntdll/wineserver,
DXMT PE (i386/aarch64/arm64ec), arm64ec dcomp/ktmw32 and madeira_d3d12 build.
No Wine-on-PC, Steam or game run; device results are required for every fix.

## ml1970 IPA verified (2026-09-25)

`xtool/Madeira.ipa`, label `ml1970 · 09-25 19:04`, 166,528,542 bytes / 1,391 entries
(ml1960 + arm64ec dcomp.dll, ktmw32.dll). SHA-256
`934f71853e282eb8d409bc2adf9d334bab34fbed0a9ca2cc7c253bd23322958b`. All 1,273
Windows resources match the source folders; ml1970 strings present in the app,
native ntdll/wineserver, the three D3D9 builds and madeira_d3d12; stripped Dock
(SHA-256 above), notices, source/login/Valve-DLL exclusions and seals pass.
Reports: `.xtool/logs/ml1970-build.log`, `ml1970-native-build.log`,
`ml1970-dxmt-pe-build.log`, `ml1970-verified.json`; verifier `.xtool/verify-ml1970.py`.
