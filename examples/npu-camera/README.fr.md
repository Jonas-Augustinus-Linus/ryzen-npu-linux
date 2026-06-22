**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-camera — filtre vidéo NPU permanent → caméra virtuelle

![npu-camera demo](../../docs/media/npu-camera.gif)

Capture la vidéo, fait passer **chaque image à travers le NPU XDNA1**, et publie le
résultat vers la caméra virtuelle `/dev/video10` (utilisable par Zoom / Chrome / OBS / Meet).

```
source ─▶ GStreamer appsink ─▶ NPU (2× 128×128 i32 matmul = 2D box blur) ─▶ appsrc ─▶ v4l2sink (/dev/video10)
```

Mesuré : **30 fps** avec 2 dispatches NPU/image, via
[`../../tools/npu-runner/libnpu.so`](../../tools/npu-runner) (ctypes chargé une seule fois,
~4 ms/appel — et non le coût d'`iree-run-module` par appel).

> L'opération NPU ici est un véritable flou 2D par image (matmul). Un vrai flou *d'arrière-plan*
> remplacerait par un modèle conv de segmentation — la plomberie capture→NPU→caméra-virtuelle est
> identique ; seuls le `.vmfb` et `process()` changent.

## Prérequis

1. `iree-amd-aie` compilé ([`../../scripts/build.sh`](../../scripts/build.sh)).
2. La caméra virtuelle `/dev/video10` (v4l2loopback signé) :
   ```bash
   sudo apt install -y linux-modules-v4l2loopback-generic v4l2loopback-utils \
       v4l-utils gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools python3-gi
   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="NPU Camera" exclusive_caps=1
   ```
   (rendez persistant via `/etc/modules-load.d/` + `/etc/modprobe.d/` ; voir les notes de configuration du dépôt).
3. Le pont NPU compilé : `(cd ../../tools/npu-runner && ./build_lib.sh)`.
4. Le noyau NPU : `~/src/iree-amd-aie/run_npu_matmul.sh 2 3 && cp /tmp/matmul_npu.vmfb ./matmul.vmfb`
   (une copie persistante — `/tmp` est effacé au démarrage).

## Lancement

```bash
# python3 système (il dispose de gi + numpy ; le build-venv uv ne peut pas charger gi — ABI)
/usr/bin/python3 npu_camera.py          # par défaut : videotestsrc -> NPU -> /dev/video10
CAM=/dev/video0 /usr/bin/python3 npu_camera.py   # votre vraie webcam
```
Vérifiez : `ffplay /dev/video10` (ou choisissez **« NPU Camera »** dans Zoom/Meet/OBS).

## Installation en tant que service permanent

```bash
cp npu-camera.service ~/.config/systemd/user/        # éditez le chemin ExecStart si nécessaire
cp npu-camera.env.example ~/.config/npu-camera.env   # définissez CAM=/dev/videoN
systemctl --user daemon-reload
systemctl --user enable --now npu-camera             # démarre automatiquement à la connexion
systemctl --user disable --now npu-camera            # désactiver
```

## Notes

- **Python 3 système** (`/usr/bin/python3`) — dispose de `gi`(GStreamer)+`numpy` ; le
  build-venv uv ne peut pas charger `gi` (incompatibilité ABI).
- Surcharges d'environnement : `CAM` (mire de test par défaut), `W`, `H`, `OUT`, `NPU_VMFB`,
  `NPU_RUNNER_DIR`.
