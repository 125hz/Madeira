#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
SRC="$ROOT/FEX"
BUILD="$SRC/build-ios"
OUT="$BUILD/FEXCore/Source/libFEXCore.a"


# Options mirror build/fex-ios/build.sh. Do not define FEX_IOS_HOST here: in
# this FEX fork it selects the code for FEX running as a Windows PE under Wine
# on iOS (xtajit.dll, xtajit64.dll), which calls Win32 APIs and symbols that
# only those modules define. The native library the app links uses __APPLE__.

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DBUILD_STEAM_SUPPORT=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_ASSERTIONS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_CCACHE=OFF \
  -DTUNE_CPU=generic \
  -DTUNE_ARCH=generic

# The Xcode project links these archives from FEX/build-ios.
cmake --build "$BUILD" --target FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit softfloat_3e xxhash --parallel "$JOBS"
for lib in "$OUT" "$BUILD/FEXCore/Source/libJemallocLibs.a"; do
  [[ -f "$lib" ]] || { echo "ERROR: FEX build did not produce $lib" >&2; exit 1; }
done
