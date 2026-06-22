"""Fast XDNA1 NPU access from Python via libnpu.so (ctypes).

Load a .vmfb once, call the NPU many times in-process (~3.7 ms/call vs ~41 ms
for spawning iree-run-module). Used by the wake-word detector and the camera
daemon.

    from npu import NPU
    npu = NPU("/tmp/matmul_npu.vmfb")          # i32 128x128 @matmul
    out = npu.matmul(a, b)                      # a,b int32 [128,128] -> [128,128]
    npu.close()
"""
import ctypes
import os
import numpy as np

_SO = os.environ.get("LIBNPU", os.path.join(os.path.dirname(os.path.abspath(__file__)), "libnpu.so"))
_lib = ctypes.CDLL(_SO)
_i32p = ctypes.POINTER(ctypes.c_int32)
_lib.npu_open.restype = ctypes.c_void_p
_lib.npu_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
_lib.npu_mm128_i32.restype = ctypes.c_int
_lib.npu_mm128_i32.argtypes = [ctypes.c_void_p, _i32p, _i32p, _i32p]
_lib.npu_close.argtypes = [ctypes.c_void_p]

N = 128


class NPU:
    def __init__(self, vmfb, fn="module.matmul"):
        self.h = _lib.npu_open(vmfb.encode(), fn.encode())
        if not self.h:
            raise RuntimeError(f"npu_open failed for {vmfb}")

    def matmul(self, a, b):
        """a @ b on the NPU. a,b: int32 [128,128]; returns int32 [128,128]."""
        a = np.ascontiguousarray(a, np.int32)
        b = np.ascontiguousarray(b, np.int32)
        assert a.shape == (N, N) and b.shape == (N, N)
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

    def close(self):
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
        print(f"matmul(2,3)[0,0] = {int(out[0, 0])}  (expect 768)  "
              f"{'OK' if out[0, 0] == 768 else 'MISMATCH'}")
