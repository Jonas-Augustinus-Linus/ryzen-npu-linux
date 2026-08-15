**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Einen XDNA-Laptop zum hybriden lokalen KI-Labor machen

Eine NPU muss nicht allein ein vollständiges LLM bereitstellen, um im System
nützlich zu sein. Der praktische Weg für XDNA1 unter Linux besteht heute darin,
der NPU eine kleine, wiederholte und CPU-prüfbare Stufe zu geben, I/O, Regeln und
nicht unterstützte Operationen auf der CPU zu belassen und die iGPU bei Bedarf
für Token-Erzeugung mit hohem Durchsatz einzusetzen.

```text
Mikrofon / Kamera / Dokumente / UI-Ereignisse
                          │
                          ▼
               CPU: I/O, Steuerung, Fallback
                          │
               ┌──────────┴──────────┐
               ▼                     ▼
 NPU: Always-on-Trigger,        iGPU: quantisiertes LLM
 Scoring, Dense-/Conv-Blöcke     Prefill + Erzeugung
               └──────────┬──────────┘
                          ▼
               CPU: Tools, Regeln, Ausgabe
```

Das ist eine technische Aufteilung, kein allgemeines Leistungsurteil. Niedriger
Energieverbrauch und längere Akkulaufzeit sind Entwicklungsziele; dieses Repo
hat noch keine kontrollierten End-to-End-Energiemessungen veröffentlicht, die
sie belegen.

## Nützliche Projekte aus dem mitgelieferten Quellcode

| Projekt | Rolle der NPU | Rolle von CPU / iGPU | Evidenzgrenze |
|---|---|---|---|
| **Private RAG-Hilfe** | Dokument-/Query-Batches durch ein persistentes bf16-Matmul bewerten | CPU zerlegt, hasht und wählt Top-k; optional erzeugt ein lokales LLM auf einem anderen Backend | [`local-rag-sidecar`](../examples/local-rag-sidecar/) integriert die NPU wirklich in den RAG-Loop. Die Merkmale sind deterministisches Hashed Bag-of-Words, **keine trainierten Embeddings**; für eine kleine Einzelanfrage ist die CPU wahrscheinlich schneller. Der aktuelle Live-Nachweis gilt für XDNA2, der XDNA1-Lauf mit aktuellem Pin steht aus. |
| **Lokaler Sprachassistent** | Always-on-Wake- oder Intent-Head | CPU für Audio-Frontend und Steuerung; iGPU-LLM für Antworten | [`wake-word`](../examples/wake-word/) führt drei persistente NPU-Dense-Layer aus, doch die gelieferten Gewichte illustrieren nur den Pfad und bilden kein trainiertes Wake-Vokabular. |
| **Private Kamera-/Barrierefreiheits-Trigger** | unterstützte Conv-/Dense-Klassifikatorstufe | CPU nimmt auf und komponiert; die App erzeugt ein Linux-Ereignis | [`npu-camera`](../examples/npu-camera/) belegt die GStreamer → NPU → `v4l2loopback`-Verkabelung, führt derzeit aber einen Nicht-KI-Box-Blur aus. Ersetze ihn durch eine trainierte, CPU-geprüfte Modellstufe. |
| **Hybrides ONNX-Experiment** | extrahierte unterstützte Matmul-/Conv-Partitionen | CPU behält ReLU, Graph-Glue und Fallback | [`onnx-mlp`](../examples/onnx-mlp/) führt einen echten hybriden Forward-Pfad aus, aber Netz und Gewichte sind erzeugte Demodaten. [`npu-trim`](../tools/npu-trim/) prüft Teile, statt einen beliebigen Graphen magisch zu unterstützen. |
| **Forschung an quantisierten Blöcken** | GEMM/GEMV, Dequantisierung, Normalisierung, RoPE und Softmax, sobald der jeweilige Pfad verifiziert ist | CPU-Golden, nicht unterstützte Attention/Steuerung; optional iGPU für den Rest | AMDs offizieller IRON-Phoenix-Workflow am Commit `cdc48e93` bestand CPU-referenzierte AIE2-Beispiele dieser Primitive.[^iron-ci] Das ist Upstream-Evidenz, kein XDNA1-Ergebnis dieses Exact-Locks und kein vollständiges LLM. |
| **Generationsübergreifendes Labor** | denselben Quellcode mit gerätespezifischen Zielen ausführen | CPU protokolliert Identität und prüft jede Ausgabe | XDNA1-Historie, aktuellen XDNA2-Pin und künftige Geräte getrennt halten. Ein sauberer Fehler auf unbekannter Hardware ist ebenfalls nützlich. |

## Eine Abfolge, die veröffentlichbare Arbeit hervorbringt

1. **Einen Korrektheitsvertrag reproduzieren.** Vor jeder Optimierung den strikten
   Detektor und den vollständigen CPU-Vergleich ausführen.
2. **Einen synthetischen Teil ersetzen.** Wake-Word-Gewichte trainieren, eine
   echte Embedding-Projektion liefern oder den Kamera-Blur durch eine evaluierte
   Modellstufe ersetzen. CPU-Fallback beibehalten.
3. **Komponieren, nicht vortäuschen.** Die NPU-Stufe mit lokalem LLM, Datenbank,
   Desktop-Aktion oder Sensorloop verbinden und kennzeichnen, wo jede Operation läuft.
4. **Die ganze Anwendung messen.** Kernel- und End-to-End-Latenz, Transfers,
   Genauigkeit, Idle-/Lastleistung, Energie pro Aufgabe, Temperatur sowie CPU-/
   iGPU-Baselines berichten. Ein TOPS-Badge beweist keine Energieeffizienz.
5. **Die Grenze veröffentlichen.** Geräteidentität, Compiler-Commit, Shapes,
   Datentypen, Befehle, Vollausgabe-Korrektheit, Skips und ersten Fehler festhalten.
   Auch ein negatives Ergebnis mit Minimalreproduzierer hilft der Forschung.

## Zwei offene Wege mit unterschiedlichen Aufgaben

- Der gepinnte `iree-amd-aie`-Weg dieses Repos paketiert Gerätemodule und einen
  persistenten C-/Python-Aufruf. Hier beginnen die gelieferten Integrationen und
  der exakte Release-Vertrag.
- Der gepinnte [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)-1.4.1-Weg
  legt die IRON-Python-API/den Compiler für direkte räumliche Kernel frei. Die
  neuere Operator-/Anwendungsbibliothek [`amd/IRON`](https://github.com/amd/IRON)
  ist ein separates Projekt auf MLIR-AIE-Sprachbindungen, keine Umbenennung. Ihr
  offizieller Phoenix-Workflow meldete am Commit `cdc48e93` **2.105 bestandene
  und 45 übersprungene Pytest-Fallläufe**. Mit fünf Standardwiederholungen sind
  das **421 verschiedene bestandene und 9 verschiedene übersprungene
  Konfigurationen**. Die Skips sind je drei MHA-, Streaming-SwiGLU- und
  GEMV+GELU-Konfigurationen, jeweils fünfmal wiederholt. GQA wird von diesem Lauf
  nicht belegt; daraus darf kein Gesamt-LLM-Nachweis für XDNA1 werden.[^iron-ci]

AMD Ryzen AI Software 1.8 für Linux listet STX/KRK statt
Phoenix.[^ryzenai-linux] Das begrenzt den Drop-in-Produktweg, schließt diese
offenen niedrigeren Wege aber nicht.

## Die ehrliche Grenze

Es gibt hier weiterhin keinen unterstützten Befehl, der ein beliebiges GGUF-,
Whisper-, Stable-Diffusion- oder ONNX-Modell nimmt und den gesamten Graphen auf
XDNA1 bereitstellt. Compilerabdeckung, Speicher, Transfers und Host-Steuerung
sind reale Grenzen. Die produktive Antwort ist, sie sichtbar zu machen,
verifizierte Stufen auszulagern und jede Stufe austauschbar zu halten.

Die vollständige Einladung und Quellcode-/Evidenzgalerie steht im englischen
[Open NPU Lab](OPEN-NPU-LAB.md). Primärquellen und Aussagegrenzen enthält
[RESEARCH.md](RESEARCH.md), die nächsten Operator- und Modellschritte die
[LLM-Roadmap](LLM-ROADMAP.md).

[^iron-ci]: AMD IRON, [offizieller Phoenix-Workflowlauf 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), Commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 für Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), abgerufen am 15.08.2026; die Seite nennt STX und KRK als unterstützte Plattformen.
