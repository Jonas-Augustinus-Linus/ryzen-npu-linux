**[🇬🇧 English](README.md) · [🇩🇪 Deutsch](README.de.md) · [🇫🇷 Français](README.fr.md) · [🇰🇷 한국어](README.ko.md) · [🇯🇵 日本語](README.ja.md)**

# Ryzen AI **XDNA1 + XDNA2** のオープンなコンピュートを **Linux** で

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Jonas-Augustinus-Linus/ryzen-npu-linux)](https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux/releases)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)
![NPU: Ryzen AI XDNA1 and XDNA2](https://img.shields.io/badge/NPU-XDNA1%20%2B%20XDNA2-ED1C24?logo=amd&logoColor=white)
[![Built with iree-amd-aie](https://img.shields.io/badge/built%20with-iree--amd--aie-FF7139)](https://github.com/nod-ai/iree-amd-aie)
![matmul on NPU: working](https://img.shields.io/badge/matmul%20on%20NPU-working-success)
![bf16 ~220 GFLOP/s](https://img.shields.io/badge/bf16-~220%20GFLOP%2Fs-brightgreen)

*ドライバからは見えるがアイドル状態*から、Linux 上で実際に計算し CPU
リファレンスまで確認できる状態へ進む、オープンで再現可能な道筋です。
元来の XDNA1/Phoenix のソースビルド経路を保ちつつ、同じ検出 → ビルド →
検証 → 常駐 runner の契約を Strix Point XDNA2 (`RyzenAI-npu4`) まで完成させました。

> **なぜこのリポジトリが存在するのか。** 7840U を含む Ryzen 7040/8040
> ノート PC の第 1 世代 **XDNA1** は、ドライバから見えていても現在の Linux
> ターンキー製品では使われずに残ることがあります。2026-08-15 時点の AMD
> 公式 Linux 対応ページが挙げるのは STX/KRK であり、Phoenix ではありません。[^amd-linux-support]
> この製品上の境界でデバイスが無価値になるわけではありません。現在は **2 つの
> オープンな低レベル経路**があります。本リポジトリが固定・パッケージする
> 再現可能な IREE 経路 `iree-amd-aie` と、IRON Python API／コンパイラ経路を
> 本リポジトリが 1.4.1 に固定する直接カーネルスタック
> [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) です。新しい演算子・
> アプリケーションライブラリ [`amd/IRON`](https://github.com/amd/IRON) は
> **MLIR-AIE 言語 bindings の上に構築された別プロジェクト**であり、
> `Xilinx/mlir-aie` の改名ではありません。本リポジトリは CPU 検証済み経路と
> 明確な証拠範囲を提供しますが、すぐ使える全モデルサーバーは主張しません。

> 🆕 **XDNA2 Strix Point（`RyzenAI-npu4`）を使っているなら？** 第2世代で状況は一変した:
> Linux 上のターンキー LLM 推論が今や存在し（FastFlowLM/Lemonade）、Ubuntu 26.04
> は XRT ユーザースペースをネイティブに同梱する — そして本リポジトリの
> アクティベーション用ツール群はそこで**無改変のまま**動作する
> （Ryzen AI 9 HX PRO 370 で検証済み）。**コンピュートも動く**:
> mlir-aie/IRON トラックは Strix の全 8 カラムで動作する — 6.65 TOPS の i8 GEMM、
> フル MobileNet、そして 8.0× のカラムスケーリングを示す我々のカスタムカーネル
> （[docs/MLIR-AIE.ja.md](docs/MLIR-AIE.ja.md)）。何が移植でき、何が変わり、
> オープンな最前線がどこへ移ったか: **[docs/XDNA2.ja.md](docs/XDNA2.ja.md)**。
> 後発の `npu5`/`npu6` は暗黙に同じターゲットへ割り当てず、対応も主張しません。
> 正確な範囲は [サポート表](docs/SUPPORT.md) を参照してください。

## 🌱 なぜ無償で公開するのか

1 台のマシンで PASS したことはゴールではありません。このリポジトリを MIT
ライセンスで無償公開するのは、Linux ユーザーが全レイヤーを調べ、証拠を再現し、
カーネルを変え、改善をコミュニティへ返せるようにするためです。学生、個人開発者、
研究者、小さなチームがこの共通基盤から、プライベートなエージェント、アクセシビリティ、
多言語モデル、省電力サービス、新しい量子化、まだ想像していない用途を含む
**多様な LLM とローカル AI**を育ててほしいと願っています。

**MIT ライセンスの条件に従えば、誰でも本成果を使用、コピー、変更、fork、
公開、再配布、サブライセンス、教育利用、商用利用できます。** 必要な著作権
表示とライセンス表示を残してください。第三者コードとモデル資産には各自の
ライセンスが適用されます。別途許可は不要で、改善の還元は歓迎しますが義務ではありません。

これは任意の LLM がすでにすべて動くという主張ではなく、そのための土台です。
厳密なデバイス検出、固定されたビルド、CPU リファレンス、常駐 C/Python 呼び出し、
実例、失敗境界を公開します。成功の尺度は 1 つのモデルを所有することではなく、
他の人がこの上に自分のものを作れることです。英語版
[Open NPU Lab](docs/OPEN-NPU-LAB.md) から入り、各主張を一次資料へつなぐ
[研究台帳](docs/RESEARCH.md) を読み、[オープン LLM ロードマップ](docs/LLM-ROADMAP.md)
または [コントリビューションガイド](CONTRIBUTING.md) から次の課題を選んでください。

## 🎬 デモ

### XDNA2 / Strix Point — 実機

IREE `npu4` の i32・bf16 matmul は CPU リファレンスと完全一致し、
常駐 runner は 16,384 個の出力すべてを検証、カスタム IRON カーネルは
XRT と HRX の両方で全 8 カラムを PASS した:

![CPU との完全一致、npu-runner の全出力検証、IRON の XRT・HRX PASS を示す XDNA2 Strix Point 実機デモ](docs/media/xdna2-compute.gif)

### XDNA1 / Phoenix — 従来の実機検証デモ

**ハイブリッド経路の仕組み — 生成した ONNX MLP**（matmul は NPU、`ReLU`
は CPU。学習済みアプリではなく生成 weight を使用し、CPU リファレンスと約
0.3% の差で一致）:

![onnx-mlp end-to-end demo](docs/media/onnx-mlp.gif)

| | |
|:--:|:--:|
| diagnose → matmul → benchmark → Python、**NPU 上で** | 3 つの `videotestsrc` パターンに非 AI の NPU 2D box blur → `/dev/video10` |
| ![npu-runner demo](docs/media/npu-runner.gif) | ![npu-camera demo](docs/media/npu-camera.gif) |
| ウェイクワード経路 — **例示用の未学習 weight** を使う NPU 全結合層 3 段 | bf16 は NPU 本来の強み — 最大 **220 GFLOP/s** |
| ![wake-word demo](docs/media/wake-word.gif) | ![benchmark demo](docs/media/benchmark.gif) |
| 実際の `.onnx` を NPU をターゲットにできる MLIR へ持っていく（ハイブリッドインポート。ソースからの amd-aie コード生成の op カバレッジが最前線） | NPU へ**実際にコンパイルできる** matmul・conv を抽出 — `npu-trim` が op を選別し、クリーンなカーネルを出力 |
| ![onnx-import demo](docs/media/onnx-import.gif) | ![npu-trim demo](docs/media/npu-trim.gif) |

## ✅ 動作するもの（検証済み）

**NPU 上で**（`--device=amdxdna`）コンパイル・実行し、正しい結果が得られ、再現可能なもの:

| ワークロード | 形状 | 結果 | スループット（NPU） |
|---|---|---|---|
| `i32` matmul | 128×128×128 | ✓ 完全一致 | ~3.6 ms/iter, ~280/s |
| `bf16 → f32` matmul | 256×256×256 | ✓ 完全一致（小数部含む） | ~2.9 ms/iter, ~350/s |

テストしたマシン: **Lenovo ThinkPad T16 Gen2 · Ryzen 7 PRO 7840U（Phoenix, XDNA1）
· Radeon 780M · Ubuntu 26.04 · kernel 7.0 · in-tree `amdxdna` · XRT 2.21 · NPU FW 1.5.5.391**。
これらの XDNA1 測定値は当時の nightly による履歴です。Strix で再検証した現在の
厳密な v1 ピンでは、まだ再測定していません。

## 📊 ベンチマーク

`iree-benchmark-module` による NPU 上でのエンドツーエンド計測（`--device=amdxdna`、
`npu1_4col`、10 回反復、平均）。実時間にはホスト側のディスパッチオーバーヘッドが含まれるため、
最小サイズの matmul はディスパッチ律速になる。実効コンピュートはサイズが大きくなるほど上昇する。

| dtype | 形状 (M×N×K) | time/iter | スループット | コンピュート |
|---|---|--:|--:|--:|
| `i32` | 128×128×128 | 3.58 ms | 279 it/s | 1.2 GFLOP/s |
| `i32` | 256×256×256 | 8.08 ms | 124 it/s | 4.2 GFLOP/s |
| `i32` | 512×512×512 | 43.6 ms | 23 it/s | 6.2 GFLOP/s |
| `bf16→f32` | 256×256×256 | 2.86 ms | 350 it/s | 11.7 GFLOP/s |
| `bf16→f32` | 512×512×512 | 3.90 ms | 257 it/s | 68.8 GFLOP/s |
| `bf16→f32` | 1024×1024×1024 | 9.76 ms | 102 it/s | 220 GFLOP/s |

**bf16 こそが NPU 本来の強みだ** — 1024³ で ~220 GFLOP/s に達し、なおもスケールし続ける。
一方 `i32`（AIE のネイティブ型ではない）は 6 GFLOP/s 付近で頭打ちになる。任意の行を再現するには:
`BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`。


## 🚀 クイックスタート

```bash
git clone https://github.com/Jonas-Augustinus-Linus/ryzen-npu-linux.git
cd ryzen-npu-linux

# ホスト・ディスク・sudo 要件を読み、厳密な読み取り専用チェックを実行する。
less docs/SUPPORT.md
./scripts/check-npu.sh --strict

# group/memlock/XRT が失敗した場合だけ内容を確認し、実行後に一度再起動する。
./scripts/enable-npu.sh

# versions.lock で固定した IREE/Peano ツールチェーンをソースからビルドする。この段階で
# --full のネイティブ IRON ホストチェックに必要な libxrt-dev もインストールする。
./scripts/build.sh

# 公開受入契約: 検出 -> CPU リファレンス -> native/Python runner。
./scripts/verify-stack.sh --quick

# 任意: 別途 pin された IRON スタックをセットアップしてから、すべて検証する。
./scripts/setup-mlir-aie.sh
./scripts/verify-stack.sh --full
```

## 🧰 ツール

| スクリプト | 何をするか |
|---|---|
| [`scripts/check-npu.sh`](scripts/check-npu.sh) | 読み取り専用: ドライバ、デバイスノード、render グループ、memlock、XRT、pyxrt をチェックする。 |
| [`scripts/enable-npu.sh`](scripts/enable-npu.sh) | 非 root ユーザーをブロックする3つの要因（render グループ、memlock、XRT）を修正する。 |
| [`scripts/detect-npu.sh`](scripts/detect-npu.sh) | 検証済み VBNV/ジオメトリだけを `npu1_4col` または `npu4` に割り当てる。 |
| [`scripts/build.sh`](scripts/build.sh) | `versions.lock` で固定した IREE/Peano ソーススタックをビルドする。 |
| [`scripts/run-matmul.sh`](scripts/run-matmul.sh) | `i32`/`bf16` matmul をコンパイル・実行し、全出力を CPU と比較する。 |
| [`scripts/verify-stack.sh`](scripts/verify-stack.sh) | CLI、native/Python runner、任意のアプリ/IRON を検証する厳密な実機テスト。 |
| [`scripts/validate-repo.sh`](scripts/validate-repo.sh) | ハードウェア不要のローカル/CI リリースチェック。 |

## 🔬 サンプルとツール

- [`tools/npu-trim/`](tools/npu-trim/) — import したグラフを選別し、検出した
  ターゲットにコンパイルできる matmul/conv だけを抽出します。任意 ONNX の
  ランタイムではありません。
- [`tools/npu-runner/`](tools/npu-runner/) — VMFB を一度ロードし、C と
  Python/ctypes から常駐呼び出しします。
- [`examples/local-rag-sidecar/`](examples/local-rag-sidecar/) — **実際の RAG
  ループへ NPU を組み込む統合例**: CPU chunk/hash → 常駐 NPU score matrix →
  CPU top-k → 任意のローカル LLM。特徴量は学習済み embedding ではなく、
  小規模な 1 クエリは CPU の方が速い可能性があります。現行 pin の XDNA1
  実機検証は未完了で、現在の live 証拠は XDNA2 です。
- [`examples/wake-word/`](examples/wake-word/) — 例示用 matched-filter weight
  で常駐 NPU dense layer を 3 段実行します。**学習済み wake 語彙ではありません**。
- [`examples/onnx-mlp/`](examples/onnx-mlp/) — **生成した**モデルによる実際の
  ハイブリッド forward: NPU matmul 2 段、明示的な CPU ReLU、CPU 参照比較。
- [`examples/npu-camera/`](examples/npu-camera/) — 実際の GStreamer → NPU →
  `v4l2loopback` 配管ですが、現在の NPU 演算は **非 AI の box blur** です。

## 🧩 2 つ目の道: `mlir-aie`（IRON）

`iree-amd-aie`（上記）は対応 IREE グラフをコンパイルします。
[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) は本リポジトリが
1.4.1 に固定する低レベルスタックです。その IRON Python API／コンパイラ経路で
**NPU カーネルを直接記述し**、`pyxrt` 経由で実行します。さらに本物の
ML の `programming_examples` を同梱しています。**両世代**の実機根拠はありますが、
同じ依存関係スナップショットで検証されたものではありません。Phoenix/`npu1` の
結果は当時の履歴で、v1 の厳密なピンは Strix/`npu2` で再検証済みです（自動検出）。
現在のピンによる XDNA1 の報告を歓迎します。セットアップが iree-amd-aie の Peano を
再利用するのは、その正確な `llvm-aie` バージョンと **clang ビルドコミット**の両方が
この mlir-aie リリースの `utils/peano-requirements.txt` のピンと一致する場合だけです。
一致しなければ、mlir-aie venv にそのピン留めされた wheel をインストールします。
詳しいガイド → **[docs/MLIR-AIE.ja.md](docs/MLIR-AIE.ja.md)**。

[`amd/IRON`](https://github.com/amd/IRON) は、MLIR-AIE 言語 bindings の上に
構築された別の新しい演算子・アプリケーションライブラリです。
`Xilinx/mlir-aie` の改名でも移転先でもありません。この動き続けるライブラリは、
本 release が固定する直接カーネル経路より大幅に広い範囲を扱います。
厳密な commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93) で、AMD
公式 Phoenix workflow は **2,105 件成功、45 件スキップ**を報告しました。
これは pytest の case-run 数です。既定の 5 iterations を考慮すると、
**異なる成功構成 421 件と異なる skip 構成 9 件**であり、2,105 個の別テスト
ではありません。9 件の skip は MHA、streaming-SwiGLU、GEMV+GELU が各 3
構成で、それぞれ 5 回反復されています。[^iron-phoenix-ci] 成功した CPU 参照
AIE2 範囲には GEMM/GEMV、Q4NX 逆量子化、softmax、RoPE、
RMSNorm/LayerNorm、activation、transpose が含まれます。これは上流 Phoenix
の根拠であり、本 repo の現行 pin XDNA1 再実行でも LLM 全体でもありません。
GQA はこの Phoenix run では立証されていません。

```bash
./scripts/setup-mlir-aie.sh                 # mlir_aie wheel + py3.14 venv + compatible Peano
./scripts/run-mlir-example.sh ml/conv2d     # build for the detected NPU + run ON IT (pyxrt)
./examples/mlir-aie/relu_add/run.sh         # a custom hand-written fused kernel
```

**NPU 上で** 検証済み（XDNA1、`run_py` / `pyxrt`、出力を torch/numpy のゴールデンと照合）:

| Example | Kind | NPU time |
|---|---|--:|
| `basic/passthrough_kernel` | DMA passthrough | ✓ |
| `basic/vector_scalar_mul` | vector × scalar | ✓ |
| `ml/conv2d` | INT8 3×3 conv | ~0.9 ms |
| `ml/conv2d_fused_relu` | conv + ReLU fused | ~0.8 ms |
| `ml/bottleneck` | ResNet bottleneck block | ~2.8 ms |
| `ml/resnet/layers_conv2_x` | ResNet conv2_x layers | ~5.1 ms |
| `ml/magika` | Google's file-type model (bf16) | ~0.9 ms |
| [`examples/mlir-aie/relu_add`](examples/mlir-aie/relu_add/) | **custom** fused `relu(a+b)` kernel | ~0.37 ms |

**XDNA2**（Strix Point、8 カラム / 32 タイル、mlir-aie 1.4.1）では: アレイ全体の
GEMM が **6.65 TOPS**（i8）/ **4.64 TFLOPS**（bfp16 経由の bf16）に達し、LLM ブロック
（softmax/RoPE/SwiGLU/RMSNorm）はパスし、**フルの `ml/mobilenet` が動作し**
（~176 ms — Phoenix の 4 カラムでは *動かせない* 設計です）、我々のカスタムカーネルは
カラム全体で **8.0×** にスケールします。XDNA2 の表と、自分のカーネルを書く
ウォークスルーは **[docs/MLIR-AIE.ja.md](docs/MLIR-AIE.ja.md)** にあります。

## 🪤 落とし穴（素朴なビルド/実行が失敗する理由）

詳細はすべて **[docs/GOTCHAS.ja.md](docs/GOTCHAS.ja.md)** に。要点だけ:

1. **ホストコンパイラには `clang` ではなく `gcc` を使う。** clang 21 は MLIR の `BuiltinDialectBytecode.cpp` のコンパイルで *segfault* する。
2. **`-DIREE_BUILD_PYTHON_BINDINGS=OFF`。** Python バインディングは `-Werror,-Wmacro-redefined` に引っかかる。CLI ツールにはそれらは不要。
3. **固定された Peano（`llvm-aie`）を使う。** `build.sh` は `versions.lock` の正確な pin をインストールして検証し、より新しい nightly を暗黙に選ばず失敗する。
4. **`-DIREE_ERROR_ON_MISSING_SUBMODULES=OFF`。** 3つの重いサブモジュールを意図的にスキップする。
5. **`--iree-amdaie-device-hal=amdxdna` でコンパイルする**（＋ `--iree-hal-indirect-command-buffers=false --iree-hal-memoization=false`）。さもないとディスパッチがタイムアウトする。
6. ⚠️ **`--amdxdna_n_core_cols=4` で実行する。5 ではない。** Phoenix は raw で5列を報告するが、使うのは4列（`npu1_4col`）。5 を渡す → コアがハングする → `ert state 8` でタイムアウトする。

## 🎯 実際にこれをどこで使えるのか？

対象者別（ゲーム · AI エージェント · ローカルアプリ）の実現可能性評価付き完全ガイド → [docs/APPLICATIONS.ja.md](docs/APPLICATIONS.ja.md)。

**[docs/USE-CASES.ja.md](docs/USE-CASES.ja.md)** を参照。ハイブリッドな
ローカル AI ラボを作りましょう。NPU は反復 scoring、常時段階、検証済み
dense/conv ブロック、CPU は I/O・policy・fallback、iGPU は必要時の token
生成を担当します。[local RAG sidecar](examples/local-rag-sidecar/) がこの分担を
ソースで示します。XDNA1 の任意モデル全体を扱う drop-in server はまだなく、
エネルギー効率も実証済み成果ではなく測定目標です。

## 📚 背景

XDNA1 と XDNA2 の比較、第1世代で Linux が難しい理由、そして `amdxdna` HAL がどのように `/dev/accel0` と
やり取りするかについては **[docs/BACKGROUND.ja.md](docs/BACKGROUND.ja.md)** を参照。

## 🧭 このリポジトリの立ち位置（そして *何ではないか*）

**これは NPU-on-Linux の最初のプロジェクトではなく、スタックのどれ一つとして発明していない** —
ドライバ、コンパイラ、ランタイムはいずれもこれより前から存在し、重い仕事を担っている:

| レイヤー | 私たちが土台とする / 隣り合う先行成果 |
|---|---|
| カーネルドライバ | [`amd/xdna-driver`](https://github.com/amd/xdna-driver) — `amdxdna`、Linux 6.14 以降メインライン、XDNA1 を `/dev/accel/accel0` として列挙する |
| コンパイラ / ランタイム | [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)、[`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie)（固定した 1.4.1 の IRON Python API／コンパイラスタック）、[`Xilinx/llvm-aie`](https://github.com/Xilinx/llvm-aie)（Peano）、[`amd/Triton-XDNA`](https://github.com/amd/Triton-XDNA) — XDNA 世代を対象とする上流 SDK / フレームワーク |
| 新しい演算子／アプリケーションライブラリ | [`amd/IRON`](https://github.com/amd/IRON) — MLIR-AIE 言語 bindings 上の別プロジェクトであり、`Xilinx/mlir-aie` の改名・移転先ではない |
| 先行する XDNA1 + Linux コンピュート | 研究論文（[arXiv 2504.03083](https://arxiv.org/abs/2504.03083) — IRON 経由で Phoenix 7940HS 上で GPT-2）、プリミティブのみのチュートリアル、[Gentoo wiki の XDNA 解説](https://wiki.gentoo.org/wiki/User:Lockal/AMDXDNA) |
| Linux でのターンキー NPU LLM | [`FastFlowLM`](https://github.com/ROCm/FastFlowLM) と [`Lemonade`](https://github.com/lemonade-sdk/lemonade/blob/main/docs/guide/faq.md) の NPU 経路は XDNA2 を明示的に要件とする。AMD Ryzen AI Software 1.8 for Linux が挙げるのは STX/KRK のみで、Phoenix XDNA1 ではない |

したがって「Linux 初の NPU」「初のコンパイラ」「XDNA1 を初めて動かした」と言えば、いずれも
過大な主張になる — 私たちはそうした主張をしない。

**このリポジトリが *何であるか*:** **パッケージ化された、再現可能な、
エンドツーエンドのレシピ + ツールキット**です。ターンキースタックから外れた
XDNA1/Phoenix で実コンピュートを可能にすることから始まり、現在は Strix Point
npu4 にも同じ公開の正しさの契約を提供します。先行成果は、
アップストリームの **SDK / フレームワーク**（ソースからのつまずきは自分で乗り越える）、**XDNA2 専用** のアプリ、
**研究論文**（クリックして実行できるリポジトリはない）、あるいは **Windows 専用** のコンピュート経路のいずれかだ。
際立っているのはその *バンドル* である: diagnose→enable→build→run のスクリプト群、ソースからの
**落とし穴マップ**、**永続的な C-API/ctypes ランナー**（呼び出しごとの `iree-run-module` より ~11× 速い）、
**アプリ例**（ウェイクワード、NPU カメラデーモン）、**正直に実現可能性を評価したアプリケーションガイド**
（計測値「音声では NPU が CPU に負ける」を含む）、そして 5 言語のドキュメント。

> **正直な但し書き:** エコシステムは速く変化し、非公開・企業内の作業は見えません。
> 新たにクレジットまたは比較すべきプロジェクトや結果があれば Issue で知らせてください。
> より良い共有地図は全員の助けになります。

## ⚖️ 免責事項

これはコミュニティのノートであり、AMD/Xilinx の製品ではない。`iree-amd-aie` は初期フェーズで
変化が速く、バージョンやフラグはドリフトする。実機の根拠は日付とピンに依存する。
XDNA1/Phoenix の結果は当時の nightly による履歴であり、v1 の厳密なピンは
2026-08-15 までに Strix Point XDNA2 で再検証した。Hawk Point の結果はまだない。
現在のピンによる XDNA1 の結果、および他の XDNA1/XDNA2 システムの結果を、正確な
デバイス識別と検証ログとともに歓迎する。

## 🤝 コントリビュート

最も有用な貢献は、**あなた自身の XDNA1 または XDNA2 マシンでの再現可能な
結果**です。**[CONTRIBUTING.md](CONTRIBUTING.md)** を参照。要点だけ:

- **ハードウェアの結果を報告する** — あなたのチップ／カーネル／ディストロと、何が動いて何が失敗したか（Issue テンプレートを用意している）。
- 他の形状／dtype 向けの **ベンチマークを追加する**、あるいは **新しい op**（conv、i8、…）を追加する。
- **[落とし穴](docs/GOTCHAS.ja.md)** を修正・改良する、スクリプトを堅牢にする、または翻訳を追加・修正する。
- Fork → branch → `scripts/validate-repo.sh`、実機変更なら
  `scripts/verify-stack.sh --quick` → 実行内容を明記した PR。

## 📄 ライセンス

**[MIT](LICENSE)** © 2026 Jonas-Augustinus-Linus — 使用、コピー、変更、fork、
公開、再配布、教育利用、商用出荷ができます。ライセンスが求める著作権表示と
ライセンス表示を残してください。

このリポジトリのスクリプトとドキュメントは MIT だ。これらは、それぞれ独自のライセンスの下にある
サードパーティのプロジェクト — IREE と `iree-amd-aie`（Apache-2.0 WITH
LLVM-exception）、`Xilinx/llvm-aie`（Peano） — をビルドし駆動するものであり、このリポジトリはそれらを再配布しない。

[^amd-linux-support]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), 2026-08-15 閲覧。
[^iron-phoenix-ci]: AMD IRON, [公式 Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
