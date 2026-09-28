#!/usr/bin/env python3
"""Front end Settings: display rate, swap tier and madsync.

1. Swift: compiles the production MadeiraConfig (app/Madeira/MadeiraConfig.swift)
   with HOME pointed at a scratch directory and checks MadeiraConfig.set():
   it keeps comments and other keys, replaces earlier lines for the key,
   removes a key for nil, migrates legacy madeira-*.txt files before creating
   madeira.cfg, and MadeiraConfig.flag() reads env.NAME lines.
2. Source checks on app/Madeira/Library.swift and FPSOverlay.swift: the
   defaults are main's (swap tier off, madsync on, display-rate hold off), the
   Madsync toggle writes inproc-sync = 0 only when switched off, and
   MADEIRA_RUNTIME_SETTINGS=0 hides both sections.

Run from anywhere; needs `swift` on PATH.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
config = (root / 'app/Madeira/MadeiraConfig.swift').read_text()
lib = (root / 'app/Madeira/Library.swift').read_text()
fps = (root / 'app/Madeira/FPSOverlay.swift').read_text()
failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


swift = config + r'''
var failed = 0
func expect(_ cond: Bool, _ what: String) { print((cond ? "PASS: " : "FAIL: ") + what); if !cond { failed += 1 } }
let docs = MadeiraConfig.documents!
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
let cfg = docs.appendingPathComponent("madeira.cfg")

// No madeira.cfg, one legacy file: set() migrates it first, so it is not hidden.
try! "2048\n".write(to: docs.appendingPathComponent("madeira-vram-mb.txt"), atomically: true, encoding: .utf8)
expect(!MadeiraConfig.present, "no madeira.cfg at the start")
expect(MadeiraConfig.set("swap-mb", "1024"), "set() creates madeira.cfg")
expect(MadeiraConfig.get("vram-mb") == "2048" && MadeiraConfig.get("swap-mb") == "1024", "legacy value migrated, new key written")

// Comments and other keys survive; the key's earlier lines are replaced.
try! "# my notes\nswap-mb = 4096\nwx = 1\nswap-mb=2048\nenv.MADEIRA_PROMOTE = 0\n".write(to: cfg, atomically: true, encoding: .utf8)
MadeiraConfig.set("swap-mb", "1024")
let text = try! String(contentsOf: cfg, encoding: .utf8)
expect(text.contains("# my notes") && text.contains("wx = 1"), "comments and other keys are kept")
expect(text.components(separatedBy: "swap-mb").count == 2 && MadeiraConfig.get("swap-mb") == "1024", "one line for the key, new value")
expect(!MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "env.MADEIRA_PROMOTE = 0 reads as off")
MadeiraConfig.set("env.MADEIRA_PROMOTE", "1")
expect(MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "env.MADEIRA_PROMOTE = 1 reads as on")
MadeiraConfig.set("env.MADEIRA_PROMOTE", nil)
expect(!MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false), "removed key: the fallback (off)")
expect(MadeiraConfig.flag("MADEIRA_SOMETHING_ELSE"), "unset flags use their fallback (on)")
MadeiraConfig.set("inproc-sync", "0")
expect(!MadeiraConfig.bool("inproc-sync", default: true), "madsync off is inproc-sync = 0")
MadeiraConfig.set("inproc-sync", nil)
expect(MadeiraConfig.bool("inproc-sync", default: true), "madsync on removes the key (main's default)")
exit(failed == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory() as tmp:
    sp = Path(tmp) / 'settings.swift'
    sp.write_text(swift)
    home = Path(tmp) / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    r = subprocess.run(['swift', str(sp)], capture_output=True, text=True, env=env)
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.stdout.write(r.stderr[-4000:])
        failures.append('swift harness')

settings = lib[lib.index('struct RuntimeMemorySyncSettings: View'):lib.index('struct LibraryPointerSettings: View')]
display = lib[lib.index('struct DisplayRateSettings: View'):lib.index('struct RuntimeMemorySyncSettings: View')]
check('MadeiraConfig.bool("inproc-sync", default: true)' in settings, 'madsync shows on unless madeira.cfg says otherwise')
check('MadeiraConfig.set("inproc-sync", on ? nil : "0")' in settings, 'Madsync off writes inproc-sync = 0; on removes the key')
check('static let swapChoices = [0, 1024, 2048, 4096]' in settings and 'mb > 0 ? String(mb) : nil' in settings,
      'swap tier: Off removes swap-mb (off by default)')
check('@State private var hold = ProMotionIntent.holdMaximum' in display
      and 'MadeiraConfig.set("env.MADEIRA_PROMOTE", on ? "1" : nil)' in display, 'display-rate hold writes env.MADEIRA_PROMOTE')
check('static var holdMaximum: Bool { MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false) }' in fps,
      'display-rate hold is off by default')
check('if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") {\n                DisplayRateSettings()\n                RuntimeMemorySyncSettings()' in lib,
      'MADEIRA_RUNTIME_SETTINGS=0 hides both sections')
print('check-runtime-settings:', 'FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
