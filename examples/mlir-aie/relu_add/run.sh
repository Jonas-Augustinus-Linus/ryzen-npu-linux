#!/usr/bin/env bash
# run.sh — build + run the custom fused relu(a+b) kernel ON THE XDNA1 NPU.
#   ./run.sh
# Needs the mlir-aie track set up first: ../../../scripts/setup-mlir-aie.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO/scripts/mlir-aie-env.sh"
python "$HERE/relu_add.py"
