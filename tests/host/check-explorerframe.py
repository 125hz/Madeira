#!/usr/bin/env python3
"""Check the real packaged TaskbarList COM server, not a generated stub.

Run with an optional DLL farm path to check an extracted App/IPA as well.
This checks packaging only; run taskbarlist-x64.exe for actual COM activation.
"""
from pathlib import Path
import re
import runpy
import struct
import sys
import tarfile

root = Path(__file__).resolve().parents[2]
PE = runpy.run_path(str(root / 'tools/check-wine-media-dlls.py'))['PE']
farm = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'app/Madeira/arm64ec-windows'
shipped = {p.name.lower(): p for p in farm.iterdir() if p.is_file()}
name = 'explorerframe.dll'
assert name in shipped, 'TaskbarList registry entry points to missing explorerframe.dll'
module = PE(shipped[name])
pe_offset = struct.unpack_from('<I', module.data, 0x3c)[0]
machine = struct.unpack_from('<H', module.data, pe_offset + 4)[0]
# Wine hybrid DLLs retain an AMD64 PE machine and describe native code in CHPE.
assert machine in (0x8664, 0xa641), 'expected an ARM64EC-compatible COM server'
optional = pe_offset + 24
image_base = struct.unpack_from('<Q', module.data, optional + 24)[0]
config_rva, config_size = module.directories[10]
assert config_rva and config_size >= 208, 'missing ARM64EC load configuration'
metadata_va = module.unpack('<Q', module.offset(config_rva + 200, 8))[0]
assert metadata_va >= image_base, 'missing ARM64EC CHPE metadata'
version, code_map, code_count = module.unpack('<III', module.offset(metadata_va - image_base, 12))
assert version and 0 < code_count < 65536, 'invalid ARM64EC code map'
entries = [module.unpack('<II', module.offset(code_map + i * 8, 8)) for i in range(code_count)]
assert any(start & 3 == 1 and size for start, size in entries), 'missing native ARM64EC code range'
exports = module.exports()
for symbol in ('DllGetClassObject', 'DllCanUnloadNow', 'DllRegisterServer', 'DllUnregisterServer'):
    assert exports.get(symbol), 'missing implemented COM export: ' + symbol
assert not module.imports(True), 'COM server unexpectedly uses ARM64EC delay imports'
missing = {dep for dep in module.imports() if dep not in shipped and
           not (dep.startswith(('api-ms-', 'ext-ms-')) and 'apisetschema.dll' in shipped)}
assert not missing, 'missing COM server imports: ' + ', '.join(sorted(missing))
with tarfile.open(root / 'app/Madeira/prefix-template.tar.gz') as archive:
    registry = archive.extractfile('prefix/system.reg').read().decode('utf-8')
clsid = '{56FDF344-FD6D-11D0-958A-006097C9A090}'
# Check the native Classes registration, not only the separate Wow6432Node entry.
section = r'[Software\\Classes\\CLSID\\' + clsid + r'\\InprocServer32]'
assert section in registry, 'missing native TaskbarList COM registration'
entry = registry.split(section, 1)[1].split('\n[', 1)[0]
assert re.search(r'@="[^"\n]*explorerframe\.dll"', entry, re.I), 'wrong TaskbarList COM server'
assert '"ThreadingModel"="Apartment"' in entry, 'wrong TaskbarList threading model'
print('PASS: ARM64EC TaskbarList server, implemented COM exports, regular imports and prefix registration')

# Mutate real package copies; never execute a PE on the host or alter the farm.
if len(sys.argv) == 1:
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix='madeira-taskbar-package-') as tmp:
        folder = Path(tmp)
        for filename, path in shipped.items():
            if filename != name:
                (folder / filename).symlink_to(path.resolve())
        target = folder / name
        original = module.data

        def rejected(label, expected):
            result = subprocess.run([sys.executable, __file__, str(folder)], capture_output=True, text=True)
            assert result.returncode != 0 and expected in result.stderr, (label, result.stdout, result.stderr)

        rejected('missing server', 'missing explorerframe.dll')
        target.write_bytes(original[:100])
        rejected('truncation', 'missing PE signature')
        data = bytearray(original)
        struct.pack_into('<H', data, pe_offset + 4, 0x14c)
        target.write_bytes(data)
        rejected('wrong architecture', 'expected a 64-bit')
        data = bytearray(original)
        struct.pack_into('<Q', data, module.offset(config_rva + 200, 8), 0)
        target.write_bytes(data)
        rejected('missing CHPE metadata', 'missing ARM64EC CHPE metadata')
        data = bytearray(original)
        struct.pack_into('<II', data, optional + 112, 0, 0)
        target.write_bytes(data)
        rejected('missing exports', 'missing export directory')
        target.write_bytes(original)
        (folder / 'comctl32.dll').unlink()
        rejected('missing dependency', 'missing COM server imports: comctl32.dll')
    print('PASS: six missing/corrupt/wrong-architecture package mutations rejected')
