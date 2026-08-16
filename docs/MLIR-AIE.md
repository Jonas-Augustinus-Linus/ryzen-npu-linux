**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# The `mlir-aie` (IRON) track — author NPU kernels, both generations

The rest of this repo builds [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie):
a **graph compiler** that lowers whole models (PyTorch / ONNX) to the NPU. This
page is the verified recipe for the *other* open path —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) and its **IRON** Python
eDSL — where you **author NPU kernels directly** and run them via `pyxrt`.

The path has been verified on **both NPU generations**, but with
release-specific designs rather than one identical wheel:

> **XDNA1** — Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, `npu1`) ·
> Ubuntu 26.04 · kernel 7.0 · XRT 2.21 · verified 2026-06-24 with mlir-aie
> 1.3.x (the earlier single-Worker design).
>
> **XDNA2** — Ryzen AI 9 HX PRO 370 (Strix Point, `npu2`, XRT name
> `RyzenAI-npu4`) · Radeon 890M · Ubuntu 26.04 · kernel 7.0 · Ubuntu-native XRT
> 2.21.75 · NPU FW 1.1.2.64 · verified 2026-08-15 with **mlir-aie 1.4.1**
> (the current annotated single-Worker and whole-array designs).

The current 1.4.x designs have not been re-verified on XDNA1; the XDNA1 entry
records the earlier 1.3.x result.

## iree-amd-aie vs mlir-aie — which one?

| | `iree-amd-aie` (repo root) | `mlir-aie` / IRON (this page) |
|---|---|---|
| You bring | a whole graph (`.onnx` / PyTorch) | a kernel idea (dataflow + a C++ compute fn) |
| Abstraction | MLIR graph compiler | ObjectFifo dataflow eDSL (`aie.iron`) + `aiecc` |
| Run host | `iree-run-module` / the C-API runner | `pyxrt` (python design runs itself) |
| Best for | "run my model on the NPU" | "write/own a specific NPU kernel", real ML example blocks |
| Python | **3.12** (IREE build deps) | **3.14** (matches Ubuntu's packaged `pyxrt`) |
| Backend | Peano (`llvm-aie`) | the **same** Peano — `aie2` (npu1) / `aie2p` (npu2), picked automatically |

They're complementary, not competing. Use whichever fits the job.

## Setup (one script)

```bash
./scripts/setup-mlir-aie.sh
```

Idempotent; clones `Xilinx/mlir-aie` at the latest release tag, creates a
Python 3.14 venv, symlinks Ubuntu's packaged `pyxrt` into it, installs the
matching `mlir_aie` wheel (1.4.1 ships `cp314` manylinux wheels) + CPU torch,
and reuses your iree-amd-aie Peano (or installs the `llvm-aie` wheel — the
wheel is `py3-none`, Python-version-agnostic). Generation detection is
upstream's: `env_setup.sh` greps `xrt-smi examine` and exports `NPU2=0/1`.

## Run an example on the NPU

```bash
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh ml/softmax
./scripts/run-mlir-example.sh ml/conv2d          # Makefile example
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
    -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
```

**mlir-aie 1.4.x restructured the examples** — the script handles both shapes:

- Most examples are now a **single Python design run directly**: `@iron.jit`
  compiles on first call, the device (`npu`/`npu2`) is auto-detected, and the
  design carries its own benchmark/verify harness. Per-example Makefiles are
  gone from most of `basic/`; lit files (`run.lit` / `run_strix.lit`) document
  the canonical invocations.
- `ml/conv2d`, `ml/mobilenet`, matmul C++-host variants still use a Makefile —
  `devicename=npu2` selects the generation
  (`devicename ?= $(if $(filter 1,$(NPU2)),npu2,npu)`).
- `aiecc.py` is gone: `aiecc` is a **C++ binary** in 1.4.x, and **Peano is the
  default backend** (chess needs explicit `--xchesscc --xbridge` + Vitis).

## What runs on XDNA2 (verified, on the NPU, mlir-aie 1.4.1)

Strix Point exposes **8 columns / 32 compute tiles** to IRON (Phoenix: 4/16).
All measurements below from this repo's machines; "NPU time" is the runtime's
on-NPU figure (around `kernel.wait()`), excluding host launch overhead.

### Kernels & blocks

| Example | Kind | XDNA2 result |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ 94 µs |
| `basic/vector_scalar_mul` | vector × scalar | ✓ 106 µs |
| `ml/softmax` | LLM block | ✓ PASS |
| `ml/rope` | LLM block | ✓ PASS |
| `ml/swiglu` | LLM block | ✓ PASS |
| `ml/norm -o rms` | RMSNorm | ✓ PASS |
| `ml/mm_activation_epilogue` | matmul + fused activation | ✓ PASS |
| `ml/conv2d` (i8, 32×32, 64ch) | INT8 convolution | ✓ 490 µs (XDNA1: ~900 µs) |
| `ml/mobilenet` | **full network** | ✓ **PASS, ~176 ms/inference** |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | custom fused kernel | ✓ see below |
| [`examples/mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/) | **W4A16 quantized GEMM** | ✓ **PASS, 5.94 TOPS** (see below) |

`ml/mobilenet` is the design that **cannot run on XDNA1** — it wants more
columns than Phoenix's 4 and dies in `CREATE_HWCTX`. On Strix's 8 columns the
whole network runs end-to-end. (Upstream currently verifies it with a relaxed
`atol=9` tolerance — their note, reproduced here.)

### GEMM (`basic/matrix_multiplication/whole_array`, 8 columns)

| Shape | dtype | inner tile | NPU time | Throughput |
|---|---|---|--:|--:|
| 512³ | i16→i32 | 32³ | 203 µs | 1.32 TOPS |
| 512³ | bf16→f32 | 32³ | 233 µs | 1.15 TFLOPS |
| 512³ | bf16 via **bfp16** | 32³ | 199 µs | 1.35 TFLOPS |
| 2048³ | bf16 via **bfp16** | 32³ | 9.71 ms | 1.77 TFLOPS |
| 2048³ | i8→i32 | 32³ | 8.73 ms | 1.97 TOPS |
| 2048³ | bf16 via **bfp16** | 64×32×64 | 3.70 ms | **4.64 TFLOPS** |
| 2048³ | i8→i32 | 64³ | 2.59 ms | **6.65 TOPS** |

Two lessons the table teaches:

1. **Inner tile size is worth 3.4×** (i8: 1.97 → 6.65 TOPS just from 32³→64³
   tiles). Going bigger overflows the 64 KB core-local memory and fails
   placement — bf16 at 64³ already does.
2. **On AIE2P, prefer the bfp16 path for bf16 math**
   (`--emulate-bf16-mmul-with-bfp16 1`). bf16 MAC is native on XDNA1's AIE2
   but *emulated at ~¼ rate* on XDNA2's AIE2P; the native mode is **bfp16
   block floating point** (8×8×8). Free +17% at 512³, +25% with tuned tiles.

The **native bfp16ebs8** end-to-end design (`ml/block_datatypes/…`) also ran
against its CPU float reference, and exposed a correctness limit that a
throughput-only run would hide:

| Native bfp16 shape (8 columns) | Throughput | CPU-reference result |
|---|---:|---|
| 512³ | 1.525 TFLOPS | **PASS** |
| 1024³ | 4.892 TFLOPS | **PASS** |
| 2048³ | ~5.09 TFLOPS | **FAIL** — 291/1000 sampled, max relative error 12% |

The throughput values were recorded with Peano 22 (`4a1adefa`) before the
environment was aligned to the v1.4.1 pin. The complete PASS/FAIL sweep was
then repeated with pinned Peano 21 (`c9c5ecb7`) and the boundary was unchanged;
the script deliberately asserts correctness rather than timing.

Isolating the reduction length at M=N=1024 gives K=1216 **PASS** and K=1280
**FAIL**. [`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh)
reproduces and asserts that known boundary. Source inspection suggests that
each K tile reloads and stores the bfp16 output, repeatedly quantizing the
partial sum; that is a hypothesis explaining the K dependence, not a proven
fix. Do not report a native-bfp throughput unless the CPU-reference check also
passes. This is separate from the **bf16 input/output, bfp16-internal** 2048³
path in the table above: its **4.64 TFLOPS** result passed correctness.

### W4A16 quantized GEMM (int4 AWQ-g128 weights, bf16 activations)

The TileFuse fused dequant+GEMM kernel — compile-only status in the previous
release — now **runs on the NPU with CPU-reference PASS**, ported to the IRON
1.4.x whole-array dataflow with Peano only
([`examples/mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/)). Weights
stream as packed 4352-byte tiles (int4 data + bf16 scales + int8 zero-points,
one AWQ group per k-tile) and are dequantized in-core into a 16 KB
weight-stationary L1 cache — 3.76× less weight DRAM traffic than bf16 B:

| Shape | Columns | NPU time | Throughput | CPU reference |
|---|---|--:|--:|---|
| 512³ | 8 | 158 µs | 1.70 TOPS | PASS |
| 2048³ | 4 | 5.76 ms | 2.98 TOPS | PASS |
| 2048³ | 8 | **2.89 ms** | **5.94 TOPS** | PASS |
| 2048×4096×4096 | 8 | 11.0 ms | **6.24 TOPS** | PASS |

That is **+28% over the 4.64 TFLOPS bf16-via-bfp16 baseline** above, at ~90%
of the i8 record, with 4-bit weights. Column scaling 4→8 is 1.99× —
compute-bound. TileFuse's paper reports 9 TOPS on Strix with the chess
compiler; the gap is Peano kernel scheduling, not dataflow. The PASS
criterion bounds elementwise error against the `|A|·|B|` accumulation scale
(max ≈ 9·10⁻³ at 2048³); see the example README for why plain relative error
is the wrong gate for signed inputs on the bfp16 datapath, and GOTCHAS
M12–M14 for three traps this port surfaced.

### Custom kernel, whole-array scaling

Our fused `relu(a+b)` ([`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/)),
1M int32 elements, tile 1024:

| Design | NPU time | Effective DDR BW |
|---|--:|--:|
| single Worker (1 tile) | 8 967 µs | 1.4 GB/s |
| whole array (8 columns, `transform_parallel_binary`) | 1 123 µs | 11.2 GB/s |

**8.0× from 8 columns** — linear scaling for this bandwidth-bound kernel.

## What runs on XDNA1 (verified, on the NPU, 2026-06-24)

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| `examples/mlir-aie/relu_add` | custom fused `relu(a+b)` kernel | ~0.37 ms |

**Known limits on Phoenix (4 columns):** `ml/mobilenet` builds but fails
`DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` — whole-network designs are
XDNA2-scale (confirmed above). Single blocks fit and run.

## Author your own kernel

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) is a
hand-written kernel that is **not** one of the stock examples: a single fused
`out = max(a + b, 0)`. It shows the whole path on either generation —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — the compute
  kernel; Peano compiles it for `aie2` or `aie2p` per the detected device, no
  source change.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — the IRON 1.4.x
  annotated-`@iron.jit` form (`In`/`Out`/`CompileTime[...]`), in two designs:
  single-Worker (`transform_binary`) and one-Worker-per-column
  (`transform_parallel_binary`, 4 or 8 columns auto).

```bash
./examples/mlir-aie/relu_add/run.sh
```

**API note:** IRON 1.4.x **requires** the annotations — the older
`iron.jit(transform_binary)(kernel, a, b, out, tile_size=…)` call form (what
this example used on 1.3.x) now raises `TypeError: … no In / Out / InOut /
CompileTime[T] annotation`. The 1.4.x algorithms take a *tensor type
descriptor* inside the jit body instead of live tensors. Porting is mechanical
— see the example's diff.

## Gotchas specific to this path

Short list — full detail in [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie track*:

1. **Python 3.14 here, not 3.12** (Ubuntu's packaged `pyxrt` is cpython-314).
2. **Expose `pyxrt` by symlink** into the venv site-packages.
3. ⚠️ **Source `env_setup.sh` without a pipe** — a pipe = subshell = the
   exports (`NPU2`, `PEANO_INSTALL_DIR`…) vanish.
4. **IRON 1.4.x annotation API break** — see above.
5. **Core-local memory is 64 KB**: 3 double-buffered int32 FIFOs at
   `tile_size` 4096 = 96 KB → `aie.tile op … allocation failed`. Size tiles to
   fit.
6. **Binary kernels can't use `num_channels=2`** — 2 inputs already occupy
   both shim MM2S DMA channels per column
   (`no ShimNOCTile has sufficient DMA capacity`).
7. **bf16 on AIE2P is ¼-rate emulation** — use the bfp16 path (see GEMM
   lessons above).
8. **Reuse the Peano** from `iree-amd-aie` when present; unpinned
   `pip install llvm-aie` today grabs a 22.x nightly one LLVM major ahead of
   what mlir-aie CI tests — the setup script pins for you.

## Relationship to the rest of the repo

This is an *additional* path, not a replacement. For "run my model on the
NPU", the `iree-amd-aie` flow (`scripts/build.sh` + `scripts/run-matmul.sh` +
the `npu-trim` / `npu-runner` tools) is still the answer on XDNA1; its XDNA2
port is tracked in [XDNA2.md](XDNA2.md). Reach for `mlir-aie` when you want to
**write a specific kernel** or run the upstream **ML example blocks** directly.
