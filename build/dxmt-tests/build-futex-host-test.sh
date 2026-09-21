#!/bin/bash
# MADEIRA (WOW64_DESIGN.md, ml1070): build and run the host-side race test for
# DXMT's wait-on-address hand-off primitive.
#
# Subject under test:
#   research/dxmt/src/util/util_futex.hpp      spin + re-check loop + notify
#   research/dxmt/src/util/util_cpu_fence.hpp  CpuFence on top of it
#
# Runs on the BUILD machine (WSL), not on device.  The header is included
# verbatim; only the three-line platform call is substituted (futex(2) for
# ntdll's RtlWaitOnAddress family) -- see the comment at the top of
# futex-host-test.cpp for what that does and does not prove.
#
# Usage: bash build/dxmt-tests/build-futex-host-test.sh
# Exit 0 = PASS.  Pass --tsan for a ThreadSanitizer run as well.
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
UTIL="$REPO_ROOT/research/dxmt/src/util"
OUT="$DIR/out-host"
mkdir -p "$OUT"

CXX="${CXX:-g++}"
WANT_TSAN=0
for arg in "$@"; do
    case "$arg" in
        --tsan) WANT_TSAN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "=== building futex-host-test ($CXX) ==="
"$CXX" -std=c++20 -O2 -Wall -Wextra -pthread \
    -I "$UTIL" \
    -o "$OUT/futex-host-test" \
    "$DIR/futex-host-test.cpp"

ls -la "$OUT/futex-host-test"
echo ""
echo "=== running ==="
"$OUT/futex-host-test"
status=$?

if [ "$WANT_TSAN" = 1 ]; then
    echo ""
    echo "=== building futex-host-test-tsan ==="
    "$CXX" -std=c++20 -O1 -g -Wall -Wextra -pthread -fsanitize=thread \
        -I "$UTIL" \
        -o "$OUT/futex-host-test-tsan" \
        "$DIR/futex-host-test.cpp"
    echo "=== running under ThreadSanitizer ==="
    # The park itself is a raw syscall TSan cannot see, so the counters it
    # checks are the atomics around it -- which is exactly the ordering claim
    # the header makes (store, then notify; load, then park).
    "$OUT/futex-host-test-tsan"
    status=$?
fi

exit $status
