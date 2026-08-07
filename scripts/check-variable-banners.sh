#!/usr/bin/env bash
# check-variable-banners.sh — every variable/output block in variables.tf and
# outputs.tf must sit under a "# ── Section ──" banner comment (see AGENTS.md,
# "Clear documentation"). Catches two drift patterns:
#
#   1. A block appended with no banner above it at all.
#   2. A banner-like comment that doesn't match the established format
#      (wrong dashes, missing padding, typo'd style).
#
# What this script deliberately does NOT check: whether a variable was filed
# under the *correct* banner for its meaning (e.g. a new toggle landing in
# "Execution settings" vs "Task runners"). That judgment call still needs a
# human/CODEOWNERS review — this only guarantees the convention itself can't
# silently rot to "no sections at all".

set -euo pipefail

# The banner regexes below match the multibyte "─" (U+2500) used in
# variables.tf/outputs.tf. Bash's [[ =~ ]] only resolves that against file
# content under a UTF-8 locale; a C/POSIX locale (the default in minimal
# shells and containers) makes every real banner fail the strict-format
# check. Force UTF-8 so the result doesn't depend on the caller's locale.
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FILES=(variables.tf outputs.tf)
BANNER_LOOSE_RE='^#{1,2}[[:space:]]*(──|--|—)'
BANNER_STRICT_RE='^# ── .+ ─{2,}$'
BLOCK_RE='^(variable|output) "'

fail=0

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "check-variable-banners: $file not found, skipping" >&2
    continue
  fi

  banner=""
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ $BANNER_LOOSE_RE ]]; then
      if [[ ! "$line" =~ $BANNER_STRICT_RE ]]; then
        echo "$file:$lineno: malformed banner (expected '# ── Section Name ──...──'): $line" >&2
        fail=1
      fi
      banner="$line"
    elif [[ "$line" =~ $BLOCK_RE ]]; then
      if [[ -z "$banner" ]]; then
        echo "$file:$lineno: no preceding '# ── Section ──' banner for: $line" >&2
        fail=1
      fi
    fi
  done < "$file"
done

if [[ "$fail" -ne 0 ]]; then
  echo >&2
  echo "See AGENTS.md, 'Clear documentation' > 'Variable/output banners', for the convention and current section list." >&2
  exit 1
fi

echo "check-variable-banners: OK (${FILES[*]})"
