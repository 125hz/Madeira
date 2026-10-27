#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Known-harmless warnings in the live log (app/Madeira/LogPattern.swift).

Lines shaped like a Steam session's: the other display drivers, Steam's SDL3
probe and the WoW64 CPU fallback read as harmless; out of memory and other
missing DLLs stay errors. Synthetic only.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
checks = r'''
func level(_ line: String) -> (String, LogStore.LogEntry.Level) { LogPattern.canonicalize(line) }
let harmless = [
    #"0024:err:module:load_dll [dll-missing] rev=ml336 #1 L"winemac.drv" status=c0000135 -- note"#,
    #"0050:err:module:load_dll [dll-missing] rev=ml336 #3 L"C:\\Program Files (x86)\\Steam\\SDL3.dll" status=c000007b -- note"#,
    #"00a8:err:module:load_dll [dll-missing] rev=ml336 #1 L"\\??\\C:\\windows\\system32\\wow64cpu.dll" status=c0000135"#,
    #"00a8:err:wow:load_cpu_dll CPU backend wow64cpu.dll not available, falling back to the platform default xtajit.dll"#,
    #"0030:err:module:import_dll Library Kerberos.dll (which is needed by L"x") not found"#,
    "Failed to mprotect last page of code buffer",
]
for line in harmless {
    let (sig, lvl) = level(line)
    assert(sig.hasPrefix("harmless: ") && lvl == .debug, line)
}
let errors = [
    #"00ac:err:module:load_dll [dll-missing] rev=ml336 #15 L"v8.dll" status=c0000017 -- note"#,
    #"00ac:err:module:load_dll [dll-missing] rev=ml336 #16 L"SDL3.dll" status=c0000017"#,
    #"00b0:err:module:load_dll [dll-missing] rev=ml336 #9 L"gameoverlayrenderer64.dll" status=c000007b"#,
    #"00b0:err:module:load_dll [dll-missing] rev=ml336 #9 L"notsdl3.dll" status=c0000135"#,
]
for line in errors {
    let (sig, lvl) = level(line)
    assert(!sig.hasPrefix("harmless: ") && lvl == .error, line)
}
print("PASS: harmless warnings marked (display drivers, sign-in packages, Steam's optional modules, WoW64 CPU fallback); out of memory and other DLLs stay errors")
'''
if not Path(SWIFTC).exists():
    if '--require-swift' in sys.argv: sys.exit('FAIL: Swift compiler unavailable')
    print('SKIP: Swift compiler unavailable locally'); sys.exit(0)
with tempfile.TemporaryDirectory(prefix='madeira-harmless-') as directory:
    source = Path(directory) / 'main.swift'; binary = Path(directory) / 'check'
    stub = 'enum LogStore { struct LogEntry { enum Level: String { case info = "INFO", success = "OK", error = "ERR", debug = "DBG" } } }\n'
    source.write_text((root / 'app/Madeira/LogPattern.swift').read_text() + '\n' + stub + checks)
    subprocess.run([SWIFTC, str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
