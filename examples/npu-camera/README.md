**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — always-on NPU video filter → virtual camera

![npu-camera demo](../../docs/media/npu-camera.gif)

Captures video, runs **every frame through the XDNA1 NPU**, and publishes the
result to the `/dev/video10` virtual camera (usable by Zoom / Chrome / OBS / Meet).

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

Measured: **30 fps** with 2 NPU dispatches/frame, via
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner) (load-once ctypes,
~4 ms/call — not the per-call `iree-run-module` cost).

> The NPU op here is a real per-frame 2D blur (matmul). A true *background* blur
> swaps in a segmentation conv model — the capture→NPU→virtual-cam plumbing is
> identical; only the `.vmfb` and `process()` change.

## Prerequisites

1. Built `iree-amd-aie` ([`../../scripts/build.sh`](../../scripts/build.sh)).
2. The virtual camera `/dev/video10` (signed v4l2loopback):
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools python3-gi
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   (persist via `/etc/modules-load.d/` + `/etc/modprobe.d/`; see the repo's setup notes).
3. The NPU bridge built: `(cd ../../tools/npu-runner && ./build_lib.sh)`.
4. The NPU kernel: `~/src/iree-amd-aie/run_npu_matmul.sh 2 3 && cp /tmp/matmul_npu.vmfb ./matmul.vmfb`
   (a persistent copy — `/tmp` is wiped on boot).

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
