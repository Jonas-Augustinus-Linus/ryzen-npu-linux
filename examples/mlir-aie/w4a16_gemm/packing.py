#!/usr/bin/env python3
# packing.py — host-side AWQ-g128 weight packer for the TileFuse W4A16 kernel
# (mix_int4_ATB.cc, glassescrab/mlir-aie@8c3d2be), plus the NumPy dequant
# reference used to verify the NPU result.
#
# Packed layout, one (k=128, n=64) B tile = 4352 bytes:
#   [0,    4096)  int4 weight data: a 16x8 row-major grid of 8x8 micro-tiles
#                 (i = k-group 0..15, j = n-group 0..7), each micro-tile
#                 row-major (k fast over 8 rows, n over 8 cols), two uint4
#                 values per byte, low nibble first (little-endian nibbles,
#                 matching AIE2P vector cast_to<uint4>() element order).
#   [4096, 4224)  64 bf16 scales, one per output column n, natural order.
#   [4224, 4352)  64 int8 zero-points as 8 groups of 16 bytes: for each
#                 n-group j, the 8 per-column zero-points duplicated twice
#                 (the kernel loads 16 and grow_replicate()s to a 64-lane
#                 vector over the row-major 8x8 micro-tile).
#
# k-tile == quantization group size (128), so every tile carries exactly one
# whole AWQ group per column and one scale/zero-point pair per column.
import numpy as np
from ml_dtypes import bfloat16

TILE_K = 128
TILE_N = 64
GROUP = 128  # AWQ group size == TILE_K, one group per tile
TILE_BYTES = TILE_K * TILE_N // 2 + TILE_N * 2 + TILE_N * 2  # 4096+128+128


def random_awq_weights(K, N, rng):
    """Random uint4 quantized weights + bf16 scales + uint4 zero-points.

    Returns (Bq, scales, zeros): Bq is (K, N) uint8 in [0, 15], scales is
    (K//GROUP, N) bf16 (positive, spanning a realistic magnitude range),
    zeros is (K//GROUP, N) uint8 in [0, 15].
    """
    assert K % GROUP == 0
    Bq = rng.integers(0, 16, size=(K, N), dtype=np.uint8)
    # LLM-ish per-group scales around 1e-2, bf16-representable by construction
    scales = (rng.random((K // GROUP, N), dtype=np.float32) * 0.05 + 0.005).astype(
        bfloat16
    )
    zeros = rng.integers(0, 16, size=(K // GROUP, N), dtype=np.uint8)
    return Bq, scales, zeros


def dequantize(Bq, scales, zeros):
    """NumPy model of the kernel's in-core dequant: bf16((q - zp) * scale).

    The kernel subtracts int8, converts to bf16, multiplies by the bf16
    scale and rounds the product back to bf16 before the MAC, so the
    reference rounds to bf16 at exactly the same point.
    """
    K, N = Bq.shape
    z = np.repeat(zeros, GROUP, axis=0).astype(np.float32)
    s = np.repeat(scales.astype(np.float32), GROUP, axis=0)
    return ((Bq.astype(np.float32) - z) * s).astype(bfloat16)


def pack_b(Bq, scales, zeros):
    """Pack (K, N) quantized weights into the flat DRAM byte stream.

    DRAM order is tile-column-major: for each n-tile j (N//TILE_N of them),
    all K//TILE_K packed 4352-byte tiles in k order, contiguously.  The
    design's per-column runtime taps slice this as a 2D view of shape
    (N//TILE_N, K//TILE_K * TILE_BYTES).
    """
    K, N = Bq.shape
    assert K % TILE_K == 0 and N % TILE_N == 0
    n_kt, n_nt = K // TILE_K, N // TILE_N
    out = np.empty((n_nt, n_kt, TILE_BYTES), dtype=np.uint8)
    for jt in range(n_nt):
        for it in range(n_kt):
            tile = Bq[it * TILE_K : (it + 1) * TILE_K, jt * TILE_N : (jt + 1) * TILE_N]
            # (i, r, j, c) -> (i, j, r, c): 16x8 grid of row-major 8x8 tiles
            nib = tile.reshape(16, 8, 8, 8).transpose(0, 2, 1, 3).reshape(-1)
            data = (nib[0::2] | (nib[1::2] << 4)).astype(np.uint8)  # low nibble first
            sc = scales[it, jt * TILE_N : (jt + 1) * TILE_N].astype(bfloat16)
            zp = zeros[it, jt * TILE_N : (jt + 1) * TILE_N]
            zp_dup = np.broadcast_to(zp.reshape(8, 1, 8), (8, 2, 8)).reshape(-1)
            out[jt, it, :4096] = data
            out[jt, it, 4096:4224] = sc.view(np.uint8)
            out[jt, it, 4224:] = zp_dup.astype(np.uint8)
    return out.reshape(-1)


def reference_matmul(A, Bdq, tilewise_bf16=False, tile_k=TILE_K):
    """f32 reference C = A @ Bdq.

    With tilewise_bf16=True, models the kernel's bf16 C accumulator: the
    partial C is rounded to bf16 after every k-tile (the kernel stores C as
    bf16 between k-tiles), which is the honest numerics model of the NPU
    result at large K.
    """
    A32 = A.astype(np.float32)
    B32 = Bdq.astype(np.float32)
    if not tilewise_bf16:
        return A32 @ B32
    K = A.shape[1]
    C = np.zeros((A.shape[0], Bdq.shape[1]), dtype=np.float32)
    for it in range(K // tile_k):
        sl = slice(it * tile_k, (it + 1) * tile_k)
        C = (C + A32[:, sl] @ B32[sl, :]).astype(bfloat16).astype(np.float32)
    return C
