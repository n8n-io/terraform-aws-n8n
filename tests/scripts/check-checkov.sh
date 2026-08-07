#!/usr/bin/env bash
# check-checkov.sh: run the checkov scan that gates CI.
#
# This is not a local imitation of the CI job: the `checkov` job in
# .github/workflows/terraform-tests.yml runs this exact script, so the flags,
# the config file and the exit code have a single definition. Findings are
# either fixed or annotated with an inline `checkov:skip=<ID>:<reason>` comment
# at the resource that causes them (see issue #27); .checkov.yaml carries no
# check suppressions, only the tests/ path exclusion. checkov exits non-zero on
# any finding that is neither fixed nor annotated, and that is what fails the
# build.
#
# Usage:
#   tests/scripts/check-checkov.sh
#
# Requires checkov at the version CI pins (CHECKOV_VERSION in the workflow):
#   uv tool install checkov==<version>
#   # or: pipx install --force checkov==<version>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/terraform-tests.yml"

if ! command -v checkov >/dev/null 2>&1; then
  echo "checkov not found on PATH. Install it: uv tool install checkov" >&2
  exit 1
fi

# checkov results depend on the checkov version, not only on the code being
# scanned: 3.3.9 evaluates whole check families against resources reached
# through a local module source (this module, as called by examples/*) that
# 3.3.0 skipped without reporting anything at all. So a clean run on an
# arbitrary version says nothing about whether the gate passes. The pin lives in
# the workflow, making that file the single source of truth for CI and for here;
# CHECKOV_VERSION_CHECK=off bypasses this, which is what you want when trying a
# newer release before pinning it.
PINNED="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
INSTALLED="$(checkov --version 2>/dev/null | tr -d '[:space:]')"

if [[ "${CHECKOV_VERSION_CHECK:-on}" != "off" && -n "$PINNED" && "$INSTALLED" != "$PINNED" ]]; then
  cat >&2 <<EOF
checkov version mismatch: installed $INSTALLED, CI pins $PINNED.

Results are not comparable across versions, so this run would not tell you
whether CI passes. Install the pinned version:

  uv tool install checkov==$PINNED
  # or: pipx install --force checkov==$PINNED

The pin lives in $WORKFLOW (CHECKOV_VERSION).
Set CHECKOV_VERSION_CHECK=off to run anyway.
EOF
  exit 1
fi

cd "$REPO_ROOT"
exec checkov -d . --framework terraform --config-file .checkov.yaml --quiet --compact
