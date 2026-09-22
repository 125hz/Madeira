// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation
import CommonCrypto
import Compression
import zlib

/// Handles AES decryption and LZMA decompression of Steam depot chunks
struct ContentDecryptor {

    // MARK: - AES Decryption

    /// Decrypt a depot chunk using AES-256-ECB
    /// Steam uses AES-256-ECB for chunk encryption with a per-depot key
    static func decryptChunk(encryptedData: Data, depotKey: Data) throws -> Data {
        guard depotKey.count == 32 else {
            throw SteamError.decryptionFailed("Invalid depot key size: \(depotKey.count), expected 32")
        }

        // Steam's chunk encryption:
        // First 16 bytes are the IV (used only for first block in a CBC-like manner)
        // Rest is AES-256-ECB encrypted
        guard encryptedData.count > 16 else {
            throw SteamError.decryptionFailed("Encrypted data too small")
        }

        // Steam's scheme (CryptoHelper.SymmetricDecrypt): the first 16 bytes are
        // ECB-decrypted to DERIVE the IV, then the remainder is CBC-decrypted.
        let ivCipher = encryptedData.prefix(16)
        let ciphertext = encryptedData.dropFirst(16)

        var derivedIV = Data(count: 16)
        var ivLen = 0
        let ivStatus = depotKey.withUnsafeBytes { keyPtr in
            ivCipher.withUnsafeBytes { inPtr in
                derivedIV.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress!, depotKey.count, nil,
                            inPtr.baseAddress!, 16, outPtr.baseAddress!, 16, &ivLen)
                }
            }
        }
        guard ivStatus == kCCSuccess, ivLen == 16 else {
            throw SteamError.decryptionFailed("IV derivation failed: \(ivStatus)")
        }

        let outputBufferSize = ciphertext.count + kCCBlockSizeAES128
        var decryptedData = Data(count: outputBufferSize)
        var decryptedLength = 0

        let status = depotKey.withUnsafeBytes { keyPtr in
            derivedIV.withUnsafeBytes { ivPtr in
                ciphertext.withUnsafeBytes { dataPtr in
                    decryptedData.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress!, depotKey.count,
                            ivPtr.baseAddress!,
                            dataPtr.baseAddress!, ciphertext.count,
                            outPtr.baseAddress!, outputBufferSize,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw SteamError.decryptionFailed("AES decryption failed with status: \(status)")
        }

        decryptedData.count = decryptedLength
        return decryptedData
    }

    /// Decrypt a depot content chunk: AES-256-ECB + PKCS7, no IV.
    /// (Chunks are ECB; CBC-with-embedded-IV is for manifest strings/filenames.)
    static func decryptChunkECB(encryptedData: Data, depotKey: Data) throws -> Data {
        guard depotKey.count == 32 else {
            throw SteamError.decryptionFailed("Invalid depot key size: \(depotKey.count), expected 32")
        }
        guard !encryptedData.isEmpty else {
            throw SteamError.decryptionFailed("Encrypted data too small")
        }

        let outputBufferSize = encryptedData.count + kCCBlockSizeAES128
        var decryptedData = Data(count: outputBufferSize)
        var decryptedLength = 0

        let status = depotKey.withUnsafeBytes { keyPtr in
            encryptedData.withUnsafeBytes { dataPtr in
                decryptedData.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyPtr.baseAddress!, depotKey.count,
                        nil,
                        dataPtr.baseAddress!, encryptedData.count,
                        outPtr.baseAddress!, outputBufferSize,
                        &decryptedLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw SteamError.decryptionFailed("AES-ECB decryption failed with status: \(status)")
        }

        decryptedData.count = decryptedLength
        return decryptedData
    }

    // MARK: - LZMA Decompression

    /// Decompress LZMA-compressed chunk data
    /// Steam chunks are LZMA compressed after encryption is removed
    static func decompressChunk(compressedData: Data, expectedSize: Int) throws -> Data {
        // Check for VZstd header: 'V' 'S' 'Z' 'a' — zstd stream + 15B footer
        if compressedData.count > 23, compressedData.prefix(4).elementsEqual([0x56, 0x53, 0x5A, 0x61]) {
            do { return try decompressVZstd(compressedData, expectedSize: expectedSize) }
            catch { throw SteamError.chunkDecodeFailed("vzstd") }
        }

        // Check for VZip header (Steam's custom compression wrapper)
        if compressedData.count >= 2 {
            let header = compressedData.prefix(2)
            if header[0] == 0x56 && header[1] == 0x5A {
                // VZip format - contains LZMA data with Steam header
                do { return try decompressVZip(compressedData, expectedSize: expectedSize) }
                catch { throw SteamError.chunkDecodeFailed("vzip") }
            }
        }

        // ml1320: older content is a single-entry PKZip archive (Valve's
        // reference client falls back to this form). MADEIRA_STEAM_ZIP_CHUNKS=0
        // restores the previous behavior for diagnosis.
        if zipChunksEnabled, compressedData.count >= 30, compressedData.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) {
            guard expectedSize > 0, expectedSize <= maximumChunkBytes else { throw SteamError.chunkDecodeFailed("zip-size") }
            var output = Data(count: expectedSize)
            var produced = 0
            let rc = compressedData.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    chunk_zip_decode(inPtr.bindMemory(to: UInt8.self).baseAddress, compressedData.count,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, expectedSize, &produced)
                }
            }
            guard rc == 0 else { throw SteamError.chunkDecodeFailed("zip\(rc)") }
            output.count = produced
            return output
        }

        // Check for LZMA header (properties byte + dictionary size)
        if compressedData.count > 5 {
            // Try LZMA decompression using Apple's Compression framework
            // with .lzma algorithm
            if let decompressed = decompressLZMA(compressedData, expectedSize: expectedSize) {
                return decompressed
            }
        }

        // Data might not be compressed - return as-is if size matches
        if compressedData.count == expectedSize {
            return compressedData
        }

        // ml1320: name the format (leading bytes are a format tag, not content).
        throw SteamError.chunkDecodeFailed(formatTag(compressedData))
    }

    static let zipChunksEnabled = LibraryFlags.enabled("MADEIRA_STEAM_ZIP_CHUNKS")

    /// Printable form of a chunk's first four bytes, for diagnostics.
    static func formatTag(_ data: Data) -> String {
        data.prefix(4).map { $0 >= 0x30 && $0 <= 0x7A ? String(UnicodeScalar($0)) : String(format: "%02x", $0) }.joined()
    }

    /// Decompress VZip format (Steam's custom wrapper around LZMA).
    /// Layout: 'VZ' + 'a' + crc32(4) | lzmaProps(5) | raw LZMA1 | crc32(4) + size(4) + 'zv'
    /// Madeira: upper bound for one decoded chunk or manifest payload. Steam
    /// chunks are at most 1 MiB; the bound only rejects hostile size fields.
    static let maximumChunkBytes = 64 * 1024 * 1024

    private static func decompressVZip(_ data: Data, expectedSize: Int) throws -> Data {
        guard data.count > 22 else {
            throw SteamError.decompressionFailed
        }

        let props = data[7..<12]
        let compressed = data[12..<(data.count - 10)]
        let size = Int(data[(data.count - 6)..<(data.count - 2)]
            .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        // The footer's size is untrusted; it must agree with the manifest when
        // the manifest supplies one, and it may never request an unbounded buffer.
        guard size > 0, size <= maximumChunkBytes, expectedSize <= 0 || size == expectedSize else {
            throw SteamError.decompressionFailed
        }

        // Raw LZMA1 stream decoded via liblzma shim (props = props byte + dict size)
        var output = Data(count: size)
        var produced = 0
        let ret = props.withUnsafeBytes { propsPtr in
            compressed.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    lzma_shim_decode(propsPtr.baseAddress!, props.count,
                                     inPtr.baseAddress!, compressed.count,
                                     outPtr.baseAddress!, size, &produced)
                }
            }
        }
        guard ret == 0 else {
            throw SteamError.decompressionFailed
        }
        output.count = produced
        return output
    }

    /// Decompress VZstd format: 'VSZa' + crc32(4) | zstd frame | 15B footer
    /// (crc32 + decompressed size + 'zsv')
    private static func decompressVZstd(_ data: Data, expectedSize: Int) throws -> Data {
        let zstdData = data[8..<(data.count - 15)]
        // Madeira: capacity comes from the manifest's cb_original. The
        // educational decoder's frame-size query runs outside the error-safe
        // wrapper and exits the process on a malformed header, so it is not
        // used; an undersized buffer is reported as an error by the wrapper.
        guard expectedSize > 0, expectedSize <= maximumChunkBytes else {
            throw SteamError.decompressionFailed
        }
        let capacity = expectedSize
        var output = Data(count: capacity)
        let produced = zstdData.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                zstd_safe_decompress(outPtr.baseAddress!, capacity,
                                     inPtr.baseAddress!, zstdData.count)
            }
        }
        guard produced != UInt.max else {
            throw SteamError.decompressionFailed
        }
        output.count = produced
        return output
    }

    /// LZMA decompression using Apple's Compression framework
    private static func decompressLZMA(_ data: Data, expectedSize: Int) -> Data? {
        let outputSize = expectedSize > 0 ? expectedSize : data.count * 10  // Estimate
        var outputBuffer = Data(count: outputSize)

        let decompressedSize = data.withUnsafeBytes { srcPtr -> Int in
            outputBuffer.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress,
                      let dst = dstPtr.baseAddress else { return 0 }

                let result = compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), outputSize,
                    src.assumingMemoryBound(to: UInt8.self), data.count,
                    nil,
                    COMPRESSION_LZMA
                )

                return result > 0 ? result : 0
            }
        }

        guard decompressedSize > 0 else { return nil }
        outputBuffer.count = decompressedSize
        return outputBuffer
    }

    // MARK: - Adler-32 Checksum

    /// Validate chunk data using Adler-32 checksum
    static func validateAdler32(data: Data, expected: UInt32) -> Bool {
        let computed = adler32(data)
        return computed == expected
    }

    /// Compute Steam's Adler-32 checksum — same as DepotDownloader's AdlerHash,
    /// which seeds a=0 rather than the standard a=1
    static func adler32(_ data: Data) -> UInt32 {
        // Steam's chunk checksum is Adler-32 seeded with 0 rather than 1.
        // zlib's adler32(0, ...) starts from exactly that state (a=0, b=0).
        // Madeira: replaces a per-byte Swift loop on every downloaded chunk.
        data.withUnsafeBytes { raw -> UInt32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return 0 }
            return UInt32(truncatingIfNeeded: zlib.adler32(0, base, uInt(raw.count)))
        }
    }

    // MARK: - Full Chunk Processing Pipeline

    /// Decrypt, decompress, and validate a chunk
    static func processChunk(
        encryptedData: Data,
        depotKey: Data,
        expectedCRC: UInt32,
        expectedSize: Int
    ) throws -> Data {
        // Step 1: Decrypt (ECB-derived IV + CBC — Steam's SymmetricDecrypt)
        let decrypted = try decryptChunk(encryptedData: encryptedData, depotKey: depotKey)

        // Step 2: Decompress
        let decompressed = try decompressChunk(compressedData: decrypted, expectedSize: expectedSize)

        // Step 3: Validate checksum
        if expectedCRC != 0 {
            guard validateAdler32(data: decompressed, expected: expectedCRC) else {
                throw SteamError.checksumMismatch
            }
        }

        return decompressed
    }
}
