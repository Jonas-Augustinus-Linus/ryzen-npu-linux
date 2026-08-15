# onnx-mlp — run an ONNX model on XDNA1 or XDNA2, end to end

![Original XDNA1 ONNX MLP terminal demo](../../docs/media/onnx-mlp.gif)

> The recording is the original XDNA1 run. The current source also detects and
> runs on Strix Point npu4, uses fresh target-labelled artifacts, and checks both
> dispatches plus the complete model against a bf16 CPU reference.

The capstone: an ONNX MLP actually **runs on the XDNA1 or Strix Point/XDNA2
NPU**, by chaining the three repo tools — even though the `amd-aie` backend
can't compile the whole graph (the ReLU/casts have no NPU lowering).

```
ONNX  ──[tools/npu-trim]──▶  device-matched bf16 matmul kernel (.npu1_4col.vmfb / .npu4.vmfb)
      ──[tools/npu-runner]─▶  run each dense layer on the NPU (load once, invoke many)
      ──[CPU]──────────────▶  the ReLU between layers
                          ──▶  verify against a CPU bf16-input/f32-accum reference
```

`run_onnx_npu.py` builds a `MatMul → ReLU → MatMul` MLP, lets **npu-trim** extract
and compile the matmuls, then runs the forward pass with **npu-runner** (the
`libnpu.so` ctypes bridge, `matmul_bf16`) for the dense layers and numpy for the
ReLU — and checks the result.

## Run

```bash
# ../../scripts/build.sh installs the versions.lock-pinned ONNX frontend.
# If iree-import-onnx is missing, rerun that build instead of replacing it with
# an unpinned pip upgrade. Build the persistent bridge once:
#   (cd ../../tools/npu-runner && ./build_lib.sh)
~/src/iree-aie-venv/bin/python run_onnx_npu.py
```

Output:

```
npu-trim: 2/2 matmul kernels lower to npu4
# target=npu4; loaded kernel once: matmul_0_256x256x256.npu4.vmfb
  [NPU] A @ W1   [CPU] ReLU   [NPU] @ W2   -> output (256, 256)
  dispatch 1 vs bf16 CPU: normalized max=1.175%
  dispatch 2 vs bf16 CPU: normalized max=2.952%
  end-to-end vs bf16 CPU: normalized max=3.613%
RESULT (npu4): ✓ ... within 5% normalized max error of the bf16 CPU reference
```

## What this shows (and the honest bits)

- **The real open-stack pattern:** you can't compile an arbitrary `.onnx` to
  the NPU whole — extract the dense cores (npu-trim), run them on the NPU
  (npu-runner), keep the activations/casts on the CPU, and orchestrate the
  dataflow yourself. This script is that orchestration for one known MLP; adapt
  the order/shapes to your model.
- **bf16 precision:** the CPU correctness oracle rounds each dispatch input to
  bf16 and accumulates in f32, matching the NPU ABI. The script checks each NPU
  dispatch and the complete MLP against that reference with a 5% normalized-max
  tolerance, then reports all-f32 model drift separately. On the verified npu4
  run the end-to-end bf16-reference error was **3.613%**; this is not bit-exact.
- **Load once, invoke many:** both layers reuse one loaded kernel via `npu-runner`
  — the same thing that makes always-on use fast (~3.7 ms/call vs ~41 ms for
  spawning `iree-run-module`).
- **Not magic:** the MLP's two matmuls happen to share a shape, so one kernel
  serves both. A real model needs a kernel per distinct matmul shape (npu-trim
  emits one each), and any op outside matmul/conv stays on the CPU — see
  [`../../docs/APPLICATIONS.md`](../../docs/APPLICATIONS.md).
- **No stale cross-generation artifacts:** every run uses a fresh private
  temporary directory, requires `npu-trim` to exit successfully, and accepts only
  two VMFBs carrying the same `.npu1_4col` or `.npu4` target suffix.

## Files

| File | Role |
|---|---|
| [`run_onnx_npu.py`](run_onnx_npu.py) | build MLP → npu-trim → npu-runner forward pass → verify |

Uses [`../../tools/npu-trim`](../../tools/npu-trim) and
[`../../tools/npu-runner`](../../tools/npu-runner).
