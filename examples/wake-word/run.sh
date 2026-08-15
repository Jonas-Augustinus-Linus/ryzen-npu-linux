#!/usr/bin/env bash
# Compile the device-matched NPU dense layer, verify it, then run the detector.
# Usage:  ./run.sh --selftest      |      ./run.sh --wav sample.wav
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
IREE="$ROOT/iree-install/bin"
VENV="${KWS_VENV:-${IREE_VENV:-$HOME/src/iree-aie-venv}}"
PYTHON="$VENV/bin/python"
DETECT_NPU="${DETECT_NPU:-$REPO/scripts/detect-npu.sh}"

[ -x "$IREE/iree-compile" ] || { echo "Missing $IREE/iree-compile; build iree-amd-aie first (see ../../scripts/build.sh)" >&2; exit 1; }
[ -x "$IREE/iree-run-module" ] || { echo "Missing $IREE/iree-run-module; build iree-amd-aie first (see ../../scripts/build.sh)" >&2; exit 1; }
[ -x "$PYTHON" ] || { echo "Python virtualenv missing: $PYTHON" >&2; exit 1; }
"$PYTHON" -c 'import numpy' 2>/dev/null || { echo "numpy is missing from $VENV" >&2; exit 1; }
[ -x "$DETECT_NPU" ] || { echo "NPU detector missing: $DETECT_NPU" >&2; exit 1; }
DEVICE_TSV="$(IREE_AMD_AIE_ROOT="$ROOT" "$DETECT_NPU" --tsv)"
IFS=$'\t' read -r TARGET ROWS COLS GENERATION VBNV <<<"$DEVICE_TSV"
VMFB="${KWS_VMFB:-$HERE/dense_${TARGET}.vmfb}"

# Compile the 128x128x128 i32 dense layer for the detected generation.
EXTRA_COMPILE_FLAGS=()
if [ "$TARGET" = npu4 ]; then
  EXTRA_COMPILE_FLAGS+=(
    --iree-amdaie-enable-control-packet=true
    --iree-amdaie-packet-flow-strategy=auto
  )
else
  EXTRA_COMPILE_FLAGS+=(--iree-amdaie-packet-flow-strategy=none)
fi
VMFB_DIR="$(dirname "$VMFB")"
mkdir -p "$VMFB_DIR"
TEMP_VMFB="$(mktemp "$VMFB_DIR/.dense_${TARGET}.XXXXXX.vmfb")"
cleanup() {
  rm -f -- "$TEMP_VMFB"
}
trap cleanup EXIT

# Compile and verify every launch through a private file, then publish it only
# after the exact CPU-reference check passes. A failed rebuild therefore keeps
# an existing known-good KWS_VMFB byte-for-byte intact.
echo ">> Compiling dense_npu.mlir for $GENERATION ($VBNV, $TARGET, ${ROWS}x${COLS}) ..."
"$IREE/iree-compile" "$HERE/dense_npu.mlir" \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device="$TARGET" \
  --iree-amdaie-lower-to-aie-pipeline=objectFifo \
  --iree-amdaie-tile-pipeline=pack-peel \
  --iree-amd-aie-peano-install-dir="$ROOT/llvm-aie" \
  --iree-amd-aie-install-dir="$ROOT/iree-install" \
  --iree-amdaie-device-hal=amdxdna \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  "${EXTRA_COMPILE_FLAGS[@]}" \
  -o "$TEMP_VMFB"
[ -s "$TEMP_VMFB" ] || { echo "Compiler produced no VMFB: $TEMP_VMFB" >&2; exit 1; }

# Make correctness part of the setup contract before the illustrative model runs.
echo ">> Verifying dense module against an exact CPU-computed splat reference ..."
"$IREE/iree-run-module" --module="$TEMP_VMFB" --device=amdxdna \
  --amdxdna_n_core_rows="$ROWS" --amdxdna_n_core_cols="$COLS" \
  --function=dense \
  --input=128x128xi32=2 --input=128x128xi32=3 \
  --expected_output=128x128xi32=768 --equality_mode=exact \
  --output_max_element_count=16
mv -f -- "$TEMP_VMFB" "$VMFB"
echo ">> Kept verified dense module: $VMFB"

# Build the load-once bridge used by the detector; it supports npu1 and npu4.
IREE_AMD_AIE_ROOT="$ROOT" "$REPO/tools/npu-runner/build_lib.sh" >/dev/null
export KWS_VMFB="$VMFB" NPU_RUNNER_DIR="$REPO/tools/npu-runner"
export NPU_GENERATION="$GENERATION" NPU_VBNV="$VBNV"
exec "$PYTHON" "$HERE/wake_word.py" "$@"
