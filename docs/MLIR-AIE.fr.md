**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# La voie `mlir-aie` (IRON) — écrivez des noyaux NPU, sur les deux générations

Le reste de ce dépôt compile [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) :
un **compilateur de graphes** qui abaisse des modèles entiers (PyTorch / ONNX) vers le NPU. Cette
page est la recette vérifiée de l'*autre* voie ouverte —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) et son eDSL Python **IRON**
— où vous **écrivez directement des noyaux NPU** et les exécutez via `pyxrt`.

Vérifiée sur les **deux générations de NPU**, mêmes scripts, même wheel :

> **XDNA1** — Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U (Phoenix, `npu1`) ·
> Ubuntu 26.04 · noyau 7.0 · XRT 2.21 · vérifié le 2026-06-24 (mlir-aie 1.3.x).
>
> **XDNA2** — Ryzen AI 9 HX PRO 370 (Strix Point, `npu2`, nom XRT
> `RyzenAI-npu4`) · Radeon 890M · Ubuntu 26.04 · noyau 7.0 · XRT natif d'Ubuntu
> 2.21.75 · NPU FW 1.1.2.64 · vérifié le 2026-08-15 (**mlir-aie 1.4.1**).

## iree-amd-aie vs mlir-aie — lequel choisir ?

| | `iree-amd-aie` (racine du dépôt) | `mlir-aie` / IRON (cette page) |
|---|---|---|
| Vous apportez | un graphe entier (`.onnx` / PyTorch) | une idée de noyau (dataflow + une fn de calcul C++) |
| Abstraction | compilateur de graphes MLIR | eDSL dataflow ObjectFifo (`aie.iron`) + `aiecc` |
| Hôte d'exécution | `iree-run-module` / l'exécuteur C-API | `pyxrt` (le design Python s'exécute lui-même) |
| Idéal pour | « exécuter mon modèle sur le NPU » | « écrire/posséder un noyau NPU spécifique », vrais blocs d'exemples ML |
| Python | **3.12** (deps de build IREE) | **3.14** (correspond au `pyxrt` empaqueté d'Ubuntu) |
| Backend | Peano (`llvm-aie`) | le **même** Peano — `aie2` (npu1) / `aie2p` (npu2), choisi automatiquement |

Elles sont complémentaires, pas concurrentes. Utilisez celle qui convient au travail.

## Installation (un seul script)

```bash
./scripts/setup-mlir-aie.sh
```

Idempotent ; il clone `Xilinx/mlir-aie` au dernier tag de release, crée un venv
Python 3.14, lie symboliquement le `pyxrt` empaqueté d'Ubuntu dans celui-ci,
installe le wheel `mlir_aie` correspondant (la 1.4.1 livre des wheels manylinux
`cp314`) + le torch CPU, et réutilise votre Peano d'iree-amd-aie (ou installe le
wheel `llvm-aie` — le wheel est `py3-none`, indépendant de la version de
Python). La détection de génération est celle de l'amont : `env_setup.sh` fait
un grep sur `xrt-smi examine` et exporte `NPU2=0/1`.

## Exécuter un exemple sur le NPU

```bash
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh ml/softmax
./scripts/run-mlir-example.sh ml/conv2d          # Makefile example
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
    -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
```

**mlir-aie 1.4.x a restructuré les exemples** — le script gère les deux formes :

- La plupart des exemples sont désormais **un unique design Python exécuté
  directement** : `@iron.jit` compile au premier appel, le périphérique
  (`npu`/`npu2`) est auto-détecté, et le design embarque son propre harnais de
  benchmark/vérification. Les Makefiles par exemple ont disparu de la majeure
  partie de `basic/` ; les fichiers lit (`run.lit` / `run_strix.lit`)
  documentent les invocations canoniques.
- `ml/conv2d`, `ml/mobilenet` et les variantes de matmul à hôte C++ utilisent
  encore un Makefile — `devicename=npu2` sélectionne la génération
  (`devicename ?= $(if $(filter 1,$(NPU2)),npu2,npu)`).
- `aiecc.py` a disparu : `aiecc` est un **binaire C++** en 1.4.x, et **Peano est
  le backend par défaut** (chess exige explicitement `--xchesscc --xbridge` +
  Vitis).

## Ce qui s'exécute sur XDNA2 (vérifié, sur le NPU, mlir-aie 1.4.1)

Strix Point expose **8 colonnes / 32 tuiles de calcul** à IRON (Phoenix : 4/16).
Toutes les mesures ci-dessous proviennent des machines de ce dépôt ; « NPU
time » est le chiffre sur-NPU du runtime (autour de `kernel.wait()`), hors
surcoût de lancement côté hôte.

### Noyaux & blocs

| Example | Kind | XDNA2 result |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ 94 µs |
| `basic/vector_scalar_mul` | vector × scalar | ✓ 106 µs |
| `ml/softmax` | LLM block | ✓ PASS |
| `ml/rope` | LLM block | ✓ PASS |
| `ml/swiglu` | LLM block | ✓ PASS |
| `ml/norm -o rms` | RMSNorm | ✓ PASS |
| `ml/mm_activation_epilogue` | matmul + fused activation | ✓ PASS |
| `ml/conv2d` (i8, 32×32, 64ch) | INT8 convolution | ✓ 490 µs (XDNA1: ~900 µs) |
| `ml/mobilenet` | **full network** | ✓ **PASS, ~176 ms/inference** |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | custom fused kernel | ✓ see below |

`ml/mobilenet` est le design qui **ne peut pas s'exécuter sur XDNA1** — il veut
plus de colonnes que les 4 de Phoenix et meurt dans `CREATE_HWCTX`. Sur les 8
colonnes de Strix, le réseau complet s'exécute de bout en bout. (L'amont le
vérifie actuellement avec une tolérance relâchée `atol=9` — leur note,
reproduite ici.)

### GEMM (`basic/matrix_multiplication/whole_array`, 8 colonnes)

| Shape | dtype | inner tile | NPU time | Throughput |
|---|---|---|--:|--:|
| 512³ | i16→i32 | 32³ | 203 µs | 1.32 TOPS |
| 512³ | bf16→f32 | 32³ | 233 µs | 1.15 TFLOPS |
| 512³ | bf16 via **bfp16** | 32³ | 199 µs | 1.35 TFLOPS |
| 2048³ | bf16 via **bfp16** | 32³ | 9.71 ms | 1.77 TFLOPS |
| 2048³ | i8→i32 | 32³ | 8.73 ms | 1.97 TOPS |
| 2048³ | bf16 via **bfp16** | 64×32×64 | 3.70 ms | **4.64 TFLOPS** |
| 2048³ | i8→i32 | 64³ | 2.59 ms | **6.65 TOPS** |

Deux leçons que ce tableau enseigne :

1. **La taille de tuile interne vaut 3.4×** (i8 : 1.97 → 6.65 TOPS rien qu'en
   passant des tuiles 32³ aux tuiles 64³). Aller plus loin déborde les 64 Ko de
   mémoire locale au cœur et échoue au placement — le bf16 à 64³ le fait déjà.
2. **Sur AIE2P, préférez la voie bfp16 pour le calcul bf16**
   (`--emulate-bf16-mmul-with-bfp16 1`). Le MAC bf16 est natif sur l'AIE2 de
   XDNA1 mais *émulé à ~¼ de la cadence* sur l'AIE2P de XDNA2 ; le mode natif
   est la **virgule flottante par blocs bfp16** (8×8×8). +17% gratuits à 512³,
   +25% avec des tuiles ajustées.

Les designs de bout en bout **bfp16ebs8 natifs** (`ml/block_datatypes/…`) se
compilent sans problème avec Peano sur cette machine (xclbin + insts produits) ;
les exécuter exige l'hôte C++, c'est-à-dire `libxrt-dev` (les paquets de
runtime d'Ubuntu ne livrent aucun en-tête de développement XRT).

### Noyau personnalisé, montée en charge sur tableau entier

Notre `relu(a+b)` fusionné ([`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/)),
1M d'éléments int32, tuile 1024 :

| Design | NPU time | Effective DDR BW |
|---|--:|--:|
| single Worker (1 tile) | 8 967 µs | 1.4 GB/s |
| whole array (8 columns, `transform_parallel_binary`) | 1 123 µs | 11.2 GB/s |

**8.0× grâce aux 8 colonnes** — montée en charge linéaire pour ce noyau limité
par la bande passante.

## Ce qui s'exécute sur XDNA1 (vérifié, sur le NPU, 2026-06-24)

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| `examples/mlir-aie/relu_add` | custom fused `relu(a+b)` kernel | ~0.37 ms |

**Limites connues sur Phoenix (4 colonnes) :** `ml/mobilenet` se compile mais
échoue sur `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` — les designs pour réseau
entier sont à l'échelle XDNA2 (confirmé ci-dessus). Les blocs isolés tiennent
et s'exécutent.

## Écrivez votre propre noyau

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) est un noyau
écrit à la main qui n'est **pas** l'un des exemples de série : un unique
`out = max(a + b, 0)` fusionné. Il montre toute la voie sur l'une ou l'autre
génération —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — le noyau de
  calcul ; Peano le compile pour `aie2` ou `aie2p` selon le périphérique
  détecté, sans modification de la source.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — la forme
  `@iron.jit` annotée d'IRON 1.4.x (`In`/`Out`/`CompileTime[...]`), en deux
  designs : Worker unique (`transform_binary`) et un Worker par colonne
  (`transform_parallel_binary`, 4 ou 8 colonnes automatiquement).

```bash
./examples/mlir-aie/relu_add/run.sh
```

**Note d'API :** IRON 1.4.x **exige** les annotations — l'ancienne forme
d'appel `iron.jit(transform_binary)(kernel, a, b, out, tile_size=…)` (celle que
cet exemple utilisait en 1.3.x) lève désormais `TypeError: … no In / Out /
InOut / CompileTime[T] annotation`. Les algorithmes 1.4.x prennent un
*descripteur de type de tenseur* dans le corps du jit au lieu de tenseurs
vivants. Le portage est mécanique — voir le diff de l'exemple.

## Pièges propres à cette voie

Liste courte — tous les détails dans [docs/GOTCHAS.md](GOTCHAS.md) → *voie mlir-aie* :

1. **Python 3.14 ici, pas 3.12** (le `pyxrt` empaqueté d'Ubuntu est cpython-314).
2. **Exposez `pyxrt` par lien symbolique** dans les `site-packages` du venv.
3. ⚠️ **Sourcez `env_setup.sh` sans pipe** — un pipe = sous-shell = les
   `export` (`NPU2`, `PEANO_INSTALL_DIR`…) disparaissent.
4. **Rupture de l'API d'annotations en IRON 1.4.x** — voir ci-dessus.
5. **La mémoire locale au cœur fait 64 Ko** : 3 FIFOs int32 en double buffering
   à `tile_size` 4096 = 96 Ko → `aie.tile op … allocation failed`. Dimensionnez
   les tuiles pour que ça tienne.
6. **Les noyaux binaires ne peuvent pas utiliser `num_channels=2`** — 2 entrées
   occupent déjà les deux canaux DMA MM2S du shim par colonne
   (`no ShimNOCTile has sufficient DMA capacity`).
7. **Le bf16 sur AIE2P est une émulation à ¼ de cadence** — utilisez la voie
   bfp16 (voir les leçons GEMM ci-dessus).
8. **Réutilisez le Peano** d'`iree-amd-aie` quand il est présent ; un
   `pip install llvm-aie` non épinglé récupère aujourd'hui une nightly 22.x en
   avance d'une version majeure de LLVM sur ce que teste la CI de mlir-aie —
   le script d'installation épingle pour vous.

## Relation avec le reste du dépôt

Ceci est une voie *supplémentaire*, pas un remplacement. Pour « exécuter mon
modèle sur le NPU », le flux `iree-amd-aie` (`scripts/build.sh` +
`scripts/run-matmul.sh` + les outils `npu-trim` / `npu-runner`) reste la
réponse sur XDNA1 ; son portage XDNA2 est suivi dans [XDNA2.md](XDNA2.md).
Tournez-vous vers `mlir-aie` quand vous voulez **écrire un noyau spécifique**
ou exécuter directement les **blocs d'exemples ML** de l'amont.
