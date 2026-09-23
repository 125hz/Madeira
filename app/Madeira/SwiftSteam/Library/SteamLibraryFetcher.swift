// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation

/// Fetches owned games list via Steam PICS (Product Info Change System)
@MainActor
class SteamLibraryFetcher {
    private let session: SteamSession

    init(session: SteamSession) {
        self.session = session
    }

    // MARK: - Fetch Owned Games

    /// Fetch all owned package IDs from license list, then resolve to app IDs
    func fetchOwnedApps() async throws -> [SteamAppInfo] {
        try await session.ensureConnected()

        // Step 1: Get license list (owned packages)
        SteamLog.trace("Fetching license list...")
        let packageIDs = try await fetchLicenseList()
        SteamLog.trace("Got \(packageIDs.count) owned packages")

        // Step 2: Get PICS access tokens for packages
        SteamLog.trace("Requesting PICS access tokens...")
        let packageTokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)

        // Step 3: Get package info to extract app IDs
        SteamLog.trace("Fetching package info...")
        let appIDs = try await fetchAppIDsFromPackages(packageIDs: packageIDs, tokens: packageTokens)
        SteamLog.trace("Found \(appIDs.count) unique app IDs")

        // Step 4: Get PICS access tokens for apps
        let appTokens = try await fetchPICSAccessTokens(appIDs: Array(appIDs))

        // Step 5: Get app info (name, depots, platform support, etc.)
        SteamLog.trace("Fetching app info...")
        let appInfos = try await fetchAppInfo(appIDs: Array(appIDs), tokens: appTokens)
        SteamLog.trace("Got info for \(appInfos.count) apps")

        // Keep playable types — games, demos, and applications (software-style
        // titles). Drops DLC, soundtracks, and tools
        // (Steamworks redistributables, runtimes, SDKs, dedicated servers).
        let games = appInfos.filter { $0.type.isPlayable }
        SteamLog.trace("\(games.count) of \(appInfos.count) apps are playable (game/demo/application)")
        return games
    }

    /// Madeira ml1410: depot IDs included in the account's licenses, from the
    /// same package info the library uses (`depotids`). Valve's DepotDownloader
    /// uses this to leave out depots an account does not own; the installer
    /// consults it only when Steam refuses a depot key. Cached per session.
    private var ownedDepotCache: Set<UInt32>?
    func ownedDepotIDs() async throws -> Set<UInt32> {
        if let cached = ownedDepotCache { return cached }
        try await session.ensureConnected()
        let packageIDs = try await fetchLicenseList()
        let tokens = try await fetchPICSAccessTokens(packageIDs: packageIDs)
        var depots = Set<UInt32>()
        for start in stride(from: 0, to: packageIDs.count, by: 50) {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = packageIDs[start..<min(start + 50, packageIDs.count)].map {
                CMsgClientPICSProductInfoRequest.PackageInfo(packageid: $0, accessToken: tokens[$0] ?? 0)
            }
            let responses = try await session.sendAndWaitPICS(eMsg: .clientPICSProductInfoRequest,
                                                              body: request.serialize(), timeout: 30)
            for response in responses {
                let pics = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in pics.packages { depots.formUnion(VDFParser.parsePackageIDs(key: "depotids", from: pkg.buffer)) }
            }
        }
        ownedDepotCache = depots
        return depots
    }

    /// Fetch PICS info for a single app on demand — used by the install
    /// panel to surface the download size before the user commits to an
    /// install. Connects the session if needed (it may sit idle-disconnected)
    /// and does one token round-trip + one product-info round-trip; no
    /// license list involved.
    func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? {
        try await session.ensureConnected()
        let tokens = try await fetchPICSAccessTokens(appIDs: [appID])
        return try await fetchAppInfo(appIDs: [appID], tokens: tokens).first
    }

    // MARK: - License List

    private func fetchLicenseList() async throws -> [UInt32] {
        try await session.awaitLicenseList(timeout: 15)
    }

    // MARK: - PICS Access Tokens

    private func fetchPICSAccessTokens(appIDs: [UInt32] = [], packageIDs: [UInt32] = []) async throws -> [UInt32: UInt64] {
        var request = CMsgClientPICSAccessTokenRequest()
        request.appids = appIDs
        request.packageids = packageIDs

        let response = try await session.sendAndWait(
            eMsg: .clientPICSAccessTokenRequest,
            body: request.serialize(),
            responseEMsg: .clientPICSAccessTokenResponse,
            timeout: 30
        )

        let tokenResponse = try CMsgClientPICSAccessTokenResponse.deserialize(from: response.body)

        var tokens: [UInt32: UInt64] = [:]
        for appToken in tokenResponse.appAccessTokens {
            tokens[appToken.appid] = appToken.accessToken
        }
        for pkgToken in tokenResponse.packageAccessTokens {
            tokens[pkgToken.packageid] = pkgToken.accessToken
        }

        return tokens
    }

    // MARK: - Package Info → App IDs

    private func fetchAppIDsFromPackages(packageIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> Set<UInt32> {
        var allAppIDs = Set<UInt32>()

        // Batch package info requests (50 at a time)
        let batches = stride(from: 0, to: packageIDs.count, by: 50).map {
            Array(packageIDs[$0..<min($0 + 50, packageIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map { pkgID in
                CMsgClientPICSProductInfoRequest.PackageInfo(
                    packageid: pkgID,
                    accessToken: tokens[pkgID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for pkg in picsResponse.packages {
                    let appIDs = VDFParser.parsePackageAppIDs(from: pkg.buffer)
                    allAppIDs.formUnion(appIDs)
                }
            }
        }

        return allAppIDs
    }

    // MARK: - App Info

    private func fetchAppInfo(appIDs: [UInt32], tokens: [UInt32: UInt64]) async throws -> [SteamAppInfo] {
        var allApps: [SteamAppInfo] = []

        // Batch app info requests (50 at a time)
        let batches = stride(from: 0, to: appIDs.count, by: 50).map {
            Array(appIDs[$0..<min($0 + 50, appIDs.count)])
        }

        for batch in batches {
            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map { appID in
                CMsgClientPICSProductInfoRequest.AppInfo(
                    appid: appID,
                    accessToken: tokens[appID] ?? 0
                )
            }

            let responses = try await session.sendAndWaitPICS(
                eMsg: .clientPICSProductInfoRequest,
                body: request.serialize(),
                timeout: 30
            )

            for response in responses {
                let picsResponse = try CMsgClientPICSProductInfoResponse.deserialize(from: response.body)
                for app in picsResponse.apps {
                    if let info = SteamAppInfo.parse(appID: app.appid, from: app.buffer) {
                        allApps.append(info)
                    }
                }
            }
        }

        return allApps
    }
}

// MARK: - Simple VDF Binary Parser

/// Parses Valve Data Format (binary) used in PICS responses
enum VDFParser {
    // VDF binary types
    private static let typeNone: UInt8 = 0x00
    private static let typeString: UInt8 = 0x01
    private static let typeInt32: UInt8 = 0x02
    private static let typeEnd: UInt8 = 0x08

    /// Parse a text-format VDF / KeyValues blob into a nested dictionary.
    /// Steam PICS sends *app* product info in this text format (`"key" "value"`
    /// pairs and `"key" { ... }` sections) — package info uses the binary
    /// format. Leaf values are always `String`. Standard VDF does not process
    /// escape sequences, so a quoted string runs verbatim to the next `"`.
    static func parseTextVDF(from data: Data) -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        func skipWhitespaceAndComments() {
            while i < n {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                    while i < n && scalars[i] != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        func nextToken() -> String? {
            skipWhitespaceAndComments()
            guard i < n else { return nil }
            let c = scalars[i]
            if c == "{" || c == "}" {
                i += 1
                return String(c)
            }
            var s = ""
            if c == "\"" {
                i += 1
                while i < n && scalars[i] != "\"" {
                    s.unicodeScalars.append(scalars[i])
                    i += 1
                }
                i += 1 // closing quote
                return s
            }
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
                    || ch == "{" || ch == "}" || ch == "\"" { break }
                s.unicodeScalars.append(ch)
                i += 1
            }
            return s
        }

        func parseSection() -> [String: Any] {
            var dict: [String: Any] = [:]
            while let key = nextToken() {
                if key == "}" { break }
                if key == "{" { continue }
                guard let value = nextToken() else { break }
                if value == "{" {
                    dict[key] = parseSection()
                } else if value == "}" {
                    break
                } else {
                    dict[key] = value
                }
            }
            return dict
        }

        return parseSection()
    }

    /// Extract app IDs from a binary VDF package info buffer
    static func parsePackageAppIDs(from data: Data) -> [UInt32] {
        parsePackageIDs(key: "appids", from: data)
    }

    /// Madeira ml1410: the same scan for any id list in a package ("appids",
    /// "depotids").
    static func parsePackageIDs(key searchKey: String, from data: Data) -> [UInt32] {
        var appIDs: [UInt32] = []
        var offset = 0

        // Look for the requested section and extract UInt32 values
        // This is a simplified parser that searches for known patterns
        if let range = findKey(searchKey, in: data) {
            offset = range
            // After "appids" key, we expect sub-keys with numeric names and uint32 values
            while offset < data.count {
                guard offset < data.count else { break }
                let type = data[offset]
                offset += 1

                if type == typeEnd { break }

                // Read key name (null-terminated string)
                guard let (_, newOffset) = readNullTerminatedString(from: data, at: offset) else { break }
                offset = newOffset

                if type == typeInt32 {
                    guard offset + 4 <= data.count else { break }
                    let value = data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                    appIDs.append(UInt32(littleEndian: value))
                    offset += 4
                } else if type == typeString {
                    guard let (_, newOff) = readNullTerminatedString(from: data, at: offset) else { break }
                    offset = newOff
                } else if type == typeNone {
                    // Sub-section - skip or recurse
                    continue
                }
            }
        }

        return appIDs
    }

    private static func findKey(_ key: String, in data: Data) -> Int? {
        let keyBytes = Array(key.utf8) + [0] // null-terminated
        let keyData = Data(keyBytes)
        guard data.count >= keyData.count else { return nil }

        for i in 0..<(data.count - keyData.count) {
            if data[i..<i + keyData.count] == keyData {
                return i + keyData.count
            }
        }
        return nil
    }

    private static func readNullTerminatedString(from data: Data, at offset: Int) -> (String, Int)? {
        var end = offset
        while end < data.count && data[end] != 0 {
            end += 1
        }
        guard end < data.count else { return nil }
        let str = String(data: data[offset..<end], encoding: .utf8) ?? ""
        return (str, end + 1)
    }
}
