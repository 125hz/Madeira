#!/usr/bin/env python3
"""ml1490 touch-control editor fixes (ContentView.swift): source invariants; no UI runs.

Device reports: in landscape the layout-size bar covered the edit buttons; after an edit the game
did not see the on-screen controller until the controls were hidden and shown; Start/Back could
not be picked in the mapping panel.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
src = (root / "app/Madeira/ContentView.swift").read_text()


def function(source, start):
    i = source.index(start); b = source.index("{", i); depth = 1; k = b + 1
    while depth:
        depth += (source[k] == "{") - (source[k] == "}"); k += 1
    return source[i:k]


bar = function(src, "private func topBar(in geo: GeometryProxy) -> some View {")
fixed = bar.index(".background(TouchControlsModel.hudRectFix ? GeometryReader")
pos = bar.index(".position(x: center.x + hudDragState.width")
legacy = bar.index(".background(TouchControlsModel.hudRectFix ? nil : GeometryReader")
assert fixed < pos < legacy, "the cluster is measured before .position (itself), after it only on rollback"
assert 'static let hudRectFix = LibraryFlags.enabled("MADEIRA_HUD_RECT_FIX")' in src

model = src[src.index("final class TouchControlsModel"):src.index("struct TouchControlsOverlay")]
assert "didSet { if oldValue && !editing { editingEnded() } }" in model, "only the true->false edge"
ended = function(model, "private func editingEnded() {")
assert ended.index("fputs(\"[controls-edit] ml1490 editing ended") < ended.index("guard Self.refreshAfterEdit else { return }") \
    < ended.index("epoch &+= 1") < ended.index("OnScreenPad.shared.rearm()"), "log, switch, rebuild, then re-arm"
assert "editsLogged < 16" in ended and 'LibraryFlags.enabled("MADEIRA_CONTROLS_REFRESH")' in model
overlay = function(src, "struct TouchControlsOverlay: View {")
assert overlay.index("ForEach(m.controls) { c in") < overlay.index(".id(m.epoch)"), "controls keyed on the epoch"
rearm = function(src, "    func rearm() {")
assert "guard n > 0 else { return }" in rearm and rearm.index("padScreenPresence(false)") < rearm.index("asyncAfter") \
    < rearm.index("padScreenPresence(true)") and "self.isLive" in rearm, "unplug, wait, plug back only if still present"

panel = function(src, "private var layout: Placement {")
assert "let bottom: CGFloat = Self.bottomMargin ? 30 : edge" in panel
assert "screen.height - bottom" in panel and "size.height / 2 - bottom" in panel, "bottom constraints use the margin"
assert 'LibraryFlags.enabled("MADEIRA_PANEL_BOTTOM_MARGIN")' in src
assert src.count('MappingPanel.logChip(') == 2 and "chipLogs < 48" in src, "both chip kinds log, capped"
print("PASS: cluster measured before .position, edit end rebuilds and re-arms, panel keeps off the bottom edge, chips log")

tab = src[src.index("private var controllerTab: some View {"):src.index("private static let bindingCollapsed")]
assert "if Self.bindingCollapsed {" in tab and "DisclosureGroup(isExpanded: $bindingOpen)" in tab and "bindingSections" in tab, "binding rows folded"
assert tab.index('actionSection("System", [.gamepad(.start), .gamepad(.back)])') < tab.index("DisclosureGroup"), "send rows come first"
assert 'LibraryFlags.enabled("MADEIRA_PANEL_BINDING_COLLAPSED")' in src and "@State private var bindingOpen = false" in src
log = (root / "app/Madeira/LogStore.swift").read_text()
app = log[log.index("private func appendToFile("):]
assert app.index("if Self.viaStderr && Self.stderrIsFile(logFileURL.path) {") < app.index("fputs(line, stderr)") < app.index("FileHandle(forWritingTo:"), \
    "app log lines go through stderr once it is the log file"
assert "err.st_dev == file.st_dev && err.st_ino == file.st_ino" in log and 'LibraryFlags.enabled("MADEIRA_LOG_VIA_STDERR")' in log
print("PASS: physical-binding rows folded under their own title; app log lines use the working writer")
