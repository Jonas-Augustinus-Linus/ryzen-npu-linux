**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Linux 上で XDNA1 NPU を使って実際に何が「できる」のか?

第1世代 Ryzen AI NPU (XDNA1 / "Phoenix"、例: 7840U) を Linux 上で **使いたい** 人 —
ゲーマー、ローカル AI / エージェント開発者、アプリ開発者、そして学習者 — のための、
実践的で正直なマップ。

## 正直な現実認識 (まずこれを読むこと)

今日 XDNA1+Linux で手に入るのは **カーネル/プリミティブレベル** であり、ターンキーではない。
唯一動作するソフトウェア経路は、ソースからビルドした [`nod-ai/iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)
であり — これは **AIE カーネル向けのコンパイラ + ランタイム** (matmul、conv、およびその周辺の
要素単位演算) であって、モデルサーバーではない。あらゆるターンキースタック (AMD
Ryzen AI SW for Linux、ONNX Runtime Vitis AI EP、Lemonade/FastFlowLM) は **XDNA1 を除外している**。
完全なターンキーのモデルや LLM は **XDNA2 / Windows** の領域だ。このラップトップ上での
大半の重いローカル AI には、**Radeon 780M iGPU** (Ollama/llama.cpp Vulkan、
ROCm) の方が速く、はるかに容易だ — それが本当の主力だ。**では、そもそもなぜ
NPU にこだわるのか?** その本物の強みが **持続的で常時稼働する推論プリミティブに対する
ワットあたり性能** にあるからだ: 永遠に動き続け、バッテリーをわずかしか消費せず、
CPU と iGPU をアイドルに保つ、小さな conv/matmul ブロック。それこそが構築する
価値のあるもの — そしてそのうちのいくつかは今日すでに構築可能だ。本ガイドの残りは、
過剰な約束をせずにその強みを活かすことについてだ。

> **すぐに葬り去るべき一つの神話:** **暗黙の CPU フォールバックは存在しない**。
> NPU に配置できない演算をコンパイラに渡すと、透過的な CPU 実行ではなく、
> **下流でのコンパイルエラー** になる。「モデルを NPU で動かし、難しい部分は
> フォールバックさせる」というのは、このツールチェーンの動作の仕方 **ではない** —
> グラフは自分で分割し、サポートされない部分は別個のコードとして CPU に残すのだ。

---

## 能力の上限: `iree-amd-aie` が *今日* XDNA1 で動かせるもの

これは他のすべてが依存する部分なので、正確に述べる。リポジトリ HEAD
`fddfec1b` におけるオンデバイス CI ハーネス (`build_tools/ci/cpu_comparison/run.py`、
`matmul_test_config.py`) とコンパイラのディスパッチ (`KernelDispatch.cpp`) に対して
検証し、それらのソースに対する敵対的レビューと照合した。

### NPU で本当に動作する演算 (llvm-cpu に対して数値的に検証済み)

| 演算 | `npu1_4col` で検証済みの dtype | ステータス |
|---|---|---|
| `linalg.matmul` (+ `matmul_transpose_a/b`、`batch_matmul`、`matmul4d`) | `i8→i32`、`i32→i32`、`bf16→f32` | ✅ CI で数値的に検証済み |
| `linalg.matmul` + **バイアス加算** (Linear 層) | `bf16→f32` のみ | ✅ npu1 で動作 (`MatmulThinBias`/`MatmulFullBias`、fusion フラグ) |
| `linalg.conv_2d_nhwc_hwcf` (素の 2D conv) | `i32→i32`、`bf16→f32`、`i8→i32` | ✅ npu1 で登録・実行 (`conv-decompose`) |
| **マルチディスパッチグラフ** (producer→consumer チェーン) | 上記と同様 | ✅ `three_matmuls`、`two_matmul_switching` が npu1 でパス |

つまりモデルは単一のカーネルに **限定されない** — サポートされる複数のディスパッチを
連結して、NPU 上で実行される小さなグラフにできる。

### 部分的 / 実験的な演算 (lowering は存在するが、ハードウェア上の CI 保証はない)

| 演算 | 実態 | 信頼度 |
|---|---|---|
| `linalg.softmax` | npu1 の lowering 戦略 **と** bf16 LUT-exp マイクロカーネルは存在するが、オンデバイスの e2e テストは [iree#21633](https://github.com/iree-org/iree/issues/21633) 待ちで **コメントアウト** されている。 | 🟡 コンパイル経路は存在。オンデバイスの正しさは CI 保証 **なし** |
| `conv_2d_nhwc_hwcf_q` (i8 **量子化** conv) | **FileCheck/コンパイル** フィクスチャ (`conv2d_nhwc_q.mlir`) のみ。いかなるハードウェア実行にも組み込まれて **おらず**、数値的に検証されて **いない**。 | 🟡 ソース/パスのサポートのみ — 動作すると仮定しないこと |
| i8 matmul + **dequant/requant** エピローグ (INT8 全結合パターン) | `matmul_elem_2.mlir` は本物の requant エピローグ **だが孤立している** — 登録するハーネスがないため、今日 CI 経由で実行 **されない**。実際に動かされているのは上記の *浮動小数点* matmul+bias 経路だ。 | 🟡 パターンはソース上で本物。自分で配線して検証する必要がある |
| `depthwise_conv_2d_nhwc_hwc` | lowering の分岐は存在するが、ツリー内で「脆弱、ガードレールなし」と説明されている。CI テストは **コメントアウト** されている。 | 🟡 試す価値はある。チューニングは覚悟。保証なし |
| `reduction_sum` | サンプルとして存在。 | 🟡 |

### 今日 XDNA1 で動かない演算

- **Attention / flash-attention** — AIE バックエンド向けに登録された attention 演算は
  まったくない。前提となる softmax の e2e は無効化されている。XDNA1 では ⛔。
- **LayerNorm、gather/embedding ルックアップ、動的シェイプ** — ディスパッチセットにない。
- **再帰セル (GRU/LSTM)** — lowering なし。そもそもアーキテクチャ的に相性が悪い。

### 小さなモデル全体を動かせるのか?

**構築可能だが、ターンキーではない。** *すべての* 層がサポートされる matmul / 素の conv /
fused 要素単位ディスパッチにマップされる、小さな **量子化 MLP または 2〜3 層 CNN** は、
NPU 上でディスパッチグラフとして実行できる。ただし: (a) このビルドは **`.onnx` や
PyTorch をインポートできない** — `IREE_INPUT_TORCH/ONNX/TOSA=OFF` かつ Python バインディング
なしでコンパイルされており、**`iree-import-onnx` も同梱しない**。手書きの **linalg レベルの
MLIR** だけを与える。実際のモデルをインポートするには、それらのフロントエンドを ON にして
**IREE を再ビルド** しなければならない。(b) サポートされない演算 (#21633 までの softmax、
attention、layernorm、depthwise、embedding、動的シェイプ) はすべて **ハードなコンパイルエラー**
なので、避けるか CPU に残さなければならない。(c) タイリングフラグは手動でチューニングする。
**npu1 でパスするリポジトリ内のモデル全体 (ResNet/MLP/transformer) の e2e テストは存在しない。**

**このマシンでの実測上限:** bf16 matmul は **1024³ で ~220 GFLOP/s** (本来の強み)、
`i32` は ~6 GFLOP/s (AIE のネイティブ型ではない)、小さな matmul は
ディスパッチオーバーヘッド律速。低デューティサイクルで1つの小さなモデルステージには十分。
LLM のサービングには **不向き**。

---

## ローカル AI / エージェント開発者向け

NPU はどのエージェントコンポーネントに対しても **ドロップインの推論エンジンではない**。だが
embedding、分類器、リランカー、ウェイクワードモデルの裏にある GEMM/conv 演算 **こそ** が
まさに NPU が動かすもの — だからこれらは空想ではなく、本物のエンジニアリング構築だ。
繰り返し現れるパターンは: **密な層を NPU に、逐次 / attention / softmax の接着部を CPU に。**

| アプリケーション | 実現可能性 | 方法 (具体的経路) | 注記 |
|---|---|---|---|
| ウェイクワード / キーワードスポッティング (常時稼働) | 🟡 構築可能 | CNN/FC の KWS モデル: CPU で mel フロントエンド → ~80 ms フレームごとに NPU で小さな conv2d / FC 分類器 → 閾値 → イベント発火。(`openWakeWord` のヘッドは3層 FC ReLU ネット — 純粋な matmul。) | **最良のエージェント適合例。** 極小で、永遠に動き、perf/watt がすべての肝。~数百 µs のディスパッチを償却するためフレームをバッチ化する。 |
| RAG embedding (MiniLM / bge-small / e5-small) | 🟡 構築可能 | エンコーダの **matmul** ブロックを NPU に lowering (bf16/i8)。softmax/layernorm/attention は CPU に残す。embedding はバッチ的でレイテンシ耐性あり (コーパスは一度だけインデックス化)。 | GEMM *こそ* がコストであり *かつ* サポートされている。グラフを分割して数値を検証する。 |
| バイエンコーダのリランキング (query×doc スコアリング) | 🟡 構築可能 | 事前計算済み embedding のバッチ matmul — ほぼ純粋な matmul であり、NPU の最良の演算。 | あらゆるエージェントタスクで最もクリーンなマッピング。クロスエンコーダのリランキングは attention が必要 → それは CPU に残す。 |
| 意図分類 / ルーティングヘッド | 🟡 構築可能 | 蒸留 MiniLM、または凍結 embedding 上の MLP: エンコーダ GEMM + 線形ヘッドを matmul として (bf16)。 | 短シーケンスで matmul 支配的 → ディスパッチオーバーヘッドが償却される。 |
| 小さな CNN 知覚 (UI 要素 / スクリーンショット分類器、OCR プレフィルタ) | 🟡 構築可能 | 素の `conv_2d_nhwc_hwcf` バックボーン (bf16、または i8→i32) + matmul ヘッドを NPU に。リサイズ/正規化は CPU。ViT は避ける (attention の壁)。 | 素の conv は検証済み。**i8 *量子化* conv はコンパイルのみ** なので、bf16 を優先するか i8 を自分で検証する。 |
| 音声エージェント向けの Whisper / 音声テキスト変換 | ⛔ 不向き (今日) | CPU 上の `whisper.cpp` または 780M (Vulkan) を使う。エンコーダ *は* 研究的な NPU オフロードになり得るが、エンドツーエンドの Whisper-on-iree-amd-aie は存在しない。デコーダは GEMV/メモリ律速。 | NPU-int8 の Whisper ビルドは Windows/Vitis を対象とし、XDNA1+Linux ではない。 |
| LLM **デコード** / トークン生成 | ⛔ 不向き | **iGPU** を使う: Ollama/llama.cpp Vulkan (gemma-2B で ~14 tok/s、7〜8B Q4 で ~5〜6 tok/s)。 | デコードは **メモリ帯域幅** 律速。NPU の FLOPs/watt の強みはこのボトルネックに効かない。最も明確な「iGPU を使え」ケース。 |
| LLM **プリフィル** (計算律速、「NPU に向く」はず) | 🟠 XDNA2/Windows が必要 | npu1 向けに lowering された fused attention + RoPE + RMSNorm + softmax が必要 — どれも存在しない。AMD の IRON `llama_3.2_1b` はこれらを実装しているが、**AIE2P/XDNA2** のみを対象とする。 | 「計算律速」が効くのは演算が lowering 可能なときだけ。XDNA1 では不可。 |
| 「`.onnx` を指定すれば NPU で動く」 | ⛔ 利用不可 | ONNX Runtime Vitis AI EP は Linux クライアント NPU では CPU にフォールバックする。このビルドにインポータはない。*インポート* すらするには `IREE_INPUT_ONNX/TORCH=ON` で IREE を再ビルドし、その上で大きな演算ギャップを覚悟する。 | ゼロからの再ビルドであり、ターンキーではない。 |

---

## ゲーマー向け

**容赦なく正直に言う:** 7840U の Linux ゲーマーは、出荷可能な形では **今日この NPU で
ゲームを速くも良くもできない**。NPU の生の弱さではなく、3つの硬い壁が原因だ:

1. **Proton サンドボックス。** ゲームは Proton/Wine 下の Windows `.exe` だ。NPU には
   Linux ネイティブの `amdxdna` ioctl (XRT XDNA SHIM + Linux ELF ランタイム) 経由でしか
   到達できない。**Proton プレフィックス内に Windows 側の `amdxdna` ドライバは存在しない**
   ため、ゲームは **NPU を呼び出せない**。唯一の経路は **プレフィックス外の別個の
   Linux ネイティブヘルパープロセス** だ。
2. **XDNA1 はあらゆるターンキースタックから見放されている** (FastFlowLM/Lemonade/Ryzen AI SW
   = XDNA2)。ここで動くのはソースからの `iree-amd-aie` だけだ。
3. **誰もゲームの NPU オフロードを出荷していない** (Linux、というか実質 Windows でも)。
   **NPU は現行ゲームで FPS をゼロしか生まない**。

> **大きな神話: FSR は NPU ワークロードではない。** FSR pre-4 は解析的 (ML なし)。
> FSR4 / Redstone のニューラルレンダリングは **GPU の RDNA4 WMMA** ユニットで動き、
> RX 9000 GPU が必要 — Ryzen AI NPU は一切使われない。AMD 自身のリアルタイム NPU
> アップスケーラ (REAPPEAR) は **XDNA2、Windows、動画向け** であり、AMD 自身がゲーム内の
> NPU アップスケーリングを *「将来の方向性」* と呼んでいる。

| アプリケーション | 実現可能性 | 方法 (具体的経路) | 注記 |
|---|---|---|---|
| **プロセス外コンパニオン** としてのローカル音声 / プッシュトゥトーク STT | 🟡 構築可能 | iree-amd-aie 経由でコンパイルした Whisper **エンコーダ** (GEMM 重め) を Linux デーモンで: PipeWire 経由でマイク読み取り → ローカルソケットでテキスト送出 → ゲーム/オーバーレイが消費。 | **唯一の現実的なゲーム隣接 NPU 用途。** レンダーループの外、~100〜300 ms のレイテンシに耐性、ネイティブ Linux (Proton の壁は当てはまらない)。エンコーダを XDNA1 に移植するのが難所。 |
| ニューラル NPC / 敵 AI (意図、戦術判断) | 🟡 構築可能 | Linux コンパニオンサービスが iree-compile 経由で小さなポリシー/MLP を動かし、ゲーム (mod/オーバーレイ) がソケット経由で問い合わせる。ターン制 / 秒スケールのみ。 | IPC + ディスパッチレイテンシのため 60 Hz のティックごとの戦闘は不可。DIY の mod パターンで、これを出荷するものはない。 |
| **ロード時** のプロシージャル生成 (テクスチャ/レベル) | 🟡 構築可能 | ネイティブ Linux プロセスでオフライン / レベルロード時に生成。ゲームはアセットをロードする。レイテンシ耐性あり。 | Proton の壁とフレームバジェットの両方を回避する。小〜中サイズのネットのみ。 |
| **キャプチャ/スクリーンショット** のオフライン/バッチ ML アップスケーリング (ライブではない) | 🟡 構築可能 | ディスクにキャプチャ → 小さな ESRGAN 風 conv スタックを `.vmfb` にコンパイル → `--device=amdxdna` で実行。 | オフラインであるから *こそ* 実現可能。Vulkan 経路 (Real-ESRGAN-ncnn) の方が今日ははるかに容易/高速。 |
| ゲームの **横で** (内部ではなく) 動くローカル LLM コパイロット | 🟡 構築可能 | 小さな量子化モデルをネイティブ Linux サービスとして。オーバーレイ/Discord ボットが消費。780M を空けておく。 | tok/s は控えめ。FastFlowLM/Lemonade が XDNA1 を拒否するためソースからの立ち上げになる。 |
| NPC のセリフ向けのゲーム内ニューラル TTS | 🟠 XDNA2/Windows が必要 | コンパニオンデーモンとしてはアーキテクチャ的に問題ないが、VITS/transformer ボコーダは XDNA1 でほぼ未実装。 | CPU TTS の方が今日はシンプル。 |
| フレームごとの **ゲーム内** ML 超解像 / アップスケーリング | ⛔ 不向き | ゲームは Proton 下で `/dev/accel/accel0` に到達できない。外部キャプチャ→アップスケール→再注入は 16 ms バジェットを破る。XDNA1 向けの SR conv カーネルは未記述。 | FSR4 = GPU。REAPPEAR = XDNA2/Windows。 |
| フレーム生成 | ⛔ 不向き | レンダーパイプライン (GPU) に紐づくモーションベクトル/オプティカルフローが必要。Proton 下でパイプラインにアクセス不可。フレームごとの往復がレイテンシを増やす。 | NPU を使うフレーム生成製品は存在しない。 |
| ランタイムアニメーション / ニューラル IK | ⛔ 不向き | フレームごとの密なエンジン結合 + Proton サンドボックス = ランタイム経路なし。オフラインツールのみ。 | |
| NPU 経由のリアルタイム外部キャプチャ・アップスケーラ | ⛔ 不向き | 動作する唯一のリアルタイムアップスケーラ (ncnn-vulkan 上の Anime4K、waifu2x/Real-ESRGAN/RIFE) は GPU/Vulkan であり **XDNA バックエンドがなく**、780M と競合する。 | 新しい MLIR-AIE conv カーネルを書く羽目になり *かつ* それでもレイテンシで負ける。 |
| オンデバイス NPU AI によるアンチチート | ⛔ 不向き | 無関係: カーネルアンチチートは Windows 専用。Proton 上の EAC/BattlEye はユーザーモードのポリシー選択。NPU を使うアンチチートはない。 | |

---

## アプリ開発者向け (低消費電力、常時稼働)

ここが NPU の perf-per-watt の強みが実際に報われる場所だ: 重いコアが **conv 状 または
matmul 状** であり、標準的な Linux メディア配管に組み込まれた、**持続的で低デューティサイクル**
なワークロード。正直な切り分けは、オーディオ vs ビジョンではなく **conv/matmul 状 vs 再帰** だ。

**統合面 (すべて標準的な Linux):**
- **オーディオ** → PipeWire `pw_filter` / `module-filter-chain` (DeepFilterNet の LADSPA
  プラグインが使うのと同じフック) → 仮想マイクを公開。
- **カメラ** → GStreamer/v4l2 経由でキャプチャ → NPU を実行 → Zoom/Chrome/OBS が読む
  **v4l2loopback** `/dev/videoN` (`exclusive_caps=1`) に書き込む。
- **汎用デーモン** → IREE ランタイム C API (`amdxdna` HAL デバイスを作成 → `.vmfb` を
  ロード → 呼び出し)、`samples/simple_embedding/simple_embedding.c` をモデルに。

| アプリケーション | 実現可能性 | 方法 (具体的経路) | 注記 |
|---|---|---|---|
| ウェブカメラの背景ぼかし / バーチャル背景 | 🟡 構築可能 | MediaPipe Selfie Segmentation (MobileNetV3 クラスの conv エンコーダ-デコーダ、256×256)。conv バックボーン (bf16) を NPU で実行。CPU でリサイズ + 合成。v4l2loopback へ出力。 | 純粋な conv → サポートされる `conv_2d_nhwc_hwcf` にマップ。128 の倍数でないシェイプはタイリング作業が必要。depthwise ステージは 🟡 (脆弱)。 |
| 仮想マイクとしてのマイクノイズ抑制 | 🟡 構築可能 | 古典的な RNNoise ではなく **DeepFilterNet** (conv エンコーダ-デコーダ)。STFT/ERB + ゲーティングは CPU に残す。conv ブロック (bf16) を NPU にオフロード。PipeWire `pw_filter` コールバック。フレームをバッチ化。 | 勝ち筋はレイテンシではなく **バッテリー** — CPU 版はすでにリアルタイム。<10 ms の厳しい締め切り + ディスパッチオーバーヘッドが難所。 |
| オンデバイス画像分類 / 自動タグ付け | 🟡 構築可能 | MobileNetV3 / EfficientNet-Lite: conv バックボーン (`conv_2d_nhwc_hwcf`) + matmul ヘッドを NPU に。低デューティサイクルでライブラリ全体をバッチ処理。リサイズ/正規化は CPU。 | **bf16 での** 最良のビジョン適合。i8 *量子化* conv + requant エピローグは **CI でコンパイルのみ** — i8 に頼る前に自分で検証する。 |
| セマンティック画像検索 embedding (MobileCLIP-S0 画像タワー) | 🟡 構築可能 | conv バックボーン + 最終射影 matmul → C API 経由で固定長ベクトル。CPU 上で sqlite/faiss に格納。一度インデックス化すれば問い合わせは安価。 | 理想的な低デューティサイクルのバックグラウンドジョブ。テキスト **transformer** タワーは attention が必要 → デバイス外で事前計算するか CPU に残す。 |
| オンデバイス OCR (スクリーンショット/スキャン) | 🟡 構築可能 | CRNN/PaddleOCR 風: conv 特徴抽出器を NPU で。CTC/シーケンスデコード + 任意の BiLSTM は CPU。テキスト行クロップをバッチ化。 | 再帰的な認識器は NPU 上に置け **ない** (softmax/attention がゲートされている)。 |
| 物体検出バックボーン (自動フレーミングのスマートカメラ) | 🟡 構築可能 | NanoDet/YOLO-nano: conv バックボーン+ネックを NPU に。アンカーデコード + NMS は CPU。v4l2loopback へ出力。 | NMS/アンカー計算は制御が重い → CPU。変則的な特徴マップシェイプはタイリングチューニングが必要。 |
| 省電力向けの在席 / 視線検出 | 🟡 構築可能 | 2〜5 fps の極小の顔/視線 CNN: conv 検出器を NPU に。「N 秒よそ見」で → CPU アクション (DPMS 減光 / ロック / 一時停止)。 | 低 fps が **ディスパッチオーバーヘッドを隠す** → 寛容なビルドの一つ。perf/watt は低デューティサイクルで最も強い。 |
| エンジン内のランタイムアニメーション / ニューラル IK | ⛔ 不向き | フレームごとのエンジン結合。オフラインのコンテンツツールとしてのみ実現可能。 | |
| NPU ワークロードとしての古典的 **RNNoise** (GRU) や **Silero VAD** | ⛔ 不向き | CPU に残す (RNNoise はすでに ~60× リアルタイムで動く)。NPU での音声強調には、**conv ベースの DeepFilterNet** に切り替える。 | GRU/LSTM は本質的に逐次的 (タイムステップが前の隠れ状態に依存)。ディスパッチオーバーヘッドが支配的。再帰の lowering は存在しない。 |

---

## 学習者向け

NPU はコンパイル対象にでき、**実行を観察できる** 本物のプログラマブルな空間データフロー
デバイスだ — クラウドハードウェアなしで AIE / MLIR / データフローを学ぶ絶好の方法。

| アプリケーション | 実現可能性 | 方法 (具体的経路) | 注記 |
|---|---|---|---|
| 動作する matmul を改変して AIE / 空間データフローを学ぶ | ✅ 今日動く | [`scripts/run-matmul.sh`](../scripts/run-matmul.sh) と [`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) から始める。シェイプ/dtype を変える。再コンパイルする。`--device=amdxdna` で実行する。 | このマシンで唯一実証的に検証された層。 |
| シェイプと dtype をまたいで matmul/conv をベンチマーク | ✅ 今日動く | `BENCH=1 ./scripts/run-matmul.sh bf16 1024 1024 1024`。i32 vs bf16 を比較し、ディスパッチ律速 vs 計算律速を観察する。 | なぜ bf16 がネイティブで、小さなカーネルがオーバーヘッド律速なのかを教えてくれる。 |
| 自前の conv2d / fused 要素単位カーネルを書く | 🟡 構築可能 | `linalg.conv_2d_nhwc_hwcf` または matmul+generic の MLIR を書く。`conv-decompose`/`pack-peel` でコンパイル。CPU リファレンスと照合して検証。 | 素の conv は検証済み。量子化 conv/softmax は実験的。 |
| 極小のエンドツーエンドモデル (量子化 MLP / 2〜3 層 CNN) を作る | 🟡 構築可能 | 各層をサポートされる linalg MLIR として書く (`three_matmuls.mlir` をモデルに)。1つの `.vmfb` にコンパイル。NPU 上でディスパッチグラフを実行。 | このビルドに `.onnx` インポートはない。サポートされない演算はフォールバックではなく **コンパイルエラー**。 |
| 実際の ONNX/PyTorch モデルをインポートして NPU をターゲットにする | 🟠 再ビルドが必要 (+ 大きな演算ギャップ) | `iree-import-onnx` を得るため `IREE_INPUT_TORCH/ONNX=ON` + Python バインディングで IREE を再ビルド。AIE 向けには attention/layernorm/softmax/embedding/動的シェイプ演算が **コンパイルに失敗する** ことを覚悟する。 | このビルドではフロントエンドは設計上オフ。インポート ≠ 実行。 |
| アップストリームの XDNA1-on-Linux カバレッジに貢献する | ✅ 今日動く | 自分の XDNA1 マシンで結果を実行。ハードウェアレポート / 新演算テストを提出する。Phoenix CI は存在するが、コミュニティのカバレッジは薄い。 | あらゆる結果が役立つ。[`CONTRIBUTING.md`](../CONTRIBUTING.md) を参照。 |
| 「NPU AI を学ぶ」ために LLM/Whisper を動かす | ⛔ 不向き | 道具が違う — モデルには 780M iGPU を、NPU は *プリミティブ* に使う。 | transformer のサービングを試みて NPU の旅を始めてはいけない。 |

---

## 自作 NPU プリミティブ (クックブック)

モデルの重いステージを、デーモンに組み込む NPU プリミティブに変える汎用パイプライン:

**1. モデルの重く並列なステージを選ぶ。** それは **matmul / 素の conv /
fused 要素単位** の形でなければならない。再帰 (GRU/LSTM) と attention/softmax のステージは
CPU に残す。前/後処理 (STFT、リサイズ、NMS、トークン化) は CPU に残す。

**2. linalg レベルの MLIR として表現する。**
[`examples/matmul_bf16.mlir`](../examples/matmul_bf16.mlir) (matmul) または
`conv_2d_nhwc_hwcf` テンプレートから始める。**`bf16` を優先する** (AIE ネイティブ、
~220 GFLOP/s の型)。i8 量子化は matmul には効く。i8 *量子化 conv* と i8 requant
エピローグは実験的なので、**頼る前に CPU リファレンスと照合して検証する**こと。
(このビルドは `.onnx`/PyTorch をインポートできない — MLIR を与える。)

**3. NPU 向けにコンパイルする。** 検証済みのフラグセット
([`scripts/run-matmul.sh`](../scripts/run-matmul.sh)、[`docs/GOTCHAS.md`](GOTCHAS.ja.md)):

```bash
iree-compile \
  --iree-hal-target-backends=amd-aie \
  --iree-amdaie-target-device=npu1_4col \
  --iree-amdaie-device-hal=amdxdna \
  --iree-amdaie-lower-to-aie-pipeline=air        `# bf16 matmul; use objectFifo for i8/conv` \
  --iree-amdaie-tile-pipeline=pack-peel          `# matmul; use conv-decompose for conv` \
  --iree-hal-memoization=false \
  --iree-hal-indirect-command-buffers=false \
  model.mlir -o model.vmfb
```

**4. 既知の入力で検証する。**

```bash
iree-run-module --device=amdxdna --module=model.vmfb \
  --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4   # cols=4 NOT 5, or ert state 8 timeout
```

**5. デーモン / メディアグラフに統合する。** `.vmfb` を次の経由で配線する:
- バッチジョブ / 手早いスクリプトには **CLI** (`iree-run-module`)。または
- **IREE ランタイム C API** — `amdxdna` HAL デバイスを作成し、モジュールをロードし、
  関数を解決し、呼び出す (`simple_embedding.c` をモデルに)。~数百 µs の投入オーバーヘッドを
  償却するため **ディスパッチごとにフレームをバッチ化** し、**CPU フォールバック経路** を保つ。
- それから **PipeWire** (`pw_filter` / `module-filter-chain` → 仮想マイク) または
  **GStreamer + v4l2loopback** (→ 仮想カメラ)、あるいは単なるソケットにフックする。

> 土台にするリポジトリのスクリプト: [`check-npu.sh`](../scripts/check-npu.sh) (生きているか?)、
> [`enable-npu.sh`](../scripts/enable-npu.sh) (render グループ / memlock /
> XRT)、[`build.sh`](../scripts/build.sh) (すべての回避策を含むソースからのビルド)、
> [`run-matmul.sh`](../scripts/run-matmul.sh) (コンパイル+実行のレシピ)。ホストコンパイラは
> **gcc** でなければならない (clang21 は `libIREECompiler.so` のリンクで segfault する)。

---

## どこから始めるか (対象者別)

- **エージェント開発者:** **ウェイクワード / KWS** プリミティブ (conv/FC、常時稼働) または
  **バイエンコーダのリランカー** (バッチ matmul) を作る — 最もクリーンな NPU 適合。
  LLM そのものは 780M iGPU で動かす。
- **ゲーマー:** 唯一現実的なビルドは、ソケット越しの **プロセス外の音声 (STT) コンパニオン
  デーモン** だ。NPU はサイドカーとして扱い、決してレンダーループの内側に置かない。
- **アプリ開発者:** **背景ぼかし** (カメラ → v4l2loopback) または **bf16** での
  **写真分類器** から始める — conv 状、レイテンシ耐性あり、perf/watt が勝つ。
- **学習者:** [`run-matmul.sh`](../scripts/run-matmul.sh) を改変し、bf16 vs i32 を
  ベンチマークし、それから自前の conv2d カーネルを書く。極小の MLP グラフへと進む。

## 🔇 実測: 音声では NPU は CPU に負ける

7840U で実測した。**CPU デノイザの 1 フレーム全体 (8 layers) = 0.063 ms** に対し、
**NPU の 1 ディスパッチ = 3.8 ms** — **~480× も遅く**、現実のデノイザは 1 フレームあたり
多数のディスパッチを必要とする (10 ms のリアルタイムバジェットを ≫ 超過する)。音声フレームは
極小なので、レイテンシは **ディスパッチオーバーヘッド律速** となり、NPU のスループットの優位は
一切効かない。RNNoise (GRU) には NPU lowering がそもそも存在しない。リアルタイムの
ノイズ抑制には **CPU を使う** こと — 例えば PipeWire の `module-filter-chain` 仮想マイク
経由の RNNoise (`librnnoise_ladspa.so`、ラベル `noise_suppressor_mono`、`playback.props`
で `Audio/Source` として公開) など。NPU はビジョン / matmul 用に取っておく。これが、
上記の音声の行が CPU に留まっている *理由* である。

## 正直な「XDNA1+Linux ではまだ手を出すな」リスト

- **NPU 上でのあらゆる LLM / Whisper / Stable Diffusion のサービング。** iGPU、または
  Windows/XDNA2 を使う。
- **NPU 上での LLM プリフィル *または* デコード** — プリフィルは attention が必要 (不在)、
  デコードは帯域幅律速 (iGPU が勝つ)。
- **NPU ディスパッチとしての attention/transformer を伴うあらゆるもの** — attention 演算がなく、
  softmax の e2e は無効 (iree#21633)。
- **任意の `.onnx`/PyTorch をインポートして「そのまま動かす」** — このビルドにインポータはない。
  サポートされない演算はフォールバックではなくコンパイルエラー。
- **ゲーム内 / フレームごとのアップスケーリングやフレーム生成** — Proton サンドボックス +
  レイテンシ + FSR4 は GPU。ここでは起きない。
- **NPU 上の GRU/LSTM モデル (古典的 RNNoise、Silero VAD)** — 逐次的で、
  再帰の lowering なし。CPU に残す。
- **自分で検証せずに i8 量子化 conv や i8 requant エピローグに頼る** こと — それらは今日 CI で
  コンパイルのみ/孤立したフィクスチャだ。

---

*信頼度の凡例: ✅ 今日動く (このマシンで検証済み) · 🟡 構築可能 /
実験的 (本物のエンジニアリング、サポートされる演算) · 🟠 XDNA2 または Windows が必要 · ⛔
NPU に不向き。Ryzen 7 PRO 7840U (Phoenix/XDNA1)、Ubuntu
26.04、カーネル 7.0、XRT 2.21、`iree-amd-aie` HEAD `fddfec1b` 上で 2026-06-22 に検証。
`iree-amd-aie` は初期フェーズで変化が速い — フラグや演算カバレッジはドリフトする。*
