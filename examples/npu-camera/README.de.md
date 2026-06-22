**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — Always-on-Videofilter auf der NPU → virtuelle Kamera

![npu-camera demo](../../docs/media/npu-camera.gif)

Erfasst Video, schickt **jeden Frame durch die XDNA1-NPU** und veröffentlicht das
Ergebnis an die virtuelle Kamera `/dev/video10` (nutzbar mit Zoom / Chrome / OBS / Meet).

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

Gemessen: **30 fps** mit 2 NPU-Dispatches/Frame, über
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner) (einmaliges Laden per ctypes,
~4 ms/Aufruf — nicht die Kosten von `iree-run-module` pro Aufruf).

> Die NPU-Operation hier ist ein echter 2D-Blur pro Frame (matmul). Ein echter
> *Hintergrund*-Blur tauscht ein Segmentierungs-Conv-Modell ein — die Pipeline
> capture→NPU→virtuelle Kamera ist identisch; nur `.vmfb` und `process()` ändern sich.

## Voraussetzungen

1. `iree-amd-aie` gebaut ([`../../scripts/build.sh`](../../scripts/build.sh)).
2. Die virtuelle Kamera `/dev/video10` (signiertes v4l2loopback):
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools python3-gi
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   (dauerhaft über `/etc/modules-load.d/` + `/etc/modprobe.d/`; siehe die Setup-Hinweise des Repos).
3. Die NPU-Brücke gebaut: `(cd ../../tools/npu-runner && ./build_lib.sh)`.
4. Der NPU-Kernel: `~/src/iree-amd-aie/run_npu_matmul.sh 2 3 && cp /tmp/matmul_npu.vmfb ./matmul.vmfb`
   (eine dauerhafte Kopie — `/tmp` wird beim Booten geleert).

## Ausführen

```bash
# system python3 (it has gi + numpy; the uv build-venv can't load gi — ABI)
/usr/bin/python3 npu_camera.py          # default: videotestsrc -> NPU -> /dev/video10
CAM=/dev/video0 /usr/bin/python3 npu_camera.py   # your real webcam
```
Überprüfen: `ffplay /dev/video10` (oder in Zoom/Meet/OBS **„NPU Camera“** auswählen).

## Als Always-on-Dienst installieren

```bash
cp npu-camera.service ~/.config/systemd/user/        # edit ExecStart path if needed
cp npu-camera.env.example ~/.config/npu-camera.env   # set CAM=/dev/videoN
systemctl --user daemon-reload
systemctl --user enable --now npu-camera             # auto-starts at login
systemctl --user disable --now npu-camera            # turn off
```

## Hinweise

- **System-Python 3** (`/usr/bin/python3`) — hat `gi`(GStreamer)+`numpy`; die
  uv-build-venv kann `gi` nicht laden (ABI-Mismatch).
- Env-Overrides: `CAM` (Standard ist Testmuster), `W`, `H`, `OUT`, `NPU_VMFB`,
  `NPU_RUNNER_DIR`.
