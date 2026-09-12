#!/bin/bash
# Build a tiny i386 PE for testing Madeira's WoW64 path on iOS.
# See WOW64_DESIGN.md section 5 (milestone 1) and build/x64-tests/build.sh,
# which this mirrors for the 32-bit side.
#
# Usage: ./build.sh hello-x86       (kernel32-only, no CRT -- milestone 1)
#        ./build.sh hello-x86-crt   (printf via default mingw CRT -- milestone 2)
#        ./build.sh window-x86      (kernel32/user32/gdi32, no CRT -- milestone 2)
set -e

NAME="${1:-hello-x86}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

if [[ "$NAME" == "hello-x86" ]]; then
    echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
    "$CC" -O2 -g -nostdlib -Wl,--entry=_start -o "$NAME.exe" "$NAME.c" -lkernel32
elif [[ "$NAME" == "window-x86" ]]; then
    echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32/user32/gdi32) ==="
    "$CC" -O2 -g -nostdlib -Wl,--entry=_start -o "$NAME.exe" "$NAME.c" \
        -lkernel32 -luser32 -lgdi32
else
    echo "=== building $NAME.exe (i386 PE, default mingw CRT) ==="
    "$CC" -O2 -g -o "$NAME.exe" "$NAME.c"
fi

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== imports ==="
"$OBJDUMP" -p "$NAME.exe" | grep -A2 "DLL Name" || true

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done. Reminder: WineProcessBridge.m's bundle-subdir heuristic (aarch64-windows"
echo "vs arm64ec-windows, keyed off the exe name/MADEIRA_EXE) does not yet know about"
echo "i386-windows/32-bit guests -- that app-side wiring is a separate change,"
echo "described in the stage-A report rather than made here."
