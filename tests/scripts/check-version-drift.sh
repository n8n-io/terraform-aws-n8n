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
#   - checkov's CKV_AWS_339 EKS version allow-list (checkov source on
#     raw.githubusercontent.com, at the pinned CHECKOV_VERSION and at the
#     latest release), which decides whether a kubernetes_version gap is the
#     known #158 hold or real drift
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

# shellcheck disable=SC1091 # path is $SCRIPT_DIR-relative, resolved at runtime, not statically
source "$SCRIPT_DIR/lib/tf-defaults.sh"

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
  latest_k8s="$(jq -r '.result.releases[0].name // empty' <<<"$eks_releases" 2>/dev/null)"
  pinned_eol="$(jq -r --arg v "$pinned_k8s" 'first(.result.releases[] | select(.name == $v) | .isEol | tostring)' <<<"$eks_releases" 2>/dev/null)"
else
  latest_k8s=""
  pinned_eol=""
fi
# Only trust what parsed into the expected shape. Anything else is reported
# as unknown, which keeps the line in the drift list: uncertain data must
# never be read as proof that the #158 hold applies.
[[ "$latest_k8s" =~ ^[0-9]+\.[0-9]+$ ]] || latest_k8s="unknown"
[[ "$pinned_eol" == "true" || "$pinned_eol" == "false" ]] || pinned_eol=""
known_holds=""
k8s_line="eks/kubernetes_version: pinned $pinned_k8s (isEol: ${pinned_eol:-unknown}), latest $latest_k8s"

# Known hold (#158): kubernetes_version waits for the pinned checkov's
# CKV_AWS_339 allow-list to include the next minor above the pin
# (docs/versioning.md). Read that list at the exact CHECKOV_VERSION CI runs.
# Check the next minor, not endoflife.date's latest: if upstream moves two
# minors ahead first, testing the latest would miss the moment the next one
# becomes allowed.
#
# The line moves to the known-holds section only when every input is
# definite: a valid latest minor, a boolean isEol of false, and a parsed
# pinned allow-list without the next minor, with no newer checkov release
# that allows it. Otherwise it stays in the drift list:
#   - isEol true (endoflife.date's flag for the end of EKS standard support)
#     is ACTIONABLE on its own, whatever checkov says or whether the latest
#     minor could be read.
#   - the pinned checkov allowing the next minor is ACTIONABLE.
#   - a newer checkov release allowing it is ACTIONABLE: bump CHECKOV_VERSION.
#   - an unreadable EKS list, isEol flag or pinned allow-list adds a note
#     instead of hiding the line. Only the optional latest-checkov lookup may
#     fail quietly: the pinned answer alone is definitive for the hold.
ckv_allows() {
  # $1: checkov git tag, $2: Kubernetes minor. Prints yes, no, or unknown.
  # Accepts only the exact shape the check uses today: one line holding a
  # complete list literal of quoted major.minor strings and nothing else.
  # Anything else (a list split across lines, a truncated list, a trailing
  # comment) is unknown rather than no, so a format change upstream surfaces
  # as a note in the drift list instead of a silent hold.
  local src line list
  [[ -n "$1" ]] || { echo unknown; return; }
  src="$(curl -sf --max-time 15 "https://raw.githubusercontent.com/bridgecrewio/checkov/$1/checkov/terraform/checks/resource/aws/EKSPlatformVersion.py")" || src=""
  line="$(grep -E '^[[:space:]]*return[[:space:]]*\[' <<<"$src")"
  list=""
  if [[ "$(grep -c . <<<"$line")" == 1 ]] \
    && grep -qE '^[[:space:]]*return[[:space:]]*\[[[:space:]]*"[0-9]+\.[0-9]+"([[:space:]]*,[[:space:]]*"[0-9]+\.[0-9]+")*[[:space:]]*,?[[:space:]]*\][[:space:]]*$' <<<"$line"; then
    list="$(grep -oE '"[0-9]+\.[0-9]+"' <<<"$line" | tr -d '"')"
  fi
  if [[ -z "$list" ]]; then
    echo unknown
  elif grep -qxF "$2" <<<"$list"; then
    echo yes
  else
    echo no
  fi
}

if [[ "$pinned_eol" == "true" ]]; then
  k8s_line+=$'\n'"  ACTIONABLE: pinned $pinned_k8s is past the end of EKS standard support, so the checkov hold tracked in #158 no longer justifies staying on it."
elif [[ "$latest_k8s" == "unknown" ]]; then
  k8s_line+=$'\n'"  note: could not read the EKS release list from endoflife.date."
elif [[ "$latest_k8s" != "$pinned_k8s" ]]; then
  next_k8s="${pinned_k8s%.*}.$(( ${pinned_k8s#*.} + 1 ))"
  pinned_checkov="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
  pinned_allows="$(ckv_allows "$pinned_checkov" "$next_k8s")"
  if [[ -z "$pinned_eol" ]]; then
    k8s_line+=$'\n'"  note: could not read isEol for $pinned_k8s from endoflife.date, so the #158 hold is not applied."
  elif [[ "$pinned_allows" == "unknown" ]]; then
    k8s_line+=$'\n'"  note: could not read or parse CKV_AWS_339 at checkov $pinned_checkov to confirm the #158 hold."
  elif [[ "$pinned_allows" == "yes" ]]; then
    k8s_line+=$'\n'"  ACTIONABLE: checkov $pinned_checkov's CKV_AWS_339 now allows $next_k8s, so the hold tracked in #158 is lifted."
  else
    latest_checkov="$(curl -sf --max-time 15 "https://api.github.com/repos/bridgecrewio/checkov/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)" || latest_checkov=""
    if [[ -n "$latest_checkov" && "$latest_checkov" != "$pinned_checkov" && "$(ckv_allows "$latest_checkov" "$next_k8s")" == "yes" ]]; then
      k8s_line+=$'\n'"  ACTIONABLE: checkov $latest_checkov's CKV_AWS_339 allows $next_k8s. Bump CHECKOV_VERSION from $pinned_checkov to lift the hold tracked in #158."
    else
      # Held: drop it from the drift list and report it under known holds.
      known_holds+="- eks/kubernetes_version: pinned $pinned_k8s (isEol: $pinned_eol), latest $latest_k8s. Known and expected: checkov $pinned_checkov's CKV_AWS_339 does not allow $next_k8s yet. Open issue: https://github.com/n8n-io/terraform-aws-n8n/issues/158"$'\n'
      k8s_line=""
    fi
  fi
fi
[[ -n "$k8s_line" ]] && echo "$k8s_line"

# A held k8s line prints nothing above, and the chart section already ends on
# a blank line, so the heading needs no blank line of its own before it.
if [[ -n "$known_holds" ]]; then
  echo "## Known and expected (not actionable)"
  echo
  printf '%s' "$known_holds"
fi

echo
echo "See docs/versioning.md for the bump policy and what this report cannot see."
exit 0
