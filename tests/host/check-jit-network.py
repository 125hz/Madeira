#!/usr/bin/env python3
"""LocalDevVPN loopback check and the Madeira JIT shortcut (app/Madeira/JITNetwork.swift);
no device runs.

1. Swift: compiles the production LoopbackProbe on the host, pointed at local test
   listeners, and checks that a fake lockdownd answering QueryType counts within
   milliseconds, while a listener that accepts but stays silent (a proxy), one that
   answers something else, and a closed port do not, each within the timeout.
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
start = net[net.index('    func start(vpnWasUp:'):net.index('    /// Runs "done"')]
require('let cellular = cellularOnly' in start and 'run(cellular ? "start cellular" : "start")' in start
        and 'self?.restore = (cellular, !vpnWasUp)' in start,
        '"start" asks for the cellular step only without Wi-Fi; "done" undoes only what "start" changed')
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
let r = LoopbackProbe.check(timeout: 0.4)
print("{\"reachable\": \(r.reachable), \"ms\": \(r.milliseconds), \"detail\": \"\(r.detail)\", \"vpn\": \(LoopbackProbe.vpnInterfaceUp)}")
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
        def run(addr, port):
            out = subprocess.run([str(exe), addr, str(port)], capture_output=True, text=True, timeout=10).stdout
            return json.loads(out)

        def serve(reply):
            """A listener that answers the first request with `reply` (None: stays silent)."""
            srv = socket.socket()
            srv.bind(('127.0.0.1', 0))
            srv.listen(4)

            def loop():
                while True:
                    try:
                        conn, _ = srv.accept()
                    except OSError:
                        return
                    conn.recv(4096)
                    if reply is not None:
                        body = reply.encode()
                        conn.sendall(len(body).to_bytes(4, 'big') + body)
                    else:
                        threading.Event().wait(1.0)
                    conn.close()
            threading.Thread(target=loop, daemon=True).start()
            return srv

        lockdownd = serve('<?xml version="1.0"?><plist version="1.0"><dict><key>Request</key><string>QueryType</string>'
                          '<key>Type</key><string>com.apple.mobile.lockdown</string></dict></plist>')
        up = run('127.0.0.1', lockdownd.getsockname()[1])
        require(up['reachable'] and up['ms'] < 100, 'lockdownd answering QueryType counts, in %.1f ms (%s)' % (up['ms'], up['detail']))
        silent = serve(None)
        proxy = run('127.0.0.1', silent.getsockname()[1])
        require(not proxy['reachable'] and proxy['ms'] < 700,
                'a listener that accepts but is not lockdownd (a proxy) does not count (%.0f ms, %s)' % (proxy['ms'], proxy['detail']))
        other = serve('<plist><dict><key>Type</key><string>something.else</string></dict></plist>')
        wrong = run('127.0.0.1', other.getsockname()[1])
        require(not wrong['reachable'], 'a reply that is not lockdownd does not count (%s)' % wrong['detail'])
        refused = run('127.0.0.1', free_port())
        require(not refused['reachable'] and refused['ms'] < 100,
                'a closed port fails at once (%.1f ms, %s)' % (refused['ms'], refused['detail']))
        require(up['vpn'] is False or up['vpn'] is True, 'the VPN interface check runs')
        for srv in (lockdownd, silent, other):
            srv.close()

print('\n%s' % ('ALL PASS' if failures == 0 else '%d FAILURE(S)' % failures))
sys.exit(0 if failures == 0 else 1)
