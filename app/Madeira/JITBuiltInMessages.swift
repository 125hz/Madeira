// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Codable messages shared by Madeira and its iOS 26 JIT helper extension.
struct MadeiraJITRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case prepare
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    static func prepare(pairingData: Data) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .prepare, targetPID: nil,
                          pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .enable, targetPID: targetPID,
                          pairingData: pairingData, scriptBase64: scriptBase64)
    }

    static var resetDDI: MadeiraJITRequest {
        MadeiraJITRequest(operation: .resetDDI, targetPID: nil,
                          pairingData: nil, scriptBase64: nil)
    }

    struct Response: Codable, Sendable {
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
