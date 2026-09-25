#!/usr/bin/env bash
# Render the main topology with the module's locals and pinned Helm chart.
# Requires terraform init -backend=false at the module root, Helm, and jq.
# No plan/apply, cluster access, or real credentials. The isolated state path
# prevents console from reading a deployment's state. This checks chart behavior,
# not the full helm_release.values wiring (unknown under plan-time mocks).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for tool in terraform helm jq; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

console() {
  # grep -v blank | tail -1: the kubernetes provider (>= 3.0) emits a "Deprecated value used"
  # warning to stdout for kubernetes_namespace.n8n (unversioned; see AGENTS.md
  # on why this module still uses it), ahead of the actual result. terraform
  # console has no flag to suppress or redirect warnings away from stdout, and
  # every expression evaluated here is a single-line jsonencode(...) result, so
  # the last non-blank line is always the real value regardless of how many
  # warning blocks precede it. jq -e then rejects anything that is not JSON,
  # so a warning landing last fails loudly instead of parsing as a value.
  terraform console -no-color -state="$tmp/terraform.tfstate" \
    -var='aws_region=us-east-1' \
    -var='n8n_domain=n8n.test.example.com' \
    -var='vpc_id=vpc-test12345' \
    -var='private_subnets=["subnet-priv1","subnet-priv2"]' \
    -var='public_subnets=["subnet-pub1","subnet-pub2"]' \
    -var='vpc_cidr_block=10.0.0.0/16' \
    -var='certificate_arn=arn:aws:acm:us-east-1:123456789012:certificate/test-cert' \
    -var='n8n_license_key=test-license-key-not-real' \
    "$@" | grep -v '^[[:space:]]*$' | tail -1 | jq -er .
}

chart_version=$(console <<< 'var.n8n_chart_version')
chart_repository=$(console <<< 'var.n8n_chart_repository')
helm pull "$chart_repository/n8n" --version "$chart_version" --untar --untardir "$tmp"
app_version=$(console <<< "yamldecode(file(\"$tmp/n8n/Chart.yaml\")).appVersion")
[[ "$app_version" == "2.40.5" ]] || { echo "Review image fallback tests for appVersion=$app_version" >&2; exit 1; }

# Include a larger multi-main floor, plus an explicitly high ceiling for the
# single-main case. Expected results below are independent of the locals.
for replicas in 1 2 3; do
  console -var="n8n_main_hpa_min_replicas=$replicas" \
    -var='n8n_main_hpa_max_replicas=6' <<'HCL' > "$tmp/values.json"
jsonencode({strategy=local.n8n_main_strategy,pdb={enabled=true,minAvailable=local.n8n_main_pdb_min_available},multiMain={enabled=local.n8n_multi_main_enabled,replicas=var.n8n_main_hpa_min_replicas},replicaCount=var.n8n_main_hpa_min_replicas,hpa={main={enabled=true,minReplicas=var.n8n_main_hpa_min_replicas,maxReplicas=local.n8n_main_hpa_effective_max_replicas}}})
HCL

  for template in deployment-main deployment-worker deployment-webhook-processor hpa-main pdb; do
    helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
      --set secretRefs.existingSecret=test-core \
      --set license.enabled=true --set license.existingSecret.name=test-license \
      --set queueMode.enabled=true --set webhookProcessor.enabled=true \
      --set keda.enabled=true --set taskRunners.enabled=true \
      --show-only "templates/$template.yaml" > "$tmp/$template.yaml"
    console <<< "jsonencode(yamldecode(file(\"$tmp/$template.yaml\")))" > "$tmp/$template.json"
  done

  if [[ "$replicas" == 1 ]]; then
    jq -e '.spec.strategy == {"type":"Recreate","rollingUpdate":null} and .spec.replicas == 1' "$tmp/deployment-main.json" >/dev/null
    jq -e '.spec.minReplicas == 1 and .spec.maxReplicas == 1' "$tmp/hpa-main.json" >/dev/null
    jq -e '.spec.minAvailable == 0' "$tmp/pdb.json" >/dev/null
  else
    jq -e --argjson replicas "$replicas" \
      '(.spec | has("strategy") | not) and .spec.replicas == $replicas' "$tmp/deployment-main.json" >/dev/null
    jq -e --argjson replicas "$replicas" \
      '.spec.minReplicas == $replicas and .spec.maxReplicas == 6' "$tmp/hpa-main.json" >/dev/null
    jq -e '.spec.minAvailable == 1' "$tmp/pdb.json" >/dev/null
  fi

  # The main-only strategy must not change worker or webhook rollouts.
  for template in deployment-worker deployment-webhook-processor; do
    jq -e '.spec | has("strategy") | not' "$tmp/$template.json" >/dev/null
  done
  jq -e '.spec.selector.matchLabels["app.kubernetes.io/component"] == "main"' "$tmp/pdb.json" >/dev/null
  # Omitted image tags use appVersion, and queue-mode runners are worker-only.
  for template in deployment-main deployment-worker deployment-webhook-processor; do
    jq -e --arg image "docker.n8n.io/n8nio/n8n:$app_version" \
      '[.spec.template.spec.containers[] | select(.name != "task-runner") | .image] == [$image]' \
      "$tmp/$template.json" >/dev/null
  done
  for template in deployment-main deployment-webhook-processor; do
    jq -e '[.spec.template.spec.containers[] | select(.name == "task-runner")] | length == 0' "$tmp/$template.json" >/dev/null
  done
  jq -e --arg image "n8nio/runners:$app_version" \
    '[.spec.template.spec.containers[] | select(.name == "task-runner") | .image] == [$image]' \
    "$tmp/deployment-worker.json" >/dev/null
  echo "PASS: chart $chart_version, main replicas=$replicas, image fallback and worker-only runners"
done

# Explicit app tags must override appVersion; runner tags follow the app unless
# explicitly set. Custom repositories must not reset either explicit tag.
# The explicit scenario deliberately picks a tag other than the pinned
# chart's appVersion (2.40.5): using the same value would make "explicit tag
# wins" indistinguishable from "fallback to appVersion" wins by coincidence.
for scenario in explicit custom; do
  args=(--set-string image.tag=2.39.6)
  repository=docker.n8n.io/n8nio/n8n
  tag=2.39.6
  runner_tag=2.39.6
  if [[ "$scenario" == custom ]]; then
    repository=registry.example.com/n8n
    tag=2.40.5-custom
    runner_tag=2.40.5
    args=(--set-string "image.repository=$repository" --set-string "image.tag=$tag"
      --set-string taskRunners.image.tag=2.40.5)
  fi
  for template in deployment-main deployment-worker deployment-webhook-processor; do
    helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
      --set secretRefs.existingSecret=test-core \
      --set license.enabled=true --set license.existingSecret.name=test-license \
      --set queueMode.enabled=true --set webhookProcessor.enabled=true \
      --set keda.enabled=true --set taskRunners.enabled=true "${args[@]}" \
      --show-only "templates/$template.yaml" > "$tmp/$template.yaml"
    console <<< "jsonencode(yamldecode(file(\"$tmp/$template.yaml\")))" > "$tmp/$template.json"
    jq -e --arg image "$repository:$tag" \
      '[.spec.template.spec.containers[] | select(.name != "task-runner") | .image] == [$image]' \
      "$tmp/$template.json" >/dev/null
  done
  jq -e --arg image "n8nio/runners:$runner_tag" \
    '[.spec.template.spec.containers[] | select(.name == "task-runner") | .image] == [$image]' \
    "$tmp/deployment-worker.json" >/dev/null
  echo "PASS: chart $chart_version, $scenario image overrides"
done

# Chart 1.13.0 stops templating a worker Deployment's replicas once KEDA
# actually scales it (n8n-io/n8n-hosting#201): only true when keda.enabled
# and queueMode.enabled are both set and keda.worker.triggers is non-empty.
# The module always sets keda.enabled=true with two non-empty Redis
# triggers (n8n.tf), so this is this module's real shape, not a synthetic
# one; none of the scenarios above set keda.worker.triggers, so they never
# exercise the branch this bump actually changed for our config.
helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
  --set secretRefs.existingSecret=test-core \
  --set license.enabled=true --set license.existingSecret.name=test-license \
  --set queueMode.enabled=true --set webhookProcessor.enabled=true \
  --set keda.enabled=true --set taskRunners.enabled=true \
  --set 'keda.worker.triggers[0].type=redis' \
  --set 'keda.worker.triggers[0].metadata.address=redis:6379' \
  --set 'keda.worker.triggers[0].metadata.listName=bull:jobs:wait' \
  --set 'keda.worker.triggers[0].metadata.listLength=1' \
  --show-only templates/deployment-worker.yaml > "$tmp/deployment-worker-keda.yaml"
console <<< "jsonencode(yamldecode(file(\"$tmp/deployment-worker-keda.yaml\")))" > "$tmp/deployment-worker-keda.json"
jq -e '.spec | has("replicas") | not' "$tmp/deployment-worker-keda.json" >/dev/null
echo "PASS: chart $chart_version, worker replicas left to KEDA with real triggers"

# keda.worker.pause / pausedReplicaCount: the chart only renders the
# autoscaling.keda.sh/paused* annotations while pause=true. The pause keys come
# from the module's own local.n8n_worker_keda_pause_values (the map n8n.tf
# merges into keda.worker), not hand-written --set flags, so this proves both
# the local's shape and the chart's reading of it. Unset must render no pause
# annotations; pause with a zero hold count must render both.
for scenario in default paused; do
  pause_vars=()
  if [[ "$scenario" == paused ]]; then
    pause_vars=(-var='n8n_worker_keda_pause=true' -var='n8n_worker_keda_paused_replica_count=0')
  fi
  console ${pause_vars[@]+"${pause_vars[@]}"} <<< 'jsonencode({keda={worker=local.n8n_worker_keda_pause_values}})' \
    > "$tmp/pause-values-$scenario.json"
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/pause-values-$scenario.json" \
    --set secretRefs.existingSecret=test-core \
    --set license.enabled=true --set license.existingSecret.name=test-license \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    --set 'keda.worker.triggers[0].type=redis' \
    --set 'keda.worker.triggers[0].metadata.address=redis:6379' \
    --set 'keda.worker.triggers[0].metadata.listName=bull:jobs:wait' \
    --set 'keda.worker.triggers[0].metadata.listLength=1' \
    --show-only templates/scaledobject-worker.yaml > "$tmp/scaledobject-worker-$scenario.yaml"
  console <<< "jsonencode(yamldecode(file(\"$tmp/scaledobject-worker-$scenario.yaml\")))" > "$tmp/scaledobject-worker-$scenario.json"
done
jq -e '(.metadata.annotations // {}) | to_entries | map(select(.key | startswith("autoscaling.keda.sh/paused"))) | length == 0' \
  "$tmp/scaledobject-worker-default.json" >/dev/null
jq -e '.metadata.annotations["autoscaling.keda.sh/paused"] == "true" and .metadata.annotations["autoscaling.keda.sh/paused-replicas"] == "0"' \
  "$tmp/scaledobject-worker-paused.json" >/dev/null
echo "PASS: chart $chart_version, worker KEDA pause/pausedReplicaCount render"

# n8n_worker_keda_min_replicas = 0 (issue #146): n8n.tf floors
# queueMode.workerReplicaCount at max(1, var.n8n_worker_keda_min_replicas)
# while keda.worker.minReplicaCount stays at the raw floor. Both templates
# gate on workerReplicaCount > 0, so a caller's floor of 0 must still render
# the worker Deployment and its ScaledObject, with KEDA's own floor at 0.
worker_replica_count=$(console -var='n8n_worker_keda_min_replicas=0' <<< 'max(1, var.n8n_worker_keda_min_replicas)')
[[ "$worker_replica_count" == "1" ]] || { echo "workerReplicaCount floor: expected 1, got $worker_replica_count" >&2; exit 1; }
helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
  --set secretRefs.existingSecret=test-core \
  --set license.enabled=true --set license.existingSecret.name=test-license \
  --set queueMode.enabled=true --set "queueMode.workerReplicaCount=$worker_replica_count" \
  --set webhookProcessor.enabled=true \
  --set keda.enabled=true --set keda.worker.minReplicaCount=0 --set taskRunners.enabled=true \
  --set 'keda.worker.triggers[0].type=redis' \
  --set 'keda.worker.triggers[0].metadata.address=redis:6379' \
  --set 'keda.worker.triggers[0].metadata.listName=bull:jobs:wait' \
  --set 'keda.worker.triggers[0].metadata.listLength=1' \
  --show-only templates/deployment-worker.yaml > "$tmp/worker-floor-zero-deployment.yaml"
helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
  --set secretRefs.existingSecret=test-core \
  --set license.enabled=true --set license.existingSecret.name=test-license \
  --set queueMode.enabled=true --set "queueMode.workerReplicaCount=$worker_replica_count" \
  --set webhookProcessor.enabled=true \
  --set keda.enabled=true --set keda.worker.minReplicaCount=0 --set taskRunners.enabled=true \
  --set 'keda.worker.triggers[0].type=redis' \
  --set 'keda.worker.triggers[0].metadata.address=redis:6379' \
  --set 'keda.worker.triggers[0].metadata.listName=bull:jobs:wait' \
  --set 'keda.worker.triggers[0].metadata.listLength=1' \
  --show-only templates/scaledobject-worker.yaml > "$tmp/worker-floor-zero-scaledobject.yaml"
grep -q '^kind: Deployment$' "$tmp/worker-floor-zero-deployment.yaml"
grep -q '^kind: ScaledObject$' "$tmp/worker-floor-zero-scaledobject.yaml"
console <<< "jsonencode(yamldecode(file(\"$tmp/worker-floor-zero-scaledobject.yaml\")))" > "$tmp/worker-floor-zero-scaledobject.json"
jq -e '.spec.minReplicaCount == 0' "$tmp/worker-floor-zero-scaledobject.json" >/dev/null
echo "PASS: chart $chart_version, worker floor of 0 still renders Deployment+ScaledObject with KEDA minReplicaCount=0"
