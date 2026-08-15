#!/usr/bin/env bash
# enable-npu.sh — Activate an AMD Ryzen AI (XDNA) NPU for one normal user.
#
# The kernel side (amdxdna driver + /dev/accel/accel0 + firmware) usually works
# out of the box on kernel >= 6.14. This installs the XRT userspace packages,
# grants render-group access, and gives only the selected user's systemd manager
# a finite memlock allowance. Reboot once after changing the configuration.
#
# Tested on: Ryzen 7 PRO 7840U (Phoenix / XDNA1), Ubuntu 26.04, kernel 7.0.
#            Ryzen AI 9 HX PRO 370 (Strix Point / XDNA2), Ubuntu 26.04, kernel 7.0.
# Idempotent. Uses sudo when not already root.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/enable-npu.sh [--uninstall]

Configure one normal user (the caller, or SUDO_USER) for NPU access.

Environment:
  TARGET_USER=name  Explicit target when invoked directly by root.
  MEMLOCK_KB=N      Finite per-user allowance in KiB (default: 1048576 = 1 GiB;
                    accepted range: 65536..16777216).

--uninstall removes only this script's per-user memlock files. It intentionally
keeps installed packages and render-group membership, and never overwrites or
removes administrator-owned files.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

UNINSTALL=0
case "${1:-}" in
  "") ;;
  --uninstall|--rollback) UNINSTALL=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

if [ -n "${TARGET_USER:-}" ]; then
  USER_NAME="$TARGET_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  USER_NAME="$SUDO_USER"
else
  USER_NAME="$(id -un)"
fi
id "$USER_NAME" >/dev/null 2>&1 || die "target user does not exist: $USER_NAME"
USER_UID="$(id -u "$USER_NAME")"
[[ "$USER_UID" =~ ^[0-9]+$ ]] || die "could not resolve numeric UID for $USER_NAME"
[ "$USER_UID" -ne 0 ] \
  || die "refusing to configure root; set TARGET_USER to the normal desktop user"

if [ "$(id -u)" -eq 0 ]; then
  AS_ROOT=()
else
  command -v sudo >/dev/null || die "sudo is required"
  AS_ROOT=(sudo)
fi

MEMLOCK_KB="${MEMLOCK_KB:-1048576}"
if ! [[ "$MEMLOCK_KB" =~ ^[0-9]+$ ]] \
    || [ "$MEMLOCK_KB" -lt 65536 ] \
    || [ "$MEMLOCK_KB" -gt 16777216 ]; then
  die "MEMLOCK_KB must be an integer from 65536 (64 MiB) to 16777216 (16 GiB)"
fi
MEMLOCK_BYTES=$((MEMLOCK_KB * 1024))

MANAGED_MARKER="# Managed by ryzen-npu-linux scripts/enable-npu.sh"
LIMITS="/etc/security/limits.d/99-xrt-npu-${USER_UID}.conf"
DROPIN="/etc/systemd/system/user@${USER_UID}.service.d/99-xrt-npu-memlock.conf"
LEGACY_LIMITS="/etc/security/limits.d/99-xrt-npu.conf"
LEGACY_DROPIN="/etc/systemd/system/user@.service.d/99-xrt-npu-memlock.conf"
LEGACY_LIMITS_BACKUP="${LEGACY_LIMITS}.legacy-unlimited.disabled"
LEGACY_DROPIN_BACKUP="${LEGACY_DROPIN}.legacy-unlimited.disabled"

WORK="$(mktemp -d)"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
printf '%s\n# user=%s uid=%s\n%s soft memlock %s\n%s hard memlock %s\n' \
  "$MANAGED_MARKER" "$USER_NAME" "$USER_UID" \
  "$USER_NAME" "$MEMLOCK_KB" "$USER_NAME" "$MEMLOCK_KB" >"$WORK/limits"
printf '%s\n# user=%s uid=%s; bytes=%s\n[Service]\nLimitMEMLOCK=%s\n' \
  "$MANAGED_MARKER" "$USER_NAME" "$USER_UID" "$MEMLOCK_BYTES" \
  "$MEMLOCK_BYTES" >"$WORK/dropin"
printf '%s soft memlock unlimited\n%s hard memlock unlimited\n' \
  "$USER_NAME" "$USER_NAME" >"$WORK/legacy-limits"
printf '[Service]\nLimitMEMLOCK=infinity\n' >"$WORK/legacy-dropin"

require_managed_or_absent() {
  local path="$1"
  if "${AS_ROOT[@]}" test -e "$path" \
      && ! "${AS_ROOT[@]}" grep -Fqx "$MANAGED_MARKER" "$path"; then
    die "$path already exists but is not managed by this script; refusing to overwrite it"
  fi
}

preflight_legacy() {
  local path="$1" expected="$2" backup="$3"
  if "${AS_ROOT[@]}" test -e "$path"; then
    "${AS_ROOT[@]}" cmp -s "$path" "$expected" \
      || die "legacy file $path has administrator changes; remove its unlimited setting manually before continuing"
    ! "${AS_ROOT[@]}" test -e "$backup" \
      || die "cannot disable $path safely because backup already exists: $backup"
  fi
}

disable_legacy() {
  local path="$1" backup="$2"
  if "${AS_ROOT[@]}" test -e "$path"; then
    "${AS_ROOT[@]}" mv -- "$path" "$backup"
    echo "  disabled legacy unlimited file: $path"
    echo "    recoverable backup: $backup"
  fi
}

remove_managed() {
  local path="$1"
  if "${AS_ROOT[@]}" test -e "$path"; then
    "${AS_ROOT[@]}" grep -Fqx "$MANAGED_MARKER" "$path" \
      || die "$path is not managed by this script; refusing to remove it"
    "${AS_ROOT[@]}" rm -- "$path"
    echo "  removed $path"
  else
    echo "  already absent: $path"
  fi
}

# Older releases wrote unlimited values, including a wildcard drop-in affecting
# every user manager. Recognize only the exact old content and preserve it under
# a non-.conf backup name; unknown administrator content is never touched.
require_managed_or_absent "$LIMITS"
require_managed_or_absent "$DROPIN"
preflight_legacy "$LEGACY_LIMITS" "$WORK/legacy-limits" "$LEGACY_LIMITS_BACKUP"
preflight_legacy "$LEGACY_DROPIN" "$WORK/legacy-dropin" "$LEGACY_DROPIN_BACKUP"

if [ "$UNINSTALL" = 1 ]; then
  echo "== Removing managed NPU memlock configuration for $USER_NAME (UID $USER_UID) =="
  remove_managed "$LIMITS"
  remove_managed "$DROPIN"
  disable_legacy "$LEGACY_LIMITS" "$LEGACY_LIMITS_BACKUP"
  disable_legacy "$LEGACY_DROPIN" "$LEGACY_DROPIN_BACKUP"
  "${AS_ROOT[@]}" systemctl daemon-reload
  echo "Done. Reboot to discard limits inherited by existing processes."
  echo "XRT packages and render-group membership were intentionally kept."
  exit 0
fi

echo "== Enabling NPU for user: $USER_NAME (UID $USER_UID) =="

# 1) XRT userspace runtime (provides xrt-smi + pyxrt + amdxdna shim libs).
echo "[1/3] Installing XRT runtime packages"
"${AS_ROOT[@]}" apt-get update -qq
"${AS_ROOT[@]}" apt-get install -y libxrt-utils-npu python3-xrt

# 2) render group — /dev/accel/accel0 is normally root:render 0660.
echo "[2/3] Adding $USER_NAME to 'render' group"
getent group render >/dev/null || die "render group is missing after XRT installation"
"${AS_ROOT[@]}" usermod -aG render "$USER_NAME"

# 3) PAM logins and GUI applications inherit limits through different paths.
# Give this user alone a finite 1 GiB default, enough for xrt-smi's 64 MiB
# locked mapping and the verified examples without granting system-wide infinity.
echo "[3/3] Setting per-user memlock = $MEMLOCK_KB KiB (PAM + systemd user manager)"
"${AS_ROOT[@]}" install -D -m 0644 "$WORK/limits" "$LIMITS"
"${AS_ROOT[@]}" install -D -m 0644 "$WORK/dropin" "$DROPIN"
echo "  wrote $LIMITS"
echo "  wrote $DROPIN"
disable_legacy "$LEGACY_LIMITS" "$LEGACY_LIMITS_BACKUP"
disable_legacy "$LEGACY_DROPIN" "$LEGACY_DROPIN_BACKUP"
"${AS_ROOT[@]}" systemctl daemon-reload

# Unblock the shell that launched this script now; children inherit rlimits.
SHELL_PID=$PPID
if [ -n "${SUDO_USER:-}" ]; then
  # When invoked through sudo, the real shell is sudo's parent.
  SHELL_PID="$(ps -o ppid= -p "$PPID" | tr -d ' ')"
fi
if [[ "$SHELL_PID" =~ ^[0-9]+$ ]] \
    && "${AS_ROOT[@]}" prlimit --pid "$SHELL_PID" \
      --memlock="$MEMLOCK_BYTES:$MEMLOCK_BYTES" 2>/dev/null; then
  echo "  set the current shell (PID $SHELL_PID) to $MEMLOCK_KB KiB"
fi

echo
echo "Done. >>> REBOOT once <<< to apply the bounded limit everywhere."
echo "Then run scripts/check-npu.sh --strict and scripts/verify-stack.sh --quick."
echo "Rollback only this script's memlock files with: scripts/enable-npu.sh --uninstall"
