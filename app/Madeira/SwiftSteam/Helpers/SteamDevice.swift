// Derived from Jfishin's Madeira Steam client (https://github.com/Jfishin),
// published in Madeira with the author's permission. Adapted for Madeira;
// see STEAM_INTEGRATION.md and THIRD-PARTY-NOTICES.md.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform device name — `Host.current()` doesn't exist on iOS.
enum SteamDevice {
    static var name: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "SwiftSteam"
        #endif
    }
}
