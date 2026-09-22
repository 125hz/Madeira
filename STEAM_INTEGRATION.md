# Steam in the optional front end

The native front end installs and opens the Windows Steam client. Steam itself
handles sign-in, Steam Guard, purchases, ownership checks, downloads and updates.
Madeira does not collect Steam credentials or require a Web API key.

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

## References

- [Valve's official client download](https://store.steampowered.com/about/)
- [Wine's thread-suspension implementation](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/process.c)
- [Apple's Mach thread query handling](https://github.com/apple/darwin-xnu/blob/main/osfmk/kern/thread_act.c)
- [Valve's owned-library Web API](https://partner.steamgames.com/doc/webapi/IPlayerService)
  requires an API key and library visibility; it is not a download or login API.

- [Chromium adapter enumeration](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/base/network_interfaces_win.cc)
- [Apple interface-address API](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getifaddrs.3.html)
- [Apple routing ABI](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.h) (vendored public header; original notices retained).
