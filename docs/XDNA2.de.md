**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — was sich ändert, was sich überträgt

Die XDNA1-Hardware-Evidenz dieses Repos stammt von einem Phoenix / Ryzen 7 PRO
7840U. Hawk Point teilt die zugeordnete `RyzenAI-npu1`-Identität, hat hier aber
noch kein separates Hardware-Ergebnis. Für diesen dokumentierten XDNA1-Pfad ist
das aus dem Quellcode gebaute `iree-amd-aie` der unter Linux verwendete
Compute-Weg. Diese Seite ist das ehrliche **XDNA2**-Delta
(Strix Point / Strix Halo / Krackan): was von den Rezepten und Werkzeugen dieses Repos
sich überträgt, was die zweite Generation ändert und wo die offene Grenze jetzt liegt.

Der Zweck ist in jeder Generation derselbe: Eine NPU, die bereits in einem
privaten Rechner steckt, soll zu einsehbarer und wiederverwendbarer Linux-
Infrastruktur werden. Die Mission steht im [Open NPU Lab](OPEN-NPU-LAB.md),
Primärquellen über diese Seite hinaus in den [Research branches](RESEARCH.md).

Unten stehen zwei Arten von Aussagen, klar getrennt:

- **✅ Verifiziert** — reproduziert auf einer echten XDNA2-Maschine:
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · Kernel 7.0
  · In-Tree-`amdxdna` · NPU FW 1.1.2.64**.
- **🔎 Recherchiert** — bezogen aus Upstream-Repos/-Docs/-Benchmarks (August 2026),
  inline verlinkt, hier noch nicht reproduziert.

Dieses Repository hat die Systemenergie auf seiner Strix-Maschine nicht
gemessen. Jede Energiezahl unten ist ausdrücklich Upstream zugeordnet und keine
Repo-Evidenz.

> **Die ausführbare Unterstützung dieses Releases ist enger als der Familienüberblick:**
> Nur Strix Point `RyzenAI-npu4` / IREE `npu4` ist auf Hardware verifiziert und
> wird automatisch zugeordnet. Strix Halo `npu5` und Krackan `npu6` dienen nur
> als Kontext; `scripts/detect-npu.sh` lehnt sie ohne verifiziertes Target und
> CPU-Referenzergebnis ab. Siehe [SUPPORT.md](SUPPORT.md).

## TL;DR

| | XDNA1 (das Heimrevier dieses Repos) | XDNA2 |
|---|---|---|
| Schlüsselfertiges LLM unter Linux | Dieses Repo liefert keinen Server; offene niedrigere IREE-/IRON-Forschungspfade bleiben | ✅ FastFlowLM + Lemonade |
| XRT-Userspace | Bauen/Installieren nach diesem Repo | ✅ **von Ubuntu 26.04 nativ ausgeliefert** (`libxrt-npu2`) |
| Eigene Kernels (offener Weg) | Repo-gepinntes `iree-amd-aie` plus `mlir-aie`; bewegliches `amd/IRON` ist ein separater Upstream-Pfad | dieselben öffentlichen Grundlagen, mit Strix als First-Class-Target `npu2`/`npu4` |
| Wo Beiträge liegen | nützliche Phoenix-Blöcke reproduzieren und zusammensetzen | offene, quantisierte, fusionierte Kernels und Anwendungsintegration |

Alles, was dieses Repo lehrt — XRT-Plumbing, memlock-/render-Gruppen-Aktivierung,
Dispatch-Overhead, Peano, IRON-Kernel-Authoring — **überträgt sich**. Was sich ändert,
sind Target-Namen, die Array-Geometrie und die Tatsache, dass „ein LLM auf der NPU
ausführen" auf XDNA2 nicht mehr die Grenze ist; **offene, quantisierte, getunte Kernels sind es**.

## ✅ Verifiziert: eine Strix-Point-Maschine heute, mit den eigenen Werkzeugen dieses Repos

Das unveränderte `scripts/check-npu.sh` auf der XDNA2-Maschine auszuführen förderte drei
Skript-Bugs zutage (alle in diesem Commit behoben — siehe unten) und diesen tatsächlichen Zustand:

```
[1] amdxdna module loaded                       ✓
[2] 1022:17f0 Strix/Krackan/Strix Halo NPU      ✓  (XDNA2)
[3] /dev/accel/accel0 root:render 0660, RW      ✓
[4] user in 'render' group                      ✓
[5] memlock = 8192 KB                            ✗  ← the same old blocker
[6] xrt-smi present (2.21.75) but:               ✗
    mmap(len=64MB, MAP_LOCKED) failed (err=-11)
[7] pyxrt present, cannot open device            ✗  (same cause)
```

Drei Erkenntnisse, die sich festzuhalten lohnen:

1. **Ubuntu 26.04 liefert den XDNA2-XRT-Userspace nativ aus.** `libxrt2`,
   `libxrt-npu2`, `libxrt-utils-npu`, `python3-xrt` (2.21.75) installieren sich direkt
   aus dem Archiv — auf XDNA1 existieren dieselben Pakete, aber keine ausgelieferte
   Laufzeitumgebung führt Modelle aus; auf XDNA2 ist das ein funktionierender Runtime-Pfad.
2. **Die Aktivierungsblocker sind Byte für Byte identisch mit XDNA1** — der 8-MB-
   memlock-Default bricht xrt-smis 64-MB-`mmap(MAP_LOCKED)` mit `EAGAIN`,
   genau das Fehlschlagen, für das `scripts/enable-npu.sh` geschrieben wurde — **aber
   der alte Fix greift auf einem systemd-Desktop stillschweigend nicht.** limits.d ist ein
   `pam_limits`-Mechanismus; ein GUI-Terminal ist ein Kind von `user@<uid>.service`
   und erbt stattdessen *dessen* 8 MB `LimitMEMLOCK`, und mit aktiviertem Lingering
   startet selbst ein Neu-Login diesen Service nie neu. `enable-npu.sh` schreibt jetzt
   ein UID-spezifisches `user@<uid>.service.d`-Drop-in, deaktiviert nur das exakt
   von einer älteren Version verwaltete Wildcard-Drop-in und wendet `prlimit` auf
   die aufrufende Shell an — die vollständige Anatomie steht in
   [GOTCHAS #0](GOTCHAS.de.md).
3. **Die Firmware ist ab Werk aktuell**: FW 1.1.2.64 geladen aus
   `amdnpu/17f0_10/` — oberhalb der Untergrenze von ≥ 1.1.0.0, die FastFlowLM verlangt.

### ✅ Endzustand: die XDNA2-NPU enumeriert (dieselbe Maschine, derselbe Tag)

Nachdem der memlock-Fix wirklich gelandet war (Drop-in + `prlimit`, Stolperstein #0),
werden alle sieben Prüfungen grün und der Userspace-Stack öffnet das Gerät:

```
$ xrt-smi examine
XRT
  Version              : 2.21.75
  amdxdna Version      : 7.0.0-29-generic
  NPU Firmware Version : 1.1.2.64
Device(s) Present
|BDF             |Name          |
|[0000:66:00.1]  |RyzenAI-npu4  |

$ python3 -c 'import pyxrt; d = pyxrt.device(0); \
    print(d.get_info(pyxrt.xrt_info_device.name))'
RyzenAI-npu4
```

`RyzenAI-npu4` bestätigt die Namens-Decoder-Zeile unten auf echter Hardware: Strix
Point ist für XRT `npu4`. Um bis *hierher* zu kommen, war kein Source-Build nötig —
Aktivierung auf XDNA2/Ubuntu 26.04 ist Konfiguration, keine Kompilierung.

## ✅ Compute: verifiziert auf der XDNA2-NPU (dieselbe Maschine, 2026-08-15)

**Live-Aufzeichnung auf echter Hardware:** exakte CPU-Referenzprüfungen mit IREE
`npu4`, vollständige `npu-runner`-Ausgabeprüfung und der 8-Spalten-IRON-Kernel
mit XRT und HRX:

![Live-Verifikation von XDNA2-Strix-Point-Compute mit IREE, npu-runner, XRT und HRX](media/xdna2-compute.gif)

Der repo-gepinnte Direct-Kernel-Pfad lief noch am selben Tag, an dem die Aktivierung landete —
`setup-mlir-aie.sh` unverändert, mlir-aie **1.4.1** (cp314-Wheel), Peano-Wheel,
Ubuntus `pyxrt`. Vollständige Tabellen in [MLIR-AIE.de.md](MLIR-AIE.de.md); die
Schlagzeilen:

- **GEMM auf allen 8 Spalten / 32 Tiles** (`whole_array`, 2048³): **6.65 TOPS**
  i8 und **4.64 TFLOPS** bf16-via-bfp16 — die innere Tile-Größe allein war
  3.4× wert (32³ → 64³-Tiles).
- **AIE2P will bfp16**: bf16-MAC ist auf XDNA2 ~¼-Rate-*Emulation* (auf
  XDNA1 nativ); `--emulate-bf16-mmul-with-bfp16 1` ist Gratis-Tempo. Die
  nativen bfp16ebs8-Entwürfe kompilieren hier mit Peano; sie auszuführen
  braucht `libxrt-dev` (C++-Hosts).
- **`ml/mobilenet` — der Entwurf, der auf den 4 Spalten von Phoenix an
  `CREATE_HWCTX` scheitert — läuft durchgängig** auf dem 8-Spalten-Array:
  ~176 ms/Inferenz.
- Im repo-gepinnten **mlir-aie-1.4.1**-Pfad bestanden einzelne `npu2`-Beispiele
  für Softmax, RoPE, SwiGLU, RMSNorm und Matmul+Aktivierungs-Epiloge. Das ist
  Repo-eigene Strix-Evidenz für diese Beispiele, kein Gesamtmodell-Ergebnis und
  nicht das separate, bewegliche `amd/IRON`-Operator-Dashboard.
- Unser eigener `relu(a+b)`-Kernel, auf die IRON-API von mlir-aie 1.4.1 portiert, skaliert
  **8.0× auf 8 Spalten** (`transform_parallel_binary`), 11.2 GB/s effektiv.

### ✅ IREE: Korrektheit gegen CPU-Referenz auf `npu4` (separater Track)

Der Upstream-IREE-CPU-vs-NPU-Harness lief ebenfalls auf dieser Hardware, mit
`--target_device=npu4`, 4 Core-Zeilen, 8 Core-Spalten und Peano 22, Commit
`4a1adefa`:

| IREE-Matmul | Verglichene Werte | Ergebnis CPU gegen NPU |
|---|---:|---|
| bf16→f32, 64³ | 4.096 | exakt gleich; maximaler absoluter/relativer Fehler 0 |
| bf16→f32, 512³ | 262.144 | exakt gleich; maximaler absoluter/relativer Fehler 0 |
| i8→i32, 512³ | 262.144 | 0 Abweichungen |

Dies sind Korrektheitsergebnisse für bf16/i8 mit `iree-amd-aie`, nicht der
native bfp16ebs8-Pfad von `mlir-aie`. Dessen separater Peano-21-Akkumulations-
Sweep bestand bei K=1216 und scheiterte erstmals bei K=1280; diese IREE-Tabelle
ändert jene Grenze nicht. Diese Korrektheitsläufe sind außerdem **keine
Leistungsmessungen**.

### Skript-Bugs, gefunden beim Richten der XDNA1-Werkzeuge auf XDNA2 (behoben)

- `check-npu.sh [1]` nutzte `lsmod | grep -q` unter `pipefail`: `grep -q` beendet sich
  beim ersten Treffer, `lsmod` stirbt an SIGPIPE (Exit 141), die Pipeline „schlägt fehl" — ein
  racebehaftetes falsches Negativ, das nur zündet, wenn das Modul früh in der `lsmod`-Ausgabe steht
  (was es auf einer frisch gebooteten Strix-Maschine tut). Prüft jetzt `/sys/module/amdxdna`.
- `check-npu.sh [2]` matchte `IPU|AI`, den XDNA1-lspci-String. XDNA2 enumeriert
  als `Neural Processing Unit` (Gerät `17f0`). Die Prüfung matcht jetzt beide und
  meldet, welche Generation sie gefunden hat.
- `check-npu.sh [6]` hatte *dieselbe* SIGPIPE-Race wie [1] — `xrt-smi examine |
  grep -q` unter `pipefail` — aber diese wird erst scharf, **sobald die NPU
  tatsächlich enumeriert** (die gematchten Zeilen stehen früh in einem erfolgreichen
  Bericht, also steigt `grep -q` aus, während `xrt-smi` noch schreibt). Die Prüfung
  meldete die allererste erfolgreiche Enumeration als Fehlschlag, während `pyxrt`
  in [7] das Gerät fröhlich öffnete. Fängt jetzt erst die Ausgabe ein und matcht dann.

## 🔎 Der Namens-Decoder (die generationsübergreifende Verwirrung Nr. 1)

| Ebene | XDNA1 | XDNA2 Strix Point | Quelle |
|---|---|---|---|
| lspci | `AMD IPU Device` (`1502`) | `Neural Processing Unit` (`17f0`) | ✅ beide Maschinen |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4` (Halo=`npu5`, Krackan=`npu6`) | ✅ diese Maschine meldet `RyzenAI-npu4` · [xdna-driver](https://github.com/amd/xdna-driver) |
| mlir-aie / IRON | `npu1` | `npu2` | [mlir-aie](https://xilinx.github.io/mlir-aie/) |
| iree-amd-aie | `npu1_4col` | `npu4` | [iree-amd-aie](https://github.com/nod-ai/iree-amd-aie) |
| ISA | AIE2 | AIE2P | [Peano](https://github.com/Xilinx/llvm-aie) |

## 🔎 Die gedrehte Landschaft: schlüsselfertig existiert auf XDNA2 — mit einem Haken

- **FastFlowLM** lieferte native Linux-Unterstützung in v0.9.35 aus (2026-03-11),
  **nur für XDNA2** — XDNA1 bleibt aus diesem Produkt ausgeschlossen. Dieses
  Repo behält deshalb seinen From-Source-Compilerpfad; daneben bietet die
  separate, bewegliche AMD-IRON-Bibliothek eine weitere offene Phoenix-
  Forschungsfläche. FLM v1.0.0 zog in AMDs
  [ROCm-GitHub-Org](https://github.com/ROCm/FastFlowLM) um (2026-08).
  **Lemonade** verpackt es als OpenAI-kompatiblen Server
  ([Linux-Guide](https://lemonade-server.ai/flm_npu_linux.html)).
- **Der Haken:** FLMs CLI ist MIT, aber seine **NPU-Kernels sind proprietäre,
  frei nutzbare Binaries**. Es ist ein Produkt zum Benutzen, keine Codebasis, um daraus
  Kernel-Authoring zu lernen. Der Open-Kernel-Weg — das Revier dieses Repos — ist
  der Ort, an dem XDNA2-Beiträge jetzt liegen.
- **Unter Linux fehlt weiterhin**, unabhängig von der Generation: der Vitis AI EP der ONNX Runtime
  ([Docs](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html))
  — daher behält der Screen-the-Graph-Ansatz von `npu-trim` seine Nische auch auf XDNA2.
  GAIA unter Linux treibt nur die iGPU an
  ([amd/gaia#1220](https://github.com/amd/gaia/issues/1220) fragt nach der NPU-Route).

## Asset für Asset: was von diesem Repo auf XDNA2 portiert

| Asset | XDNA2-Status | Was sich ändert |
|---|---|---|
| `scripts/check-npu.sh` | ✅ funktioniert (dieser Commit) | XDNA2-PCI-String + Generationsbericht; [6] SIGPIPE-Fix auf der Erfolgsseite; [5] diagnostiziert jetzt die pam-vs-systemd-Spaltung beim memlock |
| `scripts/enable-npu.sh` | ✅ funktioniert (in diesem Commit erweitert) | dieselben 3 Blocker; Ubuntu 26.04 installiert die Pakete vor — aber auf einem systemd-Desktop braucht der memlock-Fix zusätzlich zu limits.d ein UID-spezifisches `user@<uid>.service.d`-Drop-in; das Skript deaktiviert nur seine exakte alte Wildcard-Datei ([Stolperstein #0](GOTCHAS.de.md)) |
| `scripts/build.sh` (iree-amd-aie) | ✅ auf Hardware verifiziert | Source-Build + Installation auf Strix abgeschlossen; begrenzte Parallelität verhindert den beobachteten OOM, die Abschlussprüfung verlangt sowohl `npu1_4col` als auch `npu4`; getestet mit Peano 22 `4a1adefa` |
| `scripts/run-matmul.sh` | ✅ auf Hardware verifiziert | erkennt das 4×8-Grid und wählt `npu4`; i32 128³ und bf16 512³ kompilieren und laufen korrekt, der XDNA1-Pfad bleibt erhalten |
| `tools/npu-runner` | ✅ auf Hardware verifiziert | C-API-Grid-Autoerkennung löst 4×8 auf; nativer Runner und ctypes/Python-Pfad verifizierten alle 16.384 i32-Ausgabewerte |
| [`examples/local-rag-sidecar`](../examples/local-rag-sidecar/) | ✅ hardwareverifizierte Integration auf `npu4` | Deterministisches CPU-Hashing → persistentes NPU-bf16-Scoring → CPU-Top-k, mit Prüfung aller 65.536 Ausgaben. Eine Integrationsreferenz, kein trainierter Retriever; eine kleine Einzelanfrage ist wahrscheinlich auf der CPU schneller. |
| `tools/npu-trim` | ✅ Konzept intakt | `build.sh` installiert das separat gepinnte `iree-import-onnx`; das Werkzeug extrahiert unabhängige Matmul-/Conv-Formen und testkompiliert sie. Es baut kein Gesamtmodell: Gewichte, Layouts, nicht unterstützter Glue, Fallback und Orchestrierung gehören der Anwendung. |
| Repo-gepinnter `mlir-aie`-Pfad | ✅ **auf Strix hardwareverifiziert** | [`mlir-aie` 1.4.1](https://github.com/Xilinx/mlir-aie/releases) behandelt Strix als `npu2`, nutzt Peano standardmäßig und stellt den in [MLIR-AIE.de.md](MLIR-AIE.de.md) gemessenen Direct-Kernel-Pfad bereit. Das optionale HRX-Python-Backend benötigt eine externe `libhrx`; Repo-Artefakte nutzten weiterhin XRT, also ist dies keine vollständig XRT-freie Aussage. |
| Bewegliche `amd/IRON`-Operatorbibliothek | 🔎 **separate Upstream-Hardwareevidenz** | Am exakten `cdc48e93` melden die standardmäßigen fünf Iterationen des Phoenix-Workflows vom 2026-08-15 **2.105 bestandene / 45 übersprungene Fallläufe**, entsprechend **421 verschiedenen bestandenen Konfigurationen / 9 verschiedenen Skips**.[^iron-phoenix] Diesen beweglichen Quellbaum und seine Phoenix-CI nicht mit dem repo-gepinnten 1.4.1-Strix-Ergebnis vermischen. |

## 🔎 Das Hardware-Delta, das zählt, wenn du Kernels schreibst

- **Geometrie**: npu1 ist ein Array mit 4 Spalten; Strix Point (`npu4`) ist **4 Zeilen × 8
  Spalten — 32 Compute-Tiles + 8 Memory-Tiles**, partitionierbar an Spaltengrenzen,
  mit firmware-verwaltetem Kontext-Scheduling
  ([Kernel-Docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **Datentyp**: AIE2Ps Schlagzeile ist **bfp16 Block Floating Point** — 8 Werte
  teilen sich einen 8-Bit-Exponenten, 9 Bytes pro 8 Werte. Mit Peanos aktuellen
  Nightlies ist das unter dem offenen Stack real: clang liefert die
  `__builtin_aie2p_*bfp16ebs8/16`-Konvertierungs- und `BFP576_BFP576_ACC2048`-
  MAC-Builtins mit, und die `ml/block_datatypes`-GEMMs bauen mit Peano (✅
  auf dieser Maschine kompiliert). Die Kehrseite: **bf16-MAC hat sich
  verschlechtert** — natives 4×8×4 auf AIE2, ~¼-Rate-Emulation durch den
  bfp16-Datenpfad auf AIE2P
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390),
  [Hello XDNA](https://tnzr.org/xdna/isa.html)). Für bf16 auf npu1 getunte
  Kernels brauchen für Spitzendurchsatz auf npu2 eine bfp16-Neufassung; das
  Kernel-C++ ist per `__AIEARCH__` arch-gegated (20 = AIE2, 21 = AIE2P), und
  Upstream pflegt parallele `aie_kernels/aie2/`- und `aie2p/`-Bäume.
- **ISA**: weiterhin kein offizielles Handbuch, aber faktisch offen — Peano implementiert sie
  in öffentlichem LLVM, und [Hello XDNA](https://tnzr.org/xdna/isa.html) rekonstruiert
  die XDNA1/XDNA2-ISA mit Latenzen pro Instruktion.

## 🔎 Gemessene Realität: LLMs auf der XDNA2-NPU (warum Kernels die Grenze sind)

- FLM auf einem 50-TOPS-XDNA2: Llama 3.1 8B **Prefill 403 t/s** @1k ctx, Decode
  12.8 t/s; gpt-oss-20b Decode 18.2 @1k → 12.0 @32k
  ([FLM-Benchmarks](https://fastflowlm.com/docs/benchmarks/llama3_results/)).
- Vergleich auf demselben Silizium: die NPU gewinnt **Prefill ~1.5×** gegen iGPU-Vulkan, verliert
  Decode ~25%, bei bis zu ~10× besserer Energieeffizienz. Decode ist
  Speicherbandbreiten-Physik (~120 GB/s LPDDR5X, geteilt von CPU/iGPU/NPU) — keine
  Engine entkommt ihr.
- Kalibrierungspunkt für offenen Code: ein naiver offener XRT-Dispatch-llama.cpp-Fork
  ([OllamaAMDNPU](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU),
  Strix Halo) erreicht Prefill 18.4 t/s, Decode 1.4 t/s — die Lücke zu FLMs
  300–400 t/s Prefill ist **Kernel-/Dataflow-Design, kein Dispatch-Plumbing**.
- Die Architektur, die Sinn ergibt: **hybrides NPU-Prefill + iGPU-Decode** —
  genau so teilt AMDs eigener Windows-Stack die Arbeit auf.

### Forschungsbrücke zwischen den Generationen

Offene Arbeit reicht bereits über die repo-gepinnten Beispiele hinaus, doch die
Baselines müssen getrennt bleiben. Das Phoenix-Experiment von Rösti und Franz
lagert GEMMs des GPT-2-124M-Fine-Tunings auf eine NPU der ersten Generation aus
und veröffentlicht seine Hybrid-Durchsatz- und Energiewerte.[^phoenix-gpt2]
STEEL berichtet im Mittel **9,6× XDNA1-Latenz gegenüber DATO**; seine CPU-/GPU-
Energiewerte stammen aus einem separaten HX-370/**XDNA2**-Experiment, nicht aus
dieser XDNA1-Portierung.[^steel] Dies sind publizierte Ergebnisse zum
Reproduzieren und Erweitern, keine Benchmarks dieses Repos.

## Wohin es als Nächstes geht

1. ~~Direktes `mlir-aie`-GEMM auf dem 4×8-Array reproduzieren~~ — **✅ erledigt**
   mit repo-gepinntem mlir-aie 1.4.1:
   Whole-Array-GEMM mit 6.65 TOPS i8 / 4.64 TFLOPS bf16-bfp16, LLM-Blöcke,
   vollständiges MobileNet; siehe [MLIR-AIE.de.md](MLIR-AIE.de.md). Separat hat
   der exakte `amd/IRON`-Commit `cdc48e93` einen Phoenix-Hardwareworkflow,
   dessen standardmäßige fünf Iterationen **2.105 bestandene / 45 übersprungene
   Fallläufe** ergeben: **421 verschiedene bestandene Konfigurationen / 9
   verschiedene Skips**. Bestandene Fälle umfassen bf16 GEMM/GEMV,
   Q4NX-Dequant, Softmax, RoPE, RMSNorm, LayerNorm, Aktivierungen, Transpose und
   SwiGLU Decode/Prefill. Die verschiedenen Skips sind genau 3 MHA-, 3
   streaming-SwiGLU-prefill- und 3 GEMV+GELU-Konfigurationen; jede wird fünfmal
   wiederholt und bildet so drei Gruppen zu 15 Fallläufen. Das
   MHA/GQA-Dashboard ist **AIE2P-only**.[^iron-phoenix]
   Das erweitert die Experimente, die zu XDNA1 zurückgebracht werden können;
   es ist kein Current-Pin-Phoenix-Lauf dieses Repos und kein volles LLM.
2. ~~Die iree-amd-aie-Matmul-Rezepte + `npu-runner` auf `npu4` portieren und
   die Korrektheit gegen die CPU-Referenz abschließen~~ — **✅ erledigt**. Build,
   generationserkennendes Matmul-Skript, persistenter C-API-Runner und Python-
   Wrapper liefen alle auf dieser Strix-Maschine; der Upstream-Harness lieferte
   die obige Exact-Match-Tabelle. Ein kontrollierter XDNA1-vs-XDNA2-
   Leistungsvergleich bleibt separate Arbeit; aus diesen Korrektheitsläufen
   wird keine Geschwindigkeitsaussage abgeleitet.
3. **Quantisiertes Prefill-GEMM** — die Beitragsfläche, jetzt präzise kartiert.
   **TileFuse ist externe XDNA2-Forschung**, kein Runtime-Ergebnis dieses Repos:
   Das Paper veröffentlicht ein W4A16-Rezept und externen Code
   ([glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
   Fork ~13 Monate hinter main, **chess-first** mit Peano optional; AWQ
   group-128, k-Tile = Gruppengröße, dequant in-tile fusioniert mit einem
   Weight-stationary-L1-Cache, 9 TOPS auf Strix Point). In den am **2026-08-15**
   zitierten und geprüften Quellen fanden wir weder eine öffentliche Portierung
   dieses TileFuse-Kernels auf **repo-gepinntes mlir-aie 1.4.1 + nur Peano**
   noch eine öffentliche TileFuse-Integration für llama.cpp. Das ist ein
   datierter Suchstand und **kein Beweis der Abwesenheit**.
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725)
   ist weiterhin offen und unbeansprucht (das WIP des Autors stockte 2026-04;
   AMDs eigener aktiver Versuch ist [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend)
   auf der HSA-/ROCr-Runtime — ein anderer Stack als Ubuntus XRT).
   **64-KiB-Puffer-Alignment bleibt eine Benchmark-Hypothese, die einen Test
   wert ist.** Das verlinkte llama.cpp-Ticket #21725 enthält kein stützendes
   Primärexperiment und kein Rohlog; dieses Repository erhebt daher **keinen
   10×-Decode-Anspruch**.
   **Repo-Status: nur kompiliert (2026-08-15):** TileFuses fusionierter
   Dequant+GEMM-Kernel (`mix_int4_ATB.cc`) **kompiliert sauber mit Peano für
   `aie2p` gegen die mlir-aie-1.4.1-Header** (`-Dbf16_bf16_ONLY`,
   m64/k128/n64 → `matmul_bf16_bf16`). Damit ist für diese Spezialisierung
   eine Frontend-Compile-Hürde genommen; die Portierung ist damit **nicht**
   fertig. IRON/ObjectFifo-Integration, Linken, Platzierung, ABI-Abgleich,
   hostseitiges Weight-Packing, NPU-Ausführung und numerische Verifikation
   stehen noch aus. Das gepinnte
   [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) hält
   den externen Quell-Commit, Prüfsummen und die exakten Frontend-Flags fest.
   Es gibt kein W4A16-Hardware-, Korrektheits-, Durchsatz- oder Energieergebnis
   dieses Repos.

*Status: Seite hinzugefügt am 2026-08-15; Aktivierung, Direct-Kernel-Compute und die
IREE-`npu4`-Portierung samt Korrektheit gegen die CPU-Referenz wurden am selben
Tag auf der obigen Strix-Point-Maschine verifiziert. Die 🔎-Punkte tragen ihre
Quellen inline.*

[^iron-phoenix]: AMD, [`IRON` am Commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) und [Phoenix-Extensive-Hardwareworkflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15. Bei den standardmäßigen fünf Iterationen entsprechen 2.105 bestandene und 45 übersprungene Fallläufe 421 verschiedenen bestandenen Konfigurationen und 9 verschiedenen Skips. Upstream-Evidenz, kein Exact-v1-XDNA1-Lauf dieses Repos.
[^phoenix-gpt2]: A. Rösti und M. Franz, [„Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools“](https://arxiv.org/abs/2504.03083), FCCM 2025. Phoenix der ersten Generation, hybrides GPT-2-124M-Fine-Tuning; hier nicht reproduziert.
[^steel]: V. J. B. Jung et al., [„STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU“](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. XDNA1-Latenz- und XDNA2-Energieexperimente getrennt halten.
