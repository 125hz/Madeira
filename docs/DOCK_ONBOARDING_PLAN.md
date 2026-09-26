# Native Dock onboarding — ml1900

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

The owner requested stopping the ml1890 IPA build and starting this work.
That build was terminated after compilation, before packaging. The current
IPA remains the verified ml1880 artifact. The ml1890 size-display change is
retained in source. Do not describe this onboarding trial as shipped or proven.

## Intended experience

1. Welcome and native Steam sign-in (including Steam Guard/QR as today).
2. **Prepare Madeira Dock**: download official Steam components from Valve,
   verify them, and prepare the Windows environment within Madeira.
3. Open the library and download games using the existing native downloader.
4. Enable JIT when starting a game. Dock uses the one-use native sign-in
   handoff and genuine Valve client to authenticate, check subscriptions,
   and launch with the game's original Steam APIs/DRM.

No Wine desktop, interactive Steam installer, or second desktop login should
be necessary for this route. This still installs actual Valve runtime files
on the device: steamclient64.dll alone is not sufficient. It does not embed
Valve binaries, developer credentials or private Dock source in the IPA.

## Implemented prototype

`app/Madeira/SteamRuntime.swift` is the public component preparer; it contains
no private host implementation. `Onboarding.swift` adds progress, cancellation,
retry and an explicit desktop-setup fallback. Xcode's source list includes the
new file. Enable **both** `env.MADEIRA_DOCK=1` and
`env.MADEIRA_DOCK_NATIVE_SETUP=1` in madeira.cfg for this trial. Native setup
defaults off until clean-prefix device validation; `=0` restores old setup.
The existing signed-in/library/Dock routing and default flags are unchanged.

The initial pinned package set is from Valve's HTTPS update manifest:
[steam_client_win32](https://client-update.akamai.steamstatic.com/steam_client_win32).
The manifest fetched on 2026-09-24 reports version 1769731672. The three ZIP
packages are bins_win32, bins_win64_win32 and steam_win32, totaling 72,361,220
bytes. They include both client architectures, support libraries, launch helpers
and the genuine bootstrap executable used by the existing client discovery.
They exclude the full web UI/CEF package set. This is a conservative component
set for the trial, not a proven minimal dependency list for every game.

The package URLs, exact sizes and SHA-256 hashes are pinned in public source.
The x64 client's digest must additionally match Dock's supported January DLL.
Do not automatically follow the latest manifest: a changed private client ABI
requires a verified adapter in the PRIVATE Dock repo first. No hashes or
method validation in Dock are relaxed for provisioning.

The preparer uses an ephemeral URLSession without shared credentials/cookies,
allows only HTTPS redirects to the same official host, downloads to temporary
files, verifies complete archive hashes, then stages decoded files. Extraction
checks local/central headers, CRC, bounded sizes, encryption, path traversal,
symlinks and duplicate names. Valve uses Windows separators in these ZIPs;
normalize them before path and collision checks.

Preparation reuses Madeira's prefix-template seeder without starting Wine or
JIT. An unstamped prefix that already has registry hives is rejected rather
than allowing template extraction to overwrite them. It adds only fixed client-discovery registry keys/paths, including the
32-bit machine view and ActiveProcess DLL paths. No user/account/ownership
assertions are added. Existing unrelated registry content is retained; conflicting
paths are rejected, and original hives are backed up before atomic replacement.
The private host still publishes its actual PID/user discovery state only after
real authentication and entitlement checks.

Existing Steam installs are retained and can continue through setup. For a
missing client, preflight rejects conflicting existing runtime files, symlinks
and case collisions. Identical partial files can be reused on retry. Games,
steamapps and account configuration are not replaced. Publish steam.exe last,
so the ordinary library scanner does not see an installed client before its
runtime files and registry preparation are complete. Interrupted commits can
leave identical partial runtime files; retry completes them. This is not a
whole-directory atomic transaction. No Wine session may be active during it.

## Validation and remaining work

Completed:
- Production ZIP decoder matches all extracted bytes from the three genuine
  pinned archives against Python's independent ZIP reader.
- Host fixtures reject traversal, duplicate names, symlinks, bad CRC/sizes,
  unsupported flags, invalid offsets and truncation; stored, deflate, empty
  entries and Windows path separators work.
- Registry tests cover preservation, idempotence, conflicting paths and both
  views. Destination checks reject case collisions and symlink traversal.
- The bundled template has valid system/user hives and no preexisting Valve
  sections. The installer passes arm64 iOS 18 SDK type-checking with bridge
  interface stubs; the changed UI sources pass Swift parsing. Existing
  onboarding and library host regressions pass.

Still required before enabling it by default:
1. Compile/package the whole app when resuming IPA work. No new IPA was built
   after the owner's stop request; isolated type-checking is not app linking.
2. Test in a separate clean app container/prefix, preserving the owner's current
   working installation. Run native sign-in, preparation, a native game download
   and Dock authentication/launch. Observe client loading, authenticated-online,
   requested-app-listed, install-directory match and the actual game window.
3. Check required libraries/configuration discovered through dynamic loading,
   including both game architectures. Package extraction success alone does not
   prove a fresh client can authenticate or launch. Add only verified official
   packages if genuine dependencies are missing.
4. Test cancellation/network failure/retry and existing-prefix migration on
   device. Keep the legacy installer fallback. Opening full desktop Steam after
   component-only setup may fetch more packages or update to an unsupported
   client; this trial does not yet provide a separate managed desktop runtime.
5. After clean-prefix success, decide default onboarding/Dock flags and JIT pool
   selection for users who enabled JIT before finishing setup. Prefer preparing
   files before JIT; no Wine session or setup restart is required by the new
   preparer itself.

Log tag: `[dock-setup] ml1900`. No private host changes, Wine-on-PC tests,
installed PC client changes, commits or pushes were made for this prototype.
