import Foundation

/// Logging for the native Steam client.
///
/// `event` lines are the always-on, low-volume record ([steam-account],
/// [steam-library], [steam-depot], [steam-play]). They never contain tokens,
/// passwords, account names, Steam IDs or message payloads.
///
/// `trace` lines are protocol-level detail, off by default. Enable with
/// MADEIRA_STEAM_TRACE=1 in madeira-env.txt. They are still written without
/// credentials or payload bytes.
enum SteamLog {
    static let tracing = LibraryFlags.enabled("MADEIRA_STEAM_TRACE", fallback: false)

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        // ml1320: LogStore, not stderr — stderr is only captured into the
        // log once a Wine session starts, and Steam work happens before one.
        LogStore.shared.log("[steam-trace] " + message())
    }

    static func event(_ message: String) {
        LogStore.shared.log(message)
    }
}
