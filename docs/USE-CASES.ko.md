**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Linux에서 XDNA1 NPU를 실제로 어디에 쓸 수 있나?

성숙도 수준에 대해 스스로 솔직해지자. 오늘날 XDNA1+Linux에서
`iree-amd-aie`로 얻을 수 있는 것은 **AIE 커널을 위한 컴파일러 + 런타임**
(matmul, conv, 그리고 그 주변의 elementwise 연산들)이며,
`iree-*` CLI와 IREE 런타임 C API로 접근할 수 있다. 이것은 **턴키 모델 서버가 아니다**.

## 멘탈 모델: 이 노트북에서 NPU vs iGPU vs CPU

| 디바이스 | 잘하는 것 | 용도 |
|---|---|---|
| **NPU (XDNA1, ~10 TOPS)** | 지속적이고 **저전력**인 양자화/bf16 추론 커널 | 배터리를 아끼면서 특정 matmul/conv 블록을 오프로드 |
| **iGPU (Radeon 780M)** | 고처리량 범용 연산 | **오늘날 Linux에서 진짜 로컬 AI 주력 일꾼** — Vulkan/ROCm을 통한 LLM |
| **CPU** | 모든 것, 지연시간에 유연 | 글루, 제어, 폴백 |

NPU가 존재하는 이유 자체가 **와트당 성능**이다. 전력을 신경 쓰지 않는다면
780M iGPU가 Linux에서 범용 AI를 돌리기에 더 빠르고 훨씬 쉬운 길이다.

## ✅ 오늘날 잘 맞는 경우

- **NPU / 공간 데이터플로우 프로그래밍 학습.** 실제로 컴파일하고
  실행을 지켜볼 수 있는 진짜 디바이스가 있다. `run-matmul.sh`는 변형해 볼 수 있는 동작하는 기준점이다.
- 다양한 shape와 dtype(i32, bf16→f32)에서 matmul/conv에 대한 **NPU 벤치마킹**.
- **저전력 추론 *프리미티브*.** IREE 런타임 C API를 통해 앱에 임베드하고
  `--device=amdxdna`로 디스패치하는 손수 만든 matmul/conv 커널로,
  꾸준하고 가벼운 워크로드를 CPU/GPU에서 떼어 놓는다(예: 작은 CNN 단계,
  특징 추출기, 신호 처리 matmul).
- AIE 타일링, objectFifo vs air 파이프라인, 패킷
  플로우에 대한 **프로토타이핑 / 연구** — 궁극적으로 더 큰 모델을 가능하게 만드는 조각들.
- **업스트림 기여.** 모든 XDNA1-on-Linux 결과가 도움이 된다. 프로젝트의 CI에는
  전용 Phoenix 러너가 있지만 커뮤니티 커버리지는 빈약하다.

## 🚫 오늘날 XDNA1+Linux에서 현실적이지 않은 것

- **NPU에서 턴키 LLM / Whisper / Stable Diffusion 서빙.** Linux에서 XDNA1을
  타깃하는 즉시 사용 가능한 런타임은 없다. **iGPU**(Ollama/llama.cpp Vulkan, ROCm),
  또는 **Windows**(레거시 Vitis AI / Studio Effects), 또는 **XDNA2** 하드웨어를 사용하라.
- **"내 `.onnx`를 가리키기만 하면 된다."** ONNX Runtime의 Vitis AI EP는 Linux의
  클라이언트 NPU에서 CPU로 폴백한다. 임의의 그래프를 임포트하는 게 아니라 커널을 작성/로어링하는 것이다.
- **양자화-후-배포 파이프라인.** 양자화 도구는 존재한다. 빠진 것은 그 결과를
  XDNA1+Linux에서 실행할 *런타임*이다 — 그러니 여기에 배포할 거라 기대하며 양자화하지 마라.

## 컴파일된 커널을 앱에 임베드하는 방법

`iree-compile`이 생성한 `.vmfb`는 IREE 런타임이 로드한다. 둘 중 하나:

- **CLI**: `iree-run-module --device=amdxdna ... --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4`
  (배치 작업 / 스크립트에 적합), 또는
- **C API**: `iree-install`에서 `iree/runtime`를 링크하고, `amdxdna`
  HAL 디바이스를 생성하고, 모듈을 로드하고, 호출한다 — CLI가 사용하는 것과 같은 경로다. 이것이
  NPU matmul/conv를 실제 저전력 파이프라인에 연결하는 방법이다.

## 턴키 NPU 사용을 원한다면

1. **XDNA2 하드웨어**(Strix / Strix Halo / Krackan) — 2026년 Linux NPU의 모든
   추진력이 실제로 향하는 곳(Lemonade/FastFlowLM, Linux용 AMD Ryzen AI SW).
2. 같은 7840U에서의 **Windows** — 레거시 Vitis AI 경로와 Windows Studio
   Effects가 거기서는 Phoenix를 지원한다.
