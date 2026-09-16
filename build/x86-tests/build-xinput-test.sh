#!/bin/bash
# MADEIRA-TEMP: build the XInput transport self-test, xinput-x86.exe.
#
# See build/x86-tests/xinput-x86.c for what it proves and what each exit code
# means, and for the list of stages the sample crosses between a paired
# controller and this program.
#
# Kept separate from build.sh and from the other per-test scripts here, the same
# way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-xinput-test.sh
#
# Produces xinput-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  The import set must
# be kernel32 ONLY -- xinput1_3.dll is reached with LoadLibrary, deliberately:
# a static import would make the test fail at LOAD time with nothing in the log
# but "dll not found", which says nothing about the transport.  A runtime load
# distinguishes "the DLL is not in the farm" from "the DLL is there and its
# XInputGetState says no pad".
set -e

NAME=xinput-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# Same flag set and the same reasons as build-dispmode-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -lkernel32

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== asserting the import set is kernel32 only ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        kernel32.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: the test must import only kernel32; xinput1_3 is LoadLibrary'd."
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
echo "=== checking xinput1_3.dll is actually in the i386 farm ==="
if [ -f "$APP_BUNDLE/xinput1_3.dll" ]; then
    ls -la "$APP_BUNDLE/xinput1_3.dll"
else
    echo "WARNING: $APP_BUNDLE/xinput1_3.dll is missing -- the test will exit 61."
    echo "  Build it with .xtool/build-wine-i386.sh (xinput1_3 is in EXTRA_DLLS)."
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run it with a controller paired to the phone, then move a stick."
echo "Expected log:"
echo "  MADEIRA-XINPUT: pad 0 connected"
echo "  MADEIRA-XINPUT: packet=N buttons=0x.... lx=... ly=... lt=... rt=..."
echo "  MADEIRA-XINPUT: packet changed - transport works"
echo "  MADEIRA-EXIT: xinput-x86.exe status=53"
echo "Status 63 means the fifteen seconds ran out; the line above it says"
echo "whether the pad was connected at all.  Pair it with the app-side lines:"
echo "  [xinput] pad0 connected vendor=... profile=extended"
echo "  [xinput] pad0 packets=N last_buttons=0x.... lx=... ly=...   (every 10s)"
echo "  [winios] gamepad slot 0 connected"
