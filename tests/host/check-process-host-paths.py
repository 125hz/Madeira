#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Check the production taskbar's C:/D: executable and working-folder mapping."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/WindowedMode.swift').read_text()
start = source.index('    private static func windowsPath(')
end = source.index('    private static var libraryNote', start)
functions = source[start:end].replace('private static', 'static')
code = 'import Foundation\nenum Paths {\n' + functions + r'''
}
let cases = [
    ("Program Files/Client/client.exe", "C:\\Program Files\\Client\\client.exe", "C:\\Program Files\\Client"),
    ("D:\\Steam\\steam.exe", "D:\\Steam\\steam.exe", "D:\\Steam"),
    ("C:\\client.exe", "C:\\client.exe", "C:\\"),
    ("D:\\client.exe", "D:\\client.exe", "D:\\"),
    ("client.exe", "C:\\client.exe", "C:\\")
]
for (input, expected, folder) in cases {
    precondition(Paths.windowsPath(input) == expected)
    precondition(Paths.windowsFolder(input) == folder)
}
print("process-host shared-drive launch paths: PASS")
'''
swiftc = shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
with tempfile.TemporaryDirectory(prefix='madeira-process-paths-') as temp:
    path = Path(temp)
    (path / 'test.swift').write_text(code)
    subprocess.run([swiftc, str(path / 'test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
