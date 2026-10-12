# Windowed mode (ml1300, first version)

Windowed mode shows every top-level Windows window of a desktop session as a
window of its own on the iPhone or iPad screen: a dark title bar with the
window's text and three round buttons (minimize, fullscreen / restore, close),
draggable, brought to the front by a tap, several of them overlapping at once.
A taskbar along the bottom lists the running program windows and holds the
keyboard and the in-game menu. It is off by default; with it off nothing
below runs and desktop sessions look exactly as before.

## Turning it on

In `Documents/madeira.cfg` (or a game's own config lines):

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
  same). App-side; the guest window keeps its size.
- *Close* posts `WM_SYSCOMMAND/SC_CLOSE`, which `DefWindowProc` turns into
  `WM_CLOSE`, as the close box of the window's own caption would.

**Taskbar.** A pill along the bottom: a Search field (filters the window
buttons by title or program name; Go brings the first match to the front),
one button per program window (its class icon when the program registered one,
else its program's initial; a dot under it, white for the frontmost window,
the button dimmed when minimized; tap: restore / bring to front / minimize when
already in front), then the keyboard and the in-game menu (both through
`MadeiraWindowedBridge` in `WindowedMode.swift`).

## Not done in this version

- Direct game starts (no Wine desktop) are not windowed.
- No host web view window; the competitor's browser window has no equivalent.
- No files or terminal tool in the taskbar.
- Window icons set with `WM_SETICON` are not read (class icons only, and only
  icons up to 64x64).
- Frames do not resize the guest window; the grip zooms the picture. There is
  no maximize of the guest window (a program's own maximize button still works
  inside the frame).
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
  (its title bar stays reachable).
- The XInput foreground fix is off while windowed mode is on (see above).

## Log lines

All start with `[windowed] ml1300`:

    on (madeira.cfg windowed = 1)                     the switch, once per session
    off (env.MADEIRA_WINDOWED = 1; only desktop sessions are windowed)
    compositor root attached: frames + taskbar ...
    add hwnd=0x... kind=framed title="..." exe=steam class=... rect={x,y wxh} zoom=0.37
    remove hwnd=0x... kind=framed title="..."
    activate hwnd=0x... "..." (tap | drag | taskbar | fullscreen | search | guest)
    activate hwnd=0x... foreground=1 (tap)           the window's thread made it foreground
    move hwnd=0x... to (x,y) pt (app side; the guest window stays at x,y)
    scale hwnd=0x... zoom=0.62 pt/px (the guest window keeps its size)
    minimize hwnd=0x... (to the taskbar; app side, the program is not told)
    restore hwnd=0x... "..." [(SC_RESTORE posted)]
    fullscreen hwnd=0x... on (fit to the screen) | off (back to its frame)
    close hwnd=0x... "..." (WM_SYSCOMMAND SC_CLOSE -> WM_CLOSE)
    posted WM_SYSCOMMAND 0xf060 to hwnd=0x... ok=1
    title hwnd=0x... "..."
    taskbar keyboard | taskbar menu

`[winios] compositor attached inside presentation frame` is followed by the
root line in a windowed session. `[winios] drv_post_mouse hwnd=0x...` (first
40 events) shows the target window instead of `(nil)`.

## Rebuilding

`build/win32u-unix/driver_ios.c` changed (new helpers, mouse routing by
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
