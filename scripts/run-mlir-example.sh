#!/usr/bin/env bash
# run-mlir-example.sh — build a Xilinx/mlir-aie programming_example and RUN IT
# on the NPU (XDNA1 npu1 or XDNA2 npu2 — detected by mlir-aie-env.sh / NPU2).
#
# mlir-aie 1.4.x reshaped the examples: most are a single Python design run
# directly (@iron.jit compiles on first call, device auto-detected); a few
# (ml/conv2d, ml/mobilenet, matmul C++ hosts) still use a Makefile. This
# script picks the right invocation:
#   1. Makefile with a run_py target  -> make devicename=<dev> + run_py
#   2. <dirname>.py                   -> python <dirname>.py [args...]
#   3. Makefile with a run target     -> make devicename=<dev> run  (C++ host:
#                                        needs libxrt-dev)
#
# Usage:
#   ./scripts/run-mlir-example.sh basic/passthrough_kernel
#   ./scripts/run-mlir-example.sh ml/softmax
#   ./scripts/run-mlir-example.sh ml/conv2d
#   ./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
#       -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
#
# Env overrides: MLIR_AIE_DIR (default ~/src/mlir-aie)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"

[ -d "$MLIR_AIE_DIR/programming_examples" ] || {
  echo "mlir-aie is not set up at $MLIR_AIE_DIR — run ./scripts/setup-mlir-aie.sh first." >&2
  exit 1
}

REL="${1:?usage: run-mlir-example.sh <programming_examples/rel/path> [design args...]}"
shift
EX="$MLIR_AIE_DIR/programming_examples/$REL"
[ -d "$EX" ] || { echo "no such example: $EX" >&2; exit 1; }

# shellcheck disable=SC1091
source "$HERE/mlir-aie-env.sh"
DEV="$([ "${NPU2:-0}" = "1" ] && echo npu2 || echo npu)"

PY="$EX/$(basename "$EX").py"
cd "$EX"
if [ -f Makefile ] && grep -qE '^run_py:' Makefile; then
  echo "=== make (devicename=$DEV) + run_py ON THE NPU ==="
  make clean >/dev/null 2>&1 || true
  make devicename="$DEV" "$@"
  make devicename="$DEV" "$@" run_py
elif [ -f "$PY" ]; then
  echo "=== python $(basename "$PY") $* (device auto-detected: $DEV) ==="
  python "$PY" "$@"
elif [ -f Makefile ]; then
  echo "=== make (devicename=$DEV) + run ON THE NPU (C++ host: needs libxrt-dev) ==="
  make clean >/dev/null 2>&1 || true
  make devicename="$DEV" "$@"
  make devicename="$DEV" "$@" run
else
  echo "don't know how to run $REL (no run_py Makefile target, no $(basename "$PY"))" >&2
  exit 1
fi
