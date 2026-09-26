import Foundation

// ml1960: apply installation metadata inside the user's Wine prefix before
// Wine starts. This does not execute Run Process or mark a prerequisite done.
enum SteamInstallRegistry {
    struct Value: Equatable {
        var hive: SteamInstallRun.Hive
        var key: String
        var name: String
        var encoded: String
    }

    static func values(_ data: Data, installPath: String, steamPath: String, language: String = "english") throws -> [Value] {
        guard data.count <= SteamInstallScripts.maxScriptBytes,
              let decoded = String(data: data, encoding: .utf8) else { throw SteamFileError.invalid("Invalid install metadata.") }
        let text = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
        let pattern = #"//[^\r\n]*|"(?:\\.|[^"\\])*"|[{}]|[^\s{}"]+"#
        let expression = try NSRegularExpression(pattern: pattern)
        let textRange = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: textRange)
        guard matches.count <= 100_000 else { throw SteamFileError.invalid("Install metadata is too large.") }
        var path: [String] = [], pending: String?, result: [Value] = []
        func clean(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        func decode(_ s: String) -> String {
            guard s.hasPrefix("\"") else { return s }
            let bytes = Array(s.dropFirst().dropLast().utf8)
            var decoded: [UInt8] = [], i = 0
            while i < bytes.count {
                if bytes[i] == 92, i + 1 < bytes.count, bytes[i + 1] == 92 || bytes[i + 1] == 34 { i += 1 }
                decoded.append(bytes[i]); i += 1
            }
            return String(decoding: decoded, as: UTF8.self)
        }
        func expand(_ s: String) -> String? {
            var value = s
            for (key, replacement) in [("INSTALLDIR", installPath), ("STEAMPATH", steamPath), ("ROOTDRIVE", "C"), ("WINDIR", "C:\\windows")] {
                value = value.replacingOccurrences(of: "%\(key)%", with: replacement, options: .caseInsensitive)
            }
            return value.contains("%") || !clean(value) ? nil : value
        }
        var consumed = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            guard text[consumed..<range.lowerBound].allSatisfy(\.isWhitespace) else { throw SteamFileError.invalid("Invalid install metadata token.") }
            consumed = range.upperBound
            let raw = String(text[range])
            if raw.hasPrefix("//") { continue }
            if raw == "{" {
                guard let key = pending, path.count < 16 else { throw SteamFileError.invalid("Invalid install metadata section.") }
                path.append(key); pending = nil
            } else if raw == "}" {
                guard !path.isEmpty, pending == nil else { throw SteamFileError.invalid("Incomplete install metadata.") }
                path.removeLast()
            } else if let name = pending {
                pending = nil
                let value = decode(raw)
                guard path.count == 4 || path.count == 5,
                      path[0].lowercased() == "installscript", path[1].lowercased() == "registry",
                      path.count == 4 || path[4].caseInsensitiveCompare(language) == .orderedSame,
                      let (hive, key) = SteamInstallScripts.hive(path[2]), !key.isEmpty,
                      clean(key), !key.contains("]"), clean(name), clean(value) else { continue }
                let encoded: String
                switch path[3].lowercased() {
                case "string":
                    guard let expanded = expand(value) else { continue }
                    encoded = "\"" + SteamInstallScripts.escape(expanded) + "\""
                case "dword":
                    guard let number = UInt32(value) else { continue }
                    encoded = String(format: "dword:%08x", number)
                default: continue
                }
                result.append(Value(hive: hive, key: key, name: name.lowercased() == "(default)" ? "" : name, encoded: encoded))
            } else { pending = decode(raw) }
        }
        guard path.isEmpty, pending == nil, text[consumed...].allSatisfy(\.isWhitespace) else { throw SteamFileError.invalid("Incomplete install metadata.") }
        return result
    }

    static func applying(_ values: [Value], to text: String, now: Int) -> (String, Int) {
        var lines = text.components(separatedBy: "\n"), changed = 0
        for value in values {
            let run = SteamInstallRun(name: value.name, hive: value.hive, key: value.key, value: 0)
            for key in SteamInstallScripts.keys(run) {
                let header = "[" + SteamInstallScripts.escape(key) + "]"
                let lhs = value.name.isEmpty ? "@=" : "\"" + SteamInstallScripts.escape(value.name) + "\"="
                let line = lhs + value.encoded
                if let start = lines.firstIndex(where: {
                    $0.caseInsensitiveCompare(header) == .orderedSame || $0.lowercased().hasPrefix(header.lowercased() + " ")
                }) {
                    var end = start + 1
                    while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                    if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(lhs.lowercased()) }) {
                        if lines[index] == line { continue }
                        lines[index] = line
                    } else { lines.insert(line, at: end) }
                } else { lines += ["", header + " \(now)", line, ""] }
                changed += 1
            }
        }
        return (lines.joined(separator: "\n"), changed)
    }

    static func prepare(folder: URL, drive: URL, steamRoot: URL) throws -> Int {
        guard let relative = SteamPaths.relative(folder, drive: drive),
              let steamRelative = SteamPaths.relative(steamRoot, drive: drive),
              SteamPaths.safeRelative(relative, under: drive) != nil else { return 0 }
        let windows = "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        let steam = "C:\\" + steamRelative.replacingOccurrences(of: "/", with: "\\")
        var entries: [Value] = []
        for file in SteamInstallScripts.scripts(folder: folder, depth: 2) {
            let data = try Data(contentsOf: file)
            guard String(decoding: data, as: UTF8.self).range(of: "registry", options: .caseInsensitive) != nil else { continue }
            entries += try values(data, installPath: windows, steamPath: steam)
        }
        var total = 0
        for (hive, name) in [(SteamInstallRun.Hive.machine, "system.reg"), (.user, "user.reg")] {
            let selected = entries.filter { $0.hive == hive }
            guard !selected.isEmpty else { continue }
            let url = drive.deletingLastPathComponent().appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.hasPrefix("WINE REGISTRY Version 2") else { throw SteamFileError.invalid("Wine's registry is not ready.") }
            let (updated, changed) = applying(selected, to: text, now: Int(Date().timeIntervalSince1970))
            if changed > 0 { try Data(updated.utf8).write(to: url, options: .atomic) }
            total += changed
        }
        return total
    }
}
