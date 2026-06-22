**[🇬🇧 English](BACKGROUND.md) · [🇩🇪 Deutsch](BACKGROUND.de.md) · [🇫🇷 Français](BACKGROUND.fr.md) · [🇰🇷 한국어](BACKGROUND.ko.md) · [🇯🇵 日本語](BACKGROUND.ja.md)**

# 背景: XDNA1、XDNA2、そして第1世代で Linux が難しい理由

## チップについて

AMD の Ryzen AI NPU は、Xilinx から受け継いだ **AI Engine (AIE)** 空間アレイです。
VLIW ベクタタイルをストリーミング/DMA インターコネクトで接続したグリッドに加え、ホストへ橋渡しする
メモリ行と "shim" 行を備えています。プログラミングは、CUDA スタイルのカーネルではなく、
タイル上に演算を配置し、タイル間でデータをルーティングする (データフロー) ことで行います。

ここで重要なのは2つの世代です:

| | **XDNA1** ("Phoenix"/"Hawk Point") | **XDNA2** ("Strix" など) |
|---|---|---|
| 搭載モデル | Ryzen 7040 / 8040 (例: **7840U**) | Ryzen AI 300 シリーズ |
| タイルアーキ | AIE2 (`aie2`) | AIE2P |
| Phoenix ジオメトリ | 4 コア行 × **4 使用可能列** (生では5)、`npu1_4col` | より大きい、`npu4` |
| PCI ID | `1022:1502` | `1022:17f0` |
| ~性能 | ~10 TOPS | ~50 TOPS |

## Linux ソフトウェアの状況 (2026年央)

**カーネル**側は解決済みです: `amdxdna` DRM accel ドライバは **Linux 6.14** で
アップストリームに取り込まれました (ファームウェアも同様)。最新のカーネルでは NPU は
`/dev/accel/accel0` として列挙され、`xrt-smi` がそれを認識します — **両方**の世代でです。

XDNA1 がつまずくのは **ユーザースペース / コンパイラ**側です:

- **AMD Ryzen AI Software for Linux** (1.7.x) — **STX/KRK (XDNA2) のみ**をサポート。
- **ONNX Runtime + Vitis AI EP** — Linux x86_64 ではクライアント NPU のグラフコンパイラ
  が同梱されておらず、演算は CPU にフォールバックします。
- **Lemonade / FastFlowLM** ("NPU LLMs on Linux" プロジェクト群) — **XDNA2 のみ**。
  7000/8000 シリーズの XDNA1 は非サポートだと明言しています。

つまり Linux 上の XDNA1 は、ターンキースタックからは **ドライバからは見えるがアプリケーションからは
見放された** 状態です。例外 — XDNA1 (`npu1`、4×5) を *明示的に* ターゲットとする、
唯一の積極的に開発されているオープンな経路 — が **`nod-ai/iree-amd-aie`** という IREE プラグインです。
研究グレード (任意のモデルではなくカーネル) ですが、ハードウェア上で本当に動作します。
これがこのリポジトリでビルドするものです。

## `amdxdna` HAL がデバイスに到達する仕組み

`iree-amd-aie` はあなたの matmul を次のようにコンパイルします:

1. **AIE コアコード** — Peano (`llvm-aie`、`aie2` ターゲットを持つ LLVM のフォーク)
   がタイルごとのプログラム (`core_<col>_<row>.elf`) をコンパイルします。
2. **設定 / 制御** — object-FIFO または AIR データフローの lowering、パケット
   ルーティング、および制御プログラムを、(`bootgen` 経由で) `.vmfb` にパックします。

実行時には **`amdxdna` HAL** (`-DIREE_EXTERNAL_HAL_DRIVERS=amdxdna` でランタイムに
組み込まれる) が **`/dev/accel/accel0` を直接オープンし**、vendored UAPI ヘッダを使って
DRM ioctl (`DRM_IOCTL_AMDXDNA_GET_INFO`、コマンド投入、フェンス待機) を発行します。
これは外部の XRT `xrt_coreutil` ライブラリとはリンク**しません** — そちらは別個の実験的な
`xrt` HAL です。だからこそ、in-tree の `amdxdna.ko` が存在する場合に AMD の out-of-tree な
`xdna-driver` をビルドする必要が **ない** のです。

デバイスは同じ ioctl を通じて自身のジオメトリを報告します。`npu1_4col` と
`--amdxdna_n_core_cols=4` はそれと一致していなければなりません ([GOTCHAS #6](GOTCHAS.ja.md) を参照)。

## 参考資料

- AMD `xdna-driver` & カーネル `amdxdna` ドキュメント (kernel.org `accel/amdxdna`)
- `nod-ai/iree-amd-aie` (README、`build_tools/ci/`)
- `Xilinx/llvm-aie` (Peano)
- IREE (`iree.dev`)
