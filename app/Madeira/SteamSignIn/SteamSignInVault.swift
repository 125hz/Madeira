// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(Security)
import Security
#endif

struct SteamSignInCredentials: Codable, Equatable, Sendable {
    let accountName: String
    let refreshToken: String

    var isValid: Bool {
        SteamSignInWire.validAccount(accountName) && SteamSignInWire.subject(refreshToken) != nil
    }
}

/// The test backend is memory-only. Production has no file/defaults fallback.
protocol SteamSignInStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// The lock serializes the backend and revision. Signing out invalidates in-flight saves,
/// including a response that arrives after a cancelled request or an external Dock sign-out.
final class SteamSignInVault: @unchecked Sendable {
    static let shared = SteamSignInVault(storage: SteamSignInKeychain())
    private let storage: any SteamSignInStorage
    private let lock = NSLock()
    private var revision: UInt64 = 0

    init(storage: any SteamSignInStorage) { self.storage = storage }

    func read() throws -> SteamSignInCredentials? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try storage.read() else { return nil }
        guard data.count <= 16_384,
              let value = try? JSONDecoder().decode(SteamSignInCredentials.self, from: data),
              value.isValid else { throw SteamSignInFailure.invalidStoredCredentials }
        return value
    }

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        return revision
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == expected
    }

    func save(_ value: SteamSignInCredentials, revision expected: UInt64) throws {
        guard value.isValid else { throw SteamSignInFailure.invalidResponse }
        lock.lock()
        defer { lock.unlock() }
        guard revision == expected else { throw CancellationError() }
        try storage.write(JSONEncoder().encode(value))
        revision &+= 1
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        try storage.delete()
    }
}

private struct SteamSignInKeychain: SteamSignInStorage {
#if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "madeira.steam.signin",
         // Constant metadata: the account name lives only inside the protected value.
         kSecAttrAccount as String: "credentials",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SteamSignInFailure.storage
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SteamSignInFailure.storage }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SteamSignInFailure.storage
        }
    }
#else
    func read() throws -> Data? { throw SteamSignInFailure.storage }
    func write(_ data: Data) throws { throw SteamSignInFailure.storage }
    func delete() throws { throw SteamSignInFailure.storage }
#endif
}
