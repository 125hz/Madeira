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
