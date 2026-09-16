#!/usr/bin/env bash
# chart-values-diff.sh: diff the pinned n8n chart's values.yaml against a
# candidate version.
#
# Wraps the "diff the two versions' values.yaml" step that
# docs/helm-chart-coverage.md asks for on every n8n_chart_version bump (and
# that docs/versioning.md's Minor-required tier depends on) into one command
# instead of a remembered `helm show values` invocation typed twice.
# Never writes or bumps a pin: it only reads variables.tf and calls `helm
# show values`. Exits 0 once both `helm show values` calls succeed and
# `diff` ran, regardless of whether a diff was found; exits 1 on bad usage,
# a missing tool, a failed `helm show values` call (network/registry issue,
# bad candidate version), or a `diff` error.
# Run it BEFORE moving n8n_chart_version's default: it reads the pin from
# variables.tf, so once the default already equals the candidate there is
# nothing left to compare.
# Deciding whether a diff is worth exposing (or requires a module change) is
# still a human call — see docs/versioning.md.
#
# Usage: tests/scripts/chart-values-diff.sh <candidate-version>
#   e.g. tests/scripts/chart-values-diff.sh 1.12.0
# Requires: helm. No terraform, no AWS credentials, no cluster.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

CANDIDATE="${1:-}"
if [ "$#" -ne 1 ] || [ -z "$CANDIDATE" ]; then
  echo "Usage: $0 <candidate-version>" >&2
  echo "  e.g.  $0 1.12.0" >&2
  exit 1
fi

command -v helm >/dev/null 2>&1 || { echo "Required tool missing: helm" >&2; exit 1; }

# shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
source "$SCRIPT_DIR/lib/tf-defaults.sh"

PINNED="$(read_default n8n_chart_version variables.tf)"
if [ -z "$PINNED" ]; then
  echo "Could not read n8n_chart_version's default from variables.tf" >&2
  exit 1
fi

if [ "$PINNED" = "$CANDIDATE" ]; then
  echo "Candidate $CANDIDATE is already the pinned version; nothing to diff." >&2
  exit 0
fi

CHART_REPO="$(read_default n8n_chart_repository variables.tf)"
if [ -z "$CHART_REPO" ]; then
  echo "Could not read n8n_chart_repository's default from variables.tf" >&2
  exit 1
fi
# helm show values takes a bare <repo>/<chart> reference only for OCI
# registries; an https:// chart repository would need `--repo <url> n8n`.
# variables.tf accepts both schemes, so fail clearly rather than let Helm
# produce a confusing error if the default ever moves.
case "$CHART_REPO" in
  oci://*) CHART_REF="${CHART_REPO}/n8n" ;;
  *)
    echo "chart-values-diff.sh only supports oci:// chart repositories; n8n_chart_repository's default is $CHART_REPO" >&2
    exit 1
    ;;
esac
TMP_DIR="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
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

# diff: 0 = identical, 1 = differences (both are a successful comparison),
# >1 = diff itself failed.
case "$DIFF_STATUS" in
  0) echo "No differences between $PINNED and $CANDIDATE." >&2 ;;
  1) ;;
  *)
    echo "diff failed with status $DIFF_STATUS" >&2
    exit 1
    ;;
esac

exit 0
