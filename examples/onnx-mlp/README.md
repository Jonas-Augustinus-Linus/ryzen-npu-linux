# onnx-mlp — run an ONNX model on the NPU, end to end

The capstone: an ONNX MLP actually **runs on the XDNA1 NPU**, by chaining the
three repo tools — even though the `amd-aie` backend can't compile the whole
graph (the ReLU/casts have no NPU lowering).

```
ONNX  ──[tools/npu-trim]──▶  bf16 matmul kernel (.vmfb that compiles to npu1)
      ──[tools/npu-runner]─▶  run each dense layer on the NPU (load once, invoke many)
      ──[CPU]──────────────▶  the ReLU between layers
                          ──▶  verify against a CPU f32 reference
```

`run_onnx_npu.py` builds a `MatMul → ReLU → MatMul` MLP, lets **npu-trim** extract
and compile the matmuls, then runs the forward pass with **npu-runner** (the
`libnpu.so` ctypes bridge, `matmul_bf16`) for the dense layers and numpy for the
ReLU — and checks the result.

## Run

```bash
# needs a built iree-amd-aie (../../scripts/build.sh), the pip ONNX importer, and
# the bridge built once:  (cd ../../tools/npu-runner && ./build_lib.sh)
~/src/iree-aie-venv/bin/python run_onnx_npu.py
```

Output:

```
npu-trim: 2/2 matmul kernels lower to the NPU
# loaded kernel once: matmul_0_256x256x256.vmfb
  [NPU] A @ W1   [CPU] ReLU   [NPU] @ W2   -> output (256, 256)
  output[0,0] = 0.6946   reference = 0.6947
  max relative error vs CPU f32 reference = 0.31%   (bf16 inputs ~= 2-3 digits)
RESULT: ✓ the ONNX MLP runs on the NPU and matches the CPU reference
```

## What this shows (and the honest bits)

- **The real pattern for XDNA1+Linux:** you can't compile an arbitrary `.onnx` to
  the NPU whole — extract the dense cores (npu-trim), run them on the NPU
  (npu-runner), keep the activations/casts on the CPU, and orchestrate the
  dataflow yourself. This script is that orchestration for one known MLP; adapt
  the order/shapes to your model.
- **bf16 precision:** the NPU path runs the matmuls in bf16 (the AIE-native type),
  so the result matches the f32 reference to ~2-3 digits (here **0.31%**), not
  bit-exactly. Fine for inference.
- **Load once, invoke many:** both layers reuse one loaded kernel via `npu-runner`
  — the same thing that makes always-on use fast (~3.7 ms/call vs ~41 ms for
  spawning `iree-run-module`).
- **Not magic:** the MLP's two matmuls happen to share a shape, so one kernel
  serves both. A real model needs a kernel per distinct matmul shape (npu-trim
  emits one each), and any op outside matmul/conv stays on the CPU — see
  [`../../docs/APPLICATIONS.md`](../../docs/APPLICATIONS.md).

## Files

| File | Role |
|---|---|
| [`run_onnx_npu.py`](run_onnx_npu.py) | build MLP → npu-trim → npu-runner forward pass → verify |

Uses [`../../tools/npu-trim`](../../tools/npu-trim) and
[`../../tools/npu-runner`](../../tools/npu-runner).
