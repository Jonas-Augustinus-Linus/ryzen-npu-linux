# npu-trim — pull the NPU-able pieces out of an imported graph

`iree-import-onnx` happily turns a `.onnx` into MLIR, but the XDNA1 `amd-aie`
codegen **rejects most imported graphs** — f32 matmuls crash it, and the
casts/softmax/layernorm/dynamic-shapes the importer wraps around the math hit
`Unhandled pass pipeline in setRootConfig`. It only accepts a *clean,
hand-shaped* `linalg.matmul` (bf16→f32). So you can't compile a model whole; you
extract the parts that fit. That's what this does:

1. import `.onnx` → `linalg` (the hybrid path) if you hand it an ONNX file,
2. **classify every op** — ✅ NPU-supported · 🟡 experimental · ⛔ CPU-only,
3. for each `linalg.matmul`, emit a **clean standalone bf16 kernel** (shapes
   padded up to AIE-friendly sizes) and **test-compile it to `npu1`**,
4. report which kernels lower to the NPU — wire those via
   [`../npu-runner`](../npu-runner), keep the ⛔ ops on the CPU.

## Use it

```bash
# needs a built iree-amd-aie (../../scripts/build.sh) and the pip importer
# (pip install "iree-base-compiler[onnx]" in the venv)
python3 npu_trim.py model.onnx              # full screen + extract + compile
python3 npu_trim.py model.linalg.mlir       # skip the ONNX import step
python3 npu_trim.py model.onnx --no-compile # just screen + emit kernels
```

Example output (a `MatMul → ReLU → MatMul` MLP):

```
== op coverage ==
  ✅ NPU  linalg.matmul       x2   bf16→f32 / i32 matmul runs on npu1
  ✅ NPU  linalg.fill         x1   init — fused into the matmul/conv
  ⛔ CPU  linalg.generic      x1   elementwise/reduction generic (the ReLU) — keep on CPU

== extracted matmul kernels (2) ==
  matmul[0] f32→f32  256x256x256  →  npu_kernels/matmul_0_256x256x256.mlir
     ✓ compiles to npu1
  matmul[1] f32→f32  256x256x256  →  npu_kernels/matmul_1_256x256x256.mlir
     ✓ compiles to npu1

summary: 2/2 matmul kernels lower to the NPU; wire them via tools/npu-runner, keep the ⛔ ops on CPU.
```

## What it does and doesn't do

- **Does:** screen ops, extract each matmul as a verified-compilable bf16 kernel,
  and prove it lowers. The padding (to a multiple of 64, ≥256, the size the `air`
  pipeline tiles) means the *kernel* is NPU-ready; your app pads activations to match.
- **Doesn't:** rebuild the model. It won't fuse the ReLU/softmax/layernorm back in
  (those have no `amd-aie` lowering) — that's the honest op-coverage frontier from
  [`../../docs/APPLICATIONS.md`](../../docs/APPLICATIONS.md). It extracts the dense
  cores; you orchestrate the graph (NPU matmuls + CPU glue), as in the
  [wake-word example](../../examples/wake-word).

> Conv extraction is on the roadmap; today it screens convs but only emits matmul
> kernels. `int8`/`i32` matmul extraction can be added the same way.
