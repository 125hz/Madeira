#!/bin/bash
# MADEIRA-TEMP: build the ml952 fastsync stress self-test, sync-x86.exe.
# See build/x86-tests/sync-x86.c for what it asserts and what each exit code
# means, and build/ntdll-unix/shims/ios_fastsync.h for the mechanism under test.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-sync-test.sh
#
# Produces sync-x86.exe (i386 PE) and copies it into app/Madeira/i386-windows/
# so the IPA build picks it up.  The only import must be kernel32; the script
# asserts it, because anything else is load-time work inside a test whose whole
# subject is synchronisation timing.
set -e

NAME=sync-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# Same flag set and the same reasons as build-unixcall-bench.sh:
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
echo "Expected log: MADEIRA-SYNC lines ending in \"all checks passed\", then"
echo "  MADEIRA-EXIT: sync-x86.exe status=46"
echo "Any other status is a fastsync defect; sync-x86.c lists what each means."
echo ""
echo "ml982: the DEFAULT is now cells + the read-only zero-timeout answer, with"
echo "the client WAKE path still off, so a default run exercises the server path"
echo "plus MADEIRA_FS_POLLPEEK.  Three configurations, all of which must end in"
echo "status=46, via Documents/madeira-env.txt:"
echo "  (nothing)                 default: server path + poll peek"
echo "  MADEIRA_FASTSYNC=0        pre-ml952 server path, peek off as well"
echo "  MADEIRA_FASTSYNC=1        the full in-process wake path"
echo "MADEIRA_FASTSYNC=auto arms the wake path only once the process is busy;"
echo "this test is busy enough to arm it after its first 10 s window."
