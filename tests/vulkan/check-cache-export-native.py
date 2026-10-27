#!/usr/bin/env python3
"""Run valid Vulkan cache exports against a real macOS MoltenVK library.

Usage: check-cache-export-native.py <Vulkan include directory> <libMoltenVK.dylib>
A stock v1.4.2 library is expected to fail the direct-export case.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 3:
    sys.exit(__doc__)
headers, library = (Path(arg).resolve() for arg in sys.argv[1:])
rpath = library.parent
for parent in library.parents:
    if parent.suffix == '.framework':
        rpath = parent.parent
        break
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='madeira-cache-export-') as directory:
    exe = Path(directory) / 'cache-export'
    subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-I' + str(headers), str(root / 'tests/x64/vulkan-cache-export.c'),
                    str(library), '-Wl,-rpath,' + str(rpath), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
