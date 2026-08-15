"""Fast AMD XDNA1/XDNA2 NPU access from Python via libnpu.so (ctypes).

Load a .vmfb once, call the NPU many times in-process (~3.7 ms/call vs ~41 ms
for spawning iree-run-module, measured on a Ryzen 7840U/XDNA1). Used by the
wake-word detector and the camera daemon.

    from npu import NPU
    npu = NPU("/tmp/matmul_npu.vmfb")          # i32 128x128 @matmul
    out = npu.matmul(a, b)                      # a,b int32 [128,128] -> [128,128]
    npu.close()
"""
import ctypes
import os
import threading
import numpy as np

_SO = os.environ.get("LIBNPU", os.path.join(os.path.dirname(os.path.abspath(__file__)), "libnpu.so"))
_lib = ctypes.CDLL(_SO)
_i32p = ctypes.POINTER(ctypes.c_int32)
_lib.npu_open.restype = ctypes.c_void_p
_lib.npu_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
_lib.npu_mm128_i32.restype = ctypes.c_int
_lib.npu_mm128_i32.argtypes = [ctypes.c_void_p, _i32p, _i32p, _i32p]
_lib.npu_close.restype = None
_lib.npu_close.argtypes = [ctypes.c_void_p]

# bf16 matmul (any [M,K]x[K,N] -> [M,N] f32) — for tools/npu-trim kernels.
_u16p = ctypes.POINTER(ctypes.c_uint16)
_f32p = ctypes.POINTER(ctypes.c_float)
try:
    _lib.npu_mm_bf16.restype = ctypes.c_int
    _lib.npu_mm_bf16.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32,
                                 ctypes.c_int32, _u16p, _u16p, _f32p]
    _HAS_BF16 = True
except AttributeError:
    _HAS_BF16 = False  # older libnpu.so without bf16 support

N = 128


class NPU:
    def __init__(self, vmfb, fn="module.matmul"):
        # One IREE runtime call object is reused for low dispatch overhead.
        # Serialize use and close so ctypes releasing the GIL cannot race it.
        self._lock = threading.Lock()
        self.h = _lib.npu_open(vmfb.encode(), fn.encode())
        if not self.h:
            raise RuntimeError(f"npu_open failed for {vmfb}")

    def _require_open(self):
        if not getattr(self, "h", None):
            raise RuntimeError("NPU context is closed")

    def matmul(self, a, b):
        """a @ b on the NPU. a,b: int32 [128,128]; returns int32 [128,128]."""
        with self._lock:
            self._require_open()
            a = np.ascontiguousarray(a, np.int32)
            b = np.ascontiguousarray(b, np.int32)
            if a.shape != (N, N) or b.shape != (N, N):
                raise ValueError(
                    f"matmul requires two ({N}, {N}) arrays; got {a.shape} and {b.shape}"
                )
            out = np.empty((N, N), np.int32)
            rc = _lib.npu_mm128_i32(
                self.h,
                a.ctypes.data_as(_i32p),
                b.ctypes.data_as(_i32p),
                out.ctypes.data_as(_i32p),
            )
            if rc:
                raise RuntimeError("npu_mm128_i32 failed")
            return out

    def matmul_bf16(self, a, b):
        """a @ b on the NPU. a:[M,K], b:[K,N] (any numpy float, cast to bf16);
        returns [M,N] float32. The kernel's vmfb must match these shapes."""
        with self._lock:
            self._require_open()
            if not _HAS_BF16:
                raise RuntimeError("loaded libnpu.so does not provide npu_mm_bf16")
            import ml_dtypes
            a = np.ascontiguousarray(a, ml_dtypes.bfloat16)
            b = np.ascontiguousarray(b, ml_dtypes.bfloat16)
            if a.ndim != 2 or b.ndim != 2:
                raise ValueError(
                    f"matmul_bf16 requires two rank-2 arrays; got {a.shape} and {b.shape}"
                )
            M, K = a.shape
            K2, N = b.shape
            if K != K2:
                raise ValueError(
                    f"matmul_bf16 inner dimensions must match; got {a.shape} and {b.shape}"
                )
            if min(M, K, N) <= 0:
                raise ValueError("matmul_bf16 dimensions must be positive")
            if max(M, K, N) > np.iinfo(np.int32).max:
                raise ValueError("matmul_bf16 dimensions exceed the C ABI int32 limit")
            out = np.empty((M, N), np.float32)
            rc = _lib.npu_mm_bf16(
                self.h, M, K, N,
                a.view(np.uint16).ctypes.data_as(_u16p),
                b.view(np.uint16).ctypes.data_as(_u16p),
                out.ctypes.data_as(_f32p))
            if rc:
                raise RuntimeError("npu_mm_bf16 failed")
            return out

    def close(self):
        with self._lock:
            if getattr(self, "h", None):
                _lib.npu_close(self.h)
                self.h = None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


if __name__ == "__main__":  # self-test
    import sys
    vmfb = sys.argv[1] if len(sys.argv) > 1 else "/tmp/matmul_npu.vmfb"
    with NPU(vmfb) as npu:
        out = npu.matmul(np.full((N, N), 2, np.int32), np.full((N, N), 3, np.int32))
        mismatch_count = int(np.count_nonzero(out != 768))
        print(f"matmul(2,3): {out.size - mismatch_count}/{out.size} elements "
              f"equal 768  {'OK' if mismatch_count == 0 else 'MISMATCH'}")
        raise SystemExit(0 if mismatch_count == 0 else 1)
