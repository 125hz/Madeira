#!/bin/bash
# MADEIRA-TEMP: build the audio self-test, audio-x86.exe.
#
# See build/x86-tests/audio-x86.c for what it proves and what each exit code
# means.  Three paths in one program -- IAudioClient, DirectSound, waveOut --
# because they share one unix driver and nothing else, so "no sound" needs the
# log to say which of the three layers stopped.
#
# Kept separate from build.sh and from the other per-test scripts here, the
# same way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-audio-test.sh
#
# Produces audio-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  Unlike the input
# tests, mmdevapi is NOT LoadLibrary'd: it is reached the way a real program
# reaches it, through CoCreateInstance(CLSID_MMDeviceEnumerator), so the
# import set is ole32/dsound/winmm/user32/kernel32 and the COM registration in
# the prefix is part of what gets tested.
set -e

NAME=audio-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT) ==="
# Same flag set and the same reasons as build-dinput-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
# -luuid supplies CLSID_MMDeviceEnumerator/IID_IAudioClient as data; -ldxguid
# is not needed because no DirectX GUID is referenced by name.
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -ldsound -lwinmm -lole32 -luuid -luser32 -lkernel32

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
        kernel32.dll|user32.dll|ole32.dll|dsound.dll|winmm.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: mmdevapi must be reached through COM, not as a static import."
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
echo "=== checking the DLLs it needs are in the i386 farm ==="
missing=0
for dll in mmdevapi.dll dsound.dll winmm.dll ole32.dll; do
    if [ -f "$APP_BUNDLE/$dll" ]; then
        ls -la "$APP_BUNDLE/$dll"
    else
        echo "WARNING: $APP_BUNDLE/$dll is missing."
        missing=1
    fi
done
if [ "$missing" != 0 ]; then
    echo "  Build them with .xtool/build-wine-i386.sh <module>."
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done. Run it from the Custom path popup as:"
echo "  C:\\windows\\syswow64\\audio-x86.exe"
echo "Expected log:"
echo "  MADEIRA-AUDIO: (a) WASAPI OK"
echo "  MADEIRA-AUDIO: (a2) 5.1 downmix OK"
echo "  MADEIRA-AUDIO: (b) DirectSound OK"
echo "  MADEIRA-AUDIO: (c) waveOut OK"
echo "  MADEIRA-EXIT: audio-x86.exe status=59"
echo "60/61/62 name the path that failed; 63 means five seconds ran out, which"
echo "is what a spinning mmdevapi notify thread looks like from here."
