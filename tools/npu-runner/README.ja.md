**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# npu-runner — 常駐型 XDNA1 NPU 呼び出し器（IREE ランタイム C API）

`.vmfb` を **一度だけ** ロードし、呼び出しごとに `iree-run-module` を起動するのではなく、
同一プロセス内で NPU を何度も呼び出します。7840U での実測値は **約 3.7 ms/invoke 対
約 41 ms/invoke**（サブプロセス方式）— 約 11 倍高速です。XRT のデバイスオープンと
プロセス起動が、毎回ではなく一度だけ行われるためです。これは「NPU はベンチマークでは動く」を
「NPU が常時稼働の KWS / 埋め込み / CNN / カメラ / オーディオに使える」へと変えるものです。

形態は 2 つ、コアは同じ:
- **`npu_runner`** — スタンドアロンの CLI／ベンチマーク（`npu_runner.cc`）。
- **`libnpu.so` + `npu.py`** — ctypes 共有ライブラリ。これにより **Python** から
  NPU を高速に呼び出せます（[`../../examples/npu-camera`](../../examples/npu-camera) と
  [wake-word](../wake-word) ヘッドで使用）。

## ビルド

ビルド済みの `iree-amd-aie` が必要です（[`../../scripts/build.sh`](../../scripts/build.sh) を参照）。
どちらのビルドスクリプトも `IREE_AMD_AIE_ROOT`（デフォルトは `~/src/iree-amd-aie`）を尊重します。

```bash
./build.sh        # -> npu_runner (CLI)
./build_lib.sh    # -> libnpu.so   (ctypes)
```

## 実行

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
- **`n_core_cols = 4`** をデバイスパラメータに明示的に設定します（5 だと ERT state-8
  タイムアウト）。スタンドアロンのプログラムは `--amdxdna_*` フラグをパースしません。
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
