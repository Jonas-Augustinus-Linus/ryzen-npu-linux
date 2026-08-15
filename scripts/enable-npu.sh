#!/usr/bin/env bash
# enable-npu.sh — Activate an AMD Ryzen AI (XDNA) NPU for a normal user on Linux.
#
# The kernel side (amdxdna driver + /dev/accel/accel0 + firmware) usually works
# out of the box on kernel >= 6.14. What blocks a NON-root user are three things,
# all fixed here. Reboot once after running this (see the memlock note in step 3
# for why a plain re-login is not always enough).
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0.
#            Ryzen AI 9 HX PRO 370 (Strix Point / XDNA2), Ubuntu 26.04, kernel 7.0.
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
#    8 MB limit makes mmap(MAP_LOCKED) fail with EAGAIN (xrt-smi alone mmaps
#    64 MB just to enumerate). TWO mechanisms, because desktop Linux has two
#    separate limit paths:
#      a) pam_limits (limits.d) — covers ssh / TTY / anything entering via PAM.
#      b) systemd user manager  — covers GUI-launched apps (your terminal!).
#         On a systemd desktop those are children of user@<uid>.service and
#         NEVER see pam_limits; they inherit the manager's own LimitMEMLOCK
#         (default: the same 8 MB). Fixed with a service drop-in.
#    See docs/GOTCHAS.md #0 for the full story.
echo "[3/3] Setting memlock = unlimited (pam_limits + systemd user manager)"
LIMITS=/etc/security/limits.d/99-xrt-npu.conf
# NOTE: specify the username, not @render — pam_limits does not always apply
# limits to supplementary groups.
printf '%s soft memlock unlimited\n%s hard memlock unlimited\n' "$USER_NAME" "$USER_NAME" | sudo tee "$LIMITS" >/dev/null
echo "  wrote $LIMITS"
DROPIN=/etc/systemd/system/user@.service.d/99-xrt-npu-memlock.conf
sudo mkdir -p "${DROPIN%/*}"
printf '[Service]\nLimitMEMLOCK=infinity\n' | sudo tee "$DROPIN" >/dev/null
sudo systemctl daemon-reload
echo "  wrote $DROPIN"

# Bonus: unblock the shell that launched this script right now (children
# inherit rlimits), so the NPU works in THIS terminal before any reboot.
SHELL_PID=$PPID
if [ -n "${SUDO_USER:-}" ]; then
  # launched via sudo — the real shell is sudo's parent
  SHELL_PID=$(ps -o ppid= -p "$PPID" | tr -d ' ')
fi
if sudo prlimit --pid "$SHELL_PID" --memlock=unlimited:unlimited 2>/dev/null; then
  echo "  unblocked the current shell (PID $SHELL_PID) via prlimit — commands run"
  echo "  from it can use the NPU immediately"
fi

echo
echo "Done. >>> REBOOT once <<< to apply everywhere. Why not just re-login:"
echo " - ssh/TTY sessions: re-login is enough (pam path a)."
echo " - GUI apps read their limit from user@.service (path b) — and a logout does"
echo "   NOT restart that service when lingering is on"
echo "   (check: loginctl show-user \$USER -p Linger)."
echo " - This terminal is already unblocked; for any other ALREADY-RUNNING shell:"
echo "     sudo prlimit --pid \$\$ --memlock=unlimited:unlimited"
echo "Then run scripts/check-npu.sh to verify."
