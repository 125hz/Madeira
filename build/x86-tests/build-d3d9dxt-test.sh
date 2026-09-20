#!/bin/bash
# MADEIRA-TEMP: build the D3D9 block-compressed-texture self-test,
# d3d9dxt-x86.exe.  See build/x86-tests/d3d9dxt-x86.c for what it asserts and
# what each exit code means.
#
# Subject under test:
#   research/dxmt/src/d3d9/d3d9_device.cpp  MTLD3D9Device::stageTextureUpload --
#       the single CPU->GPU texel funnel, and its BC-decode arm for adapters
#       that cannot sample BC
#   research/dxmt/src/dxmt/dxmt_bcn.hpp     the shared block decoders, which
#       build/dxmt-tests/build-bcn-host-test.sh pins on the build machine; this
#       is the same arithmetic reached through the real D3D9 surface
#   research/dxmt/src/d3d9/d3d9_interface.cpp  CheckDeviceFormat's DXT answers
#
# The host test proves the decoder; this proves the PLUMBING around it -- the
# lock pitch, the block offset, the upload layout, the sampler swizzle and the
# readback -- which the host test cannot reach and a screenshot cannot separate.
#
# Kept separate from build.sh and from the other per-test scripts here, the
# same way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-d3d9dxt-test.sh
#
# Produces d3d9dxt-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + d3d9, all Wine-supplied; the script asserts it.
set -e

NAME=d3d9dxt-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/d3d9) ==="
# Same flag set and the same reasons as build-d3d9caps-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -luser32 -ld3d9

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
        kernel32.dll|user32.dll|d3d9.dll) ;;
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
echo "Run it from the Custom popup as  C:\\windows\\syswow64\\d3d9dxt-x86.exe"
echo "Expected log: MADEIRA-D3D9DXT lines for four cases, then"
echo "  MADEIRA-D3D9DXT: <n> checks, 0 failures -- PASS"
echo "  MADEIRA-EXIT: d3d9dxt-x86.exe status=57"
echo "Status 60 means at least one decoded texel was wrong; every failing"
echo "check prints its own got/want line naming the BC rule that broke."
echo "Status 58 means a DXT format is no longer advertised by CheckDeviceFormat."
echo "On an adapter WITH BC support the same PASS is expected -- the decode"
echo "arm is not taken there, so this doubles as the no-regression check."
