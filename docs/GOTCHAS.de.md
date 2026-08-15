**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# Gotchas — was bricht, warum, und der Fix

Jeder der folgenden Punkte ist bei einem echten Build aufgetreten und wurde dort gelöst (Ryzen 7840U / XDNA1,
Ubuntu 26.04, Kernel 7.0, 2026-06-22). Sie sind danach geordnet, wo sie dich beißen.
(#0 ist die Ausnahme: aufgetreten auf der Strix-/XDNA2-Maschine am 2026-08-15 — er ist
generationsunabhängig und beißt beim *Aktivieren*, vor jedem Build.)

---

## 0. limits.d sagt memlock `unlimited` — dein Terminal hat trotzdem 8 MB

**Symptom.** `enable-npu.sh` ist gelaufen, `/etc/security/limits.d/99-xrt-npu.conf` sagt
`unlimited`, du hast dich ab- und wieder angemeldet — und trotzdem:

```
$ ulimit -l
8192
$ xrt-smi examine
[xrt-smi] ERROR: mmap(len=67108864, prot=3, flags=8209, ...) failed (err=-11):
          Resource temporarily unavailable
```

**Warum.** Desktop-Linux hat **zwei unabhängige rlimit-Pfade**, und limits.d deckt nur
einen davon ab:

- `pam_limits` wendet limits.d bei **PAM-Logins** an: ssh, TTY und der Session-Leader
  des Display-Managers.
- **GUI-gestartete Apps durchlaufen PAM nie.** Auf einem systemd-Desktop wird dein
  Terminal vom **systemd User-Manager** (`user@<uid>.service`) gespawnt
  und erbt das `LimitMEMLOCK` *dieses Service* — Standard 8 MB, unabhängig von
  limits.d:

  ```
  $ systemctl show user@$(id -u).service -p LimitMEMLOCK
  LimitMEMLOCK=8388608
  $ pstree -sp $$
  systemd(1)───systemd(…)───ptyxis(…)───bash(…)      ← no PAM in this chain
  ```

- Schlimmer noch: mit aktiviertem **Lingering** (`loginctl show-user $USER -p Linger` →
  `yes`; Container-/VPN-Tooling schaltet es oft ein) stoppt ein Logout
  `user@<uid>.service` **nicht** — selbst nachdem du den Service repariert hast, startet
  ein erneutes Anmelden ihn also nie mit dem neuen Limit neu. Das schafft nur ein Reboot.

**Fix** (was `enable-npu.sh` jetzt macht): den limits.d-Eintrag für den PAM-Pfad
behalten *und* ein Drop-in für den User-Manager hinzufügen, dann einmal rebooten:

```
# /etc/systemd/system/user@.service.d/99-xrt-npu-memlock.conf
[Service]
LimitMEMLOCK=infinity
```

Um eine bereits laufende Shell ohne Reboot zu entsperren (Kindprozesse erben
rlimits):

```bash
sudo prlimit --pid $$ --memlock=unlimited:unlimited
```

`check-npu.sh [5]` erkennt jetzt genau diese Diskrepanz — limits.d gewährt es, der
Prozess hat es nicht — und gibt aus, welcher Pfad fehlgeschlagen ist, plus den
Lingering-Status.

*Ein ssh-/TTY-Workflow löst das nie aus (pam_limits deckt ihn ab) — deshalb blieb es
durch den gesamten XDNA1-Build hindurch unsichtbar. Es tauchte auf, als die Aktivierung
zum ersten Mal aus einem GUI-Terminal lief — und es beißt beide Generationen gleichermaßen.*

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

---

# mlir-aie-(IRON-)Track — separate Stolpersteine

Der zweite Weg — [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) via das
`mlir_aie`-Wheel (siehe [MLIR-AIE.de.md](MLIR-AIE.de.md)) — hat seine eigenen Fallen, verschieden
vom obigen iree-amd-aie-Build. `scripts/setup-mlir-aie.sh` und
`scripts/mlir-aie-env.sh` erledigen all diese; das ist es, was sie umschiffen.

## M1. Hier Python **3.14** verwenden — das Gegenteil des iree-Builds

Der iree-amd-aie-Build will **3.12** (Anmerkung oben). Die `mlir_aie`-Wheels unterstützen
3.11–3.14, und der einzige Weg, Ubuntus paketiertes `pyxrt` (aus `python3-xrt`,
gebaut `pyxrt.cpython-314-*.so`) zu nutzen, ist ein **3.14**-venv — ein 3.12-venv kann
jenes `pyxrt` schlicht nicht importieren. Daher nutzen die beiden Tracks bewusst verschiedene Python-venvs.

## M2. `pyxrt` ins venv exponieren

`make run_py` macht `import pyxrt`. Das Debian-Paket legt es bei
`/usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so` ab. Symlinke **genau diese eine Datei**
ins `site-packages` des venv — ein sauberes venv, **nicht** `--system-site-packages`
(was den Rest des System-Site mitschleppen und die Wheel-Abhängigkeiten überschatten würde):

```bash
ln -sf /usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so "$VENV/lib/python3.14/site-packages/"
```

## M3. ⚠️ `env_setup.sh` OHNE Pipe sourcen

```
error: unknown target triple 'aie2-none-unknown-elf'
make: *** [Makefile:37: build/passThrough.cc.o] Error 1
```

Das Makefile kompilierte den AIE-Kernel mit dem **System**-`/bin/clang++` (das
kein `aie2`-Target hat) statt mit Peanos `clang++`. Ursache: `PEANO_INSTALL_DIR` war
leer. Ursache *davon*:

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" | tail   # WRONG
```

Eine Pipe führt die linke Seite in einer **Subshell** aus, sodass jeder `export` in `env_setup.sh`
(`PEANO_INSTALL_DIR`, `MLIR_AIE_INSTALL_DIR`, `NPU2`) in dem Moment verworfen wird, in dem die
Subshell endet. **Umleiten, nicht piping:**

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" >/tmp/env.log 2>&1   # RIGHT
```

(Außerdem: `env_setup.sh` ist nicht `set -e`/`set -u`-sicher geschrieben — es unter
`set -euo pipefail` zu sourcen bricht stillschweigend ab. `scripts/mlir-aie-env.sh` lockert und
stellt diese Flags rund um das Sourcen wieder her.)

## M4. `make run_py` (pyxrt) vs. `make run` (C++-Host + libxrt-dev)

Viele Beispiele liefern **beides** mit: einen C++-Host (`test.cpp` → `make run`) und einen Python-Host
(`test.py` → `make run_py`). Der C++-Host braucht XRT-**Dev-Header**
(`libxrt-dev`), die die Laufzeit-Pakete (`libxrt-utils-npu`, `python3-xrt`)
**nicht** installieren. Bevorzuge `run_py`. Für Nur-C++-Beispiele (matrix_multiplication,
vision, relu, softmax): `sudo apt install libxrt-dev`.

## M5. Peano nur bei passendem Release-Pin wiederverwenden

Die Unterstützung für `aie` / `aie2` / `aie2p` allein genügt nicht. Jede mlir-aie-Version
pinnt ein exaktes `llvm-aie`-Wheel in `utils/peano-requirements.txt`. Das Peano von
iree-amd-aie darf nur wiederverwendet werden, wenn sowohl seine Wheel-Versionsmetadaten
als auch der von `clang --version` gemeldete **Build-Commit** zu diesem Pin passen.
`setup-mlir-aie.sh` prüft beides. Bei manueller Einrichtung ist dies die sicherste
Auswahl einer kompatiblen Version:

```bash
python -m pip install --upgrade -r utils/peano-requirements.txt
SITE="$(python -c 'import site; print(site.getsitepackages()[0])')"
source utils/env_setup.sh "$SITE/mlir_aie"
```

`env_setup.sh` konfiguriert nur die Umgebung; ohne zweites Argument findet es das
gepinnte Wheel in der aktiven venv. Übergib `$HOME/src/iree-amd-aie/llvm-aie` nur
dann ausdrücklich, wenn du dieselbe exakte Version und denselben clang-Commit
geprüft hast—nicht bloß, weil dieses Verzeichnis bereits vorhanden ist.

## M6. Gesamtnetzwerk-Entwürfe wollen mehr als die 4 Spalten von Phoenix

```
RuntimeError: DRM_IOCTL_AMDXDNA_CREATE_HWCTX IOCTL failed (err=-22): Invalid argument
```

`ml/mobilenet` **baut**, scheitert aber bei der `hw_context`-Erstellung: der Whole-Array-
Entwurf fordert mehr Spalten an, als Phoenix exponiert (**4** — dieselben 4 aus Stolperstein
#6 oben). Einzelne Bausteine (`conv2d`, `bottleneck`, `resnet/layers_conv2_x`)
und `magika` passen in 4 Spalten und laufen; das vollständige Netzwerk ist XDNA2-Gebiet
(Strix, 8 Spalten). *(Bestätigt 2026-08-15: auf den 8 Spalten von Strix Point läuft
das vollständige Netzwerk durchgängig, ~176 ms/Inferenz — [XDNA2.de.md](XDNA2.de.md).)*

## M7. IRON 1.4.x hat die unannotierte `@iron.jit`-Aufrufform gebrochen

Gegen 1.3.x geschriebener Code wie

```python
iron.jit(transform_binary)(kernel, a, b, out, tile_size=tile_size)
```

stirbt auf 1.4.x mit

```
TypeError: @iron.jit: parameter(s) ['tile_size', 'trace_size'] of 'transform_binary'
have default values but no In / Out / InOut / CompileTime[T] annotation.
```

1.4.x verlangt eine annotierte Design-Funktion — Tensoren als `In`/`Out`,
Compile-Zeit-Skalare als `CompileTime[T]`-Keyword-only-Parameter — und die
`iron.algorithms.*`-Helfer nehmen im jit-Rumpf jetzt einen **numpy-Typ-Deskriptor**
statt echter Tensoren entgegen:

```python
@iron.jit
def design(a: In, b: In, out: Out, *,
           num_elements: CompileTime[int], tile_size: CompileTime[int]):
    tensor_ty = np.ndarray[(num_elements,), np.dtype[np.int32]]
    return iron.algorithms.transform_binary(kernel, tensor_ty, tile_size=tile_size)
```

`ExternalFunction` erhält weiterhin automatisch ein nachgestelltes `int`-Tile-
Größen-Argument (`pass_size_to_kernel=True` in den parallelen Varianten). Siehe
`examples/mlir-aie/relu_add/` für ein vollständiges Vorher/Nachher.

## M8. Core-lokaler Speicher ist 64 KB — dimensioniere deine Tiles für die FIFOs, nicht für die Mathematik

Ein binärer elementweiser Entwurf braucht **6 Tile-Puffer** gleichzeitig im
Datenspeicher eines Cores (3 ObjectFifos × Doppelpufferung). Bei `tile_size=4096`
int32 sind das 6 × 16 KB = 96 KB, und aiecc scheitert an der Platzierung:

```
error: 'aie.tile' op Basic sequential allocation also failed.
note: MemoryMap: (stack) 0x0-0x3FF … in0_cons_buff_1 0x14400-0x183FF …
```

`tile_size=1024` (6 × 4 KB + Stack) passt mit Luft. Dasselbe Budget erklärt,
warum Whole-Array-GEMM innere 64³-Tiles für i8 akzeptiert, aber nicht für bf16
(2-Byte-Elemente verdoppeln die Puffergrößen).

## M9. Binäre Kernels können keine 2 shim-DMA-Kanäle pro Spalte treiben

`transform_parallel*(…, num_channels=2)` verdoppelt den DDR-Durchsatz für **unäre**
Kernels, indem es einen Worker pro (Spalte, Kanal) laufen lässt. Ein **binärer**
Kernel braucht bereits zwei MM2S-shim-Kanäle pro Spalte — einen pro Eingang —, und
der shim hat genau zwei, also scheitert `num_channels=2` an der Platzierung:

```
error: no ShimNOCTile has sufficient DMA capacity for 0 input/1 output channels
```

Bleib für Kernels mit 2 Eingängen bei `num_channels=1`.

## M10. Auf AIE2P (XDNA2) ist bf16 ¼-Rate — leite bf16-GEMMs durch bfp16

bf16-MAC ist auf XDNA1s AIE2 nativ, aber auf XDNA2s AIE2P **durch den bfp16-
Datenpfad mit ~¼-Rate emuliert**; der native Modus ist bfp16 Block Floating Point
(8×8×8). Die mitgelieferten Matmuls exponieren den Workaround als Flag:

```bash
python whole_array.py … --dtype_in bf16 --dtype_out f32 --emulate-bf16-mmul-with-bfp16 1
```

Hier gemessen: +17% bei 512³/32³-Tiles, +25% bei 2048³ mit 64×32×64-Tiles
(4.64 vs. ~3.7 TFLOPS). Details: [MLIR-AIE.de.md](MLIR-AIE.de.md) → GEMM-Lektionen.

## M11. Native bfp16-Ergebnisse können mit wachsender K-Tile-Zahl falsch werden

Das native bfp-GEMM aus `ml/block_datatypes` kann schnell aussehen und trotzdem
falsch rechnen. Gegen eine CPU-float-Referenz bestehen 512³ und 1024³, während
2048³ fehlschlägt (291 von 1000 Stichproben, maximaler relativer Fehler 12%).
Bei M=N=1024 liegt die beobachtete Grenze zwischen K=1216 (**PASS**) und
K=1280 (**FAIL**).

Die Quellcodeanalyse deutet auf eine wiederholte bfp16-Requantisierung der
Zwischenausgabe zwischen K-Kacheln hin. Das erklärt die K-Abhängigkeit, ist aber
noch keine bewiesene Lösung. Native-bfp-Durchsätze nur zusammen mit einer
bestandenen CPU-Referenzprüfung berichten.
[`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh) reproduziert
und prüft die bekannte Grenze.
