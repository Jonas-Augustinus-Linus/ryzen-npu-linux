#!/usr/bin/env python3
"""End-to-end: an ONNX MLP runs on XDNA1 or Strix Point/XDNA2.

Dense layers execute on the NPU,
ReLU on the CPU — by chaining the three repo tools:

    ONNX  ──tools/npu-trim──▶  device-matched bf16 matmul kernel (.vmfb)
          ──tools/npu-runner──▶ run each layer on the NPU (load once, invoke many)
          ──CPU──▶ the ReLU between layers

The amd-aie backend can't compile the whole graph (the ReLU/casts have no NPU
lowering), so this is the honest pattern: extract the matmuls, run them on the
NPU, keep the glue on the CPU — and check the result against a CPU reference.

Run:  python3 run_onnx_npu.py        (needs a built iree-amd-aie + the pip importer)
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import ml_dtypes
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "npu-runner"))
from npu import NPU  # noqa: E402

VENV = os.path.expanduser(os.environ.get("IREE_VENV", "~/src/iree-aie-venv"))
VENV_PY = os.path.join(VENV, "bin", "python")
DIM = 256
CPU_REFERENCE_TOLERANCE = 0.05
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


def npu_trim(onnx_path, work):
    """Import, extract, and compile for the locally detected verified target."""
    if not os.path.isfile(VENV_PY) or not os.access(VENV_PY, os.X_OK):
        sys.exit(f"IREE virtualenv Python is missing or not executable: {VENV_PY}")
    out = os.path.join(work, "kernels")
    cmd = [
        VENV_PY,
        os.path.join(REPO, "tools", "npu-trim", "npu_trim.py"),
        onnx_path,
        "--out-dir", out,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        sys.stdout.write(exc.stdout or "")
        sys.exit(f"npu-trim failed (exit {exc.returncode}):\n{(exc.stderr or '')[-1200:]}")
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    vmfbs = sorted(Path(out).glob("*.vmfb")) if os.path.isdir(out) else []
    if not vmfbs:
        sys.exit("npu-trim succeeded but produced no VMFB")
    target_matches = [
        re.search(r"\.(npu1_4col|npu4)\.vmfb$", path.name)
        for path in vmfbs
    ]
    targets = {match.group(1) for match in target_matches if match}
    if (len(vmfbs) != 2 or any(match is None for match in target_matches)
            or len(targets) != 1):
        names = ", ".join(path.name for path in vmfbs)
        sys.exit(f"expected two kernels for one detected target; found: {names}")
    return str(vmfbs[0]), targets.pop()  # both layers share the 256³ shape


def bf16_f32(array):
    """Round like an NPU bf16 input, then expose the values to NumPy as f32."""
    return np.asarray(array, dtype=ml_dtypes.bfloat16).astype(np.float32)


def normalized_max_error(actual, reference):
    max_abs = float(np.max(np.abs(actual - reference)))
    scale = max(float(np.max(np.abs(reference))), 1e-9)
    return max_abs, max_abs / scale


def main():
    rng = np.random.default_rng(0)
    W1 = (rng.standard_normal((DIM, DIM)) * 0.1).astype(np.float32)
    W2 = (rng.standard_normal((DIM, DIM)) * 0.1).astype(np.float32)
    x = (rng.standard_normal((DIM, DIM)) * 0.5).astype(np.float32)

    print(f"{D}# building a {DIM}-wide MLP (MatMul -> ReLU -> MatMul) and extracting NPU kernels{R}")
    with tempfile.TemporaryDirectory(prefix="ryzen-npu-onnx-mlp.") as work:
        model = os.path.join(work, "mlp.onnx")
        build_model(W1, W2, model)
        kernel, target = npu_trim(model, work)
        print(f"{D}# target={target}; loaded kernel once: {os.path.basename(kernel)}{R}\n")

        with NPU(kernel) as npu:             # load the kernel ONCE (npu-runner)
            h_raw = npu.matmul_bf16(x, W1)  # layer 1  — on the NPU
            h = np.maximum(h_raw, 0.0)       # ReLU     — on the CPU
            y = npu.matmul_bf16(h, W2)       # layer 2  — on the NPU
    print(f"  {G}[NPU]{R} A @ W1   {G}[CPU]{R} ReLU   {G}[NPU]{R} @ W2   -> output {y.shape}")

    # CPU reference that mirrors both bf16 input boundaries and f32 accumulation.
    h_ref = bf16_f32(x) @ bf16_f32(W1)
    y_ref = bf16_f32(np.maximum(h_ref, 0.0)) @ bf16_f32(W2)
    # Isolate dispatch 2 from layer-1 propagation by feeding its actual input to
    # the CPU oracle, rounded at the same bf16 boundary as the NPU wrapper.
    y_dispatch_ref = bf16_f32(h) @ bf16_f32(W2)
    h_abs, h_rel = normalized_max_error(h_raw, h_ref)
    y_dispatch_abs, y_dispatch_rel = normalized_max_error(y, y_dispatch_ref)
    y_abs, y_rel = normalized_max_error(y, y_ref)

    # Also report model drift against an all-f32 CPU execution; this is precision
    # context, not the hardware-correctness oracle.
    f32_ref = np.maximum(x @ W1, 0.0) @ W2
    _, f32_rel = normalized_max_error(y, f32_ref)
    print(f"\n  output[0,0] = {y[0,0]:.4f}   bf16 CPU reference = {y_ref[0,0]:.4f}")
    print(f"  dispatch 1 vs bf16 CPU: max abs={h_abs:.6g}, normalized max={h_rel:.3%}")
    print(f"  dispatch 2 vs bf16 CPU: max abs={y_dispatch_abs:.6g}, "
          f"normalized max={y_dispatch_rel:.3%}")
    print(f"  end-to-end vs bf16 CPU: max abs={y_abs:.6g}, normalized max={y_rel:.3%}")
    print(f"  end-to-end drift vs all-f32 CPU = {f32_rel:.3%}  "
          f"{D}(expected bf16 precision context){R}")
    ok = (np.isfinite(y).all()
          and h_rel < CPU_REFERENCE_TOLERANCE
          and y_dispatch_rel < CPU_REFERENCE_TOLERANCE
          and y_rel < CPU_REFERENCE_TOLERANCE)
    message = ("✓ device-matched ONNX MLP runs persistently on the NPU and is "
               "within 5% normalized max error of the bf16 CPU reference" if ok else
               "⚠ NPU output exceeded the 5% bf16 CPU-reference tolerance")
    print(f"\n{B}RESULT ({target}): {G if ok else Y}{message}{R}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
