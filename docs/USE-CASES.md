**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Where can you actually use an XDNA1 NPU on Linux?

Be honest with yourself about the maturity level. What you get from
`iree-amd-aie` on XDNA1+Linux today is a **compiler + runtime for AIE kernels**
(matmul, conv, and the elementwise ops around them), reachable from the
`iree-*` CLI and the IREE runtime C API. It is **not** a turnkey model server.

## The mental model: NPU vs iGPU vs CPU on this laptop

| Device | Best at | Use it for |
|---|---|---|
| **NPU (XDNA1, ~10 TOPS)** | sustained, **low-power** quantized/bf16 inference kernels | offloading specific matmul/conv blocks while sipping battery |
| **iGPU (Radeon 780M)** | high-throughput general compute | **your real local-AI workhorse on Linux today** — LLMs via Vulkan/ROCm |
| **CPU** | everything, latency-flexible | glue, control, fallback |

The NPU's whole reason to exist is **performance-per-watt**. If you don't care
about power, the 780M iGPU is the faster and far easier path for general AI on Linux.

## ✅ Good fits today

- **Learning NPU / spatial-dataflow programming.** A real device to compile to and
  watch execute. `run-matmul.sh` is a working baseline to mutate.
- **Benchmarking the NPU** for matmul/conv at various shapes & dtypes (i32, bf16→f32).
- **Low-power inference *primitives*.** Hand-built matmul/conv kernels you embed
  in an app via the IREE runtime C API and dispatch with `--device=amdxdna`, to
  keep a steady, lightweight workload off the CPU/GPU (e.g. small CNN stages,
  feature extractors, signal-processing matmuls).
- **Prototyping / research** on AIE tiling, objectFifo vs air pipelines, packet
  flow — the pieces that ultimately make bigger models viable.
- **Contributing upstream.** Every XDNA1-on-Linux result helps; the project's CI
  has a dedicated Phoenix runner but community coverage is thin.

## 🚫 Not realistic on XDNA1+Linux today

- **Turnkey LLM / Whisper / Stable Diffusion serving on the NPU.** No drop-in
  runtime targets XDNA1 on Linux. Use the **iGPU** (Ollama/llama.cpp Vulkan, ROCm),
  or **Windows** (legacy Vitis AI / Studio Effects), or **XDNA2** hardware.
- **"Point it at my `.onnx` and go."** ONNX Runtime's Vitis AI EP falls back to CPU
  for client NPUs on Linux. You author/lower kernels, not import arbitrary graphs.
- **Quantize-and-deploy pipelines.** Quantization tools exist; the *runtime* to run
  the result on XDNA1+Linux is what's missing — so don't quantize hoping to deploy here.

## How to embed a compiled kernel in an app

The `.vmfb` produced by `iree-compile` is loaded by the IREE runtime. Either:

- **CLI**: `iree-run-module --device=amdxdna ... --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4`
  (great for batch jobs / scripts), or
- **C API**: link `iree/runtime` from your `iree-install`, create the `amdxdna`
  HAL device, load the module, and invoke — the same path the CLI uses. This is
  how you'd wire an NPU matmul/conv into a real low-power pipeline.

## If you want turnkey NPU use

1. **XDNA2 hardware** (Strix / Strix Halo / Krackan) — where all 2026 Linux NPU
   momentum actually lands (Lemonade/FastFlowLM, AMD Ryzen AI SW for Linux).
2. **Windows** on this same 7840U — the legacy Vitis AI path and Windows Studio
   Effects do support Phoenix there.
