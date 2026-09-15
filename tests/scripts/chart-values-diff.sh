#!/usr/bin/env bash
# chart-values-diff.sh: diff the pinned n8n chart's values.yaml against a
# candidate version.
#
# Makes V1's own manual pickup step ("Diff the new chart's values.yaml
# against the currently pinned one" — see the version-currency plan) one
# command instead of a remembered `helm show values` invocation typed twice.
# Informational only: always exits 0, changes nothing, and does not read or
# write any pin. Deciding whether a delta is worth exposing (or requires a
# module change) is still a human call — see docs/versioning.md.
#
# Usage: tests/scripts/chart-values-diff.sh <candidate-version>
#   e.g. tests/scripts/chart-values-diff.sh 1.12.0
# Requires: helm. No terraform, no AWS credentials, no cluster.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CANDIDATE="${1:-}"
if [ -z "$CANDIDATE" ]; then
  echo "Usage: $0 <candidate-version>" >&2
  echo "  e.g.  $0 1.12.0" >&2
  exit 1
fi

command -v helm >/dev/null 2>&1 || { echo "Required tool missing: helm" >&2; exit 1; }

read_default() {
  # $1: variable name, $2: file. Prints its string default's contents.
  awk -v name="$1" '
    $0 ~ "variable \"" name "\"" { in_block = 1 }
    in_block && /default[ \t]*=/ {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
    in_block && /^}/ { exit }
  ' "$2"
}

PINNED="$(read_default n8n_chart_version variables.tf)"
if [ -z "$PINNED" ]; then
  echo "Could not read n8n_chart_version's default from variables.tf" >&2
  exit 1
fi

if [ "$PINNED" = "$CANDIDATE" ]; then
  echo "Candidate $CANDIDATE is already the pinned version; nothing to diff." >&2
  exit 0
fi

CHART_REF="oci://ghcr.io/n8n-io/n8n-helm-chart/n8n"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Pinned:    $PINNED" >&2
echo "Candidate: $CANDIDATE" >&2
echo >&2

helm show values "$CHART_REF" --version "$PINNED" >"$TMP_DIR/pinned.yaml" ||
  { echo "helm show values failed for pinned version $PINNED" >&2; exit 1; }
helm show values "$CHART_REF" --version "$CANDIDATE" >"$TMP_DIR/candidate.yaml" ||
  { echo "helm show values failed for candidate version $CANDIDATE" >&2; exit 1; }

diff -u --label "values.yaml ($PINNED)" --label "values.yaml ($CANDIDATE)" \
  "$TMP_DIR/pinned.yaml" "$TMP_DIR/candidate.yaml"
DIFF_STATUS=$?

if [ "$DIFF_STATUS" -eq 0 ]; then
  echo "No differences between $PINNED and $CANDIDATE." >&2
fi

exit 0
