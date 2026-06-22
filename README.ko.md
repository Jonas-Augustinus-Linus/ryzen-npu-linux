**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# **Linux**에서 Ryzen AI **XDNA1** NPU로 실제 연산 돌리기

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

## ✅ 동작하는 것 (검증됨)

**NPU에서** 컴파일·실행되었고(`--device=amdxdna`), 결과가 정확하며, 재현 가능함:

| 워크로드 | Shape | 결과 | 처리량 (NPU) |
|---|---|---|---|
| `i32` matmul | 128×128×128 | ✓ 정확 | ~3.6 ms/iter, ~280/s |
| `bf16 → f32` matmul | 256×256×256 | ✓ 정확 (소수부 포함) | ~2.9 ms/iter, ~350/s |

테스트 머신: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · kernel 7.0 · 인트리 `amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**.

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

**[docs/USE-CASES.ko.md](docs/USE-CASES.ko.md)**를 보라. 솔직히 말하면, 이것은 턴키 모델 서빙이 아니라
**커널 레벨**(matmul/conv 빌딩 블록)이다. NPU 프로그래밍 학습, 벤치마킹, 특정 저전력 추론
프리미티브를 만들고/오프로딩하는 것, 그리고 열린 XDNA1-on-Linux 노력에 기여하는 데에는 좋다.
XDNA1에서 바로 꽂아 쓸 수 있는 LLM/Whisper/ONNX 런타임을 **주지는 못한다** — 그건 XDNA2 / Windows 영역이다.

## 📚 배경

XDNA1 vs XDNA2, 1세대에서 Linux가 왜 어려운지, 그리고 `amdxdna` HAL이 `/dev/accel0`와 어떻게
통신하는지는 **[docs/BACKGROUND.ko.md](docs/BACKGROUND.ko.md)**를 보라.

## ⚖️ 면책 조항

이것은 AMD/Xilinx 제품이 아니라 커뮤니티 노트다. `iree-amd-aie`는 초기 단계이며 빠르게
바뀐다. 버전/플래그가 변동된다. 여기 있는 모든 것은 위에 명시된 바로 그 머신에서
2026-06-22에 검증되었다. 다른 XDNA1 노트북에서의 결과를 담은 이슈/PR를 환영한다.

## License

[MIT](LICENSE).
