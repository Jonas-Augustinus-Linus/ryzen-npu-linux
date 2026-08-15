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
#   TAG          mlir-aie release tag (default: versions.lock; changing it also
#                requires ALLOW_VERSION_OVERRIDE=1)
#   UPDATE_MLIR_AIE_CHECKOUT=1 moves a clean clone to the selected locked tag
#   ALLOW_DIRTY_MLIR_AIE=1 permits reusing a checkout with local changes
#   ALLOW_REMOTE_OVERRIDE=1 accepts a non-upstream origin explicitly
#   ALLOW_UNVERIFIED_WHEELS=1 permits an explicit non-Linux/x86_64/tag experiment
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="${VERSIONS_LOCK_FILE:-$PROJECT_ROOT/versions.lock}"

MLIR_AIE_DIR="${MLIR_AIE_DIR:-$HOME/src/mlir-aie}"
VENV="${VENV:-$HOME/src/mlir-aie-venv}"
IREE_REPO="${IREE_REPO:-$HOME/src/iree-amd-aie}"
PY="${PY:-python3.14}"
REQUESTED_TAG="${TAG:-}"

say(){ printf '\033[1;36m[mlir-aie]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[mlir-aie] %s\033[0m\n' "$*" >&2; exit 1; }

[ -r "$LOCK_FILE" ] || die "version lock not found: $LOCK_FILE"
# shellcheck source=../versions.lock
source "$LOCK_FILE"
for pin in VERSIONS_LOCK_FORMAT MLIR_AIE_REPOSITORY MLIR_AIE_TAG \
  MLIR_AIE_COMMIT MLIR_AIE_PEANO_VERSION MLIR_AIE_PEANO_COMMIT \
  MLIR_AIE_PEANO_WHEEL_LINUX_X86_64 MLIR_AIE_PEANO_WHEEL_SHA256 \
  MLIR_AIE_WHEEL_LINUX_X86_64 MLIR_AIE_WHEEL_SHA256 \
  MLIR_AIE_PYTHON_VERSION TORCH_CPU_VERSION PIP_VERSION WHEEL_VERSION; do
  [ -n "${!pin:-}" ] || die "missing $pin in $LOCK_FILE"
done
[ "$VERSIONS_LOCK_FORMAT" = 1 ] \
  || die "unsupported versions.lock format: $VERSIONS_LOCK_FORMAT"

for flag in UPDATE_MLIR_AIE_CHECKOUT ALLOW_DIRTY_MLIR_AIE \
  ALLOW_VERSION_OVERRIDE ALLOW_REMOTE_OVERRIDE ALLOW_UNVERIFIED_WHEELS; do
  case "${!flag:-0}" in
    0|1) ;;
    *) die "$flag must be 0 or 1 (got '${!flag}')" ;;
  esac
done

TAG="${REQUESTED_TAG:-$MLIR_AIE_TAG}"
if [ "$TAG" != "$MLIR_AIE_TAG" ] \
    && [ "${ALLOW_VERSION_OVERRIDE:-0}" != 1 ]; then
  die "TAG=$TAG differs from locked $MLIR_AIE_TAG; set ALLOW_VERSION_OVERRIDE=1 for this deliberate test"
fi

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if { [ "$HOST_OS" != Linux ] || [ "$HOST_ARCH" != x86_64 ]; } \
    && [ "${ALLOW_UNVERIFIED_WHEELS:-0}" != 1 ]; then
  die "locked wheels target Linux x86_64, found $HOST_OS $HOST_ARCH; set ALLOW_UNVERIFIED_WHEELS=1 only for an explicit unsupported-platform experiment"
fi

WHEEL_STAGE=""
cleanup_wheel_stage() {
  if [[ "${WHEEL_STAGE:-}" == /tmp/ryzen-npu-wheel.* ]] \
      && [ -d "$WHEEL_STAGE" ]; then
    rm -rf -- "$WHEEL_STAGE"
  fi
}
trap cleanup_wheel_stage EXIT

download_locked_wheel() {
  local requirement="$1" filename="$2" expected_sha="$3" find_links="$4"
  local -a download_args
  [[ "$filename" != */* ]] && [ -n "$filename" ] \
    || die "invalid locked wheel filename: $filename"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die "invalid SHA-256 for locked wheel $filename"
  command -v sha256sum >/dev/null || die "sha256sum is required"
  WHEEL_STAGE="$(mktemp -d /tmp/ryzen-npu-wheel.XXXXXX)"
  download_args=(--disable-pip-version-check --no-deps --only-binary=:all:
    --dest "$WHEEL_STAGE")
  if [ -n "$find_links" ]; then
    download_args+=(-f "$find_links")
  fi
  python -m pip download "${download_args[@]}" "$requirement"
  DOWNLOADED_WHEEL="$WHEEL_STAGE/$filename"
  [ -f "$DOWNLOADED_WHEEL" ] \
    || die "downloaded wheel filename does not match versions.lock: expected $filename"
  printf '%s  %s\n' "$expected_sha" "$DOWNLOADED_WHEEL" | sha256sum -c -
}

command -v "$PY"  >/dev/null || die "$PY not found. mlir_aie wheels support Python 3.11-3.14, and Ubuntu's pyxrt is built cpython-314, so use 3.14 (apt install python3.14-venv)."
command -v git    >/dev/null || die "git required"
PY_VERSION="$($PY -c 'import platform; print(platform.python_version())')"
PY_MAJOR_MINOR="$($PY -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [ ! -e "$VENV" ] && ! "$PY" -c 'import ensurepip, venv' 2>/dev/null; then
  die "$PY cannot create a seeded venv; install the matching Ubuntu package first: sudo apt install python${PY_MAJOR_MINOR}-venv"
fi
if [ "$PY_VERSION" != "$MLIR_AIE_PYTHON_VERSION" ]; then
  if [ "${ALLOW_VERSION_OVERRIDE:-0}" = 1 ]; then
    say "WARNING: using $PY_VERSION instead of locked Python $MLIR_AIE_PYTHON_VERSION"
  else
    die "$PY reports $PY_VERSION, expected $MLIR_AIE_PYTHON_VERSION (set ALLOW_VERSION_OVERRIDE=1 to test another patch release)"
  fi
fi
if { [ "$TAG" != "$MLIR_AIE_TAG" ] \
      || [ "$PY_VERSION" != "$MLIR_AIE_PYTHON_VERSION" ]; } \
    && [ "${ALLOW_UNVERIFIED_WHEELS:-0}" != 1 ]; then
  die "no locked wheel hash covers TAG=$TAG with Python $PY_VERSION; set ALLOW_UNVERIFIED_WHEELS=1 only for this explicit experiment"
fi

# pyxrt ships with the XRT runtime packages (python3-xrt); run_py needs it.
PYXRT_SO="$(ls /usr/lib/python3/dist-packages/pyxrt*.so 2>/dev/null | head -n1 || true)"
[ -n "$PYXRT_SO" ] || die "pyxrt not found — install the XRT runtime first: sudo apt install python3-xrt libxrt-utils-npu (or run ./scripts/enable-npu.sh)."

# 1. Clone mlir-aie at the selected locked release (source and wheel must match).
say "selected mlir-aie release: $TAG"
if [ ! -d "$MLIR_AIE_DIR/.git" ]; then
  [ ! -e "$MLIR_AIE_DIR" ] \
    || die "$MLIR_AIE_DIR exists but is not a git checkout; move it aside and rerun"
  say "cloning Xilinx/mlir-aie@$TAG -> $MLIR_AIE_DIR"
  git clone --branch "$TAG" --depth 1 "$MLIR_AIE_REPOSITORY" "$MLIR_AIE_DIR"
else
  MLIR_REMOTE="$(git -C "$MLIR_AIE_DIR" remote get-url origin 2>/dev/null || true)"
  case "$MLIR_REMOTE" in
    "$MLIR_AIE_REPOSITORY"|"${MLIR_AIE_REPOSITORY%.git}"|git@github.com:Xilinx/mlir-aie.git|ssh://git@github.com/Xilinx/mlir-aie.git) ;;
    *)
      [ "${ALLOW_REMOTE_OVERRIDE:-0}" = 1 ] \
        || die "$MLIR_AIE_DIR origin is '${MLIR_REMOTE:-missing}', expected $MLIR_AIE_REPOSITORY (set ALLOW_REMOTE_OVERRIDE=1 only if intentional)"
      say "WARNING: accepting non-upstream mlir-aie origin: $MLIR_REMOTE"
      ;;
  esac
  DIRTY="$(git -C "$MLIR_AIE_DIR" status --porcelain --untracked-files=normal)"
  if [ -n "$DIRTY" ] && [ "${ALLOW_DIRTY_MLIR_AIE:-0}" != "1" ]; then
    die "$MLIR_AIE_DIR has local changes. Commit/stash them or set ALLOW_DIRTY_MLIR_AIE=1 to reuse them explicitly; nothing was checked out."
  fi
  if ! git -C "$MLIR_AIE_DIR" rev-parse --verify --quiet "refs/tags/$TAG^{commit}" >/dev/null; then
    git -C "$MLIR_AIE_DIR" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
  fi
fi

TAG_COMMIT="$(git -C "$MLIR_AIE_DIR" rev-parse "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
[ -n "$TAG_COMMIT" ] || die "could not resolve source tag $TAG"
if [ "$TAG" = "$MLIR_AIE_TAG" ] && [ "$TAG_COMMIT" != "$MLIR_AIE_COMMIT" ]; then
  die "$TAG resolves to $TAG_COMMIT, expected locked commit $MLIR_AIE_COMMIT"
fi
CURRENT_COMMIT="$(git -C "$MLIR_AIE_DIR" rev-parse HEAD)"
if [ "$CURRENT_COMMIT" != "$TAG_COMMIT" ]; then
  if [ "${UPDATE_MLIR_AIE_CHECKOUT:-0}" = 1 ]; then
    [ -z "${DIRTY:-}" ] \
      || die "UPDATE_MLIR_AIE_CHECKOUT=1 refuses a dirty checkout; commit/stash changes first"
    say "moving clean clone from $CURRENT_COMMIT to $TAG ($TAG_COMMIT)"
    git -C "$MLIR_AIE_DIR" checkout --detach "$TAG_COMMIT"
  else
    die "$MLIR_AIE_DIR is at $CURRENT_COMMIT, expected $TAG_COMMIT; use UPDATE_MLIR_AIE_CHECKOUT=1 on a clean clone"
  fi
fi
[ "$(git -C "$MLIR_AIE_DIR" rev-parse HEAD)" = "$TAG_COMMIT" ] \
  || die "mlir-aie checkout changed unexpectedly"
say "source locked: $TAG ($TAG_COMMIT)"

# 2. Python 3.14 venv (clean) + expose the packaged pyxrt by symlink.
if [ -x "$VENV/bin/python" ]; then
  VENV_PYTHON_VERSION="$("$VENV/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  if [ "$VENV_PYTHON_VERSION" != "$MLIR_AIE_PYTHON_VERSION" ] \
      && [ "${ALLOW_VERSION_OVERRIDE:-0}" != 1 ]; then
    die "$VENV uses Python ${VENV_PYTHON_VERSION:-unknown}, expected $MLIR_AIE_PYTHON_VERSION; move it aside and rerun"
  fi
  if [ "$VENV_PYTHON_VERSION" != "$MLIR_AIE_PYTHON_VERSION" ]; then
    [ "${ALLOW_UNVERIFIED_WHEELS:-0}" = 1 ] \
      || die "$VENV Python $VENV_PYTHON_VERSION has no locked wheel hash; set ALLOW_UNVERIFIED_WHEELS=1 only for this explicit experiment"
    say "WARNING: venv Python $VENV_PYTHON_VERSION is outside the locked wheel platform"
  fi
elif [ -e "$VENV" ]; then
  die "$VENV exists but is not a usable Python venv; move it aside and rerun"
else
  say "creating venv ($PY) -> $VENV"
  "$PY" -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade "pip==$PIP_VERSION" "wheel==$WHEEL_VERSION" >/dev/null
SITE="$(python -c 'import site;print(site.getsitepackages()[0])')"
ln -sf "$PYXRT_SO" "$SITE/"
python -c "import pyxrt" 2>/dev/null && say "pyxrt visible in venv ($(basename "$PYXRT_SO")) ✓" \
  || die "pyxrt symlink failed — $PY must match the pyxrt ABI ($(basename "$PYXRT_SO"))."

# 3. mlir_aie wheel matching the cloned tag + CPU torch (golden ref for ml/* examples).
TAGNOV="${TAG#v}"
say "installing mlir_aie==$TAGNOV"
if [ "$HOST_OS" = Linux ] && [ "$HOST_ARCH" = x86_64 ] \
    && [ "$TAG" = "$MLIR_AIE_TAG" ] \
    && [ "$PY_VERSION" = "$MLIR_AIE_PYTHON_VERSION" ]; then
  download_locked_wheel "mlir_aie==$TAGNOV" \
    "$MLIR_AIE_WHEEL_LINUX_X86_64" "$MLIR_AIE_WHEEL_SHA256" \
    "https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${TAG}"
  # Resolve declared dependencies, then force the package payload itself to come
  # from the hash-checked local wheel even when the same version already exists.
  python -m pip install --upgrade "$DOWNLOADED_WHEEL"
  python -m pip install --force-reinstall --no-deps "$DOWNLOADED_WHEEL"
  cleanup_wheel_stage
  WHEEL_STAGE=""
else
  say "WARNING: installing mlir_aie without a locked wheel hash"
  python -m pip install --upgrade "mlir_aie==$TAGNOV" \
    -f "https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${TAG}"
fi
INSTALLED_MLIR_AIE="$(python -c \
  'from importlib.metadata import version; print(version("mlir-aie"))')"
[ "$INSTALLED_MLIR_AIE" = "$TAGNOV" ] \
  || die "installed mlir-aie $INSTALLED_MLIR_AIE, expected $TAGNOV"
say "installing locked CPU torch $TORCH_CPU_VERSION (golden references)"
python -m pip install --upgrade "torch==$TORCH_CPU_VERSION" \
  --index-url https://download.pytorch.org/whl/cpu
INSTALLED_TORCH="$(python -c \
  'from importlib.metadata import version; print(version("torch"))')"
[ "$INSTALLED_TORCH" = "$TORCH_CPU_VERSION" ] \
  || die "installed torch $INSTALLED_TORCH, expected $TORCH_CPU_VERSION"
python -c 'import torch' 2>/dev/null \
  || die "torch $TORCH_CPU_VERSION is installed but cannot be imported"

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
if [ "$TAG" = "$MLIR_AIE_TAG" ]; then
  [ "$PEANO_VERSION" = "$MLIR_AIE_PEANO_VERSION" ] \
    || die "$TAG source pins Peano $PEANO_VERSION, expected $MLIR_AIE_PEANO_VERSION from versions.lock"
  [ "$PEANO_COMMIT" = "$MLIR_AIE_PEANO_COMMIT" ] \
    || die "$TAG source pins Peano commit $PEANO_COMMIT, expected $MLIR_AIE_PEANO_COMMIT"
else
  say "WARNING: version override uses $TAG's own Peano pin $PEANO_VERSION"
fi
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
  if [ "$HOST_OS" = Linux ] && [ "$HOST_ARCH" = x86_64 ] \
      && [ "$TAG" = "$MLIR_AIE_TAG" ]; then
    download_locked_wheel "llvm-aie==$PEANO_VERSION" \
      "$MLIR_AIE_PEANO_WHEEL_LINUX_X86_64" \
      "$MLIR_AIE_PEANO_WHEEL_SHA256" \
      https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly
    python -m pip install --force-reinstall --no-deps --no-index "$DOWNLOADED_WHEEL"
    cleanup_wheel_stage
    WHEEL_STAGE=""
  else
    say "WARNING: installing Peano without a locked wheel hash"
    python -m pip install --upgrade --no-deps --only-binary=:all: \
      "llvm-aie==$PEANO_VERSION" \
      -f https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly
  fi
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

[ "$(git -C "$MLIR_AIE_DIR" rev-parse HEAD)" = "$TAG_COMMIT" ] \
  || die "mlir-aie source moved during setup"
if ! PIP_CHECK_OUTPUT="$(python -m pip check 2>&1)"; then
  # Older nightly Peano wheels carried a cp310 tag even though their payload is
  # a standalone compiler and works on every supported host Python. Accept only
  # that one known metadata warning; all dependency errors remain fatal.
  UNEXPECTED_PIP_CHECK="$(printf '%s\n' "$PIP_CHECK_OUTPUT" \
    | grep -Fvx "llvm-aie $PEANO_VERSION is not supported on this platform" \
    || true)"
  [ -z "$UNEXPECTED_PIP_CHECK" ] \
    || die "pip dependency check failed: $UNEXPECTED_PIP_CHECK"
  say "Peano compiler validated despite its legacy wheel platform tag"
fi

say "done."
echo
echo "  Run an example ON THE NPU:"
echo "    ./scripts/run-mlir-example.sh ml/conv2d"
echo "    ./scripts/run-mlir-example.sh basic/passthrough_kernel"
echo "  Custom fused kernel:"
echo "    ./examples/mlir-aie/relu_add/run.sh"
echo "  Full guide: docs/MLIR-AIE.md"
