**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Où peut-on réellement utiliser un NPU XDNA1 sous Linux ?

Soyez honnête avec vous-même quant au niveau de maturité. Ce que vous offre
aujourd'hui `iree-amd-aie` sur XDNA1+Linux, c'est un **compilateur + runtime pour
kernels AIE** (matmul, conv et les opérations élémentaires qui les entourent),
accessible depuis la CLI `iree-*` et l'API C du runtime IREE. Ce n'est **pas** un
serveur de modèles clé en main.

## Le modèle mental : NPU vs iGPU vs CPU sur ce portable

| Périphérique | Excelle à | À utiliser pour |
|---|---|---|
| **NPU (XDNA1, ~10 TOPS)** | kernels d'inférence quantifiés/bf16 soutenus et à **faible consommation** | décharger des blocs matmul/conv spécifiques tout en ménageant la batterie |
| **iGPU (Radeon 780M)** | calcul généraliste à haut débit | **votre véritable cheval de bataille pour l'IA locale sous Linux aujourd'hui** — LLM via Vulkan/ROCm |
| **CPU** | tout, latence flexible | colle, contrôle, repli |

La raison d'être même du NPU, c'est la **performance par watt**. Si la consommation
vous est indifférente, l'iGPU 780M est la voie la plus rapide et de loin la plus
simple pour l'IA généraliste sous Linux.

## ✅ Bons usages dès aujourd'hui

- **Apprendre la programmation NPU / dataflow spatial.** Un vrai périphérique vers
  lequel compiler et que l'on regarde s'exécuter. `run-matmul.sh` est une base
  fonctionnelle à modifier.
- **Benchmarker le NPU** pour matmul/conv selon diverses formes et types de données (i32, bf16→f32).
- **Primitives d'inférence à faible consommation.** Des kernels matmul/conv
  construits à la main que vous intégrez dans une application via l'API C du runtime
  IREE et que vous dispatchez avec `--device=amdxdna`, afin de maintenir une charge
  de travail régulière et légère hors du CPU/GPU (par ex. petits étages de CNN,
  extracteurs de caractéristiques, matmuls de traitement du signal).
- **Prototypage / recherche** sur le tiling AIE, les pipelines objectFifo vs air, le
  packet flow — les briques qui finissent par rendre viables des modèles plus grands.
- **Contribuer en amont.** Chaque résultat sur XDNA1 sous Linux est utile ; la CI du
  projet dispose d'un runner Phoenix dédié, mais la couverture communautaire est mince.

## 🚫 Pas réaliste sur XDNA1+Linux aujourd'hui

- **Servir LLM / Whisper / Stable Diffusion clé en main sur le NPU.** Aucun runtime
  prêt à l'emploi ne cible XDNA1 sous Linux. Utilisez l'**iGPU** (Ollama/llama.cpp
  Vulkan, ROCm), ou **Windows** (Vitis AI hérité / Studio Effects), ou du matériel **XDNA2**.
- **« Pointe-le vers mon `.onnx` et c'est parti. »** Le Vitis AI EP d'ONNX Runtime se
  rabat sur le CPU pour les NPU client sous Linux. Vous écrivez/abaissez des kernels,
  vous n'importez pas des graphes arbitraires.
- **Pipelines quantifier-et-déployer.** Les outils de quantification existent ; c'est
  le *runtime* permettant d'exécuter le résultat sur XDNA1+Linux qui manque — alors ne
  quantifiez pas en espérant déployer ici.

## Comment intégrer un kernel compilé dans une application

Le `.vmfb` produit par `iree-compile` est chargé par le runtime IREE. Au choix :

- **CLI** : `iree-run-module --device=amdxdna ... --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4`
  (idéal pour les jobs batch / scripts), ou
- **API C** : liez `iree/runtime` depuis votre `iree-install`, créez le périphérique
  HAL `amdxdna`, chargez le module et invoquez-le — exactement le même chemin que celui
  qu'utilise la CLI. C'est ainsi que vous câbleriez un matmul/conv NPU dans un véritable
  pipeline à faible consommation.

## Si vous voulez un usage NPU clé en main

1. **Matériel XDNA2** (Strix / Strix Halo / Krackan) — là où atterrit réellement tout
   l'élan Linux NPU de 2026 (Lemonade/FastFlowLM, AMD Ryzen AI SW pour Linux).
2. **Windows** sur ce même 7840U — le chemin Vitis AI hérité et Windows Studio Effects
   y prennent bel et bien en charge Phoenix.
