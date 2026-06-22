#!/usr/bin/env bash
# run-matmul.sh — Compile a matmul and RUN IT ON THE XDNA1 NPU. The verified
# recipe (Ryzen 7840U / Phoenix, kernel 7.0). Supports i32 and bf16.
#
# Usage:
#   scripts/run-matmul.sh                      # default: i32 128x128x128, A=2 B=3 -> 768
#   scripts/run-matmul.sh bf16                 # bf16 256x256x256, A=2 B=3 -> 1536 (f32 acc)
#   scripts/run-matmul.sh i32  256 256 256 4 5 # type M N K A B
#   TYPE=bf16 M=512 N=512 K=512 scripts/run-matmul.sh
#
# Env overrides: REPO, VENV, BENCH=1 (also run iree-benchmark-module)
set -euo pipefail

REPO="${REPO:-$HOME/src/iree-amd-aie}"
VENV="${VENV:-$HOME/src/iree-aie-venv}"
IREE="$REPO/iree-install/bin"
PEANO="$REPO/llvm-aie"

TYPE="${1:-${TYPE:-i32}}"
# Defaults differ by type; bf16 likes larger shapes with the 'air' pipeline.
if [ "$TYPE" = "bf16" ]; then DM=256; DN=256; DK=256; else DM=128; DN=128; DK=128; fi
M="${2:-${M:-$DM}}"; N="${3:-${N:-$DN}}"; K="${4:-${K:-$DK}}"
A="${5:-${A:-2}}"; B="${6:-${B:-3}}"

case "$TYPE" in
  i32)  ETYPE=i32;  ACC=i32;  ZERO="0 : i32";   PIPE=objectFifo ;;
  bf16) ETYPE=bf16; ACC=f32;  ZERO="0.0 : f32"; PIPE=air ;;
  *) echo "unknown TYPE '$TYPE' (use i32 or bf16)"; exit 1 ;;
esac

[ -d "$VENV" ] && source "$VENV/bin/activate"

# Device geometry. CRITICAL: cols for Phoenix is 4 (npu1_4col), even though raw
# metadata reports 5. Pass 5 and the cores hang -> "ert state 8" timeout.
ROWS=4; COLS=4
HELP="$REPO/build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py"
if [ -f "$HELP" ]; then
  R=$(python "$HELP" --num-rows 2>/dev/null || true); C=$(python "$HELP" --num-cols 2>/dev/null || true)
  [[ "$R" =~ ^[0-9]+$ ]] && ROWS=$R; [[ "$C" =~ ^[0-9]+$ ]] && COLS=$C
fi

MLIR=$(mktemp --suffix=.mlir); VMFB=$(mktemp --suffix=.vmfb)
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

echo ">> Compiling ${M}x${N}x${K} ${ETYPE}->${ACC} matmul for npu1_4col (${PIPE} pipeline)"
"$IREE/iree-compile" "$MLIR" \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device=npu1_4col \
  --iree-amdaie-lower-to-aie-pipeline="$PIPE" \
  --iree-amdaie-tile-pipeline=pack-peel \
  --iree-amd-aie-peano-install-dir="$PEANO" \
  --iree-amd-aie-install-dir="$REPO/iree-install" \
  --iree-amdaie-packet-flow-strategy=none \
  --iree-amdaie-device-hal=amdxdna \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  -o "$VMFB"

echo ">> Running on the NPU (rows=$ROWS cols=$COLS, A=$A B=$B)"
"$IREE/iree-run-module" --module="$VMFB" --device=amdxdna \
  --amdxdna_n_core_rows="$ROWS" --amdxdna_n_core_cols="$COLS" \
  --function=matmul --input=${M}x${K}x${ETYPE}=$A --input=${K}x${N}x${ETYPE}=$B \
  | head -3 | cut -c1-100
echo "   (expected every element = K*A*B = $K*$A*$B = $(python3 -c "print($K*$A*$B)"))"

if [ "${BENCH:-0}" = "1" ]; then
  echo ">> Benchmark"
  "$IREE/iree-benchmark-module" --module="$VMFB" --device=amdxdna \
    --amdxdna_n_core_rows="$ROWS" --amdxdna_n_core_cols="$COLS" \
    --function=matmul --input=${M}x${K}x${ETYPE}=$A --input=${K}x${N}x${ETYPE}=$B \
    --benchmark_repetitions=5 2>&1 | grep -iE 'real_time_mean|items_per' | head -2
fi
rm -f "$MLIR" "$VMFB"
