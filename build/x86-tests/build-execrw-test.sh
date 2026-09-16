#!/bin/bash
# MADEIRA-TEMP: build the DEP-policy self-test, execrw-x86.exe and execrw-nx-x86.exe.
#
# See build/x86-tests/execrw-x86.c for what each phase asserts and what each exit code
# means, and WOW64_DESIGN.md section 6 for the mechanism under test (the [dep-off]
# promotion in FEX's InvalidationTracker, reached through
# NtSetInformationProcess(ProcessExecuteFlags) -> wow64.dll ->
# BTCpuNotifyProcessExecuteFlagsChange).
#
# TWO IMAGES FROM ONE SOURCE.  The whole subject of the test is a bit in the PE optional
# header, IMAGE_DLLCHARACTERISTICS_NX_COMPAT, so the only way to test both halves is to
# link the same object twice with opposite linker flags:
#
#   execrw-x86.exe     --disable-nxcompat : DEP off.  Writable memory must be executable.
#   execrw-nx-x86.exe  --nxcompat         : DEP on.   The same call must raise an execute
#                                           access violation.
#
# The program reads its own header at run time and asserts the mode it was built for, so a
# linker that silently ignored one of these flags is caught here rather than producing a
# green run that tested nothing — which is why the script also checks the bit directly.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the other
# per-test scripts here, the same way those are kept separate from each other: this stage
# only adds files.
#
# Usage: ./build-execrw-test.sh
set -e

SRC=execrw-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"
READOBJ="$TOOLCHAIN/llvm-readobj"

cd "$SCRIPT_DIR"

# $1 = output name, $2 = the nxcompat linker flag
build_one() {
    local name=$1 nxflag=$2

    echo ""
    echo "=== building $name.exe (i386 PE, no CRT -- kernel32 only, $nxflag) ==="
    # Same flag set and the same reasons as build-sync-test.sh:
    # -nostdlib because the file supplies `start` and its own memset/memcpy, and
    # --large-address-aware because the guest window is a full 4 GB and the image
    # must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
    "$CC" -O1 -g -nostdlib -ffreestanding \
        -static-libgcc -Wno-unused-command-line-argument \
        -Wl,--entry=_start \
        -Wl,--large-address-aware \
        -Wl,"$nxflag" \
        -o "$name.exe" "$SRC.c" \
        -lkernel32

    ls -la "$name.exe"

    echo ""
    echo "=== machine type (file format) ==="
    "$OBJDUMP" -f "$name.exe"

    echo ""
    echo "=== asserting the import set is kernel32 only ==="
    local imports unexpected=0 dll
    imports=$("$OBJDUMP" -p "$name.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
    echo "$imports"
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
    if "$OBJDUMP" -p "$name.exe" | grep -q "LARGE_ADDRESS_AWARE"; then
        echo "LARGE_ADDRESS_AWARE present"
    elif "$READOBJ" --file-headers "$name.exe" | grep -q "IMAGE_FILE_LARGE_ADDRESS_AWARE"; then
        echo "LARGE_ADDRESS_AWARE present (readobj)"
    else
        echo "FAILED: LARGE_ADDRESS_AWARE not set."
        exit 1
    fi

    echo ""
    echo "=== copying $name.exe to app bundle ($APP_BUNDLE) ==="
    mkdir -p "$APP_BUNDLE"
    cp "$name.exe" "$APP_BUNDLE/$name.exe"
    ls -la "$APP_BUNDLE/$name.exe"
}

build_one execrw-x86    --disable-nxcompat
build_one execrw-nx-x86 --nxcompat

# ------------------------------------------------------------------ the bit itself
#
# This is the assertion the whole test rests on.  DllCharacteristics is at offset 0x46 of
# the 32-bit optional header, IMAGE_DLLCHARACTERISTICS_NX_COMPAT is 0x0100, and llvm-readobj
# names it NX_COMPAT in its DllCharacteristics list.  If a future toolchain quietly stops
# honouring --disable-nxcompat, both images would test the DEP-ON half and always pass; that
# silent failure is exactly what this check exists to prevent.
echo ""
echo "=== asserting the two images differ in IMAGE_DLLCHARACTERISTICS_NX_COMPAT ==="
nx_off=$("$READOBJ" --file-headers execrw-x86.exe    | grep -c "NX_COMPAT" || true)
nx_on=$( "$READOBJ" --file-headers execrw-nx-x86.exe | grep -c "NX_COMPAT" || true)
echo "execrw-x86.exe    NX_COMPAT occurrences: $nx_off (want 0)"
echo "execrw-nx-x86.exe NX_COMPAT occurrences: $nx_on  (want >= 1)"
if [ "$nx_off" != 0 ]; then
    echo "FAILED: execrw-x86.exe still declares NX_COMPAT -- --disable-nxcompat had no effect,"
    echo "        so the DEP-OFF half of the test would never run."
    exit 1
fi
if [ "$nx_on" = 0 ]; then
    echo "FAILED: execrw-nx-x86.exe does not declare NX_COMPAT -- --nxcompat had no effect,"
    echo "        so the DEP-ON half of the test would never run."
    exit 1
fi

echo ""
echo "Done."
echo "Expected log, execrw-x86.exe (DEP off):"
echo "  MADEIRA-EXECRW: image has no NX_COMPAT ..."
echo "  MADEIRA-EXECRW: phase 1..5 OK, then \"all checks passed\""
echo "  MADEIRA-EXIT: execrw-x86.exe status=52"
echo "Expected log, execrw-nx-x86.exe (DEP on):"
echo "  MADEIRA-EXECRW: image declares NX_COMPAT ..."
echo "  MADEIRA-EXECRW: phase 1 OK -- DEP on, execute access violation raised at the target"
echo "  MADEIRA-EXIT: execrw-nx-x86.exe status=52"
echo "Any other status is a DEP-policy defect; execrw-x86.c lists what each one means."
echo "The emulator side should also print one \"[dep-off] promoting ...\" line per promoted"
echo "region and a periodic \"[dep-off] summary:\" line in the DEP-off run, and neither in"
echo "the NX_COMPAT run."
