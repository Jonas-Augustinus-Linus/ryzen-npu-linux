**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-runner — 常駐型 AMD XDNA NPU 呼び出し器（IREE ランタイム C API）

![npu-runner demo](../../docs/media/npu-runner.gif)

`.vmfb` を **一度だけ** ロードし、呼び出しごとに `iree-run-module` を起動するのではなく、
同一プロセス内で NPU を何度も呼び出します。7840U/XDNA1 での実測値は **約 3.7 ms/invoke 対
約 41 ms/invoke**（サブプロセス方式）— 約 11 倍高速です。XRT のデバイスオープンと
プロセス起動が、毎回ではなく一度だけ行われるためです。これは「NPU はベンチマークでは動く」を
「NPU が常時稼働の KWS / 埋め込み / CNN / カメラ / オーディオに使える」へと変えるものです。

形態は 2 つ、コアは同じ:
- **`npu_runner`** — スタンドアロンの CLI／ベンチマーク（`npu_runner.cc`）。
- **`libnpu.so` + `npu.py`** — ctypes 共有ライブラリ。これにより **Python** から
  NPU を高速に呼び出せます（[`../../examples/npu-camera`](../../examples/npu-camera) と
  [wake-word](../../examples/wake-word) ヘッドで使用）。

## ビルド

ビルド済みの `iree-amd-aie` が必要です（[`../../scripts/build.sh`](../../scripts/build.sh) を参照）。
どちらのビルドスクリプトも `IREE_AMD_AIE_ROOT`（デフォルトは `~/src/iree-amd-aie`）を尊重します。
Python ラッパーには、アクティブな Python 環境の NumPy が必要です。
ランタイムコードは XDNA1 と XDNA2 の両方をサポートします。`.vmfb` は
デバイス固有です。`scripts/run-matmul.sh` は搭載 NPU を検出し、
`npu1_4col` または `npu4` 向けにコンパイルします。

```bash
./build.sh        # -> npu_runner (CLI)
./build_lib.sh    # -> libnpu.so   (ctypes)
```

## 実行

```bash
# デバイスに合わせi32 128x128 @matmul を作成・検証し、モジュールを保存
VMFB_OUT=/tmp/matmul_npu.vmfb ../../scripts/run-matmul.sh i32 128 128 128 2 3

./npu_runner /tmp/matmul_npu.vmfb 1000          # 1000 in-process invokes
python3 npu.py /tmp/matmul_npu.vmfb             # Python ctypes セルフテスト -> 全要素 768
```

```python
from npu import NPU
npu = NPU("/tmp/matmul_npu.vmfb")               # i32 128x128 @matmul
out = npu.matmul(a, b)                           # a,b int32[128,128] -> int32[128,128]
npu.close()
```

## 自明でなかった点（再びつまずかないために）

- **g++ を使い、clang は決して使わない**（clang21 は amdxdna ドライバの TU で ICE を起こす）。メインのビルドと同様です。
- **システムアロケータのマクロ:** ランタイム C API が
  `iree_allocator_system()` を宣言するのは、`-DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl`
  が定義されているときだけです（ビルドは CMake でこれを設定しますが、スタンドアロンのコンパイルでは自分で渡す必要があります）。
- **Proactor pool:** amdxdna のデバイス作成は、非同期 I/O のために proactor pool を
  デリファレンスします — それが無いと segfault します。私たちは
  `iree_async_proactor_pool_create(1, NULL, …)` で 1 つ作成し、
  `iree_hal_device_create_params_t.proactor_pool` に設定します（ランタイムの
  `try_create_default_device` が内部で行っていることです）。
- **グリッドの自動検出:** 両方の C API 呼び出し器は `n_core_rows` と
  `n_core_cols` を `0` のままにします。現行の amdxdna ランタイムが Phoenix
  4×4 または Strix 4×8 を検出し、Phoenix の予約メタデータ列も補正します。
  これにより、一方の世代の形状を他方に固定せずに済みます。
- **リンク:** ランタイム C API は `libiree_runtime_unified.a` にありますが、amdxdna
  ドライバはそこに同梱されていない HAL ユーティリティのアーカイブをいくつか引き込みます（deferred_command_buffer、
  queue_emulation、queue_host_call_emulation、resource_set、file_transfer）。加えて
  async と proactor_pool も必要です。将来のチェックアウトで未定義シンボルが追加された場合は、
  `nm $BLD/**/*.a | grep ' T <symbol>'` でアーカイブを見つけ、リンクグループに追加してください。

## ファイル

| ファイル | 役割 |
|---|---|
| `npu_runner.cc` / `build.sh` | スタンドアロンの CLI ＋ ベンチマーク |
| `libnpu.cc` / `build_lib.sh` | `libnpu.so` ctypes 共有ライブラリ |
| `npu.py` | `libnpu.so` を包む Python ラッパー |
