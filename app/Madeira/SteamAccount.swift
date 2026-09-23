import SwiftUI
import UIKit

// ml1310: native Steam account, owned library and downloads for the optional
// library. Steam itself authenticates the account and decides ownership:
// depot keys are only issued for depots the signed-in account owns. Games are
// downloaded unmodified into a normal Steam library folder inside drive_c and
// launched either directly or through the Windows Steam client.
// MADEIRA_STEAM_NATIVE=0 hides all of it; MADEIRA_STEAM=0 disables Steam entirely.

enum SteamInstallPaths {
    /// C:\Program Files (x86)\Steam — the Windows client's default location,
    /// so a client installed later recognizes these games.
    static var root: URL { LibraryModel.drive.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true) }
    static var steamApps: URL { root.appendingPathComponent("steamapps", isDirectory: true) }
    static var common: URL { steamApps.appendingPathComponent("common", isDirectory: true) }
}

struct SteamLaunchOption: Codable, Hashable {
    var executable: String
    var arguments: String
    var label: String
    var arch: String
    var type: String
}

struct SteamOwnedGame: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var installDir: String
    var downloadBytes: Int64
    var buildID: Int
    var launch: [SteamLaunchOption]

    init(_ info: SteamAppInfo) {
        id = Int(info.appID)
        name = info.name
        installDir = info.installDir
        downloadBytes = Int64(clamping: info.downloadSize(for: "windows"))
        buildID = Int(info.buildID)
        launch = info.launchConfigs(for: "windows").compactMap { config in
            let exe = config.executable.trimmingCharacters(in: .whitespaces)
            guard exe.lowercased().hasSuffix(".exe") else { return nil }
            return SteamLaunchOption(executable: exe, arguments: config.arguments, label: config.description,
                                     arch: config.osarch, type: config.type)
        }
    }

    /// Stable identity for grid focus, derived from the App ID.
    var focusID: UUID { UUID(uuidString: String(format: "5354454D-0000-4000-8000-%012llX", UInt64(id))) ?? UUID() }
    var folderName: String { DepotDownloader.safeFolderName(installDir.isEmpty ? "app_\(id)" : installDir) }
}

@MainActor
final class SteamAccountModel: ObservableObject {
    static let shared = SteamAccountModel()
    static var enabled: Bool { LibraryFlags.enabled("MADEIRA_STEAM") && LibraryFlags.enabled("MADEIRA_STEAM_NATIVE") }

    enum Phase: Equatable { case signedOut, signedIn }
    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var accountName = ""
    @Published private(set) var owned: [SteamOwnedGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    @Published var error: String?

    // Sign-in
    enum SignInMethod: String { case password, qr }
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var qrLink: URL?
    @Published private(set) var guardPrompt: SteamGuardPrompt?
    @Published private(set) var signInBusy = false
    @Published var signInError: String?

    // Downloads
    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var progress = SteamDownloadProgress()
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    private var inSession = false
    private var resumeAfterSession = Set<Int>()

    private let session = SteamSession()
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private let qr = SteamQRAuth()
    private let credentials = SteamCredentialAuth()
    private var signInTask: Task<Void, Never>?
    private var started = false

    private static var cacheURL: URL { LibraryModel.documents.appendingPathComponent("madeira-steam-library.json") }
    private struct Cache: Codable { var version: Int; var updated: Date; var games: [SteamOwnedGame]; var revision: Int? }
    /// ml1420: the owned-library filter changed (app types match without
    /// case). A list cached before it is refreshed at the next start instead
    /// of after six hours. Follows MADEIRA_STEAM_TYPE_FOLD.
    private static var libraryRevision: Int? { SteamAppInfo.AppType.foldsCase ? 1420 : nil }
    private var cacheRevision: Int?

    // MARK: Lifecycle

    func start() {
        guard Self.enabled, !started else { return }
        started = true
        if let tokens = session.tokenStore.loadTokens() {
            accountName = tokens.accountName
            phase = .signedIn
            if let data = try? Data(contentsOf: Self.cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 {
                owned = cache.games; libraryUpdated = cache.updated; cacheRevision = cache.revision
            }
        }
        SteamLog.event("[steam-account] ml1310 start signed-in=\(phase == .signedIn ? 1 : 0) cached=\(owned.count)")
        let outdated = libraryUpdated != nil && Self.libraryRevision != nil && cacheRevision != Self.libraryRevision
        if outdated { SteamLog.event("[steam-library] ml1420 cached list predates the type filter fix; refreshing") }
        if phase == .signedIn, outdated || Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
            Task { await refreshLibrary(interactive: false) }
        }
    }

    /// Called when a Wine session starts or ends. Downloads pause for the
    /// session (memory and I/O belong to the game) and resume afterwards.
    func sessionChanged(active running: Bool) {
        guard Self.enabled else { return }
        inSession = running
        if running {
            let pause = LibraryFlags.enabled("MADEIRA_STEAM_PAUSE_FOR_SESSION")
            if pause {
                if let current = active {
                    resumeAfterSession.insert(current.id)
                    current.task.cancel()
                }
                for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
                queue.removeAll()
                SteamLog.event("[steam-depot] ml1310 paused for session count=\(resumeAfterSession.count)")
            }
            // ml1340: log off from Steam as the game boots instead of leaving the
            // connection to its idle timeout, independent of the download switch.
            // A download allowed to continue (pause switch off) keeps it; the
            // downloader reconnects on demand either way.
            // MADEIRA_STEAM_SESSION_DISCONNECT=0 leaves the connection alone.
            if LibraryFlags.enabled("MADEIRA_STEAM_SESSION_DISCONNECT"), pause || active == nil {
                Task { await session.disconnectGracefully() }
                SteamLog.event("[steam-account] ml1340 logged off for game session")
            }
        } else {
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for id in resume { install(id) }
            if !resume.isEmpty { SteamLog.event("[steam-depot] ml1310 resumed after session count=\(resume.count)") }
        }
    }

    // MARK: Sign-in

    func beginQR() {
        cancelSignIn()
        signInBusy = true; signInError = nil
        qr.onNewChallenge = { [weak self] image, url in
            self?.qrImage = image; self?.qrLink = URL(string: url)
        }
        signInTask = Task { @MainActor in
            do {
                let image = try await qr.beginQRAuth()
                qrImage = image
                if case .showingQR(_, let url) = qr.authState { qrLink = URL(string: url) }
                signInBusy = false
                let tokens = try await qr.pollForConfirmation()
                finishSignIn(account: tokens.accountName, refresh: tokens.refreshToken, access: tokens.accessToken, method: "qr")
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failSignIn(error, method: "qr") }
            }
        }
    }

    func signIn(account: String, password: String) {
        cancelSignIn()
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { return }
        signInBusy = true; signInError = nil
        signInTask = Task { @MainActor in
            do {
                let prompt = try await credentials.begin(username: name, password: password)
                guardPrompt = prompt
                signInBusy = prompt == nil
                let tokens = try await credentials.pollForTokens()
                finishSignIn(account: tokens.accountName, refresh: tokens.refreshToken, access: tokens.accessToken, method: "password")
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failSignIn(error, method: "password") }
            }
        }
    }

    /// Submit a Steam Guard code; the running poll receives the tokens.
    func submitGuardCode(_ code: String) {
        guard let type = guardPrompt?.codeType, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        signInBusy = true; signInError = nil
        Task { @MainActor in
            do { try await credentials.submitSteamGuardCode(code, type: type) }
            catch { signInError = Self.message(error); signInBusy = false }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel(); signInTask = nil
        qr.cancel(); qr.onNewChallenge = nil
        qrImage = nil; qrLink = nil; guardPrompt = nil; signInBusy = false
    }

    private func failSignIn(_ error: Error, method: String) {
        signInError = Self.message(error)
        signInBusy = false; guardPrompt = nil; qrImage = nil; qrLink = nil
        SteamLog.event("[steam-account] ml1310 sign-in failed method=\(method) reason=\(Self.reason(error))")
    }

    private func finishSignIn(account: String, refresh: String, access: String, method: String) {
        session.tokenStore.saveTokens(accountName: account, refreshToken: refresh, accessToken: access, steamID: 0)
        // The CM logon reads the token back from the Keychain; without it every
        // later request would silently time out.
        guard session.tokenStore.loadTokens() != nil else {
            signInTask = nil; qr.onNewChallenge = nil
            qrImage = nil; qrLink = nil; guardPrompt = nil; signInBusy = false
            signInError = "Steam accepted the sign-in, but Madeira could not save it in this device's Keychain. Check the app's signing and try again."
            SteamLog.event("[steam-account] ml1310 sign-in keychain-store failed method=\(method)")
            return
        }
        accountName = account
        phase = .signedIn
        // This runs inside the sign-in task: clear its state without
        // cancelling it, and fetch the library in a task of its own.
        signInTask = nil; qr.onNewChallenge = nil
        qrImage = nil; qrLink = nil; guardPrompt = nil; signInBusy = false; signInError = nil
        SteamLog.event("[steam-account] ml1310 signed in method=\(method)")
        Task { await refreshLibrary(interactive: true) }
    }

    func signOut() {
        for id in Array(downloads.keys) { pause(id) }
        session.logout()
        try? FileManager.default.removeItem(at: Self.cacheURL)
        owned = []; libraryUpdated = nil; accountName = ""; phase = .signedOut
        SteamLog.event("[steam-account] ml1310 signed out")
    }

    // MARK: Library

    /// `interactive` refreshes (sign-in, pull to refresh, Settings) report
    /// failures to the user; the automatic refresh at start only logs
    /// transient ones, so an offline launch does not raise an alert.
    func refreshLibrary(interactive: Bool = true) async {
        guard phase == .signedIn, !refreshing, !inSession else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let apps = try await fetcher.fetchOwnedApps()
            let games = apps.filter(\.installableOnWindows).map(SteamOwnedGame.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            owned = games
            libraryUpdated = Date()
            cacheRevision = Self.libraryRevision
            let encoder = JSONEncoder()
            try? encoder.encode(Cache(version: 1, updated: libraryUpdated!, games: games, revision: cacheRevision)).write(to: Self.cacheURL, options: .atomic)
            SteamLog.event("[steam-library] ml1310 owned apps=\(apps.count) windows-installable=\(games.count)")
            // ml1420: once per fetch, which owned apps the library leaves out
            // and why (App IDs and reason tokens). MADEIRA_STEAM_HIDDEN_LOG=0 disables.
            if LibraryFlags.enabled("MADEIRA_STEAM_HIDDEN_LOG"), let report = fetcher.lastVisibility {
                SteamLog.event("[steam-library] ml1420 hidden shown=\(games.count) type-fold=\(SteamAppInfo.AppType.foldsCase ? 1 : 0) " + report.summary(limit: 40))
            }
        } catch {
            handleSessionError(error, context: "library", report: interactive)
        }
    }

    /// Owned games that have no library entry yet (not installed through
    /// Madeira or discovered from the Windows client's library).
    func uninstalledGames(excluding entries: [LibraryEntry]) -> [SteamOwnedGame] {
        let present = Set(entries.compactMap(\.steamAppID))
        return owned.filter { !present.contains($0.id) }
    }

    func game(_ appID: Int) -> SteamOwnedGame? { owned.first { $0.id == appID } }

    /// ml1390: before a Windows-client launch, record what the install record
    /// says, so a client refusal ("please update these games first") can be
    /// compared with it. Fields and depot/manifest IDs only; no account data.
    /// MADEIRA_STEAM_ACF_LOG=0 disables.
    static func logInstallRecord(appID: Int) {
        guard LibraryFlags.enabled("MADEIRA_STEAM_ACF_LOG") else { return }
        let url = SteamInstallPaths.steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"] else {
            LogStore.shared.log("[steam-acf] ml1390 app=\(appID) record=unreadable")
            return
        }
        func text(_ key: String) -> String { state[key]?.string ?? "-" }
        let depots = (state["InstalledDepots"]?.fields ?? [:]).sorted { $0.key < $1.key }.prefix(16)
            .map { "\($0.key):\($0.value["manifest"]?.string ?? "-")" }.joined(separator: ",")
        let shared = (state["SharedDepots"]?.fields ?? [:]).sorted { $0.key < $1.key }.prefix(16)
            .map { "\($0.key)>\($0.value.string ?? "-")" }.joined(separator: ",")
        LogStore.shared.log("[steam-acf] ml1390 app=\(appID) state=\(text("StateFlags")) buildid=\(text("buildid")) " +
                            "target=\(text("TargetBuildID")) update=\(text("UpdateResult")) " +
                            "depots=\(depots.isEmpty ? "-" : depots) shared=\(shared.isEmpty ? "-" : shared)")
    }

    func updateAvailable(for entry: LibraryEntry) -> Bool {
        guard entry.steamNative == true, let appID = entry.steamAppID, let build = entry.steamBuildID,
              let latest = game(appID)?.buildID else { return false }
        return latest > build
    }

    private func handleSessionError(_ error: Error, context: String, report: Bool = true) {
        if case SteamError.logonDenied(let code) = error, SteamError.signInExpiredCodes.contains(code) {
            session.logout()
            phase = .signedOut; accountName = ""
            self.error = "Your Steam sign-in is no longer valid. Sign in again to see your games."
            SteamLog.event("[steam-account] ml1310 stored sign-in rejected code=\(code)")
            return
        }
        if report { self.error = Self.message(error) }
        SteamLog.event("[steam-\(context)] ml1310 failed reason=\(Self.reason(error)) reported=\(report ? 1 : 0)")
    }

    // MARK: Downloads

    func install(_ appID: Int) {
        guard Self.enabled else { return }
        guard phase == .signedIn else { error = "Sign in to Steam to download games."; return }
        if active?.id == appID || queue.contains(appID) { return }
        if inSession {
            resumeAfterSession.insert(appID); downloads[appID] = Download(state: .paused); return
        }
        var item = downloads[appID] ?? Download(state: .queued)
        item.state = .queued
        downloads[appID] = item
        queue.append(appID)
        pump()
    }

    func pause(_ appID: Int) {
        if let current = active, current.id == appID {
            current.task.cancel()
        } else if let index = queue.firstIndex(of: appID) {
            queue.remove(at: index)
            downloads[appID]?.state = .paused
        }
        resumeAfterSession.remove(appID)
    }

    /// Stop a first-time install and delete its partial files. Updates of an
    /// installed game are only paused, never deleted.
    func cancelInstall(_ appID: Int) {
        let hasEntry = LibraryModel.shared.entries.contains { $0.steamAppID == appID }
        let running = active?.id == appID ? active?.task : nil
        pause(appID)
        downloads[appID] = nil
        guard !hasEntry, let game = game(appID) else { return }
        Task { @MainActor in
            await running?.value
            Self.deleteInstallFiles(appID: appID, folderName: game.folderName)
            SteamLog.event("[steam-depot] ml1310 cancelled app=\(appID) partial-files-removed=1")
        }
    }

    func hasPartialDownload(_ appID: Int) -> Bool {
        DepotDownloader.hasPartialDownload(appID: UInt32(appID), steamApps: SteamInstallPaths.steamApps)
    }

    // The app already keeps the idle timer disabled for its whole lifetime
    // (MetalBackedView setup), so the display stays on during downloads.
    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let appID = queue.removeFirst()
        downloads[appID]?.state = .active
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(appID)
        }
        active = (appID, task)
    }

    private func run(_ appID: Int) async {
        do {
            guard let info = try await fetcher.fetchAppInfo(appID: UInt32(appID)) else {
                throw SteamError.appInfoNotFound(UInt32(appID))
            }
            try FileManager.default.createDirectory(at: SteamInstallPaths.common, withIntermediateDirectories: true)
            let folder = try await downloader.install(info, steamApps: SteamInstallPaths.steamApps,
                                                      ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() }) { [weak self] progress in
                self?.downloads[appID]?.progress = progress
            }
            try await completeInstall(info, folder: folder)
            downloads[appID] = nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[appID] != nil { downloads[appID]?.state = .paused }
                SteamLog.event("[steam-depot] ml1310 paused app=\(appID)")
            } else if case SteamError.logonDenied = error {
                downloads[appID]?.state = .failed(Self.message(error))
                handleSessionError(error, context: "depot")
            } else {
                downloads[appID]?.state = .failed(Self.message(error))
                SteamLog.event("[steam-depot] ml1310 failed app=\(appID) reason=\(Self.reason(error))")
            }
        }
        active = nil
        pump()
    }

    private func completeInstall(_ info: SteamAppInfo, folder: URL) async throws {
        let game = SteamOwnedGame(info)
        let drive = LibraryModel.drive
        let choice = await Task.detached(priority: .userInitiated) {
            Self.chooseExecutable(folder: folder, options: game.launch, drive: drive)
        }.value
        guard let choice else {
            throw SteamError.chunkDownloadFailed("The download finished, but no Windows program was found in it.")
        }
        var entry = try LibraryModel.inspect(choice.url)
        entry.title = info.name
        entry.steamAppID = game.id
        entry.steamID = game.id
        entry.steamNative = true
        entry.steamInstalled = true
        entry.steamBuildID = game.buildID
        entry.steamInstallPath = SteamPaths.relative(folder, drive: drive)
        entry.arguments = choice.arguments
        entry.folderBytes = manifestSize(appID: game.id)
        entry.metadataChecked = Date()
        if LibraryFlags.enabled("MADEIRA_STEAM_APPID_FILE") {
            // Valve's documented steam_appid.txt: identifies the app to the
            // Steam API when the program is started directly. Ownership is
            // still checked by the Steam client.
            try? "\(game.id)".write(to: choice.url.deletingLastPathComponent().appendingPathComponent("steam_appid.txt"),
                                   atomically: true, encoding: .ascii)
        }
        LibraryModel.shared.upsertNativeSteam(entry)
        SteamLog.event("[steam-depot] ml1310 library entry app=\(game.id) exe-source=\(choice.source) bits=\(entry.bits)")
    }

    private func manifestSize(appID: Int) -> Int64? {
        let file = SteamInstallPaths.steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: file), var parser = try? SteamKeyValues(data),
              let state = try? parser.read()["appstate"], let text = state["sizeondisk"]?.string else { return nil }
        return Int64(text)
    }

    /// Deletes an app's install folder, manifest and journal. Only paths
    /// strictly inside the managed steamapps/common folder are removed.
    nonisolated static func deleteInstallFiles(appID: Int, folderName: String) {
        let fm = FileManager.default
        let common = SteamInstallPaths.common.resolvingSymlinksInPath().standardizedFileURL
        let folder = common.appendingPathComponent(DepotDownloader.safeFolderName(folderName)).resolvingSymlinksInPath().standardizedFileURL
        if folder.path.hasPrefix(common.path + "/"), folder.deletingLastPathComponent().path == common.path {
            try? fm.removeItem(at: folder)
        }
        try? fm.removeItem(at: SteamInstallPaths.steamApps.appendingPathComponent("appmanifest_\(appID).acf"))
        try? fm.removeItem(at: SteamInstallPaths.steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
    }

    func uninstall(_ entry: LibraryEntry) {
        guard entry.steamNative == true, let appID = entry.steamAppID else { return }
        pause(appID); downloads[appID] = nil
        let folderName = entry.steamInstallPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? game(appID)?.folderName ?? ""
        LibraryModel.shared.removeSteamInstall(entry.id)
        Task.detached(priority: .utility) {
            Self.deleteInstallFiles(appID: appID, folderName: folderName)
        }
        SteamLog.event("[steam-depot] ml1310 uninstalled app=\(appID)")
    }

    // MARK: Executables

    struct ExecutableChoice { var url: URL; var arguments: String; var source: String }

    private nonisolated static let helperNames = ["unins", "vcredist", "vc_redist", "dxsetup", "dotnet", "crashhandler", "crashreport",
                                      "crashpad", "prereq", "redist", "setup", "installer", "easyanticheat", "eac_", "be_service",
                                      "launcherhelper", "cefprocess", "webhelper", "updater", "touchup"]

    /// Prefer Steam's own launch entries (default type, 64-bit or neutral
    /// first), falling back to the most likely program in the folder.
    nonisolated static func chooseExecutable(folder: URL, options: [SteamLaunchOption], drive: URL) -> ExecutableChoice? {
        func rank(_ option: SteamLaunchOption) -> Int {
            (option.type.isEmpty || option.type == "default" ? 0 : 10) + (option.arch == "64" ? 0 : option.arch.isEmpty ? 1 : 2)
        }
        for option in options.sorted(by: { rank($0) < rank($1) }) {
            let relative = option.executable.replacingOccurrences(of: "\\", with: "/")
            guard let candidate = SteamPaths.safeRelative(relative, under: folder),
                  let url = SteamPaths.existing(candidate, drive: drive),
                  (try? LibraryModel.inspect(url)) != nil else { continue }
            return ExecutableChoice(url: url, arguments: option.arguments, source: "launch")
        }
        let candidates = executableCandidates(folder: folder)
        let preferred = candidates.filter { url in !helperNames.contains { url.lastPathComponent.lowercased().contains($0) } }
        let pool = preferred.isEmpty ? candidates : preferred
        let best = pool.min { a, b in
            let da = a.pathComponents.count, db = b.pathComponents.count
            if da != db { return da < db }
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa > sb
        }
        return best.map { ExecutableChoice(url: $0, arguments: "", source: "scan") }
    }

    /// Windows programs inside an install folder, at most four levels deep.
    nonisolated static func executableCandidates(folder: URL) -> [URL] {
        var found: [URL] = []
        let base = folder.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var visited = 0
        while let url = walker.nextObject() as? URL {
            visited += 1
            if visited > 50_000 { break }
            if url.pathComponents.count - base > 4 { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe", (try? LibraryModel.inspect(url)) != nil { found.append(url) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Messages

    static func message(_ error: Error) -> String {
        if let steam = error as? SteamError, let text = steam.errorDescription { return text }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection. Connect and try again."
            case .timedOut: return "Steam did not respond in time. Try again."
            default: return "A network error occurred (\(url.code.rawValue)). Try again."
            }
        }
        return error.localizedDescription
    }

    /// Short, credential-free reason for the log.
    static func reason(_ error: Error) -> String {
        switch error {
        case SteamError.logonDenied(let code): return "logon-\(code)"
        case SteamError.invalidCredentials: return "credentials"
        case SteamError.rateLimited: return "rate-limited"
        case SteamError.connectionTimeout: return "timeout"
        case SteamError.depotKeyNotFound: return "depot-key"
        case SteamError.depotNotFound: return "no-windows-depot"
        case SteamError.insufficientDiskSpace: return "disk-space"
        case SteamError.checksumMismatch: return "checksum"
        case SteamError.decompressionFailed: return "decompress"
        case SteamError.chunkDecodeFailed(let format): return "decode-\(format)"
        case SteamError.manifestFetchFailed: return "manifest"
        case SteamError.chunkDownloadFailed: return "chunk"
        case let url as URLError: return "url-\(url.code.rawValue)"
        default: return String(describing: type(of: error))
        }
    }
}

/// ml1420: while a game starts through the Windows Steam client, follow what
/// the client is downloading for it. Every 2 s (off the main thread) the
/// client's install records are read: the launched app's
/// appmanifest_<appid>.acf and those of the apps that own its shared depots.
/// Read-only. A record the client is rewriting keeps its last complete
/// reading. Stops when the session ends. MADEIRA_STEAM_CLIENT_PROGRESS=0 disables.
/// Hook: `LibraryModel.begin` / `finish`; views observe `progress`.
final class SteamClientProgressModel: ObservableObject {
    static let shared = SteamClientProgressModel()
    /// nil when no client-routed session is being followed.
    @Published private(set) var progress: SteamClientProgress?

    private let queue = DispatchQueue(label: "madeira.steam-client-progress", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private var busy = false
    private var session: Session?

    /// State touched only on `queue`.
    private final class Session {
        let appID: Int
        let client: String?
        let drive: URL
        var tracker: SteamClientProgressTracker
        var log = SteamClientProgressLog()
        var libraries: [URL] = []
        var librariesRead = -Double.infinity
        init(appID: Int, client: String?, drive: URL) {
            self.appID = appID; self.client = client; self.drive = drive
            tracker = SteamClientProgressTracker(appID: appID)
        }
        func poll(now: Double) -> (SteamClientProgress, String?) {
            if now - librariesRead >= 60 {
                librariesRead = now
                let clientApps = client.flatMap { SteamPaths.safeRelative($0, under: drive) }?
                    .deletingLastPathComponent().appendingPathComponent("steamapps", isDirectory: true)
                libraries = SteamClientProgressTracker.libraries(primary: [clientApps, SteamInstallPaths.steamApps].compactMap { $0 }, drive: drive)
            }
            tracker.poll(libraries: libraries)
            let progress = tracker.progress
            return (progress, log.line(progress, now: now))
        }
    }

    /// Main thread. Starts following `entry` when it is launched through the client.
    func start(_ entry: LibraryEntry) {
        stop()
        guard entry.usesSteam, let appID = entry.steamAppID, SteamPaths.validAppID(appID),
              LibraryFlags.enabled("MADEIRA_STEAM_CLIENT_PROGRESS") else { return }
        generation += 1
        busy = false
        session = Session(appID: appID, client: entry.steamNative == true ? entry.steamClientPath : entry.relativePath,
                          drive: LibraryModel.drive)
        progress = SteamClientProgress()
        LogStore.shared.log("[steam-progress] ml1420 start app=\(appID)")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    /// Main thread. Safe to call when nothing is being followed.
    func stop() {
        timer?.invalidate(); timer = nil
        guard let session else { return }
        self.session = nil
        generation += 1
        busy = false
        LogStore.shared.log("[steam-progress] ml1420 stop app=\(session.appID) last=\(progress?.phase.name ?? "idle")")
        progress = nil
    }

    private func tick() {
        guard !busy, let session else { return }
        busy = true
        let token = generation
        queue.async { [weak self] in
            let (next, line) = session.poll(now: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.busy = false
                if let line { LogStore.shared.log("[steam-progress] ml1420 app=\(session.appID) " + line) }
                if self.progress != next { self.progress = next }
            }
        }
    }
}
