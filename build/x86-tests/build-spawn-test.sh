#!/bin/bash
# MADEIRA-TEMP: build the 32-bit spawn-chain self-test, spawn-x86.exe.
# See build/x86-tests/spawn-x86.c for what it proves and what each exit code
# means, and WOW64_DESIGN.md section 2 / the [wow-window] and [cage] log lines
# for the mechanism under test (one 4 GB guest window per live 32-bit
# pseudo-process).
#
# Kept separate from build.sh and from the other per-test scripts here, the same
# way those are kept separate from each other: this stage only adds files.
#
# Usage: ./build-spawn-test.sh
#
# Produces spawn-x86.exe (i386 PE) and copies it into app/Madeira/i386-windows/
# so the IPA build picks it up.  The only import must be kernel32; the script
# asserts it, because a test about process creation must not be able to fail in
# some unrelated DLL's load.
set -e

NAME=spawn-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# Same flag set and the same reasons as build-sync-test.sh:
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
    echo "FAILED: the test must import only kernel32."
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
echo "Expected log:"
echo "  MADEIRA-SPAWN depth=0..3 lines, four live pseudo-processes,"
echo "  [wow-window] slot 0 B=0x7100000000 adopted by pid ...,"
echo "  [cage] CARVED guest-window slot 1 B=0x7200000000 ... + slot 1 adopted,"
echo "  MADEIRA-EXIT: spawn-x86.exe status=49"
echo "Any other status is a defect; spawn-x86.c lists what each code means."
echo "Note the address space holds exactly TWO 4GB-aligned slots, so depths 2"
echo "and 3 can only start once the levels below them have exited -- the chain"
echo "as written keeps all four alive, so a run that reports 61 with"
echo "[wow-window] REJECTED on every slot is the EXPECTED result until a third"
echo "slot exists.  Reduce MAX_DEPTH in spawn-x86.c to 1 to test just the"
echo "two-concurrent-window case."
