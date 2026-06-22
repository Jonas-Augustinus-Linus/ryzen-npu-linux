#!/usr/bin/env python3
"""npu-trim — screen an imported graph and extract NPU-compilable kernels.

The XDNA1 `amd-aie` codegen accepts a *clean, hand-shaped* `linalg.matmul`
(bf16→f32) but rejects most **imported** graphs: f32 matmuls crash it, and the
casts/softmax/layernorm/dynamic-shapes that `iree-import-onnx` wraps around the
math hit "Unhandled pass pipeline in setRootConfig". So you can't just compile a
`.onnx` to the NPU — you have to pull the NPU-able pieces out. This tool does that:

  1. import `.onnx` → `linalg` (the hybrid path) if given an ONNX file,
  2. classify every op as ✅ NPU-supported / 🟡 experimental / ⛔ CPU-only,
  3. for each `linalg.matmul`, emit a CLEAN standalone bf16→f32 kernel
     (shapes padded up to AIE-friendly sizes) — and actually compile it to npu1,
  4. report which kernels lower to the NPU; the rest of the graph stays on CPU.

Usage:
    npu_trim.py <model.onnx | model.linalg.mlir> [--out-dir DIR] [--no-compile]

Env: IREE_AMD_AIE_ROOT (default ~/src/iree-amd-aie), KWS_VENV / IREE_VENV
     (default ~/src/iree-aie-venv).
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.expanduser(os.environ.get("IREE_AMD_AIE_ROOT", "~/src/iree-amd-aie"))
VENV = os.path.expanduser(os.environ.get("IREE_VENV", os.environ.get("KWS_VENV", "~/src/iree-aie-venv")))
IREE = os.path.join(ROOT, "iree-install", "bin")
PEANO = os.path.join(ROOT, "llvm-aie")
G, Y, RED, C, D, B, Rst = "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[90m", "\033[1m", "\033[0m"

# op -> (tier, why).  tier: npu | exp | cpu
OPS = {
    "linalg.matmul":            ("npu", "bf16→f32 / i32 matmul runs on npu1"),
    "linalg.matmul_transpose_b": ("npu", "matmul variant runs on npu1"),
    "linalg.batch_matmul":      ("npu", "batched matmul runs on npu1"),
    "linalg.conv_2d_nhwc_hwcf": ("npu", "plain 2D conv runs on npu1 (bf16/f32)"),
    "linalg.fill":              ("npu", "init — fused into the matmul/conv"),
    "linalg.softmax":           ("exp", "lowering exists but the e2e test is disabled (iree#21633)"),
    "linalg.depthwise_conv_2d_nhwc_hwc": ("exp", "fragile lowering, no guardrails"),
    "linalg.conv_2d_nhwc_hwcf_q": ("exp", "quantized conv is compile-only, not hw-verified"),
}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def import_onnx(onnx_path):
    """ONNX -> linalg MLIR via iree-import-onnx + iree-compile --compile-to=input."""
    vbin = os.path.join(VENV, "bin")
    torch = "/tmp/_npu_trim.torch.mlir"
    linalg = "/tmp/_npu_trim.linalg.mlir"
    r = run([os.path.join(vbin, "iree-import-onnx"), onnx_path, "--opset-version", "17", "-o", torch])
    if r.returncode != 0:
        sys.exit(f"{RED}iree-import-onnx failed:{Rst}\n{r.stderr[-800:]}")
    r = run([os.path.join(vbin, "iree-compile"), torch, "--iree-input-type=onnx",
             "--compile-to=input", "-o", linalg])
    if r.returncode != 0:
        sys.exit(f"{RED}iree-compile --compile-to=input failed:{Rst}\n{r.stderr[-800:]}")
    return linalg


def classify(mlir):
    """Return (rows, has_unsupported). rows = [(tier, op, why, count)]."""
    found = {}
    for op in re.findall(r"\b(linalg\.[a-z_0-9]+|arith\.(?:truncf|extf|sitofp|fptosi)|tosa\.[a-z_0-9]+|tensor\.(?:expand_shape|collapse_shape))\b", mlir):
        found[op] = found.get(op, 0) + 1
    # dynamic shapes?
    if re.search(r"tensor<[^>]*\?[^>]*>", mlir):
        found["<dynamic-shape>"] = found.get("<dynamic-shape>", 0) + 1
    rows = []
    skip = {"linalg.yield", "linalg.index"}  # structural, not real ops
    for op, n in sorted(found.items()):
        if op in skip:
            continue
        if op in OPS:
            tier, why = OPS[op]
        elif op.startswith("arith.") and op.split(".")[1] in ("truncf", "extf", "sitofp", "fptosi"):
            tier, why = "cpu", "dtype cast — wrapping a matmul in these is what crashes the amd-aie codegen"
        elif op == "<dynamic-shape>":
            tier, why = "cpu", "dynamic shapes aren't supported by the amd-aie backend"
        elif op == "linalg.generic":
            tier, why = "cpu", "elementwise/reduction generic — usually a cast/activation; keep on CPU"
        else:
            tier, why = "cpu", "not in the amd-aie op set"
        rows.append((tier, op, why, n))
    return rows


def extract_matmuls(mlir):
    """Find linalg.matmul ops -> list of (M, K, N, in_dtype, out_dtype)."""
    out = []
    pat = re.compile(
        r"linalg\.matmul\s+ins\([^:]*:\s*tensor<(\d+)x(\d+)x(\w+)>,\s*tensor<(\d+)x(\d+)x(\w+)>\)"
        r"\s*outs\([^:]*:\s*tensor<\d+x\d+x(\w+)>\)")
    for m in pat.finditer(mlir):
        M, K, t1, K2, N, t2, ot = m.groups()
        out.append((int(M), int(K), int(N), t1, ot))
    return out


def pad(n):
    """Round up to an AIE-friendly size: multiple of 64, minimum 256 (air needs big tiles)."""
    return max(256, -(-n // 64) * 64)


def emit_kernel(M, K, N):
    """A clean bf16→f32 matmul of the (padded) shape — the only form npu1 accepts."""
    Mp, Kp, Np = pad(M), pad(K), pad(N)
    mlir = f"""// extracted NPU kernel — bf16 matmul, original {M}x{K}x{N} padded to {Mp}x{Kp}x{Np}
func.func @matmul(%a: tensor<{Mp}x{Kp}xbf16>, %b: tensor<{Kp}x{Np}xbf16>) -> tensor<{Mp}x{Np}xf32> {{
  %z = arith.constant 0.0 : f32
  %i = tensor.empty() : tensor<{Mp}x{Np}xf32>
  %f = linalg.fill ins(%z : f32) outs(%i : tensor<{Mp}x{Np}xf32>) -> tensor<{Mp}x{Np}xf32>
  %r = linalg.matmul ins(%a, %b : tensor<{Mp}x{Kp}xbf16>, tensor<{Kp}x{Np}xbf16>)
                     outs(%f : tensor<{Mp}x{Np}xf32>) -> tensor<{Mp}x{Np}xf32>
  return %r : tensor<{Mp}x{Np}xf32>
}}
"""
    return mlir, (Mp, Kp, Np)


def compile_npu(mlir_path, vmfb_path):
    cmd = [os.path.join(IREE, "iree-compile"), mlir_path,
           "--iree-hal-target-backends=amd-aie", "--iree-amdaie-target-device=npu1_4col",
           "--iree-amdaie-lower-to-aie-pipeline=air", "--iree-amdaie-tile-pipeline=pack-peel",
           f"--iree-amd-aie-peano-install-dir={PEANO}",
           f"--iree-amd-aie-install-dir={os.path.join(ROOT, 'iree-install')}",
           "--iree-amdaie-device-hal=amdxdna", "-o", vmfb_path]
    r = run(cmd)
    return r.returncode == 0 and os.path.exists(vmfb_path), r


def main():
    ap = argparse.ArgumentParser(description="Screen an imported graph and extract NPU-compilable matmul kernels.")
    ap.add_argument("model", help="model.onnx or model.linalg.mlir")
    ap.add_argument("--out-dir", default="npu_kernels", help="where to write extracted kernels (default ./npu_kernels)")
    ap.add_argument("--no-compile", action="store_true", help="skip the test-compile step")
    args = ap.parse_args()

    if args.model.endswith(".onnx"):
        print(f"{D}# importing {args.model} (ONNX → linalg) …{Rst}")
        mlir_path = import_onnx(args.model)
    else:
        mlir_path = args.model
    mlir = open(mlir_path, encoding="utf-8").read()

    print(f"\n{B}== op coverage =={Rst}")
    tiers = {"npu": (G, "✅ NPU"), "exp": (Y, "🟡 exp"), "cpu": (RED, "⛔ CPU")}
    for tier, op, why, n in classify(mlir):
        col, lbl = tiers[tier]
        print(f"  {col}{lbl}{Rst}  {op:<34} x{n}  {D}{why}{Rst}")

    mms = extract_matmuls(mlir)
    print(f"\n{B}== extracted matmul kernels ({len(mms)}) =={Rst}")
    if not mms:
        print(f"  {D}no static-shape linalg.matmul found to extract.{Rst}")
        return
    os.makedirs(args.out_dir, exist_ok=True)
    ok = 0
    for idx, (M, K, N, it, ot) in enumerate(mms):
        kernel, (Mp, Kp, Np) = emit_kernel(M, K, N)
        kpath = os.path.join(args.out_dir, f"matmul_{idx}_{Mp}x{Kp}x{Np}.mlir")
        open(kpath, "w").write(kernel)
        padnote = "" if (Mp, Kp, Np) == (M, K, N) else f"{D} (padded from {M}x{K}x{N}){Rst}"
        line = f"  matmul[{idx}] {it}→{ot}  {Mp}x{Kp}x{Np}{padnote}  →  {kpath}"
        if args.no_compile:
            print(line)
            continue
        success, r = compile_npu(kpath, kpath.replace(".mlir", ".vmfb"))
        if success:
            ok += 1
            print(f"{line}\n     {G}✓ compiles to npu1{Rst}")
        else:
            err = next((l for l in (r.stderr or "").splitlines()
                        if "error" in l.lower() and "0x" not in l), "(crashed — likely unsupported shape/dtype)")
            print(f"{line}\n     {RED}✗ {err.strip()[:80]}{Rst}")

    if args.no_compile:
        print(f"\n{B}summary:{Rst} emitted {len(mms)} kernel(s) to {args.out_dir}/ "
              f"(re-run without --no-compile to test-compile them on npu1).")
    else:
        print(f"\n{B}summary:{Rst} {ok}/{len(mms)} matmul kernels lower to the NPU; "
              f"wire them via tools/npu-runner, keep the ⛔ ops on CPU.")


if __name__ == "__main__":
    main()
