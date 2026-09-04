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
| `taskRunners.customConfig` | `n8n_task_runner_custom_config` (null = image's baked-in launcher config). The only route to the runner allow-lists, incl. `N8N_RUNNERS_STDLIB_ALLOW` for the native Python runner |
| `taskRunners.image.repository/pullPolicy` | Not exposed; chart default used |
| `strategy` | Not exposed |
| `service.type/port` | Hardcoded `ClusterIP` / `5678` |
| `service.annotations`, `service.main.annotations`, `service.webhookProcessor.annotations`, `service.sessionAffinity` | Not exposed |
| `ingress.*` | Never set by this module. The module manages its own `kubernetes_ingress_v1` (see `create_ingress`, `ingress_annotations`) outside the chart entirely, rather than through the chart's ingress block |
| `persistence` | Not exposed. n8n itself is stateless and needs no PVC (see README) |
| `extraVolumes`, `extraVolumeMounts` | `n8n_extra_volumes` / `n8n_extra_volume_mounts`, plus one managed `credentials-overwrite` Secret volume and read-only mount appended when `n8n_credentials_overwrite_secret_ref` is set |
| `extraContainers`, `extraInitContainers` | Not exposed |
| `dnsPolicy` | Not exposed; chart default used |
| `dnsConfig` | `n8n_dns_config` (null = not set, Kubernetes' own `ndots:5` default applies). Setting `options = [{ name = "ndots", value = "1" }]` addresses `ndots:5` search-path amplification: measured 80% DNS query reduction on a 246-pod deployment, see the variable's description |
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
| `executions.data.{saveOnError,saveOnSuccess,saveOnProgress,saveManualExecutions}` | `n8n_executions_data_save_on_error` / `n8n_executions_data_save_on_success` / `n8n_executions_data_save_on_progress` / `n8n_executions_data_save_manual_executions` |
| `executions.pruning.{hardDeleteBuffer,hardDeleteInterval,softDeleteInterval}`, `executions.extraEnv` | Not exposed |
| `config.timezone` | `n8n_timezone` |
| `config.extraEnv` | The module's own escape hatch: dozens of module-managed env vars, then `n8n_extra_env` appended last. See `variables.tf`'s `n8n_extra_env` description for the reserved-name validation |
| `config.extraEnvFrom` | Not exposed |
| `license.enabled/activationKey` | Hardcoded `true` / `n8n_license_key` |
| `license.existingSecret` | Not used; the module always sets `activationKey` directly rather than referencing a pre-existing secret |
| `secretRefs.existingSecret` | Wired to the module-created `kubernetes_secret.n8n` |
| `secretRefs.env` | Not used; the module injects core config through `existingSecret` plus `config.extraEnv` instead |
| `database.{type,useExternal,host,port,database,schema,user,passwordSecret}` | Fully wired (module-managed RDS or caller-supplied `db_host`/`db_password`) |
| `database.ssl.*` | Not set via this chart key; the module sets `DB_POSTGRESDB_SSL_ENABLED`/`DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` environment variables directly, gated by `db_postgresdb_ssl_enabled` |
| *(no chart key)* DB health-check ping tuning | The chart has no values path for this, and `DB_` is a module-managed prefix so `n8n_extra_env` rejects it at plan time. Set directly as environment variables: `db_ping_timeout_ms` / `db_ping_interval_seconds` / `db_ping_max_failures_before_recovery` → the `DB_PING_*` family (all null = n8n's own defaults). See each variable's description for the pool-saturation failure mode this exists to mitigate |
| *(no chart key)* `DB_POSTGRESDB_CONNECTION_TIMEOUT` | `db_postgresdb_connection_timeout_ms` (null = n8n default `20000`). The chart has no values path for it and `DB_` is a module-managed prefix, so `n8n_extra_env` rejects it at plan time; the module sets it as an environment variable directly. It bounds pg-pool connection establishment and pool-slot acquisition, including the health monitor's `pool.connect()` call. The monitor also applies `DB_PING_TIMEOUT_MS`, so health-check acquisition stops when whichever timeout fires first |
| `redis.{enabled,useExternal,host,port}` | Module-managed ElastiCache or caller-supplied `redis_host`/`redis_port` |
| `redis.tls` | Wired to `redis_transit_encryption_enabled` (default `false`, requires `create_elasticache = true`) |
| `redis.passwordSecret` | Module-managed when Redis AUTH is active |
| `redis.timeout` | `n8n_redis_timeout_threshold` (null = chart default) |
| `redis.username` | `redis_username` (null = chart default, Redis's default user) |
| `redis.prefix` | `redis_key_prefix` (null = chart default `"bull"`; also sets `N8N_REDIS_KEY_PREFIX` directly, since the chart has no key for it: see [README → Two deployments on one Redis](../README.md#two-deployments-on-one-redis-need-redis_key_prefix)) |
| `redis.worker.lockDuration` | `n8n_queue_worker_lock_duration` (null = chart default `60000`). Chart schema enforces a minimum of `1000`, mirrored in the variable's validation so the failure lands at plan time |
| `redis.worker.lockRenewTime` | `n8n_queue_worker_lock_renew_time` (null = chart default `10000`). Validated to be at least `1000` and strictly below the lock duration, since a renew interval at or above it guarantees the lock expires before renewal fires |
| `redis.worker.stalledInterval` | `n8n_queue_worker_stalled_interval` (null = chart default `30000`). n8n documents `0` as "disable stall checking" but the chart's schema sets `minimum: 1000`, so `0` is unreachable through this chart and the variable rejects it at plan time with that explanation |
| `redis.worker.maxStalledCount` | Deliberately not exposed. The chart still renders it (default `1`), but n8n v2 removed `QUEUE_WORKER_MAX_STALLED_COUNT` and ships a breaking-change rule stating it is ignored; `scaling.service.ts` hardcodes Bull's `maxStalledCount` to `0`. Exposing it would offer control that does not exist |
| `redis.database`, `redis.dualstack`, `redis.clusterNodes`, `redis.healthCheck` | Not exposed; chart defaults used |
| `s3.enabled/bucket.name/bucket.region/auth.autoDetect/storage.mode/storage.availableModes` | Hardcoded `true` / module-managed bucket / hardcoded `true` (Pod Identity) / hardcoded `"s3"` / hardcoded `"filesystem,s3"` |
| `s3.bucket.host`, `s3.storage.forcePathStyle`, `s3.storage.extraEnv`, `s3.auth.accessKeyId/secretAccessKeySecret` | Not exposed; not needed given `auth.autoDetect = true` |

## Not currently configurable

Chart features with **no path to configure them through this module**, not even via an environment variable: `commonLabels`/`commonAnnotations` (governance tagging), `networkPolicy`, `extraContainers`/`extraInitContainers` (sidecars), `podLabels`, `nodePlacement` (per-component scheduling within the chart), `serviceAccount.automountServiceAccountToken`, `persistence`, and the chart's own `ingress.*` block (superseded by the module's own Ingress management).

If you need one of these, you currently have two options: fork/patch the chart values by managing your own `helm_release` instead of this module (losing the module's other wiring), or open an issue describing the use case.
