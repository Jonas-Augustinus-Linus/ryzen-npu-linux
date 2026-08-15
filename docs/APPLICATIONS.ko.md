**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Linux에서 XDNA1 NPU로 무엇을 만들 수 있는가?

Ryzen 7 7840U 같은 Phoenix 계열 노트북을 가진 사람을 위한 실용적인 지도입니다.
모든 모델이 곧바로 돌아간다고 포장하려는 문서가 아닙니다. 이미 사람들의 기기 안에
들어 있는 실리콘을 열린 Linux 연구실로 바꾸는 것이 목적입니다. 유용한 한 단계를
실행하고, 모든 출력을 신뢰할 수 있는 CPU 결과와 비교하고, CPU 및 iGPU와 조합하고,
다음 사람이 이어갈 수 있을 만큼 충분한 증거를 공개합니다.

이 저장소에서 작성한 모든 내용은 MIT 라이선스입니다. **누구나 라이선스 조건에 따라
사용하고, 복사하고, 수정하고, 포크하고, 공개하고, 재배포할 수 있습니다.** 프로젝트의
뜻은 [Open NPU Lab](OPEN-NPU-LAB.ko.md), 이 저장소 밖으로 이어지는 1차 자료와 연구
갈래는 [Research branches](RESEARCH.md)를 참고하십시오.

## 기능보다 먼저 증거 라벨을 읽으십시오

- **저장소 실기:** 이 저장소가 명시한 NPU에서 실행하고 전체 결과를 확인했습니다.
  현재 lock의 증거는 Strix Point `npu4`에 있습니다. Phoenix에는 소중한 이전 실기
  결과가 있지만, 현재 lock으로 다시 실행하는 일이 남아 있습니다.
- **업스트림 실기:** 업스트림 프로젝트가 하드웨어에서 실행했습니다. 재현해 볼 경로이지,
  이 저장소가 자동으로 물려받는 결과는 아닙니다.
- **템플릿 / 배관:** 실제 NPU dispatch 또는 Linux I/O이지만, 학습된 제품 대신 합성
  가중치나 설명용 연산을 사용합니다.
- **컴파일 전용 / 프로젝트:** 아직 하드웨어 실행과 수치 정확성 관문을 통과하지 않았습니다.

컴파일은 실행이 아니고, 실행은 정확성이 아니며, 커널 시간은 애플리케이션 결과가
아닙니다. 이 저장소는 아직 NPU 에너지를 측정하지 않았으므로 배터리 수명 향상을
주장하지 않습니다.

## 열린 소프트웨어 경로는 하나가 아닙니다

이 문서의 이전 판에 적힌 좁은 연산자 한계는 **저장소가 commit `fddfec1b`에 고정한
`iree-amd-aie` backend**에 관한 것입니다. XDNA1 생태계 전체의 한계가
아닙니다.[^iree-amd-aie]

| 경로 | 증거가 보여주는 것 | 경계 |
|---|---|---|
| 이 저장소에 고정된 `iree-amd-aie` | 신중히 맞춘 bf16/i8/i32 matmul, persistent dispatch, hybrid 예제를 검증했습니다. conv 경로는 좁고 target에 따라 다릅니다. | 현재 exact lock의 실기 증거는 `npu4`입니다. 공개된 7840U 결과는 이전 동작 snapshot을 사용했습니다. 지원하지 않는 imported graph 영역이 조용히 CPU로 fallback하지 않습니다. |
| 이 저장소에 고정된 `mlir-aie` 1.4.1 경로 | direct IRON kernel과 upstream 예제가 이 저장소의 Strix Point 시스템에서 실행됐습니다. 배치와 데이터 이동을 직접 제어하는 제작자를 위한 더 낮은 수준의 경로입니다. | 이 exact 경로는 저장소의 XDNA1 실기에서 아직 재실행하지 않았습니다. |
| 계속 움직이는 [`amd/IRON`](https://github.com/amd/IRON) | exact commit `cdc48e93`에서 2026-08-15 AMD Phoenix hardware workflow는 기본 5회 반복으로 **2,105 passing / 45 skipped case-run**, 즉 **서로 다른 통과 구성 421개 / 서로 다른 skip 9개**를 기록했습니다. 통과한 AIE2 범위에는 bf16 GEMM/GEMV, Q4NX dequantization, softmax, RoPE, RMSNorm, LayerNorm, activation, transpose, SwiGLU decode/prefill 변형이 포함됩니다.[^iron-phoenix] | 강력한 **업스트림 Phoenix 증거**이지만 이 저장소의 exact-v1 XDNA1 재실행이나 완전한 LLM은 아닙니다. 서로 다른 skip 9개는 MHA 3개, streaming-SwiGLU-prefill 3개, GEMV+GELU 구성 3개이며, 각각 5회 반복되어 15 case-run짜리 세 그룹이 됩니다. MHA/GQA dashboard는 여전히 AIE2P 전용입니다. |

중요한 정정은 단순합니다. “이 고정 backend가 어느 op를 lowering하지 못한다”는 말은
**“XDNA1이 그런 종류의 kernel을 실행할 수 없다”는 뜻이 아닙니다.** 각 주장에 붙은
정확한 toolchain, device, test, 수치 oracle을 따라가야 합니다.

## ONNX: 가져오고, 추출하고, 조합은 애플리케이션이 소유합니다

현재 [`scripts/build.sh`](../scripts/build.sh)는 별도로 고정한
`iree-import-onnx`를 설치합니다. 저장소 workflow를 위해 IREE를 다시 빌드하거나 Python
binding을 추가할 필요가 없습니다. [`tools/npu-trim`](../tools/npu-trim/)은 graph를
import하거나 검사하고, 독립적인 matmul/conv shape를 찾고, 깨끗한 kernel을 내보내고,
감지한 target별로 하나씩 시험 컴파일할 수 있습니다.

의도적으로 임의의 모델 전체를 다시 만들거나 실행하지는 않습니다. 가중치,
padding/layout 변환, 지원하지 않는 op, CPU fallback, orchestration은 애플리케이션의
몫입니다. [`examples/onnx-mlp`](../examples/onnx-mlp/)가 실행 가능한 계약입니다.
NPU matmul → CPU ReLU → NPU matmul을 bf16 CPU oracle과 대조합니다.

```text
ONNX ── 고정 importer ──▶ npu-trim ──▶ target 표시가 붙은 matmul/conv VMFB
                                          │
                         앱이 소유하는 가중치, layout, scheduling
                                          │
                           NPU kernel + 명시적인 CPU glue/fallback
```

## 로컬 LLM 시스템은 세 프로세서를 함께 쓸 수 있습니다

NPU가 LLM 전체를 서빙하지 않아도 NPU가 맡은 일은 충분히 유용합니다.

```text
마이크 / 카메라 / 문서 / UI event
                    │
                    ▼
      NPU: 상시 trigger, feature block,
           linear/fused block, 분류 또는 scoring
                    │
                    ▼
      CPU: I/O, tokenization, top-k, tool, policy,
           미지원 op와 신뢰할 수 있는 fallback
                    │
                    ▼
      iGPU: prefill과 token 생성을 담당하는
            검증된 양자화 local-LLM runtime
```

열린 attention, normalization, quantization kernel이 성숙하면, 측정된 block을
애플리케이션 전체를 버리지 않고 CPU/iGPU에서 NPU로 옮길 수 있습니다. 이것이 단순한
희망이 아니라 연구 경로임을 두 공개 결과가 보여줍니다.

- Rösti와 Franz는 **GPT-2 124M fine-tuning**의 GEMM을 1세대 Phoenix NPU에
  배치하고 나머지는 CPU에 두었습니다. 저자들의 환경에서 offload한 행렬곱은 **2.8배
  이상**, end-to-end throughput은 전원 연결 시 **1.7배**, 배터리 시 **1.2배**,
  배터리 energy efficiency는 **1.4배**라고 보고했습니다.[^phoenix-gpt2] 저자들의
  수치이며 이 저장소의 측정값이 아닙니다.
- STEEL은 인용한 이전 XDNA1 attention baseline인 DATO 대비 평균 **9.6배 XDNA1
  latency speedup**을 보고했습니다. 이와 별개의 HX 370/XDNA2 실험에서는 자체 CPU와
  GPU baseline 대비 각각 **9.17배**, **1.75배** 낮은 energy use, 자체 layer-by-layer
  XDNA2 구현 대비 **22.8배**를 보고했습니다.[^steel] XDNA1 latency 실험과 XDNA2
  energy 실험을 섞어 읽으면 안 됩니다.

## 지금 실행하고, 교체하고, 확장할 수 있는 것

| 출발점 | 지금 실제인 부분 | 유용한 다음 단계 |
|---|---|---|
| [`local-rag-sidecar`](../examples/local-rag-sidecar/) | **저장소 실기 (`npu4`):** 결정적 CPU hashing → persistent NPU 256×256 bf16 score matrix → CPU top-k → 선택적 LLM endpoint. 기본적으로 literal loopback host인 `127.0.0.1` 또는 `::1`로만 제한되며, remote endpoint에는 명시적인 `--allow-remote` opt-in이 필요합니다. 65,536개 출력을 모두 검사합니다. | hashing을 라이선스가 명확한 학습 embedding이나 projection으로 바꾸고, query를 batch로 묶고, XDNA1에서 재실행하십시오. 작은 query 하나라면 CPU dot product가 더 빠를 가능성이 큽니다. 이 예제는 통합과 정확성을 증명하지 보편적인 가속을 주장하지 않습니다. |
| [`wake-word`](../examples/wake-word/) | **템플릿:** 실제 CPU log-mel과 세 번의 persistent NPU dense dispatch. 제공 가중치는 설명용 matched filter입니다. | 실제 wake-word/intent 가중치를 학습하고 라이선스를 명시하고, 실제 음성과 false accept를 평가한 뒤 iGPU/CPU local assistant를 깨우십시오. |
| [`onnx-mlp`](../examples/onnx-mlp/) | **템플릿:** 실제로 import한 두 matmul hybrid forward pass이며 dispatch별 및 end-to-end CPU 검사가 있습니다. | 학습된 intent, routing, safety, projection head로 바꾸되 shape별 kernel과 oracle을 유지하십시오. |
| [`npu-camera`](../examples/npu-camera/) | **애플리케이션 배관:** GStreamer → persistent NPU → `v4l2loopback`. NPU demo 연산은 2-pass box blur이지 segmentation이 아닙니다. | 한 단계를 학습된 지원 vision block으로 바꾸고 resize, compositing, fallback은 CPU에 남기십시오. |
| [`npu-runner`](../tools/npu-runner/) | **저장소 실기:** VMFB를 한 번 load하고 C 또는 Python에서 반복 호출하며 전체 출력을 검사합니다. | batch scoring, sensor 분류, 재사용 가능한 model sidecar용 local daemon을 만드십시오. |
| [`mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **direct-kernel 연구실:** 들여다볼 수 있는 spatial code와 multi-column 실행입니다. | AMD IRON의 AIE2 op 하나를 Phoenix에서 재현하고, 배치, transfer, CPU golden, 최초 실패 shape를 공개하십시오. |
| [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | **컴파일 전용:** 고정된 외부 W4A16 front-end probe입니다. | 성능을 주장하기 전에 lowering, linking, weight packing, NPU 실행, 양자화를 고려한 정확성을 완성하십시오. |

## 더 넓은 애플리케이션 방향

| 사람의 필요 | NPU 크기의 실험 | 명시적으로 다른 곳에 둘 부분 |
|---|---|---|
| 개인 로컬 assistant | wake word, intent/safety head, batch retrieval scoring | CPU orchestration, CPU/iGPU generation |
| 개인 검색 | projection과 query×document score matrix | parsing, 저장, top-k, 최종 generation |
| 접근성 | 소리, presence, gesture, UI-event classifier | capture와 application policy |
| 카메라/프라이버시 | 지원되는 conv 또는 linear stage | capture, resize, compositing, `v4l2loopback` |
| 오디오 | batch conv/linear feature 또는 denoising block | PipeWire, STFT, hard real-time fallback |
| 게임 | 음성, intent, offline content용 native Linux companion | Proton game/render loop와 frame-critical 작업 |
| 컴파일러 연구 | fusion, tiling, packet flow, 양자화 kernel | CPU reference와 재현 가능한 harness |

부정적인 경계도 사실로서 중요합니다. FPS 향상, frame generation, render loop 안의
upscaling을 제공하는 경로는 여기에 없습니다. Proton에서는 별도 native Linux companion이
현실적인 실험 경계입니다. 전통적인 GRU/LSTM workload는 자체 lowering이 필요하거나 CPU에
남겨야 합니다. 임의의 transformer/Whisper/vision graph는 저장소 고정 backend에 모델
전체를 바로 넣어 돌리는 방식이 아닙니다. 이것들은 탐구할 interface이지 기기를 쓰지 않을
이유가 아닙니다.

## 재현 가능한 실험 사다리

엄격한 device와 correctness 검사부터 시작하십시오.

```bash
./scripts/check-npu.sh --strict
./scripts/run-matmul.sh bf16 512 512 512
```

그다음 기존 application seam 하나를 고르십시오.

```bash
./examples/local-rag-sidecar/run.sh --cpu-only --selftest
./examples/local-rag-sidecar/run.sh --selftest       # 지원되는 실제 NPU
~/src/iree-aie-venv/bin/python tools/npu-trim/npu_trim.py model.onnx
```

확장할 때마다 device identity, exact commit/lock, model 및 data license, shape와
precision, 전체 출력 tolerance, raw log, latency, 그리고 실제로 측정한 뒤에만 system
energy를 공개하십시오. CPU fallback을 유지하십시오. 재현 입력을 가진 최소 실패도 유용한
열린 연구입니다.

## 더 이어갈 곳

- 미션, 증거 계약, 기여 사다리:
  [Open NPU Lab](OPEN-NPU-LAB.ko.md)
- 1차 논문, 업스트림 코드, 다음 연구 질문:
  [Research branches](RESEARCH.md)
- 세대별 target과 현재 XDNA2 증거:
  [XDNA2 안내](XDNA2.ko.md)
- 더 긴 transformer milestone:
  [LLM roadmap](LLM-ROADMAP.md)

목표는 하나의 대표 demo가 아닙니다. 일반 사용자, 학생, 연구자가 NPU를 잊어버리지 않고
재사용할 수 있게 만드는 많은 검증 가능한 실험입니다. source를 가져가고, 바꾸고, 여러분의
결과를 또 다른 사람의 출발점으로 만들어 주십시오.

## 1차 자료

[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie). 저장소 lock은 `fddfec1be6ceefbdb890079d957947dfa1fe0848`입니다. 이 절은 이 backend를 설명하며 모든 XDNA compiler 경로의 한계를 말하지 않습니다.
[^iron-phoenix]: AMD, [`IRON` commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) 및 [Phoenix extensive hardware workflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15. workflow 기본 5회 반복에서 2,105 passing / 45 skipped case-run은 서로 다른 통과 구성 421개 / 서로 다른 skip 9개에 해당합니다. 업스트림 CI는 움직이므로 재현할 때 commit을 고정해야 합니다.
[^phoenix-gpt2]: A. Rösti, M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025. 1세대 Phoenix, Ryzen 9 7940HS, hybrid GPT-2 124M fine-tuning.
[^steel]: V. J. B. Jung 외, [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. 논문은 open-source implementation 경로로 [`amd/IRON`](https://github.com/amd/IRON)을 제시합니다.
