#!/usr/bin/env bash
# check-terraform-floor.sh: keep the tested Terraform floor and the declared
# one identical.
#
# CI's `test-floor` job runs every `terraform test` suite on TF_FLOOR_VERSION
# (.github/workflows/terraform-tests.yml). That only proves the declared floor
# works if the two agree, and nothing else ties them together: either side
# can move while the other keeps advertising the old value. This script fails
# unless:
#
#   1. TF_FLOOR_VERSION is exactly X.Y.0, the lowest release `>= X.Y` admits.
#      Comparing major.minor alone would accept testing 1.13.1 against a
#      `>= 1.13` floor and miss a bug that only 1.13.0 has.
#   2. The module root, every modules/* submodule and every examples/* root
#      module declares required_version exactly once, as `">= X.Y"`.
#
# Requires: bash, grep, sed. No terraform, no AWS credentials.
#
# Usage: tests/scripts/check-terraform-floor.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW=".github/workflows/terraform-tests.yml"

# Exactly one definition: a second one (for example a job-level env override)
# could make test-floor run a version this script never checked.
floors="$(sed -n 's/^[[:space:]]*TF_FLOOR_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW")"
definitions="$(grep -c -E '^[[:space:]]*TF_FLOOR_VERSION:' "$WORKFLOW" || true)"

if [[ "$definitions" -ne 1 || -z "$floors" ]]; then
  echo "$WORKFLOW: expected exactly one quoted TF_FLOOR_VERSION env value, found $definitions definition(s)" >&2
  exit 1
fi
floor="$floors"

if [[ ! "$floor" =~ ^([0-9]+)\.([0-9]+)\.0$ ]]; then
  echo "$WORKFLOW: TF_FLOOR_VERSION is \"$floor\"; it must be X.Y.0, the lowest release the declared floor admits" >&2
  exit 1
fi

expected=">= ${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
failures=0

for dir in . modules/* examples/*; do
  [[ -d "$dir" ]] || continue

  # Only the directory's own .tf files: a root module's .terraform/ holds
  # copies of other modules' declarations.
  declarations="$(grep -H -E '^[[:space:]]*required_version[[:space:]]*=' "$dir"/*.tf 2>/dev/null || true)"
  count="$(printf '%s' "$declarations" | grep -c . || true)"

  if [[ "$count" -ne 1 ]]; then
    echo "$dir: expected exactly one required_version declaration, found $count" >&2
    failures=$((failures + 1))
    continue
  fi

  value="$(printf '%s\n' "$declarations" | sed -n 's/.*required_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"

  if [[ "$value" != "$expected" ]]; then
    echo "${declarations%%:*}: required_version is \"$value\", expected \"$expected\" to match TF_FLOOR_VERSION $floor" >&2
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -ne 0 ]]; then
  echo "Terraform floor check failed: $failures problem(s). Move every required_version and TF_FLOOR_VERSION together (see docs/versioning.md)." >&2
  exit 1
fi

echo "Terraform floor OK: TF_FLOOR_VERSION $floor matches required_version \"$expected\" in the root, modules/* and examples/*."
