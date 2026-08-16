**[🇬🇧 English](OPEN-NPU-LAB.md) · [🇰🇷 한국어](OPEN-NPU-LAB.ko.md)**

# Open NPU Lab: 놀고 있는 실리콘을 함께 쓰는 Linux 기반으로

이 저장소는 Ryzen 7 PRO 7840U에서 출발했습니다. 평범한 노트북 안에
1세대 XDNA1 NPU가 이미 있고 Linux에서도 보이지만, 실제로는 쓰지 못한 채
두기 쉬웠기 때문입니다. 첫 목표는 그 장치에서 CPU로 대조 검증한 진짜 연산
하나를 실행하는 것이었습니다. 더 큰 목표는 노트북 한 대, 유지관리자 한 명,
하드웨어 한 세대가 지나간 뒤에도 그 작업을 계속 쓸 수 있게 남기는 것입니다.

이 저장소는 작은 채로 잊힐 수도 있습니다. 그래도 괜찮습니다. 단 한 사람이
지나치기 쉬운 NPU를 재현 가능한 실험 장치로 바꾸고, 단 한 학생이 클라우드
하드웨어 없이 공간형 가속기를 배우고, 단 한 개발자가 다음 공개 커널을
발표하는 데 도움이 된다면 이미 쓸모 있는 일을 한 것입니다.

여기서 중심이 되는 질문은 “가장 최신 NPU로 무엇을 할 수 있는가?”가
아닙니다. **“지금 내 컴퓨터 안에 있는 이 장치를 Linux에서 어떻게 활용하고,
무엇이 실제로 실행됐는지 어떻게 정직하게 보여줄 것인가?”**입니다. 이
프로젝트를 시작하게 한 7840U에는 1세대 Ryzen AI NPU가 들어 있습니다. 그
실리콘을 이미 소유하고 있다는 사실만으로도 탐험할 이유는 충분합니다.[^amd-7840u]

> **가져가십시오. 사용하고, 바꾸고, 포크하고, 재배포하십시오.** 이 저장소의
> 원본 소스와 문서는 [MIT 라이선스](../LICENSE)로 공개합니다. 별도 허락은
> 필요 없고, 변경 사항을 이 프로젝트에 돌려줄 의무도 없습니다. 라이선스가
> 요구하는 저작권 및 라이선스 고지는 보존해 주십시오. 업스트림 프로젝트와
> 모델 자산에는 각각의 라이선스가 적용됩니다.

이것은 제품에 대한 약속이 아니라 세상에 건네는 공개 인계서입니다. 앞으로의
작업이 한 유지관리자나 이 저장소에 계속 머물 필요도 없습니다. 원본보다 오래
살아남는 포크가 생긴다면 그것도 성공입니다.

## 사명

**놀고 있는 실리콘을 되살립니다.** 이미 PC 안에 들어 있는 하드웨어가 가장
쉽게 접근할 수 있는 하드웨어입니다. 더 새로운 장치가 생겼다고 XDNA1이
쓸모없어지는 것은 아닙니다. NPU가 임의의 LLM 전체를 처음부터 끝까지 서비스할
때만 유용해지는 것도 아닙니다. 올바른 행렬 커널, 상시 동작 분류기, 저전력
sidecar, 컴파일러 재현 사례, 다음 사람의 일주일을 아껴 주는 실패 경계 모두
가치 있는 결과입니다.

**Linux의 자율성을 지킵니다.** 사용자는 장치 탐지부터 생성 코드까지 경로를
살펴보고, 각 단계를 어느 프로세서에서 실행할지 정하고, CPU 참조값과 비교하고,
turnkey 제품이 자기 장치를 지원하지 않아도 계속 작업할 수 있어야 합니다.
그 토대는 공개된 `amdxdna` 드라이버와 XRT shim,[^amdxdna]
`iree-amd-aie`,[^iree-amd-aie] 그리고 `mlir-aie`/IRON입니다.[^mlir-aie]
이 저장소는 그 위의 재현 가능한 경로를 묶어 제공합니다. 그 기반 기술을
발명했다고 주장하지 않습니다.

2026년 8월 15일 현재 AMD의 Ryzen AI Software for Linux 문서는 지원
플랫폼으로 STX와 KRK를 명시하며 Phoenix XDNA1은 열거하지 않습니다.[^ryzenai-linux]
이는 현재 turnkey 경로의 지원 범위를 보여 주는 것이지, 장치를 프로그래밍할
수 없다거나 구형 노트북에 남은 쓸모가 없다는 판정이 아닙니다.

**방법을 다음 세대로 이어 갑니다.** 이 프로젝트는 Phoenix XDNA1에서
시작하고, Strix Point XDNA2에서 같은 공개 정확성 계약을 검증합니다. 이후
장치는 증거가 생길 때까지 기본적으로 닫아 둡니다. 미래의 NPU도 불투명한
장식이 아니라 실험실이 되어야 합니다.

**일반 노트북도 정당한 AI 실험실로 만듭니다.** 대상은 컴파일러 전문가만이
아닙니다. 점검 스크립트를 실행해 볼 노트북 사용자, 그래프를 나누어 볼 로컬
LLM 개발자, 정직한 출발점이 필요한 연구자 모두를 위한 것입니다. 작은 모델,
양자화 블록, 하이브리드 파이프라인, 소박한 상시 동작 작업도 모두 유효합니다.

## 유용한 로컬 LLM이 모든 일을 한 프로세서에서 할 필요는 없습니다

실용적인 구조는 이기종 구조입니다. 현재 각 프로세서가 잘하는 일을 맡기고 CPU
fallback을 남깁니다.

```text
마이크 / 카메라 / 문서 / UI 이벤트
                    │
                    ▼
       CPU: I/O, 토큰화, 제어, fallback
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
NPU: 상시 동작 trigger,       iGPU: 양자화 로컬 LLM
작은 dense/conv 커널,         prefill + 토큰 생성
분류 또는 점수 계산                 │
        └───────────┬───────────────┘
                    ▼
       CPU: 도구, 정책, 응답, 검증
```

현재 이 저장소는 이 가운데 **NPU 가지**를 살펴보고 재사용할 수 있게 만듭니다.
로컬 assistant는 훈련된 wake word 또는 intent head를 NPU에, 기존 양자화 LLM
runtime을 iGPU에, 조정과 미지원 연산을 CPU에 맡길 수 있습니다. 이 저장소가
XDNA1에서 임의의 GGUF, ONNX, transformer 모델 전체를 실행하지 않더라도 이는
분명 의미 있는 NPU 활용입니다.

생태계가 발전하면 같은 구조도 함께 확장됩니다. attention, normalization,
quantization, runtime 지원이 좋아질 때, 측정과 검증을 마친 단계부터 전체
애플리케이션을 다시 쓰지 않고 CPU나 iGPU에서 NPU로 옮길 수 있습니다.
[LLM 로드맵](LLM-ROADMAP.md)이 그 작업을 추적합니다.

업스트림의 한 이정표는 AMD IRON입니다. 2026-08-15 exact `cdc48e9`
Phoenix 하드웨어 workflow는 **기본 5회 반복에서 pytest case-run 2,105개
PASS, 45개 SKIP**을 기록했습니다. 이는 고유 pass 구성 421개와 고유 skip
구성 9개이며,
CPU reference가 있는 AIE2 GEMM/GEMV, Q4NX dequantization, Softmax, RoPE,
RMS/LayerNorm, activation, transpose와 관련 경로를 실행했습니다.[^iron-dashboard]
MHA/GQA와 일부 fused SwiGLU 경로는 AIE2P 전용이거나 SKIP입니다. 이는 강한
upstream Phoenix 증거이지만 이 저장소의 고정 stack이나 7840U current-lock
경로가 모든 연산자를 검증했다는 뜻은 아닙니다. 그대로 물려받는 기능 목록이
아니라 직접 재현할 다음 실험 목록으로 읽어야 합니다.

## 모든 결과를 진실 라벨과 함께 읽으십시오

아래 라벨은 일부러 “동작함”보다 좁게 정의합니다.

| 라벨 | 의미 |
|---|---|
| **현재 하드웨어 정확성** | 현재 저장소의 exact lock으로 지정된 NPU에서 실행하고, 독립된 CPU 결과와 비교했습니다. |
| **이전 하드웨어 증거** | 이전 dependency snapshot으로 실제 하드웨어에서 실행했습니다. 가치 있는 증거지만 현재 lock의 재실행은 아닙니다. |
| **애플리케이션 배관** | 실제 I/O/runtime 통합이 실행됐지만, 시연 모델이나 연산은 학습된 제품 모델이 아니라 예시일 수 있습니다. |
| **합성 템플릿** | NPU dispatch는 실제이지만, weight·입력·과제는 생산 문제를 풀기보다 파이프라인을 증명하도록 생성했습니다. |
| **컴파일 전용** | 소스가 명시한 컴파일 단계까지 갔습니다. NPU에서 link, 실행, 수치 검증을 했다는 뜻은 아닙니다. |
| **프로젝트 아이디어** | 구체적인 실험안이며 현재 제공되는 기능은 아닙니다. |

컴파일은 실행이 아닙니다. 실행은 정확성이 아닙니다. 정확성은 성능이 아니고,
커널 benchmark는 사용자 애플리케이션이 아닙니다. 이 실험실의 보고서는 그
주장들을 분리합니다.

## 이 저장소에서 실제로 가져갈 수 있는 것

아래 소스 갤러리는 초대장이자 부품 목록입니다.

| 소스 | 실제인 부분 | 진실 경계 |
|---|---|---|
| [`scripts/check-npu.sh`](../scripts/check-npu.sh), [`detect-npu.sh`](../scripts/detect-npu.sh), [`verify-stack.sh`](../scripts/verify-stack.sh) | 엄격한 장치 식별과 detect → compute → 전체 출력 CPU 대조 계약을 제공합니다. Strix Point `npu4`는 현재 exact lock을 통과했습니다. | Phoenix에는 이전 실제 하드웨어 결과가 있지만 현재 exact v1 lock의 XDNA1 재실행이 남았습니다. 알 수 없는 geometry는 닫힌 상태로 실패합니다. |
| [`examples/matmul_i32.mlir`](../examples/matmul_i32.mlir), [`matmul_bf16.mlir`](../examples/matmul_bf16.mlir) | 직접 고칠 수 있는 최소 커널입니다. i32와 bf16 경로를 NPU에서 실행하고 CPU 참조값과 대조합니다. | 현재 lock 증거는 Strix Point입니다. 공개된 Phoenix timing은 이전 동작 snapshot의 장치별 결과입니다. |
| [`tools/npu-runner/`](../tools/npu-runner/) | persistent native C runner와 Python/ctypes bridge가 VMFB를 한 번 load해 반복 호출합니다. 현재 `npu4`에서 전체 출력을 확인했고, 이전 7840U 실행은 subprocess 방식의 약 41 ms에 비해 호출당 약 3.7 ms를 측정했습니다. | 이 timing은 이전 XDNA1 증거입니다. 보편적인 배속이나 현재 lock의 XDNA1 재실행으로 해석하면 안 됩니다. |
| [`examples/local-rag-sidecar/`](../examples/local-rag-sidecar/) | CPU chunking과 결정적 hashing이 persistent 256×256 bf16 NPU score matrix로 이어지고, CPU가 65,536개 출력을 모두 검사해 top-k를 고른 뒤 선택적으로 model endpoint를 호출합니다. 현재 `npu4`에서 전체 경로를 실기 검증했습니다. | feature는 학습 embedding이 아닌 hashed bag-of-words이며, 작은 단일 query는 CPU가 더 빠를 가능성이 큽니다. exact-lock XDNA1 sidecar 재실행은 아직 열려 있습니다. |
| [`examples/onnx-mlp/`](../examples/onnx-mlp/) | 실제 하이브리드 forward pass입니다. 추출된 bf16 matmul 두 개는 NPU에서, ReLU는 CPU에서 실행하며 각 dispatch와 전체 출력을 확인합니다. 원본 XDNA1 및 현재 `npu4` 실행이 있습니다. | 모델과 weight는 시연용으로 생성했습니다. 학습된 애플리케이션이나 범용 whole-model ONNX runtime이 아닙니다. |
| [`examples/wake-word/`](../examples/wake-word/) | 실제 log-mel front end와 persistent NPU dense dispatch 세 개가 문서화된 하드웨어 경로의 self-test에서 target과 noise를 구분합니다. | 제공 weight는 학습된 wake-word vocabulary가 아니라 예시용 matched filter입니다. detector라 부르기 전에 학습 weight와 실제 음성으로 검증해야 합니다. |
| [`examples/npu-camera/`](../examples/npu-camera/) | GStreamer → persistent NPU → `v4l2loopback` 배관이 원본 XDNA1 시연에서 30 fps로 실행됐습니다. `npu4` processing core는 정확성 검증을 했습니다. | NPU 연산은 2-pass 2D box blur이지 AI segmentation이 아닙니다. XDNA2에서는 전체 camera loop와 FPS를 재검증하지 않았습니다. |
| [`tools/npu-trim/`](../tools/npu-trim/) | 그래프를 import 또는 screening하고, op를 분류하고, 깨끗한 matmul/conv 커널을 추출해 감지된 target으로 test-compile하며, 오래되거나 실패한 artifact는 거부합니다. | 임의의 모델을 다시 만들거나 실행하지 않습니다. 현재 Strix의 검증 경로는 matmul이며 conv 범위는 좁고 target에 따라 다릅니다. |
| [`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/)와 [IRON 안내서](MLIR-AIE.ko.md) | 직접 작성한 spatial kernel과 업스트림 ML 예제입니다. 현재 mlir-aie 1.4.1 경로는 8-column Strix에서 하드웨어 검증됐고, 이전 XDNA1 예제는 당시 snapshot으로 실행됐습니다. | 현재 mlir-aie 1.4.x를 이 저장소의 XDNA1에서 다시 실행하지 않았습니다. 두 snapshot을 하나의 주장으로 합치면 안 됩니다. |
| [`examples/mlir-aie/w4a16_gemm/`](../examples/mlir-aie/w4a16_gemm/)와 [`scripts/check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | 고정된 compile probe가 실기 검증된 W4A16 GEMM으로 성장했습니다: int4 AWQ-g128 가중치를 in-core dequant, 512³/2048³ CPU 참조 PASS, 8-column Strix array에서 5.94 TOPS. | Strix Point의 커널 수준 증거일 뿐입니다: whole-model 통합과 energy 측정은 없고, chess 컴파일 9 TOPS 참조치가 이 Peano 빌드보다 앞서 있습니다. |

원본 XDNA1 runner 기록과 현재 XDNA2 acceptance 기록은 이 라벨의 실제 의미를
보여 줍니다.

| 이전 XDNA1 하드웨어 증거 | 현재 Strix Point XDNA2 하드웨어 정확성 |
|:---:|:---:|
| ![원본 XDNA1 persistent runner 기록](media/npu-runner.gif) | ![현재 XDNA2 exact CPU 대조와 persistent runner 기록](media/xdna2-compute.gif) |

녹화는 화면에 나온 장치, 날짜, 코드, dependency snapshot의 증거입니다. 같은
마케팅 이름을 가진 모든 기기에 대한 증명은 아닙니다.

## 실험실로 들어오는 네 가지 길

### 15분: 추측하지 말고 식별하기

[지원 표](SUPPORT.md)를 읽고 저장소를 clone한 다음 strict read-only 점검을
실행합니다.

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux
./scripts/check-npu.sh --strict
```

사용자 이름, serial number, token 및 다른 개인 정보를 지운 뒤 전체 출력을
보관하십시오. 인식하지 못한 장치에서 깔끔하게 실패한 결과도 이미 유용합니다.
알 수 없는 `npu5`, `npu6` 또는 미래 geometry를 닮아 보이는 target에 강제로
끼워 맞추지 마십시오.

### 하루: 정확성 계약 하나 재현하기

먼저 host, disk, 권한, reboot 요구 사항을 검토하십시오. 점검 결과가 group,
memlock, XRT 문제를 가리킬 때만 [`enable-npu.sh`](../scripts/enable-npu.sh)를
읽어 본 뒤 실행합니다.

```bash
./scripts/build.sh
./scripts/verify-stack.sh --quick
```

별도로 고정된 direct-kernel stack도 설치했다면 다음을 실행합니다.

```bash
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

목표는 가장 빠른 숫자가 아닙니다. 전체 CPU 참조 검증과 첫 실패를 그대로 남긴,
다른 사람이 반복할 수 있는 결과 하나입니다.

### 일주일: 합성 부품 하나를 실제 쓸모로 교체하기

좁은 단계 하나를 고릅니다. wake-word weight를 학습하거나, camera box blur를
CPU 대조 모델 단계로 교체하거나, 제공된 RAG sidecar의 hashed feature를
라이선스가 명확한 학습 projection으로 바꾸거나, 검증된 커널을 작은 service로 감싸 보십시오. persistent
runner를 재사용하고, 미지원 glue는 CPU에 명시적으로 남기며, CPU fallback을
유지하십시오. 커널 시간뿐 아니라 end-to-end latency와 energy도 측정합니다.

### 연구: 경계 하나를 옮기고 공개하기

W4A16 또는 W8 실행을 완성하고, transformer block을 fuse하고, attention
설계를 port하고, transfer를 줄이고, 수치 누적 한계를 규명하고, 미래 장치를
추가하거나, 업스트림 실패를 재현 가능하게 만드십시오. 정확한 shape, compiler
pin, 최소 reproducer가 있는 부정적 결과도 실험실을 전진시킵니다.

## 만들어 볼 가치가 있는 실용 프로젝트

| 프로젝트 | 첫 번째 유용한 결과물 | 현재 상태 |
|---|---|---|
| private local assistant | NPU wake-word/intent sidecar + iGPU LLM + CPU tool loop | 구조는 준비됐습니다. 제공 wake weight는 합성이며 완성된 assistant는 제공하지 않습니다. |
| offline RAG helper | query/document vector batch, NPU matrix scoring, CPU top-k와 database | 동작하는 [hashed-feature sidecar](../examples/local-rag-sidecar/)를 `npu4`에서 실기 검증했습니다. 통합 참고 예제이며 학습되거나 성능 우위를 보인 retriever는 아닙니다. |
| accessibility trigger | 표준 Linux event를 내보내는 학습된 sound, gesture, presence 또는 UI classifier | 프로젝트 아이디어입니다. wake-word나 camera 배관을 재사용하고 실제 training/evaluation data를 제공해야 합니다. |
| smart virtual camera | NPU의 지원 conv 단계, CPU compositing, `v4l2loopback` 출력 | 배관은 있지만 현재 demo는 box blur입니다. model conv는 shape별 검증이 필요합니다. |
| private media indexer | 작은 CNN 또는 projection 단계로 tag/embedding을 만들고 CPU에서 저장·검색 | 프로젝트 아이디어입니다. 모든 model partition을 검증하고 CPU fallback을 유지해야 합니다. |
| quantized block 실험실 | W8/W4 matmul + dequantization, CPU golden, error·energy sweep | W4A16은 이제 실기 검증되어 5.94 TOPS로 실행됩니다([`w4a16_gemm`](../examples/mlir-aie/w4a16_gemm/)). energy sweep과 다른 bit-width가 열린 milestone입니다. |
| 세대 교차 benchmark | 같은 source, 장치별 build, 전체 출력 검증, latency/energy 표 | XDNA1 이전 증거와 현재 Strix 증거가 있습니다. same-pin XDNA1과 미래 장치 행은 비어 있습니다. |
| compiler boundary 지도 | 통과/실패 shape와 op를 script로 축소하고 upstream에 보고 | 알려진 bfp16 누적 및 conv 경계가 이미 문서화되어 있습니다. 더 많은 장치를 기다립니다. |

처음부터 whole model을 약속하지 마십시오. 작더라도 쓸모 있고 측정 가능하며
교체할 수 있는 첫 결과물에서 시작한 뒤 조합하십시오.

## 공개 연구가 보여 주는 가능성: 최고점은 출발점이 아닙니다

이 저장소 밖에서 발표된 연구는 하이브리드 방식과 공개 커널 방식에 투자할 이유를
보여 줍니다. 동시에 모든 주장을 각 실험의 범위 안에 가둬야 할 이유도 보여
줍니다.

### Phoenix XDNA1: 하이브리드 GPT-2 fine-tuning

Rösti와 Franz의 2025년 논문 *Unlocking the AMD Neural Processing Unit for
ML Training on the Client Using Bare-Metal-Programming Tools*[^phoenix-gpt2]는
이 저장소의 7840U가 아닌 Ryzen 9 7940HS 노트북의 Phoenix XDNA1 NPU를
사용했습니다. 124M-parameter GPT-2 fine-tuning workload에서 GEMM을 NPU로
offload하고 나머지는 CPU에 남겼습니다. 논문은 offload한 행렬곱에서 **2.8배
초과**, 전체 throughput에서 전원 연결 시 **1.7배**, battery에서 **1.2배**,
battery energy efficiency에서 **1.4배** 개선을 보고합니다.[^phoenix-gpt2]

이는 1세대 Phoenix도 잘 설계된 하이브리드 경로를 통해 실제 LLM 작업에
기여할 수 있다는 증거입니다. 이 저장소가 GPT-2를 실행한다는 증거도, 7840U가
같은 수치를 재현한다는 증거도, 현재 exact lock을 XDNA1에서 재검증했다는
증거도 아닙니다.

### XDNA1 이식성과 XDNA2 energy: STEEL

2026년 논문 *STEEL: Sparsity-Aware Fused Attention for Energy-Efficient
Long-Sequence Inference on AMD's XDNA NPU*는 알고리즘을 AMD의 open-source
IRON 프로젝트를 통해 공개합니다.[^steel] 두 세대와 비교 기준을 섞지
마십시오.

- **XDNA1 port**에서 STEEL은 비교 기준으로 삼은 이전 XDNA1 FlashAttention
  연구 **DATO 대비 평균 9.6배 speedup**을 보고합니다. CPU/GPU와의 비교가
  아닙니다.[^steel]
- Ryzen AI 9 HX 370 **XDNA2** system에서 논문은 자체 CPU baseline 대비
  평균 **9.17배**, GPU baseline 대비 **1.75배** energy-use 감소를 보고합니다.
  같은 XDNA2의 layer-by-layer attention 구현 대비 평균 **22.8배** speedup도
  보고합니다.[^steel]

이는 해당 논문의 구성, baseline, 측정값이지 이 저장소의 benchmark가 아닙니다.
Phoenix fine-tuning 결과와 함께 보면 하나의 연속선이 드러납니다. XDNA1에서는
점진적인 CPU+NPU offload만으로도 가치를 만들 수 있고, 정교하게 fuse한
dataflow 설계는 transformer의 더 많은 부분을 NPU로 옮길 수 있습니다. 그렇다고
임의의 end-to-end LLM이 지금 이 저장소의 기능이 되는 것은 아닙니다.

## 여러 세대가 합류하는 규칙

마케팅 제품군은 compiler target이 아닙니다. 이후 NPU는 증거를 통해서만 이
실험실에 합류합니다.

1. **식별합니다.** CPU model, PCI ID, VBNV, usable row/column, firmware,
   driver, XRT, kernel, distribution, 해당 upstream target을 기록합니다.
2. **먼저 미지원으로 둡니다.** 알 수 없는 geometry는 닫힌 상태로 실패해야
   합니다. 전문가 override로 compatibility를 조사할 수는 있지만 추측을 지원
   주장으로 바꿀 수는 없습니다.
3. **최소 커널을 컴파일합니다.** **컴파일 전용**으로 표시하고 compiler log와
   정확한 pin을 보존합니다.
4. **실행하고 정확성을 증명합니다.** 모든 출력 요소를 독립 참조값과 비교하거나,
   정당화한 full-tensor error metric과 tolerance를 공개합니다. 해당된다면 native
   binding과 언어 binding도 따로 시험합니다.
5. **경계를 지도화합니다.** 성공뿐 아니라 처음 실패하는 shape/op도 공개합니다.
   가까운 case가 동작한다는 이유로 실패를 버리지 않습니다.
6. **책임 있게 측정합니다.** warm-up, dispatch, kernel, transfer,
   application time을 나눕니다. energy 주장을 하기 전에 전원 상태, power mode,
   sampling 방법, 반복 횟수, CPU/iGPU baseline을 기록합니다.
7. **의도적으로 승격합니다.** review가 끝난 뒤에만 detection, 문서, CI 기대값,
   지원 표에서 그 장치를 지원 대상으로 명시합니다.

[hardware-result issue form](../.github/ISSUE_TEMPLATE/hardware-result.yml)과
전체 [기여 안내](../CONTRIBUTING.md)를 사용하십시오. 유용한 보고에는 fresh
clone 명령, 정확한 source/toolchain revision, shape, dtype, quantization,
padding, golden 구현, 전체 출력 metric, artifact target 이름, 개인정보를 지운
log가 포함됩니다. “이 정확한 지점에서 실패”도 일급 결과입니다.

## 현재 한계를 한 번, 분명하게 적습니다

- Phoenix/7840U XDNA1에는 이전 실제 하드웨어 증거가 있지만 **현재 exact v1
  lock을 그 장치에서 아직 다시 실행하지 않았습니다**.
- Strix Point `RyzenAI-npu4`는 이 저장소에서 **현재 lock으로 하드웨어 검증한
  XDNA2 target**입니다.
- Strix Halo `npu5`, Krackan `npu6`, 이후 또는 알 수 없는 장치는 Strix
  Point로 조용히 취급하지 않고 **의도적으로 거부합니다**.
- wake-word weight와 ONNX MLP는 합성 템플릿입니다. camera 경로는 segmentation
  network가 아니라 box blur를 사용합니다. 실행과 통합 surface를 증명할 뿐,
  production model 품질을 증명하지 않습니다.
- W4A16은 검증된 커널이지 model runtime이 아닙니다: 양자화 GEMM이 Strix
  Point에서 5.94 TOPS로 CPU 참조를 통과했지만, 양자화 *모델*이 이를 통해
  end-to-end로 실행되지는 않습니다.
- XDNA1에서 임의의 LLM, GGUF, PyTorch, ONNX model이 이 저장소를 통해
  end-to-end로 실행되지는 않습니다. 미지원 op와 CPU fallback은 눈에 보여야
  합니다.
- 특정 dependency snapshot, device, shape, power mode의 pass를 다른 조건의
  pass로 간주할 수 없습니다. source build는 크고 upstream interface는
  변합니다.
- NPU가 자동으로 더 빠르거나 효율적인 것은 아닙니다. 전체 application을 CPU,
  iGPU baseline과 비교하고 더 나은 fallback을 유지하십시오.

전체 장치 상태는 [SUPPORT.md](SUPPORT.md), 더 깊은 operator와 application
경계는 [APPLICATIONS.ko.md](APPLICATIONS.ko.md), direct-kernel 증거는
[MLIR-AIE.ko.md](MLIR-AIE.ko.md)에 있습니다.

## 문을 열어 둡니다

결과를 돌려주지 않더라도 이 작업을 자유롭게 사용하십시오. 돌려주고 싶다면
하드웨어 결과 하나, 고친 문장 하나, 호환 라이선스의 학습 weight set 하나,
축소한 compiler failure 하나, 번역 하나, power 측정 하나도 다음 사용자에게
도움이 됩니다.

재현 가능한 결과물은 [Open NPU experiment 양식](../.github/ISSUE_TEMPLATE/experiment.yml)으로
공유하고, 아직 동료가 필요한 아이디어라면 [GitHub Discussions](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/discussions)에서
시작하십시오. 올바른 증거 라벨이 붙은 compile-only 결과와 잘 축소된 실패도 환영합니다.

이 프로젝트는 모두에게 같은 LLM을 만들라고 요구하지 않습니다. 이미 가진
하드웨어로 서로 다른, 내부를 살펴볼 수 있는 결과물을 만들고, 다음 사람이
모험을 이어 갈 만큼의 증거를 남겨 달라는 요청입니다.

정직하고 유용한 작업 하나를 실행하는 NPU는 더 이상 장식이 아닙니다.

## 1차 출처와 실험 범위

[^amd-7840u]: **출발 장치 — Ryzen 7 PRO 7840U / XDNA1.** AMD의 정확한 [Ryzen 7 PRO 7840U 지원 페이지](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen-pro/ryzen-pro-7000-series/amd-ryzen-7-pro-7840u.html)는 출발 processor와 Phoenix codename을 확인합니다. AMD [Ryzen 7 7840U 제품 페이지](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html)는 sibling 7840U Ryzen AI NPU의 최대 10 TOPS를 기록하고, 정확히 시험한 장치는 이 저장소의 하드웨어 기록으로 확정합니다.

[^ryzenai-linux]: **현재 turnkey Linux 범위 — STX/KRK, 2026-08-15 확인.** [AMD Ryzen AI Software 1.8.0 Linux 설치 문서](https://ryzenai.docs.amd.com/en/latest/linux.html)는 현재 release가 STX와 KRK를 지원한다고 밝히고 CNN, encoder NLP, NPU-only LLM flow를 설명합니다. Phoenix는 열거하지 않습니다. 이 문서는 이후 바뀔 수 있습니다.

[^amdxdna]: **driver/runtime 토대 — 여러 XDNA 세대.** [`amd/xdna-driver`](https://github.com/amd/xdna-driver)는 Linux `amdxdna` driver와 XRT shim을 위한 AMD의 source 저장소입니다. driver에 보인다는 사실만으로 model이 실행되는 것은 아닙니다.

[^iree-amd-aie]: **compiler/runtime 프로젝트 — 이 저장소가 사용하는 초기 공개 경로.** [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)는 upstream IREE AMD AIE plugin입니다. 이 저장소의 주장은 고정한 revision과 기록된 target에만 적용됩니다.

[^mlir-aie]: **close-to-metal 프로젝트 — AIE array와 direct kernel.** [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)는 IRON을 명시적인 tile 배치, data movement, vector compute를 다루는 open MLIR 기반 compiler toolchain 위의 Python API로 설명합니다. upstream 기능이 곧 이 저장소의 hardware/pin 결과가 되는 것은 아닙니다.

[^iron-dashboard]: **upstream Phoenix 하드웨어 CI — AIE2와 AIE2P 구분.** AMD [`IRON` exact `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e)과 2026-08-15 성공한 [“Phoenix - Extensive Benchmark/Test Suite”](https://github.com/amd/IRON/actions/runs/31876069460)는 기본 5회 반복에서 pytest case-run 2,105개 PASS와 45개 SKIP을 기록합니다. 이는 고유 pass parameter 구성 421개와 고유 skip 구성 9개입니다. skip은 MHA 3개, streaming-SwiGLU-prefill 3개, GEMV+GELU 3개이며 각각 5회 반복됩니다. 이는 upstream 하드웨어 증거이며 이 저장소의 acceptance matrix나 current-lock XDNA1 재실행이 아닙니다.

[^phoenix-gpt2]: **공개된 Phoenix XDNA1 실험 — Ryzen 9 7940HS이며 이 저장소의 7840U가 아님.** A. Rösti, M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools,” arXiv:2504.03083 (2025)](https://arxiv.org/abs/2504.03083). 2.8배/1.7배/1.2배/1.4배 수치는 논문의 hybrid GPT-2 124M fine-tuning 구성과 baseline에 속합니다.

[^steel]: **공개된 세대 교차 attention 실험 — baseline을 분리해서 읽어야 함.** V. J. B. Jung 외, [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU,” arXiv:2607.09385 (2026)](https://arxiv.org/abs/2607.09385). 논문은 코드를 [`amd/IRON`](https://github.com/amd/IRON)에 공개한다고 명시합니다. 9.6배는 XDNA1 port 대 DATO 결과이고, CPU energy 9.17배, GPU energy 1.75배, layer-by-layer 22.8배는 논문의 XDNA2 실험 결과입니다.
