**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Echte Berechnungen auf einer Ryzen AI **XDNA1** NPU unter **Linux** ausführen

Ein reproduzierbares, durchgängiges Rezept — samt Werkzeugen —, um eine AMD Ryzen AI
NPU der **ersten Generation (XDNA1 / „Phoenix")** von *treibersichtbar-aber-untätig* zu
**tatsächlich Matmuls ausführend** unter Linux zu bringen, indem
[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) aus dem Quellcode gebaut wird.

> **Warum dieses Repository existiert.** Fast jeder Artikel von 2026 nach dem Motto „die Ryzen AI NPU
> funktioniert endlich unter Linux" handelt von **XDNA2** (Strix/Krackan). Die
> **XDNA1**-Chips der ersten Generation in Ryzen-7040/8040-Laptops (z. B. dem 7840U) werden von
> den schlüsselfertigen Stacks *ausdrücklich ausgeschlossen* — AMDs Ryzen AI Software für Linux, der Vitis AI
> EP der ONNX Runtime, Lemonade/FastFlowLM. Unter XDNA1+Linux wird die NPU vom
> In-Tree-Treiber `amdxdna` eingeschaltet und enumeriert, aber **keine ausgelieferte Laufzeitumgebung wird ein Modell darauf
> ausführen.** Der eine offene Weg, der *tatsächlich* auf XDNA1 abzielt, ist `iree-amd-aie` — aus dem
> Quellcode gebaut. Dieses Repository ist die verifizierte, Stolperstein-für-Stolperstein-Karte dieses Weges.

## ✅ Was funktioniert (verifiziert)

Kompiliert und **auf der NPU** ausgeführt (`--device=amdxdna`), korrekte Ergebnisse,
wiederholbar:

| Workload | Form | Ergebnis | Durchsatz (NPU) |
|---|---|---|---|
| `i32`-Matmul | 128×128×128 | ✓ exakt | ~3,6 ms/Iter., ~280/s |
| `bf16 → f32`-Matmul | 256×256×256 | ✓ exakt (inkl. Nachkommastellen) | ~2,9 ms/Iter., ~350/s |

Getestete Maschine: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · Kernel 7.0 · In-Tree-`amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**.

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

## 🧰 Die Werkzeuge

| Skript | Was es tut |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Nur-lesend: prüft Treiber, Geräteknoten, Render-Gruppe, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Behebt die 3 Dinge, die einen Nicht-Root-Benutzer blockieren (Render-Gruppe, memlock, XRT). |
| [`scripts/build.sh`](scripts/build.sh) | Klont + baut `iree-amd-aie` mit allen angewendeten Workarounds. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Kompiliert + führt einen `i32`-/`bf16`-Matmul auf der NPU aus. Das Rezept. |

## 🪤 Die Stolpersteine (warum ein naiver Build/Lauf scheitert)

Vollständige Details in **[docs/GOTCHAS.de.md](docs/GOTCHAS.de.md)**. Die Kurzliste:

1. **Verwende `gcc`, nicht `clang`, als Host-Compiler.** clang 21 *segfaultet* beim Kompilieren von MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Die Python-Bindings stoßen auf `-Werror,-Wmacro-redefined`; die CLI-Werkzeuge brauchen sie nicht.
3. **Hebe den Peano-(`llvm-aie`-)Pin an.** Das im Repository gepinnte Nightly ist aus dem Index abgelaufen; `build.sh` wählt automatisch das neueste aus.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** Du überspringst absichtlich 3 schwergewichtige Submodule.
5. **Kompiliere mit `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`), sonst läuft der Dispatch in ein Timeout.
6. ⚠️ **Führe mit `--amdxdna_n_core_cols=4` aus, nicht 5.** Phoenix meldet 5 Roh-Spalten, nutzt aber 4 (`npu1_4col`). Übergabe von 5 → Cores hängen → `ert state 8`-Timeout.

## 🎯 Wo kann man das tatsächlich einsetzen?

Siehe **[docs/USE-CASES.de.md](docs/USE-CASES.de.md)**. Ehrlich gesagt: Das ist **Kernel-Ebene**
(Matmul-/Conv-Bausteine), kein schlüsselfertiges Model-Serving. Gut zum Erlernen von NPU-
Programmierung, zum Benchmarking, zum Bauen/Auslagern spezifischer stromsparender Inferenz-
Primitive und zum Beitragen zum offenen XDNA1-auf-Linux-Vorhaben. Es wird dir **keine**
einsatzfertige LLM-/Whisper-/ONNX-Laufzeitumgebung auf XDNA1 liefern — das ist XDNA2-/Windows-Territorium.

## 📚 Hintergrund

Siehe **[docs/BACKGROUND.de.md](docs/BACKGROUND.de.md)** für XDNA1 vs. XDNA2, warum Linux für die
erste Generation schwierig ist und wie die `amdxdna`-HAL mit `/dev/accel0` kommuniziert.

## ⚖️ Haftungsausschluss

Community-Notizen, kein AMD-/Xilinx-Produkt. `iree-amd-aie` befindet sich in einer frühen Phase und
bewegt sich schnell; Versionen/Flags driften. Alles hier wurde auf der exakten
Maschine oben am 2026-06-22 verifiziert. Issues/PRs mit Ergebnissen von anderen XDNA1-Laptops sind willkommen.

## 🤝 Mitwirken

Der nützlichste Beitrag ist **ein Ergebnis von deiner eigenen XDNA1-Maschine** — die
Abdeckung von Ryzen AI der ersten Generation unter Linux ist dünn. Siehe **[CONTRIBUTING.md](CONTRIBUTING.md)**. Kurz gesagt:

- **Melde Hardware-Ergebnisse** — deinen Chip / Kernel / deine Distro und was funktioniert hat oder fehlschlug (Issue-Vorlage bereitgestellt).
- **Füge Benchmarks** für weitere Formen/dtypes hinzu oder **neue Ops** (conv, i8, …).
- **Behebe oder verfeinere einen [Stolperstein](docs/GOTCHAS.de.md)**, härte die Skripte ab oder füge eine Übersetzung hinzu/korrigiere sie.
- Fork → branch → test mit `scripts/run-matmul.sh` → PR, der beschreibt, worauf du es ausgeführt hast.

## 📄 Lizenz

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — nutze es, forke es, liefere es aus.

Die Skripte und Dokumente in diesem Repository stehen unter MIT. Sie bauen und steuern
Drittanbieter-Projekte unter deren eigenen Lizenzen — IREE und `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) —, die dieses Repository nicht weiterverteilt.
