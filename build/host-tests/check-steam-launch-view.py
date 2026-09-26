#!/usr/bin/env python3
"""ml1490 host checks for the Steam launch screen; never runs Wine, Steam or iOS.

Part A compiles production Swift (SteamFiles.swift, AppManifestWriter.swift) on
the host under AddressSanitizer: which window a client-routed launch shows
(SteamLaunchScene, fixtures shaped like device logs 185-187), when the starting
screen hides or shows the desktop (SteamLaunchHold), and the Workshop update
read from the client's content log and Workshop record (the log lines are the
client's own wording from device logs 185 and 187).

Part B extracts the window census from app/Madeira/Winios/Winios.m (plain C
inside the Objective-C file) and drives it with stubbed win32u/ntdll entry
points under ASan/UBSan, then concurrently under ThreadSanitizer.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = '/home/hero/.local/share/swiftly/bin/swiftc'
CC = 'cc'

# ---------------------------------------------------------------- Part A
stubs = r'''
import Foundation
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-launch-view/steamapps") } }
'''

checks = r'''
import Foundation
import Glibc
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func window(_ image: String, _ w: Int, _ h: Int, visible: Bool = true, drawn: Bool = true) -> SteamLaunchWindow {
    SteamLaunchWindow(image: image, width: w, height: h, visible: visible, drawn: drawn)
}

@main struct Checks {
    static func main() throws {
        // --- Which window is up (shapes from device logs 185-187).
        let console = window("conhost.exe", 665, 509)            // the Chromium helper's console window
        let tray = window("explorer.exe", 166, 52)                // explorer's small captioned window
        let signInHidden = window("steamwebhelper.exe", 705, 440, visible: false)
        let mainHidden = window("steam.exe", 1280, 720, visible: false)
        let before = [console, tray, signInHidden, mainHidden]
        require(SteamLaunchScene.decide(before, rendered: false).scene == .waiting, "client console, tray and hidden client windows: keep waiting")
        require(SteamLaunchScene.decide(before, rendered: true).scene == .waiting, "D3D frames never make a helper's window the game's")
        let game = window("launcher_or_game.exe", 1280, 720)
        let decided = SteamLaunchScene.decide(before + [game], rendered: false)
        require(decided.scene == .game && decided.window == game, "another program's shown window is the game's")
        require(SteamLaunchScene.decide(before + [window("Game.EXE", 1280, 720, drawn: false)], rendered: false).scene == .waiting,
                "an undrawn game window waits for its first frame")
        require(SteamLaunchScene.decide(before + [window("game.exe", 1280, 720, drawn: false)], rendered: true).scene == .game,
                "D3D frames count as the game window's first frame")
        require(SteamLaunchScene.decide([window("game.exe", 150, 40)], rendered: true).scene == .waiting, "small windows are not the game")
        require(SteamLaunchScene.decide([window("game.exe", 1280, 720, visible: false)], rendered: true).scene == .waiting, "hidden windows are not the game")
        require(SteamLaunchScene.decide([window("", 1280, 720)], rendered: false).scene == .waiting &&
                SteamLaunchScene.decide([window("", 1280, 720)], rendered: true).scene == .game,
                "unknown owner: only D3D frames decide")
        let signIn = window("steamwebhelper.exe", 705, 440)
        let asked = SteamLaunchScene.decide(before + [signIn], rendered: false)
        require(asked.scene == .steamWindow && asked.window == signIn, "a shown client dialog needs the user")
        require(SteamLaunchScene.decide([window("steam.exe", 705, 440, drawn: false)], rendered: false).scene == .waiting, "an undrawn client window does not")
        require(SteamLaunchScene.decide([window("steam.exe", 200, 100)], rendered: false).scene == .waiting, "a small client window does not")
        require(SteamLaunchScene.decide([signIn, game], rendered: false).scene == .game, "the game's window wins over a client window")
        for helper in ["vcredist_x86.exe", "VC_redist.x64.exe", "dxsetup.exe", "iscriptevaluator.exe", "msiexec.exe", "wineboot.exe"] {
            require(SteamLaunchScene.owner(helper) == .helper, "first-start helper \(helper)")
        }
        // ml1760: an installer's error box holds the launch, so it needs the user too.
        let fatal = window("msiexec.exe", 326, 140)
        require(SteamLaunchScene.decide([fatal], rendered: false).scene == .steamWindow, "an installer dialog needs the user")
        require(SteamLaunchScene.decide([window("msiexec.exe", 200, 100)], rendered: false).scene == .waiting, "a small installer window does not")
        require(SteamLaunchScene.decide([window("PhysX_SystemSoftware.exe", 480, 360, drawn: false)], rendered: false).scene == .waiting, "an undrawn installer window does not")
        require(SteamLaunchScene.decide([window("explorer.exe", 480, 360)], rendered: false).scene == .waiting, "other helpers stay ignored")
        require(SteamLaunchScene.decide([fatal, game], rendered: false).scene == .game, "the game's window still wins")
        require(SteamLaunchScene.owner("STEAMWEBHELPER.EXE") == .client && SteamLaunchScene.owner("") == .unknown &&
                SteamLaunchScene.owner("program.exe") == .other, "owner classes")

        // --- When the starting screen hides or shows the desktop.
        var hold = SteamLaunchHold(autoReveal: true)
        var actions: [SteamLaunchHold.Action] = []
        for (t, scene) in [(0.0, SteamLaunchScene.waiting), (1, .steamWindow), (2.5, .steamWindow), (3, .steamWindow)] {
            actions.append(hold.step(scene, now: t))
        }
        require(actions == [.none, .none, .none, .reveal] && hold.revealed && !hold.needsAttention, "reveal after the client window stays 2 s (\(actions))")
        actions = [hold.step(.waiting, now: 4), hold.step(.steamWindow, now: 5), hold.step(.waiting, now: 6), hold.step(.waiting, now: 9.5), hold.step(.waiting, now: 10)]
        require(actions == [.none, .none, .none, .none, .cover] && !hold.revealed, "cover 4 s after it closed, restarted by a reappearance (\(actions))")
        _ = hold.step(.steamWindow, now: 11)
        require(hold.needsAttention, "attention while the client window is behind the starting screen")
        require(hold.step(.game, now: 12) == .showGame && hold.finished && hold.step(.steamWindow, now: 20) == .none, "the game's window ends the hold")

        var manual = SteamLaunchHold(autoReveal: true)
        require(manual.showSteam(waitForWindow: false) && !manual.showSteam(waitForWindow: false), "Show Steam reveals once")
        // ml1530: tapped before the client has a window, the tap waits for one and reveals at once.
        var early = SteamLaunchHold(autoReveal: true)
        require(!early.showSteam() && early.pendingReveal && !early.revealed, "early Show Steam waits for the client's window")
        require(early.step(.waiting, now: 1) == .none && early.step(.steamWindow, now: 2) == .reveal && early.revealed && early.manual,
                "the client's window is revealed as soon as it appears, no 2 s delay")
        require(early.step(.waiting, now: 100) == .none && early.revealed, "and stays shown like a manual reveal")
        var shown = SteamLaunchHold(autoReveal: true)
        _ = shown.step(.steamWindow, now: 0)
        require(shown.showSteam() && shown.revealed, "with a client window up, Show Steam reveals at once")
        require(manual.step(.waiting, now: 100) == .none && manual.revealed, "a manual reveal is never covered again")
        require(manual.step(.game, now: 101) == .showGame, "game after a manual reveal")

        var off = SteamLaunchHold(autoReveal: false)
        require((0..<20).allSatisfy { off.step(.steamWindow, now: Double($0)) == .none } && off.needsAttention, "auto-reveal off: button and hint only")

        var flapping = SteamLaunchHold(autoReveal: true)
        var reveals = 0, covers = 0, t = 0.0
        for _ in 0..<20 {
            for _ in 0..<6 { if flapping.step(.steamWindow, now: t) == .reveal { reveals += 1 }; t += 0.5 }
            for _ in 0..<10 { if flapping.step(.waiting, now: t) == .cover { covers += 1 }; t += 0.5 }
        }
        require(reveals == SteamLaunchHold.maxAutoReveals && covers == SteamLaunchHold.maxAutoReveals - 1 && flapping.revealed,
                "a flapping client window stops toggling and stays shown (reveals=\(reveals) covers=\(covers))")

        // --- ml1510: the launch stage, from the client's connection and content lines.
        var stage = SteamLaunchStage.starting
        stage = stage.after("[2026-09-23 14:34:29] Connectivity test: result=Connected (since 0.0s ago), prev=Unknown, in progress=0", appID: 7000)
        require(stage == .starting, "connectivity test leaves it starting")
        stage = stage.after("[2026-09-23 14:34:29] [Logged Off, 4, 0] [U:1:#] LogOn() called; not connected yet, scheduling connection. Schedule init returned 1", appID: 7000)
        require(stage == .signingIn, "logon called -> signing in")
        stage = stage.after("[2026-09-23 14:34:30] [Logged On, 4, 7] [U:1:#] RecvMsgClientLogOnResponse() : processing complete", appID: 7000)
        require(stage == .signedIn, "logon response -> signed in")
        stage = stage.after("[2026-09-23 14:34:31] AppID 7001 state changed : Fully Installed,App Running,", appID: 7000)
        require(stage == .signedIn, "another app's state is ignored")
        stage = stage.after("[2026-09-23 14:34:31] AppID 7000 state changed : Fully Installed,Update Queued,Update Running,", appID: 7000)
        require(stage == .updating, "update running -> updating")
        stage = stage.after("[2026-09-23 14:35:05] AppID 7000 state changed : Fully Installed,", appID: 7000)
        require(stage == .preparing, "installed again -> preparing")
        stage = stage.after("[2026-09-23 14:34:31] [Logged On, 4, 7] [U:1:#] RecvMsgClientLogOnResponse() : processing complete", appID: 7000)
        require(stage == .preparing, "stages do not move backwards")
        stage = stage.after("[2026-09-23 14:35:10] AppID 7000 state changed : Fully Installed,App Running,", appID: 7000)
        require(stage == .gameStarting, "app running -> game starting")
        // --- ml1520: console_log.txt launch tasks
        var task = SteamLaunchStage.signedIn
        task = task.after("[2026-09-23 16:28:16] GameAction [AppID 7001, ActionID 1] : LaunchApp changed task to ProcessingInstallScript with \"\"", appID: 7000)
        require(task == .signedIn, "another app's launch task is ignored")
        task = task.after("[2026-09-23 16:28:10] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to ShowEula with \"\"", appID: 7000)
        require(task == .needsInput, "license agreement -> needs input")
        task = task.after("[2026-09-23 16:28:16] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to ProcessingInstallScript with \"\"", appID: 7000)
        require(task == .installers, "install script -> installers")
        task = task.after("[2026-09-23 16:28:30] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\"", appID: 7000)
        require(task == .cloudSync, "cloud -> cloud sync")
        task = task.after("[2026-09-23 16:28:31] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to CreatingProcess with \"\"", appID: 7000)
        require(task == .gameStarting, "creating process -> game starting")
        task = task.after("[2026-09-23 16:28:32] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to ProcessingInstallScript with \"\"", appID: 7000)
        require(task == .gameStarting, "tasks do not move backwards")
        // --- ml1530: "waiting for user response" wins over the forward order (device log 199)
        var wait = SteamLaunchStage.installers
        wait = wait.after("[2026-09-23 17:42:57] GameAction [AppID 7000, ActionID 1] : LaunchApp waiting for user response to ShowInterstitials \"\"", appID: 7000)
        // ml1720: interstitials answer themselves within seconds in every device log; not a screen.
        require(wait == .installers, "interstitials are not a screen")
        wait = wait.after("[2026-09-23 17:43:07] GameAction [AppID 7000, ActionID 1] : LaunchApp continues with user response \"ShowInterstitials\"", appID: 7000)
        require(wait == .installers, "their answer changes nothing")
        wait = wait.after("[2026-09-23 17:43:07] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to CreatingProcess with \"\"", appID: 7000)
        wait = wait.after("[2026-09-23 17:43:07] GameAction [AppID 7000, ActionID 1] : LaunchApp waiting for user response to CreatingProcess \"\"", appID: 7000)
        require(wait == .gameStarting, "the process step's brief wait is not a screen")
        var eula = SteamLaunchStage.signedIn.after("[..] GameAction [AppID 7000, ActionID 1] : LaunchApp waiting for user response to ShowEula \"\"", appID: 7000)
        require(eula == .needsInput, "license agreement waiting -> needs input")
        eula = eula.after("[..] GameAction [AppID 7000, ActionID 1] : LaunchApp changed task to RunningInstallScript with \"\"", appID: 7000)
        require(eula == .installers, "the next task ends the wait")
        require(SteamLaunchStage.needsSignIn.after("[..] GameAction [AppID 7000, ActionID 1] : LaunchApp waiting for user response to ShowEula \"\"", appID: 7000) == .needsInput,
                "launch progress ends a sign-in state (the client is signed in)")
        require(SteamLaunchStage.signedIn.after("[..] [Logged Off, 4, 0] [U:1:#] ConnectionDisconnected() not auto reconnecting due to Session Replaced", appID: 7000) == .signedIn,
                "a replaced session is not a sign-in the user must make")
        var rejected = SteamLaunchStage.signingIn.after("[..] ConnectionDisconnected() not auto reconnecting due to Invalid Password", appID: 7000)
        require(rejected == .needsSignIn, "rejected sign-in -> needs sign-in")
        rejected = rejected.after("[..] ClientConnectionStatus changed", appID: 7000)
        require(rejected == .needsSignIn, "needs sign-in holds on unrelated lines")
        var progressed = rejected.after("[..] AppID 7000 state changed : Fully Installed,", appID: 7000)
        require(progressed == .preparing, "this app's progress moves on")
        progressed = rejected.after("[..] [Logged On, 4, 7] [U:1:#] RecvMsgClientLogOnResponse() : processing complete", appID: 7000)
        require(progressed == .signedIn, "a later sign-in moves on")
        require(SteamLaunchStage.allTextsDistinct, "every stage has its own text")

        // --- The Workshop update, from the client's own lines.
        var log = SteamWorkshopLog(appID: 7000)
        for line in [
            "[2026-09-23 03:45:24] AppID 7000 scheduler update : Priority User Initiated, not played for 394 seconds, update disabled for 0 seconds",
            "[2026-09-23 03:45:24] AppID 7000 state changed : Fully Installed,Update Queued,Update Running,",
            "[2026-09-23 03:45:24] AppID 7000 Workshop update changed : Running Update,",
            "[2026-09-23 03:45:24] AppID 7000 Workshop update changed : Running Update,Reconfiguring,",
        ] { log.feed(line) }
        require(log.phase == .queued && log.total == 0, "workshop update preparing")
        log.feed("[2026-09-23 03:45:26] AppID 70000 update started : download 1/2, store 0/0, reuse 0/0, delta 0/0, stage 1/2")
        log.feed("[2026-09-23 03:45:26] AppID 7000 update started : download 396293552/36271038464, store 0/0, reuse 0/0, delta 0/0, stage 762126893/72100190136")
        log.feed("[2026-09-23 03:45:26] AppID 7000 Workshop update changed : Running Update,Downloading,Staging,")
        log.feed("[2026-09-23 03:45:28] Downloading 23600 chunks for depot 7000 (4330285545469183745)")
        require(log.phase == .downloading && log.total == 36271038464 && log.downloaded == 396293552 &&
                log.toStage == 72100190136 && log.staged == 762126893, "workshop figures, other App IDs ignored")
        var appLog = SteamWorkshopLog(appID: 7000)
        for line in [
            "[2026-09-23 03:37:09] AppID 7000 App update changed : Running Update,",
            "[2026-09-23 03:37:09] AppID 7000 update started : download 0/667005168, store 0/0, reuse 0/0, delta 0/0, stage 0/1801637088",
            "[2026-09-23 03:37:10] AppID 7000 App update changed : Running Update,Downloading,Staging,",
        ] { appLog.feed(line) }
        require(appLog.phase == .idle && appLog.total == 0, "an app update is not a workshop update")
        log.feed("[2026-09-23 04:45:00] AppID 7000 Workshop update changed : None")
        require(log.phase == .idle && log.total == 0, "workshop update finished")
        require(SteamWorkshopLog.phase("Running Update,Committing,") == .staging && SteamWorkshopLog.phase("Running Update,Verifying Staged,") == .verifying &&
                SteamWorkshopLog.phase(" Running Update,Update Paused,") == .paused, "workshop states")

        let record = Data(#"""
        "AppWorkshop"
        {
            "appid"   "7000"
            "SizeOnDisk"  "1234"
            "NeedsUpdate" "1"
            "NeedsDownload" "1"
            "WorkshopItemsInstalled" { "11" { "size" "10" "manifest" "1" } "12" { "size" "20" "manifest" "2" } "99" { "size" "1" } }
            "WorkshopItemDetails" { "11" { "manifest" "1" "subscribedby" "1" } "12" { "manifest" "2" } "13" { "manifest" "3" } "14" { "manifest" "4" } }
        }
        """#.utf8)
        let items = SteamWorkshopItems.parse(record, appID: 7000)
        require(items == SteamWorkshopItems(subscribed: 4, installed: 2, needsDownload: true), "workshop record counts (\(String(describing: items)))")
        require(SteamWorkshopItems.parse(record, appID: 7001) == nil && SteamWorkshopItems.parse(record.prefix(record.count / 2), appID: 7000) == nil,
                "foreign and partially written records are rejected")

        // --- Following the files: content log tail and Workshop record.
        let base = URL(fileURLWithPath: "/tmp/madeira-launch-view")
        try? FileManager.default.removeItem(at: base)
        let logs = base.appendingPathComponent("Steam/logs"), apps = base.appendingPathComponent("Steam/steamapps")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("workshop"), withIntermediateDirectories: true)
        let contentLog = logs.appendingPathComponent("content_log.txt")
        var tail = SteamLogTail()
        require(tail.read(contentLog).isEmpty, "missing log: nothing yet")
        try Data("old session line\n".utf8).write(to: contentLog)
        require(tail.read(contentLog) == ["old session line"], "a log created after following began is read from its start")
        var fresh = SteamLogTail()
        require(fresh.read(contentLog).isEmpty, "first read of an existing log records its end")
        let handle = try FileHandle(forWritingTo: contentLog); try handle.seekToEnd()
        try handle.write(contentsOf: Data("line one\r\nline tw".utf8))
        require(fresh.read(contentLog) == ["line one"], "complete lines only")
        try handle.write(contentsOf: Data("o\n".utf8)); try handle.close()
        require(fresh.read(contentLog) == ["line two"], "a partial line completes on the next read")
        try Data("rotated\n".utf8).write(to: contentLog)
        require(fresh.read(contentLog) == ["rotated"], "a rotated log is read from its start")

        var tracker = SteamWorkshopTracker(appID: 7000)
        tracker.poll(logFile: contentLog, libraries: [apps], now: 0)
        require(tracker.progress == nil, "no workshop update: nothing to show")
        let append = { (text: String) in
            let h = try! FileHandle(forWritingTo: contentLog); try! h.seekToEnd(); try! h.write(contentsOf: Data(text.utf8)); try! h.close()
        }
        append("[t] AppID 7000 Workshop update changed : Running Update,\n[t] AppID 7000 update started : download 0/36271038464, store 0/0, reuse 0/0, delta 0/0, stage 0/72100190136\n[t] AppID 7000 Workshop update changed : Running Update,Downloading,Staging,\n")
        let recordFile = apps.appendingPathComponent("workshop/appworkshop_7000.acf")
        try record.write(to: recordFile)
        tracker.poll(logFile: contentLog, libraries: [apps], now: 2)
        var workshop = tracker.progress
        require(workshop?.phase == .downloading && workshop?.total == 36271038464 && workshop?.items?.subscribed == 4 &&
                workshop?.itemsLive == false && workshop?.fraction == nil, "workshop update with its size; item count not yet live")
        try Data(String(decoding: record, as: UTF8.self)
            .replacingOccurrences(of: #""99" { "size" "1" }"#, with: #""13" { "size" "5" }"#).utf8).write(to: recordFile)
        tracker.poll(logFile: contentLog, libraries: [apps], now: 5)
        require(tracker.progress?.items?.installed == 2, "the record is read at most every 10 s")
        tracker.poll(logFile: contentLog, libraries: [apps], now: 13)
        workshop = tracker.progress
        require(workshop?.items?.installed == 3 && workshop?.itemsLive == true && workshop?.fraction == 0.75, "a changing installed count is live progress")

        var progress = SteamClientProgress()
        progress.phase = .installed; progress.workshop = workshop
        require(progress.active && progress.working, "a workshop update keeps the starting screen busy")
        require(progress.summary == "Steam is downloading Workshop items (36.3 GB) before the game starts." &&
                progress.detail == "Workshop items are add-ons you subscribed to in Steam for this game. 3 of 4 installed." &&
                progress.fraction == 0.75, "workshop text (\(progress.summary ?? "nil") / \(progress.detail ?? "nil"))")
        progress.phase = .downloading; progress.total = 3_000_000_000; progress.downloaded = 1_000_000_000
        require(progress.summary?.hasPrefix("Steam is downloading game content: 1.0 of 3.0 GB") == true && progress.fraction == Double(1) / 3,
                "the app's own unfinished content is reported first")
        progress.downloaded = 3_000_000_000
        require(progress.summary?.contains("Workshop") == true, "then its Workshop items")
        require(progress.logFields.hasSuffix("workshop=downloading download=0/36271038464 items=3/4 live=1"), "workshop log fields (\(progress.logFields))")
        var plain = SteamClientProgress(); plain.phase = .downloading; plain.total = 100; plain.downloaded = 10
        require(!plain.logFields.contains("workshop") && plain.detail == nil, "no workshop fields or text without a workshop update")
        workshop?.items = nil; workshop?.itemsLive = false
        progress.workshop = workshop; progress.phase = .idle
        require(progress.detail == "Workshop items are add-ons you subscribed to in Steam for this game." && progress.fraction == nil, "no record: no count, no bar")
        append("[t] AppID 7000 Workshop update changed : None\n")
        tracker.poll(logFile: contentLog, libraries: [apps], now: 30)
        require(tracker.progress == nil, "finished workshop update disappears")

        // --- ml1770: setup's Steam install stage from the updater log.
        var setup = SteamSetupStage.installing
        let bootstrap = ["[2026-09-24 16:13:50] Startup - updater built Sep 10 2026 12:00:00",
                         "[2026-09-24 16:13:50] Checking for update on startup",
                         "[2026-09-24 16:13:50] Checking for available updates...",
                         "[2026-09-24 16:13:51] Downloading manifest: https://client-update.steamstatic.com/steam_client_win32",
                         "[2026-09-24 16:13:52] Downloaded new manifest",
                         "[2026-09-24 16:13:52] Downloading update (0 of 229,383 KB)...",
                         "[2026-09-24 16:14:02] Downloading update (114,692 of 229,383 KB)..."]
        var seen: [String] = []
        for line in bootstrap { setup = setup.after(line); seen.append(setup.name) }
        require(seen == ["installing", "checking", "checking", "checking", "checking", "downloading-0", "downloading-50"], "updater stages (\(seen))")
        require(setup.text == "Downloading Steam's update… 50%", "download text (\(setup.text))")
        setup = setup.after("[t] Download Complete.")
        require(setup == .downloading(percent: 50), "unknown lines keep the stage")
        setup = setup.after("[t] Extracting package...")
        require(setup == .unpacking, "extracting")
        setup = setup.after("[t] Update complete, launching...")
        require(setup == .opening && setup.detail.contains("minute"), "launching the client opens the sign-in window")
        for line in ["[t] Startup - updater built", "[t] Checking for available updates...", "[t] Verifying installation...",
                     "[t] Verification complete"] { setup = setup.after(line) }
        require(setup == .opening, "a relaunched client's checks do not undo opening")
        setup = setup.after("[t] Downloading update (1 of 4 KB)...")
        require(setup == .downloading(percent: 25), "a second update shows again")
        require(SteamSetupStage.percent("[t] Downloading update (5 of 0 KB)...") == nil, "no division by zero")
        require(SteamSetupStage.installing.after("[t] Download skipped: /client/steam_client_win32 version 1, installed version 1") == .opening,
                "an up-to-date client opens straight away")

        if failures > 0 { print("FAILURES: \(failures)"); exit(1) }
        print("PASS: all ml1490 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-launch-view-') as tmp:
    tmp = Path(tmp)
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'checks.swift').write_text(checks)
    sources = [tmp / 'stubs.swift', tmp / 'checks.swift', app / 'SteamFiles.swift', app / 'SwiftSteam/Install/AppManifestWriter.swift']
    exe = tmp / 'swift-checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe)] + [str(s) for s in sources], check=True)
    subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))

# ---------------------------------------------------------------- Part B
winios = (app / 'Winios/Winios.m').read_text()
start = winios.index('#define WINIOS_GA_PARENT')
end = winios.index('void winios_pDestroyWindow(HWND hwnd)')
census = winios[start:end]

c_prelude = r'''
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "Winios.h"
typedef void *HWND;

/* Stubbed win32u / ntdll: a table of fake windows. */
struct fake { HWND hwnd; unsigned style; HWND parent; unsigned pid; };
static struct fake fakes[256];
static int nfakes;
static _Atomic int image_queries;
static int fail_pid = 0x99;
static struct fake *lookup(HWND h) { for (int i = 0; i < nfakes; i++) if (fakes[i].hwnd == h) return &fakes[i]; return NULL; }
HWND NtUserGetAncestor(HWND hwnd, unsigned int type) { struct fake *f = lookup(hwnd); return type == 1 && f ? f->parent : NULL; }
unsigned int get_window_thread(HWND hwnd, unsigned int *process) { struct fake *f = lookup(hwnd); if (process) *process = f ? f->pid : 0; return f ? 0x20 : 0; }
int get_window_long(HWND hwnd, int offset) { struct fake *f = lookup(hwnd); return offset == -16 && f ? (int)f->style : 0; }
struct pid_info { void *pid; unsigned short length, maximum; unsigned short *buffer; };
int NtQuerySystemInformation(int info_class, void *info, unsigned int size, unsigned int *ret_size) {
    struct pid_info *id = info;
    atomic_fetch_add(&image_queries, 1);
    if (info_class != 88 || size != sizeof(*id) || id->length) return (int)0xc0000004;
    unsigned pid = (unsigned)(uintptr_t)id->pid;
    if (pid == (unsigned)fail_pid) return (int)0xc000000b;
    char path[128];
    snprintf(path, sizeof(path), pid == 7 ? "\\??\\C:\\Program Files (x86)\\Steam\\Steam.exe" : "\\??\\C:\\Games\\Pid%u\\Game%u.EXE", pid, pid);
    size_t n = strlen(path);
    if ((n + 1) * 2 > id->maximum) return (int)0xc0000004;
    for (size_t i = 0; i <= n; i++) id->buffer[i] = (unsigned short)path[i];
    id->length = (unsigned short)(n * 2);
    if (ret_size) *ret_size = size;
    return 0;
}
static HWND add(unsigned long h, unsigned style, unsigned long parent, unsigned pid) {
    fakes[nfakes] = (struct fake){ (HWND)h, style, (HWND)parent, pid };
    return fakes[nfakes++].hwnd;
}
'''

c_checks = r'''
static int failures;
#define CHECK(c, label) do { if (c) printf("PASS: %s\n", label); else { printf("FAIL: %s\n", label); failures++; } } while (0)
static struct winios_census_window out[WINIOS_CENSUS_MAX];
static struct winios_census_window *find(HWND h, int n) { for (int i = 0; i < n; i++) if (out[i].hwnd == (unsigned long long)(uintptr_t)h) return &out[i]; return NULL; }

static void *writer(void *arg) {
    long base = (long)arg;
    for (int round = 0; round < 2000; round++) {
        HWND h = (HWND)(uintptr_t)(0x9000 + base * 16 + round % 16);
        winios_census_note_frame(h, 0, 0, 640, 480, round & 1);
        winios_census_note_present(h);
        if (round % 7 == 0) winios_census_forget(h);
    }
    return NULL;
}

int main(void) {
    HWND desktop = add(0x20, 0x96000000, 0, 1);
    HWND client = add(0x100, 0x96ca0000, 0x20, 7);       /* visible client dialog */
    HWND child = add(0x101, 0x50000000, 0x100, 7);       /* WS_CHILD|WS_VISIBLE */
    HWND game = add(0x200, 0x94000000, 0x20, 0x44);      /* WS_POPUP|WS_VISIBLE */
    HWND game2 = add(0x201, 0x14c80000, 0x20, 0x44);     /* same process */
    HWND mini = add(0x202, 0x34c80000, 0x20, 0x44);      /* minimized */
    HWND hidden = add(0x203, 0x84000000, 0x20, 0x44);    /* not WS_VISIBLE */
    HWND nameless = add(0x300, 0x94000000, 0x20, 0x99);  /* image lookup fails */

    winios_census_note_frame(game, 0, 0, 1280, 720, 1);
    CHECK(winios_window_census(out, WINIOS_CENSUS_MAX) == 0 && image_queries == 0, "off: nothing recorded, nothing asked");

    winios_window_census_enable(1);
    winios_census_note_frame(desktop, 0, 0, 1280, 720, 1);
    winios_census_note_frame(child, 10, 10, 100, 100, 1);
    winios_census_note_frame(client, 287, 140, 705, 440, 1);
    winios_census_note_frame(game, 0, 0, 1280, 720, 1);
    winios_census_note_frame(game2, 0, 0, 640, 480, 1);
    winios_census_note_frame(mini, 0, 0, 160, 24, 1);
    winios_census_note_frame(hidden, 0, 0, 800, 600, 1);
    winios_census_note_frame(nameless, 0, 0, 800, 600, 1);
    int n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == 6 && !find(desktop, n) && !find(child, n), "top-level windows only: no desktop, no child");
    struct winios_census_window *c = find(client, n), *g = find(game, n), *u = find(nameless, n);
    CHECK(c && !strcmp(c->image, "steam.exe") && c->pid == 7 && c->visible && c->w == 705 && c->h == 440, "client window: owner base name, lower case");
    CHECK(g && !strcmp(g->image, "game68.exe") && g->visible, "game window owner");
    CHECK(find(mini, n) && !find(mini, n)->visible && find(hidden, n) && !find(hidden, n)->visible, "minimized and hidden windows are not shown");
    CHECK(u && u->image[0] == 0 && u->pid == 0x99, "an unreadable owner stays empty");
    CHECK(image_queries == 3, "one lookup per process");
    winios_census_note_frame(game, 0, 0, 1280, 720, 0);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(!find(game, n)->visible, "hidden by SetWindowPos");
    winios_census_note_present(game); winios_census_note_present(game); winios_census_note_present(child);
    winios_census_note_metal(game2);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(find(game, n)->presents == 2 && find(game2, n)->metal && !find(game, n)->metal, "frames and swapchains per window");
    winios_census_forget(game);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == 5 && !find(game, n) && find(game2, n), "destroyed windows leave");
    CHECK(winios_window_census(out, 2) == 2, "copy is bounded by the caller");

    for (unsigned long i = 0; i < 80; i++) winios_census_note_frame(add(0x1000 + i, 0x84000000, 0x20, 0x44), 0, 0, 10, 10, 1);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n == WINIOS_CENSUS_MAX, "capacity holds");
    HWND late = add(0x5000, 0x94000000, 0x20, 0x44);
    winios_census_note_frame(late, 0, 0, 1280, 720, 1);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(find(late, n) && find(late, n)->visible && find(client, n), "a full census gives a hidden window's slot to a shown one");

    winios_window_census_enable(0);
    CHECK(winios_window_census(out, WINIOS_CENSUS_MAX) == 0, "off: emptied");
    winios_window_census_enable(1);
    int before = image_queries;
    winios_census_note_frame(client, 287, 140, 705, 440, 1);
    CHECK(image_queries == before + 1, "a new census forgets cached process names");

    /* Concurrency: writers on "wine threads", the app reading on the main thread. */
    for (long t = 0; t < 4; t++) for (int i = 0; i < 16; i++) add(0x9000 + t * 16 + i, 0x94000000, 0x20, 0x50 + (unsigned)t);
    pthread_t threads[4];
    for (long t = 0; t < 4; t++) pthread_create(&threads[t], NULL, writer, (void *)t);
    for (int i = 0; i < 2000; i++) winios_window_census(out, WINIOS_CENSUS_MAX);
    for (int t = 0; t < 4; t++) pthread_join(threads[t], NULL);
    n = winios_window_census(out, WINIOS_CENSUS_MAX);
    CHECK(n > 0 && n <= WINIOS_CENSUS_MAX, "concurrent writers and reader");
    winios_window_census_enable(0);

    if (failures) { printf("FAILURES: %d\n", failures); return 1; }
    printf("PASS: all ml1490 census checks\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-census-') as tmp:
    tmp = Path(tmp)
    (tmp / 'census.c').write_text(c_prelude + census + c_checks)
    for name, flags in [('asan', ['-fsanitize=address,undefined', '-fno-sanitize-recover=undefined']), ('tsan', ['-fsanitize=thread'])]:
        exe = tmp / ('census-' + name)
        subprocess.run([CC, '-std=gnu11', '-O1', '-g', '-Wall', '-Wno-unused-function', '-Werror=implicit-function-declaration',
                        '-I', str(app / 'Winios'), *flags, str(tmp / 'census.c'), '-o', str(exe), '-lpthread'], check=True)
        print(f'--- census under {name}')
        subprocess.run([str(exe)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0', TSAN_OPTIONS='halt_on_error=1'))
