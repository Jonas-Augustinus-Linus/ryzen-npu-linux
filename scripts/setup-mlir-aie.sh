#!/usr/bin/env bash
# setup-mlir-aie.sh — stand up the Xilinx/mlir-aie (IRON) toolkit for the XDNA1 NPU.
#
# A second, higher-level path next to build.sh's iree-amd-aie: instead of compiling
# whole graphs, you author NPU kernels directly (IRON eDSL + aiecc + Peano) and run
# them via pyxrt. It REUSES the Peano (llvm-aie) you already built for iree-amd-aie,
# so it's cheap if you've run build.sh.
#
# Verified: Ryzen 7840U / XDNA1 / Ubuntu 26.04 / kernel 7.0 / Python 3.14 / 2026-06-24.
#
# Usage:   ./scripts/setup-mlir-aie.sh
# Env overrides:
#   MLIR_AIE_DIR (default ~/src/mlir-aie)      clone location
#   VENV         (default ~/src/mlir-aie-venv) python venv
#   IREE_REPO    (default ~/src/iree-amd-aie)  source of the reusable Peano
#   PY           (default python3.14)          MUST match the packaged pyxrt's ABI
set -euo pipefail

MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"
VENV="${VENV:-$HOME/src/mlir-aie-venv}"
IREE_REPO="${IREE_REPO:-$HOME/src/iree-amd-aie}"
PY="${PY:-python3.14}"

say(){ printf '\033[1;36m[mlir-aie]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[mlir-aie] %s\033[0m\n' "$*" >&2; exit 1; }

command -v "$PY"  >/dev/null || die "$PY not found. mlir_aie wheels support Python 3.11-3.14, and Ubuntu's pyxrt is built cpython-314, so use 3.14 (apt install python3.14-venv)."
command -v git    >/dev/null || die "git required"
command -v curl   >/dev/null || die "curl required"

# pyxrt ships with the XRT runtime packages (python3-xrt); run_py needs it.
PYXRT_SO="$(ls /usr/lib/python3/dist-packages/pyxrt*.so 2>/dev/null | head -n1 || true)"
[ -n "$PYXRT_SO" ] || die "pyxrt not found — install the XRT runtime first: sudo apt install python3-xrt libxrt-utils-npu (or run ./scripts/enable-npu.sh)."

# 1. Clone mlir-aie at the latest release tag (examples must match the wheel version).
TAG="$(curl -s https://api.github.com/repos/Xilinx/mlir-aie/releases/latest \
        | (jq -r .tag_name 2>/dev/null || python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])'))"
[ -n "$TAG" ] && [ "$TAG" != "null" ] || die "could not resolve the latest mlir-aie release tag"
say "latest mlir-aie release: $TAG"
if [ ! -d "$MLIR_AIE_DIR/.git" ]; then
  say "cloning Xilinx/mlir-aie@$TAG -> $MLIR_AIE_DIR"
  git clone --branch "$TAG" --depth 1 https://github.com/Xilinx/mlir-aie.git "$MLIR_AIE_DIR"
else
  say "reusing existing clone at $MLIR_AIE_DIR ($(git -C "$MLIR_AIE_DIR" describe --tags --always 2>/dev/null || echo unknown))"
fi

# 2. Python 3.14 venv (clean) + expose the packaged pyxrt by symlink.
if [ ! -x "$VENV/bin/python" ]; then
  say "creating venv ($PY) -> $VENV"
  "$PY" -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel >/dev/null
SITE="$(python -c 'import site;print(site.getsitepackages()[0])')"
ln -sf "$PYXRT_SO" "$SITE/"
python -c "import pyxrt" 2>/dev/null && say "pyxrt visible in venv ($(basename "$PYXRT_SO")) ✓" \
  || die "pyxrt symlink failed — $PY must match the pyxrt ABI ($(basename "$PYXRT_SO"))."

# 3. mlir_aie wheel matching the cloned tag + CPU torch (golden ref for ml/* examples).
TAGNOV="${TAG#v}"
say "installing mlir_aie==$TAGNOV"
python -m pip install "mlir_aie==$TAGNOV" -f "https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${TAG}"
python -c "import torch" 2>/dev/null || {
  say "installing CPU torch (ml/* examples check NPU output against a torch reference)"
  python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
}

# 4. Peano: reuse iree-amd-aie's if present, else the llvm-aie nightly wheel.
if [ -x "$IREE_REPO/llvm-aie/bin/clang" ]; then
  say "reusing Peano from $IREE_REPO/llvm-aie ✓"
else
  say "iree-amd-aie Peano not found — installing the llvm-aie nightly wheel"
  python -m pip install llvm-aie -f https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly
fi

say "done."
echo
echo "  Run an example ON THE NPU:"
echo "    ./scripts/run-mlir-example.sh ml/conv2d"
echo "    ./scripts/run-mlir-example.sh basic/passthrough_kernel"
echo "  Custom fused kernel:"
echo "    ./examples/mlir-aie/relu_add/run.sh"
echo "  Full guide: docs/MLIR-AIE.md"
