#!/bin/bash
# MADEIRA-TEMP: build the large-address-aware-by-default self-test, laa-x86.exe.
#
# See build/x86-tests/laa-x86.c for what it asserts and what each exit code
# means, and build/ntdll-unix/virtual_ios.c (ios_laa_forced,
# ios_wow_ceiling_for_charact, and the [laa] header patch in virtual_map_image)
# for the mechanism under test.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-laa-test.sh
#
# Produces laa-x86.exe (i386 PE) and copies it into app/Madeira/i386-windows/
# so the IPA build picks it up.
#
# THE ONE DIFFERENCE FROM EVERY OTHER SCRIPT HERE: this image must NOT be linked
# --large-address-aware, and the assertion below is that the bit is ABSENT.  The
# test's whole subject is what the port does with an image that lacks it, so an
# image carrying the bit would pass trivially and prove nothing.
set -e

NAME=laa-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only, NOT large-address-aware) ==="
# Same flag set as build-readvm-test.sh MINUS --large-address-aware.  lld-link
# does not accept a --disable- form of the flag, so the bit's absence is not
# asserted by a linker option but by the readobj check further down, which is
# the check that actually matters.
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
echo "=== asserting the large-address-aware bit is ABSENT (inverted on purpose) ==="
if "$OBJDUMP" -p "$NAME.exe" | grep -q "LARGE_ADDRESS_AWARE"; then
    echo "FAILED: LARGE_ADDRESS_AWARE is set; this test must not carry it."
    exit 1
fi
if "$TOOLCHAIN/llvm-readobj" --file-headers "$NAME.exe" | grep -q "IMAGE_FILE_LARGE_ADDRESS_AWARE"; then
    echo "FAILED: LARGE_ADDRESS_AWARE is set (readobj); this test must not carry it."
    exit 1
fi
echo "LARGE_ADDRESS_AWARE absent, as required"

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run from the app's Custom popup as C:\\windows\\syswow64\\laa-x86.exe"
echo "Expected log with the policy on (the default):"
echo "  [laa] 32-bit image is not large-address-aware; user space raised to 4 GB (MADEIRA_LAA=0 keeps 2 GB)"
echo "  [laa] main image header at 0x... patched: characteristics now 012e ..."
echo "  MADEIRA-LAA: reserved >=2600 MB highest=0x... (highest must be >= 0x80000000)"
echo "  MADEIRA-EXIT: laa-x86.exe status=60"
echo "With MADEIRA_LAA=0 in Documents/madeira-env.txt the same binary must report"
echo "  under 2048 MB and exit 61 -- that is how the knob itself is verified."
