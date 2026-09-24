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
    static func compact(_ detected: String?) -> String? {
        guard let detected else { return nil }
        let values = Set(detected.split(separator: "/").map(String.init))
        // This is a compact capability label, not a forced backend choice.
        return ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"].first(where: values.contains) ?? detected
    }
}
