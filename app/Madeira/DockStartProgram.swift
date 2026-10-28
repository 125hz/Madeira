// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Madeira Dock: "Steam starts" (Game details › Steam). Madeira can start only one
/// 32-bit program per session, so a game whose 32-bit launcher starts the game
/// (Fallout: New Vegas's FalloutNVLauncher.exe) ends the session at the launcher's
/// Play: the game's code is never made executable. With a program chosen here, the
/// program Steam's launch entry names is kept beside it as "<name>.madeira-launcher"
/// and a copy of the chosen program takes its name, so Valve's client (which still
/// starts the game and checks ownership) starts the game itself. Without a choice
/// the kept launcher is put back. Both happen at a Dock start, while no session runs.
enum DockStartProgram {
    /// The launcher's file while a copy of the chosen program has its name. Not an
    /// .exe, so the Program picker does not list it.
    static let keptSuffix = ".madeira-launcher"
    private static let key = "MadeiraDockStartProgram"

    /// The program (relative to the install folder, "FalloutNV.exe") Steam's launch
    /// entry is swapped for; nil: Steam's own.
    static func chosen(_ appID: Int, defaults: UserDefaults = .standard) -> String? {
        let all = defaults.dictionary(forKey: key) as? [String: String]
        return all?[String(appID)]
    }

    static func setChosen(_ appID: Int, _ program: String?, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[String(appID)] = program
        defaults.set(all, forKey: key)
    }

    enum Outcome: Equatable {
        /// Nothing to do: no choice and nothing kept, or the copy is already in place.
        case unchanged
        /// The launcher was kept and the chosen program copied in its place.
        case swapped
        /// The kept launcher was put back.
        case restored
        case failed(String)
    }

    /// Puts the chosen program (nil: none) in place of `launcher`, the program Steam's
    /// launch entry names; both are relative to `folder`, the game's install folder.
    static func apply(launcher: String, program: String?, folder: URL, files: FileManager = .default) -> Outcome {
        guard safe(launcher) else { return .failed("Steam's launch entry \(launcher) is outside the game's folder") }
        let target = folder.appendingPathComponent(launcher)
        let kept = URL(fileURLWithPath: target.path + keptSuffix)
        let swapping = program.map { $0.lowercased() != launcher.lowercased() } ?? false
        do {
            guard swapping, let program else {
                // No choice (or Steam's own program): the kept launcher goes back.
                guard files.fileExists(atPath: kept.path) else { return .unchanged }
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.moveItem(at: kept, to: target)
                return .restored
            }
            guard safe(program) else { return .failed("\(program) is outside the game's folder") }
            let source = folder.appendingPathComponent(program)
            guard files.fileExists(atPath: source.path) else { return .failed("\(program) is not in the game's folder") }
            if files.fileExists(atPath: target.path) {
                if files.fileExists(atPath: kept.path) {
                    // Already swapped: a copy of this program, or of an earlier choice.
                    if files.contentsEqual(atPath: target.path, andPath: source.path) { return .unchanged }
                    try files.removeItem(at: target)
                } else {
                    try files.moveItem(at: target, to: kept)
                }
            }
            try files.copyItem(at: source, to: target)
            return .swapped
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A relative path that stays inside the folder.
    private static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}
