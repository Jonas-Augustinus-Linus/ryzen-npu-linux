# Custom IRON kernel — fused `relu(a + b)` on the Ryzen AI NPU

A hand-written AIE kernel that is **not** one of the stock mlir-aie
`programming_examples`: a single fused element-wise op

```
out[i] = max(a[i] + b[i], 0)      # residual add + ReLU, in one kernel
```

The operation has been verified on **both NPU generations**, but with the
release-specific designs available at the time: XDNA1 (Phoenix / 7840U,
`npu1`) used mlir-aie 1.3.x and the earlier single-Worker design; XDNA2 (Strix
Point / HX 370, `npu2`) uses mlir-aie 1.4.1 and the current annotated
single-Worker plus 8-column designs. The current 1.4.x designs have not been
re-verified on XDNA1. `iron.jit` detects the device, and Peano compiles the
same C++ kernel for `aie2` or `aie2p` accordingly:

- [`relu_add.cc`](relu_add.cc) — the compute kernel (plain C++, no AIE-API
  needed for the scalar form). No source change between generations.
- [`relu_add.py`](relu_add.py) — an `iron.ExternalFunction` wired through the
  IRON 1.4.x annotated-`@iron.jit` API, in **two designs**, each checked
  against a numpy golden:
  - `relu_add_single` — one Worker on one compute tile
    (`transform_binary`), the original design;
  - `relu_add_array` — one Worker **per column**
    (`transform_parallel_binary`): 4 columns on npu1, 8 on npu2,
    auto-scaled from the detected device.

## Run

```bash
# one-time: set the mlir-aie track up (see ../../../docs/MLIR-AIE.md)
../../../scripts/setup-mlir-aie.sh

# build for the detected NPU generation + run ON THE NPU
./run.sh
```

Expected tail on XDNA2 (Strix Point, 1M int32 elements, tile 1024):

```
device: NPU2  columns: 8  (XDNA2/Strix)
--- single worker (1 tile) ---
NPU time     (avg/min/max us): ~8950 / ...
Effective DDR throughput (2 in + 1 out): ~1.4 GB/s
PASS (single worker (1 tile))
--- whole array (8 columns) ---
NPU time     (avg/min/max us): ~1120 / ...
Effective DDR throughput (2 in + 1 out): ~11.2 GB/s
PASS (whole array (8 columns))
PASS!  custom fused kernel  out = relu(a + b)  on the XDNA2 NPU
```

Measured on the Strix Point machine (Ryzen AI 9 HX PRO 370, Ubuntu 26.04,
kernel 7.0, mlir-aie 1.4.1): the 8-column design is **8.0× faster** than the
single Worker — column scaling is linear for this bandwidth-bound kernel.

## Notes

- `int32`, default 2²⁰ elements, `tile_size` 1024. Three double-buffered tile
  FIFOs must fit the 64 KB core-local memory: `tile_size` 4096 (16 KB × 6
  buffers = 96 KB) is already too big and fails placement — see
  [GOTCHAS](../../../docs/GOTCHAS.md).
- The array design keeps `num_channels=1`: a *binary* kernel already uses both
  shim MM2S DMA channels per column (one per input), so the `num_channels=2`
  bandwidth trick is unary-only.
- The kernel is intentionally **scalar** for clarity; vectorizing with
  `aie::add` / `aie::max` (see `aie_kernels/aie2*/**.cc` upstream) is the
  natural next step.
- This is the IRON / `mlir-aie` path. For whole-graph compilation (PyTorch/ONNX
  → NPU) use the `iree-amd-aie` path in the repo root instead.
