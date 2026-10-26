# Epic Games

Madeira can sign in to Epic, list owned Windows games, download them, and start
them through Wine and FEX. It does not install the Epic launcher. The protocol
work follows [Legendary](https://github.com/derrod/legendary).

## Source

- `app/Madeira/SwiftEpic/EpicAPI.swift`: OAuth, the device-only Keychain token
  item, owned assets, catalog metadata, manifests, content keys, and launch codes.
- `app/Madeira/SwiftEpic/EpicFormats.swift`: the shared game and cloud manifest
  and chunk readers, decryption, checksums, and streaming file hashes.
- `app/Madeira/SwiftEpic/EpicDownloader.swift`: install, update, repair, CDN
  fallback, bounded concurrent chunk downloads, and the resume journal.
- `app/Madeira/EpicLibrary.swift`: the account, installed records, download
  queue, library entries, and temporary launch arguments.
- `app/Madeira/EpicGames.swift`: sign-in, library, download, and game-detail views.
- `app/Madeira/SwiftEpic/EpicCloudSaves.swift`: cloud transport, save formats,
  folder rules, scan, and sync decisions.
- `app/Madeira/EpicCloud.swift`: cloud state, settings, conflicts, and backups.

## Account and game files

Sign in under Settings > Epic Games. Madeira exchanges an authorization code
from Epic's sign-in page. Tokens stay in the Keychain. The game list uses the
account's Windows assets. Epic checks ownership when it serves a build.

The downloader reads binary and JSON manifests. It supports encrypted file
lists and encrypted chunks when Epic supplies their content keys. It rejects
unsupported formats and verifies downloaded chunks and assembled files.

Installs use `drive_c/Program Files/Epic Games/<folder>`. Paths are checked against
that folder. Downloads spool to disk and check free space before assembly.
Pause keeps finished files. A journal lets Resume skip finished files. Update
keeps files that the installed and new manifests identify as unchanged. Repair
checks every installed file's hash. Cancel removes a partial first install;
it stops an update or repair without deleting the installed game.

Epic and Steam use the same background-download helper with separate task
identifiers. Downloads pause for a game session. Background work depends on iOS
scheduling and permission. Uninstall removes the game directory and library
entry, including saves that the game kept inside that directory.

Play obtains a one-use exchange code just before launch. The code goes into the
temporary arguments, not the saved game profile. The Wine argument log hides
`-AUTH_PASSWORD`. Games that require unsupported anti-cheat, another launcher,
or an overlay can still fail. The game details include an offline launch option
for the supported Easy Anti-Cheat case.

The Rocket League runtime changes retain safe diagnostic reads, an explicit
`faultrep` module build, and persistent shader-cache defaults. A runtime rebuild
also needs the system-UCRT loader policy in
[Wine #58](https://github.com/willfaust/wine/pull/58) and the emulator callback
shutdown fix in [Wine #30](https://github.com/willfaust/wine/pull/30). This source
change keeps the current main branch's Wine pin and bundled DLLs. It does not
replace them with the older artifacts from the original Epic branch.

## Cloud saves

Cloud sync is on by default. Automatic upload is off by default. Settings >
Epic Games has both switches. The configuration keys are
`env.MADEIRA_EPIC_CLOUD` (0 disables sync) and
`env.MADEIRA_EPIC_CLOUD_AUTO_UPLOAD` (1 enables automatic upload).

The catalog's `CloudSaveFolder`, `CloudIncludeList`, and `CloudExcludeList`
attributes define the save set. Supported variables are `{AppData}`, `{UserDir}`,
`{UserProfile}`, `{UserSavedGames}`, `{InstallDir}`, and `{EpicID}`. Folder names
match without regard to case. Paths must stay inside the Wine drive. Scans do
not follow symbolic links. Each sync allows at most 2,000 files and 128 MiB.

Madeira compares file hashes with the last agreed state for this account:

- Only the cloud changed: download it.
- Only the device changed: upload on Sync now, or with automatic upload enabled.
- Both changed, or there is no common record: ask which copy to keep.
- Both match: record the common state.

Checks run at startup, after sign-in, and when the game page opens. Sync does
not start while a game runs. Launch waits while a save sync is active. A changed
account or game session stops the sync before it writes files or publishes an
upload. After a game, use Sync now or let the next startup check the saves.

A download verifies all chunks, file hashes, and target paths before it writes
any file. Each replacement first gets a backup under Files > Madeira > Epic
Cloud Backups. Writes are atomic per file. A later disk or backup error can
still stop a multi-file write; this is not a whole-folder transaction. Files
absent from the snapshot stay on the device.

An upload rechecks the scanned files, writes chunks first, and writes the
manifest last. It creates a new snapshot and does not delete older snapshots.
The snapshot format uses feature-level 18 manifests and version 3 chunks, as
Legendary does. Save reads use the same format code as game downloads. Encrypted
save snapshots without content keys are not supported.

## Checks and limits

`python3 tests/host/check-epic-games.py` compiles the production format reader and
downloader. Local fixtures cover plain and encrypted builds, JSON manifests,
CDN fallback, pause/resume, update, repair, wrong keys, and hostile input. Install
`cryptography` in the test environment to include encrypted fixtures.

`LEGENDARY_SRC=/path/to/legendary python3 tests/host/check-epic-cloud.py` compiles
the production shared reader and cloud code. It checks sync decisions and folder
rules, reads Swift saves with Legendary, restores Legendary saves with Swift,
and checks backups, dates, damaged data, invalid paths, symbolic links, and a
rejected account/session check. Without Legendary, only the self-tests run.

The combined code passed these host checks and the full app's Swift type check.
The simulator app build stopped because the checkout lacks the private
`x86_64-vcruntime` resource. Live Epic login, cloud service writes, background
execution, UI control clicks, and Wine/FEX gameplay still need device checks.

## Credits

The game client comes from Akshay CM's Madeira #265. The cloud save code and
interoperability fixtures come from Tabîrcă Nicolae-Eduard's Madeira #207.

Legendary's protocol and format work is GPL-3.0-or-later, by derrod and
contributors. Relevant sources include `legendary/api/egs.py`,
`models/manifest.py`, `models/json_manifest.py`, `models/chunk.py`,
`downloader/mp/manager.py`, `downloader/mp/workers.py`,
`utils/savegame_helper.py`, `utils/rolling_hash.py`, and `core.py`.
The app uses Apple frameworks and zlib. It adds no Python runtime or package
dependency to Madeira.
