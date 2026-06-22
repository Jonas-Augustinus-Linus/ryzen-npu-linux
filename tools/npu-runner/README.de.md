**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-runner — persistenter XDNA1-NPU-Caller (IREE-Laufzeit-C-API)

Lädt eine `.vmfb` **einmal** und ruft die NPU im selben Prozess viele Male auf, statt
pro Aufruf `iree-run-module` zu starten. Gemessen auf einem 7840U: **~3.7 ms/invoke gegenüber
~41 ms/invoke** beim Subprozess-Pfad — ~11× schneller, weil das XRT-Device-Open und das
Starten des Prozesses einmalig geschehen, nicht bei jedem Aufruf. Das ist es, was aus „die NPU funktioniert in
einem Benchmark" ein „die NPU ist nutzbar für Always-on-KWS / Embeddings / CNN / Kamera / Audio" macht.

Zwei Formen, derselbe Kern:
- **`npu_runner`** — eine eigenständige CLI/Benchmark (`npu_runner.cc`).
- **`libnpu.so` + `npu.py`** — eine ctypes-Shared-Library, damit **Python** die
  NPU schnell aufrufen kann (verwendet von [`../../examples/npu-camera`](../../examples/npu-camera) und dem
  [wake-word](../wake-word)-Kopf).

## Build

Setzt ein gebautes `iree-amd-aie` voraus (siehe [`../../scripts/build.sh`](../../scripts/build.sh)).
Beide Build-Skripte beachten `IREE_AMD_AIE_ROOT` (Standard `~/src/iree-amd-aie`).

```bash
./build.sh        # -> npu_runner (CLI)
./build_lib.sh    # -> libnpu.so   (ctypes)
```

## Run

```bash
# make a test module (i32 128x128 @matmul)
~/src/iree-amd-aie/run_npu_matmul.sh 2 3        # -> /tmp/matmul_npu.vmfb (all 768)

./npu_runner /tmp/matmul_npu.vmfb 1000          # 1000 in-process invokes
python3 npu.py /tmp/matmul_npu.vmfb             # Python ctypes self-test -> 768
```

```python
from npu import NPU
npu = NPU("/tmp/matmul_npu.vmfb")               # i32 128x128 @matmul
out = npu.matmul(a, b)                           # a,b int32[128,128] -> int32[128,128]
npu.close()
```

## Was nicht offensichtlich war (damit du nicht erneut darüber stolperst)

- **g++, niemals clang** (clang21 löst einen ICE in der amdxdna-Treiber-TU aus), wie beim Haupt-Build.
- **System-Allocator-Makro:** Die Laufzeit-C-API deklariert
  `iree_allocator_system()` nur, wenn `-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl`
  definiert ist (der Build setzt es in CMake; eine eigenständige Kompilierung muss es übergeben).
- **Proactor pool:** Die amdxdna-Device-Erzeugung dereferenziert einen proactor pool für asynchrones
  I/O — ohne einen segfaultet sie. Wir erzeugen einen mit
  `iree_async_proactor_pool_create(1, NULL, …)` und setzen ihn auf
  `iree_hal_device_create_params_t.proactor_pool` (das, was die
  `try_create_default_device` der Laufzeit intern macht).
- **`n_core_cols = 4`** wird explizit auf den Device-Params gesetzt (5 → ERT-State-8-
  Timeout); ein eigenständiges Programm parst die `--amdxdna_*`-Flags nicht.
- **Linking:** Die Laufzeit-C-API liegt in `libiree_runtime_unified.a`, aber der amdxdna-
  Treiber zieht ein paar HAL-utils-Archive nach, die nicht darin gebündelt sind (deferred_command_buffer,
  queue_emulation, queue_host_call_emulation, resource_set, file_transfer) plus
  async + proactor_pool. Falls ein künftiger Checkout undefinierte Symbole hinzufügt, finde das
  Archiv mit `nm $BLD/**/*.a | grep ' T <symbol>'` und füge es zur Link-Gruppe hinzu.

## Dateien

| Datei | Rolle |
|---|---|
| `npu_runner.cc` / `build.sh` | eigenständige CLI + Benchmark |
| `libnpu.cc` / `build_lib.sh` | die `libnpu.so` ctypes-Shared-Library |
| `npu.py` | Python-Wrapper um `libnpu.so` |
