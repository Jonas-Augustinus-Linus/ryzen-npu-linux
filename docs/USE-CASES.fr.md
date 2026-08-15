**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Transformer un portable XDNA en laboratoire d'IA locale hybride

Un NPU n'a pas à servir seul un LLM complet pour être utile au système. Sous
Linux avec XDNA1, la voie pratique consiste aujourd'hui à confier au NPU une
petite étape répétée et vérifiable par CPU, à laisser au CPU les E/S, les règles
et les opérations non prises en charge, puis à utiliser l'iGPU pour générer des
tokens à haut débit lorsque l'application en a besoin.

```text
microphone / caméra / documents / événements UI
                          │
                          ▼
               CPU : E/S, contrôle, repli
                          │
               ┌──────────┴──────────┐
               ▼                     ▼
 NPU : déclencheur permanent,   iGPU : LLM quantifié
 scores, blocs dense/conv         prefill + génération
               └──────────┬──────────┘
                          ▼
               CPU : outils, règles, sortie
```

C'est un partage d'ingénierie, pas un verdict universel de performance. Faible
énergie et autonomie accrue sont des objectifs de conception ; ce dépôt n'a
pas encore publié de mesures énergétiques contrôlées de bout en bout qui les prouvent.

## Projets utiles à construire à partir du code fourni

| Projet | Rôle du NPU | Rôle CPU / iGPU | Limite de la preuve |
|---|---|---|---|
| **Assistant RAG privé** | Calculer par lots les scores documents/requêtes via un matmul bf16 persistant | Le CPU segmente, hache et choisit le top-k ; un LLM local sur un autre backend peut générer | [`local-rag-sidecar`](../examples/local-rag-sidecar/) intègre réellement le NPU dans la boucle RAG. Ses caractéristiques sont un sac de mots haché déterministe, **pas des embeddings entraînés** ; pour une petite requête unique, le CPU sera probablement plus rapide. La preuve matérielle actuelle est XDNA2 ; XDNA1 avec le verrou actuel reste à exécuter. |
| **Assistant vocal local** | Tête permanente de wake word ou d'intention | CPU pour le front-end audio et le contrôle ; LLM sur iGPU pour répondre | [`wake-word`](../examples/wake-word/) exécute trois couches denses NPU persistantes, mais les poids fournis illustrent le chemin et ne sont pas un vocabulaire de réveil entraîné. |
| **Déclencheur caméra privé ou d'accessibilité** | Étape de classifieur conv/dense prise en charge | Le CPU capture et compose ; l'application émet un événement Linux | [`npu-camera`](../examples/npu-camera/) prouve le câblage GStreamer → NPU → `v4l2loopback`, mais l'opération actuelle est un flou de boîte non-IA. Remplacez-la par une étape de modèle entraînée et vérifiée par CPU. |
| **Expérience ONNX hybride** | Partitions matmul/conv prises en charge et extraites | Le CPU conserve ReLU, la colle du graphe et le repli | [`onnx-mlp`](../examples/onnx-mlp/) exécute un véritable passage avant hybride, mais le réseau et les poids sont des données de démonstration générées. [`npu-trim`](../tools/npu-trim/) filtre les parties possibles au lieu de rendre magique n'importe quel graphe. |
| **Recherche sur les blocs quantifiés** | GEMM/GEMV, déquantification, normalisation, RoPE et softmax à mesure que chaque voie est validée | Résultat de référence CPU, attention/contrôle non pris en charge ; éventuellement iGPU pour le reste | Le workflow Phoenix IRON officiel d'AMD au commit `cdc48e93` a réussi des exemples AIE2 comparés au CPU pour ces primitives.[^iron-ci] C'est une preuve amont, pas un résultat XDNA1 de ce verrou exact ni un LLM complet. |
| **Laboratoire intergénérationnel** | Exécuter la même source avec des cibles propres à chaque appareil | Le CPU consigne l'identité et vérifie chaque sortie | Conservez séparément l'historique XDNA1, le verrou XDNA2 actuel et les futurs appareils. Un échec propre sur un appareil inconnu est aussi une information utile. |

## Une progression qui produit un travail publiable

1. **Reproduire un contrat de correction.** Exécutez le détecteur strict et la
   comparaison CPU complète avant toute optimisation.
2. **Remplacer une partie synthétique.** Entraînez les poids du wake word,
   fournissez une vraie projection d'embedding ou remplacez le flou caméra par
   une étape de modèle évaluée. Gardez un repli CPU.
3. **Composer sans prétendre.** Reliez l'étape NPU à un LLM local, une base de
   données, une action du bureau ou une boucle de capteur, en indiquant où tourne
   chaque opération.
4. **Mesurer l'application entière.** Publiez latences noyau et bout en bout,
   transferts, précision, puissance au repos/en charge, énergie par tâche,
   température et références CPU/iGPU. Un badge TOPS ne prouve pas l'efficacité énergétique.
5. **Publier la frontière.** Notez identité du périphérique, commit du compilateur,
   formes, types, commandes, correction de toutes les sorties, éléments ignorés
   et premier échec. Un résultat négatif minimal et reproductible aide aussi.

## Deux voies ouvertes, deux fonctions

- La voie `iree-amd-aie` verrouillée de ce dépôt empaquette les modules et un
  appel C/Python persistant. Commencez ici pour les intégrations fournies et le
  contrat de version exact.
- La voie [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) 1.4.1 épinglée
  expose l'API Python/le compilateur IRON pour programmer directement des noyaux
  spatiaux. La bibliothèque plus récente d'opérateurs/applications
  [`amd/IRON`](https://github.com/amd/IRON) est un projet distinct sur les
  bindings du langage MLIR-AIE, pas un renommage. Au commit `cdc48e93`, son
  workflow Phoenix officiel a rapporté **2 105 exécutions de cas pytest réussies
  et 45 ignorées**. Avec cinq itérations par défaut, ce sont **421 configurations
  distinctes réussies et 9 distinctes ignorées** : trois MHA, trois
  streaming-SwiGLU et trois GEMV+GELU, chacune répétée cinq fois. GQA n'est pas
  établi par ce run ; n'en faites pas une affirmation de LLM XDNA1 complet.[^iron-ci]

AMD Ryzen AI Software 1.8 for Linux cite STX/KRK et
non Phoenix.[^ryzenai-linux] Cela limite la voie produit prête à l'emploi, mais
ne ferme pas ces voies ouvertes de plus bas niveau.

## La limite honnête

Aucune commande prise en charge ici ne prend encore un modèle GGUF, Whisper,
Stable Diffusion ou ONNX quelconque pour servir tout le graphe sur XDNA1. La
couverture du compilateur, la mémoire, les transferts et l'orchestration hôte
restent de vraies contraintes. La bonne réponse est de les exposer, de décharger
les étapes vérifiées et de rendre chacune remplaçable au fil des progrès.

L'invitation et la galerie de code/preuves complètes se trouvent dans le document
anglais [Open NPU Lab](OPEN-NPU-LAB.md). [RESEARCH.md](RESEARCH.md) relie les
sources primaires à la portée exacte des affirmations, et la
[feuille de route LLM](LLM-ROADMAP.md) décrit les prochaines étapes.

[^iron-ci]: AMD IRON, [workflow Phoenix officiel 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), consulté le 15 août 2026 ; la page cite STX et KRK comme plateformes prises en charge.
