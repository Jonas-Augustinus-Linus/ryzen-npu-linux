**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# Gotchas — what breaks, why, and the fix

Every item below was hit and resolved on a real build (Ryzen 7840U / XDNA1,
Ubuntu 26.04, kernel 7.0, 2026-06-22). They are ordered by where they bite you.
(#0 is the exception: hit on the Strix / XDNA2 machine on 2026-08-15 — it is
generation-independent and bites at *activation* time, before any build.)

---

## 0. limits.d says memlock `unlimited` — your terminal still has 8 MB

**Symptom.** `enable-npu.sh` ran, `/etc/security/limits.d/99-xrt-npu.conf` says
`unlimited`, you logged out and back in — and still:

```
$ ulimit -l
8192
$ xrt-smi examine
[xrt-smi] ERROR: mmap(len=67108864, prot=3, flags=8209, ...) failed (err=-11):
          Resource temporarily unavailable
```

**Why.** Desktop Linux has **two independent rlimit paths**, and limits.d only
covers one of them:

- `pam_limits` applies limits.d on **PAM logins**: ssh, TTY, and the display
  manager's session leader.
- **GUI-launched apps never pass through PAM.** On a systemd desktop your
  terminal is spawned by the **systemd user manager** (`user@<uid>.service`)
  and inherits *that service's* `LimitMEMLOCK` — default 8 MB, regardless of
  limits.d:

  ```
  $ systemctl show user@$(id -u).service -p LimitMEMLOCK
  LimitMEMLOCK=8388608
  $ pstree -sp $$
  systemd(1)───systemd(…)───ptyxis(…)───bash(…)      ← no PAM in this chain
  ```

- Worse: with **lingering** enabled (`loginctl show-user $USER -p Linger` →
  `yes`; container/VPN tooling often turns it on), logout does **not** stop
  `user@<uid>.service` — so even after you fix the service, a re-login never
  restarts it with the new limit. Only a reboot does.

**Fix** (what `enable-npu.sh` now does): keep the limits.d entry for the PAM
path *and* add a drop-in for the user manager, then reboot once:

```
# /etc/systemd/system/user@.service.d/99-xrt-npu-memlock.conf
[Service]
LimitMEMLOCK=infinity
```

To unblock an already-running shell without rebooting (children inherit
rlimits):

```bash
sudo prlimit --pid $$ --memlock=unlimited:unlimited
```

`check-npu.sh [5]` now detects exactly this split — limits.d grants it, the
process doesn't have it — and prints which path failed, plus the lingering
status.

*An ssh/TTY workflow never triggers this (pam_limits covers it), which is how
it stayed invisible through the whole XDNA1 build. It surfaced the first time
activation ran from a GUI terminal — and it bites both generations equally.*

---

## 1. clang segfaults building MLIR → use gcc

**Symptom**
```
FAILED: .../obj.MLIRIR.dir/BuiltinDialectBytecode.cpp.o
clang++: error: clang frontend command failed with exit code 139
... file INSTALL cannot find ".../libIREECompiler.so": No such file
```
`exit 139` = SIGSEGV: the host **clang (tested 21.x) crashes** compiling one large
generated MLIR file. Because that file is in core `MLIRIR`, the compiler library
never links and the whole install collapses — but the *first* error scrolls past
and you only notice the install failure.

**Fix.** Build with **gcc**:
```bash
export CC=gcc CXX=g++
rm -rf iree-build      # required: cmake won't switch compilers in an existing dir
cmake ...              # reconfigure
```
gcc 15 builds the same tree cleanly (~65 min on 16 cores).

---

## 2. Python bindings: `_POSIX_C_SOURCE` macro redefined → turn them off

**Symptom**
```
.../python3.12/include/python3.12/pyconfig.h:1877:9:
  error: '_POSIX_C_SOURCE' macro redefined [-Werror,-Wmacro-redefined]
FAILED: runtime/bindings/python/.../PyExtRt.dir/...cc.o
```
The IREE Python (nanobind) bindings trip a feature-test-macro redefinition that
is fatal under `-Werror`. You do **not** need the Python bindings to compile and
run matmuls — the `iree-compile` / `iree-run-module` / `iree-e2e-matmul-test`
binaries are enough.

**Fix.** `-DIREE_BUILD_PYTHON_BINDINGS=OFF` (and skip the `iree-install-dist` target).

---

## 3. The pinned Peano (llvm-aie) version has expired

**Symptom**
```
ERROR: Could not find a version that satisfies the requirement
  llvm_aie==19.0.0.2025052701+31d2aa6e (from versions: 21.0.0.2026061101+..., ...)
```
`build_tools/peano_commit_linux.txt` pins a specific `llvm-aie` nightly, but the
Xilinx nightly index only keeps recent builds — the pin (untouched upstream for
~13 months) is long gone.

**Fix.** Point the pin at the newest available nightly:
```bash
echo "<latest-nightly-version>" > build_tools/peano_commit_linux.txt
bash build_tools/download_peano.sh
```
`scripts/build.sh` does this automatically by querying the index. The newer Peano
works fine despite the version jump (it's the AIE LLVM backend; the interface is stable).

---

## 4. Build aborts on intentionally-skipped submodules

**Symptom**
```
The git submodule 'third_party/stablehlo' is not initialized.
CMake Error: check_submodule_init.py failed
```
You clone without `torch-mlir`, `stablehlo`, `XRT` (none are needed for the
amdxdna path), but IREE's submodule check still errors.

**Fix.** `-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`. (And you do **not** need to build
AMD's out-of-tree `xdna-driver`: the in-tree `amdxdna.ko` exposes the device, and
the `amdxdna` HAL vendors its own shim that opens `/dev/accel0` directly.)

---

## 5. Module compiled for the wrong HAL → dispatch never completes

**Symptom.** Compiles fine, but at run time:
```
amdxdna dispatch did not complete: ert state 8; while invoking ... hal.fence.await
```
If you omit `--iree-amdaie-device-hal=amdxdna`, the module is built for a different
(e.g. `xrt`) HAL and won't execute correctly under `--device=amdxdna`.

**Fix.** Compile with the full flag set:
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

## 6. ⚠️ The big one: column count at run time

**Symptom.** Same `ert state 8` **TIMEOUT** as #5 even with correct compile flags.
The command reaches the NPU (you can see the dispatch), the cores load, then they
**hang forever** and time out after ~60 s. `dmesg` shows **no** hardware error —
the cores are simply waiting on a partition that never matches.

**Root cause.** Phoenix's raw AIE metadata reports **5 columns**, but the usable
count — and the compile target `npu1_4col` — is **4**. The driver helper agrees:
```
$ python build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py --num-cols
4
```
Pass `--amdxdna_n_core_cols=5` and the runtime sets up a 5-column partition while
the module expects 4 → mismatch → hang.

**Fix.** Run with the values the device helper reports (rows=4, **cols=4**):
```
--amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4
```
`scripts/run-matmul.sh` reads these from `--num-rows`/`--num-cols` automatically.

---

## Non-blocking notes

- **`xrt-smi validate` fails** with `Archive not found: amdxdna/bins/xrt_smi_phx.a`.
  That's Ubuntu stripping the Phoenix self-test binary, **not** a broken NPU.
- **The predicted UAPI/ABI mismatch did not happen.** kernel-7.0 in-tree `amdxdna`
  and `iree-amd-aie`'s vendored `amdxdna_accel.h` were compatible: the topology
  ioctl and device enumeration both worked first try.
- **Python 3.13/3.14 are too new** for IREE's build deps — use an isolated 3.12
  (the scripts use `uv`).

---

# mlir-aie (IRON) track — separate gotchas

The second path — [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) via the
`mlir_aie` wheel (see [MLIR-AIE.md](MLIR-AIE.md)) — has its own traps, different
from the iree-amd-aie build above. `scripts/setup-mlir-aie.sh` and
`scripts/mlir-aie-env.sh` handle all of these; this is what they're working around.

## M1. Use Python **3.14** here — the opposite of the iree build

The iree-amd-aie build wants **3.12** (note above). The `mlir_aie` wheels support
3.11–3.14, and the only way to use Ubuntu's packaged `pyxrt` (from `python3-xrt`,
built `pyxrt.cpython-314-*.so`) is a **3.14** venv — a 3.12 venv simply can't
import that `pyxrt`. So the two tracks deliberately use different Python venvs.

## M2. Expose `pyxrt` into the venv

`make run_py` does `import pyxrt`. The Debian package drops it at
`/usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so`. Symlink **that one file**
into the venv's `site-packages` — a clean venv, **not** `--system-site-packages`
(which would drag in the rest of the system site and risk shadowing the wheel deps):

```bash
ln -sf /usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so "$VENV/lib/python3.14/site-packages/"
```

## M3. ⚠️ Source `env_setup.sh` WITHOUT a pipe

```
error: unknown target triple 'aie2-none-unknown-elf'
make: *** [Makefile:37: build/passThrough.cc.o] Error 1
```

The Makefile compiled the AIE kernel with the **system** `/bin/clang++` (which has
no `aie2` target) instead of Peano's `clang++`. Cause: `PEANO_INSTALL_DIR` was
empty. Cause of *that*:

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" | tail   # WRONG
```

A pipe runs the left side in a **subshell**, so every `export` in `env_setup.sh`
(`PEANO_INSTALL_DIR`, `MLIR_AIE_INSTALL_DIR`, `NPU2`) is discarded the moment the
subshell exits. **Redirect, don't pipe:**

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" >/tmp/env.log 2>&1   # RIGHT
```

(Also: `env_setup.sh` is not written to be `set -e`/`set -u` safe — sourcing it
under `set -euo pipefail` aborts silently. `scripts/mlir-aie-env.sh` relaxes and
restores those flags around the source.)

## M4. `make run_py` (pyxrt) vs `make run` (C++ host + libxrt-dev)

Many examples ship **both** a C++ host (`test.cpp` → `make run`) and a Python host
(`test.py` → `make run_py`). The C++ host needs XRT **dev headers**
(`libxrt-dev`), which the runtime packages (`libxrt-utils-npu`, `python3-xrt`) do
**not** install. Prefer `run_py`. For C++-only examples (matrix_multiplication,
vision, relu, softmax): `sudo apt install libxrt-dev`.

## M5. Reuse Peano only when its release pin matches

Support for `aie` / `aie2` / `aie2p` alone is not enough. Each mlir-aie release
pins an exact `llvm-aie` wheel in `utils/peano-requirements.txt`; Peano from
iree-amd-aie is reusable only when both its wheel-version metadata **and** the
build commit reported by `clang --version` match that pin. `setup-mlir-aie.sh`
checks both. For a manual setup, the safest compatible selection is:

```bash
python -m pip install --upgrade -r utils/peano-requirements.txt
SITE="$(python -c 'import site; print(site.getsitepackages()[0])')"
source utils/env_setup.sh "$SITE/mlir_aie"
```

`env_setup.sh` only configures the environment; with no second argument it finds
the pinned wheel in the active venv. Pass
`$HOME/src/iree-amd-aie/llvm-aie` explicitly only after verifying that same exact
version and clang commit—do not select it merely because it is already present.

## M6. Full-network designs want more than Phoenix's 4 columns

```
RuntimeError: DRM_IOCTL_AMDXDNA_CREATE_HWCTX IOCTL failed (err=-22): Invalid argument
```

`ml/mobilenet` **builds** but fails at `hw_context` creation: the whole-array
design requests more columns than Phoenix exposes (**4** — the same 4 from gotcha
#6 above). Single building blocks (`conv2d`, `bottleneck`, `resnet/layers_conv2_x`)
and `magika` fit in 4 columns and run; the full network is XDNA2 (Strix, 8-column)
territory. *(Confirmed 2026-08-15: on Strix Point's 8 columns the full network
runs end-to-end, ~176 ms/inference — [XDNA2.md](XDNA2.md).)*

## M7. IRON 1.4.x broke the un-annotated `@iron.jit` call form

Code written against 1.3.x like

```python
iron.jit(transform_binary)(kernel, a, b, out, tile_size=tile_size)
```

dies on 1.4.x with

```
TypeError: @iron.jit: parameter(s) ['tile_size', 'trace_size'] of 'transform_binary'
have default values but no In / Out / InOut / CompileTime[T] annotation.
```

1.4.x requires an annotated design function — tensors as `In`/`Out`,
compile-time scalars as `CompileTime[T]` keyword-only params — and the
`iron.algorithms.*` helpers now take a **numpy type descriptor** inside the jit
body instead of live tensors:

```python
@iron.jit
def design(a: In, b: In, out: Out, *,
           num_elements: CompileTime[int], tile_size: CompileTime[int]):
    tensor_ty = np.ndarray[(num_elements,), np.dtype[np.int32]]
    return iron.algorithms.transform_binary(kernel, tensor_ty, tile_size=tile_size)
```

`ExternalFunction` still auto-receives a trailing `int` tile-size argument
(`pass_size_to_kernel=True` in the parallel variants). See
`examples/mlir-aie/relu_add/` for a full before/after.

## M8. Core-local memory is 64 KB — size your tiles for the FIFOs, not the math

A binary element-wise design needs **6 tile buffers** live in one core's data
memory (3 ObjectFifos × double buffering). At `tile_size=4096` int32 that is
6 × 16 KB = 96 KB and aiecc fails placement:

```
error: 'aie.tile' op Basic sequential allocation also failed.
note: MemoryMap: (stack) 0x0-0x3FF … in0_cons_buff_1 0x14400-0x183FF …
```

`tile_size=1024` (6 × 4 KB + stack) fits with room. The same budget explains
why whole-array GEMM accepts 64³ inner tiles for i8 but not for bf16 (2-byte
elements double the buffer sizes).

## M9. Binary kernels can't drive 2 shim DMA channels per column

`transform_parallel*(…, num_channels=2)` doubles DDR throughput for **unary**
kernels by running one Worker per (column, channel). A **binary** kernel already
needs two MM2S shim channels per column — one per input — and the shim has
exactly two, so `num_channels=2` fails placement:

```
error: no ShimNOCTile has sufficient DMA capacity for 0 input/1 output channels
```

Keep `num_channels=1` for 2-input kernels.

## M10. On AIE2P (XDNA2), bf16 is ¼-rate — route bf16 GEMMs through bfp16

bf16 MAC is native on XDNA1's AIE2 but **emulated through the bfp16 datapath at
~¼ rate** on XDNA2's AIE2P; the native mode is bfp16 block floating point
(8×8×8). The stock matmuls expose the workaround as a flag:

```bash
python whole_array.py … --dtype_in bf16 --dtype_out f32 --emulate-bf16-mmul-with-bfp16 1
```

Measured here: +17% at 512³/32³-tiles, +25% at 2048³ with 64×32×64 tiles
(4.64 vs 3.7-ish TFLOPS). Details: [MLIR-AIE.md](MLIR-AIE.md) → GEMM lessons.

## M11. Native bfp16 can fail as the K-tile count grows

The `ml/block_datatypes` native-bfp GEMM can look fast and still be wrong.
Against a CPU float reference, 512³ and 1024³ pass, while 2048³ fails (291 of
1000 sampled outputs, maximum relative error 12%). With M=N=1024, the observed
boundary is K=1216 **PASS** and K=1280 **FAIL**.

Source inspection suggests repeated bfp16 re-quantization of the partial output
between K tiles; this explains the K dependence but is not yet a proven fix.
Always require a CPU-reference **PASS** before reporting native-bfp throughput.
[`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh) reproduces
and asserts the known boundary.
