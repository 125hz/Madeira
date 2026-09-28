import Foundation

// Valve's text KeyValues format is used for library folders and app manifests.
// Keep this reader independent of the UI and never write Steam's own files.
indirect enum SteamValue: Sendable {
    case text(String)
    case object([String: SteamValue])
    var fields: [String: SteamValue] { if case .object(let value) = self { return value }; return [:] }
    var string: String? { if case .text(let value) = self { return value }; return nil }
    subscript(_ key: String) -> SteamValue? { fields[key.lowercased()] }
}

enum SteamFileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

struct SteamKeyValues {
    private var bytes: [UInt8]
    private var position = 0
    private var tokens = 0
    init(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw SteamFileError.invalid("Steam metadata is too large.") }
        bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { position = 3 }
    }
    private enum Token: Equatable { case word(String), open, close }
    private mutating func token() throws -> Token? {
        while position < bytes.count {
            if bytes[position] <= 32 { position += 1; continue }
            if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                while position < bytes.count && bytes[position] != 10 { position += 1 }
                continue
            }
            break
        }
        guard position < bytes.count else { return nil }
        tokens += 1
        guard tokens <= 100_000 else { throw SteamFileError.invalid("Steam metadata has too many entries.") }
        let first = bytes[position]; position += 1
        if first == 123 { return .open }; if first == 125 { return .close }
        var value: [UInt8] = []
        if first == 34 {
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 { return .word(String(decoding: value, as: UTF8.self)) }
                if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 {
                    value.append(bytes[position]); position += 1
                } else { value.append(byte) }
                guard value.count <= 16_384 else { throw SteamFileError.invalid("Steam metadata contains an oversized value.") }
            }
            throw SteamFileError.invalid("Steam metadata is incomplete. Refresh after the download finishes.")
        }
        value.append(first)
        while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 {
            value.append(bytes[position]); position += 1
            guard value.count <= 16_384 else { throw SteamFileError.invalid("Steam metadata contains an oversized value.") }
        }
        return .word(String(decoding: value, as: UTF8.self))
    }
    mutating func read() throws -> SteamValue { .object(try object(depth: 0)) }
    private mutating func object(depth: Int) throws -> [String: SteamValue] {
        guard depth < 32 else { throw SteamFileError.invalid("Steam metadata is nested too deeply.") }
        var result: [String: SteamValue] = [:]
        while let key = try token() {
            if key == .close {
                guard depth > 0 else { throw SteamFileError.invalid("Steam metadata has an unexpected closing brace.") }
                return result
            }
            guard case .word(let name) = key, let value = try token(), value != .close else {
                throw SteamFileError.invalid("Steam metadata is incomplete. Try refreshing it.")
            }
            switch value {
            case .open: result[name.lowercased()] = .object(try object(depth: depth + 1))
            case .word(let text): result[name.lowercased()] = .text(text)
            case .close: break
            }
        }
        guard depth == 0 else { throw SteamFileError.invalid("Steam metadata is incomplete. Try refreshing it.") }
        return result
    }
}

struct SteamInstalledApp: Sendable, Identifiable {
    let id: Int
    let name: String
    let relativeFolder: String
    let bytes: Int64?
    let installed: Bool
    let needsUpdate: Bool
}

struct SteamSnapshot: Sendable {
    var client: String?
    /// ml1970: the regular desktop client is installed (its web helper exists), not only the
    /// Valve components Madeira Dock prepares. Games can start through desktop Steam only then.
    var desktopClient = false
    var apps: [SteamInstalledApp] = []
    var complete = true
    var skippedLibraries = 0
    var unreadableManifests = 0
}

enum SteamPaths {
    static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
    static let installerRelative = "Madeira/Downloads/SteamSetup.exe"
    static let maximumInstallerBytes: Int64 = 32 * 1024 * 1024
    static func trustedDownload(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["cdn.akamai.steamstatic.com", "cdn.cloudflare.steamstatic.com", "media.steampowered.com"].contains(host)
    }
    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) <= UInt64(UInt32.max) }
    /// ml1970: store artwork hosts only.
    static func trustedArtwork(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".steamstatic.com") || host == "steamcdn-a.akamaihd.net"
    }
    /// ml1970: the full desktop client ships its Chromium web helper under bin/cef/cef.*;
    /// Madeira Dock's component setup deliberately omits it.
    static func hasDesktopClient(root: URL) -> Bool {
        let cef = root.appendingPathComponent("bin/cef", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: cef.path) else { return false }
        return folders.prefix(16).contains { name in
            name.lowercased().hasPrefix("cef.") &&
                FileManager.default.fileExists(atPath: cef.appendingPathComponent(name).appendingPathComponent("steamwebhelper.exe").path)
        }
    }
    static func safeRelative(_ path: String, under root: URL) -> URL? {
        guard !path.isEmpty, path.utf8.count < 900, !path.hasPrefix("/"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }), !path.contains("\"") else { return nil }
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var url = base
        for component in components {
            url = url.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { return nil }
        }
        return url
    }
    static func existing(_ url: URL, drive: URL) -> URL? {
        guard let path = relative(url, drive: drive) else { return nil }
        var result = drive
        for component in path.split(separator: "/") {
            let exact = result.appendingPathComponent(String(component))
            if FileManager.default.fileExists(atPath: exact.path) { result = exact }
            else {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: result.path),
                      let match = names.first(where: { $0.caseInsensitiveCompare(String(component)) == .orderedSame }) else { return nil }
                result.appendPathComponent(match)
            }
            guard relative(result, drive: drive) != nil else { return nil }
        }
        return result
    }
    static func windowsFolder(_ path: String, drive: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.lowercased().hasPrefix("c:/") else { return nil }
        guard let url = safeRelative(String(normalized.dropFirst(3)), under: drive) else { return nil }; return existing(url, drive: drive) ?? url
    }
    static func relative(_ url: URL, drive: URL) -> String? {
        let base = drive.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
    static func executableBits(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let dos = try handle.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw SteamFileError.invalid("Choose a Windows executable (.exe).") }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(dos[60 + $1]) << ($1 * 8) }
        guard offset >= 64, offset <= 1024 * 1024 else { throw SteamFileError.invalid("The executable header is invalid.") }
        try handle.seek(toOffset: offset)
        let pe = try handle.read(upToCount: 24) ?? Data()
        guard pe.count == 24, pe.starts(with: [0x50, 0x45, 0, 0]) else { throw SteamFileError.invalid("The executable header is invalid.") }
        let machine = UInt16(pe[4]) | UInt16(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw SteamFileError.invalid("Choose an x86 or x64 Windows installer.") }
        return machine == 0x14c ? 32 : 64
    }
}

actor SteamDisk {
    static let shared = SteamDisk()
    private func read(_ url: URL) throws -> SteamValue {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4 * 1024 * 1024 else { throw SteamFileError.invalid("Steam metadata is empty or too large.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var parser = try SteamKeyValues(try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()); return try parser.read()
    }
    func snapshot(drive: URL, preferredClient: String?) throws -> SteamSnapshot {
        let manager = FileManager.default
        let candidates = [preferredClient].compactMap { $0 } + ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe", "Steam/steam.exe"]
        let clients = candidates.compactMap { SteamPaths.safeRelative($0, under: drive) }.compactMap { SteamPaths.existing($0, drive: drive) }
        guard let exe = clients.first(where: { (try? SteamPaths.executableBits($0)) != nil }),
              let client = SteamPaths.relative(exe, drive: drive) else { return SteamSnapshot() }
        var snapshot = SteamSnapshot(client: client)
        let root = exe.deletingLastPathComponent()
        snapshot.desktopClient = SteamPaths.hasDesktopClient(root: root)
        var libraries = [root]
        let folders = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if manager.fileExists(atPath: folders.path) {
            do {
                guard SteamPaths.relative(folders, drive: drive) != nil else { throw SteamFileError.invalid("External library metadata") }
                guard let table = try read(folders)["libraryfolders"], case .object(let values) = table else { throw SteamFileError.invalid("Invalid library folders") }
                for (key, value) in values where Int(key) != nil {
                    if let path = value["path"]?.string ?? value.string {
                        if let url = SteamPaths.windowsFolder(path, drive: drive) { libraries.append(url) }
                        else { snapshot.skippedLibraries += 1 }
                    }
                }
            } catch { snapshot.complete = false }
        }
        var seen = Set<String>(), apps: [Int: SteamInstalledApp] = [:]
        for library in libraries.prefix(32) where seen.insert(library.path.lowercased()).inserted {
            try Task.checkCancellation()
            let directory = library.appendingPathComponent("steamapps")
            guard manager.fileExists(atPath: directory.path) else { continue }
            let manifests: [URL]
            do { manifests = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch { snapshot.complete = false; continue }
            for file in manifests.prefix(10_000) where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                try Task.checkCancellation()
                do {
                    guard SteamPaths.relative(file, drive: drive) != nil else { throw SteamFileError.invalid("External manifest") }
                    let state = try read(file)["appstate"]
                    guard let textID = state?["appid"]?.string, let id = Int(textID), SteamPaths.validAppID(id),
                          file.lastPathComponent == "appmanifest_\(id).acf",
                          let name = state?["name"]?.string, !name.isEmpty, name.utf8.count <= 512,
                          let folderName = state?["installdir"]?.string,
                          let folder = SteamPaths.safeRelative(folderName, under: directory.appendingPathComponent("common")),
                          let relative = SteamPaths.relative(folder, drive: drive) else { throw SteamFileError.invalid("Incomplete manifest") }
                    guard let flags = UInt64(state?["stateflags"]?.string ?? "") else { throw SteamFileError.invalid("Incomplete installation state") }
                    let size = Int64(state?["sizeondisk"]?.string ?? "")
                    let total = UInt64(state?["bytestodownload"]?.string ?? "") ?? 0
                    let downloaded = UInt64(state?["bytesdownloaded"]?.string ?? "") ?? 0
                    var isDirectory: ObjCBool = false
                    let actualFolder = SteamPaths.existing(folder, drive: drive) ?? folder
                    let exists = manager.fileExists(atPath: actualFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    let app = SteamInstalledApp(id: id, name: name, relativeFolder: SteamPaths.relative(actualFolder, drive: drive) ?? relative,
                                               bytes: size.flatMap { $0 >= 0 ? $0 : nil }, installed: flags & 4 != 0 && exists,
                                               needsUpdate: flags & 2 != 0 || total > downloaded)
                    if apps[id]?.installed != true { apps[id] = app }
                } catch { snapshot.unreadableManifests += 1; snapshot.complete = false }
            }
            if manifests.count > 10_000 { snapshot.complete = false }
        }
        if libraries.count > 32 { snapshot.complete = false }
        snapshot.apps = apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return snapshot
    }
    func storeInstaller(_ source: URL, drive: URL) throws -> Int {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 64,
              size <= SteamPaths.maximumInstallerBytes else { throw SteamFileError.invalid("Choose a Windows installer smaller than 32 MB.") }
        let bits = try SteamPaths.executableBits(source)
        guard let destination = SteamPaths.safeRelative(SteamPaths.installerRelative, under: drive) else { throw SteamFileError.invalid("The installer folder is outside drive_c.") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(SteamPaths.maximumInstallerBytes) + 1) ?? Data()
        guard data.count == size else { throw SteamFileError.invalid("The installer changed while it was being copied. Try again.") }
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        var saved = destination; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try? saved.setResourceValues(attributes)
        return bits
    }
}

// MARK: - ml1490: programs in a game's folder that are not the game

/// ml1490: when none of Steam's launch options resolve, a native install falls
/// back to scanning its folder for the program to start. That scan chose a
/// physics redistributable's installer that a game ships beside itself, so a
/// direct launch ran the installer ("Installation ended prematurely") instead
/// of the game. Redistributables, their installers and uninstallers are now
/// never chosen, recognized by name or by the folder that holds them.
/// Callers apply MADEIRA_STEAM_EXE_FILTER (0 restores the old behavior).
enum SteamExecutableRules {
    /// Name fragments of programs that are never the game.
    static let installerNameParts = ["physx", "dxwebsetup", "dxsetup", "oalinst", "redist", "vcredist", "vc_redist",
                                     "redistributable", "commonredist", "dotnetfx", "prereq", "ue3redist", "ue4prereq",
                                     "uninstall", "xnafx"]
    /// Name starts of such programs ("DirectX_Jun2010_redist", "unins000", offline .NET installers).
    static let installerNamePrefixes = ["directx", "unins", "ndp4"]
    /// Folders that hold such programs, at any depth inside the install folder.
    static let installerFolders: Set<String> = ["redist", "_redist", "redistributable", "redistributables", "_commonredist",
                                                "commonredist", "directx", "dxsdk", "physx", "vcredist", "installers",
                                                "__installer", "prerequisites", "support"]

    /// Why the program at `relative` (inside the install folder, either
    /// separator) is not the game, or nil when it may be: "folder:<name>" or "name:<fragment>".
    static func installerReason(_ relative: String) -> String? {
        let parts = relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map { $0.lowercased() }
        guard let file = parts.last else { return nil }
        if let folder = parts.dropLast().first(where: { installerFolders.contains($0) }) { return "folder:" + folder }
        let name = file.hasSuffix(".exe") ? String(file.dropLast(4)) : file
        if let part = installerNameParts.first(where: { name.contains($0) }) { return "name:" + part }
        if let prefix = installerNamePrefixes.first(where: { name.hasPrefix($0) }) { return "name:" + prefix }
        return nil
    }

    /// The same for an entry's drive_c-relative executable, judged only inside
    /// its install folder (drive_c-relative too). A program elsewhere is the
    /// user's own choice and is never judged.
    static func installerReason(executable: String, installFolder: String?) -> String? {
        guard let installFolder, !installFolder.isEmpty else { return nil }
        let folder = installFolder.replacingOccurrences(of: "\\", with: "/").lowercased() + "/"
        let path = executable.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix(folder) else { return nil }
        return installerReason(String(path.dropFirst(folder.count)))
    }
}

// MARK: - ml1490: the started game's window versus the Windows Steam client's own

/// ml1490: one top-level window of a client-routed launch's Wine desktop, as
/// Winios.m's census reports it. `image`: the owning program's executable name,
/// lower case, empty when it could not be read.
struct SteamLaunchWindow: Equatable {
    var image: String
    var width: Int
    var height: Int
    var visible: Bool
    /// The window put a frame on screen: GDI content, or a D3D swapchain of its own.
    var drawn: Bool
    var pid: UInt32 = 0
}

/// ml1490: what a game launch through the Windows Steam client is showing.
/// The decision is by owning program, not by title or window class: the
/// client, its Chromium helper, their console hosts, Wine's shell and the
/// installers Steam runs before a first start each own their windows, and any
/// other program's shown window belongs to the game that Steam started.
enum SteamLaunchScene: Equatable {
    /// Nothing for the user yet; the client works in the background.
    case waiting
    /// The client shows a window of its own: sign-in, Steam Guard, an error or a question.
    case steamWindow
    /// A window of the started game is up.
    case game

    var name: String {
        switch self {
        case .waiting: return "waiting"
        case .steamWindow: return "steam-window"
        case .game: return "game"
        }
    }

    enum Owner: String { case client = "steam-client", helper, other, unknown }

    /// The client's own programs that show windows the user may have to answer.
    static let clientImages: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe"]
    /// Programs that are neither the game nor something to answer: Wine's shell,
    /// services and console hosts, the client's background tools, and the shared
    /// redistributable installers Steam runs silently before a first start.
    static let helperImages: Set<String> = [
        "dockhost.exe",
        "explorer.exe", "conhost.exe", "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "wineboot.exe", "winemenubuilder.exe", "tabtip.exe", "start.exe", "cmd.exe", "rundll32.exe", "msiexec.exe",
        "steamservice.exe", "steamsysinfo.exe", "iscriptevaluator.exe", "gameoverlayui.exe", "gameoverlayui64.exe",
        "gldriverquery.exe", "gldriverquery64.exe", "vulkandriverquery.exe", "vulkandriverquery64.exe",
        "fossilize_replay.exe", "x64launcher.exe", "x86launcher.exe", "dxsetup.exe",
    ]
    static let helperPrefixes = ["vcredist", "vc_redist", "dotnetfx", "ndp4", "oalinst", "physx", "xnafx", "ue4prereq"]
    /// Smaller shown windows are tray lists, tool strips and caption fragments.
    static let gameMinimum = (width: 160, height: 120)
    static let dialogMinimum = (width: 240, height: 120)

    static var installerRevealEnabled: Bool {
        getenv("MADEIRA_STEAM_INSTALLER_REVEAL").map { String(cString: $0) != "0" } ?? true
    }

    /// ml1760: the first-start installers whose dialogs can hold a launch.
    static func installerImage(_ image: String) -> Bool {
        let name = image.lowercased()
        return name == "msiexec.exe" || name == "dxsetup.exe" || helperPrefixes.contains(where: { name.hasPrefix($0) })
    }

    static func owner(_ image: String) -> Owner {
        let name = image.lowercased()
        if name.isEmpty { return .unknown }
        if clientImages.contains(name) { return .client }
        if helperImages.contains(name) || helperPrefixes.contains(where: { name.hasPrefix($0) }) { return .helper }
        return .other
    }

    /// `rendered`: D3D frames reached the screen since the launch began. Stands
    /// in for a window whose owner could not be read, never for a known one.
    /// Returns the window that decided, for the log.
    static func decide(_ windows: [SteamLaunchWindow], rendered: Bool) -> (scene: SteamLaunchScene, window: SteamLaunchWindow?) {
        var steam: SteamLaunchWindow?
        for window in windows where window.visible {
            let gameSized = window.width >= gameMinimum.width && window.height >= gameMinimum.height
            switch owner(window.image) {
            case .other where gameSized && (window.drawn || rendered): return (.game, window)
            case .unknown where gameSized && rendered: return (.game, window)
            case .client where steam == nil && window.drawn &&
                               window.width >= dialogMinimum.width && window.height >= dialogMinimum.height:
                steam = window
            // ml1760: an installer's dialog is something to answer too. Steam runs some
            // first-start installers without their silent switch; one that fails shows an
            // error box and waits for OK, and Steam waits for it: a first launch sat on
            // "one-time installs" for minutes behind the starting screen (device log 47,
            // msiexec "Fatal Error"). MADEIRA_STEAM_INSTALLER_REVEAL=0 keeps them hidden.
            case .helper where steam == nil && window.drawn && installerImage(window.image) &&
                               window.width >= dialogMinimum.width && window.height >= dialogMinimum.height &&
                               installerRevealEnabled:
                steam = window
            default: break
            }
        }
        return steam.map { (.steamWindow, $0) } ?? (.waiting, nil)
    }
}

/// ml1490: whether the starting screen covers the Wine desktop during a game
/// launch through the Windows Steam client. LibraryModel feeds it the scene
/// every 0.5 s. The game's window ends the hold. A client window shown for
/// `revealDelay` s reveals the desktop (when auto-reveal is on); once it has
/// been gone for `coverDelay` s the starting screen returns, at most
/// `maxAutoReveals` times, after which the desktop stays. "Show Steam" reveals
/// it for good.
/// A third-party license agreement listed in an app's PICS info (`common/eulas`).
struct SteamEula: Equatable, Sendable {
    var id: String        // e.g. "17410_eula_1"; also the key the client records
    var name: String
    var url: String
    var version: String
}

/// ml1710: LICENSE AGREEMENTS ARE ANSWERED IN MADEIRA, BEFORE THE CLIENT STARTS.
///
/// The Windows Steam client records an accepted agreement in
/// userdata/<account>/config/localconfig.vdf as
///     UserLocalConfigStore/Software/Valve/Steam/apps/<appid>/"<eula id>" = "<version>"
/// and, when one is missing, stops a launch to ask. A -silent launch asks inside a window it
/// keeps hidden, so on this device the launch sat at "waiting for user response to ShowEula"
/// with nothing to answer. Madeira shows the agreement in its own sheet instead and records
/// it only after the user accepts. This is the one place Madeira writes a Steam file: the
/// edit inserts lines as text and leaves everything else byte for byte as the client wrote it.
enum SteamEulaStore {
    static func configFiles(steamRoot: URL) -> [URL] {
        let userdata = steamRoot.appendingPathComponent("userdata")
        let accounts = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        return accounts.filter { Int($0.lastPathComponent) != nil }
            .map { $0.appendingPathComponent("config/localconfig.vdf") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Agreements not yet recorded in the given localconfig text.
    static func missing(appID: Int, eulas: [SteamEula], in text: String) -> [SteamEula] {
        guard let root = parse(Array(text.utf8)) else { return eulas }
        var nodes = root, app: Node?
        for key in ["userlocalconfigstore", "software", "valve", "steam", "apps", String(appID)] {
            guard let node = nodes.first(where: { $0.key.lowercased() == key }) else { return eulas }
            app = node; nodes = node.children
        }
        return eulas.filter { app?.leaves[$0.id.lowercased()] == nil }
    }

    /// Agreements missing from any account's localconfig on this drive. Empty when there is
    /// no localconfig yet (nothing to record into; the client then asks as it always did).
    static func missing(appID: Int, eulas: [SteamEula], steamRoot: URL) -> [SteamEula] {
        var result: [SteamEula] = []
        for file in configFiles(steamRoot: steamRoot) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for eula in missing(appID: appID, eulas: eulas, in: text) where !result.contains(eula) { result.append(eula) }
        }
        return result
    }

    /// Records the agreements in every account's localconfig. Returns the number of files changed.
    @discardableResult
    static func record(appID: Int, eulas: [SteamEula], steamRoot: URL) throws -> Int {
        var changed = 0
        for file in configFiles(steamRoot: steamRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let updated = record(appID: appID, eulas: eulas, in: text), updated != text else { continue }
            let backup = file.appendingPathExtension("madeira-bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: file, to: backup) }
            try updated.write(to: file, atomically: true, encoding: .utf8)
            changed += 1
        }
        return changed
    }

    // MARK: text edit

    private struct Node { var key: String; var open: Int; var close: Int; var children: [Node]; var leaves: [String: Range<Int>] }

    /// Returns the text with the agreements inserted, or nil when the file has no
    /// UserLocalConfigStore/Software/Valve/Steam section to put them in.
    static func record(appID: Int, eulas: [SteamEula], in text: String) -> String? {
        var bytes = Array(text.utf8)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        for eula in eulas {
            guard let root = parse(bytes) else { return nil }
            func find(_ path: [String], in nodes: [Node]) -> Node? {
                guard let first = path.first, let node = nodes.first(where: { $0.key.lowercased() == first }) else { return nil }
                return path.count == 1 ? node : find(Array(path.dropFirst()), in: node.children)
            }
            guard let steam = find(["userlocalconfigstore", "software", "valve", "steam"], in: root) else { return nil }
            let apps = steam.children.first { $0.key.lowercased() == "apps" }
            let app = apps?.children.first { $0.key == String(appID) }
            let entry = "\"\(escape(eula.id))\"\t\t\"\(escape(eula.version))\""
            if let app, let range = app.leaves[eula.id.lowercased()] {
                bytes.replaceSubrange(range, with: Array("\"\(escape(eula.version))\"".utf8))   // value only
            } else if let app {
                let indent = indentation(bytes, before: app.close) + "\t"
                insert(&bytes, at: lineStart(bytes, app.close), indent + entry + newline)
            } else if let apps {
                let indent = indentation(bytes, before: apps.close) + "\t"
                insert(&bytes, at: lineStart(bytes, apps.close),
                       indent + "\"\(appID)\"" + newline + indent + "{" + newline + indent + "\t" + entry + newline + indent + "}" + newline)
            } else {
                let indent = indentation(bytes, before: steam.close) + "\t"
                insert(&bytes, at: lineStart(bytes, steam.close),
                       indent + "\"apps\"" + newline + indent + "{" + newline
                       + indent + "\t\"\(appID)\"" + newline + indent + "\t{" + newline + indent + "\t\t" + entry + newline
                       + indent + "\t}" + newline + indent + "}" + newline)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func insert(_ bytes: inout [UInt8], at index: Int, _ text: String) { bytes.insert(contentsOf: Array(text.utf8), at: index) }
    private static func lineStart(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index
        while i > 0, bytes[i - 1] != 10 { i -= 1 }
        return i
    }
    private static func indentation(_ bytes: [UInt8], before index: Int) -> String {
        let start = lineStart(bytes, index)
        return String(decoding: bytes[start..<index].filter { $0 == 9 || $0 == 32 }, as: UTF8.self)
    }

    /// A position-keeping reader for the same grammar SteamKeyValues accepts.
    private static func parse(_ bytes: [UInt8]) -> [Node]? {
        var i = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        enum Tok { case word(String, Range<Int>), open(Int), close(Int) }
        func next() -> Tok? {
            while i < bytes.count {
                if bytes[i] <= 32 { i += 1; continue }
                if bytes[i] == 47, i + 1 < bytes.count, bytes[i + 1] == 47 { while i < bytes.count && bytes[i] != 10 { i += 1 }; continue }
                break
            }
            guard i < bytes.count else { return nil }
            let start = i
            if bytes[i] == 123 { i += 1; return .open(start) }
            if bytes[i] == 125 { i += 1; return .close(start) }
            var value: [UInt8] = []
            if bytes[i] == 34 {
                i += 1
                while i < bytes.count, bytes[i] != 34 {
                    if bytes[i] == 92, i + 1 < bytes.count { value.append(bytes[i + 1]); i += 2; continue }
                    value.append(bytes[i]); i += 1
                }
                guard i < bytes.count else { return nil }
                i += 1
            } else {
                while i < bytes.count, bytes[i] > 32, bytes[i] != 123, bytes[i] != 125 { value.append(bytes[i]); i += 1 }
            }
            return .word(String(decoding: value, as: UTF8.self), start..<i)
        }
        func object(depth: Int) -> (nodes: [Node], leaves: [String: Range<Int>], close: Int)? {
            guard depth < 64 else { return nil }
            var nodes: [Node] = [], leaves: [String: Range<Int>] = [:]
            while let tok = next() {
                switch tok {
                case .close(let at): return depth > 0 ? (nodes, leaves, at) : nil
                case .open: return nil
                case .word(let key, _):
                    guard let value = next() else { return nil }
                    switch value {
                    case .open(let at):
                        guard let inner = object(depth: depth + 1) else { return nil }
                        nodes.append(Node(key: key, open: at, close: inner.close, children: inner.nodes, leaves: inner.leaves))
                    case .word(_, let range): leaves[key.lowercased()] = range
                    case .close: return nil
                    }
                }
            }
            return depth == 0 ? (nodes, leaves, bytes.count) : nil
        }
        return object(depth: 0)?.nodes
    }
}

struct SteamLaunchHold {
    enum Action: Equatable { case none, showGame, reveal, cover }
    static let revealDelay = 2.0, coverDelay = 4.0, maxAutoReveals = 6
    let autoReveal: Bool
    private(set) var scene = SteamLaunchScene.waiting
    private(set) var revealed = false
    private(set) var manual = false
    private(set) var finished = false
    private(set) var autoReveals = 0
    private var steamSince: Double?
    private var clearSince: Double?
    /// ml1530: "Show Steam" was tapped before the client had a window (device log 198: tapped
    /// at 37 s, the license agreement drew at 50 s); reveal as soon as one is up.
    private(set) var pendingReveal = false

    init(autoReveal: Bool) { self.autoReveal = autoReveal }

    /// A client window is up and the starting screen still hides it.
    var needsAttention: Bool { !finished && !revealed && scene == .steamWindow }

    mutating func step(_ next: SteamLaunchScene, now: Double) -> Action {
        guard !finished else { return .none }
        scene = next
        switch next {
        case .game:
            finished = true
            return .showGame
        case .steamWindow:
            clearSince = nil
            if pendingReveal, !revealed {
                pendingReveal = false; revealed = true; manual = true
                return .reveal
            }
            let since = steamSince ?? now
            steamSince = since
            guard autoReveal, !revealed, autoReveals < Self.maxAutoReveals, now - since >= Self.revealDelay else { return .none }
            revealed = true
            autoReveals += 1
            return .reveal
        case .waiting:
            steamSince = nil
            guard revealed, !manual, autoReveals < Self.maxAutoReveals else { clearSince = nil; return .none }
            let since = clearSince ?? now
            clearSince = since
            guard now - since >= Self.coverDelay else { return .none }
            revealed = false
            clearSince = nil
            return .cover
        }
    }

    /// The user asked to see Steam. Returns false when it is already shown that way.
    mutating func showSteam(waitForWindow: Bool = true) -> Bool {
        guard !finished, !manual else { return false }
        // ml1530: nothing to show yet; remember the tap and reveal when the client's window is up.
        if scene == .waiting, waitForWindow { pendingReveal = true; return false }
        revealed = true
        manual = true
        return true
    }
}

enum LibraryRendererBadge {
    static let apis = ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"]

    /// ml1780: the badge names an API only when the game's files name exactly one. The scan
    /// finds every renderer a game ships, not the one it runs: an engine with D3D9 and D3D10
    /// renderers showed D3D10 for a D3D9 game. `strict: false` is the old highest-API label.
    static func compact(_ detected: String?, strict: Bool = true) -> String? {
        guard let detected else { return nil }
        // "D3D10/D3D9" from the metadata scan, "D3D10 / D3D9" from inspect.
        let values = Set(detected.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        let known = apis.filter(values.contains)
        guard strict else { return known.first ?? detected }
        if known.count == 1 { return known[0] }
        return known.isEmpty && !detected.contains("/") ? detected : nil   // e.g. "Wine desktop"
    }
}

// MARK: - Madeira ml1780: Steam's one-time installs

/// One "Run Process" entry of a game's install script: Steam runs the entry's
/// program (DirectX, Visual C++, PhysX and similar redistributables) before a start
/// unless the registry value `name` under `key` is at least `value`, and writes 1
/// there after the program exits with 0 (Steamworks "Creating and using InstallScripts").
struct SteamInstallRun: Equatable, Sendable, Codable {
    enum Hive: String, Sendable, Codable { case machine, user }
    var name: String
    var hive: Hive
    var key: String      // under the hive, e.g. Software\Valve\Steam\Apps\7000
    var value: UInt32    // MinimumHasRunValue, else 1
}

/// ml1780: marks a game's one-time installs as done in the prefix's registry before
/// the client starts, so the client skips them. Under the emulator they took minutes
/// on every start, some never succeeded (DXSETUP ended with -9 in every device log, an
/// MSI stopped on "Fatal Error") and the client quit or wedged after running them
/// (device logs 49 and 51), so the game never started. Wine provides the runtimes these
/// installers carry. The .reg files are edited only while no session runs: the
/// wineserver holds the registry in memory and writes it back when it stops.
enum SteamInstallScripts {
    static let maxScriptBytes = 1 << 20

    /// The entries of one parsed install script, from its "Run Process" section at any depth.
    static func runs(_ root: SteamValue) -> [SteamInstallRun] {
        var result: [SteamInstallRun] = []
        func walk(_ fields: [String: SteamValue], depth: Int) {
            guard depth < 4 else { return }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                guard case .object(let inner) = value else { continue }
                if key == "run process" {
                    for (name, entry) in inner.sorted(by: { $0.key < $1.key }) {
                        guard let path = entry["hasrunkey"]?.string, let (hive, sub) = hive(path), !sub.isEmpty else { continue }
                        let minimum = entry["minimumhasrunvalue"]?.string.flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                        let run = SteamInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                        if !result.contains(run) { result.append(run) }
                    }
                } else if key != "run process on uninstall" {
                    walk(inner, depth: depth + 1)
                }
            }
        }
        walk(root.fields, depth: 0)
        return result
    }

    /// "HKEY_LOCAL_MACHINE\Software\..." -> (.machine, "Software\...").
    static func hive(_ path: String) -> (SteamInstallRun.Hive, String)? {
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let first = parts.first?.uppercased() else { return nil }
        let rest = parts.dropFirst().joined(separator: "\\")
        switch first {
        case "HKEY_LOCAL_MACHINE", "HKLM": return (.machine, rest)
        case "HKEY_CURRENT_USER", "HKCU": return (.user, rest)
        default: return nil
        }
    }

    /// The keys a run is written under. The 32-bit client reads HKLM\Software through
    /// Wow6432Node in a 64-bit prefix; the plain key covers a 64-bit reader.
    static func keys(_ run: SteamInstallRun) -> [String] {
        let lower = run.key.lowercased()
        guard run.hive == .machine, lower.hasPrefix("software\\"), !lower.hasPrefix("software\\wow6432node\\") else { return [run.key] }
        return [run.key, "Software\\Wow6432Node\\" + run.key.dropFirst("software\\".count)]
    }

    /// Install scripts: .vdf files with a "Run Process" or "Registry" section in `folder` and up to
    /// `depth` levels below it.
    static func scripts(folder: URL, depth: Int = 1) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for item in items.sorted(by: { $0.path < $1.path }).prefix(500) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if depth > 0 { found += scripts(folder: item, depth: depth - 1) }
            } else if item.pathExtension.lowercased() == "vdf", (values.fileSize ?? .max) <= maxScriptBytes,
                      let data = try? Data(contentsOf: item),
                      (String(decoding: data, as: UTF8.self).range(of: "run process", options: .caseInsensitive) != nil ||
                       String(decoding: data, as: UTF8.self).range(of: "registry", options: .caseInsensitive) != nil) {
                found.append(item)
            }
        }
        return found
    }

    /// The entries of every install script of a game installed in `installFolder`, and of
    /// the shared redistributables the client keeps next to it. `appID` (ml2013) gives the
    /// game's own entries without a "HasRunKey" Steam's per-app key (defaultRunKey).
    static func runs(installFolder: URL, appID: Int? = nil) -> [SteamInstallRun] {
        let shared = installFolder.deletingLastPathComponent()
            .appendingPathComponent("Steamworks Shared", isDirectory: true).appendingPathComponent("_CommonRedist", isDirectory: true)
        var result: [SteamInstallRun] = []
        for (file, owner) in scripts(folder: installFolder, depth: 1).map({ ($0, appID) }) + scripts(folder: shared, depth: 3).map({ ($0, nil as Int?) }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            for run in runs(script: data, appID: owner) where !result.contains(run) { result.append(run) }
        }
        return result
    }

    /// ml2013: where Valve's client records an entry that names no "HasRunKey": a DWORD named
    /// after the entry (lowercase, as its script parser keys it) under the app's own key, e.g.
    /// "directx"=1 under HKLM\Software\[Wow6432Node\]Valve\Steam\Apps\<appid> in a Windows
    /// registry after the client ran that entry. ml1780/ml1970 skipped such entries entirely,
    /// so a script whose DirectX and Visual C++ entries name no key found only its third entry.
    static func defaultRunKey(appID: Int) -> String { "Software\\Valve\\Steam\\Apps\\\(appID)" }

    /// The "HasRunKey" of an entry's fields, else (ml2013, with a valid `appID` and a program to
    /// run) the per-app default key in full-path form.
    static func runKey(_ fields: [String: String], appID: Int?) -> String? {
        if let key = fields["hasrunkey"] { return key }
        guard let appID, appID > 0, appID < 1 << 31, fields.keys.contains(where: { $0.hasPrefix("process ") }) else { return nil }
        return "HKEY_LOCAL_MACHINE\\" + defaultRunKey(appID: appID)
    }

    /// ml1790: the entries of one install script read straight from its text. Scripts repeat
    /// the "Run Process" key, one section per installer; SteamKeyValues keeps the last copy of
    /// a repeated key, so device log 52 found 1 of the 3 entries its client then ran.
    static func runs(script data: Data, appID: Int? = nil) -> [SteamInstallRun] {
        var bytes = Array(data.prefix(maxScriptBytes))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        func token() -> (text: String, quoted: Bool)? {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { return nil }
            let first = bytes[position]; position += 1
            if first == 123 { return ("{", false) }
            if first == 125 { return ("}", false) }
            var value: [UInt8] = []
            if first == 34 {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { break }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 { value.append(bytes[position]); position += 1 }
                    else { value.append(byte) }
                }
                return (String(decoding: value, as: UTF8.self), true)
            }
            value.append(first)
            while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { value.append(bytes[position]); position += 1 }
            return (String(decoding: value, as: UTF8.self), true)
        }
        var result: [SteamInstallRun] = []
        var path: [String] = []          // keys of the open sections, lowercased
        var pending: String?             // a key waiting for its value or section
        var fields: [String: String] = [:]
        var tokens = 0
        while let (text, quoted) = token() {
            tokens += 1
            if tokens > 200_000 || path.count > 32 { break }
            if !quoted && text == "{" {
                path.append(pending?.lowercased() ?? ""); pending = nil
                if path.count >= 2, path[path.count - 2] == "run process" { fields = [:] }
            } else if !quoted && text == "}" {
                // An entry section closes: path is [..., "run process", <entry>].
                if path.count >= 2, path[path.count - 2] == "run process", let name = path.last,
                   let key = runKey(fields, appID: appID), let (hive, sub) = hive(key), !sub.isEmpty {
                    let minimum = fields["minimumhasrunvalue"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                    let run = SteamInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                    if !result.contains(run) { result.append(run) }
                }
                if !path.isEmpty { path.removeLast() }
                pending = nil
            } else if let key = pending {
                if path.count >= 2, path[path.count - 2] == "run process" { fields[key.lowercased()] = text }
                pending = nil
            } else {
                pending = text
            }
        }
        return result
    }

    /// The .reg text with every run's value at least its minimum, and how many values changed.
    /// Wine's format: "[Key\\Sub] <time>" section headers, then "\"name\"=dword:00000001" lines.
    static func mark(_ runs: [SteamInstallRun], in text: String, now: Int) -> (text: String, changed: Int) {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for run in runs {
            let valueName = "\"" + escape(run.name) + "\"="
            let valueLine = valueName + String(format: "dword:%08x", run.value)
            for key in keys(run) {
                let header = "[" + escape(key) + "]"
                if let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(valueName.lowercased()) }) {
                        if let current = dword(lines[index]), current >= run.value { continue }
                        lines[index] = valueLine
                    } else {
                        var at = end
                        while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
                        lines.insert(valueLine, at: at)
                    }
                } else {
                    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                    lines += ["", header + " \(now)", valueLine, ""]
                }
                changed += 1
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// Writes the runs into the prefix's system.reg and user.reg (a .madeira-bak copy is kept
    /// once). Returns the number of values written. Only while no session runs.
    @discardableResult
    static func mark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        var total = 0
        for (hive, file) in [(SteamInstallRun.Hive.machine, "system.reg"), (.user, "user.reg")] {
            let selected = runs.filter { $0.hive == hive }
            guard !selected.isEmpty else { continue }
            let url = prefix.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }   // a prefix not seeded yet
            let (updated, changed) = mark(selected, in: String(decoding: data, as: UTF8.self), now: Int(Date().timeIntervalSince1970))
            guard changed > 0 else { continue }
            let backup = url.appendingPathExtension("madeira-bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
            try Data(updated.utf8).write(to: url, options: .atomic)
            total += changed
        }
        return total
    }

    /// ml2013: the .reg text without the runs' values (both views), and how many were removed.
    /// Used when a game is reinstalled, so its one-time installs are evaluated again.
    static func unmark(_ runs: [SteamInstallRun], in text: String) -> (text: String, changed: Int) {
        var lines = text.components(separatedBy: "\n")
        var changed = 0
        for run in runs {
            let valueName = ("\"" + escape(run.name) + "\"=").lowercased()
            for key in keys(run) {
                let header = ("[" + escape(key) + "]").lowercased()
                guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
                var index = start + 1
                while index < lines.count, !lines[index].hasPrefix("[") {
                    if lines[index].lowercased().hasPrefix(valueName) { lines.remove(at: index); changed += 1 } else { index += 1 }
                }
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// ml2013: unmark in the prefix's system.reg and user.reg. Only while no session runs.
    @discardableResult
    static func unmark(_ runs: [SteamInstallRun], prefix: URL) throws -> Int {
        var total = 0
        for (hive, file) in [(SteamInstallRun.Hive.machine, "system.reg"), (.user, "user.reg")] {
            let selected = runs.filter { $0.hive == hive }
            guard !selected.isEmpty else { continue }
            let url = prefix.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let (updated, changed) = unmark(selected, in: String(decoding: data, as: UTF8.self))
            guard changed > 0 else { continue }
            try Data(updated.utf8).write(to: url, options: .atomic)
            total += changed
        }
        return total
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func dword(_ line: String) -> UInt32? {
        guard let range = line.range(of: "=dword:", options: .caseInsensitive) else { return nil }
        return UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
    }
}


// MARK: - ml1970: one-time installs for games started through Madeira Dock

/// One "Run Process" program of an install script, resolved to a Windows path.
struct SteamInstallProcess: Equatable, Sendable {
    var run: SteamInstallRun
    var executable: String      // Windows path, C:\...
    var arguments: String
}

/// ml1970: Madeira Dock asks Valve's client to launch with its app manager, the step after the
/// desktop client's own launch tasks (license agreements, install scripts). Install scripts are
/// therefore never evaluated under Dock (no "RunningInstallScript" task in any Dock session).
/// Microsoft runtimes those scripts install (DirectX, Visual C++, .NET) are provided by Madeira's
/// Wine DLLs, and their installers failed under emulation (see ml1780), so they stay marked done.
/// Any other program runs once in the Dock session before the host starts, and is recorded done
/// only when it exits successfully. Callers apply MADEIRA_DOCK_INSTALLERS.
/// ml2013: entries without a "HasRunKey" count too (Steam's per-app key), every program's fate is
/// logged, the batch reports each exit status, and a reinstall evaluates the installs again.
enum DockInstallScripts {
    /// Programs Madeira's own Wine components replace.
    static func providedByMadeira(_ process: SteamInstallProcess) -> Bool {
        providedRuntime(process) != nil
    }

    /// ml2014: the name of the Microsoft runtime a provided program installs (start screen text),
    /// nil for any other program.
    static func providedRuntime(_ process: SteamInstallProcess) -> String? {
        let file = process.executable.split(separator: "\\").last.map { $0.lowercased() } ?? ""
        if file == "dxsetup.exe" || file.hasPrefix("dxwebsetup") { return "DirectX" }
        if file.hasPrefix("vcredist") || file.hasPrefix("vc_redist") || file.hasPrefix("vcruntime") { return "Visual C++" }
        if file.hasPrefix("dotnetfx") || file.hasPrefix("ndp4") || file.hasPrefix("netfx") { return ".NET" }
        return nil
    }

    /// ml2014: runs the plan classifies provided (every program in the run is provided by
    /// Madeira), whether or not "run all" queues them. Such a run that exits non-zero is recorded
    /// done ("provided-after-failure") instead of running again at every start.
    static func providedRuns(_ found: [SteamInstallProcess]) -> [SteamInstallRun] {
        var runs: [SteamInstallRun] = []
        for process in found where !runs.contains(process.run) &&
            found.filter({ $0.run == process.run }).allSatisfy(providedByMadeira) { runs.append(process.run) }
        return runs
    }

    /// The programs of one install script. `installDir` replaces %INSTALLDIR% (a Windows path).
    /// `appID` (ml2013) records entries without a "HasRunKey" under Steam's per-app key.
    static func processes(script data: Data, installDir: String, appID: Int? = nil) -> [SteamInstallProcess] {
        var result: [SteamInstallProcess] = []
        for (run, fields) in SteamInstallScripts.entries(script: data, appID: appID) {
            let numbers = fields.keys.compactMap { key -> Int? in
                guard key.hasPrefix("process ") else { return nil }
                return Int(key.dropFirst("process ".count).trimmingCharacters(in: .whitespaces))
            }.sorted()
            for number in numbers.prefix(8) {
                guard let raw = fields["process \(number)"], !raw.isEmpty, raw.utf8.count <= 1024 else { continue }
                let exe = expand(raw, installDir: installDir)
                let lower = exe.lowercased()
                guard exe.count > 3, exe.hasPrefix("C:\\"), !exe.contains("%"), !exe.contains("\""),
                      !exe.contains(".."), lower.hasSuffix(".exe") || lower.hasSuffix(".msi") else { continue }
                let args = expand(fields["command \(number)"] ?? "", installDir: installDir, path: false)
                    .trimmingCharacters(in: .whitespaces)
                guard args.utf8.count <= 1024, !args.contains("\r"), !args.contains("\n"), !args.contains("&"),
                      !args.contains("|"), !args.contains(">"), !args.contains("<"), !args.contains("^"),
                      !args.contains("%") else { continue }
                let process = SteamInstallProcess(run: run, executable: exe, arguments: args)
                if !result.contains(process) { result.append(process) }
            }
        }
        return result
    }

    /// A program path gets Windows separators; an argument list keeps its "/switches".
    static func expand(_ text: String, installDir: String, path: Bool = true) -> String {
        var value = path ? text.replacingOccurrences(of: "/", with: "\\") : text
        value = value.replacingOccurrences(of: "%INSTALLDIR%", with: installDir, options: .caseInsensitive)
        if path { while value.contains("\\\\") { value = value.replacingOccurrences(of: "\\\\", with: "\\") } }
        return value
    }

    /// Whether a run is recorded done in a Wine .reg text (value at least its minimum).
    static func marked(_ run: SteamInstallRun, in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        let valueName = ("\"" + SteamInstallScripts.escape(run.name) + "\"=").lowercased()
        for key in SteamInstallScripts.keys(run) {
            let header = ("[" + SteamInstallScripts.escape(key) + "]").lowercased()
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
            var index = start + 1
            while index < lines.count, !lines[index].hasPrefix("[") {
                let line = lines[index].lowercased()
                if line.hasPrefix(valueName), let range = line.range(of: "=dword:"),
                   let current = UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                   current >= run.value { return true }
                index += 1
            }
        }
        return false
    }

    /// The batch file the Dock session runs before the host: each program once, recorded done
    /// (both registry views) only when it exits with status 0.
    static func batch(_ processes: [SteamInstallProcess]) -> String {
        var lines = ["@echo off", "rem Madeira ml1970: one-time installs before Madeira Dock starts the game"]
        for process in processes {
            let quoted = "\"" + process.executable + "\""
            let command = process.executable.lowercased().hasSuffix(".msi")
                ? "C:\\windows\\system32\\msiexec.exe /i " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
                : "call " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
            let label = process.run.name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }
            lines.append("echo [dock-installers] ml1970 running " + label)
            lines.append(command)
            let hive = process.run.hive == .machine ? "HKLM" : "HKCU"
            let name = process.run.name.replacingOccurrences(of: "\"", with: "")
            for key in SteamInstallScripts.keys(process.run) {
                lines.append("if not errorlevel 1 C:\\windows\\system32\\reg.exe add \"\(hive)\\\(key.replacingOccurrences(of: "\"", with: ""))\" /v \"\(name)\" /t REG_DWORD /d \(process.run.value) /f >nul")
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

extension SteamInstallScripts {
    /// ml1970: every "Run Process" entry with its fields (lowercased keys), read from the text
    /// so repeated sections all count (see runs(script:)).
    static func entries(script data: Data, appID: Int? = nil) -> [(SteamInstallRun, [String: String])] {
        var bytes = Array(data.prefix(maxScriptBytes))
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        func token() -> (text: String, quoted: Bool)? {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { return nil }
            let first = bytes[position]; position += 1
            if first == 123 { return ("{", false) }
            if first == 125 { return ("}", false) }
            var value: [UInt8] = []
            if first == 34 {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { break }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 { value.append(bytes[position]); position += 1 }
                    else { value.append(byte) }
                }
                return (String(decoding: value, as: UTF8.self), true)
            }
            value.append(first)
            while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { value.append(bytes[position]); position += 1 }
            return (String(decoding: value, as: UTF8.self), true)
        }
        var result: [(SteamInstallRun, [String: String])] = []
        var path: [String] = []
        var pending: String?
        var fields: [String: String] = [:]
        var tokens = 0
        while let (text, quoted) = token() {
            tokens += 1
            if tokens > 200_000 || path.count > 32 { break }
            if !quoted && text == "{" {
                path.append(pending?.lowercased() ?? ""); pending = nil
                if path.count >= 2, path[path.count - 2] == "run process" { fields = [:] }
            } else if !quoted && text == "}" {
                if path.count >= 2, path[path.count - 2] == "run process", let name = path.last,
                   let key = runKey(fields, appID: appID), let (hive, sub) = hive(key), !sub.isEmpty {
                    let minimum = fields["minimumhasrunvalue"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                    let run = SteamInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                    if !result.contains(where: { $0.0 == run }) { result.append((run, fields)) }
                }
                if !path.isEmpty { path.removeLast() }
                pending = nil
            } else if let key = pending {
                if path.count >= 2, path[path.count - 2] == "run process" { fields[key.lowercased()] = text }
                pending = nil
            } else {
                pending = text
            }
        }
        return result
    }
}

// MARK: - ml2013: one-time installs, visible and reset on reinstall

/// ml2013: what a Dock start does with one install-script program.
enum DockInstallStatus: String, Sendable {
    case provided   // a runtime Madeira's Wine provides: recorded done, not run
    case done       // already recorded done in the prefix's registry
    case missing    // the program is not on disk (the log names it)
    case pending    // runs in the session before the host
    case limit      // over the per-start program limit; runs at a later start
}

/// ml2014: the install batch's service-manager step. `.none` keeps the ml2013 batch; `.off`
/// only records "services off" (MADEIRA_DOCK_INSTALL_SCM=0); `.start` runs the Dock executable
/// with --start-services before the first installer.
enum DockInstallServices: Equatable, Sendable {
    case none
    case off
    case start(String)
}

extension DockInstallScripts {
    /// ml2014: the start screen's line for a provided runtime whose installer failed.
    static func providedFailureNote(runtime: String, status: Int) -> String {
        "\(runtime) setup failed (code \(status)); Madeira provides \(runtime), so it won't run again."
    }
}

struct DockInstallPlanItem: Equatable, Sendable {
    var process: SteamInstallProcess
    var status: DockInstallStatus
}

/// ml2013: runs Madeira itself recorded done (a provided runtime, ml1970) per app, and apps whose
/// install was removed, so their one-time installs are evaluated again at the next start. Kept
/// next to the prefix's registry files; one small JSON file.
struct SteamInstallLedger: Codable, Equatable, Sendable {
    static let fileName = "madeira-install-marks.json"
    /// App ID -> runs Madeira marked done without running their program.
    var marked: [String: [SteamInstallRun]] = [:]
    /// App ID -> the removed entry's "run all" choice, applied once after a reinstall.
    var reset: [String: Bool] = [:]
    /// The programs the last generated batch runs, in its order (result lines refer to them by index).
    var session: [SteamInstallRun] = []
    var sessionApp: Int = 0

    static func load(prefix: URL) -> SteamInstallLedger {
        let url = prefix.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let ledger = try? JSONDecoder().decode(SteamInstallLedger.self, from: data) else { return SteamInstallLedger() }
        return ledger
    }
    func save(prefix: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: prefix.appendingPathComponent(Self.fileName), options: .atomic)
    }
    func madeiraMarked(_ run: SteamInstallRun, app: Int) -> Bool { marked[String(app)]?.contains(run) == true }
    mutating func record(_ runs: [SteamInstallRun], app: Int) {
        var list = marked[String(app)] ?? []
        for run in runs where !list.contains(run) { list.append(run) }
        marked[String(app)] = list.isEmpty ? nil : list
    }
    mutating func forget(_ runs: [SteamInstallRun], app: Int) {
        let list = (marked[String(app)] ?? []).filter { !runs.contains($0) }
        marked[String(app)] = list.isEmpty ? nil : list
    }
}

extension DockInstallScripts {
    /// The value a run has in a Wine .reg text (highest of both views), nil when absent.
    static func recorded(_ run: SteamInstallRun, in text: String) -> UInt32? {
        let lines = text.components(separatedBy: "\n")
        let valueName = ("\"" + SteamInstallScripts.escape(run.name) + "\"=").lowercased()
        var best: UInt32?
        for key in SteamInstallScripts.keys(run) {
            let header = ("[" + SteamInstallScripts.escape(key) + "]").lowercased()
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
            var index = start + 1
            while index < lines.count, !lines[index].hasPrefix("[") {
                let line = lines[index].lowercased()
                if line.hasPrefix(valueName), let range = line.range(of: "=dword:"),
                   let value = UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) {
                    best = max(best ?? 0, value)
                }
                index += 1
            }
        }
        return best
    }

    /// ml2013: every program's fate at this start. A run is provided (recorded done up front) only
    /// when every program in it is provided and `runAll` is off; `done` decides the rest first,
    /// then whether the program exists; at most `limit` programs run per start.
    static func plan(_ found: [SteamInstallProcess], runAll: Bool, limit: Int = 8,
                     done: (SteamInstallRun) -> Bool, exists: (String) -> Bool) -> [DockInstallPlanItem] {
        var result: [DockInstallPlanItem] = []
        var queued = 0
        for process in found {
            let status: DockInstallStatus
            if !runAll && found.filter({ $0.run == process.run }).allSatisfy(providedByMadeira) { status = .provided }
            else if done(process.run) { status = .done }
            else if !exists(process.executable) { status = .missing }
            else if queued < limit { status = .pending; queued += 1 }
            else { status = .limit }
            result.append(DockInstallPlanItem(process: process, status: status))
        }
        return result
    }

    /// ml2013: the start screen's line about the plan, or nil when there is nothing to say: nothing
    /// runs, nothing is missing and no provided runtime is newly recorded (`announceProvided`).
    static func note(_ items: [DockInstallPlanItem], runAll: Bool, announceProvided: Bool) -> String? {
        func names(_ status: DockInstallStatus) -> String {
            var seen: [String] = []
            for item in items where item.status == status {
                let name = label(item.process.run)
                if !seen.contains(name) { seen.append(name) }
            }
            return seen.joined(separator: ", ")
        }
        let active = items.contains { $0.status == .pending || $0.status == .missing || $0.status == .limit }
        guard active || (announceProvided && items.contains { $0.status == .provided }) else { return nil }
        var parts: [String] = []
        if !names(.pending).isEmpty { parts.append("Runs first: " + names(.pending)) }
        if !names(.provided).isEmpty {
            parts.append("Provided by Madeira, not run: " + names(.provided) +
                         (runAll ? "" : " (turn on \"Also run DirectX and Visual C++ installers\" to run them)"))
        }
        if !names(.done).isEmpty { parts.append("Already done: " + names(.done)) }
        if !names(.missing).isEmpty { parts.append("Installer file missing: " + names(.missing)) }
        if !names(.limit).isEmpty { parts.append("Next start: " + names(.limit)) }
        return "One-time installs. " + parts.joined(separator: ". ") + "."
    }

    /// A program's label for logs, the batch and the UI: the entry name, reduced to safe characters.
    static func label(_ run: SteamInstallRun) -> String {
        String(run.name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }.prefix(64))
    }

    /// ml2013: the batch with a result file. Each program's start and exit status are appended to
    /// `resultFile` ("start <i> <label>", "exit <i> <status>"; each redirection follows a space, so
    /// a status digit is never read as a handle number); a run is recorded done only on status 0,
    /// 3010 or 1641 (installed, restart requested). ml1970's "if not errorlevel 1" also accepted
    /// negative statuses (an installer's -9 read as success).
    ///
    /// ml2014: `services` first makes Wine's service manager reachable (`dockhost.exe
    /// --start-services` prints "services <outcome>" into the result file; "services failed" if
    /// it could not run) or records "services off". A program whose run is in `providedFallback`
    /// and exits with any other status appends "provided <i> <runtime>" before its exit line and is
    /// recorded done too: Madeira provides that runtime, so it is not run again at every start.
    static func batch(_ processes: [SteamInstallProcess], resultFile: String,
                      services: DockInstallServices = .none, providedFallback: [SteamInstallRun] = []) -> String {
        let result = " >>\"" + resultFile.replacingOccurrences(of: "\"", with: "") + "\""
        var lines = ["@echo off", "rem Madeira ml2013: one-time installs before Madeira Dock starts the game",
                     "echo begin \(processes.count)" + result.replacingOccurrences(of: " >>", with: " >")]
        switch services {
        case .none: break
        case .off: lines.append("echo services off" + result)
        case .start(let executable):
            lines.append("\"" + executable.replacingOccurrences(of: "\"", with: "") + "\" --start-services" + result)
            lines.append("if not \"%ERRORLEVEL%\"==\"0\" echo services failed" + result)
        }
        for (offset, process) in processes.enumerated() {
            let index = offset + 1
            let quoted = "\"" + process.executable + "\""
            let command = process.executable.lowercased().hasSuffix(".msi")
                ? "C:\\windows\\system32\\msiexec.exe /i " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
                : "call " + quoted + (process.arguments.isEmpty ? "" : " " + process.arguments)
            let name = label(process.run)
            lines.append("echo [dock-installers] ml2013 running \(index)/\(processes.count) " + name)
            lines.append("echo start \(index) " + name + result)
            lines.append(command)
            for ok in ["0", "3010", "1641"] { lines.append("if \"%ERRORLEVEL%\"==\"\(ok)\" goto madeira_ok_\(index)") }
            let fallback = providedFallback.contains(process.run) ? providedRuntime(process) : nil
            if let fallback {
                // ml2014: the "provided" line precedes the exit line, so a reader that sees the
                // exit also sees why it is recorded done.
                lines.append("set madeira_status=%ERRORLEVEL%")
                lines.append("echo provided \(index) " + fallback + result)
                lines.append("echo exit \(index) %madeira_status%" + result)
                lines.append("goto madeira_mark_\(index)")
            } else {
                lines.append("echo exit \(index) %ERRORLEVEL%" + result)
                lines.append("goto madeira_next_\(index)")
            }
            lines.append(":madeira_ok_\(index)")
            lines.append("echo exit \(index) %ERRORLEVEL%" + result)
            if fallback != nil { lines.append(":madeira_mark_\(index)") }
            let hive = process.run.hive == .machine ? "HKLM" : "HKCU"
            let value = process.run.name.replacingOccurrences(of: "\"", with: "")
            for key in SteamInstallScripts.keys(process.run) {
                lines.append("C:\\windows\\system32\\reg.exe add \"\(hive)\\\(key.replacingOccurrences(of: "\"", with: ""))\" /v \"\(value)\" /t REG_DWORD /d \(process.run.value) /f >nul")
            }
            lines.append(":madeira_next_\(index)")
        }
        lines.append("echo end" + result)
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// ml2013: a result file read back: programs in the batch, which started (index -> label),
    /// which exited (index -> status) and whether the batch finished.
    struct Results: Equatable, Sendable {
        var total = 0
        var started: [Int: String] = [:]
        var exits: [Int: Int] = [:]
        var ended = false
        /// ml2014: the service-manager step's outcome ("started", "already", "failed", "off").
        var services: String?
        /// ml2014: programs recorded done after a failed exit (index -> provided runtime).
        var provided: [Int: String] = [:]
        var running: Int? { started.keys.filter { exits[$0] == nil }.max() }
        static func succeeded(_ status: Int) -> Bool { status == 0 || status == 3010 || status == 1641 }
        /// ml2014: a provided runtime whose installer failed; recorded done, not run again.
        func providedAfterFailure(_ index: Int) -> Bool {
            guard let status = exits[index] else { return false }
            return !Self.succeeded(status) && provided[index] != nil
        }
    }
    static func results(_ text: String) -> Results {
        var results = Results()
        // cmd.exe writes CRLF; "\r\n" is one Character, so split on any newline Character.
        for raw in text.split(whereSeparator: { $0.isNewline }).prefix(200) {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            guard let verb = parts.first else { continue }
            switch verb {
            case "begin":
                results.total = parts.count > 1 ? min(Int(parts[1]) ?? 0, 64) : 0
            case "start":
                if parts.count > 1, let index = Int(parts[1]), (1...64).contains(index) {
                    results.started[index] = parts.count > 2 ? String(parts[2].prefix(64)) : ""
                }
            case "exit":
                if parts.count > 2, let index = Int(parts[1]), (1...64).contains(index),
                   let status = Int(parts[2].trimmingCharacters(in: .whitespaces)) { results.exits[index] = status }
            case "services":
                let word = parts.count > 1 ? String(parts[1].filter { $0.isLetter }.prefix(16)) : ""
                if !word.isEmpty { results.services = word }
            case "provided":
                if parts.count > 2, let index = Int(parts[1]), (1...64).contains(index) {
                    let name = String(parts[2].filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." || $0 == "+" }.prefix(32))
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { results.provided[index] = name }
                }
            case "end":
                results.ended = true
            default:
                continue
            }
        }
        return results
    }
}
