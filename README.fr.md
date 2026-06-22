**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Exécuter du calcul réel sur un NPU Ryzen AI **XDNA1** sous **Linux**

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

Voir **[docs/USE-CASES.fr.md](docs/USE-CASES.fr.md)**. Honnêtement : c'est **de niveau noyau (kernel-level)**
(briques de base matmul/conv), pas du serving de modèles clés en main. Idéal pour apprendre la programmation
NPU, faire du benchmarking, construire/décharger des primitives d'inférence basse consommation spécifiques,
et contribuer à l'effort ouvert XDNA1-sous-Linux. Cela ne vous donnera **pas**
un runtime LLM/Whisper/ONNX prêt à l'emploi sur XDNA1 — ça, c'est le territoire de XDNA2 / Windows.

## 📚 Contexte

Voir **[docs/BACKGROUND.fr.md](docs/BACKGROUND.fr.md)** pour XDNA1 vs XDNA2, pourquoi Linux est
difficile pour la première génération, et comment le HAL `amdxdna` communique avec `/dev/accel0`.

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
