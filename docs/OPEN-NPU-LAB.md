**[🇬🇧 English](OPEN-NPU-LAB.md) · [🇰🇷 한국어](OPEN-NPU-LAB.ko.md)**

# Open NPU Lab: from idle silicon to shared Linux infrastructure

This repository began on a Ryzen 7 PRO 7840U because a first-generation XDNA1
NPU was already inside an ordinary laptop, visible to Linux, yet easy to leave
unused. The first goal was simply to make that device do real, CPU-checked
work. The larger goal is to keep that work useful after one laptop, one
maintainer, and one hardware generation have moved on.

This may remain a small repository. That is all right. If it helps one owner
turn an overlooked NPU into a reproducible experiment, one student learn a
spatial accelerator without cloud hardware, or one developer publish the next
open kernel, it has done useful work.

The governing question is not “What can the newest NPU do?” It is **“How can I
use the device already in my machine—today, under Linux—and show honestly what
ran?”** The 7840U that started this project shipped with a first-generation
Ryzen AI NPU; owning that silicon is reason enough to explore it.[^amd-7840u]

> **Take it. Use it. Change it. Fork it. Redistribute it.** The original source
> and documentation in this repository are released under the [MIT License](../LICENSE).
> You do not need permission, and you do not owe this project your changes.
> Preserve the copyright and license notice as the license requires. Upstream
> projects and model assets keep their own licenses.

This is a public handoff, not a product promise. There is no requirement that
future work remain under one maintainer or even in this repository. A fork that
outlives the original is success.

## The mission

**Rescue idle silicon.** Hardware already in a PC is the most accessible
hardware. XDNA1 is not useless because newer devices exist, and an NPU does not
become useful only when it can serve an arbitrary LLM end to end. A correct
matrix kernel, an always-on classifier, a low-power sidecar, a compiler
reproducer, or a failed boundary that saves the next person a week are all
valuable outcomes.

**Protect Linux autonomy.** An owner should be able to inspect the path from
device detection to generated code, decide which processor runs each stage,
compare it with a CPU reference, and keep working when a turnkey product does
not cover the device. The upstream foundations are the open
`amdxdna` driver and XRT shim,[^amdxdna] `iree-amd-aie`,[^iree-amd-aie] and
`mlir-aie`/IRON.[^mlir-aie] This repository packages reproducible routes
through them; it does not claim to have invented them.

As of 15 August 2026, AMD's current Ryzen AI Software for Linux page names STX
and KRK as the supported platforms; it does not list Phoenix XDNA1.[^ryzenai-linux]
That documents a coverage gap in the current turnkey route, not an absence of
programmable hardware or a verdict that an older laptop has no useful work left.

**Carry the method across generations.** The project starts with Phoenix
XDNA1, verifies the same public correctness contract on Strix Point XDNA2, and
leaves later devices closed by default until evidence opens them. Future NPUs
should become laboratories, not opaque decorations.

**Make ordinary laptops legitimate AI laboratories.** The target audience is
not only compiler specialists. It includes a laptop owner willing to run a
check script, a local-LLM builder who can split a graph, and a researcher who
needs a truthful starting point. Small models, quantized blocks, hybrid
pipelines, and modest always-on jobs count.

## A useful local LLM does not require one processor to do everything

The practical architecture is heterogeneous. Give each processor the work it
can currently do well and retain a CPU fallback:

```text
microphone / camera / documents / UI events
                    │
                    ▼
       CPU: I/O, tokenization, control, fallback
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
NPU: always-on trigger,       iGPU: quantized local LLM
small dense/conv kernels,     prefill + token generation
classification or scoring          │
        └───────────┬───────────────┘
                    ▼
       CPU: tools, policy, response, verification
```

Today, this repository makes the **NPU branch** inspectable and reusable. A
local assistant can use the NPU for a trained wake-word or intent head, the
iGPU for an existing quantized LLM runtime, and the CPU for orchestration and
unsupported operators. That is a meaningful NPU application even though this
repository does **not** run an arbitrary GGUF, ONNX, or transformer model wholly
on XDNA1.

The same design scales with the ecosystem. As attention, normalization,
quantization, and runtime support improve, measured stages can move from CPU or
iGPU to NPU without rewriting the whole application. The [LLM roadmap](LLM-ROADMAP.md)
tracks that work.

One upstream signpost is AMD IRON. On 2026-08-15 its exact `cdc48e9` Phoenix
hardware workflow reported **2,105 passing and 45 skipped pytest case-runs under
the default five iterations**—421 distinct passing configurations and nine
distinct skipped configurations—exercising
CPU-referenced AIE2 GEMM/GEMV, Q4NX dequantization, Softmax, RoPE,
RMS/LayerNorm, activations, transpose, and related paths.[^iron-dashboard]
MHA/GQA and some fused SwiGLU paths were AIE2P-only or skipped. That is strong
upstream Phoenix evidence—not evidence that this repository's pinned stack or
7840U current-lock path has verified every operator. It identifies experiments
to reproduce, not features to inherit by association.

## Read every result with a truth label

These labels are deliberately narrower than “works”:

| Label | Meaning |
|---|---|
| **Current hardware-correctness** | Executed with the current exact repository lock on the named NPU and checked against an independent CPU result. |
| **Earlier hardware evidence** | Executed on real hardware with an earlier dependency snapshot; valuable evidence, but not a rerun of the current lock. |
| **Application plumbing** | Real I/O/runtime integration ran, but its demonstration model or operation may be illustrative rather than trained. |
| **Synthetic template** | The NPU dispatch is real; weights, inputs, or the task are generated to prove the pipeline rather than solve a production problem. |
| **Compile-only** | Source reached the stated compiler stage. It was not linked, executed, or numerically verified on the NPU. |
| **Project idea** | A concrete experiment, not a shipped capability. |

Compilation is not execution. Execution is not correctness. Correctness is not
performance, and a kernel benchmark is not an end-user application. Reports in
this lab keep those claims separate.

## What you can actually take from this repository

The source gallery below is both an invitation and a bill of materials.

| Source | What is real | Truth boundary |
|---|---|---|
| [`scripts/check-npu.sh`](../scripts/check-npu.sh), [`detect-npu.sh`](../scripts/detect-npu.sh), and [`verify-stack.sh`](../scripts/verify-stack.sh) | Strict identification and one repeatable detect → compute → full-output CPU-check contract. Strix Point `npu4` passes the current exact lock. | Phoenix has earlier real-hardware results, but the current exact v1 lock still needs an XDNA1 rerun. Unknown geometries fail closed. |
| [`examples/matmul_i32.mlir`](../examples/matmul_i32.mlir) and [`matmul_bf16.mlir`](../examples/matmul_bf16.mlir) | Minimal, editable kernels; i32 and bf16 paths execute on the NPU and are checked against CPU references. | Current-lock evidence is Strix Point. Published Phoenix timings came from the earlier working snapshot and are device-specific. |
| [`tools/npu-runner/`](../tools/npu-runner/) | A persistent native C runner and Python/ctypes bridge load a VMFB once and invoke it repeatedly. Full output is checked on current `npu4`; an earlier 7840U run measured about 3.7 ms per invocation versus about 41 ms for a subprocess path. | The timing is earlier XDNA1 evidence, not a universal speedup or a current-lock XDNA1 rerun. |
| [`examples/local-rag-sidecar/`](../examples/local-rag-sidecar/) | CPU chunking and deterministic hashing feed a persistent 256×256 bf16 NPU score matrix; the CPU checks all 65,536 outputs, selects top-k, and can call an optional model endpoint. The complete path is live-verified on current `npu4`. | The features are hashed bag-of-words, not trained embeddings; a small single query is likely faster on CPU. The exact-lock XDNA1 sidecar rerun is still open. |
| [`examples/onnx-mlp/`](../examples/onnx-mlp/) | A real hybrid forward pass: two extracted bf16 matmuls dispatch to the NPU, ReLU stays on the CPU, and dispatch plus end-to-end output are checked. Original XDNA1 and current `npu4` runs exist. | The model and weights are generated for the demonstration. It is not a trained application or general whole-model ONNX runtime. |
| [`examples/wake-word/`](../examples/wake-word/) | A real log-mel front end and three persistent NPU dense dispatches separate a target from noise in the self-test on the documented hardware paths. | The supplied weights are an illustrative matched filter, not a trained wake-word vocabulary. Bring trained weights and validate real audio before calling it a detector. |
| [`examples/npu-camera/`](../examples/npu-camera/) | GStreamer → persistent NPU → `v4l2loopback` plumbing ran at 30 fps in the original XDNA1 demonstration. The `npu4` processing core is correctness-tested. | The NPU operation is a two-pass 2D box blur, not AI segmentation. The complete camera loop and FPS have not been revalidated on XDNA2. |
| [`tools/npu-trim/`](../tools/npu-trim/) | Imports or screens a graph, classifies operators, extracts clean matmul/conv kernels, test-compiles them for the detected target, and rejects stale or failed artifacts. | It does not rebuild or run an arbitrary model. On current Strix, matmul is the verified route; conv coverage remains narrow and target-dependent. |
| [`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) and the [IRON guide](MLIR-AIE.md) | Directly authored spatial kernels and upstream ML examples. The current mlir-aie 1.4.1 path is hardware-verified on eight-column Strix; earlier XDNA1 examples ran with their then-current snapshot. | Current mlir-aie 1.4.x has not been rerun on XDNA1 in this repository. Do not merge the two snapshots into one claim. |
| [`examples/mlir-aie/w4a16_gemm/`](../examples/mlir-aie/w4a16_gemm/) and [`scripts/check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | The pinned compile probe grew into a hardware-verified W4A16 GEMM: int4 AWQ-g128 weights dequantized in-core, CPU-reference PASS at 512³/2048³, 5.94 TOPS on the 8-column Strix array. | Kernel-level evidence on Strix Point only: no whole-model integration, no energy measurement, and the chess-compiled 9 TOPS reference stays ahead of this Peano build. |

The original XDNA1 runner recording and current XDNA2 acceptance recording show
what the labels mean in practice:

| Earlier XDNA1 hardware evidence | Current Strix Point XDNA2 hardware-correctness |
|:---:|:---:|
| ![Original XDNA1 persistent-runner recording](media/npu-runner.gif) | ![Current XDNA2 exact CPU-check and persistent-runner recording](media/xdna2-compute.gif) |

Recordings are evidence for the displayed device, date, code, and dependency
snapshot—not proof for every machine carrying the same marketing name.

## Four ways to enter the lab

### Fifteen minutes: identify, do not guess

Read the [support matrix](SUPPORT.md), clone the repository, and run the strict
read-only check:

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux
./scripts/check-npu.sh --strict
```

Save the full output after removing usernames, serial numbers, tokens, and
other private data. A clean failure on an unrecognized device is already a
useful result. Do not force an unknown `npu5`, `npu6`, or future geometry into a
similar-looking target.

### One day: reproduce one correctness contract

Review host, disk, privilege, and reboot requirements first. Run
[`enable-npu.sh`](../scripts/enable-npu.sh) only when the check identifies a
group, memlock, or XRT problem and only after reading the script.

```bash
./scripts/build.sh
./scripts/verify-stack.sh --quick
```

If you also install the separately pinned direct-kernel stack:

```bash
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

The goal is not the fastest number. It is one result another person can repeat,
with complete CPU-reference checks and the first failure preserved.

### One week: replace one synthetic piece with a useful one

Choose one narrow stage. Train wake-word weights; replace the camera box blur
with one CPU-checked model stage; replace the supplied RAG sidecar's hashed
features with a licensed learned projection; or wrap a verified kernel in a small service. Reuse the
persistent runner, keep unsupported glue explicit on the CPU, and keep a CPU
fallback. Measure end-to-end latency and energy as well as kernel time.

### Research: move one boundary and publish it

Finish W4A16 or W8 execution; fuse a transformer block; port an attention
design; reduce transfers; characterize numerical accumulation limits; add a
future device; or make an upstream failure reproducible. A negative result with
an exact shape, compiler pin, and minimal reproducer advances the lab too.

## Practical projects worth building

| Project | First useful artifact | Status here |
|---|---|---|
| Private local assistant | NPU wake-word/intent sidecar + iGPU LLM + CPU tool loop | Architecture ready; supplied wake weights are synthetic, and no complete assistant is shipped. |
| Offline RAG helper | Batch query/document vectors, NPU matrix scoring, CPU top-k and database | A working [hashed-feature sidecar](../examples/local-rag-sidecar/) is hardware-verified on `npu4`; it is an integration reference, not a trained or performance-winning retriever. |
| Accessibility trigger | A trained sound, gesture, presence, or UI classifier that emits a standard Linux event | Project idea; reuse wake-word or camera plumbing and provide real training/evaluation data. |
| Smart virtual camera | Supported conv stage on NPU, CPU compositing, `v4l2loopback` output | Plumbing exists; current demo is box blur, while model conv coverage needs per-shape verification. |
| Private media indexer | Small CNN or projection stage produces tags/embeddings; CPU stores and searches them | Project idea; validate every model partition and retain CPU fallback. |
| Quantized block laboratory | W8/W4 matmul plus dequantization, CPU golden, error and energy sweep | W4A16 now runs hardware-verified at 5.94 TOPS ([`w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/)); the energy sweep and other bit-widths are the open milestones. |
| Cross-generation benchmark | Same source, device-specific build, full-output checks, latency/energy table | XDNA1 earlier evidence and current Strix evidence exist; same-pin XDNA1 and future-device rows are open. |
| Compiler boundary atlas | Passing and failing shapes/ops reduced to scripts and reported upstream | Already useful: known bfp16 accumulation and conv boundaries are documented; more devices are welcome. |

Do not begin by promising a whole model. Begin with the smallest artifact that
is useful, measurable, and replaceable. Then compose it.

## Evidence from published research: the ceiling is not the starting point

Published work outside this repository shows why the hybrid and open-kernel directions are
worth pursuing, while also showing why claims must remain experiment-specific.

### Phoenix XDNA1: hybrid GPT-2 fine-tuning

Rösti and Franz's 2025 paper,
*Unlocking the AMD Neural Processing Unit for ML Training on the Client Using
Bare-Metal-Programming Tools*,[^phoenix-gpt2] used a Phoenix XDNA1 NPU in a
Ryzen 9 7940HS laptop—not this repository's 7840U machine—to
offload GEMMs from a 124M-parameter GPT-2 fine-tuning workload while the rest
remained on the CPU. The paper reports over **2.8×** speedup for the offloaded
matrix multiplications, **1.7×** and **1.2×** end-to-end throughput improvement
on mains and battery respectively, and **1.4×** battery energy-efficiency
improvement.[^phoenix-gpt2]

That is evidence that first-generation Phoenix can contribute to real LLM work
through an engineered hybrid path. It is not evidence that this repository
runs GPT-2, that a 7840U will reproduce those numbers, or that the current exact
lock has been revalidated on XDNA1.

### XDNA1 portability and XDNA2 energy: STEEL

The 2026
*STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence
Inference on AMD's XDNA NPU* paper publishes its algorithm through AMD's
open-source IRON project.[^steel] Keep its two generations and baselines
separate:

- On an **XDNA1 port**, STEEL reports an average **9.6× speedup over DATO**, the
  prior XDNA1 FlashAttention work used as its baseline. This is not a CPU/GPU
  comparison.[^steel]
- On a Ryzen AI 9 HX 370 **XDNA2** system, the paper reports average energy-use
  reductions of **9.17× versus its CPU baseline** and **1.75× versus its GPU
  baseline**. It also reports **22.8×** average speedup over its layer-by-layer
  XDNA2 attention implementation.[^steel]

Those are the paper's configurations, baselines, and measurements—not this
repository's benchmark results. Together with the Phoenix fine-tuning work,
they show a continuum: incremental CPU+NPU offload can produce value on XDNA1,
while carefully fused dataflow designs can move more of a transformer onto an
NPU. They do not turn arbitrary end-to-end LLM support into a present repo
feature.

## The multi-generation onboarding rule

Marketing families are not compiler targets. A later NPU joins this lab only
through evidence:

1. **Identify it.** Record CPU model, PCI ID, VBNV, usable rows/columns,
   firmware, driver, XRT, kernel, distribution, and relevant upstream target.
2. **Keep it unsupported first.** Unknown geometry must fail closed. An expert
   override can investigate compatibility; it cannot convert a guess into a
   support claim.
3. **Compile a minimal kernel.** Label this **compile-only** and retain compiler
   logs and exact pins.
4. **Execute and prove correctness.** Compare every output element, or publish
   a justified full-tensor error metric and tolerance, against an independent
   reference. Test native and language bindings separately where applicable.
5. **Map boundaries.** Publish the first failing shape/op as well as passes.
   Never discard a failure merely because a nearby case works.
6. **Measure responsibly.** Separate warm-up, dispatch, kernel, transfer, and
   application time. Record power source, power mode, sample method, iterations,
   and CPU/iGPU baselines before making an energy claim.
7. **Promote deliberately.** Only after review should detection, documentation,
   CI expectations, and the support matrix name the device as supported.

Use the [hardware-result issue form](../.github/ISSUE_TEMPLATE/hardware-result.yml)
and the full [contribution guide](../CONTRIBUTING.md). A useful report includes a
fresh-clone command, exact source/toolchain revisions, shapes, dtypes,
quantization and padding, a golden implementation, complete output metrics,
artifact target names, and sanitized logs. “Failed at this exact point” is a
first-class result.

## Present limits, stated once and plainly

- Phoenix/7840U XDNA1 has earlier live-hardware evidence, but the **current
  exact v1 lock has not yet been rerun there**.
- Strix Point `RyzenAI-npu4` is the **current-lock XDNA2 hardware-verified**
  target in this repository.
- Strix Halo `npu5`, Krackan `npu6`, and later/unknown devices are
  **intentionally rejected**, not silently treated as Strix Point.
- The wake-word weights and ONNX MLP are synthetic templates. The camera path
  uses a box blur, not a segmentation network. They prove execution and
  integration surfaces, not production model quality.
- W4A16 is a verified kernel, not a model runtime: the quantized GEMM passes
  its CPU reference on Strix Point at 5.94 TOPS, but no quantized *model*
  runs end to end through it yet.
- No arbitrary LLM, GGUF, PyTorch, or ONNX model runs end to end through this
  repository on XDNA1. Unsupported operations and CPU fallback must remain
  visible.
- A pass on one dependency snapshot, device, shape, or power mode is not a pass
  on another. Source builds are large and upstream interfaces move.
- The NPU is not automatically faster or more efficient. Measure the complete
  application against CPU and iGPU baselines and keep the better fallback.

The complete device status lives in [SUPPORT.md](SUPPORT.md), deeper operator
and application boundaries in [APPLICATIONS.md](APPLICATIONS.md), and the
direct-kernel evidence in [MLIR-AIE.md](MLIR-AIE.md).

## Leave the door open

Use this work even if you never report back. If you do report back, a single
hardware result, corrected sentence, trained weight set with a compatible
license, reduced compiler failure, translation, or power measurement can help
the next owner.

Use the [Open NPU experiment form](../.github/ISSUE_TEMPLATE/experiment.yml) for
a reproducible artifact, or start a [GitHub Discussion](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/discussions)
when the idea still needs collaborators. Compile-only results and well-reduced
failures are welcome when they carry the right evidence label.

The project is not asking everyone to build the same LLM. It is asking people
to make different, inspectable things with hardware they already own—and to
leave enough evidence that another person can continue the adventure.

An NPU that runs one honest, useful job is no longer decoration.

## Primary sources and experiment scope

[^amd-7840u]: **Device origin — Ryzen 7 PRO 7840U / XDNA1.** AMD's exact [Ryzen 7 PRO 7840U support page](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-pro/ryzen-pro-7000-series/amd-ryzen-7-pro-7840u.html) establishes the origin processor and Phoenix codename. AMD's [Ryzen 7 7840U product page](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html) documents the sibling 7840U Ryzen AI NPU at up to 10 TOPS; repository hardware records establish the exact tested device.

[^ryzenai-linux]: **Current turnkey Linux scope — STX/KRK, checked 2026-08-15.** [AMD Ryzen AI Software 1.8.0 Linux installation documentation](https://ryzenai.docs.amd.com/en/latest/linux.html) states that the current release supports STX and KRK and describes CNN, encoder NLP, and NPU-only LLM flows. It does not list Phoenix; documentation may change after this date.

[^amdxdna]: **Driver/runtime foundation — multiple XDNA generations.** [`amd/xdna-driver`](https://github.com/amd/xdna-driver) is AMD's source repository for the Linux `amdxdna` driver and XRT shim. Driver visibility alone is not model execution.

[^iree-amd-aie]: **Compiler/runtime project — early open path used by this repo.** [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) is the upstream IREE AMD AIE plugin. This repository's claims apply only to its locked revision and recorded targets.

[^mlir-aie]: **Close-to-metal project — AIE arrays and direct kernels.** [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) describes IRON as a Python API over an open MLIR-based compiler toolchain with explicit tile placement, data movement, and vector compute. Upstream capability is not automatically a result on this repository's hardware/pin.

[^iron-dashboard]: **Upstream Phoenix hardware CI — AIE2 versus AIE2P.** AMD's [`IRON` at `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) and the successful [“Phoenix - Extensive Benchmark/Test Suite”](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15, report 2,105 passing and 45 skipped pytest case-runs under the default five iterations: 421 distinct passing parameter configurations and nine distinct skipped configurations. The skips are three MHA, three streaming-SwiGLU-prefill, and three GEMV+GELU configurations, each repeated five times. This is upstream hardware evidence, not this repository's acceptance matrix or current-lock XDNA1 rerun.

[^phoenix-gpt2]: **Published Phoenix XDNA1 experiment — Ryzen 9 7940HS, not this repo's 7840U.** A. Rösti and M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools,” arXiv:2504.03083 (2025)](https://arxiv.org/abs/2504.03083). The 2.8×/1.7×/1.2×/1.4× figures belong to the paper's hybrid GPT-2 124M fine-tuning setup and baselines.

[^steel]: **Published cross-generation attention experiment — keep baselines separate.** V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU,” arXiv:2607.09385 (2026)](https://arxiv.org/abs/2607.09385), with code identified by the paper at [`amd/IRON`](https://github.com/amd/IRON). The 9.6× result is the XDNA1 port versus DATO; the 9.17× CPU-energy, 1.75× GPU-energy, and 22.8× layer-by-layer results are from the paper's XDNA2 experiment.
