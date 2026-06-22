// npu_runner — load a .vmfb once, invoke it many times on the XDNA1 NPU via the
// IREE runtime C API. Replaces per-call `iree-run-module` (process spawn +
// device open every call) so always-on NPU use (KWS/embeddings/CNN/blur) is
// actually deployable. Built against the existing iree-amd-aie build tree.
//
// Demo: runs the verified i32 128x128 matmul (inputs 2 and 3 -> every out 768),
// N times in-process, and prints throughput.  Usage: npu_runner [vmfb] [iters] [fn]
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "iree/base/api.h"
#include "iree/base/allocator.h"
#include "iree/hal/api.h"
#include "iree/async/util/proactor_pool.h"
#include "iree/runtime/api.h"
#include "iree-amd-aie/driver/amdxdna/api.h"

#define CHECK(expr)                                                      \
  do {                                                                   \
    iree_status_t _s = (expr);                                          \
    if (!iree_status_is_ok(_s)) {                                       \
      fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);             \
      iree_status_fprint(stderr, _s);                                   \
      iree_status_free(_s);                                             \
      return 1;                                                          \
    }                                                                    \
  } while (0)

static const int N = 128;  // matmul dim (matches dense_npu / run_npu_matmul)

int main(int argc, char** argv) {
  const char* vmfb = argc > 1 ? argv[1] : "/tmp/matmul_npu.vmfb";
  int iters = argc > 2 ? atoi(argv[2]) : 1000;
  const char* fn = argc > 3 ? argv[3] : "module.matmul";

  // 1) Instance.
  iree_runtime_instance_options_t iopt;
  iree_runtime_instance_options_initialize(&iopt);
  iree_runtime_instance_t* instance = NULL;
  CHECK(iree_runtime_instance_create(&iopt, iree_allocator_system(), &instance));
  iree_allocator_t host = iree_runtime_instance_host_allocator(instance);

  // 2) amdxdna device with n_core_cols=4 (5 -> ERT state-8 timeout).
  iree_hal_amdxdna_device_params params;
  iree_hal_amdxdna_device_options_initialize(&params);
  params.n_core_rows = 4;
  params.n_core_cols = 4;
  iree_hal_amdxdna_driver_options drv;
  iree_hal_amdxdna_driver_options_initialize(&drv);
  iree_hal_driver_t* driver = NULL;
  CHECK(iree_hal_amdxdna_driver_create(iree_make_cstring_view("amdxdna"), &drv,
                                       &params, host, &driver));
  // amdxdna device creation needs a proactor pool for async I/O (else segfault).
  iree_hal_device_t* device = NULL;
  iree_async_proactor_pool_t* proactor = NULL;
  CHECK(iree_async_proactor_pool_create(/*node_count=*/1, /*node_ids=*/NULL,
                                        iree_async_proactor_pool_options_default(),
                                        host, &proactor));
  iree_hal_device_create_params_t dcp = iree_hal_device_create_params_default();
  dcp.proactor_pool = proactor;
  CHECK(iree_hal_driver_create_default_device(driver, &dcp, host, &device));

  // 3) Session + module (loaded ONCE).
  iree_runtime_session_options_t sopt;
  iree_runtime_session_options_initialize(&sopt);
  iree_runtime_session_t* session = NULL;
  CHECK(iree_runtime_session_create_with_device(instance, &sopt, device, host,
                                                &session));
  CHECK(iree_runtime_session_append_bytecode_module_from_file(session, vmfb));

  // 4) Two input buffer views (128x128 i32), created once and reused.
  iree_hal_allocator_t* alloc = iree_runtime_session_device_allocator(session);
  std::vector<int32_t> a(N * N, 2), b(N * N, 3);
  const iree_hal_dim_t shape[2] = {N, N};
  iree_hal_buffer_params_t bp = {};
  bp.type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL;
  bp.access = IREE_HAL_MEMORY_ACCESS_ALL;
  bp.usage = IREE_HAL_BUFFER_USAGE_DEFAULT;
  iree_hal_buffer_view_t* in_a = NULL;
  iree_hal_buffer_view_t* in_b = NULL;
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
      IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
      iree_make_const_byte_span(a.data(), a.size() * sizeof(int32_t)), &in_a));
  CHECK(iree_hal_buffer_view_allocate_buffer_copy(
      device, alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
      IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
      iree_make_const_byte_span(b.data(), b.size() * sizeof(int32_t)), &in_b));

  // 5) Hot loop: reset / push inputs / invoke / pop output.
  iree_runtime_call_t call;
  CHECK(iree_runtime_call_initialize_by_name(
      session, iree_make_cstring_view(fn), &call));

  int32_t check_val = 0;
  auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < iters; ++i) {
    iree_runtime_call_reset(&call);
    CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, in_a));
    CHECK(iree_runtime_call_inputs_push_back_buffer_view(&call, in_b));
    CHECK(iree_runtime_call_invoke(&call, 0));
    iree_hal_buffer_view_t* out = NULL;
    CHECK(iree_runtime_call_outputs_pop_front_buffer_view(&call, &out));
    if (i == iters - 1) {  // read back one element on the last iter to verify
      CHECK(iree_hal_device_transfer_d2h(
          device, iree_hal_buffer_view_buffer(out), 0, &check_val,
          sizeof(check_val), IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT,
          iree_infinite_timeout()));
    }
    iree_hal_buffer_view_release(out);
  }
  auto t1 = std::chrono::steady_clock::now();
  double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

  printf("vmfb=%s fn=%s iters=%d\n", vmfb, fn, iters);
  printf("output[0]=%d (expect 768)  %s\n", check_val,
         check_val == 768 ? "OK" : "MISMATCH");
  printf("total=%.1f ms  per-invoke=%.3f ms  rate=%.0f/s\n", ms, ms / iters,
         1000.0 * iters / ms);

  iree_runtime_call_deinitialize(&call);
  iree_hal_buffer_view_release(in_a);
  iree_hal_buffer_view_release(in_b);
  iree_runtime_session_release(session);
  iree_hal_device_release(device);
  iree_async_proactor_pool_release(proactor);
  iree_hal_driver_release(driver);
  iree_runtime_instance_release(instance);
  return 0;
}
