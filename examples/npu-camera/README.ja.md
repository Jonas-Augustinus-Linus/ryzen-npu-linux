**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — 常時稼働の NPU ビデオフィルター → 仮想カメラ

![npu-camera demo](../../docs/media/npu-camera.gif)

ビデオをキャプチャし、**すべてのフレームを XDNA1 NPU で処理**して、その結果を
`/dev/video10` 仮想カメラ（Zoom / Chrome / OBS / Meet で利用可能）に出力します。

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

実測値: 1 フレームあたり 2 回の NPU ディスパッチで **30 fps**。
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner) を利用（一度だけロードする ctypes、
1 回あたり約 4 ms — 呼び出しごとの `iree-run-module` のコストではありません）。

> ここでの NPU 演算は、フレームごとに実際に行う 2D ブラー（matmul）です。本物の*背景*ブラーは
> セグメンテーション用の conv モデルに差し替えるだけです — キャプチャ→NPU→仮想カメラの配管は
> まったく同一で、変わるのは `.vmfb` と `process()` だけです。

## 前提条件

1. `iree-amd-aie` をビルド済みであること（[`../../scripts/build.sh`](../../scripts/build.sh)）。
2. 仮想カメラ `/dev/video10`（署名済みの v4l2loopback）:
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools python3-gi
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   （`/etc/modules-load.d/` + `/etc/modprobe.d/` で永続化します。リポジトリのセットアップノートを参照）。
3. NPU ブリッジをビルド済みであること: `(cd ../../tools/npu-runner && ./build_lib.sh)`。
4. NPU カーネル: `~/src/iree-amd-aie/run_npu_matmul.sh 2 3 && cp /tmp/matmul_npu.vmfb ./matmul.vmfb`
   （永続的なコピー — `/tmp` は起動時に消去されます）。

## 実行

```bash
# system python3 (it has gi + numpy; the uv build-venv can't load gi — ABI)
/usr/bin/python3 npu_camera.py          # default: videotestsrc -> NPU -> /dev/video10
CAM=/dev/video0 /usr/bin/python3 npu_camera.py   # your real webcam
```
確認: `ffplay /dev/video10`（または Zoom/Meet/OBS で **「NPU Camera」** を選択）。

## 常時稼働サービスとしてインストール

```bash
cp npu-camera.service ~/.config/systemd/user/        # edit ExecStart path if needed
cp npu-camera.env.example ~/.config/npu-camera.env   # set CAM=/dev/videoN
systemctl --user daemon-reload
systemctl --user enable --now npu-camera             # auto-starts at login
systemctl --user disable --now npu-camera            # turn off
```

## ノート

- **システムの Python 3**（`/usr/bin/python3`）— `gi`（GStreamer）+`numpy` を備えています。uv の
  build-venv は `gi` をロードできません（ABI の不一致）。
- 環境変数によるオーバーライド: `CAM`（デフォルトはテストパターン）、`W`、`H`、`OUT`、`NPU_VMFB`、
  `NPU_RUNNER_DIR`。
