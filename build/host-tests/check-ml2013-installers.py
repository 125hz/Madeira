#!/usr/bin/env python3
"""ml2013 host checks for Madeira Dock one-time installs; never runs Wine, Steam or iOS.

Device logs 97-100: a game's install script had three "Run Process" entries (a DirectX
setup and a Visual C++ redistributable without "HasRunKey", a physics runtime with one);
Madeira found 1 program, ran none and said nothing about why. This compiles production
Swift (SteamFiles.swift, AppManifestWriter.swift) under AddressSanitizer and checks:
  * entries without "HasRunKey" are recorded under Steam's per-app key (lowercase value
    name, both registry views), as Valve's client records them; nil appID keeps ml1970;
  * the plan gives every program a fate (provided / done / missing / pending / limit),
    and "run all" queues provided runtimes;
  * reinstall reset: unmark removes values in both views; the ledger records and forgets
    runs Madeira only marked, survives a JSON round trip;
  * the ml2013 batch reports each program's start and exit status to a result file,
    records a run done only on 0/3010/1641 (a negative status is a failure), and the
    result parser reads that file back.
When Windows cmd.exe is reachable (WSL interop), the generated batch also runs for real
with stand-in programs (reg.exe replaced by a recorder), proving the goto/ERRORLEVEL flow.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or os.path.expanduser('~/.local/share/swiftly/bin/swiftc')

stubs = r'''
import Foundation
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-ml2013/steamapps") } }
'''

checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

@main struct Checks {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        // The device script's shape, with fixture names.
        let script = """
        "installscript"
        {
            "registry" { "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\Fixture Vendor\\\\Fixture" { "string" { "Install Dir" "%INSTALLDIR%" } } }
            "run process"
            {
                "DirectX"
                {
                    "process 1"   "%INSTALLDIR%\\\\DirectX\\\\DXSETUP.exe"
                    "command 1"   "/silent"
                    "NoCleanUp"   "1"
                }
                "Physics Version"
                {
                    "HasRunKey"   "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\Fixture Physics"
                    "process 1"   "%INSTALLDIR%\\\\Physics\\\\Physics_SystemSoftware.exe"
                    "NoCleanUp"   "1"
                    "MinimumHasRunValue" "81017"
                }
                "vcredist"
                {
                    "process 1"   "%INSTALLDIR%\\\\Redistributable\\\\vcredist_x86_en.exe"
                    "command 1"   "/q:a"
                    "NoCleanUp"   "1"
                }
                "NoProgram" { "NoCleanUp" "1" }
            }
        }
        """
        let data = Data(script.utf8)
        let dir = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\fixture"
        let old = DockInstallScripts.processes(script: data, installDir: dir)
        require(old.count == 1 && old.first?.run.name == "physics version", "without an app ID only the HasRunKey entry counts (ml1970, logs 97-100: programs=1)")
        let found = DockInstallScripts.processes(script: data, installDir: dir, appID: 7000)
        require(found.map(\.run.name) == ["directx", "physics version", "vcredist"], "all three programs with the app ID (\(found.map(\.run.name)))")
        let dx = found[0], physics = found[1], vc = found[2]
        require(dx.run.hive == .machine && dx.run.key == "Software\\Valve\\Steam\\Apps\\7000" && dx.run.value == 1, "no HasRunKey: Steam's per-app key, value 1")
        require(physics.run.key == "SOFTWARE\\Fixture Physics" && physics.run.value == 81017, "a HasRunKey and its minimum are kept")
        require(vc.arguments == "/q:a" && vc.executable == dir + "\\Redistributable\\vcredist_x86_en.exe", "program and arguments")
        require(SteamInstallScripts.runs(script: data).count == 1 && SteamInstallScripts.runs(script: data, appID: 7000).count == 3,
                "ml1780's reader: unchanged without an app ID, all entries with one")
        require(!SteamInstallScripts.runs(script: data, appID: 7000).contains { $0.name == "noprogram" }, "an entry with no program and no key is not recorded")
        require(SteamInstallScripts.runs(script: data, appID: 0).count == 1 && SteamInstallScripts.runs(script: data, appID: -3).count == 1, "invalid app IDs add nothing")
        require(SteamInstallScripts.keys(dx.run) == ["Software\\Valve\\Steam\\Apps\\7000", "Software\\Wow6432Node\\Valve\\Steam\\Apps\\7000"], "both registry views")

        // A Windows client's own record (32-bit view) counts as done.
        let windowsRecord = """
        WINE REGISTRY Version 2

        [Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\7000] 1700000000
        "directx"=dword:00000001
        "vcredist"=dword:00000001

        [Software\\\\Wow6432Node\\\\Fixture Physics] 1700000000
        "Physics Version"=dword:008d4e9f
        """
        require(DockInstallScripts.marked(dx.run, in: windowsRecord) && DockInstallScripts.marked(vc.run, in: windowsRecord), "the client's default-key records are read")
        require(DockInstallScripts.recorded(physics.run, in: windowsRecord) == 0x8d4e9f && DockInstallScripts.marked(physics.run, in: windowsRecord),
                "a real install's value above the minimum is done")
        require(DockInstallScripts.recorded(dx.run, in: "WINE REGISTRY Version 2\n") == nil, "absent: nil")

        // The plan: every program gets a fate.
        let none: (SteamInstallRun) -> Bool = { _ in false }
        var plan = DockInstallScripts.plan(found, runAll: false, done: none, exists: { _ in true })
        require(plan.map(\.status) == [.provided, .pending, .provided], "default: runtimes provided, the other program pending (\(plan.map(\.status.rawValue)))")
        plan = DockInstallScripts.plan(found, runAll: true, done: none, exists: { _ in true })
        require(plan.map(\.status) == [.pending, .pending, .pending], "run all: every program pending")
        plan = DockInstallScripts.plan(found, runAll: true, done: { $0.name == "physics version" }, exists: { !$0.hasSuffix("vcredist_x86_en.exe") })
        require(plan.map(\.status) == [.pending, .done, .missing], "done before missing before pending")
        plan = DockInstallScripts.plan(found, runAll: true, limit: 1, done: none, exists: { _ in true })
        require(plan.map(\.status) == [.pending, .limit, .limit], "per-start limit")

        // The start screen's note.
        let quiet = DockInstallScripts.plan(found, runAll: false, done: { _ in true }, exists: { _ in true })
        require(quiet.map(\.status) == [.provided, .done, .provided], "all recorded: provided and done")
        require(DockInstallScripts.note(quiet, runAll: false, announceProvided: false) == nil, "nothing new: no note (ml1990 quiet start)")
        let first = DockInstallScripts.note(quiet, runAll: false, announceProvided: true) ?? ""
        require(first.contains("Provided by Madeira, not run: directx, vcredist") && first.contains("Also run DirectX") && first.contains("Already done: physics version"),
                "first provided marking is announced with the switch to run them (\(first))")
        let running = DockInstallScripts.note(DockInstallScripts.plan(found, runAll: true, done: none, exists: { !$0.hasSuffix("DXSETUP.exe") }),
                                              runAll: true, announceProvided: false) ?? ""
        require(running.contains("Runs first: physics version, vcredist") && running.contains("Installer file missing: directx") && !running.contains("Also run"),
                "pending and missing programs are named (\(running))")

        // Reinstall reset: mark, then unmark in both views.
        let base = "WINE REGISTRY Version 2\n"
        let (marked, changed) = SteamInstallScripts.mark([dx.run, vc.run, physics.run], in: base, now: 1)
        require(changed == 6 && DockInstallScripts.marked(dx.run, in: marked) && DockInstallScripts.marked(physics.run, in: marked), "marked in both views")
        let (cleared, removed) = SteamInstallScripts.unmark([dx.run, physics.run], in: marked)
        require(removed == 4 && !DockInstallScripts.marked(dx.run, in: cleared) && !DockInstallScripts.marked(physics.run, in: cleared), "unmarked in both views")
        require(DockInstallScripts.marked(vc.run, in: cleared), "other values stay")
        require(SteamInstallScripts.unmark([dx.run], in: cleared).changed == 0, "unmarking an absent value changes nothing")

        // The ledger.
        var ledger = SteamInstallLedger()
        ledger.record([dx.run, vc.run, dx.run], app: 7000)
        require(ledger.marked["7000"]?.count == 2 && ledger.madeiraMarked(vc.run, app: 7000) && !ledger.madeiraMarked(vc.run, app: 7001), "record per app, once")
        ledger.forget([vc.run], app: 7000)
        require(!ledger.madeiraMarked(vc.run, app: 7000) && ledger.madeiraMarked(dx.run, app: 7000), "forget one run")
        ledger.reset["7000"] = true; ledger.session = [physics.run]; ledger.sessionApp = 7000
        let prefix = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ml2013-\(getpid())")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        require(SteamInstallLedger.load(prefix: prefix) == SteamInstallLedger(), "no file: empty ledger")
        try ledger.save(prefix: prefix)
        require(SteamInstallLedger.load(prefix: prefix) == ledger, "JSON round trip")
        try Data("{not json".utf8).write(to: prefix.appendingPathComponent(SteamInstallLedger.fileName))
        require(SteamInstallLedger.load(prefix: prefix) == SteamInstallLedger(), "a damaged file reads as empty")
        // unmark(prefix:) on real files.
        try Data(marked.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let unmarkedOnDisk = try SteamInstallScripts.unmark([dx.run], prefix: prefix)
        require(unmarkedOnDisk == 2, "unmark writes system.reg")
        let after = try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)
        require(!DockInstallScripts.marked(dx.run, in: after) && DockInstallScripts.marked(vc.run, in: after), "file unmarked")
        try? FileManager.default.removeItem(at: prefix)

        // The ml2013 batch.
        let resultFile = "C:\\madeira-dock-installers.result"
        let batch = DockInstallScripts.batch([dx, physics], resultFile: resultFile)
        let lines = batch.components(separatedBy: "\r\n")
        require(batch.hasPrefix("@echo off\r\n") && batch.hasSuffix("\r\n"), "CRLF batch")
        require(lines.contains("echo begin 2 >\"C:\\madeira-dock-installers.result\""), "result file started fresh")
        let start1 = lines.firstIndex(of: "echo start 1 directx >>\"C:\\madeira-dock-installers.result\"")
        let run1 = lines.firstIndex(of: "call \"" + dx.executable + "\" /silent")
        let check1 = lines.firstIndex(of: "if \"%ERRORLEVEL%\"==\"0\" goto madeira_ok_1")
        let fail1 = lines.firstIndex(of: "echo exit 1 %ERRORLEVEL% >>\"C:\\madeira-dock-installers.result\"")
        let ok1 = lines.firstIndex(of: ":madeira_ok_1")
        let mark1 = lines.firstIndex { $0.hasPrefix("C:\\windows\\system32\\reg.exe add \"HKLM\\Software\\Valve\\Steam\\Apps\\7000\" /v \"directx\" /t REG_DWORD /d 1 /f") }
        let next1 = lines.firstIndex(of: ":madeira_next_1")
        require([start1, run1, check1, fail1, ok1, mark1, next1].allSatisfy { $0 != nil }, "batch lines present")
        if let start1, let run1, let check1, let fail1, let ok1, let mark1, let next1 {
            require(start1 < run1 && run1 < check1 && check1 < fail1 && fail1 < ok1 && ok1 < mark1 && mark1 < next1, "start, run, check, failure report, then the mark only after success")
        }
        require(lines.contains("if \"%ERRORLEVEL%\"==\"3010\" goto madeira_ok_1") && lines.contains("if \"%ERRORLEVEL%\"==\"1641\" goto madeira_ok_1"),
                "restart-requested statuses count as installed")
        require(!batch.contains("errorlevel 1"), "no 'if not errorlevel 1' (a negative status passed it)")
        require(!lines.contains { $0.contains(">>\"") && !$0.contains(" >>\"") }, "every redirection follows a space")
        require(lines.contains("C:\\windows\\system32\\reg.exe add \"HKLM\\Software\\Wow6432Node\\Fixture Physics\" /v \"physics version\" /t REG_DWORD /d 81017 /f >nul"),
                "custom key, 32-bit view, minimum value")
        require(lines.contains("echo end >>\"C:\\madeira-dock-installers.result\""), "end line")
        require(DockInstallScripts.batch([dx]).contains("if not errorlevel 1"), "the ml1970 batch (kill switch) is unchanged")

        // Result file parser.
        let results = DockInstallScripts.results("begin 3 \r\nstart 1 directx \r\nexit 1 -9 \r\nstart 2 vcredist \r\nexit 2 3010 \r\nstart 3 physics version \r\n")
        require(results.total == 3 && results.exits[1] == -9 && results.exits[2] == 3010 && results.started[3] == "physics version", "parsed statuses and labels")
        require(results.running == 3 && !results.ended, "running program, not ended")
        require(!DockInstallScripts.Results.succeeded(-9) && DockInstallScripts.Results.succeeded(3010) && DockInstallScripts.Results.succeeded(0), "success statuses")
        require(DockInstallScripts.results("begin 1\nstart 1 a\nexit 1 0\nend\n").ended && DockInstallScripts.results("begin 1\nstart 1 a\nexit 1 0\nend\n").running == nil, "ended")
        require(DockInstallScripts.results("start 99 x\nexit abc\nbogus\n") == DockInstallScripts.Results(), "out-of-range and malformed lines ignored")
        require(DockInstallScripts.label(SteamInstallRun(name: "a&b|c>%d\"e f", hive: .machine, key: "k", value: 1)) == "abcde f", "labels keep only safe characters")

        // Fixture for the optional real cmd.exe run: programs are stand-in .cmd files under @DIR@.
        func fixture(_ name: String, _ file: String) -> SteamInstallProcess {
            SteamInstallProcess(run: SteamInstallRun(name: name, hive: .machine, key: "Software\\Fixture\\" + name, value: 1),
                                executable: "@DIR@\\" + file, arguments: "/quiet")
        }
        let real = DockInstallScripts.batch([fixture("ok", "ok.cmd"), fixture("negative", "negative.cmd"), fixture("restart", "restart.cmd"), fixture("fails", "fails.cmd")],
                                            resultFile: "@DIR@\\result.txt")
        try Data(real.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"))

        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("PASS: all ml2013 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-ml2013-') as td:
    td = Path(td)
    (td / 'stubs.swift').write_text(stubs)
    (td / 'checks.swift').write_text(checks)
    exe = td / 'checks'
    subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-sanitize=address', '-o', str(exe),
                    str(td / 'stubs.swift'), str(td / 'checks.swift'),
                    str(app / 'SteamFiles.swift'), str(app / 'SwiftSteam/Install/AppManifestWriter.swift')], check=True)
    fixture_batch = td / 'fixture.cmd'
    subprocess.run([str(exe), str(fixture_batch)], check=True, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=0'))
    batch_text = fixture_batch.read_text()

# Optional: run the generated batch with Windows cmd.exe (WSL interop) and stand-in programs.
cmd = shutil.which('cmd.exe') or ('/mnt/c/Windows/System32/cmd.exe' if Path('/mnt/c/Windows/System32/cmd.exe').exists() else None)
if cmd and shutil.which('wslpath'):
    win_temp = subprocess.run([cmd, '/d', '/c', 'echo %TEMP%'], capture_output=True, text=True, cwd='/mnt/c').stdout.strip()
    work_win = win_temp + '\\madeira-ml2013-%d' % os.getpid()
    work = Path(subprocess.run(['wslpath', '-u', work_win], capture_output=True, text=True).stdout.strip())
    work.mkdir(parents=True, exist_ok=True)
    try:
        for name, code in [('ok', 0), ('negative', -9), ('restart', 3010), ('fails', 1603)]:
            (work / (name + '.cmd')).write_text('@exit /b %d\r\n' % code, newline='')
        text = batch_text.replace('@DIR@', work_win)
        # reg.exe never runs here: each mark is appended to marks.txt instead.
        text = text.replace('C:\\windows\\system32\\reg.exe add ', 'echo mark ').replace(' >nul', ' >>"%s\\marks.txt"' % work_win)
        (work / 'run.cmd').write_text(text, newline='')
        subprocess.run([cmd, '/d', '/c', 'call', work_win + '\\run.cmd'], cwd='/mnt/c', capture_output=True, text=True, timeout=60)
        result = (work / 'result.txt').read_text(errors='replace').replace('\r', '')
        marks = (work / 'marks.txt').read_text(errors='replace') if (work / 'marks.txt').exists() else ''
        lines = [l.strip() for l in result.split('\n') if l.strip()]
        assert lines == ['begin 4', 'start 1 ok', 'exit 1 0', 'start 2 negative', 'exit 2 -9', 'start 3 restart', 'exit 3 3010',
                         'start 4 fails', 'exit 4 1603', 'end'], lines
        assert '"ok"' in marks and '"restart"' in marks and '"negative"' not in marks and '"fails"' not in marks, marks
        assert marks.count('echo mark') == 0 and marks.count('Wow6432Node') == 2 and len([l for l in marks.splitlines() if l.strip()]) == 4, marks
        print('PASS: Windows cmd.exe ran the ml2013 batch: statuses 0/-9/3010/1603 reported; only 0 and 3010 recorded done')
    finally:
        shutil.rmtree(work, ignore_errors=True)
else:
    print('SKIP: cmd.exe not reachable; batch flow checked textually only')

# Source guards for the wiring that needs UIKit / the whole app.
lib = (app / 'Library.swift').read_text()
dock = (app / 'MadeiraDock.swift').read_text()
account = (app / 'SteamAccount.swift').read_text()
assert 'LibraryFlags.enabled("MADEIRA_INSTALL_DEFAULT_KEY")' in lib and 'defaultKey && app > 0 ? app : nil' in lib, 'default key behind its switch, game scripts only'
assert 'LibraryFlags.enabled("MADEIRA_DOCK_INSTALL_REPORT")' in lib and 'DockInstallScripts.batch(pending, resultFile:' in lib, 'result batch behind its switch'
assert 'LibraryFlags.enabled("MADEIRA_DOCK_INSTALL_RESET")' in lib and 'SteamInstallScripts.unmark(clear, prefix: prefix)' in lib, 'reset behind its switch'
assert 'absorbDockInstallerResults(reason: "session-end")' in lib and 'absorbDockInstallerResults(reason: "next-start")' in lib, 'statuses logged at session end and next start'
assert 'MadeiraDock.installerNote' in lib and 'MadeiraDock.pollInstallers()' in lib, 'start screen shows the plan and progress'
assert 'installerResultName = "madeira-dock-installers.result"' in dock and '[dock-installers] ml2013 exit' in dock
assert 'LibraryModel.requestDockInstallerReset(appID: appID, runAll: entry.steamRunInstallers == true)' in account, 'uninstall requests the reset'
assert 'cmd.exe /c call \\(script) & \\"\\(MadeiraDock.executable)\\"' in lib, 'installers still run before the host, same session'
print("PASS: ml2013 integration guards; device execution still required")
