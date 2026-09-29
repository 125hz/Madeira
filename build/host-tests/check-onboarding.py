#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Steam setup in the library (app/Madeira/Onboarding.swift), on the host.

1. Swift: compiles the production OnboardingRules with the production
   MadeiraConfig.swift (HOME pointed at a scratch directory) and checks the
   pages with and without Madeira Dock and Steam sign-in, the first-run
   decision and the UserDefaults done key, navigation and the step counter,
   and the MADEIRA_ONBOARDING switch from madeira.cfg and from the environment.
2. Source checks: the library opens setup once and reopens it from Settings,
   never over a session; the Steam settings use only sign-in's and Dock's
   public pieces (no Keychain or token access here); setup starts no Wine
   session and touches no JIT pool, engine switch or launch environment; no
   program-name list; no account, token or path in a log line; a Dock start
   from the library is an unsaved library session behind the
   one-session-per-run rule; the file is in the Xcode project.

Synthetic data only: no Steam, Wine or credentials. Needs `swiftc` on PATH
(or SWIFTC).
"""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


def block(text, header):
    p = text.index(header)
    a = text.index('{', p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == '{') - (text[b] == '}')
        b += 1
    return text[p:b]


onboarding = (app / 'Onboarding.swift').read_text()
library = (app / 'Library.swift').read_text()
content = (app / 'ContentView.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
docs = (root / 'docs/LIBRARY.md').read_text()

rules = onboarding[onboarding.index('// MARK: - Rules'):onboarding.index('// MARK: - Setup model')]
model = block(onboarding, 'final class OnboardingModel')
settings_section = block(onboarding, 'struct SteamSettingsSection: View')

# ------------------------------------------------------------------ static: provenance and project
require(onboarding.startswith('// SPDX-License-Identifier: GPL-3.0-or-later\n// Copyright 2026 125hz\n'
                              '// Madeira Converter Exception: see LICENSE-EXCEPTION.md\n'),
        'Onboarding.swift: GPL-3.0-or-later, Copyright 2026 125hz, Converter Exception')
require('/* Onboarding.swift in Sources */,' in project and 'path = "Onboarding.swift"' in project,
        'Onboarding.swift is built by the Xcode project')
require(not re.search(r'\b(SwiftUI|UIKit|View|UIDevice)\b', rules.replace('// MARK: - Rules', '')),
        'the rules are Foundation-only (compiled on the host)')

# ------------------------------------------------------------------ static: when setup opens
present = block(model, 'func presentIfNeeded()')
require('guard !considered' in present and 'OnboardingRules.shouldShow(done: Self.done, enabled: Self.enabled, steps: steps)' in present,
        'setup is considered once per run and opens only by the rules')
opener = block(model, 'private func open(reason: String)')
require('LibraryModel.shared.current == nil' in opener and 'wine_process_is_running() == 0' in opener and 'guard available' in opener,
        'setup never opens over a running session, or with nothing to set up')
require('OnboardingRules.steps(signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled)' in model,
        'the pages follow the sign-in and Dock switches')
require(model.count('UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)') == 2
        and 'UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)' in block(model, 'func finish()')
        and 'UserDefaults.standard.set(true, forKey: OnboardingRules.doneKey)' in block(model, 'func skip()')
        and 'removeObject' not in onboarding and 'set(false' not in onboarding,
        'only finishing or skipping stores the done key; nothing clears it')
require('static var enabled: Bool { OnboardingRules.enabled }' in model, 'the model uses the rules switch')
require('.fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }' in library,
        'Library: setup is presented over the library')
require('onboarding.presentIfNeeded()' in block(library, 'struct LibraryView: View'),
        'Library: setup is considered when the library appears')
require(library.count('!onboarding.presented') >= 2, 'Library: controller commands do not act behind setup')
require('if onboarding.available {' in settings_section and 'onboarding.rerun()' in settings_section,
        'Settings › Steam: Run setup again, hidden with MADEIRA_ONBOARDING=0')

# ------------------------------------------------------------------ static: skippable steps
view = block(onboarding, 'struct OnboardingView: View')
for page in ['private var signInPage', 'private var dockClientPage']:
    require('secondary("Set up later") { model.next() }' in block(view, page), f'{page.split()[-1]}: Set up later')
require('secondary("Skip setup") { model.skip() }' in block(view, 'private var welcome'), 'welcome: visible Skip setup')
require('onTapGesture' not in onboarding, 'no hidden gestures')
require('dock.prepareClient()' in block(view, 'private var dockClientPage'), "components through Dock's verified download")

# ------------------------------------------------------------------ static: sign-in and tokens
require('SteamSignInView()' in view and 'SteamSignInView()' in settings_section, "sign-in through #45's sheet")
require('signIn.signOut()' in settings_section, "sign-out through #45's model")
require('MadeiraDockView(start: startDock)' in settings_section, "Settings opens Dock's sheet")
for forbidden in ['SteamTokenStore', 'credentialsForDock', 'refreshToken', 'SecItem', 'kSec', 'accessToken']:
    require(forbidden not in onboarding, f'Onboarding.swift: no {forbidden} (tokens only via the sign-in store)')
for line in onboarding.splitlines():
    if re.search(r'LogStore|SteamLog\.|print\(|NSLog|fputs', line):
        require(re.search(r'\\\((name|account|signIn|token|url|path|game|status|error)', line) is None,
                f'no account, token or path in "{line.strip()[:70]}"')

# ------------------------------------------------------------------ static: no Wine, pool, engine or exe-name behaviour
for forbidden in ['runWineFullSequence', 'setenv(', 'unsetenv(', 'MADEIRA_EXE', 'MADEIRA_ARGS', 'jit_', 'StikJITHelper',
                  'poolSize', 'JITPool', 'MADEIRA_POOL', 'FEX_', 'DXMT', 'MADEIRA_JIT', 'steamwebhelper', 'SteamSetup',
                  'inproc-sync', 'swap-mb', 'MADEIRA_FASTSYNC', 'madsync']:
    require(forbidden not in onboarding, f'Onboarding.swift: no {forbidden}')
require(not re.search(r'\b(512|896|1024|1152)\b', onboarding), 'Onboarding.swift: no pool size')
exes = {m.split('/')[-1].split('\\')[-1].lower() for m in re.findall(r'"([^"\n]*?\.exe)"', onboarding)}
require(exes <= {'explorer.exe'}, f'Onboarding.swift: no program-name list ({sorted(exes)})')
require('.exe' not in rules, 'rules key nothing on program names')

# ------------------------------------------------------------------ static: Dock from the library
start = block(content, 'private func startDock(_ game: DockGame, compactPool: Bool)')
require('LibraryView(play: launchLibraryEntry, enableJIT: enableJITViaStikDebug,\n                                startDock: { startDock($0, compactPool: $1) })' in content,
        "ContentView hands Dock's start to the library")
held = start.index('LibraryModel.sessionsThisRun > 0, MadeiraConfig.flag("MADEIRA_ONE_SESSION_PER_RUN")')
require(held < start.index('MadeiraDock.writeHandoff('), 'a held Dock start writes no sign-in transfer')
require('if inLibrary { library.begin(.dockSession(title: game.name, width: width, height: height), remember: false) }' in start
        and start.index('library.begin(') < start.index('runWineFullSequence()'),
        'a Dock start from the library is an unsaved library session')
require(start.count('runWineFullSequence(') == 1 and 'runWineFullSequence()' in start,
        "Dock's launch path is unchanged (no library profile applied over its environment)")
begin = block(library, 'func begin(_ entry: LibraryEntry, remember: Bool = true)')
require('if remember { var played = entry; played.lastPlayed = Date(); save(played) }' in begin,
        'begin(remember: false) neither adds nor stamps an entry')
dock_entry = block(onboarding, 'static func dockSession(')
require('entry.desktop = true' in dock_entry and 'save(' not in dock_entry, 'the Dock session entry is a desktop session, never saved')
require('MADEIRA_ONBOARDING' in docs and '## Steam setup' in docs, 'docs/LIBRARY.md documents setup and its switch')

# ------------------------------------------------------------------ compiled rules
checks = r'''
import Foundation
@main struct Checks {
    static var failed = 0
    static func expect(_ condition: Bool, _ label: String) {
        print((condition ? "PASS: " : "FAIL: ") + label)
        if !condition { failed += 1 }
    }
    static func main() {
        typealias R = OnboardingRules
        let full: [R.Step] = [.welcome, .signIn, .dockClient, .done]
        expect(R.doneKey == "madeiraOnboardingDone", "done key")
        expect(R.Step.signIn.rawValue == "sign-in" && R.Step.dockClient.rawValue == "dock-client", "log step names")

        // Pages with and without Dock.
        expect(R.steps(signIn: true, dock: true) == full, "with Dock: sign-in, then Valve's client components")
        expect(R.steps(signIn: true, dock: false) == [.welcome, .signIn, .done], "without Dock: sign-in only, no components page")
        expect(R.steps(signIn: false, dock: true) == full, "Dock keeps the sign-in page (it needs a sign-in)")
        expect(R.steps(signIn: false, dock: false) == [.welcome, .done], "neither: nothing to set up")
        expect(R.hasSetup(full) && R.hasSetup([.welcome, .signIn, .done]) && !R.hasSetup([.welcome, .done]), "hasSetup")

        // First-run decision.
        expect(R.shouldShow(done: false, enabled: true, steps: full), "new install shows setup")
        expect(!R.shouldShow(done: true, enabled: true, steps: full), "finished or skipped setup stays closed")
        expect(!R.shouldShow(done: false, enabled: false, steps: full), "MADEIRA_ONBOARDING=0 never shows it")
        expect(!R.shouldShow(done: false, enabled: true, steps: [.welcome, .done]), "nothing to set up: never shown")

        // The done key in UserDefaults.
        let suite = "madeira-onboarding-check"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        expect(R.shouldShow(done: defaults.bool(forKey: R.doneKey), enabled: true, steps: full), "missing key (fresh install) shows setup")
        defaults.set(true, forKey: R.doneKey)
        expect(!R.shouldShow(done: defaults.bool(forKey: R.doneKey), enabled: true, steps: full), "stored key hides setup")
        defaults.removePersistentDomain(forName: suite)

        // Navigation and the step counter.
        var walked: [R.Step] = [.welcome]
        while let next = R.next(after: walked.last!, in: full) { walked.append(next) }
        expect(walked == full, "Next walks every page in order")
        expect(R.next(after: .done, in: full) == nil, "done is the last page")
        expect(R.next(after: .dockClient, in: [.welcome, .signIn, .done]) == nil, "a page not in the list ends setup")
        expect(R.next(after: .signIn, in: [.welcome, .signIn, .done]) == .done, "without Dock, sign-in leads to done")
        expect(R.position(of: .signIn, in: full)! == (1, 2) && R.position(of: .dockClient, in: full)! == (2, 2), "step n of m with Dock")
        expect(R.position(of: .signIn, in: [.welcome, .signIn, .done])! == (1, 1), "one step without Dock")
        expect(R.position(of: .welcome, in: full) == nil && R.position(of: .done, in: full) == nil, "no counter on welcome and done")

        // The switch: default on; env.MADEIRA_ONBOARDING = 0 in madeira.cfg; the environment.
        let docs = MadeiraConfig.documents!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let cfg = docs.appendingPathComponent("madeira.cfg")
        try? FileManager.default.removeItem(at: cfg)
        unsetenv("MADEIRA_ONBOARDING")
        expect(R.enabled, "MADEIRA_ONBOARDING is on by default")
        setenv("MADEIRA_ONBOARDING", "0", 1)
        expect(!R.enabled, "MADEIRA_ONBOARDING=0 in the environment turns setup off")
        unsetenv("MADEIRA_ONBOARDING")
        try! "# notes\nenv.MADEIRA_ONBOARDING = 0\n".write(to: cfg, atomically: true, encoding: .utf8)
        expect(!R.enabled, "env.MADEIRA_ONBOARDING = 0 in madeira.cfg turns setup off")
        try! "env.MADEIRA_ONBOARDING = 1\n".write(to: cfg, atomically: true, encoding: .utf8)
        expect(R.enabled, "env.MADEIRA_ONBOARDING = 1 keeps it on")
        exit(failed == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-onboarding-check-') as tmp:
    folder = Path(tmp)
    (folder / 'Rules.swift').write_text('import Foundation\n' + rules)
    (folder / 'Checks.swift').write_text(checks)
    home = folder / 'home'
    home.mkdir()
    exe = folder / 'check'
    build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                            str(folder / 'Rules.swift'), str(app / 'MadeiraConfig.swift'), str(folder / 'Checks.swift')],
                           capture_output=True, text=True)
    require(build.returncode == 0, 'production onboarding rules and MadeiraConfig compile on the host')
    if build.returncode:
        sys.stdout.write(build.stderr[-4000:])
    else:
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        env.pop('MADEIRA_ONBOARDING', None)
        run = subprocess.run([str(exe)], env=env, capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode:
            sys.stdout.write(run.stderr[-4000:])
        require(run.returncode == 0, 'onboarding rule checks pass')

if failures:
    print(f'check-onboarding: {failures} FAILED')
    sys.exit(1)
print('check-onboarding: PASS')
