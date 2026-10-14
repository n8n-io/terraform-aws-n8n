#!/usr/bin/env bash
# Shared Terraform version-constraint evaluator for
# tests/scripts/check-version-drift.sh and its regression test,
# tests/scripts/test-version-drift-constraints.sh. Split into its own
# sourceable file because check-version-drift.sh runs network lookups at
# the top level and cannot itself be `source`d by a test.
#
# Ported from the sibling terraform-google-n8n module's
# tests/scripts/lib/constraints.sh (n8n-io/terraform-google-n8n#40), which
# generalized that module's own `~>`-vs-latest substring compare into the
# same full constraint grammar this file implements. Unlike the sibling,
# this module's check-version-drift.sh (n8n-io/terraform-aws-n8n#191)
# already evaluated provider constraints rather than doing a substring
# compare, but only understood a single "~> N[.N[.N]]" range; this file
# replaces that narrower evaluator with the same one the sibling now uses,
# so a provider constraint like ">= 1.2, < 3.0" is evaluated instead of
# reported as an explicit ERROR.

# constraint_accepts <constraint> <version>
# Exit 0 when <version> satisfies the Terraform version constraint (comma
# separated; operators ~>, >=, >, <=, <, !=, = or none), 1 when it does not,
# 2 when the constraint or <version> cannot be parsed. Missing version parts
# count as 0.
#
# Only numeric N[.N[.N]] versions are understood. A prerelease or build-
# metadata version, in a constraint or as <version>, is exit 2 instead of a
# guess, so it surfaces as an explicit ERROR. Terraform's rule that an exact
# (= or bare) constraint cannot be combined with another condition is not
# enforced here: the constraints this reads come from versions.tf, which
# Terraform itself validates.
constraint_accepts() {
  python3 - "$1" "$2" <<'PYEOF'
import re
import sys

constraint, version = sys.argv[1], sys.argv[2]


def parse(s):
    return tuple(int(x) for x in s.split("."))


def pad(t):
    return t + (0,) * (3 - len(t))


if not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
    sys.exit(2)

ver = pad(parse(version))
ok = True
for part in constraint.split(","):
    m = re.fullmatch(r"\s*(~>|>=|<=|!=|>|<|=)?\s*(\d+(?:\.\d+){0,2})\s*", part)
    if not m:
        sys.exit(2)
    op, lim = m.group(1) or "=", parse(m.group(2))
    p = pad(lim)
    if op == "=":
        ok = ok and ver == p
    elif op == "!=":
        ok = ok and ver != p
    elif op == ">=":
        ok = ok and ver >= p
    elif op == ">":
        ok = ok and ver > p
    elif op == "<=":
        ok = ok and ver <= p
    elif op == "<":
        ok = ok and ver < p
    else:  # ~>: the rightmost given component may grow, the one before it may not
        up = list(lim[: max(len(lim) - 1, 1)])
        up[-1] += 1
        ok = ok and ver >= p and ver < pad(tuple(up))
sys.exit(0 if ok else 1)
PYEOF
}
