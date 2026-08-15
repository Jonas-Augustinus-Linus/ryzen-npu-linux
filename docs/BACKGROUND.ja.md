**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# 背景: XDNA1、XDNA2、Linux のオープンな経路

## ターンキースタックが先へ進んでも、シリコンが無価値になるわけではない

AMD Ryzen AI NPU は、Xilinx から受け継いだ **AI Engine (AIE)** の空間
アレイです。VLIW ベクタタイルをストリーミング/DMA インターコネクトで
結び、メモリ行と shim 行がホストへ接続します。CUDA 型の汎用 GPU として
扱うのではなく、タイル上に演算を配置してタイル間のデータをルーティング
します。[^iron-guide]

| | **XDNA1** (Phoenix/Hawk Point) | **XDNA2** (Strix および関連デバイス) |
|---|---|---|
| 搭載製品 | **7840U** を含む Ryzen 7040/8040 | Ryzen AI 300 ファミリ |
| タイルアーキテクチャ | AIE2 (`aie2`) | AIE2P |
| 本リポジトリのターゲット | Phoenix: 使用可能な 4 列、`npu1_4col` | 検証済み Strix: `npu4` |
| 公称 NPU 性能 | 7840U は最大 10 TOPS[^amd-7840u] | Ryzen AI 300 は最大 50 TOPS[^amd-platform-guide] |

7840U の公式仕様には、今も最大 10 TOPS の Ryzen AI エンジンが記載されて
います。現在のアプリケーションソフトウェアが Phoenix を一覧に含めないから
といって、その計算能力が消えるわけではありません。[^amd-7840u]

## 2026-08-15 時点の Linux の状況

カーネルの基盤は共通です。AMD のオープンな `amdxdna` ドライバは、対応
デバイスを Linux のアクセラレータインターフェースへ公開します。AMD は
ドライバ、XRT shim、ファームウェア要件、導入手順を公開しています。[^amdxdna]

便利な製品レイヤの対応範囲は世代ごとに異なります。AMD Ryzen AI Software
1.8 for Linux が挙げるのは **STX と KRK** であり、
Phoenix/XDNA1 ではありません。[^ryzenai-linux] これは現時点のターンキー
対応表であって、XDNA1 が Linux で計算できないという判定ではありません。

XDNA1 の実験者には、現在 **2 つのオープンな低レベル経路**があります。

1. **本リポジトリがパッケージする経路:** バージョンを厳密に固定した
   [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie) スタックです。
   IREE プログラムを lowering し、デバイス固有の VMFB を作り、`amdxdna`
   HAL から呼び出します。ここにあるスクリプトが、固定・ビルド・検出・実行・
   全出力の CPU 比較を一つにします。公開済み Phoenix の測定値は当時の
   nightly による過去の実機結果です。現在の v1 厳密 pin は Strix で再検証
   済みですが、Phoenix での再実行は残っています。
2. **直接カーネル経路:** Peano と XRT を使う
   [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) です。本リポジトリは
   IRON Python API／コンパイラスタックを 1.4.1 に固定し、開発者は空間 AIE
   カーネルとデータ移動を直接記述します。新しい演算子・アプリケーション
   ライブラリ [`amd/IRON`](https://github.com/amd/IRON) は MLIR-AIE 言語
   bindings 上の別プロジェクトであり、`Xilinx/mlir-aie` の改名・移転先では
   ありません。その上流結果は再現すべき研究上の手掛かりであり、本 release
   pin が継承する保証ではありません。

AMD IRON のコミット
[`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93) における公式 Phoenix
workflow は、**pytest case-run で 2,105 件成功、45 件スキップ**でした。[^iron-phoenix-ci]
既定の 5 iterations では、これは **異なる成功構成 421 件と異なる skip 構成
9 件**に相当します。9 件の skip は MHA、streaming-SwiGLU、GEMV+GELU が
各 3 構成で、それぞれ 5 回反復されています。AIE2/Phoenix 実機テストで
成功した CPU リファレンス範囲には GEMM/GEMV、Q4NX
逆量子化、softmax、RoPE、RMSNorm/LayerNorm、activation、transpose が含まれます。
これは XDNA1 が ML カーネルの実験室として有用であるという強いアップストリーム
根拠です。ただし、本リポジトリの厳密な v1 スタックを再実行した結果でも、
XDNA1 上のエンドツーエンド LLM の主張でもありません。MHA と
streaming-SwiGLU は正確な skip に含まれ、GQA はこの Phoenix run では
立証されていません。その境界も結果とともに伝える必要があります。

## 本リポジトリの `amdxdna` HAL 経路がデバイスへ到達する仕組み

`iree-amd-aie` は対応演算を次の要素へコンパイルします。

1. **AIE コアプログラム:** Peano (`llvm-aie`) が該当する AIE
   アーキテクチャ向けのタイルごとのコードをコンパイルします。
2. **構成と制御:** データフロー lowering、ルーティング、DMA/制御コード、
   デバイスプログラムを `.vmfb` にまとめます。
3. **ホストからの呼び出し:** IREE `amdxdna` HAL が `/dev/accel/accel0` を開き、
   カーネル UAPI 経由でコマンドを投入して fence を待ちます。これは IRON
   サンプルが使う別の XRT/`pyxrt` ホスト経路とは異なります。

デバイス形状も正しさの契約に含まれます。検証済み Phoenix マッピングでは
`npu1_4col` と `--amdxdna_n_core_cols=4` が一致しなければなりません。本
リポジトリは将来の未知デバイスにターゲットを推測で割り当てません。
[GOTCHAS #6](GOTCHAS.ja.md) と [対応表](SUPPORT.md) を参照してください。

## 2 つの経路がともに重要な理由

IREE 経路は、再現可能なアプリ統合と常駐 C/Python ランタイムを実用的に
します。IRON 経路は、タイル、FIFO、カーネル、動き続ける演算子の最前線を
見えるようにします。両方を使えば、一般のノート PC 所有者も CPU で照合した
matmul から始め、ハイブリッドなローカル AI を組み立て、コンパイラや演算子の
境界を一つずつ動かせます。

プロジェクト全体の地図は英語版 [Open NPU Lab](OPEN-NPU-LAB.md)、一次資料と
主張の範囲は [研究台帳](RESEARCH.md)、未完了の作業は
[LLM ロードマップ](LLM-ROADMAP.md) を参照してください。

[^amd-7840u]: AMD, [Ryzen 7 7840U 仕様](https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html).
[^amd-platform-guide]: AMD, [Ryzen and Radeon consumer pocket guide](https://www.amd.com/content/dam/amd/en/documents/partner-hub/ryzen/amd-consumer-pocket-guide-ryzen-radeon-july-2024.pdf), 2024-07.
[^amdxdna]: AMD, [`xdna-driver`: AMD NPU 用 Linux ドライバと XRT インターフェース](https://github.com/amd/xdna-driver).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 — Linux システム要件と対応プラットフォーム](https://ryzenai.docs.amd.com/en/latest/linux.html), 2026-08-15 閲覧。
[^iron-guide]: AMD IRON, [Programming guide](https://github.com/amd/IRON/blob/main/programming_guide/README.md).
[^iron-phoenix-ci]: AMD IRON, [公式 Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit `cdc48e93`.
