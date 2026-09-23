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

    /// Something is left to do before the game can start.
    var active: Bool { phase >= .queued }
    /// Steam is verifying, downloading or installing right now. (Steam pauses
    /// other downloads while a game runs, so a paused record is not shown
    /// over gameplay.)
    var working: Bool { phase >= .verifying }

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
    var fraction: Double? { counts.map { Double($0.done) / Double($0.all) } }
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
    var detail: String? { pending.count > 1 ? "\(pending.count) items still to update" : nil }

    /// Numbers only: App IDs, byte counts, phase.
    var logFields: String {
        "phase=\(phase.name) done=\(downloaded) total=\(total) pct=\(percent.map(String.init) ?? "-") " +
        "stage=\(staged)/\(toStage) pending=\(pending.isEmpty ? "-" : pending.map(String.init).joined(separator: ",")) " +
        "apps=\(tracked) unreadable=\(unreadable)"
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

    static func readBounded(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: (1 << 20) + 1)) ?? Data()
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
