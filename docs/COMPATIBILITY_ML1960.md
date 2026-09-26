# ml1960: launch metadata, alias atomics and queued batch memory

This round responds to the nine attachments supplied on 2026-09-25. It changes
the public app and runtime. The private Dock executable, authentication,
subscription checks and original Steam APIs/DRM are unchanged. No private
source, developer account data or Valve client DLL is added to the app.

## Evidence and limits

Attachment names below use their numeric local prefixes to disambiguate the
duplicate display names. Seven longer sessions report authenticated online,
requested app listed and launch-client-error=0. A visible Dock console alone
does not diagnose an authentication failure or prove that a game rendered.

| Attachment | Build / app | Finding |
| --- | --- | --- |
| 1, 2 | ml1950 / 220 | Ends before Wine/Dock start. Download selected four depots and skipped owner-referenced depots without local manifests. Source also rejected imported default launch arguments. |
| 3 | ml1950 / 304430 | Native CASAL instruction `c8e8fce0` faults against an existing secondary RX/RW alias. The Mach handler's CAS path only accepted the primary pool; fault escaped into guest exception handling. |
| 4 | ml1950 / 17410 | Guest VA exhaustion: 4,049 MiB mapped, 46 MiB free, largest hole 0x90000, request 0x210000. New rendering thread created most large views; one ucrt allocation site accounts for about 2.6 GiB live. |
| 5 | ml1950 / 17410 | Same class of failure after sustained play: request 0x220000, largest hole 0x1f0000. Rendering thread accumulated 978 views of that size. Empty-group reclaim did not recover sufficient contiguous space. |
| 6 | ml1950 / 4505330 | Creates a D3D11 swapchain but no Present captured. No conclusive terminal fault. The unsupported-swap-effect warning is nonfatal in the current implementation. Cause remains unresolved. |
| 7 | ml1950 / 3525970 | Application reports failed OpenGL/display-server initialization and exits 1. Missing ktmw32 for an optional integration and missing dcomp also appear. No evidence that adding those modules alone supplies a working renderer. |
| 8 | ml1910 / 220 | Tester reaches rendering, including 60 fps windows, then a stall. No terminal crash record or VA exhaustion. Predates the recent heap/CPU diagnostics. |
| 9, photo 10 | ml1910 / 22380 | Valve launches the original launcher, which says installation metadata is absent. Existing native installation did not apply publisher registry values from install scripts. |

The allocation evidence identifies a runtime allocator and creator thread,
not the full caller stack. The batch-retention defect below is confirmed in
source and consistent with that pattern; the next device run must establish
whether it eliminates this particular crash. Post-exit faults are not treated
as the initial failure. There is no JIT-pool exhaustion in these two sessions.
Guest virtual address space, physical footprint and GPU allocations are
different budgets.

## Changes

### Steam installation and launch metadata

* `LibraryEntry.steamDefaultArguments` records imported default-option arguments.
  Older entries recover this provenance only when cached Steam metadata matches
  both the executable and argument string. Dock still asks Valve to launch the
  default option. Modified/custom arguments remain rejected rather than silently
  discarded. Validation failures now appear in the exported diagnostic log.
  Rollback: `MADEIRA_DOCK_DEFAULT_ARGUMENTS=0`; tag `[dock-arguments] ml1960`.
* The downloader resolves missing shared-depot manifests through the exact
  `depotfromapp` reference, including bounded nested references and cycle detection.
  It does not traverse unrelated owner depots. Existing consumer filters and
  language/platform selection remain. Missing required metadata fails explicitly
  instead of labeling a partial selection complete. Depot keys still require
  Valve authorization; owner metadata never grants access. Manifest/CDN requests
  use the containing app for paid content, retaining the free-to-download case.
  Rollback: `MADEIRA_STEAM_SHARED_METADATA=0`; `[steam-shared] ml1960`.
  Existing downloads are not silently redownloaded or given invented owner-app
  manifests. A download/update is needed to acquire previously omitted content.
  Installed native entries now offer **Repair installed files** in their Steam
  settings, using the existing downloader's chunk verification and download queue.
  This can fetch omitted content without uninstalling and uses the current public
  build. Interrupted repairs resume through the existing journal mechanism.
  `MADEIRA_STEAM_REPAIR=0` hides/disables this entry point; `[steam-repair] ml1960`.
* Before Wine starts, `SteamInstallRegistry` applies supported `Registry`
  string/DWORD values from bounded, contained install-script files. It handles
  duplicate sections, English localization, default values, ordinary install-path
  variables, HKCU and both HKLM Software views. Writes are idempotent and atomic
  per registry file. It does not execute `Run Process`, mark prerequisites done,
  or emulate entitlement. Unknown variables/types are omitted; malformed metadata
  stops setup explicitly. This is a supported subset, not a complete replacement
  for every Steam installation action or script signature validation.
  Rollback: `MADEIRA_STEAM_INSTALL_REGISTRY=0`; `[steam-registry] ml1960`.
  The switch prevents subsequent application, not reversal of prior registry
  writes. The older prerequisite-skipping policy is not changed this round.

Primary references: [Valve install scripts](https://partner.steamgames.com/doc/sdk/installscripts),
[Valve depots](https://partner.steamgames.com/doc/store/application/depots), and
[SteamRE DepotDownloader source](https://github.com/SteamRE/DepotDownloader/blob/master/DepotDownloader/ContentDownloader.cs).
SteamRE is a separate open-source project, not Valve's client implementation.

### Native alias atomic compatibility

The existing signal-safe CAS core now also accepts registered secondary aliases
when the complete aligned 4/8-byte operation resolves to contiguous RW backing.
Unknown aliases and unsupported instructions still fault normally. Atomic
success/failure and register-width semantics are preserved; no new mapping or
permission is granted. Rollback: `MADEIRA_SECONDARY_CAS=0`, read before starting
the exception handler. Tag `[mach-cas] ml1960`, capped operation reports.

### D3D9 CPU batch retention and allocation overhead

`FlushDrawBatch` previously reserved the largest historical vector size for
every next batch. Even a tiny state-only batch could therefore capture a large
mostly empty allocation until its command chunk retired. The implicit-submit
policy tracked GPU uploads/renames but did not account for these CPU vectors.

The new policy caps speculative reservation at 64 KiB per vector, compacts
large mostly empty vectors before capture, and submits through the existing
queue after at least 8 MiB of captured batch capacity. Normal queue retirement
and its 32-chunk fence remain responsible for lifetime; resources are not freed
ahead of GPU completion. A single large batch may exceed that threshold, and
other resource classes are outside this counter. Do not describe it as a hard
whole-app memory limit. Live guest pointers never move.

Rollback: `MADEIRA_D3D9_BATCH_BUDGET=0`. `[d9-batch-budget] ml1960` logs enablement
and the first/every 256 pressure submissions. Applies to native and emulated
D3D9 frontends, rebuilt for i386, aarch64 and arm64ec. Existing compact JIT pool,
light per-call diagnostics and ml1950 attribution are retained. Reduced allocator
work/retention is the intended performance benefit; neither 60 fps nor any
measured FPS increase is established by a host build/test.

## Validation and next device run

Production-source host checks cover registry values/merging/malformed input,
exact/nested depot references, unrelated/language exclusions, cycle rejection,
default-vs-custom launch arguments and rollbacks. ASan/UBSan checks exercise the
actual faulting CAS opcode (success/failure, 32-bit zero extension, alignment
and opcode rejection) and vector compaction/moved ownership/batch accounting.
The batch test does not execute the Metal queue. Existing Steam native decoder,
library/configuration regressions pass. Native Wine and DXMT plus all three
D3D9 PE architectures compile. Full app/artifact verification is recorded in
HANDOFF.md when packaging finishes.

Install over the existing app, fully quit/reopen and re-enable JIT. First retest
the previously installed launcher and default-option launch without reinstalling.
If required content remains missing, open the installed entry's Steam settings
and select **Repair installed files** to use the new metadata resolver. Do not
install unrelated products merely because a depot references
their app ID. Repeat the long D3D9 session and the secondary-alias startup case.
Export a log even after success and compare the same scene/settings for FPS.
The tester should use this build and capture a fresh log at the transition hang.

Unresolved: the D3D11 no-Present session, the OpenGL/display-server path and the
older tester transition hang lack enough evidence for a confirmed fix. A newer
log is required to separate those from the repaired paths. No device result,
upstream PR change, commit or push is claimed for this round.


## ml1960 final IPA verified (2026-09-25)

`xtool/Madeira.ipa`, label `ml1960 · 09-25 15:11`, 166,404,949 bytes / 1,389 entries.
SHA-256: `97b686f926cb2590f18430920bcb8738bb4d36358045b930b3cd89ca931280fe`.

CRC, all 1,271 Windows resource hashes, new Swift/native/three-architecture
D3D9 markers, unchanged stripped Dock, redistribution notices, source/login/
Valve-DLL exclusions and resource seals pass. Relative to ml1950, only Madeira,
Info.plist, seals and the rebuilt graphics PE files changed; no entries added
or removed. The i386 ntdll and private Dock binary remain byte-identical.

Final source includes the repair control, cancellable shared-content lookup,
argument-provenance persistence and all runtime fixes described above. Production
registry filesystem/idempotence tests, nested/cyclic depot resolution tests,
actual CAS opcode and vector ownership sanitizer tests, and library migration/
argument/config/native decoder regressions pass. Native Wine/DXMT and all three
D3D9 PE builds plus full Swift compile/link/package pass. Existing unrelated
Swift/toolchain warnings remain. No local Steam/game or on-device execution.

Reports: `.xtool/logs/ml1960-build.log`, `ml1960-native-build.log`,
`ml1960-dxmt-build.log`, `ml1960-dxmt-64-build.log`, `ml1960-verified.json`,
`ml1960-attachments-analysis.json`, `ml1960-compatibility-tests.log`,
`ml1960-library-tests.log`, `ml1960-steam-tests.log`.
Verifier: `.xtool/verify-ml1960.py`. Tests/builds are not proof of device crash
prevention or FPS gains. No commit, push, upstream PR or private source change.
