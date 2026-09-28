#!/usr/bin/env python3
"""ml2012: MadeiraConfig.set keeps comments and other keys, replaces a key's value,
removes a key with nil, and the Settings sync-engine rules map to exactly one engine.
Compiles the production MadeiraConfig.swift with a temporary HOME (Documents)."""
import os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get("SWIFTC") or shutil.which("swiftc") or os.path.expanduser("~/.local/share/swiftly/bin/swiftc")
config = (ROOT / "app/Madeira/MadeiraConfig.swift").read_text(encoding="utf-8")
# ml2013: Linux Foundation resolves .documentDirectory from the passwd home, not $HOME,
# so the unpatched copy wrote the developer's real ~/Documents/madeira.cfg. Point the
# test copy at $HOME/Documents (what iOS returns inside the app container).
DOCS_EXPR = "FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first"
assert DOCS_EXPR in config
config = config.replace(DOCS_EXPR, 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]! + "/Documents")')
library = (ROOT / "app/Madeira/Library.swift").read_text(encoding="utf-8")

# Source checks on the Settings section (SwiftUI is not available on the host).
for needle in ['struct RuntimeMemorySyncSettings', 'MadeiraConfig.set("swap-mb"', 'MadeiraConfig.set("inproc-sync", "1")',
               'MadeiraConfig.set("env.MADEIRA_FASTSYNC", "0")', 'LibraryFlags.enabled("MADEIRA_RUNTIME_SETTINGS")',
               '[runtime-settings] ml2012']:
    assert needle in library, needle

harness = r'''
import Foundation
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
let url = MadeiraConfig.url!
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try! "# keep me\npool = 896\nswap-mb = 512\nenv.OTHER = 1\n".write(to: url, atomically: true, encoding: .utf8)
check(MadeiraConfig.set("swap-mb", "2048"), "set returns true")
check(MadeiraConfig.get("swap-mb") == "2048", "value replaced")
check(MadeiraConfig.get("pool") == "896" && MadeiraConfig.get("env.OTHER") == "1", "other keys kept")
let text = try! String(contentsOf: url, encoding: .utf8)
check(text.contains("# keep me"), "comment kept")
check(text.components(separatedBy: "swap-mb").count == 2, "only one swap-mb line")
MadeiraConfig.set("swap-mb", nil)
check(MadeiraConfig.get("swap-mb") == nil, "nil removes")
MadeiraConfig.set("inproc-sync", "1"); MadeiraConfig.set("env.MADEIRA_FASTSYNC", "0")
check(MadeiraConfig.bool("inproc-sync") && MadeiraConfig.get("env.MADEIRA_FASTSYNC") == "0", "madsync selection")
MadeiraConfig.set("inproc-sync", nil); MadeiraConfig.set("env.MADEIRA_FASTSYNC", nil)
check(!MadeiraConfig.bool("inproc-sync") && MadeiraConfig.get("env.MADEIRA_FASTSYNC") == nil, "fastsync selection restores defaults")
print("PASS: MadeiraConfig.set keeps comments/other keys, replaces and removes; sync-engine keys exclusive")
'''

with tempfile.TemporaryDirectory(prefix="madeira-runtime-settings-") as tmp:
    tmp = Path(tmp)
    (tmp / "MadeiraConfig.swift").write_text(config, encoding="utf-8")
    (tmp / "main.swift").write_text(harness, encoding="utf-8")
    subprocess.run([SWIFTC, str(tmp / "MadeiraConfig.swift"), str(tmp / "main.swift"), "-o", str(tmp / "check")], check=True)
    env = dict(os.environ, HOME=str(tmp / "home"))
    (tmp / "home" / "Documents").mkdir(parents=True)
    subprocess.run([str(tmp / "check")], check=True, env=env)
print("PASS: runtime settings source checks")
