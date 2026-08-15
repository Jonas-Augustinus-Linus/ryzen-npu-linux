**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# Contexte : XDNA1, XDNA2 et les voies Linux ouvertes

## Le silicium ne devient pas inutile lorsque la pile clé en main passe à la suite

Le NPU Ryzen AI d'AMD est une matrice spatiale **AI Engine (AIE)** héritée de
Xilinx : des tuiles vectorielles VLIW reliées par une interconnexion de
streaming/DMA, avec des rangées mémoire et shim qui rejoignent l'hôte. Les
programmes placent le calcul sur les tuiles et routent les données entre elles,
au lieu de traiter le périphérique comme un GPU généraliste de type CUDA.[^iron-guide]

| | **XDNA1** (Phoenix/Hawk Point) | **XDNA2** (Strix et appareils apparentés) |
|---|---|---|
| Présent dans | Ryzen 7040/8040, dont le **7840U** | famille Ryzen AI 300 |
| Architecture des tuiles | AIE2 (`aie2`) | AIE2P |
| Cible du dépôt | Phoenix : 4 colonnes utilisables, `npu1_4col` | Strix vérifié : `npu4` |
| Performance NPU nominale | jusqu'à 10 TOPS pour le 7840U[^amd-7840u] | jusqu'à 50 TOPS pour Ryzen AI 300[^amd-platform-guide] |

La fiche officielle du 7840U décrit toujours un moteur Ryzen AI atteignant
10 TOPS. Cette capacité ne disparaît pas parce que les logiciels applicatifs
actuels ne listent plus Phoenix.[^amd-7840u]

## La situation Linux au 15 août 2026

Le socle noyau est commun. Le pilote ouvert `amdxdna` d'AMD expose les appareils
pris en charge via l'interface d'accélération Linux ; AMD publie le pilote, le
shim XRT, les exigences de firmware et les instructions d'installation.[^amdxdna]

La couche produit pratique dépend de la génération. Ryzen AI Software 1.8 for
Linux cite **STX et KRK**, pas Phoenix/XDNA1.[^ryzenai-linux]
C'est l'état de la matrice de support clé en main, pas la preuve que XDNA1 ne
peut pas calculer sous Linux.

Les expérimentateurs XDNA1 disposent désormais de **deux voies ouvertes de
plus bas niveau** :

1. **La voie empaquetée par ce dépôt :** la pile
   [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) verrouillée
   sur des versions exactes. Elle abaisse des programmes IREE, empaquette des
   modules VMFB propres au périphérique et les invoque via le HAL `amdxdna`.
   Les scripts du dépôt verrouillent, compilent, détectent, exécutent et
   comparent toutes les sorties à des références CPU. Les mesures Phoenix
   publiées sont des résultats matériels historiques du nightly de l'époque ;
   le verrou exact v1 actuel a été revalidé sur Strix et attend un nouvel essai Phoenix.
2. **La voie de noyaux directs :**
   [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) avec Peano et XRT.
   Ce dépôt verrouille sa pile API Python/compilateur IRON en version 1.4.1 ; le
   développeur y écrit directement les noyaux spatiaux AIE et leurs transferts.
   La bibliothèque plus récente d'opérateurs/applications
   [`amd/IRON`](https://github.com/amd/IRON) est un projet distinct bâti sur les
   bindings du langage MLIR-AIE, ni un renommage ni un nouvel emplacement de
   `Xilinx/mlir-aie`. Ses résultats amont sont à reproduire, pas des garanties
   héritées par ce verrou de version.

Au commit AMD IRON
[`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93), le workflow Phoenix
officiel s'est terminé avec **2 105 exécutions de cas pytest réussies et 45
ignorées**.[^iron-phoenix-ci] Avec cinq itérations par défaut, cela correspond à
**421 configurations distinctes réussies et 9 configurations distinctes
ignorées**. Les neuf skips sont trois MHA, trois streaming-SwiGLU et trois
GEMV+GELU, chacune répétée cinq fois. L'exécution matérielle AIE2/Phoenix
comprend parmi ses réussites GEMM/GEMV, déquantification Q4NX,
softmax, RoPE, RMSNorm/LayerNorm, activations et transposition, tous comparés à
une référence CPU. C'est une preuve amont solide de l'intérêt de XDNA1 comme
laboratoire de noyaux ML. Ce n'est **ni** une réexécution de la pile v1 exacte
de ce dépôt, **ni** une démonstration LLM XDNA1 de bout en bout. MHA et
streaming-SwiGLU figurent parmi les skips exacts ; GQA n'est pas établi par ce
run Phoenix. Cette limite doit accompagner le résultat.

## Comment la voie HAL `amdxdna` de ce dépôt atteint l'appareil

`iree-amd-aie` transforme une opération prise en charge en :

1. **Programmes de cœurs AIE.** Peano (`llvm-aie`) compile du code par tuile
   pour l'architecture AIE concernée.
2. **Configuration et contrôle.** Abaissement dataflow, routage, code DMA/de
   contrôle et programmes du périphérique sont empaquetés dans un `.vmfb`.
3. **Invocation hôte.** Le HAL IREE `amdxdna` ouvre `/dev/accel/accel0`, soumet
   les commandes via l'UAPI noyau et attend les fences. Cette voie diffère du
   chemin hôte XRT/`pyxrt` séparé des exemples IRON.

La géométrie du périphérique fait partie du contrat de correction. Pour le
mappage Phoenix vérifié, `npu1_4col` et `--amdxdna_n_core_cols=4` doivent
concorder ; le dépôt ne devine pas de cible pour un appareil ultérieur inconnu.
Voir [GOTCHAS #6](GOTCHAS.fr.md) et la [matrice de support](SUPPORT.md).

## Pourquoi les deux voies comptent

La voie IREE rend praticables l'intégration reproductible dans une application
et un runtime C/Python persistant. IRON expose les tuiles, FIFO, noyaux et la
frontière mouvante des opérateurs. Ensemble, elles permettent à un propriétaire
de portable de partir d'un matmul vérifié par CPU, de composer une IA locale
hybride, puis de déplacer une frontière de compilateur ou d'opérateur à la fois.

Le document anglais [Open NPU Lab](OPEN-NPU-LAB.md) donne la carte du projet,
le [registre de recherche](RESEARCH.md) rassemble sources primaires et portée
des affirmations, et la [feuille de route LLM](LLM-ROADMAP.md) suit le travail restant.

[^amd-7840u]: AMD, [spécifications Ryzen 7 7840U](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html).
[^amd-platform-guide]: AMD, [guide de poche grand public Ryzen et Radeon](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/amd-consumer-pocket-guide-ryzen-radeon-july-2024.pdf), juillet 2024.
[^amdxdna]: AMD, [`xdna-driver` : pilote Linux et interface XRT pour les NPU AMD](https://github.com/amd/xdna-driver).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 — exigences Linux et plateformes prises en charge](https://ryzenai.docs.amd.com/en/latest/linux.html), consulté le 15 août 2026.
[^iron-guide]: AMD IRON, [guide de programmation](https://github.com/amd/IRON/blob/main/programming_guide/README.md).
[^iron-phoenix-ci]: AMD IRON, [workflow Phoenix officiel 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
