#!/usr/bin/env python3
"""Read standard and delayed imports from bounded PE32 and PE32+ fixtures."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('game_deps', root / 'tools/check-game-deps.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / 'sample.exe'
    for machine, magic, optional_size in [(0x14c, 0x10b, 224), (0x8664, 0x20b, 240)]:
        data = bytearray(2048)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 0x80)
        data[0x80:0x84] = b'PE\0\0'
        struct.pack_into('<HH', data, 0x84, machine, 1)
        struct.pack_into('<H', data, 0x94, optional_size)
        optional = 0x98
        struct.pack_into('<H', data, optional, magic)
        directories = optional + (112 if magic == 0x20b else 96)
        struct.pack_into('<II', data, directories + 8, 0x1000, 40)
        struct.pack_into('<II', data, directories + 13 * 8, 0x1080, 64)
        section = optional + optional_size
        struct.pack_into('<IIII', data, section + 8, 1024, 0x1000, 1024, 0x400)
        struct.pack_into('<I', data, 0x400 + 12, 0x1040)
        data[0x440:0x44c] = b'normal.dll\0\0'
        struct.pack_into('<II', data, 0x480, 1, 0x10e0)
        data[0x4e0:0x4eb] = b'delayed.dll'
        binary.write_bytes(data)
        assert module.parse_pe_imports(binary) == (machine, ['delayed.dll', 'normal.dll'])
        for cut in (0, 63, 0x98, 0x100):
            binary.write_bytes(data[:cut])
            module.parse_pe_imports(binary)
    binary.write_bytes(b'not a PE file')
    result = subprocess.run([sys.executable, str(root / 'tools/check-game-deps.py'), str(binary)], capture_output=True)
    assert result.returncode == 1 and b'error:' in result.stderr
print('PASS: PE32/PE32+ standard and delayed imports, truncated headers, invalid-file CLI')
