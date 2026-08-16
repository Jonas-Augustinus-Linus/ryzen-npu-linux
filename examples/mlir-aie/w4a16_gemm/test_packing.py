#!/usr/bin/env python3
# test_packing.py — bit-exactness check of the host-side packer against a
# scalar NumPy model of the kernel's read path (no NPU or Peano needed).
#
# For every packed tile this walks mix_int4_ATB.cc's exact load sequence —
# 32-byte int4 chunk per 8x8 micro-tile, low-nibble-first unpack,
# grow_replicate'd 16-byte zero-point rows, grow_replicate'd 8-lane bf16
# scale rows, (q - zp) * scale rounded to bf16 — rebuilds the dequantized
# weight matrix, and requires it to be bit-identical to packing.dequantize().
# The column-distribution DRAM ordering of pack_b is exercised too (a
# non-trivial n_aie_cols so the tile permutation actually permutes).
#
# Run:  python test_packing.py
import sys

import numpy as np
from ml_dtypes import bfloat16

from packing import (
    TILE_BYTES,
    TILE_K,
    TILE_N,
    assert_packed_for,
    dequantize,
    pack_b,
    random_awq_weights,
)


def rebuild_via_kernel_read_path(packed, K, N, n_aie_cols):
    """Scalar model of mix_int4_ATB.cc's dequant loads over the whole blob."""
    n_kt, n_nt = K // TILE_K, N // TILE_N
    view = np.asarray(packed).reshape(n_nt, n_kt, TILE_BYTES)
    # Invert pack_b's [col][jj] DRAM row order back to n-tile index jt.
    order = [
        col + jj * n_aie_cols
        for col in range(n_aie_cols)
        for jj in range(n_nt // n_aie_cols)
    ]
    colA, colB = TILE_K // 8, TILE_N // 8
    got = np.zeros((K, N), dtype=bfloat16)
    for row, jt in enumerate(order):
        for it in range(n_kt):
            t = view[row, it]
            data, sc_b, zp_b = t[:4096], t[4096:4224], t[4224:]
            sc = sc_b.copy().view(bfloat16)  # 64 per-column scales
            for i in range(colA):
                for j in range(colB):
                    chunk = data[(i * colB + j) * 32 : (i * colB + j) * 32 + 32]
                    nib = np.empty(64, np.uint8)
                    nib[0::2] = chunk & 0xF  # cast_to<uint4>: low nibble first
                    nib[1::2] = chunk >> 4
                    zp16 = zp_b[j * 16 : j * 16 + 16].astype(np.int8)
                    zp64 = np.tile(zp16, 4)  # grow_replicate<64>
                    sc64 = np.tile(sc[j * 8 : j * 8 + 8], 8)  # grow_replicate
                    dq = (
                        (nib.astype(np.int8) - zp64).astype(np.float32)
                        * sc64.astype(np.float32)
                    ).astype(bfloat16)
                    got[
                        it * TILE_K + i * 8 : it * TILE_K + i * 8 + 8,
                        jt * TILE_N + j * 8 : jt * TILE_N + j * 8 + 8,
                    ] = dq.reshape(8, 8)  # micro-tile is row-major 8x8
    return got


def main():
    rng = np.random.default_rng(7)
    ok = True
    # n_aie_cols=2 with 4 n-tiles gives the non-identity order [0, 2, 1, 3];
    # n_aie_cols=1 is the identity layout.
    for K, N, cols in ((256, 128, 1), (256, 256, 2)):
        Bq, scales, zeros = random_awq_weights(K, N, rng)
        packed = pack_b(Bq, scales, zeros, n_aie_cols=cols)
        assert packed.size == (N // TILE_N) * (K // TILE_K) * TILE_BYTES
        assert_packed_for(packed, cols)
        try:
            assert_packed_for(packed, cols + 7)
        except ValueError:
            pass
        else:
            raise AssertionError("assert_packed_for missed a column mismatch")
        got = rebuild_via_kernel_read_path(packed, K, N, cols)
        ref = dequantize(Bq, scales, zeros)
        exact = np.array_equal(got.view(np.uint16), ref.view(np.uint16))
        print(
            f"K={K} N={N} n_aie_cols={cols}: kernel-read-path rebuild "
            f"{'==' if exact else '!='} dequantize()  "
            f"{'PASS' if exact else 'FAIL'}"
        )
        ok &= exact
    if not ok:
        sys.exit(1)
    print("PASS: packer is bit-exact against the kernel's read path")


if __name__ == "__main__":
    main()
