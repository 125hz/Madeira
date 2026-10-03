#!/usr/bin/env python3
"""Static integration checks for StikDebug and the iOS 26 built-in JIT helper."""

from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
app = root / "app/Madeira"
project = (root / "app/Madeira.xcodeproj/project.pbxproj").read_text()
stik = (app / "StikJITHelper.swift").read_text()
setup = (app / "JITSetup.swift").read_text()
host = (app / "JITBuiltInHost.swift").read_text()
messages = (app / "JITBuiltInMessages.swift").read_text()
helper = (root / "app/MadeiraJITHelper/MadeiraJITHelper.swift").read_text()
content = (app / "ContentView.swift").read_text()
library = (app / "Library.swift").read_text()


def require(condition, label):
    if not condition:
        raise AssertionError(label)
    print(f"PASS: {label}")


def function(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# StikDebug must target this process, carry the one bundled script, and wait
# for a live debugger rather than accepting the sticky CS_DEBUGGED bit alone.
enable = function(stik, "static func enableJIT(")
require('components.scheme = "stikdebug"' in enable
        and 'components.host = "enable-jit"' in enable,
        "StikDebug uses the canonical enable-jit URL")
require('URLQueryItem(name: "bundle-id", value: bundleID)' in enable
        and 'URLQueryItem(name: "pid", value: String(getpid()))' in enable
        and 'URLQueryItem(name: "script-data", value: scriptData.base64EncodedString())' in enable,
        "StikDebug request targets the current PID and carries Madeira's script")
require('Bundle.main.url(forResource: "madeira-jit", withExtension: "js")' in stik
        and "private static let scriptBase64" not in stik,
        "the bundled JavaScript file is the single script source")
wait = function(stik, "static func waitForDebugger(")
require("timeout: TimeInterval = 90" in wait and "if ready {" in wait,
        "StikDebug attach has a finite 90-second readiness timeout")
ready = function(stik, "static var ready: Bool")
require("jit_check_debugged()" in ready and "isDebuggerAttached()" in ready,
        "readiness requires CS_DEBUGGED and a live debugger")

# Automatic selection is deterministic: installed StikDebug first, otherwise
# the built-in helper. A failure never silently falls through to another method.
resolved = function(setup, "var resolvedMethod: JITMethod")
require("StikJITHelper.isAvailable ? .stikDebug : .builtIn" in resolved,
        "Automatic prefers installed StikDebug, then Built-in StikJIT")
coordinator_enable = function(setup, "func enable(completion:")
require("switch resolvedMethod" in coordinator_enable
        and "enableBuiltIn(completion: completion)" in coordinator_enable
        and coordinator_enable.count("StikJITHelper.enableJIT") == 1,
        "the coordinator routes each selected JIT method once")
require("JITSetupView()" in content and "JITSettingsSection()" in library,
        "JIT setup is reachable from the main flow and Settings")
require('dictionary["public_key"]' in setup
        and 'dictionary["private_key"]' in setup
        and 'dictionary["identifier"]' in setup,
        "pairing import rejects ordinary lockdown plists before invoking StikJIT")

# The debugger must run in a separate extension process. The request includes
# the target app PID and helper always forces Madeira's custom script.
require("AppExtensionProcess(configuration:" in host
        and "process.makeXPCSession()" in host
        and "session.send(request)" in host,
        "the app invokes a separate ExtensionFoundation helper over XPC")
require(project.count("EX_ENABLE_EXTENSION_POINT_GENERATION = YES;") == 4,
        "both app and helper configurations generate ExtensionFoundation metadata")
require("let targetPID: Int32?" in messages and "let pairingData: Data?" in messages
        and "let scriptBase64: String?" in messages,
        "the XPC request carries PID, pairing data, and script")
helper_enable = helper[helper.index("try StikJIT.enableJIT("):]
require("targetPID: targetPID" in helper_enable
        and "script: .customBase64(scriptBase64)" in helper_enable
        and "forceScript: true" in helper_enable,
        "the helper attaches to Madeira and forces its custom script")
require('getenv("LC_HOME_PATH")' in host,
        "built-in JIT is disabled under LiveContainer")

# Packaging: both targets share Codable messages; only the helper links the
# device-only StikJIT framework; the script and helper are embedded in the app.
for marker in [
    "MadeiraJITHelper.appex in Embed JIT Helper",
    "madeira-jit.js in Resources",
    "JITBuiltInMessages.swift in Helper Sources",
    "Frameworks/StikJIT.xcframework/ios-arm64",
]:
    require(marker in project, f"Xcode project contains {marker}")
require(project.count('"OTHER_LDFLAGS[sdk=iphoneos*]"') == 2
        and re.search(r"(?m)^\s*OTHER_LDFLAGS\s*=", project) is None
        and "#if targetEnvironment(simulator)" in helper,
        "StikJIT links on device only, with a simulator-safe helper stub")

with (app / "Info.plist").open("rb") as f:
    app_plist = plistlib.load(f)
require("stikdebug" in app_plist["LSApplicationQueriesSchemes"],
        "the app may detect the canonical StikDebug URL scheme")
with (root / "app/MadeiraJITHelper/Info.plist").open("rb") as f:
    helper_plist = plistlib.load(f)
require(helper_plist["CFBundlePackageType"] == "XPC!"
        and helper_plist["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"]
        == "$(MADEIRA_BUNDLE_IDENTIFIER).MadeiraJITHelper",
        "the helper is packaged as an ExtensionKit extension of the app's own bundle identifier")
project = (root / "app/Madeira.xcodeproj/project.pbxproj").read_text()
helper_source = (root / "app/MadeiraJITHelper/MadeiraJITHelper.swift").read_text()
require(project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(MADEIRA_BUNDLE_IDENTIFIER)";') == 2
        and project.count('PRODUCT_BUNDLE_IDENTIFIER = "$(MADEIRA_BUNDLE_IDENTIFIER).JITHelper";') == 2
        and project.count("MADEIRA_BUNDLE_IDENTIFIER = com.willfaust.madeora;") == 2
        and "AppExtensionPoint.Identifier(" not in helper_source,
        "one setting, MADEIRA_BUNDLE_IDENTIFIER, names the app, the helper and its extension point")

problem = setup[setup.index("enum ConnectionProblem"):setup.index("var message: String")]
require(problem.index('"connectionreset"') < problem.index("self = .pairing") < problem.index('"connectionrefused"')
        < problem.index('"timedout"') < problem.index("self = .vpn"),
        "a reset connection reads as a rejected pairing; refused, timed out or unreachable as LocalDevVPN")
require(setup.count("helperFailure(response.message)") == 2,
        "Check setup and Enable JIT both explain connection problems")
library_source = (app / "Library.swift").read_text()
require("if let jitProblem { jitConnectionActions(jitProblem) { model.error = nil } }" in library_source,
        "the library's JIT error offers Pair Again and LocalDevVPN")
# The error alert hangs off LibraryView's tab view, so it presents from Settings too
# (an alert inside the Library page waited until that tab came back).
body = library_source[library_source.index('struct LibraryView: View {'):]
body = body[body.index('    var body: some View {'):body.index('    @ToolbarContentBuilder private var libraryToolbar')]
require('.alert(jitProblem == nil ? "Library" : "Couldn\'t Enable JIT"' in body,
        "the library's error alert is on the tab view, shown on the Settings tab as well")
require('URL(string: "localdevvpn://enable?scheme=madeira")' in setup
        and "localdevvpn" in app_plist["LSApplicationQueriesSchemes"]
        and any("madeira" in t.get("CFBundleURLSchemes", []) for t in app_plist.get("CFBundleURLTypes", [])),
        "LocalDevVPN opens to connect and returns to Madeira's own URL scheme")

print("check-jit-method: PASS")
