# External drive safety

PR #464 supports several external folders. This change adapts useful safety
checks from David Brookes's PR #235 to that model.

- New writable registrations keep a `.madeira-library-id` UUID in the selected
  folder. Reopening that folder checks its identity before changing mappings.
  Existing registrations and read-only folders retain bookmark-only access.
- Invalid saved registrations stop registration changes. Real files and folders
  at mapping paths are kept. New registrations cannot take an existing link.
- Downloads keep their chosen library through pause, completion and repair.
  An unavailable external default stays external. A successful move updates the
  saved destination. Automatic deletion of stray partial installs is removed.
- Uninstall waits for the active downloader. It checks deletion paths and reports
  errors. It removes the main install record and library entry only after the
  preceding file operations succeed. A failed delete can leave a partial install
  that needs repair.
- Cloud audits and transfers check external folder availability and identity.
  GameInstall paths reject nested links. A missing drive cannot become an empty
  save audit. Reconnect clears failed checks and keeps unresolved save choices.
- Steam library metadata is parsed and updated with escaping. Existing app data,
  legacy entries and unrelated fields are kept. Invalid metadata is left alone.
- Encrypted download chunks must contain a full IV and complete cipher blocks.

The single-library settings, fixed E: mapping, separate storage catalog and
single-drive native resolver from #235 are not used. The existing multi-drive
interface and security-scoped bookmark lifetime remain in place.

## Checks

Run `python3 tests/host/check-external-storage.py`,
`python3 tests/host/check-steam-cloud.py`,
`python3 tests/host/check-steam-library.py` and
`python3 tests/host/check-steam-games.py`.
The storage fixture runs production path, mapping, identity, metadata and deletion
helpers against temporary files under AddressSanitizer. It also checks the saved
registration validator. The Steam library fixture runs real download and decoder
code against a local content server. On macOS it uses Apple's native crypto and
compression libraries; Linux retains the existing test shims.

Host checks and iOS Swift type checks do not prove physical drive behavior.
Before release, test folder-picker access, exFAT and APFS drives, unplug and
reconnect during reads and writes, paused-download resume after relaunch, cloud
save conflicts, moves and background expiration on iPad. Native Wine launch and
file-provider coordination also need device checks. The device results reported
in #235 apply to its own build.
