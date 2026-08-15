#!/usr/bin/env bash
# Reproduce the narrowly scoped TileFuse W4A16 front-end compile check.
#
# This proves only that one pinned m64/k128/n64 kernel specialization compiles
# for AIE2P with Peano and mlir-aie 1.4.1 headers.  It does not link/place an
# IRON design, run on the NPU, or verify numerical results.
#
# Env overrides:
#   VENV          mlir-aie virtualenv (default: ~/src/mlir-aie-venv)
#   OUTPUT        preserve the resulting object at this path
#   KEEP_WORK=1   retain the downloaded sources and temporary object
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_COMMIT="8c3d2be63161c255c4e290e500702571c69a7112"
SOURCE_BASE="https://raw.githubusercontent.com/glassescrab/mlir-aie/$SOURCE_COMMIT/aie_kernels/aie2p"
KERNEL_SHA256="9f89364479ca30d230cfb595a7bad04520ec49af514f7f6928282cc851ac1834"
ZERO_SHA256="08c19f45a55d466ea47274cf4d19e8147f85ac35df9b2eed573a7f0b89412cea"

die() {
  printf '[W4A16 compile] %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

# shellcheck disable=SC1091
source "$HERE/mlir-aie-env.sh"
[[ -x "${PEANO_INSTALL_DIR:-}/bin/clang" ]] || \
  die "Peano clang not found; run setup-mlir-aie.sh first"
source_tag="$(git -C "$MLIR_AIE_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ "$source_tag" == "v1.4.1" ]] || \
  die "this pinned check requires a mlir-aie v1.4.1 source checkout"
[[ -z "$(git -C "$MLIR_AIE_DIR" status --porcelain --untracked-files=normal)" ]] || \
  die "this pinned check requires a clean mlir-aie v1.4.1 source checkout"

mlir_aie_version="$(python -c 'import importlib.metadata as m; print(m.version("mlir-aie"))')"
[[ "$mlir_aie_version" == "1.4.1" ]] || \
  die "this pinned check requires mlir-aie 1.4.1 headers (found $mlir_aie_version)"
aie_root="$(python -c 'from aie.utils.config import root_path; print(root_path())')"
[[ -f "$aie_root/include/aie_api/aie.hpp" ]] || \
  die "aie_api headers not found below $aie_root/include"

work="$(mktemp -d /tmp/ryzen-npu-w4a16.XXXXXX)"
cleanup() {
  if [[ "${KEEP_WORK:-0}" == "1" ]]; then
    printf '[W4A16 compile] work directory retained: %s\n' "$work"
  elif [[ "$work" == /tmp/ryzen-npu-w4a16.* ]]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

curl -fsSL --retry 3 "$SOURCE_BASE/mix_int4_ATB.cc" -o "$work/mix_int4_ATB.cc"
curl -fsSL --retry 3 "$SOURCE_BASE/zero.cc" -o "$work/zero.cc"

kernel_actual="$(sha256sum "$work/mix_int4_ATB.cc" | awk '{print $1}')"
zero_actual="$(sha256sum "$work/zero.cc" | awk '{print $1}')"
[[ "$kernel_actual" == "$KERNEL_SHA256" ]] || die "mix_int4_ATB.cc checksum mismatch"
[[ "$zero_actual" == "$ZERO_SHA256" ]] || die "zero.cc checksum mismatch"

flags=(
  -O2
  -std=c++20
  --target=aie2p-none-unknown-elf
  -Wno-parentheses
  -Wno-attributes
  -Wno-macro-redefined
  -Wno-empty-body
  -Wno-missing-template-arg-list-after-template-kw
  -DNDEBUG
  -I "$aie_root/include"
  -D__AIE_API_AIE_ADF_HPP__
  -Dbf16_bf16_ONLY
  -DDIM_M=64
  -DDIM_K=128
  -DDIM_N=64
)

"$PEANO_INSTALL_DIR/bin/clang" "${flags[@]}" \
  -c "$work/mix_int4_ATB.cc" -o "$work/mix_int4_ATB.o"
[[ -s "$work/mix_int4_ATB.o" ]] || die "compiler produced no object"

if [[ -n "${OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$work/mix_int4_ATB.o" "$OUTPUT"
  printf '[W4A16 compile] object: %s\n' "$OUTPUT"
fi

printf '[W4A16 compile] PASS\n'
printf '[W4A16 compile] source: glassescrab/mlir-aie@%s\n' "$SOURCE_COMMIT"
printf '[W4A16 compile] headers: mlir-aie %s\n' "$mlir_aie_version"
printf '[W4A16 compile] scope: compile only; integration and NPU correctness remain\n'
