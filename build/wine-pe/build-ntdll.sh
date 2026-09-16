#!/bin/bash
# Build the ARM64EC PE ntdll from the wine submodule and post-process it the way
# the app needs: strip, then pad with zeros to SizeOfImage + 0x50000 (the loader
# maps the file image; the padding is the slack the iOS mapping path relies on).
# Other PE modules: `make -C dlls/<name>` in the same build tree, then copy the
# .dll from dlls/<name>/arm64ec-windows/ to app/Madeira/arm64ec-windows/ (no
# strip/pad for those). Requires the llvm-mingw toolchain (docs/BUILDING.md).
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
B="$R/wine/build-arm64ec"
if [ ! -f "$B/config.status" ]; then
    mkdir -p "$B" && cd "$B" && ../configure --enable-archs=arm64ec --without-x --disable-tests
fi
cd "$B" && make -C dlls/ntdll
SRC="$B/dlls/ntdll/arm64ec-windows/ntdll.dll"; OUT="$R/app/Madeira/arm64ec-windows/ntdll.dll"
cp "$SRC" "$OUT.tmp"
"$TC/arm64ec-w64-mingw32-strip" "$OUT.tmp"
python3 - "$OUT.tmp" <<'PY'
import struct, sys
p = sys.argv[1]; d = open(p, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
soi = struct.unpack_from('<I', d, pe + 24 + 56)[0]     # OptionalHeader.SizeOfImage
assert len(d) == soi, "stripped size %d != SizeOfImage %d" % (len(d), soi)
open(p, 'ab').write(b'\0' * 0x50000)
print("ntdll.dll: %d bytes = SizeOfImage %d + 0x50000" % (soi + 0x50000, soi))
PY
mv "$OUT.tmp" "$OUT"; ls -l "$OUT"
