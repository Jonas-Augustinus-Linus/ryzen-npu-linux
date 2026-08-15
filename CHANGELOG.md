# Changelog

All notable public-release changes are documented here.

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
