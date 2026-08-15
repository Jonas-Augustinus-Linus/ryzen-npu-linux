**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# Der `mlir-aie`-(IRON-)Track — NPU-Kernels verfassen, beide Generationen

Der Rest dieses Repositories baut [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie):
einen **Graph-Compiler**, der ganze Modelle (PyTorch / ONNX) auf die NPU absenkt. Diese
Seite ist das verifizierte Rezept für den *anderen* offenen Weg —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) und seine **IRON**-Python-
eDSL —, bei dem du **NPU-Kernels direkt verfasst** und sie via `pyxrt` ausführst.

Der Pfad wurde auf **beiden NPU-Generationen** verifiziert, allerdings mit
release-spezifischen Entwürfen statt mit einem identischen Wheel:

> **XDNA1** — Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, `npu1`) ·
> Ubuntu 26.04 · Kernel 7.0 · XRT 2.21 · am 2026-06-24 mit mlir-aie 1.3.x
> verifiziert (der frühere Einzel-Worker-Entwurf).
>
> **XDNA2** — Ryzen AI 9 HX PRO 370 (Strix Point, `npu2`, XRT-Name
> `RyzenAI-npu4`) · Radeon 890M · Ubuntu 26.04 · Kernel 7.0 · Ubuntu-natives XRT
> 2.21.75 · NPU FW 1.1.2.64 · am 2026-08-15 mit **mlir-aie 1.4.1**
> verifiziert (die aktuellen annotierten Einzel-Worker- und Whole-Array-Entwürfe).

Die aktuellen 1.4.x-Entwürfe wurden nicht erneut auf XDNA1 verifiziert; der
XDNA1-Eintrag dokumentiert das frühere 1.3.x-Ergebnis.

## iree-amd-aie vs. mlir-aie — welches davon?

| | `iree-amd-aie` (Repository-Wurzel) | `mlir-aie` / IRON (diese Seite) |
|---|---|---|
| Du bringst | einen ganzen Graphen (`.onnx` / PyTorch) | eine Kernel-Idee (Datenfluss + eine C++-Rechenfunktion) |
| Abstraktion | MLIR-Graph-Compiler | ObjectFifo-Datenfluss-eDSL (`aie.iron`) + `aiecc` |
| Host zum Ausführen | `iree-run-module` / der C-API-Runner | `pyxrt` (das Python-Design führt sich selbst aus) |
| Am besten für | „lass mein Modell auf der NPU laufen" | „einen bestimmten NPU-Kernel schreiben/besitzen", echte ML-Beispielblöcke |
| Python | **3.12** (IREE-Build-Abhängigkeiten) | **3.14** (passt zu Ubuntus paketiertem `pyxrt`) |
| Backend | Peano (`llvm-aie`) | **dasselbe** Peano — `aie2` (npu1) / `aie2p` (npu2), automatisch gewählt |

Sie sind komplementär, nicht konkurrierend. Nutze das, was zur Aufgabe passt.

## Einrichtung (ein Skript)

```bash
./scripts/setup-mlir-aie.sh
```

Idempotent; klont `Xilinx/mlir-aie` beim neuesten Release-Tag, erstellt ein
Python-3.14-venv, symlinkt Ubuntus paketiertes `pyxrt` hinein, installiert das
passende `mlir_aie`-Wheel (1.4.1 liefert `cp314`-manylinux-Wheels aus) + CPU-`torch`
und nutzt dein iree-amd-aie-Peano wieder (oder installiert das `llvm-aie`-Wheel —
das Wheel ist `py3-none`, also Python-versions-agnostisch). Die Generationserkennung
ist die des Upstreams: `env_setup.sh` grept `xrt-smi examine` und exportiert
`NPU2=0/1`.

## Ein Beispiel auf der NPU ausführen

```bash
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh ml/softmax
./scripts/run-mlir-example.sh ml/conv2d          # Makefile example
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
    -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
```

**mlir-aie 1.4.x hat die Beispiele umstrukturiert** — das Skript beherrscht beide Formen:

- Die meisten Beispiele sind jetzt ein **einzelnes, direkt ausgeführtes
  Python-Design**: `@iron.jit` kompiliert beim ersten Aufruf, das Gerät
  (`npu`/`npu2`) wird automatisch erkannt, und das Design bringt sein eigenes
  Benchmark-/Verify-Harness mit. Per-Beispiel-Makefiles sind aus dem Großteil
  von `basic/` verschwunden; lit-Dateien (`run.lit` / `run_strix.lit`)
  dokumentieren die kanonischen Aufrufe.
- `ml/conv2d`, `ml/mobilenet` und die matmul-C++-Host-Varianten nutzen weiterhin
  ein Makefile — `devicename=npu2` wählt die Generation
  (`devicename ?= $(if $(filter 1,$(NPU2)),npu2,npu)`).
- `aiecc.py` ist weg: `aiecc` ist in 1.4.x ein **C++-Binary**, und **Peano ist
  das Standard-Backend** (chess braucht explizit `--xchesscc --xbridge` + Vitis).

## Was auf XDNA2 läuft (verifiziert, auf der NPU, mlir-aie 1.4.1)

Strix Point exponiert **8 Spalten / 32 Compute-Tiles** gegenüber IRON (Phoenix: 4/16).
Alle Messungen unten stammen von den Maschinen dieses Repos; „NPU-Zeit" ist der
On-NPU-Wert der Runtime (um `kernel.wait()` herum), ohne Host-Launch-Overhead.

### Kernels & Blöcke

| Beispiel | Art | XDNA2-Ergebnis |
|---|---|--:|
| `basic/passthrough_kernel` | DMA-Durchleitung | ✓ 94 µs |
| `basic/vector_scalar_mul` | Vektor × Skalar | ✓ 106 µs |
| `ml/softmax` | LLM-Block | ✓ PASS |
| `ml/rope` | LLM-Block | ✓ PASS |
| `ml/swiglu` | LLM-Block | ✓ PASS |
| `ml/norm -o rms` | RMSNorm | ✓ PASS |
| `ml/mm_activation_epilogue` | Matmul + fusionierte Aktivierung | ✓ PASS |
| `ml/conv2d` (i8, 32×32, 64ch) | INT8-Faltung | ✓ 490 µs (XDNA1: ~900 µs) |
| `ml/mobilenet` | **vollständiges Netzwerk** | ✓ **PASS, ~176 ms/Inferenz** |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | eigener fusionierter Kernel | ✓ siehe unten |

`ml/mobilenet` ist der Entwurf, der **auf XDNA1 nicht laufen kann** — er will mehr
Spalten als die 4 von Phoenix und stirbt in `CREATE_HWCTX`. Auf den 8 Spalten von
Strix läuft das gesamte Netzwerk durchgängig. (Upstream verifiziert es derzeit mit
einer gelockerten `atol=9`-Toleranz — deren Anmerkung, hier wiedergegeben.)

### GEMM (`basic/matrix_multiplication/whole_array`, 8 Spalten)

| Form | dtype | inneres Tile | NPU-Zeit | Durchsatz |
|---|---|---|--:|--:|
| 512³ | i16→i32 | 32³ | 203 µs | 1.32 TOPS |
| 512³ | bf16→f32 | 32³ | 233 µs | 1.15 TFLOPS |
| 512³ | bf16 via **bfp16** | 32³ | 199 µs | 1.35 TFLOPS |
| 2048³ | bf16 via **bfp16** | 32³ | 9.71 ms | 1.77 TFLOPS |
| 2048³ | i8→i32 | 32³ | 8.73 ms | 1.97 TOPS |
| 2048³ | bf16 via **bfp16** | 64×32×64 | 3.70 ms | **4.64 TFLOPS** |
| 2048³ | i8→i32 | 64³ | 2.59 ms | **6.65 TOPS** |

Zwei Lektionen, die die Tabelle lehrt:

1. **Die innere Tile-Größe ist 3.4× wert** (i8: 1.97 → 6.65 TOPS allein durch
   32³→64³-Tiles). Noch größere Tiles sprengen den 64-KB-Core-lokalen Speicher
   und scheitern an der Platzierung — bf16 tut das bei 64³ bereits.
2. **Auf AIE2P für bf16-Mathematik den bfp16-Pfad bevorzugen**
   (`--emulate-bf16-mmul-with-bfp16 1`). bf16-MAC ist auf XDNA1s AIE2 nativ,
   aber auf XDNA2s AIE2P *mit ~¼-Rate emuliert*; der native Modus ist **bfp16
   Block Floating Point** (8×8×8). Gratis +17% bei 512³, +25% mit getunten Tiles.

Der **native bfp16ebs8**-End-to-End-Entwurf (`ml/block_datatypes/…`) wurde auch
gegen seine CPU-float-Referenz ausgeführt. Dabei zeigte sich eine
Korrektheitsgrenze, die eine reine Durchsatzmessung verbergen würde:

| Native bfp16-Form (8 Spalten) | Durchsatz | CPU-Referenzergebnis |
|---|---:|---|
| 512³ | 1.525 TFLOPS | **PASS** |
| 1024³ | 4.892 TFLOPS | **PASS** |
| 2048³ | ~5.09 TFLOPS | **FAIL** — 291/1000 Stichproben, max. relativer Fehler 12% |

Die Durchsatzwerte wurden mit Peano 22 (`4a1adefa`) erfasst, bevor die
Umgebung an den v1.4.1-Pin angepasst wurde. Anschließend wurde der vollständige
PASS/FAIL-Sweep mit dem gepinnten Peano 21 (`c9c5ecb7`) wiederholt; die Grenze
blieb unverändert. Das Skript prüft bewusst die Korrektheit statt des Timings.

Wird bei M=N=1024 nur die Reduktionslänge variiert, besteht K=1216 (**PASS**),
während K=1280 fehlschlägt (**FAIL**).
[`check-bfp16-correctness.sh`](../scripts/check-bfp16-correctness.sh) reproduziert
und prüft diese bekannte Grenze. Die Quellcodeanalyse deutet darauf hin, dass
jede K-Kachel die bfp16-Ausgabe neu lädt und speichert und so die Zwischensumme
wiederholt quantisiert. Das ist eine Hypothese zur K-Abhängigkeit, keine
bewiesene Lösung. Native-bfp-Durchsätze dürfen nur mit bestandener
CPU-Referenzprüfung berichtet werden. Davon getrennt ist der 2048³-Pfad mit
**bf16-Ein-/Ausgabe und internem bfp16** in der Tabelle oben: dessen
**4.64 TFLOPS** bestanden die Korrektheitsprüfung.

### Eigener Kernel, Whole-Array-Skalierung

Unser fusioniertes `relu(a+b)` ([`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/)),
1M int32-Elemente, Tile 1024:

| Entwurf | NPU-Zeit | Effektive DDR-Bandbreite |
|---|--:|--:|
| einzelner Worker (1 Tile) | 8 967 µs | 1.4 GB/s |
| Whole Array (8 Spalten, `transform_parallel_binary`) | 1 123 µs | 11.2 GB/s |

**8.0× durch 8 Spalten** — lineare Skalierung für diesen bandbreitengebundenen Kernel.

## Was auf XDNA1 läuft (verifiziert, auf der NPU, 2026-06-24)

| Beispiel | Art | NPU-Zeit |
|---|---|--:|
| `basic/passthrough_kernel` | DMA-Durchleitung | ✓ |
| `basic/vector_scalar_mul` | Vektor × Skalar | ✓ |
| `ml/conv2d` | INT8-3×3-Faltung | ~0,9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fusioniert | ~0,8 ms |
| `ml/bottleneck` | ResNet-Bottleneck-Block | ~2,8 ms |
| `ml/resnet/layers_conv2_x` | ResNet-conv2_x-Schichtgruppe | ~5,1 ms |
| `ml/magika` | Googles Dateityp-Modell (bf16) | ~0,9 ms |
| `examples/mlir-aie/relu_add` | eigener fusionierter `relu(a+b)`-Kernel | ~0,37 ms |

**Bekannte Grenzen auf Phoenix (4 Spalten):** `ml/mobilenet` baut, scheitert aber mit
`DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` — Gesamtnetzwerk-Entwürfe sind
XDNA2-Größenordnung (oben bestätigt). Einzelne Blöcke passen und laufen.

## Schreibe deinen eigenen Kernel

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) ist ein handgeschriebener
Kernel, der **keines** der mitgelieferten Beispiele ist: ein einzelnes fusioniertes
`out = max(a + b, 0)`. Er zeigt den ganzen Weg auf beiden Generationen —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — der Rechen-Kernel;
  Peano kompiliert ihn je nach erkanntem Gerät für `aie2` oder `aie2p`, ohne
  Quellcode-Änderung.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — die annotierte
  `@iron.jit`-Form von IRON 1.4.x (`In`/`Out`/`CompileTime[...]`), in zwei
  Entwürfen: einzelner Worker (`transform_binary`) und ein Worker pro Spalte
  (`transform_parallel_binary`, 4 oder 8 Spalten automatisch).

```bash
./examples/mlir-aie/relu_add/run.sh
```

**API-Anmerkung:** IRON 1.4.x **verlangt** die Annotationen — die ältere
Aufrufform `iron.jit(transform_binary)(kernel, a, b, out, tile_size=…)` (die
dieses Beispiel auf 1.3.x nutzte) wirft jetzt `TypeError: … no In / Out / InOut /
CompileTime[T] annotation`. Die 1.4.x-Algorithmen nehmen im jit-Rumpf einen
*Tensor-Typ-Deskriptor* statt echter Tensoren entgegen. Die Portierung ist
mechanisch — siehe das Diff des Beispiels.

## Für diesen Weg spezifische Stolpersteine

Die Kurzliste — vollständige Details in [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie-Track*:

1. **Hier Python 3.14, nicht 3.12** (Ubuntus paketiertes `pyxrt` ist cpython-314).
2. **Stelle `pyxrt` per Symlink** ins venv-`site-packages` bereit.
3. ⚠️ **Sourc `env_setup.sh` ohne Pipe** — Pipe = Subshell = die
   `export`s (`NPU2`, `PEANO_INSTALL_DIR`…) verschwinden.
4. **IRON-1.4.x-Annotations-API-Bruch** — siehe oben.
5. **Core-lokaler Speicher ist 64 KB**: 3 doppelt gepufferte int32-FIFOs bei
   `tile_size` 4096 = 96 KB → `aie.tile op … allocation failed`. Tiles passend
   dimensionieren.
6. **Binäre Kernels können `num_channels=2` nicht nutzen** — 2 Eingänge belegen
   bereits beide shim-MM2S-DMA-Kanäle pro Spalte
   (`no ShimNOCTile has sufficient DMA capacity`).
7. **bf16 auf AIE2P ist ¼-Rate-Emulation** — nutze den bfp16-Pfad (siehe die
   GEMM-Lektionen oben).
8. **Nutze das Peano** von `iree-amd-aie` wieder, wenn vorhanden; ein unfixiertes
   `pip install llvm-aie` greift heute ein 22.x-Nightly, das ein LLVM-Major vor
   dem liegt, was die mlir-aie-CI testet — das Setup-Skript fixiert für dich.

## Verhältnis zum Rest des Repositories

Dies ist ein *zusätzlicher* Weg, kein Ersatz. Für „lass mein Modell auf der NPU laufen" ist
der `iree-amd-aie`-Ablauf (`scripts/build.sh` + `scripts/run-matmul.sh` + die
`npu-trim`-/`npu-runner`-Werkzeuge) auf XDNA1 nach wie vor die Antwort; seine XDNA2-
Portierung wird in [XDNA2.md](XDNA2.md) verfolgt. Greif zu `mlir-aie`, wenn du
einen **bestimmten Kernel schreiben** oder die vorgelagerten **ML-Beispielblöcke**
direkt ausführen willst.
