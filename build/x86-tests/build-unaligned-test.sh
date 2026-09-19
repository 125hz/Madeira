#!/bin/bash
# MADEIRA-TEMP: build the unaligned-x86 atomics self-test, unaligned-x86.exe.
# See build/x86-tests/unaligned-x86.c for what it asserts and what each exit
# code means, and WOW64_DESIGN.md section 6 (2026-09-19) for the defect it was
# written against.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-unaligned-test.sh
#
# Produces unaligned-x86.exe (i386 PE) and copies it into
# app/Madeira/i386-windows/ so the IPA build picks it up.  The only import must
# be kernel32; the script asserts it, because anything else drags in load-time
# work that could itself fault on an unaligned access and confuse the verdict.
set -e

NAME=unaligned-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- kernel32 only) ==="
# -O1 and not -O2: the point of the file is the exact instruction encodings in
# its inline asm, and the surrounding checks must not be reordered across the
# atomics they verify.  -nostdlib because the file supplies `start` and its own
# memset/memcpy; --large-address-aware because the guest window is a full 4 GB
# (WOW64_DESIGN.md section 6).
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
echo "=== asserting the atomics really are the instructions under test ==="
# A CAS loop emitted in place of `lock xadd`, or a compiler that dropped the
# lock prefix, would leave the test passing while exercising nothing.  Check the
# disassembly for one of each.
# objdump prints the `lock` prefix on a line of its own, so the mnemonics and
# the prefix count are checked separately.
dis=$("$OBJDUMP" -d "$NAME.exe")
missing=0
for insn in xaddl cmpxchgl incl xchgl; do
    if echo "$dis" | grep -qiE "\b$insn\b"; then
        echo "found: $insn"
    else
        echo "MISSING: $insn"
        missing=1
    fi
done
locks=$(echo "$dis" | grep -ciE "^\s*[0-9a-f]+:\s+f0\s+lock\s*$" || true)
echo "lock prefixes: $locks"
if [ "$locks" -lt 4 ]; then
    echo "MISSING: fewer than four lock prefixes -- an atomic was lowered away."
    missing=1
fi
if [ "$missing" != 0 ]; then
    echo "FAILED: an instruction the test claims to exercise is not in the image."
    exit 1
fi

echo ""
echo "=== copying $NAME.exe to app bundle ($APP_BUNDLE) ==="
mkdir -p "$APP_BUNDLE"
cp "$NAME.exe" "$APP_BUNDLE/$NAME.exe"
ls -la "$APP_BUNDLE/$NAME.exe"

echo ""
echo "Done."
echo "Expected log: MADEIRA-UNALIGNED lines ending in \"all checks passed\", then"
echo "  MADEIRA-EXIT: unaligned-x86.exe status=70"
echo "  71 = a wrong result (lost update / wrong operand), 73 = the test's own"
echo "  words came out aligned, 74 = a thread wedged.  NO MADEIRA-EXIT line at"
echo "  all means the unaligned access killed the process -- the original bug."
echo "On the unix side the run should print [unaligned-atomic] site lines and a"
echo "growing ua_emu on [fex-stats], and NO 'Reconstructing context' following a"
echo "DATATYPE_MISALIGNMENT."
