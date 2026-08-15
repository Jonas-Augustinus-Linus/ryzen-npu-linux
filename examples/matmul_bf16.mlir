// 256x256x256 bf16 -> f32 matmul for the verified XDNA1/XDNA2 paths.
// Compile, run, and compare every output with the CPU reference:
//   scripts/run-matmul.sh bf16
// XDNA1 and npu4 use different lower/tile pipelines; the script selects them.
func.func @matmul(%a: tensor<256x256xbf16>, %b: tensor<256x256xbf16>) -> tensor<256x256xf32> {
  %c0 = arith.constant 0.0 : f32
  %init = tensor.empty() : tensor<256x256xf32>
  %fill = linalg.fill ins(%c0 : f32) outs(%init : tensor<256x256xf32>) -> tensor<256x256xf32>
  %r = linalg.matmul ins(%a, %b : tensor<256x256xbf16>, tensor<256x256xbf16>)
                     outs(%fill : tensor<256x256xf32>) -> tensor<256x256xf32>
  return %r : tensor<256x256xf32>
}
