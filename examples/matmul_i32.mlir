// 128x128x128 i32 matmul for the XDNA1 NPU.
// Compile with the objectFifo pipeline (see scripts/run-matmul.sh):
//   iree-compile examples/matmul_i32.mlir \
//     --iree-hal-target-backends=amd-aie --iree-amdaie-target-device=npu1_4col \
//     --iree-amdaie-lower-to-aie-pipeline=objectFifo --iree-amdaie-tile-pipeline=pack-peel \
//     --iree-amd-aie-peano-install-dir=<llvm-aie> --iree-amd-aie-install-dir=<iree-install> \
//     --iree-amdaie-packet-flow-strategy=none --iree-amdaie-device-hal=amdxdna \
//     --iree-hal-memoization=false --iree-hal-indirect-command-buffers=false -o /tmp/mm.vmfb
// Run (note cols=4!):
//   iree-run-module --module=/tmp/mm.vmfb --device=amdxdna \
//     --amdxdna_n_core_rows=4 --amdxdna_n_core_cols=4 --function=matmul \
//     --input=128x128xi32=2 --input=128x128xi32=3      # -> all 768
func.func @matmul(%a: tensor<128x128xi32>, %b: tensor<128x128xi32>) -> tensor<128x128xi32> {
  %c0 = arith.constant 0 : i32
  %init = tensor.empty() : tensor<128x128xi32>
  %fill = linalg.fill ins(%c0 : i32) outs(%init : tensor<128x128xi32>) -> tensor<128x128xi32>
  %r = linalg.matmul ins(%a, %b : tensor<128x128xi32>, tensor<128x128xi32>)
                     outs(%fill : tensor<128x128xi32>) -> tensor<128x128xi32>
  return %r : tensor<128x128xi32>
}
