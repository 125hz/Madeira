import Foundation
import zlib
import CommonCrypto

/// Progress for one application install, across all of its depots.
struct SteamDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, downloading, finishing }
    var phase: Phase = .preparing
    /// Compressed bytes to fetch for the whole install (all selected depots).
    var totalBytes: UInt64 = 0
    /// Compressed bytes already on disk, including chunks resumed from a
    /// previous attempt.
    var doneBytes: UInt64 = 0
    var bytesPerSecond: Double = 0

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

/// Orchestrates downloading an owned application's Windows depots from the
/// Steam content network into a Steam library folder.
///
/// Native Swift port of the DepotDownloader flow. Ownership is enforced by
/// Steam: depot keys and manifest request codes are only issued to an
/// account that owns the depot. Nothing here alters the downloaded files.
///
/// Madeira changes from the original port:
/// - All manifests are fetched first, so progress covers the whole install.
/// - Completed chunks are journaled per depot manifest; a cancelled, failed or
///   interrupted install resumes without re-fetching them.
/// - Files are sized to their manifest length, so an update that shrinks a
///   file cannot leave stale trailing bytes.
/// - Chunk writes happen on the download tasks with pwrite, never on the
///   main actor; a dedicated URLSession keeps chunks out of the URL cache.
/// - Manifest paths are validated to stay inside the install folder, and
///   directory names are folded case-insensitively (Windows semantics on a
///   case-sensitive iOS volume).
/// - Each chunk retries on other content servers before the install fails.
@MainActor
final class DepotDownloader {
    private let session: SteamSession
    private var depotKeys: [UInt32: Data] = [:]
    private var cdnAuthTokens: [String: String] = [:]  // "depot|host" -> "?auth=…" fragment
    private let maxConcurrentChunks = 8
    private let attemptsPerChunk = 4

    private nonisolated static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    init(session: SteamSession) {
        self.session = session
    }

    // MARK: - Public API

    /// Download an app into `steamApps/common/<installdir>` and write its
    /// appmanifest. Returns the install folder. Throws CancellationError when
    /// the calling task is cancelled; completed chunks stay journaled.
    func install(_ app: SteamAppInfo, steamApps: URL,
                 progress report: @escaping (SteamDownloadProgress) -> Void) async throws -> URL {
        let depots = app.installDepots()
        guard !depots.isEmpty else { throw SteamError.depotNotFound(app.appID) }

        let folderName = Self.safeFolderName(app.installDir.isEmpty ? "app_\(app.appID)" : app.installDir)
        let installURL = steamApps.appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        let journalDir = steamApps.appendingPathComponent("downloading", isDirectory: true)
            .appendingPathComponent("\(app.appID)", isDirectory: true)
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        var state = SteamDownloadProgress()
        report(state)

        let hosts = try await contentServers()
        guard !hosts.isEmpty else { throw SteamError.chunkDownloadFailed("No content servers are available.") }

        // 1. Keys, manifests and per-host authorization for every depot.
        var plans: [DepotPlan] = []
        for depot in depots {
            try Task.checkCancellation()
            guard let gid = depot.publicManifestID else { continue }
            let key = try await depotKey(depotID: depot.depotID, appID: app.appID)
            let manifest = try await fetchManifest(depotID: depot.depotID, appID: app.appID,
                                                   manifestGID: gid, key: key, hosts: hosts)
            var auth: [String: String] = [:]
            for host in hosts.prefix(attemptsPerChunk) {
                auth[host] = await cdnAuthFragment(depotID: depot.depotID, appID: app.appID, host: host)
            }
            plans.append(DepotPlan(depotID: depot.depotID, manifestGID: gid, key: key, manifest: manifest,
                                   hosts: Array(hosts.prefix(attemptsPerChunk)), auth: auth,
                                   declaredSize: depot.publicSizeBytes))
        }
        guard !plans.isEmpty else { throw SteamError.depotNotFound(app.appID) }

        // 2. Prepare files and load journals off the main actor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(plans: plans, installURL: installURL, journalDir: journalDir)
        }.value
        state.totalBytes = prepared.totalBytes
        state.doneBytes = prepared.doneBytes
        state.phase = .downloading
        report(state)
        SteamLog.event("[steam-depot] ml1310 install begin app=\(app.appID) depots=\(plans.count) files=\(prepared.fileCount) resume=\(prepared.doneBytes > 0 ? 1 : 0)")

        let remaining = prepared.remainingUncompressed
        if remaining > 0 {
            let values = try? installURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? Int64.max))
            if available < remaining { throw SteamError.insufficientDiskSpace(needed: remaining, available: available) }
        }

        // 3. Chunks.
        let started = Date()
        let resumedBytes = state.doneBytes
        var lastReport = Date.distantPast
        for (index, plan) in plans.enumerated() {
            let journal = try JournalWriter(url: prepared.journals[index])
            defer { journal.close() }
            let work = prepared.pending[index]
            let paths = prepared.paths[index]
            let existing = prepared.existing[index]
            let maximum = maxConcurrentChunks, attempts = attemptsPerChunk
            try await withThrowingTaskGroup(of: (UInt64, UInt64).self) { group in
                var next = 0
                func enqueue() {
                    guard next < work.count else { return }
                    let item = work[next]; next += 1
                    let chunk = plan.manifest.files[item.file].chunks[item.chunk]
                    let path = paths[item.file]
                    let verify = existing[item.file]
                    group.addTask {
                        if verify, Self.chunkAlreadyPresent(chunk, path: path) { return (item.key, UInt64(chunk.compressedSize)) }
                        try await Self.fetchChunk(chunk, plan: plan, path: path, attempts: attempts)
                        return (item.key, UInt64(chunk.compressedSize))
                    }
                }
                for _ in 0..<min(maximum, work.count) { enqueue() }
                for try await (key, bytes) in group {
                    journal.append(key)
                    state.doneBytes += bytes
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        let elapsed = now.timeIntervalSince(started)
                        if elapsed > 1 { state.bytesPerSecond = Double(state.doneBytes - resumedBytes) / elapsed }
                        report(state)
                    }
                    enqueue()
                }
            }
        }

        // 4. Install record. Sizes come from the manifests; no tree walk.
        state.phase = .finishing
        report(state)
        let installed = plans.map { plan in
            AppManifestWriter.InstalledDepot(depotID: Int(plan.depotID), manifestGID: plan.manifestGID,
                                             size: Int64(plan.manifest.totalUncompressedSize))
        }
        try AppManifestWriter.writeManifest(
            appID: app.appID, name: app.name, installDir: folderName, buildID: app.buildID,
            steamID: session.steamID, sizeOnDisk: prepared.totalUncompressed,
            steamAppsPath: steamApps.path, installedDepots: installed)
        try? FileManager.default.removeItem(at: journalDir)
        SteamLog.event("[steam-depot] ml1310 install complete app=\(app.appID) bytes=\(prepared.totalUncompressed) seconds=\(Int(Date().timeIntervalSince(started)))")
        return installURL
    }

    /// Whether a previous attempt left resumable progress for this app.
    static func hasPartialDownload(appID: UInt32, steamApps: URL) -> Bool {
        let dir = steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".journal") }
    }

    // MARK: - Plan

    struct DepotPlan: Sendable {
        let depotID: UInt32
        let manifestGID: UInt64
        let key: Data
        let manifest: DepotManifest
        let hosts: [String]
        let auth: [String: String]
        let declaredSize: UInt64
    }

    struct WorkItem: Sendable {
        let file: Int
        let chunk: Int
        var key: UInt64 { UInt64(file) << 32 | UInt64(chunk) }
    }

    struct Prepared: Sendable {
        var paths: [[String]] = []       // per depot, per file: absolute path ("" = skipped)
        var existing: [[Bool]] = []      // per depot, per file: had content before this install
        var pending: [[WorkItem]] = []   // per depot: chunks still to fetch
        var journals: [URL] = []
        var totalBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        var totalUncompressed: UInt64 = 0
        var remainingUncompressed: UInt64 = 0
        var fileCount = 0
    }

    private nonisolated static func prepare(plans: [DepotPlan], installURL: URL, journalDir: URL) throws -> Prepared {
        let fm = FileManager.default
        var result = Prepared()
        var folded: [String: String] = [:]   // lowercased relative dir -> first spelling
        let journalNames = Set(plans.map { "depot_\($0.depotID)_\($0.manifestGID).journal" })
        // A journal for an older manifest describes different file contents.
        for name in (try? fm.contentsOfDirectory(atPath: journalDir.path)) ?? [] where !journalNames.contains(name) {
            try? fm.removeItem(at: journalDir.appendingPathComponent(name))
        }
        for plan in plans {
            try Task.checkCancellation()
            let journalURL = journalDir.appendingPathComponent("depot_\(plan.depotID)_\(plan.manifestGID).journal")
            let done = JournalWriter.load(journalURL)
            var paths: [String] = []
            var existing: [Bool] = []
            var pending: [WorkItem] = []
            paths.reserveCapacity(plan.manifest.files.count)
            for (fileIndex, file) in plan.manifest.files.enumerated() {
                // Symlinks (flag 0x200) have no Windows meaning here; skip them.
                guard file.flags & 0x200 == 0,
                      let relative = safeRelativePath(file.filename, folded: &folded) else {
                    if file.flags & 0x200 == 0 { SteamLog.trace("rejected manifest path in depot \(plan.depotID)") }
                    paths.append(""); existing.append(false); continue
                }
                let url = installURL.appendingPathComponent(relative)
                if file.isDirectory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    paths.append(""); existing.append(false); continue
                }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var before = stat()
                let hadContent = stat(url.path, &before) == 0 && before.st_size > 0
                existing.append(hadContent)
                try sizeFile(url.path, to: file.size)
                paths.append(url.path)
                result.fileCount += 1
                result.totalUncompressed += file.size
                var pendingBytes: UInt64 = 0
                for (chunkIndex, chunk) in file.chunks.enumerated() {
                    let item = WorkItem(file: fileIndex, chunk: chunkIndex)
                    result.totalBytes += UInt64(chunk.compressedSize)
                    if done.contains(item.key) {
                        result.doneBytes += UInt64(chunk.compressedSize)
                    } else {
                        pending.append(item)
                        pendingBytes += UInt64(chunk.uncompressedSize)
                    }
                }
                // Space already allocated to an existing file is reused; only
                // its growth needs new space (sparse new files need all of it).
                let beforeSize = hadContent ? UInt64(before.st_size) : 0
                result.remainingUncompressed += hadContent
                    ? (file.size > beforeSize ? file.size - beforeSize : 0) : pendingBytes
            }
            result.paths.append(paths)
            result.existing.append(existing)
            result.pending.append(pending)
            result.journals.append(journalURL)
        }
        return result
    }

    /// Create or resize a file to its manifest length. Existing bytes below
    /// that length are kept so resumed and updated installs reuse them.
    private nonisolated static func sizeFile(_ path: String, to size: UInt64) throws {
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamError.chunkDownloadFailed("Cannot create a game file (errno \(errno)).") }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, UInt64(info.st_size) == size { return }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot size a game file (errno \(errno)).")
        }
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    // MARK: - Chunks

    /// A chunk's ID is the SHA-1 of its uncompressed bytes. When a file
    /// already had content (an update, or a resume without a journal), bytes
    /// that already match are kept instead of downloaded again.
    private nonisolated static func chunkAlreadyPresent(_ chunk: DepotManifest.ChunkEntry, path: String) -> Bool {
        let length = Int(chunk.uncompressedSize)
        guard chunk.sha.count == Int(CC_SHA1_DIGEST_LENGTH), length > 0,
              length <= ContentDecryptor.maximumChunkBytes else { return false }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(chunk.offset)) }
        guard read == length else { return false }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = CC_SHA1(buffer, CC_LONG(length), &digest)
        return Data(digest) == chunk.sha
    }

    private nonisolated static func fetchChunk(_ chunk: DepotManifest.ChunkEntry, plan: DepotPlan,
                                               path: String, attempts: Int) async throws {
        var lastError: Error = SteamError.chunkDownloadFailed("No content server responded.")
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            let host = plan.hosts[attempt % plan.hosts.count]
            let url = "\(host)/depot/\(plan.depotID)/chunk/\(chunk.shaHex)\(plan.auth[host] ?? "")"
            do {
                let encrypted = try await download(url)
                let data = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: plan.key,
                                                             expectedCRC: chunk.crc,
                                                             expectedSize: Int(chunk.uncompressedSize))
                guard data.count == Int(chunk.uncompressedSize) else { throw SteamError.checksumMismatch }
                try write(data, to: path, offset: chunk.offset)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                SteamLog.trace("chunk attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000) }
            }
        }
        throw lastError
    }

    private nonisolated static func write(_ data: Data, to path: String, offset: UInt64) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { throw SteamError.chunkDownloadFailed("Cannot open a game file (errno \(errno)).") }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                guard n > 0 else { throw SteamError.chunkDownloadFailed("Cannot write a game file (errno \(errno)).") }
                written += n
            }
        }
    }

    private nonisolated static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SteamError.chunkDownloadFailed("Invalid content URL.") }
        let (data, response) = try await http.data(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw SteamError.chunkDownloadFailed("Content server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    // MARK: - Manifest

    private func fetchManifest(depotID: UInt32, appID: UInt32, manifestGID: UInt64,
                               key: Data, hosts: [String]) async throws -> DepotManifest {
        let requestCode = try await manifestRequestCode(depotID: depotID, appID: appID, manifestGID: manifestGID)
        var lastError: Error = SteamError.manifestFetchFailed("No content server returned the manifest.")
        for host in hosts.prefix(6) {
            try Task.checkCancellation()
            let auth = await cdnAuthFragment(depotID: depotID, appID: appID, host: host)
            let code = requestCode == 0 ? "" : "/\(requestCode)"
            do {
                let raw = try await Self.download("\(host)/depot/\(depotID)/manifest/\(manifestGID)/5\(code)\(auth)")
                return try await Task.detached(priority: .userInitiated) {
                    try Self.parseManifest(raw, depotID: depotID, manifestGID: manifestGID, key: key)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                SteamLog.trace("manifest from a content server failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private nonisolated static func parseManifest(_ raw: Data, depotID: UInt32, manifestGID: UInt64, key: Data) throws -> DepotManifest {
        // Content servers deliver the manifest as a single-entry ZIP.
        let payload = raw.starts(with: [0x50, 0x4B]) ? try unzipSingleFile(raw) : raw
        if let plain = try? DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: payload, depotKey: key),
           !plain.files.isEmpty {
            return plain
        }
        // Older depots encrypt the whole manifest with the depot key.
        let decrypted = try ContentDecryptor.decryptChunk(encryptedData: payload, depotKey: key)
        let inflated = (try? ContentDecryptor.decompressChunk(compressedData: decrypted, expectedSize: 0)) ?? decrypted
        return try DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: inflated, depotKey: key)
    }

    /// Extract the single deflated entry from a manifest ZIP. No zip lib needed —
    /// parse the local file header and inflate the raw deflate stream.
    nonisolated static func unzipSingleFile(_ data: Data) throws -> Data {
        let data = Data(data)  // zero-based indices
        guard data.count > 30,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw SteamError.manifestFetchFailed("Not a zip")
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24 }
        let method = u16(8)
        let compSize = u32(18)
        let uncompSize = u32(22)
        let nameLen = u16(26), extraLen = u16(28)
        let start = 30 + nameLen + extraLen
        guard start + compSize <= data.count, method == 0 || method == 8,
              uncompSize <= ContentDecryptor.maximumChunkBytes * 4 else {
            throw SteamError.manifestFetchFailed("Bad zip entry (method \(method))")
        }
        let entry = data.subdata(in: start..<(start + compSize))
        if method == 0 { return entry }

        // Zip stores raw deflate — inflate with zlib, negative windowBits
        var strm = z_stream()
        let cap = max(uncompSize, 1024)
        var out = Data(count: cap)
        var n = -1
        entry.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                strm.avail_in = UInt32(entry.count)
                strm.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                strm.avail_out = UInt32(cap)
                guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                let r = inflate(&strm, Z_FINISH)
                inflateEnd(&strm)
                if r == Z_STREAM_END { n = Int(strm.total_out) }
            }
        }
        guard n >= 0 else { throw SteamError.decompressionFailed }
        out.count = n
        return out
    }

    // MARK: - Depot Key

    private func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        if let cached = depotKeys[depotID] { return cached }
        try await session.ensureConnected()

        var request = CMsgClientGetDepotDecryptionKey()
        request.depotID = depotID
        request.appID = appID

        let response = try await session.sendAndWait(
            eMsg: .clientGetDepotDecryptionKey,
            body: request.serialize(),
            responseEMsg: .clientGetDepotDecryptionKeyResponse,
            timeout: 15
        )

        let keyResponse = try CMsgClientGetDepotDecryptionKeyResponse.deserialize(from: response.body)
        // Steam only issues keys for depots this account owns.
        guard EResult(rawValue: UInt32(keyResponse.eresult))?.isSuccess == true,
              keyResponse.depotEncryptionKey.count == 32 else {
            throw SteamError.depotKeyNotFound(depotID)
        }

        depotKeys[depotID] = keyResponse.depotEncryptionKey
        return keyResponse.depotEncryptionKey
    }

    // MARK: - Manifest Request Code

    private func manifestRequestCode(depotID: UInt32, appID: UInt32, manifestGID: UInt64) async throws -> UInt64 {
        try await session.ensureConnected()
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: appID)
        encoder.writeUInt32(fieldNumber: 2, value: depotID)
        encoder.writeUInt64(fieldNumber: 3, value: manifestGID)

        let responseData = try await session.callServiceMethod(
            method: .getManifestRequestCode,
            body: encoder.data,
            timeout: 15
        )

        var decoder = ProtobufDecoder(responseData)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1 {
                // manifest_request_code is fixed64 on the wire
                return tag.wireType == .fixed64 ? try decoder.readFixed64() : try decoder.readVarint()
            }
            try decoder.skip(wireType: tag.wireType)
        }

        return 0 // No request code needed (older depots)
    }

    // MARK: - CDN Discovery + Auth

    /// Content server discovery via the public Web API
    /// (IContentServerDirectoryService/GetServersForSteamPipe). No account
    /// token is attached; the directory does not require one.
    private func contentServers() async throws -> [String] {
        var hosts: [String] = []
        do {
            guard let url = URL(string: "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=\(session.cellID)&max_servers=20") else {
                throw SteamError.chunkDownloadFailed("Bad content directory URL")
            }
            let (data, response) = try await Self.http.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SteamError.chunkDownloadFailed("Content directory HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = json["response"] as? [String: Any],
                  let servers = resp["servers"] as? [[String: Any]] else {
                throw SteamError.chunkDownloadFailed("Content directory returned unexpected data")
            }
            // Prefer servers without a load-shedding flag, in the directory's order.
            for server in servers {
                let host = (server["vhost"] as? String) ?? (server["host"] as? String) ?? ""
                guard Self.usableContentHost(host) else { continue }
                let entry = "https://\(host)"
                if !hosts.contains(entry) { hosts.append(entry) }
            }
            SteamLog.trace("content servers offered=\(servers.count) usable=\(hosts.count)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SteamLog.trace("content directory failed: \(error.localizedDescription)")
        }
        let fallback = "https://steampipe.akamaized.net"
        if !hosts.contains(fallback) { hosts.append(fallback) }
        return hosts
    }

    nonisolated static func usableContentHost(_ host: String) -> Bool {
        guard host.contains("."), !host.contains(" "), !host.contains("/"), !host.contains("*"),
              !host.contains("lancache"), !host.contains(":") else { return false }
        return host.hasSuffix(".steamcontent.com") || host.hasSuffix(".akamaized.net") ||
            host.hasSuffix(".steampipe.steamcontent.com") || host.hasSuffix(".steamstatic.com")
    }

    /// Unified-service GetCDNAuthToken → "?auth=…" query fragment for this
    /// depot on this host. An empty token is normal outside regional edge
    /// networks. Cached per depot and host.
    private func cdnAuthFragment(depotID: UInt32, appID: UInt32, host: String) async -> String {
        let cacheKey = "\(depotID)|\(host)"
        if let cached = cdnAuthTokens[cacheKey] { return cached }

        // host_name must be the bare hostname, not the https:// URL
        let bareHost = URL(string: host)?.host ?? host

        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)  // depot_id = 1
        encoder.writeString(fieldNumber: 2, value: bareHost) // host_name = 2
        encoder.writeUInt32(fieldNumber: 3, value: appID)    // app_id = 3

        do {
            try await session.ensureConnected()
            let responseData = try await session.callServiceMethod(
                method: .getCDNAuthToken,
                body: encoder.data,
                timeout: 10
            )
            var decoder = ProtobufDecoder(responseData)
            var token = ""
            while let tag = try decoder.readTag() {
                if tag.fieldNumber == 1 { token = try decoder.readString() } else { try decoder.skip(wireType: tag.wireType) }
            }
            let fragment = token.isEmpty ? "" : (token.hasPrefix("?") || token.hasPrefix("&") ? token : "?auth=\(token)")
            cdnAuthTokens[cacheKey] = fragment
            return fragment
        } catch {
            SteamLog.trace("content authorization request failed; continuing without a token")
            cdnAuthTokens[cacheKey] = ""
            return ""
        }
    }
}

/// Append-only record of completed chunks for one depot manifest. Lines are
/// hexadecimal work-item keys. A lost tail only causes those chunks to be
/// fetched again.
final class JournalWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: url)
        // A previous attempt killed mid-write can leave a partial last line;
        // start on a fresh line so the first new key is not glued onto it.
        let end = handle.seekToEndOfFile()
        if end > 0 {
            handle.seek(toFileOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { buffer = "\n" }
            handle.seekToEndOfFile()
        }
    }

    func append(_ key: UInt64) {
        buffer += String(key, radix: 16) + "\n"
        pending += 1
        if pending >= 64 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""; pending = 0
    }

    func close() {
        flush()
        try? handle.close()
    }

    static func load(_ url: URL) -> Set<UInt64> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var keys = Set<UInt64>()
        for line in text.split(separator: "\n") { if let key = UInt64(line, radix: 16) { keys.insert(key) } }
        return keys
    }
}
