**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Que peut-on construire avec un NPU XDNA1 sous Linux ?

Voici une carte pratique pour les propriétaires de portables Phoenix, comme le
Ryzen 7 7840U. Il ne s'agit pas de prétendre que tous les modèles sont prêts à
l'emploi. Il s'agit de transformer le silicium déjà présent dans nos machines
en laboratoire Linux ouvert : exécuter une étape utile, comparer chaque sortie
à une référence CPU fiable, la composer avec le CPU et l'iGPU, puis publier
assez de preuves pour que la personne suivante puisse poursuivre.

Tout contenu créé dans ce dépôt est sous licence MIT : **chacun peut l'utiliser,
le copier, le modifier, le forker, le publier et le redistribuer selon les
conditions de la licence.** La mission est exposée dans l'
[Open NPU Lab](OPEN-NPU-LAB.md), et les sources primaires et pistes connexes
figurent dans [Research branches](RESEARCH.md).

## Lire le niveau de preuve avant la capacité

- **Matériel du dépôt :** ce dépôt a exécuté le code sur le NPU nommé et vérifié
  le résultat complet. Le verrou actuel est attesté sur Strix Point `npu4` ;
  Phoenix dispose de précieux résultats matériels antérieurs, mais attend
  encore une nouvelle exécution avec le verrou courant.
- **Matériel upstream :** un projet amont l'a exécuté sur matériel. C'est une
  voie à reproduire, pas un résultat automatiquement acquis à ce dépôt.
- **Gabarit / plomberie :** dispatch NPU ou E/S Linux réels, mais avec des poids
  synthétiques ou une opération illustrative plutôt qu'un produit entraîné.
- **Compilation seule / projet :** les barrières d'exécution matérielle et de
  justesse numérique n'ont pas encore été franchies.

Compiler n'est pas exécuter ; exécuter n'est pas prouver la justesse ; le temps
d'un noyau n'est pas un résultat applicatif. Ce dépôt n'a pas encore mesuré
l'énergie du NPU et ne promet donc aucun gain d'autonomie.

## Il existe plusieurs voies logicielles ouvertes

Le plafond d'opérateurs étroit décrit par les anciennes versions de cette page
concerne le **backend `iree-amd-aie` épinglé par le dépôt au commit `fddfec1b`**,
pas tout l'écosystème XDNA1.[^iree-amd-aie]

| Voie | Ce que disent les preuves | Limite |
|---|---|---|
| `iree-amd-aie` épinglé par ce dépôt | Le dépôt vérifie des matmuls bf16/i8/i32 soigneusement façonnés, le dispatch persistant et des exemples hybrides. La voie conv est étroite et dépend de la cible. | La preuve matérielle du verrou exact courant porte sur `npu4` ; les résultats publiés du 7840U utilisaient l'ancien instantané fonctionnel. Les régions importées non prises en charge ne basculent pas silencieusement sur le CPU. |
| Voie `mlir-aie` 1.4.1 épinglée par ce dépôt | Des noyaux IRON directs et des exemples upstream ont tourné sur la machine Strix Point du dépôt ; cette voie bas niveau convient aux auteurs qui contrôlent placement et transferts. | Cette voie exacte n'a pas été rejouée sur le matériel XDNA1 du dépôt. |
| [`amd/IRON`](https://github.com/amd/IRON) en mouvement | Au commit exact `cdc48e93`, le workflow matériel Phoenix d'AMD du 2026-08-15 annonce, avec ses cinq itérations par défaut, **2 105 exécutions de cas réussies / 45 ignorées** : **421 configurations réussies distinctes / 9 skips distincts**. La couverture AIE2 réussie comprend GEMM/GEMV bf16, déquantification Q4NX, softmax, RoPE, RMSNorm, LayerNorm, activations, transpose et variantes SwiGLU decode/prefill.[^iron-phoenix] | C'est une forte **preuve Phoenix upstream**, pas une réexécution XDNA1 exact-v1 de ce dépôt ni un LLM complet. Les 9 skips distincts sont 3 configurations MHA, 3 streaming-SwiGLU-prefill et 3 GEMV+GELU, chacune répétée cinq fois pour former trois groupes de 15 exécutions. Le tableau MHA/GQA reste réservé à AIE2P. |

La correction essentielle est simple : « ce backend épinglé ne lower pas une
opération » ne signifie **pas** « XDNA1 ne peut pas exécuter ce type de noyau ».
Toute affirmation doit conserver sa chaîne d'outils, son appareil, son test et
son oracle numérique exacts.

## ONNX : importer, extraire, puis assumer la composition

Le [`scripts/build.sh`](../scripts/build.sh) actuel installe un
`iree-import-onnx` épinglé séparément ; le flux du dépôt ne nécessite ni
reconstruction d'IREE ni détour par les bindings Python.
[`tools/npu-trim`](../tools/npu-trim/) peut importer ou examiner un graphe,
identifier des formes matmul/conv indépendantes, produire des noyaux propres et
tester la compilation de chacun pour la cible détectée.

Il ne reconstruit ni n'exécute volontairement un modèle entier arbitraire.
L'application possède les poids, les conversions padding/layout, les
opérations non prises en charge, le fallback CPU et l'orchestration. L'exemple
[`examples/onnx-mlp`](../examples/onnx-mlp/) constitue le contrat exécutable :
matmul NPU → ReLU CPU → matmul NPU, vérifié face à un oracle CPU bf16.

```text
ONNX ── importateur épinglé ──▶ npu-trim ──▶ VMFB matmul/conv marqués par cible
                                                  │
                      poids, layouts et ordonnancement possédés par l'application
                                                  │
                            noyaux NPU + glue/fallback CPU explicite
```

## Un système LLM local peut employer les trois processeurs

Une contribution du NPU reste utile sans lui confier l'intégralité du LLM :

```text
microphone / caméra / documents / événements UI
                    │
                    ▼
      NPU : déclencheur permanent, bloc de features,
            bloc linéaire/fusionné, classification ou scoring
                    │
                    ▼
      CPU : E/S, tokenisation, top-k, outils, politique,
            opérateurs non pris en charge et fallback fiable
                    │
                    ▼
      iGPU : runtime LLM local quantifié et éprouvé
             pour prefill et génération de tokens
```

À mesure que mûrissent les noyaux ouverts d'attention, normalisation et
quantification, un bloc mesuré peut migrer du CPU/iGPU vers le NPU sans jeter
l'application. Deux résultats publiés montrent qu'il s'agit d'une véritable
voie de recherche :

- Rösti et Franz ont placé les GEMM du **fine-tuning de GPT-2 124M** sur un NPU
  Phoenix de première génération, le CPU gardant le reste. Ils rapportent plus
  de **2,8×** pour les multiplications de matrices déportées, **1,7×** et
  **1,2×** de débit bout en bout sur secteur et batterie, et **1,4×**
  d'efficacité énergétique sur batterie dans leur configuration.[^phoenix-gpt2]
  Ce sont les chiffres des auteurs, pas des mesures du dépôt.
- STEEL rapporte en moyenne une **latence XDNA1 améliorée de 9,6× face à DATO**,
  sa référence d'attention XDNA1 antérieure. Séparément, sur HX 370/XDNA2, il
  rapporte une consommation réduite de **9,17×** et **1,75×** face à ses
  références CPU et GPU, ainsi que **22,8×** face à son implémentation XDNA2
  couche par couche.[^steel] Ne pas mélanger l'expérience de latence XDNA1 et
  celle d'énergie XDNA2.

## Ce que vous pouvez exécuter, remplacer ou étendre

| Point de départ | Ce qui est réel aujourd'hui | Prochaine étape utile |
|---|---|---|
| [`local-rag-sidecar`](../examples/local-rag-sidecar/) | **Matériel du dépôt (`npu4`) :** hashing CPU déterministe → matrice de score bf16 NPU persistante 256×256 → top-k CPU → endpoint LLM optionnel, limité par défaut aux hôtes de bouclage littéraux `127.0.0.1` ou `::1` ; les endpoints distants exigent l'activation explicite de `--allow-remote`. Les 65 536 sorties sont vérifiées. | Remplacer le hashing par des embeddings entraînés sous licence ou une projection, grouper les requêtes et rejouer sur XDNA1. Pour une petite requête unique, un produit scalaire CPU sera probablement plus rapide ; l'exemple prouve l'intégration et la justesse, pas une accélération universelle. |
| [`wake-word`](../examples/wake-word/) | **Gabarit :** vrai log-mel CPU et trois dispatchs dense NPU persistants ; les poids fournis forment un filtre adapté illustratif. | Entraîner et licencier de vrais poids wake-word/intent, tester l'audio réel et les faux positifs, puis réveiller un assistant local CPU/iGPU. |
| [`onnx-mlp`](../examples/onnx-mlp/) | **Gabarit :** véritable forward hybride importé à deux matmuls, avec contrôles CPU par dispatch et bout en bout. | Substituer une tête entraînée d'intent, routage, sûreté ou projection tout en conservant noyaux spécifiques aux formes et oracle. |
| [`npu-camera`](../examples/npu-camera/) | **Plomberie applicative :** GStreamer → NPU persistante → `v4l2loopback` ; l'opération NPU de démonstration est un flou rectangulaire à deux passes, pas une segmentation. | Remplacer une étape par un bloc vision entraîné et pris en charge ; conserver resize, composition et fallback sur CPU. |
| [`npu-runner`](../tools/npu-runner/) | **Matériel du dépôt :** charger un VMFB une fois et l'invoquer depuis C ou Python, avec contrôle de toute la sortie. | Construire un daemon local de scoring groupé, classification de capteurs ou sidecar de modèle réutilisable. |
| [`mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **Laboratoire de noyaux directs :** code spatial inspectable et exécution multi-colonnes. | Reproduire un opérateur AIE2 d'AMD IRON sur Phoenix et publier placement, transferts, référence CPU et première forme en échec. |
| [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | **Compilation seule :** sonde front-end W4A16 externe épinglée. | Terminer lowering, édition de liens, empaquetage des poids, exécution NPU et justesse tenant compte de la quantification avant toute affirmation de performance. |

## Autres directions applicatives

| Besoin humain | Expérience à la taille du NPU | À garder explicitement ailleurs |
|---|---|---|
| Assistant local privé | wake word, tête intent/sûreté, scoring de recherche groupé | orchestration CPU ; génération CPU/iGPU |
| Recherche personnelle | projection et matrice de score requête×documents | parsing, stockage, top-k et génération finale |
| Accessibilité | classifieur acoustique, présence, geste ou événement UI | acquisition et politique applicative |
| Caméra/vie privée | étape conv ou linéaire prise en charge | capture, resize, composition, `v4l2loopback` |
| Audio | bloc conv/linéaire de features ou débruitage groupé | PipeWire, STFT et fallback temps réel strict |
| Jeux | compagnon Linux natif pour voix, intent ou contenu hors ligne | jeu/boucle de rendu Proton et tâches critiques par frame |
| Recherche compilateur | fusion, tiling, flux de paquets, noyaux quantifiés | références CPU et bancs reproductibles |

Les limites négatives factuelles restent importantes. Il n'existe ici aucune
voie livrée pour augmenter les FPS, générer des frames ou upscaler dans la
boucle de rendu ; sous Proton, un compagnon Linux natif séparé est la frontière
d'expérimentation pratique. Les charges GRU/LSTM classiques exigent leur propre
lowering ou restent sur CPU. Les graphes transformer/Whisper/vision arbitraires
ne sont pas des modèles entiers prêts à déposer sur le backend épinglé. Ce sont
des interfaces à explorer, pas des raisons de laisser le composant inutilisé.

## Échelle d'expériences reproductibles

Commencez par les contrôles stricts du périphérique et de la justesse :

```bash
./scripts/check-npu.sh --strict
./scripts/run-matmul.sh bf16 512 512 512
```

Choisissez ensuite une jointure applicative existante :

```bash
./examples/local-rag-sidecar/run.sh --cpu-only --selftest
./examples/local-rag-sidecar/run.sh --selftest       # NPU réelle prise en charge
~/src/iree-aie-venv/bin/python tools/npu-trim/npu_trim.py model.onnx
```

Pour toute extension, publiez l'identité du périphérique, le commit/verrou
exact, les licences du modèle et des données, formes et précision, tolérance
sur toute la sortie, logs bruts, latence et—seulement après mesure—énergie du
système. Gardez un fallback CPU. Un échec minimal avec entrée reproductible est
aussi une contribution à la recherche ouverte.

## Pour continuer

- Mission, contrat de preuve et parcours de contribution :
  [Open NPU Lab](OPEN-NPU-LAB.md)
- Articles primaires, code upstream et questions suivantes :
  [Research branches](RESEARCH.md)
- Cibles par génération et preuves XDNA2 actuelles :
  [guide XDNA2](XDNA2.fr.md)
- Suite plus longue des jalons transformer :
  [LLM roadmap](LLM-ROADMAP.md)

L'objectif n'est pas une démonstration consacrée. Ce sont de nombreuses
expériences inspectables qui permettent aux propriétaires, étudiants et
chercheurs de réutiliser un NPU au lieu de l'oublier. Prenez le code, changez-le
et faites de votre résultat le point de départ de quelqu'un d'autre.

## Sources primaires

[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie). Le verrou du dépôt est `fddfec1be6ceefbdb890079d957947dfa1fe0848` ; cette section décrit ce backend, pas toutes les voies de compilation XDNA.
[^iron-phoenix]: AMD, [`IRON` au commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) et [workflow matériel Phoenix extensive 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15 : avec les cinq itérations par défaut du workflow, 2 105 exécutions de cas réussies et 45 ignorées représentent 421 configurations réussies distinctes et 9 skips distincts. La CI upstream évolue ; épinglez le commit pour reproduire.
[^phoenix-gpt2]: A. Rösti et M. Franz, [« Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools »](https://arxiv.org/abs/2504.03083), FCCM 2025. Phoenix de première génération, Ryzen 9 7940HS, fine-tuning hybride de GPT-2 124M.
[^steel]: V. J. B. Jung et al., [« STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU »](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. L'article désigne [`amd/IRON`](https://github.com/amd/IRON) comme voie d'implémentation open source.
