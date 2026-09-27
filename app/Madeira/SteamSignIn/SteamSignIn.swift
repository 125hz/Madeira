// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

enum SteamSignIn {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MADEIRA_STEAM_SIGNIN"] != "0" }
    /// A stored, structurally valid credential is not proof of current authentication or ownership.
    static var isSignedIn: Bool { credentialsForDock() != nil }
    static var accountName: String? { credentialsForDock()?.accountName }

    static func credentialsForDock() -> (accountName: String, refreshToken: String)? {
        guard let value = try? SteamSignInVault.shared.read() else { return nil }
        return (value.accountName, value.refreshToken)
    }

    static func signOut() {
        do { try SteamSignInVault.shared.delete() }
        catch { print("[steam-signin] ml2011 state=keychain-unavailable") }
    }
}

enum SteamSignInFailure: Error, LocalizedError, Equatable, Sendable {
    case disabled, invalidAccount, invalidPassword, invalidCode, invalidResponse
    case invalidStoredCredentials, storage, network, rejected, expired, rateLimited
    case incorrectPassword, incorrectCode, unsupportedGuard, encryption

    var errorDescription: String? {
        switch self {
        case .disabled: return "Steam sign-in is disabled by configuration."
        case .invalidAccount: return "Enter your Steam account name, not your profile name or email address."
        case .invalidPassword: return "Enter your Steam password."
        case .invalidCode: return "Enter the five-character Steam Guard code."
        case .invalidResponse: return "Steam returned an unexpected sign-in response. Please start again."
        case .invalidStoredCredentials: return "The saved sign-in is invalid. Sign out, then sign in again."
        case .storage: return "The iOS Keychain is unavailable. Unlock your device and try again."
        case .network: return "Could not reach Steam. Check your connection and try again."
        case .rejected: return "Steam did not approve this sign-in. Please start again."
        case .expired: return "This sign-in request expired. Please start again."
        case .rateLimited: return "Steam is limiting sign-in attempts. Wait a few minutes before trying again."
        case .incorrectPassword: return "Steam did not accept the account name or password. Please try again."
        case .incorrectCode: return "Steam did not accept that code. Check the current code and try again."
        case .unsupportedGuard: return "This account requires a confirmation method Madeira does not support. Try QR sign-in or check Steam Guard in the Steam app."
        case .encryption: return "Could not encrypt the password for Steam. Please start again."
        }
    }

    static func result(_ code: Int) -> Self {
        switch code {
        case 5: return .incorrectPassword
        case 65, 71, 88: return .incorrectCode
        case 27: return .expired
        case 84, 87: return .rateLimited
        default: return .rejected
        }
    }
}

/// JSON service requests follow Valve's Web API Overview (Service Interfaces).
/// These small value types keep wire encoding independent of UI, Keychain and networking.
enum SteamSignInWire {
    indirect enum Value: Encodable, Sendable {
        case text(String), number(Int), flag(Bool), object([String: Value])
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .flag(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    static func form(_ fields: [String: Value]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(fields)
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        let encoded = json.map { safe.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
        return Data("input_json=\(encoded)".utf8)
    }

    static func validAccount(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func individualID(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = UInt64(value), id >> 56 == 1, (id >> 52) & 15 == 1,
              (id >> 32) & 0xfffff == 1, id & 0xffffffff != 0 else { return nil }
        return id
    }

    static func base64URL(_ value: Substring) -> Data? {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.count % 4 != 1 else { return nil }
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }

    /// Structure only: this does NOT verify a JWT signature, session validity or ownership.
    /// Valve's genuine client must authenticate the refresh token again at launch.
    static func subject(_ token: String) -> UInt64? {
        guard (1...8192).contains(token.utf8.count) else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let header = base64URL(parts[0]), let payload = base64URL(parts[1]),
              let signature = base64URL(parts[2]), !signature.isEmpty,
              let metadata = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              let algorithm = metadata["alg"] as? String, algorithm == "RS256",
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = claims["sub"] as? String else { return nil }
        return individualID(sub)
    }

    static func guardCode(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.utf8.count == 5 && code.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) } ? code : nil
    }

    static func challengeURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, let url = URLComponents(string: value) else { return false }
        return url.scheme == "https" && url.host == "s.team" && url.port == nil &&
            url.user == nil && url.password == nil && url.path.hasPrefix("/q/")
    }

    static func hex(_ value: String) throws -> [UInt8] {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 2048, bytes.count % 2 == 0 else { throw SteamSignInFailure.encryption }
        func nibble(_ byte: UInt8) throws -> UInt8 {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: throw SteamSignInFailure.encryption
            }
        }
        return try stride(from: 0, to: bytes.count, by: 2).map { try nibble(bytes[$0]) * 16 + nibble(bytes[$0 + 1]) }
    }

    static func derLength(_ count: Int) -> [UInt8] {
        if count < 128 { return [UInt8(count)] }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func rsaDER(modulus: String, exponent: String) throws -> Data {
        func integer(_ value: String) throws -> [UInt8] {
            var bytes = try hex(value)
            while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
            guard bytes != [0] else { throw SteamSignInFailure.encryption }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [2] + derLength(bytes.count) + bytes
        }
        let body = try integer(modulus) + integer(exponent)
        return Data([0x30] + derLength(body.count) + body)
    }
}

/// Steam encodes uint64 IDs as JSON strings. Accept exact JSON integers too, never Double.
struct SteamSignInID: Decodable, Sendable {
    let value: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), let number = UInt64(text),
           !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) { value = String(number) }
        else { value = String(try container.decode(UInt64.self)) }
    }
}

struct SteamSignInRSA: Decodable, Sendable {
    let publickey_mod: String
    let publickey_exp: String
    let timestamp: SteamSignInID

    static func encrypt(_ password: String, using response: Self) throws -> String {
#if canImport(Security)
        let modulus = try SteamSignInWire.hex(response.publickey_mod)
        guard (256...512).contains(modulus.count), password.utf8.count <= modulus.count - 11 else {
            throw SteamSignInFailure.encryption
        }
        let der = try SteamSignInWire.rsaDER(modulus: response.publickey_mod, exponent: response.publickey_exp)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, nil)
        else { throw SteamSignInFailure.encryption }
        return (encrypted as Data).base64EncodedString()
#else
        throw SteamSignInFailure.encryption
#endif
    }
}

enum SteamSignInGuard: Int, Sendable, CaseIterable {
    case none = 1, emailCode = 2, deviceCode = 3, deviceConfirmation = 4, emailConfirmation = 5
}

struct SteamSignInBegin: Decodable, Sendable {
    struct Confirmation: Decodable, Sendable { let confirmation_type: Int }
    let client_id: SteamSignInID
    let request_id: String
    let interval: Double
    let steamid: SteamSignInID?
    let challenge_url: String?
    let allowed_confirmations: [Confirmation]?
}

struct SteamSignInPoll: Decodable, Sendable {
    let new_client_id: SteamSignInID?
    let new_challenge_url: String?
    let refresh_token: String?
    let account_name: String?
    // Access tokens and machine guard data are deliberately not decoded or retained.
}

protocol SteamSignInTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class SteamSignInNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct SteamSignInNetwork: SteamSignInTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
#if canImport(Security)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: SteamSignInNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 65_536 else {
            throw SteamSignInFailure.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw SteamSignInFailure.invalidResponse }
            data.append(byte)
        }
        return (data, http)
#else
        // Linux tests inject a synthetic transport; there is no test network fallback.
        throw SteamSignInFailure.network
#endif
    }
}

struct SteamSignInClient: Sendable {
    enum Method: String, Sendable {
        case rsa = "GetPasswordRSAPublicKey", credentials = "BeginAuthSessionViaCredentials"
        case qr = "BeginAuthSessionViaQR", guardCode = "UpdateAuthSessionWithSteamGuardCode"
        case poll = "PollAuthSessionStatus"
    }
    let transport: any SteamSignInTransport
    var encrypt: @Sendable (String, SteamSignInRSA) throws -> String = { try SteamSignInRSA.encrypt($0, using: $1) }

    static func request(_ method: Method, _ fields: [String: SteamSignInWire.Value]) throws -> URLRequest {
        let form = try SteamSignInWire.form(fields)
        var url = URLComponents(string: "https://api.steampowered.com/IAuthenticationService/\(method.rawValue)/v1/")!
        if method == .rsa { url.percentEncodedQuery = String(decoding: form, as: UTF8.self) }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method == .rsa ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        if method != .rsa { request.httpBody = form }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private struct Envelope<T: Decodable>: Decodable { let response: T }
    private struct Empty: Decodable, Sendable {}

    func call<T: Decodable & Sendable>(_ method: Method, _ fields: [String: SteamSignInWire.Value], as: T.Type) async throws -> T {
        try Task.checkCancellation()
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(Self.request(method, fields)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SteamSignInFailure { throw error }
        catch { throw SteamSignInFailure.network }
        try Task.checkCancellation()
        if response.statusCode == 429 { throw SteamSignInFailure.rateLimited }
        if response.statusCode == 401 || response.statusCode == 403 { throw SteamSignInFailure.rejected }
        guard (200...299).contains(response.statusCode) else { throw SteamSignInFailure.network }
        if let result = response.value(forHTTPHeaderField: "X-eresult") {
            guard let code = Int(result) else { throw SteamSignInFailure.invalidResponse }
            if code != 1 { throw SteamSignInFailure.result(code) }
        }
        guard data.count <= 65_536,
              let decoded = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw SteamSignInFailure.invalidResponse
        }
        return decoded.response
    }

    private var device: [String: SteamSignInWire.Value] {
        ["device_friendly_name": .text("Madeira"), "platform_type": .number(1),
         "device_details": .object(["device_friendly_name": .text("Madeira"), "platform_type": .number(1)])]
    }

    func begin(account: String, password: String) async throws -> SteamSignInBegin {
        guard SteamSignInWire.validAccount(account) else { throw SteamSignInFailure.invalidAccount }
        guard !password.isEmpty, password.utf8.count <= 1024 else { throw SteamSignInFailure.invalidPassword }
        let key = try await call(.rsa, ["account_name": .text(account)], as: SteamSignInRSA.self)
        let encrypted = try encrypt(password, key)
        var fields = device
        fields.merge(["account_name": .text(account), "encrypted_password": .text(encrypted),
                      "encryption_timestamp": .text(key.timestamp.value), "remember_login": .flag(true),
                      "persistence": .number(1), "website_id": .text("Client"),
                      "guard_data": .text(""), "language": .number(0)]) { _, new in new }
        let pending = try await call(.credentials, fields, as: SteamSignInBegin.self)
        guard let steamID = pending.steamid, SteamSignInWire.individualID(steamID.value) != nil else {
            throw SteamSignInFailure.invalidResponse
        }
        return pending
    }

    func beginQR() async throws -> SteamSignInBegin {
        let pending = try await call(.qr, device, as: SteamSignInBegin.self)
        guard let challenge = pending.challenge_url, SteamSignInWire.challengeURL(challenge) else {
            throw SteamSignInFailure.invalidResponse
        }
        return pending
    }

    func submit(code: String, type: SteamSignInGuard, client: String, steamID: String) async throws {
        guard (type == .emailCode || type == .deviceCode), let code = SteamSignInWire.guardCode(code) else {
            throw SteamSignInFailure.invalidCode
        }
        _ = try await call(.guardCode, ["client_id": .text(client), "steamid": .text(steamID),
                                      "code": .text(code), "code_type": .number(type.rawValue)], as: Empty.self)
    }

    func poll(client: String, request: String) async throws -> SteamSignInPoll {
        try await call(.poll, ["client_id": .text(client), "request_id": .text(request),
                              "token_to_revoke": .text("0")], as: SteamSignInPoll.self)
    }
}

/// UI-independent state machine; all transitions, code submissions and Keychain saves
/// run on the main actor. Network requests are sequential within one cancellable attempt.
@MainActor
final class SteamSignInFlow {
    enum State: Equatable {
        case signedOut, starting, waiting, signedIn(String), failed(SteamSignInFailure)
    }
    private(set) var state: State = .signedOut { didSet { onChange?() } }
    private(set) var methods: [SteamSignInGuard] = []
    private(set) var qrURL: String?
    private(set) var codeError: SteamSignInFailure?
    private(set) var submittingCode = false
    var onChange: (() -> Void)?
    private let client: SteamSignInClient
    private let vault: SteamSignInVault
    private let sleep: @Sendable (Double) async throws -> Void
    private var task: Task<Void, Never>?
    private var attempt: UInt64 = 0
    private var queuedCode: (String, SteamSignInGuard)?

    init(client: SteamSignInClient = SteamSignInClient(transport: SteamSignInNetwork()),
         vault: SteamSignInVault = .shared,
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.client = client
        self.vault = vault
        self.sleep = sleep
        reload()
    }

    func reload() {
        do {
            if let saved = try vault.read() { state = .signedIn(saved.accountName) }
            else { state = .signedOut }
        } catch { state = .failed((error as? SteamSignInFailure) ?? .storage) }
    }

    func cancel() {
        attempt &+= 1
        task?.cancel()
        task = nil
        queuedCode = nil
        methods = []
        qrURL = nil
        submittingCode = false
        codeError = nil
        reload()
    }

    func signOut() {
        cancel()
        do { try vault.delete(); state = .signedOut }
        catch { state = .failed(.storage) }
    }

    func start(account: String, password: String) {
        start { [client] in try await client.begin(account: account, password: password) }
    }

    func startQR() { start { [client] in try await client.beginQR() } }

    private func start(_ begin: @escaping @Sendable () async throws -> SteamSignInBegin) {
        cancel()
        guard SteamSignIn.isEnabled else { state = .failed(.disabled); return }
        let id = attempt
        let revision = vault.begin()
        state = .starting
        print("[steam-signin] ml2011 state=starting")
        // Release the closure carrying the password after the begin request, before polling.
        var operation: (@Sendable () async throws -> SteamSignInBegin)? = begin
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let pending = try await operation?() else { throw CancellationError() }
                operation = nil
                try self.check(id)
                try await self.wait(pending, id: id, revision: revision)
            } catch {
                operation = nil
                guard self.attempt == id, !Task.isCancelled else { return }
                self.qrURL = nil
                self.queuedCode = nil
                self.submittingCode = false
                if error is CancellationError { self.reload(); return }
                self.state = .failed((error as? SteamSignInFailure) ?? .network)
                print("[steam-signin] ml2011 state=failed")
            }
        }
    }

    func submit(code: String, type: SteamSignInGuard) {
        guard state == .waiting, !submittingCode, methods.contains(type),
              type == .emailCode || type == .deviceCode else { return }
        guard let normalized = SteamSignInWire.guardCode(code) else {
            codeError = .invalidCode; onChange?(); return
        }
        queuedCode = (normalized, type)
        codeError = nil
        submittingCode = true
        onChange?()
    }

    private func check(_ id: UInt64) throws {
        try Task.checkCancellation()
        guard attempt == id else { throw CancellationError() }
    }

    private func wait(_ pending: SteamSignInBegin, id: UInt64, revision: UInt64) async throws {
        guard pending.client_id.value != "0", pending.request_id.utf8.count <= 1024,
              let bytes = Data(base64Encoded: pending.request_id), !bytes.isEmpty,
              pending.interval.isFinite, pending.interval > 0, pending.interval <= 60 else {
            throw SteamSignInFailure.invalidResponse
        }
        if let steamID = pending.steamid, SteamSignInWire.individualID(steamID.value) == nil {
            throw SteamSignInFailure.invalidResponse
        }
        let supported = (pending.allowed_confirmations ?? []).compactMap { SteamSignInGuard(rawValue: $0.confirmation_type) }
        methods = SteamSignInGuard.allCases.filter {
            supported.contains($0) && (pending.steamid != nil || ($0 != .emailCode && $0 != .deviceCode))
        }
        if let challenge = pending.challenge_url {
            guard SteamSignInWire.challengeURL(challenge) else { throw SteamSignInFailure.invalidResponse }
            qrURL = challenge
        } else if methods.isEmpty { throw SteamSignInFailure.unsupportedGuard }
        state = .waiting
        print("[steam-signin] ml2011 state=waiting-for-steam")
        var clientID = pending.client_id.value
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try check(id)
            guard vault.isCurrent(revision) else { throw CancellationError() }
            if let (code, type) = queuedCode {
                queuedCode = nil
                guard let steamID = pending.steamid?.value else { throw SteamSignInFailure.invalidResponse }
                do { try await client.submit(code: code, type: type, client: clientID, steamID: steamID) }
                catch let error as SteamSignInFailure where error == .incorrectCode {
                    try check(id)
                    codeError = error
                }
                try check(id)
                submittingCode = false
                onChange?()
            }
            let response = try await client.poll(client: clientID, request: pending.request_id)
            try check(id)
            guard clock.now < deadline else { throw SteamSignInFailure.expired }
            if let rotated = response.new_client_id, rotated.value != "0" { clientID = rotated.value }
            if let challenge = response.new_challenge_url, !challenge.isEmpty {
                guard SteamSignInWire.challengeURL(challenge) else { throw SteamSignInFailure.invalidResponse }
                qrURL = challenge
                onChange?()
            }
            if let token = response.refresh_token, !token.isEmpty {
                guard let account = response.account_name, let subject = SteamSignInWire.subject(token),
                      pending.steamid == nil || pending.steamid?.value == String(subject) else {
                    throw SteamSignInFailure.invalidResponse
                }
                try vault.save(SteamSignInCredentials(accountName: account, refreshToken: token), revision: revision)
                qrURL = nil
                queuedCode = nil
                submittingCode = false
                state = .signedIn(account)
                print("[steam-signin] ml2011 state=signed-in")
                return
            }
            try await sleep(max(1, pending.interval))
        }
        throw SteamSignInFailure.expired
    }
}
