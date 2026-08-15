**[🇬🇧 English](MLIR-AIE.md) · [🇩🇪 Deutsch](MLIR-AIE.de.md) · [🇫🇷 Français](MLIR-AIE.fr.md) · [🇰🇷 한국어](MLIR-AIE.ko.md) · [🇯🇵 日本語](MLIR-AIE.ja.md)**

# `mlir-aie`（IRON）トラック — 両世代で NPU カーネルを書く

このリポジトリの他の部分は [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
をビルドします。これはモデル全体（PyTorch / ONNX）を NPU へ落とし込む
**グラフコンパイラ** です。このページは、*もう一方* のオープンな道 —
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) とその **IRON** Python
eDSL — の検証済みレシピです。ここでは **NPU カーネルを直接記述し**、`pyxrt`
経由で実行します。

**両方の NPU 世代** で、同じスクリプト、同じ wheel で検証済みです:

> **XDNA1** — Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U（Phoenix, `npu1`）·
> Ubuntu 26.04 · kernel 7.0 · XRT 2.21 · 2026-06-24 に検証（mlir-aie 1.3.x）。
>
> **XDNA2** — Ryzen AI 9 HX PRO 370（Strix Point, `npu2`, XRT 名
> `RyzenAI-npu4`）· Radeon 890M · Ubuntu 26.04 · kernel 7.0 · Ubuntu ネイティブの
> XRT 2.21.75 · NPU FW 1.1.2.64 · 2026-08-15 に検証（**mlir-aie 1.4.1**）。

## iree-amd-aie と mlir-aie — どちらを使うか？

| | `iree-amd-aie`（リポジトリルート） | `mlir-aie` / IRON（このページ） |
|---|---|---|
| あなたが持ち込むもの | グラフ全体（`.onnx` / PyTorch） | カーネルのアイデア（データフロー + C++ コンピュート関数） |
| 抽象度 | MLIR グラフコンパイラ | ObjectFifo データフロー eDSL（`aie.iron`）+ `aiecc` |
| 実行ホスト | `iree-run-module` / C-API ランナー | `pyxrt`（Python の設計が自分自身を実行する） |
| 向いている用途 | 「自分のモデルを NPU で動かす」 | 「特定の NPU カーネルを書く / 所有する」、本物の ML サンプルブロック |
| Python | **3.12**（IREE のビルド依存） | **3.14**（Ubuntu のパッケージ版 `pyxrt` に合わせる） |
| バックエンド | Peano（`llvm-aie`） | **同じ** Peano — `aie2`（npu1）/ `aie2p`（npu2）を自動選択 |

両者は競合ではなく補完関係です。仕事に合う方を使ってください。

## セットアップ（スクリプト1つ）

```bash
./scripts/setup-mlir-aie.sh
```

これは冪等です。`Xilinx/mlir-aie` を最新のリリースタグでクローンし、
Python 3.14 の venv を作成し、Ubuntu のパッケージ版 `pyxrt` をその中に
シンボリックリンクし、一致する `mlir_aie` wheel（1.4.1 は `cp314` の manylinux
wheel を出荷）+ CPU 版 torch をインストールし、あなたの iree-amd-aie の Peano を
再利用します（無ければ `llvm-aie` wheel をインストールします — この wheel は
`py3-none` で、Python バージョン非依存です）。世代の検出はアップストリーム由来です:
`env_setup.sh` が `xrt-smi examine` を grep して `NPU2=0/1` をエクスポートします。

## NPU 上で例を実行する

```bash
./scripts/run-mlir-example.sh basic/passthrough_kernel
./scripts/run-mlir-example.sh ml/softmax
./scripts/run-mlir-example.sh ml/conv2d          # Makefile example
./scripts/run-mlir-example.sh basic/matrix_multiplication/whole_array \
    -M 512 -K 512 -N 512 -m 32 -k 32 -n 32 --n-aie-cols 8
```

**mlir-aie 1.4.x で例の構成が再編されました** — スクリプトは両方の形に対応します:

- ほとんどの例は今や **直接実行する単一の Python 設計** です: `@iron.jit`
  が最初の呼び出しでコンパイルし、デバイス（`npu`/`npu2`）は自動検出され、
  設計自身がベンチマーク/検証ハーネスを内蔵しています。例ごとの Makefile は
  `basic/` の大半から消えました。lit ファイル（`run.lit` / `run_strix.lit`）が
  正規の起動方法を文書化しています。
- `ml/conv2d`、`ml/mobilenet`、matmul の C++ ホスト版は依然として Makefile を
  使います — `devicename=npu2` が世代を選択します
  （`devicename ?= $(if $(filter 1,$(NPU2)),npu2,npu)`）。
- `aiecc.py` は消えました: 1.4.x では `aiecc` は **C++ バイナリ** であり、
  **Peano がデフォルトバックエンド** です（chess には明示的な
  `--xchesscc --xbridge` + Vitis が必要）。

## XDNA2 上で何が動くか（検証済み、NPU 上で、mlir-aie 1.4.1）

Strix Point は IRON に対して **8 カラム / 32 コンピュートタイル** を公開します
（Phoenix: 4/16）。以下の計測はすべてこのリポジトリのマシンによるものです。
「NPU time」はランタイムの NPU 上の数値（`kernel.wait()` の前後で計測）であり、
ホストの起動オーバーヘッドを含みません。

### カーネルとブロック

| Example | Kind | XDNA2 result |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ 94 µs |
| `basic/vector_scalar_mul` | vector × scalar | ✓ 106 µs |
| `ml/softmax` | LLM block | ✓ PASS |
| `ml/rope` | LLM block | ✓ PASS |
| `ml/swiglu` | LLM block | ✓ PASS |
| `ml/norm -o rms` | RMSNorm | ✓ PASS |
| `ml/mm_activation_epilogue` | matmul + fused activation | ✓ PASS |
| `ml/conv2d` (i8, 32×32, 64ch) | INT8 convolution | ✓ 490 µs (XDNA1: ~900 µs) |
| `ml/mobilenet` | **full network** | ✓ **PASS, ~176 ms/inference** |
| [`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | custom fused kernel | ✓ 後述 |

`ml/mobilenet` は **XDNA1 では動かせない** 設計です — Phoenix の 4 カラムを超える
カラム数を要求し、`CREATE_HWCTX` で死にます。Strix の 8 カラムではネットワーク
全体がエンドツーエンドで動作します。（アップストリームは現在これを緩和された
`atol=9` の許容誤差で検証しています — 彼らの注記をここに転記しました。）

### GEMM（`basic/matrix_multiplication/whole_array`、8 カラム）

| Shape | dtype | inner tile | NPU time | Throughput |
|---|---|---|--:|--:|
| 512³ | i16→i32 | 32³ | 203 µs | 1.32 TOPS |
| 512³ | bf16→f32 | 32³ | 233 µs | 1.15 TFLOPS |
| 512³ | bf16 via **bfp16** | 32³ | 199 µs | 1.35 TFLOPS |
| 2048³ | bf16 via **bfp16** | 32³ | 9.71 ms | 1.77 TFLOPS |
| 2048³ | i8→i32 | 32³ | 8.73 ms | 1.97 TOPS |
| 2048³ | bf16 via **bfp16** | 64×32×64 | 3.70 ms | **4.64 TFLOPS** |
| 2048³ | i8→i32 | 64³ | 2.59 ms | **6.65 TOPS** |

この表が教える 2 つの教訓:

1. **内側タイルサイズだけで 3.4× の価値がある**（i8: 32³→64³ タイルにするだけで
   1.97 → 6.65 TOPS）。それ以上大きくすると 64 KB のコアローカルメモリから
   あふれて配置に失敗します — bf16 の 64³ はすでにそうなります。
2. **AIE2P では bf16 の計算に bfp16 パスを使うこと**
   （`--emulate-bf16-mmul-with-bfp16 1`）。bf16 MAC は XDNA1 の AIE2 では
   ネイティブですが、XDNA2 の AIE2P では *約 ¼ レートでエミュレート* されます。
   ネイティブモードは **bfp16 ブロック浮動小数点**（8×8×8）です。512³ で +17%、
   チューニングしたタイルで +25% がタダで手に入ります。

**ネイティブ bfp16ebs8** のエンドツーエンド設計（`ml/block_datatypes/…`）は、この
マシンの Peano で問題なくコンパイルできます（xclbin + insts が生成される）。実行
には C++ ホスト、すなわち `libxrt-dev` が必要です（Ubuntu のランタイムパッケージは
XRT の dev ヘッダを同梱しません）。

### カスタムカーネル、アレイ全体のスケーリング

我々の融合 `relu(a+b)`（[`examples/mlir-aie/relu_add`](../examples/mlir-aie/relu_add/)）、
int32 要素 100 万個、タイル 1024:

| Design | NPU time | Effective DDR BW |
|---|--:|--:|
| single Worker (1 tile) | 8 967 µs | 1.4 GB/s |
| whole array (8 columns, `transform_parallel_binary`) | 1 123 µs | 11.2 GB/s |

**8 カラムで 8.0×** — この帯域律速のカーネルにとって線形スケーリングです。

## XDNA1 上で何が動くか（検証済み、NPU 上で、2026-06-24）

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 convolution | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU, fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layer group | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| `examples/mlir-aie/relu_add` | custom fused `relu(a+b)` kernel | ~0.37 ms |

**Phoenix（4 カラム）での既知の制限:** `ml/mobilenet` はビルドできますが
`DRM_IOCTL_AMDXDNA_CREATE_HWCTX (err=-22)` で失敗します — ネットワーク全体の設計は
XDNA2 スケールです（上で確認済み）。単一ブロックは収まって動作します。

## 自分のカーネルを書く

[`examples/mlir-aie/relu_add/`](../examples/mlir-aie/relu_add/) は、ストックの例には
**含まれない** 手書きのカーネルです: 単一の融合された `out = max(a + b, 0)`。
どちらの世代でも一連の流れすべてを示します —

- [`relu_add.cc`](../examples/mlir-aie/relu_add/relu_add.cc) — コンピュート
  カーネル。Peano が検出されたデバイスに応じて `aie2` または `aie2p` 向けに
  コンパイルします。ソースの変更は不要です。
- [`relu_add.py`](../examples/mlir-aie/relu_add/relu_add.py) — IRON 1.4.x の
  アノテーション付き `@iron.jit` 形式（`In`/`Out`/`CompileTime[...]`）を 2 つの
  設計で: 単一 Worker（`transform_binary`）と、カラムごとに 1 Worker
  （`transform_parallel_binary`、4 または 8 カラムを自動選択）。

```bash
./examples/mlir-aie/relu_add/run.sh
```

**API に関する注記:** IRON 1.4.x はアノテーションを **必須** にしました — 古い
`iron.jit(transform_binary)(kernel, a, b, out, tile_size=…)` という呼び出し形式
（この例が 1.3.x で使っていたもの）は、今では `TypeError: … no In / Out / InOut /
CompileTime[T] annotation` を送出します。1.4.x のアルゴリズムは、生きたテンソルの
代わりに jit 本体の中で *テンソル型記述子* を受け取ります。移植は機械的な作業です
— 例の diff を参照してください。

## この道に特有の落とし穴

要点だけ — 詳細は [docs/GOTCHAS.md](GOTCHAS.md) → *mlir-aie track* に:

1. **ここでは Python 3.14、3.12 ではありません**（Ubuntu のパッケージ版 `pyxrt`
   は cpython-314）。
2. **`pyxrt` を symlink で公開** します — venv の site-packages へ。
3. ⚠️ **`env_setup.sh` をパイプなしで source する** — パイプ = サブシェル =
   `export`（`NPU2`、`PEANO_INSTALL_DIR`…）が消えます。
4. **IRON 1.4.x のアノテーション API 破壊** — 上記参照。
5. **コアローカルメモリは 64 KB**: ダブルバッファリングされた int32 FIFO 3 本 ×
   `tile_size` 4096 = 96 KB → `aie.tile op … allocation failed`。収まるサイズに
   タイルを切ってください。
6. **バイナリカーネルは `num_channels=2` を使えません** — 2 つの入力がすでに
   カラムごとの shim MM2S DMA チャネルを両方占有します
   （`no ShimNOCTile has sufficient DMA capacity`）。
7. **AIE2P の bf16 は ¼ レートのエミュレーション** — bfp16 パスを使ってください
   （上の GEMM の教訓を参照）。
8. 存在するなら `iree-amd-aie` の **Peano を再利用** します。ピン留めなしの
   `pip install llvm-aie` は今日、mlir-aie の CI がテストするものより LLVM
   メジャーが 1 つ先の 22.x nightly を掴んでしまいます — セットアップスクリプトが
   代わりにピン留めします。

## このリポジトリの他の部分との関係

これは *追加* の道であって、置き換えではありません。「自分のモデルを NPU で動かす」
には、XDNA1 では `iree-amd-aie` のフロー（`scripts/build.sh` +
`scripts/run-matmul.sh` + `npu-trim` / `npu-runner` ツール）が依然として答えです。
その XDNA2 移植は [XDNA2.md](XDNA2.md) で追跡しています。**特定のカーネルを書きたい**
とき、あるいはアップストリームの **ML サンプルブロック** を直接実行したいときに
`mlir-aie` に手を伸ばしてください。
