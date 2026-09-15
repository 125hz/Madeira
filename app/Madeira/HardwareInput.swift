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
    private var padKeyOwner = 0
    private var padBtnOwner = 0
    private var padAimOwner = 0

    private var heldVKs: Set<Int32> = []
    private var heldButtons: Set<Int> = []
    private var padKeys: Set<Int32> = []
    private var padButtons: Set<Int> = []
    private var padAimActive = false

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
        padKeyOwner = InputGuard.newOwner()
        padBtnOwner = InputGuard.newOwner()
        padAimOwner = InputGuard.newOwner()

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
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.detachController()
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
        guard !heldVKs.isEmpty || !heldButtons.isEmpty || !padKeys.isEmpty
                || !padButtons.isEmpty || padAimActive else { return }
        log("forget held (\(why)) keys=\(heldVKs.count) btns=\(heldButtons.count) "
            + "pad=\(padKeys.count)")
        heldVKs.removeAll(); heldButtons.removeAll()
        padKeys.removeAll(); padButtons.removeAll()
        padAimActive = false
        InputGuard.shared.release(kbOwner)
        InputGuard.shared.release(mouseOwner)
        InputGuard.shared.release(padKeyOwner)
        InputGuard.shared.release(padBtnOwner)
        AimStickDriver.shared.end(padAimOwner)
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

    // MARK: - gamepad (optional extra; a generic default mapping)
    //
    // Cheap, because it needs no new plumbing: a stick is the same 8-way snap
    // ControlOverlayView already does, the right stick is the aim engine ml660
    // already built, and the face buttons are keys InputGuard already holds.
    //
    // The mapping below is the conventional PC shooter layout (triggers are the
    // mouse buttons, left stick walks, right stick looks). It is a DEFAULT, not
    // a claim about any particular title — the on-screen controls' own remapping
    // UI is where per-title layouts belong.

    private func attachController(_ c: GCController?) {
        guard let c, let gp = c.extendedGamepad else { return }
        c.handlerQueue = .main
        gp.valueChangedHandler = { [weak self] pad, _ in self?.padChanged(pad) }
        gamepadConnected = true
        startTicker()
        log("gamepad connected: \(c.vendorName ?? "controller")")
    }

    private func detachController() {
        padKeys.removeAll(); padButtons.removeAll()
        InputGuard.shared.release(padKeyOwner)
        InputGuard.shared.release(padBtnOwner)
        AimStickDriver.shared.end(padAimOwner)
        padAimActive = false
        gamepadConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
        log("gamepad disconnected")
    }

    private func padChanged(_ gp: GCExtendedGamepad) {
        var keys = Set<Int32>()
        var btns = Set<Int>()

        // Left stick and d-pad both walk. 8-way, so a diagonal holds two keys —
        // exactly what ControlOverlayView.stickKeys does for a thumb.
        let ls = gp.leftThumbstick
        appendStick(&keys, x: CGFloat(ls.xAxis.value), y: CGFloat(ls.yAxis.value),
                    quad: [0x57, 0x44, 0x53, 0x41])            // W D S A
        let dp = gp.dpad
        if dp.up.isPressed    { keys.insert(0x26) }
        if dp.right.isPressed { keys.insert(0x27) }
        if dp.down.isPressed  { keys.insert(0x28) }
        if dp.left.isPressed  { keys.insert(0x25) }

        if gp.buttonA.isPressed { keys.insert(0x20) }           // space
        if gp.buttonB.isPressed { keys.insert(0xA2) }           // left ctrl
        if gp.buttonX.isPressed { keys.insert(0x45) }           // E
        if gp.buttonY.isPressed { keys.insert(0x52) }           // R
        if gp.leftShoulder.isPressed  { keys.insert(0x51) }     // Q
        if gp.rightShoulder.isPressed { keys.insert(0x46) }     // F
        if gp.leftThumbstickButton?.isPressed == true  { keys.insert(0xA0) }  // left shift
        if gp.rightThumbstickButton?.isPressed == true { keys.insert(0x43) }  // C
        if gp.buttonMenu.isPressed { keys.insert(0x1B) }        // escape
        if gp.buttonOptions?.isPressed == true { keys.insert(0x09) }          // tab

        if gp.rightTrigger.isPressed { btns.insert(InputGuard.Btn.left) }
        if gp.leftTrigger.isPressed  { btns.insert(InputGuard.Btn.right) }

        if keys != padKeys { padKeys = keys; InputGuard.shared.hold(padKeyOwner, keys: keys) }
        if btns != padButtons { padButtons = btns; InputGuard.shared.hold(padBtnOwner, buttons: btns) }

        // Right stick → mouse look, through the display-link engine that already
        // converts a held deflection into per-frame motion (a mouse has no
        // "held right"; see AimStickDriver).
        let rs = gp.rightThumbstick
        let vec = HardwareInput.deflect(CGFloat(rs.xAxis.value), -CGFloat(rs.yAxis.value),
                                        deadzone: 0.15)
        if vec == .zero {
            if padAimActive { padAimActive = false; AimStickDriver.shared.end(padAimOwner) }
        } else {
            if !padAimActive { padAimActive = true; AimStickDriver.shared.begin(padAimOwner) }
            AimStickDriver.shared.steer(padAimOwner, vec)
        }
        startTicker()
    }

    /// 8-way snap with a deadzone, in stick coordinates (y positive UP).
    private func appendStick(_ into: inout Set<Int32>, x: CGFloat, y: CGFloat, quad: [Int32]) {
        let d = (x * x + y * y).squareRoot()
        guard d >= 0.35, quad.count == 4 else { return }
        var a = atan2(x, y) * 180 / .pi                // clockwise from "up"
        if a < 0 { a += 360 }
        switch Int((a + 22.5) / 45.0) % 8 {
        case 0: into.insert(quad[0])
        case 1: into.formUnion([quad[0], quad[1]])
        case 2: into.insert(quad[1])
        case 3: into.formUnion([quad[2], quad[1]])
        case 4: into.insert(quad[2])
        case 5: into.formUnion([quad[2], quad[3]])
        case 6: into.insert(quad[3])
        default: into.formUnion([quad[0], quad[3]])
        }
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
            && heldVKs.isEmpty && heldButtons.isEmpty && padKeys.isEmpty && padButtons.isEmpty
        if idle {
            // Nothing moved and nothing is held: stand down rather than print a
            // line a second for the rest of the session.
            ticker?.invalidate(); ticker = nil
            motionLock.lock(); tickerArmed = false; motionLock.unlock()
            return
        }
        let keys = heldVKs.sorted().map { String(format: "%02x", $0) }.joined(separator: ",")
        let pad = padKeys.sorted().map { String(format: "%02x", $0) }.joined(separator: ",")
        log("keys_down=[\(keys)] mouse_dx=\(Int(dx)) mouse_dy=\(Int(dy)) "
            + "buttons=\(heldButtons.sorted()) wheel=\(wheelN) "
            + "pad=[\(pad)] padbtn=\(padButtons.sorted()) "
            + "lock=\(pointerLocked ? "on" : "off") path=\(mousePath.rawValue) "
            + "events=\(tickKeys)")
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
