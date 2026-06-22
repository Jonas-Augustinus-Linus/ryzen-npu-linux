**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Was kann man mit der XDNA1-NPU unter Linux tatsächlich MACHEN?

Eine praktische, ehrliche Landkarte für alle, die die Ryzen-AI-NPU der ersten Generation
(XDNA1 / „Phoenix", z. B. den 7840U) unter Linux **nutzen** wollen — Gamer, Erbauer von
lokaler KI / Agenten, App-Entwickler und Lernende.

## Der ehrliche Realitätsrahmen (lies das zuerst)

Was du heute mit XDNA1+Linux hast, ist **Kernel-/Primitiv-Ebene**, nicht schlüsselfertig.
Der einzige funktionierende Software-Pfad ist [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie),
aus dem Quellcode gebaut — ein **Compiler + Runtime für AIE-Kernels** (matmul, conv und
die elementweisen Ops drumherum), kein Modellserver. Jeder schlüsselfertige Stack (AMD
Ryzen AI SW für Linux, ONNX Runtime Vitis AI EP, Lemonade/FastFlowLM) **schließt XDNA1
aus**; vollständige schlüsselfertige Modelle und LLMs sind **XDNA2-/Windows-Territorium**. Für die
meisten anspruchsvollen lokalen KI-Lasten auf diesem Laptop ist die **Radeon-780M-iGPU** (Ollama/llama.cpp Vulkan,
ROCm) schneller und unendlich einfacher — sie ist dein echtes Arbeitspferd. **Warum sich
also überhaupt mit der NPU abmühen?** Weil ihr echter Vorteil **Performance pro Watt
für ein gleichmäßiges, dauerhaft laufendes Inferenz-Primitiv** ist: ein kleiner conv-/matmul-Block, der
ewig läuft, am Akku nippt und CPU und iGPU im Leerlauf hält. Das ist die Sache,
die es zu bauen lohnt — und mehrere davon sind heute baubar. Der Rest dieses Leitfadens
dreht sich darum, diesen Vorteil zu nutzen, ohne zu viel zu versprechen.

> **Ein Mythos, der sofort sterben muss:** Es gibt **keinen stillen CPU-Fallback**. Wenn du
> dem Compiler eine Op übergibst, die er nicht auf der NPU platzieren kann, bekommst du einen
> **Compile-Fehler weiter unten in der Kette**, keine transparente CPU-Ausführung. „Führ mein Modell
> auf der NPU aus und lass die schwierigen Teile zurückfallen" ist **nicht**, wie diese Toolchain
> funktioniert — du partitionierst den Graphen selbst und behältst die nicht unterstützten Teile als separaten Code auf der CPU.

---

## Leistungsobergrenze: Was `iree-amd-aie` *heute* auf XDNA1 ausführen kann

Das ist der Teil, von dem alles andere abhängt, daher wird er präzise formuliert. Verifiziert
gegen das On-Device-CI-Harness (`build_tools/ci/cpu_comparison/run.py`,
`matmul_test_config.py`) und das Compiler-Dispatch (`KernelDispatch.cpp`) am Repo-
HEAD `fddfec1b`, und gegengeprüft gegen eine adversariale Durchsicht dieser Quellen.

### Ops, die echt auf der NPU LAUFEN (numerisch geprüft gegen llvm-cpu)

| Op | auf `npu1_4col` verifizierte dtypes | Status |
|---|---|---|
| `linalg.matmul` (+ `matmul_transpose_a/b`, `batch_matmul`, `matmul4d`) | `i8→i32`, `i32→i32`, `bf16→f32` | ✅ Numerisch in CI geprüft |
| `linalg.matmul` + **Bias-Add** (Linear-Layer) | nur `bf16→f32` | ✅ Läuft auf npu1 (`MatmulThinBias`/`MatmulFullBias`, Fusion-Flag) |
| `linalg.conv_2d_nhwc_hwcf` (einfache 2D-conv) | `i32→i32`, `bf16→f32`, `i8→i32` | ✅ Registriert & ausgeführt auf npu1 (`conv-decompose`) |
| **Multi-Dispatch-Graphen** (Producer→Consumer-Ketten) | wie oben | ✅ `three_matmuls`, `two_matmul_switching` bestehen auf npu1 |

Ein Modell ist also **nicht** auf einen einzelnen Kernel beschränkt — du kannst mehrere
unterstützte Dispatches zu einem kleinen Graphen verketten, der auf der NPU ausgeführt wird.

### Ops, die TEILWEISE / experimentell sind (Lowering existiert, aber nicht CI-garantiert auf Hardware)

| Op | Realität | Vertrauensgrad |
|---|---|---|
| `linalg.softmax` | Eine npu1-Lowering-Strategie **und** ein bf16-LUT-exp-Microkernel existieren, aber der On-Device-e2e-Test ist **auskommentiert**, bis [iree#21633](https://github.com/iree-org/iree/issues/21633) gelöst ist. | 🟡 Compile-Pfad existiert; On-Device-Korrektheit **nicht** CI-garantiert |
| `conv_2d_nhwc_hwcf_q` (i8-**quantisierte** conv) | Nur eine **FileCheck-/Compile**-Fixture (`conv2d_nhwc_q.mlir`); **nicht** in einen Hardware-Lauf verdrahtet und **nicht** numerisch verifiziert. | 🟡 Nur Source-/Pass-Unterstützung — nimm nicht an, dass es läuft |
| i8-matmul + **Dequant-/Requant**-Epilog (das INT8-Fully-Connected-Muster) | `matmul_elem_2.mlir` ist ein echter Requant-Epilog, **aber verwaist** — kein Harness registriert es, also wird es heute **nicht** über CI ausgeführt. Der oben genannte *Gleitkomma*-matmul+Bias-Pfad ist das, was tatsächlich durchlaufen wird. | 🟡 Das Muster ist in der Source real; du musst es selbst verdrahten & verifizieren |
| `depthwise_conv_2d_nhwc_hwc` | Ein Lowering-Zweig existiert, wird aber im Tree als „fragil, keine Leitplanken" beschrieben; der CI-Test ist **auskommentiert**. | 🟡 Probier es, erwarte Tuning; nicht garantiert |
| `reduction_sum` | Als Sample vorhanden. | 🟡 |

### Ops, die heute NICHT auf XDNA1 laufen

- **Attention / Flash-Attention** — es ist überhaupt keine Attention-Op für das AIE-
  Backend registriert; die vorausgesetzte softmax-e2e ist deaktiviert. ⛔ auf XDNA1.
- **LayerNorm, gather/Embedding-Lookups, dynamische Shapes** — nicht im Dispatch-Satz.
- **Recurrent Cells (GRU/LSTM)** — kein Lowering; architektonisch ohnehin schlecht passend.

### Kann man ein ganzes kleines Modell ausführen?

**Baubar, nicht schlüsselfertig.** Ein kleines **quantisiertes MLP oder 2–3-schichtiges CNN**, dessen
*jede* Schicht auf unterstützte matmul-/einfache-conv-/fused-elementweise-Dispatches abbildet,
kann als Dispatch-Graph auf der NPU ausgeführt werden. Aber: (a) dieser Build **kann
weder `.onnx` noch PyTorch importieren** — er wurde mit `IREE_INPUT_TORCH/ONNX/TOSA=OFF` und
ohne Python-Bindings kompiliert und liefert **kein `iree-import-onnx`** mit; du fütterst ihn nur mit handgeschriebenem
**linalg-Level-MLIR**. Um ein echtes Modell zu importieren, musst du **IREE neu bauen** mit
jenen Frontends ON. (b) Jede nicht unterstützte Op (softmax bis #21633, Attention,
layernorm, depthwise, Embeddings, dynamische Shapes) ist ein **harter Compile-Fehler**, also
musst du sie vermeiden oder auf der CPU halten. (c) Du tunst die Tiling-Flags von Hand. Es gibt **keinen
In-Repo-Ganzmodell-(ResNet/MLP/Transformer-)e2e-Test, der auf npu1 besteht.**

**Gemessene Obergrenze auf dieser Kiste:** bf16-matmul **~220 GFLOP/s bei 1024³** (native
Stärke), `i32` ~6 GFLOP/s (nicht der native Typ der AIE), kleine matmuls sind
dispatch-overhead-gebunden. Gut für eine kleine Modellstufe bei geringem Tastverhältnis; **nicht**
zum Servieren eines LLM.

---

## Für Erbauer von lokaler KI / Agenten

Die NPU ist **keine** Drop-in-Inferenz-Engine für irgendeine Agenten-Komponente. Aber die
GEMM-/conv-Mathematik unter Embeddings, Klassifikatoren, Rerankern und Wake-Word-Modellen
**ist** genau das, was die NPU ausführt — das sind also echte Engineering-Builds, keine
Fantasien. Das wiederkehrende Muster: **dichte Schichten auf der NPU, der sequenzielle /
Attention- / softmax-Kleber auf der CPU.**

| Anwendung | Machbarkeit | Wie (konkreter Pfad) | Anmerkung |
|---|---|---|---|
| Wake-Word / Keyword-Spotting (dauerhaft an) | 🟡 baubar | Ein CNN/FC-KWS-Modell: Mel-Frontend auf CPU → kleiner conv2d-/FC-Klassifikator auf NPU pro ~80-ms-Frame → Schwellwert → Event auslösen. (Der Kopf von `openWakeWord` ist ein 3-schichtiges FC-ReLU-Netz — reines matmul.) | **Die mit Abstand beste Agenten-Passung.** Winzig, läuft ewig, perf/watt ist der ganze Sinn. Frames bündeln, um den ~hundert-µs-Dispatch zu amortisieren. |
| RAG-Embeddings (MiniLM / bge-small / e5-small) | 🟡 baubar | Lowere die **matmul**-Blöcke des Encoders auf die NPU (bf16/i8); halte softmax/layernorm/Attention auf der CPU. Embeddings sind batchig & latenztolerant (indiziere einen Korpus einmal). | Die GEMMs *sind* der Kostenfaktor und *sind* unterstützt; du teilst den Graphen & validierst die Numerik. |
| Bi-Encoder-Re-Ranking (Query×Doc-Scoring) | 🟡 baubar | Gebündeltes matmul vorberechneter Embeddings — nahe an einem reinen matmul, der mit Abstand besten Op der NPU. | Die sauberste Abbildung aller Agenten-Aufgaben. Cross-Encoder-Reranking braucht Attention → halte das auf der CPU. |
| Intent-Klassifikation / Routing-Kopf | 🟡 baubar | Distilliertes MiniLM oder ein MLP über eingefrorenen Embeddings: Encoder-GEMMs + linearer Kopf als matmuls (bf16). | Kurze Sequenz, matmul-dominant → Dispatch-Overhead amortisiert sich. |
| Kleine CNN-Wahrnehmung (UI-Element-/Screenshot-Klassifikator, OCR-Vorfilter) | 🟡 baubar | Einfacher `conv_2d_nhwc_hwcf`-Backbone (bf16, oder i8→i32) + matmul-Kopf auf NPU; resize/normalize auf CPU. ViT vermeiden (Attention-Wand). | Einfache conv ist verifiziert; **i8-*quantisierte* conv ist nur-compile**, also bevorzuge bf16 oder validiere i8 selbst. |
| Whisper / Speech-to-Text für einen Sprachagenten | ⛔ (heute) ungeeignet | Nutze `whisper.cpp` auf der CPU oder der 780M (Vulkan). Der Encoder *könnte* ein Forschungs-NPU-Offload sein, aber es gibt kein End-to-End-Whisper-on-iree-amd-aie; der Decoder ist GEMV-/speichergebunden. | NPU-int8-Whisper-Builds zielen auf Windows/Vitis, nicht auf XDNA1+Linux. |
| LLM-**Decode** / Token-Generierung | ⛔ ungeeignet | Nutze die **iGPU**: Ollama/llama.cpp Vulkan (~14 tok/s gemma-2B, ~5–6 tok/s 7–8B Q4). | Decode ist **speicherbandbreiten**-gebunden; der FLOPs/Watt-Vorteil der NPU hilft beim Flaschenhals nicht. Der klarste „nutze die iGPU"-Fall. |
| LLM-**Prefill** (rechengebunden, „sollte" einer NPU passen) | 🟠 braucht XDNA2/Windows | Braucht fusioniertes Attention + RoPE + RMSNorm + softmax, gelowert für npu1 — nichts davon existiert. AMDs IRON `llama_3.2_1b` implementiert diese, zielt aber **nur** auf **AIE2P/XDNA2**. | „Rechengebunden" hilft nur, wenn die Ops lowerbar sind. Auf XDNA1 sind sie es nicht. |
| „Zeig auf meine `.onnx`, auf NPU ausführen" | ⛔ nicht verfügbar | Der ONNX Runtime Vitis AI EP fällt bei Client-NPUs unter Linux auf die CPU zurück; dieser Build hat keinen Importer. Baue IREE mit `IREE_INPUT_ONNX/TORCH=ON` neu, um überhaupt zu *importieren*, und erwarte dann massive Op-Lücken. | Ein Neuaufbau von Grund auf, nicht schlüsselfertig. |

---

## Für Gamer

**Brutal ehrlich:** Ein Linux-Gamer auf einem 7840U **kann Spiele heute mit dieser NPU
nicht schneller oder besser machen**, in keiner ausgelieferten Form. Drei harte Wände, keine reine
NPU-Schwäche:

1. **Die Proton-Sandbox.** Spiele sind Windows-`.exe` unter Proton/Wine. Die NPU ist
   nur über Linux-native `amdxdna`-ioctls erreichbar (XRT XDNA SHIM + eine Linux-ELF-
   Runtime). Es gibt **keinen Windows-seitigen `amdxdna`-Treiber innerhalb eines Proton-Prefix**,
   also **kann ein Spiel die NPU nicht aufrufen**. Der einzige Pfad ist ein **separater Linux-nativer
   Hilfsprozess außerhalb des Prefix**.
2. **XDNA1 ist von jedem schlüsselfertigen Stack aufgegeben** (FastFlowLM/Lemonade/Ryzen AI SW
   = XDNA2). Nur `iree-amd-aie` aus dem Quellcode läuft hier.
3. **Niemand liefert Game-NPU-Offload** unter Linux (oder eigentlich Windows). **NPUs liefern
   null FPS** in aktuellen Spielen.

> **Der große Mythos: FSR ist KEINE NPU-Last.** FSR vor 4 ist analytisch (kein ML).
> FSR4 / Redstone-Neural-Rendering läuft auf den **RDNA4-WMMA**-Einheiten der GPU und braucht
> eine RX-9000-GPU — die Ryzen-AI-NPU wird nie genutzt. AMDs eigener Echtzeit-NPU-
> Upscaler (REAPPEAR) ist **XDNA2, Windows, auf Video**, und AMD selbst nennt
> In-Game-NPU-Upscaling eine *„Zukunftsrichtung."*

| Anwendung | Machbarkeit | Wie (konkreter Pfad) | Anmerkung |
|---|---|---|---|
| Lokale Sprache / Push-to-Talk-STT als **Out-of-Process-Companion** | 🟡 baubar | Whisper-**Encoder** (GEMM-lastig), via iree-amd-aie in einem Linux-Daemon kompiliert: Mikrofon via PipeWire lesen → Text über einen lokalen Socket emittieren → Spiel/Overlay konsumiert ihn. | **Die eine realistische gaming-nahe NPU-Nutzung.** Außerhalb der Render-Schleife, tolerant gegenüber ~100–300 ms Latenz, nativ Linux (die Proton-Wand greift nicht). Den Encoder auf XDNA1 zu portieren ist der schwierige Teil. |
| Neuronale NPC- / Gegner-KI (Intent, taktische Entscheidungen) | 🟡 baubar | Ein Linux-Companion-Dienst führt eine kleine Policy/MLP via iree-compile aus; das Spiel (Mod/Overlay) fragt sie über einen Socket ab. Nur rundenbasiert / im Sekundentakt. | IPC- + Dispatch-Latenz schließen 60-Hz-Per-Tick-Kampf aus. DIY-Mod-Muster, nichts liefert das aus. |
| Prozedurale Inhalte (Texturen/Level) zur **Ladezeit** | 🟡 baubar | Offline / beim Level-Laden in einem nativen Linux-Prozess generieren; das Spiel lädt die Assets. Latenztolerant. | Umgeht sowohl die Proton-Wand als auch das Frame-Budget. Nur kleine/mittlere Netze. |
| Offline-/Batch-ML-Upscaling von **Captures/Screenshots** (nicht live) | 🟡 baubar | Auf Disk capturen → kleiner ESRGAN-artiger conv-Stack, zu `.vmfb` kompiliert → mit `--device=amdxdna` ausführen. | Nur machbar, *weil* es offline ist. Der Vulkan-Pfad (Real-ESRGAN-ncnn) ist heute weitaus einfacher/schneller. |
| Lokaler LLM-Co-Pilot **neben** (nicht im) Spiel | 🟡 baubar | Kleines quantisiertes Modell als nativer Linux-Dienst; Overlay/Discord-Bot konsumiert es; hält die 780M frei. | Bescheidene tok/s; Bring-up aus dem Quellcode, da FastFlowLM/Lemonade XDNA1 verweigern. |
| In-Game-Neural-TTS für NPC-Zeilen | 🟠 braucht XDNA2/Windows | Architektonisch in Ordnung als Companion-Daemon, aber VITS-/Transformer-Vocoder sind auf XDNA1 weitgehend unimplementiert. | CPU-TTS ist heute einfacher. |
| **In-Game**-ML-Super-Resolution / Upscaling pro Frame | ⛔ ungeeignet | Das Spiel erreicht `/dev/accel/accel0` unter Proton nicht; externes Capture→Upscale→Reinject sprengt das 16-ms-Budget; SR-conv-Kernels für XDNA1 sind ungeschrieben. | FSR4 = GPU; REAPPEAR = XDNA2/Windows. |
| Frame-Generierung | ⛔ ungeeignet | Braucht Motion-Vektoren/Optical-Flow, gebunden an die Render-Pipeline (GPU). Kein Pipeline-Zugriff unter Proton; Per-Frame-Round-Trips erhöhen die Latenz. | Kein Frame-Gen-Produkt nutzt eine NPU. |
| Laufzeit-Animation / Neural IK | ⛔ ungeeignet | Enge Per-Frame-Engine-Kopplung + Proton-Sandbox = kein Laufzeitpfad. Nur Offline-Tooling. | |
| Echtzeit-External-Capture-Upscaler über die NPU | ⛔ ungeeignet | Die einzigen funktionierenden Echtzeit-Upscaler (Anime4K, waifu2x/Real-ESRGAN/RIFE auf ncnn-vulkan) sind GPU/Vulkan mit **keinem XDNA-Backend** und würden mit der 780M konkurrieren. | Du würdest neue MLIR-AIE-conv-Kernels schreiben *und* trotzdem an der Latenz verlieren. |
| Anti-Cheat via On-Device-NPU-KI | ⛔ ungeeignet | Irrelevant: Kernel-Anti-Cheat ist nur Windows; EAC/BattlEye auf Proton sind User-Mode-Policy-Entscheidungen. Kein Anti-Cheat nutzt eine NPU. | |

---

## Für App-Entwickler (stromsparend, dauerhaft an)

Hier zahlt sich der perf-per-watt-Vorteil der NPU tatsächlich aus: eine **gleichmäßige,
geringes-Tastverhältnis**-Last, deren schwerer Kern **conv- oder matmul-förmig** ist, eingebunden
in die standardmäßige Linux-Media-Verrohrung. Die ehrliche Aufteilung ist **conv-/matmul-förmig vs.
recurrent**, nicht Audio vs. Vision.

**Integrationsflächen (alle Standard-Linux):**
- **Audio** → PipeWire `pw_filter` / `module-filter-chain` (derselbe Hook,
  den DeepFilterNets LADSPA-Plugin nutzt) → ein virtuelles Mikrofon bereitstellen.
- **Kamera** → Capture via GStreamer/v4l2 → NPU ausführen → in ein **v4l2loopback**
  `/dev/videoN` (`exclusive_caps=1`) schreiben, das Zoom/Chrome/OBS lesen.
- **Allgemeiner Daemon** → die IREE-Runtime-C-API (`amdxdna`-HAL-Device erstellen → `.vmfb`
  laden → aufrufen), modelliert nach `samples/simple_embedding/simple_embedding.c`.

| Anwendung | Machbarkeit | Wie (konkreter Pfad) | Anmerkung |
|---|---|---|---|
| Webcam-Hintergrundunschärfe / virtueller Hintergrund | 🟡 baubar | MediaPipe Selfie Segmentation (MobileNetV3-Klasse conv-Encoder-Decoder, 256×256). Den conv-Backbone (bf16) auf NPU ausführen; CPU-resize + Composite; raus zu v4l2loopback. | Reine conv → bildet auf unterstütztes `conv_2d_nhwc_hwcf` ab. Nicht-128-fache Shapes brauchen Tiling-Arbeit; depthwise-Stufen sind 🟡 (fragil). |
| Mikrofon-Rauschunterdrückung als virtuelles Mikrofon | 🟡 baubar | **DeepFilterNet** (conv-Encoder-Decoder), **nicht** das klassische RNNoise. STFT/ERB + Gating auf der CPU halten; conv-Blöcke (bf16) auf die NPU auslagern; PipeWire-`pw_filter`-Callback. Frames bündeln. | Der Gewinn ist **Akku**, nicht Latenz — die CPU-Version ist bereits echtzeitfähig. Harter <10-ms-Deadline + Dispatch-Overhead ist die Herausforderung. |
| On-Device-Bildklassifikation / Auto-Tagging | 🟡 baubar | MobileNetV3 / EfficientNet-Lite: conv-Backbone (`conv_2d_nhwc_hwcf`) + matmul-Kopf auf NPU; über deine Bibliothek bei geringem Tastverhältnis batchen; resize/normalize auf CPU. | Beste Vision-Passung **in bf16**. Die i8-*quantisierte* conv + Requant-Epilog ist **nur-compile in CI** — validiere sie selbst, bevor du dich auf i8 verlässt. |
| Embeddings für semantische Bildsuche (MobileCLIP-S0-Image-Tower) | 🟡 baubar | conv-Backbone + finales Projektions-matmul → Vektoren fester Länge via C-API; in sqlite/faiss auf der CPU speichern. Einmal indizieren, günstig abfragen. | Idealer Hintergrundjob mit geringem Tastverhältnis. Text-**Transformer**-Tower brauchen Attention → off-device vorberechnen oder auf der CPU halten. |
| On-Device-OCR (Screenshots/Scans) | 🟡 baubar | CRNN/PaddleOCR-artig: conv-Feature-Extraktor auf NPU; CTC-/Sequenz-Decode + jegliches BiLSTM auf CPU. Textzeilen-Crops batchen. | Der recurrent Recognizer **kann nicht** auf der NPU leben (softmax/Attention gesperrt). |
| Object-Detection-Backbone (Auto-Framing-Smartkamera) | 🟡 baubar | NanoDet/YOLO-nano: conv-Backbone+Neck auf NPU; Anchor-Decode + NMS auf CPU; raus zu v4l2loopback. | NMS-/Anchor-Mathematik ist steuerungslastig → CPU. Ungerade Feature-Map-Shapes brauchen Tiling-Tuning. |
| Anwesenheits- / Blickerkennung zum Energiesparen | 🟡 baubar | Winziges Gesichts-/Blick-CNN bei 2–5 fps: conv-Detektor auf NPU; bei „wegschauend N s" → CPU-Aktion (DPMS-Dimmen / Sperren / Pausieren). | Niedrige fps **verbergen den Dispatch-Overhead** → einer der nachsichtigeren Builds; perf/watt ist bei geringem Tastverhältnis am stärksten. |
| Laufzeit-Animation / Neural IK innerhalb einer Engine | ⛔ ungeeignet | Per-Frame-Engine-Kopplung; nur als Offline-Content-Tooling machbar. | |
| Klassisches **RNNoise** (GRU) oder **Silero VAD** als NPU-Last | ⛔ ungeeignet | Auf der CPU halten (RNNoise läuft bereits ~60× echtzeit). Für NPU-Sprachverbesserung wechsle zum **conv-basierten DeepFilterNet**. | GRU/LSTM sind inhärent sequenziell (Zeitschritt hängt vom vorigen Hidden State ab); Dispatch-Overhead dominiert; es existiert kein recurrent Lowering. |

---

## Für Lernende

Die NPU ist ein echtes, programmierbares Spatial-Dataflow-Gerät, für das du kompilieren und
dem du **bei der Ausführung zuschauen** kannst — ein hervorragender Weg, um AIE / MLIR / Dataflow ohne
Cloud-Hardware zu lernen.

| Anwendung | Machbarkeit | Wie (konkreter Pfad) | Anmerkung |
|---|---|---|---|
| AIE / Spatial-Dataflow lernen, indem man ein funktionierendes matmul mutiert | ✅ funktioniert heute | Starte von [`scripts/run-matmul.sh`](../scripts/run-matmul.sh) und [`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir); ändere Shapes/dtypes; neu kompilieren; auf `--device=amdxdna` ausführen. | Die eine empirisch verifizierte Stufe auf dieser Kiste. |
| matmul/conv über Shapes & dtypes benchmarken | ✅ funktioniert heute | `BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`; i32 vs. bf16 vergleichen, dispatch-gebunden vs. rechengebunden beobachten. | Lehrt, warum bf16 nativ ist und kleine Kernels overhead-gebunden sind. |
| Eigenen conv2d-/fused-elementweise-Kernel verfassen | 🟡 baubar | Schreibe `linalg.conv_2d_nhwc_hwcf` oder matmul+generic-MLIR; kompiliere `conv-decompose`/`pack-peel`; verifiziere gegen eine CPU-Referenz. | Einfache conv ist verifiziert; quantisierte conv/softmax sind experimentell. |
| Ein winziges End-to-End-Modell bauen (quantisiertes MLP / 2–3-schichtiges CNN) | 🟡 baubar | Verfasse jede Schicht als unterstütztes linalg-MLIR (nach dem Vorbild von `three_matmuls.mlir`); kompiliere zu einer `.vmfb`; führe den Dispatch-Graphen auf der NPU aus. | Kein `.onnx`-Import in diesem Build; nicht unterstützte Ops sind **Compile-Fehler**, keine Fallbacks. |
| Ein echtes ONNX-/PyTorch-Modell importieren und die NPU ansteuern | 🟠 braucht einen Neuaufbau (+ massive Op-Lücken) | Baue IREE mit `IREE_INPUT_TORCH/ONNX=ON` + Python-Bindings neu, um `iree-import-onnx` zu bekommen; erwarte, dass Attention-/layernorm-/softmax-/Embedding-/dynamische-Shape-Ops **nicht für AIE kompilieren**. | Frontends sind in diesem Build absichtlich aus; importieren ≠ ausführen. |
| Upstream XDNA1-auf-Linux-Abdeckung beitragen | ✅ funktioniert heute | Lass Ergebnisse auf deiner eigenen XDNA1-Kiste laufen; reiche Hardware-Reports / Neu-Op-Tests ein. Phoenix-CI existiert, aber die Community-Abdeckung ist dünn. | Jedes Ergebnis hilft; siehe [`CONTRIBUTING.md`](../CONTRIBUTING.md). |
| Ein LLM/Whisper ausführen, um „NPU-KI zu lernen" | ⛔ ungeeignet | Falsches Werkzeug — nutze die 780M-iGPU für das Modell und die NPU für *Primitive*. | Beginne deine NPU-Reise nicht damit, einen Transformer servieren zu wollen. |

---

## Bau dein eigenes NPU-Primitiv (Kochbuch)

Die generische Pipeline, um die schwere Stufe eines Modells in ein NPU-Primitiv zu verwandeln, das du
in einen Daemon einbettest:

**1. Wähle die schwere, parallele Stufe des Modells.** Sie muss **matmul- / einfach-conv- /
fused-elementweise**-förmig sein. Recurrent-(GRU/LSTM-) und Attention-/softmax-Stufen bleiben
auf der CPU. Halte Vor-/Nachverarbeitung (STFT, resize, NMS, Tokenisierung) auf der CPU.

**2. Drücke sie als linalg-Level-MLIR aus.** Starte von
[`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) (matmul) oder einer
`conv_2d_nhwc_hwcf`-Vorlage. **Bevorzuge `bf16`** (den AIE-nativen ~220-GFLOP/s-
Typ). i8-Quantisierung funktioniert für matmul; i8-*quantisierte conv* und der i8-Requant-
Epilog sind experimentell, also **verifiziere sie gegen eine CPU-Referenz, bevor du dich auf
sie verlässt**. (Dieser Build kann `.onnx`/PyTorch nicht importieren — füttere ihn mit MLIR.)

**3. Kompiliere für die NPU.** Der verifizierte Flag-Satz
([`scripts/run-matmul.sh`](../scripts/run-matmul.sh), [`docs/GOTCHAS.de.md`](GOTCHAS.de.md)):

```bash
iree-compile \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device=npu1_4col \
  --iree-amdaie-device-hal=amdxdna \
  --iree-amdaie-lower-to-aie-pipeline=air        `# bf16 matmul; use objectFifo for i8/conv` \
  --iree-amdaie-tile-pipeline=pack-peel          `# matmul; use conv-decompose for conv` \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  model.mlir -o model.vmfb
```

**4. Verifiziere mit einer bekannten Eingabe.**

```bash
iree-run-module --device=amdxdna --module=model.vmfb \
  --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4   # cols=4 NOT 5, or ert state 8 timeout
```

**5. Integriere in einen Daemon / Media-Graphen.** Binde die `.vmfb` ein über:
- **CLI** (`iree-run-module`) für Batch-Jobs / schnelle Skripte; oder
- **IREE-Runtime-C-API** — das `amdxdna`-HAL-Device erstellen, das Modul laden,
  die Funktion auflösen, aufrufen (nach dem Vorbild von `simple_embedding.c`). **Bündle Frames
  pro Dispatch**, um den ~hundert-µs-Submit-Overhead zu amortisieren, und halte einen **CPU-
  Fallback-Pfad** bereit.
- Hänge es dann an **PipeWire** (`pw_filter` / `module-filter-chain` → virtuelles Mikrofon)
  oder **GStreamer + v4l2loopback** (→ virtuelle Kamera), oder einfach einen Socket.

> Repo-Skripte zum Aufbauen: [`check-npu.sh`](../scripts/check-npu.sh) (lebt sie?),
> [`enable-npu.sh`](../scripts/enable-npu.sh) (Render-Gruppe / memlock /
> XRT), [`build.sh`](../scripts/build.sh) (der Build aus dem Quellcode mit allen
> Workarounds), [`run-matmul.sh`](../scripts/run-matmul.sh) (das Compile+Run-
> Rezept). Der Host-Compiler muss **gcc** sein (clang21 segfaultet beim Linken von
> `libIREECompiler.so`).

---

## Wo anfangen (nach Zielgruppe)

- **Agenten-Erbauer:** Baue ein **Wake-Word- / KWS**-Primitiv (conv/FC, dauerhaft an)
  oder einen **Bi-Encoder-Reranker** (gebündeltes matmul) — die saubersten NPU-Passungen. Führe das
  LLM selbst auf der 780M-iGPU aus.
- **Gamer:** Der einzige realistische Build ist ein **Out-of-Process-Sprach-(STT)-Companion-
  Daemon** über einen Socket. Behandle die NPU als Side-Car, nie innerhalb der Render-Schleife.
- **App-Entwickler:** Beginne mit **Hintergrundunschärfe** (Kamera → v4l2loopback) oder einem
  **Foto-Klassifikator** in **bf16** — conv-förmig, latenztolerant, perf/watt gewinnt.
- **Lernende:** Mutiere [`run-matmul.sh`](../scripts/run-matmul.sh), benchmarke
  bf16 vs. i32, verfasse dann deinen eigenen conv2d-Kernel; steige auf zu einem winzigen MLP-Graphen.

## Ehrliche „lohnt sich auf XDNA1+Linux noch nicht"-Liste

- **Irgendein LLM / Whisper / Stable Diffusion auf der NPU servieren.** Nutze die iGPU, oder
  Windows/XDNA2.
- **LLM-Prefill *oder* -Decode auf der NPU** — Prefill braucht Attention (fehlt),
  Decode ist bandbreitengebunden (iGPU gewinnt).
- **Alles mit Attention/Transformern als NPU-Dispatch** — keine Attention-Op,
  softmax-e2e deaktiviert (iree#21633).
- **Beliebige `.onnx`/PyTorch importieren und „einfach ausführen"** — kein Importer in
  diesem Build; nicht unterstützte Ops sind Compile-Fehler, keine Fallbacks.
- **In-Game- / Per-Frame-Upscaling oder Frame-Gen** — Proton-Sandbox + Latenz +
  FSR4-ist-GPU. Passiert hier nicht.
- **GRU/LSTM-Modelle (klassisches RNNoise, Silero VAD) auf der NPU** — sequenziell,
  kein recurrent Lowering; auf der CPU halten.
- **Sich auf i8-quantisierte conv oder den i8-Requant-Epilog verlassen**, ohne es selbst
  zu verifizieren — das sind heute nur-compile-/verwaiste Fixtures in CI.

---

*Vertrauensgrad-Legende: ✅ funktioniert heute (auf dieser Kiste verifiziert) · 🟡 baubar /
experimentell (echtes Engineering, unterstützte Ops) · 🟠 braucht XDNA2 oder Windows · ⛔
ungeeignet für eine NPU. Verifiziert auf einem Ryzen 7 PRO 7840U (Phoenix/XDNA1), Ubuntu
26.04, Kernel 7.0, XRT 2.21, `iree-amd-aie` HEAD `fddfec1b`, am 2026-06-22.
`iree-amd-aie` ist in einer frühen Phase und bewegt sich schnell — Flags und Op-Abdeckung driften.*
