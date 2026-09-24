#!/usr/bin/env python3
"""ml1530: compile the first-run setup's pure logic (Onboarding.swift) on the host.

Covers the first-run decision, the setup's pages, the default start mode of
native Steam games, the install gate, and moving a Steam folder without
steam.exe aside and back on a temporary directory. Never runs Wine."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
onboarding = (app / 'Onboarding.swift').read_text()
rules = onboarding[onboarding.index('// MARK: - ml1530 rules'):onboarding.index('// MARK: - ml1530 setup model')]

# Wiring that the compiled part cannot show.
library = (app / 'Library.swift').read_text()
views = (app / 'SteamStoreViews.swift').read_text()
steam_library = (app / 'SteamLibrary.swift').read_text()
for needle, label in [
    ('.fullScreenCover(isPresented: $onboarding.presented)', 'setup presented over the library'),
    ('onboarding.presentIfNeeded()', 'setup considered when the library appears'),
    ('onboarding.rerun()', 'Settings reopens setup'),
    ('OnboardingFinishButton()', 'finish button over the Wine desktop'),
    ('stored.steamClientLaunch == nil { played.steamClientLaunch = nil }', 'default start mode not stored as a choice'),
    ('model.save(stored); play(profile)', 'details save the unresolved entry'),
    ('steamClient.clientEntry(bigPicture: false)', 'library Steam button opens the client'),
]:
    assert needle in library, 'Library.swift: ' + label
assert 'OnboardingRules.installNeedsClient(' in views and 'MADEIRA_STEAM_REQUIRE_CLIENT' in views, 'install gate'
assert 'entry.startsWithClient' in views, 'start-with picker shows the default'
assert 'await restorePendingInstallFolder()' in steam_library and 'model.prepareInstallerFolder()' in steam_library, 'Steam UI installer moves the folder aside'
for key in ['MADEIRA_ONBOARDING', 'MADEIRA_STEAM_DEFAULT_CLIENT']:
    assert key in onboarding, key
assert 'MADEIRA_STEAM_INSTALL_MOVE_ASIDE' in steam_library
# The developer skip stays unannounced.
title = onboarding[onboarding.index('Text("Welcome to Madeira")'):]
title = title[:title.index('\n', title.index('.onTapGesture'))]
assert 'accessibility' not in title and 'hint' not in title.lower(), 'skip is not announced'
assert '[onboarding] ml1530 skipped (developer)' in onboarding

# ml1530: the ended session's desktop is hidden when setup closes and when a session ends.
assert 'EndedSessionSurface.install()' in library, 'library installs the ended-desktop guard'
assert 'EndedSessionSurface.hide(reason: "setup-closed")' in onboarding, 'setup closing hides the ended desktop'
assert 'EndedSessionSurface.hide(reason: "install-session-ended")' in onboarding
assert 'winios_compositor_set_hidden(1)' in onboarding and 'window.subviews' not in onboarding, 'the ended desktop is hidden by name (Winios.m), not by a view search'
assert 'int winios_compositor_set_hidden(int hidden)' in (root / 'app/Madeira/Winios/Winios.m').read_text(), 'Winios.m provides the hide call'
assert 'MADEIRA_LIBRARY_HIDE_ENDED_DESKTOP' in onboarding
# ml1540: restart before the first game after setup's session; the setup's first session gets 896 MB.
content = (app / 'ContentView.swift').read_text()
assert 'Self.restartAdvised = true' in onboarding and 'MADEIRA_SETUP_RESTART_PROMPT' in onboarding, 'setup marks the run'
assert 'OnboardingModel.restartAdvised, OnboardingModel.restartPromptEnabled, entry.steamSession != "installer"' in content, 'launches wait for a restart'
assert '.alert("Restart Madeira", isPresented: $restartAlert)' in onboarding, 'done page asks for the restart'
jit = (app / 'StikJITHelper.swift').read_text()
assert 'MADEIRA_POOL_SETUP_896' in jit and '!UserDefaults.standard.bool(forKey: OnboardingRules.doneKey)' in jit, 'setup session gets the 896 MB pool'
# ml1570: setup's session gets the largest pool; the finish button is tappable over a session.
assert 'sizeMB = 1152; source = "setup' in jit, 'setup session gets 1152 MB'
assert 'library.finishButtonRect.contains(point)' in content, 'controls window lets the finish button through'
assert 'LibraryModel.shared.finishButtonRect = frame.insetBy' in onboarding and 'MADEIRA_SETUP_BUTTON_HITTEST' in onboarding, 'finish button publishes its frame'

# The installer's launch profile (LibraryEntry, compiled with the same stubs as check-steam-library.py).
entry = library[library.index('struct LibraryEntry:'):library.index('final class LibraryModel:')]
stubs = r'''
import Foundation
import Glibc
struct TouchControl: Codable {}
enum LibraryError: Error { case message(String) }
enum LibraryFlags {
    static func enabled(_ key: String, fallback: Bool = true) -> Bool { getenv(key).map { String(cString: $0) != "0" } ?? fallback }
}
class LibraryModel { static let drive = URL(fileURLWithPath: "/tmp/madeira-onboarding-fixture"); var entries: [LibraryEntry] = []; var current: UUID?; var readOnly = false; func persist(_ next: [LibraryEntry]) { entries = next }; static func executable(_ relative: String) throws -> URL { drive.appendingPathComponent(relative) }; MERGE_METHODS }
enum GuestDisplay { static func configureSessionDefault(view: CGSize, knob: String) {} }
final class LogStore { static let shared = LogStore(); func log(_ m: String) {} }
func madeira_set_vsync_locked(_ mode: Int32) {}
'''
stubs = stubs.replace('MERGE_METHODS', library[library.index('    func mergeSteam('):library.index('    private func persist(')])

checks = r'''
import Foundation
@main struct Checks {
    static func require(_ condition: Bool, _ label: String) {
        if !condition { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    /// WineProcessBridge.m's MADEIRA_ARGS split: whitespace separates, double quotes group and are removed.
    static func bridgeTokens(_ text: String) -> [String] {
        var tokens: [String] = [], current = "", quoted = false, open = false
        for character in text {
            if character == "\"" { quoted.toggle(); open = true; continue }
            if !quoted && (character == " " || character == "\t") {
                if open { tokens.append(current); current = ""; open = false }
                continue
            }
            current.append(character); open = true
        }
        if open { tokens.append(current) }
        return tokens
    }
    static func installerChecks() throws {
        var installer = LibraryEntry(title: "Install Steam", relativePath: SteamPaths.installerRelative, bits: 32)
        installer.steamSession = "installer"; installer.reducedX87 = false
        try installer.validate()
        let keepAlive = installer.launchArguments
        require(keepAlive == #"/desktop=madeira,1280x720 C:\windows\system32\cmd.exe /c call "C:\Madeira\Downloads\SteamSetup.exe" & C:\windows\system32\services.exe"#,
                "installer session runs the installer, then keeps services.exe running: \(keepAlive)")
        require(bridgeTokens(keepAlive) == ["/desktop=madeira,1280x720", #"C:\windows\system32\cmd.exe"#, "/c", "call",
                                            #"C:\Madeira\Downloads\SteamSetup.exe"#, "&", #"C:\windows\system32\services.exe"#],
                "bridge argv for the installer session")
        require(!keepAlive.contains("start.exe") && !keepAlive.contains(" start "), "no start.exe (it faulted on device, log 202)")
        require(!keepAlive.contains("-nooverlay") && !keepAlive.contains("-applaunch"), "no client flags on the installer")
        installer.relativePath = "Madeira/My Downloads/SteamSetup.exe"
        try installer.validate()
        require(bridgeTokens(installer.launchArguments).dropFirst(4).first == #"C:\Madeira\My Downloads\SteamSetup.exe"#, "installer path with a space stays one argument")
        installer.relativePath = SteamPaths.installerRelative
        setenv("MADEIRA_STEAM_INSTALL_KEEPALIVE", "0", 1)
        require(installer.launchArguments == #"/desktop=madeira,1280x720 "C:\Madeira\Downloads\SteamSetup.exe""#, "keep-alive rollback")
        unsetenv("MADEIRA_STEAM_INSTALL_KEEPALIVE")
        var client = LibraryEntry(title: "Steam", relativePath: "Program Files (x86)/Steam/steam.exe", bits: 0)
        client.steamSession = "client"
        require(!client.launchArguments.contains("cmd.exe") && !client.launchArguments.contains("services.exe"), "opening the client is unchanged")
        var desktop = LibraryEntry.desktopEntry
        desktop.resolution = "1280x720"
        require(desktop.launchArguments == #"/desktop=shell,1280x720 C:\windows\system32\services.exe"#, "Desktop session unchanged")
    }
    static func main() throws {
        try installerChecks()
        typealias R = OnboardingRules
        require(R.doneKey == "madeiraOnboardingDone", "done key")
        require(R.shouldShow(done: false, enabled: true), "new install shows setup")
        require(!R.shouldShow(done: true, enabled: true), "finished setup stays closed")
        require(!R.shouldShow(done: false, enabled: false), "MADEIRA_ONBOARDING=0 never shows it")
        let defaults = UserDefaults(suiteName: "madeira-onboarding-check")!
        defaults.removePersistentDomain(forName: "madeira-onboarding-check")
        require(R.shouldShow(done: defaults.bool(forKey: R.doneKey), enabled: true), "missing flag (fresh install) shows setup")
        defaults.set(true, forKey: R.doneKey)
        require(!R.shouldShow(done: defaults.bool(forKey: R.doneKey), enabled: true), "stored flag hides setup")
        defaults.removePersistentDomain(forName: "madeira-onboarding-check")

        require(R.steps(steam: true, nativeSteam: true) == [.welcome, .steamClient, .signIn, .done], "full setup")
        require(R.steps(steam: true, nativeSteam: false) == [.welcome, .steamClient, .done], "no native sign-in page")
        require(R.steps(steam: false, nativeSteam: true) == [.welcome, .done], "no Steam pages without Steam")
        require(R.Step.steamClient.rawValue == "steam-client" && R.Step.signIn.rawValue == "sign-in", "log step names")

        require(R.clientLaunch(stored: nil, clientInstalled: true, defaultClient: true), "default: Steam client when installed")
        require(!R.clientLaunch(stored: nil, clientInstalled: false, defaultClient: true), "default: the game without a client")
        require(!R.clientLaunch(stored: nil, clientInstalled: true, defaultClient: false), "MADEIRA_STEAM_DEFAULT_CLIENT=0")
        require(!R.clientLaunch(stored: false, clientInstalled: true, defaultClient: true), "explicit 'the game' kept")
        require(R.clientLaunch(stored: true, clientInstalled: false, defaultClient: false), "explicit 'Steam client' kept")

        require(R.installNeedsClient(clientInstalled: false, required: true), "gate without client")
        require(!R.installNeedsClient(clientInstalled: true, required: true), "no gate with client")
        require(!R.installNeedsClient(clientInstalled: false, required: false), "MADEIRA_STEAM_REQUIRE_CLIENT=0")

        let fm = FileManager.default
        let drive = fm.temporaryDirectory.appendingPathComponent("madeira-onboarding-" + UUID().uuidString)
        defer { try? fm.removeItem(at: drive) }
        let parent = drive.appendingPathComponent("Program Files (x86)", isDirectory: true)
        let steam = parent.appendingPathComponent("Steam", isDirectory: true)
        func write(_ path: String, _ text: String) throws {
            let url = steam.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        require(!SteamInstallFolder.needsMoveAside(steam), "no Steam folder: nothing to move")
        require(try SteamInstallFolder.moveAside(steam) == nil, "no folder, no move")
        try fm.createDirectory(at: steam, withIntermediateDirectories: true)
        require(!SteamInstallFolder.needsMoveAside(steam), "empty Steam folder is fine for the installer")

        // Madeira's downloader made steamapps before the client existed.
        try write("steamapps/appmanifest_10.acf", "downloaded manifest")
        try write("steamapps/common/Fixture/game.exe", "game")
        try write("steamapps/libraryfolders.vdf", "downloader libraryfolders")
        require(SteamInstallFolder.needsMoveAside(steam), "downloads without steam.exe move aside")
        let pending = try SteamInstallFolder.moveAside(steam)
        require(pending?.lastPathComponent == "Steam.madeira-pending", "pending folder name")
        require(!fm.fileExists(atPath: steam.path), "Steam folder free for the installer")
        require(SteamInstallFolder.pendingFolders(steam).count == 1, "pending folder found")

        // The installer creates the client; Steam writes its own libraryfolders.vdf.
        try write("Steam.exe", "client")
        try write("steamapps/libraryfolders.vdf", "client libraryfolders")
        require(SteamInstallFolder.hasClient(steam) && !SteamInstallFolder.needsMoveAside(steam), "client found in any case")
        let report = try SteamInstallFolder.mergeBack(steam)
        require(report.folders == 1 && report.moved == 2 && report.kept == 1, "merge counts \(report)")
        require(read(steam.appendingPathComponent("steamapps/appmanifest_10.acf")) == "downloaded manifest", "manifest moved back")
        require(read(steam.appendingPathComponent("steamapps/common/Fixture/game.exe")) == "game", "game files moved back")
        require(read(steam.appendingPathComponent("steamapps/libraryfolders.vdf")) == "client libraryfolders", "Steam's file is not replaced")
        require(report.removed == 0 && SteamInstallFolder.pendingFolders(steam).count == 1, "conflicting leftover keeps the pending folder")
        let leftover = pending!.appendingPathComponent("steamapps/libraryfolders.vdf")
        require(read(leftover) == "downloader libraryfolders", "leftover kept, not deleted")
        require(!fm.fileExists(atPath: pending!.appendingPathComponent("steamapps/common").path), "emptied folders pruned")
        try fm.removeItem(at: leftover)
        let again = try SteamInstallFolder.mergeBack(steam)
        require(again.removed == 1 && SteamInstallFolder.pendingFolders(steam).isEmpty, "empty pending folder removed")
        require(try SteamInstallFolder.moveAside(steam) == nil, "an installed client is never moved")

        // The installer failed: the games go back where they were.
        try fm.removeItem(at: steam)
        try write("steamapps/appmanifest_20.acf", "second")
        try fm.createDirectory(at: parent.appendingPathComponent("Steam.madeira-pending"), withIntermediateDirectories: true)
        try Data("older".utf8).write(to: parent.appendingPathComponent("Steam.madeira-pending/old.txt"))
        let second = try SteamInstallFolder.moveAside(steam)
        require(second?.lastPathComponent == "Steam.madeira-pending-2", "a second pending folder gets its own name")
        let restored = try SteamInstallFolder.mergeBack(steam)
        require(restored.folders == 2 && restored.removed == 2 && restored.kept == 0, "both restored \(restored)")
        require(read(steam.appendingPathComponent("steamapps/appmanifest_20.acf")) == "second" &&
                read(steam.appendingPathComponent("old.txt")) == "older", "restored without a client")
        require(SteamInstallFolder.pendingFolders(steam).isEmpty, "nothing pending")
        print("PASS: first-run decision, setup pages, default start mode, install gate, Steam folder move-aside and merge-back, installer keep-alive session")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-onboarding-check-') as directory:
    folder = Path(directory)
    (folder / 'Rules.swift').write_text('import Foundation\n' + rules)
    (folder / 'Profile.swift').write_text(stubs + entry)
    (folder / 'Checks.swift').write_text(checks)
    executable = folder / 'check'
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc', '-parse-as-library',
                    str(folder / 'Rules.swift'), str(folder / 'Profile.swift'), str(app / 'SteamFiles.swift'),
                    str(folder / 'Checks.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
