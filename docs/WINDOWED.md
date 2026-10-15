# Windowed mode (ml1300, first version)

Windowed mode shows every top-level Windows window of a desktop session as a
window of its own on the iPhone or iPad screen: a dark translucent (blurred)
title bar with the window's text centred and four round monochrome buttons
(minimize, fit to screen, maximize, close), draggable, brought to the front by
a tap, several of them overlapping at once. A taskbar along the bottom holds a
search field, a pinned Steam button, the running program windows, the keyboard
and the in-game menu. It is off by default; with it off nothing below runs and
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
frame (the guest window keeps its size). When the program moves its own window
(its caption dragged inside the frame, or `SetWindowPos`), the frame follows by
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
  controls, the menu button) are separate windows above and stay reachable.
- *Close* posts `WM_SYSCOMMAND/SC_CLOSE`, which `DefWindowProc` turns into
  `WM_CLOSE`, as the close box of the window's own caption would.

**Taskbar.** A pill along the bottom: a Search field (touch it to type;
filters the window buttons by title or program name; Go brings the first
match to the front), the pinned Steam button (below),
one button per program window (its class icon when the program registered one,
else its program's initial; a dot under it, white for the frontmost window,
the button dimmed when minimized; tap: restore / bring to front / minimize when
already in front), then the keyboard and the in-game menu (both through
`MadeiraWindowedBridge` in `WindowedMode.swift`).

**Look** (round 4). Title bars, the taskbar pill and the maximize pill share
one material (`ww_material`): `UIBlurEffectStyleSystemThinMaterialDark`, a
hairline edge and a faint highlight along the top. Title-bar buttons are
28-point circles of the same neutral translucent white with a white SF Symbol
(`minus`, `arrow.up.left.and.arrow.down.right`, `plus`, `xmark`), touch
targets about 35x36 points; the frontmost frame's buttons and title are
brighter, the others dimmed. No button has a colour; a state (fit to screen)
shows as its glyph and a ring. The title bar is 36 points high. In the
taskbar every item (search field, Steam, program icons, keyboard, menu) is 36
points and they are 10 points apart, 10 points from the pill's ends; the
magnifier sits 11 points inside the search field and 7 points before its
text. On a narrow screen only the program strip shrinks (it scrolls).

**Steam on the taskbar** (round 4; `env.MADEIRA_WINDOWED_STEAM = 0` hides
it). A rounded tile with a monochrome game-controller glyph (a placeholder:
no Valve artwork is in the repository), pinned left of the program buttons
in every windowed session, with a dot under it while a Steam window is open.

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
    prefix: Steam updates its own files when it runs, and Dock refuses a
    client build it has not verified) with Continue / Cancel. Continue is
    remembered.
  - **Steam installed** (`C:\Program Files (x86)\Steam\steam.exe`, or
    `C:\Program Files\Steam\steam.exe`; Dock's client components include a
    `steam.exe`, which then counts): `"…\steam.exe" -no-cef-sandbox
    -cef-disable-gpu` is started in Steam's folder, `services.exe` first when
    none runs in the session (the library's "Start Windows services first").
    No alert: Steam's window appears when it is ready (the bootstrapper's
    update window first). A second tap within 90 s, while no Steam window is
    open yet, only says "Steam is starting".
  - **Not installed**: Valve's installer is downloaded from
    `https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe`
    (HTTPS; redirects only within `*.steamstatic.com`; status 200, 256 KB to
    64 MB, an x86/x64 PE) with a progress alert (Cancel stops it) into
    `Library/Application Support/MadeiraSteam/SteamSetup.exe` (no backup),
    copied to `C:\madeira-games\SteamSetup.exe` and started in the session
    (services first). A copy already in `C:\madeira-games` from an earlier
    download is started without downloading again. Once Steam is installed the
    button starts Steam. Not pinned to a hash: Valve updates the installer.
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
- No files or terminal tool in the taskbar.
- Window icons set with `WM_SETICON` are not read (class icons only, and only
  icons up to 64x64).
- Frames do not resize the guest window; the grip zooms the picture, and
  Maximize only shows it full screen. The guest window itself is never
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
  Valve logo: the tile uses a generic glyph.

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
    maximize hwnd=0x... on (button | fit button held): the whole screen, no title bar, taskbar hidden; ...
    maximize hwnd=0x... off (restore pill | menu | hidden or minimized | window destroyed | another window maximized): back to its frame
    restore pill ignored: not a touch (...)
    steam: taskbar button pinned (env.MADEIRA_WINDOWED_STEAM = 0 hides it) | hidden (...)
    steam: launch (already running in this session: hwnd=0x... "..." exe=steam brought to the front)
    steam: button (no Steam window in this session; the app checks the install)
    steam: not available (cancelled at the memory warning)
    steam: launch (started in this session: C:\Program Files (x86)\Steam\steam.exe -no-cef-sandbox -cef-disable-gpu)      ml1350
    steam: launch (already starting in this session; its window has not opened yet)                                        ml1350
    steam: install (SteamSetup.exe downloaded | already in drive_c from an earlier download, N bytes, at C:\madeira-games\SteamSetup.exe; started in this session)   ml1350
    steam: not available (it could not start in this session: <reason>; library entry "Steam" for C:\Program Files (x86)\Steam\steam.exe added | already there, started at the next start)
    steam: install (downloading https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe into Application Support/MadeiraSteam)
    steam: install (SteamSetup.exe downloaded, N bytes, kept in Application Support/MadeiraSteam and C:\madeira-games\SteamSetup.exe; library entry "Steam Setup" added; it could not start in this session: <reason>; it starts at the next start)
    steam: not available (Steam's installer: cancelled | the download failed: ... | Valve's server answered N | the download left Valve's servers | an unexpected size (N bytes))
    steam: not available (... library entry could not be made: ...)
    taskbar Steam button ignored: not a touch (...)

The in-session start itself logs `[launch] ml1350 ...` lines (app and ntdll);
see `docs/SESSION_LAUNCH.md`.

`[winios] compositor attached inside presentation frame` is followed by the
root line in a windowed session. `[winios] drv_post_mouse hwnd=0x...` (first
40 events) shows the target window instead of `(nil)`.

## Rebuilding

Rounds 2, 3 and 4 touched only the app (`WiniosWindowed.m`, `Winios.m`,
Swift, `Info.plist`, round 4 also the config catalog); no native rebuild. In the first version `build/win32u-unix/driver_ios.c` changed (new helpers, mouse routing by
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
