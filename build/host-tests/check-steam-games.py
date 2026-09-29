#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam games in the library (app/Madeira/SteamGames.swift), on the host.

1. Swift: compiles the production SteamGamesRules with Madeira Dock's production
   discovery (MadeiraDock.games / game(manifest:), sliced as in
   check-dock-contract.py, and SteamKeyValues.swift) and checks, on a synthetic
   drive_c laid out as Steam's client writes it, that installed and partly
   installed games are found, plus the section, search, Play-blocker and
   artwork rules, and the merge of installed and owned games (owned games come
   from the production SteamOwnedGame and SteamAppInfo).
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
owned_source = (app / 'SteamOwnedLibrary.swift').read_text()
fetcher = (app / 'SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
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
content_view = (app / 'ContentView.swift').read_text()
require('SteamGamesSection(search: search, open: { selected = $0 })' in library,
        "Library: the Steam section is in the library and opens the library's Game details page")
require('MadeiraDock.games(drive: drive)' in games and 'let drive = MadeiraDock.drive' in games,
        "the section lists exactly what Dock's own discovery finds")
# Game details: a Steam game is a library entry (its per-game settings) with a Steam section.
require('open(LibraryModel.shared.steamEntry(installed, title: item.name))' in games,
        'an installed Steam game opens its Game details page (its library entry)')
require(games.count('startDock(') == 0, 'the section never starts Dock itself: Play is on the Game details page')
# A finished download: the game becomes a library entry, and its sheet's button reads Open (Game details).
sheet = games[games.index('struct SteamGameSheet: View {'):games.index('struct SteamEntrySection')]
require('Text("Open")' in sheet and 'if let installed = item.installed {' in sheet and 'dismiss(); open(entry)' in sheet,
        "a finished download's sheet offers Open, which opens the Game details page")
require('SteamGameSheet(appID: selection.id) { entry in' in games and 'open(entry) }' in games,
        'Open presents the Game details page after the download sheet closes')
run_body = owned_source[owned_source.index('    private func run(_ appID: Int) async {'):]
run_body = run_body[:run_body.index('\n    }\n')]
require(run_body.index('try await downloader.install(') < run_body.index('LibraryModel.shared.upsertSteam(') < run_body.index('} catch {'),
        'a finished download (record written) gets its library entry; a failed or paused one does not')
require('LibraryModel.shared.removeSteam(appID: game.id)' in owned_source[owned_source.index('func uninstall(_ game: DockGame)'):],
        "Uninstall removes the game's library entry with its files")
detail = library[library.index('struct LibraryDetail: View {'):library.index('struct FPSChoice: View {')]
steam_section = games[games.index('struct SteamEntrySection'):]
require('SteamEntrySection(entry: $entry)' in detail and 'if entry.steamAppID != nil {' in detail,
        'Game details: the Steam section for a Steam game')
for label in ['"Start with"', '"Madeira Dock"', '"Smaller JIT pool (512 MB) for this launch"', '"One-time installs"',
              '"Run at next start"', '"Skip"', '"Repair installed files"', '"Uninstall"', '"App ID"',
              '"Free space on this device"', '"Pause update"', '"Resume update"']:
    require(label in steam_section, f'Steam section: {label}')
for label in ['"Library details"', '"Choose cover image"', '"Use Steam artwork"', '"Display"', '"Resolution"',
              '"Aspect & scaling"', '"Compatibility & performance"', '"Reduced-precision x87"', '"CPU cores reported"',
              '"D3D9 anisotropic filtering"', '"On screen"', '"Performance overlay"', '"Live logs"', '"Touch controls"',
              '"Control opacity"', '"Control size"', '"Executable"', '"Game details"']:
    require(label in detail, f'Game details: {label}')
require('if entry.desktop != true && entry.steamAppID == nil {' in detail,
        "no Launch arguments for a Steam game: Dock starts Steam's own launch option")
entries_start = library.index('private var entries: [LibraryEntry] {')
require('$0.steamAppID == nil' in library[entries_start:library.index('var body: some View {', entries_start)],
        'Steam games are listed in the Steam section only, not also under Games')
launch = content_view[content_view.index('private func launchLibraryEntry('):content_view.index('private func runWineFullSequence(')]
require('if let appID = entry.steamAppID {' in launch and
        'startDock(game, compactPool: MadeiraDockModel.shared.compactPool, profile: entry)' in launch,
        "Play on a Steam game's Game details page starts it through Madeira Dock with its own profile")
dock_start = content_view[content_view.index('private func startDock('):]
dock_start = dock_start[:dock_start.index('\n    }\n') + 6]
require('if let profile { library.begin(profile) }' in dock_start and 'runWineFullSequence(profile: profile)' in dock_start,
        "a Steam game's session takes its display, overlay and control settings")
configure = library[library.index('    func configureLaunch() {'):]
configure = configure[:configure.index('\n    }\n')]
require(configure.index('if steamAppID != nil {') < configure.index('setenv("MADEIRA_EXE"'),
        "a Steam game's profile never replaces what Madeira Dock starts")
apply = library[library.index('    func applyEnvironment() {'):]
apply = apply[:apply.index('\n    }\n')]
require('if let cpuCount, (1..<64).contains(cpuCount) { setenv("MADEIRA_CPU_COUNT"' in apply and
        'if let anisotropyLimit, [1, 2, 4, 8].contains(anisotropyLimit) { setenv("DXMT_D9_ANISO_LIMIT"' in apply and
        'unsetenv("MADEIRA_CPU_COUNT")' not in apply and 'unsetenv("DXMT_D9_ANISO_LIMIT")' not in apply,
        'CPU cores and anisotropic filtering are exported only when chosen (default behaviour unchanged)')
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
owned_game = owned_source[owned_source.index('struct SteamOwnedGame:'):owned_source.index('// MARK: - Playtime')]
vdf = fetcher[fetcher.index('// MARK: - Simple VDF Binary Parser'):]
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
        // The size a Game details page shows comes from the install record.
        try write(apps.appendingPathComponent("appmanifest_4545.acf"),
                  record(4545, "Sized", "Sized", flags: 4).replacingOccurrences(of: "\n}\n", with: "\n\t\"SizeOnDisk\"\t\t\"12345\"\n}\n"))
        require(SteamInstallFiles.sizeOnDisk(appID: 4545, steamApps: apps) == 12345 &&
                SteamInstallFiles.sizeOnDisk(appID: 4242, steamApps: apps) == nil, "install size from the record's SizeOnDisk")
        try fm.removeItem(at: apps.appendingPathComponent("appmanifest_4545.acf"))

        require(R.showsSection(dock: true, signedIn: false, count: 2), "section shown with Dock and games")
        require(!R.showsSection(dock: false, signedIn: true, count: 2), "no section without Dock (MADEIRA_DOCK=0 or no host)")
        require(!R.showsSection(dock: true, signedIn: false, count: 0), "no empty section without a sign-in")
        require(R.showsSection(dock: true, signedIn: true, count: 0), "signed in: the section shows while the library loads")
        require(R.showsSection(dock: true, library: true, signedIn: false, count: 0), "owned library on, signed out: the section shows to invite a sign-in")
        require(!R.showsSection(dock: false, library: true, signedIn: false, count: 0), "no section without Dock even with the library on")
        require(R.showsSignIn(library: true, signedIn: false) && !R.showsSignIn(library: true, signedIn: true)
                && !R.showsSignIn(library: false, signedIn: false), "the sign-in card shows only when the owned library is on and signed out")
        require(R.items(installed: found, owned: [], search: "").count == 2 && R.items(installed: found, owned: [], search: "  ").count == 2,
                "empty search shows all")
        require(R.items(installed: found, owned: [], search: "second").map(\.id) == [4343], "search is case-insensitive on the name")
        require(R.items(installed: found, owned: [], search: "nothing").isEmpty, "search without a match")

        // Owned games (from the account) merged with what Steam installed.
        func own(_ id: Int, _ name: String, build: Int = 100, extra: String = "") -> SteamOwnedGame {
            let vdf = "\"appinfo\" { \"common\" { \"name\" \"\(name)\" \"type\" \"Game\" \"oslist\" \"windows\" \(extra) } " +
                "\"config\" { \"installdir\" \"\(name)\" } " +
                "\"depots\" { \"\(id + 1)\" { \"manifests\" { \"public\" { \"gid\" \"77\" \"download\" \"5\" } } } " +
                "\"branches\" { \"public\" { \"buildid\" \"\(build)\" } } } }"
            return SteamOwnedGame(SteamAppInfo.parse(appID: UInt32(id), from: Data(vdf.utf8))!)
        }
        let owned = [own(4242, "Fixture Game"), own(5001, "Beta"), own(5000, "Alpha"), own(5002, "Gamma")]
        let merged = R.items(installed: found, owned: owned, search: "")
        require(merged.map(\.id) == [4242, 4343, 5000, 5001, 5002], "installed games first, then owned ones, each by name: \(merged.map(\.id))")
        require(merged.first { $0.id == 4242 }.map { $0.installed != nil && $0.owned != nil } == true, "a game both installed and owned is one item")
        require(merged.first { $0.id == 4343 }.map { $0.installed != nil && $0.owned == nil && $0.name == "Second Fixture" } == true,
                "an installed game the account does not list keeps its install record's name")
        require(R.items(installed: found, owned: owned, search: "ALPHA").map(\.id) == [5000], "search covers owned games, without case")
        require(R.items(installed: [], owned: [], search: "").isEmpty, "nothing installed and nothing owned: no items")

        let ready = found[0], partial = found[1]
        require(R.status(installed: nil, transfer: nil, updateAvailable: false) == .notInstalled, "owned only: not installed")
        require(R.status(installed: partial, transfer: nil, updateAvailable: false) == .partlyInstalled, "an unfinished record is not playable")
        require(R.status(installed: ready, transfer: nil, updateAvailable: false) == .installed, "installed")
        require(R.status(installed: ready, transfer: nil, updateAvailable: true) == .updateAvailable, "installed with a newer build")
        require(R.status(installed: ready, transfer: .active(percent: 250), updateAvailable: true) == .downloading(100), "a download wins over the record; percent is clamped")
        require(R.status(installed: nil, transfer: .paused, updateAvailable: false).label == "Paused", "paused label")
        require(R.status(installed: nil, transfer: .queued, updateAvailable: false).label == "Waiting", "queued label")
        require(R.status(installed: nil, transfer: .failed, updateAvailable: false) == .failed, "failed")
        require(R.status(installed: nil, transfer: .active(percent: 42), updateAvailable: false).label == "Downloading 42%", "progress label")

        // The build an update compares with comes from the game's owned build.
        require(owned[0].buildID == 100 && owned[0].installDir == "Fixture Game" && owned[0].folderName == "Fixture Game",
                "the owned game carries the PICS build and install folder")

        require(R.blocker(installed: true, client: true, signedIn: true) == nil, "Play offered when installed, client ready, signed in")
        require(R.blocker(installed: false, client: true, signedIn: true)?.contains("fully installed") == true, "not installed first")
        require(R.blocker(installed: true, client: false, signedIn: true)?.contains("client components") == true, "client components next")
        require(R.blocker(installed: true, client: true, signedIn: false)?.contains("Sign in") == true, "sign-in last")
        require(R.blocker(installed: true, client: true, signedIn: true, updating: true)?.contains("downloaded") == true,
                "no Play while the game is being downloaded")

        let cover = R.cover(4242)
        require(cover?.scheme == "https" && cover?.host == "cdn.cloudflare.steamstatic.com" && cover?.path.contains("/4242/") == true,
                "artwork from Steam's public store CDN by App ID")
        require(R.cover(0) == nil, "no artwork URL for an invalid App ID")

        // Artwork candidates: PICS capsule, legacy path, a demo's full game, header image.
        let art = own(6000, "Artful", extra: "\"library_assets_full\" { \"library_capsule\" { \"image\" { \"english\" \"abc123/library_capsule.jpg\" } } } " +
                                            "\"header_image\" { \"english\" \"def456/header.jpg\" } \"parent\" \"6100\"")
        let urls = R.artwork(appID: 6000) { $0 == 6000 ? art : nil }
        require(urls.map(\.absoluteString) == [
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/6000/abc123/library_capsule.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/6000/library_600x900.jpg",
            "https://cdn.cloudflare.steamstatic.com/steam/apps/6100/library_600x900.jpg",
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/6000/def456/header.jpg"], "artwork candidates in order: \(urls)")
        require(R.artwork(appID: 7) { _ in nil }.map(\.absoluteString) == ["https://cdn.cloudflare.steamstatic.com/steam/apps/7/library_600x900.jpg"],
                "unknown game: the legacy path only")
        require(R.safeAssetName("a1/b2.jpg") && !R.safeAssetName("../x") && !R.safeAssetName("/x") && !R.safeAssetName("a b") &&
                !R.safeAssetName("a?b=c") && !R.safeAssetName("a#b") && !R.safeAssetName("") && !R.safeAssetName("caf\u{e9}.jpg"),
                "artwork names are plain relative paths")
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
    (tmp / 'owned.swift').write_text('import Foundation\n' + owned_game + '\n' + vdf)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                            str(tmp / 'stubs.swift'), str(tmp / 'dock.swift'), str(tmp / 'rules.swift'),
                            str(tmp / 'checks.swift'), str(tmp / 'owned.swift'), str(app / 'SteamKeyValues.swift'),
                            str(app / 'SteamInstall.swift'), str(app / 'SwiftSteam/Library/SteamAppInfo.swift')],
                           capture_output=True, text=True)
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
