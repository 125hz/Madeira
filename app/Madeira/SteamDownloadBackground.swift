// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit

// Downloads and leaving Madeira (docs/STEAM_LIBRARY.md). While a Steam
// download runs and Madeira goes to the background, iOS is asked for the usual
// short background grace period. When that ends, or is refused, the download
// pauses cleanly (every finished chunk is journaled) and continues when
// Madeira is active again. This uses no background mode, background task
// identifier or Info.plist entry, and asks for no notification permission.
@MainActor final class SteamDownloadBackground {
    static let shared = SteamDownloadBackground()

    private weak var library: SteamOwnedLibrary?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observing = false

    /// Called once, when the library model starts.
    func attach(_ library: SteamOwnedLibrary) {
        self.library = library
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.end()
                self?.library?.resumeAfterBackground()
                self?.library?.reconcileSession()
            }
        }
    }

    /// A download became active.
    func downloadStarted() {
        if UIApplication.shared.applicationState != .active { begin() }
    }

    /// A download ended. `queueEmpty`: nothing else waits.
    func downloadEnded(queueEmpty: Bool) {
        if queueEmpty { end() }
    }

    private func begin() {
        guard task == .invalid, library?.hasActiveDownload == true else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Madeira Steam download") { [weak self] in
            MainActor.assumeIsolated {
                self?.library?.pauseForBackground()
                self?.end()
            }
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
