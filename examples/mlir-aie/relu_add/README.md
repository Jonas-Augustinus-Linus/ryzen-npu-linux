# Custom IRON kernel — fused `relu(a + b)` on the XDNA1 NPU

A hand-written AIE kernel that is **not** one of the stock mlir-aie
`programming_examples`: a single fused element-wise op

```
out[i] = max(a[i] + b[i], 0)      # residual add + ReLU, in one kernel
```

It shows the whole author-your-own-kernel path on a first-gen Ryzen AI (Phoenix /
7840U) NPU:

- [`relu_add.cc`](relu_add.cc) — the compute kernel (plain C++, no AIE-API
  needed for the scalar form), compiled for `aie2` by Peano.
- [`relu_add.py`](relu_add.py) — an `iron.ExternalFunction` wired through
  `transform_binary` (two inputs → one output) and compiled + run by `iron.jit`.
  Checks the NPU output against a numpy golden.

## Run

```bash
# one-time: set the mlir-aie track up (see ../../../docs/MLIR-AIE.md)
../../../scripts/setup-mlir-aie.sh

# build for npu1 + run ON THE NPU
./run.sh
```

Expected tail:

```
elements=4096, negatives clipped to 0 by ReLU = ~2050
Avg NPU time: ~380us  (min ~350us)
PASS!  custom fused kernel  out = relu(a + b)  on the XDNA1 NPU
```

## Notes

- `int32`, 4096 elements, tiled into 4 sub-vectors processed on one AIE core.
- The kernel is intentionally **scalar** for clarity; vectorizing with
  `aie::add` / `aie::max` (see `aie_kernels/aie2/*.cc` upstream) is the natural
  next step.
- This is the IRON / `mlir-aie` path. For whole-graph compilation (PyTorch/ONNX
  → NPU) use the `iree-amd-aie` path in the repo root instead.
