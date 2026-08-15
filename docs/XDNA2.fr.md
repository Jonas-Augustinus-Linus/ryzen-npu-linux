**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — ce qui change, ce qui se transfère

Les preuves matérielles XDNA1 de ce dépôt proviennent d'un Phoenix / Ryzen 7 PRO
7840U. Hawk Point partage l'identité `RyzenAI-npu1` associée, mais ne dispose ici
d'aucun résultat matériel distinct. Pour cette voie XDNA1 documentée,
`iree-amd-aie` compilé depuis les sources est la voie de calcul utilisée sous
Linux. Cette page est le delta **XDNA2** (Strix Point / Strix Halo /
Krackan), sans fard : ce qui, parmi les recettes et outils de ce dépôt, se transfère,
ce que la seconde génération change, et où se situe désormais la frontière ouverte.

Le but reste le même à chaque génération : transformer le NPU déjà présent
dans un ordinateur personnel en infrastructure Linux inspectable et réutilisable.
La mission se trouve dans l'[Open NPU Lab](OPEN-NPU-LAB.md), et les sources
primaires au-delà de cette page dans [Research branches](RESEARCH.md).

Deux types d'affirmations ci-dessous, clairement séparés :

- **✅ Vérifié** — reproduit sur une véritable machine XDNA2 :
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · noyau 7.0
  · `amdxdna` intégré · NPU FW 1.1.2.64**.
- **🔎 Recherché** — sourcé depuis les dépôts/docs/benchmarks amont (août 2026),
  avec liens dans le texte, pas encore reproduit ici.

Ce dépôt n'a pas mesuré l'énergie du système sur sa machine Strix. Chaque
chiffre énergétique ci-dessous est explicitement attribué à l'upstream ; ce
n'est pas une preuve du dépôt.

> **Le support exécutable de cette version est plus étroit que l'aperçu de la famille :**
> seul Strix Point `RyzenAI-npu4` / IREE `npu4` est vérifié sur matériel et associé
> automatiquement. Strix Halo `npu5` et Krackan `npu6` ne sont que du contexte ;
> `scripts/detect-npu.sh` les refuse sans cible et résultat CPU vérifiés. Voir
> [SUPPORT.md](SUPPORT.md).

## TL;DR

| | XDNA1 (le territoire de ce dépôt) | XDNA2 |
|---|---|---|
| LLM clé en main sous Linux | Ce dépôt ne livre aucun serveur ; les voies de recherche IREE/IRON bas niveau restent ouvertes | ✅ FastFlowLM + Lemonade |
| Userspace XRT | à compiler/installer selon ce dépôt | ✅ **livré nativement par Ubuntu 26.04** (`libxrt-npu2`) |
| Noyaux personnalisés (voie ouverte) | `iree-amd-aie` et `mlir-aie` épinglés par le dépôt ; `amd/IRON` en mouvement est une voie upstream séparée | les mêmes fondations publiques, avec Strix en cible de premier ordre `npu2`/`npu4` |
| Où vit la contribution | reproduire et composer des blocs Phoenix utiles | noyaux ouverts, quantifiés et fusionnés, et intégration applicative |

Tout ce que ce dépôt enseigne — plomberie XRT, activation memlock/groupe render,
surcoût de dispatch, Peano, écriture de noyaux IRON — **se transfère**. Ce qui change :
les noms de cibles, la géométrie du réseau, et le fait qu'« exécuter un LLM sur le
NPU » n'est plus la frontière sur XDNA2 ; **les noyaux ouverts, quantifiés et optimisés le sont**.

## ✅ Vérifié : une machine Strix Point aujourd'hui, avec les propres outils de ce dépôt

L'exécution de `scripts/check-npu.sh`, non modifié, sur la machine XDNA2 a révélé trois
bugs de script (tous corrigés dans ce commit — voir ci-dessous) et cet état réel :

```
[1] amdxdna module loaded                       ✓
[2] 1022:17f0 Strix/Krackan/Strix Halo NPU      ✓  (XDNA2)
[3] /dev/accel/accel0 root:render 0660, RW      ✓
[4] user in 'render' group                      ✓
[5] memlock = 8192 KB                            ✗  ← the same old blocker
[6] xrt-smi present (2.21.75) but:               ✗
    mmap(len=64MB, MAP_LOCKED) failed (err=-11)
[7] pyxrt present, cannot open device            ✗  (same cause)
```

Trois constats qui méritent d'être soulignés :

1. **Ubuntu 26.04 livre nativement le userspace XRT pour XDNA2.** `libxrt2`,
   `libxrt-npu2`, `libxrt-utils-npu`, `python3-xrt` (2.21.75) s'installent directement
   depuis l'archive — sur XDNA1 les mêmes paquets existent mais aucun runtime livré
   n'exécute de modèle ; sur XDNA2, c'est un chemin de runtime fonctionnel.
2. **Les blocages d'activation sont identiques à XDNA1, octet pour octet** — le memlock
   par défaut de 8 Mo casse le `mmap(MAP_LOCKED)` de 64 Mo de xrt-smi avec `EAGAIN`,
   exactement l'échec pour lequel `scripts/enable-npu.sh` a été écrit — **mais l'ancien
   correctif reste silencieusement sans effet sur un bureau systemd.** limits.d est un
   mécanisme `pam_limits` ; un terminal graphique est un enfant de `user@<uid>.service`
   et hérite à la place du `LimitMEMLOCK` de 8 Mo de *ce service*, et avec le lingering
   activé, même une reconnexion ne redémarre jamais ce service. `enable-npu.sh` écrit
   désormais un drop-in `user@<uid>.service.d` propre à l'UID, désactive uniquement
   l'ancien drop-in générique exact qu'il gérait et applique un `prlimit` au shell
   appelant — l'anatomie complète est dans [GOTCHAS #0](GOTCHAS.fr.md).
3. **Le firmware est à jour d'origine** : FW 1.1.2.64 chargé depuis
   `amdnpu/17f0_10/` — au-dessus du plancher ≥ 1.1.0.0 exigé par FastFlowLM.

### ✅ État final : le NPU XDNA2 s'énumère (même machine, même jour)

Une fois le correctif memlock réellement en place (drop-in + `prlimit`, gotcha #0),
les sept tests passent au vert et la stack userspace ouvre le périphérique :

```
$ xrt-smi examine
XRT
  Version              : 2.21.75
  amdxdna Version      : 7.0.0-29-generic
  NPU Firmware Version : 1.1.2.64
Device(s) Present
|BDF             |Name          |
|[0000:66:00.1]  |RyzenAI-npu4  |

$ python3 -c 'import pyxrt; d = pyxrt.device(0); \
    print(d.get_info(pyxrt.xrt_info_device.name))'
RyzenAI-npu4
```

`RyzenAI-npu4` confirme sur du matériel réel la ligne du décodeur de noms ci-dessous :
Strix Point, pour XRT, c'est `npu4`. Aucune compilation depuis les sources n'a été
nécessaire pour en arriver *là* — l'activation sur XDNA2/Ubuntu 26.04, c'est de la
configuration, pas de la compilation.

## ✅ Calcul : vérifié sur le NPU XDNA2 (même machine, 2026-08-15)

**Enregistrement en direct sur le matériel réel :** comparaisons exactes avec
la référence CPU via IREE `npu4`, vérification de toutes les sorties par
`npu-runner`, puis noyau IRON sur 8 colonnes avec XRT et HRX :

![Vérification en direct du calcul XDNA2 Strix Point avec IREE, npu-runner, XRT et HRX](media/xdna2-compute.gif)

La voie des noyaux directs épinglée par le dépôt a tourné le jour même où l'activation a abouti — `setup-mlir-aie.sh`
non modifié, mlir-aie **1.4.1** (wheel cp314), wheel Peano, le `pyxrt` d'Ubuntu.
Tableaux complets dans [MLIR-AIE.fr.md](MLIR-AIE.fr.md) ; les grandes lignes :

- **GEMM sur les 8 colonnes / 32 tuiles** (`whole_array`, 2048³) : **6.65 TOPS**
  en i8 et **4.64 TFLOPS** en bf16-via-bfp16 — la taille de tuile interne valait
  à elle seule 3.4× (tuiles 32³ → 64³).
- **AIE2P veut du bfp16** : le MAC bf16 est une *émulation* à ~¼ de cadence sur
  XDNA2 (natif sur XDNA1) ; `--emulate-bf16-mmul-with-bfp16 1` est de la
  vitesse gratuite. Les designs bfp16ebs8 natifs se compilent ici avec Peano ;
  les exécuter exige `libxrt-dev` (hôtes C++).
- **`ml/mobilenet` — le design qui échoue sur `CREATE_HWCTX` avec les 4
  colonnes de Phoenix — s'exécute de bout en bout** sur le réseau de 8
  colonnes : ~176 ms/inférence.
- Dans la voie **mlir-aie 1.4.1 épinglée par le dépôt**, les exemples `npu2`
  individuels de softmax, RoPE, SwiGLU, RMSNorm et matmul+épilogue d'activation
  passent. C'est une preuve Strix propre au dépôt pour ces exemples, pas un
  résultat de modèle entier ni le tableau d'opérateurs `amd/IRON` en mouvement.
- Notre noyau personnalisé `relu(a+b)`, porté sur l'API IRON de mlir-aie 1.4.1, monte en
  charge à **8.0× sur 8 colonnes** (`transform_parallel_binary`), 11.2 GB/s
  effectifs.

### ✅ IREE : correction face à la référence CPU sur `npu4` (voie distincte)

Le harness CPU-vs-NPU d'IREE upstream a aussi tourné sur ce matériel avec
`--target_device=npu4`, 4 rangées de cœurs, 8 colonnes de cœurs et Peano 22,
commit `4a1adefa` :

| Matmul IREE | Valeurs comparées | Résultat CPU contre NPU |
|---|---:|---|
| bf16→f32, 64³ | 4 096 | correspondance exacte ; erreur absolue/relative maximale 0 |
| bf16→f32, 512³ | 262 144 | correspondance exacte ; erreur absolue/relative maximale 0 |
| i8→i32, 512³ | 262 144 | 0 divergence |

Ce sont des résultats de correction bf16/i8 d'`iree-amd-aie`, pas la voie
bfp16ebs8 native de `mlir-aie`. Le balayage d'accumulation Peano 21, distinct,
a réussi à K=1216 et échoué pour la première fois à K=1280 ; ce tableau IREE
ne change pas cette frontière. Ces exécutions de correction ne sont par ailleurs
**pas des mesures de performance**.

### Bugs de script découverts en pointant les outils XDNA1 sur XDNA2 (corrigés)

- `check-npu.sh [1]` utilisait `lsmod | grep -q` sous `pipefail` : `grep -q` se termine
  à la première correspondance, `lsmod` meurt d'un SIGPIPE (exit 141), le pipeline
  « échoue » — un faux négatif intermittent (une course) qui ne se déclenche que lorsque
  le module apparaît tôt dans la sortie de `lsmod` (c'est le cas sur une machine Strix
  fraîchement démarrée). Le test vérifie désormais `/sys/module/amdxdna`.
- `check-npu.sh [2]` cherchait `IPU|AI`, la chaîne lspci de XDNA1. XDNA2 s'énumère
  comme `Neural Processing Unit` (périphérique `17f0`). Le test reconnaît désormais les
  deux et signale quelle génération il a trouvée.
- `check-npu.sh [6]` souffrait de la *même* course SIGPIPE que [1] — `xrt-smi examine |
  grep -q` sous `pipefail` — mais celle-ci ne s'arme **qu'une fois que le NPU s'énumère
  effectivement** (les lignes recherchées apparaissent tôt dans un rapport réussi, si
  bien que `grep -q` abandonne pendant que `xrt-smi` écrit encore). Le test a signalé
  la toute première énumération réussie comme un échec, pendant que `pyxrt`, en [7],
  ouvrait le périphérique sans broncher. Il capture désormais la sortie d'abord, puis
  fait la correspondance.

## 🔎 Le décodeur de noms (la confusion inter-générations n° 1)

| Couche | XDNA1 | XDNA2 Strix Point | Source |
|---|---|---|---|
| lspci | `AMD IPU Device` (`1502`) | `Neural Processing Unit` (`17f0`) | ✅ les deux machines |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4` (Halo=`npu5`, Krackan=`npu6`) | ✅ cette machine rapporte `RyzenAI-npu4` · [xdna-driver](https://github.com/amd/xdna-driver) |
| mlir-aie / IRON | `npu1` | `npu2` | [mlir-aie](https://xilinx.github.io/mlir-aie/) |
| iree-amd-aie | `npu1_4col` | `npu4` | [iree-amd-aie](https://github.com/nod-ai/iree-amd-aie) |
| ISA | AIE2 | AIE2P | [Peano](https://github.com/Xilinx/llvm-aie) |

## 🔎 Le retournement du paysage : le clé en main existe sur XDNA2 — avec un hic

- **FastFlowLM** a livré la prise en charge native de Linux en v0.9.35 (2026-03-11),
  **uniquement XDNA2** — XDNA1 reste exclu de ce produit. Ce dépôt conserve
  donc sa voie compilateur depuis les sources, tandis que la bibliothèque AMD
  IRON séparée et en mouvement fournit une autre surface de recherche Phoenix
  ouverte. FLM v1.0.0 est passée
  dans l'[org GitHub ROCm](https://github.com/ROCm/FastFlowLM) d'AMD (2026-08).
  **Lemonade** l'enveloppe dans un serveur compatible OpenAI
  ([guide Linux](https://lemonade-server.ai/flm_npu_linux.html)).
- **Le hic :** la CLI de FLM est sous MIT, mais ses **noyaux NPU sont des binaires
  propriétaires gratuits à l'usage**. C'est un produit à utiliser, pas une base de code
  pour apprendre l'écriture de noyaux. La voie des noyaux ouverts — le territoire de ce
  dépôt — est là où vit désormais la contribution XDNA2.
- **Toujours manquant sous Linux**, toutes générations confondues : le Vitis AI EP d'ONNX Runtime
  ([docs](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html))
  — si bien que l'approche de filtrage du graphe de `npu-trim` conserve sa niche sur XDNA2 aussi.
  GAIA sous Linux ne pilote que l'iGPU
  ([amd/gaia#1220](https://github.com/amd/gaia/issues/1220) réclame la route NPU).

## Actif par actif : ce qui, de ce dépôt, se porte sur XDNA2

| Actif | Statut XDNA2 | Ce qui change |
|---|---|---|
| `scripts/check-npu.sh` | ✅ fonctionne (ce commit) | chaîne PCI XDNA2 + rapport de génération ; [6] correctif du SIGPIPE côté succès ; [5] diagnostique désormais la divergence memlock pam-vs-systemd |
| `scripts/enable-npu.sh` | ✅ fonctionne (étendu dans ce commit) | les 3 mêmes blocages ; Ubuntu 26.04 préinstalle les paquets — mais sur un bureau systemd, le correctif memlock exige un drop-in `user@<uid>.service.d` propre à l'UID en plus de limits.d ; le script désactive uniquement son ancien fichier générique exact ([gotcha #0](GOTCHAS.fr.md)) |
| `scripts/build.sh` (iree-amd-aie) | ✅ vérifié sur le matériel | build source + installation achevés sur Strix ; le parallélisme borné évite l'OOM observé et le contrôle final exige `npu1_4col` et `npu4` ; testé avec Peano 22 `4a1adefa` |
| `scripts/run-matmul.sh` | ✅ vérifié sur le matériel | détecte la grille 4×8 et choisit `npu4` ; i32 128³ et bf16 512³ se compilent et s'exécutent correctement tout en conservant la voie XDNA1 |
| `tools/npu-runner` | ✅ vérifié sur le matériel | l'auto-détection de grille de l'API C résout 4×8 ; le runner natif et la voie ctypes/Python ont vérifié les 16 384 valeurs de sortie i32 |
| [`examples/local-rag-sidecar`](../examples/local-rag-sidecar/) | ✅ intégration vérifiée sur matériel `npu4` | Hashing CPU déterministe → scoring bf16 NPU persistant → top-k CPU, avec les 65 536 sorties vérifiées. C'est une référence d'intégration, pas un retriever entraîné ; une petite requête unique sera probablement plus rapide sur CPU. |
| `tools/npu-trim` | ✅ concept intact | `build.sh` installe `iree-import-onnx` épinglé séparément ; l'outil extrait et teste la compilation de formes matmul/conv indépendantes. Il ne reconstruit pas un modèle entier : poids, layouts, glue non prise en charge, fallback et orchestration appartiennent à l'application. |
| Voie `mlir-aie` épinglée par le dépôt | ✅ **vérifiée sur matériel Strix** | [`mlir-aie` 1.4.1](https://github.com/Xilinx/mlir-aie/releases) traite Strix comme `npu2`, emploie Peano par défaut et fournit la voie de noyaux directs mesurée dans [MLIR-AIE.fr.md](MLIR-AIE.fr.md). Le backend Python HRX optionnel exige un `libhrx` externe ; les artefacts du dépôt utilisaient encore XRT, ce n'est donc pas une affirmation entièrement sans XRT. |
| Bibliothèque d'opérateurs `amd/IRON` en mouvement | 🔎 **preuve matérielle upstream séparée** | Au commit exact `cdc48e93`, les cinq itérations par défaut du workflow Phoenix du 2026-08-15 annoncent **2 105 exécutions de cas réussies / 45 ignorées**, soit **421 configurations réussies distinctes / 9 skips distincts**.[^iron-phoenix] Ne pas fusionner cet arbre mobile ni sa CI Phoenix avec le résultat Strix 1.4.1 épinglé par le dépôt. |

## 🔎 Le delta matériel qui compte quand vous écrivez des noyaux

- **Géométrie** : npu1 est un réseau de 4 colonnes ; Strix Point (`npu4`) fait **4 rangées × 8
  colonnes — 32 tuiles de calcul + 8 tuiles mémoire**, partitionnable aux frontières de
  colonnes, avec un ordonnancement des contextes géré par le firmware
  ([docs du noyau](https://docs.kernel.org/accel/amdxdna/amdnpu.html)).
- **Type de données** : l'argument phare d'AIE2P est la **virgule flottante par blocs
  bfp16** — 8 valeurs partagent un exposant de 8 bits, 9 octets pour 8 valeurs.
  Depuis les nightlies actuelles de Peano, c'est réel sous la stack ouverte :
  clang livre les builtins de conversion `__builtin_aie2p_*bfp16ebs8/16` et de
  MAC `BFP576_BFP576_ACC2048`, et les GEMM `ml/block_datatypes` se compilent
  avec Peano (✅ compilés sur cette machine). Le revers : **le MAC bf16 a
  régressé** — natif en 4×8×4 sur AIE2, émulation à ~¼ de cadence via le chemin
  de données bfp16 sur AIE2P
  ([mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390),
  [Hello XDNA](https://tnzr.org/xdna/isa.html)). Les noyaux réglés pour le bf16
  sur npu1 exigent une réécriture bfp16 pour atteindre le débit de pointe sur
  npu2 ; le C++ des noyaux est conditionné par architecture via `__AIEARCH__`
  (20 = AIE2, 21 = AIE2P) et l'amont maintient des arbres parallèles
  `aie_kernels/aie2/` et `aie2p/`.
- **ISA** : toujours aucun manuel officiel, mais dans les faits ouverte — Peano l'implémente
  dans le LLVM public, et [Hello XDNA](https://tnzr.org/xdna/isa.html) reconstruit
  l'ISA XDNA1/XDNA2 avec les latences par instruction.

## 🔎 Réalité mesurée : les LLM sur le NPU XDNA2 (pourquoi les noyaux sont la frontière)

- FLM sur un XDNA2 de 50 TOPS : Llama 3.1 8B **prefill 403 t/s** @1k ctx, decode
  12.8 t/s ; gpt-oss-20b decode 18.2 @1k → 12.0 @32k
  ([benchmarks FLM](https://fastflowlm.com/docs/benchmarks/llama3_results/)).
- Comparaison à silicium égal : le NPU gagne en **prefill ~1.5×** face au Vulkan de
  l'iGPU, perd ~25% en decode, avec jusqu'à ~10× de mieux en efficacité énergétique.
  Le decode relève de la physique de la bande passante mémoire (~120 GB/s de LPDDR5X
  partagée entre CPU/iGPU/NPU) — aucun moteur n'y échappe.
- Point de calibration pour le code ouvert : un fork llama.cpp naïf en dispatch XRT ouvert
  ([OllamaAMDNPU](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU),
  Strix Halo) atteint prefill 18.4 t/s, decode 1.4 t/s — l'écart avec le prefill à
  300–400 t/s de FLM tient à **la conception des noyaux et du dataflow, pas à la plomberie du dispatch**.
- L'architecture qui a du sens : **l'hybride prefill-NPU + decode-iGPU** —
  exactement la façon dont la stack Windows d'AMD elle-même répartit le travail.

### Pont de recherche entre générations

Les travaux ouverts dépassent déjà les exemples épinglés du dépôt, mais leurs
références doivent rester distinctes. L'expérience Phoenix de Rösti et Franz
déporte les GEMM du fine-tuning de GPT-2 124M vers un NPU de première génération
et publie ses chiffres hybrides de débit et d'énergie.[^phoenix-gpt2] STEEL
rapporte en moyenne **9,6× de latence XDNA1 face à DATO** ; ses chiffres
d'énergie CPU/GPU proviennent d'une expérience HX 370/**XDNA2** séparée, et non
de ce port XDNA1.[^steel] Ce sont des résultats publiés à reproduire et étendre,
pas des benchmarks appartenant à ce dépôt.

## La suite

1. ~~Reproduire le GEMM `mlir-aie` direct sur le réseau 4×8~~ — **✅ fait** avec
   mlir-aie 1.4.1 épinglé par le dépôt :
   GEMM sur tableau entier à 6.65 TOPS i8 / 4.64 TFLOPS bf16-bfp16, blocs LLM,
   MobileNet complet ; voir [MLIR-AIE.fr.md](MLIR-AIE.fr.md). Séparément, le
   commit exact `amd/IRON` `cdc48e93` possède un workflow matériel Phoenix dont
   les cinq itérations par défaut donnent **2 105 exécutions de cas réussies /
   45 ignorées**, soit **421 configurations réussies distinctes / 9 skips
   distincts**. Les cas réussis comprennent GEMM/GEMV bf16,
   déquantification Q4NX, softmax, RoPE, RMSNorm, LayerNorm, activations,
   transpose et SwiGLU decode/prefill. Les skips distincts sont exactement 3
   configurations MHA, 3 streaming-SwiGLU-prefill et 3 GEMV+GELU ; chacune est
   répétée cinq fois, formant trois groupes de 15 exécutions. Le tableau MHA/GQA
   est **AIE2P-only**.[^iron-phoenix] Cela élargit les expériences à ramener sur
   XDNA1 ; ce n'est ni un nouveau passage Phoenix du verrou courant de ce dépôt,
   ni un LLM complet.
2. ~~Porter les recettes de matmul d'iree-amd-aie + `npu-runner` vers `npu4`
   et clore la correction face à la référence CPU~~ — **✅ fait**. Le build, le
   script matmul sensible à la génération, le runner persistant en API C et le
   wrapper Python ont tous tourné sur cette machine Strix ; le harness upstream
   a produit le tableau de correspondances exactes ci-dessus. Une comparaison
   de performance XDNA1-vs-XDNA2 contrôlée reste un travail distinct ; aucune
   affirmation de vitesse n'est tirée de ces exécutions de correction.
3. **GEMM de prefill quantifié** — la surface de contribution est désormais
   précisément cartographiée. **TileFuse est une recherche XDNA2 externe**, pas
   un résultat runtime du dépôt : l'article publie une recette W4A16 et du code externe
   ([glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
   fork ~13 mois derrière main, **chess d'abord** avec Peano en option ; AWQ
   group-128, k-tile = taille de groupe, dequant fusionné dans la tuile avec un
   cache L1 weight-stationary, 9 TOPS sur Strix Point). Dans les sources citées
   et auditées le **2026-08-15**, nous n'avons identifié ni port public de ce
   noyau TileFuse vers **mlir-aie 1.4.1 épinglé par le dépôt + Peano seul**, ni
   intégration TileFuse publique dans llama.cpp. C'est le résultat daté d'une
   recherche, **pas une preuve d'absence**. La
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725) reste ouverte
   et non revendiquée (le WIP de son auteur est au point mort depuis 2026-04 ;
   l'effort actif d'AMD est
   [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend) sur le
   runtime HSA/ROCr — une stack différente du XRT d'Ubuntu).
   **L'alignement des buffers à 64 Kio reste une hypothèse de benchmark à
   tester.** Le ticket llama.cpp #21725 lié ne fournit ni expérience primaire
   ni log brut à l'appui ; ce dépôt ne formule donc **aucune affirmation de
   decode 10×**.
   **Statut du dépôt : compilation seule (2026-08-15)** : le kernel fusionné
   dequant+GEMM de TileFuse (`mix_int4_ATB.cc`) **compile proprement avec
   Peano pour `aie2p` contre les en-têtes mlir-aie 1.4.1**
   (`-Dbf16_bf16_ONLY`, m64/k128/n64 → `matmul_bf16_bf16`). Cela franchit une
   barrière de compilation front-end pour cette spécialisation, mais ne termine
   **pas** le portage. Restent l'intégration IRON/ObjectFifo, l'édition de liens,
   le placement, la concordance ABI, le packing des poids côté hôte, l'exécution
   sur NPU et la vérification numérique. Le script épinglé
   [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) consigne le
   commit source externe, les sommes de contrôle et les options front-end
   exactes. Le dépôt ne possède aucun résultat W4A16 d'exécution matérielle,
   de justesse, de débit ou d'énergie.

*Statut : page ajoutée le 2026-08-15 ; l'activation, le calcul par noyaux directs et le
portage IREE `npu4` avec correction face à la référence CPU ont été vérifiés
le jour même sur la machine Strix Point ci-dessus. Les éléments 🔎 portent
leurs sources dans le texte.*

[^iron-phoenix]: AMD, [`IRON` au commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) et [workflow matériel Phoenix extensive 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), 2026-08-15. Avec les cinq itérations par défaut, 2 105 exécutions de cas réussies et 45 ignorées représentent 421 configurations réussies distinctes et 9 skips distincts. Preuve upstream, pas une exécution XDNA1 exact-v1 du dépôt.
[^phoenix-gpt2]: A. Rösti et M. Franz, [« Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools »](https://arxiv.org/abs/2504.03083), FCCM 2025. Phoenix de première génération, fine-tuning hybride de GPT-2 124M ; non reproduit ici.
[^steel]: V. J. B. Jung et al., [« STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU »](https://arxiv.org/abs/2607.09385), IEEE COINS 2026. Garder séparées ses expériences de latence XDNA1 et d'énergie XDNA2.
