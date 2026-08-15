#!/usr/bin/env python3
"""
Wake-word detector whose dense layers run on an AMD XDNA1 or XDNA2 NPU.

This is a *template*, not a trained model. It shows the real, working split for
running an always-on keyword spotter on a Ryzen AI NPU under Linux:

    audio ──▶ log-mel features      (CPU, numpy)
          ──▶ Dense(W1) ─ ReLU ─ Dense(W2) ─ ReLU ─ Dense(W3)
                  └─NPU─┘  └CPU┘   └─NPU─┘  └CPU┘   └─NPU─┘
          ──▶ score ──▶ threshold ──▶ "wake!"      (CPU)

Each Dense layer is a 128x128x128 i32 matmul executed through the persistent
IREE C API bridge (one loaded module, repeated dispatches). ReLU + a fixed-point
requant shift stay on the CPU: dense math on the NPU, lightweight glue on CPU.

The weights here are ILLUSTRATIVE (a matched filter in --selftest), so the demo
visibly separates a target pattern from noise and proves the NPU pipeline end to
end. To detect a *real* wake word, train a small MLP head (e.g. openWakeWord
style) and drop your learned W1/W2/W3 in as int32 .npy — the NPU path is unchanged.

Usage:
    ./run.sh --selftest                 # build matched-filter weights, prove it works
    ./run.sh --wav sample.wav           # run on a WAV (random weights unless --weights)
    ./run.sh --selftest --threshold 500
"""
import argparse
import os
import sys

import numpy as np

DIM = 128            # feature dim == hidden dim == matmul K/N (NPU tile size)
FRAMES = 128         # frames per window == matmul M (batch; amortizes dispatch)
ROOT = os.path.dirname(os.path.abspath(__file__))
VMFB = os.environ.get("KWS_VMFB", os.path.join(ROOT, "dense_npu.vmfb"))
RUNNER = os.environ.get(
    "NPU_RUNNER_DIR",
    os.path.normpath(os.path.join(ROOT, "..", "..", "tools", "npu-runner")),
)
sys.path.insert(0, RUNNER)
from npu import NPU  # noqa: E402

_NPU = None

# ───────────────────────── NPU dense layer ──────────────────────────
def npu_dense(A: np.ndarray, W: np.ndarray) -> np.ndarray:
    """out = A @ W, computed on the NPU. A,W are int32 [128,128]; returns int32 [128,128]."""
    if _NPU is None:
        raise RuntimeError("NPU context is not open")
    if A.shape != (FRAMES, DIM) or W.shape != (DIM, DIM):
        raise ValueError(
            f"dense requires ({FRAMES}, {DIM}) @ ({DIM}, {DIM}); "
            f"got {A.shape} @ {W.shape}"
        )
    return _NPU.matmul(A, W)

def relu_requant(x: np.ndarray, shift: int) -> np.ndarray:
    """CPU elementwise: ReLU then a fixed-point downscale (keeps int32 from overflowing)."""
    return np.maximum(x, 0) >> shift

def mlp_forward(X, W1, W2, W3, shifts=(4, 0, 0)):
    """3 NPU matmuls + 2 CPU ReLU/requant. Returns per-frame score = output column 0."""
    print(f"  [NPU] Dense 1: {X.shape} @ {W1.shape}")
    h1 = relu_requant(npu_dense(X,  W1), shifts[0])
    print(f"  [NPU] Dense 2: {h1.shape} @ {W2.shape}")
    h2 = relu_requant(npu_dense(h1, W2), shifts[1])
    print(f"  [NPU] Dense 3: {h2.shape} @ {W3.shape}")
    out = npu_dense(h2, W3) >> shifts[2]
    return out[:, 0]                      # column 0 = "wake" logit per frame

# ─────────────────────── CPU log-mel front-end ──────────────────────
def mel_filterbank(n_fft, n_mels, sr):
    """Minimal triangular mel filterbank (numpy only, no librosa)."""
    f = lambda m: 700*(10**(m/2595)-1)
    m = lambda f_: 2595*np.log10(1+f_/700)
    pts = f(np.linspace(m(0), m(sr/2), n_mels+2))
    bins = np.floor((n_fft+1)*pts/sr).astype(int)
    fb = np.zeros((n_mels, n_fft//2+1))
    for i in range(1, n_mels+1):
        l, c, r = bins[i-1], bins[i], bins[i+1]
        for k in range(l, c): fb[i-1, k] = (k-l)/max(c-l, 1)
        for k in range(c, r): fb[i-1, k] = (r-k)/max(r-c, 1)
    return fb

def log_mel(signal, sr=16000, n_fft=256, hop=128, n_mels=DIM):
    """signal -> [frames, n_mels] log-mel. Pads/trims to FRAMES rows."""
    fb = mel_filterbank(n_fft, n_mels, sr)
    win = np.hanning(n_fft)
    frames = []
    for start in range(0, max(len(signal)-n_fft, 0)+1, hop):
        seg = signal[start:start+n_fft]
        if len(seg) < n_fft: break
        spec = np.abs(np.fft.rfft(seg*win))**2
        frames.append(np.log1p(fb @ spec))
    if not frames: frames = [np.zeros(n_mels)]
    M = np.stack(frames)
    M = M[:FRAMES] if len(M) >= FRAMES else np.pad(M, ((0, FRAMES-len(M)), (0, 0)))
    return M

def quantize(features, levels=15):
    """Per-window min-max quantize log-mel -> int32 in [0, levels]. (Toy uniform quant.)"""
    lo, hi = features.min(), features.max()
    q = (features - lo) / (hi - lo + 1e-9)
    return np.clip(np.round(q*levels), 0, levels).astype(np.int32)

# ─────────────────────────── synth audio ────────────────────────────
def synth(kind, sr=16000, dur=1.0):
    """A toy 'wake word' = a 3-tone chirp; 'noise' = white noise. Real use: a WAV."""
    t = np.linspace(0, dur, int(sr*dur), endpoint=False)
    if kind == "wake":
        s = sum(np.sin(2*np.pi*fz*t) for fz in (450, 900, 1800))
        s *= np.clip(np.minimum(t, dur-t)*20, 0, 1)   # 50 ms fade in/out
    else:
        # A fixed seed makes the public self-test and its pass/fail result
        # reproducible instead of depending on process-global RNG state.
        s = np.random.default_rng(0).standard_normal(len(t))
    return s/(np.abs(s).max()+1e-9)

# ─────────────────────────── detection ──────────────────────────────
def detect(signal, W1, W2, W3, threshold, label=""):
    feats = quantize(log_mel(signal))
    scores = mlp_forward(feats, W1, W2, W3)
    peak = int(scores.max())
    hit = threshold is not None and peak >= threshold
    tag = ("🔔 WAKE" if hit else "· below thr") if threshold is not None else "(score)"
    print(f"  → {label:<12} peak score = {peak:>6}   {tag}")
    return peak, hit

def make_template():
    """A zero-mean matched filter from the synthetic wake word.
    Zero-mean is the trick: a flat/featureless input (white noise after min-max
    quant) dots to ~0, while the peaky wake spectrum dots to a large positive
    value — so ReLU after layer 1 cleanly suppresses noise."""
    pat = quantize(log_mel(synth("wake"))).mean(0).astype(np.float64)  # mean pattern [DIM]
    pat -= pat.mean()
    return np.clip(np.round(pat * (15/(np.abs(pat).max()+1e-9))), -15, 15).astype(np.int32)

def matched_filter_weights(template):
    """Illustrative weights: W1 col0 = matched filter; W2/W3 = identity passthrough."""
    W1 = np.zeros((DIM, DIM), np.int32); W1[:, 0] = template
    I = np.eye(DIM, dtype=np.int32)
    return W1, I.copy(), I.copy()

# ─────────────────────────────── main ───────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Wake-word detector with dense layers on an AMD XDNA NPU")
    ap.add_argument("--selftest", action="store_true", help="matched-filter demo: target vs noise")
    ap.add_argument("--wav", help="WAV file (16 kHz mono) to score")
    ap.add_argument("--weights", help="npz with W1,W2,W3 int32 (else random / matched-filter)")
    ap.add_argument("--threshold", type=int, default=400)
    args = ap.parse_args()

    if not os.path.exists(VMFB):
        sys.exit(f"NPU module not built: {VMFB}\nRun ./run.sh (it compiles dense_npu.mlir first).")

    if not args.selftest and not args.wav:
        ap.error("pass --selftest or --wav FILE")

    if args.weights:
        z = np.load(args.weights)
        W1, W2, W3 = z["W1"], z["W2"], z["W3"]
    elif args.selftest:
        W1, W2, W3 = matched_filter_weights(make_template())
    else:                                       # random untrained head
        rng = np.random.default_rng(0)
        W1, W2, W3 = (rng.integers(0, 3, (DIM, DIM), dtype=np.int32) for _ in range(3))

    generation = os.environ.get("NPU_GENERATION", "XDNA")
    vbnv = os.environ.get("NPU_VBNV", "auto-detected")
    print(f"NPU device : {generation} ({vbnv})")
    print(f"NPU module : {VMFB}")
    print(f"threshold  : {args.threshold}\n")

    global _NPU
    _NPU = NPU(VMFB, "module.dense")
    try:
        if args.selftest:
            print("Self-test — identical NPU pipeline on a target pattern vs background noise:")
            p, _ = detect(synth("wake"), W1, W2, W3, None, "wake word")
            n, _ = detect(synth("noise"), W1, W2, W3, None, "background")
            sugg = (p + n) // 2
            print()
            if p >= 2 * max(n, 1):
                print(f"RESULT: ✅ clear separation (wake {p} ≫ noise {n}) — the persistent 3-dispatch NPU MLP works.")
                print(f"        Pick a threshold around {sugg}:  ./run.sh --wav your.wav --threshold {sugg}")
                result = 0
            else:
                print(f"RESULT: ⚠️ weak separation (wake {p} vs noise {n}); these are illustrative weights — train a real head.")
                result = 1
        else:
            sig = load_wav(args.wav)
            detect(sig, W1, W2, W3, args.threshold, os.path.basename(args.wav))
            result = 0
    finally:
        _NPU.close()
        _NPU = None
    return result

def load_wav(path):
    import wave
    with wave.open(path, "rb") as w:
        sr, n, channels, width = (
            w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
        )
        if sr != 16000 or channels not in (1, 2) or width != 2:
            raise ValueError(
                "WAV must be 16 kHz, 16-bit PCM, mono or stereo; "
                f"got {sr} Hz, {8 * width}-bit, {channels} channel(s)"
            )
        raw = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32)
    if channels == 2:
        raw = raw.reshape(-1, 2).mean(1)
    return raw/32768.0

if __name__ == "__main__":
    raise SystemExit(main())
