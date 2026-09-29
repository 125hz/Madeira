# Library front end

Madeira starts in a game library. The original diagnostic screen (the
"developer interface") is still there: **Settings › Interface › Use developer
interface** switches to it, and its **Use New Interface** button switches back.
Either change applies at the next start (close Madeira in the app switcher and
open it again).

The code is `app/Madeira/Library.swift` and `app/Madeira/GuestDisplay.swift`
(the virtual monitor and its layout), plus the wiring in `ContentView.swift`
(`launchLibraryEntry`, `runWineFullSequence(profile:)`, `sessionBody`, the
library HUD inside `TouchControlsOverlay`, and `MetalBackedView`'s layout and
touch mapping).

## Adding games

Copy a game's whole folder into **Madeira › wine › drive_c** with the Files app,
tap **+** and choose its `.exe`. Only x86 and x64 PE executables inside drive_c
can be added; the library stores the path relative to drive_c, so a changed
app container path does not break entries. Adding an entry installs nothing.

The library reads the executable's PE imports (and those of the DLLs next to
it, plus bounded scans for dynamically loaded renderer DLL names) to show a
graphics-API badge, and measures the install folder's size. The badge names an
API only when exactly one is found: it describes what the files import, not
which renderer a game picks at run time.

Library data is written atomically to `Documents/madeira-library.json`
(version 1); covers chosen from Files are stored as thumbnails in
`Documents/madeira-art/`. A library file that cannot be read, or that has a
newer version, is left untouched and cannot be overwritten from the UI.
Removing an entry never removes the game's files or saves.

## Library screen

- Layouts: cards, compact cards, list and compact list (one short row per
  game). Sort by last played, name, date added or folder size. Search by title.
- The games section collapses by tapping its title.
- **Desktop** opens the Wine desktop (explorer and services in a virtual
  desktop) with its own profile; its Resolution is the desktop's size.
- The build label (`MadeiraBuild` in Info.plist, else the bundle version) is
  shown under the title and in the developer interface's status row.
- **Settings**: JIT and memory status, Enable JIT, extended logging, pointer
  mode (Absolute, Relative or Touch) and touch sensitivity, **Display** (hold
  the display at its maximum rate, off by default), **Memory & sync** (swap tier
  Off/1/2/4 GB, off by default; Madsync, on by default), the interface
  switch and **Credits** (the last section). Display applies from the next session or FPS limit change; Memory &
  sync after a restart. They write `env.MADEIRA_PROMOTE`, `swap-mb` and
  `inproc-sync` in `Documents/madeira.cfg`, keeping every other line.

## Game details

Tapping a game opens its details page; it stays up until the session's
starting screen takes over (or an error is shown). A profile holds:

- title and cover image;
- **Resolution**: the size of the Windows screen (the virtual monitor) the game
  renders for: 640×480 to 2560×1440, plus **Screen shape**, this device's own
  aspect ratio at 720 lines (for example 1560×720 on a 19.5:9 phone), so a game
  fills the screen without bars. It is exported as the session default
  (`MADEIRA_SCREEN_W/H`, `MADEIRA_SCREEN_SRC=knob`), which win32u reports for
  the session. New entries use 1024×768, the size main uses for every launch;
- **Aspect & scaling**: how that screen is shown. **Fit** letterboxes it,
  **Fill** covers the screen and crops, **Stretch** fills it exactly, **Aspect**
  letterboxes the shape the game actually draws (its back buffer) and **Fill
  height** keeps that shape at full height. Touches are mapped through the same
  rectangle, so input lines up in every mode;
- FPS limit: 60, the display maximum or uncapped (the same presentation
  pacing modes as the FPS pill in the developer interface), and 30 when DXMT
  has its 30 FPS cap (willfaust/dxmt#1; DXMT without it would present mode 3
  uncapped, so the choice is hidden and a saved 30 runs as 60);
- reduced-precision x87: off by default, as in FEX; only an explicit choice
  exports `FEX_X87REDUCEDPRECISION=1`. The library exports no other engine
  switch;
- launch arguments (double-quoted tokens, at most 64 and 4 KB in total);
- performance overlay, live logs and touch controls for the session, with the
  controls' **opacity** and overall **size**. The touch layout itself is saved
  per game from the in-game editor.

A game always starts directly. (The Steam integration adds a "Start with"
choice for Steam games.)

## Sessions

Play applies the profile and runs the same `runWineFullSequence` as the
developer interface's buttons. The game is shown full screen in either
orientation. A starting screen with the game's cover stays until the first
frames arrive (Metal presents or a desktop surface); after 30 seconds it offers
**Show game view**. A row of round glyph-only buttons (their words are
VoiceOver labels) holds **Show live log**, which shows the most recent log lines.

The small menu button (drag to move; it fades after three seconds) opens the
in-game menu:

1. touch controls on/off, their **Controller layout** (the built-in Xbox
   controller, the user's custom layouts, **Create new layout**; remembered per
   game), their **Opacity** and **Size**, **Edit controls**
   (the existing editor) and the **Keyboard** (its own key window, with an
   Esc/Ctrl/Shift/Alt/Tab/Enter/arrow row; modifiers latch);
2. the FPS limit, **Aspect & scaling**, and the mouse and pointer settings;
3. the performance overlay and its fields (FPS, average frame time, memory
   footprint, battery);
4. **Quit game** in red. Quit asks the program to close with Alt+F4 through
   the normal input queue, so it can save; the session ends when it exits.

Changes made in the menu (FPS limit, Aspect & scaling, controls, overlay) are
saved to the game's profile.

**Pointer modes.** Absolute drags the pointer like a trackpad, Relative sends
finger movement as mouse movement (mouse-look), and **Touch** clicks where the
finger is: tap to click, hold or move to drag, a two- or three-finger tap for a
right or middle click, a two-finger drag to scroll. Touch works in direct and
desktop sessions.

When the session ends Madeira returns to the library, restores the touch layout
it had before, and hides the ended session's surfaces. If the session ended by
itself and the program Madeira launched exited with a Windows error status
(for example `0xC0000005`, memory access violation), a message says so. The
status comes from one weak hook in ntdll's common exit wrapper
(`wine_launched_process_did_exit` in `build/ntdll-unix/server_ios.c`), called
only for the session's initial process, the one the app handed to
`__wine_main`; helpers and processes the program starts are never reported.
The hook takes one integer, does not allocate and does not log; the app keeps
only the last error status. No program names are involved.

One Wine session runs per app run: a second one cannot start in the same
process (the wineserver's permanent objects from the first session remain and
the registry initialisation aborts). The library asks to restart Madeira
instead.

## Steam setup

The code is `app/Madeira/Onboarding.swift`. It uses Steam sign-in
(`docs/STEAM_SIGNIN.md`) and Madeira Dock (`docs/MADEIRA_DOCK.md`) through
their public pieces only: `SteamSignInModel`/`SteamSignInView` for signing in
and out (the token stays in sign-in's Keychain store), and
`MadeiraDockModel.prepareClient()`/`MadeiraDockView` for Dock.

**First-run setup.** On a new install the library opens a full-screen setup
once: welcome, **Sign in to Steam**, **Prepare Madeira Dock** (Valve's client
components, about 73 MB, only when Dock is available), done. Every step has
**Set up later**, and the welcome page has **Skip setup**. Finishing or
skipping stores `madeiraOnboardingDone` in the app's UserDefaults, which iOS
removes with the app. Setup opens only when there is something to set up: the
sign-in page needs Steam sign-in or Dock, and without either setup never
opens. It never opens over a running session.

Setup is app UI only. It starts no Wine session, and the component download
runs Dock's own verified download without Wine. It changes no JIT pool, engine
switch or configuration default.

**Settings › Steam** shows the signed-in account with **Sign out of Steam**
(or **Sign in to Steam**), **Madeira Dock** (Dock's sheet, with the last Dock
result under it) and **Run setup again**. A game started from the Dock sheet
here runs as a library session: full-screen view, starting screen, in-game
menu, and the one-session-per-run rule. That session is not added to the
library.

**Steam games in the library** (`app/Madeira/SteamGames.swift`). When Madeira
Dock is available, the library shows a **Steam** section above the games you
added: the games Steam's client has installed in the prefix, exactly as Dock's
own discovery finds them (`appmanifest_<appid>.acf` in `C:\Program Files
(x86)\Steam\steamapps` and the other C: libraries its `libraryfolders.vdf`
lists). The section follows the library's search and collapses like the games
section. Artwork comes from Steam's public store CDN by App ID. A game opens a
sheet with **Play**, which goes through Dock's launch path with Dock's
per-launch pool toggle, as a library session. Play is offered only for a game
Steam marks fully installed, with Valve's client components present and a
Steam sign-in. The section reads install records only; it never writes Steam
files. Controller focus does not reach it yet.

Log tags: `[onboarding]` (`shown reason=… steps=…`, `step=…`, `done`,
`skipped`) and `[steam-games]` (counts and App IDs). No account name, token or
path is logged.

## Controllers

Player 1's controller navigates the library through `GamepadInput`: D-pad or
left stick moves the focus, A opens and plays, B goes back, Y adds a game and
the shoulder buttons switch between Library and Settings. In a session,
Back+Start opens the in-game menu and B closes it. While the library or its
menu owns input, the game sees a connected pad at rest.

## Switches

`env.NAME = 0` in `Documents/madeira.cfg` (or `NAME=0` in `madeira-env.txt`):

| Switch | Default | `0` means |
| --- | --- | --- |
| `MADEIRA_FRONTEND_DEFAULT_NEW` | on | the developer interface is the default |
| `MADEIRA_FRONTEND` | unset | `env.MADEIRA_FRONTEND = 0/1` picks the interface when nothing was chosen in the app |
| `MADEIRA_FRONTEND_CONTROLLER` | on | no controller navigation |
| `MADEIRA_ONE_SESSION_PER_RUN` | on | a second session is attempted anyway |
| `MADEIRA_EXIT_REPORT` | on | no message when a session ends by itself |
| `MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP` | on | the ended desktop's surface is left as it was |
| `MADEIRA_BUILD_LABEL` | on | no build label (the `[build]` log line stays) |
| `MADEIRA_UI_LOG_IDLE` | on | the log view keeps parsing while hidden |
| `MADEIRA_LOG_VIA_STDERR` | on | Swift log lines use their own file handle |
| `MADEIRA_RUNTIME_SETTINGS` | on | no Display and Memory & sync sections in Settings |
| `MADEIRA_SESSION_TOOLS` | on | no Aspect & scaling in the in-game menu, and a session does not save it |
| `MADEIRA_SCREEN_SHAPE_RESOLUTION` | on | no Screen shape resolution choice |
| `MADEIRA_FRONTEND_KEYBOARD` | on | Keyboard opens the game view's own keyboard instead of the key window |
| `MADEIRA_ONBOARDING` | on | first-run setup never opens, and Settings › Steam has no **Run setup again** |

Opt-in (`env.NAME = 1`), off by default:

| Switch | `1` means |
| --- | --- |
| `MADEIRA_PROMOTE` | the display link also holds the panel at its maximum rate in the 60 FPS cap (Settings › Display) |
| `MADEIRA_DEVICE_STATS` | a `[device-load]` line (thermal state, low power, screen capture) every 10 s while Wine runs |

Log tags: `[frontend]`, `[display]`, `[display-shape]`, `[frontend-pointer]`, `[launch-view]`, `[startup-log]`, `[exit-report]`,
`[session-once]`, `[library-surface]`, `[library-metadata]`, `[onboarding]`,
`[frontend-controller]`, `[frontend-keyboard]`, `[device-load]`, `[promote]`.

## Tests

`build/host-tests/check-frontend.py` (profiles incl. resolution and scaling,
the engine switches a profile exports, the 30 FPS fallback, the display layout
math, controller commands, the exit hook, and the presence of the details and
in-game menu options), `build/host-tests/check-runtime-settings.py`
(`MadeiraConfig.set` and the Settings defaults) and
`build/host-tests/check-library-api.py` (renderer detection and the badge).
`build/host-tests/check-onboarding.py` covers Steam setup: the pages with and
without Dock, the done key, the `MADEIRA_ONBOARDING` switch, and the wiring
(no Wine session, no pool or engine switch, sign-in and Dock only through
their public pieces).
`build/host-tests/check-steam-games.py` covers the library's Steam section: Dock's
discovery on a synthetic drive_c laid out as Steam writes it, the section,
search, Play and artwork rules, and that Play uses only Dock's launch path.
