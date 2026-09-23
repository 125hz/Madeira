# Steam in the optional front end

Since ml1310 the optional library signs in to Steam natively. It shows the
account's Windows games, and downloads and installs them without the Windows
desktop. The Windows Steam client (below) remains available for games that need
Steam running and for anything the native path does not cover.

## Native Steam library (ml1310)

**Credit:** the Steam protocol, sign-in, owned-library, manifest, chunk
decryption and depot-download code under `app/Madeira/SwiftSteam/` comes from
[Jfishin](https://github.com/Jfishin)'s Madeira Steam client and is published
here with his permission. Each derived file carries an attribution header.

What Madeira changed:

- The download orchestration and the password + Steam Guard flow were
  substantially rewritten.
- New here: the shared authentication transport, logging, zip-chunk decoder,
  account/download model and library views.
- Not included from the original: its Steam Cloud, launch-emulator and
  DRM-related components.

Enable the optional library (`MADEIRA_FRONTEND=1` in `madeira-frontend.txt`).
The Library tab now has two sections:

- **Steam**: installed Steam games, downloads in progress, and a collapsible
  **Not installed** list of every owned game that has a Windows build.
- **Other games**: everything added with **+** from a folder copied into
  `wine/drive_c` with the Files app. Artwork matching and profiles work as before.

### Sign in

Tap **Sign in to Steam** in the Steam section (or Settings › Steam).

- **Password** (default on iPhone): use the Steam *account name*, then either
  type the Steam Guard code (Steam app or email) or approve the sign-in in the
  Steam app. Both options are offered at once when Steam allows both.
- **QR code** (default on iPad): scan it with the Steam app on another device.
  **Open in the Steam app on this device** passes the same sign-in link to the
  Steam app installed on this device. That same-device hand-off has not been
  tested yet.

Madeira talks to Steam's authentication service directly. The password is
encrypted with Steam's RSA key before it leaves the device and is never stored.
The resulting sign-in token is kept in the iOS Keychain (this device only,
available while unlocked) under the service `madeira.steam.tokens`. **Sign out**
in Settings removes it. Installed games stay. An expired or revoked token signs
the app out with a message.

### Install and play

Tap a game under **Not installed** and choose **Install**. Files come directly
from Steam's content servers with the signed-in account; Steam only issues depot
keys for games the account owns. Nothing is patched or altered.

- Destination: `C:\Program Files (x86)\Steam\steamapps\common\<folder>`, plus a
  normal `appmanifest_<appid>.acf`, so a Windows Steam client installed later
  recognizes the game.
- Windows depots only: common content, English language content, and 64-bit
  (or 32-bit when that is all an app publishes). DLC depots, low-violence
  alternates and shared redistributables are skipped.
- Progress shows size, speed and time left. **Pause**, **Resume** and
  **Cancel** (deletes partial files of a first install) are available.
- Downloads resume where they stopped: completed chunks are journaled in
  `steamapps/downloading/<appid>`. Existing files are also checked chunk by
  chunk (SHA-1), so updates only fetch changed data.
- Downloads pause automatically while a game runs and continue afterwards.
  Keep Madeira in the foreground while downloading; iOS suspends background apps.

When the download finishes, the game appears under **Steam** with its artwork.
The program to start comes from Steam's own launch entries, or from the most
likely executable in the folder. Game details › Steam lets you:

- **Start with: The game** (default) runs the executable directly. A
  `steam_appid.txt` (Valve's documented developer file) is written next to it.
  This works for games that do not need Steam running.
- **Start with: Windows Steam client** runs `steam.exe -applaunch <appid>` in
  the virtual desktop. It needs the Windows client installed (Settings ›
  Windows Steam client) and signed in to the same account. This is the only
  supported route for games that require Steam or use Steam DRM.
- **Program** picks another executable from the install.
- **Update available** appears when Steam publishes a newer build.
- **Uninstall** deletes the game's files and manifest.

### What this does not do

- No Steam emulator, launch loader, DRM unwrapping, app-ticket injection or
  other circumvention is included. A game that refuses to start without Steam
  needs the Windows Steam client route. That route depends on the client
  itself working on device, which is still unproven (see the ml1260–ml1300
  sections below).
- No Steam Cloud synchronization, DLC or beta-branch selection yet.
- Owned games are read from the account's licenses. Family-shared libraries and
  free weekends may appear; Steam still decides download access.

### Switches (madeira-env.txt)

| Setting | Effect |
| --- | --- |
| `MADEIRA_STEAM_NATIVE=0` | Hide native sign-in, the owned library and downloads; the ml1260 Steam button returns. Installed games still launch. |
| `MADEIRA_LIBRARY_SECTIONS=0` | Keep the native features but use the single combined grid. |
| `MADEIRA_STEAM_PAUSE_FOR_SESSION=0` | Let downloads continue while a game runs. |
| `MADEIRA_STEAM_APPID_FILE=0` | Do not write `steam_appid.txt` next to newly installed executables. |
| `MADEIRA_STEAM_TRACE=1` | Protocol-level `[steam-trace]` lines (no credentials or payloads). |

Always-on log tags (no account names, tokens or game titles):
`[steam-account] ml1310` (start, sign-in method/result, sign-out, rejected token),
`[steam-library] ml1310` (owned and Windows-installable counts),
`[steam-depot] ml1310` (install begin/complete/pause/fail by App ID, uninstall),
`[steam-play] ml1310` (App ID, direct/client route), `[library-sections] ml1310`.

### Download fixes (ml1320)

Device logs 154/155: sign-in and the owned library worked, but installs
stopped after a few MB.

- **TLS error `-1200` (proven cause).** Steam's content-server directory
  includes CDN servers marked `https_support: "unavailable"`. The ml1310 host
  filter accepted any `*.steamcontent.com` name, so HTTPS requests could reach
  HTTP-only servers. Servers are now filtered by `https_support`, proxy-only
  entries and servers limited to other apps are skipped, and a server that
  keeps failing moves to the back of every chunk's rotation. Each chunk tries
  up to five of six servers.
- **"Failed to decompress chunk data" (likely cause; the log did not name the
  format).** Steam chunks come in three encodings: VZstd, VZip (LZMA) and plain
  PKZip, which older content still uses. Valve's reference client falls back
  to PKZip; the port did not support it. PKZip chunks (deflate or stored, with
  or without a data descriptor) are now decoded. Failures name the format, for
  example `decode-vzip` or `decode-zip-3`.
- Steam log lines (`[steam-trace]`, `[steam-play]`, `[library-sections]`) now
  go to the Madeira log directly. Before, they went to stderr, which is only
  captured during a Wine session.
- The Install, Resume and Try again buttons show their icons again.

Switches (diagnostic rollback): `MADEIRA_STEAM_CDN_FILTER=0`,
`MADEIRA_STEAM_HOST_HEALTH=0`, `MADEIRA_STEAM_ZIP_CHUNKS=0`.
New tag: `[steam-cdn] ml1320` (servers offered/usable/skipped, first demotions).

## Windows Steam client (ml1260–ml1300)

The rest of this document covers the Windows Steam client. It is still
available from Settings › Windows Steam client.

## Try it on device

1. Open **Library → Steam → Download Steam installer**. Wait for **Installer
   ready**, enable JIT, then choose **Run downloaded installer**. Downloading
   alone does not start Wine or allocate its JIT pool.
2. Complete the normal Windows installer. Its default destination is suitable;
   keep the client and additional libraries inside `C:` (`wine/drive_c`). At the
   final installer step, clear **Run Steam**, return using the in-game menu, and
   choose **Open Steam** so Madeira applies its client launch options.
3. Let Steam update, sign in and install an application. Keep Madeira foreground
   during downloads. Touch pointer modes and the keyboard remain available from
   the in-game menu.
4. Exit Steam normally to flush its files, then use the in-game menu's **Quit
   game** to end the desktop session and return to Madeira.
5. Installed applications are imported automatically. **Refresh installed
   games** also performs discovery. Native **Play** starts Steam with the
   installation's App ID; it does not bypass the client or ownership checks.
6. **Big Picture** opens Steam's controller interface. Not-yet-installed purchases
   are browsed and downloaded inside Steam, not through a second native account
   system. An imported entry whose files were uninstalled offers **Install**.

The download is Valve's current official bootstrap installer, fetched over HTTPS
when requested. No Steam executable is packaged in the IPA. **Use my own Steam
installer** and **Locate an existing Steam installation** cover offline staging
and custom locations. Download cancellation leaves any previously staged
installer intact. Selecting a supplied installer copies it into
`C:\Madeira\Downloads\SteamSetup.exe`. Choose **Run downloaded installer**
after staging either kind of installer. That action remains available when a
partial installation has already created Steam.exe; no repeat download is needed.

## Status and limitations

This integration is experimental. Host checks validate parsing, installation
discovery, path containment, profile migration and launch routing. The IPA build
validates compilation and packaging. They do not demonstrate a successful Steam
login, download, DRM check or game launch on iOS.

The owner confirmed installer completion with ml1270. Logs 150/151 also show the
client updating and starting its Chromium helper, but do not establish a working
login. ml1280 protects retired 32-bit process windows and their executable copies
while registered workers remain alive, and supplies the missing 64-bit
`RtlWow64SuspendThread` export using Wine's `NtSuspendThread` implementation.
Retained workers may temporarily consume one of the available guest windows;
keeping their memory is necessary to avoid use-after-retirement crashes.

Earlier port work reached an interactive CEF login window but recorded CEF
stability and login-networking failures; see `STEAM_CEF_HANDOFF.md`. That older
evidence cannot establish whether the current self-updating client works. A
fresh device test is required. Steam support also does not imply support for
every application's DRM, anti-cheat, CPU or graphics requirements.

Discovery reads bounded `libraryfolders.vdf` and `appmanifest_*.acf` files. It
does not modify them. Completed manifests plus existing installation folders are
required for automatic import. A partial scan preserves existing installation
state. Custom titles, covers, launch arguments and compatibility settings survive
refreshes. Removed entries stay hidden until **Add** is selected in Steam's
management page. Artwork matching is separate from the launch App ID.

Install sizes come from Steam's manifests. Unknown architecture and renderer are
not inferred from Steam.exe itself. Existing renderer badges show one compact
capability label, preferring the highest detected Direct3D version; this label is
not a measurement of the renderer selected at runtime.

Installer and client sessions use Wine's virtual desktop and its existing larger
JIT-pool policy. Temporary Steam sessions do not create fake game cards. The
existing CEF host accommodations remain in place. Generic section-mapping and
descriptor-cache cleanup corrections also apply to installer helper processes.

## Diagnosis and rollback

Add these settings to `madeira-env.txt` when needed:

| Setting | Effect |
| --- | --- |
| `MADEIRA_STEAM=0` | Disable Steam integration and Steam-managed launches. Existing direct-executable entries are unaffected. |
| `MADEIRA_STEAM_COMPAT=0` | Omit the client launch flags `-no-cef-sandbox -cef-disable-gpu -nocrashmonitor` for an A/B test. Existing native CEF policy is unchanged. |
| `MADEIRA_STEAM_LIGHT=0` | Omit the ml1470 client flags `-cef-disable-hang-timeouts -nooverlay -nofriendsui -noshaders`. |
| `MADEIRA_STEAM_ORDERED_CLIENT=0` | Do not give the Windows Steam client FEX's stricter ordering (ml1470). Chromium helpers still get it. |
| `MADEIRA_ORDERED_PROFILE=0` | Turn off FEX's stricter ordering profile for every process (ml1470). |
| `MADEIRA_STEAM_STAGED_INSTALL=0` | Restore automatic launch immediately after downloading/importing the installer. |
| `MADEIRA_SECTION_PROCESS_LIMIT=0` | Restore the old shared WoW address ceiling for native section mappings (diagnostic rollback). |
| `MADEIRA_FD_CACHE_RELEASE_FIX=0` | Restore the old descriptor-cache retirement behavior (diagnostic rollback; can close another process's descriptor). |
| `MADEIRA_WOW_LIVE_WINDOW_GUARD=0` | Restore time-only retirement of guest windows and executable copies. Diagnostic rollback; a surviving worker may still use that memory. |
| `MADEIRA_WOW_SUSPEND=0` | Return `STATUS_NOT_IMPLEMENTED` from the restored thread-suspension API instead of calling `NtSuspendThread`. |
| `MADEIRA_NSI_NETWORK_TABLES=0` | Disable the new interface/IP providers; preserve the previous unsupported-table error. |
| `MADEIRA_TLS_CLEAR_OWNER=0` | Restore the former cross-process/untranslated TLS clearing for diagnosis. |
| `MADEIRA_COMPACT_API_BADGE=0` | Restore the full detected API chain on badges. |

`[steam-bridge] ml1260` records feature state, scans, installer stages and session
kind/App ID. It does not log credentials. For a device failure, include the
Madeira log and the stage reached: installer, bootstrap/update, login, download,
or application launch. Relevant native tags include `[WineProc]`,
`[session-handoff]`, `[wow-capacity]`, `[wow-placement]` and CEF diagnostics.
`[steam-install] ml1270` records download completion and the separate Wine/JIT
launch handoff, including before native output capture starts. `[section-limits]`
and `[fd-cache-retire] ml1270` identify the helper-process fixes. In logs 148/149,
the installer was already downloaded: the first run ended during JIT allocation,
while the second reached installation and then suffered native-helper mapping
and process-cleanup faults. The first termination has no crash report establishing
its cause. Successful installer completion still needs an updated device test.

Steam's own `logs` directory may be needed for login/update problems; redact
account identifiers and tokens before sharing those files.

For ml1280, cold-launch Madeira, enable JIT, and use **Open Steam** with the
existing installation. No reinstall is needed. Check whether updating finishes
and whether a login window appears. `[wow-lifetime] ml1280` identifies deferred
memory retirement; `[wow-suspend] ml1280` confirms the formerly missing API ran.
If the UI remains blank or disconnected, include Steam's files from
`wine/drive_c/Program Files (x86)/Steam/logs` (especially `cef_log.txt` if present)
alongside the Madeira log. In log 151 the browser thread remains in its message
loop while the client reports a UI WebSocket failure; its cause is not yet proven.

For ml1290, log 152 and its screenshot expose a separate missing path:
`GetAdaptersAddresses` reaches unsupported NDIS interface enumeration. The iOS
NSI bridge now connects Wine's BSD interface and IP providers, including native
and 32-bit parameter reads. `[nsi-network] ml1290` reports table/status/count
without dumping adapter addresses. The providers use actual host interfaces;
Wine's existing BSD IPv6 route-table limitation remains. Change notifications
and `WSALookupServiceBegin` are separate APIs and are not implemented by this fix.

The same log later faults in `virtual_clear_tls_index` while dereferencing an
untranslated 32-bit expansion-slot pointer. `[tls-clear] ml1290` identifies
process-scoped TLS clearing with the target TEB's window translation, including
retiring windows whose workers have not exited. This also prevents one guest
process's TLS release from clearing another guest process's slot.

Cold-start the new IPA, enable JIT, and open the existing Steam installation.
No reinstall or extra launch arguments are required. Adapter enumeration and
TLS handling have build/host-test coverage; Steam login, authenticated downloads,
and continued UI stability remain unverified until tested on device.

## Startup follow-up: ml1300

Logs 153 and previous 14 confirm successful adapter enumeration after ml1290.
The remaining WSALookupServiceBegin warning is not proof of a startup failure:
Chromium falls back to an unknown connection type. The debugger already detached
before Wine started. IPv6 loopback refusals are followed by successful IPv4
connections, but the browser repeatedly reconnects and never shows a login UI
within the captured interval. Successful login remains unverified.

Generic native I/O now chooses the status-block ABI using the calling process's
guest window, rather than session-global wow_peb. That global can point at a
sibling or be temporarily cleared during child startup. The wrong choice can
misinterpret a native status as a 32-bit pointer, or overwrite a 32-bit request's
host cookie during completion. The change covers synchronous and asynchronous
file/socket results and preserves full-width native byte counts. The source and
host regression prove the defect; these logs do not establish it as the sole
cause of the client reconnect loop.

Open Steam, Big Picture and Run downloaded installer now reserve the launch
immediately, show Opening, and disable repeated taps. A cancellable main-actor
task allows the feedback to render before validation and Wine/JIT startup.
Leaving the management view cancels a pending handoff. Missing JIT or invalid
executables restore the controls and show the existing error dialog.

Chromium's invalid --enable-logging=file argument is replaced with the supported
empty-value flag. Single-process and V8 settings remain as before. The bounded
error-only guest log capture also recognizes cef_log.txt and webhelper.txt;
normal log messages are not mirrored. Socket acceptance reports metadata only,
up to 24 lines, to distinguish queueing, completion and accept failures.

Rollback switches (set in madeira-env.txt before a fresh app session):

- MADEIRA_IO_STATUS_OWNER=0: restore the old I/O ABI classification.
- MADEIRA_STEAM_LAUNCH_FEEDBACK=0: suppress Opening/delay; duplicate-tap protection remains.
- MADEIRA_CEF_LOGGING_FIX=0: restore the previous Chromium logging argument.
- MADEIRA_TEXT_LOG_ERRORS=0: exclude the newly recognized text logs.
- MADEIRA_SOCKET_ACCEPT_TRACE=0: disable accept-stage diagnostics.

Cold-launch the new IPA, enable JIT and tap Open Steam once. Reinstalling Steam
is unnecessary. Check the immediate feedback and whether a login window appears.
If it remains blank, keep the session open for about a minute and export the
Madeira log. Useful tags are [steam-launch], [io-status-owner], [cef-logging],
[socket-accept], [guest-log], [nsi-network] and [nsi-ios]. The visible NLA warning
may remain. Do not treat its presence alone as a failed startup.

## Transport error: ml1350

The client's own logs (cef_log.txt) show why "Unexpected Transport Error (0x3000)"
appears. In every run, each connection to the client's local UI transport
(ws://localhost:6246x/transportsocket/) fails with Windows error 10038
(WSAENOTSOCK), although the TCP connection itself completes and steam.exe's
listener sees it. After connecting, Chromium asks winsock which socket events
fired and passes an event handle to reset. Winsock carries that handle in the
ioctl's input-buffer argument, and the 32-bit layer translated it like a memory
address. The resulting value is not a valid handle, so the call failed with
"not a socket". The native socket code now undoes that translation for this one
argument, for 32-bit callers only.

- MADEIRA_AFD_EVENT_HANDLE=0: keep the old translation (diagnosis only).
- Log tag: [afd-event-handle] ml1350 (first eight conversions).

This removes the demonstrated cause of the transport error. It does not prove
the login screen now works: the open rendering, crash and CM-login problems in
STEAM_CEF_HANDOFF.md may be the next thing seen.

## Frozen login window: ml1360

With ml1350 the transport connected and the login window appeared (device log
prev 15), then froze. Every message to it failed inside the window callback:
6770 "dispatch_user_callback ignoring exception c0000005" lines, starting with
a jump to 0xffff0036. That value is a Wine window-procedure handle, not code.
The 32-bit layer converted it like an address when the browser called
CallWindowProc (and would do the same for a class registered with such a
handle), so win32u no longer recognized it and handed it back to be called
directly. win32u now recognizes a handle that arrives with the calling 32-bit
process's window base added.

- MADEIRA_WINPROC_HANDLE=0: previous behavior. Tag: [winproc-handle] ml1360.

Game launches through the client now pass -silent, so Steam's library window
stays closed. Sign-in, Steam Guard and error windows still appear. Open Steam and
install links are unchanged.

- MADEIRA_STEAM_SILENT=0: show the library window. Tag: [steam-silent] ml1360.

A second run (log 163) reached no login window. One of the two local transport
connections was established, dropped after about 11 seconds, and afterwards
Chromium retried only the IPv6 loopback address (refused) and never 127.0.0.1
again. The cause is not established. The accept trace ran out of its shared
budget on queued requests, so it now has separate budgets and also records the
AcceptEx first-data stage ([socket-accept] ml1360: recv-wait, delivered with a
byte count, recv-failed).

The console window titled steamwebhelper.exe comes from Madeira's diagnostic
Chromium logging flag. Chromium only writes cef_log.txt in release builds when
that flag is present, so it stays until the client is stable.

## Login works, connection does not: ml1370

Device logs 164–166: with ml1360 the login window worked (QR sign-in completed
once, and a later start signed in from Steam's saved login and opened the
library). The status bar then read NO CONNECTION: steam.exe is not connected to
Steam's connection-manager servers, so the library cannot act and -applaunch
cannot start a game. The login page itself reported "Failed to start auth
session: result 3 (Connection failed)" before one attempt succeeded. The cause
is not yet established.

- Steam's connection_log.txt is now mirrored into the Madeira log as
  [steam-connlog] ml1370 (up to 96 lines), with SteamIDs and IPv4 addresses
  masked. MADEIRA_STEAM_LOG_MIRROR=0 disables it. Chromium VERBOSE lines no
  longer use the error-excerpt budget.
- Loopback connections record their first send/receive sizes as
  [loopback-io] ml1370 (metadata only; MADEIRA_LOOPBACK_IO_TRACE=0), to explain
  the intermittent "Unexpected Transport Error" where both local connections
  were accepted but the browser gave up after 11 seconds.
- The browser's UI thread faulted on an atomic add (x86 LOCK XADD) to a data
  word that shares a page with code. Madeira now performs the whole family of
  such atomics through the page's writable alias (MADEIRA_ALIAS_LSE_ATOMICS=0
  restores the old behavior; [lse-emul] ml1370).

### ml1380: what the connection log showed

Log 167 (first run with the mirror) shows the client's connection-manager
sequence directly. The server-list Web API call fails with "status = 0" after
8–43 s, and every WebSocket ping and connect fails at once ("timeout/neterror -
Invalid", then ConnectFailed with port 0). DNS and TCP work, and the TLS
handshake completes: steam.exe sends its Finished message without an alert,
then closes without sending the WebSocket upgrade, while Windows' cryptnet
(certificate retrieval and revocation) is active. So the client rejects the
server certificate in a CryptoAPI check after the handshake. Steam's servers
use Let's Encrypt's 2026 "Gen Y" chain (YE2/YR1 intermediates, Root YE/YR
cross-signed by ISRG Root X2/X1). OpenSSL validates both chains against
Madeira's bundle, and the issuer URL serves the cross-signed Root YE, so a
missing root is not the explanation. crypt32 now logs its chain and policy
verdicts ([cert-chain] / [cert-policy] ml1380, first 16 per process,
certificate names and status bits only; WINEDEBUG=err-chain turns them off),
so the next log names the exact failing check.

The same log also shows the browser's UI thread ending when Madeira's 896 MB
JIT code pool was full ("TAIL REFUSED", fault at 0xdead). That is why "Play
anyway" stopped responding. The Steam client plus its Chromium UI can fill the
pool on its own. Earlier sessions did not, so it depends on what the UI is
doing.

### ml1390: "Please update these games first"

Log 168: "Play anyway" worked, and the client then refused with "Failed to start
game with shared content. Please update these games first: 220". The client
treats Madeira's HL2 install as out of date. It is still NO CONNECTION, so it
can neither confirm the install from current app information nor download
anything. The exact reason is recorded in Steam's content_log.txt, which is now
mirrored too ([steam-contentlog] ml1390, masked, 96 lines). Before each
Windows-client launch, Madeira logs what its install record says
([steam-acf] ml1390: StateFlags, build IDs, installed and shared depots with
manifest IDs; MADEIRA_STEAM_ACF_LOG=0 disables). New installs log every depot and
why it was selected or skipped ([steam-depot] ml1390 selection). The crypt32
verdict log no longer spends its budget on the root-store self-check.

### ml1400: why the client never reached Steam's servers

Log 169's certificate verdicts named the cause. Every api.steampowered.com chain
in steam.exe built correctly (leaf, YR1, Root YR, ISRG Root X1; no revocation
errors) but ended with CERT_TRUST_IS_UNTRUSTED_ROOT on ISRG Root X1, although
the same process had validated chains earlier. Madeira's native crypt32 side is
shared by every Windows process, and its host-root enumerator gave each
certificate out once and then freed it. The first process to import roots used
up the list, the next process's import saw no host roots, and Wine's root sync
deleted the previously imported roots from the registry. The enumerator now
keeps the bundle and gives every caller the full list
(MADEIRA_ROOT_ENUM_SHARED=0 restores the old behavior; [root-enum] ml1400 logs
each completed enumeration).

The same log explains the update refusal. content_log.txt says
"Failed running app 220 (required app 380 not ready)", and Steam rewrote HL2's
record to StateFlags 6 with SharedDepots 340, 380, 389 and 420 (Lost Coast,
Episode One, Episode Two). HL2 now depends on content that Steam installs as
those apps, and Madeira's downloader does not install it. Once the client is
online it can download them itself. Installing them from Madeira's downloader
is a follow-up; the selection log now marks such depots (<appid).

`-no-browser` / `steam://open/minigameslist` (a 2021 tip) does not apply: Valve
removed -no-browser in January 2023, and the current client's login and dialogs
are all steamwebhelper pages.

The red "Steam no longer supports running on 32-bit Windows" banner is
expected. Madeira reports an ARM64 machine, and Steam treats real Windows on
ARM64 PCs the same way (it runs its 32-bit client there too). The 32-bit client
keeps working but no longer receives updates.

Logging in once in the Windows client is still required: Steam keeps its own
sign-in, separate from Madeira's native sign-in, and then signs in automatically
on later launches if "Remember me" is kept. Madeira does not copy its token into
the Windows client's encrypted credential files.

## Online, then a frozen session: ml1410

Log 170 confirmed ml1400. The client fetched its server list, pinged the
WebSocket servers and logged on ("RecvMsgClientLogOnResponse() : processing
complete"). It then started downloading the shared content (apps 340, 380 and
420) that the game now needs. Its connection dropped once ("I/O Operation Failed") and it logged
on again by itself 9 seconds later.

The freeze that followed was the wineserver crashing, which stops every Windows
process at once. A web helper thread had exited
(`read_request EOF -> kill_thread`), and the server then faulted in
`cancel_process_async()` on the list update right after `cancel_async()`
(`req_cancel_async+0x158`). Cancelling queues a completion to the owning
thread. The source shows that when the completion cannot be queued it runs at
once and can free the request inside `cancel_async()`, which fits the fault;
the log does not show that step directly. The server now holds a reference to each
request across its cancellation. A request that completes during its own
cancellation gets no cancel wait attached, since nothing would ever release it
(`MADEIRA_ASYNC_CANCEL_HOLD=0` restores the old loop; `[async-cancel] ml1410`
logs each case). The host test reproduces the use-after-free under ASan with the
rollback.

Log 171 (the relaunch) stopped at "Unexpected Transport Error (0x3000)". That
dialog is about the local link between steam.exe and steamwebhelper, not
Steam's servers. The web helper opened its two usual loopback connections, and
steam.exe accepted both. The web helper sent its 554-byte upgrade request on
each. steam.exe read and answered one; nothing was ever read from the other. Logs
169 and 170 show both being read at once. The existing probe records only
completed transfers, so ml1410 adds `[loopback-wait] ml1410` in the wineserver:
read requests with the server's verdict, poll requests and read-queue wake-ups,
for loopback stream sockets only, 12 lines per socket
(`MADEIRA_LOOPBACK_WAIT_TRACE=0`). It also logs the first receive per loopback
connection that would block (`[loopback-io] ml1410 ... recv-would-block`). The
next occurrence will show whether steam.exe never asked for the data, asked and
was never woken, or was woken without it. Choosing "Restart Steam" in that
dialog is the workaround.

Installing another game from Madeira's library (log 172) failed with "Steam did
not allow this account to download": Steam refused the first depot key it was
asked for. Valve's own DepotDownloader leaves out depots the account's licenses
do not include (another edition, extra content). Madeira now does the same, but
only when Steam refuses a key: it reads the licensed depot IDs from the same
package info the library uses, skips a refused depot the licenses do not
include, and still fails on any other refusal
(`MADEIRA_STEAM_LICENSE_DEPOTS=0` fails on every refusal).
`[steam-depot] ml1410 depot-key refused` names the depot and Steam's result
code, and `[steam-depot] ml1410 license` lists what was skipped. The depot
selection (`ml1390 selection`) is now logged before the key requests, so a
refusal still shows the layout. Device-unverified: if the refused depot is one
the licenses include, the log will show that, and the cause is elsewhere.

## ml1420: missing owned games, client download progress, stuck starting screen

**Owned games missing from the library (proven cause, fixed).** Steam's app
information (PICS) does not capitalize `common/type` consistently. Newer apps
send `"Game"`, many older ones send `"game"`. The parser matched type names
exactly, so a lowercase type became "unknown" and the app was dropped as not
playable. That happened before the `[steam-library] ml1310 owned apps=` count,
so the log never showed it. The public app information of the reported
multi-platform game has `"type" "game"`. Run through the production parser,
it is dropped with exact matching. With case-insensitive matching it is
offered, with its platform-neutral and Windows depots selected. Type names
now match without case (`MADEIRA_STEAM_TYPE_FOLD=0` restores exact matching). A
library list cached before this change is refreshed at the next start instead
of after six hours.

Once per library fetch, `[steam-library] ml1420 hidden` lists the owned apps
that are not shown and why (App IDs and reason tokens only; up to 40 listed,
`MADEIRA_STEAM_HIDDEN_LOG=0` disables):
`shown=<n> type-fold=<0|1> requested=<n> hidden=<n> types=dlc:<n>,… ids=<appid>:<reason>,… more=<n>`
(`requested`: distinct App IDs in the account's packages).
Valve's non-playable types (DLC, soundtracks, tools, configs, videos and so on)
are only counted under `types=`. Everything else is listed by App ID:

| Reason | Meaning |
| --- | --- |
| `unknown` | PICS does not know the App ID |
| `missing` | the app was requested but absent from every PICS response |
| `parse-empty` / `parse-utf8` / `parse-noname` | PICS sent the app, but its information did not parse |
| `type-<name>` | an unexpected type (`type-none`: no type at all) |
| `os` | no Windows build (`common/oslist`) |
| `nodepots` / `nodepot/<rule><count>+…` | no installable Windows depot; counts per skipped-depot rule (`os`, `dlc`, `shared`, `nomanifest`, `lowviolence`, `lang`, `arch`) |
| `+token` | PICS flagged the app as requested without a valid access token |

**Windows client download progress.** A game started through the Windows Steam
client often has to download content first, including shared content installed
as other apps. While such a session runs, Madeira reads (never writes) the
client's install records every 2 s off the main thread. It reads
`appmanifest_<appid>.acf` for the launched app and for every app named in its
`SharedDepots`, in the client's library folders inside `drive_c`.

- The starting screen shows, for example, "Steam is downloading game content:
  1.2 of 3.8 GB (31%)" with a progress bar. Other states are installing
  (staging), verifying, paused and "needs to update". It also says how many items
  are still to update.
- The client's window can replace the starting screen. While Steam is still
  downloading, installing or verifying, a small banner then stays at the top.
  It is hidden while the session menu is open.
- A record the client is rewriting, or has briefly removed, keeps its last
  complete reading.
- `[steam-progress] ml1420` logs start, stop, phase changes (at most one per 5 s)
  and changed figures while something is pending (at most every 30 s), up to
  240 lines per session. Each line has App IDs and byte counts only.
- `MADEIRA_STEAM_CLIENT_PROGRESS=0` disables it.

Device-unverified: how often the client rewrites the byte counters during a
download. If it rewrites them rarely, the figures will lag while the phase is
still correct.

**Starting screen left on screen (suspected cause, unproven).** Log 176: after
"Show live log", the starting screen stayed visible and unresponsive although
the game was presenting. The suspected cause is the animated removal of the
starting screen. That screen is a scroll view whose live log keeps updating,
and `launchLogs` changed outside the animation in the same update. Both flags
now change in one transaction without animation
(`MADEIRA_LAUNCH_VIEW_INSTANT=0` restores the animated dismissal).
`[launch-view] ml1420 dismissed reason=<present|surface|button> logs=<0|1> instant=<0|1>`
is logged once per session. `[launch-view] ml1420 hud launching=<0|1>` shows
that the overlay received the change.

**Client never logged on (log 175).** The session never called `LogOn()`.
Two causes are proven from the log; the link between them is inferred.

1. The code pool was the wrong size (proven). Madeira takes its JIT pool once
   at app start, sized like the previous session's request, and keeps it for
   the whole run. The previous run was a direct game launch (512 MB), so the
   client session, which asks for 896 MB, got
   `keeping the 512MB pool of session 1`. FEX's code buffers were refused
   (`TAIL REFUSED`), and one thread died at the deliberate out-of-pool fault
   (`EXEC ALLOC FAILED ... honest fault at 0xdead`).
2. A thread was stuck in an unwind loop (proven). Shortly afterwards the
   browser process's network thread spent 35 of 37 profiler windows at
   ~70% of a core. It was in `virtual_unwind` → `RtlLookupFunctionEntry` with
   a constant stack pointer (`ios_jit_reverse_translate_addr` was the top
   profile entry, 41-46% of all CPU). In the sessions that logged on (170,
   173) this never happened.

(inferred) The 0xdead fault is the kind of frame the unwinder cannot get past,
since it sits outside every image, which would link cause 1 to cause 2. The
fixes:

- The next run's early pool is the largest recent session's size, and a
  library with Windows Steam client entries starts at 896 MB at least
  (`MADEIRA_POOL_STICKY_MAX=0`; `[jit-early] ml1420`).
- The 64-bit ntdll stops an unwind after three steps without progress. The
  exception is then reported unhandled instead of spinning forever
  (`MADEIRA_UNWIND_GUARD=0`; `[unwind-stall] ml1420` names pc/lr/sp).
- The reverse lookup rejects addresses outside the pool at once and tries the
  last hit first (`MADEIRA_JIT_REV_FAST=0`; `[jit-rev] ml1420`).

The 0x3000 transport trace from ml1410 worked in log 175: both loopback
connections completed, with steam.exe reading through non-blocking forced-async
receives woken by `wake-read`.

## ml1430: the Steam client runs the code pool dry

Log 177 (ml1420). The client started with the full 896 MB pool and showed its
download progress (202 MB of 3.8 GB). About a minute later the desktop stopped
responding. Proven from the log:

- FEX's code buffers had reserved 720 MB of the pool: 30 buffers, all live, 17
  of them 32 MB. Images used 85 MB. FEX's next buffer was refused, and a thread
  died at the deliberate out-of-pool fault.
- That thread was holding FEX's shared lock
  (`[deliver-hold] ... HOLDS FEX shared lock`). Every other thread of that
  process that needed new code then waited forever. The ml1420 unwind guard
  fired once (`[unwind-stall]`), so the endless spin of log 175 did not recur.

Why 720 MB (proven from source):

- Each process shares one code buffer. When it fills, a new generation
  replaces it, and an old generation is freed only when no thread still holds
  it.
- The ml460 sweeper moves idle threads to the newest generation. Only FEX's
  64-bit (ARM64EC) side ever registered threads with it. There, a system call
  leaves translated code.
- The client and its browser helpers are 32-bit (WoW64). There a system call
  is a call out of a translated block, so a thread blocked in a wait has a
  return address into its generation and could never be moved.
- Chromium keeps hundreds of threads parked in waits, and one process was
  on generation 16.

The fix (FEX WoW64 module, `xtajit.dll`):

- 32-bit threads now register with the sweeper.
- While a thread is blocked in an outermost-level system call, it is marked
  movable.
- If the sweeper moves it, the call returns to FEX's permanent dispatcher
  instead of the old block. This is equivalent because these calls always end
  their block: the block only refills registers and dispatches at the address
  the call left in the thread state.
- Callbacks that re-enter translated code, nested calls, and a stack that does
  not match are never moved, so the change can only free memory and never
  redirect a return it cannot account for.

`MADEIRA_WOW_SYSCALL_SWEEP=0` disables it. `[wow-sweep] ml1430` logs the switch
state, the first resumes and anything declined. `[gen-sweep]` now shows
32-bit moves too.

Also: the download banner sat under the clock and battery when the game view
was in portrait. The HUD's reported top inset was zero while the status bar
showed, so its top overlays now use the status bar's height when it is larger.

**ml1440: no pool at all (logs 178, prev17).** Placement failed twice and Wine
never started ("The session could not start").

- The debugger's own pick was 0x7000000000, inside the guest window.
- None of the 160 fixed-address probes fit 896 MB. The usable holes above
  0x119000000 were 697, 608 and 292 MB. The map's "517 GB hole" above them
  comes from a region walk truncated at 200,001 entries, and everything from
  64 GB up is the GPU carve-out.
- ml1420 made this likelier: a library with Windows client entries now asks
  for 896 MB at start.

Placement now falls back to 768, 640 and then 512 MB when the requested size
has no home. A pool that starts beats none, and with ml1430 the client should
need far less than 896 MB. `MADEIRA_POOL_FALLBACK=0` restores failing at the
requested size. The "no home" line now also lists the first `vm_allocate`
refusals, to tell occupied ranges from unallocatable ones. Workaround for
older builds: `Documents/madeira-pool.txt` containing `640`.

**ml1450: why the download stalls (log 179, ml1440 build).**

What log 179 proves about ml1430:
- The fix works on device. The 896 MB pool placed normally.
- The sweep ran 54 generations, moving 45-49 of 54 threads each time. The tail kept 4-5 of 12 carves free.
- There was no `TAIL REFUSED`, no out-of-pool fault and no freeze. The user reported the app stayed responsive.

Why the download stalled at 238 MB:
- The client logged on and started depot 420 (3,065 chunks), ramping up by its own rate counter.
- About 8 s after each logon, the CM WebSocket dropped with `ConnectionDisconnected('I/O Operation Failed')`. In the same second, the client's own HTTP connectivity test failed.
- At 02:30:50 it logged `BYieldingGetServersForSteamPipe failed (Transport Response Not Received / Result No Connection)` and `Failed to get list of download sources`. The download had no sources after that.
- Nothing in the log said how the CM connection ended. Its socket carried normal traffic, then closed with no recorded error.
- The connection-log mirror had used its 96 lines by then.

New in ml1450:
- **`[tcp-end] ml1450`** covers stream sockets with a non-loopback peer, 48 lines per app lifetime, and `MADEIRA_TCP_END_TRACE=0` disables it:
  - ntdll logs a receive that returns 0 (the peer closed) and any receive or send error other than would-block, with local port, peer port (0 when the peer is already gone) and errno.
  - The server logs when a program closes a connected socket, with its age and whether a hangup, shutdown, reset or error had been seen first.
- **Saved errno on socket error paths.** The existing probes query the socket after a failed receive or send, and on a reset connection those queries fail and overwrite errno. The status returned to the program could then say "not connected" instead of "connection reset". Every probe and the returned status now use the call's own error.
- **Mirror budget.** The Steam connection-log and content-log mirrors now keep up to 320 lines each (was 96).

## ml1460–ml1470: "unexpected error during startup", and what GameNative does

**Log 181 (ml1450 build).** The client showed "Steam encountered an unexpected
error during startup" after a few minutes.

What the log proves:
- The error is the client losing its own helper. The Chromium helper opened
  new connections to the client's loopback listener at about 25 s and 4 min.
  The server accepted and delivered each one, and the helper sent its
  554-byte upgrade request. The client never issued a receive or a poll on
  any of them.
- `[tcp-end]` shows the CM WebSocket closed by the client itself about 7 s
  after the first logon (`closed by program … age=7s`), with no hangup, reset
  or error on the socket. The reconnect held. Most other `[tcp-end]` lines are
  short HTTPS connections the client closes on purpose.
- The ml1410 cancel hold fired 8 times without a crash.

Not proven: why the client never picks up the accepted connections. Two
explanations fit:
- a completion lost between the server and the thread that should run it;
- a message lost between the client's threads.

**ml1460: follow one accept end to end.** `[accept-chain] ml1460` (wineserver,
48 lines per app lifetime, `MADEIRA_ACCEPT_CHAIN_TRACE=0` disables it) marks
each accept on a loopback listener and logs, for that accept only:
- which thread the completion goes to, and whether that thread is waiting in
  the server;
- whether the completion APC was queued;
- the result, including whether it was posted to a completion port, and with
  what value;
- whether and how (immediately or after a wait) a thread took that value off
  the port.

The first missing step in the next log shows where the chain breaks.

**GameNative.** Jfishin, whose Steam work Madeira's is based on, referenced
[GameNative](https://github.com/utkarshdalal/GameNative) heavily. What it does
for the Windows Steam client and other launchers:
- **Stricter FEX ordering for the client and its helper.** GameNative's FEX
  configuration gives Chromium-based launcher processes Multiblock off and x86
  ordering for vector accesses as well as normal ones (VectorTSOEnabled,
  HalfBarrierTSOEnabled). Madeira's 32-bit default orders normal accesses only
  (log 181: `VectorTSOEnabled=0 Multiblock=1` in both Steam processes).
  Chromium passes messages through shared memory, so a message published with a
  vector store can be seen before its contents. That fits "the helper spoke and
  the client never heard".
- **A long list of client flags** that turn off the overlay, friends window,
  shader pre-caching, crash handlers and Chromium's hang timeouts.
- Its Steam-without-the-client mode (a Steam API emulator and a stub loader)
  is not used. It replaces Steam's DRM, and Madeira runs the real client.

**ml1470: what Madeira took.**
- **`[ordered-profile] ml1470`** (FEX, 32-bit). A process gets the stricter
  profile (Multiblock=0, VectorTSOEnabled=1, HalfBarrierTSOEnabled=1) when
  either:
  - `libcef.dll` or `chrome_elf.dll` sits next to its executable (any Chromium
    host, found by what it is, not by name), or
  - its executable name is listed in `MADEIRA_ORDERED_PROFILE_EXES` (the user's
    list) or `MADEIRA_ORDERED_PROFILE_CLIENT`. Madeira sets the latter to the
    client's executable for a Windows-client launch, so the client gets the
    helper's ordering and the games it starts keep the fast default.

  An option set in `madeira-fex.txt` is never replaced. `[fex-cfg]` marks the
  profile's own settings as `(ordered-profile)`. `MADEIRA_ORDERED_PROFILE=0`
  turns it off in FEX; `MADEIRA_STEAM_ORDERED_CLIENT=0` stops Madeira naming
  the client.
- **Lighter client flags.** `-cef-disable-hang-timeouts -nooverlay
  -nofriendsui -noshaders` are added to Windows-client launches (not to the
  installer). `MADEIRA_STEAM_LIGHT=0` omits them.
- Not taken yet: `-cef-single-process` and GameNative's other Chromium flags.
  They change how the helper is built up and would make any result harder to
  read. Revisit if the stricter ordering alone does not stop the startup error.

Cost: the client and its helper run slower with Multiblock off. The game is
unaffected.

## References

- [Valve's official client download](https://store.steampowered.com/about/)
- [Wine's thread-suspension implementation](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/process.c)
- [Apple's Mach thread query handling](https://github.com/apple/darwin-xnu/blob/main/osfmk/kern/thread_act.c)
- [Valve's owned-library Web API](https://partner.steamgames.com/doc/webapi/IPlayerService)
  requires an API key and library visibility; it is not a download or login API.

- [Chromium adapter enumeration](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/base/network_interfaces_win.cc)
- [Apple interface-address API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getifaddrs.3.html)
- [Apple routing ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.h) (vendored public header; original notices retained).

- [Chromium NLA fallback](https://chromium.googlesource.com/chromium/src/net/+/master/base/network_change_notifier_win.cc)
- [Chromium logging switch parsing](https://chromium.googlesource.com/chromium/src/+/57368cb688f57953997281524e3a9733c535393b/chrome/common/logging_chrome.cc)
