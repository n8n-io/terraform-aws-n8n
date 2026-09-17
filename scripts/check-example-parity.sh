#!/usr/bin/env bash
# check-example-parity.sh: the DNS, topology and single-layer customer-managed
# examples are documented as examples/small plus one deliberate difference,
# customer-managed-everything stacks three of those, and medium/large are
# sizing tiers of the same input surface. In practice the module input surface
# each one passes through has silently drifted before (see #136): a variable
# added to one was never added to the others, and three examples lost the
# "Production considerations" section entirely. Two checks:
#
#   1. Variable parity. Diffs each example's variables.tf declarations against
#      examples/small's and fails on any difference not listed in
#      ALLOWED_DIFFS below. Entries are "example:pattern"; a pattern may be a
#      bash glob (customer_managed_*). Every entry must still match a real
#      variable, so a rename cannot leave a stale exemption behind.
#
#   2. Production considerations. Any example whose main.tf still lets the
#      module create RDS or S3 (does not set both create_database = false and
#      create_s3_bucket = false) inherits the module's teardown-friendly
#      deletion-control defaults, and its README must carry a "## Production
#      considerations" section saying so.
#
# What this script deliberately does NOT check: main.tf wiring, tftest.hcl
# coverage, or the content of the considerations table. It catches the
# surface going out of sync, which is what #136 found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE=small
EXAMPLES=(cloudflare godaddy split-ingress customer-managed-redis customer-managed-s3
  customer-managed-cluster customer-managed-everything medium large)

# "example:pattern" pairs allowed to differ from examples/small, either way.
ALLOWED_DIFFS=(
  # DNS-provider variants issue their own single-CN certificate, so they have
  # no Route 53 zone and cannot take n8n_additional_domains (see the "Multiple
  # hostnames" section of each README).
  "cloudflare:route53_zone_id"
  "cloudflare:n8n_additional_domains"
  "cloudflare:cloudflare_*"
  "godaddy:route53_zone_id"
  "godaddy:n8n_additional_domains"
  "godaddy:godaddy_*"
  # split-ingress composes n8n_additional_domains from webhook_subdomain
  # rather than exposing it raw, and owns its own two Ingresses.
  "split-ingress:n8n_additional_domains"
  "split-ingress:webhook_subdomain"
  "split-ingress:admin_allowed_cidr_blocks"
  "split-ingress:waf_acl_arn"
  "split-ingress:ssl_policy"
  # Customer-managed variants size their stand-in infrastructure themselves.
  "customer-managed-redis:customer_managed_*"
  "customer-managed-s3:customer_managed_*"
  "customer-managed-cluster:customer_managed_*"
  "customer-managed-cluster:kubernetes_version"
  "customer-managed-everything:customer_managed_*"
  "customer-managed-everything:kubernetes_version"
  # The module-side deletion controls (db_*, s3_force_destroy) are no-ops on
  # a layer the module does not create, and setting one there only raises the
  # module's rds_tuning_requires_module_managed_database /
  # s3_force_destroy_requires_module_managed_bucket warning. So: -s3 brings
  # its own bucket (its force_destroy is customer_managed_s3_force_destroy),
  # -everything brings both RDS and S3, and large runs Aurora in place of RDS
  # (the equivalent arguments live on aws_rds_cluster.n8n in its aurora.tf).
  "customer-managed-s3:s3_force_destroy"
  "customer-managed-everything:db_backup_retention_period"
  "customer-managed-everything:db_deletion_protection"
  "customer-managed-everything:db_skip_final_snapshot"
  "customer-managed-everything:db_final_snapshot_identifier"
  "customer-managed-everything:db_delete_automated_backups"
  "customer-managed-everything:s3_force_destroy"
  "large:db_backup_retention_period"
  "large:db_deletion_protection"
  "large:db_skip_final_snapshot"
  "large:db_final_snapshot_identifier"
  "large:db_delete_automated_backups"
  # large swaps RDS for Aurora and accepts a BYO certificate_arn instead of
  # route53_zone_id; it does not offer additional hostnames.
  "large:aurora_*"
  "large:certificate_arn"
  "large:n8n_additional_domains"
)

declare_vars() {
  # `|| true` keeps a variables.tf with no declarations from tripping
  # `set -e` inside the caller's command substitution with an unexplained exit.
  { grep -oE '^variable "[^"]+"' "examples/$1/variables.tf" || true; } | sed -E 's/^variable "(.+)"$/\1/' | sort -u
}

is_allowed() {
  local example="$1" var="$2" entry pattern
  for entry in "${ALLOWED_DIFFS[@]}"; do
    [[ "${entry%%:*}" == "$example" ]] || continue
    pattern="${entry#*:}"
    # shellcheck disable=SC2053  # pattern is meant to glob
    [[ "$var" == $pattern ]] && return 0
  done
  return 1
}

fail=0
baseline_vars="$(declare_vars "$BASELINE")"

for example in "${EXAMPLES[@]}"; do
  example_vars="$(declare_vars "$example")"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    grep -qxF "$var" <<<"$example_vars" && continue
    is_allowed "$example" "$var" && continue
    echo "check-example-parity: examples/$BASELINE declares \"$var\" but examples/$example does not (undeclared drift; add it to $example or to ALLOWED_DIFFS with a reason)" >&2
    fail=1
  done <<<"$baseline_vars"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    grep -qxF "$var" <<<"$baseline_vars" && continue
    is_allowed "$example" "$var" && continue
    echo "check-example-parity: examples/$example declares \"$var\" but examples/$BASELINE does not (undeclared drift; add it to $BASELINE or to ALLOWED_DIFFS with a reason)" >&2
    fail=1
  done <<<"$example_vars"

  # Every ALLOWED_DIFFS entry for this example must still match a variable on
  # at least one side, so a rename or removal cannot leave a stale exemption
  # that silently widens what this script accepts.
  for entry in "${ALLOWED_DIFFS[@]}"; do
    [[ "${entry%%:*}" == "$example" ]] || continue
    pattern="${entry#*:}"
    matched=0
    while IFS= read -r var; do
      # shellcheck disable=SC2053
      [[ -n "$var" && "$var" == $pattern ]] && { matched=1; break; }
    done <<<"$(printf '%s\n%s\n' "$baseline_vars" "$example_vars")"
    if [[ "$matched" -eq 0 ]]; then
      echo "check-example-parity: ALLOWED_DIFFS names \"$pattern\" for examples/$example, but no such variable exists there or in examples/$BASELINE; remove the stale exemption" >&2
      fail=1
    fi
  done
done

# Production considerations: required unless the module owns neither RDS nor
# S3 in this example. Runs over the baseline too, since small's own section is
# what every other example's points at. POSIX character classes, not \s: this
# runs under whichever grep the developer has. Only a literal `= false` counts
# as "customer-managed"; anything else (unset, `= true`, `= var.x`) is treated
# as module-owned, so the check errs toward demanding the section.
for example in "$BASELINE" "${EXAMPLES[@]}"; do
  main="examples/$example/main.tf"
  if ! { grep -qE '^[[:space:]]*create_database[[:space:]]*=[[:space:]]*false' "$main" && grep -qE '^[[:space:]]*create_s3_bucket[[:space:]]*=[[:space:]]*false' "$main"; }; then
    if ! grep -qx '## Production considerations' "examples/$example/README.md"; then
      echo "check-example-parity: examples/$example lets the module create RDS and/or S3 but its README has no \"## Production considerations\" section (see examples/$BASELINE/README.md)" >&2
      fail=1
    fi
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-example-parity: FAILED" >&2
  exit 1
fi

echo "check-example-parity: OK ($BASELINE vs ${EXAMPLES[*]})"
