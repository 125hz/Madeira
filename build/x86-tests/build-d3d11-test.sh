#!/bin/bash
# MADEIRA-TEMP: build the i386 Direct3D 11 acceptance test, d3d11-x86.exe.
# See WOW64_DESIGN.md section 6 (2026-09-19 entry) and section 7.
#
# Kept separate from build.sh on purpose: build.sh is owned by the 32-bit
# bring-up track (hello-x86 / window-x86) and this stage only adds files.
#
# Usage: ./build-d3d11-test.sh
#
# Produces d3d11-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + d3d11 + dxgi; the script asserts it.  d3d11.dll
# and dxgi.dll there are DXMT's Metal-backed builds (build/dxmt-ios/
# build-pe.sh), NOT Wine's wined3d frontends -- that is the whole point of
# the test.
set -e

NAME=d3d11-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/d3d11/dxgi) ==="
# -nostdlib: the file supplies `start` and its own memset/memcpy, so nothing
#   pulls in ucrtbase/msvcrt.  No dxguid either: the one IID the test needs is
#   spelled out in the source.
# --large-address-aware: the guest window is a full 4 GB, so the image must
#   not be restricted to the low 2 GB (WOW64_DESIGN.md section 6, the
#   ios_wow_image_ceiling() LAA derivation reads exactly this bit).  It also
#   matters here for its own sake: a mapped GPU buffer may land anywhere in
#   the window, and a test that could not address the top half would report a
#   perfectly good pointer as a failure.
"$CC" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -luser32 -ld3d11 -ldxgi

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== imports ==="
"$OBJDUMP" -p "$NAME.exe" | grep "DLL Name" || true

echo ""
echo "=== asserting the import set ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        kernel32.dll|user32.dll|d3d11.dll|dxgi.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: the test must import only kernel32/user32/d3d11/dxgi."
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
echo "=== asserting the installed d3d11/dxgi are DXMT's, not wined3d's ==="
for m in d3d11.dll dxgi.dll d3d10core.dll; do
    if [ ! -f "$APP_BUNDLE/$m" ]; then
        echo "MISSING: $APP_BUNDLE/$m -- run build/dxmt-ios/build-pe.sh i386 first"
        exit 1
    fi
    # Wine's builds import wined3d.dll; DXMT's import winemetal.dll.
    deps=$("$OBJDUMP" -p "$APP_BUNDLE/$m" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
    case "$deps" in
        *wined3d*) echo "FAILED: $m is still Wine's wined3d frontend ($deps)"; exit 1 ;;
    esac
    echo "  $m: $deps"
done

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run it from the app's Custom popup as C:\\windows\\syswow64\\d3d11-x86.exe"
echo "Expected: MADEIRA-D3D11 lines, then MADEIRA-EXIT: d3d11-x86.exe status=66"
echo "  67 = device creation failed (HRESULT printed)"
echo "  68 = Map returned an unreachable pointer"
echo "  69 = readback mismatch"
