**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — 무엇이 달라지고, 무엇이 이어지는가

이 저장소는 **XDNA1**(Phoenix/Hawk Point)을 위한 검증된 지도다. XDNA1에서는
소스에서 빌드한 `iree-amd-aie`가 여전히 Linux에서 NPU 연산을 돌리는 *유일한*
길이다. 이 페이지는 **XDNA2**(Strix Point / Strix Halo / Krackan)에 대한 솔직한
델타다: 이 저장소의 레시피와 도구 중 무엇이 그대로 이어지는지, 2세대에서 무엇이
달라지는지, 그리고 열린 최전선이 지금 어디에 있는지.

아래에는 두 종류의 주장이 있으며, 명확히 구분해 두었다:

- **✅ 검증됨(Verified)** — 실제 XDNA2 머신에서 재현됨:
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · kernel 7.0
  · 인트리 `amdxdna` · NPU FW 1.1.2.64**.
- **🔎 조사됨(Researched)** — 상류(upstream) 저장소/문서/벤치마크(2026년 8월)에서
  취합했고, 인라인으로 링크를 달았으며, 여기서 아직 재현하지는 않았다.

## TL;DR

| | XDNA1 (이 저장소의 홈그라운드) | XDNA2 |
|---|---|---|
| Linux에서 턴키 LLM | ❌ 없음 — 출시된 모든 스택에서 제외됨 | ✅ FastFlowLM + Lemonade 10.0 (2026-03부터) |
| XRT 유저스페이스 | 이 저장소대로 빌드/설치 | ✅ **Ubuntu 26.04가 기본 탑재로 배포** (`libxrt-npu2`) |
| 커스텀 커널 (열린 경로) | `iree-amd-aie` / `mlir-aie` 소스 빌드 | 동일 스택, 지원은 더 좋아짐: IRON 1.4.x는 Strix를 일급(first-class)으로 다룬다 |
| 기여가 살아 있는 곳 | *무엇이든* 돌아가게 만들기 | 오픈 커널 격차 메우기 (턴키 NPU 커널은 프로프라이어터리) |

이 저장소가 가르치는 모든 것 — XRT 배관 작업, memlock/render 그룹 활성화,
디스패치 오버헤드, Peano, IRON 커널 작성 — 은 **그대로 이어진다**. 달라지는 것은
타깃 이름, 어레이 기하 구조, 그리고 "NPU에서 LLM 돌리기"가 XDNA2에서는 더 이상
최전선이 아니라는 사실이다. 이제 최전선은 **열려 있고, 양자화되고, 튜닝된 커널**이다.

## ✅ 검증됨: 오늘의 Strix Point 머신, 이 저장소의 도구 그대로

XDNA2 머신에서 수정 없이 `scripts/check-npu.sh`를 실행하자 스크립트 버그
세 개(모두 이 커밋에서 수정됨 — 아래 참조)와 다음의 실제 상태가 드러났다:

```
[1] amdxdna module loaded                       ✓
[2] 1022:17f0 Strix/Krackan/Strix Halo NPU      ✓  (XDNA2)
[3] /dev/accel/accel0 root:render 0660, RW      ✓
[4] user in 'render' group                      ✓
[5] memlock = 8192 KB                            ✗  ← the same old blocker
[6] xrt-smi present (2.21.75) but:               ✗
    mmap(len=64MB, MAP_LOCKED) failed (err=-11)
[7] pyxrt present, cannot open device            ✗  (same cause)
```

특기할 만한 발견 세 가지:

1. **Ubuntu 26.04는 XDNA2 XRT 유저스페이스를 기본으로 배포한다.** `libxrt2`,
   `libxrt-npu2`, `libxrt-utils-npu`, `python3-xrt`(2.21.75)가 아카이브에서
   곧바로 설치된다 — XDNA1에도 같은 패키지가 존재하지만 출시된 어떤 런타임도
   모델을 실행해주지 않는 반면, XDNA2에서는 이것이 동작하는 런타임 경로다.
2. **활성화를 가로막는 요인은 XDNA1과 한 바이트도 다르지 않다** — 8 MB
   memlock 기본값이 xrt-smi의 64 MB `mmap(MAP_LOCKED)`를 `EAGAIN`으로 깨뜨리며,
   정확히 `scripts/enable-npu.sh`가 겨냥해 작성된 그 실패다 — **다만 예전
   수정법은 systemd 데스크톱에서는 소리 없이 적용되지 않는다.** limits.d는
   `pam_limits` 메커니즘이다; GUI 터미널은 `user@<uid>.service`의 자식이라
   대신 *그 서비스의* 8 MB `LimitMEMLOCK`을 물려받고, lingering이 켜져 있으면
   재로그인을 해도 그 서비스는 결코 재시작되지 않는다. 이제 `enable-npu.sh`는
   `user@.service` drop-in도 함께 쓰고 호출한 셸에 `prlimit`을 건다 — 전체
   해부는 [GOTCHAS #0](GOTCHAS.ko.md)에 있다.
3. **펌웨어는 출고 상태 그대로 최신이다**: FW 1.1.2.64가
   `amdnpu/17f0_10/`에서 로드되었다 — FastFlowLM이 요구하는 ≥ 1.1.0.0 하한선을 넘는다.

### ✅ 최종 상태: XDNA2 NPU가 enumerate 된다 (같은 머신, 같은 날)

memlock 수정이 진짜로 자리 잡은 뒤(drop-in + `prlimit`, gotcha #0), 일곱 개
검사가 모두 초록불이 되고 유저스페이스 스택이 디바이스를 연다:

```
$ xrt-smi examine
XRT
  Version              : 2.21.75
  amdxdna Version      : 7.0.0-29-generic
  NPU Firmware Version : 1.1.2.64
Device(s) Present
|BDF             |Name          |
|[0000:66:00.1]  |RyzenAI-npu4  |

$ python3 -c 'import pyxrt; d = pyxrt.device(0); \
    print(d.get_info(pyxrt.xrt_info_device.name))'
RyzenAI-npu4
```

`RyzenAI-npu4`는 아래 이름 해독표의 해당 행을 실제 하드웨어에서 확인해준다:
XRT에게 Strix Point는 `npu4`다. *여기까지* 오는 데 소스 빌드는 필요 없었다 —
XDNA2/Ubuntu 26.04에서 활성화는 컴파일이 아니라 설정의 문제다.

## ✅ 연산: XDNA2 NPU에서 검증됨 (같은 머신, 2026-08-15)

IRON 트랙은 활성화가 자리 잡은 바로 그날 돌아갔다 — `setup-mlir-aie.sh`
무수정, mlir-aie **1.4.1**(cp314 wheel), Peano wheel, Ubuntu의 `pyxrt`.
전체 표는 [MLIR-AIE.ko.md](MLIR-AIE.ko.md)에 있다; 헤드라인만 추리면:

- **8 컬럼 / 32 타일 전부에서 GEMM**(`whole_array`, 2048³): i8 **6.65 TOPS**,
  bfp16 경유 bf16 **4.64 TFLOPS** — 내부 타일 크기만으로 3.4×가 나왔다
  (32³ → 64³ 타일).
- **AIE2P는 bfp16을 원한다**: bf16 MAC은 XDNA2에서 약 ¼ 속도의
  *에뮬레이션*이다(XDNA1에서는 네이티브); `--emulate-bf16-mmul-with-bfp16 1`은
  공짜 속도다. 네이티브 bfp16ebs8 설계는 여기서 Peano로 컴파일된다;
  실행에는 `libxrt-dev`(C++ 호스트)가 필요하다.
- **Phoenix의 4 컬럼에서 `CREATE_HWCTX`에 실패하는 바로 그 설계인
  `ml/mobilenet`이** 8 컬럼 어레이에서는 **엔드투엔드로 돌아간다**:
  ~176 ms/추론.
- LLM 블록은 `npu2`에서 전부 통과한다: softmax, RoPE, SwiGLU, RMSNorm,
  matmul+활성화-에필로그.
- IRON 1.4.x API로 이식한 우리의 커스텀 `relu(a+b)` 커널은 **8 컬럼에서
  8.0×**로 스케일된다(`transform_parallel_binary`), 실효 11.2 GB/s.

### XDNA1 도구를 XDNA2에 들이대자 드러난 스크립트 버그 (수정됨)

- `check-npu.sh [1]`은 `pipefail` 아래에서 `lsmod | grep -q`를 사용했다: `grep -q`는
  첫 매치에서 종료하고, `lsmod`는 SIGPIPE로 죽으며(exit 141), 파이프라인은 "실패"한다 —
  모듈이 `lsmod` 출력의 앞쪽에 있을 때만 발동하는 경쟁적(racy) 거짓 음성이다
  (갓 부팅한 Strix 머신에서는 그렇다). 이제는 `/sys/module/amdxdna`를 검사한다.
- `check-npu.sh [2]`는 XDNA1의 lspci 문자열인 `IPU|AI`를 매칭했다. XDNA2는
  `Neural Processing Unit`(디바이스 `17f0`)으로 enumerate 된다. 이제 검사 항목은
  둘 다 매칭하고 어느 세대를 발견했는지 보고한다.
- `check-npu.sh [6]`은 [1]과 *같은* SIGPIPE 경쟁을 안고 있었다 — `pipefail`
  아래의 `xrt-smi examine | grep -q` — 다만 이쪽은 **NPU가 실제로 enumerate 되고
  나서야** 발동한다(매칭되는 줄이 성공한 리포트의 앞쪽에 있어서, `xrt-smi`가
  아직 출력을 쓰는 동안 `grep -q`가 먼저 빠져나간다). 이 검사 항목은 사상 첫
  성공적인 enumeration을 실패로 보고했고, 그 와중에 [7]의 `pyxrt`는 태연히
  디바이스를 열었다. 이제는 출력을 먼저 담아둔 뒤에 매칭한다.

## 🔎 이름 해독표 (세대 간 혼동의 1순위)

| 레이어 | XDNA1 | XDNA2 Strix Point | 출처 |
|---|---|---|---|
| lspci | `AMD IPU Device` (`1502`) | `Neural Processing Unit` (`17f0`) | ✅ 두 머신 모두 |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4` (Halo=`npu5`, Krackan=`npu6`) | ✅ 이 머신이 `RyzenAI-npu4`를 보고함 · [xdna-driver](https://github.com/amd/xdna-driver) |
| mlir-aie / IRON | `npu1` | `npu2` | [mlir-aie](https://xilinx.github.io/mlir-aie/) |
| iree-amd-aie | `npu1_4col` | `npu4` | [iree-amd-aie](https://github.com/nod-ai/iree-amd-aie) |
| ISA | AIE2 | AIE2P | [Peano](https://github.com/Xilinx/llvm-aie) |

## 🔎 뒤집힌 지형: XDNA2에는 턴키가 존재한다 — 단, 함정이 하나 있다

- **FastFlowLM**은 v0.9.35(2026-03-11)에서 네이티브 Linux 지원을 출시했는데,
  **XDNA2 전용**이다 — XDNA1은 여전히 제외되어 있으며, 이 저장소의 소스 빌드
  경로가 유일한 XDNA1 길로 남는 이유가 바로 그것이다. FLM v1.0.0은 AMD의
  [ROCm GitHub org](https://github.com/ROCm/FastFlowLM)로 이동했다(2026-08).
  **Lemonade 10.0**은 이를 OpenAI 호환 서버로 감싼다
  ([Linux 가이드](https://lemonade-server.ai/flm_npu_linux.html)).
- **함정은 이것이다:** FLM의 CLI는 MIT지만, 그 **NPU 커널은 무료로 쓸 수 있는
  프로프라이어터리 바이너리**다. 이는 사용하는 제품이지, 커널 작성을 배울
  코드베이스가 아니다. 오픈 커널 경로 — 이 저장소의 영역 — 가 이제 XDNA2
  기여가 살아 있는 곳이다.
- 세대와 무관하게 **Linux에는 여전히 없는 것**: ONNX Runtime의 Vitis AI EP
  ([문서](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html))
  — 따라서 `npu-trim`의 그래프 선별(screen-the-graph) 접근은 XDNA2에서도 그 틈새를 유지한다.
  Linux의 GAIA는 iGPU만 구동한다
  ([amd/gaia#1220](https://github.com/amd/gaia/issues/1220)이 NPU 경로를 요청하고 있다).

## 자산별 정리: 이 저장소에서 XDNA2로 이식되는 것

| 자산 | XDNA2 상태 | 달라지는 것 |
|---|---|---|
| `scripts/check-npu.sh` | ✅ 동작함 (이 커밋) | XDNA2 PCI 문자열 + 세대 보고; [6] 성공 쪽 SIGPIPE 수정; [5]는 이제 pam 대 systemd memlock 분리를 진단한다 |
| `scripts/enable-npu.sh` | ✅ 동작함 (이 커밋에서 확장됨) | 동일한 3가지 차단 요인; Ubuntu 26.04가 패키지를 미리 설치해 둔다 — 다만 systemd 데스크톱에서는 memlock 수정에 limits.d 위에 `user@.service` drop-in이 추가로 필요하다 ([gotcha #0](GOTCHAS.ko.md)) |
| `scripts/build.sh` (iree-amd-aie) | 🔎 이식될 것 | `npu4`는 지원되는 타깃이다; 프로젝트는 활발하다(Peano npu4용 softmax ukernel, ERT_CMD_CHAIN 배칭). 커밋 동기화(commit-lockstep) gotcha(고정된 xdna-driver)는 남아 있다 |
| `scripts/run-matmul.sh` | 🔎 이식될 것 | 타깃 `npu1_4col` → `npu4`; `amdxdna` HAL 플래그는 그대로다 |
| `tools/npu-runner` | 🔎 이식될 것 | IREE C API는 변경 없음 — npu4 빌드에 맞춰 재컴파일 |
| `tools/npu-trim` | ✅ 개념 그대로 유효 | op 커버리지 최전선은 이동하지만 접근법은 동일; 이를 대체할 벤더 EP는 Linux에 여전히 없다 |
| `mlir-aie` (IRON) 트랙 | ✅ **검증됨 — 가장 유력한 경로** (이 커밋) | IRON [1.4.1](https://github.com/Xilinx/mlir-aie/releases): Strix가 일급 지원(`npu2`), **Peano가 기본**, `aiecc`는 이제 C++ 바이너리, 예제는 lit 구동; 우리의 스크립트 + 커스텀 커널을 이식함(어노테이션 API 파괴적 변경 — [GOTCHAS](GOTCHAS.ko.md)); 수치는 [MLIR-AIE.ko.md](MLIR-AIE.ko.md)에. 이전 조사에 대한 정정: XRT 없는 런타임 **"HRX"는 존재하지 않는다** — 해당 모듈은 *XRT 백엔드를 쓰는* `aie.utils.hostruntime`이다; 그리고 [amd/IRON](https://github.com/amd/IRON)은 **wheel을 배포하지 않는다**(소스 설치 전용, mlir_aie 1.3.5.dev 스냅샷에 고정) |

## 🔎 커널을 작성할 때 중요한 하드웨어 델타

- **기하 구조**: npu1은 4컬럼 어레이다; Strix Point(`npu4`)는 **4행 × 8컬럼 —
  컴퓨트 타일 32개 + 메모리 타일 8개**로, 컬럼 경계에서 파티션 가능하며,
  펌웨어가 컨텍스트 스케줄링을 관리한다
  ([커널 문서](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **데이터타입**: AIE2P의 간판은 **bfp16 블록 부동소수점(block floating point)**이다 —
  값 8개가 8비트 지수 하나를 공유해, 값 8개당 9바이트다. Peano의 현재
  나이틀리 기준으로 이는 열린 스택에서 실재한다: clang이
  `__builtin_aie2p_*bfp16ebs8/16` 변환 빌트인과 `BFP576_BFP576_ACC2048`
  MAC 빌트인을 제공하고, `ml/block_datatypes` GEMM들이 Peano로 빌드된다(✅
  이 머신에서 컴파일됨). 그 이면: **bf16 MAC은 퇴보했다** — AIE2에서는
  네이티브 4×8×4, AIE2P에서는 bfp16 데이터패스를 통한 약 ¼ 속도
  에뮬레이션이다
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390),
  [Hello XDNA](https://tnzr.org/xdna/isa.html)). npu1에서 bf16용으로 튜닝한
  커널은 npu2 피크 처리량을 위해 bfp16으로 다시 써야 한다; 커널 C++는
  `__AIEARCH__`(20 = AIE2, 21 = AIE2P)로 아키텍처 분기(arch-gated)되며,
  업스트림은 `aie_kernels/aie2/`와 `aie2p/` 트리를 병렬로 유지한다.
- **ISA**: 공식 매뉴얼은 여전히 없지만 사실상 열려 있다 — Peano가 공개 LLVM에서
  이를 구현하고 있으며, [Hello XDNA](https://tnzr.org/xdna/isa.html)는 명령어별
  레이턴시와 함께 XDNA1/XDNA2 ISA를 재구성해 놓았다.

## 🔎 측정된 현실: XDNA2 NPU 위의 LLM (커널이 최전선인 이유)

- 50-TOPS XDNA2에서의 FLM: Llama 3.1 8B는 @1k ctx에서 **prefill 403 t/s**, decode
  12.8 t/s; gpt-oss-20b는 decode 18.2 @1k → 12.0 @32k
  ([FLM 벤치마크](https://fastflowlm.com/docs/benchmarks/llama3_results/)).
- 동일 실리콘 비교: NPU는 iGPU Vulkan 대비 **prefill 약 1.5배** 앞서고, decode는
  약 25% 뒤지며, 에너지 효율은 최대 약 10배 좋다. decode는
  메모리 대역폭 물리 법칙(CPU/iGPU/NPU가 공유하는 ~120 GB/s LPDDR5X)의 문제다 —
  어떤 엔진도 여기서 벗어나지 못한다.
- 오픈 코드의 눈금 조정점: 단순한(naive) 오픈 XRT 디스패치 llama.cpp 포크
  ([OllamaAMDNPU](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU),
  Strix Halo)는 prefill 18.4 t/s, decode 1.4 t/s에 도달한다 — FLM의 prefill
  300–400 t/s와의 격차는 **디스패치 배관이 아니라 커널/데이터플로 설계**다.
- 이치에 맞는 아키텍처는 **NPU-prefill + iGPU-decode 하이브리드**다 —
  정확히 AMD 자신의 Windows 스택이 작업을 나누는 방식이다.

## 다음으로 갈 곳

1. ~~4×8 어레이에서 IRON GEMM 재현~~ — **✅ 완료**(mlir-aie 1.4.1,
   어레이 전체 GEMM이 i8 6.65 TOPS / bf16-bfp16 4.64 TFLOPS, LLM 블록,
   전체 MobileNet; [MLIR-AIE.ko.md](MLIR-AIE.ko.md)). GQA/MHA:
   [amd/IRON](https://github.com/amd/IRON) op 라이브러리에 있지만 **aie2p
   전용**(head-dim 64만)이다 — 다만 그것은 소스 설치 전용이고, mlir_aie
   1.3.5.dev 스냅샷에 고정되어 있으며, 유일한 양자화 op는 *dequant*(Q4NX/AWQ
   → bf16)다. wheel 없음, 융합 W4A16 없음.
2. **iree-amd-aie matmul 레시피와 `npu-runner`를 `npu4`로 이식**하고, XDNA1
   대 XDNA2 수치를 나란히 공개한다. (이 머신에서는 빌드 도구만이 걸림돌이다 —
   `ninja`/`lld`는 apt 설치가 필요하다; 플로 자체는 이식될 것으로 예상된다:
   `npu4`는 지원되는 타깃이다.)
3. **양자화 prefill GEMM** — 이제 정밀하게 지도가 그려진 기여 지점:
   [TileFuse](https://arxiv.org/abs/2606.11357)가 W4A16 레시피를 *코드와
   함께* 공개했다
   ([glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
   main보다 약 13개월 뒤처진 포크, **chess 우선**에 Peano는 옵션; AWQ
   group-128, k-타일 = 그룹 크기, dequant를 L1 weight-stationary 캐시와 함께
   타일 안에서 융합, Strix Point에서 9 TOPS). 열린 형태로는 어디에도 존재하지
   **않는** 것: 그 커널의 **현행 IRON 1.4.x + Peano 전용** 버전, 그리고 어떤
   llama.cpp 통합이든.
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725)는 여전히 열려
   있고 아무도 맡지 않았다(작성자의 WIP는 2026-04에 멈췄다; AMD 자신의
   활발한 노력은 HSA/ROCr 런타임 위의
   [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend)로 —
   Ubuntu의 XRT와는 다른 스택이다). 또한 업스트림에서 측정되어 훔쳐올 가치가
   있는 것: **64 KB 버퍼 정렬(SMMU 페이지)이 #21725에 인용된 IRON 실험에서
   10× decode 손잡이였다**.
   **이 머신에서 스파이크 확인(2026-08-15)**: TileFuse의 융합 dequant+GEMM
   커널(`mix_int4_ATB.cc`)이 **mlir-aie 1.4.1 헤더에 대해 Peano `aie2p`
   타깃으로 깔끔하게 컴파일된다**(`-Dbf16_bf16_ONLY`, m64/k128/n64 →
   `matmul_bf16_bf16`) — 포팅 갭은 커널이 아니라 ObjectFifo 설계 + 호스트
   패킹이다.

*상태: 2026-08-15에 페이지 추가; 같은 날 위의 Strix Point 머신에서 활성화에
이어 IRON 연산까지 검증했다. 🔎 항목들은 출처를 인라인으로 달고 있다.*
