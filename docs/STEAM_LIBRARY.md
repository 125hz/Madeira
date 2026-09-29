# Steam library and downloads

Madeira shows the games a Steam account owns, installs and updates them from
Steam's content servers, and removes them again. An installed game starts
through Madeira Dock like any other Steam game in the prefix.

The code is `app/Madeira/SteamOwnedLibrary.swift` (the model),
`app/Madeira/SteamGames.swift` (the library's Steam section and the game
sheet), `app/Madeira/SteamInstall.swift` (where a download lives and how one is
removed), `app/Madeira/SteamDownloadBackground.swift`, and
`app/Madeira/SwiftSteam/` (the Steam connection, product info, depot
downloader, content decoders and install record writer).

## What you see

In the library, the **Steam** section (`docs/LIBRARY.md`, "Steam setup") lists
two kinds of game together: the games Steam has installed in the prefix, and
the account's owned games that are not installed yet. Installed games come
first. Each card shows the game's artwork, its state (**Madeira Dock**,
**Not installed**, **Update available**, **Downloading 42%**, **Paused**,
**Download failed**) and, when Steam knows it, the playtime. **Refresh** reads
the install records again and fetches the library again.

A card opens the game's sheet:

- **Install**, or **Play** (through Madeira Dock, with its per-launch pool
  toggle) for an installed game. A game that is being downloaded cannot be
  played.
- **Update** when Steam lists a newer build than the install record, for games
  in Madeira's own library folder.
- **Pause**, **Resume**, **Try again** and **Cancel download** while a download
  exists. Cancelling a first-time install deletes its partial files; cancelling
  an update only stops it.
- **Uninstall** (with a confirmation) for games in Madeira's own library folder.
  Games Steam's client installed in another library folder are shown and
  played, but Madeira does not modify them.
- Progress, speed and time left, the free space on the device, and a link to
  the game's Steam Store page.

Sign-in is not new: Settings › Steam and first-run setup (`docs/STEAM_SIGNIN.md`,
`docs/LIBRARY.md`) sign in and out. Signing in fetches the library; signing out
deletes the cached list and stops the downloads.

## How it works

**The library.** After sign-in, one Steam connection (a WebSocket over TLS to a
Steam connection-manager server from Valve's public server directory) logs on
with the stored refresh token and reads the license list Steam pushes. The
licenses name packages, the packages name apps, and Steam's product-info
service (PICS) describes each app. Only playable types (games, demos,
applications) with a Windows depot are kept. The list is cached in
Application Support (`steam-library.json`, with a hash of the account name it belongs
to; removed at sign-out) and refreshed when it is older than six hours. Steam's
own playtime record for the account comes from `Player.GetOwnedGames` over the
same connection (`steam-playtime.json`).

**The token.** The connection reads the sign-in from `SteamSignIn` and never
stores a token of its own: there is no second Keychain item and no token in
UserDefaults or a file. The connection is closed after 60 seconds of no use and
opens again when needed.

**A download.** Steam issues a depot key and a manifest request code only to an
account that owns the depot, so ownership is Steam's decision, not Madeira's.

1. Product info of the app (and of the apps whose depots it shares) selects the
   Windows, English, 64-bit (else 32-bit) depots, without DLC, redistributables
   or regional alternates.
2. For each depot: the depot key, the manifest request code, a per-server
   authorization token, then the manifest from a content server (a single-entry
   zip; older depots encrypt the manifest as a whole). File names in a manifest
   are encrypted with the depot key.
3. Files are created at their manifest size, and chunks are fetched by up to
   eight tasks. A chunk is decrypted (AES-256, the IV first), decompressed
   (zstd, LZMA or zip, whichever container Steam served), checked against its
   size and Steam's Adler-32, and written in place. A failed chunk is retried on
   another content server; servers that keep failing move to the back of the
   rotation. Content servers come from Valve's directory and must be Valve's
   own hosts, over HTTPS.
4. Finished chunks are journaled under `steamapps/downloading/<appid>`. An
   interrupted, paused or failed install resumes without fetching them again,
   and bytes already on disk that match a chunk's SHA-1 are kept (an update, or a
   resume after the journal's last lines were lost).
5. Manifest paths are validated to stay inside the install folder (no `..`,
   drive letters or control characters; symlink entries are skipped), and
   directory spellings are folded case-insensitively, as on Windows.
6. Last, `appmanifest_<appid>.acf` is written. Until then the game is not
   installed for Madeira Dock, so a partial download is never offered for Play.

Games with depots shared from another app also get the owner app's own record,
because Valve's client refuses to start a game before it. A file Valve's client
must customize per user before it runs is listed in the record (`CheckGuid`) and
its depot's manifest is kept in `steamapps/depotcache`, as the client expects.
Nothing here alters, unpacks or replaces a game's files, and there is no
emulation of Steam, tickets or DRM: the game starts through Valve's own client,
which signs in and checks the license (`docs/MADEIRA_DOCK.md`).

**Where.** Downloads go to Madeira Dock's own Steam library folder,
`C:\Program Files (x86)\Steam\steamapps` in the prefix, as
`common/<installdir>` and the install record beside it. That is exactly the
layout Madeira Dock's discovery reads (`MadeiraDock.games`) and Valve's client
understands; `build/host-tests/check-steam-library.py` writes an install with
the production downloader and has Dock's own scanner find it.

**Sessions.** A game session pauses downloads (memory and I/O belong to the
game) and closes the Steam connection before Valve's client signs in with the
same account, which would otherwise log one of the two out. Downloads continue
when the session has ended and the library is back. Madeira does not start more
than one session per app run (`docs/LIBRARY.md`).

**Leaving Madeira.** A running download asks iOS for the usual short background
grace period. When that ends, or is refused, the download pauses and continues
when Madeira is opened again. This uses no background mode, no background task
identifier and no notification permission; `Info.plist` is unchanged. Keep
Madeira open while a large game downloads.

## Switches

`env.MADEIRA_STEAM_LIBRARY = 0` in `Documents/madeira.cfg` turns the owned
library and downloads off (the Steam section then lists installed games only, as
before). The library also stays off without Madeira Dock, because a downloaded
game starts through it. `env.MADEIRA_STEAM_TRACE = 1` adds protocol trace lines
(message names and result codes, never payloads or credentials). There are no
other switches.

## Logs

`[steam-library]`, `[steam-depot]`, `[steam-cdn]`, `[steam-shared]`,
`[steam-shared-record]`, `[steam-record]`, `[steam-playtime]`, `[steam-account]`
and `[steam-games]`. They carry App IDs, depot IDs, counts and short reason
codes. No account name, Steam ID, token, game name or path is logged (the
host test checks this on a full install).

## 64-bit impact

None. This is app-side Swift and C that runs when the Steam section is used. It
starts no Wine session, sets no environment variable, and changes no JIT pool,
engine switch, Wine, FEX or DXMT code, and no `madeira.cfg` default. The one
line added to an existing code path is the call in `ContentView` that tells the
library a session starts (it pauses downloads and closes the connection; the
session itself is untouched).

## Provenance and licence audit

The Steam connection, library, product-info, depot-downloader, content-decoder
and install-record code is derived from **Jfishin's** Madeira Steam client (his
private fork; its Steam module is called SwiftSteam), used with his
permission (`docs/STEAM_SIGNIN.md`, "Provenance"). Jfishin also confirmed that he
wrote the depot downloader himself, in Swift, from how Steam's content system
works, and did not translate DepotDownloader's C#.

His permission covers this code as it covers sign-in, so the derived files are
GPL-3.0-or-later with the Madeira Converter Exception and say
`Copyright 2026 Jfishin, 125hz`. Files that are 125hz's own say
`Copyright 2026 125hz`. The zstd decoder keeps its own notice (Meta Platforms,
BSD-3-Clause selected from BSD / GPL-2.0).

**Why an audit.** The original says it follows "the DepotDownloader flow", and
DepotDownloader (SteamRE) is GPL-2.0 code that must not be translated into a
GPL-3.0-or-later work. SteamKit2 (LGPL-2.1) is the library it
sits on. Following the same protocol is fine; translated code is not.

**What was compared.** DepotDownloader `master` (ContentDownloader.cs,
Steam3Session.cs, CDNClientPool.cs, ProtoManifest.cs, Util.cs,
DepotConfigStore.cs) and SteamKit2 (`SteamKit2/Steam/CDN/DepotChunk.cs`,
`Client.cs`, `Server.cs`, `Types/DepotManifest.cs`, `Util/CryptoHelper.cs`,
`Util/Adler32.cs`), against every ported file. Two checks:

1. A shingle comparison of the code (comments removed, identifiers kept). A
   translation to another language changes the tokens, so this is weak evidence
   alone, but it found nothing: the longest run any file shares with any of
   those C# files is one 8-token sequence in the app-info parser
   (`branches = depots["branches"]`, a Steam key name) and a `for (i >= 0; i--)`
   loop in Meta's decoder; at 5 tokens the most any file shares is 14, Steam key
   names and loop idioms. The distinctive identifiers the two share are the
   protocol's words (`depotKey`, `manifestRequestCode`, `compressedSize`,
   `installDir`, `sizeOnDisk`).
2. A read of the flow side by side. The steps are the protocol's: ask for the
   depot key, the manifest request code and a CDN authorization, fetch and
   decrypt the manifest, fetch chunks, decrypt with the key (first block ECB, the
   rest CBC with PKCS7), decompress by container, check Adler-32 with seed 0, write
   at the chunk's offset. Where the two differ in structure:

| | DepotDownloader (C#) | this code |
|---|---|---|
| Steam access | SteamKit2 callback handlers on a `SteamClient` | raw protobuf messages on a WebSocket over TLS (`SteamConnection`, `SteamSession`) |
| Content servers | `CDNClientPool` weights servers by a persisted penalty list, `Server.NumEntries`, proxy server | Valve's directory over HTTPS, host filter by name and `https_support`, a per-install failure count, hosts rotate per chunk |
| Resume | per-file staging directory, old manifest kept in a config store, chunk diff by old/new manifest, file hash | append-only journal of finished chunk indices per depot manifest, SHA-1 of bytes already on disk |
| File writes | one `FileStream` per file with a lock, async writes | `pwrite` on the download task, files sized to the manifest first |
| Licensing check | `AccountHasAccess` reads package `appids`/`depotids` before every download | the license depot list is read only when Steam refuses a depot key, to leave out content the account does not own |
| Output | files only | files plus Steam's install record, shared-owner records and `depotcache` entries for Valve's client |

**Result.** No translated code was found, so nothing was rewritten for licence
reasons. What follows the protocol carries the protocol's names
(`depotKey`, `manifestRequestCode`, `compressedSize`, and Valve's field numbers),
which are interface facts. Comments that said the code was a port of
DepotDownloader, or named SteamKit2 or JavaSteam functions, now say the code
follows Steam's content protocol. The class is still called `DepotDownloader`,
as in Jfishin's tree; the name is generic.

| File | Non-blank lines | Lines identical to Jfishin's | Origin |
|---|---|---|---|
| `Core/CMServerList.swift` | 117 | 108 | Jfishin; header and comments |
| `Core/LicenseListBox.swift` | 49 | 42 | Jfishin; header |
| `Core/SteamConnection.swift` | 171 | 154 | Jfishin; header |
| `Core/SteamMessageCodec.swift` | 218 | 205 | Jfishin; header |
| `Core/SteamSession.swift` | 736 | 639 | Jfishin; logon with SteamSignIn's sign-in, `suspend()`/`resume()`, no token clearing, no channel encryption |
| `Core/SteamError.swift` | 108 | 60 | Jfishin (reduced in the sign-in PR, extended again with his connection, library and content errors) |
| `Core/SteamProtocol.swift` | 55 | n/a | Jfishin's message-type, result-code and service-method constants, reduced to what is used |
| `Core/SteamCMSession.swift` | 25 | n/a | 125hz (the protocol that lets tests script the connection) |
| `Proto/SteamProtoMessages.swift` | 810 | 767 | Jfishin (protobuf helpers and messages); the sign-in PR's hardened decoder is kept |
| `Content/ContentDecryptor.swift` | 232 | 153 | Jfishin; comments rewritten, zip container added, corrupt-zstd guard fixed |
| `Content/DepotDownloader.swift` | 732 | 209 | Jfishin's original (334 non-blank lines), substantially rewritten by 125hz: journal, resume, host rotation, records |
| `Content/DepotManifest.swift` | 175 | 163 | Jfishin; unused diff code removed |
| `Library/SteamAppInfo.swift` | 289 | 157 | Jfishin, extended (shared depots, artwork names); launch, Cloud and licence-agreement parts removed |
| `Library/SteamLibraryFetcher.swift` | 351 | 251 | Jfishin, extended (licensed depots, shared metadata); the hidden-app report removed |
| `Install/AppManifestWriter.swift` | 184 | 101 | Jfishin's record writer (176 lines, in a folder named DRM in his tree; it writes Steam's own `appmanifest` format and nothing else), extended by 125hz: installed depots, shared depots, `CheckGuid` |
| `lzma_shim.c/.h` | 85 | n/a | Jfishin |
| `zstd_edu.c/.h` | 2056 | n/a | Meta Platforms (BSD-3-Clause selected), with Jfishin's error-safe wrapper; 1,986 lines identical to his copy |
| `chunk_zip.c/.h` | 73 | n/a | 125hz |
| `SteamOwnedLibrary.swift` | 434 | n/a | 125hz; the model is adapted from the fork's account model around Jfishin's flows |
| `SteamInstall.swift` | 95 | n/a | 125hz |
| `SteamDownloadBackground.swift` | 54 | n/a | 125hz |
| `SteamGames.swift` | 510 | n/a | 125hz (#53's section, extended) |

The limit of this audit: it cannot prove how a file was originally written. It
rests on Jfishin's statement, on his tree carrying no third-party notice for
these files, and on the comparison above.

**Left out of his client, on purpose:** the channel encryption (which cites the
SteamKit2/JavaSteam key dictionary; the connection is TLS), Steam Cloud, the
launch, ticket and stub code and everything in his DRM folder except the
install record writer (which writes Steam's own `appmanifest` format and does
nothing else), and the Windows desktop client's installer and launch code.

## Tests

`build/host-tests/check-steam-library.py` (needs `swiftc` on Linux, `cc`,
`python3` with `cryptography` or the `openssl` command, and libssl, liblzma and
zlib development files; it never contacts Steam):

- static: licence headers, the Xcode project, no program names, no engine, pool
  or `Info.plist` change, no second token path, no account data in a log line;
- one AddressSanitizer executable built from the production Swift and C, with
  stand-ins for CommonCrypto (on OpenSSL), Compression and zlib and a scripted
  `SteamCMSession`:
  - units: message headers and codec (round trips, truncated and hostile
    input), logon, license and product-info messages, playtime, depot selection
    (language, architecture, DLC, redistributables, shared depots), the library
    fetcher against scripted product-info replies, the AES and container decoders
    on known vectors with wrong keys, checksums, truncation and hostile sizes,
    manifest path and folder rules;
  - installs, against a local HTTP content server with three hosts (one dead, one
    that corrupts the first answer per chunk, one healthy) and content
    authorization: every chunk container and an encrypted manifest; a shared
    depot; a depot the account does not own; hostile manifest paths; an
    interrupted install that resumes without refetching journaled chunks and is
    not listed as installed before its record exists; then Madeira Dock's own
    scanner (`MadeiraDock.games`) finds the finished install; an update that
    fetches one changed chunk and shrinks a file; uninstall.

`check-steam-games.py` covers the merge of installed and owned games, the
status text, artwork candidates and the Play rules; `check-steam-signin-native.py`
covers the module boundary (sign-in files hold no library code).

Not covered: a live logon to Steam and a download from Valve's content servers
from this branch (the protocol code is the fork's, which ran on the owner's
devices; see the pull request for what was and was not device-tested), the SwiftUI
views, iOS background-task behaviour, and running a downloaded game.

## Not included, and limits

- No Steam Cloud, no achievements, no workshop content, no DLC installation,
  no branch (beta) selection, no language selection: English, the public
  branch.
- A file that a newer build no longer contains is not deleted by an update
  (the install keeps it); **Uninstall** removes the whole folder.
- Only the account's licenses are read; family sharing and free-on-demand
  licenses are whatever Steam's license list contains.
- Games installed by Valve's client in another library folder are listed and
  played but not updated or removed here.
