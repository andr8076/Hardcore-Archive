#!/usr/bin/env bash

# Convert CRLF -> LF for tracked text files matching common patterns.
set -Eeuo pipefail

printf 'Scanning tracked files for CRLF line endings...\n'

patterns=("*.sh" "*.py" "*.md" "*.yml" "*.yaml" "*.env" "*.txt")

# Helper to process a null-separated list of filenames coming from git/xargs/grep
process_matches() {
  while IFS= read -r -d '' file; do
    printf 'Fixing %s\n' "$file"
    sed -i 's/\r$//' "$file"
  done
}

# First try to check only common text patterns (safer/fast)
git ls-files -z "${patterns[@]}" 2>/dev/null | xargs -0 -r grep -IlZ $'\r' | process_matches

# Also run a fallback over all tracked files to catch any missed files.
git ls-files -z | xargs -0 -r grep -IlZ $'\r' | process_matches

printf 'Finished converting line endings.\n'
