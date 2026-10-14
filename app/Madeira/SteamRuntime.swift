// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import zlib
#if canImport(CryptoKit)
import CryptoKit
#endif

// Valve's client components for Madeira Dock, fetched from Valve's own update
// CDN (one host, HTTPS) and checked against pinned sizes and SHA-256 sums; the
// unpacked steamclient64.dll must be the client build the Dock host supports.
// Pins never follow a moving client manifest. No Valve binary is bundled.
enum SteamRuntimeFiles {
    struct Package: Sendable {
        let file: String
        let bytes: Int
        let sha256: String
    }
    static let origin = "https://client-update.akamai.steamstatic.com/"
    static let packages = [
        Package(file: "bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da", bytes: 59_544_006,
                sha256: "8b712b2a3412a9066b7725f4e1c5cef9a7ca5b187b6585a5b92d25d09df0ba62"),
        Package(file: "bins_win64_win32.zip.f29d67dc38a4be027f1734802697c668621a6da1", bytes: 10_509_550,
                sha256: "345f6e4bdc19b27ae53bf752c21e2d894e0e899d94823222fb426e890d1226b5"),
        Package(file: "steam_win32.zip.3e96965d109fc2d4cc14206b2fc4ec960a746ed3", bytes: 2_307_664,
                sha256: "1369615c795b60de822876b4dc4042186cf58d0dc8f63ea1371167f667e16925")
    ]
    static let clientSHA256 = "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640"
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"

    enum Failure: LocalizedError {
        case invalidPackage, conflict, activeSession, prefixMissing
        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "Steam's components could not be verified. Try downloading them again."
            case .conflict: return "Existing Steam files need attention. They were kept. Use the desktop setup option."
            case .activeSession: return "Close the running session before preparing Steam's components."
            case .prefixMissing: return "Madeira could not prepare its Windows environment."
            }
        }
    }

    static func validPath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < 240,
              !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") }
    }

    static func destination(_ relative: String, under drive: URL) throws -> URL {
        guard validPath(relative) else { throw Failure.conflict }
        let fm = FileManager.default
        var result = drive
        for component in relative.split(separator: "/") {
            if fm.fileExists(atPath: result.path) {
                let matches = try fm.contentsOfDirectory(atPath: result.path)
                    .filter { $0.caseInsensitiveCompare(String(component)) == .orderedSame }
                guard matches.isEmpty || matches == [String(component)] else { throw Failure.conflict }
            }
            result.appendPathComponent(String(component))
            guard result.standardizedFileURL.path == result.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw Failure.conflict
            }
        }
        return result
    }

    /// How large an archive may be. Dock's three pinned packages use `dock`;
    /// ml1370's full client (SteamClientPackages) uses `client`: its web runtime
    /// package holds a 220 MB library and its UI packages thousands of files.
    struct Limits: Sendable {
        let archive: Int, entry: Int, total: Int, count: Int
        static let dock = Limits(archive: 64 << 20, entry: 64 << 20, total: 256 << 20, count: 256)
        static let client = Limits(archive: 512 << 20, entry: 512 << 20, total: 2048 << 20, count: 32_768)
    }

    // Parse the central directory, then validate each local header. ZIP64,
    // encryption, symlinks and duplicate/case-colliding names are rejected.
    // Called only AFTER the whole archive's pinned SHA-256 has been checked.
    static func unpack(_ data: Data, write: (String, Data) throws -> Void) throws {
        try unpack(data, limits: .dock) { name, size, read in
            var whole = Data(capacity: size)
            try read { piece in
                if let base = piece.baseAddress { whole.append(base.assumingMemoryBound(to: UInt8.self), count: piece.count) }
            }
            try write(name, whole)
        }
    }

    /// The same checks, one file at a time without holding it whole (ml1370):
    /// `file(name, size, read)` must call `read` once; it hands the file's bytes
    /// to its closure in pieces of at most 1 MB and throws after the last piece
    /// when the CRC or the size is wrong, so a caller keeps nothing it read
    /// before `read` returned. `directory` gets the folder entries.
    static func unpack(_ data: Data, limits: Limits, directory: ((String) throws -> Void)? = nil,
                       file: (String, Int, (_ sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws -> Void) throws {
        func need(_ condition: Bool) throws { if !condition { throw Failure.invalidPackage } }
        try need(data.count >= 22 && data.count <= limits.archive)
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else {
            throw Failure.invalidPackage
        }
        let count = u16(end + 10), central = u32(end + 16), centralSize = u32(end + 12)
        try need(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count && count <= limits.count)
        try need(central <= end && centralSize == end - central)
        var cursor = central, total = 0
        var seen = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            try need(cursor + 46 <= end && u32(cursor) == 0x02014b50)
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16)), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), local = u32(cursor + 42)
            let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            let kind = (u32(cursor + 38) >> 16) & 0xf000
            try need(next <= end && flags & 1 == 0 && (method == 0 || method == 8))
            try need(kind == 0 || kind == 0x8000 || kind == 0x4000)
            guard let rawName = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else {
                throw Failure.invalidPackage
            }
            // Valve's Windows packages use backslashes. Normalize BEFORE all
            // traversal/duplicate checks, but compare local headers verbatim.
            let normalizedName = rawName.replacingOccurrences(of: "\\", with: "/")
            let isDirectory = normalizedName.hasSuffix("/")
            let name = isDirectory ? String(normalizedName.dropLast()) : normalizedName
            try need(validPath(name) && seen.insert(name.lowercased()).inserted)
            try need(size <= limits.entry && local + 30 <= central && u32(local) == 0x04034b50)
            try need(u16(local + 6) == flags && u16(local + 8) == method && u16(local + 26) == nameLength)
            let body = local + 30 + nameLength + u16(local + 28)
            try need(body <= central && compressed <= central - body)
            try need(data.subdata(in: local + 30..<local + 30 + nameLength) == Data(rawName.utf8))
            if flags & 8 == 0 { try need(u32(local + 18) == compressed && u32(local + 22) == size) }
            total += size
            try need(total <= limits.total)
            if isDirectory {
                try need(size == 0 && compressed == 0)
                try directory?(name)
                cursor = next; continue
            }
            var reads = 0
            try file(name, size) { sink in
                reads += 1
                try need(reads == 1)
                try data.withUnsafeBytes { raw in
                    let source = UnsafeRawBufferPointer(rebasing: raw[body..<body + compressed])
                    var actualCRC = crc32(0, nil, 0)
                    let piece = 1 << 20
                    if method == 0 {
                        try need(compressed == size)
                        var offset = 0
                        while offset < size {
                            let part = UnsafeRawBufferPointer(rebasing: source[offset..<min(size, offset + piece)])
                            actualCRC = crc32(actualCRC, part.bindMemory(to: UInt8.self).baseAddress, UInt32(part.count))
                            try sink(part)
                            offset += part.count
                        }
                    } else {
                        var stream = z_stream()
                        try need(inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
                        defer { inflateEnd(&stream) }
                        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: piece, alignment: 16)
                        defer { out.deallocate() }
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                        stream.avail_in = UInt32(compressed)
                        var produced = 0, result = Z_OK
                        while result != Z_STREAM_END {
                            stream.next_out = out.bindMemory(to: UInt8.self).baseAddress
                            stream.avail_out = UInt32(piece)
                            result = inflate(&stream, Z_NO_FLUSH)
                            try need(result == Z_OK || result == Z_STREAM_END)
                            let length = piece - Int(stream.avail_out)
                            produced += length
                            try need(produced <= size && (length > 0 || result == Z_STREAM_END))
                            if length > 0 {
                                let part = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(out)[0..<length])
                                actualCRC = crc32(actualCRC, part.bindMemory(to: UInt8.self).baseAddress, UInt32(length))
                                try sink(part)
                            }
                        }
                        try need(Int(stream.total_in) == compressed && Int(stream.total_out) == size && produced == size)
                    }
                    try need(UInt32(actualCRC) == crc)
                }
            }
            try need(reads == 1)
            cursor = next
        }
        try need(cursor == end)
    }

    // Only fixed client-discovery paths are written. Never write user IDs,
    // licenses, login cache, tokens, or a value asserting ownership.
    static func registry(_ text: String, machine: Bool, windowsRoot: String = SteamRuntimeFiles.windowsRoot) throws -> String {
        guard text.hasPrefix("WINE REGISTRY Version 2") else { throw Failure.prefixMissing }
        let root = windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
        let sections: [(String, [(String, String)])] = machine
            ? [("Software\\\\Valve\\\\Steam", [("InstallPath", root)]),
               ("Software\\\\Wow6432Node\\\\Valve\\\\Steam", [("InstallPath", root)])]
            : [("Software\\\\Valve\\\\Steam", [("SteamPath", root), ("SteamExe", root + "\\\\steam.exe")]),
               ("Software\\\\Valve\\\\Steam\\\\ActiveProcess",
                [("SteamClientDll", root + "\\\\steamclient.dll"), ("SteamClientDll64", root + "\\\\steamclient64.dll")])]
        var lines = text.components(separatedBy: "\n")
        for (key, values) in sections {
            let header = "[\(key)]"
            let starts = lines.indices.filter { lines[$0].lowercased().hasPrefix(header.lowercased()) }
            guard starts.count <= 1 else { throw Failure.conflict }
            if let start = starts.first {
                let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
                var additions: [String] = []
                for (name, value) in values {
                    let prefix = "\"\(name)\"="
                    let matches = lines[(start + 1)..<end].filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
                    let expected = prefix + "\"\(value)\""
                    guard matches.isEmpty || matches == [expected] else { throw Failure.conflict }
                    if matches.isEmpty { additions.append(expected) }
                }
                lines.insert(contentsOf: additions, at: end)
            } else {
                lines += ["", header] + values.map { "\"\($0.0)\"=\"\($0.1)\"" } + [""]
            }
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(CryptoKit)
private final class SteamRuntimeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "client-update.akamai.steamstatic.com"
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

actor SteamRuntimeInstaller {
    static let shared = SteamRuntimeInstaller()
    private var busy = false

    // Runs before any Wine session in this app run; no Wine/JIT run.
    func prepare(prefix: URL, progress: @Sendable (String) async -> Void) async throws {
        guard !busy, wine_process_is_running() == 0, wineserver_is_running() == 0 else {
            throw SteamRuntimeFiles.Failure.activeSession
        }
        busy = true; defer { busy = false }
        let fm = FileManager.default
        // Do not let the template seeder overwrite a preexisting, unstamped
        // registry. Fresh downloads may have created drive_c/steamapps only.
        if !fm.fileExists(atPath: prefix.appendingPathComponent(".update-timestamp").path),
           ["system.reg", "user.reg"].contains(where: { fm.fileExists(atPath: prefix.appendingPathComponent($0).path) }) {
            throw SteamRuntimeFiles.Failure.conflict
        }
        let drive = prefix.appendingPathComponent("drive_c")
        let root = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw SteamRuntimeFiles.Failure.conflict
        }
        // Existing installs are retained; this trial prepares missing files.
        guard !fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path) else {
            throw SteamRuntimeFiles.Failure.conflict
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("madeira-runtime-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: SteamRuntimeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var names = Set<String>(), files: [String] = []
        for (index, package) in SteamRuntimeFiles.packages.enumerated() {
            try Task.checkCancellation()
            await progress("Downloading Steam components (\(index + 1) of \(SteamRuntimeFiles.packages.count))…")
            let url = URL(string: SteamRuntimeFiles.origin + package.file)!
            let (temporary, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == url.host, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw SteamRuntimeFiles.Failure.invalidPackage
            }
            let archive = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard Self.hash(archive) == package.sha256 else { throw SteamRuntimeFiles.Failure.invalidPackage }
            await progress("Verifying Steam components…")
            try SteamRuntimeFiles.unpack(archive) { name, bytes in
                guard names.insert(name.lowercased()).inserted else { throw SteamRuntimeFiles.Failure.invalidPackage }
                let file = stage.appendingPathComponent(name)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
                files.append(name)
            }
        }
        guard Self.hash(try Data(contentsOf: stage.appendingPathComponent("steamclient64.dll"))) == SteamRuntimeFiles.clientSHA256,
              files.contains("steam.exe") else { throw SteamRuntimeFiles.Failure.invalidPackage }
        try Task.checkCancellation()
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw SteamRuntimeFiles.Failure.activeSession }
        await progress("Preparing the Windows environment…")
        try Task.checkCancellation()
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw SteamRuntimeFiles.Failure.activeSession }
        madeira_seed_prefix_if_needed(prefix.path)
        // Preflight all destinations and both hives before publishing anything.
        var pending: [(URL, Data)] = []
        for (file, machine) in [("system.reg", true), ("user.reg", false)] {
            let url = prefix.appendingPathComponent(file)
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw SteamRuntimeFiles.Failure.conflict
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            pending.append((url, Data(try SteamRuntimeFiles.registry(text, machine: machine).utf8)))
        }
        for name in files {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if fm.fileExists(atPath: target.path), !fm.contentsEqual(atPath: target.path, andPath: stage.appendingPathComponent(name).path) {
                throw SteamRuntimeFiles.Failure.conflict
            }
        }
        try Task.checkCancellation()
        // No suspension during commit. steam.exe is last, so a check for an installed
        // client never mistakes a partial package for one. A retry accepts
        // identical files left by an interrupted commit, never replaces others.
        for (url, bytes) in pending {
            let backup = url.appendingPathExtension("dock-setup-bak")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
            try bytes.write(to: url, options: .atomic)
        }
        for name in files.sorted(by: { $0 == "steam.exe" ? false : ($1 == "steam.exe" ? true : $0 < $1) }) {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage.appendingPathComponent(name), to: target)
        }
        await progress("Steam components are ready.")
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - ml1370: the full Steam client from Valve's packages

/// The whole Windows client (the UI, its web runtime, resources and strings),
/// installed the way Valve's bootstrapper installs it, but by the app: the
/// platform manifest `steam_client_win64` from Valve's update host lists the
/// packages with their sizes and SHA-256 sums; each is downloaded from the same
/// host, checked against both before it is read, and unpacked with the reader
/// above into `C:\Program Files (x86)\Steam`. Nothing is pinned here: the client
/// is the current one (Madeira Dock's pinned components are a separate,
/// verified subset of an older 32-bit manifest). No Valve file is bundled and
/// no account data is read or written.
enum SteamClientPackages {
    static var installWindowsRoot: String {
        let prefix = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("wine")
        return madeira_process_host_shared_drive(prefix.path) == nil ? SteamRuntimeFiles.windowsRoot : "D:\\Steam"
    }
    /// The manifest the 64-bit client's bootstrapper reads (Valve's file name).
    static let manifestName = "steam_client_win64"
    /// Its top-level section ("win64").
    static var platform: String { String(manifestName.dropFirst("steam_client_".count)) }
    /// Where Valve's bootstrapper keeps the manifest of the installed client
    /// (relative to the Steam folder). Written after a complete install.
    static var manifestCopy: String { "package/" + manifestName + ".manifest" }
    /// User data in the Steam folder: never replaced by a package file.
    static let keptFolders: Set<String> = ["steamapps", "userdata", "config", "logs", "dumps", "appcache", "depotcache"]

    struct Package: Sendable, Equatable {
        let name: String
        let file: String
        let bytes: Int
        let sha256: String
    }

    struct Manifest: Sendable {
        let version: String
        /// Download order: by name, the bootstrapper's own package (steam.exe) last.
        let packages: [Package]
        var bytes: Int { packages.reduce(0) { $0 + $1.bytes } }
    }

    enum Failure: LocalizedError {
        case manifest(String), download(String), package(String), space(Int), dockSession, notWindows64
        var errorDescription: String? {
            switch self {
            case .manifest(let why): return "Valve's client manifest could not be used: \(why)."
            case .download(let why): return "A Steam package could not be downloaded: \(why)."
            case .package(let why): return "A Steam package failed its check: \(why). Nothing was installed; try again."
            case .space(let mb): return "Not enough free space: installing Steam needs about \(mb) MB."
            case .dockSession: return "Steam cannot be installed during a Madeira Dock session (Dock uses the client's files). End the game first."
            case .notWindows64: return "The downloaded client is not the 64-bit Windows client."
            }
        }
    }

    /// The packages of Valve's manifest text. Strings packages for other
    /// languages than `language` are left out (as the bootstrapper does);
    /// nested variants (regional builds of the bootstrapper package) are ignored.
    static func parse(_ data: Data, language: String = "en") throws -> Manifest {
        guard data.count <= 1 << 20, var reader = try? SteamKeyValues(data), let root = try? reader.read(),
              let section = root[platform] else { throw Failure.manifest("no \(platform) section") }
        guard let version = section["version"]?.string, !version.isEmpty, version.count <= 20,
              version.allSatisfy(\.isNumber) else { throw Failure.manifest("no version") }
        var packages: [Package] = []
        for (name, value) in section.fields {
            guard let file = value["file"]?.string else { continue }
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else {
                throw Failure.manifest("a package name is not plain")
            }
            if name.hasPrefix("strings_"), name.hasSuffix("_all"), name != "strings_all", name != "strings_\(language)_all" { continue }
            guard file.hasPrefix(name + ".zip."), SteamRuntimeFiles.validPath(file), !file.contains("/"),
                  let bytes = value["size"]?.string.flatMap({ Int($0) }), bytes > 0, bytes <= SteamRuntimeFiles.Limits.client.archive,
                  let sha = value["sha2"]?.string?.lowercased(), sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
                throw Failure.manifest("package \(name) is malformed")
            }
            packages.append(Package(name: name, file: file, bytes: bytes, sha256: sha))
        }
        guard (1...64).contains(packages.count) else { throw Failure.manifest("\(packages.count) packages") }
        let bootstrapper = section.fields.filter { $0.value["isbootstrapperpackage"]?.string == "1" }.map(\.key)
        packages.sort { a, b in
            let la = bootstrapper.contains(a.name), lb = bootstrapper.contains(b.name)
            return la != lb ? lb : a.name < b.name
        }
        return Manifest(version: version, packages: packages)
    }

    /// A PE file for x86-64 (IMAGE_FILE_MACHINE_AMD64); false for the 32-bit
    /// client's steam.exe that Madeira Dock's components contain.
    static func isWindows64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 64, head[0] == 0x4d, head[1] == 0x5a else { return false }
        let pe = Int(head[0x3c]) | Int(head[0x3d]) << 8 | Int(head[0x3e]) << 16 | Int(head[0x3f]) << 24
        guard pe >= 64, pe + 6 <= head.count, head[pe] == 0x50, head[pe + 1] == 0x45, head[pe + 2] == 0, head[pe + 3] == 0 else { return false }
        return (Int(head[pe + 4]) | Int(head[pe + 5]) << 8) == 0x8664
    }

    /// The full 64-bit client is installed under `root` (the Steam folder): an
    /// x86-64 steam.exe and the platform manifest Valve's bootstrapper (or this
    /// installer) leaves after a complete install.
    static func installed(root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestCopy).path)
            && isWindows64(root.appendingPathComponent("steam.exe"))
    }

    /// The installed client's manifest version, when installed() holds.
    static func installedVersion(root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(manifestCopy)) else { return nil }
        return (try? parse(data))?.version
    }
}

/// What the installer is doing, for the progress sheet and the log.
struct SteamClientInstallProgress: Sendable, Equatable {
    enum Phase: String, Sendable { case manifest, downloading, unpacking, done, installing, finished }
    var phase: Phase = .manifest
    /// 1-based package number and the package count (0 before the manifest).
    var part = 0, parts = 0
    var name = ""
    var bytes = 0
    /// Bytes of this package received so far (downloading).
    var received = 0
    /// All packages: bytes finished before this one, and the total.
    var finishedBytes = 0, totalBytes = 0
    var version = ""
    /// Files of the client (installing / finished).
    var files = 0
    /// What happened to Steam's registry keys (finished).
    var registry = ""
}

/// Download progress arrives for every buffer; the sheet needs a few hundred updates.
private final class SteamProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let step: Int64
    private var last: Int64 = 0
    init(step: Int) { self.step = Int64(step) }
    func pass(_ value: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value - last >= step else { return false }
        last = value
        return true
    }
}

private final class SteamDownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    var observation: NSKeyValueObservation?
    func set(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
}

actor SteamClientInstaller {
    static let shared = SteamClientInstaller()
    private var busy = false

    /// Installs the current full client into `prefix`'s drive C. `sessionRunning`:
    /// a Wine session is up (the windowed taskbar): files only; the registry is
    /// left to Steam, which writes its own keys when it starts. Without a session
    /// the prefix is seeded first and Madeira Dock's discovery keys are written
    /// when they do not conflict. Existing files are replaced, except user data
    /// (SteamClientPackages.keptFolders); steam.exe is written last.
    func install(prefix: URL, sessionRunning: Bool,
                 progress: @escaping @Sendable (SteamClientInstallProgress) async -> Void) async throws -> SteamClientInstallProgress {
        guard !busy else { throw SteamClientPackages.Failure.download("an install is already running") }
        if sessionRunning, getenv("MADEIRA_DOCK_SESSION").map({ String(cString: $0) == "1" }) == true {
            throw SteamClientPackages.Failure.dockSession
        }
        busy = true; defer { busy = false }
        let fm = FileManager.default
        var state = SteamClientInstallProgress()
        await progress(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration, delegate: SteamRuntimeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // The manifest.
        let manifestURL = URL(string: SteamRuntimeFiles.origin + SteamClientPackages.manifestName)!
        let (manifestData, manifestResponse): (Data, URLResponse)
        do { (manifestData, manifestResponse) = try await session.data(from: manifestURL) }
        catch { throw SteamClientPackages.Failure.manifest(Self.reason(error)) }
        guard let http = manifestResponse as? HTTPURLResponse, http.statusCode == 200, http.url?.host == manifestURL.host else {
            throw SteamClientPackages.Failure.manifest("Valve's server answered \((manifestResponse as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let manifest = try SteamClientPackages.parse(manifestData)
        state.parts = manifest.packages.count; state.totalBytes = manifest.bytes; state.version = manifest.version

        // Room for the packages, the unpacked client and a margin (the unpacked client is ~2.3x the packages).
        let need = manifest.bytes * 3 + (256 << 20)
        if let free = try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(need) {
            throw SteamClientPackages.Failure.space(need >> 20)
        }

        let stage = fm.temporaryDirectory.appendingPathComponent("madeira-steam-client-" + UUID().uuidString)
        let files = stage.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        // Lower-case relative path -> the spelling of its first package. The
        // stage keeps exact spellings; the commit matches them to the disk.
        var names: [String: String] = [:], folders: [String: String] = [:]
        var made = Set<String>()   // stage folders already created (exact spelling)
        func staged(_ name: String) throws -> URL {
            let key = name.lowercased()
            let spelled = names[key] ?? name
            names[key] = spelled
            let url = files.appendingPathComponent(spelled)
            let parent = (spelled as NSString).deletingLastPathComponent
            if !parent.isEmpty, made.insert(parent).inserted {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            return url
        }

        for (index, package) in manifest.packages.enumerated() {
            try Task.checkCancellation()
            state.part = index + 1; state.name = package.name; state.bytes = package.bytes; state.received = 0
            state.phase = .downloading
            await progress(state)
            let archive = stage.appendingPathComponent("package.zip")
            try? fm.removeItem(at: archive)
            let url = URL(string: SteamRuntimeFiles.origin + package.file)!
            let snapshot = state
            let throttle = SteamProgressThrottle(step: max(256 << 10, package.bytes / 200))
            let response = try await Self.download(url, to: archive, session: session) { received in
                guard throttle.pass(received) else { return }
                var now = snapshot; now.received = Int(received)
                Task { await progress(now) }
            }
            guard response.statusCode == 200, response.url?.host == url.host, response.url?.scheme == "https" else {
                throw SteamClientPackages.Failure.download("Valve's server answered \(response.statusCode) for \(package.name)")
            }
            guard (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw SteamClientPackages.Failure.package("\(package.name) has the wrong size")
            }
            state.received = package.bytes; state.phase = .unpacking
            await progress(state)
            let data = try Data(contentsOf: archive, options: .alwaysMapped)
            guard Self.hash(data) == package.sha256 else { throw SteamClientPackages.Failure.package("\(package.name) has the wrong SHA-256") }
            do {
                try SteamRuntimeFiles.unpack(data, limits: .client, directory: { name in
                    let key = name.lowercased()
                    let spelled = folders[key] ?? name
                    folders[key] = spelled
                    if made.insert(spelled).inserted {
                        try fm.createDirectory(at: files.appendingPathComponent(spelled), withIntermediateDirectories: true)
                    }
                }) { name, _, read in
                    let target = try staged(name)
                    try? fm.removeItem(at: target)   // a later package's copy of the same file wins, as in the bootstrapper
                    guard fm.createFile(atPath: target.path, contents: nil) else { throw SteamRuntimeFiles.Failure.invalidPackage }
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try read { piece in
                        guard let base = piece.baseAddress else { return }
                        // No copy: the piece stays valid until this returns.
                        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                                                          count: piece.count, deallocator: .none))
                    }
                }
            } catch SteamRuntimeFiles.Failure.invalidPackage {
                throw SteamClientPackages.Failure.package("\(package.name) is not a ZIP archive Madeira accepts")
            }
            try? fm.removeItem(at: archive)
            state.finishedBytes += package.bytes; state.phase = .done
            await progress(state)
        }

        guard let exe = names["steam.exe"] else { throw SteamClientPackages.Failure.package("no steam.exe in the packages") }
        guard SteamClientPackages.isWindows64(files.appendingPathComponent(exe)) else { throw SteamClientPackages.Failure.notWindows64 }
        try Task.checkCancellation()

        // Commit: no cancellation from here.
        state.phase = .installing; state.files = names.count
        await progress(state)
        if !sessionRunning, wine_process_is_running() == 0, wineserver_is_running() == 0 {
            madeira_seed_prefix_if_needed(prefix.path)
        }
        let drive = prefix.appendingPathComponent("drive_c")
        let shared = madeira_process_host_shared_drive(prefix.path).map { URL(fileURLWithPath: $0) }
        let root = shared?.appendingPathComponent("Steam") ?? drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        let windowsRoot = shared == nil ? SteamRuntimeFiles.windowsRoot : "D:\\Steam"
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw SteamRuntimeFiles.Failure.conflict
        }
        var resolver = SteamFolderResolver(root: root)
        for folder in folders.values.sorted() { _ = try resolver.folder(folder) }
        let ordered = names.values.sorted { a, b in
            a.lowercased() == "steam.exe" ? false : (b.lowercased() == "steam.exe" ? true : a < b)
        }
        var kept = 0
        for name in ordered {
            let target = try resolver.file(name)
            if fm.fileExists(atPath: target.path) {
                let top = name.split(separator: "/").first.map { $0.lowercased() } ?? ""
                if SteamClientPackages.keptFolders.contains(top) { kept += 1; continue }
                var isFolder: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue { throw SteamRuntimeFiles.Failure.conflict }
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: files.appendingPathComponent(name), to: target)
        }
        let packageFolder = try resolver.folder("package")
        try manifestData.write(to: packageFolder.appendingPathComponent(SteamClientPackages.manifestName + ".manifest"), options: .atomic)

        // Steam's discovery keys, as Dock writes them, only while no session owns the registry.
        if sessionRunning || wine_process_is_running() != 0 || wineserver_is_running() != 0 {
            state.registry = "left to Steam (a session is running; Steam writes its own keys when it starts)"
        } else if !fm.fileExists(atPath: prefix.appendingPathComponent(".update-timestamp").path) {
            state.registry = "left as is (the prefix's registry is not the app's template)"
        } else {
            do {
                var pending: [(URL, Data)] = []
                for (file, machine) in [("system.reg", true), ("user.reg", false)] {
                    let url = prefix.appendingPathComponent(file)
                    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                        throw SteamRuntimeFiles.Failure.conflict
                    }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    pending.append((url, Data(try SteamRuntimeFiles.registry(text, machine: machine, windowsRoot: windowsRoot).utf8)))
                }
                for (url, bytes) in pending {
                    let backup = url.appendingPathExtension("steam-setup-bak")
                    if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
                    try bytes.write(to: url, options: .atomic)
                }
                state.registry = "install path and client DLL paths written"
            } catch {
                state.registry = "left as is (\(error is SteamRuntimeFiles.Failure ? "Steam keys for another folder are already there" : Self.reason(error)))"
            }
        }
        state.phase = .finished
        if kept > 0 { state.registry += "; \(kept) existing user-data files kept" }
        await progress(state)
        return state
    }

    private static func download(_ url: URL, to target: URL, session: URLSession,
                                 received: @escaping @Sendable (Int64) -> Void) async throws -> HTTPURLResponse {
        let box = SteamDownloadBox()
        defer { box.observation = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let task = session.downloadTask(with: url) { temporary, response, error in
                    // The temporary file is removed when this returns: move it first.
                    if let error {
                        continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError()
                                            : SteamClientPackages.Failure.download(reason(error)))
                        return
                    }
                    guard let temporary, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: SteamClientPackages.Failure.download("no file")); return
                    }
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: temporary, to: target)
                        continuation.resume(returning: http)
                    } catch {
                        continuation.resume(throwing: SteamClientPackages.Failure.download(reason(error)))
                    }
                }
                box.observation = task.progress.observe(\.completedUnitCount) { progress, _ in received(progress.completedUnitCount) }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Paths under the Steam folder, matched case-insensitively against what is
/// already there (Dock's components, an earlier install), as Windows would;
/// symlinks are refused. Directory listings are read once.
private struct SteamFolderResolver {
    let root: URL
    private var listings: [String: [String: String]] = [:]   // folder path -> lower-case name -> name on disk
    init(root: URL) { self.root = root }

    private mutating func child(_ name: String, of parent: URL) throws -> URL {
        let fm = FileManager.default
        if listings[parent.path] == nil {
            var names: [String: String] = [:]
            for entry in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] { names[entry.lowercased()] = entry }
            listings[parent.path] = names
        }
        let spelled = listings[parent.path]?[name.lowercased()] ?? name
        listings[parent.path]?[name.lowercased()] = spelled
        let url = parent.appendingPathComponent(spelled)
        if let kind = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType, kind == .typeSymbolicLink {
            throw SteamRuntimeFiles.Failure.conflict
        }
        return url
    }

    /// The folder (created when missing).
    mutating func folder(_ relative: String) throws -> URL {
        guard SteamRuntimeFiles.validPath(relative) else { throw SteamRuntimeFiles.Failure.conflict }
        var url = root
        for component in relative.split(separator: "/") {
            url = try child(String(component), of: url)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) {
                guard isFolder.boolValue else { throw SteamRuntimeFiles.Failure.conflict }
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
        }
        return url
    }

    /// Where a file goes (its folder created when missing).
    mutating func file(_ relative: String) throws -> URL {
        guard SteamRuntimeFiles.validPath(relative) else { throw SteamRuntimeFiles.Failure.conflict }
        let parent = (relative as NSString).deletingLastPathComponent
        let folder = parent.isEmpty ? root : try self.folder(parent)
        return try child((relative as NSString).lastPathComponent, of: folder)
    }
}
#endif
