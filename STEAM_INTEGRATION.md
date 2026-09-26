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
| `MADEIRA_APC_REQUEUE=0` | Restore dropping an I/O completion step for a busy thread (ml1480). Diagnostic rollback: reintroduces empty accepts and 0-byte reads. |
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

**Logs 182/183 (ml1460 build), about 8 minutes of one session.**
- The chain completed for all five accepts. The client read the helper's
  request on every connection and answered it, and the startup error did not
  appear.
- **The CM protocol decides whether a session holds.** In logs 179-183, every
  WebSocket CM connection (27018 or 443) dropped with
  `ConnectionDisconnected('I/O Operation Failed')` 0-8 s after logon, closed by
  the client with no socket error. Every UDP connection (27017) held, and its
  heartbeats kept passing. The client picks WebSocket 85-88 % of the time and
  re-rolls after each drop. So a session is healthy once it lands on UDP, and a
  run of WebSocket picks is what starved the log 179 download. The cause of the
  WebSocket drop is unknown.
- **The download progressed.** Depot 420's last 217 MB took 5.2 min (about
  0.7 MB/s) before depot 389 started. The Library bar read 14 % from the saved
  manifest at start, about 49 % once Steam rewrote it (Steam's own totals:
  1.91 of 3.84 GB), then 55 %.

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

## ml1480: the root cause, a dropped I/O completion step

**Log 184 (ml1470 build).** The stricter ordering was active in both client
processes (`[ordered-profile] … reason=listed` and `reason=chromium-host`),
and "unexpected error during startup" still appeared. `[accept-chain]` caught
it:

```
[accept-chain] ml1460 accepted; completion goes to thread 0094 (alive, in server wait=0)
[accept-chain] ml1460 result status=00000101 pending=1 port=1 posted=1 value=38c0180
[accept-chain] ml1460 completion APC status=00000101 to thread 0094 queued=0
```

The client never read that connection. The helper sent its 554-byte request
and waited.

What happened. When an overlapped operation becomes ready, the server queues
a system APC to the thread that started it, and that thread's ntdll does the
client half: the actual `recv`, or fetching an accept's addresses. A thread
that is not waiting in the server has to be interrupted. Upstream does that
with SIGUSR1, but on iOS `send_thread_signal` always fails, because there is
no per-process task port. So the APC was dropped, and the async completed with
the APC's own status, `STATUS_ALERTED` (0x101), and 0 bytes. The program saw:
- an accept that "succeeded" with nothing filled in (the startup error);
- for a receive, a successful read of 0 bytes, which every TCP program treats
  as the peer closing.

This hits any program whenever data or a connection arrives while the issuing
thread is busy. It fits the WebSocket drops too: a 0-byte TCP read ends the
session, while a UDP session ignores an empty datagram. That the WebSocket
drops share this cause is not yet proven.

**Fix (`[apc-requeue] ml1480`, wineserver).** An async I/O APC for a thread
that cannot be signalled is:
- given to another thread of the same process that is waiting in the server;
- or, if no thread is waiting, kept queued on the issuing thread, which runs it
  at its next server wait.

The client half is not tied to the issuing thread (upstream already hands it
over when that thread has exited). The server wakes only one alerted async per
socket queue at a time, so ordering is unchanged. Other system APCs keep the
upstream behaviour. `MADEIRA_APC_REQUEUE=0` restores dropping. The log line
prints the first 32 handovers and every 1024th after that, with the APC
status, so the next log also shows how often this was happening.

## ml1490: the client stays hidden, and games load and run lighter

What logs 185-193 proved after ml1480:
- **ml1480 fixed both failures.**
  - The WebSocket CM connection held for a whole session (log 185).
  - The client downloaded at up to 93 Mbit/s and launched the game with no startup error.
  - `[apc-requeue]` handed over 30-55 completion steps per session that the old server would have dropped.
- **A title stalled while loading, and it was not the client.** DXMT's D3D9 upload ring grew to 955 MB during a long loading screen. The ring only recycles after a submission, and a loading screen barely submits. The process reached its memory ceiling and slowed under compression.
- **Portal and Mirror's Edge reached gameplay through the client.**
- **Direct starts of Steam-DRM titles cannot work.** One also ran with a foreign hard-coded Steam ID. Another ran a PhysX installer the native install had picked as its program.
- **Client-routed play costs frame rate.** A client-routed title ran at 35-42 fps against 53-59 fps for the same game DRM-free. During play the client used about one extra core:
  - its engine thread's polling loop kept the Wine server at 0.4 core;
  - its hidden UI renderer used about 15 %;
  - the ordered profile slowed both.
- **Other log findings.**
  - A saved logon was rejected once, after the network changed (European CM list, new interface).
  - One launch was held by a 36 GB Workshop update: 52 subscribed items.

Changes:
- **Starting screen instead of the desktop.** A client-routed launch stays on the starting screen until the game's own window appears. The client's windows are revealed only when it needs you (sign-in, Steam Guard, EULA, errors) or when you press "Show Steam". Workshop updates are shown with their size and the note that they come from your subscriptions.
- **Loading memory (DXMT).** Uploads commit every 64 MB, with at most two batches in flight. A host run of the production ring allocator peaks at 192 MB instead of 1088 MB.
- **Steam identity per launch.** Nothing is published for client launches (the client sets it). A direct launch gets its folder and its library ID or steam_appid.txt.
- **Installers are never picked as a game's program.** Existing entries are repaired.
- **The ordered profile is off by default** (MADEIRA_ORDERED_PROFILE=1 re-enables it).
- **`[open-obj]` names what the client's engine thread keeps opening.** That comes next.
- Not done, and will not be: GameNative's client-less mode. It replaces Steam's DRM with an API emulator, a stub loader and an unpacker.

Switches added: MADEIRA_STEAM_HIDE_DESKTOP, MADEIRA_STEAM_AUTO_REVEAL, MADEIRA_STEAM_WORKSHOP_PROGRESS, MADEIRA_LIVE_BLACK_BARS, MADEIRA_STEAM_EXE_FILTER, MADEIRA_STEAM_ENV, MADEIRA_OPEN_OBJECT_TRACE, DXMT_D9_UPLOAD_COMMIT_MB, DXMT_ZERO_BUFFER_POW2.

## ml1500: keeping the client out of the game's way

Log 194, a client-routed title against the same title DRM-free:
- **Frame rate and memory:** 35-40 fps and 4.5 GB, against 60 fps and 2 GB.
- **The game itself costs the same:** renderer 448 MB against 491 MB.
- **Everything else is the client:**
  - 137 threads instead of 38;
  - about 290 MB more compiled code;
  - a second Chromium process that is only a crash uploader;
  - an engine thread keeping the Wine server busy at a third of a core;
  - all of it scheduled at the same top iOS priority as the game.

Changes:
- **Scheduling.** The client and its helpers now run at lower iOS scheduling classes: DEFAULT for the client, UTILITY for its helpers and tools. The game keeps the top class.
- **Client flags.** Game launches add the rest of GameNative's client options. `-cef-disable-breakpad` removes the crash-uploader process; the others turn off chat, Big Picture, VR, streaming drivers, the intro, helper extensions, remote fonts, video decode, D3D11 and DirectWrite in the helper.

What would save the most, and is not done:
- **GameNative's DRM-free mode** (Steam API emulator + stub loader + Steamless) is circumvention and is out.
- **A headless client host** is the legitimate equivalent. It would run Valve's genuine steamclient.dll without the Chromium UI, so games still pass Steam's checks against the signed-in account. It needs its own investigation.

Other findings:
- **Diagnostics on skews measurements.** The settings toggle (200 Hz profiler, 20 s thread walk) costs more with the client's thread count, so compare frame rates with it off.
- **Unsolved:** the client reruns a title's redistributable installers at every launch (DirectX, PhysX, VC++; about 16 s).

Switches: MADEIRA_THREAD_QOS, MADEIRA_STEAM_BACKGROUND_QOS, MADEIRA_STEAM_CEF_LIGHT, MADEIRA_LOG_VIA_STDERR, MADEIRA_PANEL_BINDING_COLLAPSED.

## ml1520: the web helper stops while the game plays

Logs 196/197 (ml1510), a client-routed title:
- **Frame rate and memory:** 45-55 fps and about 4.1 GB. About 1.6 GB of that is compressed, meaning nothing touches it.
- **CPU during play:**
  - The web helper's renderer thread alone is about 16% of all CPU. The helper's other threads, and the Wine server answering them, come on top.
  - The client's gamepad task is up to 10%.
- **Network polling:** about 40 adapter enumerations a second, all session long.
- **Installers:** the rerun of a title's redistributable installers is not the installers running. They cannot start, because SteamService takes the last of the three 32-bit process slots. So they fail at once, and the client retries them at every launch.

Changes (all device-unverified):
- **The helper ends 10 s after the game's window appears.** Its restart is refused until the session ends, and its 4 GB process window, with the memory in it, goes back to iOS right away. The client itself stays up and keeps the game's connection. A Windows tool does the same for PCs; whether this client build tolerates it here is what the next log shows ([park] lines).
- **Network change requests wait instead of failing,** so a caller waiting for an address change no longer re-reads the adapters in a loop.
- **The helper's verbose logging follows the diagnostics switch.**
- **`[proc-mem]` names what each 32-bit program holds,** every 30 s.
- **The starting screen follows the client's launch tasks** (console_log.txt), including a "Steam is waiting for you" line for a license agreement.

What stays out: GameNative's DRM-free mode and any client-less use of steamclient.dll.

Switches: MADEIRA_STEAM_WEBHELPER_STOP, MADEIRA_PARK, MADEIRA_PARK_DELAY_S, MADEIRA_NSI_NOTIFY_PENDING, MADEIRA_CEF_QUIET_LOG, MADEIRA_PROC_MEM, MADEIRA_STEAM_LAUNCH_STAGES.

## ml1720–ml1780 (2026-09-24): first launch, one-time installs, what the client costs

Rounds on the merged tree (Will's upstream through c8f6f27 / DXMT ca8a251). Device
logs 44–51. All device-unverified unless stated.

- **ml1720:** the license-agreement check reads the client's own folder (it read the
  game's folder, so every agreement looked accepted). "Session Replaced" is another
  login of the same account, not a rejected sign-in. valloc logging is capped (a log
  reached 562 MB). Show Steam shows the desktop at once.
- **ml1750 (verified):** when the 32-bit window band is full, a window spills into
  [0x74_0000_0000, 0x7b_0000_0000) (`MADEIRA_WOW_SPILL_CEF=0`). The client's
  redistributable installers got windows again (log 47).
- **ml1760:** a drawn, dialog-sized window from an installer image (msiexec, DXSETUP,
  vcredist/PhysX/dotnetfx helpers) auto-reveals the desktop
  (`MADEIRA_STEAM_INSTALLER_REVEAL=0`).
- **ml1770:** setup shows the client's install stage from `logs/bootstrap_log.txt`
  ("Downloading Steam's update… 45%", "Opening Steam's sign-in window…";
  `MADEIRA_SETUP_STAGES=0`, `[setup-stage] ml1770`). Log 48: a fresh install reaches
  the web helper ~90 s after the installer starts and draws the login ~50 s later.
- **ml1780, one-time installs:** logs 49/51 show the installers failing
  (DXSETUP -9 every time, an MSI "Fatal Error", a vcredist child without a window)
  and then the client itself ending (crash dump + exit 1) or its main thread looping
  on a fault right after the install script. Before a client start Madeira now reads
  the game's install scripts (`*.vdf` with "Run Process" in the install folder and one
  level down, plus `Steamworks Shared/_CommonRedist`) and writes each entry's
  HasRunKey value (DWORD ≥ MinimumHasRunValue, under both the key and its
  `Wow6432Node` view) into the prefix's `system.reg`/`user.reg` while no session runs —
  exactly the record the client writes after a successful run, so it skips them.
  Wine supplies those runtimes. Per-game "Run Steam's one-time installs" opts back
  in; `MADEIRA_STEAM_SKIP_INSTALLERS=0` disables; a "Skip one-time installs" button on
  the starting screen (installers stage) ends the session and relaunches.
  `[steam-installers] ml1780`. Reference: Steamworks "Creating and using InstallScripts".
- **ml1780, app:** the early JIT pool starts 0.6 s after the first frame (its
  debugger round trip stops the whole app for 3–4 s and kept the launch screen black;
  `MADEIRA_JIT_EARLY_DEFER=0`); the renderer badge names an API only when the files
  name exactly one (`MADEIRA_API_BADGE_STRICT=0`); the live log sits beside the status
  on a landscape phone (`MADEIRA_LAUNCH_SIDE_LOG=0`).

**ml1790** (device logs 52/53 of ml1780):
- The install-script reader kept only the last of the repeated `"Run Process"`
  sections (1 of 3 entries marked; the client still ran the others). A text reader
  now keeps every section.
- A second Wine session in one app run aborts in the wineserver's `init_registry`
  (`Assertion failed: (root_key)`, log 52) — the skip button's in-process relaunch
  and any Play after a session. Launches after the first session now ask for a
  restart ("Close Madeira"); the skip button marks the installs after the session
  stops and asks for a restart (`MADEIRA_ONE_SESSION_PER_RUN=0`, `[session-once] ml1790`).
- The early JIT pool starts at app start again (`MADEIRA_JIT_EARLY_DEFER=1` defers).
- Opt-in experiment `MADEIRA_STEAM_WEBHELPER_FREEZE=1`: the web helper's threads are
  held at their next wait from 10 s after the game's window until the session ends
  (`[park] ml1790`).
- Log 53, game through the client: footprint ~4.6 GB (game 1.21 GB, helper 0.69 GB,
  client 0.13 GB, 2.59 GB outside the 32-bit windows), 15–59 fps. Direct launches were
  ~2.4–2.5 GB. Next: a headless host around the genuine client library,
  `docs/STEAM_HOST_PLAN.md`.

**ml1800:** the web helper freezes by default while a client-started game plays
(`MADEIRA_STEAM_WEBHELPER_FREEZE=0` to keep it running), with a watchdog that thaws it
if the game presents nothing for 6 s (`MADEIRA_STEAM_FREEZE_WATCHDOG=0`, `[park] ml1800`).
Log 54 (freeze requested) stalled before sign-in with no freeze line: an unrelated,
intermittent client start-up wait. Log 55: the scripts declare a HasRunKey only for one
entry, so DirectX still runs (~14 s) each start.

What the client costs while a game plays (log 5 (2), ml1710, ~6 min of play, no
change made yet):
- Web helper ~680 MB (dirty + compressed) of a ~4.5 GB footprint; client ~127 MB.
- Web helper 0.27–0.42 cores for the first ~2.5 min while hidden, then 0.03–0.1. Most
  of it is re-translation: its FEX code buffer (iOS cap 32 MB) rotates about once a
  second (`[fex-stats] … +10 rotations` per 13 s, ~12k blocks/s compiled).
- The client's main thread traps on one unaligned compare-and-swap ~45/s in play
  (~220/s at startup) and FEX never patches it (`ua_patch=0`).
- Ending the helper during play froze the game before (logs 199/200); a replacement
  for the client or its API library is out of scope (DRM).

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

### 2026-09-24 — ml1820: native genuine-client headless host

The owner authorized native Windows host/game tests and asked that desktop
Steam remain closed. `build/steam-host/` now contains an independent C host:
exact client SHA-256/method gates, genuine cached logon, connected-state and
subscription-list checks, Valve's own asynchronous `LaunchApp`, callback pumping
while playing, and restoration of real process/account discovery values.
There are no game-specific patches, replacement Steam APIs, fabricated tickets
or removed DRM. The production Madeira launch path was not changed.

The owner confirmed startup for three installed games: a 32-bit C: title and
64-bit Steamworks titles on C: and D:. The C: installation was explicitly
selected for the benchmark. One game loaded the original Steam API alongside
the installed Valve-signed client DLL. Desktop Steam/CEF were absent. A reported
menu crash did not reproduce; the owner said they likely closed it accidentally.
Normal exits released the client and restored discovery with exit code zero.

Private `BIsSubscribedApp` returned true even for invalid IDs in this context;
it is not sufficient to authorize launch. The real subscription-list gate
rejected a missing App ID. A real non-entitled-account test remains outstanding.
The current DLL's asynchronous launch payload is 524 bytes, not 528. The first
launch exposed this mismatch; the corrected attempt retained the host properly.

Checks: both PE architectures compile; 11 lifecycle/failure and 16 entitlement/
payload validation cases pass under ASan/UBSan. Session/launch is x64-only.
A 5.17-second authenticated-session sample measured 99.93 MiB private host
memory and 0.0469 seconds host CPU; this excludes game/service processes and
does not predict Wine/FEX overhead. Both installed Valve client hashes remain
unchanged. Experimental code is uncommitted; no app payloads were staged and
no IPA was built for this native-only milestone.

Next: secure native-token handoff and a device probe using the existing Steam
prefix before changing onboarding. Desired onboarding is one native sign-in,
background installation of genuine client components and the headless host at
Play. See `build/steam-host/README.md` and `docs/STEAM_HOST_PLAN.md` for commands,
the exact supported DLL, original sources and remaining limitations.

### 2026-09-24 — ml1830: Madeira Dock private source and first iOS integration

Madeira Dock is the legitimate headless host for Valve's genuine client. It
requires real Steam authentication and authenticated subscription-list checks,
then uses Valve's launch path with original game APIs/DRM. It is not a DRM
bypasser. No fabricated ownership, Steam API replacements or protection patches.

The owner requires closed source. All independently written host source moved
out of the public checkout into the PRIVATE sibling ../madeira-dock repository
(125hz/madeira-dock) before any public source commit. The default GPL license
was replaced with an owner-authorized proprietary license permitting unmodified
binary distribution with Madeira. No third-party implementation was relicensed.
Public Madeira includes only the stripped EXE, notices and public Swift adapter.
Source/privacy Git hooks reject private paths and renamed markers, including
source removed before a push. No developer cached login, account token, Steam
config, Valve DLL or game content is included in the repository or IPA.

The app adapter is MadeiraDock.swift, included in the normal Xcode project.
MADEIRA_DOCK=1 opts into the device trial; =0 restores the desktop client route.
The native QR/password flow obtains each user's token from Steam and stores it
in Keychain. Before launch, downloads pause and the native Steam session logs
off/closes; reconnect is blocked while Dock owns the token. A protected,
backup-excluded one-use file carries it into Wine. Only the path is in the
environment. Dock consumes/deletes the file before login; malformed input fails
without cached fallback. Selected numeric results are copied into the app log;
leftover handoffs are cleared at failure, session end, sign-out and next start.

Onboarding with Dock enabled puts native sign-in first, then installs Valve's
Windows files using the existing official installer. The user is told to stop
at Steam's updated sign-in screen, without signing in there. This initial
trial still requires those installed files and the supported exact client
build. It supports Steam's default launch option with no custom arguments.
Automatic component installation/removing the desktop installer is later work.
The intended single-login path is implemented but not yet proven on a device.

Validation: 27 existing host sanitizer scenarios, bounded handoff/parser tests
(including 2,000 malformed inputs), Windows file consumption/deletion/replay,
real-host malformed-handoff rejection before login, and the existing cached
Windows authentication/subscription check pass. The public onboarding, launch
routing/contract and native Steam suites pass. The iOS build succeeds with
existing unrelated warnings. All Dock static imports resolve against bundled
Wine exports; no runtime compatibility is inferred from that alone. Wine source
is 11.4 and the bundled prefix template is Windows 10 Pro build 19045, not Win7.

Artifact: xtool/Madeira.ipa, label ml1830 · 09-24 19:39, 1,389 entries,
166,284,871 bytes, SHA-256 bd426d2b3172bf0160050338879d3b8712671af37fbd399509fd4ca49bf59b28.
Bundled stripped x64 Dock: 30,208 bytes, SHA-256
ddefca17379dda5e274f065913a7215a7f49a504ccb37a657a5257cc8d48804b.
CRC, all 1,271 Windows resource files, both new seals, integration strings,
source/debug exclusion and cached-login-file exclusion verified. The master
trial switch defaults off pending device results. No public Madeira push.

Read docs/MADEIRA_DOCK.md for the current device workflow; private README.md,
AGENTS.md and docs/HANDOFF.md for how to work on Dock. Next: owner device test
of live native token authentication, ownership gating, game launch and cleanup
using the existing prefix, then clean-prefix/component installation. Extended
play, a genuinely non-entitled account, revoked licenses, network loss, Steam
Guard/expiry, cloud/multiplayer and other client versions remain open.

Private Dock upload completed: origin/main commit 390eec9 (2026-09-24). Repository private visibility was rechecked immediately before pushing. Working tree clean in ../madeira-dock. Public Madeira changes and the device-trial binary remain uncommitted/unpushed; owner device validation is next.



## ml1840 — Dock routing and startup diagnostics (2026-09-24)

Device log 58 from ml1830 did NOT exercise Dock. At 19:59:28 the app prepared
its one-use handoff, then deleted madeira-env.txt because madeira.cfg existed.
The canonical file contained only the webhelper-freeze setting. LibraryFlags
read legacy env/getenv only, and the worker recomputed the route after deletion,
overwriting Dock's command with desktop steam.exe. The log contains the actual
steam.exe argv/child startup. This is a Swift integration bug, not evidence of
failed Dock authentication or Wine incompatibility.

ml1840 reads canonical env.* for both UI decisions and runtime export, merges
new legacy environment overrides atomically before cleanup, and verifies each
legacy file's values before deleting it. Conflicting/unreadable files remain.
The launch decision is passed explicitly through configuration and worker
startup; it cannot silently change when a file disappears. The session stores
that route for status text and final Dock diagnostics. [launch-route] ml1840
selected=dock is the app-side marker; dockhost.exe argv and guest host stages
are still required to establish that Dock actually ran.

The log toggle is pinned above the starting-screen scroll view from the start.
The log pane uses its full landscape height and up to 200 recent coalesced rows
instead of seven bottom-anchored rows. Short histories align to the top. The
profile's initial live-log choice can now be toggled off during startup too.
Dock gets its own honest starting/waiting label and Show desktop button.

Rollback/configuration: MADEIRA_DOCK=0 chooses desktop Steam before launch;
MADEIRA_FLAGS_CONFIG=0 restores legacy-only UI flag lookup;
MADEIRA_CONFIG_ENV_MERGE=0 retains unimported legacy environment overrides;
MADEIRA_STARTUP_LOG_ALWAYS=0 restores the delayed log button;
MADEIRA_STARTUP_LOG_FILL=0 restores seven rows. Use env.NAME = value lines in
Documents/madeira.cfg. Legacy madeira-env.txt remains accepted and imported.
A device affected by ml1830 must re-add env.MADEIRA_DOCK = 1: the deleted flag
cannot be recovered automatically. Dock remains opt-in; no account data or
private host source is introduced. Private host EXE is unchanged.

Validation: production configuration/LibraryFlags filesystem regression,
explicit route snapshot tests, Steam library/contract, onboarding, and launch
view suites pass (launch scene/census uses ASan/UBSan and TSan). Visual layout,
live native-token authentication, entitlement rejection, and Wine/FEX launch
still require device testing. Do not describe log 58 as a Dock failure or success.

Verified ml1840 artifact: `ml1840 · 09-24 20:11`, 1,389 ZIP entries,
166,299,430 bytes, SHA-256 `c07ad624c0924b89a427081e757a553f90a15744721f819501b3ac7216f521cc`.
All 1,271 Windows resources match their source copies and remain unchanged from
ml1830. Only the app executable, Info.plist and signature seal changed. Dock
remains the same stripped 30,208-byte PE; CRC, resource seals, integration
markers and source/cached-login exclusions pass. IPA: `xtool/Madeira.ipa`.
No public commit/push this round. Device authentication/gameplay and visual
layout confirmation remain pending.


## ml1850 — log 59: unloaded DLL mapping reused (2026-09-24)

The ml1840 device run selected Dock correctly: [launch-route] selected=dock,
argv[3]=C:\windows\system32\dockhost.exe, and a real x64 host child. It crashed
with 0xc0000005 during LoadLibraryExW of the genuine client, before live-token
authentication. The surviving explorer desktop made the UI wait indefinitely.
This is NOT evidence of a rejected Steam login or an ownership failure.

Exact evidence: bcrypt.dll at PE 0x70fb8a0000 (size 0x90000) received pool copy
0x11d134000. After crypto-provider teardown, coml2.dll reused the same base and
size but received no fresh pool-copy log. The fault PC 0x11d14bba0 equals the
old bcrypt pool +0x17ba0, whose actual instruction is `str w8,[x22]` inside
generic_alg_property. x22 was 1. The log's coml2+0x17ba0 attribution reads the
NEW PE header; coml2's real text ends at RVA 0x13216. The recorded instruction
bytes match bundled bcrypt exactly. Dock's return RVA 0x1e1f is its client
LoadLibraryExW call. Do not patch coml2, bypass SHA-256, or disable client DRM.

Fix: delete_view retires overlapping PE-to-pool translations for SEC_IMAGE
before releasing the address. This covers all owners of that unmapped VA and
preserves adjacent mappings. It leaves executable allocation reclamation to
the existing process ledger; it does not immediately recycle executable bytes.
The old mprotect containment test checked only MZ and SizeOfImage, so equal-size
address reuse wrongly counted as the old live image. A fresh mapping now gets
a fresh code copy and the existing FEX alias registration replaces its overlap.
MADEIRA_JIT_IMAGE_RETIRE=0 rolls back; [jit-image-retire] ml1850 is capped at 32.

A weak native self-exit callback now publishes only Dock's numeric exit status
through an atomic session record. Swift polls it independently of explorer,
reads only whitelisted numeric guest report events, and displays a failure plus
Close session instead of spinning forever. Zero status is distinct from no
exit event. First event wins, and the record resets at session begin.
MADEIRA_DOCK_STATUS=0 disables this observation; [dock-status] ml1850 logs it.
The guest report is still not an ownership assertion; original checks remain.

Live-log control: the previous top placement was outside the known visible
Show desktop controls, under the general session tools gate and near the
session-message overlay. Log 59 does not prove which UI condition hid it.
The button is now directly above Show desktop, bordered, immediately available,
and independent of MADEIRA_SESSION_TOOLS. MADEIRA_STARTUP_LOG_ALWAYS=0 retains
the delayed legacy control; [launch-log] ml1850 logs via LogStore, not an early
stderr write. The ml1840 full-height/200-row log implementation remains.

Validation: new source-extracted ASan/UBSan host checks cover equal-base/equal-size
image reuse, both ownership records, adjacency, partial overlap, rollback,
zero-length ranges, first/zero/error exit status, concurrent publishers and
session reset. Existing config, library/contract, and session lifetime tests
pass. Native rebuild: ntdll 36/36, win32u 46/46, wineserver successful. No actual
Wine/game runs on this PC. Device authentication, game launch, and visual
button/layout confirmation remain pending. No private Dock implementation or
binary changes; no source or account data added to the app. No public push.

Verified ml1850 IPA: `ml1850 · 09-24 21:00`, 1,389 entries,
166,303,597 bytes, SHA-256 `bdc7e6a944f1a1dd24f276bfc9350cb2040187d6bae3c6d1bd5167cb145aac87`.
CRC, new native/UI diagnostic strings, all 1,271 Windows resources, resource
seals, and private-source/cached-login exclusions pass. Compared with ml1840,
only Madeira, Info.plist and CodeResources changed. Dock remains 30,208 bytes
with SHA-256 `ddefca17379dda5e274f065913a7215a7f49a504ccb37a657a5257cc8d48804b`. Linked host-exit callback and
status reader verified with llvm-nm. Existing unrelated compiler warnings remain.
Install over the current app and retain env.MADEIRA_DOCK = 1; no config change
needed. Device retest required; no authentication/game-launch success claimed.

## ml1860 — client compatibility and normal-exit reporting

Log 60 loaded Valve's client successfully; the owner's Dock report identified
an unsupported January client, before authentication. The private host now has
an independently verified adapter for that exact official DLL; unknown builds
still fail closed. MADEIRA_DOCK_CLIENT_202601=0 disables the new adapter.
The public app observes normal Dock exit through the common Wine exit wrapper
and includes only whitelisted report fields in its exported diagnostic log.
MADEIRA_DOCK_STATUS=0 rolls back that observation. The owner confirmed the
live-log button works. Windows no-login ABI/rollback checks and host regression
checks pass. Device authentication/game launch remain unproven. Keep the
existing env.MADEIRA_DOCK=1; no Steam reinstall should be needed for this DLL.
Read HANDOFF.md and docs/MADEIRA_DOCK.md for current test instructions. Private
adapter source stays only in ../madeira-dock; only its stripped EXE is bundled.

ml1860 artifact verified: `ml1860 · 09-24 21:30`, `xtool/Madeira.ipa`,
166,306,898 bytes / 1,389 entries. IPA SHA-256:
`78a10b3ce35fc5da9aee957f8e3ce0f5c6ce493fc3b8811daa7c3b73176373ca`.
Dock remains stripped x64, 30,208 bytes, new SHA-256:
`61976bb68737c9e39f1acd387b22c7aece406f34784352bb0307bf21a1b0f3fa`.
Only the app executable, Dock EXE, Info.plist and CodeResources changed versus
ml1850; no removed entries. All 1,271 Windows resource files match the source
bundle; CRC, notices, signatures' resource seals and source/login/Valve-DLL
exclusion checks pass. Common exit wrapper and both bridge symbols are linked.
Existing unrelated compiler warnings remain. No commit/push performed.

## ml1870 — protected handoff path

Log 61 passes the exact client/session ABI checks and reports a normal exit,
but rejects the one-use native transfer before submitting a token to Valve.
The app's Z: path assumption is wrong for a normally seeded prefix. ml1870
uses Wine's Unix namespace for the same protected Application Support file;
MADEIRA_DOCK_UNIX_HANDOFF=0 rolls back. The private host also adds numeric
operation/error diagnostics (MADEIRA_DOCK_HANDOFF_DIAGNOSTICS=0 disables them).
Code 37 now has a specific message. No token/path/account data is logged.
The existing exclusive-open, bounds, delete-on-close and clearing checks stay.
Source-extracted namespace and synthetic Windows consumption/replay tests pass.
The full host rejects a malformed synthetic transfer before login, reports
stage=5/error=0 and removes it. Its isolated official-client probe emits known
missing-helper warnings; these do not change that pre-login rejection result.
No cached-login fallback, Wine-on-PC run, installed client modification, or game
test. Desktop Steam remains closed. Keep env.MADEIRA_DOCK=1; install over the
app and export the normal log after a failure. See HANDOFF.md for the evidence
limits: iOS authentication/game launch is still unproven. Dock source is private.

ml1870 verified artifact: `ml1870 · 09-24 21:46`, `xtool/Madeira.ipa`,
166,307,354 bytes / 1,389 entries. SHA-256:
`defe7ed39691534563d027ae813054eb709e5a30169ad6aef22680aa1df3a124`.
Stripped x64 Dock is 30,720 bytes, SHA-256:
`26bc7b1ace2846191f67d7673219e7bae132be5b0ec0db84d5e9795c65b45044`.
CRC, all 1,271 Windows resources, new app/host diagnostic strings, resource
seals and source/login/Valve-DLL exclusions pass. Only Madeira, Dock EXE,
Info.plist and CodeResources changed from ml1860; no entries removed.
Dock imports resolve against bundled Wine exports. Existing unrelated compiler
warnings remain. No commit/push performed. Device verification is outstanding.

## ml1880 — first authenticated device launches; performance trial

Device logs 62/63 (ml1870) report session-authenticated-online=1 and
session-requested-app-listed=1; the owner confirms the installed 32-bit game
runs on iOS through Dock. This proves the tested native-token/Valve-client
path, not broad compatibility, clean-prefix provisioning or all online APIs.
Source remains private; the stripped host and real authentication/DRM are
unchanged this round. No developer login is included.

Evidence: late whole-app footprint is about 2,713 / 2,832 MiB, versus the
owner's earlier roughly 4.5 GB observation (not a controlled matched scene).
The 896 MiB JIT allocation is still selected as a desktop session, although
head + reserved tail reaches only about 230 MiB. Pool blessing dirties the
whole allocation. Metal allocated size is roughly 450–470 MiB; the larger
resource census is logical capacity, not another resident-memory total.
Frame reports vary by scene: later log 63 windows show about 47–58 fps,
4–8 ms GPU time and substantial unattributed CPU-side waiting. Do not call
all of that waiting CPU computation or promise an FPS increase from it.

Changes in public Swift only:
- With Dock enabled and onboarding complete, the early pool defaults to
  512 MiB despite the old desktop/setup sticky high-water. This reduces the
  reservation by 384 MiB. Actual footprint/FPS improvement needs device A/B.
  Explicit pool=256..1152 wins; unfinished setup retains its larger pool.
  env.MADEIRA_DOCK_COMPACT_POOL=0 restores previous sizing after restart.
- A desktop launch after a compact allocation stops before Wine starts,
  requests a restart and reserves at least 896 MiB on the next run. That
  reservation is cleared only after a large allocation succeeds. The pool
  cannot be enlarged or safely discarded after debugger detach. Existing
  one-session-per-app-run behavior remains. Explicit small pool overrides
  retain their deliberate user-selected behavior.
- Normal Dock gameplay defaults the guest D3D9 census to off: log 63 counted
  over 32,000 API calls/frame, plus histogram work. Frame/memory telemetry
  remains. env.MADEIRA_DOCK_LIGHT_DIAGNOSTICS=0 restores the old default;
  env.MADEIRA_D3D9_CENSUS=1 explicitly enables it. MADEIRA_DIAG or
  MADEIRA_D3D9_LAST opt-ins also prevent the new default. This targets the
  emulated PE frontend loaded in these logs; the native frontend's static
  initializers run earlier and are not reconfigured by this launch policy.
  This reduces diagnostic work, with no measured FPS claim yet.

Host checks compile the production policy and cover setup, manual overrides,
rollback, desktop recovery and diagnostic precedence; config/onboarding
regressions pass. Tags: [dock-pool] ml1880 and [dock-perf] ml1880.
Install the new IPA, fully quit/reopen Madeira, enable JIT and repeat the same
scene/settings for several minutes. Check the actual pool is 512 MB, then
compare footprint and [frame] windows. For independent A/B: pool=896 keeps
old memory sizing; env.MADEIRA_D3D9_CENSUS=1 keeps old per-call counting.
Restart between changes. If [jit-pool] EXHAUSTED or tail allocation failure
occurs, restore pool=896 and send the log. Larger/other games are untested.
No private host code changes, commit or push in this round.

ml1880 verified artifact: `ml1880 · 09-24 22:11`, `xtool/Madeira.ipa`,
166,312,103 bytes / 1,389 entries. SHA-256:
`5096bec2dcef89ea62c258736acd0c86514e96a95f07fce901a1335915b1d264`.
All 1,271 Windows resources match the staging tree. CRC, build/policy tags,
stripped host, license notices, source/login/Valve-DLL exclusions and resource
seals pass. Only Madeira, Info.plist and CodeResources changed from ml1870;
no entries were added or removed. Dock EXE remains byte-identical:
`26bc7b1ace2846191f67d7673219e7bae132be5b0ec0db84d5e9795c65b45044`.
Public config/onboarding/library/runtime/report and performance policy tests
pass; the production desktop-reservation methods are also exercised with
isolated preferences. Existing unrelated compiler warnings remain. No
commit/push. RAM/FPS improvement from ml1880 requires owner device testing.

## ml1890 — hide unreliable pre-download sizes

The owner reports ml1880 runs well; there is no new log or controlled RAM/FPS
comparison yet. They also reported implausible sizes on uninstalled entries.
The public downloadSize estimator sums selected PICS depots, mixes compressed
public.download values with legacy maxsize, and skips missing sizes. This can
produce partial or misleading totals. No raw per-app metadata was supplied to
establish which exact field caused each reported value.

The owner authorized removing the estimates if a reliable fix was unavailable.
SteamOwnedGame.displayedDownloadBytes now suppresses the cached estimate by
default, in both the library card/list badge and the download-options sheet.
No arbitrary size clamp or title-specific patch. Stored downloadBytes is kept
for cache decoding and rollback; old bad cached values are hidden immediately
without sign-out, cache deletion or a refresh. Actual manifest-based download
progress, installed folder sizes and free-space display remain unchanged.
MADEIRA_STEAM_HIDE_SIZE_ESTIMATES=0 restores the legacy estimate after restart;
[steam-size] ml1890 logs the policy once. A future estimate needs a complete,
validated install plan with consistent units, rather than a partial metadata
sum presented as the full game size. No additional library network requests.

Swift-only change; no private Dock or native runtime changes. Keep the ml1880
pool/diagnostic improvements. Build/IPA verification recorded below when done.
No commit/push.

## ml1900 — native Dock onboarding prototype (build stopped)

The owner explicitly stopped the ml1890 build and requested planning and
implementation of onboarding without an interactive Steam installation.
The build was terminated after compile/before packaging; the IPA is still
ml1880, SHA-256 5096bec2dcef89ea62c258736acd0c86514e96a95f07fce901a1335915b1d264.
The ml1890 library-size change remains in source and is not shipped yet.

Read docs/DOCK_ONBOARDING_PLAN.md for the complete plan, verified package
provenance, implementation, test evidence and remaining clean-prefix tests.
A public native preparer and opt-in onboarding page now download three pinned
Valve packages (~73 MB), verify hashes, safely extract them, seed the prefix
and create client-discovery registry entries. No Wine/JIT session or second
Steam login is started. Progress/cancel/retry and desktop fallback are present.
MADEIRA_DOCK_NATIVE_SETUP=1 (with MADEIRA_DOCK=1) opts in; default remains off.
[dock-setup] ml1900 is the low-volume tag. Private Dock code/binary are unchanged.

Host ZIP/path/registry checks pass against synthetic cases and all three real
Valve archives. Existing onboarding/library regressions pass; installer code
passes isolated arm64-iOS SDK type-checking and UI source parsing. This is NOT
a full app link or a clean-prefix device authentication/gameplay test. No IPA
build was restarted. Use a separate clean test container for the next device
trial; preserve the owner's currently working install. Never claim native
provisioning proven from the earlier existing-prefix Dock launch logs.
No commit/push. Next IPA round should be ml1900 when build work resumes.

## ml1900 packaged for device testing (2026-09-25)

The owner explicitly resumed IPA building. The full app compiled, linked and
packaged successfully; the earlier build-stopped notes below are historical.
Current artifact: `xtool/Madeira.ipa`, label `ml1900 · 09-25 00:08`,
166,360,928 bytes / 1,389 entries. SHA-256:
`3c25ddff4b740aa32428078b1485a9bc2f8526f0728802739a0421b46bb53caf`.

The IPA includes native Dock onboarding and ml1890's hidden unreliable size
estimates. Native setup remains opt-in: set `env.MADEIRA_DOCK=1` and
`env.MADEIRA_DOCK_NATIVE_SETUP=1` in Documents/madeira.cfg, fully reopen the app,
then Settings > Run setup again. Existing Steam files are retained and skip
component preparation; download/provisioning needs a separate clean test
container, preserving the owner's working installation. Fresh-prefix device
authentication/game launch is still unverified. Prepare components before JIT.

Content verification passed: CRC, build/new-feature tags, 1,271 runtime resources,
stripped Dock, notices, source/login/Valve-DLL exclusions and resource seals.
Only the app executable, Info.plist and CodeResources differ from ml1880; no
entries added/removed. Dock's hash is unchanged. Existing compiler warnings
remain. Reports: .xtool/logs/ml1900-verified.json and ml1900-build.log;
verifier: .xtool/verify-ml1900.py. No commit/push or private source changes.

## ml1910 — Dock onboarding enabled by default (2026-09-25)

The owner requested a fresh-install IPA with Dock and native setup already
enabled because they cannot edit madeira.cfg during onboarding. This explicitly
supersedes ml1900's opt-in-only decision. Both MADEIRA_DOCK and
MADEIRA_DOCK_NATIVE_SETUP now default true; explicit =0 overrides still work.
MadeiraDock.nativeSetupEnabled is shared by onboarding routing and its low-volume
[dock-defaults] ml1910 diagnostic. No configuration file is needed on a fresh
install. Flow: welcome, native Steam sign-in, Prepare Madeira Dock (download and
verify ~73 MB of official Valve components), library. Wine desktop installation
is only an explicit fallback. Genuine client files are still downloaded; they
are not bundled in the IPA. Private Dock/authentication/DRM checks are unchanged.
Existing Steam files are retained. Clean-prefix device authentication/launch
is still awaiting the owner's test, not proven by changing these defaults.
Host onboarding/configuration/performance regressions pass. Full build and
content verification passed: `ml1910 · 09-25 00:19`, 166,360,404 bytes,
1,389 entries. SHA-256 `9ee0011365a1f1769837cc8c4587e32e2772f66b2410a77a919684435eb6b0a8`.
All 1,271 runtime resources match; stripped Dock, notices, source/login/Valve-DLL
exclusions, ZIP CRC and seals pass. Only app executable, Info.plist and seals
differ from ml1880. Reports: .xtool/logs/ml1910-build.log and
ml1910-verified.json; verifier: .xtool/verify-ml1910.py. Existing unrelated
compiler warnings remain. The IPA is ready at xtool/Madeira.ipa.
No private source edits, commit or push.

## ml1940 — log 64 address-space pressure and heap performance trial

Log 64 ends with STATUS_NO_MEMORY for a 0x240000-byte guest reservation:
3,877 MiB mapped, 218 MiB aggregate free, largest gap 0x230000. The 32-bit
guest exits status 3; later access violations are during teardown. Dock exits
normally, and the 512 MiB JIT pool does not report exhaustion. The `reserved`
census class is an initial-allocation flag, not proof of currently uncommitted
pages. Do not describe this as an authenticated Dock failure or proven leak.

See docs/RUNTIME_MEMORY_PERFORMANCE.md for evidence, primary API references,
implementation and retest plan. New Wine i386 heap policies initialized after
process parameters, before application threads: MADEIRA_HEAP_COMPACT=1 caps
subheap growth at 2 MiB and retries to the actual aligned need under pressure;
MADEIRA_HEAP_COMBINED=1 joins full reserve+commit into one VM call. Either enabled
also releases a new reservation if its split commit fails (verified source bug,
not established as this crash's cause). No caching of freed blocks, changed
requested sizes/VA ceilings, game-specific logic, auth or private Dock changes.
Dock launches default both switches on after config export; explicit =0 wins.
Native 64-bit heaps are unaffected. Logs: [dock-heap] / [heap-policy] ml1940.
This mitigates guest address pressure; a long-session device repeat is required
to prove crash prevention. No FPS gain measured. User's current IPA was ml1910.

Production-path ASan/UBSan host test check-heap-policy.py passes: combined and
split VM contracts, failure injection/cleanup, aliasing, fixed heap rejection,
growth bounds, small-gap retry and rollback. Existing Dock performance/config
regressions pass. i386 build initially exposed ARM-specific probes in shared
sources: CHPE detach/counter diagnostics now architecture-guarded. The local
build-wine-i386.sh now checks make exit status, not merely old target existence.
Fresh i386 ntdll compile/link passes; architecture and new strings verified.
Full IPA build/content verification passed; artifact details recorded below. No commit/push.
Current controller PRs/worktrees are not changed by this round.


ml1940 build completed and content-verified (2026-09-25):
`xtool/Madeira.ipa`, label `ml1940 · 09-25 01:50`, 166,363,201 bytes,
1,389 entries. SHA-256:
`55bdb43208945e6363d446698f36c58305f9a0fd83d086c9c992e2d8ef48a498`.
Only the app executable, i386 ntdll, Info.plist and resource seals differ from
ml1910. All 1,271 Windows resources match the source bundle; no entries removed.
CRC, new Swift/PE markers, stripped unchanged Dock, source/login/Valve-DLL
exclusions and seals pass. Native/PE build had zero missing cross-imports.
Reports: .xtool/logs/ml1940-build.log, ml1940-wine-i386-build.log,
ml1940-verified.json and ml1940-log64-analysis.json. Existing unrelated Swift
warnings remain. No device run, measured FPS gain, commit or push in this round.
Install over the app, fully restart and repeat the transition/long session.


## ml1950 — pressure recovery and useful performance diagnostics

Log 65 confirms ml1940 is active but repeats the allocation failure: guest VA
mapped 3,945 MiB, total free 150 MiB, largest hole 0x1e0000, failed request
0x230000, followed by guest exit 3. Do not call ml1940 a confirmed crash fix.
See HANDOFF.md and docs/RUNTIME_MEMORY_PERFORMANCE.md for this round.

Wine i386 now atomically detaches and releases wholly empty LFH groups on a
failed RtlAllocateHeap, then retries once if any were released. Partially used
groups are republished and live pointers never move. MADEIRA_HEAP_RECLAIM=0
rolls back. Empty-group retention has not been proven as the main consumer in
this log; recovery does not solve arbitrary live-block/VirtualAlloc exhaustion.

MADEIRA_HEAP_STATS reports live large/subheap/free capacity and large allocation
sites. MADEIRA_VA_DIAGNOSTICS adds size/creator-thread attribution to the failure
census. MADEIRA_CPU_DIAGNOSTICS reports per-thread cumulative CPU deltas every
10 seconds without suspending threads or reading registers/stacks. All default
on for Dock; explicit =0 wins. Logs use ml1950. Keep existing intrusive samplers
off. Snapshot capacities/overflow and unmatched/new/dead CPU threads are explicit;
do not interpret the counters as proof of a leak or a measured FPS improvement.
Log 65 median FPS 43.75, presenter CPU 4.9 ms / wait 17.55 ms; the dominant busy
worker or wait dependency remains unproven. Keep compact JIT sizing and light
D3D9 diagnostics. No private Dock/source/authentication changes.

Production-source sanitizer tests for reclaim (including 2,000 concurrent frees)
and CPU metadata/query-failure/port-cleanup/ID-reuse/capacity pass, as do existing
heap/Dock/guest-window regressions. i386 ntdll and native Wine compile. Full IPA
verification is recorded in HANDOFF.md once complete. Device long-play and FPS
confirmation remain pending. No upstream PR changes, commit or push.


ml1950 final IPA verified (2026-09-25): `xtool/Madeira.ipa`, label
`ml1950 · 09-25 02:37`, 166,368,757 bytes / 1,389 entries.
SHA-256: `c57e3000dd41a513736ebe2c784ed27507f9447da58f51fa0c2fbb4b280b68fc`.
i386 ntdll: `04f8314e250ba02418db6878dbc25fcb62cb8646fbfa89e7713727afc90ca4c9`.
All 1,271 Windows resources match the current source bundle; CRC, final CPU
Mach-port marker, new heap/VA diagnostics, stripped unchanged Dock, notices,
source/login/Valve-DLL exclusions and seals pass. Only Madeira, i386 ntdll,
Info.plist and CodeResources differ from ml1940; no entries added or removed.
The final rebuild includes the acquire read pairing with concurrent frees.
Native build: 36/36 ntdll and 46/46 win32u objects, wineserver success; PE import
closure has zero missing imports. Production VA-census sanitizer tests also
pass (grouping, exclusions, empty window, capacity overflow and rollback).
Existing unrelated Swift/toolchain warnings remain. No device crash prevention
or FPS gain is confirmed yet. Install over the current app, fully quit/reopen,
enable JIT, repeat the long session and export the log, even on success.
Reports: .xtool/logs/ml1950-build.log, ml1950-native-build.log,
ml1950-wine-i386-build.log, ml1950-log65-analysis.json, ml1950-verified.json.
Verifier: .xtool/verify-ml1950.py. No private Dock changes, commit or push.


## ml1960 — public installation/launch compatibility

See [docs/COMPATIBILITY_ML1960.md](docs/COMPATIBILITY_ML1960.md). Imported default
launch arguments retain provenance so Dock can select Valve's default option;
custom arguments remain explicit unsupported input. Downloads resolve missing
shared-depot manifests from their exact owner references, bounded and cancellable,
while all key/content authorization remains with Valve. Supported publisher
Registry values are applied inside the stopped Wine prefix before launch.
Private Dock source/binary/authentication are unchanged. Existing installations
receive registry/default-argument handling immediately; omitted depot content
requires download/update. Device tests remain pending. Each policy has an
independent MADEIRA_* rollback and ml1960 diagnostic listed in the document.


ml1960 repair entry point: installed native entries now expose **Repair installed
files** in their Steam settings even when the build ID is current. It uses the
existing queue, chunk verification and resumable downloader, with the new shared
metadata resolver. `MADEIRA_STEAM_REPAIR=0` hides/disables it; `[steam-repair] ml1960`.
No automatic redownload or uninstall is performed. The final app rebuild includes
this control, shared-lookup cancellation and saved argument-provenance handling.
