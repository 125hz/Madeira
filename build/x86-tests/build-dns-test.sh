#!/bin/bash
# MADEIRA-TEMP: build the dnsapi self-test, dns-x86.exe.
# See build/x86-tests/dns-x86.c for what it asserts and what each exit code
# means, and build/ntdll-unix/dnsapi_unixlib_ios.c for the unix side it
# exercises.
#
# Kept separate from build.sh (owned by the 32-bit bring-up track) and from the
# other per-test scripts here, the same way those are kept separate from each
# other: this stage only adds files.
#
# Usage: ./build-dns-test.sh
#
# Produces dns-x86.exe (i386 PE) and copies it into app/Madeira/i386-windows/
# so the IPA build picks it up.  The imports must be dnsapi and kernel32 and
# nothing else; the script asserts it, because the subject of the test is a
# unix call made by dnsapi and any other DLL dragged in at load time is another
# unix side that could fail first.
set -e

NAME=dns-x86
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/.xtool/toolchains/llvm-mingw/bin"
APP_BUNDLE="$REPO_ROOT/app/Madeira/i386-windows"
CC="$TOOLCHAIN/i686-w64-mingw32-clang"
OBJDUMP="$TOOLCHAIN/i686-w64-mingw32-objdump"

cd "$SCRIPT_DIR"

echo "=== building $NAME.exe (i386 PE, no CRT -- dnsapi + kernel32 only) ==="
# Same flag set and the same reasons as build-sync-test.sh:
# -nostdlib because the file supplies `start` and its own memset/memcpy, and
# --large-address-aware because the guest window is a full 4 GB and the image
# must not be restricted to the low 2 GB (WOW64_DESIGN.md section 6).
"$CC" -O1 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start \
    -Wl,--large-address-aware \
    -o "$NAME.exe" "$NAME.c" \
    -ldnsapi -lkernel32

ls -la "$NAME.exe"

echo ""
echo "=== machine type (file format) ==="
"$OBJDUMP" -f "$NAME.exe"

echo ""
echo "=== asserting the import set is dnsapi + kernel32 only ==="
imports=$("$OBJDUMP" -p "$NAME.exe" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
echo "$imports"
unexpected=0
for dll in $imports; do
    case "$dll" in
        kernel32.dll|dnsapi.dll) ;;
        *) echo "UNEXPECTED IMPORT: $dll"; unexpected=1 ;;
    esac
done
if [ "$unexpected" != 0 ]; then
    echo "FAILED: the test must import only dnsapi and kernel32."
    exit 1
fi
case "$imports" in
    *dnsapi.dll*) ;;
    *) echo "FAILED: dnsapi.dll is not imported -- the test would not test anything."; exit 1 ;;
esac

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
echo "Run it from the launcher's Custom path popup as"
echo "  C:\\windows\\syswow64\\dns-x86.exe"
echo "Expected log: [unixlib] dnsapi (module ...) -> wow64 table, NO"
echo "  \"err:dnsapi:DllMain No libresolv support\", then MADEIRA-DNS lines and"
echo "  MADEIRA-EXIT: dns-x86.exe status=54"
echo "Any DNS status is a pass -- 9002 (DNS_ERROR_RCODE_SERVER_FAILURE) is the"
echo "expected answer where the sandbox leaves libresolv with no nameservers."
echo "No MADEIRA-EXIT line at all is the original bug: the process died inside"
echo "the unix call."
