# npu-trim — pull the NPU-able pieces out of an imported graph

`iree-import-onnx` happily turns a `.onnx` into MLIR, but the XDNA1 `amd-aie`
codegen **rejects most imported graphs** — f32 matmuls crash it, and the
casts/softmax/layernorm/dynamic-shapes the importer wraps around the math hit
`Unhandled pass pipeline in setRootConfig`. It only accepts a *clean,
hand-shaped* `linalg.matmul` or `linalg.conv_2d_nhwc_hwcf` (bf16→f32). So you
can't compile a model whole; you extract the parts that fit. That's what this does:

1. import `.onnx` → `linalg` (the hybrid path) if you hand it an ONNX file,
2. **classify every op** — ✅ NPU-supported · 🟡 experimental · ⛔ CPU-only,
3. for each `linalg.matmul` **and** `linalg.conv_2d_nhwc_hwcf`, emit a **clean
   standalone bf16 kernel** (matmuls padded to AIE-friendly sizes; convs
   re-laid-out to NHWC and batch-bumped to ≥2) and **test-compile it to `npu1`**,
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

summary: 2/2 kernels lower to the NPU; wire them via tools/npu-runner, keep the ⛔ ops on CPU.
```

And on a CNN (`Conv → …`), the imported `conv_2d_nchw_fchw` is screened, re-laid-out
to the NPU-native NHWC form, batch-bumped, and test-compiled:

```
== extracted conv kernels (1) ==
  conv[0] f32  2x14x14x32 * 3x3 → 64ch (imported NCHW — transpose to NHWC at the edges; batch 1→2 (npu1 conv needs N≥2; run a 2-batch, keep output[0]))  →  npu_kernels/conv_0_2x14x14x32_to64.mlir
     ✓ compiles to npu1
```

## What it does and doesn't do

- **Does:** screen ops, extract each matmul as a verified-compilable bf16 kernel,
  and prove it lowers. The padding (to a multiple of 64, ≥256, the size the `air`
  pipeline tiles) means the *kernel* is NPU-ready; your app pads activations to match.
- **Does (conv):** the ONNX importer lowers `Conv` to `linalg.conv_2d_nchw_fchw`
  (NCHW), which `amd-aie` won't take; the tool re-emits it as the NPU-native
  `conv_2d_nhwc_hwcf` (NHWC) bf16 kernel, so your app transposes activations
  NCHW↔NHWC at the edges. It also bumps batch to ≥2 (the conv codegen can't set a
  config for `N=1` — run a 2-batch and keep `output[0]`).
- **Doesn't:** rebuild the model. It won't fuse the ReLU/softmax/layernorm back in
  (those have no `amd-aie` lowering) — that's the honest op-coverage frontier from
  [`../../docs/APPLICATIONS.md`](../../docs/APPLICATIONS.md). It extracts the dense
  cores; you orchestrate the graph (NPU matmuls/convs + CPU glue), as in the
  [wake-word example](../../examples/wake-word).

> **Conv codegen is narrow today.** `amd-aie`'s `conv-decompose` pipeline is tuned
> around its CI shape (≈ `H=14`/`OH=12`, `3×3`, channels in `{8,16,32,64}`, `N≥2`),
> so many real-model convs (1×1, large spatial, `IC=3` RGB stems) still hit
> `Unhandled pass pipeline` — that's exactly why the tool **test-compiles each
> kernel** and reports ✓/✗ instead of promising. Extract the convs that pass, keep
> the rest on CPU. `int8`/`i32` matmul extraction can be added the same way.
