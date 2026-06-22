**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Ryzen AI **XDNA1** NPU 上で実際のコンピュートを **Linux** で動かす

AMD Ryzen AI **第1世代（XDNA1 / "Phoenix"）** NPU を *ドライバからは見えているがアイドル状態* から
**実際に matmul を実行する** 状態まで持っていくための、再現可能でエンドツーエンドのレシピ — ツール付き。
[`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) をソースからビルドして実現する。

> **なぜこのリポジトリが存在するのか。** 2026年の「Ryzen AI NPU がついに Linux で動く」という
> 記事のほとんどは **XDNA2**（Strix/Krackan）についてのものだ。Ryzen 7040/8040 ラップトップ
> （例: 7840U）に搭載された第1世代 **XDNA1** チップは、ターンキーなスタック群によって *明示的に除外されている* —
> AMD の Ryzen AI Software for Linux、ONNX Runtime の Vitis AI EP、Lemonade/FastFlowLM。
> XDNA1+Linux では NPU は電源が入り、in-tree の `amdxdna` ドライバによって列挙されるが、
> **出荷済みのランタイムでその上でモデルを実行できるものは存在しない。** XDNA1 を *実際に* ターゲットにできる
> 唯一のオープンな道が `iree-amd-aie` — ソースからビルドしたものだ。このリポジトリは、その道のりを
> 落とし穴ごとに検証したマップである。

## ✅ 動作するもの（検証済み）

**NPU 上で**（`--device=amdxdna`）コンパイル・実行し、正しい結果が得られ、再現可能なもの:

| ワークロード | 形状 | 結果 | スループット（NPU） |
|---|---|---|---|
| `i32` matmul | 128×128×128 | ✓ 完全一致 | ~3.6 ms/iter, ~280/s |
| `bf16 → f32` matmul | 256×256×256 | ✓ 完全一致（小数部含む） | ~2.9 ms/iter, ~350/s |

テストしたマシン: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U（Phoenix, XDNA1）
· Radeon 780M · Ubuntu 26.04 · kernel 7.0 · in-tree `amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**。

## 🚀 クイックスタート

```bash
git clone https://github.com/<you>/ryzen-npu-linux.git && cd ryzen-npu-linux

# 0. Is the NPU even alive? (read-only diagnostic)
./scripts/check-npu.sh

# 1. (if check failed on groups/memlock/xrt) activate it for your user, then re-login
./scripts/enable-npu.sh

# 2. Build iree-amd-aie from source (~65 min, 30-60 GB disk). All workarounds baked in.
./scripts/build.sh

# 3. Run a matmul ON THE NPU
./scripts/run-matmul.sh i32          # 128x128x128, all 768
./scripts/run-matmul.sh bf16         # 256x256x256 bf16->f32, all 1536
BENCH=1 ./scripts/run-matmul.sh bf16 # + benchmark
```

## 🧰 ツール

| スクリプト | 何をするか |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | 読み取り専用: ドライバ、デバイスノード、render グループ、memlock、XRT、pyxrt をチェックする。 |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | 非 root ユーザーをブロックする3つの要因（render グループ、memlock、XRT）を修正する。 |
| [`scripts/build.sh`](scripts/build.sh) | `iree-amd-aie` をクローンし、すべてのワークアラウンドを適用してビルドする。 |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | NPU 上で `i32`/`bf16` の matmul をコンパイル・実行する。これがレシピ。 |

## 🪤 落とし穴（素朴なビルド/実行が失敗する理由）

詳細はすべて **[docs/GOTCHAS.ja.md](docs/GOTCHAS.ja.md)** に。要点だけ:

1. **ホストコンパイラには `clang` ではなく `gcc` を使う。** clang 21 は MLIR の `BuiltinDialectBytecode.cpp` のコンパイルで *segfault* する。
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`。** Python バインディングは `-Werror,-Wmacro-redefined` に引っかかる。CLI ツールにはそれらは不要。
3. **Peano（`llvm-aie`）の pin を上げる。** リポジトリで pin されている nightly はインデックスから失効している。`build.sh` が最新を自動選択する。
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`。** 3つの重いサブモジュールを意図的にスキップする。
5. **`--iree-amdaie-device-hal=amdxdna` でコンパイルする**（＋ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`）。さもないとディスパッチがタイムアウトする。
6. ⚠️ **`--amdxdna_n_core_cols=4` で実行する。5 ではない。** Phoenix は raw で5列を報告するが、使うのは4列（`npu1_4col`）。5 を渡す → コアがハングする → `ert state 8` でタイムアウトする。

## 🎯 実際にこれをどこで使えるのか？

**[docs/USE-CASES.ja.md](docs/USE-CASES.ja.md)** を参照。正直に言うと: これは **カーネルレベル**
（matmul/conv のビルディングブロック）であり、ターンキーなモデルサービングではない。NPU プログラミングの学習、
ベンチマーク、特定の低消費電力推論プリミティブのビルド/オフロード、そしてオープンな XDNA1-on-Linux の取り組みへの
貢献には向いている。XDNA1 で **ドロップインの** LLM/Whisper/ONNX ランタイムが手に入るわけ **ではない** —
それは XDNA2 / Windows の領域だ。

## 📚 背景

XDNA1 と XDNA2 の比較、第1世代で Linux が難しい理由、そして `amdxdna` HAL がどのように `/dev/accel0` と
やり取りするかについては **[docs/BACKGROUND.ja.md](docs/BACKGROUND.ja.md)** を参照。

## ⚖️ 免責事項

これはコミュニティのノートであり、AMD/Xilinx の製品ではない。`iree-amd-aie` は初期フェーズで
変化が速く、バージョンやフラグはドリフトする。ここに書かれたものはすべて、上記のとおりの正確なマシン上で
2026-06-22 に検証した。他の XDNA1 ラップトップでの結果を伴う Issue/PR を歓迎する。

## ライセンス

[MIT](LICENSE)。
