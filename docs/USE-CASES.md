**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Turn an XDNA laptop into a hybrid local-AI lab

An NPU does not have to serve an entire LLM by itself to earn a useful place in
the system. On XDNA1 Linux today, the practical route is to give the NPU a
small, repeated, CPU-checkable stage; let the CPU handle I/O, policy, and
unsupported operations; and use the iGPU for high-throughput token generation
when an application needs it.

```text
microphone / camera / documents / UI events
                         │
                         ▼
              CPU: I/O, control, fallback
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
 NPU: always-on trigger,       iGPU: quantized LLM
 scoring, dense/conv blocks     prefill + generation
              └──────────┬──────────┘
                         ▼
              CPU: tools, policy, output
```

This is an engineering split, not a universal performance verdict. Low energy
use and longer battery life are design goals; this repository has not yet
published controlled end-to-end energy measurements proving them.

## Useful projects you can build from the supplied source

| Project | NPU role | CPU / iGPU role | Evidence boundary |
|---|---|---|---|
| **Private RAG helper** | Batch document/query scoring through a persistent bf16 matmul | CPU chunks, hashes, selects top-k; optional local LLM generates on another backend | [`local-rag-sidecar`](../examples/local-rag-sidecar/) is a real NPU-in-the-loop integration. Its features are deterministic hashed bag-of-words, **not trained embeddings**; one small query is likely faster on CPU. Current live proof is XDNA2; current-lock XDNA1 is pending. |
| **Local voice assistant** | Always-on wake or intent head | CPU audio front end and control; iGPU LLM answers | [`wake-word`](../examples/wake-word/) exercises three persistent NPU dense layers, but the supplied weights are illustrative rather than a trained wake vocabulary. |
| **Private camera or accessibility trigger** | A supported conv/dense classifier stage | CPU captures/composites; app emits a Linux event | [`npu-camera`](../examples/npu-camera/) proves GStreamer → NPU → `v4l2loopback` plumbing, but its current operation is a non-AI box blur. Replace it with a trained, CPU-checked model stage. |
| **Hybrid ONNX experiment** | Extracted supported matmul/conv partitions | CPU keeps ReLU, graph glue, and fallback | [`onnx-mlp`](../examples/onnx-mlp/) executes a real hybrid forward path, but the network and weights are generated demonstration data, not a trained application. [`npu-trim`](../tools/npu-trim/) screens rather than magically supporting an arbitrary graph. |
| **Quantized-block research** | GEMM/GEMV, dequantization, normalization, RoPE, softmax as each path is verified | CPU golden result, unsupported attention/control; optional iGPU remainder | AMD's official IRON Phoenix workflow at commit `cdc48e93` passed CPU-referenced AIE2 examples for these primitives.[^iron-ci] That is upstream evidence, not this exact-lock XDNA1 result or an end-to-end LLM. |
| **Cross-generation lab** | Run the same source through device-specific targets | CPU records identity and checks every output | Preserve separate XDNA1 historical, XDNA2 current-lock, and future-device rows. A clean failure on an unknown device is useful evidence. |

## A progression that produces publishable work

1. **Reproduce one correctness contract.** Run the strict detector and a full
   CPU comparison before optimizing anything.
2. **Replace one synthetic part.** Train wake-word weights, supply a real
   embedding projection, or replace the camera blur with one evaluated model
   stage. Keep a CPU fallback.
3. **Compose, do not pretend.** Connect the NPU stage to a local LLM, database,
   desktop action, or sensor loop while labeling where every operation runs.
4. **Measure the whole application.** Report kernel and end-to-end latency,
   transfers, accuracy, idle/load power, energy per task, temperature, and the
   CPU/iGPU baselines. Energy is not proven by a TOPS badge.
5. **Publish the boundary.** Record device identity, compiler commit, shapes,
   data types, commands, full-output correctness, skips, and first failure. A
   negative result with a minimal reproducer helps the next researcher.

## Two open routes, different jobs

- The repository's pinned `iree-amd-aie` route packages device modules and a
  persistent C/Python invocation path. Start here for the supplied integrations
  and exact release contract.
- The pinned [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) 1.4.1 route
  exposes the IRON Python API/compiler for direct spatial-kernel programming.
  The newer [`amd/IRON`](https://github.com/amd/IRON) operator/application
  library is a separate project built on MLIR-AIE language bindings, not a
  rename. At commit `cdc48e93`, its official Phoenix workflow reported **2,105
  passing and 45 skipped pytest case-runs**. With five default iterations, that
  is **421 distinct passing and 9 distinct skipped configurations**. The skips
  are three MHA, three streaming-SwiGLU, and three GEMV+GELU configurations,
  each repeated five times. GQA is not established by this run; do not turn the
  result into a whole-XDNA1-LLM claim.[^iron-ci]

AMD Ryzen AI Software 1.8 for Linux lists STX/KRK rather than
Phoenix.[^ryzenai-linux] That limits the drop-in product path; it does not close
these open lower-level routes.

## The honest limitation

There is still no supported command here that takes an arbitrary GGUF, Whisper,
Stable Diffusion, or ONNX model and serves the whole graph on XDNA1. Compilation
coverage, memory, transfers, and host orchestration remain real constraints.
The useful response is to expose those boundaries, offload verified stages, and
make each stage replaceable as the ecosystem advances.

For the full invitation and source/evidence gallery, enter the
[Open NPU Lab](OPEN-NPU-LAB.md). Follow primary sources and precise claim scopes
in [RESEARCH.md](RESEARCH.md), and see the next operator and model milestones in
the [LLM roadmap](LLM-ROADMAP.md).

[^iron-ci]: AMD IRON, [official Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), accessed 2026-08-15; the page lists STX and KRK as supported platforms.
