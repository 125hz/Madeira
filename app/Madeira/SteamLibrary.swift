import SwiftUI
import UniformTypeIdentifiers

// No account credentials enter the native interface. Steam owns authentication,
// entitlements, downloads and updates inside the Windows environment.
private final class SteamDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > SteamPaths.maximumInstallerBytes || totalBytesExpectedToWrite > SteamPaths.maximumInstallerBytes {
            downloadTask.cancel(); return
        }
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(SteamPaths.trustedDownload(request.url) ? request : nil)
    }
}

@MainActor final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()
    @Published var snapshot = SteamSnapshot()
    @Published var busy = false
    @Published var refreshing = false
    @Published var progress = 0.0
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var scan: Task<SteamSnapshot, Error>?
    private var canManage: Bool { LibraryModel.shared.current == nil && wine_process_is_running() == 0 && wineserver_is_running() == 0 }
    var cachedInstaller: Bool {
        guard let url = SteamPaths.safeRelative(SteamPaths.installerRelative, under: LibraryModel.drive) else { return false }
        return (try? SteamPaths.executableBits(url)) != nil
    }
    func refresh() async {
        guard LibraryFlags.enabled("MADEIRA_STEAM"), canManage, !refreshing, !busy else { return }
        refreshing = true
        defer { refreshing = false; scan = nil }
        let drive = LibraryModel.drive
        let preferred = UserDefaults.standard.string(forKey: "madeiraSteamClient")
        let task = Task { try await SteamDisk.shared.snapshot(drive: drive, preferredClient: preferred) }
        scan = task
        do {
            let result = try await task.value
            guard !Task.isCancelled, canManage else { return }
            snapshot = result
            LibraryModel.shared.mergeSteam(result)
            fputs("[steam-bridge] ml1260 scan client=\(result.client == nil ? 0 : 1) apps=\(result.apps.count) complete=\(result.complete ? 1 : 0) skipped=\(result.skippedLibraries) unreadable=\(result.unreadableManifests)\n", stderr)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func stopScan() { scan?.cancel() }
    func cancel() { operation?.cancel() }
    func download(ready: @escaping (LibraryEntry) -> Void) {
        guard !busy, canManage, LibraryFlags.enabled("MADEIRA_STEAM") else { return }
        busy = true; error = nil; progress = 0
        operation = Task {
            defer { busy = false; operation = nil }
            let delegate = SteamDownloadDelegate { value in Task { @MainActor [weak self] in self?.progress = value } }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                fputs("[steam-bridge] ml1260 installer download begin\n", stderr)
                let (temporary, response) = try await session.download(from: SteamPaths.installerURL, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      SteamPaths.trustedDownload(http.url) else { throw SteamFileError.invalid("Steam's installer could not be downloaded. Try again or choose your own installer.") }
                let bits = try await SteamDisk.shared.storeInstaller(temporary, drive: LibraryModel.drive)
                try Task.checkCancellation()
                guard canManage else { return }
                fputs("[steam-bridge] ml1260 installer ready bits=\(bits)\n", stderr)
                ready(installerEntry(bits: bits))
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; fputs("[steam-bridge] ml1260 installer download failed\n", stderr) }
            }
        }
    }
    func importInstaller(_ source: URL, ready: @escaping (LibraryEntry) -> Void) {
        guard !busy, canManage, LibraryFlags.enabled("MADEIRA_STEAM") else { return }
        busy = true; error = nil
        operation = Task {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() }; busy = false; operation = nil }
            do {
                let bits = try await SteamDisk.shared.storeInstaller(source, drive: LibraryModel.drive)
                try Task.checkCancellation()
                guard canManage else { return }
                fputs("[steam-bridge] ml1260 supplied installer ready bits=\(bits)\n", stderr)
                ready(installerEntry(bits: bits))
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func installerEntry(bits: Int = 32) -> LibraryEntry {
        var entry = LibraryEntry(title: "Install Steam", relativePath: SteamPaths.installerRelative, bits: bits)
        entry.steamSession = "installer"; entry.reducedX87 = false
        return entry
    }
    func clientEntry(bigPicture: Bool) -> LibraryEntry? {
        guard let path = snapshot.client else { return nil }
        var entry = LibraryEntry(title: "Steam", relativePath: path, bits: 0)
        entry.steamSession = "client"; entry.steamBigPicture = bigPicture; entry.reducedX87 = false
        return entry
    }
    func chooseClient(_ entry: LibraryEntry) async {
        guard entry.relativePath.split(separator: "/").last?.lowercased() == "steam.exe" else {
            error = "Choose Steam.exe from the Steam installation folder."; return
        }
        UserDefaults.standard.set(entry.relativePath, forKey: "madeiraSteamClient")
        await refresh()
    }
}

struct SteamLibraryView: View {
    @ObservedObject private var model = SteamLibraryModel.shared
    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importInstaller = false
    @State private var chooseClient = false
    let play: (LibraryEntry) -> Void
    let enableJIT: () -> Void
    private func launch(_ entry: LibraryEntry) {
        guard jit_check_debugged() else { model.error = "Enable JIT before opening Steam."; return }
        do { try entry.validate() } catch { model.error = error.localizedDescription; return }
        model.stopScan()
        play(entry)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your Steam library", systemImage: "storefront").font(.title2.bold())
                    Text("Sign in, install games, and manage updates in Steam. Installed games appear in Madeira after you close the Steam session.")
                        .foregroundStyle(.secondary)
                    Text("Steam support is experimental. Keep Madeira open during downloads. Some titles and Steam features may not work with this Windows environment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if model.busy {
                        ProgressView("Preparing installer…", value: model.progress)
                        Button("Cancel", role: .cancel) { model.cancel() }
                    } else if model.snapshot.client != nil {
                        Button { if let entry = model.clientEntry(bigPicture: false) { launch(entry) } } label: { Label("Open Steam", systemImage: "play.fill") }
                        Button { if let entry = model.clientEntry(bigPicture: true) { launch(entry) } } label: { Label("Big Picture", systemImage: "gamecontroller") }
                    } else {
                        Button { model.download(ready: launch) } label: { Label("Download & install Steam", systemImage: "arrow.down.circle") }
                        if model.cachedInstaller { Button("Run downloaded installer") { launch(model.installerEntry()) } }
                    }
                    Button(action: enableJIT) { Label("Enable JIT", systemImage: "bolt.fill") }.disabled(model.busy)
                } footer: {
                    Text("The Windows client is downloaded from Valve, then installed in drive_c. Your sign-in and Steam Guard stay inside Steam. Use the in-game menu’s Quit game action to return here.")
                }
                if !model.snapshot.apps.isEmpty {
                    Section("On this device") {
                        ForEach(model.snapshot.apps) { app in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                    Text(app.installed ? (app.needsUpdate ? "Update pending" : "Installed") : "Download incomplete")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.installed {
                                    Button("Add") {
                                        var ignored = UserDefaults.standard.array(forKey: "madeiraSteamHidden") as? [Int] ?? []
                                        ignored.removeAll { $0 == app.id }; UserDefaults.standard.set(ignored, forKey: "madeiraSteamHidden")
                                        library.mergeSteam(model.snapshot)
                                    }.disabled(library.entries.contains { $0.steamAppID == app.id })
                                }
                            }
                        }
                    }
                }
                Section("Manage") {
                    Button { Task { await model.refresh() } } label: {
                        HStack { Label("Refresh installed games", systemImage: "arrow.clockwise"); if model.refreshing { Spacer(); ProgressView() } }
                    }.disabled(model.refreshing || model.busy)
                    Button("Locate an existing Steam installation") { chooseClient = true }.disabled(model.busy)
                    Button("Use my own Steam installer") { importInstaller = true }.disabled(model.busy)
                    Link("Steam support", destination: URL(string: "https://help.steampowered.com/")!)
                }
                if !model.snapshot.complete { Section { Text("Some Steam files are still being updated or could not be read. Refresh after Steam has finished.").font(.footnote) } }
                if model.snapshot.skippedLibraries > 0 { Section { Text("Only Steam libraries inside drive_c can be imported.").font(.footnote) } }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.refresh() }
            .onDisappear { model.cancel() }
            .sheet(isPresented: $chooseClient) {
                NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                    chooseClient = false; Task { await model.chooseClient(entry) }
                } }
            }
            .fileImporter(isPresented: $importInstaller, allowedContentTypes: [.item]) { result in
                do { model.importInstaller(try result.get(), ready: launch) }
                catch { model.error = error.localizedDescription }
            }
            .alert("Steam", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}
