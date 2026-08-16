**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — what changes, what transfers

This repo's XDNA1 hardware evidence comes from a Phoenix / Ryzen 7 PRO 7840U.
Hawk Point shares the mapped `RyzenAI-npu1` identity, but has no separate
hardware result here yet. For this documented XDNA1 path, from-source
`iree-amd-aie` is the compute route used under Linux. This page is the honest
**XDNA2** (Strix Point / Strix Halo / Krackan) delta:
what of this repo's recipes and tools carries over, what the second generation
changes, and where the open frontier now sits.

The purpose is the same on every generation: turn an NPU already inside a
personal machine into inspectable, reusable Linux infrastructure. Read the
[Open NPU Lab](OPEN-NPU-LAB.md) for that mission and [Research branches](RESEARCH.md)
for primary sources that lead beyond this page.

Two kinds of claims below, clearly separated:

- **✅ Verified** — reproduced on a real XDNA2 machine:
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · kernel 7.0
  · in-tree `amdxdna` · NPU FW 1.1.2.64**.
- **🔎 Researched** — sourced from upstream repos/docs/benchmarks (August 2026),
  linked inline, not yet reproduced here.

This repository has not measured system energy on its Strix machine. Every
energy figure below is explicitly attributed upstream; it is not repo evidence.

> **Executable support in this release is narrower than the family overview:**
> only Strix Point `RyzenAI-npu4` / IREE `npu4` is hardware-verified and mapped
> automatically. Strix Halo `npu5` and Krackan `npu6` are context only;
> `scripts/detect-npu.sh` rejects them until a contributor supplies a verified
> target and CPU-reference result. See [SUPPORT.md](SUPPORT.md).

## TL;DR

| | XDNA1 (this repo's home turf) | XDNA2 |
|---|---|---|
| Turnkey LLM on Linux | No server is shipped by this repo; open lower-level IREE/IRON research paths remain | ✅ FastFlowLM + Lemonade |
| XRT userspace | build/install per this repo | ✅ **shipped natively by Ubuntu 26.04** (`libxrt-npu2`) |
| Custom kernels (open path) | repo-pinned `iree-amd-aie` plus `mlir-aie`; moving `amd/IRON` is a separate upstream path | the same public foundations, with Strix as a first-class `npu2`/`npu4` target |
| Where contribution lives | reproducing and composing useful Phoenix blocks | open, quantized, fused kernels and application integration |

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
   even a re-login never restarts that service. `enable-npu.sh` now writes a
   UID-specific `user@<uid>.service.d` drop-in, disables only the exact legacy
   wildcard drop-in it previously managed, and `prlimit`s the invoking shell —
   the full anatomy is [GOTCHAS #0](GOTCHAS.md).
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
on XDNA2/Ubuntu 26.04 is configuration, not compilation.

## ✅ Compute: verified on the XDNA2 NPU (same machine, 2026-08-15)

**Live-hardware recording:** IREE `npu4` exact CPU-reference checks, all-output
`npu-runner` verification, and the 8-column IRON kernel through XRT and HRX:

![Live XDNA2 Strix Point compute verification on IREE, npu-runner, XRT, and HRX](media/xdna2-compute.gif)

The repo-pinned direct-kernel track ran the same day activation landed — `setup-mlir-aie.sh`
unchanged, mlir-aie **1.4.1** (cp314 wheel), Peano wheel, Ubuntu's `pyxrt`.
Full tables in [MLIR-AIE.md](MLIR-AIE.md); headlines:

- **GEMM on all 8 columns / 32 tiles** (`whole_array`, 2048³): **6.65 TOPS**
  i8 and **4.64 TFLOPS** bf16-via-bfp16 — inner-tile size alone was worth
  3.4× (32³ → 64³ tiles).
- **AIE2P wants bfp16**: bf16 MAC is ~¼-rate *emulation* on XDNA2 (native on
  XDNA1); `--emulate-bf16-mmul-with-bfp16 1` is free speed. The native
  bfp16ebs8 designs compile with Peano here; running them needs `libxrt-dev`
  (C++ hosts).
- **`ml/mobilenet` — the design that fails `CREATE_HWCTX` on Phoenix's 4
  columns — runs end-to-end** on the 8-column array: ~176 ms/inference.
- In the repo-pinned **mlir-aie 1.4.1** track, individual `npu2` examples for
  softmax, RoPE, SwiGLU, RMSNorm, and matmul+activation epilogues passed. This
  is repo-owned Strix evidence for those examples, not a whole-model result and
  not the separate moving `amd/IRON` operator dashboard.
- Our custom `relu(a+b)` kernel ported to the mlir-aie 1.4.1 IRON API scales
  **8.0× on 8 columns** (`transform_parallel_binary`), 11.2 GB/s effective.
- **W4A16 quantized GEMM (2026-08-16)**: the TileFuse int4-AWQ fused
  dequant+GEMM kernel runs in a repo-owned IRON whole-array design, Peano
  only — CPU-reference PASS at 512³/2048³ and **5.94 TOPS** at 2048³
  (+28% over the bf16 baseline); see
  [`examples/mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/).

### ✅ IREE: CPU-reference correctness on `npu4` (separate track)

The upstream IREE CPU-vs-NPU harness was also run on this hardware with
`--target_device=npu4`, 4 core rows, 8 core columns, and Peano 22 commit
`4a1adefa`:

| IREE matmul | Values compared | CPU vs NPU result |
|---|---:|---|
| bf16→f32, 64³ | 4,096 | exact match; max absolute/relative error 0 |
| bf16→f32, 512³ | 262,144 | exact match; max absolute/relative error 0 |
| i8→i32, 512³ | 262,144 | 0 mismatches |

These are `iree-amd-aie` bf16/i8 correctness results, not the native
`mlir-aie` bfp16ebs8 path. That separate Peano 21 accumulation sweep passed at
K=1216 and first failed at K=1280; nothing in this IREE table changes that
boundary. These correctness runs are also **not performance measurements**.

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
  **XDNA2-only** — XDNA1 stays excluded from that product. This repo therefore
  keeps its from-source compiler route, while the separate moving AMD IRON
  library provides another open Phoenix research surface. FLM v1.0.0 moved into AMD's
  [ROCm GitHub org](https://github.com/ROCm/FastFlowLM) (2026-08).
  **Lemonade** wraps it as an OpenAI-compatible server
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
| `scripts/enable-npu.sh` | ✅ works (extended in this commit) | same 3 blockers; Ubuntu 26.04 pre-installs the packages — but on a systemd desktop the memlock fix needs a UID-specific `user@<uid>.service.d` drop-in on top of limits.d; the script disables only its exact legacy wildcard file ([gotcha #0](GOTCHAS.md)) |
| `scripts/build.sh` (iree-amd-aie) | ✅ hardware-verified | source build + install completed on Strix; bounded parallelism avoids the observed OOM, and the final check requires both `npu1_4col` and `npu4`; tested with Peano 22 `4a1adefa` |
| `scripts/run-matmul.sh` | ✅ hardware-verified | detects the 4×8 grid and selects `npu4`; i32 128³ and bf16 512³ compile and execute correctly while retaining the XDNA1 path |
| `tools/npu-runner` | ✅ hardware-verified | C API grid auto-discovery resolves 4×8; both the native runner and ctypes/Python path verified all 16,384 i32 output values |
| [`examples/local-rag-sidecar`](../examples/local-rag-sidecar/) | ✅ hardware-verified integration on `npu4` | CPU deterministic hashing → persistent NPU bf16 scoring → CPU top-k, with all 65,536 outputs checked. It is an integration reference, not a trained retriever; one small query is likely faster on CPU. |
| `tools/npu-trim` | ✅ concept intact | `build.sh` installs the separately pinned `iree-import-onnx`; the tool extracts and test-compiles independent matmul/conv shapes. It does not rebuild a whole model: the app owns weights, layouts, unsupported glue, fallback, and orchestration. |
| Repo-pinned `mlir-aie` track | ✅ **hardware-verified on Strix** | [`mlir-aie` 1.4.1](https://github.com/Xilinx/mlir-aie/releases) treats Strix as `npu2`, uses Peano by default, and provides the direct-kernel track measured in [MLIR-AIE.md](MLIR-AIE.md). The optional HRX Python backend needs an external `libhrx`; repo artifacts still used the existing XRT toolchain, so this is not a fully XRT-free claim. |
| Moving `amd/IRON` operator library | 🔎 **separate upstream hardware evidence** | At exact `cdc48e93`, the 2026-08-15 Phoenix workflow's default five iterations report **2,105 passing / 45 skipped case-runs**, representing **421 distinct passing configurations / 9 distinct skips**.[^iron-phoenix] Do not merge that moving source tree or its Phoenix CI into the repo-pinned 1.4.1 Strix result. |

## 🔎 Hardware delta that matters when you write kernels

- **Geometry**: npu1 is a 4-column array; Strix Point (`npu4`) is **4 rows × 8
  columns — 32 compute tiles + 8 memory tiles**, partitionable at column
  boundaries, with firmware-managed context scheduling
  ([kernel docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **Datatype**: AIE2P's headline is **bfp16 block floating point** — 8 values
  share an 8-bit exponent, 9 bytes per 8 values. As of Peano's current
  nightlies this is real under the open stack: clang ships the
  `__builtin_aie2p_*bfp16ebs8/16` conversion and `BFP576_BFP576_ACC2048`
  MAC builtins, and the `ml/block_datatypes` GEMMs build with Peano (✅
  compiled on this machine). The flip side: **bf16 MAC regressed** — native
  4×8×4 on AIE2, ~¼-rate emulation through the bfp16 datapath on AIE2P
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390),
  [Hello XDNA](https://tnzr.org/xdna/isa.html)). Kernels tuned for bf16 on
  npu1 need a bfp16 rewrite for peak npu2 throughput; kernel C++ is
  arch-gated by `__AIEARCH__` (20 = AIE2, 21 = AIE2P) and upstream keeps
  parallel `aie_kernels/aie2/` and `aie2p/` trees.
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

### Research bridge across generations

Open work already reaches beyond the repo-pinned examples, but the baselines
must stay separate. Rösti and Franz's Phoenix experiment offloads GEMMs from
GPT-2 124M fine-tuning to a first-generation NPU and reports the authors'
hybrid throughput and energy figures.[^phoenix-gpt2] STEEL reports an average
**9.6× XDNA1 latency speedup versus DATO**; its CPU/GPU energy figures are from
a separate HX 370/**XDNA2** experiment, not that XDNA1 port.[^steel] These are
published results to reproduce and extend, not benchmarks owned by this repo.

## Where this goes next

1. ~~Reproduce direct `mlir-aie` GEMM on the 4×8 array~~ — **✅ done** with the
   repo-pinned mlir-aie 1.4.1
   whole-array GEMM at 6.65 TOPS i8 / 4.64 TFLOPS bf16-bfp16, LLM blocks,
   full MobileNet; see [MLIR-AIE.md](MLIR-AIE.md). Separately, exact
   `amd/IRON` commit `cdc48e93` has a Phoenix hardware workflow whose default
   five iterations produce **2,105 passing / 45 skipped case-runs**, representing
   **421 distinct passing configurations / 9 distinct skips**. Passing cases include bf16 GEMM/GEMV, Q4NX dequant,
   softmax, RoPE, RMSNorm, LayerNorm, activations, transpose, and SwiGLU
   decode/prefill. The distinct skips are exactly MHA 3,
   streaming-SwiGLU-prefill 3, and GEMV+GELU 3; each repeats five times to
   produce three 15-case-run groups. Its MHA/GQA dashboard is
   **AIE2P-only**.[^iron-phoenix]
   That broadens the experiments worth bringing back to XDNA1; it is not this
   repo's current-pin Phoenix rerun or a full LLM.
2. ~~Port the iree-amd-aie matmul recipes + `npu-runner` to `npu4` and close
   CPU-reference correctness~~ — **✅ done**. The build, generation-aware matmul
   script, persistent C API runner, and Python wrapper all ran on this Strix
   machine; the upstream harness produced the exact-match table above. A
   controlled XDNA1-vs-XDNA2 performance comparison remains separate work; no
   speed claim is derived from these correctness runs.
3. **Quantized prefill GEMM** — the contribution surface, now precisely
   mapped. **TileFuse is external XDNA2 research**, not a repository runtime
   result: its paper publishes a W4A16 recipe and external code
   ([glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
   fork ~13 months behind main, **chess-first** with Peano optional; AWQ
   group-128, k-tile = group size, dequant fused in-tile with an L1
   weight-stationary cache, 9 TOPS on Strix Point). In the sources cited and
   audited on **2026-08-15**, we did not identify a public port of that TileFuse
   kernel to **repo-pinned mlir-aie 1.4.1 + Peano-only**, or a public llama.cpp
   TileFuse integration. That is a dated search result, **not proof of absence**.
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725)
   is still open and unclaimed (the author's WIP stalled 2026-04; AMD's own
   active effort is [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend)
   on the HSA/ROCr runtime — a different stack from Ubuntu's XRT).
   **64 KiB buffer alignment remains a benchmark hypothesis worth testing.**
   The linked llama.cpp #21725 does not provide a supporting primary experiment
   or raw log; this repository therefore makes **no 10× decode claim**.
   **Repo status — ✅ hardware-verified (2026-08-16):** the TileFuse fused
   dequant+GEMM kernel (`mix_int4_ATB.cc`, vendored byte-identical from the
   pinned fork commit) now **runs on this Strix machine** inside a repo-owned
   IRON 1.4.x whole-array design with Peano only —
   [`examples/mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/):
   host-side AWQ-g128 packing (4352 B/tile), in-core dequant into a 16 KB
   weight-stationary L1 cache, CPU-reference **PASS** at 512³ and 2048³
   (max error ≈ 9·10⁻³ of the accumulation scale), **5.94 TOPS** at 2048³ on
   8 columns (+28% over the repo's 4.64 TFLOPS bf16 baseline, ~66% of
   TileFuse's chess-compiled 9 TOPS) and 6.24 TOPS at 2048×4096×4096. The
   pinned [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) still
   records the external source commit, checksums, and front-end flags; the
   example README documents the three new gotchas (M12–M14). Energy remains
   unmeasured, and a llama.cpp integration remains open.

*Status: page added 2026-08-15; activation, direct-kernel compute, and the IREE `npu4`
port with CPU-reference correctness were verified the same day on the Strix
Point machine above. The 🔎 items carry their sources inline.*

[^iron-phoenix]: AMD, [`IRON` at `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) and [Phoenix extensive hardware workflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15. Under the workflow's default five iterations, 2,105 passing and 45 skipped case-runs represent 421 distinct passing configurations and 9 distinct skips. Upstream evidence, not a repo exact-v1 XDNA1 run.
[^phoenix-gpt2]: A. Rösti and M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025. First-generation Phoenix, hybrid GPT-2 124M fine-tuning; not reproduced here.
[^steel]: V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. Keep its XDNA1 latency and XDNA2 energy experiments separate.
