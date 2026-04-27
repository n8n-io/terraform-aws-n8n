#!/usr/bin/env bash
# smoke-test.sh — post-deployment smoke test for terraform-aws-n8n.
#
# This module deploys the multi-main topology (multiple main + worker +
# webhook-processor pods, PostgreSQL, Redis, KEDA). The script auto-detects
# the topology by probing the namespace; for this module that is always the
# multi-main path — main/worker/webhook-processor pod health, queue mode,
# Redis connectivity, KEDA ScaledObject, HTTPS, API, and end-to-end execution.
#
# Usage:
#   # Run from the example directory — outputs are read automatically:
#   cd examples/complete
#   ../../tests/scripts/smoke-test.sh
#
#   # Or point at a Terraform directory explicitly:
#   TERRAFORM_DIR=examples/complete ./tests/scripts/smoke-test.sh
#
#   # Override any value by setting it in .env (next to this script,
#   # or next to terraform.tfstate):
#   cp tests/scripts/.env.example tests/scripts/.env
#   # edit .env, then run the script.
#
#   # Force mode (skip auto-detection):
#   DEPLOY_MODE=multi ./tests/scripts/smoke-test.sh
#
# Priority: .env explicit values > Terraform outputs > built-in defaults.

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────
# Look for .env in (1) the script's own directory, then (2) the current working
# directory (TERRAFORM_DIR). This lets you keep secrets next to the Terraform
# files rather than alongside the script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _env_candidate in "$SCRIPT_DIR/.env" "$(pwd)/.env"; do
  if [[ -f "$_env_candidate" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$_env_candidate"; set +a
    break
  fi
done

# ── Read from Terraform outputs ───────────────────────────────────────────────
# Default TERRAFORM_DIR to the current working directory so running the script
# from inside a terraform directory just works.

TERRAFORM_DIR="${TERRAFORM_DIR:-$(pwd)}"

if command -v terraform &>/dev/null && [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
  echo -e "\033[0;36m↳\033[0m  Reading values from Terraform state in: $TERRAFORM_DIR"

  tf_namespace=$(terraform -chdir="$TERRAFORM_DIR" output -raw namespace 2>/dev/null || true)
  tf_n8n_url=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_url 2>/dev/null || true)
  tf_kubectl_cmd=$(terraform -chdir="$TERRAFORM_DIR" output -raw kubectl_config_command 2>/dev/null || true)

  # Only apply if not already set via .env / environment
  NAMESPACE="${NAMESPACE:-$tf_namespace}"
  N8N_URL="${N8N_URL:-$tf_n8n_url}"

  echo -e "\033[0;36m↳\033[0m  namespace = ${NAMESPACE:-<not found>}"
  echo -e "\033[0;36m↳\033[0m  n8n_url   = ${N8N_URL:-<not found>}"

  # Switch kubectl context to the cluster from this Terraform deployment.
  # Required when multiple clusters are configured — avoids running against
  # the wrong cluster if the context was last pointed elsewhere.
  if [[ -n "$tf_kubectl_cmd" ]]; then
    echo -e "\033[0;36m↳\033[0m  Switching kubectl context: $tf_kubectl_cmd"
    eval "$tf_kubectl_cmd" &>/dev/null
  fi

  echo ""
fi

# ── Configuration ─────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-${N8N_NAMESPACE:-n8n}}"
N8N_URL="${N8N_URL:-}"
N8N_API_KEY="${N8N_API_KEY:-}"
DEPLOY_MODE="${DEPLOY_MODE:-}"        # set to 'single' or 'multi' to skip auto-detect

# Multi-mode optional load test settings
LOAD_TEST="${LOAD_TEST:-false}"
LOAD_REQUESTS="${LOAD_REQUESTS:-100}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-20}"
LOAD_SEED_JOBS="${LOAD_SEED_JOBS:-20}"   # jobs queued in phase 1 to trigger the autoscaler
SCALE_WAIT_SECS="${SCALE_WAIT_SECS:-180}"
LOAD_JOB_DURATION_SECS="${LOAD_JOB_DURATION_SECS:-10}"

# Expected minimum replica counts for multi-main deployments
MAIN_MIN=2
WORKER_MIN=1
WEBHOOK_MIN=2

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

# ── Preflight ─────────────────────────────────────────────────────────────────

header "Preflight"

require_cmd kubectl
require_cmd curl

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach the cluster. Check your kubeconfig / credentials.${RESET}" >&2
  exit 1
fi
pass "kubectl cluster connectivity"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  fail "Namespace '$NAMESPACE' does not exist"
  exit 1
fi
pass "Namespace '$NAMESPACE' exists"

if [[ -z "$N8N_URL" ]]; then
  warn "N8N_URL not set — HTTP and API tests will be skipped"
  warn "  Set N8N_URL=https://your-domain.com to enable them"
fi

if [[ -z "$N8N_API_KEY" ]]; then
  warn "N8N_API_KEY not set — workflow execution test will be skipped"
  warn "  Create one in n8n: Settings > API > Create API Key"
fi

# ── Deployment mode detection ─────────────────────────────────────────────────

header "Deployment Mode"

if [[ -n "$DEPLOY_MODE" ]]; then
  info "Mode forced via DEPLOY_MODE=$DEPLOY_MODE"
elif kubectl get deployment n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  DEPLOY_MODE="multi"
else
  DEPLOY_MODE="single"
fi

if [[ "$DEPLOY_MODE" == "multi" ]]; then
  pass "Multi-main deployment detected (n8n-worker present)"
  info "Checks: queue mode, HPA/KEDA, Redis, leader election"
else
  pass "Single-instance deployment detected"
  info "Checks: SQLite PVC, task runner sidecar, Python runner"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SINGLE-INSTANCE CHECKS
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$DEPLOY_MODE" == "single" ]]; then

# ── Pod health (single) ───────────────────────────────────────────────────────

header "Pod Health"

if ! kubectl get deployment n8n-main -n "$NAMESPACE" &>/dev/null; then
  fail "Deployment 'n8n-main' not found in namespace '$NAMESPACE'"
  echo -e "${RED}Cannot continue — no n8n deployment found.${RESET}" >&2
  exit 1
fi

ready=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
ready="${ready:-0}"
desired=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

if [[ "$ready" -eq "$desired" && "$ready" -gt 0 ]]; then
  pass "n8n-main pod: $ready/$desired ready"
else
  fail "n8n-main pod: $ready/$desired ready"
fi

# Surface any pods not in Running state
bad_pods=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=n8n" \
  --no-headers 2>/dev/null \
  | awk '{print $1, $3}' \
  | grep -v "Running\|Completed" || true)
if [[ -n "$bad_pods" ]]; then
  warn "Unhealthy pods detected:"
  while IFS= read -r line; do info "$line"; done <<< "$bad_pods"
fi

# Grab the running pod name for subsequent checks
N8N_POD=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=n8n" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$N8N_POD" ]]; then
  fail "Could not find a running n8n pod — remaining checks will be limited"
else
  info "Using pod: $N8N_POD"
fi

# ── SQLite PVC ────────────────────────────────────────────────────────────────

header "SQLite Persistent Volume"

pvc=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
  | grep -i "n8n\|sqlite\|data" | head -3 || true)

if [[ -n "$pvc" ]]; then
  bound=$(echo "$pvc" | grep -c "Bound" || true)
  total=$(echo "$pvc" | wc -l | tr -d ' ')
  if [[ "$bound" -eq "$total" ]]; then
    pass "PVC(s) bound ($bound/$total)"
    while IFS= read -r line; do info "$line"; done <<< "$pvc"
  else
    fail "One or more PVCs not bound ($bound/$total)"
    while IFS= read -r line; do info "$line"; done <<< "$pvc"
  fi
else
  warn "No PVCs found matching n8n — SQLite data may not be persisted"
  info "Check: kubectl get pvc -n $NAMESPACE"
fi

# Verify the data directory is writable inside the running pod
if [[ -n "$N8N_POD" ]]; then
  data_dir=$(kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
    -- printenv N8N_USER_FOLDER 2>/dev/null \
    || kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
    -- printenv HOME 2>/dev/null || echo "")

  if [[ -n "$data_dir" ]]; then
    if kubectl exec "$N8N_POD" -n "$NAMESPACE" -c n8n \
        -- sh -c "test -w $data_dir" &>/dev/null; then
      pass "Data directory is writable: $data_dir"
    else
      warn "Data directory may not be writable: $data_dir"
    fi
  fi
fi

# ── Task runner sidecar (single) ──────────────────────────────────────────────

header "Task Runner Sidecar"

containers=$(kubectl get deployment n8n-main -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

info "Containers in pod spec: $containers"

if echo "$containers" | grep -qiE "runner"; then
  runner_container=$(echo "$containers" | tr ' ' '\n' | grep -iE "runner" | head -1)
  pass "Task runner sidecar found: $runner_container"

  # ── Python runner ──────────────────────────────────────────────────────────

  header "Python Runner"

  if [[ -n "$N8N_POD" ]]; then
    python_version=$(kubectl exec "$N8N_POD" -n "$NAMESPACE" -c "$runner_container" \
      -- python3 --version 2>/dev/null || \
      kubectl exec "$N8N_POD" -n "$NAMESPACE" -c "$runner_container" \
      -- python --version 2>/dev/null || echo "")

    if [[ -n "$python_version" ]]; then
      pass "Python binary present in runner sidecar: $python_version"
    else
      fail "Python binary not found in runner sidecar"
      info "Verify the runner image includes Python support"
    fi

    # Check runner sidecar logs for broker connection
    runner_logs=$(kubectl logs "$N8N_POD" -n "$NAMESPACE" -c "$runner_container" \
      --tail=50 2>/dev/null || true)

    if echo "$runner_logs" | grep -qiE "connected|ready|broker|listening"; then
      connected_line=$(echo "$runner_logs" | grep -iE "connected|ready|broker|listening" | tail -1)
      pass "Runner sidecar connected to broker"
      info "$connected_line"
    else
      warn "No broker connection confirmation found in runner logs (last 50 lines)"
      info "This may be normal if the runner starts on-demand. Check manually:"
      info "kubectl logs $N8N_POD -n $NAMESPACE -c $runner_container"
    fi
  else
    skip "Python runner exec checks (no running pod found)"
  fi

else
  warn "Task runner sidecar not detected — task runners may be disabled"
  info "Set n8n_task_runners_enabled = true in terraform.tfvars and re-apply"

  header "Python Runner"
  skip "Python runner checks (task runner sidecar not present)"
fi

fi  # end single-instance checks

# ══════════════════════════════════════════════════════════════════════════════
# MULTI-MAIN CHECKS
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$DEPLOY_MODE" == "multi" ]]; then

# ── Pod health (multi) ────────────────────────────────────────────────────────

header "Pod Health"

check_deployment() {
  local name="$1"
  local min_replicas="$2"
  local label="$3"

  if ! kubectl get deployment "$name" -n "$NAMESPACE" &>/dev/null; then
    fail "Deployment '$name' not found"
    return
  fi

  local ready
  ready=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  ready="${ready:-0}"

  local desired
  desired=$(kubectl get deployment "$name" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$ready" -ge "$min_replicas" && "$ready" -eq "$desired" ]]; then
    pass "$label: $ready/$desired pods ready"
  elif [[ "$ready" -gt 0 ]]; then
    warn "$label: only $ready/$desired pods ready (minimum $min_replicas)"
  else
    fail "$label: 0/$desired pods ready"
  fi

  local bad_pods
  bad_pods=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=$name" \
    --no-headers 2>/dev/null \
    | awk '{print $1, $3}' \
    | grep -v "Running\|Completed" || true)
  if [[ -n "$bad_pods" ]]; then
    warn "Unhealthy pods detected under $name:"
    while IFS= read -r line; do info "$line"; done <<< "$bad_pods"
  fi
}

check_deployment "n8n-main"              "$MAIN_MIN"    "Main pods"
check_deployment "n8n-worker"            "$WORKER_MIN"  "Worker pods"
check_deployment "n8n-webhook-processor" "$WEBHOOK_MIN" "Webhook processor pods"

# ── Task runner sidecars (multi: workers only) ────────────────────────────────

header "Task Runner Sidecars"

# In queue mode, Code nodes execute on worker pods — the task runner sidecar
# belongs on workers, not on main or webhook-processor pods.
worker_containers=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

if echo "$worker_containers" | grep -qiE "runner"; then
  runner_container=$(echo "$worker_containers" | tr ' ' '\n' | grep -iE "runner" | head -1)
  pass "Task runner sidecar present on n8n-worker pods: $runner_container"

  # Confirm sidecar is connected to broker in a running worker pod
  worker_pod=$(kubectl get pods -n "$NAMESPACE" \
    -l "app.kubernetes.io/component=worker" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$worker_pod" ]]; then
    runner_logs=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c "$runner_container" \
      --tail=50 2>/dev/null || true)
    if echo "$runner_logs" | grep -qiE "connected|ready|broker|listening"; then
      connected_line=$(echo "$runner_logs" | grep -iE "connected|ready|broker|listening" | tail -1)
      pass "Worker runner sidecar connected to broker"
      info "$connected_line"
    else
      warn "No broker connection confirmation in worker runner logs (last 50 lines)"
      info "kubectl logs $worker_pod -n $NAMESPACE -c $runner_container"
    fi
  fi
else
  warn "Task runner sidecar not found on n8n-worker — task runners may be disabled"
  info "Set n8n_task_runners_enabled = true in terraform.tfvars and re-apply"
fi

# ── Multi-main leader election ────────────────────────────────────────────────

header "Multi-Main Leader Election"

# n8n uses Redis-based leader election. Verify the feature flag is enabled
# on main pods and that at least one pod reports leadership activity.
main_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=main" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$main_pod" ]]; then
  multi_main=$(kubectl exec "$main_pod" -n "$NAMESPACE" -c n8n-main \
    -- printenv N8N_MULTI_MAIN_SETUP_ENABLED 2>/dev/null || echo "")
  if [[ "$multi_main" == "true" ]]; then
    pass "N8N_MULTI_MAIN_SETUP_ENABLED=true on main pods — Redis leader election active"
  else
    warn "N8N_MULTI_MAIN_SETUP_ENABLED is not 'true' (got: '${multi_main:-<unset>}')"
    info "Expected when main replica count > 1"
  fi

  leader_log=$(kubectl logs "$main_pod" -n "$NAMESPACE" -c n8n-main --tail=100 2>/dev/null \
    | grep -iE "leader|leadership" | tail -3 || true)
  if [[ -n "$leader_log" ]]; then
    pass "Leader election activity found in logs"
    while IFS= read -r line; do info "$line"; done <<< "$leader_log"
  else
    info "No leadership log lines yet — normal if recently started"
  fi
else
  warn "No running main pod found to check leader election"
fi

# ── Autoscaler configuration ──────────────────────────────────────────────────

header "Autoscaler Configuration"

check_hpa() {
  local name="$1"
  local label="$2"

  if ! kubectl get hpa "$name" -n "$NAMESPACE" &>/dev/null; then
    warn "HPA '$name' not found — HPAs are configured by Terraform, not manual deployment"
    return
  fi

  local min max current targets
  min=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.spec.minReplicas}')
  max=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.spec.maxReplicas}')
  current=$(kubectl get hpa "$name" -n "$NAMESPACE" -o jsonpath='{.status.currentReplicas}')
  targets=$(kubectl get hpa "$name" -n "$NAMESPACE" \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || echo "unknown")

  pass "$label HPA: min=$min max=$max current=$current CPU=$targets%"

  if [[ "$current" -eq "$max" ]]; then
    warn "$label is at max replicas ($max) — may indicate sustained high load"
  fi
}

check_hpa "n8n-main"              "Main"
check_hpa "n8n-webhook-processor" "Webhook processor"

# Workers: prefer KEDA ScaledObject (queue-depth), fall back to CPU-based HPA
if kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  min=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null || echo "?")
  max=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null || echo "?")
  ready=$(kubectl get scaledobject n8n-worker -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  pass "Worker KEDA ScaledObject: min=$min max=$max ready=$ready (queue-depth autoscaling)"
elif kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null 2>&1; then
  check_hpa "n8n-worker" "Worker"
else
  warn "No autoscaler found for n8n-worker — expected KEDA ScaledObject or CPU-based HPA"
fi

# ── Queue mode: Redis connectivity ────────────────────────────────────────────

header "Queue Mode — Redis Connectivity"

worker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/component=worker" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$worker_pod" ]]; then
  fail "No running worker pod found to probe Redis connectivity"
else
  info "Using worker pod: $worker_pod"

  redis_host=$(kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
    -- printenv QUEUE_BULL_REDIS_HOST 2>/dev/null || true)

  if [[ -n "$redis_host" ]]; then
    pass "Redis host visible in worker environment: $redis_host"
  else
    warn "Could not read Redis host from worker environment"
    info "Manually verify: kubectl exec -n $NAMESPACE $worker_pod -c n8n-worker -- printenv | grep -i redis"
  fi

  if kubectl exec "$worker_pod" -n "$NAMESPACE" -c n8n-worker \
      -- sh -c 'kill -0 1' &>/dev/null; then
    queue_connected=$(kubectl logs "$worker_pod" -n "$NAMESPACE" -c n8n-worker --tail=100 2>/dev/null \
      | grep -iE "queue|bull|redis|worker" | tail -3 || true)
    if [[ -n "$queue_connected" ]]; then
      pass "Worker logs show queue activity"
      while IFS= read -r line; do info "$line"; done <<< "$queue_connected"
    else
      warn "No queue-related log lines found in last 100 worker log lines"
    fi
  fi
fi

fi  # end multi-main checks

# ══════════════════════════════════════════════════════════════════════════════
# COMMON CHECKS (HTTP, API, Workflow execution)
# ══════════════════════════════════════════════════════════════════════════════

# ── HTTP health check ─────────────────────────────────────────────────────────

header "HTTP Health Check"

if [[ -z "$N8N_URL" ]]; then
  skip "HTTP health check (N8N_URL not set)"
else
  healthz_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 10 "${N8N_URL%/}/healthz" || echo "000")

  if [[ "$healthz_status" == "200" ]]; then
    pass "/healthz returned HTTP $healthz_status"
  elif [[ "$healthz_status" == "000" ]]; then
    fail "/healthz — connection failed (timeout or DNS error)"
  else
    fail "/healthz returned HTTP $healthz_status (expected 200)"
  fi

  # Verify HTTP → HTTPS redirect
  http_url="${N8N_URL/https:/http:}"
  if [[ "$http_url" != "$N8N_URL" ]]; then
    redirect_status=$(curl -sk -o /dev/null -w "%{http_code}" \
      --max-time 10 "$http_url" || echo "000")
    if [[ "$redirect_status" =~ ^30[1-8]$ ]]; then
      pass "HTTP → HTTPS redirect: $redirect_status"
    elif [[ "$redirect_status" == "000" ]]; then
      warn "HTTP redirect check — connection failed"
    else
      warn "HTTP → HTTPS redirect returned $redirect_status (expected 301/302/307/308)"
    fi
  fi
fi

# ── API connectivity ──────────────────────────────────────────────────────────

header "API Connectivity"

if [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "API connectivity test (requires N8N_URL and N8N_API_KEY)"
else
  api_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "${N8N_URL%/}/api/v1/workflows?limit=1" || echo "000")

  if [[ "$api_status" == "200" ]]; then
    pass "API /api/v1/workflows responded HTTP $api_status"
  elif [[ "$api_status" == "401" ]]; then
    fail "API returned 401 Unauthorized — check your N8N_API_KEY"
  elif [[ "$api_status" == "000" ]]; then
    fail "API — connection failed (timeout or DNS error)"
  else
    fail "API /api/v1/workflows returned HTTP $api_status"
  fi
fi

# ── Workflow execution ────────────────────────────────────────────────────────
#
# Single mode: Webhook → JS Code → Python Code
#   Exercises both task runner language runtimes end-to-end.
#
# Multi mode: Webhook → Set
#   Lightweight — verifies queue routing; task runner is covered by the
#   sidecar check above.

if [[ "$DEPLOY_MODE" == "single" ]]; then
  header "Workflow Execution (JS + Python runners)"
else
  header "Workflow Execution via Queue"
fi

if [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "Workflow execution test (requires N8N_URL and N8N_API_KEY)"
else
  webhook_path="smoke-test-$$"

  if [[ "$DEPLOY_MODE" == "single" ]]; then
    # Single: Webhook → JS Code → Python Code (exercises both runners)
    workflow_payload="{
      \"name\": \"__smoke-test__\",
      \"nodes\": [
        {
          \"id\": \"a1b2c3d4-0001-0001-0001-000000000001\",
          \"name\": \"Webhook\",
          \"type\": \"n8n-nodes-base.webhook\",
          \"typeVersion\": 1,
          \"position\": [250, 300],
          \"webhookId\": \"${webhook_path}\",
          \"parameters\": {
            \"httpMethod\": \"POST\",
            \"path\": \"${webhook_path}\",
            \"responseMode\": \"onReceived\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0002-0002-0002-000000000002\",
          \"name\": \"JS Code\",
          \"type\": \"n8n-nodes-base.code\",
          \"typeVersion\": 2,
          \"position\": [450, 300],
          \"parameters\": {
            \"jsCode\": \"return [{ json: { js_runner: 'passed' } }];\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0003-0003-0003-000000000003\",
          \"name\": \"Python Code\",
          \"type\": \"n8n-nodes-base.code\",
          \"typeVersion\": 2,
          \"position\": [650, 300],
          \"parameters\": {
            \"language\": \"python\",
            \"pythonCode\": \"return [{'json': {'python_runner': 'passed'}}]\"
          }
        }
      ],
      \"connections\": {
        \"Webhook\": {
          \"main\": [[{ \"node\": \"JS Code\", \"type\": \"main\", \"index\": 0 }]]
        },
        \"JS Code\": {
          \"main\": [[{ \"node\": \"Python Code\", \"type\": \"main\", \"index\": 0 }]]
        }
      },
      \"settings\": {}
    }"
    exec_success_msg="Execution completed successfully — JS and Python runners both processed"
  else
    # Multi: Webhook → Set (lightweight queue-mode test)
    workflow_payload="{
      \"name\": \"__smoke-test__\",
      \"nodes\": [
        {
          \"id\": \"a1b2c3d4-0001-0001-0001-000000000001\",
          \"name\": \"Webhook\",
          \"type\": \"n8n-nodes-base.webhook\",
          \"typeVersion\": 1,
          \"position\": [250, 300],
          \"webhookId\": \"${webhook_path}\",
          \"parameters\": {
            \"httpMethod\": \"POST\",
            \"path\": \"${webhook_path}\",
            \"responseMode\": \"onReceived\"
          }
        },
        {
          \"id\": \"a1b2c3d4-0002-0002-0002-000000000002\",
          \"name\": \"Set\",
          \"type\": \"n8n-nodes-base.set\",
          \"typeVersion\": 3.4,
          \"position\": [450, 300],
          \"parameters\": {
            \"assignments\": {
              \"assignments\": [
                { \"id\": \"1\", \"name\": \"smoke_test\", \"value\": \"passed\", \"type\": \"string\" }
              ]
            }
          }
        }
      ],
      \"connections\": {
        \"Webhook\": {
          \"main\": [[{ \"node\": \"Set\", \"type\": \"main\", \"index\": 0 }]]
        }
      },
      \"settings\": {}
    }"
    exec_success_msg="Execution completed successfully — queue mode is working"
  fi

  # Create workflow
  create_response=$(curl -sk -w "\n%{http_code}" \
    --max-time 15 \
    -X POST \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$workflow_payload" \
    "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

  create_status=$(echo "$create_response" | tail -1)
  create_body=$(echo "$create_response" | sed '$d')

  if [[ "$create_status" != "200" ]]; then
    fail "Failed to create test workflow (HTTP $create_status)"
    info "Response: $create_body"
    info "Skipping execution test"
  else
    workflow_id=$(echo "$create_body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
    pass "Test workflow created (id: $workflow_id)"
    if [[ "$DEPLOY_MODE" == "single" ]]; then
      info "Webhook → JS Code node → Python Code node (exercises both runners)"
    fi

    # Activate so the webhook listener starts
    activate_status=$(curl -sk -o /dev/null -w "%{http_code}" \
      --max-time 10 \
      -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/activate" 2>/dev/null || echo "000")

    if [[ "$activate_status" != "200" ]]; then
      fail "Failed to activate test workflow (HTTP $activate_status)"
    else
      pass "Test workflow activated"

      if [[ "$DEPLOY_MODE" == "multi" ]]; then
        info "Waiting 5s for webhook-processor to register the new webhook..."
        sleep 5
        info "Triggering execution via webhook — will be queued to a worker"

        trigger_status=$(curl -sk -o /dev/null -w "%{http_code}" \
          --max-time 15 \
          -X POST \
          -H "Content-Type: application/json" \
          -d '{"smoke_test": true}' \
          "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo "000")
        trigger_body=""
      else
        info "Triggering execution via webhook → Code node (exercises task runner)"

        # Poll until the webhook is registered (up to 15s)
        trigger_status="000"
        trigger_body=""
        for _w in $(seq 1 5); do
          sleep 3
          trigger_response=$(curl -sk -w "\n%{http_code}" \
            --max-time 15 \
            -X POST \
            -H "Content-Type: application/json" \
            -d '{"smoke_test": true}' \
            "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo -e "\n000")
          trigger_status=$(echo "$trigger_response" | tail -1)
          trigger_body=$(echo "$trigger_response" | sed '$d')
          [[ "$trigger_status" =~ ^2 ]] && break
          [[ "$trigger_status" == "404" ]] && continue
          break
        done
      fi

      if [[ "$trigger_status" =~ ^2 ]]; then
        pass "Webhook triggered (HTTP $trigger_status)"

        info "Waiting for execution to complete..."
        exec_state="unknown"
        for i in $(seq 1 15); do
          sleep 2
          exec_state=$(curl -sk \
            --max-time 10 \
            -H "X-N8N-API-KEY: $N8N_API_KEY" \
            "${N8N_URL%/}/api/v1/executions?workflowId=${workflow_id}&limit=1" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); execs=d.get('data',[]); print(execs[0]['status'] if execs else 'pending')" 2>/dev/null \
            || echo "unknown")

          if [[ "$exec_state" == "success" ]]; then
            pass "$exec_success_msg"
            break
          elif [[ "$exec_state" == "error" || "$exec_state" == "crashed" ]]; then
            fail "Execution ended with status: $exec_state"
            if [[ "$DEPLOY_MODE" == "single" && -n "${N8N_POD:-}" ]]; then
              info "Check logs: kubectl logs $N8N_POD -n $NAMESPACE -c n8n --tail=50"
            fi
            break
          elif [[ "$i" -eq 15 ]]; then
            warn "Execution still in state '$exec_state' after 30s"
            if [[ "$DEPLOY_MODE" == "multi" ]]; then
              info "May be slow to process — check: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=worker --tail=50"
            fi
          fi
        done
      else
        fail "Webhook trigger failed (HTTP $trigger_status)"
        info "Webhook URL: ${N8N_URL%/}/webhook/${webhook_path}"
        [[ -n "$trigger_body" ]] && info "Response: $trigger_body"
      fi
    fi

    # Cleanup — deactivate then delete
    curl -sk -o /dev/null --max-time 10 -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}/deactivate" 2>/dev/null || true
    curl -sk -o /dev/null --max-time 10 -X DELETE \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      "${N8N_URL%/}/api/v1/workflows/${workflow_id}" 2>/dev/null || true
    info "Test workflow deleted"
  fi
fi

# ── Worker scaling test (multi only, optional) ────────────────────────────────
#
# Creates a temporary CPU-burning workflow, queues LOAD_REQUESTS concurrent
# executions, and verifies that the worker HPA/KEDA scales up.
#
# Why not /healthz? Those requests never touch worker pods — they hit the main
# pods' HTTP listener. Workers only get CPU when executing workflows.

if [[ "$DEPLOY_MODE" == "multi" ]]; then

header "Worker Scaling Test"

if [[ "$LOAD_TEST" != "true" ]]; then
  skip "Load scaling test (set LOAD_TEST=true to enable)"
elif [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "Load scaling test (requires N8N_URL and N8N_API_KEY)"
else
  SCALER_MODE=""
  if kubectl get hpa n8n-worker -n "$NAMESPACE" &>/dev/null; then
    worker_hpa_targets=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
      --no-headers 2>/dev/null | awk '{print $3}' || echo "<unknown>")
    if [[ "$worker_hpa_targets" == *"<unknown>"* ]]; then
      warn "HPA CPU metrics are <unknown> — metrics-server is not installed or not yet ready"
      info "Install metrics-server if not already done, then wait ~2 minutes for metrics to populate."
      info "Verify: kubectl top pods -n $NAMESPACE"
      info "Skipping load test — it cannot demonstrate scaling in this state."
    else
      SCALER_MODE="hpa"
    fi
  elif kubectl get scaledobject n8n-worker -n "$NAMESPACE" &>/dev/null; then
    info "No HPA found — KEDA ScaledObject detected. Scaling is queue-depth driven (Redis)."
    SCALER_MODE="keda"
  else
    skip "Load scaling test — no HPA or KEDA ScaledObject found for n8n-worker"
  fi

  if [[ -n "$SCALER_MODE" ]]; then
    load_webhook_path="smoke-load-$$"
    load_duration_ms=$((LOAD_JOB_DURATION_SECS * 1000))
    load_js="const end = Date.now() + ${load_duration_ms}; let x = 0; while (Date.now() < end) { for (let i = 0; i < 100000; i++) x += Math.sqrt(i); } return [{json: {done: true, elapsed: Date.now() - (end - ${load_duration_ms})}}];"

    load_workflow_payload=$(cat <<EOF
{
  "name": "__smoke-load-test__",
  "nodes": [
    {
      "id": "a1b2c3d4-0011-0011-0011-000000000011",
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [250, 300],
      "webhookId": "${load_webhook_path}",
      "parameters": {
        "httpMethod": "POST",
        "path": "${load_webhook_path}",
        "responseMode": "onReceived"
      }
    },
    {
      "id": "a1b2c3d4-0012-0012-0012-000000000012",
      "name": "CPU Burn",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [450, 300],
      "parameters": {
        "jsCode": "${load_js}"
      }
    }
  ],
  "connections": {
    "Webhook": {
      "main": [[{"node": "CPU Burn", "type": "main", "index": 0}]]
    }
  },
  "settings": {}
}
EOF
    )

    load_workflow_id=""

    load_create_response=$(curl -sk -w "\n%{http_code}" \
      --max-time 15 \
      -X POST \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$load_workflow_payload" \
      "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

    load_create_status=$(echo "$load_create_response" | tail -1)
    load_create_body=$(echo "$load_create_response" | sed '$d')

    if [[ "$load_create_status" != "200" ]]; then
      warn "Could not create load test workflow (HTTP $load_create_status) — skipping scaling test"
      info "Response: $load_create_body"
    else
      load_workflow_id=$(echo "$load_create_body" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
      info "Load test workflow created (id: $load_workflow_id, CPU burn: ${LOAD_JOB_DURATION_SECS}s per job)"

      load_activate_status=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -X POST \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/activate" 2>/dev/null || echo "000")

      if [[ "$load_activate_status" != "200" ]]; then
        warn "Could not activate load test workflow (HTTP $load_activate_status) — skipping scaling test"
      else
        if [[ "$SCALER_MODE" == "hpa" ]]; then
          worker_before=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
        else
          worker_before=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          worker_before="${worker_before:-0}"
        fi
        info "Baseline — worker: $worker_before replica(s)"

        # Clamp seed batch to total request count
        load_seed=$LOAD_SEED_JOBS
        [[ $load_seed -gt $LOAD_REQUESTS ]] && load_seed=$LOAD_REQUESTS
        load_remaining=$((LOAD_REQUESTS - load_seed))

        # Phase 1: queue seed jobs to signal the autoscaler
        if [[ "$SCALER_MODE" == "keda" ]]; then
          info "Phase 1: queuing $load_seed seed jobs to build queue depth (KEDA trigger)..."
        else
          info "Phase 1: queuing $load_seed seed jobs — each burns ~${LOAD_JOB_DURATION_SECS}s CPU (HPA trigger)..."
        fi

        for i in $(seq 1 "$load_seed"); do
          curl -sk -o /dev/null --max-time 10 \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"job\": $i}" \
            "${N8N_URL%/}/webhook/${load_webhook_path}" &
          if (( i % LOAD_CONCURRENCY == 0 )); then wait || true; fi
        done
        wait || true
        info "$load_seed seed jobs queued. Polling for scale-up (max ${SCALE_WAIT_SECS}s)..."

        # Poll for scale-up
        worker_scaled=false
        worker_after="$worker_before"
        elapsed=0
        poll_interval=15
        while [[ $elapsed -lt $SCALE_WAIT_SECS ]]; do
          sleep $poll_interval
          elapsed=$((elapsed + poll_interval))
          if [[ "$SCALER_MODE" == "hpa" ]]; then
            worker_now=$(kubectl get hpa n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
          else
            worker_now=$(kubectl get deployment n8n-worker -n "$NAMESPACE" \
              -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            worker_now="${worker_now:-0}"
          fi
          if [[ "$worker_now" -gt "$worker_before" ]]; then
            worker_scaled=true
            worker_after="$worker_now"
            break
          fi
          info "  ${elapsed}s / ${SCALE_WAIT_SECS}s — worker replicas: ${worker_now} (waiting for > $worker_before)"
        done

        if [[ "$worker_scaled" == "true" ]]; then
          pass "Worker pods scaled: $worker_before → $worker_after (detected after ${elapsed}s)"

          # Phase 2: queue remaining jobs so the new workers are visibly utilized
          if [[ $load_remaining -gt 0 ]]; then
            info "Phase 2: queuing $load_remaining remaining jobs across $worker_after worker(s)..."
            info "Watch new workers pick up jobs: kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=worker -w"
            for i in $(seq $((load_seed + 1)) "$LOAD_REQUESTS"); do
              curl -sk -o /dev/null --max-time 10 \
                -X POST \
                -H "Content-Type: application/json" \
                -d "{\"job\": $i}" \
                "${N8N_URL%/}/webhook/${load_webhook_path}" &
              if (( (i - load_seed) % LOAD_CONCURRENCY == 0 )); then wait || true; fi
            done
            wait || true
            info "All $LOAD_REQUESTS jobs queued total — $load_seed seed + $load_remaining follow-on"
          fi
        else
          warn "Worker pods did not scale ($worker_before → $worker_after) within ${SCALE_WAIT_SECS}s"
          if [[ "$SCALER_MODE" == "keda" ]]; then
            info "Diagnose: kubectl describe scaledobject n8n-worker -n $NAMESPACE"
            info "Check queue depth: kubectl exec -n $NAMESPACE \$(kubectl get pod -n $NAMESPACE -l app.kubernetes.io/name=redis -o name | head -1) -- redis-cli llen bull:jobs:wait"
          else
            info "Diagnose: kubectl describe hpa n8n-worker -n $NAMESPACE"
          fi
          info "Try: LOAD_REQUESTS=100 LOAD_JOB_DURATION_SECS=10 LOAD_TEST=true ./smoke-test.sh"
        fi

        if [[ "$SCALER_MODE" == "hpa" ]]; then
          info "Current HPA state:"
          kubectl get hpa -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        else
          info "Current KEDA ScaledObject state:"
          kubectl get scaledobject -n "$NAMESPACE" 2>/dev/null | while IFS= read -r line; do info "$line"; done
        fi
      fi

      if [[ -n "$load_workflow_id" ]]; then
        curl -sk -o /dev/null --max-time 10 -X POST \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}/deactivate" 2>/dev/null || true
        curl -sk -o /dev/null --max-time 10 -X DELETE \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${load_workflow_id}" 2>/dev/null || true
        info "Load test workflow deleted"
      fi
    fi
  fi
fi

fi  # end multi-only load test

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "${BOLD}  Smoke Test Summary  [mode: $DEPLOY_MODE]${RESET}"
echo -e "${BOLD}══════════════════════════════════════${RESET}"
echo -e "  ${GREEN}Passed:${RESET}  $PASS"
echo -e "  ${RED}Failed:${RESET}  $FAIL"
echo -e "  ${YELLOW}Warnings:${RESET} $WARN"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}${BOLD}RESULT: FAIL — $FAIL check(s) did not pass.${RESET}"
  exit 1
else
  echo -e "${GREEN}${BOLD}RESULT: PASS${RESET}"
  exit 0
fi
