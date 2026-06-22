**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# Gotchas — was bricht, warum, und der Fix

Jeder der folgenden Punkte ist bei einem echten Build aufgetreten und wurde dort gelöst (Ryzen 7840U / XDNA1,
Ubuntu 26.04, Kernel 7.0, 2026-06-22). Sie sind danach geordnet, wo sie dich beißen.

---

## 1. clang segfaultet beim Bauen von MLIR → gcc verwenden

**Symptom**
```
FAILED: .../obj.MLIRIR.dir/BuiltinDialectBytecode.cpp.o
clang++: error: clang frontend command failed with exit code 139
... file INSTALL cannot find ".../libIREECompiler.so": No such file
```
`exit 139` = SIGSEGV: das Host-**clang (getestet 21.x) stürzt ab** beim Kompilieren einer großen
generierten MLIR-Datei. Weil diese Datei im Kern-`MLIRIR` liegt, wird die Compiler-Bibliothek
nie gelinkt und die gesamte Installation bricht zusammen — doch der *erste* Fehler scrollt vorbei
und du bemerkst nur das Fehlschlagen der Installation.

**Fix.** Mit **gcc** bauen:
```bash
export CC=gcc CXX=g++
rm -rf iree-build      # required: cmake won't switch compilers in an existing dir
cmake ...              # reconfigure
```
gcc 15 baut denselben Baum sauber (~65 min auf 16 Cores).

---

## 2. Python-Bindings: `_POSIX_C_SOURCE`-Makro neu definiert → abschalten

**Symptom**
```
.../python3.12/include/python3.12/pyconfig.h:1877:9:
  error: '_POSIX_C_SOURCE' macro redefined [-Werror,-Wmacro-redefined]
FAILED: runtime/bindings/python/.../PyExtRt.dir/...cc.o
```
Die IREE-Python-(nanobind)-Bindings stolpern über eine Neudefinition eines Feature-Test-Makros, die
unter `-Werror` fatal ist. Du brauchst die Python-Bindings **nicht**, um Matmuls zu kompilieren und
auszuführen — die Binaries `iree-compile` / `iree-run-module` / `iree-e2e-matmul-test`
reichen aus.

**Fix.** `-DIREE_BUILD_PYTHON_BINDINGS=OFF` (und das Target `iree-install-dist` überspringen).

---

## 3. Die fixierte Peano-(llvm-aie)-Version ist abgelaufen

**Symptom**
```
ERROR: Could not find a version that satisfies the requirement
  llvm_aie==19.0.0.2025052701+31d2aa6e (from versions: 21.0.0.2026061101+..., ...)
```
`build_tools/peano_commit_linux.txt` fixiert ein bestimmtes `llvm-aie`-Nightly, aber der
Xilinx-Nightly-Index behält nur aktuelle Builds — die Fixierung (upstream seit
~13 Monaten unverändert) ist längst weg.

**Fix.** Die Fixierung auf das neueste verfügbare Nightly zeigen lassen:
```bash
echo "<latest-nightly-version>" > build_tools/peano_commit_linux.txt
bash build_tools/download_peano.sh
```
`scripts/build.sh` macht das automatisch, indem es den Index abfragt. Das neuere Peano
funktioniert trotz des Versionssprungs einwandfrei (es ist das AIE-LLVM-Backend; die Schnittstelle ist stabil).

---

## 4. Build bricht bei absichtlich übersprungenen Submodulen ab

**Symptom**
```
The git submodule 'third_party/stablehlo' is not initialized.
CMake Error: check_submodule_init.py failed
```
Du klonst ohne `torch-mlir`, `stablehlo`, `XRT` (keines davon wird für den
amdxdna-Pfad benötigt), aber IREEs Submodul-Prüfung wirft trotzdem einen Fehler.

**Fix.** `-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`. (Und du musst AMDs Out-of-Tree-`xdna-driver`
**nicht** bauen: das In-Tree-`amdxdna.ko` stellt das Gerät bereit, und
der `amdxdna`-HAL liefert seinen eigenen Shim mit, der `/dev/accel0` direkt öffnet.)

---

## 5. Modul für den falschen HAL kompiliert → Dispatch wird nie abgeschlossen

**Symptom.** Kompiliert sauber, aber zur Laufzeit:
```
amdxdna dispatch did not complete: ert state 8; while invoking ... hal.fence.await
```
Wenn du `--iree-amdaie-device-hal=amdxdna` weglässt, wird das Modul für einen anderen
(z. B. `xrt`-)HAL gebaut und läuft unter `--device=amdxdna` nicht korrekt.

**Fix.** Mit dem vollständigen Flag-Satz kompilieren:
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

## 6. ⚠️ Der große Brocken: Spaltenanzahl zur Laufzeit

**Symptom.** Dasselbe `ert state 8`-**TIMEOUT** wie bei #5, sogar mit korrekten Compile-Flags.
Der Befehl erreicht die NPU (du siehst den Dispatch), die Cores laden, dann
**hängen sie für immer** und laufen nach ~60 s in einen Timeout. `dmesg` zeigt **keinen** Hardwarefehler —
die Cores warten einfach auf eine Partition, die nie passt.

**Ursache.** Die rohen AIE-Metadaten von Phoenix melden **5 Spalten**, aber die nutzbare
Anzahl — und das Compile-Target `npu1_4col` — ist **4**. Der Treiber-Helfer stimmt dem zu:
```
$ python build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py --num-cols
4
```
Übergibst du `--amdxdna_n_core_cols=5`, richtet die Runtime eine 5-Spalten-Partition ein, während
das Modul 4 erwartet → Mismatch → Hänger.

**Fix.** Mit den Werten ausführen, die der Geräte-Helfer meldet (rows=4, **cols=4**):
```
--amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4
```
`scripts/run-matmul.sh` liest diese automatisch aus `--num-rows`/`--num-cols`.

---

## Nicht-blockierende Anmerkungen

- **`xrt-smi validate` schlägt fehl** mit `Archive not found: amdxdna/bins/xrt_smi_phx.a`.
  Das ist Ubuntu, das das Phoenix-Selbsttest-Binary entfernt, **kein** kaputter NPU.
- **Der vorhergesagte UAPI/ABI-Mismatch ist nicht eingetreten.** Das In-Tree-`amdxdna` von Kernel 7.0
  und das von `iree-amd-aie` mitgelieferte `amdxdna_accel.h` waren kompatibel: der Topologie-
  ioctl und die Geräte-Enumeration funktionierten beide auf Anhieb.
- **Python 3.13/3.14 sind zu neu** für IREEs Build-Abhängigkeiten — eine isolierte 3.12 verwenden
  (die Skripte nutzen `uv`).
