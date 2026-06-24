**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# Der `mlir-aie`-(IRON-)Track — ein zweiter offener Weg zur XDNA1-NPU

Der Rest dieses Repositories baut [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie):
einen **Graph-Compiler**, der ganze Modelle (PyTorch / ONNX) auf die NPU absenkt. Diese
Seite ist das verifizierte Rezept für den *anderen* offenen Weg —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) und seine **IRON**-Python-
eDSL —, bei dem du **NPU-Kernels direkt verfasst** und sie via `pyxrt` ausführst. Außerdem
liefert er echte ML-`programming_examples` (conv2d, ResNet-Blöcke, Googles Magika) mit, also
ist es der schnellste Weg, *benannte* Workloads auf eine Phoenix-NPU der ersten Generation zu bringen.

Beide Wege zielen auf `npu1` (Phoenix / XDNA1) und teilen sich dasselbe **Peano-(`llvm-aie`-)
Backend** — wenn du also bereits `./scripts/build.sh` ausgeführt hast, nutzt dieser Track jenes
Peano wieder und kostet praktisch nichts zusätzlich.

> Dieselbe Maschine wie alles andere hier: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO
> 7840U (Phoenix, XDNA1) · Ubuntu 26.04 · Kernel 7.0 · In-Tree-`amdxdna` · XRT
> 2.21 · NPU FW 1.5.5.391**. Verifiziert 2026-06-24.

## iree-amd-aie vs. mlir-aie — welches davon?

| | `iree-amd-aie` (Repository-Wurzel) | `mlir-aie` / IRON (diese Seite) |
|---|---|---|
| Du bringst | einen ganzen Graphen (`.onnx` / PyTorch) | eine Kernel-Idee (Datenfluss + eine C++-Rechenfunktion) |
| Abstraktion | MLIR-Graph-Compiler | ObjectFifo-Datenfluss-eDSL (`aie.iron`) + `aiecc` |
| Host zum Ausführen | `iree-run-module` / der C-API-Runner | `pyxrt` (`make run_py`) |
| Am besten für | „lass mein Modell auf der NPU laufen" | „einen bestimmten NPU-Kernel schreiben/besitzen", echte ML-Beispielblöcke |
| Python | **3.12** (IREE-Build-Abhängigkeiten) | **3.14** (passt zu Ubuntus paketiertem `pyxrt`) |
| Backend | Peano (`llvm-aie`) | **dasselbe** Peano |

Sie sind komplementär, nicht konkurrierend. Nutze das, was zur Aufgabe passt.

## Einrichtung (ein Skript)

```bash
./scripts/setup-mlir-aie.sh
```

Es ist idempotent und tut Folgendes:

1. **Klont `Xilinx/mlir-aie` beim neuesten Release-Tag** (`~/src/mlir-aie`). Die
   `programming_examples` müssen zum installierten Wheel passen, daher ist der Tag auf
   die Wheel-Version fixiert.
2. **Erstellt ein Python-3.14-venv** (`~/src/mlir-aie-venv`) und **symlinkt das
   paketierte `pyxrt`** (`python3-xrt`, gebaut `cpython-314`) hinein — deshalb
   ist das venv 3.14 und nicht das für den iree-amd-aie-Build verwendete 3.12.
3. **Installiert das `mlir_aie`-Wheel** (passender Tag) **+ CPU-`torch`** (die `ml/*`-
   Beispiele prüfen die NPU-Ausgabe gegen einen Torch-Goldwert).
4. **Nutzt das Peano wieder**, das du für `iree-amd-aie` gebaut hast (`~/src/iree-amd-aie/llvm-aie`);
   ist es nicht vorhanden, installiert es stattdessen das `llvm-aie`-Nightly-Wheel.

## Ein Beispiel auf der NPU ausführen

```bash
./scripts/run-mlir-example.sh ml/conv2d                 # default target: run_py (pyxrt)
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: needs libxrt-dev
```

`run-mlir-example.sh` sourct [`scripts/mlir-aie-env.sh`](../scripts/mlir-aie-env.sh)
(Toolchain auf `PATH`, Peano verdrahtet, Gerät automatisch als `npu1` erkannt), baut das
Beispiel für `npu1` und führt es auf der NPU aus. Standardmäßig nutzt es das **`run_py`**-Make-
Target — einen `pyxrt`-Host, der **keine** XRT-Dev-Header braucht.

## Was auf XDNA1 läuft (verifiziert, auf der NPU)

Alles via `run_py` / `pyxrt`, Ausgabe gegen einen Torch-/Numpy-Goldwert geprüft. Die NPU-Zeiten
sind Wanduhrzeit inkl. Host-Dispatch (sie schwanken von Lauf zu Lauf):

| Beispiel | Art | NPU-Zeit |
|---|---|--:|
| `basic/passthrough_kernel` | DMA-Durchleitung | ✓ |
| `basic/vector_scalar_mul` | Vektor × Skalar | ✓ |
| `ml/conv2d` | INT8-3×3-Faltung | ~0,9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fusioniert | ~0,8 ms |
| `ml/bottleneck` | ResNet-Bottleneck-Block (1×1→3×3→1×1 + Skip) | ~2,8 ms |
| `ml/resnet/layers_conv2_x` | ResNet-conv2_x-Schichtgruppe | ~5,1 ms |
| `ml/magika` | Googles Dateityp-Modell (bf16) | ~0,9 ms |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **eigener** fusionierter `relu(a+b)`-Kernel | ~0,37 ms |

**Bekannte Grenzen auf Phoenix (4 Spalten):**

- `basic/matrix_multiplication/*` baut zu einer **xclbin einwandfrei** (512³, 4 Spalten),
  aber sein Host ist **nur C++** — `make run` braucht `libxrt-dev` (die Laufzeit-
  Pakete liefern keine XRT-Dev-Header). `sudo apt install libxrt-dev`, dann
  `./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run`.
- `ml/mobilenet` baut, scheitert aber beim Lauf mit
  `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)`: der Gesamtnetzwerk-Entwurf will mehr
  als die **4** Spalten von Phoenix. Einzelne Blöcke (conv2d, bottleneck, resnet
  conv2_x) und `magika` passen und laufen; das vollständige Netzwerk ist XDNA2-Größenordnung.

## Schreibe deinen eigenen Kernel

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) ist ein handgeschriebener
Kernel, der **keines** der mitgelieferten Beispiele ist: ein einzelnes fusioniertes
`out = max(a + b, 0)` (Residual-Add + ReLU). Er zeigt den ganzen Weg —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — der Rechen-Kernel,
  von Peano für `aie2` kompiliert.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — eine
  `iron.ExternalFunction`, durch `transform_binary` verdrahtet und von `iron.jit`
  kompiliert + ausgeführt, gegen numpy geprüft.

```bash
./examples/mlir-aie/relu_add/run.sh
```

## Für diesen Weg spezifische Stolpersteine

Der IRON-Weg hat seine eigenen Fallen, getrennt vom iree-amd-aie-Build. Die Kurz-
liste (vollständige Details in [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie-Track*):

1. **Hier Python 3.14, nicht 3.12.** Der einzige Weg, Ubuntus paketiertes `pyxrt`
   zu nutzen, ist ein 3.14-venv; ein 3.12-venv kann es nicht importieren.
2. **Stelle `pyxrt` per Symlink** ins venv-`site-packages` bereit (sauberes venv, nicht
   `--system-site-packages`).
3. ⚠️ **Sourc `env_setup.sh` ohne Pipe.** `source env_setup.sh A B | tail`
   führt es in einer Subshell aus und die `export`s verschwinden → leeres `PEANO_INSTALL_DIR` →
   System-`/bin/clang++` → `error: unknown target triple 'aie2-none-unknown-elf'`.
   (`scripts/mlir-aie-env.sh` erledigt das für dich.)
4. **Bevorzuge `make run_py` gegenüber `make run`.** `run_py` ist reines `pyxrt`; `run` baut
   einen C++-Host, der `libxrt-dev` braucht.
5. **Nutze das Peano** von `iree-amd-aie` wieder, statt `llvm-aie` erneut herunterzuladen.
6. **Gesamtnetzwerk-Entwürfe wollen > 4 Spalten** — sie scheitern an `CREATE_HWCTX` auf Phoenix.

## Verhältnis zum Rest des Repositories

Dies ist ein *zusätzlicher* Weg, kein Ersatz. Für „lass mein Modell auf der NPU laufen" ist
der `iree-amd-aie`-Ablauf (`scripts/build.sh` + `scripts/run-matmul.sh` + die
`npu-trim`-/`npu-runner`-Werkzeuge) nach wie vor die Antwort. Greif zu `mlir-aie`, wenn du
einen **bestimmten Kernel schreiben** oder die vorgelagerten **ML-Beispielblöcke**
direkt ausführen willst.
