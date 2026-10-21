#!/bin/bash
# Official iOS-only MoltenVK archive, pinned independently of "latest".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=v1.4.2
SHA=b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1
DEST="$ROOT/toolchains/moltenvk"
ARCHIVE="$ROOT/toolchains/MoltenVK-ios-$VERSION.tar"
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 "https://github.com/KhronosGroup/MoltenVK/releases/download/$VERSION/MoltenVK-ios.tar" -o "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA" "$ARCHIVE" | shasum -a 256 -c -
mkdir -p "$DEST"
tar -xf "$ARCHIVE" -C "$DEST" --strip-components=1
echo "MoltenVK $VERSION verified at $DEST"
