import Foundation
import QuartzCore
import UIKit
import SwiftUI
import GameController
import ObjectiveC

// ============================================================================
// ml663 — A REAL KEYBOARD AND A REAL MOUSE, BEHAVING LIKE ONE.
//
// Everything the app posted into wine until now originated as a FINGER: a touch
// on the live view, a region in ControlOverlayView, a thumb on a stick. Each of
// those had to invent the thing it was standing in for — a stick invents held
// arrow keys, the aim stick invents a stream of relative mouse counts, a tap
// invents a click. Plug a Bluetooth keyboard and mouse into the phone and there
// is nothing left to invent: the hardware already produces exactly the events
// Windows expects, and this file's whole job is to not lose them on the way.
//
// WHY GCKeyboard AND NOT UIKey / pressesBegan.
//
// UIKit's press pipeline is a TEXT pipeline wearing a keyboard costume. It is
// wrong for a game in three ways that cannot be configured away:
//
//   • Modifiers are not keys there. Holding Shift delivers no press at all; it
//     arrives as `modifierFlags` on the NEXT key's event. A game that walks on
//     W and sprints on Shift needs Shift's own down and up, on time.
//   • Auto-repeat is synthesised. Hold W and UIKit re-delivers it ~30×/s, each
//     one a down with no matching up. Wine would see W pressed thirty times a
//     second and the game would stutter-step.
//   • UIKeyCommand is a menu mechanism: it matches whole chords, consumes them,
//     and tells you nothing about release.
//
// GCKeyboard is the raw HID path — one callback per physical transition, with
// the modifiers as ordinary keys and no repeat. That is a keyboard.
//
// WHAT THE VK MAP IS KEYED ON.
//
// `GCKeyCode.rawValue` IS the USB HID keyboard usage ID (0x04 = 'a', 0xE1 =
// left shift, ...). Mapping from the raw usage rather than from GCKeyCode's
// named constants is deliberate: the usage table is fixed by the USB HID spec
// and complete, whereas the named constants are an SDK-version-dependent subset
// (F13-F24 and most of the international keys have no constant at all). One
// switch over integers covers every key a keyboard can send, including the ones
// Apple never named.
//
// WHAT THE DRIVER ALREADY DOES, SO THIS FILE DOES NOT.
//
// Extended keys need no special handling here: driver_ios.c:141 derives the
// scan code with MAPVK_VK_TO_VSC_EX and sets KEYEVENTF_EXTENDEDKEY whenever
// that returns 0xE0xx — arrows, the nav cluster, right ctrl/alt, numpad divide,
// NumLock. The generic VK_SHIFT/VK_CONTROL/VK_MENU a game reads with
// GetAsyncKeyState are synthesised by the wineserver from the left/right ones
// (queue_ios.c:1704-1717). So posting VK_LSHIFT is both more precise than
// posting VK_SHIFT and strictly more compatible.
// ============================================================================

final class HardwareInput: ObservableObject {
    static let shared = HardwareInput()

    // MARK: published state (drives the small amount of UI this needs)

    @Published private(set) var keyboardConnected = false
    @Published private(set) var mouseConnected = false
    @Published private(set) var gamepadConnected = false
    /// Pointer lock: the iOS system pointer is hidden and pinned, and the mouse
    /// deltas keep arriving at the screen edges. See `PointerLock`.
    @Published private(set) var pointerLocked = false
    /// ml665 — a mouse enumerated, but nothing ever came out of it. On iPhone
    /// that has exactly one cause and one fix, and the user cannot be expected
    /// to know it: AssistiveTouch is the only pointer-device path the OS has.
    /// Raised once per session, dismissable, cleared the instant a delta lands.
    @Published private(set) var assistiveTouchHint = false
    /// Window-space rect of the hint banner, so `ControlsWindow.hitTest` lets
    /// its dismiss button through in portrait (where that window otherwise
    /// consumes nothing outside a control region). `.zero` = not on screen.
    static var hintRect: CGRect = .zero
    /// ml665 — whether pointer lock can do ANYTHING on this device.
    /// `prefersPointerLocked` is an iPad mechanism; iPhone's on-screen cursor
    /// belongs to AssistiveTouch and ignores it. There is no API that reports
    /// this, so the idiom is the detection — see `setPointerLocked`. The UI
    /// reads it too: a lock button that cannot lock is worse than no button.
    static var pointerLockAvailable: Bool { UIDevice.current.userInterfaceIdiom != .phone }

    // ml664 — WHICH PATH IS CARRYING THE MOUSE.
    //
    // Two of them, and on some devices only the second one ever produces a
    // delta (see the ml664 banner below `attachMouse`). The distinction is not
    // cosmetic: pointer lock is CORRECT for `.gcmouse` and FATAL for `.uikit`,
    // because `prefersPointerLocked` is precisely the switch that tells UIKit to
    // stop delivering pointer events. So the path is decided by evidence — a
    // delta that actually arrived — and everything else keys off it.
    enum MousePath: String { case none, gcmouse, uikit }
    @Published private(set) var mousePath: MousePath = .none

    // MARK: InputGuard ownership
    //
    // ml661's model, unchanged and for the same reason: every holder of a key or
    // a button states the SET it wants held, and InputGuard posts the difference.
    // A hardware keyboard is just another owner — which is what lets an on-screen
    // fire button and a physical mouse button be pressed at the same time without
    // either one's release dropping the other's press.
    //
    // One owner per DEVICE ROLE, not per key: releasing the keyboard is then a
    // single call that cannot be got half-right (disconnect, backgrounding, a
    // scene going inactive with four keys down).

    private var kbOwner = 0
    private var mouseOwner = 0

    private var heldVKs: Set<Int32> = []
    private var heldButtons: Set<Int> = []

    // ml668: the gamepad has no owner of its own here any more. Its presses go
    // through `ControlOverlayView`, which allocates one InputGuard owner PER
    // PHYSICAL BUTTON — because a pad button now presses a control the user
    // chose, not a key this file invented, and "which control" is a property of
    // the layout rather than of the device. See the pad section below.

    // MARK: relative-motion carry
    //
    // Same truncation problem as ml641's relCarryX, same fix: the integer delta
    // handed to wine loses a fraction on every event, and at a sensitivity below
    // 1.0 that fraction is the entire signal. Carry it.
    private var carryX: CGFloat = 0
    private var carryY: CGFloat = 0

    // Scroll is continuous on a Magic Mouse / precision wheel; Windows counts
    // NOTCHES of 120. Accumulate and emit whole notches.
    private var scrollAccumY: Double = 0
    private var scrollAccumX: Double = 0
    private static let scrollNotch: Double = 1.0

    // MARK: 1 Hz activity line
    private var ticker: Timer?
    private var tickDX: Double = 0, tickDY: Double = 0
    private var tickKeys = 0, tickWheel = 0
    /// Lock-guarded mirror of `ticker != nil`, readable from the mouse queue.
    private var tickerArmed = false

    private var started = false

    // MARK: mouse-path bookkeeping (ml664)

    /// Every GCMouse we have already wired. GameController hands the same object
    /// back from `mice()`, from `current` and from the connect notification, and
    /// re-assigning the handlers is harmless — but re-LOGGING "mouse connected"
    /// three times is not, so the identity set decides what is news.
    private var attachedMice = Set<ObjectIdentifier>()
    /// Set by the first non-zero `mouseMovedHandler` callback. Until this is
    /// true, GCMouse is a device that exists, not a device that reports.
    private var gcDeltaSeen = false
    /// Set by the first delta that arrived through UIKit instead.
    private var uikitSeen = false
    /// Raw-delta sampling: every one of the first 20, then 1-in-100.
    private var rawSeq = 0

    // ========================================================================
    // ml665 — THE ASSISTIVETOUCH MOUSE, AND WHY IT FELT BAD.
    //
    // THE REQUIREMENT WE CANNOT REMOVE. On iPhone there is no public HID path
    // to a Bluetooth mouse at all: pointer devices are routed ONLY through
    // AssistiveTouch (Settings ▸ Accessibility ▸ Touch ▸ AssistiveTouch ▸ On,
    // then Devices). With it off, GCMouse enumerates the device and delivers
    // nothing; with it on, `mouseMovedHandler` fires. `prefersPointerLocked` is
    // an iPad API — iPhone has no system pointer to lock, so the request is
    // inert there (see `setPointerLocked`). None of that is something this app
    // can work around, so it is stated here and in the UI rather than retried.
    //
    // WHAT MADE IT STUTTER. AssistiveTouch turns a mouse CLICK into a
    // synthesised TOUCH at the accessibility cursor's position, delivered as an
    // ordinary `.direct` UITouch — not `.indirectPointer`. So a click used to
    // land in `MetalBackedView.touchesBegan` as a finger: absolute
    // MOVE|LEFTDOWN|ABSOLUTE at the cursor's screen point, which SNAPS the
    // game's cursor there, after which our relative deltas resume from the new
    // place. Click, jump, drift back, click, jump: exactly the "stuttery,
    // didn't feel good" the user reported. Worse, the same synthesised touch
    // can land on an on-screen control and press it.
    //
    // The buttons are already carried correctly by GCMouse's own
    // `pressedChangedHandler`, so the synthesised touch is pure duplication.
    // While a real mouse is live (`mousePath == .gcmouse` and a delta inside
    // `Self.mouseActiveWindow`), `shouldIgnore(_:)` classifies each incoming
    // `.direct` touch and both the live view and `ControlOverlayView` drop the
    // synthesised ones. `InputSettings.ignoreTouchesWithMouse` is the knob that
    // turns the whole thing off if the heuristic ever misfires on a device we
    // have not seen.
    //
    // DELIVERY. `handlerQueue` used to be `.main` — the same queue SwiftUI
    // re-renders and the log console scrolls on, so a mouse sample could sit
    // behind a body evaluation. It is `mouseQueue` now, a dedicated serial
    // `.userInteractive` queue, which makes `moved`/`button`/`scrolled`
    // off-main: hence `motionLock` over the carries and counters, and a main
    // hop for everything that touches `@Published` state, `InputGuard` or the
    // `Timer`. `winios_pointer` is posted DIRECTLY from the mouse queue — the
    // ring behind it takes its own mutex and has always been written from
    // whatever thread had the event.
    // ========================================================================

    /// GCMouse's delivery queue. Serial (so deltas stay ordered) and
    /// `.userInteractive` (so a mouse sample outranks a SwiftUI re-render).
    private let mouseQueue = DispatchQueue(label: "madeira.hwinput.mouse",
                                           qos: .userInteractive)
    /// Guards every counter below that the mouse queue and the main queue both
    /// touch: the carries, the scroll accumulators, the 1 Hz tick totals, the
    /// raw-sample sequence and the delivery statistics.
    private let motionLock = NSLock()

    /// A GCMouse delta inside this many seconds means the hand is on the mouse
    /// and a `.direct` touch is AssistiveTouch's, not a finger's.
    private static let mouseActiveWindow: CFTimeInterval = 2.0
    /// `CACurrentMediaTime()` of the last non-zero GCMouse delta (motionLock).
    private var lastGCDeltaAt: CFTimeInterval = 0
    /// `CACurrentMediaTime()` of the last GCMouse button transition (motionLock).
    private var lastGCButtonAt: CFTimeInterval = 0
    /// Set by the first non-zero delta, from the mouse queue (motionLock). The
    /// main-thread mirror is `gcDeltaSeen`.
    private var gcDeltaLive = false
    /// Classification lines are capped at 30 — enough to validate the heuristic
    /// on a device, few enough to be free afterwards. Main thread only.
    private var touchClassLogged = 0
    /// One line, not one per attempt. Main thread only.
    private var phoneLockNoted = false
    /// The 10 s hint countdown is armed once per session. Main thread only.
    private var hintArmed = false

    // Delivery statistics, all under motionLock. Reported every 10 s from the
    // mouse queue: if AssistiveTouch delivers at ~60 Hz there is nothing left to
    // win in delivery, and if the ring coalesces most of them the game is seeing
    // per-frame chunks — which is what a 30-40 fps game can consume anyway.
    private static let deliveryWindow: CFTimeInterval = 10.0
    private var devCount = 0
    private var devLastAt: CFTimeInterval = 0
    private var devGapSum: Double = 0
    private var devGapMax: Double = 0
    private var devWindowStart: CFTimeInterval = 0
    private var devRingPushed: UInt32 = 0
    private var devRingCoalesced: UInt32 = 0

    private let F_MOVE: UInt32 = 0x0001
    private let F_WHEEL: UInt32 = 0x0800
    private let F_HWHEEL: UInt32 = 0x1000

    // MARK: - lifecycle

    /// Idempotent. Called from ContentView.onAppear, which happens once per
    /// scene and long before any device can be plugged in.
    func start() {
        guard !started else { return }
        started = true
        kbOwner = InputGuard.newOwner()
        mouseOwner = InputGuard.newOwner()

        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
            self?.attachKeyboard(n.object as? GCKeyboard)
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.detachKeyboard()
        }
        nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            self?.log("GCMouseDidConnect")
            self?.attachMouse(n.object as? GCMouse, why: "connect")
        }
        nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] n in
            self?.detachMouse(n.object as? GCMouse)
        }
        // A mouse that is connected but not CURRENT is a mouse GameController is
        // not routing to this app. The notification is the moment that changes,
        // and it is the one moment the handlers are worth (re-)installing even
        // though nothing about the device object changed.
        nc.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { [weak self] n in
            self?.log("GCMouseDidBecomeCurrent")
            self?.attachMouse(n.object as? GCMouse, why: "became-current")
        }
        nc.addObserver(forName: .GCMouseDidStopBeingCurrent, object: nil, queue: .main) { [weak self] n in
            self?.log("GCMouseDidStopBeingCurrent: \((n.object as? GCMouse)?.vendorName ?? "?")")
        }
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            self?.attachController(n.object as? GCController)
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            self?.detachController(n.object as? GCController)
        }

        // ml661's rule, applied to hardware: the events that end a press are the
        // ones you cannot count on arriving. A key held when the app resigns
        // active gets no key-up — iOS simply stops delivering. InputGuard already
        // releases the OWNER on these notifications; this clears our own mirror of
        // what is held, so the next real transition starts from an honest set
        // instead of re-posting a key the user let go of minutes ago.
        for n in [UIApplication.willResignActiveNotification,
                  UIApplication.didEnterBackgroundNotification,
                  UIApplication.didReceiveMemoryWarningNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.forgetHeld("scene-inactive")
            }
        }

        // Devices already attached when the app launched get no notification.
        attachKeyboard(GCKeyboard.coalesced)
        inventory("startup")
        for c in GCController.controllers() { attachController(c) }
        log("started (keyboard=\(keyboardConnected) mouse=\(mouseConnected) pad=\(gamepadConnected))")

        // ml664 — WHY THE "connected" LINES WERE MISSING FROM THE PULLED LOG.
        //
        // Nothing was wrong with the devices: the lines were written before
        // anything was listening. stderr only becomes the log file when the wine
        // sequence starts (the first stderr line in a pulled log is
        // `[phase] wine-start t+4.2s`), and this runs from ContentView.onAppear,
        // seconds earlier. Every log() above therefore went to a console nobody
        // captured — which is exactly why the last run showed a mouse that
        // toggled pointer lock (so it WAS attached) with no "mouse connected"
        // line anywhere, the single most misleading shape the evidence could
        // have taken.
        //
        // The device inventory is cheap and idempotent, so re-emit it after the
        // redirect has certainly happened. Three samples, not one, because the
        // interesting case is a device that appears between them.
        for delay in [10.0, 30.0, 90.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.inventory("t+\(Int(delay))s")
            }
        }
    }

    /// Enumerate and (re-)wire every pointing device GameController admits to,
    /// by BOTH routes — `mice()` and `current` — because they are not the same
    /// list and either can be the empty one.
    private func inventory(_ why: String) {
        let mice = GCMouse.mice()
        let cur = GCMouse.current
        log("inventory(\(why)): mice=\(mice.count) current=\(cur != nil) "
            + "keyboard=\(GCKeyboard.coalesced != nil) path=\(mousePath.rawValue) "
            + "gcDelta=\(gcDeltaSeen) uikit=\(uikitSeen)")
        for (i, m) in mice.enumerated() {
            log("  mice[\(i)]: vendor=\(m.vendorName ?? "?") "
                + "category=\(m.productCategory) "
                + "mouseInput=\(m.mouseInput == nil ? "NIL" : "present") "
                + "current=\(cur === m)")
            attachMouse(m, why: "\(why)/mice[\(i)]")
        }
        if let cur, !mice.contains(where: { $0 === cur }) {
            log("  current: vendor=\(cur.vendorName ?? "?") category=\(cur.productCategory) "
                + "mouseInput=\(cur.mouseInput == nil ? "NIL" : "present") (NOT in mice())")
            attachMouse(cur, why: "\(why)/current")
        }
        if let kb = GCKeyboard.coalesced {
            log("  keyboard: vendor=\(kb.vendorName ?? "?") category=\(kb.productCategory) "
                + "keyboardInput=\(kb.keyboardInput == nil ? "NIL" : "present")")
            attachKeyboard(kb)
        }
    }

    private func log(_ s: String) {
        fputs("[hwinput] \(s)\n", stderr)
    }

    /// The one-shot verdict, and the only place `mousePath` moves.
    ///
    /// `.gcmouse` is absorbing: once a real HID delta has arrived, the UIKit
    /// path is redundant at best and a double-count at worst.
    private func announcePath(_ p: MousePath) {
        guard p != mousePath, mousePath != .gcmouse else { return }
        mousePath = p
        log("mouse path: \(p.rawValue)")
    }

    /// Raw delta trace: all of the first 20, then 1-in-100. The first twenty are
    /// what tells a dead stream from a stream whose deltas are all zero, and
    /// those are completely different bugs.
    private func logRaw(_ src: String, _ dx: CGFloat, _ dy: CGFloat) {
        motionLock.lock(); rawSeq += 1; let n = rawSeq; motionLock.unlock()
        guard n <= 20 || n % 100 == 0 else { return }
        log(String(format: "raw %@ #%d dx=%.3f dy=%.3f", src, n, Double(dx), Double(dy)))
    }

    /// Drop every held-key belief without posting anything: InputGuard's own
    /// releaseAll (and winios_release_all_keys behind it) has already sent, or is
    /// about to send, the ups.
    private func forgetHeld(_ why: String) {
        guard !heldVKs.isEmpty || !heldButtons.isEmpty else { return }
        log("forget held (\(why)) keys=\(heldVKs.count) btns=\(heldButtons.count)")
        heldVKs.removeAll(); heldButtons.removeAll()
        InputGuard.shared.release(kbOwner)
        InputGuard.shared.release(mouseOwner)
        // ml668: the pad's holds live in ControlOverlayView, one owner per
        // physical button. Its own valve is the complete one.
        ControlOverlayView.shared.padReleaseAll(why)
        motionLock.lock()
        carryX = 0; carryY = 0
        scrollAccumX = 0; scrollAccumY = 0
        motionLock.unlock()
    }

    // MARK: - keyboard

    private func attachKeyboard(_ kb: GCKeyboard?) {
        guard let kb else { return }
        guard let input = kb.keyboardInput else {
            // Never silent: a keyboard whose `keyboardInput` is nil is a
            // keyboard the app will never hear from, and that is a finding.
            if !keyboardConnected {
                log("keyboard connected: \(kb.vendorName ?? "keyboard") "
                    + "[category=\(kb.productCategory)] keyboardInput=NIL — no key stream")
            }
            return
        }
        // InputGuard, ControlFaces and the whole SwiftUI side are main-thread
        // only. GameController's default handler queue already IS the main queue,
        // but saying so is cheaper than discovering otherwise.
        kb.handlerQueue = .main
        input.keyChangedHandler = { [weak self] _, _, code, pressed in
            self?.key(code, pressed)
        }
        let fresh = !keyboardConnected
        keyboardConnected = true
        startTicker()
        if fresh { log("keyboard connected: \(kb.vendorName ?? "keyboard") "
                       + "[category=\(kb.productCategory)]") }
    }

    private func detachKeyboard() {
        // A key physically held at the moment the keyboard's battery dies never
        // sends its up. Release first, then forget.
        heldVKs.removeAll()
        InputGuard.shared.release(kbOwner)
        keyboardConnected = GCKeyboard.coalesced?.keyboardInput != nil
        log("keyboard disconnected (coalesced still present=\(keyboardConnected))")
    }

    private func key(_ code: GCKeyCode, _ pressed: Bool) {
        tickKeys += 1
        guard let vk = HardwareInput.vk(forHIDUsage: code.rawValue) else {
            // Worth a line each: an unmapped key is a key the user pressed and
            // the game did not receive, and the usage number names it exactly.
            if pressed { log("unmapped HID usage 0x\(String(code.rawValue, radix: 16))") }
            return
        }
        if pressed { heldVKs.insert(vk) } else { heldVKs.remove(vk) }

        // Ctrl+Alt+P — the way OUT of pointer lock, and therefore the one chord
        // that must work while the pointer is locked and the SwiftUI chrome is
        // unreachable by pointer. Swallowed (never posted to wine) so a game
        // bound to P does not also act on it; Ctrl and Alt themselves are posted
        // normally, because they are keys the user is genuinely holding.
        if pressed, vk == 0x50,
           heldVKs.contains(0xA2) || heldVKs.contains(0xA3),   // L/R control
           heldVKs.contains(0xA4) || heldVKs.contains(0xA5) {  // L/R alt
            heldVKs.remove(vk)
            InputGuard.shared.hold(kbOwner, keys: heldVKs)
            setPointerLocked(!pointerLocked, why: "Ctrl+Alt+P")
            return
        }
        InputGuard.shared.hold(kbOwner, keys: heldVKs)
        startTicker()
    }

    // MARK: - mouse

    // ========================================================================
    // ml664 — A GCMouse THAT CONNECTS AND NEVER REPORTS.
    //
    // Last run's evidence, in order: the keyboard worked; `GCMouse` produced a
    // DISCONNECT notification; `mouseConnected` was true and pointer lock
    // toggled on and off (which `setPointerLocked` refuses unless a mouse is
    // attached, so `mouseInput` was NOT nil); and across the whole session the
    // 1 Hz line read `mouse_dx=0 mouse_dy=0` with not one `drv_post_mouse`. So
    // GameController enumerated the device, handed over a `GCMouseInput`, and
    // then delivered zero callbacks through it.
    //
    // That is the documented iPhone shape of GCMouse, not a wiring mistake.
    // Pointer support on iOS is an iPad feature: iPadOS routes a Bluetooth
    // mouse to a system pointer and, for apps that ask, to GCMouse's raw HID
    // stream. iPhone has no system pointer — a mouse pairs there through
    // AssistiveTouch's pointer-device support, which OWNS the HID reports and
    // turns them into an accessibility cursor. `GCMouse` still vends the device
    // (it is a HID device, it enumerates, it disconnects) but the report stream
    // never reaches `mouseMovedHandler`. And `prefersPointerLocked` cannot
    // rescue it: there is no pointer to lock, so the request is inert.
    //
    // Hence defence in depth. This method wires GCMouse as well as it can be
    // wired — every device from both `mice()` and `current`, handlers re-armed
    // when one becomes current, nothing assumed about which object is live —
    // and `uikitMoved`/`uikitButtons`/`uikitScroll` below accept the same
    // motion from UIKit's indirect-pointer pipeline, which is the ONLY pipeline
    // an AssistiveTouch-owned or otherwise non-GC mouse can reach. Whichever
    // one produces a delta first wins, and says so in one line.
    //
    // HANDLER SIGNATURES, since a wrong one compiles and then never fires:
    //   mouseInput.mouseMovedHandler  : (GCMouseInput, Float, Float) -> Void
    //   button.pressedChangedHandler  : (GCControllerButtonInput, Float, Bool) -> Void
    //   scroll.valueChangedHandler    : (GCControllerDirectionPad, Float, Float) -> Void
    // `pressedChangedHandler` and `valueChangedHandler` on a button share one
    // type, so assigning the pressed closure to the value property type-checks
    // and silently changes the semantics. Both are spelled out at each use.
    // ========================================================================

    private func attachMouse(_ mouse: GCMouse?, why: String) {
        guard let mouse else { return }
        let fresh = attachedMice.insert(ObjectIdentifier(mouse)).inserted

        guard let m = mouse.mouseInput else {
            // The silent `return` this guard used to be is what made the last
            // run unreadable. A mouse with no input object is a finding, and
            // the UIKit path is still available to it.
            if fresh {
                log("mouse connected: \(mouse.vendorName ?? "mouse") "
                    + "[category=\(mouse.productCategory) via=\(why)] mouseInput=NIL "
                    + "— no GC delta stream; UIKit indirect-pointer path only")
            }
            noteMousePresent()
            return
        }
        // ml665: NOT `.main`. See the ml665 banner — the main queue is where
        // SwiftUI re-renders and the log console scrolls, and a mouse sample
        // queued behind one of those is jitter the user feels as stutter.
        mouse.handlerQueue = mouseQueue

        m.mouseMovedHandler = { [weak self] _, dx, dy in
            self?.moved(CGFloat(dx), CGFloat(dy))
        }
        m.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(InputGuard.Btn.left, pressed)
        }
        m.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(InputGuard.Btn.right, pressed)
        }
        m.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.button(InputGuard.Btn.middle, pressed)
        }
        // Side buttons, in the order the device reports them. Windows has
        // exactly two (XBUTTON1/XBUTTON2); anything beyond is dropped rather
        // than invented.
        for (i, aux) in (m.auxiliaryButtons ?? []).enumerated() where i < 2 {
            let b = (i == 0) ? InputGuard.Btn.x1 : InputGuard.Btn.x2
            aux.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.button(b, pressed)
            }
        }
        m.scroll.valueChangedHandler = { [weak self] _, x, y in
            self?.scrolled(Double(x), Double(y))
        }

        noteMousePresent()
        // NO pointer lock here — ml664. Locking on CONNECT is what made the
        // previous revision unrecoverable: `prefersPointerLocked` tells UIKit to
        // stop delivering pointer events, so the moment a mouse appeared the app
        // switched off the only pipeline that was actually carrying it, on the
        // strength of a GCMouse object that turned out to report nothing. Lock
        // is armed by the first real GCMouse delta instead, in `moved`.
        if fresh {
            log("mouse connected: \(mouse.vendorName ?? "mouse") "
                + "[category=\(mouse.productCategory) via=\(why) "
                + "current=\(GCMouse.current === mouse)] "
                + "(right=\(m.rightButton != nil) middle=\(m.middleButton != nil) "
                + "aux=\(m.auxiliaryButtons?.count ?? 0)) — awaiting first delta")
        }
    }

    /// Shared by both attach routes: a pointing device exists, so the drawn
    /// cursor should follow relative motion and the toolbar should offer the
    /// lock button. Says nothing about whether the device REPORTS.
    private func noteMousePresent() {
        mouseConnected = true
        // The drawn cursor arrow follows relative motion only while a real mouse
        // is driving it — see winios_cursor_track_relative.
        winios_cursor_track_relative(1)
        startTicker()
        armAssistiveTouchHint()          // ml665
    }

    private func detachMouse(_ mouse: GCMouse?) {
        if let mouse { attachedMice.remove(ObjectIdentifier(mouse)) }
        heldButtons.removeAll()
        InputGuard.shared.release(mouseOwner)
        let remaining = GCMouse.mice()
        // The UIKit path does not go away with a GCMouse object — it never
        // depended on one. Only a GC-less AND UIKit-less state is "no mouse".
        mouseConnected = !remaining.isEmpty || uikitSeen
        if remaining.isEmpty {
            gcDeltaSeen = false
            attachedMice.removeAll()
            if mousePath == .gcmouse { mousePath = .none; log("mouse path: none") }
            setPointerLocked(false, why: "mouse disconnected")
        }
        if !mouseConnected { winios_cursor_track_relative(0) }
        log("mouse disconnected: \(mouse?.vendorName ?? "?") "
            + "(remaining=\(remaining.count) path=\(mousePath.rawValue))")
    }

    /// GameController reports mouse motion with y pointing UP, like a desk. Wine
    /// (and every Windows mouse) reports y pointing DOWN, like a screen. The one
    /// negation below is that difference and nothing else.
    ///
    /// ml665: runs on `mouseQueue`, not the main thread. Everything below is
    /// either lock-guarded, thread-safe on its own (`winios_pointer`, `fputs`)
    /// or hopped to main.
    private func moved(_ dx: CGFloat, _ dy: CGFloat) {
        let now = CACurrentMediaTime()
        logRaw("gcmouse", dx, dy)
        noteDelivery(now)
        var first = false
        if dx != 0 || dy != 0 {
            motionLock.lock()
            lastGCDeltaAt = now
            if !gcDeltaLive { gcDeltaLive = true; first = true }
            motionLock.unlock()
        }
        // Post BEFORE the main hop: the delta is the thing with a deadline.
        postMotion(dx, -dy)
        if first { DispatchQueue.main.async { [weak self] in self?.firstGCDelta() } }
    }

    /// The one-time consequences of a live HID stream, on the main thread
    /// because every line of it is `@Published` or UIKit.
    private func firstGCDelta() {
        gcDeltaSeen = true
        announcePath(.gcmouse)
        // The hint exists to say "your mouse is not reporting". It is.
        if assistiveTouchHint { assistiveTouchHint = false }
        // NOW lock, and only now: the raw HID stream is proven live, so
        // taking UIKit's pointer away costs nothing and buys containment —
        // deltas that keep arriving past the screen edge. (On iPhone this is
        // refused; see setPointerLocked.)
        setPointerLocked(true, why: "first GCMouse delta")
    }

    /// ml665 — what the delivery pipeline is actually doing, once every 10 s.
    ///
    /// Three numbers decide whether there is anything left to win here:
    ///   • `rate` — AssistiveTouch's own delivery cadence. A mouse reports at
    ///     125-1000 Hz; if this reads ~60/s then the accessibility layer is
    ///     coalescing to the display and no queue change can beat it.
    ///   • `gap mean/max` — jitter. A max far above the mean is a sample that
    ///     waited behind something, which IS ours to fix.
    ///   • `ring coalesced` — deltas merged into an already-queued move because
    ///     wine had not drained yet. Large is FINE and even desirable: it means
    ///     the game receives one summed delta per frame instead of a burst.
    /// Runs on the mouse queue; `motionLock` covers every counter.
    private func noteDelivery(_ now: CFTimeInterval) {
        var line: String?
        motionLock.lock()
        if devWindowStart == 0 {
            devWindowStart = now
            devRingPushed = 0; devRingCoalesced = 0
            winios_q_stats(&devRingPushed, &devRingCoalesced)
        }
        if devLastAt != 0 {
            let gap = now - devLastAt
            devGapSum += gap
            if gap > devGapMax { devGapMax = gap }
        }
        devLastAt = now
        devCount += 1
        let span = now - devWindowStart
        if span >= Self.deliveryWindow {
            var pushed: UInt32 = 0, coalesced: UInt32 = 0
            winios_q_stats(&pushed, &coalesced)
            let gaps = max(devCount - 1, 1)
            line = String(format:
                "delivery %.1fs: events=%d rate=%.1f/s gap mean=%.1fms max=%.1fms "
                + "ring pushed=%u coalesced=%u",
                span, devCount, Double(devCount) / span,
                devGapSum / Double(gaps) * 1000, devGapMax * 1000,
                pushed &- devRingPushed, coalesced &- devRingCoalesced)
            devWindowStart = now; devCount = 0; devGapSum = 0; devGapMax = 0
            devRingPushed = pushed; devRingCoalesced = coalesced
        }
        motionLock.unlock()
        if let line { log(line) }
    }

    /// The single place a screen-down delta becomes wine motion. Shared by the
    /// GCMouse handler and the UIKit fallback so both are scaled by the SAME
    /// `sensMouse` and both carry the truncation remainder.
    ///
    /// ml665: callable from either queue. The carry is the whole reason a
    /// sensitivity below 1.0 works at all — and with AssistiveTouch handing us
    /// FRACTIONAL deltas (0.513, 1.993, -7.301: its own tracking-speed scale is
    /// already applied) it is now load-bearing at sensitivity 1.0 too, so it
    /// must not be torn between two threads.
    private func postMotion(_ dx: CGFloat, _ dy: CGFloat) {
        // One aligned Double read of a value only the slider writes: no tear on
        // arm64, and the worst case is one sample scaled by the old gain.
        let sens = CGFloat(InputSettings.shared.sensMouse)
        motionLock.lock()
        carryX += dx * sens
        carryY += dy * sens
        let ix = Int32(max(-30000, min(30000, carryX)))
        let iy = Int32(max(-30000, min(30000, carryY)))
        carryX -= CGFloat(ix)
        carryY -= CGFloat(iy)
        if ix != 0 || iy != 0 { tickDX += Double(ix); tickDY += Double(iy) }
        motionLock.unlock()
        guard ix != 0 || iy != 0 else { return }
        // RELATIVE, never absolute. The wineserver adds our delta to its own
        // cursor and hands raw input `x - cursor.x`, i.e. exactly our delta,
        // BEFORE any ClipCursor clamping — so aiming never stalls against a
        // screen edge or inside a game's clip rect, and a menu's visible cursor
        // still moves because update_desktop_cursor_pos moved it.
        winios_pointer(ix, iy, F_MOVE, 0)
        bumpTicker()
    }

    /// ml665: the GCMouse button handlers run on `mouseQueue`, and `InputGuard`
    /// is a plain-dictionary main-thread object. Motion is posted directly
    /// because the ring behind `winios_pointer` takes its own mutex; a BUTTON
    /// goes through InputGuard's ownership union, so it hops.
    ///
    /// The timestamp is taken HERE, on the mouse queue, before the hop: it is
    /// what `shouldIgnore` compares an incoming `.direct` touch against, and a
    /// synthesised touch arrives within milliseconds of the click.
    private func button(_ b: Int, _ pressed: Bool) {
        motionLock.lock(); lastGCButtonAt = CACurrentMediaTime(); motionLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if pressed { self.heldButtons.insert(b) } else { self.heldButtons.remove(b) }
            InputGuard.shared.hold(self.mouseOwner, buttons: self.heldButtons)
            self.startTicker()
        }
    }

    // MARK: - ml665: telling an AssistiveTouch click from a finger

    /// True while a real mouse is in the user's hand: the GCMouse path won, and
    /// a delta arrived inside the last `mouseActiveWindow` seconds. Anything
    /// `.direct` that lands during that window is AssistiveTouch's synthesised
    /// click, not a finger — the hand is on the mouse.
    var mouseActive: Bool {
        guard mousePath == .gcmouse else { return false }
        motionLock.lock(); let t = lastGCDeltaAt; motionLock.unlock()
        return t != 0 && CACurrentMediaTime() - t < Self.mouseActiveWindow
    }

    /// Classify one touch and say whether the caller must drop it.
    ///
    /// THE HEURISTIC, and how it is validated. AssistiveTouch synthesises its
    /// click as a `.direct` touch with no contact patch — `majorRadius` comes
    /// back at (or within rounding of) zero, where a real fingertip measures
    /// roughly 10-30 points. The second signal is timing: the synthesised touch
    /// lands within a few milliseconds of the GCMouse button transition for the
    /// same physical click, so a `.direct` touch arriving inside
    /// `buttonCoincidence` of one is the same click seen twice. Either signal
    /// is enough; the first 30 classifications are logged with BOTH numbers so
    /// the device log says which one is carrying the decision.
    ///
    /// `logging:` is passed true only for touch-DOWNs — a drag would otherwise
    /// spend the 30-line budget in a quarter of a second.
    @discardableResult
    func shouldIgnore(_ t: UITouch, logging: Bool) -> Bool {
        let radius = Double(t.majorRadius)
        motionLock.lock(); let btnAt = lastGCButtonAt; motionLock.unlock()
        let dt = btnAt == 0 ? Double.infinity : CACurrentMediaTime() - btnAt
        // `.indirectPointer` is the OTHER pipeline (ml664) and is handled by its
        // own recognisers; only a `.direct` touch can be an AssistiveTouch click.
        let synthesised = t.type == .direct
            && (radius <= Self.fingerRadiusFloor || dt < Self.buttonCoincidence)
        if logging, touchClassLogged < 30, mouseConnected {
            touchClassLogged += 1
            log(String(format: "touch classified %@ radius=%.2f dt=%@ type=%d active=%@",
                       synthesised ? "synthesized" : "finger", radius,
                       dt.isFinite ? String(format: "%.0fms", dt * 1000) : "never",
                       t.type.rawValue, mouseActive ? "yes" : "no"))
        }
        guard synthesised, mouseActive, InputSettings.shared.ignoreTouchesWithMouse
        else { return false }
        return true
    }

    /// A real fingertip's contact patch never measures this small; a synthesised
    /// touch has no patch at all.
    private static let fingerRadiusFloor: Double = 1.0
    /// A `.direct` touch this close behind a GCMouse button change is that same
    /// click arriving a second time.
    private static let buttonCoincidence: CFTimeInterval = 0.050

    /// Set-level convenience for the four `touches*` overrides: true when EVERY
    /// touch in the event is synthesised, which is the only case where dropping
    /// the whole callback is safe.
    func shouldIgnore(_ touches: Set<UITouch>, logging: Bool) -> Bool {
        guard !touches.isEmpty else { return false }
        var all = true
        for t in touches where !shouldIgnore(t, logging: logging) { all = false }
        return all
    }

    /// The banner's dismiss button. Once per session, as promised.
    func dismissAssistiveTouchHint() {
        guard assistiveTouchHint else { return }
        assistiveTouchHint = false
        HardwareInput.hintRect = .zero
        log("assistive-touch hint dismissed")
    }

    /// ml665 — a mouse is enumerated. If nothing comes out of it within ten
    /// seconds, the user needs to be told the one thing that fixes it, because
    /// no amount of app-side work can: on iPhone the OS routes pointer devices
    /// through AssistiveTouch and nowhere else.
    private func armAssistiveTouchHint() {
        guard !hintArmed, UIDevice.current.userInterfaceIdiom == .phone else { return }
        hintArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self, !self.gcDeltaSeen, self.mouseConnected else { return }
            self.assistiveTouchHint = true
            self.log("assistive-touch hint shown: mouse enumerated, no GCMouse "
                     + "delta in 10s — AssistiveTouch is the only pointer path on iPhone")
        }
    }

    // MARK: - UIKit indirect-pointer fallback (ml664)
    //
    // Called from MetalBackedView's hover / pan recognisers and its
    // indirect-pointer touches. Deltas are already screen-down and in view
    // POINTS; they go through the same `postMotion` and the same `sensMouse` as
    // the GCMouse path, so the two feel identical and neither can drift.
    //
    // BEST-EFFORT, and honestly so. An unlocked iOS pointer is clamped to the
    // screen: push it into the left edge and it stops, so the hover deltas stop
    // with it and the in-game view stops turning until the user pulls back.
    // There is no iOS API to re-centre or warp the system pointer (the macOS
    // CGWarpMouseCursorPosition has no iOS counterpart), and
    // `prefersPointerLocked` — the real fix — is exactly what kills this
    // pipeline. So: the GCMouse + pointer-lock path is the complete solution
    // where the OS provides it, and this is what a device without it gets.

    /// A pointer delta from UIKit, in view points, y already screen-down.
    func uikitMoved(_ dx: CGFloat, _ dy: CGFloat, src: String) {
        guard !gcDeltaSeen else { return }      // the HID stream owns it
        guard dx != 0 || dy != 0 else { return }
        logRaw(src, dx, dy)
        noteUIKitPointer()
        postMotion(dx, dy)
    }

    /// The complete set of buttons UIKit says are down, declared rather than
    /// edged — same model as every other InputGuard owner, so a chord that
    /// loses one of its transitions still converges.
    func uikitButtons(_ want: Set<Int>) {
        guard !gcDeltaSeen else { return }
        guard want != heldButtons else { return }
        if !want.isEmpty { noteUIKitPointer() }
        heldButtons = want
        InputGuard.shared.hold(mouseOwner, buttons: want)
        startTicker()
    }

    /// Scroll from UIKit, in view points. 14pt per notch — the same ratio the
    /// on-screen two-finger scroll uses, so the two agree.
    func uikitScroll(_ dxPoints: CGFloat, _ dyPoints: CGFloat) {
        guard !gcDeltaSeen else { return }
        guard dxPoints != 0 || dyPoints != 0 else { return }
        noteUIKitPointer()
        scrolled(Double(dxPoints) / 14.0, Double(dyPoints) / 14.0)
    }

    private func noteUIKitPointer() {
        guard !uikitSeen else { return }
        uikitSeen = true
        noteMousePresent()
        announcePath(.uikit)
    }

    /// ml665: reached from the mouse queue (GCMouse scroll) and from main
    /// (`uikitScroll`). The accumulators decide how many notches to emit, so
    /// the decision is made under the lock and the notches are posted after it.
    private func scrolled(_ x: Double, _ y: Double) {
        var notches: [(UInt32, Int32)] = []
        let n = HardwareInput.scrollNotch
        motionLock.lock()
        scrollAccumY += y
        scrollAccumX += x
        while scrollAccumY >= n { scrollAccumY -= n; notches.append((F_WHEEL, 120)) }
        while scrollAccumY <= -n { scrollAccumY += n; notches.append((F_WHEEL, -120)) }
        while scrollAccumX >= n { scrollAccumX -= n; notches.append((F_HWHEEL, 120)) }
        while scrollAccumX <= -n { scrollAccumX += n; notches.append((F_HWHEEL, -120)) }
        tickWheel += notches.count
        motionLock.unlock()
        for (flags, delta) in notches {
            winios_pointer(0, 0, flags, UInt32(bitPattern: delta))
        }
        if !notches.isEmpty { bumpTicker() }
    }

    // MARK: - pointer lock

    func togglePointerLock() {
        setPointerLocked(!pointerLocked, why: "toggle")
    }

    private func setPointerLocked(_ on: Bool, why: String) {
        // Locking with no mouse attached would hide a pointer that does not
        // exist and give nothing back.
        var want = on && mouseConnected
        // ========================================================================
        // ml665 — POINTER LOCK DOES NOT EXIST ON iPhone.
        //
        // `prefersPointerLocked` is an iPad mechanism. iPhone has no system
        // pointer to lock: the cursor on screen belongs to AssistiveTouch, which
        // is an accessibility feature, not UIKit's pointer, and it ignores the
        // preference entirely. There is no API that reports this — the override
        // installs fine, `setNeedsUpdateOfPrefersPointerLocked` returns happily,
        // and the cursor keeps moving — so the idiom check IS the detection.
        //
        // Nothing is lost by not locking. Lock buys CONTAINMENT, and GCMouse
        // deltas are raw HID reports: they keep arriving unchanged while the
        // AssistiveTouch cursor sits clamped against a screen edge. (Verify in
        // the log: `raw gcmouse` lines and non-zero `mouse_dx` on the 1 Hz line
        // while the cursor is parked in a corner. If they ever stop, the
        // accessibility layer is gating on cursor movement and this is a real
        // limitation rather than a cosmetic one.) What IS lost is the hidden
        // cursor, which `PointerHider` handles separately, and that the cursor
        // can drift over the app's own chrome — mitigated instead by ml665's
        // synthesised-touch filter, which stops it PRESSING anything.
        // ========================================================================
        if want, !Self.pointerLockAvailable {
            if !phoneLockNoted {
                phoneLockNoted = true
                log("pointer lock: unavailable on iPhone (AssistiveTouch pointer); "
                    + "relying on GCMouse deltas")
            }
            want = false
        }
        // ml664: and locking while the UIKit path is the one carrying the mouse
        // would END it. `prefersPointerLocked` stops UIKit pointer delivery —
        // hover, indirect-pointer touches, scroll, all of it — and on a device
        // where GCMouse reports nothing there is then no mouse at all. Refuse,
        // loudly, rather than silently trading a working mouse for containment.
        if want, mousePath == .uikit {
            log("pointer lock REFUSED (\(why)): path=uikit — locking would stop "
                + "UIKit pointer delivery and this device has no GCMouse stream")
            want = false
        }
        guard want != pointerLocked else { return }
        pointerLocked = want
        PointerLock.refresh()
        log("pointer lock \(want ? "ON" : "OFF") (\(why)) path=\(mousePath.rawValue)")
    }

    // ========================================================================
    // MARK: - ml668 — THE GAMEPAD
    //
    // A controller paired to the phone has to reach the game by TWO roads at
    // once, and they are not alternatives:
    //
    //   1. XInput. Everything written after about 2006 asks XInput for a pad,
    //      and for those titles the right answer is to BE the pad. The sampler
    //      below writes an XINPUT_GAMEPAD-shaped struct into a shared slot
    //      (Winios.m, `winios_gamepad_set_state`), win32u reads it through one
    //      syscall, and wine's xinput1_3 hands it to the game. Nothing about
    //      the user's on-screen layout is involved: the game gets the raw pad.
    //
    //   2. The on-screen layout. Most of what this port actually runs is older
    //      than XInput and reads the keyboard and the mouse. For those, a
    //      controller is useless unless something turns its buttons into the
    //      keys they DO read — which is exactly what the landscape control
    //      layout already does for a thumb. So each control can name a physical
    //      button (`TouchControl.padBinding`), and pressing that button presses
    //      that control through the SAME `InputGuard` ownership path a finger
    //      uses: `ControlOverlayView.padPress` takes an owner, holds the
    //      control's own `ControlRegionKind`, and lights its face.
    //
    // BOTH AT ONCE IS CORRECT, not a conflict. It is what a PC with a
    // controller and a key remapper does, and a game can only notice if it
    // reads XInput *and* the keyboard for the same action — in which case the
    // user unbinds the control, which is what the panel is for.
    //
    // WHY 250 Hz AND WHY NOT A DISPLAY LINK. XInput's contract is a STATE that
    // is current when you ask; a game may poll it at 1 kHz, and a pad sampled
    // at the display's 60 Hz would hand that game the same sample sixteen times
    // and then jump. `CADisplayLink` cannot exceed the refresh rate, so it is
    // the wrong clock here however convenient it is elsewhere: a
    // `DispatchSourceTimer` at 4 ms on a dedicated `.userInteractive` queue is.
    // `valueChangedHandler` fires on the same queue and samples immediately, so
    // a button transition is never waiting out the rest of a tick.
    //
    // WHY NOT THE MAIN QUEUE. The same reason ml665 moved the mouse off it: a
    // sample queued behind a SwiftUI body evaluation is jitter the user feels.
    // Everything on the pad queue either writes the shared slot (thread-safe by
    // construction, see Winios.h) or hops to main — and the hop happens only
    // when something CHANGED, which for buttons is rare and for sticks is
    // throttled to 120 Hz, because `AimStickDriver` consumes its vector on a
    // display link and cannot use anything faster.
    // ========================================================================

    /// One XInput user index per connected controller, in connection order.
    /// Written on main (connect/disconnect), read on `padQueue`.
    private var padSlots: [GCController?] = [nil, nil, nil, nil]

    // ml671 — THE PROFILE IS CAPTURED, NOT RE-FETCHED.
    //
    // This used to read `slots[i]?.extendedGamepad` on the sampling queue,
    // every 4 ms, and `.map` a nil result into a nil sample. A nil there is
    // indistinguishable from "no pad": the loop `continue`d, the slot was never
    // published, `winios_gamepad_get_state` kept answering "not connected", and
    // the 10 s line still printed `src=phys` — because that field only ever
    // tested `padSlots[0] != nil`, which was true the whole time. So a pad that
    // enumerated, logged "connected", and then reported NOTHING looked exactly
    // like a pad that was connected and sitting perfectly centred.
    //
    // Capturing the profile once, on the main thread, at attach removes the
    // per-sample optional entirely — the profile object lives as long as the
    // controller does, and this is how Apple's own samples poll a pad. It is
    // also cheaper. And `padProfileMissing` below makes the remaining failure
    // say its own name instead of impersonating a centred stick.
    private var padProfiles: [GCExtendedGamepad?] = [nil, nil, nil, nil]
    /// ml671 — slot 0's UNCONVERTED reading, for the 1 Hz line. Guarded by
    /// `padLock` rather than carried on the main hop, because the hop only
    /// happens when the SNAPSHOT changes: a pad whose axes are stuck at zero
    /// would never hop, and the one line that could prove it would never be
    /// written. One uncontended lock per sample is not a cost worth having an
    /// unanswerable bug for.
    private var padRawMirror = PadRaw()
    private let padLock = NSLock()

    /// The sampling clock's queue. Serial, `.userInteractive`, and also the
    /// `handlerQueue` of every attached controller, so a value-changed callback
    /// and a timer tick can never interleave mid-sample.
    private let padQueue = DispatchQueue(label: "madeira.hwinput.pad",
                                         qos: .userInteractive)
    /// padQueue only.
    private var padTimer: DispatchSourceTimer?
    private var padPackets = [UInt32](repeating: 0, count: 4)
    private var padLastPublished = [PadSnapshot](repeating: PadSnapshot(), count: 4)
    private var padLastApplied = PadSnapshot()
    private var padLastStickHop: CFTimeInterval = 0
    /// ml6xx — see the banner on `padDriveBindings`: the right stick's feed
    /// into `AimStickDriver` cannot rely on "the quantised sample changed"
    /// alone, or a return-to-centre that happens to land on a repeated
    /// Int16 latches the last real deflection forever. This is the clock
    /// for that keepalive. padQueue only.
    private var padLastAimReconcile: CFTimeInterval = 0
    /// The last vector THIS app told `AimStickDriver` about, MAIN THREAD
    /// only, purely for the `[padmouse]` diagnostic lines below —
    /// `AimStickDriver`'s own summed vector is private, and may also be
    /// carrying an on-screen touch's contribution this app cannot see.
    private var padLastAimVec: CGSize = .zero
    /// Rate limit for the "fed a non-zero vector" line, MAIN THREAD only —
    /// otherwise a held stick would print at whatever rate the 120 Hz
    /// stick-hop throttle allows.
    private var padLastAimLogAt: CFTimeInterval = 0
    private var padStatAt: CFTimeInterval = 0
    /// MAIN-THREAD mirror of the last sample the bindings acted on, for the
    /// 1 Hz line. `padLastApplied` itself belongs to the pad queue and reading
    /// it from `tick()` would be a plain race over a struct.
    private var padUIState = PadSnapshot()

    /// ml671 — the UNCONVERTED GameController reading.
    ///
    /// Kept beside the XInput-unit snapshot for exactly one reason: when a pad
    /// reports nothing, the only question worth answering is whether
    /// GameController handed us zeros or whether WE turned real numbers into
    /// zeros — and no amount of Int16 logging can separate those two. The
    /// floats go on the 1 Hz line as `lxf=`/`lyf=`/`rxf=`/`ryf=`.
    struct PadRaw: Equatable {
        var lxf: Float = 0, lyf: Float = 0
        var rxf: Float = 0, ryf: Float = 0
        var ltf: Float = 0, rtf: Float = 0
        var buttons: UInt16 = 0

        /// Is any AXIS saying anything at all? Buttons deliberately excluded:
        /// the whole question this answers is about the analogue half.
        var axesQuiet: Bool {
            lxf == 0 && lyf == 0 && rxf == 0 && ryf == 0 && ltf == 0 && rtf == 0
        }
    }

    /// One pad's readings, in XInput units. Deliberately a value type: it is
    /// built on the pad queue, compared there, and carried to the main queue by
    /// copy, so there is nothing for the two threads to share.
    struct PadSnapshot: Equatable {
        var buttons: UInt16 = 0
        var lt: UInt8 = 0, rt: UInt8 = 0
        var lx: Int16 = 0, ly: Int16 = 0
        var rx: Int16 = 0, ry: Int16 = 0
    }

    // ml671 — the axis probe. padQueue only, except the three writes in
    // attachController, which happen before the timer for that slot can run.
    private var padAxisProbeAt = [CFTimeInterval](repeating: 0, count: 4)
    private var padAxisSeen = [Bool](repeating: false, count: 4)
    private var padProfileWarned = [Bool](repeating: false, count: 4)
    private var padSampleCount = [UInt32](repeating: 0, count: 4)
    /// Cumulative count of samples where `readRaw` saw ANY axis non-zero,
    /// alongside `padSampleCount` on the 10 s line — the number that
    /// separates "the stick never reported motion" from "it did, and
    /// something downstream dropped it on the floor".
    private var padAxisEvents = [UInt32](repeating: 0, count: 4)

    private func xlog(_ s: String) {
        fputs("[xinput] \(s)\n", stderr)
    }

    /// A slot holds a controller but no profile to read it through. One line
    /// per slot per connection — this is the failure that used to look like a
    /// centred stick, and it must never be silent again.
    private func padProfileMissing(_ i: Int) {
        guard !padProfileWarned[i] else { return }
        padProfileWarned[i] = true
        xlog("pad\(i) HAS NO EXTENDED PROFILE — the controller is enumerated but "
             + "nothing can be read from it; the slot stays unpublished and every "
             + "XInputGetState will answer ERROR_DEVICE_NOT_CONNECTED")
    }

    /// The two lines that end an "is it the pad or is it us?" argument: the
    /// first time any axis moves, and a one-shot complaint if none ever does.
    private func padAxisProbe(_ i: Int, _ raw: PadRaw) {
        if !raw.axesQuiet {
            guard !padAxisSeen[i] else { return }
            padAxisSeen[i] = true
            xlog(String(format: "pad%d first axis motion lxf=%.4f lyf=%.4f "
                                + "rxf=%.4f ryf=%.4f ltf=%.3f rtf=%.3f "
                                + "(after %u samples)",
                        i, raw.lxf, raw.lyf, raw.rxf, raw.ryf, raw.ltf, raw.rtf,
                        padSampleCount[i]))
            return
        }
        // Quiet, and it has been quiet since the pad appeared. Say so ONCE,
        // five seconds in: by then the user has certainly touched something, so
        // "every axis still reads exactly 0.0" is a finding and not a wait.
        guard !padAxisSeen[i], padAxisProbeAt[i] != 0,
              CACurrentMediaTime() - padAxisProbeAt[i] >= 5.0 else { return }
        padAxisProbeAt[i] = 0
        xlog(String(format: "pad%d ANALOGUE SILENCE: %u samples in 5s and every "
                            + "axis float is exactly 0.0 (buttons=0x%04x). The "
                            + "conversion is not the suspect -- GameController "
                            + "itself is reporting nothing on this profile's "
                            + "thumbsticks and triggers.",
                    i, padSampleCount[i], Int(raw.buttons)))
    }

    private func attachController(_ c: GCController?) {
        guard let c else { return }
        guard let gp = c.extendedGamepad else {
            // A controller with no extended profile is a remote or a
            // micro-gamepad: no second stick, no triggers, nothing XInput can
            // be built out of. Say so rather than fail silently.
            log("controller ignored: \(c.vendorName ?? "?") has no extended gamepad profile")
            return
        }

        padLock.lock()
        var slot = padSlots.firstIndex(where: { $0 === c })
        if slot == nil { slot = padSlots.firstIndex(where: { $0 == nil }) }
        if let i = slot { padSlots[i] = c; padProfiles[i] = gp }   // ml671
        padLock.unlock()

        guard let i = slot else {
            xlog("no free user index for \(c.vendorName ?? "?") (4 pads already)")
            return
        }

        // NOT `.main` — see the banner. The handler only samples; everything
        // that touches SwiftUI or InputGuard hops from inside padSample().
        c.handlerQueue = padQueue
        gp.valueChangedHandler = { [weak self] _, _ in self?.padSample() }

        gamepadConnected = true
        padAxisProbeAt[i] = CACurrentMediaTime()
        padAxisSeen[i] = false
        padProfileWarned[i] = false
        padStartSampling()
        startTicker()
        // ml671: name the analogue elements at connect. A pad whose sticks never
        // move is a different fault from a pad that has no sticks, and this line
        // is what tells them apart before a single sample is taken.
        xlog("pad\(i) connected vendor=\(c.vendorName ?? "?") profile=extended "
             + "sticks=\(gp.leftThumbstick.xAxis.value == 0 && gp.leftThumbstick.yAxis.value == 0 ? "centred" : "deflected") "
             + "l3=\(gp.leftThumbstickButton != nil) r3=\(gp.rightThumbstickButton != nil) "
             + "options=\(gp.buttonOptions != nil)")
    }

    private func detachController(_ c: GCController?) {
        let live = GCController.controllers()
        var freed: [Int] = []

        padLock.lock()
        for i in padSlots.indices {
            guard let s = padSlots[i] else { continue }
            // Either this is the controller that went away, or it is one the
            // framework no longer lists — a disconnect notification names one
            // device and we have no guarantee it names every device that left.
            if s === c || !live.contains(where: { $0 === s }) {
                padSlots[i] = nil
                padProfiles[i] = nil                                // ml671
                freed.append(i)
            }
        }
        let remaining = padSlots.contains { $0 != nil }
        padLock.unlock()

        for i in freed {
            // Clear the slot BEFORE anything else: a game polling right now
            // must see ERROR_DEVICE_NOT_CONNECTED, not the last sample forever.
            winios_gamepad_set_state(Int32(i), nil)
            xlog("pad\(i) disconnected")
        }
        gamepadConnected = remaining
        if !remaining {
            // ml670: the sampler is slot 0's clock for the ON-SCREEN half too,
            // so it only stands down when neither source is left. Without this
            // guard, unplugging a controller would silently kill the virtual
            // one that is still on the screen.
            if OnScreenPad.shared.isLive {
                padQueue.async { [weak self] in self?.padSample() }
            } else {
                padStopSampling()
            }
            // A button physically held when the battery died sends no up.
            ControlOverlayView.shared.padReleaseAll("pad disconnected")
        }
    }

    private func padStartSampling() {
        padQueue.async { [weak self] in
            guard let self, self.padTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.padQueue)
            // 4 ms with 1 ms leeway: the leeway is what lets the OS coalesce
            // this timer with whatever else is waking the core, which matters
            // on a phone in a way it never does on a desktop.
            t.schedule(deadline: .now(), repeating: .milliseconds(4),
                       leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.padSample() }
            self.padTimer = t
            t.resume()
        }
    }

    private func padStopSampling() {
        padQueue.async { [weak self] in
            self?.padTimer?.cancel()
            self?.padTimer = nil
        }
    }

    // ========================================================================
    // ml670 — THE ON-SCREEN CONTROLLER JOINS SLOT 0
    //
    // THE MERGE RULE, and why each half of it is what it is.
    //   buttons  OR.   Two sources cannot disagree about a bit: either says
    //                  pressed and it is pressed. This is also what a PC does
    //                  with two XInput devices merged by a remapper.
    //   triggers MAX.  Analogue, and a partially-pulled physical trigger must
    //                  not cancel a fully-held on-screen one.
    //   sticks   PHYSICAL WINS past its deadzone, else on-screen. NOT summed:
    //            summing two sources that both rest near zero produces drift
    //            with no user input at all, and a real thumb on a real stick is
    //            unambiguously the more specific intent. Below the deadzone the
    //            physical stick is saying nothing, so the screen gets it.
    //
    // THE PACKET INVARIANT IS UNTOUCHED: the bump is still `merged != last
    // published`, so a game's `dwPacketNumber` still ticks on change and only
    // on change — which is the one optimisation that field exists for.
    // ========================================================================

    /// The layout gained or lost its last virtual-controller control. Called
    /// from `OnScreenPad.setPresent` on the main thread.
    func padScreenPresence(_ present: Bool) {
        if present {
            padStartSampling()
            startTicker()
            xlog("pad0 on-screen source armed (physical=\(gamepadConnected ? "yes" : "no"))")
        } else if !gamepadConnected {
            padStopSampling()
            // Clear the slot BEFORE standing the timer down, or the last merged
            // sample would sit there forever reading as a connected pad.
            padQueue.async { [weak self] in
                winios_gamepad_set_state(0, nil)
                self?.padLastPublished[0] = PadSnapshot()
            }
            xlog("pad0 on-screen source gone, slot cleared")
        } else {
            // A physical pad is still there; one more sample re-publishes it
            // without the on-screen half.
            padQueue.async { [weak self] in self?.padSample() }
        }
    }

    /// An on-screen transition. Publish NOW rather than on the next 4 ms tick:
    /// a button press that waits out a tick is a button press a 1 kHz-polling
    /// game can miss entirely at the start of a frame.
    func padScreenChanged() {
        padQueue.async { [weak self] in self?.padSample() }
    }

    /// One sample of every connected pad, plus slot 0's on-screen half.
    /// padQueue only.
    private func padSample() {
        padLock.lock()
        let slots = padSlots
        let profiles = padProfiles
        padLock.unlock()
        let screen = OnScreenPad.shared.snapshot()

        for i in 0..<slots.count {
            // ml671: the CAPTURED profile, not a fresh `controller.extendedGamepad`
            // on this queue. See the banner on `padProfiles`.
            var phys: PadSnapshot?
            if let gp = profiles[i] {
                padSampleCount[i] &+= 1
                let raw = Self.readRaw(gp)
                if !raw.axesQuiet { padAxisEvents[i] &+= 1 }
                if i == 0 {
                    padLock.lock(); padRawMirror = raw; padLock.unlock()
                }
                padAxisProbe(i, raw)
                phys = Self.snapshot(raw)
            } else if slots[i] != nil {
                padProfileMissing(i)
            }
            // Slot 0 is the one the layout can reach: wine presents it as
            // XInput user 0, and two people cannot share one on-screen layout.
            let useScreen = (i == 0 && screen.live)
            guard phys != nil || useScreen else { continue }
            let snap = useScreen ? Self.mergePad(physical: phys, screen: screen.sample)
                                 : phys!

            if snap != padLastPublished[i] {
                padLastPublished[i] = snap
                padPackets[i] &+= 1
            }
            var st = winios_gamepad()
            st.connected = 1
            st.buttons = snap.buttons
            st.left_trigger = snap.lt
            st.right_trigger = snap.rt
            st.lx = snap.lx; st.ly = snap.ly
            st.rx = snap.rx; st.ry = snap.ry
            // The slot owns the packet number and only bumps it on a real
            // change, so publishing every sample is free and keeps the
            // connected flag alive without a second code path.
            winios_gamepad_set_state(Int32(i), &st)

            // The on-screen BINDINGS (ml668, a physical button pressing a
            // key control) follow the PHYSICAL sample only — feeding them the
            // merged one would make an on-screen A press its own bound control
            // and, through a default binding, itself.
            if i == 0, let p = phys { padDriveBindings(p) }
        }

        let now = CACurrentMediaTime()
        if now - padStatAt >= 10.0,
           slots.contains(where: { $0 != nil }) || profiles.contains(where: { $0 != nil })
               || screen.live {
            padStatAt = now
            let s0 = padLastPublished[0]
            padLock.lock(); let raw0 = padRawMirror; padLock.unlock()
            // ml671: `src` used to be derived from `padSlots[0] != nil` alone,
            // so it said "phys" for a slot that had never been read. It now
            // reports the PROFILE, which is the thing samples actually come
            // from, and carries the raw floats beside the converted ints so the
            // two can be compared without a second run.
            let src = profiles[0] != nil ? (screen.live ? "both" : "phys")
                                         : (screen.live ? "screen"
                                            : (slots[0] != nil ? "noprofile" : "none"))
            // ml671 — READ THE SLOT BACK, and report what a GAME would get.
            //
            // Everything else on this line is what the app BELIEVES it
            // published. This is the bytes `XInputGetState` will actually
            // return, fetched through the very same `winios_gamepad_get_state`
            // that win32u's `ios_gamepad_query` calls — an xinput-x86.exe run
            // performed from inside the app, once every ten seconds. If
            // `got=no` while `samples=` is climbing, the sampler is running and
            // the publish is not landing, which no amount of app-side state can
            // tell you on its own.
            var back = winios_gamepad()
            let got = winios_gamepad_get_state(0, &back) != 0
            xlog(String(format: "pad0 packets=%u samples=%u axis_events=%u "
                                + "last_buttons=0x%04x "
                                + "lx=%d ly=%d lxf=%.4f lyf=%.4f rxf=%.4f ryf=%.4f "
                                + "src=%@ slot(got=%@ packet=%u buttons=0x%04x lx=%d ly=%d)",
                        padPackets[0], padSampleCount[0], padAxisEvents[0],
                        Int(s0.buttons),
                        Int(s0.lx), Int(s0.ly),
                        raw0.lxf, raw0.lyf, raw0.rxf, raw0.ryf, src,
                        got ? "yes" : "no", back.packet, Int(back.buttons),
                        Int(back.lx), Int(back.ly)))
        }
    }

    /// XInput's own left/right thumb deadzone constants. Used here — and only
    /// here — as the "is the physical stick saying anything at all?" test that
    /// decides which source owns that stick this sample. A game's own deadzone
    /// is still its own business (see `read`: nothing is pre-clamped).
    private static let leftThumbDeadzone: Double = 7849
    private static let rightThumbDeadzone: Double = 8689

    static func mergePad(physical p: PadSnapshot?, screen s: PadSnapshot) -> PadSnapshot {
        guard let p else { return s }
        var m = PadSnapshot()
        m.buttons = p.buttons | s.buttons
        m.lt = max(p.lt, s.lt)
        m.rt = max(p.rt, s.rt)
        // ml671 — THE FALLBACK MUST NOT DESTROY A SMALL REAL DEFLECTION.
        //
        // This used to be a plain two-way choice: physical past its deadzone,
        // otherwise the screen. That silently zeroed every physical deflection
        // under 24% of full travel (7849/32767) whenever an on-screen stick
        // existed at all — including a resting one, whose contribution is zero.
        // A slow walk on a real stick therefore became no walk.
        //
        // Three-way instead, and the order is the order of specificity: a real
        // stick past its deadzone wins; failing that, a screen stick that is
        // ACTUALLY DEFLECTED wins, because the thumb on it is the live intent;
        // failing that, whatever the physical stick says, however small.
        if hypot(Double(p.lx), Double(p.ly)) > leftThumbDeadzone || (s.lx == 0 && s.ly == 0) {
            m.lx = p.lx; m.ly = p.ly
        } else {
            m.lx = s.lx; m.ly = s.ly
        }
        if hypot(Double(p.rx), Double(p.ry)) > rightThumbDeadzone || (s.rx == 0 && s.ry == 0) {
            m.rx = p.rx; m.ry = p.ry
        } else {
            m.rx = s.rx; m.ry = s.ry
        }
        return m
    }

    /// Decide whether this sample is worth a main-queue hop, and make it.
    /// padQueue only.
    ///
    /// ml6xx — THE RIGHT STICK IS NOT ALLOWED TO GO STALE.
    //
    // `AimStickDriver`'s CADisplayLink keeps posting whatever vector it was
    // last handed, every frame, for as long as it runs — there is no "stop"
    // signal separate from a fresh `padAim` call carrying a smaller (or
    // zero) vector. Gating that call purely on "did the quantised Int16
    // change since the sample we last acted on" is correct for buttons and
    // the left stick: nothing to redo while they repeat. For the right
    // stick it is not: if the ONE sample where the stick's return to centre
    // finishes happens to land on the same Int16 as the sample before it —
    // which Int16 quantisation of a continuous float, or a physically
    // imperfect centre detent, both make easy — this function goes quiet
    // and the LAST real deflection drives the mouse forever. That is
    // exactly what a report of "the camera is being forced up" with no
    // thumb on the stick looks like: a holder `AimStickDriver` was never
    // told to release.
    //
    // So the right stick also gets a time-based keepalive, independent of
    // whether its quantised sample changed: at least once every 200 ms the
    // CURRENT sample is re-applied regardless. That costs nothing while a
    // controller sits idle (5 Hz, and `applyPadBindings` is idempotent when
    // nothing is actually held) and turns "stuck forever" into "stuck for
    // at most a fifth of a second" in the worst case this cannot rule out.
    private func padDriveBindings(_ snap: PadSnapshot) {
        let last = padLastApplied
        // A trigger is analogue, so "changed" for a BINDING means it crossed
        // the press threshold — otherwise a resting trigger's last-bit noise
        // would hop every 4 ms.
        let buttonsMoved = snap.buttons != last.buttons
            || Self.triggerOn(snap.lt) != Self.triggerOn(last.lt)
            || Self.triggerOn(snap.rt) != Self.triggerOn(last.rt)
        let sticksMoved = snap.lx != last.lx || snap.ly != last.ly
            || snap.rx != last.rx || snap.ry != last.ry
        let now = CACurrentMediaTime()
        let aimKeepaliveDue = now - padLastAimReconcile >= 0.2
        guard buttonsMoved || sticksMoved || aimKeepaliveDue else { return }

        if !buttonsMoved && sticksMoved {
            // Stick-only motion: AimStickDriver consumes its vector on a
            // display link and the dirstick only changes on an 8-way boundary,
            // so anything past 120 Hz is thrown away on arrival.
            guard now - padLastStickHop >= 1.0 / 120.0 else { return }
            padLastStickHop = now
        }
        padLastAimReconcile = now
        padLastApplied = snap
        DispatchQueue.main.async { [weak self] in
            self?.padUIState = snap
            self?.applyPadBindings(snap)
        }
    }

    /// Press, release and steer the bound landscape controls. MAIN THREAD:
    /// `TouchControlsModel`, `ControlOverlayView`, `InputGuard` and
    /// `AimStickDriver` are all main-thread objects.
    private func applyPadBindings(_ s: PadSnapshot) {
        let ov = ControlOverlayView.shared
        let map = Self.bindingMap(TouchControlsModel.shared.controls)

        for b in PadButton.allCases where !b.isStick {
            guard let c = map[b], Self.pressed(b, s) else {
                ov.padRelease(b.rawValue)
                continue
            }
            // ml670: through the model's helper, so the layout-wide size
            // slider moves the deadzone the binding path computes exactly as it
            // moves the one the thumb path computes.
            let d = TouchControlsModel.diameter(c)
            ov.padPress(b.rawValue, region: c.regionID,
                        kind: c.action.regionKind(diameter: d),
                        label: c.action.label)
        }

        // Left stick → the 8-way control it is bound to. Same snap, same quad
        // and the same `stickKeys` the thumb path uses, so a diagonal holds two
        // keys exactly as it does under a finger.
        if let c = map[.leftStick], let quad = c.action.stickKeys {
            ov.padDir(PadButton.leftStick.rawValue, region: c.regionID, quad: quad,
                      dir: Self.snap8(CGFloat(s.lx) / 32767, CGFloat(s.ly) / 32767,
                                      deadzone: 0.35))
        } else {
            ov.padRelease(PadButton.leftStick.rawValue)
        }

        // Right stick → velocity mouse-look. `AimStickDriver` wants y positive
        // DOWN (screen sense); XInput reports y positive UP, hence the one
        // negation. It runs even with no aim control on screen whenever the
        // game is in relative-mouse mode, because in that mode there is nothing
        // else on the phone that can turn the camera with a controller.
        //
        // ml6xx — OPT-IN WHEN A PHYSICAL PAD IS PRESENT. This function only
        // ever runs off a PHYSICAL sample (see `padDriveBindings`'s caller),
        // so reaching here already means a real controller is attached. A
        // 2008-era title that reads that controller through XInput or the
        // DirectInput joystick gets the right stick from wine natively —
        // feeding the SAME stick into the mouse on top of that steers the
        // camera twice (reported as "the camera is being forced up") and
        // drags the game's own menu cursor. So this is now opt-in, default
        // OFF, via `InputSettings.padRightStickMouse`. Turning it off does
        // NOT touch an on-screen mouse-stick control's own touch handling —
        // that is a different path (`ControlOverlayView`'s `.aimStick`
        // region, driven by a finger, not by this function) and keeps
        // working exactly as before.
        let aim = map[.rightStick]
        if InputSettings.shared.padRightStickMouse, aim != nil || InputSettings.shared.relative {
            let v = Self.deflect(CGFloat(s.rx) / 32767, -CGFloat(s.ry) / 32767,
                                 deadzone: 0.15)
            ov.padAim(PadButton.rightStick.rawValue,
                      region: aim?.action.isMouseStick == true ? aim?.regionID : nil,
                      vec: v)
            padLogAim(src: "phys", vec: v)
        } else {
            ov.padRelease(PadButton.rightStick.rawValue)
            padLastAimVec = .zero
        }
    }

    /// MAIN THREAD. The `[padmouse]` diagnostics ml672 asked for: a
    /// rate-limited line whenever this app feeds `AimStickDriver` a
    /// non-zero vector (so "the mouse moved" can be tied to a SOURCE and a
    /// VALUE instead of guessed at), plus a periodic line while the driver
    /// is running at all — which is the one case a stuck vector needs: the
    /// driver keeps posting motion every frame with NOTHING in this log
    /// explaining why unless something says so on a clock, not on an edge.
    private func padLogAim(src: String, vec: CGSize) {
        padLastAimVec = vec
        guard vec != .zero else { return }
        let now = CACurrentMediaTime()
        guard now - padLastAimLogAt >= 0.5 else { return }
        padLastAimLogAt = now
        fputs(String(format: "[padmouse] src=%@ vec=(%.3f,%.3f) holders=%d\n",
                     src, Double(vec.width), Double(vec.height),
                     AimStickDriver.shared.holderCount), stderr)
    }

    /// Which control each physical button presses.
    ///
    /// THE DEFAULTS EXIST BECAUSE A LAYOUT WITH NO BINDINGS IS THE COMMON CASE.
    /// Every layout saved before this feature has none, and a controller that
    /// does nothing until the user has visited an edit panel is a controller
    /// that looks broken. So: if the layout names no button at all, the face
    /// buttons and bumpers fall onto the layout's own buttons in the order they
    /// were created, and the left stick onto its first stick. One explicit
    /// binding anywhere turns the whole default set off — a half-defaulted
    /// layout is the one thing more confusing than no defaults.
    static func bindingMap(_ controls: [TouchControl]) -> [PadButton: TouchControl] {
        var map: [PadButton: TouchControl] = [:]
        for c in controls where c.padBinding != nil { map[c.padBinding!] = c }
        if !map.isEmpty { return map }

        let order: [PadButton] = [.a, .b, .x, .y, .lb, .rb, .start, .back]
        // ml670: a VIRTUAL controller button is never a default binding target.
        // The physical button it would be bound to is already in the merge, so
        // binding it here would press a control that does nothing with the
        // press — and, for the matching button, bind the pad to itself.
        let buttons = controls.filter {
            !$0.action.isStick && !$0.action.isGamepad
                && $0.action != .none && $0.action != .keyboardToggle
        }
        for (i, c) in buttons.enumerated() where i < order.count { map[order[i]] = c }
        if let stick = controls.first(where: { $0.action.stickKeys != nil }) {
            map[.leftStick] = stick
        }
        if let look = controls.first(where: { $0.action.isMouseStick }) {
            map[.rightStick] = look
        }
        return map
    }

    /// Is this button down in that sample? The triggers are analogue and have
    /// no XInput bit; 30/255 is the threshold wine's own xinput1_3 uses for a
    /// trigger keystroke, so a bound trigger and a game reading XInput agree
    /// about when it counts as pressed.
    private static func pressed(_ b: PadButton, _ s: PadSnapshot) -> Bool {
        switch b {
        case .lt: return triggerOn(s.lt)
        case .rt: return triggerOn(s.rt)
        default:  return b.mask != 0 && (s.buttons & b.mask) != 0
        }
    }
    private static func triggerOn(_ v: UInt8) -> Bool { v > 30 }

    /// One GCExtendedGamepad reading, in XInput units.
    ///
    /// NO DEADZONE IS APPLIED. XInput's convention is that the APPLICATION owns
    /// the deadzone — XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE is a constant a game
    /// may use, scale or ignore — and a driver that pre-clamps turns a game's
    /// own handling into a second, wrong clamp on top of ours. The deadzones
    /// further down this file are on the paths where THIS app is the consumer:
    /// the on-screen control bindings.
    private static func readRaw(_ gp: GCExtendedGamepad) -> PadRaw {
        var r = PadRaw()
        var b: UInt16 = 0
        if gp.buttonA.isPressed { b |= PadButton.a.mask }
        if gp.buttonB.isPressed { b |= PadButton.b.mask }
        if gp.buttonX.isPressed { b |= PadButton.x.mask }
        if gp.buttonY.isPressed { b |= PadButton.y.mask }
        if gp.leftShoulder.isPressed  { b |= PadButton.lb.mask }
        if gp.rightShoulder.isPressed { b |= PadButton.rb.mask }
        if gp.leftThumbstickButton?.isPressed  == true { b |= PadButton.l3.mask }
        if gp.rightThumbstickButton?.isPressed == true { b |= PadButton.r3.mask }
        // Menu is Start and Options is Back, which is the mapping every Xbox,
        // PlayStation and MFi pad iOS vends agrees on. `buttonHome` (the Xbox
        // / PS / Guide button) is deliberately NOT reported: iOS reserves it,
        // it is how the user gets out, and XINPUT_GAMEPAD_GUIDE is an
        // undocumented bit only XInputGetStateEx is supposed to expose anyway.
        if gp.buttonMenu.isPressed { b |= PadButton.start.mask }
        if gp.buttonOptions?.isPressed == true { b |= PadButton.back.mask }
        if gp.dpad.up.isPressed    { b |= PadButton.dpadUp.mask }
        if gp.dpad.down.isPressed  { b |= PadButton.dpadDown.mask }
        if gp.dpad.left.isPressed  { b |= PadButton.dpadLeft.mask }
        if gp.dpad.right.isPressed { b |= PadButton.dpadRight.mask }
        r.buttons = b
        r.ltf = gp.leftTrigger.value
        r.rtf = gp.rightTrigger.value
        // ml671 — AND THERE IS NO SECOND ACCESSOR TO TRY.
        //
        // Worth stating, because "read the stick a different way" is the first
        // thing anyone reaches for when a stick reads zero. GCControllerDirection
        // Pad vends exactly `xAxis`/`yAxis` (GCControllerAxisInput) plus the four
        // synthesised `up`/`down`/`left`/`right` buttons — it has no whole-vector
        // property, and `GCController.physicalInputProfile.dpads[...]` hands back
        // THIS SAME OBJECT rather than a second opinion. So if these four floats
        // are zero while the stick is deflected, the value never reached
        // GameController, and no amount of rewriting this function changes it.
        // That is precisely the claim `padAxisProbe` is there to settle.
        r.lxf = gp.leftThumbstick.xAxis.value
        r.lyf = gp.leftThumbstick.yAxis.value
        r.rxf = gp.rightThumbstick.xAxis.value
        r.ryf = gp.rightThumbstick.yAxis.value
        return r
    }

    /// The raw reading in XInput units. Split from `readRaw` so the two can be
    /// logged side by side: the whole point of keeping the floats is to be able
    /// to say which of the two is zero.
    private static func snapshot(_ r: PadRaw) -> PadSnapshot {
        var s = PadSnapshot()
        s.buttons = r.buttons
        s.lt = trigger(r.ltf)
        s.rt = trigger(r.rtf)
        s.lx = axis(r.lxf)
        s.ly = axis(r.lyf)
        s.rx = axis(r.rxf)
        s.ry = axis(r.ryf)
        return s
    }

    /// GameController reports −1…1; XInput reports −32768…32767. Scaling by
    /// 32767 (not 32768) is what makes full deflection land exactly on the
    /// positive limit instead of one count short of it, and the clamp is what
    /// stops a pad that overshoots slightly from wrapping to a full deflection
    /// in the OPPOSITE direction.
    private static func axis(_ v: Float) -> Int16 {
        let s = (Double(v) * 32767.0).rounded()
        return Int16(max(-32768.0, min(32767.0, s)))
    }
    private static func trigger(_ v: Float) -> UInt8 {
        UInt8(max(0.0, min(255.0, (Double(v) * 255.0).rounded())))
    }

    /// 8-way snap in STICK coordinates (y positive UP), returning the same
    /// 0-7 index `ControlOverlayView.snap` produces — 0 is up, clockwise — or
    /// −1 for centred. Shared convention, so a control steered by a thumb and
    /// the same control steered by a stick hold the identical key set.
    private static func snap8(_ x: CGFloat, _ y: CGFloat, deadzone: CGFloat) -> Int {
        let d = (x * x + y * y).squareRoot()
        guard d >= deadzone else { return -1 }
        var a = atan2(x, y) * 180 / .pi            // clockwise from "up"
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    /// Analogue deflection rescaled from the deadzone edge, so the first
    /// countable movement is a crawl and not a jump.
    private static func deflect(_ x: CGFloat, _ y: CGFloat, deadzone: CGFloat) -> CGSize {
        let d = (x * x + y * y).squareRoot()
        guard d > deadzone else { return .zero }
        let m = min((d - deadzone) / (1 - deadzone), 1.0)
        return CGSize(width: x / d * m, height: y / d * m)
    }

    // MARK: - 1 Hz activity line

    /// ml665: `Timer` and `RunLoop.main` are main-thread objects and the mouse
    /// queue is not the main thread. One hop, and only when there is no ticker
    /// yet — the steady state is a bare atomic-ish read.
    private func bumpTicker() {
        if Thread.isMainThread { startTicker(); return }
        // NOT `ticker == nil`: reading a main-thread object reference from the
        // mouse queue is the race this whole revision is about. `tickerArmed`
        // is the lock-guarded mirror, so the steady state costs one uncontended
        // lock and no dispatch at all.
        motionLock.lock(); let armed = tickerArmed; motionLock.unlock()
        guard !armed else { return }
        DispatchQueue.main.async { [weak self] in self?.startTicker() }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        motionLock.lock(); tickerArmed = true; motionLock.unlock()
    }

    private func tick() {
        motionLock.lock()
        let dx = tickDX, dy = tickDY, wheelN = tickWheel
        motionLock.unlock()
        let idle = tickKeys == 0 && wheelN == 0 && dx == 0 && dy == 0
            && heldVKs.isEmpty && heldButtons.isEmpty && !gamepadConnected
        if idle {
            // Nothing moved and nothing is held: stand down rather than print a
            // line a second for the rest of the session.
            ticker?.invalidate(); ticker = nil
            motionLock.lock(); tickerArmed = false; motionLock.unlock()
            return
        }
        let keys = heldVKs.sorted().map { String(format: "%02x", $0) }.joined(separator: ",")
        // ml668: the pad's own held-set belongs to ControlOverlayView now, so
        // what this line can honestly report about it is the RAW sample —
        // which is also the more useful number, because it separates "the pad
        // is not reporting" from "the pad is reporting and nothing is bound".
        let p = padUIState
        // ml671: the RAW floats beside the converted ints. `lx=0 lyf=0.83` is
        // a conversion bug; `lx=0 lyf=0.0` is GameController reporting nothing,
        // and one line now says which. The raw half is lock-guarded rather than
        // hopped, because a pad stuck at zero never changes and so never hops.
        padLock.lock(); let raw = padRawMirror; padLock.unlock()
        let pad = gamepadConnected
            ? String(format: "pad=0x%04x lx=%d ly=%d rx=%d ry=%d "
                             + "lxf=%.3f lyf=%.3f rxf=%.3f ryf=%.3f ltf=%.2f rtf=%.2f",
                     Int(p.buttons), Int(p.lx), Int(p.ly), Int(p.rx), Int(p.ry),
                     raw.lxf, raw.lyf, raw.rxf, raw.ryf, raw.ltf, raw.rtf)
            : "pad=none"
        log("keys_down=[\(keys)] mouse_dx=\(Int(dx)) mouse_dy=\(Int(dy)) "
            + "buttons=\(heldButtons.sorted()) wheel=\(wheelN) \(pad) "
            + "lock=\(pointerLocked ? "on" : "off") path=\(mousePath.rawValue) "
            + "events=\(tickKeys)")
        // ml672 — the 1 Hz half of the `[padmouse]` diagnostics: while
        // `AimStickDriver` is running at all, say so and say what THIS app
        // last fed it. A driver still running with nothing moving it is
        // precisely the "stuck forever" failure mode padDriveBindings' new
        // keepalive is meant to make impossible — if this line ever shows
        // `link=true` alongside a `pad0` 10 s line reading all-zero floats
        // for more than the keepalive's 200 ms, the stale vector is coming
        // from somewhere this app cannot see (an on-screen touch's own
        // holder in `AimStickDriver`, not this one).
        if AimStickDriver.shared.isRunning {
            fputs(String(format: "[padmouse] driver running vec=(%.3f,%.3f) holders=%d\n",
                         Double(padLastAimVec.width), Double(padLastAimVec.height),
                         AimStickDriver.shared.holderCount), stderr)
        }
        tickKeys = 0
        motionLock.lock()
        tickDX -= dx; tickDY -= dy; tickWheel -= wheelN
        motionLock.unlock()
    }

    // MARK: - the VK map
    //
    // Keyed on the USB HID keyboard/keypad usage page (0x07), which is what
    // GCKeyCode.rawValue is. Ordered exactly as the HID table is, so a gap is
    // visible as a gap.

    static func vk(forHIDUsage u: Int) -> Int32? {
        switch u {
        // 0x04-0x1D: a-z. HID is alphabetical, VK_A..VK_Z is 0x41..0x5A.
        case 0x04...0x1D: return Int32(0x41 + (u - 0x04))
        // 0x1E-0x26: 1-9, 0x27: 0. VK_0..VK_9 are the ASCII digits.
        case 0x1E...0x26: return Int32(0x31 + (u - 0x1E))
        case 0x27: return 0x30                       // VK_0

        case 0x28: return 0x0D                       // VK_RETURN
        case 0x29: return 0x1B                       // VK_ESCAPE
        case 0x2A: return 0x08                       // VK_BACK
        case 0x2B: return 0x09                       // VK_TAB
        case 0x2C: return 0x20                       // VK_SPACE
        case 0x2D: return 0xBD                       // VK_OEM_MINUS   -
        case 0x2E: return 0xBB                       // VK_OEM_PLUS    =
        case 0x2F: return 0xDB                       // VK_OEM_4       [
        case 0x30: return 0xDD                       // VK_OEM_6       ]
        case 0x31: return 0xDC                       // VK_OEM_5       backslash
        case 0x32: return 0xDC                       // non-US # / ~ (ISO): same VK
        case 0x33: return 0xBA                       // VK_OEM_1       ;
        case 0x34: return 0xDE                       // VK_OEM_7       '
        case 0x35: return 0xC0                       // VK_OEM_3       `
        case 0x36: return 0xBC                       // VK_OEM_COMMA   ,
        case 0x37: return 0xBE                       // VK_OEM_PERIOD  .
        case 0x38: return 0xBF                       // VK_OEM_2       /
        case 0x39: return 0x14                       // VK_CAPITAL

        // 0x3A-0x45: F1-F12 → VK_F1 (0x70) upward.
        case 0x3A...0x45: return Int32(0x70 + (u - 0x3A))

        case 0x46: return 0x2C                       // VK_SNAPSHOT (PrintScreen)
        case 0x47: return 0x91                       // VK_SCROLL
        case 0x48: return 0x13                       // VK_PAUSE
        case 0x49: return 0x2D                       // VK_INSERT
        case 0x4A: return 0x24                       // VK_HOME
        case 0x4B: return 0x21                       // VK_PRIOR (PageUp)
        case 0x4C: return 0x2E                       // VK_DELETE (forward delete)
        case 0x4D: return 0x23                       // VK_END
        case 0x4E: return 0x22                       // VK_NEXT (PageDown)
        case 0x4F: return 0x27                       // VK_RIGHT
        case 0x50: return 0x25                       // VK_LEFT
        case 0x51: return 0x28                       // VK_DOWN
        case 0x52: return 0x26                       // VK_UP

        case 0x53: return 0x90                       // VK_NUMLOCK
        case 0x54: return 0x6F                       // VK_DIVIDE
        case 0x55: return 0x6A                       // VK_MULTIPLY
        case 0x56: return 0x6D                       // VK_SUBTRACT
        case 0x57: return 0x6B                       // VK_ADD
        // Numpad Enter. Windows tells it from the main Enter only by the E0 bit
        // on its scan code, and the VK is the same — see winios_post_key_ex. We
        // post the plain VK_RETURN, which is what every game that does not read
        // scan codes sees anyway.
        case 0x58: return 0x0D                       // VK_RETURN (numpad)
        // 0x59-0x61: keypad 1-9 → VK_NUMPAD1 (0x61) upward. 0x62: keypad 0.
        case 0x59...0x61: return Int32(0x61 + (u - 0x59))
        case 0x62: return 0x60                       // VK_NUMPAD0
        case 0x63: return 0x6E                       // VK_DECIMAL

        case 0x64: return 0xE2                       // VK_OEM_102 (ISO < > key)
        case 0x65: return 0x5D                       // VK_APPS (menu key)
        case 0x67: return 0x92                       // VK_OEM_NEC_EQUAL (keypad =)

        // 0x68-0x73: F13-F24 → VK_F13 (0x7C) upward.
        case 0x68...0x73: return Int32(0x7C + (u - 0x68))

        case 0x75: return 0x2F                       // VK_HELP
        case 0x77: return 0x29                       // VK_SELECT
        // 0x74/0x76/0x78-0x7E (Execute, Menu, Stop, Again, Undo, Cut, Copy,
        // Paste, Find) are deliberately unmapped: Windows has no virtual-key for
        // them, and the VKs that look close (VK_OEM_AUTO, VK_OEM_ENLW) are IME
        // keys. Inventing a mapping would send a Japanese IME key to a game.
        case 0x7F: return 0xAD                       // VK_VOLUME_MUTE
        case 0x80: return 0xAF                       // VK_VOLUME_UP
        case 0x81: return 0xAE                       // VK_VOLUME_DOWN
        case 0x85: return 0x6C                       // VK_SEPARATOR (keypad ,)

        // International / IME keys. Japanese and Korean keyboards send these and
        // a Windows game's text entry reads them; they cost two lines each.
        case 0x87: return 0xC1                       // VK_ABNT_C1 / JIS ro
        case 0x88: return 0xF2                       // VK_OEM_COPY (katakana/hiragana)
        case 0x89: return 0xDC                       // JIS yen: VK_OEM_5
        case 0x8A: return 0x1C                       // VK_CONVERT
        case 0x8B: return 0x1D                       // VK_NONCONVERT
        case 0x90: return 0x15                       // VK_HANGUL
        case 0x91: return 0x19                       // VK_HANJA

        // 0xE0-0xE7: the modifiers, as ordinary keys with LEFT/RIGHT identity.
        // The wineserver derives the generic VK_SHIFT/VK_CONTROL/VK_MENU a game
        // reads with GetAsyncKeyState from these (queue_ios.c:1704), so posting
        // the specific one is strictly better than posting the generic one.
        case 0xE0: return 0xA2                       // VK_LCONTROL
        case 0xE1: return 0xA0                       // VK_LSHIFT
        case 0xE2: return 0xA4                       // VK_LMENU
        case 0xE3: return 0x5B                       // VK_LWIN
        case 0xE4: return 0xA3                       // VK_RCONTROL
        case 0xE5: return 0xA1                       // VK_RSHIFT
        case 0xE6: return 0xA5                       // VK_RMENU
        case 0xE7: return 0x5C                       // VK_RWIN

        default: return nil
        }
    }
}

// ============================================================================
// ml663 — POINTER LOCK.
//
// Two separate problems, and only one of them is about the pointer being
// visible:
//
//   1. VISIBILITY. An unlocked iOS pointer draws a circle over the game
//      surface and highlights every SwiftUI control it passes. A UIPointerStyle
//      of .hidden() over the live view handles that part (see PointerHider).
//   2. CONTAINMENT. An unlocked pointer stops at the screen edge, and at the
//      edge it starts hitting the app's own chrome instead of the game. GCMouse
//      deltas keep arriving either way — they are raw HID — but the user is now
//      dragging a system cursor across a toolbar while trying to turn left.
//
// `prefersPointerLocked` fixes (2), and requires UIApplicationSupportsIndirect
// InputEvents=YES in Info.plist (added in the same revision).
//
// The awkward part is that UIKit asks the KEY WINDOW's root view controller for
// that preference, and this app's root is SwiftUI's own UIHostingController —
// an instance we never construct and cannot subclass. So the override is
// installed on its CLASS at runtime.
//
// That is narrower than it sounds. Swift generic classes get one ObjC class per
// specialisation, so `UIHostingController<ContentView>` is a class with exactly
// one instance in this process: the root. The pads' hosting controllers are
// UIHostingController<JoystickPadOverlay> and <TouchControlsOverlay> — different
// classes, untouched. And the override is added, not swizzled: nothing's
// existing implementation is displaced unless that concrete class already had
// one, which UIHostingController does not.
//
// Every step is guarded and reported. If any of it fails the app keeps working
// exactly as before, minus containment — which is why (1) is solved separately
// rather than as a consequence of this.
// ============================================================================

enum PointerLock {
    private static var installed = false

    /// Re-ask UIKit for the preference. Cheap and idempotent.
    ///
    /// The root controller is re-resolved every time rather than cached: a
    /// cached weak reference that goes nil (a scene rebuild) would silently stop
    /// updating the preference, and the failure would look like "pointer lock
    /// stopped working after rotating", which is the least debuggable shape a
    /// bug can have.
    static func refresh() {
        DispatchQueue.main.async {
            install()
            keyWindow()?.rootViewController?.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static func install() {
        guard !installed else { return }
        guard let root = keyWindow()?.rootViewController else {
            fputs("[hwinput] pointer lock: no key window yet (will retry)\n", stderr)
            return
        }
        guard let cls: AnyClass = object_getClass(root) else { return }
        let sel = NSSelectorFromString("prefersPointerLocked")
        // @convention(block) so imp_implementationWithBlock can make an IMP of
        // it; the block's first parameter is the receiver, as ObjC requires.
        let body: @convention(block) (AnyObject) -> Bool = { _ in
            HardwareInput.shared.pointerLocked
        }
        let imp = imp_implementationWithBlock(body)
        // "B@:" — returns _Bool (which IS ObjC BOOL on arm64), takes self and
        // _cmd. Add first; replace only if this exact class already had one.
        if !class_addMethod(cls, sel, imp, "B@:") {
            _ = class_replaceMethod(cls, sel, imp, "B@:")
        }
        installed = true
        fputs("[hwinput] pointer lock installed on \(NSStringFromClass(cls))\n", stderr)
    }
}

/// Hides the iOS system pointer wherever it is over the game surface, whether
/// or not pointer lock took. Attached by MetalBackedView.
final class PointerHider: NSObject, UIPointerInteractionDelegate {
    static let shared = PointerHider()

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return .hidden()
    }

    /// ml664 — ONE region, the whole surface.
    ///
    /// The default behaviour re-resolves a region per hover location, and each
    /// re-resolution is a chance for the style to lapse back to the system arrow
    /// for a frame. Claiming the entire view as a single region makes the hidden
    /// style continuous across it, and tells UIKit the pointer is still "inside"
    /// something of ours everywhere on the game view.
    ///
    /// It does NOT contain the pointer: iOS clamps the system pointer to the
    /// screen and offers no way to warp or re-centre it. At the screen edge the
    /// hover deltas simply stop — see the best-effort note on `uikitMoved`.
    func pointerInteraction(_ interaction: UIPointerInteraction,
                            regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let v = interaction.view else { return defaultRegion }
        return UIPointerRegion(rect: v.bounds)
    }
}

/// ml664 — the indirect-pointer recognisers must never win an arbitration.
///
/// They coexist with each other (hover + drag + scroll are three views of one
/// device) and with everything SwiftUI and `ControlOverlayView` have installed.
/// `cancelsTouchesInView = false` at each call site keeps raw touch delivery
/// intact on top of this; the pair is what stops a mouse from stealing a finger.
final class PointerGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PointerGestureDelegate()

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        return false
    }
}
