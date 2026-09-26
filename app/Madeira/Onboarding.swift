import SwiftUI
import UIKit
import Combine

// ml1530: first-run setup. On a new install (no `madeiraOnboardingDone` in
// UserDefaults, which iOS removes with the app) the library opens this full-screen
// setup. ml1910 defaults to native sign-in, verified Valve component preparation,
// then the library. The desktop installer remains an explicit fallback.
// MADEIRA_ONBOARDING=0 never opens it. Settings › "Run setup again" reopens it.
// Log tag: [onboarding] ml1530.

// MARK: - ml1530 rules (Foundation only; build/host-tests/check-onboarding.py compiles this part)

enum OnboardingRules {
    static let doneKey = "madeiraOnboardingDone"

    enum Step: String, CaseIterable { case welcome, steamClient = "steam-client", signIn = "sign-in", done }

    /// Whether setup opens by itself when the library appears.
    static func shouldShow(done: Bool, enabled: Bool) -> Bool { enabled && !done }

    /// The pages of the first-run setup. The Steam client page needs Steam
    /// support; the sign-in page needs Madeira's own Steam client too.
    static func steps(steam: Bool, nativeSteam: Bool, dock: Bool = false) -> [Step] {
        guard steam else { return [.welcome, .done] }
        if nativeSteam && dock { return [.welcome, .signIn, .steamClient, .done] }
        return nativeSteam ? [.welcome, .steamClient, .signIn, .done] : [.welcome, .steamClient, .done]
    }

    /// How a game installed by Madeira's downloader starts: the user's stored
    /// choice, else the Windows Steam client when it is installed
    /// (MADEIRA_STEAM_DEFAULT_CLIENT=0 makes "the game" the default again).
    static func clientLaunch(stored: Bool?, clientInstalled: Bool, defaultClient: Bool) -> Bool {
        stored ?? (defaultClient && clientInstalled)
    }

    /// Whether a game's install button asks for the Windows Steam client first
    /// (MADEIRA_STEAM_REQUIRE_CLIENT=0 never asks).
    static func installNeedsClient(clientInstalled: Bool, required: Bool) -> Bool { required && !clientInstalled }
}

/// ml1530: Steam's installer stops with "the directory has to be empty" when
/// C:\Program Files (x86)\Steam exists, and Madeira's downloader creates it
/// (steamapps) before the Windows client is installed. Before the installer runs,
/// a Steam folder without steam.exe is renamed to Steam.madeira-pending (or
/// Steam.madeira-pending-2, …) beside it; once no session is running its contents
/// move back, without replacing anything Steam created, and the emptied folder
/// is removed. Callers apply MADEIRA_STEAM_INSTALL_MOVE_ASIDE and log.
enum SteamInstallFolder {
    static let pendingName = "Steam.madeira-pending"

    struct Report: Equatable {
        /// Items moved back (whole folders count once).
        var moved = 0
        /// Items left in a pending folder because the Steam folder already has them.
        var kept = 0
        /// Pending folders removed after they were emptied.
        var removed = 0
        var folders = 0
    }

    private static func children(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
    }
    private static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// steam.exe, in any letter case, directly inside `root`.
    static func hasClient(_ root: URL) -> Bool {
        children(root).contains { $0.lastPathComponent.lowercased() == "steam.exe" }
    }

    /// The folder exists, holds something, and has no steam.exe.
    static func needsMoveAside(_ root: URL) -> Bool {
        isFolder(root) && !children(root).isEmpty && !hasClient(root)
    }

    /// Pending folders beside `root`, oldest name first.
    static func pendingFolders(_ root: URL) -> [URL] {
        children(root.deletingLastPathComponent())
            .filter { $0.lastPathComponent == pendingName || $0.lastPathComponent.hasPrefix(pendingName + "-") }
            .filter(isFolder)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Renames `root` aside when the installer would refuse it. Returns the new
    /// folder, or nil when nothing needed to move.
    @discardableResult
    static func moveAside(_ root: URL) throws -> URL? {
        guard needsMoveAside(root) else { return nil }
        let parent = root.deletingLastPathComponent()
        var target = parent.appendingPathComponent(pendingName, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(pendingName)-\(index)", isDirectory: true)
            index += 1
            guard index < 100 else { throw CocoaError(.fileWriteFileExists) }
        }
        try FileManager.default.moveItem(at: root, to: target)
        return target
    }

    /// Moves every pending folder's contents back into `root` (created when
    /// missing). Existing items in `root` are never replaced.
    static func mergeBack(_ root: URL) throws -> Report {
        var report = Report()
        let folders = pendingFolders(root)
        report.folders = folders.count
        guard !folders.isEmpty else { return report }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try merge(from: folder, into: root, report: &report)
            prune(folder)
            if !FileManager.default.fileExists(atPath: folder.path) { report.removed += 1 }
        }
        return report
    }

    /// Moves items of `source` missing from `destination` (names compared
    /// without case), descending into folders both have.
    static func merge(from source: URL, into destination: URL, report: inout Report) throws {
        let existing = Dictionary(children(destination).map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for item in children(source) {
            if let match = existing[item.lastPathComponent.lowercased()] {
                if isFolder(item) && isFolder(match) { try merge(from: item, into: match, report: &report) }
                else { report.kept += 1 }
            } else {
                try FileManager.default.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
                report.moved += 1
            }
        }
    }

    /// Removes empty folders inside `folder`, and `folder` itself when it ends up empty.
    private static func prune(_ folder: URL) {
        for item in children(folder) where isFolder(item) { prune(item) }
        if children(folder).isEmpty { try? FileManager.default.removeItem(at: folder) }
    }
}

// MARK: - ml1530 setup model

extension LibraryEntry {
    /// ml1530: whether this game starts through the Windows Steam client, with
    /// the default applied when the user has not chosen (steamClientLaunch nil).
    @MainActor var startsWithClient: Bool {
        OnboardingRules.clientLaunch(stored: steamClientLaunch, clientInstalled: SteamLibraryModel.shared.snapshot.client != nil,
                                     defaultClient: LibraryFlags.enabled("MADEIRA_STEAM_DEFAULT_CLIENT"))
    }
}

@MainActor final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    typealias Step = OnboardingRules.Step
    /// ml1540: setup's Steam install ran a Wine session in this app run. A game started in the
    /// same run inherits that run's pool and native state, so Madeira asks for a restart first
    /// (owner request; device log 202). MADEIRA_SETUP_RESTART_PROMPT=0 never asks.
    static var restartAdvised = false
    static var restartPromptEnabled: Bool { LibraryFlags.enabled("MADEIRA_SETUP_RESTART_PROMPT") }
    static let restartMessage = "Restart Madeira to finish setup: swipe Madeira away in the app switcher, then open it again. Then start your game."
    /// firstRun: the whole setup. steamClient: only the Steam client install,
    /// opened from a game's install button (MADEIRA_STEAM_REQUIRE_CLIENT).
    enum Purpose: String { case firstRun = "first-run", steamClient = "steam-client" }

    @Published var presented = false
    @Published private(set) var step: Step = .welcome
    @Published private(set) var purpose = Purpose.firstRun
    /// The Wine session started by setup to install Steam; LibraryHUD shows the finish button.
    @Published private(set) var installSession = false
    @Published private(set) var finishing = false
    @Published private(set) var starting = false
    @Published private(set) var checking = false
    @Published private(set) var runtimePhase = ""
    private var runtimeTask: Task<Void, Never>?
    /// The last check after an install session found no steam.exe.
    @Published private(set) var installMissing = false
    @Published var message: String?
    /// ml1770: the Steam install's stage for the starting screen; nil outside setup's
    /// session or with MADEIRA_SETUP_STAGES=0.
    @Published private(set) var setupStage: SteamSetupStage?
    private var stageTimer: Timer?
    private var stageLines = 0
    private var watch: AnyCancellable?
    private var considered = false

    static var enabled: Bool { LibraryFlags.enabled("MADEIRA_ONBOARDING") }
    static var done: Bool { UserDefaults.standard.bool(forKey: OnboardingRules.doneKey) }

    private init() {
        watch = LibraryModel.shared.$current.receive(on: DispatchQueue.main).sink { [weak self] current in
            MainActor.assumeIsolated { self?.sessionChanged(running: current != nil) }
        }
    }

    var steps: [Step] {
        guard purpose == .firstRun else { return [.steamClient] }
        return OnboardingRules.steps(steam: LibraryFlags.enabled("MADEIRA_STEAM"), nativeSteam: SteamAccountModel.enabled, dock: MadeiraDock.enabled)
    }

    /// The library appeared: open setup once per run on a new install.
    func presentIfNeeded() {
        guard !considered else { return }
        considered = true
        guard OnboardingRules.shouldShow(done: Self.done, enabled: Self.enabled) else { return }
        open(.firstRun, at: .welcome, reason: "first-run")
    }

    /// Settings › Run setup again.
    func rerun() { open(.firstRun, at: .welcome, reason: "settings") }

    /// A game's install button while the Windows Steam client is missing.
    func openSteamClientSetup(appID: Int) {
        LogStore.shared.log("[onboarding] ml1530 install gate app=\(appID)")
        // Let the game's sheet finish dismissing first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.open(.steamClient, at: .steamClient, reason: "install-gate")
        }
    }

    private func open(_ purpose: Purpose, at step: Step, reason: String) {
        guard LibraryModel.shared.current == nil else { return }
        self.purpose = purpose; message = nil; installMissing = false
        LogStore.shared.log("[onboarding] ml1530 shown reason=\(reason) purpose=\(purpose.rawValue)")
        LogStore.shared.log("[dock-defaults] ml1910 dock=\(MadeiraDock.enabled ? 1 : 0) native-setup=\(MadeiraDock.nativeSetupEnabled ? 1 : 0)")
        go(step)
        presented = true
    }

    func go(_ next: Step) {
        step = next
        LogStore.shared.log("[onboarding] ml1530 step=\(next.rawValue)")
    }

    func next() {
        let list = steps
        guard let index = list.firstIndex(of: step), index + 1 < list.count else { finish(); return }
        message = nil
        go(list[index + 1])
    }

    /// The hidden developer skip on the welcome title.
    func skip() {
        UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)
        LogStore.shared.log("[onboarding] ml1530 skipped (developer)")
        close()
    }

    func finish() {
        if purpose == .firstRun { UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey) }
        LogStore.shared.log("[onboarding] ml1530 done purpose=\(purpose.rawValue)")
        close()
    }

    /// Back to the library, with no ended session's desktop left over it.
    private func close() {
        EndedSessionSurface.hide(reason: "setup-closed")
        presented = false
    }

    // MARK: Steam client install

    // ml1900: trial native preparation; retain the installer as an explicit
    // fallback until the owner confirms authentication on a clean prefix.
    func prepareRuntime() {
        guard !starting, !checking, LibraryModel.shared.current == nil else { return }
        starting = true; message = nil
        runtimePhase = "Preparing download…"
        LogStore.shared.log("[dock-setup] ml1900 native preparation started")
        let prefix = LibraryModel.drive.deletingLastPathComponent()
        runtimeTask = Task {
            defer { starting = false; runtimeTask = nil }
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: prefix) { phase in
                    await MainActor.run { self.runtimePhase = phase }
                }
                await checkClient()
                guard SteamLibraryModel.shared.snapshot.client != nil else { throw SteamRuntimeFiles.Failure.prefixMissing }
                LogStore.shared.log("[dock-setup] ml1900 verified runtime prepared; no Wine session started")
            } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                message = "Setup cancelled. You can try again when you're ready."
                LogStore.shared.log("[dock-setup] ml1900 native preparation cancelled")
            } catch {
                message = error.localizedDescription
                LogStore.shared.log("[dock-setup] ml1900 preparation failed; existing files retained", level: .error)
            }
        }
    }

    func cancelRuntime() { runtimeTask?.cancel() }

    func downloadInstaller() {
        message = nil; SteamLibraryModel.shared.error = nil
        LogStore.shared.log("[onboarding] ml1530 installer download")
        // Staged: the page's Install button runs it once downloaded.
        SteamLibraryModel.shared.download { _ in }
    }

    /// Runs the downloaded installer in the Wine desktop. The first start also
    /// seeds the Windows prefix (drive_c) when it does not exist yet.
    func runInstaller(play: @escaping (LibraryEntry) -> Void) {
        let client = SteamLibraryModel.shared
        guard !starting, !installSession, LibraryModel.shared.current == nil, client.cachedInstaller else { return }
        message = nil; installMissing = false; client.error = nil
        guard StikJITHelper.readyToLaunch else {
            message = "Enable JIT first, then tap Install Steam again."; return
        }
        let entry = client.installerEntry()
        do { try entry.validate() } catch { message = error.localizedDescription; return }
        starting = true
        LogStore.shared.log("[onboarding] ml1530 installer start purpose=\(purpose.rawValue)")
        Task { @MainActor in
            defer { starting = false }
            await SteamAccountModel.shared.holdForSteamInstall()
            client.stopScan()
            installSession = true; finishing = false
            startStages()
            presented = false
            // The setup screen finishes dismissing before the session takes over.
            try? await Task.sleep(nanoseconds: 500_000_000)
            client.prepareInstallerFolder()
            play(entry)
            guard LibraryModel.shared.current == nil else {
                Self.restartAdvised = true
                return
            }
            // The session did not start (JIT, validation): back to this page.
            installSession = false
            stopStages()
            message = LibraryModel.shared.error ?? "Steam's installer could not start. Try again."
            LibraryModel.shared.error = nil
            LogStore.shared.log("[onboarding] ml1530 installer did not start")
            await client.restorePendingInstallFolder()
            presented = true
        }
    }

    /// The button over the Wine desktop: close the session gracefully.
    func finishInstall() {
        guard installSession, !finishing else { return }
        finishing = true
        LogStore.shared.log("[onboarding] ml1530 finish tapped; closing session")
        LibraryModel.shared.requestQuit()
        // A window that asked to confirm closing leaves the session up; allow another tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.installSession, self.finishing else { return }
            self.finishing = false
            LogStore.shared.log("[onboarding] ml1530 session still running after finish; button re-enabled")
        }
    }

    private func sessionChanged(running: Bool) {
        guard !running, installSession else { return }
        installSession = false; finishing = false
        stopStages()
        LogStore.shared.log("[onboarding] ml1530 install session ended")
        EndedSessionSurface.hide(reason: "install-session-ended")
        go(.steamClient)
        // The library view returns first; then setup opens over it again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presented = true
            Task { await self?.checkClient(afterInstall: true) }
        }
    }

    // MARK: ml1770 install stage

    /// Follows the client's updater log every 2 s, off the main thread.
    private func startStages() {
        stopStages()
        guard LibraryFlags.enabled("MADEIRA_SETUP_STAGES") else { return }
        let follower = SetupStageFollower(log: SteamInstallPaths.root.appendingPathComponent("logs/bootstrap_log.txt"),
                                          drive: LibraryModel.drive)
        setupStage = .installing; stageLines = 0
        LogStore.shared.log("[setup-stage] ml1770 follow stage=installing")
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            follower.poll { stage in
                Task { @MainActor in
                    guard let self, self.stageTimer != nil, self.setupStage != stage else { return }
                    self.setupStage = stage
                    // Changes only; download percentages make this at most 24 lines per install.
                    if self.stageLines < 24 { self.stageLines += 1; LogStore.shared.log("[setup-stage] ml1770 stage=\(stage.name)") }
                }
            }
        }
        stageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStages() {
        stageTimer?.invalidate(); stageTimer = nil
        setupStage = nil
    }

    /// Scans drive_c for steam.exe (and moves a set-aside Steam folder back).
    func checkClient(afterInstall: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let client = SteamLibraryModel.shared
        for _ in 0..<50 where client.refreshing { try? await Task.sleep(nanoseconds: 200_000_000) }
        await client.refresh()
        let found = client.snapshot.client != nil
        if afterInstall {
            installMissing = !found
            LogStore.shared.log("[onboarding] ml1530 client check found=\(found ? 1 : 0)")
        }
    }
}

// MARK: - ml1530 the ended session's desktop

/// ml1530: a desktop session (the Desktop, the Windows Steam client, Steam's
/// installer) draws through Winios's compositor view, a plain UIView the native
/// side adds straight onto the app window, above the SwiftUI root view, and
/// never hides. The game view (MetalHostView) is hidden when a session ends;
/// the compositor was not, so once nothing was presented over the library (setup
/// finishing, device log: "done" at 18:26:17) the ended session's frozen desktop
/// covered it. The library now hides that view when the session ends and shows
/// it again when the next one begins. [library-surface] ml1530 logs both.
/// MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP=0 leaves it alone.
enum EndedSessionSurface {
    private static var watch: AnyCancellable?
    private static var hiddenByUs = false

    @MainActor static func install() {
        guard watch == nil else { return }
        watch = LibraryModel.shared.$current.receive(on: DispatchQueue.main).sink { current in
            MainActor.assumeIsolated {
                if current == nil { hide(reason: "session-ended") } else { show() }
            }
        }
    }

    /// The desktop session's compositor view (Winios.m) is hidden and shown by name.
    @MainActor static func hide(reason: String) {
        guard LibraryFlags.enabled("MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP"), LibraryModel.shared.enabled,
              LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        guard winios_compositor_set_hidden(1) != 0 else { return }
        hiddenByUs = true
        LogStore.shared.log("[library-surface] ml1530 hid ended desktop reason=\(reason)")
    }

    @MainActor static func show() {
        guard hiddenByUs else { return }
        hiddenByUs = false
        _ = winios_compositor_set_hidden(0)
        LogStore.shared.log("[library-surface] ml1530 desktop shown for the new session")
    }
}

// MARK: - ml1530 setup screens

struct OnboardingView: View {
    let play: (LibraryEntry) -> Void
    let enableJIT: () -> Void
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var client = SteamLibraryModel.shared
    @ObservedObject private var steam = SteamAccountModel.shared
    @State private var signIn = false
    @State private var restartAlert = false   // ml1540
    @State private var jitReady = StikJITHelper.readyToLaunch
    @State private var desktopSetup = false
    private var nativeSetup: Bool {
        MadeiraDock.nativeSetupEnabled && !desktopSetup
    }
    private let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let index = model.steps.firstIndex(of: model.step), model.steps.count > 3, model.step != .welcome, model.step != .done {
                        Text("Step \(index) of \(model.steps.count - 2)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    switch model.step {
                    case .welcome: welcome
                    case .steamClient: steamClient
                    case .signIn: signInPage
                    case .done: done
                    }
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                if model.purpose == .steamClient {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { model.finish() }.disabled(model.starting) }
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $signIn) { SteamSignInView() }
        .onAppear { steam.start(); jitReady = StikJITHelper.readyToLaunch }
        .onReceive(ticks) { _ in jitReady = StikJITHelper.readyToLaunch }
        .task(id: model.step) { if model.step == .steamClient { await model.checkClient() } }
    }

    private func header(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title.bold())
        }
    }

    private func primary(_ title: String, symbol: String? = nil, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) } else if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }.frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent).controlSize(.large)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).frame(maxWidth: .infinity, minHeight: 44)
    }

    private func point(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.bold)).frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle()).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(.tint).accessibilityHidden(true)
            // ml1530: tapping the title skips setup (developers); deliberately not announced.
            Text("Welcome to Madeira").font(.largeTitle.bold())
                .onTapGesture { model.skip() }
            Text("Madeira runs Windows games on your \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
                .font(.title3)
            if model.steps.contains(.steamClient) {
                Text("A few steps get you ready:").foregroundStyle(.secondary)
                if MadeiraDock.enabled {
                    point(1, "Sign in to Steam in Madeira.")
                    point(2, nativeSetup ? "Let Madeira prepare Steam's official components." : "Install Steam's Windows files for Madeira Dock.")
                } else {
                    point(1, "Install Steam for Windows inside Madeira.")
                    if model.steps.contains(.signIn) { point(2, "Sign in to Steam in Madeira, so your games show up here.") }
                }
            }
            primary("Get started", symbol: "arrow.right") { model.next() }.padding(.top, 8)
        }
    }

    @ViewBuilder private var steamClient: some View {
        if nativeSetup { nativeRuntimePage } else { desktopClientPage }
    }

    private var nativeRuntimePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Prepare Madeira Dock", symbol: "shippingbox")
            Text("Madeira downloads Steam's official components directly from Valve. You won't need to open a Windows desktop or sign in a second time.")
            if client.snapshot.client != nil {
                Label("Steam components are available.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary(model.purpose == .steamClient ? "Done" : "Continue", symbol: "arrow.right") {
                    if model.purpose == .steamClient { model.finish() } else { model.next() }
                }
            } else if model.starting || model.checking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.starting ? model.runtimePhase : "Checking Steam components…").foregroundStyle(.secondary)
                }
                if model.starting { secondary("Cancel") { model.cancelRuntime() } }
            } else {
                Text("About 73 MB to download. Keep Madeira open while setup finishes.").foregroundStyle(.secondary)
                if let message = model.message { Text(message).foregroundStyle(.red) }
                primary("Prepare Steam components", symbol: "arrow.down.circle.fill") { model.prepareRuntime() }
                secondary("Use desktop setup instead") { desktopSetup = true }
                if model.purpose == .firstRun { secondary("Set up later") { model.next() } }
            }
        }
    }

    private var desktopClientPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header(MadeiraDock.enabled ? "Prepare Madeira Dock" : "Install Steam for Windows", symbol: "desktopcomputer")
            Text(MadeiraDock.enabled
                 ? "Madeira Dock uses Steam's official Windows files to start your games. This first test still uses Valve's installer to prepare those files."
                 : "Steam for Windows runs inside Madeira. Madeira needs it to start the games in your Steam library.")
            if client.snapshot.client != nil {
                Label("Steam for Windows is installed.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary(model.purpose == .steamClient ? "Done" : "Continue", symbol: "arrow.right") {
                    if model.purpose == .steamClient { model.finish() } else { model.next() }
                }
            } else if model.checking {
                HStack(spacing: 12) { ProgressView(); Text("Looking for Steam…").foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    point(1, "Madeira downloads Steam's official installer from Valve.")
                    point(2, "The installer opens in a Windows desktop. Follow its steps. Steam then updates itself, which can take several minutes.")
                    point(3, MadeiraDock.enabled ? "Wait until Steam finishes updating and its sign-in window appears. Dock uses your Madeira sign-in when you play." : "Sign in to Steam in its window.")
                    point(4, MadeiraDock.enabled ? "Tap “Steam files are installed” at the top to return to Madeira." : "Then tap “Tap when Steam is installed and you're signed in” at the top of the screen to come back here.")
                }
                if model.installMissing {
                    Label("Madeira could not find Steam yet. The installer may not have finished. Try again, and wait for Steam's sign-in window before you tap the button.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !jitReady {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Madeira needs JIT to run Windows programs. Enable it first.").font(.subheadline).foregroundStyle(.secondary)
                        Button(action: enableJIT) { Label("Enable JIT", systemImage: "bolt.fill") }.buttonStyle(.bordered)
                    }
                }
                if let error = model.message ?? client.error {
                    Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                if client.busy {
                    ProgressView(client.installerPhase, value: client.progress)
                    secondary("Cancel download") { client.cancel() }
                } else if client.cachedInstaller {
                    primary(model.installMissing ? "Try again" : "Install Steam", symbol: "play.fill", busy: model.starting) { model.runInstaller(play: play) }
                        .disabled(model.starting || !jitReady)
                } else {
                    primary("Download Steam", symbol: "arrow.down.circle.fill") { model.downloadInstaller() }
                }
            }
            if model.purpose == .firstRun && client.snapshot.client == nil {
                secondary("Set up later") { model.next() }.disabled(model.starting)
            }
        }
    }

    private var signInPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Sign in to Steam in Madeira", symbol: "person.crop.circle.badge.checkmark")
            Text(MadeiraDock.enabled
                 ? "Sign in here to see your library and download games. When you play, Madeira Dock hands your sign-in to Steam's official client, which checks your license."
                 : "Sign in here to show your Steam library and install your games from inside Madeira.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Madeira sends your sign-in directly to Steam. Your password is not saved.", systemImage: "lock.fill")
                Label("Madeira saves your Steam sign-in in this device's Keychain.", systemImage: "iphone")
                if MadeiraDock.enabled { Label("Steam Guard may ask you to approve your sign-in.", systemImage: "checkmark.shield") }
            }.font(.subheadline).foregroundStyle(.secondary)
            if steam.phase == .signedIn {
                Label("Signed in as \(steam.accountName)", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
                secondary("Use a different account") {
                    LogStore.shared.log("[onboarding] ml1530 sign-in replaced")
                    steam.signOut(); signIn = true
                }
            } else {
                primary("Sign in to Steam", symbol: "person.crop.circle") { signIn = true }
                secondary("Set up later") { model.next() }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("You're all set", symbol: "checkmark.seal.fill")
            if model.steps.contains(.steamClient) {
                Text("Your Steam games appear in your library. Install one there, then tap Play.")
            }
            Text("You can run this setup again from Settings.").foregroundStyle(.secondary)
            // ml1540: after the setup's Steam session, a restart before the first game.
            if OnboardingModel.restartAdvised && OnboardingModel.restartPromptEnabled {
                Label(OnboardingModel.restartMessage, systemImage: "arrow.clockwise.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            }
            primary("Go to your library", symbol: "square.grid.2x2.fill") {
                if OnboardingModel.restartAdvised && OnboardingModel.restartPromptEnabled {
                    LogStore.shared.log("[onboarding] ml1540 restart advised")
                    restartAlert = true
                } else {
                    model.finish()
                }
            }
            .alert("Restart Madeira", isPresented: $restartAlert) {
                Button("OK") { model.finish() }
            } message: { Text(OnboardingModel.restartMessage) }
        }
    }
}

/// ml1770: the updater log's tail and stage, touched only on its own queue.
private final class SetupStageFollower: @unchecked Sendable {
    private let queue = DispatchQueue(label: "madeira.setup-stage", qos: .utility)
    private let log: URL, drive: URL
    private var tail = SteamLogTail()
    private var stage = SteamSetupStage.installing
    private var busy = false

    init(log: URL, drive: URL) { self.log = log; self.drive = drive }

    func poll(_ done: @escaping @Sendable (SteamSetupStage) -> Void) {
        queue.async { [self] in
            guard !busy else { return }
            busy = true; defer { busy = false }
            for line in tail.read(SteamPaths.existing(log, drive: drive) ?? log) { stage = stage.after(line) }
            done(stage)
        }
    }
}

/// ml1530: over the Wine desktop while setup's Steam install runs.
struct OnboardingFinishButton: View {
    @ObservedObject private var model = OnboardingModel.shared
    var body: some View {
        Button { model.finishInstall() } label: {
            HStack(spacing: 8) {
                if model.finishing { ProgressView().tint(.white) } else { Image(systemName: "checkmark.circle.fill") }
                Text(model.finishing ? "Closing Steam…" : (MadeiraDock.enabled ? "Steam files are installed" : "Tap when Steam is installed and you're signed in"))
                    .fontWeight(.semibold).multilineTextAlignment(.center)
            }.padding(.horizontal, 6).frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
        .disabled(model.finishing)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        // ml1570: during a session the controls window hands every touch outside its
        // listed rects to the live view (ControlsWindow.hitTest), so this button was
        // never tappable (device log 205: no close request after the tap). Publish its
        // frame like the menu button's; MADEIRA_SETUP_BUTTON_HITTEST=0 stops publishing.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { Self.publish(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { _, frame in Self.publish(frame) }
        })
        .onDisappear { LibraryModel.shared.finishButtonRect = .zero }
    }

    private static func publish(_ frame: CGRect) {
        guard LibraryFlags.enabled("MADEIRA_SETUP_BUTTON_HITTEST") else { return }
        LibraryModel.shared.finishButtonRect = frame.insetBy(dx: -8, dy: -8)
    }
}

// MARK: - ml1970 start modes

/// ml1970: how a Steam game starts. Madeira Dock is the default whenever it is enabled and
/// Valve's client components are present; regular Steam needs the desktop client.
enum SteamStartMode: Hashable { case dock, game, steam }

extension LibraryEntry {
    @MainActor var steamStartMode: SteamStartMode {
        guard startsWithClient else { return .game }
        return MadeiraDock.enabled && steamDesktopLaunch != true ? .dock : .steam
    }
    mutating func setSteamStartMode(_ mode: SteamStartMode) {
        switch mode {
        case .game: steamClientLaunch = false; steamDesktopLaunch = nil
        case .dock: steamClientLaunch = true; steamDesktopLaunch = nil
        case .steam: steamClientLaunch = true; steamDesktopLaunch = MadeiraDock.enabled ? true : nil
        }
        LogStore.shared.log("[steam-start] ml1970 app=\(steamAppID ?? 0) mode=\(mode)")
    }
}
