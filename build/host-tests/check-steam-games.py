#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Installed Steam games in the library (app/Madeira/SteamGames.swift), on the host.

1. Swift: compiles the production SteamGamesRules with Madeira Dock's production
   discovery (MadeiraDock.games / game(manifest:), sliced as in
   check-dock-contract.py, and SteamKeyValues.swift) and checks, on a synthetic
   drive_c laid out as Steam's client writes it, that installed and partly
   installed games are found, plus the section, search, Play-blocker and
   artwork rules.
2. Source checks: the section uses Dock's discovery and Dock's launch path
   only (no environment, sign-in transfer, token or Wine call of its own), no
   program-name list, no account data in a log line, wired into the library,
   built by the Xcode project.

Synthetic data only: no Steam, Wine or credentials.
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


games = (app / 'SteamGames.swift').read_text()
dock = (app / 'MadeiraDock.swift').read_text()
library = (app / 'Library.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
rules = games[games.index('// MARK: - Rules'):games.index('// MARK: - Model')]

# ------------------------------------------------------------------ static
require(games.startswith('// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright 2026 125hz\n'
                         '// Madeira Converter Exception: see LICENSE-EXCEPTION.md\n'),
        'SteamGames.swift: GPL-3.0-or-later, Copyright 2026 125hz, Converter Exception')
require('/* SteamGames.swift in Sources */,' in project and 'path = "SteamGames.swift"' in project,
        'SteamGames.swift is built by the Xcode project')
require('SteamGamesSection(search: search, startDock: startDock)' in library, 'Library: the Steam section is in the library')
require('MadeiraDock.games(drive: drive)' in games and 'let drive = MadeiraDock.drive' in games,
        "the section lists exactly what Dock's own discovery finds")
require('startDock(game, dock.compactPool)' in games and games.count('startDock(') == 1,
        "Play goes through Dock's launch path, with Dock's per-launch pool toggle")
for forbidden in ['setenv(', 'unsetenv(', 'runWineFullSequence', 'writeHandoff', 'credentialsForDock', 'SteamTokenStore',
                  'refreshToken', 'SecItem', 'MADEIRA_EXE', 'MADEIRA_ARGS', 'jit_', 'JITPool', 'poolSize',
                  'steamwebhelper', 'steam.exe', 'SteamSetup', 'FEX_', 'DXMT']:
    require(forbidden not in games, f'SteamGames.swift: no {forbidden}')
require(not re.findall(r'"[^"\n]*\.exe"', games), 'SteamGames.swift: no program names')
for line in games.splitlines():
    if re.search(r'LogStore|SteamLog\.|print\(|NSLog|fputs', line):
        require(re.search(r'\\\((game\.name|name|account|token|signIn|path|folder|status|error)', line) is None,
                f'no account data, name or path in "{line.strip()[:70]}"')
require(re.search(r'\bView\b|SwiftUI', rules.replace('// MARK: - Rules', '')) is None, 'the rules are Foundation-only')

# ------------------------------------------------------------------ compiled
head = dock[dock.index('enum DockPerformancePolicy {'):dock.index('enum MadeiraDock {')]
body = (dock[dock.index('enum MadeiraDock {'):dock.index('    @MainActor private static var lastReport =')] +
        dock[dock.index("    /// The host's environment for one launch."):])
stubs = r'''
import Foundation
import Glibc
enum SteamSignIn {
    static func flag(_ name: String, default fallback: Bool) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? fallback }
}
enum SteamLog { static func event(_ m: String) {}; static func trace(_ m: @autoclosure () -> String) {} }
enum SteamRuntimeFiles {
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"
}
'''
checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
func record(_ appID: Int, _ name: String, _ folder: String, flags: Int) -> String {
    "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"Universe\"\t\t\"1\"\n\t\"name\"\t\t\"\(name)\"\n\t\"StateFlags\"\t\t\"\(flags)\"\n" +
    "\t\"installdir\"\t\t\"\(folder)\"\n\t\"buildid\"\t\t\"100\"\n}\n"
}

@main struct Checks {
    static func main() throws {
        typealias R = SteamGamesRules
        let fm = FileManager.default
        let drive = fm.temporaryDirectory.appendingPathComponent("madeira-steam-games-" + UUID().uuidString)
        defer { try? fm.removeItem(at: drive) }
        // Madeira's Steam library, as Steam's client lays it out.
        let apps = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        try write(apps.appendingPathComponent("appmanifest_4242.acf"), record(4242, "Fixture Game", "Fixture Game", flags: 4))
        try fm.createDirectory(at: apps.appendingPathComponent("common/Fixture Game"), withIntermediateDirectories: true)
        try write(apps.appendingPathComponent("appmanifest_4343.acf"), record(4343, "Second Fixture", "Second", flags: 1026))
        try write(apps.appendingPathComponent("appmanifest_bad.acf"), "not a record")
        try write(apps.appendingPathComponent("appmanifest_4444.acf"), record(4444, "Escape", "../x", flags: 4))

        let found = MadeiraDock.games(drive: drive)
        require(found.map(\.id) == [4242, 4343], "Dock's discovery finds the valid records, sorted by name: \(found.map(\.id))")
        let first = found.first { $0.id == 4242 }
        require(first?.installed == true && first?.installDir == "Fixture Game" && first?.library == "Program Files (x86)/Steam/steamapps",
                "a fully installed game (StateFlags 4) in Madeira's Steam library")
        require(found.first { $0.id == 4343 }?.installed == false, "an update in progress is not offered for Play")
        require(first?.windowsInstallPath == "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game", "Windows install path")

        require(R.showsSection(dock: true, count: 2), "section shown with Dock and games")
        require(!R.showsSection(dock: false, count: 2), "no section without Dock (MADEIRA_DOCK=0 or no host)")
        require(!R.showsSection(dock: true, count: 0), "no empty section")
        require(R.matching(found, search: "").count == 2 && R.matching(found, search: "  ").count == 2, "empty search shows all")
        require(R.matching(found, search: "second").map(\.id) == [4343], "search is case-insensitive on the name")
        require(R.matching(found, search: "nothing").isEmpty, "search without a match")

        require(R.blocker(installed: true, client: true, signedIn: true) == nil, "Play offered when installed, client ready, signed in")
        require(R.blocker(installed: false, client: true, signedIn: true)?.contains("fully installed") == true, "not installed first")
        require(R.blocker(installed: true, client: false, signedIn: true)?.contains("client components") == true, "client components next")
        require(R.blocker(installed: true, client: true, signedIn: false)?.contains("Sign in") == true, "sign-in last")

        let cover = R.cover(4242)
        require(cover?.scheme == "https" && cover?.host == "cdn.cloudflare.steamstatic.com" && cover?.path.contains("/4242/") == true,
                "artwork from Steam's public store CDN by App ID")
        require(R.cover(0) == nil, "no artwork URL for an invalid App ID")
        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all Steam games Swift checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-steam-games-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + head)
    (tmp / 'dock.swift').write_text('import Foundation\nimport Glibc\n' + body)
    (tmp / 'rules.swift').write_text('import Foundation\n' + rules)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                            str(tmp / 'stubs.swift'), str(tmp / 'dock.swift'), str(tmp / 'rules.swift'),
                            str(tmp / 'checks.swift'), str(app / 'SteamKeyValues.swift')], capture_output=True, text=True)
    require(build.returncode == 0, 'production Steam games rules and Dock discovery compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-4000:])
    else:
        run = subprocess.run([str(exe)], env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'), capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-4000:])
        require(run.returncode == 0, 'Steam games checks pass under AddressSanitizer')

if failures:
    print(f'check-steam-games: {failures} FAILED')
    sys.exit(1)
print('check-steam-games: PASS')
