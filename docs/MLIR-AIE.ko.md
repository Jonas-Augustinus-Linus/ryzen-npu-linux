**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# `mlir-aie`(IRON) 트랙 — NPU 커널을 직접 작성, 두 세대 모두

이 저장소의 나머지는 [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)를
빌드한다: 모델 전체(PyTorch / ONNX)를 NPU로 낮추는 **그래프 컴파일러**다. 이
페이지는 *다른* 열린 경로 —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)와 그 **IRON** Python
eDSL — 의 검증된 레시피다. 여기서는 **NPU 커널을 직접 작성**하고 `pyxrt`로
실행한다.

이 경로는 **두 NPU 세대 모두**에서 검증되었지만, 하나의 동일한 wheel이 아니라
릴리스별 설계로 검증했다:

> **XDNA1** — Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, `npu1`) ·
> Ubuntu 26.04 · kernel 7.0 · XRT 2.21 · 2026-06-24 mlir-aie 1.3.x로 검증
> (이전 단일 Worker 설계).
>
> **XDNA2** — Ryzen AI 9 HX PRO 370 (Strix Point, `npu2`, XRT 이름
> `RyzenAI-npu4`) · Radeon 890M · Ubuntu 26.04 · kernel 7.0 · Ubuntu 기본 XRT
> 2.21.75 · NPU FW 1.1.2.64 · 2026-08-15 **mlir-aie 1.4.1**로 검증
> (현재의 어노테이션된 단일 Worker 및 전체 어레이 설계).

현재 1.4.x 설계는 XDNA1에서 다시 검증하지 않았다. XDNA1 항목은 이전 1.3.x
결과를 기록한 것이다.

## iree-amd-aie vs mlir-aie — 어느 쪽?

| | `iree-amd-aie` (저장소 루트) | `mlir-aie` / IRON (이 페이지) |
|---|---|---|
| 가져오는 것 | 그래프 전체(`.onnx` / PyTorch) | 커널 아이디어(데이터플로 + C++ 연산 함수) |
| 추상화 | MLIR 그래프 컴파일러 | ObjectFifo 데이터플로 eDSL(`aie.iron`) + `aiecc` |
| 실행 호스트 | `iree-run-module` / C-API 러너 | `pyxrt`(python 설계가 스스로 실행) |
| 적합 용도 | "내 모델을 NPU에서 돌려라" | "특정 NPU 커널을 직접 작성/소유", 실제 ML 예제 블록 |
| Python | **3.12**(IREE 빌드 의존성) | **3.14**(Ubuntu 패키지 `pyxrt`에 맞춤) |
| 백엔드 | Peano(`llvm-aie`) | **같은** Peano — `aie2`(npu1) / `aie2p`(npu2), 자동 선택 |

둘은 경쟁이 아니라 상호 보완 관계다. 작업에 맞는 쪽을 쓸 것.

## 셋업 (스크립트 하나)

```bash
./scripts/setup-mlir-aie.sh
```

멱등(idempotent)이다; `Xilinx/mlir-aie`를 최신 릴리스 태그로 클론하고,
Python 3.14 venv를 만들고, Ubuntu 패키지 `pyxrt`를 그 안에 심볼릭 링크로
연결하고, 일치하는 `mlir_aie` wheel(1.4.1은 `cp314` manylinux wheel을
배포한다) + CPU torch를 설치하고, iree-amd-aie용으로 빌드한 Peano를
재사용한다(없으면 `llvm-aie` wheel을 설치한다 — 이 wheel은 `py3-none`이라
Python 버전에 무관하다). 세대 감지는 업스트림 방식 그대로다: `env_setup.sh`가
`xrt-smi examine`을 grep 해서 `NPU2=0/1`을 export 한다.

## NPU에서 예제 실행하기

```bash
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh ml/softmax
./scripts/run-mlir-example.sh ml/conv2d          # Makefile example
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
    -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
```

**mlir-aie 1.4.x는 예제 구조를 재편했다** — 스크립트는 두 형태를 모두 처리한다:

- 이제 대부분의 예제는 **직접 실행하는 단일 Python 설계**다: `@iron.jit`이
  첫 호출에서 컴파일하고, 디바이스(`npu`/`npu2`)는 자동 감지되며, 설계가
  자체 벤치마크/검증 하네스를 품고 있다. 예제별 Makefile은 `basic/`
  대부분에서 사라졌다; lit 파일(`run.lit` / `run_strix.lit`)이 표준 호출
  방법을 문서화한다.
- `ml/conv2d`, `ml/mobilenet`, matmul의 C++ 호스트 변형들은 여전히 Makefile을
  쓴다 — `devicename=npu2`가 세대를 선택한다
  (`devicename ?= $(if $(filter 1,$(NPU2)),npu2,npu)`).
- `aiecc.py`는 사라졌다: 1.4.x에서 `aiecc`는 **C++ 바이너리**이고, **Peano가
  기본 백엔드**다(chess는 명시적 `--xchesscc --xbridge` + Vitis가 필요하다).

## XDNA2에서 무엇이 돌아가나 (NPU에서 검증됨, mlir-aie 1.4.1)

Strix Point는 IRON에 **8 컬럼 / 컴퓨트 타일 32개**를 노출한다(Phoenix: 4/16).
아래 측정값은 모두 이 저장소의 머신들에서 나왔다; "NPU 시간"은 런타임이
보고하는 NPU 상의 수치(`kernel.wait()` 전후)로, 호스트 런치 오버헤드는
제외한다.

### 커널 & 블록

| 예제 | 종류 | XDNA2 결과 |
|---|---|--:|
| `basic/passthrough_kernel` | DMA 패스스루 | ✓ 94 µs |
| `basic/vector_scalar_mul` | 벡터 × 스칼라 | ✓ 106 µs |
| `ml/softmax` | LLM 블록 | ✓ PASS |
| `ml/rope` | LLM 블록 | ✓ PASS |
| `ml/swiglu` | LLM 블록 | ✓ PASS |
| `ml/norm -o rms` | RMSNorm | ✓ PASS |
| `ml/mm_activation_epilogue` | matmul + 융합 활성화 | ✓ PASS |
| `ml/conv2d` (i8, 32×32, 64ch) | INT8 컨볼루션 | ✓ 490 µs (XDNA1: ~900 µs) |
| `ml/mobilenet` | **네트워크 전체** | ✓ **PASS, ~176 ms/추론** |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | 커스텀 융합 커널 | ✓ 아래 참조 |

`ml/mobilenet`은 **XDNA1에서는 돌 수 없는** 설계다 — Phoenix의 4 컬럼보다
많은 컬럼을 원해 `CREATE_HWCTX`에서 죽는다. Strix의 8 컬럼에서는 네트워크
전체가 엔드투엔드로 돌아간다. (업스트림은 현재 이를 완화된 `atol=9` 허용
오차로 검증한다 — 그들의 주석을 여기 그대로 옮겨 둔다.)

### GEMM (`basic/matrix_multiplication/whole_array`, 8 컬럼)

| Shape | dtype | 내부 타일 | NPU 시간 | 처리량 |
|---|---|---|--:|--:|
| 512³ | i16→i32 | 32³ | 203 µs | 1.32 TOPS |
| 512³ | bf16→f32 | 32³ | 233 µs | 1.15 TFLOPS |
| 512³ | **bfp16** 경유 bf16 | 32³ | 199 µs | 1.35 TFLOPS |
| 2048³ | **bfp16** 경유 bf16 | 32³ | 9.71 ms | 1.77 TFLOPS |
| 2048³ | i8→i32 | 32³ | 8.73 ms | 1.97 TOPS |
| 2048³ | **bfp16** 경유 bf16 | 64×32×64 | 3.70 ms | **4.64 TFLOPS** |
| 2048³ | i8→i32 | 64³ | 2.59 ms | **6.65 TOPS** |

이 표가 가르치는 두 가지 교훈:

1. **내부 타일 크기만으로 3.4×가 나온다**(i8: 32³→64³ 타일만으로 1.97 → 6.65
   TOPS). 더 키우면 64 KB 코어 로컬 메모리를 넘쳐 배치(placement)에
   실패한다 — bf16은 64³에서 이미 그렇다.
2. **AIE2P에서 bf16 연산은 bfp16 경로를 택하라**
   (`--emulate-bf16-mmul-with-bfp16 1`). bf16 MAC은 XDNA1의 AIE2에서는
   네이티브지만 XDNA2의 AIE2P에서는 *약 ¼ 속도로 에뮬레이션*된다; 네이티브
   모드는 **bfp16 블록 부동소수점(block floating point)**(8×8×8)이다.
   512³에서 공짜 +17%, 타일을 튜닝하면 +25%.

**네이티브 bfp16ebs8** 엔드투엔드 설계(`ml/block_datatypes/…`)도 CPU float
참조값과 대조해 실행했고, 처리량만 재면 감춰지는 정합성 한계를 확인했다:

| 네이티브 bfp16 형상(8컬럼) | 처리량 | CPU 참조 결과 |
|---|---:|---|
| 512³ | 1.525 TFLOPS | **PASS** |
| 1024³ | 4.892 TFLOPS | **PASS** |
| 2048³ | 약 5.09 TFLOPS | **FAIL** — 표본 1000개 중 291개, 최대 상대 오차 12% |

처리량 값은 환경을 v1.4.1 pin에 맞추기 전 Peano 22(`4a1adefa`)로 기록했다.
이후 고정 Peano 21(`c9c5ecb7`)로 전체 PASS/FAIL sweep을 다시 실행해 경계가
같음을 확인했으며, 스크립트는 시간 대신 정합성만 단언한다.

M=N=1024로 두고 축약 길이만 분리하면 K=1216은 **PASS**, K=1280은
**FAIL**이다. [`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh)는
이 알려진 경계를 재현하고 단언한다. 소스 검사로는 각 K 타일이 bfp16 출력을 다시
읽고 저장하면서 부분합을 반복 양자화하는 것으로 보인다. 이는 K 의존성을 설명하는
가설이지, 검증된 수정안은 아니다. CPU 참조 검사도 통과하지 않은 네이티브 bfp
처리량은 보고하지 말아야 한다. 이는 위 표의 **bf16 입출력, 내부 bfp16** 2048³
경로와 별개이며, 그 **4.64 TFLOPS** 결과는 정합성 검사를 통과했다.

### 커스텀 커널, 어레이 전체 스케일링

우리의 융합 `relu(a+b)`([`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/)),
int32 1M 요소, 타일 1024:

| 설계 | NPU 시간 | 실효 DDR 대역폭 |
|---|--:|--:|
| 단일 Worker (타일 1개) | 8 967 µs | 1.4 GB/s |
| 어레이 전체 (8 컬럼, `transform_parallel_binary`) | 1 123 µs | 11.2 GB/s |

**8 컬럼에서 8.0×** — 대역폭에 묶인(bandwidth-bound) 이 커널에서는 선형
스케일링이다.

## XDNA1에서 무엇이 돌아가나 (NPU에서 검증됨, 2026-06-24)

| 예제 | 종류 | NPU 시간 |
|---|---|--:|
| `basic/passthrough_kernel` | DMA 패스스루 | ✓ |
| `basic/vector_scalar_mul` | 벡터 × 스칼라 | ✓ |
| `ml/conv2d` | INT8 3×3 컨볼루션 | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, 융합 | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck 블록 | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x 레이어 그룹 | ~5.1 ms |
| `ml/magika` | Google의 파일 유형 모델 (bf16) | ~0.9 ms |
| `examples/mlir-aie/relu_add` | 커스텀 융합 `relu(a+b)` 커널 | ~0.37 ms |

**Phoenix(4 컬럼)에서 알려진 한계:** `ml/mobilenet`은 빌드되지만
`DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)`로 실패한다 — 네트워크 전체 설계는
XDNA2 규모다(위에서 확인됨). 단일 블록은 들어맞고 실행된다.

## 커널 직접 작성하기

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/)는 기본 예제에
포함되지 **않은** 손수 작성한 커널이다: 단일 융합 `out = max(a + b, 0)`.
어느 세대에서든 전체 경로를 보여준다 —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — 연산 커널;
  Peano가 감지된 디바이스에 따라 `aie2` 또는 `aie2p`용으로 컴파일하며, 소스
  수정은 없다.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — IRON 1.4.x의
  어노테이션 붙은 `@iron.jit` 형태(`In`/`Out`/`CompileTime[...]`)이며, 설계는
  두 가지다: 단일 Worker(`transform_binary`)와 컬럼당 Worker 하나
  (`transform_parallel_binary`, 4 또는 8 컬럼 자동).

```bash
./examples/mlir-aie/relu_add/run.sh
```

**API 참고:** IRON 1.4.x는 어노테이션을 **요구한다** — 예전
`iron.jit(transform_binary)(kernel, a, b, out, tile_size=…)` 호출 형태(이
예제가 1.3.x에서 쓰던 것)는 이제 `TypeError: … no In / Out / InOut /
CompileTime[T] annotation`을 던진다. 1.4.x의 algorithms는 살아 있는 텐서
대신 jit 본문 안에서 *텐서 타입 기술자(descriptor)*를 받는다. 이식은
기계적이다 — 예제의 diff를 볼 것.

## 이 경로에 특화된 gotcha들

요약 목록 — 전체 내용은 [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie 트랙*:

1. **여기는 Python 3.14, 3.12가 아니다**(Ubuntu 패키지 `pyxrt`는 cpython-314다).
2. **`pyxrt`를 심볼릭 링크로** venv site-packages에 노출하라.
3. ⚠️ **`env_setup.sh`를 파이프 없이 source 하라** — 파이프 = 서브셸 =
   export(`NPU2`, `PEANO_INSTALL_DIR`…)가 사라진다.
4. **IRON 1.4.x 어노테이션 API 파괴적 변경** — 위 참조.
5. **코어 로컬 메모리는 64 KB다**: `tile_size` 4096의 더블 버퍼링 int32 FIFO
   3개 = 96 KB → `aie.tile op … allocation failed`. 들어맞게 타일 크기를
   정하라.
6. **바이너리(2입력) 커널은 `num_channels=2`를 쓸 수 없다** — 입력 2개가 이미
   컬럼당 shim MM2S DMA 채널 둘을 점유한다
   (`no ShimNOCTile has sufficient DMA capacity`).
7. **AIE2P에서 bf16은 ¼ 속도 에뮬레이션이다** — bfp16 경로를 쓰라(위 GEMM
   교훈 참조).
8. **Peano는 `iree-amd-aie` 것이 있으면 재사용하라**; 오늘 pin 없이
   `pip install llvm-aie`를 하면 mlir-aie CI가 테스트하는 것보다 LLVM 메이저
   하나 앞선 22.x 나이틀리를 받는다 — 셋업 스크립트가 대신 pin 해준다.

## 저장소의 나머지와의 관계

이것은 *추가* 경로이지 대체가 아니다. "내 모델을 NPU에서 돌려라"에는 XDNA1에서
`iree-amd-aie` 흐름(`scripts/build.sh` + `scripts/run-matmul.sh` +
`npu-trim` / `npu-runner` 도구)이 여전히 정답이다; 그 XDNA2 이식은
[XDNA2.md](XDNA2.md)에서 추적한다. **특정 커널을 작성**하거나 업스트림
**ML 예제 블록**을 직접 돌리고 싶을 때 `mlir-aie`를 꺼내 쓸 것.
