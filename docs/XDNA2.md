**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — what changes, what transfers

This repo is the verified map for **XDNA1** (Phoenix/Hawk Point), where from-source
`iree-amd-aie` is still the *only* way to run compute on the NPU under Linux.
This page is the honest **XDNA2** (Strix Point / Strix Halo / Krackan) delta:
what of this repo's recipes and tools carries over, what the second generation
changes, and where the open frontier now sits.

Two kinds of claims below, clearly separated:

- **✅ Verified** — reproduced on a real XDNA2 machine:
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · kernel 7.0
  · in-tree `amdxdna` · NPU FW 1.1.2.64**.
- **🔎 Researched** — sourced from upstream repos/docs/benchmarks (August 2026),
  linked inline, not yet reproduced here.

## TL;DR

| | XDNA1 (this repo's home turf) | XDNA2 |
|---|---|---|
| Turnkey LLM on Linux | ❌ none — excluded by every shipped stack | ✅ FastFlowLM + Lemonade 10.0 (since 2026-03) |
| XRT userspace | build/install per this repo | ✅ **shipped natively by Ubuntu 26.04** (`libxrt-npu2`) |
| Custom kernels (open path) | `iree-amd-aie` / `mlir-aie` from source | same stack, better supported: IRON 1.4.x treats Strix as first-class |
| Where contribution lives | making *anything* run | closing the open-kernel gap (the turnkey NPU kernels are proprietary) |

Everything this repo teaches — XRT plumbing, memlock/render-group activation,
dispatch overhead, Peano, IRON kernel authoring — **transfers**. What changes is
target names, array geometry, and the fact that "run an LLM on the NPU" is no
longer the frontier on XDNA2; **open, quantized, tuned kernels are**.

## ✅ Verified: a Strix Point machine today, using this repo's own tools

Running unmodified `scripts/check-npu.sh` on the XDNA2 box surfaced three
script bugs (all fixed in this commit — see below) and this true state:

```
[1] amdxdna module loaded                       ✓
[2] 1022:17f0 Strix/Krackan/Strix Halo NPU      ✓  (XDNA2)
[3] /dev/accel/accel0 root:render 0660, RW      ✓
[4] user in 'render' group                      ✓
[5] memlock = 8192 KB                            ✗  ← the same old blocker
[6] xrt-smi present (2.21.75) but:               ✗
    mmap(len=64MB, MAP_LOCKED) failed (err=-11)
[7] pyxrt present, cannot open device            ✗  (same cause)
```

Three findings worth writing home about:

1. **Ubuntu 26.04 ships the XDNA2 XRT userspace natively.** `libxrt2`,
   `libxrt-npu2`, `libxrt-utils-npu`, `python3-xrt` (2.21.75) install straight
   from the archive — on XDNA1 the same packages exist but no shipped runtime
   executes models; on XDNA2 this is a working runtime path.
2. **The activation blockers are byte-for-byte identical to XDNA1** — the 8 MB
   memlock default breaks xrt-smi's 64 MB `mmap(MAP_LOCKED)` with `EAGAIN`,
   exactly the failure `scripts/enable-npu.sh` was written for — **but the old
   fix silently does not apply on a systemd desktop.** limits.d is a
   `pam_limits` mechanism; a GUI terminal is a child of `user@<uid>.service`
   and inherits *its* 8 MB `LimitMEMLOCK` instead, and with lingering enabled
   even a re-login never restarts that service. `enable-npu.sh` now also
   writes a `user@.service` drop-in and `prlimit`s the invoking shell — the
   full anatomy is [GOTCHAS #0](GOTCHAS.md).
3. **Firmware is current out of the box**: FW 1.1.2.64 loaded from
   `amdnpu/17f0_10/` — above the ≥ 1.1.0.0 floor that FastFlowLM requires.

### ✅ End state: the XDNA2 NPU enumerates (same machine, same day)

After the memlock fix landed for real (drop-in + `prlimit`, gotcha #0), all
seven checks go green and the userspace stack opens the device:

```
$ xrt-smi examine
XRT
  Version              : 2.21.75
  amdxdna Version      : 7.0.0-29-generic
  NPU Firmware Version : 1.1.2.64
Device(s) Present
|BDF             |Name          |
|[0000:66:00.1]  |RyzenAI-npu4  |

$ python3 -c 'import pyxrt; d = pyxrt.device(0); \
    print(d.get_info(pyxrt.xrt_info_device.name))'
RyzenAI-npu4
```

`RyzenAI-npu4` confirms the naming-decoder row below on real hardware: Strix
Point is `npu4` to XRT. No source build was needed to get *here* — activation
on XDNA2/Ubuntu 26.04 is configuration, not compilation. Compute is the next
step (see *Where this goes next*).

### Script bugs found by pointing the XDNA1 tools at XDNA2 (fixed)

- `check-npu.sh [1]` used `lsmod | grep -q` under `pipefail`: `grep -q` exits on
  first match, `lsmod` dies of SIGPIPE (exit 141), the pipeline "fails" — a racy
  false negative that only fires when the module sits early in `lsmod` output
  (it does on a freshly booted Strix machine). Now checks `/sys/module/amdxdna`.
- `check-npu.sh [2]` matched `IPU|AI`, the XDNA1 lspci string. XDNA2 enumerates
  as `Neural Processing Unit` (device `17f0`). The check now matches both and
  reports which generation it found.
- `check-npu.sh [6]` had the *same* SIGPIPE race as [1] — `xrt-smi examine |
  grep -q` under `pipefail` — but this one only arms **once the NPU actually
  enumerates** (the matched lines sit early in a successful report, so `grep
  -q` bails while `xrt-smi` is still writing). The check reported the first
  ever successful enumeration as a failure while `pyxrt` in [7] happily opened
  the device. Now captures output first, then matches.

## 🔎 The naming decoder (the #1 cross-generation confusion)

| Layer | XDNA1 | XDNA2 Strix Point | Source |
|---|---|---|---|
| lspci | `AMD IPU Device` (`1502`) | `Neural Processing Unit` (`17f0`) | ✅ both machines |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4` (Halo=`npu5`, Krackan=`npu6`) | ✅ this machine reports `RyzenAI-npu4` · [xdna-driver](https://github.com/amd/xdna-driver) |
| mlir-aie / IRON | `npu1` | `npu2` | [mlir-aie](https://xilinx.github.io/mlir-aie/) |
| iree-amd-aie | `npu1_4col` | `npu4` | [iree-amd-aie](https://github.com/nod-ai/iree-amd-aie) |
| ISA | AIE2 | AIE2P | [Peano](https://github.com/Xilinx/llvm-aie) |

## 🔎 The landscape flip: turnkey exists on XDNA2 — with a catch

- **FastFlowLM** shipped native Linux support in v0.9.35 (2026-03-11),
  **XDNA2-only** — XDNA1 stays excluded, which is why this repo's from-source
  path remains the only XDNA1 route. FLM v1.0.0 moved into AMD's
  [ROCm GitHub org](https://github.com/ROCm/FastFlowLM) (2026-08).
  **Lemonade 10.0** wraps it as an OpenAI-compatible server
  ([Linux guide](https://lemonade-server.ai/flm_npu_linux.html)).
- **The catch:** FLM's CLI is MIT, but its **NPU kernels are proprietary
  free-to-use binaries**. It is a product to use, not a codebase to learn
  kernel authoring from. The open-kernel path — this repo's territory — is
  where XDNA2 contribution now lives.
- **Still missing on Linux**, generation regardless: ONNX Runtime's Vitis AI EP
  ([docs](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html))
  — so `npu-trim`'s screen-the-graph approach keeps its niche on XDNA2 too.
  GAIA on Linux drives the iGPU only
  ([amd/gaia#1220](https://github.com/amd/gaia/issues/1220) asks for the NPU route).

## Asset-by-asset: what of this repo ports to XDNA2

| Asset | XDNA2 status | What changes |
|---|---|---|
| `scripts/check-npu.sh` | ✅ works (this commit) | XDNA2 PCI string + generation report; [6] success-side SIGPIPE fix; [5] now diagnoses the pam-vs-systemd memlock split |
| `scripts/enable-npu.sh` | ✅ works (extended in this commit) | same 3 blockers; Ubuntu 26.04 pre-installs the packages — but on a systemd desktop the memlock fix needs a `user@.service` drop-in on top of limits.d ([gotcha #0](GOTCHAS.md)) |
| `scripts/build.sh` (iree-amd-aie) | 🔎 should port | `npu4` is a supported target; project active (softmax ukernel for Peano npu4, ERT_CMD_CHAIN batching). The commit-lockstep gotcha (pinned xdna-driver) remains |
| `scripts/run-matmul.sh` | 🔎 should port | target `npu1_4col` → `npu4`; the `amdxdna` HAL flags stay |
| `tools/npu-runner` | 🔎 should port | IREE C API unchanged — recompile against the npu4 build |
| `tools/npu-trim` | ✅ concept intact | op-coverage frontier moves, approach identical; still no vendor EP on Linux to replace it |
| `mlir-aie` (IRON) track | 🔎 **strongest path** | IRON [1.4.x](https://github.com/Xilinx/mlir-aie/releases): Strix first-class (`npu2`), **Peano is now the default backend** (we built it anyway), **HRX** = XRT-free host runtime option; [amd/IRON](https://github.com/amd/IRON) ships a prebuilt op library (GEMM, GEMV, MHA, GQA, RMSNorm, RoPE, softmax, dequant) as pip wheels |

## 🔎 Hardware delta that matters when you write kernels

- **Geometry**: npu1 is a 4-column array; Strix Point (`npu4`) is **4 rows × 8
  columns — 32 compute tiles + 8 memory tiles**, partitionable at column
  boundaries, with firmware-managed context scheduling
  ([kernel docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **Datatype**: AIE2P's headline is **bfp16 block floating point** — 8 values
  share an 8-bit exponent, 9 bytes per 8 values. Support is gated by ~450+
  hard-coded `__AIE_ARCH__` conditions in mlir-aie rather than feature flags —
  both a porting hazard and a named contribution surface
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390)).
- **ISA**: still no official manual, but effectively open — Peano implements it
  in public LLVM, and [Hello XDNA](https://tnzr.org/xdna/isa.html) reconstructs
  the XDNA1/XDNA2 ISA with per-instruction latencies.

## 🔎 Measured reality: LLMs on the XDNA2 NPU (why kernels are the frontier)

- FLM on a 50-TOPS XDNA2: Llama 3.1 8B **prefill 403 t/s** @1k ctx, decode
  12.8 t/s; gpt-oss-20b decode 18.2 @1k → 12.0 @32k
  ([FLM benchmarks](https://fastflowlm.com/docs/benchmarks/llama3_results/)).
- Same-silicon comparison: NPU wins **prefill ~1.5×** over iGPU Vulkan, loses
  decode ~25%, at up to ~10× better energy efficiency. Decode is
  memory-bandwidth physics (~120 GB/s LPDDR5X shared by CPU/iGPU/NPU) — no
  engine escapes it.
- Calibration point for open code: a naive open XRT-dispatch llama.cpp fork
  ([OllamaAMDNPU](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU),
  Strix Halo) reaches prefill 18.4 t/s, decode 1.4 t/s — the gap to FLM's
  300–400 t/s prefill is **kernel/dataflow design, not dispatch plumbing**.
- The architecture that makes sense: **NPU-prefill + iGPU-decode hybrid** —
  exactly how AMD's own Windows stack splits the work.

## Where this goes next

1. **Port the matmul recipes + `npu-runner` to `npu4`** and publish XDNA1 vs
   XDNA2 numbers side by side (same tables as the README).
2. **Reproduce IRON GEMM/GQA on the 4×8 array** (mlir-aie 1.4.x; try HRX to
   drop the XRT dependency).
3. **Quantized prefill GEMM** — W4A16 (and bfp16-exploiting) kernels via the
   IRON flow; [TileFuse](https://arxiv.org/abs/2606.11357) published the
   recipe (up to +281% GEMV vs full-precision NPU baselines). The
   [amd/IRON](https://github.com/amd/IRON) library has dequant but **no
   Q4/MXFP4 GEMM** — that gap is real, and llama.cpp has an open, unclaimed
   ggml-xdna backend request
   ([#21725](https://github.com/ggml-org/llama.cpp/issues/21725)) as a
   maintainer-visible landing zone.

*Status: page added 2026-08-15; activation completed and verified the same day
on the Strix Point machine above — `xrt-smi` enumeration and a `pyxrt` device
open of `RyzenAI-npu4`, after fixing [gotcha #0](GOTCHAS.md). The 🔎 items
carry their sources inline.*
