#!/usr/bin/env bash
# Offline, deterministic regression test for constraint_accepts()
# (tests/scripts/lib/constraints.sh), the Terraform version-constraint
# evaluator tests/scripts/check-version-drift.sh uses to decide whether a
# provider's latest registry version is actual drift or already covered by
# the module's own `~>`/`>=`/etc. constraint. Runs no network and no
# Terraform; every case below is a fixed (constraint, version, expected
# exit code) triple.
#
# Ported from the sibling terraform-google-n8n module's
# tests/scripts/test-version-drift-constraints.sh (n8n-io/terraform-google-n8n#40).
#
# Usage: tests/scripts/test-version-drift-constraints.sh
# Requires: python3 (constraints.sh shells out to it).

set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=lib/constraints.sh
source tests/scripts/lib/constraints.sh

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

# check_case <constraint> <version> <expected-exit>
check_case() {
  local constraint="$1" version="$2" expected="$3" actual
  if constraint_accepts "$constraint" "$version"; then
    actual=0
  else
    actual=$?
  fi
  if [ "$actual" = "$expected" ]; then
    pass "constraint_accepts '${constraint}' '${version}' -> ${actual}"
  else
    fail "constraint_accepts '${constraint}' '${version}' -> ${actual}, expected ${expected}"
  fi
}

# ── This module's five Terraform provider constraints (versions.tf) ────────
# Not a live lookup: fixed version(s) observed at the time this test was
# written, used only to exercise the operator the module actually pins
# with, not to assert what upstream's current release is.
check_case "~> 6.0" "6.68.0" 0   # aws: admits any 6.x.y
check_case "~> 6.0" "7.0.0" 1    # aws: major bump is drift
check_case "~> 3.0" "3.3.0" 0    # kubernetes / helm / random: admits any 3.x.y
check_case "~> 3.0" "4.0.0" 1    # kubernetes / helm / random: major bump is drift
check_case "~> 0.14" "0.14.2" 0  # time: admits 0.x.y for x >= 14
check_case "~> 0.14" "0.22.0" 0  # time: pre-1.0, so the minor is free too
check_case "~> 0.14" "1.0.0" 1   # time: major bump is drift

# ── ~> precision (one and two dotted components, exact upper bound) ────────
check_case "~> 3.0" "3.3.0" 0
check_case "~> 3.0" "4.0.0" 1
check_case "~> 0.14" "0.14.2" 0
check_case "~> 0.14" "1.0.0" 1
check_case "~> 6.23" "8.6.0" 1
check_case "~> 8.0" "8.7.0" 0
check_case "~> 1.14" "1.19.0" 0
check_case "~> 6.23.1" "6.23.9" 0
check_case "~> 6.23.1" "6.24.0" 1
check_case "~> 1" "1.9.0" 0
check_case "~> 1" "2.0.0" 1

# ── Correct ~> 6.23 lower/upper edges (6.23.0 inclusive, 6.22.x excluded) ───
check_case "~> 6.23" "6.23.0" 0
check_case "~> 6.23" "6.99.9" 0
check_case "~> 6.23" "6.22.9" 1

# ── Comma-separated bounds ──────────────────────────────────────────────────
check_case ">= 1.11" "1.11.0" 0
check_case ">= 1.11" "1.16.5" 0
check_case ">= 1.11, < 2.0" "2.1.0" 1
check_case ">= 1.11, < 2.0" "1.16.5" 0
check_case ">= 1.11, < 2.0" "1.10.9" 1

# ── Bare, =, !=, >, <=, < ────────────────────────────────────────────────
check_case "1.2.3" "1.2.3" 0
check_case "1.2.3" "1.2.4" 1
check_case "= 1.2.3" "1.2.3" 0
check_case "!= 1.2.3" "1.2.3" 1
check_case "> 1.0.0" "1.0.0" 1
check_case "<= 1.0.0" "1.0.0" 0
check_case "< 1.0.0" "1.0.0" 1

# ── Unparseable constraints ─────────────────────────────────────────────────
check_case "" "1.0.0" 2
check_case "~>" "1.0.0" 2
check_case ">=1.x" "1.0.0" 2
check_case "1.2.3.4" "1.0.0" 2
check_case "latest" "1.0.0" 2

# ── Prerelease or non-numeric versions are an explicit error, not a guess ───
# A prerelease constraint is valid Terraform but outside the numeric subset
# this evaluator understands; a prerelease or non-numeric candidate version
# used to raise inside the evaluator and read as "outside the constraint".
check_case "= 1.2.0-beta" "1.2.0" 2
check_case ">= 1.2.0-beta" "1.2.0" 2
check_case "~> 6.0" "6.69.0-beta1" 2
check_case "~> 6.0" "" 2
check_case "~> 6.0" "unknown" 2

# ── Extra whitespace tolerance ──────────────────────────────────────────────
check_case "  ~>   3.0  " "3.1.0" 0

# ── Self-check: prove a wrong expected value is actually caught ────────────
# Runs one case with a deliberately wrong expected exit code in a subshell
# (so its FAILURES increment does not pollute the real run) and confirms it
# is reported as a failure, not a false pass. This proves the harness has
# teeth every time it runs, rather than only when someone remembers to
# break it by hand.
SELFTEST_OUTPUT="$(
  FAILURES=0
  fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
  pass() { echo "PASS: $1"; }
  check_case() {
    local constraint="$1" version="$2" expected="$3" actual
    if constraint_accepts "$constraint" "$version"; then
      actual=0
    else
      actual=$?
    fi
    if [ "$actual" = "$expected" ]; then
      pass "constraint_accepts '${constraint}' '${version}' -> ${actual}"
    else
      fail "constraint_accepts '${constraint}' '${version}' -> ${actual}, expected ${expected}"
    fi
  }
  check_case "~> 3.0" "3.3.0" 1
  echo "FAILURES=$FAILURES"
)"

if echo "$SELFTEST_OUTPUT" | grep -q "^FAILURES=1$"; then
  pass "self-check: a deliberately wrong expected exit code is caught as a failure"
else
  fail "self-check: a deliberately wrong expected exit code was NOT caught (harness has no teeth): ${SELFTEST_OUTPUT}"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "test-version-drift-constraints.sh: ${FAILURES} case(s) failed" >&2
  exit 1
fi

echo "test-version-drift-constraints.sh: all cases passed"
