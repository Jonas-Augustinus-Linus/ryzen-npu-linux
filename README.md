**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Open Ryzen AI **XDNA1 + XDNA2** compute on **Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Jonas-Augustinus-Linus/ryzen-npu-linux)](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1 and XDNA2](https://img.shields.io/badge/NPU-XDNA1%20%2B%20XDNA2-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

An open, reproducible path from *driver-visible-but-idle* to real, CPU-checked
NPU compute on Linux. It preserves the original XDNA1/Phoenix from-source path
and now carries the same detect → build → verify → persistent-runner contract to
Strix Point XDNA2 (`RyzenAI-npu4`).

> **Why this repo exists.** First-generation **XDNA1** silicon in Ryzen 7040/8040
> laptops—including the 7840U—can be driver-visible yet left idle by current
> turnkey Linux products. As of 2026-08-15, AMD's official Linux support page
> lists STX/KRK, not Phoenix.[^amd-linux-support] That product boundary does not
> make the device useless. There are now **two open lower-level routes**:
> `iree-amd-aie`, which this repo pins and packages into a reproducible IREE path,
> and the direct-kernel [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)
> stack, whose IRON Python API/compiler track this repo pins at 1.4.1. The newer
> [`amd/IRON`](https://github.com/amd/IRON) operator/application library is a
> **separate project built on MLIR-AIE language bindings**, not a rename of
> `Xilinx/mlir-aie`. This repo provides CPU-checked paths and explicit evidence
> boundaries—not a claim of turnkey whole-model serving.

> 🆕 **On XDNA2 Strix Point (`RyzenAI-npu4`)?** The second generation flipped the landscape:
> turnkey LLM inference now exists on Linux (FastFlowLM/Lemonade), Ubuntu 26.04
> ships the XRT userspace natively — and this repo's activation tooling works
> there **unchanged** (verified on a Ryzen AI 9 HX PRO 370). **Compute too**:
> the mlir-aie/IRON track runs on all 8 Strix columns — 6.65 TOPS i8 GEMM,
> full MobileNet, our custom kernel at 8.0× column scaling
> ([docs/MLIR-AIE.md](docs/MLIR-AIE.md)). What transfers, what changes, and
> where the open frontier moved: **[docs/XDNA2.md](docs/XDNA2.md)**. Later
> `npu5`/`npu6` devices are not silently mapped or claimed; see the exact
> [support matrix](docs/SUPPORT.md).

## 🌱 Why we give this away

Finishing the path on one machine is not the finish line. This repository is
MIT-licensed and published freely so Linux users can inspect every layer, repeat
the evidence, change the kernels, and give improvements back. Our hope is that
students, independent developers, researchers, and small teams can use this as
shared ground for **many different LLMs and local AI systems**: private agents,
accessibility tools, multilingual models, low-power services, new quantization
ideas, and applications we have not imagined.

**Anyone may use, copy, modify, fork, publish, redistribute, sublicense, teach
with, or use this work commercially** under the MIT License. Keep the required
copyright and license notice; third-party code and model assets retain their own
licenses. No separate permission is needed, and contributions back are welcome
but not required.

This is a foundation, not a claim that an arbitrary LLM already runs end to end.
It makes the foundation concrete: strict device detection, pinned builds,
CPU-reference correctness, persistent C/Python invocation, working examples,
and public failure boundaries. The measure of success is not ownership of one
model; it is other people being able to build on the work. Enter the
[Open NPU Lab](docs/OPEN-NPU-LAB.md), follow each claim into the primary-source
[research ledger](docs/RESEARCH.md), then choose a milestone from the
[open LLM roadmap](docs/LLM-ROADMAP.md) or [contribution guide](CONTRIBUTING.md).

## 🎬 Demos

### XDNA2 / Strix Point — live hardware

IREE `npu4` i32 and bf16 matmuls match their CPU references exactly, the
persistent runner verifies all 16,384 outputs, and the custom IRON kernel passes
on all 8 columns through both XRT and HRX:

![XDNA2 Strix Point live-hardware demo with exact CPU checks, full-output npu-runner verification, and IRON XRT and HRX passes](docs/media/xdna2-compute.gif)

### XDNA1 / Phoenix — original verified demos

**Hybrid mechanics demo — a generated ONNX MLP** (matmuls on the NPU, `ReLU`
on the CPU; generated weights, not a trained application; matches its CPU
reference to ~0.3%):

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python, **on the NPU** | non-AI NPU 2D box blur on three `videotestsrc` patterns → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| wake-word pipeline — 3 dense NPU layers with **illustrative, untrained weights** | bf16 is the NPU's native strength — up to **220 GFLOP/s** |
| ![wake-word demo](docs/media/wake-word.gif) | ![benchmark demo](docs/media/benchmark.gif) |
| bring a real `.onnx` → NPU-targetable MLIR (hybrid import; the from-source amd-aie codegen's op coverage is the frontier) | extract the matmuls **and convs** that **do** compile to the NPU — `npu-trim` screens ops & emits clean kernels |
| ![onnx-import demo](docs/media/onnx-import.gif) | ![npu-trim demo](docs/media/npu-trim.gif) |

## ✅ What works (verified)

Compiled and executed **on the NPU** (`--device=amdxdna`), correct results,
repeatable:

| Workload | Shape | Result | Throughput (NPU) |
|---|---|---|---|
| `i32` matmul | 128×128×128 | ✓ exact | ~3.6 ms/iter, ~280/s |
| `bf16 → f32` matmul | 256×256×256 | ✓ exact (incl. fractional) | ~2.9 ms/iter, ~350/s |

Tested machine: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · kernel 7.0 · in-tree `amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**.
These XDNA1 measurements are historical from the then-current nightly; they
have not yet been rerun with the current v1 exact lock, which was revalidated on Strix.

## 📊 Benchmarks

End-to-end on the NPU via `iree-benchmark-module` (`--device=amdxdna`,
`npu1_4col`, 10 reps, mean). Wall-clock includes host dispatch overhead, so the
smallest matmuls are dispatch-bound; effective compute climbs with size.

| dtype | shape (M×N×K) | time/iter | throughput | compute |
|---|---|--:|--:|--:|
| `i32` | 128×128×128 | 3.58 ms | 279 it/s | 1.2 GFLOP/s |
| `i32` | 256×256×256 | 8.08 ms | 124 it/s | 4.2 GFLOP/s |
| `i32` | 512×512×512 | 43.6 ms | 23 it/s | 6.2 GFLOP/s |
| `bf16→f32` | 256×256×256 | 2.86 ms | 350 it/s | 11.7 GFLOP/s |
| `bf16→f32` | 512×512×512 | 3.90 ms | 257 it/s | 68.8 GFLOP/s |
| `bf16→f32` | 1024×1024×1024 | 9.76 ms | 102 it/s | 220 GFLOP/s |

**bf16 is the NPU's native strength** — ~220 GFLOP/s at 1024³ and still scaling,
while `i32` (not the AIE's native type) tops out near 6 GFLOP/s. Reproduce any row:
`BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`.

## 🚀 Quickstart

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux

# Read host/disk/sudo requirements, then run the strict read-only check.
less docs/SUPPORT.md
./scripts/check-npu.sh --strict

# Only if the check reports group/memlock/XRT failures: review, run, reboot once.
./scripts/enable-npu.sh

# Build the versions.lock-pinned IREE/Peano toolchain from source; this also
# installs libxrt-dev for the native IRON host checks used by --full.
./scripts/build.sh

# One public acceptance contract: detect -> CPU references -> native/Python runner.
./scripts/verify-stack.sh --quick

# Optional: set up the separately pinned IRON stack, then verify everything.
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

## 🧰 The tools

| Script | What it does |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Read-only: checks driver, device node, render group, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Fixes the 3 things that block a non-root user (render group, memlock, XRT). |
| [`scripts/detect-npu.sh`](scripts/detect-npu.sh) | Maps only verified VBNV/geometry pairs to `npu1_4col` or `npu4`; rejects unknown devices. |
| [`scripts/build.sh`](scripts/build.sh) | Builds the `versions.lock`-pinned IREE/Peano source stack. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Compiles, runs, and fully CPU-checks an `i32`/`bf16` matmul. |
| [`scripts/verify-stack.sh`](scripts/verify-stack.sh) | One strict hardware acceptance test for CLI, native runner, Python, and optional apps/IRON. |
| [`scripts/validate-repo.sh`](scripts/validate-repo.sh) | Hardware-free local/CI release checks. |

## 🔬 Examples & tools

- [`tools/npu-trim/`](tools/npu-trim/) — **screen an imported `.onnx` and extract the matmuls and convs that actually compile to the NPU** (classify ops, emit clean bf16 kernels, test-compile; the rest stays on CPU).
- [`tools/npu-runner/`](tools/npu-runner/) — **persistent NPU caller** (IREE C API + `libnpu.so`/ctypes): load a `.vmfb` once, invoke many times; the historical XDNA1 measurement was **~3.7 ms vs ~41 ms** for per-call `iree-run-module`.
- [`examples/matmul_i32.mlir`](examples/matmul_i32.mlir) · [`examples/matmul_bf16.mlir`](examples/matmul_bf16.mlir) — the minimal verified NPU matmuls.
- [`examples/local-rag-sidecar/`](examples/local-rag-sidecar/) — **a real NPU-in-the-RAG-loop integration**: CPU chunk/hash → persistent NPU score matrix → CPU top-k → optional local LLM. Its hashed features are not trained embeddings, one small query is likely faster on CPU, and current-lock XDNA1 hardware verification remains pending; the live current-lock result is XDNA2.
- [`examples/wake-word/`](examples/wake-word/) — **persistent wake-word pipeline mechanics** on XDNA1/npu4. The self-test dispatches three dense layers, but its illustrative matched-filter weights are not a trained vocabulary.
- [`examples/onnx-mlp/`](examples/onnx-mlp/) — **a real hybrid forward path with a generated model**: two NPU matmuls + explicit CPU ReLU, each checked against bf16 CPU references; it is not a trained application or arbitrary ONNX runtime.
- [`examples/npu-camera/`](examples/npu-camera/) — **always-on NPU video plumbing → virtual camera** (`/dev/video10`): GStreamer → two persistent dispatches per frame. The NPU operation is a non-AI box blur; the original XDNA1 plumbing demo measured 30 fps, while npu4's processing core is correctness-tested separately.

## 🧩 Second path: `mlir-aie` (IRON)

`iree-amd-aie` (above) compiles supported IREE graphs;
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) is the lower-level stack
this repo pins at 1.4.1. Its IRON Python API/compiler path lets you **author NPU
kernels directly** and run them via `pyxrt`, and the project ships
real ML `programming_examples`. The hardware paths have evidence on **both
generations**, but not under the same dependency snapshot: the Phoenix/`npu1`
results are historical, while the v1 exact lock was revalidated on Strix/`npu2`
(auto-detected). Current-pin XDNA1 reports are welcome. Setup reuses
iree-amd-aie's Peano only when
its exact `llvm-aie` version **and clang build commit** match this mlir-aie
release's `utils/peano-requirements.txt` pin; otherwise it installs that pinned
wheel in the mlir-aie venv. Full guide → **[docs/MLIR-AIE.md](docs/MLIR-AIE.md)**.

[`amd/IRON`](https://github.com/amd/IRON) is a separate, newer operator and
application library built on MLIR-AIE language bindings; it is neither a rename
nor the new repository location of `Xilinx/mlir-aie`. That moving library is
materially broader than this release's pinned direct-kernel track. At exact
commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93), AMD's official
Phoenix workflow reported **2,105 passing and 45 skipped pytest case-runs**.
Because the workflow's default is five iterations, those totals represent
**421 distinct passing configurations and 9 distinct skipped configurations**,
not 2,105 different tests. The nine skips are three MHA, three streaming-SwiGLU,
and three GEMV+GELU configurations, each repeated five times.[^iron-phoenix-ci]
Passing CPU-referenced AIE2 coverage includes GEMM/GEMV, Q4NX dequantization,
softmax, RoPE, RMSNorm/LayerNorm, activations, and transpose. This is upstream
Phoenix evidence, not this repo's current-lock XDNA1 rerun or an end-to-end LLM;
GQA is not established by this Phoenix run.

```bash
./scripts/setup-mlir-aie.sh                 # mlir_aie wheel + py3.14 venv + compatible Peano
./scripts/run-mlir-example.sh ml/conv2d     # build for the detected NPU + run ON IT (pyxrt)
./examples/mlir-aie/relu_add/run.sh         # a custom hand-written fused kernel
```

Verified **on the NPU** (XDNA1, `run_py` / `pyxrt`, output vs a torch/numpy golden):

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 conv | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layers | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

On **XDNA2** (Strix Point, 8 columns / 32 tiles, mlir-aie 1.4.1): whole-array
GEMM hits **6.65 TOPS** (i8) / **4.64 TFLOPS** (bf16 via bfp16), the LLM blocks
(softmax/RoPE/SwiGLU/RMSNorm) pass, **full `ml/mobilenet` runs** (~176 ms — it
*can't* run on Phoenix's 4 columns), and our custom kernel scales **8.0×**
across the columns. The XDNA2 tables and the author-your-own-kernel
walkthrough are in **[docs/MLIR-AIE.md](docs/MLIR-AIE.md)**.

## 🪤 The gotchas (why a naive build/run fails)

Full detail in **[docs/GOTCHAS.md](docs/GOTCHAS.md)**. The short list:

1. **Use `gcc`, not `clang`, as the host compiler.** clang 21 *segfaults* compiling MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Python bindings hit `-Werror,-Wmacro-redefined`; the CLI tools don't need them.
3. **Use the locked Peano (`llvm-aie`).** `build.sh` installs and verifies the exact `versions.lock` pin; it fails instead of silently selecting a newer nightly.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** You intentionally skip 3 heavy submodules.
5. **Compile with `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`) or the dispatch times out.
6. ⚠️ **Run with `--amdxdna_n_core_cols=4`, not 5.** Phoenix reports 5 raw columns but uses 4 (`npu1_4col`). Passing 5 → cores hang → `ert state 8` timeout.

## 🎯 Where can you actually use this?

**Full audience-by-audience guide (games · AI agents · local apps) with feasibility ratings → [docs/APPLICATIONS.md](docs/APPLICATIONS.md).**

Quick version — **[docs/USE-CASES.md](docs/USE-CASES.md)**. Build a hybrid local-AI
lab: NPU for repeated scoring, always-on stages, and verified dense/conv blocks;
CPU for I/O, policy, and fallback; iGPU for token generation when needed. The
new [local RAG sidecar](examples/local-rag-sidecar/) shows that split in source.
There is still no drop-in whole-model XDNA1 server here, and energy efficiency
remains a measurement goal rather than a repo-proven result.

## 📚 Background

See **[docs/BACKGROUND.md](docs/BACKGROUND.md)** for XDNA1 vs XDNA2, why Linux is
hard for first-gen, and how the `amdxdna` HAL talks to `/dev/accel0`.

## 🧭 Where this sits (and what it is *not*)

**This is not the first NPU-on-Linux project, and it invents none of the stack** —
the driver, compiler, and runtime all predate it and do the heavy lifting:

| Layer | Prior art we build on / sit next to |
|---|---|
| Kernel driver | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, mainline since Linux 6.14, enumerates XDNA1 as `/dev/accel/accel0` |
| Compiler / runtime | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (the pinned 1.4.1 IRON Python API/compiler stack), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — upstream SDKs/frameworks targeting XDNA generations |
| Newer operator / application library | [`amd/IRON`](https://github.com/amd/IRON) — a separate project built on MLIR-AIE language bindings, not a rename or new location of `Xilinx/mlir-aie` |
| Prior XDNA1 + Linux compute | a research paper ([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — GPT-2 on a Phoenix 7940HS via IRON), primitive-only tutorials, the [Gentoo wiki XDNA writeup](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| Turnkey NPU LLM on Linux | [`FastFlowLM`](https://github.com/ROCm/FastFlowLM) and [`Lemonade`](https://github.com/lemonade-sdk/lemonade/blob/main/docs/guide/faq.md) explicitly require XDNA2 for their NPU paths; AMD Ryzen AI Software 1.8 for Linux lists STX/KRK only, not Phoenix XDNA1 |

So "first NPU on Linux", "first compiler", or "first to run XDNA1" would all be
overclaims — and we don't make them.

**What this repo *is*:** a **packaged, reproducible, end-to-end recipe + toolkit**
that began by making real compute available on the first-gen XDNA1/Phoenix path
left out of turnkey stacks, and now gives Strix Point npu4 the same public
correctness contract. The prior art is either an upstream **SDK/framework**
(you navigate the from-source gotchas yourself), an **XDNA2-only** app, a
**research paper** (no click-to-run repo), or a **Windows-only** compute path. The
distinctive part is the *bundle*: diagnose→enable→build→run scripts, the from-source
**gotcha map**, the **persistent C-API/ctypes runner** (~11× faster than per-call
`iree-run-module`), the **app examples** (wake-word, NPU camera daemon), the
**honest feasibility-rated applications guide** (incl. the measured "NPU loses to
CPU for audio"), and 5-language docs.

> **Honest caveat:** the ecosystem changes quickly and private/corporate work is
> not visible. Please open an issue when a newer project or result should be
> credited or compared; this repository benefits from a better shared map.

## ⚖️ Disclaimer

Community notes, not an AMD/Xilinx product. `iree-amd-aie` is early-phase and
moves fast; versions/flags drift. Hardware evidence is dated and pin-specific:
the XDNA1/Phoenix results are historical from the then-current nightly, while
the v1 exact lock was revalidated on Strix Point XDNA2 through 2026-08-15. No
Hawk Point result is recorded yet. Current-pin XDNA1 and other XDNA1/XDNA2
results are welcome with the exact device identity and verification log.

## 🤝 Contributing

The most useful contribution is **a reproducible result from your own XDNA1 or
XDNA2 machine**. See **[CONTRIBUTING.md](CONTRIBUTING.md)**. In short:

- **Report hardware results** — your chip / kernel / distro and what worked or failed (issue template provided).
- **Add benchmarks** for other shapes/dtypes, or **new ops** (conv, i8, …).
- **Fix or refine a [gotcha](docs/GOTCHAS.md)**, harden the scripts, or add/correct a translation.
- Fork → branch → run `scripts/validate-repo.sh` and `scripts/verify-stack.sh --quick`
  where hardware applies → open a PR describing exactly what you ran.

## 📄 License

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — use it, copy it, modify it,
fork it, publish it, redistribute it, teach with it, or ship it commercially.
Preserve the copyright and license notice as the license requires.

The scripts and docs in this repo are MIT. They build and drive third-party
projects under their own licenses — IREE and `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) — which this repo does not redistribute.

[^amd-linux-support]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), accessed 2026-08-15.
[^iron-phoenix-ci]: AMD IRON, [official Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
