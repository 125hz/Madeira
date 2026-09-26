#!/bin/bash
# Cross-compile a minimal, LGPL-only FFmpeg as static libraries for iOS arm64.
# Output prefix: toolchains/ffmpeg-ios/ (headers for build/ntdll-unix/build.sh),
# and the four archives copied to app/Madeira/ for the app target's link.
#
# Consumer: winegstreamer's unix side on this port,
# build/ntdll-unix/winegstreamer_unixlib_ios.c (+ wg_parser_av_ios.c), compiled
# into libntdll_unix.a. Upstream Wine implements that unix side with GStreamer,
# which does not exist on iOS.
#
#   - libavcodec: the WMA-family decoders behind the Windows WMA decoder
#     MFT/DMO (wmav1, wmav2, wmapro, wmalossless, xma1, xma2), which FAudio
#     uses for xWMA/XMA voices; MPEG-1 layer I/II/III and plain PCM decoders
#     for the wg_parser.
#   - libavformat: the wg_parser's demuxers -- mp3, wav and mov (MP4/MOV/M4A)
#     -- and the mpegaudio parser the mp3 demuxer selects. No protocols: the
#     parser reads through its own AVIOContext (the PE read thread's pull
#     protocol), never a URL. No muxers.
#   - libswresample, libavutil.
#
# Deliberately NO H.264, HEVC or AAC decoder or parser: those streams are
# decoded by Apple's VideoToolbox / AudioToolbox
# (build/ntdll-unix/wg_parser_apple_ios.c); mov's stsd/avcC/esds and stss
# already carry what a parser would add.
#
# LICENSING (THIRD-PARTY-NOTICES.md): configured --disable-gpl
# --disable-nonfree --disable-version3 and --disable-everything, then only the
# components above, all LGPL-2.1-or-later. Do not add a GPL, version3 or
# nonfree component here. The mov demuxer's optional zlib (compressed moov)
# stays disabled.
#
# --disable-asm: the C paths are enough for these decoders, and it keeps the
# archive identical in behaviour to the one the port was tested with.
#
# The tarball is the unmodified upstream release, fetched from ffmpeg.org into
# build/ffmpeg/src/ (ignored) and checked against the SHA-256 below before
# anything is extracted; a mismatch aborts. No patches are applied.
#
# Re-runnable: the tarball is cached, and configure runs again only when the
# configure arguments change (they are stamped into the build tree) or when
# --reconfigure is passed.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC_DIR="$BUILD_DIR/src"
OBJ_DIR="$BUILD_DIR/obj"
PREFIX="$REPO_ROOT/toolchains/ffmpeg-ios"
APP_DIR="$REPO_ROOT/app/Madeira"

FFMPEG_VERSION=7.1.1
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
TARBALL="$SRC_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
SRC="$OBJ_DIR/ffmpeg-${FFMPEG_VERSION}"
BUILD="$OBJ_DIR/build"

RECONFIGURE=0
for a in "$@"; do
    case "$a" in
        --reconfigure) RECONFIGURE=1 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
JOBS=$(sysctl -n hw.ncpu)

# ------------------------------------------------------------------ fetch
mkdir -p "$SRC_DIR" "$OBJ_DIR"
if [ ! -f "$TARBALL" ]; then
    echo "=== fetching $FFMPEG_URL ==="
    curl -fSL --connect-timeout 20 --retry 2 -o "$TARBALL.part" "$FFMPEG_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
echo "=== verifying sha256 ==="
GOT=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
if [ "$GOT" != "$FFMPEG_SHA256" ]; then
    echo "sha256 mismatch for $TARBALL" >&2
    echo "  expected $FFMPEG_SHA256" >&2
    echo "  got      $GOT" >&2
    exit 1
fi
if [ ! -f "$SRC/configure" ]; then
    echo "=== extracting ffmpeg-$FFMPEG_VERSION ==="
    rm -rf "$SRC"
    tar -C "$OBJ_DIR" -xJf "$TARBALL"
fi

# ------------------------------------------------------------------ configure
HOSTFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0"
CONFIG_ARGS=(
    --prefix="$PREFIX"
    --enable-cross-compile
    --arch=aarch64
    --cpu=generic
    --target-os=darwin
    --sysroot="$SDK"
    --cc="$(xcrun -sdk iphoneos -f clang)"
    --cxx="$(xcrun -sdk iphoneos -f clang++)"
    --ar="$(xcrun -sdk iphoneos -f ar)"
    --ranlib="$(xcrun -sdk iphoneos -f ranlib)"
    --nm="$(xcrun -sdk iphoneos -f nm) -g"
    --strip="$(xcrun -sdk iphoneos -f strip)"
    "--extra-cflags=$HOSTFLAGS -fno-stack-protector -fvisibility=hidden -O2"
    "--extra-ldflags=$HOSTFLAGS"
    --disable-gpl
    --disable-nonfree
    --disable-version3
    --disable-everything
    --enable-decoder=wmav1,wmav2,wmapro,wmalossless,xma1,xma2
    --enable-decoder=mp1,mp2,mp3
    --enable-decoder=pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le
    --enable-demuxer=mp3,wav,mov
    --enable-parser=mpegaudio
    --disable-programs
    --disable-doc
    --disable-network
    --disable-avdevice
    --enable-avformat
    --disable-swscale
    --disable-avfilter
    --disable-postproc
    --enable-avcodec
    --enable-avutil
    --enable-swresample
    --disable-asm
    --disable-shared
    --enable-static
    --enable-pic
    --disable-iconv
    --disable-zlib
    --disable-bzlib
    --disable-lzma
    --disable-sdl2
    --disable-schannel
    --disable-securetransport
    --disable-audiotoolbox
    --disable-videotoolbox
    --disable-coreimage
    --disable-appkit
    --disable-avfoundation
    --disable-metal
    --disable-debug
)

mkdir -p "$BUILD"
STAMP="$BUILD/madeira-configure.args"
WANT_STAMP="$(printf '%s\n' "${CONFIG_ARGS[@]}")"
if [ $RECONFIGURE -eq 0 ] && [ -f "$BUILD/config.h" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT_STAMP" ]; then
    echo "=== configure arguments changed: reconfiguring ==="
    RECONFIGURE=1
fi
if [ $RECONFIGURE -eq 1 ] || [ ! -f "$BUILD/config.h" ]; then
    echo "=== configuring ffmpeg-$FFMPEG_VERSION ==="
    cd "$BUILD"
    # A reconfigure over an old tree keeps stale objects of components that
    # are now disabled; start clean.
    [ ! -f Makefile ] || make distclean >/dev/null 2>&1 || true
    "$SRC/configure" "${CONFIG_ARGS[@]}" > "$OBJ_DIR/configure.log" 2>&1 \
        || { echo "configure failed; see $OBJ_DIR/configure.log" >&2; exit 1; }
    printf '%s' "$WANT_STAMP" > "$STAMP"
fi

# ------------------------------------------------------------------ build
echo "=== building ==="
cd "$BUILD"
make -j"$JOBS" > "$OBJ_DIR/make.log" 2>&1 || { echo "make failed; see $OBJ_DIR/make.log" >&2; exit 1; }
make install >> "$OBJ_DIR/make.log" 2>&1

# ------------------------------------------------------------------ install
# The app target links these four from app/Madeira/ (ignored, like
# libntdll_unix.a), in dependency order avformat -> avcodec -> swresample ->
# avutil.
FFMPEG_LIBS=(libavformat libavcodec libswresample libavutil)
for lib in "${FFMPEG_LIBS[@]}"; do
    cp "$PREFIX/lib/$lib.a" "$APP_DIR/$lib.a"
done

echo
echo "=== ffmpeg $FFMPEG_VERSION installed (headers: $PREFIX/include) ==="
for lib in "${FFMPEG_LIBS[@]}"; do
    ls -la "$APP_DIR/$lib.a"
done
# FFmpeg 7.x keeps the per-component switches in config_components.h.
for kind in DECODER DEMUXER PARSER PROTOCOL MUXER; do
    printf '  %-9s %s\n' "$kind:" "$(grep "^#define CONFIG_.*_$kind 1" "$BUILD/config_components.h" \
        | sed "s/#define CONFIG_//; s/_$kind 1//" | tr 'A-Z\n' 'a-z ')"
done
