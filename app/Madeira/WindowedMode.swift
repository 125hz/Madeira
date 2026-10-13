import Foundation
import UIKit

// ml1300 windowed mode (docs/WINDOWED.md). The frames, title bars and the
// taskbar are UIKit views made by the native compositor (Winios/
// WiniosWindowed.m); this file is the Swift end: whether the mode is on, and
// the taskbar's tool buttons, which call into the library front end. ml1350:
// also MadeiraSession, which starts a program inside the running session
// (docs/SESSION_LAUNCH.md), used by the Steam button and the in-game menu's
// Run program….

enum WindowedMode {
    /// This session draws every top-level window in its own frame: a desktop
    /// session with madeira.cfg `windowed = 1` or env.MADEIRA_WINDOWED = 1.
    static var active: Bool { winios_windowed_active() != 0 }

    /// One window fills the whole screen (its frame's maximize button); the
    /// in-game menu then offers the way back. Main thread.
    static var maximized: Bool { active && winios_windowed_maximized() != 0 }

    /// Back to the frames and the taskbar.
    static func restoreWindows() { winios_windowed_unmaximize() }

    /// Windowed mode taps a window where the finger is (the Touch pointer mode
    /// of MetalBackedView): the trackpad pointer that desktop sessions use by
    /// default cannot cross from one frame to another on screen.
    /// env.MADEIRA_WINDOWED_TOUCH = 0 keeps the pointer mode chosen in Settings.
    /// (Read on every touch, so from the environment the session exported, not the file.)
    static var forcesTouchPointer: Bool {
        guard active else { return false }
        let keep = getenv("MADEIRA_WINDOWED_TOUCH")   // 0: windowed mode keeps the Settings pointer mode (trackpad) instead of tap-where-you-touch
        return !(keep.map { $0.pointee == 48 && $0.advanced(by: 1).pointee == 0 } ?? false)
    }
}

/// Found by name (NSClassFromString) from WiniosWindowed.m's taskbar, so the
/// native side needs no Swift header.
@objc(MadeiraWindowedBridge)
final class MadeiraWindowedBridge: NSObject {
    /// The taskbar's keyboard button: the library's keyboard, as in its menu.
    @objc static func toggleKeyboard() {
        DispatchQueue.main.async {
            if LibraryKeyboard.window != nil { LibraryKeyboard.hide() } else { LibraryKeyboard.show() }
            fputs("[windowed] ml1300 taskbar keyboard\n", stderr)
        }
    }

    /// The taskbar's menu button: the in-game menu of a library session.
    @objc static func openMenu() {
        DispatchQueue.main.async {
            let library = LibraryModel.shared
            guard library.current != nil else {
                fputs("[windowed] ml1300 taskbar menu: no library session (developer interface)\n", stderr)
                return
            }
            library.menu = true
            fputs("[windowed] ml1300 taskbar menu\n", stderr)
        }
    }

    /// Round 4: the taskbar's pinned Steam button (left of the program buttons).
    @objc static func steamButtonEnabled() -> Bool {
        MadeiraConfig.flag("MADEIRA_WINDOWED_STEAM", fallback: true)   // 0: no pinned Steam button on the windowed-mode taskbar (round 4)
    }

    /// The Steam button when no Steam window is open in the session (one that
    /// is open is brought to the front by WiniosWindowed.m and never gets here).
    @objc static func steamTapped() {
        DispatchQueue.main.async { WindowedSteam.tapped() }
    }
}

/// The windowed taskbar's Steam button (round 4, docs/WINDOWED.md).
///
/// ml1350: the button starts Steam INSIDE the running session (MadeiraSession
/// below, docs/SESSION_LAUNCH.md), as a child of the Wine desktop's shell:
/// - Steam installed in the prefix (steam.exe under Program Files (x86)\Steam or
///   Program Files\Steam): steam.exe -no-cef-sandbox -cef-disable-gpu in its
///   folder, services.exe first when none runs.
/// - Not installed: Valve's SteamSetup.exe, downloaded from Valve's CDN with a
///   progress alert into Application Support/MadeiraSteam, copied to
///   C:\madeira-games and started (a copy already there is started without a
///   new download).
/// When the in-session start is refused or fails (env.MADEIRA_SESSION_LAUNCH=0,
/// no session, a start error), the round 4 behaviour is the fallback: a library
/// entry "Steam" / "Steam Setup" (Wine desktop, services first) for the next
/// start, and an alert that says why and to restart Madeira.
/// The first tap shows the memory warning (Continue / Cancel); a second tap
/// while the started Steam has not opened a window yet only says so.
/// Log lines: "[windowed] ml1300 steam: launch | install | not available (reason)",
/// plus MadeiraSession's "[launch] ml1350 in-session: …".
@MainActor
enum WindowedSteam {
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    /// steam.exe relative to drive_c; Program Files (x86) is where Steam installs by default.
    static let clientPaths = ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe"]
    static let installerPath = "madeira-games/SteamSetup.exe"
    /// The full client under Wine: no Chromium sandbox, a software-rendered web helper.
    static let clientArguments = "-no-cef-sandbox -cef-disable-gpu"
    private static let warnedKey = "madeira.windowed.steam-memory-warning"
    private static var download: URLSessionDownloadTask?
    private static var session: URLSession?
    private static var observation: NSKeyValueObservation?
    private static var progressAlert: UIAlertController?
    private static var percent = -1
    /// ml1350: when this run last started Steam or its installer in the session.
    private static var startedAt: Date?
    private static var starting = false

    static func log(_ line: String) { fputs("[windowed] ml1300 steam: \(line)\n", stderr) }

    static var installedClient: String? {
        clientPaths.first { FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent($0).path) }
    }

    static func tapped() {
        if download != nil {
            if let alert = progressAlert, alert.presentingViewController == nil { present(alert) }
            return
        }
        // ml1350: the Steam just started has no window yet (a window would have
        // been brought to the front by WiniosWindowed.m): do not start a second one.
        if starting || startedAt.map({ Date().timeIntervalSince($0) < 90 }) == true {
            log("launch (already starting in this session; its window has not opened yet)")
            show("Steam is starting", "Steam was started in this session a moment ago. Its window opens when it is ready; "
                 + "the first start after an install or update can take a few minutes.")
            return
        }
        guard UserDefaults.standard.bool(forKey: warnedKey) else {
            var message = "The full Steam client needs a lot of memory; the web helper may be killed."
            if MadeiraDock.enabled && MadeiraDock.clientInstalled {
                message += "\n\nSteam updates its own files when it runs; Madeira Dock refuses a client build it has not verified."
            }
            let alert = UIAlertController(title: "Steam", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                WindowedSteam.log("not available (cancelled at the memory warning)")
            })
            alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
                UserDefaults.standard.set(true, forKey: WindowedSteam.warnedKey)
                WindowedSteam.proceed()
            })
            present(alert)
            return
        }
        proceed()
    }

    private static func proceed() {
        if let client = installedClient {
            startClient(client)
        } else if MadeiraSession.available, let bytes = installerCopyBytes {
            installerReady(nil, bytes: bytes)   // ml1350: the copy in drive_c from an earlier download
        } else {
            startDownload()
        }
    }

    private static func windowsPath(_ relative: String) -> String {
        "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    /// The program's folder, as a Windows path ("C:\Program Files (x86)\Steam").
    private static func windowsFolder(_ relative: String) -> String {
        windowsPath((relative as NSString).deletingLastPathComponent)
    }

    private static var libraryNote: String {
        LibraryModel.shared.enabled ? ""
            : "\n\nThis run uses the developer interface: switch to the library interface in Settings to see the entry."
    }

    /// ml1350: start `relative` (drive_c) inside the running session, services.exe
    /// first; nil result = started. Otherwise the reason it was not, for the fallback.
    private static func startInSession(_ relative: String, arguments: String,
                                       done: @escaping @MainActor (_ failure: String?) -> Void) {
        let path = windowsPath(relative)
        let command = "\"\(path)\"" + (arguments.isEmpty ? "" : " " + arguments)
        starting = true
        MadeiraSession.launch(commandLine: command, workingDirectory: windowsFolder(relative), servicesFirst: true) { result in
            WindowedSteam.starting = false
            if result.ok { WindowedSteam.startedAt = Date() }
            done(result.ok ? nil : result.reason)
        }
    }

    private static func startClient(_ relative: String) {
        let path = windowsPath(relative)
        guard MadeiraSession.available else {
            prepareClient(relative, inSession: MadeiraSession.unavailableReason)
            return
        }
        startInSession(relative, arguments: clientArguments) { failure in
            if let failure {
                WindowedSteam.prepareClient(relative, inSession: failure)
            } else {
                WindowedSteam.log("launch (started in this session: \(path) \(WindowedSteam.clientArguments))")
            }
        }
    }

    /// The round 4 fallback: a library entry for the next start.
    private static func prepareClient(_ relative: String, inSession failure: String) {
        let path = windowsPath(relative)
        let entry = libraryEntry(relative: relative, title: "Steam", arguments: clientArguments)
        if let failure = entry.failure {
            log("not available (Steam is installed at \(path), but its library entry could not be made: \(failure))")
            show("Steam", "Steam is installed, but Madeira could not add it to the library: \(failure)")
            return
        }
        log("not available (it could not start in this session: \(failure); library entry \"Steam\" for "
            + "\(path) \(entry.added ? "added" : "already there"), started at the next start)")
        show("Steam starts in a session of its own",
             "Madeira could not start Steam inside this session (\(failure)). Steam is \(entry.added ? "now " : "")in "
             + "your library: restart Madeira (swipe it away in the app switcher), then open Steam there. It runs in a "
             + "Wine desktop of its own, windowed when windowed mode is on." + libraryNote)
    }

    /// The library entry that starts `relative` (drive_c) inside the Wine
    /// desktop with services.exe first, made when no entry starts it yet.
    private static func libraryEntry(relative: String, title: String, arguments: String) -> (added: Bool, failure: String?) {
        let library = LibraryModel.shared
        func present() -> Bool {
            library.entries.contains { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
        }
        if present() { return (false, nil) }
        do {
            var entry = try LibraryModel.inspect(LibraryModel.drive.appendingPathComponent(relative))
            entry.title = title
            entry.arguments = arguments
            entry.launchMode = "desktop"   // inside the Wine desktop: every window shows, windowed mode applies
            entry.startServices = true     // services.exe first (the SCM, rpcss: out-of-process COM)
            library.save(entry)
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        return present() ? (true, nil) : (false, library.error ?? "the library file could not be changed")
    }

    // MARK: Valve's installer

    nonisolated static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "steamstatic.com" || host.hasSuffix(".steamstatic.com")
    }

    private static func startDownload() {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraSteam", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = folder; try url.setResourceValues(values)
        } catch {
            log("not available (could not prepare Application Support: \(error.localizedDescription))")
            show("Steam", "Madeira could not prepare a folder for Steam's installer: \(error.localizedDescription)")
            return
        }
        let target = folder.appendingPathComponent("SteamSetup.exe")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: SteamSetupRedirects(), delegateQueue: nil)
        let task = session.downloadTask(with: installerURL) { temp, response, failure in
            // The temporary file is removed when this returns: check and move it first.
            var outcome: String?
            var bytes = 0
            if let failure {
                outcome = (failure as? URLError)?.code == .cancelled ? "cancelled" : "the download failed: \(failure.localizedDescription)"
            } else if let temp {
                let http = response as? HTTPURLResponse
                let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if http?.statusCode != 200 {
                    outcome = "Valve's server answered \(http?.statusCode ?? 0)"
                } else if !WindowedSteam.allowed(http?.url) {
                    outcome = "the download left Valve's servers"
                } else if size < 256 * 1024 || size > 64 * 1024 * 1024 {
                    outcome = "an unexpected size (\(size) bytes)"
                } else {
                    do {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: temp, to: target)
                        bytes = size
                    } catch {
                        outcome = "the download could not be kept: \(error.localizedDescription)"
                    }
                }
            } else {
                outcome = "the download returned no file"
            }
            let result = outcome, count = bytes
            Task { @MainActor in WindowedSteam.downloaded(target, bytes: count, failure: result) }
        }
        let alert = UIAlertController(title: "Downloading Steam's installer",
                                      message: "SteamSetup.exe from Valve…", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in WindowedSteam.download?.cancel() })
        progressAlert = alert
        percent = -1
        download = task
        self.session = session
        observation = task.progress.observe(\.fractionCompleted) { @Sendable progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in WindowedSteam.progressed(fraction) }
        }
        log("install (downloading \(installerURL.absoluteString) into Application Support/MadeiraSteam)")
        present(alert)
        task.resume()
    }

    private static func progressed(_ fraction: Double) {
        let now = Int((fraction * 100).rounded(.down))
        guard download != nil, now != percent else { return }
        percent = now
        progressAlert?.message = "SteamSetup.exe from Valve… \(now) %"
    }

    private static func downloaded(_ file: URL, bytes: Int, failure: String?) {
        observation = nil
        download = nil
        session?.finishTasksAndInvalidate()
        session = nil
        let alert = progressAlert
        progressAlert = nil
        let next = {
            if let failure {
                WindowedSteam.log("not available (Steam's installer: \(failure))")
                if failure != "cancelled" { WindowedSteam.show("Steam", "Steam's installer could not be downloaded: \(failure).") }
                return
            }
            WindowedSteam.installerReady(file, bytes: bytes)
        }
        if let alert, alert.presentingViewController != nil, !alert.isBeingDismissed {
            alert.dismiss(animated: true, completion: next)
        } else {
            next()
        }
    }

    /// ml1350: the size of the installer copy an earlier download left in drive_c
    /// (nil when there is none, or it is not plausibly Valve's installer).
    private static var installerCopyBytes: Int? {
        let copy = LibraryModel.drive.appendingPathComponent(installerPath)
        guard let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size >= 256 * 1024, size <= 64 * 1024 * 1024 else { return nil }
        return size
    }

    /// `file` nil: the copy in drive_c is already there (an earlier download).
    private static func installerReady(_ file: URL?, bytes: Int) {
        let fm = FileManager.default
        let copy = LibraryModel.drive.appendingPathComponent(installerPath)
        if let file {
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: file, to: copy)
            } catch {
                log("not available (SteamSetup.exe downloaded, \(bytes) bytes, but it could not be put into drive_c: \(error.localizedDescription))")
                show("Steam", "Steam's installer was downloaded but could not be put into the Windows drive: \(error.localizedDescription)")
                return
            }
        }
        let origin = file == nil ? "already in drive_c from an earlier download" : "downloaded"
        guard MadeiraSession.available else {
            prepareInstaller(bytes: bytes, origin: origin, inSession: MadeiraSession.unavailableReason)
            return
        }
        startInSession(installerPath, arguments: "") { failure in
            if let failure {
                WindowedSteam.prepareInstaller(bytes: bytes, origin: origin, inSession: failure)
            } else {
                WindowedSteam.log("install (SteamSetup.exe \(origin), \(bytes) bytes, at \(WindowedSteam.windowsPath(WindowedSteam.installerPath)); "
                                  + "started in this session)")
            }
        }
    }

    /// The round 4 fallback: a library entry "Steam Setup" for the next start.
    private static func prepareInstaller(bytes: Int, origin: String, inSession failure: String) {
        let entry = libraryEntry(relative: installerPath, title: "Steam Setup", arguments: "")
        if let failure = entry.failure {
            log("not available (SteamSetup.exe \(origin), \(bytes) bytes, at \(windowsPath(installerPath)); library entry failed: \(failure))")
            show("Steam", "Steam's installer is at \(windowsPath(installerPath)), but Madeira could not add it to the library: \(failure)")
            return
        }
        log("install (SteamSetup.exe \(origin), \(bytes) bytes, kept in Application Support/MadeiraSteam and \(windowsPath(installerPath)); "
            + "library entry \"Steam Setup\" \(entry.added ? "added" : "already there"); it could not start in this session: \(failure); "
            + "it starts at the next start)")
        show("Steam's installer is ready",
             "Valve's SteamSetup.exe is in your library as Steam Setup. Madeira could not start it inside this session "
             + "(\(failure)): restart Madeira (swipe it away in the app switcher), then open Steam Setup. Once Steam "
             + "is installed, this button starts Steam." + libraryNote)
    }

    // MARK: Alerts

    static func show(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    static func present(_ controller: UIViewController) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil }
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else {
            log("not available (no window to show the message in)")
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(controller, animated: true)
    }
}

/// Valve's installer may only be fetched from, and redirected within, Valve's
/// CDN over HTTPS (the same rule as SteamRuntime.swift's component download).
private final class SteamSetupRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(WindowedSteam.allowed(request.url) ? request : nil)
    }
}

/// ntdll calls this on the Wine thread that took (state 1) or finished (state 2)
/// a request; the main actor does the rest.
private let madeiraSessionLaunchCallback: madeira_session_launch_cb = { id, state, status, pid, detail in
    let text = detail.map { String(cString: $0) } ?? ""
    Task { @MainActor in MadeiraSession.update(id: id, state: state, status: status, pid: pid, detail: text) }
}

/// ml1350 in-session launcher (docs/SESSION_LAUNCH.md): start a Windows program
/// inside the RUNNING session, the way a desktop OS starts one from its shell.
///
/// The request goes to ntdll's queue (build/ntdll-unix/process_ios.c,
/// madeira_session_launch_request); the Wine thread that owns the desktop window
/// (explorer's shell thread in a desktop session) takes it from the display
/// driver's event hook and starts it with NtCreateUserProcess, as CreateProcessW
/// would, so the program is the shell's child with its desktop and environment.
/// The completion runs on the main actor once: ok with the new pid, or an error
/// with the reason. Every launch logs one line:
/// "[launch] ml1350 in-session: <cmd> -> ok (pid …, parent …) | error (reason)".
/// Only full paths of .exe programs start this way ("C:\Games\Game\game.exe -arg",
/// quoted or not); the working folder defaults to the program's own.
/// env.MADEIRA_SESSION_LAUNCH = 0 turns it off (the Steam button then prepares a
/// library entry for the next start, as before ml1350; Run program… is hidden).
@MainActor
enum MadeiraSession {
    struct Result {
        let ok: Bool
        /// The new process id (ok only).
        let pid: UInt32
        /// The NTSTATUS of the start (0 when ok; 0 too when refused before queueing).
        let status: UInt32
        /// ok: "pid …, parent …"; error: why it did not start.
        let reason: String
    }

    /// 0: the app cannot start a program inside a running session (Run program… is hidden; the windowed taskbar's Steam button falls back to a library entry for the next start); ml1350
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SESSION_LAUNCH", fallback: true) }
    /// A session is running and the feature is on.
    static var available: Bool { enabled && wine_process_is_running() != 0 }
    static var unavailableReason: String {
        enabled ? "no Windows session is running" : "starting programs in a running session is off (env.MADEIRA_SESSION_LAUNCH=0)"
    }

    /// services.exe first when none runs (process_ios.c MSL_FLAG_SERVICES_FIRST).
    private static let servicesFirstFlag: UInt32 = 1
    /// A request no Wine thread took by then is reported as an error (ntdll drops it at 30 s).
    private static let takeTimeout: TimeInterval = 35
    private static var callbackSet = false
    private static var pending: [UInt32: (command: String, taken: Bool, completion: @MainActor (Result) -> Void)] = [:]

    static func launch(commandLine: String, workingDirectory: String? = nil, servicesFirst: Bool = false,
                       completion: @escaping @MainActor (Result) -> Void = { _ in }) {
        let command = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard available else {
            finish(command, Result(ok: false, pid: 0, status: 0, reason: unavailableReason), completion)
            return
        }
        if !callbackSet {
            madeira_session_launch_set_callback(madeiraSessionLaunchCallback)
            callbackSet = true
        }
        var reason = [CChar](repeating: 0, count: 512)
        let folder = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: UInt32 = command.withCString { cmd in
            if let folder, !folder.isEmpty {
                return folder.withCString { madeira_session_launch_request(cmd, $0, servicesFirst ? servicesFirstFlag : 0, &reason, Int32(reason.count)) }
            }
            return madeira_session_launch_request(cmd, nil, servicesFirst ? servicesFirstFlag : 0, &reason, Int32(reason.count))
        }
        guard id != 0 else {
            finish(command, Result(ok: false, pid: 0, status: 0, reason: String(cString: reason)), completion)
            return
        }
        pending[id] = (command, false, completion)
        fputs("[launch] ml1350 in-session: \(command) -> queued #\(id)\n", stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + takeTimeout) {
            MainActor.assumeIsolated {
                guard let request = MadeiraSession.pending[id], !request.taken else { return }
                MadeiraSession.pending[id] = nil
                MadeiraSession.finish(request.command, Result(ok: false, pid: 0, status: 0,
                    reason: "no Wine thread of the session took the request in \(Int(MadeiraSession.takeTimeout)) s"), request.completion)
            }
        }
    }

    fileprivate static func update(id: UInt32, state: UInt32, status: UInt32, pid: UInt32, detail: String) {
        guard var request = pending[id] else { return }   // already reported (timeout)
        if state == 1 {
            request.taken = true
            pending[id] = request
            fputs("[launch] ml1350 in-session: \(request.command) -> starting (\(detail))\n", stderr)
            return
        }
        pending[id] = nil
        finish(request.command, Result(ok: status == 0, pid: pid, status: status, reason: detail), request.completion)
    }

    private static func finish(_ command: String, _ result: Result, _ completion: @MainActor (Result) -> Void) {
        fputs("[launch] ml1350 in-session: \(command) -> \(result.ok ? "ok" : "error") (\(result.reason))\n", stderr)
        completion(result)
    }

    // MARK: Run program…

    private static let lastCommandKey = "madeira.session.run-last"

    /// The in-game menu's "Run program…": a command line typed by the user,
    /// started in this session; the last one is offered again.
    static func promptRun() {
        let alert = UIAlertController(title: "Run program",
                                      message: "A Windows program to start in this session, with its arguments: "
                                        + "C:\\folder\\program.exe -options",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "C:\\Games\\Game\\game.exe"
            field.text = UserDefaults.standard.string(forKey: MadeiraSession.lastCommandKey)
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartQuotesType = .no      // a typed " must stay a straight quote
            field.smartDashesType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .go
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Run", style: .default) { [weak alert] _ in
            let command = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !command.isEmpty else { return }
            UserDefaults.standard.set(command, forKey: MadeiraSession.lastCommandKey)
            MadeiraSession.launch(commandLine: command) { result in
                if !result.ok { WindowedSteam.show("Run program", "It did not start: \(result.reason).") }
            }
        })
        WindowedSteam.present(alert)
    }
}
