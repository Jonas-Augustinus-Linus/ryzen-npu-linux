#!/usr/bin/env bash
# check-npu.sh — Diagnose whether an AMD Ryzen AI (XDNA) NPU is usable on Linux.
#
# Read-only. Safe to run anytime. Checks every layer that has to be green
# before you can run compute on the NPU: kernel driver -> device node ->
# permissions -> memlock -> XRT runtime -> Python binding.
#
# Usage: scripts/check-npu.sh [--strict]
#   --strict  return nonzero when any required readiness check fails
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0.
#            Ryzen AI 9 HX PRO 370 (Strix Point / XDNA2), Ubuntu 26.04, kernel 7.0.
set -uo pipefail

STRICT=0
[ "$#" -le 1 ] || { printf 'expected at most one option\n' >&2; exit 2; }
case "${1:-}" in
  "") ;;
  --strict) STRICT=1 ;;
  -h|--help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

FAILURES=0
CURRENT_USER="$(id -un)" || {
  printf 'could not resolve the current user\n' >&2
  exit 1
}
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[36mi\033[0m %s\n' "$1"; }

echo "== AMD NPU (XDNA) readiness check =="

echo "[1] Kernel driver (amdxdna)"
# NOTE: not `lsmod | grep -q` — under pipefail, grep -q exiting on first match
# SIGPIPEs lsmod (racy false negative when the module sits early in the list).
if [ -d /sys/module/amdxdna ]; then pass "amdxdna module loaded"; else fail "amdxdna NOT loaded (need kernel >= 6.14, or AMD out-of-tree xdna-driver)"; fi

echo "[2] PCI device"
# XDNA1 (Phoenix/Hawk Point) enumerates as "IPU"/"AI"; XDNA2 (Strix/Krackan)
# as "Neural Processing Unit".
NPU_PCI=$(lspci -nn 2>/dev/null | grep -iE 'Signal processing controller.*(IPU|Neural Processing Unit|\bAI\b)')
if [ -n "$NPU_PCI" ]; then
  pass "$NPU_PCI"
  case "$NPU_PCI" in
    *1502*) info "device 1502 = XDNA1 family; run scripts/detect-npu.sh. Phoenix has historical hardware evidence; Hawk Point and the current v1 pin still need hardware confirmation" ;;
    *17f0*) info "device 17f0 = XDNA2 family; exact support still depends on VBNV/geometry (run scripts/detect-npu.sh)" ;;
  esac
else info "NPU not obviously visible in lspci (not fatal)"; fi

echo "[3] Device node /dev/accel/accel0"
if [ -e /dev/accel/accel0 ]; then
  pass "$(stat -c '%n owner=%U group=%G mode=%A' /dev/accel/accel0)"
  if [ -r /dev/accel/accel0 ] && [ -w /dev/accel/accel0 ]; then pass "current user has RW access"
  else fail "no RW access — add yourself to the 'render' group: sudo usermod -aG render \$USER (then re-login)"; fi
else fail "/dev/accel/accel0 missing — driver did not bind / firmware not loaded"; fi

echo "[4] User groups"
case " $(id -nG) " in
  *" render "*) pass "in 'render' group" ;;
  *)
    if [ -r /dev/accel/accel0 ] && [ -w /dev/accel/accel0 ]; then
      info "not in 'render', but the current ACL/privileges already grant device RW access"
    else
      fail "NOT in 'render' group (sudo usermod -aG render \$USER, then re-login)"
    fi
    ;;
esac

echo "[5] memlock limit (verified compute allowance: 1 GiB; XRT alone maps 64 MiB locked)"
MEMLOCK_REQUIRED_KB=1048576
XRT_MINIMUM_KB=65536
ML=$(ulimit -l)
if [ "$ML" = "unlimited" ] \
    || [ "${ML:-0}" -ge "$MEMLOCK_REQUIRED_KB" ] 2>/dev/null; then
  pass "memlock = $ML KiB (meets the verified 1 GiB compute allowance)"
else
  fail "memlock = $ML KiB (below the verified 1048576 KiB compute allowance)"
  if [ "${ML:-0}" -ge "$XRT_MINIMUM_KB" ] 2>/dev/null; then
    info "this may let xrt-smi enumerate, but it is below the allowance validated by the quick compute contract"
  fi
  # Distinguish the two failure modes — see docs/GOTCHAS.md #0:
  #   never configured  vs  configured in limits.d but this process never saw it
  #   (GUI apps are children of user@<uid>.service; pam_limits does not apply there)
  LIMIT_FILES=(/etc/security/limits.conf)
  shopt -s nullglob
  LIMIT_FILES+=(/etc/security/limits.d/*.conf)
  shopt -u nullglob
  if awk -v user="$CURRENT_USER" -v required="$MEMLOCK_REQUIRED_KB" '
      /^[[:space:]]*#/ || NF < 4 { next }
      ($1 == user || $1 == "*") && $3 == "memlock" {
        sufficient = ($4 == "unlimited" || ($4 ~ /^[0-9]+$/ && $4 >= required))
        if ($2 == "soft" && sufficient) soft = 1
        if ($2 == "hard" && sufficient) hard = 1
        if ($2 == "-" && sufficient) soft = hard = 1
      }
      END { exit !(soft && hard) }
    ' "${LIMIT_FILES[@]}" 2>/dev/null; then
    MGR=$(systemctl show "user@$(id -u).service" -p LimitMEMLOCK --value 2>/dev/null)
    info "limits.d already grants at least 1 GiB — but this process did not inherit it:"
    info "it inherits from user@$(id -u).service (LimitMEMLOCK=${MGR:-unknown}), and pam_limits"
    info "only covers ssh/TTY logins, never apps spawned by the systemd user manager"
    if [ "$(loginctl show-user "$CURRENT_USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
      info "lingering is ON: logout does NOT restart user@$(id -u).service — re-login won't fix this, a reboot will"
    fi
    info "fix: re-run scripts/enable-npu.sh (adds the UID-specific user@.service drop-in) + reboot,"
    info "or unblock this very shell right now:  sudo prlimit --pid \$\$ --memlock=1073741824:1073741824"
  else
    info "fix: run scripts/enable-npu.sh (writes limits.d + the UID-specific user@.service drop-in), then reboot"
    info "or unblock this very shell right now:  sudo prlimit --pid \$\$ --memlock=1073741824:1073741824"
  fi
fi

echo "[6] XRT runtime (xrt-smi)"
if command -v xrt-smi >/dev/null; then
  pass "xrt-smi: $(command -v xrt-smi)"
  # NOTE: capture, then match — `xrt-smi examine | grep -q` under pipefail is
  # the same SIGPIPE race as [1]: grep -q exits at the first match, xrt-smi
  # dies of SIGPIPE (exit 141), and a *successful* enumeration reports as a
  # failure. The race only arms once the NPU actually enumerates (the matched
  # lines appear early in the output) — invisible until the machine works.
  if XRT_OUT=$(xrt-smi examine 2>/dev/null); then
    :
  else
    XRT_OUT=""
  fi
  case "$XRT_OUT" in
  *RyzenAI-npu*|*"NPU Firmware"*)
    pass "xrt-smi sees the NPU:"
    printf '%s\n' "$XRT_OUT" | grep -iE 'NPU Firmware|RyzenAI-npu|Device\(s\) Present' | sed 's/^/      /'
    ;;
  *)
    fail "xrt-smi installed but does not enumerate the NPU"
    ML=$(ulimit -l)
    if [ "$ML" != "unlimited" ] && [ "${ML:-0}" -lt "$XRT_MINIMUM_KB" ] 2>/dev/null; then
      info "likely cause: the low memlock from [5] — xrt-smi's 64MB mmap(MAP_LOCKED) fails with EAGAIN. Apply the fix printed in [5], retry."
    fi
    ;;
  esac
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
if [ "$FAILURES" -eq 0 ]; then
  echo "Readiness: PASS. The NPU is activated."
  echo "Build iree-amd-aie (scripts/build.sh), then run scripts/verify-stack.sh."
else
  echo "Readiness: FAIL ($FAILURES required check(s) failed)."
  echo "Apply the fixes above, then rerun this check."
  if [ "$STRICT" -eq 1 ]; then
    exit 1
  fi
fi
