# Process host: phase 2 (ml1331)

Implemented 2026-10-13 on `vulkan-stack`. **Not device-tested.** Wine clients can
join the app's existing wineserver from owned `MadeiraProcessHost` extensions.
The feature and shared storage both default off. The final local IPA is built
after merging into `vulkan-donor-local`; that branch must never be pushed.

## Design

The app's normal in-session launcher (`MadeiraSession`, ml1350) queues the first
remote start with request flag 2. The flag belongs to that launch and its Wine
thread, and is consumed once by `spawn_process`. The normal `NtCreateUserProcess`
gate, startup information, environment, working directory and desktop still
apply. Its child socket is duplicated and sent by XPC to the extension. No
parentless wineserver connection is injected.

The app starts the extension, enables JIT for its pid, and prepares a private
image/JIT pool (512 MiB by default; `env.MADEIRA_EXT_PROCESS_POOL_MB = 128..1152`).
The extension runs `__wine_main` with `WINESERVERSOCKET` pointing at that child
socket. It uses the existing exec-child startup path, rather than cloning the
parent's PEB with `wine_ios_child_main`. A seeded prefix and an existing desktop
need no second explorer. Initialisation inside Wine's standard child path is
retained.

Wine's startup environment is supplied by the parent/server. `env_ios.c` replaces
the child's Windows `WINE_IOS_JIT_RX/RW/SIZE` with the extension's own POSIX
values before its PE FEX module reads them. In-session launches of the full
client and its web helper strip `SteamAppId`, `SteamGameId` and `SteamAppPath`
from a copy of the Windows environment. The parent's environment is preserved.
`env.MADEIRA_SESSION_CLEAN_STEAM_ENV = 0` restores the old inheritance.

### Host-routed control

A separate socketpair carries versioned 64-byte headers and bounded payloads.
`ProcessHostControl.h` defines its private ABI. An extension-owned service thread
calls `ios_process_host_control` in its linked native library, operating only
on its own task and local thread port names. **No task port travels over XPC.**
The device already demonstrated that sending its task port broke the connection;
the phase-1 task-port registry and transfer have been removed.

The app registers only extension pids it started. `wine_host_process_control`
serializes requests, splits memory operations into at most 64 KiB pieces, checks
reply framing, limits diagnostic lines, and poisons the socket after a partial
message, timeout or disconnect. The RPC loop allocates its buffer before any
Wine thread is suspended.

Native code uses direct weak references to the app/extension hooks. This keeps
the hooks linked under executable dead-strip; a `dlsym`-only reference allowed
the linker to remove them. Final binary inspection checks their presence.

Remote reads/writes, signals and Mach suspend/resume now route through this
service. Context capture reuses the existing in-task ARM64/WoW64 implementation.
A first logical suspend retains an outer Mach hold across capture; nested
suspends do not add holds, and the final resume releases one hold. Native
ARM64 control/integer context writes are applied to the captured syscall frame
when applicable, with frame identity rechecked and x18 preserved; otherwise
they use `thread_set_state`. Existing guarded i386 frame writes are reused.
`patches/0052-process-host-context.patch` extends Wine's snapshot/dirty-context
bookkeeping to remote clients without changing the pinned submodule.

**Limit:** direct AMD64 context writes and native floating-point/debug/other
register writes are explicitly rejected with `STATUS_NOT_SUPPORTED`. Captured
guest AMD64 registers have the same last-saved CPU-area limitations as the
existing in-task path. Full register-group support remains future work.

### Storage and synchronisation

`env.MADEIRA_SHARED_DRIVE = 1` detects every app group in the app's signed
entitlements and also tries `group.com.SideStore.SideStore`. The extension must
resolve the selected group itself before using the prefix. A missing group or
missing extension entitlement stops preparation with a diagnostic.

`D:` maps to `<container>/madeira-shared`. The full-client installer prefers
`D:\Steam` when this mapping is available; its discovery registry writer uses that same
path (existing conflicting keys are preserved and logged). Dock's pinned component preparer keeps its own C: path. The taskbar and
remote test can launch the D: client inside a running session. General library
entries remain C:-relative; use the remote test or the in-session taskbar for D:.

With **both** extension clients and shared storage enabled, the app makes a
persistent copy of its private prefix at `<container>/madeira-shared/prefix`
before starting the server. The original prefix is preserved. Copying is staged,
excludes the old `.wineserver` socket directory, and is refused during a running
session. C: becomes a relative link into the copied `drive_c`; D: is rebuilt.
The app server, its primary client, library file lookups and extension clients
use that same prefix. Later launches reuse it; the two prefixes are not kept in
sync. Disabling either flag returns to the private prefix, so changes made in
the shared prefix are absent from that private copy. File handles are still
served by Wine, but some Wine operations also open files locally: a separate
minimal prefix served only through the server would not provide consistent
paths. Bundle links remain valid because app and extension see the same bundle.
Other links to private app-container paths can remain inaccessible remotely.

**Privacy decision:** the shared prefix may contain existing client login caches
and other personal files. Every app entitled to the selected group can read it;
SideStore is one such app for its own group. Setting the shared-drive flag is an
explicit opt-in to that storage. No developer login, token or account data is
bundled or committed. A large existing prefix requires space for its copy.

`inproc-sync = 1` is refused for every remote start: madsync objects belong to
app memory. Each remote client forces **client-side fastsync off** in both its
POSIX and Windows environments. Its separate image has a separate cell table.
The app server may retain fastsync: clients using ordinary server requests see
the server's event state correctly. A cfg snapshot reaches the extension's own
Documents directory; it never tries to open the app's `madeira.cfg` directly.

### Descendants, windows and failures

A `CreateProcess` from an extension follows the same process gate and forwards
its own exec-child socket/argv/cwd to the app's launcher over XPC. The app creates
another session and JIT pool. Remote helpers skip the in-task CEF single-process
rewrite and its `--type=` refusal. Existing Dock process-gate rules remain.

The extension rejects a second request in the same host process; the app also
rejects a reused pid in its registry. Whether this extension point gives each
concurrent request a distinct pid needs device verification. A reused process
is an honest failure, never a second Wine instance corrupting the first one.

Display hooks have real signatures: CreateWindow succeeds, ShowWindow returns
the `~0u` no-override sentinel, and GDI surface presentation acknowledges success.
Window geometry/destruction go to the app over XPC, are coalesced, and are
consumed on the existing Wine event-pump thread (metadata queries require a TEB).
The compositor/windowed-mode code then gets the HWND and geometry. Input uses
the shared wineserver window station. **Frames remain black:** no GDI pixels,
Metal layers or IOSurfaces are transferred. GL/Vulkan presentation and controller
snapshots in the headless extension are still unsupported. Phase 3 must add
IOSurface frame transport; visible content/input behavior needs device tests.

Startup has a 55-second app deadline within the native hook's 60-second bound.
Failure/timeout/interruption shuts down the exec-child socket (including its
duplicates), closes control endpoints and cancels the owned request, so the
parent's process-info wait gets EOF/failure. Fatal extension loader errors notify
the app and connection invalidation aborts its socket. Normal initial-process
exit reaches the existing `wine_launched_process_did_exit` hook and the app logs
`[ext-proc] ml1330 exit code N`.

## Device tests

Install the final IPA over Madeira, retaining its extensions. Use a desktop
session that pumps messages; fully quit/reopen after changing cfg.

```ini
env.MADEIRA_EXT_PROCESS = 1
env.MADEIRA_SHARED_DRIVE = 1
env.MADEIRA_EXT_PROCESS_TEST = 1
inproc-sync = 0
```

Expected stages: `ml1331 shared container: <path>`, `shared prefix ready`,
`test: launcher exec-child requested (1)`, `spawn exec-child fd=...`,
`ml1330 extension started pid=...`, `enabling JIT for the extension pid=...`,
`ext: JIT pool: RX=... RW=...`, `ml1331 control socket registered`,
`process started: ok=1 stage=5`, and finally **`ml1330 exit code 0`**.
The extension's own Documents/madeira-ext-log.txt contains Wine/echo diagnostics.
An early guest exit can interleave with the start/launcher result lines.

For the full-client trial, install the x64 client from the taskbar, then replace
only the test value:

```ini
env.MADEIRA_EXT_PROCESS_TEST = steam
```

It starts the installed client with `-nobootstrapperupdate -skipinitialbootstrap
-norepairfiles -noverifyfiles -no-cef-sandbox`. Watch for a second distinct iOS pid
when the client starts its web helper. Remote window geometry should reach the
windowed-mode list; content is intentionally black in this phase. A successful
build is not evidence that the client authenticated or its helper booted.

Failure shapes: no shared group / extension cannot resolve it; inproc-sync
refused; JIT helper/pool unavailable; preparation stage failure; reused extension
pid; startup timeout; `remote <operation> pid=... tid=... -> error`; loader fatal; nonzero exit.
Rollback: `env.MADEIRA_EXT_PROCESS = 0`, then restart. Set shared-drive to 0 too
to stop preferring D: for future full-client installs. Shared files are retained.

## Verification

Unix libraries are rebuilt with `rebuild-native.sh wineserver ntdll win32u`.
Objective-C sources pass iOS SDK syntax checks; the app Swift sources compile in
the full xtool build, and the standalone process-host target links and embeds.
`tests/host/check-process-host.py` executes production socket framing and launcher
environment edits, checking fragmentation, truncation, disconnects, timeouts,
case-insensitive removal, rollback and preservation of the parent environment.
`check-process-host-environment.py` executes the production dynamic environment
replacement and verifies that missing local aliases never retain parent values.
Config-catalog, Dock components/contract, Steam library, onboarding, gamepad and
swap-coverage host checks accompany it. Exact final IPA/hash and build outcomes
are recorded in the local dated `HANDOFF.md` entry. No device run was made.

Apple API references: [App Group container access](https://developer.apple.com/documentation/foundation/filemanager/1412643-containerurl),
[thread_get_state](https://developer.apple.com/documentation/kernel/1418576-thread_get_state).
