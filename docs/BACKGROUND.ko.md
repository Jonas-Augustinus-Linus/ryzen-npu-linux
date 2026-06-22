**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# 배경: XDNA1, XDNA2, 그리고 1세대에서 Linux가 어려운 이유

## 칩

AMD의 Ryzen AI NPU는 Xilinx로부터 물려받은 **AI Engine (AIE)** 공간 배열(spatial array)이다 —
스트리밍/DMA 인터커넥트로 연결된 VLIW 벡터 타일의 격자에, 호스트와 연결하는 메모리
및 "shim" 행이 더해진 구조다. CUDA 방식의 커널이 아니라, 타일에 연산을 배치하고
타일 사이로 데이터를 라우팅하는(데이터플로) 방식으로 프로그래밍한다.

여기서 중요한 두 세대는 다음과 같다:

| | **XDNA1** ("Phoenix"/"Hawk Point") | **XDNA2** ("Strix" 등) |
|---|---|---|
| 탑재 제품 | Ryzen 7040 / 8040 (예: **7840U**) | Ryzen AI 300 시리즈 |
| 타일 아키텍처 | AIE2 (`aie2`) | AIE2P |
| Phoenix 지오메트리 | 4 코어 행 × **사용 가능 4열**(원시 5열), `npu1_4col` | 더 큼, `npu4` |
| PCI ID | `1022:1502` | `1022:17f0` |
| ~성능 | ~10 TOPS | ~50 TOPS |

## Linux 소프트웨어 상황 (2026년 중반)

**커널** 쪽은 해결되었다: `amdxdna` DRM accel 드라이버가 **Linux 6.14**에
업스트림되었다(펌웨어도 포함). 최신 커널에서 NPU는 `/dev/accel/accel0`으로
열거되며 `xrt-smi`가 이를 인식한다 — **두** 세대 **모두**에서.

XDNA1이 떨어져 나가는 지점은 **유저스페이스 / 컴파일러** 쪽이다:

- **AMD Ryzen AI Software for Linux** (1.7.x) — **STX/KRK (XDNA2)만** 지원.
- **ONNX Runtime + Vitis AI EP** — Linux x86_64에서는 클라이언트-NPU 그래프 컴파일러가
  제공되지 않으며, 연산은 CPU로 폴백된다.
- **Lemonade / FastFlowLM** ("NPU LLMs on Linux" 프로젝트들) — **XDNA2 전용**이며,
  7000/8000 시리즈 XDNA1은 지원하지 않는다고 명시한다.

따라서 Linux에서 XDNA1은 턴키 스택 관점에서 **드라이버로는 보이지만 애플리케이션이
없는 고아 상태**다. 예외는 — XDNA1(`npu1`, 4×5)을 *명시적으로* 대상으로 삼아 활발히
개발되는 유일한 오픈 경로는 — IREE 플러그인인 **`nod-ai/iree-amd-aie`**다. 연구
수준(임의의 모델이 아니라 커널 단위)이지만, 하드웨어에서 실제로 동작한다. 이 저장소가
빌드하는 것이 바로 이것이다.

## `amdxdna` HAL이 디바이스에 도달하는 방식

`iree-amd-aie`는 당신의 matmul을 다음으로 컴파일한다:

1. **AIE 코어 코드** — Peano(`llvm-aie`, `aie2` 타깃을 갖춘 LLVM 포크)가
   타일별 프로그램(`core_<col>_<row>.elf`)을 컴파일한다.
2. **구성 / 제어** — object-FIFO 또는 AIR 데이터플로 lowering, 패킷
   라우팅, 그리고 제어 프로그램을 (`bootgen`을 통해) `.vmfb`에 패킹한다.

런타임에 **`amdxdna` HAL**(`-DIREE_EXTERNAL_HAL_DRIVERS=amdxdna`로 런타임에
빌드됨)은 **`/dev/accel/accel0`을 직접 열고**, 벤더링된 UAPI 헤더를 사용해
DRM ioctl(`DRM_IOCTL_AMDXDNA_GET_INFO`, 커맨드 제출, 펜스 대기)을 발행한다.
외부 XRT `xrt_coreutil` 라이브러리를 링크하지 **않는다** — 그것은 별개의 실험적인
`xrt` HAL이다. 이 때문에 in-tree `amdxdna.ko`가 존재할 때는 AMD의 out-of-tree
`xdna-driver`를 빌드할 **필요가 없다**.

디바이스는 동일한 ioctl을 통해 자신의 지오메트리를 보고한다. `npu1_4col`과
`--amdxdna_n_core_cols=4`는 이 값과 일치해야 한다([GOTCHAS #6](GOTCHAS.ko.md) 참조).

## 참고 자료

- AMD `xdna-driver` 및 커널 `amdxdna` 문서 (kernel.org `accel/amdxdna`)
- `nod-ai/iree-amd-aie` (README, `build_tools/ci/`)
- `Xilinx/llvm-aie` (Peano)
- IREE (`iree.dev`)
