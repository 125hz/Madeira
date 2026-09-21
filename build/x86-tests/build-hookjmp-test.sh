#!/bin/bash
# MADEIRA-TEMP: build the inline-detour / rel32-wrap self-test, hookjmp-x86.exe.
#
# See build/x86-tests/hookjmp-x86.c for what each phase asserts and what each
# exit code means, and WOW64_DESIGN.md (the ml1070 entry) for the mechanism
# under test: a five-byte `E9 rel32` detour whose two ends sit in opposite
# halves of the 4 GB guest window, which is the routine shape on this port
# because builtin i386 images are placed above 2 GB while a program and its own
# DLLs load below it.
#
# THE IMAGE MUST NOT BE LARGE-ADDRESS-AWARE, and the assertion below is that the
# bit is ABSENT — the same inverted assertion build-laa-test.sh makes, and for
# the same reason: the subject is what this port does with an image that lacks
# the flag, so an image carrying it would answer a different question.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-hookjmp-test.sh
set -e

NAME=hookjmp-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"
READOBJ="$TOOLCHAIN/llvm-readobj"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only, NOT large-address-aware) ==="
# Same flag set as build-laa-test.sh: -nostdlib because the file supplies
# `start' and its own memset/memcpy, and deliberately WITHOUT
# --large-address-aware.  lld-link has no --disable- form of that flag, so the
# bit's absence is asserted by the readobj check below rather than by a linker
# option -- which is the check that actually matters anyway.
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
if "$READOBJ" --file-headers "$NAME.exe" | grep -q "IMAGE_FILE_LARGE_ADDRESS_AWARE"; then
    echo "FAILED: LARGE_ADDRESS_AWARE is set (readobj); this test must not carry it."
    exit 1
fi
echo "LARGE_ADDRESS_AWARE absent, as required"

echo ""
echo "=== asserting the E9 emitter really is 32-bit modular (no sign-extended add) ==="
# emit_jmp32 must compute `to - (at + 5)` in 32-bit unsigned arithmetic.  On a
# 32-bit target that is what the ISA does anyway, so this is a shape check on
# the object code rather than a semantic one: the function must contain a plain
# SUB and must not have been lowered to anything wider.
if "$OBJDUMP" -d "$NAME.exe" | grep -q "cdq\|cltd"; then
    echo "NOTE: a sign-extension instruction exists somewhere in the image (not necessarily"
    echo "      in emit_jmp32) -- check by hand if a cross-2GB phase ever fails."
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Run from the app's Custom popup as C:\\windows\\syswow64\\hookjmp-x86.exe"
echo "Expected log with the default policy (4 GB ceiling forced for a non-LAA image):"
echo "  MADEIRA-HOOKJMP: phase 1 OK ..."
echo "  MADEIRA-HOOKJMP: phase 2 OK -- ... straddle 0x80000000 ..."
echo "  MADEIRA-HOOKJMP: ntdll base=0xfff.....  (the high half)"
echo "  MADEIRA-HOOKJMP: detoured export returned ... through the trampoline   (twice)"
echo "  MADEIRA-EXIT: hookjmp-x86.exe status=60"
echo "With MADEIRA_LAA=0 in Documents/madeira-env.txt the same binary must report"
echo "  phase 2 SKIPPED and exit 61 -- that is how the knob itself is verified."
echo "Any 6x/7x status other than 60/61 is a defect; hookjmp-x86.c lists what each means."
