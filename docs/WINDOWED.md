# Windowed mode (ml1300, first version)

Windowed mode shows every top-level Windows window of a desktop session as a
window of its own on the iPhone or iPad screen: a dark translucent (blurred)
title bar with the window's text centred and four round monochrome buttons
(minimize, fit to screen, maximize, close), draggable, brought to the front by
a tap, several of them overlapping at once. A taskbar along the bottom holds a
search field, the running program windows (Steam's with Steam's icon, round
7), the keyboard and the in-game menu. It is off by default; with it off nothing below runs and
desktop sessions look exactly as before.

## Turning it on

**Settings › Graphics › Windowed mode** writes it; by hand, in
`Documents/madeira.cfg` (or a game's own config lines):

    windowed = 1

`env.MADEIRA_WINDOWED = 1` does the same; `env.MADEIRA_WINDOWED = 0` turns it
off even where `windowed = 1` is set. It applies to **desktop sessions only**:
the Desktop entry, a game whose start mode is "Wine desktop", and every
Madeira Dock start (Steam plus the game). A direct game start (the game is
Wine's first process, no desktop) is not windowed; there the game presents
through the full-screen Metal layer as before. The switch is read once at the
start of each session.

`env.MADEIRA_WINDOWED_TOUCH = 0` keeps the pointer mode chosen in Settings.
By default windowed mode uses Touch pointer mode (tap where you touch, hold
and move to drag, two fingers for right click and scroll), because a
trackpad-style pointer moves in guest desktop coordinates and cannot follow a
frame you dragged somewhere else on screen.

## How it works

Files: `app/Madeira/Winios/WiniosWindowed.m` (frames, taskbar, input
targets), `WiniosWindowed.h`, hooks in `app/Madeira/Winios/Winios.m`,
helpers in `build/win32u-unix/driver_ios.c`, the Swift end in
`app/Madeira/WindowedMode.swift`, one line in `ContentView.swift`
(`touchPointerMode`).

**Pixels.** A desktop session already keeps one CALayer per top-level window
in the desktop compositor (`Winios.m`): the window's GDI surface (a 32-bit DIB
the driver hands over at each flush) as its contents, and for a window a
Direct3D swapchain presents into, a CAMetalLayer sublayer over its client
area. Nothing about that changes. Windowed mode only moves each window's layer
into a *host* layer inside a frame view; the host's bounds origin is the
window layer's own origin and its transform is the frame's zoom, so the window
always fills its frame's content area wherever the frame is, and the
compositor's frame, contents and Metal updates keep working untouched. The
guest's own window decorations stay visible inside the frame (a program's
caption, menu bar and borders), under the native title bar.

**Which windows get a frame** (`ww_classify`):

| window | shown as |
|---|---|
| the desktop window, child windows | not drawn (the background is black) |
| explorer's own taskbar (`Shell_TrayWnd`, the Start menu of a Desktop session) | a frame of its own (titled "explorer"), no taskbar button, so it can be moved out of the way |
| unowned, or `WS_EX_APPWINDOW` (program windows, Steam's main window, a game window) | a frame with a title bar, and a taskbar button |
| owned, with a caption (dialogs, message boxes) | a frame with a title bar, placed over its owner, no taskbar button |
| owned, without a caption (menus, tooltips, drop-down lists, owned popups) | inside its owner's frame at the guest's relative offset, moving and zooming with it |
| unowned tool windows, or owned popups whose owner has no frame | drawn without chrome where the plain desktop layout would put them |

The driver reads each window's text, styles, owner, root owner, class, the
owning program's file name and its class icon on the window's own thread at
every position change, and refreshes text and styles about once a second from
the event pump (so a title change shows within a second).

**Frames are app-side.** Dragging a title bar moves the frame on screen only;
the guest window keeps its desktop position. The bottom-right grip zooms the
frame (the guest window keeps its size); since round 8 it resizes the guest
window instead and a pinch on the title bar zooms (see Round 8). When the
program moves its own window (its caption dragged inside the frame, or
`SetWindowPos`), the frame follows by
the same amount, so a drag on the guest's own caption moves the frame too.
New frames cascade from the top of the screen at a zoom of at most 1 point per
guest pixel, small enough to fit the screen; a dialog opens centred over its
owner.

**Size changes refit the zoom** (round 2). Many programs create their main
window parked off screen or at the minimized size (`-32000,-32000` and
160x31) and only then give it its real size. A frame first placed at such a
placeholder rect is placed again (cascade or centred over its owner) at the
window's first real size; any later size change of the guest window, and a
new screen size (rotation), recomputes the fit zoom, so a window larger than
the screen comes up zoomed below 1 with its whole title bar on screen. Once
you zoom a frame with the grip, size changes keep your zoom (the frame is only
kept reachable). A placeholder rect (the program minimizing itself) never
changes the frame. Each refit logs `refit hwnd=... rect=... zoom=...`.

**The title bar stays reachable.** Dragging, zooming and refits keep the whole
height of the title bar and at least 120 points of its width inside the area
above the taskbar, so a frame can always be grabbed again.

**Input.** Touches on window content fall through the compositor to the game
view (`MetalBackedView`), which maps them through
`winios_desktop_point_from_window`. In windowed mode that finds the frame (or
popup) under the finger, frontmost first, and converts the point into that
window's own desktop pixels. Because two frames that are apart on screen can
overlap on the guest desktop, a desktop hit test would pick the wrong window:
the mouse event instead names the top-level window, and the server routes it
there (`send_hardware_message` with the window; `find_hardware_message_window`
takes `msg->win` when it is visible, mouse capture first). A press latches its
window until the last button is up, so a drag that leaves the frame still
goes to it. A touch on the black background is dropped. Keys go to the
focused window as before.

**Game controllers and the keyboard** (round 2). Controllers reach the guest
through the Game Controller framework (`GamepadInput.swift` polls the pads and
feeds `WiniosGamepad.c`), which does not depend on UIKit focus; nothing in
windowed mode gates it (the forced Touch pointer mode only changes touches; the
pad stops only while the app is inactive or the library menu is open, as in
every session). But since iOS 15 a controller also drives focusable UIKit
controls (the focus engine), and the first version's taskbar search field and
buttons were focusable: the pad's A opened the search field and the software
keyboard, and its Go brought the first taskbar window (another program) to
the front, so the game lost foreground and with it the pad. Now:
- `Info.plist` sets `GCSupportsControllerUserInteraction = false`.
- The windowed root carries a `GCEventInteraction` for gamepad events (as the
  game view already does), so controller events under the frames and the
  taskbar go to the Game Controller framework, not to UIKit navigation
  (`env.MADEIRA_XINPUT = 0` leaves UIKit's default).
- No chrome can take focus (`canBecomeFocused` is NO on the root, frames,
  title-bar and taskbar buttons, the window strip and the search field), the
  title-bar tap recognizers take no presses, and every button ignores an
  action that does not come from a touch (`... ignored: not a touch`).
- The search field becomes first responder only right after a touch on it.
  Touching or picking a window (a tap or click in a frame, a title bar, a
  taskbar button) gives the keyboard back to the program
  (`search field released (...)`), so a hardware keyboard is not left typing
  into the search field. Go with nothing typed only closes the keyboard.
- The taskbar keyboard button answers a touch only.

**Activation and z-order.** Touching a frame brings it to the front on
screen; the click itself activates the window in Wine. Tapping or dragging a
title bar, the fullscreen button, the taskbar and the search field also ask
the window's own thread to make it the foreground window. When a program
activates one of its windows itself, its frame comes to the front (polled 4
times a second). While windowed mode is on, the XInput foreground fix
(`ios_foreground_check`, which made a polling game's main window foreground
every second) stands down, so a game does not pull itself over the window you
chose.

**Buttons.**
- *Minimize* hides the frame into the taskbar (dimmed button). It is app-side:
  the program is not told and keeps running and rendering, so games do not
  lose their device. A window the program minimized itself (`WS_MINIMIZE`) is
  also shown dimmed; tapping it posts `WM_SYSCOMMAND/SC_RESTORE`.
- *Fullscreen* fits the window into the whole screen above the taskbar (title
  bar kept, so restore is one tap; a double tap on the title bar does the
  same). App-side; the guest window keeps its size. A fitted frame does not
  move: while it is on, the button shows the "shrink" arrows in a light ring
  (round 4; round 2 coloured it blue); dragging it only pulses the button and
  logs `move ... ignored: fullscreen`.
- *Maximize* (round 3; the "+" button, or hold the fit button) shows the
  window as a game session does: the whole screen, no title bar, the taskbar
  hidden, the picture aspect-fitted with black bars, touches mapped into it
  (a touch on the bars is dropped). App-side again: the guest window keeps
  its size. A small translucent pill at the bottom centre (it dims to 30 %
  after a few seconds; a touch wakes it) brings the windows back (its window
  icon) or opens the in-game menu; the library's in-game menu also has *Show
  all windows* while a window is maximized. One window at a time; a dialog the
  program opens still comes up in its own frame on top. The window being
  hidden, minimized or destroyed ends it. The app's own overlays (touch
  controls, the performance overlay) are separate windows above and stay
  reachable. Round 7: the library's round menu button hides while a window is
  maximized (the pill's menu button opens the same menu; `WindowedHUD` in
  `WindowedMode.swift`, observed by `LibraryHUD`; `env.MADEIRA_WINDOWED_HUD_MENU
  = 1` keeps it), and the pill can be **dragged anywhere** inside the safe area
  with one finger (a tap still hits its buttons; it still dims and wakes, still
  touch only); where it was left is kept for the rest of the session (as
  fractions of the screen, so a rotation keeps it on the same side) and every
  later maximize puts it there.
- *Close* posts `WM_SYSCOMMAND/SC_CLOSE`, which `DefWindowProc` turns into
  `WM_CLOSE`, as the close box of the window's own caption would.

**Taskbar.** A pill along the bottom: a Search field (touch it to type; it
opens the launcher below), (only with `env.MADEIRA_WINDOWED_STEAM = 1`) the
pinned Steam tile (below), one button per program window (its class icon when the program registered one,
else its program's initial; a dot under it, white for the frontmost window,
the button dimmed when minimized; tap: restore / bring to front / minimize when
already in front), then the keyboard and the in-game menu (both through
`MadeiraWindowedBridge` in `WindowedMode.swift`).

**Search** (round 5). The search field is a launcher, like a desktop OS's
start search. Touching it opens a results panel just above the taskbar (the
chrome's material, rounded, scrolling; at most 60 rows), and typing filters it
live: names that start with the text first, then a word of the name, then
anywhere in the name, then the program's file name. Each row has an icon, the
name and a second line saying what it is. The rows, in this order:

- **Open windows** (the taskbar's windows): picking one restores it if
  minimized and brings it to the front.
- **Tools**: *Explorer* (`C:\windows\explorer.exe C:\`, a file browser on
  drive C:), *Command Prompt* (`C:\windows\system32\cmd.exe`) and *Steam* (the
  Steam tile's action, below; there whether or not Steam runs, the way to start
  it since round 7; `env.MADEIRA_WINDOWED_STEAM = 0` removes it).
- **Library**: the games you added (their program with their launch arguments,
  working folder and "Start Windows services first"; a `.bat`/`.cmd` through
  `cmd.exe /c`), and the installed Steam games whose program is known: the one
  *Start with: The game* would start (the program picked in Game details,
  Steam's launch configuration, or the install folder's only program). A Steam
  game picked here starts as its own program, **without Steam** (Madeira Dock
  is not involved; a game that requires Steam may close or try to start the
  Steam client itself, as it would on Windows).
  The Desktop entry is the Explorer tool. A game's own config lines and its
  library settings that are not part of its command (display, touch controls,
  FPS limit, Wine version …) do not apply: it starts inside the session that
  is running.
- **Start Menu / Desktop shortcuts**: every `.lnk` under
  `C:\ProgramData\Microsoft\Windows\Start Menu\Programs`, and each user's
  `AppData\Roaming\Microsoft\Windows\Start Menu\Programs` and `Desktop`, whose
  target is a `.exe` on drive C: (LinkInfo's local path, else the relative
  path), with the shortcut's arguments and working folder; uninstallers left out.
- **Programs**: the `.exe` files directly inside each folder of `Program Files`
  and `Program Files (x86)` (at most four a folder, 80 in all; Wine's own
  folders, Steam's folder and file names with unins/uninstall/crash/setup/
  update/redist/report/helper left out), named after the folder when it has
  one program.

One row per program file (the first of: tool, library, shortcut, program).
The prefix is scanned off the main thread when the panel opens, at most every
20 seconds (the panel shows the last scan at once and refills when a new one
ends). Icons: a program file's own icon (read from its PE resources, as the
Steam tile's below), else a library cover, else a glyph (folder, terminal,
game controller) or the name's initial. Wine's `explorer.exe` has no icon
resource, so Explorer shows the folder glyph.

Picking anything but a window starts it **inside the running session**
(`MadeiraSession.launch`, ml1350, `docs/SESSION_LAUNCH.md`): the quoted full
path and its arguments, in the program's working folder (by default its own
folder). A failure shows an alert with the reason ("It did not start in this
session: …"; a library game adds that it still starts from the library).
Go on the keyboard picks the first row (it has a faint background); Go with
nothing typed only closes. Round 7: the return key is labelled Search
(`UIReturnKeySearch`, same action), and the field asks for no spell checking
or inline prediction, which on most keyboards also drops the suggestion bar. The panel closes when the field gives up the
keyboard: after a pick, a touch on any window or the black background, a
taskbar button, the keyboard's own dismiss key, maximize, or a new session.
Typing no longer hides taskbar buttons (round 4 filtered them).

**The keyboard** (round 5). While the search field has the software keyboard,
the taskbar and the results panel move up to sit 8 points above it, animated
with the keyboard's own duration and curve (`UIKeyboardWillChangeFrame` /
`WillHide`), and back down when it goes. Only a docked keyboard that reaches
the bottom of the screen lifts it; a floating iPad keyboard, or the keyboard
of another text input (the library keyboard, a program's text field) does not.
Frames stay where they are.

**Little room above the keyboard** (round 7). The iOS keyboard cannot be made
smaller, so the results change shape instead. With the taskbar 8 points above
the keyboard, the list above it needs room for two rows (176 points from the
top of the safe area to 8 points above the keyboard). With less:

- 112 to 176 points (an iPhone in landscape: about 170 with the docked
  keyboard, where round 6 showed one row): the results become one strip of
  **chips** (a 24-point icon and the name on a 36-point pill, 72 to 220 points
  wide, scrolling sideways) in a 48-point panel directly above the keyboard,
  and the taskbar sits above the strip.
- under 112 points (a taller keyboard, its suggestion bar, a smaller screen):
  the chips go **into the taskbar**: it widens to the screen, the field stays
  at its left, the program buttons, keyboard and menu buttons fade out while
  the search is open, and the chips fill the rest of the pill.

The first chip (with something typed) is brighter with a light edge: the
Search key picks it. New text scrolls the strip back to it. In portrait (and
on iPad) the list stays, capped to the room there is, as before.
`env.MADEIRA_WINDOWED_CHIPS = 0` always shows the list.

**Look** (round 4). Title bars, the taskbar pill and the maximize pill share
one material (`ww_material`): `UIBlurEffectStyleSystemThinMaterialDark`, a
hairline edge and a faint highlight along the top. Title-bar buttons are
28-point circles of the same neutral translucent white with a white SF Symbol
(`minus`, `arrow.up.left.and.arrow.down.right`, `plus`, `xmark`), touch
targets about 35x36 points; the frontmost frame's buttons and title are
brighter, the others dimmed. No button has a colour; a state (fit to screen)
shows as its glyph and a ring. The title bar is 36 points high (round 8: 30
points, 22-point buttons with 32-point touch targets, 12-point title). In the
taskbar every item (search field, Steam, program icons, keyboard, menu) is 36
points and they are 10 points apart, 10 points from the pill's ends; the
magnifier sits 11 points inside the search field and 7 points before its
text. On a narrow screen only the program strip shrinks (it scrolls).

**Steam on the taskbar** (round 4; round 7). Since round 7 there is a Steam
tile only **while a Steam window is open** in the session (a window whose
program is `steam.exe` or `steamwebhelper.exe`): the first such window's own
program button is the tile, in its place among the program buttons, with
Steam's icon (below; the window's icon or initial until it is read), its dot
and its tap (restore / bring to front / minimize, like any program button).
Further Steam windows keep their own buttons. With no Steam window there is
no tile; Steam starts from the search's *Steam* row (same action as the old
tile, below) or from the library. `steam: tile shown (window hwnd=…)` /
`steam: tile hidden (no Steam window)` log the changes.
`env.MADEIRA_WINDOWED_STEAM = 1` brings back the round 4 tile pinned left of
the program buttons in every session; `0` removes Steam from the taskbar and
the search. The icon is drawn in the same 36-point box as every program icon
(aspect-fit, rounded corners): until round 7 the pinned tile's icon view grew
with the button from a zero size (flexible width and height) and came out 72
points, over the pill's edge.

Round 4's pinned tile: left of the program buttons in every windowed session,
with a dot under it while a Steam window is open. Round 5: once Steam is
installed in the prefix (the `steam.exe` the tile starts, below) the tile
shows **that file's own icon**, read at run time from its PE resources: the
first icon group (`RT_GROUP_ICON`) and from it the 32-bit 64x64 image (else
32-bit 48x48, else the nearest size), PNG or DIB with its transparency. The
icon comes from the user's installed copy; no Valve artwork is in the
repository. Until then the tile keeps the monochrome game-controller glyph
on a rounded tile. The check runs when the session starts, at most every 5
seconds while the taskbar changes, when the tile is tapped and when the search
panel opens, so a Steam installed during the session gets its icon; a
`steam.exe` whose icon cannot be read is not read again that session.

- A Steam window open in this session (a taskbar window whose program is
  `steam.exe` or `steamwebhelper.exe`): the tap restores it if minimized and
  brings it to the front (`steam: launch (already running ...)`).
- Otherwise (ml1350) **the button starts Steam inside the running session**,
  through the in-session launcher (`docs/SESSION_LAUNCH.md`): the Wine desktop's
  shell thread (explorer) starts it with `NtCreateUserProcess`, as Windows
  starts a program from its shell, so Steam is explorer's child in the desktop
  you are looking at and its windows come up in frames.
  - The first tap shows "The full Steam client needs a lot of memory; the web
    helper may be killed." (plus, when Madeira Dock's client files are in the
    prefix: Madeira starts Steam with `-nobootstrapperupdate`, so it does not
    update itself; the full client has its own folder and Dock's files stay as
    Dock verified them) with Continue / Cancel. Continue is remembered.
  - **Two folders (ml1371). The full client and Madeira Dock never share a
    folder.** Dock's pinned client lives in `C:\Program Files (x86)\Steam` and
    Dock refuses any other build there (device log 102: after an ml1370 install
    into that folder every Dock start reported `client-sha256=e9045710…`,
    `session-client-adapter=0`, `session-unsupported-client=1`). The full client
    goes to `C:\Program Files (x86)\Steam Client`, or to `D:\Steam` when
    `env.MADEIRA_SHARED_DRIVE = 1` and the shared container resolves; its
    launch, the library entry, the taskbar tile and the search row use that
    folder, and "installed" is checked there (also `C:\Program Files\Steam`),
    never in Dock's folder. The installer refuses Dock's folder as a target.
  - **Steam installed** (ml1370: the full 64-bit client, i.e. an x86-64
    `steam.exe` plus `package\steam_client_win64.manifest` in
    `C:\Program Files (x86)\Steam Client` (ml1371), `D:\Steam` or
    `C:\Program Files\Steam`; Madeira Dock's folder never counts):
    `"…\steam.exe" -nobootstrapperupdate -skipinitialbootstrap -norepairfiles
    -noverifyfiles -no-cef-sandbox -cef-disable-gpu steam://open/games` is
    started in Steam's folder, `services.exe` first when none runs in the
    session (the library's "Start Windows services first"). The bootstrapper
    neither updates itself nor downloads the manifest nor checks the files (the
    app installed and checked them), so it goes straight to the client and the
    library page. `-cef-disable-gpu` stays: the web helper runs in
    single-process mode in this task (ntdll's proc-gate), where its GPU thread
    would be ANGLE on Direct3D 11 inside the same process;
    `env.MADEIRA_STEAM_CEF_GPU = 1` drops it. `env.MADEIRA_STEAM_LAUNCH_FLAGS = 0`
    goes back to `-no-cef-sandbox -cef-disable-gpu` (the bootstrapper then
    updates and verifies). The competitor's log spells the first switch
    `-nobootstrapupdate`; Valve's `steam.exe` only contains
    `-nobootstrapperupdate`. No alert: Steam's window appears when it is ready.
    A second tap within 90 s, while no Steam window is open yet, only says
    "Steam is starting". The search's Steam row reads "Steam client · path"
    only for the full client.
  - **Full client in Dock's folder** (an ml1370 install from before ml1371):
    the button and the library entry offer **Repair Madeira Dock's Steam
    files** first (below); after the repair the client starts from its new
    folder, or the install is offered when it had to be removed.
  - **Not installed** (ml1370): "Install Steam" (Cancel / Install; it says
    Dock's own client is not touched). The app does
    what Valve's bootstrapper does, natively: it reads the manifest
    `https://client-update.akamai.steamstatic.com/steam_client_win64` (HTTPS,
    redirects only on that host, at most 1 MB, a `win64` section with a numeric
    version), takes every package it lists (18 in version 1788652215, 356 MB;
    smallest first since the device test, so an interruption loses the least:
    `resources_hidpi_all` 0.1 MB … `bins_win64` 63.7 MB, `bins_cef_win64`
    148 MB last; `strings_<lang>_all` only for English), downloads each from the
    same host, checks its size and the manifest's SHA-256 before reading it, and
    unpacks it with Dock's ZIP reader (same checks; larger limits: 512 MB
    archive / file, 2 GB in all, 32768 entries; the archive is mapped, never
    read whole, files streamed to disk in 1 MB pieces) into a staging folder,
    `Library/Application Support/MadeiraSteam/client-stage` (not backed up).
    **Resume:** each unpacked package leaves a marker (`done/<package>`: client
    version, package name, SHA-256); a downloaded but not yet unpacked package
    stays in `zips/` and is used again when its size and SHA-256 still match.
    The next Install after an interruption (or a failure, or Cancel) skips the
    marked packages and continues from the first unfinished one; the
    confirmation then reads "Resume Steam install (N of M done)", and so does
    the search's Steam row. A newer client version from Valve starts over. The
    folder is removed after a complete install. While the install runs the
    screen does not auto-lock and each package (and the final move) runs in a
    UIKit background task; if iOS ends that time after the app leaves the
    screen, the install stops cleanly (`interrupted at part N of M (app
    suspended); tap Install again to resume`).
    Then it checks that `steam.exe` is x86-64 and moves everything into the
    full client's folder (ml1371: `C:\Program Files (x86)\Steam Client` or
    `D:\Steam`, never Dock's; existing files replaced, `steamapps`,
    `userdata`, `config`, `logs`, `dumps`, `appcache`, `depotcache` files kept,
    names matched case-insensitively to what is there, `steam.exe` last) and
    writes Valve's manifest to `package\steam_client_win64.manifest`. A
    progress sheet (over the windowed desktop or the library) shows "Downloading
    part N of 18 (name, size)…", "Unpacking part N of 18…", "Installing N
    files…", then "Installed. Starting Steam…" (for 2.5 s, while the start
    is queued) with a bar; Cancel stops it before anything is moved (finished
    packages are kept for the next Install). It needs about 3x the remaining
    packages' size free. In a running session only files are written (Steam
    writes its own registry keys when it starts); without a session the prefix
    is seeded first and Steam's discovery keys are written for the full
    client's folder only when Madeira Dock's client is not installed (Dock's
    keys must keep pointing at Dock's folder) and they do not conflict. During
    a Madeira Dock game session the button does not start it:
    "Quit the game first … then open the Desktop entry in your library and
    install Steam from its taskbar". When it finishes, Steam starts as above
    (`[steam-launch] ml1370 command line …`). `env.MADEIRA_STEAM_PACKAGE_INSTALL = 0`
    brings back the round 4 path: any `steam.exe` counts, else Valve's
    `SteamSetup.exe` is downloaded (cdn.cloudflare.steamstatic.com, progress
    alert, `C:\madeira-games\SteamSetup.exe`) and started.
  - **The library's Steam entry** (the fallback's "Steam" below, or any entry
    whose program is one of those `steam.exe` paths, Dock's folder included):
    Play offers the same install (the starting screen goes, the sheet comes up)
    when the full client is missing and starts the entry when it finishes; an
    entry still carrying round 4's `-no-cef-sandbox -cef-disable-gpu` is
    switched to the switches above, and (ml1371) an entry pointing at Dock's
    folder is moved to the full client's `steam.exe` (64-bit) and saved.
  - **Repair Madeira Dock's Steam files** (ml1371, `SteamDockRepair`,
    `SteamRuntimeInstaller.repairDock`). Offered when the full client is found
    in Dock's folder (Steam button, library entry, the Madeira Dock sheet's
    Steam client section) and automatically when a Dock start reports
    `session-unsupported-client=1` with a `client-sha256` other than the pinned
    one (MadeiraDock.pollReport, once per app run; the failure text names the
    repair too). A complete full client in Dock's folder is moved whole to
    `C:\Program Files (x86)\Steam Client` when that folder does not exist yet
    (not to `D:`), then Dock's `steamapps`, `userdata`, `config`, `depotcache`
    and `appcache` are moved back; otherwise everything in Dock's folder except
    those is removed. Then Dock's three pinned packages are fetched again
    (`prepare`, repair mode) and `steamclient64.dll` must hash to the pinned
    `71b391fe…`. Without a session Dock's discovery keys are rewritten even if
    another client changed them; in a session only the files (the log says
    whether the keys still point at Dock's folder). Refused while a Dock game's
    host has not reported a result.
  - **Discovery keys** (ml1371): the full client, when it runs, writes Steam's
    own `SteamPath` / `SteamExe` / `ActiveProcess\SteamClientDll(64)` for its
    folder and is left to do so. Every Madeira Dock start puts them (and HKLM
    `InstallPath`) back on Dock's folder before its session starts
    (`MadeiraDock.assertDiscoveryKeys`), so a game in a Dock session always
    finds Dock's `steamclient64.dll`.
  - **Fallback** (round 4's behaviour), when the in-session start is refused or
    fails (`env.MADEIRA_SESSION_LAUNCH = 0`, no session, the file is gone, a
    start error; the reason is in the alert and the log): a library entry
    "Steam" / "Steam Setup" is made (unless an entry already starts that file;
    Wine desktop start mode, services.exe first, the same arguments) and the
    alert says why the live start failed and to restart Madeira and open it in
    the library. With the developer interface (library off) the entry is still
    made; the alert says to switch to the library interface.
- The button answers touches only, like the rest of the chrome.
- Any other program: the in-game menu (the taskbar's menu button) has
  **Run program…** (ml1350): a command line such as
  `C:\Games\Tool\tool.exe -option`, started in this session the same way; an
  error shows its reason. The last command is offered again.

## Not done in this version

- Direct game starts (no Wine desktop) are not windowed.
- No host web view window; the competitor's browser window has no equivalent.
- No files or terminal button in the taskbar itself; since round 5 the search
  starts Explorer and Command Prompt (not device-tested: a console window
  under this driver is unproven).
- Search (round 5): no Steam game start through Madeira Dock or the Steam
  client (`steam.exe -applaunch`); a Steam game without a known program is not
  listed; shortcuts that point to an MSI feature or only through an ID list
  (no path) are skipped; `.url` and document shortcuts are skipped; environment
  variables in a shortcut's working folder are not expanded (the program's own
  folder is used); no recent or pinned items; nothing is remembered.
- The search panel closes on a touch on a window only in Touch pointer mode
  (the default here); with `env.MADEIRA_WINDOWED_TOUCH = 0` close it with the
  keyboard's dismiss key or Go.
- Window icons set with `WM_SETICON` are not read (class icons only, and only
  icons up to 64x64).
- Frames do not resize the guest window; the grip zooms the picture, and
  Maximize only shows it full screen (round 8: the grip resizes the guest
  window; Maximize and fit still only show it). The guest window itself is never
  maximized (a program's own maximize button still works inside the frame).
- Maximize is not remembered; each session starts with frames.
- Positions and zooms are not remembered between sessions.
- The trackpad pointer and a hardware mouse move in guest desktop coordinates:
  the arrow is drawn in the frontmost frame whose window covers that desktop
  point, and a click goes to that window. Touch pointer mode (the default here)
  has no such limit.
- Mouse-leave and hover tracking inside Wine still hit-test the guest desktop,
  so hover effects can stick where two windows overlap on the guest desktop.
- A touch on the black background is dropped; to close an open menu, tap any
  window.
- Windows are not clipped to the screen; a frame can be dragged mostly off it
  (at least 120 points of its title bar stay on screen).
- A controller cannot operate the frames or the taskbar (by design: its input
  is the program's); use touch for the chrome.
- The XInput foreground fix is off while windowed mode is on (see above).
- The Steam button starts Steam inside the running session since ml1350 (not
  device-tested yet); the round 4 library entry remains the fallback. No
  Valve logo in the repository: the tile shows the installed `steam.exe`'s own
  icon (round 5), a generic glyph until Steam is installed.
- ml1370's package install ran once on a device (log 99, client 1791918634:
  18 packages, 6557 files, install-phase footprint at most 688 MB, then Steam
  started with the switches above). Steam then did not open: its web helper
  loaded `libcef.dll` (~212 MB image) into the 560 MB JIT pool, the pool ran
  out (`[jit-pool] TAIL REFUSED`, `[code-buffer] EXEC ALLOC FAILED … JIT pool
  exhausted`) and steam.exe/steamwebhelper looped on execute faults while the
  footprint rose to 2.1 GB. That is the process model's / pool's problem, not
  the install's. Resume reuses only whole packages (no byte-range resume of a
  partial download). It does not write `package\steam_client_win64.installed`
  (Valve's per-file list), keeps no copy of Madeira Dock's replaced files, and
  never updates an installed client (for a newer Valve build, delete
  `package\steam_client_win64.manifest` in Steam's folder and install again). The web helper still runs in single-process mode
  in this task and still gets the session's fixed `SteamAppId`/`SteamGameId`/
  `SteamAppPath` environment (WineProcessBridge.m publishes it to every
  non-Dock session; the in-session launcher passes no environment).
- Round 7: the iOS keyboard keeps its size (no API shrinks it); the chips are
  the answer to a short screen. The chip thresholds are fixed (176 / 112
  points; 166 / 94 since round 9's smaller taskbar), not settings. The restore pill's dragged place is not kept between
  sessions.

## Log lines

All start with `[windowed] ml1300`:

    on (madeira.cfg windowed = 1)                     the switch, once per session
    off (env.MADEIRA_WINDOWED = 1; only desktop sessions are windowed)
    compositor root attached: frames + taskbar (...); chrome not focusable, gamepad events claimed for the Game Controller framework
    add hwnd=0x... kind=framed title="..." exe=steam class=... rect={x,y wxh} zoom=0.37
    refit hwnd=0x... rect={0,0 1280x720} zoom=0.52 (first real size; placed again)
    refit hwnd=0x... rect={...} zoom=... (size changed | screen changed)
    refit hwnd=0x... rect={...} zoom=... (size changed; the zoom set with the grip is kept)
    remove hwnd=0x... kind=framed title="..."
    activate hwnd=0x... "..." (tap | drag | taskbar | fullscreen | search | guest)
    activate hwnd=0x... foreground=1 (tap)           the window's thread made it foreground
    move hwnd=0x... to (x,y) pt (app side; the guest window stays at x,y)
    move hwnd=0x... ignored: fullscreen (fitted) frames stay put; ...
    scale hwnd=0x... zoom=0.62 pt/px (the guest window keeps its size; kept when it resizes)
    scale hwnd=0x... zoom=0.62 pt/px (title bar pinch; the guest window keeps its size; kept when it resizes)   round 8
    resize hwnd=0x... to WxH (client px; window WxH, zoom 0.62 pt/px kept) [(drag began) | (drag ended)]          round 8
    resize hwnd=0x... to WxH (client px) dropped: its thread did not pump within 3 s                          round 8
    resize hwnd=0x...: the program maximized this window, so the grip zooms the picture instead               round 8
    refit hwnd=0x... rect={...} zoom=... (size changed; resized with the grip, zoom kept)                      round 8
    grip: resizes the guest window (env.MADEIRA_WINDOWED_RESIZE = 0: ...); a pinch on a title bar zooms ...   round 8, once per session
    grip: resizes the guest window, aspect locked (held a moment first or two fingers: free; ...) | freely (env.MADEIRA_WINDOWED_RESIZE_FREE = 1; ...)   round 9, once per session
    title bar: minimize, maximize (full-screen arrows; ...), close (...) | minimize, fit, maximize, close (env.MADEIRA_WINDOWED_FIT_BUTTON = 1)   round 9, once per session
    resize hwnd=0x...: aspect locked 16:9 (client 1280x720; default | grip held | two fingers) | free (width and height on their own; ...)   round 9, when a drag begins
    resize hwnd=0x... to WxH (client px; window WxH, zoom 0.62 pt/px kept)[ (drag began) | (drag ended)] (aspect locked 16:9) | (free)   round 9
    grip held on hwnd=0x...: the drag that follows resizes width and height freely | keeps the aspect ratio      round 9

and from the driver (round 8):

    [winios] ml1302 resize hwnd=0x... applied (client WxH asked, window WxH with a WxH frame, client now WxH[; the program's size limits][; no sizing border, resized anyway][; WM_ENTERSIZEMOVE][; WM_EXITSIZEMOVE])
    [winios] ml1302 resize hwnd=0x... refused (a child window | minimized | maximized by the program | size out of range | no window rects | SetWindowPos failed | the window is gone; ...)

The rest, all `[windowed] ml1300`:

    minimize hwnd=0x... (to the taskbar; app side, the program is not told)
    restore hwnd=0x... "..." [(SC_RESTORE posted)]
    fullscreen hwnd=0x... on (fit to the screen; the frame stays put, its button shows the shrink arrows in a ring: ...) | off (back to its movable frame)
    taskbar keyboard button ignored: not a touch (event type 3; controller or keyboard focus press)
    search field: first responder refused (not a touch on it; the keyboard stays with the program)
    search field released (tap | click | drag | taskbar | ...): the keyboard goes back to the program
    close hwnd=0x... "..." (WM_SYSCOMMAND SC_CLOSE -> WM_CLOSE)
    posted WM_SYSCOMMAND 0xf060 to hwnd=0x... ok=1
    title hwnd=0x... "..."
    taskbar keyboard | taskbar menu
    maximize hwnd=0x... on (button | maximize button held | title bar double tap | fit button held): the whole screen, no title bar, taskbar hidden; ...
    maximize hwnd=0x... off (restore pill | menu | hidden or minimized | window destroyed | another window maximized): back to its frame
    restore pill ignored: not a touch (...)
    steam: taskbar tile shown only while a Steam window is open (env.MADEIRA_WINDOWED_STEAM = 1 pins it; ...) | pinned (env.MADEIRA_WINDOWED_STEAM = 1) | off (...)   round 7
    steam: tile shown (window hwnd=0x... "..." exe=steamwebhelper, as its program button[, the client's icon | , the window's icon])   round 7
    steam: tile hidden (no Steam window)                                                             round 7
    pill moved to (x,y) pt (kept for this session)                                                   round 7
    hud menu button hidden (a frame is maximized; the restore pill has the menu) | shown             round 7 (Swift)
    hud menu button hidden (windowed mode: the taskbar and the restore pill have the menu) | shown (windowed mode ended) | kept (env.MADEIRA_WINDOWED_HUD_MENU = 1)   round 9 (Swift)
    search: results as chips in the taskbar, right of the field | as chips directly above the keyboard, the taskbar above them | as a list above the taskbar (N pt above the keyboard)   round 7
    steam: launch (already running in this session: hwnd=0x... "..." exe=steam brought to the front)
    steam: button (no Steam window in this session; the app checks the install)
    steam: not available (cancelled at the memory warning)
    steam: launch (started in this session: C:\Program Files (x86)\Steam\steam.exe -nobootstrapperupdate -skipinitialbootstrap -norepairfiles -noverifyfiles -no-cef-sandbox -cef-disable-gpu steam://open/games)      ml1350, ml1370
    steam: install (the full client is not in the prefix[; the steam.exe there is not the 64-bit client])               ml1370
    steam: launch (already starting in this session; its window has not opened yet)                                        ml1350
    steam: install (SteamSetup.exe downloaded | already in drive_c from an earlier download, N bytes, at C:\madeira-games\SteamSetup.exe; started in this session)   ml1350
    steam: not available (it could not start in this session: <reason>; library entry "Steam" for C:\Program Files (x86)\Steam\steam.exe added | already there, started at the next start)
    steam: install (downloading https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe into Application Support/MadeiraSteam)
    steam: install (SteamSetup.exe downloaded, N bytes, kept in Application Support/MadeiraSteam and C:\madeira-games\SteamSetup.exe; library entry "Steam Setup" added; it could not start in this session: <reason>; it starts at the next start)
    steam: not available (Steam's installer: cancelled | the download failed: ... | Valve's server answered N | the download left Valve's servers | an unexpected size (N bytes))
    steam: not available (... library entry could not be made: ...)
    taskbar Steam button ignored: not a touch (...)
    steam: icon from C:\Program Files (x86)\Steam\steam.exe (64x64)                                  round 5
    steam: icon placeholder (Steam is not installed in the prefix; the tile keeps its glyph)         round 5
    steam: icon placeholder (C:\...\steam.exe: no icon | no resources | its icon could not be decoded | ...; the tile keeps its glyph)
    search: open (N windows, M programs and tools[; no Swift bridge: windows only])                 round 5
    search: scan (tools 3, library N, Steam games N, shortcuts N, programs N; N ms)                 round 5 (Swift)
    search: keyboard up (N pt): taskbar and results moved above it | keyboard down (0 pt): taskbar back at the bottom
    search: pick window "..." (hwnd=0x...) | pick tool "Steam" (the Steam tile's action) | pick <tool|library|steam|startmenu|program> "..." ("C:\...\x.exe" args)
    search: launch <kind> "..." -> ok (pid N, parent N) | error (reason)                              round 5 (Swift)
    search: close (picked | tap elsewhere | taskbar button | taskbar Steam button | Go on an empty field | Go with no match | keyboard dismissed | maximize | new session | ...)
    search result ignored: not a touch (...)

The in-session start itself logs `[launch] ml1350 ...` lines (app and ntdll);
see `docs/SESSION_LAUNCH.md`.

ml1370's Steam install and start (Swift, also for the library's Steam entry):

    [steam-install] ml1370 start: manifest https://client-update.akamai.steamstatic.com/steam_client_win64 (a session is running: files only, ... | no session); footprint N MB
    [steam-install] ml1370 manifest version 1788652215: 18 packages, 356.4 MB (smallest first)
    [steam-install] ml1370 part 1 of 18 (resources_hidpi_all, 0.1 MB) downloading | unpacking | done; peak footprint N MB | already done (resumed)
    [steam-install] ml1370 installing 6597 files (client version ...) into C:\Program Files (x86)\Steam
    [steam-install] ml1370 installed in C:\Program Files (x86)\Steam (client version ..., N files from 18 packages, 356.4 MB[, N from an earlier attempt]; registry: left to Steam (...) | install path and client DLL paths written | left as is (...)[; N existing user-data files kept]; peak footprint N MB)
    [steam-install] ml1370 failed at part N of 18 (downloading|unpacking|...): <reason | cancelled | interrupted (app suspended)>[; resumable: N of 18 packages done]
    [steam-install] ml1370 interrupted at part N of 18 (app suspended); tap Install again to resume
    [steam-install] ml1370 resumable install found: N of 18 packages done (client version ...)
    [steam-install] ml1370 not started (cancelled at the confirmation | a Madeira Dock game session is running)
    [steam-install] ml1371 dock repair: offered (Dock reported client sha256=…, not the pinned 71b391fe…)
    [steam-install] ml1371 dock repair: start (the full client is in Dock's folder | Dock's folder is not the pinned build; a session is running: files only | no session: Dock's discovery keys are rewritten)
    [steam-install] ml1371 dock repair: done (moved the full client to C:\Program Files (x86)\Steam Client | removed N entries from Dock's folder; kept [appcache, config, depotcache, steamapps, userdata]; Dock's 3 pinned packages fetched; client sha256=71b391fe… (pinned: match); registry: Dock's discovery keys rewritten | left (...))
    [steam-install] ml1371 dock repair: failed (reason) | not started (declined | a Madeira Dock game is still running)
    [steam-install] ml1371 dock keys: rewritten (were: C:\Program Files (x86)\Steam Client[, missing in user.reg]) | already Dock's[; not written: user.reg]   (every Dock start, before its session)
    [steam-install] ml1371 library entry "...": the full client is in Madeira Dock's folder; offering the Dock repair
    [steam-launch] ml1371 library entry "...": program moved from C:\Program Files (x86)\Steam\steam.exe to C:\Program Files (x86)\Steam Client\steam.exe
    [steam-install] ml1370 library entry "Steam": the full client is not installed; offering the install
    [steam-launch] ml1370 command line (in this session (taskbar) | library entry, a session of its own): "C:\Program Files (x86)\Steam\steam.exe" -nobootstrapperupdate ...
    [steam-launch] ml1370 web helper mode: single-process (in this task)
    [steam-launch] ml1370 web helper switches: --no-sandbox from -no-cef-sandbox, --disable-gpu from -cef-disable-gpu; ntdll's proc-gate appends --single-process and refuses --type= children
    [steam-launch] ml1370 library entry "Steam": switches brought from -no-cef-sandbox -cef-disable-gpu to ...

`[winios] compositor attached inside presentation frame` is followed by the
root line in a windowed session. `[winios] drv_post_mouse hwnd=0x...` (first
40 events) shows the target window instead of `(nil)`.

## Rebuilding

Rounds 2, 3 and 4 touched only the app (`WiniosWindowed.m`, `Winios.m`,
Swift, `Info.plist`, round 4 also the config catalog); no native rebuild.
Round 5 (search launcher, keyboard, Steam icon) is app only too
(`WiniosWindowed.m`, `WindowedMode.swift`); its launches need ml1350's
`libntdll_unix.a` / `libwin32u_unix.a`. In the first version `build/win32u-unix/driver_ios.c` changed (new helpers, mouse routing by
window, the foreground-fix guard): `rebuild-native.sh win32u`, then the app.
The app links against an older `libwin32u_unix.a` too (weak fallbacks in
`WiniosWindowed.m`): frames then have no title, owner or icon, the buttons do
nothing, and input is hit-tested on the guest desktop as before.

## Test

1. madeira.cfg: `windowed = 1`. Start the Desktop entry (or a Madeira Dock game).
2. Expect a black screen with the taskbar pill at the bottom. Each window that
   appears gets a frame with its title; `[windowed] ml1300 add ...` per window.
3. Open a second program (Desktop: from the Start menu in the "explorer" frame;
   or a Dock start, which brings Steam and the game). Drag one frame by its
   title bar over the other; tap the lower one: it comes to the front
   (`activate ... (tap)`), and taps inside it reach it even where the two
   windows overlap on the guest desktop.
4. Open a menu in a program: it appears next to its owner, inside the frame.
5. Minimize: the frame goes, the taskbar button dims; tap the button: it
   returns. Fullscreen: the window fills the screen; the button again restores.
6. Close on a dialog: it closes (`close ...`, `posted WM_SYSCOMMAND 0xf060 ...`).
7. Rotate the device: frames stay on screen, the taskbar re-centres.
8. Remove the line (or `env.MADEIRA_WINDOWED = 0`): the next desktop session
   is the old fitted desktop.

### Round 2 (after the first device run)

The first device run showed a game window at full size at 1 point per pixel
(it was added at its 160x31 placeholder and never refit), drags that left most
of a frame off screen, and a controller that opened the taskbar search field
and keyboard instead of playing. Round 2 changes only `WiniosWindowed.m`,
`Info.plist` and these docs (the app; `libwin32u_unix.a` is unchanged).

1. Start a game that opens a large window through a Dock or Desktop start.
   Expect `add ... rect={-32000,-32000 160x31} zoom=1.00` (or a real rect)
   and then `refit hwnd=... rect={0,0 WxH} zoom=0.xx (first real size; placed
   again)`: the frame fits the screen above the taskbar, title bar on screen.
2. Drag the title bar hard towards each edge: the frame stops with at least
   120 points of its title bar on screen; drag it back.
3. Tap fullscreen: the button turns blue and the title bar dark blue; a drag
   only pulses the button (`move ... ignored: fullscreen`); tap it again to
   get the movable frame back.
4. With a controller connected, play the game's menus: the controller works in
   the game; nothing in the taskbar highlights, no keyboard appears, and no
   `activate ... (search)` or `taskbar keyboard` lines appear unless you touch
   them. Any `... ignored: not a touch` line means a focus press was blocked.
5. Touch the search field: the keyboard comes up (`keyboard focus: elsewhere
   (responder)`); tap inside the game window: `search field released (click)`
   and `keyboard focus: program`.
6. Zoom a frame with the grip, then make the program change its window size
   (a resolution change in its options): `refit ... (the zoom set with the
   grip is kept)`.
7. Rotate the device: `refit ... (screen changed)` for frames you did not zoom.

### Round 3 (maximize; and the desktop game fit without windowed mode)

Windowed mode (`windowed = 1`):

1. Tap the green "+" on the game's title bar (or hold the fit button):
   `maximize hwnd=... on (button)`. The game fills the screen with black bars,
   no title bar, no taskbar; touches and the controller play it; the touch
   controls / menu button of the app stay on top.
2. The pill at the bottom centre dims after about 3 s; touch it (it brightens)
   and tap its window icon: `maximize hwnd=... off (restore pill)`, the frame and
   the taskbar are back where they were. Maximize again, open the in-game menu,
   *Show all windows*: `... off (menu)`.
3. Rotate while maximized: the picture refits to the new screen.

Without windowed mode (`windowed = 0`, the Dock / Steam default), Winios.m
(ml1301, `env.MADEIRA_DESKTOP_GAME_FIT = 0` turns it off): when the guest's
foreground window is a borderless window (`WS_POPUP`, or no full caption) that
presents through Metal, that window's picture is shown fitted to the whole
screen (aspect fit, black bars over the desktop) instead of the whole desktop
being fitted, and touches map into it (a touch on the bars goes to its nearest
edge). The desktop comes back when another window is foreground or the window
is hidden, minimized or destroyed. The foreground is polled 4 times a second
from the event pump (`winios_drv_foreground_window`, `winios_drv_census_owner`,
both existing helpers: no win32u rebuild). Not in this version: the front end's
Fill / Stretch display modes (it always aspect-fits), and a swapchain on a child
window (only the top-level window's own Metal layer is fitted).

4. Start a Dock game with `windowed = 0` whose window is smaller than the
   desktop: `[winios] ml1301 desktop game fit hwnd=0x... 640x480 -> rect (...)
   in WxH pt (env.MADEIRA_DESKTOP_GAME_FIT=0 disables)`; no teal desktop around
   it; taps land where they are drawn.
5. Switch to another window (Alt+Tab in the guest, or a dialog that takes the
   foreground): `[winios] ml1301 desktop game fit hwnd=0x... off (foreground
   changed): the whole desktop again`; back to the game: fitted again.
6. `env.MADEIRA_DESKTOP_GAME_FIT = 0`: no `ml1301` lines, the old desktop fit.

### Round 4 (look; Steam on the taskbar)

The owner's device run of round 3: "windowed mode works as intended now",
with three requests: more room around the search field's magnifier, title
bars translucent and blurred with monochrome buttons ("no Linux GNOME
colours"), and a Steam installer or Steam itself reachable from the windowed
desktop. App only (`WiniosWindowed.m`, `WiniosWindowed.h`,
`WindowedMode.swift`, the config catalog).

1. Start a windowed session. Title bars: dark, translucent (a window behind a
   frame shows blurred through it), a faint line along the top, the title
   centred in white; four grey-white circles with white glyphs, none
   coloured. Tap another frame: its title and buttons brighten, the previous
   one's dim. Tap fit: the button shows the inward arrows in a ring; tap it
   again.
2. Taskbar: the same material; the magnifier clearly inside the search
   field's left end with a gap before "Search"; Steam tile, program icons,
   keyboard and menu evenly spaced. Rotate: still even.
3. Maximize, check the pill has the same material; restore.
4. Tap the Steam tile with no Steam window open: the memory warning appears
   once (`steam: button ...`); Cancel logs `steam: not available (cancelled at
   the memory warning)`; tap again, Continue.
   - Prefix with `steam.exe`: alert "Steam starts in a session of its own",
     `steam: not available (... library entry "Steam" ... added ...)`. Restart
     Madeira: the library has Steam; open it (windowed on): Steam's windows
     come up in frames; tap the Steam tile: `steam: launch (already running
     ...)` and the dot under the tile.
   - Prefix without Steam: a "Downloading Steam's installer" alert counting
     up, then "Steam's installer is ready", `steam: install (SteamSetup.exe
     downloaded, N bytes ...)`. Restart, open Steam Setup from the library.
5. `env.MADEIRA_WINDOWED_STEAM = 0`: no Steam tile, `steam: taskbar button
   hidden (...)`.

(Since ml1350 step 4 starts Steam / the installer in the session; the alerts
above are the fallback. Test with round 5.)

### Round 5 (ml1350: Steam and other programs start in the running session)

The owner: start the Steam client (or its installer) from the taskbar into
the running desktop, like a desktop OS. Needs `libntdll_unix.a` and
`libwin32u_unix.a` rebuilt (`rebuild-native.sh ntdll win32u`) plus the app.
Full steps and log lines: `docs/SESSION_LAUNCH.md` "Test".

1. Windowed desktop session, prefix with Steam: tap the Steam tile, Continue.
   Expect `[launch] ml1350 queued #1`, `starting #1 on tid … (parent
   C:\windows\explorer.exe …, the desktop window's thread)`, services.exe
   first (or "already runs"), `#1: … -> ok (pid …)`, then the app's
   `[launch] ml1350 in-session: "C:\Program Files (x86)\Steam\steam.exe"
   -no-cef-sandbox -cef-disable-gpu -> ok (pid …, parent …)` and
   `steam: launch (started in this session: …)`. Steam's window comes up in
   a frame; the tile gets its dot. A second tap before the window: "Steam is
   starting".
2. Prefix without Steam: the download as in round 4, then SteamSetup.exe
   starts in a frame (`steam: install (… started in this session)`); finish
   the install; tap the tile again: Steam starts.
3. Taskbar menu → Run program…: `C:\windows\system32\winemine.exe` (or any
   GUI program in the prefix): a frame appears; a wrong path shows "It did not
   start: the program file was not found, NTSTATUS c0000034."
4. `env.MADEIRA_SESSION_LAUNCH = 0`: no Run program… entry; the Steam tile
   falls back to the round 4 library entry, its alert naming
   `env.MADEIRA_SESSION_LAUNCH=0`.

### Round 6 (windowed round 5: search launcher, keyboard, Steam icon)

The owner after round 4/ml1350: the search bar did nothing, he wanted to open
Explorer or search apps and games, the keyboard covered the field, and the
Steam tile should show Steam. App only (WiniosWindowed.m, WindowedMode.swift);
the launches use ml1350's in-session launcher (needs its native libraries).

1. Windowed desktop session. Touch the search field: the keyboard comes up and
   the taskbar rides above it (`search: keyboard up (N pt) ...`); the results
   panel sits above the taskbar (`search: open (N windows, M programs and
   tools)`, then `search: scan (tools 3, library N, ...)`). Rows: open
   windows, Explorer, Command Prompt, Steam, library games, Start Menu /
   Desktop shortcuts, programs, with icons.
2. Type part of a game's or program's name: the panel filters live; the first
   row has a faint background. Go: it starts (`search: pick library "..."`,
   `[launch] ml1350 in-session: "C:\..." -> ok (pid ...)`, `search: launch
   library "..." -> ok (...)`); its window comes up in a frame. Keyboard and
   taskbar go back down (`search: keyboard down`, `search: close (picked)`).
3. Search "explorer", pick Explorer: a file browser on C: in a frame. Command
   Prompt: a console window (unproven under this driver; report what happens).
4. Type a window's title and pick it: that frame comes to the front (restored
   if minimized).
5. Open the panel, then touch a window or the black background: it closes
   (`search: close (tap elsewhere)`), the touch reaches the window.
6. Pick something that fails (e.g. a program whose file was removed after the
   scan): an alert with the reason, `search: launch ... -> error (...)`.
7. Steam installed in the prefix: from the first frame of the session the
   tile shows Steam's own icon (`steam: icon from C:\Program Files
   (x86)\Steam\steam.exe (64x64)`). Not installed: the glyph and `steam: icon
   placeholder (Steam is not installed ...)`; install it through the tile;
   within a few seconds of the install finishing (or at the next tap) the tile
   changes to the icon.
8. iPad with a floating keyboard, or a hardware keyboard: the taskbar stays put
   (or lifts only by the shortcut bar's height).

### Round 7 (device feedback on vk6: Steam tile, landscape search, maximize pill)

The owner on vk6: the Steam icon on the taskbar was absurdly large and should
only be there while Steam runs; in landscape the search showed one result at
a time ("the keyboard needs to be smaller"); with a window maximized the round
menu button is redundant with the pill's, and the pill should be draggable.
App only (WiniosWindowed.m, WindowedMode.swift, two lines in Library.swift).

1. Windowed session, no Steam running: no Steam tile on the taskbar
   (`steam: taskbar tile shown only while a Steam window is open ...`). Search
   "steam", pick it: Steam starts as before; when its window appears its
   program button carries Steam's icon at the same size as the other icons,
   with the dot (`steam: tile shown (window hwnd=… exe=…)`). Tap it: front /
   minimize like any program button. Quit Steam: the tile goes (`steam: tile
   hidden (no Steam window)`).
2. `env.MADEIRA_WINDOWED_STEAM = 1`: the pinned tile left of the program
   buttons, its icon 36 points, inside the pill (`steam: taskbar tile pinned`).
3. iPhone in landscape, touch the search field: the keyboard comes up; the
   results are one strip of chips directly above it, the taskbar above the
   strip (`search: results as chips directly above the keyboard, the taskbar
   above them (N pt above the keyboard)`; report N). Swipe the chips sideways;
   type: the strip filters, the first chip is bright with a light edge; the
   Search key starts it; a chip tap picks that one.
4. Where even less room is left (N under 112: a keyboard with its suggestion
   bar, a smaller phone): the taskbar widens, its buttons fade and the chips sit
   inside it right of the field (`... as chips in the taskbar, right of the
   field ...`); closing the search brings the buttons back. Portrait and iPad:
   the list as before. `env.MADEIRA_WINDOWED_CHIPS = 0`: always the list.
5. Maximize a window: the library's round menu button disappears (`hud menu
   button hidden ...`); the pill's menu button opens the menu. Drag the pill
   to a corner (`pill moved to (x,y) pt`); it stays inside the safe area,
   still dims and wakes, its buttons still work. Show all windows: the round
   button comes back (`hud menu button shown`). Maximize again: the pill is
   where it was left. Rotate: it stays on the same side.

### Round 8 (2026-10-13: real resize, grip visibility, smaller title bar)

The owner, after using another windowed app: resize by dragging the
bottom-right corner, width and height on their own; the grip should not stay
on screen forever; smaller title-bar buttons and a slightly smaller title bar.
WiniosWindowed.m (+.h), one line in Winios.m (the client size goes to
`winios_windowed_place`), and a new helper in `build/win32u-unix/driver_ios.c`.

**Resize.** The grip now resizes the guest window, as a desktop window
manager's sizing corner does. While the finger moves, an outline shows the new
size (from the frame's top-left, at the frame's zoom) and the app asks for the
client size that means: the visible size minus the window's non-client frame
(caption, borders, menu bar) as last reported. Requests are coalesced to the
latest size per window, sent at most ten times a second during the drag, once
more when the finger stops for a moment, and once when it lifts. The window's
own thread applies them from its event pump
(`winios_drv_resize_client_if_owner`, ml1302): the client size plus the
window's current frame (window rect minus client rect) becomes the window size
for `SetWindowPos(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)`;
`WM_ENTERSIZEMOVE` goes before the first size of a drag and `WM_EXITSIZEMOVE`
after the last, for programs that rebuild their swapchain only when sizing
ends. A window without `WS_THICKFRAME` is resized too (the user asked for
it); `DefWindowProc` still applies the program's `WM_GETMINMAXINFO` limits
(windows with a sizing border or without `WS_POPUP`), and the driver logs the
client size the window really got. Another Wine thread that pumps first posts
`WM_NULL` to the window (at most every 100 ms) so a thread idle in its message
wait wakes and applies it, as the ml1350 launcher wakes the shell; a request
not applied within 3 s is dropped with a log line. The new size reaches the
frame through the usual size-change path, and the refit keeps the zoom (points
per pixel) for up to 3 s after a grip request: the frame grows or shrinks with
the window, nothing is rescaled, the top-left stays put. The outline goes when
the window reaches the size (or 1.5 s after the finger lifts, when the program
kept another size).

Not resized: fullscreen (fit) and maximized frames (no grip there), and a
window the program maximized itself (`WS_MAXIMIZE`: the guest would refuse;
the grip zooms the picture for that window and says so). The old zoom is still
there: a pinch on the title bar zooms the picture (the guest window keeps its
size; later size changes keep that zoom, as the old grip did), and
`env.MADEIRA_WINDOWED_RESIZE = 0` makes the grip zoom again. A
`libwin32u_unix.a` without the helper: the grip's requests log `not applied:
this libwin32u_unix.a has no ml1302 resize helper` once.

**Grip visibility.** The grip shows only on the active (frontmost) frame and
only for about 2 seconds after a touch on that frame: its title bar, its
buttons, the grip, or the window inside it (a touch mapped through the frame).
Then it fades out; while faded it takes no touches, so the window's own
bottom-right corner is the program's. During a drag it stays.

**Title bar.** 30 points high (was 36), the title in 12-point semibold (was
13), the four buttons 22-point circles (was 28) with 10-point glyphs, 10 points
apart, each with a 32-point square touch target centred on it (neighbouring
targets just meet). The narrowest title bar is 200 points (was 220). The
restore pill and the taskbar are unchanged.

Test (round 8):

1. A program with a resizable window (Notepad, Explorer, Steam): touch the
   frame; the grip appears at the content's bottom-right, fades about 2 s
   later. Touch another frame: the grip moves to that one (only the active
   frame shows it).
2. Drag the grip right only, then down only: the outline follows the finger;
   the window follows a little behind, width and height on their own (`resize
   hwnd=… to WxH (client px; …) (drag began)`, then the driver's `[winios]
   ml1302 resize hwnd=… applied (…)`, last `(drag ended)` with
   `WM_EXITSIZEMOVE`). The text inside reflows; nothing is stretched. The zoom
   in the refit lines stays the same (`refit … (size changed; resized with the
   grip, zoom kept)`).
3. Drag it very small: the program's minimum wins (`client now WxH; the
   program's size limits`); the outline goes 1.5 s after you lift.
4. A dialog without a sizing border (a message box): it resizes anyway (`no
   sizing border, resized anyway`); report how it draws.
5. A game window: drag the grip; report whether the game follows the new size
   (swapchain resize) or keeps rendering at the old one.
6. Pinch the title bar with two fingers: the picture zooms (`scale … (title bar
   pinch; …)`), the guest window keeps its size.
7. `env.MADEIRA_WINDOWED_RESIZE = 0`: the grip zooms as in round 7 (`grip:
   zooms the picture (env.MADEIRA_WINDOWED_RESIZE = 0)` at session start).
8. Title bars: smaller buttons, still easy to hit (try the edges between two
   buttons); on a very narrow window the title still shows a few characters.
   `env.MADEIRA_WINDOWED_HUD_MENU = 1`: the round button stays.

### Round 9 (2026-10-13: device feedback on vk8: aspect-locked resize, slimmer chrome)

The owner on vk8: resizing a window stretched the game ("i want it to and
still be the correct aspect ratio inside"), and a weirdly sized window stayed
stretched when fitted to the screen; the round menu button is redundant with
the taskbar's menu button in windowed mode; the taskbar could be a bit
smaller; the title bar's diagonal-arrows (fit) button does what maximize does.
App only: WiniosWindowed.m, WindowedMode.swift, one comment line in
Library.swift, three catalog lines; no native change.

**Why it stretched.** The frame itself never scales a window unevenly: the
picture inside a frame is the guest window at one zoom (points per pixel) for
both axes (`ww_apply_frame`: the host transform divides out the compositor's
own pixel-to-point factors, so the content area is always the window's
desktop size times one zoom), and fit / maximize take the smaller of the two
screen-to-window ratios and leave black bars (letterbox). What stretched is the
program's picture inside its own window: a game that does not rebuild its
swapchain when its window changes size keeps rendering at the old size, and
that picture is shown across the new client area (as Windows itself would
show it). A window resized to another shape therefore showed the game
stretched, and fit or maximize then kept that shape.

**Aspect-locked resize (default).** A grip drag now keeps the client area's
aspect ratio from the moment the drag began. The new size comes from one
scale for both axes, taken from the axis the finger moved more (relative to
the size at the start); for a ratio with small terms (16:9, 4:3, 16:10) the
client size moves in whole steps of it (16 x 9 pixels for 16:9), so it is
exactly W:H. The outline shows that size; the request names the client size
directly (`resize … (aspect locked 16:9)`). A game that keeps its swapchain
size is then shown at the same proportions, only larger or smaller, and fit /
maximize of that window letterbox it without distortion.

Free resize (round 8: width and height on their own) for that drag: hold the
grip still for about a third of a second before dragging (a light haptic tap,
the grip's lines get bolder), or drag it with two fingers (the grip is small,
so the hold is the practical way). `env.MADEIRA_WINDOWED_RESIZE_FREE = 1`
makes free the default; then the hold or two fingers keep the aspect.
`env.MADEIRA_WINDOWED_RESIZE = 0` still makes the grip zoom the picture.
Program limits (`WM_GETMINMAXINFO`) can still give a size of another shape;
the driver's `ml1302 resize … applied (… client now WxH)` line says so.

**Round menu button.** Hidden for the whole windowed session (the desktop with
frames and while maximized), not only while maximized: the taskbar and the
restore pill both have a menu button. The native side tells the Swift side
when its root is attached and removed (`windowedSessionChanged:`);
`WindowedHUD.hidesMenuButton` is the same flag the library HUD already
observes. `env.MADEIRA_WINDOWED_HUD_MENU = 1` keeps the round button.

**Taskbar a fifth smaller.** Pill 46 points high (was 56); icons, round
buttons and the search field 30 points (was 36; the field is now one item high,
13-point text, 13-point magnifier box); 8 points of padding and gap (was 10);
the field 96 points wide (was 112); icon corners 7.5. Every item stays a
30-point touch target. Restore pill 78 x 40 points with 30-point buttons (was
92 x 46 with 36). Landscape search chips: 30 points high in a 40-point strip
(was 36 / 48), 22-point icons; the thresholds that choose the list or the
chips follow (166 and 94 points above the keyboard, was 176 and 112). Windows
get the 10 points the taskbar gave back.

**Title bar.** Minimize, maximize and close. Maximize is drawn with the
full-screen arrows; tapping it, holding it, or double-tapping the title bar
maximizes (the restore pill brings the windows back). The fit button is gone;
the narrowest title bar is 168 points (was 200 for four buttons: three
22-point buttons, 10 points apart, keep the same title room).
`env.MADEIRA_WINDOWED_FIT_BUTTON = 1` brings back round 8's four buttons
(maximize "+", fit with the arrows, holding fit maximizes, a double tap fits,
the narrowest bar 200).

Test (round 9):

1. A game in a window (one that keeps its render size): touch it, drag the
   grip right: the window grows in both directions at the same proportions
   (`resize hwnd=…: aspect locked 16:9 (client 1280x720; default)`, then
   `resize … to WxH … (aspect locked 16:9)`); the picture is never stretched.
   Drag it down instead: the same. Report the ratio in the lines and whether
   the game's picture still looks right.
2. Hold the grip still a moment (haptic tap, bolder lines, `grip held on
   hwnd=…`), then drag: width and height on their own (`resize hwnd=…: free
   (…; grip held)`). Lift; the next quick drag is aspect-locked again.
3. After a free resize to an odd shape, maximize: the window fills the screen
   with black bars where its shape differs; nothing in the frame stretches it
   (the program's own picture may still be stretched inside its window, as
   step 2 made it).
4. `env.MADEIRA_WINDOWED_RESIZE_FREE = 1`: plain drags are free, held drags
   keep the aspect (session start: `grip: resizes the guest window freely …`).
5. Windowed session in the library: no round menu button on the desktop or
   while maximized (`hud menu button hidden (windowed mode: …)`); the taskbar's
   and the pill's menu buttons open the menu. Leave the session: the round
   button is back on the next non-windowed session (`… shown (windowed mode
   ended)`). `env.MADEIRA_WINDOWED_HUD_MENU = 1`: it stays (`… kept`).
6. The taskbar: smaller, still easy to hit (search field, program icons,
   keyboard, menu); iPhone landscape search shows the chip strip (report the
   `N pt above the keyboard`). The restore pill: smaller, still draggable.
7. Title bars: three buttons (minimize, maximize with the arrows, close);
   double-tap a title bar or hold maximize: maximized (`maximize hwnd=… on
   (title bar double tap | maximize button held)`). `env.MADEIRA_WINDOWED_
   FIT_BUTTON = 1`: four buttons as in round 8.

Not done in round 9: the program's own picture is not letterboxed inside its
client area when its render size and its window disagree (a free resize, or a
program that changes its window size itself): that needs the window's Metal
layer to aspect-fit and the touch and cursor mapping to follow it
(Winios.m / WiniosWindowed.m together), and it would move clicks for programs
that expect Windows' stretch. The aspect lock makes it rare. The aspect is
the client's at the start of each drag; a window whose client size was never
reported uses its whole window rect.

### ml1370 (2026-10-13: Steam from Valve's packages, the full client's switches)

The owner's run of a competing app showed how it gets a working full client:
it installs Valve's `steam_client_win64` packages itself and starts the x64
`steam.exe` with the bootstrapper's no-update / no-verify switches. Ours ran
SteamSetup.exe and then the 32-bit `steam.exe`, whose bootstrapper tried to
update, failed its manifest download, verified files and never showed the main
window. App only (`SteamRuntime.swift`, `WindowedMode.swift`, two lines in
`ContentView.swift`, the config catalog); no native change.

1. Windowed desktop session, prefix without Steam (or with only Madeira Dock's
   components): search "steam", pick it (after the memory warning): "Install
   Steam" (with Dock's files: the note that they are replaced). Install: the
   sheet counts "Downloading part 1 of 18 (…)" up to "Installing N files…";
   the log has `[steam-install] ml1370 manifest version …: 18 packages, …`,
   one `part N of 18 (name, size) downloading | unpacking | done` triple per
   package and `installed in C:\Program Files (x86)\Steam (…)`. Steam then
   starts: `[steam-launch] ml1370 command line (in this session (taskbar)):
   "C:\Program Files (x86)\Steam\steam.exe" -nobootstrapperupdate
   -skipinitialbootstrap -norepairfiles -noverifyfiles -no-cef-sandbox
   -cef-disable-gpu steam://open/games` and `web helper mode: single-process
   (in this task)`. Report whether the bootstrapper window still appears, and
   whether the sign-in or library window opens (Steam's own `logs/
   bootstrap_log.txt` and `logs/webhelper.txt` in the prefix say what the
   bootstrapper did).
2. Cancel during a download: `failed at part N of 18 (downloading):
   cancelled; resumable: K of 18 packages done`, nothing in `C:\Program Files
   (x86)\Steam` changed. Search "steam": the row reads "Resume Steam install
   (K of 18 done)"; pick it: `resumable install found: K of 18 …`, the alert
   "Resume Steam install (K of 18 done)", Resume: parts 1…K log `already done
   (resumed)` and the install continues at part K+1.
2b. (Resume, device feedback 2026-10-13) Start an install, switch to another
   app for a few minutes: either it finished in the background (`installed in
   …`), or `interrupted at part N of 18 (app suspended); tap Install again to
   resume`; back in Madeira the sheet says so; Install again resumes. The
   screen does not auto-lock while the sheet runs.
2c. During a Madeira Dock game: picking Steam shows "Quit the game first"
   (`not started (a Madeira Dock game session is running)`), no sheet.
3. Library interface, no session: the library's "Steam" entry (or one made by
   the fallback): Play brings up the install sheet instead of the starting
   screen when the client is missing; after it finishes the entry starts in a
   session of its own (`command line (library entry, …)`). An entry from round
   4: `switches brought from -no-cef-sandbox -cef-disable-gpu to …`.
4. `env.MADEIRA_STEAM_PACKAGE_INSTALL = 0`: the round 4 path (SteamSetup.exe).
   `env.MADEIRA_STEAM_LAUNCH_FLAGS = 0`: `-no-cef-sandbox -cef-disable-gpu`.
   `env.MADEIRA_STEAM_CEF_GPU = 1`: the switches without `-cef-disable-gpu`.
5. After the install, a Madeira Dock start: it boots as before (ml1371: the
   full client is in `C:\Program Files (x86)\Steam Client`; Dock's folder and
   `client-sha256=71b391fe…` are unchanged).

### ml1371 (2026-10-13: separate folders, Dock repair; device log 102)

1. A prefix where ml1370 installed the full client into Dock's folder: start
   a Dock game: it fails as in log 102 and the alert "Repair Madeira Dock's
   Steam files" comes up over the starting screen (`dock repair: offered
   (…)`). Repair: `dock repair: start (the full client is in Dock's folder; a
   session is running: files only)`, then `done (moved the full client to
   C:\Program Files (x86)\Steam Client; kept […]; … client sha256=71b391fe…
   (pinned: match); registry: …)`. Restart Madeira, start the game again:
   `client-sha256=71b391fe…`, no `session-unsupported-client`.
2. Same, but from the library interface without a session: Settings › Steam ›
   Madeira Dock shows "Repair Madeira Dock's Steam files"; registry: `Dock's
   discovery keys rewritten`.
3. Windowed desktop: search "steam", pick it: the full client starts from
   `C:\Program Files (x86)\Steam Client\steam.exe` (`[steam-launch] ml1370
   command line …`); the library's old "Steam" entry is moved there on its
   next Play (`program moved from …`).
4. Fresh prefix: Install Steam: `installing N files … into C:\Program Files
   (x86)\Steam Client`; Dock's "Download Valve's client components" still works
   afterwards, and the other way round.
