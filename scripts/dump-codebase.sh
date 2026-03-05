#!/usr/bin/env bash
# Dump the essential codebase files into a single text file for LLM consumption

set -euo pipefail

# Enable recursive globbing (**/) and prevent literal unmatched globs
shopt -s globstar nullglob

# ====================== FILE LIST ======================
patterns=(
  README.md
  Makefile
  main.c
  lua/cli.lua
  test_cli.lua
  vendor/README.md
)
# ======================================================

output_file="code_dump.txt"

# Start fresh
> "$output_file"

echo "=== Starting codebase dump ==="

for pattern in "${patterns[@]}"; do
  for file in ${pattern}; do
    if [[ -f "$file" ]]; then
      echo "Dumping: $file"
      {
        printf '\n<<<<<<<<<< START FILE: %s >>>>>>>>>>\n\n' "$file"
        cat "$file"
        printf '\n<<<<<<<<<< END FILE: %s >>>>>>>>>>\n' "$file"
      } >> "$output_file"
    fi
  done
done

echo "=== Done! Output written to $output_file ==="