**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# The `mlir-aie` (IRON) track — a second open path to the XDNA1 NPU

The rest of this repo builds [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie):
a **graph compiler** that lowers whole models (PyTorch / ONNX) to the NPU. This
page is the verified recipe for the *other* open path —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) and its **IRON** Python
eDSL — where you **author NPU kernels directly** and run them via `pyxrt`. It also
ships real ML `programming_examples` (conv2d, ResNet blocks, Google's Magika), so
it's the fastest way to get *named* workloads onto a first-gen Phoenix NPU.

Both paths target `npu1` (Phoenix / XDNA1) and share the **same Peano (`llvm-aie`)
backend** — so if you've already run `./scripts/build.sh`, this track reuses that
Peano and costs almost nothing extra.

> Same machine as everything else here: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO
> 7840U (Phoenix, XDNA1) · Ubuntu 26.04 · kernel 7.0 · in-tree `amdxdna` · XRT
> 2.21 · NPU FW 1.5.5.391**. Verified 2026-06-24.

## iree-amd-aie vs mlir-aie — which one?

| | `iree-amd-aie` (repo root) | `mlir-aie` / IRON (this page) |
|---|---|---|
| You bring | a whole graph (`.onnx` / PyTorch) | a kernel idea (dataflow + a C++ compute fn) |
| Abstraction | MLIR graph compiler | ObjectFifo dataflow eDSL (`aie.iron`) + `aiecc` |
| Run host | `iree-run-module` / the C-API runner | `pyxrt` (`make run_py`) |
| Best for | "run my model on the NPU" | "write/own a specific NPU kernel", real ML example blocks |
| Python | **3.12** (IREE build deps) | **3.14** (matches Ubuntu's packaged `pyxrt`) |
| Backend | Peano (`llvm-aie`) | the **same** Peano |

They're complementary, not competing. Use whichever fits the job.

## Setup (one script)

```bash
./scripts/setup-mlir-aie.sh
```

It is idempotent and does the following:

1. **Clones `Xilinx/mlir-aie` at the latest release tag** (`~/src/mlir-aie`). The
   `programming_examples` must match the installed wheel, so the tag is pinned to
   the wheel version.
2. **Creates a Python 3.14 venv** (`~/src/mlir-aie-venv`) and **symlinks the
   packaged `pyxrt`** (`python3-xrt`, built `cpython-314`) into it — that's why
   the venv is 3.14 and not the 3.12 used for the iree-amd-aie build.
3. **Installs the `mlir_aie` wheel** (matching tag) **+ CPU `torch`** (the `ml/*`
   examples check NPU output against a torch golden).
4. **Reuses the Peano** you built for `iree-amd-aie` (`~/src/iree-amd-aie/llvm-aie`);
   if it's not there, it installs the `llvm-aie` nightly wheel instead.

## Run an example on the NPU

```bash
./scripts/run-mlir-example.sh ml/conv2d                 # default target: run_py (pyxrt)
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: needs libxrt-dev
```

`run-mlir-example.sh` sources [`scripts/mlir-aie-env.sh`](../scripts/mlir-aie-env.sh)
(toolchain on `PATH`, Peano wired, device auto-detected as `npu1`), builds the
example for `npu1`, and runs it on the NPU. It defaults to the **`run_py`** make
target — a `pyxrt` host that needs **no** XRT dev headers.

## What runs on XDNA1 (verified, on the NPU)

All via `run_py` / `pyxrt`, output checked against a torch/numpy golden. NPU times
are wall-clock incl. host dispatch (they vary run to run):

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block (1×1→3×3→1×1 + skip) | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

**Known limits on Phoenix (4 columns):**

- `basic/matrix_multiplication/*` builds to an **xclbin fine** (512³, 4 columns)
  but its host is **C++ only** — `make run` needs `libxrt-dev` (the runtime
  packages don't ship XRT dev headers). `sudo apt install libxrt-dev`, then
  `./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run`.
- `ml/mobilenet` builds but fails at run with
  `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)`: the whole-network design wants more
  than Phoenix's **4** columns. Single blocks (conv2d, bottleneck, resnet
  conv2_x) and `magika` fit and run; the full network is XDNA2-scale.

## Author your own kernel

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) is a hand-written
kernel that is **not** one of the stock examples: a single fused
`out = max(a + b, 0)` (residual add + ReLU). It shows the whole path —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — the compute kernel,
  compiled for `aie2` by Peano.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — an
  `iron.ExternalFunction` wired through `transform_binary` and compiled + run by
  `iron.jit`, checked against numpy.

```bash
./examples/mlir-aie/relu_add/run.sh
```

## Gotchas specific to this path

The IRON path has its own traps, separate from the iree-amd-aie build. The short
list (full detail in [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie track*):

1. **Python 3.14 here, not 3.12.** The only way to use Ubuntu's packaged `pyxrt`
   is a 3.14 venv; a 3.12 venv can't import it.
2. **Expose `pyxrt` by symlink** into the venv `site-packages` (clean venv, not
   `--system-site-packages`).
3. ⚠️ **Source `env_setup.sh` without a pipe.** `source env_setup.sh A B | tail`
   runs it in a subshell and the `export`s vanish → empty `PEANO_INSTALL_DIR` →
   system `/bin/clang++` → `error: unknown target triple 'aie2-none-unknown-elf'`.
   (`scripts/mlir-aie-env.sh` handles this for you.)
4. **Prefer `make run_py` over `make run`.** `run_py` is pure `pyxrt`; `run` builds
   a C++ host that needs `libxrt-dev`.
5. **Reuse the Peano** from `iree-amd-aie` instead of re-downloading `llvm-aie`.
6. **Full-network designs want > 4 columns** — they fail `CREATE_HWCTX` on Phoenix.

## Relationship to the rest of the repo

This is an *additional* path, not a replacement. For "run my model on the NPU",
the `iree-amd-aie` flow (`scripts/build.sh` + `scripts/run-matmul.sh` + the
`npu-trim` / `npu-runner` tools) is still the answer. Reach for `mlir-aie` when you
want to **write a specific kernel** or run the upstream **ML example blocks**
directly.
