**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — always-on NPU video filter → virtual camera

![npu-camera demo](../../docs/media/npu-camera.gif)

Captures video, runs **every frame through an XDNA1 or XDNA2 NPU**, and publishes the
result to the `/dev/video10` virtual camera (usable by Zoom / Chrome / OBS / Meet).

> The recording above was made on XDNA1. The same source now uses the runner's
> runtime geometry discovery and a device-matched VMFB on XDNA1 or Strix Point npu4.

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

Original XDNA1 measurement: **30 fps** with 2 NPU dispatches/frame, via
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner) (load-once ctypes,
~4 ms/call — not the per-call `iree-run-module` cost).
The npu4 processing function is hardware-correctness-tested; no XDNA2 camera FPS
is claimed yet.

> The NPU op here is a real per-frame 2D blur (matmul). A true *background* blur
> swaps in a segmentation conv model — the capture→NPU→virtual-cam plumbing is
> identical; only the `.vmfb` and `process()` change.

## Prerequisites

1. Built `iree-amd-aie` ([`../../scripts/build.sh`](../../scripts/build.sh)).
2. The virtual camera `/dev/video10` (signed v4l2loopback):
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools \
       python3-gi python3-numpy
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   (persist via `/etc/modules-load.d/` + `/etc/modprobe.d/`; see the repo's setup notes).
3. The NPU bridge built: `(cd ../../tools/npu-runner && ./build_lib.sh)`.
4. A kernel compiled for the NPU currently installed in the machine:
   ```bash
   VMFB_OUT="$PWD/matmul.vmfb" ../../scripts/run-matmul.sh i32 128 128 128 2 3
   ```
   `run-matmul.sh` detects XDNA1 (`npu1_4col`) or Strix Point XDNA2 (`npu4`)
   and also compares every output element with its CPU reference before saving it.

## Run

```bash
# system python3 (it has gi + numpy; the uv build-venv can't load gi — ABI)
/usr/bin/python3 npu_camera.py          # default: videotestsrc -> NPU -> /dev/video10
CAM=/dev/video0 /usr/bin/python3 npu_camera.py   # your real webcam
```
Verify: `ffplay /dev/video10` (or pick **“NPU Camera”** in Zoom/Meet/OBS).

## Install as an always-on service

```bash
cp npu-camera.service ~/.config/systemd/user/        # edit ExecStart path if needed
cp npu-camera.env.example ~/.config/npu-camera.env   # set CAM=/dev/videoN
systemctl --user daemon-reload
systemctl --user enable --now npu-camera             # auto-starts at login
systemctl --user disable --now npu-camera            # turn off
```

## Notes

- **System Python 3** (`/usr/bin/python3`) — has `gi`(GStreamer)+`numpy`; the uv
  build-venv can't load `gi` (ABI mismatch).
- Env overrides: `CAM` (default test pattern), `W`, `H`, `OUT`, `NPU_VMFB`,
  `NPU_RUNNER_DIR`.
