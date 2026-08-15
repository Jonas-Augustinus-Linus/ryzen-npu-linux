#!/usr/bin/env bash
# Detect, compile/cache, and run the 256x256 bf16 local-RAG NPU sidecar.
# This file inherits the repository's MIT license. See ../../LICENSE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/../.." && pwd)"
IREE_ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
VENV="${RAG_VENV:-${IREE_VENV:-$HOME/src/iree-aie-venv}}"
PYTHON="$VENV/bin/python"
DETECT_NPU="${DETECT_NPU:-$PROJECT/scripts/detect-npu.sh}"
RUNNER_DIR="$PROJECT/tools/npu-runner"

[ -x "$PYTHON" ] || {
  echo "Python virtualenv missing: $PYTHON" >&2
  echo "Set RAG_VENV or IREE_VENV to an environment containing numpy and ml_dtypes." >&2
  exit 1
}
"$PYTHON" -c 'import numpy' 2>/dev/null || {
  echo "numpy is missing from $VENV" >&2
  exit 1
}

# CPU-only and help paths intentionally do not probe hardware or create caches.
for argument in "$@"; do
  case "$argument" in
    --cpu-only|-h|--help)
      exec "$PYTHON" "$HERE/local_rag_sidecar.py" "$@"
      ;;
  esac
done

"$PYTHON" -c 'import ml_dtypes' 2>/dev/null || {
  echo "ml_dtypes is missing from $VENV" >&2
  exit 1
}

[ -x "$DETECT_NPU" ] || {
  echo "NPU detector missing or not executable: $DETECT_NPU" >&2
  exit 1
}
[ -x "$PROJECT/scripts/run-matmul.sh" ] || {
  echo "matmul compiler runner missing: $PROJECT/scripts/run-matmul.sh" >&2
  exit 1
}

DETECTION="$(IREE_AMD_AIE_ROOT="$IREE_ROOT" "$DETECT_NPU" --tsv)" || {
  echo "NPU detection failed: $DETECT_NPU" >&2
  exit 1
}
if [[ "$DETECTION" == *$'\n'* ]]; then
  echo "NPU detector returned more than one TSV record" >&2
  exit 1
fi
IFS=$'\t' read -r TARGET ROWS COLS GENERATION VBNV EXTRA <<<"$DETECTION"
if [ -z "$TARGET" ] || [ -z "$ROWS" ] || [ -z "$COLS" ] \
    || [ -z "$GENERATION" ] || [ -z "$VBNV" ] || [ -n "${EXTRA:-}" ]; then
  echo "NPU detector returned an invalid TSV record" >&2
  exit 1
fi
echo ">> Detected $GENERATION ($VBNV): target=$TARGET geometry=${ROWS}x${COLS}"

CACHE_DIR="${RAG_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ryzen-npu-linux/local-rag-sidecar}"
ROOT_REAL="$(readlink -f "$IREE_ROOT")" || {
  echo "Could not resolve the IREE checkout: $IREE_ROOT" >&2
  exit 1
}
IREE_REVISION="$(git -C "$IREE_ROOT" rev-parse --verify HEAD 2>/dev/null)" || {
  echo "Could not identify the IREE source revision: $IREE_ROOT" >&2
  exit 1
}
IREE_CMAKE_CACHE="$IREE_ROOT/iree-build/CMakeCache.txt"

if [ -n "${RAG_VMFB:-}" ]; then
  # An explicit path is an expert-managed artifact. Correctness is still
  # checked for every query by local_rag_sidecar.py before context is used.
  VMFB="$RAG_VMFB"
else
  VMFB_KEY_INPUTS=(
    "$PROJECT/scripts/run-matmul.sh"
    "$DETECT_NPU"
    "$IREE_CMAKE_CACHE"
    "$IREE_ROOT/iree-install/bin/iree-compile"
    "$IREE_ROOT/iree-install/bin/iree-run-module"
    "$IREE_ROOT/iree-install/lib/libIREECompiler.so"
    "$IREE_ROOT/llvm-aie/bin/clang"
    "$IREE_ROOT/llvm-aie/bin/opt"
    "$IREE_ROOT/llvm-aie/bin/llc"
    "$IREE_ROOT/llvm-aie/bin/llvm-readelf"
    "$IREE_ROOT/llvm-aie/bin/ld.lld"
    "$IREE_ROOT/llvm-aie/lib/libclang-cpp.so"
    "$IREE_ROOT/llvm-aie/lib/libLLVM.so"
  )
  for key_input in "${VMFB_KEY_INPUTS[@]}"; do
    [ -f "$key_input" ] || {
      echo "VMFB cache-key input is missing: $key_input" >&2
      exit 1
    }
  done
  VMFB_INPUT_HASHES="$(sha256sum "${VMFB_KEY_INPUTS[@]}")" || {
    echo "Could not hash every VMFB cache-key input" >&2
    exit 1
  }
  IREE_COMPILE_VERSION="$(
    "$IREE_ROOT/iree-install/bin/iree-compile" --version
  )" || {
    echo "Could not read the IREE compiler identity" >&2
    exit 1
  }
  PEANO_CLANG_VERSION="$("$IREE_ROOT/llvm-aie/bin/clang" --version)" || {
    echo "Could not read the Peano compiler identity" >&2
    exit 1
  }
  VMFB_KEY="$(
    printf '%s\n' \
      "$ROOT_REAL" "$IREE_REVISION" "$TARGET" "$ROWS" "$COLS" \
      'bf16' '256' '256' '256' '2' '3' \
      "$VMFB_INPUT_HASHES" "$IREE_COMPILE_VERSION" "$PEANO_CLANG_VERSION" \
      | sha256sum | cut -d' ' -f1
  )" || {
    echo "Could not derive the VMFB cache key" >&2
    exit 1
  }
  VMFB="$CACHE_DIR/matmul_bf16_256x256x256.${TARGET}.${VMFB_KEY}.vmfb"
fi
if [ ! -s "$VMFB" ] || [ "${RAG_REBUILD:-0}" = "1" ]; then
  mkdir -p "$(dirname "$VMFB")"
  echo ">> Building and full-output-verifying VMFB: $VMFB"
  REPO="$IREE_ROOT" \
    VENV="$VENV" \
    DETECT_NPU="$DETECT_NPU" \
    TARGET_DEVICE="$TARGET" \
    VMFB_OUT="$VMFB" \
    "$PROJECT/scripts/run-matmul.sh" bf16 256 256 256
else
  echo ">> Reusing cached VMFB: $VMFB"
fi
[ -s "$VMFB" ] || {
  echo "VMFB is missing or empty after compilation: $VMFB" >&2
  exit 1
}

if [ -n "${LIBNPU:-}" ]; then
  [ -s "$LIBNPU" ] || {
    echo "LIBNPU is missing or empty: $LIBNPU" >&2
    exit 1
  }
else
  [ -f "$IREE_CMAKE_CACHE" ] || {
    echo "IREE build cache is missing: $IREE_CMAKE_CACHE" >&2
    exit 1
  }
  HOST_COMPILER_VERSION="$(g++ -dumpfullversion -dumpversion)" || {
    echo "Could not identify the host C++ compiler" >&2
    exit 1
  }
  LIB_CMAKE_HASH="$(sha256sum "$IREE_CMAKE_CACHE")" || {
    echo "Could not hash the IREE build cache" >&2
    exit 1
  }
  LIB_SOURCE_HASHES="$(
    sha256sum "$RUNNER_DIR/libnpu.cc" "$RUNNER_DIR/build_lib.sh"
  )" || {
    echo "Could not hash the persistent bridge sources" >&2
    exit 1
  }
  RUNTIME_ARCHIVE_METADATA="$(
    find "$IREE_ROOT/iree-build/runtime" -type f -name '*.a' \
      -printf '%p\t%s\t%T@\n' | LC_ALL=C sort
  )" || {
    echo "Could not inventory the IREE runtime archives" >&2
    exit 1
  }
  FLATCC_ARCHIVE_METADATA="$(
    stat -c '%n\t%s\t%Y' \
      "$IREE_ROOT/iree-build/build_tools/third_party/flatcc/libflatcc_parsing.a" \
      "$IREE_ROOT/iree-build/build_tools/third_party/flatcc/libflatcc_runtime.a"
  )" || {
    echo "Could not inventory the flatcc runtime archives" >&2
    exit 1
  }
  LIBNPU_KEY="$(
    printf '%s\n' \
      "$ROOT_REAL" "$IREE_REVISION" "$HOST_COMPILER_VERSION" \
      "$LIB_CMAKE_HASH" "$LIB_SOURCE_HASHES" \
      "$RUNTIME_ARCHIVE_METADATA" "$FLATCC_ARCHIVE_METADATA" \
      | sha256sum | cut -d' ' -f1
  )" || {
    echo "Could not derive the persistent bridge cache key" >&2
    exit 1
  }
  LIBNPU="$CACHE_DIR/libnpu.${LIBNPU_KEY}.so"
  if [ ! -s "$LIBNPU" ] || [ "$RUNNER_DIR/libnpu.cc" -nt "$LIBNPU" ] \
      || [ "$RUNNER_DIR/build_lib.sh" -nt "$LIBNPU" ]; then
    echo ">> Building the toolchain-keyed persistent bridge: $LIBNPU"
    IREE_AMD_AIE_ROOT="$IREE_ROOT" LIBNPU_OUT="$LIBNPU" \
      "$RUNNER_DIR/build_lib.sh"
  fi
fi

export LIBNPU RAG_VMFB="$VMFB" NPU_TARGET="$TARGET" NPU_GENERATION="$GENERATION"
exec "$PYTHON" "$HERE/local_rag_sidecar.py" "$@"
