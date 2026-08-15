**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2 (Strix) — ce qui change, ce qui se transfère

Ce dépôt est la carte vérifiée pour **XDNA1** (Phoenix/Hawk Point), où
`iree-amd-aie` compilé depuis les sources reste la *seule* façon d'exécuter du calcul
sur le NPU sous Linux. Cette page est le delta **XDNA2** (Strix Point / Strix Halo /
Krackan), sans fard : ce qui, parmi les recettes et outils de ce dépôt, se transfère,
ce que la seconde génération change, et où se situe désormais la frontière ouverte.

Deux types d'affirmations ci-dessous, clairement séparés :

- **✅ Vérifié** — reproduit sur une véritable machine XDNA2 :
  **Ryzen AI 9 HX PRO 370 (Strix Point) · Radeon 890M · Ubuntu 26.04 · noyau 7.0
  · `amdxdna` intégré · NPU FW 1.1.2.64**.
- **🔎 Recherché** — sourcé depuis les dépôts/docs/benchmarks amont (août 2026),
  avec liens dans le texte, pas encore reproduit ici.

## TL;DR

| | XDNA1 (le territoire de ce dépôt) | XDNA2 |
|---|---|---|
| LLM clé en main sous Linux | ❌ aucun — exclu par toutes les stacks livrées | ✅ FastFlowLM + Lemonade 10.0 (depuis 2026-03) |
| Userspace XRT | à compiler/installer selon ce dépôt | ✅ **livré nativement par Ubuntu 26.04** (`libxrt-npu2`) |
| Noyaux personnalisés (voie ouverte) | `iree-amd-aie` / `mlir-aie` depuis les sources | même stack, mieux prise en charge : IRON 1.4.x traite Strix en cible de premier ordre |
| Où vit la contribution | faire tourner *quoi que ce soit* | combler l'écart des noyaux ouverts (les noyaux NPU clés en main sont propriétaires) |

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
   désormais aussi un drop-in `user@.service` et applique un `prlimit` au shell
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

La voie IRON a tourné le jour même où l'activation a abouti — `setup-mlir-aie.sh`
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
- Les blocs LLM passent tous sur `npu2` : softmax, RoPE, SwiGLU, RMSNorm,
  matmul + épilogue d'activation.
- Notre noyau personnalisé `relu(a+b)`, porté sur l'API IRON 1.4.x, monte en
  charge à **8.0× sur 8 colonnes** (`transform_parallel_binary`), 11.2 GB/s
  effectifs.

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
  **uniquement XDNA2** — XDNA1 reste exclu, raison pour laquelle la voie
  depuis-les-sources de ce dépôt demeure la seule route XDNA1. FLM v1.0.0 est passée
  dans l'[org GitHub ROCm](https://github.com/ROCm/FastFlowLM) d'AMD (2026-08).
  **Lemonade 10.0** l'enveloppe dans un serveur compatible OpenAI
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
| `scripts/enable-npu.sh` | ✅ fonctionne (étendu dans ce commit) | les 3 mêmes blocages ; Ubuntu 26.04 préinstalle les paquets — mais sur un bureau systemd, le correctif memlock exige un drop-in `user@.service` en plus de limits.d ([gotcha #0](GOTCHAS.fr.md)) |
| `scripts/build.sh` (iree-amd-aie) | 🔎 devrait se porter | `npu4` est une cible prise en charge ; projet actif (ukernel softmax pour Peano npu4, batching ERT_CMD_CHAIN). Le piège des commits en lockstep (xdna-driver épinglé) demeure |
| `scripts/run-matmul.sh` | 🔎 devrait se porter | cible `npu1_4col` → `npu4` ; les drapeaux HAL `amdxdna` restent |
| `tools/npu-runner` | 🔎 devrait se porter | API C d'IREE inchangée — recompiler contre le build npu4 |
| `tools/npu-trim` | ✅ concept intact | la frontière de couverture d'ops se déplace, approche identique ; toujours aucun EP fournisseur sous Linux pour le remplacer |
| voie `mlir-aie` (IRON) | ✅ **vérifiée — la voie la plus solide** (ce commit) | IRON [1.4.1](https://github.com/Xilinx/mlir-aie/releases) : Strix en premier ordre (`npu2`), **Peano par défaut**, `aiecc` désormais un binaire C++, exemples pilotés par lit ; nos scripts + noyau personnalisé portés (rupture de l'API d'annotations — [GOTCHAS](GOTCHAS.fr.md)) ; les chiffres dans [MLIR-AIE.fr.md](MLIR-AIE.fr.md). Correction par rapport à la recherche antérieure : il n'existe **aucun runtime « HRX »** sans XRT — le module est `aie.utils.hostruntime` *avec un backend XRT* ; et [amd/IRON](https://github.com/amd/IRON) ne livre **aucun wheel** (installation depuis les sources uniquement, épinglée à un instantané mlir_aie 1.3.5.dev) |

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

## La suite

1. ~~Reproduire le GEMM d'IRON sur le réseau 4×8~~ — **✅ fait** (mlir-aie 1.4.1,
   GEMM sur tableau entier à 6.65 TOPS i8 / 4.64 TFLOPS bf16-bfp16, blocs LLM,
   MobileNet complet ; [MLIR-AIE.fr.md](MLIR-AIE.fr.md)). GQA/MHA : la
   bibliothèque d'ops [amd/IRON](https://github.com/amd/IRON) les propose
   **uniquement pour aie2p** (head-dim 64 seulement) — mais elle s'installe
   uniquement depuis les sources, épinglée à un instantané mlir_aie 1.3.5.dev,
   et sa seule op de quantification est le *dequant* (Q4NX/AWQ → bf16). Aucun
   wheel, aucun W4A16 fusionné.
2. **Porter les recettes de matmul d'iree-amd-aie + `npu-runner` vers `npu4`**
   et publier les chiffres XDNA1 vs XDNA2 côte à côte. (Bloqué sur cette
   machine uniquement par les outils de build — `ninja`/`lld` demandent un apt
   install ; le flot lui-même devrait se porter : `npu4` est une cible prise en
   charge.)
3. **GEMM de prefill quantifié** — la surface de contribution, désormais
   cartographiée avec précision : [TileFuse](https://arxiv.org/abs/2606.11357)
   a publié la recette W4A16 *et le code*
   ([glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification),
   fork ~13 mois derrière main, **chess d'abord** avec Peano en option ; AWQ
   group-128, k-tile = taille de groupe, dequant fusionné dans la tuile avec un
   cache L1 weight-stationary, 9 TOPS sur Strix Point). Ce qui n'existe **nulle
   part** en ouvert : ce noyau sur **IRON 1.4.x actuel + Peano seul**, et toute
   intégration llama.cpp. La
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725) reste ouverte
   et non revendiquée (le WIP de son auteur est au point mort depuis 2026-04 ;
   l'effort actif d'AMD est
   [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend) sur le
   runtime HSA/ROCr — une stack différente du XRT d'Ubuntu). Également mesuré
   en amont et bon à reprendre : **l'alignement des buffers à 64 Ko (page SMMU)
   était un levier de 10× en decode** dans les expériences IRON citées dans
   #21725.
   **Spike vérifié sur cette machine (2026-08-15)** : le kernel fusionné
   dequant+GEMM de TileFuse (`mix_int4_ATB.cc`) **compile proprement avec
   Peano pour `aie2p` contre les en-têtes mlir-aie 1.4.1**
   (`-Dbf16_bf16_ONLY`, m64/k128/n64 → `matmul_bf16_bf16`) — l'écart de
   portage est le design ObjectFifo + le packing côté hôte, pas le kernel.

*Statut : page ajoutée le 2026-08-15 ; activation, puis calcul IRON, vérifiés
le jour même sur la machine Strix Point ci-dessus. Les éléments 🔎 portent
leurs sources dans le texte.*
