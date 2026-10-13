import Foundation
import UIKit

// ml1300 windowed mode (docs/WINDOWED.md). The frames, title bars and the
// taskbar are UIKit views made by the native compositor (Winios/
// WiniosWindowed.m); this file is the Swift end: whether the mode is on, and
// the taskbar's tool buttons, which call into the library front end.

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
/// What it can do, honestly: the app starts Wine's first program of a session
/// and nothing inside a running session takes a launch request from the app,
/// so a second program (Steam, or Valve's installer) cannot be started into the
/// current desktop. One session runs per app run. The button therefore prepares
/// the next start and says so:
/// - Steam installed in the prefix (steam.exe under Program Files (x86)\Steam or
///   Program Files\Steam): a library entry "Steam" that starts steam.exe inside
///   a Wine desktop of its own (services.exe first), windowed when windowed
///   mode is on.
/// - Not installed: Valve's SteamSetup.exe, downloaded from Valve's CDN with a
///   progress alert into Application Support/MadeiraSteam, copied to
///   C:\madeira-games and added as the library entry "Steam Setup".
/// The first tap shows the memory warning (Continue / Cancel).
/// Log lines: "[windowed] ml1300 steam: launch | install | not available (reason)".
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

    static func log(_ line: String) { fputs("[windowed] ml1300 steam: \(line)\n", stderr) }

    static var installedClient: String? {
        clientPaths.first { FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent($0).path) }
    }

    static func tapped() {
        if download != nil {
            if let alert = progressAlert, alert.presentingViewController == nil { present(alert) }
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
        if let client = installedClient { prepareClient(client) } else { startDownload() }
    }

    private static func windowsPath(_ relative: String) -> String {
        "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }

    private static var libraryNote: String {
        LibraryModel.shared.enabled ? ""
            : "\n\nThis run uses the developer interface: switch to the library interface in Settings to see the entry."
    }

    private static func prepareClient(_ relative: String) {
        let path = windowsPath(relative)
        let entry = libraryEntry(relative: relative, title: "Steam", arguments: clientArguments)
        if let failure = entry.failure {
            log("not available (Steam is installed at \(path), but its library entry could not be made: \(failure))")
            show("Steam", "Steam is installed, but Madeira could not add it to the library: \(failure)")
            return
        }
        log("not available (a running session cannot start another program from the app; library entry \"Steam\" for "
            + "\(path) \(entry.added ? "added" : "already there"), started at the next start)")
        show("Steam starts in a session of its own",
             "Madeira cannot start another program inside a running session yet. Steam is \(entry.added ? "now " : "")in "
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

    private static func installerReady(_ file: URL, bytes: Int) {
        let fm = FileManager.default
        let copy = LibraryModel.drive.appendingPathComponent(installerPath)
        do {
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: file, to: copy)
        } catch {
            log("not available (SteamSetup.exe downloaded, \(bytes) bytes, but it could not be put into drive_c: \(error.localizedDescription))")
            show("Steam", "Steam's installer was downloaded but could not be put into the Windows drive: \(error.localizedDescription)")
            return
        }
        let entry = libraryEntry(relative: installerPath, title: "Steam Setup", arguments: "")
        if let failure = entry.failure {
            log("not available (SteamSetup.exe downloaded, \(bytes) bytes, at \(windowsPath(installerPath)); library entry failed: \(failure))")
            show("Steam", "Steam's installer is at \(windowsPath(installerPath)), but Madeira could not add it to the library: \(failure)")
            return
        }
        log("install (SteamSetup.exe downloaded, \(bytes) bytes, kept in Application Support/MadeiraSteam and \(windowsPath(installerPath)); "
            + "library entry \"Steam Setup\" \(entry.added ? "added" : "already there"); it cannot run inside this session, it starts at the next start)")
        show("Steam's installer is ready",
             "Valve's SteamSetup.exe is in your library as Steam Setup. Madeira cannot start another program inside a "
             + "running session yet: restart Madeira (swipe it away in the app switcher), then open Steam Setup. Once Steam "
             + "is installed, this button adds Steam itself to the library." + libraryNote)
    }

    // MARK: Alerts

    private static func show(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    private static func present(_ controller: UIViewController) {
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
