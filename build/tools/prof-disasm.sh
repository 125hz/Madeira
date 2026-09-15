#!/usr/bin/env bash
#
# prof-disasm.sh -- turn the [prof] hot-block dumps in a device log into two
# disassemblies per block: the GUEST x86 (i386) at its RIP, and the HOST ARM64
# (aarch64) FEX emitted for it.
#
# The sampler (build/ntdll-unix/signal_arm64_ios.c, ml960) prints, per hot block:
#
#   [prof]   block#3 rip=0x2a0000 module=?+0x2a0000 host=0x136d76b00+704 \
#            guest_insts=37 x87=0 vec=4 tso=9 mem=21 samples=3.6% pc=0x136d76da0 \
#            gdump=0x2a0000+96 hdump=0x136d76b00+384
#   [prof]     g: 8b0c2485 c9740a8b ...        <- guest bytes, 8-byte groups
#   [prof]     h: fd7bbfa9 fd030091 ...        <- host bytes, same encoding
#
# `gdump=<addr>+<len>` and `hdump=<addr>+<len>` give the disassembly base and the
# byte count of each stream; continuation lines simply append. This script needs
# nothing else from the log, so it works on a full device capture.
#
# Usage:
#   build/tools/prof-disasm.sh <logfile> [--block N] [--mc] [--out DIR]
#
#   --block N   only this block number (repeatable)
#   --mc        force llvm-mc --disassemble. llvm-mc prints no addresses, which
#               for a JIT block is most of the value (branch targets inside the
#               block are unreadable without them), so GNU objdump -b binary is
#               preferred when it is present -- note llvm-objdump has no raw
#               binary mode at all, so it cannot be used here.
#   --out DIR   also write the raw .bin streams there (default: a temp dir)
#
set -uo pipefail

usage() { sed -n '2,32p' "$0"; exit "${1:-1}"; }

LOG=""
ONLY=()
FORCE_MC=0
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --block) ONLY+=("$2"); shift 2 ;;
        --mc)    FORCE_MC=1; shift ;;
        --out)   OUT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*)      echo "unknown option: $1" >&2; usage ;;
        *)       LOG="$1"; shift ;;
    esac
done
[[ -n "$LOG" ]] || usage
[[ -r "$LOG" ]] || { echo "cannot read $LOG" >&2; exit 1; }

# ---- tools -----------------------------------------------------------------
# This checkout's own LLVM copies first (.xtool/toolchains, see .xtool/README.md),
# then whatever is on PATH.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$ROOT/.xtool/toolchains"
find_tool() {
    local name="$1" p
    for p in "$TC/llvm-mingw/bin/$name" "$TC/llvm-ios-build/bin/$name" \
             "$TC/llvm-project/bin/$name"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    command -v "$name" 2>/dev/null && return 0
    return 1
}
# GNU objdump is the only one of the two that can disassemble a headerless blob
# WITH addresses (llvm-objdump has no -b binary). llvm-mc is the portable
# fallback and is what --mc forces.
OBJDUMP="$(command -v objdump 2>/dev/null || true)"
if [[ -n "$OBJDUMP" ]] && ! "$OBJDUMP" --version 2>/dev/null | grep -qi "GNU objdump"; then
    OBJDUMP=""
fi
MC="$(find_tool llvm-mc || true)"
if [[ $FORCE_MC == 1 ]]; then OBJDUMP=""; fi
if [[ -z "$OBJDUMP" && -z "$MC" ]]; then
    echo "need GNU objdump or llvm-mc (looked in $TC and on PATH)" >&2
    exit 1
fi

[[ -n "$OUT" ]] || OUT="$(mktemp -d)"
mkdir -p "$OUT"

# disas <arch> <hexstring> <base-address> <label>
#   arch: i386 | aarch64
#
# x86 is variable-length, so only a disassembler can say where each instruction
# starts: GNU objdump -b binary does it with addresses, llvm-mc without.
# AArch64 is fixed 4-byte, so when llvm-mc is used the addresses are exact
# arithmetic -- which matters, because a JIT block is mostly branches to labels
# inside itself and those are unreadable without addresses. Most Linux binutils
# builds are x86-only (objdump -i), so this is the normal path, not a fallback.
disas() {
    local arch="$1" hex="$2" base="$3" label="$4"
    local bin="$OUT/$label.bin"
    [[ -n "$hex" ]] || { echo "      (no bytes)"; return; }
    printf '%s' "$hex" | sed 's/../& /g' | tr -d '\n' | xxd -r -p > "$bin" 2>/dev/null
    [[ -s "$bin" ]] || { echo "      (empty after decode)"; return; }

    if [[ "$arch" == aarch64 ]]; then
        [[ -n "$MC" ]] || { echo "      (no llvm-mc: cannot disassemble aarch64)"; return; }
        printf '%s' "$hex" | sed 's/../0x& /g' \
            | "$MC" --disassemble -triple=aarch64 2>&1 \
            | awk -v base="$base" -v hx="$hex" '
                BEGIN { n = 0 }
                {
                    line = $0
                    sub(/^[ \t]+/, "", line)
                    if (line == "" || line ~ /^\./) next
                    word = substr(hx, n * 8 + 1, 8)
                    # bytes are little-endian in the stream; show the instruction word
                    w = substr(word,7,2) substr(word,5,2) substr(word,3,2) substr(word,1,2)
                    printf "      %x:\t%s\t%s\n", strtonum(base) + n * 4, w, line
                    n++
                }'
        return
    fi

    if [[ -n "$OBJDUMP" ]] && "$OBJDUMP" -i 2>/dev/null | grep -qw "$arch"; then
        "$OBJDUMP" -D -b binary -m "$arch" --adjust-vma="$base" "$bin" 2>/dev/null \
            | sed -n '/^ *[0-9a-f]*:/p' | sed 's/^/      /'
    elif [[ -n "$MC" ]]; then
        # No addresses for x86 without a real disassembler pass; the base is in
        # the block header printed above.
        printf '%s' "$hex" | sed 's/../0x& /g' \
            | "$MC" --disassemble -triple=i386 2>&1 \
            | sed 's/^/      /'
    else
        echo "      (no disassembler for $arch)"
    fi
}

# ---- parse -----------------------------------------------------------------
want_block() {
    [[ ${#ONLY[@]} -eq 0 ]] && return 0
    local b
    for b in "${ONLY[@]}"; do [[ "$b" == "$1" ]] && return 0; done
    return 1
}

emit() {
    [[ -n "${BLK:-}" ]] || return 0
    if want_block "$BLK"; then
        echo "=============================================================================="
        echo "block#$BLK  rip=$RIP  module=$MOD  host=$HOST  samples=$SAMP"
        echo "  counts: $COUNTS"
        echo "-- guest x86 (i386) @ $GADDR, ${#GHEX} hex chars --"
        disas i386 "$GHEX" "$GADDR" "block${BLK}.guest"
        echo "-- host ARM64 (aarch64) @ $HADDR, ${#HHEX} hex chars --"
        disas aarch64 "$HHEX" "$HADDR" "block${BLK}.host"
        echo
    fi
    BLK=""
}

BLK=""; RIP=""; MOD=""; HOST=""; SAMP=""; COUNTS=""; GADDR=0; HADDR=0; GHEX=""; HHEX=""

while IFS= read -r line; do
    case "$line" in
        *"[prof]"*"block#"*)
            emit
            BLK="$(sed -n 's/.*block#\([0-9]*\).*/\1/p' <<<"$line")"
            RIP="$(sed -n 's/.*[ ]rip=\([^ ]*\).*/\1/p' <<<"$line")"
            MOD="$(sed -n 's/.*[ ]module=\([^ ]*\).*/\1/p' <<<"$line")"
            HOST="$(sed -n 's/.*[ ]host=\([^ ]*\).*/\1/p' <<<"$line")"
            SAMP="$(sed -n 's/.*[ ]samples=\([^ ]*\).*/\1/p' <<<"$line")"
            COUNTS="$(sed -n 's/.*\(guest_insts=[^ ]*\)[ ]\(x87=[^ ]*\)[ ]\(vec=[^ ]*\)[ ]\(tso=[^ ]*\)[ ]\(mem=[^ ]*\).*/\1 \2 \3 \4 \5/p' <<<"$line")"
            GADDR="$(sed -n 's/.*[ ]gdump=\([^+]*\)+.*/\1/p' <<<"$line")"
            HADDR="$(sed -n 's/.*[ ]hdump=\([^+]*\)+.*/\1/p' <<<"$line")"
            [[ -n "$GADDR" ]] || GADDR=0
            [[ -n "$HADDR" ]] || HADDR=0
            GHEX=""; HHEX=""
            ;;
        *"[prof]"*"     g: "*)
            [[ -n "$BLK" ]] || continue
            case "$line" in *"<"*) continue ;; esac   # "<not readable>" note
            GHEX+="$(sed 's/.*[ ]g: //; s/[^0-9a-fA-F]//g' <<<"$line")"
            ;;
        *"[prof]"*"     h: "*)
            [[ -n "$BLK" ]] || continue
            case "$line" in *"<"*) continue ;; esac
            HHEX+="$(sed 's/.*[ ]h: //; s/[^0-9a-fA-F]//g' <<<"$line")"
            ;;
    esac
done < "$LOG"
emit

echo "raw streams in: $OUT"
