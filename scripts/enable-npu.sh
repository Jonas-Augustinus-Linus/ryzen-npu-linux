#!/usr/bin/env bash
# enable-npu.sh — Activate an AMD Ryzen AI (XDNA) NPU for a normal user on Linux.
#
# The kernel side (amdxdna driver + /dev/accel/accel0 + firmware) usually works
# out of the box on kernel >= 6.14. What blocks a NON-root user are three things,
# all fixed here. Re-login (or reboot) once after running this.
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0.
# Idempotent. Uses sudo.
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
echo "== Enabling NPU for user: $USER_NAME =="

# 1) XRT userspace runtime (provides xrt-smi + pyxrt + the amdxdna shim libs).
echo "[1/3] Installing XRT runtime packages"
sudo apt-get update -qq
sudo apt-get install -y libxrt-utils-npu python3-xrt || {
  echo "  (package names vary by distro; on Ubuntu 26.04 these pull libxrt2/libxrt-npu2/libxrt-utils)"; }

# 2) render group — /dev/accel/accel0 is root:render 0660.
echo "[2/3] Adding $USER_NAME to 'render' group"
sudo usermod -aG render "$USER_NAME"

# 3) memlock unlimited — the NPU pins (mlock) large DMA buffers; the default
#    8 MB limit makes mmap(MAP_LOCKED) fail with EAGAIN.
echo "[3/3] Setting memlock = unlimited"
LIMITS=/etc/security/limits.d/99-xrt-npu.conf
# NOTE: specify the username, not @render — pam_limits does not always apply
# limits to supplementary groups.
printf '%s soft memlock unlimited\n%s hard memlock unlimited\n' "$USER_NAME" "$USER_NAME" | sudo tee "$LIMITS" >/dev/null
echo "  wrote $LIMITS"

echo
echo "Done. >>> LOG OUT and LOG BACK IN (or reboot) <<< for the group and memlock"
echo "changes to take effect, then run scripts/check-npu.sh to verify."
