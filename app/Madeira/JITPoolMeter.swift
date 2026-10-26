// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The JIT pool's use for the performance overlay ("JIT 374/560 MB"), read from
/// the log lines the pool already writes: `JIT pool: RX=..., size=560MB` when it
/// is set up, and `[jit-pool] image ... used=0x../0x..` or
/// `[jit-pool] EXHAUSTED ... bump=0x../0x..` as code is loaded into it. Its size
/// changes from launch to launch (iPadOS decides how much contiguous space is free),
/// and a game that runs out of it stops: CS2 at the Valve logo on 2026-10-25 had
/// 560 MB of 896 MB and ran out loading v8.dll. LogStore feeds every line; the
/// overlay reads `text` once a second.
///
/// A split pool (`pool-split = 1`) is one span of pool offsets with one or two holes
/// that are never handed out (ntdll logs `[jit-pool] split pool: ... hole [0x..,0x..)`
/// and `[jit-pool] pool-mid: ... hole 2 [0x..,0x..)`). The span size and the end of
/// the latest allocation both include a hole once code sits above it, so the holes
/// come off both numbers and the text says "split". Lines about pool-low's region C
/// (`[pool-low] region C`) describe a separate region and are not counted.
enum JITPoolMeter {
    struct State: Equatable {
        var sizeMB: Int?
        var used: UInt64 = 0
        var total: UInt64 = 0
        var exhausted = 0
        var shrunk = false
        var holes: [Hole] = []
    }

    /// Pool offsets [start, end) that are never handed out.
    struct Hole: Equatable { var start: UInt64; var end: UInt64 }

    private static let lock = NSLock()
    private static var state = State()

    static func reset() { lock.lock(); state = State(); lock.unlock() }

    static var current: State { lock.lock(); defer { lock.unlock() }; return state }

    /// Cheap for lines that are not the pool's: one `contains` each.
    static func note(_ line: String) {
        guard line.contains("JIT pool: RX=") || line.contains("[jit-pool] ") || line.contains("no hole fits a ") else { return }
        lock.lock(); defer { lock.unlock() }
        state = next(state, line)
    }

    static func next(_ previous: State, _ line: String) -> State {
        var s = previous
        if line.contains("no hole fits a ") { s.shrunk = true }
        if let r = line.range(of: "JIT pool: RX="), let size = line[r.upperBound...].range(of: "size=") {
            s.sizeMB = Int(line[size.upperBound...].prefix { $0.isNumber })
        }
        if let r = line.range(of: "[jit-pool] ") {
            let rest = line[r.upperBound...]
            if rest.contains("[pool-low] region C") { return s }
            if rest.hasPrefix("split pool:") || rest.hasPrefix("pool-mid:"), !rest.contains("ignored"),
               let found = Self.hole(rest, after: rest.hasPrefix("split pool:") ? "hole [0x" : "hole 2 [0x"),
               !s.holes.contains(found) {
                s.holes.append(found)
                return s
            }
            if let pair = hexPair(rest, after: "used=0x") ?? hexPair(rest, after: "bump=0x") {
                s.used = pair.0
                if pair.1 > 0 { s.total = pair.1 }
            }
            if rest.contains("EXHAUSTED") { s.exhausted += 1 }
        }
        return s
    }

    /// "JIT 374/560 MB", "JIT FULL 560 MB" once it ran out, "(small)" / "(split)" notes;
    /// nil before the pool is set up. A split pool's holes are left out of both numbers.
    static func text(_ s: State) -> String? {
        let gap = s.holes.reduce(UInt64(0)) { $0 + ($1.end - $1.start) }
        let below = s.holes.reduce(UInt64(0)) { $0 + (min(s.used, $1.end) > $1.start ? min(s.used, $1.end) - $1.start : 0) }
        let span = s.total > 0 ? s.total : UInt64(s.sizeMB ?? 0) << 20
        guard s.total > 0 || s.sizeMB != nil else { return nil }
        let totalMB = Int((span - min(gap, span) + (1 << 19)) >> 20)
        let usedMB = Int((s.used - min(below, s.used) + (1 << 19)) >> 20)
        let notes = [s.shrunk ? "small" : nil, s.holes.isEmpty ? nil : "split"].compactMap { $0 }
        if s.exhausted > 0 { return "JIT FULL \(totalMB) MB" + (s.holes.isEmpty ? "" : " (split)") }
        return "JIT \(usedMB)/\(totalMB) MB" + (notes.isEmpty ? "" : " (" + notes.joined(separator: ", ") + ")")
    }

    /// "hole [0x1d000000,0x25000000)" -> Hole(0x1d000000, 0x25000000).
    static func hole(_ text: Substring, after marker: String) -> Hole? {
        guard let r = text.range(of: marker) else { return nil }
        let first = text[r.upperBound...].prefix { $0.isHexDigit }
        let rest = text[r.upperBound...].dropFirst(first.count)
        guard rest.hasPrefix(",0x"), let start = UInt64(first, radix: 16),
              let end = UInt64(rest.dropFirst(3).prefix { $0.isHexDigit }, radix: 16), end > start else { return nil }
        return Hole(start: start, end: end)
    }

    /// "used=0x78000/0x23000000" -> (0x78000, 0x23000000).
    static func hexPair(_ text: Substring, after marker: String) -> (UInt64, UInt64)? {
        guard let r = text.range(of: marker) else { return nil }
        let first = text[r.upperBound...].prefix { $0.isHexDigit }
        guard let a = UInt64(first, radix: 16) else { return nil }
        let rest = text[r.upperBound...].dropFirst(first.count)
        guard rest.hasPrefix("/0x") else { return (a, 0) }
        return (a, UInt64(rest.dropFirst(3).prefix { $0.isHexDigit }, radix: 16) ?? 0)
    }
}
