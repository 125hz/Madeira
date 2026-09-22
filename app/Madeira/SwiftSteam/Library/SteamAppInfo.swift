// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation

/// Parsed app metadata from Steam PICS
struct SteamAppInfo {
    let appID: UInt32
    var name: String = ""
    var type: AppType = .game
    var installDir: String = ""
    var oslist: String = ""         // "macos", "windows", "macos,windows", etc.
    var depots: [DepotInfo] = []
    var launchConfigs: [LaunchConfig] = []
    var buildID: UInt32 = 0

    // Cloud save info
    var cloudSaveEnabled: Bool = false
    var cloudSaveFiles: [CloudSaveFile] = []

    enum AppType: String {
        case game = "Game"
        case dlc = "DLC"
        case tool = "Tool"
        case demo = "Demo"
        case application = "Application"
        case music = "Music"
        case unknown = ""

        var isPlayable: Bool {
            self == .game || self == .demo || self == .application
        }
    }

    struct DepotInfo {
        var depotID: UInt32
        var name: String = ""
        var maxSize: UInt64 = 0
        var oslist: String = ""     // "macos", "windows", etc.
        var osarch: String = ""     // "64", "32"
        var dlcAppID: UInt32? = nil
        var manifests: [String: UInt64] = [:]  // branch -> manifestID ("public" is default)
        /// Compressed download size from the modern manifests-dict format
        /// (`manifests.public.download`). 0 when PICS sent the legacy flat
        /// gid format or omitted it.
        var publicDownloadBytes: UInt64 = 0
        /// On-disk size from `manifests.public.size`. 0 when absent.
        var publicSizeBytes: UInt64 = 0
        /// `sharedinstall "1"` marks redistributable depots (DirectX, VC++
        /// runtimes) that live in Steam's common store, not the game dir —
        /// excluded from size math.
        var isSharedInstall: Bool = false
        /// `config.language`: empty for common content, otherwise one
        /// language pack ("english", "german", ...).
        var language: String = ""
        /// `config.lowviolence "1"`: regional alternate content.
        var lowViolence: Bool = false

        /// Check if depot is for the specified OS
        func supports(os: String) -> Bool {
            oslist.isEmpty || oslist.lowercased().contains(os.lowercased())
        }

        /// Get the public branch manifest ID
        var publicManifestID: UInt64? {
            manifests["public"]
        }
    }

    struct LaunchConfig {
        var executable: String = ""
        var arguments: String = ""
        var description: String = ""
        var oslist: String = ""
        var osarch: String = ""
        var type: String = ""       // "default", "option1", etc.

        func supports(os: String) -> Bool {
            oslist.isEmpty || oslist.lowercased().contains(os.lowercased())
        }
    }

    struct CloudSaveFile {
        var root: String = ""      // "gameinstall", "WinMyDocuments", etc.
        var path: String = ""      // Relative path pattern
        var pattern: String = ""   // File pattern (e.g., "*.sav")
        var recursive: Bool = false
    }

    // MARK: - Computed Properties

    var supportsMac: Bool {
        oslist.lowercased().contains("macos") || oslist.lowercased().contains("mac")
    }

    var supportsWindows: Bool {
        oslist.lowercased().contains("windows") || oslist.isEmpty
    }

    /// Get depots for a specific platform
    func depots(for os: String) -> [DepotInfo] {
        depots.filter { $0.supports(os: os) }
    }

    /// Madeira: the depots a Windows client would install for this app,
    /// following the same rules as Valve's DepotDownloader: matching OS,
    /// architecture-neutral or matching osarch, common or requested-language
    /// content, no low-violence alternates, no DLC or shared redistributables,
    /// and only depots that publish a public manifest. A 64-bit selection
    /// falls back to 32-bit depots when the app only publishes those.
    func installDepots(os: String = "windows", arch: String = "64",
                       language: String = "english") -> [DepotInfo] {
        func select(_ arch: String) -> [DepotInfo] {
            depots.filter { d in
                d.supports(os: os) && d.dlcAppID == nil && !d.isSharedInstall &&
                d.publicManifestID != nil && !d.lowViolence &&
                (d.osarch.isEmpty || d.osarch == arch) &&
                (d.language.isEmpty || d.language.caseInsensitiveCompare(language) == .orderedSame)
            }.sorted { $0.depotID < $1.depotID }
        }
        let preferred = select(arch)
        if arch == "64", !preferred.contains(where: { $0.osarch == "64" }),
           depots.contains(where: { $0.osarch == "32" && $0.supports(os: os) }) {
            return select("32")
        }
        return preferred
    }

    /// Madeira: owned apps that can be installed for Windows at all.
    var installableOnWindows: Bool {
        supportsWindows && type.isPlayable && !installDepots().isEmpty
    }

    /// Approximate download size for a platform. Per depot, prefers the
    /// modern `manifests.public.download` figure (compressed download —
    /// present for most apps since Valve's 2023 PICS change), falling back
    /// to the legacy `maxsize` field (absent for many apps, which is why
    /// this used to come up empty). Depots tagged with a `dlcAppID`
    /// (bonus/DLC content) and `sharedinstall` redistributables are
    /// excluded — they're not part of the base install this figure is
    /// meant to represent. Treat as "about".
    func downloadSize(for os: String) -> UInt64 {
        installDepots(os: os).reduce(0) { total, d in
            let bytes = d.publicDownloadBytes > 0 ? d.publicDownloadBytes : d.maxSize
            guard bytes > 0 else { return total }
            // Sizes are parsed from untrusted PICS VDF strings with no
            // bound — saturate instead of trapping if a malformed depot
            // entry overflows the sum.
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? UInt64.max : sum
        }
    }

    /// Get launch configs for a specific platform
    func launchConfigs(for os: String) -> [LaunchConfig] {
        launchConfigs.filter { $0.supports(os: os) }
    }

    // MARK: - Parsing

    /// Parse app info from a PICS text-VDF buffer.
    static func parse(appID: UInt32, from data: Data) -> SteamAppInfo? {
        let vdf = VDFParser.parseTextVDF(from: data)
        return parse(appID: appID, from: vdf)
    }

    /// Parse app info from a VDF dictionary
    static func parse(appID: UInt32, from vdf: [String: Any]) -> SteamAppInfo? {
        var info = SteamAppInfo(appID: appID)

        // Navigate to appinfo section
        let appInfo: [String: Any]
        if let nested = vdf["\(appID)"] as? [String: Any] {
            appInfo = nested
        } else if let nested = vdf["appinfo"] as? [String: Any] {
            appInfo = nested
        } else {
            appInfo = vdf
        }

        // Common section
        if let common = appInfo["common"] as? [String: Any] {
            info.name = common["name"] as? String ?? ""
            info.type = AppType(rawValue: common["type"] as? String ?? "") ?? .unknown
            info.oslist = common["oslist"] as? String ?? ""
        }

        // Config section
        if let config = appInfo["config"] as? [String: Any] {
            info.installDir = config["installdir"] as? String ?? ""
            if let launchSection = config["launch"] as? [String: Any] {
                for (_, launchData) in launchSection {
                    guard let launch = launchData as? [String: Any] else { continue }
                    var lc = LaunchConfig()
                    lc.executable = launch["executable"] as? String ?? ""
                    lc.arguments = launch["arguments"] as? String ?? ""
                    lc.description = launch["description"] as? String ?? ""
                    if let launchConfig = launch["config"] as? [String: Any] {
                        lc.oslist = launchConfig["oslist"] as? String ?? ""
                        lc.osarch = launchConfig["osarch"] as? String ?? ""
                    }
                    lc.type = launch["type"] as? String ?? ""
                    info.launchConfigs.append(lc)
                }
            }
        }

        // Depots section
        if let depots = appInfo["depots"] as? [String: Any] {
            for (key, depotData) in depots {
                guard let depotID = UInt32(key),
                      let depot = depotData as? [String: Any] else { continue }

                var di = DepotInfo(depotID: depotID)
                di.name = depot["name"] as? String ?? ""
                if let config = depot["config"] as? [String: Any] {
                    di.oslist = config["oslist"] as? String ?? ""
                    di.osarch = config["osarch"] as? String ?? ""
                    di.language = config["language"] as? String ?? ""
                    di.lowViolence = (config["lowviolence"] as? String) == "1"
                }
                if let maxSizeStr = depot["maxsize"] as? String, let maxSize = UInt64(maxSizeStr) {
                    di.maxSize = maxSize
                } else if let maxSize = depot["maxsize"] as? UInt32 {
                    di.maxSize = UInt64(maxSize)
                }
                // Text-VDF leaves every leaf as String — check that first
                // (the UInt32 branch is kept for any binary-VDF caller).
                if let dlcStr = depot["dlcappid"] as? String, let dlc = UInt32(dlcStr) {
                    di.dlcAppID = dlc
                } else if let dlc = depot["dlcappid"] as? UInt32 {
                    di.dlcAppID = dlc
                }
                di.isSharedInstall = (depot["sharedinstall"] as? String) == "1"
                if let manifests = depot["manifests"] as? [String: Any] {
                    for (branch, entry) in manifests {
                        if let gidStr = entry as? String, let gid = UInt64(gidStr) {
                            // Legacy flat format: branch -> gid string.
                            di.manifests[branch] = gid
                        } else if let gid = entry as? UInt64 {
                            di.manifests[branch] = gid
                        } else if let dict = entry as? [String: Any] {
                            // Modern format (2023+): branch -> { gid, size,
                            // download }. This is where most apps carry
                            // their sizes now — many no longer set maxsize.
                            if let gidStr = dict["gid"] as? String, let gid = UInt64(gidStr) {
                                di.manifests[branch] = gid
                            }
                            if branch == "public" {
                                if let dStr = dict["download"] as? String, let d = UInt64(dStr) {
                                    di.publicDownloadBytes = d
                                }
                                if let sStr = dict["size"] as? String, let s = UInt64(sStr) {
                                    di.publicSizeBytes = s
                                }
                            }
                        }
                    }
                }
                info.depots.append(di)
            }

            // Build ID
            if let branches = depots["branches"] as? [String: Any],
               let publicBranch = branches["public"] as? [String: Any] {
                if let buildIDStr = publicBranch["buildid"] as? String, let buildID = UInt32(buildIDStr) {
                    info.buildID = buildID
                } else if let buildID = publicBranch["buildid"] as? UInt32 {
                    info.buildID = buildID
                }
            }
        }

        // UFS (cloud saves)
        if let ufs = appInfo["ufs"] as? [String: Any] {
            info.cloudSaveEnabled = true
            if let savefiles = ufs["savefiles"] as? [String: Any] {
                for (_, fileData) in savefiles {
                    guard let file = fileData as? [String: Any] else { continue }
                    var csf = CloudSaveFile()
                    csf.root = file["root"] as? String ?? ""
                    csf.path = file["path"] as? String ?? ""
                    csf.pattern = file["pattern"] as? String ?? ""
                    csf.recursive = (file["recursive"] as? String) == "1"
                    info.cloudSaveFiles.append(csf)
                }
            }
        }

        // Filter out non-game types unless explicitly wanted
        guard !info.name.isEmpty else { return nil }

        return info
    }
}
