// libnpu.so — "load once, call many" XDNA1 NPU access from any language via a
// tiny C ABI. Load a .vmfb once (npu_open), invoke the NPU repeatedly
// (npu_mm128_i32), tear down (npu_close). ~3.7 ms/call vs ~41 ms for spawning
// iree-run-module. Specialized to the verified i32 128x128 matmul, which both
// the wake-word head and the camera transform use; generalize as needed.
//
// Build: see build_lib.sh (g++ -fPIC -shared, same archives as npu_runner).
#include <cstdint>
#include <cstring>

#include "iree/async/util/proactor_pool.h"
#include "iree/runtime/api.h"
#include "iree-amd-aie/driver/amdxdna/api.h"

static const int N = 128;

struct npu_ctx {
  iree_runtime_instance_t* instance;
  iree_async_proactor_pool_t* proactor;
  iree_hal_driver_t* driver;
  iree_hal_device_t* device;
  iree_runtime_session_t* session;
  iree_runtime_call_t call;
  iree_hal_allocator_t* alloc;
};

#define OK(expr)                                   \
  do {                                             \
    iree_status_t _s = (expr);                     \
    if (!iree_status_is_ok(_s)) {                  \
      iree_status_fprint(stderr, _s);              \
      iree_status_free(_s);                        \
      return NULL;                                 \
    }                                              \
  } while (0)

#define OKI(expr)                                  \
  do {                                             \
    iree_status_t _s = (expr);                     \
    if (!iree_status_is_ok(_s)) {                  \
      iree_status_fprint(stderr, _s);              \
      iree_status_free(_s);                        \
      return 1;                                    \
    }                                              \
  } while (0)

extern "C" npu_ctx* npu_open(const char* vmfb, const char* fn) {
  npu_ctx* c = new npu_ctx();
  memset(c, 0, sizeof(*c));

  iree_runtime_instance_options_t iopt;
  iree_runtime_instance_options_initialize(&iopt);
  OK(iree_runtime_instance_create(&iopt, iree_allocator_system(), &c->instance));
  iree_allocator_t host = iree_runtime_instance_host_allocator(c->instance);

  iree_hal_amdxdna_device_params params;
  iree_hal_amdxdna_device_options_initialize(&params);
  params.n_core_rows = 4;
  params.n_core_cols = 4;  // 5 -> ERT state-8 timeout
  iree_hal_amdxdna_driver_options drv;
  iree_hal_amdxdna_driver_options_initialize(&drv);
  OK(iree_hal_amdxdna_driver_create(iree_make_cstring_view("amdxdna"), &drv,
                                    &params, host, &c->driver));

  OK(iree_async_proactor_pool_create(1, NULL,
                                     iree_async_proactor_pool_options_default(),
                                     host, &c->proactor));
  iree_hal_device_create_params_t dcp = iree_hal_device_create_params_default();
  dcp.proactor_pool = c->proactor;
  OK(iree_hal_driver_create_default_device(c->driver, &dcp, host, &c->device));

  iree_runtime_session_options_t sopt;
  iree_runtime_session_options_initialize(&sopt);
  OK(iree_runtime_session_create_with_device(c->instance, &sopt, c->device, host,
                                             &c->session));
  OK(iree_runtime_session_append_bytecode_module_from_file(c->session, vmfb));
  c->alloc = iree_runtime_session_device_allocator(c->session);
  OK(iree_runtime_call_initialize_by_name(
      c->session, iree_make_cstring_view(fn), &c->call));
  return c;
}

// out = a @ b, all int32 [128,128] row-major. Returns 0 on success.
extern "C" int npu_mm128_i32(npu_ctx* c, const int32_t* a, const int32_t* b,
                             int32_t* out) {
  const iree_hal_dim_t shape[2] = {N, N};
  iree_hal_buffer_params_t bp = {};
  bp.type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL;
  bp.access = IREE_HAL_MEMORY_ACCESS_ALL;
  bp.usage = IREE_HAL_BUFFER_USAGE_DEFAULT;
  iree_hal_buffer_view_t* va = NULL;
  iree_hal_buffer_view_t* vb = NULL;
  OKI(iree_hal_buffer_view_allocate_buffer_copy(
      c->device, c->alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
      IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
      iree_make_const_byte_span(a, N * N * sizeof(int32_t)), &va));
  OKI(iree_hal_buffer_view_allocate_buffer_copy(
      c->device, c->alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
      IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
      iree_make_const_byte_span(b, N * N * sizeof(int32_t)), &vb));

  iree_runtime_call_reset(&c->call);
  OKI(iree_runtime_call_inputs_push_back_buffer_view(&c->call, va));
  OKI(iree_runtime_call_inputs_push_back_buffer_view(&c->call, vb));
  iree_hal_buffer_view_release(va);
  iree_hal_buffer_view_release(vb);

  OKI(iree_runtime_call_invoke(&c->call, 0));
  iree_hal_buffer_view_t* vo = NULL;
  OKI(iree_runtime_call_outputs_pop_front_buffer_view(&c->call, &vo));
  iree_status_t s = iree_hal_device_transfer_d2h(
      c->device, iree_hal_buffer_view_buffer(vo), 0, out,
      N * N * sizeof(int32_t), IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT,
      iree_infinite_timeout());
  iree_hal_buffer_view_release(vo);
  if (!iree_status_is_ok(s)) { iree_status_free(s); return 1; }
  return 0;
}

extern "C" void npu_close(npu_ctx* c) {
  if (!c) return;
  iree_runtime_call_deinitialize(&c->call);
  if (c->session) iree_runtime_session_release(c->session);
  if (c->device) iree_hal_device_release(c->device);
  if (c->driver) iree_hal_driver_release(c->driver);
  if (c->proactor) iree_async_proactor_pool_release(c->proactor);
  if (c->instance) iree_runtime_instance_release(c->instance);
  delete c;
}
