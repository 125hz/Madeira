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
        // ml1840: canonical config remains available after migration removes
        // madeira-env.txt. MADEIRA_FLAGS_CONFIG=0 restores legacy-only lookup.
        let configured = MadeiraConfig.environmentValues()
        if configured["MADEIRA_FLAGS_CONFIG"] != "0", let value = configured[key] { return value != "0" }
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

/// ml1520: which interface Madeira starts with: the library (the default) or the
/// diagnostic UI. The choice is made in either interface's settings, stored in
/// UserDefaults and read once per run, so a change applies at the next start.
/// Without a stored choice, an explicit MADEIRA_FRONTEND=0/1 line in
/// madeira-frontend.txt or madeira-env.txt still decides. MADEIRA_FRONTEND_DEFAULT_NEW=0
/// makes the diagnostic UI the default again.
enum FrontendChoice {
    static let key = "madeiraFrontend"
    static let startup: (useNew: Bool, source: String) = {
        if let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) {
            return (stored == "new", "setting")
        }
        if let file = legacyFile { return (file, "file") }
        return (LibraryFlags.enabled("MADEIRA_FRONTEND_DEFAULT_NEW"), "default")
    }()
    /// The interface the next start uses.
    static var preferNew: Bool {
        guard let stored = UserDefaults.standard.string(forKey: key), ["new", "old"].contains(stored) else { return startup.useNew }
        return stored == "new"
    }
    static func choose(new useNew: Bool) {
        UserDefaults.standard.set(useNew ? "new" : "old", forKey: key)
        LogStore.shared.log("[frontend] ml1520 next-start choice=\(useNew ? "new" : "old") source=setting")
    }
    private static var logged = false
    static func logStartup() {
        guard !logged else { return }
        logged = true
        LogStore.shared.log("[frontend] ml1520 choice=\(startup.useNew ? "new" : "old") source=\(startup.source)")
    }
    private static var legacyFile: Bool? {
        for name in ["madeira-frontend.txt", "madeira-env.txt"] {
            guard let text = try? String(contentsOf: LibraryModel.documents.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "MADEIRA_FRONTEND=1": return true
                case "MADEIRA_FRONTEND=0": return false
                default: continue
                }
            }
        }
        return nil
    }
}

// ml1140: the library interface; FrontendChoice decides whether it or the diagnostic UI starts.
struct LibraryEntry: Codable, Identifiable {
    var id = UUID()
    var title: String
    var relativePath: String
    var bits: Int
    var steamID: Int?
    var coverFile: String?
    var arguments = ""
    // ml1960: imported launch metadata is distinct from a user's override.
    var steamDefaultArguments: String?
    var resolution = "1280x720"
    var display = "fit"
    var fpsMode = 1
    var reducedX87 = true
    // ml1990: processors reported to Windows code for this game (nil = the device's count).
    // Some engines size worker pools from it and misbehave with many cores.
    var cpuCount: Int?
    var fastSync = true
    var extendedModes = false
    var liveLogs = false
    var performance = false
    var touchControls = false
    var controlOpacity = 0.7
    var controlSize = 1.0
    var controls: [TouchControl]?
    // ml1970: the controller layout (preset id) this game last used; nil = Xbox default.
    var controlLayout: String?
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
    // ml1780: true lets the client run the game's one-time installs (DirectX, Visual C++,
    // PhysX...); otherwise Madeira marks them done before a client start.
    var steamRunInstallers: Bool?
    // ml1970: true starts this game through the regular desktop Steam client even while
    // Madeira Dock is on ("Steam (more usage)" under Start with); nil keeps Madeira Dock.
    var steamDesktopLaunch: Bool?
    var usesSteam: Bool { steamSession != nil || (steamAppID != nil && (steamNative != true || steamClientLaunch == true)) }
    /// ml1490: the Windows Steam client is asked to start this game (-applaunch),
    /// so the Wine desktop shows only the client until the game's window is up.
    var steamGameLaunch: Bool { desktop != true && usesSteam && steamSession == nil && steamAppID != nil && steamInstalled != false }
    /// ml1720: drive-relative path of the Steam client a client-routed launch starts. A native
    /// install's relativePath is the GAME's executable; the client lives at steamClientPath.
    var steamClientRelativePath: String {
        steamNative == true ? (steamClientPath ?? relativePath) : relativePath
    }
    /// Windows path of the Steam client used for a client-routed launch.
    private var steamClientWindowsPath: String {
        guard steamNative == true else { return windowsPath }
        return "C:\\" + (steamClientPath ?? "").replacingOccurrences(of: "/", with: "\\")
    }
    var launchArguments: String {
        launchArguments(dock: MadeiraDock.routes(self))
    }
    func launchArguments(dock: Bool) -> String {
        if desktop == true { return "/desktop=shell,\(resolution) C:\\windows\\system32\\services.exe" }
        guard usesSteam else { return arguments }
        if dock {
            // ml1970: the game's pending one-time installs run first, in the same session.
            if let script = MadeiraDock.installerScript {
                return "/desktop=madeira,\(resolution) C:\\windows\\system32\\cmd.exe /c call \(script) & \"\(MadeiraDock.executable)\""
            }
            return "/desktop=madeira,\(resolution) \"\(MadeiraDock.executable)\""
        }
        // ml1530: a Madeira session lasts while its first program or any program it started
        // runs. Steam's installer starts Steam.exe as it exits, and the session ended before
        // Steam.exe counted (device log: the installer's session closed 13.7 s in and took
        // the just-started client with it). The installer session now also runs services.exe,
        // as the Desktop session does, which keeps the session (and the client) up until the
        // user ends it; it also gives Steam's service a service manager to talk to. cmd.exe
        // starts both. MADEIRA_STEAM_INSTALL_KEEPALIVE=0 starts the installer alone again.
        // ml1540: without start.exe, which faulted at its first instruction on device (log 202:
        // exit c000001d, so services.exe never ran). cmd.exe runs the installer, then
        // services.exe in the foreground: cmd holds the session during the install and
        // services.exe after it, until the setup's button ends the session.
        if steamSession == "installer" && LibraryFlags.enabled("MADEIRA_STEAM_INSTALL_KEEPALIVE") {
            return "/desktop=madeira,\(resolution) C:\\windows\\system32\\cmd.exe /c call \"\(windowsPath)\" & C:\\windows\\system32\\services.exe"
                + (arguments.isEmpty ? "" : " " + arguments)
        }
        let compatibility = steamSession != "installer" && LibraryFlags.enabled("MADEIRA_STEAM_COMPAT")
            ? " -no-cef-sandbox -cef-disable-gpu -nocrashmonitor" : ""
        // ml1470: a lighter client, after GameNative's Steam profile: no hang watchdog to kill a
        // helper that is slow under emulation, no overlay injected into games, no friends window and
        // no shader pre-cache downloads. MADEIRA_STEAM_LIGHT=0 omits these flags.
        let light = steamSession != "installer" && LibraryFlags.enabled("MADEIRA_STEAM_LIGHT")
            ? " -cef-disable-hang-timeouts -nooverlay -nofriendsui -noshaders" : ""
        // ml1500: for a GAME launch only (opening the client keeps its full UI), the rest of
        // GameNative's client options that trim the client's own UI stack. Device log 194: the
        // helper's second process was Chromium's crash reporter (--type=crashpad-handler), a whole
        // extra process and image copy for nothing (-cef-disable-breakpad); chat, Big Picture,
        // VR, streaming drivers, intro video, extensions, remote fonts, video decode and D3D11 in
        // the helper are unused while a game runs. None of these touch the game or Steam's DRM.
        // MADEIRA_STEAM_CEF_LIGHT=0 omits them.
        let lighter = steamSession != "installer" && steamAppID != nil && steamInstalled != false
            && LibraryFlags.enabled("MADEIRA_STEAM_LIGHT") && LibraryFlags.enabled("MADEIRA_STEAM_CEF_LIGHT")
            ? " -cef-disable-breakpad -cef-single-process -cef-in-process-gpu -cef-disable-extensions"
              + " -cef-disable-remote-fonts -cef-disable-accelerated-video-decode -cef-disable-d3d11"
              + " -nochatui -nobigpicture -nointro -vrdisable -skipstreamingdrivers -no-dwrite" : ""
        let mode: String
        // ml1360: a game launch keeps Steam's library window closed (-silent);
        // sign-in and error windows still appear. MADEIRA_STEAM_SILENT=0 shows it.
        // ml1710: license agreements are answered in Madeira before launch (SteamEulaStore), so
        // every game launch stays silent.
        let silent = LibraryFlags.enabled("MADEIRA_STEAM_SILENT") ? " -silent" : ""
        if let id = steamAppID { mode = steamInstalled == false ? " steam://install/\(id)" : silent + " -applaunch \(id)" }
        else { mode = steamBigPicture == true ? " -gamepadui" : "" }
        return "/desktop=madeira,\(resolution) \"\(steamClientWindowsPath)\"" + compatibility + light + lighter + mode + (arguments.isEmpty ? "" : " " + arguments)
    }
    /// ml1500: the client's helper and background programs; see configureLaunch.
    static let steamBackgroundImages = ["steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe",
                                        "steamerrorreporter64.exe", "gldriverquery.exe", "gldriverquery64.exe",
                                        "vulkandriverquery.exe", "vulkandriverquery64.exe", "conhost.exe"]
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
            if MadeiraDock.routes(self) { try MadeiraDock.validate(self) }
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
        // ml1500: the bridge now takes 64 arguments in 4 KB (was 16 in 1 KB), room for a
        // launcher's lightweight-mode flags plus the user's own arguments.
        guard launchArguments.utf8.count < 4096 else { throw LibraryError.message("The complete launch command is too long.") }
        guard !quoted, tokens <= 64 else { throw LibraryError.message("Use balanced double quotes and at most 64 launch arguments in total.") }
    }

    // Called on the existing launch worker, after text-file defaults are read.
    func applyEnvironment(dock: Bool? = nil) {
        configureLaunch(dock: dock)
        setenv("FEX_X87REDUCEDPRECISION", reducedX87 ? "1" : "0", 1)
        if let cpuCount, cpuCount > 0 { setenv("MADEIRA_CPU_COUNT", String(cpuCount), 1) } else { unsetenv("MADEIRA_CPU_COUNT") }
        setenv("MADEIRA_FASTSYNC", fastSync ? "auto" : "0", 1)
        setenv("MADEIRA_FASTSYNC_SEM", semaphoreFastPath == true ? "1" : "0", 1)
        // ml1520: the "Offer higher display modes" toggle is gone, so every game gets the default
        // (off) mode ladder whatever an older profile stored. MADEIRA_EXTENDED_MODES_FORCE_DEFAULT=0
        // honours the stored value again.
        let extended = LibraryFlags.enabled("MADEIRA_EXTENDED_MODES_FORCE_DEFAULT") ? false : extendedModes
        setenv("MADEIRA_EXTENDED_MODES", extended ? "1" : "0", 1)
        if extended != extendedModes { LogStore.shared.log("[display-modes] ml1520 stored extended modes ignored") }
        setenv("DXMT_D9_ANISO_LIMIT", String(anisotropyLimit ?? 0), 1)
        GuestDisplay.configureSessionDefault(view: CGSize(width: 1280, height: 720), knob: resolution)
        madeira_set_vsync_locked(Int32(fpsMode))
        fputs("[frontend] ml1140 launch profile applied\n", stderr)
        LogStore.shared.log("[display-shape] ml1340 resolution=\(resolution) mode=\(display)")
    }
    func configureLaunch(dock: Bool? = nil) {
        let useDock = dock ?? MadeiraDock.routes(self)
        MadeiraDock.configure(self, dock: useDock)
        setenv("MADEIRA_EXE", desktop == true || usesSteam ? "explorer.exe" : windowsPath, 1)
        setenv("MADEIRA_ARGS", launchArguments(dock: useDock), 1)
        if desktop == true || usesSteam { setenv("MADEIRA_DESKTOP", "1", 1) } else { unsetenv("MADEIRA_DESKTOP") }
        // ml1470: the Steam client trades messages with its Chromium helper, which FEX can run
        // with stricter ordering (found by its libcef.dll); the client can get the same, and the
        // games it starts keep the default.
        // ml1490: OFF by default. The startup error it was aimed at was a dropped I/O completion
        // (fixed in the server, ml1480), and the profile costs the client and its helper CPU the
        // game needs (device log 193: the helper's renderer and the client's engine thread were a
        // quarter of all samples during play). MADEIRA_ORDERED_PROFILE=1 in madeira-env.txt turns
        // it back on for Chromium hosts, plus MADEIRA_STEAM_ORDERED_CLIENT=1 for the client.
        let ordered = LibraryFlags.enabled("MADEIRA_ORDERED_PROFILE", fallback: false)
        setenv("MADEIRA_ORDERED_PROFILE", ordered ? "1" : "0", 1)
        let client = steamClientWindowsPath.split(separator: "\\").last.map(String.init) ?? ""
        if ordered, usesSteam, !client.isEmpty, LibraryFlags.enabled("MADEIRA_STEAM_ORDERED_CLIENT", fallback: false) {
            setenv("MADEIRA_ORDERED_PROFILE_CLIENT", client, 1)
            LogStore.shared.log("[ordered-profile] ml1470 Steam client \(client) gets the stricter ordering")
        } else {
            unsetenv("MADEIRA_ORDERED_PROFILE_CLIENT")
        }
        // ml1500: every guest thread runs at the highest iOS class (USER_INTERACTIVE), so the
        // client's ~100 threads competed with the game for the performance cores (device log 194:
        // helper renderer and the client's engine thread ~25 % of samples during play). ntdll now
        // takes a per-program class from these lists ([thread-qos]); the client's helpers and
        // background tools run at UTILITY, the client itself at DEFAULT, and the game keeps
        // USER_INTERACTIVE. MADEIRA_STEAM_BACKGROUND_QOS=0 leaves every thread interactive.
        if usesSteam, !client.isEmpty, LibraryFlags.enabled("MADEIRA_STEAM_BACKGROUND_QOS") {
            setenv("MADEIRA_QOS_UTILITY_EXES", Self.steamBackgroundImages.joined(separator: ";"), 1)
            setenv("MADEIRA_QOS_DEFAULT_EXES", client, 1)
            // ml1530: the web helper stays alive while the game runs (ending it froze the game,
            // logs 199/200) but drops to BACKGROUND, the lowest class, so it only gets spare
            // cycles. MADEIRA_STEAM_HELPER_BACKGROUND=0 keeps it at UTILITY.
            if LibraryFlags.enabled("MADEIRA_STEAM_HELPER_BACKGROUND") {
                setenv("MADEIRA_QOS_BACKGROUND_EXES", "steamwebhelper.exe", 1)
            } else {
                unsetenv("MADEIRA_QOS_BACKGROUND_EXES")
            }
        } else {
            unsetenv("MADEIRA_QOS_UTILITY_EXES"); unsetenv("MADEIRA_QOS_DEFAULT_EXES"); unsetenv("MADEIRA_QOS_BACKGROUND_EXES")
        }
        // ml1560: console programs of a Steam session get consoles without windows (kernelbase,
        // [console-headless]). Device log 204: the keep-alive cmd.exe's and the web helper's
        // console windows sat on top of Steam's sign-in window and took every tap on it.
        // MADEIRA_STEAM_HEADLESS_CONSOLES=0 shows those console windows again.
        if usesSteam, LibraryFlags.enabled("MADEIRA_STEAM_HEADLESS_CONSOLES") {
            setenv("MADEIRA_HEADLESS_CONSOLE_EXES", "cmd.exe;steamwebhelper.exe;steamservice.exe;steam.exe;steamerrorreporter.exe", 1)
        } else {
            unsetenv("MADEIRA_HEADLESS_CONSOLE_EXES")
        }
        // ml1520: the client's web helper (its UI browser) ends 10 s after the game's window
        // appears and may not restart until the session ends; the client keeps the game's
        // connection itself. Device log 196: the helper's renderer alone was 16 % of all CPU
        // during play. ntdll does it ([park], signal_arm64_ios.c) and the client's own thread
        // gives the helper's memory back. MADEIRA_STEAM_WEBHELPER_STOP=0 keeps the helper running.
        // ml1530: OPT-IN (=1). Device logs 199/200: the game stopped presenting 10-20 s after the
        // helper ended, main thread in a wait nothing signals; with the helper alive (log 196) it
        // ran for minutes. The helper's threads also never exited, so its memory stayed anyway.
        // ml1790: MADEIRA_STEAM_WEBHELPER_FREEZE=1 (opt-in experiment) holds the helper's threads
        // at their next wait instead of ending it (ntdll [park] ml1790), from 10 s after the
        // game's window until the session ends: no helper CPU, and the client never sees it exit.
        // ml1800: ON by default (owner: keep the real client, make it as quiet as possible while
        // the game plays); the watchdog in LibraryModel.watchFrozenHelper thaws it if the game
        // stops presenting. MADEIRA_STEAM_WEBHELPER_FREEZE=0 keeps the helper running.
        unsetenv("MADEIRA_PARK_MODE")
        if usesSteam, !client.isEmpty, LibraryFlags.enabled("MADEIRA_STEAM_WEBHELPER_FREEZE") {
            setenv("MADEIRA_PARK_EXES", "steamwebhelper.exe", 1)
            setenv("MADEIRA_PARK_MODE", "freeze", 1)
            unsetenv("MADEIRA_PARK_OWNER_EXES")
            LogStore.shared.log("[park] ml1790 Steam's web helper freezes while the game runs")
        } else if usesSteam, !client.isEmpty, LibraryFlags.enabled("MADEIRA_STEAM_WEBHELPER_STOP", fallback: false) {
            setenv("MADEIRA_PARK_EXES", "steamwebhelper.exe", 1)
            setenv("MADEIRA_PARK_OWNER_EXES", client, 1)
        } else {
            unsetenv("MADEIRA_PARK_EXES"); unsetenv("MADEIRA_PARK_OWNER_EXES")
        }
        // ml1490: the store identity of a game started directly, for the Steam
        // environment WineProcessBridge publishes ([steam-env]). A client-routed
        // or desktop launch gets none: the client sets it for the games it starts.
        if desktop != true && !usesSteam, let id = steamAppID, SteamPaths.validAppID(id) {
            setenv("MADEIRA_STEAM_APPID", String(id), 1)
        } else {
            unsetenv("MADEIRA_STEAM_APPID")
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
    /// ml1970: asks the library to close a details page held open during a launch.
    @Published var closeDetail = 0
    @Published var sessionMessage = ""
    @Published var launching = false
    @Published var overlayFields = ["FPS", "Frame time", "RAM", "Battery"]
    private var launchPresent: UInt64 = 0
    private var launchSurface: UInt64 = 0
    private var launchStarted = Date()
    /// ml1510: read by the starting screen for its elapsed-time line.
    var launchStartedAt: Date { launchStarted }
    @Published var launchSlow = false
    @Published var launchLogs = false
    @Published private(set) var dockLaunching = false
    @Published private(set) var dockLaunchFailure: String?
    private var dockExitObserved = false
    private var launchDismissLogged = false
    /// ml1490: a game started through the Windows Steam client keeps the
    /// starting screen over the Wine desktop until the game's window is up.
    private var steamHold: SteamLaunchHold?
    private var steamSceneLines = 0
    /// The starting screen offers "Show Steam".
    @Published private(set) var steamHolding = false
    /// A Steam client window is up behind the starting screen.
    @Published private(set) var steamAttention = false
    var menuButtonRect = CGRect.zero
    var performanceRect = CGRect.zero
    /// ml1570: setup's "Tap when Steam is installed" button over a running session (window points).
    var finishButtonRect = CGRect.zero
    private let modalTouchGuard = LibraryFlags.enabled("MADEIRA_MODAL_TOUCH_GUARD")
    var blocksGameplayTouch: Bool { modalTouchGuard && current != nil && (menu || launching) }
    private var timer: Timer?
    private var sawProcess = false
    // ml2000: why a session ended by itself (not Quit): the pool ran dry or the game
    // exited with a Windows error. MADEIRA_EXIT_REPORT=0 returns without a message.
    private var quitRequested = false
    private var pressureAtStart = false
    private var programsGoneSince: Date?
    private var dockSessionEnding = false
    /// ml2000: a Dock session keeps its desktop after Madeira Dock exits, so a game that
    /// ended (or crashed) left the library behind its last frame. Once the Dock host has
    /// exited and every program started in this session has ended for 5 s, end the
    /// session like Quit, keeping the exit report. MADEIRA_DOCK_END_WITH_GAME=0 keeps it.
    private func endDockSessionAfterGame() {
        guard dockLaunching, dockExitObserved, dockLaunchFailure == nil, !quitRequested, !dockSessionEnding,
              LibraryFlags.enabled("MADEIRA_DOCK_END_WITH_GAME"), wine_programs_started() > 0 else { return }
        guard wine_programs_live() == 0 else { programsGoneSince = nil; return }
        let since = programsGoneSince ?? Date()
        programsGoneSince = since
        guard Date().timeIntervalSince(since) >= 5 else { return }
        dockSessionEnding = true
        LogStore.shared.log("[dock-session] ml2000 programs=\(wine_programs_started()) all ended; ending the session")
        if wineserver_request_session_stop() != 0 { sessionMessage = "Game ended. Closing…"; menu = false }
    }
    private func exitReport() -> String? {
        guard !quitRequested, LibraryFlags.enabled("MADEIRA_EXIT_REPORT") else { return nil }
        if !pressureAtStart && StikJITHelper.poolPressureRecorded {
            LogStore.shared.log("[exit-report] ml2000 pool=dry")
            return "This game needed more code memory than Madeira reserved when it opened. Close Madeira in the app switcher and open it again; it reserves more from then on."
        }
        var status: UInt32 = 0
        guard wine_crash_exit_status(&status) != 0 else { return nil }
        LogStore.shared.log("[exit-report] ml2000 status=0x\(String(status, radix: 16))")
        let kind = status == 0xC0000005 ? " (memory access violation)" : status == 0xC0000017 ? " (out of memory)" : ""
        return "The game stopped with Windows error 0x\(String(status, radix: 16, uppercase: true))\(kind). Export the diagnostic log from Settings to report it."
    }
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
        // ml1520: fixed for the whole run (FrontendChoice); a change applies at the next start.
        let allowed = FrontendChoice.startup.useNew
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
            // ml1490: a redistributable's installer chosen before the filter is not kept.
            let installer = LibraryFlags.enabled("MADEIRA_STEAM_EXE_FILTER") &&
                SteamExecutableRules.installerReason(executable: entry.relativePath, installFolder: entry.steamInstallPath) != nil
            let keepExecutable = entry.steamNative == true && (try? Self.executable(entry.relativePath)) != nil && !installer
            if !keepExecutable {
                entry.relativePath = installed.relativePath; entry.bits = installed.bits; entry.arguments = installed.arguments
                entry.steamDefaultArguments = installed.steamDefaultArguments
            } else if entry.relativePath.caseInsensitiveCompare(installed.relativePath) == .orderedSame && entry.arguments == installed.arguments {
                entry.steamDefaultArguments = installed.steamDefaultArguments
            }
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

    func begin(_ entry: LibraryEntry, dock: Bool = false) {
        dockLaunching = dock
        dockLaunchFailure = nil; dockExitObserved = false
        wine_dock_exit_reset()
        quitRequested = false; pressureAtStart = StikJITHelper.poolPressureRecorded   // ml2000
        programsGoneSince = nil; dockSessionEnding = false; wine_programs_reset()
        LibraryController.shared.configure(enabled: enabled, ownsInput: false)
        Self.sessionsThisRun += 1   // ml1790
        launchPresent = madeira_get_present_count(); launchStarted = Date(); launchSlow = false; launchLogs = entry.liveLogs
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
        HardwareInput.shared.reservePadSlotForSession(touchControls: entry.touchControls)   // ml1990
        // ml1970: remember the game's layout; a game that never had one starts on Xbox.
        // MADEIRA_CONTROLS_XBOX_DEFAULT=0 keeps the shared layout instead.
        if ControlPresetsModel.enabled {
            let presets = ControlPresetsModel.shared
            presets.setActive(entry.controlLayout)
            if entry.controls == nil, entry.controlLayout == nil, LibraryFlags.enabled("MADEIRA_CONTROLS_XBOX_DEFAULT") {
                presets.load(ControlPresetLayout.xboxID, screen: ControlPresetsModel.currentScreen())
            }
        }
        InputSettings.shared.displayMode = DisplayMode(rawValue: entry.display) ?? .fit
        FullscreenState.shared.active = true
        MetalHostView.shared.isHidden = false
        ProMotionIntent.shared.setActive(true, maxHz: ProMotionIntent.maxHz(for: Int32(entry.fpsMode)))
        if entry.steamSession == nil {
            var played = entry; played.lastPlayed = Date()
            // ml1530: a start mode taken from the default (LibraryDetail.start) is not stored as a choice.
            if let stored = entries.first(where: { $0.id == entry.id }), stored.steamClientLaunch == nil { played.steamClientLaunch = nil }
            save(played)
        }
        if entry.usesSteam { fputs("[steam-bridge] ml1260 session=\(entry.steamSession ?? "app") appid=\(entry.steamAppID ?? 0) desktop=1\n", stderr) }
        // ml1420: what the Windows Steam client downloads before the game starts.
        SteamClientProgressModel.shared.start(entry)
        launchDismissLogged = false
        beginSteamHold(entry)
        sawProcess = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        if dockLaunching && !dockExitObserved && LibraryFlags.enabled("MADEIRA_DOCK_STATUS") {
            var status: Int32 = 0
            let ended = wine_dock_exit_status(&status) != 0
            let report = MainActor.assumeIsolated { MadeiraDock.pollReport(force: ended) }
            if ended || report.result != nil {
                dockExitObserved = true
                if !ended { status = Int32(report.result ?? 0) }
                if launching || status != 0 {
                    dockLaunchFailure = report.failure ?? "Madeira Dock exited before a game window appeared. Export the diagnostic log."
                    LogStore.shared.log("[dock-status] ml1860 host-ended status=\(status) native=\(ended ? 1 : 0) starting=\(launching ? 1 : 0)", level: .error)
                    MainActor.assumeIsolated { MadeiraDock.cleanup() }
                }
            }
        }
        endDockSessionAfterGame()
        if steamHold != nil {
            // ml1490: the desktop's own frames (the client's console and helper
            // windows) do not end this starting screen; the game's window does.
            pollSteamHold()
            if launching && !launchSlow && Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        } else if launching {
            if madeira_get_present_count() >= launchPresent + 3 {
                showGameView(reason: "present")
            } else if winios_surface_present_count() > launchSurface {
                showGameView(reason: "surface")
            } else if Date().timeIntervalSince(launchStarted) > 30 { launchSlow = true }
        }
        watchFrozenHelper()
        if wine_process_is_running() != 0 {
            sawProcess = true
            if sessionMessage == "Starting…" { sessionMessage = "" }
        } else if sawProcess && wineserver_is_running() == 0 { finish() }
    }

    /// ml1800: while Steam's web helper is frozen (ntdll [park], MADEIRA_PARK_MODE=freeze), a game
    /// that presents no frame for 6 s with Madeira in front gets the helper back: ending the helper
    /// once left games waiting on the client (logs 199/200), and a freeze could do the same.
    /// MADEIRA_STEAM_FREEZE_WATCHDOG=0 leaves the helper frozen whatever happens.
    private func watchFrozenHelper() {
        guard !frozenThawed, madeira_park_frozen() > 0, UIApplication.shared.applicationState == .active else {
            frozenWatchCount = nil; return
        }
        // D3D presents plus desktop-surface frames: a game that draws either way counts.
        let count = madeira_get_present_count() &+ UInt64(winios_surface_present_count()), now = Date()
        if count != frozenWatchCount { frozenWatchCount = count; frozenWatchSince = now; return }
        guard now.timeIntervalSince(frozenWatchSince) >= 6, LibraryFlags.enabled("MADEIRA_STEAM_FREEZE_WATCHDOG") else { return }
        frozenThawed = true
        LogStore.shared.log("[park] ml1800 watchdog: no frame for 6 s with \(madeira_park_frozen()) helper thread(s) frozen; thawing", level: .error)
        madeira_park_thaw()
    }
    private var frozenWatchCount: UInt64?
    private var frozenWatchSince = Date()
    private var frozenThawed = false
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
        LogStore.shared.setDisplayActive(liveLogs)
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
        LogStore.shared.setDisplayActive(launching ? launchLogs : liveLogs)
        fputs("[startup-log] ml1180 visible=\(launchLogs ? 1 : 0)\n", stderr)
    }

    // MARK: ml1490 — starting screen over the Windows Steam client

    /// A game started through the Windows Steam client is a desktop session, and
    /// the desktop's first frame (the client's console and helper windows) used
    /// to end the starting screen. Now it stays, with the client's download
    /// progress, until a window of the started game is up; a client window the
    /// user may have to answer (sign-in, an error) reveals the desktop, and
    /// "Show Steam" reveals it on request. Which window is which comes from
    /// Winios.m's census (owning program per top-level window), decided by
    /// SteamLaunchScene. MADEIRA_STEAM_HIDE_DESKTOP=0 restores the old
    /// behaviour; MADEIRA_STEAM_AUTO_REVEAL=0 keeps only the button.
    /// [steam-launch-view] ml1490 logs the hold, scene changes and reveals.
    private func beginSteamHold(_ entry: LibraryEntry) {
        endSteamHold(reason: nil)
        guard entry.steamGameLaunch, LibraryFlags.enabled("MADEIRA_STEAM_HIDE_DESKTOP") else { return }
        let hold = SteamLaunchHold(autoReveal: LibraryFlags.enabled("MADEIRA_STEAM_AUTO_REVEAL"))
        steamHold = hold; steamSceneLines = 0; steamHolding = true
        winios_window_census_enable(1)
        LogStore.shared.log("[steam-launch-view] ml1490 hold app=\(entry.steamAppID ?? 0) auto-reveal=\(hold.autoReveal ? 1 : 0)")
    }

    private func endSteamHold(reason: String?) {
        guard steamHold != nil || steamHolding else { return }
        if let reason, let hold = steamHold {
            LogStore.shared.log("[steam-launch-view] ml1490 end reason=\(reason) scene=\(hold.scene.name) revealed=\(hold.revealed ? 1 : 0) t=\(Int(Date().timeIntervalSince(launchStarted)))s")
        }
        steamHold = nil
        steamHolding = false; steamAttention = false
        winios_window_census_enable(0)
    }

    /// Winios.m's census as SteamLaunchScene reads it.
    private static func censusWindows() -> [SteamLaunchWindow] {
        var raw = [winios_census_window](repeating: winios_census_window(), count: Int(WINIOS_CENSUS_MAX))
        let count = Int(winios_window_census(&raw, Int32(raw.count)))
        return raw.prefix(max(0, min(count, raw.count))).map { window in
            let image = withUnsafeBytes(of: window.image) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return SteamLaunchWindow(image: image, width: Int(window.w), height: Int(window.h), visible: window.visible != 0,
                                     drawn: window.presents > 0 || window.metal != 0, pid: window.pid)
        }
    }

    private func pollSteamHold() {
        guard var hold = steamHold else { return }
        let elapsed = Date().timeIntervalSince(launchStarted)
        let windows = Self.censusWindows()
        // D3D frames stand in only for a window whose owner could not be read.
        let decision = SteamLaunchScene.decide(windows, rendered: madeira_get_present_count() >= launchPresent + 3)
        if decision.scene != hold.scene, steamSceneLines < 24 {
            steamSceneLines += 1
            let window = decision.window.map { " window=\($0.width)x\($0.height) owner=\(SteamLaunchScene.owner($0.image).rawValue) pid=\(String($0.pid, radix: 16))" } ?? ""
            LogStore.shared.log("[steam-launch-view] ml1490 scene=\(decision.scene.name) shown=\(windows.filter(\.visible).count)\(window) t=\(Int(elapsed))s")
        }
        let action = hold.step(decision.scene, now: elapsed)
        steamHold = hold
        switch action {
        case .none:
            break
        case .showGame:
            endSteamHold(reason: "game-window")
            // ml1510: the client can now yield the performance cores to the game.
            madeira_set_background_qos(1)
            if launching { showGameView(reason: "game-window") }
            return
        case .reveal:
            LogStore.shared.log("[steam-launch-view] ml1490 reveal reason=steam-window count=\(hold.autoReveals) t=\(Int(elapsed))s")
            if launching { showGameView(reason: "steam-window") }
        case .cover:
            // The client window was answered; back to the starting screen.
            LogStore.shared.log("[steam-launch-view] ml1490 cover reason=steam-window-closed t=\(Int(elapsed))s")
            InputGuard.shared.releaseAll("steam-launch-cover")
            LibraryKeyboard.hide(); menu = false
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { launching = true }
        }
        if steamAttention != hold.needsAttention { steamAttention = hold.needsAttention }
    }

    /// "Show Steam" on the starting screen: the desktop stays until the game's window is up.
    func showSteam() {
        guard var hold = steamHold else { return }
        // ml1530: tapped before the client has a window, the hold remembers it and reveals the
        // window when it appears. MADEIRA_STEAM_SHOW_WAITS=0 shows the desktop at once as before.
        // ml1720: shows the desktop at once, every time: a tap that only queued a reveal read as a
        // dead button (device logs: dozens of taps, nothing on screen). MADEIRA_STEAM_SHOW_WAITS=1
        // waits for the client's window as ml1530 did.
        let now = hold.showSteam(waitForWindow: LibraryFlags.enabled("MADEIRA_STEAM_SHOW_WAITS", fallback: false))
        steamHold = hold
        guard now else {
            if hold.pendingReveal {
                LogStore.shared.log("[steam-launch-view] ml1530 show-steam waits for the client's window t=\(Int(Date().timeIntervalSince(launchStarted)))s")
            }
            return
        }
        steamAttention = false
        LogStore.shared.log("[steam-launch-view] ml1490 reveal reason=button scene=\(hold.scene.name) t=\(Int(Date().timeIntervalSince(launchStarted)))s")
        showGameView(reason: "show-steam")
    }
    // MARK: ml1780 Steam's one-time installs

    /// The game's install folder: the recorded one, else the steamapps/common/<dir> its
    /// executable is in.
    static func steamInstallFolder(_ entry: LibraryEntry) -> URL? {
        if let path = entry.steamInstallPath, let folder = SteamPaths.safeRelative(path, under: drive) { return folder }
        let parts = entry.relativePath.split(separator: "/").map(String.init)
        guard let common = parts.lastIndex(where: { $0.lowercased() == "common" }), common + 1 < parts.count - 1 else { return nil }
        return SteamPaths.safeRelative(parts[...(common + 1)].joined(separator: "/"), under: drive)
    }

    /// Marks the game's one-time installs done in the prefix's registry; only while no
    /// session runs. Returns the number of install entries found (0: no install script).
    @discardableResult
    static func markSteamInstallers(_ entry: LibraryEntry, reason: String) -> Int {
        let app = entry.steamAppID ?? 0
        guard let folder = steamInstallFolder(entry) else {
            LogStore.shared.log("[steam-installers] ml1780 app=\(app) reason=\(reason) no install folder"); return 0
        }
        let runs = SteamInstallScripts.runs(installFolder: folder)
        var written = 0
        do { written = try SteamInstallScripts.mark(runs, prefix: drive.deletingLastPathComponent()) }
        catch { LogStore.shared.log("[steam-installers] ml1780 app=\(app) write failed: \(error.localizedDescription)", level: .error) }
        LogStore.shared.log("[steam-installers] ml1780 app=\(app) reason=\(reason) entries=\(runs.count) names=\(runs.map(\.name).joined(separator: ",")) written=\(written)")
        return runs.count
    }

    /// ml1970: a Madeira Dock start. Valve's client never evaluates install scripts on this route
    /// (see DockInstallScripts), so Madeira does: runtimes its Wine provides are marked done, and
    /// the other programs not yet recorded done go into a batch the session runs before the host.
    /// "Run Steam's one-time installs" (steamRunInstallers) also queues the provided ones.
    /// Only while no session runs. MADEIRA_DOCK_INSTALLERS=0 restores ml1780's marking.
    static func prepareDockInstallers(_ entry: LibraryEntry) {
        MadeiraDock.installerScript = nil
        let app = entry.steamAppID ?? 0
        let batchURL = drive.appendingPathComponent(MadeiraDock.installerScriptName)
        try? FileManager.default.removeItem(at: batchURL)
        guard let folder = steamInstallFolder(entry), let gameRelative = SteamPaths.relative(folder, drive: drive) else {
            LogStore.shared.log("[dock-installers] ml1970 app=\(app) no install folder"); return
        }
        func windows(_ relative: String) -> String { "C:\\" + relative.replacingOccurrences(of: "/", with: "\\") }
        let shared = folder.deletingLastPathComponent().appendingPathComponent("Steamworks Shared", isDirectory: true)
        var found: [SteamInstallProcess] = []
        var roots: [(URL, Int, String)] = [(folder, 1, windows(gameRelative))]
        if let sharedRelative = SteamPaths.relative(shared, drive: drive) {
            roots.append((shared.appendingPathComponent("_CommonRedist", isDirectory: true), 3, windows(sharedRelative)))
        }
        for (root, depth, installDir) in roots {
            for file in SteamInstallScripts.scripts(folder: root, depth: depth) {
                guard let data = try? Data(contentsOf: file) else { continue }
                for process in DockInstallScripts.processes(script: data, installDir: installDir) where !found.contains(process) {
                    found.append(process)
                }
            }
        }
        let runAll = entry.steamRunInstallers == true
        let prefix = drive.deletingLastPathComponent()
        let registry = [SteamInstallRun.Hive.machine: "system.reg", .user: "user.reg"].mapValues {
            (try? String(contentsOf: prefix.appendingPathComponent($0), encoding: .utf8)) ?? ""
        }
        func done(_ run: SteamInstallRun) -> Bool { DockInstallScripts.marked(run, in: registry[run.hive] ?? "") }
        func exists(_ windowsPath: String) -> Bool {
            let relative = windowsPath.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
            guard let url = SteamPaths.safeRelative(relative, under: drive) else { return false }
            return SteamPaths.existing(url, drive: drive) != nil
        }
        // A run is marked done up front only when every program in it is provided by Madeira.
        var provided: [SteamInstallRun] = []
        for process in found where !runAll && !provided.contains(process.run) {
            if found.filter({ $0.run == process.run }).allSatisfy(DockInstallScripts.providedByMadeira) { provided.append(process.run) }
        }
        var written = 0
        do { written = try SteamInstallScripts.mark(provided, prefix: prefix) }
        catch { LogStore.shared.log("[dock-installers] ml1970 app=\(app) mark failed: \(error.localizedDescription)", level: .error) }
        let pending = found.filter { !provided.contains($0.run) && !done($0.run) && exists($0.executable) }.prefix(8)
        if !pending.isEmpty {
            do {
                try Data(DockInstallScripts.batch(Array(pending)).utf8).write(to: batchURL, options: .atomic)
                MadeiraDock.installerScript = "C:\\" + MadeiraDock.installerScriptName
            } catch {
                LogStore.shared.log("[dock-installers] ml1970 app=\(app) batch write failed: \(error.localizedDescription)", level: .error)
            }
        }
        LogStore.shared.log("[dock-installers] ml1970 app=\(app) programs=\(found.count) provided=\(provided.count) marked=\(written) " +
                            "pending=\(pending.count) run-all=\(runAll ? 1 : 0) names=\(pending.map(\.run.name).joined(separator: ","))")
    }

    /// Set by "Skip one-time installs": the library marks the installs once the session has ended.
    @Published var relaunchRequest: LibraryEntry?
    @Published private(set) var skippingInstallers = false

    /// ml1790: Wine sessions started in this app run. A second one cannot start in the same
    /// process: the wineserver's permanent objects from the first session are still there and
    /// init_registry aborts on "\Registry" (device log 52, `Assertion failed: (root_key)`; no
    /// log has ever shown a second session start). Madeira asks for a restart instead.
    /// MADEIRA_ONE_SESSION_PER_RUN=0 lets the launch go ahead as before.
    static var sessionsThisRun = 0
    static let restartMessage = "Restart Madeira to start another game: swipe Madeira away in the app switcher, then open it again."
    @Published var restartNotice: String?

    /// "Skip one-time installs" on the starting screen: ends the session; once it has ended the
    /// installs are marked done (the registry can only be written between sessions) and
    /// Madeira asks for a restart, after which Play starts without them.
    func skipSteamInstallers() {
        guard var entry = activeEntry, entry.steamGameLaunch, !skippingInstallers else { return }
        guard let folder = Self.steamInstallFolder(entry), !SteamInstallScripts.runs(installFolder: folder).isEmpty else {
            LogStore.shared.log("[steam-installers] ml1780 skip tapped but no install script was found app=\(entry.steamAppID ?? 0)")
            sessionMessage = "Madeira could not find this game's install script. Use Show Steam to answer its installers."
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.sessionMessage = "" }
            return
        }
        if var stored = entries.first(where: { $0.id == entry.id }), stored.steamRunInstallers == true {
            stored.steamRunInstallers = nil; save(stored)
        }
        entry.steamRunInstallers = nil
        skippingInstallers = true
        pendingRelaunch = entry
        LogStore.shared.log("[steam-installers] ml1790 skip tapped app=\(entry.steamAppID ?? 0) t=\(Int(Date().timeIntervalSince(launchStarted)))s; ending the session")
        requestQuit()
        sessionMessage = "Closing Steam to skip the one-time installs…"
    }
    private var pendingRelaunch: LibraryEntry?

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
        quitRequested = true
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
            if ControlPresetsModel.enabled { entry.controlLayout = ControlPresetsModel.shared.activeID }
            entry.fpsMode = fpsMode; entry.performance = performance
            if LibraryFlags.enabled("MADEIRA_SESSION_TOOLS") { entry.display = InputSettings.shared.displayMode.rawValue }
            entry.overlayFields = overlayFields; save(entry)
        }
    }
    private func finish() {
        // The legacy timer/session callbacks run on the main queue. Keep the
        // credential-file lifecycle in that same isolation domain.
        let dockError = MainActor.assumeIsolated {
            let message = dockLaunching ? MadeiraDock.finishReport() : nil
            MadeiraDock.cleanup()
            return message
        }
        if let dockError { error = dockError } else if sawProcess, let report = exitReport() { error = report }
        dockLaunching = false
        timer?.invalidate(); timer = nil
        SteamClientProgressModel.shared.stop()
        endSteamHold(reason: "session-ended")
        madeira_set_background_qos(0)   // ml1510
        saveCurrentProfile()
        let controls = TouchControlsModel.shared
        InputGuard.shared.releaseAll("frontend-exit")
        controls.controls = savedControls; controls.visible = savedVisible; controls.sizeScale = savedSize
        HardwareInput.shared.releaseReservedPadSlot()   // ml1990
        InputSettings.shared.displayMode = savedDisplay
        current = nil; activeEntry = nil; menu = false; sessionMessage = ""
        LogStore.shared.setDisplayActive(true)
        launching = false; launchLogs = false; LibraryKeyboard.hide()
        LibraryController.shared.configure(enabled: enabled, ownsInput: enabled)
        FullscreenState.shared.active = false; MetalHostView.shared.isHidden = true
        ProMotionIntent.shared.setActive(false)
        skippingInstallers = false
        if let entry = pendingRelaunch { pendingRelaunch = nil; relaunchRequest = entry }   // ml1780
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
                if LibraryFlags.enabled("MADEIRA_STEAM_ARTWORK") {
                    SteamArtworkImage(id: id, backdrop: backdrop)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
                } else {
                    AsyncImage(url: backdrop ? URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/library_hero.jpg") : SteamCatalog.cover(id)) { image in
                        image.resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center).clipped()
                    } placeholder: { Color.clear }
                }
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
            // ml1780: MADEIRA_API_BADGE_STRICT=0 shows the highest API found again.
            if let api = LibraryFlags.enabled("MADEIRA_COMPACT_API_BADGE")
                ? LibraryRendererBadge.compact(entry.graphicsAPI, strict: LibraryFlags.enabled("MADEIRA_API_BADGE_STRICT")) : entry.graphicsAPI { badge(api) }
            // ml1970: no "Steam" pill on installed games (MADEIRA_STEAM_BADGE=1 restores it).
            if entry.steamAppID != nil, entry.steamInstalled == false || LibraryFlags.enabled("MADEIRA_STEAM_BADGE", fallback: false) {
                badge(entry.steamInstalled == false ? "Not installed" : "Steam")
            }
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
    // ml1520: the interface the next start uses (FrontendChoice).
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false
    @AppStorage("madeiraLibraryLayout") private var layout = "cards"
    @AppStorage("madeiraLibrarySort") private var sort = "played"
    private let refinements = LibraryFlags.enabled("MADEIRA_LIBRARY_REFINEMENTS")
    private let layoutsEnabled = LibraryFlags.enabled("MADEIRA_LIBRARY_LAYOUTS")
    // ml1310: Steam / other-games sections and native Steam account.
    @ObservedObject private var steam = SteamAccountModel.shared
    @State private var steamSignIn = false
    @State private var steamGame: SteamGameRef?
    @AppStorage("madeiraSteamShowUninstalled") private var showUninstalled = true
    // ml1990: collapsed state of the installed Steam and Other games sections.
    @AppStorage("madeiraLibraryHideInstalled") private var hideInstalled = false
    @AppStorage("madeiraLibraryHideOthers") private var hideOthers = false
    private let collapsibleSections = LibraryFlags.enabled("MADEIRA_LIBRARY_COLLAPSE")
    private let nativeSteam = SteamAccountModel.enabled
    private let sectioned = SteamAccountModel.enabled && LibraryFlags.enabled("MADEIRA_LIBRARY_SECTIONS")
    // ml1530: first-run setup (Onboarding.swift) and the Windows Steam client's button.
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var steamClient = SteamLibraryModel.shared
    // ml1970: hidden by default now that Madeira Dock starts games; regular Steam stays in
    // Settings › Windows Steam client. MADEIRA_LIBRARY_STEAM_BUTTON=1 shows it again.
    private let steamButton = LibraryFlags.enabled("MADEIRA_STEAM") && LibraryFlags.enabled("MADEIRA_LIBRARY_STEAM_BUTTON", fallback: false)
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
        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView(play: play, enableJIT: enableJIT) }
        .onAppear {
            // ml1530: an ended desktop session's surface never stays over the library.
            EndedSessionSurface.install(); EndedSessionSurface.hide(reason: "library-appeared")
            onboarding.presentIfNeeded()
        }
        .task { await SteamLibraryModel.shared.refresh() }
        .task { steam.start() }
        .onChange(of: model.current) { _, current in
            guard current == nil else { steam.sessionChanged(active: true); return }
            Task {
                // ml1530: a Steam folder set aside for the installer returns before downloads resume into it.
                await SteamLibraryModel.shared.restorePendingInstallFolder()
                steam.sessionChanged(active: false)
                await SteamLibraryModel.shared.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await SteamLibraryModel.shared.refresh() } } }
        .onAppear { fputs("[steam-bridge] ml1260 enabled=\(LibraryFlags.enabled("MADEIRA_STEAM") ? 1 : 0) compact-badges=\(LibraryFlags.enabled("MADEIRA_COMPACT_API_BADGE") ? 1 : 0)\n", stderr) }
        .onAppear { fputs("[frontend-layout] ml1190 full-height native tab symbols and metadata=\(refinements ? 1 : 0)\n", stderr) }
        // LogStore: stderr is not captured before a Wine session starts.
        .onAppear { LogStore.shared.log("[library-sections] ml1310 native-steam=\(nativeSteam ? 1 : 0) sections=\(sectioned ? 1 : 0)") }
        .onAppear { LogStore.shared.log("[ui-details] ml1520 Steam start choice under library details; no display-modes toggle") }
        .onReceive(controller.commands) { command in
            if selected == nil, !browser, !steamManager, !steamSignIn, steamGame == nil, !onboarding.presented, command == "tab" { tab = 1 - tab }
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
            }
            // ml1530: reopens the first-run setup (MADEIRA_ONBOARDING=0 hides it).
            if OnboardingModel.enabled {
                Section {
                    Button { onboarding.rerun() } label: { Label("Run setup again", systemImage: "wand.and.stars") }
                } footer: {
                    Text("Walks you through installing Steam for Windows and signing in to Steam.")
                }
            }
            Section {
                Toggle("Use developer interface", isOn: Binding(get: { developerUI }, set: { on in
                    developerUI = on; FrontendChoice.choose(new: !on); restartNotice = true
                }))
            } header: { Text("Interface") } footer: {
                Text("The developer interface is Madeira's original diagnostic screen. The change applies after Madeira restarts.")
            }
        }
        .alert("Restart Madeira", isPresented: $restartNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Close Madeira from the app switcher and open it again to switch interfaces.")
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
                // ml1530: opens the installed Windows Steam client in the Wine desktop.
                // MADEIRA_LIBRARY_STEAM_BUTTON=0 hides it.
                if steamButton && nativeSteam, steamClient.snapshot.client != nil {
                    Button {
                        guard let entry = steamClient.clientEntry(bigPicture: false) else { return }
                        LogStore.shared.log("[library] ml1530 Steam button opens the client")
                        play(entry)
                    } label: {
                        Label("Steam", systemImage: "storefront").font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityHint("Opens Steam for Windows")
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
            guard tab == 0, selected == nil, !browser, !steamManager, !steamSignIn, steamGame == nil, !onboarding.presented else { return }
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
                            // ml1970: one short row per game, same details.
                            Label("Compact list", systemImage: "list.dash").tag("compactList")
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
            LibraryDetail(entry: entry, play: { profile in
                // ml1970: keep the details page up until the session's starting screen takes
                // over (or an error needs the library's alert), instead of showing the library
                // for the second or two a Dock start spends preparing. MADEIRA_DETAIL_HOLD=0.
                if LibraryFlags.enabled("MADEIRA_DETAIL_HOLD") {
                    play(profile)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if selected?.id == entry.id { selected = nil } }
                } else {
                    selected = nil; play(profile)
                }
            })
        }
        .onChange(of: model.current) { _, current in if current != nil { selected = nil } }
        .onChange(of: model.error) { _, error in if error != nil { selected = nil } }
        .onChange(of: model.restartNotice) { _, notice in if notice != nil { selected = nil } }
        .onChange(of: model.closeDetail) { _, _ in selected = nil }
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
            // ml1990: the installed Steam games and Other games collapse like Not installed.
            LibrarySectionHeader(title: "Steam", count: steamInstalled.count,
                                 collapsed: collapsibleSections ? $hideInstalled : nil) {
                if steam.refreshing { ProgressView().accessibilityLabel("Refreshing Steam library") }
            }
            if steam.phase == .signedOut { SteamSignInCard { steamSignIn = true } }
            if hideInstalled && collapsibleSections {
                EmptyView()
            } else if !owned.downloading.isEmpty || !steamInstalled.isEmpty {
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
            LibrarySectionHeader(title: "Other games", count: otherEntries.count,
                                 collapsed: collapsibleSections ? $hideOthers : nil) {
                Button { browser = true } label: { Label("Add a game", systemImage: "plus.circle") }.font(.subheadline)
            }
            if hideOthers && collapsibleSections {
                EmptyView()
            } else if otherEntries.isEmpty {
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
        if layoutsEnabled && (layout == "list" || layout == "compactList") {
            let dense = layout == "compactList"
            LazyVStack(spacing: dense ? 4 : 8) { ForEach(items) { item in cell(item, list: true, dense: dense) } }
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
    @ViewBuilder private func cell(_ item: Cell, list: Bool, dense: Bool = false) -> some View {
        switch item {
        case .entry(let entry): libraryItem(entry, list: list, dense: dense)
        case .owned(let game):
            Button { steamGame = SteamGameRef(id: game.id) } label: { SteamOwnedCell(game: game, list: list, dense: dense) }
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
    private func libraryItem(_ entry: LibraryEntry, list: Bool, dense: Bool = false) -> some View {
        // ml1970: Steam playtime and last played (SteamPlaytime), when Steam has any.
        let played = SteamAccountModel.playtimeEnabled ? entry.steamAppID.flatMap { steam.playtime[$0] } : nil
        return Button { selected = entry } label: {
            Group {
                if list && dense {
                    HStack(spacing: 10) {
                        LibraryArtwork(entry: entry).frame(width: 28, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let summary = played?.summary { Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 6)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary).fixedSize()
                    }.padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                } else if list {
                    HStack(spacing: 14) {
                        LibraryArtwork(entry: entry).frame(width: 48, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.headline).lineLimit(2); LibraryBadges(entry: entry).foregroundStyle(.secondary)
                            if let summary = played?.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        LibraryArtwork(entry: entry).aspectRatio(2.0 / 3.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        LibraryBadges(entry: entry).foregroundStyle(.secondary)
                        if let text = played?.played { Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
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
        // ml1530: without a stored choice, a native game starts through the Windows
        // Steam client when it is installed (MADEIRA_STEAM_DEFAULT_CLIENT); only the
        // launched profile carries the resolved mode, the saved entry keeps "no choice".
        let viaClient = entry.startsWithClient
        if entry.steamNative == true {
            // ml1310: an unfinished update mixes old and new files.
            if let appID = entry.steamAppID, SteamAccountModel.shared.downloads[appID] != nil {
                error = "This game's update has not finished. Resume it and wait for it to complete before playing."; return
            }
            if viaClient {
                entry.steamClientPath = SteamLibraryModel.shared.snapshot.client
            } else if (try? LibraryModel.executable(entry.relativePath)) == nil {
                error = "The game's files are missing. Uninstall it and install it again."; return
            }
            LogStore.shared.log("[steam-play] ml1310 app=\(entry.steamAppID ?? 0) mode=\(viaClient ? "client" : "direct") client-found=\(entry.steamClientPath == nil ? 0 : 1)")
            if entry.steamClientLaunch == nil { LogStore.shared.log("[steam-play] ml1530 default start mode=\(viaClient ? "client" : "direct")") }
            if viaClient {
                LogStore.shared.log("[steam-silent] ml1360 enabled=\(LibraryFlags.enabled("MADEIRA_STEAM_SILENT") ? 1 : 0)")
                if let appID = entry.steamAppID { SteamAccountModel.logInstallRecord(appID: appID) }
            }
        }
        leaving = true
        let stored = entry
        var profile = entry
        if entry.steamNative == true && entry.steamClientLaunch == nil { profile.steamClientLaunch = viaClient }
        fputs("[launch-feedback] ml1250 pending=1 polish=\(launchPolish ? 1 : 0)\n", stderr)
        // Give the pressed state a display turn before saving and handing off.
        DispatchQueue.main.asyncAfter(deadline: .now() + (launchPolish ? 0.12 : 0)) {
            model.save(stored); play(profile)
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
                            if SteamAccountModel.playtimeEnabled, let appID = entry.steamAppID,
                               let summary = SteamAccountModel.shared.playtime[appID]?.summary {
                                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                            }
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
                // ml1520: how the game starts sits near the top, under its library details.
                if entry.steamNative == true && SteamAccountModel.enabled {
                    SteamEntrySection(entry: $entry) {
                        leaving = true; SteamAccountModel.shared.uninstall(entry); dismiss()
                    }
                }
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
                }
                Section {
                    Toggle("Reduced-precision x87", isOn: $entry.reducedX87)
                    Toggle("Fast synchronization", isOn: $entry.fastSync)
                    Picker("CPU cores reported", selection: Binding(get: { entry.cpuCount ?? 0 }, set: { entry.cpuCount = $0 == 0 ? nil : $0 })) {
                        Text("Automatic").tag(0)
                        ForEach([1, 2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
                    }
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
    private let sideLogEnabled = LibraryFlags.enabled("MADEIRA_LAUNCH_SIDE_LOG")   // ml1780
    private let alwaysLog = LibraryFlags.enabled("MADEIRA_STARTUP_LOG_ALWAYS")   // ml1840
    @State private var launchVisible = false
    @State private var launchChanges = 0
    // ml1420: the Windows Steam client's downloads for a client-routed launch.
    @ObservedObject private var steamProgress = SteamClientProgressModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared   // ml1530
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
                // ml1530: setup's Steam install; ends the session once Steam is ready.
                if onboarding.installSession && !model.launching && !model.menu {
                    OnboardingFinishButton()
                        .frame(maxWidth: min(520, geo.size.width - 120)).frame(maxWidth: .infinity)
                        .padding(.top, Self.topInset(geo) + (model.sessionMessage.isEmpty ? 10 : 54))
                }
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
        .onAppear { fputs("[ui-menu] ml1520 controls first, overlay settings last, red quit\n", stderr) }
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
        // ml1780: a landscape phone had the live log below the fold of this scroll view; it goes
        // beside the status there instead. MADEIRA_LAUNCH_SIDE_LOG=0 keeps it underneath.
        let showLogs = model.launchLogs
        let sideLogs = showLogs && compact && geo.size.width > geo.size.height && sideLogEnabled
        return HStack(spacing: 12) {
        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: compact ? 10 : 18) {
                LibraryArtwork(entry: entry).frame(width: compact ? 90 : 120, height: compact ? 135 : 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).shadow(radius: 20)
                Text(entry.title).font(.title2.bold()).multilineTextAlignment(.center)
                if model.dockLaunchFailure == nil { ProgressView().tint(.white) }
                // ml1510: the client's actual stage (connection and content logs) rather than one
                // fixed line, with the time so far once it is slow. MADEIRA_STEAM_LAUNCH_STAGES=0
                // leaves `stage` nil and restores the fixed text.
                // ml1770: setup's Steam install, from the client's updater log.
                if onboarding.installSession, let stage = onboarding.setupStage {
                    Text(stage.text).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    Text(stage.detail).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 360)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                } else if let failure = model.dockLaunchFailure {
                    Text("Madeira Dock stopped").font(.headline)
                    Text(failure).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("Close session", systemImage: "stop.circle") { model.requestQuit() }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                } else if model.dockLaunching {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 8) {
                            Text(dockStatus).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                            Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } else if model.steamHolding, let stage = steamProgress.progress?.stage {
                    Text(stage.text).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    if let detail = stage.detail {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(model.launchStartedAt)))s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                } else {
                    Text(model.steamHolding ? (model.launchSlow ? "Still waiting for Steam…" : "Steam is starting your game…")
                                            : (model.launchSlow ? "Still starting…" : "Starting your game…")).foregroundStyle(.white.opacity(0.7))
                }
                // ml1970: under Dock too, while Valve's client installs content the launch needs.
                if !model.dockLaunching || LibraryFlags.enabled("MADEIRA_DOCK_PROGRESS"), let progress = steamProgress.progress, progress.active {
                    SteamClientProgressBanner(progress: progress).tint(.white).frame(maxWidth: 360)
                }
                // ml1490: Steam's own windows stay behind this screen until the game opens.
                // ml1850: colocated with the known visible desktop control,
                // independent of session tools and the top session-message overlay.
                if alwaysLog {
                    Button(showLogs ? "Hide live log" : "Show live log", systemImage: "text.alignleft") {
                        model.toggleLaunchLogs()
                    }.buttonStyle(.bordered).tint(.white).frame(minHeight: 44)
                }
                if model.steamHolding {
                    Button(model.dockLaunching ? "Show desktop" : "Show Steam", systemImage: "macwindow") { model.showSteam() }
                        .buttonStyle(.bordered).tint(.white).frame(minHeight: 44)
                        .accessibilityHint(model.dockLaunching ? "Shows the Windows desktop" : "Shows the Windows Steam client, for example to sign in")
                    // ml1780: the client is running the game's one-time installs; restart without them.
                    if !model.dockLaunching, steamProgress.progress?.stage == .installers, model.activeEntry?.steamGameLaunch == true {
                        Button(model.skippingInstallers ? "Closing Steam…" : "Skip one-time installs", systemImage: "forward.end") {
                            model.skipSteamInstallers()
                        }
                        .buttonStyle(.bordered).tint(.white).frame(minHeight: 44).disabled(model.skippingInstallers)
                        .accessibilityHint("Closes Steam and marks DirectX, Visual C++ and similar installers as done")
                    }
                    // ml1990: no explanatory line under a Madeira Dock start (owner request);
                    // MADEIRA_DOCK_START_NOTE=1 shows it again.
                    if !model.dockLaunching || LibraryFlags.enabled("MADEIRA_DOCK_START_NOTE", fallback: false) {
                        Text(model.dockLaunching ? "Madeira Dock uses your Steam sign-in to request access from Valve before launching the game."
                                                 : model.steamAttention ? "Steam opened a window. It may need you, for example to sign in."
                                                  : "Steam's windows stay hidden until the game opens. If Steam needs you, for example to sign in, tap Show Steam.")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(model.steamAttention ? 0.9 : 0.6))
                            .frame(maxWidth: 360)
                    }
                }
                if model.launchSlow {
                    if !model.steamHolding { Button("Show game view") { model.showGameView(reason: "button") }.frame(minHeight: 44) }
                    if sessionTools && !alwaysLog {
                        Button(model.launchLogs ? "Hide live log" : "Show live log") { model.toggleLaunchLogs() }.frame(minHeight: 44)
                    }
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
        .onAppear {
            LogStore.shared.log("[launch-log] ml1850 inline=\(alwaysLog ? 1 : 0) tools=\(sessionTools ? 1 : 0) dock=\(model.dockLaunching ? 1 : 0)")
        }
    }
    /// ml1970: what the Dock start is waiting for, from the host's numeric report.
    private var dockStatus: String {
        let report = MadeiraDock.pollReport()
        if report.fields["launch-update-wait"] != nil && report.fields["launch-update-ready"] == nil {
            return "Steam is installing content this game needs. The game starts when it finishes…"
        }
        if MadeiraDock.installerScript != nil && report.fields["probe-start-bits"] == nil {
            return "Running this game's one-time installs…"
        }
        return model.launchSlow ? "Waiting for Madeira Dock…" : "Starting Madeira Dock…"
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label("Session", systemImage: "gamecontroller.fill").font(.title2.bold()); Spacer(); Button("Done") { model.menu = false }.buttonStyle(.bordered) }
                // ml1520: the controls come first, the easiest to reach; the overlay settings last.
                Toggle("Touch controls", isOn: $controls.visible)
                // ml1970: the layout choice lives here, and only while touch controls are on.
                if controls.visible && ControlPresetsModel.enabled { ControllerLayoutPicker { model.menu = false } }
                LabeledContent("Opacity") { Slider(value: $model.opacity, in: 0.15...1) }
                Button("Edit controls", systemImage: "slider.horizontal.3") { controls.visible = true; controls.editing = true; model.menu = false }
                Button("Keyboard", systemImage: "keyboard") { model.menu = false; LibraryKeyboard.show() }
                Divider()
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
                Toggle("Performance overlay", isOn: $model.performance)
                if model.performance {
                    ForEach(["FPS", "Frame time", "RAM", "Battery"], id: \.self) { field in
                        Toggle(field, isOn: Binding(get: { model.overlayFields.contains(field) }, set: { on in
                            model.overlayFields.removeAll { $0 == field }; if on { model.overlayFields.append(field) }
                        })).font(.subheadline)
                    }
                }
                Divider()
                // ml1520: red label and symbol; the menu's .primary style would otherwise win.
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
    private let fill = LibraryFlags.enabled("MADEIRA_STARTUP_LOG_FILL")
    var body: some View {
        // Rows are coalesced by signature; insertion order isn't recency.
        // Show the latest updates so a repeating wait still looks live.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.entries.sorted { $0.lastTimestamp < $1.lastTimestamp }.suffix(fill ? 200 : 7))) {
                        Text($0.lastRaw).font(.system(size: 9, design: .monospaced)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: fill ? max(0, geo.size.height - 16) : nil, alignment: .topLeading)
            }.defaultScrollAnchor(.bottom).padding(8)
        }.background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
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
            } else if progress.phase >= .queued {
                // ml1970: queued or verifying with no byte counts yet: an activity indicator.
                ProgressView()
            }
            if let speed = progress.speedLine {
                Text(speed).font(.caption2.monospacedDigit()).opacity(0.75)
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

// MARK: - ml1970 store artwork with fallbacks

/// ml1970: store artwork for an App ID. Newer apps publish their library capsule only under a
/// hashed store_item_assets folder named in PICS, and many demos publish none, so the single
/// legacy URL left those cards blank. Candidates, in order: the PICS capsule/hero, the legacy
/// path, the same for a demo's full game, then the store's header image (public store API, no
/// account data). Failures advance to the next candidate; a working URL is remembered.
/// MADEIRA_STEAM_ARTWORK=0 restores the single legacy URL.
@MainActor enum SteamArtwork {
    private static var working: [String: URL] = [:]
    private static var details: [Int: (header: URL?, fullGame: Int?)] = [:]
    static let assetBase = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/"

    static func remembered(_ id: Int, backdrop: Bool) -> URL? { working["\(id)-\(backdrop)"] }
    static func remember(_ url: URL, id: Int, backdrop: Bool) { working["\(id)-\(backdrop)"] = url }

    static func candidates(_ id: Int, backdrop: Bool) -> [URL] {
        var urls: [URL] = []
        func add(_ text: String?) { if let text, let url = URL(string: text), !urls.contains(url) { urls.append(url) } }
        func direct(_ app: Int) {
            let game = SteamAccountModel.shared.game(app)
            if backdrop { add(game?.libraryHero.map { assetBase + "\(app)/" + $0 }) }
            add(game?.libraryCapsule.map { assetBase + "\(app)/" + $0 })
            add("https://cdn.cloudflare.steamstatic.com/steam/apps/\(app)/" + (backdrop ? "library_hero.jpg" : "library_600x900.jpg"))
        }
        direct(id)
        if let parent = SteamAccountModel.shared.game(id)?.parentID { direct(parent) }
        if let header = SteamAccountModel.shared.game(id)?.headerImage { add(assetBase + "\(id)/" + header) }
        return urls
    }

    /// Store details for an app without usable artwork: its header image, and a demo's full game.
    static func storeFallbacks(_ id: Int, backdrop: Bool) async -> [URL] {
        if details[id] == nil {
            details[id] = (nil, nil)
            var components = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
            components.queryItems = [URLQueryItem(name: "appids", value: String(id)), URLQueryItem(name: "filters", value: "basic,fullgame")]
            var request = URLRequest(url: components.url!); request.timeoutInterval = 15
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let body = (json[String(id)] ?? json.values.first) as? [String: Any], body["success"] as? Bool == true,
               let info = body["data"] as? [String: Any] {
                let header = (info["header_image"] as? String).flatMap(URL.init(string:)).flatMap { SteamPaths.trustedArtwork($0) ? $0 : nil }
                let full = (info["fullgame"] as? [String: Any]).flatMap { ($0["appid"] as? String).flatMap(Int.init) ?? $0["appid"] as? Int }
                details[id] = (header, full)
            }
        }
        var urls: [URL] = []
        if let full = details[id]?.fullGame, full != id {
            urls += candidates(full, backdrop: backdrop)
            if let header = await storeFallbacks(full, backdrop: backdrop).last { urls.append(header) }
        }
        if let header = details[id]?.header { urls.append(header) }
        return urls
    }
}

struct SteamArtworkImage: View {
    let id: Int
    let backdrop: Bool
    @State private var urls: [URL] = []
    @State private var index = 0
    @State private var askedStore = false
    var body: some View {
        AsyncImage(url: index < urls.count ? urls[index] : nil) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .onAppear { if index < urls.count { SteamArtwork.remember(urls[index], id: id, backdrop: backdrop) } }
            case .failure:
                Color.clear.onAppear { advance() }
            default:
                Color.clear
            }
        }
        .task(id: "\(id)-\(backdrop)") {
            askedStore = false; index = 0
            let list = SteamArtwork.candidates(id, backdrop: backdrop)
            urls = SteamArtwork.remembered(id, backdrop: backdrop).map { [$0] + list.filter { $0 != SteamArtwork.remembered(id, backdrop: backdrop) } } ?? list
        }
    }
    private func advance() {
        if index + 1 < urls.count { index += 1; return }
        guard !askedStore else { return }
        askedStore = true
        Task { @MainActor in
            let more = await SteamArtwork.storeFallbacks(id, backdrop: backdrop).filter { !urls.contains($0) }
            guard !more.isEmpty else { return }
            let next = urls.count
            urls += more
            index = next
        }
    }
}

/// ml1970: the session menu's layout choice: Xbox (the default), the user's custom layouts
/// ("Custom Layout 1", "Custom Layout 2", ...), and "Create new layout", which opens the editor on
/// an empty layout to fill with keyboard, mouse and controller buttons. Choosing one replaces the
/// on-screen controls at once (ControlPresetsModel.load refreshes them).
struct ControllerLayoutPicker: View {
    var closeMenu: () -> Void
    @ObservedObject private var presets = ControlPresetsModel.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @ObservedObject private var model = LibraryModel.shared
    @State private var confirmDelete: ControlPreset?

    private var currentName: String {
        guard let active = presets.active else { return "Custom" }
        return active.id == ControlPresetLayout.xboxID ? "Xbox" : active.name
    }

    var body: some View {
        LabeledContent("Controller layout") {
            Menu {
                Button { choose(ControlPresetLayout.xboxID) } label: {
                    if presets.activeID == ControlPresetLayout.xboxID { Label("Xbox", systemImage: "checkmark") }
                    else { Label("Xbox", systemImage: "gamecontroller") }
                }
                ForEach(presets.store.user) { p in
                    Button { choose(p.id) } label: {
                        if presets.activeID == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Divider()
                Button("Create new layout", systemImage: "plus") {
                    guard presets.createLayout() != nil else { return }
                    model.saveCurrentProfile()
                    controls.visible = true
                    controls.editing = true
                    closeMenu()
                }
                if let active = presets.active, !ControlPresetStore.isBuiltIn(active.id) {
                    Button("Edit \(active.name)", systemImage: "slider.horizontal.3") {
                        controls.visible = true; controls.editing = true; closeMenu()
                    }
                    Button("Delete \(active.name)", systemImage: "trash", role: .destructive) { confirmDelete = active }
                }
            } label: {
                HStack(spacing: 4) { Text(currentName); Image(systemName: "chevron.up.chevron.down").font(.caption) }
            }
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                        set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete, presets.delete(p.id) { choose(ControlPresetLayout.xboxID) }
                confirmDelete = nil
            }
        }
    }

    private func choose(_ id: String) {
        presets.load(id, screen: ControlPresetsModel.currentScreen())
        model.saveCurrentProfile()
        LogStore.shared.log("[controls-layout] ml1970 chose layout=\(id == ControlPresetLayout.xboxID ? "xbox" : "custom")")
    }
}
