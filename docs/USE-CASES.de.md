**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Wo kann man eine XDNA1-NPU unter Linux tatsächlich einsetzen?

Sei ehrlich zu dir selbst, was den Reifegrad angeht. Was du heute von
`iree-amd-aie` auf XDNA1+Linux bekommst, ist ein **Compiler + Runtime für AIE-Kernels**
(matmul, conv und die elementweisen Ops drumherum), erreichbar über die
`iree-*`-CLI und die IREE-Runtime-C-API. Es ist **kein** schlüsselfertiger Modellserver.

## Das mentale Modell: NPU vs. iGPU vs. CPU auf diesem Laptop

| Gerät | Am besten geeignet für | Verwende es für |
|---|---|---|
| **NPU (XDNA1, ~10 TOPS)** | dauerhafte, **stromsparende** quantisierte/bf16-Inferenz-Kernels | Auslagern bestimmter matmul/conv-Blöcke bei gleichzeitig geringem Akkuverbrauch |
| **iGPU (Radeon 780M)** | allgemeines Rechnen mit hohem Durchsatz | **dein echtes Arbeitspferd für lokale KI unter Linux heute** — LLMs via Vulkan/ROCm |
| **CPU** | alles, latenzflexibel | Glue, Steuerung, Fallback |

Die NPU existiert einzig und allein wegen der **Performance pro Watt**. Wenn dir der
Stromverbrauch egal ist, ist die 780M-iGPU der schnellere und weitaus einfachere Weg für allgemeine KI unter Linux.

## ✅ Heute gut geeignet

- **NPU- / Spatial-Dataflow-Programmierung lernen.** Ein echtes Gerät, für das man kompilieren und
  dessen Ausführung man beobachten kann. `run-matmul.sh` ist eine funktionierende Basis zum Verändern.
- **Benchmarking der NPU** für matmul/conv bei verschiedenen Shapes und Dtypes (i32, bf16→f32).
- **Stromsparende Inferenz-*Primitive*.** Handgebaute matmul/conv-Kernels, die du
  per IREE-Runtime-C-API in eine App einbettest und mit `--device=amdxdna` dispatchst, um
  eine gleichmäßige, leichtgewichtige Last von CPU/GPU fernzuhalten (z. B. kleine CNN-Stufen,
  Feature-Extraktoren, Matmuls für die Signalverarbeitung).
- **Prototyping / Forschung** zu AIE-Tiling, objectFifo- vs. air-Pipelines, Packet-
  Flow — die Bausteine, die letztlich größere Modelle realisierbar machen.
- **Upstream beitragen.** Jedes XDNA1-auf-Linux-Ergebnis hilft; die CI des Projekts
  hat einen dedizierten Phoenix-Runner, aber die Community-Abdeckung ist dünn.

## 🚫 Heute auf XDNA1+Linux nicht realistisch

- **Schlüsselfertiges LLM- / Whisper- / Stable-Diffusion-Serving auf der NPU.** Es gibt keine
  Drop-in-Runtime, die XDNA1 unter Linux anspricht. Nutze die **iGPU** (Ollama/llama.cpp Vulkan, ROCm),
  oder **Windows** (Legacy Vitis AI / Studio Effects), oder **XDNA2**-Hardware.
- **„Zeig auf meine `.onnx` und los."** Der Vitis-AI-EP der ONNX Runtime fällt für
  Client-NPUs unter Linux auf die CPU zurück. Du erstellst/lowerst Kernels, du importierst keine beliebigen Graphen.
- **Quantize-and-Deploy-Pipelines.** Quantisierungstools existieren; was fehlt, ist die *Runtime*, um
  das Ergebnis auf XDNA1+Linux auszuführen — quantisiere also nicht in der Hoffnung, hier deployen zu können.

## Wie man einen kompilierten Kernel in eine App einbettet

Die von `iree-compile` erzeugte `.vmfb` wird von der IREE-Runtime geladen. Entweder:

- **CLI**: `iree-run-module --device=amdxdna ... --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4`
  (ideal für Batch-Jobs / Skripte), oder
- **C-API**: Linke `iree/runtime` aus deiner `iree-install`, erstelle das `amdxdna`-
  HAL-Device, lade das Modul und rufe es auf — derselbe Pfad, den die CLI nutzt. So
  würdest du eine NPU-matmul/conv in eine echte stromsparende Pipeline einbinden.

## Wenn du schlüsselfertige NPU-Nutzung willst

1. **XDNA2-Hardware** (Strix / Strix Halo / Krackan) — dort landet das gesamte
   Linux-NPU-Momentum von 2026 tatsächlich (Lemonade/FastFlowLM, AMD Ryzen AI SW für Linux).
2. **Windows** auf demselben 7840U — der Legacy-Vitis-AI-Pfad und Windows Studio
   Effects unterstützen Phoenix dort.
