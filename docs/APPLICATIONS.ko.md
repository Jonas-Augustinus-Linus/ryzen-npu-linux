**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Linux에서 XDNA1 NPU로 실제로 무엇을 할 수 있나?

1세대 Ryzen AI NPU(XDNA1 / "Phoenix", 예: 7840U)를 Linux에서 **사용하려는** 사람들 —
게이머, 로컬 AI / 에이전트 빌더, 앱 개발자, 학습자 — 를 위한 실용적이고 솔직한 지도다.

## 솔직한 현실 프레임 (이것부터 읽어라)

오늘날 XDNA1+Linux에서 여러분이 가진 것은 턴키가 아니라 **커널 / 프리미티브 레벨**이다.
유일하게 동작하는 소프트웨어 경로는 소스에서 빌드한 [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
이며 — 이것은 모델 서버가 아니라 **AIE 커널을 위한 컴파일러 + 런타임**(matmul, conv, 그리고
그 주변의 elementwise 연산들)이다. 모든 턴키 스택(AMD
Ryzen AI SW for Linux, ONNX Runtime Vitis AI EP, Lemonade/FastFlowLM)은 **XDNA1을
제외**한다. 완전한 턴키 모델과 LLM은 **XDNA2 / Windows** 영역이다. 이 노트북에서 대부분의
무거운 로컬 AI에는 **Radeon 780M iGPU**(Ollama/llama.cpp Vulkan,
ROCm)가 더 빠르고 한없이 더 쉽다 — 이것이 여러분의 진짜 주력 일꾼이다. **그렇다면 NPU를
대체 왜 신경 쓰는가?** 그 진짜 강점이 **지속적이고 항시 켜진 추론 프리미티브에 대한 와트당
성능**이기 때문이다: 영원히 돌면서 배터리를 야금야금 쓰고 CPU와 iGPU를 놀게 두는, 작은
conv/matmul 블록 말이다. 그것이 만들 가치가 있는 것이며 — 그중 몇 가지는 오늘날 만들 수 있다.
이 가이드의 나머지는 과장된 약속 없이 그 강점을 활용하는 법에 관한 것이다.

> **즉시 깨버려야 할 한 가지 미신:** **조용한 CPU 폴백은 없다.** NPU에 배치할 수
> 없는 op를 컴파일러에 넘기면, 투명한 CPU 실행이 아니라 **하류에서 컴파일 에러**가
> 난다. "내 모델을 NPU에서 돌리고 어려운 부분은 폴백시킨다"는 이 툴체인이 동작하는
> 방식이 **아니다** — 그래프는 여러분이 직접 분할하고, 지원되지 않는 부분은 별도 코드로
> CPU에 남겨 둔다.

---

## 성능 상한: `iree-amd-aie`가 *오늘날* XDNA1에서 실행할 수 있는 것

이것이 나머지 모든 것이 의존하는 부분이므로, 정확하게 명시한다. 저장소 HEAD
`fddfec1b`에서 온디바이스 CI 하니스(`build_tools/ci/cpu_comparison/run.py`,
`matmul_test_config.py`)와 컴파일러 디스패치(`KernelDispatch.cpp`)에 대조 검증했으며,
그 소스들에 대한 적대적 리뷰와 교차 확인했다.

### NPU에서 진짜로 실행되는 op (llvm-cpu 대비 수치 검증됨)

| Op | `npu1_4col`에서 검증된 dtype | 상태 |
|---|---|---|
| `linalg.matmul` (+ `matmul_transpose_a/b`, `batch_matmul`, `matmul4d`) | `i8→i32`, `i32→i32`, `bf16→f32` | ✅ CI에서 수치 검증됨 |
| `linalg.matmul` + **bias add** (Linear 레이어) | `bf16→f32` 만 | ✅ npu1에서 실행됨 (`MatmulThinBias`/`MatmulFullBias`, fusion 플래그) |
| `linalg.conv_2d_nhwc_hwcf` (평범한 2D conv) | `i32→i32`, `bf16→f32`, `i8→i32` | ✅ npu1에 등록·실행됨 (`conv-decompose`) |
| **다중 디스패치 그래프** (producer→consumer 체인) | 위와 동일 | ✅ `three_matmuls`, `two_matmul_switching`가 npu1에서 통과 |

따라서 모델이 단일 커널에 **국한되지 않는다** — 지원되는 디스패치 여러 개를 작은
그래프로 엮어 NPU에서 실행할 수 있다.

### 부분적 / 실험적인 op (로어링은 존재하나 하드웨어에서 CI 보장은 안 됨)

| Op | 현실 | 신뢰 수준 |
|---|---|---|
| `linalg.softmax` | npu1 로어링 전략 **및** bf16 LUT-exp 마이크로커널은 존재하지만, 온디바이스 e2e 테스트는 [iree#21633](https://github.com/iree-org/iree/issues/21633) 대기로 **주석 처리**되어 있다. | 🟡 컴파일 경로는 존재; 온디바이스 정확성은 CI 보장 **안 됨** |
| `conv_2d_nhwc_hwcf_q` (i8 **양자화** conv) | **FileCheck/compile** 픽스처(`conv2d_nhwc_q.mlir`) 뿐이며, 어떤 하드웨어 실행에도 연결되어 있지 **않고** 수치 검증도 **안 되어** 있다. | 🟡 소스/패스 지원만 — 실행된다고 가정하지 마라 |
| i8 matmul + **dequant/requant** 에필로그 (INT8 fully-connected 패턴) | `matmul_elem_2.mlir`은 진짜 requant 에필로그지만 **고아 상태**다 — 어떤 하니스도 등록하지 않으므로 오늘날 CI를 통해 실행되지 **않는다**. 실제로 돌려지는 것은 위의 *부동소수점* matmul+bias 경로다. | 🟡 소스상 패턴은 실재; 직접 연결·검증해야 함 |
| `depthwise_conv_2d_nhwc_hwc` | 로어링 분기는 존재하나 트리 내에서 "취약하고 가드레일 없음"으로 설명되며, CI 테스트는 **주석 처리**되어 있다. | 🟡 시도해 보되 튜닝을 각오하라; 보장 안 됨 |
| `reduction_sum` | 샘플로 존재. | 🟡 |

### 오늘날 XDNA1에서 실행되지 *않는* op

- **Attention / flash-attention** — AIE 백엔드에는 어떤 attention op도 등록되어
  있지 않으며, 선행 조건인 softmax e2e가 비활성화되어 있다. XDNA1에서 ⛔.
- **LayerNorm, gather/embedding lookup, 동적 shape** — 디스패치 세트에 없음.
- **순환 셀 (GRU/LSTM)** — 로어링 없음; 애초에 아키텍처적으로 맞지 않는다.

### 작은 모델 전체를 돌릴 수 있나?

**만들 수는 있으나 턴키는 아니다.** *모든* 레이어가 지원되는 matmul / 평범한 conv /
융합된 elementwise 디스패치로 매핑되는 작은 **양자화 MLP 또는 2~3 레이어 CNN**은
NPU에서 디스패치 그래프로 실행될 수 있다. 단: (a) 이 빌드는 **`.onnx`나 PyTorch를
임포트할 수 없다** — `IREE_INPUT_TORCH/ONNX/TOSA=OFF`에 Python 바인딩 없이 컴파일되었고
**`iree-import-onnx`도 함께 제공되지 않는다**; 여러분은 손으로 작성한 **linalg 레벨
MLIR**만 넣을 수 있다. 실제 모델을 임포트하려면 그 프론트엔드를 켠 채 **IREE를 다시
빌드**해야 한다. (b) 지원되지 않는 op(#21633 전까지의 softmax, attention,
layernorm, depthwise, embedding, 동적 shape)는 **하드 컴파일 에러**이므로, 피하거나
CPU에 남겨 둬야 한다. (c) 타일링 플래그는 직접 튜닝한다. **npu1에서 통과하는
저장소 내 모델 전체(ResNet/MLP/transformer) e2e 테스트는 없다.**

**이 머신에서 측정된 상한:** bf16 matmul **1024³에서 ~220 GFLOP/s**(본래
강점), `i32` ~6 GFLOP/s(AIE의 네이티브 타입이 아님), 작은 matmul은
디스패치 오버헤드에 묶인다. 낮은 듀티 사이클에서 작은 모델 한 단계에는 괜찮지만, LLM
서빙에는 **부적합**하다.

---

## 로컬 AI / 에이전트 빌더용

NPU는 어떤 에이전트 구성요소에도 **꽂아 쓰는** 추론 엔진이 **아니다**. 하지만 embedding,
분류기, 리랭커, wake-word 모델 밑에 깔린 GEMM/conv 연산은 NPU가 돌리는 바로 그것이므로
— 이들은 공상이 아니라 진짜 엔지니어링 빌드다. 반복되는 패턴: **NPU에는 dense 레이어,
순차 / attention / softmax 글루는 CPU에.**

| 응용 | 실현성 | 방법 (구체적 경로) | 비고 |
|---|---|---|---|
| Wake-word / keyword spotting (항시 켜짐) | 🟡 빌드 가능 | CNN/FC KWS 모델: CPU에서 mel 프런트엔드 → ~80 ms 프레임마다 NPU에서 작은 conv2d / FC 분류기 → 임계값 → 이벤트 발화. (`openWakeWord`의 헤드는 3레이어 FC ReLU 망 — 순수 matmul.) | **단연 최고의 에이전트 적합 사례.** 작고, 영원히 돌며, 와트당 성능이 핵심 전부다. 프레임을 배치해 ~수백 µs 디스패치를 분산하라. |
| RAG embedding (MiniLM / bge-small / e5-small) | 🟡 빌드 가능 | 인코더의 **matmul** 블록을 NPU로 로어링(bf16/i8); softmax/layernorm/attention은 CPU에 유지. Embedding은 배치성이고 지연에 관대하다(코퍼스를 한 번 인덱싱). | GEMM이 *바로* 비용이며 *바로* 지원되는 부분이다; 그래프를 분할하고 수치를 검증하라. |
| Bi-encoder 리랭킹 (query×doc 스코어링) | 🟡 빌드 가능 | 사전 계산된 embedding의 배치 matmul — 순수 matmul에 가까운, NPU의 단연 최고 op. | 어떤 에이전트 작업보다 가장 깔끔한 매핑. Cross-encoder 리랭킹은 attention이 필요 → 그건 CPU에 두라. |
| 인텐트 분류 / 라우팅 헤드 | 🟡 빌드 가능 | 증류된 MiniLM 또는 frozen embedding 위의 MLP: 인코더 GEMM + 선형 헤드를 matmul(bf16)로. | 짧은 시퀀스, matmul 지배적 → 디스패치 오버헤드가 분산된다. |
| 작은 CNN 인지 (UI 요소 / 스크린샷 분류기, OCR 사전 필터) | 🟡 빌드 가능 | NPU에서 평범한 `conv_2d_nhwc_hwcf` 백본(bf16, 또는 i8→i32) + matmul 헤드; resize/normalize는 CPU. ViT는 피하라(attention 벽). | 평범한 conv는 검증됨; **i8 *양자화* conv는 컴파일 전용**이므로 bf16를 선호하거나 i8를 직접 검증하라. |
| 음성 에이전트용 Whisper / speech-to-text | ⛔ 부적합 (오늘날) | CPU 또는 780M(Vulkan)에서 `whisper.cpp`를 쓰라. 인코더는 *연구용* NPU 오프로드가 될 *수도* 있지만, iree-amd-aie 위의 엔드투엔드 Whisper는 없다; 디코더는 GEMV/메모리 바운드다. | NPU-int8 Whisper 빌드는 XDNA1+Linux가 아니라 Windows/Vitis를 타깃한다. |
| LLM **디코드** / 토큰 생성 | ⛔ 부적합 | **iGPU**를 쓰라: Ollama/llama.cpp Vulkan (~14 tok/s gemma-2B, ~5–6 tok/s 7–8B Q4). | 디코드는 **메모리 대역폭** 바운드다; NPU의 FLOPs/와트 강점은 이 병목에 도움이 안 된다. 가장 명확한 "iGPU를 쓰라" 사례. |
| LLM **프리필** (연산 바운드, NPU에 "맞아야" 함) | 🟠 XDNA2/Windows 필요 | npu1용으로 로어링된 fused attention + RoPE + RMSNorm + softmax가 필요한데 — 아무것도 없다. AMD의 IRON `llama_3.2_1b`이 이들을 구현하지만 **AIE2P/XDNA2**만 타깃한다. | "연산 바운드"는 op들이 로어링 가능할 때만 도움이 된다. XDNA1에서는 그렇지 않다. |
| "내 `.onnx`를 가리키면, NPU에서 실행" | ⛔ 사용 불가 | ONNX Runtime Vitis AI EP는 Linux 클라이언트 NPU에서 CPU로 폴백한다; 이 빌드에는 임포터가 없다. *임포트*라도 하려면 `IREE_INPUT_ONNX/TORCH=ON`으로 IREE를 다시 빌드하고, 그다음 큰 op 공백을 각오하라. | 턴키가 아니라 맨바닥 재빌드. |

---

## 게이머용

**가차 없이 솔직하게:** 7840U의 Linux 게이머는 오늘날 이 NPU로 **게임을 더 빠르게도 더
좋게도 만들 수 없다**, 출시 가능한 어떤 형태로도. 날것의 NPU 약점이 아니라, 세 개의 단단한
벽 때문이다:

1. **Proton 샌드박스.** 게임은 Proton/Wine 아래의 Windows `.exe`다. NPU는
   Linux 네이티브 `amdxdna` ioctl(XRT XDNA SHIM + Linux ELF 런타임)을 통해서만 도달
   가능하다. **Proton prefix 안에는 Windows 측 `amdxdna` 드라이버가 없으므로**,
   게임이 **NPU를 호출할 수 없다**. 유일한 경로는 **prefix 바깥의 별도 Linux 네이티브
   헬퍼 프로세스**다.
2. **XDNA1은 모든 턴키 스택에서 버려졌다**(FastFlowLM/Lemonade/Ryzen AI SW
   = XDNA2). 여기서는 소스에서 빌드한 `iree-amd-aie`만 동작한다.
3. **아무도 게임 NPU 오프로드를 출시하지 않는다**, Linux에서(사실상 Windows에서도). **NPU는
   현재 게임에서 0 FPS를 제공한다.**

> **거대한 미신: FSR은 NPU 워크로드가 아니다.** FSR4 이전은 분석적이다(ML 없음).
> FSR4 / Redstone 뉴럴 렌더링은 **GPU의 RDNA4 WMMA** 유닛에서 돌고
> RX 9000 GPU가 필요하다 — Ryzen AI NPU는 절대 쓰이지 않는다. AMD 자체의 실시간 NPU
> 업스케일러(REAPPEAR)는 **XDNA2, Windows, 영상 대상**이며, AMD 스스로
> 인게임 NPU 업스케일링을 *"미래의 방향"*이라 부른다.

| 응용 | 실현성 | 방법 (구체적 경로) | 비고 |
|---|---|---|---|
| **프로세스 외부 동반** STT로서의 로컬 음성 / push-to-talk | 🟡 빌드 가능 | Linux 데몬에서 iree-amd-aie로 컴파일한 Whisper **인코더**(GEMM 위주): PipeWire로 마이크 읽기 → 로컬 소켓으로 텍스트 방출 → 게임/오버레이가 소비. | **유일하게 현실적인 게이밍 인접 NPU 용도.** 렌더 루프 바깥, ~100–300 ms 지연에 관대, Linux 네이티브(Proton 벽 적용 안 됨). 인코더를 XDNA1로 포팅하는 게 어려운 부분이다. |
| 뉴럴 NPC / 적 AI (인텐트, 전술 결정) | 🟡 빌드 가능 | Linux 동반 서비스가 iree-compile로 작은 policy/MLP를 돌리고; 게임(모드/오버레이)이 소켓으로 질의. 턴제 / 초 단위만. | IPC + 디스패치 지연이 60 Hz 틱당 전투를 배제한다. DIY 모드 패턴, 아무도 출시 안 함. |
| **로드 시점**의 절차적 콘텐츠(텍스처/레벨) | 🟡 빌드 가능 | 네이티브 Linux 프로세스에서 오프라인 / 레벨 로드 시 생성; 게임은 에셋을 로드. 지연에 관대. | Proton 벽과 프레임 예산 둘 다 회피. 작은/중간 망만. |
| **캡처/스크린샷**의 오프라인/배치 ML 업스케일링 (라이브 아님) | 🟡 빌드 가능 | 디스크로 캡처 → 작은 ESRGAN 류 conv 스택을 `.vmfb`로 컴파일 → `--device=amdxdna`로 실행. | 오프라인이기 *때문에* 가능. 오늘날 Vulkan 경로(Real-ESRGAN-ncnn)가 훨씬 쉽고 빠르다. |
| 게임 **옆에서**(안이 아니라) 도는 로컬 LLM 코파일럿 | 🟡 빌드 가능 | 작은 양자화 모델을 네이티브 Linux 서비스로; 오버레이/Discord 봇이 소비; 780M을 비워 둠. | 적당한 tok/s; FastFlowLM/Lemonade가 XDNA1을 거부하므로 소스에서 brings up. |
| NPC 대사용 인게임 뉴럴 TTS | 🟠 XDNA2/Windows 필요 | 동반 데몬으로는 아키텍처적으로 괜찮으나, VITS/transformer 보코더는 XDNA1에 대부분 미구현. | 오늘날은 CPU TTS가 더 간단하다. |
| 프레임당 **인게임** ML 초해상도 / 업스케일링 | ⛔ 부적합 | Proton 아래에서 게임이 `/dev/accel/accel0`에 도달 못 함; 외부 캡처→업스케일→재주입은 16 ms 예산을 날린다; XDNA1용 SR conv 커널은 미작성. | FSR4 = GPU; REAPPEAR = XDNA2/Windows. |
| 프레임 생성 | ⛔ 부적합 | 렌더 파이프라인(GPU)에 묶인 모션 벡터/옵티컬 플로우가 필요. Proton 아래에선 파이프라인 접근 불가; 프레임당 왕복이 지연을 더한다. | NPU를 쓰는 프레임 생성 제품은 없다. |
| 런타임 애니메이션 / 뉴럴 IK | ⛔ 부적합 | 빡빡한 프레임당 엔진 결합 + Proton 샌드박스 = 런타임 경로 없음. 오프라인 툴링만. | |
| NPU를 통한 실시간 외부 캡처 업스케일러 | ⛔ 부적합 | 유일하게 동작하는 실시간 업스케일러(Anime4K, ncnn-vulkan 위의 waifu2x/Real-ESRGAN/RIFE)는 GPU/Vulkan이며 **XDNA 백엔드가 없고**, 780M과 충돌할 것이다. | 새 MLIR-AIE conv 커널을 작성하고 *나서도* 여전히 지연에 진다. |
| 온디바이스 NPU AI를 통한 안티치트 | ⛔ 부적합 | 무관: 커널 안티치트는 Windows 전용; Proton의 EAC/BattlEye는 유저 모드 정책 선택이다. NPU를 쓰는 안티치트는 없다. | |

---

## 앱 개발자용 (저전력, 항시 켜짐)

여기서 NPU의 와트당 성능 강점이 실제로 이득을 낸다: 무거운 핵심이 **conv 또는 matmul
형태**이고 표준 Linux 미디어 배관에 연결되는, **지속적이고 낮은 듀티 사이클**의
워크로드다. 솔직한 구분선은 오디오 대 비전이 아니라 **conv/matmul 형태 대
순환**이다.

**통합 지점(모두 표준 Linux):**
- **오디오** → PipeWire `pw_filter` / `module-filter-chain`(DeepFilterNet의
  LADSPA 플러그인이 쓰는 바로 그 훅) → 가상 마이크 노출.
- **카메라** → GStreamer/v4l2로 캡처 → NPU 실행 → Zoom/Chrome/OBS가 읽는
  **v4l2loopback** `/dev/videoN`(`exclusive_caps=1`)에 기록.
- **범용 데몬** → IREE 런타임 C API(`amdxdna` HAL 디바이스 생성 → `.vmfb` 로드 →
  invoke), `samples/simple_embedding/simple_embedding.c`를 본떠서.

| 응용 | 실현성 | 방법 (구체적 경로) | 비고 |
|---|---|---|---|
| 웹캠 배경 흐림 / 가상 배경 | 🟡 빌드 가능 | MediaPipe Selfie Segmentation(MobileNetV3 급 conv 인코더-디코더, 256×256). conv 백본(bf16)을 NPU에서; CPU resize + 합성; v4l2loopback으로 출력. | 순수 conv → 지원되는 `conv_2d_nhwc_hwcf`로 매핑. 128 배수가 아닌 shape는 타일링 작업 필요; depthwise 단계는 🟡(취약). |
| 가상 마이크로서의 마이크 노이즈 억제 | 🟡 빌드 가능 | 고전적 RNNoise가 **아니라** **DeepFilterNet**(conv 인코더-디코더). STFT/ERB + 게이팅은 CPU에 유지; conv 블록(bf16)을 NPU로 오프로드; PipeWire `pw_filter` 콜백. 프레임을 배치. | 이득은 지연이 아니라 **배터리**다 — CPU 버전은 이미 실시간이다. 빡빡한 <10 ms 데드라인 + 디스패치 오버헤드가 난제. |
| 온디바이스 이미지 분류 / 자동 태깅 | 🟡 빌드 가능 | MobileNetV3 / EfficientNet-Lite: NPU에서 conv 백본(`conv_2d_nhwc_hwcf`) + matmul 헤드; 라이브러리를 낮은 듀티 사이클로 배치 처리; resize/normalize는 CPU. | **bf16에서** 최고의 비전 적합 사례. i8 *양자화* conv + requant 에필로그는 **CI에서 컴파일 전용**이므로 — i8에 의존하기 전에 직접 검증하라. |
| 시맨틱 이미지 검색 embedding (MobileCLIP-S0 이미지 타워) | 🟡 빌드 가능 | conv 백본 + 최종 projection matmul → C API로 고정 길이 벡터; CPU에서 sqlite/faiss에 저장. 한 번 인덱싱, 질의는 저렴. | 이상적인 낮은 듀티 사이클 백그라운드 작업. 텍스트 **transformer** 타워는 attention 필요 → 디바이스 밖에서 사전 계산하거나 CPU에 유지. |
| 온디바이스 OCR (스크린샷/스캔) | 🟡 빌드 가능 | CRNN/PaddleOCR 류: conv 특징 추출기는 NPU; CTC/시퀀스 디코드 + 모든 BiLSTM은 CPU. 텍스트 라인 크롭을 배치. | 순환 인식기는 NPU에 살 수 **없다**(softmax/attention 게이트됨). |
| 객체 탐지 백본 (자동 프레이밍 스마트 카메라) | 🟡 빌드 가능 | NanoDet/YOLO-nano: conv 백본+넥은 NPU; 앵커 디코드 + NMS는 CPU; v4l2loopback 출력. | NMS/앵커 연산은 제어 위주 → CPU. 특이한 특징 맵 shape는 타일링 튜닝 필요. |
| 절전을 위한 존재 / 시선 탐지 | 🟡 빌드 가능 | 2–5 fps의 작은 얼굴/시선 CNN: conv 탐지기는 NPU; "N초 동안 시선 이탈" 시 → CPU 동작(DPMS 밝기 낮춤 / 잠금 / 일시정지). | 낮은 fps가 **디스패치 오버헤드를 가린다** → 더 너그러운 빌드 중 하나; 와트당 성능은 낮은 듀티 사이클에서 가장 강하다. |
| 엔진 안의 런타임 애니메이션 / 뉴럴 IK | ⛔ 부적합 | 프레임당 엔진 결합; 오프라인 콘텐츠 툴링으로만 가능. | |
| NPU 워크로드로서의 고전적 **RNNoise**(GRU) 또는 **Silero VAD** | ⛔ 부적합 | CPU에 유지하라(RNNoise는 이미 ~60배 실시간으로 돈다). NPU 음성 향상에는 **conv 기반 DeepFilterNet**으로 전환하라. | GRU/LSTM은 본질적으로 순차적이다(타임스텝이 직전 은닉 상태에 의존); 디스패치 오버헤드가 지배하며; 순환 로어링이 없다. |

---

## 학습자용

NPU는 컴파일해서 **실행을 지켜볼** 수 있는 진짜 프로그래머블 공간 데이터플로우
디바이스다 — 클라우드 하드웨어 없이 AIE / MLIR / 데이터플로우를 배우는 훌륭한 방법.

| 응용 | 실현성 | 방법 (구체적 경로) | 비고 |
|---|---|---|---|
| 동작하는 matmul을 변형하며 AIE / 공간 데이터플로우 학습 | ✅ 오늘날 동작 | [`scripts/run-matmul.sh`](../scripts/run-matmul.sh)와 [`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir)에서 시작; shape/dtype 변경; 재컴파일; `--device=amdxdna`로 실행. | 이 머신에서 경험적으로 검증된 유일한 티어. |
| shape & dtype 전반에 걸쳐 matmul/conv 벤치마크 | ✅ 오늘날 동작 | `BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`; i32 대 bf16 비교, 디스패치 바운드 대 연산 바운드 관찰. | 왜 bf16이 네이티브이고 작은 커널이 오버헤드 바운드인지 가르친다. |
| 자신만의 conv2d / 융합된 elementwise 커널 작성 | 🟡 빌드 가능 | `linalg.conv_2d_nhwc_hwcf` 또는 matmul+generic MLIR 작성; `conv-decompose`/`pack-peel` 컴파일; CPU 레퍼런스 대비 검증. | 평범한 conv는 검증됨; 양자화 conv/softmax는 실험적. |
| 작은 엔드투엔드 모델 빌드 (양자화 MLP / 2–3 레이어 CNN) | 🟡 빌드 가능 | 모든 레이어를 지원되는 linalg MLIR로 작성(`three_matmuls.mlir`을 본떠서); 하나의 `.vmfb`로 컴파일; NPU에서 디스패치 그래프 실행. | 이 빌드에 `.onnx` 임포트 없음; 지원되지 않는 op는 폴백이 아니라 **컴파일 에러**. |
| 실제 ONNX/PyTorch 모델을 임포트해 NPU 타깃 | 🟠 재빌드 필요 (+ 큰 op 공백) | `iree-import-onnx`를 얻으려면 `IREE_INPUT_TORCH/ONNX=ON` + Python 바인딩으로 IREE 재빌드; attention/layernorm/softmax/embedding/동적 shape op가 AIE용으로 **컴파일 실패**할 것을 각오하라. | 이 빌드에선 프론트엔드가 설계상 꺼져 있다; 임포트 ≠ 실행. |
| 업스트림 XDNA1-on-Linux 커버리지 기여 | ✅ 오늘날 동작 | 자신의 XDNA1 머신에서 결과를 실행; 하드웨어 리포트 / 새 op 테스트 제출. Phoenix CI는 존재하나 커뮤니티 커버리지는 빈약하다. | 모든 결과가 도움이 된다; [`CONTRIBUTING.md`](../CONTRIBUTING.md) 참조. |
| "NPU AI 학습"을 위해 LLM/Whisper 실행 | ⛔ 부적합 | 잘못된 도구 — 모델에는 780M iGPU를, NPU에는 *프리미티브*를 쓰라. | transformer 서빙 시도로 NPU 여정을 시작하지 마라. |

---

## 자신만의 NPU 프리미티브 만들기 (요리책)

모델의 무거운 단계를 데몬에 임베드하는 NPU 프리미티브로 바꾸는 일반 파이프라인:

**1. 모델의 무겁고 병렬적인 단계를 고른다.** 그것은 **matmul / 평범한 conv /
융합된 elementwise** 형태여야 한다. 순환(GRU/LSTM)과 attention/softmax 단계는
CPU에 남는다. 전/후처리(STFT, resize, NMS, 토큰화)는 CPU에 유지한다.

**2. linalg 레벨 MLIR로 표현한다.**
[`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir)(matmul) 또는
`conv_2d_nhwc_hwcf` 템플릿에서 시작. **`bf16`을 선호하라**(AIE 네이티브, ~220 GFLOP/s
타입). i8 양자화는 matmul에 동작한다; i8 *양자화 conv*와 i8 requant
에필로그는 실험적이므로, **의존하기 전에 CPU 레퍼런스 대비 검증하라**. (이
빌드는 `.onnx`/PyTorch를 임포트할 수 없다 — MLIR을 넣어라.)

**3. NPU용으로 컴파일한다.** 검증된 플래그 세트
([`scripts/run-matmul.sh`](../scripts/run-matmul.sh), [`docs/GOTCHAS.ko.md`](GOTCHAS.ko.md)):

```bash
iree-compile \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device=npu1_4col \
  --iree-amdaie-device-hal=amdxdna \
  --iree-amdaie-lower-to-aie-pipeline=air        `# bf16 matmul; use objectFifo for i8/conv` \
  --iree-amdaie-tile-pipeline=pack-peel          `# matmul; use conv-decompose for conv` \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  model.mlir -o model.vmfb
```

**4. 알려진 입력으로 검증한다.**

```bash
iree-run-module --device=amdxdna --module=model.vmfb \
  --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4   # cols=4 NOT 5, or ert state 8 timeout
```

**5. 데몬 / 미디어 그래프에 통합한다.** `.vmfb`를 다음으로 연결한다:
- 배치 작업 / 빠른 스크립트에는 **CLI**(`iree-run-module`); 또는
- **IREE 런타임 C API** — `amdxdna` HAL 디바이스 생성, 모듈 로드,
  함수 해석, invoke(`simple_embedding.c`를 본떠서). ~수백 µs 제출 오버헤드를
  분산하기 위해 **디스패치당 프레임을 배치하고**, **CPU 폴백 경로**를 유지하라.
- 그다음 **PipeWire**(`pw_filter` / `module-filter-chain` → 가상 마이크)
  또는 **GStreamer + v4l2loopback**(→ 가상 카메라), 혹은 그냥 소켓에 연결하라.

> 기반으로 삼을 저장소 스크립트: [`check-npu.sh`](../scripts/check-npu.sh)(살아
> 있나?), [`enable-npu.sh`](../scripts/enable-npu.sh)(render 그룹 / memlock /
> XRT), [`build.sh`](../scripts/build.sh)(모든 워크어라운드가 적용된 소스
> 빌드), [`run-matmul.sh`](../scripts/run-matmul.sh)(컴파일+실행
> 레시피). 호스트 컴파일러는 **gcc**여야 한다(clang21은
> `libIREECompiler.so` 링크 시 세그폴트).

---

## 어디서 시작할까 (대상별)

- **에이전트 빌더:** **wake-word / KWS** 프리미티브(conv/FC, 항시 켜짐)
  또는 **bi-encoder 리랭커**(배치 matmul)를 만들어라 — 가장 깔끔한 NPU 적합 사례. LLM
  자체는 780M iGPU에서 돌려라.
- **게이머:** 유일하게 현실적인 빌드는 소켓을 통한 **프로세스 외부 음성(STT) 동반
  데몬**이다. NPU를 사이드카로 취급하되, 절대 렌더 루프 안에 넣지 마라.
- **앱 개발자:** **배경 흐림**(카메라 → v4l2loopback) 또는 **bf16**의
  **사진 분류기**로 시작하라 — conv 형태, 지연에 관대, 와트당 성능이 이긴다.
- **학습자:** [`run-matmul.sh`](../scripts/run-matmul.sh)를 변형하고, bf16 대
  i32를 벤치마크한 뒤, 자신만의 conv2d 커널을 작성하라; 작은 MLP 그래프로 졸업하라.

## 솔직한 "XDNA1+Linux에선 아직 신경 쓰지 마라" 목록

- **NPU에서 어떤 LLM / Whisper / Stable Diffusion이든 서빙.** iGPU, 또는
  Windows/XDNA2를 쓰라.
- **NPU에서 LLM 프리필 *또는* 디코드** — 프리필은 attention(없음)이 필요하고,
  디코드는 대역폭 바운드(iGPU 승).
- **attention/transformer를 NPU 디스패치로 쓰는 모든 것** — attention op 없음,
  softmax e2e 비활성화(iree#21633).
- **임의의 `.onnx`/PyTorch를 임포트해 "그냥 실행"하기** — 이 빌드에 임포터 없음;
  지원되지 않는 op는 폴백이 아니라 컴파일 에러.
- **인게임 / 프레임당 업스케일링이나 프레임 생성** — Proton 샌드박스 + 지연 +
  FSR4는-GPU. 여기선 일어나지 않는다.
- **NPU에서 GRU/LSTM 모델(고전적 RNNoise, Silero VAD)** — 순차적이고,
  순환 로어링 없음; CPU에 유지하라.
- **i8 양자화 conv나 i8 requant 에필로그에 직접 검증 없이 의존하기** — 그것들은
  오늘날 CI에서 컴파일 전용/고아 픽스처다.

---

*신뢰 수준 범례: ✅ 오늘날 동작(이 머신에서 검증됨) · 🟡 빌드 가능 /
실험적(진짜 엔지니어링, 지원되는 op) · 🟠 XDNA2 또는 Windows 필요 · ⛔
NPU에 부적합. Ryzen 7 PRO 7840U(Phoenix/XDNA1), Ubuntu
26.04, kernel 7.0, XRT 2.21, `iree-amd-aie` HEAD `fddfec1b`에서 2026-06-22에 검증됨.
`iree-amd-aie`는 초기 단계이며 빠르게 움직인다 — 플래그와 op 커버리지가 변동된다.*
