#!/usr/bin/env bash
# check-npu.sh — Diagnose whether an AMD Ryzen AI (XDNA) NPU is usable on Linux.
#
# Read-only. Safe to run anytime. Checks every layer that has to be green
# before you can run compute on the NPU: kernel driver -> device node ->
# permissions -> memlock -> XRT runtime -> Python binding.
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0.
set -uo pipefail

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[36mi\033[0m %s\n' "$1"; }

echo "== AMD NPU (XDNA) readiness check =="

echo "[1] Kernel driver (amdxdna)"
if lsmod | grep -q '^amdxdna'; then pass "amdxdna module loaded"; else fail "amdxdna NOT loaded (need kernel >= 6.14, or AMD out-of-tree xdna-driver)"; fi

echo "[2] PCI device"
if lspci 2>/dev/null | grep -qiE 'Signal processing controller.*(IPU|AI)'; then
  pass "$(lspci 2>/dev/null | grep -iE 'Signal processing controller.*(IPU|AI)')"
else info "IPU not obviously visible in lspci (not fatal)"; fi

echo "[3] Device node /dev/accel/accel0"
if [ -e /dev/accel/accel0 ]; then
  pass "$(stat -c '%n owner=%U group=%G mode=%A' /dev/accel/accel0)"
  if [ -r /dev/accel/accel0 ] && [ -w /dev/accel/accel0 ]; then pass "current user has RW access"
  else fail "no RW access — add yourself to the 'render' group: sudo usermod -aG render \$USER (then re-login)"; fi
else fail "/dev/accel/accel0 missing — driver did not bind / firmware not loaded"; fi

echo "[4] User groups"
if id -nG | tr ' ' '\n' | grep -qx render; then pass "in 'render' group"; else fail "NOT in 'render' group (sudo usermod -aG render \$USER, then re-login)"; fi

echo "[5] memlock limit (NPU pins buffers)"
ML=$(ulimit -l)
if [ "$ML" = "unlimited" ] || [ "${ML:-0}" -ge 65536 ] 2>/dev/null; then pass "memlock = $ML"
else fail "memlock = $ML KB (too low). Set 'unlimited' in /etc/security/limits.d/*.conf, re-login"; fi

echo "[6] XRT runtime (xrt-smi)"
if command -v xrt-smi >/dev/null; then
  pass "xrt-smi: $(command -v xrt-smi)"
  if xrt-smi examine 2>/dev/null | grep -qiE 'RyzenAI-npu|NPU Firmware'; then
    pass "xrt-smi sees the NPU:"; xrt-smi examine 2>/dev/null | grep -iE 'NPU Firmware|RyzenAI-npu|Device\(s\) Present' | sed 's/^/      /'
  else fail "xrt-smi installed but does not enumerate the NPU"; fi
else fail "xrt-smi missing — install: sudo apt install libxrt-utils-npu python3-xrt"; fi

echo "[7] Python binding (pyxrt)"
if python3 -c 'import pyxrt' 2>/dev/null; then
  python3 - <<'PY' 2>/dev/null && pass "pyxrt opened device 0" || fail "pyxrt present but could not open device"
import pyxrt; d = pyxrt.device(0)
print("      BDF :", d.get_info(pyxrt.xrt_info_device.bdf))
print("      Name:", d.get_info(pyxrt.xrt_info_device.name))
PY
else info "pyxrt not importable in this python (only needed for python tooling, not for iree CLI runs)"; fi

echo
echo "If [1]-[6] are green, the NPU is activated. To actually RUN compute on it,"
echo "build iree-amd-aie (scripts/build.sh) and use scripts/run-matmul.sh."
