#!/usr/bin/env python3
"""ml1530 touch-control presets (ContentView.swift); never runs iOS.

Part A extracts the Foundation-only block of ContentView.swift (PadButton,
ControlAction, TouchControl and the ml1530 preset types after them) and compiles
it on the host under AddressSanitizer: preset encode/decode, the built-in Xbox
layout on phone and tablet screens, built-ins read-only, save-as-new-name, and
what loading a preset puts in the editor.

Part B checks the UI wiring in the same file: kill switch, log tag, the editor
entry point, and that loading replaces the model's layout.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'app/Madeira/ContentView.swift').read_text()
SWIFTC = '/home/hero/.local/share/swiftly/bin/swiftc'

# ---------------------------------------------------------------- Part A
start = src.index('enum PadButton: String, Codable')
end = src.index('final class TouchControlsModel: ObservableObject {')
core = src[start:end]
assert 'import SwiftUI' not in core and 'UIKit' not in core, 'the preset core stays Foundation-only'
for name in ('struct ControlPreset:', 'struct ControlPresetScreen', 'enum ControlPresetLayout', 'struct ControlPresetStore'):
    assert name in core, name + ' lives in the extractable block'

stubs = r'''
import Foundation
struct Color { init(red: Double, green: Double, blue: Double) {} }
'''

checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

let screens: [(String, ControlPresetScreen)] = [
    ("6.3in phone", ControlPresetScreen(width: 874, height: 402, left: 59, right: 59, top: 0, bottom: 21)),
    ("6.1in phone", ControlPresetScreen(width: 844, height: 390, left: 47, right: 47, top: 0, bottom: 21)),
    ("6.9in phone", ControlPresetScreen(width: 956, height: 440, left: 62, right: 62, top: 0, bottom: 21)),
    ("4.7in phone", ControlPresetScreen(width: 667, height: 375)),
    ("insets unreported", ControlPresetScreen(width: 874, height: 402)),
    ("11in tablet", ControlPresetScreen(width: 1194, height: 834, top: 24, bottom: 20)),
    ("13in tablet", ControlPresetScreen(width: 1366, height: 1024, top: 24, bottom: 20)),
    ("mini tablet", ControlPresetScreen(width: 1133, height: 744, top: 24, bottom: 20)),
    ("phone, portrait", ControlPresetScreen(width: 402, height: 874, left: 0, right: 0, top: 62, bottom: 34)),
]

let expected: [ControlAction] = [
    .gamepad(.leftStick), .gamepad(.rightStick), .gamepadDPad,
    .gamepad(.a), .gamepad(.b), .gamepad(.x), .gamepad(.y),
    .gamepad(.lb), .gamepad(.rb), .gamepad(.lt), .gamepad(.rt),
    .gamepad(.start), .gamepad(.back), .gamepad(.l3), .gamepad(.r3),
]

func find(_ cs: [TouchControl], _ a: ControlAction) -> TouchControl? { cs.first { $0.action == a } }

@main struct Checks {
    static func main() throws {
        // --- Built-in Xbox layout: complete, on screen, non-overlapping.
        for (label, screen) in screens {
            let s = screen.landscape
            let cs = ControlPresetLayout.xbox(for: screen)
            let actions = cs.map { $0.action }
            require(cs.count == expected.count && expected.allSatisfy { a in actions.filter { $0 == a }.count == 1 },
                    "\(label): both sticks, D-pad, ABXY, LB/RB, LT/RT, Start/Back, L3/R3, once each")
            require(cs.allSatisfy { $0.scale >= 0.5 && $0.scale <= 3.0 }, "\(label): scales inside the pinch clamp")
            require(cs.allSatisfy { $0.nx >= 0.03 && $0.nx <= 0.97 && $0.ny >= 0.03 && $0.ny <= 0.97 },
                    "\(label): positions inside the editor's drag clamp")
            let m = ControlPresetLayout.margins(s)
            let safe = CGRect(x: m.left, y: m.top, width: s.width - m.left - m.right, height: s.height - m.top - m.bottom)
            let boxes = cs.map { ControlPresetLayout.box($0, screen: s) }
            require(boxes.allSatisfy { safe.contains($0) }, "\(label): every control inside the safe area")
            // Round controls hit-test (and draw) as circles — `circularHit` —
            // so two of them clash only if the circles do; the diamond's
            // diagonal neighbours share box corners and nothing else.
            func clash(_ i: Int, _ j: Int) -> Bool {
                let a = boxes[i], b = boxes[j]
                if cs[i].action.circularHit && cs[j].action.circularHit {
                    let dx = a.midX - b.midX, dy = a.midY - b.midY
                    return (dx * dx + dy * dy).squareRoot() < a.width / 2 + b.width / 2 + 2
                }
                return a.insetBy(dx: -2, dy: -2).intersects(b)
            }
            var overlaps: [String] = []
            for i in cs.indices { for j in cs.indices where j > i {
                if clash(i, j) {
                    overlaps.append("\(cs[i].action.label)/\(cs[j].action.label)")
                }
            } }
            require(overlaps.isEmpty, "\(label): no two controls overlap (\(overlaps))")
            let menu = ControlPresetLayout.menuButtonRect(s)
            require(!boxes.contains { $0.intersects(menu) }, "\(label): the in-game menu button's default spot is left free")
            // Placement the preset promises.
            let l = find(cs, .gamepad(.leftStick))!, r = find(cs, .gamepad(.rightStick))!
            let d = find(cs, .gamepadDPad)!, a = find(cs, .gamepad(.a))!, y = find(cs, .gamepad(.y))!
            let x = find(cs, .gamepad(.x))!, b = find(cs, .gamepad(.b))!
            let lt = find(cs, .gamepad(.lt))!, lb = find(cs, .gamepad(.lb))!, rt = find(cs, .gamepad(.rt))!
            let st = find(cs, .gamepad(.start))!, bk = find(cs, .gamepad(.back))!
            require(l.nx < 0.3 && l.ny > 0.6 && r.nx > 0.7 && r.ny > 0.6, "\(label): sticks in the bottom corners")
            require(d.nx < 0.5 && d.ny < l.ny && a.nx > 0.5 && a.ny < r.ny, "\(label): D-pad above the left stick, ABXY above the right")
            require(y.ny < x.ny && x.ny == b.ny && b.ny < a.ny && x.nx < y.nx && y.nx < b.nx && abs(y.nx - a.nx) < 1e-9,
                    "\(label): Y top, X left, B right, A bottom")
            require(lt.ny < lb.ny && lt.ny < 0.2 && lt.nx < 0.5 && rt.nx > 0.5, "\(label): triggers above bumpers, top corners")
            require(bk.nx < 0.5 && st.nx > 0.5 && abs(bk.ny - st.ny) < 1e-9, "\(label): Back left of Start, centre")
            require(ControlPresetScreen(width: s.width, height: s.height).landscape.width >= s.height, "\(label): laid out landscape")
        }
        let ids = Set(ControlPresetLayout.xbox(for: .referencePhone).map { $0.id })
        require(ids.count == expected.count, "built-in controls have distinct ids")

        // --- Encode / decode round trip.
        var store = ControlPresetStore()
        var custom = TouchControl()
        custom.nx = 0.2; custom.ny = 0.7; custom.scale = 1.4
        custom.action = .key(0x20); custom.padBinding = .a
        var legacy = TouchControl(); legacy.action = .pad("A")
        var dpad = TouchControl(); dpad.action = .gamepadDPad
        let layout = [custom, legacy, dpad] + ControlPresetLayout.xbox(for: .referencePhone)
        var n = 0
        let fixedID: () -> String = { n += 1; return "user-\(n)" }
        require(store.save(name: "  Racing  ", controls: layout, sizeScale: 1.25, newID: fixedID) == .created("user-1"), "save creates")
        require(store.save(name: "Shooter", controls: [custom], sizeScale: 0.8, newID: fixedID) == .created("user-2"), "second preset")
        require(store.preset("user-1")?.name == "Racing", "names are trimmed")
        let data = try store.encoded()
        let back = try ControlPresetStore.decoded(data)
        require(back == store && back.user.count == 2, "user presets round-trip through JSON")
        require(back.preset("user-1")?.controls == layout && back.preset("user-1")?.sizeScale == 1.25,
                "controls (keys, pad actions, bindings, legacy .pad) and size survive")
        let text = String(decoding: data, as: UTF8.self)
        require(!text.contains(ControlPresetLayout.xboxID), "built-ins are never written to the file")
        let old = #"{"version":1,"presets":[{"id":"p","name":"Old","controls":[{"id":"6F1B5E2A-1C1D-4B7E-9C84-0A0B0C0D0E0F","nx":0.5,"ny":0.5,"scale":1,"action":{"mouseLeft":{}}}]}]}"#
        let oldStore = try ControlPresetStore.decoded(Data(old.utf8))
        require(oldStore.preset("p")?.sizeScale == nil && oldStore.preset("p")?.controls.count == 1,
                "a preset without sizeScale or padBinding still decodes")
        let future = #"{"version":2,"presets":[]}"#
        require((try? ControlPresetStore.decoded(Data(future.utf8))) == nil, "a newer file version is refused, not misread")
        let smuggled = try ControlPresetStore.decoded(Data(#"{"version":1,"presets":[{"id":"builtin.xbox","name":"X","controls":[]}]}"#.utf8))
        require(smuggled.user.isEmpty && smuggled.preset(ControlPresetLayout.xboxID)?.controls.count == expected.count,
                "a file entry cannot shadow a built-in")

        // --- Built-ins are read-only.
        let xbox = ControlPresetLayout.xboxID
        require(ControlPresetStore.isBuiltIn(xbox) && store.all.first?.id == xbox, "Xbox controller is built in and listed first")
        require(!store.delete(id: xbox), "built-in not deletable")
        require(!store.rename(id: xbox, to: "Mine"), "built-in not renamable")
        require(!store.overwrite(id: xbox, controls: [], sizeScale: 1), "built-in not overwritable")
        require(store.save(name: "xbox CONTROLLER ", controls: [], sizeScale: 1) == .refusedBuiltIn, "saving under a built-in's name is refused")
        require(store.preset(xbox)?.controls.count == expected.count, "built-in unchanged after all of that")

        // --- Save a built-in's edit under a new name.
        let copy = store.copyName(for: ControlPresetLayout.xboxName)
        require(copy == "Xbox controller (custom)" && store.named(copy) == nil, "a free copy name is offered (\(copy))")
        guard case .created(let copyID) = store.save(name: copy, controls: layout, sizeScale: 1, newID: fixedID) else {
            require(false, "save as new name"); exit(1)
        }
        require(!ControlPresetStore.isBuiltIn(copyID) && store.user.count == 3, "saved as a user preset")
        require(store.copyName(for: ControlPresetLayout.xboxName) == "Xbox controller (custom 2)", "next copy name moves on")
        require(store.save(name: "racing", controls: [custom], sizeScale: 1.5) == .replaced("user-1") && store.user.count == 3,
                "saving under a user preset's name replaces it in place")
        require(store.preset("user-1")?.controls == [custom], "replaced layout stored")

        // --- Rename / delete user presets.
        require(!store.rename(id: "user-1", to: "Shooter"), "rename to a used name refused")
        require(!store.rename(id: "user-1", to: "Xbox Controller"), "rename to a built-in's name refused")
        require(!store.rename(id: "user-1", to: "   "), "rename to empty refused")
        require(store.rename(id: "user-1", to: "Driving") && store.preset("user-1")?.name == "Driving", "rename")
        require(store.rename(id: "user-1", to: "driving"), "rename to its own name, other case")
        require(store.delete(id: "user-2") && store.preset("user-2") == nil && !store.delete(id: "user-2"), "delete once")
        require(store.save(name: "", controls: [], sizeScale: 1) == .refusedEmpty, "empty name refused")

        // --- Loading replaces the layout.
        let saved = store.preset(copyID)!
        let loaded = ControlPresetStore.layout(of: saved, screen: nil)
        require(loaded.controls.count == saved.controls.count && loaded.sizeScale == 1, "load returns the whole preset")
        require(zip(loaded.controls, saved.controls).allSatisfy { $0.action == $1.action && $0.padBinding == $1.padBinding
                    && $0.nx == $1.nx && $0.ny == $1.ny && $0.scale == $1.scale },
                "load keeps actions, bindings, positions and scales")
        require(Set(loaded.controls.map { $0.id }).isDisjoint(with: saved.controls.map { $0.id })
                && Set(loaded.controls.map { $0.id }).count == loaded.controls.count, "load gives fresh, distinct ids")
        var wild = TouchControl(); wild.nx = 1.4; wild.ny = -0.2; wild.scale = 9
        let clamped = ControlPresetStore.layout(of: ControlPreset(id: "w", name: "w", controls: [wild], sizeScale: 7), screen: nil)
        require(clamped.controls[0].nx == 0.97 && clamped.controls[0].ny == 0.03 && clamped.controls[0].scale == 3 && clamped.sizeScale == 2,
                "load clamps positions, scale and size into the editor's ranges")
        let tablet = screens[5].1
        let fitted = ControlPresetStore.layout(of: store.preset(xbox)!, screen: tablet)
        let direct = ControlPresetLayout.xbox(for: tablet)
        require(fitted.controls.map { $0.nx } == direct.map { $0.nx } && fitted.controls.map { $0.ny } == direct.map { $0.ny },
                "the built-in is laid out again for the screen it is loaded on")
        require(fitted.controls.map { $0.nx } != store.preset(xbox)!.controls.map { $0.nx }, "tablet layout differs from the phone copy")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all ml1530 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-control-presets-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'core.swift').write_text('import Foundation\n' + core)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'swift-checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                    str(tmp / 'stubs.swift'), str(tmp / 'core.swift'), str(tmp / 'checks.swift')], check=True)
    subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# ---------------------------------------------------------------- Part B
def function(source, start):
    i = source.index(start); b = source.index("{", i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == "{") - (source[k] == "}"); k += 1
    return source[i:k]

assert 'static let enabled = LibraryFlags.enabled("MADEIRA_CONTROL_PRESETS")' in src, 'kill switch'
bar = function(src, "private func topBar(in geo: GeometryProxy) -> some View {")
assert "if m.editing {" in bar and bar.index("if m.editing {") < bar.index("if ControlPresetsModel.enabled && !Self.editorDone {") \
    < bar.index("ControlPresetsMenu(screen: presetScreen(in: geo))"), 'legacy presets button in the editor only, behind the switches'
# ml1970: Done replaces the exit arrows in the editor; the show/hide glyph and pencil are hidden
# there; layouts are chosen in the session menu, which refreshes the controls after a load.
assert 'static let editorDone = LibraryFlags.enabled("MADEIRA_CONTROLS_EDITOR_DONE")' in src
assert bar.index('if m.editing && Self.editorDone {') < bar.index('Text("Done")') < bar.index('glassButton("gamecontroller"')
assert 'if !(m.editing && Self.editorDone) {' in bar
library_src = (root / 'app/Madeira/Library.swift').read_text()
assert 'if controls.visible && ControlPresetsModel.enabled { ControllerLayoutPicker' in library_src, 'layout picker only with touch controls on'
assert 'Button("Create new layout", systemImage: "plus")' in library_src and 'while store.named("Custom Layout \\(n)")' in src
assert 'm.layoutReplaced(reason: "preset")' in src and 'OnScreenPad.shared.rearm()' in function(src, "func layoutReplaced(reason: String) {")
model = src[src.index("final class ControlPresetsModel"):src.index("/// ml — THE SIZE TO GIVE A WINDOW-LEVEL OVERLAY")]
assert 'fputs("[control-presets] ml1530 \\(line)\\n", stderr)' in model and 'logged < 64' in model, 'log tag, capped'
assert 'log("\\(verb) name=\\(p?.name ?? "?") controls=\\(count)")' in model
for verb in ('"loaded"', '"saved"', '"deleted"'):
    assert 'log(' + verb in model, verb + ' is logged'
load = function(model, "func load(_ id: String, screen: ControlPresetScreen) {")
assert load.index("ControlPresetStore.layout(of: p, screen: screen)") < load.index("m.controls = l.controls") \
    and "m.sizeScale = l.sizeScale" in load and "m.selected = nil" in load, 'loading replaces the editor layout'
assert 'appendingPathComponent("madeira-control-presets.json")' in model and "readOnly = true" in model, \
    'Documents file; an unreadable one is kept, not overwritten'
menu = src[src.index("struct ControlPresetsMenu: View {"):src.index("struct GlassShape: View {")]
assert 'Replace your current controls with' in menu and 'presets.load(p.id, screen: screen)' in menu, 'load confirms first'
assert 'TouchControlsHost.beginTextEntry()' in menu and 'TouchControlsHost.endTextEntry()' in menu, 'name field gets a key window, then gives it back'
assert '"saveLayout"' not in src and 'saveCurrentProfile' not in menu, 'the per-game profile path is untouched'
print("PASS: presets UI behind MADEIRA_CONTROL_PRESETS, in the editor, logged, load confirms and replaces the layout")
