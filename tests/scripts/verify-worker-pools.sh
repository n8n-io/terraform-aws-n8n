#!/usr/bin/env bash
# verify-worker-pools.sh: post-deployment verification for n8n_worker_pools.
#
# Companion to smoke-test.sh, for deployments that declare n8n_worker_pools.
#
# smoke-test.sh answers "is this deployment healthy". This answers a question
# nothing at plan time can: did the chart actually render the pools. A chart
# that predates queueMode.workerGroups has no additionalProperties: false on
# queueMode, so Helm accepts the key, renders nothing for it, and the release
# succeeds. N8N_WORKER_POOLS_ENABLED lands on every pod, no pool Deployment or
# ScaledObject exists, and every project pinned to a pool quietly runs on the
# default queue. The mocked helm provider in the plan-time suite accepts any
# values at all, so counting rendered Deployments after a live apply is the only
# place that failure is visible.
#
# CI cannot run this: it needs a live cluster. Same manual-verification tier as
# smoke-test.sh and verify-custom-image.sh.
#
# Usage:
#   # Run from an example directory whose outputs include worker_pool_names
#   # (examples/worker-pools does); namespace and pools are read automatically:
#   cd examples/worker-pools
#   ../../tests/scripts/verify-worker-pools.sh
#
#   # Or point at a Terraform directory explicitly:
#   TERRAFORM_DIR=examples/worker-pools ./tests/scripts/verify-worker-pools.sh
#
#   # Or name the pools yourself, for a root module without that output:
#   WORKER_POOLS="heavy secteam itop" NAMESPACE=n8n ./tests/scripts/verify-worker-pools.sh
#
# Settings (env, or .env next to this script, in TERRAFORM_DIR, or in the
# current directory; an explicit env value wins over the file):
#   WORKER_POOLS   space-separated pool names to expect (default: the
#                  worker_pool_names output)
#   NAMESPACE      Kubernetes namespace (default: the namespace output, then n8n)
#   RELEASE_NAME   Helm release name the module fixes (default: n8n). Pool
#                  resources are named <RELEASE_NAME>-worker-<pool>.
#
# Priority: explicit env > Terraform outputs > built-in defaults.

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
# Candidates: next to this script, in TERRAFORM_DIR, in the current directory.
# TERRAFORM_DIR is resolved first so a .env kept beside the Terraform files is
# found when the script is run from elsewhere. Values already in the
# environment win over the file, matching the documented priority: the file
# is a convenience for defaults, not an override of an explicit choice.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-$(pwd)}"

_explicit_pools="${WORKER_POOLS-__unset__}"
_explicit_ns="${NAMESPACE-__unset__}"
_explicit_release="${RELEASE_NAME-__unset__}"
_explicit_tfdir="$TERRAFORM_DIR"

for _env_candidate in "$SCRIPT_DIR/.env" "$TERRAFORM_DIR/.env" "$(pwd)/.env"; do
  if [[ -f "$_env_candidate" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$_env_candidate"; set +a
    break
  fi
done

[[ "$_explicit_pools" != "__unset__" ]] && WORKER_POOLS="$_explicit_pools"
[[ "$_explicit_ns" != "__unset__" ]] && NAMESPACE="$_explicit_ns"
[[ "$_explicit_release" != "__unset__" ]] && RELEASE_NAME="$_explicit_release"
# Also the directory itself: a .env that sets TERRAFORM_DIR would otherwise
# redirect state reads and the kubectl context switch to a different deployment
# than the one the caller named.
TERRAFORM_DIR="$_explicit_tfdir"

# ── Read from Terraform outputs ───────────────────────────────────────────────

# .terraform/, not terraform.tfstate: a remote backend leaves no local state
# file, but still leaves .terraform/ behind after init, so this works for
# both.
if command -v terraform &>/dev/null && [[ -d "$TERRAFORM_DIR/.terraform" ]]; then
  echo -e "\033[0;36m↳\033[0m  Reading values from Terraform state in: $TERRAFORM_DIR"

  tf_namespace=$(terraform -chdir="$TERRAFORM_DIR" output -raw namespace 2>/dev/null || true)
  tf_kubectl_cmd=$(terraform -chdir="$TERRAFORM_DIR" output -raw kubectl_config_command 2>/dev/null || true)
  # A list output: -json, then strip the JSON down to a space-separated list
  # without depending on jq. Names are already validated to [a-z0-9-] by the
  # module, so the character class below cannot mangle one.
  tf_pools=$(terraform -chdir="$TERRAFORM_DIR" output -json worker_pool_names 2>/dev/null \
    | tr -d '[]"\n' | tr ',' ' ' || true)

  # Unset-only fallback: an explicit NAMESPACE="" or WORKER_POOLS="" from the
  # caller (preserved above from _explicit_ns/_explicit_pools) is a real
  # choice, distinct from never having set it, and must not be replaced by
  # Terraform's value.
  NAMESPACE="${NAMESPACE-$tf_namespace}"
  WORKER_POOLS="${WORKER_POOLS-$tf_pools}"

  echo -e "\033[0;36m↳\033[0m  namespace    = ${NAMESPACE:-<not found>}"
  echo -e "\033[0;36m↳\033[0m  worker pools = ${WORKER_POOLS:-<not found>}"

  # Point kubectl at this deployment's cluster. A failure here is fatal: the
  # alternative is verifying whatever cluster the previous context pointed at
  # and reporting it as this one, which is worse than no result.
  if [[ -n "$tf_kubectl_cmd" ]]; then
    echo -e "\033[0;36m↳\033[0m  Switching kubectl context: $tf_kubectl_cmd"
    if ! eval "$tf_kubectl_cmd" &>/dev/null; then
      echo -e "\033[0;31mERROR: could not switch kubectl context with: $tf_kubectl_cmd\033[0m" >&2
      echo "Refusing to verify against whichever cluster the current context points at." >&2
      exit 1
    fi
  fi

  echo ""
fi

# ── Configuration ─────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-n8n}"
RELEASE_NAME="${RELEASE_NAME:-n8n}"
WORKER_POOLS="${WORKER_POOLS:-}"

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── State ─────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
WARN=0
SKIPPED=0

# ── Helpers ───────────────────────────────────────────────────────────────────

header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
pass()   { echo -e "  ${GREEN}✔${RESET}  $*"; PASS=$((PASS + 1)); }
fail()   { echo -e "  ${RED}✘${RESET}  $*"; FAIL=$((FAIL + 1)); }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $*"; WARN=$((WARN + 1)); }
skip()   { echo -e "  ${YELLOW}–${RESET}  $* ${YELLOW}(skipped)${RESET}"; SKIPPED=$((SKIPPED + 1)); }
info()   { echo -e "      ${CYAN}↳${RESET} $*"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}ERROR: required command '$1' not found.${RESET}" >&2
    exit 1
  fi
}

summarize_and_exit() {
  echo ""
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Worker Pools Verification Summary${RESET}"
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo -e "  ${GREEN}Passed:${RESET}  $PASS"
  echo -e "  ${RED}Failed:${RESET}  $FAIL"
  echo -e "  ${YELLOW}Warnings:${RESET} $WARN"
  echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
  echo ""

  if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}${BOLD}RESULT: FAIL. $FAIL check(s) did not pass.${RESET}"
    exit 1
  fi
  echo -e "${GREEN}${BOLD}RESULT: PASS${RESET}"
  exit 0
}

# Value of one env var on the n8n container of a Deployment's pod template.
# Only literal `value` entries: the module renders pool and feature-flag vars
# that way, so a valueFrom here would itself be a surprise. Exit status is
# kubectl's own (see trigger_field above); a caller that already knows the
# Deployment exists must check it, not read an error the same as "unset".
deploy_env() {
  local deploy="$1" var="$2"
  kubectl get deploy -n "$NAMESPACE" "$deploy" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name==\"n8n-worker\")].env[?(@.name==\"$var\")].value}{.spec.template.spec.containers[?(@.name==\"n8n-main\")].env[?(@.name==\"$var\")].value}{.spec.template.spec.containers[?(@.name==\"n8n\")].env[?(@.name==\"$var\")].value}" \
    2>/dev/null
}

# Whole ScaledObject as JSON, empty if absent.
scaledobject_json() {
  kubectl get scaledobject -n "$NAMESPACE" "$1" -o json 2>/dev/null || true
}

# Pull a top-level trigger metadata field out of ScaledObject JSON for trigger
# index $2, without jq: the KEDA CRD is regular enough for a targeted jsonpath.
# Exit status is kubectl's own: a nonzero exit is always a real failure (the
# object vanished, RBAC, a network blip), never "field absent" -- kubectl's
# jsonpath prints empty output but still exits 0 when the object exists and
# the path inside it does not. Callers that already know the object exists
# must not swallow a nonzero exit into an empty string, or a transient error
# reads the same as an unset field.
trigger_field() {
  local so="$1" idx="$2" field="$3"
  kubectl get scaledobject -n "$NAMESPACE" "$so" \
    -o jsonpath="{.spec.triggers[$idx].metadata.$field}" 2>/dev/null
}

so_condition() {
  local so="$1" type="$2"
  kubectl get scaledobject -n "$NAMESPACE" "$so" \
    -o jsonpath="{.status.conditions[?(@.type==\"$type\")].status}" 2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────

require_cmd kubectl

header "Preflight"

if [[ -z "$WORKER_POOLS" ]]; then
  echo -e "${RED}ERROR: no pools to verify.${RESET}" >&2
  echo "Set WORKER_POOLS=\"heavy secteam itop\" or run from a Terraform directory whose outputs include worker_pool_names." >&2
  exit 1
fi

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  fail "namespace $NAMESPACE not reachable (is kubectl pointed at this cluster?)"
  summarize_and_exit
fi
pass "namespace $NAMESPACE reachable"

if kubectl get crd scaledobjects.keda.sh &>/dev/null; then
  pass "KEDA ScaledObject CRD installed"
else
  fail "scaledobjects.keda.sh CRD missing: KEDA is not installed, so no pool can scale"
fi

# The chart labels pool resources component=worker-group, deliberately not
# `worker`: the default worker Deployment's selector is immutable and must not
# match pool pods. Counting on that label is the whole point of this script.
# Every label lookup also carries app.kubernetes.io/instance=$RELEASE_NAME, so
# a second release or a stale pool in the same namespace is not counted here.
EXPECTED_COUNT=$(echo "$WORKER_POOLS" | wc -w | tr -d ' ')
RENDERED=$(kubectl get deploy -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=worker-group" \
  -o jsonpath='{range .items[*]}{.metadata.labels.n8n\.io/worker-pool}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)
RENDERED_COUNT=$(printf '%s\n' "$RENDERED" | sed '/^$/d' | wc -l | tr -d ' ')

header "Pool count (the check nothing at plan time can make)"

if [[ "$RENDERED_COUNT" -eq 0 ]]; then
  fail "expected $EXPECTED_COUNT pool Deployment(s), found none with label app.kubernetes.io/component=worker-group"
  info "This is what a chart that predates queueMode.workerGroups looks like after a clean apply:"
  info "the key was accepted and ignored. Check n8n_chart_version / n8n_chart_repository, then:"
  info "  helm -n $NAMESPACE get values $RELEASE_NAME | grep -A2 workerGroups"
  info "  helm -n $NAMESPACE get manifest $RELEASE_NAME | grep -c 'component: worker-group'"
  summarize_and_exit
elif [[ "$RENDERED_COUNT" -eq "$EXPECTED_COUNT" ]]; then
  pass "$RENDERED_COUNT pool Deployment(s) rendered, matching the $EXPECTED_COUNT declared"
else
  fail "$RENDERED_COUNT pool Deployment(s) rendered but $EXPECTED_COUNT declared"
fi

for rendered in $RENDERED; do
  found=0
  for expected in $WORKER_POOLS; do
    [[ "$rendered" == "$expected" ]] && found=1
  done
  if [[ "$found" -eq 0 ]]; then
    fail "pool Deployment for \"$rendered\" exists on the cluster but is not declared; a removed pool left behind, or a second release in this namespace"
  fi
done

SO_RENDERED=$(kubectl get scaledobject -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=worker-group" \
  -o jsonpath='{range .items[*]}{.metadata.labels.n8n\.io/worker-pool}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)
for rendered in $SO_RENDERED; do
  found=0
  for expected in $WORKER_POOLS; do
    [[ "$rendered" == "$expected" ]] && found=1
  done
  if [[ "$found" -eq 0 ]]; then
    fail "pool ScaledObject for \"$rendered\" exists on the cluster but is not declared; a removed pool left its scaler behind, or a second release in this namespace"
  fi
done

# ── Feature flag on the mains ─────────────────────────────────────────────────

header "Feature flag"

MAIN_DEPLOY=$(kubectl get deploy -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=main" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$MAIN_DEPLOY" ]]; then
  fail "no main Deployment found (labels app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=main)"
else
  # Read from a running pod, not the Deployment template: a rollout in
  # progress can leave the template updated while old ReplicaSet pods still
  # serve traffic on the previous env, which the template alone can't show.
  main_pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=main" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$main_pod" ]]; then
    fail "no Running main pod found to inspect (Deployment $MAIN_DEPLOY exists but has no Running pod)"
  else
    # shellcheck disable=SC2016
    if ! flag=$(kubectl exec -n "$NAMESPACE" "$main_pod" -c n8n-main -- sh -c 'printf %s "$N8N_WORKER_POOLS_ENABLED"' 2>/dev/null); then
      fail "could not exec into main pod $main_pod to read N8N_WORKER_POOLS_ENABLED"
    elif [[ "$flag" == "true" ]]; then
      pass "N8N_WORKER_POOLS_ENABLED=true on $main_pod (mains route to pools)"
    else
      fail "N8N_WORKER_POOLS_ENABLED is \"${flag:-<unset>}\" on $main_pod; mains will enqueue everything to the default queue"
    fi
  fi

  # Advisory only: the image tag is the one thing here the module's own
  # plan-time check already covers, but only when n8n_image_tag is pinned. A
  # floating `stable` slips past it, so read what actually deployed.
  image=$(kubectl get deploy -n "$NAMESPACE" "$MAIN_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  tag="${image##*:}"
  if [[ "$tag" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
    if [[ "$major" -gt 2 || ( "$major" -eq 2 && "$minor" -ge 39 ) ]]; then
      pass "n8n image $tag is >= 2.39, the first release that reads the pool variables"
    else
      fail "n8n image $tag predates worker pools (first in 2.39.0); it ignores N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME"
    fi
  else
    warn "n8n image tag \"$tag\" is not a version number; confirm it is >= 2.39 yourself"
  fi
fi

# The default worker's triggers tell us whether this deployment speaks TLS to
# Redis, which every pool's triggers then have to match. Missing entirely
# would silently baseline every pool against three empty strings, so a
# non-TLS pool trigger would match a baseline that was never actually read.
DEFAULT_SO="${RELEASE_NAME}-worker"
if [[ -z "$(scaledobject_json "$DEFAULT_SO")" ]]; then
  fail "ScaledObject $DEFAULT_SO not found; cannot establish the default worker's Redis TLS/AUTH baseline for pool comparison"
  summarize_and_exit
fi
DEFAULT_TLS=$(trigger_field "$DEFAULT_SO" 0 enableTLS) || { fail "kubectl error reading $DEFAULT_SO trigger metadata (enableTLS)"; summarize_and_exit; }
DEFAULT_USER=$(trigger_field "$DEFAULT_SO" 0 username) || { fail "kubectl error reading $DEFAULT_SO trigger metadata (username)"; summarize_and_exit; }
DEFAULT_PWENV=$(trigger_field "$DEFAULT_SO" 0 passwordFromEnv) || { fail "kubectl error reading $DEFAULT_SO trigger metadata (passwordFromEnv)"; summarize_and_exit; }

# ── Per pool ──────────────────────────────────────────────────────────────────

for pool in $WORKER_POOLS; do
  header "Pool: $pool"
  name="${RELEASE_NAME}-worker-${pool}"

  # Deployment
  if kubectl get deploy -n "$NAMESPACE" "$name" &>/dev/null; then
    pass "Deployment $name exists"
    label=$(kubectl get deploy -n "$NAMESPACE" "$name" -o jsonpath='{.metadata.labels.n8n\.io/worker-pool}' 2>/dev/null || true)
    if [[ "$label" == "$pool" ]]; then
      pass "labelled n8n.io/worker-pool=$pool"
    else
      fail "label n8n.io/worker-pool is \"${label:-<unset>}\", expected \"$pool\""
    fi
    if ! env_pool=$(deploy_env "$name" N8N_WORKER_POOL_NAME); then
      fail "kubectl error reading $name's N8N_WORKER_POOL_NAME"
    elif [[ "$env_pool" == "$pool" ]]; then
      pass "pod template carries N8N_WORKER_POOL_NAME=$pool"
    else
      fail "pod template N8N_WORKER_POOL_NAME is \"${env_pool:-<unset>}\", expected \"$pool\"; these workers would consume the default queue"
    fi
    if ! replicas=$(kubectl get deploy -n "$NAMESPACE" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null); then
      fail "kubectl error reading replicas for Deployment $name"
    else
      ready=$(kubectl get deploy -n "$NAMESPACE" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
      ready="${ready:-0}"
      if [[ "$replicas" -eq 0 ]]; then
        pass "scaled to 0 (parked; KEDA owns the count)"
      elif [[ "$ready" -ge "$replicas" ]]; then
        pass "$ready/$replicas replicas ready"
      else
        fail "$ready/$replicas replicas ready"
        # The one failure specific to pools: n8n 2.39 exits 1 on a pooled worker
        # the licence does not cover, while the default worker beside it is fine.
        # Measured live; the previous container's log carries the sentence.
        if kubectl logs -n "$NAMESPACE" -l "n8n.io/worker-pool=$pool" -c n8n-worker --previous --tail=50 2>/dev/null \
            | grep -q 'worker pools are not licensed'; then
          info "cause: the licence lacks feat:workerPools (\"worker pools are not licensed\" in the previous container log)"
          info "if the entitlement was just added, delete settings.license.cert in the database and restart the n8n deployments; pods keep the cached certificate otherwise"
        else
          info "kubectl -n $NAMESPACE describe deploy $name"
        fi
      fi
    fi
  else
    fail "Deployment $name missing"
  fi

  # ScaledObject
  if [[ -z "$(scaledobject_json "$name")" ]]; then
    fail "ScaledObject $name missing; the pool would sit at a fixed replica count"
    continue
  fi
  pass "ScaledObject $name exists"

  ready_cond=$(so_condition "$name" Ready)
  if [[ "$ready_cond" == "True" ]]; then
    pass "ScaledObject READY=True"
  else
    fail "ScaledObject READY=${ready_cond:-<none>}; KEDA cannot reach the queue (kubectl -n keda logs -l app=keda-operator | grep -i 'connection to redis')"
  fi

  target=$(kubectl get scaledobject -n "$NAMESPACE" "$name" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null || true)
  if [[ "$target" == "$name" ]]; then
    pass "scales Deployment $target"
  else
    fail "scaleTargetRef is \"$target\", expected \"$name\""
  fi

  # Triggers watch this pool's queue, not the default one.
  wait_list=""
  active_list=""
  if ! wait_list=$(trigger_field "$name" 0 listName); then
    fail "kubectl error reading $name trigger 0 metadata (listName)"
  elif ! active_list=$(trigger_field "$name" 1 listName); then
    fail "kubectl error reading $name trigger 1 metadata (listName)"
  elif [[ "$wait_list" == *":jobs-${pool}:wait" && "$active_list" == *":jobs-${pool}:active" ]]; then
    pass "triggers watch $wait_list and $active_list"
  else
    fail "triggers watch \"${wait_list:-<none>}\" / \"${active_list:-<none>}\", expected *:jobs-${pool}:wait and *:jobs-${pool}:active"
  fi

  # TLS and AUTH metadata must match the default worker's, or the scaler talks
  # plaintext to a TLS-only endpoint and hangs without crashing.
  for idx in 0 1; do
    tls=$(trigger_field "$name" "$idx" enableTLS) || { fail "kubectl error reading $name trigger $idx metadata (enableTLS)"; continue; }
    user=$(trigger_field "$name" "$idx" username) || { fail "kubectl error reading $name trigger $idx metadata (username)"; continue; }
    pwenv=$(trigger_field "$name" "$idx" passwordFromEnv) || { fail "kubectl error reading $name trigger $idx metadata (passwordFromEnv)"; continue; }
    if [[ "$tls" == "$DEFAULT_TLS" && "$user" == "$DEFAULT_USER" && "$pwenv" == "$DEFAULT_PWENV" ]]; then
      pass "trigger $idx carries the default worker's Redis metadata (enableTLS=${tls:-unset}, passwordFromEnv=${pwenv:-unset}, username=${user:-unset})"
    else
      fail "trigger $idx Redis metadata differs from the default worker's: enableTLS=${tls:-unset} vs ${DEFAULT_TLS:-unset}, passwordFromEnv=${pwenv:-unset} vs ${DEFAULT_PWENV:-unset}, username=${user:-unset} vs ${DEFAULT_USER:-unset}"
    fi
  done

  # The external metric resolves. `kubectl get hpa` TARGETS reads <unknown>
  # for a KEDA-backed HPA whether or not this works, so this is the signal.
  metric="s0-redis-$(echo "$wait_list" | tr ':' '-')"
  if kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/$NAMESPACE/$metric?labelSelector=scaledobject.keda.sh/name=$name" &>/dev/null; then
    pass "external metric $metric resolves"
  else
    warn "external metric $metric did not resolve; harmless while the ScaledObject is READY=True and the pool is at 0, otherwise see keda-operator logs"
  fi

  # Running pods, if any, carry the pool name in their live environment.
  if ! pods_raw=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,n8n.io/worker-pool=$pool" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); then
    fail "kubectl error listing Running pods for pool $pool"
  else
    pods=$(printf '%s\n' "$pods_raw" | sed '/^$/d')
    if [[ -z "$pods" ]]; then
      skip "no Running pod to inspect (pool at 0 or still starting)"
    else
      bad=0
      while IFS= read -r p; do
        # Single quotes on purpose: the variable must expand inside the pod, not here.
        # shellcheck disable=SC2016
        live=$(kubectl exec -n "$NAMESPACE" "$p" -c n8n-worker -- sh -c 'printf %s "$N8N_WORKER_POOL_NAME"' 2>/dev/null || true)
        [[ "$live" == "$pool" ]] || { bad=1; info "$p: N8N_WORKER_POOL_NAME=\"${live:-<unset>}\""; }
      done <<< "$pods"
      if [[ "$bad" -eq 0 ]]; then
        pass "every Running pod reports N8N_WORKER_POOL_NAME=$pool"
      else
        fail "a Running pod does not carry N8N_WORKER_POOL_NAME=$pool"
      fi
    fi
  fi
done

# ── Default workers unaffected ────────────────────────────────────────────────

header "Default worker deployment"

if kubectl get deploy -n "$NAMESPACE" "$DEFAULT_SO" &>/dev/null; then
  if ! dflt=$(deploy_env "$DEFAULT_SO" N8N_WORKER_POOL_NAME); then
    fail "kubectl error reading $DEFAULT_SO's N8N_WORKER_POOL_NAME"
  elif [[ -z "$dflt" ]]; then
    pass "$DEFAULT_SO has no N8N_WORKER_POOL_NAME (still serves the default queue)"
  else
    fail "$DEFAULT_SO carries N8N_WORKER_POOL_NAME=$dflt; the default queue has no consumer"
  fi
else
  fail "Deployment $DEFAULT_SO not found; unpinned executions (the default queue) have no consumer"
fi

echo ""
info "Topology verified. Routing is a UI action and is not tested here; see examples/worker-pools/README.md, \"An end-to-end execution on a pool\"."

summarize_and_exit
