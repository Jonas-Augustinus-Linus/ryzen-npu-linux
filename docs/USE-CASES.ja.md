**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# XDNA ノート PC をハイブリッドなローカル AI 実験室にする

NPU が一台で LLM 全体をサーブしなければ、システム内で役に立たないわけでは
ありません。現在の Linux + XDNA1 で現実的なのは、小さく反復され、CPU で
照合できる段階を NPU に任せ、I/O、ポリシー、未対応演算を CPU に残し、高い
スループットのトークン生成が必要なら iGPU を使う構成です。

```text
マイク / カメラ / 文書 / UI イベント
                    │
                    ▼
       CPU: I/O、制御、フォールバック
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
NPU: 常時トリガー、スコア、      iGPU: 量子化 LLM
dense/conv ブロック              prefill + 生成
        └───────────┬───────────┘
                    ▼
       CPU: ツール、ポリシー、出力
```

これは工学的な分担であり、普遍的な性能判定ではありません。低消費エネルギー
と長いバッテリー駆動は設計目標ですが、本リポジトリはそれを証明する管理された
エンドツーエンドのエネルギー測定をまだ公開していません。

## 提供ソースから作れる有用なプロジェクト

| プロジェクト | NPU の役割 | CPU / iGPU の役割 | 根拠の境界 |
|---|---|---|---|
| **プライベート RAG ヘルパー** | 常駐 bf16 matmul で文書/クエリをバッチスコアリング | CPU が分割・ハッシュ・top-k を担当し、任意で別 backend のローカル LLM が生成 | [`local-rag-sidecar`](../examples/local-rag-sidecar/) は NPU を実際の RAG ループに組み込みます。特徴量は学習済み embedding ではなく決定的な hashed bag-of-words です。小規模な 1 クエリは CPU の方が速い可能性があります。現在の実機証拠は XDNA2 で、現行 pin の XDNA1 は未実行です。 |
| **ローカル音声アシスタント** | 常時 wake/intent head | CPU が音声 front-end と制御、iGPU LLM が応答 | [`wake-word`](../examples/wake-word/) は常駐 NPU dense layer を 3 段実行しますが、提供 weight は学習済み wake 語彙ではなく経路を示すものです。 |
| **プライベートカメラ／アクセシビリティトリガー** | 対応する conv/dense 分類段階 | CPU が capture/composite、アプリが Linux event を出力 | [`npu-camera`](../examples/npu-camera/) は GStreamer → NPU → `v4l2loopback` の配管を証明しますが、現状の演算は AI ではない box blur です。学習し CPU で照合したモデル段階に置き換えてください。 |
| **ハイブリッド ONNX 実験** | 抽出した対応 matmul/conv partition | CPU が ReLU、graph glue、fallback を維持 | [`onnx-mlp`](../examples/onnx-mlp/) は実際のハイブリッド forward を実行しますが、ネットワークと weight は生成したデモデータです。[`npu-trim`](../tools/npu-trim/) は任意グラフを魔法のように対応させず、可能な部分を選別します。 |
| **量子化ブロック研究** | 各経路を検証しながら GEMM/GEMV、逆量子化、normalization、RoPE、softmax | CPU golden、未対応 attention/control、任意で iGPU が残りを担当 | AMD 公式 IRON Phoenix workflow の commit `cdc48e93` は、これらの primitive の CPU 参照 AIE2 例を通過しました。[^iron-ci] これは上流の根拠であり、本 exact-lock の XDNA1 結果でもエンドツーエンド LLM でもありません。 |
| **世代横断ラボ** | 同じソースをデバイス別ターゲットで実行 | CPU が識別情報を記録し、全出力を照合 | XDNA1 の過去記録、現行 pin の XDNA2、将来デバイスを分けて保存します。未知デバイスでの明確な失敗も有用な証拠です。 |

## 公開できる成果を生む進め方

1. **正しさの契約を一つ再現する。** 最適化より先に strict detector と
   全出力 CPU 比較を実行します。
2. **合成要素を一つ本物に置き換える。** wake-word weight を学習する、実際の
   embedding projection を用意する、camera blur を評価済みモデル段階に
   置き換える、のいずれかから始めます。CPU fallback は残します。
3. **組み合わせ、装わない。** NPU 段階をローカル LLM、データベース、desktop
   action、sensor loop と接続し、各演算の実行場所を明記します。
4. **アプリ全体を測る。** kernel と end-to-end の latency、転送、精度、idle/
   load 電力、タスク当たりエネルギー、温度、CPU/iGPU baseline を報告します。
   TOPS バッジだけでエネルギー効率は証明できません。
5. **境界を公開する。** デバイス識別、compiler commit、shape、dtype、コマンド、
   全出力の正しさ、skip、最初の失敗を記録します。最小再現付きの否定的結果も
   次の研究者を助けます。

## 役割の異なる 2 つのオープン経路

- 本リポジトリが固定する `iree-amd-aie` 経路は、デバイスモジュールと常駐
  C/Python 呼び出しをパッケージします。提供統合と厳密な release contract
  はここから始めます。
- 固定した [`Xilinx/mlir-aie`](https://github.com/Xilinx/mlir-aie) 1.4.1 経路は、
  直接の空間カーネル向け IRON Python API／コンパイラを公開します。新しい
  演算子・アプリケーションライブラリ [`amd/IRON`](https://github.com/amd/IRON)
  は MLIR-AIE 言語 bindings 上の別プロジェクトで、改名ではありません。
  commit `cdc48e93` の公式 Phoenix workflow は **pytest case-run で 2,105 件
  成功、45 件スキップ**でした。既定の 5 iterations では **異なる成功構成
  421 件、異なる skip 構成 9 件**です。skip は MHA、streaming-SwiGLU、
  GEMV+GELU が各 3 構成で、それぞれ 5 回反復されています。GQA はこの run
  では立証されておらず、結果を XDNA1 の全 LLM 主張に変えてはいけません。[^iron-ci]

AMD Ryzen AI Software 1.8 for Linux が挙げるのは Phoenix では
なく STX/KRK です。[^ryzenai-linux] これはすぐ使える製品経路の制限ですが、
上記のオープンな低レベル経路を閉じるものではありません。

## 正直な限界

任意の GGUF、Whisper、Stable Diffusion、ONNX モデルを受け取り、グラフ全体を
XDNA1 でサーブする対応コマンドは、ここにはまだありません。コンパイラ対応範囲、
メモリ、転送、ホスト制御は現実の制約です。有用な対応は、その境界を公開し、
検証済み段階だけをオフロードし、進歩に合わせて各段階を交換可能にすることです。

完全な招待状とソース／根拠ギャラリーは英語版 [Open NPU Lab](OPEN-NPU-LAB.md)、
一次資料と主張範囲は [RESEARCH.md](RESEARCH.md)、次の演算子・モデル目標は
[LLM ロードマップ](LLM-ROADMAP.md) を参照してください。

[^iron-ci]: AMD IRON, [公式 Phoenix workflow run 31876069460](https://github.com/amd/IRON/actions/runs/31876069460), commit [`cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93).
[^ryzenai-linux]: AMD, [Ryzen AI Software 1.8 for Linux](https://ryzenai.docs.amd.com/en/latest/linux.html), 2026-08-15 閲覧。対応プラットフォームとして STX と KRK を記載。
