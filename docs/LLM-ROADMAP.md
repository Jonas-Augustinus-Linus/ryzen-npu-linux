# From idle silicon to many local AI systems

This project began with a Ryzen 7 PRO 7840U whose NPU was visible to Linux but
had no practical open application path. The goal is not to crown one model or
one generation. It is to make laptop NPUs understandable, reusable building
blocks for private local AI—and to leave enough source, measurements, and
failure evidence that somebody else can continue the work.

Everything authored in this repository is MIT-licensed. You may use it, fork
it, teach from it, change it, redistribute it, or turn it into a different
project without asking permission. Contributions back are welcome, not a
condition of use.

This is still not a drop-in XDNA1 LLM server. It is the reproducible layer
underneath one: device activation, compiler targets, real-hardware kernels,
persistent invocation, CPU references, hybrid examples, and an honest map of
what remains. The broader experiment map is the [Open NPU Lab](OPEN-NPU-LAB.md).

## The practical architecture: use all three engines

A useful local assistant does not need every operation on one processor. A
realistic laptop design assigns work according to its character:

```text
microphone / camera / files / sensors
                 |
                 v
      NPU: always-on, repeated kernels
      wake word · features · intent/routing · reranking · vision blocks
                 |
                 v
      CPU: orchestration and unsupported glue
      tokenization · sampling · I/O · fallback · application policy
                 |
                 v
      iGPU (or a future NPU runtime): model generation
      quantized local LLM · speech · image model
```

On XDNA1 today, the NPU is best treated as an open, low-level accelerator for
selected kernels or fused blocks while the CPU and Radeon iGPU keep doing the
work they already do well. This is not a consolation prize: it lets an idle
piece of silicon participate in a useful private system and gives researchers a
path to move the boundary one verified block at a time. XDNA2 can use the same
hybrid pattern while also exploring newer end-to-end runtimes.

## What primary evidence says is possible

The limits of today's turnkey software are not the limits of the hardware.
Keep these evidence classes separate:

| Evidence | What it establishes | What it does **not** establish here |
|---|---|---|
| AMD Ryzen 7 7840U specifications[^roadmap-7840u] | Phoenix shipped with a Ryzen AI NPU rated up to 10 TOPS. | A Linux model runtime or application compatibility. |
| Rösti & Franz, FCCM 2025[^roadmap-phoenix-gpt2] | On first-generation Phoenix, a hybrid IRON/CPU implementation offloaded GPT-2 124M GEMMs for local fine-tuning: over 2.8× for the offloaded matmuls, 1.7×/1.2× end-to-end throughput on mains/battery, and 1.4× battery energy efficiency in the authors' setup. | Those figures are not measurements from this repository and do not mean arbitrary LLMs run here unchanged. |
| AMD IRON operator library and Phoenix CI[^roadmap-amd-iron] | On 2026-08-15, AMD's exact `cdc48e9` Phoenix workflow recorded 2,105 passing and 45 skipped pytest case-runs under five default iterations: 421 distinct passing and nine distinct skipped configurations. The open AIE2 path exercised CPU-referenced GEMM/GEMV, Q4NX dequantization, softmax, RoPE, RMS/LayerNorm, activations, transpose, and related operators. | This is upstream hardware evidence, not this repository's exact-v1 Phoenix rerun. The distinct skips were three MHA, three streaming-SwiGLU-prefill, and three GEMV+GELU configurations, each repeated five times; MHA/GQA remains AIE2P-only, so this is not an end-to-end XDNA1 LLM result. |
| STEEL, 2026[^roadmap-steel] | The paper ports fused attention to XDNA1 and reports an average 9.6× latency reduction versus the cited prior XDNA1 implementation. Separately, its HX 370/XDNA2 measurements report lower attention energy than CPU/GPU baselines. | The XDNA1 latency comparison and XDNA2 energy comparison are different experiments; neither is a result reproduced by this repository yet. |
| Current AMD Ryzen AI Linux support[^roadmap-amd-linux] | As of 2026-08-15, AMD's current turnkey Linux release targets newer STX/KRK platforms. | Exclusion from that product matrix does not make Phoenix's programmable AIE array unusable through open lower-level tools. |

These results are the reason this roadmap does not describe XDNA1 as dead
hardware. They also show why rigor matters: generation, toolchain, model,
precision, power mode, and CPU/GPU baselines must travel with every number.

## What this repository already proves

| Layer | Public contract | Evidence status |
|---|---|---|
| Device | Strict readiness plus exact XDNA1 `npu1_4col` / Strix Point `npu4` detection; unknown later devices are rejected. | XDNA1 historical hardware; current v1 lock on Strix |
| IREE compute | i32 and bf16 matmul compiled and checked against host CPU references. | XDNA1 historical hardware; XDNA2 current hardware |
| Persistent runtime | Native C API and Python/ctypes reuse one loaded module and validate the complete output tensor. | Both paths have hardware evidence under their documented snapshots |
| Hybrid model plumbing | ONNX matmuls are extracted, run persistently on the NPU, and unsupported ReLU glue stays explicitly on CPU. | Generated test MLP, not a trained application model |
| Always-on plumbing | CPU log-mel → three NPU dense dispatches → CPU threshold, plus a GStreamer virtual-camera path. | Working templates; wake weights are illustrative and camera compute is a non-AI box blur |
| IRON kernels | Direct kernels, LLM primitives, whole-array GEMM, and full MobileNet examples. | Earlier Phoenix results and current Strix results use different dependency snapshots |

The current exact-v1 pin still needs an independent Phoenix/XDNA1 hardware
rerun. That missing confirmation is a published task, not a reason to erase the
earlier 7840U evidence or silently promote it to a current result.

## Two honest development tracks

### XDNA1: rescue the laptops already in people's hands

1. Re-run `verify-stack.sh --full` on Phoenix with the exact current lock and
   publish the unedited log, device identity, firmware, and tolerances.
2. Replace the illustrative wake-word weights with a redistributable trained
   model, then connect detection to a local assistant running on CPU/iGPU.
3. Turn the generated ONNX MLP into useful intent classification, embedding
   projection, or reranking, retaining per-dispatch CPU checks.
4. Port and fuse transformer primitives from the open AIE2 operator work rather
   than assuming an AIE2P design fits the smaller array.
5. Measure latency **and** system energy against CPU and iGPU baselines. A faster
   dispatch alone is not evidence of better battery life.

### XDNA2 and later: explore without abandoning the evidence contract

1. ~~Finish W4A16 from compile-only through link, hardware execution, and a
   quantization-aware CPU golden~~ — **done**
   ([`w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/): CPU-reference PASS,
   5.94 TOPS at 2048³ on 8 columns). Next: compare W8 and bf16 rather than
   assuming one format wins, and measure energy.
2. Compose GEMM, attention/softmax, RoPE, RMSNorm, SwiGLU, residuals, and
   dequantization into fused transformer blocks that avoid round-trips.
3. Add KV-cache ownership, dynamic sequence handling, batching, cancellation,
   profiling, and stable buffers above the persistent runner.
4. Connect ONNX, GGUF, and MLIR import paths to an explicit partition report:
   NPU regions, deliberate host operations, and every unsupported op.
5. Bring up later `npu5`/`npu6` devices from their real geometry and upstream
   target—not by relabeling them as Strix—and graduate support only after a
   full-output hardware result.

## An experiment ladder anyone can climb

| Time | A useful contribution |
|---|---|
| 15 minutes after setup | Run `verify-stack.sh --quick`; attach the log and device identity to a hardware-result issue. Failures are useful data. |
| One evening | Change a matmul shape or dtype, add a CPU golden, and report full-output error plus timing. |
| One weekend | Put a real small classifier, feature projection, reranker, or vision block behind `npu-runner`; compare an honest CPU implementation. |
| A longer project | Fuse a transformer block, add quantization, measure wall energy, or integrate an open local-LLM runtime. Publish the source even when the result loses. |

Use the [experiment issue form](../.github/ISSUE_TEMPLATE/experiment.yml) to
leave a reproducible trail. A negative result with a minimized reproducer can
save the next person weeks.

## Graduation contract for a model or kernel

A new LLM kernel or integration graduates only when it includes:

- exact device identity and pinned toolchain versions;
- shapes, dtypes, quantization, padding, and accumulation behavior;
- a CPU or independently trusted golden implementation;
- full-output error metrics and an explicit tolerance rationale;
- a command another person can run from a fresh clone;
- separate labels for **idea**, **compile-only**, **hardware correctness**,
  **performance**, and **energy**;
- raw logs, warmup/repetition details, and an upstream issue or minimized
  reproducer when the compiler/runtime is the limiting layer.

The community does not need every experiment to succeed. It needs every result
to be clear enough that the next person can continue from it. Start with
[`../scripts/verify-stack.sh`](../scripts/verify-stack.sh), the
[support/evidence matrix](SUPPORT.md), and the existing
[hardware-result issue form](../.github/ISSUE_TEMPLATE/hardware-result.yml).

## Primary-source notes

[^roadmap-7840u]: AMD's exact [Ryzen 7 PRO 7840U support page](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-pro/ryzen-pro-7000-series/amd-ryzen-7-pro-7840u.html) establishes the origin processor and Phoenix codename. AMD's [Ryzen 7 7840U product specifications](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html) document the sibling 7840U Ryzen AI NPU at up to 10 TOPS; repository hardware records establish the exact tested device.
[^roadmap-phoenix-gpt2]: A. Rösti and M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025. First-generation Phoenix, GPT-2 124M hybrid fine-tuning.
[^roadmap-amd-iron]: AMD, [`IRON` at `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) and the successful [“Phoenix - Extensive Benchmark/Test Suite” run](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15: 2,105 passing and 45 skipped pytest case-runs under five default iterations, representing 421 distinct passing and nine distinct skipped configurations. Upstream source and upstream hardware CI, not a repo-owned run.
[^roadmap-steel]: V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026; source is published in [AMD IRON](https://github.com/amd/IRON).
[^roadmap-amd-linux]: AMD, [Ryzen AI Software 1.8 Linux installation/support page](https://ryzenai.docs.amd.com/en/latest/linux.html). Product support is time-sensitive; checked 2026-08-15.
