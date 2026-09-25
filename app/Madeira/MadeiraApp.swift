import SwiftUI

@main
struct MadeiraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear { GamepadInput.shared.start() }
        }
    }
}
