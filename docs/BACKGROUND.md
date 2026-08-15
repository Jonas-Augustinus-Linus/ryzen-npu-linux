**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Background: XDNA1, XDNA2, and the open Linux routes

## The silicon did not become useless when the turnkey stack moved on

AMD's Ryzen AI NPU is an **AI Engine (AIE)** spatial array inherited from
Xilinx: VLIW vector tiles connected by streaming/DMA interconnect, with memory
and shim rows linking the array to the host. Programs place computation on
tiles and route data between them rather than treating the device as a
CUDA-style general-purpose GPU.[^iron-guide]

| | **XDNA1** (Phoenix/Hawk Point) | **XDNA2** (Strix and related devices) |
|---|---|---|
| Found in | Ryzen 7040/8040, including the **7840U** | Ryzen AI 300 family |
| Tile architecture | AIE2 (`aie2`) | AIE2P |
| Repository target | Phoenix: 4 usable columns, `npu1_4col` | verified Strix: `npu4` |
| Nominal NPU performance | up to 10 TOPS for the 7840U[^amd-7840u] | up to 50 TOPS for Ryzen AI 300[^amd-platform-guide] |

The 7840U specification still describes a Ryzen AI engine with up to 10 TOPS.
That capability does not disappear because current application software stops
listing Phoenix.[^amd-7840u]

## The Linux situation on 2026-08-15

The kernel foundation is shared. AMD's open `amdxdna` driver exposes supported
devices through the Linux accelerator interface, and AMD publishes the driver,
XRT shim, firmware requirements, and installation guidance.[^amdxdna]

The convenient product layer is generation-specific. AMD Ryzen AI Software 1.8
for Linux lists **STX and KRK**, not Phoenix/XDNA1.[^ryzenai-linux]
That is a statement about today's turnkey support matrix—not a finding that
XDNA1 cannot compute on Linux.

For XDNA1 experimenters there are now **two open, lower-level routes**:

1. **The route packaged by this repository:** the exact-lock
   [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) stack. It
   lowers IREE programs, packages device-specific VMFB modules, and invokes them
   through the `amdxdna` HAL. The scripts here pin, build, detect, run, and check
   every output against CPU references. The published Phoenix measurements are
   historical results from the then-current nightly; the current v1 exact lock
   has been revalidated on Strix and still awaits a Phoenix rerun.
2. **The direct-kernel route:**
   [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) with Peano and XRT.
   This repository pins its IRON Python API/compiler stack at 1.4.1; developers
   author spatial AIE kernels and data movement directly. The newer
   [`amd/IRON`](https://github.com/amd/IRON) operator/application library is a
   separate project built on MLIR-AIE language bindings—not a rename or new
   location of `Xilinx/mlir-aie`. Its upstream results are research leads to
   reproduce, not guarantees inherited by this release pin.

At AMD IRON commit
[`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93), the official Phoenix
workflow recorded **2,105 passing and 45 skipped pytest case-runs**.[^iron-phoenix-ci]
These are not distinct tests: the default five iterations
mean **421 distinct passing configurations and 9 distinct skipped
configurations**. The nine skips are three MHA, three streaming-SwiGLU, and
three GEMV+GELU configurations, each repeated five times. The AIE2/Phoenix
hardware run includes passing CPU-referenced GEMM/GEMV, Q4NX
dequantization, softmax, RoPE, RMSNorm/LayerNorm, activations, and transpose.
This is strong upstream evidence that XDNA1 is a useful ML-kernel laboratory.
It is **not** a rerun of this repository's exact v1 stack, and it is not an
end-to-end XDNA1 LLM claim. MHA and streaming-SwiGLU are among the exact skips,
and GQA is not established by this Phoenix run; the boundary must travel with
the result.

## How the repository's `amdxdna` HAL route reaches the device

`iree-amd-aie` compiles a supported operation into:

1. **AIE core programs.** Peano (`llvm-aie`) compiles per-tile code for the
   applicable AIE architecture.
2. **Configuration and control.** Dataflow lowering, routing, DMA/control code,
   and the device programs are packaged into a `.vmfb`.
3. **Host invocation.** The IREE `amdxdna` HAL opens `/dev/accel/accel0`, submits
   commands through the kernel UAPI, and waits on fences. This differs from the
   separate XRT/`pyxrt` host path used by IRON examples.

The device geometry is part of correctness. On the verified Phoenix mapping,
`npu1_4col` and `--amdxdna_n_core_cols=4` must agree; this repository refuses to
guess a target for a later unknown device. See [GOTCHAS #6](GOTCHAS.md) and the
[support matrix](SUPPORT.md).

## Why both routes matter

The IREE route makes repeatable application integration and a persistent C/
Python runtime practical. The IRON route exposes tiles, FIFOs, kernels, and the
moving operator frontier. Together they let ordinary laptop owners start with
a CPU-checked matmul, compose a hybrid local-AI application, and then move one
compiler or operator boundary at a time.

Use the [Open NPU Lab](OPEN-NPU-LAB.md) as the project map, the
[research ledger](RESEARCH.md) for primary sources and claim scopes, and the
[LLM roadmap](LLM-ROADMAP.md) for unfinished work.

[^amd-7840u]: AMD, [Ryzen 7 7840U specifications](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html).
[^amd-platform-guide]: AMD, [Ryzen and Radeon consumer pocket guide](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/amd-consumer-pocket-guide-ryzen-radeon-july-2024.pdf), July 2024.
[^amdxdna]: AMD, [`xdna-driver`: Linux driver and XRT interface for AMD NPUs](https://github.com/amd/xdna-driver).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 — Linux system requirements and supported platforms](https://ryzenai.docs.amd.com/en/latest/linux.html), accessed 2026-08-15.
[^iron-guide]: AMD IRON, [Programming guide](https://github.com/amd/IRON/blob/main/programming_guide/README.md).
[^iron-phoenix-ci]: AMD IRON, [official Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
