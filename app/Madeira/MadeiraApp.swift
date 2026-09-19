import SwiftUI
import GameController

/// ml1001: the SwiftUI half of `GamepadEventClaim` (ContentView.swift). From
/// iOS 18 SwiftUI routes game-controller input into its own focus system unless
/// the hierarchy says it consumes the pad through GameController; without this
/// the analogue sticks reach the app only in brief bursts while buttons arrive
/// normally. Older systems have neither the behaviour nor the modifier.
private struct ClaimGamepadEvents: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else {
            content
        }
    }
}

@main
struct MadeiraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
        }
    }
}
