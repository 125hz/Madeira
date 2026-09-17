#!/bin/bash
# MADEIRA-TEMP: build the D3D9 capability/format self-test, d3d9caps-x86.exe.
# See build/x86-tests/d3d9caps-x86.c for what it asserts and what each exit
# code means.
#
# Subject under test:
#   research/dxmt/src/d3d9/d3d9_interface.cpp   CheckDeviceType,
#       CheckDeviceFormat, CheckDepthStencilMatch, CheckDeviceMultiSampleType,
#       CheckDeviceFormatConversion, GetDeviceCaps, GetAdapterIdentifier, and
#       the [d3d9-caps] trace that prints the same queries from the inside
#   research/dxmt/src/d3d9/d3d9_format.cpp      the format predicates those
#       answers are derived from
#
# d3d9modes-x86.exe covers the mode table and fullscreen create; this covers
# the far larger capability surface a 2000-2010 title gates its renderer on,
# and which nothing else in this directory touches.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-d3d9caps-test.sh
#
# Produces d3d9caps-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + d3d9, both Wine-supplied; the script asserts it.
set -e

NAME=d3d9caps-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/d3d9) ==="
# Same flag set and the same reasons as build-d3d9modes-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -ld3d9

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
echo "Run it from the Custom popup as  C:\\windows\\syswow64\\d3d9caps-x86.exe"
echo "Expected log: MADEIRA-D3D9CAPS lines, every REQUIRED one marked [ok  ],"
echo "then  MADEIRA-EXIT: d3d9caps-x86.exe status=56"
echo "Any other status is a defect; d3d9caps-x86.c lists what each means."
echo "The run should also print, from the D3D9 frontend itself:"
echo "  info:  [d3d9-caps] GetAdapterIdentifier adapter=0 ... vendor=0x106b device=0x0001 ..."
echo "  info:  [d3d9-caps] CheckDeviceFormat ... -> hr 0x0        (one per distinct query)"
echo "  info:  [d3d9-caps] GetDeviceCaps adapter=0 HAL -> hr 0x0  vs=3.0 ps=3.0 ..."
echo "Compare the vendor/device pair against ddraw-x86.exe's MADEIRA-DDRAW"
echo "dwVendorId/dwDeviceId: the two interfaces must report the same adapter."
echo ""
echo "App-side wiring still required (owned by the app track, not this stage):"
echo "  ContentView.swift  ->  add a 'd3d9caps-x86' entry so the test gets its"
echo "  own launch button below the live view, the same way '32-bit hello' does."
