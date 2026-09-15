#!/usr/bin/env bash
# check-version-drift.sh: report every pin that has fallen behind upstream.
#
# This is a report, not a gate: it always exits 0. A scheduled CI job runs it
# and posts the output to the job summary, so drift is visible without a
# reviewer needing to remember to go check five different registries by hand.
# Nothing here bumps a pin automatically: every change this script would
# suggest is release-sized work (see docs/versioning.md) and gets its own PR
# with the accompanying re-verification the pin's tier requires.
#
# Checks pins reachable from public, unauthenticated APIs:
#   - Terraform providers (registry.terraform.io)
#   - CLI tools this repo's CI pins (GitHub releases)
#   - Helm charts: the four controller charts against their own chart
#     repositories, n8n's chart against its source repo's Git tag (its
#     oci:// registry has no equivalent public index; see docs/versioning.md)
#   - EKS-supported Kubernetes versions (endoflife.date, an aggregator over
#     AWS's own release-calendar docs, not an AWS-published API)
#
# Deliberately NOT checked here (see docs/versioning.md "What this script
# cannot see"): RDS/ElastiCache engine versions and Aurora engine versions.
# No public aggregator covers minor-version currency at that granularity for
# either, and confirming a version is actually creatable in one account and
# region, for EKS as much as for RDS/Aurora, still needs the credentialed
# `describe-*` call this repo's CI does not hold (see AGENTS.md: never apply
# from CI). That is a manual check on the same cadence as everything here.
#
# Usage: tests/scripts/check-version-drift.sh
# Requires: curl, jq. No terraform, no AWS credentials, no cluster.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool missing: $tool" >&2; exit 1; }
done

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

read_provider_constraint() {
  # $1: provider name (as it appears after "source  = \"hashicorp/$1\"").
  awk -v name="$1" '
    $0 ~ "source  *= *\"hashicorp/" name "\"" { want_version = 1; next }
    want_version && /version[ \t]*=/ {
      if (match($0, /"[^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
      }
      exit
    }
  ' versions.tf
}

echo "## Version drift report"
echo

# ── Terraform providers ───────────────────────────────────────────────────────
for provider in aws kubernetes helm random time; do
  constraint="$(read_provider_constraint "$provider")"
  latest="$(curl -sf --max-time 15 "https://registry.terraform.io/v1/providers/hashicorp/$provider" | jq -r '.version // "unknown"')" || latest="unknown"
  echo "provider/$provider: constraint \"$constraint\", latest $latest"
done

echo

# ── CLI tools this repo's CI pins ─────────────────────────────────────────────
# terraform/tflint/checkov/markdownlint are each pinned via a top-level env
# var this repo's other tooling also reads (see terraform-tests.yml); helm and
# terraform-docs are pinned differently (a step's `version:` input and a
# job-level env var respectively) and are extracted separately below rather
# than forced through this list.
#
# A `tool|repo|env` list read line by line, not `declare -A`: associative
# arrays are bash >= 4 only, and stock macOS ships bash 3.2, where `declare
# -A` fails and the later lookups die under `set -u`. Same portability rule
# check-helm-chart-coverage.sh follows for `mapfile`.
WORKFLOW=".github/workflows/terraform-tests.yml"
while IFS='|' read -r tool repo env_name; do
  pinned="$(sed -n "s/^[[:space:]]*${env_name}:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$WORKFLOW" | head -1)"
  latest="$(curl -sf --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // "unknown"')" || latest="unknown"
  echo "cli/$tool: pinned $pinned, latest $latest"
done <<'EOF'
terraform|hashicorp/terraform|TF_VERSION
tflint|terraform-linters/tflint|TFLINT_VERSION
checkov|bridgecrewio/checkov|CHECKOV_VERSION
markdownlint|igorshubovych/markdownlint-cli|MARKDOWNLINT_VERSION
EOF

# Scoped to the line(s) right after a `uses: azure/setup-helm@` step rather
# than the first "version:" anywhere in the file: a generic whole-file match
# would silently start reporting an unrelated step's version input the
# moment one is added earlier in the file.
pinned_helm="$(awk '
  /uses:[[:space:]]*azure\/setup-helm@/ { want = 1; next }
  want && /version:/ {
    if (match($0, /v[0-9][^[:space:]]*/)) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  }
' "$WORKFLOW")"
latest_helm="$(curl -sf --max-time 15 "https://api.github.com/repos/helm/helm/releases/latest" | jq -r '.tag_name // "unknown"')" || latest_helm="unknown"
echo "cli/helm: pinned $pinned_helm, latest $latest_helm"

pinned_tfdocs="$(sed -n 's/^[[:space:]]*TERRAFORM_DOCS_VERSION:[[:space:]]*\(v[0-9][^[:space:]]*\)/\1/p' "$WORKFLOW" | head -1)"
latest_tfdocs="$(curl -sf --max-time 15 "https://api.github.com/repos/terraform-docs/terraform-docs/releases/latest" | jq -r '.tag_name // "unknown"')" || latest_tfdocs="unknown"
echo "cli/terraform-docs: pinned $pinned_tfdocs, latest $latest_tfdocs"

echo

# ── Helm charts this module installs ──────────────────────────────────────────
n8n_chart_version="$(read_default n8n_chart_version variables.tf)"
n8n_latest="$(curl -sf --max-time 15 "https://api.github.com/repos/n8n-io/n8n-hosting/tags?per_page=1" | jq -r '.[0].name // "unknown"' | sed 's/^v//')" || n8n_latest="unknown"
echo "chart/n8n: pinned $n8n_chart_version, latest tag $n8n_latest"

# `key|variable|index url|entry name`, read line by line for the same bash
# 3.2 reason as the CLI list above.
while IFS='|' read -r key var_name url entry_name; do
  pinned="$(read_default "$var_name" variables.tf)"
  # Fetch first, parse second: awk exits on the first match, and under
  # pipefail a `curl | awk` pipeline would then report curl's SIGPIPE as a
  # failure and mask a perfectly good answer as "unknown".
  index="$(curl -sf --max-time 15 "$url")" || index=""
  # First "version:" line under this chart's entries block: the repository
  # index lists newest first, so it is the latest published version.
  latest="$(printf '%s\n' "$index" | awk -v name="$entry_name" '
    $0 ~ "^  " name ":" { in_block = 1; next }
    in_block && /^  [A-Za-z]/ { exit }
    in_block && /version:/ {
      sub(/^ *version: */, "")
      print
      exit
    }
  ')"
  echo "chart/$key: pinned $pinned, latest ${latest:-unknown}"
done <<'EOF'
lbc|lbc_chart_version|https://aws.github.io/eks-charts/index.yaml|aws-load-balancer-controller
cluster-autoscaler|cluster_autoscaler_chart_version|https://kubernetes.github.io/autoscaler/index.yaml|cluster-autoscaler
metrics-server|metrics_server_chart_version|https://kubernetes-sigs.github.io/metrics-server/index.yaml|metrics-server
keda|keda_chart_version|https://kedacore.github.io/charts/index.yaml|keda
EOF

echo

# ── EKS-supported Kubernetes versions ─────────────────────────────────────────
# endoflife.date aggregates AWS's own EKS release-calendar docs into a public,
# unauthenticated JSON API, keyed by Kubernetes minor. That is a genuine
# public API despite AWS itself not offering one for this: this is the
# exception to the "cannot see EKS versions" note this script used to carry,
# and to docs/versioning.md's matching entry. It still cannot prove a version
# is creatable in one specific account and region (only the credentialed
# `aws eks describe-cluster-versions` answers that), so both remain the
# authoritative check before a live account-scoped bump.
pinned_k8s="$(read_default kubernetes_version variables.tf)"
eks_releases="$(curl -sf --max-time 15 "https://endoflife.date/api/v1/products/amazon-eks")" || eks_releases=""
if [[ -n "$eks_releases" ]]; then
  latest_k8s="$(echo "$eks_releases" | jq -r '.result.releases[0].name // "unknown"')"
  pinned_eol="$(echo "$eks_releases" | jq -r --arg v "$pinned_k8s" '.result.releases[] | select(.name == $v) | .isEol')"
else
  latest_k8s="unknown"
  pinned_eol=""
fi
echo "eks/kubernetes_version: pinned $pinned_k8s (isEol: ${pinned_eol:-unknown}), latest $latest_k8s"

echo
echo "See docs/versioning.md for the bump policy and what this report cannot see."
exit 0
