**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Running real compute on a Ryzen AI **XDNA1** NPU on **Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1](https://img.shields.io/badge/NPU-Ryzen%20AI%20XDNA1-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

A reproducible, end-to-end recipe — with tools — for taking an AMD Ryzen AI
**first-generation (XDNA1 / "Phoenix")** NPU from *driver-visible-but-idle* to
**actually executing matmuls** on Linux, by building
[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) from source.

> **Why this repo exists.** Almost every "the Ryzen AI NPU finally works on Linux"
> article in 2026 is about **XDNA2** (Strix/Krackan). The first-gen **XDNA1**
> chips in Ryzen 7040/8040 laptops (e.g. the 7840U) are *explicitly excluded* by
> the turnkey stacks — AMD's Ryzen AI Software for Linux, ONNX Runtime's Vitis AI
> EP, Lemonade/FastFlowLM. On XDNA1+Linux the NPU is powered on and enumerated by
> the in-tree `amdxdna` driver, but **no shipped runtime will execute a model on
> it.** The one open path that *does* target XDNA1 is `iree-amd-aie` — built from
> source. This repo is the verified, gotcha-by-gotcha map of that path.

## 🎬 Demos

**End-to-end — an ONNX MLP on the NPU** (matmuls on the NPU, `ReLU` on the CPU; matches the CPU reference to ~0.3%):

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python, **on the NPU** | NPU 2D-blur on three `videotestsrc` patterns → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| wake-word KWS — 3 dense layers on the NPU (target fires, noise stays silent) | bf16 is the NPU's native strength — up to **220 GFLOP/s** |
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
git clone https://github.com/<you>/ryzen-npu-linux.git && cd ryzen-npu-linux

# 0. Is the NPU even alive? (read-only diagnostic)
./scripts/check-npu.sh

# 1. (if check failed on groups/memlock/xrt) activate it for your user, then re-login
./scripts/enable-npu.sh

# 2. Build iree-amd-aie from source (~65 min, 30-60 GB disk). All workarounds baked in.
./scripts/build.sh

# 3. Run a matmul ON THE NPU
./scripts/run-matmul.sh i32          # 128x128x128, all 768
./scripts/run-matmul.sh bf16         # 256x256x256 bf16->f32, all 1536
BENCH=1 ./scripts/run-matmul.sh bf16 # + benchmark
```

## 🧰 The tools

| Script | What it does |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Read-only: checks driver, device node, render group, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Fixes the 3 things that block a non-root user (render group, memlock, XRT). |
| [`scripts/build.sh`](scripts/build.sh) | Clones + builds `iree-amd-aie` with every workaround applied. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Compiles + runs an `i32`/`bf16` matmul on the NPU. The recipe. |

## 🔬 Examples & tools

- [`tools/npu-trim/`](tools/npu-trim/) — **screen an imported `.onnx` and extract the matmuls and convs that actually compile to the NPU** (classify ops, emit clean bf16 kernels, test-compile; the rest stays on CPU).
- [`tools/npu-runner/`](tools/npu-runner/) — **persistent NPU caller** (IREE C API + `libnpu.so`/ctypes): load a `.vmfb` once, invoke many times — **~3.7 ms vs ~41 ms** for per-call `iree-run-module`. The piece that makes always-on use deployable.
- [`examples/matmul_i32.mlir`](examples/matmul_i32.mlir) · [`examples/matmul_bf16.mlir`](examples/matmul_bf16.mlir) — the minimal verified NPU matmuls.
- [`examples/wake-word/`](examples/wake-word/) — **a runnable wake-word detector** whose dense layers run on the NPU (`./run.sh --selftest`: target fires, noise stays silent). The cleanest always-on agent fit.
- [`examples/onnx-mlp/`](examples/onnx-mlp/) — **end-to-end: an ONNX MLP runs on the NPU** (npu-trim extracts the matmuls → npu-runner runs them → ReLU on CPU → verified vs a CPU reference).
- [`examples/npu-camera/`](examples/npu-camera/) — **always-on NPU video filter → virtual camera** (`/dev/video10`): GStreamer → NPU per-frame → Zoom/Meet/OBS, at **30 fps**, installable as a systemd `--user` service.

## 🧩 Second path: `mlir-aie` (IRON)

`iree-amd-aie` (above) compiles **whole graphs**;
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON) is the lower-level
path — you **author NPU kernels directly** and run them via `pyxrt`, and it ships
real ML `programming_examples`. Both target `npu1` and **share the Peano backend
you already built**, so it's cheap to add. Full guide → **[docs/MLIR-AIE.md](docs/MLIR-AIE.md)**.

```bash
./scripts/setup-mlir-aie.sh                 # mlir_aie wheel + py3.14 venv + reuse your Peano
./scripts/run-mlir-example.sh ml/conv2d     # build for npu1 + run ON THE NPU (pyxrt)
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

`basic/matrix_multiplication` compiles to an xclbin (its `run` host is C++ — needs
`libxrt-dev`); `ml/mobilenet` is XDNA2-scale (wants > 4 columns). Details and the
author-your-own-kernel walkthrough are in **[docs/MLIR-AIE.md](docs/MLIR-AIE.md)**.

## 🪤 The gotchas (why a naive build/run fails)

Full detail in **[docs/GOTCHAS.md](docs/GOTCHAS.md)**. The short list:

1. **Use `gcc`, not `clang`, as the host compiler.** clang 21 *segfaults* compiling MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Python bindings hit `-Werror,-Wmacro-redefined`; the CLI tools don't need them.
3. **Bump the Peano (`llvm-aie`) pin.** The repo's pinned nightly has expired from the index; `build.sh` auto-selects the newest.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** You intentionally skip 3 heavy submodules.
5. **Compile with `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`) or the dispatch times out.
6. ⚠️ **Run with `--amdxdna_n_core_cols=4`, not 5.** Phoenix reports 5 raw columns but uses 4 (`npu1_4col`). Passing 5 → cores hang → `ert state 8` timeout.

## 🎯 Where can you actually use this?

**Full audience-by-audience guide (games · AI agents · local apps) with feasibility ratings → [docs/APPLICATIONS.md](docs/APPLICATIONS.md).**

Quick version — **[docs/USE-CASES.md](docs/USE-CASES.md)**. Honestly: this is **kernel-level**
(matmul/conv building blocks), not turnkey model serving. Good for learning NPU
programming, benchmarking, building/offloading specific low-power inference
primitives, and contributing to the open XDNA1-on-Linux effort. It will **not**
give you a drop-in LLM/Whisper/ONNX runtime on XDNA1 — that's XDNA2 / Windows territory.

## 📚 Background

See **[docs/BACKGROUND.md](docs/BACKGROUND.md)** for XDNA1 vs XDNA2, why Linux is
hard for first-gen, and how the `amdxdna` HAL talks to `/dev/accel0`.

## 🧭 Where this sits (and what it is *not*)

**This is not the first NPU-on-Linux project, and it invents none of the stack** —
the driver, compiler, and runtime all predate it and do the heavy lifting:

| Layer | Prior art we build on / sit next to |
|---|---|
| Kernel driver | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, mainline since Linux 6.14, enumerates XDNA1 as `/dev/accel/accel0` |
| Compiler / runtime | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — SDKs/frameworks that compile for `npu1` |
| Prior XDNA1 + Linux compute | a research paper ([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — GPT-2 on a Phoenix 7940HS via IRON), primitive-only tutorials, the [Gentoo wiki XDNA writeup](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| Turnkey NPU LLM on Linux | FastFlowLM · Lemonade 10.x · AMD Ryzen AI SW — **all XDNA2-only; they explicitly exclude XDNA1** |

So "first NPU on Linux", "first compiler", or "first to run XDNA1" would all be
overclaims — and we don't make them.

**What this repo *is*:** as far as public searching (2026-06) can find, the first
— and only — **packaged, reproducible, end-to-end recipe + toolkit** that runs
*arbitrary real compute* (i32/bf16 matmul, conv) on the **first-gen XDNA1
(Phoenix, e.g. 7840U) NPU on Linux** — the exact hardware/OS combo every turnkey
vendor stack leaves orphaned. The prior art is either an upstream **SDK/framework**
(you navigate the from-source gotchas yourself), an **XDNA2-only** app, a
**research paper** (no click-to-run repo), or a **Windows-only** compute path. The
distinctive part is the *bundle*: diagnose→enable→build→run scripts, the from-source
**gotcha map**, the **persistent C-API/ctypes runner** (~11× faster than per-call
`iree-run-module`), the **app examples** (wake-word, NPU camera daemon), the
**honest feasibility-rated applications guide** (incl. the measured "NPU loses to
CPU for audio"), and 5-language docs.

> **Honest caveat:** this positioning is from public search of READMEs and snippets
> (no external repo was cloned/verified). We **cannot** see private repos, corporate
> work, or the long tail of one-off scripts — "we found no direct peer" means
> exactly that, not "none exists."

## ⚖️ Disclaimer

Community notes, not an AMD/Xilinx product. `iree-amd-aie` is early-phase and
moves fast; versions/flags drift. Everything here was verified on the exact
machine above on 2026-06-22. Issues/PRs with results from other XDNA1 laptops welcome.

## 🤝 Contributing

The most useful contribution is **a result from your own XDNA1 machine** — first-gen
Ryzen AI on Linux coverage is thin. See **[CONTRIBUTING.md](CONTRIBUTING.md)**. In short:

- **Report hardware results** — your chip / kernel / distro and what worked or failed (issue template provided).
- **Add benchmarks** for other shapes/dtypes, or **new ops** (conv, i8, …).
- **Fix or refine a [gotcha](docs/GOTCHAS.md)**, harden the scripts, or add/correct a translation.
- Fork → branch → test with `scripts/run-matmul.sh` → PR describing what you ran it on.

## 📄 License

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — use it, fork it, ship it.

The scripts and docs in this repo are MIT. They build and drive third-party
projects under their own licenses — IREE and `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) — which this repo does not redistribute.
