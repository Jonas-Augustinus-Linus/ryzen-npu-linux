# Contributing

Thanks for helping build an open XDNA-on-Linux path. This project exists so the
community can use AMD NPUs without a proprietary application boundary, then
turn verified kernels into local inference, agents, and many different LLM
experiments. The most valuable contribution is still **a reproducible result
from your own hardware**: successes expand the compatibility map, and precise
failures tell upstream projects where the next piece of the ecosystem is needed.

## What's welcome

- 🧪 **Hardware results.** Did the recipe work (or not) on your machine? Report
  your chip, kernel, distro, and what happened. Use the template below.
- 📊 **Benchmarks.** Numbers for other shapes/dtypes or XDNA1/XDNA2 machines.
- 🧩 **New ops and LLM building blocks.** Convolution, quantized matmul,
  attention, RoPE, RMSNorm, SwiGLU, sampling, fused ops, and honest CPU/NPU
  partitioning — anything reproducibly running through IREE or mlir-aie.
- 🪤 **Gotcha fixes.** A workaround that stopped working, a new failure mode, or
  a cleaner fix than what's in [docs/GOTCHAS.md](docs/GOTCHAS.md).
- 🛠️ **Script/doc improvements.** Make the tools more robust or portable.
- 🌍 **Translations.** Improve or add a language (see below).

## Reporting a hardware result (issue template)

Open an issue titled `result: <chip> / <distro> / <works|fails>` and include:

```
- CPU / NPU:        e.g. Ryzen AI 9 HX 370 (Strix Point, XDNA2 / RyzenAI-npu4)
- OS / kernel:      e.g. Ubuntu 26.04 / 7.0.0
- amdxdna driver:   in-tree | out-of-tree (version)
- XRT version:      e.g. 2.21.75      NPU firmware: e.g. 1.5.5.391
- detect-npu.sh:    paste the complete output
- verify-stack.sh:  quick/full, PASS or first failing stage
- Build:            success? compiler used, time, any patched flags
- Run:              i32 ✓/✗   bf16 ✓/✗   (paste the result line or error)
- Benchmark:        optional, paste the table row(s)
- Notes:            anything you had to change vs this repo
```

Even a clean "worked as written on <chip>" is genuinely useful data.

## Dev setup

```bash
./scripts/build.sh                 # builds iree-amd-aie with all workarounds
./scripts/verify-stack.sh --quick  # strict hardware + CPU-reference contract
./scripts/validate-repo.sh        # hardware-free checks used by CI
```
See [docs/BACKGROUND.md](docs/BACKGROUND.md) for how the pieces fit together.

## Pull requests

1. Fork and branch (`git checkout -b my-change`).
2. Keep scripts POSIX-bash and runnable on a fresh machine; test them.
3. If you change behaviour, update the relevant doc (and ideally its translations).
4. Open a PR describing **what you tested it on**.

## Translations

Each doc has per-language siblings: `README.<lang>.md`, `docs/<DOC>.<lang>.md`
(`de`/`fr`/`ko`/`ja`), with a language-switcher bar on top. When you edit English
prose, please update the translations too, or note in the PR that they need it.
**Never translate** code, commands, CLI flags, paths, or identifiers — only prose.

## Scope & conduct

This repo documents verified XDNA1 and Strix Point XDNA2 compute on Linux and
turns it into reusable public examples. It does not replace
[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), mlir-aie,
LLVM-AIE, XRT, or amdxdna; compiler/runtime bugs should be reduced here and then
reported upstream. Unsupported hardware (currently npu5/npu6) must stay labelled
unsupported until someone contributes real hardware evidence.

Be respectful and assume good faith. Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
report security problems through [SECURITY.md](SECURITY.md), and credit the
upstream work that makes every result possible.
