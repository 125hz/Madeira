import SwiftUI
import UIKit

// ml1310: native Steam views for the optional library. Sign-in, the owned
// library, downloads and per-game Steam options. See SteamAccount.swift.

// MARK: - Sign in

struct SteamSignInView: View {
    @ObservedObject private var steam = SteamAccountModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var method: SteamAccountModel.SignInMethod = UIDevice.current.userInterfaceIdiom == .pad ? .qr : .password
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case account, password, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Sign in to Steam", systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text("See your Steam games in Madeira, install them here, and play.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let prompt = steam.guardPrompt {
                    guardSection(prompt)
                } else {
                    Section {
                        Picker("Sign-in method", selection: $method) {
                            Text("Password").tag(SteamAccountModel.SignInMethod.password)
                            Text("QR code").tag(SteamAccountModel.SignInMethod.qr)
                        }.pickerStyle(.segmented)
                    }
                    if method == .password { passwordSection } else { qrSection }
                }
                if let error = steam.signInError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text("Madeira signs in with Steam directly. Your password is sent only to Steam and is never stored. A sign-in token is kept in this device's Keychain until you sign out.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { steam.cancelSignIn(); dismiss() } } }
            .onAppear { steam.signInError = nil; if method == .qr { steam.beginQR() } else { focus = .account } }
            .onChange(of: method) { _, value in
                steam.signInError = nil
                if value == .qr { steam.beginQR() } else { steam.cancelSignIn(); focus = .account }
            }
            .onChange(of: steam.phase) { _, phase in if phase == .signedIn { dismiss() } }
            .onChange(of: steam.guardPrompt) { _, prompt in if prompt?.codeType != nil { focus = .code } }
            .onDisappear { if steam.phase != .signedIn { steam.cancelSignIn() } }
        }
    }

    private var passwordSection: some View {
        Section {
            TextField("Steam account name", text: $account)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .account).submitLabel(.next).onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
            Button(action: submit) {
                HStack {
                    Text("Sign in").fontWeight(.semibold)
                    if steam.signInBusy { Spacer(); ProgressView() }
                }
            }.disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || steam.signInBusy)
        } footer: {
            Text("Use your Steam account name, which can differ from your email address.")
        }
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, !steam.signInBusy else { return }
        steam.signIn(account: account, password: password)
        password = ""
    }

    private func guardSection(_ prompt: SteamGuardPrompt) -> some View {
        Section {
            if let type = prompt.codeType {
                Text(type == .device
                     ? "Enter the Steam Guard code shown in the Steam app on your phone."
                     : "Enter the code Steam sent to your email" + (prompt.hint.isEmpty ? "." : " (\(prompt.hint))."))
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title3.monospaced()).focused($focus, equals: .code)
                    .submitLabel(.go).onSubmit { steam.submitGuardCode(code) }
                Button {
                    steam.submitGuardCode(code)
                } label: {
                    HStack { Text("Continue").fontWeight(.semibold); if steam.signInBusy { Spacer(); ProgressView() } }
                }.disabled(code.trimmingCharacters(in: .whitespaces).count < 5 || steam.signInBusy)
            }
            if prompt.canApprove {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(prompt.codeType == nil
                         ? "Approve this sign-in in the Steam app on your phone."
                         : "Or approve this sign-in in the Steam app.")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Start over", role: .cancel) { code = ""; steam.cancelSignIn() }
        } header: { Text("Steam Guard") }
    }

    private var qrSection: some View {
        Section {
            if let image = steam.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Steam sign-in QR code")
                Text("On another device, open the Steam app, go to Steam Guard, and scan this code.")
                if let link = steam.qrLink {
                    Button { UIApplication.shared.open(link) } label: {
                        Label("Open in the Steam app on this device", systemImage: "arrow.up.forward.app")
                    }
                }
                HStack(spacing: 12) { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
            } else if steam.signInBusy {
                HStack(spacing: 12) { ProgressView(); Text("Getting a sign-in code…").foregroundStyle(.secondary) }
            } else {
                Button("Get a new code") { steam.beginQR() }
            }
        }
    }
}

// MARK: - Owned games

private func steamArtworkEntry(_ game: SteamOwnedGame) -> LibraryEntry {
    var entry = LibraryEntry(title: game.name, relativePath: "", bits: 0)
    entry.steamID = game.id
    return entry
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

struct SteamDownloadStatus: View {
    let download: SteamAccountModel.Download
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

struct SteamOwnedCell: View {
    let game: SteamOwnedGame
    let list: Bool
    @ObservedObject private var steam = SteamAccountModel.shared
    var body: some View {
        let download = steam.downloads[game.id]
        Group {
            if list {
                HStack(spacing: 14) {
                    LibraryArtwork(entry: steamArtworkEntry(game)).frame(width: 48, height: 72)
                        .overlay { overlay(download) }.clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.name).font(.headline).lineLimit(2)
                        if let download { SteamDownloadStatus(download: download) } else { badges }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LibraryArtwork(entry: steamArtworkEntry(game)).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { overlay(download) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .opacity(download == nil ? 0.72 : 1)
                    Text(game.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    badges
                }.padding(4)
            }
        }.foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityHint(download == nil ? "Not installed. Opens download options." : "Downloading.")
    }
    private var badges: some View {
        HStack(spacing: 4) {
            badge(steam.downloads[game.id] == nil ? "Not installed" : "Downloading")
            if game.downloadBytes > 0 { badge(formatBytes(game.downloadBytes)) }
        }.foregroundStyle(.secondary)
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func overlay(_ download: SteamAccountModel.Download?) -> some View {
        if let download {
            ZStack {
                Color.black.opacity(0.45)
                switch download.state {
                case .active:
                    ProgressView(value: download.progress.fraction).progressViewStyle(.circular).tint(.white)
                        .overlay(Text("\(Int(download.progress.fraction * 100))%").font(.caption2.bold()).foregroundStyle(.white).offset(y: 26))
                case .queued: Image(systemName: "clock").font(.title2).foregroundStyle(.white)
                case .paused: Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(.white)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

struct SteamGameSheet: View {
    let appID: Int
    var openEntry: (LibraryEntry) -> Void
    @ObservedObject private var steam = SteamAccountModel.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var freeSpace: Int64?
    @State private var partial = false
    @State private var confirmCancel = false

    private var game: SteamOwnedGame? { steam.game(appID) }
    private var installed: LibraryEntry? { library.entries.first { $0.steamAppID == appID } }

    var body: some View {
        NavigationStack {
            Form {
                if let game {
                    Section {
                        HStack(spacing: 20) {
                            LibraryArtwork(entry: steamArtworkEntry(game)).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 12) {
                                Text(game.name).font(.title2.bold())
                                if game.downloadBytes > 0 {
                                    Text("Download about \(formatBytes(game.downloadBytes))").font(.subheadline).foregroundStyle(.secondary)
                                }
                                primaryAction(game)
                            }
                        }.padding(.vertical, 24)
                            .listRowBackground(
                                LibraryArtwork(entry: steamArtworkEntry(game), backdrop: true).blur(radius: 4)
                                    .overlay(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55))
                                    .clipped()
                            )
                    }
                    if let download = steam.downloads[appID] {
                        Section("Download") {
                            SteamDownloadStatus(download: download)
                            downloadControls(download)
                        }
                    }
                    Section {
                        if let freeSpace { LabeledContent("Free space on this device", value: formatBytes(freeSpace)) }
                        Text("Games download directly from Steam with your account into C:\\Program Files (x86)\\Steam\\steamapps\\common. Keep Madeira open while downloading. A download pauses while a game is running and continues afterwards.")
                            .font(.footnote).foregroundStyle(.secondary)
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
            .task(id: steam.downloads[appID]?.state) {
                partial = steam.hasPartialDownload(appID)
                let values = try? LibraryModel.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                freeSpace = values?.volumeAvailableCapacityForImportantUsage
            }
            .confirmationDialog("Cancel this download? Downloaded files are deleted.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel download", role: .destructive) { steam.cancelInstall(appID) }
                Button("Keep downloading", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func primaryAction(_ game: SteamOwnedGame) -> some View {
        if let entry = installed {
            Button { dismiss(); openEntry(entry) } label: {
                HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Open").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30)
            }.buttonStyle(.borderedProminent)
        } else if let download = steam.downloads[appID] {
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
        } else {
            Button { steam.install(appID) } label: {
                actionLabel(partial ? "Resume download" : "Install", symbol: "arrow.down.circle.fill")
            }.buttonStyle(.borderedProminent).disabled(steam.phase != .signedIn)
        }
    }

    /// Explicit glyph + title: a Label inside a bordered button in a Form row
    /// renders title-only, so the icon is drawn directly (as Play does).
    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(title).fontWeight(.semibold)
        }.frame(minWidth: 100, minHeight: 30)
    }

    @ViewBuilder private func downloadControls(_ download: SteamAccountModel.Download) -> some View {
        Button("Cancel download", role: .destructive) { confirmCancel = true }
        if case .failed = download.state {
            Text("Downloaded parts are kept. Try again to continue where it stopped.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Library section pieces

struct SteamSignInCard: View {
    var signIn: () -> Void
    var body: some View {
        Button(action: signIn) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Steam").font(.headline)
                    Text("See your Steam games here and install them without leaving Madeira.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

struct LibrarySectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            trailing
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Settings

struct SteamSettingsSection: View {
    @ObservedObject private var steam = SteamAccountModel.shared
    var signIn: () -> Void
    var openClient: () -> Void
    @State private var confirmSignOut = false
    var body: some View {
        Section {
            if steam.phase == .signedIn {
                LabeledContent("Signed in as", value: steam.accountName)
                Button {
                    Task { await steam.refreshLibrary() }
                } label: {
                    HStack {
                        Label("Refresh Steam library", systemImage: "arrow.clockwise")
                        Spacer()
                        if steam.refreshing { ProgressView() }
                        else if let updated = steam.libraryUpdated {
                            Text(updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(steam.refreshing)
                Button("Sign out of Steam", role: .destructive) { confirmSignOut = true }
            } else {
                Button(action: signIn) { Label("Sign in to Steam", systemImage: "person.crop.circle.badge.plus") }
            }
            Button(action: openClient) { Label("Windows Steam client…", systemImage: "desktopcomputer") }
        } header: {
            Text("Steam")
        } footer: {
            Text("Madeira keeps a Steam sign-in token in this device's Keychain. Signing out removes it; installed games stay on this device. The Windows Steam client is optional and only needed for games that require Steam to be running.")
        }
        .confirmationDialog("Sign out of Steam? Installed games stay on this device.", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { steam.signOut() }
        }
    }
}

// MARK: - Installed game options

struct SteamEntrySection: View {
    @Binding var entry: LibraryEntry
    var uninstall: () -> Void
    @ObservedObject private var steam = SteamAccountModel.shared
    @ObservedObject private var client = SteamLibraryModel.shared
    @State private var candidates: [String] = []
    @State private var confirmUninstall = false

    var body: some View {
        Section {
            Picker("Start with", selection: Binding(get: { entry.steamClientLaunch == true }, set: { entry.steamClientLaunch = $0 })) {
                Text("The game").tag(false)
                Text("Windows Steam client").tag(true)
            }
            if entry.steamClientLaunch == true && client.snapshot.client == nil {
                Text("Install the Windows Steam client from Settings first, then sign in to it with the same account.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if candidates.count > 1 {
                Picker("Program", selection: Binding(get: { entry.relativePath }, set: { select($0) })) {
                    ForEach(candidates, id: \.self) { path in
                        Text(displayName(path)).tag(path)
                    }
                }.pickerStyle(.navigationLink)
            }
            if let appID = entry.steamAppID, let download = steam.downloads[appID] {
                SteamDownloadStatus(download: download)
                switch download.state {
                case .active, .queued: Button("Pause update") { steam.pause(appID) }
                case .paused, .failed: Button("Resume update") { steam.install(appID) }
                }
            } else if steam.updateAvailable(for: entry), let appID = entry.steamAppID {
                Button { steam.install(appID) } label: { Label("Update available — download", systemImage: "arrow.down.circle") }
                    .disabled(steam.phase != .signedIn)
            }
            Button("Uninstall", role: .destructive) { confirmUninstall = true }
        } header: {
            Text("Steam")
        } footer: {
            Text("Starting the game directly works for games that do not need Steam running. Games that require Steam need the Windows Steam client, signed in to the same account.")
        }
        .task(id: entry.steamInstallPath) {
            guard let folder = entry.steamInstallPath.flatMap({ SteamPaths.safeRelative($0, under: LibraryModel.drive) }) else { return }
            let drive = LibraryModel.drive
            let found = await Task.detached(priority: .utility) {
                SteamAccountModel.executableCandidates(folder: folder).compactMap { SteamPaths.relative($0, drive: drive) }
            }.value
            candidates = found.contains(entry.relativePath) ? found : [entry.relativePath] + found
        }
        .confirmationDialog("Uninstall \(entry.title)? Its downloaded files are deleted from this device. Saves stored elsewhere are kept.",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive, action: uninstall)
        }
    }

    private func select(_ path: String) {
        guard let url = try? LibraryModel.executable(path), let inspected = try? LibraryModel.inspect(url) else { return }
        entry.relativePath = path; entry.bits = inspected.bits
        entry.graphicsAPI = inspected.graphicsAPI ?? entry.graphicsAPI
    }

    private func displayName(_ path: String) -> String {
        guard let base = entry.steamInstallPath, path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }
}
