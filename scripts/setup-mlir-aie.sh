#!/usr/bin/env bash
# setup-mlir-aie.sh — stand up the Xilinx/mlir-aie (IRON) toolkit for the NPU
# (XDNA1 npu1 and XDNA2 npu2 — the same wheel targets both; env_setup.sh
# auto-detects the generation via xrt-smi and exports NPU2=0/1).
#
# A second, higher-level path next to build.sh's iree-amd-aie: instead of compiling
# whole graphs, you author NPU kernels directly (IRON eDSL + aiecc + Peano) and run
# them via pyxrt. It reuses the Peano (llvm-aie) from iree-amd-aie only when it is
# the exact version pinned by this mlir-aie release.
#
# Verified: Ryzen 7840U / XDNA1 / Ubuntu 26.04 / kernel 7.0 / Python 3.14 / 2026-06-24
#           (mlir-aie 1.3.x) and Ryzen AI 9 HX PRO 370 / XDNA2 Strix Point /
#           Ubuntu 26.04 / kernel 7.0 / Python 3.14 / 2026-08-15 (mlir-aie 1.4.1).
#
# Usage:   ./scripts/setup-mlir-aie.sh
# Env overrides:
#   MLIR_AIE_DIR (default ~/src/mlir-aie)      clone location
#   VENV         (default ~/src/mlir-aie-venv) python venv
#   IREE_REPO    (default ~/src/iree-amd-aie)  source of the reusable Peano
#   PY           (default python3.14)          MUST match the packaged pyxrt's ABI
#   TAG          mlir-aie release tag (default: latest; use v1.4.1 for the
#                pinned correctness checks documented in this repository)
#   ALLOW_DIRTY_MLIR_AIE=1 permits reusing a checkout with local changes
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

# 1. Clone mlir-aie at the selected release tag (examples must match the wheel).
if [ -z "${TAG:-}" ]; then
  TAG="$(curl -s https://api.github.com/repos/Xilinx/mlir-aie/releases/latest \
          | (jq -r .tag_name 2>/dev/null || python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])'))"
else
  say "requested mlir-aie release: $TAG"
fi
[ -n "$TAG" ] && [ "$TAG" != "null" ] || die "could not resolve the latest mlir-aie release tag"
say "selected mlir-aie release: $TAG"
if [ ! -d "$MLIR_AIE_DIR/.git" ]; then
  say "cloning Xilinx/mlir-aie@$TAG -> $MLIR_AIE_DIR"
  git clone --branch "$TAG" --depth 1 https://github.com/Xilinx/mlir-aie.git "$MLIR_AIE_DIR"
else
  CURRENT_TAG="$(git -C "$MLIR_AIE_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  DIRTY="$(git -C "$MLIR_AIE_DIR" status --porcelain --untracked-files=normal)"
  if [ -n "$DIRTY" ] && [ "${ALLOW_DIRTY_MLIR_AIE:-0}" != "1" ]; then
    die "$MLIR_AIE_DIR has local changes. Commit/stash them or set ALLOW_DIRTY_MLIR_AIE=1 to reuse them explicitly; nothing was checked out."
  fi
  if [ "$CURRENT_TAG" != "$TAG" ]; then
    say "updating clean clone from ${CURRENT_TAG:-an untagged commit} to $TAG"
    git -C "$MLIR_AIE_DIR" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
    git -C "$MLIR_AIE_DIR" checkout --detach "$TAG"
  else
    say "reusing existing clone at $MLIR_AIE_DIR ($TAG)"
  fi
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
python -m pip install --upgrade "mlir_aie==$TAGNOV" \
  -f "https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${TAG}"
python -c "import torch" 2>/dev/null || {
  say "installing CPU torch (ml/* examples check NPU output against a torch reference)"
  python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
}

# 4. Peano: use the release's tested pin. An iree-amd-aie copy is safe only if
# both its wheel metadata and clang build commit match that exact pin.
PEANO_REQUIREMENTS="$MLIR_AIE_DIR/utils/peano-requirements.txt"
[ -r "$PEANO_REQUIREMENTS" ] \
  || die "missing Peano requirements for $TAG: $PEANO_REQUIREMENTS"
PEANO_VERSION="$(sed -nE \
  's/^[[:space:]]*llvm[-_]aie[[:space:]]*==[[:space:]]*([^[:space:]#]+).*$/\1/p' \
  "$PEANO_REQUIREMENTS")"
case "$PEANO_VERSION" in
  ""|*$'\n'*) die "expected exactly one pinned llvm-aie==VERSION in $PEANO_REQUIREMENTS" ;;
esac
PEANO_COMMIT="${PEANO_VERSION##*+}"
IREE_PEANO="$IREE_REPO/llvm-aie"
IREE_METADATA="$IREE_REPO/llvm_aie-${PEANO_VERSION}.dist-info/METADATA"

if [ -x "$IREE_PEANO/bin/clang" ] \
    && [ -r "$IREE_METADATA" ] \
    && grep -Fqx "Version: $PEANO_VERSION" "$IREE_METADATA" \
    && { [ "$PEANO_COMMIT" = "$PEANO_VERSION" ] \
         || "$IREE_PEANO/bin/clang" --version 2>/dev/null | grep -Fq "$PEANO_COMMIT"; }; then
  say "reusing compatible Peano $PEANO_VERSION from $IREE_PEANO ✓"
else
  if [ -x "$IREE_PEANO/bin/clang" ]; then
    IREE_VERSION="$(sed -n 's/^Version: //p' "$IREE_REPO"/llvm_aie-*.dist-info/METADATA \
      2>/dev/null | paste -sd, - || true)"
    say "iree-amd-aie Peano ${IREE_VERSION:-version unknown} is incompatible; installing the pinned wheel"
  else
    say "iree-amd-aie Peano not found — installing the pinned wheel"
  fi
  python -m pip install --upgrade -r "$PEANO_REQUIREMENTS"
  INSTALLED_PEANO="$(python -c \
    'from importlib.metadata import version; print(version("llvm-aie"))')"
  [ "$INSTALLED_PEANO" = "$PEANO_VERSION" ] \
    || die "installed llvm-aie $INSTALLED_PEANO, expected $PEANO_VERSION"
  PIP_PEANO="$(python -m pip show llvm-aie \
    | awk '/^Location:/{print $2 "/llvm-aie"}')"
  [ -x "$PIP_PEANO/bin/clang" ] \
    || die "pinned Peano installed but clang is missing from $PIP_PEANO/bin"
  [ "$PEANO_COMMIT" = "$PEANO_VERSION" ] \
    || "$PIP_PEANO/bin/clang" --version 2>/dev/null | grep -Fq "$PEANO_COMMIT" \
    || die "pinned Peano clang does not report expected commit $PEANO_COMMIT"
  say "using pinned Peano $PEANO_VERSION from $PIP_PEANO ✓"
fi

say "done."
echo
echo "  Run an example ON THE NPU:"
echo "    ./scripts/run-mlir-example.sh ml/conv2d"
echo "    ./scripts/run-mlir-example.sh basic/passthrough_kernel"
echo "  Custom fused kernel:"
echo "    ./examples/mlir-aie/relu_add/run.sh"
echo "  Full guide: docs/MLIR-AIE.md"
