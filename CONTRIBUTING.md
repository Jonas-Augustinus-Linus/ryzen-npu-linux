# Contributing

Thanks for helping map out the XDNA1-on-Linux NPU path! This is a community
knowledge base — the single most valuable contribution is **a result from your
own hardware**, because coverage of first-gen Ryzen AI on Linux is thin.

## What's welcome

- 🧪 **Hardware results.** Did the recipe work (or not) on your machine? Report
  your chip, kernel, distro, and what happened. Use the template below.
- 📊 **Benchmarks.** Numbers for other matmul shapes/dtypes, or on a different
  XDNA1 chip (7840U vs 7640U vs 8840U vs …).
- 🧩 **New ops.** Convolution, other dtypes (i8, f32), fused ops — anything you
  got running through `iree-amd-aie` on the NPU.
- 🪤 **Gotcha fixes.** A workaround that stopped working, a new failure mode, or
  a cleaner fix than what's in [docs/GOTCHAS.md](docs/GOTCHAS.md).
- 🛠️ **Script/doc improvements.** Make the tools more robust or portable.
- 🌍 **Translations.** Improve or add a language (see below).

## Reporting a hardware result (issue template)

Open an issue titled `result: <chip> / <distro> / <works|fails>` and include:

```
- CPU / NPU:        e.g. Ryzen 7 7840U (Phoenix, XDNA1)
- OS / kernel:      e.g. Ubuntu 26.04 / 7.0.0
- amdxdna driver:   in-tree | out-of-tree (version)
- XRT version:      e.g. 2.21.75      NPU firmware: e.g. 1.5.5.391
- check-npu.sh:     which lines were green/red
- Build:            success? compiler used, time, any patched flags
- Run:              i32 ✓/✗   bf16 ✓/✗   (paste the result line or error)
- Benchmark:        optional, paste the table row(s)
- Notes:            anything you had to change vs this repo
```

Even a clean "worked as written on <chip>" is genuinely useful data.

## Dev setup

```bash
./scripts/build.sh                 # builds iree-amd-aie with all workarounds
./scripts/run-matmul.sh i32        # sanity check on the NPU
BENCH=1 ./scripts/run-matmul.sh bf16
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

This repo documents *getting compute running on XDNA1 NPUs on Linux*. Upstream
bugs belong in [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie).
Be respectful and assume good faith — we're all reverse-engineering the same
under-documented hardware together.
