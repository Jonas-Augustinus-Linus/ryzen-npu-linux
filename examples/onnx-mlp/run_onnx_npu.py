#!/usr/bin/env python3
"""End-to-end: an ONNX MLP runs on the XDNA1 NPU — dense layers on the NPU,
ReLU on the CPU — by chaining the three repo tools:

    ONNX  ──tools/npu-trim──▶  bf16 matmul kernel (.vmfb that compiles to npu1)
          ──tools/npu-runner──▶ run each layer on the NPU (load once, invoke many)
          ──CPU──▶ the ReLU between layers

The amd-aie backend can't compile the whole graph (the ReLU/casts have no NPU
lowering), so this is the honest pattern: extract the matmuls, run them on the
NPU, keep the glue on the CPU — and check the result against a CPU reference.

Run:  python3 run_onnx_npu.py        (needs a built iree-amd-aie + the pip importer)
"""
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "npu-runner"))
from npu import NPU  # noqa: E402

WORK = "/tmp/onnx_mlp_e2e"
VENV_PY = os.path.expanduser(os.environ.get("IREE_VENV", "~/src/iree-aie-venv") + "/bin/python")
DIM = 256
G, Y, D, B, R = "\033[32m", "\033[33m", "\033[90m", "\033[1m", "\033[0m"


def build_model(W1, W2, path):
    """A 2-layer MLP:  C = relu(A @ W1) @ W2  (f32 ONNX)."""
    import onnx
    from onnx import helper, TensorProto as T
    A = helper.make_tensor_value_info("A", T.FLOAT, [DIM, DIM])
    C = helper.make_tensor_value_info("C", T.FLOAT, [DIM, DIM])
    w1 = helper.make_tensor("W1", T.FLOAT, [DIM, DIM], W1.tobytes(), raw=True)
    w2 = helper.make_tensor("W2", T.FLOAT, [DIM, DIM], W2.tobytes(), raw=True)
    nodes = [helper.make_node("MatMul", ["A", "W1"], ["h"]),
             helper.make_node("Relu", ["h"], ["hr"]),
             helper.make_node("MatMul", ["hr", "W2"], ["C"])]
    g = helper.make_graph(nodes, "mlp", [A], [C], initializer=[w1, w2])
    onnx.save(helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)]), path)


def npu_trim(onnx_path):
    """tools/npu-trim: import + extract + compile the matmul kernels to npu1."""
    out = os.path.join(WORK, "kernels")
    r = subprocess.run(
        [VENV_PY, os.path.join(REPO, "tools", "npu-trim", "npu_trim.py"), onnx_path, "--out-dir", out],
        capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    vmfbs = sorted(f for f in os.listdir(out) if f.endswith(".vmfb")) if os.path.isdir(out) else []
    if not vmfbs:
        sys.exit(f"npu-trim produced no kernel:\n{r.stderr[-600:]}")
    return os.path.join(out, vmfbs[0])  # both layers share the 256x256x256 shape


def main():
    os.makedirs(WORK, exist_ok=True)
    rng = np.random.default_rng(0)
    W1 = (rng.standard_normal((DIM, DIM)) * 0.1).astype(np.float32)
    W2 = (rng.standard_normal((DIM, DIM)) * 0.1).astype(np.float32)
    x = (rng.standard_normal((DIM, DIM)) * 0.5).astype(np.float32)

    print(f"{D}# building a {DIM}-wide MLP (MatMul -> ReLU -> MatMul) and extracting NPU kernels{R}")
    model = os.path.join(WORK, "mlp.onnx")
    build_model(W1, W2, model)
    kernel = npu_trim(model)
    print(f"{D}# loaded kernel once: {os.path.basename(kernel)}{R}\n")

    npu = NPU(kernel)                      # load the kernel ONCE (npu-runner)
    h = npu.matmul_bf16(x, W1)             # layer 1  — on the NPU
    h = np.maximum(h, 0.0)                 # ReLU     — on the CPU
    y = npu.matmul_bf16(h, W2)             # layer 2  — on the NPU
    npu.close()
    print(f"  {G}[NPU]{R} A @ W1   {G}[CPU]{R} ReLU   {G}[NPU]{R} @ W2   -> output {y.shape}")

    ref = np.maximum(x @ W1, 0.0) @ W2     # the same MLP, all on the CPU in f32
    rel = np.abs(y - ref).max() / (np.abs(ref).max() + 1e-9)
    print(f"\n  output[0,0] = {y[0,0]:.4f}   reference = {ref[0,0]:.4f}")
    print(f"  max relative error vs CPU f32 reference = {rel:.2%}  {D}(bf16 inputs ~= 2-3 digits){R}")
    ok = rel < 0.05
    print(f"\n{B}RESULT: {G if ok else Y}{'✓ the ONNX MLP runs on the NPU and matches the CPU reference' if ok else '⚠ larger error — check shapes/scale'}{R}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
