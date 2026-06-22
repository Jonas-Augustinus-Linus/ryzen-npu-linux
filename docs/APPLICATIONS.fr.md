**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Que pouvez-vous réellement FAIRE avec le NPU XDNA1 sous Linux ?

Une carte pratique et honnête pour ceux qui veulent **utiliser** le NPU Ryzen AI
de première génération (XDNA1 / « Phoenix », p. ex. le 7840U) sous Linux — joueurs,
constructeurs d'IA locale / d'agents, développeurs d'applications et apprenants.

## Le cadre honnête de la réalité (à lire en premier)

Ce dont vous disposez aujourd'hui sur XDNA1+Linux est de **niveau noyau/primitive**,
pas clé en main. Le seul chemin logiciel qui fonctionne est [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
construit depuis les sources — un **compilateur + runtime pour kernels AIE** (matmul, conv et
les opérations élémentaires qui les entourent), pas un serveur de modèles. Chaque stack clé en main (AMD
Ryzen AI SW pour Linux, ONNX Runtime Vitis AI EP, Lemonade/FastFlowLM) **exclut
XDNA1** ; les modèles et LLM clé en main complets sont du domaine de **XDNA2 / Windows**. Pour la plupart
des charges d'IA locale lourdes sur ce portable, l'**iGPU Radeon 780M** (Ollama/llama.cpp Vulkan,
ROCm) est plus rapide et infiniment plus simple — c'est votre véritable cheval de bataille. **Alors pourquoi
s'embêter avec le NPU ?** Parce que son véritable atout, c'est la **performance par watt
pour une primitive d'inférence stable, toujours active** : un petit bloc conv/matmul qui
tourne en permanence, ménage la batterie et laisse le CPU et l'iGPU au repos. C'est cela qui
vaut la peine d'être construit — et plusieurs de ces choses sont constructibles dès aujourd'hui. Le reste de ce guide
porte sur l'exploitation de cet atout sans promettre l'impossible.

> **Un mythe à tuer immédiatement :** il n'y a **aucun repli silencieux vers le CPU**. Si vous
> donnez au compilateur une op qu'il ne peut pas placer sur le NPU, vous obtenez une **erreur de
> compilation en aval**, pas une exécution CPU transparente. « Exécuter mon modèle sur le NPU et laisser
> les parties difficiles se rabattre » n'est **pas** le fonctionnement de cette chaîne d'outils — vous partitionnez
> le graphe vous-même et gardez les parties non prises en charge sur le CPU sous forme de code séparé.

---

## Plafond de capacité : ce que `iree-amd-aie` peut exécuter sur XDNA1 *aujourd'hui*

C'est la partie dont tout le reste dépend, elle est donc énoncée avec précision. Vérifié
par rapport au harnais CI sur appareil (`build_tools/ci/cpu_comparison/run.py`,
`matmul_test_config.py`) et au dispatch du compilateur (`KernelDispatch.cpp`) au HEAD du dépôt
`fddfec1b`, et recoupé par une revue adversariale de ces sources.

### Ops qui s'EXÉCUTENT réellement sur le NPU (vérifiées numériquement vs llvm-cpu)

| Op | dtypes vérifiés sur `npu1_4col` | Statut |
|---|---|---|
| `linalg.matmul` (+ `matmul_transpose_a/b`, `batch_matmul`, `matmul4d`) | `i8→i32`, `i32→i32`, `bf16→f32` | ✅ Vérifié numériquement en CI |
| `linalg.matmul` + **ajout de biais** (couche Linear) | `bf16→f32` uniquement | ✅ S'exécute sur npu1 (`MatmulThinBias`/`MatmulFullBias`, flag de fusion) |
| `linalg.conv_2d_nhwc_hwcf` (conv 2D simple) | `i32→i32`, `bf16→f32`, `i8→i32` | ✅ Enregistré et exécuté sur npu1 (`conv-decompose`) |
| **Graphes multi-dispatch** (chaînes producteur→consommateur) | comme ci-dessus | ✅ `three_matmuls`, `two_matmul_switching` passent sur npu1 |

Ainsi, un modèle n'est **pas** limité à un seul kernel — vous pouvez enchaîner plusieurs
dispatches pris en charge en un petit graphe qui s'exécute sur le NPU.

### Ops PARTIELLES / expérimentales (l'abaissement existe, mais non garanti en CI sur le matériel)

| Op | Réalité | Niveau de confiance |
|---|---|---|
| `linalg.softmax` | Une stratégie d'abaissement npu1 **et** un microkernel bf16 LUT-exp existent, mais le test e2e sur appareil est **commenté** en attendant [iree#21633](https://github.com/iree-org/iree/issues/21633). | 🟡 Le chemin de compilation existe ; la correction sur appareil **n'est pas** garantie en CI |
| `conv_2d_nhwc_hwcf_q` (conv i8 **quantifiée**) | Seulement une fixture **FileCheck/compile** (`conv2d_nhwc_q.mlir`) ; **non** reliée à aucune exécution matérielle et **non** vérifiée numériquement. | 🟡 Prise en charge source/pass uniquement — ne présumez pas qu'elle s'exécute |
| matmul i8 + épilogue de **déquant/requant** (le motif INT8 entièrement connecté) | `matmul_elem_2.mlir` est un véritable épilogue de requant **mais il est orphelin** — aucun harnais ne l'enregistre, il ne s'exécute donc **pas** via la CI aujourd'hui. Le chemin matmul+biais *en virgule flottante* ci-dessus est ce qui est réellement exercé. | 🟡 Le motif est réel dans les sources ; vous devez le câbler et le vérifier vous-même |
| `depthwise_conv_2d_nhwc_hwc` | Une branche d'abaissement existe mais est décrite dans l'arbre comme « fragile, sans garde-fous » ; le test CI est **commenté**. | 🟡 Essayez-le, attendez-vous à du réglage ; non garanti |
| `reduction_sum` | Présent comme exemple. | 🟡 |

### Ops qui ne s'exécutent PAS sur XDNA1 aujourd'hui

- **Attention / flash-attention** — aucune op d'attention n'est enregistrée pour le backend
  AIE ; le softmax e2e prérequis est désactivé. ⛔ sur XDNA1.
- **LayerNorm, gather/recherches d'embeddings, formes dynamiques** — absents du jeu de dispatch.
- **Cellules récurrentes (GRU/LSTM)** — aucun abaissement ; architecturalement mal adaptées de toute façon.

### Peut-on exécuter un petit modèle entier ?

**Constructible, pas clé en main.** Un petit **MLP quantifié ou un CNN à 2–3 couches** dont
*chaque* couche correspond à des dispatches matmul / conv simple / élémentaire fusionné pris en charge
peut s'exécuter comme un graphe de dispatch sur le NPU. Mais : (a) ce build **ne peut pas importer
de `.onnx` ni de PyTorch** — il a été compilé avec `IREE_INPUT_TORCH/ONNX/TOSA=OFF` et
sans bindings Python, et n'embarque **aucun `iree-import-onnx`** ; vous lui fournissez uniquement du
**MLIR de niveau linalg** écrit à la main. Pour importer un vrai modèle, vous devez **reconstruire IREE** avec
ces frontends ON. (b) Toute op non prise en charge (softmax jusqu'à #21633, attention,
layernorm, depthwise, embeddings, formes dynamiques) est une **erreur de compilation dure**, vous
devez donc l'éviter ou la garder sur le CPU. (c) Vous réglez à la main les flags de tiling. Il n'existe **aucun
test e2e de modèle entier (ResNet/MLP/transformer) dans le dépôt qui passe sur npu1.**

**Plafond mesuré sur cette machine :** matmul bf16 **~220 GFLOP/s à 1024³** (force
native), `i32` ~6 GFLOP/s (pas le type natif de l'AIE), les petits matmuls sont
limités par la surcharge de dispatch. Convient pour un petit étage de modèle à faible duty cycle ; **pas**
pour servir un LLM.

---

## Pour les constructeurs d'IA locale / d'agents

Le NPU n'est **pas** un moteur d'inférence prêt à l'emploi pour un composant d'agent quelconque. Mais le
calcul GEMM/conv sous les embeddings, classifieurs, rerankers et modèles de mot-clé d'activation
**est** exactement ce que le NPU exécute — ce sont donc de vraies réalisations d'ingénierie, pas des
fantasmes. Le motif récurrent : **couches denses sur le NPU, la colle séquentielle /
attention / softmax sur le CPU.**

| Application | Faisabilité | Comment (chemin concret) | Note |
|---|---|---|---|
| Mot-clé d'activation / détection de mots-clés (toujours active) | 🟡 constructible | Un modèle KWS CNN/FC : front-end mel sur CPU → petit classifieur conv2d / FC sur NPU par trame de ~80 ms → seuil → déclenchement d'événement. (La tête d'`openWakeWord` est un réseau FC ReLU à 3 couches — du matmul pur.) | **La meilleure adéquation pour un agent.** Minuscule, tourne en permanence, la perf/watt est tout l'enjeu. Regroupez les trames pour amortir le dispatch de ~quelques centaines de µs. |
| Embeddings RAG (MiniLM / bge-small / e5-small) | 🟡 constructible | Abaissez les blocs **matmul** de l'encodeur vers le NPU (bf16/i8) ; gardez softmax/layernorm/attention sur le CPU. Les embeddings sont par lots et tolérants à la latence (indexer un corpus une fois). | Les GEMM *sont* le coût et *sont* pris en charge ; vous découpez le graphe et validez les valeurs numériques. |
| Re-ranking bi-encodeur (scoring requête×doc) | 🟡 constructible | Matmul par lots d'embeddings précalculés — proche d'un matmul pur, la meilleure op du NPU. | La correspondance la plus propre de toutes les tâches d'agent. Le reranking cross-encodeur nécessite de l'attention → gardez-le sur le CPU. |
| Classification / routage d'intention (tête) | 🟡 constructible | MiniLM distillé ou un MLP sur embeddings figés : GEMM d'encodeur + tête linéaire en matmuls (bf16). | Séquences courtes, dominé par le matmul → la surcharge de dispatch s'amortit. |
| Perception par petit CNN (classifieur d'éléments d'UI / de captures, pré-filtre OCR) | 🟡 constructible | Backbone `conv_2d_nhwc_hwcf` simple (bf16, ou i8→i32) + tête matmul sur NPU ; redimensionnement/normalisation sur CPU. Évitez les ViT (mur de l'attention). | La conv simple est vérifiée ; la conv *quantifiée* i8 est **compile-only**, préférez donc le bf16 ou validez l'i8 vous-même. |
| Whisper / reconnaissance vocale pour un agent vocal | ⛔ non adapté (aujourd'hui) | Utilisez `whisper.cpp` sur CPU ou le 780M (Vulkan). L'encodeur *pourrait* faire l'objet d'un déchargement NPU de recherche, mais il n'existe pas de Whisper-sur-iree-amd-aie de bout en bout ; le décodeur est limité par GEMV/mémoire. | Les builds Whisper NPU-int8 ciblent Windows/Vitis, pas XDNA1+Linux. |
| **Décodage** LLM / génération de tokens | ⛔ non adapté | Utilisez l'**iGPU** : Ollama/llama.cpp Vulkan (~14 tok/s gemma-2B, ~5–6 tok/s 7–8B Q4). | Le décodage est limité par la **bande passante mémoire** ; l'atout FLOPs/watt du NPU n'aide pas le goulet d'étranglement. Le cas « utilisez l'iGPU » le plus net. |
| **Prefill** LLM (limité par le calcul, « devrait » convenir à un NPU) | 🟠 nécessite XDNA2/Windows | Nécessite attention fusionnée + RoPE + RMSNorm + softmax abaissés pour npu1 — aucun n'existe. L'IRON `llama_3.2_1b` d'AMD les implémente mais ne cible que **AIE2P/XDNA2**. | « Limité par le calcul » n'aide que si les ops sont abaissables. Elles ne le sont pas, sur XDNA1. |
| « Pointe vers mon `.onnx`, exécute sur le NPU » | ⛔ non disponible | Le Vitis AI EP d'ONNX Runtime se rabat sur le CPU pour les NPU client sous Linux ; ce build n'a pas d'importateur. Reconstruisez IREE avec `IREE_INPUT_ONNX/TORCH=ON` pour ne serait-ce qu'*importer*, puis attendez-vous à de gros manques d'ops. | Une reconstruction depuis zéro, pas du clé en main. |

---

## Pour les joueurs

**Brutalement honnête :** un joueur Linux sur un 7840U **ne peut pas rendre les jeux plus rapides ni
meilleurs avec ce NPU aujourd'hui**, d'aucune manière livrable. Trois murs durs, et non une faiblesse brute
du NPU :

1. **Le bac à sable Proton.** Les jeux sont des `.exe` Windows sous Proton/Wine. Le NPU n'est
   accessible que via les ioctls `amdxdna` natifs Linux (XRT XDNA SHIM + un runtime ELF Linux). Il n'y a
   **aucun pilote `amdxdna` côté Windows dans un préfixe Proton**,
   un jeu **ne peut donc pas appeler le NPU**. Le seul chemin est un **processus assistant natif Linux
   séparé, hors du préfixe**.
2. **XDNA1 est abandonné par toute stack clé en main** (FastFlowLM/Lemonade/Ryzen AI SW
   = XDNA2). Seul `iree-amd-aie` depuis les sources tourne ici.
3. **Personne ne livre de déchargement NPU pour les jeux** sous Linux (ni vraiment sous Windows). **Les NPU délivrent
   zéro FPS** dans les jeux actuels.

> **Le grand mythe : FSR n'est PAS une charge de travail NPU.** FSR pré-4 est analytique (pas de ML).
> Le rendu neuronal FSR4 / Redstone tourne sur les unités **WMMA RDNA4 du GPU** et nécessite
> un GPU RX 9000 — le NPU Ryzen AI n'est jamais utilisé. L'upscaler NPU temps réel d'AMD lui-même
> (REAPPEAR) est **XDNA2, Windows, sur de la vidéo**, et AMD lui-même qualifie
> l'upscaling NPU en jeu de *« orientation future. »*

| Application | Faisabilité | Comment (chemin concret) | Note |
|---|---|---|---|
| STT vocal / push-to-talk local comme **compagnon hors-processus** | 🟡 constructible | **Encodeur** Whisper (lourd en GEMM) compilé via iree-amd-aie dans un daemon Linux : lecture du micro via PipeWire → émission de texte sur un socket local → le jeu/overlay le consomme. | **Le seul usage NPU réaliste lié au jeu.** Hors de la boucle de rendu, tolérant à ~100–300 ms de latence, natif Linux (le mur Proton ne s'applique pas). Porter l'encodeur vers XDNA1 est la partie difficile. |
| PNJ neuronal / IA ennemie (intention, décisions tactiques) | 🟡 constructible | Un service compagnon Linux exécute une petite policy/MLP via iree-compile ; le jeu (mod/overlay) l'interroge sur un socket. Au tour par tour / à l'échelle de la seconde uniquement. | La latence IPC + dispatch exclut le combat à 60 Hz par tick. Motif de mod DIY, rien ne livre cela. |
| Contenu procédural (textures/niveaux) au **chargement** | 🟡 constructible | Générer hors ligne / au chargement du niveau dans un processus Linux natif ; le jeu charge les assets. Tolérant à la latence. | Esquive à la fois le mur Proton et le budget de trame. Petits/moyens réseaux uniquement. |
| Upscaling ML hors-ligne/par lots de **captures/screenshots** (pas en direct) | 🟡 constructible | Capture sur disque → petite pile conv de style ESRGAN compilée en `.vmfb` → exécution avec `--device=amdxdna`. | Faisable uniquement *parce que* c'est hors ligne. Le chemin Vulkan (Real-ESRGAN-ncnn) est bien plus simple/rapide aujourd'hui. |
| Co-pilote LLM local **à côté** (pas à l'intérieur) du jeu | 🟡 constructible | Petit modèle quantifié comme service Linux natif ; un overlay/bot Discord le consomme ; libère le 780M. | tok/s modeste ; mise en route depuis les sources puisque FastFlowLM/Lemonade refusent XDNA1. |
| TTS neuronal en jeu pour les répliques de PNJ | 🟠 nécessite XDNA2/Windows | Architecturalement correct comme daemon compagnon, mais les vocodeurs VITS/transformer sont largement non implémentés sur XDNA1. | Le TTS CPU est plus simple aujourd'hui. |
| Super-résolution / upscaling ML **en jeu** par trame | ⛔ non adapté | Le jeu ne peut pas atteindre `/dev/accel/accel0` sous Proton ; capture externe→upscale→réinjection fait exploser le budget de 16 ms ; les kernels conv SR pour XDNA1 ne sont pas écrits. | FSR4 = GPU ; REAPPEAR = XDNA2/Windows. |
| Génération de trames | ⛔ non adapté | Nécessite des vecteurs de mouvement/flux optique liés au pipeline de rendu (GPU). Aucun accès au pipeline sous Proton ; les aller-retours par trame ajoutent de la latence. | Aucun produit de frame-gen n'utilise un NPU. |
| Animation à l'exécution / IK neuronale | ⛔ non adapté | Couplage moteur serré par trame + bac à sable Proton = aucun chemin à l'exécution. Outillage hors ligne uniquement. | |
| Upscaler de capture externe en temps réel via le NPU | ⛔ non adapté | Les seuls upscalers temps réel fonctionnels (Anime4K, waifu2x/Real-ESRGAN/RIFE sur ncnn-vulkan) sont GPU/Vulkan **sans backend XDNA**, et lutteraient contre le 780M. | Vous écririez de nouveaux kernels conv MLIR-AIE *et* perdriez quand même face à la latence. |
| Anti-triche via IA NPU sur appareil | ⛔ non adapté | Hors sujet : l'anti-triche noyau est Windows uniquement ; EAC/BattlEye sur Proton sont des choix de politique en mode utilisateur. Aucun anti-triche n'utilise un NPU. | |

---

## Pour les développeurs d'applications (basse consommation, toujours actives)

C'est là que l'atout perf-par-watt du NPU paie réellement : une charge de travail **stable, à
faible duty cycle** dont le cœur lourd est de **forme conv ou matmul**, câblée
dans la plomberie média Linux standard. La distinction honnête est **forme conv/matmul vs
récurrente**, pas audio vs vision.

**Surfaces d'intégration (toutes standard Linux) :**
- **Audio** → PipeWire `pw_filter` / `module-filter-chain` (le même hook
  qu'utilise le plugin LADSPA de DeepFilterNet) → exposer un micro virtuel.
- **Caméra** → capture via GStreamer/v4l2 → exécuter le NPU → écrire vers un **v4l2loopback**
  `/dev/videoN` (`exclusive_caps=1`) que Zoom/Chrome/OBS lisent.
- **Daemon générique** → l'API C du runtime IREE (créer le périphérique HAL `amdxdna` → charger
  le `.vmfb` → invoquer), modelé sur `samples/simple_embedding/simple_embedding.c`.

| Application | Faisabilité | Comment (chemin concret) | Note |
|---|---|---|---|
| Flou d'arrière-plan webcam / arrière-plan virtuel | 🟡 constructible | MediaPipe Selfie Segmentation (encodeur-décodeur conv de classe MobileNetV3, 256×256). Exécuter le backbone conv (bf16) sur NPU ; redimensionnement + composition CPU ; sortie vers v4l2loopback. | Conv pure → correspond au `conv_2d_nhwc_hwcf` pris en charge. Les formes non multiples de 128 nécessitent du tiling ; les étages depthwise sont 🟡 (fragiles). |
| Suppression de bruit du micro comme micro virtuel | 🟡 constructible | **DeepFilterNet** (encodeur-décodeur conv), **pas** le RNNoise classique. Gardez STFT/ERB + gating sur CPU ; déchargez les blocs conv (bf16) sur NPU ; callback PipeWire `pw_filter`. Regroupez les trames. | Le gain est la **batterie**, pas la latence — la version CPU est déjà en temps réel. La deadline dure de <10 ms + la surcharge de dispatch sont le défi. |
| Classification / auto-étiquetage d'images sur appareil | 🟡 constructible | MobileNetV3 / EfficientNet-Lite : backbone conv (`conv_2d_nhwc_hwcf`) + tête matmul sur NPU ; traitement par lots sur votre bibliothèque à faible duty cycle ; redimensionnement/normalisation sur CPU. | Meilleure adéquation vision **en bf16**. La conv *quantifiée* i8 + l'épilogue de requant sont **compile-only en CI** — validez-les vous-même avant de compter sur l'i8. |
| Embeddings de recherche d'images sémantique (tour image MobileCLIP-S0) | 🟡 constructible | Backbone conv + matmul de projection finale → vecteurs de longueur fixe via l'API C ; stockage dans sqlite/faiss sur CPU. Indexer une fois, requêtes bon marché. | Tâche d'arrière-plan idéale à faible duty cycle. Les tours **transformer** texte nécessitent de l'attention → précalculez hors appareil ou gardez sur CPU. |
| OCR sur appareil (captures/scans) | 🟡 constructible | Style CRNN/PaddleOCR : extracteur de caractéristiques conv sur NPU ; décodage CTC/séquence + tout BiLSTM sur CPU. Regroupez les crops de lignes de texte. | Le reconnaisseur récurrent **ne peut pas** vivre sur le NPU (softmax/attention bloqués). |
| Backbone de détection d'objets (caméra intelligente à cadrage automatique) | 🟡 constructible | NanoDet/YOLO-nano : backbone+neck conv sur NPU ; décodage d'ancres + NMS sur CPU ; sortie v4l2loopback. | Le calcul NMS/ancres est lourd en contrôle → CPU. Les formes de feature-map atypiques nécessitent du réglage de tiling. |
| Détection de présence / regard pour l'économie d'énergie | 🟡 constructible | Minuscule CNN visage/regard à 2–5 fps : détecteur conv sur NPU ; sur « regard détourné N s » → action CPU (atténuation DPMS / verrouillage / pause). | Le faible fps **masque la surcharge de dispatch** → l'un des builds les plus indulgents ; la perf/watt est la plus forte à faible duty cycle. |
| Animation à l'exécution / IK neuronale dans un moteur | ⛔ non adapté | Couplage moteur par trame ; faisable uniquement comme outillage de contenu hors ligne. | |
| **RNNoise** classique (GRU) ou **Silero VAD** comme charge de travail NPU | ⛔ non adapté | Gardez sur CPU (RNNoise tourne déjà à ~60× le temps réel). Pour le rehaussement de parole sur NPU, passez à **DeepFilterNet basé sur conv**. | GRU/LSTM sont intrinsèquement séquentiels (le pas de temps dépend de l'état caché précédent) ; la surcharge de dispatch domine ; aucun abaissement récurrent n'existe. |

---

## Pour les apprenants

Le NPU est un véritable périphérique programmable de dataflow spatial vers lequel vous pouvez compiler et
**regarder s'exécuter** — un excellent moyen d'apprendre AIE / MLIR / le dataflow sans matériel
en cloud.

| Application | Faisabilité | Comment (chemin concret) | Note |
|---|---|---|---|
| Apprendre AIE / le dataflow spatial en mutant un matmul fonctionnel | ✅ fonctionne aujourd'hui | Partez de [`scripts/run-matmul.sh`](../scripts/run-matmul.sh) et [`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) ; changez formes/dtypes ; recompilez ; exécutez sur `--device=amdxdna`. | Le seul palier empiriquement vérifié sur cette machine. |
| Benchmarker matmul/conv selon formes et dtypes | ✅ fonctionne aujourd'hui | `BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024` ; comparez i32 vs bf16, observez dispatch-bound vs compute-bound. | Enseigne pourquoi bf16 est natif et pourquoi les petits kernels sont limités par la surcharge. |
| Écrire votre propre kernel conv2d / élémentaire fusionné | 🟡 constructible | Écrivez du MLIR `linalg.conv_2d_nhwc_hwcf` ou matmul+generic ; compilez `conv-decompose`/`pack-peel` ; vérifiez vs une référence CPU. | La conv simple est vérifiée ; conv quantifiée/softmax sont expérimentales. |
| Construire un minuscule modèle de bout en bout (MLP quantifié / CNN à 2–3 couches) | 🟡 constructible | Écrivez chaque couche en MLIR linalg pris en charge (sur le modèle de `three_matmuls.mlir`) ; compilez vers un seul `.vmfb` ; exécutez le graphe de dispatch sur NPU. | Pas d'import `.onnx` sur ce build ; les ops non prises en charge sont des **erreurs de compilation**, pas des replis. |
| Importer un vrai modèle ONNX/PyTorch et cibler le NPU | 🟠 nécessite une reconstruction (+ gros manques d'ops) | Reconstruisez IREE avec `IREE_INPUT_TORCH/ONNX=ON` + bindings Python pour obtenir `iree-import-onnx` ; attendez-vous à ce que les ops attention/layernorm/softmax/embedding/forme-dynamique **échouent à la compilation** pour AIE. | Les frontends sont désactivés dans ce build par conception ; importer ≠ exécuter. |
| Contribuer à la couverture XDNA1-sous-Linux en amont | ✅ fonctionne aujourd'hui | Exécutez des résultats sur votre propre machine XDNA1 ; déposez des rapports matériels / tests de nouvelles ops. La CI Phoenix existe mais la couverture communautaire est mince. | Chaque résultat aide ; voir [`CONTRIBUTING.md`](../CONTRIBUTING.md). |
| Exécuter un LLM/Whisper pour « apprendre l'IA NPU » | ⛔ non adapté | Mauvais outil — utilisez l'iGPU 780M pour le modèle, et le NPU pour les *primitives*. | Ne commencez pas votre parcours NPU en essayant de servir un transformer. |

---

## Construisez votre propre primitive NPU (livre de recettes)

Le pipeline générique pour transformer l'étage lourd d'un modèle en une primitive NPU que vous
intégrez dans un daemon :

**1. Choisissez l'étage lourd et parallèle du modèle.** Il doit être de **forme matmul / conv
simple / élémentaire fusionnée**. Les étages récurrents (GRU/LSTM) et attention/softmax restent
sur CPU. Gardez le pré/post-traitement (STFT, redimensionnement, NMS, tokenisation) sur CPU.

**2. Exprimez-le en MLIR de niveau linalg.** Partez de
[`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) (matmul) ou d'un
template `conv_2d_nhwc_hwcf`. **Préférez `bf16`** (le type natif AIE, ~220 GFLOP/s).
La quantification i8 fonctionne pour matmul ; la *conv quantifiée* i8 et l'épilogue de requant
i8 sont expérimentaux, alors **vérifiez-les contre une référence CPU avant de
compter dessus**. (Ce build ne peut pas importer `.onnx`/PyTorch — fournissez-lui du MLIR.)

**3. Compilez pour le NPU.** Le jeu de flags vérifié
([`scripts/run-matmul.sh`](../scripts/run-matmul.sh), [`docs/GOTCHAS.md`](GOTCHAS.fr.md)) :

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

**4. Vérifiez sur une entrée connue.**

```bash
iree-run-module --device=amdxdna --module=model.vmfb \
  --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4   # cols=4 NOT 5, or ert state 8 timeout
```

**5. Intégrez dans un daemon / graphe média.** Câblez le `.vmfb` via :
- **CLI** (`iree-run-module`) pour les jobs batch / scripts rapides ; ou
- **API C du runtime IREE** — créez le périphérique HAL `amdxdna`, chargez le module,
  résolvez la fonction, invoquez (sur le modèle de `simple_embedding.c`). **Regroupez les trames
  par dispatch** pour amortir la surcharge de soumission de ~quelques centaines de µs, et gardez un **chemin
  de repli CPU**.
- Puis raccordez-le à **PipeWire** (`pw_filter` / `module-filter-chain` → micro virtuel)
  ou **GStreamer + v4l2loopback** (→ caméra virtuelle), ou simplement un socket.

> Scripts du dépôt sur lesquels bâtir : [`check-npu.sh`](../scripts/check-npu.sh) (est-il
> vivant ?), [`enable-npu.sh`](../scripts/enable-npu.sh) (groupe render / memlock /
> XRT), [`build.sh`](../scripts/build.sh) (le build depuis les sources avec tous les
> contournements), [`run-matmul.sh`](../scripts/run-matmul.sh) (la recette de compile+exécution).
> Le compilateur hôte doit être **gcc** (clang21 segfaulte en liant
> `libIREECompiler.so`).

---

## Par où commencer (par public)

- **Constructeurs d'agents :** construisez une primitive **mot-clé d'activation / KWS** (conv/FC, toujours active)
  ou un **reranker bi-encodeur** (matmul par lots) — les meilleures adéquations NPU. Exécutez le
  LLM lui-même sur l'iGPU 780M.
- **Joueurs :** le seul build réaliste est un **daemon compagnon vocal (STT) hors-processus**
  sur un socket. Traitez le NPU comme un side-car, jamais à l'intérieur de la boucle de rendu.
- **Développeurs d'applications :** commencez par le **flou d'arrière-plan** (caméra → v4l2loopback) ou un
  **classifieur de photos** en **bf16** — de forme conv, tolérant à la latence, victoires perf/watt.
- **Apprenants :** mutez [`run-matmul.sh`](../scripts/run-matmul.sh), benchmarkez
  bf16 vs i32, puis écrivez votre propre kernel conv2d ; passez ensuite à un minuscule graphe MLP.

## 🔇 Mesuré : le NPU perd face au CPU pour l'audio

Nous l'avons mesuré sur un 7840U. Une **trame entière de débruiteur CPU (8 layers) = 0.063 ms**,
alors qu'un **unique dispatch NPU = 3.8 ms** — **~480× plus lent**, et un vrai débruiteur
nécessite de nombreux dispatches/trame (≫ le budget temps réel de 10 ms). Les trames audio sont
minuscules, donc la latence est **limitée par la surcharge de dispatch** et l'avantage de débit du NPU
ne s'applique jamais ; RNNoise (GRU) n'a aucun abaissement NPU du tout. **Utilisez le CPU** pour la
suppression de bruit en temps réel — p. ex. RNNoise via un micro virtuel PipeWire `module-filter-chain`
(`librnnoise_ladspa.so`, label `noise_suppressor_mono`, exposé comme `Audio/Source` via
`playback.props`). Gardez le NPU pour la vision/matmul ; voilà *pourquoi* les lignes audio ci-dessus
restent sur le CPU.

## Liste honnête « pas la peine de s'y mettre sur XDNA1+Linux pour l'instant »

- **Servir un LLM / Whisper / Stable Diffusion sur le NPU.** Utilisez l'iGPU, ou
  Windows/XDNA2.
- **Prefill *ou* décodage LLM sur le NPU** — le prefill nécessite de l'attention (absente),
  le décodage est limité par la bande passante (l'iGPU gagne).
- **Tout ce qui implique attention/transformers comme dispatch NPU** — aucune op d'attention,
  softmax e2e désactivé (iree#21633).
- **Importer un `.onnx`/PyTorch arbitraire et « le faire juste tourner »** — pas d'importateur dans
  ce build ; les ops non prises en charge sont des erreurs de compilation, pas des replis.
- **Upscaling ou frame-gen en jeu / par trame** — bac à sable Proton + latence +
  FSR4-est-GPU. Ça n'arrivera pas ici.
- **Modèles GRU/LSTM (RNNoise classique, Silero VAD) sur le NPU** — séquentiels,
  pas d'abaissement récurrent ; gardez sur CPU.
- **Compter sur la conv quantifiée i8 ou l'épilogue de requant i8** sans le vérifier
  vous-même — ce sont des fixtures compile-only/orphelines en CI aujourd'hui.

---

*Légende des niveaux de confiance : ✅ fonctionne aujourd'hui (vérifié sur cette machine) · 🟡 constructible /
expérimental (vraie ingénierie, ops prises en charge) · 🟠 nécessite XDNA2 ou Windows · ⛔
non adapté à un NPU. Vérifié sur un Ryzen 7 PRO 7840U (Phoenix/XDNA1), Ubuntu
26.04, kernel 7.0, XRT 2.21, `iree-amd-aie` HEAD `fddfec1b`, le 2026-06-22.
`iree-amd-aie` est en phase précoce et évolue vite — les flags et la couverture d'ops dérivent.*
