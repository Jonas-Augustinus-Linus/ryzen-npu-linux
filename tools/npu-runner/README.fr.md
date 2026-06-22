**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-runner — appelant persistant pour NPU XDNA1 (API C du runtime IREE)

![npu-runner demo](../../docs/media/npu-runner.gif)

Charge un `.vmfb` **une seule fois** et invoque le NPU de nombreuses fois en cours de processus, au lieu de
lancer `iree-run-module` à chaque appel. Mesuré sur un 7840U : **~3,7 ms/invoke contre
~41 ms/invoke** pour le chemin par sous-processus — ~11× plus rapide, parce que l'ouverture du périphérique XRT +
le lancement du processus n'ont lieu qu'une fois, et non à chaque appel. C'est ce qui transforme « le NPU fonctionne dans un
benchmark » en « NPU utilisable pour du KWS / des embeddings / du CNN / de la caméra / de l'audio en permanence ».

Deux formes, même cœur :
- **`npu_runner`** — une CLI/benchmark autonome (`npu_runner.cc`).
- **`libnpu.so` + `npu.py`** — une bibliothèque partagée ctypes pour que **Python** puisse appeler le
  NPU rapidement (utilisée par [`../../examples/npu-camera`](../../examples/npu-camera) et la
  tête [wake-word](../wake-word)).

## Build

Requiert un `iree-amd-aie` déjà compilé (voir [`../../scripts/build.sh`](../../scripts/build.sh)).
Les deux scripts de build respectent `IREE_AMD_AIE_ROOT` (par défaut `~/src/iree-amd-aie`).

```bash
./build.sh        # -> npu_runner (CLI)
./build_lib.sh    # -> libnpu.so   (ctypes)
```

## Run

```bash
# make a test module (i32 128x128 @matmul)
~/src/iree-amd-aie/run_npu_matmul.sh 2 3        # -> /tmp/matmul_npu.vmfb (all 768)

./npu_runner /tmp/matmul_npu.vmfb 1000          # 1000 in-process invokes
python3 npu.py /tmp/matmul_npu.vmfb             # Python ctypes self-test -> 768
```

```python
from npu import NPU
npu = NPU("/tmp/matmul_npu.vmfb")               # i32 128x128 @matmul
out = npu.matmul(a, b)                           # a,b int32[128,128] -> int32[128,128]
npu.close()
```

## Ce qui n'était pas évident (pour que vous ne retombiez pas dessus)

- **g++, jamais clang** (clang21 provoque une ICE sur le TU du pilote amdxdna), comme pour le build principal.
- **Macro de l'allocateur système :** l'API C du runtime ne déclare
  `iree_allocator_system()` que lorsque `-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl`
  est défini (le build le définit dans CMake ; une compilation autonome doit le passer).
- **Proactor pool :** la création du périphérique amdxdna déréférence un proactor pool pour les E/S
  asynchrones — sans lui, segfault. Nous en créons un avec
  `iree_async_proactor_pool_create(1, NULL, …)` et le définissons sur
  `iree_hal_device_create_params_t.proactor_pool` (ce que la fonction
  `try_create_default_device` du runtime fait en interne).
- **`n_core_cols = 4`** est défini explicitement sur les params du périphérique (5 → timeout ERT state-8) ;
  un programme autonome n'analyse pas les flags `--amdxdna_*`.
- **Linking :** l'API C du runtime se trouve dans `libiree_runtime_unified.a`, mais le pilote
  amdxdna tire quelques archives HAL-utils qui n'y sont pas regroupées (deferred_command_buffer,
  queue_emulation, queue_host_call_emulation, resource_set, file_transfer) plus
  async + proactor_pool. Si un checkout futur ajoute des symboles non définis, trouvez
  l'archive avec `nm $BLD/**/*.a | grep ' T <symbol>'` et ajoutez-la au groupe de link.

## Fichiers

| Fichier | Rôle |
|---|---|
| `npu_runner.cc` / `build.sh` | CLI autonome + benchmark |
| `libnpu.cc` / `build_lib.sh` | la bibliothèque partagée ctypes `libnpu.so` |
| `npu.py` | wrapper Python autour de `libnpu.so` |
