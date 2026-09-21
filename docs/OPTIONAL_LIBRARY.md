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
resolution can still override it. Engine options apply at launch; restart
Madeira when changing engine options between sessions, since native libraries
can cache their configuration. Arguments support double-quoted tokens, up to
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
opens the in-game menu; B closes it. Hints use Xbox-style logical button names.
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
