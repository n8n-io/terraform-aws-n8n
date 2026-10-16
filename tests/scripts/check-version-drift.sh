#!/usr/bin/env bash
# check-version-drift.sh: report every pin that has fallen behind upstream.
#
# Each pin is classified DRIFT / OK / ERROR (ported from the sibling
# terraform-google-n8n module's check-version-drift.sh,
# n8n-io/terraform-google-n8n#36, for a consistent report shape across the
# three Terraform modules):
#   DRIFT: the pin is behind upstream, or (for a Terraform provider) its
#          constraint no longer admits the latest release.
#   OK:    the pin matches upstream, or its constraint already admits the
#          latest release.
#   ERROR: the upstream lookup failed, or this script cannot evaluate the
#          pin's form (e.g. a provider constraint that isn't a single
#          "~> N[.N[.N]]" range). Printed to both stdout and stderr: stdout
#          so it lands in the report this script's only consumer syncs to a
#          tracking issue (see "Why this still exits 0" below), stderr so it
#          is also visible immediately in CI logs. Never reported as quiet
#          "up to date": an unreadable pin and a current one must never
#          look the same. One exception, inherited from before this
#          classification: the optional lookup of the latest checkov release
#          behind the #158 hold. If it fails, the line stays under "Known and
#          expected" (the pinned checkov's CKV_AWS_339 is what holds it) and
#          that run skips the early warning that a newer checkov release
#          allows the next minor.
# A one-line summary count closes the report: "N pin(s) behind upstream, M
# error(s)". M counts every ERROR, whether a failed upstream lookup or a pin
# this script cannot evaluate, so it is not a count of failed lookups (the
# sibling's "M lookup(s) failed" wording would overstate that). The #158
# kubernetes_version hold is the one pin that carries no classification: it is
# not actionable, so it is listed separately under "Known and expected" and
# counted in neither total.
#
# Why this still exits 0 (unlike the sibling, which exits 2 on any lookup
# failure): .github/workflows/version-drift.yml pipes this script straight
# into `tee -a report.md "$GITHUB_STEP_SUMMARY"`, and `shell: bash` on that
# step adds `-o pipefail`. A later, unguarded step (no `if: always()`) syncs
# report.md to a single tracking issue, the only place this report is
# actually read day to day. A non-zero exit here would fail the first step,
# and GitHub Actions would then skip the sync step entirely: the one
# successful run that found a lookup failure would silently stop updating
# the tracking issue and leave it showing a stale report, replaced by a bare
# failed Actions run nobody watches. Every ERROR line is already visible in
# the synced issue body via stdout, so the exit code would only subtract
# information here. Revisit this if the workflow's sync step ever gains
# `if: always()`.
#
# Checks pins reachable from public, unauthenticated APIs:
#   - Terraform providers (registry.terraform.io), constraint-aware: a
#     "~> N[.N[.N]]" constraint that already admits the latest release is OK,
#     not drift (this repo's five provider constraints, e.g. "~> 6.0", admit
#     a wide range of latest releases by design). Any other constraint form
#     (an exact pin, ">=", a comma-separated combination, ...) cannot be
#     evaluated this way and is reported as an explicit ERROR asking for a
#     manual compare, never silently as OK.
#   - CLI tools this repo's CI pins (GitHub releases)
#   - Helm charts: the four controller charts against their own chart
#     repositories' index.yaml; the n8n chart against its own
#     oci://ghcr.io/n8n-io/n8n-helm-chart registry's anonymous tag list (a
#     short-lived unauthenticated token plus the Docker Distribution
#     `tags/list` API; ghcr.io does expose a public, unauthenticated tag
#     index, and an earlier version of this script read n8n-io/n8n-hosting's
#     latest Git tag instead and claimed the OCI registry had "no equivalent
#     public index", which was wrong). Only plain X.Y.Z tags count: the
#     registry also carries prereleases (e.g.
#     "1.11.0-preview.workerpools.1") and non-version tags ("artifacthub.io",
#     "sha256-..." digests), none of which is the "latest numbered release"
#     this check reports against. A Git tag can also exist before the chart
#     is actually published to GHCR, so the registry is the more accurate
#     source of what is actually pullable.
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

WORKFLOW=".github/workflows/terraform-tests.yml"

drift_count=0
error_count=0

report_drift() { echo "DRIFT: $1"; drift_count=$((drift_count + 1)); }
report_ok()    { echo "OK:    $1"; }
report_error() {
  # Printed to both streams; see the header comment "Why this still exits 0".
  echo "ERROR: $1"
  echo "ERROR: $1" >&2
  error_count=$((error_count + 1))
}

# $1: pin label (e.g. "cli/terraform"). $2: pinned version. $3: latest
# version, or empty if the upstream lookup failed. Tolerates a "v" prefix on
# either side (GitHub tag names carry one; this repo's pins sometimes do,
# sometimes don't) so that is never reported as drift on its own.
compare_pin() {
  local label="$1" pinned="$2" latest="$3"
  if [[ -z "$pinned" ]]; then
    report_error "$label: could not read the pinned version"
    return
  fi
  if [[ -z "$latest" ]]; then
    report_error "$label: upstream lookup failed"
    return
  fi
  if [[ "${pinned#v}" == "${latest#v}" ]]; then
    report_ok "$label: pinned $pinned matches latest $latest"
  else
    report_drift "$label: pinned $pinned, latest $latest"
  fi
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

# $1: dotted version (up to 3 segments, e.g. "6.68.0"); missing trailing
# segments count as 0. Prints a fixed-width, directly comparable string.
numify() {
  local v="$1"
  local IFS=.
  local -a p
  read -r -a p <<<"$v"
  printf '%05d%05d%05d' "${p[0]:-0}" "${p[1]:-0}" "${p[2]:-0}"
}

# $1: provider constraint (e.g. "~> 6.0"). $2: latest release (e.g.
# "6.68.0"). Prints yes/no when the constraint admits/excludes the latest
# release, or "unknown" when this script cannot evaluate the constraint's
# form, so the caller reports an explicit ERROR instead of guessing.
#
# Only a single "~> N[.N[.N]]" constraint is understood. Per Terraform's
# pessimistic-constraint-operator semantics
# (https://developer.hashicorp.com/terraform/language/expressions/version-constraints):
# everything but the rightmost given component is frozen, and the rightmost
# given component is free to increase. So "~> 6.0" admits any 6.x.y (only
# the major, 6, is frozen) and "~> 1.2.3" admits any 1.2.z (the major and
# minor, 1 and 2, are frozen). A bare "~> N" (one segment) freezes nothing
# and admits any N.x.y. Any other constraint form (an exact pin, ">=", a
# comma-separated combination, ...) is "unknown": say so rather than
# evaluate it wrong.
provider_admits_latest() {
  local constraint="$1" latest="$2"
  [[ "$constraint" =~ ^~[\>][[:space:]]*([0-9]+(\.[0-9]+){0,2})$ ]] || { echo unknown; return; }
  local spec="${BASH_REMATCH[1]}"
  [[ "$latest" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo unknown; return; }
  local IFS=.
  local -a segs
  read -r -a segs <<<"$spec"
  local n=${#segs[@]}
  local -a lower=(0 0 0) upper=(0 0 0)
  local i
  for ((i = 0; i < n; i++)); do lower[i]=${segs[i]}; done
  if (( n == 1 )); then
    upper=( $(( 10#${segs[0]} + 1 )) 0 0 )
  else
    local fixed=$(( n - 1 ))
    for ((i = 0; i < fixed - 1; i++)); do upper[i]=${segs[i]}; done
    upper[fixed - 1]=$(( 10#${segs[fixed - 1]} + 1 ))
  fi
  local lower_n upper_n latest_n
  lower_n="$(numify "${lower[0]}.${lower[1]}.${lower[2]}")"
  upper_n="$(numify "${upper[0]}.${upper[1]}.${upper[2]}")"
  latest_n="$(numify "$latest")"
  if (( 10#$latest_n >= 10#$lower_n && 10#$latest_n < 10#$upper_n )); then
    echo yes
  else
    echo no
  fi
}

echo "## Version drift report"
echo

# ── Terraform providers ───────────────────────────────────────────────────────
for provider in aws kubernetes helm random time; do
  constraint="$(read_provider_constraint "$provider")"
  if [[ -z "$constraint" ]]; then
    report_error "provider/$provider: could not read the version constraint from versions.tf"
    continue
  fi
  latest="$(curl -sf --max-time 15 "https://registry.terraform.io/v1/providers/hashicorp/$provider" | jq -r '.version // empty')" || latest=""
  if [[ -z "$latest" ]]; then
    report_error "provider/$provider: constraint \"$constraint\", registry.terraform.io lookup failed"
    continue
  fi
  # Checked here, not only inside provider_admits_latest, so a prerelease or
  # otherwise unexpected "latest" is reported as such rather than blamed on
  # the constraint.
  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    report_error "provider/$provider: registry.terraform.io returned latest \"$latest\", which is not a plain X.Y.Z release; compare constraint \"$constraint\" by hand"
    continue
  fi
  case "$(provider_admits_latest "$constraint" "$latest")" in
    yes) report_ok "provider/$provider: constraint \"$constraint\" already admits latest $latest" ;;
    no)  report_drift "provider/$provider: constraint \"$constraint\" does not admit latest $latest" ;;
    *)   report_error "provider/$provider: constraint \"$constraint\" is not a single \"~> N[.N[.N]]\" range; cannot evaluate automatically against latest $latest, compare by hand" ;;
  esac
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
while IFS='|' read -r tool repo env_name; do
  pinned="$(sed -n "s/^[[:space:]]*${env_name}:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$WORKFLOW" | head -1)"
  latest="$(curl -sf --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty')" || latest=""
  compare_pin "cli/$tool" "$pinned" "$latest"
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
latest_helm="$(curl -sf --max-time 15 "https://api.github.com/repos/helm/helm/releases/latest" | jq -r '.tag_name // empty')" || latest_helm=""
compare_pin "cli/helm" "$pinned_helm" "$latest_helm"

pinned_tfdocs="$(sed -n 's/^[[:space:]]*TERRAFORM_DOCS_VERSION:[[:space:]]*\(v[0-9][^[:space:]]*\)/\1/p' "$WORKFLOW" | head -1)"
latest_tfdocs="$(curl -sf --max-time 15 "https://api.github.com/repos/terraform-docs/terraform-docs/releases/latest" | jq -r '.tag_name // empty')" || latest_tfdocs=""
compare_pin "cli/terraform-docs" "$pinned_tfdocs" "$latest_tfdocs"

echo

# ── Helm charts this module installs ──────────────────────────────────────────
n8n_chart_version="$(read_default n8n_chart_version variables.tf)"
n8n_token="$(curl -sf --max-time 15 "https://ghcr.io/token?scope=repository:n8n-io/n8n-helm-chart/n8n:pull&service=ghcr.io" | jq -r '.token // empty' 2>/dev/null)" || n8n_token=""
if [[ -z "$n8n_token" ]]; then
  report_error "chart/n8n: ghcr.io anonymous token request failed"
else
  # tags/list paginates (a `Link: <...>; rel="next"` header). Ask for a page
  # far larger than the tag count, and treat a Link header as an ERROR: a
  # truncated list would silently drop the newest tags and could read as OK.
  # `-i` keeps the headers; the body is the part after the first blank line.
  n8n_resp="$(curl -sf -i --max-time 15 -H "Authorization: Bearer $n8n_token" "https://ghcr.io/v2/n8n-io/n8n-helm-chart/n8n/tags/list?n=1000" | tr -d '\r')" || n8n_resp=""
  n8n_link="$(printf '%s\n' "$n8n_resp" | awk 'NF == 0 { exit } tolower($1) == "link:" { print }')"
  n8n_tags="$(printf '%s\n' "$n8n_resp" | awk 'body { print } NF == 0 { body = 1 }' | jq -r '.tags[]?' 2>/dev/null)" || n8n_tags=""
  # Keep only plain X.Y.Z release tags; see the header comment for why.
  n8n_latest="$(printf '%s\n' "$n8n_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  if [[ -n "$n8n_link" ]]; then
    report_error "chart/n8n: ghcr.io tag list is paginated and this script reads only the first page, so the latest release may be missing"
  elif [[ -z "$n8n_latest" ]]; then
    report_error "chart/n8n: ghcr.io tag list lookup failed or returned no numbered release tags"
  else
    compare_pin "chart/n8n" "$n8n_chart_version" "$n8n_latest"
  fi
fi

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
  compare_pin "chart/$key" "$pinned" "$latest"
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
# as an ERROR, which keeps the line out of both "OK" and the #158 hold:
# uncertain data must never be read as proof that the hold applies.
[[ "$latest_k8s" =~ ^[0-9]+\.[0-9]+$ ]] || latest_k8s="unknown"
[[ "$pinned_eol" == "true" || "$pinned_eol" == "false" ]] || pinned_eol=""
k8s_detail="eks/kubernetes_version: pinned $pinned_k8s (isEol: ${pinned_eol:-unknown}), latest $latest_k8s"

# Known hold (#158): kubernetes_version waits for the pinned checkov's
# CKV_AWS_339 allow-list to include the next minor above the pin
# (docs/versioning.md). Read that list at the exact CHECKOV_VERSION CI runs.
# Check the next minor, not endoflife.date's latest: if upstream moves two
# minors ahead first, testing the latest would miss the moment the next one
# becomes allowed.
#
# The line moves to the known-holds section (and out of the DRIFT/OK/ERROR
# counts below, because "not actionable" means exactly that) only when every input
# is definite: a valid latest minor, a boolean isEol of false, and a parsed
# pinned allow-list without the next minor, with no newer checkov release
# that allows it. Otherwise it is DRIFT or ERROR:
#   - isEol true (endoflife.date's flag for the end of EKS standard support)
#     is DRIFT (ACTIONABLE) on its own, whatever checkov says or whether the
#     latest minor could be read.
#   - the pinned checkov allowing the next minor is DRIFT (ACTIONABLE).
#   - a newer checkov release allowing it is DRIFT (ACTIONABLE): bump
#     CHECKOV_VERSION.
#   - an unreadable EKS list, isEol flag or pinned allow-list is an ERROR
#     instead of a silent hold. Only the optional latest-checkov lookup may
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

known_holds=""
if [[ "$pinned_eol" == "true" ]]; then
  report_drift "$k8s_detail; ACTIONABLE: pinned $pinned_k8s is past the end of EKS standard support, so the checkov hold tracked in #158 no longer justifies staying on it"
elif [[ "$latest_k8s" == "unknown" ]]; then
  report_error "$k8s_detail; could not read the EKS release list from endoflife.date"
elif [[ -z "$pinned_eol" ]]; then
  report_error "$k8s_detail; could not read isEol for $pinned_k8s from endoflife.date, so the #158 hold is not applied"
elif [[ "$latest_k8s" == "$pinned_k8s" ]]; then
  report_ok "$k8s_detail"
else
  next_k8s="${pinned_k8s%.*}.$(( ${pinned_k8s#*.} + 1 ))"
  pinned_checkov="$(sed -n 's/^[[:space:]]*CHECKOV_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORKFLOW" | head -1)"
  pinned_allows="$(ckv_allows "$pinned_checkov" "$next_k8s")"
  if [[ "$pinned_allows" == "unknown" ]]; then
    report_error "$k8s_detail; could not read or parse CKV_AWS_339 at checkov $pinned_checkov to confirm the #158 hold"
  elif [[ "$pinned_allows" == "yes" ]]; then
    report_drift "$k8s_detail; ACTIONABLE: checkov $pinned_checkov's CKV_AWS_339 now allows $next_k8s, so the hold tracked in #158 is lifted"
  else
    latest_checkov="$(curl -sf --max-time 15 "https://api.github.com/repos/bridgecrewio/checkov/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null)" || latest_checkov=""
    if [[ -n "$latest_checkov" && "$latest_checkov" != "$pinned_checkov" && "$(ckv_allows "$latest_checkov" "$next_k8s")" == "yes" ]]; then
      report_drift "$k8s_detail; ACTIONABLE: checkov $latest_checkov's CKV_AWS_339 allows $next_k8s. Bump CHECKOV_VERSION from $pinned_checkov to lift the hold tracked in #158"
    else
      # Held: not actionable, reported separately below, not counted as
      # DRIFT or ERROR.
      known_holds+="- eks/kubernetes_version: pinned $pinned_k8s (isEol: $pinned_eol), latest $latest_k8s. Known and expected: checkov $pinned_checkov's CKV_AWS_339 does not allow $next_k8s yet. Open issue: https://github.com/n8n-io/terraform-aws-n8n/issues/158"$'\n'
    fi
  fi
fi

# Every section above already ends on a blank line, so the heading needs no
# blank line of its own before it.
if [[ -n "$known_holds" ]]; then
  echo "## Known and expected (not actionable)"
  echo
  printf '%s' "$known_holds"
fi

echo
echo "check-version-drift.sh: ${drift_count} pin(s) behind upstream, ${error_count} error(s)"
echo
echo "See docs/versioning.md for the bump policy and what this report cannot see."
exit 0
