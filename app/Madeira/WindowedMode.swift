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
}
