#!/usr/bin/env python3
"""Production registry/depot policy, atomic alias core, and batch ownership checks."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
swift = r'''
import Foundation
import Glibc
enum LibraryFlags { static func enabled(_ name: String) -> Bool { getenv(name).map { String(cString: $0) != "0" } ?? true } }
enum VDFParser { static func parseTextVDF(from: Data) -> [String: Any] { [:] } }
enum SteamLog { static func event(_ text: String) {} }
@MainActor final class SteamLibraryFetcher {
 var fixtures: [UInt32: SteamAppInfo] = [:]
 var calls: [UInt32] = []
 func fetchAppInfo(appID: UInt32) async throws -> SteamAppInfo? { calls.append(appID); return fixtures[appID] }
 FETCH_INSTALL_METHOD
}
@main struct Test {
@MainActor static func main() async throws {
let script = #"""
"InstallScript" {
 "Registry" { "HKLM\Software\Example\Product" {
  "string" { "Installed Path" "%INSTALLDIR%" "Quoted" "a\"b" "(Default)" "%STEAMPATH%" "Unknown" "%UNKNOWN%" }
  "dword" { "Version" "12" "english" { "Language" "1" } "french" { "Language" "2" } }
 } }
 "Registry" { "HKCU\Software\Example" { "string" { "Location" "%INSTALLDIR%\bin" } } }
 "Run Process" { "Prerequisite" { "HasRunKey" "HKLM\Software\Other" "Process 1" "%INSTALLDIR%\setup.exe" } }
}
"kvsignatures" { "installscript" "opaque" }
"""#
let v = try SteamInstallRegistry.values(Data(script.utf8), installPath: #"C:\Library\Fixture"#, steamPath: #"C:\Client"#)
assert(v.count == 6)
assert(v.first(where: { $0.name == "Version" })?.encoded == "dword:0000000c")
assert(v.first(where: { $0.name == "Language" })?.encoded == "dword:00000001")
assert(!v.contains { $0.name == "Unknown" || $0.name == "Prerequisite" })
let initial = "WINE REGISTRY Version 2\n\n[Software\\\\Unrelated] 1\n\"Keep\"=dword:00000005\n"
let (updated, count) = SteamInstallRegistry.applying(v.filter { $0.hive == .machine }, to: initial, now: 2)
assert(count == 10 && updated.contains("Wow6432Node"))
assert(updated.contains("\"Keep\"=dword:00000005") && updated.contains("@="))
assert(SteamInstallRegistry.applying(v.filter { $0.hive == .machine }, to: updated, now: 3).1 == 0)
let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let drive = prefix.appendingPathComponent("drive_c"), folder = drive.appendingPathComponent("Library/Fixture")
let steam = drive.appendingPathComponent("Client")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: prefix) }
try script.write(to: folder.appendingPathComponent("installscript.vdf"), atomically: true, encoding: .utf8)
for file in ["system.reg", "user.reg"] { try initial.write(to: prefix.appendingPathComponent(file), atomically: true, encoding: .utf8) }
let writes = try SteamInstallRegistry.prepare(folder: folder, drive: drive, steamRoot: steam)
assert(writes == 11)
let system = try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)
assert(system.contains("Installed Path") && system.contains("Wow6432Node") && system.contains("Keep"))
let repeatedWrites = try SteamInstallRegistry.prepare(folder: folder, drive: drive, steamRoot: steam)
assert(repeatedWrites == 0)
for malformed in ["\"InstallScript\" {", "}", "\"InstallScript\" { \"Registry\" }"] {
 do { _ = try SteamInstallRegistry.values(Data(malformed.utf8), installPath: "C:\\x", steamPath: "C:\\s"); fatalError("accepted malformed") } catch {}
}
var child = SteamAppInfo(appID: 9000), parent = SteamAppInfo(appID: 9001)
child.depots = [.init(depotID: 9002, fromApp: 9001), .init(depotID: 9003, manifests: ["public": 7], fromApp: 9001)]
parent.depots = [.init(depotID: 9002, oslist: "windows", manifests: ["public": 123], publicSizeBytes: 456, language: "english"), .init(depotID: 9003, manifests: ["public": 999])]
assert(child.inheritDepots(from: [9001: parent]) == 1)
assert(child.depots[0].publicManifestID == 123 && child.depots[0].language == "english")
assert(child.depots[1].publicManifestID == 7 && child.installDepots().count == 2)
assert(child.inheritDepots(from: [9001: parent]) == 0)
let fetcher = SteamLibraryFetcher()
var grandparent = SteamAppInfo(appID: 9004)
grandparent.depots = parent.depots
parent.depots[0].manifests = [:]; parent.depots[0].fromApp = 9004
// An unrelated dependency in the owner must not be traversed.
parent.depots.append(.init(depotID: 9090, fromApp: 9091))
child.depots[0].manifests = [:]
child.depots.append(.init(depotID: 9092, language: "french", fromApp: 9093))
fetcher.fixtures = [9000: child, 9001: parent, 9004: grandparent]
let inherited = try await fetcher.fetchInstallInfo(appID: 9000)
assert(inherited?.depots[0].publicManifestID == 123)
assert(fetcher.calls == [9000, 9001, 9004])
grandparent.depots[0].manifests = [:]; grandparent.depots[0].fromApp = 9001
fetcher.fixtures[9004] = grandparent; fetcher.calls = []
do { _ = try await fetcher.fetchInstallInfo(appID: 9000); fatalError("accepted unresolved cycle") } catch {}
assert(fetcher.calls == [9000, 9001, 9004])
setenv("MADEIRA_STEAM_SHARED_METADATA", "0", 1)
fetcher.calls = []
let legacy = try await fetcher.fetchInstallInfo(appID: 9000)
assert(legacy?.depots[0].publicManifestID == nil && fetcher.calls == [9000])
unsetenv("MADEIRA_STEAM_SHARED_METADATA")
fetcher.calls = []
let cancelled = Task { @MainActor in try await fetcher.fetchInstallInfo(appID: 9000) }
cancelled.cancel()
do { _ = try await cancelled.value; fatalError("ignored cancellation") } catch is CancellationError {}
assert(fetcher.calls.isEmpty)
print("PASS registry duplicate sections, paths, types, locale, idempotence, malformed input; exact shared depot inheritance")
print("PASS production shared resolver: nested references, unrelated/language exclusions, cycles and rollback")
}}
'''
fetcher_source = (app / 'SwiftSteam/Library/SteamLibraryFetcher.swift').read_text()
method_start = fetcher_source.index('    func fetchInstallInfo(')
swift = swift.replace('FETCH_INSTALL_METHOD', fetcher_source[method_start:fetcher_source.index('    private func fetchLicenseList', method_start)])
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
start = source.index('static int ios_mach_emulate_cas(')
cas = source[start:source.index('\n}', start) + 2]
c = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
''' + cas + r'''
int main(void) {
 uint64_t r[29] = {0}, mem = 17;
 r[8] = 17; r[0] = 99;
 assert(ios_mach_emulate_cas(0xc8e8fce0, (uintptr_t)&mem, r));
 assert(mem == 99 && r[8] == 17);
 r[8] = 18; r[0] = 100;
 assert(ios_mach_emulate_cas(0xc8e8fce0, (uintptr_t)&mem, r));
 assert(mem == 99 && r[8] == 99);
 uint32_t small = 42;
 r[8] = 0xffff00000000002aULL; r[0] = 0xffff00000000000bULL;
 assert(ios_mach_emulate_cas(0x88e8fce0, (uintptr_t)&small, r));
 assert(small == 11 && r[8] == 42);
 assert(!ios_mach_emulate_cas(0xc8e8fce0, (uintptr_t)&mem + 1, r));
 assert(!ios_mach_emulate_cas(0xd503201f, (uintptr_t)&mem, r));
 puts("PASS actual fault opcode CAS64 success/failure, CAS32 zero extension, alignment and non-CAS rejection");
}
'''
cpp = r'''
#include "d3d9_batch_budget.hpp"
#include <cassert>
#include <memory>
#include <iostream>
struct Payload { std::unique_ptr<int> p; char pad[244]; };
int main() {
 std::vector<Payload> batch;
 batch.reserve(8192);
 batch.push_back({std::make_unique<int>(37), {}});
 int *original = batch[0].p.get();
 dxmt::d9CompactBatch(batch, true);
 assert(batch.size() == 1 && batch[0].p.get() == original && *original == 37);
 assert(batch.capacity() < 8192);
 assert(dxmt::d9BatchReserve<Payload>(8192, false) == 8192);
 assert(dxmt::d9BatchReserve<Payload>(8192, true) * sizeof(Payload) <= 65536);
 size_t current = 0, submitted = 0, peak = 0;
 for (int i = 0; i < 10000; ++i) {
   std::vector<Payload> next;
   next.reserve(dxmt::d9BatchReserve<Payload>(8192, true));
   current += next.capacity() * sizeof(Payload);
   peak = std::max(peak, current);
   if (current >= dxmt::kD9BatchCommitBytes) { ++submitted; current = 0; }
 }
 assert(submitted > 0 && peak <= dxmt::kD9BatchCommitBytes + 65536);
 // ml1970: tiny flushes (one op in a full reserve) are trimmed and charged
 // what they hold, so thousands of them do not force a submission.
 size_t used_total = 0, tiny_submits = 0;
 for (int i = 0; i < 20000; ++i) {
   std::vector<Payload> tiny;
   tiny.reserve(dxmt::d9BatchReserve<Payload>(8192, true));
   tiny.push_back({std::make_unique<int>(i), {}});
   int *keep = tiny[0].p.get();
   dxmt::d9CompactBatch(tiny, true, true);
   assert(tiny.size() == 1 && tiny[0].p.get() == keep && tiny.capacity() * sizeof(Payload) <= 4096);
   used_total += dxmt::d9BatchCharge(tiny, true);
   if (used_total >= dxmt::kD9BatchCommitBytes) { ++tiny_submits; used_total = 0; }
 }
 assert(tiny_submits <= 1);
 // The ml1960 rule (capacity charge) submitted many times for the same stream.
 size_t legacy = 0, legacy_submits = 0;
 for (int i = 0; i < 20000; ++i) {
   legacy += dxmt::d9BatchReserve<Payload>(8192, true) * sizeof(Payload);
   if (legacy >= dxmt::kD9BatchLegacyCommitBytes) { ++legacy_submits; legacy = 0; }
 }
 assert(legacy_submits > 100);
 // Large real work still submits under the used-bytes charge.
 std::vector<Payload> big(40000);
 assert(dxmt::d9BatchCharge(big, true) >= dxmt::kD9BatchCommitBytes / 2);
 std::cout << "PASS batch slack compaction preserves moved ownership; speculative reservation and no-Present accounting bounded; ml1970 tiny flushes trimmed and charged by use\n";
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-compat-') as td:
    td = Path(td)
    (td/'Checks.swift').write_text(swift)
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc', str(app/'SteamFiles.swift'), str(app/'SteamInstallRegistry.swift'), str(app/'SwiftSteam/Library/SteamAppInfo.swift'), str(td/'Checks.swift'), '-o', str(td/'swift-check')], check=True)
    subprocess.run([str(td/'swift-check')], check=True)
    for name, code, compiler, options in [('cas.c', c, 'cc', ['-std=c11']), ('batch.cpp', cpp, 'c++', ['-std=c++20', '-I'+str(root/'research/dxmt/src/d3d9')])]:
        (td/name).write_text(code)
        subprocess.run([compiler, *options, '-fsanitize=address,undefined', str(td/name), '-o', str(td/'native-check')], check=True)
        subprocess.run([str(td/'native-check')], check=True)
assert 'ios_jit_anon_alias_lookup(fault_addr + cas_width - 1)' in source
device = (root/'research/dxmt/src/d3d9/d3d9_device.cpp').read_text()
assert 'm_batchBytesSinceCommit = 0;' in device
assert 'm_batchBytesSinceCommit >= (charge_used ? kD9BatchCommitBytes : kD9BatchLegacyCommitBytes)' in device
print('PASS integration guards present; device execution still required')
