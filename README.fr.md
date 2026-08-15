**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Calcul Ryzen AI **XDNA1 + XDNA2** ouvert sous **Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Jonas-Augustinus-Linus/ryzen-npu-linux)](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1 and XDNA2](https://img.shields.io/badge/NPU-XDNA1%20%2B%20XDNA2-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

Une voie ouverte et reproductible, de *visible par le pilote mais inactif* au
calcul NPU réel vérifié par référence CPU sous Linux. Elle conserve la voie
XDNA1/Phoenix d'origine et porte le même contrat détection → compilation →
vérification → runner persistant sur Strix Point XDNA2 (`RyzenAI-npu4`).

> **Pourquoi ce dépôt existe.** Le silicium **XDNA1** de première génération des
> portables Ryzen 7040/8040 — dont le 7840U — peut être visible par le pilote mais
> laissé inactif par les produits Linux clés en main actuels. Au 15 août 2026,
> la page officielle d'AMD cite STX/KRK, pas Phoenix.[^amd-linux-support] Cette
> limite produit ne rend pas le périphérique inutile. Il existe **deux voies
> ouvertes de plus bas niveau** : `iree-amd-aie`, que ce dépôt verrouille et
> empaquette en chemin IREE reproductible, et la pile de noyaux directs
> [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie), dont ce dépôt épingle
> la voie API Python/compilateur IRON en version 1.4.1. La bibliothèque plus
> récente d'opérateurs et d'applications [`amd/IRON`](https://github.com/amd/IRON)
> est un **projet distinct bâti sur les bindings du langage MLIR-AIE**, pas un
> renommage de `Xilinx/mlir-aie`. Ce dépôt fournit des chemins vérifiés par CPU
> et des limites de preuve explicites, pas un serveur clé en main pour tout modèle.

> 🆕 **Sur XDNA2 Strix Point (`RyzenAI-npu4`) ?** La deuxième génération a renversé le
> paysage : l'inférence LLM clé en main existe désormais sous Linux
> (FastFlowLM/Lemonade), Ubuntu 26.04 fournit nativement l'userspace XRT — et
> l'outillage d'activation de ce dépôt y fonctionne **sans modification**
> (vérifié sur un Ryzen AI 9 HX PRO 370). **Le calcul aussi** : la voie
> mlir-aie/IRON tourne sur les 8 colonnes de Strix — GEMM i8 à 6.65 TOPS,
> MobileNet complet, notre noyau personnalisé avec une montée en charge de
> 8.0× sur les colonnes ([docs/MLIR-AIE.fr.md](docs/MLIR-AIE.fr.md)). Ce qui
> se transfère, ce qui change, et où s'est déplacée la frontière ouverte :
> **[docs/XDNA2.fr.md](docs/XDNA2.fr.md)**. Les appareils ultérieurs
> `npu5`/`npu6` ne sont ni associés ni revendiqués en silence ; voir la
> [matrice de support](docs/SUPPORT.md).

## 🌱 Pourquoi nous l'offrons librement

Achever la voie sur une seule machine n'est pas l'arrivée. Ce dépôt est sous
licence MIT et distribué gratuitement afin que les utilisateurs Linux puissent
examiner chaque couche, reproduire les preuves, modifier les noyaux et partager
leurs améliorations. Nous souhaitons que étudiants, développeurs indépendants,
chercheurs et petites équipes y bâtissent **de nombreux LLM et systèmes d'IA
locale différents** : agents privés, accessibilité, modèles multilingues,
services sobres, nouvelles quantifications et applications encore inimaginées.

**Toute personne peut utiliser, copier, modifier, forker, publier, redistribuer,
sous-licencier, enseigner avec ou exploiter commercialement ce travail** selon
la licence MIT. Conservez les mentions de droit d'auteur et de licence requises ;
le code tiers et les ressources de modèles gardent leurs propres licences.
Aucune autre permission n'est nécessaire et contribuer en retour est bienvenu,
mais facultatif.

C'est une fondation, pas l'affirmation que n'importe quel LLM fonctionne déjà de
bout en bout. Elle est concrète : détection stricte, builds épinglés, correction
par référence CPU, appels persistants C/Python, exemples réels et limites
d'échec publiques. La réussite, c'est que d'autres puissent poursuivre ce
travail. Entrez dans l'[Open NPU Lab](docs/OPEN-NPU-LAB.md) en anglais, remontez
chaque affirmation jusqu'au [registre de recherche](docs/RESEARCH.md), puis
choisissez une étape dans la [feuille de route LLM ouverte](docs/LLM-ROADMAP.md)
ou le [guide de contribution](CONTRIBUTING.md).

## 🎬 Démos

### XDNA2 / Strix Point — matériel réel

Les matmuls i32 et bf16 d'IREE sur `npu4` correspondent exactement à leurs
références CPU, le runner persistant vérifie les 16 384 sorties, et le noyau
IRON personnalisé passe sur les 8 colonnes avec XRT comme avec HRX :

![Démo XDNA2 Strix Point sur matériel réel avec comparaisons CPU exactes, vérification complète de npu-runner et validations IRON via XRT et HRX](docs/media/xdna2-compute.gif)

### XDNA1 / Phoenix — démos vérifiées d'origine

**Mécanique hybride — un MLP ONNX généré** (matmuls sur le NPU, `ReLU` sur le
CPU ; poids générés, pas une application entraînée ; correspond à sa référence
CPU à ~0.3% près) :

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python, **sur le NPU** | flou boîte 2D non-IA sur NPU, appliqué à trois motifs `videotestsrc` → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| pipeline de mot-clé — 3 couches denses NPU avec des **poids illustratifs non entraînés** | bf16 est la force native du NPU — jusqu'à **220 GFLOP/s** |
| ![wake-word demo](docs/media/wake-word.gif) | ![benchmark demo](docs/media/benchmark.gif) |
| transformer un vrai `.onnx` → MLIR ciblant le NPU (import hybride ; la couverture d'ops du codegen amd-aie compilé depuis les sources est la frontière) | extraire les matmuls **et convs** qui **se** compilent bien vers le NPU — `npu-trim` filtre les ops et émet des noyaux propres |
| ![onnx-import demo](docs/media/onnx-import.gif) | ![npu-trim demo](docs/media/npu-trim.gif) |

## ✅ Ce qui fonctionne (vérifié)

Compilé et exécuté **sur le NPU** (`--device=amdxdna`), résultats corrects,
reproductible :

| Charge de travail | Forme | Résultat | Débit (NPU) |
|---|---|---|---|
| matmul `i32` | 128×128×128 | ✓ exact | ~3,6 ms/itér, ~280/s |
| matmul `bf16 → f32` | 256×256×256 | ✓ exact (y compris fractionnaire) | ~2,9 ms/itér, ~350/s |

Machine testée : **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, XDNA1)
· Radeon 780M · Ubuntu 26.04 · noyau 7.0 · `amdxdna` intégré · XRT 2.21 · NPU FW 1.5.5.391**.
Ces mesures XDNA1 sont historiques et proviennent de la nightly de l'époque ; elles
n'ont pas encore été répétées avec le verrou exact v1 actuel, revalidé sur Strix.

## 📊 Tests de performance

De bout en bout sur le NPU via `iree-benchmark-module` (`--device=amdxdna`,
`npu1_4col`, 10 répétitions, moyenne). Le temps réel inclut le surcoût de
répartition côté hôte, si bien que les plus petits matmuls sont limités par la
répartition ; le calcul effectif augmente avec la taille.

| dtype | forme (M×N×K) | temps/itér | débit | calcul |
|---|---|--:|--:|--:|
| `i32` | 128×128×128 | 3.58 ms | 279 it/s | 1.2 GFLOP/s |
| `i32` | 256×256×256 | 8.08 ms | 124 it/s | 4.2 GFLOP/s |
| `i32` | 512×512×512 | 43.6 ms | 23 it/s | 6.2 GFLOP/s |
| `bf16→f32` | 256×256×256 | 2.86 ms | 350 it/s | 11.7 GFLOP/s |
| `bf16→f32` | 512×512×512 | 3.90 ms | 257 it/s | 68.8 GFLOP/s |
| `bf16→f32` | 1024×1024×1024 | 9.76 ms | 102 it/s | 220 GFLOP/s |

**Le bf16 est la force native du NPU** — ~220 GFLOP/s à 1024³ et continue de
monter en charge, tandis que `i32` (qui n'est pas le type natif de l'AIE)
plafonne autour de 6 GFLOP/s. Pour reproduire n'importe quelle ligne :
`BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`.


## 🚀 Démarrage rapide

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux

# Lire les prérequis hôte/disque/sudo, puis lancer le diagnostic strict en lecture seule.
less docs/SUPPORT.md
./scripts/check-npu.sh --strict

# Seulement en cas d'échec groupe/memlock/XRT : relire, exécuter, redémarrer une fois.
./scripts/enable-npu.sh

# Compiler la pile IREE/Peano épinglée dans versions.lock ; cela installe aussi
# libxrt-dev pour les vérifications hôte IRON natives de --full.
./scripts/build.sh

# Contrat public : détection -> références CPU -> runners natif/Python.
./scripts/verify-stack.sh --quick

# Optionnel : configurer la pile IRON épinglée séparément, puis tout vérifier.
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

## 🧰 Les outils

| Script | Ce qu'il fait |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Lecture seule : vérifie le pilote, le nœud de périphérique, le groupe render, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Corrige les 3 éléments qui bloquent un utilisateur non-root (groupe render, memlock, XRT). |
| [`scripts/detect-npu.sh`](scripts/detect-npu.sh) | N'associe que les couples VBNV/géométrie vérifiés à `npu1_4col` ou `npu4`. |
| [`scripts/build.sh`](scripts/build.sh) | Compile la pile IREE/Peano épinglée dans `versions.lock`. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Compile, exécute et compare toutes les sorties `i32`/`bf16` à la référence CPU. |
| [`scripts/verify-stack.sh`](scripts/verify-stack.sh) | Test matériel strict pour CLI, runner natif/Python et, en option, applications/IRON. |
| [`scripts/validate-repo.sh`](scripts/validate-repo.sh) | Vérifications de publication locales/CI sans matériel. |

## 🔬 Exemples et outils

- [`tools/npu-trim/`](tools/npu-trim/) — filtre un graphe importé et n'extrait
  que les matmuls/convs compilables pour la cible détectée ; ce n'est pas un
  runtime ONNX arbitraire.
- [`tools/npu-runner/`](tools/npu-runner/) — charge une VMFB une fois puis
  l'invoque de façon persistante en C et Python/ctypes.
- [`examples/local-rag-sidecar/`](examples/local-rag-sidecar/) — **intégration
  réelle du NPU dans une boucle RAG** : segmentation/hachage CPU → matrice de
  scores persistante NPU → top-k CPU → LLM local facultatif. Les caractéristiques
  ne sont pas des embeddings entraînés, une petite requête unique sera
  probablement plus rapide sur CPU, et le matériel XDNA1 avec le verrou actuel
  reste à tester ; la preuve actuelle en direct est XDNA2.
- [`examples/wake-word/`](examples/wake-word/) — trois couches denses NPU
  persistantes avec des poids de filtre illustratifs, **pas un vocabulaire de
  réveil entraîné**.
- [`examples/onnx-mlp/`](examples/onnx-mlp/) — véritable passage avant hybride
  avec un modèle **généré** : deux matmuls NPU, ReLU CPU explicite et référence CPU.
- [`examples/npu-camera/`](examples/npu-camera/) — véritable câblage GStreamer →
  NPU → `v4l2loopback` ; l'opération NPU actuelle est un **flou boîte non-IA**.

## 🧩 Seconde voie : `mlir-aie` (IRON)

`iree-amd-aie` (ci-dessus) compile des graphes IREE pris en charge ;
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) est la pile de plus bas
niveau que ce dépôt épingle en version 1.4.1. Sa voie API Python/compilateur
IRON permet d'**écrire directement des noyaux NPU** et de les exécuter via `pyxrt` ; elle
livre de véritables `programming_examples` ML. Des preuves matérielles existent pour les
**deux générations**, mais pas avec le même instantané de dépendances : les résultats
Phoenix/`npu1` sont historiques, tandis que le verrou exact v1 a été revalidé sur
Strix/`npu2` (détection automatique). Les rapports XDNA1 avec le pin actuel sont les
bienvenus. La configuration ne réutilise
le Peano d'iree-amd-aie que si sa version exacte de `llvm-aie` **et le commit de build de clang**
correspondent au pin `utils/peano-requirements.txt` de cette version de mlir-aie ; sinon elle
installe ce wheel épinglé dans le venv mlir-aie. Guide complet → **[docs/MLIR-AIE.fr.md](docs/MLIR-AIE.fr.md)**.

[`amd/IRON`](https://github.com/amd/IRON) est une bibliothèque distincte et plus
récente d'opérateurs et d'applications, bâtie sur les bindings du langage
MLIR-AIE ; ce n'est ni un renommage ni le nouvel emplacement de
`Xilinx/mlir-aie`. Cette bibliothèque mouvante est nettement plus large que la
voie de noyaux directs épinglée par cette version. Au
commit exact [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93), le workflow
Phoenix officiel d'AMD a rapporté **2 105 réussites et 45 éléments ignorés**,
sous forme d'exécutions de cas pytest. Avec cinq itérations par défaut, ces
totaux représentent **421 configurations distinctes réussies et 9 configurations
distinctes ignorées**, pas 2 105 tests différents. Les neuf skips sont trois
configurations MHA, trois streaming-SwiGLU et trois GEMV+GELU, chacune répétée
cinq fois.[^iron-phoenix-ci] La couverture AIE2 réussie et comparée au CPU inclut
GEMM/GEMV, déquantification Q4NX, softmax, RoPE, RMSNorm/LayerNorm, activations
et transposition. C'est une preuve Phoenix amont, ni la réexécution XDNA1 au
verrou actuel de ce dépôt ni un LLM complet ; GQA n'est pas établi par ce run.

```bash
./scripts/setup-mlir-aie.sh                 # mlir_aie wheel + py3.14 venv + compatible Peano
./scripts/run-mlir-example.sh ml/conv2d     # build for the detected NPU + run ON IT (pyxrt)
./examples/mlir-aie/relu_add/run.sh         # a custom hand-written fused kernel
```

Vérifié **sur le NPU** (XDNA1, `run_py` / `pyxrt`, sortie vs une référence (golden) torch/numpy) :

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 conv | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layers | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

Sur **XDNA2** (Strix Point, 8 colonnes / 32 tuiles, mlir-aie 1.4.1) : le GEMM
sur tableau entier atteint **6.65 TOPS** (i8) / **4.64 TFLOPS** (bf16 via bfp16),
les blocs LLM (softmax/RoPE/SwiGLU/RMSNorm) passent, **`ml/mobilenet` complet
s'exécute** (~176 ms — il ne *peut pas* tourner sur les 4 colonnes de Phoenix),
et notre noyau personnalisé monte en charge à **8.0×** sur les colonnes. Les
tableaux XDNA2 et le guide pas-à-pas pour écrire votre propre noyau sont dans
**[docs/MLIR-AIE.fr.md](docs/MLIR-AIE.fr.md)**.

## 🪤 Les pièges (pourquoi une compilation/exécution naïve échoue)

Tous les détails dans **[docs/GOTCHAS.fr.md](docs/GOTCHAS.fr.md)**. La liste courte :

1. **Utilisez `gcc`, pas `clang`, comme compilateur hôte.** clang 21 *plante (segfault)* en compilant MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Les bindings Python rencontrent `-Werror,-Wmacro-redefined` ; les outils CLI n'en ont pas besoin.
3. **Utilisez le Peano (`llvm-aie`) verrouillé.** `build.sh` installe et vérifie exactement le pin de `versions.lock` ; il échoue au lieu de choisir silencieusement une nightly plus récente.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** Vous sautez intentionnellement 3 sous-modules lourds.
5. **Compilez avec `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`) ou le dispatch expire (timeout).
6. ⚠️ **Exécutez avec `--amdxdna_n_core_cols=4`, pas 5.** Phoenix rapporte 5 colonnes brutes mais en utilise 4 (`npu1_4col`). Passer 5 → les cœurs se bloquent → timeout `ert state 8`.

## 🎯 Où pouvez-vous réellement utiliser cela ?

Guide complet public par public (jeux · agents IA · applications locales) avec notes de faisabilité → [docs/APPLICATIONS.fr.md](docs/APPLICATIONS.fr.md).

Voir **[docs/USE-CASES.fr.md](docs/USE-CASES.fr.md)**. Construisez un laboratoire
d'IA locale hybride : NPU pour les scores répétés, les étapes permanentes et les
blocs dense/conv vérifiés ; CPU pour les E/S, les règles et le repli ; iGPU pour
la génération de tokens. Le [sidecar RAG local](examples/local-rag-sidecar/)
montre ce partage dans le code. Il n'existe toujours pas ici de serveur XDNA1
clé en main pour un modèle complet ; l'efficacité énergétique reste un objectif
à mesurer, pas un résultat déjà prouvé.

## 📚 Contexte

Voir **[docs/BACKGROUND.fr.md](docs/BACKGROUND.fr.md)** pour XDNA1 vs XDNA2, pourquoi Linux est
difficile pour la première génération, et comment le HAL `amdxdna` communique avec `/dev/accel0`.

## 🧭 Où se situe ce projet (et ce qu'il n'est *pas*)

**Ce n'est pas le premier projet NPU-sous-Linux, et il n'invente aucune partie de la pile** —
le pilote, le compilateur et le runtime lui préexistent tous et font le gros du travail :

| Couche | Travaux antérieurs sur lesquels nous bâtissons / à côté desquels nous nous situons |
|---|---|
| Pilote noyau | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, dans la branche principale depuis Linux 6.14, énumère XDNA1 en tant que `/dev/accel/accel0` |
| Compilateur / runtime | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (pile API Python/compilateur IRON 1.4.1 épinglée), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — SDK/frameworks amont ciblant les générations XDNA |
| Bibliothèque plus récente d'opérateurs / applications | [`amd/IRON`](https://github.com/amd/IRON) — projet distinct bâti sur les bindings du langage MLIR-AIE, ni renommage ni nouvel emplacement de `Xilinx/mlir-aie` |
| Calcul XDNA1 + Linux antérieur | un article de recherche ([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — GPT-2 sur un Phoenix 7940HS via IRON), des tutoriels uniquement sur les primitives, le [récapitulatif XDNA du wiki Gentoo](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| LLM NPU clés en main sous Linux | [`FastFlowLM`](https://github.com/ROCm/FastFlowLM) et [`Lemonade`](https://github.com/lemonade-sdk/lemonade/blob/main/docs/guide/faq.md) exigent explicitement XDNA2 pour leurs chemins NPU ; AMD Ryzen AI Software 1.8 pour Linux ne liste que STX/KRK, pas Phoenix XDNA1 |

Ainsi, « premier NPU sous Linux », « premier compilateur » ou « premier à faire tourner XDNA1 » seraient
tous des affirmations exagérées — et nous ne les faisons pas.

**Ce que ce dépôt *est* :** une **recette + trousse à outils empaquetée,
reproductible et de bout en bout**. Elle a commencé par rendre le calcul réel
accessible sur XDNA1/Phoenix, oublié des piles clés en main, puis a donné à
Strix Point npu4 le même contrat public de correction. Les travaux antérieurs sont soit un **SDK/framework** en amont
(vous naviguez vous-même parmi les pièges de la compilation depuis les sources), soit une application
**XDNA2 uniquement**, soit un **article de recherche** (pas de dépôt prêt à l'emploi en un clic), soit un
chemin de calcul **Windows uniquement**. La particularité réside dans le *paquet* : les scripts
diagnostiquer→activer→compiler→exécuter, la **carte des pièges** de la compilation depuis les sources,
l'**exécuteur persistant C-API/ctypes** (~11× plus rapide que `iree-run-module` appel par appel), les
**exemples d'application** (mot de réveil, démon de caméra NPU), le **guide d'applications avec notes de
faisabilité honnêtes** (y compris le constat mesuré « le NPU perd contre le CPU pour l'audio »), et une
documentation en 5 langues.

> **Mise en garde honnête :** l'écosystème évolue vite et le travail privé ou
> interne reste invisible. Signalez les projets ou résultats récents à créditer
> ou comparer : une meilleure carte commune profite à tous.

## ⚖️ Avertissement

Notes communautaires, pas un produit AMD/Xilinx. `iree-amd-aie` est en phase précoce et
évolue vite ; les versions/flags dérivent. Les preuves matérielles sont datées et propres
à leurs pins : les résultats XDNA1/Phoenix sont historiques et proviennent de la nightly
de l'époque, tandis que le verrou exact v1 a été revalidé sur Strix Point XDNA2 jusqu'au
2026-08-15. Aucun résultat Hawk Point n'est encore consigné. Les résultats XDNA1 avec le pin
actuel et ceux d'autres systèmes XDNA1/XDNA2 sont bienvenus avec l'identité exacte du
périphérique et le journal de vérification.

## 🤝 Contribuer

La contribution la plus utile est **un résultat reproductible de votre propre
machine XDNA1 ou XDNA2**. Voir **[CONTRIBUTING.md](CONTRIBUTING.md)**. En bref :

- **Rapportez des résultats matériels** — votre puce / noyau / distribution et ce qui a fonctionné ou échoué (un gabarit d'issue est fourni).
- **Ajoutez des tests de performance** pour d'autres formes/dtypes, ou de **nouvelles ops** (conv, i8, …).
- **Corrigez ou affinez un [piège](docs/GOTCHAS.fr.md)**, durcissez les scripts, ou ajoutez/corrigez une traduction.
- Fork → branche → `scripts/validate-repo.sh` et, pour le matériel,
  `scripts/verify-stack.sh --quick` → PR décrivant exactement les tests.

## 📄 Licence

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — utilisez, copiez, modifiez,
forkez, publiez, redistribuez, enseignez ou commercialisez ce travail. Conservez
les mentions de droit d'auteur et de licence exigées par la licence.

Les scripts et la documentation de ce dépôt sont sous licence MIT. Ils compilent et pilotent des
projets tiers sous leurs propres licences — IREE et `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) — que ce dépôt ne redistribue pas.

[^amd-linux-support]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), consulté le 15 août 2026.
[^iron-phoenix-ci]: AMD IRON, [workflow Phoenix officiel 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
