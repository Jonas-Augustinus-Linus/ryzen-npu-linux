#!/usr/bin/env bash
# mlir-aie-env.sh — source me to put the Xilinx/mlir-aie (IRON) toolchain on PATH
# for the XDNA1 NPU. Activates the venv, exposes Peano, and sources mlir-aie's own
# env_setup.sh the RIGHT way (no pipe — a pipe runs it in a subshell and the
# exports vanish; see docs/GOTCHAS.md → mlir-aie track).
#
#   source scripts/mlir-aie-env.sh
#
# Env overrides:
#   MLIR_AIE_DIR (default ~/src/mlir-aie)      mlir-aie clone (from setup-mlir-aie.sh)
#   VENV         (default ~/src/mlir-aie-venv) python 3.14 venv
#   IREE_REPO    (default ~/src/iree-amd-aie)  source of the reusable Peano
MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"
VENV="${VENV:-$HOME/src/mlir-aie-venv}"
IREE_REPO="${IREE_REPO:-$HOME/src/iree-amd-aie}"

# mlir-aie's utils/env_setup.sh (and the venv activate) are not written to be safe
# under `set -e`/`set -u`. If a caller sourced us with those on, relax them for the
# duration and restore the caller's exact flags at the end.
_MAE_FLAGS="$-"
set +eu

# shellcheck disable=SC1091
source "$VENV/bin/activate"
_SITE="$(python -c 'import site;print(site.getsitepackages()[0])')"

# Peano: reuse the one you built for iree-amd-aie; else fall back to the pip wheel.
if [ -x "$IREE_REPO/llvm-aie/bin/clang" ]; then
  _PEANO="$IREE_REPO/llvm-aie"
else
  _PEANO="$(pip show llvm-aie 2>/dev/null | awk '/^Location:/{print $2}')/llvm-aie"
fi

# IMPORTANT: redirect, never pipe. `source env_setup.sh ... | tail` => subshell =>
# PEANO_INSTALL_DIR/MLIR_AIE_INSTALL_DIR/NPU2 are lost.
source "$MLIR_AIE_DIR/utils/env_setup.sh" "$_SITE/mlir_aie" "$_PEANO" >/dev/null 2>&1

echo "[mlir-aie env] NPU2=${NPU2:-?} (0=Phoenix/XDNA1)  PEANO=${PEANO_INSTALL_DIR:-unset}"

# Restore the caller's shell strictness.
case "$_MAE_FLAGS" in *e*) set -e ;; esac
case "$_MAE_FLAGS" in *u*) set -u ;; esac
