// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
import Foundation
import Darwin

@MainActor
enum MadeiraExtProcess {
    // 1: enable owned Wine app-extension clients; default off (ml1331).
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_EXT_PROCESS", fallback: false) }
    private struct Launch {
        let session: MadeiraProcessHostSession
        let fd: Int32
        let cwd: Int32
        let done: (Bool) -> Void
    }
    private static var pending: [UUID: Launch] = [:]
    private static var running: [UUID: MadeiraProcessHostSession] = [:]

    static func runTestIfRequested() {
        guard enabled else { madeira_process_host_set_spawn_handler(nil); return }
        madeira_process_host_set_spawn_handler { argv, env, fd, cwd, done in
            // The block's descriptors are borrowed. Duplicate before crossing queues.
            let socket = dup(fd), directory = cwd < 0 ? -1 : dup(cwd)
            guard socket >= 0, cwd < 0 || directory >= 0 else {
                if socket >= 0 { close(socket) }; done(false); return
            }
            DispatchQueue.main.async {
                begin(argv: argv, env: env, fd: socket, cwd: directory, done: done)
            }
        }
        // 1: exec-child cmd smoke test; steam: installed x64 full client (ml1331).
        guard let test = MadeiraConfig.get("env.MADEIRA_EXT_PROCESS_TEST") ?? getenv("MADEIRA_EXT_PROCESS_TEST").map({ String(cString: $0) }),
              test == "1" || test.lowercased() == "steam" else { return }
        awaitSession(test: test.lowercased(), attempt: 0)
    }

    private static func awaitSession(test: String, attempt: Int) {
        guard enabled else { return }
        guard MadeiraSession.available else {
            if attempt < 60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { awaitSession(test: test, attempt: attempt + 1) }
            } else { LogStore.shared.log("[ext-proc] ml1331 test refused: no running desktop session") }
            return
        }
        guard MadeiraConfig.get("inproc-sync") != "1" else {
            LogStore.shared.log("[ext-proc] ml1331 test refused: inproc-sync=1 uses app memory"); return
        }
        let command: String
        let folder: String
        if test == "steam" {
            guard let path = WindowedSteam.readyClient else {
                LogStore.shared.log("[ext-proc] ml1331 test refused: install the x64 full client first"); return
            }
            let windows = path.contains(":") ? path : "C:\\" + path.replacingOccurrences(of: "/", with: "\\")
            folder = String(windows.prefix(upTo: windows.lastIndex(of: "\\")!))
            command = "\"" + windows + "\" -nobootstrapperupdate -skipinitialbootstrap -norepairfiles -noverifyfiles -no-cef-sandbox"
        } else {
            command = "\"C:\\windows\\system32\\cmd.exe\" /c echo remote-ok"
            folder = "C:\\windows\\system32"
        }
        LogStore.shared.log("[ext-proc] ml1331 test: launcher exec-child requested (\(test))")
        MadeiraSession.launch(commandLine: command, workingDirectory: folder, remote: true) { result in
            LogStore.shared.log("[ext-proc] ml1331 launcher result: \(result.ok ? "ok" : "error") \(result.reason)")
        }
    }

    private static func finish(_ id: UUID, ok: Bool, reason: String) {
        guard let launch = pending.removeValue(forKey: id) else { return }
        if !ok { shutdown(launch.fd, SHUT_RDWR); launch.session.invalidate() }
        else { running[id] = launch.session }
        close(launch.fd); if launch.cwd >= 0 { close(launch.cwd) }
        LogStore.shared.log("[ext-proc] ml1331 spawn \(ok ? "ok" : "error"): \(reason)")
        launch.done(ok)
    }

    private static func begin(argv: [String], env: [String], fd: Int32, cwd: Int32, done: @escaping (Bool) -> Void) {
        guard enabled, MadeiraConfig.flag("MADEIRA_SHARED_DRIVE", fallback: false),
              let prefix = madeira_process_host_shared_prefix(LibraryModel.documents.appendingPathComponent("wine").path),
              let pairing = try? JITPairingFileStore.data(), let script = StikJITHelper.scriptData,
              MadeiraBuiltInJIT.unavailableReason == nil else {
            shutdown(fd, SHUT_RDWR); close(fd); if cwd >= 0 { close(cwd) }
            LogStore.shared.log("[ext-proc] ml1331 spawn refused: shared prefix or JIT helper unavailable")
            done(false); return
        }
        let id = UUID(), session = MadeiraProcessHostSession()
        session.logger = { line in LogStore.shared.log("[ext-proc] ml1330 " + line) }
        session.exitHandler = { _ in DispatchQueue.main.async { running[id] = nil } }
        pending[id] = Launch(session: session, fd: fd, cwd: cwd, done: done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { finish(id, ok: false, reason: "extension startup timed out") }
        DispatchQueue.global(qos: .userInitiated).async {
            session.start { pid in
                DispatchQueue.main.async {
                    guard pending[id] != nil else { session.invalidate(); return }
                    guard pid > 0 else { finish(id, ok: false, reason: "extension did not start"); return }
                    LogStore.shared.log("[ext-proc] ml1330 enabling JIT for the extension pid=\(pid)")
                    MadeiraBuiltInJIT.send(.enable(targetPID: pid, pairingData: pairing, scriptBase64: script.base64EncodedString()),
                        started: {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                guard pending[id] != nil else { return }
                                session.prepareGuest(withArgv: argv, socketFD: fd, directoryFD: cwd, env: env, prefix: prefix) { ok, stage, error in
                                    DispatchQueue.main.async {
                                        guard pending[id] != nil else { return }
                                        guard ok else { finish(id, ok: false, reason: "prepare stage \(stage): \(error ?? "failed")"); return }
                                        session.startGuest { started, stage, error in
                                            DispatchQueue.main.async { finish(id, ok: started, reason: "start stage \(stage): \(error ?? "ready")") }
                                        }
                                    }
                                }
                            }
                        }, completion: { result in
                            if case .failure(let error) = result {
                                DispatchQueue.main.async { finish(id, ok: false, reason: error.localizedDescription) }
                            }
                        })
                }
            }
        }
    }
}
