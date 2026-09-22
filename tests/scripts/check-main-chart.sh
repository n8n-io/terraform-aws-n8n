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
[[ "$app_version" == "2.39.6" ]] || { echo "Review image fallback tests for appVersion=$app_version" >&2; exit 1; }

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
for scenario in explicit custom; do
  args=(--set-string image.tag=2.40.5)
  repository=docker.n8n.io/n8nio/n8n
  tag=2.40.5
  if [[ "$scenario" == custom ]]; then
    repository=registry.example.com/n8n
    tag=2.40.5-custom
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
  jq -e '[.spec.template.spec.containers[] | select(.name == "task-runner") | .image] == ["n8nio/runners:2.40.5"]' \
    "$tmp/deployment-worker.json" >/dev/null
  echo "PASS: chart $chart_version, $scenario image overrides"
done
