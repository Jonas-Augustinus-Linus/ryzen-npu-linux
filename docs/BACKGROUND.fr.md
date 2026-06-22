**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Contexte : XDNA1, XDNA2, et pourquoi Linux est difficile pour la première génération

## La puce

Le NPU Ryzen AI d'AMD est un réseau spatial **AI Engine (AIE)** hérité de Xilinx —
une grille de tuiles vectorielles VLIW reliées par une interconnexion de streaming/DMA, plus des rangées
de mémoire et des rangées « shim » qui font le pont vers l'hôte. On le programme en plaçant le calcul sur les
tuiles et en routant les données entre elles (dataflow), et non avec un noyau de style CUDA.

Deux générations comptent ici :

| | **XDNA1** (« Phoenix »/« Hawk Point ») | **XDNA2** (« Strix », etc.) |
|---|---|---|
| Présent dans | Ryzen 7040 / 8040 (par ex. **7840U**) | Série Ryzen AI 300 |
| Architecture des tuiles | AIE2 (`aie2`) | AIE2P |
| Géométrie Phoenix | 4 rangées de cœurs × **4 colonnes utilisables** (5 brutes), `npu1_4col` | plus grande, `npu4` |
| ID PCI | `1022:1502` | `1022:17f0` |
| ~Perf | ~10 TOPS | ~50 TOPS |

## La situation logicielle Linux (mi-2026)

Le côté **noyau** est résolu : le pilote DRM accel `amdxdna` a été intégré en amont dans
**Linux 6.14** (le firmware aussi). Sur un noyau moderne, le NPU est énuméré comme
`/dev/accel/accel0` et `xrt-smi` le voit — pour les **deux** générations.

Le côté **espace utilisateur / compilateur** est là où XDNA1 décroche :

- **AMD Ryzen AI Software for Linux** (1.7.x) — prend en charge **STX/KRK (XDNA2) uniquement**.
- **ONNX Runtime + Vitis AI EP** — sous Linux x86_64, le compilateur de graphes client-NPU
  n'est pas livré ; les ops basculent sur le CPU.
- **Lemonade / FastFlowLM** (les projets « NPU LLMs on Linux ») — **XDNA2 uniquement** ;
  ils indiquent explicitement que la série 7000/8000 XDNA1 n'est pas prise en charge.

Ainsi, XDNA1 sous Linux est **visible par le pilote mais orphelin côté applications** par les
stacks clés en main. L'exception — le seul chemin ouvert activement développé qui cible *explicitement*
XDNA1 (`npu1`, 4×5) — est **`nod-ai/iree-amd-aie`**, un plugin IREE. C'est du
niveau recherche (des noyaux, pas des modèles arbitraires), mais cela tourne réellement sur le
matériel. C'est ce que construit ce dépôt.

## Comment le HAL `amdxdna` atteint le périphérique

`iree-amd-aie` compile votre matmul vers :

1. **Le code des cœurs AIE** — Peano (`llvm-aie`, un fork de LLVM avec une cible `aie2`)
   compile les programmes par tuile (`core_<col>_<row>.elf`).
2. **La configuration / le contrôle** — l'abaissement (lowering) dataflow object-FIFO ou AIR, le
   routage de paquets et un programme de contrôle, empaquetés (via `bootgen`) dans le `.vmfb`.

À l'exécution, le **HAL `amdxdna`** (intégré au runtime avec
`-DIREE_EXTERNAL_HAL_DRIVERS=amdxdna`) **ouvre `/dev/accel/accel0` directement** et
émet des ioctls DRM (`DRM_IOCTL_AMDXDNA_GET_INFO`, soumission de commandes, attente de fence)
en utilisant un en-tête UAPI vendoré. Il ne lie **pas** la bibliothèque externe XRT `xrt_coreutil`
— c'est le HAL `xrt` séparé et expérimental. C'est pourquoi vous n'avez **pas** besoin
de construire le `xdna-driver` hors arbre d'AMD lorsque le `amdxdna.ko` intégré à l'arbre est présent.

Le périphérique signale sa géométrie via le même ioctl ; `npu1_4col` et
`--amdxdna_n_core_cols=4` doivent concorder avec elle (voir [GOTCHAS #6](GOTCHAS.fr.md)).

## Références

- Docs `xdna-driver` d'AMD et `amdxdna` du noyau (kernel.org `accel/amdxdna`)
- `nod-ai/iree-amd-aie` (README, `build_tools/ci/`)
- `Xilinx/llvm-aie` (Peano)
- IREE (`iree.dev`)
