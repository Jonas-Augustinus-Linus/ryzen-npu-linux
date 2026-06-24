#!/usr/bin/env python3
# relu_add.py — custom IRON kernel driver (XDNA1 / npu1).
#
# Runs  out = relu(a + b) = max(a + b, 0)  on the 7840U NPU and checks it against
# a numpy golden. Demonstrates the author-your-own-kernel path: an ExternalFunction
# (our relu_add.cc) wired through transform_binary and compiled+run by iron.jit.
#
# Run:  ./run.sh   (or: source ../../../scripts/mlir-aie-env.sh && python relu_add.py)
import os
import sys
import time
import numpy as np

import aie.iron as iron
from aie.iron.algorithms import transform_binary

HERE = os.path.dirname(os.path.abspath(__file__))


def relu_add(a, b, out):
    """Tile a and b and push each tile through the relu_add_i32 kernel."""
    n = a.numel()
    num_sub_vectors = 4
    tile_size = n // num_sub_vectors  # elements one core handles per tile

    tile_ty = np.ndarray[(tile_size,), np.dtype[np.int32]]

    # Handle to our external C++ kernel; arg_types = [a_tile, b_tile, out_tile, N]
    kernel = iron.ExternalFunction(
        "relu_add_i32",
        source_file=os.path.join(HERE, "relu_add.cc"),
        arg_types=[tile_ty, tile_ty, tile_ty, np.int32],
    )

    # iron.jit compiles + runs; transform_binary = two inputs -> one output
    iron.jit(transform_binary)(kernel, a, b, out, tile_size=tile_size)


def main():
    num_elements = 4096

    # NPU-accessible tensors; include negatives so ReLU actually clips
    a = iron.randint(-50, 50, (num_elements,), dtype=np.int32, device="npu")
    b = iron.randint(-50, 50, (num_elements,), dtype=np.int32, device="npu")
    out = iron.tensor((num_elements,), dtype=np.int32, device="npu")

    n_warmup, n_iters = 5, 20
    t_total, t_min = 0.0, float("inf")
    for k in range(n_warmup + n_iters):
        t0 = time.perf_counter()
        relu_add(a, b, out)
        dt = (time.perf_counter() - t0) * 1e6
        if k >= n_warmup:
            t_total += dt
            t_min = min(t_min, dt)

    got = out.numpy()
    expected = np.maximum(a.numpy() + b.numpy(), 0)
    mismatches = int(np.sum(got != expected))
    clipped = int(np.sum((a.numpy() + b.numpy()) < 0))

    print(f"\nelements={num_elements}, negatives clipped to 0 by ReLU = {clipped}")
    print(f"Avg NPU time: {t_total / n_iters:.1f}us  (min {t_min:.1f}us)")
    if mismatches == 0:
        print("PASS!  custom fused kernel  out = relu(a + b)  on the XDNA1 NPU")
        sys.exit(0)
    print(f"FAIL!  {mismatches} mismatches")
    print("got[:8] =", got[:8])
    print("exp[:8] =", expected[:8])
    sys.exit(1)


if __name__ == "__main__":
    main()
