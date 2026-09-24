#!/usr/bin/env python3
"""Compile production Steam parsing/launch logic on the host; never run Wine."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
library = (root / 'app/Madeira/Library.swift').read_text()
entry = library[library.index('struct LibraryEntry:'):library.index('final class LibraryModel:')]
stubs = r'''
import Foundation
import Glibc
struct TouchControl: Codable {}
enum LibraryError: Error { case message(String) }
enum LibraryFlags {
    static func enabled(_ key: String, fallback: Bool = true) -> Bool { getenv(key).map { String(cString: $0) != "0" } ?? fallback }
}
class LibraryModel { static let drive = URL(fileURLWithPath: "/tmp/madeira-profile-fixture"); var entries: [LibraryEntry] = []; var current: UUID?; var readOnly = false; func persist(_ next: [LibraryEntry]) { entries = next }; static func executable(_ relative: String) throws -> URL { drive.appendingPathComponent(relative) }; MERGE_METHODS }
enum GuestDisplay { static func configureSessionDefault(view: CGSize, knob: String) {} }
final class LogStore { static let shared = LogStore(); func log(_ m: String) {} }
func madeira_set_vsync_locked(_ mode: Int32) {}
'''
stubs = stubs.replace('MERGE_METHODS', library[library.index('    func mergeSteam('):library.index('    private func persist(')])
checks = r'''
import Foundation
import Glibc
func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    if !condition() { throw SteamFileError.invalid("FAIL: " + label) }
}
func rejected(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw SteamFileError.invalid("FAIL: accepted " + label)
}
@main struct Checks {
    static func main() async throws {
        var parser = try SteamKeyValues(Data(#"// comment
        "LibraryFolders" { "0" { "path" "C:\\Steam" } "literal" "}" "quote" "a\"b" }
        "#.utf8))
        let values = try parser.read()
        try require(values["LIBRARYFOLDERS"]?["0"]?["path"]?.string == "C:\\Steam", "escaped Windows path")
        try require(values["libraryfolders"]?["literal"]?.string == "}", "quoted brace")
        for text in ["{", "x { y z", "x", "}", "x { y }", "x \"unterminated"] {
            try rejected("truncated VDF") { var p = try SteamKeyValues(Data(text.utf8)); _ = try p.read() }
        }
        try rejected("oversized VDF") { _ = try SteamKeyValues(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) }
        for path in ["../outside", "/outside", "C:\\outside", "a/../b", "a//b", "a\"b", "a\u{0}b", "\\outside"] {
            try require(SteamPaths.safeRelative(path, under: LibraryModel.drive) == nil, "unsafe path")
        }
        for url in ["http://cdn.akamai.steamstatic.com/x", "https://cdn.akamai.steamstatic.com.evil.example/x", "https://evil.example/x", "https://user@cdn.akamai.steamstatic.com/x"] {
            try require(!SteamPaths.trustedDownload(URL(string: url)), "untrusted redirect")
        }
        try require(SteamPaths.trustedDownload(SteamPaths.installerURL), "official HTTPS installer")
        try require(LibraryRendererBadge.compact("OpenGL/D3D9/D3D11") == "D3D11", "compact capability badge")
        // ml1490: redistributables and installers are never the game.
        for (path, reason) in [("PhysX/PhysX_SystemSoftware.exe", "folder:physx"), ("_CommonRedist\\vcredist\\2010\\vcredist_x86.exe", "folder:_commonredist"),
                               ("Redist/setup.exe", "folder:redist"), ("Support\\tool.exe", "folder:support"), ("DirectX/DXSETUP.exe", "folder:directx"),
                               ("PhysX_9.21_SystemSoftware.exe", "name:physx"), ("dxwebsetup.exe", "name:dxwebsetup"), ("oalinst.exe", "name:oalinst"),
                               ("VC_redist.x64.exe", "name:redist"), ("dotNetFx40_Full_x86_x64.exe", "name:dotnetfx"), ("UE3Redist.exe", "name:redist"),
                               ("UE4PrereqSetup_x64.exe", "name:prereq"), ("unins000.exe", "name:unins"), ("Uninstall.exe", "name:uninstall"),
                               ("DirectX_Jun2010_redist.exe", "name:redist"), ("NDP472-KB4054530-x86-x64-AllOS-ENU.exe", "name:ndp4")] {
            try require(SteamExecutableRules.installerReason(path) == reason, "installer \(path) -> \(SteamExecutableRules.installerReason(path) ?? "nil")")
        }
        for path in ["Binaries/Game.exe", "bin/win64/game-dx11.exe", "Launcher.exe", "Game_DX9.exe", "Supported/Game.exe"] {
            try require(SteamExecutableRules.installerReason(path) == nil, "may be the game: \(path)")
        }
        try require(SteamExecutableRules.installerReason(executable: "Games/X/PhysX/a.exe", installFolder: "Games/X") == "folder:physx" &&
                    SteamExecutableRules.installerReason(executable: "Other/PhysX/a.exe", installFolder: "Games/X") == nil &&
                    SteamExecutableRules.installerReason(executable: "Games/X/PhysX/a.exe", installFolder: nil) == nil &&
                    SteamExecutableRules.installerReason(executable: "games/x/Binaries/a.exe", installFolder: "Games/X") == nil,
                    "entries are judged only inside their install folder")
        var profile = LibraryEntry(title: "Fixture", relativePath: "Program Files (x86)/Steam/Steam.exe", bits: 0)
        profile.steamAppID = 12345; profile.steamInstalled = true
        profile.steamID = 54321; profile.arguments = "-windowed \"two words\""
        try profile.validate()
        try require(profile.launchArguments.contains("-applaunch 12345"), "launch identity independent of cover")
        try require(profile.launchArguments.contains(" -silent -applaunch 12345"), "game launch keeps the library window closed")
        setenv("MADEIRA_STEAM_SILENT", "0", 1)
        try require(!profile.launchArguments.contains("-silent"), "silent rollback")
        unsetenv("MADEIRA_STEAM_SILENT")
        try require(profile.launchArguments.contains("\"C:\\Program Files (x86)\\Steam\\Steam.exe\""), "quoted path")
        try require(profile.launchArguments.contains(" -cef-disable-hang-timeouts -nooverlay -nofriendsui -noshaders -cef-disable-breakpad"), "light client flags")
        // ml1500: the helper trim rides a game launch; the crash reporter process is gone.
        try require(profile.launchArguments.contains(" -skipstreamingdrivers -no-dwrite -silent -applaunch 12345") && profile.launchArguments.contains("-cef-single-process"), "lighter client flags on a game launch")
        setenv("MADEIRA_STEAM_CEF_LIGHT", "0", 1)
        try require(!profile.launchArguments.contains("-cef-disable-breakpad") && profile.launchArguments.contains("-noshaders -silent -applaunch 12345"), "lighter flags rollback")
        unsetenv("MADEIRA_STEAM_CEF_LIGHT")
        setenv("MADEIRA_STEAM_LIGHT", "0", 1)
        try require(!profile.launchArguments.contains("-nooverlay") && !profile.launchArguments.contains("-cef-disable-breakpad") && profile.launchArguments.contains("-applaunch 12345"), "light flags rollback")
        unsetenv("MADEIRA_STEAM_LIGHT")
        profile.configureLaunch()
        try require(String(cString: getenv("MADEIRA_EXE")) == "explorer.exe", "desktop wrapper")
        try require(String(cString: getenv("MADEIRA_DESKTOP")) == "1", "desktop memory policy")
        // ml1500: the client and its helpers get background scheduling classes; the game does not.
        try require(String(cString: getenv("MADEIRA_QOS_DEFAULT_EXES")) == "Steam.exe" && String(cString: getenv("MADEIRA_QOS_UTILITY_EXES")).contains("steamwebhelper.exe"), "client background classes")
        setenv("MADEIRA_STEAM_BACKGROUND_QOS", "0", 1); profile.configureLaunch()
        try require(getenv("MADEIRA_QOS_UTILITY_EXES") == nil && getenv("MADEIRA_QOS_DEFAULT_EXES") == nil, "background classes rollback")
        unsetenv("MADEIRA_STEAM_BACKGROUND_QOS"); profile.configureLaunch()
        // ml1490: the ordered profile is off unless asked for.
        try require(String(cString: getenv("MADEIRA_ORDERED_PROFILE")) == "0" && getenv("MADEIRA_ORDERED_PROFILE_CLIENT") == nil,
                    "ordered profile off by default, client not named")
        setenv("MADEIRA_ORDERED_PROFILE", "1", 1); setenv("MADEIRA_STEAM_ORDERED_CLIENT", "1", 1); profile.configureLaunch()
        try require(String(cString: getenv("MADEIRA_ORDERED_PROFILE")) == "1"
                    && String(cString: getenv("MADEIRA_ORDERED_PROFILE_CLIENT")) == "Steam.exe", "opt-in names the client executable")
        setenv("MADEIRA_STEAM_ORDERED_CLIENT", "0", 1); profile.configureLaunch()
        try require(getenv("MADEIRA_ORDERED_PROFILE_CLIENT") == nil, "client ordering rollback")
        unsetenv("MADEIRA_STEAM_ORDERED_CLIENT"); setenv("MADEIRA_ORDERED_PROFILE", "0", 1)
        // ml1490: the store identity reaches only a direct launch; the client sets it for the games it starts.
        setenv("MADEIRA_STEAM_APPID", "999", 1); profile.configureLaunch()
        try require(getenv("MADEIRA_STEAM_APPID") == nil, "client-routed launch publishes no store identity")
        try require(profile.steamGameLaunch, "client-routed game launch holds the starting screen")
        var direct = LibraryEntry(title: "Direct", relativePath: "Games/Fixture/game.exe", bits: 32)
        direct.steamAppID = 12345; direct.steamNative = true; direct.steamInstalled = true
        direct.configureLaunch()
        try require(!direct.usesSteam && String(cString: getenv("MADEIRA_STEAM_APPID")) == "12345", "direct launch publishes its store identity")
        try require(!direct.steamGameLaunch, "a direct launch has no client to wait for")
        direct.steamClientLaunch = true; direct.steamClientPath = "Program Files (x86)/Steam/steam.exe"; direct.configureLaunch()
        try require(direct.usesSteam && getenv("MADEIRA_STEAM_APPID") == nil && direct.steamGameLaunch, "client-routed native entry: none, and held")
        var artwork = LibraryEntry(title: "Art only", relativePath: "Games/Fixture/game.exe", bits: 32)
        artwork.steamID = 54321; setenv("MADEIRA_STEAM_APPID", "999", 1); artwork.configureLaunch()
        try require(getenv("MADEIRA_STEAM_APPID") == nil, "artwork identity is not a store identity")
        var openSteam = LibraryEntry(title: "Steam", relativePath: "Program Files (x86)/Steam/steam.exe", bits: 32)
        openSteam.steamSession = "client"
        try require(openSteam.usesSteam && !openSteam.steamGameLaunch, "opening the client itself shows it")
        profile.steamInstalled = false
        try require(profile.launchArguments.contains("steam://install/12345"), "reinstall route")
        try require(!profile.launchArguments.contains("-silent"), "install route shows Steam")
        try require(!profile.steamGameLaunch, "install route shows the client instead of holding")
        profile.arguments = Array(repeating: "argument", count: 64).joined(separator: " ")
        try rejected("combined bridge argument overflow") { try profile.validate() }
        profile.arguments = ""; profile.relativePath = "../Steam.exe"
        try rejected("launch outside drive_c") { try profile.validate() }
        profile.relativePath = "Steam/Steam.exe"; profile.steamAppID = -1
        try rejected("invalid app ID") { try profile.validate() }
        profile.steamAppID = 12345
        setenv("MADEIRA_STEAM", "0", 1)
        try rejected("disabled integration") { try profile.validate() }
        unsetenv("MADEIRA_STEAM")
        let encoded = try JSONEncoder().encode(profile)
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["steamAppID", "steamInstalled", "steamInstallPath", "steamSession", "steamBigPicture"] { old.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: old))
        try require(!legacy.usesSteam && legacy.steamID == 54321, "old artwork does not opt into Steam launching")
        let manager = FileManager.default
        let drive = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: drive) }
        let client = drive.appendingPathComponent("Program Files (x86)/Steam/Steam.exe")
        try manager.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pe = Data(repeating: 0, count: 128); pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64
        pe[64] = 0x50; pe[65] = 0x45; pe[68] = 0x4c; pe[69] = 1
        try pe.write(to: client)
        let apps = client.deletingLastPathComponent().appendingPathComponent("steamapps")
        try manager.createDirectory(at: apps.appendingPathComponent("common/Fixture"), withIntermediateDirectories: true)
        let manifest = apps.appendingPathComponent("appmanifest_12345.acf")
        let text = #"""
        "AppState" { "appid" "12345" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" "SizeOnDisk" "1234567890" }
        """#
        try Data(text.utf8).write(to: manifest)
        var snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(snapshot.client == "Program Files (x86)/Steam/Steam.exe", "case insensitive client discovery")
        try require(snapshot.apps.count == 1 && snapshot.apps[0].installed && snapshot.apps[0].bytes == 1234567890, "installed manifest")
        UserDefaults.standard.removeObject(forKey: "madeiraSteamHidden")
        let model = LibraryModel(); model.mergeSteam(snapshot)
        try require(model.entries.count == 1 && model.entries[0].steamAppID == 12345, "automatic import")
        model.entries[0].title = "Custom title"; model.entries[0].arguments = "-windowed"; model.entries[0].steamID = 54321
        model.mergeSteam(snapshot)
        try require(model.entries.count == 1 && model.entries[0].title == "Custom title" && model.entries[0].arguments == "-windowed" && model.entries[0].steamID == 54321, "refresh preserves customization")
        var partial = snapshot; partial.apps = []; partial.complete = false; model.mergeSteam(partial)
        try require(model.entries[0].steamInstalled == true, "partial scan preserves installed state")
        partial.complete = true; model.mergeSteam(partial)
        try require(model.entries[0].steamInstalled == false, "uninstall detected")
        model.remove(model.entries[0].id); model.mergeSteam(snapshot)
        try require(model.entries.isEmpty, "removed entries stay hidden")
        UserDefaults.standard.removeObject(forKey: "madeiraSteamHidden")
        try Data(text.replacingOccurrences(of: "\"4\"", with: "\"2\"").utf8).write(to: manifest)
        snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(!snapshot.apps[0].installed && snapshot.apps[0].needsUpdate, "incomplete download not installed")
        try Data(text.replacingOccurrences(of: "StateFlags", with: "MissingField").utf8).write(to: manifest)
        snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(!snapshot.complete && snapshot.apps.isEmpty, "missing installation state is not an uninstall")
        try Data("\"AppState\" {".utf8).write(to: manifest)
        snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(!snapshot.complete && snapshot.unreadableManifests == 1, "partial write preserves previous installation state")
        try Data(text.utf8).write(to: manifest)
        let other = drive.appendingPathComponent("Other Library/steamapps")
        try manager.createDirectory(at: other.appendingPathComponent("common/Extra"), withIntermediateDirectories: true)
        try Data(text.replacingOccurrences(of: "12345", with: "23456").replacingOccurrences(of: "Fixture", with: "Extra").utf8)
            .write(to: other.appendingPathComponent("appmanifest_23456.acf"))
        let folders = apps.appendingPathComponent("libraryfolders.vdf")
        try Data(#"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "C:\\Other Library" } }
        """#.utf8).write(to: folders)
        snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(snapshot.complete && snapshot.apps.count == 2, "multiple modern libraries")
        try Data(#"""
        "libraryfolders" { "1" "C:\\Other Library" "2" "D:\\External" }
        """#.utf8).write(to: folders)
        snapshot = try await SteamDisk.shared.snapshot(drive: drive, preferredClient: nil)
        try require(snapshot.apps.count == 2 && snapshot.skippedLibraries == 1, "legacy library format and external library exclusion")
        try manager.createSymbolicLink(at: drive.appendingPathComponent("escape"), withDestinationURL: drive.deletingLastPathComponent())
        try require(SteamPaths.safeRelative("escape/outside", under: drive) == nil, "symlink containment")
        let bits = try await SteamDisk.shared.storeInstaller(client, drive: drive)
        try require(bits == 32, "installer staging")
        try require(try Data(contentsOf: drive.appendingPathComponent(SteamPaths.installerRelative)) == pe, "installer bytes preserved")
        print("PASS: Steam parsing, containment, partial installs, staging, profile migration and launch routing")
    }
}
'''
# Swift multiline raw strings require triple delimiters.
checks = checks.replace('Data(#"// comment', 'Data(#"""\n        // comment').replace('        "#.utf8))', '        """#.utf8))')
checks = checks.replace('try require(try Data(contentsOf: drive.appendingPathComponent(SteamPaths.installerRelative)) == pe,', 'let staged = try Data(contentsOf: drive.appendingPathComponent(SteamPaths.installerRelative))\n        try require(staged == pe,')
with tempfile.TemporaryDirectory(prefix='madeira-steam-check-') as directory:
    folder = Path(directory)
    (folder / 'Profile.swift').write_text(stubs + entry)
    (folder / 'Checks.swift').write_text(checks)
    executable = folder / 'check'
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc', '-parse-as-library',
                    str(root / 'app/Madeira/SteamFiles.swift'), str(folder / 'Profile.swift'),
                    str(folder / 'Checks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
