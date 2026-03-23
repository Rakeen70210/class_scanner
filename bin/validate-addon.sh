#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON_DIR="$ROOT_DIR/ClassScanner"
TOC_FILE="$ADDON_DIR/ClassScanner.toc"
STRICT_MODE="${1:-}"

if [ ! -f "$TOC_FILE" ]; then
  echo "Missing TOC file: $TOC_FILE" >&2
  exit 1
fi

echo "Validating addon manifest: $TOC_FILE"

mapfile -t toc_entries < <(awk '
  /^[[:space:]]*$/ { next }
  /^##/ { next }
  { print }
' "$TOC_FILE")

if [ "${#toc_entries[@]}" -eq 0 ]; then
  echo "No Lua files were listed in the TOC." >&2
  exit 1
fi

for entry in "${toc_entries[@]}"; do
  file_path="$ADDON_DIR/$entry"
  if [ ! -f "$file_path" ]; then
    echo "TOC entry is missing on disk: $entry" >&2
    exit 1
  fi
done

echo "TOC references are valid."

syntax_checker=""
if command -v luac5.1 >/dev/null 2>&1; then
  syntax_checker="luac5.1"
elif command -v luac >/dev/null 2>&1; then
  syntax_checker="luac"
fi

if [ -n "$syntax_checker" ]; then
  echo "Running Lua syntax checks with $syntax_checker"
  for entry in "${toc_entries[@]}"; do
    "$syntax_checker" -p "$ADDON_DIR/$entry"
  done
elif [ "$STRICT_MODE" = "--strict" ]; then
  echo "Lua syntax checker not available in strict mode. Install lua5.1." >&2
  exit 1
else
  echo "Lua syntax checker not available locally; skipping parse validation."
fi

echo "Addon validation passed."
