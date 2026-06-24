**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# Pièges — ce qui casse, pourquoi, et comment le corriger

Chaque point ci-dessous a été rencontré et résolu sur un build réel (Ryzen 7840U / XDNA1,
Ubuntu 26.04, kernel 7.0, 2026-06-22). Ils sont ordonnés selon l'endroit où ils vous mordent.

---

## 1. clang plante (segfault) en construisant MLIR → utilisez gcc

**Symptôme**
```
FAILED: .../obj.MLIRIR.dir/BuiltinDialectBytecode.cpp.o
clang++: error: clang frontend command failed with exit code 139
... file INSTALL cannot find ".../libIREECompiler.so": No such file
```
`exit 139` = SIGSEGV : le **clang hôte (testé en 21.x) plante** lors de la compilation d'un
gros fichier MLIR généré. Comme ce fichier fait partie du cœur `MLIRIR`, la bibliothèque
du compilateur n'est jamais liée et toute l'installation s'effondre — mais la *première* erreur
défile hors de l'écran et vous ne remarquez que l'échec de l'installation.

**Correctif.** Construisez avec **gcc** :
```bash
export CC=gcc CXX=g++
rm -rf iree-build      # required: cmake won't switch compilers in an existing dir
cmake ...              # reconfigure
```
gcc 15 construit le même arbre proprement (~65 min sur 16 cœurs).

---

## 2. Bindings Python : macro `_POSIX_C_SOURCE` redéfinie → désactivez-les

**Symptôme**
```
.../python3.12/include/python3.12/pyconfig.h:1877:9:
  error: '_POSIX_C_SOURCE' macro redefined [-Werror,-Wmacro-redefined]
FAILED: runtime/bindings/python/.../PyExtRt.dir/...cc.o
```
Les bindings Python (nanobind) d'IREE déclenchent une redéfinition de macro de test de
fonctionnalité qui est fatale sous `-Werror`. Vous n'avez **pas** besoin des bindings Python
pour compiler et exécuter des matmuls — les binaires `iree-compile` / `iree-run-module` /
`iree-e2e-matmul-test` suffisent.

**Correctif.** `-DIREE_BUILD_PYTHON_BINDINGS=OFF` (et ignorez la cible `iree-install-dist`).

---

## 3. La version épinglée de Peano (llvm-aie) a expiré

**Symptôme**
```
ERROR: Could not find a version that satisfies the requirement
  llvm_aie==19.0.0.2025052701+31d2aa6e (from versions: 21.0.0.2026061101+..., ...)
```
`build_tools/peano_commit_linux.txt` épingle une nightly `llvm-aie` spécifique, mais l'index
nightly de Xilinx ne conserve que les builds récents — l'épingle (non touchée en amont depuis
~13 mois) a disparu depuis longtemps.

**Correctif.** Pointez l'épingle vers la nightly la plus récente disponible :
```bash
echo "<latest-nightly-version>" > build_tools/peano_commit_linux.txt
bash build_tools/download_peano.sh
```
`scripts/build.sh` le fait automatiquement en interrogeant l'index. La version plus récente de
Peano fonctionne très bien malgré le saut de version (c'est le backend LLVM AIE ; l'interface est stable).

---

## 4. Le build s'interrompt sur des sous-modules intentionnellement ignorés

**Symptôme**
```
The git submodule 'third_party/stablehlo' is not initialized.
CMake Error: check_submodule_init.py failed
```
Vous clonez sans `torch-mlir`, `stablehlo`, `XRT` (aucun n'est nécessaire pour le chemin
amdxdna), mais la vérification des sous-modules d'IREE émet quand même une erreur.

**Correctif.** `-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`. (Et vous n'avez **pas** besoin de
construire le `xdna-driver` hors-arbre d'AMD : l'`amdxdna.ko` intégré à l'arbre expose le
périphérique, et le HAL `amdxdna` embarque son propre shim qui ouvre `/dev/accel0` directement.)

---

## 5. Module compilé pour le mauvais HAL → le dispatch ne se termine jamais

**Symptôme.** Compile sans problème, mais à l'exécution :
```
amdxdna dispatch did not complete: ert state 8; while invoking ... hal.fence.await
```
Si vous omettez `--iree-amdaie-device-hal=amdxdna`, le module est construit pour un HAL
différent (p. ex. `xrt`) et ne s'exécutera pas correctement sous `--device=amdxdna`.

**Correctif.** Compilez avec le jeu de drapeaux complet :
```
--iree-amdaie-device-hal=amdxdna
--iree-hal-memoization=false
--iree-hal-indirect-command-buffers=false
--iree-amdaie-target-device=npu1_4col
--iree-amdaie-lower-to-aie-pipeline=objectFifo   # i32
# (use 'air' for bf16)
--iree-amdaie-tile-pipeline=pack-peel
--iree-amd-aie-peano-install-dir=<.../llvm-aie>
--iree-amd-aie-install-dir=<.../iree-install>
```

---

## 6. ⚠️ Le gros morceau : le nombre de colonnes à l'exécution

**Symptôme.** Même `ert state 8` **TIMEOUT** qu'au #5, même avec les drapeaux de compilation
corrects. La commande atteint le NPU (vous pouvez voir le dispatch), les cœurs se chargent, puis
ils **se figent indéfiniment** et expirent après ~60 s. `dmesg` n'affiche **aucune** erreur
matérielle — les cœurs attendent simplement une partition qui ne correspond jamais.

**Cause racine.** Les métadonnées AIE brutes de Phoenix indiquent **5 colonnes**, mais le
nombre utilisable — et la cible de compilation `npu1_4col` — est **4**. L'assistant du pilote confirme :
```
$ python build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py --num-cols
4
```
Passez `--amdxdna_n_core_cols=5` et le runtime met en place une partition de 5 colonnes alors
que le module en attend 4 → incohérence → blocage.

**Correctif.** Exécutez avec les valeurs rapportées par l'assistant du périphérique (rows=4, **cols=4**) :
```
--amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4
```
`scripts/run-matmul.sh` les lit automatiquement depuis `--num-rows`/`--num-cols`.

---

## Notes non bloquantes

- **`xrt-smi validate` échoue** avec `Archive not found: amdxdna/bins/xrt_smi_phx.a`.
  C'est Ubuntu qui supprime le binaire d'auto-test Phoenix, **pas** un NPU défaillant.
- **L'incohérence UAPI/ABI prédite ne s'est pas produite.** L'`amdxdna` intégré à l'arbre du
  kernel-7.0 et l'`amdxdna_accel.h` embarqué par `iree-amd-aie` étaient compatibles : l'ioctl de
  topologie et l'énumération des périphériques ont tous deux fonctionné du premier coup.
- **Python 3.13/3.14 sont trop récents** pour les dépendances de build d'IREE — utilisez un
  3.12 isolé (les scripts utilisent `uv`).

---

# Voie mlir-aie (IRON) — pièges distincts

La seconde voie — [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) via le
wheel `mlir_aie` (voir [MLIR-AIE.md](MLIR-AIE.md)) — a ses propres pièges, différents
du build iree-amd-aie ci-dessus. `scripts/setup-mlir-aie.sh` et
`scripts/mlir-aie-env.sh` gèrent tous ces points ; voici ce qu'ils contournent.

## M1. Utilisez Python **3.14** ici — l'inverse du build iree

Le build iree-amd-aie veut **3.12** (note ci-dessus). Les wheels `mlir_aie` prennent en charge
3.11–3.14, et le seul moyen d'utiliser le `pyxrt` empaqueté d'Ubuntu (depuis `python3-xrt`,
compilé en `pyxrt.cpython-314-*.so`) est un venv **3.14** — un venv 3.12 ne peut tout simplement pas
importer ce `pyxrt`. Les deux voies utilisent donc délibérément des venvs Python différents.

## M2. Exposez `pyxrt` dans le venv

`make run_py` fait `import pyxrt`. Le paquet Debian le dépose à
`/usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so`. Liez symboliquement **ce seul fichier**
dans les `site-packages` du venv — un venv propre, **pas** `--system-site-packages`
(qui entraînerait le reste du site système et risquerait de masquer les deps du wheel) :

```bash
ln -sf /usr/lib/python3/dist-packages/pyxrt.cpython-314-*.so "$VENV/lib/python3.14/site-packages/"
```

## M3. ⚠️ Sourcez `env_setup.sh` SANS pipe

```
error: unknown target triple 'aie2-none-unknown-elf'
make: *** [Makefile:37: build/passThrough.cc.o] Error 1
```

Le Makefile a compilé le noyau AIE avec le `/bin/clang++` **système** (qui n'a
aucune cible `aie2`) au lieu du `clang++` de Peano. Cause : `PEANO_INSTALL_DIR` était
vide. Cause de *cela* :

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" | tail   # WRONG
```

Un pipe exécute le côté gauche dans un **sous-shell**, donc chaque `export` de `env_setup.sh`
(`PEANO_INSTALL_DIR`, `MLIR_AIE_INSTALL_DIR`, `NPU2`) est jeté au moment où le
sous-shell se termine. **Redirigez, ne pipez pas :**

```bash
source utils/env_setup.sh "$MLIR_AIE" "$PEANO" >/tmp/env.log 2>&1   # RIGHT
```

(De plus : `env_setup.sh` n'est pas écrit pour être sûr sous `set -e`/`set -u` —
le sourcer sous `set -euo pipefail` avorte silencieusement. `scripts/mlir-aie-env.sh` relâche et
restaure ces drapeaux autour du source.)

## M4. `make run_py` (pyxrt) vs `make run` (hôte C++ + libxrt-dev)

Beaucoup d'exemples livrent **à la fois** un hôte C++ (`test.cpp` → `make run`) et un hôte Python
(`test.py` → `make run_py`). L'hôte C++ a besoin des **en-têtes de développement** XRT
(`libxrt-dev`), que les paquets de runtime (`libxrt-utils-npu`, `python3-xrt`) n'installent
**pas**. Préférez `run_py`. Pour les exemples uniquement en C++ (matrix_multiplication,
vision, relu, softmax) : `sudo apt install libxrt-dev`.

## M5. Réutilisez le Peano que vous avez déjà compilé

Ne re-téléchargez pas `llvm-aie`. Passez le Peano d'iree-amd-aie comme 2ᵉ argument
d'`env_setup.sh` pour qu'il saute son auto-installation :

```bash
source utils/env_setup.sh "$SITE/mlir_aie" "$HOME/src/iree-amd-aie/llvm-aie"
```

Il prend en charge `aie` / `aie2` / `aie2p`, donc le même Peano sert les deux voies.

## M6. Les designs pour réseau entier exigent plus que les 4 colonnes de Phoenix

```
RuntimeError: DRM_IOCTL_AMDXDNA_CREATE_HWCTX IOCTL failed (err=-22): Invalid argument
```

`ml/mobilenet` **se compile** mais échoue à la création du `hw_context` : le design
pour tableau entier (whole-array) demande plus de colonnes que Phoenix n'en expose (**4** — les mêmes 4 du piège
#6 ci-dessus). Les briques de base isolées (`conv2d`, `bottleneck`, `resnet/layers_conv2_x`)
et `magika` tiennent dans 4 colonnes et s'exécutent ; le réseau complet est du territoire XDNA2
(Strix, 8 colonnes).
