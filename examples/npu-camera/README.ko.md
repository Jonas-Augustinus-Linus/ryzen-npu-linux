**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — 상시 동작 NPU 비디오 필터 → 가상 카메라

![npu-camera demo](../../docs/media/npu-camera.gif)

비디오를 캡처해 **모든 프레임을 XDNA1 NPU로 처리**한 뒤, 그 결과를
`/dev/video10` 가상 카메라(Zoom / Chrome / OBS / Meet에서 사용 가능)로 내보냅니다.

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

측정값: 프레임당 2회의 NPU 디스패치로 **30 fps**,
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner)를 통해 동작합니다(한 번만 로드하는 ctypes,
호출당 ~4 ms — 호출마다 `iree-run-module`을 실행하는 비용이 아님).

> 여기서 사용하는 NPU 연산은 프레임마다 실제로 수행되는 2D 블러(matmul)입니다. 진정한 *배경* 블러는
> 세그멘테이션 conv 모델로 교체하면 됩니다 — 캡처→NPU→가상 카메라 배관은
> 동일하며, `.vmfb`와 `process()`만 바뀝니다.

## 사전 준비

1. `iree-amd-aie` 빌드 완료([`../../scripts/build.sh`](../../scripts/build.sh)).
2. 가상 카메라 `/dev/video10`(서명된 v4l2loopback):
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools python3-gi
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   (`/etc/modules-load.d/` + `/etc/modprobe.d/`로 영구 적용; 레포의 설정 노트 참고).
3. NPU 브리지 빌드: `(cd ../../tools/npu-runner && ./build_lib.sh)`.
4. NPU 커널: `~/src/iree-amd-aie/run_npu_matmul.sh 2 3 && cp /tmp/matmul_npu.vmfb ./matmul.vmfb`
   (영구 사본 — `/tmp`은 부팅 시 초기화됨).

## 실행

```bash
# system python3 (it has gi + numpy; the uv build-venv can't load gi — ABI)
/usr/bin/python3 npu_camera.py          # default: videotestsrc -> NPU -> /dev/video10
CAM=/dev/video0 /usr/bin/python3 npu_camera.py   # your real webcam
```
확인: `ffplay /dev/video10`(또는 Zoom/Meet/OBS에서 **“NPU Camera”** 선택).

## 상시 동작 서비스로 설치

```bash
cp npu-camera.service ~/.config/systemd/user/        # edit ExecStart path if needed
cp npu-camera.env.example ~/.config/npu-camera.env   # set CAM=/dev/videoN
systemctl --user daemon-reload
systemctl --user enable --now npu-camera             # auto-starts at login
systemctl --user disable --now npu-camera            # turn off
```

## 참고

- **시스템 Python 3**(`/usr/bin/python3`) — `gi`(GStreamer)+`numpy`를 갖추고 있음; uv
  build-venv는 `gi`를 로드할 수 없음(ABI 불일치).
- 환경 변수 오버라이드: `CAM`(기본값은 테스트 패턴), `W`, `H`, `OUT`, `NPU_VMFB`,
  `NPU_RUNNER_DIR`.
