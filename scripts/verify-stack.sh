#!/usr/bin/env bash
# One-command hardware acceptance test for the public XDNA1/XDNA2 stack.
#
# Usage: scripts/verify-stack.sh [--quick|--full] [--keep-work]
#   --quick      detect, CPU-reference i32/bf16, native and Python runners
#   --full       quick checks plus wake-word, ONNX MLP, and XDNA2 IRON bfp16 checks
#   --keep-work  retain the generated VMFB and logs printed at exit
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
IREE_ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
IREE_VENV="${IREE_VENV:-$HOME/src/iree-aie-venv}"
MODE=quick
KEEP_WORK=0

for arg in "$@"; do
  case "$arg" in
    --quick) MODE=quick ;;
    --full) MODE=full ;;
    --keep-work) KEEP_WORK=1 ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf '[verify-stack] unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

die() {
  printf '[verify-stack] FAIL: %s\n' "$*" >&2
  exit 1
}

for executable in \
  "$IREE_ROOT/iree-install/bin/iree-compile" \
  "$IREE_ROOT/iree-install/bin/iree-run-module" \
  "$IREE_VENV/bin/python"; do
  [ -x "$executable" ] || die "missing executable: $executable (run scripts/build.sh)"
done

TMP_ROOT="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" \
  || die "temporary directory is unavailable: ${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMP_ROOT/ryzen-npu-verify.XXXXXX")"
cleanup() {
  if [ "$KEEP_WORK" -eq 1 ]; then
    printf '[verify-stack] work retained: %s\n' "$WORK"
  elif [[ "$WORK" == "$TMP_ROOT"/ryzen-npu-verify.* ]] && [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
  else
    printf '[verify-stack] refusing to remove unexpected work path: %s\n' "$WORK" >&2
  fi
}
trap cleanup EXIT
# Some compiler/runtime helpers leave tmpRunTool-* and amdaie_pdi_fb-* behind.
# Contain every child tool's temporary output in WORK so the same trap owns it.
export TMPDIR="$WORK"

printf '=== Ryzen NPU Linux stack verification (%s) ===\n' "$MODE"
"$HERE/check-npu.sh" --strict

DEVICE_JSON="$(IREE_AMD_AIE_ROOT="$IREE_ROOT" "$HERE/detect-npu.sh" --json)"
TARGET="$(IREE_AMD_AIE_ROOT="$IREE_ROOT" "$HERE/detect-npu.sh" --target)"
printf '[verify-stack] device: %s\n' "$DEVICE_JSON"

printf '\n[1/5] i32: compile, run, and compare every element with the CPU reference\n'
IREE_AMD_AIE_ROOT="$IREE_ROOT" REPO="$IREE_ROOT" VENV="$IREE_VENV" \
  VMFB_OUT="$WORK/matmul_i32.vmfb" "$HERE/run-matmul.sh" i32 128 128 128 2 3

printf '\n[2/5] bf16: compile, run, and compare every element with the CPU reference\n'
IREE_AMD_AIE_ROOT="$IREE_ROOT" REPO="$IREE_ROOT" VENV="$IREE_VENV" \
  "$HERE/run-matmul.sh" bf16 256 256 256 2 3

printf '\n[3/5] persistent native runner: build, warm up, invoke, verify all 16,384 outputs\n'
IREE_AMD_AIE_ROOT="$IREE_ROOT" "$PROJECT/tools/npu-runner/build.sh" >/dev/null
"$PROJECT/tools/npu-runner/npu_runner" "$WORK/matmul_i32.vmfb" 10

printf '\n[4/5] persistent Python bridge: build and verify all 16,384 outputs\n'
IREE_AMD_AIE_ROOT="$IREE_ROOT" "$PROJECT/tools/npu-runner/build_lib.sh" >/dev/null
LIBNPU="$PROJECT/tools/npu-runner/libnpu.so" \
  "$IREE_VENV/bin/python" "$PROJECT/tools/npu-runner/npu.py" "$WORK/matmul_i32.vmfb"

printf '\n[5/5] quick hardware contract complete\n'

if [ "$MODE" = full ]; then
  printf '\n[full 1/3] persistent three-dispatch wake-word application\n'
  IREE_AMD_AIE_ROOT="$IREE_ROOT" IREE_VENV="$IREE_VENV" KWS_VENV="$IREE_VENV" \
    KWS_VMFB="$WORK/wake-word.${TARGET}.vmfb" \
    "$PROJECT/examples/wake-word/run.sh" --selftest

  printf '\n[full 2/3] ONNX -> extracted kernels -> NPU/CPU-reference application\n'
  IREE_AMD_AIE_ROOT="$IREE_ROOT" IREE_VENV="$IREE_VENV" \
    "$IREE_VENV/bin/python" "$PROJECT/examples/onnx-mlp/run_onnx_npu.py"

  if [ "$TARGET" = npu4 ]; then
    printf '\n[full 3/3] native bfp16 CPU-reference checks at known-good sizes\n'
    LOG_DIR="$WORK/bfp16" "$HERE/check-bfp16-correctness.sh" --quick
  else
    printf '\n[full 3/3] native bfp16 check skipped (XDNA2-only IRON design; target=%s)\n' "$TARGET"
  fi
fi

printf '\n[verify-stack] PASS: %s verification completed on %s\n' "$MODE" "$DEVICE_JSON"
