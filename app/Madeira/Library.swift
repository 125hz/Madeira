import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO

// ml1140: opt-in library. Removing MADEIRA_FRONTEND=1 restores the diagnostic UI.
struct LibraryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    var relativePath: String
    var bits: Int
    var steamID: Int?
    var coverFile: String?
    var arguments = ""
    var resolution = "1280x720"
    var display = "fit"
    var fpsMode = 1
    var reducedX87 = true
    var fastSync = true
    var extendedModes = false
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controlOpacity = 0.7
    var controlSize = 1.0
    var controls: [TouchControl]?
    var lastPlayed: Date?

    var windowsPath: String { "C:\\" + relativePath.replacingOccurrences(of: "/", with: "\\") }

    func validate() throws {
        let size = resolution.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, (320...4096).contains(size[0]), (240...4096).contains(size[1]),
              (0...3).contains(fpsMode), !arguments.contains("\0"), !windowsPath.contains("\0") else {
            throw LibraryError.message("The saved launch profile contains invalid display or argument values.")
        }
        var quoted = false, inToken = false, tokens = 0
        for character in arguments {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
        }
        guard !quoted, tokens <= 16 else { throw LibraryError.message("Use balanced double quotes and at most 16 launch arguments.") }
    }

    // Called on the existing launch worker, after text-file defaults are read.
    func applyEnvironment() {
        setenv("MADEIRA_EXE", windowsPath, 1)
        setenv("MADEIRA_ARGS", arguments, 1)
        unsetenv("MADEIRA_DESKTOP")
        setenv("FEX_X87REDUCEDPRECISION", reducedX87 ? "1" : "0", 1)
        setenv("MADEIRA_FASTSYNC", fastSync ? "auto" : "0", 1)
        setenv("MADEIRA_EXTENDED_MODES", extendedModes ? "1" : "0", 1)
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
        madeira_set_vsync_locked(Int32(fpsMode))
        fputs("[frontend] ml1140 launch profile applied\n", stderr)
    }
}

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var drive: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true).resolvingSymlinksInPath() }
    @Published var enabled = false
    @Published var entries: [LibraryEntry] = []
    @Published var current: UUID?
    @Published var menu = false
    @Published var performance = false
    @Published var liveLogs = false
    @Published var opacity = 0.7
    @Published var fpsMode = 1
    @Published var error: String?
    @Published var sessionMessage = ""
    var menuButtonRect = CGRect.zero
    private var timer: Timer?
    private var sawProcess = false
    private var readOnly = false
    private var savedControls: [TouchControl] = []
    private var savedVisible = true
    private var savedSize = 1.0
    private var savedDisplay = DisplayMode.fit
    private struct Document: Codable { var version: Int; var entries: [LibraryEntry] }
    private var file: URL { Self.documents.appendingPathComponent("madeira-library.json") }

    private init() {
        refreshFlag()
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard doc.version == 1 else { throw LibraryError.message("This library uses a newer format.") }
            entries = doc.entries
        } catch {
            readOnly = true
            self.error = "Library could not be opened. The original file was preserved. " + error.localizedDescription
        }
    }

    func refreshFlag() {
        guard current == nil, wine_process_is_running() == 0 else { return }
        let allowed = ["madeira-env.txt", "madeira-frontend.txt"].contains { name in
            guard let text = try? String(contentsOf: Self.documents.appendingPathComponent(name), encoding: .utf8) else { return false }
            return text.components(separatedBy: .newlines).contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "MADEIRA_FRONTEND=1"
            }
        }
        if enabled != allowed { fputs("[frontend] ml1140 enabled=\(allowed ? 1 : 0)\n", stderr) }
        enabled = allowed
    }

    func save(_ entry: LibraryEntry) {
        guard !readOnly else { error = "The library file could not be read. Preserve or repair it before making changes."; return }
        var next = entries
        if let i = next.firstIndex(where: { $0.id == entry.id }) { next[i] = entry }
        else { next.append(entry) }
        persist(next)
    }
    func remove(_ id: UUID) { persist(entries.filter { $0.id != id }) }
    private func persist(_ next: [LibraryEntry]) {
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(version: 1, entries: next)).write(to: file, options: .atomic)
            entries = next
        } catch { self.error = "Could not save the library: " + error.localizedDescription }
    }

    static func executable(_ relative: String) throws -> URL {
        let url = drive.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(drive.path + "/"), url.pathExtension.lowercased() == "exe",
              FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryError.message("Choose an executable inside drive_c.")
        }
        return url
    }
    static func inspect(_ url: URL) throws -> LibraryEntry {
        guard url.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/") else {
            throw LibraryError.message("The executable must be inside drive_c.")
        }
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let dos = try h.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw LibraryError.message("This is not a Windows executable.") }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | (UInt64(dos[60 + $1]) << ($1 * 8)) }
        guard offset >= 64, offset < 16 * 1024 * 1024 else { throw LibraryError.message("Invalid executable header.") }
        try h.seek(toOffset: offset)
        let pe = try h.read(upToCount: 6) ?? Data()
        guard pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { throw LibraryError.message("Missing PE header.") }
        let machine = Int(pe[4]) | Int(pe[5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw LibraryError.message("Only x86 and x64 executables are supported.") }
        let relative = String(url.resolvingSymlinksInPath().path.dropFirst(drive.path.count + 1))
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        return LibraryEntry(title: name, relativePath: relative, bits: machine == 0x14c ? 32 : 64)
    }

    func begin(_ entry: LibraryEntry) {
        current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        opacity = entry.controlOpacity; fpsMode = entry.fpsMode; sessionMessage = "Starting…"
        let controls = TouchControlsModel.shared
        savedControls = controls.controls; savedVisible = controls.visible; savedSize = controls.sizeScale
        savedDisplay = InputSettings.shared.displayMode
        if let profile = entry.controls { controls.controls = profile }
        controls.visible = entry.touchControls; controls.sizeScale = entry.controlSize
        InputSettings.shared.displayMode = DisplayMode(rawValue: entry.display) ?? .fit
        FullscreenState.shared.active = true
        MetalHostView.shared.isHidden = false
        ProMotionIntent.shared.setActive(true, maxHz: ProMotionIntent.maxHz(for: Int32(entry.fpsMode)))
        var played = entry; played.lastPlayed = Date(); save(played)
        sawProcess = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        if wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if sawProcess && wineserver_is_running() == 0 { finish() }
    }
    func launchFailed() { if current != nil && !sawProcess { finish(); error = "The session could not start. Check the diagnostic log and JIT status." } }
    func setFPS(_ mode: Int) {
        fpsMode = mode; madeira_set_vsync_locked(Int32(mode))
        ProMotionIntent.shared.setActive(true, maxHz: ProMotionIntent.maxHz(for: Int32(mode)))
        saveCurrentProfile()
    }
    func showMenu() {
        InputGuard.shared.releaseAll("frontend-menu")
        menu = true
    }
    func requestQuit() {
        // Use the existing input queue so the application can save and close normally.
        // Keep the surface visible until the native session actually ends.
        InputGuard.shared.releaseAll("frontend-quit")
        winios_post_key(0x12, 1); winios_post_key(0x73, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            winios_post_key(0x73, 0); winios_post_key(0x12, 0)
        }
        sessionMessage = "Close requested. Confirm any in-game exit dialog."
        menu = false
        fputs("[frontend] ml1140 graceful close requested\n", stderr)
    }
    func saveCurrentProfile() {
        let controls = TouchControlsModel.shared
        if let id = current, var entry = entries.first(where: { $0.id == id }) {
            entry.controls = controls.controls; entry.controlSize = controls.sizeScale
            entry.touchControls = controls.visible; entry.controlOpacity = opacity
            entry.fpsMode = fpsMode; entry.performance = performance; save(entry)
        }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        saveCurrentProfile()
        let controls = TouchControlsModel.shared
        InputGuard.shared.releaseAll("frontend-exit")
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        InputSettings.shared.displayMode = savedDisplay
        current = nil; menu = false; sessionMessage = ""
        FullscreenState.shared.active = false; MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        fputs("[frontend] ml1140 returned to library\n", stderr)
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct SteamMatch: Decodable, Identifiable {
    let id: Int
    let name: String
    let tiny_image: String?
}
enum SteamCatalog {
    // Public Store search: no account, credentials, or private library access.
    static func search(_ text: String) async throws -> [SteamMatch] {
        var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        url.queryItems = [URLQueryItem(name: "term", value: text), URLQueryItem(name: "l", value: "english"), URLQueryItem(name: "cc", value: "US")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 2_000_000 else {
            throw LibraryError.message("Steam search is unavailable. You can still edit the title and artwork manually.")
        }
        struct Results: Decodable { var items: [SteamMatch] }
        return Array(try JSONDecoder().decode(Results.self, from: data).items.prefix(30))
    }
    static func cover(_ id: Int) -> URL? { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_600x900.jpg") }
}

struct LibraryArtwork: View {
    let entry: LibraryEntry
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.6), .teal.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            if let name = entry.coverFile,
               let image = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let id = entry.steamID {
                AsyncImage(url: SteamCatalog.cover(id)) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .clipped().accessibilityHidden(true)
    }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @State private var browser = false
    @State private var selected: LibraryEntry?
    @State private var search = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your library").font(.largeTitle.bold())
                        Text("PC games, a little closer.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: enableJIT) { Label("Enable JIT", systemImage: "bolt.fill") }.buttonStyle(.bordered)
                }
                if model.entries.isEmpty {
                    ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Add an executable from Madeira’s drive_c folder to get started."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 18)], spacing: 24) {
                        ForEach(model.entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { entry in
                            Button { selected = entry } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    LibraryArtwork(entry: entry).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 18))
                                    Text(entry.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
                                    Text("\(entry.bits)-bit · \(entry.resolution)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 1100)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .searchable(text: $search, prompt: "Search your library")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { browser = true } label: { Label("Add executable", systemImage: "plus") } } }
        .sheet(isPresented: $browser) {
            NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                model.save(entry); browser = false; selected = entry
            } }
        }
        .sheet(item: $selected) { entry in
            LibraryDetail(entry: entry, play: { profile in selected = nil; play(profile) })
        }
        .alert("Library", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshFlag() } }
    }
}

struct ExecutableBrowser: View {
    let folder: URL
    var select: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files, id: \.path) { file in
                if file.hasDirectoryPath {
                    NavigationLink { ExecutableBrowser(folder: file, select: select) } label: { Label(file.lastPathComponent, systemImage: "folder") }
                } else {
                    Button { do { select(try LibraryModel.inspect(file)) } catch { self.error = error.localizedDescription } } label: {
                        Label(file.lastPathComponent, systemImage: "app.dashed")
                    }
                }
            }
            if files.isEmpty && error == nil { Text("No executables here. Copy files into Madeira/wine/drive_c using Files.").foregroundStyle(.secondary) }
        }.navigationTitle(folder.lastPathComponent)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            do {
                files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    .filter { ($0.hasDirectoryPath || $0.pathExtension.lowercased() == "exe") && $0.resolvingSymlinksInPath().path.hasPrefix(LibraryModel.drive.path + "/") }
                    .sorted { if $0.hasDirectoryPath != $1.hasDirectoryPath { return $0.hasDirectoryPath }; return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LibraryDetail: View {
    @State var entry: LibraryEntry
    var play: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared
    @State private var findCover = false
    @State private var importCover = false
    @State private var remove = false
    @State private var leaving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 20) {
                        LibraryArtwork(entry: entry).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.title).font(.title2.bold())
                            Text("\(entry.bits)-bit Windows executable").font(.caption).foregroundStyle(.secondary)
                            Button { leaving = true; model.save(entry); play(entry) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 90) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }.padding(.vertical, 8)
                    TextField("Title", text: $entry.title)
                    Button("Find on Steam", systemImage: "magnifyingglass") { findCover = true }
                    Button("Choose cover image", systemImage: "photo") { importCover = true }
                    if entry.coverFile != nil { Button("Use Steam artwork") { entry.coverFile = nil } }
                }
                Section("Display") {
                    Picker("Resolution", selection: $entry.resolution) {
                        ForEach(["640x480", "800x600", "960x540", "1024x768", "1280x720", "1280x960", "1920x1080", "2560x1440"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Aspect & scaling", selection: $entry.display) { ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                    FPSChoice(mode: $entry.fpsMode)
                    Toggle("Offer higher display modes", isOn: $entry.extendedModes)
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    Toggle("Fast synchronization", isOn: $entry.fastSync)
                    TextField("Launch arguments", text: $entry.arguments, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: { Text("Compatibility & performance") } footer: {
                    Text("Full x87 precision can improve compatibility at a performance cost. Engine settings apply at launch; restart Madeira before changing them between sessions.")
                }
                Section("On screen") {
                    Toggle("Performance overlay", isOn: $entry.performance)
                    Toggle("Live logs", isOn: $entry.liveLogs)
                    Toggle("Touch controls", isOn: $entry.touchControls)
                    LabeledContent("Control opacity") { Slider(value: $entry.controlOpacity, in: 0.15...1) }
                    LabeledContent("Control size") { Slider(value: $entry.controlSize, in: 0.5...2) }
                    Text("Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
                Section { Button("Remove from library", role: .destructive) { remove = true } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.save(entry); dismiss() } } }
            .sheet(isPresented: $findCover) { SteamSearchView(query: entry.title) { match in entry.steamID = match.id; entry.title = match.name; entry.coverFile = nil } }
            .fileImporter(isPresented: $importCover, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (attrs.fileSize ?? Int.max) <= 20_000_000 else { throw LibraryError.message("Choose an image smaller than 20 MB.") }
                    let data = try Data(contentsOf: url)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                          let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw LibraryError.message("This image could not be opened.") }
                    let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = entry.id.uuidString + ".jpg"; try jpeg.write(to: dir.appendingPathComponent(name), options: .atomic); entry.coverFile = name
                } catch { self.error = error.localizedDescription }
            }
            .confirmationDialog("Remove this library entry? Your executable and saves stay in drive_c.", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { leaving = true; model.remove(entry.id); dismiss() }
            }
            .task {
                guard entry.steamID == nil else { return }
                // Only accept an unambiguous exact match automatically.
                do {
                    let matches = try await SteamCatalog.search(entry.title)
                    let exact = matches.filter { $0.name.compare(entry.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                    if exact.count == 1 { entry.steamID = exact[0].id }
                } catch { /* Manual editing remains available when offline. */ }
            }
            .onDisappear { if !leaving { model.save(entry) } }
        }
    }
}

struct SteamSearchView: View {
    @State var query: String
    var select: (SteamMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [SteamMatch] = []
    @State private var error: String?
    @State private var loading = false
    @State private var submitted = ""
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Searching Steam…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(results) { match in
                    Button { select(match); dismiss() } label: {
                        HStack {
                            AsyncImage(url: URL(string: match.tiny_image ?? "")) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "gamecontroller") }.frame(width: 70, height: 40)
                            Text(match.name).foregroundStyle(.primary)
                        }
                    }
                }
            }.navigationTitle("Find on Steam")
            .searchable(text: $query, prompt: "Title").onSubmit(of: .search) { submitted = query }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { submitted = query }
            .task(id: submitted) {
                guard !submitted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                loading = true; error = nil
                do { let found = try await SteamCatalog.search(submitted); try Task.checkCancellation(); results = found; if found.isEmpty { error = "No matches. Try a different title." } }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}

struct FPSChoice: View {
    @Binding var mode: Int
    var body: some View { Picker("Frame limit", selection: $mode) { Text("30 FPS").tag(3); Text("60 FPS").tag(1); Text("Display maximum").tag(0); Text("Uncapped").tag(2) } }
}

struct LibraryGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)) }
    }
}

struct LibraryHUD: View {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @AppStorage("madeiraLibraryMenuX") private var nx = 0.92
    @AppStorage("madeiraLibraryMenuY") private var ny = 0.12
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { geo in
            let x = min(max(30, geo.size.width * nx + drag.width), max(30, geo.size.width - 30))
            let y = min(max(geo.safeAreaInsets.top + 30, geo.size.height * ny + drag.height), max(30, geo.size.height - geo.safeAreaInsets.bottom - 30))
            ZStack(alignment: .topLeading) {
                if model.performance { LibraryMetrics().padding(.top, geo.safeAreaInsets.top + 8).padding(.leading, geo.safeAreaInsets.leading + 12).allowsHitTesting(false) }
                if model.liveLogs { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, geo.safeAreaInsets.top + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, geo.safeAreaInsets.top + 12).allowsHitTesting(false) }
                Button { model.showMenu() } label: { Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).frame(width: 48, height: 48).modifier(LibraryGlass()) }
                    .accessibilityLabel("Game menu. Drag to move.")
                    .simultaneousGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                        nx = min(max(0.05, (geo.size.width * nx + value.translation.width) / max(1, geo.size.width)), 0.95)
                        ny = min(max(0.05, (geo.size.height * ny + value.translation.height) / max(1, geo.size.height)), 0.95)
                    })
                    .position(x: x, y: y)
                    .background(GeometryReader { measure in
                        let rect = CGRect(x: x - 26, y: y - 26, width: 52, height: 52)
                        Color.clear.onAppear { model.menuButtonRect = rect }.onChange(of: rect) { _, value in model.menuButtonRect = value }
                    })
                if model.menu {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.menu = false }
                    menu.frame(width: min(370, geo.size.width - 32), height: min(570, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))
                        .modifier(LibraryGlass()).position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }.ignoresSafeArea()
        .onAppear { model.saveCurrentProfile() }
        .onChange(of: model.menu) { _, open in if !open { model.saveCurrentProfile() } }
    }
    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("In game").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false } }
                Toggle("Performance", isOn: $model.performance)
                FPSChoice(mode: Binding(get: { model.fpsMode }, set: { model.setFPS($0) }))
                Divider()
                Toggle("Touch controls", isOn: $controls.visible)
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; MetalBackedView.toggleKeyboard() }
                Divider()
                Button("Quit game", systemImage: "stop.circle", role: .destructive) { model.requestQuit() }
                Text("If the game asks to save or confirm, finish that dialog to return to your library.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
}

struct LibraryLiveLogs: View {
    @ObservedObject private var logs = LogStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { ForEach(Array(logs.entries.suffix(7))) { Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2) } }
            .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
    }
}

struct LibraryMetrics: View {
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var fps = 0.0
    @State private var memory = 0
    @State private var battery = -1
    private let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(String(format: "%.0f FPS  ·  %d MB", fps, memory) + (battery >= 0 ? "  ·  \(battery)%" : ""))
            .font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .onAppear { lastCount = madeira_get_present_count(); lastTime = Date(); UIDevice.current.isBatteryMonitoringEnabled = true }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false }
            .onReceive(ticks) { now in
                let count = madeira_get_present_count(); let dt = now.timeIntervalSince(lastTime)
                fps = count >= lastCount ? Double(count - lastCount) / max(0.001, dt) : 0; lastCount = count; lastTime = now
                var info = task_vm_info_data_t(); var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
                if result == KERN_SUCCESS { memory = Int(info.phys_footprint / 1048576) }
                battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
            }
    }
}
