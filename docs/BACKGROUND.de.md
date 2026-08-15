**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Hintergrund: XDNA1, XDNA2 und die offenen Linux-Wege

## Das Silizium wird nicht nutzlos, nur weil der Turnkey-Stack weiterzieht

AMDs Ryzen-AI-NPU ist ein von Xilinx geerbtes räumliches **AI-Engine-(AIE)-Array**:
VLIW-Vektorkacheln sind über Streaming/DMA verbunden; Speicher- und Shim-Reihen
stellen die Verbindung zum Host her. Programme platzieren Berechnungen auf den
Kacheln und routen Daten zwischen ihnen, statt das Gerät wie eine allgemeine
CUDA-GPU zu behandeln.[^iron-guide]

| | **XDNA1** (Phoenix/Hawk Point) | **XDNA2** (Strix und verwandte Geräte) |
|---|---|---|
| Zu finden in | Ryzen 7040/8040, einschließlich **7840U** | Ryzen-AI-300-Familie |
| Kachelarchitektur | AIE2 (`aie2`) | AIE2P |
| Ziel dieses Repos | Phoenix: 4 nutzbare Spalten, `npu1_4col` | verifiziertes Strix: `npu4` |
| Nominale NPU-Leistung | beim 7840U bis zu 10 TOPS[^amd-7840u] | bei Ryzen AI 300 bis zu 50 TOPS[^amd-platform-guide] |

AMDs Spezifikation des 7840U nennt weiterhin eine Ryzen-AI-Engine mit bis zu
10 TOPS. Diese Rechenfähigkeit verschwindet nicht, weil aktuelle
Anwendungssoftware Phoenix nicht mehr aufführt.[^amd-7840u]

## Die Linux-Situation am 15.08.2026

Die Kernel-Grundlage ist gemeinsam. AMDs offener `amdxdna`-Treiber stellt
unterstützte Geräte über die Linux-Accelerator-Schnittstelle bereit; AMD
veröffentlicht Treiber, XRT-Shim, Firmware-Anforderungen und Installationshinweise.[^amdxdna]

Die komfortable Produktschicht ist generationsabhängig. AMD Ryzen AI Software
1.8 für Linux nennt **STX und KRK**, nicht Phoenix/XDNA1.[^ryzenai-linux]
Das beschreibt die heutige Turnkey-Supportmatrix; es beweist nicht, dass XDNA1
unter Linux nicht rechnen kann.

Für XDNA1-Experimente gibt es inzwischen **zwei offene, niedrigere Wege**:

1. **Der von diesem Repository paketierte Weg:** der exakt gepinnte
   [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)-Stack. Er
   senkt IREE-Programme ab, paketiert gerätespezifische VMFB-Module und ruft sie
   über die `amdxdna`-HAL auf. Die Skripte hier pinnen, bauen, erkennen, führen
   aus und vergleichen alle Ausgaben mit CPU-Referenzen. Die veröffentlichten
   Phoenix-Messungen stammen vom damaligen Nightly. Der aktuelle exakte v1-Pin
   wurde auf Strix erneut verifiziert; der Phoenix-Wiederholungslauf steht aus.
2. **Der direkte Kernelweg:**
   [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) mit Peano und XRT.
   Dieses Repo pinnt den IRON-Python-API-/Compiler-Stack auf 1.4.1; Entwickler
   schreiben räumliche AIE-Kernels und Datenbewegungen direkt. Die neuere
   Operator-/Anwendungsbibliothek [`amd/IRON`](https://github.com/amd/IRON) ist
   ein separates Projekt auf MLIR-AIE-Sprachbindungen — keine Umbenennung und
   kein neuer Ort von `Xilinx/mlir-aie`. Ihre Upstream-Ergebnisse sind zu
   reproduzierende Hinweise, keine vom Release-Pin geerbten Garantien.

Beim AMD-IRON-Commit
[`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93) endete der offizielle
Phoenix-Workflow mit **2.105 bestandenen und 45 übersprungenen Pytest-Fallläufen**.[^iron-phoenix-ci]
Wegen der standardmäßigen fünf Wiederholungen entspricht das **421 verschiedenen
bestandenen und 9 verschiedenen übersprungenen Konfigurationen**. Die neun Skips
sind je drei MHA-, Streaming-SwiGLU- und GEMV+GELU-Konfigurationen, jeweils
fünfmal wiederholt. Der AIE2/Phoenix-Hardwarelauf umfasst bestandene,
CPU-referenzierte GEMM/GEMV,
Q4NX-Dequantisierung, Softmax, RoPE, RMSNorm/LayerNorm, Aktivierungen und
Transposition. Das ist starke Upstream-Evidenz für XDNA1 als ML-Kernel-Labor.
Es ist **kein** Wiederholungslauf des exakten v1-Stacks dieses Repos und kein
End-to-End-LLM-Nachweis für XDNA1. MHA und Streaming-SwiGLU gehören zu den
exakten Skips; GQA wird durch diesen Phoenix-Lauf nicht belegt. Diese Grenze
gehört zum Ergebnis.

## Wie der `amdxdna`-HAL-Weg dieses Repos das Gerät erreicht

`iree-amd-aie` übersetzt eine unterstützte Operation in:

1. **AIE-Core-Programme.** Peano (`llvm-aie`) kompiliert Code pro Kachel für die
   jeweilige AIE-Architektur.
2. **Konfiguration und Steuerung.** Dataflow-Lowering, Routing, DMA-/Steuercode
   und Geräteprogramme werden in eine `.vmfb` gepackt.
3. **Host-Aufruf.** Die IREE-`amdxdna`-HAL öffnet `/dev/accel/accel0`, reicht
   Befehle über die Kernel-UAPI ein und wartet auf Fences. Das ist nicht der
   separate XRT-/`pyxrt`-Hostpfad der IRON-Beispiele.

Auch die Gerätegeometrie gehört zum Korrektheitsvertrag. Beim verifizierten
Phoenix-Mapping müssen `npu1_4col` und `--amdxdna_n_core_cols=4` übereinstimmen;
für unbekannte spätere Geräte rät dieses Repo kein Ziel. Siehe
[GOTCHAS #6](GOTCHAS.de.md) und die [Support-Matrix](SUPPORT.md).

## Warum beide Wege wichtig sind

Der IREE-Weg macht wiederholbare Anwendungsintegration und eine persistente
C-/Python-Runtime praktikabel. IRON legt Kacheln, FIFOs, Kernels und die
bewegliche Operatorgrenze offen. Zusammen ermöglichen sie Laptop-Besitzern, mit
einem CPU-geprüften Matmul zu beginnen, eine hybride lokale KI zu komponieren
und jeweils eine Compiler- oder Operatorgrenze zu verschieben.

Der [Open NPU Lab](OPEN-NPU-LAB.md) ist die Projektkarte, das
[Forschungsregister](RESEARCH.md) sammelt Primärquellen und Aussagegrenzen, und
die [LLM-Roadmap](LLM-ROADMAP.md) verfolgt offene Arbeit.

[^amd-7840u]: AMD, [Spezifikation des Ryzen 7 7840U](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html).
[^amd-platform-guide]: AMD, [Ryzen and Radeon Consumer Pocket Guide](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/amd-consumer-pocket-guide-ryzen-radeon-july-2024.pdf), Juli 2024.
[^amdxdna]: AMD, [`xdna-driver`: Linux-Treiber und XRT-Schnittstelle für AMD-NPUs](https://github.com/amd/xdna-driver).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 — Linux-Systemanforderungen und unterstützte Plattformen](https://ryzenai.docs.amd.com/en/latest/linux.html), abgerufen am 15.08.2026.
[^iron-guide]: AMD IRON, [Programming Guide](https://github.com/amd/IRON/blob/main/programming_guide/README.md).
[^iron-phoenix-ci]: AMD IRON, [offizieller Phoenix-Workflowlauf 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), Commit `cdc48e93`.
