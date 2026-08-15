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

REPO="${REPO:-$HOME/src/iree-amd-aie}"
VENV="${VENV:-$HOME/src/iree-aie-venv}"
IREE="$REPO/iree-install/bin"
PEANO="$REPO/llvm-aie"

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

# Detect device generation and usable geometry with iree-amd-aie's own helper.
# It compensates for Phoenix metadata's reserved fifth column and reports 4;
# Strix reports all 8 compute columns. TARGET_DEVICE is an explicit override,
# but this compile-and-run script still requires usable local geometry.
ROWS=""; COLS=""; ARCH=""; VBNV=""
HELP="$REPO/build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py"
if [ -f "$HELP" ]; then
  ARCH=$(python "$HELP" --npu-device 2>/dev/null || true)
  ROWS=$(python "$HELP" --num-rows 2>/dev/null || true)
  COLS=$(python "$HELP" --num-cols 2>/dev/null || true)
fi
for sysfs_device in /sys/bus/pci/drivers/amdxdna/*:*; do
  if [ -r "$sysfs_device/vbnv" ]; then
    VBNV="$(<"$sysfs_device/vbnv")"
    break
  fi
done

if ! [[ "$ROWS" =~ ^[1-9][0-9]*$ && "$COLS" =~ ^[1-9][0-9]*$ ]]; then
  echo "unable to discover NPU geometry with $HELP" >&2
  echo "check that /dev/accel/accel0 is accessible and REPO points to iree-amd-aie" >&2
  exit 1
fi

if [ -n "${TARGET_DEVICE:-}" ]; then
  TARGET="$TARGET_DEVICE"
else
  # The helper currently folds npu4/npu5/npu6 into "Strix". Use the raw VBNV
  # so a future XDNA2 device is not silently compiled with Strix Point's npu4
  # target merely because it also exposes eight columns.
  case "$VBNV:$ROWS:$COLS" in
    RyzenAI-npu1:4:4|NPU\ Phoenix:4:4) TARGET=npu1_4col ;;
    RyzenAI-npu4:4:8|NPU\ Strix:4:8)   TARGET=npu4 ;;
    *)
      echo "unsupported NPU identity/geometry: vbnv='${VBNV:-unknown}' arch='${ARCH:-unknown}' rows=$ROWS cols=$COLS" >&2
      echo "set TARGET_DEVICE=npu1_4col or TARGET_DEVICE=npu4 only for explicitly known-compatible hardware" >&2
      exit 1
      ;;
  esac
fi

case "$TARGET" in
  npu1_4col|npu4) ;;
  *) echo "unsupported TARGET_DEVICE '$TARGET' (use npu1_4col or npu4)" >&2; exit 1 ;;
esac
case "$TARGET:$ROWS:$COLS" in
  npu1_4col:4:4|npu4:4:8) ;;
  *)
    echo "target $TARGET is incompatible with discovered geometry ${ROWS}x${COLS}" >&2
    exit 1
    ;;
esac

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

MLIR=$(mktemp --suffix=.mlir)
if [ -n "${VMFB_OUT:-}" ]; then
  VMFB="$VMFB_OUT"
  KEEP_VMFB=1
else
  VMFB=$(mktemp --suffix=.vmfb)
  KEEP_VMFB=0
fi
cleanup() {
  rm -f "$MLIR"
  [ "$KEEP_VMFB" = 1 ] || rm -f "$VMFB"
}
trap cleanup EXIT

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

if [ "$KEEP_VMFB" = 1 ]; then
  echo ">> Kept compiled module: $VMFB"
fi
