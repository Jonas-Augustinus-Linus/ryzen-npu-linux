**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-runner — 상주형 XDNA1 NPU 호출기 (IREE runtime C API)

![npu-runner demo](../../docs/media/npu-runner.gif)

`.vmfb`를 **한 번만** 로드한 뒤, 호출마다 `iree-run-module`을 새로 띄우는 대신
프로세스 내부에서 NPU를 여러 번 호출합니다. 7840U에서 측정한 결과: **~3.7 ms/invoke 대
~41 ms/invoke**(서브프로세스 경로) — 약 11배 빠릅니다. XRT 디바이스 오픈 + 프로세스
스폰이 매 호출이 아니라 한 번만 일어나기 때문입니다. 이로써 "벤치마크에서 NPU가 동작한다"가
"상시 가동 KWS / 임베딩 / CNN / 카메라 / 오디오에 NPU를 실제로 쓸 수 있다"로 바뀝니다.

두 가지 형태, 동일한 코어:
- **`npu_runner`** — 독립 실행형 CLI/벤치마크(`npu_runner.cc`).
- **`libnpu.so` + `npu.py`** — ctypes 공유 라이브러리로, **Python**이 NPU를 빠르게
  호출할 수 있게 합니다([`../../examples/npu-camera`](../../examples/npu-camera)와
  [wake-word](../wake-word) 헤드에서 사용).

## Build

빌드된 `iree-amd-aie`가 필요합니다([`../../scripts/build.sh`](../../scripts/build.sh) 참고).
두 빌드 스크립트 모두 `IREE_AMD_AIE_ROOT`(기본값 `~/src/iree-amd-aie`)를 따릅니다.

```bash
./build.sh        # -> npu_runner (CLI)
./build_lib.sh    # -> libnpu.so   (ctypes)
```

## Run

```bash
# make a test module (i32 128x128 @matmul)
~/src/iree-amd-aie/run_npu_matmul.sh 2 3        # -> /tmp/matmul_npu.vmfb (all 768)

./npu_runner /tmp/matmul_npu.vmfb 1000          # 1000 in-process invokes
python3 npu.py /tmp/matmul_npu.vmfb             # Python ctypes self-test -> 768
```

```python
from npu import NPU
npu = NPU("/tmp/matmul_npu.vmfb")               # i32 128x128 @matmul
out = npu.matmul(a, b)                           # a,b int32[128,128] -> int32[128,128]
npu.close()
```

## 알기 어려웠던 점 (다시 부딪히지 않도록)

- **g++, 절대 clang 아님**(clang21은 amdxdna 드라이버 TU에서 ICE 발생), 메인 빌드와 동일.
- **System allocator 매크로:** runtime C API는
  `-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl`가
  정의되어 있을 때만 `iree_allocator_system()`을 선언합니다(빌드는 CMake에서 설정하지만,
  독립 컴파일에서는 직접 넘겨야 합니다).
- **Proactor pool:** amdxdna 디바이스 생성은 비동기 I/O를 위해 proactor pool을
  역참조합니다 — pool이 없으면 segfault가 납니다. `iree_async_proactor_pool_create(1, NULL, …)`로
  하나를 생성하고 `iree_hal_device_create_params_t.proactor_pool`에 설정합니다(runtime의
  `try_create_default_device`가 내부적으로 하는 동작).
- **`n_core_cols = 4`**를 디바이스 파라미터에 명시적으로 설정합니다(5 → ERT state-8
  타임아웃); 독립 실행 프로그램은 `--amdxdna_*` 플래그를 파싱하지 않습니다.
- **링킹:** runtime C API는 `libiree_runtime_unified.a`에 있지만, amdxdna
  드라이버는 거기에 번들되지 않은 몇몇 HAL-utils 아카이브(deferred_command_buffer,
  queue_emulation, queue_host_call_emulation, resource_set, file_transfer)와
  async + proactor_pool을 끌어옵니다. 향후 체크아웃에서 undefined 심볼이 추가되면,
  `nm $BLD/**/*.a | grep ' T <symbol>'`로 해당 아카이브를 찾아 링크 그룹에 추가하세요.

## Files

| File | Role |
|---|---|
| `npu_runner.cc` / `build.sh` | 독립 실행형 CLI + 벤치마크 |
| `libnpu.cc` / `build_lib.sh` | `libnpu.so` ctypes 공유 라이브러리 |
| `npu.py` | `libnpu.so`를 감싼 Python 래퍼 |
