**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# What can you actually DO with the XDNA1 NPU on Linux?

A practical, honest map for people who want to **use** the first-gen Ryzen AI
NPU (XDNA1 / "Phoenix", e.g. the 7840U) on Linux — gamers, local-AI / agent
builders, app developers, and learners.

## The honest reality frame (read this first)

What you have on XDNA1+Linux today is **kernel/primitive-level**, not turnkey.
The only working software path is [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
built from source — a **compiler + runtime for AIE kernels** (matmul, conv, and
the elementwise ops around them), not a model server. Every turnkey stack (AMD
Ryzen AI SW for Linux, ONNX Runtime Vitis AI EP, Lemonade/FastFlowLM) **excludes
XDNA1**; full turnkey models and LLMs are **XDNA2 / Windows** territory. For most
heavy local AI on this laptop, the **Radeon 780M iGPU** (Ollama/llama.cpp Vulkan,
ROCm) is faster and infinitely easier — it is your real workhorse. **So why
bother with the NPU at all?** Because its genuine edge is **performance-per-watt
for a steady, always-on inference primitive**: a small conv/matmul block that
runs forever, sips battery, and keeps the CPU and iGPU idle. That is the thing
worth building — and several of them are buildable today. The rest of this guide
is about leveraging that edge without overpromising.

> **One myth to kill immediately:** there is **no silent CPU fallback**. If you
> hand the compiler an op it can't place on the NPU, you get a **compile error
> downstream**, not transparent CPU execution. "Run my model on the NPU and let
> the hard parts fall back" is **not** how this toolchain works — you partition
> the graph yourself and keep the unsupported parts on CPU as separate code.

---

## Capability ceiling: what `iree-amd-aie` can run on XDNA1 *today*

This is the part everything else depends on, so it is stated precisely. Verified
against the on-device CI harness (`build_tools/ci/cpu_comparison/run.py`,
`matmul_test_config.py`) and the compiler dispatch (`KernelDispatch.cpp`) at repo
HEAD `fddfec1b`, and cross-checked against adversarial review of those sources.

### Ops that genuinely RUN on the NPU (numerically checked vs llvm-cpu)

| Op | dtypes verified on `npu1_4col` | Status |
|---|---|---|
| `linalg.matmul` (+ `matmul_transpose_a/b`, `batch_matmul`, `matmul4d`) | `i8→i32`, `i32→i32`, `bf16→f32` | ✅ Numerically checked in CI |
| `linalg.matmul` + **bias add** (Linear layer) | `bf16→f32` only | ✅ Runs on npu1 (`MatmulThinBias`/`MatmulFullBias`, fusion flag) |
| `linalg.conv_2d_nhwc_hwcf` (plain 2D conv) | `i32→i32`, `bf16→f32`, `i8→i32` | ✅ Registered & run on npu1 (`conv-decompose`) |
| **Multi-dispatch graphs** (producer→consumer chains) | as above | ✅ `three_matmuls`, `two_matmul_switching` pass on npu1 |

So a model is **not** limited to a single kernel — you can chain several
supported dispatches into a small graph that executes on the NPU.

### Ops that are PARTIAL / experimental (lowering exists, but not CI-guaranteed on hardware)

| Op | Reality | Trust level |
|---|---|---|
| `linalg.softmax` | An npu1 lowering strategy **and** a bf16 LUT-exp microkernel exist, but the on-device e2e test is **commented out** pending [iree#21633](https://github.com/iree-org/iree/issues/21633). | 🟡 Compile path exists; on-device correctness **not** CI-guaranteed |
| `conv_2d_nhwc_hwcf_q` (i8 **quantized** conv) | Only a **FileCheck/compile** fixture (`conv2d_nhwc_q.mlir`); **not** wired into any hardware run and **not** numerically verified. | 🟡 Source/pass support only — do not assume it runs |
| i8 matmul + **dequant/requant** epilogue (the INT8 fully-connected pattern) | `matmul_elem_2.mlir` is a genuine requant epilogue **but is orphaned** — no harness registers it, so it does **not** execute via CI today. The *floating-point* matmul+bias path above is what's actually exercised. | 🟡 Pattern is real in source; you must wire & verify it yourself |
| `depthwise_conv_2d_nhwc_hwc` | A lowering branch exists but is described in-tree as "fragile, no guardrails"; the CI test is **commented out**. | 🟡 Try it, expect tuning; not guaranteed |
| `reduction_sum` | Present as a sample. | 🟡 |

### Ops that DON'T run on XDNA1 today

- **Attention / flash-attention** — no attention op is registered for the AIE
  backend at all; the prerequisite softmax e2e is disabled. ⛔ on XDNA1.
- **LayerNorm, gather/embedding lookups, dynamic shapes** — not in the dispatch set.
- **Recurrent cells (GRU/LSTM)** — no lowering; architecturally a poor fit anyway.

### Can you run a whole small model?

**Buildable, not turnkey.** A small **quantized MLP or 2–3-layer CNN** whose
*every* layer maps to supported matmul / plain-conv / fused-elementwise dispatches
can execute as a dispatch graph on the NPU. But: (a) this build **cannot import
`.onnx` or PyTorch** — it was compiled with `IREE_INPUT_TORCH/ONNX/TOSA=OFF` and
no Python bindings, and ships **no `iree-import-onnx`**; you feed it hand-written
**linalg-level MLIR** only. To import a real model you must **rebuild IREE** with
those frontends ON. (b) Any unsupported op (softmax until #21633, attention,
layernorm, depthwise, embeddings, dynamic shapes) is a **hard compile error**, so
you must avoid it or keep it on CPU. (c) You hand-tune tiling flags. There is **no
in-repo whole-model (ResNet/MLP/transformer) e2e test that passes on npu1.**

**Measured ceiling on this box:** bf16 matmul **~220 GFLOP/s at 1024³** (native
strength), `i32` ~6 GFLOP/s (not the AIE's native type), small matmuls are
dispatch-overhead bound. Fine for one small model stage at low duty cycle; **not**
for serving an LLM.

---

## For local-AI / agent builders

The NPU is **not** a drop-in inference engine for any agent component. But the
GEMM/conv math underneath embeddings, classifiers, rerankers and wake-word models
**is** exactly what the NPU runs — so these are real engineering builds, not
fantasies. The recurring pattern: **dense layers on the NPU, the sequential /
attention / softmax glue on CPU.**

| Application | Feasibility | How (concrete path) | Note |
|---|---|---|---|
| Wake-word / keyword spotting (always-on) | 🟡 buildable | A CNN/FC KWS model: mel front-end on CPU → small conv2d / FC classifier on NPU per ~80 ms frame → threshold → fire event. (`openWakeWord`'s head is a 3-layer FC ReLU net — pure matmul.) | **The single best agent fit.** Tiny, runs forever, perf/watt is the whole point. Batch frames to amortize ~hundreds-of-µs dispatch. |
| RAG embeddings (MiniLM / bge-small / e5-small) | 🟡 buildable | Lower the encoder's **matmul** blocks to NPU (bf16/i8); keep softmax/layernorm/attention on CPU. Embeddings are batchy & latency-tolerant (index a corpus once). | The GEMMs *are* the cost and *are* supported; you split the graph & validate numerics. |
| Bi-encoder re-ranking (query×doc scoring) | 🟡 buildable | Batched matmul of precomputed embeddings — close to a pure matmul, the NPU's single best op. | Cleanest mapping of any agent task. Cross-encoder reranking needs attention → keep that on CPU. |
| Intent classification / routing head | 🟡 buildable | Distilled MiniLM or an MLP over frozen embeddings: encoder GEMMs + linear head as matmuls (bf16). | Short-sequence, matmul-dominant → dispatch overhead amortizes. |
| Small CNN perception (UI-element / screenshot classifier, OCR pre-filter) | 🟡 buildable | Plain `conv_2d_nhwc_hwcf` backbone (bf16, or i8→i32) + matmul head on NPU; resize/normalize on CPU. Avoid ViT (attention wall). | Plain conv is verified; **i8 *quantized* conv is compile-only**, so prefer bf16 or validate i8 yourself. |
| Whisper / speech-to-text for a voice agent | ⛔ not suited (today) | Use `whisper.cpp` on CPU or the 780M (Vulkan). The encoder *could* be a research NPU offload, but there is no end-to-end Whisper-on-iree-amd-aie; decoder is GEMV/memory-bound. | NPU-int8 Whisper builds target Windows/Vitis, not XDNA1+Linux. |
| LLM **decode** / token generation | ⛔ not suited | Use the **iGPU**: Ollama/llama.cpp Vulkan (~14 tok/s gemma-2B, ~5–6 tok/s 7–8B Q4). | Decode is **memory-bandwidth** bound; the NPU's FLOPs/watt edge doesn't help the bottleneck. The clearest "use the iGPU" case. |
| LLM **prefill** (compute-bound, "should" suit an NPU) | 🟠 needs XDNA2/Windows | Needs fused attention + RoPE + RMSNorm + softmax lowered for npu1 — none exist. AMD's IRON `llama_3.2_1b` implements these but targets **AIE2P/XDNA2** only. | "Compute-bound" only helps if the ops are lowerable. They aren't, on XDNA1. |
| "Point at my `.onnx`, run on NPU" | ⛔ not available | ONNX Runtime Vitis AI EP falls back to CPU on Linux client NPUs; this build has no importer. Rebuild IREE with `IREE_INPUT_ONNX/TORCH=ON` to even *import*, then expect heavy op gaps. | A from-scratch rebuild, not turnkey. |

---

## For gamers

**Brutally honest:** a Linux gamer on a 7840U **cannot make games faster or
better with this NPU today**, in any shipping way. Three hard walls, not raw NPU
weakness:

1. **The Proton sandbox.** Games are Windows `.exe` under Proton/Wine. The NPU is
   reachable only via Linux-native `amdxdna` ioctls (XRT XDNA SHIM + a Linux ELF
   runtime). There is **no Windows-side `amdxdna` driver inside a Proton prefix**,
   so a game **cannot call the NPU**. The only path is a **separate Linux-native
   helper process outside the prefix**.
2. **XDNA1 is abandoned by every turnkey stack** (FastFlowLM/Lemonade/Ryzen AI SW
   = XDNA2). Only `iree-amd-aie` from source runs here.
3. **Nobody ships game NPU offload** on Linux (or really Windows). **NPUs deliver
   zero FPS** in current games.

> **The big myth: FSR is NOT an NPU workload.** FSR pre-4 is analytical (no ML).
> FSR4 / Redstone neural rendering runs on the **GPU's RDNA4 WMMA** units and needs
> an RX 9000 GPU — the Ryzen AI NPU is never used. AMD's own real-time NPU
> upscaler (REAPPEAR) is **XDNA2, Windows, on video**, and AMD itself calls
> in-game NPU upscaling a *"future direction."*

| Application | Feasibility | How (concrete path) | Note |
|---|---|---|---|
| Local voice / push-to-talk STT as an **out-of-process companion** | 🟡 buildable | Whisper **encoder** (GEMM-heavy) compiled via iree-amd-aie in a Linux daemon: read mic via PipeWire → emit text over a local socket → game/overlay consumes it. | **The one realistic gaming-adjacent NPU use.** Outside the render loop, tolerant of ~100–300 ms latency, native Linux (Proton wall doesn't apply). Porting the encoder to XDNA1 is the hard part. |
| Neural NPC / enemy AI (intent, tactical decisions) | 🟡 buildable | A Linux companion service runs a small policy/MLP via iree-compile; the game (mod/overlay) queries it over a socket. Turn-based / seconds-scale only. | IPC + dispatch latency rules out 60 Hz per-tick combat. DIY mod pattern, nothing ships this. |
| Procedural content (textures/levels) at **load time** | 🟡 buildable | Generate offline / at level-load in a native Linux process; game loads the assets. Latency-tolerant. | Dodges both the Proton wall and the frame budget. Small/medium nets only. |
| Offline/batch ML upscaling of **captures/screenshots** (not live) | 🟡 buildable | Capture to disk → small ESRGAN-style conv stack compiled to `.vmfb` → run with `--device=amdxdna`. | Only feasible *because* it's offline. The Vulkan path (Real-ESRGAN-ncnn) is far easier/faster today. |
| Local LLM co-pilot **alongside** (not inside) the game | 🟡 buildable | Small quantized model as a native Linux service; overlay/Discord bot consumes it; keeps the 780M free. | Modest tok/s; from-source bring-up since FastFlowLM/Lemonade refuse XDNA1. |
| In-game neural TTS for NPC lines | 🟠 needs XDNA2/Windows | Architecturally fine as a companion daemon, but VITS/transformer vocoders are largely unimplemented on XDNA1. | CPU TTS is simpler today. |
| **In-game** ML super-resolution / upscaling per frame | ⛔ not suited | Game can't reach `/dev/accel/accel0` under Proton; external capture→upscale→reinject blows the 16 ms budget; SR conv kernels for XDNA1 are unwritten. | FSR4 = GPU; REAPPEAR = XDNA2/Windows. |
| Frame generation | ⛔ not suited | Needs motion vectors/optical flow bound to the render pipeline (GPU). No pipeline access under Proton; per-frame round-trips add latency. | No frame-gen product uses an NPU. |
| Runtime animation / neural IK | ⛔ not suited | Tight per-frame engine coupling + Proton sandbox = no runtime path. Offline tooling only. | |
| Real-time external capture-upscaler via the NPU | ⛔ not suited | The only working real-time upscalers (Anime4K, waifu2x/Real-ESRGAN/RIFE on ncnn-vulkan) are GPU/Vulkan with **no XDNA backend**, and would fight the 780M. | You'd be writing new MLIR-AIE conv kernels *and* still losing to latency. |
| Anti-cheat via on-device NPU AI | ⛔ not suited | Irrelevant: kernel anti-cheat is Windows-only; EAC/BattlEye on Proton are user-mode policy choices. No anti-cheat uses an NPU. | |

---

## For app developers (low-power, always-on)

This is where the NPU's perf-per-watt edge actually pays off: a **steady,
low-duty-cycle** workload whose heavy core is **conv- or matmul-shaped**, wired
into standard Linux media plumbing. The honest split is **conv/matmul-shaped vs
recurrent**, not audio vs vision.

**Integration surfaces (all standard Linux):**
- **Audio** → PipeWire `pw_filter` / `module-filter-chain` (the same hook
  DeepFilterNet's LADSPA plugin uses) → expose a virtual mic.
- **Camera** → capture via GStreamer/v4l2 → run NPU → write to a **v4l2loopback**
  `/dev/videoN` (`exclusive_caps=1`) that Zoom/Chrome/OBS read.
- **General daemon** → the IREE runtime C API (create `amdxdna` HAL device → load
  `.vmfb` → invoke), modeled on `samples/simple_embedding/simple_embedding.c`.

| Application | Feasibility | How (concrete path) | Note |
|---|---|---|---|
| Webcam background blur / virtual background | 🟡 buildable | MediaPipe Selfie Segmentation (MobileNetV3-class conv encoder-decoder, 256×256). Run the conv backbone (bf16) on NPU; CPU resize + composite; out to v4l2loopback. | Pure conv → maps to supported `conv_2d_nhwc_hwcf`. Non-128-multiple shapes need tiling work; depthwise stages are 🟡 (fragile). |
| Mic noise suppression as a virtual mic | 🟡 buildable | **DeepFilterNet** (conv encoder-decoder), **not** classic RNNoise. Keep STFT/ERB + gating on CPU; offload conv blocks (bf16) to NPU; PipeWire `pw_filter` callback. Batch frames. | Win is **battery**, not latency — the CPU version is already real-time. Hard <10 ms deadline + dispatch overhead is the challenge. |
| On-device image classification / auto-tagging | 🟡 buildable | MobileNetV3 / EfficientNet-Lite: conv backbone (`conv_2d_nhwc_hwcf`) + matmul head on NPU; batch over your library at low duty cycle; resize/normalize on CPU. | Best vision fit **in bf16**. The i8 *quantized* conv + requant epilogue is **compile-only in CI** — validate it yourself before relying on i8. |
| Semantic image search embeddings (MobileCLIP-S0 image tower) | 🟡 buildable | Conv backbone + final projection matmul → fixed-length vectors via C API; store in sqlite/faiss on CPU. Index once, query cheap. | Ideal low-duty-cycle background job. Text **transformer** towers need attention → precompute off-device or keep on CPU. |
| On-device OCR (screenshots/scans) | 🟡 buildable | CRNN/PaddleOCR-style: conv feature extractor on NPU; CTC/sequence decode + any BiLSTM on CPU. Batch text-line crops. | Recurrent recognizer **cannot** live on the NPU (softmax/attention gated). |
| Object detection backbone (auto-framing smart camera) | 🟡 buildable | NanoDet/YOLO-nano: conv backbone+neck on NPU; anchor decode + NMS on CPU; v4l2loopback out. | NMS/anchor math is control-heavy → CPU. Odd feature-map shapes need tiling tuning. |
| Presence / gaze detection for power-saving | 🟡 buildable | Tiny face/gaze CNN at 2–5 fps: conv detector on NPU; on "looking away N s" → CPU action (DPMS dim / lock / pause). | Low fps **hides dispatch overhead** → one of the more forgiving builds; perf/watt is strongest at low duty cycle. |
| Runtime animation / neural IK inside an engine | ⛔ not suited | Per-frame engine coupling; only feasible as offline content tooling. | |
| Classic **RNNoise** (GRU) or **Silero VAD** as the NPU workload | ⛔ not suited | Keep on CPU (RNNoise runs ~60× real-time already). For NPU speech enhancement, switch to **conv-based DeepFilterNet**. | GRU/LSTM are inherently sequential (timestep depends on prior hidden state); dispatch overhead dominates; no recurrent lowering exists. |

---

## For learners

The NPU is a real, programmable spatial-dataflow device you can compile to and
**watch execute** — an excellent way to learn AIE / MLIR / dataflow without cloud
hardware.

| Application | Feasibility | How (concrete path) | Note |
|---|---|---|---|
| Learn AIE / spatial-dataflow by mutating a working matmul | ✅ works today | Start from [`scripts/run-matmul.sh`](../scripts/run-matmul.sh) and [`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir); change shapes/dtypes; recompile; run on `--device=amdxdna`. | The one empirically-verified tier on this box. |
| Benchmark matmul/conv across shapes & dtypes | ✅ works today | `BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`; compare i32 vs bf16, watch dispatch-bound vs compute-bound. | Teaches why bf16 is native and small kernels are overhead-bound. |
| Author your own conv2d / fused-elementwise kernel | 🟡 buildable | Write `linalg.conv_2d_nhwc_hwcf` or matmul+generic MLIR; compile `conv-decompose`/`pack-peel`; verify vs a CPU reference. | Plain conv is verified; quantized conv/softmax are experimental. |
| Build a tiny end-to-end model (quantized MLP / 2–3-layer CNN) | 🟡 buildable | Author every layer as supported linalg MLIR (model after `three_matmuls.mlir`); compile to one `.vmfb`; run the dispatch graph on NPU. | No `.onnx` import on this build; unsupported ops are **compile errors**, not fallbacks. |
| Import a real ONNX/PyTorch model and target the NPU | 🟠 needs a rebuild (+ heavy op gaps) | Rebuild IREE with `IREE_INPUT_TORCH/ONNX=ON` + Python bindings to get `iree-import-onnx`; expect attention/layernorm/softmax/embedding/dynamic-shape ops to **fail to compile** for AIE. | Frontends are off in this build by design; importing ≠ running. |
| Contribute upstream XDNA1-on-Linux coverage | ✅ works today | Run results on your own XDNA1 box; file hardware reports / new-op tests. Phoenix CI exists but community coverage is thin. | Every result helps; see [`CONTRIBUTING.md`](../CONTRIBUTING.md). |
| Run an LLM/Whisper to "learn NPU AI" | ⛔ not suited | Wrong tool — use the 780M iGPU for the model, and the NPU for *primitives*. | Don't start your NPU journey by trying to serve a transformer. |

---

## Build-your-own NPU primitive (cookbook)

The generic pipeline for turning a model's heavy stage into an NPU primitive you
embed in a daemon:

**1. Pick the model's heavy, parallel stage.** It must be **matmul / plain conv /
fused-elementwise** shaped. Recurrent (GRU/LSTM) and attention/softmax stages stay
on CPU. Keep pre/post-processing (STFT, resize, NMS, tokenization) on CPU.

**2. Express it as linalg-level MLIR.** Start from
[`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) (matmul) or a
`conv_2d_nhwc_hwcf` template. **Prefer `bf16`** (the AIE-native, ~220 GFLOP/s
type). i8 quantization works for matmul; i8 *quantized conv* and the i8 requant
epilogue are experimental, so **verify them against a CPU reference before you
rely on them**. (This build can't import `.onnx`/PyTorch — feed it MLIR.)

**3. Compile for the NPU.** The verified flag set
([`scripts/run-matmul.sh`](../scripts/run-matmul.sh), [`docs/GOTCHAS.md`](GOTCHAS.md)):

```bash
iree-compile \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device=npu1_4col \
  --iree-amdaie-device-hal=amdxdna \
  --iree-amdaie-lower-to-aie-pipeline=air        `# bf16 matmul; use objectFifo for i8/conv` \
  --iree-amdaie-tile-pipeline=pack-peel          `# matmul; use conv-decompose for conv` \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  model.mlir -o model.vmfb
```

**4. Verify on a known input.**

```bash
iree-run-module --device=amdxdna --module=model.vmfb \
  --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4   # cols=4 NOT 5, or ert state 8 timeout
```

**5. Integrate into a daemon / media graph.** Wire the `.vmfb` in via:
- **CLI** (`iree-run-module`) for batch jobs / quick scripts; or
- **IREE runtime C API** — create the `amdxdna` HAL device, load the module,
  resolve the function, invoke (model after `simple_embedding.c`). **Batch frames
  per dispatch** to amortize the ~hundreds-of-µs submit overhead, and keep a **CPU
  fallback path**.
- Then hook it to **PipeWire** (`pw_filter` / `module-filter-chain` → virtual mic)
  or **GStreamer + v4l2loopback** (→ virtual camera), or just a socket.

> Repo scripts to build on: [`check-npu.sh`](../scripts/check-npu.sh) (is it
> alive?), [`enable-npu.sh`](../scripts/enable-npu.sh) (render group / memlock /
> XRT), [`build.sh`](../scripts/build.sh) (the from-source build with all
> workarounds), [`run-matmul.sh`](../scripts/run-matmul.sh) (the compile+run
> recipe). Host compiler must be **gcc** (clang21 segfaults linking
> `libIREECompiler.so`).

---

## Where to start (by audience)

- **Agent builders:** build a **wake-word / KWS** primitive (conv/FC, always-on)
  or a **bi-encoder reranker** (batched matmul) — the cleanest NPU fits. Run the
  LLM itself on the 780M iGPU.
- **Gamers:** the only realistic build is an **out-of-process voice (STT) companion
  daemon** over a socket. Treat the NPU as a side-car, never inside the render loop.
- **App developers:** start with **background blur** (camera → v4l2loopback) or a
  **photo classifier** in **bf16** — conv-shaped, latency-tolerant, perf/watt wins.
- **Learners:** mutate [`run-matmul.sh`](../scripts/run-matmul.sh), benchmark
  bf16 vs i32, then author your own conv2d kernel; graduate to a tiny MLP graph.

## 🔇 Measured: the NPU loses to the CPU for audio

We measured it on a 7840U. A **whole CPU denoiser frame (8 layers) = 0.063 ms**,
while a **single NPU dispatch = 3.8 ms** — **~480× slower**, and a real denoiser
needs many dispatches/frame (≫ the 10 ms real-time budget). Audio frames are tiny,
so latency is **dispatch-overhead-bound** and the NPU's throughput edge never
applies; RNNoise (GRU) has no NPU lowering at all. **Use the CPU** for real-time
noise suppression — e.g. RNNoise via a PipeWire `module-filter-chain` virtual mic
(`librnnoise_ladspa.so`, label `noise_suppressor_mono`, exposed as an
`Audio/Source` via `playback.props`). Keep the NPU for vision/matmul; this is *why*
the audio rows above stay on the CPU.

## Honest "don't bother on XDNA1+Linux yet" list

- **Serving any LLM / Whisper / Stable Diffusion on the NPU.** Use the iGPU, or
  Windows/XDNA2.
- **LLM prefill *or* decode on the NPU** — prefill needs attention (absent),
  decode is bandwidth-bound (iGPU wins).
- **Anything with attention/transformers as an NPU dispatch** — no attention op,
  softmax e2e disabled (iree#21633).
- **Importing arbitrary `.onnx`/PyTorch and "just running" it** — no importer in
  this build; unsupported ops are compile errors, not fallbacks.
- **In-game / per-frame upscaling or frame-gen** — Proton sandbox + latency +
  FSR4-is-GPU. Not happening here.
- **GRU/LSTM models (classic RNNoise, Silero VAD) on the NPU** — sequential,
  no recurrent lowering; keep on CPU.
- **Relying on i8 quantized conv or the i8 requant epilogue** without verifying it
  yourself — those are compile-only/orphaned fixtures in CI today.

---

*Trust level legend: ✅ works today (verified on this box) · 🟡 buildable /
experimental (real engineering, supported ops) · 🟠 needs XDNA2 or Windows · ⛔
not suited to an NPU. Verified on a Ryzen 7 PRO 7840U (Phoenix/XDNA1), Ubuntu
26.04, kernel 7.0, XRT 2.21, `iree-amd-aie` HEAD `fddfec1b`, on 2026-06-22.
`iree-amd-aie` is early-phase and moves fast — flags and op coverage drift.*
