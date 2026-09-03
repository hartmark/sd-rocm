#!/usr/bin/env bash
# Build conf/hsa-gentle-wait.so (LD_PRELOAD shim, see the .c for what/why).
# Run inside the sd-rocm container, or anywhere with gcc. Idempotent.
#   ./build-hsa-gentle-wait.sh [output.so]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE/../conf/hsa-gentle-wait.c}"
OUT="${1:-$HERE/../conf/hsa-gentle-wait.so}"
CC="${CC:-gcc}"
"$CC" -O2 -fPIC -shared -Wall -o "$OUT" "$SRC" -ldl
echo "built $OUT"
"$CC" --version | head -1
# sanity: the interposed symbols must be exported
for s in hsa_signal_wait_scacquire hsa_signal_wait_relaxed hsa_amd_signal_wait_any hsa_amd_signal_wait_all; do
  nm -D --defined-only "$OUT" | grep -q " T $s$" && echo "  exports $s" || { echo "  MISSING $s" >&2; exit 1; }
done
