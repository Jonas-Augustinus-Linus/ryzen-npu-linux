#!/usr/bin/env bash
# mlir-aie-env.sh — source me to put the Xilinx/mlir-aie (IRON) toolchain on PATH
# for the NPU (XDNA1 or XDNA2). Activates the venv, exposes Peano, and sources
# mlir-aie's own env_setup.sh the RIGHT way (no pipe — a pipe runs it in a
# subshell and the exports vanish; see docs/GOTCHAS.md → mlir-aie track).
# env_setup.sh probes xrt-smi and exports NPU2 (0 = Phoenix npu1, 1 = Strix
# family npu2); aiecc then targets aie2 or aie2p automatically per design.
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
# duration and restore both flags on every success/error path.
_MAE_FLAGS="$-"
set +eu

_mae_error() {
  printf '[mlir-aie env] ERROR: %s\n' "$*" >&2
}

_mae_setup() {
  local activate env_setup requirements site mlir_install
  local source_tag expected_wheel wheel_version
  local peano_version peano_commit peano iree_metadata pip_version

  activate="$VENV/bin/activate"
  env_setup="$MLIR_AIE_DIR/utils/env_setup.sh"
  requirements="$MLIR_AIE_DIR/utils/peano-requirements.txt"

  [ -f "$activate" ] || {
    _mae_error "venv activation script not found: $activate (run scripts/setup-mlir-aie.sh)"
    return 1
  }
  [ -x "$VENV/bin/python" ] || {
    _mae_error "venv Python not found or not executable: $VENV/bin/python"
    return 1
  }
  [ -f "$env_setup" ] || {
    _mae_error "mlir-aie environment source not found: $env_setup"
    return 1
  }
  [ -r "$requirements" ] || {
    _mae_error "Peano requirements not found: $requirements"
    return 1
  }

  site="$("$VENV/bin/python" -c \
    'import site; print(site.getsitepackages()[0])' 2>/dev/null)" || {
      _mae_error "could not resolve site-packages from $VENV/bin/python"
      return 1
    }
  mlir_install="$site/mlir_aie"
  [ -d "$mlir_install" ] || {
    _mae_error "mlir_aie is missing from the venv: $mlir_install"
    return 1
  }

  source_tag="$(git -C "$MLIR_AIE_DIR" describe --tags --exact-match HEAD \
    2>/dev/null || true)"
  case "$source_tag" in
    v*) expected_wheel="${source_tag#v}" ;;
    *)
      _mae_error "$MLIR_AIE_DIR must be checked out at an exact release tag"
      return 1
      ;;
  esac
  wheel_version="$("$VENV/bin/python" -c \
    'from importlib.metadata import version; print(version("mlir-aie"))' \
    2>/dev/null || true)"
  if [ "$wheel_version" != "$expected_wheel" ]; then
    _mae_error "source $source_tag requires mlir-aie wheel $expected_wheel, found ${wheel_version:-none} (run scripts/setup-mlir-aie.sh)"
    return 1
  fi

  peano_version="$(sed -nE \
    's/^[[:space:]]*llvm[-_]aie[[:space:]]*==[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "$requirements")"
  case "$peano_version" in
    ""|*$'\n'*)
      _mae_error "expected exactly one pinned llvm-aie==VERSION in $requirements"
      return 1
      ;;
  esac
  peano_commit="${peano_version##*+}"
  iree_metadata="$IREE_REPO/llvm_aie-${peano_version}.dist-info/METADATA"

  # A pip --target Peano can leave stale dist-info behind, so require both the
  # exact wheel version and the expected commit in clang's version banner.
  if [ -x "$IREE_REPO/llvm-aie/bin/clang" ] \
      && [ -r "$iree_metadata" ] \
      && grep -Fqx "Version: $peano_version" "$iree_metadata" \
      && { [ "$peano_commit" = "$peano_version" ] \
           || "$IREE_REPO/llvm-aie/bin/clang" --version 2>/dev/null \
                | grep -Fq "$peano_commit"; }; then
    peano="$IREE_REPO/llvm-aie"
  else
    pip_version="$("$VENV/bin/python" -c \
      'from importlib.metadata import version; print(version("llvm-aie"))' \
      2>/dev/null || true)"
    peano="$site/llvm-aie"
    if [ "$pip_version" != "$peano_version" ] || [ ! -x "$peano/bin/clang" ] \
        || { [ "$peano_commit" != "$peano_version" ] \
             && ! "$peano/bin/clang" --version 2>/dev/null \
                  | grep -Fq "$peano_commit"; }; then
      _mae_error "compatible Peano $peano_version is missing (run scripts/setup-mlir-aie.sh)"
      return 1
    fi
  fi

  # shellcheck disable=SC1091
  source "$activate" || {
    _mae_error "failed to activate venv: $VENV"
    return 1
  }

  # IMPORTANT: redirect, never pipe. A pipe would source in a subshell and lose
  # PEANO_INSTALL_DIR/MLIR_AIE_INSTALL_DIR/NPU2.
  source "$env_setup" "$mlir_install" "$peano" >/dev/null 2>&1 || {
    _mae_error "failed to source $env_setup (check XRT/xrt-smi and the installed toolchain)"
    return 1
  }
  [ -d "${MLIR_AIE_INSTALL_DIR:-}" ] || {
    _mae_error "env_setup.sh did not set a valid MLIR_AIE_INSTALL_DIR"
    return 1
  }
  [ -x "${PEANO_INSTALL_DIR:-}/bin/clang" ] || {
    _mae_error "env_setup.sh did not set a usable PEANO_INSTALL_DIR"
    return 1
  }
  [ -n "${NPU2+x}" ] || {
    _mae_error "env_setup.sh did not set NPU2"
    return 1
  }

  echo "[mlir-aie env] NPU2=$NPU2 (0=Phoenix/XDNA1, 1=Strix/XDNA2)  PEANO=$PEANO_INSTALL_DIR"
}

_mae_restore() {
  local status="$1" flags="$2"
  unset _MAE_FLAGS _MAE_STATUS
  unset -f _mae_error _mae_setup _mae_restore
  case "$flags" in *u*) set -u ;; *) set +u ;; esac
  case "$flags" in *e*) set -e ;; *) set +e ;; esac
  return "$status"
}

if _mae_setup; then
  _MAE_STATUS=0
else
  _MAE_STATUS=$?
fi
_mae_restore "$_MAE_STATUS" "$_MAE_FLAGS"
