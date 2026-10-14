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
    // `force` (ml1371 Dock repair): values another client wrote for these names
    // are replaced instead of stopping as a conflict.
    static func registry(_ text: String, machine: Bool, windowsRoot: String = SteamRuntimeFiles.windowsRoot,
                         force: Bool = false) throws -> String {
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
                var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
                if force {
                    let names = values.map { "\"\($0.0)\"=".lowercased() }
                    let stale = ((start + 1)..<end).filter { index in names.contains { lines[index].lowercased().hasPrefix($0) } }
                    for index in stale.reversed() { lines.remove(at: index) }
                    end -= stale.count
                }
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
    // `repair` (ml1371, repairDock): also inside a running session, where only
    // the files are written; without a session Dock's discovery keys are
    // rewritten even when another client changed them. Returns whether the keys
    // were written.
    @discardableResult
    func prepare(prefix: URL, repair: Bool = false, progress: @Sendable (String) async -> Void) async throws -> Bool {
        guard !busy, repair || (wine_process_is_running() == 0 && wineserver_is_running() == 0) else {
            throw SteamRuntimeFiles.Failure.activeSession
        }
        busy = true; defer { busy = false }
        let fm = FileManager.default
        // Do not let the template seeder overwrite a preexisting, unstamped
        // registry. Fresh downloads may have created drive_c/steamapps only.
        if !repair, !fm.fileExists(atPath: prefix.appendingPathComponent(".update-timestamp").path),
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
        let live = wine_process_is_running() != 0 || wineserver_is_running() != 0
        guard repair || !live else { throw SteamRuntimeFiles.Failure.activeSession }
        await progress("Preparing the Windows environment…")
        try Task.checkCancellation()
        guard repair || (wine_process_is_running() == 0 && wineserver_is_running() == 0) else { throw SteamRuntimeFiles.Failure.activeSession }
        // Preflight all destinations and both hives before publishing anything.
        // A running session owns the registry: then only the files are written.
        var pending: [(URL, Data)] = []
        if !live {
            madeira_seed_prefix_if_needed(prefix.path)
            for (file, machine) in [("system.reg", true), ("user.reg", false)] {
                let url = prefix.appendingPathComponent(file)
                guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                    throw SteamRuntimeFiles.Failure.conflict
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                pending.append((url, Data(try SteamRuntimeFiles.registry(text, machine: machine, force: repair).utf8)))
            }
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
        return !pending.isEmpty
    }

    // MARK: ml1371: Dock repair

    /// Madeira Dock's folder keeps these when it is repaired (the account's
    /// data, the game library and the client's caches); everything else in it
    /// is the client, which the pinned packages replace.
    static let dockKept: Set<String> = ["steamapps", "userdata", "config", "depotcache", "appcache"]

    struct DockRepair: Sendable {
        /// The full client was moved from Dock's folder to `clientRoot`.
        var moved = false
        /// Top-level entries removed from Dock's folder (not moved).
        var removed = 0
        /// The kept entries found in Dock's folder.
        var kept: [String] = []
        /// steamclient64.dll's SHA-256 in Dock's folder afterwards.
        var sha256 = ""
        /// Dock's discovery keys were (re)written (no session was running).
        var keys = false
    }

    /// Puts Madeira Dock's folder (`C:\Program Files (x86)\Steam`) back to the
    /// pinned client build. A complete full client found there (an x86-64
    /// steam.exe and its saved manifest: an ml1370 install before the folders
    /// were separated) is moved to `clientRoot` when that is given and free,
    /// and Dock's kept folders are moved back; otherwise everything in Dock's
    /// folder except the kept folders is removed. Then the three pinned
    /// packages are fetched again (prepare, repair mode). Throws when the
    /// result is not the pinned steamclient64.dll.
    func repairDock(prefix: URL, clientRoot: URL?, progress: @escaping @Sendable (String) async -> Void) async throws -> DockRepair {
        guard !busy else { throw SteamRuntimeFiles.Failure.activeSession }
        let fm = FileManager.default
        var result = DockRepair()
        let drive = prefix.appendingPathComponent("drive_c")
        let dock = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        guard dock.standardizedFileURL.path == dock.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw SteamRuntimeFiles.Failure.conflict
        }
        await progress("Checking Madeira Dock's Steam folder…")
        if fm.fileExists(atPath: dock.path) {
            if SteamClientPackages.installed(root: dock), let clientRoot,
               clientRoot.standardizedFileURL.path != dock.standardizedFileURL.path,
               !fm.fileExists(atPath: clientRoot.path) {
                await progress("Moving the full Steam client to its own folder…")
                try fm.createDirectory(at: clientRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: dock, to: clientRoot)
                try fm.createDirectory(at: dock, withIntermediateDirectories: false)
                for name in try fm.contentsOfDirectory(atPath: clientRoot.path) where Self.dockKept.contains(name.lowercased()) {
                    try fm.moveItem(at: clientRoot.appendingPathComponent(name), to: dock.appendingPathComponent(name))
                    result.kept.append(name)
                }
                result.moved = true
            } else {
                await progress("Removing the other client's files from Madeira Dock's folder…")
                for name in try fm.contentsOfDirectory(atPath: dock.path) {
                    if Self.dockKept.contains(name.lowercased()) { result.kept.append(name); continue }
                    try fm.removeItem(at: dock.appendingPathComponent(name))
                    result.removed += 1
                }
            }
        }
        result.keys = try await prepare(prefix: prefix, repair: true, progress: progress)
        let client = dock.appendingPathComponent("steamclient64.dll")
        result.sha256 = Self.hash(try Data(contentsOf: client, options: .alwaysMapped))
        guard result.sha256 == SteamRuntimeFiles.clientSHA256 else { throw SteamRuntimeFiles.Failure.invalidPackage }
        result.kept.sort()
        return result
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
    /// ml1371: the full client never shares Madeira Dock's folder (Dock refuses
    /// any client build but its pinned one). Its own folder on drive C:, a sibling
    /// of Dock's; the full client runs from any folder.
    static let clientRelativeRoot = "Program Files (x86)/Steam Client"
    static let clientWindowsRoot = "C:\\Program Files (x86)\\Steam Client"

    /// Where the full client is installed: D:\Steam on the shared drive when
    /// env.MADEIRA_SHARED_DRIVE = 1 and the shared container resolves, else
    /// C:\Program Files (x86)\Steam Client in `prefix` (the active prefix).
    struct Target: Sendable {
        let root: URL
        let windowsRoot: String
        let shared: Bool
    }

    /// The app's own prefix (Documents/wine), which the shared-drive lookup takes.
    static var originalPrefix: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("wine")
    }
    /// The prefix sessions run in (MadeiraDock.prefix).
    static var activePrefix: URL { URL(fileURLWithPath: SharedContainer.activePrefix(originalPrefix.path)) }

    static func target(prefix: URL = activePrefix) -> Target {
        if let shared = SharedContainer.drive(prefix: originalPrefix.path) {
            return Target(root: URL(fileURLWithPath: shared).appendingPathComponent("Steam"), windowsRoot: "D:\\Steam", shared: true)
        }
        return Target(root: prefix.appendingPathComponent("drive_c").appendingPathComponent(clientRelativeRoot),
                      windowsRoot: clientWindowsRoot, shared: false)
    }

    static var installWindowsRoot: String { target().windowsRoot }

    /// An ml1370 install from before the folders were separated: the full client
    /// in Madeira Dock's folder (an x86-64 steam.exe and the saved manifest).
    static func inDockFolder(prefix: URL = activePrefix) -> Bool {
        installed(root: prefix.appendingPathComponent("drive_c").appendingPathComponent(SteamRuntimeFiles.relativeRoot))
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
        /// Download order (ml1370 resume): smallest first, so an interruption
        /// loses the least; ties by name.
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
            case .dockSession: return "Steam can't be installed while a Madeira Dock game is running (Dock uses the client's files). Quit the game first, then install Steam from the Desktop entry."
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
        packages.sort { $0.bytes != $1.bytes ? $0.bytes < $1.bytes : $0.name < $1.name }
        return Manifest(version: version, packages: packages)
    }

    // MARK: Resume (ml1370)

    /// The install's staging folder, kept between attempts (and app runs) so an
    /// interrupted install continues: `state` (manifest version, package count),
    /// `done/<package>` markers ("version package sha256") for packages already
    /// unpacked into `files/`, and `zips/` for downloaded packages not yet
    /// unpacked. Removed after a complete install. Not backed up.
    static var stageFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraSteam/client-stage", isDirectory: true)
    }

    static func marker(version: String, _ package: Package) -> String { "\(version) \(package.name) \(package.sha256)" }

    /// An interrupted install: its manifest version, the packages already done
    /// and the package count; nil when there is none.
    static func pendingInstall() -> (version: String, done: Int, parts: Int)? {
        let stage = stageFolder
        guard let text = try? String(contentsOf: stage.appendingPathComponent("state"), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let parts = Int(lines[1]), parts > 0 else { return nil }
        let version = lines[0]
        let done = ((try? FileManager.default.contentsOfDirectory(atPath: stage.appendingPathComponent("done").path)) ?? [])
            .filter { name in
                (try? String(contentsOf: stage.appendingPathComponent("done/" + name), encoding: .utf8))?
                    .hasPrefix(version + " " + name + " ") == true
            }.count
        return (version, min(done, parts), parts)
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
    enum Phase: String, Sendable { case manifest, downloading, unpacking, done, skipped, installing, finished }
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
    /// ml1370 resume: packages taken from an earlier, interrupted attempt.
    var resumed = 0
    /// The app's largest phys_footprint seen during the install, in MB.
    var peakFootprintMB = 0
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
    /// (SteamClientPackages.keptFolders); steam.exe is written last. ml1370
    /// resume: packages finished by an earlier attempt of the same client version
    /// are skipped (SteamClientPackages.stageFolder).
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
        state.peakFootprintMB = Self.footprintMB()

        // The staging folder survives an interruption; a different client version starts over.
        let stage = SteamClientPackages.stageFolder
        let files = stage.appendingPathComponent("files", isDirectory: true)
        let doneFolder = stage.appendingPathComponent("done", isDirectory: true)
        let zips = stage.appendingPathComponent("zips", isDirectory: true)
        if let earlier = SteamClientPackages.pendingInstall(), earlier.version != manifest.version {
            try? fm.removeItem(at: stage)
        }
        for folder in [files, doneFolder, zips] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var stageURL = stage; try? stageURL.setResourceValues(excluded)
        try Data("\(manifest.version)\n\(manifest.packages.count)\n".utf8).write(to: stage.appendingPathComponent("state"), options: .atomic)
        func finished(_ package: SteamClientPackages.Package) -> Bool {
            (try? String(contentsOf: doneFolder.appendingPathComponent(package.name), encoding: .utf8))
                == SteamClientPackages.marker(version: manifest.version, package)
        }

        // Room for the remaining packages, their unpacked files and a margin (the unpacked client is ~2.3x the packages).
        let remaining = manifest.packages.filter { !finished($0) }.reduce(0) { $0 + $1.bytes }
        let need = remaining * 3 + (256 << 20)
        if let free = try? stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(need) {
            throw SteamClientPackages.Failure.space(need >> 20)
        }

        // Lower-case relative path -> the spelling of its first package. The
        // stage keeps exact spellings; the commit matches them to the disk.
        // A resumed install reads back what earlier attempts staged.
        var names: [String: String] = [:], folders: [String: String] = [:]
        var made = Set<String>()   // stage folders already created (exact spelling)
        for (relative, isFolder) in Self.staged(in: files) {
            if isFolder {
                folders[relative.lowercased()] = folders[relative.lowercased()] ?? relative
                made.insert(relative)
            } else {
                names[relative.lowercased()] = names[relative.lowercased()] ?? relative
            }
        }
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
            if finished(package) {
                state.finishedBytes += package.bytes; state.resumed += 1; state.phase = .skipped
                await progress(state)
                continue
            }
            // A package downloaded by an earlier attempt but not unpacked is used
            // again when its size and SHA-256 still match.
            let archive = zips.appendingPathComponent(package.file)
            if let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == package.bytes,
               let earlier = try? Data(contentsOf: archive, options: .alwaysMapped), Self.hash(earlier) == package.sha256 {
                state.received = package.bytes; state.phase = .downloading
                await progress(state)
            } else {
                try? fm.removeItem(at: archive)
                state.phase = .downloading
                await progress(state)
                let url = URL(string: SteamRuntimeFiles.origin + package.file)!
                let snapshot = state
                let throttle = SteamProgressThrottle(step: max(256 << 10, package.bytes / 200))
                let response = try await Self.download(url, to: archive, session: session) { received in
                    guard throttle.pass(received) else { return }
                    var now = snapshot; now.received = Int(received)
                    Task { await progress(now) }
                }
                guard response.statusCode == 200, response.url?.host == url.host, response.url?.scheme == "https" else {
                    try? fm.removeItem(at: archive)
                    throw SteamClientPackages.Failure.download("Valve's server answered \(response.statusCode) for \(package.name)")
                }
                guard (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                    try? fm.removeItem(at: archive)
                    throw SteamClientPackages.Failure.package("\(package.name) has the wrong size")
                }
            }
            state.received = package.bytes; state.phase = .unpacking
            await progress(state)
            // Mapped, never read whole into memory: the hash and the reader page
            // through the file, and each entry is written out in 1 MB pieces.
            let data = try Data(contentsOf: archive, options: .alwaysMapped)
            guard Self.hash(data) == package.sha256 else {
                try? fm.removeItem(at: archive)
                throw SteamClientPackages.Failure.package("\(package.name) has the wrong SHA-256")
            }
            var written = 0
            do {
                try SteamRuntimeFiles.unpack(data, limits: .client, directory: { name in
                    let key = name.lowercased()
                    let spelled = folders[key] ?? name
                    folders[key] = spelled
                    if made.insert(spelled).inserted {
                        try fm.createDirectory(at: files.appendingPathComponent(spelled), withIntermediateDirectories: true)
                    }
                }) { name, _, read in
                    written += 1
                    if written % 128 == 0 { state.peakFootprintMB = max(state.peakFootprintMB, Self.footprintMB()) }
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
            try Data(SteamClientPackages.marker(version: manifest.version, package).utf8)
                .write(to: doneFolder.appendingPathComponent(package.name), options: .atomic)
            try? fm.removeItem(at: archive)
            state.peakFootprintMB = max(state.peakFootprintMB, Self.footprintMB())
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
        // ml1371: never Madeira Dock's folder.
        let target = SteamClientPackages.target(prefix: prefix)
        let root = target.root, windowsRoot = target.windowsRoot
        let dockRoot = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        guard root.standardizedFileURL.path.lowercased() != dockRoot.standardizedFileURL.path.lowercased() else {
            throw SteamRuntimeFiles.Failure.conflict
        }
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

        // Steam's discovery keys for this folder, only while no session owns the
        // registry and only when Madeira Dock's client is not installed (its keys
        // must keep pointing at Dock's folder; games in a Dock session read them).
        if sessionRunning || wine_process_is_running() != 0 || wineserver_is_running() != 0 {
            state.registry = "left to Steam (a session is running; Steam writes its own keys when it starts)"
        } else if fm.fileExists(atPath: dockRoot.appendingPathComponent("steamclient64.dll").path) {
            state.registry = "left to Steam (Madeira Dock's discovery keys stay on Dock's folder)"
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
        try? fm.removeItem(at: stage)   // complete: nothing to resume
        state.phase = .finished
        state.peakFootprintMB = max(state.peakFootprintMB, Self.footprintMB())
        if kept > 0 { state.registry += "; \(kept) existing user-data files kept" }
        await progress(state)
        return state
    }

    /// What earlier attempts left in the stage's `files/`: relative paths (exact
    /// spelling) and whether each is a folder.
    private static func staged(in files: URL) -> [(String, Bool)] {
        guard let walker = FileManager.default.enumerator(at: files, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let base = files.standardizedFileURL.path + "/"
        var found: [(String, Bool)] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            found.append((String(path.dropFirst(base.count)), (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true))
        }
        return found
    }

    /// The app's phys_footprint (the number jetsam judges), in MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : 0
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
