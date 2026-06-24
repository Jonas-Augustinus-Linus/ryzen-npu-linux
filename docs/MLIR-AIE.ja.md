**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# `mlir-aie`（IRON）トラック — XDNA1 NPU への 2 つ目のオープンな道

このリポジトリの他の部分は [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
をビルドします。これはモデル全体（PyTorch / ONNX）を NPU へ落とし込む
**グラフコンパイラ** です。このページは、*もう一方* のオープンな道 —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) とその **IRON** Python
eDSL — の検証済みレシピです。ここでは **NPU カーネルを直接記述し**、`pyxrt`
経由で実行します。さらに本物の ML の `programming_examples`（conv2d、ResNet
ブロック、Google の Magika）を同梱しているため、*名前のついた* ワークロードを
第1世代 Phoenix NPU 上で動かすには最速の道です。

どちらの道も `npu1`（Phoenix / XDNA1）をターゲットとし、**同じ Peano（`llvm-aie`）
バックエンドを共有** します — つまり、すでに `./scripts/build.sh` を実行済みなら、
このトラックはその Peano を再利用し、追加コストはほとんどかかりません。

> ここの他のすべてと同じマシンです: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO
> 7840U（Phoenix, XDNA1）· Ubuntu 26.04 · kernel 7.0 · in-tree `amdxdna` · XRT
> 2.21 · NPU FW 1.5.5.391**。2026-06-24 に検証。

## iree-amd-aie と mlir-aie — どちらを使うか？

| | `iree-amd-aie`（リポジトリルート） | `mlir-aie` / IRON（このページ） |
|---|---|---|
| あなたが持ち込むもの | グラフ全体（`.onnx` / PyTorch） | カーネルのアイデア（データフロー + C++ コンピュート関数） |
| 抽象度 | MLIR グラフコンパイラ | ObjectFifo データフロー eDSL（`aie.iron`）+ `aiecc` |
| 実行ホスト | `iree-run-module` / C-API ランナー | `pyxrt`（`make run_py`） |
| 向いている用途 | 「自分のモデルを NPU で動かす」 | 「特定の NPU カーネルを書く / 所有する」、本物の ML サンプルブロック |
| Python | **3.12**（IREE のビルド依存） | **3.14**（Ubuntu のパッケージ版 `pyxrt` に合わせる） |
| バックエンド | Peano（`llvm-aie`） | **同じ** Peano |

両者は競合ではなく補完関係です。仕事に合う方を使ってください。

## セットアップ（スクリプト1つ）

```bash
./scripts/setup-mlir-aie.sh
```

これは冪等であり、次のことを行います:

1. **`Xilinx/mlir-aie` を最新のリリースタグでクローン** します（`~/src/mlir-aie`）。
   `programming_examples` はインストールされた wheel と一致している必要があるため、
   タグは wheel のバージョンに固定されます。
2. **Python 3.14 の venv を作成** し（`~/src/mlir-aie-venv`）、**パッケージ版の
   `pyxrt`**（`python3-xrt`、`cpython-314` でビルド）をその中に **シンボリックリンク** します
   — これが、venv が iree-amd-aie ビルドで使う 3.12 ではなく 3.14 である理由です。
3. **`mlir_aie` wheel をインストール**（一致するタグ）し、**CPU 版 `torch`** も入れます
   （`ml/*` の例は NPU の出力を torch のゴールデンと照合します）。
4. **`iree-amd-aie` 向けにビルドした Peano**（`~/src/iree-amd-aie/llvm-aie`）を再利用します。
   そこに無ければ、代わりに `llvm-aie` nightly wheel をインストールします。

## NPU 上で例を実行する

```bash
./scripts/run-mlir-example.sh ml/conv2d                 # default target: run_py (pyxrt)
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run   # C++ host: needs libxrt-dev
```

`run-mlir-example.sh` は [`scripts/mlir-aie-env.sh`](../scripts/mlir-aie-env.sh)
を source し（ツールチェーンを `PATH` に通し、Peano を結線し、デバイスを `npu1`
として自動検出）、その例を `npu1` 向けにビルドして NPU 上で実行します。デフォルト
ターゲットは **`run_py`** make ターゲット — XRT の dev ヘッダを **一切** 必要としない
`pyxrt` ホストです。

## XDNA1 上で何が動くか（検証済み、NPU 上で）

すべて `run_py` / `pyxrt` 経由で、出力は torch/numpy のゴールデンと照合済みです。
NPU 時間はホストのディスパッチを含む実時間です（実行ごとに変動します）:

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block (1×1→3×3→1×1 + skip) | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

**Phoenix（4 カラム）での既知の制限:**

- `basic/matrix_multiplication/*` は **xclbin までは問題なく** ビルドできます（512³、4 カラム）
  が、そのホストは **C++ 専用** です — `make run` には `libxrt-dev` が必要です
  （ランタイムパッケージは XRT の dev ヘッダを同梱しません）。`sudo apt install libxrt-dev`
  を実行してから `./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array run`。
- `ml/mobilenet` はビルドできますが、実行時に
  `DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` で失敗します: ネットワーク全体の設計は
  Phoenix の **4** カラムを超えるカラム数を要求します。単一ブロック（conv2d、bottleneck、
  resnet conv2_x）と `magika` は収まって動作します。ネットワーク全体は XDNA2 スケールです。

## 自分のカーネルを書く

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) は、ストックの例には
**含まれない** 手書きのカーネルです: 単一の融合された
`out = max(a + b, 0)`（残差加算 + ReLU）。これは一連の流れすべてを示します —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — Peano が `aie2`
  向けにコンパイルするコンピュートカーネル。
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — `transform_binary`
  を通して結線され、`iron.jit` でコンパイル + 実行される `iron.ExternalFunction`。
  numpy と照合されます。

```bash
./examples/mlir-aie/relu_add/run.sh
```

## この道に特有の落とし穴

IRON の道には、iree-amd-aie ビルドとは別の独自の罠があります。要点だけ
（詳細は [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie track* に）:

1. **ここでは Python 3.14、3.12 ではありません。** Ubuntu のパッケージ版 `pyxrt`
   を使う唯一の方法は 3.14 の venv です。3.12 の venv はそれをインポートできません。
2. **`pyxrt` を symlink で公開** します。venv の `site-packages` へ（クリーンな venv であり、
   `--system-site-packages` ではありません）。
3. ⚠️ **`env_setup.sh` をパイプなしで source します。** `source env_setup.sh A B | tail`
   はそれをサブシェルで実行し、`export` が消えます → `PEANO_INSTALL_DIR` が空 →
   システムの `/bin/clang++` → `error: unknown target triple 'aie2-none-unknown-elf'`。
   （`scripts/mlir-aie-env.sh` がこれを肩代わりします。）
4. **`make run` より `make run_py` を優先します。** `run_py` は純粋な `pyxrt` です。`run` は
   `libxrt-dev` を必要とする C++ ホストをビルドします。
5. `llvm-aie` を再ダウンロードせず、**iree-amd-aie の Peano を再利用** します。
6. **ネットワーク全体の設計は 4 カラムを超えるカラム数を要求** します — Phoenix では
   `CREATE_HWCTX` で失敗します。

## このリポジトリの他の部分との関係

これは *追加* の道であって、置き換えではありません。「自分のモデルを NPU で動かす」には、
`iree-amd-aie` のフロー（`scripts/build.sh` + `scripts/run-matmul.sh` +
`npu-trim` / `npu-runner` ツール）が依然として答えです。**特定のカーネルを書きたい** とき、
あるいはアップストリームの **ML サンプルブロック** を直接実行したいときに `mlir-aie` に手を伸ばしてください。
