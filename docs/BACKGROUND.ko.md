**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# 배경: XDNA1, XDNA2, 그리고 Linux의 두 공개 경로

## 턴키 스택이 다음 세대로 옮겨갔다고 실리콘이 쓸모없어지는 것은 아니다

AMD Ryzen AI NPU는 Xilinx에서 이어진 **AI Engine(AIE)** 공간형 어레이다.
VLIW 벡터 타일들이 스트리밍/DMA 인터커넥트로 연결되고, 메모리 행과 shim 행이
호스트를 잇는다. CUDA식 범용 GPU처럼 다루는 대신 타일에 연산을 배치하고 그
사이의 데이터 흐름을 라우팅한다.[^iron-guide]

| | **XDNA1** (Phoenix/Hawk Point) | **XDNA2** (Strix 및 관련 장치) |
|---|---|---|
| 탑재 제품 | Ryzen 7040/8040, **7840U** 포함 | Ryzen AI 300 계열 |
| 타일 아키텍처 | AIE2 (`aie2`) | AIE2P |
| 이 저장소의 타깃 | Phoenix: 사용 가능 4열, `npu1_4col` | 검증된 Strix: `npu4` |
| 명목 NPU 성능 | 7840U 최대 10 TOPS[^amd-7840u] | Ryzen AI 300 최대 50 TOPS[^amd-platform-guide] |

7840U 공식 사양은 여전히 최대 10 TOPS Ryzen AI 엔진을 명시한다. 현재의
애플리케이션 소프트웨어가 Phoenix를 지원 목록에 올리지 않는다고 그 연산
능력이 사라지는 것은 아니다.[^amd-7840u]

## 2026-08-15 현재 Linux 상황

커널 기반은 두 세대가 공유한다. AMD의 공개 `amdxdna` 드라이버는 지원 장치를
Linux accelerator 인터페이스에 노출하며, AMD는 드라이버, XRT shim, 펌웨어
요구사항과 설치 안내를 공개한다.[^amdxdna]

편리한 제품 계층의 지원 범위는 세대별로 다르다. AMD Ryzen AI Software 1.8
for Linux 문서는 **STX와 KRK**를 열거하며 Phoenix/XDNA1은 포함하지
않는다.[^ryzenai-linux] 이것은 현재 턴키 지원 표에 대한 설명이지, XDNA1이
Linux에서 연산할 수 없다는 판정이 아니다.

XDNA1 실험자에게는 이제 **두 개의 공개된 저수준 경로**가 있다.

1. **이 저장소가 패키징한 경로:** 정확한 버전을 고정한
   [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) 스택이다.
   IREE 프로그램을 lowering하고 장치별 VMFB를 만들며 `amdxdna` HAL로
   호출한다. 여기의 스크립트는 버전 고정, 빌드, 감지, 실행, 모든 출력의 CPU
   대조를 묶는다. 공개된 Phoenix 측정은 당시 nightly로 얻은 과거 실기
   결과이며, 현재 v1 정확 핀은 Strix에서 재검증됐지만 Phoenix 재실행은 남아 있다.
2. **직접 커널 경로:** Peano와 XRT를 쓰는
   [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)다. 이 저장소는 IRON
   Python API/컴파일러 스택을 1.4.1에 고정하며 개발자는 공간형 AIE 커널과
   데이터 이동을 직접 작성한다. 더 새로운 연산자·애플리케이션 라이브러리
   [`amd/IRON`](https://github.com/amd/IRON)은 MLIR-AIE 언어 바인딩 위의 별도
   프로젝트이며 `Xilinx/mlir-aie`의 이름 변경이나 새 위치가 아니다. 그
   업스트림 결과는 재현할 연구 단서이지 릴리스 핀이 물려받는 보증이 아니다.

AMD IRON 커밋
[`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93)의 공식 Phoenix
workflow는 **pytest case-run 2,105개 통과, 45개 건너뜀**으로 완료됐다.[^iron-phoenix-ci]
기본 5회 iterations이므로 이는 **서로 다른 통과 구성 421개와 서로 다른 skip
구성 9개**다. 9개 skip은 MHA 3개, streaming-SwiGLU 3개, GEMV+GELU 3개
구성이고 각각 5회 반복됐다. AIE2/Phoenix 실기 실행의 통과 범위에는 CPU
기준값으로 대조한 GEMM/GEMV, Q4NX 역양자화,
softmax, RoPE, RMSNorm/LayerNorm, activation, transpose가 포함된다. 이는
XDNA1이 유용한 ML 커널 실험실이라는 강한 업스트림 근거다. 그러나 이 저장소의
정확한 v1 스택을 다시 실행한 결과도, XDNA1 엔드투엔드 LLM 주장도 아니다.
MHA와 streaming-SwiGLU는 정확한 skip에 포함되며 GQA는 이 Phoenix run으로
입증되지 않았다. 결과에는 반드시 그 경계가 따라야 한다.

## 이 저장소의 `amdxdna` HAL 경로가 장치에 도달하는 방식

`iree-amd-aie`는 지원 연산을 다음 구성으로 컴파일한다.

1. **AIE 코어 프로그램:** Peano(`llvm-aie`)가 해당 AIE 아키텍처용 타일별
   코드를 컴파일한다.
2. **구성 및 제어:** 데이터플로 lowering, 라우팅, DMA/제어 코드와 장치
   프로그램을 `.vmfb`로 패키징한다.
3. **호스트 호출:** IREE `amdxdna` HAL이 `/dev/accel/accel0`을 열고 커널
   UAPI를 통해 명령을 제출한 뒤 fence를 기다린다. 이는 IRON 예제의 별도
   XRT/`pyxrt` 호스트 경로와 다르다.

장치 geometry도 정확성 계약의 일부다. 검증된 Phoenix 매핑에서는
`npu1_4col`과 `--amdxdna_n_core_cols=4`가 일치해야 한다. 이 저장소는 이후의
알 수 없는 장치에 타깃을 추측해 넣지 않는다. [GOTCHAS #6](GOTCHAS.ko.md)과
[지원 표](SUPPORT.md)를 참고하라.

## 두 경로가 모두 중요한 이유

IREE 경로는 반복 가능한 애플리케이션 통합과 지속형 C/Python 런타임을
실용적으로 만든다. IRON 경로는 타일, FIFO, 커널, 계속 움직이는 연산자
최전선을 드러낸다. 둘을 함께 쓰면 일반 노트북 사용자도 CPU로 대조한
matmul에서 출발해 하이브리드 로컬 AI를 조합하고, 컴파일러나 연산자 경계를
한 번에 하나씩 넓힐 수 있다.

전체 프로젝트 지도는 [Open NPU Lab](OPEN-NPU-LAB.ko.md), 1차 자료와 주장
범위는 [연구 원장](RESEARCH.md), 남은 작업은 [LLM 로드맵](LLM-ROADMAP.md)을
참고하라.

[^amd-7840u]: AMD, [Ryzen 7 7840U 공식 사양](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html).
[^amd-platform-guide]: AMD, [Ryzen and Radeon consumer pocket guide](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/amd-consumer-pocket-guide-ryzen-radeon-july-2024.pdf), 2024년 7월.
[^amdxdna]: AMD, [`xdna-driver`: AMD NPU용 Linux 드라이버와 XRT 인터페이스](https://github.com/amd/xdna-driver).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 — Linux 시스템 요구사항과 지원 플랫폼](https://ryzenai.docs.amd.com/en/latest/linux.html), 2026-08-15 확인.
[^iron-guide]: AMD IRON, [Programming guide](https://github.com/amd/IRON/blob/main/programming_guide/README.md).
[^iron-phoenix-ci]: AMD IRON, [공식 Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 커밋 `cdc48e93`.
