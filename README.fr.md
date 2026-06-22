**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Exécuter du calcul réel sur un NPU Ryzen AI **XDNA1** sous **Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1](https://img.shields.io/badge/NPU-Ryzen%20AI%20XDNA1-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

Une recette reproductible et de bout en bout — avec ses outils — pour faire passer un NPU AMD Ryzen AI
**de première génération (XDNA1 / « Phoenix »)** de l'état *visible-par-le-pilote-mais-inactif* à
**l'exécution effective de matmuls** sous Linux, en compilant
[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) depuis les sources.

> **Pourquoi ce dépôt existe.** Presque tous les articles de 2026 du type « le NPU Ryzen AI fonctionne enfin sous Linux »
> portent sur **XDNA2** (Strix/Krackan). Les puces **XDNA1** de première génération
> des portables Ryzen 7040/8040 (par ex. le 7840U) sont *explicitement exclues* par
> les stacks clés en main — le Ryzen AI Software d'AMD pour Linux, le Vitis AI EP d'ONNX Runtime,
> Lemonade/FastFlowLM. Sur XDNA1+Linux, le NPU est alimenté et énuméré par
> le pilote `amdxdna` intégré au noyau, mais **aucun runtime livré n'exécutera de modèle dessus.**
> La seule voie ouverte qui *cible* effectivement XDNA1 est `iree-amd-aie` — compilé depuis
> les sources. Ce dépôt est la carte vérifiée, piège par piège, de cette voie.

## 🎬 Démos

**De bout en bout — un MLP ONNX sur le NPU** (matmuls sur le NPU, `ReLU` sur le CPU ; correspond à la référence CPU à ~0.3% près) :

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python, **sur le NPU** | flou 2D NPU sur trois motifs `videotestsrc` → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| KWS de détection de mot-clé — 3 couches denses sur le NPU (la cible se déclenche, le bruit reste silencieux) | bf16 est la force native du NPU — jusqu'à **220 GFLOP/s** |
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
git clone https://github.com/<you>/ryzen-npu-linux.git && cd ryzen-npu-linux

# 0. Is the NPU even alive? (read-only diagnostic)
./scripts/check-npu.sh

# 1. (if check failed on groups/memlock/xrt) activate it for your user, then re-login
./scripts/enable-npu.sh

# 2. Build iree-amd-aie from source (~65 min, 30-60 GB disk). All workarounds baked in.
./scripts/build.sh

# 3. Run a matmul ON THE NPU
./scripts/run-matmul.sh i32          # 128x128x128, all 768
./scripts/run-matmul.sh bf16         # 256x256x256 bf16->f32, all 1536
BENCH=1 ./scripts/run-matmul.sh bf16 # + benchmark
```

## 🧰 Les outils

| Script | Ce qu'il fait |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | Lecture seule : vérifie le pilote, le nœud de périphérique, le groupe render, memlock, XRT, pyxrt. |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | Corrige les 3 éléments qui bloquent un utilisateur non-root (groupe render, memlock, XRT). |
| [`scripts/build.sh`](scripts/build.sh) | Clone + compile `iree-amd-aie` avec tous les contournements appliqués. |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | Compile + exécute un matmul `i32`/`bf16` sur le NPU. La recette. |

## 🪤 Les pièges (pourquoi une compilation/exécution naïve échoue)

Tous les détails dans **[docs/GOTCHAS.fr.md](docs/GOTCHAS.fr.md)**. La liste courte :

1. **Utilisez `gcc`, pas `clang`, comme compilateur hôte.** clang 21 *plante (segfault)* en compilant MLIR `BuiltinDialectBytecode.cpp`.
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`.** Les bindings Python rencontrent `-Werror,-Wmacro-redefined` ; les outils CLI n'en ont pas besoin.
3. **Mettez à jour le pin de Peano (`llvm-aie`).** La nightly épinglée du dépôt a expiré de l'index ; `build.sh` sélectionne automatiquement la plus récente.
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`.** Vous sautez intentionnellement 3 sous-modules lourds.
5. **Compilez avec `--iree-amdaie-device-hal=amdxdna`** (+ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`) ou le dispatch expire (timeout).
6. ⚠️ **Exécutez avec `--amdxdna_n_core_cols=4`, pas 5.** Phoenix rapporte 5 colonnes brutes mais en utilise 4 (`npu1_4col`). Passer 5 → les cœurs se bloquent → timeout `ert state 8`.

## 🎯 Où pouvez-vous réellement utiliser cela ?

Guide complet public par public (jeux · agents IA · applications locales) avec notes de faisabilité → [docs/APPLICATIONS.fr.md](docs/APPLICATIONS.fr.md).

Voir **[docs/USE-CASES.fr.md](docs/USE-CASES.fr.md)**. Honnêtement : c'est **de niveau noyau (kernel-level)**
(briques de base matmul/conv), pas du serving de modèles clés en main. Idéal pour apprendre la programmation
NPU, faire du benchmarking, construire/décharger des primitives d'inférence basse consommation spécifiques,
et contribuer à l'effort ouvert XDNA1-sous-Linux. Cela ne vous donnera **pas**
un runtime LLM/Whisper/ONNX prêt à l'emploi sur XDNA1 — ça, c'est le territoire de XDNA2 / Windows.

## 📚 Contexte

Voir **[docs/BACKGROUND.fr.md](docs/BACKGROUND.fr.md)** pour XDNA1 vs XDNA2, pourquoi Linux est
difficile pour la première génération, et comment le HAL `amdxdna` communique avec `/dev/accel0`.

## 🧭 Où se situe ce projet (et ce qu'il n'est *pas*)

**Ce n'est pas le premier projet NPU-sous-Linux, et il n'invente aucune partie de la pile** —
le pilote, le compilateur et le runtime lui préexistent tous et font le gros du travail :

| Couche | Travaux antérieurs sur lesquels nous bâtissons / à côté desquels nous nous situons |
|---|---|
| Pilote noyau | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`, dans la branche principale depuis Linux 6.14, énumère XDNA1 en tant que `/dev/accel/accel0` |
| Compilateur / runtime | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie), [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) (IRON), [`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie) (Peano), [`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — SDK/frameworks qui compilent pour `npu1` |
| Calcul XDNA1 + Linux antérieur | un article de recherche ([arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — GPT-2 sur un Phoenix 7940HS via IRON), des tutoriels uniquement sur les primitives, le [récapitulatif XDNA du wiki Gentoo](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| LLM NPU clés en main sous Linux | FastFlowLM · Lemonade 10.x · AMD Ryzen AI SW — **tous XDNA2 uniquement ; ils excluent explicitement XDNA1** |

Ainsi, « premier NPU sous Linux », « premier compilateur » ou « premier à faire tourner XDNA1 » seraient
tous des affirmations exagérées — et nous ne les faisons pas.

**Ce que ce dépôt *est* :** pour autant que la recherche publique (2026-06) puisse le constater, la première
— et la seule — **recette + trousse à outils empaquetée, reproductible et de bout en bout** qui exécute
*n'importe quel calcul réel arbitraire* (matmul i32/bf16, conv) sur le **NPU XDNA1 de première génération
(Phoenix, p. ex. 7840U) sous Linux** — la combinaison matériel/OS exacte que toute pile de fournisseur
clés en main laisse orpheline. Les travaux antérieurs sont soit un **SDK/framework** en amont
(vous naviguez vous-même parmi les pièges de la compilation depuis les sources), soit une application
**XDNA2 uniquement**, soit un **article de recherche** (pas de dépôt prêt à l'emploi en un clic), soit un
chemin de calcul **Windows uniquement**. La particularité réside dans le *paquet* : les scripts
diagnostiquer→activer→compiler→exécuter, la **carte des pièges** de la compilation depuis les sources,
l'**exécuteur persistant C-API/ctypes** (~11× plus rapide que `iree-run-module` appel par appel), les
**exemples d'application** (mot de réveil, démon de caméra NPU), le **guide d'applications avec notes de
faisabilité honnêtes** (y compris le constat mesuré « le NPU perd contre le CPU pour l'audio »), et une
documentation en 5 langues.

> **Mise en garde honnête :** ce positionnement provient d'une recherche publique de README et d'extraits
> (aucun dépôt externe n'a été cloné/vérifié). Nous **ne pouvons pas** voir les dépôts privés, le travail
> en entreprise, ni la longue traîne des scripts ponctuels — « nous n'avons trouvé aucun pair direct »
> signifie exactement cela, et non « il n'en existe aucun ».

## ⚖️ Avertissement

Notes communautaires, pas un produit AMD/Xilinx. `iree-amd-aie` est en phase précoce et
évolue vite ; les versions/flags dérivent. Tout ce qui figure ici a été vérifié sur la machine exacte
ci-dessus le 2026-06-22. Les issues/PR avec des résultats provenant d'autres portables XDNA1 sont les bienvenus.

## 🤝 Contribuer

La contribution la plus utile est **un résultat issu de votre propre machine XDNA1** — la
couverture du Ryzen AI de première génération sous Linux est mince. Voir **[CONTRIBUTING.md](CONTRIBUTING.md)**. En bref :

- **Rapportez des résultats matériels** — votre puce / noyau / distribution et ce qui a fonctionné ou échoué (un gabarit d'issue est fourni).
- **Ajoutez des tests de performance** pour d'autres formes/dtypes, ou de **nouvelles ops** (conv, i8, …).
- **Corrigez ou affinez un [piège](docs/GOTCHAS.fr.md)**, durcissez les scripts, ou ajoutez/corrigez une traduction.
- Fork → branch → test avec `scripts/run-matmul.sh` → PR décrivant la machine sur laquelle vous l'avez exécuté.

## 📄 Licence

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — utilisez-le, forkez-le, livrez-le.

Les scripts et la documentation de ce dépôt sont sous licence MIT. Ils compilent et pilotent des
projets tiers sous leurs propres licences — IREE et `iree-amd-aie` (Apache-2.0 WITH
LLVM-exception), `Xilinx/llvm-aie` (Peano) — que ce dépôt ne redistribue pas.
