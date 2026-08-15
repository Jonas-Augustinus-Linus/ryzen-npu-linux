// 128x128x128 i32 matmul for the verified XDNA1/XDNA2 paths.
// Compile, run, and compare every output with the CPU reference:
//   scripts/run-matmul.sh i32
// The script detects npu1_4col versus npu4 and selects the matching geometry.
func.func @matmul(%a: tensor<128x128xi32>, %b: tensor<128x128xi32>) -> tensor<128x128xi32> {
  %c0 = arith.constant 0 : i32
  %init = tensor.empty() : tensor<128x128xi32>
  %fill = linalg.fill ins(%c0 : i32) outs(%init : tensor<128x128xi32>) -> tensor<128x128xi32>
  %r = linalg.matmul ins(%a, %b : tensor<128x128xi32>, tensor<128x128xi32>)
                     outs(%fill : tensor<128x128xi32>) -> tensor<128x128xi32>
  return %r : tensor<128x128xi32>
}
