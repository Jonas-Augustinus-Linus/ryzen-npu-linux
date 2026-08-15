**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2（Strix）— 何が変わり、何が引き継がれるか

このリポジトリは **XDNA1**（Phoenix/Hawk Point）の検証済みマップである。XDNA1 では、
ソースからビルドした `iree-amd-aie` が今なお Linux 上で NPU にコンピュートを実行させる
*唯一の* 方法だ。このページは **XDNA2**（Strix Point / Strix Halo / Krackan）との差分を
正直にまとめたものである: このリポジトリのレシピとツールのうち何が引き継がれ、
第2世代で何が変わり、オープンな最前線が今どこにあるのか。

以下の主張は 2 種類あり、明確に分けてある:

- **✅ 検証済み** — 実機の XDNA2 マシンで再現したもの:
  **Ryzen AI 9 HX PRO 370（Strix Point）· Radeon 890M · Ubuntu 26.04 · kernel 7.0
  · in-tree `amdxdna` · NPU FW 1.1.2.64**。
- **🔎 調査済み** — アップストリームのリポジトリ/ドキュメント/ベンチマーク（2026年8月）に
  基づくもので、リンクは本文中に併記。ここではまだ再現していない。

## TL;DR

| | XDNA1（このリポジトリのホームグラウンド） | XDNA2 |
|---|---|---|
| Linux でのターンキー LLM | ❌ 皆無 — 出荷済みのどのスタックからも除外 | ✅ FastFlowLM + Lemonade 10.0（2026-03 以降） |
| XRT ユーザースペース | このリポジトリの手順でビルド/インストール | ✅ **Ubuntu 26.04 が標準で同梱**（`libxrt-npu2`） |
| カスタムカーネル（オープンな道） | `iree-amd-aie` / `mlir-aie` をソースから | 同じスタックだがサポートは向上: IRON 1.4.x は Strix をファーストクラスとして扱う |
| コントリビューションの在りか | *何かしら* を動かすこと自体 | オープンカーネルのギャップを埋めること（ターンキーの NPU カーネルはプロプライエタリ） |

このリポジトリが教えることのすべて — XRT の配管、memlock/render グループによる有効化、
ディスパッチオーバーヘッド、Peano、IRON でのカーネル作成 — は **そのまま引き継がれる**。
変わるのはターゲット名とアレイのジオメトリ、そして「NPU で LLM を動かす」ことが
XDNA2 ではもはや最前線ではないという事実だ。**最前線は、オープンで量子化され、チューニングされたカーネルである**。

## ✅ 検証済み: 今日の Strix Point マシンを、このリポジトリ自身のツールで

無改変の `scripts/check-npu.sh` を XDNA2 マシンで実行したところ、スクリプトのバグが
2 件見つかり（どちらもこのコミットで修正済み — 後述）、実際の状態は次の通りだった:

```
[1] amdxdna module loaded                       ✓
[2] 1022:17f0 Strix/Krackan/Strix Halo NPU      ✓  (XDNA2)
[3] /dev/accel/accel0 root:render 0660, RW      ✓
[4] user in 'render' group                      ✓
[5] memlock = 8192 KB                            ✗  ← the same old blocker
[6] xrt-smi present (2.21.75) but:               ✗
    mmap(len=64MB, MAP_LOCKED) failed (err=-11)
[7] pyxrt present, cannot open device            ✗  (same cause)
```

特筆に値する発見が 3 つある:

1. **Ubuntu 26.04 は XDNA2 の XRT ユーザースペースを標準で同梱している。** `libxrt2`、
   `libxrt-npu2`、`libxrt-utils-npu`、`python3-xrt`（2.21.75）はアーカイブからそのまま
   インストールできる — XDNA1 でも同じパッケージは存在するが、モデルを実行できる出荷済み
   ランタイムは無い。XDNA2 ではこれが動作するランタイムパスになっている。
2. **有効化を阻むブロッカーは XDNA1 と 1 バイトも違わず同じ。** memlock のデフォルト 8 MB
   が xrt-smi の 64 MB の `mmap(MAP_LOCKED)` を `EAGAIN` で壊す —
   まさに `scripts/enable-npu.sh` が書かれた理由となった失敗そのものだ。これは
   XDNA2 にも**無変更で**当てはまる（そして Ubuntu 26.04 ではパッケージ導入ステップはすでに済んでいる）。
3. **ファームウェアは最初から最新である**: FW 1.1.2.64 が
   `amdnpu/17f0_10/` からロードされる — FastFlowLM が要求する下限 ≥ 1.1.0.0 を上回っている。

### XDNA1 のツールを XDNA2 に向けて見つかったスクリプトのバグ（修正済み）

- `check-npu.sh [1]` は `pipefail` の下で `lsmod | grep -q` を使っていた: `grep -q` は
  最初のマッチで終了し、`lsmod` は SIGPIPE で死に（exit 141）、パイプラインは「失敗」する —
  モジュールが `lsmod` 出力の先頭近くにあるときだけ発火する、レースを含んだ偽陰性だ
  （ブート直後の Strix マシンではまさにそうなる）。現在は `/sys/module/amdxdna` をチェックする。
- `check-npu.sh [2]` は XDNA1 の lspci 文字列である `IPU|AI` にマッチさせていた。XDNA2 は
  `Neural Processing Unit`（デバイス `17f0`）として列挙される。チェックは現在両方に
  マッチし、どちらの世代を見つけたかを報告する。

## 🔎 名前の解読表（世代間の混乱ナンバーワン）

| レイヤ | XDNA1 | XDNA2 Strix Point | 出典 |
|---|---|---|---|
| lspci | `AMD IPU Device`（`1502`） | `Neural Processing Unit`（`17f0`） | ✅ 両マシンで確認 |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4`（Halo=`npu5`、Krackan=`npu6`） | [xdna-driver](https://github.com/amd/xdna-driver) |
| mlir-aie / IRON | `npu1` | `npu2` | [mlir-aie](https://xilinx.github.io/mlir-aie/) |
| iree-amd-aie | `npu1_4col` | `npu4` | [iree-amd-aie](https://github.com/nod-ai/iree-amd-aie) |
| ISA | AIE2 | AIE2P | [Peano](https://github.com/Xilinx/llvm-aie) |

## 🔎 状況の反転: XDNA2 にはターンキーが存在する — ただし罠がある

- **FastFlowLM** は v0.9.35（2026-03-11）でネイティブ Linux サポートを出荷したが、
  **XDNA2 専用** — XDNA1 は除外されたままであり、これがこのリポジトリのソースからの
  道が XDNA1 唯一のルートであり続ける理由だ。FLM v1.0.0 は AMD の
  [ROCm GitHub org](https://github.com/ROCm/FastFlowLM) に移った（2026-08）。
  **Lemonade 10.0** はこれを OpenAI 互換サーバとしてラップする
  （[Linux ガイド](https://lemonade-server.ai/flm_npu_linux.html)）。
- **その罠:** FLM の CLI は MIT だが、その **NPU カーネルは無償利用可の
  プロプライエタリバイナリ** だ。使うための製品であって、カーネル作成を学ぶための
  コードベースではない。オープンカーネルの道 — このリポジトリの領域 — こそが、
  いま XDNA2 のコントリビューションが息づく場所だ。
- **Linux で依然として欠けているもの**（世代を問わず）: ONNX Runtime の Vitis AI EP
  （[ドキュメント](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html)）
  — そのため `npu-trim` のグラフを選別するアプローチは XDNA2 でもニッチを保つ。
  Linux 上の GAIA は iGPU のみを駆動する
  （[amd/gaia#1220](https://github.com/amd/gaia/issues/1220) が NPU ルートを要望している）。

## 資産ごとに見る: このリポジトリの何が XDNA2 に移植できるか

| 資産 | XDNA2 での状態 | 何が変わるか |
|---|---|---|
| `scripts/check-npu.sh` | ✅ 動作する（このコミット） | XDNA2 の PCI 文字列と世代の報告を追加 |
| `scripts/enable-npu.sh` | ✅ **無改変で**動作する | 同じ 3 つのブロッカー。Ubuntu 26.04 はパッケージをプリインストール済み |
| `scripts/build.sh`（iree-amd-aie） | 🔎 移植できるはず | `npu4` はサポート対象ターゲット。プロジェクトは活発（Peano npu4 向け softmax ukernel、ERT_CMD_CHAIN バッチング）。コミットのロックステップという落とし穴（ピン留めされた xdna-driver）は残る |
| `scripts/run-matmul.sh` | 🔎 移植できるはず | ターゲット `npu1_4col` → `npu4`。`amdxdna` HAL フラグはそのまま |
| `tools/npu-runner` | 🔎 移植できるはず | IREE C API は不変 — npu4 ビルドに対して再コンパイルするだけ |
| `tools/npu-trim` | ✅ コンセプトは健在 | op カバレッジの最前線は動くが、アプローチは同一。これを置き換えるベンダー EP は Linux には依然として無い |
| `mlir-aie`（IRON）トラック | 🔎 **最有力の道** | IRON [1.4.x](https://github.com/Xilinx/mlir-aie/releases): Strix はファーストクラス（`npu2`）、**Peano がデフォルトバックエンドに**（我々はいずれにせよビルド済み）、**HRX** = XRT 不要のホストランタイムという選択肢。[amd/IRON](https://github.com/amd/IRON) はビルド済み op ライブラリ（GEMM、GEMV、MHA、GQA、RMSNorm、RoPE、softmax、dequant）を pip wheel として出荷 |

## 🔎 カーネルを書くときに効いてくるハードウェアの差分

- **ジオメトリ**: npu1 は 4 カラムのアレイ。Strix Point（`npu4`）は **4 行 × 8
  カラム — コンピュートタイル 32 個 + メモリタイル 8 個** で、カラム境界で
  パーティション可能、コンテキストスケジューリングはファームウェア管理
  （[カーネルドキュメント](https://docs.kernel.org/accel/amdxdna/amdnpu.html)）。
- **データ型**: AIE2P の目玉は **bfp16 ブロック浮動小数点** — 8 個の値が 8 ビットの
  指数を共有し、8 値あたり 9 バイト。そのサポートは feature flag ではなく、mlir-aie 内の
  約 450 か所以上のハードコードされた `__AIE_ARCH__` 条件で制御されている —
  移植の危険源であると同時に、名指しされたコントリビューション面でもある
  （[mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390)）。
- **ISA**: 公式マニュアルは依然として無いが、事実上オープン — Peano が公開 LLVM で
  これを実装しており、[Hello XDNA](https://tnzr.org/xdna/isa.html) は XDNA1/XDNA2 ISA を
  命令ごとのレイテンシ付きで再構成している。

## 🔎 計測された現実: XDNA2 NPU 上の LLM（なぜカーネルが最前線なのか）

- 50 TOPS の XDNA2 上の FLM: Llama 3.1 8B は **prefill 403 t/s** @1k ctx、decode
  12.8 t/s。gpt-oss-20b は decode 18.2 @1k → 12.0 @32k
  （[FLM ベンチマーク](https://fastflowlm.com/docs/benchmarks/llama3_results/)）。
- 同一シリコンでの比較: NPU は iGPU Vulkan に対して **prefill で約 1.5 倍** 勝り、
  decode では約 25% 負けるが、エネルギー効率は最大約 10 倍良い。decode は
  メモリ帯域の物理法則（CPU/iGPU/NPU で共有される約 120 GB/s の LPDDR5X）であり —
  どのエンジンもそこからは逃れられない。
- オープンなコードの較正点: 素朴なオープン XRT ディスパッチの llama.cpp フォーク
  （[OllamaAMDNPU](https://github.com/BrandedTamarasu-glitch/OllamaAMDNPU)、
  Strix Halo）は prefill 18.4 t/s、decode 1.4 t/s に達する — FLM の
  300–400 t/s の prefill との差は **カーネル/データフロー設計であって、ディスパッチの配管ではない**。
- 理にかなったアーキテクチャ: **NPU で prefill + iGPU で decode のハイブリッド** —
  まさに AMD 自身の Windows スタックが仕事を分割しているやり方だ。

## この先どこへ向かうか

1. **matmul レシピと `npu-runner` を `npu4` に移植し**、XDNA1 と XDNA2 の数値を
   並べて公開する（README と同じ表で）。
2. **4×8 アレイ上で IRON の GEMM/GQA を再現する**（mlir-aie 1.4.x。XRT 依存を
   落とすため HRX を試す）。
3. **量子化 prefill GEMM** — IRON フローによる W4A16（および bfp16 を活用する）カーネル。
   [TileFuse](https://arxiv.org/abs/2606.11357) がそのレシピを公開している
   （フル精度の NPU ベースラインに対して GEMV で最大 +281%）。
   [amd/IRON](https://github.com/amd/IRON) ライブラリには dequant はあるが **Q4/MXFP4
   GEMM は無い** — このギャップは本物であり、llama.cpp にはオープンで未着手の
   ggml-xdna バックエンド要望
   （[#21725](https://github.com/ggml-org/llama.cpp/issues/21725)）が、
   メンテナから見える着地点として存在する。

*ステータス: このページは 2026-08-15 に追加。✅ の項目は同日、上記の Strix Point
マシンで再現したもの。🔎 の項目は出典を本文中に併記している。*
