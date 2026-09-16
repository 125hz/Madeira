#!/bin/bash
# MADEIRA-TEMP: build the D3D9 adapter mode-table self-test, d3d9modes-x86.exe.
# See build/x86-tests/d3d9modes-x86.c for what it asserts and what each exit
# code means.
#
# Subject under test, in two halves that have to agree:
#   research/dxmt/src/d3d9/d3d9_interface.cpp   adapterModes(), the
#       GetAdapterModeCount / EnumAdapterModes / GetAdapterDisplayMode /
#       CheckDeviceType / CreateDevice chain, and the [d3d9-modes] trace
#   research/dxmt/src/util/wsi_monitor_*.cpp    where that list comes from
#   build/win32u-unix/sysparams_ios.c           the virtual monitor itself
#
# dispmode-x86.exe covers the win32u half on its own; this one covers the D3D9
# half and the two of them agreeing.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-d3d9modes-test.sh
#
# Produces d3d9modes-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + d3d9, all Wine-supplied; the script asserts it.
set -e

NAME=d3d9modes-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/d3d9) ==="
# Same flag set and the same reasons as build-d3d9-cube.sh:
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
echo "Run it from the Custom popup as  C:\\windows\\syswow64\\d3d9modes-x86.exe"
echo "Expected log: MADEIRA-D3D9MODES lines ending in \"PASS\", then"
echo "  MADEIRA-EXIT: d3d9modes-x86.exe status=55"
echo "Any other status is a defect; d3d9modes-x86.c lists what each means."
echo "The run should also print, from the D3D9 frontend:"
echo "  info:  [d3d9-modes] adapter 0 count=N current=WxH@60 | ... (once)"
echo "  info:  [d3d9-modes] CreateDevice 800x600 X8R8G8B8 ... -> hr 0x0"
echo ""
echo "App-side wiring still required (owned by the app track, not this stage):"
echo "  ContentView.swift  ->  add a 'd3d9modes-x86' entry so the test gets its"
echo "  own launch button below the live view, the same way '32-bit hello' does."
