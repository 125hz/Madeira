// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Only the
// protobuf helpers and the IAuthenticationService messages that sign-in uses
// are here. Field numbers are Valve's, from the public
// steammessages_auth.steamclient.proto definitions.

import Foundation

// MARK: - Steam Protobuf Message Stubs
//
// These are hand-written Swift structs that mirror the essential Steam protobuf messages.
// They implement manual protobuf encoding/decoding (field tag + wire type + value)
// without requiring the swift-protobuf dependency.
//
// Wire types: 0=varint, 1=64-bit, 2=length-delimited, 5=32-bit

// MARK: - Protobuf Encoding Helpers

enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtobufEncoder {
    private(set) var data = Data()

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeTag(fieldNumber: UInt32, wireType: ProtoWireType) {
        writeVarint(UInt64(fieldNumber << 3 | UInt32(wireType.rawValue)))
    }

    mutating func writeString(fieldNumber: UInt32, value: String) {
        guard !value.isEmpty else { return }
        let bytes = Data(value.utf8)
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeBytes(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeUInt32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeUInt64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(value))
    }

    mutating func writeInt32(fieldNumber: UInt32, value: Int32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func writeInt64(fieldNumber: UInt32, value: Int64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(UInt64(bitPattern: value))
    }

    mutating func writeBool(fieldNumber: UInt32, value: Bool) {
        guard value else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(1)
    }

    mutating func writeFixed32(fieldNumber: UInt32, value: UInt32) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed32)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    mutating func writeFixed64(fieldNumber: UInt32, value: UInt64) {
        guard value != 0 else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    mutating func writeSubmessage(fieldNumber: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }
}

struct ProtobufDecoder {
    let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw SteamError.protobufError("Varint too long")
            }
        }
        throw SteamError.protobufError("Unexpected end of data reading varint")
    }

    mutating func readTag() throws -> (fieldNumber: UInt32, wireType: ProtoWireType)? {
        guard !isAtEnd else { return nil }
        let tag = try readVarint()
        let wireTypeRaw = UInt8(tag & 0x7)
        guard let wireType = ProtoWireType(rawValue: wireTypeRaw) else {
            throw SteamError.protobufError("Unknown wire type: \(wireTypeRaw)")
        }
        return (fieldNumber: UInt32(tag >> 3), wireType: wireType)
    }

    /// A length prefix, checked against the bytes that remain. Lengths come
    /// from the network, so an oversized value must throw, not trap.
    mutating func readLength() throws -> Int {
        let length = try readVarint()
        guard length <= UInt64(data.count - offset) else {
            throw SteamError.protobufError("Length past end of data")
        }
        return Int(length)
    }

    mutating func readBytes() throws -> Data {
        let length = try readLength()
        guard offset + length <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading bytes")
        }
        let bytes = data[offset..<offset + length]
        offset += length
        return Data(bytes)
    }

    mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw SteamError.protobufError("Invalid UTF-8 string")
        }
        return str
    }

    mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed32")
        }
        let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw SteamError.protobufError("Unexpected end of data reading fixed64")
        }
        let value = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func skip(wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            offset += 8
        case .lengthDelimited:
            offset += try readLength()
        case .fixed32:
            offset += 4
        }
        guard offset <= data.count else {
            throw SteamError.protobufError("Skip went past end of data")
        }
    }
}

// MARK: - Authentication Messages

/// Request RSA public key for password encryption
struct CAuthentication_GetPasswordRSAPublicKey_Request {
    var accountName: String = ""

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: accountName)
        return encoder.data
    }
}

struct CAuthentication_GetPasswordRSAPublicKey_Response {
    var publicKeyMod: String = ""
    var publicKeyExp: String = ""
    var timestamp: UInt64 = 0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.publicKeyMod = try decoder.readString()
            case 2: msg.publicKeyExp = try decoder.readString()
            case 3: msg.timestamp = try decoder.readVarint()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin credential-based auth session
struct CAuthentication_BeginAuthSessionViaCredentials_Request {
    var accountName: String = ""
    var encryptedPassword: String = ""  // Base64 encoded RSA-encrypted password
    var encryptionTimestamp: UInt64 = 0
    var platformType: UInt32 = 1       // k_EAuthTokenPlatformType_SteamClient = 1
    var persistence: UInt32 = 1        // k_ESessionPersistence_Persistent = 1
    var deviceFriendlyName: String = ""
    var websiteId: String = "Client"

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        // Field numbers from steammessages_auth.steamclient.proto:
        //   1 device_friendly_name, 2 account_name, 3 encrypted_password,
        //   4 encryption_timestamp, 6 platform_type, 7 persistence,
        //   8 website_id, 9 device_details.
        // An earlier version of this port sent the account name as field 1 and the
        // encrypted password as field 2, so Steam read the password blob as the
        // account name and every typed sign-in failed with InvalidPassword /
        // AccountNotFound ("account name or password is incorrect").
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeString(fieldNumber: 2, value: accountName)
        encoder.writeString(fieldNumber: 3, value: encryptedPassword)
        encoder.writeUInt64(fieldNumber: 4, value: encryptionTimestamp)
        encoder.writeUInt32(fieldNumber: 6, value: platformType)
        encoder.writeUInt32(fieldNumber: 7, value: persistence)
        encoder.writeString(fieldNumber: 8, value: websiteId)
        // CAuthentication_DeviceDetails: 1 device_friendly_name, 2 platform_type.
        var deviceEncoder = ProtobufEncoder()
        deviceEncoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        deviceEncoder.writeUInt32(fieldNumber: 2, value: platformType)
        encoder.writeSubmessage(fieldNumber: 9, value: deviceEncoder.data)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaCredentials_Response {
    var clientID: UInt64 = 0
    var requestID: Data = Data()
    var interval: Float = 5.0
    var allowedConfirmations: [AllowedConfirmation] = []
    var steamid: UInt64 = 0

    struct AllowedConfirmation {
        var confirmationType: UInt32 = 0  // k_EAuthSessionGuardType
        var associatedMessage: String = ""
    }

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.requestID = try decoder.readBytes()
            case 3:
                let bits = UInt32(try decoder.readFixed32())
                msg.interval = Float(bitPattern: bits)
            case 4:
                let subData = try decoder.readBytes()
                var subDecoder = ProtobufDecoder(subData)
                var confirmation = AllowedConfirmation()
                while let subTag = try subDecoder.readTag() {
                    switch subTag.fieldNumber {
                    case 1: confirmation.confirmationType = UInt32(truncatingIfNeeded: try subDecoder.readVarint())
                    case 2: confirmation.associatedMessage = try subDecoder.readString()
                    default: try subDecoder.skip(wireType: subTag.wireType)
                    }
                }
                msg.allowedConfirmations.append(confirmation)
            // steamid: accept either encoding rather than trust one.
            case 5: msg.steamid = try (tag.wireType == .fixed64 ? decoder.readFixed64() : decoder.readVarint())
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Begin QR auth session
struct CAuthentication_BeginAuthSessionViaQR_Request {
    var deviceFriendlyName: String = ""
    var platformType: UInt32 = 1

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeString(fieldNumber: 1, value: deviceFriendlyName)
        encoder.writeUInt32(fieldNumber: 2, value: platformType)
        return encoder.data
    }
}

struct CAuthentication_BeginAuthSessionViaQR_Response {
    var clientID: UInt64 = 0
    var challengeURL: String = ""
    var requestID: Data = Data()
    var interval: Float = 5.0

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.clientID = try decoder.readVarint()
            case 2: msg.challengeURL = try decoder.readString()
            case 3: msg.requestID = try decoder.readBytes()
            case 4:
                let bits = try decoder.readFixed32()
                msg.interval = Float(bitPattern: bits)
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}

/// Update auth session with Steam Guard code
struct CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request {
    var clientID: UInt64 = 0
    var steamid: UInt64 = 0
    var code: String = ""
    var codeType: UInt32 = 0  // k_EAuthSessionGuardType

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeFixed64(fieldNumber: 2, value: steamid)   // fixed64 steamid = 2 in the proto
        encoder.writeString(fieldNumber: 3, value: code)
        encoder.writeUInt32(fieldNumber: 4, value: codeType)
        return encoder.data
    }
}

/// Poll for auth session status
struct CAuthentication_PollAuthSessionStatus_Request {
    var clientID: UInt64 = 0
    var requestID: Data = Data()

    func serialize() -> Data {
        var encoder = ProtobufEncoder()
        encoder.writeUInt64(fieldNumber: 1, value: clientID)
        encoder.writeBytes(fieldNumber: 2, value: requestID)
        return encoder.data
    }
}

struct CAuthentication_PollAuthSessionStatus_Response {
    var newClientID: UInt64 = 0
    var newChallengeURL: String = ""
    var refreshToken: String = ""
    var accessToken: String = ""
    var hadRemoteInteraction: Bool = false
    var accountName: String = ""
    var newGuardData: String = ""

    static func deserialize(from data: Data) throws -> Self {
        var decoder = ProtobufDecoder(data)
        var msg = Self()

        while let tag = try decoder.readTag() {
            switch tag.fieldNumber {
            case 1: msg.newClientID = try decoder.readVarint()
            case 2: msg.newChallengeURL = try decoder.readString()
            case 3: msg.refreshToken = try decoder.readString()
            case 4: msg.accessToken = try decoder.readString()
            case 5: msg.hadRemoteInteraction = try decoder.readVarint() != 0
            case 6: msg.accountName = try decoder.readString()
            case 7: msg.newGuardData = try decoder.readString()
            default: try decoder.skip(wireType: tag.wireType)
            }
        }
        return msg
    }
}
