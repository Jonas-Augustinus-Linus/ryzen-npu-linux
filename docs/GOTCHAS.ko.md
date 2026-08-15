**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# 함정 모음 — 무엇이 깨지고, 왜 그러며, 어떻게 고치는가

아래의 모든 항목은 실제 빌드(Ryzen 7840U / XDNA1,
Ubuntu 26.04, kernel 7.0, 2026-06-22)에서 직접 마주치고 해결한 것들이다. 여러분을 괴롭히는 지점 순서로 정렬했다.
(#0은 예외다: Strix / XDNA2 머신에서 2026-08-15에 마주쳤다 — 세대와 무관하며,
어떤 빌드보다도 앞선 *활성화* 시점에 여러분을 괴롭힌다.)

---

## 0. limits.d는 memlock `unlimited`라는데 — 터미널은 여전히 8 MB다

**증상.** `enable-npu.sh`를 실행했고, `/etc/security/limits.d/99-xrt-npu.conf`에는
`unlimited`라고 적혀 있고, 로그아웃 후 다시 로그인까지 했는데 — 여전히:

```
$ ulimit -l
8192
$ xrt-smi examine
[xrt-smi] ERROR: mmap(len=67108864, prot=3, flags=8209, ...) failed (err=-11):
          Resource temporarily unavailable
```

**원인.** 데스크톱 Linux에는 **서로 독립적인 rlimit 경로가 두 개** 있고, limits.d는
그중 하나만 담당한다:

- `pam_limits`는 **PAM 로그인**에 limits.d를 적용한다: ssh, TTY, 그리고 디스플레이
  매니저의 세션 리더.
- **GUI로 실행된 앱은 PAM을 전혀 거치지 않는다.** systemd 데스크톱에서 터미널은
  **systemd 유저 매니저**(`user@<uid>.service`)가 띄우며, limits.d와 무관하게
  *그 서비스의* `LimitMEMLOCK` — 기본값 8 MB — 을 상속받는다:

  ```
  $ systemctl show user@$(id -u).service -p LimitMEMLOCK
  LimitMEMLOCK=8388608
  $ pstree -sp $$
  systemd(1)───systemd(…)───ptyxis(…)───bash(…)      ← no PAM in this chain
  ```

- 설상가상으로: **lingering**이 켜져 있으면(`loginctl show-user $USER -p Linger` →
  `yes`; 컨테이너/VPN 도구가 흔히 켜 놓는다), 로그아웃해도 `user@<uid>.service`는
  종료되지 **않는다** — 그래서 서비스를 고친 뒤에도 재로그인만으로는 새 제한값으로
  재시작되는 일이 결코 없다. 오직 재부팅만이 그렇게 한다.

**해결책**(이제 `enable-npu.sh`가 하는 일): PAM 경로를 위해 limits.d 항목은 그대로
두고, *거기에 더해* 유저 매니저용 드롭인을 추가한 다음, 한 번 재부팅하라:

```
# /etc/systemd/system/user@.service.d/99-xrt-npu-memlock.conf
[Service]
LimitMEMLOCK=infinity
```

재부팅 없이 이미 실행 중인 셸을 풀어주려면(자식 프로세스는 rlimit을
상속받는다):

```bash
sudo prlimit --pid $$ --memlock=unlimited:unlimited
```

`check-npu.sh [5]`는 이제 정확히 이 분열 — limits.d는 허용하는데 프로세스는 갖고
있지 않은 상태 — 을 감지하여, 어느 경로가 실패했는지와 함께 lingering 상태를
출력한다.

*ssh/TTY 워크플로에서는 이 문제가 결코 발생하지 않으며(pam_limits가 담당하므로),
그래서 XDNA1 빌드 내내 눈에 띄지 않은 채 남아 있었다. GUI 터미널에서 처음
활성화를 실행했을 때 비로소 드러났다 — 그리고 두 세대를 똑같이 괴롭힌다.*

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

## M5. 릴리스 핀이 일치할 때만 Peano를 재사용하라

`aie` / `aie2` / `aie2p` 지원 여부만으로는 충분하지 않다. 각 mlir-aie 릴리스는
`utils/peano-requirements.txt`에 정확한 `llvm-aie` wheel을 핀한다. iree-amd-aie의
Peano는 wheel 버전 메타데이터와 `clang --version`이 보고하는 **빌드 커밋**이 모두
그 핀과 일치할 때만 재사용할 수 있다. `setup-mlir-aie.sh`는 둘 다 확인한다.
수동으로 설정할 때 가장 안전한 호환 버전 선택 방법은 다음과 같다:

```bash
python -m pip install --upgrade -r utils/peano-requirements.txt
SITE="$(python -c 'import site; print(site.getsitepackages()[0])')"
source utils/env_setup.sh "$SITE/mlir_aie"
```

`env_setup.sh`는 환경만 구성한다. 두 번째 인자를 생략하면 활성 venv에서 핀된 wheel을
찾는다. `$HOME/src/iree-amd-aie/llvm-aie`는 동일한 정확한 버전과 clang 커밋을
확인한 뒤에만 명시적으로 넘겨라. 이미 존재한다는 이유만으로 선택해서는 안 된다.

## M6. 네트워크 전체 설계는 Phoenix의 4 컬럼보다 많은 것을 원한다

```
RuntimeError: DRM_IOCTL_AMDXDNA_CREATE_HWCTX IOCTL failed (err=-22): Invalid argument
```

`ml/mobilenet`은 **빌드**되지만 `hw_context` 생성에서 실패한다: 어레이 전체
설계가 Phoenix가 노출하는 것보다 많은 컬럼을 요청한다(**4** — 위 gotcha #6과
같은 4다). 단일 빌딩 블록(`conv2d`, `bottleneck`, `resnet/layers_conv2_x`)과
`magika`는 4 컬럼에 들어맞고 실행되지만, 전체 네트워크는 XDNA2(Strix, 8 컬럼)
영역이다. *(2026-08-15 확인: Strix Point의 8 컬럼에서는 네트워크 전체가
엔드투엔드로 돌아간다, ~176 ms/추론 — [XDNA2.md](XDNA2.md).)*

## M7. IRON 1.4.x는 어노테이션 없는 `@iron.jit` 호출 형태를 깨뜨렸다

1.3.x 기준으로 작성된 이런 코드는

```python
iron.jit(transform_binary)(kernel, a, b, out, tile_size=tile_size)
```

1.4.x에서 다음과 함께 죽는다

```
TypeError: @iron.jit: parameter(s) ['tile_size', 'trace_size'] of 'transform_binary'
have default values but no In / Out / InOut / CompileTime[T] annotation.
```

1.4.x는 어노테이션 붙은 설계 함수를 요구한다 — 텐서는 `In`/`Out`으로,
컴파일 타임 스칼라는 keyword 전용 `CompileTime[T]` 파라미터로 — 그리고
`iron.algorithms.*` 헬퍼들은 이제 살아 있는 텐서 대신 jit 본문 안에서
**numpy 타입 기술자(type descriptor)**를 받는다:

```python
@iron.jit
def design(a: In, b: In, out: Out, *,
           num_elements: CompileTime[int], tile_size: CompileTime[int]):
    tensor_ty = np.ndarray[(num_elements,), np.dtype[np.int32]]
    return iron.algorithms.transform_binary(kernel, tensor_ty, tile_size=tile_size)
```

`ExternalFunction`은 여전히 뒤에 붙는 `int` 타일 크기 인자를 자동으로 받는다
(parallel 변형에서는 `pass_size_to_kernel=True`). 전체 before/after는
`examples/mlir-aie/relu_add/`를 볼 것.

## M8. 코어 로컬 메모리는 64 KB다 — 타일 크기는 수학이 아니라 FIFO에 맞춰라

바이너리(2입력) 요소별(element-wise) 설계는 한 코어의 데이터 메모리에
**타일 버퍼 6개**가 동시에 살아 있어야 한다(ObjectFifo 3개 × 더블 버퍼링).
`tile_size=4096` int32에서는 6 × 16 KB = 96 KB이고 aiecc는 배치(placement)에
실패한다:

```
error: 'aie.tile' op Basic sequential allocation also failed.
note: MemoryMap: (stack) 0x0-0x3FF … in0_cons_buff_1 0x14400-0x183FF …
```

`tile_size=1024`(6 × 4 KB + 스택)는 여유 있게 들어맞는다. 같은 예산이, 어레이
전체 GEMM이 i8에서는 64³ 내부 타일을 받아들이면서 bf16에서는 받아들이지
못하는 이유도 설명한다(2바이트 요소는 버퍼 크기를 두 배로 만든다).

## M9. 바이너리 커널은 컬럼당 shim DMA 채널 2개를 구동할 수 없다

`transform_parallel*(…, num_channels=2)`는 **단항(unary)** 커널에서 (컬럼,
채널) 쌍마다 Worker 하나를 돌려 DDR 처리량을 두 배로 만든다. **바이너리**
커널은 이미 컬럼당 MM2S shim 채널 두 개가 필요하다 — 입력마다 하나 —
그런데 shim에는 정확히 두 개뿐이라, `num_channels=2`는 배치(placement)에
실패한다:

```
error: no ShimNOCTile has sufficient DMA capacity for 0 input/1 output channels
```

2입력 커널은 `num_channels=1`을 유지하라.

## M10. AIE2P(XDNA2)에서 bf16은 ¼ 속도다 — bf16 GEMM은 bfp16으로 돌려라

bf16 MAC은 XDNA1의 AIE2에서는 네이티브지만 XDNA2의 AIE2P에서는 **bfp16
데이터패스를 통해 약 ¼ 속도로 에뮬레이션**된다; 네이티브 모드는 bfp16 블록
부동소수점(8×8×8)이다. 기본 제공 matmul들은 이 워크어라운드를 플래그로
노출한다:

```bash
python whole_array.py … --dtype_in bf16 --dtype_out f32 --emulate-bf16-mmul-with-bfp16 1
```

여기서 측정한 값: 512³/32³-타일에서 +17%, 64×32×64 타일의 2048³에서 +25%
(4.64 대 3.7 언저리 TFLOPS). 자세한 내용: [MLIR-AIE.md](MLIR-AIE.md) → GEMM
교훈.

## M11. 네이티브 bfp16은 K 타일 수가 늘면 정합성에 실패할 수 있다

`ml/block_datatypes` 네이티브 bfp GEMM은 빠르게 보여도 결과가 틀릴 수 있다.
CPU float 참조값과 비교하면 512³과 1024³은 통과하지만, 2048³은 실패한다
(표본 1000개 중 291개, 최대 상대 오차 12%). M=N=1024에서는 K=1216이
**PASS**, K=1280이 **FAIL**인 경계가 관측되었다.

소스 검사로는 K 타일 사이에서 부분 출력이 bfp16으로 반복 재양자화되는 것으로
보인다. 이는 K 의존성을 설명하지만 아직 검증된 수정안은 아니다. 네이티브 bfp
처리량은 반드시 CPU 참조 **PASS**와 함께 보고해야 한다.
[`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh)는 이 알려진
경계를 재현하고 단언한다.
