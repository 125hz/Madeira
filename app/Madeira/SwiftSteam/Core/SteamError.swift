// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation

// MARK: - SwiftSteam Error Types

/// Top-level errors for SwiftSteam operations
enum SteamError: LocalizedError {
    /// Logon EResults that mean the stored sign-in token itself is unusable:
    /// InvalidPassword, AccessDenied, AccountNotFound, Revoked, Expired,
    /// InvalidSignature.
    static let signInExpiredCodes: Set<UInt32> = [5, 15, 18, 26, 27, 94]

    // Connection errors
    case noServersAvailable
    case connectionFailed(String)
    case connectionTimeout
    case disconnected
    case webSocketError(Error)

    // Authentication errors
    case authenticationFailed(String)
    case invalidCredentials
    case steamGuardRequired(SteamGuardType)
    case twoFactorRequired
    case rateLimited
    case accountDisabled
    case tokenExpired
    case tokenRefreshFailed
    case rsaKeyFetchFailed
    case qrCodeExpired
    case authSessionExpired
    /// CM logon refused with this EResult (Madeira: lets callers tell a
    /// revoked or expired sign-in from a transient network failure).
    case logonDenied(UInt32)

    // Session errors
    case notAuthenticated
    case sessionExpired
    case heartbeatFailed

    // Protocol errors
    case invalidMessage
    case unexpectedResponse(UInt32)
    case protobufError(String)
    case messageTooLarge(Int)
    case cryptoError(String)
    case channelEncryptFailed(String)

    // Library errors
    case libraryFetchFailed(String)
    case appInfoNotFound(UInt32)
    case depotNotFound(UInt32)

    // Content/download errors
    case manifestFetchFailed(String)
    case chunkDownloadFailed(String)
    case decryptionFailed(String)
    case decompressionFailed
    /// ml1320: a downloaded chunk could not be decoded; the associated value
    /// names the encoding (vzip, vzstd, zip…) or its leading bytes.
    case chunkDecodeFailed(String)
    case checksumMismatch
    case depotKeyNotFound(UInt32)
    case insufficientDiskSpace(needed: UInt64, available: UInt64)


    var errorDescription: String? {
        switch self {
        case .noServersAvailable:
            return "No Steam CM servers available"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionTimeout:
            return "Steam did not respond in time. Check your internet connection and try again."
        case .disconnected:
            return "Disconnected from Steam server"
        case .webSocketError(let error):
            return "WebSocket error: \(error.localizedDescription)"
        case .authenticationFailed(let reason):
            return reason
        case .invalidCredentials:
            return "The account name or password is incorrect."
        case .steamGuardRequired(let type):
            return "Steam Guard verification required (\(type.displayName))"
        case .twoFactorRequired:
            return "Two-factor authentication code required"
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .accountDisabled:
            return "This Steam account has been disabled"
        case .tokenExpired:
            return "Session token has expired"
        case .tokenRefreshFailed:
            return "Failed to refresh session token"
        case .rsaKeyFetchFailed:
            return "Failed to fetch RSA public key for password encryption"
        case .qrCodeExpired:
            return "QR code has expired. Please try again."
        case .authSessionExpired:
            return "The sign-in request expired. Start again."
        case .logonDenied(let code):
            return SteamError.signInExpiredCodes.contains(code)
                ? "Your Steam sign-in is no longer valid. Sign in again."
                : "Steam refused the connection (code \(code)). Try again later."
        case .notAuthenticated:
            return "Not authenticated with Steam"
        case .sessionExpired:
            return "Steam session has expired"
        case .heartbeatFailed:
            return "Failed to send heartbeat to Steam server"
        case .invalidMessage:
            return "Received invalid message from Steam server"
        case .unexpectedResponse(let eMsg):
            return "Unexpected response from Steam server (EMsg: \(eMsg))"
        case .protobufError(let detail):
            return "Protocol buffer error: \(detail)"
        case .messageTooLarge(let size):
            return "Message too large: \(size) bytes"
        case .cryptoError(let detail):
            return "Crypto error: \(detail)"
        case .channelEncryptFailed(let detail):
            return "Channel encrypt failed: \(detail)"
        case .libraryFetchFailed(let reason):
            return "Failed to fetch library: \(reason)"
        case .appInfoNotFound(let appID):
            return "App info not found for app \(appID)"
        case .depotNotFound(let depotID):
            return "Steam has no Windows download for this game (app \(depotID))."
        case .manifestFetchFailed(let reason):
            return "Could not read the game's file list: \(reason)"
        case .chunkDownloadFailed(let reason):
            return "Download failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .decompressionFailed:
            return "Failed to decompress chunk data"
        case .chunkDecodeFailed(let format):
            return "Part of the game could not be decoded (\(format)). Try again; downloaded parts are kept."
        case .checksumMismatch:
            return "Chunk checksum verification failed"
        case .depotKeyNotFound:
            return "Steam did not allow this account to download the game's files. Check that the account owns it."
        case .insufficientDiskSpace(let needed, let available):
            return String(format: "Not enough free space: the download needs %.1f GB and %.1f GB is available.",
                          Double(needed) / 1_000_000_000, Double(available) / 1_000_000_000)
        }
    }
}

// MARK: - Steam Guard Types

enum SteamGuardType: String, Codable {
    case email = "email"
    case device = "device"          // Steam Mobile Authenticator
    case machineToken = "machine"   // Remember this computer

    var displayName: String {
        switch self {
        case .email: return "Email Code"
        case .device: return "Mobile Authenticator"
        case .machineToken: return "Machine Token"
        }
    }
}

// MARK: - Steam Connection State

enum SteamConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected       // TCP/WS connected, not yet authenticated
    case authenticated   // Fully logged in with session
    case reconnecting    // Lost connection, attempting to reconnect

    var isConnected: Bool {
        self == .connected || self == .authenticated
    }

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .authenticated: return "Authenticated"
        case .reconnecting: return "Reconnecting..."
        }
    }
}

// MARK: - Steam EMsg Constants

/// Steam protocol message types (subset used by SwiftSteam)
enum EMsg: UInt32 {
    // Mask for protobuf messages
    static let protoMask: UInt32 = 0x80000000

    // General
    case multi = 1
    case channelEncryptRequest = 1303
    case channelEncryptResponse = 1304
    case channelEncryptResult = 1305
    case clientHeartBeat = 703
    case clientHello = 4006

    // Login
    case clientLogon = 5514
    case clientLogonResponse = 5515
    case clientLogOff = 5516
    case clientLoggedOff = 5517

    // License / ownership
    case clientLicenseList = 780

    // PICS
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906

    // Depot
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case clientGetCDNAuthToken = 5546
    case clientGetCDNAuthTokenResponse = 5547

    // Service methods (unified messages)
    case serviceMethod = 146
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151

    /// Raw value with protobuf mask applied
    var masked: UInt32 {
        rawValue | EMsg.protoMask
    }
}

// MARK: - Steam Service Method Names

enum SteamServiceMethod: String {
    // Auth
    case getPasswordRSAPublicKey = "Authentication.GetPasswordRSAPublicKey#1"
    case beginAuthSessionViaCredentials = "Authentication.BeginAuthSessionViaCredentials#1"
    case beginAuthSessionViaQR = "Authentication.BeginAuthSessionViaQR#1"
    case updateAuthSessionWithSteamGuardCode = "Authentication.UpdateAuthSessionWithSteamGuardCode#1"
    case pollAuthSessionStatus = "Authentication.PollAuthSessionStatus#1"

    // Cloud (Steam Cloud save sync)
    case getAppFileChangelist = "Cloud.GetAppFileChangelist#1"
    case clientFileDownload = "Cloud.ClientFileDownload#1"
    case beginAppUploadBatch = "Cloud.BeginAppUploadBatch#1"
    case beginHTTPUpload = "Cloud.BeginHTTPUpload#1"
    case commitHTTPUpload = "Cloud.CommitHTTPUpload#1"
    case completeAppUploadBatch = "Cloud.CompleteAppUploadBatch#1"
    case signalAppLaunchIntent = "Cloud.SignalAppLaunchIntent#1"
    case signalAppExitSyncDone = "Cloud.SignalAppExitSyncDone#1"

    // Content
    case getManifestRequestCode = "ContentServerDirectory.GetManifestRequestCode#1"
    case getCDNAuthToken = "ContentServerDirectory.GetCDNAuthToken#1"
    case getContentServers = "ContentServerDirectory.GetServers#1"
}

// MARK: - Steam Result Codes

enum EResult: UInt32 {
    case ok = 1
    case fail = 2
    case noConnection = 3
    case invalidPassword = 5
    case loggedInElsewhere = 6
    case invalidProtocolVersion = 7
    case invalidParam = 8
    case fileNotFound = 9
    case busy = 10
    case invalidState = 11
    case invalidName = 12
    case accessDenied = 15
    case timeout = 16
    case banned = 17
    case accountNotFound = 18
    case invalidSteamID = 19
    case serviceUnavailable = 20
    case notLoggedOn = 21
    case pending = 22
    case rateLimitExceeded = 84
    case accountLoginDeniedNeedTwoFactor = 85
    case expired = 27
    case accountLogonDenied = 63          // Steam Guard email required
    case accountLogonDeniedNoMail = 66
    case accountLogonDeniedVerifiedEmailRequired = 74
    case twoFactorCodeMismatch = 88
    case twoFactorActivationCodeMismatch = 89
    case tryAnotherCM = 48                // Server overloaded, try a different CM

    var isSuccess: Bool { self == .ok }
}
