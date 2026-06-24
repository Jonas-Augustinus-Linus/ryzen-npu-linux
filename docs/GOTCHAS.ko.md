**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# 함정 모음 — 무엇이 깨지고, 왜 그러며, 어떻게 고치는가

아래의 모든 항목은 실제 빌드(Ryzen 7840U / XDNA1,
Ubuntu 26.04, kernel 7.0, 2026-06-22)에서 직접 마주치고 해결한 것들이다. 여러분을 괴롭히는 지점 순서로 정렬했다.

---

## 1. clang이 MLIR 빌드 중 세그폴트 → gcc를 사용할 것

**증상**
```
FAILED: .../obj.MLIRIR.dir/BuiltinDialectBytecode.cpp.o
clang++: error: clang frontend command failed with exit code 139
... file INSTALL cannot find ".../libIREECompiler.so": No such file
```
`exit 139` = SIGSEGV: 호스트 **clang(21.x 버전에서 테스트)이** 크게 생성된 MLIR 파일 하나를 컴파일하다 **크래시**한다. 그 파일이 핵심 `MLIRIR`에 속해 있기 때문에 컴파일러 라이브러리가
링크되지 않고 설치 전체가 무너진다 — 그런데 *첫 번째* 에러는 화면 위로 스크롤되어 지나가
버려서, 여러분은 설치 실패만 알아차리게 된다.

**해결책.** **gcc**로 빌드하라:
```bash
export CC=gcc CXX=g++
rm -rf iree-build      # required: cmake won't switch compilers in an existing dir
cmake ...              # reconfigure
```
gcc 15는 동일한 트리를 깔끔하게 빌드한다(16코어에서 약 65분).

---

## 2. Python 바인딩: `_POSIX_C_SOURCE` 매크로 재정의 → 끄기

**증상**
```
.../python3.12/include/python3.12/pyconfig.h:1877:9:
  error: '_POSIX_C_SOURCE' macro redefined [-Werror,-Wmacro-redefined]
FAILED: runtime/bindings/python/.../PyExtRt.dir/...cc.o
```
IREE Python(nanobind) 바인딩은 feature-test-macro 재정의를 유발하는데, 이는
`-Werror` 아래에서 치명적이다. matmul을 컴파일하고 실행하는 데에는 Python 바인딩이 **필요하지 않다** — `iree-compile` / `iree-run-module` / `iree-e2e-matmul-test`
바이너리만으로 충분하다.

**해결책.** `-DIREE_BUILD_PYTHON_BINDINGS=OFF` (그리고 `iree-install-dist` 타겟은 건너뛴다).

---

## 3. 고정된 Peano(llvm-aie) 버전이 만료되었다

**증상**
```
ERROR: Could not find a version that satisfies the requirement
  llvm_aie==19.0.0.2025052701+31d2aa6e (from versions: 21.0.0.2026061101+..., ...)
```
`build_tools/peano_commit_linux.txt`는 특정 `llvm-aie` 나이틀리를 고정하지만,
Xilinx 나이틀리 인덱스는 최근 빌드만 유지한다 — 고정된 버전(상류에서 약 13개월간 손대지 않음)은 이미 오래전에 사라졌다.

**해결책.** 고정값을 사용 가능한 최신 나이틀리로 가리키게 한다:
```bash
echo "<latest-nightly-version>" > build_tools/peano_commit_linux.txt
bash build_tools/download_peano.sh
```
`scripts/build.sh`는 인덱스를 질의하여 이를 자동으로 처리한다. 새 Peano는
버전 점프에도 불구하고 잘 작동한다(AIE LLVM 백엔드이며, 인터페이스는 안정적이다).

---

## 4. 의도적으로 건너뛴 서브모듈에서 빌드가 중단됨

**증상**
```
The git submodule 'third_party/stablehlo' is not initialized.
CMake Error: check_submodule_init.py failed
```
`torch-mlir`, `stablehlo`, `XRT`(amdxdna 경로에는 어느 것도 필요 없음) 없이
클론하지만, IREE의 서브모듈 검사는 여전히 에러를 낸다.

**해결책.** `-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`. (그리고 AMD의 트리 외부
`xdna-driver`를 빌드할 **필요가 없다**: 트리 내장 `amdxdna.ko`가 디바이스를 노출하고,
`amdxdna` HAL이 `/dev/accel0`을 직접 여는 자체 shim을 벤더링한다.)

---

## 5. 잘못된 HAL용으로 컴파일된 모듈 → 디스패치가 영원히 완료되지 않음

**증상.** 컴파일은 잘 되지만, 실행 시점에:
```
amdxdna dispatch did not complete: ert state 8; while invoking ... hal.fence.await
```
`--iree-amdaie-device-hal=amdxdna`를 생략하면, 모듈은 다른
(예: `xrt`) HAL용으로 빌드되어 `--device=amdxdna` 아래에서 올바르게 실행되지 않는다.

**해결책.** 전체 플래그 세트로 컴파일하라:
```
--iree-amdaie-device-hal=amdxdna
--iree-hal-memoization=false
--iree-hal-indirect-command-buffers=false
--iree-amdaie-target-device=npu1_4col
--iree-amdaie-lower-to-aie-pipeline=objectFifo   # i32
# (use 'air' for bf16)
--iree-amdaie-tile-pipeline=pack-peel
--iree-amd-aie-peano-install-dir=<.../llvm-aie>
--iree-amd-aie-install-dir=<.../iree-install>
```

---

## 6. ⚠️ 결정적인 함정: 실행 시점의 컬럼 수

**증상.** 올바른 컴파일 플래그를 써도 #5와 동일한 `ert state 8` **TIMEOUT**.
명령이 NPU에 도달하고(디스패치를 볼 수 있다), 코어가 로드된 다음, 코어들이
**영원히 멈춰** 약 60초 후에 타임아웃된다. `dmesg`에는 하드웨어 에러가 **없다** —
코어들은 그저 결코 일치하지 않는 파티션을 기다리고 있을 뿐이다.

**근본 원인.** Phoenix의 raw AIE 메타데이터는 **5개 컬럼**을 보고하지만, 사용 가능한
수 — 그리고 컴파일 타겟인 `npu1_4col` — 는 **4**다. 드라이버 헬퍼도 이에 동의한다:
```
$ python build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py --num-cols
4
```
`--amdxdna_n_core_cols=5`를 넘기면 런타임이 5컬럼 파티션을 구성하지만
모듈은 4를 기대한다 → 불일치 → 멈춤.

**해결책.** 디바이스 헬퍼가 보고하는 값(rows=4, **cols=4**)으로 실행하라:
```
--amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4
```
`scripts/run-matmul.sh`는 이 값들을 `--num-rows`/`--num-cols`에서 자동으로 읽어온다.

---

## 차단되지 않는 참고 사항

- **`xrt-smi validate` 실패** — `Archive not found: amdxdna/bins/xrt_smi_phx.a`.
  이는 Ubuntu가 Phoenix 셀프 테스트 바이너리를 제거한 것이지, NPU가 고장 난 것이 **아니다**.
- **예상되었던 UAPI/ABI 불일치는 발생하지 않았다.** kernel-7.0 트리 내장 `amdxdna`와
  `iree-amd-aie`가 벤더링한 `amdxdna_accel.h`는 호환되었다: 토폴로지
  ioctl과 디바이스 열거가 모두 첫 시도에 작동했다.
- **Python 3.13/3.14는 너무 최신**이라 IREE의 빌드 의존성에 맞지 않는다 — 격리된 3.12를 사용하라
  (스크립트는 `uv`를 사용한다).

---

# mlir-aie (IRON) 트랙 — 별개의 gotcha들

두 번째 경로 — `mlir_aie` wheel을 통한
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)(여기 [MLIR-AIE.md](MLIR-AIE.md)
참조) — 에는 위의 iree-amd-aie 빌드와는 다른 그 자체의 함정이 있다.
`scripts/setup-mlir-aie.sh`와 `scripts/mlir-aie-env.sh`가 이들을 모두 처리해준다;
이것이 그 스크립트들이 우회하고 있는 내용이다.

## M1. 여기서는 Python **3.14**를 쓴다 — iree 빌드와 정반대

iree-amd-aie 빌드는 **3.12**를 원한다(위 참고 사항). `mlir_aie` wheel은
3.11–3.14를 지원하며, Ubuntu 패키지 `pyxrt`(`python3-xrt`에서 나오며
`pyxrt.cpython-314-*.so`로 빌드됨)를 쓰는 유일한 방법은 **3.14** venv다 — 3.12
venv는 그 `pyxrt`를 import 할 수 없다. 따라서 두 트랙은 의도적으로 서로 다른
Python venv를 쓴다.

## M2. `pyxrt`를 venv에 노출하기

`make run_py`는 `import pyxrt`를 한다. Debian 패키지는 그것을
`/usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so`에 둔다. **그 파일 하나만**
venv의 `site-packages`에 심볼릭 링크하라 — 깨끗한 venv여야 하며
**`--system-site-packages`는 아니다**(그렇게 하면 나머지 시스템 site가 딸려
들어와 wheel 의존성을 가릴 위험이 있다):

```bash
ln -sf /usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so "$VENV/lib/python3.14/site-packages/"
```

## M3. ⚠️ `env_setup.sh`를 파이프 없이 source 할 것

```
error: unknown target triple 'aie2-none-unknown-elf'
make: *** [Makefile:37: build/passThrough.cc.o] Error 1
```

Makefile이 AIE 커널을 Peano의 `clang++`가 아니라 **시스템** `/bin/clang++`(`aie2`
타깃이 없다)로 컴파일했다. 원인: `PEANO_INSTALL_DIR`이 비어 있었다. *그것의*
원인:

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" | tail   # WRONG
```

파이프는 왼쪽을 **서브셸**에서 실행하므로, `env_setup.sh`의 모든
`export`(`PEANO_INSTALL_DIR`, `MLIR_AIE_INSTALL_DIR`, `NPU2`)는 서브셸이 끝나는
순간 버려진다. **파이프 말고 리다이렉트하라:**

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" >/tmp/env.log 2>&1   # RIGHT
```

(또한: `env_setup.sh`는 `set -e`/`set -u`에 안전하게 작성되어 있지 않다 —
`set -euo pipefail` 아래에서 source 하면 조용히 중단된다. `scripts/mlir-aie-env.sh`는
source 전후로 그 플래그들을 완화했다가 복원한다.)

## M4. `make run_py`(pyxrt) vs `make run`(C++ 호스트 + libxrt-dev)

많은 예제가 C++ 호스트(`test.cpp` → `make run`)와 Python 호스트(`test.py` →
`make run_py`)를 **둘 다** 제공한다. C++ 호스트는 XRT **개발 헤더**(`libxrt-dev`)가
필요한데, 런타임 패키지(`libxrt-utils-npu`, `python3-xrt`)는 그것을 설치하지
**않는다**. `run_py`를 선호하라. C++ 전용 예제(matrix_multiplication, vision,
relu, softmax)는: `sudo apt install libxrt-dev`.

## M5. 이미 빌드한 Peano를 재사용하라

`llvm-aie`를 다시 받지 말라. iree-amd-aie Peano를 `env_setup.sh`의 두 번째 인자로
넘겨 자동 설치를 건너뛰게 하라:

```bash
source utils/env_setup.sh "$SITE/mlir_aie" "$HOME/src/iree-amd-aie/llvm-aie"
```

이는 `aie` / `aie2` / `aie2p`를 지원하므로, 같은 Peano가 두 트랙 모두에 쓰인다.

## M6. 네트워크 전체 설계는 Phoenix의 4 컬럼보다 많은 것을 원한다

```
RuntimeError: DRM_IOCTL_AMDXDNA_CREATE_HWCTX IOCTL failed (err=-22): Invalid argument
```

`ml/mobilenet`은 **빌드**되지만 `hw_context` 생성에서 실패한다: 어레이 전체
설계가 Phoenix가 노출하는 것보다 많은 컬럼을 요청한다(**4** — 위 gotcha #6과
같은 4다). 단일 빌딩 블록(`conv2d`, `bottleneck`, `resnet/layers_conv2_x`)과
`magika`는 4 컬럼에 들어맞고 실행되지만, 전체 네트워크는 XDNA2(Strix, 8 컬럼)
영역이다.
