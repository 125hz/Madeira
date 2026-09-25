# Physical controllers and XInput

This is the physical-controller portion of the 125hz fork's input work,
extracted onto upstream without the touch-layout editor or keyboard/mouse
remapping. Up to four extended GameController profiles are assigned stable
XInput user slots. Disconnecting one does not renumber the others.

The app captures the live profiles and samples them on a serial queue at 250 Hz
(4 ms with 1 ms scheduling leeway), with change callbacks for prompt updates.
The timer stops while inactive or with no connected pads. Inactive controllers
remain connected but report neutral input. Disconnects clear their slots.
Buttons, triggers, and signed stick axes reach XInput without mouse synthesis
or an app-imposed dead zone. iOS 18 event claims prevent UIKit/SwiftUI focus
navigation from consuming controller events.

`WiniosGamepad.c` publishes snapshots under a short mutex. Packet numbers change
only when the sample or connection changes. The win32u query copies the state
or capabilities into the Windows caller's buffer. Wine's paired XInput change
tries this query before its existing HID path.

Set `env.MADEIRA_XINPUT = 0` in Documents/madeira.cfg and restart to disable the
producer and event claims. `[xinput] ml1920` logs enablement and connections;
there is no per-sample logging. This first contribution does not implement
controller vibration, battery telemetry, DirectInput, touch gamepad controls,
or library navigation. The existing controller tab still contains placeholders
for touch controls.

## Integration prerequisite

The companion change targets `willfaust/wine`'s `madeira-lgpl` branch. Review
and integrate that change together with this one, then update Madeira's Wine
pin. This source-review PR deliberately retains upstream's submodule pins and
prebuilt DLLs until the dependency is accepted and the combined build is tested.

Rebuild the native win32u library and the affected PE win32u/XInput modules
using the paired Wine source before testing. Rebuild wow64win for a WOW64
configuration. XInput 1.1/1.2/1.3/1.4/UAP share the implementation; 9.1.0 forwards
to 1.4. Copying just the app changes over the existing prebuilt DLLs will not
enable the feature. No binaries from the larger fork are included here.

## Validation

Run `python3 build/host-tests/check-gamepad.py` on a POSIX host. It compiles the
actual snapshot code and win32u query, checking packet stability, axis/trigger
ranges, slots, invalid queries, disconnect/reconnect and concurrent readers
and writers. The companion Wine branch has a standalone native Windows API
test with a synthetic host query; it does not require a game or Steam.

The extracted Swift bridge was type-checked for arm64 iOS 17 against the iOS
SDK, using the production config reader and a log-sink stub. The C transport
also compiled for arm64 iOS 17. The Wine XInput source compiled for x86-64 and
i386, and the native Windows API test passed.

The full combined upstream app has not been linked or device-tested. Before
marking this ready, pair a controller and check buttons, both sticks, triggers,
disconnect/reconnect, background/resume, a second pad, and the rollback flag.
The fork's existing device history does not prove this isolated extraction.
