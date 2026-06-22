// One dense (fully-connected / Linear) layer for the XDNA1 NPU:  out = A @ W
//
// This is the ONLY thing that runs on the NPU in this example — a plain
// 128x128x128 i32 matmul, the verified-working primitive (objectFifo pipeline).
// The wake-word MLP is just three of these dispatches with ReLU + requant done
// on the CPU in between (see wake_word.py). We use i32 (not bf16) because:
//   * i32 matmul compiles & runs on npu1 at 128x128x128 (bf16 'air' needs >=256),
//   * int32 is a native numpy dtype, so .npy I/O with iree-run-module is trivial.
//
// Why ReLU isn't here: fusing matmul+ReLU into one NPU dispatch currently fails
// in the AIE backend (BD-id allocation), so the elementwise stays on the CPU.
func.func @dense(%a: tensor<128x128xi32>, %w: tensor<128x128xi32>) -> tensor<128x128xi32> {
  %z = arith.constant 0 : i32
  %init = tensor.empty() : tensor<128x128xi32>
  %fill = linalg.fill ins(%z : i32) outs(%init : tensor<128x128xi32>) -> tensor<128x128xi32>
  %out = linalg.matmul ins(%a, %w : tensor<128x128xi32>, tensor<128x128xi32>)
                       outs(%fill : tensor<128x128xi32>) -> tensor<128x128xi32>
  return %out : tensor<128x128xi32>
}
