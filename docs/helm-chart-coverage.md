# n8n Helm chart value coverage

This module deploys the [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) via `helm_release.n8n` (`n8n.tf`) and sets a large fixed subset of the chart's `values.yaml` directly, driven by typed Terraform variables. This doc catalogs which chart values this module exposes, which it hardcodes, and which it leaves entirely untouched (chart defaults apply), so you know when you've hit the edge of what the module can do for you today.

**Verified against chart version `1.10.0`**, the module's `n8n_chart_version` default (`variables.tf`). The coverage table below reflects that version's `values.yaml` keys; the chart can add, rename, or remove keys between releases, so a row here can silently go stale if you bump `n8n_chart_version` without re-checking it. When you do bump the default, diff the two versions' `values.yaml` (e.g. `helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <new>` against the [chart's `values.yaml`](https://github.com/n8n-io/n8n-hosting/blob/main/charts/n8n/values.yaml) at the old tag) and update this doc's version line plus any affected rows in the same PR.

**There is no generic raw-values passthrough.** The only general escape hatch is `n8n_extra_env` (`config.extraEnv`), and it only reaches environment variables, not arbitrary chart values. If you need a chart key this module doesn't set and isn't an environment variable, you cannot reach it through this module's inputs: see [Not currently configurable](#not-currently-configurable) below.

## Coverage by chart section

| Chart key(s) | Module coverage |
| --- | --- |
| `image.tag` | `n8n_image_tag` (null = chart default `stable`) |
| `image.repository` | `n8n_image_repository` (null = chart default) |
| `image.pullPolicy` | Not exposed; chart default used |
| `commonLabels`, `commonAnnotations`, `podLabels` | Not exposed |
| `queueMode.enabled/workerReplicaCount/workerConcurrency` | Hardcoded `true` / `n8n_worker_keda_min_replicas` / `n8n_worker_concurrency` |
| `queueMode.workerExtraEnv` | Not exposed (worker-only env); use `n8n_extra_env` for env vars applied to *all* pods instead |
| `webhookProcessor.enabled/replicaCount/disableProductionWebhooksOnMainProcess` | Hardcoded `true` / `n8n_webhook_hpa_min_replicas` / hardcoded `true` |
| `multiMain.enabled/replicas/antiAffinity.type` | Hardcoded `true` / `n8n_main_hpa_min_replicas` / hardcoded `"preferred"` |
| `multiMain.topologySpreadConstraints`, `multiMain.setup.keyTtl/checkInterval` | Not exposed; chart default used |
| `taskRunners.enabled/nativePythonRunner/launcher.autoShutdownTimeout/resources` | `n8n_task_runners_enabled` / `n8n_task_runner_python_enabled` / `n8n_task_runner_auto_shutdown_timeout` / `n8n_task_runner_*_request`/`*_limit` |
| `taskRunners.image.tag` | `n8n_task_runner_image_tag` (null = application image tag) |
| `taskRunners.image.repository/pullPolicy`, `taskRunners.customConfig` | Not exposed; chart default used |
| `strategy` | Not exposed |
| `service.type/port` | Hardcoded `ClusterIP` / `5678` |
| `service.annotations`, `service.main.annotations`, `service.webhookProcessor.annotations`, `service.sessionAffinity` | Not exposed |
| `ingress.*` | Never set by this module. The module manages its own `kubernetes_ingress_v1` (see `create_ingress`, `ingress_annotations`) outside the chart entirely, rather than through the chart's ingress block |
| `persistence` | Not exposed. n8n itself is stateless and needs no PVC (see README) |
| `extraVolumes`, `extraVolumeMounts` | `n8n_extra_volumes` / `n8n_extra_volume_mounts` |
| `extraContainers`, `extraInitContainers` | Not exposed |
| `dnsPolicy`, `dnsConfig` | Not exposed |
| `resources.main/worker/webhookProcessor` | `n8n_{main,worker,webhook}_{cpu,memory}_{request,limit}` |
| `nodeSelector`, `tolerations`, `affinity`, `nodePlacement` | Not exposed. Node-level placement is controlled at the EKS node group instead (`node_instance_type`, `node_min`/`node_max`), not per-pod scheduling within the chart |
| `securityContext` | Not exposed; chart default (`fsGroup`/`runAsUser`/`runAsGroup` 1000) used |
| `rbac.create` | Not exposed; chart default (`true`) used |
| `serviceAccount.create/name/awsRoleArn` | `true` / `"n8n-enterprise"` by default; the module takes over the account (`create = false`) and renames it to `"n8n-enterprise-pull"` when `n8n_image_pull_secrets` is set / `awsRoleArn` wired to the module's Pod Identity IAM role either way (see [docs/pod-identity.md](./pod-identity.md)) |
| `serviceAccount.annotations`, `serviceAccount.automountServiceAccountToken` | Not exposed |
| `networkPolicy.enabled` | Not exposed; chart default (`false`) used, module creates no NetworkPolicy |
| `probes.*` (liveness/readiness/worker) | Not exposed; chart defaults used |
| `lifecycle.{main,worker,webhookProcessor}.terminationGracePeriodSeconds/preStop` | `n8n_termination_grace_period` / `n8n_prestop_sleep` |
| `hpa.main`, `hpa.webhookProcessor` | `n8n_{main,webhook}_hpa_{min,max}_replicas`, `n8n_{main,webhook}_hpa_cpu_threshold` |
| `hpa.worker` | Not used; the module scales workers via `keda.worker` instead |
| `keda.enabled/worker.{minReplicaCount,maxReplicaCount,triggers}` | Hardcoded `true` / `n8n_worker_keda_{min,max}_replicas` / two hardcoded Redis-queue-depth triggers sized by `n8n_worker_keda_jobs_per_replica` |
| `keda.worker.pollingInterval/cooldownPeriod` | Hardcoded `15` / `60` |
| `keda.webhookProcessor` | Not used; the module creates the webhook HPA externally in `scaling.tf` instead (the chart skips its own webhook HPA when `keda.enabled = true`) |
| `pdb.enabled/minAvailable` | Hardcoded `true` / `1` |
| `webhook.url` | Not set via this chart key; the module sets the equivalent `WEBHOOK_URL` environment variable directly (from `n8n_webhook_url`) |
| `webhook.enabled/timeout/extraEnv` | Not exposed; chart defaults used |
| `executions.timeout/timeoutMax/concurrency.productionLimit` | `n8n_execution_timeout` / `n8n_execution_timeout_max` / `n8n_execution_concurrency_limit` |
| `executions.pruning.enabled/maxAge/maxCount` | Hardcoded `true` / `n8n_pruning_max_age` / `n8n_pruning_max_count` |
| `executions.data.*`, `executions.pruning.{hardDeleteBuffer,hardDeleteInterval,softDeleteInterval}`, `executions.extraEnv` | Hardcoded (data.\*) or not exposed (pruning timing, extraEnv) |
| `config.timezone` | `n8n_timezone` |
| `config.extraEnv` | The module's own escape hatch: dozens of module-managed env vars, then `n8n_extra_env` appended last. See `variables.tf`'s `n8n_extra_env` description for the reserved-name validation |
| `config.extraEnvFrom` | Not exposed |
| `license.enabled/activationKey` | Hardcoded `true` / `n8n_license_key` |
| `license.existingSecret` | Not used; the module always sets `activationKey` directly rather than referencing a pre-existing secret |
| `secretRefs.existingSecret` | Wired to the module-created `kubernetes_secret.n8n` |
| `secretRefs.env` | Not used; the module injects core config through `existingSecret` plus `config.extraEnv` instead |
| `database.{type,useExternal,host,port,database,schema,user,passwordSecret}` | Fully wired (module-managed RDS or caller-supplied `db_host`/`db_password`) |
| `database.ssl.*` | Not set via this chart key; the module sets `DB_POSTGRESDB_SSL_ENABLED`/`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` environment variables directly, gated by `db_postgresdb_ssl_enabled` |
| `redis.{enabled,useExternal,host,port}` | Module-managed ElastiCache or caller-supplied `redis_host`/`redis_port` |
| `redis.tls` | Wired to `redis_transit_encryption_enabled` (default `false`, requires `create_elasticache = true`) |
| `redis.passwordSecret` | Module-managed when Redis AUTH is active |
| `redis.timeout` | `n8n_redis_timeout_threshold` (null = chart default) |
| `redis.username`, `redis.database`, `redis.prefix`, `redis.dualstack`, `redis.clusterNodes`, `redis.worker.*`, `redis.healthCheck` | Not exposed; chart defaults used |
| `s3.enabled/bucket.name/bucket.region/auth.autoDetect/storage.mode/storage.availableModes` | Hardcoded `true` / module-managed bucket / hardcoded `true` (Pod Identity) / hardcoded `"s3"` / hardcoded `"filesystem,s3"` |
| `s3.bucket.host`, `s3.storage.forcePathStyle`, `s3.storage.extraEnv`, `s3.auth.accessKeyId/secretAccessKeySecret` | Not exposed; not needed given `auth.autoDetect = true` |

## Not currently configurable

Chart features with **no path to configure them through this module**, not even via an environment variable: `commonLabels`/`commonAnnotations` (governance tagging), `networkPolicy`, `extraContainers`/`extraInitContainers` (sidecars), `podLabels`, `nodePlacement` (per-component scheduling within the chart), `serviceAccount.automountServiceAccountToken`, `persistence`, and the chart's own `ingress.*` block (superseded by the module's own Ingress management).

If you need one of these, you currently have two options: fork/patch the chart values by managing your own `helm_release` instead of this module (losing the module's other wiring), or open an issue describing the use case.
