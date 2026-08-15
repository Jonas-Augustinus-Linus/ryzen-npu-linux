#!/usr/bin/env bash
# build.sh — Build iree-amd-aie from source so you can run real compute on AMD
# XDNA1 (Phoenix/Hawk Point) and XDNA2 (Strix Point) NPUs on Linux. Encodes
# every workaround needed as of mid-2026 (see docs/GOTCHAS.md for the why).
#
# Historical path evidence: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04,
#            kernel 7.0, with the then-current nightly. Current v1 exact lock
#            revalidated on Ryzen AI 9 HX PRO 370 (Strix Point / XDNA2),
#            Ubuntu 26.04, kernel 7.0, gcc 15, cmake 4.2, ~30-60 GB disk.
#
# Usage:   scripts/build.sh [SRC_DIR]      (default: ~/src)
# Env:     JOBS=N                         (default: min(nproc, 8), limits OOM risk)
#          CLEAN_BUILD=1                  (discard the CMake/Ninja build cache)
#          UPDATE_IREE_CHECKOUT=1          (move a clean clone to the locked commit)
#          ALLOW_DIRTY_IREE=1              (build a knowingly modified locked clone)
#          IREE_COMMIT=<sha> ALLOW_VERSION_OVERRIDE=1
#                                           (deliberately test another commit)
#          ALLOW_REMOTE_OVERRIDE=1         (accept a non-upstream origin explicitly)
#          ALLOW_UNVERIFIED_WHEELS=1       (non-Linux/x86_64 experiment; no lock hash)
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
LOCK_FILE="${VERSIONS_LOCK_FILE:-$PROJECT_ROOT/versions.lock}"
[ -r "$LOCK_FILE" ] || die "version lock not found: $LOCK_FILE"
# shellcheck source=../versions.lock
source "$LOCK_FILE"

for pin in VERSIONS_LOCK_FORMAT IREE_AMD_AIE_REPOSITORY \
  IREE_AMD_AIE_COMMIT IREE_PEANO_VERSION IREE_PEANO_COMMIT \
  IREE_PEANO_WHEEL_LINUX_X86_64 IREE_PEANO_WHEEL_SHA256 UV_VERSION \
  IREE_PYTHON_VERSION PIP_VERSION WHEEL_VERSION SETUPTOOLS_VERSION \
  NUMPY_VERSION REQUESTS_VERSION SYMPY_VERSION ML_DTYPES_VERSION \
  PYYAML_VERSION PYBIND11_VERSION NANOBIND_VERSION LIT_VERSION; do
  [ -n "${!pin:-}" ] || die "missing $pin in $LOCK_FILE"
done
[ -n "${IREE_BASE_COMPILER_VERSION:-}" ] \
  && [ -n "${IREE_BASE_COMPILER_WHEEL_LINUX_X86_64:-}" ] \
  && [ -n "${IREE_BASE_COMPILER_WHEEL_SHA256:-}" ] \
  && [ -n "${ONNX_VERSION:-}" ] \
  && [ -n "${ONNX_WHEEL_LINUX_X86_64:-}" ] \
  && [ -n "${ONNX_WHEEL_SHA256:-}" ] \
  && [ -n "${PROTOBUF_VERSION:-}" ] \
  && [ -n "${TYPING_EXTENSIONS_VERSION:-}" ] \
  || die "missing ONNX verification pins in $LOCK_FILE"
[ "$VERSIONS_LOCK_FORMAT" = 1 ] \
  || die "unsupported versions.lock format: $VERSIONS_LOCK_FORMAT"

for flag in CLEAN_BUILD UPDATE_IREE_CHECKOUT ALLOW_DIRTY_IREE \
  ALLOW_VERSION_OVERRIDE ALLOW_REMOTE_OVERRIDE ALLOW_UNVERIFIED_WHEELS; do
  case "${!flag:-0}" in
    0|1) ;;
    *) die "$flag must be 0 or 1 (got '${!flag}')" ;;
  esac
done

SRC="${1:-$HOME/src}"
REPO="$SRC/iree-amd-aie"
VENV="$SRC/iree-aie-venv"
IREE_COMMIT="${IREE_COMMIT:-$IREE_AMD_AIE_COMMIT}"
if [ "$IREE_COMMIT" != "$IREE_AMD_AIE_COMMIT" ] \
    && [ "${ALLOW_VERSION_OVERRIDE:-0}" != 1 ]; then
  die "IREE_COMMIT differs from versions.lock; set ALLOW_VERSION_OVERRIDE=1 for this deliberate test"
fi

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if { [ "$HOST_OS" != Linux ] || [ "$HOST_ARCH" != x86_64 ]; } \
    && [ "${ALLOW_UNVERIFIED_WHEELS:-0}" != 1 ]; then
  die "locked wheels target Linux x86_64, found $HOST_OS $HOST_ARCH; set ALLOW_UNVERIFIED_WHEELS=1 only for an explicit unsupported-platform experiment"
fi

WHEEL_STAGE=""
PEANO_STAGE=""
cleanup_stages() {
  if [[ "${WHEEL_STAGE:-}" == /tmp/ryzen-npu-wheel.* ]] \
      && [ -d "$WHEEL_STAGE" ]; then
    rm -rf -- "$WHEEL_STAGE"
  fi
  if [[ "${PEANO_STAGE:-}" == "$SRC"/.ryzen-npu-peano.* ]] \
      && [ -d "$PEANO_STAGE" ]; then
    rm -rf -- "$PEANO_STAGE"
  fi
}
trap cleanup_stages EXIT

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

peano_output_matches() {
  local peano_version="${1:-$IREE_PEANO_VERSION}"
  local peano_commit="${2:-$IREE_PEANO_COMMIT}"
  local metadata="$REPO/llvm_aie-${peano_version}.dist-info/METADATA"
  local record="$REPO/llvm_aie-${peano_version}.dist-info/RECORD"
  local -a metadata_dirs
  [[ "$peano_version" =~ ^[0-9A-Za-z.+_-]+$ ]] || return 1
  [[ "$peano_commit" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  shopt -s nullglob
  metadata_dirs=("$REPO"/llvm_aie-*.dist-info)
  shopt -u nullglob
  [ -x "$REPO/llvm-aie/bin/clang" ] \
    && [ "${#metadata_dirs[@]}" -eq 1 ] \
    && [ -r "$metadata" ] && [ -r "$record" ] \
    && grep -Fqx "Version: $peano_version" "$metadata" \
    && "$REPO/llvm-aie/bin/clang" --version 2>/dev/null \
         | grep -Fq "$peano_commit" \
    && python - "$REPO" "$record" <<'PY'
import base64
import csv
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
record = Path(sys.argv[2]).resolve()
metadata_dir = record.parent
expected = set()

with record.open(newline="", encoding="utf-8") as handle:
    for relative, digest, size in csv.reader(handle):
        if not (relative.startswith("llvm-aie/")
                or relative.startswith(metadata_dir.name + "/")):
            raise SystemExit(1)
        path = (root / relative).resolve()
        try:
            path.relative_to(root)
        except ValueError:
            raise SystemExit(1)
        if not path.is_file():
            raise SystemExit(1)
        expected.add(relative)
        if size and path.stat().st_size != int(size):
            raise SystemExit(1)
        if digest:
            algorithm, encoded = digest.split("=", 1)
            if algorithm != "sha256":
                raise SystemExit(1)
            hasher = hashlib.sha256()
            with path.open("rb") as payload:
                for chunk in iter(lambda: payload.read(1024 * 1024), b""):
                    hasher.update(chunk)
            actual = base64.urlsafe_b64encode(hasher.digest()).rstrip(b"=").decode()
            if actual != encoded:
                raise SystemExit(1)

actual = set()
for top in (root / "llvm-aie", metadata_dir):
    for path in top.rglob("*"):
        if path.is_file() or path.is_symlink():
            actual.add(path.relative_to(root).as_posix())
if actual != expected:
    raise SystemExit(1)
PY
}
NPROC="$(nproc)"
if [ -z "${JOBS+x}" ]; then
  JOBS="$NPROC"
  if [ "$JOBS" -gt 8 ]; then JOBS=8; fi
elif ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: JOBS must be a positive integer (got '${JOBS:-}')." >&2
  exit 2
fi
LINK_JOBS="$JOBS"
if [ "$LINK_JOBS" -gt 4 ]; then LINK_JOBS=4; fi

mkdir -p "$SRC"

echo "== [0/6] System build tools (sudo) =="
# ninja + lld + ccache are required/strongly recommended. cmake>=3.26, a C/C++
# compiler, libudev/uuid dev headers.
sudo apt-get install -y ninja-build lld ccache cmake git \
  build-essential libudev-dev uuid-dev libxrt-dev
for tool in cmake ninja gcc g++ ccache ld.lld git dpkg; do
  command -v "$tool" >/dev/null || die "$tool is missing after package installation"
done
dpkg-query -W -f='${Status}\n' libxrt-dev 2>/dev/null \
  | grep -Fqx 'install ok installed' \
  || die "libxrt-dev is required by the native IRON host checks"
[ -r /usr/include/xrt/xrt_bo.h ] && [ -r /usr/include/xrt/xrt_device.h ] \
  || die "libxrt-dev is installed but required XRT C++ headers are missing"
CMAKE_VERSION="$(cmake --version | awk 'NR==1 {print $3}')"
dpkg --compare-versions "$CMAKE_VERSION" ge 3.26 \
  || die "cmake >=3.26 is required, found $CMAKE_VERSION"
LLD_VERSION="$(ld.lld --version)"
LLD_VERSION="${LLD_VERSION%%$'\n'*}"
CCACHE_VERSION="$(ccache --version)"
CCACHE_VERSION="${CCACHE_VERSION%%$'\n'*}"
echo "  host tools: cmake $CMAKE_VERSION; ninja $(ninja --version); gcc $(gcc -dumpfullversion -dumpversion); $LLD_VERSION; $CCACHE_VERSION"

echo "== [1/6] Isolated Python $IREE_PYTHON_VERSION venv =="
command -v uv >/dev/null || {
  echo "ERROR: uv $UV_VERSION is required and is not auto-installed." >&2
  echo "  Install that exact version from your distro, pipx, or the signed uv release," >&2
  echo "  then rerun. This script intentionally does not execute curl | sh." >&2
  exit 1
}
INSTALLED_UV_VERSION="$(uv --version | awk '{print $2}')"
if [ "$INSTALLED_UV_VERSION" != "$UV_VERSION" ]; then
  if [ "${ALLOW_VERSION_OVERRIDE:-0}" = 1 ]; then
    echo "WARNING: using uv $INSTALLED_UV_VERSION instead of locked $UV_VERSION" >&2
  else
    die "uv $INSTALLED_UV_VERSION found, expected $UV_VERSION (set ALLOW_VERSION_OVERRIDE=1 to test it explicitly)"
  fi
fi
uv python install "$IREE_PYTHON_VERSION"
if [ -x "$VENV/bin/python" ]; then
  VENV_PYTHON="$("$VENV/bin/python" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  if [ "$VENV_PYTHON" != "$IREE_PYTHON_VERSION" ] \
      && [ "${ALLOW_VERSION_OVERRIDE:-0}" != 1 ]; then
    echo "ERROR: existing venv at $VENV uses Python ${VENV_PYTHON:-unknown}, expected $IREE_PYTHON_VERSION." >&2
    echo "  Move it aside or remove that exact venv, then rerun." >&2
    exit 1
  fi
  echo "  reusing Python $VENV_PYTHON venv: $VENV"
elif [ -e "$VENV" ]; then
  echo "ERROR: $VENV exists but is not a usable Python venv; move it aside and rerun." >&2
  exit 1
else
  uv venv --python "$IREE_PYTHON_VERSION" --seed "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade "pip==$PIP_VERSION" "setuptools==$SETUPTOOLS_VERSION" \
  "wheel==$WHEEL_VERSION"

echo "== [2/6] iree-amd-aie locked source (skip 3 heavy, unneeded submodules) =="
if [ ! -d "$REPO/.git" ]; then
  [ ! -e "$REPO" ] || die "$REPO exists but is not a git checkout; move it aside and rerun"
  git clone --filter=blob:none --no-checkout "$IREE_AMD_AIE_REPOSITORY" "$REPO"
  git -C "$REPO" fetch --depth 1 origin "$IREE_COMMIT"
  FETCHED_COMMIT="$(git -C "$REPO" rev-parse 'FETCH_HEAD^{commit}')"
  [ "$FETCHED_COMMIT" = "$IREE_COMMIT" ] \
    || die "origin returned $FETCHED_COMMIT for requested IREE commit $IREE_COMMIT"
  git -C "$REPO" checkout --detach "$IREE_COMMIT"
else
  IREE_REMOTE="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
  case "$IREE_REMOTE" in
    "$IREE_AMD_AIE_REPOSITORY"|"${IREE_AMD_AIE_REPOSITORY%.git}"|git@github.com:nod-ai/iree-amd-aie.git|ssh://git@github.com/nod-ai/iree-amd-aie.git) ;;
    *)
      [ "${ALLOW_REMOTE_OVERRIDE:-0}" = 1 ] \
        || die "$REPO origin is '${IREE_REMOTE:-missing}', expected $IREE_AMD_AIE_REPOSITORY (set ALLOW_REMOTE_OVERRIDE=1 only if intentional)"
      echo "WARNING: accepting non-upstream IREE origin: $IREE_REMOTE" >&2
      ;;
  esac
  # Older releases overwrote this tracked upstream pin with whichever nightly
  # was newest that day. Recover that exact state before applying the new-lock
  # output check: accept only an unstaged, one-line VERSION whose sole installed
  # Peano tree fully matches its RECORD, metadata, and clang commit. If the user
  # already followed an earlier move-aside instruction, an otherwise clean
  # pin-only state is also recoverable. The original value is retained in .git.
  LEGACY_PIN_PATH=build_tools/peano_commit_linux.txt
  LEGACY_PIN_MIGRATED=0
  LEGACY_OUTPUT_VALID=0
  LEGACY_PIN_VALUE=""
  LEGACY_PIN_BACKUP=""
  if ! git -C "$REPO" diff --quiet -- "$LEGACY_PIN_PATH" \
      && git -C "$REPO" diff --cached --quiet -- "$LEGACY_PIN_PATH"; then
    LEGACY_PIN_VALUE="$(sed -n '1p' "$REPO/$LEGACY_PIN_PATH")"
    if [[ "$LEGACY_PIN_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\+([0-9a-f]{7,40})$ ]] \
        && cmp -s "$REPO/$LEGACY_PIN_PATH" \
          <(printf '%s\n' "$LEGACY_PIN_VALUE"); then
      LEGACY_PIN_COMMIT="${BASH_REMATCH[1]}"
      shopt -s nullglob
      LEGACY_METADATA_DIRS=("$REPO"/llvm_aie-*.dist-info)
      shopt -u nullglob
      if [ ! -e "$REPO/llvm-aie" ] \
          && [ "${#LEGACY_METADATA_DIRS[@]}" -eq 0 ]; then
        # The old output was already moved aside after a previous diagnostic.
        LEGACY_OUTPUT_VALID=1
      elif peano_output_matches "$LEGACY_PIN_VALUE" "$LEGACY_PIN_COMMIT"; then
        LEGACY_OUTPUT_VALID=1
      fi
      if [ "$LEGACY_OUTPUT_VALID" = 1 ]; then
        IREE_GIT_DIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
        LEGACY_PIN_BACKUP="$IREE_GIT_DIR/ryzen-npu-legacy-peano-pin-${LEGACY_PIN_COMMIT}.txt"
        if [ -e "$LEGACY_PIN_BACKUP" ]; then
          cmp -s "$REPO/$LEGACY_PIN_PATH" "$LEGACY_PIN_BACKUP" \
            || die "legacy pin backup already exists with different content: $LEGACY_PIN_BACKUP"
        else
          cp -- "$REPO/$LEGACY_PIN_PATH" "$LEGACY_PIN_BACKUP"
        fi
        git -C "$REPO" restore --worktree --source=HEAD -- "$LEGACY_PIN_PATH"
        LEGACY_PIN_MIGRATED=1
        echo "  migrated legacy tracked Peano pin $LEGACY_PIN_VALUE; backup: $LEGACY_PIN_BACKUP"
      fi
    fi
  fi

  MANAGED_PEANO=0
  shopt -s nullglob
  EXISTING_PEANO_METADATA=("$REPO"/llvm_aie-*.dist-info)
  shopt -u nullglob
  if [ -e "$REPO/llvm-aie" ] || [ "${#EXISTING_PEANO_METADATA[@]}" -ne 0 ]; then
    if ! peano_output_matches; then
      if [ "$LEGACY_PIN_MIGRATED" = 1 ] && [ "$LEGACY_OUTPUT_VALID" = 1 ]; then
        die "legacy Peano $LEGACY_PIN_VALUE output remains; its tracked pin was safely restored (backup: $LEGACY_PIN_BACKUP). Move llvm-aie and llvm_aie-*.dist-info aside, then rerun"
      fi
      die "existing Peano output is modified or mismatched; move llvm-aie and llvm_aie-*.dist-info aside, then rerun"
    fi
    MANAGED_PEANO=1
  fi
  if [ "$MANAGED_PEANO" = 1 ]; then
    IREE_DIRTY="$(git -C "$REPO" status --porcelain --untracked-files=normal -- . \
      ':(exclude)llvm-aie' \
      ":(exclude)llvm_aie-${IREE_PEANO_VERSION}.dist-info")"
  else
    IREE_DIRTY="$(git -C "$REPO" status --porcelain --untracked-files=normal)"
  fi
  if [ -n "$IREE_DIRTY" ] && [ "${ALLOW_DIRTY_IREE:-0}" != 1 ]; then
    die "$REPO has local changes; commit/stash them or set ALLOW_DIRTY_IREE=1 to build them explicitly"
  fi
  CURRENT_IREE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
  if [ "$CURRENT_IREE_COMMIT" != "$IREE_COMMIT" ]; then
    if [ "${UPDATE_IREE_CHECKOUT:-0}" = 1 ]; then
      [ -z "$IREE_DIRTY" ] \
        || die "UPDATE_IREE_CHECKOUT=1 refuses a dirty checkout; commit/stash changes first"
      git -C "$REPO" fetch --depth 1 origin "$IREE_COMMIT"
      FETCHED_COMMIT="$(git -C "$REPO" rev-parse 'FETCH_HEAD^{commit}')"
      [ "$FETCHED_COMMIT" = "$IREE_COMMIT" ] \
        || die "origin returned $FETCHED_COMMIT for requested IREE commit $IREE_COMMIT"
      git -C "$REPO" checkout --detach "$IREE_COMMIT"
    else
      die "$REPO is at $CURRENT_IREE_COMMIT, expected $IREE_COMMIT; use UPDATE_IREE_CHECKOUT=1 on a clean clone, or set IREE_COMMIT plus ALLOW_VERSION_OVERRIDE=1"
    fi
  fi
fi
git -C "$REPO" submodule sync --recursive
git -C "$REPO" \
  -c submodule."third_party/torch-mlir".update=none \
  -c submodule."third_party/stablehlo".update=none \
  -c submodule."third_party/XRT".update=none \
  submodule update --init --recursive --depth 1
[ "$(git -C "$REPO" rev-parse HEAD)" = "$IREE_COMMIT" ] \
  || die "IREE checkout changed unexpectedly while initializing submodules"
cd "$REPO"

echo "== [3/6] Locked Python build requirements =="
python -m pip install \
  "numpy==$NUMPY_VERSION" "requests==$REQUESTS_VERSION" \
  "sympy==$SYMPY_VERSION" "ml_dtypes==$ML_DTYPES_VERSION" \
  "PyYAML==$PYYAML_VERSION" "pybind11[global]==$PYBIND11_VERSION" \
  "nanobind==$NANOBIND_VERSION" "lit==$LIT_VERSION" \
  "protobuf==$PROTOBUF_VERSION" "typing_extensions==$TYPING_EXTENSIONS_VERSION"
if [ "$HOST_OS" = Linux ] && [ "$HOST_ARCH" = x86_64 ]; then
  download_locked_wheel "onnx==$ONNX_VERSION" \
    "$ONNX_WHEEL_LINUX_X86_64" "$ONNX_WHEEL_SHA256" ""
  python -m pip install --upgrade --force-reinstall --no-deps "$DOWNLOADED_WHEEL"
  cleanup_stages
  WHEEL_STAGE=""
  download_locked_wheel "iree-base-compiler==$IREE_BASE_COMPILER_VERSION" \
    "$IREE_BASE_COMPILER_WHEEL_LINUX_X86_64" \
    "$IREE_BASE_COMPILER_WHEEL_SHA256" ""
  python -m pip install --upgrade --force-reinstall --no-deps "$DOWNLOADED_WHEEL"
  cleanup_stages
  WHEEL_STAGE=""
else
  echo "WARNING: installing ONNX frontend without a locked wheel hash on $HOST_OS $HOST_ARCH" >&2
  python -m pip install "onnx==$ONNX_VERSION" \
    "iree-base-compiler[onnx]==$IREE_BASE_COMPILER_VERSION"
fi
python -m pip check
[ -x "$VENV/bin/iree-import-onnx" ] \
  || die "locked iree-base-compiler install did not provide $VENV/bin/iree-import-onnx"
python - "$IREE_BASE_COMPILER_VERSION" "$ONNX_VERSION" <<'PY'
from importlib.metadata import version
import sys

expected = {
    "iree-base-compiler": sys.argv[1],
    "onnx": sys.argv[2],
}
for package, wanted in expected.items():
    found = version(package)
    if found != wanted:
        raise SystemExit(f"{package} {found} installed, expected {wanted}")
PY
"$VENV/bin/iree-import-onnx" --help >/dev/null

echo "== [4/6] Peano (llvm-aie) — the AIE backend compiler =="
# Do not rewrite upstream's tracked build_tools/peano_commit_linux.txt. Install
# the repository's hardware-verified pin into ignored build-output directories.
PEANO_OK=0
if peano_output_matches; then
  PEANO_OK=1
fi
if [ "$PEANO_OK" != 1 ]; then
  shopt -s nullglob
  PEANO_METADATA_DIRS=("$REPO"/llvm_aie-*.dist-info)
  shopt -u nullglob
  if [ -e "$REPO/llvm-aie" ] || [ "${#PEANO_METADATA_DIRS[@]}" -ne 0 ]; then
    die "existing Peano output in $REPO does not exactly match $IREE_PEANO_VERSION ($IREE_PEANO_COMMIT); move llvm-aie and llvm_aie-*.dist-info aside, then rerun"
  fi
  PEANO_STAGE="$(mktemp -d "$SRC/.ryzen-npu-peano.XXXXXX")"
  if [ "$HOST_OS" = Linux ] && [ "$HOST_ARCH" = x86_64 ]; then
    download_locked_wheel "llvm_aie==$IREE_PEANO_VERSION" \
      "$IREE_PEANO_WHEEL_LINUX_X86_64" "$IREE_PEANO_WHEEL_SHA256" \
      https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly
    python -m pip install --disable-pip-version-check --no-deps --no-index \
      --target "$PEANO_STAGE" "$DOWNLOADED_WHEEL"
  else
    echo "WARNING: installing Peano without a locked wheel hash on $HOST_OS $HOST_ARCH" >&2
    python -m pip install --disable-pip-version-check --no-deps \
      --only-binary=:all: --target "$PEANO_STAGE" \
      "llvm_aie==$IREE_PEANO_VERSION" \
      -f https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly
  fi
  shopt -s nullglob
  STAGED_METADATA_DIRS=("$PEANO_STAGE"/llvm_aie-*.dist-info)
  shopt -u nullglob
  [ -x "$PEANO_STAGE/llvm-aie/bin/clang" ] \
    && [ "${#STAGED_METADATA_DIRS[@]}" -eq 1 ] \
    && grep -Fqx "Version: $IREE_PEANO_VERSION" "${STAGED_METADATA_DIRS[0]}/METADATA" \
    && "$PEANO_STAGE/llvm-aie/bin/clang" --version 2>/dev/null | grep -Fq "$IREE_PEANO_COMMIT" \
    || die "downloaded Peano failed version/commit validation"
  mv -- "$PEANO_STAGE/llvm-aie" "$REPO/llvm-aie"
  mv -- "${STAGED_METADATA_DIRS[0]}" "$REPO/"
  cleanup_stages
  WHEEL_STAGE=""
  PEANO_STAGE=""
fi
echo "  peano locked: $IREE_PEANO_VERSION ($IREE_PEANO_COMMIT)"

echo "== [5/6] Configure (gcc host compiler — NOT clang; python bindings OFF) =="
# WHY gcc: clang segfaults compiling MLIR BuiltinDialectBytecode.cpp (tested clang 21).
# WHY python OFF: nanobind/python bindings hit -Werror,-Wmacro-redefined and are
#                 not needed to run matmuls via the iree-* CLI tools.
export CC=gcc CXX=g++ CCACHE_MAXSIZE=20G
if [ "${CLEAN_BUILD:-0}" = 1 ]; then
  echo "  CLEAN_BUILD=1: removing $REPO/iree-build"
  rm -rf "$REPO/iree-build"
elif [ -d "$REPO/iree-build" ]; then
  CACHE="$REPO/iree-build/CMakeCache.txt"
  if [ -f "$CACHE" ]; then
    CACHED_CC="$(sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p' "$CACHE" | head -n1)"
    CACHED_CXX="$(sed -n 's/^CMAKE_CXX_COMPILER:[^=]*=//p' "$CACHE" | head -n1)"
    EXPECTED_CC="$(readlink -f "$(command -v "$CC")")"
    EXPECTED_CXX="$(readlink -f "$(command -v "$CXX")")"
    if [ -z "$CACHED_CC" ] || [ -z "$CACHED_CXX" ] \
        || [ "$(readlink -f "$CACHED_CC" 2>/dev/null || true)" != "$EXPECTED_CC" ] \
        || [ "$(readlink -f "$CACHED_CXX" 2>/dev/null || true)" != "$EXPECTED_CXX" ]; then
      echo "ERROR: existing CMake cache does not use the required gcc/g++ host compilers." >&2
      echo "  cached C/C++: ${CACHED_CC:-unknown} / ${CACHED_CXX:-unknown}" >&2
      echo "  required C/C++: $EXPECTED_CC / $EXPECTED_CXX" >&2
      echo "  Rerun with CLEAN_BUILD=1 to create a compatible cache." >&2
      exit 1
    fi
  fi
  echo "  reusing build cache: $REPO/iree-build"
fi
cmake -G Ninja -B "$REPO/iree-build" -S "$REPO/third_party/iree" \
  -DCMAKE_BUILD_TYPE=Release \
  -DIREE_CMAKE_PLUGIN_PATHS="$REPO" \
  -DIREE_BUILD_PYTHON_BINDINGS=OFF \
  -DIREE_INPUT_STABLEHLO=OFF -DIREE_INPUT_TORCH=OFF -DIREE_INPUT_TOSA=OFF \
  -DIREE_HAL_DRIVER_DEFAULTS=OFF -DIREE_TARGET_BACKEND_DEFAULTS=OFF \
  -DIREE_TARGET_BACKEND_LLVM_CPU=ON \
  -DIREE_EXTERNAL_HAL_DRIVERS=amdxdna \
  -DIREE_BUILD_TESTS=ON \
  -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_INSTALL_PREFIX="$REPO/iree-install"

echo "== [6/6] Build + install (JOBS=$JOBS; this is the long part) =="
cmake --build "$REPO/iree-build" --parallel "$JOBS" -- -k 0
cmake --build "$REPO/iree-build" --parallel "$JOBS" --target install

echo
echo "Done. Tools in: $REPO/iree-install/bin"
TARGET_HELP="$("$REPO/iree-install/bin/iree-compile" \
  --iree-hal-target-backends=amd-aie --help 2>&1)"
MISSING_TARGETS=""
for target in npu1_4col npu4; do
  if ! grep -Fqi "$target" <<<"$TARGET_HELP"; then
    MISSING_TARGETS="${MISSING_TARGETS:+$MISSING_TARGETS, }$target"
  fi
done
if [ -n "$MISSING_TARGETS" ]; then
  echo "ERROR: amd-aie target(s) missing from iree-compile: $MISSING_TARGETS" >&2
  exit 1
fi
echo "amd-aie targets present: npu1_4col (XDNA1), npu4 (XDNA2) — ready."
echo "XDNA1: run scripts/run-matmul.sh (set REPO=$REPO VENV=$VENV if non-default)."
echo "XDNA2: compile for --iree-amdaie-target-device=npu4 (see docs/XDNA2.md)."
