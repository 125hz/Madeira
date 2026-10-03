#!/usr/bin/env python3
"""LocalDevVPN loopback check and the Madeira JIT shortcut (app/Madeira/JITNetwork.swift);
no device runs.

1. Swift: compiles the production LoopbackProbe on the host, pointed at local test
   listeners, and checks the route step (it names the interface traffic leaves by, and
   a listener reached other than through a VPN does not count and is never connected
   to, which is how a network that accepts any connection is ruled out) and the
   connection step (a listening port connects in milliseconds, a closed port fails at
   once).
2. Source checks: Enable JIT checks the loopback before any JIT method and runs the
   shortcut only when it does not answer and the shortcut is turned on; "start" asks for
   the cellular step only when Madeira sees cellular data without Wi-Fi, and "done" undoes
   only what "start" changed; the restore runs after the debugger detached and before
   Wine starts; the app hands madeira://jit-network/... to the shortcut; Settings has the
   switch.
"""
from pathlib import Path
import json, os, shutil, socket, subprocess, sys, tempfile, threading

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


net = (app / 'JITNetwork.swift').read_text()
setup = (app / 'JITSetup.swift').read_text()
content = (app / 'ContentView.swift').read_text()
main_app = (app / 'MadeiraApp.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()

# ------------------------------------------------------------------ static
require('/* JITNetwork.swift in Sources */,' in project, 'JITNetwork.swift is built by the Xcode project')
require('static let address = "10.7.0.1"' in net and 'static let port: UInt16 = 62078' in net,
        "the check targets lockdownd through LocalDevVPN's loopback (10.7.0.1:62078, StikDebug's address)")
enable = setup[setup.index('    func enable(completion:'):setup.index('    private func enableResolved(')]
require(enable.index('ensureLoopback') < enable.index('self?.enableResolved'),
        'Enable JIT checks the loopback before any JIT method')
ensure = enable[enable.index('private func ensureLoopback('):]
require('guard let self, !probe.reachable, JITNetworkShortcut.shared.enabled else { proceed(false); return }' in ensure,
        'the shortcut runs only when the loopback does not answer and the shortcut is turned on')
require('JITNetworkShortcut.shared.restoreIfNeeded' in enable,
        'a JIT attempt that fails after the shortcut ran puts back what it changed')
start = net[net.index('    func start(completion:'):net.index('    /// From the launch thread')]
require('let cellular = cellularOnly' in start
        and start.index('pending = cellular ? "done cellular" : "done"') < start.index('run(cellular ? "start cellular" : "start"')
        and 'guard let input = pending else { completion(); return }' in start and 'run(input)' in start,
        '"start" asks for the cellular step only without Wi-Fi, and records the "done" it owes before it runs')
require('UserDefaults.standard.string(forKey: Self.pendingKey)' in net
        and 'JITNetworkShortcut.shared.restoreLeftover()' in main_app,
        'the owed "done" is kept on disk and run at the next launch if a run ended between them')
require('path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)' in net,
        'cellular-only comes from the system network path')
detach = content.index('winios_phase("detach-done")')
require(detach < content.index('JITNetworkShortcut.restoreBlocking()', detach) < content.index('self.startWineserver()', detach),
        'the restore runs after the debugger detached and before Wine starts')
require('.onOpenURL { url in JITNetworkShortcut.shared.handle(url) }' in main_app,
        "the app hands madeira:// URLs to the shortcut's handler")
require('URLQueryItem(name: "x-success", value: "madeira://jit-network/success")' in net
        and 'URLQueryItem(name: "name", value: Self.name)' in net and 'static let name = "Madeira JIT"' in net,
        'the shortcut runs through x-callback-url and returns to madeira://jit-network/')
require('ConnectionProblem(helperMessage: message) ?? (loopbackAnswered == false ? .vpn : nil)' in setup,
        "a JIT failure after a check that found no lockdownd is explained as LocalDevVPN (a network that accepts any connection gives 'early eof')")
require(ensure[:ensure.index('func connectWithShortcut(')].count('LoopbackProbe.waitUntilReachable(within: 15)') == 1,
        "after the shortcut, the loopback is awaited up to 15 s (LocalDevVPN's Connect returns before its tunnel routes)")
actions = setup[setup.index('@MainActor func jitConnectionActions('):setup.index('struct JITSettingsSection')]
require(actions.index('if JITNetworkShortcut.shared.enabled {') < actions.index('LocalDevVPN.open()')
        and 'if let retry { retry() } else { JITCoordinator.shared.connectWithShortcut() }' in actions,
        "with the shortcut on, the connect action runs the shortcut, never LocalDevVPN's link")
require('jitConnectionActions(jitProblem, retry: enableJIT)' in (app / 'Library.swift').read_text(),
        "the library's alert retries Enable JIT, which runs the shortcut")
require('Toggle("\\(JITNetworkShortcut.name) shortcut", isOn: $shortcut.enabled)' in setup
        and 'MadeiraConfig.flag("MADEIRA_JIT_SHORTCUT", fallback: false)' in net,
        'Settings › JIT has the switch, off by default (madeira.cfg env.MADEIRA_JIT_SHORTCUT)')

# ------------------------------------------------------------------ Swift
probe = net[net.index('enum LoopbackProbe {'):net.index('/// The user\'s "Madeira JIT" shortcut')]
probe = probe.replace('static let address = "10.7.0.1"', 'static var address = "10.7.0.1"') \
             .replace('static let port: UInt16 = 62078', 'static var port: UInt16 = 62078')
main = r'''
let args = CommandLine.arguments
LoopbackProbe.address = args[1]
LoopbackProbe.port = UInt16(args[2])!
let r = LoopbackProbe.check(timeout: 0.4, requireVPN: args[3] == "1")
let route = LoopbackProbe.route()
print("{\"reachable\": \(r.reachable), \"ms\": \(r.milliseconds), \"detail\": \"\(r.detail)\", \"interface\": \"\(route?.interface ?? "-")\", \"vpn\": \(route?.isVPN ?? false), \"ldv\": [\(LoopbackProbe.Route(interface: "utun5", address: "10.7.1.1").isLocalDevVPN), \(LoopbackProbe.Route(interface: "utun5", address: "172.19.0.1").isLocalDevVPN), \(LoopbackProbe.Route(interface: "en0", address: "10.7.1.1").isLocalDevVPN)]}")
'''


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 'main.swift'
    src.write_text('import Darwin\nimport Foundation\n' + probe + '\n' + main)
    exe = Path(tmp) / 'probe'
    build = subprocess.run([SWIFTC, '-O', str(src), '-o', str(exe)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        require(False, 'the production LoopbackProbe compiles on the host')
    else:
        def run(addr, port, require_vpn):
            out = subprocess.run([str(exe), addr, str(port), '1' if require_vpn else '0'],
                                 capture_output=True, text=True, timeout=10).stdout
            return json.loads(out)

        srv = socket.socket()
        srv.bind(('127.0.0.1', 0))
        srv.listen(8)
        threading.Thread(target=lambda: [srv.accept()[0].close() for _ in range(8)], daemon=True).start()
        port = srv.getsockname()[1]
        up = run('127.0.0.1', port, False)
        require(up['reachable'] and up['ms'] < 100, 'a listening port connects in %.1f ms (%s)' % (up['ms'], up['detail']))
        require(up['interface'].startswith('lo') and up['vpn'] is False,
                'the route check names the interface traffic leaves by (%s), and lo0 is not a VPN' % up['interface'])
        held = run('127.0.0.1', port, True)
        require(not held['reachable'] and held['ms'] < 50 and 'not a VPN' in held['detail'],
                'a listener that accepts, reached other than through a VPN, does not count, and is never connected to (%.1f ms, %s)'
                % (held['ms'], held['detail']))
        refused = run('127.0.0.1', free_port(), False)
        require(not refused['reachable'] and refused['ms'] < 100,
                'a closed port fails at once (%.1f ms, %s)' % (refused['ms'], refused['detail']))
        require(up['ldv'] == [True, False, False],
                "LocalDevVPN is told from another VPN by its tunnel address: utun5 10.7.1.1 is LocalDevVPN; "
                "utun5 172.19.0.1 (a VPN carrying all traffic) and en0 are not")
        srv.close()

print('\n%s' % ('ALL PASS' if failures == 0 else '%d FAILURE(S)' % failures))
sys.exit(0 if failures == 0 else 1)
