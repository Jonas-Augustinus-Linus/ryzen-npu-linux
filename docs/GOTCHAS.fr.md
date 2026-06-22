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
