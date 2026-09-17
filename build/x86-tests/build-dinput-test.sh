#!/bin/bash
# MADEIRA-TEMP: build the DirectInput joystick self-test, dinput-x86.exe.
#
# See build/x86-tests/dinput-x86.c for what it proves and what each exit code
# means. In short: xinput-x86.exe proves the controller reaches a Windows
# process; this one proves it reaches IDirectInput8::EnumDevices, which is the
# only way most pre-2010 games ever ask for a pad.
#
# Kept separate from build.sh and from the other per-test scripts here, the same
# way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-dinput-test.sh
#
# Produces dinput-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.
#
# THE IMPORT SET IS STATIC HERE, unlike xinput-x86.exe which LoadLibrary's
# xinput1_3.dll. The reason is the opposite of that one's: DirectInput8Create
# is reached through an import library either way, and the interesting failure
# is not "is dinput8.dll present" (it has been in the farm for a long time) but
# "does its EnumDevices return anything". A missing dinput8.dll would show up
# as a loader error naming it, which is unambiguous enough.
#   dxguid and dinput8's own libdinput8.a supply IID_IDirectInput8W and
# c_dfDIJoystick2 as STATIC data, so neither adds a DLL to the import set.
set -e

NAME=dinput-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT) ==="
# Same flag set and the same reasons as build-xinput-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -ldinput8 -ldxguid -lole32 -luser32 -lkernel32

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== asserting the import set ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        dinput8.dll|ole32.dll|user32.dll|kernel32.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: expected dinput8 + ole32 + user32 + kernel32 only."
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
echo "=== checking dinput8.dll/dinput.dll are actually in the i386 farm ==="
for dll in dinput8.dll dinput.dll; do
    if [ -f "$APP_BUNDLE/$dll" ]; then
        ls -la "$APP_BUNDLE/$dll"
    else
        echo "WARNING: $APP_BUNDLE/$dll is missing -- the test cannot load."
        echo "  Build it with .xtool/build-wine-i386.sh."
    fi
done

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run it with a controller paired to the phone, then move a stick."
echo "Expected log:"
echo "  MADEIRA-DINPUT: device 0 type=0x00000215 instance=\"Gamepad\" product=\"Madeira Gamepad\""
echo "    (0x15 = DI8DEVTYPE_GAMEPAD, 0x02 = DI8DEVTYPEGAMEPAD_STANDARD in the"
echo "     high byte; no DIDEVTYPE_HID bit, because it is not a HID device)"
echo "  MADEIRA-DINPUT: EnumDevices hr=0x00000000 devices=1"
echo "  MADEIRA-DINPUT: acquired, initial state:"
echo "  MADEIRA-DINPUT: x=32768 y=32768 z=32768 rx=32768 ry=32768 pov=-1 buttons=0x00000000"
echo "  MADEIRA-DINPUT: REST-CHECK pass (every axis centred, pov -1)"
echo "  MADEIRA-DINPUT: state changed - DirectInput path works"
echo "  MADEIRA-EXIT: dinput-x86.exe status=58"
echo "Status 68 means EnumDevices found nothing; run xinput-x86.exe first to"
echo "tell 'no pad paired' apart from 'dinput does not expose it'."
echo "Status 69 means it enumerated but never moved."
