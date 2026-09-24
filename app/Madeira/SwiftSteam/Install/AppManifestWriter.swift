// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation

/// Generates Steam appmanifest .acf files — Steam's on-disk install record.
/// A depot download writes one next to `steamapps/common/<installdir>` so the
/// install is recorded in the same format the real Steam client would produce
/// (useful as the launcher's own install registry, and keeps the library
/// readable if a real client ever opens it).
///
/// The format matches what Steam itself writes — verified against real ACFs
/// on 2026-05-07. Steam is strict-ish about the format; an earlier version
/// of this writer produced ACFs that Steam silently rejected (`Universe`
/// instead of `universe`, missing `LastPlayed`/`StagingSize`/`UpdateResult`/
/// `TargetBuildID`/`ScheduledAutoUpdate`, `BytesDownloaded` set to install
/// size instead of 0, `AutoUpdateBehavior=1` instead of 0).
///
/// The minimum-viable manifest covers the simple "I downloaded these files,
/// here's the size" case. The richer overload (with `installedDepots`) is what
/// the depot installer flow uses — Steam checks the InstalledDepots block to
/// decide whether to re-download. Without it, an app shows as installed but
/// Steam tries to "update" it on first launch, which either fixes the
/// manifest itself or fails noisily depending on conditions.
struct AppManifestWriter {

    /// Write an appmanifest_{appid}.acf file to the Steam library folder.
    /// `installedDepots` is optional — pass it when you want Steam to fully
    /// trust the install (depot install flow); omit for the simpler case
    /// where you just want a placeholder.
    /// `launcherPath` is the in-bottle path to steam.exe; only meaningful
    /// when the install lives in a Wine bottle that a real Steam client
    /// may later read. Headless installs leave it nil.
    /// `buildID` is the depot build id from PICS — pass 0 if unknown
    /// (Steam may still accept the install but flag it for verification on
    /// next launch).
    static func writeManifest(
        appID: UInt32,
        name: String,
        installDir: String,
        buildID: UInt32,
        steamID: UInt64,
        sizeOnDisk: UInt64 = 0,
        steamAppsPath: String? = nil,
        installedDepots: [InstalledDepot]? = nil,
        launcherPath: String? = nil
    ) throws {
        let path = steamAppsPath ?? defaultSteamAppsPath()
        let manifestPath = (path as NSString).appendingPathComponent("appmanifest_\(appID).acf")

        let timestamp = Int(Date().timeIntervalSince1970)

        // Build the body line-by-line so we can interleave optional fields
        // without nested string interpolation soup. Field names + ordering
        // match what Steam Client itself writes — order doesn't seem to
        // matter to the parser, but matching the ordering keeps the file
        // diffable against a real Steam-written manifest.
        var lines: [String] = []
        lines.append("\"AppState\"")
        lines.append("{")
        lines.append("\t\"appid\"\t\t\"\(appID)\"")
        // Lowercase 'universe' — Steam writes it lowercase, and key
        // case-sensitivity of the parser is empirically uncertain. Match
        // exactly to be safe.
        lines.append("\t\"universe\"\t\t\"1\"")
        if let launcherPath {
            lines.append("\t\"LauncherPath\"\t\t\"\(escapeVDFString(launcherPath))\"")
        }
        lines.append("\t\"name\"\t\t\"\(escapeVDFString(name))\"")
        lines.append("\t\"StateFlags\"\t\t\"4\"")  // 4 = fully installed
        lines.append("\t\"installdir\"\t\t\"\(escapeVDFString(installDir))\"")
        lines.append("\t\"LastUpdated\"\t\t\"\(timestamp)\"")
        lines.append("\t\"LastPlayed\"\t\t\"0\"")
        lines.append("\t\"SizeOnDisk\"\t\t\"\(sizeOnDisk)\"")
        lines.append("\t\"StagingSize\"\t\t\"0\"")
        lines.append("\t\"buildid\"\t\t\"\(buildID)\"")
        lines.append("\t\"LastOwner\"\t\t\"\(steamID)\"")
        // DownloadType=1 means "complete install" (vs deferred/partial). Critical
        // for the depot-install flow — without it Steam may decide files are
        // missing and try to re-download.
        if installedDepots != nil {
            lines.append("\t\"DownloadType\"\t\t\"1\"")
        }
        lines.append("\t\"UpdateResult\"\t\t\"0\"")
        // Bytes-downloaded / bytes-staged are POST-install state markers. A
        // completed install has these at 0 — anything non-zero tells Steam
        // there's a queued download. Earlier versions of this writer set
        // them to sizeOnDisk; that put Steam into "verifying download"
        // mode on next launch.
        lines.append("\t\"BytesToDownload\"\t\t\"0\"")
        lines.append("\t\"BytesDownloaded\"\t\t\"0\"")
        lines.append("\t\"BytesToStage\"\t\t\"0\"")
        lines.append("\t\"BytesStaged\"\t\t\"0\"")
        lines.append("\t\"TargetBuildID\"\t\t\"\(buildID)\"")
        // AutoUpdateBehavior 0 = "Always keep this game updated" (the
        // default Steam UI option). Earlier we wrote 1 which means
        // "Only update on launch" — non-default and possibly the trigger
        // for Steam's manifest-rewrite that wiped our libraryfolders.vdf
        // entries.
        lines.append("\t\"AutoUpdateBehavior\"\t\t\"0\"")
        lines.append("\t\"AllowOtherDownloadsWhileRunning\"\t\t\"0\"")
        lines.append("\t\"ScheduledAutoUpdate\"\t\t\"0\"")

        if let installedDepots, !installedDepots.isEmpty {
            lines.append("\t\"InstalledDepots\"")
            lines.append("\t{")
            for depot in installedDepots {
                lines.append("\t\t\"\(depot.depotID)\"")
                lines.append("\t\t{")
                if let manifestGID = depot.manifestGID {
                    lines.append("\t\t\t\"manifest\"\t\t\"\(manifestGID)\"")
                }
                if let bytes = depot.size {
                    lines.append("\t\t\t\"size\"\t\t\"\(bytes)\"")
                }
                if let dlcAppID = depot.dlcAppID {
                    lines.append("\t\t\t\"dlcappid\"\t\t\"\(dlcAppID)\"")
                }
                lines.append("\t\t}")
            }
            lines.append("\t}")
        }

        // UserConfig + MountedConfig blocks are present in every real
        // Steam-written ACF. Most games default to English; Steam uses
        // these to drive language-pack depot selection. We always write
        // English for v1 (i.e. matching the common case); future work
        // could read the user's Steam locale setting.
        lines.append("\t\"UserConfig\"")
        lines.append("\t{")
        lines.append("\t\t\"language\"\t\t\"english\"")
        lines.append("\t}")
        lines.append("\t\"MountedConfig\"")
        lines.append("\t{")
        lines.append("\t\t\"language\"\t\t\"english\"")
        lines.append("\t}")

        lines.append("}")

        let content = lines.joined(separator: "\n")

        // Madeira: a failed install record fails the install instead of
        // leaving downloaded files that no library scan can identify.
        try content.write(toFile: manifestPath, atomically: true, encoding: .utf8)
    }

    /// Remove an appmanifest file
    static func removeManifest(appID: UInt32, steamAppsPath: String? = nil) {
        let path = steamAppsPath ?? defaultSteamAppsPath()
        let manifestPath = (path as NSString).appendingPathComponent("appmanifest_\(appID).acf")
        try? FileManager.default.removeItem(atPath: manifestPath)
    }

    /// Check if an appmanifest exists for an app
    static func manifestExists(appID: UInt32, steamAppsPath: String? = nil) -> Bool {
        let path = steamAppsPath ?? defaultSteamAppsPath()
        let manifestPath = (path as NSString).appendingPathComponent("appmanifest_\(appID).acf")
        return FileManager.default.fileExists(atPath: manifestPath)
    }

    /// Single depot entry inside `InstalledDepots`. All fields are optional —
    /// Steam tolerates missing manifest/size when there's nothing else to
    /// reference (rare). `dlcAppID` is set only for DLC depots, which are
    /// distinguished from base-game depots by Steam.
    struct InstalledDepot {
        let depotID: Int
        let manifestGID: UInt64?
        let size: Int64?
        let dlcAppID: Int?

        init(depotID: Int, manifestGID: UInt64? = nil, size: Int64? = nil, dlcAppID: Int? = nil) {
            self.depotID = depotID
            self.manifestGID = manifestGID
            self.size = size
            self.dlcAppID = dlcAppID
        }
    }

    // MARK: - Helpers

    private static func defaultSteamAppsPath() -> String {
        SteamInstallPaths.steamApps.path
    }

    /// Escape special characters for VDF format
    private static func escapeVDFString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Madeira ml1420: the Windows client's download progress

/// Madeira ml1420: one app's update state, read from the appmanifest the
/// Windows Steam client rewrites while it downloads. StateFlags bits follow
/// the client's EAppState values. Read-only: Madeira never writes these
/// records while the client runs.
struct SteamClientAppState: Equatable {
    enum Phase: Int, Comparable {
        case idle = 0, installed, queued, paused, verifying, staging, downloading
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
        var name: String {
            switch self {
            case .idle: return "idle"
            case .installed: return "installed"
            case .queued: return "queued"
            case .paused: return "paused"
            case .verifying: return "verifying"
            case .staging: return "staging"
            case .downloading: return "downloading"
            }
        }
    }

    var appID: Int
    var flags: UInt64
    var bytesToDownload: UInt64 = 0
    var bytesDownloaded: UInt64 = 0
    var bytesToStage: UInt64 = 0
    var bytesStaged: UInt64 = 0
    /// Apps that own depots this app uses (`SharedDepots` values), in order.
    var sharedOwners: [Int] = []

    /// nil for a missing, oversized, partially written or foreign record.
    static func parse(_ data: Data, appID: Int) -> SteamClientAppState? {
        guard !data.isEmpty, data.count <= 1 << 20, var parser = try? SteamKeyValues(data),
              let root = try? parser.read(), let record = root["AppState"],
              record["appid"]?.string == String(appID),
              let flags = UInt64(record["StateFlags"]?.string ?? "") else { return nil }
        func number(_ key: String) -> UInt64 { UInt64(record[key]?.string ?? "") ?? 0 }
        var state = SteamClientAppState(appID: appID, flags: flags)
        state.bytesToDownload = number("BytesToDownload"); state.bytesDownloaded = number("BytesDownloaded")
        state.bytesToStage = number("BytesToStage"); state.bytesStaged = number("BytesStaged")
        for (_, owner) in (record["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let id = owner.string.flatMap({ Int($0) }), id > 0, id <= Int(UInt32.max), id != appID,
               !state.sharedOwners.contains(id) { state.sharedOwners.append(id) }
        }
        return state
    }

    var phase: Phase {
        if flags & (0x100000 | 0x80000 | 0x40000) != 0 { return .downloading }  // Downloading, Preallocating, AddingFiles
        if flags & (0x200000 | 0x400000) != 0 { return .staging }                // Staging, Committing
        if flags & 0x20000 != 0 { return .verifying }                            // Validating
        if flags & 0x200 != 0 { return .paused }                                 // UpdatePaused
        if flags & (0x100 | 0x400) != 0 {                                        // UpdateRunning, UpdateStarted
            return bytesDownloaded >= bytesToDownload && bytesToDownload > 0 && bytesStaged < bytesToStage ? .staging : .downloading
        }
        if flags & 2 != 0 { return .queued }                                     // UpdateRequired
        if flags & 4 != 0 { return .installed }                                  // FullyInstalled
        return .idle
    }
}

/// Madeira ml1420: combined progress of a launched app and the apps that own
/// its shared depots.
struct SteamClientProgress: Equatable {
    typealias Phase = SteamClientAppState.Phase
    var phase: Phase = .idle
    var downloaded: UInt64 = 0
    var total: UInt64 = 0
    var staged: UInt64 = 0
    var toStage: UInt64 = 0
    /// App IDs still updating or waiting to update, ascending.
    var pending: [Int] = []
    var tracked = 0
    var unreadable = 0
    /// Madeira ml1490: the launched app's Workshop update, when one runs.
    var workshop: SteamWorkshopProgress?
    /// Madeira ml1510: what the client is doing, for the starting screen.
    var stage: SteamLaunchStage?

    /// Something is left to do before the game can start.
    var active: Bool { phase >= .queued || workshop?.active == true }
    /// Steam is verifying, downloading or installing right now. (Steam pauses
    /// other downloads while a game runs, so a paused record is not shown
    /// over gameplay.)
    var working: Bool { phase >= .verifying || workshop?.working == true }
    /// ml1490: report the Workshop update, unless the app's own content still
    /// has unfinished figures (Steam updates the app first, then its Workshop items).
    private var showsWorkshop: Bool {
        guard workshop?.active == true else { return false }
        guard phase >= .verifying, let counts else { return true }
        return counts.done >= counts.all
    }

    private static func sum(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b); return overflow ? .max : value
    }

    /// `involved`: apps seen updating earlier in this session; they stay in
    /// the totals after they finish, so the figures do not jump back.
    static func combine(_ states: [SteamClientAppState], involved: Set<Int>) -> SteamClientProgress {
        var result = SteamClientProgress()
        result.tracked = states.count
        for state in states {
            let phase = state.phase
            result.phase = max(result.phase, phase)
            if phase >= .queued { result.pending.append(state.appID) }
            // A waiting record's counters may be left over from an earlier
            // update; count them only when they describe unfinished work.
            guard phase >= .paused || involved.contains(state.appID) ||
                  (phase == .queued && state.bytesToDownload > state.bytesDownloaded) else { continue }
            result.total = sum(result.total, state.bytesToDownload)
            result.downloaded = sum(result.downloaded, min(state.bytesDownloaded, state.bytesToDownload))
            result.toStage = sum(result.toStage, state.bytesToStage)
            result.staged = sum(result.staged, min(state.bytesStaged, state.bytesToStage))
        }
        result.pending.sort()
        return result
    }

    private var staging: Bool { phase == .staging && toStage > 0 }
    /// The figures the current phase reports: staged bytes while staging, else downloaded bytes.
    private var counts: (done: UInt64, all: UInt64)? {
        if staging { return (min(staged, toStage), toStage) }
        guard total > 0, phase >= .queued else { return nil }
        return (min(downloaded, total), total)
    }
    var fraction: Double? {
        if showsWorkshop { return workshop?.fraction }
        return counts.map { Double($0.done) / Double($0.all) }
    }
    var percent: Int? { counts.map { Int((Double($0.done) * 100 / Double($0.all)).rounded(.down)) } }

    static func size(_ bytes: UInt64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
    static func amount(_ done: UInt64, of total: UInt64) -> String {
        if done >= 1_000_000_000 || (total >= 1_000_000_000 && done == 0) {
            return String(format: "%.1f of %.1f GB", Double(done) / 1e9, Double(total) / 1e9)
        }
        return size(done) + " of " + size(total)
    }

    /// One line for the starting screen, or nil when there is nothing to report.
    var summary: String? {
        if showsWorkshop, let workshop { return workshop.summary }
        let figures: String? = staging ? Self.amount(staged, of: toStage) : total > 0 ? Self.amount(downloaded, of: total) : nil
        let suffix = figures.map { ": \($0) (\(percent ?? 0)%)" }
        switch phase {
        case .downloading: return "Steam is downloading game content" + (suffix ?? "…")
        case .staging: return "Steam is installing downloaded content" + (suffix ?? "…")
        case .verifying: return "Steam is verifying game files…"
        case .paused: return "Steam paused the content download" + (suffix ?? ".")
        case .queued: return "Steam needs to update game content before the game can start."
        case .installed, .idle: return nil
        }
    }
    var detail: String? {
        if showsWorkshop, let workshop { return workshop.detail }
        return pending.count > 1 ? "\(pending.count) items still to update" : nil
    }

    /// Numbers only: App IDs, byte counts, phase.
    var logFields: String {
        "phase=\(phase.name) done=\(downloaded) total=\(total) pct=\(percent.map(String.init) ?? "-") " +
        "stage=\(staged)/\(toStage) pending=\(pending.isEmpty ? "-" : pending.map(String.init).joined(separator: ",")) " +
        "apps=\(tracked) unreadable=\(unreadable)" + (workshop.map { " workshop=" + $0.logFields } ?? "")
    }
}

// MARK: - Madeira ml1510: what the client is doing while the starting screen waits

/// Madeira ml1510: the client's progress through a game launch, read from the
/// lines it appends to logs/connection_log.txt and logs/content_log.txt:
///   [..] [Logged Off, 4, 0] [U:1:#] LogOn() called; not connected yet, scheduling connection. ...
///   [..] [Logged On, 4, 7] [U:1:#] RecvMsgClientLogOnResponse() : processing complete
///   [..] ConnectionDisconnected() not auto reconnecting due to Invalid Password
///   [..] AppID 7000 state changed : Fully Installed,Update Queued,Update Running,
///   [..] AppID 7000 state changed : Fully Installed,App Running,
/// ml1520: and from logs/console_log.txt, the launch task the client is on:
///   [..] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to ProcessingInstallScript with ""
/// Stages only move forward, except that a rejected sign-in can follow any of them.
enum SteamLaunchStage: Int, Comparable {
    case starting, signingIn, signedIn, updating, preparing, needsInput, installers, cloudSync, gameStarting, needsSignIn

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    static let all: [SteamLaunchStage] = [.starting, .signingIn, .signedIn, .updating, .preparing, .needsInput, .installers,
                                          .cloudSync, .gameStarting, .needsSignIn]
    static var allTextsDistinct: Bool { Set(all.map(\.text)).count == all.count }

    var name: String {
        switch self {
        case .starting: return "starting"
        case .signingIn: return "signing-in"
        case .signedIn: return "signed-in"
        case .updating: return "updating"
        case .preparing: return "preparing"
        case .needsInput: return "needs-input"
        case .installers: return "installers"
        case .cloudSync: return "cloud-sync"
        case .gameStarting: return "game-starting"
        case .needsSignIn: return "needs-sign-in"
        }
    }

    /// The starting screen's main line.
    var text: String {
        switch self {
        case .starting: return "Starting Steam…"
        case .signingIn: return "Signing in to Steam…"
        case .signedIn: return "Signed in. Steam is getting the game ready…"
        case .updating: return "Steam is updating the game…"
        case .preparing: return "Steam is preparing the game…"
        case .needsInput: return "Steam is waiting for you. Its window opens here in a moment."
        case .installers: return "Steam is checking the game's one-time installs…"
        case .cloudSync: return "Steam is syncing cloud saves…"
        case .gameStarting: return "Starting the game…"
        case .needsSignIn: return "Steam needs you to sign in. Tap Show Steam."
        }
    }

    /// A second line, or nil.
    var detail: String? {
        switch self {
        case .signedIn, .preparing:
            return "The first start of a game can include one-time installs such as DirectX."
        case .needsInput: return "Usually a license agreement or a notice for this game. Steam can take a few seconds to draw it."
        case .installers: return "DirectX, Visual C++ and similar. Steam checks them before a start."
        case .gameStarting: return "The game is loading. This can take a moment."
        default: return nil
        }
    }

    /// The next stage after one client log line, for the launched `appID`.
    func after(_ line: String, appID: Int) -> SteamLaunchStage {
        if line.contains("Invalid Password") || line.contains("not auto reconnecting") { return .needsSignIn }
        let signedIn = line.contains("[Logged On") || line.contains("RecvMsgClientLogOnResponse() : processing complete")
        // After a rejected sign-in, only a later sign-in moves on.
        if self == .needsSignIn { return signedIn ? .signedIn : self }
        var next = self
        if line.contains("LogOn() called") || line.contains("Logging on") { next = .signingIn }
        if signedIn { next = .signedIn }
        if let range = line.range(of: "AppID \(appID) state changed :") {
            let states = line[range.upperBound...].lowercased()
            if states.contains("app running") { next = .gameStarting }
            else if states.contains("update running") || states.contains("update started") { next = .updating }
            else if states.contains("fully installed") { next = .preparing }
        }
        // ml1530: "waiting for user response to <task>" is Steam holding the launch for a screen
        // (license agreement, interstitials; device logs 198/199) whatever came before it, so it
        // wins over the forward order; "continues with user response" or the next task ends it.
        // CreatingProcess also "waits" for a moment on every start, and is not a screen.
        if line.contains("GameAction [AppID \(appID),") {
            if let range = line.range(of: "waiting for user response to ") {
                let task = line[range.upperBound...].prefix { !$0.isWhitespace }.lowercased()
                if !task.contains("creatingprocess") && self != .needsSignIn { return .needsInput }
            }
            if self == .needsInput, line.contains("continues with user response") { return .preparing }
        }
        if self == .needsInput, line.contains("GameAction [AppID \(appID),"), line.contains("changed task to ") {
            return SteamLaunchStage.preparing.after(line, appID: appID)
        }
        // ml1520: console_log.txt launch tasks
        if line.contains("GameAction [AppID \(appID),"), let range = line.range(of: "changed task to ") {
            let task = line[range.upperBound...].prefix { !$0.isWhitespace }.lowercased()
            if task.contains("eula") || task.contains("cdkey") || task.contains("dialog") { next = .needsInput }
            else if task.contains("installscript") { next = .installers }
            else if task.contains("cloud") { next = .cloudSync }
            else if task.contains("creatingprocess") || task.contains("waitinggamewindow") || task.contains("completed") {
                next = .gameStarting
            }
        }
        return max(self, next)
    }
}

/// Madeira ml1510: follows the client logs for one launch (ml1520: and its console log).
struct SteamLaunchStageTracker {
    let appID: Int
    private(set) var stage = SteamLaunchStage.starting
    private var connection = SteamLogTail()
    private var content = SteamLogTail()
    private var console = SteamLogTail()

    init(appID: Int) { self.appID = appID }

    mutating func poll(connectionLog: URL?, contentLog: URL?, consoleLog: URL? = nil) {
        for url in [connectionLog, contentLog, consoleLog].compactMap({ $0 }) {
            let lines = url == connectionLog ? connection.read(url) : url == contentLog ? content.read(url) : console.read(url)
            for line in lines { stage = stage.after(line, appID: appID) }
        }
    }
}

// MARK: - Madeira ml1490: Workshop content the client updates before a start

/// Madeira ml1490: the launched app's Workshop update, read from the Windows
/// client's content_log.txt. The client holds a game's start while it updates
/// the Workshop items the account subscribes to. Those can be far larger than
/// the game (device log 187: 36 GB) and the app's own manifest does not show
/// them. The client writes, for example:
///   [date time] AppID 7000 Workshop update changed : Running Update,Downloading,Staging,
///   [date time] AppID 7000 update started : download 396293552/36271038464, store 0/0, reuse 0/0, delta 0/0, stage 762126893/72100190136
/// An "update started" line belongs to whichever update ("App" or "Workshop")
/// the same app reported last. Its figures describe the update when it started;
/// the log reports no progress after that.
struct SteamWorkshopLog: Equatable {
    typealias Phase = SteamClientAppState.Phase
    let appID: Int
    private(set) var phase: Phase = .idle
    private(set) var downloaded: UInt64 = 0
    private(set) var total: UInt64 = 0
    private(set) var staged: UInt64 = 0
    private(set) var toStage: UInt64 = 0
    private var workshopLast = false

    init(appID: Int) { self.appID = appID }

    /// The client's comma-separated update states.
    static func phase(_ states: String) -> Phase {
        let text = states.lowercased().trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("none") { return .idle }
        if text.contains("downloading") || text.contains("preallocating") { return .downloading }
        if text.contains("staging") || text.contains("committing") { return .staging }
        if text.contains("verifying") || text.contains("validating") { return .verifying }
        if text.contains("paused") || text.contains("suspended") { return .paused }
        return .queued   // "Running Update", "Reconfiguring": preparing
    }

    /// `done/all` after `key ` in an "update started" line.
    static func figures(_ text: Substring, _ key: String) -> (UInt64, UInt64)? {
        guard let range = text.range(of: key + " ") else { return nil }
        let pair = text[range.upperBound...].prefix { $0.isNumber || $0 == "/" }.split(separator: "/")
        guard pair.count == 2, let done = UInt64(pair[0]), let all = UInt64(pair[1]) else { return nil }
        return (done, all)
    }

    mutating func feed(_ line: String) {
        guard let range = line.range(of: "AppID \(appID) ") else { return }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("Workshop update changed :") {
            workshopLast = true
            phase = Self.phase(String(rest.dropFirst("Workshop update changed :".count)))
            if phase == .idle { downloaded = 0; total = 0; staged = 0; toStage = 0 }
        } else if rest.hasPrefix("App update changed :") {
            workshopLast = false
        } else if workshopLast, rest.hasPrefix("update started :") {
            if let pair = Self.figures(rest, "download") { downloaded = min(pair.0, pair.1); total = pair.1 }
            if let pair = Self.figures(rest, "stage") { staged = min(pair.0, pair.1); toStage = pair.1 }
        }
    }
}

/// Madeira ml1490: counts from the client's record of an app's Workshop items,
/// steamapps/workshop/appworkshop_<appid>.acf. Item IDs and the subscribing
/// account in that record are never kept or logged.
struct SteamWorkshopItems: Equatable {
    /// Items the record lists as subscribed (its item details), else those installed.
    var subscribed = 0
    /// Of those, the items with installed content.
    var installed = 0
    var needsDownload = false

    static func parse(_ data: Data, appID: Int) -> SteamWorkshopItems? {
        guard !data.isEmpty, data.count <= 4 << 20, var parser = try? SteamKeyValues(data),
              let root = try? parser.read(), let record = root["AppWorkshop"],
              record["appid"]?.string == String(appID) else { return nil }
        let installed = Set((record["WorkshopItemsInstalled"]?.fields ?? [:]).keys)
        let details = Set((record["WorkshopItemDetails"]?.fields ?? [:]).keys)
        var items = SteamWorkshopItems()
        items.subscribed = details.isEmpty ? installed.count : details.count
        items.installed = details.isEmpty ? installed.count : details.intersection(installed).count
        items.needsDownload = record["NeedsDownload"]?.string == "1" || record["NeedsUpdate"]?.string == "1"
        return items
    }
}

/// Madeira ml1490: what the starting screen says about a Workshop update.
struct SteamWorkshopProgress: Equatable {
    typealias Phase = SteamClientAppState.Phase
    var phase: Phase = .idle
    /// The update's download size and what was already downloaded, when it started.
    var downloaded: UInt64 = 0
    var total: UInt64 = 0
    var items: SteamWorkshopItems?
    /// The installed-item count changed during this launch, so it measures progress.
    var itemsLive = false

    var active: Bool { phase >= .queued }
    var working: Bool { phase >= .verifying }

    var fraction: Double? {
        guard itemsLive, let items, items.subscribed > 0 else { return nil }
        return Double(min(items.installed, items.subscribed)) / Double(items.subscribed)
    }

    var summary: String {
        let size = total > 0 ? " (\(SteamClientProgress.size(total)))" : ""
        switch phase {
        case .downloading: return "Steam is downloading Workshop items\(size) before the game starts."
        case .staging: return "Steam is installing Workshop items before the game starts."
        case .verifying: return "Steam is checking Workshop items before the game starts."
        case .paused: return "Steam paused the Workshop update for this game."
        default: return "Steam is updating Workshop items before the game starts."
        }
    }

    var detail: String {
        var text = "Workshop items are add-ons you subscribed to in Steam for this game."
        if let items, items.subscribed > 0 {
            text += itemsLive ? " \(items.installed) of \(items.subscribed) installed."
                              : " \(items.subscribed) subscribed item\(items.subscribed == 1 ? "" : "s")."
        }
        return text
    }

    /// Numbers only.
    var logFields: String {
        "\(phase.name) download=\(downloaded)/\(total) items=\(items.map { "\($0.installed)/\($0.subscribed)" } ?? "-") live=\(itemsLive ? 1 : 0)"
    }
}

/// Madeira ml1490: new complete lines of a text log the client appends to,
/// from where it ended when following began (the first read only records the
/// end). Bounded per read. A log that shrank was rotated and is read from its start.
struct SteamLogTail {
    static let limit = 256 * 1024, maxLine = 16 * 1024
    private var offset: UInt64?
    private var partial = Data()

    mutating func read(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            if offset == nil { offset = 0 }   // not written yet: follow it from its start
            return []
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard var start = offset else { offset = size; return [] }
        if size < start { start = 0; partial.removeAll() }
        guard size > start, (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(min(size - start, UInt64(Self.limit)))) else { offset = start; return [] }
        offset = start + UInt64(data.count)
        partial.append(data)
        var lines: [String] = []
        var lineStart = partial.startIndex
        for index in partial.indices where partial[index] == 10 {
            lines.append(String(decoding: partial[lineStart..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            lineStart = index + 1
        }
        partial = Data(partial[lineStart...])
        if partial.count > Self.maxLine { partial.removeAll() }
        return lines
    }
}

/// Madeira ml1490: follows the launched app's Workshop update during one
/// launch: the client's content log every poll, its Workshop record at most
/// every `itemsInterval` s while an update runs.
struct SteamWorkshopTracker {
    static let itemsInterval = 10.0
    private(set) var log: SteamWorkshopLog
    private var tail = SteamLogTail()
    private(set) var items: SteamWorkshopItems?
    private var firstInstalled: Int?
    private(set) var itemsLive = false
    private var itemsRead = -Double.infinity

    init(appID: Int) { log = SteamWorkshopLog(appID: appID) }

    mutating func poll(logFile: URL?, libraries: [URL], now: Double) {
        if let logFile { for line in tail.read(logFile) { log.feed(line) } }
        guard log.phase >= .queued, now - itemsRead >= Self.itemsInterval else { return }
        itemsRead = now
        for library in libraries {
            let file = library.appendingPathComponent("workshop/appworkshop_\(log.appID).acf")
            guard let data = SteamClientProgressTracker.readBounded(file, limit: 4 << 20) else { continue }
            // A record being rewritten keeps the last complete reading.
            if let parsed = SteamWorkshopItems.parse(data, appID: log.appID) {
                items = parsed
                if let first = firstInstalled { if parsed.installed != first { itemsLive = true } }
                else { firstInstalled = parsed.installed }
            }
            break
        }
    }

    /// nil while no Workshop update runs.
    var progress: SteamWorkshopProgress? {
        guard log.phase != .idle else { return nil }
        return SteamWorkshopProgress(phase: log.phase, downloaded: log.downloaded, total: log.total, items: items, itemsLive: itemsLive)
    }
}

/// Madeira ml1420: follows one launched app and the owners of its shared
/// depots across polls. A record the client is rewriting (or has briefly
/// removed) keeps its last complete reading.
struct SteamClientProgressTracker {
    static let maxApps = 16
    let appID: Int
    private(set) var states: [Int: SteamClientAppState] = [:]
    private(set) var involved = Set<Int>()
    private(set) var unreadable = 0
    private var peaks: [Int: (download: UInt64, stage: UInt64)] = [:]

    init(appID: Int) { self.appID = appID }

    /// The launched app first, then the apps its record names as owners.
    var appIDs: [Int] {
        var ids = [appID]
        for owner in states[appID]?.sharedOwners ?? [] where ids.count < Self.maxApps && !ids.contains(owner) { ids.append(owner) }
        return ids
    }

    /// `data` nil: no record found. Unreadable data counts as a partial write.
    mutating func record(_ id: Int, data: Data?) {
        guard let data else { return }
        guard var state = SteamClientAppState.parse(data, appID: id) else { unreadable += 1; return }
        if state.phase >= .paused {
            involved.insert(id)
            let peak = peaks[id] ?? (0, 0)
            peaks[id] = (max(peak.download, state.bytesToDownload), max(peak.stage, state.bytesToStage))
        } else if state.phase < .queued, state.bytesToDownload == 0, let peak = peaks[id] {
            // A finished update may reset its counters; keep its share complete.
            state.bytesToDownload = peak.download; state.bytesDownloaded = peak.download
            state.bytesToStage = peak.stage; state.bytesStaged = peak.stage
        }
        states[id] = state
    }

    /// Reads the launched app first, so a newly listed owner is followed in the same pass.
    mutating func poll(libraries: [URL]) {
        record(appID, data: Self.read(appID, libraries: libraries))
        for id in appIDs.dropFirst() { record(id, data: Self.read(id, libraries: libraries)) }
    }

    var progress: SteamClientProgress {
        var result = SteamClientProgress.combine(appIDs.compactMap { states[$0] }, involved: involved)
        result.unreadable = unreadable
        return result
    }

    static func readBounded(_ url: URL, limit: Int = 1 << 20) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit + 1)) ?? Data()
    }

    static func read(_ id: Int, libraries: [URL]) -> Data? {
        for library in libraries {
            if let data = readBounded(library.appendingPathComponent("appmanifest_\(id).acf")) { return data }
        }
        return nil
    }

    /// Steam library folders to search: the given steamapps folders, then the
    /// libraries their libraryfolders.vdf lists inside drive_c. At most 8.
    static func libraries(primary: [URL], drive: URL) -> [URL] {
        var result: [URL] = [], seen = Set<String>()
        func add(_ url: URL) {
            if result.count < 8, seen.insert(url.standardizedFileURL.path.lowercased()).inserted { result.append(url) }
        }
        primary.forEach(add)
        for folder in primary {
            guard let data = readBounded(folder.appendingPathComponent("libraryfolders.vdf")), data.count <= 1 << 20,
                  var parser = try? SteamKeyValues(data), let table = try? parser.read()["libraryfolders"] else { continue }
            for (key, value) in table.fields.sorted(by: { $0.key < $1.key }) where Int(key) != nil {
                if let path = value["path"]?.string ?? value.string, let root = SteamPaths.windowsFolder(path, drive: drive) {
                    add(root.appendingPathComponent("steamapps", isDirectory: true))
                }
            }
        }
        return result
    }
}

/// Madeira ml1420: when to write a progress line. Phase changes (at most one
/// per 5 s) and, while something is left to do, changed figures at most every
/// 30 s; never more than `cap` lines per session.
struct SteamClientProgressLog {
    static let interval: Double = 30, phaseInterval: Double = 5, cap = 240
    private var phase: SteamClientProgress.Phase?
    private var fields = ""
    private var last = 0.0
    private(set) var lines = 0

    mutating func line(_ progress: SteamClientProgress, now: Double) -> String? {
        guard lines < Self.cap else { return nil }
        let text = progress.logFields
        let changed = progress.phase != phase
        let due = changed ? (phase == nil || now - last >= Self.phaseInterval)
                          : (progress.active && text != fields && now - last >= Self.interval)
        guard due else { return nil }
        phase = progress.phase; fields = text; last = now; lines += 1
        return text
    }
}
