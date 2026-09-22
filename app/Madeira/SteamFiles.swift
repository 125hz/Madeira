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

enum LibraryRendererBadge {
    static func compact(_ detected: String?) -> String? {
        guard let detected else { return nil }
        let values = Set(detected.split(separator: "/").map(String.init))
        // This is a compact capability label, not a forced backend choice.
        return ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"].first(where: values.contains) ?? detected
    }
}
