# Research branches: where to continue from this repository

This is a deliberately curated map of **primary sources**: official hardware
and kernel documentation, upstream source repositories, and original research
papers. It exists so this small repository can be a fork in the road rather
than a dead end. Start with the question that started the project—*how can I
make the devices I already own useful?*—then follow the branch that matches your
hardware and curiosity.

Links here are not claims that this repository reproduced every result. Each
entry says what generation and evidence type it covers. Repository-owned
results remain in [SUPPORT.md](SUPPORT.md), [MLIR-AIE.md](MLIR-AIE.md), and the
[Open NPU Lab](OPEN-NPU-LAB.md).

## Evidence vocabulary

| Label | Meaning |
|---|---|
| **repo hardware** | This repository ran the workload on the named NPU and checked its output. |
| **historical repo hardware** | A real earlier run, but not under the current exact lock. |
| **upstream source** | The implementation or support statement exists upstream; it may move and was not necessarily run here. |
| **published research** | The authors report the result under their experimental setup; it is not a repo benchmark. |
| **compile-only** | Front-end/lowering compilation passed; no hardware-correctness or performance claim. |
| **proposal** | A useful experiment that still needs code and evidence. |

## 1. Understand the silicon and the Linux path

- **Phoenix / XDNA1 capability.** AMD specifies the Ryzen 7 7840U with a Ryzen
  AI NPU rated up to 10 TOPS.[^amd-7840u] This is a hardware capability statement,
  not a promise that a particular Linux framework supports it.
- **The mainline interface.** The Linux kernel's `amdxdna` documentation covers
  the accelerator driver, XDNA array, scheduling, application binaries,
  userspace components, DMA, isolation, and telemetry.[^kernel-amdxdna] The AMD
  driver repository contains the kernel-driver and XRT-shim development path.[^xdna-driver]
- **Why an enumerated device can still feel idle.** AMD's current Ryzen AI Linux
  product documentation lists newer STX/KRK targets.[^ryzen-ai-linux] That
  turnkey support matrix and lower-level programmability are different facts;
  this repository uses the latter to preserve a path for Phoenix.

**Good first research questions:** Can the same current lock pass on another
7840U/7940HS/8040-series machine? What firmware and kernel combinations change
the result? Can kernel telemetry support repeatable energy experiments?

## 2. Program the NPU instead of waiting for a model server

- **MLIR-AIE / IRON.** The upstream project exposes a close-to-metal Python API
  for tile placement, data movement, and vectorized compute on Ryzen AI
  NPUs.[^mlir-aie] Its programming guide is the best route from a first ObjectFIFO
  to multi-core designs.[^mlir-aie-guide] The AIE kernel API documents reusable
  vector, matrix, reduction, convolution, and vision building blocks.[^aie-kernels]
- **IREE AMD-AIE.** The IREE plugin connects compiler lowering and the `amdxdna`
  HAL, and is the from-source graph/compiler path used by this repository.[^iree-amd-aie]
- **Peano / LLVM-AIE.** The compiler that emits AIE core code is itself open
  source.[^llvm-aie] Exact compiler compatibility matters; use this repo's lock
  and verification scripts before comparing results.
- **The evolving AMD IRON library.** AMD's newer open repository publishes
  operators with interfaces, NPU designs, CPU references, and tests. Its
  2026-08-15 Phoenix workflow at exact commit `cdc48e9` reports 2,105 passing
  and 45 skipped pytest case-runs under its default five iterations—421 distinct
  passing configurations and nine distinct skipped configurations—exercising
  AIE2 GEMM/GEMV, RMSNorm, LayerNorm, RoPE,
  softmax, activations, Q4NX dequantization, transpose, and related paths.[^amd-iron]
  The distinct skips are three MHA, three streaming-SwiGLU-prefill, and three
  GEMV+GELU configurations, each repeated five times; the dashboard marks
  MHA/GQA as AIE2P-only. Treat this as
  strong **upstream Phoenix hardware evidence**, not as a repo-owned current-lock
  rerun or an end-to-end XDNA1 LLM result.
- **Why this interface matters.** The IRON interface paper evaluates the API's
  efficiency, expressivity, and extensibility, and links the artifact.[^iron-paper]

**Good first research questions:** Which upstream AIE2 operators fit Phoenix's
smaller array unchanged? Which require a new placement or data-movement design?
Can one fused block eliminate enough host round-trips to change system energy?

## 3. Local LLMs: move the boundary one block at a time

- **XDNA1 hybrid training is already published.** Rösti and Franz map the GEMMs
  of GPT-2 124M fine-tuning to first-generation Phoenix through IRON while the
  CPU keeps the rest. They report over 2.8× speedup for those matmuls, 1.7× and
  1.2× end-to-end throughput on mains and battery, and 1.4× battery energy
  efficiency in their setup.[^phoenix-gpt2] This is strong evidence for hybrid
  work; it is not a number reproduced by this repository.
- **Fusion changes the problem.** STEEL formulates fused attention for XDNA-like
  arrays and publishes its implementation through AMD IRON. The paper reports a
  9.6× average XDNA1 latency reduction against the cited prior XDNA1 design; its
  CPU/GPU energy comparison is a separate HX 370/XDNA2 experiment.[^steel]
- **Quantization is a dataflow problem, not only a file format.** TileFuse
  co-designs W4A16/W8A16 layout, unpacking, dequantization, and GEMM/GEMV for
  XDNA2, reporting kernel and end-to-end gains under the authors' setup.[^tilefuse]
  This repository now has its own hardware evidence on that direction: the
  TileFuse kernel runs CPU-reference-verified at 5.94 TOPS in
  [`examples/mlir-aie/w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/); the
  paper's 9 TOPS (chess) and end-to-end results remain the authors' own.
- **Reproducible process can itself be open infrastructure.** A 2026 study
  records correctness-gated skills used to deploy multiple decoder-only LLMs on
  XDNA2 with the open compiler stack.[^agent-skills] Its exact models and XDNA2
  results do not transfer automatically to XDNA1, but the method—small phases,
  numerical gates, and reusable debugging knowledge—does.

**Branches worth exploring:**

1. XDNA1 bf16 FFN/linear blocks from a small open checkpoint, with CPU
   activation and residual glue.
2. A trained intent or safety head that uses the persistent NPU runner while a
   local CPU/iGPU model generates text.
3. Batched embedding projection or RAG scoring, where one dispatch does useful
   work for many documents or queries.
4. AIE2 fused attention and dequantization ports whose placement is designed
   for Phoenix instead of pretending AIE2P geometry is identical.
5. XDNA2 W4/W8 transformer blocks with full-output goldens, then a stable
   model-facing runtime and KV-cache contract.

## 4. Turn kernels into things people can use

This repository already exposes the plumbing for persistent C/Python calls,
ONNX matmul extraction, wake-word features, a virtual camera, and direct IRON
kernels. Useful next projects can stay small:

| Human need | NPU-sized experiment | Keep elsewhere |
|---|---|---|
| Private local assistant | wake word, intent head, embedding projection, batched RAG scoring | CPU orchestration; iGPU/CPU generation |
| Accessibility | always-on acoustic or visual event classifier | UI policy, speech decode, application integration |
| Personal search | document/query projection and top-k score matrix | parsing, storage, final rerank/generation |
| Camera/privacy | trained segmentation or classification blocks | capture, resize, compositing, virtual-camera output |
| Low-power monitoring | batched sensor/spectrogram classifier | acquisition, alert policy, logging |
| Compiler research | tiling, fusion, packet flow, quantized kernels | trusted references and experiment harness |

The [local RAG sidecar](../examples/local-rag-sidecar/) is intentionally one
small bridge: CPU text hashing, persistent NPU matrix scoring, CPU top-k, and an
optional LLM endpoint restricted by default to the literal loopback hosts
`127.0.0.1` or `::1`. Remote endpoints require explicit `--allow-remote`
opt-in. It is an integration reference—not a claim that hashing is a trained
embedding model or that one query beats a CPU.

For established local model engines, follow their own primary repositories and
connect them as peers rather than claiming their work as this project's:
`llama.cpp` for GGUF CPU/GPU inference,[^llama-cpp] `whisper.cpp` for local
speech recognition,[^whisper-cpp] and `openWakeWord` as a reference for trained
wake-word models.[^openwakeword]

## 5. Publish experiments so somebody else can continue

Use the [experiment issue form](../.github/ISSUE_TEMPLATE/experiment.yml). Link
the source and model license; record exact device identity, lock, shapes,
precision, full-output error, warmups, repetitions, and raw logs. Keep these
statements separate:

1. it compiled;
2. it executed on hardware;
3. its complete output met a justified reference tolerance;
4. it was faster;
5. it used less energy;
6. it solved a useful user problem.

An experiment that fails at step two is still valuable if its reproducer is
public. Open research grows through traceable branches, including branches that
show where not to spend another week.

## Primary-source notes

[^amd-7840u]: AMD, [Ryzen 7 7840U product specifications](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html). Hardware specification; accessed 2026-08-15.
[^kernel-amdxdna]: Linux kernel documentation, [`accel/amdxdna` NPU driver](https://docs.kernel.org/accel/amdxdna/index.html). Mainline driver architecture and interfaces.
[^xdna-driver]: AMD, [`xdna-driver`](https://github.com/amd/xdna-driver). Kernel driver and XRT shim source.
[^ryzen-ai-linux]: AMD, [Ryzen AI Software 1.8 Linux installation/support page](https://ryzenai.docs.amd.com/en/latest/linux.html). Current product support is time-sensitive; checked 2026-08-15.
[^mlir-aie]: Xilinx/AMD, [`mlir-aie`](https://github.com/Xilinx/mlir-aie). Open MLIR-AIE and IRON source.
[^mlir-aie-guide]: Xilinx/AMD, [IRON programming guide](https://xilinx.github.io/mlir-aie/dev/programming_guide/). Upstream developer documentation.
[^aie-kernels]: Xilinx/AMD, [AIE kernels API](https://xilinx.github.io/mlir-aie/dev/api/aie_kernels/). Upstream kernel inventory and interfaces.
[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie). Early-phase IREE compiler plugin and AMD-AIE runtime integration.
[^llvm-aie]: Xilinx/AMD, [`llvm-aie`](https://github.com/Xilinx/llvm-aie). Open compiler targeting AMD AI Engines.
[^amd-iron]: AMD, [`IRON` at `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) and [Phoenix extensive hardware workflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15: 2,105 passing and 45 skipped pytest case-runs under five default iterations, representing 421 distinct passing and nine distinct skipped parameter configurations. Moving upstream source; pin the commit when reproducing.
[^iron-paper]: E. Hunhoff et al., [“Efficiency, Expressivity, and Extensibility in a Close-to-Metal NPU Programming Interface”](https://arxiv.org/abs/2504.18430), FCCM 2025.
[^phoenix-gpt2]: A. Rösti and M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025. The paper targets first-generation Phoenix and a hybrid GPT-2 124M fine-tuning implementation.
[^steel]: V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. The source link named by the paper is [AMD IRON](https://github.com/amd/IRON).
[^tilefuse]: W. Pang et al., [“TileFuse: A Fused Mixed-Precision Kernel Library for Efficient Quantized LLM Inference on AMD NPUs”](https://arxiv.org/abs/2606.11357), 2026. XDNA2 results only.
[^agent-skills]: J. Li et al., [“From Human Guidance to Autonomy: Agent Skill System for End-to-End LLM Deployment on Spatial NPUs”](https://arxiv.org/abs/2606.07586), MLArchSys/ISCA 2026. XDNA2 study.
[^llama-cpp]: ggml-org, [`llama.cpp`](https://github.com/ggml-org/llama.cpp). Primary source for GGUF-oriented local inference.
[^whisper-cpp]: ggml-org, [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp). Primary source for local Whisper inference.
[^openwakeword]: dscripka, [`openWakeWord`](https://github.com/dscripka/openWakeWord). Primary implementation/training reference for open wake-word models.
