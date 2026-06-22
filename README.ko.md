**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# **Linux**에서 Ryzen AI **XDNA1** NPU로 실제 연산 돌리기

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1](https://img.shields.io/badge/NPU-Ryzen%20AI%20XDNA1-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)를 소스에서 빌드하여,
AMD Ryzen AI **1세대(XDNA1 / "Phoenix")** NPU를 *드라이버에는 보이지만 놀고 있는* 상태에서
**실제로 matmul을 실행하는** 상태로 끌어올리는, 재현 가능한 엔드투엔드 레시피 — 도구까지 포함.

> **이 저장소가 존재하는 이유.** 2026년에 나온 "드디어 Ryzen AI NPU가 Linux에서 동작한다"는
> 거의 모든 글은 **XDNA2**(Strix/Krackan)에 관한 것이다. Ryzen 7040/8040 노트북(예: 7840U)에
> 들어있는 1세대 **XDNA1** 칩은 턴키 스택들 — AMD의 Linux용 Ryzen AI Software, ONNX Runtime의
> Vitis AI EP, Lemonade/FastFlowLM — 에서 *명시적으로 제외*되어 있다. XDNA1+Linux 환경에서 NPU는
> 인트리(in-tree) `amdxdna` 드라이버에 의해 전원이 켜지고 enumerate 되지만, **출시된 어떤 런타임도
> 그 위에서 모델을 실행해주지 않는다.** XDNA1을 *실제로* 타깃하는 유일하게 열린 경로는 `iree-amd-aie`이며,
> 이는 소스에서 빌드해야 한다. 이 저장소는 그 경로를 검증하고 gotcha 하나하나까지 짚어낸 지도다.

## 🎬 데모

**엔드투엔드 — NPU에서 실행하는 ONNX MLP** (matmul은 NPU에서, `ReLU`는 CPU에서; CPU 레퍼런스와 ~0.3% 이내로 일치):

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python, **NPU에서 실행** | 세 가지 `videotestsrc` 패턴에 NPU 2D-blur 적용 → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| 웨이크워드 KWS — NPU에서 dense 레이어 3개 (타깃은 발화, 노이즈는 침묵 유지) | bf16은 NPU의 고유 강점 — 최대 **220 GFLOP/s** |
| ![wake-word demo](docs/media/wake-word.gif) | ![benchmark demo](docs/media/benchmark.gif) |
| 실제 `.onnx`를 NPU 타깃 가능한 MLIR로 가져오기 (하이브리드 임포트; 소스에서 빌드한 amd-aie 코드젠의 op 커버리지가 최전선이다) | NPU로 **실제** 컴파일되는 matmul만 추출 — `npu-trim`이 op를 선별하고 깔끔한 커널을 내보낸다 |
| ![onnx-import demo](docs/media/onnx-import.gif) | ![npu-trim demo](docs/media/npu-trim.gif) |

## ✅ 동작하는 것 (검증됨)

**NPU에서** 컴파일·실행되었고(`--device=amdxdna`), 결과가 정확하며, 재현 가능함:

| 워크로드 | Shape | 결과 | 처리량 (NPU) |
|---|---|---|---|
| `i32` matmul | 128×128×128 | ✓ 정확 | ~3.6 ms/iter, ~280/s |
| `bf16 → f32` matmul | 256×256×256 | ✓ 정확 (소수부 포함) | ~2.9 ms/iter, ~350/s |

테스트 머신: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · kernel 7.0 · 인트리 `amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**.

## 📊 벤치마크

`iree-benchmark-module`로 NPU에서 측정한 엔드투엔드 결과(`--device=amdxdna`,
`npu1_4col`, 10회 반복, 평균). 벽시계 시간(wall-clock)에는 호스트 디스패치 오버헤드가
포함되어 있어, 가장 작은 matmul은 디스패치에 묶인다(dispatch-bound). 실효 연산량은
크기가 커질수록 올라간다.

| dtype | Shape (M×N×K) | 시간/iter | 처리량 | 연산량 |
|---|---|--:|--:|--:|
| `i32` | 128×128×128 | 3.58 ms | 279 it/s | 1.2 GFLOP/s |
| `i32` | 256×256×256 | 8.08 ms | 124 it/s | 4.2 GFLOP/s |
| `i32` | 512×512×512 | 43.6 ms | 23 it/s | 6.2 GFLOP/s |
| `bf16→f32` | 256×256×256 | 2.86 ms | 350 it/s | 11.7 GFLOP/s |
| `bf16→f32` | 512×512×512 | 3.90 ms | 257 it/s | 68.8 GFLOP/s |
| `bf16→f32` | 1024×1024×1024 | 9.76 ms | 102 it/s | 220 GFLOP/s |

**bf16은 NPU의 본래 강점이다** — 1024³에서 ~220 GFLOP/s이며 여전히 스케일링 중인 반면,
(AIE의 네이티브 타입이 아닌) `i32`는 6 GFLOP/s 근처에서 한계에 부딪힌다. 어떤 행이든 재현하려면:
`BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`.


## 🚀 Quickstart

```bash
git clone https://github.com/<you>/ryzen-npu-linux.git && cd ryzen-npu-linux

# 0. Is the NPU even alive? (read-only diagnostic)
./scripts/check-npu.sh

# 1. (if check failed on groups/memlock/xrt) activate it for your user, then re-login
./scripts/enable-npu.sh

# 2. Build iree-amd-aie from source (~65 min, 30-60 GB disk). All workarounds baked in.
./scripts/build.sh

# 3. Run a matmul ON THE NPU
./scripts/run-matmul.sh i32          # 128x128x128, all 768
./scripts/run-matmul.sh bf16         # 256x256x256 bf16->f32, all 1536
BENCH=1 ./scripts/run-matmul.sh bf16 # + benchmark
```

## 🧰 도구

| 스크립트 | 하는 일 |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | 읽기 전용: 드라이버, 디바이스 노드, render 그룹, memlock, XRT, pyxrt를 점검한다. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | 비루트 사용자를 막는 3가지(render 그룹, memlock, XRT)를 바로잡는다. |
| [`scripts/build.sh`](scripts/build.sh) | `iree-amd-aie`를 클론하고, 모든 워크어라운드를 적용해 빌드한다. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | NPU에서 `i32`/`bf16` matmul을 컴파일·실행한다. 바로 그 레시피. |

## 🪤 Gotcha들 (순진하게 빌드/실행하면 왜 실패하는가)

자세한 내용은 **[docs/GOTCHAS.ko.md](docs/GOTCHAS.ko.md)**에 있다. 요약 목록:

1. **호스트 컴파일러로 `clang`이 아니라 `gcc`를 써라.** clang 21은 MLIR `BuiltinDialectBytecode.cpp`를 컴파일할 때 *세그폴트*가 난다.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Python 바인딩은 `-Werror,-Wmacro-redefined`에 걸린다. CLI 도구에는 필요 없다.
3. **Peano(`llvm-aie`) pin을 올려라.** 저장소에 고정된 nightly는 인덱스에서 만료되었다. `build.sh`가 최신 버전을 자동 선택한다.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** 무거운 서브모듈 3개를 의도적으로 건너뛴다.
5. **`--iree-amdaie-device-hal=amdxdna`로 컴파일하라**(+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`). 그러지 않으면 디스패치가 타임아웃 난다.
6. ⚠️ **`--amdxdna_n_core_cols=4`로 실행하라, 5가 아니다.** Phoenix는 raw 컬럼을 5개로 보고하지만 실제로는 4개를 쓴다(`npu1_4col`). 5를 넘기면 → 코어가 hang → `ert state 8` 타임아웃.

## 🎯 실제로 어디에 쓸 수 있나?

대상별 전체 가이드(게임 · AI 에이전트 · 로컬 앱)와 실현성 등급 → [docs/APPLICATIONS.ko.md](docs/APPLICATIONS.ko.md).

**[docs/USE-CASES.ko.md](docs/USE-CASES.ko.md)**를 보라. 솔직히 말하면, 이것은 턴키 모델 서빙이 아니라
**커널 레벨**(matmul/conv 빌딩 블록)이다. NPU 프로그래밍 학습, 벤치마킹, 특정 저전력 추론
프리미티브를 만들고/오프로딩하는 것, 그리고 열린 XDNA1-on-Linux 노력에 기여하는 데에는 좋다.
XDNA1에서 바로 꽂아 쓸 수 있는 LLM/Whisper/ONNX 런타임을 **주지는 못한다** — 그건 XDNA2 / Windows 영역이다.

## 📚 배경

XDNA1 vs XDNA2, 1세대에서 Linux가 왜 어려운지, 그리고 `amdxdna` HAL이 `/dev/accel0`와 어떻게
통신하는지는 **[docs/BACKGROUND.ko.md](docs/BACKGROUND.ko.md)**를 보라.

## 🧭 이 저장소의 위치 (그리고 *아닌* 것)

**이것은 Linux에서 NPU를 다룬 최초의 프로젝트가 아니며, 스택의 어느 부분도 새로 발명하지 않았다** —
드라이버, 컴파일러, 런타임 모두 이 저장소보다 먼저 존재했고 무거운 일을 다 해낸다:

| 계층 | 우리가 그 위에 올라타거나 곁에 두는 선행 작업 |
|---|---|
| 커널 드라이버 | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, Linux 6.14부터 메인라인에 포함, XDNA1을 `/dev/accel/accel0`로 enumerate 한다 |
| 컴파일러 / 런타임 | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — `npu1`용으로 컴파일하는 SDK/프레임워크 |
| 선행 XDNA1 + Linux 연산 | 연구 논문 한 편([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — IRON으로 Phoenix 7940HS에서 돌린 GPT-2), 프리미티브 전용 튜토리얼들, [Gentoo wiki XDNA 정리글](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| Linux용 턴키 NPU LLM | FastFlowLM · Lemonade 10.x · AMD Ryzen AI SW — **전부 XDNA2 전용이며, XDNA1을 명시적으로 제외한다** |

따라서 "Linux 최초의 NPU", "최초의 컴파일러", "XDNA1을 최초로 구동" 같은 표현은 전부
과장이 될 것이고 — 우리는 그렇게 주장하지 않는다.

**이 저장소가 *무엇인가 하면*:** 공개 검색(2026-06)으로 찾을 수 있는 한, **1세대 XDNA1
(Phoenix, 예: 7840U) NPU를 Linux에서** 돌려 *임의의 실제 연산*(i32/bf16 matmul, conv)을 수행하는,
**패키징되고 재현 가능한 엔드투엔드 레시피 + 도구 모음**으로는 최초 — 그리고 유일 — 이다.
바로 그 하드웨어/OS 조합이야말로 모든 턴키 벤더 스택이 버려둔(orphaned) 부분이다. 선행 작업은
업스트림 **SDK/프레임워크**(소스에서 빌드할 때의 함정은 직접 헤쳐나가야 함)이거나, **XDNA2 전용**
앱이거나, **연구 논문**(클릭해서 바로 돌릴 수 있는 저장소가 없음)이거나, **Windows 전용** 연산
경로다. 차별점은 바로 그 *묶음*에 있다: diagnose→enable→build→run 스크립트, 소스 빌드의
**gotcha 지도**, **상주(persistent) C-API/ctypes 러너**(호출마다 `iree-run-module`을 부르는 것보다
~11× 빠름), **앱 예제들**(웨이크워드, NPU 카메라 데몬), **솔직한 실현성 등급 애플리케이션 가이드**
(측정으로 드러난 "오디오에서는 NPU가 CPU에 진다"는 사실 포함), 그리고 5개 언어 문서.

> **솔직한 단서:** 이 포지셔닝은 README와 코드 조각의 공개 검색에 기반한다
> (외부 저장소를 클론하거나 검증하지는 않았다). 우리는 비공개 저장소, 기업 내부 작업,
> 일회성 스크립트의 롱테일을 **볼 수 없다** — "직접적인 동급 사례를 찾지 못했다"는 말은
> 딱 그 뜻이지, "존재하지 않는다"는 뜻이 아니다.

## ⚖️ 면책 조항

이것은 AMD/Xilinx 제품이 아니라 커뮤니티 노트다. `iree-amd-aie`는 초기 단계이며 빠르게
바뀐다. 버전/플래그가 변동된다. 여기 있는 모든 것은 위에 명시된 바로 그 머신에서
2026-06-22에 검증되었다. 다른 XDNA1 노트북에서의 결과를 담은 이슈/PR를 환영한다.

## 🤝 기여하기

가장 쓸모 있는 기여는 **여러분 자신의 XDNA1 머신에서 나온 결과**다 — Linux에서의
1세대 Ryzen AI 커버리지는 빈약하다. **[CONTRIBUTING.md](CONTRIBUTING.md)**를 보라. 요약하면:

- **하드웨어 결과를 보고하라** — 여러분의 칩 / 커널 / 배포판과 무엇이 동작했고 무엇이 실패했는지(이슈 템플릿 제공).
- 다른 shape/dtype에 대한 **벤치마크를 추가**하거나, **새 op**(conv, i8, …)를 추가하라.
- **[gotcha](docs/GOTCHAS.ko.md)를 고치거나 다듬고**, 스크립트를 견고하게 하거나, 번역을 추가/수정하라.
- Fork → branch → test with `scripts/run-matmul.sh` → PR describing what you ran it on.

## 📄 라이선스

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — 쓰고, 포크하고, 배포하라.

이 저장소의 스크립트와 문서는 MIT다. 이들은 각자의 라이선스를 따르는 서드파티
프로젝트 — IREE와 `iree-amd-aie`(Apache-2.0 WITH LLVM-exception), `Xilinx/llvm-aie`(Peano) —
를 빌드하고 구동하며, 이 저장소는 그것들을 재배포하지 않는다.
