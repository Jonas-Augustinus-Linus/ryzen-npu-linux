#!/usr/bin/env bash
# run-matmul.sh — compile a matmul and run it on an AMD XDNA NPU. Detects
# Phoenix/XDNA1 versus Strix/XDNA2 and selects the matching IREE target.
#
# Usage:
#   scripts/run-matmul.sh                      # default: i32 128x128x128, A=2 B=3 -> 768
#   scripts/run-matmul.sh bf16                 # bf16 256x256x256, A=2 B=3 -> 1536 (f32 acc)
#   scripts/run-matmul.sh i32  256 256 256 4 5 # type M N K A B
#   TYPE=bf16 M=512 N=512 K=512 scripts/run-matmul.sh
# A/B are signed integer splats. For bf16, exact-representable inputs/results
# are required so the full-output CPU-reference check can remain exact.
#
# Env overrides: REPO, VENV, TARGET_DEVICE, VMFB_OUT, BENCH=1 (also benchmark)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$HOME/src/iree-amd-aie}"
VENV="${VENV:-$HOME/src/iree-aie-venv}"
IREE="$REPO/iree-install/bin"
PEANO="$REPO/llvm-aie"
DETECT_NPU="${DETECT_NPU:-$HERE/detect-npu.sh}"

TYPE="${1:-${TYPE:-i32}}"
# Defaults differ by type; bf16 uses a larger shape on both target pipelines.
if [ "$TYPE" = "bf16" ]; then DM=256; DN=256; DK=256; else DM=128; DN=128; DK=128; fi
M="${2:-${M:-$DM}}"; N="${3:-${N:-$DN}}"; K="${4:-${K:-$DK}}"
A="${5:-${A:-2}}"; B="${6:-${B:-3}}"

for dim_name in M N K; do
  dim_value="${!dim_name}"
  if ! [[ "$dim_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$dim_name must be a positive integer (got '$dim_value')" >&2
    exit 2
  fi
done

case "$TYPE" in
  i32)  ETYPE=i32;  ACC=i32; ZERO="0 : i32" ;;
  bf16) ETYPE=bf16; ACC=f32; ZERO="0.0 : f32" ;;
  *) echo "unknown TYPE '$TYPE' (use i32 or bf16)"; exit 1 ;;
esac

[ -d "$VENV" ] && source "$VENV/bin/activate"

# Compute a trusted scalar CPU reference without interpolating user input into
# Python source. i32 arithmetic follows signed 32-bit wraparound; bf16 inputs
# are rounded to bfloat16 before producing the f32 reference value.
if ! EXPECTED="$(python3 - "$TYPE" "$K" "$A" "$B" <<'PY'
import sys

kind, k_text, a_text, b_text = sys.argv[1:]
k = int(k_text)

if kind == "i32":
    try:
        a, b = int(a_text), int(b_text)
    except ValueError:
        raise SystemExit("i32 A and B must be decimal integers")
    lo, hi = -(1 << 31), (1 << 31) - 1
    if not (lo <= a <= hi and lo <= b <= hi):
        raise SystemExit("i32 A and B must fit in signed 32 bits")
    value = (a * b * k + (1 << 31)) % (1 << 32) - (1 << 31)
    print(value)
else:
    try:
        a, b = int(a_text), int(b_text)
    except ValueError:
        raise SystemExit("bf16 A and B must be signed decimal integers")
    if abs(a) > 256 or abs(b) > 256:
        raise SystemExit("bf16 A and B must be in [-256, 256] for exact representation")
    value = a * b * k
    if abs(value) > (1 << 24):
        raise SystemExit("bf16 K*A*B must be within [-2^24, 2^24] for exact f32 representation")
    print(value)
PY
)"; then
  echo "invalid matmul constants" >&2
  exit 2
fi

# Resolve only a positively identified, verified device target. The shared
# helper refuses to collapse later npu5/npu6 hardware into npu4 by accident.
[ -x "$DETECT_NPU" ] || {
  echo "NPU detector is missing or not executable: $DETECT_NPU" >&2
  exit 1
}
IFS=$'\t' read -r TARGET ROWS COLS GENERATION VBNV \
  < <(IREE_AMD_AIE_ROOT="$REPO" "$DETECT_NPU" --tsv)

# Keep the previously verified Phoenix lowering. The Strix choices mirror the
# upstream CPU-comparison configurations: objectFifo for both types, and the
# Peano bf16 microkernel with four-level tiling on the 4x8 array.
PIPE=objectFifo
TILE_PIPE=pack-peel
EXTRA_COMPILE_FLAGS=()
if [ "$TARGET" = npu1_4col ]; then
  EXTRA_COMPILE_FLAGS+=(--iree-amdaie-packet-flow-strategy=none)
  if [ "$TYPE" = bf16 ]; then
    PIPE=air
  fi
elif [ "$TARGET" = npu4 ]; then
  EXTRA_COMPILE_FLAGS+=(
    --iree-amdaie-enable-control-packet=true
    --iree-amdaie-packet-flow-strategy=auto
  )
  if [ "$TYPE" = bf16 ]; then
    TILE_PIPE=pack-peel-4-level-tiling
    EXTRA_COMPILE_FLAGS+=(
      --iree-amdaie-enable-ukernels=all
      --iree-amd-aie-enable-chess-for-ukernel=0
      --iree-amdaie-stack-size=3072
    )
  fi
fi

TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || {
  echo "temporary directory is unavailable: ${TMPDIR:-/tmp}" >&2
  exit 1
}
WORK="$(mktemp -d "$TMP_ROOT/ryzen-npu-matmul.XXXXXX")"
TEMP_VMFB=""
cleanup() {
  [ -z "$TEMP_VMFB" ] || rm -f -- "$TEMP_VMFB"
  if [[ "$WORK" == "$TMP_ROOT"/ryzen-npu-matmul.* ]] && [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
  else
    echo "refusing to remove unexpected work path: $WORK" >&2
  fi
}
trap cleanup EXIT
# IREE helpers can leave tmpRunTool-* and amdaie_pdi_fb-* directories. Keep all
# of them inside this invocation's private directory so the same trap owns them.
export TMPDIR="$WORK"

MLIR="$WORK/matmul.mlir"
if [ -n "${VMFB_OUT:-}" ]; then
  VMFB_FINAL="$VMFB_OUT"
  VMFB_DIR="$(dirname "$VMFB_FINAL")"
  VMFB_NAME="$(basename "$VMFB_FINAL")"
  mkdir -p "$VMFB_DIR"
  VMFB="$(mktemp "$VMFB_DIR/.${VMFB_NAME}.XXXXXX.vmfb")"
else
  VMFB_FINAL=""
  VMFB="$WORK/matmul.vmfb"
fi
TEMP_VMFB="$VMFB"

cat > "$MLIR" <<EOF
func.func @matmul(%a: tensor<${M}x${K}x${ETYPE}>, %b: tensor<${K}x${N}x${ETYPE}>) -> tensor<${M}x${N}x${ACC}> {
  %c0 = arith.constant ${ZERO}
  %init = tensor.empty() : tensor<${M}x${N}x${ACC}>
  %fill = linalg.fill ins(%c0 : ${ACC}) outs(%init : tensor<${M}x${N}x${ACC}>) -> tensor<${M}x${N}x${ACC}>
  %r = linalg.matmul ins(%a, %b : tensor<${M}x${K}x${ETYPE}>, tensor<${K}x${N}x${ETYPE}>)
                     outs(%fill : tensor<${M}x${N}x${ACC}>) -> tensor<${M}x${N}x${ACC}>
  return %r : tensor<${M}x${N}x${ACC}>
}
EOF

echo ">> Compiling ${M}x${N}x${K} ${ETYPE}->${ACC} matmul for ${TARGET} (${PIPE}, ${TILE_PIPE})"
"$IREE/iree-compile" "$MLIR" \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device="$TARGET" \
  --iree-amdaie-lower-to-aie-pipeline="$PIPE" \
  --iree-amdaie-tile-pipeline="$TILE_PIPE" \
  --iree-amd-aie-peano-install-dir="$PEANO" \
  --iree-amd-aie-install-dir="$REPO/iree-install" \
  --iree-amdaie-device-hal=amdxdna \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  "${EXTRA_COMPILE_FLAGS[@]}" \
  -o "$VMFB"

echo ">> Running on the NPU (rows=$ROWS cols=$COLS, A=$A B=$B)"
"$IREE/iree-run-module" --module="$VMFB" --device=amdxdna \
  --amdxdna_n_core_rows="$ROWS" --amdxdna_n_core_cols="$COLS" \
  --function=matmul \
  "--input=${M}x${K}x${ETYPE}=$A" \
  "--input=${K}x${N}x${ETYPE}=$B" \
  "--expected_output=${M}x${N}x${ACC}=$EXPECTED" \
  --equality_mode=exact \
  --output_max_element_count=16
echo "   verified every output element against CPU reference $EXPECTED"

if [ "${BENCH:-0}" = "1" ]; then
  echo ">> Benchmark"
  "$IREE/iree-benchmark-module" --module="$VMFB" --device=amdxdna \
    --amdxdna_n_core_rows="$ROWS" --amdxdna_n_core_cols="$COLS" \
    --function=matmul \
    "--input=${M}x${K}x${ETYPE}=$A" \
    "--input=${K}x${N}x${ETYPE}=$B" \
    --benchmark_repetitions=5 2>&1 | grep -iE 'real_time_mean|items_per' | head -2
fi

if [ -n "$VMFB_FINAL" ]; then
  # Publish only after compilation, full CPU-reference validation, and any
  # requested benchmark succeed. A failure never leaves a new partial VMFB at
  # the path that an application will later trust.
  mv -f -- "$TEMP_VMFB" "$VMFB_FINAL"
  echo ">> Kept verified compiled module: $VMFB_FINAL"
fi
