**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# La voie `mlir-aie` (IRON) — une seconde voie ouverte vers le NPU XDNA1

Le reste de ce dépôt compile [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) :
un **compilateur de graphes** qui abaisse des modèles entiers (PyTorch / ONNX) vers le NPU. Cette
page est la recette vérifiée de l'*autre* voie ouverte —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) et son eDSL Python **IRON** —
où vous **écrivez directement des noyaux NPU** et les exécutez via `pyxrt`. Elle
livre aussi de véritables `programming_examples` ML (conv2d, blocs ResNet, le Magika de Google), si bien que
c'est le moyen le plus rapide d'amener des charges de travail *nommées* sur un NPU Phoenix de première génération.

Les deux voies ciblent `npu1` (Phoenix / XDNA1) et partagent le **même backend Peano (`llvm-aie`)** —
donc si vous avez déjà exécuté `./scripts/build.sh`, cette voie réutilise ce
Peano et ne coûte presque rien de plus.

> Même machine que tout le reste ici : **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO
> 7840U (Phoenix, XDNA1) · Ubuntu 26.04 · noyau 7.0 · `amdxdna` intégré · XRT
> 2.21 · NPU FW 1.5.5.391**. Vérifié le 2026-06-24.

## iree-amd-aie vs mlir-aie — lequel choisir ?

| | `iree-amd-aie` (racine du dépôt) | `mlir-aie` / IRON (cette page) |
|---|---|---|
| Vous apportez | un graphe entier (`.onnx` / PyTorch) | une idée de noyau (dataflow + une fn de calcul C++) |
| Abstraction | compilateur de graphes MLIR | eDSL dataflow ObjectFifo (`aie.iron`) + `aiecc` |
| Hôte d'exécution | `iree-run-module` / l'exécuteur C-API | `pyxrt` (`make run_py`) |
| Idéal pour | « exécuter mon modèle sur le NPU » | « écrire/posséder un noyau NPU spécifique », vrais blocs d'exemples ML |
| Python | **3.12** (deps de build IREE) | **3.14** (correspond au `pyxrt` empaqueté d'Ubuntu) |
| Backend | Peano (`llvm-aie`) | le **même** Peano |

Elles sont complémentaires, pas concurrentes. Utilisez celle qui convient au travail.

## Installation (un seul script)

```bash
./scripts/setup-mlir-aie.sh
```

Il est idempotent et fait ce qui suit :

1. **Clone `Xilinx/mlir-aie` au dernier tag de release** (`~/src/mlir-aie`). Les
   `programming_examples` doivent correspondre au wheel installé, donc le tag est épinglé à
   la version du wheel.
2. **Crée un venv Python 3.14** (`~/src/mlir-aie-venv`) et **lie symboliquement le
   `pyxrt` empaqueté** (`python3-xrt`, compilé en `cpython-314`) dans celui-ci — c'est pourquoi
   le venv est en 3.14 et non en 3.12 utilisé pour le build iree-amd-aie.
3. **Installe le wheel `mlir_aie`** (tag correspondant) **+ `torch` CPU** (les exemples `ml/*`
   vérifient la sortie NPU par rapport à une référence (golden) torch).
4. **Réutilise le Peano** que vous avez compilé pour `iree-amd-aie` (`~/src/iree-amd-aie/llvm-aie`) ;
   s'il n'est pas là, il installe à la place le wheel nightly `llvm-aie`.

## Exécuter un exemple sur le NPU

```bash
./scripts/run-mlir-example.sh ml/conv2d                 # default target: run_py (pyxrt)
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: needs libxrt-dev
```

`run-mlir-example.sh` source [`scripts/mlir-aie-env.sh`](../scripts/mlir-aie-env.sh)
(toolchain sur le `PATH`, Peano câblé, périphérique auto-détecté comme `npu1`), compile l'exemple
pour `npu1`, et l'exécute sur le NPU. Il utilise par défaut la cible make **`run_py`** —
un hôte `pyxrt` qui n'a besoin d'**aucun** en-tête de développement XRT.

## Ce qui s'exécute sur XDNA1 (vérifié, sur le NPU)

Tout via `run_py` / `pyxrt`, sortie vérifiée par rapport à une référence (golden) torch/numpy. Les temps
NPU sont en temps réel, y compris la répartition côté hôte (ils varient d'une exécution à l'autre) :

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block (1×1→3×3→1×1 + skip) | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

**Limites connues sur Phoenix (4 colonnes) :**

- `basic/matrix_multiplication/*` se compile en un **xclbin sans problème** (512³, 4 colonnes)
  mais son hôte est **uniquement en C++** — `make run` a besoin de `libxrt-dev` (les paquets
  de runtime ne livrent pas les en-têtes de développement XRT). `sudo apt install libxrt-dev`, puis
  `./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run`.
- `ml/mobilenet` se compile mais échoue à l'exécution avec
  `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` : le design pour réseau entier exige plus
  que les **4** colonnes de Phoenix. Les blocs isolés (conv2d, bottleneck, resnet
  conv2_x) et `magika` tiennent et s'exécutent ; le réseau complet est à l'échelle XDNA2.

## Écrivez votre propre noyau

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) est un noyau écrit à la main
qui n'est **pas** l'un des exemples de série : un unique `out = max(a + b, 0)`
fusionné (addition résiduelle + ReLU). Il montre toute la voie —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — le noyau de calcul,
  compilé pour `aie2` par Peano.
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — une
  `iron.ExternalFunction` câblée via `transform_binary` et compilée + exécutée par
  `iron.jit`, vérifiée par rapport à numpy.

```bash
./examples/mlir-aie/relu_add/run.sh
```

## Pièges propres à cette voie

La voie IRON a ses propres pièges, distincts du build iree-amd-aie. La liste
courte (tous les détails dans [docs/GOTCHAS.md](GOTCHAS.md) → *voie mlir-aie*) :

1. **Python 3.14 ici, pas 3.12.** Le seul moyen d'utiliser le `pyxrt` empaqueté
   d'Ubuntu est un venv 3.14 ; un venv 3.12 ne peut pas l'importer.
2. **Exposez `pyxrt` par lien symbolique** dans les `site-packages` du venv (venv propre, pas
   `--system-site-packages`).
3. ⚠️ **Sourcez `env_setup.sh` sans pipe.** `source env_setup.sh A B | tail`
   l'exécute dans un sous-shell et les `export` disparaissent → `PEANO_INSTALL_DIR` vide →
   `/bin/clang++` système → `error: unknown target triple 'aie2-none-unknown-elf'`.
   (`scripts/mlir-aie-env.sh` s'en occupe pour vous.)
4. **Préférez `make run_py` à `make run`.** `run_py` est du pur `pyxrt` ; `run` compile
   un hôte C++ qui a besoin de `libxrt-dev`.
5. **Réutilisez le Peano** d'`iree-amd-aie` au lieu de re-télécharger `llvm-aie`.
6. **Les designs pour réseau entier exigent > 4 colonnes** — ils échouent sur `CREATE_HWCTX` sous Phoenix.

## Relation avec le reste du dépôt

Ceci est une voie *supplémentaire*, pas un remplacement. Pour « exécuter mon modèle sur le NPU »,
le flux `iree-amd-aie` (`scripts/build.sh` + `scripts/run-matmul.sh` + les
outils `npu-trim` / `npu-runner`) reste la réponse. Tournez-vous vers `mlir-aie` quand vous
voulez **écrire un noyau spécifique** ou exécuter directement les **blocs d'exemples ML**
en amont.
