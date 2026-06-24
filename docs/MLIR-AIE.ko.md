**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# `mlir-aie`(IRON) 트랙 — XDNA1 NPU로 가는 두 번째 열린 경로

이 저장소의 나머지는 [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)를
빌드한다: 모델 전체(PyTorch / ONNX)를 NPU로 낮추는 **그래프 컴파일러**다. 이
페이지는 *다른* 열린 경로 —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)와 그 **IRON** Python
eDSL — 의 검증된 레시피다. 여기서는 **NPU 커널을 직접 작성**하고 `pyxrt`로
실행한다. 또한 실제 ML `programming_examples`(conv2d, ResNet 블록, Google의
Magika)를 함께 제공하므로, *이름 붙은* 워크로드를 1세대 Phoenix NPU에 올리는
가장 빠른 길이다.

두 경로 모두 `npu1`(Phoenix / XDNA1)을 타깃하며 **같은 Peano(`llvm-aie`)
백엔드**를 공유한다 — 따라서 이미 `./scripts/build.sh`를 돌렸다면, 이 트랙은 그
Peano를 재사용하므로 추가 비용이 거의 없다.

> 여기 나머지 전부와 동일한 머신: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO
> 7840U (Phoenix, XDNA1) · Ubuntu 26.04 · kernel 7.0 · 인트리 `amdxdna` · XRT
> 2.21 · NPU FW 1.5.5.391**. 2026-06-24 검증.

## iree-amd-aie vs mlir-aie — 어느 쪽?

| | `iree-amd-aie` (저장소 루트) | `mlir-aie` / IRON (이 페이지) |
|---|---|---|
| 가져오는 것 | 그래프 전체(`.onnx` / PyTorch) | 커널 아이디어(데이터플로 + C++ 연산 함수) |
| 추상화 | MLIR 그래프 컴파일러 | ObjectFifo 데이터플로 eDSL(`aie.iron`) + `aiecc` |
| 실행 호스트 | `iree-run-module` / C-API 러너 | `pyxrt`(`make run_py`) |
| 적합 용도 | "내 모델을 NPU에서 돌려라" | "특정 NPU 커널을 직접 작성/소유", 실제 ML 예제 블록 |
| Python | **3.12**(IREE 빌드 의존성) | **3.14**(Ubuntu 패키지 `pyxrt`에 맞춤) |
| 백엔드 | Peano(`llvm-aie`) | **같은** Peano |

둘은 경쟁이 아니라 상호 보완 관계다. 작업에 맞는 쪽을 쓸 것.

## 셋업 (스크립트 하나)

```bash
./scripts/setup-mlir-aie.sh
```

멱등(idempotent)이며 다음을 수행한다:

1. **`Xilinx/mlir-aie`를 최신 릴리스 태그로 클론한다**(`~/src/mlir-aie`).
   `programming_examples`는 설치된 wheel과 일치해야 하므로, 태그는 wheel
   버전에 고정된다.
2. **Python 3.14 venv를 만들고**(`~/src/mlir-aie-venv`) **패키지 `pyxrt`를
   심볼릭 링크**(`python3-xrt`, `cpython-314`로 빌드됨)로 그 안에 연결한다 — 이것이
   venv가 iree-amd-aie 빌드에 쓰는 3.12가 아니라 3.14인 이유다.
3. **`mlir_aie` wheel(일치하는 태그)을 설치한다** **+ CPU `torch`**(`ml/*`
   예제는 NPU 출력을 torch 골든값과 대조한다).
4. **`iree-amd-aie`용으로 빌드한 Peano를 재사용한다**(`~/src/iree-amd-aie/llvm-aie`);
   없으면 대신 `llvm-aie` 나이틀리 wheel을 설치한다.

## NPU에서 예제 실행하기

```bash
./scripts/run-mlir-example.sh ml/conv2d                 # default target: run_py (pyxrt)
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: needs libxrt-dev
```

`run-mlir-example.sh`는 [`scripts/mlir-aie-env.sh`](../scripts/mlir-aie-env.sh)를
source 하고(툴체인을 `PATH`에, Peano 연결, 디바이스 `npu1` 자동 감지),
예제를 `npu1`용으로 빌드한 뒤 NPU에서 실행한다. 기본값은 **`run_py`** make
타깃이다 — XRT 개발 헤더가 **필요 없는** `pyxrt` 호스트다.

## XDNA1에서 무엇이 돌아가나 (NPU에서 검증됨)

모두 `run_py` / `pyxrt`를 통하며, 출력은 torch/numpy 골든값과 대조했다. NPU
시간은 호스트 디스패치를 포함한 벽시계 시간이다(실행마다 달라진다):

| 예제 | 종류 | NPU 시간 |
|---|---|--:|
| `basic/passthrough_kernel` | DMA 패스스루 | ✓ |
| `basic/vector_scalar_mul` | 벡터 × 스칼라 | ✓ |
| `ml/conv2d` | INT8 3×3 컨볼루션 | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, 융합 | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck 블록 (1×1→3×3→1×1 + skip) | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x 레이어 그룹 | ~5.1 ms |
| `ml/magika` | Google의 파일 유형 모델 (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **커스텀** 융합 `relu(a+b)` 커널 | ~0.37 ms |

**Phoenix(4 컬럼)에서 알려진 한계:**

- `basic/matrix_multiplication/*`는 **xclbin으로는 정상 빌드**되지만(512³, 4 컬럼)
  그 호스트는 **C++ 전용**이다 — `make run`에는 `libxrt-dev`가 필요하다(런타임
  패키지는 XRT 개발 헤더를 제공하지 않는다). `sudo apt install libxrt-dev` 후,
  `./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run`.
- `ml/mobilenet`은 빌드되지만 실행 시
  `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)`로 실패한다: 네트워크 전체 설계는
  Phoenix의 **4** 컬럼보다 많은 컬럼을 원한다. 단일 블록(conv2d, bottleneck,
  resnet conv2_x)과 `magika`는 들어맞고 실행되지만, 전체 네트워크는 XDNA2
  규모다.

## 커널 직접 작성하기

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/)는 기본 예제에
포함되지 **않은** 손수 작성한 커널이다: 단일 융합
`out = max(a + b, 0)`(residual add + ReLU). 전체 경로를 보여준다 —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — 연산 커널,
  Peano로 `aie2`용으로 컴파일됨.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) —
  `transform_binary`를 통해 연결되고 `iron.jit`로 컴파일·실행되는
  `iron.ExternalFunction`, numpy와 대조됨.

```bash
./examples/mlir-aie/relu_add/run.sh
```

## 이 경로에 특화된 gotcha들

IRON 경로에는 iree-amd-aie 빌드와는 별개로 그 자체의 함정이 있다. 요약 목록(전체
내용은 [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie 트랙*):

1. **여기는 Python 3.14, 3.12가 아니다.** Ubuntu 패키지 `pyxrt`를 쓰는 유일한
   방법은 3.14 venv다; 3.12 venv는 그것을 import 할 수 없다.
2. **`pyxrt`를 venv `site-packages`에 심볼릭 링크로 노출하라**(깨끗한 venv,
   `--system-site-packages` 아님).
3. ⚠️ **`env_setup.sh`를 파이프 없이 source 하라.** `source env_setup.sh A B | tail`은
   서브셸에서 실행되어 `export`가 사라진다 → `PEANO_INSTALL_DIR`가 빈 값 →
   시스템 `/bin/clang++` → `error: unknown target triple 'aie2-none-unknown-elf'`.
   (`scripts/mlir-aie-env.sh`가 이를 대신 처리해준다.)
4. **`make run` 대신 `make run_py`를 선호하라.** `run_py`는 순수 `pyxrt`이고;
   `run`은 `libxrt-dev`가 필요한 C++ 호스트를 빌드한다.
5. **`llvm-aie`를 다시 받지 말고 `iree-amd-aie`의 Peano를 재사용하라.**
6. **네트워크 전체 설계는 4 컬럼보다 많은 것을 원한다** — Phoenix에서
   `CREATE_HWCTX`에 실패한다.

## 저장소의 나머지와의 관계

이것은 *추가* 경로이지 대체가 아니다. "내 모델을 NPU에서 돌려라"에는
`iree-amd-aie` 흐름(`scripts/build.sh` + `scripts/run-matmul.sh` +
`npu-trim` / `npu-runner` 도구)이 여전히 정답이다. **특정 커널을 작성**하거나
업스트림 **ML 예제 블록**을 직접 돌리고 싶을 때 `mlir-aie`를 꺼내 쓸 것.
