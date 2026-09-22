# Optional library

The diagnostic interface remains the default. In Files, open Madeira and
create `madeira-frontend.txt` containing:

```text
MADEIRA_FRONTEND=1
```

The same line in `madeira-env.txt` also works. Return to Madeira while no
session is running, or relaunch the app. Remove the line from both files to
restore the diagnostic interface. No executable files or saves are moved.

Use **+** to browse `wine/drive_c`. Only x86/x64 PE executables inside that
directory can be added. The library records a relative path, so an app
container path change does not invalidate entries. Copy complete application
directories with Files; adding an entry does not install dependencies.

Open a card to edit its title, match artwork using public Steam Store search,
choose a local image, or set launch options. Automatic artwork matching selects
the nearest title returned by Steam search. Abbreviated filenames can still
need manual correction through Find on Steam. Search
and Steam artwork need internet access, but local titles, images, and launch
profiles work offline. No Steam sign-in or private library access is involved.

Each profile offers virtual resolution, fit/fill/aspect/stretch presentation,
30/60/display-maximum/uncapped pacing, reduced x87 precision, fast synchronization,
extended display modes, arguments, live logs, and touch-control preferences.
The default virtual display is 1280×720. A previously saved in-application
resolution can still override it. Synchronization options refresh after quitting
the current session and starting the next; experimental semaphore waits default
off. Other cached engine options, including reduced-precision x87, still require
restarting Madeira. Arguments support double-quoted tokens, up to
16 tokens and 1023 UTF-8 bytes, matching the existing launch bridge.

Enable JIT before Play. Sessions open fullscreen with no log panel unless
enabled in their profile. Drag the small menu button to move it. The menu
offers an FPS/RAM/battery overlay, live frame limits, touch controls, their
existing XInput/keyboard/mouse editor, the keyboard, and Quit. Editor changes
are saved to the current profile when returning to the menu; menu settings
are saved when dismissing it. Quit now requests termination of the Wine session
through the wineserver's process lifecycle, including child processes. It does
not wait for an application exit dialog; unsaved work is lost. Return to the
library waits for native teardown. Restart Madeira between compatibility-option
comparisons because native components retain configuration across sessions.

The Library and Settings tabs separate browsing from setup. Settings contains
Enable JIT, entitlement status, the same extended-diagnostics switch as the
legacy bug icon, pointer sensitivity, and controller mouse mapping. The Desktop
entry starts the existing explorer/services virtual desktop with its own saved
resolution and profile. The in-game menu exposes the existing Absolute,
Relative, and Touch pointer modes, including touch and physical-mouse sensitivity.

Library cards use equal 2:3 cover rectangles and equal title space. Architecture
and graphics badges replace the resolution caption. Graphics badges describe PE
imports, not a measurement of the active renderer: an application can import
several APIs or load its renderer dynamically (shown as API auto). Details use
background artwork, and launch artwork remains until Metal frames or a GDI
surface arrives. This detects first rendering, not completion of an application's
own loading screen. After 30 seconds a Show game view escape remains available.

The dark session panel exposes FPS, average frame time, app memory footprint,
and battery as independent overlay fields. Average frame time is the reciprocal
of the one-second presentation rate; it is not a percentile. The movable menu
button fades three seconds after use. Motion respects Reduce Motion.

The keyboard uses its own key window and an accessory row for Esc, Ctrl, Shift,
Alt, Tab, Enter, arrows, and Done. Modifiers latch until toggled off or dismissed.
Typing currently uses the existing US/ASCII virtual-key mapping.

A controller's D-pad/left stick browses cards; A opens details/plays, B returns,
Y adds an executable, and shoulder buttons switch Library/Settings. Back+Start
opens the in-game menu; B closes it. Controller hints are hidden in the interface.
Detailed settings and the executable browser still use touch. Controller input
is neutralized for the guest while the library/menu owns it.

Library data is stored atomically in `madeira-library.json`; local cover
thumbnails are in `madeira-art`. An unreadable or newer library file is left
untouched and cannot be overwritten through the UI. Removing an entry does
not remove its executable or saves. Liquid Glass is used on iOS 26 and newer;
older systems use a system material. The session panel has an opaque dark base
so bright game content cannot wash out its controls.

## ml1150 performance and compatibility checks

* `DXMT_D9_QUERY_ADAPTIVE=0` restores lifetime-based D3D9 query throttling.
  The default starts a new polling burst after a 250-microsecond gap, avoiding
  the 100-microsecond bounded wait when ordinary asynchronous checks are spread
  across frames. Tight loops retain their existing back-pressure and submission
  rules. Look for `[query-pacing] ml1150` and `[d3d9-query]` parked percentages.
* `[frame-tail] ml1150` reports p99, p99.9, maximum, and counts at/above 50/100ms.
  Histograms now cover 4096 one-millisecond bins instead of clipping at 64ms.
  Samples still exclude intervals of four seconds or more; short windows do not
  contain enough frames for a stable p99.9 estimate. `MADEIRA_FRAME_STATS=0`
  disables these measurements along with the existing frame census.
* `MADEIRA_UI_LOG_IDLE=0` restores hidden frontend log parsing. By default,
  `[ui-log-idle] ml1150` confirms that the display tail/parser is suspended
  during sessions with Live logs off. Native and Swift file logging continues;
  hidden lines are not replayed into the UI after the session.
* `MADEIRA_EXEC_FAULT_CODE=0` restores the prior generated-page-fault exception
  code. `[exec-fault] ml1150` is capped at four reports per module. Synthesized
  execute faults now explicitly carry EXCEPTION_ACCESS_VIOLATION rather than
  inheriting an unrelated native record code, consistent with Microsoft's
  [exception record contract](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-exception_record).
  This corrects exception semantics; it does not make an invalid target executable.
* `MADEIRA_SESSION_STOP=0` restores the legacy Alt-F4 quit behavior. The new
  `[session-stop] ml1150` request runs on the server thread; main guest-thread
  cleanup also handles pthread exit so the frontend can observe completion.
* `MADEIRA_FRONTEND_KEYBOARD=0` restores the legacy keyboard target;
  `MADEIRA_FRONTEND_CONTROLLER=0` disables frontend controller routing.
  Removing `MADEIRA_FRONTEND=1` disables the entire optional interface.

For a managed-runtime loading hang, compare fresh app launches with Fast semaphore
waits on/off in the profile (or `MADEIRA_FASTSYNC_SEM=0` with no profile override).
Logs 111 and the earlier diagnostics show continuing rendering, little late-stage
file I/O, and no detected late token; they do not establish a storage bottleneck
or prove that semaphores are responsible. Preserve the application's Player.log
from its AppData/LocalLow directory when available. Neither that hang nor the
startup failure is considered resolved until a device run demonstrates it.

# Performance validation

Compare the same scene, in-application resolution, FPS limit and thermal
conditions on device. First compare with the frontend disabled to isolate
the renderer change. Collect at least 30 seconds after loading settles.

* `[present-size] ml1140`: guest-pixel presentation. At a 1280×720 window,
  the drawable should now be 1280×720, not 3840×2160 on a 3× host.
  `MADEIRA_PRESENT_PIXELS=0` restores the previous scale multiplication.
* `[mode-budget] ml1140`: advertised modes default to the session pixel
  budget. `MADEIRA_EXTENDED_MODES=1` restores the larger mode ladder.
* `[d9-display] ml1140` and `[iOS ChangeDisplaySettings]`: fullscreen virtual
  mode changes. `DXMT_D9_VIRTUAL_MODE=0` disables the new D3D9 mode request.
  Verify that the cursor can reach all four edges after resolution changes.
* `[frame]`, `[frame-owner]`, `[gpu-work] ml1140`: presenter timing, owner
  transitions, realized Metal passes/attachment actions and GPU time per
  present. `MADEIRA_FRAME_FOLLOW=0` restores initial presenter pinning;
  `MADEIRA_FRAME_STATS=0` disables the instrumentation.

GPU duration is command-buffer time, not display latency. The new gpu-work
line normalizes the aggregate by presents; parallel buffers and asynchronous
heartbeat boundaries can overlap. Attachment counts are not bandwidth bytes.
No performance increase or successful device UI interaction is established
by a build or binary-content check alone.

Design references: Apple's [drawable pixel dimensions](https://developer.apple.com/documentation/QuartzCore/CAMetalLayer/drawableSize),
[Metal load/store guidance](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/LoadandStoreActions.html),
and [Liquid Glass API](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)).

## Recent updates: ml1160–ml1180

- iOS shader caches now use the app's Caches directory. Disabled blend fields
  and unused pixel-sampler types no longer multiply equivalent pipeline variants;
  unused sampler/view setup is skipped. Cold compilation can still cause hitches.
- Small managed 2D texture mirrors can remain resident instead of triggering a
  GPU readback on a later lock. The optional cache holds at most 32 MiB per module
  and accepts resources up to 256 KiB. Existing compressed sole-copy mirrors do
  not consume that budget. `DXMT_D9_SMALL_MIRROR_CACHE=0` restores eager eviction;
  `[mirror-cache] ml1180` reports the policy.
- Completed oversized staging blocks can be reused. Each ring retains at most
  two extra blocks, each at most 16 MiB, using the existing completion and expiry
  rules. `DXMT_RING_OVERSIZE_REUSE=0` restores the old policy; `[ring-reuse] ml1180`
  reports policy and first actual reuse. This reduces allocation churn, not the
  amount of texture data an application uploads.
- `[readback-detail] ml1180` splits synchronous readbacks into managed/default
  mirrors, render targets and front buffers, with byte totals and sampled sizes.
  `DXMT_D9_READBACK_STATS=0` disables it. Compare with `[submit-causes]`,
  `[frame-tail]`, `[gpu-work]`, `[pipeline-wait]`, and `[device-load]`.
- The Windows FEX lookup tables are recommitted after being cleared. This keeps
  Wine's page bookkeeping consistent when a DEP transition reapplies protections.
  `FEX_LOOKUP_RECOMMIT=0` rolls back; `[lookup-commit] ml1180` confirms the policy.
  It does not repair unrelated invalid guest jumps.
- The native icon-only tab control has no inner rectangular backgrounds. Library
  cards center in the available width; cards/compact/list layouts and last-played,
  alphabetical, date-added and size sorting remain available. Detail artwork is
  restricted to the header and is less blurred. Startup uses the wide hero image in both orientations (restored in ml1190).
- Size scans now ascend conventional binary subdirectories such as `bin`,
  `Binaries` and `Win32` to include the installation's assets. Existing cached
  sizes refresh automatically. Unusual layouts remain an estimate of the detected
  folder, not a package manifest. `MADEIRA_LIBRARY_INSTALL_SIZE=0` restores the
  executable-directory scan; `[library-metadata] ml1180` reports the scan revision.
- The session menu contains live Display fit choices, saved per profile. After
  30 seconds on the startup cover, Show live log opens a small log panel below
  Show game view. It displays the most recently updated log entries. Removing
  the launch cover returns log visibility to the profile's original preference.
  `MADEIRA_SESSION_TOOLS=0` hides the new controls; `[session-tools]`,
  `[session-display]` and `[startup-log] ml1180` identify them.
- Opening the menu clears held controls and blocks the UIKit touch-control layer,
  including fingers already tracking. Controls stay hidden during the menu and
  launch cover. `MADEIRA_MODAL_TOUCH_GUARD=0` restores the old routing;
  `[modal-input] ml1180` reports the policy. Retest button taps, sticks, scrolling,
  dismissal and rotation with touch controls enabled.
- Absolute pointer mode uses trackpad motion; Relative and Touch keep their
  existing semantics. Cursor size follows guest-pixel scaling, and hosting updates
  between desktop and direct sessions. These fixes do not prove that an
  application's input/message loop is responsive.
- For unresolved loading/startup/input failures, `[guest-log] ml1180` captures
  bounded error excerpts from guest log-file writes; `[guest-code]` captures safe
  caller-code candidates around bad guest branches; `[mouse-delivery]` and
  `[cursor-visibility]` distinguish delivered clicks from guest cursor hiding.
  Disable with `MADEIRA_GUEST_LOG_ERRORS=0`, `MADEIRA_GUEST_CALLER_CODE=0`, and
  `MADEIRA_MOUSE_DELIVERY=0`, respectively. These are diagnostics, not compatibility
  fixes. Native/PE build verification cannot establish a successful device run.


## ml1190: fewer readback waits and redundant attachment stores

- Restoring a managed 2D/cube mirror now batches stale mip/face transfers into
  one submission and wait, with a 16 MiB batch budget. A single larger surface
  keeps its old allocation size. Allocation failure falls back to individual
  downloads. CPU mirrors are populated only after GPU completion; decoded BC
  sole-copy mirrors remain untouched. `DXMT_D9_BATCH_READBACK=0` restores separate
  waits. `[readback-batch] ml1190` reports policy, actual batches and waits saved.
- A render target immediately overwritten by a matching full clear no longer
  needs its previous contents stored to memory. Matching requires the same view,
  dimensions, array coverage and base subresource, with no resolve attachment.
  Dependency ordering is retained. `DXMT_CLEAR_DISCARD_STORE=0` disables this;
  `[clear-store] ml1190` reports actual stores omitted. Device correctness and
  performance still need checking, especially after resolution changes.
- JIT allocation enters the existing verified fixed-address fallback after one
  rejected debugger allocation, avoiding repeated multi-second suspension in the
  forbidden guest address band. `MADEIRA_JIT_FAST_PLACEMENT=0` restores eight
  attempts; `[jit-placement] ml1190` reports policy. This addresses an observed
  retry sequence, not a proven cause of every desktop crash.
- Native tab backgrounds now have a full-height transparent canvas; the previous
  one-pixel canvas could clip the symbols. Desktop omits Library details, and
  portrait startup again uses the same wide artwork as landscape.
- `[guest-callee] ml1190` adds bounded runtime-code candidates for recognized
  position-independent indirect-call address builders. It shares the existing
  `MADEIRA_GUEST_CALLER_CODE=0` switch and four-dump limit. It never changes guest
  execution. The invalid guest return remains unresolved. A successful build
  does not establish that a device startup/loading problem is fixed.

For comparisons, keep resolution, frame cap and thermal conditions consistent,
record the same scene after warm-up, and send the full saved log. Relevant tags:
`[frame]`, `[frame-tail]`, `[gpu-work]`, `[readback-batch]`, `[clear-store]`,
`[submit-causes]`, `[device-load]`, `[pipeline-wait]`, `[guest-log]`,
`[guest-callee]`, `[guest-frame]`, `[guest-seh]`, and `[jit-placement]`.

- The PE headless display backend now returns user32's real primary monitor
  handle in DXGI output descriptions. A private sentinel previously disagreed
  with Wine's virtual-monitor identity, so clients comparing the handles could
  fail to associate an otherwise valid output. `DXMT_WSI_MONITOR_IDENTITY=0`
  restores the sentinel. `[monitor-identity] ml1190` records the selected handle;
  `[dxgi-modes] ml1190` reports the first 16 supported-format mode queries
  (`DXMT_DISPLAY_MODE_STATS=0` disables those reports).
- All three DXMT PE architectures are refreshed, including the previously stale
  64-bit display DLLs. Release optimization is now the default for each; existing
  Meson trees are explicitly reconfigured rather than silently keeping debug
  settings. `MADEIRA_DXMT_PE_BUILDTYPE=debug` is the build-time rollback.
  `[dxmt-pe-build] ml1190` records the selected build type in the build log.
- The additional local device log 135 identifies a resolution-list exception
  before settings-dependent loading failures. Static IL inspection is consistent
  with an empty list, and the display identity fix addresses a concrete API
  mismatch. The owner still needs to confirm that mode enumeration resumes and
  loading succeeds; this is not evidence of a storage-speed problem.

- The existing D3D9 census TLS pointer is explicitly constant-initialized across
  translation units. This resolves the ARM64EC external-initializer link failure
  found while refreshing that architecture; no new TLS slot or FEX change is made.

- Desktop lookup and clicks (ml1210): a shell-less desktop can belong to the
  calling process in Wine's handle table without having a client window object.
  It is now recognized as a desktop when its handle is valid. This repairs
  ancestor lookup for child controls and lets desktop rectangle queries return
  the monitor bounds, so centered dialogs no longer use a zero-size desktop.
  `MADEIRA_DESKTOP_HANDLE_FIX=0` restores the old lookup; `[desktop-handle] ml1210`
  reports the first four matches. Invalid/stale handles and real local window
  objects retain their existing behavior.
- Log 138 identifies the click failure as activation of handle zero (error
  1400), while the actual dialog is already active and foreground. Its negative
  placement also puts part of the displayed dialog outside the mouse's screen
  bounds. The ml1200 foreground-policy experiment did not address this cause
  and has been removed; `MADEIRA_CLICK_ACTIVATION` no longer changes behavior.
  Normal Wine activation policy, including guest veto/eat replies, is restored.
  `[click-activation] ml1210` retains the first 16 activation outcomes; disable
  with `MADEIRA_MOUSE_DELIVERY=0`. Host checks pass; launcher interaction and
  cursor travel still need confirmation on device.

- Launcher handoff (ml1220): exiting the original executable no longer stops
  wineserver while application processes remain in the session. The original
  session thread waits for the server; Wine's own application count decides
  when the session is finished, including child and grandchild launchers that
  have not created a window yet. Quit still requests termination of the entire
  session. `MADEIRA_SESSION_DESCENDANTS=0` restores immediate stop when the
  original thread retires. `[session-handoff] ml1220` reports retirement,
  bounded remaining-process counts, and final completion. Server thread cleanup
  now clears its running flag on `pthread_exit` as well as normal return.
  Log 139 confirms the previous click/placement repair and shows a child being
  loaded before the parent exit triggers premature server shutdown. The new
  handoff passes host lifecycle checks; successful child startup needs a device
  retest.

- Nested 32-bit launchers (ml1230): if both normal guest windows are occupied,
  Madeira can complete the unused upper half of its held address reservation
  into a third window. It acquires the missing 64 KB and overrun guard only
  when that space is free; existing mappings and the original session PEB
  remain intact. A previously allocated large pool can prevent this extension.
  `MADEIRA_WOW_EXTRA_WINDOW=0` disables it. `[wow-capacity] ml1230` reports the
  extension or why it failed. Log 140 proves that the third process previously
  failed its address-space reservation before loading its executable. The host
  allocator checks pass; successful game startup remains a device test.

- Native DLL placement with multiple guest windows (ml1240): guest allocation
  detection now checks both address bounds. A native DLL's host ceiling can
  overlap the third guest window without making it a guest allocation. Native
  images now stay outside those windows and retain normal executable JIT-pool
  mapping. Log 141 confirms third-slot allocation but faults at the native
  WOW64 loader entry point before rendering, after the old upper-bound-only
  check placed that DLL inside guest memory. `MADEIRA_WOW_STRICT_LIMITS=0`
  restores the old decision; `[wow-placement] ml1240` records the first eight
  differing classifications. Host checks cover all three windows, ordinary
  and high-half guest requests, low-address devices, and rollback. Full startup
  and rendering still require device confirmation.
