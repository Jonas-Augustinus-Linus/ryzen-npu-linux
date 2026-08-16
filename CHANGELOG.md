# Changelog

All notable public-release changes are documented here.

## [Unreleased]

### Added

- `examples/mlir-aie/w4a16_gemm`: a W4A16 quantized GEMM (int4 AWQ group-128
  weights, bf16 activations) on the whole 4×8 XDNA2 array — the TileFuse
  fused dequant+GEMM kernel, vendored byte-identical from the pinned external
  commit, ported from compile-only status to a repo-owned IRON 1.4.x design
  with Peano only. Includes a NumPy weight packer producing the exact
  4352-byte per-tile layout (verified bit-exact against the kernel's read
  path by the shipped `test_packing.py` harness) and a CPU-reference
  verifier bounding error against the accumulation scale.
- GOTCHAS M12–M14: the ¼-rate 8×8×8 bf16 `aie::mmul` without the bfp16
  emulation define (6.2× measured), `ExternalFunction` compile-flag changes
  not invalidating the `@iron.jit` cache, and three shim-DMA expressibility
  limits that only appear at larger shapes.

### Verified on Strix Point

- W4A16 GEMM CPU-reference PASS at 512³, 2048³ (4 and 8 columns), and
  2048×4096×4096; maximum elementwise error ≈ 9·10⁻³ of the |A|·|B|
  accumulation scale. Throughput 5.94 TOPS at 2048³ and 6.24 TOPS at
  2048×4096×4096 on 8 columns — +28% over the repo's 4.64 TFLOPS
  bf16-via-bfp16 baseline with 3.76× less weight DRAM traffic; column
  scaling 4→8 is 1.99×. TileFuse's chess-compiled 9 TOPS remains the
  reference point for the open Peano scheduling gap. No energy measurement.

## [1.1.0] - 2026-08-16

This release turns the verified compute toolkit into an **Open NPU Lab**: a
freely reusable starting point for owners of XDNA1 laptops, XDNA2 systems, and
future devices who want to explore local AI under Linux without hiding CPU
fallbacks or unsupported boundaries.

### Added

- English and Korean Open NPU Lab guides with a 15-minute/day/week/research
  progression, real XDNA1/XDNA2 GIFs, hybrid CPU+iGPU+NPU designs, an evidence
  contract, and explicit permission to use, modify, fork, and redistribute the
  repository under MIT.
- A primary-source research map linking AMD and Linux documentation, open
  compiler/runtime sources, and published XDNA1/XDNA2 LLM research. Upstream
  results are labelled separately from this repository's own measurements.
- A real `local-rag-sidecar` example: deterministic local document features,
  persistent 256x256 bf16 NPU scoring, complete CPU-reference validation before
  context use, CPU top-k/context assembly, and an optional fail-closed
  OpenAI-compatible model endpoint.
- An open-experiment issue form for useful successes, failures, compile-only
  results, performance measurements, and energy measurements on new hardware.

### Verified on Strix Point

- The sidecar executed 21 persistent NPU calls (three queries repeated seven
  times), checked all 65,536 outputs per call, preserved exact CPU top-3 parity,
  and observed a worst normalized maximum error of 0.149%. Dispatch timings
  varied materially across diagnostic reruns and are therefore not presented as
  CPU speedup or energy claims.
- The ordinary corpus-query path now performs the same full CPU-reference,
  tolerance, and ranking checks before retrieved text can reach a model.

### Research corrections and boundaries

- AMD IRON's exact Phoenix/AIE2 workflow at commit `cdc48e9` is recorded as
  upstream evidence: 2,105 passing and 45 skipped pytest case-runs under five
  default iterations (421 distinct passing and nine distinct skipped
  configurations) on 2026-08-15, including CPU-referenced GEMM/GEMV, Q4NX dequantization, Softmax,
  RoPE, RMS/LayerNorm, activations, and transpose. This is not relabelled as a
  repository exact-lock XDNA1 run or an end-to-end LLM.
- Stale claims that no ONNX importer or no broader XDNA1 operator path exists
  were corrected. The pinned IREE path, moving upstream IRON capability, and
  published papers now have distinct evidence labels.
- The exact current repository lock still awaits an XDNA1 hardware rerun;
  existing Phoenix evidence remains historical and Hawk Point remains
  identity-mapped but unverified here.

## [1.0.0] - 2026-08-15

Real Strix Point hardware: device detection, i32/bf16 CPU-reference matches,
full persistent-runner validation, and eight-column IRON XRT/HRX execution:

![XDNA2 Strix Point real-hardware compute and CPU-reference verification](https://raw.githubusercontent.com/Jonas-Augustinus-Linus/ryzen-npu-linux/v1.0.0/docs/media/xdna2-compute.gif)

### Added

- One open workflow spanning the earlier hardware-verified XDNA1
  (`npu1_4col`) path and the current-lock-verified Strix Point XDNA2 (`npu4`)
  path on Linux: detect, build, CPU-reference check, and persistent native/Python
  invocation.
- Real-hardware i32 and bf16 IREE paths, IRON examples, LLM building-block
  checks, ONNX extraction, wake-word, and virtual-camera examples.
- `verify-stack.sh` as the hardware acceptance contract and hardware-free CI for
  scripts, Python, Markdown links, and repository hygiene.
- Five-language documentation, contribution templates, and public compatibility
  result reporting.

### Reproducibility and safety

- Current release toolchain versions are pinned in `versions.lock`; development
  overrides are explicit rather than silently selecting a new nightly. The exact
  lock and acceptance contract were hardware-revalidated on Strix Point; the
  historical Phoenix result used the same IREE source commit and an earlier
  Peano, so XDNA1 reconfirmation of the exact v1 lock is requested.
- Device selection rejects unverified npu5/npu6 mappings instead of treating all
  XDNA2 hardware as Strix Point.
- Runtime outputs are fully validated, invalid C/Python inputs are rejected, and
  partial initialization is cleaned up.

### Known boundaries

- Phoenix XDNA1 has earlier real-hardware evidence, but the exact v1 Peano 22
  lock still awaits XDNA1 reconfirmation. Hawk Point has no separate hardware
  result. The current exact lock is verified on Strix Point npu4; npu5/npu6 are
  not claimed.
- Native bfp16ebs8 CPU-reference checks pass through K=1216 and first fail at
  K=1280 in the documented sweep; this is published as a boundary, not hidden.
- W4A16 front-end compilation works, while full lowering, linking, and NPU
  correctness remain open research work.
- The npu4 camera processing core matched the CPU on all 921,600 output values,
  but the complete XDNA2 GStreamer/`/dev/video10` loopback and FPS path remains
  unverified on this host; the published camera GIF is the original XDNA1 run.
- Results labelled compile-only, correctness, or performance remain separate.

[1.0.0]: https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases/tag/v1.0.0
[1.1.0]: https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases/tag/v1.1.0
