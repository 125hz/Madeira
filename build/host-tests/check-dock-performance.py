#!/usr/bin/env python3
"""Compile production pool/diagnostic policy, including desktop recovery cases."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/MadeiraDock.swift').read_text(encoding='utf-8')
start = source.index('enum DockPerformancePolicy {')
policy = source[start:source.index('\n}', start) + 2]
tests = r'''
import Foundation
import Glibc
func early(_ legacy: Int = 896, _ explicit: Int? = nil, _ dock: Bool = true,
           _ compact: Bool = true, _ setup: Bool = true, _ desktop: Bool = false) -> Int {
    DockPerformancePolicy.earlyPoolMB(legacy: legacy, explicit: explicit,
        dock: dock, compact: compact, setupComplete: setup, desktopReserved: desktop)
}
assert(early() == 512)
assert(early(1152) == 512) // obsolete setup/sticky desktop high-water
assert(early(1152, nil, true, true, false) == 1152) // unfinished onboarding
assert(early(896, nil, false) == 896) // legacy client route
assert(early(896, nil, true, false) == 896) // rollback
assert(early(512, nil, true, true, true, true) == 896) // desktop recovery
assert(early(1152, nil, true, true, true, true) == 1152)
for override in [256, 512, 640, 896, 1152] {
    assert(early(896, override) == override)
    assert(early(896, override, true, true, true, true) == override)
    assert(!DockPerformancePolicy.needsDesktopRestart(compactPoolMB: 512,
        explicit: override, desktop: true, dock: false))
}
assert(DockPerformancePolicy.needsDesktopRestart(compactPoolMB: 512,
    explicit: nil, desktop: true, dock: false))
for size in [0, 896, 1152] {
    assert(!DockPerformancePolicy.needsDesktopRestart(compactPoolMB: size,
        explicit: nil, desktop: true, dock: false))
}
assert(!DockPerformancePolicy.needsDesktopRestart(compactPoolMB: 512,
    explicit: nil, desktop: true, dock: true))
assert(!DockPerformancePolicy.needsDesktopRestart(compactPoolMB: 512,
    explicit: nil, desktop: false, dock: false))
for dock in [false, true] { for light in [false, true] {
    for diagnostic in [false, true] { for forensic in [false, true] {
        let value = DockPerformancePolicy.censusDefault(dock: dock, lightweight: light,
            diagnostic: diagnostic, forensic: forensic)
        assert(value == (dock && light && !diagnostic && !forensic ? "0" : nil))
        // The real launch block only installs a default into an unset variable.
        setenv("MADEIRA_D3D9_CENSUS", "1", 1)
        if let value { setenv("MADEIRA_D3D9_CENSUS", value, 0) }
        assert(String(cString: getenv("MADEIRA_D3D9_CENSUS")) == "1")
    }}
}}
print("PASS: compact/setup/rollback/explicit sizing, desktop recovery, diagnostic overrides")
'''
content = (root / 'app/Madeira/ContentView.swift').read_text(encoding='utf-8')
launch = content[content.index('private func runWineFullSequence('):]
assert launch.index('reserveDesktopPoolIfNeeded') < launch.index('isLaunching = true')
assert 'getenv("MADEIRA_D3D9_CENSUS") == nil' in launch
assert 'setenv("MADEIRA_D3D9_CENSUS", value, 0)' in launch
assert launch.index('censusDefault(') < launch.index('startWineProcess()')
jit = (root / 'app/Madeira/StikJITHelper.swift').read_text(encoding='utf-8')
assert 'UserDefaults.standard.set(true, forKey: desktopPoolKey)' in jit
assert 'if sizeMB >= 896 { UserDefaults.standard.removeObject(forKey: desktopPoolKey) }' in jit
assert 'DockPerformancePolicy.earlyPoolMB' in jit
begin = jit.index('    private static let desktopPoolKey')
end = jit.index('    /// Install the SIGTRAP fallback', begin)
pool_methods = jit[begin:end]
fixtures = r'''
final class DefaultsFixture {
    var values: [String: Bool] = [:]
    var ints: [String: Int] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func set(_ value: Int, forKey key: String) { ints[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key); ints.removeValue(forKey: key) }
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func integer(forKey key: String) -> Int { ints[key] ?? 0 }
}
enum LibraryFlags {
    static var off: Set<String> = []
    static func enabled(_ key: String) -> Bool { !off.contains(key) }
}
enum UserDefaults { static let standard = DefaultsFixture() }
enum MadeiraConfig {
    static var override: String?
    static func get(_ key: String) -> String? { override }
}
final class LogStore { static let shared = LogStore(); func log(_ value: String) {} }
enum PoolHarness {
    static var poolReady = false
    METHODS
}
'''.replace('METHODS', pool_methods)
tests += r'''
let key = "madeiraDockDesktopPoolNextRun"
assert(!PoolHarness.reserveDesktopPoolIfNeeded(desktop: true, dock: false))
PoolHarness.rememberCompactPool(sizeMB: 512, selected: true)
PoolHarness.poolReady = true
assert(!PoolHarness.reserveDesktopPoolIfNeeded(desktop: true, dock: true))
assert(PoolHarness.reserveDesktopPoolIfNeeded(desktop: true, dock: false))
assert(UserDefaults.standard.bool(forKey: key))
// A failed/undersized allocation must not consume the next-run reservation.
PoolHarness.rememberCompactPool(sizeMB: 768, selected: false)
assert(UserDefaults.standard.bool(forKey: key))
PoolHarness.rememberCompactPool(sizeMB: 896, selected: false)
assert(!UserDefaults.standard.bool(forKey: key))
MadeiraConfig.override = "640"
assert(!PoolHarness.reserveDesktopPoolIfNeeded(desktop: true, dock: false))
MadeiraConfig.override = " 512\n"
assert(PoolHarness.explicitPoolMB == 512)
MadeiraConfig.override = "255"
assert(PoolHarness.explicitPoolMB == nil)
MadeiraConfig.override = "invalid"
assert(PoolHarness.explicitPoolMB == nil)
// ml2000: pool-pressure feedback.
assert(DockPerformancePolicy.earlyPoolMB(legacy: 512, explicit: nil, dock: true, compact: true,
       setupComplete: true, desktopReserved: false, pressureMB: 896) == 896)
assert(DockPerformancePolicy.earlyPoolMB(legacy: 512, explicit: 640, dock: true, compact: true,
       setupComplete: true, desktopReserved: false, pressureMB: 1152) == 640)
assert(DockPerformancePolicy.earlyPoolMB(legacy: 896, explicit: nil, dock: false, compact: true,
       setupComplete: true, desktopReserved: false, pressureMB: 1152) == 1152)
assert(DockPerformancePolicy.earlyPoolMB(legacy: 512, explicit: nil, dock: true, compact: true,
       setupComplete: true, desktopReserved: false, pressureMB: 100) == 512)
assert(DockPerformancePolicy.poolAfterPressure(usedMB: 512) == 896)
assert(DockPerformancePolicy.poolAfterPressure(usedMB: 896) == 1152)
assert(DockPerformancePolicy.poolAfterPressure(usedMB: 1152) == 1152)
UserDefaults.standard.set(896, forKey: "madeiraPoolPressureMB")
assert(PoolHarness.poolPressureFloorMB == 896)
LibraryFlags.off = ["MADEIRA_POOL_FEEDBACK"]
assert(PoolHarness.poolPressureFloorMB == 0 && PoolHarness.consumePoolPressure() == 0)
LibraryFlags.off = []
print("PASS: production reservation persistence, successful-allocation consumption, manual overrides and ml2000 pool-pressure floor")
'''
with tempfile.TemporaryDirectory(prefix='madeira-perf-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(tests + '\n' + policy + '\n' + fixtures, encoding='utf-8')
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc', str(folder / 'main.swift'),
                    '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
