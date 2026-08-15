# Local RAG sidecar — put the NPU inside a real retrieval loop

This is a **real NPU-in-the-RAG-loop integration**, small enough to inspect:

```text
Markdown / text ──CPU deterministic chunk + SHA-256 hashed BoW──▶ A[256,256]
query           ──CPU SHA-256 hashed BoW────────────────────────▶ B[256,256]
                                                          column 0 = query
                         persistent XDNA NPU: A @ B (bf16 → f32)
                                           │
                                           ▼
                              CPU top-k + context assembly
                                           │
                            optional OpenAI-compatible local LLM
```

The code loads one device-specific VMFB once through
[`tools/npu-runner/npu.py`](../../tools/npu-runner/npu.py), then calls its
`matmul_bf16` path persistently. The NPU produces all **65,536 output elements**
in the fixed 256×256 result; the application reads document scores from query
column 0. `run.sh` creates the kernel through the repository's already verified
`scripts/run-matmul.sh bf16 256 256 256` contract.

## What this proves — and what it does not

- **Real integration:** document/query preprocessing feeds an actual NPU
  dispatch, whose result directly determines the context shown to the user or
  sent to a local model.
- **CPU work:** UTF-8 loading, deterministic ≤256-token chunks, stable SHA-256
  feature hashing, top-k selection, context assembly, and any LLM call remain on
  the CPU. **NPU work:** the dense retrieval score matrix.
- **Transparent baseline:** this is signed hashed bag-of-words, L2-normalized and
  rounded to bf16. It is **not a trained embedding model or a production
  retriever**. Its value is a reproducible, dependency-light integration point
  that can later accept learned embeddings or a quantized projection.
- **Performance honesty:** for one query and a small corpus, a CPU dot product is
  likely faster. The example demonstrates persistent dispatch, correctness, and
  a composable local-AI split; it is not a claim that this shape wins every
  latency benchmark.
- The matrix has room for 256 document chunks and 256 query columns, but this
  reference deliberately uses only column 0 so the data path stays obvious.

## Run the proof first

The CPU-only path checks the deterministic chunking, hashing, meaningful
retrieval fixtures, full matrix finiteness, top-k behavior, and repeated-call
p50/p95 without touching the device:

```bash
./run.sh --cpu-only --selftest
```

The live path detects `npu1_4col` or `npu4`, creates an atomic
toolchain-and-target-keyed cache entry outside the repository, builds
`libnpu.so` if needed, and keeps one NPU context open across all calls:

```bash
./run.sh --selftest
```

For each of three meaningful queries it compares every one of the NPU's 65,536
outputs with a bf16-rounded-input/f32-accumulating CPU oracle. Non-finite output,
more than 5% normalized-max error, semantic-fixture failure, or any top-k order
difference makes the command exit nonzero. It also reports persistent-call p50
and p95 latency. Set `RAG_REBUILD=1` to force a fresh VMFB.

### Verification status

- **XDNA2 / `npu4` (Strix Point), final-candidate rerun on 2026-08-16:** three queries × seven
  persistent calls passed all 65,536-output finite/oracle checks and exact top-3
  parity. Worst normalized-max errors were **0.138%, 0.149%, and 0.115%** (5%
  gate). Dispatch timings varied materially across diagnostic reruns, so they
  are printed for local observation but are not published as a CPU speedup or
  energy result. A separate ordinary query over this Open NPU Lab document also
  passed exact top-3 parity and all 65,536 checks. The preceding VMFB build
  matched all 65,536 splat-reference outputs exactly.
- **XDNA1 / `npu1_4col` (Phoenix, including the Ryzen 7 7840U path):** the
  repository has historical live results for the same persistent runner and
  bf16 matmul building blocks. A rerun of this complete sidecar against the
  current locked toolchain remains outstanding; do not read the XDNA2 result as
  a new XDNA1 hardware claim.

## Search your own Markdown and text

Files are read in stable path order and split into at most 256 lexical tokens
and 16 Ki characters per chunk. Directories are traversed recursively; `.md`,
`.markdown`, and `.txt` are accepted. Corpus symlinks are rejected rather than
following them outside the chosen roots. The bounded reader allows at most 512
supported candidate file paths (hard-link aliases count toward the limit),
8 MiB per unique file, 16 MiB total input, 256 chunks, and a 16 Ki-character
query. It fails instead of silently truncating a limit or skipping an
unreadable directory.

```bash
./run.sh \
  --corpus ../../docs \
  --query "How does the persistent NPU runner avoid launch overhead?" \
  --top-k 3
```

Before printing or sending context, a normal NPU query checks all 65,536 output
values against the CPU oracle, enforces the documented 5% normalized-maximum
tolerance, and requires exact top-k parity. The selected context is always
printed, so the example remains useful without an LLM server. Add more
`--corpus` or `--query` options as needed.

## Optional local OpenAI-compatible model

Model invocation is off by default. Supply both the complete chat-completions
URL and a model name explicitly:

```bash
./run.sh \
  --corpus ~/notes \
  --query "Summarize the power-measurement procedure" \
  --endpoint http://127.0.0.1:11434/v1/chat/completions \
  --model my-local-model
```

Only the literal loopback addresses `127.0.0.1` and `::1` are accepted by
default. Hostnames—including `localhost`, whose resolver mapping can be
changed—and non-loopback addresses require the conspicuous `--allow-remote`
flag. Environment-configured HTTP proxies are disabled, redirects are rejected,
`--timeout` is a total
wall-clock deadline enforced by a disposable transport process, and responses
are size-limited (2 MiB by default). No credential is read by default. If you
explicitly pass, for example,
`--api-key-env OPENAI_API_KEY`, that environment value is sent as a bearer
token; an unset/empty explicit variable is an error. Key values must be bounded
printable ASCII without whitespace or control characters. The program does not print the API key, request headers, serialized
request, server reason text, or an endpoint error body that might echo them. It
**does** intentionally print the selected context and model answer to stdout,
with terminal control and bidirectional-format characters escaped;
redirect or capture output only where that text is safe. Endpoint errors exit
nonzero. The endpoint path also bounds the model name, query, selected context,
and 48 MiB serialized helper request; it fails explicitly instead of allocating
or sending an unbounded prompt.

Sending context to a remote endpoint is a data disclosure. `--allow-remote`
makes that decision explicit; it does not make the remote service private.

## Dependencies and cache

Use the same built and pinned `iree-amd-aie` checkout as the rest of this
repository. `RAG_VENV` (or `IREE_VENV`) must contain NumPy and, for NPU calls,
`ml_dtypes`. The default compiled module is:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/ryzen-npu-linux/local-rag-sidecar/
  matmul_bf16_256x256x256.<target>.<toolchain-key>.vmfb
```

Overrides: `IREE_AMD_AIE_ROOT`, `RAG_VENV`, `RAG_CACHE_DIR`, `RAG_VMFB`,
`LIBNPU`, and `RAG_REBUILD=1`.

The default VMFB key covers the canonical checkout and Git revision, detected
target and geometry, fixed matrix recipe, compiler/run-module/Peano binaries,
the checkout-owned Peano compiler libraries, IREE compiler library, CMake
cache, and the repository scripts that generate the MLIR and select the target.
A toolchain or recipe change therefore cannot silently reuse an older
target-only module. `RAG_VMFB` is an explicit expert override; every query
still has to pass the complete CPU-reference gate before its ranking can be
used.

The default shared-library bridge is also stored outside the repository under
a key derived from the canonical IREE checkout, source revision, bridge source,
CMake cache, host compiler, and every directly linked archive's metadata. The
builder publishes it with an
atomic rename, so an interrupted or different-toolchain build cannot be reused
as a merely nonempty `libnpu.so`. `LIBNPU` remains an explicit expert override.

The hardware-free regression suite fixes the chunk/hash layout, fail-closed CPU
oracle, symlink boundary, local/remote endpoint policy, proxy bypass, redirect
rejection, and response cap in place. CI installs the exact NumPy version from
`versions.lock` and runs:

```bash
python test_local_rag_sidecar.py
```

## License

This example is part of `ryzen-npu-linux` and inherits its **MIT License**.
Anyone may use, copy, modify, merge, publish, distribute, sublicense, or sell it
under the license terms. No generated VMFB, shared library, corpus, prompt, or
model response is committed by this example.
