# Steam in the optional front end

The native front end installs and opens the Windows Steam client. Steam itself
handles sign-in, Steam Guard, purchases, ownership checks, downloads and updates.
Madeira does not collect Steam credentials or require a Web API key.

## Try it on device

1. Enable JIT, then open **Library → Steam → Download & install Steam**.
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
`C:\Madeira\Downloads\SteamSetup.exe` before launch.

## Status and limitations

This integration is experimental. Host checks validate parsing, installation
discovery, path containment, profile migration and launch routing. The IPA build
validates compilation and packaging. They do not demonstrate a successful Steam
login, download, DRM check or game launch on iOS.

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
existing CEF host accommodations remain in place; no new native emulator patches
or account-protection workarounds are part of this change.

## Diagnosis and rollback

Add these settings to `madeira-env.txt` when needed:

| Setting | Effect |
| --- | --- |
| `MADEIRA_STEAM=0` | Disable Steam integration and Steam-managed launches. Existing direct-executable entries are unaffected. |
| `MADEIRA_STEAM_COMPAT=0` | Omit the client launch flags `-no-cef-sandbox -cef-disable-gpu -nocrashmonitor` for an A/B test. Existing native CEF policy is unchanged. |
| `MADEIRA_COMPACT_API_BADGE=0` | Restore the full detected API chain on badges. |

`[steam-bridge] ml1260` records feature state, scans, installer stages and session
kind/App ID. It does not log credentials. For a device failure, include the
Madeira log and the stage reached: installer, bootstrap/update, login, download,
or application launch. Relevant native tags include `[WineProc]`,
`[session-handoff]`, `[wow-capacity]`, `[wow-placement]` and CEF diagnostics.
Steam's own `logs` directory may be needed for login/update problems; redact
account identifiers and tokens before sharing those files.

## References

- [Valve's official client download](https://store.steampowered.com/about/)
- [Valve's owned-library Web API](https://partner.steamgames.com/doc/webapi/IPlayerService)
  requires an API key and library visibility; it is not a download or login API.
