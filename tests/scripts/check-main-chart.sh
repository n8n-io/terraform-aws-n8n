#!/usr/bin/env bash
# Render the main topology with the module's locals and pinned Helm chart.
# Requires terraform init -backend=false at the module root, Helm, and jq.
# No plan/apply, cluster access, or real credentials. The isolated state path
# prevents console from reading a deployment's state. This checks chart behavior,
# not the full helm_release.values wiring (unknown under plan-time mocks).
#
# N8N_CHART_DIR: point at a local chart checkout instead of `helm pull`-ing
# the pinned n8n_chart_version. Useful against a chart still in review (no
# released version to pull). When set, the pinned-appVersion assertion below
# is skipped: there is no release to compare it against. Resolved to an
# absolute path before this script cd's to the repo root, so a relative
# value is interpreted relative to the directory the script was invoked
# from, not the repo.
set -euo pipefail
if [[ -n "${N8N_CHART_DIR:-}" ]]; then
  N8N_CHART_DIR="$(cd "$N8N_CHART_DIR" && pwd)" || { echo "N8N_CHART_DIR not found: $N8N_CHART_DIR" >&2; exit 1; }
fi
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

split_yaml_docs() {
  # $1: helm template output with one or more "---"-separated documents, each
  # preceded by its own separator (Helm's own --show-only behavior, including
  # before the first document). $2: output file prefix. Writes "$2"NN for each
  # document, 00-indexed in source order. Chart 2.0's templates/configmap.yaml
  # renders one ConfigMap per component (shared first, then each rendered
  # component) as separate documents from one --show-only call; this is how
  # scenarios below pick out the shared one (always doc 00) without a YAML
  # multi-document parser (terraform console's yamldecode() rejects one).
  awk -v prefix="$2" 'BEGIN { n = -1 } /^---$/ { n++; next } { print > sprintf("%s%02d", prefix, n) }' "$1"
}

chart_version=$(console <<< 'var.n8n_chart_version')
chart_repository=$(console <<< 'var.n8n_chart_repository')
if [[ -n "${N8N_CHART_DIR:-}" ]]; then
  mkdir -p "$tmp/n8n"
  cp -R "$N8N_CHART_DIR"/. "$tmp/n8n"
  app_version=$(console <<< "yamldecode(file(\"$tmp/n8n/Chart.yaml\")).appVersion")
  chart_version="local $(console <<< "yamldecode(file(\"$tmp/n8n/Chart.yaml\")).version" | tr -d '"')"
  echo "Using local chart checkout $N8N_CHART_DIR (appVersion=$app_version); skipping pinned-appVersion assertion" >&2
else
  helm pull "$chart_repository/n8n" --version "$chart_version" --untar --untardir "$tmp"
  app_version=$(console <<< "yamldecode(file(\"$tmp/n8n/Chart.yaml\")).appVersion")
  [[ "$app_version" == "2.44.5" ]] || { echo "Review image fallback tests for appVersion=$app_version" >&2; exit 1; }
fi

# Chart 1.16.0 skips the single-main PDB (n8n-io/n8n-hosting#228) and adds the
# task-runner liveness probe (n8n-io/n8n-hosting#223); chart 2.0 keeps both.
# The assertions for both branch on this. A local checkout reports
# "local <version>", so the version is read from its Chart.yaml instead.
chart_semver=$(console <<< "yamldecode(file(\"$tmp/n8n/Chart.yaml\")).version" | tr -d '"')
IFS=. read -r chart_major chart_minor _ <<< "${chart_semver%%-*}"
if (( chart_major > 1 || (chart_major == 1 && chart_minor >= 16) )); then
  chart_at_least_1_16=true
else
  chart_at_least_1_16=false
fi

# Include a larger multi-main floor, plus an explicitly high ceiling for the
# single-main case. Expected results below are independent of the locals.
for replicas in 1 2 3; do
  console -var="n8n_main_hpa_min_replicas=$replicas" \
    -var='n8n_main_hpa_max_replicas=6' <<'HCL' > "$tmp/values.json"
jsonencode({strategy=local.n8n_main_strategy,pdb={enabled=true,minAvailable=1},multiMain={enabled=local.n8n_multi_main_enabled,replicas=var.n8n_main_hpa_min_replicas},replicaCount=var.n8n_main_hpa_min_replicas,hpa={main={enabled=true,minReplicas=var.n8n_main_hpa_min_replicas,maxReplicas=local.n8n_main_hpa_effective_max_replicas}}})
HCL

  for template in deployment-main deployment-worker deployment-webhook-processor hpa-main; do
    helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
      --set secretRefs.existingSecret=test-core \
      --set license.enabled=true --set license.existingSecret.name=test-license \
      --set queueMode.enabled=true --set webhookProcessor.enabled=true \
      --set keda.enabled=true --set taskRunners.enabled=true \
      --show-only "templates/$template.yaml" > "$tmp/$template.yaml"
    console <<< "jsonencode(yamldecode(file(\"$tmp/$template.yaml\")))" > "$tmp/$template.json"
  done

  # Charts from 1.16.0 (n8n-io/n8n-hosting#228) render the main PDB only while main
  # can run more than one replica, so single-main gets none there; every
  # multi-main replica count above, and every replica count on older charts,
  # still renders the module's budget. `--show-only` errors on a template
  # that renders nothing, so render the whole chart and look for the PDB's
  # source marker instead of matching Helm's error text.
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
    --set secretRefs.existingSecret=test-core \
    --set license.enabled=true --set license.existingSecret.name=test-license \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    > "$tmp/all.yaml"
  if grep -qx '# Source: n8n/templates/pdb.yaml' "$tmp/all.yaml"; then
    helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
      --set secretRefs.existingSecret=test-core \
      --set license.enabled=true --set license.existingSecret.name=test-license \
      --set queueMode.enabled=true --set webhookProcessor.enabled=true \
      --set keda.enabled=true --set taskRunners.enabled=true \
      --show-only templates/pdb.yaml > "$tmp/pdb.yaml"
    console <<< "jsonencode(yamldecode(file(\"$tmp/pdb.yaml\")))" > "$tmp/pdb.json"
    pdb_rendered=true
  else
    pdb_rendered=false
  fi

  if [[ "$replicas" == 1 ]]; then
    jq -e '.spec.strategy == {"type":"Recreate","rollingUpdate":null} and .spec.replicas == 1' "$tmp/deployment-main.json" >/dev/null
    jq -e '.spec.minReplicas == 1 and .spec.maxReplicas == 1' "$tmp/hpa-main.json" >/dev/null
    if [[ "$chart_at_least_1_16" == false ]]; then
      [[ "$pdb_rendered" == true ]] \
        || { echo "FAIL: chart ${chart_version} predates 1.16.0 and must render the single-main PDB" >&2; exit 1; }
      jq -e '.spec.minAvailable == 0' "$tmp/pdb.json" >/dev/null
    else
      [[ "$pdb_rendered" == false ]] \
        || { echo "FAIL: chart ${chart_version} must render no main PDB for single-main (n8n-io/n8n-hosting#228 skips it while main runs one replica)" >&2; exit 1; }
    fi
  else
    jq -e --argjson replicas "$replicas" \
      '(.spec | has("strategy") | not) and .spec.replicas == $replicas' "$tmp/deployment-main.json" >/dev/null
    jq -e --argjson replicas "$replicas" \
      '.spec.minReplicas == $replicas and .spec.maxReplicas == 6' "$tmp/hpa-main.json" >/dev/null
    [[ "$pdb_rendered" == true ]] \
      || { echo "FAIL: chart ${chart_version} must render the main PDB while main can run more than one replica" >&2; exit 1; }
    jq -e '.spec.minAvailable == 1' "$tmp/pdb.json" >/dev/null
    jq -e '.spec.selector.matchLabels["app.kubernetes.io/component"] == "main"' "$tmp/pdb.json" >/dev/null
  fi

  # The main-only strategy must not change worker or webhook rollouts.
  for template in deployment-worker deployment-webhook-processor; do
    jq -e '.spec | has("strategy") | not' "$tmp/$template.json" >/dev/null
  done
  if [[ "$pdb_rendered" == true ]]; then
    jq -e '.spec.selector.matchLabels["app.kubernetes.io/component"] == "main"' "$tmp/pdb.json" >/dev/null
  fi
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

# Chart 1.16.0 (n8n-io/n8n-hosting#223) probes the launcher's /healthz on port 5680
# on the worker task-runner sidecar; main and webhook-processor pods carry no
# sidecar in queue mode, so only the worker gets it. The module never sets
# N8N_RUNNERS_LAUNCHER_HEALTH_CHECK_PORT, and a caller-managed launcher file
# (n8n_task_runner_custom_config) cannot move the port: the launcher reads it
# from the environment only. $tmp/deployment-worker.json is left over from the
# last replicas iteration above, which always sets taskRunners.enabled=true.
if [[ "$chart_at_least_1_16" == true ]]; then
  jq -e '
    [.spec.template.spec.containers[] | select(.name == "task-runner") | .livenessProbe.httpGet]
    == [{"path": "/healthz", "port": 5680}]
  ' "$tmp/deployment-worker.json" >/dev/null \
    || { echo "FAIL: worker task-runner sidecar must carry the chart's launcher liveness probe on /healthz:5680" >&2; exit 1; }
  echo "PASS: chart $chart_version, worker task-runner sidecar carries the launcher liveness probe on /healthz:5680"
fi
# Every n8n container (main, worker, webhook-processor) loads the shared
# ConfigMap through envFrom (decision 0012); assert that wiring directly
# instead of only commenting on it. Name is derived from the rendered
# ConfigMap's own metadata.name (doc 00, see split_yaml_docs above), not
# hardcoded, so a chart rename still passes as long as every container
# still references whatever name the chart actually renders.
helm template n8n "$tmp/n8n" -f "$tmp/values.json" \
  --set secretRefs.existingSecret=test-core \
  --set license.enabled=true --set license.existingSecret.name=test-license \
  --set queueMode.enabled=true --set webhookProcessor.enabled=true \
  --set keda.enabled=true --set taskRunners.enabled=true \
  --show-only templates/configmap.yaml > "$tmp/envfrom-configmap-all.yaml"
split_yaml_docs "$tmp/envfrom-configmap-all.yaml" "$tmp/envfrom-configmap-doc-"
console <<< "jsonencode(yamldecode(file(\"$tmp/envfrom-configmap-doc-00\")))" > "$tmp/envfrom-configmap.json"
shared_configmap_name=$(jq -r '.metadata.name' "$tmp/envfrom-configmap.json")
for template in deployment-main deployment-worker deployment-webhook-processor; do
  jq -e --arg name "$shared_configmap_name" \
    '[.spec.template.spec.containers[].envFrom[]?.configMapRef.name] | index($name) != null' \
    "$tmp/$template.json" >/dev/null \
    || { echo "$template: no container's envFrom references shared ConfigMap $shared_configmap_name" >&2; exit 1; }
done
echo "PASS: chart $chart_version, main/worker/webhook-processor containers load the shared ConfigMap $shared_configmap_name via envFrom"

# Explicit app tags must override appVersion; runner tags follow the app unless
# explicitly set. Custom repositories must not reset either explicit tag.
# The explicit scenario deliberately picks a tag other than the pinned
# chart's appVersion (2.43.5): using the same value would make "explicit tag
# wins" indistinguishable from "fallback to appVersion" wins by coincidence.
for scenario in explicit custom; do
  args=(--set-string image.tag=2.39.6)
  repository=docker.n8n.io/n8nio/n8n
  tag=2.39.6
  runner_tag=2.39.6
  if [[ "$scenario" == custom ]]; then
    repository=registry.example.com/n8n
    tag=2.41.4-custom
    runner_tag=2.41.4
    args=(--set-string "image.repository=$repository" --set-string "image.tag=$tag"
      --set-string taskRunners.image.tag=2.41.4)
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

# redis.worker.timeout -> N8N_GRACEFUL_SHUTDOWN_TIMEOUT: the module builds
# this into local.n8n_queue_worker_settings (locals.tf) and merges it into
# the `redis.worker` Helm value only when n8n_graceful_shutdown_timeout (or a
# sibling) is set (n8n.tf); helm_release.values is unknown at plan time under
# the mock provider, so the tftest.hcl runs assert only the local's shape.
# This renders the real chart's configmap.yaml to prove an override actually
# reaches the ConfigMap key, and that leaving it unset still resolves to the
# chart's own default, closing the loop the mock provider cannot. The default
# is compared against local.n8n_chart_default_graceful_shutdown_timeout, which
# the graceful_shutdown_fits_grace_period check relies on, so a chart bump that
# moves the default fails here until that local is updated.
for scenario in default overridden; do
  timeout_vars=()
  if [[ "$scenario" == overridden ]]; then
    timeout_vars=(-var='n8n_graceful_shutdown_timeout=45')
  fi
  console ${timeout_vars[@]+"${timeout_vars[@]}"} <<< 'jsonencode({redis={worker=local.n8n_queue_worker_settings}})' \
    > "$tmp/graceful-shutdown-timeout-$scenario.json"
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/graceful-shutdown-timeout-$scenario.json" \
    --set secretRefs.existingSecret=test-core \
    --set license.enabled=true --set license.existingSecret.name=test-license \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    --show-only templates/configmap.yaml > "$tmp/configmap-$scenario-all.yaml"
  # Chart 2.0 renders one ConfigMap document per component (shared first,
  # then main/worker/webhookProcessor); N8N_GRACEFUL_SHUTDOWN_TIMEOUT is a
  # shared variable (redis.worker.timeout, templates/_env.tpl's "shared"
  # branch), so only the shared document (always doc 00) matters here.
  split_yaml_docs "$tmp/configmap-$scenario-all.yaml" "$tmp/configmap-$scenario-doc-"
  console <<< "jsonencode(yamldecode(file(\"$tmp/configmap-$scenario-doc-00\")))" > "$tmp/configmap-$scenario.json"
done
default_timeout=$(console <<< 'local.n8n_chart_default_graceful_shutdown_timeout')
jq -e --arg want "$default_timeout" '.data.N8N_GRACEFUL_SHUTDOWN_TIMEOUT == $want' "$tmp/configmap-default.json" >/dev/null
jq -e '.data.N8N_GRACEFUL_SHUTDOWN_TIMEOUT == "45"' "$tmp/configmap-overridden.json" >/dev/null
echo "PASS: chart $chart_version, n8n_graceful_shutdown_timeout reaches N8N_GRACEFUL_SHUTDOWN_TIMEOUT in the ConfigMap"

# db_postgresdb_ssl_ca_pem -> database.ssl.ca (issue #178). The module merges
# database.ssl.{enabled,rejectUnauthorized,ca} from local.postgres_ssl_ca_values
# only while a CA is delivered, and sets DB_POSTGRESDB_SSL_ENABLED /
# DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED through env.shared
# (local.n8n_postgres_ssl_env) the rest of the time. Chart 2.0 has no
# per-variable ConfigMap key reference anymore (decision 0012): every plain
# value, chart-computed or from env.shared, lands as one key in the shared
# ConfigMap's data, loaded by every n8n container through envFrom, so this
# checks that ConfigMap's data directly instead of each container's env list.
# The tftest.hcl runs can only pin the locals' shape, because
# helm_release.values is unknown under plan mocks. Without a CA the chart
# renders no DB_POSTGRESDB_SSL* key at all, so the module's own entries are
# the only ones; with a CA the chart owns DB_POSTGRESDB_SSL_ENABLED itself
# (database.ssl.enabled, unconditionally in chart 2.0), and the module must
# not also set it there, or n8n.validateEnv fails the render with a clash
# error ("env.shared.DB_POSTGRESDB_SSL_ENABLED is set by the chart..."),
# which `set -e` surfaces as this script failing outright.
ca_pem=$'\n-----BEGIN CERTIFICATE-----\nMIIFake\n-----END CERTIFICATE-----\n'
ca_trimmed=$'-----BEGIN CERTIFICATE-----\nMIIFake\n-----END CERTIFICATE-----'
for scenario in default ca; do
  ca_vars=()
  if [[ "$scenario" == ca ]]; then
    ca_vars=(-var="db_postgresdb_ssl_ca_pem=$ca_pem" -var='db_postgresdb_ssl_reject_unauthorized=true')
  fi
  console ${ca_vars[@]+"${ca_vars[@]}"} \
    <<< 'jsonencode({database=local.postgres_ssl_ca_values,env={shared=local.n8n_postgres_ssl_env}})' \
    > "$tmp/postgres-ssl-values-$scenario.json"
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/postgres-ssl-values-$scenario.json" \
    --set secretRefs.existingSecret=test-core \
    --set license.enabled=true --set license.existingSecret.name=test-license \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    --show-only templates/configmap.yaml > "$tmp/postgres-ssl-$scenario-all.yaml"
  split_yaml_docs "$tmp/postgres-ssl-$scenario-all.yaml" "$tmp/postgres-ssl-$scenario-doc-"
  console <<< "jsonencode(yamldecode(file(\"$tmp/postgres-ssl-$scenario-doc-00\")))" \
    > "$tmp/postgres-ssl-$scenario-configmap.json"
done
jq -e '.data.DB_POSTGRESDB_SSL_ENABLED == "true" and .data.DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED == "false" and (.data | has("DB_POSTGRESDB_SSL_CA") | not)' \
  "$tmp/postgres-ssl-default-configmap.json" >/dev/null
jq -e --arg ca "$ca_trimmed" \
  '.data.DB_POSTGRESDB_SSL_CA == $ca and .data.DB_POSTGRESDB_SSL_ENABLED == "true" and .data.DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED == "true"' \
  "$tmp/postgres-ssl-ca-configmap.json" >/dev/null
echo "PASS: chart $chart_version, db_postgresdb_ssl_ca_pem reaches the shared env ConfigMap as DB_POSTGRESDB_SSL_CA with no chart/module clash"

# n8n_worker_keda_min_replicas = 0 (issue #146): n8n.tf feeds
# queueMode.workerReplicaCount from local.n8n_worker_replica_count (floored at
# 1 in scaling.tf) and keda.worker.minReplicaCount from the raw input. Both
# worker templates gate on workerReplicaCount > 0, so a floor of 0 must still
# render the worker Deployment and its ScaledObject, with KEDA's own floor at
# 0. Both values are read from the module, so changing the local's floor
# fails here. This does not catch n8n.tf bypassing the local:
# helm_release.values is unknown under plan mocks, so that wiring still needs
# a real plan to verify.
console -var='n8n_worker_keda_min_replicas=0' \
  <<< 'jsonencode({queueMode={workerReplicaCount=local.n8n_worker_replica_count},keda={worker={minReplicaCount=var.n8n_worker_keda_min_replicas}}})' \
  > "$tmp/worker-floor-zero-values.json"
jq -e '.queueMode.workerReplicaCount == 1 and .keda.worker.minReplicaCount == 0' "$tmp/worker-floor-zero-values.json" >/dev/null \
  || { echo "worker floor of 0: expected workerReplicaCount=1 and minReplicaCount=0, got $(cat "$tmp/worker-floor-zero-values.json")" >&2; exit 1; }
for template in deployment-worker scaledobject-worker; do
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/worker-floor-zero-values.json" \
    --set secretRefs.existingSecret=test-core \
    --set license.enabled=true --set license.existingSecret.name=test-license \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    --set 'keda.worker.triggers[0].type=redis' \
    --set 'keda.worker.triggers[0].metadata.address=redis:6379' \
    --set 'keda.worker.triggers[0].metadata.listName=bull:jobs:wait' \
    --set 'keda.worker.triggers[0].metadata.listLength=1' \
    --show-only "templates/$template.yaml" > "$tmp/worker-floor-zero-$template.yaml"
  console <<< "jsonencode(yamldecode(file(\"$tmp/worker-floor-zero-$template.yaml\")))" > "$tmp/worker-floor-zero-$template.json"
done
jq -e '.kind == "Deployment"' "$tmp/worker-floor-zero-deployment-worker.json" >/dev/null
jq -e '.kind == "ScaledObject" and .spec.minReplicaCount == 0' "$tmp/worker-floor-zero-scaledobject-worker.json" >/dev/null
echo "PASS: chart $chart_version, worker floor of 0 still renders Deployment+ScaledObject with KEDA minReplicaCount=0"

# The module's whole env.shared map against the real chart, with the offline
# license certificate (n8n_license_cert_secret_ref) and outbound CA trust
# (n8n_extra_ca_pem) on. Three things only a render shows, because
# helm_release.values is unknown under plan mocks:
#   - n8n.validateEnv accepts every name the module puts in env.shared (a
#     clash with a chart-computed name fails the render, and set -e this
#     script);
#   - NODE_EXTRA_CA_CERTS, a literal, lands in the shared ConfigMap, and
#     N8N_LICENSE_CERT, a {secretKeyRef} value, lands in the explicit env list
#     of every n8n container instead (never in a ConfigMap);
#   - the module's own webhook and worker PodDisruptionBudgets (n8n.tf) select
#     the labels the chart actually puts on those pods.
# A -var string cannot express null, so the license key is cleared through a
# var file given after console()'s own -var flags (later flags win).
printf '{"n8n_license_key": null, "n8n_license_cert_secret_ref": {"name": "caller-license-cert"}}' > "$tmp/env-shared.tfvars.json"
console -var-file="$tmp/env-shared.tfvars.json" -var="n8n_extra_ca_pem=$ca_pem" \
  <<< 'jsonencode({env={shared=nonsensitive(local.n8n_env_shared),worker=local.n8n_env_worker},license=local.n8n_license_values})' \
  > "$tmp/env-shared-values.json"
helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/env-shared-values.json" \
  --set secretRefs.existingSecret=test-core \
  --set queueMode.enabled=true --set webhookProcessor.enabled=true \
  --set keda.enabled=true --set taskRunners.enabled=true \
  > "$tmp/env-shared-all.yaml"
for template in configmap deployment-main deployment-worker deployment-webhook-processor; do
  helm template n8n "$tmp/n8n" -f "$tmp/values.json" -f "$tmp/env-shared-values.json" \
    --set secretRefs.existingSecret=test-core \
    --set queueMode.enabled=true --set webhookProcessor.enabled=true \
    --set keda.enabled=true --set taskRunners.enabled=true \
    --show-only "templates/$template.yaml" > "$tmp/env-shared-$template.yaml"
done
split_yaml_docs "$tmp/env-shared-configmap.yaml" "$tmp/env-shared-configmap-doc-"
console <<< "jsonencode(yamldecode(file(\"$tmp/env-shared-configmap-doc-00\")))" > "$tmp/env-shared-configmap.json"
jq -e '.data.NODE_EXTRA_CA_CERTS == "/etc/n8n-certs/ca-bundle.crt" and (.data | has("N8N_LICENSE_CERT") | not)' \
  "$tmp/env-shared-configmap.json" >/dev/null \
  || { echo "FAIL: shared ConfigMap must carry NODE_EXTRA_CA_CERTS and must not carry N8N_LICENSE_CERT" >&2; exit 1; }
for template in deployment-main deployment-worker deployment-webhook-processor; do
  console <<< "jsonencode(yamldecode(file(\"$tmp/env-shared-$template.yaml\")))" > "$tmp/env-shared-$template.json"
  jq -e '
    [.spec.template.spec.containers[] | select(.name != "task-runner") | .env[]? | select(.name == "N8N_LICENSE_CERT") | .valueFrom.secretKeyRef]
    == [{"name": "caller-license-cert", "key": "cert"}]
  ' "$tmp/env-shared-$template.json" >/dev/null \
    || { echo "FAIL: $template: n8n container must read N8N_LICENSE_CERT from caller-license-cert/cert" >&2; exit 1; }
done
for pair in worker:deployment-worker webhook-processor:deployment-webhook-processor; do
  component="${pair%%:*}"
  jq -e --arg component "$component" '
    .spec.template.metadata.labels as $l
    | $l["app.kubernetes.io/name"] == "n8n"
      and $l["app.kubernetes.io/instance"] == "n8n"
      and $l["app.kubernetes.io/component"] == $component
  ' "$tmp/env-shared-${pair#*:}.json" >/dev/null \
    || { echo "FAIL: ${pair#*:} pod labels no longer match the module's $component PodDisruptionBudget selector" >&2; exit 1; }
done
echo "PASS: chart $chart_version, module env.shared renders with license cert + extra CA; PDB selectors match worker/webhook pod labels"

# N8N_AVAILABLE_BINARY_DATA_MODES / s3.storage.extraEnv: removed from the chart
# entirely in 2.0 (s3.storage now has only mode and forcePathStyle; see
# values.yaml). The chart has no path left to render the deprecated variable,
# so there is nothing left to assert against a real chart render here; a
# previous scenario did that against chart <= 1.13.0's s3.storage.extraEnv.
# N8N_DEFAULT_BINARY_DATA_MODE itself is unaffected: chart 2.0 still sets it
# from s3.storage.mode (templates/_env.tpl), just as a shared ConfigMap key
# loaded through envFrom now, like every other plain chart value (decision
# 0012), rather than as a container's explicit env entry.
