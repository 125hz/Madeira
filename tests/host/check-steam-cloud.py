#!/usr/bin/env python3
"""Steam Cloud sync decisions (app/Madeira/SteamCloud.swift SteamCloudPlan); no Steam runs.
Compiles the production SteamCloudEntry and SteamCloudPlan and checks what each comparison
leads to against the record of the last sync: one-sided changes are copied, two-sided ones
wait for a choice, and a save synced before that is now missing on this device is a choice
whose mark keeps a new save of that name from going up over the cloud's copy unasked (the
reset-prefix case). Source checks: Steam Cloud is off unless turned on, every upload that
replaces a cloud file backs up the cloud's copy first, and backups are in Documents.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


cloud = (app / 'SteamCloud.swift').read_text()
owned = (app / 'SteamOwnedLibrary.swift').read_text()
entry = cloud[cloud.index('/// One save file, on either side or both.'):cloud.index('/// How one app\'s cloud and local save files compare.')]
plan = cloud[cloud.index('// MARK: - What to do with a comparison'):cloud.index('// MARK: - Upload')]

# ------------------------------------------------------------------ static
require('SteamSignIn.flag("MADEIRA_STEAM_CLOUD", default: false)' in owned,
        'Steam Cloud is off unless turned on (env.MADEIRA_STEAM_CLOUD = 1)')
upload = owned[owned.index('private func upload(_ appID: Int'):owned.index('// MARK: Before Play')]
require(upload.index('cloudFile(appID, entry)') < upload.index('.cloudBeginAppUploadBatch'),
        "an upload fetches the cloud's copy of every file it replaces before the batch opens")
require('appendingPathComponent("cloud", isDirectory: true)' in upload,
        "the cloud's copies go to the backup's cloud/ folder")
require('urls(for: .documentDirectory' in owned and '"Steam Cloud Backups"' in owned,
        'backups are in Documents (Files › Madeira › Steam Cloud Backups)')
require('$0.kind == .cloudOnly' in owned[owned.index('func resolveCloud'):owned.index('private func download(')],
        "keeping this device's side leaves a missing save missing instead of uploading nothing")

# ------------------------------------------------------------------ Swift
main = r'''
import Foundation
struct SteamCloudAudit { var entries: [SteamCloudEntry] = [] }

var failed = 0
func check(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label); if !ok { failed += 1 } }

func sha(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }
func hex(_ byte: UInt8) -> String { SteamCloudPlan.hex(sha(byte)) }
let path = "%WinAppDataLocalLow%Studio/Game/save.dat"
let key = path.lowercased()
func e(_ kind: SteamCloudEntry.Kind, cloud: UInt8? = nil, local: UInt8? = nil) -> SteamCloudEntry {
    var x = SteamCloudEntry(path: path, kind: kind)
    if let cloud { x.cloudSHA = sha(cloud) }
    if let local { x.localSHA = sha(local) }
    return x
}
func plan(_ x: SteamCloudEntry, _ known: String?) -> SteamCloudPlan {
    SteamCloudPlan.make(audit: SteamCloudAudit(entries: [x]), baseline: known.map { [key: $0] } ?? [:])
}
func only(_ p: SteamCloudPlan) -> String {
    p.download.count == 1 && p.upload.isEmpty && p.conflicts.isEmpty ? "download"
    : p.upload.count == 1 && p.download.isEmpty && p.conflicts.isEmpty ? "upload"
    : p.conflicts.count == 1 && p.download.isEmpty && p.upload.isEmpty ? "ask"
    : p.download.isEmpty && p.upload.isEmpty && p.conflicts.isEmpty ? "nothing" : "mixed"
}

// One-sided changes are copied; two-sided ones and no record wait for a choice.
check(only(plan(e(.differ, cloud: 1, local: 2), hex(1))) == "upload", "changed on this device only: uploaded")
check(only(plan(e(.differ, cloud: 2, local: 1), hex(1))) == "download", "changed in the cloud only: downloaded")
check(only(plan(e(.differ, cloud: 2, local: 3), hex(1))) == "ask", "changed on both sides: a choice")
check(only(plan(e(.differ, cloud: 2, local: 3), nil)) == "ask", "different with no record: a choice")
check(only(plan(e(.cloudOnly, cloud: 1), nil)) == "download", "new in the cloud: downloaded")
check(only(plan(e(.localOnly, local: 1), nil)) == "upload", "new on this device: uploaded")
check(only(plan(e(.localOnly, local: 1), hex(1))) == "nothing", "deleted in the cloud: not sent back")
let same = plan(e(.same, cloud: 4, local: 4), SteamCloudPlan.missingMark + hex(1))
check(only(same) == "nothing" && same.settled[key] == hex(4), "identical on both sides: recorded, replacing any mark")

// Synced before, missing on this device now: a choice, and the record is marked.
let lost = plan(e(.cloudOnly, cloud: 1), hex(1))
check(only(lost) == "ask", "synced before and missing here: a choice, not ignored")
check(lost.settled[key] == SteamCloudPlan.missingMark + hex(1), "  and the record is marked missing")
check(only(plan(e(.cloudOnly, cloud: 1), SteamCloudPlan.missingMark + hex(1))) == "ask", "  still a choice while marked")
check(plan(e(.cloudOnly, cloud: 1), SteamCloudPlan.missingMark + hex(1)).settled.isEmpty, "  the mark is not rewritten")

// The reset-prefix case: the device lost the save, the game started fresh and wrote a
// new one, and the cloud still holds the synced progress. Without the mark this was a
// change on this device only, uploaded over the cloud's progress.
check(only(plan(e(.differ, cloud: 1, local: 9), hex(1))) == "upload", "(no mark: a fresh save would go up unasked)")
check(only(plan(e(.differ, cloud: 1, local: 9), SteamCloudPlan.missingMark + hex(1))) == "ask",
      "a save that reappears after it went missing: a choice, never uploaded unasked")
check(only(plan(e(.differ, cloud: 2, local: 9), SteamCloudPlan.missingMark + hex(1))) == "ask", "  also when the cloud moved on")

// The user chose to leave it missing.
let deleted = SteamCloudPlan.deletedMark + hex(1)
check(only(plan(e(.cloudOnly, cloud: 1), deleted)) == "nothing", "left missing by choice: not asked again")
check(only(plan(e(.cloudOnly, cloud: 2), deleted)) == "download", "  the cloud's copy changed since: downloaded (nothing here to lose)")
check(only(plan(e(.differ, cloud: 1, local: 9), deleted)) == "ask", "  a new save of that name later: a choice")

exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'main.swift'
    src.write_text('import Foundation\n' + entry + '\n' + plan + '\n' + main.replace('import Foundation\n', '', 1))
    out = Path(tmp) / 'cloud'
    build = subprocess.run([SWIFTC, '-O', str(src), '-o', str(out)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        require(False, 'the production SteamCloudPlan compiles on the host')
    else:
        run = subprocess.run([str(out)], capture_output=True, text=True)
        print(run.stdout, end='')
        if run.returncode != 0:
            failures += 1

print('\n%s' % ('ALL PASS' if failures == 0 else '%d FAILURE(S)' % failures))
sys.exit(0 if failures == 0 else 1)
