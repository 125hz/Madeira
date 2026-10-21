#!/bin/bash
# Build the native Vulkan backend and Wine Unix thunk table, then merge MoltenVK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/build/vulkan-ios"
MVK="$ROOT/toolchains/moltenvk/MoltenVK"
OBJ="$HERE/obj"
LIB="$MVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
[ -f "$LIB" ] || { echo "Missing pinned MoltenVK: run bash build/vulkan-ios/fetch.sh" >&2; exit 1; }
[ -f "$MVK/include/vulkan/vulkan.h" ] || { echo "Missing pinned Vulkan headers" >&2; exit 1; }
mkdir -p "$OBJ"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
COMMON=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2 -fPIC -fvisibility=hidden)
xcrun --sdk iphoneos clang "${COMMON[@]}" -Wall -Wextra -Werror \
    -I"$MVK/include" -c "$HERE/backend.c" -o "$OBJ/backend.o"
for name in vulkan vulkan_thunks; do
    xcrun --sdk iphoneos clang "${COMMON[@]}" -fno-strict-aliasing -fno-stack-protector \
        -Werror=implicit-function-declaration \
        -include "$ROOT/wine/build-macos/include/config.h" \
        -include "$ROOT/build/ntdll-unix/shims/wine_ios_exit.h" \
        -I"$ROOT/build/ntdll-unix/shims" -I"$ROOT/wine/build-macos/include" \
        -I"$ROOT/wine/include" -I"$ROOT/wine/dlls/winevulkan" \
        -D__WINESRC__ -DWINE_UNIX_LIB -DWINE_IOS=1 -DWINBASEAPI= -D_NTSYSTEM_ \
        -D__wine_unix_call_funcs=madeira_winevulkan_unix_call_funcs \
        -D__wine_unix_call_wow64_funcs=madeira_winevulkan_unix_call_wow64_funcs \
        -c "$ROOT/wine/dlls/winevulkan/$name.c" -o "$OBJ/winevulkan_$name.o"
done
libtool -static -o "$ROOT/app/Madeira/libmadeira_vulkan.a" \
    "$OBJ/backend.o" "$OBJ/winevulkan_vulkan.o" "$OBJ/winevulkan_vulkan_thunks.o" "$LIB"
mkdir -p "$ROOT/app/Madeira/legal"
cp "$ROOT/toolchains/moltenvk/LICENSE" "$ROOT/app/Madeira/legal/LICENSE-MoltenVK.txt"
echo "Built $ROOT/app/Madeira/libmadeira_vulkan.a"
