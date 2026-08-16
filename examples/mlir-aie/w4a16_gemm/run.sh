#!/usr/bin/env bash
# Run the W4A16 GEMM example on the NPU (XDNA2 Strix, 8 columns).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/mlir-aie-env.sh"
cd "$HERE"
python w4a16_gemm.py -M 512 -K 512 -N 512 "$@"
