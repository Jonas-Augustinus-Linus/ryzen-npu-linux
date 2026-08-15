**[🇬🇧 English](XDNA2.md) · [🇩🇪 Deutsch](XDNA2.de.md) · [🇫🇷 Français](XDNA2.fr.md) · [🇰🇷 한국어](XDNA2.ko.md) · [🇯🇵 日本語](XDNA2.ja.md)**

# XDNA2（Strix）— 何が変わり、何が引き継がれるか

このリポジトリの XDNA1 実機エビデンスは Phoenix / Ryzen 7 PRO 7840U で
得られた。Hawk Point はマッピング対象の `RyzenAI-npu1` 識別子を共有するが、
ここにはまだ個別の実機結果がない。この文書で扱う XDNA1 経路では、ソースから
ビルドした `iree-amd-aie` が Linux 上で使用したコンピュート経路である。このページは
**XDNA2**（Strix Point / Strix Halo / Krackan）との差分を
正直にまとめたものである: このリポジトリのレシピとツールのうち何が引き継がれ、
第2世代で何が変わり、オープンな最前線が今どこにあるのか。

以下の主張は 2 種類あり、明確に分けてある:

- **✅ 検証済み** — 実機の XDNA2 マシンで再現したもの:
  **Ryzen AI 9 HX PRO 370（Strix Point）· Radeon 890M · Ubuntu 26.04 · kernel 7.0
  · in-tree `amdxdna` · NPU FW 1.1.2.64**。
- **🔎 調査済み** — アップストリームのリポジトリ/ドキュメント/ベンチマーク（2026年8月）に
  基づくもので、リンクは本文中に併記。ここではまだ再現していない。

> **このリリースで実行可能な対応範囲は、製品群の概説より狭いです。**
> 実機検証と自動割り当てが済んでいるのは Strix Point `RyzenAI-npu4` / IREE
> `npu4` のみです。Strix Halo `npu5` と Krackan `npu6` は背景情報であり、
> 検証済みターゲットと CPU リファレンス結果が提供されるまで
> `scripts/detect-npu.sh` は拒否します。[SUPPORT.md](SUPPORT.md) を参照してください。

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
3 件見つかり（いずれもこのコミットで修正済み — 後述）、実際の状態は次の通りだった:

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
2. **有効化を阻むブロッカーは XDNA1 と 1 バイトも違わず同じ** — memlock のデフォルト
   8 MB が xrt-smi の 64 MB の `mmap(MAP_LOCKED)` を `EAGAIN` で壊す。まさに
   `scripts/enable-npu.sh` が書かれた理由となった失敗そのものだ — **しかし、従来の
   修正は systemd デスクトップでは黙って効かない。** limits.d は `pam_limits` の
   仕組みであり、GUI ターミナルは `user@<uid>.service` の子プロセスとして *その*
   8 MB の `LimitMEMLOCK` を代わりに継承する。しかも lingering が有効だと、
   再ログインしてもそのサービスは二度と再起動されない。`enable-npu.sh` は現在、
   UID 固有の `user@<uid>.service.d` drop-in を書き込み、過去に自身が管理した
   旧 wildcard drop-in と完全に一致する場合にのみそれを無効化し、呼び出し元の
   シェルに `prlimit` を適用する — 完全な解剖は
   [GOTCHAS #0](GOTCHAS.ja.md) にある。
3. **ファームウェアは最初から最新である**: FW 1.1.2.64 が
   `amdnpu/17f0_10/` からロードされる — FastFlowLM が要求する下限 ≥ 1.1.0.0 を上回っている。

### ✅ 最終状態: XDNA2 NPU が列挙される（同じマシン、同じ日）

memlock の修正が本当の意味で効いた後（drop-in + `prlimit`、落とし穴 #0）、
7 つのチェックすべてが緑になり、ユーザースペーススタックがデバイスを開く:

```
$ xrt-smi examine
XRT
  Version              : 2.21.75
  amdxdna Version      : 7.0.0-29-generic
  NPU Firmware Version : 1.1.2.64
Device(s) Present
|BDF             |Name          |
|[0000:66:00.1]  |RyzenAI-npu4  |

$ python3 -c 'import pyxrt; d = pyxrt.device(0); \
    print(d.get_info(pyxrt.xrt_info_device.name))'
RyzenAI-npu4
```

`RyzenAI-npu4` は、下の名前解読表の該当行を実機で裏付ける: XRT にとって Strix Point
は `npu4` である。*ここ* までたどり着くのにソースビルドは一切不要だった —
XDNA2/Ubuntu 26.04 での有効化はコンパイルではなく設定の問題だ。

## ✅ コンピュート: XDNA2 NPU 上で検証済み（同じマシン、2026-08-15）

**実機のライブ記録:** IREE `npu4` の CPU リファレンス完全一致、
`npu-runner` の全出力検証、XRT・HRX による 8 カラム IRON カーネルの実行:

![IREE、npu-runner、XRT、HRX による XDNA2 Strix Point 実機コンピュート検証](media/xdna2-compute.gif)

IRON トラックは有効化が完了したその日のうちに動いた — `setup-mlir-aie.sh` は
無改変、mlir-aie **1.4.1**（cp314 wheel）、Peano wheel、Ubuntu の `pyxrt`。
完全な表は [MLIR-AIE.ja.md](MLIR-AIE.ja.md) に。ハイライト:

- **全 8 カラム / 32 タイルでの GEMM**（`whole_array`、2048³）: i8 で **6.65 TOPS**、
  bfp16 経由の bf16 で **4.64 TFLOPS** — 内側タイルサイズだけで 3.4× の価値があった
  （32³ → 64³ タイル）。
- **AIE2P は bfp16 を欲しがる**: bf16 MAC は XDNA2 では約 ¼ レートの
  *エミュレーション*（XDNA1 ではネイティブ）。`--emulate-bf16-mmul-with-bfp16 1`
  はタダで手に入る速度だ。ネイティブ bfp16ebs8 設計はここでは Peano で
  コンパイルできる。実行には `libxrt-dev` が必要（C++ ホスト）。
- **`ml/mobilenet` — Phoenix の 4 カラムでは `CREATE_HWCTX` に失敗する設計 — が
  8 カラムのアレイでエンドツーエンドに動作する**: 推論あたり ~176 ms。
- LLM ブロックは `npu2` ですべてパスする: softmax、RoPE、SwiGLU、RMSNorm、
  matmul+activation エピローグ。
- IRON 1.4.x API に移植した我々のカスタム `relu(a+b)` カーネルは
  **8 カラムで 8.0×** にスケールする（`transform_parallel_binary`）。実効 11.2 GB/s。

### ✅ IREE: `npu4` での CPU 参照正しさ検証（別トラック）

upstream IREE の CPU-vs-NPU ハーネスも、この実機で
`--target_device=npu4`、コア 4 行×8 列、Peano 22 コミット `4a1adefa`
を用いて実行した。

| IREE matmul | 比較値数 | CPU 対 NPU の結果 |
|---|---:|---|
| bf16→f32, 64³ | 4,096 | 全数一致、最大絶対/相対誤差 0 |
| bf16→f32, 512³ | 262,144 | 全数一致、最大絶対/相対誤差 0 |
| i8→i32, 512³ | 262,144 | 不一致 0 |

これらは `iree-amd-aie` の bf16/i8 正しさ検証であり、ネイティブ
`mlir-aie` bfp16ebs8 経路とは別物である。別の Peano 21 累積スイープは
K=1216 でパスし、K=1280 で初めて失敗した。この IREE の表はその境界を
変更しない。また、これらの正しさ検証は **性能測定ではない**。

### XDNA1 のツールを XDNA2 に向けて見つかったスクリプトのバグ（修正済み）

- `check-npu.sh [1]` は `pipefail` の下で `lsmod | grep -q` を使っていた: `grep -q` は
  最初のマッチで終了し、`lsmod` は SIGPIPE で死に（exit 141）、パイプラインは「失敗」する —
  モジュールが `lsmod` 出力の先頭近くにあるときだけ発火する、レースを含んだ偽陰性だ
  （ブート直後の Strix マシンではまさにそうなる）。現在は `/sys/module/amdxdna` をチェックする。
- `check-npu.sh [2]` は XDNA1 の lspci 文字列である `IPU|AI` にマッチさせていた。XDNA2 は
  `Neural Processing Unit`（デバイス `17f0`）として列挙される。チェックは現在両方に
  マッチし、どちらの世代を見つけたかを報告する。
- `check-npu.sh [6]` には [1] と *同じ* SIGPIPE レースがあった — `pipefail` の下での
  `xrt-smi examine | grep -q` — ただしこちらは **NPU が実際に列挙されて初めて**
  発火の準備が整う（成功したレポートではマッチ対象の行が先頭近くにあるため、
  `xrt-smi` がまだ書き込んでいる最中に `grep -q` が抜けてしまう）。このチェックは
  史上初の列挙成功を失敗として報告し、その傍らで [7] の `pyxrt` は何食わぬ顔で
  デバイスを開いていた。現在は先に出力をキャプチャしてからマッチさせる。

## 🔎 名前の解読表（世代間の混乱ナンバーワン）

| レイヤ | XDNA1 | XDNA2 Strix Point | 出典 |
|---|---|---|---|
| lspci | `AMD IPU Device`（`1502`） | `Neural Processing Unit`（`17f0`） | ✅ 両マシンで確認 |
| XRT / xdna-driver | `RyzenAI-npu1` | `RyzenAI-npu4`（Halo=`npu5`、Krackan=`npu6`） | ✅ このマシンが `RyzenAI-npu4` と報告 · [xdna-driver](https://github.com/amd/xdna-driver) |
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
| `scripts/check-npu.sh` | ✅ 動作する（このコミット） | XDNA2 の PCI 文字列と世代の報告。[6] の成功側 SIGPIPE 修正。[5] は pam 対 systemd の memlock 分裂を診断するように |
| `scripts/enable-npu.sh` | ✅ 動作する（このコミットで拡張） | 同じ 3 つのブロッカー。Ubuntu 26.04 はパッケージをプリインストール済み — ただし systemd デスクトップでは、memlock の修正に limits.d に加えて UID 固有の `user@<uid>.service.d` drop-in が必要であり、スクリプトは自身の旧 wildcard ファイルと完全に一致する場合にのみそれを無効化する（[落とし穴 #0](GOTCHAS.ja.md)） |
| `scripts/build.sh`（iree-amd-aie） | ✅ 実機検証済み | Strix でソースビルド+インストール完了。並列度の制限で実際に発生した OOM を防ぎ、最終チェックで `npu1_4col` と `npu4` の両方を必須とする。Peano 22 `4a1adefa` でテスト |
| `scripts/run-matmul.sh` | ✅ 実機検証済み | 4×8 グリッドを検出して `npu4` を選択。XDNA1 経路を維持しつつ i32 128³ と bf16 512³ が正しくコンパイル・実行された |
| `tools/npu-runner` | ✅ 実機検証済み | C API のグリッド自動検出で4×8を解決。ネイティブ runner と ctypes/Python 経路の両方で i32 出力 16,384 値を全て検証 |
| `tools/npu-trim` | ✅ コンセプトは健在 | op カバレッジの最前線は動くが、アプローチは同一。これを置き換えるベンダー EP は Linux には依然として無い |
| `mlir-aie`（IRON）トラック | ✅ **検証済み — 最有力の道**（このコミット） | IRON [1.4.1](https://github.com/Xilinx/mlir-aie/releases): Strix はファーストクラス（`npu2`）、**Peano がデフォルト**、`aiecc` は C++ バイナリに、例は lit 駆動に。我々のスクリプト + カスタムカーネルは移植済み（アノテーション API の破壊 — [GOTCHAS](GOTCHAS.ja.md)）。数値は [MLIR-AIE.ja.md](MLIR-AIE.ja.md) に。以前の調査に対する訂正: mlir-aie 1.4.1 は **オプトインの HRX Python バックエンドを実際に同梱**しており、外部から提供する `libhrx` が必要である。このリポジトリの `relu_add` の単一 Worker 版と 8 カラム版は、ここで HRX ランタイムによるディスパッチと正しさ検証の PASS を実機確認した。ただしアーティファクトの生成には既存の XRT ツールチェーンを使ったため、ビルドから実行まで完全に XRT 不要だという主張ではない。 [amd/IRON](https://github.com/amd/IRON) は依然 **wheel を一切出荷していない**（ソースインストールのみ、mlir_aie 1.3.5.dev スナップショットにピン留め） |

## 🔎 カーネルを書くときに効いてくるハードウェアの差分

- **ジオメトリ**: npu1 は 4 カラムのアレイ。Strix Point（`npu4`）は **4 行 × 8
  カラム — コンピュートタイル 32 個 + メモリタイル 8 個** で、カラム境界で
  パーティション可能、コンテキストスケジューリングはファームウェア管理
  （[カーネルドキュメント](https://docs.kernel.org/accel/amdxdna/amdnpu.html)）。
- **データ型**: AIE2P の目玉は **bfp16 ブロック浮動小数点** — 8 個の値が 8 ビットの
  指数を共有し、8 値あたり 9 バイト。Peano の現行 nightly の時点で、これはオープン
  スタックの下で現実のものだ: clang は `__builtin_aie2p_*bfp16ebs8/16` 変換
  ビルトインと `BFP576_BFP576_ACC2048` MAC ビルトインを出荷しており、
  `ml/block_datatypes` の GEMM は Peano でビルドできる（✅ このマシンでコンパイル
  済み）。その裏返し: **bf16 MAC は後退した** — AIE2 ではネイティブの 4×8×4、
  AIE2P では bfp16 データパス経由の約 ¼ レートのエミュレーション
  （[mlir-aie#3390](https://github.com/Xilinx/mlir-aie/discussions/3390)、
  [Hello XDNA](https://tnzr.org/xdna/isa.html)）。npu1 の bf16 向けにチューニング
  されたカーネルは、npu2 でピークスループットを出すには bfp16 への書き直しが必要だ。
  カーネル C++ は `__AIEARCH__`（20 = AIE2、21 = AIE2P）でアーキテクチャ分岐され、
  アップストリームは `aie_kernels/aie2/` と `aie2p/` の並行ツリーを維持している。
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

1. ~~4×8 アレイ上で IRON の GEMM を再現する~~ — **✅ 完了**（mlir-aie 1.4.1、
   アレイ全体の GEMM が i8 で 6.65 TOPS / bf16-bfp16 で 4.64 TFLOPS、LLM ブロック、
   フル MobileNet。[MLIR-AIE.ja.md](MLIR-AIE.ja.md)）。GQA/MHA:
   [amd/IRON](https://github.com/amd/IRON) の op ライブラリはこれらを
   **aie2p 専用** で持つ（head-dim は 64 のみ）— しかしソースインストールのみで、
   mlir_aie 1.3.5.dev スナップショットにピン留めされており、量子化 op は
   *dequant*（Q4NX/AWQ → bf16）だけだ。wheel は無く、融合 W4A16 も無い。
2. ~~iree-amd-aie の matmul レシピと `npu-runner` を `npu4` に移植し、
   CPU 参照の正しさを確認~~ — **✅ 完了**。ビルド、世代自動検出 matmul
   スクリプト、常駐 C API runner、Python ラッパーはすべてこの Strix
   実機で動作し、upstream ハーネスで上記の全数一致を得た。統制した
   XDNA1-vs-XDNA2 性能比較は別の今後の作業であり、この正しさ検証から
   速度に関する主張は行わない。
3. **量子化 prefill GEMM** — コントリビューションの面であり、今や正確にマップ
   されている: [TileFuse](https://arxiv.org/abs/2606.11357) は W4A16 のレシピを
   *コードとともに* 公開した
   （[glassescrab/mlir-aie](https://github.com/glassescrab/mlir-aie/tree/feature/update-mix-mm-int4-verification)、
   main から約 13 か月遅れのフォークで、**chess ファースト**、Peano はオプション。
   AWQ group-128、k タイル = グループサイズ、L1 の weight-stationary キャッシュで
   タイル内に dequant を融合、Strix Point で 9 TOPS）。オープンな場所のどこにも
   **存在しない** もの: そのカーネルの **現行 IRON 1.4.x + Peano のみ** への移植、
   そして llama.cpp との統合のすべて。
   [#21725](https://github.com/ggml-org/llama.cpp/issues/21725) は依然オープンで
   未着手だ（作者の WIP は 2026-04 に停滞。AMD 自身の活発な取り組みは HSA/ROCr
   ランタイム上の
   [`ggml-hsa`](https://github.com/ypapadop-amd/ggml/tree/hsa-backend) —
   Ubuntu の XRT とは別のスタックである）。加えて、アップストリームで計測済みで
   盗む価値があるもの: #21725 で引用された IRON の実験では、**64 KB のバッファ
   アラインメント（SMMU ページ）が decode を 10× 変えるノブ** だった。
   **このマシンでスパイク確認済み（2026-08-15）**: TileFuse の融合
   dequant+GEMM カーネル（`mix_int4_ATB.cc`）は **mlir-aie 1.4.1 のヘッダに
   対して Peano の `aie2p` ターゲットでクリーンにコンパイルできる**
   （`-Dbf16_bf16_ONLY`、m64/k128/n64 → `matmul_bf16_bf16`）。これはこの
   特殊化についてフロントエンドのコンパイル障壁を 1 つ越えただけで、移植の
   完了では **ない**。IRON/ObjectFifo 統合、リンク、配置、ABI 整合、ホスト側の
   重みパッキング、NPU 実行、数値検証がすべて残っている。固定済みの
   [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) にソース
   コミット、チェックサム、正確なフロントエンドフラグを記録している。

*ステータス: このページは 2026-08-15 に追加。有効化、IRON コンピュート、
CPU 参照正しさを含む IREE `npu4` 移植を、同日上記の Strix Point 実機で
検証済み。🔎 の項目は出典を本文中に併記している。*
