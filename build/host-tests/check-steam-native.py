#!/usr/bin/env python3
"""ml1310 host checks for the native Steam client; never runs Wine, Steam or iOS.

Part A compiles production Swift (depot selection, manifest path safety, the
download journal, appmanifest output and library-entry routing) on the host.
Part B compiles the production C decoders (liblzma shim, zstd educational
decoder) and drives them with real LZMA streams, handcrafted zstd frames and
concurrent corrupt input under ThreadSanitizer and AddressSanitizer. The
unlocked wrapper is rebuilt as a control and must be reported by TSan.
"""
from pathlib import Path
import lzma
import os
import re
import subprocess
import tempfile
import dock_contract

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
steam = app / 'SwiftSteam'
SWIFTC = '/home/hero/.local/share/swiftly/bin/swiftc'
# System cc: the Swift toolchain's clang TSan runtime needs the Blocks runtime on Linux.
CLANG = 'cc'


def block(source, start_marker):
    """Return the declaration starting at start_marker through its closing brace."""
    start = source.index(start_marker)
    depth, i = 0, source.index('{', start)
    while True:
        c = source[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return source[start:i + 1] + '\n'
        i += 1


# ---------------------------------------------------------------- Part A
fetcher = (steam / 'Library/SteamLibraryFetcher.swift').read_text()
downloader = (steam / 'Content/DepotDownloader.swift').read_text()
library = (app / 'Library.swift').read_text()

vdf = fetcher[fetcher.index('// MARK: - Simple VDF Binary Parser'):]
helpers = 'enum DD {\n'
for marker in ['nonisolated static func safeRelativePath(', 'nonisolated static func safeFolderName(',
               'nonisolated static func usableContentHost(', 'nonisolated static func serverEligibility(']:
    helpers += block(downloader, marker).replace('nonisolated ', '')
helpers += '    enum ServerEligibility: Equatable { case usable, noHTTPS, other }\n}\n'
helpers += block(downloader, 'final class ContentHostHealth')
journal = block(downloader, 'final class JournalWriter')
# ml1490: the native install's program choice, from SteamAccount.swift (which
# needs UIKit as a whole). SA holds the static members of SteamAccountModel.
account = (app / 'SteamAccount.swift').read_text()
exe_search = block(account, 'struct SteamLaunchOption') + 'enum SA {\n'
exe_search += block(account, 'struct ExecutableChoice') + block(account, 'struct ExecutableSearch')
helpers_at = account.index('private nonisolated static let helperNames')
exe_search += '    static let helperNames' + account[account.index(' = [', helpers_at):account.index(']', helpers_at) + 1] + '\n'
for marker in ['nonisolated static func searchExecutable(', 'nonisolated static func executableCandidates(']:
    exe_search += block(account, marker).replace('nonisolated ', '')
exe_search += '}\n'
entry = library[library.index('struct LibraryEntry:'):library.index('final class LibraryModel:')]
model_methods = library[library.index('    func mergeSteam('):library.index('    private func persist(')]

stubs = r'''
import Foundation
import Glibc
import Dispatch
struct TouchControl: Codable {}
enum LibraryError: Error { case message(String) }
enum LibraryFlags {
    static func enabled(_ key: String, fallback: Bool = true) -> Bool { getenv(key).map { String(cString: $0) != "0" } ?? fallback }
}
enum SteamLog { static func trace(_ m: @autoclosure () -> String) {}; static func event(_ m: String) {} }
final class LogStore { static let shared = LogStore(); func log(_ m: String) {} }
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-steam-native/steamapps") } }
class LibraryModel {
    static var drive = URL(fileURLWithPath: "/tmp/madeira-steam-native/drive_c")
    var entries: [LibraryEntry] = []; var current: UUID?; var readOnly = false
    func persist(_ next: [LibraryEntry]) { entries = next }
    static func executable(_ relative: String) throws -> URL {
        let url = drive.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.message("missing") }
        return url
    }
    // A Windows program: "MZ" at the start (the production reader also checks the PE header).
    static func inspect(_ url: URL) throws -> LibraryEntry {
        guard url.path.hasPrefix(drive.path + "/"), (try? Data(contentsOf: url))?.prefix(2) == Data([0x4d, 0x5a]) else { throw LibraryError.message("not a program") }
        return LibraryEntry(title: url.deletingPathExtension().lastPathComponent, relativePath: String(url.path.dropFirst(drive.path.count + 1)), bits: 32)
    }
    MODEL_METHODS
}
enum GuestDisplay { static func configureSessionDefault(view: CGSize, knob: String) {} }
func madeira_set_vsync_locked(_ mode: Int32) {}
'''.replace('MODEL_METHODS', model_methods)

checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func appVDF(_ body: String) -> Data { Data(("\"appinfo\" { \"appid\" \"10\" " + body + " }").utf8) }

@main struct Checks {
    static func main() throws {
        // Depot selection: Windows, neutral/64-bit, common/english, no low
        // violence, DLC, shared redistributables or manifest-less depots.
        let full = appVDF(#"""
        "common" { "name" "Fixture" "type" "Game" "oslist" "windows,macos" }
        "config" { "installdir" "Fixture Game"
          "launch" { "0" { "executable" "bin/game64.exe" "type" "default" "config" { "oslist" "windows" "osarch" "64" } }
                     "1" { "executable" "mac/game.app" "config" { "oslist" "macos" } } } }
        "depots" {
          "101" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1001" "size" "500" "download" "300" } } }
          "102" { "config" { "oslist" "windows" "language" "english" } "manifests" { "public" { "gid" "1002" "download" "40" } } }
          "103" { "config" { "oslist" "windows" "language" "german" } "manifests" { "public" { "gid" "1003" "download" "40" } } }
          "104" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" { "gid" "1004" "download" "70" } } }
          "105" { "config" { "oslist" "windows" "osarch" "64" } "manifests" { "public" { "gid" "1005" "download" "80" } } }
          "106" { "config" { "oslist" "windows" "lowviolence" "1" } "manifests" { "public" { "gid" "1006" } } }
          "107" { "dlcappid" "999" "manifests" { "public" { "gid" "1007" } } }
          "108" { "sharedinstall" "1" "manifests" { "public" { "gid" "1008" } } }
          "109" { "config" { "oslist" "windows" } }
          "110" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "1010" } } }
          "branches" { "public" { "buildid" "4242" } }
        }
        """#)
        let info = SteamAppInfo.parse(appID: 10, from: full)!
        require(info.installDepots().map(\.depotID) == [101, 102, 105], "install depots: common + english + 64-bit only")
        require(info.downloadSize(for: "windows") == 420, "download size counts only selected depots")
        require(info.buildID == 4242 && info.installableOnWindows, "build id and Windows installability")
        require(info.launchConfigs(for: "windows").map(\.executable) == ["bin/game64.exe"], "Windows launch configuration")

        let legacy = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Old" "type" "Game" "oslist" "windows" } "config" { "installdir" "Old" }
        "depots" { "201" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" "2001" } }
                   "202" { "manifests" { "public" "2002" } } }
        """#))!
        require(legacy.installDepots().map(\.depotID) == [201, 202], "32-bit-only apps fall back to 32-bit depots")

        let macOnly = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Mac" "type" "Game" "oslist" "macos" } "depots" { "301" { "config" { "oslist" "macos" } "manifests" { "public" "3001" } } }
        """#))!
        require(!macOnly.installableOnWindows, "apps without a Windows build are not offered")
        let tool = SteamAppInfo.parse(appID: 10, from: appVDF(#"""
        "common" { "name" "Tool" "type" "Tool" } "depots" { "401" { "manifests" { "public" "4001" } } }
        """#))!
        require(!tool.installableOnWindows, "tools and redistributables are not offered")

        // ml1410: package depot lists (binary VDF) and depots installed from another app.
        func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
        var pkg: [UInt8] = [0x00] + Array("appids".utf8) + [0, 0x02] + Array("0".utf8) + [0] + le(7000) + [0x08]
        pkg += [0x00] + Array("depotids".utf8) + [0, 0x02] + Array("0".utf8) + [0] + le(7001)
        pkg += [0x02] + Array("1".utf8) + [0] + le(7002) + [0x08]
        require(VDFParser.parsePackageIDs(key: "depotids", from: Data(pkg)) == [7001, 7002], "package depot ids")
        require(VDFParser.parsePackageAppIDs(from: Data(pkg)) == [7000], "package app ids unchanged")
        let shared = SteamAppInfo.parse(appID: 7100, from: appVDF(#"""
        "common" { "name" "Shared" "type" "Game" "oslist" "windows" }
        "depots" { "7101" { "manifests" { "public" "71011" } } "7109" { "depotfromapp" "7108" } }
        """#))!
        require(shared.depots.first { $0.depotID == 7109 }?.fromApp == 7108 && shared.installDepots().map(\.depotID) == [7101],
                "depotfromapp parsed; borrowed depot not installed")
        require(shared.depotSelectionSummary().contains("7109[-]nomanifest<7108"), "selection log marks the owning app")

        // ml1420: PICS type names are not consistently capitalized. Shape of a
        // real multi-platform app: neutral content, per-OS binaries, language
        // packs and an optional DLC depot, no osarch anywhere.
        let lower = SteamAppInfo.parse(appID: 7200, from: appVDF(#"""
        "common" { "name" "Lower" "type" "game" "oslist" "windows,macos,linux" }
        "depots" { "7201" { "systemdefined" "1" "manifests" { "public" { "gid" "1" "size" "9" "download" "5" } } }
                   "7202" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "2" "download" "3" } } }
                   "7203" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "3" } } }
                   "7204" { "config" { "language" "french" } "manifests" { "public" { "gid" "4" } } }
                   "7205" { "config" { "oslist" "windows" "optionaldlc" "7209" } "dlcappid" "7209" "optional" "1" "manifests" { "public" { "gid" "5" } } }
                   "7206" { "config" { "oslist" "linux" } "manifests" { "public" { "gid" "6" } } }
                   "branches" { "public" { "buildid" "77" } } "baselanguages" "english,french" }
        """#))!
        require(lower.type == .game && lower.rawType == "game", "lowercase PICS type is a game")
        require(lower.installableOnWindows && lower.hiddenReason == nil && lower.installDepots().map(\.depotID) == [7201, 7202],
                "lowercase-typed multi-platform app is offered with its Windows depots")
        require(SteamAppInfo.AppType(pics: "game", foldCase: false) == .unknown, "type fold rollback keeps exact matching")
        require(SteamAppInfo.AppType(pics: "APPLICATION") == .application && SteamAppInfo.AppType(pics: "demo") == .demo &&
                SteamAppInfo.AppType(pics: "dlc") == .dlc && SteamAppInfo.AppType(pics: "Game") == .game &&
                SteamAppInfo.AppType(pics: "config") == .unknown && SteamAppInfo.AppType(pics: "") == .unknown,
                "type names match without case; unknown names stay unknown")
        require(!SteamAppInfo.AppType(pics: "tool").isPlayable && !SteamAppInfo.AppType(pics: "DLC").isPlayable,
                "lowercase tools and DLC stay hidden")

        // ml1420: hidden reasons and the once-per-fetch summary.
        require(macOnly.hiddenReason == "os" && tool.hiddenReason == "type-tool", "hidden reasons: os, type")
        let noManifest = SteamAppInfo.parse(appID: 7310, from: appVDF(#"""
        "common" { "name" "NoManifest" "type" "Game" "oslist" "windows" }
        "depots" { "7311" { "config" { "oslist" "windows" } } "7312" { "config" { "oslist" "windows" } } "7313" { "config" { "oslist" "macos" } } }
        """#))!
        require(noManifest.hiddenReason == "nodepot/nomanifest2+os1", "no installable depot names the skipped-depot rules")
        let noDepots = SteamAppInfo.parse(appID: 7320, from: appVDF(#""common" { "name" "Empty" "type" "Game" }"#))!
        require(noDepots.hiddenReason == "nodepots", "app without depots")
        let untyped = SteamAppInfo.parse(appID: 7307, from: appVDF(#""common" { "name" "Untyped" }"#))!
        let toolApp = SteamAppInfo.parse(appID: 7303, from: appVDF(#""common" { "name" "T" "type" "Tool" }"#))!
        let dlcApp = SteamAppInfo.parse(appID: 7308, from: appVDF(#""common" { "name" "D" "type" "DLC" }"#))!
        let macApp = SteamAppInfo.parse(appID: 7305, from: appVDF(#""common" { "name" "M" "type" "Game" "oslist" "macos" }"#))!
        let report = SteamLibraryVisibilityReport(requested: [7200, 7301, 7302, 7303, 7304, 7305, 7307, 7308, 7200],
                                                  parsed: [lower, toolApp, macApp, untyped, dlcApp], unknown: [7301],
                                                  failed: [7302: "parse-empty"], missingToken: [7305])
        let summary = report.summary(limit: 40)
        require(summary == "requested=8 hidden=7 types=dlc:1,tool:1 ids=7301:unknown,7302:parse-empty,7304:missing,7305:os+token,7307:type-none more=0",
                "hidden summary: expected types counted, other reasons listed by App ID (\(summary))")
        require(report.summary(limit: 2).hasSuffix("ids=7301:unknown,7302:parse-empty more=3"), "hidden summary is capped")
        require(SteamAppInfo.parseFailure(Data()) == "parse-empty" && SteamAppInfo.parseFailure(Data([0x22, 0xff, 0xfe, 0x22])) == "parse-utf8" &&
                SteamAppInfo.parseFailure(Data(#""x" { }"#.utf8)) == "parse-noname", "parse failure reasons")

        // ml1420: PICS product info carries missing_token (field 3) per app.
        var sub = ProtobufEncoder()
        sub.writeUInt32(fieldNumber: 1, value: 7305); sub.writeBool(fieldNumber: 3, value: true)
        sub.writeBytes(fieldNumber: 5, value: Data("x".utf8))
        var outer = ProtobufEncoder()
        outer.writeSubmessage(fieldNumber: 1, value: sub.data); outer.writeUInt32(fieldNumber: 2, value: 7301)
        let pics = try CMsgClientPICSProductInfoResponse.deserialize(from: outer.data)
        require(pics.apps.first?.missingToken == true && pics.apps.first?.buffer == Data("x".utf8) && pics.unknownApps == [7301],
                "PICS response: missing token, buffer and unknown apps")

        // ml1420: the Windows client's appmanifest progress.
        func acf(_ id: Int, flags: Int, toDownload: UInt64 = 0, downloaded: UInt64 = 0, toStage: UInt64 = 0, staged: UInt64 = 0,
                 shared: [(Int, Int)] = []) -> Data {
            var text = "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"StateFlags\"\t\t\"\(flags)\"\n"
            text += "\t\"BytesToDownload\"\t\t\"\(toDownload)\"\n\t\"BytesDownloaded\"\t\t\"\(downloaded)\"\n"
            text += "\t\"BytesToStage\"\t\t\"\(toStage)\"\n\t\"BytesStaged\"\t\t\"\(staged)\"\n"
            text += "\t\"InstalledDepots\"\n\t{\n\t\t\"1\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"2\"\n\t\t}\n\t}\n"
            if !shared.isEmpty {
                text += "\t\"SharedDepots\"\n\t{\n" + shared.map { "\t\t\"\($0.0)\"\t\t\"\($0.1)\"\n" }.joined() + "\t}\n"
            }
            return Data((text + "}\n").utf8)
        }
        typealias Phase = SteamClientAppState.Phase
        let phases: [(Int, Phase)] = [(0x100000 | 0x400 | 2, .downloading), (0x80000, .downloading), (0x200000 | 0x400, .staging),
                                      (0x400000, .staging), (0x20000, .verifying), (0x200 | 2, .paused), (6, .queued), (4, .installed),
                                      (1, .idle), (0, .idle)]
        require(phases.allSatisfy { SteamClientAppState.parse(acf(7000, flags: $0.0), appID: 7000)?.phase == $0.1 },
                "StateFlags map to phases")
        require(SteamClientAppState.parse(acf(7000, flags: 0x400 | 2, toDownload: 10, downloaded: 4), appID: 7000)?.phase == .downloading &&
                SteamClientAppState.parse(acf(7000, flags: 0x100, toDownload: 10, downloaded: 10, toStage: 10, staged: 3), appID: 7000)?.phase == .staging,
                "a running update without a specific bit follows its counters")
        let record = acf(7000, flags: 6, shared: [(7101, 7100), (7102, 7100), (7103, 7000), (7201, 7200)])
        require(SteamClientAppState.parse(record, appID: 7000)?.sharedOwners == [7100, 7200], "shared depot owners, once each, never the app itself")
        require(SteamClientAppState.parse(record, appID: 7001) == nil, "record for another app is rejected")
        require((1..<record.count).allSatisfy { SteamClientAppState.parse(record.prefix($0), appID: 7000) == nil ||
                                               SteamClientAppState.parse(record.prefix($0), appID: 7000) == SteamClientAppState.parse(record, appID: 7000) },
                "every truncated record is rejected or complete")
        require(SteamClientAppState.parse(Data(), appID: 7000) == nil &&
                SteamClientAppState.parse(Data(repeating: 32, count: (1 << 20) + 1), appID: 7000) == nil &&
                SteamClientAppState.parse(Data("\"AppState\" { \"appid\" \"7000\" }".utf8), appID: 7000) == nil,
                "empty, oversized and flagless records are rejected")

        let progressRoot = URL(fileURLWithPath: "/tmp/madeira-steam-progress")
        try? FileManager.default.removeItem(at: progressRoot)
        let drive = progressRoot.appendingPathComponent("drive_c")
        let apps = drive.appendingPathComponent("Program Files (x86)/Steam/steamapps")
        let extra = drive.appendingPathComponent("Games Library/steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data(#"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "C:\\Games Library" } "2" { "path" "D:\\External" } }
        """#.utf8).write(to: apps.appendingPathComponent("libraryfolders.vdf"))
        let libraries = SteamClientProgressTracker.libraries(primary: [apps, apps], drive: drive)
        require(libraries.map(\.lastPathComponent) == ["steamapps", "steamapps"] && libraries.last?.path.contains("Games Library") == true,
                "progress searches the client's libraries inside drive_c, once each")
        var tracker = SteamClientProgressTracker(appID: 7000)
        tracker.poll(libraries: libraries)
        require(tracker.progress == SteamClientProgress() && tracker.appIDs == [7000], "no record yet: idle, nothing tracked")
        try record.write(to: apps.appendingPathComponent("appmanifest_7000.acf"))
        try acf(7100, flags: 0x100000 | 0x400 | 2, toDownload: 2_000_000_000, downloaded: 1_200_000_000).write(to: apps.appendingPathComponent("appmanifest_7100.acf"))
        try acf(7200, flags: 6, toDownload: 1_800_000_000).write(to: extra.appendingPathComponent("appmanifest_7200.acf"))
        tracker.poll(libraries: libraries)
        var progress = tracker.progress
        require(tracker.appIDs == [7000, 7100, 7200] && progress.phase == .downloading && progress.total == 3_800_000_000 &&
                progress.downloaded == 1_200_000_000 && progress.pending == [7000, 7100, 7200] && progress.percent == 31,
                "launched app plus shared-depot owners, across libraries")
        require(progress.summary == "Steam is downloading game content: 1.2 of 3.8 GB (31%)" && progress.detail == "3 items still to update" &&
                progress.active && progress.working, "progress text (\(progress.summary ?? "nil"))")
        try record.prefix(record.count / 2).write(to: apps.appendingPathComponent("appmanifest_7000.acf"))
        try Data(acf(7100, flags: 0x100000, toDownload: 2_000_000_000, downloaded: 1_500_000_000).prefix(40)).write(to: apps.appendingPathComponent("appmanifest_7100.acf"))
        try FileManager.default.removeItem(at: extra.appendingPathComponent("appmanifest_7200.acf"))
        tracker.poll(libraries: libraries)
        require(tracker.progress.unreadable == 2 && tracker.progress.downloaded == 1_200_000_000 && tracker.appIDs == [7000, 7100, 7200],
                "partial writes and a briefly missing record keep the last complete reading")
        try record.write(to: apps.appendingPathComponent("appmanifest_7000.acf"))
        try acf(7100, flags: 4).write(to: apps.appendingPathComponent("appmanifest_7100.acf"))
        try acf(7200, flags: 0x200000 | 0x400, toDownload: 1_800_000_000, downloaded: 1_800_000_000, toStage: 1_000_000_000,
                staged: 250_000_000).write(to: extra.appendingPathComponent("appmanifest_7200.acf"))
        tracker.poll(libraries: libraries)
        progress = tracker.progress
        require(progress.phase == .staging && progress.downloaded == 3_800_000_000 && progress.total == 3_800_000_000 &&
                progress.pending == [7000, 7200], "a finished owner keeps its share after its counters reset")
        require(progress.summary == "Steam is installing downloaded content: 250 MB of 1.0 GB (25%)", "staging text (\(progress.summary ?? "nil"))")
        try acf(7000, flags: 4, shared: [(7101, 7100), (7201, 7200)]).write(to: apps.appendingPathComponent("appmanifest_7000.acf"))
        try acf(7200, flags: 4, toDownload: 1_800_000_000, downloaded: 1_800_000_000).write(to: extra.appendingPathComponent("appmanifest_7200.acf"))
        tracker.poll(libraries: libraries)
        progress = tracker.progress
        require(progress.phase == .installed && !progress.active && progress.summary == nil && progress.pending.isEmpty, "all installed: nothing to show")
        var queued = SteamClientProgress.combine([SteamClientAppState.parse(acf(7000, flags: 6, toDownload: 9, downloaded: 9), appID: 7000)!], involved: [])
        require(queued.phase == .queued && queued.total == 0 && queued.summary == "Steam needs to update game content before the game can start." &&
                !queued.working, "leftover counters of a waiting record are not counted")
        queued = SteamClientProgress.combine([SteamClientAppState.parse(acf(7000, flags: 0x200 | 2, toDownload: 3_000_000_000, downloaded: 450_000_000), appID: 7000)!], involved: [])
        require(queued.summary == "Steam paused the content download: 450 MB of 3.0 GB (15%)" && queued.active && !queued.working,
                "paused: shown while starting, not over gameplay (\(queued.summary ?? "nil"))")
        require(SteamClientProgress.amount(0, of: 3_800_000_000) == "0.0 of 3.8 GB" && SteamClientProgress.size(12_000_000) == "12 MB",
                "size formatting")

        var limiter = SteamClientProgressLog()
        var sample = SteamClientProgress(); sample.phase = .downloading; sample.total = 100; sample.downloaded = 10
        var logged = [limiter.line(sample, now: 0) != nil]
        sample.downloaded = 20; logged.append(limiter.line(sample, now: 10) != nil)
        logged.append(limiter.line(sample, now: 31) != nil)
        logged.append(limiter.line(sample, now: 70) != nil)
        sample.phase = .staging; logged.append(limiter.line(sample, now: 33) != nil)
        logged.append(limiter.line(sample, now: 37) != nil)
        sample.phase = .installed; logged.append(limiter.line(sample, now: 45) != nil)
        sample.downloaded = 100; logged.append(limiter.line(sample, now: 500) != nil)
        require(logged == [true, false, true, false, false, true, true, false], "progress log: first, 30 s figures, 5 s phase floor, quiet when done (\(logged))")
        var capped = SteamClientProgressLog(), lines = 0
        for step in 0..<1000 { sample.phase = step % 2 == 0 ? .downloading : .staging; if capped.line(sample, now: Double(step) * 10) != nil { lines += 1 } }
        require(lines == SteamClientProgressLog.cap, "progress log is capped per session")

        // Manifest paths.
        var folded: [String: String] = [:]
        for bad in ["../x", "a/../b", "a/./b", "C:/x", "a/b\u{1}c", "", "////"] {
            require(DD.safeRelativePath(bad, folded: &folded) == nil, "rejects manifest path \(bad.debugDescription)")
        }
        require(DD.safeRelativePath("Data\\Maps\\a.pak", folded: &folded) == "Data/Maps/a.pak", "backslash paths")
        require(DD.safeRelativePath("data/maps/b.pak", folded: &folded) == "Data/Maps/b.pak", "directories fold case-insensitively")
        require(DD.safeRelativePath("DATA/Other/c.pak", folded: &folded) == "Data/Other/c.pak", "partial folding keeps first spelling")
        require(DD.safeRelativePath("/lead/and//double/", folded: &folded) == "lead/and/double", "empty components ignored")
        require(DD.safeFolderName("../../escape") == "escape" && DD.safeFolderName("..") == "app" &&
                DD.safeFolderName("") == "app" && DD.safeFolderName("C:") == "app" && DD.safeFolderName("Game Name") == "Game Name",
                "install folder is one safe component")
        require(DD.usableContentHost("cache1-lax1.steamcontent.com") && DD.usableContentHost("steampipe.akamaized.net"),
                "public content hosts accepted")
        for host in ["lancache.steamcontent.com", "*.steamcontent.com", "evil.example", "a.steamcontent.com.evil.example",
                     "a.steamcontent.com:8080", "a/b.steamcontent.com"] {
            require(!DD.usableContentHost(host), "rejects content host \(host)")
        }

        // ml1320: content directory entries (shapes from GetServersForSteamPipe).
        let json = #"""
        [{"type":"SteamCache","host":"cache1-atl3.steamcontent.com","https_support":"mandatory"},
         {"type":"CDN","host":"a.cdn.steampipe.steamcontent.com","https_support":"unavailable"},
         {"type":"CDN","host":"b.akamaized.net","https_support":"optional"},
         {"type":"CDN","host":"c.steamcontent.com","https_support":"mandatory","use_as_proxy":true},
         {"type":"CDN","host":"d.steamcontent.com","https_support":"mandatory","allowed_app_ids":[730]},
         {"type":"CDN","host":"e.steamcontent.com","https_support":"mandatory","allowed_app_ids":[220, 730]},
         {"type":"SteamCache","host":"f.steamcontent.com"}]
        """#
        let servers = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        let verdicts = servers.map { DD.serverEligibility($0, appID: 220) }
        require(verdicts == [.usable, .noHTTPS, .usable, .other, .other, .usable, .usable],
                "content servers: HTTPS-unavailable, proxy and other-app servers skipped")

        let health = ContentHostHealth(enabled: true)
        let pool = ["https://a", "https://b", "https://c"]
        require(health.order(pool, seed: 1) == ["https://b", "https://c", "https://a"], "chunks start on different servers")
        for _ in 0..<3 { health.recordFailure("https://b", reason: "url-1200") }
        require(health.order(pool, seed: 1) == ["https://c", "https://a", "https://b"], "failing server moves to the back")
        for _ in 0..<3 { health.recordSuccess("https://b") }
        require(health.order(pool, seed: 1).first == "https://b", "recovered server returns to rotation")
        let plain = ContentHostHealth(enabled: false)
        plain.recordFailure("https://b", reason: "x")
        require(plain.order(pool, seed: 1) == ["https://b", "https://c", "https://a"], "health rollback keeps plain rotation")

        // Resume journal.
        let dir = URL(fileURLWithPath: "/tmp/madeira-steam-native")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let journalURL = dir.appendingPathComponent("depot.journal")
        let writer = try JournalWriter(url: journalURL)
        let keys: [UInt64] = (0..<200).map { UInt64($0 / 7) << 32 | UInt64($0 % 7) }
        for key in keys { writer.append(key) }
        writer.close()
        let handle = try FileHandle(forWritingTo: journalURL); handle.seekToEndOfFile(); handle.write(Data("zz\n12".utf8)); try handle.close()
        let loaded = JournalWriter.load(journalURL)
        require(loaded.isSuperset(of: Set(keys)) && loaded.count == 201, "journal round trip tolerates a garbage/partial tail")
        let appended = try JournalWriter(url: journalURL); appended.append(UInt64(1) << 40); appended.close()
        require(JournalWriter.load(journalURL).contains(UInt64(1) << 40), "journal appends across attempts")

        // appmanifest: readable by the existing library scanner.
        try AppManifestWriter.writeManifest(appID: 10, name: #"Quote "and" \slash"#, installDir: "Fixture Game", buildID: 4242,
                                            steamID: 7, sizeOnDisk: 500, steamAppsPath: dir.appendingPathComponent("steamapps").path,
                                            installedDepots: [.init(depotID: 101, manifestGID: 1001, size: 500)])
        var parser = try SteamKeyValues(Data(contentsOf: dir.appendingPathComponent("steamapps/appmanifest_10.acf")))
        let state = try parser.read()["appstate"]
        require(state?["appid"]?.string == "10" && state?["stateflags"]?.string == "4" &&
                state?["installdir"]?.string == "Fixture Game" && state?["buildid"]?.string == "4242" &&
                state?["installeddepots"]?["101"]?["manifest"]?.string == "1001", "appmanifest fields parse back")
        require(state?["name"]?.string == #"Quote "and" \slash"#, "appmanifest escapes names")
        do {
            try AppManifestWriter.writeManifest(appID: 11, name: "x", installDir: "x", buildID: 1, steamID: 0,
                                                steamAppsPath: "/proc/definitely/not/writable")
            require(false, "manifest write failure is reported")
        } catch { require(true, "manifest write failure is reported") }

        // Library entries: direct and client-routed native installs.
        var native = LibraryEntry(title: "Fixture", relativePath: "Program Files (x86)/Steam/steamapps/common/Fixture Game/bin/game64.exe", bits: 64)
        native.steamAppID = 10; native.steamNative = true; native.steamInstalled = true; native.arguments = "-windowed"
        require(!native.usesSteam && native.launchArguments == "-windowed", "native install starts the game directly")
        native.configureLaunch()
        require(String(cString: getenv("MADEIRA_EXE")) == native.windowsPath && getenv("MADEIRA_DESKTOP") == nil,
                "direct launch uses the game executable without a desktop session")
        native.steamClientLaunch = true
        // ml1970: "Steam (more usage)": the regular client even while Madeira Dock is on.
        native.steamDesktopLaunch = true
        require(!MadeiraDock.routes(native), "the regular Steam choice bypasses Madeira Dock")
        do { try native.validate(); require(false, "client route needs an installed client") }
        catch { require(true, "client route needs an installed client") }
        native.steamClientPath = "Program Files (x86)/Steam/steam.exe"
        try native.validate()
        require(native.usesSteam && native.launchArguments.contains("\"C:\\Program Files (x86)\\Steam\\steam.exe\"") &&
                native.launchArguments.contains("-applaunch 10") && !native.launchArguments.contains("game64.exe"),
                "client route launches the Steam client by App ID")

        // The Windows-client scan never rewrites a native entry.
        let model = LibraryModel()
        native.steamClientLaunch = nil
        model.entries = [native]
        var snapshot = SteamSnapshot(client: "Program Files (x86)/Steam/steam.exe")
        snapshot.apps = [SteamInstalledApp(id: 10, name: "Fixture", relativeFolder: "x", bytes: 1, installed: false, needsUpdate: false)]
        model.mergeSteam(snapshot)
        require(model.entries.count == 1 && model.entries[0].relativePath == native.relativePath &&
                model.entries[0].steamInstalled == true, "client scan leaves native entries alone")
        snapshot.apps = []
        model.mergeSteam(snapshot)
        require(model.entries[0].steamInstalled == true, "complete client scan does not mark native entries uninstalled")

        var update = native; update.id = UUID(); update.title = "Store Name"; update.steamBuildID = 5000; update.relativePath = "other.exe"
        model.entries[0].title = "My Title"
        model.upsertNativeSteam(update)
        require(model.entries.count == 1 && model.entries[0].title == "My Title" && model.entries[0].steamBuildID == 5000 &&
                model.entries[0].relativePath == "other.exe", "update keeps profile; missing executable choice is replaced")
        model.removeSteamInstall(model.entries[0].id)
        require(model.entries.isEmpty, "uninstall removes the entry")

        // ml1490: the folder scan never chooses a redistributable's installer.
        let installRelative = "Program Files (x86)/Steam/steamapps/common/Scan Game"
        let game = LibraryModel.drive.appendingPathComponent(installRelative)
        try? FileManager.default.removeItem(at: game)
        for (path, size) in [("Binaries/Game.exe", 2_000), ("PhysX/PhysX_SystemSoftware.exe", 64_000), ("unins000.exe", 1_000),
                             ("_CommonRedist/vcredist/2010/vcredist_x86.exe", 9_000), ("Support/Tool.exe", 70_000),
                             ("Binaries/readme.txt", 10)] {
            let url = game.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = Data(repeating: 0, count: size); if path.hasSuffix(".exe") { bytes[0] = 0x4d; bytes[1] = 0x5a }
            try bytes.write(to: url)
        }
        let unresolved = [SteamLaunchOption(executable: "Binaries\\Missing.exe", arguments: "", label: "", arch: "64", type: "default"),
                          SteamLaunchOption(executable: "..\\escape.exe", arguments: "", label: "", arch: "", type: "default")]
        var search = SA.searchExecutable(folder: game, options: unresolved, drive: LibraryModel.drive)
        require(search.choice?.url.lastPathComponent == "Game.exe" && search.choice?.source == "scan" && search.skipped == 4,
                "scan skips installers by name and folder (\(search.choice?.url.path ?? "none"), skipped \(search.skipped))")
        require(search.rejected == ["exe=Binaries\\Missing.exe reason=missing", "exe=..\\escape.exe reason=unsafe-path"],
                "rejected launch options carry their reason (\(search.rejected))")
        setenv("MADEIRA_STEAM_EXE_FILTER", "0", 1)
        search = SA.searchExecutable(folder: game, options: [], drive: LibraryModel.drive)
        require(search.choice?.url.lastPathComponent == "Tool.exe" && search.skipped == 0, "filter rollback: the old size-first choice")
        unsetenv("MADEIRA_STEAM_EXE_FILTER")
        search = SA.searchExecutable(folder: game, options: [SteamLaunchOption(executable: "binaries\\GAME.EXE", arguments: "-x", label: "", arch: "", type: "")],
                                     drive: LibraryModel.drive)
        require(search.choice?.source == "launch" && search.choice?.arguments == "-x" && search.rejected.isEmpty, "a resolving launch option wins")
        try FileManager.default.removeItem(at: game.appendingPathComponent("Binaries/Game.exe"))
        require(SA.searchExecutable(folder: game, options: [], drive: LibraryModel.drive).choice == nil, "only installers: nothing is chosen")

        // ...and an installer chosen before the filter is not kept by an update.
        try Data([0x4d, 0x5a]).write(to: game.appendingPathComponent("Binaries/Game.exe"))
        var stale = native; stale.id = UUID(); stale.steamClientLaunch = nil; stale.steamInstallPath = installRelative
        stale.relativePath = installRelative + "/PhysX/PhysX_SystemSoftware.exe"
        model.entries = [stale]
        var refreshed = stale; refreshed.relativePath = installRelative + "/Binaries/Game.exe"
        model.upsertNativeSteam(refreshed)
        require(model.entries[0].relativePath == refreshed.relativePath, "update replaces an installer chosen earlier")
        model.entries = [stale]
        setenv("MADEIRA_STEAM_EXE_FILTER", "0", 1); model.upsertNativeSteam(refreshed); unsetenv("MADEIRA_STEAM_EXE_FILTER")
        require(model.entries[0].relativePath == stale.relativePath, "filter rollback keeps the earlier choice")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all ml1310 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs + entry + dock_contract.source(app))
    (tmp / 'vdf.swift').write_text('import Foundation\n' + vdf)
    (tmp / 'helpers.swift').write_text('import Foundation\nimport Glibc\n' + helpers + journal + exe_search)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'stubs.swift', tmp / 'vdf.swift', tmp / 'helpers.swift', tmp / 'checks.swift',
               app / 'SteamFiles.swift', steam / 'Library/SteamAppInfo.swift', steam / 'Install/AppManifestWriter.swift',
               steam / 'Proto/SteamProtoMessages.swift', steam / 'Core/SteamError.swift']
    exe = tmp / 'swift-checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe)] + [str(s) for s in sources], check=True)
    # Address checking stays on; LeakSanitizer is off because it reports
    # Swift runtime/global allocations still live at process exit.
    subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# ---------------------------------------------------------------- Part B
c_checks = r'''
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lzma_shim.h"
static int failures;
#define CHECK(c, label) do { if (c) printf("PASS: %s\n", label); else { printf("FAIL: %s\n", label); failures++; } } while (0)

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *size = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(*size ? *size : 1); fread(data, 1, *size, f); fclose(f); return data;
}

/* zstd frame: magic, single-segment descriptor with a 1-byte content size,
 * then one last block (type 0 raw or 1 RLE). */
static size_t frame(uint8_t *out, int type, const uint8_t *payload, uint8_t n) {
    size_t i = 0;
    out[i++] = 0x28; out[i++] = 0xB5; out[i++] = 0x2F; out[i++] = 0xFD;
    out[i++] = 0x20; out[i++] = n;
    uint32_t header = 1u | ((uint32_t)type << 1) | ((uint32_t)n << 3);
    out[i++] = header & 0xFF; out[i++] = (header >> 8) & 0xFF; out[i++] = (header >> 16) & 0xFF;
    if (type == 0) { memcpy(out + i, payload, n); i += n; } else out[i++] = payload[0];
    return i;
}

static uint8_t raw_frame[512], rle_frame[16], bad_frames[64][96];
static size_t raw_len, rle_len;
static uint8_t expected[200];
static volatile int thread_failures;

static void *worker(void *arg) {
    uintptr_t id = (uintptr_t)arg;
    uint8_t out[256];
    for (int round = 0; round < 1500; round++) {
        int pick = (int)((round + id) % 3);
        if (pick == 0) {
            size_t n = zstd_safe_decompress(out, sizeof out, raw_frame, raw_len);
            if (n != 200 || memcmp(out, expected, 200)) __atomic_add_fetch(&thread_failures, 1, __ATOMIC_RELAXED);
        } else if (pick == 1) {
            size_t n = zstd_safe_decompress(out, sizeof out, rle_frame, rle_len);
            if (n != 77 || out[0] != 'Z' || out[76] != 'Z') __atomic_add_fetch(&thread_failures, 1, __ATOMIC_RELAXED);
        } else {
            const uint8_t *bad = bad_frames[(round * 7 + id) % 64];
            if (zstd_safe_decompress(out, sizeof out, bad, 96) != (size_t)-1) {
                /* Random bytes after a valid magic are rejected, except in the
                 * astronomically unlikely case they form a valid frame. */
            }
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    /* LZMA1 via the shim: stream and props produced by Python's encoder. */
    size_t plain_size, stream_size, props_size;
    uint8_t *plain = read_file(argv[1], &plain_size);
    uint8_t *props = read_file(argv[2], &props_size);
    uint8_t *stream = read_file(argv[3], &stream_size);
    uint8_t *decoded = malloc(plain_size);
    size_t produced = 0;
    int rc = lzma_shim_decode(props, props_size, stream, stream_size, decoded, plain_size, &produced);
    CHECK(rc == 0 && produced == plain_size && !memcmp(decoded, plain, plain_size), "LZMA1 chunk decodes exactly");
    rc = lzma_shim_decode(props, props_size, stream, stream_size / 2, decoded, plain_size, &produced);
    CHECK(rc != 0, "truncated LZMA1 chunk is rejected");
    CHECK(lzma_shim_decode(props, 4, stream, stream_size, decoded, plain_size, &produced) != 0, "bad LZMA props rejected");

    /* ml1320: single-entry PKZip chunks (older content). */
    size_t zp_size, z_size;
    uint8_t *zplain = read_file(argv[4], &zp_size);
    uint8_t *zout = malloc(zp_size + 64);
    const char *names[] = {"deflate", "stored", "deflate+descriptor", "stored+descriptor"};
    for (int i = 0; i < 4; i++) {
        uint8_t *zip = read_file(argv[5 + i], &z_size);
        size_t got = 0;
        int zrc = chunk_zip_decode(zip, z_size, zout, zp_size, &got);
        char label[96]; snprintf(label, sizeof label, "zip chunk decodes exactly (%s)", names[i]);
        CHECK(zrc == 0 && got == zp_size && !memcmp(zout, zplain, zp_size), label);
        if (i == 0) {
            CHECK(chunk_zip_decode(zip, z_size / 2, zout, zp_size, &got) < 0, "truncated zip chunk is rejected");
            CHECK(chunk_zip_decode(zip, z_size, zout, zp_size / 2, &got) == -4, "zip chunk larger than expected is rejected");
            CHECK(chunk_zip_decode(zip, 20, zout, zp_size, &got) == -1, "short zip header is rejected");
        }
        free(zip);
    }
    uint8_t *bz = read_file(argv[9], &z_size);
    size_t got = 0;
    CHECK(chunk_zip_decode(bz, z_size, zout, zp_size, &got) == -2, "unsupported zip method is rejected");
    CHECK(chunk_zip_decode(plain, plain_size, zout, zp_size, &got) == -1, "non-zip data is rejected");
    free(bz); free(zplain); free(zout);

    for (int i = 0; i < 200; i++) expected[i] = (uint8_t)(i * 31 + 7);
    raw_len = frame(raw_frame, 0, expected, 200);
    uint8_t z = 'Z';
    rle_len = frame(rle_frame, 1, &z, 77);
    uint8_t out[256];
    CHECK(zstd_safe_decompress(out, sizeof out, raw_frame, raw_len) == 200 && !memcmp(out, expected, 200), "zstd raw block");
    CHECK(zstd_safe_decompress(out, sizeof out, rle_frame, rle_len) == 77 && out[0] == 'Z' && out[76] == 'Z', "zstd RLE block");
    CHECK(zstd_safe_decompress(out, 100, raw_frame, raw_len) == (size_t)-1, "undersized zstd output is an error, not exit");
    uint8_t junk[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    CHECK(zstd_safe_decompress(out, sizeof out, junk, sizeof junk) == (size_t)-1, "bad zstd magic is an error, not exit");
    srand(1310);
    for (int f = 0; f < 64; f++) {
        bad_frames[f][0] = 0x28; bad_frames[f][1] = 0xB5; bad_frames[f][2] = 0x2F; bad_frames[f][3] = 0xFD;
        for (int i = 4; i < 96; i++) bad_frames[f][i] = (uint8_t)rand();
    }
    pthread_t threads[8];
    for (uintptr_t t = 0; t < 8; t++) pthread_create(&threads[t], NULL, worker, (void *)t);
    for (int t = 0; t < 8; t++) pthread_join(threads[t], NULL);
    CHECK(thread_failures == 0, "8 threads x 1500 mixed valid/corrupt zstd decodes");
    free(plain); free(props); free(stream); free(decoded);
    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    printf("PASS: all ml1310 C decoder checks\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    plain = bytes((i * 7919 >> 3) & 0xFF for i in range(300_000)) + b'Madeira' * 20_000
    alone = lzma.compress(plain, format=lzma.FORMAT_ALONE,
                          filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20}])
    (tmp / 'plain.bin').write_bytes(plain)
    (tmp / 'props.bin').write_bytes(alone[:5])
    (tmp / 'stream.bin').write_bytes(alone[13:])
    # Single-entry zip chunks: sized headers, and streamed (bit 3 data
    # descriptor, sizes zero in the local header) like non-seekable writers.
    import io, zipfile

    class Unseekable(io.RawIOBase):
        def __init__(self): self.buf = bytearray()
        def writable(self): return True
        def write(self, b): self.buf += b; return len(b)

    zplain = bytes((i * 131 + (i >> 7)) & 0xFF for i in range(700_000)) + b'chunk' * 30_000
    (tmp / 'zplain.bin').write_bytes(zplain)
    for name, method, streamed in [('zip-deflate', zipfile.ZIP_DEFLATED, False), ('zip-stored', zipfile.ZIP_STORED, False),
                                   ('zip-deflate-dd', zipfile.ZIP_DEFLATED, True), ('zip-stored-dd', zipfile.ZIP_STORED, True),
                                   ('zip-bzip2', zipfile.ZIP_BZIP2, False)]:
        sink = Unseekable() if streamed else io.BytesIO()
        with zipfile.ZipFile(sink, 'w', method) as archive:
            with archive.open('z', 'w') as entry:
                entry.write(zplain)
        data = bytes(sink.buf) if streamed else sink.getvalue()
        if streamed: assert data[6] & 8, 'expected a data descriptor'
        (tmp / f'{name}.bin').write_bytes(data)
    (tmp / 'checks.c').write_text(c_checks)
    zstd_src = (steam / 'zstd_edu.c').read_text()
    unlocked = zstd_src.replace('pthread_mutex_lock(&g_zstd_safe_lock);', '').replace('pthread_mutex_unlock(&g_zstd_safe_lock);', '')
    assert unlocked != zstd_src
    (tmp / 'zstd_unlocked.c').write_text('#include "zstd_edu.h"\n' + unlocked.replace('#include "zstd_edu.h"', ''))
    common = ['-g', '-O1', '-I', str(steam), str(tmp / 'checks.c'), str(steam / 'lzma_shim.c'), str(steam / 'chunk_zip.c'), '-llzma', '-lz', '-lpthread']
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', TSAN_OPTIONS='halt_on_error=1')
    args = [str(tmp / n) for n in ('plain.bin', 'props.bin', 'stream.bin', 'zplain.bin', 'zip-deflate.bin', 'zip-stored.bin', 'zip-deflate-dd.bin', 'zip-stored-dd.bin', 'zip-bzip2.bin')]
    for sanitizer in ['address,undefined', 'thread']:
        exe = tmp / ('c-' + sanitizer.split(',')[0])
        subprocess.run([CLANG, f'-fsanitize={sanitizer}'] + common + [str(steam / 'zstd_edu.c'), '-o', str(exe)], check=True)
        print(f'--- production decoders under {sanitizer}')
        subprocess.run([str(exe)] + args, check=True, env=env)
    # Control: the pre-ml1310 unlocked wrapper shares one jump target across threads.
    exe = tmp / 'c-unlocked'
    subprocess.run([CLANG, '-fsanitize=thread'] + common + ['-I', str(steam), str(tmp / 'zstd_unlocked.c'), '-o', str(exe)], check=True)
    result = subprocess.run([str(exe)] + args, env=env, capture_output=True, text=True)
    warning = next((line for line in result.stderr.splitlines() if 'WARNING: ThreadSanitizer' in line), '')
    raced = bool(warning)
    print(f'PASS: unlocked control is reported by ThreadSanitizer ({warning.strip()})' if raced else 'FAIL: unlocked control not detected')
    if not raced: raise SystemExit(1)
print('PASS: ml1310 steam native host checks complete')
