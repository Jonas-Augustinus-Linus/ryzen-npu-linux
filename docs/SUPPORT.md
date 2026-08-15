# Supported hardware and host requirements

This project deliberately distinguishes a PCI family name from a compiler
target that has been executed on real hardware. Run `scripts/detect-npu.sh`; do
not guess a target from the marketing name alone.

## Hardware matrix

| Hardware identity | IREE target | Status |
|---|---|---|
| Phoenix (Ryzen 7 PRO 7840U), `RyzenAI-npu1`, 4 usable columns | `npu1_4col` | Earlier real-hardware XDNA1 evidence; current exact v1 Peano 22 lock awaits reconfirmation |
| Hawk Point reporting `RyzenAI-npu1`, 4 usable columns | `npu1_4col` | Identity is mapped; no separate hardware result yet |
| Strix Point, `RyzenAI-npu4`, 4×8 array | `npu4` | Current exact v1 lock and acceptance contract hardware-verified |
| Krackan / `npu6`, Strix Halo / `npu5`, later devices | none here | Not mapped or claimed; contribute real-hardware evidence |

`lspci` may use one broad XDNA2 description for several products. The detector
combines the raw VBNV with usable geometry and refuses an unknown combination.
`TARGET_DEVICE` is an expert override, not a way to bypass incompatible geometry.

## Hardware evidence and current release host

- **Current v1 exact lock:** Ubuntu 26.04, Linux 7.0, in-tree `amdxdna`,
  native XRT userspace, Ryzen AI 9 HX PRO 370 / `RyzenAI-npu4`.
- **Earlier XDNA1 evidence:** Ubuntu 26.04, Linux 7.0, Ryzen 7 PRO 7840U /
  `RyzenAI-npu1`, using the same pinned IREE source commit and the Peano nightly
  selected by the earlier recipe. The current Peano 22 lock has not yet been
  rerun on that machine; a `verify-stack.sh --quick` result is requested.

The in-tree driver first appeared in Linux 6.14. Other recent distributions may
work, but the package-install commands are written for apt/Ubuntu and need a
reported hardware result before they become verified here.

## Build resources and privileges

- x86-64 Linux with Python 3.12 available through `uv`;
- 30–60 GB free disk for the IREE source/build/install tree;
- 16 GiB RAM minimum is practical; more RAM or swap is recommended for parallel
  C++ compilation. Reduce `JOBS` if the host is memory-constrained;
- internet access for pinned upstream source and Python wheels;
- `sudo` for system packages, render-group membership, and user-service memlock
  setup; the compiler and normal NPU runs are unprivileged;
- one reboot may be required after initial driver/group/memlock setup.

Review [`../scripts/enable-npu.sh`](../scripts/enable-npu.sh) before running it.
It changes host configuration and prints the exact files it manages. The other
readiness and verification scripts are unprivileged; `check-npu.sh` is read-only.

## Public verification contract

```bash
./scripts/check-npu.sh --strict
./scripts/build.sh
./scripts/verify-stack.sh --quick
```

The quick verifier must finish with full CPU-reference matches for i32 and bf16,
16,384/16,384 native runner elements, and 16,384/16,384 Python runner elements.
After `./scripts/setup-mlir-aie.sh`, use `--full` for the wake-word, ONNX MLP,
and native IRON bfp16 checks too.

This repository publishes source, pins, and reproduction instructions rather
than prebuilt compiler/runtime binaries. Upstream IREE, iree-amd-aie, mlir-aie,
LLVM-AIE, XRT, and driver projects retain their own licenses and security models.
