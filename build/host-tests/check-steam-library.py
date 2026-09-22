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
    static func enabled(_ key: String) -> Bool { getenv(key).map { String(cString: $0) != "0" } ?? true }
}
class LibraryModel { static let drive = URL(fileURLWithPath: "/tmp/madeira-profile-fixture"); var entries: [LibraryEntry] = []; var current: UUID?; var readOnly = false; func persist(_ next: [LibraryEntry]) { entries = next }; MERGE_METHODS }
enum GuestDisplay { static func configureSessionDefault(view: CGSize, knob: String) {} }
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
        var profile = LibraryEntry(title: "Fixture", relativePath: "Program Files (x86)/Steam/Steam.exe", bits: 0)
        profile.steamAppID = 12345; profile.steamInstalled = true
        profile.steamID = 54321; profile.arguments = "-windowed \"two words\""
        try profile.validate()
        try require(profile.launchArguments.contains("-applaunch 12345"), "launch identity independent of cover")
        try require(profile.launchArguments.contains("\"C:\\Program Files (x86)\\Steam\\Steam.exe\""), "quoted path")
        profile.configureLaunch()
        try require(String(cString: getenv("MADEIRA_EXE")) == "explorer.exe", "desktop wrapper")
        try require(String(cString: getenv("MADEIRA_DESKTOP")) == "1", "desktop memory policy")
        profile.steamInstalled = false
        try require(profile.launchArguments.contains("steam://install/12345"), "reinstall route")
        profile.arguments = Array(repeating: "argument", count: 16).joined(separator: " ")
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
