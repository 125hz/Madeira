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
choose a local image, or set launch options. Automatic artwork matching only
accepts one exact title match; ambiguous filenames need manual search. Search
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
are saved when dismissing it. Quit sends a normal close request; confirm any
application save/exit dialog. Madeira returns to the library after native
process exit. A hung application may require restarting Madeira; the menu
does not terminate arbitrary host threads.

Library data is stored atomically in `madeira-library.json`; local cover
thumbnails are in `madeira-art`. An unreadable or newer library file is left
untouched and cannot be overwritten through the UI. Removing an entry does
not remove its executable or saves. Liquid Glass is used on iOS 26 and newer;
older systems use a system material.

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
