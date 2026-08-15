**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# XDNA 노트북을 하이브리드 로컬 AI 실험실로 만들기

NPU가 LLM 전체를 혼자 서비스해야만 시스템에서 쓸모 있는 것은 아니다. 오늘의
XDNA1 Linux에서 실용적인 방법은 작고 반복적이며 CPU로 대조할 수 있는 단계를
NPU에 맡기고, CPU가 I/O·정책·미지원 연산을 처리하며, 높은 처리량의 토큰 생성이
필요할 때 iGPU를 쓰는 것이다.

```text
마이크 / 카메라 / 문서 / UI 이벤트
                    │
                    ▼
       CPU: I/O, 제어, fallback
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
NPU: 상시 trigger, 점수 계산,   iGPU: 양자화 LLM
dense/conv 블록                 prefill + 생성
        └───────────┬───────────┘
                    ▼
       CPU: 도구, 정책, 출력
```

이는 엔지니어링 분할이지 보편적인 성능 판정이 아니다. 낮은 에너지 사용과 더 긴
배터리 시간은 설계 목표지만, 이 저장소는 이를 증명하는 통제된 엔드투엔드 에너지
측정값을 아직 공개하지 않았다.

## 제공된 소스로 만들 수 있는 유용한 프로젝트

| 프로젝트 | NPU 역할 | CPU / iGPU 역할 | 근거의 경계 |
|---|---|---|---|
| **개인 RAG 도우미** | 지속형 bf16 matmul로 문서/질의 batch 점수 계산 | CPU가 chunk·hash·top-k를 처리하고, 선택적으로 다른 backend의 로컬 LLM이 생성 | [`local-rag-sidecar`](../examples/local-rag-sidecar/)는 실제 NPU-in-the-loop 통합이다. feature는 학습된 embedding이 아니라 결정적 hashed bag-of-words이며, 작은 질의 하나는 CPU가 더 빠를 가능성이 크다. 현재 실기 증거는 XDNA2이고 현재 핀 XDNA1은 남아 있다. |
| **로컬 음성 비서** | 상시 wake 또는 intent head | CPU가 오디오 전처리와 제어, iGPU LLM이 응답 | [`wake-word`](../examples/wake-word/)는 지속형 NPU dense layer 세 개를 실행하지만 제공 weight는 학습된 wake vocabulary가 아니라 예시용이다. |
| **개인 카메라·접근성 trigger** | 지원되는 conv/dense 분류 단계 | CPU가 capture/compositing하고 앱이 Linux event 출력 | [`npu-camera`](../examples/npu-camera/)는 GStreamer → NPU → `v4l2loopback` 배관을 증명하지만 현재 연산은 AI가 아닌 box blur다. 학습되고 CPU로 대조한 모델 단계로 교체해야 한다. |
| **하이브리드 ONNX 실험** | 추출된 지원 matmul/conv partition | CPU가 ReLU, 그래프 glue, fallback 유지 | [`onnx-mlp`](../examples/onnx-mlp/)는 실제 하이브리드 forward를 실행하지만 네트워크와 weight는 생성된 데모 데이터다. [`npu-trim`](../tools/npu-trim/)은 임의 그래프를 마법처럼 지원하는 대신 가능한 부분을 선별한다. |
| **양자화 블록 연구** | 각 경로를 검증해 가며 GEMM/GEMV, 역양자화, normalization, RoPE, softmax 수행 | CPU golden, 미지원 attention/control, 선택적으로 iGPU가 나머지 담당 | AMD 공식 IRON Phoenix workflow 커밋 `cdc48e93`은 이 프리미티브들의 CPU 기준 AIE2 예제를 통과했다.[^iron-ci] 이는 업스트림 근거이지 이 저장소 exact-lock의 XDNA1 결과나 엔드투엔드 LLM이 아니다. |
| **세대 교차 실험실** | 같은 소스를 장치별 타깃으로 실행 | CPU가 장치 식별값을 기록하고 모든 출력 대조 | XDNA1 과거 기록, XDNA2 현재 핀, 미래 장치 결과를 분리해 보존한다. 알 수 없는 장치에서의 명확한 실패도 유용한 근거다. |

## 공개할 만한 결과를 만드는 순서

1. **정확성 계약 하나를 재현한다.** 최적화보다 먼저 strict detector와 전체
   CPU 비교를 실행한다.
2. **합성 요소 하나를 실제 요소로 교체한다.** wake-word weight를 학습하거나,
   실제 embedding projection을 넣거나, camera blur를 평가된 모델 단계로
   교체한다. CPU fallback은 유지한다.
3. **조합하되 과장하지 않는다.** NPU 단계를 로컬 LLM, 데이터베이스, desktop
   action, sensor loop와 연결하고 각 연산이 어디서 실행되는지 표시한다.
4. **애플리케이션 전체를 측정한다.** 커널·엔드투엔드 지연시간, 전송량, 정확도,
   idle/load 전력, 작업당 에너지, 온도, CPU/iGPU 기준선을 함께 보고한다.
   TOPS 배지만으로 에너지 효율이 증명되지는 않는다.
5. **경계를 공개한다.** 장치 식별값, compiler commit, shape, dtype, 명령,
   전체 출력 정확도, skip, 최초 실패를 기록한다. 최소 재현 사례가 있는 부정적
   결과도 다음 연구자를 돕는다.

## 서로 다른 일을 하는 두 공개 경로

- 이 저장소가 고정한 `iree-amd-aie` 경로는 장치 모듈과 지속형 C/Python
  호출 경로를 패키징한다. 제공된 통합 예제와 정확한 릴리스 계약은 여기서
  시작한다.
- 고정된 [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) 1.4.1 경로는
  직접 공간형 커널용 IRON Python API/컴파일러를 연다. 더 새로운 연산자·
  애플리케이션 라이브러리 [`amd/IRON`](https://github.com/amd/IRON)은 MLIR-AIE
  언어 바인딩 위의 별도 프로젝트이며 이름 변경이 아니다. 커밋 `cdc48e93`의 공식
  Phoenix workflow는 **pytest case-run 2,105개 통과, 45개 건너뜀**을 보고했다.
  기본 5회 iterations에서는 **서로 다른 통과 구성 421개, 서로 다른 skip 구성
  9개**다. skip은 MHA 3개, streaming-SwiGLU 3개, GEMV+GELU 3개 구성이고 각각
  5회 반복됐다. GQA는 이 run으로 입증되지 않았으며 이를 XDNA1 전체 LLM
  주장으로 바꾸면 안 된다.[^iron-ci]

AMD Ryzen AI Software 1.8 for Linux는 Phoenix 대신 STX/KRK를
열거한다.[^ryzenai-linux] 이는 즉시 사용하는 제품 경로의 한계이지, 위의 공개
저수준 경로를 닫는 것은 아니다.

## 솔직한 한계

임의의 GGUF, Whisper, Stable Diffusion, ONNX 모델을 받아 그래프 전체를
XDNA1에서 서비스하는 지원 명령은 아직 없다. 컴파일 coverage, memory, transfer,
host orchestration은 실제 제약이다. 유용한 대응은 이 경계를 공개하고 검증된
단계를 offload하며, 생태계가 발전할 때 각 단계를 교체할 수 있게 만드는 것이다.

전체 초대장과 소스·근거 갤러리는 [Open NPU Lab](OPEN-NPU-LAB.ko.md), 1차
자료와 정확한 주장 범위는 [RESEARCH.md](RESEARCH.md), 다음 연산자·모델
milestone은 [LLM 로드맵](LLM-ROADMAP.md)을 참고하라.

[^iron-ci]: AMD IRON, [공식 Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 커밋 [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), 2026-08-15 확인. 지원 플랫폼으로 STX와 KRK를 열거한다.
