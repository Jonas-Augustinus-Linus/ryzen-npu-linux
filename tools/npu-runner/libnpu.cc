// libnpu.so — "load once, call many" AMD XDNA NPU access from any language via a
// tiny C ABI. Load a .vmfb once (npu_open), invoke the NPU repeatedly
// (npu_mm128_i32), tear down (npu_close). On a Ryzen 7840U/XDNA1 this measured
// ~3.7 ms/call vs ~41 ms for spawning iree-run-module. Specialized to the
// verified i32 128x128 matmul, which both
// the wake-word head and the camera transform use; generalize as needed.
//
// Build: see build_lib.sh (g++ -fPIC -shared, same archives as npu_runner).
#include <cstdint>
#include <cstdio>
#include <limits>
#include <new>

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
  bool call_initialized;
};

static bool npu_status_ok(iree_status_t status) {
  if (iree_status_is_ok(status)) return true;
  std::fputs("libnpu: ", stderr);
  iree_status_fprint(stderr, status);
  iree_status_free(status);
  return false;
}

static void npu_ctx_destroy(npu_ctx* c) {
  if (!c) return;
  if (c->call_initialized) {
    iree_runtime_call_deinitialize(&c->call);
  }
  if (c->session) iree_runtime_session_release(c->session);
  if (c->device) iree_hal_device_release(c->device);
  if (c->driver) iree_hal_driver_release(c->driver);
  if (c->proactor) iree_async_proactor_pool_release(c->proactor);
  if (c->instance) iree_runtime_instance_release(c->instance);
  delete c;
}

static int npu_invalid_argument(const char* message) {
  std::fprintf(stderr, "libnpu: invalid argument: %s\n", message);
  return 1;
}

static bool npu_matrix_byte_length(int32_t rows, int32_t cols,
                                   iree_host_size_t element_size,
                                   iree_host_size_t* out_length) {
  if (rows <= 0 || cols <= 0 || !out_length) return false;
  const auto r = static_cast<iree_host_size_t>(rows);
  const auto c = static_cast<iree_host_size_t>(cols);
  const auto max = std::numeric_limits<iree_host_size_t>::max();
  if (r > max / c) return false;
  const auto elements = r * c;
  if (element_size != 0 && elements > max / element_size) return false;
  *out_length = elements * element_size;
  return true;
}

extern "C" npu_ctx* npu_open(const char* vmfb, const char* fn) {
  if (!vmfb || !*vmfb || !fn || !*fn) {
    npu_invalid_argument("npu_open requires non-empty vmfb and function names");
    return nullptr;
  }
  npu_ctx* c = new (std::nothrow) npu_ctx{};
  if (!c) {
    std::fputs("libnpu: could not allocate context\n", stderr);
    return nullptr;
  }

#define NPU_OPEN_CHECK(expr)                        \
  do {                                              \
    if (!npu_status_ok((expr))) {                   \
      npu_ctx_destroy(c);                           \
      return nullptr;                               \
    }                                               \
  } while (0)

  iree_runtime_instance_options_t iopt;
  iree_runtime_instance_options_initialize(&iopt);
  NPU_OPEN_CHECK(
      iree_runtime_instance_create(&iopt, iree_allocator_system(), &c->instance));
  iree_allocator_t host = iree_runtime_instance_host_allocator(c->instance);

  iree_hal_amdxdna_device_params params;
  iree_hal_amdxdna_device_options_initialize(&params);
  // Zero lets the runtime discover the usable grid on both Phoenix (4x4) and
  // Strix (4x8), including Phoenix's reserved metadata column adjustment.
  params.n_core_rows = 0;
  params.n_core_cols = 0;
  iree_hal_amdxdna_driver_options drv;
  iree_hal_amdxdna_driver_options_initialize(&drv);
  NPU_OPEN_CHECK(iree_hal_amdxdna_driver_create(
      iree_make_cstring_view("amdxdna"), &drv, &params, host, &c->driver));

  NPU_OPEN_CHECK(iree_async_proactor_pool_create(
      1, NULL, iree_async_proactor_pool_options_default(), host, &c->proactor));
  iree_hal_device_create_params_t dcp = iree_hal_device_create_params_default();
  dcp.proactor_pool = c->proactor;
  NPU_OPEN_CHECK(
      iree_hal_driver_create_default_device(c->driver, &dcp, host, &c->device));

  iree_runtime_session_options_t sopt;
  iree_runtime_session_options_initialize(&sopt);
  NPU_OPEN_CHECK(iree_runtime_session_create_with_device(
      c->instance, &sopt, c->device, host, &c->session));
  NPU_OPEN_CHECK(
      iree_runtime_session_append_bytecode_module_from_file(c->session, vmfb));
  c->alloc = iree_runtime_session_device_allocator(c->session);
  NPU_OPEN_CHECK(iree_runtime_call_initialize_by_name(
      c->session, iree_make_cstring_view(fn), &c->call));
  c->call_initialized = true;
#undef NPU_OPEN_CHECK
  return c;
}

// out = a @ b, all int32 [128,128] row-major. Returns 0 on success.
extern "C" int npu_mm128_i32(npu_ctx* c, const int32_t* a, const int32_t* b,
                             int32_t* out) {
  if (!c || !c->call_initialized || !c->device || !c->alloc) {
    return npu_invalid_argument("npu_mm128_i32 requires an open context");
  }
  if (!a || !b || !out) {
    return npu_invalid_argument("npu_mm128_i32 received a null buffer");
  }
  const iree_hal_dim_t shape[2] = {N, N};
  iree_hal_buffer_params_t bp = {};
  bp.type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL;
  bp.access = IREE_HAL_MEMORY_ACCESS_ALL;
  bp.usage = IREE_HAL_BUFFER_USAGE_DEFAULT;
  iree_hal_buffer_view_t* va = NULL;
  iree_hal_buffer_view_t* vb = NULL;
  iree_hal_buffer_view_t* vo = NULL;
  int result = 1;

  iree_runtime_call_reset(&c->call);
  if (!npu_status_ok(iree_hal_buffer_view_allocate_buffer_copy(
          c->device, c->alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
          IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
          iree_make_const_byte_span(a, N * N * sizeof(int32_t)), &va)))
    goto cleanup;
  if (!npu_status_ok(iree_hal_buffer_view_allocate_buffer_copy(
          c->device, c->alloc, 2, shape, IREE_HAL_ELEMENT_TYPE_INT_32,
          IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
          iree_make_const_byte_span(b, N * N * sizeof(int32_t)), &vb)))
    goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_inputs_push_back_buffer_view(&c->call, va)))
    goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_inputs_push_back_buffer_view(&c->call, vb)))
    goto cleanup;
  if (!npu_status_ok(iree_runtime_call_invoke(&c->call, 0))) goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_outputs_pop_front_buffer_view(&c->call, &vo)))
    goto cleanup;
  if (!npu_status_ok(iree_hal_device_transfer_d2h(
          c->device, iree_hal_buffer_view_buffer(vo), 0, out,
          N * N * sizeof(int32_t), IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT,
          iree_infinite_timeout())))
    goto cleanup;
  result = 0;

cleanup:
  if (vo) iree_hal_buffer_view_release(vo);
  if (vb) iree_hal_buffer_view_release(vb);
  if (va) iree_hal_buffer_view_release(va);
  iree_runtime_call_reset(&c->call);
  return result;
}

// out[M,N] f32 = a[M,K] @ b[K,N], bf16 inputs (uint16 bit-pattern). For the
// kernels tools/npu-trim extracts. Returns 0 on success.
extern "C" int npu_mm_bf16(npu_ctx* c, int32_t M, int32_t K, int32_t N,
                           const uint16_t* a, const uint16_t* b, float* out) {
  if (!c || !c->call_initialized || !c->device || !c->alloc) {
    return npu_invalid_argument("npu_mm_bf16 requires an open context");
  }
  if (!a || !b || !out) {
    return npu_invalid_argument("npu_mm_bf16 received a null buffer");
  }
  iree_host_size_t a_bytes = 0;
  iree_host_size_t b_bytes = 0;
  iree_host_size_t out_bytes = 0;
  if (!npu_matrix_byte_length(M, K, sizeof(uint16_t), &a_bytes) ||
      !npu_matrix_byte_length(K, N, sizeof(uint16_t), &b_bytes) ||
      !npu_matrix_byte_length(M, N, sizeof(float), &out_bytes)) {
    return npu_invalid_argument(
        "npu_mm_bf16 dimensions must be positive and fit host buffer sizes");
  }
  const iree_hal_dim_t sa[2] = {static_cast<iree_hal_dim_t>(M),
                                static_cast<iree_hal_dim_t>(K)};
  const iree_hal_dim_t sb[2] = {static_cast<iree_hal_dim_t>(K),
                                static_cast<iree_hal_dim_t>(N)};
  iree_hal_buffer_params_t bp = {};
  bp.type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL;
  bp.access = IREE_HAL_MEMORY_ACCESS_ALL;
  bp.usage = IREE_HAL_BUFFER_USAGE_DEFAULT;
  iree_hal_buffer_view_t* va = NULL;
  iree_hal_buffer_view_t* vb = NULL;
  iree_hal_buffer_view_t* vo = NULL;
  int result = 1;

  iree_runtime_call_reset(&c->call);
  if (!npu_status_ok(iree_hal_buffer_view_allocate_buffer_copy(
          c->device, c->alloc, 2, sa, IREE_HAL_ELEMENT_TYPE_BFLOAT_16,
          IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
          iree_make_const_byte_span(a, a_bytes), &va)))
    goto cleanup;
  if (!npu_status_ok(iree_hal_buffer_view_allocate_buffer_copy(
          c->device, c->alloc, 2, sb, IREE_HAL_ELEMENT_TYPE_BFLOAT_16,
          IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR, bp,
          iree_make_const_byte_span(b, b_bytes), &vb)))
    goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_inputs_push_back_buffer_view(&c->call, va)))
    goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_inputs_push_back_buffer_view(&c->call, vb)))
    goto cleanup;
  if (!npu_status_ok(iree_runtime_call_invoke(&c->call, 0))) goto cleanup;
  if (!npu_status_ok(
          iree_runtime_call_outputs_pop_front_buffer_view(&c->call, &vo)))
    goto cleanup;
  if (!npu_status_ok(iree_hal_device_transfer_d2h(
          c->device, iree_hal_buffer_view_buffer(vo), 0, out, out_bytes,
          IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout())))
    goto cleanup;
  result = 0;

cleanup:
  if (vo) iree_hal_buffer_view_release(vo);
  if (vb) iree_hal_buffer_view_release(vb);
  if (va) iree_hal_buffer_view_release(va);
  iree_runtime_call_reset(&c->call);
  return result;
}

extern "C" void npu_close(npu_ctx* c) {
  npu_ctx_destroy(c);
}
