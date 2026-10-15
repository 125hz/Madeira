// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). The app-side orchestration that runs
// ONE Wine process in the MadeiraProcessHost extension for the opt-in smoke test.
// Nothing here runs unless the owner asks:
//   env.MADEIRA_EXT_PROCESS = 0           kill switch for the whole feature
//   env.MADEIRA_EXT_PROCESS_TEST = 1      run `cmd.exe /c echo remote-ok` once at session start
// Each step logs an "[ext-proc] ml1330 …" line.

import Foundation

@MainActor
enum MadeiraExtProcess {
    /// Kill switch: the whole process-host feature is off when env.MADEIRA_EXT_PROCESS = 0.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_EXT_PROCESS", fallback: true) }

    /// Kept alive while the test runs.
    private static var session: MadeiraProcessHostSession?

    /// Called once per session start (ContentView.runWineFullSequence), after the probe.
    static func runTestIfRequested() {
        guard enabled else { return }
        guard MadeiraConfig.flag("MADEIRA_EXT_PROCESS_TEST", fallback: false) else { return }
        if let reason = MadeiraBuiltInJIT.unavailableReason {
            LogStore.shared.log("[ext-proc] ml1330 skipped: \(reason)")
            return
        }
        LogStore.shared.log("[ext-proc] ml1330 test: starting MadeiraProcessHost (cmd.exe /c echo remote-ok)")

        let s = MadeiraProcessHostSession()
        s.logger = { line in LogStore.shared.log("[ext-proc] ml1330 \(line)") }
        session = s

        s.start { pid in
            DispatchQueue.main.async { continueAfterStart(pid: pid) }
        }
    }

    private static func continueAfterStart(pid: Int32) {
        guard session != nil else { return }
        guard pid > 0 else {
            LogStore.shared.log("[ext-proc] ml1330 test: the extension did not start; nothing ran", level: .error)
            session = nil
            return
        }
        // Enable JIT for the EXTENSION's pid through the JIT helper (StikJIT.enableJIT
        // takes a target pid). The helper attaches and runs Madeira's script; the pool
        // request the extension makes is a BRK the attached debugger answers. The enable
        // request stays open as long as the debugger is attached, so we proceed from the
        // `started` callback rather than its completion.
        guard let pairing = try? JITPairingFileStore.data(),
              let script = StikJITHelper.scriptData else {
            LogStore.shared.log("[ext-proc] ml1330 test: no pairing file or JIT script; cannot enable JIT for the extension",
                                level: .error)
            session = nil
            return
        }
        LogStore.shared.log("[ext-proc] ml1330 enabling JIT for the extension pid=\(pid)")
        MadeiraBuiltInJIT.send(
            .enable(targetPID: pid, pairingData: pairing, scriptBase64: script.base64EncodedString()),
            started: {
                // The helper is attaching to the extension. Give it a moment, then
                // prepare the guest; prepareGuest checks CS_DEBUGGED in the extension and
                // reports honestly if the debugger has not landed yet.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                    prepareAndRun()
                }
            },
            completion: { result in
                if case .failure(let error) = result {
                    LogStore.shared.log("[ext-proc] ml1330 JIT enable for the extension failed: \(error.localizedDescription)",
                                        level: .error)
                }
            })
    }

    private static func prefixPath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("wine").path
    }

    private nonisolated static func prepareAndRun() {
        DispatchQueue.main.async {
            guard let s = session else { return }
            let argv = ["wine", "C:\\windows\\system32\\cmd.exe", "/c", "echo remote-ok"]
            // A clean environment: no MADEIRA_FASTSYNC and no inproc-sync, so the remote
            // process runs plain server synchronisation (fastsync/madsync are process
            // memory, not coherent across iOS tasks).
            let env: [String] = []
            s.prepareGuest(withArgv: argv, env: env, prefix: prefixPath()) { ok, stage, error in
                DispatchQueue.main.async {
                    if !ok {
                        LogStore.shared.log("[ext-proc] ml1330 test: prepare failed at stage \(stage): \(error ?? "")",
                                            level: .error)
                        return
                    }
                    s.startGuest { ok2, stage2, error2 in
                        DispatchQueue.main.async {
                            if ok2 {
                                LogStore.shared.log("[ext-proc] ml1330 test: remote process started (stage \(stage2)); "
                                    + "watch the extension's madeira-ext-log.txt for 'remote-ok' / the guest exit code",
                                    level: .success)
                            } else {
                                LogStore.shared.log("[ext-proc] ml1330 test: start failed at stage \(stage2): \(error2 ?? "")",
                                                    level: .error)
                            }
                        }
                    }
                }
            }
        }
    }
}
