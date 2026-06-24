//===- relu_add.cc ---------------------------------------------*- C++ -*-===//
//
// Custom AIE kernel (XDNA1 / aie2): fused residual-add + ReLU
//   out[i] = max(a[i] + b[i], 0)
//
// A single fused element-wise op (residual add + activation) that is NOT one of
// the stock mlir-aie programming_examples — written here to show the full
// author-your-own-kernel path on first-gen Ryzen AI.
//===----------------------------------------------------------------------===//
#include <stdint.h>

extern "C" {

// a, b: input tiles,  c: output tile,  N: elements per tile
void relu_add_i32(int32_t *a, int32_t *b, int32_t *c, int32_t N) {
  for (int i = 0; i < N; i++) {
    int32_t t = a[i] + b[i];
    c[i] = (t < 0) ? 0 : t;
  }
}

} // extern "C"
