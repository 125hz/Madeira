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
#   ./build-pe.sh --install all   # also install nvapi/nvngx and friends
#
# --targets limits what is BUILT; --install limits what is copied into
# app/Madeira/<arch>-windows/.  The install set defaults to the modules the
# Direct3D paths need, so that building the whole tree for a compile check
# does not quietly add DLLs to the app bundle that nothing has wired up yet.
#
# d3d11.dll / dxgi.dll / d3d10core.dll joined that default set on 2026-09-19
# (WOW64_DESIGN.md section 6): the 32-bit unix-call dispatch they need is the
# same winemetal wow64 table the D3D9 path already uses, and they REPLACE
# Wine's wined3d-based i386 copies -- .xtool/build-wine-i386.sh no longer
# builds those (NEVER_OVERWRITE/EXCLUDE/SKIP_BREADTH_REASON there), so a farm
# round will not overwrite what this stage installs.
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
[ ${#install_set[@]} -gt 0 ] || install_set=(winemetal.dll d3d9.dll d3d9-emulated.dll d3d9shim.dll \
                                             d3d11.dll dxgi.dll d3d10core.dll)

# MADEIRA (WOW64_DESIGN.md section 8.5): the i386 shim (built as d3d9shim.dll,
# since two meson targets cannot both be called d3d9) is now bound to its unix
# side -- virtual_ios.c's load_builtin_unixlib() has a `d3d9shim` branch that
# hands it dxmt_d3d9_unix_call_{,wow64_}funcs -- so it SHIPS as d3d9.dll and
# the emulated DXMT frontend ships beside it as d3d9-emulated.dll.
#
# Installing the shim as d3d9.dll is NOT the same thing as turning the native
# frontend on. With no knob set, the shim's DllMain forwards all ten exports
# to d3d9-emulated.dll (d3d9shim_main.c read_mode/forwarding), so the default
# path is byte for byte the frontend section 6 measured and log 41 ran at
# 30-40 fps -- the shim adds one LoadLibrary and a GetProcAddress per export,
# once. The native ARM64 frontend is opt-in, per session, with
# Documents/madeira-d3d9.txt = `native` (ContentView exports it as
# MADEIRA_D3D9), which is what makes the A/B of section 8.8-4 a one-file
# change on device rather than a reinstall.
#
# Set MADEIRA_D3D9_DEFAULT=emulated to go back to the previous mapping (the
# emulated build installed as BOTH d3d9.dll and d3d9-emulated.dll, the shim
# only as d3d9shim.dll, where nothing loads it) for a bisect. --install
# matches the INSTALLED name, so `--install d3d9.dll` always ships whichever
# module is currently mapped to that name.
MADEIRA_D3D9_DEFAULT="${MADEIRA_D3D9_DEFAULT:-shim}"
install_as() {
    if [ "$2" = i386 ]; then
        case "$1" in
            d3d9shim.dll)
                if [ "$MADEIRA_D3D9_DEFAULT" = shim ]; then
                    echo "d3d9.dll d3d9shim.dll"
                else
                    echo "d3d9shim.dll"
                fi
                return ;;
            d3d9.dll)
                if [ "$MADEIRA_D3D9_DEFAULT" = shim ]; then
                    echo "d3d9-emulated.dll"
                else
                    echo "d3d9.dll d3d9-emulated.dll"
                fi
                return ;;
        esac
    fi
    echo "$1"
}

# MADEIRA (WOW64_DESIGN.md section 8.4): meson's default buildtype is `debug`,
# which means every PE module this stage has ever produced -- including the
# i386 d3d9.dll that section 6 measured at 20-28 % of all CPU -- was compiled
# -O0.  That A/B has now been run: the i386 stage (the shipped D3D9 path)
# defaults to `release` below.  research/dxmt/meson.build sets
# 'b_ndebug=if-release', so a release build also defines NDEBUG, which flips
# winemetal_thunks.c's UNIX_CALL from the asserting form to the quiet one
# (src/winemetal/winemetal_thunks.c:35-44) -- confirmed to still compile.
#
# The aarch64/arm64ec stages are untouched by this: their default stays
# `debug`, scoping the change to the i386 (D3D9) stage only.  Set
# MADEIRA_DXMT_PE_BUILDTYPE=debug (and delete research/dxmt/build-pe-<arch>,
# since meson only reads this at setup time) to go back to an unoptimised
# i386 build for a bisect; MADEIRA_DXMT_PE_BUILDTYPE, when set, still applies
# to every requested arch, matching the previous single-knob behaviour.
default_pe_buildtype() {
    case "$1" in
        i386) echo release ;;
        *)    echo debug ;;
    esac
}

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
    buildtype="${MADEIRA_DXMT_PE_BUILDTYPE:-$(default_pe_buildtype "$arch")}"

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
        echo "--- meson setup $build_sub (buildtype $buildtype)"
        rm -rf "$build_sub"
        meson setup --cross-file "$cross_file" --native-file "$native_file" \
            --buildtype "$buildtype" \
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
        # install_as may return more than one space-separated target name
        # (the emulated d3d9 frontend installs as both d3d9.dll and
        # d3d9-emulated.dll by default -- see install_as above).
        read -r -a targets_for_dll <<< "$(install_as "$base" "$arch")"
        shown="$dll"
        marks=()
        for target in "${targets_for_dll[@]}"; do
            if should_install "$target" || should_install "$base"; then
                "$MINGW_BIN/$triple-strip" -o "$dest/$target" "$dll"
                shown="$dest/$target"
                if [ "$target" = "$base" ]; then
                    marks+=("-> app/Madeira/$install_dir/")
                else
                    marks+=("-> app/Madeira/$install_dir/$target")
                fi
                installed=$((installed + 1))
            fi
        done
        if [ ${#marks[@]} -eq 0 ]; then
            mark="(built, not installed)"
        else
            mark="$(IFS=', '; echo "${marks[*]}")"
        fi
        printf "    %-18s %10s bytes  " "$base" "$(wc -c < "$shown" | tr -d ' ')"
        printf "%s  " "$("$MINGW_BIN/llvm-readobj" --file-headers "$shown" \
            | sed -n 's/^  Machine: .*(\(0x[0-9A-Fa-f]*\))/Machine \1/p' | head -1)"
        echo "$mark"
    done < <(find "$build_sub/src" -maxdepth 2 -name '*.dll' | sort)
    [ "$found" = 1 ] || { echo "    (none)"; overall=1; }
    echo "    $installed module(s) installed into app/Madeira/$install_dir/"
done

exit $overall
