import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log
import GameController

// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// How the guest surface (the fixed-resolution virtual display games render
/// into — see `MetalBackedView.guestSize()`) is mapped into the live view's
/// bounds. A tap on `displayModeToggle` (ContentView) cycles Fit -> Fill ->
/// Stretch -> Fit and the choice persists via InputSettings.
enum DisplayMode: String, CaseIterable {
    case fit, fill, stretch, aspect, fitHeight

    var label: String {
        switch self {
        case .fit:     return "Fit"
        case .fill:    return "Fill"
        case .stretch: return "Stretch"
        case .aspect:  return "Aspect"
        case .fitHeight: return "Fill height"
        }
    }
    var symbol: String {
        switch self {
        case .fit:     return "aspectratio"
        case .fill:    return "arrow.up.left.and.arrow.down.right"
        case .stretch: return "rectangle.expand.vertical"
        case .aspect:  return "rectangle.ratio.16.to.9"
        case .fitHeight: return "arrow.up.and.down.square"
        }
    }
    var next: DisplayMode {
        switch self {
        case .fit:     return .fill
        case .fill:    return .stretch
        case .stretch: return .aspect
        case .aspect:  return .fitHeight
        case .fitHeight: return .fit
        }
    }
}

/// Fullscreen is a MODE the user enters with a button (ContentView's
/// fullscreenToggle, or the HUD cluster's exit button in TouchControlsOverlay)
/// — never a side effect of rotation, size class, or `UIDevice.current.
/// orientation`. It governs three things that all used to be keyed on
/// "landscape" (a proxy that broke on iPad — see ContentView.body): whether
/// MetalBackedView clamps Fill/Fill-height to Aspect (effectiveDisplayMode),
/// whether TouchControlsOverlay shows the movable HUD cluster + on-screen
/// controls, and whether ControlsWindow's hit-test lets the HUD cluster (and
/// its edit mode) claim the screen.
///
/// Deliberately NOT persisted — the spec is explicit that the app always
/// starts in the normal view — so this is a bare in-memory flag, not routed
/// through InputSettings' UserDefaults-backed JSON blob.
final class FullscreenState: ObservableObject {
    static let shared = FullscreenState()

    @Published var active = false {
        didSet {
            guard oldValue != active else { return }
            // The surface must re-lay-out for the new bounds/clamp rule the
            // instant this flips, exactly like a display-mode change does.
            MetalBackedView.refreshDisplayMode(reason: active ? "fullscreen-enter" : "fullscreen-exit")
            // ml: a stale `editing == true` left over from the HUD cluster's
            // pencil button used to survive a rotation/exit and make
            // ControlsWindow.hitTest (below) claim the ENTIRE screen — even
            // the launch row and log console in the normal view — because
            // TouchControlsOverlay's full-bounds gesture becomes reachable
            // the moment hitTest forwards to it. That is "sometimes pressing
            // a launch button does nothing" for real: whether it reproduces
            // depended entirely on whether the user had previously opened
            // edit mode. Force it closed the moment fullscreen ends so a
            // stale flag can never outlive the mode it only makes sense in.
            if !active {
                TouchControlsModel.shared.editing = false
                TouchControlsModel.shared.selected = nil
            }
            // ml — see ControlOverlayView.dropRegions' doc comment: each
            // mode has its own region-id namespace ("portrait." for the key
            // row, "ctl." for fullscreen's user-placed controls). Drop
            // whichever does NOT belong to the mode just entered, so a
            // region whose owning view's `.onDisappear` lost the race can
            // never keep claiming screen space — and therefore stealing
            // touches from the live view — in the mode that follows it.
            ControlOverlayView.shared.dropRegions(unless: { id in
                active ? id.hasPrefix("ctl.") : id.hasPrefix("portrait.")
            })
        }
    }
    private init() {}
}

/// Geometry shared by two things that must never disagree: the frame the
/// presented layer's host view is given (MetalBackedView.gameRect(), which
/// sizes MetalHostView.shared directly — see applyDisplayModeAndLog) and
/// where a touch point lands on the guest surface (`mapTouch`). If layout
/// and touch mapping each did their own aspect math, Fill/Stretch would skew
/// input the moment they disagreed by a rounding hair.
enum GameSurfaceLayout {
    /// The rect, in the same coordinate space as `bounds`, that the guest
    /// surface occupies for `mode`. Fit/Fill preserve the guest aspect ratio
    /// and center the result — Fill's rect can extend beyond `bounds` on one
    /// axis (that IS the fill: the host view is sized to this rect directly,
    /// so it genuinely covers more than `bounds` there; mapTouch below clamps
    /// a touch landing in that extra margin to the surface edge). Stretch is
    /// exactly `bounds`.
    static func rect(guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGRect {
        guard guest.width > 0, guest.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if mode == .stretch { return bounds }
        // Aspect: letterbox on the shape of what is actually PRESENTED (the
        // swapchain drawable, i.e. the game's back buffer), not the virtual
        // monitor. A game whose back buffer is 4:3 on a 16:9 monitor is
        // stretched by the layer in every other mode; here the host view takes
        // the drawable's aspect so the layer scales it uniformly. Falls back to
        // Fit until the swapchain has published a drawable size.
        // Fit height: keep the presented aspect and always fill the view's
        // full height, so a landscape game gets side bars but never top/bottom
        // bars (a wider-than-view result is centred and cropped at the sides).
        let useDrawable = (mode == .aspect || mode == .fitHeight) && aspect.width > 0 && aspect.height > 0
        let shape = useDrawable ? aspect : guest
        let sx = bounds.width / shape.width, sy = bounds.height / shape.height
        let scale = mode == .fill ? max(sx, sy) : (mode == .fitHeight ? sy : min(sx, sy))
        let w = shape.width * scale, h = shape.height * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// Maps a point in `bounds`'s coordinate space (a touch location) to
    /// guest-pixel coordinates for `mode`, clamped to the guest surface —
    /// including a touch that lands in Fill's cropped-away margin, which
    /// clamps to the nearest edge rather than reporting an off-surface point.
    static func map(point: CGPoint, guest: CGSize, aspect: CGSize = .zero, bounds: CGRect, mode: DisplayMode) -> CGPoint {
        let r = rect(guest: guest, aspect: aspect, bounds: bounds, mode: mode)
        guard r.width > 0, r.height > 0 else { return .zero }
        let x = (point.x - r.minX) * guest.width / r.width
        let y = (point.y - r.minY) * guest.height / r.height
        return CGPoint(x: min(max(x, 0), guest.width - 1),
                       y: min(max(y, 0), guest.height - 1))
    }
}

/// The guest's virtual monitor: what shape it starts out, and how the app
/// finds out when the guest changes it.
///
/// Before 2026-09-14 the monitor was a fixed 1024x768 for every direct launch,
/// so a widescreen game ran 4:3 and Fit pillarboxed it on a 19.5:9 phone —
/// "the game runs in a smaller window in landscape". Neither the display-mode
/// toggle nor anything else in the app can fix that, because the aspect is
/// decided by the monitor the guest is rendering for, not by how the result is
/// scaled afterwards. So the monitor now takes the DEVICE's landscape shape,
/// the way a PC monitor decides what a game looks like on Windows.
enum GuestDisplay {
    /// The modes the virtual monitor advertises. Kept in step with
    /// `ios_standard_modes` in build/win32u-unix/sysparams_ios.c: this list
    /// decides the session default, that one is what `EnumDisplaySettings`
    /// hands the guest, and a default missing from the guest's own mode table
    /// is a mode a game cannot re-select after it switches away.
    static let standardModes: [(w: Int, h: Int)] = [
        (640, 480), (800, 600), (1024, 768), (1152, 864),
        (1280, 720), (1280, 768), (1280, 800), (1280, 960),
        (1280, 1024), (1360, 768), (1366, 768), (1440, 900),
        (1600, 900), (1600, 1200), (1680, 1050), (1920, 1080),
        (1920, 1200), (2048, 1536), (2560, 1440),
    ]

    /// Pick the standard mode to start a session at for a landscape view of
    /// `size` points.
    ///
    /// Two constraints, in order. **Shape** first: the mode whose aspect is
    /// nearest the view's. Games want STANDARD modes, so a 19.5:9 phone gets
    /// the nearest standard aspect — 16:9 — and Fit letterboxes the remaining
    /// sliver, rather than a 1560x720 nobody's mode list contains. **Cost**
    /// second: only modes between 0.9 and 2.1 MP are considered (a phone GPU
    /// renders every one of those pixels), and among modes of effectively the
    /// same aspect the cheapest wins — so 16:9 lands on 1280x720 rather than
    /// 1920x1080, and 16:10 on 1280x800.
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
        // Anything within this of the best is the SAME standard aspect wearing
        // a different rounding (1366x768 is 1.7786, 1280x720 is 1.7778); the
        // tie is broken on render cost, not on the third decimal place.
        return candidates.filter { error($0) <= best + 0.01 }
                         .min { $0.w * $0.h < $1.w * $1.h }!
    }

    /// Choose the session's virtual monitor and export it for win32u
    /// (`ios_screen_size()` reads exactly these three variables).
    /// `Documents/madeira-screen.txt` holding `WxH` overrides the choice.
    /// Desktop mode does NOT come through here — explorer is launched with an
    /// explicit `/desktop=WxH` and exports its own size.
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
        // ml1090 — PUBLISH IT, DON'T ONLY EXPORT IT.
        //
        // IOSDisplayShim's cache seeds itself from MADEIRA_SCREEN_W/H on its
        // FIRST read and then never re-reads the environment (win32u owns the
        // value afterwards). Any `guestSize()` during the app's own first
        // layout runs before this function does, so the cache latched the
        // 1024x768 fallback and everything scaled from it disagreed with the
        // monitor win32u reports. Log 77: "[display] virtual monitor 1280x720
        // (source=view)" and, 1000 lines later, "[overlay] created ...
        // guest=1024x768" — two different ideas of the same desktop, so the
        // overlay, the drawn cursor and the touch mapping were all scaled by
        // the wrong number. This is the same call win32u makes when a guest
        // changes mode, so there is one publisher and one value.
        winios_display_mode_changed(Int32(mode.w), Int32(mode.h))
        return (mode.w, mode.h, source)
    }

    /// The device's landscape view size in POINTS. Points, not pixels: the
    /// aspect is the same either way, and points are what the presented
    /// layer's frame is expressed in.
    static var landscapeViewSize: CGSize {
        let b = UIScreen.main.bounds.size
        return CGSize(width: max(b.width, b.height), height: min(b.width, b.height))
    }

    /// Re-lay-out the presented surface when the guest switches modes.
    /// Idempotent and cheap: `guestSize()` calls it on every use so the
    /// observer exists no matter which view got on screen first.
    static func observeModeChanges() {
        _ = observer
    }

    private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        // The ObjC importer maps a `NSString * const` whose name ends in
        // "Notification" onto NSNotification.Name and drops that suffix, so the
        // Swift spelling of MadeiraDisplayModeChangedNotification is this.
        forName: .MadeiraDisplayModeChanged,
        object: nil, queue: .main
    ) { _ in
        MetalBackedView.refreshDisplayMode(reason: "mode-changed")
    }
}

/// Raw window-level host for the presenting CAMetalLayer.
// ml1001 -- CONTROLLER EVENTS BELONG TO THE GAME, NOT TO THE FOCUS ENGINE.
//
// Since iOS 18 the system also turns game-controller input into UIKit/SwiftUI
// focus navigation (the left stick moves focus, B is "back"), and a view
// hierarchy that has not said otherwise only sees the ANALOGUE half of the pad
// through GameController in brief bursts: device logs showed ~40 non-zero stick
// samples in 25,000 while buttons arrived normally. `GCEventInteraction` is the
// declaration that a view tree consumes the controller through the
// GameController framework; SwiftUI's `handlesGameControllerEvents` is the same
// thing one layer up. Installed on every view that fronts the game surface.
// Below iOS 18 neither the behaviour nor the class exists, so this is a no-op.
enum GamepadEventClaim {
    static func install(on view: UIView) {
        if #available(iOS 18.0, *) {
            if view.interactions.contains(where: { $0 is GCEventInteraction }) { return }
            let claim = GCEventInteraction()
            claim.handledEventTypes = .gamepad
            view.addInteraction(claim)
        }
    }
}

final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        GamepadEventClaim.install(on: self)
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false
    /// Aspect mode follows the swapchain drawable, which DXMT resizes on
    /// device Reset (a game changing resolution in its options). Nothing in
    /// UIKit lays us out for that, so watch the property and re-apply.
    private static var drawableObservation: NSKeyValueObservation?

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }

    /// `keyboardTarget` is reassigned in didMoveToWindow(window: non-nil), but
    /// rotation destroys/recreates this placeholder (SwiftUI switches between
    /// the portrait/landscape branches, each its own identity — see the
    /// comment on that if/else in ContentView.body), and nothing clears the
    /// weak reference on the way OUT: didMoveToWindow(window: nil) early-
    /// returns without touching it. So there is a real window, between the
    /// old placeholder's teardown and the new one's attach, where
    /// `keyboardTarget` still points at a view whose `.window` is nil — a
    /// `becomeFirstResponder()` on that view fails silently, which is exactly
    /// "tap the keyboard button, nothing happens." Resolve fresh at tap time
    /// instead of trusting the cached weak var: fall back to walking the live
    /// window hierarchy for whichever MetalBackedView is actually attached
    /// right now, and adopt it.
    private static func resolveKeyboardTarget() -> MetalBackedView? {
        if let t = keyboardTarget, t.window != nil { return t }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let found = firstMetalBackedView(in: window) {
                    keyboardTarget = found
                    return found
                }
            }
        }
        return keyboardTarget   // last resort: whatever we had, even if stale
    }

    private static func firstMetalBackedView(in view: UIView) -> MetalBackedView? {
        if let v = view as? MetalBackedView { return v }
        for sub in view.subviews {
            if let found = firstMetalBackedView(in: sub) { return found }
        }
        return nil
    }

    static func toggleKeyboard() {
        let target = resolveKeyboardTarget()
        guard let v = target else {
            fputs("[keyboard] show target=nil isFirstResponder=n/a window=nil " +
                  "(no live MetalBackedView found)\n", stderr)
            return
        }
        // Forced onto the main queue, after a layout pass, so a tap that
        // lands mid-rotation (the placeholder just got a new frame/window)
        // never races becomeFirstResponder against layout still settling.
        DispatchQueue.main.async {
            v.window?.layoutIfNeeded()
            let id = ObjectIdentifier(v)
            if v.isFirstResponder {
                let ok = v.resignFirstResponder()
                fputs("[keyboard] hide target=\(id) isFirstResponder=\(v.isFirstResponder) " +
                      "window=\(String(describing: v.window)) resigned=\(ok)\n", stderr)
            } else {
                let ok = v.becomeFirstResponder()
                fputs("[keyboard] show target=\(id) isFirstResponder=\(v.isFirstResponder) " +
                      "window=\(String(describing: v.window)) became=\(ok)\n", stderr)
                // ml: THE "tap the button, then tap the live view" BUG.
                //
                // A `becomeFirstResponder()` that returns false is not a
                // permanent refusal — it is UIKit saying "not right now",
                // typically because this view is not yet actually attached to
                // a window (the layoutIfNeeded above raced a rotation/re-attach
                // still in flight) or another responder was mid-resign. The old
                // code took `false` as final, so the keyboard silently stayed
                // down until a SECOND, unrelated tap on the live view happened
                // to retry it via touchesBegan. Retry once more on the next
                // runloop tick — by then the attach/resign this turn started
                // has had a chance to finish — before giving up for real.
                if !ok {
                    DispatchQueue.main.async {
                        guard !v.isFirstResponder else { return }
                        let retried = v.becomeFirstResponder()
                        fputs("[keyboard] show-retry target=\(id) " +
                              "isFirstResponder=\(v.isFirstResponder) became=\(retried)\n", stderr)
                    }
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
        // ml663: with a Bluetooth mouse attached, iOS draws its own pointer over
        // whatever is under it — including this surface, where it is both
        // distracting and a lie (the game has its own cursor, at its own
        // position). Hide it for the game area specifically, so the SwiftUI
        // chrome around it still shows a pointer you can aim at when pointer
        // lock is off. Harmless with no mouse: the interaction simply never
        // fires.
        addInteraction(UIPointerInteraction(delegate: PointerHider.shared))
        GamepadEventClaim.install(on: self)
        installPointerFallback()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addInteraction(UIPointerInteraction(delegate: PointerHider.shared))
        GamepadEventClaim.install(on: self)
        installPointerFallback()
    }

    // ==================================================================
    // ml664 — THE MOUSE THAT GameController CANNOT SEE.
    //
    // `HardwareInput` wires GCMouse as completely as it can be wired, and on a
    // device where the mouse is an AssistiveTouch pointer device that still
    // yields zero deltas (see the ml664 banner in HardwareInput.attachMouse).
    // The events DO exist — they arrive as UIKit *indirect pointer* input,
    // which is a different pipeline with a different opt-in
    // (UIApplicationSupportsIndirectInputEvents, already in Info.plist).
    //
    // Three recognisers, because iOS splits one mouse across three shapes:
    //   • hover  — movement with no button down. Absolute positions; we keep
    //              the previous one and send the difference.
    //   • drag   — movement WITH a button down. Hover stops during a drag, so
    //              a pan restricted to `.indirectPointer` carries it instead.
    //   • scroll — the wheel, delivered as a pan with no touches at all when
    //              `allowedScrollTypesMask` is set.
    // Buttons themselves are indirect-pointer TOUCHES, intercepted at the top
    // of touchesBegan/Ended/Cancelled and read off `UIEvent.buttonMask`.
    //
    // None of this may touch a finger. `allowedTouchTypes` on both pans is
    // restricted to `.indirectPointer` (the scroll pan accepts no touch type at
    // all), the hover recogniser is not a touch recogniser to begin with, and
    // every one of them is `cancelsTouchesInView = false` and recognises
    // simultaneously — so `ControlOverlayView`'s multi-touch arbitration and
    // the trackpad/game touch paths below are unchanged.
    // ==================================================================

    private var hoverLast = CGPoint.zero
    private var hoverHasLast = false
    private var pointerPanLast = CGPoint.zero
    private var pointerScrollLast = CGPoint.zero

    private func installPointerFallback() {
        let indirect = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onPointerHover(_:)))
        hover.cancelsTouchesInView = false
        hover.delegate = PointerGestureDelegate.shared
        addGestureRecognizer(hover)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(onPointerDrag(_:)))
        drag.allowedTouchTypes = indirect
        drag.allowedScrollTypesMask = []          // motion only; the wheel is separate
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        drag.delaysTouchesBegan = false
        drag.delaysTouchesEnded = false
        drag.delegate = PointerGestureDelegate.shared
        addGestureRecognizer(drag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onPointerScroll(_:)))
        scroll.allowedTouchTypes = []             // NEVER a finger: scroll events only
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        scroll.cancelsTouchesInView = false
        scroll.delaysTouchesBegan = false
        scroll.delaysTouchesEnded = false
        scroll.delegate = PointerGestureDelegate.shared
        addGestureRecognizer(scroll)
    }

    @objc private func onPointerHover(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            hoverLast = p; hoverHasLast = true
        case .changed:
            // No previous sample (the pointer re-entered, or a drag just ended)
            // means the first difference would be a jump from wherever it was
            // last seen. Re-seed instead of posting it.
            guard hoverHasLast else { hoverLast = p; hoverHasLast = true; return }
            let d = CGPoint(x: p.x - hoverLast.x, y: p.y - hoverLast.y)
            hoverLast = p
            HardwareInput.shared.uikitMoved(d.x, d.y, src: "hover")
        default:
            hoverHasLast = false
        }
    }

    @objc private func onPointerDrag(_ g: UIPanGestureRecognizer) {
        // Translation, not location: a pan's translation keeps accumulating past
        // the point where the clamped system pointer stops, which is the only
        // edge behaviour iOS gives us for free.
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            pointerPanLast = .zero
            hoverHasLast = false
        case .changed:
            let d = CGPoint(x: t.x - pointerPanLast.x, y: t.y - pointerPanLast.y)
            pointerPanLast = t
            HardwareInput.shared.uikitMoved(d.x, d.y, src: "pan")
        default:
            pointerPanLast = .zero
            hoverHasLast = false      // hover re-seeds on its next sample
        }
    }

    @objc private func onPointerScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .changed:
            let d = CGPoint(x: t.x - pointerScrollLast.x, y: t.y - pointerScrollLast.y)
            pointerScrollLast = t
            HardwareInput.shared.uikitScroll(d.x, d.y)
        default:
            pointerScrollLast = .zero
        }
    }

    /// An indirect-pointer touch is a MOUSE BUTTON, not a finger — it must never
    /// reach the trackpad/game touch logic below, which would read a click as a
    /// tap and a click-drag as a one-finger aim.
    ///
    /// Returns true when this event belonged to the pointer and is handled.
    private func pointerButtons(_ touches: Set<UITouch>, with event: UIEvent?,
                                ending: Bool) -> Bool {
        guard touches.contains(where: { $0.type == .indirectPointer }) else { return false }
        var mask = event?.buttonMask ?? []
        if ending {
            // Belt and braces against a mask that still lists the button being
            // released: if nothing indirect is still down, nothing is held.
            let live = (event?.allTouches ?? []).filter {
                $0.type == .indirectPointer && $0.phase != .ended && $0.phase != .cancelled
            }
            if live.isEmpty { mask = [] }
        }
        var want: Set<Int> = []
        if mask.contains(.primary)   { want.insert(InputGuard.Btn.left) }
        if mask.contains(.secondary) { want.insert(InputGuard.Btn.right) }
        if mask.contains(UIEvent.ButtonMask.button(3)) { want.insert(InputGuard.Btn.middle) }
        if mask.contains(UIEvent.ButtonMask.button(4)) { want.insert(InputGuard.Btn.x1) }
        if mask.contains(UIEvent.ButtonMask.button(5)) { want.insert(InputGuard.Btn.x2) }
        // A down with an empty mask happens in UIKit's pointer-compatibility
        // mode, where a click is reported as a touch and nothing else. It is a
        // left click; treating it as "no buttons" would make the mouse unable to
        // click at all on exactly the devices this fallback exists for.
        if !ending && want.isEmpty { want.insert(InputGuard.Btn.left) }
        HardwareInput.shared.uikitButtons(want)
        return true
    }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// The guest surface's logical resolution — the size of the virtual
    /// monitor win32u is reporting to the guest RIGHT NOW. This is no longer
    /// the launch-time `MADEIRA_SCREEN_W/H` pair: since 2026-09-14 a guest's
    /// `ChangeDisplaySettings` really resizes the virtual monitor
    /// (build/win32u-unix/sysparams_ios.c: `ios_virtual_change_display_settings`
    /// → `ios_publish_screen_size`), so the value must be read back from
    /// `winios_screen_size()` (IOSDisplayShim.m) on every use. A stale read
    /// here would letterbox a game's new mode inside the old one's aspect.
    /// `GuestDisplay.observeModeChanges` re-lays-out when it changes.
    private func guestSize() -> CGSize {
        GuestDisplay.observeModeChanges()
        var w: Int32 = 0, h: Int32 = 0
        winios_screen_size(&w, &h)
        guard w > 0, h > 0 else {
            return CGSize(width: envInt("MADEIRA_SCREEN_W", 1024),
                          height: envInt("MADEIRA_SCREEN_H", 768))
        }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    /// The rect (view-local points) the guest surface occupies for the
    /// current DisplayMode: Fit is the largest centered rect that fits our
    /// bounds (unchanged from the original hardcoded-1024x768 behaviour, just
    /// generalised to guestSize()); Fill is the smallest centered rect that
    /// COVERS our bounds — same width (or height) as bounds exactly, the
    /// other axis overflowing symmetrically; Stretch is bounds itself. The
    /// window-level host view gets exactly THIS frame (see applyDisplayMode
    /// below), not our full bounds unconditionally — Fit must stay confined
    /// to keep it out of sibling SwiftUI chrome (the pillarbox HUD bar in
    /// landscape, the header/log rows around the 240pt portrait game strip),
    /// and Fill/Stretch only grow as far as the aspect math actually needs.
    /// Touch mapping (mapTouch, below) uses the identical rect so
    /// letterboxing/cropping/stretching never skews input.

    /// The DisplayMode actually used for layout AND touch mapping this
    /// frame — may differ from the user's InputSettings.shared.displayMode.
    ///
    /// In the NORMAL view the game surface always has sibling chrome next to
    /// or below it — the fixed-height portrait strip (ContentView.
    /// portraitBody: `MadeiraMetalView().frame(height: 240)`) or the
    /// fixed-width right-hand tools column (wideNormalBody). Fill/Fill-height
    /// are allowed to grow the presented rect past `bounds` on one axis by
    /// design (see GameSurfaceLayout.rect) — that's correct in FULLSCREEN,
    /// where nothing else is on screen, but in the normal view that overflow
    /// is exactly "the live view overlaps the chrome next to/below it". A
    /// CAMetalLayer doesn't reliably honour contentsRect cropping for
    /// drawable-presented content, so rather than risk a coordinate mismatch,
    /// fall back to Aspect in the normal view for those two modes.
    ///
    /// ml: this used to key off `traitCollection.verticalSizeClass`, which
    /// mirrored ContentView's own (also since-removed) `vSizeClass ==
    /// .compact` branch condition. Both lied on iPad, where split view and
    /// Stage Manager report regular/regular in every orientation — so the
    /// clamp either never engaged or never released there. FullscreenState is
    /// the one flag every view in the app now agrees on (see its doc comment).
    private func effectiveDisplayMode() -> DisplayMode {
        let mode = InputSettings.shared.displayMode
        let clampsToAspect = !FullscreenState.shared.active && (mode == .fill || mode == .fitHeight)
        return clampsToAspect ? .aspect : mode
    }

    /// The drawable size to hand GameSurfaceLayout, or `.zero` ("unknown")
    /// when DXMT hasn't published a real one yet. `.zero` makes
    /// GameSurfaceLayout.rect/.map fall back to the guest size instead of
    /// letterboxing/mapping against a stale or placeholder shape (MetalHostView
    /// seeds 800x600 at init, before any game has resized it).
    private func drawableAspect() -> CGSize {
        // The drawable's shape means something only once this session has
        // presented into it. Until then it is the 800x600 seed (or the last
        // session's size), and a program that only ever shows ordinary windows
        // was laid out 4:3 against a 16:9 guest — scaled unevenly on the two axes.
        guard madeira_get_present_count() != Self.presentCountAtLaunch else { return .zero }
        let d = MetalHostView.shared.metalLayer.drawableSize
        return (d.width > 0 && d.height > 0) ? d : .zero
    }

    /// Present counter value when the current session started — see drawableAspect().
    static var presentCountAtLaunch: UInt64 = 0

    private func gameRect() -> CGRect {
        GameSurfaceLayout.rect(guest: guestSize(), aspect: drawableAspect(),
                               bounds: bounds, mode: effectiveDisplayMode())
    }

    /// Coalesces the ~0.3s settle re-apply scheduled by applyAndScheduleSettle
    /// (below) / refreshDisplayMode(reason:) — a burst of triggers (rotation
    /// firing layoutSubviews repeatedly, KVO plus a layout pass, …) collapses
    /// to one trailing re-apply instead of one per trigger.
    private static var pendingSettleWorkItem: DispatchWorkItem?

    /// UIKit reports PRE-rotation bounds while a rotation/safe-area
    /// transition is still animating, and DXMT may not have published the
    /// new drawableSize yet either — so an apply driven by the transition's
    /// own callback can compute from stale inputs. This is the fix for
    /// "the Aspect button lays out small until you cycle all the way back to
    /// it": re-apply once more after things have actually settled, from
    /// whichever MetalBackedView is live right now (`keyboardTarget`, not a
    /// captured view — rotation destroys/recreates this placeholder, see the
    /// comment on ContentView.body's fullscreenBody/wideNormalBody/
    /// portraitBody if/else).
    private static func scheduleSettleReapply(reason: String) {
        pendingSettleWorkItem?.cancel()
        let item = DispatchWorkItem {
            keyboardTarget?.applyDisplayModeAndLog(reason: "settle:\(reason)")
        }
        pendingSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Sizes the presented layer's host view to gameRect() and logs every
    /// call (LogStore's signature dedup already collapses repeats with an
    /// on-screen counter, so this doesn't spam the UI — see LogPattern
    /// .canonicalize) with the inputs that produced `rect`, so a pulled log
    /// says exactly what each apply saw rather than just its outcome.
    ///
    /// `reason` names the trigger (layout / attach / drawable / mode-changed
    /// / mode-toggle / orientation / settle:<reason>) — see refreshDisplayMode
    /// (reason:) and the call sites in layoutSubviews/didMoveToWindow.
    ///
    /// Fill/Fill-height can genuinely extend past our own bounds on one axis
    /// in landscape/fullscreen (that's the point — filling the pillarbox bars
    /// a game used to leave empty), which may run under the notch/home
    /// indicator there; per spec that's acceptable. In portrait,
    /// effectiveDisplayMode() already keeps this from happening (see above).
    private func applyDisplayModeAndLog(reason: String) {
        guard let w = window else { return }
        let mode = InputSettings.shared.displayMode
        let effective = effectiveDisplayMode()
        let guest = guestSize()
        let rawDrawable = MetalHostView.shared.metalLayer.drawableSize
        let r = gameRect()
        MetalHostView.shared.frame = convert(r, to: w)
        // ml1090 — PUBLISH THE RECT WE JUST LAID OUT.
        //
        // The direct-launch cursor and the GDI overlay used to read the game
        // rect back off the presented layer's bounds, which are only right
        // once a drawable has actually been presented into it. A program whose
        // first window is a dialog has presented nothing yet, so the overlay
        // was built against a stale rect (log 77: game-rect=320x240 while this
        // apply had chosen 402x226) and everything it drew was scaled wrong.
        // This is the same `r` the touch mapping uses, so all three agree.
        winios_set_game_rect(r.width, r.height)
        // The direct-launch cursor is a sublayer of MetalHostView.shared's own
        // layer, positioned from that layer's LOCAL bounds (see Winios.m's
        // winios_set_game_layer doc comment) — which just changed size/shape
        // above. Re-place it now so it tracks every DisplayMode change and
        // rotation, not only the next touch/pointer event.
        winios_cursor_relayout()
        // Same host layer, same trigger: a directly-launched program's ordinary
        // GDI windows (a chooser dialog, a message box, a popup menu) are drawn
        // in a transparent overlay hosted on that same layer and positioned from
        // its local bounds — see winios_overlay_relayout's doc comment in
        // Winios.h. No-op in desktop mode and whenever no such window exists.
        winios_overlay_relayout()
        // ml1110 — the desktop-session twin of the two calls above. The
        // compositor letterboxes the wine desktop inside its own frame against
        // the guest resolution, and a guest-side ChangeDisplaySettings moves
        // that mapping without moving the frame — which
        // winios_set_compositor_frame deliberately cannot notice. This apply is
        // already the reason="mode-changed" one, so it is the right trigger.
        // No-op in a direct launch.
        winios_compositor_relayout()
        let modeLabel = mode == effective ? mode.label : "\(effective.label)(req:\(mode.label))"
        fputs(String(format: "[display] apply reason=%@ mode=%@ guest=%.0fx%.0f drawable=%.0fx%.0f "
                    + "bounds=(%.0f,%.0f %.0fx%.0f) -> rect=(%.0f,%.0f %.0fx%.0f)\n",
                    reason, modeLabel, guest.width, guest.height, rawDrawable.width, rawDrawable.height,
                    bounds.minX, bounds.minY, bounds.width, bounds.height,
                    r.minX, r.minY, r.width, r.height), stderr)
    }

    /// Instance-side helper for the two direct call sites (layoutSubviews,
    /// didMoveToWindow) that already hold `self`: apply now AND arm the
    /// coalesced settle re-apply for ~0.3s out.
    private func applyAndScheduleSettle(_ reason: String) {
        applyDisplayModeAndLog(reason: reason)
        Self.scheduleSettleReapply(reason: reason)
    }

    /// Re-applies the display mode to whichever MetalBackedView is currently
    /// on screen, and arms the settle re-apply. InputSettings is a plain
    /// ObservableObject, not something this raw UIKit view observes, so a
    /// mode flip from the HUD button (or the guest's own mode-change
    /// notification, or a drawableSize KVO, or a device rotation) needs an
    /// explicit nudge — see the call sites of this function.
    static func refreshDisplayMode(reason: String = "refresh") {
        keyboardTarget?.applyDisplayModeAndLog(reason: reason)
        scheduleSettleReapply(reason: reason)
    }

    /// Idempotent, app-lifetime: re-lay-out on device rotation too, not just
    /// on the layoutSubviews pass UIKit happens to schedule around it — the
    /// pass that DOES fire during the transition sees pre-rotation bounds
    /// (see scheduleSettleReapply above), so the rotation notification itself
    /// is a second, independent trigger with its own settle re-apply.
    private static let orientationObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification,
        object: nil, queue: .main
    ) { _ in
        MetalBackedView.refreshDisplayMode(reason: "orientation")
    }
    private static func observeOrientationChanges() { _ = orientationObserver }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        defuseAncestorRecognizers()
        let host = MetalHostView.shared
        host.isHidden = LibraryModel.shared.enabled && LibraryModel.shared.current == nil
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        applyAndScheduleSettle("attach")
        Self.observeOrientationChanges()
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            // Direct-launch cursor host (Winios.m) — see winios_set_game_layer's
            // doc comment there. Registered once, same lifetime reasoning as the
            // DXMT registration right above: one host, one layer, forever.
            winios_set_game_layer(Unmanaged.passUnretained(host.metalLayer).toOpaque())
            Self.drawableObservation = host.metalLayer.observe(\.drawableSize, options: [.new]) { _, _ in
                // drawableSize is written off the render thread (DXMT's
                // setProps); KVO delivers on whatever thread the write
                // happened on, and applyDisplayModeAndLog touches UIKit, so
                // this MUST hop to main before calling it.
                DispatchQueue.main.async { MetalBackedView.refreshDisplayMode(reason: "drawable") }
            }
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
    }

    /// SwiftUI ancestors attach gesture recognizers that can delay or cancel
    /// raw touch delivery (double-tap timing is exactly what they punish).
    /// Defuse them for our subtree.
    ///
    /// ml662: re-run on every layout, not once on attach. SwiftUI installs
    /// recognizers lazily as the body changes — a modifier added by a later
    /// render arrives AFTER didMoveToWindow, and one such recogniser with
    /// cancelsTouchesInView left at its default is enough to cancel a live-view
    /// touch. Which is the mirror image of the aim-stick complaint: the game
    /// view must be as uncancellable as the control layer.
    func defuseAncestorRecognizers() {
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        defuseAncestorRecognizers()
        if let w = window {
            // UIKit calls layoutSubviews mid-rotation with pre-rotation
            // bounds (this is exactly the "Aspect lays out small until you
            // cycle the mode" bug) — applyAndScheduleSettle both applies now
            // AND arms a re-apply once the transition has actually settled.
            applyAndScheduleSettle("layout")
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map touch point in view-local UI points to guest-pixel coordinates via
    // the same GameSurfaceLayout math that sizes the presented layer's host
    // view (see gameRect()/applyDisplayModeAndLog above — effectiveDisplayMode()
    // and drawableAspect() keep the two in agreement), then post to
    // winios.drv. Off-surface touches (Fill's cropped margin) clamp to the
    // nearest edge.
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        mapPoint(touch.location(in: self))
    }

    /// Same mapping as `mapTouch`, for a point that is not necessarily a
    /// live `UITouch`'s current location — the midpoint of several fingers
    /// (Task 2's 2/3-finger taps), or a touch's ORIGINAL down point read
    /// after the touch itself has already ended.
    private func mapPoint(_ p: CGPoint) -> (Int32, Int32) {
        if desktopMode {
            // The desktop is drawn by the window-level compositor, letterboxed
            // inside its own presentation frame; only it knows the mapping.
            let w = convert(p, to: nil)
            var px: Int32 = 0, py: Int32 = 0
            winios_desktop_point_from_window(Double(w.x), Double(w.y), &px, &py)
            Self.cursor = CGPoint(x: CGFloat(px), y: CGFloat(py))   // keep the trackpad's cursor in step
            return (px, py)
        }
        // ml1110 — THE DIRECT-LAUNCH OVERLAY FIT, INVERTED EXACTLY.
        //
        // A direct launch has no window manager, so a top-level window larger
        // than the guest desktop can never be moved back on screen; when one
        // exists the GDI overlay maps the UNION of what it draws into the game
        // rect with one uniform scale, centred (see winios_overlay_fit_source
        // in Winios.h). That union is NOT the guest desktop, so the
        // GameSurfaceLayout mapping below — which assumes it is — would put a
        // tap somewhere the window is not. Same three numbers, same game rect
        // `r` the overlay was placed against, run backwards. Clamped to the
        // SOURCE rect rather than the desktop, because the guest pixels a tap
        // on an oversized window lands on are legitimately outside it.
        var fx = 0.0, fy = 0.0, fw = 0.0, fh = 0.0
        if winios_overlay_fit_source(&fx, &fy, &fw, &fh) != 0, fw > 0, fh > 0 {
            let r = gameRect()
            let k = min(r.width / fw, r.height / fh)
            if k > 0 {
                let ox = r.minX + (r.width - fw * k) / 2
                let oy = r.minY + (r.height - fh * k) / 2
                let gx = min(max(fx + (p.x - ox) / k, fx), fx + fw - 1)
                let gy = min(max(fy + (p.y - oy) / k, fy), fy + fh - 1)
                return (Int32(gx), Int32(gy))
            }
        }
        let guest = guestSize()
        let g = GameSurfaceLayout.map(point: p, guest: guest, aspect: drawableAspect(),
                                      bounds: bounds, mode: effectiveDisplayMode())
        return (Int32(g.x), Int32(g.y))
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    private static var cursor = CGPoint(x: 480, y: 270)
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    // ml — Task 2 ("Touch" pointer mode): middle button, for a 3-finger tap.
    // Matches Winios.m's MOUSEEVENTF_MIDDLEDOWN/UP (0x0020/0x0040) exactly —
    // the same flag values `InputGuard.postButton` already sends for a
    // Bluetooth mouse's middle button, so no driver-side change is involved.
    private let F_MDOWN: UInt32 = 0x20, F_MUP: UInt32 = 0x40
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private static let unifiedPointer = LibraryFlags.enabled("MADEIRA_POINTER_UNIFIED")
    private static var reportedUnifiedPointer = false
    private var trackpadMode: Bool {
        desktopMode || (Self.unifiedPointer && !touchPointerMode && !InputSettings.shared.relative)
    }
    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    /* ml660: the one place relative deltas are turned into wine events.
     *
     * Shared by the desktop trackpad path, the live-view drag path and (via
     * winios_pointer directly) the on-screen aim stick, so all three are
     * calibrated by the SAME sensRel slider and all three carry the truncation
     * remainder — see the ml641 note on relCarryX. */
    private func postRelative(_ dx: CGFloat, _ dy: CGFloat) {
        let sens = CGFloat(InputSettings.shared.sensRel)
        relCarryX += dx * sens
        relCarryY += dy * sens
        let ix = Int32(max(-30000, min(30000, relCarryX)))
        let iy = Int32(max(-30000, min(30000, relCarryY)))
        relCarryX -= CGFloat(ix)
        relCarryY -= CGFloat(iy)
        if ix != 0 || iy != 0 {
            winios_pointer(ix, iy, F_MOVE, 0)
            Self.relPosts += 1
            Self.relAccX += Int(ix); Self.relAccY += Int(iy)
        } else {
            Self.relTruncated += 1
        }
        relmouseReport()
    }

    // ====================================================================
    // ml667 — the touch end of [relmouse].
    //
    // The report is "swipes stop turning the camera, but the pause-menu
    // cursor still moves". Three different layers can produce that, and only
    // one of them lives here, so the first job is to stop guessing which:
    // this line says whether the FINGER still reaches this view at all.
    //
    //   posts / acc   deltas this view actually handed to winios_pointer.
    //   trunc         deltas the sensitivity scale rounded away to nothing
    //                 (the ml641 carry should keep this from mattering).
    //   claims        touchesBegan calls that took ownership.
    //   refused       touchesBegan calls turned away because a claim was
    //                 still live — with the owner's phase and whether it is
    //                 still OUR view's touch. `refused` climbing while
    //                 `claims` does not, with owner_mine=false, is the
    //                 recycled-UITouch trap (a pooled UITouch reissued to
    //                 another view leaves `gameTouch` pointing at a live
    //                 stranger, and this view never accepts a finger again).
    //
    // If posts keeps climbing here while the server's [relmouse] rel_in does
    // not, the loss is below us; if posts stalls with refused climbing, it is
    // here. Static because the counters must survive a view rebuild.
    // ====================================================================
    private static var relPosts = 0, relTruncated = 0, relAccX = 0, relAccY = 0
    private static var claims = 0, refused = 0
    private static var lastRefusePhase = -1, lastRefuseMine = false
    private static var relNextReport: TimeInterval = 0

    private func relmouseReport() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now >= Self.relNextReport else { return }
        Self.relNextReport = now + 5
        var owner = "none"
        if let o = gameTouch {
            owner = "phase=\(o.phase.rawValue) mine=\(o.view === self)"
        }
        let line = "[relmouse] ml667 src=touch posts=\(Self.relPosts) "
            + "acc=(\(Self.relAccX),\(Self.relAccY)) trunc=\(Self.relTruncated) "
            + "claims=\(Self.claims) refused=\(Self.refused) "
            + "last_refuse(phase=\(Self.lastRefusePhase) mine=\(Self.lastRefuseMine)) "
            + "owner=\(owner) relmode=\(InputSettings.shared.relative) "
            + "sens=\(InputSettings.shared.sensRel)\n"
        fputs(line, stderr)
    }

    /* ml660: GAME MODE (MADEIRA_DESKTOP unset — everything the launch table
     * starts) used to have exactly one behaviour: touch-down posted
     * MOVE|LEFTDOWN|ABSOLUTE, each move posted MOVE|ABSOLUTE, lift posted
     * LEFTUP. So a hold-and-drag to aim was, quite literally, a left click with
     * the button held down for the whole drag — reported as "dragging just acts
     * as a left click" — and the moves it did send were ABSOLUTE positions,
     * which a mouse-look game turns into (finger position − its own clamped
     * cursor): the ml641 spin, not aiming.
     *
     * The trackpad engine's Relative mode was never reachable from here: it is
     * gated behind desktopMode. Now the live view honours the same toggle, so
     * Relative gives a drag pure motion with no button at all, and a quick
     * stationary tap still clicks. Absolute mode is untouched — desktop use
     * (and every game that wants a real pointer) behaves exactly as before. */
    private var gameRelative: Bool { !desktopMode && InputSettings.shared.relative }

    // ========================================================================
    // ml666 — THE GAME VIEW OWNS ONE FINGER, AND KNOWS WHICH.
    //
    // Every branch below used `touches.first` — an arbitrary member of the set
    // this callback happens to carry — while writing ONE set of per-view state
    // (`touchStartPoint`, `lastPanPoint`, `movedBeyondSlop`, `touchStartTime`).
    // With two fingers on the live view that state belongs to whichever finger
    // moved last: a second touch landing mid-drag re-seeds the start point, so
    // the first finger's lift is judged "stationary and quick" and fires a
    // CLICK the user never asked for; in absolute mode each extra finger posts
    // its own LEFTDOWN and the lifts do not pair with them.
    //
    // A stray touch is therefore not a harmless no-op here, and the click it
    // produces is the event the user reports right before the controls die. So
    // the live view claims exactly one `UITouch` and ignores the rest until it
    // ends — the same rule the control layer follows. Weak, because UIKit owns
    // the object and a missed end must not pin it.
    //
    // Nothing on this path touches overlay or held-key state: the click is
    // posted straight to the ring as a LEFTDOWN/LEFTUP pair and no InputGuard
    // owner, region or face is involved, so a tap on the game can no longer
    // release what a thumb on a control is holding.
    // ========================================================================
    private weak var gameTouch: UITouch?

    /// The claimed finger, if it is in this callback's set.
    private func ownedTouch(_ touches: Set<UITouch>) -> UITouch? {
        guard let owned = gameTouch else { return nil }
        return touches.first { $0 === owned }
    }

    // ========================================================================
    // Task 2 — "Touch" pointer mode: tap-to-click, tap-and-hold-to-drag, and
    // 2/3-finger taps for right/middle click.
    //
    // A separate, independent state machine from the Absolute/Relative
    // `gameTouch` single-owner path above: disambiguating a 1/2/3-finger TAP
    // needs to see every finger of a gesture, not just the first one claimed,
    // so it keeps its own small per-gesture ledger rather than reusing it.
    //
    //   1 finger, released quickly & without moving -> left click AT the tap.
    //   1 finger held >= ~250ms OR moved before release -> left button DOWN
    //       at the ORIGINAL down point (never the moved-to point — a hold
    //       must not itself feel like a jump), follows the finger while it
    //       is down, UP on lift.
    //   2 fingers that both lift without moving -> right click at their
    //       midpoint. 3 fingers -> middle click, same way.
    //   A finger moving past a small slop CANCELS a 2/3-finger tap outright
    //   (no click posted at all — ambiguous is safer as a no-op than as a
    //   guess), except a 2-finger drag optionally scrolls the wheel.
    // ========================================================================
    private var tmDownPoints: [ObjectIdentifier: CGPoint] = [:]
    private var tmGestureDownPoint = CGPoint.zero
    private var tmPeak = 0                  // most fingers seen down at once this gesture
    private var tmResolved = false          // true once a left DOWN has been posted (hold/drag)
    private var tmDragTouch: UITouch?
    private var tmSlopBroken = false
    private var tmGeneration = 0            // invalidates a stale hold timer
    private var tmTwoFingerLastY: CGFloat = 0
    private var tmScrollAccum: CGFloat = 0

    private static let tmHoldDelay: TimeInterval = 0.25
    private static let tmSlop: CGFloat = 10

    // Touch mode applies in BOTH sessions. It was first gated to direct launches
    // only, so on the Wine desktop -- the place a user most wants "tap where I
    // mean, hold to drag a window" -- the trackpad path still ran and the cursor
    // had to be dragged around. Desktop taps map through the compositor's own
    // desktop-pixel mapping (winios_desktop_point_from_window), see mapPoint.
    private var touchPointerMode: Bool { InputSettings.shared.touchMode }

    private func tmResetGesture() {
        tmDownPoints.removeAll()
        tmGestureDownPoint = .zero
        tmPeak = 0
        tmResolved = false
        tmDragTouch = nil
        tmSlopBroken = false
        tmGeneration += 1
        tmTwoFingerLastY = 0
        tmScrollAccum = 0
    }

    /// Midpoint of every finger seen this gesture, read from their DOWN
    /// points — for a tap that never broke slop (the only kind that reaches
    /// here) that is within `tmSlop` of each finger's actual lift point, and
    /// avoids needing a second ledger of "last known position" just for
    /// fingers that have already ended by the time this runs.
    private func tmMidpoint() -> CGPoint {
        guard !tmDownPoints.isEmpty else { return tmGestureDownPoint }
        let pts = Array(tmDownPoints.values)
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n,
                       y: pts.reduce(0) { $0 + $1.y } / n)
    }

    private func tmCommitDrag(_ t: UITouch) {
        guard !tmResolved else { return }
        tmResolved = true
        tmDragTouch = t
        let (x, y) = mapPoint(tmGestureDownPoint)
        winios_post_touch_down(x, y)
    }

    private func postClickLeft(at p: CGPoint) {
        let (x, y) = mapPoint(p)
        winios_post_touch_down(x, y)
        winios_post_touch_up(x, y)
    }

    /// Right/middle click at an absolute guest position. `winios_post_
    /// touch_down/up` are left-button-only by construction (their C bodies
    /// hardcode MOUSEEVENTF_LEFTDOWN/UP), so right/middle reuse
    /// `winios_pointer` directly — the SAME primitive `InputGuard.
    /// postButton` already calls for a Bluetooth mouse's right/middle
    /// buttons — with MOUSEEVENTF_ABSOLUTE added so the click lands at a
    /// specific point instead of wherever InputGuard's own (unrelated)
    /// desktop-mode cursor last was. No driver change: Winios.m's
    /// `winios_q_push_ev` already understands RIGHTDOWN/RIGHTUP/
    /// MIDDLEDOWN/MIDDLEUP, and `winios_pointer` already calls
    /// `winios_cursor_move` for any ABSOLUTE-flagged post (Winios.m:1867),
    /// so the drawn cursor follows exactly like a left click does.
    private func postAbsoluteClick(down: UInt32, up: UInt32, at p: CGPoint) {
        let (x, y) = mapPoint(p)
        winios_pointer(x, y, down | F_ABS, 0)
        winios_pointer(x, y, up | F_ABS, 0)
    }

    private func touchModeBegan(_ touches: Set<UITouch>) {
        guard !tmResolved else { return }   // a finger joining mid-drag changes nothing
        for t in touches where tmDownPoints[ObjectIdentifier(t)] == nil {
            tmDownPoints[ObjectIdentifier(t)] = t.location(in: self)
        }
        tmPeak = max(tmPeak, tmDownPoints.count)

        if tmDownPoints.count == 1, let t = touches.first {
            tmGestureDownPoint = t.location(in: self)
            // Instant visual feedback — "a single tap moves the cursor
            // there" — before we know whether this becomes a tap, a hold, or
            // (if a second finger joins) a right/middle click. Purely the
            // drawn arrow: no protocol event is posted yet, so a multi-
            // finger tap that follows produces no stray click or jump.
            let (x, y) = mapPoint(tmGestureDownPoint)
            winios_cursor_move(x, y)
            tmGeneration += 1
            let gen = tmGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tmHoldDelay) { [weak self, weak t] in
                guard let self, let t, self.tmGeneration == gen, !self.tmResolved,
                      self.tmDownPoints.count == 1 else { return }
                self.tmCommitDrag(t)
            }
        } else {
            // A second/third finger joined before the first resolved: only a
            // multi-finger TAP is possible now — invalidate the hold timer so
            // it can never fire a left click/drag out from under that.
            tmGeneration += 1
        }
    }

    private func touchModeMoved(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let active = activeTouches(event)

        // Two-finger drag: scroll (optional per spec, cheap to add — reuses
        // the exact notch math as the desktop trackpad's two-finger scroll
        // below). Computed once per event from the current pair, never per
        // touch: both fingers can appear in the same `touches` set and must
        // not double-count one drag.
        if !tmResolved, tmDownPoints.count == 2, active.count == 2 {
            let avg = avgPoint(active)
            if tmTwoFingerLastY == 0 { tmTwoFingerLastY = avg.y }
            let dy = avg.y - tmTwoFingerLastY
            if abs(dy) > 2 { tmSlopBroken = true }
            tmTwoFingerLastY = avg.y
            tmScrollAccum += dy
            let (mx, my) = mapPoint(avg)
            while tmScrollAccum <= -14 { tmScrollAccum += 14
                winios_pointer(mx, my, F_WHEEL, UInt32(bitPattern: Int32(-120))) }
            while tmScrollAccum >= 14  { tmScrollAccum -= 14
                winios_pointer(mx, my, F_WHEEL, UInt32(bitPattern: Int32(120))) }
            return
        }

        for t in touches {
            guard let down = tmDownPoints[ObjectIdentifier(t)] else { continue }
            let p = t.location(in: self)

            if tmResolved {
                guard t === tmDragTouch else { continue }   // only the drag's own finger moves it
                let (x, y) = mapPoint(p)
                winios_post_touch_move(x, y)
                continue
            }
            guard tmDownPoints.count == 1 else {
                // 3+ fingers (or a pair we are not scrolling): movement just
                // cancels the tap — no gesture is defined for it.
                if hypot(p.x - down.x, p.y - down.y) > Self.tmSlop { tmSlopBroken = true }
                continue
            }
            if hypot(p.x - down.x, p.y - down.y) > Self.tmSlop {
                tmSlopBroken = true
                tmCommitDrag(t)                  // LDOWN at the ORIGINAL down point
                let (x, y) = mapPoint(p)
                winios_post_touch_move(x, y)      // then the move that broke slop
            }
        }
    }

    private func touchModeEnded(_ touches: Set<UITouch>, _ event: UIEvent?) {
        if tmResolved, let d = tmDragTouch, touches.contains(d) {
            let (x, y) = mapPoint(d.location(in: self))
            winios_post_touch_up(x, y)
            tmResetGesture()
            return
        }
        guard !tmResolved else { return }   // some OTHER (ignored) finger lifted mid-drag
        guard activeTouches(event).isEmpty else { return }   // wait for every finger up

        let peak = tmPeak
        let mid = tmMidpoint()
        let brokeSlop = tmSlopBroken
        tmResetGesture()
        guard !brokeSlop else { return }   // a moved finger cancels the tap outright

        switch peak {
        case 1: postClickLeft(at: mid)
        case 2: postAbsoluteClick(down: F_RDOWN, up: F_RUP, at: mid)
        case 3: postAbsoluteClick(down: F_MDOWN, up: F_MUP, at: mid)
        default: break   // 4+ fingers: no gesture defined, no click.
        }
    }

    private func touchModeCancelled(_ touches: Set<UITouch>) {
        if tmResolved, let d = tmDragTouch, touches.contains(d) {
            // Release whatever button is down rather than leave it stuck —
            // the same reasoning ml661 applies to held keys.
            let (x, y) = mapPoint(d.location(in: self))
            winios_post_touch_up(x, y)
            tmResetGesture()
            return
        }
        // A cancel mid-tap is a stronger signal than a slop break: drop the
        // whole gesture, never guess a click out of it.
        if !tmResolved { tmResetGesture() }
    }

    private func stopTouchForModal() -> Bool {
        guard LibraryModel.shared.blocksGameplayTouch else { return false }
        // A finger can still belong to this view after another finger opens
        // the window-level menu. Forget it without synthesizing a tap on lift.
        touchGeneration += 1
        gameTouch = nil; dragTouch = nil; dragActive = false
        twoFingerActive = false; relCarryX = 0; relCarryY = 0
        tmResetGesture()
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if stopTouchForModal() { return }
        if pointerButtons(touches, with: event, ending: false) { return }   // ml664
        // ========================================================================
        // ml665 — THE CLICK THAT ARRIVES AS A FINGER.
        //
        // On iPhone a mouse reaches an app only through AssistiveTouch, and
        // AssistiveTouch delivers a CLICK as a synthesised `.direct` UITouch at
        // the accessibility cursor's position. Without this guard that touch ran
        // the whole finger path below: `winios_post_touch_down` / an absolute
        // MOVE|LEFTDOWN|ABSOLUTE at the cursor's point, which SNAPS the game's
        // cursor across the screen — and then GCMouse's relative deltas resume
        // from wherever it landed. Click, jump, drift, click, jump: the stutter.
        //
        // The button itself is not lost: GCMouse's own `pressedChangedHandler`
        // already reported it (HardwareInput.button), with no position attached,
        // which is exactly what a mouse-look game wants. So this is pure
        // de-duplication, and it only applies while a real mouse is live.
        // ========================================================================
        if HardwareInput.shared.shouldIgnore(touches, logging: true) { return }
        if desktopMode && touchPointerMode {
            touchModeBegan(touches)
            return
        }
        guard trackpadMode else {
            // Task 2 — "Touch" pointer mode has its own multi-finger state
            // machine (tap/hold/2-3-finger tap), independent of the single-
            // owner `gameTouch` path below.
            if touchPointerMode {
                touchModeBegan(touches)
                return
            }
            // ml666: one owner. A live claim is only replaced when its touch is
            // gone (UIKit deallocated it, or it already ended) — never by a
            // second finger arriving.
            if let held = gameTouch, held.phase != .ended, held.phase != .cancelled {
                Self.refused += 1                                   // ml667
                Self.lastRefusePhase = held.phase.rawValue
                Self.lastRefuseMine = (held.view === self)
                return
            }
            guard let t = touches.first else { return }
            gameTouch = t
            Self.claims += 1                                        // ml667
            if gameRelative {
                let p = t.location(in: self)
                touchStartPoint = p
                lastPanPoint = p
                touchStartTime = Date().timeIntervalSinceReferenceDate
                movedBeyondSlop = false
                relCarryX = 0; relCarryY = 0   // never carry motion across a lift
                return                          // NO button on touch-down
            }
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        let active = activeTouches(event)
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if Self.unifiedPointer && !desktopMode {
            var x: Int32 = 0, y: Int32 = 0
            if winios_get_cursor_position(&x, &y) != 0 { Self.cursor = CGPoint(x: CGFloat(x), y: CGFloat(y)) }
            if !Self.reportedUnifiedPointer {
                Self.reportedUnifiedPointer = true
                fputs("[pointer-routing] ml1170 direct absolute mode uses trackpad motion\n", stderr)
            }
        }
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            guard !self.stopTouchForModal() else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // ml664: the pan recogniser owns pointer motion — a second delta from
        // here would double every click-drag.
        if stopTouchForModal() { return }
        if touches.contains(where: { $0.type == .indirectPointer }) { return }
        // ml665: the down was dropped as synthesised, so its moves must be too —
        // otherwise a click-drag with the AssistiveTouch cursor would turn the
        // camera a second time on top of the GCMouse deltas already doing it.
        if HardwareInput.shared.shouldIgnore(touches, logging: false) { return }
        if desktopMode && touchPointerMode {
            touchModeMoved(touches, event)
            return
        }
        guard trackpadMode else {
            if touchPointerMode {
                touchModeMoved(touches, event)
                return
            }
            guard let t = ownedTouch(touches) else { return }   // ml666
            if gameRelative {
                let p = t.location(in: self)
                let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
                lastPanPoint = p
                if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }
                postRelative(dx, dy)
                return
            }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            postRelative(dx, dy)
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        var screenW: Int32 = 1280, screenH: Int32 = 720
        winios_screen_size(&screenW, &screenH)
        let maxX = CGFloat(max(1, screenW) - 1)
        let maxY = CGFloat(max(1, screenH) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if stopTouchForModal() { return }
        if pointerButtons(touches, with: event, ending: true) { return }    // ml664
        if HardwareInput.shared.shouldIgnore(touches, logging: false) { return }  // ml665
        if desktopMode && touchPointerMode {
            touchModeEnded(touches, event)
            return
        }
        guard trackpadMode else {
            if touchPointerMode {
                touchModeEnded(touches, event)
                return
            }
            guard let t = ownedTouch(touches) else { return }   // ml666
            gameTouch = nil
            if gameRelative {
                // A stationary, quick lift is a click. Posted with NO move
                // flag, so wine clicks wherever the GAME's own cursor is —
                // posting a position here is exactly what makes a mouse-look
                // title snap its aim before firing.
                let now = Date().timeIntervalSinceReferenceDate
                if !movedBeyondSlop && now - touchStartTime < 0.35 {
                    winios_pointer(0, 0, F_LDOWN, 0)
                    winios_pointer(0, 0, F_LUP, 0)
                }
                return
            }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // ml664: a cancelled pointer touch gets no mask worth reading — drop
        // every button rather than guess, the same rule ml661 applies to fingers.
        if touches.contains(where: { $0.type == .indirectPointer }) {
            HardwareInput.shared.uikitButtons([])
            return
        }
        if HardwareInput.shared.shouldIgnore(touches, logging: false) { return }  // ml665
        if desktopMode && touchPointerMode {
            touchModeCancelled(touches)
            return
        }
        guard trackpadMode else {
            if touchPointerMode {
                touchModeCancelled(touches)
                return
            }
            guard let t = ownedTouch(touches) else { return }   // ml666
            gameTouch = nil
            if gameRelative {
                // Nothing to release — relative drags never pressed a button,
                // and a cancelled touch is never a click.
                relCarryX = 0; relCarryY = 0
                return
            }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// ml661 — EVERY HELD CONTROL DECLARES WHAT IT WANTS HELD; NOTHING POSTS EDGES.
///
/// The sticks and buttons used to be edge-triggered in their own `@State`:
/// "the thumb crossed into a new sector, so post W-up and A-down". That is
/// only correct while the view survives to post the closing edge, and a
/// SwiftUI view under a thumb has several ways not to:
///
///   • `DragGesture` has no cancellation callback. A system edge-swipe, the
///     control-centre pull, or another recogniser winning simply means
///     `onEnded` is never called — the key stays down forever.
///   • Toggling the landscape controls off (`TouchControlsModel.visible`), or
///     entering edit mode, or rotating, removes the whole `ForEach` body. The
///     view is gone; `onEnded` will never arrive.
///   • Two controls can bind the same key. Edge-triggered, whichever lifts
///     first releases it out from under the other.
///
/// So ownership replaces edges. A control says "owner 7 wants {W, A}" and this
/// class posts the difference between the union of all owners' wishes and what
/// it has actually sent down. Releasing an owner is a single call that cannot
/// be got wrong, an owner that vanishes takes its keys with it, and a shared
/// key stays down while any owner still wants it.
///
/// On top of that sits a 1Hz reconciler. It compares this app-side intent
/// against `winios_held_keys()` — what the DRIVER was actually told — and
/// repairs a disagreement that survives three ticks: a key wine thinks is down
/// that nobody wants gets an up, a key an owner wants that never reached wine
/// gets its down re-sent. That makes a lost transition self-healing rather
/// than permanent, whatever loses it.
final class InputGuard {
    static let shared = InputGuard()

    /// owner → the virtual-keys that owner currently wants held.
    private var wants: [Int: Set<Int32>] = [:]
    /// owner → mouse buttons that owner wants held. See `Btn`.
    private var wantBtns: [Int: Set<Int>] = [:]

    /// ml663 — the five buttons a real mouse has. On-screen controls only ever
    /// ask for `.left`/`.right`; a Bluetooth mouse asks for all of them, and
    /// they go through the SAME ownership union so an on-screen fire button and
    /// a physical left button cannot release each other's press.
    enum Btn {
        static let left = 0, right = 1, middle = 2, x1 = 3, x2 = 4
    }

    /// MOUSEEVENTF_* for one button edge. `data` carries XBUTTON1/2, which is
    /// how X1 and X2 are told apart — they share one flag pair.
    static func postButton(_ b: Int, down: Bool) {
        let flags: UInt32
        var data: UInt32 = 0
        switch b {
        case Btn.left:   flags = down ? 0x0002 : 0x0004
        case Btn.right:  flags = down ? 0x0008 : 0x0010
        case Btn.middle: flags = down ? 0x0020 : 0x0040
        case Btn.x1:     flags = down ? 0x0080 : 0x0100; data = 1
        case Btn.x2:     flags = down ? 0x0080 : 0x0100; data = 2
        default: return
        }
        winios_pointer(0, 0, flags, data)
    }
    /// What we have actually posted a DOWN for and not yet an UP.
    private var keysDown: Set<Int32> = []
    private var btnsDown: Set<Int> = []

    private var ticker: Timer?
    private var mismatch = 0
    private var heartbeat = 0

    private static var ownerSeq = 0
    /// Stable per-view identity. Stored in `@State`, so it is created once per
    /// view identity and survives re-renders (which is exactly the lifetime a
    /// held key has to be tied to).
    static func newOwner() -> Int { ownerSeq += 1; return ownerSeq }

    private init() {
        let nc = NotificationCenter.default
        // Backgrounding, a phone call, the app switcher: the finger is gone and
        // no gesture callback is coming. Release everything, both sides.
        //
        // ml662: memory warnings join the list. They are the one event that can
        // tear down and rebuild view state under a thumb WITHOUT a scene phase
        // change, so a control holding a key through one has nothing else that
        // would notice.
        for n in [UIApplication.willResignActiveNotification,
                  UIApplication.didEnterBackgroundNotification,
                  UIApplication.didReceiveMemoryWarningNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.releaseAll("scene-inactive")
            }
        }
    }

    // MARK: intent

    func hold(_ owner: Int, keys: Set<Int32>) {
        wants[owner] = keys.isEmpty ? nil : keys
        sync()
    }

    func hold(_ owner: Int, buttons: Set<Int>) {
        wantBtns[owner] = buttons.isEmpty ? nil : buttons
        sync()
    }

    /// The one call a control makes when it stops being held — for any reason,
    /// including reasons it cannot detect (see `.onDisappear` / `@GestureState`
    /// at each call site).
    func release(_ owner: Int) {
        guard wants[owner] != nil || wantBtns[owner] != nil else { return }
        wants[owner] = nil
        wantBtns[owner] = nil
        sync()
    }

    func releaseAll(_ reason: String) {
        let had = keysDown.count + btnsDown.count
        wants.removeAll()
        wantBtns.removeAll()
        sync()
        AimStickDriver.shared.stopAll()
        // ml662: and forget the touches that were holding them, so the faces go
        // dark and a finger still on the glass when the app comes back does not
        // resume a press it never re-began. Each track releases its own owner,
        // which after the removeAll above is already a no-op.
        ControlOverlayView.shared.dropAllTouches(reason)
        // Belt and braces: whatever the app believes, clear what the DRIVER
        // believes. These are the two independent held-sets and either can be
        // the stale one.
        winios_release_all_keys()
        if had > 0 { fputs("[input] releaseAll(\(reason)) released \(had)\n", stderr) }
    }

    private func sync() {
        let wantKeys = wants.values.reduce(into: Set<Int32>()) { $0.formUnion($1) }
        for vk in keysDown.subtracting(wantKeys) { winios_post_key(vk, 0) }
        for vk in wantKeys.subtracting(keysDown) { winios_post_key(vk, 1) }
        keysDown = wantKeys

        let wantBtn = wantBtns.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        for b in btnsDown.subtracting(wantBtn) { InputGuard.postButton(b, down: false) }
        for b in wantBtn.subtracting(btnsDown) { InputGuard.postButton(b, down: true) }
        btnsDown = wantBtn

        startTickerIfNeeded()
    }

    // MARK: reconciler / diagnostics

    /// The aim stick holds no keys, so `sync()` never runs for it — but a stick
    /// stuck "held" is precisely the failure worth watching. Let it arm the
    /// reconciler too.
    func pokeTicker() { startTickerIfNeeded() }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        var mask = [UInt32](repeating: 0, count: 8)
        let drvCount = mask.withUnsafeMutableBufferPointer {
            Int(winios_held_keys($0.baseAddress))
        }
        var drv = Set<Int32>()
        for vk in 0..<256 where (mask[vk >> 5] & (UInt32(1) << UInt32(vk & 31))) != 0 {
            drv.insert(Int32(vk))
        }

        let stuck = drv.subtracting(keysDown)        // wine holds what nobody wants
        let lost  = keysDown.subtracting(drv)        // an owner wants what wine never got

        // ml661: one line that names BOTH held-sets and the aim clock, every
        // four seconds while anything is held. Pair it with winios.m's
        // "[input] ring ..." line and a future report of dead input says which
        // stage lost it — app intent, the ring, or the driver — instead of
        // leaving it to be guessed at.
        heartbeat += 1
        if heartbeat % 4 == 0,
           !keysDown.isEmpty || !btnsDown.isEmpty || drvCount > 0 || AimStickDriver.shared.isRunning {
            // ml666: `owners` is the number of distinct intents in the union.
            // An owner that outlives its finger is invisible to the stuck/lost
            // comparison above (app and driver AGREE that the key is down —
            // they are both wrong together), so this count is the one number
            // that names it: owners standing higher than the controls actually
            // under a thumb is a held-forever key.
            fputs("[input] app keys=\(hex(keysDown)) btns=\(btnsDown.sorted()) " +
                  "owners=\(Set(wants.keys).union(wantBtns.keys).count) " +
                  "drv=\(hex(drv)) aim(holders=\(AimStickDriver.shared.holderCount) " +
                  "link=\(AimStickDriver.shared.isRunning))\n", stderr)
        }

        if stuck.isEmpty && lost.isEmpty {
            mismatch = 0
            if keysDown.isEmpty && btnsDown.isEmpty && drvCount == 0
                && !AimStickDriver.shared.isRunning {
                ticker?.invalidate(); ticker = nil   // nothing held anywhere: stand down
            }
            return
        }

        mismatch += 1
        // Three seconds of disagreement is not a drain that is merely late —
        // even a badly stalled frame drains eventually. Repair it.
        guard mismatch >= 3 else { return }
        mismatch = 0
        fputs("[input] reconcile stuck=\(hex(stuck)) lost=\(hex(lost)) " +
              "app=\(hex(keysDown)) drv=\(hex(drv))\n", stderr)
        // Repair only the keys that actually disagree. A blanket
        // winios_release_all_keys() here would also drop the keys a thumb is
        // legitimately holding, and they would not come back until the next
        // reconcile — three seconds of not walking to fix one stuck key.
        for vk in stuck { winios_post_key(vk, 0) }
        for vk in lost  { winios_post_key(vk, 1) }
    }

    private func hex(_ s: Set<Int32>) -> String {
        "[" + s.sorted().map { String(format: "%02x", $0) }.joined(separator: ",") + "]"
    }
}

/// Hold-to-press key. ml662: visual only — the key is held by
/// ControlOverlayView for exactly as long as ITS touch lasts, so a second
/// finger landing anywhere can no longer cancel the press.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @ObservedObject private var face: ControlFaceState
    private let rid: String

    init(label: String, vk: Int32, big: Bool = false) {
        self.label = label; self.vk = vk; self.big = big
        // Identity is the KEY, not the view: two buttons bound to the same
        // virtual-key are the same control as far as input is concerned, and
        // InputGuard already unions their intent.
        let id = String(format: "hold.%02x", vk)
        self.rid = id
        _face = ObservedObject(wrappedValue: ControlFaces.state(id))
    }

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(face.down ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .controlRegion(rid, label, .keys([vk]))
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    /// The directional (arrow-key) stick.
    ///
    /// ml666: the only one. There was a second instance for the portrait aim
    /// stick; that control is gone (see the ml666 note at the portrait key
    /// row), and with it the reason for the pad to draw more than one face.
    static let shared = JoystickPadState()

    @Published var held = false
    @Published var dir: Int = -1
    /// ml660: continuous knob offset, −1…1 per axis, for the aim stick. The
    /// directional stick leaves this nil and steers by `dir` (8-way snap),
    /// because it drives KEYS and a key is either down or not.
    @Published var vec: CGSize?
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
    /// SF Symbol drawn in the face, so two identical-looking sticks are
    /// telling apart at a glance.
    let glyph: String?

    init(glyph: String? = nil) { self.glyph = glyph }
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = controlOverlayWindowBounds(in: scene)
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    var body: some View {
        GeometryReader { _ in
            // ml666: one face, for the directional stick. The aim stick that
            // shared this overlay has been removed from the HUD.
            ZStack(alignment: .topLeading) {
                JoystickPadFace(s: JoystickPadState.shared)
            }
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset below
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One stick's face in the window-level overlay.
struct JoystickPadFace: View {
    @ObservedObject var s: JoystickPadState

    var body: some View {
        Group {
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir, vec: s.vec, glyph: s.glyph)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        .opacity(s.hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
        // ml660: `vec` is DELIBERATELY not in an .animation(value:) list — the
        // aim knob must sit exactly under the thumb, and a spring on it would
        // both lag the finger and smear the deflection the driver reads. The
        // spring-back on release still happens, because `held` flips in the
        // same transaction and that animation covers every change in it.
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    /// ml660: continuous knob deflection, −1…1 per axis. Set by the aim stick;
    /// when non-nil it REPLACES the 8-way `dir` offset, so one face serves both
    /// a d-pad-shaped stick (keys, snapped) and an analogue one (mouse-look).
    var vec: CGSize?
    /// ml660: SF Symbol identifying what this stick drives. Drawn in the middle
    /// of the ring: alone at idle size (where a knob plus a glyph is a smudge)
    /// and dimmed behind the knob when expanded, where deflecting reveals it.
    var glyph: String?
    private var expanded: Bool { held || alwaysExpanded }

    // ml — was a bare `22`; that is exactly `keyRowButtonSize * 0.5` at the
    // constant's old value of 44, so tying it to the constant keeps the same
    // ratio (and keeps the ring inside its cell) at 36 and at any future
    // resize, instead of silently drifting out of proportion the next time
    // only one of the two numbers gets changed.
    static var idleDiameter: CGFloat { keyRowButtonSize * 0.5 }
    // The EXPANDED pad is a permanent, off-grid size — it must not shrink
    // just because the idle ring's cell did.
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    @ViewBuilder private var interior: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard expanded else { return .zero }
        let travel = d * knobTravelRatio
        if let v = vec {
            return CGSize(width: travel * v.width, height: travel * v.height)
        }
        guard dir >= 0 else { return .zero }
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        return ZStack {
            interior
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            if let g = glyph {
                Image(systemName: g)
                    .font(.system(size: d * (expanded ? 0.30 : 0.62), weight: .medium))
                    .foregroundColor(.white)
                    .opacity(expanded ? 0.42 : 0.95)
            }
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .offset(knobOffset(d))
                // At idle size a glyph-bearing stick shows the GLYPH instead of
                // the knob — 9pt of white disc plus a 2pt symbol is unreadable
                // mush, and the glyph is the whole point of the distinction.
                .opacity(glyph == nil || expanded ? 1 : 0)
        }
        .frame(width: d, height: d)
    }
}

/// ml660 — AIM STICK ENGINE (velocity-control mouse-look).
///
/// The directional stick posts KEY events, so it is edge-triggered: press W,
/// later release W. A mouse has no such thing as "held right" — a game reads
/// motion, and a stick that is merely deflected is producing motion for as long
/// as it is held. So this is a clock, not an event handler: a CADisplayLink
/// converts the current deflection into a delta every frame, `dx = deflection ×
/// sensRel × fullRate × Δt`, and posts it as RELATIVE motion.
///
/// Relative, specifically — the same path the pointer panel's "Relative" mode
/// uses: `winios_pointer(dx, dy, MOUSEEVENTF_MOVE, 0)` with NO MOUSEEVENTF_
/// ABSOLUTE. The wineserver adds our delta to its own cursor
/// (`x = cursor.x + input->mouse.x`) and hands raw input `x - cursor.x`, i.e.
/// exactly our delta, BEFORE any clamping happens — so aiming never stalls at
/// a screen edge or inside a game's ClipCursor rect. Nothing new is needed on
/// the driver side.
///
/// Δt comes from the display link rather than being assumed to be 1/60, so the
/// same deflection turns the camera at the same rate on a 60Hz and a 120Hz
/// panel, and a dropped frame does not eat the motion it was carrying.
final class AimStickDriver {
    static let shared = AimStickDriver()

    /// Mouse counts per second at full deflection with sensRel == 1.0. The
    /// slider (0.10…8.0, default 2.0) scales it, so the default is ~720
    /// counts/s flat out — about a fast-but-controllable drag.
    static let fullRate: CGFloat = 360

    private var link: CADisplayLink?
    // Same truncation problem as ml641's relCarryX: at low sensitivity the
    // per-frame delta is a fraction, and Int32() of a fraction is zero forever.
    private var carryX: CGFloat = 0, carryY: CGFloat = 0

    /// ml661 — HOLDERS ARE TOKENS, NOT A COUNT.
    ///
    /// Portrait and landscape can both have an aim stick on screen, so the
    /// clock is shared and needs to stop when the last thumb lifts. A bare
    /// `holders += 1 / -= 1` counter gets that wrong in both directions: a
    /// `begin()` whose `end()` never arrives (the gesture was cancelled, or the
    /// control was removed mid-hold) pins the count above zero FOREVER, and
    /// because the last deflection is still latched, the display link keeps
    /// posting 60–120 relative moves a second into the event ring for the rest
    /// of the session. That is not merely a stuck camera: it is the flood that
    /// used to bury every key and button transition behind it.
    ///
    /// Keyed by owner instead, the operation is idempotent — a duplicate
    /// `end()` is a no-op, a missing one is repaired the moment that owner
    /// disappears or is released, and `stopAll()` can always clear the lot.
    /// Each owner also carries its own deflection, so one stick lifting cannot
    /// leave the other's vector latched.
    private var vecs: [Int: CGSize] = [:]

    func begin(_ owner: Int) {
        if vecs[owner] == nil { vecs[owner] = .zero }
        InputGuard.shared.pokeTicker()
        guard link == nil else { return }
        carryX = 0; carryY = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Deflection, −1…1 per axis, y positive DOWN (screen sense). Sign matches
    /// the drag path: push right → view turns right, like a mouse.
    func steer(_ owner: Int, _ v: CGSize) {
        guard vecs[owner] != nil else { return }   // not holding: ignore stragglers
        vecs[owner] = CGSize(width: v.width.isFinite ? v.width : 0,
                             height: v.height.isFinite ? v.height : 0)
    }

    func end(_ owner: Int) {
        guard vecs.removeValue(forKey: owner) != nil else { return }
        guard vecs.isEmpty else { return }
        stopAll()
    }

    /// Unconditional halt: the app resigned active, or the reconciler decided
    /// nothing can legitimately still be held.
    func stopAll() {
        vecs.removeAll()
        carryX = 0; carryY = 0
        link?.invalidate()
        link = nil
    }

    var isRunning: Bool { link != nil }
    var holderCount: Int { vecs.count }

    /// Sum of every holder's deflection, clamped to unit length — two thumbs on
    /// two aim sticks add, they do not multiply the rate.
    private var vector: CGSize {
        var x: CGFloat = 0, y: CGFloat = 0
        for v in vecs.values { x += v.width; y += v.height }
        let d = (x * x + y * y).squareRoot()
        if d > 1 { x /= d; y /= d }
        return CGSize(width: x, height: y)
    }

    @objc private func tick(_ l: CADisplayLink) {
        let v = vector
        let vx = v.width, vy = v.height
        guard vx != 0 || vy != 0 else { return }
        let dt = max(min(l.targetTimestamp - l.timestamp, 1.0 / 15.0), 1.0 / 240.0)
        let k = CGFloat(InputSettings.shared.sensRel) * Self.fullRate * CGFloat(dt)
        carryX += vx * k
        carryY += vy * k
        let ix = Int32(max(-30000, min(30000, carryX)))
        let iy = Int32(max(-30000, min(30000, carryY)))
        carryX -= CGFloat(ix)
        carryY -= CGFloat(iy)
        if ix != 0 || iy != 0 { winios_pointer(ix, iy, 0x0001 /* MOUSEEVENTF_MOVE */, 0) }
    }
}

// ============================================================================
// ml662 — ONE UIKIT MULTI-TOUCH LAYER FOR EVERY ON-SCREEN CONTROL.
//
// ml661 made a control that STOPS being held release correctly. It could not
// make a control be held in the first place, because that was never in our
// hands: every control was a SwiftUI `DragGesture(minimumDistance: 0)` and
// SwiftUI gestures are arbitrated by UIGestureRecognizers, which are built for
// ONE gesture at a time on a scrolling document — not for four thumbs on a
// gamepad. Concretely, and all three were reported from the same build:
//
//   • A button only fires once its recogniser reaches .began. A simultaneous
//     recogniser elsewhere (the live view's, the other window's, a system edge
//     gesture) can delay that transition past the lift, or fail it outright.
//     The tap is simply never delivered — "the buttons still aren't 100%
//     being registered".
//   • A second touch ANYWHERE makes UIKit re-run arbitration, and the losing
//     recogniser is cancelled. `@GestureState` resets, ml661's cancel path
//     correctly releases the stick — and the aim stick dies mid-aim because a
//     stray finger brushed the live view. Correct behaviour, wrong cause.
//   • `onEnded` can arrive late or, after a cancellation, never.
//
// None of that is fixable inside the gesture model, so the gesture model is
// gone from the play path. Raw UIKit multi-touch has exactly the semantics a
// gamepad needs and has had them since 2008: `touchesBegan/Moved/Ended/
// Cancelled` deliver every finger independently, each `UITouch` keeps its
// identity from began to ended, and a touch delivered to one view is unaffected
// by touches delivered to another.
//
// So: ONE `ControlOverlayView`, a plain multi-touch UIView sitting at the very
// top of the window stack, owns every control's touch. Controls are REGIONS in
// window coordinates, registered by the SwiftUI views that draw them (the
// `.controlRegion` modifier below), so layout stays declarative and only input
// moves. The rules are the ones the failures name:
//
//   1. The region under a touch's INITIAL location owns that touch until it
//      ends or is cancelled. No other touch can take it, release it, or
//      cancel it.
//   2. A stick follows its own touch's `location(in:)` even far outside its
//      frame; a button releases if its own finger slides off (and re-presses
//      if it slides back).
//   3. `hitTest` returns nil everywhere except on a region, so the live view
//      keeps every touch that is not on a control — and because those touches
//      land in a DIFFERENT view (and a different window), they cannot cancel a
//      control's touch.
//   4. `InputGuard` still owns everything actually posted, keyed per TOUCH
//      rather than per view — so a duplicate release is a no-op and a touch
//      that vanishes takes its keys with it.
// ============================================================================

/// What a region does while a finger is on it.
enum ControlRegionKind: Equatable {
    /// Hold these virtual-keys for exactly as long as the touch lasts.
    case keys(Set<Int32>)
    /// Momentary: down on began, up 60 ms later. The portrait ⏎/␣/Esc row.
    case tapKey(Int32)
    /// Hold these mouse buttons (0 = left, 1 = right).
    case buttons(Set<Int>)
    /// 8-way snapped stick over four keys, in order up/right/down/left.
    case dirStick(quad: [Int32], deadzone: CGFloat)
    /// Analogue stick feeding AimStickDriver.
    case aimStick(deadzone: CGFloat, travel: CGFloat)
    /// Raise/lower the iOS software keyboard.
    case keyboardToggle
    /// Hit-tests and lights up, posts nothing: `.none` and the legacy unwired
    /// `.pad` glyph. Deliberately still a region — swallowing the touch is the
    /// whole point, or an inert button would swing the camera.
    case inert

    // ml670 — THE ON-SCREEN HALF OF XINPUT.
    //
    // These three are the touch-layer shapes of a VIRTUAL CONTROLLER. They post
    // no keys and take no `InputGuard` owner: what they mutate is
    // `OnScreenPad`, whose merged sample `HardwareInput` publishes into the
    // same `winios_gamepad_set_state` slot a physical pad fills. So a game
    // reading XInput cannot tell a thumb from a controller, which is the entire
    // point — everything below the seqlock already works and needed nothing.

    /// Hold one XInput button (or drive one analogue trigger to 255) for
    /// exactly as long as the touch lasts.
    case padButton(PadButton)
    /// One cross-shaped control holding the four D-pad bits, 8-way snapped so a
    /// diagonal sets two exactly as a real pad does.
    case padDPad(deadzone: CGFloat)
    /// Analogue thumbstick: deflection −1…1 per axis, scaled to XInput units
    /// by `OnScreenPad`. `right` picks rx/ry over lx/ly.
    case padStick(right: Bool, deadzone: CGFloat, travel: CGFloat)

    var isStick: Bool {
        switch self {
        case .dirStick, .aimStick, .padStick: return true
        default: return false
        }
    }
    /// Does this region contribute to the virtual controller? `register` and
    /// `unregister` use it to decide whether slot 0 has an on-screen source at
    /// all, which is what marks it connected with no physical pad attached.
    var isPadKind: Bool {
        switch self {
        case .padButton, .padDPad, .padStick: return true
        default: return false
        }
    }
    var name: String {
        switch self {
        case .keys:           return "keys"
        case .tapKey:         return "tap"
        case .buttons:        return "btn"
        case .dirStick:       return "dirstick"
        case .aimStick:       return "aimstick"
        case .keyboardToggle: return "kbd"
        case .inert:          return "inert"
        case .padButton:      return "padbtn"
        case .padDPad:        return "paddpad"
        case .padStick:       return "padstick"
        }
    }
}

// ============================================================================
// ml670 — THE VIRTUAL CONTROLLER
//
// WHY THIS IS A SEPARATE OBJECT AND NOT A FIELD ON `ControlOverlayView`.
// The sample is produced on the MAIN thread (a touch) and consumed on
// `HardwareInput.padQueue` (the 4 ms sampler). One lock-guarded aggregate with
// a value-type snapshot is the whole of the thread story, and it is the same
// story `PadSnapshot` already tells for the physical pad: built on one thread,
// compared there, carried by copy.
//
// CONTRIBUTIONS ARE KEYED BY REGION, not accumulated as edges. The same rule
// ml661 wrote for keys — state the SET, never the edges — for exactly the same
// reason: a lost "up" from a cancelled touch would otherwise pin a button down
// for the session, and that is the single most reported symptom in this file's
// history. A region that stops contributing removes its entry; the aggregate is
// recomputed from what is left, so nothing can leak.
//
// PRESENCE IS NOT PRESSURE. `present` counts REGISTERED pad controls, not held
// ones: XInput's contract is that a connected controller answers with zeroes,
// and a slot that only appears on the first press would read to a game as a
// controller being hot-plugged mid-frame.
// ============================================================================
final class OnScreenPad {
    static let shared = OnScreenPad()

    /// What one region is contributing right now.
    private struct Contribution {
        var buttons: UInt16 = 0
        var lt: UInt8 = 0, rt: UInt8 = 0
        var lvec: CGSize?
        var rvec: CGSize?
    }

    private let lock = NSLock()
    private var parts: [String: Contribution] = [:]
    /// What each region is CALLED, so the release line can name the button and
    /// not the opaque region id — a log that says `A up` is readable, one that
    /// says `ctl.3f1a90c2 up` is a lookup.
    private var names: [String: String] = [:]
    private var agg = HardwareInput.PadSnapshot()
    private var present = 0

    /// Diagnostics for the rate-limited `[xinput] onscreen …` line.
    private var logged = 0
    private var lastLogAt: CFTimeInterval = 0

    /// The merged on-screen sample plus whether any pad control exists at all.
    func snapshot() -> (sample: HardwareInput.PadSnapshot, live: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (agg, present > 0)
    }

    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return present > 0 }

    /// `ControlOverlayView.register`/`unregister` publish how many pad-kind
    /// regions the layout currently has. The sampler has to be running for the
    /// slot to stay connected, so a change either starts or stops it.
    func setPresent(_ n: Int) {
        lock.lock()
        let was = present
        present = n
        lock.unlock()
        guard (was > 0) != (n > 0) else { return }
        fputs("[xinput] onscreen controls \(n > 0 ? "present" : "gone") (regions=\(n))\n", stderr)
        HardwareInput.shared.padScreenPresence(n > 0)
    }

    // MARK: contributions (main thread)

    func press(_ rid: String, _ b: PadButton) {
        var c = Contribution()
        switch b {
        case .lt: c.lt = 255
        case .rt: c.rt = 255
        case .leftStick:  c.lvec = .zero      // a stick control held but centred
        case .rightStick: c.rvec = .zero
        default:  c.buttons = b.mask
        }
        apply(rid, c, log: b.label, down: true)
    }

    /// 8-way D-pad, `dir` the same 0-7 (0 = up, clockwise) the thumb sticks use,
    /// −1 centred.
    func dpad(_ rid: String, dir: Int) {
        var c = Contribution()
        let up = PadButton.dpadUp.mask, rt = PadButton.dpadRight.mask
        let dn = PadButton.dpadDown.mask, lf = PadButton.dpadLeft.mask
        switch dir {
        case 0: c.buttons = up
        case 1: c.buttons = up | rt
        case 2: c.buttons = rt
        case 3: c.buttons = dn | rt
        case 4: c.buttons = dn
        case 5: c.buttons = dn | lf
        case 6: c.buttons = lf
        case 7: c.buttons = up | lf
        default: break
        }
        apply(rid, c, log: "D-pad\(dir)", down: dir >= 0)
    }

    /// Analogue deflection, −1…1 per axis, screen sense (y grows DOWN). XInput
    /// reports y positive UP, so the one negation lives here and nowhere else.
    func stick(_ rid: String, right: Bool, vec: CGSize) {
        var c = Contribution()
        if right { c.rvec = vec } else { c.lvec = vec }
        apply(rid, c, log: right ? "R-stick" : "L-stick", down: vec != .zero)
    }

    func clear(_ rid: String) {
        lock.lock()
        guard parts.removeValue(forKey: rid) != nil else { lock.unlock(); return }
        let name = names.removeValue(forKey: rid) ?? rid
        let before = agg
        recompute()
        let after = agg
        lock.unlock()
        note("up", rid: name, before: before, after: after)
        if before != after { HardwareInput.shared.padScreenChanged() }
    }

    func clearAll() {
        lock.lock()
        guard !parts.isEmpty else { lock.unlock(); return }
        parts.removeAll()
        names.removeAll()
        let before = agg
        recompute()
        lock.unlock()
        if before != agg { HardwareInput.shared.padScreenChanged() }
    }

    private func apply(_ rid: String, _ c: Contribution, log: String, down: Bool) {
        lock.lock()
        parts[rid] = c
        names[rid] = log
        let before = agg
        recompute()
        let after = agg
        lock.unlock()
        note(down ? "down" : "up", rid: log, before: before, after: after)
        // Immediately, not on the next 4 ms tick: a transition is the one thing
        // a gamepad reader must never have to wait for.
        if before != after { HardwareInput.shared.padScreenChanged() }
    }

    /// lock held.
    private func recompute() {
        var b: UInt16 = 0, lt: UInt8 = 0, rt: UInt8 = 0
        var lv = CGSize.zero, rv = CGSize.zero
        for c in parts.values {
            b |= c.buttons
            lt = max(lt, c.lt)
            rt = max(rt, c.rt)
            // Sum then clamp: two controls both claiming a stick is a layout
            // mistake, not a crash, and the clamp keeps the result legal.
            if let v = c.lvec { lv.width += v.width; lv.height += v.height }
            if let v = c.rvec { rv.width += v.width; rv.height += v.height }
        }
        var s = HardwareInput.PadSnapshot()
        s.buttons = b
        s.lt = lt; s.rt = rt
        s.lx = Self.axis(lv.width);  s.ly = Self.axis(-lv.height)
        s.rx = Self.axis(rv.width);  s.ry = Self.axis(-rv.height)
        agg = s
    }

    private static func axis(_ v: CGFloat) -> Int16 {
        let s = (Double(min(max(v, -1), 1)) * 32767.0).rounded()
        return Int16(max(-32768.0, min(32767.0, s)))
    }

    /// Rate-limited so a stick held against the gate cannot bury the log: every
    /// one of the first 64 transitions, then at most one a second.
    private func note(_ what: String, rid: String, before: HardwareInput.PadSnapshot,
                      after: HardwareInput.PadSnapshot) {
        guard before != after else { return }
        let now = CACurrentMediaTime()
        guard logged < 64 || now - lastLogAt >= 1.0 else { return }
        logged += 1
        lastLogAt = now
        fputs(String(format: "[xinput] onscreen %@ %@ buttons=0x%04x lt=%d rt=%d "
                     + "lx=%d ly=%d rx=%d ry=%d\n", rid, what, Int(after.buttons),
                     Int(after.lt), Int(after.rt), Int(after.lx), Int(after.ly),
                     Int(after.rx), Int(after.ry)), stderr)
    }
}

/// One control's hit area, in WINDOW coordinates — the same space SwiftUI's
/// `.global` frames are measured in, which is why both the portrait key row
/// (app window) and the landscape overlay (controls window) can register into
/// one list without any conversion.
struct ControlRegion {
    let id: String
    /// Human label for the log line; may change when a control is remapped,
    /// which is why it is NOT the identity.
    var label: String
    var frame: CGRect
    var kind: ControlRegionKind
    /// Round controls hit-test as circles so neighbouring sticks cannot steal
    /// each other's corners; the portrait row's rectangular keys do not.
    var circular = false
    /// How far a finger may slide past the edge before a button releases.
    var slideOff: CGFloat = 20
    /// The window-level pad face this region drives, if any (portrait sticks).
    /// Landscape sticks draw themselves and leave this nil.
    weak var pad: JoystickPadState?

    func hit(_ p: CGPoint, slack: CGFloat = 0) -> Bool {
        if circular {
            let c = CGPoint(x: frame.midX, y: frame.midY)
            return hypot(p.x - c.x, p.y - c.y) <= max(frame.width, frame.height) / 2 + slack
        }
        return frame.insetBy(dx: -slack, dy: -slack).contains(p)
    }
}

/// Per-control visual state, published by the UIKit layer and observed by the
/// SwiftUI view that draws that control.
///
/// One object PER REGION, not one dictionary for all of them: the aim stick
/// republishes its deflection every display frame, and a single shared
/// `ObservableObject` would redraw every other button on screen 120 times a
/// second for it.
final class ControlFaceState: ObservableObject {
    @Published var down = false
    @Published var dir: Int = -1
    @Published var vec: CGSize?
}

enum ControlFaces {
    private static var map: [String: ControlFaceState] = [:]
    /// Main-thread only (touch handling and SwiftUI body evaluation both are).
    ///
    /// Entries are deliberately NEVER removed. A control that is hidden and
    /// shown again — the pointer panel, a rotation, toggling the overlay off —
    /// must come back to the SAME object the touch layer publishes into, or the
    /// view would observe one instance while the layer wrote to another and the
    /// button would never light up again. There are a handful of these, each a
    /// few bytes.
    static func state(_ id: String) -> ControlFaceState {
        if let s = map[id] { return s }
        let s = ControlFaceState()
        map[id] = s
        return s
    }
}

/// The single multi-touch layer. Transparent, sits above everything, and
/// hit-tests to nothing except a registered region.
final class ControlOverlayView: UIView {
    static let shared = ControlOverlayView(frame: .zero)

    private var order: [String] = []
    private var regions: [String: ControlRegion] = [:]
    /// ml — WHO CURRENTLY OWNS EACH REGION ID.
    ///
    /// `id` is deliberately shared between rotation-swapped view instances
    /// (e.g. `JoystickKeyView.rid == "portrait.dpad"` in both portraitBody and
    /// wideNormalBody) so the overlay treats them as one logical control. But
    /// SwiftUI gives no ordering guarantee between an outgoing instance's
    /// `.onDisappear` and an incoming instance's `.onAppear` across a body
    /// swap. When the disappear fires SECOND, an unregister keyed only by
    /// `id` would delete the brand-new instance's just-published
    /// registration a moment after it landed — dead controls until the next
    /// re-register. `register`/`unregister`/`reframe` are keyed by an
    /// instance-scoped token (see `ControlRegionModifier.owner` below) so a
    /// stale call from an instance that no longer owns `id` is a no-op.
    private var owners: [String: UUID] = [:]

    /// What one finger is doing. Keyed by `ObjectIdentifier(UITouch)` — the
    /// identity UIKit guarantees stable from began to ended/cancelled, and the
    /// thing rule 1 above is actually about.
    private struct Track {
        let region: String
        let owner: Int
        let start: CGPoint
        let seq: Int
        let began: CFTimeInterval
        /// ml666 — THE TOUCH ITSELF, weakly.
        ///
        /// `ObjectIdentifier` is an ADDRESS, and UIKit recycles `UITouch`
        /// objects between sequences: a table keyed only by the address cannot
        /// tell "the same finger, still down" from "a new finger that happens to
        /// have been handed the same object". Keeping the object lets every
        /// sweep below ask UIKit itself — is this touch still alive, is it still
        /// the one I began with, what phase does it think it is in — instead of
        /// trusting a key that can silently mean two different fingers.
        weak var touch: UITouch?
        /// Consecutive events in which UIKit did not list this touch as live.
        /// Two strikes, not one: an event's touch set is assembled before
        /// delivery, so a single absence is not proof of anything and reaping a
        /// finger that IS on the glass would release a key mid-hold.
        var misses = 0
        /// Button whose finger has slid off the edge: released, but still ours.
        var lapsed = false
    }
    private var tracked: [ObjectIdentifier: Track] = [:]

    private var touchSeq = 0
    private var nBegan = 0, nEnded = 0, nCancelled = 0, nMissed = 0, nRecovered = 0
    private var reportTimer: Timer?
    private var healthTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The two lines this whole class exists for.
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        isUserInteractionEnabled = true
        backgroundColor = .clear
        GamepadEventClaim.install(on: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: registration

    func register(_ r: ControlRegion, owner: UUID) {
        if regions[r.id] == nil { order.append(r.id) }
        regions[r.id] = r
        owners[r.id] = owner
        // ml670: a re-register can turn a keyboard control into a pad control
        // or back, so the count is recomputed rather than incremented.
        publishPadPresence()
        startHealthMonitor()   // ml666: armed as soon as there is a control to lose
        r.pad?.center = CGPoint(x: r.frame.midX, y: r.frame.midY)
        // A region with no window behind it is a control that silently does
        // nothing, which is the exact failure this revision exists to end. Any
        // registration therefore guarantees the host window. Async because we
        // are inside a SwiftUI update; attach() is idempotent, so a burst of
        // registrations in one turn still creates exactly one window.
        if window == nil {
            DispatchQueue.main.async { TouchControlsHost.attach() }
        }
        logRegistration(r)
    }

    func reframe(_ id: String, _ f: CGRect, owner: UUID) {
        guard var r = regions[id], owners[id] == owner, r.frame != f else { return }
        r.frame = f
        regions[id] = r
        r.pad?.center = CGPoint(x: f.midX, y: f.midY)
    }

    /// The view drawing this control went away (controls hidden, edit mode,
    /// rotation, the pointer panel replacing the key row). Anything its finger
    /// was holding goes with it — that is ml661's rule, enforced here once
    /// instead of at four call sites.
    ///
    /// `owner` must still be on record for `id`: see the `owners` doc comment
    /// above. A call from an instance that has already been superseded is
    /// silently ignored instead of deleting the superseding instance's live
    /// registration.
    func unregister(_ id: String, owner: UUID) {
        guard regions[id] != nil, owners[id] == owner else { return }
        // Array(): finish() mutates `tracked`, and a dictionary's key view is a
        // live projection of it.
        for k in Array(tracked.keys) where tracked[k]?.region == id {
            finish(key: k, why: "unregistered")
        }
        regions[id] = nil
        owners[id] = nil
        order.removeAll { $0 == id }
        OnScreenPad.shared.clear(id)
        publishPadPresence()
    }

    /// ml — BELT AND SUSPENDERS against a region surviving the mode it
    /// belongs to (Task 1, fullscreen-cursor investigation).
    ///
    /// `unregister` above is owner-checked and depends on the outgoing
    /// SwiftUI view's `.onDisappear` actually firing before the incoming
    /// mode's first touch. Every registered region is a live claim on screen
    /// space — `region(at:)`, and therefore `ControlsWindow.hitTest`, treats
    /// ANY registered region as "this point belongs to a control, not the
    /// live view" — so a region that outlives its view keeps claiming its
    /// OLD position after the layout that put it there is gone. The
    /// portrait/wide-normal key row's ids ("portrait.*") and fullscreen's
    /// user-placed controls ("ctl.*") occupy completely different screen
    /// positions in completely different bodies, so a leftover one can end
    /// up sitting in the middle of the live view in the mode that follows
    /// it — exactly the shape of "taps/drags on the game area do nothing"
    /// with no visible control to blame, because the stale region draws
    /// nothing; it only steals hit-testing.
    ///
    /// Called from `FullscreenState.active`'s didSet on every transition.
    /// A no-op whenever `.onDisappear` already did its job — the common
    /// case — so this costs nothing beyond a dictionary walk; it exists
    /// purely to make a lost teardown self-healing instead of sticky for
    /// the rest of the session.
    func dropRegions(unless keep: (String) -> Bool) {
        for id in Array(order) where !keep(id) {
            for k in Array(tracked.keys) where tracked[k]?.region == id {
                finish(key: k, why: "mode-switch-stale")
            }
            regions[id] = nil
            owners[id] = nil
            order.removeAll { $0 == id }
            OnScreenPad.shared.clear(id)
        }
        publishPadPresence()
    }

    /// ml — one line per (re)registration, capped: a rotation or pointer-
    /// panel toggle re-registers every control at once, and an uncapped log
    /// would flood the device log exactly when it is most useful (right
    /// after launch, diagnosing whether a control's frame/window came up
    /// right the first time). The first 40 are the ones that matter for
    /// that; a session that is still re-registering after 40 has already
    /// told its story.
    private static var loggedRegistrations = 0
    private func logRegistration(_ r: ControlRegion) {
        guard Self.loggedRegistrations < 40 else { return }
        Self.loggedRegistrations += 1
        let f = r.frame
        let w = window?.bounds.size ?? .zero
        fputs(String(format: "[controls] region %@ frame=(%.0f,%.0f %.0f\u{d7}%.0f) window=(%.0f\u{d7}%.0f)\n",
                     r.id, f.origin.x, f.origin.y, f.width, f.height, w.width, w.height), stderr)
    }

    /// ml670: how many of the registered regions are virtual-controller
    /// controls. A handful of regions exist at any time, so recounting on every
    /// registration is cheaper than the bookkeeping that would avoid it.
    private func publishPadPresence() {
        OnScreenPad.shared.setPresent(regions.values.filter { $0.kind.isPadKind }.count)
    }

    /// Topmost-last: a region registered later wins an overlap.
    func region(at p: CGPoint) -> ControlRegion? {
        // Edit mode belongs to SwiftUI — dragging and pinching controls into
        // place is layout, not input, and must not press anything.
        guard !TouchControlsModel.shared.editing else { return nil }
        // The UIKit control layer sits above the SwiftUI HUD in this window.
        // Returning the window's normal hit test alone still selects controls
        // behind a modal sheet unless their own region lookup refuses it.
        guard !LibraryModel.shared.blocksGameplayTouch else { return nil }
        for id in order.reversed() {
            if let r = regions[id], r.hit(p) { return r }
        }
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return region(at: point) != nil ? self : nil
    }

    // MARK: touch tracking

    /// ml665 — an AssistiveTouch cursor hovering over a control must not press
    /// it. The synthesised click is a `.direct` touch with no contact patch (see
    /// HardwareInput.shouldIgnore), and while a real mouse is live it is always
    /// a duplicate of a GCMouse button that has already been reported. A touch
    /// dropped here is simply never tracked, so `move`/`finish` — both of which
    /// are no-ops for an untracked touch — need no matching guard.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        reconcile(event)
        for t in touches where !HardwareInput.shared.shouldIgnore(t, logging: true) {
            begin(t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if LibraryModel.shared.blocksGameplayTouch { dropAllTouches("frontend-modal"); return }
        reconcile(event)
        for t in touches { move(t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { finish(key: ObjectIdentifier(t), why: "ended") }
        reconcile(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A touch that began on a button and is still down when the app
        // resigns active arrives here, not in touchesEnded. Same release path:
        // the region is released and the touch forgotten, which is the whole of
        // what a cancel means to a control.
        for t in touches { finish(key: ObjectIdentifier(t), why: "cancelled") }
        reconcile(event)
    }

    // ========================================================================
    // ml666 — REBUILD FROM `UITouch` IDENTITY ON EVERY EVENT.
    //
    // ml662 assumed the four callbacks are a complete, balanced ledger: every
    // `began` is matched by an `ended` or a `cancelled` on the same view. UIKit
    // does not promise that. A view that is re-parented or whose window is
    // re-framed under a live finger, an event delivered while the app is being
    // suspended, a `UITouch` reclaimed for a new sequence — each drops the
    // closing callback, and a per-touch table keyed by address then holds a
    // PHANTOM: an entry for a finger that is not on the glass.
    //
    // A phantom is not a cosmetic leak. Its `InputGuard` owner is still in the
    // wants-union, so the key or mouse button it was holding is pinned DOWN for
    // the rest of the session — pressing that control again changes nothing
    // (the union already contains it) and releasing it changes nothing (the
    // phantom still wants it). That is precisely "the buttons stop working",
    // and for an aim-stick region the phantom also keeps its last deflection in
    // `AimStickDriver.vecs`, so the camera drifts and the stick reads dead.
    //
    // So the table is no longer trusted between events: every callback first
    // reconciles it against the only authority there is, the live `UITouch`
    // objects UIKit hands us. Anything tracked that is not among them — or that
    // UIKit has already deallocated, or that it now reports as ended/cancelled
    // — is released and forgotten before the new event is processed. No cap, no
    // per-region exclusivity, nothing that can leave a region unreachable: the
    // only way to hold a region is to have a live finger on it.
    // ========================================================================
    private func reconcile(_ event: UIEvent?) {
        guard !tracked.isEmpty else { return }
        // `allTouches` is every touch in the current multi-touch sequence, not
        // just the ones in this callback's set — including fingers resting on
        // other controls and on the game view in the other window.
        var live = Set<ObjectIdentifier>()
        for t in event?.allTouches ?? [] where t.phase != .ended && t.phase != .cancelled {
            live.insert(ObjectIdentifier(t))
        }
        // Array(): finish() mutates `tracked` from inside the loop.
        for (k, tk) in Array(tracked) {
            guard let t = tk.touch else {          // UIKit deallocated it
                finish(key: k, why: "stale-gone"); continue
            }
            if t.phase == .ended || t.phase == .cancelled {
                finish(key: k, why: "stale-phase"); continue
            }
            // `UITouch.view` is the view the touch was delivered to and does
            // not change for the life of that touch. So a live touch at our
            // address that UIKit says belongs to ANOTHER view is the recycling
            // case caught in flight: the object was handed to a new finger
            // somewhere else (the game view, most often) and our entry is a
            // phantom. Only trusted when UIKit actually names a view.
            if let v = t.view, v !== self {
                finish(key: k, why: "stale-view"); continue
            }
            // Absence from `allTouches` is the last resort, and deliberately
            // the weakest test: two consecutive events plus a grace period
            // before the finger is declared gone.
            guard event != nil else { continue }
            if live.contains(k) {
                if tk.misses != 0 { var u = tk; u.misses = 0; tracked[k] = u }
            } else if tk.misses >= 1, CACurrentMediaTime() - tk.began > 0.25 {
                finish(key: k, why: "stale-absent")
            } else {
                var u = tk; u.misses += 1; tracked[k] = u
            }
        }
    }

    /// The app went away, or the reconciler decided nothing can still be held.
    func dropAllTouches(_ why: String) {
        for k in Array(tracked.keys) { finish(key: k, why: why) }
        // ml668: a pad hold is a finger by every other rule in this file, so it
        // goes the same way a finger does when the app stops being able to
        // observe input at all.
        padReleaseAll(why)
        // ml670: and so does the virtual controller. `finish` above has already
        // cleared every TRACKED region; this catches anything a lost callback
        // left behind, which is the failure mode this whole valve exists for.
        OnScreenPad.shared.clearAll()
    }

    private func begin(_ t: UITouch) {
        // ml666: UIKit hands out recycled `UITouch` objects, so this address may
        // still carry a track whose closing callback never arrived. Releasing it
        // HERE is what stops the old owner's keys from being pinned down by a
        // finger that is no longer on the glass — the overwrite this replaces
        // left that owner in InputGuard's union forever.
        finish(key: ObjectIdentifier(t), why: "reused")
        let p = t.location(in: self)
        guard let r = region(at: p) else {
            // hitTest said yes and the region list changed before the touch was
            // delivered. Should be impossible in one runloop turn — which is
            // exactly why it gets a line of its own rather than a silent return.
            nMissed += 1
            fputs("[input] touch began on NO region at \(Int(p.x)),\(Int(p.y)) "
                  + "regions=\(order.count) (total missed=\(nMissed))\n", stderr)
            return
        }
        touchSeq += 1
        let tk = Track(region: r.id, owner: InputGuard.newOwner(), start: p,
                       seq: touchSeq, began: CACurrentMediaTime(), touch: t)
        tracked[ObjectIdentifier(t)] = tk
        nBegan += 1
        let face = ControlFaces.state(r.id)
        face.down = true

        switch r.kind {
        case .keys, .buttons:
            applyHold(r, owner: tk.owner)
            haptic()
        case .tapKey(let vk):
            winios_post_key(vk, 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { winios_post_key(vk, 0) }
            haptic()
        case .dirStick(let quad, _):
            openPad(r)
            steerDir(r, owner: tk.owner, dir: -1, quad: quad)
        case .aimStick:
            openPad(r)
            AimStickDriver.shared.begin(tk.owner)
            face.vec = .zero
            r.pad?.vec = .zero
            haptic()
        case .keyboardToggle:
            MetalBackedView.toggleKeyboard()
            haptic()
        case .inert:
            break
        // ml670 — the virtual controller. No InputGuard owner is taken: these
        // hold no keys and no mouse buttons, and `OnScreenPad` is keyed by
        // region, so `finish`'s unconditional `clear` is the whole release path.
        case .padButton(let b):
            OnScreenPad.shared.press(r.id, b)
            haptic()
        case .padDPad:
            OnScreenPad.shared.dpad(r.id, dir: -1)
            haptic()
        case .padStick(let right, _, _):
            face.vec = .zero
            OnScreenPad.shared.stick(r.id, right: right, vec: .zero)
            haptic()
        }

        if logs(tk.seq) {
            fputs("[input] touch id=\(tk.seq) began on \(r.id) (\(r.label)) "
                  + "kind=\(r.kind.name) active=\(tracked.count)\n", stderr)
        }
        startReporting()
    }

    private func move(_ t: UITouch) {
        let key = ObjectIdentifier(t)
        guard var tk = tracked[key], let r = regions[tk.region] else { return }
        let p = t.location(in: self)
        let d = CGSize(width: p.x - tk.start.x, height: p.y - tk.start.y)

        switch r.kind {
        case .dirStick(let quad, let dz):
            // A stick follows its OWN touch wherever it goes — leaving the
            // frame mid-drag is normal thumb travel, not a release.
            steerDir(r, owner: tk.owner, dir: snap(d, deadzone: dz), quad: quad)
        case .aimStick(let dz, let travel):
            let v = deflect(d, deadzone: dz, travel: travel)
            ControlFaces.state(r.id).vec = v
            r.pad?.vec = v
            AimStickDriver.shared.steer(tk.owner, v)
        case .keys, .buttons:
            let inside = r.hit(p, slack: r.slideOff)
            if !inside && !tk.lapsed {
                tk.lapsed = true
                tracked[key] = tk
                InputGuard.shared.release(tk.owner)
                ControlFaces.state(r.id).down = false
            } else if inside && tk.lapsed {
                tk.lapsed = false
                tracked[key] = tk
                applyHold(r, owner: tk.owner)
                ControlFaces.state(r.id).down = true
            }
        // ml670: a virtual button slides off and comes back exactly as a key
        // does — same slack, same lapsed flag, so a thumb rolling off the edge
        // releases the XInput bit instead of pinning it.
        case .padButton(let b):
            let inside = r.hit(p, slack: r.slideOff)
            if !inside && !tk.lapsed {
                tk.lapsed = true
                tracked[key] = tk
                OnScreenPad.shared.clear(r.id)
                ControlFaces.state(r.id).down = false
            } else if inside && tk.lapsed {
                tk.lapsed = false
                tracked[key] = tk
                OnScreenPad.shared.press(r.id, b)
                ControlFaces.state(r.id).down = true
            }
        case .padDPad(let dz):
            let dir = snap(d, deadzone: dz)
            let face = ControlFaces.state(r.id)
            if face.dir != dir {
                if face.dir == -1 && dir != -1 { haptic() }
                face.dir = dir
                OnScreenPad.shared.dpad(r.id, dir: dir)
            }
        case .padStick(let right, let dz, let travel):
            let v = deflect(d, deadzone: dz, travel: travel)
            ControlFaces.state(r.id).vec = v
            r.pad?.vec = v
            OnScreenPad.shared.stick(r.id, right: right, vec: v)
        case .tapKey, .keyboardToggle, .inert:
            break
        }
    }

    private func finish(key: ObjectIdentifier, why: String) {
        guard let tk = tracked.removeValue(forKey: key) else { return }
        if why == "ended" { nEnded += 1 } else { nCancelled += 1 }

        // ml666 — ONE LINE PER RECOVERED REGION.
        //
        // "ended" is the finger lifting; anything else is a release this layer
        // had to work out for itself, and each reason names a different way the
        // ledger was broken. A build that never prints these is a build where
        // the four callbacks really are balanced; a build that prints them says
        // which mechanism is dropping the close, and the region it would have
        // left dead is named right there.
        if why != "ended" {
            nRecovered += 1
            let ms = Int((CACurrentMediaTime() - tk.began) * 1000)
            fputs("[input] recover region=\(tk.region) "
                  + "(\(regions[tk.region]?.label ?? "gone")) reason=\(why) "
                  + "id=\(tk.seq) held=\(ms)ms active=\(tracked.count) "
                  + "(total recovered=\(nRecovered))\n", stderr)
        }

        // Release unconditionally and in both systems. Both calls are no-ops
        // for an owner that held nothing, so there is no case to get right.
        InputGuard.shared.release(tk.owner)
        AimStickDriver.shared.steer(tk.owner, .zero)
        AimStickDriver.shared.end(tk.owner)
        // ml670: and in the third. Also a no-op for a region that contributed
        // nothing, so there is still no case to get right.
        OnScreenPad.shared.clear(tk.region)

        let face = ControlFaces.state(tk.region)
        face.down = false
        face.dir = -1
        face.vec = nil
        if let r = regions[tk.region] { closePad(r) }

        if logs(tk.seq) {
            let ms = Int((CACurrentMediaTime() - tk.began) * 1000)
            fputs("[input] touch id=\(tk.seq) \(why) on \(tk.region) "
                  + "(\(regions[tk.region]?.label ?? "gone")) held=\(ms)ms "
                  + "active=\(tracked.count)\n", stderr)
        }
        if tracked.isEmpty { report(idle: true) }
    }

    // MARK: posting

    private func applyHold(_ r: ControlRegion, owner: Int) {
        switch r.kind {
        case .keys(let k):    InputGuard.shared.hold(owner, keys: k)
        case .buttons(let b): InputGuard.shared.hold(owner, buttons: b)
        default: break
        }
    }

    private func steerDir(_ r: ControlRegion, owner: Int, dir: Int, quad: [Int32]) {
        let face = ControlFaces.state(r.id)
        guard face.dir != dir else { return }
        // ml661's rule survives intact: state the SET, never the edges.
        InputGuard.shared.hold(owner, keys: Set(Self.stickKeys(dir, quad)))
        if face.dir == -1 && dir != -1 { haptic() }
        face.dir = dir
        r.pad?.dir = dir
    }

    private func openPad(_ r: ControlRegion) {
        guard let pad = r.pad else { return }
        pad.center = CGPoint(x: r.frame.midX, y: r.frame.midY)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { pad.held = true }
    }

    private func closePad(_ r: ControlRegion) {
        guard let pad = r.pad else { return }
        pad.dir = -1
        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
            pad.held = false
            pad.vec = nil
        }
    }

    // MARK: ml668 — a physical controller button pressing an on-screen control
    //
    // THE RULE THIS OBEYS. A pad button is a SECOND FINGER, not a second input
    // system. It takes an `InputGuard` owner exactly as a touch does, it holds
    // exactly the `ControlRegionKind` that touch would have held, and it
    // publishes into the same `ControlFaces` state — so the reconciler in
    // `InputGuard.tick`, the coalescing ring behind `winios_post_key` and every
    // diagnostic that counts owners see one more finger and nothing they have
    // to be taught about.
    //
    // THE OWNER KIND IS THE BUTTON: one owner per physical button, for the life
    // of the session. Per-button rather than per-control is what makes
    // rebinding safe — moving a binding from one control to another restates
    // that one owner's key set and disturbs nothing else — and it is what lets
    // `padReleaseAll` be a complete, idempotent valve.
    //
    // A pad hold deliberately does NOT go in `tracked`: that table is keyed by
    // `UITouch` identity and every sweep in it asks UIKit whether the touch is
    // still alive. A button has no UITouch to ask about, and its release comes
    // from the sampler (or from `padReleaseAll`), which cannot be lost the way
    // a cancelled gesture can.

    private struct PadHold {
        let region: String
        let owner: Int
        var dir: Int = -1
        var aiming = false
    }
    private var padHolds: [String: PadHold] = [:]
    private var padOwners: [String: Int] = [:]

    private func padOwner(_ button: String) -> Int {
        if let o = padOwners[button] { return o }
        let o = InputGuard.newOwner()
        padOwners[button] = o
        return o
    }

    /// Hold `rid` with `kind` on behalf of `button`. Idempotent: called every
    /// sample while the button is down, it costs one dictionary lookup after
    /// the first. `label` is for the log line only.
    func padPress(_ button: String, region rid: String,
                  kind: ControlRegionKind, label: String) {
        if let h = padHolds[button], h.region == rid, !h.aiming { return }
        padRelease(button)                       // rebound, or was aiming
        let owner = padOwner(button)
        padHolds[button] = PadHold(region: rid, owner: owner)
        ControlFaces.state(rid).down = true
        switch kind {
        case .keys(let k):    InputGuard.shared.hold(owner, keys: k)
        case .buttons(let b): InputGuard.shared.hold(owner, buttons: b)
        case .tapKey(let vk):
            // Momentary, exactly as the touch path spells it: a physical
            // button held down on a tap-key control still sends one pair.
            winios_post_key(vk, 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { winios_post_key(vk, 0) }
        case .keyboardToggle:
            MetalBackedView.toggleKeyboard()
        case .dirStick, .aimStick, .inert:
            // A stick control bound to a BUTTON holds nothing — the button has
            // no direction to steer with. It still takes the hold so the face
            // lights and the binding is visibly doing something.
            break
        case .padButton, .padDPad, .padStick:
            // ml670: a PHYSICAL button bound to a VIRTUAL controller button is
            // a remap of the pad onto itself, and the physical sample is
            // already in the merge — pressing it here would double-count and,
            // worse, fight the finger for a region-keyed contribution. The face
            // still lights, so the binding is visibly doing something.
            break
        }
        fputs("[input] pad \(button) down on \(rid) (\(label)) kind=\(kind.name)\n", stderr)
    }

    /// Release whatever `button` is holding. A no-op when it holds nothing, so
    /// the sampler can call it unconditionally on every up edge.
    func padRelease(_ button: String) {
        guard let h = padHolds.removeValue(forKey: button) else { return }
        InputGuard.shared.release(h.owner)
        AimStickDriver.shared.steer(h.owner, .zero)
        AimStickDriver.shared.end(h.owner)
        guard !h.region.isEmpty else { return }
        let face = ControlFaces.state(h.region)
        face.down = false
        face.dir = -1
        face.vec = nil
        if let r = regions[h.region] { closePad(r) }
    }

    /// An 8-way direction from a physical stick, into a dirstick control.
    /// `dir` is -1 for centred, else the same 0-7 the touch path uses.
    func padDir(_ button: String, region rid: String, quad: [Int32], dir: Int) {
        if padHolds[button]?.region != rid {
            padRelease(button)
            padHolds[button] = PadHold(region: rid, owner: padOwner(button))
            if let r = regions[rid] { openPad(r) }
        }
        guard padHolds[button]?.dir != dir else { return }
        padHolds[button]?.dir = dir
        // ml661's rule again: state the SET, never the edges.
        InputGuard.shared.hold(padOwner(button), keys: Set(Self.stickKeys(dir, quad)))
        let face = ControlFaces.state(rid)
        face.down = dir != -1
        face.dir = dir
        if let r = regions[rid] { r.pad?.dir = dir }
    }

    /// Velocity mouse-look from a physical stick. `rid` may be nil: a game in
    /// relative-mouse mode gets pad look whether or not the layout has an aim
    /// control to light up.
    func padAim(_ button: String, region rid: String?, vec: CGSize) {
        if vec == .zero { padRelease(button); return }
        if padHolds[button] == nil {
            padHolds[button] = PadHold(region: rid ?? "", owner: padOwner(button),
                                       dir: -1, aiming: true)
            AimStickDriver.shared.begin(padOwner(button))
        }
        AimStickDriver.shared.steer(padOwner(button), vec)
        if let rid {
            let face = ControlFaces.state(rid)
            face.down = true
            face.vec = vec
            if let r = regions[rid] { r.pad?.vec = vec }
        }
    }

    /// Every pad hold, gone. The controller disconnected, the app resigned
    /// active, or `InputGuard.releaseAll` decided nothing can still be held.
    func padReleaseAll(_ why: String) {
        guard !padHolds.isEmpty else { return }
        let n = padHolds.count
        for b in Array(padHolds.keys) { padRelease(b) }
        fputs("[input] pad releaseAll(\(why)) released \(n)\n", stderr)
    }

    private static func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize, deadzone: CGFloat) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    /// Analogue deflection, −1…1 per axis, re-scaled from the deadzone edge so
    /// the first countable movement is a crawl rather than a jump.
    private func deflect(_ t: CGSize, deadzone: CGFloat, travel: CGFloat) -> CGSize {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        guard d > deadzone, travel > deadzone else { return .zero }
        let m = min((d - deadzone) / (travel - deadzone), 1.0)
        return CGSize(width: t.width / d * m, height: t.height / d * m)
    }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    // MARK: diagnostics

    /// Every one of the first 50 touches, then one in a hundred. Gated on the
    /// touch's own sequence number so a began and its ended are always a pair —
    /// a lone "began" in the log then means exactly what it looks like.
    private func logs(_ seq: Int) -> Bool { seq <= 50 || seq % 100 == 0 }

    private func startReporting() {
        guard reportTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.report(idle: false) }
        RunLoop.main.add(t, forMode: .common)
        reportTimer = t
    }

    /// ml666 — THE SYMPTOM, NAMED, EVERY FIVE SECONDS.
    ///
    /// A dead control is always a region whose touch never ended. Five seconds
    /// is far longer than any press and longer than most holds that matter:
    /// a stick held that long is a thumb resting on it and says so, while a
    /// BUTTON reported here for minutes on end is the failure itself, named,
    /// with the reason its release never came still in the log above it.
    ///
    /// Silent when nothing qualifies, so it costs a running game nothing. It
    /// also re-reconciles with no event in hand (`reconcile(nil)` still reaps
    /// touches UIKit has deallocated or already ended), which is what un-sticks
    /// a region when no further touch ever arrives to do it.
    func startHealthMonitor() {
        guard healthTimer == nil else { return }
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.health() }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    private func health() {
        reconcile(nil)
        let now = CACurrentMediaTime()
        var stale: [String] = []
        for tk in tracked.values where now - tk.began > 5.0 {
            stale.append(String(format: "%@(%@,%ds%@)", tk.region,
                                regions[tk.region]?.kind.name ?? "gone",
                                Int(now - tk.began), tk.lapsed ? ",off" : ""))
        }
        guard !stale.isEmpty else { return }
        fputs("[input] health held>5s=[\(stale.sorted().joined(separator: " "))] "
              + "active=\(tracked.count) regions=\(order.count) "
              + "began=\(nBegan) ended=\(nEnded) cancelled=\(nCancelled) "
              + "recovered=\(nRecovered) missed=\(nMissed)\n", stderr)
    }

    /// One line a second while anything is held, plus one when the last finger
    /// lifts. Silent when nothing is being touched, so it cannot bury the rest
    /// of the log the way a free-running heartbeat would.
    private func report(idle: Bool) {
        var sticks: [String] = [], buttons: [String] = []
        for tk in tracked.values {
            guard let r = regions[tk.region] else { continue }
            let f = ControlFaces.state(r.id)
            switch r.kind {
            case .dirStick, .padDPad: sticks.append("\(r.id)=dir\(f.dir)")
            case .aimStick, .padStick:
                let v = f.vec ?? .zero
                sticks.append(String(format: "%@=(%.2f,%.2f)", r.id, v.width, v.height))
            default: buttons.append(r.id + (tk.lapsed ? "(off)" : ""))
            }
        }
        fputs("[input] controls: active_touches=\(tracked.count) "
              + "sticks=[\(sticks.sorted().joined(separator: " "))] "
              + "buttons=[\(buttons.sorted().joined(separator: " "))] "
              + "regions=\(order.count) began=\(nBegan) ended=\(nEnded) "
              + "cancelled=\(nCancelled) missed=\(nMissed)\(idle ? " idle" : "")\n", stderr)
        if idle { reportTimer?.invalidate(); reportTimer = nil }
    }
}

/// Register the frame this view occupies as a control region, and take the
/// view out of the input business entirely.
///
/// The SwiftUI side keeps what it is good at — layout, appearance, animation —
/// and publishes its `.global` frame, which for a UIHostingController's tree is
/// window coordinates, the space `ControlOverlayView` hit-tests in. Nothing
/// here attaches a gesture, so nothing here can be arbitrated, delayed or
/// cancelled.
///
/// A `ViewModifier` (not a plain function returning `some View`) purely so it
/// can hold `@State` — the per-instance ownership token `ControlOverlayView.
/// owners` needs. See that property's doc comment for why an outgoing
/// instance's `.onDisappear` must not be able to unregister an incoming
/// instance's registration when the two share an `id` across a rotation.
private struct ControlRegionModifier: ViewModifier {
    let id: String
    let label: String
    let kind: ControlRegionKind
    var circular: Bool = false
    var pad: JoystickPadState? = nil

    /// Minted once per view IDENTITY (an `@State` initial value persists
    /// across re-renders of the same instance and is fresh for every new
    /// one), never per region id — `id` is the shared logical-control name,
    /// this is "which physical SwiftUI view currently claims it."
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        ControlOverlayView.shared.register(
                            ControlRegion(id: id, label: label, frame: geo.frame(in: .global),
                                          kind: kind, circular: circular, pad: pad),
                            owner: owner)
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        ControlOverlayView.shared.reframe(id, f, owner: owner)
                    }
                    .onChange(of: kind) { _, k in
                        ControlOverlayView.shared.register(
                            ControlRegion(id: id, label: label, frame: geo.frame(in: .global),
                                          kind: k, circular: circular, pad: pad),
                            owner: owner)
                    }
                    .onDisappear { ControlOverlayView.shared.unregister(id, owner: owner) }
            }
        )
    }
}

extension View {
    func controlRegion(_ id: String, _ label: String, _ kind: ControlRegionKind,
                       circular: Bool = false,
                       pad: JoystickPadState? = nil) -> some View {
        modifier(ControlRegionModifier(id: id, label: label, kind: kind,
                                        circular: circular, pad: pad))
    }
}

/// ml — UNIFORM SQUARE FOOTPRINT for every control in the wrapping key/tool
/// grid (ContentView.controlRow's non-pointer-panel branch): the tap keys,
/// the modifiers, the keyboard toggle, the joystick, and the icon buttons
/// (pointer/display/fullscreen/diag[/lock]) all share this exact size and
/// corner radius, so nothing in the row reads as bigger or more important
/// than its neighbour. Device feedback: Ctrl/Shift were visibly wider AND
/// taller than Esc/⏎/␣ and the keyboard button before this.
///
/// 44 -> 36 (device feedback: the row wanted to take less vertical space) —
/// every icon/label size below is scaled off this same constant rather than
/// re-picked by eye, so a future resize only has to change this one number.
let keyRowButtonSize: CGFloat = 36
let keyRowCornerRadius: CGFloat = 7

/// Visual-only key for the portrait row. Draws, publishes its frame, and
/// nothing else — ControlOverlayView presses it.
struct ControlKeyView: View {
    let id: String
    let label: String
    let kind: ControlRegionKind
    // ml — was 15 at keyRowButtonSize==44; scaled with the same ratio to 36.
    var fontSize: CGFloat = 12
    var size: CGFloat = keyRowButtonSize
    /// The ⌨ button was styled off `Color.secondary`; the key caps off white.
    var secondaryTint = false
    @ObservedObject private var face: ControlFaceState

    init(id: String, label: String, kind: ControlRegionKind, fontSize: CGFloat = 12,
         size: CGFloat = keyRowButtonSize, secondaryTint: Bool = false) {
        self.id = id; self.label = label; self.kind = kind
        self.fontSize = fontSize; self.size = size
        self.secondaryTint = secondaryTint
        _face = ObservedObject(wrappedValue: ControlFaces.state(id))
    }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            // ml — EXACT, not minWidth/minHeight: a minimum lets a longer
            // label ("Ctrl", "Shift") grow the button past its neighbours,
            // which is exactly the "every button the same size" bug. The
            // label instead shrinks to fit the fixed square.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(secondaryTint
                        ? Color.secondary.opacity(face.down ? 0.45 : 0.25)
                        : Color.white.opacity(face.down ? 0.35 : 0.15))
            .cornerRadius(keyRowCornerRadius)
            .controlRegion(id, label, kind)
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
///
/// ml662: input lives in ControlOverlayView now. This view lays the stick out,
/// draws its idle ring, and publishes its frame — the expanded pad's held/dir
/// state comes straight from the touch layer via JoystickPadState.
struct JoystickKeyView: View {
    static let rid = "portrait.dpad"

    @State private var hosted = false       // overlay window up: it draws the face
    @ObservedObject private var face = ControlFaces.state(JoystickKeyView.rid)
    /// ml — observed here too (not just held by JoystickPadHost's own
    /// overlay) so THIS view can tell "the window-level face has a real,
    /// freshly-registered centre" from "it doesn't yet, or it's a stale
    /// leftover" — see the `.overlay` and `.onDisappear` below.
    @ObservedObject private var pad = JoystickPadState.shared

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    var body: some View {
        // The idle ring lives in the row (inset inside the button so it has
        // breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: keyRowButtonSize, height: keyRowButtonSize)
            .background(Color.white.opacity(face.down ? 0.30 : 0.15))
            .cornerRadius(keyRowCornerRadius)
            // ml — THE STALE-CENTRE FIX (device feedback: "portrait is fine
            // until you've visited landscape once, then the glyph is outside
            // its button and unusable, even back in portrait").
            //
            // ROOT CAUSE: `pad` (JoystickPadState.shared) is a process-lifetime
            // SINGLETON, but THIS view is not — portraitBody and wideNormalBody
            // are different SwiftUI identities (see the comment on ContentView.
            // body's if/else), so switching between them destroys one
            // JoystickKeyView and creates another. The window-level face reads
            // `pad.center`, which used to be left holding whatever the OUTGOING
            // instance last registered — the other layout's screen position —
            // until the incoming instance's own registration overwrote it. In
            // the gap between "old instance gone" and "new instance's
            // GeometryReader has actually measured its own frame", the window
            // overlay drew the ring at that stale point, which is why it could
            // land on the launch row or off in space. Local-fallback until we
            // KNOW the centre is fresh (below) plus zeroing it on teardown
            // (see `.onDisappear`) closes that gap from both ends: nothing
            // stale is ever drawn, from either the instance that's gone or the
            // one that hasn't registered yet.
            .overlay { if !hosted || pad.center == .zero { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { _ in
                    Color.clear.onAppear {
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            TouchControlsHost.attach()   // ml662: the touch layer
                            hosted = true
                        }
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: face.down)
            // ml662: the pad's centre is set from the registered frame, and the
            // region is torn down with the view — which covers the pointer panel
            // replacing this row and a rotation rebuilding the hierarchy, the two
            // cases that used to strand a held arrow.
            .controlRegion(Self.rid, "dpad",
                           .dirStick(quad: [vkUp, vkRight, vkDown, vkLeft],
                                     deadzone: deadzone),
                           pad: JoystickPadState.shared)
            // See the ROOT CAUSE note above: whenever THIS instance goes away
            // (rotation swapping portraitBody/wideNormalBody, the pointer
            // panel replacing the row, fullscreen), zero the shared pad state
            // outright rather than leaving it for the next instance to
            // overwrite eventually. `.controlRegion`'s own onDisappear already
            // unregisters the region (releasing any held touch/keys) — this
            // additionally guarantees nothing can be drawn at the OLD position
            // in the meantime.
            .onDisappear {
                pad.hidden = true
                pad.center = .zero
                pad.dir = -1
                pad.vec = nil
                hosted = false
            }
    }
}

// ml666 — THE AIM STICK IS GONE FROM THE HUD.
//
// It was the portrait key row's second stick (the "scope" glyph, its own
// JoystickPadState instance, the `.aimStick` region kind) and the user asked
// for it to be removed: mouse-look on the live view is the drag path, which
// needs no on-screen control at all, and the row is short of width.
//
// `AimStickDriver` itself STAYS — a physical gamepad's right stick drives it
// (HardwareInput), which is a different control surface with exactly the same
// velocity semantics — and so does the `.aimStick` region kind, because it is
// what that driver is reached through.

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    /// ml — Task 2: the third pointer mode, "Touch" — tap-to-click plus a
    /// tap-and-hold drag, positions mapped exactly like Absolute (see
    /// `MetalBackedView.gameRelative`/`touchPointerMode` for how this and
    /// `relative` combine: mutually exclusive by convention, `touchMode`
    /// checked first). A separate flag rather than widening `relative` into
    /// an enum: every existing `InputSettings.shared.relative` read stays
    /// correct unchanged, and `pointerModeToggle` (ContentView) is the one
    /// place that keeps the two in the "at most one true" relationship a
    /// three-way UI control implies.
    @Published var touchMode: Bool = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }
    /// ml663 — HARDWARE mouse gain, and a third slider rather than a reuse of
    /// `sensRel`, because it is calibrated against something different. sensRel
    /// converts THUMB TRAVEL (view points, and a thumb has ~40pt of it) into
    /// mouse counts, so its useful default is 2.0. A mouse already reports
    /// motion in mouse counts: the honest default is 1.0 — pass them through
    /// untouched and let the game's own sensitivity slider be the sensitivity
    /// slider, exactly as on a PC. Sharing one value would mean plugging in a
    /// mouse doubled its speed for no reason a user could see.
    @Published var sensMouse: Double = 1.0 { didSet { save() } }
    /// ml665 — drop AssistiveTouch's synthesised `.direct` touches while a real
    /// mouse is delivering GCMouse deltas. ON by default because on iPhone the
    /// synthesised touch is always a duplicate of a click GCMouse already
    /// reported, and letting it through is what made the pointer jump to the
    /// accessibility cursor on every click. The knob exists for the device we
    /// have not seen: if `[hwinput] touch classified …` ever calls a real finger
    /// synthesised, set `"ignoreTouchesWithMouse": false` in
    /// Documents/madeira-input.json and the old behaviour comes back exactly.
    @Published var ignoreTouchesWithMouse = true { didSet { save() } }
    /// ml672 — OFF by default. A physical pad's right stick can feed
    /// `AimStickDriver` (see HardwareInput's `applyPadBindings`) so games
    /// with no native controller support still get camera control from a
    /// controller. But a game that reads the pad itself through XInput or
    /// the DirectInput joystick already gets that stick natively; feeding
    /// it into the mouse ON TOP of that steers the camera twice and drags
    /// the game's own cursor around. Off until the user asks for it.
    @Published var padRightStickMouse = false { didSet { save() } }
    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }
    /// Fit/Fill/Stretch — how the guest surface maps into the live view.
    /// MetalBackedView doesn't observe this object, so the setter nudges the
    /// on-screen view directly (see MetalBackedView.refreshDisplayMode()); a
    /// plain `didSet { save() }` here would leave the old mode on screen
    /// until the next incidental layout pass.
    @Published var displayMode: DisplayMode = .aspect {
        didSet { save(); MetalBackedView.refreshDisplayMode(reason: "mode-toggle") }
    }
    /// Landscape HUD cluster (controller/pencil buttons, TouchControlsOverlay.
    /// topBar) drag position — fractional (0...1) of the screen, one slot per
    /// rotation because the notch/home-indicator sit on opposite sides, so a
    /// spot dragged clear of them in one is inside them in the other. nil
    /// means "no drag yet, use the default top-center placement."
    @Published var hudPosLandscapeLeft:  CGPoint? = nil { didSet { save() } }
    @Published var hudPosLandscapeRight: CGPoint? = nil { didSet { save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            touchMode = j["touchMode"] as? Bool ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            sensMouse = j["sensMouse"] as? Double ?? 1.0
            ignoreTouchesWithMouse = j["ignoreTouchesWithMouse"] as? Bool ?? true
            padRightStickMouse = j["padRightStickMouse"] as? Bool ?? false
            diagnostics = j["diagnostics"] as? Bool ?? false
            displayMode = (j["displayMode"] as? String).flatMap(DisplayMode.init(rawValue:)) ?? .aspect
            hudPosLandscapeLeft  = Self.point(from: j["hudPosLandscapeLeft"])
            hudPosLandscapeRight = Self.point(from: j["hudPosLandscapeRight"])
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private static func point(from v: Any?) -> CGPoint? {
        guard let d = v as? [String: Any],
              let nx = d["nx"] as? Double, let ny = d["ny"] as? Double else { return nil }
        return CGPoint(x: nx, y: ny)
    }

    private func save() {
        guard !loading else { return }
        var j: [String: Any] = ["relative": relative, "touchMode": touchMode,
                                "sensAbs": sensAbs, "sensRel": sensRel,
                                "sensMouse": sensMouse, "diagnostics": diagnostics,
                                "ignoreTouchesWithMouse": ignoreTouchesWithMouse,
                                "padRightStickMouse": padRightStickMouse,
                                "displayMode": displayMode.rawValue]
        if let p = hudPosLandscapeLeft  { j["hudPosLandscapeLeft"]  = ["nx": Double(p.x), "ny": Double(p.y)] }
        if let p = hudPosLandscapeRight { j["hudPosLandscapeRight"] = ["nx": Double(p.x), "ny": Double(p.y)] }
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MetalBackedView {
        return MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
}

/// A user-added Custom… launch button, persisted across app restarts —
/// see `ContentView.customLaunchButtonsKey`. `label` is the exe's file
/// name without extension (derived once, at Add Button time); `path` is
/// the full Windows path handed to MADEIRA_EXE verbatim, same as the
/// built-in `launchTargets` full-path entries.
struct CustomLaunchButton: Codable, Equatable {
    let label: String
    let path: String
}

struct ContentView: View {
    @ObservedObject private var library = LibraryModel.shared
    @StateObject private var logStore = LogStore.shared
    @State private var jitStatus: JITStatus = .unknown
    @State private var entitlements: EntitlementStatus?
    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var input = InputSettings.shared
    /// ml663: so the pointer-lock button and the mouse slider appear exactly
    /// when there is a mouse to aim them at, and vanish when it is unplugged.
    @ObservedObject private var hw = HardwareInput.shared
    @State private var pointerPanel = false
    @Namespace private var pointerNS
    /// Custom… launch button (below): the popup's visibility and the path it
    /// edits, prefilled from `customExePathKey` when the button is tapped.
    @State private var showCustomLaunchAlert = false
    @State private var customExePath: String =
        UserDefaults.standard.string(forKey: ContentView.customExePathKey) ?? ""
    /// User-added Custom… buttons (Add Button in the alert below), persisted
    /// as JSON under `customLaunchButtonsKey` and loaded once at view init.
    @State private var customLaunchButtons: [CustomLaunchButton] =
        ContentView.loadCustomLaunchButtons()
    /// Long-press ▸ Rename on a user-added button (below): which button is
    /// being renamed (by path — `CustomLaunchButton` has no stable id of its
    /// own) and the alert's own text field state.
    @State private var showRenameLaunchAlert = false
    @State private var renameLaunchButtonPath: String?
    @State private var renameLaunchButtonText: String = ""
    /// Fixed tint cycle for `customLaunchButtons` so neighbouring
    /// user-added buttons are visually distinct; wraps by index.
    private static let customButtonTints: [Color] = [
        .teal, .indigo, .brown, .cyan, .yellow,
    ]
    /// Whether the game surface is fullscreen — see FullscreenState's doc
    /// comment. The single source of truth `body`'s if/else and every
    /// control row's fullscreenToggle button read; deliberately NOT an
    /// `@Environment(\.verticalSizeClass)` or `UIDevice.current.orientation`
    /// check — both lie on iPad (regular/regular size classes in split view
    /// and Stage Manager; orientation can read faceUp/unknown, or simply not
    /// match the window's own shape in a multi-window scene).
    @ObservedObject private var fullscreenState = FullscreenState.shared
    /// ml: THE LAUNCH-STATE GUARD.
    ///
    /// runWineFullSequence() used to have no notion of "a session is already
    /// running" at all — only `jit_check_debugged()`, which stops protecting
    /// anything the moment early-detach runs (seconds in). A boot that never
    /// finishes (`wine_process_is_running()` stuck at 1 — the "detach-wait:
    /// presents=0 running=1 elapsed=Ns" line, logged forever) left every
    /// later tap free to kick off a SECOND full sequence on top of the first
    /// one's still-live JIT pool / wineserver / env vars, with nothing in the
    /// UI to say why the result looked like "nothing happened." This is that
    /// guard: set the instant a sequence starts, cleared the instant
    /// runWineFullSequence's background work actually finishes (normal exit,
    /// boot-failure timeout, or a pool-allocation failure) — see the three
    /// `isLaunching = false` sites inside that function.
    @State private var isLaunching = false

    /// ml — THE LOADING SPINNER.
    ///
    /// Shown centred over the live view from the moment a GAME launch button
    /// is tapped (a launchTargets entry, a user custom button, or the
    /// Custom… alert's own Launch — see beginLaunchSpinner's call sites)
    /// until the guest's first frame presents, the session ends, or 90s pass
    /// — whichever comes first. Deliberately NOT shown for "Wine Virtual
    /// Desktop" or "Enable JIT": neither call site calls beginLaunchSpinner.
    @State private var showLaunchSpinner = false
    /// `madeira_get_present_count()` at the moment the spinner started — the
    /// present counter is monotonic and process-lifetime, so "a frame has
    /// presented since launch" is `count > this`, never `count > 0` (a
    /// second launch in the same run starts well above zero already).
    @State private var launchSpinnerBaseline: UInt64 = 0
    @State private var launchSpinnerDeadline = Date.distantPast

    private func beginLaunchSpinner() {
        launchSpinnerBaseline = madeira_get_present_count()
        launchSpinnerDeadline = Date().addingTimeInterval(90)
        withAnimation(.easeInOut(duration: 0.2)) { showLaunchSpinner = true }
    }

    /// Polled every 0.2s (see `launchSpinnerOverlay` below) rather than
    /// event-driven: the three exits (first present, process exit, timeout)
    /// have no common notification to hang a callback off, and a present
    /// counter/isLaunching flag are cheap enough to sample on a timer.
    private func tickLaunchSpinner() {
        guard showLaunchSpinner else { return }
        let presented = madeira_get_present_count() > launchSpinnerBaseline
        let ended = !isLaunching
        let timedOut = Date() >= launchSpinnerDeadline
        if presented || ended || timedOut {
            withAnimation(.easeInOut(duration: 0.2)) { showLaunchSpinner = false }
        }
    }

    /// Centred over the live view, hit-testing disabled so it can never
    /// intercept a touch meant for the game underneath (or, at this size,
    /// for the sibling chrome around it in wideNormalBody).
    @ViewBuilder private var launchSpinnerOverlay: some View {
        if showLaunchSpinner {
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
                Text("Starting…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    /// Shipped launch targets, EITHER BITNESS. Was `thirtyTwoBitTests` /
    /// "32-bit test programs" (WOW64_DESIGN.md stage E), but the table never
    /// actually selected a bitness: the ForEach below hands `exe` to
    /// MADEIRA_EXE verbatim and WineProcessBridge.m probes the PE machine of a
    /// full path, routing 32- or 64-bit accordingly. So a 64-bit entry belongs
    /// here just as much as a 32-bit one, and the old name only misled.
    ///
    /// Trimmed to the shipped/user-facing set (2026-09-15) — the rest of the
    /// diagnostic exes (unix-call bench, fastsync/FS/readvm/spawn/dispmode/ctx
    /// tests, …) stay in the bundle and keep working through this exact
    /// mechanism; they just no longer get a button. Add a row back to wire one
    /// up again — no other code needed. Entries are keyed by `exe` in the
    /// ForEach, so each path must be unique.
    private let launchTargets: [(label: String, exe: String, tint: Color)] = [
        ("INSIDE", #"C:\INSIDE\INSIDE.exe"#, .orange),
        ("D3D9 cube", "d3d9-cube-x86.exe", .purple),
        // Full Win32 path passed verbatim to MADEIRA_EXE — WineProcessBridge
        // detects the backslash and launches it as-is (no syswow64 prefix).
        (#"Mirror's Edge"#, #"C:\Mirrors-Edge\Mirror's Edge\Binaries\MirrorsEdge.exe"#, .pink),
    ]

    enum JITStatus {
        case unknown
        case testing
        case available
        case mappingOnly
        case unavailable
    }

    var body: some View {
        /* ml658: was NavigationView, which is deprecated and — the reason this
         * matters — defaults to a SPLIT VIEW on iPad. TARGETED_DEVICE_FAMILY is
         * "1,2", so iPad is a shipping target, and the whole UI was being forced
         * into a sidebar/detail arrangement it was never laid out for.
         * NavigationStack is single-column on every device. Safe here: there are
         * no NavigationLinks anywhere in the app, so nothing depended on the
         * two-column selection behaviour. */
        NavigationStack {
            // ml: THE BODY SWITCH, rewritten so fullscreen is a MODE, never a
            // side effect of rotation.
            //
            // Was `vSizeClass == .compact ? landscapeBody : portraitBody` —
            // i.e. rotating to landscape silently dropped into a fullscreen
            // body with no way back and (on iPad, where vSizeClass is
            // .regular in EVERY orientation because iPad never compacts its
            // vertical size class the way iPhone does) never triggered at
            // all, leaving the tiny portrait layout on screen sideways with
            // dead buttons. Three states now: fullscreen (explicit button
            // only, any orientation), wide normal (rotated to landscape but
            // fullscreen was never pressed — same tools as portrait, laid
            // out sideways), tall normal (today's portrait). The wide/tall
            // split reads `geo`'s own measured size, not a size class or
            // `UIDevice.current.orientation` — both are unreliable on iPad
            // (split view / Stage Manager windows, `.faceUp`/`.unknown` at
            // launch) where this geometry is the only fact that is actually
            // true.
            GeometryReader { geo in
                Group {
                    if fullscreenState.active {
                        fullscreenBody
                    } else if library.enabled {
                        LibraryView(play: launchLibraryEntry, enableJIT: enableJITViaStikDebug)
                    } else if geo.size.width > geo.size.height {
                        wideNormalBody
                    } else {
                        portraitBody
                    }
                }
                // ml — belt-and-suspenders for the cold-landscape-launch fix in
                // `controlOverlayWindowBounds`: this `geo` is the exact source
                // of truth this same reader uses to pick wideNormalBody over
                // portraitBody, so re-attaching whenever IT changes guarantees
                // the overlay window gets re-measured at least once against
                // whatever geometry the chosen body is actually laid out for,
                // with no dependence on a rotation notification ever firing.
                .onChange(of: geo.size) { _, _ in
                    TouchControlsHost.attach()
                }
            }
            // Rotation destroys/recreates the UIViewRepresentable across
            // this if/else (multiple SwiftUI identities) — HARMLESS since
            // 2026-07-05: MetalHostView is a process-lifetime singleton;
            // a fresh placeholder only re-parents the same CAMetalLayer.
            .navigationTitle("Madeira")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(library.enabled ? .visible : .automatic, for: .navigationBar)
            .navigationBarHidden(fullscreenState.active)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if !isLaunching {
                    library.refreshFlag()
                    MetalHostView.shared.isHidden = library.enabled && library.current == nil
                }
            }
            .onAppear {
                jit_install_trap_handler()
                // ml1330: StikDebug is closed by iOS about a minute after it
                // attaches; take the process-lifetime JIT pool while it is here.
                StikJITHelper.prepareEarlyPool(trigger: "start")
                entitlements = EntitlementStatus.check()
                logEntitlementStatus()
                // WOW64_DESIGN.md §9.2 step 0: measure the free VA map before
                // Wine/JIT touches it. Read-only, no behaviour change.
                mad_va_probe(entitlements?.extendedVA ?? false)
                // ml663: GameController's connect notifications only fire for
                // devices that arrive AFTER an observer exists, so this has to
                // run before the user can plug anything in. Idempotent.
                HardwareInput.shared.start()
                DeviceLoadDiagnostics.start()
            }
        }
    }

    /// Portrait (tall normal view): classic tooling layout — header, badges,
    /// 240pt game strip, key row, action buttons, log console.
    private var portraitBody: some View {
        VStack(spacing: 0) {
            // Readouts sit ABOVE the game strip, closest to the surface they
            // describe: entitlement indicators, then the present/FPS readout,
            // then the surface itself. (Only the KEY row stays below — it is
            // input, not instrumentation.)
            //
            // NOTE: the surface is a raw window-level view positioned over the
            // placeholder (MetalHostView.shared), so SwiftUI content laid "on
            // top" of the strip is covered — these rows must be siblings above
            // it, never overlays on it.
            if let ents = entitlements {
                entitlementBadges(ents)
            }
            HStack(spacing: 6) {
                FPSOverlay()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            MadeiraMetalView()
                .frame(height: 240)
                .background(Color.black)
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()   // re-frame to the new bounds
                }
                // Device feedback (2026-09-15): rotating away used to leave a
                // tiny, unpressable ghost of this row's arrow pad on screen —
                // JoystickKeyView (below) only exists in THIS body, and
                // ControlOverlayView.unregister never resets
                // JoystickPadState.center, so the window-level overlay
                // (JoystickPadHost, always attached, never torn down) kept
                // drawing the idle ring at its last position here, now
                // misplaced elsewhere. Re-entering this body is what un-hides
                // it (respecting whatever the pointer-panel toggle already
                // wants) right here.
                .onAppear { JoystickPadState.shared.hidden = pointerPanel }
                .overlay { launchSpinnerOverlay }
                .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                    tickLaunchSpinner()
                }
            controlRow
            // ml663: the hardware mouse's own gain. Its own row rather than a
            // fourth control squeezed into controlRow, and only while a mouse
            // is attached — a slider that cannot affect anything is noise.
            if pointerPanel && hw.mouseConnected {
                mouseGainRow
            }
            Divider()
            actionButtons
            Divider()
            logConsole
        }
    }

    /// Wide normal view: rotated to landscape shape WITHOUT pressing the
    /// fullscreen button. Exactly the same tools as portraitBody — nothing is
    /// removed or hidden, see FullscreenState's doc comment — just arranged
    /// for the width: live view on the left, the rest in a scrollable column
    /// on the right, so nothing runs off the bottom of a short landscape
    /// screen (iPhone landscape, a narrow iPad split).
    ///
    /// ml — THE TWO-COLUMN REBUILD.
    ///
    /// This used to size the left column with `.frame(maxWidth: .infinity,
    /// maxHeight: .infinity)` and trust HStack to give it "whatever the fixed
    /// 360pt right column left over." That is ordinary, normally-reliable
    /// SwiftUI sizing — and it is NOT what the raw live-view surface keys
    /// off. MetalHostView is added directly to the UIWindow, ON TOP of the
    /// entire SwiftUI tree (see the file-top comment), and it is sized from
    /// THIS placeholder's own UIKit `bounds` (MetalBackedView.gameRect(),
    /// applyDisplayModeAndLog) — a value SwiftUI only ever produces from a
    /// flexible-frame negotiation ONE LAYOUT PASS after the fact, is stale
    /// mid-rotation (see scheduleSettleReapply's doc comment), and is API
    /// nothing here can inspect or assert on. Because the presented layer is
    /// window-level, ANY gap between what SwiftUI intended and what UIKit's
    /// bounds actually read at apply time draws OVER the launch row and log
    /// console instead of being clipped by them — exactly the reported "live
    /// view extends under the column" bug, plus a squeezed column on iPad.
    ///
    /// The fix: stop asking HStack to infer the split and hand both columns
    /// an EXPLICIT size computed once from `geo`, every render. The left
    /// column's frame is no longer a negotiated remainder; it is a number
    /// this code owns, so MadeiraMetalView (and therefore MetalBackedView's
    /// `bounds`, and therefore MetalHostView's frame AND mapTouch's rect —
    /// display and touch mapping read the identical `bounds`) can never
    /// exceed it. `.clipped()` on both columns is defense in depth for the
    /// SwiftUI-hosted content (the log List, buttons); it cannot itself
    /// constrain the window-level surface, which is why the explicit size is
    /// the load-bearing part of this fix, not the clip.
    private var wideNormalBody: some View {
        GeometryReader { geo in
            // Right column: clamp(360...460) or ~34% of the width, per spec —
            // wide enough for the log/launch text on an iPad, never so wide
            // it eats the live view on a narrow iPhone landscape screen.
            let rightWidth = min(max(geo.size.width * 0.34, 360), 460)
            let dividerWidth: CGFloat = 1
            let leftWidth = max(geo.size.width - rightWidth - dividerWidth, 0)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let ents = entitlements {
                        entitlementBadges(ents)
                    }
                    HStack(spacing: 6) {
                        FPSOverlay()
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    MadeiraMetalView()
                        // WIDTH explicit — see the type comment above, this
                        // number is what MetalBackedView.bounds' width becomes,
                        // and the cross-column HStack negotiation is exactly
                        // the axis that went wrong. HEIGHT stays flexible
                        // (`maxHeight: .infinity`): that negotiation is
                        // entirely WITHIN this one VStack, against the header/
                        // FPS row's own intrinsic height, which was never the
                        // suspect axis and needs no hardcoded guess.
                        .frame(width: leftWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color.black)
                        .clipped()
                        .onAppear {
                            TouchControlsHost.attach()
                            JoystickPadState.shared.hidden = pointerPanel
                        }
                        .onReceive(NotificationCenter.default.publisher(
                            for: UIDevice.orientationDidChangeNotification)) { _ in
                            TouchControlsHost.attach()
                        }
                        .overlay { launchSpinnerOverlay }
                        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                            tickLaunchSpinner()
                        }
                }
                .frame(width: leftWidth, height: geo.size.height)
                .clipped()
                Divider()
                // ml — WAS an outer `ScrollView` around this whole VStack,
                // with `logConsole.frame(minHeight: 280)` — a List has no
                // natural intrinsic height inside an unconstrained
                // ScrollView, so a hardcoded floor stood in for one. That is
                // exactly the reported "the log stops about half-way down an
                // iPad column" bug: the VStack sized itself to CONTENT height
                // (header + buttons + 280pt), and the surrounding ScrollView
                // left the rest of a tall column simply blank rather than
                // stretching anything into it.
                //
                // Fixed instead: no outer scroll container at all. controlRow
                // wraps to as many lines as it needs (a LazyVGrid, no scroll
                // gesture of its own — see controlRow's doc comment) and
                // actionButtons keeps its OWN horizontal ScrollView for
                // overflow, so they only ever need their natural height here,
                // and logConsole (a List, which already scrolls its own rows)
                // gets `maxHeight: .infinity` to claim everything left in the
                // column — on an iPad's tall column that reaches the bottom;
                // on a short landscape phone it shrinks gracefully to
                // whatever is left rather than being clipped by a floor
                // taller than the space actually available.
                VStack(alignment: .leading, spacing: 0) {
                    controlRow
                    if pointerPanel && hw.mouseConnected {
                        mouseGainRow
                    }
                    Divider()
                    actionButtons
                    Divider()
                    logConsole
                        .frame(maxHeight: .infinity)
                }
                .frame(width: rightWidth, height: geo.size.height)
                // Opaque, not just clipped: MetalHostView draws ABOVE this
                // entire SwiftUI tree (window-level, see the type comment),
                // so if display-mode math or a mid-rotation stale `bounds`
                // ever hands it a frame wider than `leftWidth` again, this
                // column stays legible instead of showing the live view
                // bleeding through translucent List/Button backgrounds.
                .background(Color.black)
                .clipped()
            }
        }
    }

    /// The FPS/display/keys/pointer row shared by every NORMAL-view layout
    /// (portraitBody, wideNormalBody) — extracted so wide landscape gets
    /// exactly the same tools as portrait, just arranged differently around
    /// the game surface; no launch/control affordance goes missing just
    /// because the phone is sideways.
    private var controlRow: some View {
        Group {
            if pointerPanel {
                // The cursor button has slid to the leftmost slot and become
                // the close control; matchedGeometryEffect animates the slide.
                //
                // ml: displayModeToggle/fullscreenToggle used to live in THIS
                // branch too — that is the "display-fit mode control shows up
                // inside the mouse settings popup" bug. This row IS the mouse
                // settings popup (absolute/relative + sensitivity, toggled by
                // pointerToggleButton), and neither button belongs here: both
                // are general-purpose view controls, not mouse settings, and
                // the main toolbar (the `else` branch below) is their only
                // home. Closing the popup (pointerToggleButton, now showing
                // "xmark") is what gets you back to them. Not wrapped in the
                // horizontal ScrollView below — pointerSensSlider wants to
                // FILL the row's width, which a ScrollView would instead
                // propose as unbounded and collapse to nothing.
                HStack(spacing: 6) {
                    pointerToggleButton
                    pointerModeToggle
                    // ml — Task 2: Touch mode maps positions 1:1 through the
                    // same game-rect mapping as Absolute (MetalBackedView.
                    // mapPoint) — no sensitivity scaling applies, so there is
                    // nothing for this slider to edit while it is selected.
                    if !input.touchMode {
                        pointerSensSlider
                    } else {
                        Text("Tap to click, hold to drag, two/three fingers "
                             + "for right/middle click.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                // ml662: every one of these is now a REGION owned by
                // ControlOverlayView, not a SwiftUI gesture. A Button (which
                // ⏎/␣/Esc/⌨ used to be) needs its tap recogniser to win
                // arbitration against everything else on screen, and that is
                // precisely the fight a second finger made it lose.
                //
                // ml — THE SCROLL-VS-PRESS FIX, TAKE TWO: no more ScrollView.
                //
                // This used to be a fixed-outside-the-ScrollView joystick slot
                // plus a horizontal `ScrollView` for everything else — the
                // joystick was pulled out because a control that owns a
                // ControlOverlayView region is SUPPOSED to have absolute
                // priority over any SwiftUI gesture underneath it (touch-down
                // included, see ControlsWindow.hitTest), but the ScrollView's
                // own pan recognizer kept winning that race whenever this
                // control's registered region frame was even briefly stale.
                // That fix only ever protected the joystick; the key caps were
                // still inside the ScrollView and a drag starting on ANY of
                // them could still be stolen by the pan gesture instead of
                // registering as a press-and-hold, and a cold launch straight
                // into landscape (see `controlOverlayWindowBounds`) could
                // leave the touch layer entirely un-registered, at which point
                // EVERYTHING in this row — joystick included — was just
                // scrollable SwiftUI content with nothing pressing anything.
                //
                // A WRAPPING grid needs no scroll gesture at all, which
                // removes the competing recognizer outright instead of
                // special-casing one control against it: every control is
                // always fully visible, wrapping to a second line if the
                // column is too narrow for one, and the joystick is an
                // ordinary cell like everything else because there is no
                // longer a gesture for it to be extracted from.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: keyRowButtonSize,
                                                        maximum: keyRowButtonSize),
                                              spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    fullscreenToggle
                    JoystickKeyView()
                    Group {
                        ControlKeyView(id: "portrait.enter", label: "⏎", kind: .tapKey(0x0D))
                        ControlKeyView(id: "portrait.tab",   label: "Tab", kind: .tapKey(0x09))
                        ControlKeyView(id: "portrait.space", label: "␣", kind: .tapKey(0x20))
                        ControlKeyView(id: "portrait.esc",   label: "Esc", kind: .tapKey(0x1B))
                        // ml: modifiers, not taps — held for exactly as long as
                        // the finger is down (.keys, the same region kind
                        // HoldKeyView uses for the arrow keys), so they combine
                        // with any other on-screen key AND with the software
                        // keyboard: both post through the same winios_post_key
                        // ring / driver-side held-key state (InputGuard unions
                        // every region's contribution; insertText's synthesized
                        // presses land on top of whatever is already held).
                        ControlKeyView(id: "portrait.ctrl",  label: "Ctrl", kind: .keys([0x11]))
                        ControlKeyView(id: "portrait.shift", label: "Shift", kind: .keys([0x10]))
                        ControlKeyView(id: "portrait.kbd",   label: "⌨", kind: .keyboardToggle,
                                       fontSize: 20, secondaryTint: true)
                    }
                    .transition(.opacity)
                    pointerToggleButton
                    displayModeToggle
                    diagToggleButton
                    // ml665: no lock button where lock cannot happen (iPhone).
                    if hw.mouseConnected && HardwareInput.pointerLockAvailable {
                        pointerLockButton
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        // The expanded pad overflows this row; without a raised zIndex the
        // later siblings (action buttons, log) would draw over it.
        .zIndex(10)
    }

    /// ml663: the hardware mouse's own gain slider + the iPhone AssistiveTouch
    /// hint. Its own row rather than a fourth control squeezed into
    /// controlRow, and only while a mouse is attached — a slider that cannot
    /// affect anything is noise. Shared by portraitBody/wideNormalBody, same
    /// reasoning as controlRow above.
    private var mouseGainRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Slider(value: $input.sensMouse, in: 0.10...8.0)
                Text(String(format: "%.2f", input.sensMouse))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            // ml665: two facts the user cannot discover from inside the
            // app, and both change how this slider should be set.
            // AssistiveTouch applies its OWN tracking-speed scale before
            // we ever see a delta (which is why they arrive fractional),
            // so a mid Tracking Speed there plus this slider is one gain
            // stage the user can reason about instead of two multiplying
            // each other. And the requirement itself is not ours to
            // remove: iPhone has no other pointer-device path.
            if UIDevice.current.userInterfaceIdiom == .phone {
                Text("iPhone: AssistiveTouch must be on (Settings ▸ "
                     + "Accessibility ▸ Touch ▸ AssistiveTouch ▸ Devices). "
                     + "Set its Tracking Speed to the middle and use this "
                     + "slider for in-game sensitivity.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    /// Fullscreen: game mode, entered only via fullscreenToggle (or restored
    /// by rotating while already in it — see FullscreenState). Full-bounds
    /// surface, any orientation; ALL controls live in the movable HUD cluster
    /// (TouchControlsOverlay, a window-level overlay — the window-hosted
    /// surface would cover anything drawn "over" it in this SwiftUI tree, see
    /// the comment on MadeiraMetalView in portraitBody). No header/log/nav
    /// chrome, no FPS pill, no display-mode button — those stay in the
    /// normal view.
    private var fullscreenBody: some View {
        GeometryReader { geo in
            // ml: this used to be landscapeBody, keyed on the device having
            // rotated rather than on fullscreen having been requested, and
            // therefore unreachable in a PORTRAIT fullscreen and un-exitable
            // on iPad where the triggering size-class check never fired at
            // all. Fit/Aspect/Fit-height letterbox inside this box with a
            // UNIFORM scale, Fill covers it, Stretch fills it exactly — same
            // GameSurfaceLayout/DisplayMode math as everywhere else, just
            // against the FULL bounds instead of a clamped one (see
            // MetalBackedView.effectiveDisplayMode).
            MadeiraMetalView()
                .frame(width: geo.size.width, height: geo.size.height)
                // ml662: the controls window hosts the UIKit touch layer, so
                // it has to exist here whether or not the app was ever in the
                // normal view this session.
                .onAppear { TouchControlsHost.attach() }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification)) { _ in
                    TouchControlsHost.attach()
                }
                // Device feedback (2026-09-15): see the matching onAppear in
                // portraitBody — this is the fullscreen half of hiding the
                // normal view's stale window-level joystick-pad ghost.
                // `center` is left stale (nothing resets it on unregister) so
                // it is zeroed here too, belt-and-suspenders against the
                // opacity check in JoystickPadFace ever seeing a leftover
                // nonzero value while hidden briefly flips during a rotation.
                .onAppear {
                    JoystickPadState.shared.hidden = true
                    JoystickPadState.shared.center = .zero
                }
                .background(Color.black)
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    /// Hold-to-press key: VK down on touch, VK up on release — for keys
    /// games treat as held (arrows). Same winios queue as keyButton.
    private func holdKeyButton(_ label: String, vk: Int32, big: Bool = false) -> some View {
        HoldKeyView(label: label, vk: vk, big: big)
    }

    /// Small on-screen key: posts VK down, then up 60ms later, through the
    /// winios input queue (same path as touch→mouse).
    // ml641 pointer panel ------------------------------------------------
    private var pointerToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { pointerPanel.toggle() }
            // The window-level pads fade themselves; see JoystickPadState.hidden.
            JoystickPadState.shared.hidden = pointerPanel
            // ml666: the aim stick is gone; only the directional pad fades.
        } label: {
            Image(systemName: pointerPanel ? "xmark" : "cursorarrow")
                .font(.system(size: 15, weight: .medium))
                .frame(width: keyRowButtonSize, height: keyRowButtonSize)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(keyRowCornerRadius)
        }
        .matchedGeometryEffect(id: "pointerBtn", in: pointerNS)
    }

    /// ml649: heavy diagnostics on/off, live. Stroke icon, dimmed when quiet —
    /// same visual language as the controls-visibility button.
    private var diagToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            input.diagnostics.toggle()
        } label: {
            Image(systemName: "ladybug")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(input.diagnostics ? 1.0 : 0.35))
                .frame(width: keyRowButtonSize, height: keyRowButtonSize)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(keyRowCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// ml663 — THE WAY BACK OUT.
    ///
    /// Pointer lock hides and pins the iOS pointer, which is exactly right while
    /// the game has the mouse and exactly wrong when the user wants to press
    /// something in the app. There must always be two ways out of it and neither
    /// may need the pointer: this button (touch works regardless of lock) and
    /// the Ctrl+Alt+P chord on the keyboard itself. The landscape overlay's own
    /// copy sits in its top bar for the same reason.
    ///
    /// ml664: it also NAMES THE PATH. Lock means something different on each —
    /// on `gcmouse` it is containment the user wants, on `uikit` it is the thing
    /// that would switch the mouse off — so the button says which one it is
    /// rather than leaving the user to infer it from whether aiming works.
    private var pointerLockButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            HardwareInput.shared.togglePointerLock()
        } label: {
            // ml — vertical, not horizontal: the icon+"HID"/"UI" tag used to
            // sit side by side in a wide (minWidth 52) rectangle, which is
            // exactly the non-square shape the rest of the row no longer
            // has. Stacked, both lines fit the same keyRowButtonSize square
            // as every other control here.
            VStack(spacing: 1) {
                Image(systemName: hw.pointerLocked ? "cursorarrow.slash" : "cursorarrow.motionlines")
                    .font(.system(size: 13, weight: .regular))
                Text(hw.mousePath == .gcmouse ? "HID"
                     : hw.mousePath == .uikit ? "UI" : "—")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white.opacity(hw.pointerLocked ? 1.0 : 0.35))
            .frame(width: keyRowButtonSize, height: keyRowButtonSize)
            .background(Color.secondary.opacity(0.25))
            .cornerRadius(keyRowCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// Cycles Fit -> Fill -> Stretch -> Fit. Sits next to pointerToggleButton
    /// in every normal-view control row (controlRow, shared by portraitBody/
    /// wideNormalBody) — see GameSurfaceLayout/DisplayMode near the top of
    /// this file for what each mode does to the presented layer.
    private var displayModeToggle: some View {
        Button {
            input.displayMode = input.displayMode.next
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Device feedback (2026-09-15): this button (and the FPS-cap pill
            // beside it) went dead-silent when taps were being swallowed
            // upstream — nothing here ever logged, so there was no way to
            // tell "action ran" from "tap never arrived." Every tap now says so.
            fputs("[hud] tap display-mode -> \(input.displayMode.label)\n", stderr)
        } label: {
            Image(systemName: input.displayMode.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: keyRowButtonSize, height: keyRowButtonSize)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(keyRowCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(input.displayMode.label)
    }

    /// Enters fullscreen — the ONLY way in now (see FullscreenState's doc
    /// comment: rotation alone never does this any more). Sits right next to
    /// displayModeToggle in every normal-view control row, and is itself
    /// absent from the fullscreen body — the HUD cluster's own exit button
    /// (TouchControlsOverlay.topBar) is the way back out, draggable the same
    /// way the rest of that cluster is.
    private var fullscreenToggle: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            fputs("[hud] tap fullscreen -> enter\n", stderr)
            fullscreenState.active = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .medium))
                .frame(width: keyRowButtonSize, height: keyRowButtonSize)
                .background(Color.secondary.opacity(0.25))
                .cornerRadius(keyRowCornerRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enter fullscreen")
    }

    /// Cycles Absolute -> Relative -> Touch -> Absolute. `relative` and
    /// `touchMode` are kept mutually exclusive here — this button is the one
    /// place that has to enforce that, since a three-way UI control implies
    /// "at most one true" but the two flags are independent `@Published`
    /// vars (see `InputSettings.touchMode`'s doc comment for why it is a
    /// separate flag rather than widening `relative` into an enum).
    private var pointerModeToggle: some View {
        Button {
            if input.touchMode {
                input.touchMode = false            // Touch -> Absolute
            } else if input.relative {
                input.relative = false              // Relative -> Touch
                input.touchMode = true
            } else {
                input.relative = true               // Absolute -> Relative
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(input.touchMode ? "Touch" : (input.relative ? "Relative" : "Absolute"))
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 82, minHeight: 32)
                .background((input.touchMode || input.relative
                             ? Color.accentColor : Color.secondary).opacity(0.28))
                .cornerRadius(6)
        }
        .transition(.opacity)
    }

    /// One slider bound to whichever mode is live, so the two values are edited
    /// independently and both persist.
    private var pointerSensSlider: some View {
        HStack(spacing: 8) {
            Slider(value: input.relative ? $input.sensRel : $input.sensAbs, in: 0.10...8.0)
            Text(String(format: "%.2f", input.relative ? input.sensRel : input.sensAbs))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // ml662: keyButton() is gone — a momentary key is `.tapKey` in the touch
    // layer now (ControlKeyView), so it cannot be lost to gesture arbitration.

    private func entitlementBadges(_ ents: EntitlementStatus) -> some View {
        HStack(spacing: 8) {
            // Live debugger/JIT state, not the (macOS-only, never granted on
            // iOS) allow-jit entitlement the old badge checked.
            entitlementBadge("JIT", granted: debuggerAttached)
            entitlementBadge("Memory+", granted: ents.increasedMemory)
            entitlementBadge("64-bit VA", granted: ents.extendedVA)
            Spacer()
            // Device model rides in this row (the old standalone statusHeader
            // row above it spent ~50pt of vertical space on nothing else).
            VStack(alignment: .trailing, spacing: 0) {
                Text("Device")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(deviceInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            debuggerAttached = isDebuggerAttached()
        }
    }

    private func entitlementBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .foregroundColor(granted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(granted ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
        )
    }

    private func logEntitlementStatus() {
        guard let ents = entitlements else { return }
        logStore.log("Checking entitlements...")
        logStore.log("  allow-jit: \(ents.jitAllowed)", level: ents.jitAllowed ? .success : .error)
        logStore.log("  increased-memory-limit: \(ents.increasedMemory)", level: ents.increasedMemory ? .success : .debug)
        logStore.log("  extended-virtual-addressing: \(ents.extendedVA)", level: ents.extendedVA ? .success : .debug)
        if !ents.extendedVA {
            logStore.log("  Tip: Use GetMoreRam to inject extended-virtual-addressing", level: .info)
        }
    }

    private var actionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button("Enable JIT") {
                    enableJITViaStikDebug()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button("Wine Virtual Desktop") {
                    // S3-pre R2v2: raw rpcss.exe CANNOT run standalone —
                    // its wmain unconditionally StartServiceCtrlDispatcherW's
                    // (rpcss_main.c:282), which RPCs back to the SCM; without
                    // services.exe it raised + wedged in
                    // service_run_main_thread, and explorer's
                    // CoRegisterClassObject wedged behind it (seq-3680 run).
                    // Proper bootstrap: explorer's cmdline child = services.exe
                    // (SCM host, windows-subsystem = no console). It creates
                    // \pipe\svcctl early, runs auto-start services (MountMgr/
                    // Eventlog/NDIS/nsiproxy/PlugPlay — winedevice/plugplay
                    // are bundled; failures tolerated), and combase's
                    // start_rpcss then demand-starts RpcSs through the SCM
                    // with a 30s start-pending wait → rpcss runs as services'
                    // child (3-deep tree, proven depth) with a proper
                    // dispatcher connection → epmapper up → real COM.
                    // Known risk: if shellwindows_init beats services.exe's
                    // RPC_Init, OpenSCManager fails → watch whether that
                    // fails fast or hits the RaiseException→CS wedge again.
                    // The desktop is the session's virtual monitor, not a size of its
                    // own: runWineFullSequence re-derives the monitor from the view (or
                    // Documents/madeira-screen.txt) AFTER this handler, so a fixed
                    // 960x540 here made explorer program a mode smaller than the monitor
                    // the compositor lays out against — a desktop drawn in the top-left
                    // three quarters of its frame. (It went unnoticed while 960x540 was
                    // missing from the mode list and the request was refused.)
                    let screenKnob = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                        .flatMap { try? String(contentsOf: $0.appendingPathComponent("madeira-screen.txt"),
                                               encoding: .utf8) }
                    let deskMode = GuestDisplay.configureSessionDefault(view: GuestDisplay.landscapeViewSize,
                                                                        knob: screenKnob)
                    let deskW = deskMode.w, deskH = deskMode.h
                    setenv("MADEIRA_EXE", "explorer.exe", 1)
                    setenv("MADEIRA_ARGS",
                           "/desktop=shell,\(deskW)x\(deskH) C:\\windows\\system32\\services.exe", 1)
                    setenv("MADEIRA_DESKTOP", "1", 1)
                    setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                    setenv("MADEIRA_SCREEN_H", String(deskH), 1)
                    // explorer owns the size in desktop mode; say so in the
                    // [display] virtual monitor line win32u prints at session start.
                    setenv("MADEIRA_SCREEN_SRC", "desktop", 1)
                    // ml1090 — same reason as configureSessionDefault's own
                    // publish: the shim's cache may already have latched the
                    // 1024x768 fallback from an earlier layout pass.
                    winios_display_mode_changed(Int32(deskW), Int32(deskH))
                    runWineFullSequence()
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)

                // Every shipped launch target gets its own button here, same
                // style as Wine Virtual Desktop / Enable JIT above. Bitness is
                // decided by WineProcessBridge from the PE header, not by this
                // table — see `launchTargets`.
                ForEach(launchTargets, id: \.exe) { test in
                    Button(test.label) {
                        // ml: only for an ACTUAL new launch — runWineFullSequence's
                        // own relaunch guard silently no-ops while a session is
                        // already up, and starting the spinner anyway would leave
                        // it spinning over a tap that did nothing.
                        if !isLaunching { beginLaunchSpinner() }
                        setenv("MADEIRA_EXE", test.exe, 1)
                        unsetenv("MADEIRA_ARGS")
                        unsetenv("MADEIRA_DESKTOP")
                        runWineFullSequence()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(test.tint)
                }

                // User-added buttons (Custom… ▸ Add Button), same launch
                // path as the full-path launchTargets entries above — see
                // launchCustomExe(_:), which is also where the loading
                // spinner starts for THIS button (shared with the Custom…
                // alert's own Launch button below). Long-press for
                // Rename/Remove; built-in buttons above offer neither.
                ForEach(Array(customLaunchButtons.enumerated()), id: \.element.path) { index, button in
                    Button(button.label) {
                        launchCustomExe(button.path)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.customButtonTints[index % Self.customButtonTints.count])
                    .contextMenu {
                        Button("Rename") {
                            renameLaunchButtonPath = button.path
                            renameLaunchButtonText = button.label
                            showRenameLaunchAlert = true
                        }
                        Button("Remove", role: .destructive) {
                            removeCustomLaunchButton(button)
                        }
                    }
                }

                // Prompts via the .alert below, then launches exactly like the
                // full-path launchTargets entries above (Mirror's Edge,
                // INSIDE) — see launchCustomExe().
                Button("Custom…") {
                    customExePath = UserDefaults.standard.string(forKey: Self.customExePathKey)
                        ?? customExePath
                    showCustomLaunchAlert = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)

                Button("Clear Log") {
                    logStore.clear()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding()
        }
        // Modal popup rather than the old 2-line text-field row (removed —
        // it crashed): an .alert can't be laid out wrong, and it cannot
        // collide with the horizontal ScrollView's own gesture recognizers.
        .alert("Custom Launch", isPresented: $showCustomLaunchAlert) {
            TextField("C:\\Games\\Foo\\foo.exe", text: $customExePath)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Launch") { launchCustomExe() }
            Button("Add Button") { addCustomLaunchButton() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Full Windows path to the .exe, passed to MADEIRA_EXE exactly as typed.")
        }
        // Long-press ▸ Rename on a user-added button (the ForEach above) —
        // same alert-not-inline-editor reasoning as Custom Launch itself.
        .alert("Rename Button", isPresented: $showRenameLaunchAlert) {
            TextField("Name", text: $renameLaunchButtonText)
                .autocorrectionDisabled()
            Button("Save") {
                if let path = renameLaunchButtonPath {
                    renameCustomLaunchButton(path: path, to: renameLaunchButtonText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New name for this launch button.")
        }
    }

    /// UserDefaults key for the last path typed into the Custom… launcher —
    /// deliberately a plain UserDefaults value (not the Documents/*.json
    /// files InputSettings/TouchControlsModel use) since it is one string
    /// with no other app code that needs to read it off disk.
    private static let customExePathKey = "madeiraCustomExePath"

    /// Launch mechanism identical to the launchTargets ForEach above and the
    /// full-path entries in that table (Mirror's Edge, INSIDE): MADEIRA_EXE
    /// gets the path VERBATIM and WineProcessBridge.m detects the backslash
    /// and launches it as-is, no syswow64 prefix. Trims whitespace and
    /// refuses an empty path rather than handing Wine a blank MADEIRA_EXE.
    /// `path` is nil for the alert's own Launch button (uses/persists the
    /// text field, `customExePath`); a user-added button below passes its
    /// stored path explicitly and does not touch the text field or
    /// `customExePathKey`.
    private func launchCustomExe(_ path: String? = nil) {
        let trimmed = (path ?? customExePath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logStore.log("Custom launch: empty path, ignored.", level: .error)
            return
        }
        if path == nil {
            customExePath = trimmed
            UserDefaults.standard.set(trimmed, forKey: Self.customExePathKey)
        }
        // ml: covers BOTH callers — the alert's own Launch button and every
        // user-added custom button (see the ForEach above) — so the loading
        // spinner shows for either without a second call site to keep in
        // sync. Guarded the same way as launchTargets: only for a launch
        // that will actually start (see beginLaunchSpinner's doc comment).
        if !isLaunching { beginLaunchSpinner() }
        setenv("MADEIRA_EXE", trimmed, 1)
        unsetenv("MADEIRA_ARGS")
        unsetenv("MADEIRA_DESKTOP")
        runWineFullSequence()
    }

    /// UserDefaults key for the persisted, JSON-encoded `[CustomLaunchButton]`
    /// array — the user-added buttons on the same row as launchTargets.
    private static let customLaunchButtonsKey = "madeiraCustomLaunchButtons"

    /// Decodes `customLaunchButtonsKey` for the `@State` initializer above;
    /// any decode failure (missing key, corrupt data) is treated as "no
    /// buttons yet" rather than a crash.
    private static func loadCustomLaunchButtons() -> [CustomLaunchButton] {
        guard let data = UserDefaults.standard.data(forKey: customLaunchButtonsKey),
              let decoded = try? JSONDecoder().decode([CustomLaunchButton].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func saveCustomLaunchButtons() {
        guard let data = try? JSONEncoder().encode(customLaunchButtons) else { return }
        UserDefaults.standard.set(data, forKey: Self.customLaunchButtonsKey)
    }

    /// Add Button in the Custom Launch alert: takes the typed path as-is
    /// (trimmed, same validation as Launch), derives a label from the exe's
    /// file name (text after the last backslash, minus a trailing ".exe",
    /// case preserved), and appends a persistent button — unless a button
    /// for that exact path already exists, in which case this is a no-op
    /// and the alert simply closes.
    private func addCustomLaunchButton() {
        let trimmed = customExePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logStore.log("Custom launch: empty path, ignored.", level: .error)
            return
        }
        customExePath = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.customExePathKey)
        guard !customLaunchButtons.contains(where: { $0.path == trimmed }) else { return }
        let fileName = trimmed.split(separator: "\\").last.map(String.init) ?? trimmed
        let label = fileName.lowercased().hasSuffix(".exe")
            ? String(fileName.dropLast(4))
            : fileName
        customLaunchButtons.append(CustomLaunchButton(label: label, path: trimmed))
        saveCustomLaunchButtons()
    }

    /// Long-press ▸ Remove on a user-added button (see the ForEach above).
    /// Built-in launchTargets buttons have no such context menu at all.
    private func removeCustomLaunchButton(_ button: CustomLaunchButton) {
        customLaunchButtons.removeAll { $0.path == button.path }
        saveCustomLaunchButtons()
    }

    /// Long-press ▸ Rename on a user-added button: keyed by `path` (the only
    /// stable identity `CustomLaunchButton` has — see its own doc comment),
    /// same persistence as every other mutation of `customLaunchButtons`. A
    /// blank/whitespace-only name is refused rather than saved, same
    /// validation as the path fields elsewhere in this alert family.
    private func renameCustomLaunchButton(path: String, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let i = customLaunchButtons.firstIndex(where: { $0.path == path }) else { return }
        customLaunchButtons[i] = CustomLaunchButton(label: trimmed, path: path)
        saveCustomLaunchButtons()
    }

    private func runTriangleTest() {
        logStore.log("D3D11 triangle test: full sequence", level: .info)
        // Reuse the existing full Wine sequence but target triangle.exe.
        // WineProcessBridge has the program baked in for now — to flip it
        // requires a signature change. For this iteration we rely on the
        // build's WineProcessBridge.m pointing at triangle.exe.
        runWineFullSequence()
    }

    private var logConsole: some View {
        let entries = logStore.entries.sorted(by: { $0.lastTimestamp > $1.lastTimestamp })
        return List(entries) { entry in
            HStack(alignment: .top, spacing: 8) {
                // Timestamp of LAST occurrence
                Text(timeString(entry.lastTimestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                // Level chip
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(colorForLevel(entry.level))
                    .frame(width: 28, alignment: .leading)
                // Last raw message (the most recent line that matched this signature)
                Text(entry.lastRaw)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                // Count badge (only if count > 1)
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.secondary)
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // ml540: ONE formatter for the whole app, built once on first use.
    //
    // This used to construct a fresh DateFormatter on every call — once per log
    // row per body evaluation — and each new instance opens ICU underneath
    // (udat_open -> SimpleDateFormat::initialize). That is not just wasteful,
    // it is where ml539 died: after Wine's main thread exited, ICU ran
    // _platform_strcmp on a pointer into that dead thread's stack (x0 sat 0x68C
    // below its recorded tsd_base) and took the whole app down. A single
    // long-lived formatter does the ICU open ONCE, at first log render, long
    // before Wine exists.
    private static let hhmmss: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Main-thread only (SwiftUI body evaluation) — DateFormatter is not safe to
    // share across threads.
    private func timeString(_ date: Date) -> String {
        ContentView.hhmmss.string(from: date)
    }

    private var statusColor: Color {
        switch jitStatus {
        case .unknown: return .gray
        case .testing: return .yellow
        case .available: return .green
        case .mappingOnly: return .orange
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch jitStatus {
        case .unknown: return "Not tested"
        case .testing: return "Testing..."
        case .available: return "Available"
        case .mappingOnly: return "Needs debugger"
        case .unavailable: return "Unavailable"
        }
    }

    private var deviceInfo: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine
    }

    private func colorForLevel(_ level: LogStore.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .debug: return .gray
        }
    }

    private func runJITTest() {
        jitStatus = .testing
        logStore.log("Starting JIT test...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT for this app.", level: .error)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let mappingOk = jit_test_mapping()
                        DispatchQueue.main.async {
                            if mappingOk {
                                jitStatus = .mappingOnly
                                logStore.log("Dual mapping works. Enable JIT via StikDebug to unlock execution.", level: .success)
                            }
                        }
                    }
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop detected — try 'Test JIT (Alt)' for debugger-allocated memory", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("JIT test failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runJITTestStrategy2() {
        jitStatus = .testing
        logStore.log("Starting JIT test (Strategy 2: debugger-allocated RX)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = jit_test_execute_strategy2()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("JIT is fully functional (strategy 2)!", level: .success)
                case -2:
                    jitStatus = .unavailable
                    logStore.log("CS_DEBUGGED not set. Use StikDebug to enable JIT.", level: .error)
                case -3:
                    jitStatus = .unavailable
                    logStore.log("Fault loop — debugger-allocated pages also rejected", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("Strategy 2 failed with result: \(result)", level: .error)
                }
            }
        }
    }

    private func runFEXTest() {
        logStore.log("Starting FEX-Emu integration test...")
        jitStatus = .testing

        // Set up FEX log callback
        fex_set_log_callback { msg in
            if let msg = msg {
                let str = String(cString: msg)
                DispatchQueue.main.async {
                    LogStore.shared.log(str, level: .debug)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = fex_test_execute()

            DispatchQueue.main.async {
                switch result {
                case 42:
                    jitStatus = .available
                    logStore.log("FEX-Emu test PASSED: x86-64 code returned 42!", level: .success)
                case -1:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test FAILED (init/setup error)", level: .error)
                default:
                    jitStatus = .unavailable
                    logStore.log("FEX-Emu test returned \(result)", level: .error)
                }
            }
        }
    }

    private func enableJITViaStikDebug() {
        jitStatus = .testing
        logStore.log("Requesting JIT via StikDebug URL scheme...")

        StikJITHelper.enableJIT { success in
            if success {
                jitStatus = .available
                logStore.log("JIT enabled! Debugger attached.", level: .success)
            } else {
                jitStatus = .unavailable
                logStore.log("Failed to enable JIT via StikDebug", level: .error)
            }
        }
    }

    /// Full sequence: allocate JIT pool, start wineserver, start Wine.
    /// Debugger stays attached during PE loading so mprotect_exec can use BRK
    /// to prepare code pages. Detach happens after Wine finishes + recovery.
    private func launchLibraryEntry(_ entry: LibraryEntry) {
        guard !isLaunching, wine_process_is_running() == 0, wineserver_is_running() == 0, library.current == nil else {
            library.error = "A session is already running."; return
        }
        // ml1330: "ready" means a JIT pool exists or a debugger that can grant one
        // is attached now. CS_DEBUGGED alone stays set after StikDebug is gone.
        guard StikJITHelper.readyToLaunch else {
            guard jit_check_debugged(), LibraryFlags.enabled("MADEIRA_JIT_RECONNECT") else {
                library.error = "Enable JIT before playing."; return
            }
            reconnectJIT(then: entry)
            return
        }
        do { if entry.desktop != true { _ = try LibraryModel.executable(entry.relativePath) }; try entry.validate() }
        catch { library.error = error.localizedDescription; return }
        guard entry.windowsPath.utf8.count < 1024, entry.arguments.utf8.count < 1024 else {
            library.error = "The executable path or launch arguments are too long."; return
        }
        SteamLibraryModel.shared.stopScan()
        entry.configureLaunch()
        library.begin(entry)
        runWineFullSequence(profile: entry)
    }

    /// ml1330: JIT was enabled earlier in this run but StikDebug has since gone
    /// and no pool was taken. Re-open StikDebug (which re-attaches and, through
    /// pollForJIT, allocates the pool immediately), then continue this launch
    /// once Madeira is in the foreground again.
    private func reconnectJIT(then entry: LibraryEntry) {
        logStore.log("[jit-early] ml1330 JIT connection lost before the first launch; reopening StikDebug")
        library.error = nil
        StikJITHelper.enableJIT { ok in
            guard ok, StikJITHelper.readyToLaunch else {
                library.error = "Madeira could not reconnect JIT. Open StikDebug, enable JIT for Madeira, then press Play again."
                return
            }
            let launch = { self.launchLibraryEntry(entry) }
            if UIApplication.shared.applicationState == .active { launch(); return }
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                           object: nil, queue: .main) { _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                launch()
            }
        }
    }

    private func runWineFullSequence(profile: LibraryEntry? = nil) {
        // ml: THE RELAUNCH GUARD. See isLaunching's doc comment. Every early
        // return on this path — this one included — logs a
        // "[launch] ignored: <reason>" line through the app's normal log
        // function (so it lands in the exported log, not just stderr), so a
        // tap that does nothing visible ALWAYS has a reason on record.
        guard !isLaunching else {
            logStore.log("[launch] ignored: a session is already launching or running — "
                         + "wait for it to finish (or its boot to fail/time out) before trying again",
                         level: .error)
            return
        }
        guard StikJITHelper.readyToLaunch else {
            logStore.log("[launch] ignored: no JIT pool and no attached debugger — press 'Enable JIT' first", level: .error)
            return
        }
        isLaunching = true
        MetalBackedView.presentCountAtLaunch = madeira_get_present_count()
        // No program is running yet — a cursor a PREVIOUS session left
        // showing (or the stale builtin-fallback arrow a touch can create
        // even before any SetCursor — see winios_ensure_cursor_layer's doc
        // comment in Winios.m) must not carry into this one before its own
        // first pSetCursor call.
        winios_cursor_show(0)

        logStore.log("Running full Wine sequence...")

        // Start a main thread heartbeat to diagnose hang
        var heartbeatCount = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            heartbeatCount += 1
            os_log("[HEARTBEAT] main thread alive #%d", heartbeatCount)
        }

        // Pause UI flushing — prevents ALL SwiftUI re-renders during Wine execution,
        // so zero main thread hang time accumulates while debugger is attached
        logStore.uiPaused = true

        // Suppress os_log from wineserver — hundreds of messages/sec cause os_log buffer
        // contention that blocks the main thread RunLoop, triggering iOS hang detection
        ws_log_quiet = 1

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Allocate JIT pool (BRK suspends entire process)
            // 128 MB was enough for cube but Thumper exhausts it (more PE
            // copies + larger FEX block cache). Desktop mode holds the
            // session's aarch64 image set AND every child's x64 set AND the
            // FEX code buffers in ONE pool: Thumper-under-desktop hit 199MB
            // of image copies alone (2026-07-06), leaving the FEX tail carve
            // colliding with the head. 384 MB fits both plus slack; the pool
            // is dual-map + NO_FOOTPRINT so unwritten pages cost nothing.
            //
            // 2026-07-10 (Steam S3): 384 MB is VIRTUAL-exhausted by Steam's
            // pseudo-process fan-out — steam.exe + services + rpcss + cmd +
            // conhost + steamerrorreporter64 each copy their whole DLL set
            // (owner-keyed, no .text sharing yet) → 138 image copies hit
            // ~365 MB and the crash reporter's ntdll can't fit → the load
            // fails and execution BUS-faults on the un-committed image. Since
            // the pool is jetsam-exempt + demand-committed (unwritten pages
            // cost nothing), raising the VIRTUAL cap is a cheap, safe unblock.
            // 640 MB clears the current fan-out with headroom to reach the
            // ole32 delay-load (FEX riprel probe) and beyond. The real fix for
            // the PHYSICAL duplication is .text sharing (deferred project).
            //
            // 2026-07-10 pm (task #34 / CEF): 896 MB — libcef.dll's 212MB
            // pool copy EXHAUSTED 640 (bump 412MB + no contiguous 212MB →
            // libcef load degraded → init CHECK). Pure-x64 skip-copy was
            // trialed and reverted (broke x18-trampoline layout, ml68);
            // until skip-copy or .text sharing lands, buy headroom. Virtual
            // is jetsam-exempt; the copy itself is ~212MB real RSS when
            // written.
            // 2026-08-01 (ml364): 1152 MB — ml363 died at MSM depth on pool
            // EXHAUSTION (bump 858MB, freelist 0, tail-reserve 64MB) when
            // Chrome's in-proc GPU thread requested a doubled 32MB EC code
            // buffer; the fallback landed non-executable in the guest band and
            // FEX scribbled through a garbage CodeBuffer. NOTE the jetsam
            // ledger note above is STALE: the pool was never exempt and
            // arrives FULLY DIRTY from StikDebug's TXM blessing writes, so
            // this +256MB costs +256MB of the 4096MB budget up front. The
            // ml362/ml363 footprint work (peak 3804→3190) is what pays for
            // it. The real fix for both sides is still .text sharing.
            // 2026-08-01 (ml367): back to 896 MB. ml364 needed 1152 because the
            // shipped PE DLLs carried DWARF debug sections (llvm-mingw links
            // -Wl,-debug:dwarf) and the pool copies the ENTIRE image, so 42% of
            // every copy was debug info with no runtime purpose. Stripping them
            // (llvm-strip --strip-debug over the bundle) drops projected peak
            // pool use 894 -> ~653 MB, so 896 restores the ml364-equivalent
            // headroom (~243 MB) while returning 256 MB of footprint — the pool
            // is dirty from birth, so its SIZE is what costs, not its usage.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-02 (ml421): 1024 MB. ml420 (post-#69-fix, deepest run yet:
            // cycle 41) refilled the stripped 896 pool anyway — head 768MB of
            // copies + 176MB tail of EC code buffers collided; the doubled 32MB
            // GPU-thread buffer was refused and the ml361/ml363 ClearCache
            // wild-write returned (now also honestly REFUSED unix-side,
            // rev=ml421). +128MB is the depth lever that fits under jetsam:
            // ml420 peaked 3837 phys; 3837+128=3965 < 4096. Tight — if jetsam
            // returns, the durable fix is .text sharing, not more pool.
            // 2026-08-02 (ml423): BACK to 896. Jetsam DID return — ml422 died a
            // silent EXC_RESOURCE kill at 2.5min (peak 3904, log stops mid-line),
            // exactly the predicted cost of the +128MB dirty-at-birth pool.
            // ml421's honest EC_CODE refusal makes pool exhaustion GRACEFUL now
            // (ctor halving, worst case one thread's 0xdead fault) while jetsam
            // kills the whole app — 896 + graceful degradation strictly beats
            // 1024 + jetsam roulette. Durable fix remains .text sharing.
            // KEEP ios_usable_va_floor PAIRED: 896MB -> 0x7038000000.
            // 2026-08-03 (ml458): STAY at 896 — growth is closed for good.
            // jetsam killed 1024 twice (ml422 peak 3904) and the no-footprint
            // exemption is unreachable: all four (entry-flags, owner) variants
            // return kr=4, and the plain ones expose why — the named entry
            // covers 16KB of the 896MB object, i.e. the kernel wants an entry
            // naming the WHOLE object, which we can never build over memory
            // whose object StikDebug created. Pool stays dirty-from-birth and
            // jetsam-counted, so SIZE is the cost and 896 is the ceiling.
            // ⛔ ml457 re-trialed pure-x64 skip-copy (already dead per ml68
            // above) and it failed again for a different reason: x64 guest
            // RIPs ARE pool-copy aliases, so the copy is the execution
            // substrate — steam.exe died in seconds. Do not try a third time.
            // The remaining levers are USE-side: the 276MB of duplicate copies
            // (.text sharing) and the 214MB tail of EC code buffers.
            // ml668: RUNTIME-SELECTABLE. 896 stays the default and the only
            // value proven for Steam/CEF. 384 is the direct-game experiment:
            // the last good Book of the Dead run used ~139MB of head + ~48MB
            // of tail, so 384 leaves ~197MB of observed slack while returning
            // ~512MB of footprint -- and the pool is dirty from birth, so its
            // SIZE is the cost, not its usage. The VA floor is no longer a
            // hand-paired constant (ml668 derives it from the pool actually
            // allocated), so changing this is now a one-line change.
            // Override lives in Documents/madeira-pool.txt (a bare number of MB)
            // so it can be swapped between runs without a rebuild, and deleting
            // the file reverts to the proven default. Clamped to sane values --
            // a typo here would otherwise move the VA floor with it.
            // ml901 (perf round 2): the DEFAULT is now a function of the SESSION
            // SHAPE, not a single constant. This is not a per-title profile --
            // it is the one structural fact that decides pool demand.
            //
            // The pool is dirty from birth (ml458: StikDebug's TXM blessing
            // writes every page, and the no-footprint exemption is unreachable),
            // so its SIZE costs jetsam budget 1:1 whether or not it is used. On
            // the device it measures poolRX=896MB dirty / 621MB resident against
            // a 4096MB ceiling -- 22% of the budget.
            //
            // What actually consumes it is the number of pseudo-processes that
            // each copy their whole DLL set. A DESKTOP session is the fan-out
            // case (explorer + services + rpcss + cmd + conhost + the CEF
            // helpers; ml364 measured an 858MB bump there, which is why 896 is
            // the proven value and must not move). A DIRECT launch is one
            // process. Measured across every direct-launch log on hand, the
            // high-water mark is head 180.5MB + tail 48MB = 228.6MB; the median
            // is ~100MB. 512 leaves 2.2x headroom over the worst observed run
            // and returns 384MB of footprint.
            //
            // RISK, stated plainly: a direct-launch title that needs more than
            // ~460MB of code space (head + tail) will exhaust the pool. That
            // failure is ALREADY loud and already graceful -- ml421 made the
            // EC_CODE tail carve refuse honestly and FEX halve down, and the
            // head allocator prints
            //     [jit-pool] EXHAUSTED (image ...): want=... bump=.../... tail_resv=...
            //     [jit-pool] EXHAUSTED (anon RWX): ...
            //     [jit-pool] TAIL REFUSED (FEX EC_CODE): ...
            // with the exact numbers. The line below names the knob in the same
            // breath so a log reader never has to know this file exists.
            let isDesktopFanout = getenv("MADEIRA_DESKTOP") != nil
            var poolSizeMB = isDesktopFanout ? 896 : 512
            var poolSource = isDesktopFanout ? "desktop-session default" : "direct-launch default"
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-pool.txt"), encoding: .utf8),
               let mb = Int(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               mb >= 256, mb <= 1152 {
                poolSizeMB = mb
                poolSource = "madeira-pool.txt override"
            }
            logStore.log("JIT pool \(poolSizeMB)MB (\(poolSource)) — raise it with " +
                         "Documents/madeira-pool.txt (bare MB, 256..1152) if the log shows [jit-pool] EXHAUSTED")
            setenv("MADEIRA_POOL_MB", String(poolSizeMB), 1)
            // ml1330: the early pool of the next app run is sized like this session.
            UserDefaults.standard.set(poolSizeMB, forKey: "madeiraLastPoolMB")
            // ml901: [prof] sampling profiler. Documents/madeira-prof.txt holds
            // "period_ms[,report_s]" -- "0" turns it off, absent means ON at the
            // 5ms / 10s default. It samples every thread's PC and buckets it by
            // REGION (FEX JIT output, the FEX runtime, each Wine PE pool copy,
            // our unix binary, the Mach exception handler, Metal, other dylibs,
            // waiting-in-kernel), which is the partition every remaining perf
            // decision needs and the one no existing line reports. It measures
            // and prints its own CPU cost and backs its period off if that ever
            // exceeds 2% of one core, so it can never become the problem.
            // Default ON: a run without it produces no [prof] evidence at all.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-prof.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_PROF", v, 1)
                    logStore.log("Profiler: MADEIRA_PROF=\(v) via madeira-prof.txt")
                }
            }

            // ml694: W^X A/B switch. Documents/madeira-wx.txt containing "0"
            // disables page demotion for the SAME binary, so the on/off
            // comparison needs one rebuild, not two. The previous gate read
            // container paths that can never exist, so it silently forced
            // ENABLED and no A/B was actually possible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wx.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_WX", v, 1)
                logStore.log("W^X override: MADEIRA_WX=\(v) via madeira-wx.txt")
            }

            // ml727: wine-mono backpatcher bridge A/B. Documents/madeira-mono-bridge.txt
            // == "1" sets MADEIRA_WINEMONO_BRIDGE, which arms FEX's Mono code-patching
            // optimisation for wine-mono (recognised since ml712 but activation left
            // opt-in because the bridge reclassifies an XCHG from a true atomic exchange
            // into an alias-directed plain write).
            //
            // Worth arming here: the dominant fault site emits SWPAL, which is exactly
            // what FEX generates for a guest XCHG, and the patching XCHGs sit inside
            // libmono -- so the bridge's "RIP must lie inside Mono" test should pass.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-bridge.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_WINEMONO_BRIDGE", v, 1)
                    logStore.log("Mono bridge: MADEIRA_WINEMONO_BRIDGE=\(v) via madeira-mono-bridge.txt")
                }
            }

            // ml716: syscall-frame context A/B. Documents/madeira-ctx-frame.txt == "1"
            // makes ios_fill_thread_context() report a thread parked inside a syscall
            // using its saved Wine syscall frame (TEB+0x378) instead of the Mach-O
            // registers it happens to be executing. Off by default; native code reads
            // only the environment variable.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-ctx-frame.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_CTX_FRAME", v, 1)
                    logStore.log("Context source: MADEIRA_CTX_FRAME=\(v) via madeira-ctx-frame.txt")
                }
            }

            // ml744: DXMT options passthrough. Documents/madeira-dxmt.txt is copied
            // verbatim into DXMT_CONFIG, which the renderer's config parser reads as
            // inline "key=value" lines, so options can be tried without a rebuild.
            // d3d11.mipClampBC=N is the one that matters for memory: this GPU cannot
            // sample BC, so those textures are expanded to uncompressed and cost 2-8x
            // their shipped size.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-dxmt.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("DXMT_CONFIG", v, 1)
                    logStore.log("DXMT config: \(v) via madeira-dxmt.txt")
                }
            }

            // The session's virtual monitor (2026-09-14). A direct launch used
            // to get a fixed 1024x768 screen whatever the device looked like,
            // so a widescreen game rendered 4:3 and Fit pillarboxed it — the
            // "game runs in a smaller window in landscape" report. The monitor
            // now takes the nearest STANDARD mode to the device's landscape
            // shape, at a phone-sized pixel count; Documents/madeira-screen.txt
            // holding "WxH" (e.g. "1920x1080") overrides it for a session, the
            // same one-file-and-relaunch shape as the knobs below.
            //
            // Desktop mode is untouched: the "Wine Virtual Desktop" and Steam
            // buttons export their own /desktop size (and source=desktop) at
            // press time, after this has run.
            do {
                let knob = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    .flatMap { try? String(contentsOf: $0.appendingPathComponent("madeira-screen.txt"),
                                           encoding: .utf8) }
                let view = GuestDisplay.landscapeViewSize
                let m = GuestDisplay.configureSessionDefault(view: view, knob: knob)
                logStore.log("[display] virtual monitor \(m.w)x\(m.h) (source=\(m.source)) for a "
                             + "\(Int(view.width))x\(Int(view.height))-pt landscape view")
            }

            // Native D3D9 frontend A/B (WOW64_DESIGN.md section 8.5 / 8.8-4).
            // The i386 d3d9.dll games import is now the thin SHIM; with no knob
            // set its DllMain forwards all ten exports to d3d9-emulated.dll, so
            // the default path is the proven emulated DXMT frontend. Writing
            // "native" into Documents/madeira-d3d9.txt makes the same shim bind
            // its unix side instead and run the frontend as native ARM64 code in
            // libdxmt_unix.a -- the whole point of section 8, and the reason the
            // knob is per session rather than per build: both frontends ship in
            // the bundle, so the A/B is one file and a relaunch.
            // "emulated" is the explicit spelling of the default.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-d3d9.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_D3D9", v, 1)
                    logStore.log("D3D9 frontend: MADEIRA_D3D9=\(v) via madeira-d3d9.txt")
                }
            }

            // Generic environment passthrough (ml961). Documents/madeira-env.txt:
            // one NAME=VALUE per line ("#" comments), exported verbatim so any
            // MADEIRA_* runtime knob (MADEIRA_FASTSYNC=0, MADEIRA_FS_NEGCACHE=0,
            // MADEIRA_SRV_STATS=0, ...) can be A/B tested on the device without a
            // rebuild. Applied before the launch so native code sees it from the
            // first getenv. Only MADEIRA_ and DXMT_ names are honoured, so a stray
            // line cannot redirect PATH or the loader.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-env.txt"), encoding: .utf8) {
                for raw in txt.split(whereSeparator: { $0.isNewline }) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    guard name.hasPrefix("MADEIRA_") || name.hasPrefix("DXMT_") else {
                        logStore.log("madeira-env.txt: ignoring \(name) (only MADEIRA_*/DXMT_* names are honoured)")
                        continue
                    }
                    setenv(name, value, 1)
                    logStore.log("Env override: \(name)=\(value) via madeira-env.txt")
                }
            }

            // ml962: the 512MB JIT-pool dump is now OPT-IN.
            //
            // signal_arm64_ios.c writes the WHOLE RW alias to
            // Documents/fex-jit-dump.bin on the first unhandled exec fault and
            // again on the first ILL — an offline-disassembly aid from ml347 that
            // nothing in a normal run wants. At today's pool sizes that is a
            // 512-896MB file written synchronously from a fault handler, into the
            // folder the user syncs, every time a guest faults. m56 produced one.
            //
            // MADEIRA_JIT_DUMP=1 (via Documents/madeira-env.txt, which the block
            // above already passes through) turns it back on. Default off, and the
            // stale file from an earlier run is deleted here so it cannot keep
            // occupying half a gigabyte of the user's storage forever.
            let jitDumpOn = (getenv("MADEIRA_JIT_DUMP").map { String(cString: $0) } ?? "0") != "0"
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let dump = d.appendingPathComponent("fex-jit-dump.bin")
                if jitDumpOn {
                    logStore.log("JIT pool dump ARMED (MADEIRA_JIT_DUMP=1) — the first unhandled guest " +
                                 "fault will write the whole pool to Documents/fex-jit-dump.bin")
                } else if let sz = (try? FileManager.default.attributesOfItem(atPath: dump.path)[.size]) as? Int {
                    try? FileManager.default.removeItem(at: dump)
                    logStore.log("Removed stale Documents/fex-jit-dump.bin (\(sz / 1024 / 1024)MB) — " +
                                 "set MADEIRA_JIT_DUMP=1 in madeira-env.txt to collect one")
                }
            }

            // ===== FEX JIT settings (ml900) =====================================
            // Generic passthrough for FEX's own configuration, same shape as the
            // DXMT block above. Madeira ships no /usr/share/fex-emu/Config.json and
            // no AppConfig/*.json (the device log shows FEX probing for both and
            // finding nothing), so the JIT runs entirely on compiled-in defaults and
            // there was no way to change one without a rebuild. FEX's environment
            // layer reads FEX_<OPTIONNAME>, so one file covers every option rather
            // than growing a switch per knob.
            //
            // Documents/madeira-fex.txt: one NAME=VALUE per line, names exactly as
            // they appear in FEX's Config.json.in, uppercased. Lines starting with
            // '#' are comments. Examples:
            //     X87REDUCEDPRECISION=1   # 64-bit x87 instead of 80-bit. Much faster
            //                             # for 32-bit x87-heavy code, and a real
            //                             # accuracy loss: anything that depends on
            //                             # 80-bit intermediates (some geometry and
            //                             # physics) can render or behave differently.
            //     MAXINST=500             # smaller multiblock blocks: less compile
            //                             # stutter, more dispatch
            //     TSOENABLED=0            # relax emulated memory ordering. FAST AND
            //                             # UNSAFE: x86 is TSO and ARM64 here is not,
            //                             # so this can break any multithreaded guest.
            // The effective values are printed once per process as [fex-cfg], so a
            // log always says which way a run shipped.
            //
            // Name validation is deliberate: this writes into the process environment
            // that the whole Wine session inherits, so only [A-Z0-9_] names are
            // accepted and each is prefixed with FEX_ here -- a line in this file can
            // never set an arbitrary environment variable.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-fex.txt"), encoding: .utf8) {
                var applied: [String] = []
                for rawLine in txt.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let name = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, !value.isEmpty,
                          name.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else {
                        logStore.log("FEX config: ignoring malformed line '\(line)'", level: .error)
                        continue
                    }
                    setenv("FEX_" + name, value, 1)
                    applied.append("\(name)=\(value)")
                }
                if !applied.isEmpty {
                    logStore.log("FEX config: \(applied.joined(separator: " ")) via madeira-fex.txt")
                }
            }

            // ml998/2026-09-18: FEAT_LRCPC2 probe.
            //
            // CPUFeatures.cpp cannot ask the CPU what it is -- it is a PE module with
            // no unix func table -- so HOSTFEATURES=ENABLELRCPC2 was left as a user
            // opt-in. The app CAN ask, and this is where the answer belongs, one
            // sysctl at startup. It is REPORTED and deliberately NOT auto-applied;
            // the reason is a property of this port, not of the silicon, so it is
            // worth stating where the next person will look for it.
            //
            // LRCPC2's whole value is folding a displacement into the access as
            // `ldapur/stlur wR, [Xn, #imm9]'. That can only happen if the JIT still
            // has the displacement when it emits the access -- and behind a guest
            // window it never does. Arm64JITCore::GetGuestMemAddr (FEXCore JIT
            // MemoryOps.cpp) returns NoOffset on EVERY non-identity path, because
            // the guest base has to be applied as `Base + zext32(EA + disp)' and an
            // imm9 would add the displacement on the far side of the window
            // (`Base + zext32(EA) + disp'), which leaves the window whenever an x86
            // effective address wraps at 4 GiB. So LoadMemTSO/StoreMemTSO see
            // Guest.Offset invalid, emit `ldapur [Xn, #0]', and the displacement is
            // still materialised by the add/sub inside GetGuestMemAddr.
            //
            // Counted, for `add [ebp-516], reg' (load-modify-store, the shape the
            // hot blocks are full of):
            //   OFF: one IR Add for EA+disp, CSE'd across the load and the store,
            //        plus one ApplyGuestBase per access  = 3 address instructions.
            //   ON:  SelectAddressMode peels the displacement, so there is no IR Add
            //        to share, and each access re-emits `sub Tmp, base, #516' plus
            //        `add Tmp, GUEST_BASE, Tmp, UXTW'  = 4.
            // It is a one-instruction REGRESSION per load-modify-store here, not a
            // win, and on an A12/A13 (ARMv8.3, LRCPC but not LRCPC2) an unguarded
            // enable would emit an undefined instruction in every JIT block. Hence:
            // report, do not apply. Turning this into a win needs GetGuestMemAddr to
            // learn a window-safe offset path first; the sysctl result below is what
            // that work would gate on.
            do {
                var lrcpc2: Int32 = 0
                var sz: Int = MemoryLayout<Int32>.size
                let ok: Bool = sysctlbyname("hw.optional.arm.FEAT_LRCPC2", &lrcpc2, &sz, nil, 0) == 0
                let present: Bool = ok && lrcpc2 != 0
                var msg: String = "[fex-cfg] FEAT_LRCPC2="
                msg += ok ? String(lrcpc2) : "?"
                if present {
                    msg += " -> LRCPC2 TSO addressing AVAILABLE but NOT auto-enabled:"
                    msg += " GetGuestMemAddr folds every displacement into the address behind"
                    msg += " the guest window, so ldapur #0 would save nothing and would cost"
                    msg += " one extra instruction per load-modify-store"
                } else {
                    msg += " -> LRCPC2 unavailable on this CPU; TSO stays on ldapr/stlr"
                }
                if getenv("FEX_HOSTFEATURES") != nil {
                    msg += " | HOSTFEATURES set by madeira-fex.txt, left alone"
                }
                logStore.log(msg)
            }

            // 2026-09-23: HOST FEATURES ARE PROBED, NOT ASSUMED.
            //
            // CPUFeatures.cpp (a PE module that cannot call sysctl) used to claim a
            // fixed feature set that happens to be true of the newest phones. On an
            // older core that is silent corruption, not a crash: with FEAT_AFP
            // claimed but absent, FPCR.NEP is RES0, every scalar SSE operation
            // zeroes the upper lanes of its destination instead of preserving them,
            // and a 32-bit title rendered garbage text and geometry on a tablet
            // while the same build was correct on a phone. The app CAN ask, so it
            // does, and hands the answers over in one variable. A sysctl that does
            // not exist is reported as "?" and left at the old assumption.
            do {
                let probes: [(key: String, sysctl: String)] = [
                    ("AFP",    "hw.optional.arm.FEAT_AFP"),
                    ("FLAGM",  "hw.optional.arm.FEAT_FlagM"),
                    ("FLAGM2", "hw.optional.arm.FEAT_FlagM2"),
                    ("FCMA",   "hw.optional.arm.FEAT_FCMA"),
                    ("RCPC",   "hw.optional.arm.FEAT_LRCPC"),
                    ("AES",    "hw.optional.arm.FEAT_AES"),
                    ("PMULL",  "hw.optional.arm.FEAT_PMULL"),
                    ("SHA",    "hw.optional.arm.FEAT_SHA256"),
                    ("CRC",    "hw.optional.armv8_crc32"),
                    ("ATOMICS", "hw.optional.arm.FEAT_LSE"),
                ]
                var parts: [String] = []
                for p in probes {
                    var v: Int32 = 0
                    var sz: Int = MemoryLayout<Int32>.size
                    if sysctlbyname(p.sysctl, &v, &sz, nil, 0) == 0 {
                        parts.append(p.key + "=" + (v != 0 ? "1" : "0"))
                    } else {
                        parts.append(p.key + "=?")
                    }
                }
                let joined: String = parts.joined(separator: ",")
                setenv("FEX_MADEIRA_HOSTPROBE", joined, 1)
                logStore.log("[fex-cfg] host feature probe: " + joined)
            }
            // ===== end FEX JIT settings =========================================
            profile?.applyEnvironment()

            // ml734: Theorafile call tracer. Documents/madeira-tf-trace.txt == "1"
            // redirects libtheorafile's tf_* exports through wrappers in
            // tftrace-x64.dll that call the original and report the RETURN
            // value. The intro decodes and plays, the stream reaches a clean
            // end of file, the decoder stops reading -- and the game never
            // leaves VideoContext. File EOF is not decoder EOS, and a call
            // count cannot tell "tf_eos returns false forever" from "it returns
            // true and the managed side ignores it". Only the return value can.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-tf-trace.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_TF_TRACE", v, 1)
                    logStore.log("Theorafile tracer: MADEIRA_TF_TRACE=\(v) via madeira-tf-trace.txt")
                }
            }

            // ml731: Windows shared-data clock A/B. Documents/madeira-usd-time.txt == "1"
            // makes wineserver update KUSER_SHARED_DATA's SystemTime, InterruptTime
            // and TickCount again. Without it those stay frozen at their init values,
            // so GetTickCount/Environment.TickCount/DateTime.UtcNow never advance and
            // every time-gated transition in a managed game waits forever while the
            // renderer keeps drawing. Opt-in only because the old code claimed the
            // write faulted; this should become unconditional once proven.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-usd-time.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_USD_TIME", v, 1)
                    logStore.log("Shared-data clock: MADEIRA_USD_TIME=\(v) via madeira-usd-time.txt")
                }
            }

            // ml730: REAL thread suspension A/B. Documents/madeira-real-suspend.txt == "1"
            // makes a Wine suspend actually stop the Mach thread and keep it stopped
            // until the matching resume, instead of only snapshotting its registers
            // and bumping a counter while the target keeps running.
            //
            // Off by default and reversible on purpose: wineserver is a thread inside
            // this same Mach process and shares the allocator with the guest, so truly
            // freezing a thread that holds the malloc lock or FEX's CodeInvalidationMutex
            // can deadlock whoever suspended it. Windows apps tolerate preemptive suspend
            // because the suspender does not share their heap; here it does.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-real-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MADEIRA_REAL_SUSPEND", v, 1)
                    logStore.log("Thread suspension: MADEIRA_REAL_SUSPEND=\(v) via madeira-real-suspend.txt")
                }
            }

            // ml713: Mono suspend-policy A/B. Documents/madeira-mono-suspend.txt
            // containing "preemptive" (or "coop"/"hybrid") sets MONO_THREADS_SUSPEND
            // for wine-mono, so the comparison needs no rebuild.
            //
            // EXPERIMENT, NOT A FIX, and deliberately not a default. Marvel Cosmic
            // Invasion deadlocks with one thread owning a Mono critical section while
            // looping on mono_lls_find/usleep waiting for a thread-info record, and six
            // threads queued behind that section. Preemptive suspend would sidestep the
            // handshake -- but it needs SuspendThread + GetThreadContext to yield a
            // coherent x86-64 context for a guest thread stopped anywhere, including
            // mid-JIT-block, and that path has never been exercised under FEX. It may
            // trade a deadlock for a worse failure. If it does get in-game, that is NOT
            // evidence for any particular theory of the deadlock.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-mono-suspend.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty {
                    setenv("MONO_THREADS_SUSPEND", v, 1)
                    logStore.log("Mono suspend policy: MONO_THREADS_SUSPEND=\(v) via madeira-mono-suspend.txt")
                }
            }

            winios_phase("pool-alloc-begin")
            logStore.log("Allocating \(poolSizeMB)MB JIT pool (BRK will suspend process)...")
            let t0 = CFAbsoluteTimeGetCurrent()
            let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            winios_phase("pool-ready")
            logStore.log("BRK suspension lasted \(String(format: "%.2f", elapsed))s")

            // ml762: remote Metal backend. Documents/madeira-remote.txt holds
            // "<host-ip> <token>" and routes winemetal to a Metal daemon on that
            // host instead of the local device. The mode is decided ONCE per
            // process: flipping it later would leave handles from two address
            // spaces alive at the same time, which is precisely what the handle
            // tag exists to make impossible.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-remote.txt"), encoding: .utf8) {
                let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                                .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    setenv("DXMT_REMOTE_METAL", parts[0], 1)
                    setenv("RMETAL_TOKEN", parts[1], 1)
                    logStore.log("remote Metal: host=\(parts[0]) via madeira-remote.txt", level: .success)
                } else if !parts.isEmpty {
                    logStore.log("madeira-remote.txt needs '<host-ip> <token>'", level: .error)
                }
            }

            // ml761: top-level API census. Documents/madeira-apicensus.txt == "1"
            // counts every call across the PE->unix winemetal boundary and
            // classifies each as producer, consumer, lifetime, query, sync,
            // presentation or bulk-memory. Needed because a packed command
            // batch carries GUEST handles -- raw pointer casts, meaningless on
            // another machine -- so every handle producer and consumer has to
            // be redirected together.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-apicensus.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_API_CENSUS", v, 1)
                logStore.log("API census: DXMT_API_CENSUS=\(v) via madeira-apicensus.txt")
            }

            // ml760: shadow-pack mode. Documents/madeira-shadow.txt == "1" packs
            // and validates every real render batch into the remote wire format,
            // then discards it and renders locally as normal. Exercises the
            // packer against live traffic where being wrong costs nothing. The
            // check that matters is packed counts equalling census counts: a
            // silently skipped command would otherwise surface as a subtly wrong
            // frame on another machine.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-shadow.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_SHADOW_PACK", v, 1)
                logStore.log("shadow pack: DXMT_SHADOW_PACK=\(v) via madeira-shadow.txt")
            }

            // ml758: wmtcmd census. Documents/madeira-census.txt == "1" counts
            // which of the 59 render/compute/blit command types a workload
            // actually emits, and how large their sidecar data gets. Needed
            // before serialising wmtcmd_* for the remote Metal transport --
            // building a schema for all 59 on speculation would be weeks of
            // work for commands no title may ever issue.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-census.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("DXMT_CMD_CENSUS", v, 1)
                logStore.log("wmtcmd census: DXMT_CMD_CENSUS=\(v) via madeira-census.txt")
            }

            // ml757: FEX arena placeholder. Documents/madeira-arena.txt == "1"
            // makes Wine reserve FEX's host arena before any PE loads. OFF by
            // default: FEX still selects its own band, and on hardware that
            // band IS the reservation, so enabling it starves FEX and kills
            // x64 before the first window. Proven correct on the research VM
            // (8GB held, 0 of 123 guest images inside it) -- turn on only once
            // FEX consumes WINE_IOS_FEX_ARENA_BASE/SIZE instead of choosing.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-arena.txt"), encoding: .utf8) {
                let v = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                setenv("MADEIRA_FEX_ARENA", v, 1)
                logStore.log("FEX arena placeholder: MADEIRA_FEX_ARENA=\(v) via madeira-arena.txt")
            }

            // ml748: W^X A/B probe. Documents/madeira-wxprobe.txt == "1" runs it.
            // Loading xtajit64.dll faults writing its .rdata on the jailbroken
            // research VM and not on this phone, with CS_DEBUGGED live in both,
            // so attachment is not the variable. Either the VM is stricter than
            // real hardware (its patchVmMapProtect() was removed, and that is
            // what forces W to stick on file-backed pages), or hardware masks a
            // genuine bug and the loader must stop holding RWX over image pages.
            // Reasoning cannot separate those; the SAME build reporting on both
            // machines can. Runs here because it needs the real container, the
            // real sandbox and a live cs_wx_enabled map -- a standalone binary
            // over SSH already answered this wrongly once.
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let txt = try? String(contentsOf: d.appendingPathComponent("madeira-wxprobe.txt"), encoding: .utf8),
               txt.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                logStore.log("W^X probe armed via madeira-wxprobe.txt", level: .success)
                jit_wx_probe()
            }

            if let pool = pool {
                logStore.log("JIT pool: RX=\(String(format: "%p", Int(bitPattern: pool.rx))), RW=\(String(format: "%p", Int(bitPattern: pool.rw))), size=\(pool.size / 1024 / 1024)MB", level: .success)
                setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
                setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
                setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
                setenv("MADEIRA_POOL_MB", String(pool.size / 1024 / 1024), 1)   // ml1330: actual (early/reused) size
            } else {
                // ml596: ABORT. "Continuing without it" produced ml595 — a run that
                // looked like an ARM64EC/optimizer regression but was only Wine
                // executing with no JIT pool, and it cost a diagnostic cycle plus a
                // wrong conclusion I wrote into the source. A run without the pool can
                // only manufacture misleading secondary crashes, so refuse to start one.
                // ml962: the reason is printed by allocatePool itself, on the
                // [jit-pool] lines directly above — it knows whether the debugger
                // was gone, whether every placement was rejected, or whether a
                // cached pool had been torn down. This used to assert "all
                // placements landed in the forbidden guest 64G window" no matter
                // what actually happened, which sent m56's diagnosis after an
                // address-space problem that did not exist.
                logStore.log("JIT pool unavailable — not starting Wine (see the [jit-pool] lines above).", level: .error)
                logStore.uiPaused = false
                // ml: reset the relaunch guard on every exit from this
                // closure, not just the successful-completion path at the
                // bottom — a failure here used to leave isLaunching stuck
                // `true` forever, silently ignoring (see the guard at the top
                // of this function) every later tap with no way out short of
                // relaunching the app.
                DispatchQueue.main.async { self.isLaunching = false; LibraryModel.shared.launchFailed() }
                return
            }

            // Step 1b (ml524, #67): DETACH THE DEBUGGER NOW, while the VM map is small.
            //
            // Every ~54s whole-app stall coincides with StikDebug DEPARTING — clean
            // exit(0) and jetsam-kill alike (12:07:43 exit(0) -> GAP 54.0s at 12:07:49;
            // 12:13:58 cpulimit kill -> GAP 53.8s starting 64ms BEFORE the kill log).
            // Departure is the trigger; the manner of death is irrelevant. StikDebug
            // burns its 48s-CPU-per-60s budget in ~52s every single run, so an
            // UNCONTROLLED departure mid-game is guaranteed. Detaching here pays the
            // cost ONCE, at a moment we choose, before anything is on screen.
            //
            // Why it may also be CHEAPER here: on attach the kernel unnests the DYLD
            // shared region in OUR map ("increases system memory footprint until the
            // target exits"), so teardown plausibly scales with VM-map complexity —
            // and right now the map is a fraction of what it becomes under Steam
            // (91 threads / 2512MB). The [early-detach] timing below tests exactly that.
            //
            // Safe NOW and not before: ml522/ml523 made US the task-level Mach handler
            // for bad-access + bad-instruction + breakpoint, so the fault backstop that
            // used to require a live debugger (madeira-jit.js: "NEVER detach here ... every
            // later escalated fault parks its thread forever", the ml345 wedge) is ours.
            // And all executable memory already comes from the pool granted above —
            // virtual_ios.c copies every PE .text into it rather than mprotecting,
            // because iOS/TXM blocks mprotect(PROT_EXEC) outright.
            //
            // ORDERING MATTERS: our task-port claim installs at wine's first thread
            // setup, which is AFTER this point, so this BRK still reaches StikDebug.
            // Flip to false to A/B against the old attached-for-the-whole-run behaviour.
            let earlyDetach = true
            if earlyDetach, pool != nil {
                let dt0 = CFAbsoluteTimeGetCurrent()
                StikJITHelper.detachDebugger()
                let dms = (CFAbsoluteTimeGetCurrent() - dt0) * 1000.0
                logStore.log(String(format: "[early-detach] rev=ml524 took %.0f ms", dms),
                             level: dms > 5000 ? .error : .success)
            } else if !earlyDetach {
                logStore.log("[early-detach] rev=ml524 DISABLED — debugger stays attached all run")
            }

            winios_phase("detach-done")

            // Step 2: Start wineserver
            self.startWineserver()
            winios_phase("wineserver-up")

            // Step 3: Start Wine (debugger still attached for PE loading BRK calls)
            Thread.sleep(forTimeInterval: 2.0)
            winios_phase("wine-start")
            self.startWineProcess()

            // Step 4: Wait for Wine to finish instead of fixed timer
            // Poll wine_process_is_running() — it clears when __wine_main returns
            // For real games this never returns (message loop runs forever), so
            // the cap is what matters. After detach, the dual-mapped JIT pool
            // keeps existing blocks executable; only NEW BRK-based compiles
            // fail.
            //
            // 2026-05-13 first-frame: Thumper splash renders at ~50s but JIT is
            // STILL compiling new FMOD blocks 3M log lines later — audio init
            // is huge (~14k unique RIPs in fmod64.dll alone). Bumped to 300s
            // to let FMOD finish init before debugger detach; otherwise main
            // game loop never engages because Present is gated on audio ready.
            logStore.log("Waiting for Wine to finish PE loading...")
            // 2026-07-03 early detach: attached-mode runs the whole guest
            // ~2x slower (measured 1.2s → 0.74s per present at detach) and
            // on iOS 27 presented frames only reliably reach glass after
            // detach. Post-detach is safe now: trap-mode JIT writes go via
            // the Mach emulator (no debugger), pool pages are pre-executable
            // (dual map), page0 runs once on the first thread, and a
            // post-detach compile was observed working (real_compiles
            // 7093→7094, no faults). So: detach once the game is actually
            // presenting (present #2 = first post-splash frame) plus a
            // settle window, instead of waiting out the full 1200s cap.
            let maxWait = 1200.0  // hard safety cap (unchanged)
            // 2026-07-03 second iteration: detach on present #1 (splash shown)
            // instead of #2. The 3-minute splash-hold is the game loading —
            // running it detached should roughly halve it. Riskier than #2
            // (thousands of load-time compiles + worker-thread spawns happen
            // post-detach) but all known dependencies are covered: trap-mode
            // writes, pre-executable pool, page0 once-guard.
            let settleAfterFirstPresent = 20.0
            var presentingSince: CFAbsoluteTime? = nil
            let pollStart = CFAbsoluteTimeGetCurrent()
            var lastHeartbeat = CFAbsoluteTimeGetCurrent()
            while wine_process_is_running() != 0 {
                Thread.sleep(forTimeInterval: 0.25)
                let now = CFAbsoluteTimeGetCurrent()
                // Diagnostic heartbeat: 2026-07-03's detach-at-#1 run never
                // triggered despite presents visibly counting — log what this
                // loop actually observes so that can't happen silently again.
                if now - lastHeartbeat > 30 {
                    lastHeartbeat = now
                    logStore.log("detach-wait: presents=\(madeira_get_present_count()) running=\(wine_process_is_running()) elapsed=\(Int(now - pollStart))s")
                }
                // Task #25: the present heuristic is meaningless in desktop
                // mode — ANY child presenting (cube, a game window) trips it
                // mid-session, and later program launches still need the
                // attached-debugger facilities. Desktop sessions stay
                // attached until the desktop exits (or the safety cap).
                let isDesktopSession = getenv("MADEIRA_DESKTOP").map { $0.pointee == 49 } ?? false
                if !isDesktopSession {
                    if presentingSince == nil && madeira_get_present_count() >= 1 {
                        presentingSince = now
                        logStore.log("Game is presenting (#1, splash) — early detach in \(Int(settleAfterFirstPresent))s")
                    }
                    if let t = presentingSince, now - t > settleAfterFirstPresent {
                        logStore.log("Early detach: game presenting and settled", level: .success)
                        break
                    }
                }
                if now - pollStart > maxWait {
                    logStore.log("Wine still running after \(Int(maxWait))s, proceeding with detach", level: .error)
                    break
                }
            }
            let wineElapsed = CFAbsoluteTimeGetCurrent() - pollStart
            logStore.log("Wine finished after \(String(format: "%.1f", wineElapsed))s")
            // No program is running any more — the cursor it may have been
            // showing must not survive back into the normal UI.
            winios_cursor_show(0)

            // Step 5: Resume UI + os_log, give main thread time to recover before detach
            DispatchQueue.main.async {
                ws_log_quiet = 0
                logStore.uiPaused = false
            }
            Thread.sleep(forTimeInterval: 2.0)

            // Step 6: Detach debugger — main thread should have zero accumulated hang time
            logStore.log("Detaching debugger...")
            StikJITHelper.detachDebugger()

            // ml: THE OTHER HALF OF THE RELAUNCH GUARD. This is reached on
            // every path out of the poll loop above — a clean guest exit, the
            // maxWait timeout (a boot that hung forever, the exact
            // "detach-wait: presents=0 running=1" case), all of it — so a
            // relaunch is never blocked longer than this cleanup actually
            // takes.
            DispatchQueue.main.async {
                heartbeat.invalidate()
                self.isLaunching = false
                if wine_process_is_running() == 0 { LibraryModel.shared.launchFailed() }
            }
        }
    }

    private func startWineserver() {
        logStore.log("Starting wineserver...")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        logStore.log("Wine prefix: \(winePrefixPath)")

        let result = wineserver_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wineserver thread launched successfully", level: .success)
        } else {
            logStore.log("Failed to start wineserver (error: \(result))", level: .error)
        }
    }

    private func startWineProcess() {
        logStore.log("Starting Wine process...")

        if wineserver_is_running() == 0 {
            logStore.log("Wineserver not running! Start it first.", level: .error)
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let winePrefixPath = documentsPath.appendingPathComponent("wine").path

        // Call synchronously — caller already waited for wineserver to be ready
        let result = wine_process_start(winePrefixPath)
        if result == 0 {
            logStore.log("Wine process thread launched", level: .success)
        } else {
            logStore.log("Failed to start Wine process (error: \(result))", level: .error)
        }
    }

    private func testDualMapping() {
        logStore.log("Testing dual-mapped memory properties...")

        DispatchQueue.global(qos: .userInitiated).async {
            testDualMappingImpl()
        }
    }

    private func testDualMappingImpl() {
        logStore.log("Creating 64KB dual-mapped region...")

        guard let region = jit_region_create(65536) else {
            logStore.log("Failed to create dual-mapped region", level: .error)
            return
        }

        let rwPtr = jit_region_rw_ptr(region)
        let rxPtr = jit_region_rx_ptr(region)
        let size = jit_region_size(region)

        logStore.log("Region created: size=\(size)")
        logStore.log("  RW ptr: \(String(format: "%p", Int(bitPattern: rwPtr)))")
        logStore.log("  RX ptr: \(String(format: "%p", Int(bitPattern: rxPtr)))")

        // Test 1: Write to RW, verify readable from RX
        let testPattern: UInt32 = 0xDEADBEEF
        rwPtr?.assumingMemoryBound(to: UInt32.self).pointee = testPattern
        let readBack = rxPtr?.assumingMemoryBound(to: UInt32.self).pointee

        if readBack == testPattern {
            logStore.log("Dual mapping verified: write to RW visible from RX", level: .success)
        } else {
            logStore.log("Dual mapping FAILED: wrote \(String(format: "0x%X", testPattern)), read \(String(format: "0x%X", readBack ?? 0))", level: .error)
        }

        // Test 2: Verify RW and RX are at different virtual addresses
        if rwPtr != rxPtr {
            logStore.log("Distinct virtual addresses confirmed (RW != RX)", level: .success)
        } else {
            logStore.log("WARNING: RW and RX are at the same address", level: .error)
        }

        jit_region_destroy(region)
        logStore.log("Region destroyed. Dual mapping test complete.")
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    guideRow(
                        icon: "cpu",
                        title: "JIT Compilation",
                        detail: "Required for x86 code translation. On iOS 26, StikDebug must stay attached — assign the 'universal' or 'MeloNX' JIT script to Madeira in StikDebug."
                    )
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "Expands virtual address space to ~64GB. Required for large games. Must be injected via GetMoreRam (free accounts can't provision this)."
                    )
                }

                Section("Setup Steps") {
                    stepRow(number: 1, text: "Install Madeira via SideStore or Xcode")
                    stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                    stepRow(number: 3, text: "Reinstall Madeira with the same IPA to apply injected entitlements")
                    stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to Madeira and launch it")
                    stepRow(number: 5, text: "Launch Madeira and tap 'Test JIT' to verify")
                }

                Section("About") {
                    Text("Madeira is a proof-of-concept for running x86 Windows games on iOS using FEX-Emu, Wine, and Metal-based graphics translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// ml668 — A PHYSICAL CONTROLLER BUTTON, as a landscape control can be bound
/// to one.
///
/// Deliberately NOT `ControlAction.pad(String)`. That case says "this
/// on-screen button DRAWS an Xbox glyph", which was never wired to anything.
/// This says "this on-screen control is ALSO pressed by that physical button",
/// which is a second, orthogonal property of the same control: the control
/// keeps posting its own keys or mouse buttons, and the pad is a second finger
/// on it rather than a different action.
///
/// WHY THE LAYER EXISTS AT ALL, given that XInput now works. Most of the
/// software this port runs predates XInput and reads the keyboard and the
/// mouse, full stop. A controller is useless to those titles unless something
/// turns its buttons into the keys they do read — which is exactly what the
/// landscape control layout already does for a thumb. Binding the pad to the
/// SAME controls reuses the user's own mapping instead of inventing a second
/// one, and it is also what a PC with a controller and a key remapper does:
/// XInput and the remapper both see every button, at the same time, and that
/// is not a conflict.
///
/// Raw-value Codable so the layout JSON stores a NAME and not an ordinal:
/// inserting a button in the middle of this enum must not silently rebind
/// every layout already on disk.
enum PadButton: String, Codable, CaseIterable, Hashable, Identifiable {
    case a, b, x, y
    case lb, rb, lt, rt
    case l3, r3
    case start, back
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftStick, rightStick

    var id: String { rawValue }

    /// The XINPUT_GAMEPAD_* bit this button reports in, or 0 for the two
    /// analogue sticks (which are not buttons and have no bit).
    var mask: UInt16 {
        switch self {
        case .a:          return 0x1000
        case .b:          return 0x2000
        case .x:          return 0x4000
        case .y:          return 0x8000
        case .lb:         return 0x0100
        case .rb:         return 0x0200
        case .l3:         return 0x0040
        case .r3:         return 0x0080
        case .start:      return 0x0010
        case .back:       return 0x0020
        case .dpadUp:     return 0x0001
        case .dpadDown:   return 0x0002
        case .dpadLeft:   return 0x0004
        case .dpadRight:  return 0x0008
        // The triggers are ANALOGUE and have no XInput button bit at all. A
        // control bound to one is pressed past a threshold — see
        // HardwareInput.padPressed.
        case .lt, .rt:    return 0
        case .leftStick, .rightStick: return 0
        }
    }

    var isStick: Bool { self == .leftStick || self == .rightStick }
    var isTrigger: Bool { self == .lt || self == .rt }

    var label: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .lt: return "LT"
        case .rt: return "RT"
        case .l3: return "L3"
        case .r3: return "R3"
        case .start: return "Start"
        case .back: return "Back"
        case .dpadUp: return "D↑"
        case .dpadDown: return "D↓"
        case .dpadLeft: return "D←"
        case .dpadRight: return "D→"
        case .leftStick: return "L-stick"
        case .rightStick: return "R-stick"
        }
    }

    // ========================================================================
    // ml670 — HOW A VIRTUAL ONE OF THESE IS DRAWN.
    //
    // Put on the button and not in the view because the shape IS part of the
    // button's identity: a rounded rect says "shoulder", a capsule says
    // "system", a coloured circle says "face". A user who has ever held a
    // controller reads the layout without reading a single label, and the view
    // then has one switch instead of four.
    // ========================================================================

    /// Xbox face colours. Everything else is uncoloured — a wash of tint on
    /// every button would make the four that MEAN something unreadable.
    var tint: Color? {
        switch self {
        case .a: return Color(red: 0.36, green: 0.76, blue: 0.30)
        case .b: return Color(red: 0.88, green: 0.28, blue: 0.24)
        case .x: return Color(red: 0.24, green: 0.53, blue: 0.92)
        case .y: return Color(red: 0.96, green: 0.76, blue: 0.16)
        default: return nil
        }
    }

    /// SF Symbol drawn instead of a label, for the four D-pad directions.
    var glyph: String? {
        switch self {
        case .dpadUp:    return "arrowtriangle.up.fill"
        case .dpadDown:  return "arrowtriangle.down.fill"
        case .dpadLeft:  return "arrowtriangle.left.fill"
        case .dpadRight: return "arrowtriangle.right.fill"
        default: return nil
        }
    }

    /// The label drawn ON the control, which is not always the label used in
    /// the chip: "Start"/"Back" become small caps in a capsule.
    var faceLabel: String {
        switch self {
        case .start: return "START"
        case .back:  return "BACK"
        default:     return label
        }
    }

    enum Face { case round, wide, capsule, small, stick }

    var face: Face {
        switch self {
        case .a, .b, .x, .y:                             return .round
        case .lb, .rb, .lt, .rt:                         return .wide
        case .start, .back:                              return .capsule
        case .l3, .r3:                                   return .small
        case .leftStick, .rightStick:                    return .stick
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:  return .round
        }
    }

    /// Drawn size, given the layout's base diameter for a round button.
    func size(diameter d: CGFloat) -> CGSize {
        switch face {
        case .round, .stick: return CGSize(width: d, height: d)
        case .wide:          return CGSize(width: d * 1.50, height: d * 0.66)
        case .capsule:       return CGSize(width: d * 0.70, height: d * 0.35)
        case .small:         return CGSize(width: d * 0.72, height: d * 0.72)
        }
    }

    /// Round controls hit-test as circles so neighbouring ones cannot steal
    /// each other's corners; the oblong ones must not.
    var circularHit: Bool {
        switch face {
        case .round, .small, .stick: return true
        case .wide, .capsule:        return false
        }
    }
}

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case joystickMouse       // ml660: renders as a stick, posts relative mouse motion
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml645: Xbox button. NEVER WIRED — see below.

    // ml670 — THE VIRTUAL CONTROLLER, as an action.
    //
    // WHY A NEW CASE AND NOT A REVIVAL OF `.pad(String)`. That case carried a
    // free-form STRING, which is why it could never be wired: nothing could
    // turn "A" into an XInput bit without a lookup that would silently miss on
    // any spelling nobody thought of, and a layout on disk could name a button
    // that does not exist. `PadButton` is the closed set, it already owns the
    // `mask`, and it is already raw-value Codable. `.pad` stays only so a
    // layout saved before this build still DECODES; it draws dimmed, hit-tests
    // as `.inert`, and the panel migrates it on the first tap.
    case gamepad(PadButton)
    /// One cross-shaped control carrying all four D-pad directions. Not a
    /// `PadButton` — there is no such physical button; it is four of them.
    case gamepadDPad

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    /// ml660: the aim stick drives no keys at all, so `stickKeys` cannot
    /// identify it — but it must still LOOK and hit-test like a stick.
    var isMouseStick: Bool { self == .joystickMouse }
    /// ml: `.joystickWASD` and `.joystickArrows` are THE SAME control (both
    /// go through `.dirStick` with an identical deadzone/snap — see
    /// `regionKind` below), told apart only by which four keys `stickKeys`
    /// names. Before this they were also visually IDENTICAL — `stickGlyph`
    /// only ever covered the aim stick, so two sticks added from "Pointer,
    /// sticks & special" with different key sets drew the exact same idle
    /// ring, and a user could not tell WASD from Arrows without pressing
    /// one. See ContentView's Tasks doc: "same visuals apart from a small
    /// label/glyph so they can be told apart."
    /// ml670: the `PadButton` this control IS, if it is a virtual controller
    /// button. nil for every keyboard/mouse control and for the D-pad cross,
    /// which is four buttons and not one.
    var padButton: PadButton? { if case .gamepad(let b) = self { return b }; return nil }
    var isGamepad: Bool {
        if case .gamepad = self { return true }
        return self == .gamepadDPad
    }
    var isStick: Bool { stickKeys != nil || isMouseStick || padButton?.isStick == true }
    /// ml660: SF Symbol drawn in the face, distinguishing sticks from each
    /// other — every stick now gets one (see the doc comment above), since
    /// the key sticks' actual on-screen label goes undrawn (the stick FACE
    /// is what `TouchControlButton` renders for `isStick`, never the
    /// `Text(control.action.label)` branch — see its `body`).
    var stickGlyph: String? {
        switch self {
        case .joystickMouse:  return "scope"
        case .joystickWASD:   return "keyboard"
        case .joystickArrows: return "arrow.up.and.down.and.arrow.left.and.right"
        default:              return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .joystickMouse:   return "AIM"
        case .pad(let n):      return n
        case .gamepad(let b):  return b.label
        case .gamepadDPad:     return "D-pad"
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// ml670 — the DRAWN size of this control, and whether its hit region is a
    /// circle. Everything that used to assume "one round button, `baseDiameter`
    /// across" goes through here now, because a shoulder button is oblong and a
    /// Start capsule is small, and the touch region has to be the SAME rect the
    /// user sees or the control is dead exactly where it looks alive.
    func controlSize(diameter d: CGFloat) -> CGSize {
        if let b = padButton { return b.size(diameter: d) }
        if self == .gamepadDPad { return CGSize(width: d * 1.55, height: d * 1.55) }
        return CGSize(width: d, height: d)
    }
    var circularHit: Bool {
        if let b = padButton { return b.circularHit }
        // The cross's four diagonals live in the CORNERS of its square, which a
        // circular hit test is precisely what would cut off.
        if self == .gamepadDPad { return false }
        return true
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created

    /// ml668 — the physical controller button that also presses this control,
    /// if any. Optional and defaulted, so the synthesised `Codable` decodes a
    /// layout written before this field existed (`decodeIfPresent` for an
    /// Optional) and every stored layout keeps working untouched.
    var padBinding: PadButton? = nil

    /// The id this control's hit region is registered under in
    /// `ControlOverlayView`. Derived, never stored — the UUID already IS the
    /// identity, and this is only the short form the touch layer keys on.
    /// `TouchControlButton.init` builds its region with this same property, so
    /// a physical button and a thumb address one region and cannot drift.
    var regionID: String { "ctl." + id.uuidString.prefix(8) }
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = true               { didSet { save() } }
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    /// ml670 — ONE SIZE KNOB FOR THE WHOLE LAYOUT, 0.5…2.0.
    ///
    /// The pinch that already exists scales ONE control, which is the right
    /// tool for "this button is too small" and the wrong one for "everything is
    /// too small on this phone" — a user with a dozen controls would have to
    /// pinch each one and would not get them consistent. This multiplies every
    /// control's own `scale`, so the two compose: a deliberately-huge stick
    /// stays proportionally huge when the whole layout shrinks.
    ///
    /// Global rather than per-orientation because the layout itself is global:
    /// there is one `controls` array and it is landscape-only.
    @Published var sizeScale: Double = 1.0      { didSet { save() } }

    /// THE one place a control's drawn diameter is computed. Every caller —
    /// the view, the mapping panel's placement, the physical-pad binding path —
    /// goes through it, or the touch region and the pixels drift apart the
    /// first time the slider moves.
    static func diameter(_ c: TouchControl) -> CGFloat {
        baseDiameter * CGFloat(c.scale) * CGFloat(shared.sizeScale)
    }

    /// The HUD cluster's (controller/pencil buttons, TouchControlsOverlay.
    /// topBar) actual on-screen frame, in the same window coordinate space
    /// `ControlsWindow.hitTest` runs in — published every render via a
    /// GeometryReader background, same trick as `HardwareInput.hintRect`.
    /// Replaces a fixed top-center guess now that the cluster is draggable
    /// (ml? movable HUD). `.zero` until the first layout pass lands, so
    /// `hitsInteractive` keeps its old fixed-rect guess as a fallback until
    /// then.
    var hudClusterRect: CGRect = .zero

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    /// `sizeScale` is OPTIONAL, not defaulted. The synthesised decoder uses
    /// `decodeIfPresent` only for Optionals — a non-optional with a default
    /// value still THROWS on a missing key, which would make every layout
    /// written before this build fail to decode and silently reset to empty.
    /// Same reasoning, and the same shape, as `TouchControl.padBinding`.
    private struct Saved: Codable {
        var controls: [TouchControl]
        var visible: Bool
        var sizeScale: Double?
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = s.visible
            sizeScale = min(max(s.sizeScale ?? 1.0, 0.5), 2.0)
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(
            Saved(controls: controls, visible: visible, sizeScale: sizeScale))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on SwiftUI chrome?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    ///
    /// ml662: this used to include the controls themselves. It must not any
    /// more — the controls are regions in ControlOverlayView, which gets first
    /// refusal on every point, and letting a control's circle also route to
    /// SwiftUI would put a gesture recogniser back under the thumb. What is
    /// left is the chrome that is genuinely a tap on a button: the top bar.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        // ml — Task 1 (fullscreen cursor investigation): USED TO fall back to
        // a guessed top-center rectangle here, before topBar's GeometryReader
        // had published a real measurement. A guess can be WRONG for a given
        // device/orientation/dragged-cluster position, and being wrong here
        // means claiming screen space that is not actually the HUD — which
        // silently steals that area from the live view for as long as the
        // guess stays in effect. The rule this function exists to enforce is
        // the other way round: when we do not POSITIVELY know a point is
        // under a control, the live view wins. `hudClusterRect` is published
        // on the very first render (topBar always renders while fullscreen
        // is active, and publishes unconditionally), so the window this
        // trades away is at most the first frame or two right after
        // entering fullscreen — a possibly-ignored HUD tap, never a
        // possibly-swallowed game-area touch.
        guard hudClusterRect != .zero else { return false }
        // The cluster can be dragged anywhere in the safe area and its
        // button count varies (mouse-lock, "+" in edit mode), so hit-test the
        // MEASURED frame instead of a fixed guess — padded enough to keep
        // 44pt buttons reachable without ballooning into a blob that reads
        // as "empty space" to the user.
        return hudClusterRect.insetBy(dx: -8, dy: -8).contains(p)
    }
}

/// ml — THE SIZE TO GIVE A WINDOW-LEVEL OVERLAY, root-caused from a device
/// report: app launched STRAIGHT INTO landscape (wide normal view) had a dead
/// toolbar joystick and a key row that scrolled instead of pressing — i.e. the
/// touch layer was not there to claim those touches at all — while portrait
/// launches, and landscape reached by rotating or by a fullscreen round trip,
/// worked. The log line `TouchControlsHost.attach` already prints
/// (`[controls] ml644 overlay attached frame=...`) showed exactly this on a
/// cold landscape launch: the FIRST call recorded a portrait-shaped frame
/// (402×874 on that device) and only a LATER call — triggered by entering/
/// leaving fullscreen — recorded the correct 874×402.
///
/// `scene.coordinateSpace.bounds` is the culprit: on a cold launch directly
/// into a non-default interface orientation, it can still report the
/// pre-rotation "reference" size for the first render pass or two, before
/// the scene's own interface-orientation transform has landed — with nothing
/// to correct it afterward, because `UIDevice.orientationDidChangeNotification`
/// (the only other thing that re-runs `attach()`) fires on an actual
/// *change*, and a device that was ALREADY landscape before launch never
/// produces one. A portrait launch never hits this because the stale first
/// reading and the true one happen to agree.
///
/// SwiftUI's own `.global` coordinate space — the space every `ControlRegion`
/// registers its frame in — does NOT have this problem: by the time any
/// `.onAppear` fires, SwiftUI has already completed a layout pass against the
/// app's real key window, which is how `ContentView.body`'s own `geo.size`
/// check picks `wideNormalBody` correctly on that same cold launch. Sourcing
/// this window's frame from THAT window instead of the scene's separate
/// coordinate space ties both to the same ground truth by construction, so
/// they cannot disagree — not even for one frame.
func controlOverlayWindowBounds(in scene: UIWindowScene) -> CGRect {
    // Second fallback deliberately excludes our OWN overlay windows
    // (ControlsWindow, JoystickPadHost's PassthroughWindow) — neither is ever
    // made key, but by the time this runs both may already be in
    // `scene.windows`, and picking one of them here would just reproduce the
    // exact "measuring the wrong window" bug this function exists to end.
    let size = scene.windows.first(where: { $0.isKeyWindow })?.bounds.size
        ?? scene.windows.first(where: { !($0 is ControlsWindow) && !($0 is PassthroughWindow) })?.bounds.size
        ?? scene.coordinateSpace.bounds.size
    return CGRect(origin: .zero, size: size)
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    /// ml — Task 1: one capped log line whenever this window consumes a
    /// fullscreen touch instead of letting it fall through to the live view.
    /// A device report of "the cursor does nothing in fullscreen" is
    /// otherwise indistinguishable from "the touch reached MetalBackedView
    /// and was mishandled there" — this line says definitively that the
    /// touch never left THIS window, and why. Capped at 40 for the same
    /// reason `ControlOverlayView.logRegistration` is: useful right after
    /// the report reproduces, useless as an unbounded flood.
    private static var refusedLogged = 0
    private static func logRefusal(_ reason: String, _ p: CGPoint) {
        guard refusedLogged < 40 else { return }
        refusedLogged += 1
        fputs(String(format: "[controls] ml refused game-area touch at (%.0f,%.0f) reason=%@\n",
                     p.x, p.y, reason), stderr)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if FullscreenState.shared.active, LibraryModel.shared.current != nil {
            let library = LibraryModel.shared
            if library.menu || library.launching || library.menuButtonRect.contains(point) ||
                (library.performance && library.performanceRect.contains(point)) {
                return super.hitTest(point, with: event)
            }
        }
        let m = TouchControlsModel.shared
        // ml662: the UIKit touch layer gets first refusal in EVERY body — the
        // key row (portraitBody/wideNormalBody) registers its frames here
        // too, so this window is not fullscreen-only. `region(at:)` already
        // returns nil in edit mode, so the edit-mode branch below still wins
        // there.
        let ov = ControlOverlayView.shared
        if ov.window === self, ov.region(at: convert(point, to: ov)) != nil { return ov }
        if LibraryModel.shared.current != nil && !m.editing { return nil }
        // ml665: the AssistiveTouch hint banner lives in this window's hosting
        // view, and the guard below hands everything outside a control region
        // straight through in the normal view — which would make the
        // banner's dismiss button untappable. Its published rect is the one
        // exception, in every body.
        if HardwareInput.shared.assistiveTouchHint,
           HardwareInput.hintRect.contains(point) {
            return super.hitTest(point, with: event)
        }
        // ml: THE STALE-EDIT-MODE FIX.
        //
        // `m.editing` used to gate this branch alone: true claims the WHOLE
        // screen unconditionally (TouchControlsOverlay's body applies
        // `.contentShape(Rectangle()).gesture(scalePinch)` across its full
        // bounds, so once hitTest forwards here there is nothing left for
        // the normal view underneath to receive). Edit mode is only ever
        // ENTERED from the HUD cluster's pencil button, which only exists in
        // fullscreen — but nothing used to CLEAR it when fullscreen ended, so
        // a user who opened edit mode, then rotated away or exited
        // fullscreen without tapping the checkmark first, got every future
        // tap — including the launch row's — silently swallowed here. That
        // is the "pressing a launch button does nothing, hit or miss"
        // report: whether it reproduced depended entirely on edit-mode
        // history. FullscreenState.active's didSet now force-clears
        // `editing` the moment fullscreen ends (belt), and this guard makes
        // sure a stale `true` can never matter outside fullscreen even if
        // that ever raced (suspenders).
        guard FullscreenState.shared.active else { return nil }
        // Edit mode owns the whole (fullscreen) screen: drags and the scale
        // pinch must not leak through and swing the camera while you are
        // arranging buttons.
        if m.editing {
            Self.logRefusal("editing", point)
            return super.hitTest(point, with: event)
        }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        Self.logRefusal("hud-cluster", point)
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = false        // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        guard let w = window else { return }
        // ml — was `scene.coordinateSpace.bounds`; see `controlOverlayWindowBounds`'s
        // doc comment for the cold-landscape-launch bug that traced to it.
        w.frame = controlOverlayWindowBounds(in: scene)

        // ml662 — THE TOUCH LAYER, as a WINDOW subview rather than a subview of
        // the hosting view.
        //
        // It has to be above the SwiftUI hosting view and it has to stay there.
        // A hosting view rebuilds its own subtree whenever the SwiftUI body
        // changes, so anything parented inside it can be reordered underneath;
        // a UIWindow does not reorder the subviews you add to it. Same argument
        // as the one that put the pad in its own window in the first place.
        //
        // This is also the ONLY window-level input surface in the app, which is
        // what makes rule 3 hold: a touch that misses every region is hit-tested
        // to nil here and again in the pad's PassthroughWindow, and lands on the
        // live view in the app window — a different view, so UIKit delivers the
        // two independently and neither can cancel the other.
        let ov = ControlOverlayView.shared
        if ov.superview !== w { ov.removeFromSuperview(); w.addSubview(ov) }
        w.bringSubviewToFront(ov)
        ov.frame = w.bounds
        ov.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The overlay's own window must not hand a control's touch to the
        // pinch-to-scale recogniser SwiftUI installed on the hosting view.
        w.rootViewController?.view.gestureRecognizers?.forEach {
            $0.cancelsTouchesInView = false
            $0.delaysTouchesBegan = false
            $0.delaysTouchesEnded = false
        }
        fputs("[controls] ml644 overlay attached frame=\(w.frame) " +
              "controls=\(TouchControlsModel.shared.controls.count) " +
              "touchlayer=\(ov.frame)\n", stderr)
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var m = TouchControlsModel.shared
    @ObservedObject private var hw = HardwareInput.shared
    /// ml: re-keyed from a local `geo.size.width > geo.size.height` read to
    /// the shared mode flag — see FullscreenState's doc comment. The cluster
    /// and on-screen controls now show/hide with fullscreen, not with device
    /// shape, so a portrait fullscreen gets them too and a wide NORMAL-view
    /// landscape (live view + launch row + logs, side by side) does not try
    /// to show them over chrome that isn't there.
    @ObservedObject private var fullscreenState = FullscreenState.shared
    @State private var pinchBase: Double?
    /// Live drag delta for the HUD cluster (controller/pencil buttons); only
    /// non-zero while a long-press-drag on its grip is in progress. The
    /// settled position lives in InputSettings, one slot per landscape
    /// rotation — see hudBaseCenter/commitHudDrag below.
    @GestureState private var hudDragState: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fullscreen = fullscreenState.active
            ZStack(alignment: .top) {
                if fullscreen {
                    if (m.visible || m.editing) && !library.blocksGameplayTouch {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                                .opacity(library.current != nil && !m.editing ? library.opacity : 1)
                        }
                    }
                    if library.current != nil && !m.editing { LibraryHUD() }
                    else { topBar(in: geo) }
                    // ml670: edit mode only. In play mode there is nothing to
                    // adjust and a slider under the thumb would be a control
                    // that eats a press.
                    if m.editing { sizeBar(in: geo) }
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
                // ml665: OUTSIDE the fullscreen branch. A mouse that
                // enumerates and never reports is exactly as broken in the
                // normal view, and this window is the only surface that is
                // above the game in every body.
                if hw.assistiveTouchHint { assistiveTouchBanner(fullscreen: fullscreen) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch)
        }
        .ignoresSafeArea()
    }

    /// ml665 — the one thing the app cannot do for the user.
    ///
    /// iPhone routes every pointer device through AssistiveTouch; there is no
    /// public HID path and `prefersPointerLocked` is an iPad API. So when a
    /// mouse enumerates and ten seconds pass with no GCMouse delta, the ONLY
    /// useful thing to show is the exact settings path. Raised once per session
    /// (HardwareInput.armAssistiveTouchHint), cleared by the first delta, and
    /// dismissable — its rect is published to `HardwareInput.hintRect` so
    /// `ControlsWindow.hitTest` lets the dismiss button through in the normal
    /// view, where that window deliberately consumes nothing else.
    private func assistiveTouchBanner(fullscreen: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "computermouse")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
            Text("Mouse detected. iPhone needs AssistiveTouch: "
                 + "Settings > Accessibility > Touch > AssistiveTouch > On, then Devices")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                HardwareInput.shared.dismissAssistiveTouchHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(GlassShape())
        .padding(.horizontal, 12)
        // Fullscreen puts topBar at the top of this same window; sit under it.
        .padding(.top, fullscreen ? 62 : 8)
        .background(GeometryReader { g -> Color in
            // Window coords: this window is full-screen, so .global is its own
            // coordinate space. Published rather than recomputed in hitTest
            // because hitTest has no access to SwiftUI layout.
            let f = g.frame(in: .global)
            DispatchQueue.main.async { HardwareInput.hintRect = f }
            return Color.clear
        })
        .transition(.opacity)
    }

    /// Movable HUD cluster. Anchored top-center by default, same as before,
    /// but a long-press-then-drag on its grip repositions it anywhere inside
    /// the safe area and the drop point persists per landscape rotation
    /// (InputSettings.hudPosLandscapeLeft/Right, same JSON file as the other
    /// input settings) so it comes back where it was left. The buttons
    /// themselves stay plain taps — only the grip carries the drag gesture,
    /// so there is no ambiguity with tapping gamecontroller/pencil/plus.
    private func topBar(in geo: GeometryProxy) -> some View {
        let center = hudBaseCenter(in: geo)
        return HStack(spacing: 10) {
            hudGrip(in: geo)
            // ml: THE WAY OUT. Third button in the same movable cluster —
            // simplest option that satisfies both "draggable, same
            // implementation as the rest of the cluster" and "never ends up
            // off-screen after a rotation" for free, since it rides the
            // cluster's own clamped, persisted position (hudBaseCenter/
            // commitHudDrag below) rather than needing a second one of its
            // own. A tap exits; only the grip drags.
            glassButton("arrow.down.right.and.arrow.up.left") {
                if library.current != nil { m.editing = false; library.showMenu() }
                else { fullscreenState.active = false }
            }
            glassButton("gamecontroller", dim: !m.visible) { m.visible.toggle() }
            // ml663: landscape is where a keyboard and mouse are actually used,
            // so the escape hatch from pointer lock has to be reachable HERE —
            // by touch, which pointer lock does not affect. (Ctrl+Alt+P does the
            // same thing without leaving the keyboard.)
            // ml665: and not at all on iPhone, where `prefersPointerLocked` is
            // inert — the cursor on screen is AssistiveTouch's, not UIKit's.
            if hw.mouseConnected && HardwareInput.pointerLockAvailable {
                // ml664: three states, not two. Locked; unlocked on the raw HID
                // path (lock is available and useful); unlocked on the UIKit
                // path (lock is refused — it would stop pointer delivery). The
                // glyph distinguishes them so "the button does nothing" is never
                // the only symptom.
                glassButton(hw.pointerLocked ? "cursorarrow.slash"
                            : hw.mousePath == .uikit ? "cursorarrow.click.badge.clock"
                            : "cursorarrow.motionlines",
                            dim: !hw.pointerLocked) {
                    HardwareInput.shared.togglePointerLock()
                }
            }
            glassButton(m.editing ? "checkmark" : "pencil") {
                m.editing.toggle()
                if !m.editing { m.selected = nil }
            }
            if m.editing {
                glassButton("plus") {
                    var c = TouchControl()
                    // Stagger, so repeated adds do not stack invisibly.
                    c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                    c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                    m.controls.append(c)
                    m.selected = c.id
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
        .position(x: center.x + hudDragState.width, y: center.y + hudDragState.height)
        .background(GeometryReader { g -> Color in
            // Window coords, same trick (and the same reason) as
            // HardwareInput.hintRect above: ControlsWindow.hitTest has no
            // access to SwiftUI layout, so the measured frame is published
            // here for it to read.
            let f = g.frame(in: .global)
            DispatchQueue.main.async { m.hudClusterRect = f }
            return Color.clear
        })
    }

    /// ml670 — THE LAYOUT-WIDE SIZE SLIDER.
    ///
    /// Rides next to the HUD cluster, so it follows the cluster wherever the
    /// user has dragged it and never has to be hunted for. It is safe to put a
    /// SwiftUI gesture here and nowhere else: while `editing` is set,
    /// `ControlsWindow.hitTest` hands the whole screen to the hosting view and
    /// `ControlOverlayView.region(at:)` returns nil, so the touch layer is
    /// standing down and there is nothing for the slider to fight with.
    ///
    /// It multiplies rather than replaces each control's own pinch scale — see
    /// `TouchControlsModel.sizeScale`.
    ///
    /// ml — WAS a fixed "+48pt below the cluster's UN-dragged base, clamped to
    /// the screen's bottom edge". That clamp is exactly the reported "slider
    /// drawn on top of the cluster" bug: drag the cluster down near the
    /// bottom edge (device feedback did — see the fullscreen edit-mode
    /// screenshot) and there is no longer 48pt of room below it, so the
    /// clamp pulled the bar back UP onto the buttons instead of trying the
    /// other side. Fixed by reading `m.hudClusterRect` — the cluster's own
    /// LIVE measured rect, published by topBar's GeometryReader in the same
    /// window coordinate space this view's `.position()` already uses —
    /// instead of re-deriving an approximate position independently (which
    /// also could not know the cluster's actual height: the pointer-lock and
    /// + buttons are conditional, so the cluster is not always the same
    /// size). Below when there is room, above otherwise — holds for a
    /// cluster dragged to any edge, and for portrait fullscreen, since
    /// nothing here assumes a landscape shape any more.
    private func sizeBar(in geo: GeometryProxy) -> some View {
        let w: CGFloat = min(300, geo.size.width - 40)
        let barHeight: CGFloat = 46
        let gap: CGFloat = 10
        let cluster = m.hudClusterRect
        let hasCluster = cluster != .zero
        let spaceBelow = hasCluster
            ? geo.size.height - geo.safeAreaInsets.bottom - cluster.maxY : 0
        let placeBelow = !hasCluster || spaceBelow >= barHeight + gap
        let targetX = hasCluster ? cluster.midX : geo.size.width / 2
        let targetY: CGFloat
        if hasCluster {
            targetY = placeBelow ? cluster.maxY + gap + barHeight / 2
                                  : cluster.minY - gap - barHeight / 2
        } else {
            // Cold-start fallback: hudClusterRect's first publish is
            // dispatched async from topBar, so a sizeBar that somehow
            // renders before that lands (editing flips true on the very
            // first frame) has nothing measured to key off yet. Matches the
            // old fixed offset from the cluster's un-dragged top-center spot.
            targetY = hudBaseCenter(in: geo).y + 48
        }
        return HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
            Slider(value: $m.sizeScale, in: 0.5...2.0)
                .tint(.white.opacity(0.85))
            Text("\(Int((m.sizeScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: w)
        .background(GlassShape())
        .position(x: min(max(targetX, w / 2 + 8), geo.size.width - w / 2 - 8),
                  y: min(max(targetY, barHeight / 2 + 8),
                         geo.size.height - barHeight / 2 - 8))
    }

    /// Small drag handle, leading edge of the cluster. A LongPressGesture
    /// gate (0.3s + haptic) before the DragGesture, rather than a bare drag
    /// on the whole cluster, keeps a plain tap on gamecontroller/pencil/plus
    /// completely unambiguous — only this handle ever starts a move.
    private func hudGrip(in geo: GeometryProxy) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 24, height: 44)
            .contentShape(Rectangle())
            .gesture(hudDragGesture(in: geo))
    }

    /// `.global`, not the default `.local`, and that is load-bearing: `.local`
    /// measures translation against the GRIP'S OWN frame, and that frame moves
    /// every time `hudDragState` moves the cluster via `.position()` below —
    /// translation-fed-back-into-the-thing-that-defines-translation is a
    /// textbook feedback loop and is exactly what made the drag jittery. In
    /// `.global` (window) space the origin never moves regardless of what the
    /// gesture itself does to the view, so `start + translation` stays a
    /// simple, stable sum for the whole gesture.
    private func hudDragGesture(in geo: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($hudDragState) { value, state, _ in
                if case .second(true, let drag?) = value {
                    state = drag.translation
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                commitHudDrag(translation: drag.translation, in: geo)
            }
    }

    /// UIDevice.current.orientation, not geo's width/height compare: the two
    /// landscape rotations put the notch/home-indicator on opposite sides, so
    /// they need their own saved spot even though both are "landscape." This
    /// is purely a cosmetic drop-point memory, not what decides whether the
    /// cluster shows (that's FullscreenState) — so orientation's iPad
    /// unreliability doesn't bite here the way it would for that decision. A
    /// portrait fullscreen (now possible — see FullscreenState) shares the
    /// "left" slot by default, same as anything that isn't clearly
    /// landscapeRight; `hudBaseCenter`/`commitHudDrag` below always clamp
    /// into the CURRENT safe area regardless, so a stale/shared slot can
    /// never place the cluster off-screen, only in a slightly generic spot.
    private var isLandscapeRight: Bool { UIDevice.current.orientation == .landscapeRight }

    /// The cluster's un-dragged center: the saved drop point for this
    /// rotation if there is one, else the original top-center spot.
    private func hudBaseCenter(in geo: GeometryProxy) -> CGPoint {
        let saved = isLandscapeRight ? InputSettings.shared.hudPosLandscapeRight
                                      : InputSettings.shared.hudPosLandscapeLeft
        if let n = saved {
            return CGPoint(x: n.x * geo.size.width, y: n.y * geo.size.height)
        }
        // Matches the pre-drag layout: horizontally centered, ~10pt (padding)
        // + half the 44pt button height below the top edge.
        return CGPoint(x: geo.size.width / 2, y: geo.safeAreaInsets.top + 32)
    }

    /// Drops the cluster where the drag ended, clamped so it (approximately —
    /// button count varies) stays inside the safe area, and persists the
    /// fractional position for this rotation.
    private func commitHudDrag(translation: CGSize, in geo: GeometryProxy) {
        let base = hudBaseCenter(in: geo)
        var center = CGPoint(x: base.x + translation.width, y: base.y + translation.height)
        let halfW: CGFloat = 90, halfH: CGFloat = 30
        let minX = geo.safeAreaInsets.leading + halfW
        let maxX = max(minX, geo.size.width - geo.safeAreaInsets.trailing - halfW)
        let minY = geo.safeAreaInsets.top + halfH
        let maxY = max(minY, geo.size.height - geo.safeAreaInsets.bottom - halfH)
        center.x = min(max(center.x, minX), maxX)
        center.y = min(max(center.y, minY), maxY)
        guard geo.size.width > 0, geo.size.height > 0 else { return }
        let normalized = CGPoint(x: center.x / geo.size.width, y: center.y / geo.size.height)
        if isLandscapeRight { InputSettings.shared.hudPosLandscapeRight = normalized }
        else { InputSettings.shared.hudPosLandscapeLeft = normalized }
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Device feedback (2026-09-15): every HUD button logs its tap now,
            // so a report of "nothing happened" is distinguishable from "the
            // tap never reached SwiftUI" by whether this line shows up.
            fputs("[hud] tap \(system)\n", stderr)
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(GlassShape(circle: true))
        }
        .buttonStyle(.plain)
    }
}

/// Shared glass backing, with the pre-26 fallback the codebase already uses.
struct GlassShape: View {
    var circle = false
    var body: some View {
        if #available(iOS 26.0, *) {
            if circle { Circle().fill(.clear).glassEffect(.regular, in: Circle()) }
            else { RoundedRectangle(cornerRadius: 18).fill(.clear)
                     .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18)) }
        } else {
            if circle { Circle().fill(.ultraThinMaterial) }
            else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
        }
    }
}

/// ml662: what this control DOES while a finger is on it, as a touch-layer
/// region. Deadzone and travel scale with the pinched diameter, exactly as the
/// old in-view versions did, so a stick you made bigger still needs a
/// proportionally bigger thumb throw.
extension ControlAction {
    func regionKind(diameter: CGFloat) -> ControlRegionKind {
        switch self {
        case .none, .pad:      return .inert
        case .key(let vk):     return .keys([vk])
        case .mouseLeft:       return .buttons([0])
        case .mouseRight:      return .buttons([1])
        case .keyboardToggle:  return .keyboardToggle
        case .joystickWASD, .joystickArrows:
            return .dirStick(quad: stickKeys ?? [], deadzone: diameter * 0.22)
        case .joystickMouse:
            return .aimStick(deadzone: diameter * 0.12, travel: diameter * 0.55)
        // ml670: deadzone and travel scale with the DRAWN size exactly as the
        // keyboard sticks' do, so a stick made bigger by the size slider still
        // wants a proportionally bigger thumb throw.
        case .gamepad(let b):
            if b.isStick {
                return .padStick(right: b == .rightStick,
                                 deadzone: diameter * 0.12, travel: diameter * 0.42)
            }
            return .padButton(b)
        case .gamepadDPad:
            return .padDPad(deadzone: diameter * 0.26)
        }
    }
}

/// ml662: drawing only. Every branch that used to press, hold, steer or
/// release is gone — ControlOverlayView does all of it, keyed by the UITouch
/// that landed here, and publishes the pressed/deflected state this view reads
/// back out of `ControlFaces`.
///
/// The DragGesture that remains is EDIT MODE ONLY: repositioning a control is
/// layout, it happens while the game is not being played, and the touch layer
/// deliberately stands down (`region(at:)` returns nil while editing) so this
/// gesture has the screen to itself.
struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @ObservedObject private var face: ControlFaceState
    @State private var dragBase: CGPoint?
    private let rid: String

    init(control: TouchControl, screen: CGSize) {
        self.control = control
        self.screen = screen
        let id = control.regionID
        self.rid = id
        _face = ObservedObject(wrappedValue: ControlFaces.state(id))
    }

    /// ml670: the layout-wide size slider multiplies this control's own pinch.
    private var diameter: CGFloat { TouchControlsModel.diameter(control) }
    private var isStick: Bool { control.action.isStick }
    private var isSelected: Bool { m.editing && m.selected == control.id }
    private var isDown: Bool { face.down }
    /// ml670: the DRAWN rect. Square for everything that was here before; a
    /// shoulder button, a Start capsule and the D-pad cross are not square, and
    /// `.controlRegion` is attached after this frame so the touch region is
    /// exactly what is on screen.
    private var boxSize: CGSize { control.action.controlSize(diameter: diameter) }

    // ------------------------------------------------------------------
    // ml670 — VIRTUAL CONTROLLER FACES
    //
    // WHY THIS EXISTS AT ALL: every one of these used to draw the letter "L".
    // A control is created with `action = .mouseLeft` (so a brand-new button is
    // usable before anything is mapped), `.mouseLeft.label` is "L", and the
    // controller tab only ever set `padBinding` — a SECOND property that does
    // not touch `action`. So a user who added a button and chose "A" on the
    // controller tab got a left-mouse button, drawn "L", pressing nothing on a
    // pad. The action is now what says "this IS an A button", and the drawing
    // follows the action.
    // ------------------------------------------------------------------

    /// The edit-mode selection ring and the resting outline, in whatever shape
    /// this control actually is.
    @ViewBuilder private var outline: some View {
        let o = isSelected ? 0.95 : (isStick || control.action == .gamepadDPad ? 0 : 0.28)
        let w: CGFloat = isSelected ? 2 : 1
        switch control.action.padButton?.face {
        case .some(.wide):
            RoundedRectangle(cornerRadius: boxSize.height * 0.30)
                .stroke(.white.opacity(o), lineWidth: w)
        case .some(.capsule):
            Capsule().stroke(.white.opacity(o), lineWidth: w)
        default:
            if control.action == .gamepadDPad {
                RoundedRectangle(cornerRadius: boxSize.width * 0.16)
                    .stroke(.white.opacity(isSelected ? 0.95 : 0), lineWidth: w)
            } else {
                Circle().stroke(.white.opacity(o), lineWidth: w)
            }
        }
    }

    @ViewBuilder private func padFace(_ b: PadButton) -> some View {
        switch b.face {
        case .round:
            ZStack {
                GlassShape(circle: true)
                if let t = b.tint {
                    // Translucent like every other control — the tint is a hue
                    // on the glass, not a solid disc, or the four face buttons
                    // would be the only opaque things on the screen.
                    Circle().fill(t.opacity(isDown ? 0.62 : 0.34))
                }
                if let g = b.glyph {
                    Image(systemName: g)
                        .font(.system(size: boxSize.height * 0.40, weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
                } else {
                    Text(b.faceLabel)
                        .font(.system(size: boxSize.height * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.92))
                }
            }
        case .small:
            ZStack {
                GlassShape(circle: true)
                Text(b.faceLabel)
                    .font(.system(size: boxSize.height * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
            }
        case .wide:
            ZStack {
                RoundedRectangle(cornerRadius: boxSize.height * 0.30)
                    .fill(.ultraThinMaterial)
                    .opacity(isDown ? 1.0 : 0.85)
                Text(b.faceLabel)
                    .font(.system(size: boxSize.height * 0.40, weight: .semibold))
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.88))
            }
        case .capsule:
            ZStack {
                Capsule().fill(.ultraThinMaterial).opacity(isDown ? 1.0 : 0.85)
                Text(b.faceLabel)
                    .font(.system(size: boxSize.height * 0.44, weight: .semibold))
                    .kerning(0.6)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .foregroundStyle(.white.opacity(isDown ? 1.0 : 0.85))
            }
        case .stick:
            // Unreachable: `isStick` catches the two sticks before padFace is
            // called. Present so the switch is exhaustive without a `default`,
            // which is what makes a new PadButton a compile error here.
            EmptyView()
        }
    }

    /// ONE cross, not four buttons. A real D-pad's diagonals are its corners,
    /// and four separate circles cannot produce one without two thumbs — which
    /// is exactly the thing an 8-way snap over a single region gives for free,
    /// using the same `snap` the thumbsticks already use.
    private var dpadCross: some View {
        let w = boxSize.width
        let arm = w * 0.36
        let r = arm * 0.28
        // 0 up, clockwise. A diagonal lights BOTH of its arms, because it is
        // holding both bits.
        func lit(_ dir: Int) -> Bool {
            guard face.dir >= 0 else { return false }
            let d = face.dir
            switch dir {
            case 0: return d == 7 || d == 0 || d == 1
            case 2: return d == 1 || d == 2 || d == 3
            case 4: return d == 3 || d == 4 || d == 5
            default: return d == 5 || d == 6 || d == 7
            }
        }
        func arrow(_ g: String, _ dir: Int, _ dx: CGFloat, _ dy: CGFloat) -> some View {
            Image(systemName: g)
                .font(.system(size: arm * 0.46, weight: .semibold))
                .foregroundStyle(.white.opacity(lit(dir) ? 1.0 : 0.55))
                .offset(x: dx * w * 0.33, y: dy * w * 0.33)
        }
        return ZStack {
            RoundedRectangle(cornerRadius: r).fill(.ultraThinMaterial)
                .frame(width: w, height: arm)
            RoundedRectangle(cornerRadius: r).fill(.ultraThinMaterial)
                .frame(width: arm, height: w)
            arrow("arrowtriangle.up.fill",    0,  0, -1)
            arrow("arrowtriangle.right.fill", 2,  1,  0)
            arrow("arrowtriangle.down.fill",  4,  0,  1)
            arrow("arrowtriangle.left.fill",  6, -1,  0)
        }
        .frame(width: w, height: w)
    }

    var body: some View {
        ZStack {
            if isStick {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                // ml670: a VIRTUAL thumbstick uses the identical face — a stick
                // is a stick, and drawing it any other way would be the second
                // stick idiom on one screen.
                JoystickFace(held: isDown, dir: face.dir, alwaysExpanded: true,
                             vec: face.vec, glyph: control.action.stickGlyph)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
            } else if control.action == .gamepadDPad {
                dpadCross
            } else if let b = control.action.padButton {
                padFace(b)
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(control.action.isPad ? 0.45
                                                    : (isDown ? 1.0 : 0.85)))
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
        .overlay(outline)
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isDown)
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: face.dir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        // MUST come before .position: .position expands the modified view to
        // fill its parent, so a frame probe attached after it would measure the
        // whole screen instead of this control. Attached here it measures the
        // control and still reports its FINAL placed rect in .global.
        .controlRegion(rid, control.action.label,
                       control.action.regionKind(diameter: diameter),
                       circular: control.action.circularHit)
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        // Edit mode only; see the type comment.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard m.editing else { return }
                    m.selected = control.id
                    guard let i = m.index(of: control.id) else { return }
                    if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                    let b = dragBase ?? .zero
                    m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                    m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                }
                .onEnded { _ in dragBase = nil }
        )
        .onDisappear { dragBase = nil }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    /// ml672: the "Right stick also moves the mouse" toggle below lives on
    /// this object.
    @ObservedObject private var input = InputSettings.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        // ml670: the control's real half-extent, which now depends on its SHAPE
        // (a D-pad cross is half again as wide as a button) and on the
        // layout-wide size slider. The larger half-axis, so the panel clears it
        // whichever side it ends up on.
        let box = control.action.controlSize(diameter: TouchControlsModel.diameter(control))
        let r  = max(box.width, box.height) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                // ml666: no "Aim" entry — the mouse-look stick is off the HUD.
                // `.joystickMouse` stays in ControlAction so a layout saved
                // before this build still decodes and still works; it just
                // cannot be assigned to a new control any more.
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    // ml668 — THE CONTROLLER TAB IS NOW A BINDING, NOT A LABEL.
    //
    // What it used to offer was `ControlAction.pad("A")`: a control that DREW
    // an Xbox glyph and, as the banner admitted, pressed nothing. What it
    // offers now is the physical button that ALSO presses this control, on top
    // of whatever the keyboard tab set it to. The distinction is the whole
    // feature: a control still posts its own key, and the pad is a second
    // finger on it, so one layout serves a thumb and a controller at once.
    //
    // A game that reads XInput sees the pad regardless of anything chosen
    // here — that path does not go through the layout at all (wine's
    // xinput1_3 reads the same sample through win32u). These bindings are for
    // the majority of titles, which read the keyboard and the mouse and have
    // never heard of a controller.
    // ml670 — AND THE TAB NOW HAS TWO HALVES, because there are two genuinely
    // different things a controller can mean for one control and conflating
    // them is what shipped a screen full of buttons labelled "L".
    //
    //   MAKE IT a controller button  → sets `action`. The control IS an XInput
    //     button: it draws like one and a game polling XInput sees it pressed.
    //   ALSO PRESSED BY              → sets `padBinding`. The control keeps
    //     doing whatever the keyboard tab says, and a PHYSICAL button is a
    //     second finger on it.
    //
    // Both at once is legal and occasionally useful; neither implies the other.
    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make this control a virtual controller button. A game that "
                 + "reads XInput sees it as controller 1, with or without a "
                 + "physical pad plugged in.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            actionSection("Face buttons", [.gamepad(.a), .gamepad(.b),
                                           .gamepad(.x), .gamepad(.y)])
            actionSection("Bumpers & triggers", [.gamepad(.lb), .gamepad(.rb),
                                                 .gamepad(.lt), .gamepad(.rt)])
            actionSection("D-pad", [.gamepadDPad, .gamepad(.dpadUp),
                                    .gamepad(.dpadDown), .gamepad(.dpadLeft),
                                    .gamepad(.dpadRight)])
            actionSection("Sticks & clicks", [.gamepad(.leftStick), .gamepad(.rightStick),
                                              .gamepad(.l3), .gamepad(.r3)])
            actionSection("System", [.gamepad(.start), .gamepad(.back)])

            Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.vertical, 2)

            Text("Also press this control with a physical controller button. "
                 + "Games that read XInput get the controller either way.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            padSection("Face", [.a, .b, .x, .y])
            padSection("Bumpers & triggers", [.lb, .rb, .lt, .rt])
            padSection("D-pad", [.dpadUp, .dpadDown, .dpadLeft, .dpadRight])
            padSection("Sticks & clicks", [.leftStick, .rightStick, .l3, .r3])
            padSection("System", [.start, .back])
            padSection("", [nil])            // the "None" chip, on its own row
            Text("A stick binding wants a stick control: L-stick steers a WASD "
                 + "or arrows control, R-stick drives mouse-look. With nothing "
                 + "bound at all, A/B/X/Y and the bumpers fall to the first "
                 + "buttons in the layout and L-stick to its first stick.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(.white.opacity(0.15)).frame(height: 1).padding(.vertical, 2)

            // ml672 — OFF by default. A game that reads the controller
            // itself (XInput or the DirectInput joystick) already gets the
            // right stick natively; also feeding it to the mouse steers the
            // camera twice and drags the game's own cursor. Turn this on
            // only for a game with no native controller support that is
            // being played with a mouse-look control on screen, or in
            // relative-mouse mode.
            Toggle(isOn: $input.padRightStickMouse) {
                Text("Right stick also moves the mouse")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .tint(.accentColor)
            Text("Off by default: a game that reads the controller itself "
                 + "already gets the right stick, and feeding it to the "
                 + "mouse too fights the camera against itself. An "
                 + "on-screen mouse-look control still works by touch "
                 + "either way.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row of pad-binding chips. `nil` is the unbind chip.
    private func padSection(_ title: String, _ items: [PadButton?]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, b in
                    padChip(b)
                }
            }
        }
    }

    private func padChip(_ button: PadButton?) -> some View {
        let on = control.padBinding == button
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            guard let i = m.index(of: control.id) else { return }
            // ONE control per button. Binding B to a control that already has
            // A silently leaves A unbound would be surprising; binding a button
            // that another control already claims quietly stealing it would be
            // worse. So: clear the button everywhere first, then claim it here.
            if let button {
                for j in m.controls.indices where m.controls[j].padBinding == button {
                    m.controls[j].padBinding = nil
                }
            }
            m.controls[i].padBinding = button
        } label: {
            Text(button?.label ?? "None")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }

    /// ml670: a row of chips that set `action`, labelled by the action itself —
    /// no second label table to drift out of step with what the control draws.
    private func actionSection(_ title: String, _ actions: [ControlAction]) -> some View {
        section(title, actions.map { ($0.label, $0) })
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
