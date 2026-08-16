**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# What can you build with an XDNA1 NPU on Linux?

This is a practical map for owners of Phoenix-class laptops such as the Ryzen
7 7840U. The aim is not to pretend that every model is turnkey. It is to turn
silicon already in people's machines into an open Linux laboratory: run one
useful stage, compare every output with a trusted CPU result, compose it with
the CPU and iGPU, and publish enough evidence for the next person to continue.

Everything authored in this repository is MIT-licensed: **anyone may use,
copy, change, fork, publish, and redistribute it under the license terms.** See
the [Open NPU Lab](OPEN-NPU-LAB.md) for the mission and [Research branches](RESEARCH.md)
for primary sources and directions beyond this repository.

## Read the evidence label before the capability

- **Repo hardware:** this repository executed it on the named NPU and checked
  the complete result. Current-lock evidence is Strix Point `npu4`; Phoenix has
  valuable earlier hardware results, but still needs a current-lock rerun.
- **Upstream hardware:** an upstream project ran it on hardware. That is a route
  to reproduce, not a result inherited by this repository.
- **Template / plumbing:** real NPU dispatch or Linux I/O, with synthetic weights
  or an illustrative operation rather than a trained product.
- **Compile-only / project:** it has not yet crossed hardware execution and
  numerical-correctness gates.

Compilation is not execution; execution is not correctness; a kernel timing is
not an application result. This repository has not yet measured NPU energy, so
it makes no battery-life claim.

## There is more than one open software path

The narrow operator ceiling documented in older versions of this page applies
to the **repository-pinned `iree-amd-aie` backend at commit `fddfec1b`**, not to
the whole XDNA1 ecosystem.[^iree-amd-aie]

| Path | What the evidence says | Boundary |
|---|---|---|
| This repo's pinned `iree-amd-aie` | The repo verifies carefully shaped bf16/i8/i32 matmuls, persistent dispatch, and hybrid examples. Its conv path is narrow and target-dependent. | Current exact-lock hardware evidence is `npu4`; published 7840U results used the earlier working snapshot. Unsupported imported graph regions do not silently fall back. |
| This repo's pinned `mlir-aie` 1.4.1 track | Direct IRON kernels and upstream examples ran on the repo's Strix Point system; it is a lower-level path for authors who control placement and data movement. | This exact track has not been rerun on repo XDNA1 hardware. |
| Moving [`amd/IRON`](https://github.com/amd/IRON) | At exact commit `cdc48e93`, AMD's Phoenix hardware workflow on 2026-08-15 reported **2,105 passing / 45 skipped case-runs under its default five iterations**: **421 distinct passing configurations / 9 distinct skips**. Passing AIE2 coverage included bf16 GEMM/GEMV, Q4NX dequantization, softmax, RoPE, RMSNorm, LayerNorm, activations, transpose, and SwiGLU decode/prefill variants.[^iron-phoenix] | This is strong **upstream Phoenix evidence**, not the repo's exact-v1 XDNA1 rerun or a complete LLM. The 9 distinct skips are 3 MHA, 3 streaming-SwiGLU-prefill, and 3 GEMV+GELU configurations, each repeated five times to produce the three 15-case-run groups. The MHA/GQA dashboard remains AIE2P-only. |

The important correction is simple: “this pinned backend does not lower an op”
does **not** mean “XDNA1 cannot execute that kind of kernel.” Follow the exact
toolchain, device, test, and numerical oracle attached to each claim.

## ONNX: import, extract, then own the composition

The current [`scripts/build.sh`](../scripts/build.sh) installs a separately
pinned `iree-import-onnx`; no IREE rebuild or Python-bindings detour is required
for the repository workflow. [`tools/npu-trim`](../tools/npu-trim/) can import
or screen a graph, identify independent matmul/conv shapes, emit clean kernels,
and test-compile each one for the detected target.

It deliberately does **not** rebuild or execute an arbitrary whole model. Your
application owns the weights, padding/layout conversions, unsupported
operators, CPU fallback, and orchestration. The
[`examples/onnx-mlp`](../examples/onnx-mlp/) example is the executable contract:
NPU matmul → CPU ReLU → NPU matmul, checked against a bf16 CPU oracle.

```text
ONNX ── pinned importer ──▶ npu-trim ──▶ target-labelled matmul/conv VMFBs
                                              │
                       application-owned weights, layout and scheduling
                                              │
                         NPU kernels + explicit CPU glue/fallback
```

## A local LLM system can use all three processors

An NPU contribution is useful even when the NPU does not serve the entire LLM:

```text
microphone / camera / documents / UI events
                    │
                    ▼
      NPU: always-on trigger, feature block,
           linear/fused block, classification or scoring
                    │
                    ▼
      CPU: I/O, tokenization, top-k, tools, policy,
           unsupported operators and trusted fallback
                    │
                    ▼
      iGPU: an established quantized local-LLM runtime
            for prefill and token generation
```

As open attention, normalization and quantization kernels mature, a measured
block can move from CPU/iGPU to NPU without discarding the application. Two
published results show why this is a research path rather than wishful thinking:

- Rösti and Franz mapped GEMMs from **GPT-2 124M fine-tuning** to a first-gen
  Phoenix NPU while the CPU kept the rest. They report over **2.8×** for the
  offloaded matrix multiplications, **1.7×** mains and **1.2×** battery
  end-to-end throughput, and **1.4×** battery energy efficiency in their
  setup.[^phoenix-gpt2] These are the authors' figures, not repo measurements.
- STEEL reports an average **9.6× XDNA1 latency speedup versus DATO**, its cited
  prior XDNA1 attention baseline. Separately, on HX 370/XDNA2, it reports
  **9.17×** and **1.75×** lower energy use versus its CPU and GPU baselines and
  **22.8×** versus its layer-by-layer XDNA2 implementation.[^steel] Do not mix
  the XDNA1 latency experiment with the XDNA2 energy experiment.

## Things you can run, replace, or extend

| Starting point | What is real now | A useful next step |
|---|---|---|
| [`local-rag-sidecar`](../examples/local-rag-sidecar/) | **Repo hardware (`npu4`):** deterministic CPU hashing → persistent NPU 256×256 bf16 score matrix → CPU top-k → optional LLM endpoint restricted by default to the literal loopback hosts `127.0.0.1` or `::1`; remote endpoints require explicit `--allow-remote` opt-in. All 65,536 outputs are checked. | Replace hashing with licensed learned embeddings or a projection, batch queries, and rerun on XDNA1. A CPU dot product will likely be faster for one small query; the example proves integration and correctness, not a universal speedup. |
| [`wake-word`](../examples/wake-word/) | **Template:** real CPU log-mel and three persistent NPU dense dispatches; supplied weights are an illustrative matched filter. | Train and license real wake-word/intent weights, test real audio and false accepts, then wake an iGPU/CPU local assistant. |
| [`onnx-mlp`](../examples/onnx-mlp/) | **Template:** an actual imported two-matmul hybrid forward pass with per-dispatch and end-to-end CPU checks. | Substitute a trained intent, routing, safety, or projection head while preserving its shape-specific kernels and oracle. |
| [`npu-camera`](../examples/npu-camera/) | **Application plumbing:** GStreamer → persistent NPU → `v4l2loopback`; the NPU demo operation is a two-pass box blur, not segmentation. | Replace one stage with a trained, supported vision block; keep resize, compositing and fallback on CPU. |
| [`npu-runner`](../tools/npu-runner/) | **Repo hardware:** load a VMFB once and invoke it from C or Python, with complete-output checks. | Build a local daemon for batched scoring, sensor classification, or a reusable model sidecar. |
| [`mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **Direct-kernel laboratory:** inspectable spatial code and multi-column execution. | Reproduce one AMD IRON AIE2 operator on Phoenix, publish placement, transfers, CPU golden and first failing shape. |
| [`mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/) | **Repo hardware (`npu4`):** int4 AWQ-g128 weights dequantized in-core, quantization-aware CPU-reference PASS, 5.94 TOPS at 2048³ on 8 columns. | Wire it into a real quantized-model path (the llama.cpp route is still open), measure energy, and close the gap to the chess-compiled 9 TOPS. |

## More application directions

| Human need | NPU-sized experiment | Keep explicit elsewhere |
|---|---|---|
| Private local assistant | wake word, intent/safety head, batched retrieval scoring | CPU orchestration; CPU/iGPU generation |
| Personal search | projection and query×document score matrix | parsing, storage, top-k and final generation |
| Accessibility | acoustic, presence, gesture or UI-event classifier | capture and application policy |
| Camera/privacy | supported conv or linear stage | capture, resize, compositing, `v4l2loopback` |
| Audio | batched conv/linear feature or denoising block | PipeWire, STFT and hard real-time fallback |
| Games | native Linux companion for voice, intent or offline content | Proton game/render loop and frame-critical work |
| Compiler research | fusion, tiling, packet flow, quantized kernels | CPU references and reproducible harnesses |

The factual negative boundaries still matter. There is no shipping path here
that adds game FPS, frame generation or in-render-loop upscaling; a separate
native Linux companion is the practical experiment boundary under Proton.
Classic GRU/LSTM workloads need their own lowering or should remain on CPU.
Arbitrary transformer/Whisper/vision graphs are not whole-model drop-ins for the
repo-pinned backend. These are interfaces to investigate, not reasons to leave
the device unused.

## A reproducible experiment ladder

Start with the strict device and correctness checks:

```bash
./scripts/check-npu.sh --strict
./scripts/run-matmul.sh bf16 512 512 512
```

Then choose one existing application seam:

```bash
./examples/local-rag-sidecar/run.sh --cpu-only --selftest
./examples/local-rag-sidecar/run.sh --selftest       # supported live NPU
~/src/iree-aie-venv/bin/python tools/npu-trim/npu_trim.py model.onnx
```

For every extension, publish the device identity, exact commit/lock, model and
data license, shapes and precision, full-output tolerance, raw logs, latency,
and—only after measuring it—system energy. Keep CPU fallback available. A
minimal failure with a reproducible input is also useful open research.

## Where to continue

- Mission, evidence contract and contribution ladder:
  [Open NPU Lab](OPEN-NPU-LAB.md)
- Primary papers, upstream code and follow-on questions:
  [Research branches](RESEARCH.md)
- Generation-specific targets and current XDNA2 evidence:
  [XDNA2 guide](XDNA2.md)
- Longer transformer milestone sequence:
  [LLM roadmap](LLM-ROADMAP.md)

The goal is not one blessed demo. It is many inspectable experiments that let
ordinary owners, students and researchers reuse an NPU instead of forgetting
it. Take the source, change it, and let your result become somebody else's
starting point.

## Primary-source notes

[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie). The repository lock is `fddfec1be6ceefbdb890079d957947dfa1fe0848`; this section describes that backend, not every XDNA compiler path.
[^iron-phoenix]: AMD, [`IRON` at `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) and [Phoenix extensive hardware workflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15: under the workflow's default five iterations, 2,105 passing and 45 skipped case-runs represent 421 distinct passing configurations and 9 distinct skips. Upstream CI is moving evidence; pin the commit when reproducing.
[^phoenix-gpt2]: A. Rösti and M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025. First-generation Phoenix, Ryzen 9 7940HS, hybrid GPT-2 124M fine-tuning.
[^steel]: V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. The paper identifies [`amd/IRON`](https://github.com/amd/IRON) as its open-source implementation route.
