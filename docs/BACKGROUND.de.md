**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Hintergrund: XDNA1, XDNA2 und warum Linux für die erste Generation schwierig ist

## Der Chip

AMDs Ryzen-AI-NPU ist ein von Xilinx geerbtes räumliches Array aus **AI Engines (AIE)** —
ein Gitter aus VLIW-Vektorkacheln, die über ein Streaming-/DMA-Interconnect verbunden sind, plus Speicher-
und „Shim“-Reihen, die zur Host-Seite überbrücken. Du programmierst es, indem du die Berechnung auf
Kacheln platzierst und Daten zwischen ihnen routest (Dataflow), nicht mit einem CUDA-artigen Kernel.

Zwei Generationen sind hier relevant:

| | **XDNA1** („Phoenix“/„Hawk Point“) | **XDNA2** („Strix“ usw.) |
|---|---|---|
| Zu finden in | Ryzen 7040 / 8040 (z. B. **7840U**) | Ryzen AI 300 Serie |
| Kachel-Architektur | AIE2 (`aie2`) | AIE2P |
| Phoenix-Geometrie | 4 Core-Reihen × **4 nutzbare Spalten** (5 roh), `npu1_4col` | größer, `npu4` |
| PCI-ID | `1022:1502` | `1022:17f0` |
| ~Leistung | ~10 TOPS | ~50 TOPS |

## Die Linux-Software-Situation (Mitte 2026)

Die **Kernel**-Seite ist gelöst: Der `amdxdna`-DRM-Accel-Treiber wurde in
**Linux 6.14** upstream aufgenommen (die Firmware ebenfalls). Auf einem modernen Kernel enumeriert die NPU als
`/dev/accel/accel0` und `xrt-smi` sieht sie — für **beide** Generationen.

Die **Userspace-/Compiler**-Seite ist der Punkt, an dem XDNA1 abfällt:

- **AMD Ryzen AI Software für Linux** (1.7.x) — unterstützt **nur STX/KRK (XDNA2)**.
- **ONNX Runtime + Vitis AI EP** — auf Linux x86_64 wird der Client-NPU-Graph-Compiler
  nicht ausgeliefert; Ops fallen auf die CPU zurück.
- **Lemonade / FastFlowLM** (die Projekte „NPU LLMs on Linux“) — **nur XDNA2**;
  sie geben ausdrücklich an, dass XDNA1 der 7000er/8000er-Serie nicht unterstützt wird.

XDNA1 unter Linux ist also **treibersichtbar, aber von den schlüsselfertigen
Stacks anwendungsverwaist**. Die Ausnahme — der eine aktiv entwickelte offene Pfad, der *explizit*
XDNA1 (`npu1`, 4×5) anvisiert — ist **`nod-ai/iree-amd-aie`**, ein IREE-Plugin. Es ist
forschungsnah (Kernel, keine beliebigen Modelle), läuft aber tatsächlich auf der
Hardware. Genau das baut dieses Repo.

## Wie die `amdxdna`-HAL das Gerät erreicht

`iree-amd-aie` kompiliert deinen Matmul zu:

1. **AIE-Core-Code** — Peano (`llvm-aie`, ein Fork von LLVM mit einem `aie2`-Target)
   kompiliert Pro-Kachel-Programme (`core_<col>_<row>.elf`).
2. **Konfiguration / Steuerung** — Object-FIFO- oder AIR-Dataflow-Lowering, Paket-
   Routing und ein Steuerprogramm, gepackt (via `bootgen`) in die `.vmfb`.

Zur Laufzeit **öffnet die `amdxdna`-HAL** (in die Runtime eingebaut mit
`-DIREE_EXTERNAL_HAL_DRIVERS=amdxdna`) **`/dev/accel/accel0` direkt** und
setzt DRM-ioctls (`DRM_IOCTL_AMDXDNA_GET_INFO`, Command-Submission, Fence-Wait)
unter Verwendung eines vendored UAPI-Headers ab. Sie linkt **nicht** die externe XRT-Bibliothek `xrt_coreutil`
— das ist die separate, experimentelle `xrt`-HAL. Deshalb musst du AMDs
Out-of-Tree-`xdna-driver` **nicht** bauen, wenn der In-Tree-`amdxdna.ko` vorhanden ist.

Das Gerät meldet seine Geometrie über denselben ioctl; `npu1_4col` und
`--amdxdna_n_core_cols=4` müssen damit übereinstimmen (siehe [GOTCHAS #6](GOTCHAS.de.md)).

## Referenzen

- AMD `xdna-driver` & Kernel-`amdxdna`-Dokumentation (kernel.org `accel/amdxdna`)
- `nod-ai/iree-amd-aie` (README, `build_tools/ci/`)
- `Xilinx/llvm-aie` (Peano)
- IREE (`iree.dev`)
