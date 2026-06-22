**[🇬🇧 English](GOTCHAS.md) · [🇩🇪 Deutsch](GOTCHAS.de.md) · [🇫🇷 Français](GOTCHAS.fr.md) · [🇰🇷 한국어](GOTCHAS.ko.md) · [🇯🇵 日本語](GOTCHAS.ja.md)**

# 落とし穴 — 何が壊れ、なぜ壊れ、どう直すか

以下の各項目は、すべて実機のビルド（Ryzen 7840U / XDNA1、
Ubuntu 26.04、kernel 7.0、2026-06-22）で実際に遭遇し、解決したものです。発生順（どこでつまずくか）に並べてあります。

---

## 1. clang が MLIR のビルド中に segfault する → gcc を使う

**症状**
```
FAILED: .../obj.MLIRIR.dir/BuiltinDialectBytecode.cpp.o
clang++: error: clang frontend command failed with exit code 139
... file INSTALL cannot find ".../libIREECompiler.so": No such file
```
`exit 139` = SIGSEGV: ホストの **clang（21.x で確認）がクラッシュ** して、ある大きな
生成済み MLIR ファイルのコンパイルに失敗します。そのファイルはコアの `MLIRIR` に含まれるため、コンパイラライブラリは
リンクされず、インストール全体が崩壊します。しかし *最初の* エラーはスクロールで流れてしまい、
気づくのはインストール失敗だけ、ということになります。

**修正方法。** **gcc** でビルドします:
```bash
export CC=gcc CXX=g++
rm -rf iree-build      # required: cmake won't switch compilers in an existing dir
cmake ...              # reconfigure
```
gcc 15 は同じツリーをクリーンにビルドします（16 コアで約 65 分）。

---

## 2. Python バインディング: `_POSIX_C_SOURCE` マクロが再定義される → オフにする

**症状**
```
.../python3.12/include/python3.12/pyconfig.h:1877:9:
  error: '_POSIX_C_SOURCE' macro redefined [-Werror,-Wmacro-redefined]
FAILED: runtime/bindings/python/.../PyExtRt.dir/...cc.o
```
IREE の Python（nanobind）バインディングは feature-test-macro の再定義を引き起こし、
これは `-Werror` の下では致命的です。matmul のコンパイルと実行に Python バインディングは **必要ありません** —
`iree-compile` / `iree-run-module` / `iree-e2e-matmul-test` の
バイナリで十分です。

**修正方法。** `-DIREE_BUILD_PYTHON_BINDINGS=OFF`（そして `iree-install-dist` ターゲットはスキップ）。

---

## 3. ピン留めされた Peano（llvm-aie）バージョンが期限切れになっている

**症状**
```
ERROR: Could not find a version that satisfies the requirement
  llvm_aie==19.0.0.2025052701+31d2aa6e (from versions: 21.0.0.2026061101+..., ...)
```
`build_tools/peano_commit_linux.txt` は特定の `llvm-aie` nightly をピン留めしていますが、
Xilinx の nightly インデックスは最近のビルドしか保持しません。そのピン（アップストリームでは
約 13 か月間そのまま）はとうに消えています。

**修正方法。** ピンを、入手可能な最新の nightly に向けます:
```bash
echo "<latest-nightly-version>" > build_tools/peano_commit_linux.txt
bash build_tools/download_peano.sh
```
`scripts/build.sh` はインデックスを問い合わせて、これを自動で行います。新しい Peano は
バージョンが飛んでいても問題なく動作します（AIE LLVM バックエンドであり、インターフェイスは安定しています）。

---

## 4. 意図的にスキップしたサブモジュールでビルドが中断する

**症状**
```
The git submodule 'third_party/stablehlo' is not initialized.
CMake Error: check_submodule_init.py failed
```
`torch-mlir`、`stablehlo`、`XRT`（いずれも amdxdna パスには不要）を含めずにクローンしても、
IREE のサブモジュールチェックは依然としてエラーを出します。

**修正方法。** `-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`。（そして AMD の out-of-tree な
`xdna-driver` をビルドする必要は **ありません**: in-tree の `amdxdna.ko` がデバイスを公開し、
`amdxdna` HAL は `/dev/accel0` を直接オープンする独自の shim を同梱しています。）

---

## 5. 誤った HAL 向けにコンパイルされたモジュール → ディスパッチが完了しない

**症状。** コンパイルは問題なく通りますが、実行時に:
```
amdxdna dispatch did not complete: ert state 8; while invoking ... hal.fence.await
```
`--iree-amdaie-device-hal=amdxdna` を省略すると、モジュールは別の
HAL（例: `xrt`）向けにビルドされ、`--device=amdxdna` の下では正しく実行されません。

**修正方法。** フラグ一式を完全に指定してコンパイルします:
```
--iree-amdaie-device-hal=amdxdna
--iree-hal-memoization=false
--iree-hal-indirect-command-buffers=false
--iree-amdaie-target-device=npu1_4col
--iree-amdaie-lower-to-aie-pipeline=objectFifo   # i32
# (use 'air' for bf16)
--iree-amdaie-tile-pipeline=pack-peel
--iree-amd-aie-peano-install-dir=<.../llvm-aie>
--iree-amd-aie-install-dir=<.../iree-install>
```

---

## 6. ⚠️ 最大の難所: 実行時のカラム数

**症状。** 正しいコンパイルフラグを使っていても、#5 と同じ `ert state 8` の **タイムアウト** が発生します。
コマンドは NPU まで到達し（ディスパッチは確認できる）、コアはロードされ、その後
**永遠にハング** して約 60 秒後にタイムアウトします。`dmesg` にはハードウェアエラーが **何も** 表示されません —
コアは、決して一致しないパーティションをただ待っているだけです。

**根本原因。** Phoenix の生の AIE メタデータは **5 カラム** と報告しますが、使用可能な
カラム数 — そしてコンパイルターゲット `npu1_4col` — は **4** です。ドライバのヘルパーも一致します:
```
$ python build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py --num-cols
4
```
`--amdxdna_n_core_cols=5` を渡すと、ランタイムは 5 カラムのパーティションをセットアップする一方で
モジュールは 4 を期待します → ミスマッチ → ハング。

**修正方法。** デバイスヘルパーが報告する値（rows=4、**cols=4**）で実行します:
```
--amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4
```
`scripts/run-matmul.sh` はこれらを `--num-rows`/`--num-cols` から自動的に読み取ります。

---

## ブロッキングしない注意点

- **`xrt-smi validate` が失敗する**（`Archive not found: amdxdna/bins/xrt_smi_phx.a`）。
  これは Ubuntu が Phoenix のセルフテストバイナリを除去しているためであり、NPU の故障では **ありません**。
- **予想された UAPI/ABI のミスマッチは起きませんでした。** kernel-7.0 の in-tree `amdxdna`
  と `iree-amd-aie` の同梱する `amdxdna_accel.h` は互換でした: トポロジ
  ioctl とデバイス列挙は、どちらも一発で動作しました。
- **Python 3.13/3.14 は新しすぎます**（IREE のビルド依存関係には）— 隔離された 3.12 を使ってください
  （スクリプトは `uv` を使用します）。
