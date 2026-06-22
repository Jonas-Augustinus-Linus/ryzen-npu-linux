**[🇬🇧 English](USE-CASES.md) · [🇩🇪 Deutsch](USE-CASES.de.md) · [🇫🇷 Français](USE-CASES.fr.md) · [🇰🇷 한국어](USE-CASES.ko.md) · [🇯🇵 日本語](USE-CASES.ja.md)**

# Linux 上で XDNA1 NPU は実際どこに使えるのか?

成熟度については自分に正直になろう。今日 Linux + XDNA1 上で
`iree-amd-aie` から得られるのは、**AIE カーネル向けのコンパイラ + ランタイム**
(matmul、conv、およびその周辺の要素単位演算)であり、`iree-*` CLI と IREE
ランタイム C API から到達できる。これは **すぐ使えるモデルサーバーではない**。

## 心構え: このノート PC における NPU vs iGPU vs CPU

| デバイス | 得意なこと | 用途 |
|---|---|---|
| **NPU (XDNA1, ~10 TOPS)** | 持続的で **低消費電力** な量子化/bf16 推論カーネル | バッテリーを温存しつつ特定の matmul/conv ブロックをオフロードする |
| **iGPU (Radeon 780M)** | 高スループットの汎用計算 | **今日の Linux における本命のローカル AI 主力** — Vulkan/ROCm 経由の LLM |
| **CPU** | あらゆること、レイテンシに柔軟 | 接着剤、制御、フォールバック |

NPU が存在する唯一の理由は **ワットあたりの性能** だ。消費電力を気にしないなら、
汎用 AI を Linux 上で動かすには 780M iGPU の方が速く、はるかに容易な道筋になる。

## ✅ 今日うまくはまる用途

- **NPU / 空間データフロープログラミングの学習。** コンパイル対象として実際のデバイスがあり、
  実行の様子を観察できる。`run-matmul.sh` は改変できる動作するベースラインだ。
- 各種シェイプ・dtype (i32, bf16→f32) での matmul/conv に対する **NPU のベンチマーク**。
- **低消費電力推論の *プリミティブ*。** 手作りの matmul/conv カーネルを IREE ランタイム
  C API 経由でアプリに組み込み、`--device=amdxdna` でディスパッチして、
  安定した軽量ワークロードを CPU/GPU から逃がす(例: 小さな CNN ステージ、
  特徴抽出器、信号処理向け matmul)。
- AIE タイリング、objectFifo vs air パイプライン、パケットフローに関する
  **プロトタイピング / 研究** — 最終的により大きなモデルを実用化する構成要素。
- **アップストリームへの貢献。** Linux 上の XDNA1 に関するあらゆる結果が役立つ。
  プロジェクトの CI には専用の Phoenix ランナーがあるが、コミュニティのカバレッジは薄い。

## 🚫 今日の XDNA1+Linux では現実的でないもの

- **NPU 上での LLM / Whisper / Stable Diffusion のすぐ使えるサービング。** Linux 上の
  XDNA1 を対象とするドロップインのランタイムは存在しない。**iGPU**
  (Ollama/llama.cpp Vulkan、ROCm)、または **Windows**(レガシーの Vitis AI / Studio Effects)、
  あるいは **XDNA2** ハードウェアを使うこと。
- **「`.onnx` を指定すれば動く」。** ONNX Runtime の Vitis AI EP は Linux 上のクライアント
  NPU では CPU にフォールバックする。任意のグラフをインポートするのではなく、
  カーネルを自分で記述/ロワリングする。
- **量子化してデプロイするパイプライン。** 量子化ツールは存在するが、その結果を
  XDNA1+Linux で動かすための *ランタイム* が欠けている — だから、ここでデプロイできることを
  期待して量子化してはいけない。

## コンパイル済みカーネルをアプリに組み込む方法

`iree-compile` が生成する `.vmfb` は IREE ランタイムによってロードされる。いずれかの方法で:

- **CLI**: `iree-run-module --device=amdxdna ... --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4`
  (バッチジョブ / スクリプトに最適)、または
- **C API**: `iree-install` から `iree/runtime` をリンクし、`amdxdna`
  HAL デバイスを作成し、モジュールをロードして呼び出す — CLI が使うのと同じ経路だ。
  これが NPU の matmul/conv を実際の低消費電力パイプラインに組み込む方法になる。

## すぐ使える NPU 利用が欲しいなら

1. **XDNA2 ハードウェア**(Strix / Strix Halo / Krackan)— 2026 年の Linux NPU の勢いが
   実際に集まる先(Lemonade/FastFlowLM、AMD Ryzen AI SW for Linux)。
2. この同じ 7840U 上での **Windows** — そこではレガシーの Vitis AI 経路と Windows Studio
   Effects が Phoenix をサポートしている。
