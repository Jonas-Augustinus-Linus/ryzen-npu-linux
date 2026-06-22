**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Background: XDNA1, XDNA2, and why Linux is hard for first-gen

## The chip

AMD's Ryzen AI NPU is an **AI Engine (AIE)** spatial array inherited from Xilinx —
a grid of VLIW vector tiles connected by streaming/DMA interconnect, plus memory
and "shim" rows that bridge to the host. You program it by placing compute on
tiles and routing data between them (dataflow), not with a CUDA-style kernel.

Two generations matter here:

| | **XDNA1** ("Phoenix"/"Hawk Point") | **XDNA2** ("Strix" etc.) |
|---|---|---|
| Found in | Ryzen 7040 / 8040 (e.g. **7840U**) | Ryzen AI 300 series |
| Tile arch | AIE2 (`aie2`) | AIE2P |
| Phoenix geometry | 4 core rows × **4 usable cols** (5 raw), `npu1_4col` | larger, `npu4` |
| PCI ID | `1022:1502` | `1022:17f0` |
| ~Perf | ~10 TOPS | ~50 TOPS |

## The Linux software situation (mid-2026)

The **kernel** side is solved: the `amdxdna` DRM accel driver was upstreamed in
**Linux 6.14** (firmware too). On a modern kernel the NPU enumerates as
`/dev/accel/accel0` and `xrt-smi` sees it — for **both** generations.

The **userspace / compiler** side is where XDNA1 falls off:

- **AMD Ryzen AI Software for Linux** (1.7.x) — supports **STX/KRK (XDNA2) only**.
- **ONNX Runtime + Vitis AI EP** — on Linux x86_64 the client-NPU graph compiler
  isn't shipped; ops fall back to CPU.
- **Lemonade / FastFlowLM** (the "NPU LLMs on Linux" projects) — **XDNA2 only**;
  they state outright that 7000/8000-series XDNA1 is unsupported.

So XDNA1 on Linux is **driver-visible but application-orphaned** by the turnkey
stacks. The exception — the one actively-developed open path that *explicitly*
targets XDNA1 (`npu1`, 4×5) — is **`nod-ai/iree-amd-aie`**, an IREE plugin. It's
research-grade (kernels, not arbitrary models), but it genuinely runs on the
hardware. That's what this repo builds.

## How the `amdxdna` HAL reaches the device

`iree-amd-aie` compiles your matmul to:

1. **AIE core code** — Peano (`llvm-aie`, a fork of LLVM with an `aie2` target)
   compiles per-tile programs (`core_<col>_<row>.elf`).
2. **Configuration / control** — object-FIFO or AIR dataflow lowering, packet
   routing, and a control program, packed (via `bootgen`) into the `.vmfb`.

At run time the **`amdxdna` HAL** (built into the runtime with
`-DIREE_EXTERNAL_HAL_DRIVERS=amdxdna`) **opens `/dev/accel/accel0` directly** and
issues DRM ioctls (`DRM_IOCTL_AMDXDNA_GET_INFO`, command submission, fence wait)
using a vendored UAPI header. It does **not** link the external XRT `xrt_coreutil`
library — that's the separate, experimental `xrt` HAL. This is why you do **not**
need to build AMD's out-of-tree `xdna-driver` when the in-tree `amdxdna.ko` is present.

The device reports its geometry through the same ioctl; `npu1_4col` and
`--amdxdna_n_core_cols=4` must agree with it (see [GOTCHAS #6](GOTCHAS.md)).

## References

- AMD `xdna-driver` & kernel `amdxdna` docs (kernel.org `accel/amdxdna`)
- `nod-ai/iree-amd-aie` (README, `build_tools/ci/`)
- `Xilinx/llvm-aie` (Peano)
- IREE (`iree.dev`)
