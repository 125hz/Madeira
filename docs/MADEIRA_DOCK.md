# Madeira Dock integration and device tests

## ml1960 compatibility update

The new attachment set passes genuine Dock authentication in every session that
reaches the host. Public app/runtime changes handle imported default launch
arguments, shared-depot manifests, installation registry values, secondary-alias
CAS and D3D9 batch memory. See [COMPATIBILITY_ML1960.md](COMPATIBILITY_ML1960.md).
The private host and stripped executable are unchanged. No credentials or Valve
DLLs are bundled. Unresolved renderer/transition hangs are not proof of a Dock
authentication failure. Device retests remain necessary.

## ml1910 — Dock onboarding enabled by default (2026-09-25)

The owner requested a fresh-install IPA with Dock and native setup already
enabled because they cannot edit madeira.cfg during onboarding. This explicitly
supersedes ml1900's opt-in-only decision. Both MADEIRA_DOCK and
MADEIRA_DOCK_NATIVE_SETUP now default true; explicit =0 overrides still work.
MadeiraDock.nativeSetupEnabled is shared by onboarding routing and its low-volume
[dock-defaults] ml1910 diagnostic. No configuration file is needed on a fresh
install. Flow: welcome, native Steam sign-in, Prepare Madeira Dock (download and
verify ~73 MB of official Valve components), library. Wine desktop installation
is only an explicit fallback. Genuine client files are still downloaded; they
are not bundled in the IPA. Private Dock/authentication/DRM checks are unchanged.
Existing Steam files are retained. Clean-prefix device authentication/launch
is still awaiting the owner's test, not proven by changing these defaults.
Host onboarding/configuration/performance regressions pass. Full build and
content verification passed: `ml1910 · 09-25 00:19`, 166,360,404 bytes,
1,389 entries. SHA-256 `9ee0011365a1f1769837cc8c4587e32e2772f66b2410a77a919684435eb6b0a8`.
All 1,271 runtime resources match; stripped Dock, notices, source/login/Valve-DLL
exclusions, ZIP CRC and seals pass. Only app executable, Info.plist and seals
differ from ml1880. Reports: .xtool/logs/ml1910-build.log and
ml1910-verified.json; verifier: .xtool/verify-ml1910.py. Existing unrelated
compiler warnings remain. The IPA is ready at xtool/Madeira.ipa.
No private source edits, commit or push.

## ml1900 packaged for device testing (2026-09-25)

The owner explicitly resumed IPA building. The full app compiled, linked and
packaged successfully; the earlier build-stopped notes below are historical.
Current artifact: `xtool/Madeira.ipa`, label `ml1900 · 09-25 00:08`,
166,360,928 bytes / 1,389 entries. SHA-256:
`3c25ddff4b740aa32428078b1485a9bc2f8526f0728802739a0421b46bb53caf`.

The IPA includes native Dock onboarding and ml1890's hidden unreliable size
estimates. Native setup remains opt-in: set `env.MADEIRA_DOCK=1` and
`env.MADEIRA_DOCK_NATIVE_SETUP=1` in Documents/madeira.cfg, fully reopen the app,
then Settings > Run setup again. Existing Steam files are retained and skip
component preparation; download/provisioning needs a separate clean test
container, preserving the owner's working installation. Fresh-prefix device
authentication/game launch is still unverified. Prepare components before JIT.

Content verification passed: CRC, build/new-feature tags, 1,271 runtime resources,
stripped Dock, notices, source/login/Valve-DLL exclusions and resource seals.
Only the app executable, Info.plist and CodeResources differ from ml1880; no
entries added/removed. Dock's hash is unchanged. Existing compiler warnings
remain. Reports: .xtool/logs/ml1900-verified.json and ml1900-build.log;
verifier: .xtool/verify-ml1900.py. No commit/push or private source changes.

Dock is a separately built, proprietary executable hosted in the private
`125hz/madeira-dock` repository. Its source must never enter this public app's
working tree or Git history. The public integration consists of
`MadeiraDock.swift`, onboarding/session routing and the stripped `dockhost.exe`.
The bundled `dock-notices.txt` contains its binary redistribution license and
runtime notices. No developer account or cached Steam login is bundled.

## Native onboarding prototype — ml1900

See [DOCK_ONBOARDING_PLAN.md](DOCK_ONBOARDING_PLAN.md). Native preparation is
implemented behind MADEIRA_DOCK_NATIVE_SETUP=1, requires the Dock route, and
has host/isolated type-check coverage. It still needs a full app build and
clean-prefix device validation. The owner stopped packaging; the current IPA
remains ml1880. No private host code changed.

## Device follow-up (ml1890)

The owner reports ml1880 runs well. No new measured RAM/FPS comparison is
available yet. ml1890 only hides unreliable pre-download library estimates;
it retains the Dock pool/diagnostic policies and unchanged private host.

## ml1880 — first authenticated device launches; performance trial

Device logs 62/63 (ml1870) report session-authenticated-online=1 and
session-requested-app-listed=1; the owner confirms the installed 32-bit game
runs on iOS through Dock. This proves the tested native-token/Valve-client
path, not broad compatibility, clean-prefix provisioning or all online APIs.
Source remains private; the stripped host and real authentication/DRM are
unchanged this round. No developer login is included.

Evidence: late whole-app footprint is about 2,713 / 2,832 MiB, versus the
owner's earlier roughly 4.5 GB observation (not a controlled matched scene).
The 896 MiB JIT allocation is still selected as a desktop session, although
head + reserved tail reaches only about 230 MiB. Pool blessing dirties the
whole allocation. Metal allocated size is roughly 450–470 MiB; the larger
resource census is logical capacity, not another resident-memory total.
Frame reports vary by scene: later log 63 windows show about 47–58 fps,
4–8 ms GPU time and substantial unattributed CPU-side waiting. Do not call
all of that waiting CPU computation or promise an FPS increase from it.

Changes in public Swift only:
- With Dock enabled and onboarding complete, the early pool defaults to
  512 MiB despite the old desktop/setup sticky high-water. This reduces the
  reservation by 384 MiB. Actual footprint/FPS improvement needs device A/B.
  Explicit pool=256..1152 wins; unfinished setup retains its larger pool.
  env.MADEIRA_DOCK_COMPACT_POOL=0 restores previous sizing after restart.
- A desktop launch after a compact allocation stops before Wine starts,
  requests a restart and reserves at least 896 MiB on the next run. That
  reservation is cleared only after a large allocation succeeds. The pool
  cannot be enlarged or safely discarded after debugger detach. Existing
  one-session-per-app-run behavior remains. Explicit small pool overrides
  retain their deliberate user-selected behavior.
- Normal Dock gameplay defaults the guest D3D9 census to off: log 63 counted
  over 32,000 API calls/frame, plus histogram work. Frame/memory telemetry
  remains. env.MADEIRA_DOCK_LIGHT_DIAGNOSTICS=0 restores the old default;
  env.MADEIRA_D3D9_CENSUS=1 explicitly enables it. MADEIRA_DIAG or
  MADEIRA_D3D9_LAST opt-ins also prevent the new default. This targets the
  emulated PE frontend loaded in these logs; the native frontend's static
  initializers run earlier and are not reconfigured by this launch policy.
  This reduces diagnostic work, with no measured FPS claim yet.

Host checks compile the production policy and cover setup, manual overrides,
rollback, desktop recovery and diagnostic precedence; config/onboarding
regressions pass. Tags: [dock-pool] ml1880 and [dock-perf] ml1880.
Install the new IPA, fully quit/reopen Madeira, enable JIT and repeat the same
scene/settings for several minutes. Check the actual pool is 512 MB, then
compare footprint and [frame] windows. For independent A/B: pool=896 keeps
old memory sizing; env.MADEIRA_D3D9_CENSUS=1 keeps old per-call counting.
Restart between changes. If [jit-pool] EXHAUSTED or tail allocation failure
occurs, restore pool=896 and send the log. Larger/other games are untested.
No private host code changes, commit or push in this round.


ml1880 verified artifact: `ml1880 · 09-24 22:11`, `xtool/Madeira.ipa`,
166,312,103 bytes / 1,389 entries. SHA-256:
`5096bec2dcef89ea62c258736acd0c86514e96a95f07fce901a1335915b1d264`.
All 1,271 Windows resources match the staging tree. CRC, build/policy tags,
stripped host, license notices, source/login/Valve-DLL exclusions and resource
seals pass. Only Madeira, Info.plist and CodeResources changed from ml1870;
no entries were added or removed. Dock EXE remains byte-identical:
`26bc7b1ace2846191f67d7673219e7bae132be5b0ec0db84d5e9795c65b45044`.
Public config/onboarding/library/runtime/report and performance policy tests
pass; the production desktop-reservation methods are also exercised with
isolated preferences. Existing unrelated compiler warnings remain. No
commit/push. RAM/FPS improvement from ml1880 requires owner device testing.

## Previous trial: ml1870

Log 61 confirms the January adapter passes its method checks on-device and
normal-exit reporting works. Dock next rejects the one-use credential transfer
with code 37, before handing the token to Steam. This is not an ownership denial.

The app assumed a Z: drive for the protected Application Support file, while
Madeira's seeded Wine prefix guarantees only C:. ml1870 uses Wine's explicit
Unix namespace to reach that same file. Protection, permissions, one-use
deletion and original Valve authentication remain unchanged. Roll back with
MADEIRA_DOCK_UNIX_HANDOFF=0. No token or native file path is logged.

The stripped Dock executable also reports numeric transfer operation/errors
(MADEIRA_DOCK_HANDOFF_DIAGNOSTICS=0 disables those). They are included in the
normal exported Madeira log. Source remains in the private Dock repository.
Install ml1870 over the current app, keep MADEIRA_DOCK=1, and retry. No Steam
reinstall or sign-out is indicated. Path/transport tests pass; device token
authentication and gameplay still need a device test.

## Previous trial: ml1860

Log 60 loaded the genuine client successfully, then stopped before login:
the installed January client did not match Dock's previously supported PC
build. The new private host adds an independently checked adapter for that
exact DLL. Unknown builds still fail closed; authentication, entitlement and
game DRM are unchanged. MADEIRA_DOCK_CLIENT_202601=0 rolls back this adapter.
Only the stripped executable is staged in Madeira; source stays private.

Normal Wine exits now notify the app through the common exit wrapper.
The startup screen also observes completed reports independently of the
remaining desktop process. Approved numeric diagnostics and client fingerprint
appear as [dock-report] ml1860 in exported Madeira logs; unknown text is ignored.
MADEIRA_DOCK_STATUS=0 disables this observation. The owner confirmed the live
log button appears in ml1850; that layout remains in this build.

Install ml1860 over the existing app, retain env.MADEIRA_DOCK=1 and retry.
No Steam reinstall should be needed for the exact reported DLL. Windows
no-login ABI checks passed with the official matching DLL; this is not proof
of token authentication or game launch on iOS. Export the normal Madeira log
after a failure. No-desktop installation/provisioning remains planned work.

## Login and ownership

The user signs in through Madeira's native Steam UI. Steam issues the user's
refresh token, which Madeira stores in this device's Keychain. Before a Dock
launch, Madeira pauses downloads and disconnects its native Steam connection.
It writes a bounded, single-use transfer in protected Application Support
storage, excluded from backups. Only a file path enters the guest environment.

Dock consumes the transfer before authenticating with Valve's original client.
The client's online authentication and license checks gate the launch. The
library displayed in Madeira and locally parsed account identifiers are not
authorization. The original game executable, Steam APIs and DRM stay intact.
Valve's client can maintain its own cache in the user's Wine prefix; that is
runtime user data, never part of the distributed app or private source repo.



## ml1850 — log 59: unloaded DLL mapping reused (2026-09-24)

The ml1840 device run selected Dock correctly: [launch-route] selected=dock,
argv[3]=C:\windows\system32\dockhost.exe, and a real x64 host child. It crashed
with 0xc0000005 during LoadLibraryExW of the genuine client, before live-token
authentication. The surviving explorer desktop made the UI wait indefinitely.
This is NOT evidence of a rejected Steam login or an ownership failure.

Exact evidence: bcrypt.dll at PE 0x70fb8a0000 (size 0x90000) received pool copy
0x11d134000. After crypto-provider teardown, coml2.dll reused the same base and
size but received no fresh pool-copy log. The fault PC 0x11d14bba0 equals the
old bcrypt pool +0x17ba0, whose actual instruction is `str w8,[x22]` inside
generic_alg_property. x22 was 1. The log's coml2+0x17ba0 attribution reads the
NEW PE header; coml2's real text ends at RVA 0x13216. The recorded instruction
bytes match bundled bcrypt exactly. Dock's return RVA 0x1e1f is its client
LoadLibraryExW call. Do not patch coml2, bypass SHA-256, or disable client DRM.

Fix: delete_view retires overlapping PE-to-pool translations for SEC_IMAGE
before releasing the address. This covers all owners of that unmapped VA and
preserves adjacent mappings. It leaves executable allocation reclamation to
the existing process ledger; it does not immediately recycle executable bytes.
The old mprotect containment test checked only MZ and SizeOfImage, so equal-size
address reuse wrongly counted as the old live image. A fresh mapping now gets
a fresh code copy and the existing FEX alias registration replaces its overlap.
MADEIRA_JIT_IMAGE_RETIRE=0 rolls back; [jit-image-retire] ml1850 is capped at 32.

A weak native self-exit callback now publishes only Dock's numeric exit status
through an atomic session record. Swift polls it independently of explorer,
reads only whitelisted numeric guest report events, and displays a failure plus
Close session instead of spinning forever. Zero status is distinct from no
exit event. First event wins, and the record resets at session begin.
MADEIRA_DOCK_STATUS=0 disables this observation; [dock-status] ml1850 logs it.
The guest report is still not an ownership assertion; original checks remain.

Live-log control: the previous top placement was outside the known visible
Show desktop controls, under the general session tools gate and near the
session-message overlay. Log 59 does not prove which UI condition hid it.
The button is now directly above Show desktop, bordered, immediately available,
and independent of MADEIRA_SESSION_TOOLS. MADEIRA_STARTUP_LOG_ALWAYS=0 retains
the delayed legacy control; [launch-log] ml1850 logs via LogStore, not an early
stderr write. The ml1840 full-height/200-row log implementation remains.

Validation: new source-extracted ASan/UBSan host checks cover equal-base/equal-size
image reuse, both ownership records, adjacency, partial overlap, rollback,
zero-length ranges, first/zero/error exit status, concurrent publishers and
session reset. Existing config, library/contract, and session lifetime tests
pass. Native rebuild: ntdll 36/36, win32u 46/46, wineserver successful. No actual
Wine/game runs on this PC. Device authentication, game launch, and visual
button/layout confirmation remain pending. No private Dock implementation or
binary changes; no source or account data added to the app. No public push.

## ml1840 — Dock routing and startup diagnostics (2026-09-24)

Device log 58 from ml1830 did NOT exercise Dock. At 19:59:28 the app prepared
its one-use handoff, then deleted madeira-env.txt because madeira.cfg existed.
The canonical file contained only the webhelper-freeze setting. LibraryFlags
read legacy env/getenv only, and the worker recomputed the route after deletion,
overwriting Dock's command with desktop steam.exe. The log contains the actual
steam.exe argv/child startup. This is a Swift integration bug, not evidence of
failed Dock authentication or Wine incompatibility.

ml1840 reads canonical env.* for both UI decisions and runtime export, merges
new legacy environment overrides atomically before cleanup, and verifies each
legacy file's values before deleting it. Conflicting/unreadable files remain.
The launch decision is passed explicitly through configuration and worker
startup; it cannot silently change when a file disappears. The session stores
that route for status text and final Dock diagnostics. [launch-route] ml1840
selected=dock is the app-side marker; dockhost.exe argv and guest host stages
are still required to establish that Dock actually ran.

The log toggle is pinned above the starting-screen scroll view from the start.
The log pane uses its full landscape height and up to 200 recent coalesced rows
instead of seven bottom-anchored rows. Short histories align to the top. The
profile's initial live-log choice can now be toggled off during startup too.
Dock gets its own honest starting/waiting label and Show desktop button.

Rollback/configuration: MADEIRA_DOCK=0 chooses desktop Steam before launch;
MADEIRA_FLAGS_CONFIG=0 restores legacy-only UI flag lookup;
MADEIRA_CONFIG_ENV_MERGE=0 retains unimported legacy environment overrides;
MADEIRA_STARTUP_LOG_ALWAYS=0 restores the delayed log button;
MADEIRA_STARTUP_LOG_FILL=0 restores seven rows. Use env.NAME = value lines in
Documents/madeira.cfg. Legacy madeira-env.txt remains accepted and imported.
A device affected by ml1830 must re-add env.MADEIRA_DOCK = 1: the deleted flag
cannot be recovered automatically. Dock remains opt-in; no account data or
private host source is introduced. Private host EXE is unchanged.

Validation: production configuration/LibraryFlags filesystem regression,
explicit route snapshot tests, Steam library/contract, onboarding, and launch
view suites pass (launch scene/census uses ASan/UBSan and TSan). Visual layout,
live native-token authentication, entitlement rejection, and Wine/FEX launch
still require device testing. Do not describe log 58 as a Dock failure or success.

## Current scope

Native Windows tests established startup for three installed games using the
PC client's existing login. The new refresh-token handoff has passed parser,
file-consumption and malformed-input tests with synthetic credentials. Live
refresh-token authentication and Wine/FEX/iOS launches still need device tests.

This first device trial requires Steam's official files to have been installed
inside Madeira. It has a strict client-version gate and supports Steam's
default launch option with no custom arguments. Onboarding puts native sign-in
first when Dock is enabled; the installer still opens a Wine desktop, but
users are told to finish once the updated Steam sign-in window appears.
They do not need to sign in there for the intended Dock path.

Removing the installer entirely is subsequent work: downloading a verified
official runtime and validating a clean Wine prefix. Existing Windows tests
do not establish that capability.

## Test on a device

The bundled Wine source is 11.4, and the shipped prefix template identifies
Windows 10 Pro build 19045. This is Wine's reported compatibility version;
Wine does not run a Windows 7 kernel. Existing user prefix overrides can differ.
Dock's PE imports ordinary Windows/UCRT APIs, whose actual Wine implementation
must still be exercised on-device. The genuine Valve client is a separate
dependency; real Windows 7 support is not promised. Valve ended its Windows
7/8/8.1 support on 2024-01-01 ([Valve support](https://help.steampowered.com/en/faqs/view/4784-4F2B-1321-800A)).

1. Install the ml1850 IPA over the existing app, preserving its data.
2. Keep the current Steam installation and games inside the app.
3. Add `env.MADEIRA_DOCK = 1` to Madeira's Documents/madeira.cfg. The ml1830
   cleanup bug deleted the legacy trial flag, so restore it once. Preserve
   other settings. A new madeira-env.txt with `MADEIRA_DOCK=1` is also imported.
4. Relaunch Madeira, sign in through its native Steam UI if needed, and enable JIT.
5. Choose an installed Steam game's Steam/client launch mode, with no custom
   arguments, then tap Play. The app starts Dock inside Wine's desktop.
6. If a menu appears, exercise it and end the session normally. Export the
   Madeira diagnostic log after success or failure. The guest report is also
   at Documents/wine/drive_c/madeira-dock.txt; it contains numeric host stages.

`MADEIRA_DOCK=0` restores the desktop Steam route. An unsuccessful Dock login
does not automatically fall back to a direct game launch. The app removes any
unconsumed handoff after a failed preparation, session end, sign-out or next
app start. The first trial remains off by default pending device results.

## Source separation

The app's Git hooks reject private host paths and private source markers,
including source present in earlier commits of a push. They are a guard
against mistakes, not a substitute for reviewing staged files. Only a verified
private destination may receive Dock source. Repository privacy restricts
source access; executable distribution does not prevent reverse engineering.

## Previous verified build (ml1830; superseded)

The local IPA `xtool/Madeira.ipa` was built as `ml1830 · 09-24 19:39` and
content-verified: 1,389 ZIP entries, 166,284,871 bytes, SHA-256
`bd426d2b3172bf0160050338879d3b8712671af37fbd399509fd4ca49bf59b28`.
Dock is a 30,208-byte stripped x64 PE, SHA-256
`ddefca17379dda5e274f065913a7215a7f49a504ccb37a657a5257cc8d48804b`.
All 1,271 files in the three Windows resource directories match their IPA
copies. Both new resources are sealed; no Dock source/debug files or cached
Steam login files are bundled. Building succeeds with existing unrelated Swift
warnings. These artifact checks are not a successful device launch.

Verified ml1840 artifact: `ml1840 · 09-24 20:11`, 1,389 ZIP entries,
166,299,430 bytes, SHA-256 `c07ad624c0924b89a427081e757a553f90a15744721f819501b3ac7216f521cc`.
All 1,271 Windows resources match their source copies and remain unchanged from
ml1830. Only the app executable, Info.plist and signature seal changed. Dock
remains the same stripped 30,208-byte PE; CRC, resource seals, integration
markers and source/cached-login exclusions pass. IPA: `xtool/Madeira.ipa`.
No public commit/push this round. Device authentication/gameplay and visual
layout confirmation remain pending.

Verified ml1850 IPA: `ml1850 · 09-24 21:00`, 1,389 entries,
166,303,597 bytes, SHA-256 `bdc7e6a944f1a1dd24f276bfc9350cb2040187d6bae3c6d1bd5167cb145aac87`.
CRC, new native/UI diagnostic strings, all 1,271 Windows resources, resource
seals, and private-source/cached-login exclusions pass. Compared with ml1840,
only Madeira, Info.plist and CodeResources changed. Dock remains 30,208 bytes
with SHA-256 `ddefca17379dda5e274f065913a7215a7f49a504ccb37a657a5257cc8d48804b`. Linked host-exit callback and
status reader verified with llvm-nm. Existing unrelated compiler warnings remain.
Install over the current app and retain env.MADEIRA_DOCK = 1; no config change
needed. Device retest required; no authentication/game-launch success claimed.

ml1860 artifact verified: `ml1860 · 09-24 21:30`, `xtool/Madeira.ipa`,
166,306,898 bytes / 1,389 entries. IPA SHA-256:
`78a10b3ce35fc5da9aee957f8e3ce0f5c6ce493fc3b8811daa7c3b73176373ca`.
Dock remains stripped x64, 30,208 bytes, new SHA-256:
`61976bb68737c9e39f1acd387b22c7aece406f34784352bb0307bf21a1b0f3fa`.
Only the app executable, Dock EXE, Info.plist and CodeResources changed versus
ml1850; no removed entries. All 1,271 Windows resource files match the source
bundle; CRC, notices, signatures' resource seals and source/login/Valve-DLL
exclusion checks pass. Common exit wrapper and both bridge symbols are linked.
Existing unrelated compiler warnings remain. No commit/push performed.

ml1870 verified artifact: `ml1870 · 09-24 21:46`, `xtool/Madeira.ipa`,
166,307,354 bytes / 1,389 entries. SHA-256:
`defe7ed39691534563d027ae813054eb709e5a30169ad6aef22680aa1df3a124`.
Stripped x64 Dock is 30,720 bytes, SHA-256:
`26bc7b1ace2846191f67d7673219e7bae132be5b0ec0db84d5e9795c65b45044`.
CRC, all 1,271 Windows resources, new app/host diagnostic strings, resource
seals and source/login/Valve-DLL exclusions pass. Only Madeira, Dock EXE,
Info.plist and CodeResources changed from ml1860; no entries removed.
Dock imports resolve against bundled Wine exports. Existing unrelated compiler
warnings remain. No commit/push performed. Device verification is outstanding.
