#!/usr/bin/env python3
"""npu-trim — screen an imported graph and extract NPU-compilable kernels.

The `amd-aie` codegen accepts a *clean, hand-shaped* `linalg.matmul`
(bf16→f32) but rejects most **imported** graphs: f32 matmuls crash it, and the
casts/softmax/layernorm/dynamic-shapes that `iree-import-onnx` wraps around the
math hit "Unhandled pass pipeline in setRootConfig". So you can't just compile a
`.onnx` to the NPU — you have to pull the NPU-able pieces out. This tool does that:

  1. import `.onnx` → `linalg` (the hybrid path) if given an ONNX file,
  2. classify every op as ✅ NPU-supported / 🟡 experimental / ⛔ CPU-only,
  3. for each `linalg.matmul`, emit a CLEAN standalone bf16→f32 kernel
     (shapes padded up to AIE-friendly sizes) — and compile it for the detected
     XDNA1 (`npu1_4col`) or Strix Point/XDNA2 (`npu4`) target,
  4. report which kernels lower to the NPU; the rest of the graph stays on CPU.

Usage:
    npu_trim.py <model.onnx | model.linalg.mlir> [--out-dir DIR] [--no-compile]

Env: IREE_AMD_AIE_ROOT (default ~/src/iree-amd-aie), KWS_VENV / IREE_VENV
     (default ~/src/iree-aie-venv), DETECT_NPU (shared detector override),
     TARGET_DEVICE (explicit detector override for known-compatible hardware).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = os.path.expanduser(os.environ.get("IREE_AMD_AIE_ROOT", "~/src/iree-amd-aie"))
VENV = os.path.expanduser(os.environ.get("IREE_VENV", os.environ.get("KWS_VENV", "~/src/iree-aie-venv")))
IREE = os.path.join(ROOT, "iree-install", "bin")
PEANO = os.path.join(ROOT, "llvm-aie")
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DETECT_NPU = os.environ.get("DETECT_NPU", os.path.join(REPO, "scripts", "detect-npu.sh"))
G, Y, RED, C, D, B, Rst = "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[90m", "\033[1m", "\033[0m"

# op -> (tier, why).  tier: npu | exp | cpu
OPS = {
    "linalg.matmul":            ("npu", "bf16→f32 / i32 matmul has an amd-aie lowering"),
    "linalg.matmul_transpose_b": ("npu", "matmul variant has an amd-aie lowering"),
    "linalg.batch_matmul":      ("npu", "batched matmul has an amd-aie lowering"),
    "linalg.conv_2d_nhwc_hwcf": ("npu", "plain 2D conv has an amd-aie lowering (bf16/f32)"),
    "linalg.fill":              ("npu", "init — fused into the matmul/conv"),
    "linalg.softmax":           ("exp", "lowering exists but the e2e test is disabled (iree#21633)"),
    "linalg.depthwise_conv_2d_nhwc_hwc": ("exp", "fragile lowering, no guardrails"),
    "linalg.conv_2d_nhwc_hwcf_q": ("exp", "quantized conv is compile-only, not hw-verified"),
}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def import_onnx(onnx_path):
    """Return imported linalg MLIR without sharing stale files through /tmp."""
    vbin = os.path.join(VENV, "bin")
    importer = os.path.join(vbin, "iree-import-onnx")
    frontend = os.path.join(vbin, "iree-compile")
    for tool in (importer, frontend):
        if not os.path.isfile(tool) or not os.access(tool, os.X_OK):
            sys.exit(f"{RED}required ONNX import tool is missing: {tool}{Rst}")

    with tempfile.TemporaryDirectory(prefix="ryzen-npu-onnx-import.") as work:
        torch = os.path.join(work, "model.torch.mlir")
        linalg = os.path.join(work, "model.linalg.mlir")
        r = run([importer, onnx_path, "--opset-version", "17", "-o", torch])
        if r.returncode != 0:
            sys.exit(f"{RED}iree-import-onnx failed:{Rst}\n{r.stderr[-800:]}")
        r = run([frontend, torch, "--iree-input-type=onnx",
                 "--compile-to=input", "-o", linalg])
        if r.returncode != 0:
            sys.exit(f"{RED}iree-compile --compile-to=input failed:{Rst}\n{r.stderr[-800:]}")
        try:
            return Path(linalg).read_text(encoding="utf-8")
        except OSError as exc:
            sys.exit(f"{RED}could not read imported MLIR: {exc}{Rst}")


def detect_device():
    """Resolve the verified target and geometry through the repo-wide detector."""
    if not os.path.isfile(DETECT_NPU) or not os.access(DETECT_NPU, os.X_OK):
        sys.exit(f"{RED}NPU detector is missing or not executable: {DETECT_NPU}{Rst}")
    env = os.environ.copy()
    env["IREE_AMD_AIE_ROOT"] = ROOT
    r = run([DETECT_NPU, "--tsv"], env=env)
    if r.returncode != 0:
        detail = (r.stderr or r.stdout).strip()
        sys.exit(f"{RED}NPU detection failed:{Rst}\n{detail}")
    fields = r.stdout.rstrip("\n").split("\t")
    if len(fields) != 5:
        sys.exit(f"{RED}invalid detector output: {r.stdout!r}{Rst}")
    target, rows, cols, generation, vbnv = fields
    if target not in ("npu1_4col", "npu4"):
        sys.exit(f"{RED}unsupported detected target: {target}{Rst}")
    return {
        "target": target,
        "rows": int(rows),
        "cols": int(cols),
        "generation": generation,
        "vbnv": vbnv,
    }


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
    """A clean bf16→f32 matmul of the padded, AIE-friendly shape."""
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


def extract_convs(mlir):
    """Find 2D conv ops -> list of dicts {N,H,W,IC,OC,KH,KW,dtype,layout}."""
    out = []
    # NCHW/FCHW (what ONNX imports to): ins(input[N,IC,H,W], filter[OC,IC,KH,KW])
    for m in re.finditer(r"linalg\.conv_2d_nchw_fchw\b.*?ins\([^:]*:\s*"
                         r"tensor<(\d+)x(\d+)x(\d+)x(\d+)x(\w+)>,\s*tensor<(\d+)x(\d+)x(\d+)x(\d+)x\w+>\)", mlir):
        N, IC, H, W, t, OC, _IC, KH, KW = m.groups()
        out.append(dict(N=int(N), H=int(H), W=int(W), IC=int(IC), OC=int(OC),
                        KH=int(KH), KW=int(KW), dtype=t, layout="NCHW"))
    # NHWC/HWCF (the NPU-native form): ins(input[N,H,W,IC], filter[KH,KW,IC,OC])
    for m in re.finditer(r"linalg\.conv_2d_nhwc_hwcf\b.*?ins\([^:]*:\s*"
                         r"tensor<(\d+)x(\d+)x(\d+)x(\d+)x(\w+)>,\s*tensor<(\d+)x(\d+)x\d+x(\d+)x\w+>\)", mlir):
        N, H, W, IC, t, KH, KW, OC = m.groups()
        out.append(dict(N=int(N), H=int(H), W=int(W), IC=int(IC), OC=int(OC),
                        KH=int(KH), KW=int(KW), dtype=t, layout="NHWC"))
    return out


def emit_conv_kernel(c):
    """A clean conv_2d_nhwc_hwcf bf16→f32 kernel for amd-aie.
    Assumes stride 1, no padding (OH=H-KH+1). Batch is bumped to >=2 because the
    amd-aie conv codegen can't set a config for N=1. Returns (mlir, N)."""
    H, W, IC, OC, KH, KW = (c[k] for k in ("H", "W", "IC", "OC", "KH", "KW"))
    N = max(2, c["N"])
    OH, OW = H - KH + 1, W - KW + 1
    mlir = f"""// extracted NPU conv kernel — conv_2d_nhwc_hwcf bf16→f32 (from a {c['layout']} conv)
func.func @conv(%in: tensor<{N}x{H}x{W}x{IC}xbf16>, %fil: tensor<{KH}x{KW}x{IC}x{OC}xbf16>) -> tensor<{N}x{OH}x{OW}x{OC}xf32> {{
  %z = arith.constant 0.0 : f32
  %i = tensor.empty() : tensor<{N}x{OH}x{OW}x{OC}xf32>
  %f = linalg.fill ins(%z : f32) outs(%i : tensor<{N}x{OH}x{OW}x{OC}xf32>) -> tensor<{N}x{OH}x{OW}x{OC}xf32>
  %r = linalg.conv_2d_nhwc_hwcf {{dilations = dense<1> : tensor<2xi64>, strides = dense<1> : tensor<2xi64>}}
       ins(%in, %fil : tensor<{N}x{H}x{W}x{IC}xbf16>, tensor<{KH}x{KW}x{IC}x{OC}xbf16>)
       outs(%f : tensor<{N}x{OH}x{OW}x{OC}xf32>) -> tensor<{N}x{OH}x{OW}x{OC}xf32>
  return %r : tensor<{N}x{OH}x{OW}x{OC}xf32>
}}
"""
    return mlir, N


def compile_npu(mlir_path, vmfb_path, device, kernel_kind,
                lower="air", tile="pack-peel"):
    """Publish only a successful compile; preserve a prior good VMFB on failure."""
    target = device["target"]
    extra = []
    if target == "npu4":
        extra.extend([
            "--iree-amdaie-enable-control-packet=true",
            "--iree-amdaie-packet-flow-strategy=auto",
        ])
        if kernel_kind == "matmul":
            # The same bf16 pipeline that run-matmul.sh verified on Strix Point.
            lower = "objectFifo"
            tile = "pack-peel-4-level-tiling"
            extra.extend([
                "--iree-amdaie-enable-ukernels=all",
                "--iree-amd-aie-enable-chess-for-ukernel=0",
                "--iree-amdaie-stack-size=3072",
            ])
    else:
        extra.append("--iree-amdaie-packet-flow-strategy=none")

    destination = Path(vmfb_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
            prefix=".npu-trim-compile.", dir=destination.parent) as work:
        temporary_vmfb = os.path.join(work, destination.name)
        cmd = [
            os.path.join(IREE, "iree-compile"), mlir_path,
            "--iree-hal-target-backends=amd-aie",
            f"--iree-amdaie-target-device={target}",
            f"--iree-amdaie-lower-to-aie-pipeline={lower}",
            f"--iree-amdaie-tile-pipeline={tile}",
            f"--iree-amd-aie-peano-install-dir={PEANO}",
            f"--iree-amd-aie-install-dir={os.path.join(ROOT, 'iree-install')}",
            "--iree-amdaie-device-hal=amdxdna",
            "--iree-hal-memoization=false",
            "--iree-hal-indirect-command-buffers=false",
            *extra,
            "-o", temporary_vmfb,
        ]
        r = run(cmd)
        output = Path(temporary_vmfb)
        success = r.returncode == 0 and output.is_file() and output.stat().st_size > 0
        if success:
            os.replace(output, destination)
        return success, r


def main():
    ap = argparse.ArgumentParser(description="Screen an imported graph and extract NPU-compilable matmul kernels.")
    ap.add_argument("model", help="model.onnx or model.linalg.mlir")
    ap.add_argument("--out-dir", default="npu_kernels", help="where to write extracted kernels (default ./npu_kernels)")
    ap.add_argument("--no-compile", action="store_true", help="skip the test-compile step")
    args = ap.parse_args()

    if args.model.endswith(".onnx"):
        print(f"{D}# importing {args.model} (ONNX → linalg) …{Rst}")
        mlir = import_onnx(args.model)
    else:
        try:
            mlir = Path(args.model).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"{RED}could not read input MLIR: {exc}{Rst}", file=sys.stderr)
            return 1

    device = None if args.no_compile else detect_device()
    if device:
        print(f"{D}# compile target: {device['generation']} {device['vbnv']} "
              f"({device['target']}, {device['rows']}x{device['cols']}){Rst}")

    print(f"\n{B}== op coverage =={Rst}")
    tiers = {"npu": (G, "✅ NPU"), "exp": (Y, "🟡 exp"), "cpu": (RED, "⛔ CPU")}
    for tier, op, why, n in classify(mlir):
        col, lbl = tiers[tier]
        print(f"  {col}{lbl}{Rst}  {op:<34} x{n}  {D}{why}{Rst}")

    os.makedirs(args.out_dir, exist_ok=True)
    mms = extract_matmuls(mlir)
    convs = extract_convs(mlir)
    if not mms and not convs:
        print(f"\n  {D}no static-shape linalg.matmul or conv_2d found to extract.{Rst}")
        return 0 if args.no_compile else 1

    def report(line, kpath, kernel_kind, lower, tile):
        if args.no_compile:
            print(line)
            return 0
        stem = os.path.splitext(kpath)[0]
        vmfb_path = f"{stem}.{device['target']}.vmfb"
        success, r = compile_npu(
            kpath, vmfb_path, device, kernel_kind, lower, tile)
        if success:
            print(f"{line}\n     {G}✓ compiles to {device['target']} → {vmfb_path}{Rst}")
            return 1
        err = next((l for l in (r.stderr or "").splitlines()
                    if "error" in l.lower() and "0x" not in l), "(crashed — likely unsupported shape/dtype)")
        print(f"{line}\n     {RED}✗ {device['target']}: {err.strip()[:120]}{Rst}")
        return 0

    ok = 0
    print(f"\n{B}== extracted matmul kernels ({len(mms)}) =={Rst}")
    for idx, (M, K, N, it, ot) in enumerate(mms):
        kernel, (Mp, Kp, Np) = emit_kernel(M, K, N)
        kpath = os.path.join(args.out_dir, f"matmul_{idx}_{Mp}x{Kp}x{Np}.mlir")
        Path(kpath).write_text(kernel, encoding="utf-8")
        padnote = "" if (Mp, Kp, Np) == (M, K, N) else f"{D} (padded from {M}x{K}x{N}){Rst}"
        ok += report(f"  matmul[{idx}] {it}→{ot}  {Mp}x{Kp}x{Np}{padnote}  →  {kpath}",
                     kpath, "matmul", "air", "pack-peel")

    print(f"\n{B}== extracted conv kernels ({len(convs)}) =={Rst}")
    for idx, c in enumerate(convs):
        kernel, Nk = emit_conv_kernel(c)
        kpath = os.path.join(args.out_dir,
                             f"conv_{idx}_{Nk}x{c['H']}x{c['W']}x{c['IC']}_to{c['OC']}.mlir")
        Path(kpath).write_text(kernel, encoding="utf-8")
        notes = []
        if c["layout"] != "NHWC":
            notes.append(f"imported {c['layout']} — transpose to NHWC at the edges")
        if Nk != c["N"]:
            notes.append(f"batch {c['N']}→{Nk} (amd-aie conv needs N≥2; run a {Nk}-batch, keep output[0])")
        tag = f"{D} ({'; '.join(notes)}){Rst}" if notes else ""
        ok += report(f"  conv[{idx}] {c['dtype']}  {Nk}x{c['H']}x{c['W']}x{c['IC']} * {c['KH']}x{c['KW']} → {c['OC']}ch{tag}  →  {kpath}",
                     kpath, "conv", "objectFifo", "conv-decompose")

    total = len(mms) + len(convs)
    if args.no_compile:
        print(f"\n{B}summary:{Rst} emitted {total} kernel(s) to {args.out_dir}/ "
              "(re-run without --no-compile to detect and test-compile for the local NPU).")
        return 0
    else:
        print(f"\n{B}summary:{Rst} {ok}/{total} kernels lower to {device['target']}; "
              f"wire them via tools/npu-runner, keep the ⛔ ops on CPU.")
        return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
