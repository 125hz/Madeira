// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation
import Security
import CommonCrypto

/// Steam protocol cryptography: RSA key exchange and AES-256 symmetric encryption.
/// Matches SteamKit2/JavaSteam wire format for ChannelEncrypt handshake and message encryption.
enum SteamCrypto {

    // MARK: - Valve's RSA Public Key (Universe Public, 1024-bit)
    // Source: SteamKit2 KeyDictionary / JavaSteam KeyDictionary
    // X.509 SubjectPublicKeyInfo DER encoding

    private static let valvePublicKeyDER: [UInt8] = [
        0x30, 0x81, 0x9D, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00, 0x03, 0x81, 0x8B, 0x00, 0x30, 0x81, 0x87, 0x02, 0x81, 0x81, 0x00, 0xDF, 0xEC, 0x1A,
        0xD6, 0x2C, 0x10, 0x66, 0x2C, 0x17, 0x35, 0x3A, 0x14, 0xB0, 0x7C, 0x59, 0x11, 0x7F, 0x9D, 0xD3,
        0xD8, 0x2B, 0x7A, 0xE3, 0xE0, 0x15, 0xCD, 0x19, 0x1E, 0x46, 0xE8, 0x7B, 0x87, 0x74, 0xA2, 0x18,
        0x46, 0x31, 0xA9, 0x03, 0x14, 0x79, 0x82, 0x8E, 0xE9, 0x45, 0xA2, 0x49, 0x12, 0xA9, 0x23, 0x68,
        0x73, 0x89, 0xCF, 0x69, 0xA1, 0xB1, 0x61, 0x46, 0xBD, 0xC1, 0xBE, 0xBF, 0xD6, 0x01, 0x1B, 0xD8,
        0x81, 0xD4, 0xDC, 0x90, 0xFB, 0xFE, 0x4F, 0x52, 0x73, 0x66, 0xCB, 0x95, 0x70, 0xD7, 0xC5, 0x8E,
        0xBA, 0x1C, 0x7A, 0x33, 0x75, 0xA1, 0x62, 0x34, 0x46, 0xBB, 0x60, 0xB7, 0x80, 0x68, 0xFA, 0x13,
        0xA7, 0x7A, 0x8A, 0x37, 0x4B, 0x9E, 0xC6, 0xF4, 0x5D, 0x5F, 0x3A, 0x99, 0xF9, 0x9E, 0xC4, 0x3A,
        0xE9, 0x63, 0xA2, 0xBB, 0x88, 0x19, 0x28, 0xE0, 0xE7, 0x14, 0xC0, 0x42, 0x89, 0x02, 0x01, 0x11,
    ]

    // MARK: - Random

    /// Generate cryptographically random bytes
    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return bytes
    }

    // MARK: - RSA

    /// RSA-encrypt data using Valve's public key (OAEP SHA-1 padding).
    /// Used for ChannelEncrypt handshake to securely send the session key.
    static func rsaEncrypt(_ plaintext: Data) throws -> Data {
        let keyData = Data(valvePublicKeyDER)

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw SteamError.cryptoError("Failed to create RSA key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        guard let encrypted = SecKeyCreateEncryptedData(secKey, .rsaEncryptionOAEPSHA1, plaintext as CFData, &error) else {
            throw SteamError.cryptoError("RSA encrypt failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        return encrypted as Data
    }

    // MARK: - HMAC-SHA1

    /// HMAC-SHA1 of data using the given key (CommonCrypto CCHmac)
    private static func hmacSHA1(_ data: Data, key: Data) -> Data {
        var result = Data(count: Int(CC_SHA1_DIGEST_LENGTH))  // 20 bytes
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                result.withUnsafeMutableBytes { resultPtr in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyPtr.baseAddress!, key.count,
                        dataPtr.baseAddress!, data.count,
                        resultPtr.baseAddress!
                    )
                }
            }
        }
        return result
    }

    // MARK: - AES-256 Symmetric Encryption (HMAC-IV, matches SteamKit2 NetFilterEncryptionWithHMAC)

    /// Encrypt data matching SteamKit2's NetFilterEncryptionWithHMAC format.
    ///
    /// IV construction (16 bytes):
    ///   - Bytes 0–12: first 13 bytes of HMAC-SHA1(rand3 + plaintext, key[0..15])
    ///   - Bytes 13–15: 3 random bytes (the HMAC seed)
    ///
    /// Wire format: [AES-256-ECB(IV)] + [AES-256-CBC-PKCS7(plaintext, IV)]
    ///
    /// The server validates the HMAC on decryption — a plain random IV will fail
    /// HMAC validation and be silently dropped.
    static func symmetricEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw SteamError.cryptoError("Session key must be 32 bytes")
        }

        // 1. Generate 3 random bytes as the HMAC seed
        let rand3 = randomBytes(3)

        // 2. HMAC key is the first 16 bytes of the session key
        let hmacKey = Data(key.prefix(16))

        // 3. HMAC-SHA1(rand3 + plaintext) — covers both seed and content
        let hmac = hmacSHA1(rand3 + plaintext, key: hmacKey)

        // 4. Build the 16-byte plaintext IV: [13 HMAC bytes] + [3 random bytes]
        let iv = Data(hmac.prefix(13)) + rand3

        // 5. Encrypt the IV with AES-256-ECB (hides the HMAC-derived IV)
        let encryptedIV = try aesECBEncrypt(iv, key: key)

        // 6. Encrypt the data with AES-256-CBC using the plaintext IV
        let encryptedData = try aesCBCEncrypt(plaintext, key: key, iv: iv)

        return encryptedIV + encryptedData
    }

    /// Decrypt data matching SteamKit2's NetFilterEncryptionWithHMAC format.
    static func symmetricDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw SteamError.cryptoError("Session key must be 32 bytes")
        }
        guard ciphertext.count >= 32 else {
            throw SteamError.cryptoError("Ciphertext too short for symmetric decrypt")
        }

        // 1. Decrypt the first 16 bytes with AES-256-ECB to recover the plaintext IV
        let iv = try aesECBDecrypt(Data(ciphertext.prefix(16)), key: key)

        // 2. Decrypt the rest with AES-256-CBC using the recovered IV
        let plaintext = try aesCBCDecrypt(Data(ciphertext.dropFirst(16)), key: key, iv: iv)

        // 3. Validate HMAC: iv[13..15] = rand3 seed; HMAC-SHA1(rand3 + plaintext, key[0..15])
        //    first 13 bytes must match iv[0..12]
        let rand3 = Data(iv.suffix(3))
        let expectedHmac = hmacSHA1(rand3 + plaintext, key: Data(key.prefix(16)))
        guard expectedHmac.prefix(13).elementsEqual(iv.prefix(13)) else {
            throw SteamError.cryptoError("HMAC validation failed — wrong session key or corrupted message")
        }

        return plaintext
    }

    // MARK: - AES Primitives

    /// AES-256-ECB encrypt a single 16-byte block (no padding)
    private static func aesECBEncrypt(_ data: Data, key: Data) throws -> Data {
        try aesCrypt(data, key: key, iv: nil, operation: CCOperation(kCCEncrypt),
                     mode: CCMode(kCCModeECB), padding: CCPadding(ccNoPadding))
    }

    /// AES-256-ECB decrypt a single 16-byte block (no padding)
    private static func aesECBDecrypt(_ data: Data, key: Data) throws -> Data {
        try aesCrypt(data, key: key, iv: nil, operation: CCOperation(kCCDecrypt),
                     mode: CCMode(kCCModeECB), padding: CCPadding(ccNoPadding))
    }

    /// AES-256-CBC encrypt with PKCS7 padding
    private static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try aesCrypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt),
                     mode: CCMode(kCCModeCBC), padding: CCPadding(ccPKCS7Padding))
    }

    /// AES-256-CBC decrypt with PKCS7 padding
    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try aesCrypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt),
                     mode: CCMode(kCCModeCBC), padding: CCPadding(ccPKCS7Padding))
    }

    /// Generic CommonCrypto AES operation
    private static func aesCrypt(
        _ data: Data, key: Data, iv: Data?,
        operation: CCOperation, mode: CCMode, padding: CCPadding
    ) throws -> Data {
        var cryptorRef: CCCryptorRef?
        var status = key.withUnsafeBytes { keyPtr in
            let ivPtr = iv.map { iv in iv.withUnsafeBytes { $0.baseAddress } } ?? nil
            // Use the iv parameter properly
            if let iv = iv {
                return iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreateWithMode(
                        operation, mode, CCAlgorithm(kCCAlgorithmAES),
                        padding,
                        ivBytes.baseAddress,
                        keyPtr.baseAddress!, key.count,
                        nil, 0, 0, 0,
                        &cryptorRef
                    )
                }
            } else {
                return CCCryptorCreateWithMode(
                    operation, mode, CCAlgorithm(kCCAlgorithmAES),
                    padding,
                    nil,
                    keyPtr.baseAddress!, key.count,
                    nil, 0, 0, 0,
                    &cryptorRef
                )
            }
        }

        guard status == kCCSuccess, let cryptor = cryptorRef else {
            throw SteamError.cryptoError("CCCryptorCreate failed: \(status)")
        }
        defer { CCCryptorRelease(cryptor) }

        let outputSize = CCCryptorGetOutputLength(cryptor, data.count, true)
        var output = Data(count: outputSize)
        var dataOutMoved = 0
        var totalMoved = 0

        status = data.withUnsafeBytes { dataPtr in
            output.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(
                    cryptor,
                    dataPtr.baseAddress!, data.count,
                    outPtr.baseAddress!, outputSize,
                    &dataOutMoved
                )
            }
        }
        guard status == kCCSuccess else {
            throw SteamError.cryptoError("CCCryptorUpdate failed: \(status)")
        }
        totalMoved += dataOutMoved

        status = output.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(
                cryptor,
                outPtr.baseAddress!.advanced(by: totalMoved),
                outputSize - totalMoved,
                &dataOutMoved
            )
        }
        guard status == kCCSuccess else {
            throw SteamError.cryptoError("CCCryptorFinal failed: \(status)")
        }
        totalMoved += dataOutMoved

        output.count = totalMoved
        return output
    }

    // MARK: - CRC32

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }
}
