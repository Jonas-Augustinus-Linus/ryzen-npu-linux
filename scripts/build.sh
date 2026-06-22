#!/usr/bin/env bash
# build.sh — Build iree-amd-aie from source so you can run real compute on an
# AMD XDNA1 (Phoenix) NPU on Linux. Encodes every workaround needed as of
# mid-2026 (see docs/GOTCHAS.md for the why behind each one).
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0,
#            gcc 15, cmake 4.2, ~65 min cold build on 16 cores, ~30-60 GB disk.
#
# Usage:   scripts/build.sh [SRC_DIR]      (default: ~/src)
set -euo pipefail

SRC="${1:-$HOME/src}"
REPO="$SRC/iree-amd-aie"
VENV="$SRC/iree-aie-venv"
NPROC="$(nproc)"

mkdir -p "$SRC"

echo "== [0/6] System build tools (sudo) =="
# ninja + lld + ccache are required/strongly recommended. cmake>=3.26, a C/C++
# compiler, libudev/uuid dev headers.
sudo apt-get install -y ninja-build lld ccache cmake git \
  build-essential libudev-dev uuid-dev || true

echo "== [1/6] Isolated Python 3.12 venv (3.13/3.14 are too new for IREE wheels) =="
if ! command -v uv >/dev/null; then
  echo "Installing uv (user-local)..."; curl -LsSf https://astral.sh/uv/install.sh | sh; export PATH="$HOME/.local/bin:$PATH"
fi
uv python install 3.12
uv venv --python 3.12 --seed "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip

echo "== [2/6] Clone iree-amd-aie (skip 3 heavy, unneeded submodules) =="
if [ ! -d "$REPO/.git" ]; then
  git -c submodule."third_party/torch-mlir".update=none \
      -c submodule."third_party/stablehlo".update=none \
      -c submodule."third_party/XRT".update=none \
      clone --recursive --shallow-submodules \
      https://github.com/nod-ai/iree-amd-aie.git "$REPO"
fi
cd "$REPO"

echo "== [3/6] Python build requirements =="
python -m pip install -r third_party/iree/runtime/bindings/python/iree/runtime/build_requirements.txt
python -m pip install pyyaml "pybind11[global]==2.13.6" "nanobind==2.9.0" lit

echo "== [4/6] Peano (llvm-aie) — the AIE backend compiler =="
# The pinned nightly version expires from the index after ~weeks. Auto-bump the
# pin to the newest available nightly so download_peano.sh succeeds.
NIGHTLY="https://github.com/Xilinx/llvm-aie/releases/expanded_assets/nightly"
LATEST="$(python -m pip index versions llvm_aie -f "$NIGHTLY" --pre 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]+' | head -1 || true)"
if [ -n "$LATEST" ]; then echo "  pinning peano -> $LATEST"; echo "$LATEST" > build_tools/peano_commit_linux.txt; fi
bash build_tools/download_peano.sh
test -x "$REPO/llvm-aie/bin/clang" && echo "  peano ok: $REPO/llvm-aie"

echo "== [5/6] Configure (gcc host compiler — NOT clang; python bindings OFF) =="
# WHY gcc: clang segfaults compiling MLIR BuiltinDialectBytecode.cpp (tested clang 21).
# WHY python OFF: nanobind/python bindings hit -Werror,-Wmacro-redefined and are
#                 not needed to run matmuls via the iree-* CLI tools.
export CC=gcc CXX=g++ CCACHE_MAXSIZE=20G
rm -rf "$REPO/iree-build"
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
  -DLLVM_PARALLEL_LINK_JOBS=4 \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=lld" \
  -DCMAKE_INSTALL_PREFIX="$REPO/iree-install"

echo "== [6/6] Build + install (this is the long part) =="
cmake --build "$REPO/iree-build" -- -k 0
cmake --build "$REPO/iree-build" --target install

echo
echo "Done. Tools in: $REPO/iree-install/bin"
"$REPO/iree-install/bin/iree-compile" --iree-hal-target-backends=amd-aie --help 2>&1 \
  | grep -i npu1_4col && echo "npu1_4col target present — ready."
echo "Now run:  scripts/run-matmul.sh   (set REPO=$REPO VENV=$VENV if non-default)"
