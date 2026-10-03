// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// First-run setup and Settings › Steam for the library (docs/LIBRARY.md,
// "Steam setup"). On a new install (no `madeiraOnboardingDone` in UserDefaults,
// which iOS removes with the app) the library opens a full-screen setup:
// welcome, Steam sign-in, Valve's client components for Madeira Dock (only when
// Dock is available), done. Every step can be skipped. Settings › Steam ›
// "Run setup again" reopens it. env.MADEIRA_ONBOARDING = 0 never opens it.
//
// Setup is app UI only: sign-in goes through SteamSignIn (the token stays in its
// Keychain store) and the components through MadeiraDockModel.prepareClient(),
// which downloads and verifies files without starting Wine. Setup starts no Wine
// session and changes no JIT pool, engine switch or configuration default.
// Log tag: [onboarding] (no account names, tokens or paths).

// MARK: - Rules (Foundation and MadeiraConfig only; tests/host/check-onboarding.py compiles this part)

enum OnboardingRules {
    static let doneKey = "madeiraOnboardingDone"

    /// `env.MADEIRA_ONBOARDING = 0` (madeira.cfg or the environment) never opens
    /// setup and hides "Run setup again". On by default.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }

    enum Step: String, CaseIterable { case welcome, signIn = "sign-in", dockClient = "dock-client", done }

    /// The setup's pages. Sign-in is offered when Steam sign-in is enabled, or
    /// when Madeira Dock is available (Dock needs a sign-in). Valve's client
    /// components are offered only when Dock is available.
    static func steps(signIn: Bool, dock: Bool) -> [Step] {
        var list: [Step] = [.welcome]
        if signIn || dock { list.append(.signIn) }
        if dock { list.append(.dockClient) }
        return list + [.done]
    }

    /// Whether there is anything to set up between the welcome and done pages.
    static func hasSetup(_ steps: [Step]) -> Bool { steps.contains(.signIn) || steps.contains(.dockClient) }

    /// Whether setup opens by itself when the library appears.
    static func shouldShow(done: Bool, enabled: Bool, steps: [Step]) -> Bool {
        enabled && !done && hasSetup(steps)
    }

    /// The page after `step`, or nil when setup is finished.
    static func next(after step: Step, in steps: [Step]) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// "Step n of m" for the pages between welcome and done; nil on those two.
    static func position(of step: Step, in steps: [Step]) -> (number: Int, count: Int)? {
        let middle = steps.filter { $0 != .welcome && $0 != .done }
        guard let index = middle.firstIndex(of: step) else { return nil }
        return (index + 1, middle.count)
    }
}

// MARK: - Setup model

@MainActor final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    typealias Step = OnboardingRules.Step

    @Published var presented = false
    @Published private(set) var step: Step = .welcome
    /// Considered once per app run, when the library first appears.
    private var considered = false

    static var enabled: Bool { OnboardingRules.enabled }
    static var done: Bool { UserDefaults.standard.bool(forKey: OnboardingRules.doneKey) }

    var steps: [Step] { OnboardingRules.steps(signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled) }
    /// Setup can be opened: enabled, and something to set up.
    var available: Bool { Self.enabled && OnboardingRules.hasSetup(steps) }

    private init() {}

    /// The library appeared: open setup once on a new install.
    func presentIfNeeded() {
        guard !considered else { return }
        considered = true
        guard OnboardingRules.shouldShow(done: Self.done, enabled: Self.enabled, steps: steps) else { return }
        open(reason: "first-run")
    }

    /// Settings › Steam › Run setup again.
    func rerun() { open(reason: "settings") }

    private func open(reason: String) {
        // Never over a running session.
        guard available, LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        LogStore.shared.log("[onboarding] shown reason=\(reason) steps=\(steps.map(\.rawValue).joined(separator: ","))")
        go(.welcome)
        presented = true
    }

    func go(_ next: Step) {
        step = next
        LogStore.shared.log("[onboarding] step=\(next.rawValue)")
    }

    func next() {
        guard let following = OnboardingRules.next(after: step, in: steps) else { finish(); return }
        go(following)
    }

    /// "Skip setup" on the welcome page: done, and not shown again.
    func skip() {
        UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)
        LogStore.shared.log("[onboarding] skipped")
        close()
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)
        LogStore.shared.log("[onboarding] done")
        close()
    }

    private func close() {
        EndedSessionSurface.hide(reason: "setup-closed")
        presented = false
    }
}

// MARK: - Setup screens

struct OnboardingView: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let position = OnboardingRules.position(of: model.step, in: model.steps), position.count > 1 {
                        Text("Step \(position.number) of \(position.count)")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    switch model.step {
                    case .welcome: welcome
                    case .signIn: signInPage
                    case .dockClient: dockClientPage
                    case .done: donePage
                    }
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .onAppear { signIn.refresh(); dock.refresh() }
    }

    private func header(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
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
            Text("Welcome to Madeira").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Madeira runs Windows games on your \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").")
                .font(.title3)
            Text("A few optional steps get you ready:").foregroundStyle(.secondary)
            let pages = model.steps
            if pages.contains(.signIn) { point(1, "Sign in to Steam in Madeira.") }
            if pages.contains(.dockClient) {
                point(2, "Download Valve's Steam client components for Madeira Dock.")
            }
            primary("Get started", symbol: "arrow.right") { model.next() }.padding(.top, 8)
            secondary("Skip setup") { model.skip() }
        }
    }

    private var signInPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Sign in to Steam", symbol: "person.crop.circle.badge.checkmark")
            Text(model.steps.contains(.dockClient)
                 ? "When you start a game with Madeira Dock, Madeira hands this sign-in to Valve's own Steam client, which signs in and checks your license."
                 : "Madeira keeps a Steam sign-in so it can start your Steam games with your own account.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Your password goes only to Steam and is never saved.", systemImage: "lock.fill")
                Label("The sign-in is kept in this device's Keychain until you sign out.", systemImage: "iphone")
            }.font(.subheadline).foregroundStyle(.secondary)
            if let name = signIn.accountName {
                Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
                secondary("Use a different account") {
                    LogStore.shared.log("[onboarding] sign-in replaced")
                    signIn.signOut(); showSignIn = true
                }
            } else {
                primary("Sign in to Steam", symbol: "person.crop.circle") { showSignIn = true }
                secondary("Set up later") { model.next() }
            }
        }
    }

    private var dockClientPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Prepare Madeira Dock", symbol: "shippingbox")
            Text("Madeira Dock starts your installed Steam games through Valve's own Steam client, without the Steam desktop window. It needs the client's components, which Madeira downloads from Valve.")
            if dock.clientInstalled {
                Label("Valve's client components are installed.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("Continue", symbol: "arrow.right") { model.next() }
            } else {
                Text("About 73 MB from Valve's update servers, checked against pinned SHA-256 sums. No Windows session runs for this.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if dock.preparing {
                    HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                } else {
                    if let error = dock.error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    primary(dock.error == nil ? "Download components" : "Try again", symbol: "arrow.down.circle.fill") {
                        LogStore.shared.log("[onboarding] components download")
                        dock.prepareClient()
                    }
                }
                // A running download continues; Settings › Steam › Madeira Dock shows it.
                secondary("Set up later") { model.next() }
            }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("You're all set", symbol: "checkmark.seal.fill")
            if model.steps.contains(.dockClient) {
                Text("Settings › Steam › Madeira Dock lists the Steam games installed in Madeira's drive_c and starts them.")
            }
            Text("You can run this setup again from Settings › Steam.").foregroundStyle(.secondary)
            primary("Go to your library", symbol: "square.grid.2x2.fill") { model.finish() }
        }
    }
}

// MARK: - Settings › Steam

/// The library's Steam settings: the signed-in account, Sign in / Sign out
/// (SteamSignIn; the token stays in its Keychain store), Madeira Dock's sheet
/// and "Run setup again".
struct SteamSettingsSection: View {
    /// Opens Steam sign-in or Madeira Dock. LibraryView presents the sheet from the
    /// Settings Form: a sheet attached to this section closed again as soon as it
    /// slid up whenever the Form rebuilt its rows.
    let open: (SettingsSheet) -> Void
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var cloud = SteamCloudSetting.shared
    @State private var confirmSignOut = false

    /// Shown when Steam sign-in or Madeira Dock is available.
    static var shown: Bool { SteamSignIn.isEnabled || MadeiraDock.enabled }

    var body: some View {
        account
        // Opt-in two-way sync of installed games' saves (docs/STEAM_CLOUD.md).
        if SteamOwnedLibrary.enabled, signIn.accountName != nil {
            Section {
                Toggle("Steam Cloud saves", isOn: $cloud.on)
            } footer: {
                Text("Syncs installed Steam games' saves with Steam Cloud before and after you play. A save that changed on both sides, or that is missing on this device, is never replaced without asking, and a save a sync replaces is kept in Files › Madeira › Steam Cloud Backups.")
            }
        }
    }

    private var account: some View {
        Section {
            if let name = signIn.accountName {
                LabeledContent("Signed in as", value: name)
                Button("Sign out of Steam", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.steamSignIn) } label: { Label("Sign in to Steam", systemImage: "person.crop.circle.badge.plus") }
            }
            if MadeiraDock.enabled {
                Button { open(.dock) } label: { Label("Madeira Dock", systemImage: "shippingbox") }
                if let status = dock.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if onboarding.available {
                Button { onboarding.rerun() } label: { Label("Run setup again", systemImage: "wand.and.stars") }
            }
        } header: {
            Text("Steam")
        } footer: {
            Text("Madeira keeps a Steam sign-in token in this device's Keychain, for this device only. Signing out removes it.")
        }
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signIn.signOut() }
        }
        .onAppear { signIn.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in signIn.refresh() }
    }
}

// MARK: - Madeira Dock in the library

extension LibraryEntry {
    static let dockSessionID = UUID(uuidString: "5D0C4A3E-2B7F-4C61-9E0A-6B1D2F3C4E5A")!

    /// A Dock start from the library runs as a library session (full-screen
    /// view, starting screen, in-game menu, one session per run) with this
    /// entry. It is a desktop session: explorer's virtual desktop runs the
    /// host. It is never saved to the library.
    static func dockSession(title: String, width: Int, height: Int) -> LibraryEntry {
        var entry = LibraryEntry(title: title.isEmpty ? "Madeira Dock" : title, relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = dockSessionID; entry.desktop = true; entry.resolution = "\(width)x\(height)"
        entry.graphicsAPI = "Madeira Dock"
        return entry
    }
}
