#!/bin/bash
# Build DXMT's PE side (the DLLs Wine loads inside Madeira) with llvm-mingw.
#
# This is the counterpart to build.sh, which builds the unix/Metal half that
# links into Madeira.app.  Until milestone 4 the PE DLLs in
# app/Madeira/{aarch64,arm64ec}-windows/ were imported prebuilt, so there was
# no PE stage in this checkout at all; the D3D9 path needs an i386 build, so
# the stage now exists and is reproducible.
#
#   ./build-pe.sh                 # i386 only (the milestone-4 target)
#   ./build-pe.sh i386 aarch64    # more arches
#   ./build-pe.sh --targets winemetal.dll d3d9.dll
#   ./build-pe.sh --install all   # also install d3d11/dxgi/d3d10core
#
# --targets limits what is BUILT; --install limits what is copied into
# app/Madeira/<arch>-windows/.  The install set defaults to the modules the
# D3D9 path needs, so that building the whole tree for a compile check does
# not quietly add DLLs to the app bundle that nothing has wired up yet (the
# i386 d3d11/dxgi/d3d10core do build, but their 32-bit unix-call dispatch is
# still the open hand-off in WOW64_DESIGN.md section 7).
#
# Why it builds out of a synced copy rather than in place: the native build
# workspace ($MADEIRA_WORK, recorded in .xtool/work-path) is a `git archive
# HEAD` export, so uncommitted submodule changes are invisible to it.  We
# rsync the tracked research/dxmt tree over the exported one first, the same
# way .xtool/build-fex.sh does for FEX.  Meson build dirs are excluded so a
# sync does not clobber a configured tree.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
MADEIRA_ROOT="${MADEIRA_ROOT:-$(cd "$BUILD_DIR/../.." && pwd)}"
if [ -z "${MADEIRA_WORK:-}" ]; then
    if [ -f "$MADEIRA_ROOT/.xtool/work-path" ]; then
        MADEIRA_WORK="$(cat "$MADEIRA_ROOT/.xtool/work-path")"
    else
        MADEIRA_WORK="$MADEIRA_ROOT"
    fi
fi
MINGW_BIN="$MADEIRA_ROOT/.xtool/toolchains/llvm-mingw/bin"
DXMT_SRC="$MADEIRA_WORK/research/dxmt"
MESON_DIR="$MADEIRA_WORK/build/dxmt-ios/meson"

arches=()
targets=()
install_set=()
mode=arch
for arg in "$@"; do
    case "$arg" in
        --targets) mode=target ;;
        --install) mode=install ;;
        --*)       echo "unknown option: $arg" >&2; exit 2 ;;
        *)         case "$mode" in
                       target)  targets+=("$arg") ;;
                       install) install_set+=("$arg") ;;
                       *)       arches+=("$arg") ;;
                   esac ;;
    esac
done
[ ${#arches[@]} -gt 0 ] || arches=(i386)
[ ${#install_set[@]} -gt 0 ] || install_set=(winemetal.dll d3d9.dll)

should_install() {
    for want in "${install_set[@]}"; do
        [ "$want" = all ] && return 0
        [ "$want" = "$1" ] && return 0
    done
    return 1
}

export PATH="$MADEIRA_ROOT/.xtool/bin:$MINGW_BIN:$PATH"
# The top-level meson.build does an unconditional find_program('xcrun') for
# the Metal shader generators; .xtool/bin/xcrun is the local dispatcher and
# needs these to locate the SDK and the Windows Metal compiler.
export BOXEDVN_XTOOL_SDK="${BOXEDVN_XTOOL_SDK:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
export BOXEDVN_METAL_BIN="${BOXEDVN_METAL_BIN:-$MADEIRA_ROOT/.xtool/toolchains/metal/32023/bin}"

for tool in meson ninja xxd; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "=== syncing tracked research/dxmt into the native workspace ==="
echo "    $MADEIRA_ROOT/research/dxmt  ->  $DXMT_SRC"
mkdir -p "$DXMT_SRC"
rsync -a --delete --exclude='.git' --exclude='build-*/' \
    "$MADEIRA_ROOT/research/dxmt/" "$DXMT_SRC/"

mkdir -p "$MESON_DIR"

# The native (build-machine) compiler is only used for meson's own probes
# here -- no native targets are configured for a PE cross build -- but meson
# still insists on having one.  The upstream build-osx.txt names Apple clang;
# on this host the build machine is Linux.
native_file="$MESON_DIR/native-host.txt"
{
    echo "[binaries]"
    if command -v clang >/dev/null; then
        echo "c = 'clang'"
        echo "cpp = 'clang++'"
    else
        echo "c = 'gcc'"
        echo "cpp = 'g++'"
    fi
} > "$native_file"

arch_triple() {
    case "$1" in
        i386)    echo i686-w64-mingw32 ;;
        aarch64) echo aarch64-w64-mingw32 ;;
        arm64ec) echo arm64ec-w64-mingw32 ;;
        *)       return 1 ;;
    esac
}
arch_cpu_family() {
    case "$1" in
        i386)              echo x86 ;;
        aarch64|arm64ec)   echo aarch64 ;;
    esac
}
arch_cpu() {
    case "$1" in
        i386)              echo i686 ;;
        aarch64|arm64ec)   echo aarch64 ;;
    esac
}
arch_wine_build() {
    # Which configured Wine tree holds the matching import libraries.
    # .xtool/configure-wine.sh creates build-macos (aarch64 PE) and
    # build-i386 (--enable-archs=i386); build-arm64ec is configured
    # separately.
    case "$1" in
        i386)    echo "$MADEIRA_WORK/wine/build-i386" ;;
        aarch64) echo "$MADEIRA_WORK/wine/build-macos" ;;
        arm64ec) echo "$MADEIRA_WORK/wine/build-arm64ec" ;;
    esac
}
arch_install_dir() {
    case "$1" in
        i386)    echo i386-windows ;;
        aarch64) echo aarch64-windows ;;
        arm64ec) echo arm64ec-windows ;;
    esac
}

overall=0
for arch in "${arches[@]}"; do
    triple="$(arch_triple "$arch")" || { echo "unknown arch: $arch" >&2; exit 2; }
    wine_build="$(arch_wine_build "$arch")"
    install_dir="$(arch_install_dir "$arch")"
    build_sub="build-pe-$arch"

    echo ""
    echo "=================================================================="
    echo "=== $arch ($triple) -> $install_dir"
    echo "=================================================================="

    if [ ! -f "$wine_build/config.status" ]; then
        echo "SKIP: $wine_build is not configured."
        echo "      Run .xtool/configure-wine.sh (and the matching build) first."
        overall=1
        continue
    fi

    # winemetal.dll links against Wine's import libraries and is postprocessed
    # with winebuild --builtin.  src/winemetal/meson.build looks for winebuild
    # at <wine_build_path>/tools/winebuild/winebuild, but on this host only the
    # separate build-tools tree builds host tools, so alias it in.
    if [ ! -e "$wine_build/tools/winebuild/winebuild" ]; then
        if [ -x "$MADEIRA_WORK/wine/build-tools/tools/winebuild/winebuild" ]; then
            echo "--- aliasing winebuild from wine/build-tools"
            mkdir -p "$wine_build/tools/winebuild"
            ln -sf "$MADEIRA_WORK/wine/build-tools/tools/winebuild/winebuild" \
                   "$wine_build/tools/winebuild/winebuild"
        else
            echo "SKIP: no winebuild available (wine/build-tools not built)."
            overall=1
            continue
        fi
    fi

    cross_file="$MESON_DIR/cross-$arch.txt"
    cat > "$cross_file" <<EOF
# Generated by build/dxmt-ios/build-pe.sh -- do not edit.
# Absolute paths on purpose: the upstream build-*.txt cross files use
# '@GLOBAL_SOURCE_ROOT@' / 'toolchains/llvm-mingw-<date>-ucrt-macos-universal'
# and expect a toolchains symlink inside the submodule.  This checkout keeps
# its toolchains in .xtool/ and we would rather not add an untracked symlink
# to the submodule, so the paths are resolved here instead.
[binaries]
c = '$MINGW_BIN/$triple-clang'
cpp = '$MINGW_BIN/$triple-clang++'
ar = '$MINGW_BIN/$triple-ar'
strip = '$MINGW_BIN/$triple-strip'
windres = '$MINGW_BIN/$triple-windres'
dlltool = '$MINGW_BIN/$triple-dlltool'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$(arch_cpu_family "$arch")'
cpu = '$(arch_cpu "$arch")'
endian = 'little'
EOF

    cd "$DXMT_SRC"
    if [ ! -f "$build_sub/build.ninja" ]; then
        echo "--- meson setup $build_sub"
        rm -rf "$build_sub"
        meson setup --cross-file "$cross_file" --native-file "$native_file" \
            -Dwine_build_path="$wine_build" \
            -Dwine_builtin_dll=true \
            "$build_sub"
    else
        echo "--- reusing configured $build_sub"
    fi

    if [ ${#targets[@]} -gt 0 ]; then
        want=()
        for t in "${targets[@]}"; do
            # resolve a bare DLL name to its path inside the build dir
            hit="$(cd "$build_sub" && ninja -t targets all 2>/dev/null \
                   | sed -n "s/^\(.*\/$t\):.*/\1/p" | head -1)"
            if [ -n "$hit" ]; then want+=("$hit"); else want+=("$t"); fi
        done
        echo "--- ninja ${want[*]}"
        (cd "$build_sub" && ninja "${want[@]}") || { overall=1; continue; }
    else
        echo "--- ninja (all)"
        (cd "$build_sub" && ninja) || { overall=1; continue; }
    fi

    echo ""
    echo "--- built PE modules for $arch"
    dest="$MADEIRA_ROOT/app/Madeira/$install_dir"
    mkdir -p "$dest"
    found=0
    installed=0
    while IFS= read -r dll; do
        found=1
        base="$(basename "$dll")"
        if should_install "$base"; then
            "$MINGW_BIN/$triple-strip" -o "$dest/$base" "$dll"
            shown="$dest/$base"
            mark="-> app/Madeira/$install_dir/"
            installed=$((installed + 1))
        else
            shown="$dll"
            mark="(built, not installed)"
        fi
        printf "    %-16s %10s bytes  " "$base" "$(wc -c < "$shown" | tr -d ' ')"
        printf "%s  " "$("$MINGW_BIN/llvm-readobj" --file-headers "$shown" \
            | sed -n 's/^  Machine: .*(\(0x[0-9A-Fa-f]*\))/Machine \1/p' | head -1)"
        echo "$mark"
    done < <(find "$build_sub/src" -maxdepth 2 -name '*.dll' | sort)
    [ "$found" = 1 ] || { echo "    (none)"; overall=1; }
    echo "    $installed module(s) installed into app/Madeira/$install_dir/"
done

exit $overall
