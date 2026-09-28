# Madeira Dock

Madeira Dock starts a Steam game that Steam's client has installed in the
prefix, through **Valve's genuine Windows Steam client**, without the Steam
desktop window, its Chromium web helper or its library UI.

It is a small headless Windows program (`dockhost.exe`). Inside Madeira's Wine
session it loads the client's own libraries, signs in with the user's own
Steam sign-in and asks the client to start the game with Valve's own
`LaunchApp`. Valve's client performs the online authentication and the licence
check. The game, its Steam API calls and any DRM run exactly as Valve ships
them.

## What it is not

- Not a Steam emulator, not a DRM bypass, no ticket forging, no game patches.
  Without Valve accepting the sign-in and confirming the licence, the game does
  not start, and there is no fallback that starts it anyway.
- Not a Valve SDK use. Dock drives **undocumented internal interfaces** of
  Valve's client DLL (`steamclient64.dll`). That is fragile by nature, so Dock
  only drives client builds it has been verified against: it hashes the DLL
  (SHA-256) and checks the exact method addresses it calls. Any other build
  **fails closed** before sign-in, with report code 30 and the client's
  fingerprint in the log. Two client builds are supported at the pinned
  commit; see `research/madeira-dock/docs/CLIENT_LAYOUTS.md`.
- No Valve binaries, game content, cached login or token is bundled or
  committed.

## Source and licence

- Source: the `research/madeira-dock` submodule
  (`https://github.com/125hz/madeira-dock`, pinned at `412063f`), about 1,700 lines of
  C. Copyright 2026 125hz, **GPL-3.0-or-later with the Madeira
  Converter Exception** (the owner open-sourced it on 2026-09-27; it used to
  be a closed executable).
- Research references: OpenSteamworks (MIT) and Valve's public Steamworks
  documentation and headers were consulted. According to the Dock repository's
  `THIRD-PARTY-NOTICES.md`, no code was copied from them.
- Build: `build/madeira-dock/build.sh` cross-compiles it with llvm-mingw
  (x86-64 PE, static runtime, stripped, reproducible: no PE timestamp) and
  stages two files in the bundle:
  - `app/Madeira/arm64ec-windows/dockhost.exe`
  - `app/Madeira/arm64ec-windows/dock-notices.txt` (Dock's licence, the
    exception, the GPL text and the LLVM/MinGW-w64 runtime notices).

  Both are build outputs and are gitignored. `--check` also runs Dock's own
  unit tests. Without a built `dockhost.exe`, Madeira shows no Dock button.

## Using it

The developer interface has a **Madeira Dock** button (when `dockhost.exe`
is built; `env.MADEIRA_DOCK = 0` hides it). The sheet has:

1. **Steam account.** Sign in with Madeira's Steam sign-in
   (`docs/STEAM_SIGNIN.md`).
2. **Steam client.** "Download Valve's client components" fetches three
   pinned packages (about 73 MB) from Valve's update CDN
   (`client-update.akamai.steamstatic.com`, HTTPS, redirects must stay on that
   host). Each package is checked against a pinned size and SHA-256 sum before
   it is read. The ZIP reader rejects traversal, symlinks, duplicates,
   encryption and ZIP64. The unpacked `steamclient64.dll` must be the pinned
   build the Dock host supports.

   The files go to `C:\Program Files (x86)\Steam`, and Steam's discovery
   registry keys (install path, client DLL paths; nothing account-related)
   are written. This happens without starting Wine. Existing Steam files are
   kept; conflicting ones stop the setup.
3. **Installed games.** Read from Steam's own
   `steamapps/appmanifest_<appid>.acf` files in the client's library and in
   the other C: libraries its `libraryfolders.vdf` lists. Only games Steam
   marks fully installed can be started.

   Dock does not install games. They must already be installed in the prefix
   by Steam's client, for example with the desktop client, or copied together
   with their app manifest. Valve's client may still update a game's content
   when Dock starts it, and Dock waits for that.
4. **Smaller JIT pool (512 MB) for this launch.** Opt-in. The toggle starts
   from `env.MADEIRA_DOCK_COMPACT_POOL` and is off unless that is `1`.

Tap a game. Dock is started with Steam's default launch option only; custom
arguments are not supported.

## How a launch works

1. Madeira checks: JIT is enabled, no session has run in this app run,
   `dockhost.exe` is bundled, the client DLL exists, the game is fully
   installed and its folder exists, and a sign-in is stored.
2. **One-use sign-in transfer.** `SteamSignIn.credentialsForDock()` supplies
   the account name and refresh token from the Keychain. Madeira writes them,
   with the account's SteamID (taken from the token's subject claim to select
   the account, not trusted as identity) and the App ID, into a bounded file
   (`MDOCK001`: 8-byte magic, u64 SteamID, u32 App ID, u16 lengths, account,
   token). The file is:
   - in `Application Support/MadeiraDock/launch.auth`, with complete file
     protection, mode 0600, excluded from backups;
   - created exclusively (`O_EXCL | O_NOFOLLOW`);
   - reached by the guest only through its path, in `MADEIRA_DOCK_AUTH_FILE`
     via Wine's `\\?\unix` namespace (the prefix has no guaranteed Z:).

   Dock opens it exclusively with delete-on-close, clears its buffers and
   hands the token to the verified client's own sign-in method. Madeira
   removes any leftover when the result is reported, on sign-out and at the
   next app start. No token, account name or path is logged.
3. The host's inputs go in its environment: `MADEIRA_STEAM_HOST_*` gates,
   App ID, client folder, the expected install folder (Valve's client must
   resolve the game to exactly that folder) and the report path. The
   cached-account variables are always cleared. The launch also sets the
   engine's opt-in image-retire switch, `MADEIRA_JIT_IMAGE_RETIRE=1`, for
   this session only and logs `[dock-launch] image-retire=1` (see Known
   risks). Other sessions keep the engine default (off).
4. The session is the normal Wine session: `explorer.exe
   /desktop=madeira,<W>x<H> C:\windows\system32\dockhost.exe`. The size comes
   from `desktop-size` in madeira.cfg, else 1280x720.
5. **The report.** Dock writes numeric stages to `C:\madeira-dock.txt`.
   Madeira reads only whitelisted numeric fields and the 64-hex client
   fingerprint (never other guest text), logs changes as `[dock-report]`,
   and turns the final `probe-result` into a message. Covered: unsupported
   client build, no licence, a bad transfer, Valve's own launch refusal codes,
   and per-user executable preparation errors.

If the install record lists per-user custom executables (`CheckGuid`), Dock
asks Valve's client to prepare them before launching. `env.MADEIRA_DOCK_CEG = 0`
never asks. The preparation is Valve's; Dock does not touch the files.

## Switches

`env.NAME = value` in `Documents/madeira.cfg`.

| Switch | Default | Effect |
|---|---|---|
| `MADEIRA_DOCK` | on | `0` hides the Dock button |
| `MADEIRA_DOCK_COMPACT_POOL` | **off** | `1` starts the sheet's "Smaller JIT pool" toggle on |
| `MADEIRA_DOCK_CEG` | on | `0`: never ask the client to prepare per-user executables |
| `MADEIRA_DOCK_IMAGE_RETIRE` | on | `0`: a Dock launch does not turn on the engine's `MADEIRA_JIT_IMAGE_RETIRE` (an explicit `env.MADEIRA_JIT_IMAGE_RETIRE` still wins) |
| `MADEIRA_DOCK_CLIENT_202601` | on | read by the host: `0` disables its January 2026 client adapter |
| `MADEIRA_DOCK_HANDOFF_DIAGNOSTICS` | on | read by the host: `0` drops its numeric transfer diagnostics |

## 64-bit and runtime impact

With no Dock launch, nothing changes. The JIT pool stays 896 MB (or
madeira.cfg `pool`); no engine, Wine, FEX or DXMT file is touched. The compact
pool applies only to a Dock launch whose toggle is on, only for that launch,
and an explicit madeira.cfg `pool` still wins. Dock's host is itself an x64
program. A Dock launch also sets `MADEIRA_JIT_IMAGE_RETIRE=1`, the engine's
opt-in image-retire switch (its own engine PR), for that session only; no
other session sets it, and an engine without the switch ignores it.

## Not included (compared with the fork)

- **Game installation and library integration.** The fork's Steam library and
  depot downloads were rejected with #35 and are not coming back here. When
  the new front end lands, Dock can be offered from it.
- **One-time installers.** Valve's client does not run a game's install
  scripts on this route. The fork ran them from a batch before the host, and
  by default skipped installers it recognised by file name. That name list is
  gone (no program-name rules). The batch also needs `reg.exe`, which this
  bundle does not ship. A later change can offer it as an explicit per-launch
  choice.
- **Automatic session end and the exit-status hook.** These need the ntdll
  program start/exit hooks from the front-end PR. Here, the result comes from
  the report file, and the session ends as other developer-interface
  sessions do.
- Heap, D3D9-census and pool-pressure defaults for Dock sessions (fork engine
  policies).

## Status and known risks

- On the owner's devices (fork builds), Dock launches reached gameplay: the
  host reported an authenticated online session and the app in the account's
  licences. Clean-prefix component setup and broad title compatibility are
  less proven.
- **This extraction has not been run on a device.**
- The fork's device runs depended on an engine fix: retiring an unloaded
  image's translations before its address is reused (fork ml1850). Without
  it, one device run crashed while Valve's client loaded its DLLs, before any
  sign-in: a DLL mapped at the address of a DLL unloaded moments before ran
  the unloaded DLL's translated code. The fix is its own engine PR, off by
  default, behind `MADEIRA_JIT_IMAGE_RETIRE=1`. Dock launches set that switch
  for their session only. This app side builds and runs without the engine
  PR; the variable is then ignored and Dock may hit that crash.
- Valve can change the client at any time. A new client build needs a newly
  verified adapter in the Dock repository and new pins in `SteamRuntime.swift`.
  Until then, Dock refuses the new build.

## Tests

On a Linux host with `swiftc`, `cc` and `python3`; no Steam, Wine or
credentials:

- `check-dock-contract.py`:
  - static rules: no program-name lists, no credential in a log line, compact
    pool off by default and Dock-only, madeira.cfg `pool` wins, the
    image-retire switch set only in the Dock launch environment, no built
    binary tracked, submodule pin;
  - compiled production Swift: pool policy, manifest and library discovery,
    validation, the transfer envelope and subject, the host environment
    (image retire on, and off with `MADEIRA_DOCK_IMAGE_RETIRE=0`), and the
    one-launch request.
- `check-dock-report.py`: the report parser, its messages, rejection of
  private and malformed fields, and that every report round the pinned host
  writes is accepted.
- `check-dock-path.py`: the transfer path through Wine's own path resolver
  (`WINE_FILE_C` can point at `dlls/ntdll/unix/file.c` when the wine
  submodule is not checked out).
- `check-dock-components.py`: the component ZIP reader and registry writer on
  synthetic archives, and the pins (one HTTPS host, well-formed sums, a
  client hash the pinned host supports).
- `build/madeira-dock/build.sh --check`: Dock's own ASan/UBSan unit tests
  (transfer parsing, 2,000 malformed inputs, client selection, launch-result
  and callback bounds).
