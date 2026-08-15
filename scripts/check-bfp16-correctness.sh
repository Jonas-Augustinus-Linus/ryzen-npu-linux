#!/usr/bin/env bash
# Reproduce the native bfp16ebs8 GEMM checks against the host CPU reference.
#
# This is a correctness sweep, not a CPU-vs-NPU speed comparison.  The upstream
# C++ host uses a fixed random seed and checks the NPU result against a float
# reference.  Known failures are asserted as failures so a compiler/runtime
# error cannot be mistaken for the numerical boundary documented by this repo.
#
# Usage:
#   ./scripts/check-bfp16-correctness.sh          # complete documented sweep
#   ./scripts/check-bfp16-correctness.sh --quick  # two known-good sizes only
#
# Env overrides:
#   MLIR_AIE_DIR  mlir-aie v1.4.1 checkout (default: ~/src/mlir-aie)
#   LOG_DIR       directory for per-case logs (default: a fresh /tmp directory)
#   ALLOW_UNPINNED=1 permits a checkout other than the verified v1.4.1 tag
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"
EXAMPLE="$MLIR_AIE_DIR/programming_examples/ml/block_datatypes/matrix_multiplication/whole_array"
VERIFIED_TAG="v1.4.1"

die() {
  printf '[bfp16 correctness] %s\n' "$*" >&2
  exit 1
}

case "${1:---full}" in
  --full)
    cases=(
      "512 512 512 PASS"
      "1024 1024 1024 PASS"
      "1024 1216 1024 PASS"
      "1024 1280 1024 FAIL"
      "2048 2048 2048 FAIL"
    )
    ;;
  --quick)
    cases=(
      "512 512 512 PASS"
      "1024 1024 1024 PASS"
    )
    ;;
  -h|--help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    die "unknown option: $1 (use --full or --quick)"
    ;;
esac

[[ -d "$EXAMPLE" ]] || die "example not found: $EXAMPLE (run setup-mlir-aie.sh first)"
command -v git >/dev/null || die "git is required"
command -v make >/dev/null || die "make is required"
command -v tee >/dev/null || die "tee is required"

source_tag="$(git -C "$MLIR_AIE_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$source_tag" != "$VERIFIED_TAG" && "${ALLOW_UNPINNED:-0}" != "1" ]]; then
  die "expected mlir-aie $VERIFIED_TAG, found ${source_tag:-an untagged checkout}; set ALLOW_UNPINNED=1 to test it explicitly"
fi
if [[ -n "$(git -C "$MLIR_AIE_DIR" status --porcelain --untracked-files=normal)" \
      && "${ALLOW_UNPINNED:-0}" != "1" ]]; then
  die "mlir-aie checkout has local changes; use a clean $VERIFIED_TAG checkout or set ALLOW_UNPINNED=1"
fi

# shellcheck disable=SC1091
source "$HERE/mlir-aie-env.sh"
[[ "${NPU2:-0}" == "1" ]] || die "native bfp16ebs8 whole-array design requires an XDNA2/NPU2 device"

LOG_DIR="${LOG_DIR:-$(mktemp -d /tmp/ryzen-npu-bfp16-check.XXXXXX)}"
mkdir -p "$LOG_DIR"
printf '[bfp16 correctness] source=%s device=npu2 columns=8 logs=%s\n' \
  "${source_tag:-unversioned}" "$LOG_DIR"

unexpected=0
for spec in "${cases[@]}"; do
  read -r M K N expected <<<"$spec"
  label="${M}x${K}x${N}"
  log="$LOG_DIR/$label.log"
  printf '\n=== %s (expected %s) ===\n' "$label" "$expected"

  # The upstream target name omits n_aie_cols.  Cleaning prevents a cached
  # four-column xclbin from being reused for this eight-column check.
  make -C "$EXAMPLE" clean >/dev/null 2>&1 || \
    die "could not clean cached artifacts before $label"
  set +e
  make -C "$EXAMPLE" \
    devicename=npu2 n_aie_cols=8 \
    M="$M" K="$K" N="$N" m=64 k=64 n=64 \
    runargs='-v 2 --warmup 1 --iters 1' run 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e

  observed="ERROR"
  if [[ $status -eq 0 ]] && grep -q '^PASS!$' "$log"; then
    observed="PASS"
  elif [[ $status -ne 0 ]] && grep -q '^Failed\.$' "$log"; then
    observed="FAIL"
  fi

  if [[ "$observed" == "$expected" ]]; then
    printf '[bfp16 correctness] %s: %s (as expected)\n' "$label" "$observed"
  else
    printf '[bfp16 correctness] %s: expected %s, observed %s (make status %d)\n' \
      "$label" "$expected" "$observed" "$status" >&2
    unexpected=$((unexpected + 1))
  fi
done

printf '\n[bfp16 correctness] logs preserved at %s\n' "$LOG_DIR"
if ((unexpected)); then
  die "$unexpected case(s) did not match the verified boundary"
fi
printf '[bfp16 correctness] all cases matched the CPU-reference expectations\n'
