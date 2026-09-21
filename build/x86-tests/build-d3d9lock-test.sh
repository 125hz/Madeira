#!/bin/bash
# MADEIRA-TEMP: build the D3D9 partial-surface-update self-test,
# d3d9lock-x86.exe.  See build/x86-tests/d3d9lock-x86.c for what each case
# asserts and what each exit code means.
#
# Subject under test:
#   research/dxmt/src/d3d9/d3d9_surface.cpp   LockRect / UnlockRect -- the
#       sub-rect pointer and pitch handed to the application, the dirty-rect
#       bookkeeping, and the partial-extent upload on Unlock
#   research/dxmt/src/d3d9/d3d9_image_lock.hpp  the shared offset arithmetic
#       both ends of that pair use
#   research/dxmt/src/d3d9/d3d9_device.cpp    stageTextureUpload (the single
#       CPU->GPU texel funnel), UpdateSurface, UpdateTexture, StretchRect,
#       ColorFill, GetRenderTargetData
#   research/dxmt/src/d3d9/d3d9_texture.cpp   the MANAGED dirty region and the
#       pre-draw managed sweep that flushes it
#
# d3d9dxt-x86.exe proves the BC decode; this proves the PARTIAL UPDATE around
# it -- that an image built from many small sub-rect writes spread over several
# frames is, on every frame, the sum of the writes issued so far.  A screenshot
# cannot separate a lost dirty rect from a level-replacing staging buffer from a
# wrong source offset; this can.
#
# Kept separate from build.sh and from the other per-test scripts here, the
# same way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-d3d9lock-test.sh
#
# Produces d3d9lock-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + gdi32 + d3d9, all Wine-supplied; the script
# asserts it.  gdi32 is here only for the GetDC case (CreateSolidBrush /
# TextOutA / SetBkColor); every other test in this directory stops at user32.
set -e

NAME=d3d9lock-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/gdi32/d3d9) ==="
# Same flag set and the same reasons as build-d3d9dxt-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -luser32 -lgdi32 -ld3d9

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== asserting the import set is Wine-supplied only ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        kernel32.dll|user32.dll|gdi32.dll|d3d9.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: the test must import only Wine-supplied DLLs."
    exit 1
fi

echo ""
echo "=== asserting the large-address-aware bit is set ==="
if "$OBJDUMP" -p "$NAME.exe" | grep -q "LARGE_ADDRESS_AWARE"; then
    echo "LARGE_ADDRESS_AWARE present"
else
    chars=$("$TOOLCHAIN/llvm-readobj" --file-headers "$NAME.exe" \
            | sed -n 's/.*IMAGE_FILE_LARGE_ADDRESS_AWARE.*/yes/p' | head -1)
    if [ "$chars" = yes ]; then
        echo "LARGE_ADDRESS_AWARE present (readobj)"
    else
        echo "FAILED: LARGE_ADDRESS_AWARE not set."
        exit 1
    fi
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run it from the Custom popup as  C:\\windows\\syswow64\\d3d9lock-x86.exe"
echo "Expected log: one MADEIRA-D9LOCK line per case, then"
echo "  MADEIRA-D9LOCK: <n> cases run, <m> skipped, 0 failed -- PASS"
echo "  MADEIRA-EXIT: d3d9lock-x86.exe status=57"
echo "Any other status is the exit code of the FIRST failing case; the case"
echo "table at the top of d3d9lock-x86.c maps it back to a name, and that"
echo "case's own line carries the first bad pixel and the miscount."
