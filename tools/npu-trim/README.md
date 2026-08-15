# npu-trim — pull the NPU-able pieces out of an imported graph

![Original XDNA1 npu-trim terminal demo](../../docs/media/npu-trim.gif)

> The recording is the original XDNA1 screening flow. The current tool also
> detects Strix Point npu4, emits target-labelled VMFBs, and fails closed when a
> kernel does not compile; npu4 matmul is verified while conv remains limited.

`iree-import-onnx` happily turns a `.onnx` into MLIR, but the `amd-aie`
codegen **rejects most imported graphs** — f32 matmuls crash it, and the
casts/softmax/layernorm/dynamic-shapes the importer wraps around the math hit
`Unhandled pass pipeline in setRootConfig`. It only accepts a *clean,
hand-shaped* `linalg.matmul` or `linalg.conv_2d_nhwc_hwcf` (bf16→f32). So you
can't compile a model whole; you extract the parts that fit. That's what this does:

1. import `.onnx` → `linalg` (the hybrid path) if you hand it an ONNX file,
2. **classify every op** — ✅ NPU-supported · 🟡 experimental · ⛔ CPU-only,
3. for each `linalg.matmul` **and** `linalg.conv_2d_nhwc_hwcf`, emit a **clean
   standalone bf16 kernel** (matmuls padded to AIE-friendly sizes; convs
   re-laid-out to NHWC and batch-bumped to ≥2) and **test-compile it for the
   detected XDNA1 `npu1_4col` or Strix Point/XDNA2 `npu4` target**,
4. report which kernels lower to the NPU — wire those via
   [`../npu-runner`](../npu-runner), keep the ⛔ ops on the CPU.

## Use it

```bash
# ../../scripts/build.sh installs the versions.lock-pinned ONNX importer.
# If iree-import-onnx is missing, rerun that build; do not replace the verified
# frontend with an unpinned pip upgrade.

~/src/iree-aie-venv/bin/python npu_trim.py model.onnx              # import + extract + device-matched compile
~/src/iree-aie-venv/bin/python npu_trim.py model.linalg.mlir       # skip the ONNX import step
~/src/iree-aie-venv/bin/python npu_trim.py model.onnx --no-compile # screen + emit; no NPU required
```

Example output (a `MatMul → ReLU → MatMul` MLP):

```
== op coverage ==
  ✅ NPU  linalg.matmul       x2   bf16→f32 / i32 matmul has an amd-aie lowering
  ✅ NPU  linalg.fill         x1   init — fused into the matmul/conv
  ⛔ CPU  linalg.generic      x1   elementwise/reduction generic (the ReLU) — keep on CPU

== extracted matmul kernels (2) ==
  matmul[0] f32→f32  256x256x256  →  npu_kernels/matmul_0_256x256x256.mlir
     ✓ compiles to npu4 → npu_kernels/matmul_0_256x256x256.npu4.vmfb
  matmul[1] f32→f32  256x256x256  →  npu_kernels/matmul_1_256x256x256.mlir
     ✓ compiles to npu4 → npu_kernels/matmul_1_256x256x256.npu4.vmfb

summary: 2/2 kernels lower to npu4; wire them via tools/npu-runner, keep the ⛔ ops on CPU.
```

On the XDNA1 reference target, a CNN (`Conv → …`) is screened, re-laid-out from
`conv_2d_nchw_fchw` to NHWC, batch-bumped, and test-compiled:

```
== extracted conv kernels (1) ==
  conv[0] f32  2x14x14x32 * 3x3 → 64ch (imported NCHW — transpose to NHWC at the edges; batch 1→2 (npu1 conv needs N≥2; run a 2-batch, keep output[0]))  →  npu_kernels/conv_0_2x14x14x32_to64.mlir
     ✓ compiles to npu1_4col → npu_kernels/conv_0_2x14x14x32_to64.npu1_4col.vmfb
```

## What it does and doesn't do

- **Does:** screen ops, extract each matmul as a verified-compilable bf16 kernel,
  and prove it lowers. Padding to a multiple of 64 with a minimum of 256 matches
  the AIE-friendly minimum used by the verified target paths; your app pads
  activations to match.
- **Detects the generation once:** the shared `scripts/detect-npu.sh` selects only
  the two hardware mappings verified by this repository. XDNA1 keeps the `air` /
  `pack-peel` path. Strix Point uses the same `objectFifo`, four-level tiling,
  Peano ukernel, control-packet flags as `scripts/run-matmul.sh`. VMFB names include
  `.npu1_4col` or `.npu4`, so an artifact from one generation cannot masquerade as
  the other.
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

> On the verified Strix Point setup, the 2×14×14×32 → 64-channel conv probe above
> is extracted but currently fails the `npu4` compile with an unsupported dynamic
> `memref.subview`. The command reports that failure and exits nonzero; the npu4
> port verified here is the bf16 matmul path, not a conv correctness claim.

ONNX import uses a private temporary directory, compilation replaces the
target-specific VMFB atomically, and any missing kernel or compile failure exits
nonzero. This makes the command safe to use from another script without accepting
a stale `/tmp` artifact as a successful build.
