#!/usr/bin/env bash
# Resolve the locally installed AMD XDNA NPU to this repo's verified IREE target.
#
# Supported automatic mappings:
#   RyzenAI-npu1 / Phoenix / 4x4 -> npu1_4col (XDNA1)
#   RyzenAI-npu4 / Strix   / 4x8 -> npu4       (XDNA2 Strix Point)
#
# Later XDNA2 VBNVs (npu5/npu6) are deliberately not guessed as npu4. Set
# TARGET_DEVICE explicitly only when that hardware is known to be compatible.
#
# Usage: scripts/detect-npu.sh [--human|--tsv|--json|--target|--rows|--cols]
# Env:   IREE_AMD_AIE_ROOT (default: ~/src/iree-amd-aie)
#        TARGET_DEVICE     explicit npu1_4col or npu4 override
set -euo pipefail

ROOT="${IREE_AMD_AIE_ROOT:-$HOME/src/iree-amd-aie}"
HELPER="$ROOT/build_tools/ci/amdxdna_driver_utils/amdxdna_ioctl.py"
MODE="${1:---human}"

die() {
  printf '[detect-npu] %s\n' "$*" >&2
  exit 1
}

[ "$#" -le 1 ] || {
  printf '[detect-npu] expected at most one option\n' >&2
  exit 2
}

case "$MODE" in
  --human|--tsv|--json|--target|--rows|--cols) ;;
  -h|--help)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf '[detect-npu] unknown option: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

[ -f "$HELPER" ] || die "IREE device helper not found: $HELPER (run scripts/build.sh first)"
command -v python3 >/dev/null || die "python3 is required"
[ -r /dev/accel/accel0 ] && [ -w /dev/accel/accel0 ] \
  || die "/dev/accel/accel0 is not readable/writable (run scripts/check-npu.sh)"

ARCH="$(python3 "$HELPER" --npu-device 2>/dev/null)" \
  || die "could not query the NPU architecture with $HELPER"
ROWS="$(python3 "$HELPER" --num-rows 2>/dev/null)" \
  || die "could not query NPU rows with $HELPER"
COLS="$(python3 "$HELPER" --num-cols 2>/dev/null)" \
  || die "could not query NPU columns with $HELPER"
[[ "$ROWS" =~ ^[1-9][0-9]*$ && "$COLS" =~ ^[1-9][0-9]*$ ]] \
  || die "invalid NPU geometry from helper: rows='$ROWS' cols='$COLS'"

VBNV=""
for sysfs_device in /sys/bus/pci/drivers/amdxdna/*:*; do
  if [ -r "$sysfs_device/vbnv" ]; then
    VBNV="$(<"$sysfs_device/vbnv")"
    break
  fi
done
[ -n "$VBNV" ] || die "could not read the NPU VBNV from amdxdna sysfs"

if [ -n "${TARGET_DEVICE:-}" ]; then
  TARGET="$TARGET_DEVICE"
else
  case "$VBNV:$ROWS:$COLS" in
    RyzenAI-npu1:4:4|NPU\ Phoenix:4:4) TARGET="npu1_4col" ;;
    RyzenAI-npu4:4:8|NPU\ Strix:4:8)   TARGET="npu4" ;;
    *)
      die "unsupported automatic mapping: vbnv='$VBNV' arch='$ARCH' geometry=${ROWS}x${COLS}; set TARGET_DEVICE only for known-compatible hardware"
      ;;
  esac
fi

case "$TARGET:$ROWS:$COLS" in
  npu1_4col:4:4|npu4:4:8) ;;
  npu1_4col:*|npu4:*)
    die "target $TARGET is incompatible with discovered geometry ${ROWS}x${COLS}"
    ;;
  *)
    die "unsupported TARGET_DEVICE '$TARGET' (verified: npu1_4col, npu4)"
    ;;
esac

GENERATION="$([ "$TARGET" = npu4 ] && printf XDNA2 || printf XDNA1)"
VBNV_TSV="${VBNV//$'\t'/ }"
VBNV_TSV="${VBNV_TSV//$'\n'/ }"

case "$MODE" in
  --human)
    printf 'VBNV:       %s\n' "$VBNV"
    printf 'generation: %s\n' "$GENERATION"
    printf 'target:     %s\n' "$TARGET"
    printf 'geometry:   %sx%s\n' "$ROWS" "$COLS"
    ;;
  --tsv)
    printf '%s\t%s\t%s\t%s\t%s\n' "$TARGET" "$ROWS" "$COLS" "$GENERATION" "$VBNV_TSV"
    ;;
  --json)
    python3 - "$TARGET" "$ROWS" "$COLS" "$GENERATION" "$ARCH" "$VBNV" <<'PY'
import json
import sys

target, rows, cols, generation, arch, vbnv = sys.argv[1:]
print(json.dumps({
    "target": target,
    "rows": int(rows),
    "cols": int(cols),
    "generation": generation,
    "arch": arch,
    "vbnv": vbnv,
}, sort_keys=True))
PY
    ;;
  --target) printf '%s\n' "$TARGET" ;;
  --rows)   printf '%s\n' "$ROWS" ;;
  --cols)   printf '%s\n' "$COLS" ;;
esac
