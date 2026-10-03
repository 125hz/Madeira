// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Getting this device's own network path ready for JIT (docs/JIT.md).
//
// Built-in StikJIT and StikDebug reach this device's lockdownd through
// LocalDevVPN's loopback, which works on Wi-Fi or with no network at all but
// not over cellular data. Enable JIT first checks the loopback directly
// (LoopbackProbe, milliseconds when it works). Only when that fails, and the
// Madeira JIT shortcut is turned on, does Madeira run the shortcut to turn
// Cellular Data off (when there is no Wi-Fi) and connect LocalDevVPN; once a
// game's JIT pool is mapped and the debugger has left, it runs it again to put
// both back. Log tags: [jit-loopback], [jit-shortcut].

import Darwin
import Foundation
import Network
import UIKit

/// Whether LocalDevVPN's loopback reaches this device's lockdownd, at
/// 10.7.0.1:62078 (the address StikDebug uses). A connection alone proves
/// nothing (a proxy or another VPN can accept any connection), so it sends
/// lockdownd's QueryType request, which needs no pairing, and counts only a
/// reply naming com.apple.mobile.lockdown. Through a working tunnel that takes
/// milliseconds; with the VPN off, or over cellular data, it is refused or times
/// out. The connection is closed at once.
enum LoopbackProbe {
    static let address = "10.7.0.1"
    static let port: UInt16 = 62078

    struct Result {
        let reachable: Bool
        let milliseconds: Double
        let detail: String
    }

    private static let queryType = Array(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<plist version=\"1.0\"><dict><key>Label</key><string>Madeira</string>"
        + "<key>Request</key><string>QueryType</string></dict></plist>\n").utf8)

    /// Blocks for at most `timeout`; use `check(timeout:completion:)` from the main thread.
    static func check(timeout: TimeInterval = 0.4) -> Result {
        let start = CFAbsoluteTimeGetCurrent()
        func done(_ ok: Bool, _ detail: String) -> Result {
            Result(reachable: ok, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000, detail: detail)
        }
        func remainingMs() -> Int32 { max(1, Int32((start + timeout - CFAbsoluteTimeGetCurrent()) * 1000)) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return done(false, "bad address") }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return done(false, "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return done(false, String(cString: strerror(errno))) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, remainingMs())
            guard ready > 0 else { return done(false, ready == 0 ? "timed out" : String(cString: strerror(errno))) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return done(false, String(cString: strerror(err))) }
        }
        // lockdownd's framing: a big-endian length, then the plist.
        let message = withUnsafeBytes(of: UInt32(queryType.count).bigEndian, Array.init) + queryType
        guard message.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == message.count else {
            return done(false, "send: \(String(cString: strerror(errno)))")
        }
        var reply: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 2048)
        while reply.count < 16384 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMs())
            guard ready > 0 else { return done(false, ready == 0 ? "connected, no lockdownd reply" : String(cString: strerror(errno))) }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return done(false, "connected, closed without a lockdownd reply") }
            reply += chunk[0..<n]
            if String(decoding: reply, as: UTF8.self).contains("com.apple.mobile.lockdown") {
                return done(true, "lockdownd answered")
            }
        }
        return done(false, "connected, not lockdownd")
    }

    static func check(timeout: TimeInterval = 0.4, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = check(timeout: timeout)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Checks again until the loopback answers or `within` seconds pass: a VPN that
    /// was just connected needs a moment before it routes.
    static func waitUntilReachable(within: TimeInterval, completion: @escaping @MainActor (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = CFAbsoluteTimeGetCurrent() + within
            var result = check(timeout: 0.4)
            while !result.reachable, CFAbsoluteTimeGetCurrent() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                result = check(timeout: 0.4)
            }
            let final = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(final) } }
        }
    }

    /// Whether an interface holds an address in LocalDevVPN's 10.7.0.0/24, i.e. its
    /// VPN is connected (whether or not it routes). Instant: no network traffic.
    static var vpnInterfaceUp: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if ip >> 8 == 0x0A0700 { return true }       // 10.7.0.x
            }
            cursor = entry.pointee.ifa_next
        }
        return false
    }
}

/// The user's "Madeira JIT" shortcut (docs/JIT.md has its steps). Input "start",
/// with "cellular" when Madeira sees cellular data and no Wi-Fi: turn Cellular Data
/// off (only then) and connect LocalDevVPN. Input "done", with "cellular" and/or
/// "vpn": turn Cellular Data back on and/or disconnect LocalDevVPN. Madeira decides
/// both from what it saw before "start", so "done" only undoes what "start" changed.
///
/// An app can only run a shortcut by opening the Shortcuts app, so each run leaves
/// Madeira for a moment and comes back through x-callback-url
/// (madeira://jit-network/...). Off unless Settings › JIT › Madeira JIT shortcut
/// turns it on (madeira.cfg env.MADEIRA_JIT_SHORTCUT = 1): without the shortcut the
/// Shortcuts app would only report that it is missing.
@MainActor final class JITNetworkShortcut: ObservableObject {
    static let shared = JITNetworkShortcut()
    static let name = "Madeira JIT"

    /// Settings › JIT › Madeira JIT shortcut: when LocalDevVPN's loopback does not answer,
    /// Enable JIT runs the shortcut. Off unless it is 1.
    @Published var enabled = MadeiraConfig.flag("MADEIRA_JIT_SHORTCUT", fallback: false) {
        didSet {
            guard enabled != oldValue else { return }
            MadeiraConfig.set("env.MADEIRA_JIT_SHORTCUT", enabled ? "1" : nil)
            LogStore.shared.log("[jit-shortcut] setting on=\(enabled ? 1 : 0)")
        }
    }

    enum Outcome { case done(String), failed(String) }

    /// Cellular data is carrying traffic and there is no Wi-Fi: the case LocalDevVPN's
    /// loopback cannot work in. From the system's network path, kept current.
    var cellularOnly: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
    }
    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "madeira.jit-network.path"))
    }

    /// What "done" has to undo; nil when the shortcut changed nothing. Read and
    /// cleared only on the main thread.
    private var restore: (cellular: Bool, vpn: Bool)?
    private var waiting: ((Outcome) -> Void)?
    private var timeout: Timer?

    /// Runs "start". `vpnWasUp`: LocalDevVPN was already connected, so "done" leaves it.
    func start(vpnWasUp: Bool, completion: @escaping (Outcome) -> Void) {
        let cellular = cellularOnly
        run(cellular ? "start cellular" : "start") { [weak self] outcome in
            if case .done = outcome, cellular || !vpnWasUp { self?.restore = (cellular, !vpnWasUp) }
            completion(outcome)
        }
    }

    /// Runs "done" when "start" changed anything, then calls `completion`.
    func restoreIfNeeded(completion: @escaping () -> Void) {
        guard let restore else { completion(); return }
        self.restore = nil
        run("done" + (restore.cellular ? " cellular" : "") + (restore.vpn ? " vpn" : "")) { _ in completion() }
    }

    /// From the launch thread, right after the debugger detached: runs "done" if
    /// needed and blocks until Madeira is back (or `timeout` passes). Nothing draws
    /// yet at that point, so the moment in the background is safe.
    nonisolated static func restoreBlocking(timeout: TimeInterval = 30) {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.restoreIfNeeded { finished.signal() } }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            LogStore.shared.log("[jit-shortcut] done did not return within \(Int(timeout)) s; continuing", level: .error)
        }
    }

    private func run(_ input: String, completion: @escaping (Outcome) -> Void) {
        finish(.failed("superseded"))
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: Self.name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "madeira://jit-network/success"),
            URLQueryItem(name: "x-error", value: "madeira://jit-network/error"),
            URLQueryItem(name: "x-cancel", value: "madeira://jit-network/cancel")
        ]
        guard let url = c.url else { completion(.failed("bad shortcut URL")); return }
        LogStore.shared.log("[jit-shortcut] run input=\(input)")
        waiting = completion
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failed("the shortcut did not return within 60 s")) }
        }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened { MainActor.assumeIsolated { self?.finish(.failed("Shortcuts could not be opened")) } }
        }
    }

    /// madeira://jit-network/{success|error|cancel}, from Shortcuts' x-callback-url.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "madeira", url.host == "jit-network" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value ?? "" }
        switch url.path {
        case "/success": finish(.done(value("result")))
        case "/error":   finish(.failed(value("errorMessage").isEmpty ? "the shortcut failed" : value("errorMessage")))
        default:         finish(.failed("the shortcut was cancelled"))
        }
        return true
    }

    private func finish(_ outcome: Outcome) {
        timeout?.invalidate()
        timeout = nil
        guard let waiting else { return }
        self.waiting = nil
        switch outcome {
        case .done(let result): LogStore.shared.log("[jit-shortcut] returned result=\(result.isEmpty ? "-" : result)")
        case .failed(let why):  LogStore.shared.log("[jit-shortcut] failed: \(why)", level: .error)
        }
        waiting(outcome)
    }
}
