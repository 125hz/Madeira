#!/bin/bash
# MADEIRA-TEMP: build the section-8.4 unix-call benchmark, unixcall-bench-x86.exe.
# See WOW64_DESIGN.md section 8.4 ("Cost of one unix call -- MEASURE FIRST").
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from
# build-d3d9-cube.sh (the milestone-4 acceptance test), the same way those two
# are kept separate from each other: this stage only adds files.
#
# Usage: ./build-unixcall-bench.sh
#
# Produces unixcall-bench-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  The only import must
# be kernel32 -- winemetal.dll is reached with LoadLibraryA/GetProcAddress,
# because llvm-mingw ships no import library for it; the script asserts it.
set -e

NAME=unixcall-bench-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# Same flag set as build-d3d9-cube.sh, and for the same reasons: -nostdlib
# because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
#
# -O1 rather than -O2 on purpose: at -O2 clang is entitled to notice that the
# in-process reference loop's callee is pure and hoist the whole loop, which
# would report a benchmark result for a loop that never ran.  The callee is
# already __attribute__((noinline)) and the sink is volatile; -O1 is the belt
# to that pair's braces, and none of the three timed loops contains anything
# the optimiser could usefully speed up anyway.
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
echo "=== imports ==="
"$OBJDUMP" -p "$NAME.exe" | grep "DLL Name" || true

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
    echo "FAILED: the benchmark must import only kernel32 -- anything else is"
    echo "        load-time work that would be attributed to the measurement."
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
echo "=== checking the installed winemetal.dll exports WMTNop (slot 150) ==="
# Not fatal: the DLL is built by a different stage (build/dxmt-ios/build-pe.sh)
# and this script must still be runnable before that stage has been re-run.
# The exe reports it at runtime as status=46 either way.
if [ -f "$APP_BUNDLE/winemetal.dll" ]; then
    if "$TOOLCHAIN/llvm-objdump" -p "$APP_BUNDLE/winemetal.dll" | grep -q "WMTNop"; then
        echo "WMTNop present in app/Madeira/i386-windows/winemetal.dll"
    else
        echo "WARNING: the installed i386 winemetal.dll has no WMTNop export."
        echo "         Run: wsl bash .xtool/build-dxmt.sh   (or build/dxmt-ios/build-pe.sh i386)"
    fi
else
    echo "note: app/Madeira/i386-windows/winemetal.dll not present yet."
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Expected log: MADEIRA-BENCH lines, the headline being"
echo "  MADEIRA-BENCH: unix-call ns/call = N"
echo "then MADEIRA-EXIT: unixcall-bench-x86.exe status=44"
