#!/usr/bin/env python3
# w4a16_gemm.py — TileFuse-style W4A16 GEMM on the XDNA2 NPU (IRON 1.4.x).
#
# C[bf16] = A[bf16] @ dequant(B[int4 AWQ-g128])  on the whole 4x8 Strix array.
#
# B streams as packed 4352-byte tiles (4096 B int4 data + 128 B bf16
# per-column scales + 128 B duplicated int8 zero-points; see packing.py) and
# is dequantized in-core into a 16 KB weight-stationary L1 cache by the
# vendored TileFuse kernel (mix_int4_ATB.cc, glassescrab/mlir-aie@8c3d2be,
# compiled by Peano for aie2p against mlir-aie 1.4.1 headers).  The dataflow
# is the stock whole_array GEMM with two W4A16-specific twists:
#
#  * the B ObjectFifos carry opaque packed bytes (3.76x less DRAM traffic
#    than bf16 B), with no stream-dims transformation;
#  * the kernel processes half an M-tile per call (DIV=2, internal state):
#    A's L2->L1 fifo produces (m, k) tiles mem-side but the cores consume
#    (m/2, k) halves (`consumer_obj_type`), and the core calls matmul twice
#    per B tile — dequant runs only on the first call and the second reuses
#    the L1 cache.
#
# Fixed inner tile: m=64, k=128 (= AWQ group size), n=64, r=s=t=8.
#
# Run:  ./run.sh   (or: source ../../../scripts/mlir-aie-env.sh &&
#                        python w4a16_gemm.py -M 512 -K 512 -N 512)
import argparse
import os
import re
import sys

import numpy as np
from ml_dtypes import bfloat16

import aie.iron as iron
from aie.iron import (
    CompileTime,
    In,
    Kernel,
    ObjectFifo,
    Out,
    Program,
    Runtime,
    TaskGroup,
    Worker,
)
from aie.iron.controlflow import range_
from aie.iron.dataflow import ObjectFifoLink
from aie.iron.device import AnyMemTile
from aie.helpers.taplib import TensorTiler2D
from aie.utils.benchmark import print_benchmark, run_iters

from packing import (
    TILE_BYTES,
    assert_packed_for,
    dequantize,
    pack_b,
    random_awq_weights,
    reference_matmul,
)

HERE = os.path.dirname(os.path.abspath(__file__))

# Kernel-fixed geometry (must match mix_int4_ATB.cc's -DDIM_* build)
M_TILE, K_TILE, N_TILE = 64, 128, 64
R = S = T = 8  # aie::mmul micro-kernel dims (8x8x8 bf16 on AIE2P)


def _kernel_div():
    """Read the kernel's ``constexpr int DIV`` out of the vendored source.

    DIV couples two layers that cannot see each other: the kernel processes
    m/DIV rows per call and its static ``g_counter`` cycles modulo DIV, while
    the Python design sizes the A L1 half-tiles and the per-B-tile call count
    to match.  The constexpr has no ``#ifndef`` guard, so it cannot be
    overridden with ``-D`` without editing the byte-pinned vendored file —
    deriving it from the source keeps the two sides from drifting silently.
    """
    with open(os.path.join(HERE, "mix_int4_ATB.cc")) as f:
        m = re.search(r"^constexpr int DIV = (\d+);", f.read(), re.M)
    if m is None:
        raise RuntimeError("cannot find 'constexpr int DIV' in mix_int4_ATB.cc")
    return int(m.group(1))


DIV = _kernel_div()
assert M_TILE % DIV == 0


def _kernels():
    """The vendored TileFuse kernel: one .o exporting matmul + zero symbols."""
    a_l1_ty = np.ndarray[(M_TILE // DIV, K_TILE), np.dtype[bfloat16]]
    b_l1_ty = np.ndarray[(TILE_BYTES,), np.dtype[np.int8]]
    c_l1_ty = np.ndarray[(M_TILE, N_TILE), np.dtype[bfloat16]]
    matmul = iron.ExternalFunction(
        "matmul_bf16_bf16",
        source_file=os.path.join(HERE, "mix_int4_ATB.cc"),
        arg_types=[a_l1_ty, b_l1_ty, c_l1_ty],
        include_dirs=[HERE],
        compile_flags=[
            "-Dbf16_bf16_ONLY",
            f"-DDIM_M={M_TILE}",
            f"-DDIM_K={K_TILE}",
            f"-DDIM_N={N_TILE}",
            # Route the kernel's 8x8x8 bf16 aie::mmul through the AIE2P bfp16
            # datapath.  Without this, aie_api composes it from 1/4-rate
            # native bf16 MACs: 0.94 vs 5.81 TOPS at 2048^3 in the controlled
            # A/B (6.2x); the final tuned run measures 5.94 (GOTCHAS M12).
            "-DAIE_API_EMULATE_BFLOAT16_MMUL_WITH_BFP16",
            "-Wno-missing-template-arg-list-after-template-kw",
        ],
    )
    zero = Kernel("zero_bf16", matmul.object_file_name, [c_l1_ty])
    return matmul, zero, a_l1_ty, b_l1_ty, c_l1_ty


def _build_design(M, K, N, n_aie_cols):
    m, k, n = M_TILE, K_TILE, N_TILE
    n_aie_rows = 4
    n_aie_cores = n_aie_rows * n_aie_cols
    fifo_depth = 2

    matmul_kernel, zero_kernel, A_l1_ty, B_l1_ty, C_l1_ty = _kernels()

    assert M % (m * n_aie_rows) == 0
    assert K % k == 0
    assert N % (n * n_aie_cols) == 0
    assert n_aie_cols in (4, 8), (
        "this design keeps the stock per-shim A layout; <4 columns would "
        "need the stacked-row split (not implemented)"
    )
    # The runtime sequence pairs row-blocks ping/pong (tb_n_rows = 2), so the
    # row-block count must be even — odd counts crash later inside
    # TensorTiler2D.step_tiler with an opaque partial-group error.
    assert (M // (m * n_aie_rows)) % 2 == 0, (
        f"M={M}: M / (m*n_aie_rows) = {M // (m * n_aie_rows)} row blocks must "
        f"be even (M a multiple of {2 * m * n_aie_rows})"
    )
    # The C write-back BD stride is m*n_aie_rows*N elements and must stay
    # within the shim DMA's inclusive [1, 2^20] stride range (GOTCHAS M14);
    # beyond it the design fails minutes later in aiecc with a cryptic
    # 'Stride 3 exceeds the [1:1048576] range' verifier error.
    assert m * n_aie_rows * N <= 1 << 20, (
        f"N={N} too large: C write-back stride m*n_aie_rows*N = "
        f"{m * n_aie_rows * N} exceeds the shim DMA stride range 2^20 "
        f"(max N = {(1 << 20) // (m * n_aie_rows)} for m={m})"
    )

    n_tiles_per_core = (M // m) * (N // n) // n_aie_cores
    n_shim_mem_A = min(n_aie_rows, n_aie_cols)
    n_A_tiles_per_shim = 1  # guaranteed by the n_aie_cols assert above

    A_ty = np.ndarray[(M * K,), np.dtype[bfloat16]]
    B_ty = np.ndarray[((N // n) * (K // k) * TILE_BYTES,), np.dtype[np.int8]]
    C_ty = np.ndarray[(M * N,), np.dtype[bfloat16]]
    A_l2_ty = np.ndarray[(m * k,), np.dtype[bfloat16]]  # one (m, k) tile
    A_l2l1_prod_ty = np.ndarray[(m, k), np.dtype[bfloat16]]
    C_l2_ty = np.ndarray[(m * n * n_aie_rows,), np.dtype[bfloat16]]

    A_l3l2_fifos = []
    A_l2l1_fifos = []
    B_l3l2_fifos = []
    B_l2l1_fifos = []
    C_l1l2_fifos = [[] for _ in range(n_aie_rows)]
    C_l2l3_fifos = []

    # A: one shim/mem column per core row; the L2->L1 fifo streams the full
    # (m, k) tile in the stock micro-tiled order (row-blocks outermost), which
    # is exactly two consecutive micro-tiled (m/2, k) halves — the cores
    # consume it at half-tile granularity via consumer_obj_type.
    a_dims = [(m // R, R * k), (k // S, S), (R, k), (S, 1)]
    for i in range(n_shim_mem_A):
        a_l3l2 = ObjectFifo(A_l2_ty, name=f"A_L3L2_{i}", depth=fifo_depth)
        A_l3l2_fifos.append(a_l3l2)
        a_l2l1 = ObjectFifo(
            A_l2l1_prod_ty,
            name=f"A_L2L1_{i}",
            depth=fifo_depth,
            dims_to_stream=a_dims,
            consumer_obj_type=A_l1_ty,
        )
        A_l2l1_fifos.append(a_l2l1)
        ObjectFifoLink(a_l3l2.cons(), [a_l2l1.prod()], AnyMemTile, [], [])

    # B: opaque packed tiles, one tile per fifo object, no transformation.
    for col in range(n_aie_cols):
        b_l3l2 = ObjectFifo(B_l1_ty, name=f"B_L3L2_{col}", depth=fifo_depth)
        B_l3l2_fifos.append(b_l3l2)
        B_l2l1_fifos.append(
            b_l3l2.cons().forward(obj_type=B_l1_ty, name=f"B_L2L1_{col}")
        )

        # C: stock whole_array join + stream-out (row-major C).
        c_dims = [(m // R, R * n), (R, T), (n // T, R * T), (T, 1)]
        c_l2l3 = ObjectFifo(
            C_l2_ty, name=f"C_L2L3_{col}", depth=fifo_depth, dims_to_stream=c_dims
        )
        C_l2l3_fifos.append(c_l2l3)
        of_offsets = [m * n * i for i in range(n_aie_rows)]
        c_tmp_fifos = c_l2l3.prod().join(
            of_offsets,
            obj_types=[C_l1_ty] * n_aie_rows,
            names=[f"C_L1L2_{col}_{row}" for row in range(n_aie_rows)],
            depths=[fifo_depth] * n_aie_rows,
        )
        for j in range(n_aie_rows):
            C_l1l2_fifos[j].append(c_tmp_fifos[j])

    def core_fn(in_a, in_b, out_c, zero, matmul):
        loop = range(1)  # stock workaround for issue #1547
        if n_tiles_per_core > 1:
            loop = range_(n_tiles_per_core)
        for _ in loop:
            elem_out = out_c.acquire(1)
            zero(elem_out)
            for _ in range_(K // k):
                elem_in_b = in_b.acquire(1)
                # INVARIANT: matmul is called exactly DIV times per acquired
                # B tile.  The kernel's static g_counter cycles modulo DIV
                # (call 0 dequantizes the tile into the L1 weight cache and
                # computes rows [0, m/DIV); later calls reuse the cache for
                # the following row slices) and persists across calls — any
                # other call count desyncs it permanently and silently
                # corrupts every subsequent output tile on that core.
                for _ in range(DIV):
                    elem_in_a = in_a.acquire(1)
                    matmul(elem_in_a, elem_in_b, elem_out)
                    in_a.release(1)
                in_b.release(1)
            out_c.release(1)

    workers = Worker.grid(
        n_aie_rows,
        n_aie_cols,
        lambda row, col: Worker(
            core_fn,
            [
                A_l2l1_fifos[row].cons(),
                B_l2l1_fifos[col].cons(),
                C_l1l2_fifos[row][col].prod(),
                zero_kernel,
                matmul_kernel,
            ],
            stack_size=0xD00,
        ),
    )

    # Host-side access patterns (stock structure; B works on the packed view)
    tb_max_n_rows = 4
    tb_n_rows = tb_max_n_rows // 2

    A_tiles = TensorTiler2D.group_tiler(
        (M, K),
        (m, k),
        (1, K // k),
        pattern_repeat=N // n // n_aie_cols,
        prune_step=False,
    )
    # B is packed in column-distribution order (see packing.pack_b), so each
    # column's whole per-pass stream is one contiguous run and one tap.  A
    # strided multi-row tap would need a 4D buffer descriptor the shim DMA
    # cannot express once the 69632-byte row itself takes two dims (observed
    # aie.dma_bd verifier failure at 2048^3), and per-row fills exhaust the
    # 16 buffer descriptors of a shim tile.
    b_col_bytes = (N // n // n_aie_cols) * (K // k) * TILE_BYTES
    B_tiles = TensorTiler2D.simple_tiler(
        (n_aie_cols, b_col_bytes),
        (1, b_col_bytes),
        prune_step=False,
    )
    C_tiles = TensorTiler2D.step_tiler(
        (M, N),
        (m * n_aie_rows, n),
        tile_group_repeats=(tb_n_rows, N // n // n_aie_cols),
        tile_group_steps=(1, n_aie_cols),
        prune_step=False,
    )

    flat_workers = [w for row in workers for w in row]
    A_prods = [f.prod() for f in A_l3l2_fifos]
    B_prods = [f.prod() for f in B_l3l2_fifos]
    C_conses = [f.cons() for f in C_l2l3_fifos]

    def sequence(A, B, C, A_hs, B_hs, C_hs):
        c_index = 0
        tg = TaskGroup()
        for tb in range(iron.ceildiv(M // m // n_aie_rows, tb_max_n_rows)):
            for pingpong in [0, 1]:
                if c_index >= len(C_tiles):
                    break
                row_base = tb * tb_max_n_rows + pingpong * tb_max_n_rows // 2
                current_tb_n_rows = min(
                    [tb_max_n_rows // 2, M // m // n_aie_rows - row_base]
                )
                for col in range(n_aie_cols):
                    C_hs[col].drain(C, tap=C_tiles[c_index], wait=True, group=tg)
                    c_index += 1
                    for tile_row in range(current_tb_n_rows):
                        tile_offset = (
                            (row_base + tile_row) * n_shim_mem_A + col
                        ) % len(A_tiles)
                        if col < n_aie_rows:
                            A_hs[col].fill(A, tap=A_tiles[tile_offset], group=tg)
                        B_hs[col].fill(B, tap=B_tiles[col], group=tg)
                if tb > 0 or (tb == 0 and pingpong > 0):
                    tg.finish()
                    tg = TaskGroup()
        tg.finish()

    rt = Runtime(sequence, [A_ty, B_ty, C_ty, A_prods, B_prods, C_conses])
    program = Program(iron.get_current_device(), rt, workers=flat_workers)
    return program.resolve_program()


@iron.jit(aiecc_flags=["--alloc-scheme=basic-sequential"])
def w4a16_gemm(
    A: In,
    B: In,
    C: Out,
    *,
    M: CompileTime[int],
    K: CompileTime[int],
    N: CompileTime[int],
    n_aie_cols: CompileTime[int],
):
    return _build_design(M, K, N, n_aie_cols)


def main():
    p = argparse.ArgumentParser(prog="W4A16 GEMM (whole array)")
    p.add_argument("-M", type=int, default=512)
    p.add_argument("-K", type=int, default=512)
    p.add_argument("-N", type=int, default=512)
    p.add_argument("--n-aie-cols", type=int, choices=[4, 8], default=8)
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--seed", type=int, default=1726250518)
    p.add_argument("--rtol", type=float, default=5e-2,
                   help="PASS/FAIL bound on max |got - ref| / (|A| @ |B_dq|)")
    p.add_argument("--atol", type=float, default=5e-2,
                   help="floors the |ref| denominator of the *printed* "
                        "relative-error statistics only; it does not "
                        "participate in the PASS/FAIL verdict (which is "
                        "--rtol against the accumulation scale)")
    args = p.parse_args()
    M, K, N = args.M, args.K, args.N

    n_aie_rows = 4
    if M % (M_TILE * n_aie_rows):
        p.error(f"-M must be a multiple of {M_TILE * n_aie_rows}")
    if (M // M_TILE // n_aie_rows) % 2:
        p.error(f"-M / {M_TILE * n_aie_rows} must be even (transfer blocks)")
    if K % K_TILE:
        p.error(f"-K must be a multiple of {K_TILE} (AWQ group size)")
    if N % (N_TILE * args.n_aie_cols):
        p.error(f"-N must be a multiple of {N_TILE * args.n_aie_cols}")

    dev = iron.get_current_device()
    cols = dev.cols
    print(f"device: {type(dev).__name__}  columns: {cols}")
    if cols < args.n_aie_cols:
        p.error(f"--n-aie-cols {args.n_aie_cols} > device columns {cols}")

    rng = np.random.default_rng(args.seed)
    A_np = (rng.random((M, K), dtype=np.float32) - 0.5).astype(bfloat16)
    Bq, scales, zeros = random_awq_weights(K, N, rng)
    B_packed = pack_b(Bq, scales, zeros, args.n_aie_cols)
    # The packed byte order depends on the column count and nothing at run
    # time would catch a mismatch (same size, same dtype, silently wrong C).
    assert_packed_for(B_packed, args.n_aie_cols)

    A_t = iron.tensor(A_np, dtype=bfloat16, device="npu")
    B_t = iron.tensor(B_packed.view(np.int8), dtype=np.int8, device="npu")
    C_t = iron.zeros((M, N), dtype=bfloat16, device="npu")

    bench = run_iters(
        w4a16_gemm,
        A_t,
        B_t,
        C_t,
        M=M,
        K=K,
        N=N,
        n_aie_cols=args.n_aie_cols,
        warmup=args.warmup,
        iters=args.iters,
    )

    # References: plain f32 GEMM over dequantized weights, and the
    # "kernel-faithful" variant that rounds C to bf16 after every k-tile
    # exactly like the bf16 C accumulator on the NPU does.
    Bdq = dequantize(Bq, scales, zeros)
    ref = reference_matmul(A_np, Bdq)
    ref_tile = reference_matmul(A_np, Bdq, tilewise_bf16=True)
    got = C_t.numpy().reshape(M, N).astype(np.float32)

    def err_stats(reference):
        denom = np.maximum(np.abs(reference), args.atol)
        rel = np.abs(got - reference) / denom
        return rel.max(), rel.mean()

    max_rel, mean_rel = err_stats(ref)
    max_rel_t, mean_rel_t = err_stats(ref_tile)

    # PASS criterion: elementwise error bounded against the accumulation
    # scale S = (|A| @ |Bdq|), the natural dot-product error bound.  Signed
    # zero-mean inputs make tiny C elements from catastrophic cancellation,
    # and AIE2P's bfp16 block-float datapath truncates 8-value blocks against
    # their shared exponent — so error relative to |C| is unbounded on
    # near-zero outputs, while error relative to S stays at bf16/bfp16 level
    # (~1e-2).  A real dataflow bug (swapped tile, wrong scale) produces
    # errors on the order of S itself, ~100x this tolerance.
    scale = np.abs(A_np.astype(np.float32)) @ np.abs(Bdq.astype(np.float32))
    norm_err = np.abs(got - ref) / (scale + 1e-30)
    max_norm, mean_norm = norm_err.max(), norm_err.mean()

    print_benchmark(bench)
    ops = 2.0 * M * K * N
    if bench.npu is not None and bench.npu.avg_us > 0:
        tops = ops / (bench.npu.avg_us * 1e-6) / 1e12
        print(f"{M}x{K}x{N}, {args.n_aie_cols} cols: {tops:.2f} TOPS (effective)")
    print(f"rel err vs f32 reference:        max {max_rel:.3e}  mean {mean_rel:.3e}")
    print(f"rel err vs tilewise-bf16 ref:    max {max_rel_t:.3e}  mean {mean_rel_t:.3e}")
    print(f"err / accumulation scale |A||B|: max {max_norm:.3e}  mean {mean_norm:.3e}")

    if max_norm < args.rtol:
        print(f"PASS  (max normalized err {max_norm:.3e} < {args.rtol})")
        sys.exit(0)
    n_bad = int(np.sum(norm_err >= args.rtol))
    print(f"FAIL  ({n_bad}/{got.size} elements outside tolerance)")
    bad = np.unravel_index(np.argmax(norm_err), got.shape)
    print(f"worst at {bad}: got {got[bad]!r} expected {ref[bad]!r} scale {scale[bad]!r}")
    sys.exit(1)


if __name__ == "__main__":
    main()
