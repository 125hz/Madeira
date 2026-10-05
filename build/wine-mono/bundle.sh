#!/bin/bash
# Copy the pinned Wine Mono (pin.sh) into the app bundle, with its licence summary.
#
# Called by the Xcode build phase "Bundle Wine Mono" as
#   bundle.sh "$CODESIGNING_FOLDER_PATH/wine-mono"
# and runnable by hand with any destination. The source is build/wine-mono/wine-mono-<ver>
# from fetch.sh; without it the destination is removed and the app is built without Mono.
# The source tree is never modified.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$R/build/wine-mono/pin.sh"
VER="$WINE_MONO_VER"
SRC="$R/build/wine-mono/wine-mono-$VER"
DST="${1:?usage: bundle.sh <destination folder>}"

if [ ! -f "$SRC/bin/libmono-2.0-x86.dll" ]; then
    rm -rf "$DST"
    echo "note: no Wine Mono in $SRC (run build/wine-mono/fetch.sh); the app is built without it"
    exit 0
fi

WANT="$(sed -n 's/^#define WINE_MONO_VERSION "\(.*\)"/\1/p' "$R/wine/dlls/mscoree/mscoree_private.h" 2>/dev/null || true)"
if [ -n "$WANT" ] && [ "$WANT" != "$VER" ]; then
    echo "warning: Wine's mscoree asks for Wine Mono $WANT; bundling the pinned $VER (build/wine-mono/pin.sh)"
fi

# The lib/mono/*-api reference assemblies are for compilers only (~107 MB of 233).
rsync -a --delete --exclude '/lib/mono/*-api/' "$SRC/" "$DST/"
cp "$R/build/wine-mono/COPYING" "$DST/COPYING"
