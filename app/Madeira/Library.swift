import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import GameController
import Combine

enum LibraryFlags {
    static func enabled(_ key: String, fallback: Bool = true) -> Bool {
        // UI preferences are needed before the launch worker imports the file.
        let path = LibraryModel.documents.appendingPathComponent("madeira-env.txt")
        if let text = try? String(contentsOf: path, encoding: .utf8),
           let line = text.components(separatedBy: .newlines).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }) {
            return line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) != "0"
        }
        return getenv(key).map { String(cString: $0) != "0" } ?? fallback
    }
}

// Shares the hardware sampler; no additional display timer during gameplay.
final class LibraryController: ObservableObject {
    static let shared = LibraryController()
    @Published var connected = false
    let commands = PassthroughSubject<String, Never>()
    private let lock = NSLock()
    private var enabled = false
    private var owns = false
    private var last: UInt16 = 0
    private var announced = false
    private let allowed = LibraryFlags.enabled("MADEIRA_FRONTEND_CONTROLLER")
    var ownsInput: Bool { lock.lock(); defer { lock.unlock() }; return enabled && owns }
    func configure(enabled: Bool, ownsInput: Bool) {
        lock.lock(); self.enabled = enabled && allowed; owns = ownsInput; lock.unlock()
    }
    func sample(_ sample: HardwareInput.PadSnapshot) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var buttons = sample.buttons
        if owns {
            if sample.lx < -16000 { buttons |= 4 }; if sample.lx > 16000 { buttons |= 8 }
            if sample.ly > 16000 { buttons |= 1 }; if sample.ly < -16000 { buttons |= 2 }
        }
        let pressed = buttons & ~last; last = buttons
        let own = owns, announce = !announced; announced = true
        lock.unlock()
        if announce { DispatchQueue.main.async { self.connected = true; fputs("[frontend-controller] ml1150 navigation active\n", stderr) } }
        var command: String?
        // Reserve the Back+Start chord in gameplay, leaving ordinary Start intact.
        if !own, buttons & 0x30 == 0x30, pressed & 0x30 != 0 { command = "menu" }
        if own {
            for (mask, name): (UInt16, String) in [(1, "up"), (2, "down"), (4, "left"), (8, "right"), (0x1000, "accept"), (0x2000, "back"), (0x8000, "add"), (0x10, "menu"), (0x100, "tab"), (0x200, "tab")] {
                if pressed & mask != 0 { command = name; break }
            }
        }
        if let command { DispatchQueue.main.async { self.commands.send(command) } }
    }
}

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
    var graphicsAPI: String?
    var overlayFields: [String]?
    var semaphoreFastPath: Bool?
    var desktop: Bool?
    static let desktopID = UUID(uuidString: "AF046C35-C32A-497B-92BC-0BBD14F8CB61")!
    static var desktopEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Desktop", relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = desktopID; entry.desktop = true; entry.graphicsAPI = "Wine desktop"
        return entry
    }

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
        configureLaunch()
        setenv("FEX_X87REDUCEDPRECISION", reducedX87 ? "1" : "0", 1)
        setenv("MADEIRA_FASTSYNC", fastSync ? "auto" : "0", 1)
        if let semaphoreFastPath { setenv("MADEIRA_FASTSYNC_SEM", semaphoreFastPath ? "1" : "0", 1) }
        setenv("MADEIRA_EXTENDED_MODES", extendedModes ? "1" : "0", 1)
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
        madeira_set_vsync_locked(Int32(fpsMode))
        fputs("[frontend] ml1140 launch profile applied\n", stderr)
    }
    func configureLaunch() {
        setenv("MADEIRA_EXE", desktop == true ? "explorer.exe" : windowsPath, 1)
        setenv("MADEIRA_ARGS", desktop == true ? "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" : arguments, 1)
        if desktop == true { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
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
    @Published var launching = false
    @Published var overlayFields = ["FPS", "Frame time", "RAM", "Battery"]
    private var launchPresent: UInt64 = 0
    private var launchSurface: UInt64 = 0
    private var launchStarted = Date()
    @Published var launchSlow = false
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
        LibraryController.shared.configure(enabled: allowed, ownsInput: allowed)
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
        var entry = LibraryEntry(title: name, relativePath: relative, bits: machine == 0x14c ? 32 : 64)
        entry.graphicsAPI = graphicsImports(url)
        return entry
    }

    // Read the PE import directory, rather than guessing from the executable's name.
    static func graphicsImports(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64); guard dos.count == 64 else { return nil }
        let base = UInt64(u32(dos, 60)); guard base < 16 * 1024 * 1024 else { return nil }
        let header = read(base, 264); guard header.count >= 144 else { return nil }
        let sections = Int(header[6]) | Int(header[7]) << 8
        let optSize = Int(header[20]) | Int(header[21]) << 8
        guard sections <= 96, optSize >= 120 else { return nil }
        let imports = u32(header, header[24] == 0x0b && header[25] == 2 ? 144 : 128)
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            guard table.count == sections * 40 else { return nil }
            for index in 0..<sections {
                let i = index * 40, va = u32(table, index * 40 + 12), size = u32(table, index * 40 + 16)
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        guard imports != 0, let start = fileOffset(imports) else { return nil }
        var levels = Set<String>()
        for i in 0..<256 {
            let descriptor = read(start + UInt64(i * 20), 20)
            guard descriptor.count == 20 else { break }
            let nameRVA = u32(descriptor, 12); if nameRVA == 0 { break }
            guard let offset = fileOffset(nameRVA) else { continue }
            let data = read(offset, 128)
            let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
            switch name {
            case "d3d9.dll": levels.insert("D3D9")
            case "d3d10.dll", "d3d10_1.dll": levels.insert("D3D10")
            case "d3d11.dll": levels.insert("D3D11")
            case "d3d12.dll": levels.insert("D3D12")
            case "opengl32.dll": levels.insert("OpenGL")
            default: break
            }
        }
        return levels.isEmpty ? nil : levels.sorted().joined(separator: " / ")
    }

    func begin(_ entry: LibraryEntry) {
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false
        launchSurface = winios_surface_present_count()
        launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        LogStore.shared.setDisplayActive(entry.liveLogs)
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
        if launching {
            if madeira_get_present_count() >= launchPresent + 3 || winios_surface_present_count() > launchSurface {
                withAnimation(.easeInOut(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.4)) { launching = false }
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
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
        LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: true)
        menu = true
    }
    func requestQuit() {
        LibraryKeyboard.hide()
        if wineserver_request_session_stop() != 0 {
            InputGuard.shared.releaseAll("frontend-quit")
            sessionMessage = "Closing…"; menu = false
            return
        }
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
            entry.fpsMode = fpsMode; entry.performance = performance
            entry.overlayFields = overlayFields; save(entry)
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
        LogStore.shared.setDisplayActive(true)
        launching = false; LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
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
    static func nearest(_ query: String, _ matches: [SteamMatch]) -> SteamMatch? {
        func normalized(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber } }
        func distance(_ a: String, _ b: String) -> Int {
            let a = Array(a.prefix(120)), b = Array(b.prefix(120))
            var row = Array(0...b.count)
            for (i, c) in a.enumerated() {
                var next = [i + 1]
                for (j, d) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (c == d ? 0 : 1))) }
                row = next
            }
            return row.last ?? 0
        }
        let q = normalized(query)
        return matches.min { distance(q, normalized($0.name)) < distance(q, normalized($1.name)) }
    }
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
    var backdrop = false
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.6), .teal.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: entry.desktop == true ? "desktopcomputer" : "gamecontroller.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            if let name = entry.coverFile,
               let image = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let id = entry.steamID {
                AsyncImage(url: backdrop ? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg") : SteamCatalog.cover(id)) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped().accessibilityHidden(true)
        }
    }
}

struct LibraryBadges: View {
    let entry: LibraryEntry
    var body: some View {
        HStack(spacing: 6) {
            badge("\(entry.bits)-bit")
            badge(entry.graphicsAPI ?? "API auto")
        }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct LibraryStatus: View {
    @State private var jit = false
    @State private var memory = false
    let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 14) { status("JIT", jit); status("Memory+", memory) }
            .onAppear { update() }.onReceive(ticks) { _ in update() }
    }
    private func status(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 5) { Circle().fill(enabled ? Color.green : Color.orange).frame(width: 6, height: 6); Text(label).font(.caption2) }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(enabled ? "enabled" : "unavailable")")
    }
    private func update() { jit = jit_check_debugged(); memory = EntitlementStatus.check().increasedMemory }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @State private var browser = false
    @State private var selected: LibraryEntry?
    @State private var search = ""
    @State private var focused: UUID?
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            library.tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }.tag(0)
            settings.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(1)
        }.preferredColorScheme(.dark)
        .onReceive(controller.commands) { command in
            if selected == nil, !browser, command == "tab" { tab = 1 - tab }
        }
    }
    private var settings: some View {
        Form {
            Section("Ready to play") {
                LibraryStatus()
                Button(action: enableJIT) { Label("Enable JIT", systemImage: "bolt.fill") }
            }
            Section {
                Toggle("Extended logging", isOn: $input.diagnostics)
            } header: { Text("Diagnostics") } footer: { Text("The same diagnostics switch as the bug icon. Enable it when collecting a diagnostic run; it can reduce performance.") }
            Section("Pointer") { LibraryPointerSettings() }
            Section("Controller") {
                Toggle("Right stick controls mouse", isOn: $input.padRightStickMouse)
                Text("Use the D-pad or left stick to browse, A to open or play, and B to go back. Back + Start opens the in-game menu.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                Text("Add complete application folders to Madeira/wine/drive_c using Files. Display, frame limit, and compatibility options are saved per game.")
                Text("The optional interface is enabled by MADEIRA_FRONTEND=1 in madeira-frontend.txt or madeira-env.txt.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var library: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your library").font(.largeTitle.bold())
                        LibraryStatus().foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "desktopcomputer").font(.title2).frame(width: 52, height: 52).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) { Text("Desktop").font(.headline); Text("Explore your Windows environment").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain)
                    .id(LibraryEntry.desktopID)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(focused == LibraryEntry.desktopID && controller.connected ? Color.cyan : .clear, lineWidth: 3))
                if model.entries.filter({ $0.desktop != true }).isEmpty {
                    ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Add an executable from Madeira’s drive_c folder to get started."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 210), spacing: 18, alignment: .top)], alignment: .leading, spacing: 24) {
                        ForEach(model.entries.filter { $0.desktop != true && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { entry in
                            Button { selected = entry } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    LibraryArtwork(entry: entry).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                                        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
                                    Text(entry.title).font(.headline).lineLimit(2, reservesSpace: true).foregroundStyle(.primary)
                                    LibraryBadges(entry: entry).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                                .padding(5).overlay(RoundedRectangle(cornerRadius: 22).stroke(focused == entry.id && controller.connected ? Color.cyan : .clear, lineWidth: 3))
                                .scaleEffect(focused == entry.id && controller.connected ? 1.02 : 1)
                                .id(entry.id)
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 1100)
        }
        .background(LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.18), .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) {
            if controller.connected { Text("D-pad / stick  Browse     A  Details     Y  Add").font(.caption.weight(.medium)).padding(14).frame(maxWidth: .infinity).background(.ultraThinMaterial) }
        }
        .onReceive(controller.commands) { command in
            guard tab == 0, selected == nil, !browser else { return }
            let items = [model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry] + model.entries.filter { $0.desktop != true && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            let index = items.firstIndex(where: { $0.id == focused }) ?? 0
            if command == "add" { browser = true }
            else if command == "accept", !items.isEmpty { selected = items[index] }
            else if ["left", "right", "up", "down"].contains(command), !items.isEmpty {
                let delta = command == "left" || command == "up" ? -1 : 1
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18)) { focused = items[(index + delta + items.count) % items.count].id }
            }
        }
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
        .onAppear { if focused == nil { focused = LibraryEntry.desktopID } }
        .onChange(of: focused) { _, id in
            if let id { withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) } }
        }
        }
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
                            LibraryBadges(entry: entry)
                            Button { leaving = true; model.save(entry); play(entry) } label: { HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Play").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }.padding(.vertical, 48)
                        .listRowBackground(Color.black.opacity(0.25))
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
                    Toggle("Fast semaphore waits", isOn: Binding(get: { entry.semaphoreFastPath ?? LibraryFlags.enabled("MADEIRA_FASTSYNC_SEM") }, set: { entry.semaphoreFastPath = $0 }))
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
            .scrollContentBackground(.hidden)
            .background {
                GeometryReader { geo in
                    LibraryArtwork(entry: entry, backdrop: true).frame(width: geo.size.width, height: geo.size.height)
                        .overlay(LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8), .black], startPoint: .top, endPoint: .bottom))
                }.ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
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
                if entry.graphicsAPI == nil, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
                guard entry.desktop != true, entry.steamID == nil, entry.coverFile == nil else { return }
                let original = entry.title
                do {
                    let matches = try await SteamCatalog.search(original)
                    try Task.checkCancellation()
                    if entry.title == original, entry.steamID == nil, let match = SteamCatalog.nearest(original, matches) {
                        entry.steamID = match.id; entry.title = match.name; model.save(entry)
                        fputs("[frontend] ml1150 automatic catalog match applied\n", stderr)
                    }
                } catch { /* Manual editing remains available when offline. */ }
            }
            .onDisappear { if !leaving { model.save(entry) } }
            .onReceive(LibraryController.shared.commands) { command in
                guard !findCover, !importCover, !remove else { return }
                if command == "back" { model.save(entry); dismiss() }
                if command == "accept" { leaving = true; model.save(entry); play(entry) }
            }
            .safeAreaInset(edge: .bottom) {
                if LibraryController.shared.connected { Text("A  Play     B  Back").font(.caption).padding(12).frame(maxWidth: .infinity).background(.ultraThinMaterial) }
            }
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
    var body: some View {
        HStack { Text("FPS limit"); Spacer(); Picker("FPS limit", selection: $mode) { Text("30 FPS").tag(3); Text("60 FPS").tag(1); Text("Display maximum").tag(0); Text("Uncapped").tag(2) }.labelsHidden().pickerStyle(.menu) }
    }
}

struct LibraryPointerSettings: View {
    @ObservedObject private var input = InputSettings.shared
    private var mode: Binding<String> {
        Binding(get: { input.touchMode ? "touch" : (input.relative ? "relative" : "absolute") }, set: { value in
            InputGuard.shared.releaseAll("frontend-pointer-mode")
            input.touchMode = value == "touch"; input.relative = value == "relative"
            fputs("[frontend-pointer] ml1150 mode=\(value)\n", stderr)
        })
    }
    var body: some View {
        Picker("Pointer mode", selection: mode) {
            Text("Absolute").tag("absolute"); Text("Relative").tag("relative"); Text("Touch").tag("touch")
        }.pickerStyle(.segmented)
        Text(input.touchMode ? "Tap the screen to position and click. Hold and move to drag." : (input.relative ? "Drag to send relative mouse movement. Tap to click." : "Drag the pointer like a trackpad. Tap to click."))
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Touch sensitivity") {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.1...8)
        }
        LabeledContent("Mouse sensitivity") { Slider(value: $input.sensMouse, in: 0.1...8) }
    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faded = false
    @State private var touched = 0
    var body: some View {
        GeometryReader { geo in
            let x = min(max(30, geo.size.width * nx + drag.width), max(30, geo.size.width - 30))
            let y = min(max(geo.safeAreaInsets.top + 30, geo.size.height * ny + drag.height), max(30, geo.size.height - geo.safeAreaInsets.bottom - 30))
            ZStack(alignment: .topLeading) {
                if model.launching, let entry = model.entries.first(where: { $0.id == model.current }) {
                    LibraryArtwork(entry: entry, backdrop: true).overlay(.black.opacity(0.65)).ignoresSafeArea()
                    VStack(spacing: 18) {
                        LibraryArtwork(entry: entry).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)
                        Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                        ProgressView().tint(.white)
                        Text(model.launchSlow ? "Still starting…" : "Starting your game…").foregroundStyle(.white.opacity(0.7))
                        if model.launchSlow { Button("Show game view") { model.launching = false } }
                    }.frame(width: geo.size.width, height: geo.size.height).foregroundStyle(.white).transition(.opacity)
                }
                if model.performance { LibraryMetrics().padding(.top, geo.safeAreaInsets.top + 8).padding(.leading, geo.safeAreaInsets.leading + 12).allowsHitTesting(false) }
                if model.liveLogs { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, geo.safeAreaInsets.top + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, geo.safeAreaInsets.top + 12).allowsHitTesting(false) }
                Button { touched += 1; model.showMenu() } label: { Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).foregroundStyle(.white).frame(width: 48, height: 48).background(.black.opacity(0.75), in: Circle()).overlay(Circle().stroke(.white.opacity(0.2))) }
                    .opacity(faded && drag == .zero && !model.menu ? 0.3 : 1)
                    .accessibilityLabel("Game menu. Drag to move.")
                    .simultaneousGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                        touched += 1
                        nx = min(max(0.05, (geo.size.width * nx + value.translation.width) / max(1, geo.size.width)), 0.95)
                        ny = min(max(0.05, (geo.size.height * ny + value.translation.height) / max(1, geo.size.height)), 0.95)
                    })
                    .position(x: x, y: y)
                    .background(GeometryReader { measure in
                        let rect = CGRect(x: x - 26, y: y - 26, width: 52, height: 52)
                        Color.clear.onAppear { model.menuButtonRect = rect }.onChange(of: rect) { _, value in model.menuButtonRect = value }
                    })
                if model.menu {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.menu = false }.transition(.opacity)
                    menu.frame(width: min(460, geo.size.width - 32), height: min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))
                        .background(Color(red: 0.075, green: 0.085, blue: 0.12), in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
        .task(id: touched) {
            faded = false
            do { try await Task.sleep(for: .seconds(3)); withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { faded = true } } catch { }
        }
        .onAppear { model.saveCurrentProfile() }
        .onChange(of: model.menu) { _, open in
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: open)
            if !open { model.saveCurrentProfile() }
        }
        .onReceive(LibraryController.shared.commands) { command in
            if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if command == "back", model.menu { model.menu = false }
        }
    }
    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label("Session", systemImage: "gamecontroller.fill").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false }.buttonStyle(.bordered) }
                Toggle("Performance overlay", isOn: $model.performance)
                if model.performance {
                    ForEach(["FPS", "Frame time", "RAM", "Battery"], id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
                }
                FPSChoice(mode: Binding(get: { model.fpsMode }, set: { model.setFPS($0) }))
                Divider()
                Text("Mouse & pointer").font(.headline)
                LibraryPointerSettings()
                Divider()
                Toggle("Touch controls", isOn: $controls.visible)
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }
                Divider()
                Button("Quit game", systemImage: "stop.circle", role: .destructive) { model.requestQuit() }
                Text("Closes the running session. Unsaved progress will be lost.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
                .foregroundStyle(.white).tint(.cyan)
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
    @ObservedObject private var model = LibraryModel.shared
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var fps = 0.0
    @State private var memory = 0
    @State private var battery = -1
    private let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(.caption.monospacedDigit().weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
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
    private var parts: [String] {
        var result: [String] = []
        if model.overlayFields.contains("FPS") { result.append(String(format: "%.0f FPS", fps)) }
        if model.overlayFields.contains("Frame time") { result.append(fps > 0 ? String(format: "%.1f ms avg", 1000 / fps) : "— ms") }
        if model.overlayFields.contains("RAM") { result.append("\(memory) MB") }
        if model.overlayFields.contains("Battery"), battery >= 0 { result.append("\(battery)%") }
        return result
    }
}

// A key window is required for UIKit text input; the rendering placeholder lives
// beneath separate presentation and control windows and cannot reliably own it.
enum LibraryKeyboard {
    static var window: UIWindow?
    static weak var previous: UIWindow?
    static var input: LibraryKeyInput?
    static func show() {
        if let value = getenv("MADEIRA_FRONTEND_KEYBOARD"), String(cString: value) == "0" { MetalBackedView.toggleKeyboard(); return }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        previous = scene.windows.first(where: { $0.isKeyWindow })
        let w = LibraryKeyboardWindow(windowScene: scene)
        w.windowLevel = .normal + 102; w.backgroundColor = .clear
        let controller = UIViewController(); controller.view.backgroundColor = .clear
        w.rootViewController = controller
        let v = LibraryKeyInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(v); input = v; window = w
        w.makeKeyAndVisible(); v.becomeFirstResponder()
        fputs("[frontend-keyboard] ml1150 key-window input activated\n", stderr)
    }
    static func hide() {
        input?.releaseModifiers(); input?.resignFirstResponder(); window?.isHidden = true
        window = nil; input = nil; previous?.makeKey(); previous = nil
    }
}
final class LibraryKeyboardWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
final class LibraryKeyInput: UIView, UIKeyInput {
    var hasText: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    private var held = Set<Int32>()
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    override var inputAccessoryView: UIView? {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 650, height: 52)); scroll.backgroundColor = .secondarySystemBackground
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 5
        for (title, key) in [("Esc", 0x1b), ("Ctrl", 0x11), ("Shift", 0x10), ("Alt", 0x12), ("Tab", 0x09), ("Enter", 0x0d), ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27), ("Done", 0)] {
            let button = UIButton(type: .system); button.configuration = .tinted(); button.setTitle(title, for: .normal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }
                let vk = Int32(key)
                if key == 0 { LibraryKeyboard.hide() }
                else if [0x10, 0x11, 0x12].contains(key) {
                    if self.held.contains(vk) { self.held.remove(vk); winios_post_key(vk, 0) }
                    else { self.held.insert(vk); winios_post_key(vk, 1) }
                    button?.isSelected = self.held.contains(vk)
                } else { self.press(vk) }
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        scroll.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8), row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4), row.heightAnchor.constraint(equalToConstant: 44)])
        return scroll
    }
    private func press(_ vk: Int32) { winios_post_key(vk, 1); winios_post_key(vk, 0) }
    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            let temporary = shift && !held.contains(0x10)
            if temporary { winios_post_key(0x10, 1) }; press(vk); if temporary { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() { press(0x08) }
    func releaseModifiers() { for key in held { winios_post_key(key, 0) }; held.removeAll() }
}
