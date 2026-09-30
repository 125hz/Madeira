// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The library and download model is adapted from the account model built
// around Jfishin's Madeira Steam client (used with the author's permission,
// see docs/STEAM_SIGNIN.md, "Provenance"); the integration with sign-in,
// Madeira Dock and the library is 125hz's.

import CryptoKit
import Foundation
import UIKit

// The account's owned Steam games and their downloads (docs/STEAM_LIBRARY.md).
//
// Steam itself decides ownership: the library comes from the account's
// licenses over a Steam connection, and depot keys are only issued for
// depots the account owns. Games download unmodified from Steam's content
// servers into Madeira Dock's Steam library folder (SteamInstall.swift) and
// start through Madeira Dock like any installed game. The only sign-in is
// SteamSignIn's: the connection reads its token from the same Keychain item
// and never stores one of its own. `env.MADEIRA_STEAM_LIBRARY = 0` turns the
// whole thing off (the library then lists installed games only).
// Log tags: [steam-library], [steam-depot], [steam-playtime], [steam-account]
// (App IDs, counts and short reason codes; never account data).

// MARK: - Owned games

struct SteamOwnedGame: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var installDir: String
    var buildID: Int
    /// Store artwork names from PICS (see SteamArtwork); nil in older caches.
    var libraryCapsule: String?
    var libraryHero: String?
    var headerImage: String?
    var parentID: Int?
    /// Steam's launch configuration, for "Start with: The game" (SteamDirectStart);
    /// nil in older caches, which then ask Steam once (SteamOwnedLibrary.launchOptions).
    var launches: [SteamLaunchOption]?

    init(_ info: SteamAppInfo) {
        id = Int(info.appID)
        name = info.name
        installDir = info.installDir
        buildID = Int(info.buildID)
        libraryCapsule = info.libraryCapsule; libraryHero = info.libraryHero; headerImage = info.headerImage
        parentID = info.parentID.map(Int.init)
        launches = info.launches
    }

    var folderName: String { SteamInstallFiles.safeFolderName(installDir.isEmpty ? "app_\(id)" : installDir) }
}

// MARK: - Playtime

/// Steam's own playtime record for one app (Player.GetOwnedGames, the
/// signed-in account's own library through its existing connection): minutes
/// played in total and the last time played (Unix seconds, 0 = never).
struct SteamPlaytime: Codable, Equatable, Sendable {
    var minutes: Int
    var lastPlayed: Int

    var played: String? {
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min played" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f hrs played", hours) : "\(Int(hours.rounded())) hrs played"
    }

    func lastPlayedText(formatter: DateFormatter = SteamPlaytime.dayFormatter) -> String? {
        guard lastPlayed > 0 else { return nil }
        return "Last played " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastPlayed)))
    }

    /// "12.5 hrs played · Last played Yesterday"
    var summary: String? {
        let parts = [played, lastPlayedText()].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .none; formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// CPlayer_GetOwnedGames_Response: games = 2 { appid = 1, playtime_forever = 4, rtime_last_played = 11 }.
    static func parse(_ data: Data) throws -> [Int: SteamPlaytime] {
        var decoder = ProtobufDecoder(data)
        var result: [Int: SteamPlaytime] = [:]
        while let tag = try decoder.readTag() {
            guard tag.fieldNumber == 2, tag.wireType == .lengthDelimited else { try decoder.skip(wireType: tag.wireType); continue }
            var game = ProtobufDecoder(try decoder.readBytes())
            var app = 0, minutes = 0, last = 0
            while let field = try game.readTag() {
                switch (field.fieldNumber, field.wireType) {
                case (1, .varint): app = Int(truncatingIfNeeded: Int32(truncatingIfNeeded: try game.readVarint()))
                case (4, .varint): minutes = Int(truncatingIfNeeded: Int32(truncatingIfNeeded: try game.readVarint()))
                case (11, .varint): last = Int(truncatingIfNeeded: UInt32(truncatingIfNeeded: try game.readVarint()))
                default: try game.skip(wireType: field.wireType)
                }
            }
            if app > 0, minutes > 0 || last > 0 { result[app] = SteamPlaytime(minutes: max(0, minutes), lastPlayed: max(0, last)) }
            if result.count > 100_000 { break }
        }
        return result
    }
}

// MARK: - The account between the app and a game session

/// One Steam account, two possible users: the app's own connection (library,
/// playtime, downloads) and Valve's client in a game session, to which Madeira
/// Dock hands the same sign-in. A second logon with the same account replaces
/// the first one's session, so only one may be logged on: the app's connection
/// logs off, and its socket is closed, before Dock writes the one-use sign-in
/// transfer, and it comes back only after the game session ended.
/// Foundation only (check-steam-library.py compiles and runs it).
@MainActor final class SteamConnectionGate {
    private let closeConnection: @MainActor () async -> Void
    private let reopenConnection: @MainActor () -> Void
    /// The app's connection may be used (no game session holds the account).
    private(set) var open = true
    /// Madeira Dock holds the account: from before its sign-in transfer is
    /// written until its session ended (or its start failed).
    private(set) var heldForDock = false
    private var closing: Task<Void, Never>?

    /// `close` logs the app's connection off and returns once its socket is
    /// closed; `reopen` lets it connect again.
    init(close: @escaping @MainActor () async -> Void, reopen: @escaping @MainActor () -> Void) {
        closeConnection = close
        reopenConnection = reopen
    }

    /// A game session starts. Idempotent: the task finishes when the socket is closed.
    @discardableResult func close() -> Task<Void, Never> {
        if let closing { return closing }
        open = false
        let task = Task { await closeConnection() }
        closing = task
        return task
    }

    /// Madeira Dock is about to hand the sign-in to Valve's client: returns only
    /// once the app's connection is logged off and closed. Until `releaseDock()`
    /// the connection stays closed whatever else happens.
    func holdForDock() async {
        heldForDock = true
        await close().value
    }

    /// Madeira Dock's session ended, or its start failed.
    func releaseDock() { heldForDock = false }

    /// Lets the app's connection back when no game session runs and Dock does
    /// not hold the account. Returns whether it reopened.
    @discardableResult func reopen(sessionRunning: Bool) -> Bool {
        guard !open, !sessionRunning, !heldForDock else { return false }
        open = true
        closing = nil
        reopenConnection()
        return true
    }
}

// MARK: - Model

@MainActor
final class SteamOwnedLibrary: ObservableObject {
    static let shared = SteamOwnedLibrary()

    /// Off with `env.MADEIRA_STEAM_LIBRARY = 0`, or without Madeira Dock (a
    /// downloaded game starts through it).
    static var enabled: Bool { MadeiraDock.enabled && SteamSignIn.flag("MADEIRA_STEAM_LIBRARY", default: true) }

    @Published private(set) var signedIn = false
    @Published private(set) var owned: [SteamOwnedGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var libraryUpdated: Date?
    /// Steam's playtime and last played, by App ID.
    @Published private(set) var playtime: [Int: SteamPlaytime] = [:]
    @Published var error: String?

    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var progress = SteamDownloadProgress()
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var queue: [Int] = []
    private var active: (id: Int, task: Task<Void, Never>)?
    /// A game session runs: downloads wait, and the Steam connection stays closed.
    private var inSession = false
    private var resumeAfterSession = Set<Int>()
    /// Downloads paused because iOS ended Madeira's background time.
    private var resumeAfterBackgroundIDs = Set<Int>()

    private let session = SteamSession()
    /// The app's connection is closed while a game session (or Madeira Dock) holds the account.
    private lazy var gate = SteamConnectionGate(close: { [session] in await session.suspend() },
                                                reopen: { [session] in session.resume() })
    private lazy var fetcher = SteamLibraryFetcher(session: session)
    private lazy var downloader = DepotDownloader(session: session)
    private var started = false
    /// Which account the cached list belongs to: a SHA-256 of the account name,
    /// so the cache file holds no name.
    private var cachedAccount: String?
    private static func accountKey(_ name: String?) -> String? {
        name.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    private var timer: Timer?

    var hasActiveDownload: Bool { downloads.values.contains { $0.state == .active || $0.state == .queued } }
    func game(_ appID: Int) -> SteamOwnedGame? { owned.first { $0.id == appID } }

    // MARK: Files

    static var drive: URL { MadeiraDock.drive }
    static var steamApps: URL { SteamInstallPaths.steamApps(drive: drive) }
    private static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Madeira", isDirectory: true)
    }
    private static var cacheURL: URL { supportFolder.appendingPathComponent("steam-library.json") }
    private static var playtimeURL: URL { supportFolder.appendingPathComponent("steam-playtime.json") }
    private struct Cache: Codable { var version: Int; var updated: Date; var account: String; var games: [SteamOwnedGame] }

    // MARK: Lifecycle

    /// Called when the library shows the Steam section. Reads the cached list
    /// and refreshes it when it is older than six hours; once per app run.
    func start() {
        guard Self.enabled, !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: SteamSignIn.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signInChanged() }
        }
        SteamDownloadBackground.shared.attach(self)
        signedIn = SteamSignIn.isSignedIn
        if signedIn { loadCaches() }
        SteamLog.event("[steam-library] start signed-in=\(signedIn ? 1 : 0) cached=\(owned.count)")
        if signedIn { refreshIfStale() }
    }

    private func refreshIfStale() {
        if Date().timeIntervalSince(libraryUpdated ?? .distantPast) > 6 * 3600 {
            Task { await refreshLibrary(interactive: false) }
        } else {
            Task { await refreshPlaytime() }   // playtime changes more often than the library
        }
    }

    /// Sign-in was stored or removed (SteamSignIn.didChange).
    private func signInChanged() {
        let now = SteamSignIn.isSignedIn
        guard now != signedIn || (now && Self.accountKey(SteamSignIn.accountName) != cachedAccount) else { return }
        signedIn = now
        if !now {
            for id in Array(downloads.keys) { pause(id) }
            session.logoff()
            clearCaches()
            owned = []; libraryUpdated = nil; playtime = [:]; downloads = [:]
            SteamLog.event("[steam-library] signed out: list cleared")
        } else {
            owned = []; libraryUpdated = nil; playtime = [:]
            Task { await refreshLibrary(interactive: true) }
        }
    }

    private func loadCaches() {
        let account = Self.accountKey(SteamSignIn.accountName)
        cachedAccount = account
        if let data = try? Data(contentsOf: Self.cacheURL), data.count <= 64 << 20,
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2, cache.account == account {
            owned = cache.games; libraryUpdated = cache.updated
        }
        if !owned.isEmpty, let data = try? Data(contentsOf: Self.playtimeURL), data.count <= 16 << 20,
           let cached = try? JSONDecoder().decode([Int: SteamPlaytime].self, from: data) {
            playtime = cached
        }
    }

    private func clearCaches() {
        cachedAccount = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.playtimeURL)
    }

    // MARK: Library

    /// `interactive` refreshes (sign-in, the Refresh button) tell the user
    /// about failures; the automatic one only logs transient ones, so an
    /// offline start does not raise an alert.
    func refreshLibrary(interactive: Bool = true) async {
        guard Self.enabled, signedIn, !refreshing, !inSession else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let apps = try await fetcher.fetchOwnedApps()
            let games = apps.filter(\.installableOnWindows).map(SteamOwnedGame.init)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            owned = games
            libraryUpdated = Date()
            cachedAccount = Self.accountKey(SteamSignIn.accountName)
            writeCache()
            SteamLog.event("[steam-library] owned apps=\(apps.count) windows-installable=\(games.count)")
            await refreshPlaytime()
        } catch {
            handleSessionError(error, context: "library", report: interactive)
        }
    }

    private func writeCache() {
        guard let account = cachedAccount, let updated = libraryUpdated else { return }
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(version: 2, updated: updated, account: account, games: owned))
            .write(to: Self.cacheURL, options: .atomic)
    }

    /// Steam's launch configuration for an owned app, for "Start with: The game"
    /// (SteamDirectStart): from the cached library, else asked of Steam once over the
    /// app's own connection (signed in, no session running) and kept in the cache.
    /// nil when it cannot be had; the Program picker then decides.
    func launchOptions(appID: Int) async -> [SteamLaunchOption]? {
        if let cached = game(appID)?.launches { return cached }
        guard Self.enabled, signedIn, !inSession, appID > 0, appID <= Int(UInt32.max) else { return nil }
        do {
            guard let info = try await fetcher.fetchAppInfo(appID: UInt32(appID)) else { return nil }
            if let index = owned.firstIndex(where: { $0.id == appID }) {
                owned[index].launches = info.launches
                writeCache()
            }
            SteamLog.event("[steam-start] launch configuration app=\(appID) entries=\(info.launches.count)")
            return info.launches
        } catch {
            handleSessionError(error, context: "start", report: false)
            return nil
        }
    }

    private func handleSessionError(_ error: Error, context: String, report: Bool = true) {
        if case SteamError.logonDenied(let code) = error, SteamError.signInExpiredCodes.contains(code) {
            self.error = "Your Steam sign-in is no longer valid. Sign out and sign in again in Settings › Steam."
            SteamLog.event("[steam-account] stored sign-in rejected code=\(code)")
            return
        }
        if report { self.error = SteamSignIn.message(error) }
        SteamLog.event("[steam-\(context)] failed reason=\(Self.reason(error)) reported=\(report ? 1 : 0)")
    }

    // MARK: Playtime

    /// The account's own Player.GetOwnedGames over the existing connection.
    private func requestOwnedGamesPlaytime() async throws -> Data {
        try await session.ensureConnected()
        var request = ProtobufEncoder()
        request.writeUInt64(fieldNumber: 1, value: session.steamID)   // steamid
        request.writeBool(fieldNumber: 2, value: false)                // include_appinfo
        request.writeBool(fieldNumber: 3, value: true)                 // include_played_free_games
        request.writeBool(fieldNumber: 5, value: true)                 // include_free_sub
        return try await session.callServiceMethod(method: .getOwnedGames, body: request.data, timeout: 20)
    }

    func refreshPlaytime() async {
        guard Self.enabled, signedIn, !inSession else { return }
        do {
            let parsed = try SteamPlaytime.parse(try await requestOwnedGamesPlaytime())
            playtime = parsed
            try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(parsed).write(to: Self.playtimeURL, options: .atomic)
            SteamLog.event("[steam-playtime] apps=\(parsed.count)")
        } catch {
            SteamLog.event("[steam-playtime] unavailable reason=\(Self.reason(error))")
        }
    }

    // MARK: Game sessions

    /// A game session is starting (ContentView starts the Wine session) or ended.
    /// Downloads pause for a session (memory and I/O belong to the game) and
    /// continue afterwards; the app's Steam connection is closed for the whole
    /// session (SteamConnectionGate). Idempotent.
    func sessionChanged(active running: Bool) {
        guard Self.enabled, running != inSession else { return }
        if running {
            inSession = true
            if let current = active {
                resumeAfterSession.insert(current.id)
                current.task.cancel()
            }
            for id in queue { resumeAfterSession.insert(id); downloads[id]?.state = .paused }
            queue.removeAll()
            gate.close()
            SteamLog.event("[steam-depot] paused for a game session count=\(resumeAfterSession.count)")
        } else {
            // Madeira Dock may still hold the account (dockEnded() releases it).
            guard gate.reopen(sessionRunning: false) else { return }
            inSession = false
            let resume = resumeAfterSession.sorted()
            resumeAfterSession.removeAll()
            for id in resume { install(id) }
            if !resume.isEmpty { SteamLog.event("[steam-depot] resumed after a game session count=\(resume.count)") }
            // Steam records the session's playtime when the game ends.
            Task { try? await Task.sleep(nanoseconds: 5_000_000_000); await self.refreshPlaytime() }
        }
    }

    /// Before Madeira Dock writes the one-use sign-in transfer for Valve's
    /// client (ContentView.startDock): downloads stop (the running one is
    /// awaited), and the app's own connection logs off and its socket closes.
    /// Returns when the account is free; the connection stays closed until
    /// `dockEnded()` and the end of the session.
    func prepareDock() async {
        let running = active?.task
        sessionChanged(active: true)
        await running?.value
        await gate.holdForDock()
        SteamLog.event("[steam-library] connection closed for Madeira Dock")
    }

    /// Madeira Dock's session ended, or its start failed (MadeiraDockModel,
    /// ContentView.startDock): the connection comes back once no session runs.
    func dockEnded() {
        guard gate.heldForDock else { return }
        gate.releaseDock()
        reconcileSession()
    }

    /// Whether a Wine session runs in this app run (any interface).
    private var sessionRunning: Bool {
        LibraryModel.shared.current != nil || wine_process_is_running() != 0 || wineserver_is_running() != 0
    }

    /// Compares the app's session state with what downloads assumed. Called
    /// when the section appears, when the app becomes active and every few
    /// seconds while something downloads.
    func reconcileSession() {
        sessionChanged(active: sessionRunning)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileSession()
                if !self.hasActiveDownload { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    // MARK: Background

    /// iOS ended Madeira's background time: pause everything, to continue
    /// when Madeira is active again (SteamDownloadBackground). Finished
    /// chunks are journaled, so nothing is lost.
    func pauseForBackground() {
        if let current = active { resumeAfterBackgroundIDs.insert(current.id); current.task.cancel() }
        for id in queue { resumeAfterBackgroundIDs.insert(id); downloads[id]?.state = .paused }
        queue.removeAll()
        SteamLog.event("[steam-depot] paused for the background count=\(resumeAfterBackgroundIDs.count)")
    }

    func resumeAfterBackground() {
        guard !resumeAfterBackgroundIDs.isEmpty else { return }
        let ids = resumeAfterBackgroundIDs.sorted()
        resumeAfterBackgroundIDs.removeAll()
        for id in ids { install(id) }
        SteamLog.event("[steam-depot] resumed after the background count=\(ids.count)")
    }

    // MARK: Downloads

    /// Whether Steam lists a newer build than the installed record.
    func updateAvailable(appID: Int, installedBuild: Int?) -> Bool {
        guard let installedBuild, let latest = game(appID)?.buildID, latest > 0 else { return false }
        return latest > installedBuild
    }

    func hasPartialDownload(_ appID: Int) -> Bool {
        DepotDownloader.hasPartialDownload(appID: UInt32(appID), steamApps: Self.steamApps)
    }

    /// Installs or updates a game: queues it and starts when nothing else downloads.
    func install(_ appID: Int) {
        guard Self.enabled else { return }
        guard signedIn else { error = "Sign in to Steam to download games."; return }
        if active?.id == appID || queue.contains(appID) { return }
        if inSession {
            resumeAfterSession.insert(appID); downloads[appID] = Download(state: .paused); return
        }
        var item = downloads[appID] ?? Download(state: .queued)
        item.state = .queued
        downloads[appID] = item
        queue.append(appID)
        startTimer()
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

    /// Stops a download. A first-time install also loses its partial files;
    /// an update of an installed game is only paused, never deleted.
    func cancelInstall(_ appID: Int, installed: Bool) {
        let running = active?.id == appID ? active?.task : nil
        pause(appID)
        downloads[appID] = nil
        guard !installed, let game = game(appID) else { return }
        let apps = Self.steamApps
        Task { @MainActor in
            await running?.value
            SteamInstallFiles.delete(appID: appID, folderName: game.folderName, steamApps: apps)
            SteamLog.event("[steam-depot] cancelled app=\(appID) partial-files-removed=1")
        }
    }

    /// Checks an installed game's files against the current Steam build and
    /// downloads what is missing or changed: the downloader compares every chunk
    /// already on disk by its SHA-1 before fetching it.
    func repair(_ appID: Int) {
        SteamLog.event("[steam-repair] app=\(appID) requested=1")
        install(appID)
    }

    /// Removes an install that Madeira's downloads own (its library folder is
    /// Madeira Dock's own), with its library entry (its per-game settings).
    func uninstall(_ game: DockGame) {
        guard SteamInstallPaths.isManaged(library: game.library), !inSession else { return }
        pause(game.id); downloads[game.id] = nil
        LibraryModel.shared.removeSteam(appID: game.id)
        // A reinstall evaluates the game's one-time installs again.
        DockInstallers.setRunsNext(game.id, true, prefix: MadeiraDock.prefix)
        let apps = Self.steamApps, id = game.id, folder = game.installDir
        Task.detached(priority: .utility) {
            SteamInstallFiles.delete(appID: id, folderName: folder, steamApps: apps)
            await MainActor.run { SteamGamesModel.shared.refresh() }
        }
        SteamLog.event("[steam-depot] uninstalled app=\(id)")
    }

    private func pump() {
        guard active == nil, !inSession, !queue.isEmpty else { return }
        let appID = queue.removeFirst()
        downloads[appID]?.state = .active
        SteamDownloadBackground.shared.downloadStarted(appID: appID, name: game(appID)?.name ?? "Steam game")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(appID)
        }
        active = (appID, task)
    }

    private func run(_ appID: Int) async {
        var outcome = SteamDownloadBackground.Outcome.paused
        do {
            guard let info = try await fetcher.fetchInstallInfo(appID: UInt32(appID)) else {
                throw SteamError.appInfoNotFound(UInt32(appID))
            }
            try FileManager.default.createDirectory(at: SteamInstallPaths.common(drive: Self.drive), withIntermediateDirectories: true)
            let folder = try await downloader.install(info, steamApps: Self.steamApps,
                                                      ownedDepots: { [weak self] in try? await self?.fetcher.ownedDepotIDs() }) { [weak self] progress in
                self?.downloads[appID]?.progress = progress
                SteamDownloadBackground.shared.progress(progress)
            }
            downloads[appID] = nil
            // The install record is written last: the game is now "installed" for Dock, and it
            // gets its library entry (its Game details page and settings; an existing one is kept).
            LibraryModel.shared.upsertSteam(DockGame(id: appID, name: info.name, installDir: folder.lastPathComponent,
                                                     library: SteamInstallPaths.libraryRelative, installed: true,
                                                     customExecutables: false), title: info.name)
            SteamLog.event("[steam-depot] library entry app=\(appID)")
            SteamGamesModel.shared.refresh()
            outcome = .completed
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                if downloads[appID] != nil { downloads[appID]?.state = .paused }
                SteamLog.event("[steam-depot] paused app=\(appID)")
            } else if case SteamError.logonDenied = error {
                downloads[appID]?.state = .failed(SteamSignIn.message(error))
                handleSessionError(error, context: "depot")
                outcome = .failed(SteamSignIn.message(error))
            } else {
                downloads[appID]?.state = .failed(SteamSignIn.message(error))
                SteamLog.event("[steam-depot] failed app=\(appID) reason=\(Self.reason(error))")
                outcome = .failed(SteamSignIn.message(error))
            }
        }
        active = nil
        SteamDownloadBackground.shared.downloadEnded(appID: appID, name: game(appID)?.name ?? "Steam game",
                                                     outcome: outcome, queueEmpty: queue.isEmpty)
        pump()
    }

    // MARK: Messages

    /// Short, credential-free reason for the log.
    static func reason(_ error: Error) -> String {
        switch error {
        case SteamError.logonDenied(let code): return "logon-\(code)"
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
