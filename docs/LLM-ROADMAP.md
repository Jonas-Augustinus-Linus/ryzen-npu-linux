# An open Linux NPU road to many LLMs

The purpose of this repository is larger than making one benchmark turn green.
We want an AMD NPU on Linux to be a piece of general community infrastructure:
something a student, independent developer, researcher, or small project can
understand, reproduce, change, and use without first joining a closed SDK
program. The code is MIT-licensed, the commands are inspectable, and both the
passes and the numerical failure boundaries are public.

The long-term hope is that people build **many different LLM systems** on this
foundation: local assistants, accessibility tools, private/offline agents,
multilingual models, low-power background services, experimental quantization,
and ideas this repository's maintainers will never invent. Success is not one
blessed model. Success is other people being able to take a verified primitive,
replace it, measure it against a CPU reference, and share the result.

This is not yet a drop-in LLM server. It is the reproducible layer underneath
one: device activation, compiler targets, real-hardware kernels, persistent
invocation, correctness checks, examples, and an honest map of what remains.

## What the foundation already proves

| Layer | Public contract |
|---|---|
| Device | Strict readiness plus exact XDNA1 `npu1_4col` / Strix Point `npu4` detection |
| IREE compute | i32 and bf16 matmul compiled and checked element-by-element against a host CPU reference |
| Persistent runtime | Native C API and Python/ctypes reuse one loaded module and validate the complete output tensor |
| IRON kernels | Eight-column XDNA2 examples and LLM primitives including softmax, RoPE, SwiGLU, and RMSNorm |
| Model path | ONNX matmuls extracted to NPU kernels with unsupported glue left explicitly on the CPU |
| Evidence | Reproduction scripts record known-good results and known numerical/compiler boundaries separately |

## Roadmap to useful LLM runtimes

1. **Finish quantized matrix multiplication.** Carry the current W4A16
   compile-only front end through lowering, link, NPU execution, and CPU golden
   verification. Add W8 and mixed-precision alternatives rather than assuming
   one quantization wins everywhere.
2. **Compose verified transformer blocks.** Join GEMM, attention/softmax, RoPE,
   RMSNorm, SwiGLU, and residual operations while measuring transfers and
   synchronization. A fused block only graduates when its full output is
   checked, not merely when it compiles.
3. **Build a model-facing runtime.** Add stable buffer reuse, KV-cache ownership,
   dynamic sequence handling, batching, cancellation, and profiling above the
   persistent runner. Keep the C ABI small enough for Python, Rust, C++, and
   existing inference engines to adopt.
4. **Connect open model formats.** Make ONNX, GGUF, and MLIR import paths emit a
   clear partition: supported NPU regions, deliberate CPU fallback, and a report
   of every unsupported op. Never silently claim that a CPU fallback ran on the
   NPU.
5. **Publish portable evidence.** Grow the hardware-result matrix across chips,
   kernels, drivers, firmware, and distributions. Track correctness, latency,
   throughput, energy, and memory separately so users can choose the right
   trade-off for their model.

## Contribution contract

A new LLM kernel or integration should include:

- exact device identity and pinned toolchain versions;
- the shapes, dtypes, quantization, padding, and accumulation behavior;
- a CPU or independently trusted golden implementation;
- full-output error metrics and an explicit tolerance rationale;
- a command another person can run from a fresh clone;
- honest labels for **compile-only**, **hardware correctness**, and
  **performance**;
- the smallest upstream issue or reproducer when the compiler/runtime is the
  limiting layer.

Start with [`../scripts/verify-stack.sh`](../scripts/verify-stack.sh), the
[XDNA2 evidence table](XDNA2.md), and the
[hardware-result issue form](../.github/ISSUE_TEMPLATE/hardware-result.yml).
The community does not need every experiment to succeed. It needs every result
to be reproducible enough that the next person can continue from it.
