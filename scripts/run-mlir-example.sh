#!/usr/bin/env bash
# run-mlir-example.sh — build a Xilinx/mlir-aie programming_example for the XDNA1
# NPU (npu1) and RUN IT on the NPU. Prefers the `run_py` target (pyxrt host; no
# XRT dev headers needed). For C++-host-only examples, pass `run` (needs libxrt-dev).
#
# Usage:
#   ./scripts/run-mlir-example.sh ml/conv2d
#   ./scripts/run-mlir-example.sh basic/passthrough_kernel run_py
#   ./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: libxrt-dev
#
# Env overrides: MLIR_AIE_DIR (default ~/src/mlir-aie)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"

[ -d "$MLIR_AIE_DIR/programming_examples" ] || {
  echo "mlir-aie is not set up at $MLIR_AIE_DIR — run ./scripts/setup-mlir-aie.sh first." >&2
  exit 1
}

# shellcheck disable=SC1091
source "$HERE/mlir-aie-env.sh"

REL="${1:?usage: run-mlir-example.sh <programming_examples/rel/path> [make-target]}"
TGT="${2:-run_py}"
EX="$MLIR_AIE_DIR/programming_examples/$REL"
[ -d "$EX" ] || { echo "no such example: $EX" >&2; exit 1; }

echo "=== build $REL  (devicename=npu / npu1, NPU2=${NPU2:-?}) ==="
make -C "$EX" clean >/dev/null 2>&1 || true
make -C "$EX"

echo "=== run ($TGT) ON THE NPU ==="
make -C "$EX" "$TGT"
