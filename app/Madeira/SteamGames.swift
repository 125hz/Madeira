// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Steam games in the library (docs/LIBRARY.md, "Steam setup", and
// docs/STEAM_LIBRARY.md): the games Steam has installed in the prefix, which is
// Madeira Dock's own discovery (MadeiraDock.games: Steam's
// appmanifest_<appid>.acf records in the client's library and the other C:
// libraries its libraryfolders.vdf lists), and the account's owned games that
// are not installed yet (SteamOwnedLibrary), which can be installed here.
// Play starts an installed game through Madeira Dock's launch path
// (ContentView.startDock), so Valve's own client signs in, checks the licence
// and starts it. No program names are involved: a game is its App ID.
// Log tag: [steam-games] (App IDs and counts only).

// MARK: - Rules (Foundation only; build/host-tests/check-onboarding.py compiles this part)

enum SteamGamesRules {
    /// One game of the section: installed by Steam, owned by the account, or both.
    struct Item: Identifiable, Equatable {
        let id: Int
        var name: String
        var installed: DockGame?
        var owned: SteamOwnedGame?
    }

    /// What a game's card and sheet say about it.
    enum Status: Equatable {
        case notInstalled, partlyInstalled, installed, updateAvailable
        case queued, downloading(Int), paused, failed

        var label: String {
            switch self {
            case .notInstalled: return "Not installed"
            case .partlyInstalled: return "Not fully installed"
            case .installed: return "Madeira Dock"
            case .updateAvailable: return "Update available"
            case .queued: return "Waiting"
            case .downloading(let percent): return "Downloading \(percent)%"
            case .paused: return "Paused"
            case .failed: return "Download failed"
            }
        }
    }

    /// A download's state, as far as the status needs it.
    enum Transfer: Equatable { case queued, active(percent: Int), paused, failed }

    static func status(installed: DockGame?, transfer: Transfer?, updateAvailable: Bool) -> Status {
        if let transfer {
            switch transfer {
            case .queued: return .queued
            case .active(let percent): return .downloading(max(0, min(100, percent)))
            case .paused: return .paused
            case .failed: return .failed
            }
        }
        guard let installed else { return .notInstalled }
        if !installed.installed { return .partlyInstalled }
        return updateAvailable ? .updateAvailable : .installed
    }

    /// The games of both lists by App ID, installed ones first (each group by
    /// name), filtered by the library's search text. A game Steam installed
    /// but the account does not list (or that is listed before the library
    /// loaded) keeps the name of its install record.
    static func items(installed: [DockGame], owned: [SteamOwnedGame], search: String) -> [Item] {
        var byID: [Int: Item] = [:]
        for game in owned { byID[game.id] = Item(id: game.id, name: game.name, installed: nil, owned: game) }
        for game in installed {
            if var item = byID[game.id] { item.installed = game; byID[game.id] = item }
            else { byID[game.id] = Item(id: game.id, name: game.name, installed: game, owned: nil) }
        }
        let text = search.trimmingCharacters(in: .whitespaces)
        let all = byID.values.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
        return all.sorted {
            let a = $0.installed != nil, b = $1.installed != nil
            if a != b { return a }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Whether the library shows the Steam section: Dock is available, and there is
    /// a game to show, a sign-in whose library is on its way, or (with the owned
    /// library on) a signed-out account the section invites to sign in.
    static func showsSection(dock: Bool, library: Bool = false, signedIn: Bool, count: Int) -> Bool {
        dock && (count > 0 || signedIn || library)
    }

    /// Whether the section shows its "Sign in to Steam" card instead of the account's games.
    static func showsSignIn(library: Bool, signedIn: Bool) -> Bool { library && !signedIn }

    /// Why Play is not offered yet, or nil when Dock can be asked to start the game.
    /// Valve's client still decides at launch.
    static func blocker(installed: Bool, client: Bool, signedIn: Bool, updating: Bool = false) -> String? {
        if !installed { return "Steam does not list this game as fully installed yet." }
        if updating { return "This game is being downloaded. Play is available when it is done." }
        if !client { return "Madeira Dock needs Valve's client components. Download them in Settings › Steam › Madeira Dock." }
        if !signedIn { return "Sign in to Steam in Settings › Steam to play." }
        return nil
    }

    /// Steam's public store artwork for an App ID (no account data).
    static func cover(_ appID: Int) -> URL? {
        guard appID > 0 else { return nil }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg")
    }

    static let assetBase = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/"

    /// A store artwork file name is a relative path of plain characters.
    static func safeAssetName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.hasPrefix("/") && !name.contains("..") &&
            name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }
    }

    /// Artwork candidates for an App ID, in order: the capsule named in the
    /// game's product info (newer apps publish it only under a hashed folder),
    /// the legacy path, the same for a demo's full game, then the header image.
    /// A card tries them one after another.
    static func artwork(appID: Int, owned: (Int) -> SteamOwnedGame?) -> [URL] {
        var urls: [URL] = []
        func add(_ url: URL?) { if let url, !urls.contains(url) { urls.append(url) } }
        func asset(_ id: Int, _ name: String?) -> URL? {
            guard let name, safeAssetName(name) else { return nil }
            return URL(string: assetBase + "\(id)/" + name)
        }
        func direct(_ id: Int) {
            add(asset(id, owned(id)?.libraryCapsule))
            add(cover(id))
        }
        direct(appID)
        if let parent = owned(appID)?.parentID, parent != appID { direct(parent) }
        add(asset(appID, owned(appID)?.headerImage))
        return urls
    }
}

// MARK: - Model

/// The games Steam has installed in the prefix (Dock's discovery, off the main
/// thread), with the build each Madeira-managed install records.
@MainActor final class SteamGamesModel: ObservableObject {
    static let shared = SteamGamesModel()
    @Published private(set) var games: [DockGame] = []
    /// `buildid` of each install in Madeira's own library folder, by App ID.
    @Published private(set) var builds: [Int: Int] = [:]
    private var scanning = false
    /// A refresh was asked for while a scan ran (an install record was just
    /// written): scan again once it ends.
    private var rescan = false
    private var lastCount = -1

    /// Reads the install records again, off the main thread.
    func refresh() {
        guard MadeiraDock.enabled else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let drive = MadeiraDock.drive
        Task.detached(priority: .utility) {
            let found = MadeiraDock.games(drive: drive)
            var builds: [Int: Int] = [:]
            for game in found where SteamInstallPaths.isManaged(library: game.library) && game.installed {
                if let build = SteamInstallFiles.buildID(appID: game.id, steamApps: SteamInstallPaths.steamApps(drive: drive)) {
                    builds[game.id] = build
                }
            }
            let recorded = builds
            await MainActor.run {
                self.scanning = false
                let again = self.rescan
                self.rescan = false
                if self.games != found { self.games = found }
                if self.builds != recorded { self.builds = recorded }
                if found.count != self.lastCount {
                    self.lastCount = found.count
                    LogStore.shared.log("[steam-games] installed=\(found.count) ready=\(found.filter(\.installed).count)")
                }
                if again { self.refresh() }
            }
        }
    }
}

// MARK: - Library section

private struct SteamGameSelection: Identifiable { let id: Int }

/// The library's Steam section: the account's games and the games Steam has
/// installed in the prefix, each started through Madeira Dock once installed.
struct SteamGamesSection: View {
    let search: String
    /// Madeira Dock's start (ContentView.startDock).
    let startDock: (DockGame, Bool) -> Void
    @ObservedObject private var model = SteamGamesModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("madeiraLibraryHideSteam") private var hidden = false
    @State private var selected: SteamGameSelection?
    @State private var showSignIn = false

    private var libraryEnabled: Bool { SteamOwnedLibrary.enabled }

    var body: some View {
        let owned = libraryEnabled ? steam.owned : []
        let items = SteamGamesRules.items(installed: model.games, owned: owned, search: search)
        let total = SteamGamesRules.items(installed: model.games, owned: owned, search: "").count
        Group {
            if SteamGamesRules.showsSection(dock: MadeiraDock.enabled, library: libraryEnabled,
                                            signedIn: libraryEnabled && steam.signedIn, count: total) {
                VStack(alignment: .leading, spacing: 14) {
                    LibrarySectionHeader(title: "Steam", count: total, collapsed: $hidden) {
                        Button { refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.font(.subheadline)
                            .disabled(steam.refreshing)
                    }
                    if hidden {
                        EmptyView()
                    } else {
                        // Signed out: the account's games need a sign-in; say so here rather
                        // than hiding the section until someone finds Settings › Steam.
                        if SteamGamesRules.showsSignIn(library: libraryEnabled, signedIn: steam.signedIn) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Sign in to Steam to see your games and install them.")
                                    .foregroundStyle(.secondary)
                                Button { showSignIn = true } label: {
                                    Label("Sign in to Steam", systemImage: "person.crop.circle")
                                }.buttonStyle(.borderedProminent)
                            }
                        }
                        if libraryEnabled, steam.signedIn, steam.refreshing, owned.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading your Steam library…").foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                        if items.isEmpty {
                            if total > 0 { Text("No Steam games match your search.").foregroundStyle(.secondary) }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 164), spacing: 12, alignment: .top)],
                                      alignment: .leading, spacing: 18) {
                                ForEach(items) { item in
                                    Button { selected = SteamGameSelection(id: item.id) } label: { SteamGameCell(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        // The library reappears after every session, so this also rereads after a game.
        .onAppear {
            model.refresh()
            if libraryEnabled { steam.start(); steam.reconcileSession() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh(); if libraryEnabled { steam.reconcileSession() } }
        }
        .sheet(item: $selected) { selection in SteamGameDetail(appID: selection.id, startDock: startDock) }
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .alert("Steam", isPresented: Binding(get: { steam.error != nil }, set: { if !$0 { steam.error = nil } })) {
            Button("OK", role: .cancel) { steam.error = nil }
        } message: { Text(steam.error ?? "") }
    }

    private func refreshAll() {
        model.refresh()
        if libraryEnabled && steam.signedIn { Task { await steam.refreshLibrary(interactive: true) } }
    }
}

// MARK: - Artwork

/// A game's artwork: its candidates in turn until one loads.
struct SteamGameArtwork: View {
    let appID: Int
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @State private var index = 0

    var body: some View {
        let urls = SteamGamesRules.artwork(appID: appID) { steam.game($0) }
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemFill)
                Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
                AsyncImage(url: index < urls.count ? urls[index] : nil) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    case .failure:
                        Color.clear.onAppear { if index + 1 < urls.count { index += 1 } }
                    default:
                        Color.clear
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: appID) { index = 0 }
    }
}

// MARK: - Cards

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

private extension SteamOwnedLibrary.Download {
    var transfer: SteamGamesRules.Transfer {
        switch state {
        case .queued: return .queued
        case .active: return .active(percent: Int(progress.fraction * 100))
        case .paused: return .paused
        case .failed: return .failed
        }
    }
}

private struct SteamGameCell: View {
    let item: SteamGamesRules.Item
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared

    var body: some View {
        let download = steam.downloads[item.id]
        let status = SteamGamesRules.status(installed: item.installed, transfer: download?.transfer,
                                            updateAvailable: steam.updateAvailable(appID: item.id, installedBuild: games.builds[item.id]))
        VStack(alignment: .leading, spacing: 6) {
            SteamGameArtwork(appID: item.id).aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { overlay(download) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .opacity(item.installed?.installed == true || download != nil ? 1 : 0.6)
            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(status.label)
                .font(.caption2.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.secondary)
            if let played = steam.playtime[item.id]?.played {
                Text(played).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(4).foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func overlay(_ download: SteamOwnedLibrary.Download?) -> some View {
        if let download {
            ZStack {
                Color.black.opacity(0.45)
                switch download.state {
                case .active:
                    ProgressView(value: download.progress.fraction).progressViewStyle(.circular).tint(.white)
                case .queued: Image(systemName: "clock").font(.title2).foregroundStyle(.white)
                case .paused: Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(.white)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

/// Progress, speed and the state of one download.
struct SteamDownloadStatus: View {
    let download: SteamOwnedLibrary.Download
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: download.progress.fraction)
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var caption: String {
        let p = download.progress
        switch download.state {
        case .queued: return "Waiting to start…"
        case .paused: return p.totalBytes > 0 ? "Paused at \(Int(p.fraction * 100))%" : "Paused"
        case .failed(let message): return message
        case .active:
            switch p.phase {
            case .preparing: return "Preparing download…"
            case .finishing: return "Finishing…"
            case .downloading:
                var parts = ["\(Int(p.fraction * 100))%", "\(formatBytes(Int64(p.doneBytes))) of \(formatBytes(Int64(p.totalBytes)))"]
                if p.bytesPerSecond > 0 {
                    parts.append("\(formatBytes(Int64(p.bytesPerSecond)))/s")
                    let left = Double(p.totalBytes - min(p.doneBytes, p.totalBytes)) / p.bytesPerSecond
                    if left.isFinite, left > 60 { parts.append("about \(Int(left / 60) + 1) min left") }
                }
                return parts.joined(separator: " · ")
            }
        }
    }
}

// MARK: - Game sheet

/// One Steam game: Play through Madeira Dock when it is installed, Install,
/// Update, Pause, Resume and Uninstall for downloads Madeira manages.
struct SteamGameDetail: View {
    let appID: Int
    let startDock: (DockGame, Bool) -> Void
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var partial = false
    @State private var confirmCancel = false
    @State private var confirmUninstall = false

    var body: some View {
        let owned = SteamOwnedLibrary.enabled ? steam.owned : []
        let item = SteamGamesRules.items(installed: games.games, owned: owned, search: "").first { $0.id == appID }
        let download = steam.downloads[appID]
        let installed = item?.installed
        let update = steam.updateAvailable(appID: appID, installedBuild: games.builds[appID])
        let managed = installed.map { SteamInstallPaths.isManaged(library: $0.library) } ?? false
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 20) {
                            SteamGameArtwork(appID: appID).frame(width: 120, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(item.name).font(.title2.bold())
                                if let summary = steam.playtime[appID]?.summary {
                                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                                }
                                primaryAction(installed: installed, download: download, update: update,
                                              canInstall: item.owned != nil)
                            }
                        }.padding(.vertical, 12)
                        if let installed, download == nil {
                            if let blocker = SteamGamesRules.blocker(installed: installed.installed, client: dock.clientInstalled,
                                                                     signedIn: signIn.signedIn) {
                                Text(blocker).font(.footnote).foregroundStyle(.orange)
                            }
                        } else if let installed, let blocker = SteamGamesRules.blocker(installed: installed.installed, client: true,
                                                                                       signedIn: true, updating: true) {
                            Text(blocker).font(.footnote).foregroundStyle(.orange)
                        }
                        if installed == nil, download == nil, !dock.clientInstalled {
                            Text("Madeira Dock needs Valve's client components to start games. Download them in Settings › Steam › Madeira Dock.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let download {
                        Section("Download") {
                            SteamDownloadStatus(download: download)
                            Button("Cancel download", role: .destructive) { confirmCancel = true }
                            if case .failed = download.state {
                                Text("Downloaded parts are kept. Try again to continue where it stopped.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if installed != nil {
                        Section {
                            Toggle("Smaller JIT pool (512 MB) for this launch", isOn: $dock.compactPool)
                        } footer: {
                            Text("Madeira Dock starts the game through Valve's own Steam client, without the Steam desktop window. Valve's client signs in with your account and decides whether the game may run.")
                        }
                        if let status = dock.status {
                            Section("Last Dock result") { Text(status) }
                        }
                    }
                    Section {
                        LabeledContent("App ID", value: String(appID))
                        if let installed { LabeledContent("Folder", value: installed.windowsInstallPath).font(.caption) }
                        if let freeSpace { LabeledContent("Free space on this device", value: formatBytes(freeSpace)) }
                    } footer: {
                        if item.owned != nil {
                            Text("Games download directly from Steam with your account into C:\\Program Files (x86)\\Steam\\steamapps\\common. Keep Madeira open while it downloads: it pauses shortly after you leave, and while a game is running, and continues when you return.")
                        }
                    }
                    if managed, download == nil {
                        Section {
                            Button("Uninstall", role: .destructive) { confirmUninstall = true }
                        } footer: {
                            Text("Deletes the game's files from this device. Your Steam library and your saves in Steam Cloud are not affected.")
                        }
                    }
                    Section {
                        Link(destination: URL(string: "https://store.steampowered.com/app/\(appID)/")!) {
                            Label("View in the Steam Store", systemImage: "safari")
                        }
                    }
                } else {
                    ContentUnavailableView("Game unavailable", systemImage: "questionmark.square.dashed",
                                           description: Text("Refresh your Steam library and try again."))
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { dock.refresh(); signIn.refresh() }
            .task(id: download?.state) {
                partial = steam.hasPartialDownload(appID)
                let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                freeSpace = values?.volumeAvailableCapacityForImportantUsage
            }
            .confirmationDialog("Cancel this download?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button(installed == nil ? "Cancel and delete downloaded files" : "Cancel the update", role: .destructive) {
                    steam.cancelInstall(appID, installed: installed != nil)
                }
                Button("Keep downloading", role: .cancel) {}
            }
            .confirmationDialog("Uninstall this game?", isPresented: $confirmUninstall, titleVisibility: .visible) {
                Button("Uninstall", role: .destructive) {
                    if let installed { steam.uninstall(installed) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The game's files are deleted from this device.") }
        }
    }

    @ViewBuilder private func primaryAction(installed: DockGame?, download: SteamOwnedLibrary.Download?,
                                            update: Bool, canInstall: Bool) -> some View {
        if let download {
            switch download.state {
            case .active, .queued:
                Button { steam.pause(appID) } label: { actionLabel("Pause", symbol: "pause.fill") }
                    .buttonStyle(.bordered)
            case .paused:
                Button { steam.install(appID) } label: { actionLabel("Resume", symbol: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
            case .failed:
                Button { steam.install(appID) } label: { actionLabel("Try again", symbol: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
            }
        } else if let installed {
            let blocker = SteamGamesRules.blocker(installed: installed.installed, client: dock.clientInstalled, signedIn: signIn.signedIn)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    LogStore.shared.log("[steam-games] play app=\(installed.id)")
                    dismiss()
                    // Let the sheet finish dismissing before the session takes over.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { startDock(installed, dock.compactPool) }
                } label: { actionLabel("Play", symbol: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(blocker != nil)
                if update, SteamInstallPaths.isManaged(library: installed.library) {
                    Button { steam.install(appID) } label: { actionLabel("Update", symbol: "arrow.down.circle") }
                        .buttonStyle(.bordered)
                }
            }
        } else if canInstall {
            Button { steam.install(appID) } label: {
                actionLabel(partial ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(!steam.signedIn)
        }
    }

    /// Explicit glyph and title: a Label inside a bordered button in a Form row
    /// renders title-only, so the icon is drawn directly.
    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title).fontWeight(.semibold)
        }.frame(minWidth: 100, minHeight: 30)
    }
}
