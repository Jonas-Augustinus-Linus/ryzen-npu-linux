**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Was lässt sich mit einer XDNA1-NPU unter Linux bauen?

Dies ist eine praktische Karte für Besitzer von Phoenix-Laptops wie dem Ryzen
7 7840U. Es geht nicht darum, jedes Modell als schlüsselfertig darzustellen.
Vielmehr soll das Silizium, das bereits in unseren Rechnern steckt, zu einem
offenen Linux-Labor werden: eine nützliche Stufe ausführen, jede Ausgabe mit
einem vertrauenswürdigen CPU-Ergebnis vergleichen, sie mit CPU und iGPU
kombinieren und genügend Belege veröffentlichen, damit andere weiterarbeiten
können.

Alle in diesem Repository verfassten Inhalte stehen unter der MIT-Lizenz:
**Jeder darf sie gemäß den Lizenzbedingungen nutzen, kopieren, ändern, forken,
veröffentlichen und weitergeben.** Die Mission steht im
[Open NPU Lab](OPEN-NPU-LAB.md), Primärquellen und weitere Abzweigungen in den
[Research branches](RESEARCH.md).

## Erst das Beleglabel lesen, dann die Fähigkeit

- **Repo-Hardware:** Dieses Repository hat den Code auf der genannten NPU
  ausgeführt und das vollständige Ergebnis geprüft. Der aktuelle Lock ist auf
  Strix Point `npu4` belegt; für Phoenix gibt es wertvolle frühere
  Hardwareergebnisse, aber noch keinen Lauf mit dem aktuellen Lock.
- **Upstream-Hardware:** Ein Upstream-Projekt hat den Test auf Hardware
  ausgeführt. Das ist ein reproduzierbarer Weg, kein automatisch geerbtes
  Ergebnis dieses Repositories.
- **Vorlage / Plumbing:** echter NPU-Dispatch oder echtes Linux-I/O, aber mit
  synthetischen Gewichten oder einer beispielhaften Operation statt eines
  trainierten Produkts.
- **Nur kompiliert / Projekt:** Hardwareausführung und numerische
  Korrektheitsprüfung stehen noch aus.

Kompilieren ist nicht Ausführen; Ausführen ist nicht Korrektheit; ein
Kernel-Timing ist kein Anwendungsergebnis. Die NPU-Energie wurde in diesem Repo
noch nicht gemessen, daher wird keine Akkulaufzeit versprochen.

## Es gibt mehr als einen offenen Softwarepfad

Die enge Operatorgrenze älterer Fassungen dieser Seite gilt für das
**im Repository gepinnte `iree-amd-aie`-Backend am Commit `fddfec1b`**, nicht
für das gesamte XDNA1-Ökosystem.[^iree-amd-aie]

| Pfad | Was die Belege aussagen | Grenze |
|---|---|---|
| Gepinntes `iree-amd-aie` dieses Repos | Das Repo verifiziert sorgfältig geformte bf16/i8/i32-Matmuls, persistenten Dispatch und Hybridbeispiele. Der Conv-Pfad ist eng und zielabhängig. | Der exakte aktuelle Lock ist auf `npu4` belegt; die veröffentlichten 7840U-Ergebnisse stammen vom früheren funktionierenden Snapshot. Nicht unterstützte importierte Graphregionen fallen nicht still auf die CPU zurück. |
| Gepinnter `mlir-aie`-1.4.1-Pfad dieses Repos | Direkte IRON-Kernels und Upstream-Beispiele liefen auf dem Strix-Point-System des Repos; dieser niedrigere Pfad eignet sich für Autoren, die Platzierung und Datenbewegung selbst steuern. | Genau dieser Pfad wurde auf der XDNA1-Hardware des Repos noch nicht erneut ausgeführt. |
| Bewegliches [`amd/IRON`](https://github.com/amd/IRON) | Am exakten Commit `cdc48e93` meldete AMDs Phoenix-Hardwareworkflow am 2026-08-15 bei seinen standardmäßigen fünf Iterationen **2.105 bestandene / 45 übersprungene Fallläufe**: **421 verschiedene bestandene Konfigurationen / 9 verschiedene Skips**. Die erfolgreiche AIE2-Abdeckung umfasste bf16 GEMM/GEMV, Q4NX-Dequantisierung, Softmax, RoPE, RMSNorm, LayerNorm, Aktivierungen, Transpose sowie SwiGLU-Decode/Prefill-Varianten.[^iron-phoenix] | Das ist starke **Upstream-Phoenix-Evidenz**, kein Exact-v1-XDNA1-Lauf dieses Repos und kein vollständiges LLM. Die 9 verschiedenen Skips sind 3 MHA-, 3 streaming-SwiGLU-prefill- und 3 GEMV+GELU-Konfigurationen, jeweils fünfmal wiederholt und damit drei Gruppen zu 15 Fallläufen. MHA/GQA bleibt im Dashboard AIE2P-only. |

Die entscheidende Korrektur lautet: „Dieses gepinnte Backend kann eine
Operation nicht lowern“ bedeutet **nicht** „XDNA1 kann so einen Kernel nicht
ausführen“. Zu jeder Aussage gehören die genaue Toolchain, das Gerät, der Test
und das numerische Orakel.

## ONNX: importieren, extrahieren, Zusammensetzung selbst besitzen

Das aktuelle [`scripts/build.sh`](../scripts/build.sh) installiert ein separat
gepinntes `iree-import-onnx`; für den Repo-Workflow sind weder ein IREE-Neubau
noch ein Umweg über Python-Bindings nötig. [`tools/npu-trim`](../tools/npu-trim/)
kann einen Graph importieren oder prüfen, unabhängige Matmul-/Conv-Formen
erkennen, saubere Kernels ausgeben und jeden davon für das erkannte Ziel
testkompilieren.

Es baut oder startet bewusst **kein** beliebiges Gesamtmodell. Die Anwendung
besitzt Gewichte, Padding/Layout-Konvertierungen, nicht unterstützte
Operationen, CPU-Fallback und Orchestrierung. Das Beispiel
[`examples/onnx-mlp`](../examples/onnx-mlp/) ist der ausführbare Vertrag:
NPU-Matmul → CPU-ReLU → NPU-Matmul, geprüft gegen ein bf16-CPU-Orakel.

```text
ONNX ── gepinnter Importer ──▶ npu-trim ──▶ zielmarkierte Matmul/Conv-VMFBs
                                                │
                      anwendungseigene Gewichte, Layouts und Ablaufplanung
                                                │
                           NPU-Kernels + expliziter CPU-Glue/Fallback
```

## Ein lokales LLM-System kann alle drei Prozessoren nutzen

Ein NPU-Beitrag ist auch dann nützlich, wenn die NPU nicht das ganze LLM
bereitstellt:

```text
Mikrofon / Kamera / Dokumente / UI-Ereignisse
                    │
                    ▼
      NPU: Always-on-Trigger, Feature-Block,
           Linear/Fused-Block, Klassifikation oder Scoring
                    │
                    ▼
      CPU: I/O, Tokenisierung, Top-k, Werkzeuge, Richtlinien,
           nicht unterstützte Ops und vertrauenswürdiger Fallback
                    │
                    ▼
      iGPU: etablierte quantisierte Local-LLM-Runtime
            für Prefill und Token-Erzeugung
```

Wenn offene Attention-, Normalisierungs- und Quantisierungskernels reifen, kann
ein gemessener Block von CPU/iGPU auf die NPU wandern, ohne die Anwendung
wegzuwerfen. Zwei veröffentlichte Ergebnisse zeigen, warum dies ein echter
Forschungsweg ist:

- Rösti und Franz legten GEMMs des **GPT-2-124M-Fine-Tunings** auf eine
  Phoenix-NPU der ersten Generation, während die CPU den Rest behielt. Sie
  berichten über mehr als **2,8×** für die ausgelagerten Matrixmultiplikationen,
  **1,7×** Netz- und **1,2×** Akku-End-to-End-Durchsatz sowie **1,4×**
  Energieeffizienz im Akkubetrieb.[^phoenix-gpt2] Das sind Autorenwerte, keine
  Messungen dieses Repos.
- STEEL berichtet im Mittel **9,6× geringere XDNA1-Latenz gegenüber DATO**, der
  zitierten früheren XDNA1-Attention-Basis. Davon getrennt meldet die
  HX-370/XDNA2-Messung **9,17×** bzw. **1,75×** weniger Energie als ihre CPU-
  und GPU-Baselines sowie **22,8×** gegenüber ihrer schichtweisen
  XDNA2-Implementierung.[^steel] XDNA1-Latenz und XDNA2-Energie sind getrennte
  Experimente.

## Dinge, die du ausführen, ersetzen oder erweitern kannst

| Ausgangspunkt | Was heute real ist | Nützlicher nächster Schritt |
|---|---|---|
| [`local-rag-sidecar`](../examples/local-rag-sidecar/) | **Repo-Hardware (`npu4`):** deterministisches CPU-Hashing → persistente NPU-bf16-Scorematrix 256×256 → CPU-Top-k → optionaler LLM-Endpunkt, standardmäßig auf die literalen Loopback-Hosts `127.0.0.1` oder `::1` beschränkt; entfernte Endpunkte erfordern die explizite Aktivierung mit `--allow-remote`. Alle 65.536 Ausgaben werden geprüft. | Hashing durch lizenzierte gelernte Embeddings oder eine Projektion ersetzen, Anfragen bündeln und auf XDNA1 wiederholen. Für eine kleine Einzelanfrage ist ein CPU-Dot-Product wahrscheinlich schneller; das Beispiel belegt Integration und Korrektheit, keinen universellen Speedup. |
| [`wake-word`](../examples/wake-word/) | **Vorlage:** echtes CPU-Log-Mel und drei persistente NPU-Dense-Dispatches; die mitgelieferten Gewichte sind ein beispielhafter Matched Filter. | Reale Wake-Word-/Intent-Gewichte trainieren und lizenzieren, Audio und Fehlalarme testen und damit einen lokalen iGPU/CPU-Assistenten wecken. |
| [`onnx-mlp`](../examples/onnx-mlp/) | **Vorlage:** tatsächlich importierter Hybrid-Forward-Pass mit zwei Matmuls und CPU-Prüfung pro Dispatch sowie Ende-zu-Ende. | Einen trainierten Intent-, Routing-, Safety- oder Projektionskopf einsetzen und formspezifische Kernels plus Orakel erhalten. |
| [`npu-camera`](../examples/npu-camera/) | **Anwendungs-Plumbing:** GStreamer → persistente NPU → `v4l2loopback`; die NPU-Demooperation ist ein zweipassiger Box-Blur, keine Segmentierung. | Eine Stufe durch einen trainierten, unterstützten Vision-Block ersetzen; Resize, Compositing und Fallback auf CPU belassen. |
| [`npu-runner`](../tools/npu-runner/) | **Repo-Hardware:** VMFB einmal laden und aus C oder Python wiederholt aufrufen, mit vollständiger Ausgabekontrolle. | Lokalen Daemon für gebündeltes Scoring, Sensorklassifikation oder einen wiederverwendbaren Model-Sidecar bauen. |
| [`mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **Direct-Kernel-Labor:** einsehbarer Spatial-Code und Mehrspaltenausführung. | Einen AMD-IRON-AIE2-Operator auf Phoenix reproduzieren und Platzierung, Transfers, CPU-Golden und erste fehlschlagende Form veröffentlichen. |
| [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | **Nur kompiliert:** gepinnter externer W4A16-Frontend-Probe. | Lowering, Linken, Weight Packing, NPU-Ausführung und quantisierungsbewusste Korrektheit abschließen, bevor Leistung beansprucht wird. |

## Weitere Anwendungsrichtungen

| Bedarf | NPU-großes Experiment | Explizit woanders belassen |
|---|---|---|
| Privater lokaler Assistent | Wake Word, Intent/Safety-Head, gebündeltes Retrieval-Scoring | CPU-Orchestrierung; CPU/iGPU-Generierung |
| Persönliche Suche | Projektion und Query×Dokument-Scorematrix | Parsing, Speicherung, Top-k und finale Generierung |
| Barrierefreiheit | akustischer, Präsenz-, Gesten- oder UI-Ereignisklassifikator | Erfassung und Anwendungsrichtlinie |
| Kamera/Privatsphäre | unterstützte Conv- oder Linear-Stufe | Capture, Resize, Compositing, `v4l2loopback` |
| Audio | gebündelter Conv/Linear-Feature- oder Denoising-Block | PipeWire, STFT und harter Echtzeit-Fallback |
| Spiele | nativer Linux-Companion für Stimme, Intent oder Offline-Inhalte | Proton-Spiel-/Renderloop und framekritische Arbeit |
| Compilerforschung | Fusion, Tiling, Packet Flow, quantisierte Kernels | CPU-Referenzen und reproduzierbare Harnesses |

Sachliche Grenzen bleiben wichtig. Hier existiert kein ausgelieferter Pfad für
mehr FPS, Frame Generation oder Upscaling im Renderloop; unter Proton ist ein
separater nativer Linux-Companion die praktikable Experimentgrenze. Klassische
GRU/LSTM-Workloads benötigen eigenes Lowering oder bleiben auf der CPU.
Beliebige Transformer-/Whisper-/Vision-Graphen sind für das gepinnte Backend
keine Gesamtmodell-Drop-ins. Das sind zu erforschende Schnittstellen, keine
Gründe, das Gerät ungenutzt zu lassen.

## Leiter für reproduzierbare Experimente

Beginne mit strikter Geräte- und Korrektheitsprüfung:

```bash
./scripts/check-npu.sh --strict
./scripts/run-matmul.sh bf16 512 512 512
```

Wähle anschließend eine bestehende Anwendungsnaht:

```bash
./examples/local-rag-sidecar/run.sh --cpu-only --selftest
./examples/local-rag-sidecar/run.sh --selftest       # unterstützte Live-NPU
~/src/iree-aie-venv/bin/python tools/npu-trim/npu_trim.py model.onnx
```

Veröffentliche für jede Erweiterung Geräteidentität, exakten Commit/Lock,
Modell- und Datenlizenz, Formen und Präzision, vollständige Ausgabetoleranz,
Rohlogs, Latenz und—erst nach der Messung—Systemenergie. Halte den CPU-Fallback
bereit. Auch ein minimaler Fehler mit reproduzierbarer Eingabe ist wertvolle
offene Forschung.

## Wo es weitergeht

- Mission, Evidenzvertrag und Beitragsleiter:
  [Open NPU Lab](OPEN-NPU-LAB.md)
- Primärpublikationen, Upstream-Code und Folgefragen:
  [Research branches](RESEARCH.md)
- Generationsspezifische Ziele und aktuelle XDNA2-Belege:
  [XDNA2-Leitfaden](XDNA2.de.md)
- Längere Transformer-Meilensteine:
  [LLM roadmap](LLM-ROADMAP.md)

Das Ziel ist nicht eine einzige privilegierte Demo. Es sind viele einsehbare
Experimente, mit denen Besitzer, Lernende und Forschende eine NPU weiterverwenden,
statt sie zu vergessen. Nimm den Quellcode, ändere ihn und mache dein Ergebnis
zum Ausgangspunkt für andere.

## Primärquellen

[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie). Der Repo-Lock ist `fddfec1be6ceefbdb890079d957947dfa1fe0848`; dieser Abschnitt beschreibt dieses Backend, nicht jeden XDNA-Compilerpfad.
[^iron-phoenix]: AMD, [`IRON` am Commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) und [Phoenix-Extensive-Hardwareworkflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15: Bei den standardmäßigen fünf Iterationen entsprechen 2.105 bestandene und 45 übersprungene Fallläufe 421 verschiedenen bestandenen Konfigurationen und 9 verschiedenen Skips. Upstream-CI bewegt sich; beim Reproduzieren den Commit pinnen.
[^phoenix-gpt2]: A. Rösti und M. Franz, [„Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools“](https://arxiv.org/abs/2504.03083), FCCM 2025. Phoenix der ersten Generation, Ryzen 9 7940HS, hybrides GPT-2-124M-Fine-Tuning.
[^steel]: V. J. B. Jung et al., [„STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU“](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. Das Paper nennt [`amd/IRON`](https://github.com/amd/IRON) als Open-Source-Implementierungspfad.
