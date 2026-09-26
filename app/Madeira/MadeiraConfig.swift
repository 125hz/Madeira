import Foundation

/// ml1095: ONE configuration file for every runtime switch: Documents/madeira.cfg
///
///     # comments start with #
///     key = value        (whitespace trimmed; the value runs to the end of the
///                         line, so it may contain '='; the last line wins)
///
/// Keys are the old per-file names without "madeira-" and ".txt"
/// (swap-mb, vram-mb, pool, totalphys, wx, ...). Environment exports are
/// "env.NAME = value". DXMT options are one line, "dxmt = a=b;c=d".
///
/// The native side reads the same file through build/madeira_cfg.h with the
/// same rules. When madeira.cfg is ABSENT the legacy one-value-per-file layout
/// still works. Newly supplied environment overrides are merged into an
/// existing canonical file before cleanup. Legacy files are deleted only
/// after their values have been verified in madeira.cfg (ml1840).
enum MadeiraConfig {
    static let fileName = "madeira.cfg"

    /// Every switch that used to live in its own Documents/madeira-<key>.txt.
    static let legacyKeys = [
        "swap-mb", "swap-canary", "vram-mb", "pool", "totalphys", "inproc-sync", "wx",
        "mono-bridge", "ctx-frame", "tf-trace", "usd-time", "real-suspend", "mono-suspend",
        "arena", "arena-mb", "arena-test", "fexfail", "remote", "remote-batch", "d3d12",
        "apicensus", "shadow", "census", "wxprobe", "args", "valley-args",
        "jumbo-mb", "jumbo-keep-mb", "iat-noexec", "vmwatch", "no-local-read", "vsps-fill",
    ]

    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    static var url: URL? { documents?.appendingPathComponent(fileName) }
    static var present: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// All key/value pairs of madeira.cfg (empty when the file is absent).
    static func all() -> [String: String] {
        guard let u = url, let text = try? String(contentsOf: u, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    /// The value for `key`, trimmed, or nil when unset. Falls back to the legacy
    /// file ONLY when madeira.cfg does not exist.
    static func get(_ key: String) -> String? {
        if present { return all()[key] }
        guard let d = documents,
              let txt = try? String(contentsOf: d.appendingPathComponent("madeira-\(key).txt"), encoding: .utf8)
        else { return nil }
        return txt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bool(_ key: String, default dflt: Bool = false) -> Bool {
        guard let v = get(key) else { return dflt }
        return ["1", "on", "true", "yes"].contains(v)
    }

    /// ml1840: UI decisions and the launch worker must resolve the same flags.
    /// A newly supplied legacy env file is an explicit override until it has
    /// been imported; the canonical file takes over after verified migration.
    static func environmentValues() -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in all() where key.hasPrefix("env.") {
            let name = String(key.dropFirst(4))
            if allowedEnvironmentName(name) { values[name] = value }
        }
        if let d = documents, let text = try? String(contentsOf: d.appendingPathComponent("madeira-env.txt"), encoding: .utf8) {
            values.merge(parseEnvironment(text)) { _, latest in latest }
        }
        return values
    }
    static func allowedEnvironmentName(_ name: String) -> Bool {
        (name.hasPrefix("MADEIRA_") || name.hasPrefix("DXMT_")) &&
            name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if allowedEnvironmentName(name), !value.contains("\0") { result[name] = value }
        }
        return result
    }

    /// Preserve existing keys/comments and atomically append only overrides.
    /// MADEIRA_CONFIG_ENV_MERGE=0 retains the legacy file instead of migrating.
    @discardableResult
    static func mergeLegacyEnvironment(log: (String) -> Void) -> [String] {
        guard let d = documents, let u = url, present,
              environmentValues()["MADEIRA_CONFIG_ENV_MERGE"] != "0",
              let text = try? String(contentsOf: d.appendingPathComponent("madeira-env.txt"), encoding: .utf8),
              let original = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        let values = parseEnvironment(text), current = all()
        let changed = values.keys.filter { current["env." + $0] != values[$0] }.sorted()
        guard !changed.isEmpty else { return [] }
        do {
            let suffix = changed.map { "env.\($0) = \(values[$0]!)" }.joined(separator: "\n")
            try (original + "\n# Environment overrides imported by ml1840\n" + suffix + "\n")
                .write(to: u, atomically: true, encoding: .utf8)
            guard changed.allSatisfy({ all()["env." + $0] == values[$0] }) else { return [] }
            log("[config-env] ml1840 preserved \(changed.count) environment override(s) in madeira.cfg")
            return changed
        } catch {
            log("[config-env] ml1840 import failed; legacy environment file retained")
            return []
        }
    }

    /// One-time migration: with no madeira.cfg and at least one legacy file,
    /// write madeira.cfg from them. Legacy files are left in place (ignored from
    /// now on) so nothing is destroyed; the log names them so they can be deleted.
    /// Returns the keys that were migrated.
    @discardableResult
    static func migrateLegacy(log: (String) -> Void) -> [String] {
        if present { return mergeLegacyEnvironment(log: log) }
        guard let d = documents, let u = url, !present else { return [] }
        var lines = ["# Madeira configuration (ml1095): one file for every switch.",
                     "# key = value; lines starting with # are comments; the last line wins.",
                     "# Keys are the old file names without 'madeira-' and '.txt'.",
                     "# Environment exports: env.NAME = value. DXMT options: dxmt = a=b;c=d.",
                     ""]
        var migrated: [String] = []
        for key in legacyKeys {
            guard let txt = try? String(contentsOf: d.appendingPathComponent("madeira-\(key).txt"), encoding: .utf8) else { continue }
            let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(key) = \(v)")
            migrated.append(key)
        }
        if let txt = try? String(contentsOf: d.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
            let parts = txt.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if !parts.isEmpty { lines.append("dxmt = " + parts.joined(separator: ";")); migrated.append("dxmt") }
        }
        if let txt = try? String(contentsOf: d.appendingPathComponent("madeira-env.txt"), encoding: .utf8) {
            for raw in txt.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
                lines.append("env.\(line[..<eq]) = \(line[line.index(after: eq)...])")
            }
            migrated.append("env")
        }
        guard !migrated.isEmpty else { return [] }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: u, atomically: true, encoding: .utf8)
            log("madeira.cfg written from legacy files (\(migrated.joined(separator: ", "))); the madeira-*.txt files are now ignored and can be deleted")
        } catch {
            log("madeira.cfg could not be written: \(error)")
            return []
        }
        return migrated
    }

    /// Remove known legacy files only after verifying their canonical values
    /// (never logs, traces or the input map). Idempotent; conflicts are retained.
    /// Returns the names removed.
    @discardableResult
    static func deleteLegacyFiles(log: (String) -> Void) -> [String] {
        guard present, let d = documents else { return [] }
        var removed: [String] = []
        for name in legacyKeys.map({ "madeira-\($0).txt" }) + ["madeira-env.txt", "madeira-dxmt.txt"] {
            let u = d.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else { continue }
            // ml1840: existence of madeira.cfg is not proof this file's values
            // were imported. A write/read failure or conflict must retain it.
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let stored = all()
            if name == "madeira-env.txt" {
                let values = parseEnvironment(text)
                guard !values.isEmpty, values.allSatisfy({ stored["env." + $0.key] == $0.value }) else { continue }
            } else if name == "madeira-dxmt.txt" {
                let value = text.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: ";")
                guard stored["dxmt"] == value else { continue }
            } else {
                let key = String(name.dropFirst("madeira-".count).dropLast(4))
                guard stored[key] == text.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            }
            do { try FileManager.default.removeItem(at: u); removed.append(name) }
            catch { log("could not remove \(name): \(error)") }
        }
        if !removed.isEmpty { log("removed legacy config files (madeira.cfg is the one file now): " + removed.joined(separator: ", ")) }
        return removed
    }
}
