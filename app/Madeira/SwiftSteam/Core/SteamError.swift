// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Reduced to
// the errors that sign-in can raise.

import Foundation

/// Errors raised by the Steam sign-in code.
enum SteamError: LocalizedError, Equatable {
    case authenticationFailed(String)
    case invalidCredentials
    case rateLimited
    case accountDisabled
    case rsaKeyFetchFailed
    case qrCodeExpired
    case authSessionExpired
    case protobufError(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .invalidCredentials:
            return "The account name or password is incorrect."
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .accountDisabled:
            return "This Steam account has been disabled"
        case .rsaKeyFetchFailed:
            return "Failed to fetch RSA public key for password encryption"
        case .qrCodeExpired:
            return "QR code has expired. Please try again."
        case .authSessionExpired:
            return "The sign-in request expired. Start again."
        case .protobufError(let detail):
            return "Protocol buffer error: \(detail)"
        }
    }
}

/// Where a Steam Guard code comes from.
enum SteamGuardType: String, Codable {
    case email = "email"
    case device = "device"          // Steam Mobile Authenticator
}
