# Wake-word detector — persistent dense layers on XDNA1/XDNA2

![wake-word selftest demo](../../docs/media/wake-word.gif)

A runnable **template** for an always-on keyword spotter whose fully-connected
layers execute **on an XDNA1 or Strix Point XDNA2 NPU** under Linux. The GIF is
the original XDNA1 recording; the current source is also live-verified on npu4.
Wake-word / KWS is the
single best agent-side fit for this NPU (tiny, runs forever, perf-per-watt is the
whole point — see [`../../docs/APPLICATIONS.md`](../../docs/APPLICATIONS.md)).

```
audio ─▶ log-mel features ─▶ Dense(W1)─ReLU ─ Dense(W2)─ReLU ─ Dense(W3) ─▶ score ─▶ threshold ─▶ "wake!"
         └───── CPU ─────┘    └─NPU─┘ └CPU┘   └─NPU─┘ └CPU┘   └─NPU─┘       └──────── CPU ────────┘
```

Each `Dense` layer is one **128×128×128 i32 matmul dispatched to the NPU** through
the persistent IREE C API bridge: the device and VMFB load once, then all six
self-test dispatches reuse that context without subprocess or `.npy` I/O. ReLU
and a fixed-point requant shift run on the CPU — **dense math on the NPU, glue on
the CPU.**

## Run it

```bash
# First build iree-amd-aie from the repo root (../../scripts/build.sh).
cd examples/wake-word
./run.sh --selftest            # detects target, compiles, CPU-checks, runs persistently
```

Expected (the 3 `[NPU] Dense …` lines are real NPU dispatches):

```
  → wake word    peak score =     94   (score)
  → background   peak score =     31   (score)

RESULT: ✅ clear separation (wake 94 ≫ noise 31) — the persistent 3-dispatch NPU MLP works.
        Pick a threshold around 62:  ./run.sh --wav your.wav --threshold 62
```

Score a real recording (16 kHz mono WAV):

```bash
./run.sh --wav your.wav --threshold 62
```

## What's real here, and what isn't

**Real:** the three matmuls genuinely run on the NPU (kill the device and it
errors; the math is verified — same `i32` matmul as [`../matmul_i32.mlir`](../matmul_i32.mlir)).
The log-mel front-end is a real (numpy-only) STFT→mel→log pipeline.

**Illustrative:** the **weights are not trained.** `--selftest` builds a
*matched filter* — a zero-mean template of the synthetic wake tone placed in `W1`,
with `W2`/`W3` as identity. Zero-mean is the trick that makes it work: a flat,
featureless spectrum (white noise after min-max quant) dots to ≈0 and ReLU kills
it, while the peaky wake spectrum dots to a large positive score. It proves the
**pipeline**, not a real vocabulary.

## Make it detect *your* wake word

The NPU path never changes — only the weights do:

1. Train a tiny MLP head (e.g. [openWakeWord](https://github.com/dscripka/openWakeWord)-style:
   mel/embedding features → 3 FC+ReLU layers → 1 logit).
2. Quantize each layer's weight matrix to `int32`, shaped `128×128` (pad/tile to
   the NPU size), and save them:
   ```python
   np.savez("model.npz", W1=W1.astype("int32"), W2=W2.astype("int32"), W3=W3.astype("int32"))
   ```
3. Run with your weights — same NPU dispatches:
   ```bash
   ./run.sh --wav your.wav --weights model.npz --threshold <your_value>
   ```

## Honest limitations (and how a production build differs)

- **`i32`, not `bf16`.** This fixed 128³ kernel gives one exact, common
  correctness path on `npu1_4col` and `npu4`. For a larger trained model, compare
  the device-specific bf16/quantized pipelines and record a justified tolerance.
- **ReLU is on the CPU.** Fusing matmul+ReLU into one NPU dispatch currently fails
  in the AIE backend (BD-id allocation), so the elementwise stays on the CPU. It's
  nanoseconds — not the bottleneck.
- **Per-frame, no temporal context.** Real KWS stacks frames or uses a small conv
  for time context; this template classifies frames independently for clarity.
- **The runtime is persistent, but this remains a template.** A production KWS
  should reuse/batch audio buffers too, then connect the detector to PipeWire
  (`pw_filter`) so it listens on the real microphone without a file boundary.

## Files

| File | Role |
|---|---|
| [`dense_npu.mlir`](dense_npu.mlir) | The one NPU op: a 128×128×128 `i32` dense/Linear layer. |
| [`wake_word.py`](wake_word.py) | CPU front-end + 3× NPU dispatch + ReLU/requant + detection. |
| [`run.sh`](run.sh) | Detects XDNA1/npu4, compiles and CPU-checks the module, builds the bridge, then runs. |

> Needs a built `iree-amd-aie` (`../../scripts/build.sh`) and the
> `~/src/iree-aie-venv` Python env (numpy). Override paths with `IREE_AMD_AIE_ROOT`,
> `IREE_VENV`/`KWS_VENV`, and `KWS_VMFB`. Each launch compiles into a private
> temporary file beside the destination and atomically replaces the VMFB only
> after success; a failed self-test exits nonzero.
