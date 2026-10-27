#!/bin/bash
# GPL-3.0-or-later WITH the Madeira Converter Exception, version 1.
# Optional pinned MoltenVK build with only the direct-cache-export backport.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/build/vulkan-ios"
REV=db66022459ffb663aa2b50f6b018bc2e124f5edf
SRC="${MADEIRA_MOLTENVK_SOURCE:-$ROOT/toolchains/moltenvk-cache-export-source}"
PATCH="$HERE/patches/0001-direct-cache-export.patch"
PLATFORM="${1:-ios}"
case "$PLATFORM" in
    prepare) DESTINATION=''; LABEL='' ;;
    ios) DESTINATION='generic/platform=iOS'; LABEL='iOS' ;;
    macos) DESTINATION='generic/platform=macOS'; LABEL='macOS' ;;
    *) echo "usage: $0 [ios|macos|prepare]" >&2; exit 1 ;;
esac
if [ ! -e "$SRC" ]; then
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch v1.4.2 https://github.com/KhronosGroup/MoltenVK.git "$SRC"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$REV" ] || {
    echo "Expected MoltenVK $REV in a dedicated source checkout: $SRC" >&2; exit 1;
}
# Accept only the original source or the exact one-patch result. Do not silently
# include unrelated experimental MoltenVK policies from a developer's checkout.
FILE=MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/$(dirname "$FILE")"
git -C "$SRC" show "$REV:$FILE" > "$TEMP/$FILE"
patch -s -p1 -d "$TEMP" < "$PATCH"
CHANGED="$(git -C "$SRC" diff --name-only HEAD)"
if [ -z "$CHANGED" ]; then
    git -C "$SRC" apply --check "$PATCH"
    git -C "$SRC" apply "$PATCH"
elif [ "$CHANGED" != "$FILE" ] || ! cmp -s "$TEMP/$FILE" "$SRC/$FILE"; then
    echo "Refusing unrelated source changes; use a clean dedicated MoltenVK checkout" >&2
    exit 1
fi
if [ "$PLATFORM" = prepare ]; then
    echo "Prepared the exact one-patch source: $SRC"
    exit 0
fi
cd "$SRC"
./fetchDependencies --"$PLATFORM" --keep-cache
# Use a clean parent build: an incremental PRELINK_LIBS parent can retain stale
# objects even when its child archive has been rebuilt.
xcodebuild clean build -project MoltenVKPackaging.xcodeproj \
    -scheme "MoltenVK Package ($LABEL only)" -configuration Release \
    -destination "$DESTINATION" -jobs 2 CODE_SIGNING_ALLOWED=NO
if [ "$PLATFORM" = ios ]; then
    LIB="$SRC/Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
    OUT="$ROOT/toolchains/moltenvk-cache-export/ios-arm64"
    [ -f "$LIB" ] || { echo "Missing source-built archive: $LIB" >&2; exit 1; }
    mkdir -p "$OUT"
    cp "$LIB" "$OUT/libMoltenVK.a"
    printf '%s\n' "$REV" > "$OUT/source-revision.txt"
    shasum -a 256 "$PATCH" "$OUT/libMoltenVK.a" > "$OUT/SHA256SUMS"
    echo "Set MADEIRA_MOLTENVK_LIBRARY=$OUT/libMoltenVK.a when rebuilding build/vulkan-ios/build.sh"
fi
