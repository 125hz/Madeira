import SwiftUI
import UniformTypeIdentifiers
import UIKit
import Darwin
import ImageIO
import GameController
import Combine

enum DeviceLoadDiagnostics {
    private static var lastReport = 0.0
    private static var timer: Timer?
    static func start() {
        guard timer == nil else { return }
        let value = Timer(timeInterval: 10, repeats: true) { _ in report() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    static func report() {
        guard wine_process_is_running() != 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastReport >= 10 else { return }
        lastReport = now
        guard getenv("MADEIRA_DEVICE_STATS").map({ String(cString: $0) != "0" }) ?? true else { return }
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        fputs("[device-load] ml1160 thermal=\(thermal) low-power=\(process.isLowPowerModeEnabled ? 1 : 0) capture=\(UIScreen.main.isCaptured ? 1 : 0)\n", stderr)
    }
}

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
    var folderBytes: Int64?
    var metadataChecked: Date?
    var metadataRevision: Int?
    var overlayFields: [String]?
    var semaphoreFastPath: Bool?
    var anisotropyLimit: Int?
    var desktop: Bool?
    // Store identity is independent of the editable artwork match.
    var steamAppID: Int?
    var steamInstallPath: String?
    var steamInstalled: Bool?
    var steamSession: String?
    var steamBigPicture: Bool?
    // ml1310: installed by Madeira's own Steam downloader. relativePath is the
    // game's executable; it starts directly unless steamClientLaunch routes it
    // through the Windows Steam client at steamClientPath.
    var steamNative: Bool?
    var steamClientLaunch: Bool?
    var steamClientPath: String?
    var steamBuildID: Int?
    var usesSteam: Bool { steamSession != nil || (steamAppID != nil && (steamNative != true || steamClientLaunch == true)) }
    /// Windows path of the Steam client used for a client-routed launch.
    private var steamClientWindowsPath: String {
        guard steamNative == true else { return windowsPath }
        return "C:\\" + (steamClientPath ?? "").replacingOccurrences(of: "/", with: "\\")
    }
    var launchArguments: String {
        if desktop == true { return "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" }
        guard usesSteam else { return arguments }
        let compatibility = steamSession != "installer" && LibraryFlags.enabled("MADEIRA_STEAM_COMPAT")
            ? " -no-cef-sandbox -cef-disable-gpu -nocrashmonitor" : ""
        // ml1470: a lighter client, after GameNative's Steam profile: no hang watchdog to kill a
        // helper that is slow under emulation, no overlay injected into games, no friends window and
        // no shader pre-cache downloads. MADEIRA_STEAM_LIGHT=0 omits these flags.
        let light = steamSession != "installer" && LibraryFlags.enabled("MADEIRA_STEAM_LIGHT")
            ? " -cef-disable-hang-timeouts -nooverlay -nofriendsui -noshaders" : ""
        let mode: String
        // ml1360: a game launch keeps Steam's library window closed (-silent);
        // sign-in and error windows still appear. MADEIRA_STEAM_SILENT=0 shows it.
        let silent = LibraryFlags.enabled("MADEIRA_STEAM_SILENT") ? " -silent" : ""
        if let id = steamAppID { mode = steamInstalled == false ? " steam://install/\(id)" : silent + " -applaunch \(id)" }
        else { mode = steamBigPicture == true ? " -gamepadui" : "" }
        return "/desktop=madeira,\(resolution) \"\(steamClientWindowsPath)\"" + compatibility + light + mode + (arguments.isEmpty ? "" : " " + arguments)
    }
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
        for character in launchArguments {
            if character == "\"" { quoted.toggle() }
            if !quoted && (character == " " || character == "\t") { inToken = false }
            else if !inToken { tokens += 1; inToken = true }
        }
        if usesSteam {
            let client = steamNative == true ? (steamClientPath ?? "") : relativePath
            if steamNative == true && client.isEmpty {
                throw LibraryError.message("Install the Windows Steam client (Settings › Windows Steam client), or start this game directly.")
            }
            guard LibraryFlags.enabled("MADEIRA_STEAM"), SteamPaths.safeRelative(client, under: LibraryModel.drive) != nil,
                  steamAppID.map(SteamPaths.validAppID) ?? true,
                  steamSession == nil || ["client", "installer"].contains(steamSession!) else {
                throw LibraryError.message("The Steam launch profile is invalid or Steam integration is disabled.")
            }
        }
        guard launchArguments.utf8.count < 1024 else { throw LibraryError.message("The complete launch command is too long.") }
        guard !quoted, tokens <= 16 else { throw LibraryError.message("Use balanced double quotes and at most 16 launch arguments.") }
    }

    // Called on the existing launch worker, after text-file defaults are read.
    func applyEnvironment() {
        configureLaunch()
        setenv("FEX_X87REDUCEDPRECISION", reducedX87 ? "1" : "0", 1)
        setenv("MADEIRA_FASTSYNC", fastSync ? "auto" : "0", 1)
        setenv("MADEIRA_FASTSYNC_SEM", semaphoreFastPath == true ? "1" : "0", 1)
        setenv("MADEIRA_EXTENDED_MODES", extendedModes ? "1" : "0", 1)
        setenv("DXMT_D9_ANISO_LIMIT", String(anisotropyLimit ?? 0), 1)
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
        madeira_set_vsync_locked(Int32(fpsMode))
        fputs("[frontend] ml1140 launch profile applied\n", stderr)
        LogStore.shared.log("[display-shape] ml1340 resolution=\(resolution) mode=\(display)")
    }
    func configureLaunch() {
        setenv("MADEIRA_EXE", desktop == true || usesSteam ? "explorer.exe" : windowsPath, 1)
        setenv("MADEIRA_ARGS", launchArguments, 1)
        if desktop == true || usesSteam { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
        // ml1470: the Steam client trades messages with its Chromium helper, which FEX already
        // runs with stricter ordering (found by its libcef.dll). Give the client the same; the
        // games it starts keep the default. MADEIRA_STEAM_ORDERED_CLIENT=0 turns this off.
        let client = steamClientWindowsPath.split(separator: "\\").last.map(String.init) ?? ""
        if usesSteam, !client.isEmpty, LibraryFlags.enabled("MADEIRA_STEAM_ORDERED_CLIENT") {
            setenv("MADEIRA_ORDERED_PROFILE_CLIENT", client, 1)
            LogStore.shared.log("[ordered-profile] ml1470 Steam client \(client) gets the stricter ordering")
        } else {
            unsetenv("MADEIRA_ORDERED_PROFILE_CLIENT")
        }
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
    @Published var launchLogs = false
    private var launchDismissLogged = false
    var menuButtonRect = CGRect.zero
    var performanceRect = CGRect.zero
    private let modalTouchGuard = LibraryFlags.enabled("MADEIRA_MODAL_TOUCH_GUARD")
    var blocksGameplayTouch: Bool { modalTouchGuard && current != nil && (menu || launching) }
    private var timer: Timer?
    private var sawProcess = false
    private var readOnly = false
    private var metadataInFlight = Set<UUID>()
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
        var entry = entry
        if let i = next.firstIndex(where: { $0.id == entry.id }) {
            // A details sheet may predate an asynchronous metadata refresh.
            if (next[i].metadataChecked ?? .distantPast) > (entry.metadataChecked ?? .distantPast) {
                entry.folderBytes = next[i].folderBytes; entry.graphicsAPI = next[i].graphicsAPI
                entry.metadataChecked = next[i].metadataChecked
                entry.metadataRevision = next[i].metadataRevision
            }
            if let appID = next[i].steamAppID, appID == entry.steamAppID {
                // Client-managed entries follow the client's scan; a native
                // entry's executable is user-selectable, but its install
                // state follows the downloader.
                if next[i].steamNative != true { entry.relativePath = next[i].relativePath }
                entry.steamInstallPath = next[i].steamInstallPath
                entry.steamInstalled = next[i].steamInstalled; entry.folderBytes = next[i].folderBytes
                entry.steamNative = next[i].steamNative; entry.steamBuildID = next[i].steamBuildID
            }
            next[i] = entry
        } else { next.append(entry) }
        persist(next)
    }
    func mergeSteam(_ snapshot: SteamSnapshot) {
        guard !readOnly, current == nil, let client = snapshot.client else { return }
        var next = entries
        let found = Set(snapshot.apps.map(\.id))
        let hidden = Set(UserDefaults.standard.array(forKey: "madeiraSteamHidden") as? [Int] ?? [])
        for app in snapshot.apps where !hidden.contains(app.id) && (app.installed || next.contains(where: { $0.steamAppID == app.id })) {
            // ml1310: games installed by Madeira's downloader keep their own
            // executable and install state; the client scan never rewrites them.
            if next.contains(where: { $0.steamAppID == app.id && $0.steamNative == true }) { continue }
            if let index = next.firstIndex(where: { $0.steamAppID == app.id }) {
                next[index].relativePath = client; next[index].steamInstallPath = app.relativeFolder
                next[index].steamInstalled = app.installed; next[index].folderBytes = app.bytes
            } else {
                var entry = LibraryEntry(title: app.name, relativePath: client, bits: 0)
                entry.steamAppID = app.id; entry.steamID = app.id; entry.steamInstallPath = app.relativeFolder
                entry.steamInstalled = true; entry.folderBytes = app.bytes
                next.append(entry)
            }
        }
        if snapshot.complete {
            for index in next.indices where next[index].steamAppID != nil && next[index].steamNative != true && !found.contains(next[index].steamAppID!) {
                next[index].steamInstalled = false
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if (try? encoder.encode(next)) != (try? encoder.encode(entries)) { persist(next) }
    }
    func remove(_ id: UUID) {
        if let appID = entries.first(where: { $0.id == id })?.steamAppID {
            var hidden = UserDefaults.standard.array(forKey: "madeiraSteamHidden") as? [Int] ?? []
            if !hidden.contains(appID) { hidden.append(appID); UserDefaults.standard.set(hidden, forKey: "madeiraSteamHidden") }
        }
        persist(entries.filter { $0.id != id })
    }
    /// ml1310: record a game installed (or updated) by Madeira's Steam
    /// downloader. An existing entry for the same App ID keeps its title,
    /// artwork, profile and a still-present executable choice.
    func upsertNativeSteam(_ installed: LibraryEntry) {
        guard !readOnly, let appID = installed.steamAppID else { return }
        var next = entries
        if let index = next.firstIndex(where: { $0.steamAppID == appID }) {
            var entry = next[index]
            let keepExecutable = entry.steamNative == true && (try? Self.executable(entry.relativePath)) != nil
            if !keepExecutable { entry.relativePath = installed.relativePath; entry.bits = installed.bits; entry.arguments = installed.arguments }
            entry.steamNative = true; entry.steamInstalled = true
            entry.steamInstallPath = installed.steamInstallPath; entry.steamBuildID = installed.steamBuildID
            entry.folderBytes = installed.folderBytes ?? entry.folderBytes
            if entry.graphicsAPI == nil { entry.graphicsAPI = installed.graphicsAPI }
            next[index] = entry
        } else {
            next.append(installed)
        }
        persist(next)
    }
    /// ml1310: forget an uninstalled native Steam game without hiding the
    /// App ID from the Windows client's import list.
    func removeSteamInstall(_ id: UUID) {
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

    @MainActor
    func refreshMetadata(_ id: UUID) async {
        let revision = (LibraryFlags.enabled("MADEIRA_LIBRARY_INSTALL_SIZE") ? 2 : 1) + (LibraryFlags.enabled("MADEIRA_LIBRARY_API_SCAN") ? 10 : 0)
        guard !metadataInFlight.contains(id), let entry = entries.first(where: { $0.id == id }), entry.desktop != true, entry.steamAppID == nil || entry.steamNative == true,
              entry.metadataRevision != revision || Date().timeIntervalSince(entry.metadataChecked ?? .distantPast) > 86400,
              let url = try? Self.executable(entry.relativePath) else { return }
        metadataInFlight.insert(id)
        defer { metadataInFlight.remove(id) }
        let result = await LibraryMetadataScanner.shared.scan(url, drive: Self.drive)
        guard !Task.isCancelled, var updated = entries.first(where: { $0.id == id }) else { return }
        updated.folderBytes = result.bytes
        if let api = result.api { updated.graphicsAPI = api }
        updated.metadataChecked = Date(); updated.metadataRevision = revision; save(updated)
        fputs("[library-metadata] ml1250 install scan revision=\(revision) api=\(updated.graphicsAPI ?? "unknown") bytes=\(result.bytes ?? -1)\n", stderr)
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

    func begin(_ entry: LibraryEntry) {
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false; launchLogs = false
        launchSurface = winios_surface_present_count()
        launching = true; overlayFields = entry.overlayFields ?? ["FPS", "Frame time", "RAM", "Battery"]
        activeEntry = entry; current = entry.id; menu = false; performance = entry.performance; liveLogs = entry.liveLogs
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
        if entry.steamSession == nil { var played = entry; played.lastPlayed = Date(); save(played) }
        if entry.usesSteam { fputs("[steam-bridge] ml1260 session=\(entry.steamSession ?? "app") appid=\(entry.steamAppID ?? 0) desktop=1\n", stderr) }
        // ml1420: what the Windows Steam client downloads before the game starts.
        SteamClientProgressModel.shared.start(entry)
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
    }
    func launchFailed() { if current != nil && !sawProcess { finish(); error = "The session could not start. Check the diagnostic log and JIT status." } }
    /// ml1420: the starting screen could stay visible (and unresponsive) after
    /// the game was presenting. The animated removal of a scrolling view with
    /// live content is the suspected cause (unproven). Both flags now change in
    /// one transaction without animation. MADEIRA_LAUNCH_VIEW_INSTANT=0 restores
    /// the animated dismissal.
    func showGameView(reason: String = "button") {
        let instant = LibraryFlags.enabled("MADEIRA_LAUNCH_VIEW_INSTANT")
        if launching && !launchDismissLogged {
            launchDismissLogged = true
            fputs("[launch-view] ml1420 dismissed reason=\(reason) logs=\(launchLogs ? 1 : 0) instant=\(instant ? 1 : 0)\n", stderr)
        }
        if launchLogs { LogStore.shared.setDisplayActive(liveLogs) }
        if instant {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { launchLogs = false; launching = false }
        } else {
            if launchLogs { launchLogs = false }
            withAnimation(.easeInOut(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.4)) { launching = false }
        }
    }
    func toggleLaunchLogs() {
        launchLogs.toggle()
        LogStore.shared.setDisplayActive(liveLogs || launchLogs)
        fputs("[startup-log] ml1180 visible=\(launchLogs ? 1 : 0)\n", stderr)
    }
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
        fputs("[modal-input] ml1180 touch guard=\(modalTouchGuard ? 1 : 0)\n", stderr)
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
            if LibraryFlags.enabled("MADEIRA_SESSION_TOOLS") { entry.display = InputSettings.shared.displayMode.rawValue }
            entry.overlayFields = overlayFields; save(entry)
        }
    }
    private func finish() {
        timer?.invalidate(); timer = nil
        SteamClientProgressModel.shared.stop()
        saveCurrentProfile()
        let controls = TouchControlsModel.shared
        InputGuard.shared.releaseAll("frontend-exit")
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        InputSettings.shared.displayMode = savedDisplay
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
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
        if LibraryFlags.enabled("MADEIRA_LIBRARY_INSTALL_SIZE") {
            let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "release"]
            for _ in 0..<4 {
                guard binaryFolders.contains(installation.lastPathComponent.lowercased()) else { break }
                let parent = installation.deletingLastPathComponent()
                guard parent.path.hasPrefix(drive.path + "/"),
                      !["program files", "program files (x86)", "games", "common", "steamapps"].contains(parent.lastPathComponent.lowercased()) else { break }
                installation = parent
            }
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
        let extended = LibraryFlags.enabled("MADEIRA_LIBRARY_API_SCAN")
        var budget = 32 * 1024 * 1024
        var pending = [executable], visited = Set<String>(), apis = Set<String>()
        // A launcher may start a sibling executable rather than import its engine.
        // Restrict fallback to the same installation directory and a small count.
        if extended && LibraryModel.graphicsImports(executable) == nil {
            pending.insert(contentsOf: siblings.filter {
                $0.pathExtension.lowercased() == "exe" && $0 != executable &&
                $0.resolvingSymlinksInPath().path.hasPrefix(drive.path + "/")
            }.sorted { $0.path < $1.path }.prefix(8), at: 0)
        }
        while let file = pending.popLast(), visited.count < 64, !Task.isCancelled {
            if !visited.insert(file.path).inserted { continue }
            let imports = LibraryModel.importNames(file)
            apis.formUnion(LibraryModel.apiNames(imports))
            if extended { apis.formUnion(dynamicAPIs(file, budget: &budget)) }
            for name in imports { if let dependency = local[name], !visited.contains(dependency.path) { pending.append(dependency) } }
        }
        return (complete && walker != nil ? bytes : nil, apis.isEmpty ? nil : apis.sorted().joined(separator: "/"))
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
        // Keep native tracking while allowing the surrounding glass capsule to
        // supply the only background, including during a held selection.
        // Background image height participates in UIKit's segment layout.
        // Keep a full-height transparent canvas so the symbol is not clipped.
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
            } else if let id = entry.steamID {
                AsyncImage(url: backdrop ? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg") : SteamCatalog.cover(id)) { image in
                    image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
                } placeholder: { Color.clear }
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
            if let api = LibraryFlags.enabled("MADEIRA_COMPACT_API_BADGE") ? LibraryRendererBadge.compact(entry.graphicsAPI) : entry.graphicsAPI { badge(api) }
            if entry.steamAppID != nil { badge(entry.steamInstalled == false ? "Not installed" : "Steam") }
            if SteamAccountModel.enabled && SteamAccountModel.shared.updateAvailable(for: entry) { badge("Update") }
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
            // ml1420: which build is installed (BuildStamp, ContentView.swift).
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
    private func update() { jit = StikJITHelper.readyToLaunch; memory = EntitlementStatus.check().increasedMemory }
}

struct LibraryView: View {
    @ObservedObject private var model = LibraryModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @State private var browser = false
    @State private var steamManager = false
    @State private var selected: LibraryEntry?
    @State private var search = ""
    @State private var focused: UUID?
    @ObservedObject private var controller = LibraryController.shared
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0
    @AppStorage("madeiraLibraryLayout") private var layout = "cards"
    @AppStorage("madeiraLibrarySort") private var sort = "played"
    private let refinements = LibraryFlags.enabled("MADEIRA_LIBRARY_REFINEMENTS")
    private let layoutsEnabled = LibraryFlags.enabled("MADEIRA_LIBRARY_LAYOUTS")
    // ml1310: Steam / other-games sections and native Steam account.
    @ObservedObject private var steam = SteamAccountModel.shared
    @State private var steamSignIn = false
    @State private var steamGame: SteamGameRef?
    @AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true
    private let nativeSteam = SteamAccountModel.enabled
    private let sectioned = SteamAccountModel.enabled && LibraryFlags.enabled("MADEIRA_LIBRARY_SECTIONS")
    struct SteamGameRef: Identifiable { let id: Int }
    private enum Cell: Identifiable {
        case entry(LibraryEntry), owned(SteamOwnedGame)
        var id: UUID { switch self { case .entry(let entry): return entry.id; case .owned(let game): return game.focusID } }
    }
    private var steamEntries: [LibraryEntry] { entries.filter { $0.steamAppID != nil } }
    private var otherEntries: [LibraryEntry] { entries.filter { $0.steamAppID == nil } }
    /// Owned games without a library entry, split into in-progress downloads
    /// (shown with the installed games) and the rest.
    private var ownedGames: (downloading: [SteamOwnedGame], notInstalled: [SteamOwnedGame]) {
        let owned = steam.uninstalledGames(excluding: model.entries)
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return (owned.filter { steam.downloads[$0.id] != nil }, owned.filter { steam.downloads[$0.id] == nil })
    }
    private var focusCells: [Cell] {
        guard sectioned else { return entries.map(Cell.entry) }
        let owned = ownedGames
        return owned.downloading.map(Cell.owned) + steamEntries.map(Cell.entry)
            + (steam.phase == .signedIn && showUninstalled ? owned.notInstalled.map(Cell.owned) : [])
            + otherEntries.map(Cell.entry)
    }
    private var entries: [LibraryEntry] {
        let visible = model.entries.filter { $0.desktop != true && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        guard refinements else { return visible }
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
            Group {
                if refinements {
                    LibraryTabControl(selection: $tab).frame(width: 160, height: 52)
                        .modifier(LibraryPillGlass())
                } else {
                    HStack(spacing: 4) {
                        tabButton("Library", symbol: "square.grid.2x2.fill", index: 0)
                        tabButton("Settings", symbol: "gearshape.fill", index: 1)
                    }.padding(5).modifier(LibraryPillGlass())
                }
            }.padding(.bottom, 5).padding(.top, 8)
        }
        .sheet(isPresented: $steamManager) { SteamLibraryView(play: { profile in steamManager = false; play(profile) }, enableJIT: enableJIT) }
        .sheet(isPresented: $steamSignIn) { SteamSignInView() }
        .sheet(item: $steamGame) { ref in
            SteamGameSheet(appID: ref.id) { entry in
                // Let the download sheet finish dismissing before presenting details.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { selected = entry }
            }
        }
        .alert("Steam", isPresented: Binding(get: { steam.error != nil }, set: { if !$0 { steam.error = nil } })) {
            Button("OK", role: .cancel) { steam.error = nil }
        } message: { Text(steam.error ?? "") }
        .task { await SteamLibraryModel.shared.refresh() }
        .task { steam.start() }
        .onChange(of: model.current) { _, current in
            steam.sessionChanged(active: current != nil)
            if current == nil { Task { await SteamLibraryModel.shared.refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await SteamLibraryModel.shared.refresh() } } }
        .onAppear { fputs("[steam-bridge] ml1260 enabled=\(LibraryFlags.enabled("MADEIRA_STEAM") ? 1 : 0) compact-badges=\(LibraryFlags.enabled("MADEIRA_COMPACT_API_BADGE") ? 1 : 0)\n", stderr) }
        .onAppear { fputs("[frontend-layout] ml1190 full-height native tab symbols and metadata=\(refinements ? 1 : 0)\n", stderr) }
        // LogStore: stderr is not captured before a Wine session starts.
        .onAppear { LogStore.shared.log("[library-sections] ml1310 native-steam=\(nativeSteam ? 1 : 0) sections=\(sectioned ? 1 : 0)") }
        .onReceive(controller.commands) { command in
            if selected == nil, !browser, !steamManager, !steamSignIn, steamGame == nil, command == "tab" { tab = 1 - tab }
        }
    }
    private func tabButton(_ title: String, symbol: String, index: Int) -> some View {
        Button { tab = index } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(tab == index ? Color.accentColor : .secondary)
                .background(tab == index ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
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
            Section("Controller") {
                Toggle("Right stick controls mouse", isOn: $input.padRightStickMouse)
            }
            if nativeSteam {
                SteamSettingsSection(signIn: { steamSignIn = true }, openClient: { steamManager = true })
            }
            Section("Library") {
                Text("Add complete application folders to Madeira/wine/drive_c using Files. Display, frame limit, and compatibility options are saved per game.")
                Text("The optional interface is enabled by MADEIRA_FRONTEND=1 in madeira-frontend.txt or madeira-env.txt.").font(.caption).foregroundStyle(.secondary)
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
                // With the native Steam library, the Windows client lives in Settings.
                if LibraryFlags.enabled("MADEIRA_STEAM") && !nativeSteam {
                    Button { steamManager = true } label: {
                        Label("Steam", systemImage: "storefront").font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }.buttonStyle(.plain)
                }
                }
                if sectioned {
                    sections(width: viewport.size.width)
                } else if model.entries.filter({ $0.desktop != true }).isEmpty {
                    ContentUnavailableView("Make yourself at home", systemImage: "gamecontroller", description: Text("Add an executable from Madeira’s drive_c folder to get started."))
                } else {
                    cells(entries.map(Cell.entry), width: viewport.size.width)
                }
            }.padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .refreshable { if sectioned && steam.phase == .signedIn { await steam.refreshLibrary() } }
        .onReceive(controller.commands) { command in
            guard tab == 0, selected == nil, !browser, !steamManager, !steamSignIn, steamGame == nil else { return }
            let items = focusCells
            let ids = [LibraryEntry.desktopID] + items.map(\.id)
            let index = ids.firstIndex(where: { $0 == focused }) ?? 0
            if command == "add" { browser = true }
            else if command == "accept" {
                if index == 0 { selected = model.entries.first(where: { $0.desktop == true }) ?? .desktopEntry }
                else { open(items[index - 1]) }
            }
            else if ["left", "right", "up", "down"].contains(command) {
                let delta = command == "left" || command == "up" ? -1 : 1
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.18)) { focused = ids[(index + delta + ids.count) % ids.count] }
            }
        }
        .searchable(text: $search, prompt: "Search your library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if layoutsEnabled {
                    Menu {
                        Picker("Library layout", selection: $layout) {
                            Label("Cards", systemImage: "square.grid.2x2").tag("cards")
                            Label("Compact cards", systemImage: "square.grid.3x3").tag("compact")
                            Label("List", systemImage: "list.bullet").tag("list")
                        }
                        if refinements {
                            Picker("Sort by", selection: $sort) {
                                Label("Last played", systemImage: "clock").tag("played")
                                Label("Name", systemImage: "textformat.abc").tag("name")
                                Label("Recently added", systemImage: "plus").tag("added")
                                Label("Folder size", systemImage: "internaldrive").tag("size")
                            }
                        }
                    } label: { Label("Library options", systemImage: "line.3.horizontal.decrease") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button { browser = true } label: { Label("Add executable", systemImage: "plus") } }
        }
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
    // ml1310: Steam games (installed, downloading, not installed) and other games.
    @ViewBuilder private func sections(width: CGFloat) -> some View {
        let owned = ownedGames
        let steamInstalled = steamEntries
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "Steam", count: steamInstalled.count) {
                if steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }
            }
            if steam.phase == .signedOut { SteamSignInCard { steamSignIn = true } }
            if !owned.downloading.isEmpty || !steamInstalled.isEmpty {
                cells(owned.downloading.map(Cell.owned) + steamInstalled.map(Cell.entry), width: width)
            } else if steam.phase == .signedIn && !steam.refreshing && owned.notInstalled.isEmpty && search.isEmpty {
                Text(steam.libraryUpdated == nil ? "Pull down to load your Steam library."
                     : "No Windows games were found in this Steam library.").foregroundStyle(.secondary)
            }
            if steam.phase == .signedIn && !owned.notInstalled.isEmpty {
                Button {
                    withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) { showUninstalled.toggle() }
                } label: {
                    HStack {
                        Text("Not installed").font(.headline)
                        Text("\(owned.notInstalled.count)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showUninstalled ? 90 : 0)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle()).frame(minHeight: 44)
                }.buttonStyle(.plain)
                    .accessibilityValue(showUninstalled ? "Shown" : "Hidden")
                if showUninstalled { cells(owned.notInstalled.map(Cell.owned), width: width) }
            }
        }
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(title: "Other games", count: otherEntries.count) {
                Button { browser = true } label: { Label("Add a game", systemImage: "plus.circle") }.font(.subheadline)
            }
            if otherEntries.isEmpty {
                Text(search.isEmpty
                     ? "Copy a game's folder into Madeira › wine › drive_c with the Files app, then tap + and choose its .exe."
                     : "No other games match your search.")
                    .foregroundStyle(.secondary)
            } else {
                cells(otherEntries.map(Cell.entry), width: width)
            }
        }
    }
    @ViewBuilder private func cells(_ items: [Cell], width viewportWidth: CGFloat) -> some View {
        if layoutsEnabled && layout == "list" {
            LazyVStack(spacing: 8) { ForEach(items) { item in cell(item, list: true) } }
        } else {
            let compact = layoutsEnabled && layout == "compact"
            let width = max(1, min(viewportWidth, 1100) - 32)
            let count = max(1, Int((width + 12) / (compact ? 110 : 154)))
            let cardWidth = min(compact ? 115.0 : 164.0, (width - CGFloat(count - 1) * 12) / CGFloat(count))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: 12, alignment: .top), count: count), alignment: .center, spacing: 18) {
                ForEach(items) { item in cell(item, list: false) }
            }.frame(maxWidth: .infinity, alignment: .center)
        }
    }
    @ViewBuilder private func cell(_ item: Cell, list: Bool) -> some View {
        switch item {
        case .entry(let entry): libraryItem(entry, list: list)
        case .owned(let game):
            Button { steamGame = SteamGameRef(id: game.id) } label: { SteamOwnedCell(game: game, list: list) }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(focused == game.focusID && controller.connected ? Color.accentColor : .clear, lineWidth: 2))
                .id(game.focusID)
        }
    }
    private func open(_ item: Cell) {
        switch item {
        case .entry(let entry): selected = entry
        case .owned(let game): steamGame = SteamGameRef(id: game.id)
        }
    }
    private func libraryItem(_ entry: LibraryEntry, list: Bool) -> some View {
        Button { selected = entry } label: {
            Group {
                if list {
                    HStack(spacing: 14) {
                        LibraryArtwork(entry: entry).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) { Text(entry.title).font(.headline).lineLimit(2); LibraryBadges(entry: entry).foregroundStyle(.secondary) }
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
            .task(id: entry.id, priority: .utility) { if refinements { await model.refreshMetadata(entry.id) } }
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
    @State private var findCover = false
    @State private var importCover = false
    @State private var remove = false
    @State private var leaving = false
    @State private var error: String?
    private let launchPolish = LibraryFlags.enabled("MADEIRA_LAUNCH_POLISH")
    /// ml1340: "WxH" matching this screen's landscape aspect at 720 lines
    /// (width rounded to a multiple of 8), or nil when it equals a preset or
    /// MADEIRA_SCREEN_SHAPE_RESOLUTION=0.
    static var screenShapeResolution: String? {
        guard LibraryFlags.enabled("MADEIRA_SCREEN_SHAPE_RESOLUTION") else { return nil }
        let bounds = UIScreen.main.bounds
        let long = max(bounds.width, bounds.height), short = min(bounds.width, bounds.height)
        guard short > 0 else { return nil }
        let width = Int((720 * long / short / 8).rounded()) * 8
        guard (640...4096).contains(width), width != 1280, width != 960 else { return nil }
        return "\(width)x720"
    }
    private func start() {
        guard !leaving else { return }
        if entry.steamNative == true {
            // ml1310: an unfinished update mixes old and new files.
            if let appID = entry.steamAppID, SteamAccountModel.shared.downloads[appID] != nil {
                error = "This game's update has not finished. Resume it and wait for it to complete before playing."; return
            }
            if entry.steamClientLaunch == true {
                entry.steamClientPath = SteamLibraryModel.shared.snapshot.client
            } else if (try? LibraryModel.executable(entry.relativePath)) == nil {
                error = "The game's files are missing. Uninstall it and install it again."; return
            }
            LogStore.shared.log("[steam-play] ml1310 app=\(entry.steamAppID ?? 0) mode=\(entry.steamClientLaunch == true ? "client" : "direct") client-found=\(entry.steamClientPath == nil ? 0 : 1)")
            if entry.steamClientLaunch == true {
                LogStore.shared.log("[steam-silent] ml1360 enabled=\(LibraryFlags.enabled("MADEIRA_STEAM_SILENT") ? 1 : 0)")
                if let appID = entry.steamAppID { SteamAccountModel.logInstallRecord(appID: appID) }
            }
        }
        leaving = true
        let profile = entry
        fputs("[launch-feedback] ml1250 pending=1 polish=\(launchPolish ? 1 : 0)\n", stderr)
        // Give the pressed state a display turn before saving and handing off.
        DispatchQueue.main.asyncAfter(deadline: .now() + (launchPolish ? 0.12 : 0)) {
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
                            Button(action: start) { HStack(spacing: 10) { Image(systemName: "play.fill"); Text(entry.steamAppID != nil && entry.steamInstalled == false ? "Install" : "Play").fontWeight(.semibold) }.frame(minWidth: 100, minHeight: 30) }
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
                    Button("Find on Steam", systemImage: "magnifyingglass") { findCover = true }
                    Button("Choose cover image", systemImage: "photo") { importCover = true }
                    if entry.coverFile != nil { Button("Use Steam artwork") { entry.coverFile = nil } }
                } }
                Section("Display") {
                    Picker("Resolution", selection: $entry.resolution) {
                        ForEach(["640x480", "800x600", "960x540", "1024x768", "1280x720", "1280x960", "1920x1080", "2560x1440"], id: \.self) { Text($0).tag($0) }
                        // ml1340: this device's own aspect ratio at 720 lines, so
                        // the game fills the screen without bars or stretching.
                        if let shape = Self.screenShapeResolution {
                            Text("Screen shape (\(shape.replacingOccurrences(of: "x", with: "×")))").tag(shape)
                        }
                    }
                    Picker("Aspect & scaling", selection: $entry.display) { ForEach(DisplayMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                    FPSChoice(mode: $entry.fpsMode)
                    Toggle("Offer higher display modes", isOn: $entry.extendedModes)
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    Toggle("Fast synchronization", isOn: $entry.fastSync)
                    Toggle("Fast semaphore waits (experimental)", isOn: Binding(get: { entry.semaphoreFastPath ?? false }, set: { entry.semaphoreFastPath = $0 }))
                    Picker("D3D9 anisotropic filtering", selection: Binding(get: { entry.anisotropyLimit ?? 0 }, set: { entry.anisotropyLimit = $0 })) {
                        Text("Application default").tag(0)
                        ForEach([1, 2, 4, 8], id: \.self) { Text("Up to \($0)×").tag($0) }
                    }
                    TextField("Launch arguments", text: $entry.arguments, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: { Text("Compatibility & performance") } footer: {
                    Text("Full x87 precision can improve compatibility at a performance cost. Synchronization settings apply to the next launch. Full precision changes may still require restarting Madeira.")
                }
                Section("On screen") {
                    Toggle("Performance overlay", isOn: $entry.performance)
                    Toggle("Live logs", isOn: $entry.liveLogs)
                    Toggle("Touch controls", isOn: $entry.touchControls)
                    LabeledContent("Control opacity") { Slider(value: $entry.controlOpacity, in: 0.15...1) }
                    LabeledContent("Control size") { Slider(value: $entry.controlSize, in: 0.5...2) }
                    Text("Arrange buttons and choose XInput, mouse, or keyboard actions from the in-game menu.").font(.caption).foregroundStyle(.secondary)
                }
                if entry.steamNative == true && SteamAccountModel.enabled {
                    SteamEntrySection(entry: $entry) {
                        leaving = true; SteamAccountModel.shared.uninstall(entry); dismiss()
                    }
                }
                Section("Executable") { Text(entry.windowsPath).font(.caption.monospaced()).textSelection(.enabled) }
                if !(entry.steamNative == true && SteamAccountModel.enabled) {
                    Section { Button("Remove from library", role: .destructive) { remove = true } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Game details").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                if entry.steamAppID == nil || entry.steamNative == true, entry.graphicsAPI == nil, let url = try? LibraryModel.executable(entry.relativePath) { entry.graphicsAPI = LibraryModel.graphicsImports(url) }
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
                guard !leaving, !findCover, !importCover, !remove else { return }
                if command == "back" { model.save(entry); dismiss() }
                if command == "accept" { start() }
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

struct LibraryPillGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let enabled = LibraryFlags.enabled("MADEIRA_FRONTEND_GLASS")
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color(uiColor: .secondarySystemBackground), in: Capsule()) }
        else if #available(iOS 26, *), Self.enabled { content.glassEffect(.regular.interactive(), in: Capsule()) }
        else { content.background(.regularMaterial, in: Capsule()) }
    }
}

// Keep frame-rate drag state in this small view. Global translation remains
// stable while the view moves; local coordinates feed its own movement back in.
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
    private let draggable = LibraryFlags.enabled("MADEIRA_HUD_DRAG")

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
        }, including: draggable ? .all : .none)
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

struct LibraryHUD: View {
    /// ml1430: top offset for the overlays pinned to the top edge. This HUD ignores the safe
    /// area, and with the game view in portrait its reported top inset came out as zero while
    /// the status bar was showing, so the download banner sat under the clock and battery.
    /// The larger of the reported inset and the visible status bar's height is used.
    static func topInset(_ geo: GeometryProxy) -> CGFloat {
        let bar = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.statusBarManager?.statusBarFrame.height ?? 0
        return max(geo.safeAreaInsets.top, bar)
    }
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @ObservedObject private var input = InputSettings.shared
    private let sessionTools = LibraryFlags.enabled("MADEIRA_SESSION_TOOLS")
    private let launchPolish = LibraryFlags.enabled("MADEIRA_LAUNCH_POLISH")
    @State private var launchVisible = false
    @State private var launchChanges = 0
    // ml1420: the Windows Steam client's downloads for a client-routed launch.
    @ObservedObject private var steamProgress = SteamClientProgressModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if model.launching, let entry = model.activeEntry {
                    LibraryArtwork(entry: entry, backdrop: true).overlay(.black.opacity(0.65)).ignoresSafeArea()
                        .opacity(launchVisible || !launchPolish ? 1 : 0)
                    launchView(entry, geometry: geo)
                        .opacity(launchVisible || !launchPolish ? 1 : 0)
                        .scaleEffect(launchVisible || reduceMotion || !launchPolish ? 1 : 0.96)
                }
                if !model.launching && model.performance { LibraryFloatingItem(isMenu: false, viewport: geo.size, insets: geo.safeAreaInsets) }
                if model.liveLogs && !model.launching { LibraryLiveLogs().frame(maxWidth: 550, maxHeight: 140).padding(.top, Self.topInset(geo) + 60).padding(.horizontal, 12).allowsHitTesting(false) }
                if !model.sessionMessage.isEmpty { Text(model.sessionMessage).font(.caption).padding(10).background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity).padding(.top, Self.topInset(geo) + 12).allowsHitTesting(false) }
                // ml1420: once the starting screen is gone (the Steam window
                // itself presents frames), keep showing an active download.
                if !model.launching && !model.menu, let progress = steamProgress.progress, progress.working {
                    SteamClientProgressBanner(progress: progress, compact: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: 420).padding(.horizontal, 16).frame(maxWidth: .infinity)
                        .padding(.top, Self.topInset(geo) + (model.sessionMessage.isEmpty ? 12 : 56))
                        .allowsHitTesting(false)
                }
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
                withAnimation(launchPolish ? .easeOut(duration: reduceMotion ? 0.15 : 0.35) : nil) { launchVisible = true }
            }
            .preferredColorScheme(.dark)
        }.ignoresSafeArea()
        .onAppear { model.saveCurrentProfile(); fputs("[frontend-hud] ml1160 contained menu; stable overlay drag\n", stderr) }
        .onAppear { fputs("[session-tools] ml1180 display-picker/startup-log=\(sessionTools ? 1 : 0)\n", stderr) }
        .onChange(of: model.menu) { _, open in
            LibraryController.shared.configure(enabled: model.enabled, ownsInput: open)
            if !open { model.saveCurrentProfile() }
        }
        // ml1420: proves the HUD saw the starting screen's state change.
        .onChange(of: model.launching) { _, launching in
            guard launchChanges < 4 else { return }
            launchChanges += 1
            fputs("[launch-view] ml1420 hud launching=\(launching ? 1 : 0)\n", stderr)
        }
        .onReceive(LibraryController.shared.commands) { command in
            if command == "menu" { if model.menu { model.menu = false } else { model.showMenu() } }
            else if command == "back", model.menu { model.menu = false }
        }
    }
    private func launchView(_ entry: LibraryEntry, geometry geo: GeometryProxy) -> some View {
        let compact = geo.size.height < 500
        let available = max(0, geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom)
        return ScrollView {
            VStack(spacing: compact ? 10 : 18) {
                LibraryArtwork(entry: entry).frame(width: compact ? 90 : 120, height: compact ? 135 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                ProgressView().tint(.white)
                Text(model.launchSlow ? "Still starting…" : "Starting your game…").foregroundStyle(.white.opacity(0.7))
                if let progress = steamProgress.progress, progress.active {
                    SteamClientProgressBanner(progress: progress).tint(.white).frame(maxWidth: 360)
                }
                if model.launchSlow {
                    Button("Show game view") { model.showGameView(reason: "button") }.frame(minHeight: 44)
                    if sessionTools {
                        Button(model.launchLogs ? "Hide live log" : "Show live log") { model.toggleLaunchLogs() }.frame(minHeight: 44)
                    }
                }
                if model.liveLogs || model.launchLogs {
                    LibraryLiveLogs().frame(maxWidth: 550).frame(height: compact ? 90 : 120).clipped()
                }
            }.padding(16).frame(maxWidth: .infinity).frame(minHeight: available)
        }
        .frame(width: geo.size.width, height: available)
        .padding(.top, geo.safeAreaInsets.top).foregroundStyle(.white).transition(.opacity)
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
                if sessionTools {
                    LabeledContent("Display fit") {
                        Picker("Display fit", selection: $input.displayMode) {
                            ForEach(DisplayMode.allCases, id: \.self) { mode in
                                Label(mode.label, systemImage: mode.symbol).tag(mode)
                            }
                        }.pickerStyle(.menu).labelsHidden()
                            .onChange(of: input.displayMode) { _, mode in
                                model.saveCurrentProfile()
                                fputs("[session-display] ml1180 mode=\(mode.rawValue)\n", stderr)
                            }
                    }
                }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(logs.entries.sorted { $0.lastTimestamp < $1.lastTimestamp }.suffix(7))) {
                    Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.defaultScrollAnchor(.bottom)
            .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            .accessibilityLabel("Live diagnostic log")
    }
}

/// ml1420: what the Windows Steam client is downloading or installing before
/// a client-routed game can start.
struct SteamClientProgressBanner: View {
    let progress: SteamClientProgress
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            if let summary = progress.summary {
                Text(summary).font(compact ? .caption.weight(.medium) : .subheadline)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(maxWidth: compact ? 240 : 300)
            }
            if let detail = progress.detail {
                Text(detail).font(.caption2).opacity(0.75)
            }
        }
        .accessibilityElement(children: .combine)
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
