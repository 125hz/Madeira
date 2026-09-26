import Foundation
import Darwin

// ml1880: public runtime policy; no Steam authentication or host implementation.
enum DockPerformancePolicy {
    static func earlyPoolMB(legacy: Int, explicit: Int?, dock: Bool, compact: Bool,
                            setupComplete: Bool, desktopReserved: Bool, pressureMB: Int = 0) -> Int {
        if let explicit { return explicit }
        // ml2000: a session that ran the pool dry raises every later early pool.
        let floor = (512...1152).contains(pressureMB) ? pressureMB : 0
        guard dock && compact && setupComplete else { return max(legacy, floor) }
        return max(desktopReserved ? max(896, legacy) : 512, floor)
    }

    /// ml2000: the pool size that follows a session which ran a pool of `usedMB` dry.
    static func poolAfterPressure(usedMB: Int) -> Int {
        usedMB < 896 ? 896 : 1152
    }

    static func needsDesktopRestart(compactPoolMB: Int, explicit: Int?, desktop: Bool, dock: Bool) -> Bool {
        explicit == nil && desktop && !dock && compactPoolMB > 0 && compactPoolMB < 896
    }

    static func censusDefault(dock: Bool, lightweight: Bool, diagnostic: Bool, forensic: Bool) -> String? {
        dock && lightweight && !diagnostic && !forensic ? "0" : nil
    }
}

// ml1830: public app-to-executable contract. The independently built host lives
// in the private Madeira Dock repository; only its stripped EXE is bundled.
// ml1910: Dock and native component setup default on for fresh installs.
// MADEIRA_DOCK=0 restores desktop launches; MADEIRA_DOCK_NATIVE_SETUP=0
// restores the interactive installer page without changing the launch route.
enum MadeiraDock {
    static var enabled: Bool {
        LibraryFlags.enabled("MADEIRA_STEAM") && LibraryFlags.enabled("MADEIRA_STEAM_NATIVE")
            && LibraryFlags.enabled("MADEIRA_DOCK", fallback: true)
    }
    static var nativeSetupEnabled: Bool {
        enabled && LibraryFlags.enabled("MADEIRA_DOCK_NATIVE_SETUP", fallback: true)
    }
    static let executable = "C:\\windows\\system32\\dockhost.exe"
    static func routes(_ entry: LibraryEntry) -> Bool { enabled && entry.steamGameLaunch && entry.steamDesktopLaunch != true }
    /// ml1970: a batch of the game's pending one-time installs (DockInstallScripts), run in the
    /// Dock session before the host. Set on the main actor before launch, read by the launch worker.
    nonisolated(unsafe) static var installerScript: String?
    static let installerScriptName = "madeira-dock-installers.cmd"

    static func supportsArguments(_ entry: LibraryEntry) -> Bool {
        entry.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (LibraryFlags.enabled("MADEIRA_DOCK_DEFAULT_ARGUMENTS") && entry.arguments == entry.steamDefaultArguments)
    }

    static func validate(_ entry: LibraryEntry) throws {
        guard let id = entry.steamAppID, SteamPaths.validAppID(id),
              let folder = entry.steamInstallPath, SteamPaths.safeRelative(folder, under: LibraryModel.drive) != nil,
              !entry.steamClientRelativePath.isEmpty,
              Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows") != nil else {
            throw LibraryError.message("Madeira Dock needs its bundled executable and a valid Steam installation. Run Steam setup, then refresh your library.")
        }
        let root = LibraryModel.drive.appendingPathComponent(entry.steamClientRelativePath).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("steamclient64.dll").path) else {
            throw LibraryError.message("Steam's client files are missing. Complete Steam setup before testing Madeira Dock.")
        }
        // The first host contract launches the default option. Do not silently
        // drop a custom profile's command line or choose another executable.
        guard supportsArguments(entry) else {
            throw LibraryError.message("This Dock test supports Steam's default launch option. Clear custom arguments or turn off MADEIRA_DOCK to use the desktop client.")
        }
    }

    /// Tokens stay in Keychain except for this bounded one-use transfer. The
    /// payload is not an ownership claim: Valve authenticates it in the guest.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, appID > 0, UInt64(appID) < UInt64(UInt32.max) else {
            throw LibraryError.message("Your Steam sign-in cannot be handed to Dock. Sign in to Steam again in Madeira.")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The JWT subject selects the account; it is deliberately not treated as
    /// authenticated identity. Only Valve accepting the token can establish it.
    static func subject(_ token: String) throws -> UInt64 {
        guard token.utf8.count <= 8192 else { throw SteamFileError.invalid("Steam sign-in is too large.") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw SteamFileError.invalid("Steam sign-in needs renewal.") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else {
            throw SteamFileError.invalid("Steam sign-in needs renewal.")
        }
        return id
    }

    // ml1870: the seeded iOS prefix has C: but does not guarantee a Z: mapping.
    // Wine's Unix namespace reaches the protected native file without a drive
    // mapping or moving credentials into the user-visible Documents folder.
    static func handoffGuestPath(_ url: URL, unixNamespace: Bool) -> String {
        (unixNamespace ? "\\\\?\\unix" : "Z:") + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // ml1860: a bounded public diagnostic contract, never arbitrary guest text.
    struct Report {
        var fields: [String: String] = [:]
        var result: Int? { fields["probe-result"].flatMap(Int.init) }
        var failure: String? {
            guard let result, result != 0 else { return nil }
            if result == 30 {
                if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                    return "Madeira Dock does not support this Steam client's interface yet. Export the diagnostic log; it now includes the client fingerprint and failed check."
                }
                return "Madeira Dock could not initialize the Steam session (code 30). Export the diagnostic log to identify the failed check."
            }
            if result == 35 { return "Steam did not confirm a license for this game on the signed-in account." }
            if result == 37 {
                if fields["session-native-handoff-app-mismatch"] == "1" {
                    return "Madeira Dock received a sign-in transfer for a different launch. Close the session and try again."
                }
                return "Madeira Dock could not read the one-use Steam sign-in transfer. Steam has not checked the login yet. Export the diagnostic log before trying again."
            }
            // ml1990: Valve's client could not prepare the game's per-user executable (CEG).
            if result == 49 {
                switch fields["ceg-result"].flatMap(Int.init) {
                case -1: return "Steam took too long to prepare this game's executable. Check the connection and try again."
                case 0: return "Steam did not start preparing this game's executable. Use Repair installed files in the game's Steam settings, then try again."
                case 10: return "Steam is busy with this game (updating or running). Try again in a moment."
                // ml2000: Valve's client prepares the executable through its own Windows service.
                case -4: return "Steam's Windows service manager could not be started, so Steam could not prepare this game's executable. Export the diagnostic log."
                case -5: return "Steam's Windows service (Steam Client Service) is not installed in Madeira's Windows setup, so Steam could not prepare this game's executable. Export the diagnostic log."
                default: return "Steam could not prepare this game's executable for your account (code \(fields["ceg-result"] ?? "?")). Export the diagnostic log."
                }
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               let reason = Self.launchRefusal(error, waited: result == 48) {
                return reason
            }
            return "Madeira Dock could not complete the Steam launch (code \(result)). Export the diagnostic log before trying again."
        }

        /// ml1970: Valve's own launch refusal (EAppUpdateError) in words. Numbers only
        /// come from the host report; nothing here changes what Steam decided.
        static func launchRefusal(_ error: Int, waited: Bool) -> String? {
            switch error {
            case 5: return "Steam did not confirm a license for this game on the signed-in account."
            case 6, 21: return "Steam could not reach its servers to start this game. Check the connection and try again."
            case 16: return "Steam reports this game is already running. Close it, then try again."
            case 17, 19, 20:
                return waited
                    ? "Steam could not finish installing content this game needs. Try again later, or use Repair installed files in the game's Steam settings."
                    : "Steam needs to install or update content this game depends on before it can start. Start the game again to let Madeira Dock wait for Steam, or use Repair installed files."
            case 18: return "Steam does not see this game as installed. Use Repair installed files in the game's Steam settings."
            case 28: return "Steam could not find the game's executable. Use Repair installed files in the game's Steam settings."
            case 22, 23, 24: return "Steam could not read this game's configuration. Refresh the library and try again."
            case 25: return "Steam says this game is not released yet."
            case 26: return "Steam says this game is not available in your region."
            default: return nil
            }
        }
    }
    static func parseReport(_ data: Data) -> Report {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Report() }
        let allowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
            "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
            "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
            "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
            "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
            "session-account-input-invalid", "session-app-input-invalid",
            "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
            "session-authenticated-online", "session-requested-app-listed", "session-auth-test-result",
            "launch-client-error", "launch-update-wait", "launch-update-retry", "launch-update-ready",
            "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
            "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
            "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
            "shutdown-begin", "shutdown-complete", "probe-result"]
        var report = Report()
        // Ignore a partial final line until the writer completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]",
                  ["ml1830", "ml1820", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000"].contains(parts[1]) else { continue }
            let field = parts[2].trimmingCharacters(in: .newlines).split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                report.fields[key] = value
            } else if allowed.contains(key), let number = Int32(value) {
                report.fields[key] = String(number)
            }
        }
        return report
    }
    @MainActor private static var lastReport = Report()
    @MainActor private static var lastReportRead = Date.distantPast
    @MainActor static func pollReport(force: Bool = false) -> Report {
        guard force || Date().timeIntervalSince(lastReportRead) >= 2 else { return lastReport }
        lastReportRead = Date()
        let url = LibraryModel.drive.appendingPathComponent("madeira-dock.txt")
        guard let file = try? FileHandle(forReadingFrom: url) else { return lastReport }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 32769), data.count <= 32768 else { return lastReport }
        let report = parseReport(data)
        for key in report.fields.keys.sorted() where report.fields[key] != lastReport.fields[key] {
            SteamLog.event("[dock-report] ml1860 \(key)=\(report.fields[key]!)")
        }
        lastReport = report
        return report
    }

    private static var transferURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MadeiraDock", isDirectory: true).appendingPathComponent("launch.auth")
    }
    @MainActor static func cleanup() {
        if let url = transferURL { try? FileManager.default.removeItem(at: url) }
        unsetenv("MADEIRA_DOCK_AUTH_FILE")
    }
    @MainActor static func writeHandoff(account: String, token: String, appID: Int) throws {
        cleanup()
        lastReport = Report(); lastReportRead = .distantPast
        let report = LibraryModel.drive.appendingPathComponent("madeira-dock.txt")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
        guard let url = transferURL else { throw LibraryError.message("Dock's private transfer folder is unavailable.") }
        var data = try envelope(account: account, token: token, steamID: subject(token), appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let fm = FileManager.default
        var folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LibraryError.message("Dock's transfer folder is invalid.")
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw LibraryError.message("Madeira could not create Dock's private sign-in transfer.")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            try file.write(contentsOf: data); try file.close()
            let unixNamespace = LibraryFlags.enabled("MADEIRA_DOCK_UNIX_HANDOFF")
            setenv("MADEIRA_DOCK_AUTH_FILE", handoffGuestPath(url, unixNamespace: unixNamespace), 1)
            SteamLog.event("[dock-handoff] ml1870 unix-namespace=\(unixNamespace ? 1 : 0) protected-file-ready=1")
        } catch { try? file.close(); cleanup(); throw error }
    }

    static func configure(_ entry: LibraryEntry, dock: Bool? = nil) {
        let route = dock ?? routes(entry)
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            setenv(key, route ? "1" : "0", 1)
        }
        guard route, let appID = entry.steamAppID, let install = entry.steamInstallPath else { return }
        let client = (entry.steamClientRelativePath as NSString).deletingLastPathComponent
        setenv("MADEIRA_STEAM_HOST_APPID", String(appID), 1)
        setenv("MADEIRA_STEAM_HOST_CLIENT_DIR", "C:\\" + client.replacingOccurrences(of: "/", with: "\\"), 1)
        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", "C:\\" + install.replacingOccurrences(of: "/", with: "\\"), 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt", 1)
        // Never let a stale environment choose the PC cached-account test path.
        unsetenv("MADEIRA_STEAM_HOST_ACCOUNT"); unsetenv("MADEIRA_STEAM_HOST_STEAMID")
    }

    @MainActor static func finishReport() -> String? {
        let report = pollReport(force: true)
        guard report.result != nil else { return "Madeira Dock stopped before reporting completion. Export the diagnostic log for this device test." }
        return report.failure
    }
}
