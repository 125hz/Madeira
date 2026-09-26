#!/usr/bin/env python3
"""Compile the production diagnostic parser; never use real credentials."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
text = (root / 'app/Madeira/MadeiraDock.swift').read_text()
parser = text[text.index('    struct Report {'):text.index('    @MainActor private static var lastReport =')]
checks = r'''
func parse(_ text: String) -> MadeiraDock.Report { MadeiraDock.parseReport(Data(text.utf8)) }
let fingerprint = String(repeating: "a", count: 64)
let report = parse("[steam-host] ml1820 client-sha256=\(fingerprint)\r\n[steam-host] ml1830 session-unsupported-client=1\r\n[steam-host] ml1830 probe-result=30\r\n")
assert(report.result == 30 && report.failure!.contains("interface"))
assert(report.fields["client-sha256"] == fingerprint)
assert(parse("[steam-host] ml1830 probe-result=30\n").failure!.contains("initialize"))
assert(parse("[steam-host] ml1830 probe-result=35\n").failure!.contains("license"))
assert(parse("[steam-host] ml1830 probe-result=0\n").failure == nil)
assert(parse("[steam-host] ml1830 probe-result=30").result == nil)
assert(parse("[steam-host] ml1830 probe-result=30\n[steam-host] ml1830 probe-result=0\n").result == 0)
assert(parse("[steam-host] ml1860 session-client-adapter=202601\n").fields["session-client-adapter"] == "202601")
let transport = parse("[steam-host] ml1870 session-handoff-stage=1\r\n[steam-host] ml1870 session-handoff-error=3\r\n[steam-host] ml1830 probe-result=37\r\n")
assert(transport.fields["session-handoff-stage"] == "1" && transport.fields["session-handoff-error"] == "3")
assert(transport.failure!.contains("sign-in transfer") && transport.failure!.contains("not checked"))
assert(parse("[steam-host] ml1830 session-native-handoff-app-mismatch=1\n[steam-host] ml1830 probe-result=37\n").failure!.contains("different launch"))
let rejected = "[steam-host] ml1830 account=synthetic\n[steam-host] ml1830 token=synthetic\n[steam-host] ml1830 probe-result=2147483648\n[steam-host] ml1830 probe-result=secret\n[steam-host] ml1830 client-sha256=invalid\n[steam-host] unknown probe-result=0\n[steam-host] ml1830 probe-result=0 secret\n"
assert(parse(rejected).fields.isEmpty)
assert(parse(String(repeating: "x", count: 32769)).fields.isEmpty)
assert(MadeiraDock.parseReport(Data([0xff])).fields.isEmpty)
print("PASS: Dock report completion, CRLF, fingerprints, adapter version, failure reasons and private/malformed field rejection")
'''
with tempfile.TemporaryDirectory(prefix='madeira-dock-report-') as directory:
    source = Path(directory) / 'main.swift'; binary = Path(directory) / 'check'
    source.write_text('import Foundation\nenum MadeiraDock {\n' + parser + '\n}\n' + checks)
    subprocess.run(['/home/hero/.local/share/swiftly/bin/swiftc',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
