#!/bin/bash
# Build the native Vulkan backend and Wine Unix thunk table, then merge MoltenVK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/build/vulkan-ios"
MVK="$ROOT/toolchains/moltenvk/MoltenVK"
OBJ="$HERE/obj"
LIB="${MADEIRA_MOLTENVK_LIBRARY:-$MVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a}"
[ -f "$LIB" ] || { echo "Missing pinned MoltenVK: run bash build/vulkan-ios/fetch.sh" >&2; exit 1; }
[ -f "$MVK/include/vulkan/vulkan.h" ] || { echo "Missing pinned Vulkan headers" >&2; exit 1; }
mkdir -p "$OBJ"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
COMMON=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2 -fPIC -fvisibility=hidden)
xcrun --sdk iphoneos clang "${COMMON[@]}" -Wall -Wextra -Werror \
    -I"$MVK/include" -c "$HERE/backend.c" -o "$OBJ/backend.o"
libtool -static -o "$ROOT/app/Madeira/libmadeira_vulkan.a" \
    "$OBJ/backend.o" "$LIB"
mkdir -p "$ROOT/app/Madeira/legal"
cp "$ROOT/toolchains/moltenvk/LICENSE" "$ROOT/app/Madeira/legal/LICENSE-MoltenVK.txt"
echo "Built $ROOT/app/Madeira/libmadeira_vulkan.a"
