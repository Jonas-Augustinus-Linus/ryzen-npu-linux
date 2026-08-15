**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — was sich ändert, was sich überträgt

Dieses Repo ist die verifizierte Karte für **XDNA1** (Phoenix/Hawk Point), wo aus dem
Quellcode gebautes `iree-amd-aie` nach wie vor der *einzige* Weg ist, Berechnungen auf der
NPU unter Linux auszuführen. Diese Seite ist das ehrliche **XDNA2**-Delta
(Strix Point / Strix Halo / Krackan): was von den Rezepten und Werkzeugen dieses Repos
sich überträgt, was die zweite Generation ändert und wo die offene Grenze jetzt liegt.

Unten stehen zwei Arten von Aussagen, klar getrennt:

- **✅ Verifiziert** — reproduziert auf einer echten XDNA2-Maschine:
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · Kernel 7.0
  · In-Tree-`amdxdna` · NPU FW 1.1.2.64**.
- **🔎 Recherchiert** — bezogen aus Upstream-Repos/-Docs/-Benchmarks (August 2026),
  inline verlinkt, hier noch nicht reproduziert.

## TL;DR

| | XDNA1 (das Heimrevier dieses Repos) | XDNA2 |
|---|---|---|
| Schlüsselfertiges LLM unter Linux | ❌ keines — von jedem ausgelieferten Stack ausgeschlossen | ✅ FastFlowLM + Lemonade 10.0 (seit 2026-03) |
| XRT-Userspace | Bauen/Installieren nach diesem Repo | ✅ **von Ubuntu 26.04 nativ ausgeliefert** (`libxrt-npu2`) |
| Eigene Kernels (offener Weg) | `iree-amd-aie` / `mlir-aie` aus dem Quellcode | derselbe Stack, besser unterstützt: IRON 1.4.x behandelt Strix als First-Class |
| Wo Beiträge liegen | *überhaupt etwas* zum Laufen bringen | die Open-Kernel-Lücke schließen (die schlüsselfertigen NPU-Kernels sind proprietär) |

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
   zusätzlich ein `user@.service`-Drop-in und wendet `prlimit` auf die aufrufende
   Shell an — die vollständige Anatomie steht in [GOTCHAS #0](GOTCHAS.de.md).
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
Aktivierung auf XDNA2/Ubuntu 26.04 ist Konfiguration, keine Kompilierung. Compute ist
der nächste Schritt (siehe *Wohin es als Nächstes geht*).

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
  **nur für XDNA2** — XDNA1 bleibt ausgeschlossen, weshalb der From-Source-Weg
  dieses Repos die einzige XDNA1-Route bleibt. FLM v1.0.0 zog in AMDs
  [ROCm-GitHub-Org](https://github.com/ROCm/FastFlowLM) um (2026-08).
  **Lemonade 10.0** verpackt es als OpenAI-kompatiblen Server
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
| `scripts/enable-npu.sh` | ✅ funktioniert (in diesem Commit erweitert) | dieselben 3 Blocker; Ubuntu 26.04 installiert die Pakete vor — aber auf einem systemd-Desktop braucht der memlock-Fix ein `user@.service`-Drop-in zusätzlich zu limits.d ([Stolperstein #0](GOTCHAS.de.md)) |
| `scripts/build.sh` (iree-amd-aie) | 🔎 sollte portieren | `npu4` ist ein unterstütztes Target; Projekt aktiv (softmax-ukernel für Peano npu4, ERT_CMD_CHAIN-Batching). Der Commit-Lockstep-Stolperstein (fixierter xdna-driver) bleibt |
| `scripts/run-matmul.sh` | 🔎 sollte portieren | Target `npu1_4col` → `npu4`; die `amdxdna`-HAL-Flags bleiben |
| `tools/npu-runner` | 🔎 sollte portieren | IREE-C-API unverändert — gegen den npu4-Build neu kompilieren |
| `tools/npu-trim` | ✅ Konzept intakt | die Op-Abdeckungs-Grenze verschiebt sich, der Ansatz ist identisch; weiterhin kein Vendor-EP unter Linux, der es ersetzen würde |
| `mlir-aie`-(IRON-)Track | 🔎 **stärkster Weg** | IRON [1.4.x](https://github.com/Xilinx/mlir-aie/releases): Strix First-Class (`npu2`), **Peano ist jetzt das Standard-Backend** (wir haben es ohnehin gebaut), **HRX** = XRT-freie Host-Runtime-Option; [amd/IRON](https://github.com/amd/IRON) liefert eine vorgebaute Op-Bibliothek (GEMM, GEMV, MHA, GQA, RMSNorm, RoPE, softmax, dequant) als pip-Wheels aus |

## 🔎 Das Hardware-Delta, das zählt, wenn du Kernels schreibst

- **Geometrie**: npu1 ist ein Array mit 4 Spalten; Strix Point (`npu4`) ist **4 Zeilen × 8
  Spalten — 32 Compute-Tiles + 8 Memory-Tiles**, partitionierbar an Spaltengrenzen,
  mit firmware-verwaltetem Kontext-Scheduling
  ([Kernel-Docs](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **Datentyp**: AIE2Ps Schlagzeile ist **bfp16 Block Floating Point** — 8 Werte
  teilen sich einen 8-Bit-Exponenten, 9 Bytes pro 8 Werte. Die Unterstützung hängt an ~450+
  hartkodierten `__AIE_ARCH__`-Bedingungen in mlir-aie statt an Feature-Flags —
  zugleich eine Portierungsfalle und eine benannte Beitragsfläche
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390)).
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

## Wohin es als Nächstes geht

1. **Die Matmul-Rezepte + `npu-runner` auf `npu4` portieren** und XDNA1-vs-
   XDNA2-Zahlen nebeneinander veröffentlichen (dieselben Tabellen wie im README).
2. **IRON-GEMM/GQA auf dem 4×8-Array reproduzieren** (mlir-aie 1.4.x; HRX ausprobieren,
   um die XRT-Abhängigkeit loszuwerden).
3. **Quantisiertes Prefill-GEMM** — W4A16-Kernels (und bfp16-ausnutzende) via den
   IRON-Flow; [TileFuse](https://arxiv.org/abs/2606.11357) hat das Rezept
   veröffentlicht (bis zu +281% GEMV gegenüber Full-Precision-NPU-Baselines). Die
   [amd/IRON](https://github.com/amd/IRON)-Bibliothek hat dequant, aber **kein
   Q4/MXFP4-GEMM** — diese Lücke ist real, und llama.cpp hat eine offene, unbeanspruchte
   ggml-xdna-Backend-Anfrage
   ([#21725](https://github.com/ggml-org/llama.cpp/issues/21725)) als
   maintainer-sichtbare Landezone.

*Status: Seite hinzugefügt am 2026-08-15; Aktivierung am selben Tag auf der obigen
Strix-Point-Maschine abgeschlossen und verifiziert — `xrt-smi`-Enumeration und ein
`pyxrt`-Geräte-Open von `RyzenAI-npu4`, nach dem Beheben von
[Stolperstein #0](GOTCHAS.de.md). Die 🔎-Punkte tragen ihre Quellen inline.*
