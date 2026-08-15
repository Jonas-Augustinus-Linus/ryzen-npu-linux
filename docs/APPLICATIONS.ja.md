**[🇬🇧 English](APPLICATIONS.md) · [🇩🇪 Deutsch](APPLICATIONS.de.md) · [🇫🇷 Français](APPLICATIONS.fr.md) · [🇰🇷 한국어](APPLICATIONS.ko.md) · [🇯🇵 日本語](APPLICATIONS.ja.md)**

# Linux 上の XDNA1 NPU で何を作れるか

これは Ryzen 7 7840U など、Phoenix 世代のラップトップを所有する人のための
実践的な地図です。あらゆるモデルがターンキーで動くと装うことが目的ではありません。
すでに人々のマシンに入っているシリコンをオープンな Linux ラボに変え、役に立つ
一段を実行し、全出力を信頼できる CPU 結果と比較し、CPU と iGPU と組み合わせ、
次の人が続けられるだけの証拠を公開することが目的です。

このリポジトリで作成されたものはすべて MIT ライセンスです。**ライセンス条件に
従えば、誰でも利用、複製、変更、フォーク、公開、再配布できます。** ミッションは
[Open NPU Lab](OPEN-NPU-LAB.md)、一次資料とその先の研究経路は
[Research branches](RESEARCH.md) を参照してください。

## 機能より先に証拠ラベルを読む

- **リポジトリ実機:** このリポジトリが指定 NPU で実行し、全結果を検査したもの。
  現行 lock の証拠は Strix Point `npu4` にあり、Phoenix には重要な過去の実機結果が
  ありますが、現行 lock での再実行はまだ必要です。
- **upstream 実機:** upstream プロジェクトが実機で実行したもの。再現すべき経路で
  あって、このリポジトリが自動的に取得する結果ではありません。
- **テンプレート / 配管:** NPU dispatch や Linux I/O は実物ですが、学習済み製品では
  なく、合成重みや例示演算を使います。
- **compile-only / プロジェクト:** 実機実行と数値正当性の gate は未通過です。

コンパイルは実行ではなく、実行は正しさではなく、kernel timing はアプリの結果では
ありません。このリポジトリはまだ NPU のエネルギーを測っていないため、電池寿命の
改善を主張しません。

## オープンなソフトウェア経路は一つではない

このページの旧版にあった狭い operator ceiling は、**リポジトリが commit
`fddfec1b` に固定した `iree-amd-aie` backend** に関するもので、XDNA1
エコシステム全体の上限ではありません。[^iree-amd-aie]

| 経路 | 証拠が示すもの | 境界 |
|---|---|---|
| この repo 固定の `iree-amd-aie` | 慎重に整形した bf16/i8/i32 matmul、persistent dispatch、hybrid 例を検証済み。conv 経路は狭く target 依存。 | 現行 exact lock の実機証拠は `npu4`。公開済み 7840U 結果は以前の動作 snapshot による。未対応の imported graph 領域が暗黙に CPU fallback することはない。 |
| この repo 固定の `mlir-aie` 1.4.1 経路 | 直接 IRON kernel と upstream 例が repo の Strix Point で実行済み。配置とデータ移動を制御する作者向けの低水準経路。 | この exact 経路は repo の XDNA1 実機ではまだ再実行していない。 |
| 進行中の [`amd/IRON`](https://github.com/amd/IRON) | exact commit `cdc48e93` で、2026-08-15 の AMD Phoenix hardware workflow は既定の 5 iteration により **2,105 passing / 45 skipped case-run**、すなわち **421 distinct passing configuration / 9 distinct skip** を報告した。通過した AIE2 coverage には bf16 GEMM/GEMV、Q4NX dequant、softmax、RoPE、RMSNorm、LayerNorm、activation、transpose、SwiGLU decode/prefill variant が含まれる。[^iron-phoenix] | 強力な **upstream Phoenix 証拠**だが、repo exact-v1 の XDNA1 再実行でも完全な LLM でもない。9 distinct skip は MHA 3、streaming-SwiGLU-prefill 3、GEMV+GELU 3 configuration で、各 5 回反復され三つの 15 case-run group になる。MHA/GQA dashboard は AIE2P-only のまま。 |

重要な訂正は単純です。「この固定 backend がある op を lower できない」は、
**「XDNA1 がその種類の kernel を実行できない」ことを意味しません。** 各主張に付く
正確な toolchain、device、test、数値 oracle を追ってください。

## ONNX: import、extract、そして構成はアプリが担う

現在の [`scripts/build.sh`](../scripts/build.sh) は別途固定した
`iree-import-onnx` をインストールします。リポジトリの workflow に IREE の再 build や
Python bindings 経由の迂回は不要です。[`tools/npu-trim`](../tools/npu-trim/) は graph を
import または検査し、独立した matmul/conv shape を見つけ、clean kernel を出力し、
検出 target ごとに test-compile できます。

意図的に任意のモデル全体を再構築・実行するものではありません。重み、padding/layout
変換、未対応 op、CPU fallback、orchestration はアプリケーションが所有します。
[`examples/onnx-mlp`](../examples/onnx-mlp/) が実行可能な契約です。NPU matmul →
CPU ReLU → NPU matmul を bf16 CPU oracle と照合します。

```text
ONNX ── 固定 importer ──▶ npu-trim ──▶ target 名付き matmul/conv VMFB
                                           │
                     アプリ所有の重み、layout、スケジューリング
                                           │
                        NPU kernel + 明示的な CPU glue/fallback
```

## ローカル LLM システムは三つの processor を使える

NPU が LLM 全体を serve しなくても、NPU の仕事には価値があります。

```text
マイク / カメラ / 文書 / UI event
                    │
                    ▼
      NPU: always-on trigger、feature block、
           linear/fused block、分類または scoring
                    │
                    ▼
      CPU: I/O、tokenize、top-k、tool、policy、
           未対応 op と信頼できる fallback
                    │
                    ▼
      iGPU: prefill と token generation を担う
            実績ある量子化 local-LLM runtime
```

オープンな attention、normalization、quantization kernel が成熟すれば、計測済み block を
アプリ全体を捨てずに CPU/iGPU から NPU へ移せます。これが願望ではなく研究経路である
ことを二つの公開結果が示しています。

- Rösti と Franz は **GPT-2 124M fine-tuning** の GEMM を第一世代 Phoenix NPU に
  配置し、残りを CPU に残しました。彼らの環境では、offload した行列積が **2.8× 超**、
  end-to-end throughput が電源接続時 **1.7×**、battery 時 **1.2×**、battery の energy
  efficiency が **1.4×** と報告されています。[^phoenix-gpt2] 著者の数値であり、repo の
  測定値ではありません。
- STEEL は引用した従来 XDNA1 attention baseline DATO に対し、平均 **9.6× の XDNA1
  latency speedup** を報告しています。これとは別に HX 370/XDNA2 では、各 CPU/GPU
  baseline に対して **9.17× / 1.75×** 少ない energy、layer-by-layer XDNA2 実装に
  対して **22.8×** を報告しています。[^steel] XDNA1 latency と XDNA2 energy の実験を
  混同しないでください。

## 実行し、置き換え、拡張できるもの

| 出発点 | 現時点で実物である部分 | 有用な次の一歩 |
|---|---|---|
| [`local-rag-sidecar`](../examples/local-rag-sidecar/) | **repo 実機 (`npu4`):** 決定的 CPU hashing → persistent NPU 256×256 bf16 score matrix → CPU top-k → 任意の LLM endpoint。既定では literal loopback host の `127.0.0.1` または `::1` のみに制限され、remote endpoint には明示的な `--allow-remote` opt-in が必要。65,536 出力すべてを検査。 | hashing をライセンス明記の学習済み embedding や projection に置換し、query を batch 化し、XDNA1 で再実行する。小さな query 一件なら CPU dot product の方が速い可能性が高い。この例は統合と正しさを証明し、万能な高速化を主張しない。 |
| [`wake-word`](../examples/wake-word/) | **テンプレート:** 本物の CPU log-mel と三つの persistent NPU dense dispatch。付属重みは例示 matched filter。 | 本物の wake-word/intent 重みを学習・ライセンスし、実音声と false accept を評価して、iGPU/CPU のローカル assistant を起動する。 |
| [`onnx-mlp`](../examples/onnx-mlp/) | **テンプレート:** 実際に import した二つの matmul の hybrid forward pass。dispatch ごと、および end-to-end の CPU check がある。 | 学習済み intent、routing、safety、projection head に置換し、shape 固有 kernel と oracle を維持する。 |
| [`npu-camera`](../examples/npu-camera/) | **アプリ配管:** GStreamer → persistent NPU → `v4l2loopback`。NPU demo 演算は two-pass box blur であり segmentation ではない。 | 一段を学習済み対応 vision block に置換し、resize、composite、fallback は CPU に保つ。 |
| [`npu-runner`](../tools/npu-runner/) | **repo 実機:** VMFB を一度 load して C/Python から反復 invoke し、全出力を検査。 | batch scoring、sensor 分類、再利用可能 model sidecar の local daemon を作る。 |
| [`mlir-aie/relu_add`](../examples/mlir-aie/relu_add/) | **direct-kernel laboratory:** 検査可能な spatial code と multi-column 実行。 | AMD IRON AIE2 op 一つを Phoenix で再現し、配置、transfer、CPU golden、最初の失敗 shape を公開する。 |
| [`check-w4a16-compile.sh`](../scripts/check-w4a16-compile.sh) | **compile-only:** 固定済み外部 W4A16 front-end probe。 | 性能を主張する前に lowering、link、weight packing、NPU 実行、量子化を考慮した正しさを完成させる。 |

## ほかのアプリケーション方向

| 人の需要 | NPU サイズの実験 | 明示的に別へ残す部分 |
|---|---|---|
| private local assistant | wake word、intent/safety head、batch retrieval scoring | CPU orchestration、CPU/iGPU generation |
| 個人検索 | projection と query×document score matrix | parse、保存、top-k、最終 generation |
| accessibility | 音響、presence、gesture、UI-event classifier | capture と application policy |
| camera/privacy | 対応 conv または linear stage | capture、resize、composite、`v4l2loopback` |
| audio | batch conv/linear feature または denoise block | PipeWire、STFT、hard real-time fallback |
| game | voice、intent、offline content 用 native Linux companion | Proton game/render loop と frame-critical 処理 |
| compiler research | fusion、tiling、packet flow、量子化 kernel | CPU reference と再現可能 harness |

否定的な境界も事実として重要です。FPS 向上、frame generation、render loop 内 upscaling を
提供する経路はここにはなく、Proton 下では独立した native Linux companion が実践的な
実験境界です。従来型 GRU/LSTM workload は独自 lowering が必要か、CPU に残すべきです。
任意の transformer/Whisper/vision graph は repo 固定 backend にモデル全体を置くだけでは
動きません。これらは調査すべき interface であり、device を放置する理由ではありません。

## 再現可能な実験の段階

まず厳格な device と correctness check から始めます。

```bash
./scripts/check-npu.sh --strict
./scripts/run-matmul.sh bf16 512 512 512
```

次に既存の application seam を一つ選びます。

```bash
./examples/local-rag-sidecar/run.sh --cpu-only --selftest
./examples/local-rag-sidecar/run.sh --selftest       # 対応する実 NPU
~/src/iree-aie-venv/bin/python tools/npu-trim/npu_trim.py model.onnx
```

拡張ごとに device identity、exact commit/lock、model/data license、shape と precision、
全出力 tolerance、raw log、latency、そして実測後に限り system energy を公開します。
CPU fallback を残してください。再現入力を伴う最小失敗例も有用なオープン研究です。

## 次に読むもの

- ミッション、証拠契約、貢献の段階:
  [Open NPU Lab](OPEN-NPU-LAB.md)
- 一次論文、upstream code、次の研究課題:
  [Research branches](RESEARCH.md)
- 世代別 target と現在の XDNA2 証拠:
  [XDNA2 guide](XDNA2.ja.md)
- transformer の長期 milestone:
  [LLM roadmap](LLM-ROADMAP.md)

目標は一つの公認 demo ではありません。一般の所有者、学習者、研究者が NPU を忘れず
再利用できる、多くの検査可能な実験です。source を持ち帰って変更し、あなたの結果を
次の誰かの出発点にしてください。

## 一次資料

[^iree-amd-aie]: nod.ai/AMD, [`iree-amd-aie`](https://github.com/nod-ai/iree-amd-aie)。repo lock は `fddfec1be6ceefbdb890079d957947dfa1fe0848`。この節はこの backend を記述し、全 XDNA compiler 経路の上限を述べるものではない。
[^iron-phoenix]: AMD, [`IRON` commit `cdc48e93`](https://github.com/amd/IRON/tree/cdc48e93fd2c8776105780790c46ba4bca1bc40e) および [Phoenix extensive hardware workflow 31876069460](https://github.com/amd/IRON/actions/runs/31876069460)、2026-08-15。workflow 既定の 5 iteration では 2,105 passing / 45 skipped case-run が 421 distinct passing configuration / 9 distinct skip に対応する。upstream CI は動くため、再現時は commit を固定すること。
[^phoenix-gpt2]: A. Rösti、M. Franz, [“Unlocking the AMD Neural Processing Unit for ML Training on the Client Using Bare-Metal-Programming Tools”](https://arxiv.org/abs/2504.03083), FCCM 2025。第一世代 Phoenix、Ryzen 9 7940HS、hybrid GPT-2 124M fine-tuning。
[^steel]: V. J. B. Jung et al., [“STEEL: Sparsity-Aware Fused Attention for Energy-Efficient Long-Sequence Inference on AMD's XDNA NPU”](https://arxiv.org/abs/2607.09385), IEEE COINS 2026。論文は open-source implementation 経路として [`amd/IRON`](https://github.com/amd/IRON) を示す。
