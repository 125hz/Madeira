// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import ExtensionFoundation
import Foundation
import XPC

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var madeiraJITHelper: AppExtensionPoint {
        Name("MadeiraJITHelper")
    }
}

@available(iOS 26.0, *)
private final class MadeiraJITExtensionSession {
    let process: AppExtensionProcess
    let session: XPCSession

    init(process: AppExtensionProcess, session: XPCSession) {
        self.process = process
        self.session = session
    }

    deinit {
        session.cancel(reason: "Madeira JIT request finished")
        process.invalidate()
    }
}

/// Starts the separate helper process required to debug Madeira without
/// deadlocking Madeira itself.
@MainActor
enum MadeiraBuiltInJIT {
    @available(iOS 26.0, *)
    private static var activeSession: MadeiraJITExtensionSession?

    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return "Built-in JIT is available only on a physical device."
#else
        guard #available(iOS 26.0, *) else {
            return "Built-in JIT requires iOS 26 or later."
        }
        if getenv("LC_HOME_PATH") != nil {
            return "Built-in JIT is unavailable inside LiveContainer. Choose StikDebug instead."
        }
        return nil
#endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    static func send(_ request: MadeiraJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<MadeiraJITRequest.Response, Error>) -> Void) {
        guard unavailableReason == nil else {
            completion(.failure(NSError(
                domain: "MadeiraBuiltInJIT", code: 1,
                userInfo: [NSLocalizedDescriptionKey: unavailableReason ?? "Built-in JIT is unavailable."])))
            return
        }
        guard #available(iOS 26.0, *) else { return }

        Task { @MainActor in
            do {
                let monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .madeiraJITHelper)
                guard let identity = monitor.identities.first else {
                    throw NSError(
                        domain: "MadeiraBuiltInJIT", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Madeira's JIT helper was not found in this installation. Reinstall Madeira."])
                }
                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity,
                    onInterruption: { activeSession = nil }))
                let session = try process.makeXPCSession()
                try session.activate()
                activeSession = MadeiraJITExtensionSession(process: process, session: session)
                started()
                try session.send(request) {
                    (result: Result<MadeiraJITRequest.Response, any Error>) in
                    Task { @MainActor in
                        activeSession = nil
                        completion(result.mapError { $0 as Error })
                    }
                }
            } catch {
                activeSession = nil
                completion(.failure(error))
            }
        }
    }
}
