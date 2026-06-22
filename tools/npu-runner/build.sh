#!/usr/bin/env bash
# Build npu_runner: a persistent IREE-runtime-C-API caller that loads a .vmfb
# once and invokes the XDNA1 NPU many times in-process (~11x faster per call
# than spawning iree-run-module). Links against the existing iree-amd-aie build
# tree (no reinstall). Host compiler MUST be g++ (clang21 ICEs the driver).
set -euo pipefail
ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
BLD="$ROOT/iree-build"
SRC="$ROOT/third_party/iree/runtime/src"
AMD="$ROOT/runtime/src"
GEN="$BLD/runtime/src"
AMDGEN="$BLD/runtime/plugins/AMD-AIE"
APLUG="$BLD/runtime/plugins/AMD-AIE/iree-amd-aie"
U="$BLD/runtime/src/iree/hal/utils"
A="$BLD/runtime/src/iree/async"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$BLD/runtime/src/iree/runtime/libiree_runtime_unified.a" ] || {
  echo "Build iree-amd-aie first (../iree-amd-aie). Missing: $BLD"; exit 1; }

# The IREE runtime C API uses a build-time system allocator macro.
DEFS="-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl"

g++ -O2 -std=c++17 $DEFS "$HERE/npu_runner.cc" -o "$HERE/npu_runner" \
  -I"$SRC" -I"$AMD" -I"$GEN" -I"$AMDGEN" \
  -Wl,--start-group \
    "$BLD/runtime/src/iree/runtime/libiree_runtime_unified.a" \
    "$APLUG/driver/amdxdna/registration/libiree-amd-aie_driver_amdxdna_registration_registration.a" \
    "$APLUG/driver/amdxdna/libiree-amd-aie_driver_amdxdna_amdxdna.a" \
    "$APLUG/driver/amdxdna/shim/linux/kmq/libiree-amd-aie_driver_amdxdna_shim_linux_kmq_shim-xdna.a" \
    "$APLUG/aie_runtime/libiree-amd-aie_aie_runtime_iree_aie_runtime_static.a" \
    "$APLUG/aie_runtime/libiree-amd-aie_aie_runtime_AMDAIEEnums.a" \
    "$APLUG/aie_runtime/Utils/libiree-amd-aie_aie_runtime_Utils_Utils.a" \
    "$APLUG/aie_runtime/libcdo_driver.a" \
    "$APLUG/aie_runtime/iree_aie_runtime/libxaiengine.a" \
    "$U/libiree_hal_utils_deferred_command_buffer.a" \
    "$U/libiree_hal_utils_queue_emulation.a" \
    "$U/libiree_hal_utils_queue_host_call_emulation.a" \
    "$U/libiree_hal_utils_resource_set.a" \
    "$U/libiree_hal_utils_file_transfer.a" \
    "$A/libiree_async_async.a" \
    "$A/util/libiree_async_util_proactor_pool.a" \
    "$BLD/build_tools/third_party/flatcc/libflatcc_parsing.a" \
    "$BLD/build_tools/third_party/flatcc/libflatcc_runtime.a" \
  -Wl,--end-group -luuid -ldl -lpthread -lm -lstdc++

echo "built: $HERE/npu_runner"
# If a future iree-amd-aie checkout adds undefined symbols, find the archive:
#   for a in $(find "$BLD" -name '*.a'); do nm "$a" 2>/dev/null | grep -q " T <symbol>" && echo "$a"; done
# and add it inside --start-group/--end-group above.
