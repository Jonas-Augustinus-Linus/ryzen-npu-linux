#!/usr/bin/env bash
# Compile the NPU dense layer once, then run the wake-word detector.
# Usage:  ./run.sh --selftest      |      ./run.sh --wav sample.wav
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
IREE="$ROOT/iree-install/bin"
VENV="${KWS_VENV:-$HOME/src/iree-aie-venv}"
VMFB="$HERE/dense_npu.vmfb"

[ -x "$IREE/iree-compile" ] || { echo "Build iree-amd-aie first (see ../../scripts/build.sh)"; exit 1; }
[ -d "$VENV" ] && source "$VENV/bin/activate"

# Compile the 128x128x128 i32 dense layer for npu1_4col (objectFifo, the i32 path).
if [ ! -f "$VMFB" ] || [ "$HERE/dense_npu.mlir" -nt "$VMFB" ]; then
  echo ">> Compiling dense_npu.mlir for the NPU ..."
  "$IREE/iree-compile" "$HERE/dense_npu.mlir" \
    --iree-hal-target-backends=amd-aie \
    --iree-amdaie-target-device=npu1_4col \
    --iree-amdaie-lower-to-aie-pipeline=objectFifo \
    --iree-amdaie-tile-pipeline=pack-peel \
    --iree-amd-aie-peano-install-dir="$ROOT/llvm-aie" \
    --iree-amd-aie-install-dir="$ROOT/iree-install" \
    --iree-amdaie-packet-flow-strategy=none \
    --iree-amdaie-device-hal=amdxdna \
    --iree-hal-memoization=false \
    --iree-hal-indirect-command-buffers=false \
    -o "$VMFB"
fi

export IREE_RUN_MODULE="$IREE/iree-run-module" KWS_VMFB="$VMFB"
exec python3 "$HERE/wake_word.py" "$@"
