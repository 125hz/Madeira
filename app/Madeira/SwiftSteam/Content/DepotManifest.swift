import Foundation

/// Represents a parsed Steam depot manifest - lists all files and their chunks
struct DepotManifest {
    let depotID: UInt32
    let manifestGID: UInt64
    let creationTime: UInt32
    var totalUncompressedSize: UInt64
    var totalCompressedSize: UInt64
    var files: [FileEntry] = []

    struct FileEntry {
        let filename: String
        let size: UInt64
        let flags: UInt32
        var chunks: [ChunkEntry]

        var isDirectory: Bool { flags & 0x40 != 0 }

        /// Reconstruct the full file from chunks (ordered by offset)
        var sortedChunks: [ChunkEntry] {
            chunks.sorted { $0.offset < $1.offset }
        }
    }

    struct ChunkEntry {
        let sha: Data           // 20-byte SHA-1 hash (used as chunk ID)
        let crc: UInt32         // Adler-32 checksum of uncompressed data
        let offset: UInt64      // Offset within the file
        let compressedSize: UInt32
        let uncompressedSize: UInt32

        /// Hex string of SHA hash (used in CDN URLs)
        var shaHex: String {
            sha.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Parsing

    /// Parse a depot manifest from binary data. Modern CDN payloads have an
    /// 8-byte binary header before the ContentManifestPayload protobuf, and
    /// filenames may be base64(AES-CBC depot-key) — pass depotKey to decode them.
    static func parse(depotID: UInt32, manifestGID: UInt64, data: Data, depotKey: Data? = nil) throws -> DepotManifest {
        guard data.count >= 4 else {
            throw SteamError.manifestFetchFailed("Manifest data too small")
        }

        // ContentManifestPayload starts with tag 0x0a (field 1, length-delimited).
        // Otherwise the blob is: 8B header (4B magic + 4B payloadLen) + protobuf
        // + a signature trailer — bound the payload by the header's length.
        let payload: Data
        if data.first == 0x0A {
            payload = data
        } else {
            let len = data.count >= 8
                ? Int(data[4..<8].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
                : 0
            let end = (len > 0 && 8 + len <= data.count) ? 8 + len : data.count
            payload = Data(data[8..<end])
        }

        // Check for protobuf-encoded manifest (newer format)
        // The manifest is actually a zip containing a serialized binary
        var manifest = DepotManifest(
            depotID: depotID,
            manifestGID: manifestGID,
            creationTime: 0,
            totalUncompressedSize: 0,
            totalCompressedSize: 0
        )

        // Parse the manifest payload (binary protobuf format)
        try parseManifestPayload(data: Data(payload), manifest: &manifest, depotKey: depotKey)

        return manifest
    }

    /// Parse the manifest's serialized file list
    private static func parseManifestPayload(data: Data, manifest: inout DepotManifest, depotKey: Data?) throws {
        // The manifest is a protobuf message: ContentManifestPayload
        // Field 1 (repeated): ContentManifestPayload.FileMapping
        //   Field 1: filename (string)
        //   Field 2: size (uint64)
        //   Field 3: flags (uint32)
        //   Field 6 (repeated): ContentManifestPayload.FileMapping.ChunkData
        //     Field 1: sha (bytes, 20)
        //     Field 2: crc (fixed32)
        //     Field 3: offset (uint64)
        //     Field 4: cb_compressed (uint32)
        //     Field 5: cb_original (uint32)

        var decoder = ProtobufDecoder(data)
        var totalUncompressed: UInt64 = 0
        var totalCompressed: UInt64 = 0

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: // FileMapping
                let fileData = try decoder.readBytes()
                if let entry = try parseFileEntry(from: fileData, depotKey: depotKey) {
                    totalUncompressed += entry.size
                    for chunk in entry.chunks {
                        totalCompressed += UInt64(chunk.compressedSize)
                    }
                    manifest.files.append(entry)
                }
            default:
                try decoder.skip(wireType: tag.wireType)
            }
        }

        manifest.totalUncompressedSize = totalUncompressed
        manifest.totalCompressedSize = totalCompressed
    }

    /// Encrypted filenames are base64'd AES-256-CBC ciphertext (depot key,
    /// embedded IV). Base64 can legitimately contain '/', so don't guard on
    /// separators — attempt the decode and keep it only if the result is sane.
    private static var filenameDiagLogged = false

    private static func decryptFilename(_ name: String, depotKey: Data?) -> String {
        let stripped = name.filter { !$0.isWhitespace }
        func fail(_ why: String) -> String {
            if !filenameDiagLogged {
                filenameDiagLogged = true
                SteamLog.trace("filename decrypt fail (\(why)): \(name.prefix(24))… keyNil=\(depotKey == nil)")
            }
            return name
        }
        guard let depotKey else { return fail("no key") }
        guard let cipher = Data(base64Encoded: stripped, options: .ignoreUnknownCharacters),
              cipher.count > 16 else { return fail("b64") }
        guard let plain = try? ContentDecryptor.decryptChunk(encryptedData: cipher, depotKey: depotKey) else { return fail("aes") }
        // Plaintext is NUL-padded after PKCS7 unpadding — strip trailing nulls
        var bytes = plain
        while bytes.last == 0 { bytes.removeLast() }
        guard let decoded = String(data: bytes, encoding: .utf8), !decoded.isEmpty else {
            return fail("utf8 \(plain.prefix(16).map { String(format: "%02x", $0) }.joined())")
        }
        guard !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return fail("ctrl") }
        return decoded
    }

    private static func parseFileEntry(from data: Data, depotKey: Data?) throws -> FileEntry? {
        var decoder = ProtobufDecoder(data)
        var filename = ""
        var size: UInt64 = 0
        var flags: UInt32 = 0
        var chunks: [ChunkEntry] = []

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: filename = try decoder.readString()
            case 2: size = try decoder.readVarint()
            case 3: flags = UInt32(try decoder.readVarint())
            case 6: // ChunkData
                let chunkData = try decoder.readBytes()
                if let chunk = try parseChunkEntry(from: chunkData) {
                    chunks.append(chunk)
                }
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        guard !filename.isEmpty else { return nil }

        let decoded = decryptFilename(filename, depotKey: depotKey)
        // Normalize path separators (Steam uses backslashes)
        let normalizedFilename = decoded.replacingOccurrences(of: "\\", with: "/")

        return FileEntry(filename: normalizedFilename, size: size, flags: flags, chunks: chunks)
    }

    private static func parseChunkEntry(from data: Data) throws -> ChunkEntry? {
        var decoder = ProtobufDecoder(data)
        var sha = Data()
        var crc: UInt32 = 0
        var offset: UInt64 = 0
        var compressedSize: UInt32 = 0
        var uncompressedSize: UInt32 = 0

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: sha = try decoder.readBytes()
            case 2: crc = try decoder.readFixed32()
            case 3: offset = try decoder.readVarint()
            case 4: uncompressedSize = UInt32(try decoder.readVarint()) // cb_original
            case 5: compressedSize = UInt32(try decoder.readVarint())   // cb_compressed
            default: try decoder.skip(wireType: tag.wireType)
            }
        }

        guard !sha.isEmpty else { return nil }

        return ChunkEntry(
            sha: sha,
            crc: crc,
            offset: offset,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )
    }
}

// MARK: - Manifest Comparison (for delta updates)

extension DepotManifest {
    /// Compare with another manifest to find changed chunks
    struct ManifestDiff {
        let newChunks: [(file: FileEntry, chunk: ChunkEntry)]       // New/changed chunks to download
        let deletedFiles: [String]                                     // Files to delete
        let unchangedFiles: [String]                                   // Files that haven't changed

        var totalDownloadSize: UInt64 {
            UInt64(newChunks.reduce(0) { $0 + Int($1.chunk.compressedSize) })
        }

        var totalNewFiles: Int {
            Set(newChunks.map { $0.file.filename }).count
        }
    }

    /// Calculate the diff between this manifest and an older one
    func diff(from oldManifest: DepotManifest) -> ManifestDiff {
        // Build lookup of old chunks by SHA
        var oldChunkSHAs = Set<Data>()
        var oldFilenames = Set<String>()
        for file in oldManifest.files {
            oldFilenames.insert(file.filename)
            for chunk in file.chunks {
                oldChunkSHAs.insert(chunk.sha)
            }
        }

        var newChunks: [(file: FileEntry, chunk: ChunkEntry)] = []
        var unchangedFiles: [String] = []
        let newFilenames = Set(files.map { $0.filename })

        for file in files {
            let fileChunks = file.chunks.filter { !oldChunkSHAs.contains($0.sha) }
            if fileChunks.isEmpty {
                unchangedFiles.append(file.filename)
            } else {
                for chunk in fileChunks {
                    newChunks.append((file: file, chunk: chunk))
                }
            }
        }

        let deletedFiles = oldFilenames.subtracting(newFilenames).sorted()

        return ManifestDiff(
            newChunks: newChunks,
            deletedFiles: deletedFiles,
            unchangedFiles: unchangedFiles
        )
    }
}
