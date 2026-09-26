#!/usr/bin/env python3
"""ml1970 host checks; never runs Wine, Steam or iOS.

Compiles production Swift (SteamFiles.swift, AppManifestWriter.swift) under
AddressSanitizer and checks:
  * Madeira Dock one-time installs: install-script programs parsed from the text
    (repeated sections, %INSTALLDIR%, numbered process/command pairs), unsafe
    arguments refused, Microsoft runtimes recognised as provided, done-marks read
    from Wine .reg text in both registry views, and the batch records a program
    done only after it exits with status 0;
  * shared-depot install records: SharedDepots in the game's record and a merged
    owner record, as Valve's client writes them;
  * the regular desktop client is told apart from Dock's client components.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = '/home/hero/.local/share/swiftly/bin/swiftc'

stubs = r'''
import Foundation
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-ml1970/steamapps") } }
'''

checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

@main struct Checks {
    static func main() throws {
        // Entry names are compared lowercased, as ml1780 reads them (registry names are case-insensitive).
        // --- Install scripts: repeated "Run Process" sections, one program each.
        let script = """
        "InstallScript"
        {
            "Run Process"
            {
                "DirectX"
                {
                    "HasRunKey"   "HKEY_LOCAL_MACHINE\\\\Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010"
                    "process 1"   "%INSTALLDIR%\\\\_CommonRedist\\\\DirectX\\\\Jun2010\\\\DXSETUP.exe"
                    "command 1"   "/silent"
                }
            }
            "Run Process"
            {
                "OpenAL"
                {
                    "HasRunKey"   "HKEY_LOCAL_MACHINE\\\\Software\\\\Valve\\\\Steam\\\\Apps\\\\7000"
                    "process 1"   "%INSTALLDIR%\\\\redist\\\\oalinst.exe"
                    "command 1"   "/s"
                    "MinimumHasRunValue" "2"
                }
                "Physics"
                {
                    "HasRunKey"   "HKEY_CURRENT_USER\\\\Software\\\\Fixture"
                    "process 1"   "%INSTALLDIR%\\\\redist\\\\physics.msi"
                    "process 2"   "%INSTALLDIR%\\\\redist\\\\second.exe"
                    "command 2"   "/quiet & del C:\\\\x"
                }
                "Escape"
                {
                    "HasRunKey"   "HKEY_LOCAL_MACHINE\\\\Software\\\\Fixture2"
                    "process 1"   "%INSTALLDIR%\\\\..\\\\..\\\\evil.exe"
                }
            }
        }
        """
        let dir = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fixture Game"
        let found = DockInstallScripts.processes(script: Data(script.utf8), installDir: dir)
        setvbuf(stdout, nil, _IONBF, 0)
        require(found.count == 3, "three runnable programs from repeated sections (\(found.count))")
        let dx = found.first { $0.run.name == "directx" }
        let al = found.first { $0.run.name == "openal" }
        let msi = found.first { $0.run.name == "physics" }
        require(dx?.executable == dir + "\\_CommonRedist\\DirectX\\Jun2010\\DXSETUP.exe" && dx?.arguments == "/silent", "%INSTALLDIR% expanded")
        require(al?.run.value == 2 && al?.run.hive == .machine, "MinimumHasRunValue and hive kept")
        require(msi?.executable.hasSuffix("physics.msi") == true && msi?.run.hive == .user, "MSI program kept")
        require(!found.contains { $0.executable.contains("second.exe") }, "arguments with shell operators are refused")
        require(!found.contains { $0.run.name == "escape" }, "paths leaving the folder are refused")
        require(dx.map(DockInstallScripts.providedByMadeira) == true, "DirectX is provided by Madeira")
        require(al.map(DockInstallScripts.providedByMadeira) == false, "OpenAL is not")
        for name in ["vcredist_x86.exe", "VC_redist.x64.exe", "dotNetFx40_Full_x86_x64.exe", "NDP472-KB4054530-x86-x64-AllOS-ENU.exe"] {
            let p = SteamInstallProcess(run: al!.run, executable: "C:\\r\\" + name, arguments: "")
            require(DockInstallScripts.providedByMadeira(p), "provided: \(name)")
        }

        // --- Done marks in Wine .reg text, either registry view.
        guard let al else { return }
        let reg = """
        WINE REGISTRY Version 2

        [Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\7000] 1700000000
        "openal"=dword:00000002
        """
        require(DockInstallScripts.marked(al.run, in: reg), "a mark in the 32-bit view counts")
        require(!DockInstallScripts.marked(al.run, in: reg.replacingOccurrences(of: "dword:00000002", with: "dword:00000001")),
                "a value below the minimum does not")
        require(!DockInstallScripts.marked(al.run, in: "WINE REGISTRY Version 2\n"), "an absent mark does not")
        let (marked, _) = SteamInstallScripts.mark([al.run], in: "WINE REGISTRY Version 2\n", now: 1)
        require(DockInstallScripts.marked(al.run, in: marked), "the ml1780 writer and the ml1970 reader agree")

        // --- The batch: each program, then its mark only on success, in both views.
        let batch = DockInstallScripts.batch([al, msi!])
        let lines = batch.components(separatedBy: "\r\n")
        let run = lines.firstIndex { $0 == "call \"" + al.executable + "\" /s" }
        let mark = lines.firstIndex { $0.hasPrefix("if not errorlevel 1 C:\\windows\\system32\\reg.exe add \"HKLM\\Software\\Valve\\Steam\\Apps\\7000\" /v \"openal\" /t REG_DWORD /d 2 /f") }
        let mark32 = lines.firstIndex { $0.contains("\"HKLM\\Software\\Wow6432Node\\Valve\\Steam\\Apps\\7000\"") }
        require(run != nil && mark != nil && mark32 != nil && run! < mark! && run! < mark32!, "program runs, then is marked done on status 0")
        require(lines.contains { $0.hasPrefix("C:\\windows\\system32\\msiexec.exe /i \"") && $0.hasSuffix("physics.msi\"") }, "MSI runs through msiexec")
        require(lines.contains { $0.contains("\"HKCU\\Software\\Fixture\"") }, "a per-user mark uses HKCU")
        require(batch.hasPrefix("@echo off\r\n") && batch.hasSuffix("\r\n"), "CRLF batch")

        // --- Shared depots: the game's record names owners; the owner's own record is merged.
        let apps = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ml1970-\(getpid())")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try AppManifestWriter.writeManifest(appID: 20, name: "Game", installDir: "Shared Folder", buildID: 9, steamID: 0,
                                            steamAppsPath: apps.path,
                                            installedDepots: [.init(depotID: 21, manifestGID: 111, size: 5)],
                                            sharedDepots: [(depotID: 31, ownerAppID: 30), (depotID: 39, ownerAppID: 30)])
        var parser = try SteamKeyValues(try Data(contentsOf: apps.appendingPathComponent("appmanifest_20.acf")))
        let game = try parser.read()["AppState"]
        require(game?["SharedDepots"]?["31"]?.string == "30" && game?["SharedDepots"]?["39"]?.string == "30", "SharedDepots names the owner app")
        require(game?["InstalledDepots"]?["31"] == nil && game?["InstalledDepots"]?["21"]?["manifest"]?.string == "111",
                "owner depots are not the game's own InstalledDepots")
        try AppManifestWriter.writeManifest(appID: 30, name: "Owner", installDir: "Shared Folder", buildID: 3, steamID: 0,
                                            steamAppsPath: apps.path, installedDepots: [.init(depotID: 35, manifestGID: 7, size: 1),
                                                                                       .init(depotID: 31, manifestGID: 1, size: 1)])
        try AppManifestWriter.mergeOwnerManifest(ownerAppID: 30, ownerName: "Owner", ownerBuildID: 4, installDir: "Shared Folder",
                                                 steamID: 0, steamAppsPath: apps.path,
                                                 depots: [.init(depotID: 31, manifestGID: 222, size: 10), .init(depotID: 39, manifestGID: 333, size: 20)])
        parser = try SteamKeyValues(try Data(contentsOf: apps.appendingPathComponent("appmanifest_30.acf")))
        let owner = try parser.read()["AppState"]
        require(owner?["InstalledDepots"]?["35"]?["manifest"]?.string == "7", "owner record keeps its other depots")
        require(owner?["InstalledDepots"]?["31"]?["manifest"]?.string == "222" && owner?["InstalledDepots"]?["39"]?["manifest"]?.string == "333",
                "installed shared depots replace their older entries")
        require(owner?["buildid"]?.string == "4" && owner?["StateFlags"]?.string == "4" && owner?["SizeOnDisk"]?.string == "31",
                "owner build, installed state and size")
        // ml1990: per-user custom executables (CEG) are listed for Valve's client.
        try AppManifestWriter.writeManifest(appID: 21, name: "Ceg", installDir: "Ceg", buildID: 1, steamID: 0,
                                            steamAppsPath: apps.path, installedDepots: [.init(depotID: 22, manifestGID: 1, size: 1)],
                                            customExecutables: ["pc\\game.exe", "tools\\a \"b\".exe"])
        parser = try SteamKeyValues(try Data(contentsOf: apps.appendingPathComponent("appmanifest_21.acf")))
        let ceg = try parser.read()["AppState"]?["CheckGuid"]
        require(ceg?["0"]?.string == "pc\\game.exe" && ceg?["1"]?.string == "tools\\a \"b\".exe", "CheckGuid lists custom executables, escaped")
        let state = SteamClientAppState.parse(try Data(contentsOf: apps.appendingPathComponent("appmanifest_20.acf")), appID: 20)
        require(state?.sharedOwners == [30], "progress follows the owner app")

        // --- Regular Steam versus Dock's client components.
        let steam = apps.appendingPathComponent("Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("bin/cef/cef.win64"), withIntermediateDirectories: true)
        require(!SteamPaths.hasDesktopClient(root: steam), "components without the web helper are not regular Steam")
        FileManager.default.createFile(atPath: steam.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe").path, contents: Data([0x4d, 0x5a]))
        require(SteamPaths.hasDesktopClient(root: steam), "the web helper marks regular Steam")
        try? FileManager.default.removeItem(at: apps)

        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("PASS: all ml1970 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-ml1970-') as td:
    td = Path(td)
    (td / 'stubs.swift').write_text(stubs)
    (td / 'checks.swift').write_text(checks)
    exe = td / 'checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                    str(td / 'stubs.swift'), str(td / 'checks.swift'),
                    str(app / 'SteamFiles.swift'), str(app / 'SwiftSteam/Install/AppManifestWriter.swift')], check=True)
    subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# Source guards for the wiring that needs UIKit / the whole app.
lib = (app / 'Library.swift').read_text()
cv = (app / 'ContentView.swift').read_text()
dock = (app / 'MadeiraDock.swift').read_text()
assert 'entry.steamGameLaunch && entry.steamDesktopLaunch != true' in dock, 'regular Steam choice bypasses Dock'
assert 'cmd.exe /c call \\(script) & \\"\\(MadeiraDock.executable)\\"' in lib, 'installers run before the host, same session'
assert 'LibraryModel.prepareDockInstallers(entry)' in cv and 'MADEIRA_DOCK_INSTALLERS' in cv
assert '"ml1970"' in dock and '"launch-update-wait"' in dock, 'Dock content-wait report fields accepted'
assert 'LibraryFlags.enabled("MADEIRA_LIBRARY_STEAM_BUTTON", fallback: false)' in lib, 'library Steam button hidden by default'
print("PASS: ml1970 integration guards; device execution still required")
