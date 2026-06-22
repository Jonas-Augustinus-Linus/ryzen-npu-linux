// 256x256x256 bf16 -> f32 matmul for the XDNA1 NPU (bf16 inputs, f32 accumulate).
// bf16 uses the 'air' lower-to-aie pipeline (not objectFifo):
//   iree-compile examples/matmul_bf16.mlir \
//     --iree-hal-target-backends=amd-aie --iree-amdaie-target-device=npu1_4col \
//     --iree-amdaie-lower-to-aie-pipeline=air --iree-amdaie-tile-pipeline=pack-peel \
//     --iree-amd-aie-peano-install-dir=<llvm-aie> --iree-amd-aie-install-dir=<iree-install> \
//     --iree-amdaie-packet-flow-strategy=none --iree-amdaie-device-hal=amdxdna \
//     --iree-hal-memoization=false --iree-hal-indirect-command-buffers=false -o /tmp/mm.vmfb
// Run (cols=4!):
//   iree-run-module --module=/tmp/mm.vmfb --device=amdxdna \
//     --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4 --function=matmul \
//     --input=256x256xbf16=2 --input=256x256xbf16=3    # -> all 1536.0
//   (fractional works too: 1.5 x 0.5 -> 192.0)
func.func @matmul(%a: tensor<256x256xbf16>, %b: tensor<256x256xbf16>) -> tensor<256x256xf32> {
  %c0 = arith.constant 0.0 : f32
  %init = tensor.empty() : tensor<256x256xf32>
  %fill = linalg.fill ins(%c0 : f32) outs(%init : tensor<256x256xf32>) -> tensor<256x256xf32>
  %r = linalg.matmul ins(%a, %b : tensor<256x256xbf16>, tensor<256x256xbf16>)
                     outs(%fill : tensor<256x256xf32>) -> tensor<256x256xf32>
  return %r : tensor<256x256xf32>
}
