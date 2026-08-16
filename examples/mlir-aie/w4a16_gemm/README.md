# W4A16 GEMM — int4 AWQ-g128 weights, bf16 activations, on the XDNA2 NPU

A TileFuse-style quantized matrix multiply running on the whole 4×8 Strix
Point array under the fully open stack (mlir-aie 1.4.1 IRON + Peano + Ubuntu's
XRT — no chess, no proprietary kernels):

```
C[bf16] = A[bf16] @ dequant(B[int4, AWQ group-128])
```

Weights stream to each core as **packed 4352-byte tiles** — 4096 B of int4
data plus 128 B bf16 per-column scales plus 128 B int8 zero-points — and are
dequantized *in-core* into a 16 KB weight-stationary L1 cache, then multiplied
through the AIE2P bfp16 datapath. B moves **3.76× less DRAM data** than a bf16
GEMM while A and C stay full bf16 precision.

## Measured on Strix Point hardware (2026-08-16)

Ryzen AI 9 HX PRO 370 · Ubuntu 26.04 · kernel 7.0 · mlir-aie 1.4.1 (Peano) ·
Ubuntu-native XRT 2.21.75 · NPU FW 1.1.2.64. "NPU time" is the runtime's
on-NPU figure; every row also passed its NumPy CPU reference (see below).

| Shape (M×K×N) | Columns | NPU time | Effective throughput | CPU reference |
|---|---|--:|--:|---|
| 512³ | 8 | 158 µs | 1.70 TOPS | PASS |
| 2048³ | 4 | 5.76 ms | 2.98 TOPS | PASS |
| 2048³ | 8 | **2.89 ms** | **5.94 TOPS** | PASS |
| 2048×4096×4096 | 8 | 11.0 ms | **6.24 TOPS** | PASS |

Context on the same machine and array: the stock `whole_array` bf16-via-bfp16
GEMM measures 4.64 TFLOPS at 2048³ and the i8 GEMM 6.65 TOPS
([MLIR-AIE.md](../../../docs/MLIR-AIE.md)). This W4A16 kernel is **28% faster
than the bf16 baseline** while also carrying 4-bit weights, and reaches ~90%
of the i8 record. TileFuse (the paper this kernel comes from) reports 9 TOPS
on Strix with the proprietary chess compiler; the remaining gap here is
Peano-vs-chess kernel scheduling, not dataflow.

Column scaling 4→8 is 1.99× — the design is compute-bound, not DMA-bound.

## Files

- [`mix_int4_ATB.cc`](mix_int4_ATB.cc), [`zero.cc`](zero.cc) — the fused
  dequant+GEMM kernel, vendored **byte-identical** (sha256-pinned, same
  checksums as [`scripts/check-w4a16-compile.sh`](../../../scripts/check-w4a16-compile.sh))
  from [glassescrab/mlir-aie@`8c3d2be`](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
  the TileFuse authors' fork (Apache-2.0 WITH LLVM-exception). Compiled here
  by Peano for `aie2p` with `-Dbf16_bf16_ONLY -DDIM_M=64 -DDIM_K=128
  -DDIM_N=64 -DAIE_API_EMULATE_BFLOAT16_MMUL_WITH_BFP16`.
- [`packing.py`](packing.py) — NumPy packer producing the exact per-tile byte
  layout the kernel reads (verified bit-exact against a scalar model of the
  kernel's load path), plus the dequant + tile-faithful references.
- [`w4a16_gemm.py`](w4a16_gemm.py) — the IRON 1.4.x whole-array design and
  host driver (verify + benchmark).

## How the design differs from the stock `whole_array` GEMM

- **B fifos carry opaque packed bytes.** One 4352 B object per (k=128, n=64)
  tile, no stream-dims transformation; the byte layout is produced host-side
  by `packing.pack_b`. k-tile = AWQ group size, so every tile carries whole
  quantization groups (one scale/zero per output column per tile).
- **The kernel processes half an M-tile per call** (`DIV=2` with an internal
  call counter). Call 0 dequantizes the B tile into the L1 cache and computes
  C rows 0–31; call 1 reuses the cache for rows 32–63. The A L2→L1 fifo
  therefore produces (64, 128) tiles mem-side but cores consume (32, 128)
  halves — IRON 1.4.x's `consumer_obj_type` expresses exactly this, and the
  stock micro-tiled A layout already puts the two halves in consumption order
  (row-blocks are its outermost dimension).
- **B is packed in column-distribution order**, so each column's whole
  per-pass weight stream is a single contiguous DMA fill. A strided
  multi-row B tap is not expressible as a shim buffer descriptor at 2048³
  (the 69632-byte row already takes two of the four dims), and splitting into
  per-row fills exhausts the 16 BDs of a shim tile. The packed blob is
  therefore specific to the deployed column count (`pack_b(..., n_aie_cols)`).
- Everything else — A/C fifos, taps, runtime sequence, 4 shim/mem columns for
  A, C join per column — is the stock whole_array structure.

Core-local memory at depth 2 everywhere: A 16 KB + B 8.5 KB + C 16 KB +
16 KB static L1 weight cache + 3.3 KB stack ≈ 60 KB of the 64 KB budget.

## Numerics: what PASS means here

The verifier compares the NPU result against `A @ dequant(B)` computed in
float32, with dequantization modeled exactly as the kernel does it
(`bf16((q - zp) * scale)` per element). Reported metrics:

- **err / accumulation scale** — `|got − ref| / (|A| @ |B_dq|)`, the natural
  elementwise dot-product error bound. This is the **PASS criterion**
  (default 5e-2; measured max ≈ 9e-3 at 2048³ — bf16/bfp16 level, and a real
  dataflow bug sits ~100× above it).
- plain elementwise relative error vs the f32 reference, and vs a
  "tile-faithful" reference that rounds C to bf16 after every k-tile the way
  the kernel's bf16 C accumulator does — reported for transparency. With
  signed zero-mean inputs these are cancellation-dominated on near-zero
  outputs (the AIE2P bfp16 datapath quantizes 8-value blocks against a shared
  exponent), so they are not used as the acceptance gate. With positive
  inputs — as the upstream matmul tests use — the plain relative error is
  ≤ 2.2e-2 with zero elements outside 5e-2.

## Run

```bash
# one-time: set the mlir-aie track up (see ../../../docs/MLIR-AIE.md)
../../../scripts/setup-mlir-aie.sh

./run.sh                                    # 512³ verify + benchmark
./run.sh -M 2048 -K 2048 -N 2048            # the benchmark shape
./run.sh -M 2048 -K 2048 -N 2048 --n-aie-cols 4
```

Shape constraints: `M % 256 == 0` with `M/256` even, `K % 128 == 0` (whole
AWQ groups), `N % (64 × columns) == 0`, and `N ≤ 4096` (the C write-back
stride `m·4·N` must stay within the shim DMA's 2²⁰ stride limit).
`--n-aie-cols` supports 4 and 8; fewer than 4 columns would need the
stacked-row A split, which this design does not implement.

## Gotchas found while building this (full detail in [GOTCHAS](../../../docs/GOTCHAS.md))

- Without `-DAIE_API_EMULATE_BFLOAT16_MMUL_WITH_BFP16` the kernel's 8×8×8
  bf16 `aie::mmul` compiles fine but lowers through ¼-rate native bf16 MACs:
  0.94 TOPS instead of 5.94 at 2048³.
- Changing an `ExternalFunction`'s `compile_flags` inside a helper function
  does **not** invalidate the `@iron.jit` cache — clear `~/.npu/cache` (or
  rename the object file) when toggling kernel defines.
- Shim-DMA expressibility limits surface as aiecc errors only at larger
  shapes: ≤ 4 BD dims (highest = repeat), 16 BDs per shim tile, strides
  < 2²⁰ elements.
