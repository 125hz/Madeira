#!/usr/bin/env python3
"""Run the production Swift validator and native Windows argument parser."""
from pathlib import Path
import json
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
swift = (root / 'app/Madeira/Library.swift').read_text()
start = swift.index('enum LaunchArgumentText {')
end = swift.index('\nextension Binding', start)
helper = swift[start:end]
native = (root / 'app/Madeira/WineProcessBridge.m').read_text()
start = native.index('static int madeira_split_launch_args(')
end = native.index('\nstatic void *wine_process_thread', start)
cases = [('', True), ('--flag "two words"', True), ('""', True),
         (r'--title \"word\"', True), (r'"C:\some path\\"', True),
         ('"unclosed', False), ('bad\nline', False), ('bad\x7f', False),
         ('x' * 4095, True), ('x' * 4096, False),
         (' '.join(['x'] * 64), True), (' '.join(['x'] * 65), False)]
with tempfile.TemporaryDirectory(prefix='madeira-args-') as folder:
    folder = Path(folder)
    checks = '\n'.join('precondition(LaunchArgumentText.valid(' + json.dumps(s) + ') == ' + str(ok).lower() + ')' for s, ok in cases if '\x7f' not in s)
    # JSON control escapes differ from Swift's Unicode escapes.
    checks = checks.replace(r'\n', r'\n')
    (folder / 'main.swift').write_text('import Foundation\n' + helper + '\n' + checks)
    subprocess.run(['swiftc', str(folder / 'main.swift'), '-o', str(folder / 'swift')], check=True)
    subprocess.run([str(folder / 'swift')], check=True)
    checks = '\n'.join('assert((madeira_split_launch_args(' + json.dumps(s).replace(r'\u007f', r'\177') + ', buf, sizeof(buf), argv, 64) >= 0) == ' + str(int(ok)) + ');' for s, ok in cases)
    c = '#include <assert.h>\n#include <string.h>\n' + native[start:end] + '\nint main(void) { char buf[4096]; char *argv[64];\n' + checks + '\nreturn 0; }'
    (folder / 'main.c').write_text(c)
    subprocess.run(['clang', '-fsanitize=address,undefined', str(folder / 'main.c'), '-o', str(folder / 'native')], check=True)
    subprocess.run([str(folder / 'native')], check=True)
print('PASS production launch argument validation and parsing')
