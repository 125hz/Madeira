#!/bin/bash
# MADEIRA-TEMP: build the DirectDraw (NO3D) self-test, ddraw-x86.exe.
# See build/x86-tests/ddraw-x86.c for what it asserts and what each exit code
# means.
#
# Subject under test:
#   wine/dlls/wined3d/directx.c   wined3d_init's gl -> no3d fallback, the no3d
#       adapter's gpu_description (the identity ddraw reports), and
#       adapter_no3d_get_wined3d_caps (the 2D DDCAPS)
#   wine/dlls/ddraw/*             the DirectDraw7 object built on top of it
#   build/win32u-unix/sysparams_ios.c   the virtual monitor the mode list and
#       SetDisplayMode reach
#
# There is no OpenGL and no Vulkan on this port, so this is the only path by
# which a DirectDraw title can work at all, and "ddraw7_Initialize was reached"
# in a device log does not distinguish a healthy 2D DirectDraw from one that
# answers every query with zeroes.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-ddraw-test.sh
#
# Produces ddraw-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Imports must be
# exactly kernel32 + user32 + ddraw, all Wine-supplied; the script asserts it.
set -e

NAME=ddraw-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/ddraw) ==="
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
#
# -ldxguid supplies IID_IDirectDraw7. It is a static import library, not a
# DLL, so it adds no runtime import -- the assertion below still expects only
# kernel32/user32/ddraw.
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32 -luser32 -lddraw -ldxguid

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
        kernel32.dll|user32.dll|ddraw.dll) ;;
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
echo "Run it from the Custom popup as  C:\\windows\\syswow64\\ddraw-x86.exe"
echo "Expected log: MADEIRA-DDRAW lines, every required one marked [ok  ], then"
echo "  MADEIRA-EXIT: ddraw-x86.exe status=57"
echo "Any other status is a defect; ddraw-x86.c lists what each means."
echo "The run is also expected to print, once, from wined3d:"
echo "  err:d3d:wined3d_caps_gl_ctx_create Failed to find a suitable pixel format."
echo "  err:winediag: Disabling 3D support: no OpenGL or Vulkan adapter is available."
echo "That pair is the fallback working, not a defect -- the pixel-format error"
echo "appearing WITHOUT the winediag line after it would be the defect."
echo "Compare MADEIRA-DDRAW dwVendorId/dwDeviceId against d3d9caps-x86.exe's"
echo "MADEIRA-D3D9CAPS VendorId/DeviceId: the two must report the same adapter."
echo ""
echo "App-side wiring still required (owned by the app track, not this stage):"
echo "  ContentView.swift  ->  add a 'ddraw-x86' entry so the test gets its own"
echo "  launch button below the live view, the same way '32-bit hello' does."
