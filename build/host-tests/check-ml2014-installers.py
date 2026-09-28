#!/usr/bin/env python3
"""ml2014 host checks for Madeira Dock one-time installs; never runs Wine, Steam or iOS.

Device log 103: "run all" queued a game's DirectX setup; it exited -9 and ml2013 retried it at
every start, and no service manager existed in the Dock session while installers ran. This
compiles production Swift (SteamFiles.swift, AppManifestWriter.swift) under AddressSanitizer:
  * provided runtimes are named (DirectX / Visual C++ / .NET); providedRuns() is the plan's
    run-level "every program provided" rule, independent of "run all";
  * the ml2014 batch runs `dockhost.exe --start-services` into the result file before the first
    installer ("services failed" if it cannot run), or records "services off";
  * a provided run that exits non-zero writes "provided <i> <runtime>" before its exit line and is
    recorded done; any other failing installer keeps ml2013's retry;
  * the result parser, providedAfterFailure() and the start screen's note;
  * default arguments keep the ml2013 batch byte-for-byte.
When Windows cmd.exe is reachable (WSL interop), the batch runs for real with stand-in
installers and the staged dockhost.exe (--start-services only connects to the service manager;
on Windows it reports "already"); a missing executable must yield "services failed".
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
enum SteamInstallPaths { static var steamApps: URL { URL(fileURLWithPath: "/tmp/madeira-ml2014/steamapps") } }
'''

checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
func process(_ name: String, _ file: String, key: String = "Software\\Valve\\Steam\\Apps\\7000", dir: String = "C:\\Games\\fixture") -> SteamInstallProcess {
    SteamInstallProcess(run: SteamInstallRun(name: name, hive: .machine, key: key, value: 1), executable: dir + "\\" + file, arguments: "/quiet")
}

@main struct Checks {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let dx = process("directx", "DXSETUP.exe"), vc = process("vcredist", "vcredist_x86_en.exe")
        let net = process("dotnet", "dotNetFx40_Full_x86_x64.exe"), physics = process("physics", "Physics_SystemSoftware.exe")
        require(DockInstallScripts.providedRuntime(dx) == "DirectX" && DockInstallScripts.providedRuntime(process("w", "dxwebsetup.exe")) == "DirectX",
                "DirectX setup is a provided runtime")
        require(DockInstallScripts.providedRuntime(vc) == "Visual C++" && DockInstallScripts.providedRuntime(process("v", "VC_redist.x64.exe")) == "Visual C++",
                "Visual C++ redistributables")
        require(DockInstallScripts.providedRuntime(net) == ".NET" && DockInstallScripts.providedRuntime(physics) == nil, ".NET provided, other programs not")
        require(DockInstallScripts.providedByMadeira(dx) && !DockInstallScripts.providedByMadeira(physics), "providedByMadeira unchanged")
        // A run mixing a provided runtime with another program is not provided (the plan's rule).
        let mixedA = process("mixed", "vcredist_x64.exe", key: "Software\\Mixed"), mixedB = process("mixed", "Tool.exe", key: "Software\\Mixed")
        let found = [dx, physics, vc, mixedA, mixedB]
        require(DockInstallScripts.providedRuns(found) == [dx.run, vc.run], "provided runs: every program provided (\(DockInstallScripts.providedRuns(found).map(\.name)))")
        let plan = DockInstallScripts.plan(found, runAll: false, done: { _ in false }, exists: { _ in true })
        require(plan.filter { $0.status == .provided }.map(\.process.run) == [dx.run, vc.run], "same runs the plan marks provided without run-all")

        // Defaults keep the ml2013 batch.
        let result = "C:\\madeira-dock-installers.result"
        let r = " >>\"C:\\madeira-dock-installers.result\""
        require(DockInstallScripts.batch([dx, physics], resultFile: result) ==
                DockInstallScripts.batch([dx, physics], resultFile: result, services: .none, providedFallback: []), "defaults: the ml2013 batch")
        require(!DockInstallScripts.batch([dx], resultFile: result).contains("services") &&
                !DockInstallScripts.batch([dx], resultFile: result).contains("provided"), "ml2013 batch has no ml2014 lines")

        // The service-manager step.
        let batch = DockInstallScripts.batch([dx, physics], resultFile: result, services: .start("C:\\windows\\system32\\dockhost.exe"),
                                             providedFallback: [dx.run, vc.run])
        let lines = batch.components(separatedBy: "\r\n")
        let begin = lines.firstIndex(of: "echo begin 2 >\"C:\\madeira-dock-installers.result\"")
        let svc = lines.firstIndex(of: "\"C:\\windows\\system32\\dockhost.exe\" --start-services" + r)
        let svcFail = lines.firstIndex(of: "if not \"%ERRORLEVEL%\"==\"0\" echo services failed" + r)
        let start1 = lines.firstIndex(of: "echo start 1 directx" + r)
        require([begin, svc, svcFail, start1].allSatisfy { $0 != nil }, "service-manager lines present")
        if let begin, let svc, let svcFail, let start1 { require(begin < svc && svc < svcFail && svcFail < start1, "begin, services, then the first installer") }
        require(lines.filter { $0.contains("--start-services") }.count == 1, "services started once per batch")
        require(DockInstallScripts.batch([dx], resultFile: result, services: .off).components(separatedBy: "\r\n").contains("echo services off" + r),
                "kill switch: services off recorded, dockhost not run")
        require(!DockInstallScripts.batch([dx], resultFile: result, services: .off).contains("--start-services"), "kill switch: no --start-services")
        require(!lines.contains { $0.contains(">>\"") && !$0.contains(" >>\"") }, "every redirection follows a space")

        // Provided fallback for item 1 (DirectX); item 2 (not provided) keeps the retry.
        let set1 = lines.firstIndex(of: "set madeira_status=%ERRORLEVEL%")
        let prov1 = lines.firstIndex(of: "echo provided 1 DirectX" + r)
        let exit1 = lines.firstIndex(of: "echo exit 1 %madeira_status%" + r)
        let goto1 = lines.firstIndex(of: "goto madeira_mark_1")
        let ok1 = lines.firstIndex(of: ":madeira_ok_1")
        let mark1 = lines.firstIndex(of: ":madeira_mark_1")
        let reg1 = lines.firstIndex { $0.hasPrefix("C:\\windows\\system32\\reg.exe add \"HKLM\\Software\\Valve\\Steam\\Apps\\7000\" /v \"directx\"") }
        let next1 = lines.firstIndex(of: ":madeira_next_1")
        let check1 = lines.firstIndex(of: "if \"%ERRORLEVEL%\"==\"1641\" goto madeira_ok_1")
        require([set1, prov1, exit1, goto1, ok1, mark1, reg1, next1, check1].allSatisfy { $0 != nil }, "fallback lines present")
        if let set1, let prov1, let exit1, let goto1, let ok1, let mark1, let reg1, let next1, let check1 {
            require(check1 < set1 && set1 < prov1 && prov1 < exit1 && exit1 < goto1 && goto1 < ok1 && ok1 < mark1 && mark1 < reg1 && reg1 < next1,
                    "success checks, status saved, provided before exit, then the same registry mark as success")
        }
        require(lines.contains("echo exit 2 %ERRORLEVEL%" + r) && lines.contains("goto madeira_next_2") && !lines.contains(":madeira_mark_2") &&
                !lines.contains { $0.hasPrefix("echo provided 2") }, "a non-provided installer keeps ml2013's failure path")
        let noFallback = DockInstallScripts.batch([dx], resultFile: result, services: .off, providedFallback: [])
        require(!noFallback.contains("provided") && noFallback.contains("echo exit 1 %ERRORLEVEL%" + r) && noFallback.contains("goto madeira_next_1"),
                "fallback kill switch: DirectX failure retried as in ml2013")

        // Result parser.
        let text = "begin 2 \r\nservices started\r\nstart 1 directx \r\nprovided 1 DirectX \r\nexit 1 -9 \r\nstart 2 physics \r\nexit 2 1603 \r\nend \r\n"
        let parsed = DockInstallScripts.results(text)
        require(parsed.services == "started" && parsed.provided == [1: "DirectX"] && parsed.exits == [1: -9, 2: 1603] && parsed.ended, "parsed ml2014 lines")
        require(parsed.providedAfterFailure(1) && !parsed.providedAfterFailure(2) && !parsed.providedAfterFailure(3), "provided-after-failure only for the provided run")
        require(!DockInstallScripts.results("provided 1 DirectX\nexit 1 0\n").providedAfterFailure(1), "a success is not provided-after-failure")
        require(DockInstallScripts.results("provided 1 Visual C++\n").provided[1] == "Visual C++", "runtime names keep + and spaces")
        require(DockInstallScripts.results("services already\n").services == "already" && DockInstallScripts.results("services failed\n").services == "failed" &&
                DockInstallScripts.results("services off\n").services == "off", "every services outcome")
        require(DockInstallScripts.results("services\nprovided 99 X\nprovided 1\nprovided x DirectX\n") == DockInstallScripts.Results(), "malformed ml2014 lines ignored")
        require(DockInstallScripts.results("services st&a|rted>\n").services == "started", "services word keeps letters only")
        require(DockInstallScripts.providedFailureNote(runtime: "DirectX", status: -9) ==
                "DirectX setup failed (code -9); Madeira provides DirectX, so it won't run again.", "start screen note")

        // Fixture for the optional real cmd.exe run (stand-in programs under @DIR@).
        func fixture(_ name: String, _ file: String) -> SteamInstallProcess {
            SteamInstallProcess(run: SteamInstallRun(name: name, hive: .machine, key: "Software\\Fixture\\" + name, value: 1),
                                executable: "@DIR@\\" + file, arguments: "/quiet")
        }
        let items = [fixture("ok", "ok.cmd"), fixture("dx", "dxwebsetup_fail.cmd"), fixture("vc", "vcredist_ok.cmd"), fixture("fails", "fails.cmd")]
        let real = DockInstallScripts.batch(items, resultFile: "@DIR@\\result.txt", services: .start("@DOCK@"),
                                            providedFallback: DockInstallScripts.providedRuns(items))
        let args = CommandLine.arguments
        try Data(real.utf8).write(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "/dev/null"))

        if failures > 0 { print("\(failures) FAILURES"); exit(1) }
        print("PASS: all ml2014 Swift checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='madeira-ml2014-') as td:
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

cmd = shutil.which('cmd.exe') or ('/mnt/c/Windows/System32/cmd.exe' if Path('/mnt/c/Windows/System32/cmd.exe').exists() else None)
dock = app / 'arm64ec-windows/dockhost.exe'
if cmd and shutil.which('wslpath') and dock.exists():
    win_temp = subprocess.run([cmd, '/d', '/c', 'echo %TEMP%'], capture_output=True, text=True, cwd='/mnt/c').stdout.strip()
    work_win = win_temp + '\\madeira-ml2014-%d' % os.getpid()
    work = Path(subprocess.run(['wslpath', '-u', work_win], capture_output=True, text=True).stdout.strip())
    work.mkdir(parents=True, exist_ok=True)
    try:
        for name, code in [('ok', 0), ('dxwebsetup_fail', -9), ('vcredist_ok', 3010), ('fails', 1603)]:
            (work / (name + '.cmd')).write_text('@exit /b %d\r\n' % code, newline='')
        # The staged Dock executable, copied so the checkout is never executed from.
        shutil.copy(dock, work / 'dockhost.exe')

        def run(dock_win):
            for leftover in ('result.txt', 'marks.txt'):
                (work / leftover).unlink(missing_ok=True)
            text = batch_text.replace('@DIR@', work_win).replace('@DOCK@', dock_win)
            text = text.replace('C:\\windows\\system32\\reg.exe add ', 'echo mark ').replace(' >nul', ' >>"%s\\marks.txt"' % work_win)
            (work / 'run.cmd').write_text(text, newline='')
            subprocess.run([cmd, '/d', '/c', 'call', work_win + '\\run.cmd'], cwd='/mnt/c', capture_output=True, text=True, timeout=120)
            lines = [l.strip() for l in (work / 'result.txt').read_text(errors='replace').replace('\r', '').split('\n') if l.strip()]
            marks = (work / 'marks.txt').read_text(errors='replace') if (work / 'marks.txt').exists() else ''
            return lines, marks

        lines, marks = run(work_win + '\\dockhost.exe')
        assert lines == ['begin 4', 'services already', 'start 1 ok', 'exit 1 0', 'start 2 dx', 'provided 2 DirectX', 'exit 2 -9',
                         'start 3 vc', 'exit 3 3010', 'start 4 fails', 'exit 4 1603', 'end'], lines
        recorded = [l for l in marks.splitlines() if l.strip()]
        assert len(recorded) == 6 and all(any('"%s"' % n in l for l in recorded) for n in ('ok', 'dx', 'vc')), marks
        assert '"fails"' not in marks, marks
        print('PASS: Windows cmd.exe ran the ml2014 batch with the staged dockhost.exe: services already; '
              'DirectX -9 provided-after-failure recorded done; 1603 not recorded')
        lines, _ = run(work_win + '\\missing-dockhost.exe')
        assert lines[:3] == ['begin 4', 'services failed', 'start 1 ok'] and lines[-1] == 'end', lines
        print('PASS: a Dock executable that cannot run records "services failed" and the installers still run')
    finally:
        shutil.rmtree(work, ignore_errors=True)
else:
    print('SKIP: cmd.exe or the staged dockhost.exe not reachable; batch flow checked textually only')

# Source guards for the wiring that needs UIKit / the whole app.
lib = (app / 'Library.swift').read_text()
dock_src = (app / 'MadeiraDock.swift').read_text()
assert 'LibraryFlags.enabled("MADEIRA_DOCK_INSTALL_SCM") ? .start(MadeiraDock.executable) : .off' in lib, 'services step behind its switch'
assert 'LibraryFlags.enabled("MADEIRA_DOCK_INSTALL_PROVIDED_FALLBACK") ? DockInstallScripts.providedRuns(found) : []' in lib, 'fallback behind its switch'
assert 'services: services, providedFallback: fallback' in lib, 'report batch gets both'
assert 'ledger.forget(succeeded + providedAfterFailure, app: app)' in lib, 'provided-after-failure no longer counts as only marked'
assert 'provided-after-failure=\\(providedAfterFailure.count)' in lib
assert '[dock-installers] ml2014 services=\\(services)' in dock_src, 'services outcome logged'
assert 'provided-after-failure; recorded done, not run again' in dock_src and 'DockInstallScripts.providedFailureNote(' in dock_src, 'logged and shown'
assert 'cmd.exe /c call \\(script) & \\"\\(MadeiraDock.executable)\\"' in lib, 'installers still run before the host, same session'
# Device log 105: DXSETUP's Managed DirectX step failed LoadLibraryShim(fusion.dll) (no Wine Mono),
# so setup ended -9. Wine's builtin 32-bit fusion.dll is placed in the .NET 2.0 folder, if missing.
assert 'DockInstallScripts.providedRuntime($0) == "DirectX"' in lib and 'LibraryFlags.enabled("MADEIRA_DOTNET_FUSION")' in lib
assert 'windows/Microsoft.NET/Framework/v2.0.50727' in lib and '"i386-windows/fusion.dll"' in lib
assert 'if fm.fileExists(atPath: target.path) { return "present" }' in lib, 'an existing fusion.dll is never replaced'
fusion = (app / 'i386-windows/fusion.dll').read_bytes()
pe = int.from_bytes(fusion[0x3c:0x40], 'little')
assert fusion[pe:pe + 4] == b'PE\0\0' and int.from_bytes(fusion[pe + 4:pe + 6], 'little') == 0x14c, 'bundled fusion.dll is i386'
print("PASS: ml2014 integration guards; device execution still required")
