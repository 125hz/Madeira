# In-session launcher (ml1350)

Written 2026-10-13, branch `vulkan-stack`, uncommitted, not device-tested.

The app starts the first Windows program of a session (`WineProcessBridge.m`,
`__wine_main` with `MADEIRA_EXE`/`MADEIRA_ARGS`, usually `explorer.exe /desktop=…`).
Until ml1350 nothing inside a running session accepted a launch request from the app,
so the windowed taskbar's Steam button could only prepare a library entry for the next
start. ml1350 lets the app start any Windows program inside the RUNNING session, the
way a desktop OS starts one from its shell.

## The mechanism

    app (any thread)                              Wine thread of the session
    ----------------                              --------------------------
    MadeiraSession.launch(commandLine:…)          winios_pProcessEvents (Winios.m, every message pump)
      -> madeira_session_launch_request             -> winios_drv_session_launch_pump (driver_ios.c)
         (ntdll process_ios.c: validate,                 owns the desktop window? -> madeira_session_launch_run(1)
          queue, return an id)                           otherwise: post WM_NULL to the desktop window
                                                         (wakes its owner), after 2 s run(0) here
                                                    -> msl_create_process: NtCreateUserProcess on this thread
    completion on the main actor  <-- callback  <--     (what CreateProcessW does), resume, report pid

- **Who starts it.** The thread that owns the desktop window. In a desktop session that is
  explorer's shell thread (`wine/programs/explorer/desktop.c` `manage_desktop`), so the
  new program is **explorer's child**: explorer's window station and desktop, its
  environment, its console state and standard handles, exactly like the program
  `explorer /desktop=… <cmd>` starts itself with `CreateProcessW` at session start. Desktop
  sessions wake every message wait each 16 ms (`message_ios.c` `wait_message`), so the
  shell thread runs the display driver's event hook several times a second even when
  idle. Any other thread that pumps posts `WM_NULL` to the desktop window (at most every
  0.25 s while a request waits) to wake its owner; `DefWindowProc` ignores it.
- **Fallback thread.** A game session has no explorer; its desktop window can have a dead
  or no owner. A request no desktop-owning thread took in 2 s is run by the next Wine
  thread that pumps messages (the game's), and the log says so (`the first Wine thread to
  pump messages`). That thread blocks while the child boots, as it would in its own
  `CreateProcessW`. The program then belongs to the game's session: when the session's
  first program exits, the session (and the program) end, as for any child.
- **How it is started.** `msl_create_process` (process_ios.c) does what kernelbase's
  `CreateProcessW( NULL, cmdline, NULL, NULL, FALSE, 0, NULL, curdir, &zeroed_si, &pi )`
  does (`create_process_params` + `create_nt_process` + the resume):
  normalized `RTL_USER_PROCESS_PARAMETERS` with the image path, the command line, the
  working folder, window title = image path, empty desktop/shell info (the server gives
  the child the parent's desktop), the caller's environment, console flags, process group
  and standard handles (`CONSOLE_HANDLE_ALLOC` when the caller has no console, as kernelbase
  does), `PS_ATTRIBUTE_IMAGE_NAME` = `\??\<path>`, `PS_ATTRIBUTE_CLIENT_ID`, a suspended
  first thread, then `NtResumeThread`. The iOS `NtCreateUserProcess` path is unchanged:
  the process gate, the steamwebhelper single-process rules, `spawn_process` (a new
  pthread pseudo-process), and the 50 ms wait for the child's start-up all apply as for
  every guest `CreateProcess`.
- **One at a time.** Starts are serialized (the child boot already is, ml1213); a request
  waits for the next pump while another start runs.
- **Expiry.** A request nobody took in 30 s is dropped with a reason; the app reports a
  request not taken in 35 s even if no Wine thread ever pumps. When the session's first
  program ends, `WineProcessBridge.m` drops what is still queued
  (`madeira_session_launch_fail_all`), so nothing leaks into the next session.

### Why this and not the alternatives

- **A second `__wine_main` through WineProcessBridge (option B)** is not possible: in this
  one-Mach-task model `__wine_main` initializes the unix side's process-global state
  (config dir, signal setup, the session PEB, `main_argv`, `server_init_process`) once, and
  ends the session when it returns. A parentless second process over an injected
  wineserver socket would boot through `build_initial_params` (the first-process path,
  wineboot included) while the global `peb`/`main_argv` are switched, which
  `wine_ios_child_main` only does safely because the parent sits blocked in its own
  `NtCreateUserProcess`.
- **A Wine-side helper** (a registered "MadeiraLaunch" message handled by explorer with
  `ShellExecuteExW`) needs an explorer.exe rebuild (a `programs/` module; `build-modules.sh`
  only builds `dlls/`), a wine submodule change and a payload channel for the command line
  (a global atom, 255 characters). Explorer's desktop window has no existing "run" path to
  reuse (only the desktop launcher icons' double-click).
- **The unix side calling `NtCreateUserProcess` on an existing Wine thread** needs no PE
  code, no injection and no new module: the same 40 lines of parameter building kernelbase
  does, on a thread that is already inside a syscall with a valid TEB, in the event hook
  that already carries the windowed taskbar's commands (`winios_windowed_pump_wine`). This
  is what ml1350 does. It is also how upstream Wine itself starts explorer: win32u's
  `get_desktop_window` builds the same parameters and calls `NtCreateUserProcess` from the
  unix side (`build/win32u-unix/winstation_ios.c`, the `#if 0` block). That path is disabled
  on iOS with an early note that it failed with c0000135 for explorer at session start;
  since then guest `CreateProcess` children (services.exe, Steam's helpers) boot through the
  same `NtCreateUserProcess`, and ml1350 runs from a fully started session, not from the
  first window's creation. Whether the old failure had another cause is one of the device
  questions below.

## API

C (`app/Madeira/WineProcessBridge.h`, implemented in `build/ntdll-unix/process_ios.c`):

    unsigned int madeira_session_launch_request(const char *cmdline_utf8, const char *cwd_utf8,
                                                unsigned int flags, char *reason, int reason_len);
    void madeira_session_launch_set_callback(madeira_session_launch_cb cb);
    void madeira_session_launch_fail_all(const char *why);

- `cmdline_utf8`: `C:\path\program.exe args` or `"C:\path with spaces\program.exe" args`;
  unquoted paths with spaces work too (the shortest prefix ending in `.exe` at a blank is
  the program, like kernelbase's search). Only full paths (`X:\…`) of `.exe` files; a
  `.bat`, an `.msi`, a bare name or a relative path is refused with a reason. `/` in the
  program path becomes `\`. The child's command line is the program quoted plus the rest
  as typed. Control characters and broken UTF-8 are refused; 4096 UTF-16 units at most.
- `cwd_utf8`: a full Windows folder, or NULL/empty for the program's own folder.
- `flags`: `1` = start `C:\windows\system32\services.exe` first when no `services.exe`
  runs in the session (checked with `SystemProcessInformation`).
- Returns the request id (> 0), or 0 with the reason.
- Callback, on the Wine thread: state 1 when a thread took the request (detail names the
  parent process and which thread), state 2 when done (status = NTSTATUS, 0 = started;
  pid set; detail = "pid …, parent …" or the error text).

Win32u (`build/win32u-unix/driver_ios.c`): `int winios_drv_session_launch_pump(void)`, called
from `Winios.m` `winios_pProcessEvents` (a weak fallback in Winios.m keeps the app linking
against an older `libwin32u_unix.a`; it then starts nothing).

Swift (`app/Madeira/WindowedMode.swift`):

    MadeiraSession.launch(commandLine: String, workingDirectory: String? = nil,
                          servicesFirst: Bool = false,
                          completion: @escaping @MainActor (MadeiraSession.Result) -> Void)
    MadeiraSession.Result { ok, pid, status, reason }
    MadeiraSession.enabled / .available / .unavailableReason
    MadeiraSession.promptRun()          // the in-game menu's "Run program…"

## Users

- **The windowed taskbar's Steam tile** (`WindowedSteam`, docs/WINDOWED.md): starts
  `"…\Steam\steam.exe" -no-cef-sandbox -cef-disable-gpu` (services first), or Valve's
  `C:\madeira-games\SteamSetup.exe` after the download (or the copy an earlier download
  left). On a refused/failed start the round 4 library entry and its "restart Madeira"
  alert are the fallback, with the reason. The memory warning and the download code are
  unchanged.
- **Run program…** in the in-game Session menu (the taskbar's menu button opens it): a
  text prompt for a command line, the last one offered again
  (`UserDefaults madeira.session.run-last`); an error shows its reason. This is the generic
  entry (no per-program buttons). The project's earlier "Custom…" launch popup does not
  exist in this tree (the fork reset to upstream), so this prompt is the reusable path.

## Kill switch

`env.MADEIRA_SESSION_LAUNCH = 0` (madeira.cfg): ntdll refuses every request; the app hides
Run program… and the Steam tile falls back to the library entry, naming the switch in its
alert. Catalog entry: `env.MADEIRA_SESSION_LAUNCH` (Wine core).

## Log lines

ntdll (process_ios.c), Wine thread / app thread:

    [launch] ml1350 queued #N: "C:\…\program.exe" args (in C:\…\; services.exe first)
    [launch] ml1350 starting #N on tid XXXX (parent C:\windows\explorer.exe, pid XXXX, the desktop window's thread | the first Wine thread to pump messages (no desktop-window owner took it in 2 s)): <cmd>
    [launch] ml1350 #N: services.exe already runs in this session
    [launch] ml1350 #N: services.exe first (none ran | the process list could not be read): status XXXXXXXX pid XXXX
    [launch] ml1350 #N: <cmd> -> ok (pid XXXX, parent C:\windows\explorer.exe)
    [launch] ml1350 #N: <cmd> -> error (the program file was not found, NTSTATUS c0000034)
    [launch] ml1350 #N dropped: no Wine thread of the session took it in 30 s
    [launch] ml1350 #N dropped: the session ended before a Wine thread took the request

App (MadeiraSession):

    [launch] ml1350 in-session: <cmd> -> queued #N
    [launch] ml1350 in-session: <cmd> -> starting (parent …, pid …, …)
    [launch] ml1350 in-session: <cmd> -> ok (pid XXXX, parent C:\windows\explorer.exe)
    [launch] ml1350 in-session: <cmd> -> error (reason)

The usual `NtCreateUserProcess: image=… cmdline=…` and `spawn_process: creating child
thread for …` lines follow the `starting` line; `[proc-gate] REFUSING …` there means the
process gate refused the program (`refused (Madeira's process gate, or no access to the
file)`).

Error texts: the program file was not found (c0000034), a folder in the program's path was
not found (c000003a), the program path is not valid, refused (c0000022), the file is not a
Windows program (c000012f), the program is not for a machine this session runs (c000007b),
a 16-bit or DOS program, a DLL the program needs is missing (c0000135), out of memory, the
path is too long; anything else as `NTSTATUS xxxxxxxx`. Before queueing: the command line
must start with a program path ending in .exe …, the program needs a full Windows path …,
a quote is not closed, starting programs in a running session is off
(env.MADEIRA_SESSION_LAUNCH=0), no Windows session is running.

## What is verified, what is not

Compiled in WSL for iOS (`rebuild-native.sh ntdll win32u`; both archives export the new
symbols, no diagnostics; a strict `-Werror=implicit-function-declaration` compile of the
new code is clean). `Winios.m` and `WineProcessBridge.m` pass `clang -fsyntax-only` (iOS 18
SDK); `WindowedMode.swift` with the menu entry type-checks against the iOS 26.5 SDK with the
real `WineProcessBridge.h` imported and stubs for the library model (also under
`-strict-concurrency=complete`).

Not verified (needs a device run, docs/WINDOWED.md round 5):
- that explorer's shell thread reaches the event hook while idle in its `GetMessage` wait
  (desktop sessions' 16 ms slices say it does) and takes the request first;
- that `NtCreateUserProcess` from inside the event hook boots Steam's bootstrapper the way
  the explorer-started program does (same path, different caller frame); a c0000135
  ("a DLL the program needs is missing") here would point back at the old note on
  win32u's disabled unix-side explorer start;
- the game-session fallback (the request run on a game's thread);
- services.exe detection through `SystemProcessInformation` on this port;
- SteamSetup.exe (a 32-bit installer) started in a running session that already has
  64-bit processes (the WoW64 guest window path applies as for any 32-bit child).

## ml1351: launched children that crash-looped (device logs 81-83)

Written 2026-10-13, uncommitted, ntdll compiled in WSL, not device-tested.

Logs 81, 82 and 83 (a Dock session with a 32-bit game running, then the taskbar's Steam
tile) show the launcher working as designed: `services.exe first (none ran): status
00000000` and `steam.exe … -> ok (pid …, parent explorer.exe)`. Both children then fault at
their first instruction forever (`BUS EXEC in JIT .data`, `[exc-disp] raise … p0=8
(EXECUTE)`, `kr=2(PROTECTION_FAILURE) entryprot=3 nowprot=3`), one thread at a full core.

**The launcher was not the cause.** A diff of the launched path against a guest
`CreateProcessW`:
- `msl_create_process`'s `RTL_USER_PROCESS_PARAMETERS` match kernelbase's
  `create_process_params` + `RtlCreateProcessParametersEx` field for field (ConsoleFlags,
  ProcessGroupId, ConsoleHandle with the `CONSOLE_HANDLE_ALLOC` fallback, std handles with
  `INVALID_HANDLE_VALUE` → NULL, environment, title). A stack block is fine:
  `NtCreateUserProcess` serialises it into the server request (`create_startup_info`); the
  child reads its own copy from the server and never touches the parent's memory (Wine's
  own `run_wineboot` does the same from the unix side). No guest-memory block is needed.
- From `NtCreateUserProcess` on the path is the normal one: `new_process`, `new_thread`,
  `spawn_process`, `wine_ios_child_main` (PEB cloned from the initial one, `[proc-ident]`,
  `[init-peb]`, child ntdll copy). The child PEBs in the app heap (0x11175c000) are normal:
  dockhost's is 0x1054c8000.
- `EcCodeBitMap = 0x0` is correct for these children. services.exe is aarch64 (`Machine=0xaa64`,
  "NOT setting cpu_area") and steam.exe is i386 (WoW64); only an x64 image in an aarch64
  session loads the ARM64EC ntdll and gets the bitmap (`[ec-child-ntdll]`, as dockhost does).
- The real fault: both children's ntdll copies landed on JIT-pool pages whose max
  protection had already lost EXECUTE: `[pool-poison] HANDED OUT NON-EXEC off=0xa854000 …
  prot=3 max=3`, `[copy-verify] ntdll.dll: 29 of 29 .text pages BORN NON-EXEC`. The pool tail
  from offset 0xa848000 had been unusable since the game's 32-bit DRM loader image
  (`[jit-pool] image 0x7903ff0000+0x54000 (?)`, a manually mapped DLL) was copied: its
  writable section runs past the bytes copied, and the RW `mprotect` of that section reached
  the next pool pages, which on blessed pool memory removes EXECUTE for good. Every log in
  70-83 that has `[pool-poison]` has its first poisoned hand-out at exactly 0xa848000. Any process
  started after that point would die the same way, whoever starts it; the launcher was just
  the first to start one.
- Log 84 (no game first): the launched steam.exe boots through its whole import list
  (kernel32 … mswsock, 30+ modules) with executable pool copies, then dies on a guest read
  of uncommitted memory (`0x7924f50aee`, guest `0x24f50aee`, "NO wine view"; guest eip
  0x7BB9FF61 in gdi32's range) — a separate WoW64 issue, not a set-up difference.

**Fix (virtual_ios.c, port of the pre-reset ml1970 guard):**
- `[pool-guard] ml1351`: the image copy's and the child-ntdll copy's writable-section
  `mprotect` never reaches past the copy's own pages. `env.MADEIRA_POOL_SECTION_CLAMP = 0`
  restores the unclamped range.
- `[pool-quarantine] ml1351`: a pool range handed out non-executable is left allocated and
  the next one taken (16 tries / 64 MB per session at most). `env.MADEIRA_POOL_QUARANTINE = 0`
  restores report-only.

No explorer.exe/PE-side change: the unix-side `NtCreateUserProcess` is equivalent to the
guest `CreateProcessW`, so the custom-message path through explorer's desktop window would
start the same children on the same poisoned pool.

**New log line** (process_ios.c `madeira_session_launch_child_started`, called from
`server_init_process_done` on the child's first thread just before it starts; launched
children always, the first 8 ordinary children of a session as the comparison):

    [launch] ml1351 launch #N first thread pid PPPP tid TTTT: peb=0x… (registered) machine=aa64 EcCodeBitMap=0x0 (none, as expected for this machine) start=0x71ffd5837c -> 0x15… prot=5/7 (executable) => same layout as a normal child
    [launch] ml1351 spawned first thread pid … (same fields, an ordinary child)

`registered` = the PEB is in the per-process identity table ([proc-ident]); EcCodeBitMap is
expected exactly when the machine is 8664; `start` is the process's LdrInitializeThunk and
its JIT-pool copy, whose page must keep EXECUTE in its max protection. Anything else prints
`NOT REGISTERED` / `MISSING` / `UNEXPECTED` / `NOT EXECUTABLE` and `DIFFERS from a normal
child`.

Not verified: no device run. The next log should show `[pool-guard] ml1351 … runs past the
0x…-byte pool copy` when the game's DRM image loads, no `[pool-poison]` from 0xa848000
on, and `[launch] ml1351 launch #1 … => same layout as a normal child` for services.exe and
steam.exe. Still open: the core-burning retry loop on an unrecoverable NOEXEC fault
(generic fault path), and log 84's steam.exe read fault.

## ml1352: 32-bit Steam client launched into a plain desktop session (log 84)

Log 84 (explorer desktop, no game, no Dock): the launched 32-bit steam.exe loads its imports,
then reads unmapped memory at guest 0x24F50AEE from 0x7BB9FF61, first inside window
callbacks (`dispatch_user_callback ignoring exception c0000005`, many times) and then
fatally after `SetCurrentProcessExplicitAppUserModelID`. Symbolised against the unstripped
i386 build (`wine/build-i386/dlls/gdi32/i386-windows/gdi32.dll`, .text identical to the
shipped one; image base 0x10000000, loaded at 0x7BB80000): `get_gdi_client_ptr` →
`handle_entry` (objects.c:92/121), the read of `gdi_shared->Handles[idx].Type`. The table
address was the session's HOST table 0x70_24f50000 truncated to 32 bits (index 116 → +0xae0).

Cause: win32u backs the GDI handle table with a section (so each 32-bit process can map a
view inside its guest window) only when the session is armed for 32-bit code when win32u
starts. Dock sessions force it (`ContentView.swift`, `MADEIRA_GDI_SHARED_SECTION=1`), which is
why the Dock path never hit this; a plain desktop session starts 64-bit, keeps a private table,
and a 32-bit program started later (by the launcher, or by any 64-bit program) inherits the
cloned host pointer in its PEB. Not a Valve-specific path: any 32-bit GDI user does this.

Fix (`wine/dlls/win32u/gdiobj.c`, `win32u_private.h`): the section-backed table is the default
in every session (`[gdi-shared] ml1352 section-backed table by default (session armed … : 0|1)`);
`env.MADEIRA_GDI_SECTION_ALWAYS = 0` restores "only when armed"; `env.MADEIRA_GDI_SHARED_SECTION`
still forces either way. A 32-bit process that still meets a private table logs once
`[gdi-shared] ml1352 peb=… pid=…: 32-bit process, but this session's GDI table … is private host
memory …`. Expected next log: `[gdi-shared] peb=… pid=… wow=1 master=… guest-view=…` for steam.exe.

## ml1353: a dead process no longer heats the device

`signal_arm64_ios.c` bus_handler: an EXECUTE fault inside the JIT pool on a page whose max
protection has no EXECUTE can never succeed; when the dispatcher itself lives on such pages
(the process's own ntdll copy) delivery faults again forever. After 32 consecutive faults of one
thread at one pc there, the thread runs `abort_process(c0000005)` (this pseudo-process only):
`[pool] ml1353 giving up: pid … tid … pc=… (pool+0x…) faulted 32 times in a row on a page whose max
protection has no EXECUTE (prot=3/3); ending this process …`. `env.MADEIRA_POOL_NOEXEC_GIVEUP = 0`
keeps the endless retry.

## Files

`build/ntdll-unix/process_ios.c` (queue, parsing, `msl_create_process`),
`build/win32u-unix/driver_ios.c` (`winios_drv_session_launch_pump`),
`app/Madeira/Winios/Winios.m` (the call in `winios_pProcessEvents`),
`app/Madeira/WineProcessBridge.h` / `.m` (C API, drop at session end),
`app/Madeira/WindowedMode.swift` (`MadeiraSession`, the Steam tile),
`app/Madeira/Library.swift` (Run program… in the Session menu),
`app/Madeira/ConfigCatalog.generated.swift` (the switch), docs/WINDOWED.md.
