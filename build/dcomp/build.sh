#!/bin/bash
# Build dcomp.dll (ARM64EC) from dcomp.c / dcomp.def and install it into the
# app's DLL farm (app/Madeira/arm64ec-windows, or $DEST) in place of Wine's
# stub, whose DCompositionCreateDevice answers E_NOTIMPL. dcomp.c says what
# it does instead. The exports are checked against dcomp.def before anything
# is installed. Requires the llvm-mingw toolchain (docs/BUILDING.md). Like
# faultrep.dll, its install goes into the tracked farm.
set -eu
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="$REPO_ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
OUT="${OUT:-$DIR/out}"
DEST="${DEST:-$REPO_ROOT/app/Madeira/arm64ec-windows}"
mkdir -p "$OUT"

"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -Wall \
    -o "$OUT/dcomp.dll" "$DIR/dcomp.c" "$DIR/dcomp.def"

want=$(awk 'f && NF { print $1 } /^EXPORTS/ { f = 1 }' "$DIR/dcomp.def" | sort)
have=$("$MINGW/llvm-readobj" --coff-exports "$OUT/dcomp.dll" | awk '$1 == "Name:" { print $2 }' | sort)
if [ "$want" != "$have" ]; then
    echo "dcomp.dll: the exports do not match dcomp.def" >&2
    diff <(echo "$want") <(echo "$have") >&2 || true
    exit 1
fi

mkdir -p "$DEST"
cp "$OUT/dcomp.dll" "$DEST/dcomp.dll"
echo "dcomp.dll: $(wc -c < "$OUT/dcomp.dll" | tr -d ' ') bytes, $(echo "$have" | wc -l | tr -d ' ') exports -> $DEST"
