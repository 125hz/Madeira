import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import Combine

// ============================================================================
// Library front end.
//
// A game library in front of the existing launch path: entries are Windows
// executables inside the prefix's drive_c, each with its own launch profile
// (arguments, resolution and scaling, frame limit, x87 precision, on-screen
// controls). Play starts the same runWineFullSequence the developer interface
// uses; the session runs full screen with a small in-game menu.
//
// The developer interface stays available: Settings › Interface switches back
// to it (FrontendChoice), and it has a "Use New Interface" button to return.
// Every switch below is read with MadeiraConfig.flag, so `env.NAME = 0` in
// madeira.cfg turns it off.
// ============================================================================

/// Thermal state, Low Power Mode and screen capture every 10 s while a session
/// runs: the three device conditions that explain a slow run in a log.
/// MADEIRA_DEVICE_STATS=0 turns the line off.
enum DeviceLoadDiagnostics {
    private static var lastReport = 0.0
    private static var timer: Timer?
    /// Opt-in (env.MADEIRA_DEVICE_STATS = 1): a line every 10 s during every
    /// session is a diagnostic, so it is off by default.
    static func start() {
        guard timer == nil, MadeiraConfig.flag("MADEIRA_DEVICE_STATS", fallback: false) else { return }
        let value = Timer(timeInterval: 10, repeats: true) { _ in report() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    static func report() {
        guard wine_process_is_running() != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastReport >= 10 else { return }
        lastReport = now
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        fputs("[device-load] thermal=\(thermal) low-power=\(process.isLowPowerModeEnabled ? 1 : 0) capture=\(UIScreen.main.isCaptured ? 1 : 0)\n", stderr)
    }
}

/// Which build is installed, shown in light grey in both interfaces and logged
/// once at start ([build]). A build that writes `MadeiraBuild` into Info.plist
/// (a round tag and build time) shows that; other builds show the bundle
/// version. MADEIRA_BUILD_LABEL=0 hides the label (the log line stays).
enum BuildStamp {
    static let text: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        if let stamp = info["MadeiraBuild"] as? String, !stamp.isEmpty { return stamp }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }()
    static let visible = MadeiraConfig.flag("MADEIRA_BUILD_LABEL")
}

/// Controller navigation of the library, fed by GamepadInput's sampler (player
/// 1's physical pad) so there is no second timer. While the library owns input
/// (no session, or the in-game menu is open) GamepadInput publishes a neutral
/// pad to Windows. D-pad or left stick moves the focus, A opens, B goes back,
/// Y adds a game, a shoulder switches tabs; in a session Back+Start opens the
/// menu. MADEIRA_FRONTEND_CONTROLLER=0 turns navigation off.
final class LibraryController: ObservableObject, @unchecked Sendable {
    static let shared = LibraryController()
    @Published var connected = false
    let commands = PassthroughSubject<String, Never>()
    private let lock = NSLock()
    private var enabled = false
    private var owns = false
    private var last: UInt16 = 0
    private var announced = false
    private let allowed = MadeiraConfig.flag("MADEIRA_FRONTEND_CONTROLLER")
    var ownsInput: Bool { lock.lock(); defer { lock.unlock() }; return enabled && owns }
    func configure(enabled: Bool, ownsInput: Bool) {
        lock.lock(); self.enabled = enabled && allowed; owns = ownsInput; lock.unlock()
    }
    /// One sample of player 1's pad, in XInput button bits and stick units.
    func sample(buttons raw: UInt16, lx: Int16, ly: Int16) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var buttons = raw
        if owns {
            if lx < -16000 { buttons |= 4 }; if lx > 16000 { buttons |= 8 }
            if ly > 16000 { buttons |= 1 }; if ly < -16000 { buttons |= 2 }
        }
        let pressed = buttons & ~last; last = buttons
        let own = owns, announce = !announced; announced = true
        lock.unlock()
        if announce { DispatchQueue.main.async { self.connected = true; fputs("[frontend-controller] navigation active\n", stderr) } }
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

/// Which interface Madeira starts with: the library (the default) or the
/// developer interface. The choice is made in either interface, stored in
/// UserDefaults and read once per run, so a change applies at the next start.
/// Without a stored choice, MADEIRA_FRONTEND=0/1 in madeira.cfg (env.) or in
/// madeira-env.txt decides; MADEIRA_FRONTEND_DEFAULT_NEW=0 makes the developer
/// interface the default.
enum FrontendChoice {
    static let key = "madeiraFrontend"
    static let startup: (useNew: Bool, source: String) = {
        if let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) {
            return (stored == "new", "setting")
        }
        if let configured = MadeiraConfig.get("env.MADEIRA_FRONTEND") { return (configured != "0", "config") }
        if let value = getenv("MADEIRA_FRONTEND").map({ String(cString: $0) }) { return (value != "0", "environment") }
        return (MadeiraConfig.flag("MADEIRA_FRONTEND_DEFAULT_NEW"), "default")
    }()
    /// The interface the next start uses.
    static var preferNew: Bool {
        guard let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) else { return startup.useNew }
        return stored == "new"
    }
    static func choose(new useNew: Bool) {
        UserDefaults.standard.set(useNew ? "new" : "old", forKey: key)
        LogStore.shared.log("[frontend] next-start choice=\(useNew ? "library" : "developer") source=setting")
    }
    private static var logged = false
    static func logStartup() {
        guard !logged else { return }
        logged = true
        LogStore.shared.log("[frontend] choice=\(startup.useNew ? "library" : "developer") source=\(startup.source)")
    }
}

/// One game in the library and its launch profile, stored in
/// Documents/madeira-library.json (version 1). New fields must be optional so
/// older files keep decoding; unknown keys are ignored.
struct LibraryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    /// The executable, relative to drive_c ("Games/Foo/foo.exe").
    var relativePath: String
    /// 32 or 64 from the PE header, 0 when unknown.
    var bits: Int
    /// A user-chosen cover in Documents/madeira-art/.
    var coverFile: String?
    var arguments = ""
    /// The virtual monitor's size ("WxH"): the session default a game renders
    /// for (GuestDisplay.configureSessionDefault), and the Desktop entry's
    /// desktop size. New entries default to 1408x648, a wide shape near the
    /// phone's landscape aspect that most games render quickly.
    var resolution = "1408x648"
    /// How the monitor is scaled to the screen (DisplayMode raw value; nil = Fit).
    var display: String?
    /// FPS limit: 1 = 60, 3 = 30, 0 = display maximum, 2 = uncapped (madeira_set_vsync_locked).
    var fpsMode = 1
    /// FEX's X87ReducedPrecision for this game. Off by default, as in FEX; only
    /// an explicit choice exports FEX_X87REDUCEDPRECISION=1.
    var reducedX87 = false
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controls: [TouchControl]?
    /// The named layout (TouchControlPresets.swift) `controls` came from, so the
    /// Session menu shows it and an edit is written back to it; nil for controls
    /// no layout holds. Older files have none.
    var controlLayout: String?
    var lastPlayed: Date?
    var graphicsAPI: String?
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    /// The Wine desktop (explorer and services in a virtual desktop).
    var desktop: Bool?
    /// Touch controls' opacity (0.15...1, nil = 0.7) and overall size (0.5...2,
    /// nil = 1) in this game's sessions.
    var controlOpacity: Double?
    var controlSize: Double?

    var displayMode: DisplayMode { display.flatMap(DisplayMode.init(rawValue:)) ?? .fit }

    var launchArguments: String {
        if desktop == true { return "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" }
        return arguments
    }

    static let desktopID = UUID(uuidString: "AF046C35-C32A-497B-92BC-0BBD14F8CB61")!
    static var desktopEntry: LibraryEntry {
        var entry = LibraryEntry(title: "Desktop", relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = desktopID; entry.desktop = true; entry.graphicsAPI = "Wine desktop"
        return entry
    }

    var windowsPath: String { "C:\\" + relativePath.replacingOccurrences(of: "/", with: "\\") }

    /// The vsync mode to apply: a saved 30 FPS limit runs as 60 when DXMT has
    /// no 30 FPS cap (mode 3 would otherwise present uncapped).
    var effectiveFPSMode: Int32 { fpsMode == 3 && !ProMotionIntent.has30Cap ? 1 : Int32(fpsMode) }

    func validate() throws {
        let size = resolution.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, (320...4096).contains(size[0]), (240...4096).contains(size[1]),
              (0...3).contains(fpsMode), !arguments.contains("\0"), !windowsPath.contains("\0") else {
            throw LibraryError.message("The saved launch profile contains invalid display or argument values.")
        }
        var quoted = false, inToken = false, tokens = 0
        for character in launchArguments {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
        }
        // WineProcessBridge takes at most 64 arguments in 4 KB.
        guard launchArguments.utf8.count < 4096 else { throw LibraryError.message("The complete launch command is too long.") }
        guard !quoted, tokens <= 64 else { throw LibraryError.message("Use balanced double quotes and at most 64 launch arguments in total.") }
    }

    /// Runs on the launch worker, before the JIT pool is taken.
    func applyEnvironment() {
        configureLaunch()
        // Unset unless chosen: FEX's own default then applies, as for any other launch.
        if reducedX87 { setenv("FEX_X87REDUCEDPRECISION", "1", 1) } else { unsetenv("FEX_X87REDUCEDPRECISION") }
        madeira_set_vsync_locked(effectiveFPSMode)
        fputs("[frontend] launch profile applied\n", stderr)
        LogStore.shared.log("[display-shape] resolution=\(resolution) mode=\(displayMode.rawValue)")
    }

    /// What the bridge starts. Set on the main thread before the session begins.
    func configureLaunch() {
        setenv("MADEIRA_EXE", desktop == true ? "explorer.exe" : windowsPath, 1)
        setenv("MADEIRA_ARGS", launchArguments, 1)
        if desktop == true { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
        // Every session's virtual monitor takes this entry's Resolution
        // (MADEIRA_SCREEN_W/H, source "knob"); for the Desktop entry it is the
        // same size as its /desktop= argument.
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
    }
}

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var drive: URL { documents.appendingPathComponent("wine/drive_c", isDirectory: true).resolvingSymlinksInPath() }
    @Published var enabled = false
    @Published var entries: [LibraryEntry] = []
    @Published var current: UUID?
    @Published var activeEntry: LibraryEntry?
    @Published var menu = false
    @Published var performance = false
    @Published var liveLogs = false
    @Published var fpsMode = 1
    /// The session's touch-control opacity (the entry's Control opacity).
    @Published var opacity = 0.7
    /// The session's Aspect & scaling; MetalBackedView lays the game out with it.
    @Published var displayMode = DisplayMode.fit {
        didSet { if displayMode != oldValue { MetalBackedView.refreshDisplayMode(reason: "mode-toggle") } }
    }
    @Published var error: String?
    @Published var sessionMessage = ""
    @Published var launching = false
    @Published var overlayFields = ["FPS", "Frame time", "RAM", "Battery"]
    private var launchPresent: UInt64 = 0
    private var launchSurface: UInt64 = 0
    private var launchStarted = Date()
    /// Read by the starting screen for its elapsed-time line.
    var launchStartedAt: Date { launchStarted }
    @Published var launchSlow = false
    @Published var launchLogs = false
    private var launchDismissLogged = false
    var menuButtonRect = CGRect.zero
    var performanceRect = CGRect.zero
    /// The in-game menu and the starting screen take every touch.
    var blocksGameplayTouch: Bool { current != nil && (menu || launching) }
    private var timer: Timer?
    private var sawProcess = false
    // Why a session ended by itself (not Quit): the program the app launched
    // exited with a Windows error (wine_crash_exit_status, WineProcessBridge.m).
    // MADEIRA_EXIT_REPORT=0 returns to the library without a message.
    private var quitRequested = false
    private func exitReport() -> String? {
        guard !quitRequested, MadeiraConfig.flag("MADEIRA_EXIT_REPORT") else { return nil }
        var status: UInt32 = 0
        guard wine_crash_exit_status(&status) != 0 else { return nil }
        LogStore.shared.log("[exit-report] status=0x\(String(status, radix: 16))")
        let kind = status == 0xC0000005 ? " (memory access violation)" : status == 0xC0000017 ? " (out of memory)" : ""
        return "The game stopped with Windows error 0x\(String(status, radix: 16, uppercase: true))\(kind). Export the diagnostic log to report it."
    }
    private var readOnly = false
    private var metadataInFlight = Set<UUID>()
    private var savedControls: [TouchControl] = []
    private var savedLayout: String?
    private var savedVisible = true
    private var savedSize = 1.0
    /// The session's first frame makes the drawable's shape known (Aspect).
    private var laidOutAfterFirstPresent = false
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
        // Fixed for the whole run (FrontendChoice); a change applies at the next start.
        let allowed = FrontendChoice.startup.useNew
        if enabled != allowed { fputs("[frontend] library enabled=\(allowed ? 1 : 0)\n", stderr) }
        enabled = allowed
        LibraryController.shared.configure(enabled: allowed, ownsInput: allowed)
    }

    func save(_ entry: LibraryEntry) {
        guard !readOnly else { error = "The library file could not be read. Preserve or repair it before making changes."; return }
        var next = entries
        var entry = entry
        if let i = next.firstIndex(where: { $0.id == entry.id }) {
            // A details sheet may predate an asynchronous metadata refresh.
            if (next[i].metadataChecked ?? .distantPast) > (entry.metadataChecked ?? .distantPast) {
                entry.folderBytes = next[i].folderBytes; entry.graphicsAPI = next[i].graphicsAPI
                entry.metadataChecked = next[i].metadataChecked
                entry.metadataRevision = next[i].metadataRevision
            }
            next[i] = entry
        } else { next.append(entry) }
        persist(next)
    }
    func remove(_ id: UUID) {
        persist(entries.filter { $0.id != id })
    }
    private func persist(_ next: [LibraryEntry]) {
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(version: 1, entries: next)).write(to: file, options: .atomic)
            entries = next
        } catch { self.error = "Could not save the library: " + error.localizedDescription }
    }

    /// Install size and graphics API, at most once a day per entry.
    @MainActor
    func refreshMetadata(_ id: UUID) async {
        let revision = 12
        guard !metadataInFlight.contains(id), let entry = entries.first(where: { $0.id == id }), entry.desktop != true,
              entry.metadataRevision != revision || Date().timeIntervalSince(entry.metadataChecked ?? .distantPast) > 86400,
              let url = try? Self.executable(entry.relativePath) else { return }
        metadataInFlight.insert(id)
        defer { metadataInFlight.remove(id) }
        let result = await LibraryMetadataScanner.shared.scan(url, drive: Self.drive)
        guard !Task.isCancelled, var updated = entries.first(where: { $0.id == id }) else { return }
        updated.folderBytes = result.bytes
        if let api = result.api { updated.graphicsAPI = api }
        updated.metadataChecked = Date(); updated.metadataRevision = revision; save(updated)
        fputs("[library-metadata] install scan api=\(updated.graphicsAPI ?? "unknown") bytes=\(result.bytes ?? -1)\n", stderr)
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
    static func apiNames(_ imports: [String]) -> Set<String> {
        var levels = Set<String>()
        for name in imports {
            switch name {
            case "ddraw.dll": levels.insert("DirectDraw")
            case "d3d8.dll": levels.insert("D3D8")
            case "d3d9.dll": levels.insert("D3D9")
            case "d3d10.dll", "d3d10_1.dll": levels.insert("D3D10")
            case "d3d11.dll": levels.insert("D3D11")
            case "d3d12.dll": levels.insert("D3D12")
            case "opengl32.dll": levels.insert("OpenGL")
            case "vulkan-1.dll": levels.insert("Vulkan")
            default: break
            }
        }
        return levels
    }
    static func graphicsImports(_ url: URL) -> String? {
        let levels = apiNames(importNames(url))
        return levels.isEmpty ? nil : levels.sorted().joined(separator: " / ")
    }
    static func importNames(_ url: URL) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64); guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return [] }
        let base = UInt64(u32(dos, 60)); guard base < 16 * 1024 * 1024 else { return [] }
        let header = read(base, 264); guard header.count == 264, u32(header, 0) == 0x4550 else { return [] }
        let sections = Int(header[6]) | Int(header[7]) << 8
        let optSize = Int(header[20]) | Int(header[21]) << 8
        guard sections <= 96, optSize >= 120 else { return [] }
        let pe64 = header[24] == 0x0b && header[25] == 2
        guard header[24] == 0x0b, header[25] == 1 || pe64 else { return [] }
        let imports = u32(header, pe64 ? 144 : 128)
        let delayed = optSize >= (pe64 ? 224 : 208) ? u32(header, pe64 ? 240 : 224) : 0
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            guard table.count == sections * 40 else { return nil }
            for index in 0..<sections {
                let i = index * 40, va = u32(table, index * 40 + 12), size = u32(table, index * 40 + 16)
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        var names: [String] = []
        for (rva, stride, nameField) in [(imports, 20, 12), (delayed, 32, 4)] {
            guard rva != 0, let start = fileOffset(rva) else { continue }
            for i in 0..<256 {
                let descriptor = read(start + UInt64(i * stride), stride)
                guard descriptor.count == stride else { break }
                var nameRVA = u32(descriptor, nameField); if nameRVA == 0 { break }
                if stride == 32 && u32(descriptor, 0) & 1 == 0 {
                    let imageBase = u32(header, 52)
                    guard !pe64, nameRVA >= imageBase else { continue }
                    nameRVA -= imageBase
                }
                guard let offset = fileOffset(nameRVA) else { continue }
                let data = read(offset, 128)
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                names.append(name)
            }
        }
        return names
    }

    // MARK: session

    /// Wine sessions started in this app run. A second one cannot start in the
    /// same process: the wineserver's permanent objects from the first session
    /// are still there and init_registry aborts on "\Registry". Madeira asks for
    /// a restart instead. MADEIRA_ONE_SESSION_PER_RUN=0 lets the launch go ahead.
    static var sessionsThisRun = 0
    static let restartMessage = "Restart Madeira to start another game: swipe Madeira away in the app switcher, then open it again."
    @Published var restartNotice: String?

    /// `remember: false` runs a session that is not a library entry (a Madeira
    /// Dock start): it is neither added to the library nor stamped as played.
    func begin(_ entry: LibraryEntry, remember: Bool = true) {
        wine_exit_status_reset()
        quitRequested = false
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        Self.sessionsThisRun += 1
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false; launchLogs = entry.liveLogs
        launchSurface = winios_surface_present_count()
        MetalBackedView.presentCountAtLaunch = launchPresent; laidOutAfterFirstPresent = false
        launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        displayMode = entry.displayMode
        activeEntry = entry; current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
        LogStore.shared.setDisplayActive(entry.liveLogs)
        fpsMode = entry.fpsMode; sessionMessage = "Starting…"
        opacity = min(max(entry.controlOpacity ?? 0.7, 0.15), 1)
        let controls = TouchControlsModel.shared
        savedControls = controls.controls; savedVisible = controls.visible; savedSize = controls.sizeScale
        savedLayout = controls.layoutID
        if let profile = entry.controls {
            controls.controls = profile
            // The game's controls come with the layout they were loaded from (if that
            // layout still exists), so a later edit is not written to another game's.
            if ControlPresetsModel.enabled {
                controls.layoutID = ControlPresetsModel.shared.store.resolvedID(entry.controlLayout)
            }
        }
        controls.visible = entry.touchControls
        controls.sizeScale = min(max(entry.controlSize ?? 1, 0.5), 2)
        MetalHostView.shared.isHidden = false
        ProMotionIntent.apply(mode: entry.effectiveFPSMode)
        if remember { var played = entry; played.lastPlayed = Date(); save(played) }
        launchDismissLogged = false
        sawProcess = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        if launching {
            if madeira_get_present_count() >= launchPresent + 3 {
                showGameView(reason: "present")
            } else if winios_surface_present_count() > launchSurface {
                showGameView(reason: "surface")
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
        if wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if sawProcess && wineserver_is_running() == 0 { finish() }
        // The first frame gives Aspect and Fill height the drawable's shape.
        if current != nil, !laidOutAfterFirstPresent, madeira_get_present_count() != MetalBackedView.presentCountAtLaunch {
            laidOutAfterFirstPresent = true
            MetalBackedView.refreshDisplayMode(reason: "first-present")
        }
    }
    func launchFailed() { if current != nil && !sawProcess { finish(); error = "The session could not start. Check the diagnostic log and JIT status." } }
    /// Both flags change in one transaction without animation: the animated
    /// removal of a scrolling view with live content could leave the starting
    /// screen up (and unresponsive) while the game was already presenting.
    func showGameView(reason: String = "button") {
        if launching && !launchDismissLogged {
            launchDismissLogged = true
            fputs("[launch-view] dismissed reason=\(reason) logs=\(launchLogs ? 1 : 0)\n", stderr)
        }
        LogStore.shared.setDisplayActive(liveLogs)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { launchLogs = false; launching = false }
    }
    func toggleLaunchLogs() {
        launchLogs.toggle()
        LogStore.shared.setDisplayActive(launching ? launchLogs : liveLogs)
        fputs("[startup-log] visible=\(launchLogs ? 1 : 0)\n", stderr)
    }

    func setFPS(_ mode: Int) {
        fpsMode = mode
        let applied: Int32 = mode == 3 && !ProMotionIntent.has30Cap ? 1 : Int32(mode)
        madeira_set_vsync_locked(applied)
        ProMotionIntent.apply(mode: applied)
        saveCurrentProfile()
    }
    func showMenu() {
        LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: true)
        menu = true
    }
    func requestQuit() {
        LibraryKeyboard.hide()
        quitRequested = true
        // Ask the application to close (Alt+F4) through the normal input queue,
        // so it can save; the surface stays up until the native session ends.
        winios_post_key(0x12, 1); winios_post_key(0x73, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            winios_post_key(0x73, 0); winios_post_key(0x12, 0)
        }
        sessionMessage = "Close requested. Confirm any in-game exit dialog."
        menu = false
        fputs("[frontend] graceful close requested\n", stderr)
    }
    func saveCurrentProfile() {
        let controls = TouchControlsModel.shared
        if let id = current, var entry = entries.first(where: { $0.id == id }) {
            entry.controls = controls.controls
            if ControlPresetsModel.enabled { entry.controlLayout = controls.layoutID }
            entry.touchControls = controls.visible
            entry.fpsMode = fpsMode; entry.performance = performance
            entry.overlayFields = overlayFields
            entry.controlOpacity = opacity; entry.controlSize = controls.sizeScale
            // The in-game Aspect & scaling choice sticks to the game. MADEIRA_SESSION_TOOLS=0
            // hides that picker and leaves the stored choice alone.
            if MadeiraConfig.flag("MADEIRA_SESSION_TOOLS") { entry.display = displayMode.rawValue }
            save(entry)
        }
    }
    private func finish() {
        if sawProcess, let report = exitReport() { error = report }
        timer?.invalidate(); timer = nil
        saveCurrentProfile()
        let controls = TouchControlsModel.shared
        controls.editing = false; controls.selected = nil
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        if ControlPresetsModel.enabled { controls.layoutID = savedLayout }
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        displayMode = .fit
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
        MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        fputs("[frontend] returned to library\n", stderr)
    }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

// Serialized off the main actor. Cancellation follows the card's SwiftUI task,
// so entering a session stops directory work instead of competing with it.
private actor LibraryMetadataScanner {
    static let shared = LibraryMetadataScanner()
    // Dynamic imports do not appear in the PE import table. Look only for
    // terminated DLL names in bounded reads; these indicate supported APIs,
    // not which backend an application selects at runtime.
    private func dynamicAPIs(_ file: URL, budget: inout Int) -> Set<String> {
        guard budget > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let signature = try? handle.read(upToCount: 2), signature == Data([0x4d, 0x5a]) else { return [] }
        let length = (try? handle.seekToEnd()) ?? 0
        let window = min(budget, 4 * 1024 * 1024)
        var result = Set<String>()
        let names = ["ddraw.dll", "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "opengl32.dll", "vulkan-1.dll"]
        for offset in [UInt64(0), length > UInt64(window) ? length - UInt64(window) : 0] {
            guard budget > 0, !Task.isCancelled else { break }
            try? handle.seek(toOffset: offset)
            guard let bytes = try? handle.read(upToCount: min(window, budget)) else { break }
            budget -= bytes.count
            let folded = Data(bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
            for name in names {
                let ascii = Data((name + "\0").utf8)
                let wide = Data((name + "\0").utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
                if folded.range(of: ascii) != nil || folded.range(of: wide) != nil {
                    result.formUnion(LibraryModel.apiNames([name]))
                }
            }
            if length <= UInt64(window) { break }
        }
        return result
    }
    func scan(_ executable: URL, drive: URL) -> (bytes: Int64?, api: String?) {
        let folder = executable.deletingLastPathComponent()
        guard folder.path.hasPrefix(drive.path + "/"), !Task.isCancelled else { return (nil, nil) }
        let manager = FileManager.default
        // Executables commonly live below the installation root. Only ascend
        // conventional binary directories, never an arbitrary library parent.
        var installation = folder
        let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "release"]
        for _ in 0..<4 {
            guard binaryFolders.contains(installation.lastPathComponent.lowercased()) else { break }
            let parent = installation.deletingLastPathComponent()
            guard parent.path.hasPrefix(drive.path + "/"),
                  !["program files", "program files (x86)", "games", "common", "steamapps"].contains(parent.lastPathComponent.lowercased()) else { break }
            installation = parent
        }
        var complete = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let walker = manager.enumerator(at: installation, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in complete = false; return true })
        var bytes: Int64 = 0
        var files = 0
        while let file = walker?.nextObject() as? URL {
            if Task.isCancelled { return (nil, nil) }
            files += 1
            if files > 200_000 { complete = false; break }
            guard let values = try? file.resourceValues(forKeys: keys) else { complete = false; continue }
            if values.isSymbolicLink == true { walker?.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        // Engines often import graphics through a local DLL. Follow only their
        // actual import graph, case-insensitively, never every DLL in drive_c.
        let siblings = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var local: [String: URL] = [:]
        for file in siblings where file.pathExtension.lowercased() == "dll" {
            if file.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/") { local[file.lastPathComponent.lowercased()] = file }
        }
        var budget = 32 * 1024 * 1024
        var pending = [executable], visited = Set<String>(), apis = Set<String>()
        // A launcher may start a sibling executable rather than import its engine.
        // Restrict fallback to the same installation directory and a small count.
        if LibraryModel.graphicsImports(executable) == nil {
            pending.insert(contentsOf: siblings.filter {
                $0.pathExtension.lowercased() == "exe" && $0 != executable &&
                $0.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/")
            }.sorted { $0.path < $1.path }.prefix(8), at: 0)
        }
        while let file = pending.popLast(), visited.count < 64, !Task.isCancelled {
            if !visited.insert(file.path).inserted { continue }
            let imports = LibraryModel.importNames(file)
            apis.formUnion(LibraryModel.apiNames(imports))
            apis.formUnion(dynamicAPIs(file, budget: &budget))
            for name in imports { if let dependency = local[name], !visited.contains(dependency.path) { pending.append(dependency) } }
        }
        return (complete && walker != nil ? bytes : nil, apis.isEmpty ? nil : apis.sorted().joined(separator: "/"))
    }
}

enum LibraryRendererBadge {
    static let apis = ["D3D12", "D3D11", "D3D10", "D3D9", "D3D8", "Vulkan", "OpenGL", "DirectDraw"]

    /// The badge names an API only when the game's files name exactly one. The
    /// scan finds every renderer a game ships, not the one it runs: an engine
    /// with D3D9 and D3D10 renderers would otherwise be labelled D3D10.
    static func compact(_ detected: String?) -> String? {
        guard let detected else { return nil }
        // "D3D10/D3D9" from the metadata scan, "D3D10 / D3D9" from inspect.
        let values = Set(detected.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        let known = apis.filter(values.contains)
        if known.count == 1 { return known[0] }
        return known.isEmpty && !detected.contains("/") ? detected : nil   // e.g. "Wine desktop"
    }
}

// UIKit owns the entire hit region and tracking sequence. No SwiftUI button
// gaps: hold and slide across the native segments to change tabs.
private struct LibraryTabControl: UIViewRepresentable {
    @Binding var selection: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: [UIImage(systemName: "square.grid.2x2.fill")!, UIImage(systemName: "gearshape.fill")!])
        control.accessibilityLabel = "Library and Settings"
        control.setWidth(80, forSegmentAt: 0); control.setWidth(80, forSegmentAt: 1)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        // The surrounding glass capsule supplies the only background, including
        // during a held selection. A full-height transparent canvas keeps the
        // symbol from being clipped (the image height takes part in layout).
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 52)).image { _ in }
        for state: UIControl.State in [.normal, .selected, .highlighted, [.selected, .highlighted]] {
            control.setBackgroundImage(clear, for: state, barMetrics: .default)
        }
        control.setDividerImage(clear, forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        control.backgroundColor = .clear
        control.selectedSegmentTintColor = .clear
        control.selectedSegmentIndex = selection
        return control
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegmentIndex = selection
        control.accessibilityValue = selection == 0 ? "Library" : "Settings"
        for (index, symbol) in ["square.grid.2x2.fill", "gearshape.fill"].enumerated() {
            control.setImage(UIImage(systemName: symbol)?.withTintColor(index == selection ? .systemBlue : .secondaryLabel, renderingMode: .alwaysOriginal), forSegmentAt: index)
        }
    }
    final class Coordinator: NSObject {
        var parent: LibraryTabControl
        init(_ parent: LibraryTabControl) { self.parent = parent }
        @objc func changed(_ control: UISegmentedControl) { parent.selection = control.selectedSegmentIndex }
    }
}

struct LibraryArtwork: View {
    let entry: LibraryEntry
    var backdrop = false
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            Color(uiColor: .secondarySystemFill)
            Image(systemName: entry.desktop == true ? "desktopcomputer" : "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary)
            if let name = entry.coverFile,
               let image = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { format; size }
            VStack(alignment: .leading, spacing: 4) { format; size }
        }
    }
    private var format: some View {
        HStack(spacing: 4) {
            if entry.bits == 32 || entry.bits == 64 { badge("\(entry.bits)-bit") }
            if let api = LibraryRendererBadge.compact(entry.graphicsAPI) { badge(api) }
        }
    }
    @ViewBuilder private var size: some View {
        if let bytes = entry.folderBytes { badge(String(format: bytes < 1_000_000_000 ? "%.2f GB" : "%.1f GB", Double(bytes) / 1_000_000_000)) }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct LibraryStatus: View {
    @State private var jit = false
    @State private var memory = false
    let ticks = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 14) {
            status("JIT", jit); status("Memory+", memory)
            if BuildStamp.visible {
                Text(BuildStamp.text).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(.systemGray2)).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel("Build \(BuildStamp.text)")
            }
        }
            .onAppear { update() }.onReceive(ticks) { _ in update() }
    }
    private func status(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 5) { Circle().fill(enabled ? Color.green : Color.orange).frame(width: 6, height: 6); Text(label).font(.caption2) }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label): \(enabled ? "enabled" : "unavailable")")
    }
    private func update() { jit = jit_check_debugged(); memory = EntitlementStatus.check().increasedMemory }
}

/// A section title with a count; with `collapsed` set, tapping the title
/// collapses or expands the section (the state is the caller's, persisted).
struct LibrarySectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        if let collapsed {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.title2.bold())
                        if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                    }.contentShape(Rectangle()).frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(collapsed.wrappedValue ? "Collapsed" : "Expanded")
                Spacer()
                trailing
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                if let count, count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                trailing
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        }
    }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    /// Madeira Dock's start, for Settings › Steam (Onboarding.swift).
    var startDock: (DockGame, Bool) -> Void = { _, _ in }
    /// First-run setup (Onboarding.swift).
    @ObservedObject private var onboarding = OnboardingModel.shared
    @State private var browser = false
    @State private var selected: LibraryEntry?
    @State private var search = ""
    @State private var focused: UUID?
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0
    // The interface the next start uses (FrontendChoice).
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false
    @State private var settingsSheet: SettingsSheet?
    @State private var settingsRefresh = 0
    @AppStorage("madeiraLibraryLayout") private var layout = "cards"
    @AppStorage("madeiraLibrarySort") private var sort = "played"
    // Collapsed state of the games section.
    @AppStorage("madeiraLibraryHideOthers") private var hideGames = false
    private var entries: [LibraryEntry] {
        let visible = model.entries.filter { $0.desktop != true && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        if sort == "added" { return visible.reversed() }
        return visible.sorted {
            if sort == "played", $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            if sort == "size", $0.folderBytes != $1.folderBytes { return ($0.folderBytes ?? -1) > ($1.folderBytes ?? -1) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    var body: some View {
        Group {
            if tab == 0 { library } else { settings }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryTabControl(selection: $tab).frame(width: 160, height: 52)
                .modifier(LibraryPillGlass())
                .padding(.bottom, 5).padding(.top, 8)
        }
        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }
        .onAppear {
            // An ended desktop session's surface never stays over the library.
            EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
            // First-run setup opens once on a new install.
            onboarding.presentIfNeeded()
        }
        .onReceive(controller.commands) { command in
            if selected == nil, !browser, !onboarding.presented, command == "tab" { tab = 1 - tab }
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
            } header: { Text("Diagnostics") }
            Section("Pointer") { LibraryPointerSettings() }
            if MadeiraConfig.flag("MADEIRA_RUNTIME_SETTINGS") {
                DisplayRateSettings()
                RuntimeMemorySyncSettings(open: { settingsSheet = $0 }, refresh: settingsRefresh)
            }
            if SteamSettingsSection.shown { SteamSettingsSection(open: { settingsSheet = $0 }) }
            Section {
                Toggle("Use developer interface", isOn: Binding(get: { developerUI }, set: { on in
                    developerUI = on; FrontendChoice.choose(new: !on); restartNotice = true
                }))
            } header: { Text("Interface") } footer: {
                Text("The developer interface is Madeira's original diagnostic screen. The change applies after Madeira restarts.")
            }
            // Credits, last on the Settings page.
            Section {
                MadeiraCredit(name: "Will Faust", handle: "willfaust", role: "Created Madeira")
                MadeiraCredit(name: "Nick", handle: "125hz", role: "32-bit game support, the game library and Madeira Dock")
                MadeiraCredit(name: "Jfishin", handle: "Jfishin", role: "The original native Steam sign-in, library and downloads")
            } header: { Text("Credits") } footer: {
                Text("Madeira is built on Wine, FEX-Emu, DXMT by Feifan He (3Shain) with the Direct3D 9 frontend by David Acevedo (dacevedo12), rpmalloc by Mattias Jansson, and StikDebug for enabling JIT. Thank you to everyone who contributes to these projects.")
            }
        }
        .alert("Restart Madeira", isPresented: $restartNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close Madeira from the app switcher and open it again to switch interfaces.")
        }
        // The Settings sheets hang off the Form, never off one of its rows: a Form
        // may rebuild its rows while a sheet slides up over it, and a sheet whose
        // owning row is rebuilt closes again at once.
        .sheet(item: $settingsSheet, onDismiss: { settingsRefresh += 1 }) { sheet in
            switch sheet {
            case .allSettings: AllSettingsView()
            case .steamSignIn: SteamSignInView()
            case .dock: MadeiraDockView(start: startDock)
            }
        }
    }
    private var library: some View {
        GeometryReader { viewport in
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
                HStack {
                    Button { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry } label: {
                        Label("Desktop", systemImage: "desktopcomputer")
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }.buttonStyle(.plain)
                        .id(LibraryEntry.desktopID)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(focused == LibraryEntry.desktopID && controller.connected ? Color.cyan : .clear, lineWidth: 3))
                }
                // Installed Steam games, started through Madeira Dock (SteamGames.swift).
                SteamGamesSection(search: search, startDock: startDock)
                if model.entries.filter({ $0.desktop != true }).isEmpty {
                    ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."))
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        LibrarySectionHeader(title: "Games", count: entries.count, collapsed: $hideGames) {
                            Button { browser = true } label: { Label("Add a game", systemImage: "plus.circle") }.font(.subheadline)
                        }
                        if hideGames {
                            EmptyView()
                        } else if entries.isEmpty {
                            Text("No games match your search.").foregroundStyle(.secondary)
                        } else {
                            cells(entries, width: viewport.size.width)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .onReceive(controller.commands) { command in
            guard tab == 0, selected == nil, !browser, !onboarding.presented else { return }
            let items = entries
            let ids = [LibraryEntry.desktopID] + items.map(\.id)
            let index = ids.firstIndex(where: { $0 == focused }) ?? 0
            if command == "add" { browser = true }
            else if command == "accept" {
                if index == 0 { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry }
                else { selected = items[index - 1] }
            }
            else if ["left", "right", "up", "down"].contains(command) {
                let delta = command == "left" || command == "up" ? -1 : 1
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18)) { focused = ids[(index + delta + ids.count) % ids.count] }
            }
        }
        .searchable(text: $search, prompt: "Search your library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Library layout", selection: $layout) {
                        Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                        Label("Compact cards", systemImage: "square.grid.3x3").tag("compact")
                        Label("List", systemImage: "list.bullet").tag("list")
                        Label("Compact list", systemImage: "list.dash").tag("compactList")
                    }
                    Picker("Sort by", selection: $sort) {
                        Label("Last played", systemImage: "clock").tag("played")
                        Label("Name", systemImage: "textformat.abc").tag("name")
                        Label("Recently added", systemImage: "plus").tag("added")
                        Label("Folder size", systemImage: "internaldrive").tag("size")
                    }
                } label: { Label("Library options", systemImage: "line.3.horizontal.decrease") }
            }
            ToolbarItem(placement: .topBarTrailing) { Button { browser = true } label: { Label("Add executable", systemImage: "plus") } }
        }
        .sheet(isPresented: $browser) {
            NavigationStack { ExecutableBrowser(folder: LibraryModel.drive) { entry in
                model.save(entry); browser = false; selected = entry
            } }
        }
        .sheet(item: $selected) { entry in
            // The details page stays up until the session's starting screen takes
            // over (or an error needs the library's alert), instead of showing the
            // library for the moment a start spends preparing.
            LibraryDetail(entry: entry, play: { profile in
                play(profile)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if selected?.id == entry.id { selected = nil } }
            })
        }
        .onChange(of: model.current) { _, current in if current != nil { selected = nil } }
        .onChange(of: model.error) { _, error in if error != nil { selected = nil } }
        .onChange(of: model.restartNotice) { _, notice in if notice != nil { selected = nil } }
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
    @ViewBuilder private func cells(_ items: [LibraryEntry], width viewportWidth: CGFloat) -> some View {
        if layout == "list" || layout == "compactList" {
            let dense = layout == "compactList"
            LazyVStack(spacing: dense ? 4 : 8) { ForEach(items) { entry in libraryItem(entry, list: true, dense: dense) } }
        } else {
            let compact = layout == "compact"
            let width = max(1, min(viewportWidth, 1100) - 32)
            let count = max(1, Int((width + 12) / (compact ? 110 : 154)))
            let cardWidth = min(compact ? 115.0 : 164.0, (width - CGFloat(count - 1) * 12) / CGFloat(count))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: 12, alignment: .top), count: count), alignment: .center, spacing: 18) {
                ForEach(items) { entry in libraryItem(entry, list: false) }
            }.frame(maxWidth: .infinity, alignment: .center)
        }
    }
    private func libraryItem(_ entry: LibraryEntry, list: Bool, dense: Bool = false) -> some View {
        Button { selected = entry } label: {
            Group {
                if list && dense {
                    // One short row per game.
                    HStack(spacing: 10) {
                        LibraryArtwork(entry: entry).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary).fixedSize()
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                } else if list {
                    HStack(spacing: 14) {
                        LibraryArtwork(entry: entry).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.headline).lineLimit(2); LibraryBadges(entry: entry).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryArtwork(entry: entry).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.foregroundStyle(.primary)
        }.buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused == entry.id && controller.connected ? Color.accentColor : .clear, lineWidth: 2))
            .id(entry.id)
            .task(id: entry.id, priority: .utility) { await model.refreshMetadata(entry.id) }
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

private struct LibraryPlayStyle: ButtonStyle {
    var pending: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(pending || configuration.isPressed ? Color(uiColor: .darkGray) : .accentColor,
                        in: RoundedRectangle(cornerRadius: 14))
    }
}

struct LibraryDetail: View {
    @State var entry: LibraryEntry
    var play: (LibraryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = LibraryModel.shared
    @State private var importCover = false
    @State private var remove = false
    @State private var leaving = false
    @State private var error: String?
    static let presetResolutions = ["640x480", "800x600", "960x540", "1024x768", "1280x720", "1280x960", "1408x648", "1920x1080", "2560x1440"]
    /// The presets, plus a stored size that is none of them (a screen shape
    /// chosen on another device), so the picker never shows a blank choice.
    static func resolutions(keeping current: String) -> [String] {
        presetResolutions.contains(current) || current == screenShapeResolution ? presetResolutions : presetResolutions + [current]
    }
    /// "WxH" matching this screen's landscape aspect at 720 lines (width
    /// rounded to a multiple of 8), or nil when it equals a preset or
    /// MADEIRA_SCREEN_SHAPE_RESOLUTION=0.
    static var screenShapeResolution: String? {
        guard MadeiraConfig.flag("MADEIRA_SCREEN_SHAPE_RESOLUTION") else { return nil }
        let bounds = UIScreen.main.bounds
        let long = max(bounds.width, bounds.height), short = min(bounds.width, bounds.height)
        guard short > 0 else { return nil }
        let width = Int((720 * long / short / 8).rounded()) * 8
        guard (640...4096).contains(width), width != 1280, width != 960 else { return nil }
        return "\(width)x720"
    }
    private func start() {
        guard !leaving else { return }
        leaving = true
        let profile = entry
        // Give the pressed state a display turn before saving and handing off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            model.save(profile); play(profile)
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 20) {
                        LibraryArtwork(entry: entry).frame(width: 120, height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.title).font(.title2.bold())
                            LibraryBadges(entry: entry)
                            if let played = entry.lastPlayed {
                                Text("Last played \(played.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Button(action: start) { HStack(spacing: 10) { Image(systemName: "play.fill"); Text("Play").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30) }
                                .buttonStyle(LibraryPlayStyle(pending: leaving)).disabled(leaving)
                        }
                    }.padding(.vertical, 24)
                        .listRowBackground(
                            LibraryArtwork(entry: entry, backdrop: true).blur(radius: 4)
                                .overlay(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.48))
                                .overlay(alignment: .bottom) {
                                    LinearGradient(colors: [.clear, Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                                }.clipped()
                        )
                }
                if entry.desktop != true { Section("Library details") {
                    TextField("Title", text: $entry.title)
                    Button("Choose cover image", systemImage: "photo") { importCover = true }
                    if entry.coverFile != nil { Button("Remove cover image") { entry.coverFile = nil } }
                } }
                Section("Display") {
                    // The Windows screen the game renders for (and the Desktop's size).
                    Picker("Resolution", selection: $entry.resolution) {
                        ForEach(Self.resolutions(keeping: entry.resolution), id: \.self) { Text($0.replacingOccurrences(of: "x", with: "×")).tag($0) }
                        // This device's own aspect ratio at 720 lines, so the game
                        // fills the screen without bars or stretching.
                        if let shape = Self.screenShapeResolution {
                            Text("Screen shape (\(shape.replacingOccurrences(of: "x", with: "×")))").tag(shape)
                        }
                    }
                    Picker("Aspect & scaling", selection: Binding(get: { entry.displayMode.rawValue }, set: { entry.display = $0 })) {
                        ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    FPSChoice(mode: $entry.fpsMode)
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    if entry.desktop != true {
                        TextField("Launch arguments", text: $entry.arguments, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                } header: { Text("Compatibility & performance") } footer: {
                    Text("Reduced-precision x87 can make older games faster at some cost in accuracy; it is off by default. Settings apply to the next launch; a precision change may still require restarting Madeira.")
                }
                Section("On screen") {
                    Toggle("Performance overlay", isOn: $entry.performance)
                    Toggle("Live logs", isOn: $entry.liveLogs)
                    Toggle("Touch controls", isOn: $entry.touchControls)
                    LabeledContent("Control opacity") {
                        Slider(value: Binding(get: { entry.controlOpacity ?? 0.7 }, set: { entry.controlOpacity = $0 }), in: 0.15...1)
                    }
                    LabeledContent("Control size") {
                        Slider(value: Binding(get: { entry.controlSize ?? 1 }, set: { entry.controlSize = $0 }), in: 0.5...2)
                    }
                    Text("Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.").font(.caption).foregroundStyle(.secondary)
                }
                if entry.desktop != true {
                    Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
                    Section { Button("Remove from library", role: .destructive) { remove = true } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.save(entry); dismiss() } } }
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
                if entry.graphicsAPI == nil, entry.desktop != true, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
            }
            .onDisappear { if !leaving { model.save(entry) } }
            .onReceive(LibraryController.shared.commands) { command in
                guard !leaving, !importCover, !remove else { return }
                if command == "back" { model.save(entry); dismiss() }
                if command == "accept" { start() }
            }
        }
    }
}

struct FPSChoice: View {
    @Binding var mode: Int
    var body: some View {
        HStack { Text("FPS limit"); Spacer(); Picker("FPS limit", selection: $mode) {
            // 30 needs DXMT's 30 FPS cap (ProMotionIntent.has30Cap); a saved 30 stays selectable.
            if ProMotionIntent.has30Cap || mode == 3 { Text("30 FPS").tag(3) }
            Text("60 FPS").tag(1); Text("Display maximum").tag(0); Text("Uncapped").tag(2)
        }.labelsHidden().pickerStyle(.menu) }
    }
}

/// Holding the display at its maximum refresh rate in the 60 FPS limit
/// (madeira.cfg env.MADEIRA_PROMOTE = 1, off by default; see ProMotionIntent).
/// Applies from the next session start or FPS limit change.
struct DisplayRateSettings: View {
    @State private var hold = ProMotionIntent.holdMaximum

    var body: some View {
        Section {
            Toggle("Hold the display at its maximum rate", isOn: Binding(get: { hold }, set: { on in
                hold = on
                MadeiraConfig.set("env.MADEIRA_PROMOTE", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] promote=\(on ? 1 : 0)")
            }))
        } header: { Text("Display") } footer: {
            Text("Off by default. On a 120 Hz display, keeps the panel at 120 Hz during a game's 60 FPS limit so a frame that misses one refresh waits 8 ms instead of 17 ms. Uses more power.")
        }
    }
}

/// One row of Settings › Credits: a person, their GitHub account and what they did.
struct MadeiraCredit: View {
    let name: String
    let handle: String
    let role: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(.body.weight(.semibold))
                if let url = URL(string: "https://github.com/\(handle)") {
                    Link("@\(handle)", destination: url).font(.subheadline)
                }
            }
            Text(role).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Memory & sync: the JIT pool (madeira.cfg pool), the video memory
/// budget (vram-mb), the file-backed swap tier (swap-mb, off by default, and
/// env.MADEIRA_SWAP_COVERAGE, which allocations it backs) and the in-process sync
/// engine madsync (inproc-sync, on by default). All are read when Madeira starts,
/// so changes apply after a restart. "All settings" opens every other option.
/// MADEIRA_RUNTIME_SETTINGS=0 hides this section.
/// A sheet opened from Settings; LibraryView presents it from the Form itself.
enum SettingsSheet: String, Identifiable {
    case allSettings, steamSignIn, dock
    var id: String { rawValue }
}

struct RuntimeMemorySyncSettings: View {
    /// Opens a Settings sheet (LibraryView owns the presentation).
    var open: (SettingsSheet) -> Void = { _ in }
    /// Bumped when a Settings sheet closes, so the rows re-read madeira.cfg.
    var refresh = 0
    /// The keys this section owns; All settings leaves them out.
    static let featuredKeys: Set<String> = ["pool", "vram-mb", "swap-mb", "env.MADEIRA_SWAP_COVERAGE", "inproc-sync", "eco"]
    static let poolChoices = [0, 512, 640, 768, 1024, 1152]          // 0 = the standard 896 MB
    static let vramChoices = [0, 1536, 2048, 3072, 4096, 4352, 4608, 5120, 6144]   // 0 = automatic
    static let swapChoices = [0, 1024, 2048, 3072, 4096]
    /// The stored value "" (no key) and "classic" are the same rules.
    static let coverageChoices: [(String, String)] = [
        ("", "Large allocations (8 MB+)"), ("blocks", "All allocations of 1 MB+"), ("wide", "1 MB+ and overflow"),
    ]
    @State private var poolMB = Self.intKey("pool")
    @State private var vramMB = Self.intKey("vram-mb")
    @State private var swapMB = Self.intKey("swap-mb")
    @State private var coverage = Self.currentCoverage()
    @State private var madsync = MadeiraConfig.bool("inproc-sync", default: true)
    @State private var eco = MadeiraConfig.bool("eco", default: false)
    @State private var changed = false

    /// The configured value in MB, shown as itself even when it is not one of the choices.
    static func intKey(_ key: String) -> Int { Int(MadeiraConfig.get(key) ?? "") ?? 0 }
    static func currentCoverage() -> String {
        let v = (MadeiraConfig.get("env.MADEIRA_SWAP_COVERAGE") ?? "").lowercased()
        return v == "classic" ? "" : v
    }
    static func gb(_ mb: Int) -> String {
        String(format: "%g GB", Double(mb) / 1024)   // 1.5, 4, 4.25 ...
    }

    private func mbPicker(_ title: String, key: String, value: Binding<Int>, choices: [Int],
                          zero: String, label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: Binding(get: { value.wrappedValue }, set: { mb in
            value.wrappedValue = mb; changed = true
            MadeiraConfig.set(key, mb > 0 ? String(mb) : nil)
            LogStore.shared.log("[runtime-settings] \(key)=\(mb)")
        })) {
            ForEach(choices, id: \.self) { mb in Text(mb == 0 ? zero : label(mb)).tag(mb) }
            if !choices.contains(value.wrappedValue) { Text("\(value.wrappedValue) MB").tag(value.wrappedValue) }
        }
    }

    var body: some View {
        Section {
            mbPicker("JIT pool", key: "pool", value: $poolMB, choices: Self.poolChoices,
                     zero: "Default (896 MB)", label: { "\($0) MB" })
            mbPicker("Video memory", key: "vram-mb", value: $vramMB, choices: Self.vramChoices,
                     zero: "Automatic", label: Self.gb)
            mbPicker("Swap tier", key: "swap-mb", value: $swapMB, choices: Self.swapChoices,
                     zero: "Off", label: Self.gb)
            Picker("Swap coverage", selection: Binding(get: { coverage }, set: { mode in
                coverage = mode; changed = true
                MadeiraConfig.set("env.MADEIRA_SWAP_COVERAGE", mode.isEmpty ? nil : mode)
                LogStore.shared.log("[runtime-settings] swap-coverage=\(mode.isEmpty ? "classic" : mode)")
            })) {
                ForEach(Self.coverageChoices, id: \.0) { Text($0.1).tag($0.0) }
                if !Self.coverageChoices.contains(where: { $0.0 == coverage }) { Text(coverage).tag(coverage) }
            }
            .disabled(swapMB == 0)
            Toggle("Madsync", isOn: Binding(get: { madsync }, set: { on in
                madsync = on; changed = true
                MadeiraConfig.set("inproc-sync", on ? nil : "0")
                LogStore.shared.log("[runtime-settings] inproc-sync=\(on ? 1 : 0)")
            }))
            Toggle("Eco mode", isOn: Binding(get: { eco }, set: { on in
                eco = on; changed = true
                MadeiraConfig.set("eco", on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] eco=\(on ? 1 : 0)")
            }))
            Button { open(.allSettings) } label: {
                Label("All settings (\(ConfigCatalog.generated.count - Self.featuredKeys.count) more)", systemImage: "slider.horizontal.3")
            }
        } header: { Text("Memory & sync") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("JIT pool is the memory reserved at launch for translated x86 code (256 to 1152 MB).")
                Text("Video memory is how much graphics memory games are told they have. Automatic sizes it from the memory free at launch. Too high can get Madeira closed for using too much memory; too low makes games keep reloading textures.")
                Text("Swap tier moves game data to a file on this device's storage when memory runs short, up to the chosen size, at some speed cost. Coverage decides which allocations it moves: large ones only (8 MB and up, the default), every allocation of 1 MB and up, or those plus allocations that overflow the game's address range. Wider coverage saves more memory but can slow a game down.")
                Text("Madsync is the in-process synchronisation engine (on by default).")
                Text("Eco mode starts every game with its threads at a low priority, which saves power but makes games run slower. Off by default. It is meant for loading screens: the ECO pill in the performance overlay turns it on and off while a game runs.")
                if changed { Text("Restart Madeira (close it from the app switcher) for these changes to apply.").foregroundStyle(.orange) }
            }
        }
        .onChange(of: refresh) { _, _ in
            poolMB = Self.intKey("pool"); vramMB = Self.intKey("vram-mb"); swapMB = Self.intKey("swap-mb")
            coverage = Self.currentCoverage(); madsync = MadeiraConfig.bool("inproc-sync", default: true)
            eco = MadeiraConfig.bool("eco", default: false)
        }
    }
}

struct LibraryPointerSettings: View {
    @ObservedObject private var input = InputSettings.shared
    /// Absolute, Relative or Touch; `touchMode` and `relative` stay mutually exclusive.
    private var mode: Binding<String> {
        Binding(get: { input.touchMode ? "touch" : (input.relative ? "relative" : "absolute") }, set: { value in
            input.touchMode = value == "touch"; input.relative = value == "relative"
            fputs("[frontend-pointer] mode=\(value)\n", stderr)
        })
    }
    var body: some View {
        Picker("Pointer mode", selection: mode) {
            Text("Absolute").tag("absolute"); Text("Relative").tag("relative"); Text("Touch").tag("touch")
        }.pickerStyle(.segmented)
        Text(input.touchMode ? "Tap the screen to position and click. Hold and move to drag. Two fingers: right click or scroll."
             : (input.relative ? "Drag to send relative mouse movement for mouse-look. Tap to click." : "Drag the pointer like a trackpad. Tap to click."))
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Touch sensitivity") {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.1...8)
        }
    }
}

struct LibraryPillGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color(uiColor: .secondarySystemBackground), in: Capsule()) }
        else if #available(iOS 26, *) { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

// Keep drag state in this small view. Global translation remains stable while
// the view moves; local coordinates feed its own movement back in.
struct LibraryFloatingItem: View {
    let isMenu: Bool
    let viewport: CGSize
    let insets: EdgeInsets
    @ObservedObject private var model = LibraryModel.shared
    @AppStorage private var nx: Double
    @AppStorage private var ny: Double
    @GestureState private var drag = CGSize.zero
    @State private var measured = CGSize(width: 48, height: 48)
    @State private var faded = false
    @State private var touched = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isMenu: Bool, viewport: CGSize, insets: EdgeInsets) {
        self.isMenu = isMenu; self.viewport = viewport; self.insets = insets
        _nx = AppStorage(wrappedValue: isMenu ? 0.92 : 0.25, isMenu ? "madeiraLibraryMenuX" : "madeiraLibraryMetricsX")
        _ny = AppStorage(wrappedValue: isMenu ? 0.12 : 0.08, isMenu ? "madeiraLibraryMenuY" : "madeiraLibraryMetricsY")
    }
    private func position(_ translation: CGSize) -> CGPoint {
        let left = insets.leading + measured.width / 2 + 8
        let top = insets.top + measured.height / 2 + 8
        return CGPoint(x: min(max(left, viewport.width * nx + translation.width), max(left, viewport.width - insets.trailing - measured.width / 2 - 8)),
                       y: min(max(top, viewport.height * ny + translation.height), max(top, viewport.height - insets.bottom - measured.height / 2 - 8)))
    }
    private func record(_ rect: CGRect) {
        if isMenu { model.menuButtonRect = rect } else { model.performanceRect = rect }
    }
    var body: some View {
        let center = position(drag)
        let rect = CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height)
        Group {
            if isMenu {
                Button { touched += 1; model.showMenu() } label: {
                    Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                }.buttonStyle(.plain).modifier(LibraryPillGlass())
                    .opacity(faded && drag == .zero && !model.menu ? 0.3 : 1)
                    .accessibilityLabel("Game menu").accessibilityHint("Drag to move")
            } else { LibraryMetrics().accessibilityHint("Drag to move") }
        }
        .frame(maxWidth: isMenu ? 48 : max(48, min(390, viewport.width - insets.leading - insets.trailing - 16)))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { measured = proxy.size }.onChange(of: proxy.size) { _, size in measured = size }
        })
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global).updating($drag) { value, state, transaction in
            transaction.animation = nil; state = value.translation
        }.onEnded { value in
            let end = position(value.translation)
            withTransaction(Transaction(animation: nil)) {
                nx = end.x / max(1, viewport.width); ny = end.y / max(1, viewport.height); touched += 1
            }
        })
        .position(center)
        .onAppear { record(rect) }.onChange(of: rect) { _, value in record(value) }
        .onDisappear { record(.zero) }
        .task(id: touched) {
            guard isMenu else { return }
            faded = false
            do { try await Task.sleep(for: .seconds(3)); withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { faded = true } } catch { }
        }
    }
}

/// Everything the library draws over a running session: the starting screen,
/// the menu button, the performance overlay, live logs and the in-game menu.
/// It lives in TouchControlsOverlay's window, which is above the game surface.
struct LibraryHUD: View {
    /// Top offset for the overlays pinned to the top edge. This HUD ignores the
    /// safe area, and with the game view in portrait its reported top inset can
    /// be zero while the status bar is showing; the larger of the reported inset
    /// and the visible status bar's height is used.
    static func topInset(_ geo: GeometryProxy) -> CGFloat {
        let bar = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.statusBarManager?.statusBarFrame.height ?? 0
        return max(geo.safeAreaInsets.top, bar)
    }
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    private let sessionTools = MadeiraConfig.flag("MADEIRA_SESSION_TOOLS")
    @State private var launchVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.launching, let entry = model.activeEntry {
                    LibraryArtwork(entry: entry, backdrop: true).overlay(.black.opacity(0.65)).ignoresSafeArea()
                        .opacity(launchVisible ? 1 : 0)
                    launchView(entry, geometry: geo)
                        .opacity(launchVisible ? 1 : 0)
                        .scaleEffect(launchVisible || reduceMotion ? 1 : 0.96)
                }
                if !model.launching && model.performance { LibraryFloatingItem(isMenu: false, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.liveLogs && !model.launching { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, Self.topInset(geo) + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, Self.topInset(geo) + 12).allowsHitTesting(false) }
                if !model.launching { LibraryFloatingItem(isMenu: true, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.menu {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.menu = false }.transition(.opacity)
                    menu.frame(width: min(460, geo.size.width - 32), height: min(650, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom - 24))
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.15)))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.menu)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.35)) { launchVisible = true }
            }
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
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
    private func launchView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let compact = geo.size.height < 500
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        // A landscape phone would have the live log below the fold; it goes
        // beside the status there instead.
        let showLogs = model.launchLogs
        let sideLogs = showLogs && compact && geo.size.width > geo.size.height
        return HStack(spacing: 12) {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: compact ? 10 : 18) {
                LibraryArtwork(entry: entry).frame(width: compact ? 90 : 120, height: compact ? 135 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        Text(model.launchSlow ? "Still starting…" : "Starting your game…").foregroundStyle(.white.opacity(0.7))
                        Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                }
                // The starting screen's controls are one row of glyph-only buttons, so a
                // short screen does not push them below the fold. The words stay as
                // VoiceOver labels.
                HStack(spacing: 14) {
                    launchGlyph(showLogs ? "Hide live log" : "Show live log", "text.alignleft", on: showLogs) {
                        model.toggleLaunchLogs()
                    }
                }
                if model.launchSlow {
                    Button("Show game view") { model.showGameView(reason: "button") }.frame(minHeight: 44)
                }
                if showLogs && !sideLogs {
                    LibraryLiveLogs().frame(maxWidth: 550).frame(height: compact ? 90 : 120).clipped()
                }
            }.padding(16).frame(maxWidth: .infinity).frame(minHeight: available)
        }
        }.frame(maxWidth: .infinity)
        if sideLogs {
            LibraryLiveLogs().frame(width: min(420, geo.size.width * 0.45)).frame(height: max(0, available - 32)).clipped()
                .padding(.trailing, 16 + geo.safeAreaInsets.trailing)
        }
        }
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top).foregroundStyle(.white).transition(.opacity)
    }
    /// A round glyph button for the starting screen's control row.
    private func launchGlyph(_ label: String, _ symbol: String, on: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(on ? 0.32 : 0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label("Session", systemImage: "gamecontroller.fill").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false }.buttonStyle(.bordered) }
                // The controls come first, the easiest to reach; the overlay settings last.
                Toggle("Touch controls", isOn: $controls.visible)
                // The named layouts (Xbox controller, custom ones) live here in a session: this
                // menu replaces the overlay's top bar, where the same menu sits outside the library.
                if controls.visible && ControlPresetsModel.enabled {
                    ControlLayoutMenu(style: .row) { openedEditor in
                        model.saveCurrentProfile()
                        if openedEditor { model.menu = false }
                    }
                }
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                LabeledContent("Size") { Slider(value: $controls.sizeScale, in: 0.5...2) }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }
                Divider()
                FPSChoice(mode: Binding(get: { model.fpsMode }, set: { model.setFPS($0) }))
                // Saved to the game with the rest of the session's profile.
                // MADEIRA_SESSION_TOOLS=0 hides it.
                if sessionTools {
                    LabeledContent("Aspect & scaling") {
                        Picker("Aspect & scaling", selection: $model.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in Label(mode.label, systemImage: mode.symbol).tag(mode) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }
                Divider()
                Text("Mouse & pointer").font(.headline)
                LibraryPointerSettings()
                Divider()
                Toggle("Performance overlay", isOn: $model.performance)
                if model.performance {
                    ForEach(["FPS", "Frame time", "RAM", "Battery"], id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
                }
                Divider()
                // Red label and symbol; the menu's .primary style would otherwise win.
                Button(role: .destructive) { model.requestQuit() } label: {
                    Label("Quit game", systemImage: "stop.circle").foregroundStyle(.red)
                }.tint(.red)
                Text("Closes the running session. Unsaved progress will be lost.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .foregroundStyle(.primary)
        }
        .scrollIndicators(.visible)
    }
}

struct LibraryLiveLogs: View {
    @ObservedObject private var logs = LogStore.shared
    var body: some View {
        // Rows are coalesced by signature; insertion order isn't recency.
        // Show the latest updates so a repeating wait still looks live.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.entries.sorted { $0.lastTimestamp < $1.lastTimestamp }.suffix(200))) {
                        Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 16), alignment: .topLeading)
            }.defaultScrollAnchor(.bottom).padding(8)
        }.background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            .accessibilityLabel("Live diagnostic log")
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
        // MADEIRA_FRONTEND_KEYBOARD=0: the game view's own keyboard instead.
        if !MadeiraConfig.flag("MADEIRA_FRONTEND_KEYBOARD") { MetalBackedView.toggleKeyboard(); return }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        previous = scene.windows.first(where: { $0.isKeyWindow })
        let w = LibraryKeyboardWindow(windowScene: scene)
        w.windowLevel = .normal + 102; w.backgroundColor = .clear
        let controller = UIViewController(); controller.view.backgroundColor = .clear
        w.rootViewController = controller
        let v = LibraryKeyInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(v); input = v; window = w
        w.makeKeyAndVisible(); v.becomeFirstResponder()
        fputs("[frontend-keyboard] key-window input activated\n", stderr)
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

/// A desktop session (the Desktop entry) draws through Winios's compositor view,
/// a plain UIView the native side adds straight onto the app window, above the
/// SwiftUI root view, and never hides. The game view (MetalHostView) is hidden
/// when a session ends; the compositor was not, so the ended session's frozen
/// desktop covered the library. The library hides that view when the session
/// ends and shows it again when the next one begins. [library-surface] logs
/// both. MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP=0 leaves it alone.
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

    @MainActor static func hide(reason: String) {
        guard MadeiraConfig.flag("MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP"), LibraryModel.shared.enabled,
              LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        guard winios_compositor_set_hidden(1) != 0 else { return }
        hiddenByUs = true
        LogStore.shared.log("[library-surface] hid ended desktop reason=\(reason)")
    }

    @MainActor static func show() {
        guard hiddenByUs else { return }
        hiddenByUs = false
        _ = winios_compositor_set_hidden(0)
        LogStore.shared.log("[library-surface] desktop shown for the new session")
    }
}
