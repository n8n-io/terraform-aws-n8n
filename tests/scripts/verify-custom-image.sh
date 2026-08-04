#!/usr/bin/env bash
# verify-custom-image.sh: post-deployment verification for custom n8n images.
#
# Companion to smoke-test.sh, for deployments that set n8n_image_repository and
# n8n_custom_extensions_path to bake community packages into the image instead
# of installing them on every pod boot.
#
# smoke-test.sh answers "is this deployment healthy". This answers a narrower
# question that no amount of health checking covers: are the baked nodes
# actually loaded, and loaded on *every* pod type. The failure this exists to
# catch is asymmetric loading: a node type that resolves on main pods but not
# on workers, which looks fine in the editor and fails only in production.
#
# CI cannot run this: it needs a live cluster and a real image. It is the same
# manual-verification tier as smoke-test.sh.
#
# Usage:
#   # Run from the example directory (outputs are read automatically):
#   cd examples/small
#   ../../tests/scripts/verify-custom-image.sh
#
#   # Or point at a Terraform directory explicitly:
#   TERRAFORM_DIR=examples/small ./tests/scripts/verify-custom-image.sh
#
#   # Override any value by setting it in .env (next to this script,
#   # or next to terraform.tfstate):
#   cp tests/scripts/.env.example tests/scripts/.env
#
# Optional settings:
#   EXPECT_IMAGE_REPOSITORY   assert the deployed repository matches
#   EXPECT_EXTENSIONS_PATH    assert N8N_CUSTOM_EXTENSIONS matches
#   CUSTOM_NODE_WORKFLOW      path to a workflow JSON that uses a baked node,
#                             which enables the end-to-end execution check
#                             (also needs N8N_URL and N8N_API_KEY)
#
# Priority: .env explicit values > Terraform outputs > built-in defaults.

set -euo pipefail

# ── Load .env ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _env_candidate in "$SCRIPT_DIR/.env" "$(pwd)/.env"; do
  if [[ -f "$_env_candidate" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$_env_candidate"; set +a
    break
  fi
done

# ── Read from Terraform outputs ───────────────────────────────────────────────

TERRAFORM_DIR="${TERRAFORM_DIR:-$(pwd)}"

if command -v terraform &>/dev/null && [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
  echo -e "\033[0;36m↳\033[0m  Reading values from Terraform state in: $TERRAFORM_DIR"

  tf_namespace=$(terraform -chdir="$TERRAFORM_DIR" output -raw namespace 2>/dev/null || true)
  tf_n8n_url=$(terraform -chdir="$TERRAFORM_DIR" output -raw n8n_url 2>/dev/null || true)
  tf_kubectl_cmd=$(terraform -chdir="$TERRAFORM_DIR" output -raw kubectl_config_command 2>/dev/null || true)

  NAMESPACE="${NAMESPACE:-$tf_namespace}"
  N8N_URL="${N8N_URL:-$tf_n8n_url}"

  echo -e "\033[0;36m↳\033[0m  namespace = ${NAMESPACE:-<not found>}"

  # Point kubectl at this deployment's cluster, so a context left pointing
  # somewhere else does not silently verify the wrong deployment.
  if [[ -n "$tf_kubectl_cmd" ]]; then
    echo -e "\033[0;36m↳\033[0m  Switching kubectl context: $tf_kubectl_cmd"
    eval "$tf_kubectl_cmd" &>/dev/null || true
  fi

  echo ""
fi

# ── Configuration ─────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-${N8N_NAMESPACE:-n8n}}"
N8N_URL="${N8N_URL:-}"
N8N_API_KEY="${N8N_API_KEY:-}"

EXPECT_IMAGE_REPOSITORY="${EXPECT_IMAGE_REPOSITORY:-}"
EXPECT_EXTENSIONS_PATH="${EXPECT_EXTENSIONS_PATH:-}"
CUSTOM_NODE_WORKFLOW="${CUSTOM_NODE_WORKFLOW:-}"

# The directory the chart mounts a volume over, on the main deployment only.
# Anything baked underneath it is hidden on mains while workers still see it.
SHADOWED_DIR="/home/node/.n8n"

# n8n writes its generated node type list here (staticCacheDir in
# packages/core/src/instance-settings/instance-settings.ts). This is what n8n
# actually loaded, as opposed to what is merely present on disk.
NODE_TYPES_JSON="/home/node/.cache/n8n/public/types/nodes.json"

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

# Per-component values are collected as newline-delimited "component|value"
# records rather than associative arrays: macOS still ships bash 3.2, which has
# no `declare -A`, and smoke-test.sh stays 3.2-compatible for the same reason.
lookup() {
  printf '%s\n' "$1" | awk -F'|' -v k="$2" '$1 == k { sub(/^[^|]*\|/, ""); print; exit }'
}

values_of() {
  printf '%s\n' "$1" | awk -F'|' 'NF > 1 { sub(/^[^|]*\|/, ""); print }'
}

# Called both at the end and from the early exit taken when the deployment
# does not use a custom image, so the two paths cannot report differently.
summarize_and_exit() {
  echo ""
  echo -e "${BOLD}══════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Custom Image Verification Summary${RESET}"
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

# First Running pod for a component label, empty if none. Used to pick a single
# pod to exec into; checks that must cover the whole fleet use pods_for instead.
pod_for() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# Every Running pod for a component label, newline-delimited.
pods_for() {
  kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# The n8n application container within a pod, as opposed to the task runner
# sidecar. The chart names it after the component (n8n-main, n8n-worker,
# n8n-webhook-processor); older and forked charts use a bare "n8n". Falling back
# to the first container is a last resort and only right by declaration order,
# so it warns: exec'ing into the runner sidecar instead would read the wrong
# process's environment and report a confident, wrong answer.
container_for() {
  local p="$1" names n
  names=$(kubectl get pod -n "$NAMESPACE" "$p" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
  for n in $names; do
    case "$n" in
      n8n|n8n-main|n8n-worker|n8n-webhook-processor) echo "$n"; return ;;
    esac
  done
  if [[ -n "$names" ]]; then
    echo "WARN: no recognised n8n container in $p (containers: $names), using the first" >&2
  fi
  echo "${names%% *}"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

header "Preflight"

require_cmd kubectl
require_cmd python3

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach the cluster. Check your kubeconfig / credentials.${RESET}" >&2
  exit 1
fi
pass "kubectl cluster connectivity"

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo -e "${RED}ERROR: namespace '$NAMESPACE' not found.${RESET}" >&2
  exit 1
fi
pass "Namespace '$NAMESPACE' exists"

MAIN=$(pod_for main)
WORKER=$(pod_for worker)
WEBHOOK=$(pod_for webhook-processor)

POD_TYPES=()
[[ -n "$MAIN" ]]    && POD_TYPES+=("main:$MAIN")
[[ -n "$WORKER" ]]  && POD_TYPES+=("worker:$WORKER")
[[ -n "$WEBHOOK" ]] && POD_TYPES+=("webhook-processor:$WEBHOOK")

if [[ ${#POD_TYPES[@]} -eq 0 ]]; then
  echo -e "${RED}ERROR: no Running n8n pods found in namespace '$NAMESPACE'.${RESET}" >&2
  exit 1
fi

for entry in "${POD_TYPES[@]}"; do
  info "${entry%%:*} → ${entry#*:}"
done
pass "Found ${#POD_TYPES[@]} running pod type(s)"

if [[ ${#POD_TYPES[@]} -lt 3 ]]; then
  warn "Expected main, worker and webhook-processor. Asymmetric loading cannot be fully checked"
fi

# ── 1. Image ──────────────────────────────────────────────────────────────────
#
# Every Running pod must run the same image. A mismatch means a partial
# rollout, and it is the state in which "works on main, fails on workers" is
# expected rather than surprising, so it is worth ruling out before anything
# else.

header "Custom image (n8n_image_repository / n8n_image_tag)"

# Every Running replica, not one per component: a half-finished rollout leaves
# one worker on the old image while its sibling already has the new one, and
# sampling a single pod per component is exactly how that stays invisible.
POD_IMAGES=""
UNREADABLE=0
for entry in "${POD_TYPES[@]}"; do
  comp="${entry%%:*}"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    c=$(container_for "$p")
    img=$(kubectl get pod -n "$NAMESPACE" "$p" \
          -o jsonpath="{.spec.containers[?(@.name=='$c')].image}" 2>/dev/null || true)
    if [[ -z "$img" ]]; then
      UNREADABLE=$((UNREADABLE + 1))
      info "$(printf '%-20s %-42s %s' "$comp" "$p" "<unreadable>")"
      continue
    fi
    POD_IMAGES="${POD_IMAGES}${comp}|${img}
"
    info "$(printf '%-20s %-42s %s' "$comp" "$p" "$img")"
  done <<< "$(pods_for "$comp")"
done

# A pod whose image could not be read is an unverified pod. Counting only the
# images that *were* readable would report convergence across the rest and read
# as a clean pass, which is the same blind spot this section exists to close.
if [[ "$UNREADABLE" -gt 0 ]]; then
  fail "$UNREADABLE pod(s) had no readable image, so convergence is unverified"
  info "Re-run once the rollout settles, or check the container names with"
  info "kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].spec.containers[*].name}'"
fi

UNIQUE_IMAGES=$(values_of "$POD_IMAGES" | sort -u | grep -c . || true)
if [[ "$UNIQUE_IMAGES" == "1" ]]; then
  pass "All pods run the same image"
elif [[ "$UNIQUE_IMAGES" == "0" ]]; then
  fail "No pod images could be read at all"
else
  fail "Pods run $UNIQUE_IMAGES different images, so the rollout is not converged"
fi

DEPLOYED_IMAGE=$(lookup "$POD_IMAGES" main)
[[ -z "$DEPLOYED_IMAGE" ]] && DEPLOYED_IMAGE=$(lookup "$POD_IMAGES" worker)
DEPLOYED_REPO="${DEPLOYED_IMAGE%:*}"

if [[ -n "$EXPECT_IMAGE_REPOSITORY" ]]; then
  if [[ "$DEPLOYED_REPO" == "$EXPECT_IMAGE_REPOSITORY" ]]; then
    pass "Image repository matches EXPECT_IMAGE_REPOSITORY"
  else
    fail "Image repository is '$DEPLOYED_REPO', expected '$EXPECT_IMAGE_REPOSITORY'"
  fi
else
  skip "Image repository assertion (set EXPECT_IMAGE_REPOSITORY to enable)"
fi

# ── 2. Task runner sidecar ────────────────────────────────────────────────────
#
# The chart derives the runner sidecar's tag from image.tag, so a custom tag
# with no n8n_task_runner_image_tag resolves to a nonexistent n8nio/runners tag.
# The release waits for readiness, so this normally fails the apply rather than
# reaching a running cluster, but a cluster that drifted after apply, or one
# deployed by an older module version, can still be sitting in it.

header "Task runner sidecar (n8n_task_runner_image_tag)"

RUNNER_IMAGES=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json, sys
seen = set()
for p in json.load(sys.stdin)["items"]:
    for c in p["spec"].get("containers", []):
        if "runner" in c["name"].lower() or "/runners" in c.get("image", ""):
            seen.add(c["image"])
for i in sorted(seen):
    print(i)
' 2>/dev/null || true)

if [[ -z "$RUNNER_IMAGES" ]]; then
  skip "No task runner sidecars found (task runners disabled, or the chart changed its container name)"
else
  while IFS= read -r img; do
    [[ -n "$img" ]] && info "runner image: $img"
  done <<< "$RUNNER_IMAGES"
  pass "Task runner sidecar present"
fi

# Any container stuck before start, with the pull failures called out by name.
PULL_TROUBLE=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json, sys
rows = []
for p in json.load(sys.stdin)["items"]:
    st = p.get("status", {})
    for cs in st.get("containerStatuses", []) + st.get("initContainerStatuses", []):
        w = (cs.get("state") or {}).get("waiting")
        if w:
            rows.append("%s|%s|%s|%s" % (p["metadata"]["name"], cs["name"],
                                         w.get("reason", "?"), (w.get("message") or "")[:120]))
for r in rows:
    print(r)
' 2>/dev/null || true)

if [[ -z "$PULL_TROUBLE" ]]; then
  pass "No containers waiting on an image pull"
else
  while IFS='|' read -r p c reason msg; do
    [[ -z "$p" ]] && continue
    if [[ "$reason" == "ImagePullBackOff" || "$reason" == "ErrImagePull" ]]; then
      fail "$p/$c: $reason"
      info "$msg"
      info "If the image tag is custom, set n8n_task_runner_image_tag to a published n8n version"
    else
      warn "$p/$c waiting: $reason"
    fi
  done <<< "$PULL_TROUBLE"
fi

# ── 3. N8N_CUSTOM_EXTENSIONS ──────────────────────────────────────────────────
#
# The module sets this on all three pod types deliberately. If it differs
# between them, a node type resolves on some pods and not others.

header "Extensions path (n8n_custom_extensions_path)"

POD_EXTS=""
for entry in "${POD_TYPES[@]}"; do
  comp="${entry%%:*}"; p="${entry#*:}"
  c=$(container_for "$p")
  v=$(kubectl exec -n "$NAMESPACE" "$p" -c "$c" -- printenv N8N_CUSTOM_EXTENSIONS 2>/dev/null || true)
  POD_EXTS="${POD_EXTS}${comp}|${v}
"
  info "$(printf '%-20s N8N_CUSTOM_EXTENSIONS=%s' "$comp" "${v:-<absent>}")"
done

EXT_PATH=$(lookup "$POD_EXTS" main)
[[ -z "$EXT_PATH" ]] && EXT_PATH=$(lookup "$POD_EXTS" worker)

if [[ -z "$EXT_PATH" ]]; then
  warn "N8N_CUSTOM_EXTENSIONS is not set on any pod, so there is nothing further to verify"
  info "This script only applies to deployments that set n8n_custom_extensions_path"
  summarize_and_exit
fi

MISMATCH=0
for entry in "${POD_TYPES[@]}"; do
  comp="${entry%%:*}"
  [[ "$(lookup "$POD_EXTS" "$comp")" != "$EXT_PATH" ]] && MISMATCH=1
done

if [[ "$MISMATCH" -eq 0 ]]; then
  pass "Same extensions path on every pod type: $EXT_PATH"
else
  fail "N8N_CUSTOM_EXTENSIONS differs between pod types, so node types will resolve inconsistently"
fi

if [[ -n "$EXPECT_EXTENSIONS_PATH" ]]; then
  if [[ "$EXT_PATH" == "$EXPECT_EXTENSIONS_PATH" ]]; then
    pass "Extensions path matches EXPECT_EXTENSIONS_PATH"
  else
    fail "Extensions path is '$EXT_PATH', expected '$EXPECT_EXTENSIONS_PATH'"
  fi
fi

# ── 4. The shadowing guard ────────────────────────────────────────────────────
#
# The module rejects a path under /home/node/.n8n at plan time. This re-checks
# it against the running cluster, which catches a chart change that moves the
# mount, or a release edited outside Terraform.

header "Shadowed-directory guard"

if [[ "$EXT_PATH" == "$SHADOWED_DIR" || "$EXT_PATH" == "$SHADOWED_DIR"/* ]]; then
  fail "Extensions path is under $SHADOWED_DIR, which the chart mounts over on main pods"
  info "Baked nodes will be invisible on mains and visible on workers"
else
  pass "Extensions path is outside $SHADOWED_DIR"
fi

kubectl get deploy -n "$NAMESPACE" -o json 2>/dev/null | python3 -c '
import json, sys
shadowed = sys.argv[1]
for d in json.load(sys.stdin)["items"]:
    name = d["metadata"]["name"]
    spec = d["spec"]["template"]["spec"]
    kinds = {}
    for v in spec.get("volumes", []):
        if "emptyDir" in v:
            kinds[v["name"]] = "emptyDir"
        elif "persistentVolumeClaim" in v:
            kinds[v["name"]] = "pvc:" + v["persistentVolumeClaim"]["claimName"]
        else:
            kinds[v["name"]] = ",".join(k for k in v if k != "name")
    mounts = [(m["name"], m["mountPath"]) for c in spec.get("containers", [])
              for m in c.get("volumeMounts", []) if shadowed in m["mountPath"]]
    if mounts:
        for n, path in mounts:
            print("      %-24s %-22s -> %s" % (name, path, kinds.get(n, "?")))
    else:
        print("      %-24s (nothing mounted under %s)" % (name, shadowed))
' "$SHADOWED_DIR" 2>/dev/null || true

# ── 5. Baked files on disk ────────────────────────────────────────────────────
#
# Necessary but not sufficient: files can be present and still not loaded,
# which is exactly the trap of installing into the image's global node_modules.

header "Baked node files on disk"

for entry in "${POD_TYPES[@]}"; do
  comp="${entry%%:*}"; p="${entry#*:}"
  c=$(container_for "$p")
  count=$(kubectl exec -n "$NAMESPACE" "$p" -c "$c" -- \
          sh -c "find '$EXT_PATH' -name '*.node.js' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r' || echo 0)
  if [[ "${count:-0}" -gt 0 ]]; then
    pass "$(printf '%-20s %s .node.js file(s) under %s' "$comp" "$count" "$EXT_PATH")"
  else
    fail "$(printf '%-20s no .node.js files under %s' "$comp" "$EXT_PATH")"
    info "The loader globs <path>/node_modules/<pkg>/**/*.node.js, so check the image layout"
  fi
done

# ── 6. What n8n actually loaded ───────────────────────────────────────────────
#
# The generated type list is the authority. Parse it as JSON and use the array
# length: grepping for '"name":' counts every nested property key too, which
# inflates ~1k node types into six figures.

header "Node types n8n loaded"

if [[ -z "$MAIN" ]]; then
  skip "No main pod available to read the generated type list"
else
  MAIN_C=$(container_for "$MAIN")
  LOADED=$(kubectl exec -n "$NAMESPACE" "$MAIN" -c "$MAIN_C" -- node -e '
const fs = require("fs");
const f = process.argv[1];
if (!fs.existsSync(f)) { console.log("MISSING"); process.exit(0); }
let types;
try { types = JSON.parse(fs.readFileSync(f, "utf8")); }
catch (e) { console.log("UNPARSEABLE"); process.exit(0); }
const names = (Array.isArray(types) ? types : []).map(t => t && t.name).filter(Boolean);
console.log("TOTAL " + names.length);
names.filter(n => n.startsWith("CUSTOM.")).sort().forEach(n => console.log("CUSTOM " + n));
' "$NODE_TYPES_JSON" 2>/dev/null || true)

  if [[ -z "$LOADED" || "$LOADED" == "MISSING" ]]; then
    warn "No generated type list at $NODE_TYPES_JSON"
    info "It is written on first editor load, so open the n8n UI once, then re-run"
  elif [[ "$LOADED" == "UNPARSEABLE" ]]; then
    warn "Generated type list at $NODE_TYPES_JSON is not valid JSON"
  else
    total=$(echo "$LOADED" | awk '/^TOTAL /{print $2}')
    custom=$(echo "$LOADED" | awk '/^CUSTOM /{print $2}')
    custom_count=$(echo "$custom" | grep -c . || true)

    info "$total node types loaded in total"

    if [[ "${custom_count:-0}" -gt 0 ]]; then
      pass "$custom_count node type(s) loaded from the custom directory"
      while IFS= read -r n; do
        [[ -n "$n" ]] && info "$n"
      done <<< "$custom"
      info "Note the CUSTOM. prefix: a node installed from npm as"
      info "n8n-nodes-example.myNode is CUSTOM.myNode here, and workflows"
      info "referencing the old type will not resolve"
    else
      fail "No CUSTOM.* node types loaded: the baked nodes are on disk but not loaded"
      info "Check that N8N_CUSTOM_EXTENSIONS points at the directory *containing*"
      info "node_modules, not at node_modules itself"
    fi
  fi
fi

# ── 7. End-to-end execution ───────────────────────────────────────────────────
#
# The checks above prove main loaded the nodes. They cannot prove a worker did:
# workers serve no type list. Only executing a workflow that uses a baked node
# through the queue settles it, and that needs a workflow specific to whichever
# node was baked, so the caller supplies one.

header "End-to-end execution of a baked node"

if [[ -z "$CUSTOM_NODE_WORKFLOW" ]]; then
  skip "Execution test (set CUSTOM_NODE_WORKFLOW to a workflow JSON using a baked node)"
  info "Without it, worker-side loading is unverified: main and workers can differ"
elif [[ ! -f "$CUSTOM_NODE_WORKFLOW" ]]; then
  fail "CUSTOM_NODE_WORKFLOW file not found: $CUSTOM_NODE_WORKFLOW"
elif [[ -z "$N8N_URL" || -z "$N8N_API_KEY" ]]; then
  skip "Execution test (requires N8N_URL and N8N_API_KEY)"
else
  require_cmd curl

  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CUSTOM_NODE_WORKFLOW" 2>/dev/null; then
    fail "CUSTOM_NODE_WORKFLOW is not valid JSON: $CUSTOM_NODE_WORKFLOW"
  else
    # The webhook path is rewritten to a unique value so repeat runs, and
    # concurrent runs against the same instance, do not collide.
    webhook_path="verify-custom-image-$$"

    # One pass over the workflow: what it contains, and the payload to send.
    probe=$(python3 -c '
import json, sys
wf = json.load(open(sys.argv[1]))
path = sys.argv[2]
nodes = wf.get("nodes", [])
types = [str(n.get("type", "")) for n in nodes]
print("CUSTOM " + ("yes" if any(t.startswith("CUSTOM.") for t in types) else "no"))
print("WEBHOOK " + ("yes" if any(t.endswith(".webhook") for t in types) else "no"))
for n in nodes:
    if str(n.get("type", "")).endswith(".webhook"):
        # httpMethod is forced along with the path: the trigger below is a POST,
        # and a workflow whose webhook is pinned to GET would fail it with a 404
        # that reads as a broken deployment rather than a mismatched fixture.
        n.setdefault("parameters", {})["path"] = path
        n["parameters"]["httpMethod"] = "POST"
        n["webhookId"] = path
print("PAYLOAD " + json.dumps({
    "name": "__verify-custom-image__",
    "nodes": nodes,
    "connections": wf.get("connections", {}),
    "settings": wf.get("settings", {}),
}))
' "$CUSTOM_NODE_WORKFLOW" "$webhook_path" 2>/dev/null || true)

    uses_custom=$(printf '%s\n' "$probe" | awk '/^CUSTOM /{print $2; exit}')
    has_webhook=$(printf '%s\n' "$probe" | awk '/^WEBHOOK /{print $2; exit}')
    payload=$(printf '%s\n' "$probe" | sed -n 's/^PAYLOAD //p')

    # A workflow with no baked node would still execute and still report
    # success, which is worse than not running it at all: the log would read
    # as proof of something that was never exercised.
    if [[ "$uses_custom" != "yes" ]]; then
      fail "Supplied workflow references no CUSTOM.* node type, so it cannot test the baked nodes"
      info "Use the type name as n8n loaded it, for example CUSTOM.myNode"
    elif [[ "$has_webhook" != "yes" ]]; then
      fail "Supplied workflow has no webhook trigger"
      info "A webhook trigger is what routes the execution through a worker"
    elif [[ -z "$payload" ]]; then
      fail "Could not build a workflow payload from $CUSTOM_NODE_WORKFLOW"
    else
      pass "Supplied workflow references a CUSTOM.* node type"

      create_response=$(curl -sk -w "\n%{http_code}" --max-time 15 -X POST \
        -H "X-N8N-API-KEY: $N8N_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${N8N_URL%/}/api/v1/workflows" 2>/dev/null || echo -e "\n000")

      create_status=$(echo "$create_response" | tail -1)
      create_body=$(echo "$create_response" | sed '$d')

      if [[ "$create_status" != "200" ]]; then
        fail "Failed to create the test workflow (HTTP $create_status)"
        info "Response: $create_body"
      else
        workflow_id=$(echo "$create_body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
        pass "Test workflow created (id: $workflow_id)"

        activate_status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${workflow_id}/activate" 2>/dev/null || echo "000")

        if [[ "$activate_status" != "200" ]]; then
          fail "Failed to activate the test workflow (HTTP $activate_status)"
          info "An unresolvable node type is the usual cause, so check the CUSTOM.* name"
        else
          pass "Test workflow activated"

          info "Waiting 5s for the webhook-processor to register the webhook..."
          sleep 5

          trigger_status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            -d '{"verify_custom_image": true}' \
            "${N8N_URL%/}/webhook/${webhook_path}" 2>/dev/null || echo "000")

          if [[ ! "$trigger_status" =~ ^2 ]]; then
            fail "Webhook trigger failed (HTTP $trigger_status)"
            info "Webhook URL: ${N8N_URL%/}/webhook/${webhook_path}"
          else
            pass "Webhook triggered (HTTP $trigger_status)"

            exec_state="unknown"
            for i in $(seq 1 15); do
              sleep 2
              exec_state=$(curl -sk --max-time 10 \
                -H "X-N8N-API-KEY: $N8N_API_KEY" \
                "${N8N_URL%/}/api/v1/executions?workflowId=${workflow_id}&limit=1" 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('data',[]); print(e[0]['status'] if e else 'pending')" 2>/dev/null \
                || echo "unknown")

              if [[ "$exec_state" == "success" ]]; then
                pass "A worker executed the baked node successfully"
                info "This is the check that rules out main-only loading"
                break
              elif [[ "$exec_state" == "error" || "$exec_state" == "crashed" ]]; then
                fail "Execution ended with status: $exec_state"
                info "If the error is 'Unrecognized node type', the workers did not load"
                info "the custom directory even though main did"
                info "Worker logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=worker --tail=50"
                break
              elif [[ "$i" -eq 15 ]]; then
                warn "Execution still in state '$exec_state' after 30s"
              fi
            done
          fi
        fi

        curl -sk -o /dev/null --max-time 10 -X POST \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${workflow_id}/deactivate" 2>/dev/null || true
        curl -sk -o /dev/null --max-time 10 -X DELETE \
          -H "X-N8N-API-KEY: $N8N_API_KEY" \
          "${N8N_URL%/}/api/v1/workflows/${workflow_id}" 2>/dev/null || true
        info "Test workflow deleted"
      fi
    fi
  fi
fi

# ── 8. Boot-time installs ─────────────────────────────────────────────────────
#
# Baking exists to remove the npm install on every pod boot. Leaving
# n8n_reinstall_missing_packages on puts it straight back: the installed_packages
# rows live in Postgres and survive the switch to a baked image, so every pod
# reinstalls them at startup and the same nodes end up loaded twice under two
# different names.

header "Boot-time package installs"

REINSTALL=""
if [[ -n "$MAIN" ]]; then
  REINSTALL=$(kubectl exec -n "$NAMESPACE" "$MAIN" -c "$(container_for "$MAIN")" -- \
              printenv N8N_REINSTALL_MISSING_PACKAGES 2>/dev/null || true)
fi

REINSTALL_LC=$(printf '%s' "$REINSTALL" | tr '[:upper:]' '[:lower:]')

case "$REINSTALL_LC" in
  true)
    warn "N8N_REINSTALL_MISSING_PACKAGES=true alongside a baked image"
    info "Every pod will npm-install the packages again at boot, which is the"
    info "cost baking was meant to remove. Set n8n_reinstall_missing_packages = false."
    ;;
  "")
    pass "N8N_REINSTALL_MISSING_PACKAGES not set (chart default)"
    ;;
  *)
    pass "N8N_REINSTALL_MISSING_PACKAGES=$REINSTALL"
    ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────

summarize_and_exit
