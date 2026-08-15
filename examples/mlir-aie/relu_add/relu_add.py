#!/usr/bin/env python3
# relu_add.py — custom IRON kernel driver (XDNA1 npu1 / XDNA2 npu2).
#
# Runs  out = relu(a + b) = max(a + b, 0)  on the Ryzen AI NPU and checks it
# against a numpy golden. Demonstrates the author-your-own-kernel path: an
# ExternalFunction (our relu_add.cc) compiled by Peano for the detected
# generation (aie2 on Phoenix, aie2p on Strix) and run by iron.jit.
#
# Two designs, both verified:
#   single  one Worker on one compute tile — the original XDNA1 design
#   array   transform_parallel_binary — one Worker per column (× DMA channels),
#           auto-scaled to the array: 4 columns on npu1, 8 on npu2
#
# Run:  ./run.sh   (or: source ../../../scripts/mlir-aie-env.sh && python relu_add.py)
import argparse
import os
import sys

import numpy as np

import aie.iron as iron
from aie.iron import CompileTime, In, Out
from aie.utils.benchmark import print_benchmark, run_iters

HERE = os.path.dirname(os.path.abspath(__file__))


def _kernel(tile_size):
    """Handle to our external C++ kernel; arg_types = [a_tile, b_tile, out_tile, N]."""
    tile_ty = np.ndarray[(tile_size,), np.dtype[np.int32]]
    return iron.ExternalFunction(
        "relu_add_i32",
        source_file=os.path.join(HERE, "relu_add.cc"),
        arg_types=[tile_ty, tile_ty, tile_ty, np.int32],
    )


@iron.jit
def relu_add_single(
    a: In,
    b: In,
    out: Out,
    *,
    num_elements: CompileTime[int],
    tile_size: CompileTime[int],
):
    tensor_ty = np.ndarray[(num_elements,), np.dtype[np.int32]]
    return iron.algorithms.transform_binary(
        _kernel(tile_size), tensor_ty, tile_size=tile_size
    )


@iron.jit
def relu_add_array(
    a: In,
    b: In,
    out: Out,
    *,
    num_elements: CompileTime[int],
    tile_size: CompileTime[int],
):
    # num_channels stays 1: a binary kernel already needs 2 shim MM2S DMA
    # channels per column (one per input) — the shim has exactly 2.
    tensor_ty = np.ndarray[(num_elements,), np.dtype[np.int32]]
    return iron.algorithms.transform_parallel_binary(
        _kernel(tile_size), tensor_ty, tile_size=tile_size, num_channels=1
    )


def _verify_and_report(name, a, b, out, bench):
    got = out.numpy()
    expected = np.maximum(a.numpy() + b.numpy(), 0)
    mismatches = int(np.sum(got != expected))
    print(f"\n--- {name} ---")
    print_benchmark(bench)
    if bench.npu is not None and bench.npu.avg_us > 0:
        gbps = 3 * got.nbytes / (bench.npu.avg_us * 1e-6) / 1e9
        print(f"Effective DDR throughput (2 in + 1 out): {gbps:.1f} GB/s")
    if mismatches == 0:
        print(f"PASS ({name})")
        return True
    print(f"FAIL ({name})  {mismatches} mismatches")
    print("got[:8] =", got[:8])
    print("exp[:8] =", expected[:8])
    return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("-n", "--num-elements", type=int, default=1 << 20,
                   help="int32 elements per tensor (default: %(default)s)")
    p.add_argument("--tile-size", type=int, default=1024,
                   help="elements per Worker tile (default: %(default)s; "
                        "3 double-buffered int32 tile buffers must fit the "
                        "64KB core-local memory)")
    args = p.parse_args()
    n, tile = args.num_elements, args.tile_size

    dev = iron.get_current_device()
    cols = dev.cols
    print(f"device: {type(dev).__name__}  columns: {cols}  "
          f"({'XDNA2/Strix' if cols == 8 else 'XDNA1/Phoenix'})")

    per_round = tile * cols
    if n % per_round:
        sys.exit(f"num_elements ({n}) must be a multiple of "
                 f"tile_size*cols ({per_round})")

    # NPU-accessible tensors; include negatives so ReLU actually clips
    a = iron.randint(-50, 50, (n,), dtype=np.int32, device="npu")
    b = iron.randint(-50, 50, (n,), dtype=np.int32, device="npu")
    clipped = int(np.sum((a.numpy() + b.numpy()) < 0))
    print(f"elements={n}, negatives clipped to 0 by ReLU = {clipped}")

    ok = True

    out1 = iron.tensor((n,), dtype=np.int32, device="npu")
    bench1 = run_iters(
        relu_add_single, a, b, out1,
        num_elements=n, tile_size=tile, warmup=5, iters=20,
    )
    ok &= _verify_and_report("single worker (1 tile)", a, b, out1, bench1)

    out2 = iron.tensor((n,), dtype=np.int32, device="npu")
    bench2 = run_iters(
        relu_add_array, a, b, out2,
        num_elements=n, tile_size=tile, warmup=5, iters=20,
    )
    ok &= _verify_and_report(f"whole array ({cols} columns)", a, b, out2, bench2)

    if ok:
        gen = "XDNA2" if cols == 8 else "XDNA1"
        print(f"\nPASS!  custom fused kernel  out = relu(a + b)  on the {gen} NPU")
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
