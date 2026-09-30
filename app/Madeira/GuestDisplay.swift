import Foundation

// The guest's virtual monitor and how it is laid out on the device's screen.
//
// A game renders for the virtual monitor win32u reports (build/win32u-unix/
// sysparams_ios.c): it starts at the session default from MADEIRA_SCREEN_W/H,
// and a game's ChangeDisplaySettings programs a new mode, which win32u
// publishes through winios_display_mode_changed() (IOSDisplayShim.m;
// MADEIRA_VIRTUAL_MODE_SET=0 keeps the session default). MetalBackedView reads the current size back (winios_screen_size) and places
// the presented layer with GameSurfaceLayout, so the layer's frame and the
// touch mapping always agree. A library entry chooses the monitor size
// (Resolution) and how it is scaled (Aspect & scaling); the developer
// interface keeps Fit.

/// How the guest surface is mapped into the view's bounds.
enum DisplayMode: String, CaseIterable {
    case fit, fill, stretch, aspect

    /// Older settings stored "fitHeight" (Fill height); it behaved as Fit in
    /// landscape and is gone from the picker, so it decodes to Fit.
    init?(rawValue: String) {
        switch rawValue {
        case "fit", "fitHeight": self = .fit
        case "fill": self = .fill
        case "stretch": self = .stretch
        case "aspect": self = .aspect
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .fit:       return "Fit"
        case .fill:      return "Fill"
        case .stretch:   return "Stretch"
        case .aspect:    return "Aspect"
        }
    }
    var symbol: String {
        switch self {
        case .fit:       return "aspectratio"
        case .fill:      return "arrow.up.left.and.arrow.down.right"
        case .stretch:   return "rectangle.expand.vertical"
        case .aspect:    return "rectangle.ratio.16.to.9"
        }
    }
}

/// Geometry shared by the presented layer's frame and the touch mapping: if
/// the two did their own aspect math, Fill and Stretch would skew input the
/// moment they disagreed by a rounding hair.
enum GameSurfaceLayout {
    /// The rect, in `bounds`'s coordinate space, that the guest surface
    /// occupies for `mode`.
    ///
    /// - Fit: the guest's shape, as large as fits, centred (letterbox).
    /// - Fill: the guest's shape, covering `bounds`; one axis overflows and
    ///   is cropped.
    /// - Stretch: exactly `bounds`.
    /// - Aspect: like Fit, but on the shape of what is actually presented
    ///   (`aspect`, the swapchain drawable, i.e. the game's back buffer). A
    ///   game whose back buffer is 4:3 on a 16:9 monitor is stretched by the
    ///   layer in every other mode; here it is scaled uniformly. Falls back to
    ///   the guest shape until a drawable size is known (`aspect == .zero`).
    static func rect(guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGRect {
        guard guest.width > 0, guest.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if mode == .stretch { return bounds }
        let useDrawable = mode == .aspect && aspect.width > 0 && aspect.height > 0
        let shape = useDrawable ? aspect : guest
        let sx = bounds.width / shape.width, sy = bounds.height / shape.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let w = shape.width * scale, h = shape.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// A point in `bounds`'s coordinate space (a touch) in guest pixels for
    /// `mode`, clamped to the guest surface; a touch in Fill's cropped margin
    /// clamps to the nearest edge.
    static func map(point: CGPoint, guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGPoint {
        let r = rect(guest: guest, aspect: aspect, bounds: bounds, mode: mode)
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (point.x - r.minX) * guest.width / r.width
        let y = (point.y - r.minY) * guest.height / r.height
        return CGPoint(x: min(max(x, 0), guest.width - 1),
                       y: min(max(y, 0), guest.height - 1))
    }
}

/// The session default of the guest's virtual monitor.
enum GuestDisplay {
    /// Standard modes a session default is chosen from when no size is given.
    static let standardModes: [(w: Int, h: Int)] = [
        (640, 480), (800, 600), (1024, 768), (1152, 864),
        (1280, 720), (1280, 768), (1280, 800), (1280, 960),
        (1280, 1024), (1360, 768), (1366, 768), (1440, 900),
        (1600, 900), (1600, 1200), (1680, 1050), (1920, 1080),
        (1920, 1200), (2048, 1536), (2560, 1440),
    ]

    /// The standard mode nearest a landscape view's shape, and among modes of
    /// effectively the same shape (0.9 to 2.1 megapixels) the cheapest: a
    /// 19.5:9 phone gets 1280x720, a 4:3 tablet 1152x864.
    static func defaultMode(forLandscapeView size: CGSize) -> (w: Int, h: Int) {
        let fallback = (w: 1280, h: 720)
        guard size.width > 0, size.height > 0 else { return fallback }
        let want = Double(max(size.width, size.height) / min(size.width, size.height))
        let candidates = standardModes.filter { m in
            let px = m.w * m.h
            return px >= 900_000 && px <= 2_100_000
        }
        guard !candidates.isEmpty else { return fallback }
        let error = { (m: (w: Int, h: Int)) in abs(Double(m.w) / Double(m.h) - want) }
        let best = candidates.map(error).min()!
        return candidates.filter { error($0) <= best + 0.01 }
                         .min { $0.w * $0.h < $1.w * $1.h }!
    }

    /// Chooses the session's virtual monitor and exports it for win32u, which
    /// reads MADEIRA_SCREEN_W/H (and MADEIRA_SCREEN_SRC for its log line) the
    /// first time the monitor is queried. `knob` is a "WxH" choice (a library
    /// entry's Resolution); without a valid one the default is the standard
    /// mode nearest the view's shape.
    ///
    /// The size is also published to IOSDisplayShim, so a layout that already
    /// ran re-reads it (MadeiraDisplayModeChangedNotification).
    @discardableResult
    static func configureSessionDefault(view: CGSize, knob: String?) -> (w: Int, h: Int, source: String) {
        var mode = defaultMode(forLandscapeView: view)
        var source = "view"
        if let raw = knob?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                mode = (w, h)
                source = "knob"
            }
        }
        setenv("MADEIRA_SCREEN_W", String(mode.w), 1)
        setenv("MADEIRA_SCREEN_H", String(mode.h), 1)
        setenv("MADEIRA_SCREEN_SRC", source, 1)
        winios_display_mode_changed(Int32(mode.w), Int32(mode.h))
        return (mode.w, mode.h, source)
    }
}
