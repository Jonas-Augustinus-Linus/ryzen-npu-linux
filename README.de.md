**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Offenes Ryzen-AI-**XDNA1- und XDNA2**-Computing unter **Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Jonas-Augustinus-Linus/ryzen-npu-linux)](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1 and XDNA2](https://img.shields.io/badge/NPU-XDNA1%20%2B%20XDNA2-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

Ein offener, reproduzierbarer Weg von *treibersichtbar-aber-untätig* zu echtem,
CPU-geprüftem NPU-Computing unter Linux. Er bewahrt den ursprünglichen
XDNA1/Phoenix-Quellpfad und bringt denselben Vertrag aus Erkennen → Bauen →
Prüfen → persistentem Runner auf Strix Point XDNA2 (`RyzenAI-npu4`).

> **Warum dieses Repository existiert.** Fast jeder Artikel von 2026 nach dem Motto „die Ryzen AI NPU
> funktioniert endlich unter Linux" handelt von **XDNA2** (Strix/Krackan). Die
> **XDNA1**-Chips der ersten Generation in Ryzen-7040/8040-Laptops (z. B. dem 7840U) werden von
> den schlüsselfertigen Stacks *ausdrücklich ausgeschlossen* — AMDs Ryzen AI Software für Linux, der Vitis AI
> EP der ONNX Runtime, Lemonade/FastFlowLM. Unter XDNA1+Linux wird die NPU vom
> In-Tree-Treiber `amdxdna` eingeschaltet und enumeriert, aber **keine ausgelieferte Laufzeitumgebung wird ein Modell darauf
> ausführen.** Der eine offene Weg, der *tatsächlich* auf XDNA1 abzielt, ist `iree-amd-aie` — aus dem
> Quellcode gebaut. Dieses Repository ist die verifizierte, Stolperstein-für-Stolperstein-Karte dieses Weges.

> 🆕 **Auf XDNA2 Strix Point (`RyzenAI-npu4`)?** Die zweite Generation hat die Lage gedreht:
> Turnkey-LLM-Inferenz existiert jetzt unter Linux (FastFlowLM/Lemonade),
> Ubuntu 26.04 liefert den XRT-Userspace nativ mit — und das
> Aktivierungs-Tooling dieses Repos funktioniert dort **unverändert**
> (verifiziert auf einem Ryzen AI 9 HX PRO 370). **Compute ebenfalls**:
> der mlir-aie/IRON-Track läuft auf allen 8 Strix-Spalten — 6.65 TOPS i8-GEMM,
> das vollständige MobileNet, unser eigener Kernel mit 8.0×-Spalten-Skalierung
> ([docs/MLIR-AIE.de.md](docs/MLIR-AIE.de.md)). Was übertragbar ist, was sich
> ändert und wohin die offene Front gewandert ist: **[docs/XDNA2.de.md](docs/XDNA2.de.md)**.
> Spätere `npu5`/`npu6`-Geräte werden nicht stillschweigend zugeordnet oder
> beansprucht; siehe die genaue [Support-Matrix](docs/SUPPORT.md).

## 🌱 Warum wir dies frei weitergeben

Der Weg auf einem einzigen Rechner ist nicht das Ziel. Dieses Repository steht
unter der MIT-Lizenz und wird kostenlos veröffentlicht, damit Linux-Nutzer jede
Schicht prüfen, die Ergebnisse wiederholen, Kernels verändern und Verbesserungen
zurückgeben können. Wir hoffen, dass Lernende, unabhängige Entwickler, Forschung
und kleine Teams darauf **viele verschiedene LLMs und lokale KI-Systeme** bauen:
private Agents, Barrierefreiheit, mehrsprachige Modelle, stromsparende Dienste,
neue Quantisierung und Anwendungen, an die wir noch gar nicht gedacht haben.

Dies ist eine Grundlage, keine Behauptung, dass jedes LLM bereits durchgängig
läuft. Die Grundlage ist konkret: strikte Geräteerkennung, gepinnte Builds,
CPU-Referenzkorrektheit, persistente C-/Python-Aufrufe, funktionierende Beispiele
und öffentliche Fehlergrenzen. Erfolg bedeutet, dass andere darauf aufbauen
können. Siehe die [offene LLM-Roadmap](docs/LLM-ROADMAP.md) und den
[Beitragsleitfaden](CONTRIBUTING.md).

## 🎬 Demos

### XDNA2 / Strix Point — Live-Hardware

IREE-`npu4`-Matmuls in i32 und bf16 stimmen exakt mit ihren CPU-Referenzen
überein, der persistente Runner prüft alle 16.384 Ausgaben, und der eigene
IRON-Kernel besteht auf allen 8 Spalten sowohl mit XRT als auch mit HRX:

![XDNA2-Strix-Point-Live-Hardware-Demo mit exakten CPU-Vergleichen, vollständiger npu-runner-Ausgabeprüfung sowie IRON-Pässen mit XRT und HRX](docs/media/xdna2-compute.gif)

### XDNA1 / Phoenix — ursprüngliche verifizierte Demos

**Durchgängig — ein ONNX MLP auf der NPU** (Matmuls auf der NPU, `ReLU` auf der CPU; stimmt mit der CPU-Referenz auf ~0.3% überein):

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| Diagnose → Matmul → Benchmark → Python, **auf der NPU** | NPU-2D-Weichzeichner auf drei `videotestsrc`-Mustern → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| Weckwort-KWS — 3 dichte Schichten auf der NPU (das Ziel löst aus, Rauschen bleibt still) | bf16 ist die native Stärke der NPU — bis zu **220 GFLOP/s** |
| ![wake-word demo](docs/media/wake-word.gif) | ![benchmark demo](docs/media/benchmark.gif) |
| ein echtes `.onnx` → NPU-anvisierbares MLIR bringen (hybrider Import; die Op-Abdeckung des From-Source-amd-aie-Codegens ist die Grenze) | die Matmuls **und Convs** extrahieren, die **tatsächlich** auf der NPU kompilieren — `npu-trim` filtert Ops & erzeugt saubere Kernels |
| ![onnx-import demo](docs/media/onnx-import.gif) | ![npu-trim demo](docs/media/npu-trim.gif) |

## ✅ Was funktioniert (verifiziert)

Kompiliert und **auf der NPU** ausgeführt (`--device=amdxdna`), korrekte Ergebnisse,
wiederholbar:

| Workload | Form | Ergebnis | Durchsatz (NPU) |
|---|---|---|---|
| `i32`-Matmul | 128×128×128 | ✓ exakt | ~3,6 ms/Iter., ~280/s |
| `bf16 → f32`-Matmul | 256×256×256 | ✓ exakt (inkl. Nachkommastellen) | ~2,9 ms/Iter., ~350/s |

Getestete Maschine: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · Kernel 7.0 · In-Tree-`amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**.
Diese XDNA1-Messungen sind historische Werte des damals aktuellen Nightly; mit dem
aktuellen exakten v1-Pin, der auf Strix erneut verifiziert wurde, wurden sie noch nicht wiederholt.

## 📊 Benchmarks

Durchgängig auf der NPU via `iree-benchmark-module` (`--device=amdxdna`,
`npu1_4col`, 10 Wiederholungen, Mittelwert). Die Wanduhrzeit umfasst den Host-Dispatch-Overhead,
weshalb die kleinsten Matmuls dispatch-gebunden sind; die effektive Rechenleistung steigt mit der Größe.

| dtype | Form (M×N×K) | Zeit/Iter. | Durchsatz | Rechenleistung |
|---|---|--:|--:|--:|
| `i32` | 128×128×128 | 3.58 ms | 279 it/s | 1.2 GFLOP/s |
| `i32` | 256×256×256 | 8.08 ms | 124 it/s | 4.2 GFLOP/s |
| `i32` | 512×512×512 | 43.6 ms | 23 it/s | 6.2 GFLOP/s |
| `bf16→f32` | 256×256×256 | 2.86 ms | 350 it/s | 11.7 GFLOP/s |
| `bf16→f32` | 512×512×512 | 3.90 ms | 257 it/s | 68.8 GFLOP/s |
| `bf16→f32` | 1024×1024×1024 | 9.76 ms | 102 it/s | 220 GFLOP/s |

**bf16 ist die native Stärke der NPU** — ~220 GFLOP/s bei 1024³ und immer noch skalierend,
während `i32` (nicht der native Typ der AIE) bei etwa 6 GFLOP/s an seine Grenze stößt. Jede Zeile reproduzieren:
`BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`.

## 🚀 Schnellstart

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux

# Host-/Platten-/sudo-Anforderungen lesen, dann strikt und nur-lesend prüfen.
less docs/SUPPORT.md
./scripts/check-npu.sh --strict

# Nur bei Gruppen-/memlock-/XRT-Fehlern: prüfen, ausführen, einmal neu starten.
./scripts/enable-npu.sh

# Den in versions.lock gepinnten IREE-/Peano-Stack aus dem Quellcode bauen; dabei
# wird auch libxrt-dev für die nativen IRON-Hostprüfungen von --full installiert.
./scripts/build.sh

# Öffentlicher Akzeptanzvertrag: Erkennung -> CPU-Referenzen -> C/Python-Runner.
./scripts/verify-stack.sh --quick

# Optional den separat gepinnten IRON-Stack einrichten, dann alles prüfen.
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

## 🧰 Die Werkzeuge

| Skript | Was es tut |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Nur-lesend: prüft Treiber, Geräteknoten, Render-Gruppe, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Behebt die 3 Dinge, die einen Nicht-Root-Benutzer blockieren (Render-Gruppe, memlock, XRT). |
| [`scripts/detect-npu.sh`](scripts/detect-npu.sh) | Ordnet nur verifizierte VBNV/Geometrien `npu1_4col` oder `npu4` zu; Unbekanntes wird abgelehnt. |
| [`scripts/build.sh`](scripts/build.sh) | Baut den in `versions.lock` gepinnten IREE-/Peano-Stack. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Kompiliert, startet und prüft alle `i32`-/`bf16`-Ausgaben gegen die CPU. |
| [`scripts/verify-stack.sh`](scripts/verify-stack.sh) | Strikter Hardware-Akzeptanztest für CLI, nativen/Python-Runner und optionale Apps/IRON. |
| [`scripts/validate-repo.sh`](scripts/validate-repo.sh) | Hardwarefreie lokale/CI-Release-Prüfungen. |

## 🧩 Zweiter Weg: `mlir-aie` (IRON)

`iree-amd-aie` (oben) kompiliert **ganze Graphen**;
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON) ist der hardwarenähere
Weg — du **verfasst NPU-Kernels direkt** und führst sie via `pyxrt` aus, und er liefert
echte ML-`programming_examples` mit. Für **beide Generationen** gibt es Hardwarebelege,
aber nicht mit demselben Abhängigkeitsstand: Die Phoenix-/`npu1`-Ergebnisse sind historisch,
der exakte v1-Pin wurde dagegen auf Strix/`npu2` erneut verifiziert (automatisch erkannt).
Berichte mit dem aktuellen Pin auf XDNA1 sind willkommen. Das Setup nutzt das Peano von iree-amd-aie nur
dann wieder, wenn sowohl dessen exakte `llvm-aie`-Version als auch der **clang-Build-Commit**
zum Pin dieser mlir-aie-Version in `utils/peano-requirements.txt` passen; andernfalls
installiert es das gepinnte Wheel in die mlir-aie-venv. Vollständiger Leitfaden → **[docs/MLIR-AIE.de.md](docs/MLIR-AIE.de.md)**.

```bash
./scripts/setup-mlir-aie.sh                 # mlir_aie wheel + py3.14 venv + compatible Peano
./scripts/run-mlir-example.sh ml/conv2d     # build for the detected NPU + run ON IT (pyxrt)
./examples/mlir-aie/relu_add/run.sh         # a custom hand-written fused kernel
```

Verifiziert **auf der NPU** (XDNA1, `run_py` / `pyxrt`, Ausgabe gegen einen Torch-/Numpy-Goldwert):

| Beispiel | Art | NPU-Zeit |
|---|---|--:|
| `basic/passthrough_kernel` | DMA-Durchleitung | ✓ |
| `basic/vector_scalar_mul` | Vektor × Skalar | ✓ |
| `ml/conv2d` | INT8-3×3-conv | ~0,9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU fusioniert | ~0,8 ms |
| `ml/bottleneck` | ResNet-Bottleneck-Block | ~2,8 ms |
| `ml/resnet/layers_conv2_x` | ResNet-conv2_x-Schichten | ~5,1 ms |
| `ml/magika` | Googles Dateityp-Modell (bf16) | ~0,9 ms |
| [`examples/mlir-aie/relu_add`](examples/mlir-aie/relu_add/) | **eigener** fusionierter `relu(a+b)`-Kernel | ~0,37 ms |

Auf **XDNA2** (Strix Point, 8 Spalten / 32 Tiles, mlir-aie 1.4.1): Whole-Array-
GEMM erreicht **6.65 TOPS** (i8) / **4.64 TFLOPS** (bf16 via bfp16), die LLM-Blöcke
(softmax/RoPE/SwiGLU/RMSNorm) bestehen, **das vollständige `ml/mobilenet` läuft**
(~176 ms — auf den 4 Spalten von Phoenix *kann* es nicht laufen), und unser eigener
Kernel skaliert **8.0×** über die Spalten. Die XDNA2-Tabellen und die
Anleitung zum Schreiben des eigenen Kernels stehen in **[docs/MLIR-AIE.de.md](docs/MLIR-AIE.de.md)**.

## 🪤 Die Stolpersteine (warum ein naiver Build/Lauf scheitert)

Vollständige Details in **[docs/GOTCHAS.de.md](docs/GOTCHAS.de.md)**. Die Kurzliste:

1. **Verwende `gcc`, nicht `clang`, als Host-Compiler.** clang 21 *segfaultet* beim Kompilieren von MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Die Python-Bindings stoßen auf `-Werror,-Wmacro-redefined`; die CLI-Werkzeuge brauchen sie nicht.
3. **Verwende das fixierte Peano (`llvm-aie`).** `build.sh` installiert und prüft exakt den Pin aus `versions.lock`; statt still ein neueres Nightly zu wählen, bricht es ab.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** Du überspringst absichtlich 3 schwergewichtige Submodule.
5. **Kompiliere mit `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`), sonst läuft der Dispatch in ein Timeout.
6. ⚠️ **Führe mit `--amdxdna_n_core_cols=4` aus, nicht 5.** Phoenix meldet 5 Roh-Spalten, nutzt aber 4 (`npu1_4col`). Übergabe von 5 → Cores hängen → `ert state 8`-Timeout.

## 🎯 Wo kann man das tatsächlich einsetzen?

Vollständiger Leitfaden Zielgruppe für Zielgruppe (Spiele · KI-Agenten · lokale Apps) mit Machbarkeitsbewertungen → [docs/APPLICATIONS.de.md](docs/APPLICATIONS.de.md).

Siehe **[docs/USE-CASES.de.md](docs/USE-CASES.de.md)**. Ehrlich gesagt: Das ist **Kernel-Ebene**
(Matmul-/Conv-Bausteine), kein schlüsselfertiges Model-Serving. Gut zum Erlernen von NPU-
Programmierung, zum Benchmarking, zum Bauen/Auslagern spezifischer stromsparender Inferenz-
Primitive und zum Beitragen zum offenen XDNA1-auf-Linux-Vorhaben. Es wird dir **keine**
einsatzfertige LLM-/Whisper-/ONNX-Laufzeitumgebung auf XDNA1 liefern — das ist XDNA2-/Windows-Territorium.

## 📚 Hintergrund

Siehe **[docs/BACKGROUND.de.md](docs/BACKGROUND.de.md)** für XDNA1 vs. XDNA2, warum Linux für die
erste Generation schwierig ist und wie die `amdxdna`-HAL mit `/dev/accel0` kommuniziert.

## 🧭 Wo das einzuordnen ist (und was es *nicht* ist)

**Dies ist nicht das erste NPU-auf-Linux-Projekt, und es erfindet keinen Teil des Stacks** —
Treiber, Compiler und Laufzeitumgebung gehen ihm allesamt voraus und leisten die eigentliche Arbeit:

| Schicht | Vorarbeit, auf der wir aufbauen / neben der wir stehen |
|---|---|
| Kernel-Treiber | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, seit Linux 6.14 im Mainline, enumeriert XDNA1 als `/dev/accel/accel0` |
| Compiler / Laufzeitumgebung | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — vorgelagerte SDKs/Frameworks für XDNA-Generationen |
| Frühere XDNA1- + Linux-Berechnungen | ein Forschungspapier ([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — GPT-2 auf einem Phoenix 7940HS via IRON), reine Primitive-Tutorials, der [Gentoo-Wiki-XDNA-Beitrag](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| Schlüsselfertiges NPU-LLM unter Linux | FastFlowLM · Lemonade 10.x · AMD Ryzen AI SW — **alle nur XDNA2; sie schließen XDNA1 ausdrücklich aus** |

„Erste NPU unter Linux", „erster Compiler" oder „erster, der XDNA1 ausführt" wären also
allesamt übertriebene Behauptungen — und die stellen wir nicht auf.

**Was dieses Repository *ist*:** ein **paketiertes, reproduzierbares, durchgängiges
Rezept + Werkzeugset**. Es begann mit echtem Computing auf dem von Turnkey-Stacks
ausgelassenen XDNA1/Phoenix-Pfad und gibt Strix Point npu4 nun denselben öffentlichen
Korrektheitsvertrag. Die Vorarbeit ist entweder ein
vorgelagertes **SDK/Framework** (die From-Source-Stolpersteine umschiffst du selbst), eine
**nur-XDNA2**-App, ein **Forschungspapier** (kein Klick-und-los-Repository) oder ein
**nur-Windows**-Rechenpfad. Das Unterscheidende ist das *Bündel*: Diagnose→Aktivierung→Build→Lauf-Skripte,
die From-Source-**Stolperstein-Karte**, der **persistente C-API-/ctypes-Runner**
(~11× schneller als `iree-run-module` pro Aufruf), die **App-Beispiele** (Wake-Word, NPU-Kamera-Daemon),
der **ehrlich machbarkeitsbewertete Anwendungsleitfaden** (inkl. des gemessenen „NPU verliert
bei Audio gegen die CPU") und Dokumentation in 5 Sprachen.

> **Ehrlicher Vorbehalt:** Das Ökosystem ändert sich schnell, private und interne
> Arbeit bleibt unsichtbar. Bitte melde neuere Projekte oder Ergebnisse, die hier
> gewürdigt oder verglichen werden sollten; eine bessere gemeinsame Karte hilft allen.

## ⚖️ Haftungsausschluss

Community-Notizen, kein AMD-/Xilinx-Produkt. `iree-amd-aie` befindet sich in einer frühen Phase und
bewegt sich schnell; Versionen/Flags driften. Hardwarebelege sind datiert und pin-spezifisch:
Die XDNA1-/Phoenix-Ergebnisse stammen historisch vom damals aktuellen Nightly, während der
exakte v1-Pin bis zum 2026-08-15 auf Strix Point XDNA2 erneut verifiziert wurde. Für Hawk Point
liegt noch kein Ergebnis vor. XDNA1-Ergebnisse mit dem aktuellen Pin und weitere
XDNA1-/XDNA2-Ergebnisse sind mit genauer Geräteidentität und Prüfprotokoll willkommen.

## 🤝 Mitwirken

Der nützlichste Beitrag ist **ein reproduzierbares Ergebnis von deiner eigenen
XDNA1- oder XDNA2-Maschine**. Siehe **[CONTRIBUTING.md](CONTRIBUTING.md)**. Kurz gesagt:

- **Melde Hardware-Ergebnisse** — deinen Chip / Kernel / deine Distro und was funktioniert hat oder fehlschlug (Issue-Vorlage bereitgestellt).
- **Füge Benchmarks** für weitere Formen/dtypes hinzu oder **neue Ops** (conv, i8, …).
- **Behebe oder verfeinere einen [Stolperstein](docs/GOTCHAS.de.md)**, härte die Skripte ab oder füge eine Übersetzung hinzu/korrigiere sie.
- Fork → Branch → `scripts/validate-repo.sh` und, falls Hardware betroffen ist,
  `scripts/verify-stack.sh --quick` → PR mit den exakten Tests.

## 📄 Lizenz

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — nutze es, forke es, liefere es aus.

Die Skripte und Dokumente in diesem Repository stehen unter MIT. Sie bauen und steuern
Drittanbieter-Projekte unter deren eigenen Lizenzen — IREE und `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) —, die dieses Repository nicht weiterverteilt.
