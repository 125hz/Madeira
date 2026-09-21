#!/bin/bash
# MADEIRA-TEMP: build the guest virtual-memory churn self-test, vmchurn-x86.exe.
#
# See build/x86-tests/vmchurn-x86.c for what each phase asserts and what each
# exit code means, and WOW64_DESIGN.md (the ml1100 entry, item 2) for why it
# exists: a device session drives ~3,400 guest reserve/commit/release round
# trips a second at 704 KB each, the obvious optimisation is a cache of
# recently released regions, and that optimisation breaks four separate Windows
# guarantees if it is written from the syscall names alone. This file is those
# guarantees as assertions, so the cache has something to be built against.
#
# It is USEFUL BEFORE THE CACHE EXISTS, which is the point of building it now:
# the same binary runs on the Windows host's own WoW64, which is the reference
# implementation of every rule it checks, so a disagreement between the two runs
# is a port bug whether or not anything has been optimised yet. It also prints a
# per-cycle time, so "did the fast path help" has a baseline to be measured
# against rather than a memory of one.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-vmchurn-test.sh
set -e

NAME=vmchurn-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# Same flag set as build-execrw-test.sh: -nostdlib because the file supplies
# `start' and its own memset/memcpy.  No --large-address-aware: this test is
# about allocation semantics and must behave identically whatever the ceiling
# policy does, so it deliberately makes no claim about the high half.
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
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
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run from the app's Custom popup as C:\\windows\\syswow64\\vmchurn-x86.exe"
echo ""
echo "Expected:  MADEIRA-EXIT: ... status=80   — every Windows rule held."
echo "Any other status is a real disagreement with Windows; vmchurn-x86.c's"
echo "header lists what each number means.  62/63 (zero-fill), 65/66 (MEM_FREE"
echo "and faulting) and 67 (explicit-base re-reserve) are specifically the four"
echo "rules a released-region cache is most likely to break, so they are the"
echo "ones to watch after any change to virtual_ios.c's allocation path."
echo ""
echo "The two timing lines are the baseline:"
echo "  MADEIRA-VMCHURN: churn 512 cycles in <N> us"
echo "  MADEIRA-VMCHURN: per cycle <N> ns (reserve+commit, touch every page, release)"
echo "Compare them against the host's own WoW64 run of the same binary, and"
echo "against the [valloc] line's res+commit and release means from the same"
echo "session -- those measure the unix side of the same call, so the difference"
echo "between them is everything above ntdll."
