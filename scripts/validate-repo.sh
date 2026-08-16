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
import hashlib
import re
import subprocess
import sys
from urllib.parse import unquote

tracked = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
).decode().split("\0")
tracked = [Path(name) for name in tracked if name]
errors = []

# Vendored byte-identical to an upstream commit; the sha256 pins below must
# match scripts/check-w4a16-compile.sh. Instead of style checks, these files
# get a byte-identity assertion — it subsumes whitespace/newline/conflict
# scanning and catches any formatter or merge damage outright.
VENDORED = {
    Path("examples/mlir-aie/w4a16_gemm/mix_int4_ATB.cc"):
        "9f89364479ca30d230cfb595a7bad04520ec49af514f7f6928282cc851ac1834",
    Path("examples/mlir-aie/w4a16_gemm/zero.cc"):
        "08c19f45a55d466ea47274cf4d19e8147f85ac35df9b2eed573a7f0b89412cea",
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
        actual = hashlib.sha256(data).hexdigest()
        if actual != VENDORED[path]:
            errors.append(
                f"{path}: vendored file modified (sha256 {actual} != pinned "
                f"{VENDORED[path]}; byte-identity to the upstream commit is "
                f"the provenance guarantee — see check-w4a16-compile.sh)"
            )
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
