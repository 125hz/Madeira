# Process host: phases 2 and 3 (ml1331, ml1332)

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

### Prerequisites: app group and sync engine

Device log 98 (first phase-2 trial) stopped at both of these: every stage logged
`shared container: none` (about 30 times) and `test refused: inproc-sync=1 uses
app memory`.

**App group.** `app/Madeira/Madeira.entitlements` and
`app/MadeiraProcessHost/ProcessHost.entitlements` declare the same group,
`com.apple.security.application-groups = [group.com.willfaust.madeora]`
(`group.` + the default bundle id). Before this the app declared no group, so a
sideloader had nothing to register and no container existed. How each binary
carries it into the IPA:

- the app: xtool signs the app binary ad hoc with `entitlementsPath`
  (`xtool.yml`, written by `prepare-upstream.py`: `app/Madeira/Madeira.entitlements`);
- the extension: `embed-process-host.py` builds it outside xtool and used to leave it
  unsigned, and a sideloader reads each binary's entitlements from its code signature
  (ldid's `Entitlements`) to choose that App ID's capabilities and groups. It now signs
  the extension ad hoc with `ProcessHost.entitlements` (`.xtool/upstream-build/adhoc_sign.py`,
  the layout `ldid -S` writes; SHA-256 CodeDirectory, entitlements in slot 5) and
  asserts both files name the same groups. The memory host and the JIT helper are
  still embedded unsigned (no group needed, out of scope).

SideStore/AltStore register the group for the installing team and rewrite its id
(AltStore appends `.<TEAMID>`; the bundle id is rewritten the same way, as the
`com.willfaust.madeora.<TEAMID>.JITHelper` probe line shows), identically for the
app and its extensions, then re-sign with a profile that grants the rewritten id.
So nothing hard-codes the id at run time: `SharedContainer.swift` tries the groups
of the embedded provisioning profile (`embeddedProvisioningProfile()`, EntitlementChecker.swift),
then the signed binary's own groups, then `group.com.SideStore.SideStore` and
`group.com.rileytestut.AltStore`, and uses the first one iOS resolves. It runs once
per app run and logs once:

```
[ext-proc] ml1331 shared container: <container path> (group <id>)
[ext-proc] ml1331 shared container: none (profile groups: [...] signed groups: [...]). ...
```

`[device] signing:` also reports `profile-app-groups=<n>` (the count; ids only in the
line above). The ProcessHostClient.m lookup (signed groups, then SideStore's) is
only called once a container exists, so its `shared container: <path>/madeira-shared`
line appears once and `none` no longer repeats per launch. The extension opens the
group the app passes in `PH_INFO_GROUP`, which works only when its own profile
grants the same rewritten id.

Reading a device log: `profile-app-groups=0` and `none (profile groups: [])` mean
the sideloader registered no group (old IPA, or the sideloader ignores groups);
`profile groups: [<id>]` with `none` means the group was registered but iOS
refused the container (report it); a path means the app side is ready, and an
extension-side refusal (`extension cannot resolve the shared container`) then
means the extension's profile lacks the group (check that the IPA's appex carries
a signature: `adhoc_sign.py --show <appex binary>`).

**Sync engine.** Madsync keeps synchronisation objects in app memory, which an
extension task cannot reach. With `env.MADEIRA_EXT_PROCESS = 1` and madeira.cfg
selecting madsync (`inproc-sync = 1`), `ExtProcessSync.prepareSession`
(MadeiraExtProcess.swift, called by `startWineserver` before `wineserver_start`)
switches that session to fastsync without changing madeira.cfg: it sets
`MADEIRA_MADSYNC_SESSION=0` (madsync.c reads it when the server creates its first
object) and `MADEIRA_FASTSYNC` = cfg `env.MADEIRA_FASTSYNC`, else `auto`, unless
already set, then logs

```
[ext-proc] ml1331 sync: madsync (inproc-sync = 1) disabled for this session because remote processes cannot share app memory; fastsync used
```

Wine decides madsync once per app run: if an earlier session of the same run
already started it, the log says `madsync already active in this app run ...;
restart Madeira`. `env.MADEIRA_EXT_PROCESS_KEEP_MADSYNC = 1` keeps madsync and the
old refusal (`sync: madsync kept ...`). The refusals now follow the real state: the
app test refuses only when `ExtProcessSync` recorded active madsync, and
`process_ios.c` refuses a remote start only when this process was handed madsync's
device (`inproc_device_fd >= 0`), not merely because the cfg key is 1.

### Storage and synchronisation

`env.MADEIRA_SHARED_DRIVE = 1` uses the shared container above. The extension must
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

Madsync never runs with remote starts: madsync objects belong to app memory, so
a madsync session is switched to fastsync (Prerequisites above), and a remote
start is refused only while madsync is really active. Each remote client forces **client-side fastsync off** in both its
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
the shared wineserver window station. Phase 2 transferred no pixels; phase 3
(below) adds IOSurface frames. Controller snapshots in the headless extension
are still unsupported; visible content/input behavior needs device tests.

Startup has a 55-second app deadline within the native hook's 60-second bound.
Failure/timeout/interruption shuts down the exec-child socket (including its
duplicates), closes control endpoints and cancels the owned request, so the
parent's process-info wait gets EOF/failure. Fatal extension loader errors notify
the app and connection invalidation aborts its socket. Normal initial-process
exit reaches the existing `wine_launched_process_did_exit` hook and the app logs
`[ext-proc] ml1330 exit code N`.

## Phase 3: frames (ml1332)

Implemented 2026-10-13 on `vulkan-stack`. **Not device-tested.** Active only
with `env.MADEIRA_EXT_PROCESS = 1`; `env.MADEIRA_EXT_PROCESS_FRAMES = 0` keeps
phase 2's black windows (the app tells the extension in `prepareGuest`).

### Design

Every top-level window of an extension client that presents gets **two
IOSurfaces** (window pixel size, `BGRA`, alpha forced to 255), created by the
extension so their memory counts against the extension. They reach the app once
per creation or resize (`windowSurface:buffer0:buffer1:`, with the HWND, size,
kind and a generation number), as `IOSurface` objects through their public
`NSSecureCoding` over the existing NSXPC connection. The iOS SDK exports but does
not declare `IOSurfaceCreateXPCObject`/`IOSurfaceLookupFromXPCObject`, so the
documented object route is used; it carries the same XPC object. After each
frame the extension sends `windowFrame:reply:` (HWND, generation, buffer index,
dirty rect). **One frame per window is in flight:** the extension writes neither
buffer until the app's reply, which the app sends from the completion block of
the Core Animation transaction that set the layer's contents. The buffer the app
shows is therefore never written, and contents alternate between two distinct
surfaces, so every frame is a new contents value for Core Animation.

**GDI** (ProcessHostStubs.c `winios_surface_present` → ProcessHost.m): Wine's
window surface bits are valid only during its flush, so the dirty rect is first
copied into a private mirror of the surface (alpha forced opaque: a GDI DIB is
BGRX and its alpha byte is often 0). Each buffer keeps a stale rect (everything
dirtied since it was last written); a frame copies only that rect from the mirror
under `IOSurfaceLock`. A flush during a flight only updates the mirror and is
counted as coalesced; the reply sends the newest state, so the last frame never
waits for another Wine flush. Only a failed mirror allocation returns 0 to Wine
(its dirty bounds are kept). Memory: three surface-sized copies per window
(mirror plus two IOSurfaces, about 12 MB for a 1280x800 window).

**Metal** (DXMT/vkd3d swapchains, winevulkan surfaces): the extension cannot
present into the app's layer. It now exports its own `macdrv_functions` table
(DXMT finds it with `dlsym`) and `madeira_vulkan_layer_for_hwnd`; both return an
extension-owned `CAMetalLayer` subclass per HWND that is never in a layer tree
and forces `framebufferOnly = NO`. Drawables are presented normally.
`-[MTLCommandBuffer presentDrawable:]`, `presentDrawable:atTime:` and
`presentDrawable:afterMinimumDuration:` are replaced on the device's concrete
command-buffer classes (found once from sample command buffers; the original IMP
is always called). For a drawable of such a layer the hook encodes one blit of
the drawable's texture into the back buffer's IOSurface-backed `MTLTexture`
(`newTextureWithDescriptor:iosurface:plane:`) on the same command buffer, and the
command buffer's completion sends the frame. DXMT ends its presenter encoder before
`presentDrawable`, so no encoder is open at that point. This was preferred over a
DXMT texture-provider change: it needs no submodule change or DXMT rebuild and also
covers Vulkan drivers that present through the command buffer. Trade-off: one extra
full-frame GPU copy per present; presents during a flight are not copied (counted
as dropped). Only `BGRA8Unorm` and `BGRA8Unorm_sRGB` drawables are copied (a
one-time log names any other format).

**App** (ProcessHostClient.m → Winios.m `winios_remote_surface_frame`, main
thread): kind 0 sets the HWND's existing compositor layer (the layer created for
the remote HWND by phase 2's geometry forwarding) to the IOSurface, exactly like
a local GDI image (same contents-rect crop, game-mode rules and present counter).
Kind 1 uses a sublayer placed over the client rect where a local window's
CAMetalLayer sits (`winios_place_metal_layer`). Windowed mode places that layer
in its frame as for a local window.

**Cursor and focus.** Cursor images and visibility from the remote process
(driver_ios.c `winios_drv_set_cursor` there) are forwarded (`windowCursor:`,
visibility only when it changes) to the app's drawn cursor. A tap inside a remote
window reaches its thread as hardware input through the shared server, and that
thread activates the window itself. A windowed-mode activation request (frame
chrome or taskbar) used the owner-thread rule, which never runs for a remote
window: the app's pump now calls `winios_drv_foreground_remote` for HWNDs an
extension reported, which asks the server to make the window foreground; win32u
sends `WM_WINE_SETACTIVEWINDOW` to the owning thread through the server. Nothing
is asked of the extension. Logged once: `[windowed] ml1300 ml1332 activate remote
hwnd=... foreground=1 (server-routed; no extension call)`.

**Lifetime.** The extension frees a window's IOSurfaces, textures and mirror in
`pDestroyWindow` before it forwards the destroy, and all of them at process exit.
The app drops its references on the destroy message; when an extension session
ends (exit, invalidation, crash) the app drops the buffers of every window that
session reported and queues a destroy for each, so the Wine-thread pump removes
their layers and windowed frames. Stats lines count both sides:
extension `ml1332 stats windows=N surfaces live=N created=N released=N frames=N
coalesced=N dropped=N lost=N`; app `[ext-proc] ml1332 stats remote windows=N
surfaces live=N received=N dropped=N frames=N (window destroyed | session pid=N
ended)`. `live` must return to 0 after a session.

### Logs (capped)

App: `[ext-proc] ml1332 surface hwnd=0x… WxH iosurface id=A,B (buffers 0,1)
kind=gdi gen=N`, `[ext-proc] ml1332 frame hwnd=0x… buffer N dirty x,y WxH (#n)`
(first 96 frames, then every 256th, 400 lines at most), `[ext-proc] ml1332 remote
swapchain layer for hwnd=…`. Extension (relayed as `ext:`): `ml1332 metal layer for
hwnd=…`, `ml1332 metal present copy hooked on <classes> (N methods)`, IOSurface
allocation failures, the unsupported-format line and the exit stats.

### Limits

- Not device-tested. Assumed but unverified on device: IOSurface `NSSecureCoding`
  across this NSXPC connection, `CALayer.contents` accepting an IOSurface on iOS,
  its row order (top row first, as for the CGImage path), and that a layer never
  added to a tree still vends drawables and completes presents in an extension.
- GL in a remote process is unsupported (the GL presenter is app-only).
  Vulkan frames arrive only if the Vulkan driver presents through
  `-[MTLCommandBuffer presentDrawable*]`; a driver calling `-[CAMetalDrawable
  present]` directly is not copied. HDR/float drawables are not copied.
- A remote swapchain's sublayer is not used by the desktop fit or game fit
  (those follow local CAMetalLayers only).
- If a reply is lost (only with a dead connection) the next frame proceeds after
  2 s (`lost` in the stats).
- Controller snapshots are still not routed to extension clients.

## Device tests

Install the final IPA over Madeira, retaining its extensions. Use a desktop
session that pumps messages; fully quit/reopen after changing cfg.

```ini
env.MADEIRA_EXT_PROCESS = 1
env.MADEIRA_SHARED_DRIVE = 1
env.MADEIRA_EXT_PROCESS_TEST = 1
```

`inproc-sync` need not change: a madsync cfg is switched to fastsync for the
session (`ml1331 sync: madsync (inproc-sync = 1) disabled for this session ...`).
The IPA must be installed (not only refreshed) by the sideloader so it registers
the app group for the app and the extension.

Expected stages: `[device] signing: ... profile-app-groups=1`,
`ml1331 shared container: <path> (group <id>)`, `shared prefix ready`,
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
windowed-mode list, and since ml1332 the client's first window should show pixels
(`ml1332 surface hwnd=...` then `ml1332 frame hwnd=... buffer 0`). A successful
build is not evidence that the client authenticated or its helper booted.

The cheap pixel test (ml1332) starts a bundled GDI program instead:

```ini
env.MADEIRA_EXT_PROCESS_TEST = notepad
```

(`winemine` works the same way.) Expect `test: launcher exec-child requested
(notepad)`, the phase-2 start stages, then `[ext-proc] ml1332 surface hwnd=0x…
WxH iosurface id=…,… (buffers 0,1) kind=gdi`, `[ext-proc] ml1332 frame hwnd=0x…
buffer 0 dirty 0,0 WxH`, then alternating `buffer 1` / `buffer 0` lines while
typing, and a visible, typeable Notepad window (in windowed mode, its own frame).
Closing it should log both stats lines with `surfaces live=0`.
Frame failure shapes: no `surface` line (no GDI surface in the extension: check
that the session is a desktop session); `surface` but no `frame` lines (XPC
send failed); `frame` lines but a black/garbled window (Core Animation did not
take the IOSurface: report it, `env.MADEIRA_EXT_PROCESS_FRAMES = 0` restores
phase 2); `IOSurface ... allocation failed`.

**Extension log (ml1333).** The extension writes its stderr (Wine's own output, its
milestones, early fatal signals and uncaught Objective-C exceptions) to
`<shared container>/madeira-shared/ext-logs/<pid>.txt` (newest 16 kept; its own
Documents only if the group does not resolve). When the extension is interrupted, its
connection drops or its guest exits, the app appends that file to the session log as
`[ext-proc] ml1333 ext log pid=N (<why>): L lines, B bytes, <path>` followed by
`[ext-proc] ml1333 ext log: <line>` (first 60 and last 140 lines of a longer file).
Inside it: `[ext +T] ml1333 extension pid=N log=<path>; crash handlers installed ...`,
`ml1333 start argv[i]=…`, `start cwd=…`, `start prefix=… exists= system.reg= c:->… drive_c=`,
`start ntdll <arch> readable=`, `start server socket fd=… open=… desktop=… fastsync=…
footprint= available= threads=`, `ml1333 entering __wine_main`, `ml1333 phase spawn:…`,
heartbeats `ml1333 alive +50ms … +6400ms footprint= available= threads=`, and on a
death before Wine's own signal handlers exist `[ext-crash] ml1333 signal N addr= pc= code=
thread mach id …; backtrace:` with symbol lines (after ntdll initialises signals, Wine's
handlers report into the same file). The app also logs any uncaught Objective-C
exception before it dies: `[crash] ml1333 uncaught Objective-C exception <name>:
<reason> (thread mach id N)` plus up to 24 `[crash] ml1333   <frame>` lines.

**Data directory and silent deaths (ml1334).** Log 101: the remote `cmd.exe` reached
`entering __wine_main`, then `err:environ:read_nls_file failed to load
…/App.app/PlugIns/MadeiraProcessHost.appex/nls/normnfc.nls` (and `locale.nls`,
`l_intl.nls`), connected to the server, published the hardware registry and ended
~0.3 s after stage 5 with no crash line (app: `extension interrupted`, launcher
`c00000e5`). ntdll's `init_paths` took every bundle path from its running image's
directory, which in the extension is the `.appex`: nls/ (locale, normalisation and
the case table), the PE sets that `load_ntdll`/`apisetschema` open through `dll_dir`,
`bin_dir`, `ntdll_dir` and the loader name. Without `l_intl.nls` the case table is
NULL and the first case-insensitive comparison (the next steps are init_files and the
startup info's path work) reads it; had boot got further, ntdll.dll would not have
been found either, and the loader's `fatal_error` only wrote to os_log.
- `loader_ios.c ios_resolve_bundle_dir`: `MADEIRA_BUNDLE_DIR` first when it names a
  directory with nls/; else, when the image directory has no nls/ and is
  `<bundle>/PlugIns/<name>.appex`, the containing bundle if it has nls/; else the image
  directory. The app's processes never set the variable and keep their directory,
  silently. Log: `[ext-proc] ml1334 data dir: <path> (bundle env | appex parent | image
  dir)`, with `-- NO nls/ here` when none was found, and `MADEIRA_BUNDLE_DIR=… ignored`.
- ProcessHost.m sets `MADEIRA_BUNDLE_DIR` to the app's bundle path (`PH_INFO_BUNDLE`),
  else its own containing bundle, and logs `[ext-proc] ml1334 bundle dir for Wine:
  <path> (from the app | this extension's containing bundle) nls/=present|MISSING`. An
  app-supplied value in the forwarded environment is not applied.
- A missing case table now ends the process at its cause: `[Wine ntdll] ml1334 FATAL
  (this process's boot thread ends): ml1334 the case table <dir>/nls/l_intl.nls did not
  load …`. The loader's `fatal_error` and `ios_fatal_startup_error` now also write
  `[Wine ntdll] ml1334 FATAL …` to stderr, and in the extension report the end to the
  app (`wine_launched_process_did_exit(1)`, so `ml1330 exit code 1` and the log).
- Boot steps: in the extension every start-up step prints `[boot] ml1334 <step>`
  (`virtual_init...`, `init_environment (nls tables)...`, `server_init_process...`,
  `init_files...`, `startup info: get_startup_info...`, `… add_dynamic_environment...`,
  `… load_main_exe...`, `load_ntdll...`, …; the app only stores the newest step). The
  heartbeat runs until the process ends (`ml1333 alive +Nms … step=<newest step>`: dense
  for 6.4 s, then every 10 s, after 2 min every 60 s).
- Exits: every `exit()` of the Wine Unix side passes the shim's observer, `[ext-proc]
  ml1334 exit(N) from <symbol>+0x… (image offset 0x…), thread mach id …, boot step …;
  backtrace:`; libc `exit()` itself logs `ml1334 libc exit(): the extension process is
  ending …` (atexit). Crash handlers now also cover SIGSYS, SIGPIPE, SIGUSR1/2, SIGQUIT,
  SIGINT, SIGTERM, SIGHUP, SIGALRM, SIGVTALRM, SIGPROF, SIGXCPU, SIGXFSZ and SIGEMT
  (default actions that end a process without a word) and run on an alternate stack
  (a stack overflow is reported); the `[ext-crash]` line adds the sender pid and the
  boot step. Only SIGKILL (jetsam, code signing, a guard exception, the debugger) and
  `_exit` remain unlogged in the extension; see the next point.
- The extension runs under its JIT debugger for its whole life (`[jit-helper] enable:
  finished` came 70 ms after the death in log 101). The helper now returns the script's
  last six lines and the app logs them: `[jit-helper] ml1334 enable result: Madeira
  detached cleanly … Script tail: … | Madeira JIT: inferior exited (W<status> | X<signal>)`
  or `… undeliverable after 8 tries — killing inferior …`. This names a SIGKILL death,
  including one by the debugger after a fault it could not hand back. (Assumes the
  StikJIT progress callback carries the script's `log()` lines, as its NSLog does.)
- App side: every path that ends an extension logs `[ext-proc] ml1334 app ended the
  extension: <why> (pid N)`, e.g. `the XPC connection was invalidated (the extension
  process ended)`, `iOS interrupted the extension request (…)`, `its Wine process
  exited (code N)`, `prepareGuest failed over XPC: …`, `the launcher ended the session
  (…)`. The app never times out a started extension: the 55 s deadline only covers
  start-up (`finish` ignores it once the launch completed), the control socket's 10 s
  timeouts only poison that socket, and its EOF/EAGAIN never cancel the request.

Failure shapes: no shared group / extension cannot resolve it (see Prerequisites
for reading the group lines); madsync still active (kept by
`env.MADEIRA_EXT_PROCESS_KEEP_MADSYNC = 1`, or started earlier in the app run); JIT helper/pool unavailable; preparation stage failure; reused extension
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

Phase 3: `rebuild-native.sh win32u` (only `driver_ios.c` changed on the Unix side);
iOS SDK `-fsyntax-only -Wall` of ProcessHost.m, ProcessHostStubs.c,
ProcessHostClient.m, Winios.m and WiniosWindowed.m; `swiftc -typecheck` of
MadeiraExtProcess.swift against stubs; one full `build-app.sh` that links and
embeds the extension (see HANDOFF.md for its outcome and the symbol checks).

ml1334: `rebuild-native.sh ntdll win32u` (loader_ios.c, env_ios.c, server_ios.c and the
exit shim); iOS SDK `-fsyntax-only -Wall` of ProcessHost.m, ProcessHostStubs.c and
ProcessHostClient.m; `swiftc -parse` of MadeiraJITHelper.swift / JITBuiltInHost.swift and
an executed Swift 6 probe of the helper's script-tail buffer; `check-process-host.py`
now also runs the production `ios_resolve_bundle_dir` against synthetic bundles (app
unchanged and silent, .appex resolves to its app, the variable wins, a variable without
nls/ is ignored loudly, no nls/ anywhere is reported). No device run.

Apple API references: [App Group container access](https://developer.apple.com/documentation/foundation/filemanager/1412643-containerurl),
[thread_get_state](https://developer.apple.com/documentation/kernel/1418576-thread_get_state).
