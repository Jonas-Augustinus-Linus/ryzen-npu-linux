#!/usr/bin/env bash
# Hardware-free release checks. This is the same entry point used by CI.
# Usage: scripts/validate-repo.sh
set -euo pipefail

case "${1:-}" in
  "") [ "$#" -eq 0 ] || { echo "validate-repo.sh takes no arguments" >&2; exit 2; } ;;
  -h|--help)
    [ "$#" -eq 1 ] || { echo "validate-repo.sh takes no arguments" >&2; exit 2; }
    sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "validate-repo.sh takes no arguments" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

mapfile -t shell_files < <(git ls-files --cached --others --exclude-standard '*.sh')
for file in "${shell_files[@]}"; do
  bash -n "$file"
  [ -x "$file" ] || { echo "shell entry point is not executable: $file" >&2; exit 1; }
done
printf '[validate] shell syntax/executable bits: %d PASS\n' "${#shell_files[@]}"

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

tracked = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
).decode().split("\0")
tracked = [Path(name) for name in tracked if name]
errors = []

# Vendored byte-identical to an upstream commit and pinned by sha256
# (scripts/check-w4a16-compile.sh); whitespace fixes would break the pins.
VENDORED = {
    Path("examples/mlir-aie/w4a16_gemm/mix_int4_ATB.cc"),
    Path("examples/mlir-aie/w4a16_gemm/zero.cc"),
}

for path in tracked:
    data = path.read_bytes()
    if path.suffix.lower() in {".gif", ".png", ".jpg", ".jpeg", ".webp", ".ico", ".pdf"}:
        continue
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        errors.append(f"{path}: invalid UTF-8: {exc}")
        continue
    if path in VENDORED:
        continue
    if data and not data.endswith(b"\n"):
        errors.append(f"{path}: missing final newline")
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.endswith((" ", "\t")):
            errors.append(f"{path}:{lineno}: trailing whitespace")
        if re.match(r"^(?:<{7}|={7}|>{7})(?: |$)", line):
            errors.append(f"{path}:{lineno}: merge-conflict marker")
    if path.suffix == ".py":
        try:
            compile(text, str(path), "exec")
        except SyntaxError as exc:
            errors.append(f"{path}:{exc.lineno}: Python syntax: {exc.msg}")
    if path.suffix.lower() != ".md":
        continue
    if sum(1 for line in text.splitlines() if line.lstrip().startswith("```")) % 2:
        errors.append(f"{path}: unbalanced fenced code blocks")
    # Inline Markdown links and images. Remote URLs and same-page anchors are
    # intentionally skipped; fragments are stripped from local paths.
    for match in re.finditer(r"!?\[[^\]]*\]\(([^)]+)\)", text):
        target = match.group(1).strip().split()[0].strip("<>")
        if not target or target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        local = unquote(target.split("#", 1)[0].split("?", 1)[0])
        if local and not (path.parent / local).resolve().exists():
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{path}:{line}: missing local link: {target}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
print(f"[validate] UTF-8/newlines/whitespace/Python/Markdown links: {len(tracked)} PASS")
PY

git diff --check
printf '[validate] git diff --check: PASS\n'
