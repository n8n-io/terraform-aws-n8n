# Upgrading n8n

This covers bumping the deployed n8n version on an existing deployment. It does not cover upgrading this module or its providers; see [Stability & versioning](../README.md#stability--versioning) and [Compatibility](../README.md#compatibility) for those, and [docs/versioning.md](./versioning.md) for the full inventory of every version this module pins (providers, engines, controller charts, CI toolchain) and how each is bumped.

## Version inputs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"2.0.0-rc.1"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `null`, meaning the selected chart's default applies (`appVersion: 2.44.5` in chart `2.0.0-rc.1`) |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning the application image tag |

Bumping the image tag alone gets you a new n8n version without changing the chart's templates or value schema. Bumping the chart version can also change what values the chart accepts, so treat it as the larger-blast-radius change of the two.

Production deployments should pin `n8n_image_tag`. The chart uses `IfNotPresent`, so floating `stable` can resolve differently across nodes and create a mixed-version deployment.

## Moving from chart 1.11.0 to 1.12.0

**Inspect and pin the running application version before changing the chart.**
Chart `1.11.0` defaulted to the floating `stable` tag. Chart `1.12.0` instead
uses its `appVersion`, `2.39.6`, when `n8n_image_tag` is null. This preserves
null as "use the chart default", but can downgrade an existing application.
For example, a deployment where `stable` resolved to `2.40.5` would move back
to `2.39.6`. Helm rollback does not reverse database migrations.

1. Select the deployment's kubeconfig explicitly, especially when managing
   several clusters:

   ```bash
   export KUBECONFIG=/path/to/deployment-kubeconfig
   kubectl config current-context
   kubectl -n <namespace> get pods -l app.kubernetes.io/instance=n8n \
     -o custom-columns='POD:.metadata.name,IMAGES:.spec.containers[*].image,IMAGE_IDS:.status.containerStatuses[*].imageID'
   ```

2. Inspect the actual n8n version on each main, worker, and webhook pod.
   A `stable` image reference alone does not identify the running version:

   ```bash
   kubectl -n <namespace> exec <pod> -c <n8n-container> -- n8n --version
   ```

   If pods disagree, resolve the mixed-version deployment before proceeding.
   Record runner image versions too. Set `n8n_image_tag` to the verified
   application version in your configuration; for a custom image tag, also
   set `n8n_task_runner_image_tag` to its underlying n8n version.
3. Keep those pins while setting `n8n_chart_version = "1.12.0"`. Review a
   fresh Terraform plan and the rendered chart images before applying.
   An explicit tag prevents the fallback change, but is not proof that an
   arbitrary older application is compatible with the new chart.

In this module's queue-mode topology, chart `1.12.0` removes task-runner
sidecars from mains. Runners remain on workers when enabled; webhook pods
still have none. **Use n8n 2.13.0 or newer with this topology.** The
[upstream chart guidance](https://github.com/n8n-io/n8n-hosting/blob/v1.12.0/charts/n8n/README.md)
notes that n8n 1.108.0 through 2.12.x still needs a runner on main for MCP
Server Trigger executions. An older explicit image pin is not made compatible
by keeping its tag. Expect pod rollouts and verify JavaScript and Python Code
nodes through workers after the upgrade, including manual executions.

The CPU-capacity estimate excludes main runners only for verified upstream
`1.12.0` (including build metadata). Older, preview, future unverified, and
custom charts retain the conservative main-runner allowance. Default peak
requests fall from `16,600m` to `15,400m`; no autoscaler ceiling changes.

Chart `1.12.0` does not include worker pools. Keep using a suitable preview
or verified custom chart for `n8n_worker_pools`. The chart's KEDA worker
pause settings shipped in this same release, but this module only
supports them from chart `1.13.0`; see `n8n_worker_keda_pause` in the next
section.

## Moving from chart 1.12.0 to 1.13.0

**Pin `n8n_image_tag` before upgrading if it is still null.** The fallback
moves with `appVersion`, `2.39.6` → `2.40.5`. If a deployment is already
pinned (recommended, see above), this upgrade does not touch the running
application version at all.

**The first upgrade to `1.13.0` can interrupt running worker pods.**
Chart `1.13.0` stops setting `spec.replicas` on the worker Deployment once
KEDA owns the count (n8n-io/n8n-hosting#201). This module always meets
that condition: it configures `keda.enabled = true` with non-empty Redis
queue-depth triggers, and it floors `queueMode.workerReplicaCount` at 1,
so the chart always renders the worker `ScaledObject`.

Helm compares the previous release's manifest, which had `replicas`, with
the new one, which does not, and removes the field. Kubernetes then
defaults it to 1. This happens once, on the first `helm upgrade` to
`1.13.0`, and the target is always 1, not the configured floor:

- The worker Deployment's desired count drops to 1 whenever it was above
  1. That includes one sitting exactly at a floor above 1.
  `examples/medium` sets a floor of 5 and `examples/large` sets 20.
- Kubernetes starts terminating the surplus pods. The KEDA-managed HPA
  may raise the count again before all of them are gone, so how many are
  actually terminated depends on timing.
- A terminated worker gets SIGTERM, stops taking new jobs and waits for
  its running executions, but only up to its shutdown window. The chart
  sets `N8N_GRACEFUL_SHUTDOWN_TIMEOUT` from `redis.worker.timeout`, 30
  seconds by default; `n8n_graceful_shutdown_timeout` overrides it. Setting
  the value through `n8n_extra_env`, `n8n_worker_extra_env` or a worker
  pool's `extra_env` is rejected at plan time: the chart always renders it
  on every n8n container as a ConfigMap reference, and `extraEnv` is
  appended after it, so a second entry with the same name would silently
  replace the chart's value. The pod is also bounded by
  `n8n_termination_grace_period`: the timeout plus `n8n_prestop_sleep` must
  stay below it. An explicit `n8n_graceful_shutdown_timeout` that does not
  fit fails validation; with the input unset, the chart's 30-second default
  that does not fit only raises a plan-time warning. Executions still
  running after that can be interrupted.
- On a healthy, unpaused installation, the HPA that KEDA manages behind
  the `ScaledObject` (`kubectl get hpa keda-hpa-n8n-worker`) is expected
  to restore the floor, and scale above it as queue demand requires.
  `keda.worker.pollingInterval` does not set the HPA's reconciliation
  interval, so it does not guarantee recovery within 15 seconds.
- A deployment at the default floor of 1 that has not scaled above 1 sees
  no change.

This behavior follows from the chart templates and from how Helm and
Kubernetes handle a removed field. The live validation of this release
ran at a worker floor of 1, where the reset cannot be observed, so the
case with more than 1 worker has not been tested on a live cluster.

Raising the floor or adding headroom before the upgrade does not help,
because the reset goes to 1 either way. Scaling the live Deployment with
`kubectl` or removing `spec.replicas` from it beforehand does not help
either: neither changes the manifest Helm stored for the previous release,
which is what Helm compares against. For a deployment that runs more than
1 worker:

1. Upgrade in a low-traffic window.
2. Pause or reduce the work arriving (schedules, webhooks and upstream
   producers) and let running executions finish before you apply.
3. After the apply, confirm the worker count is back at the floor
   (`kubectl get deploy n8n-worker -n <namespace>`) and check for
   interrupted executions in the n8n execution list.

A floor of 0 behaves differently. The chart renders the worker Deployment
and the worker `ScaledObject` only when `queueMode.workerReplicaCount` is
above 0. This module sets `queueMode.workerReplicaCount` to
`max(1, n8n_worker_keda_min_replicas)`, so both always render, and
`n8n_worker_keda_min_replicas = 0` sets only KEDA's own floor. KEDA then
scales the worker Deployment to zero while the queue is empty. Earlier
module versions passed the floor through unchanged, so a floor of 0
rendered no default workers at all (`n8n-io/terraform-aws-n8n#146`). If
you were running at a floor of 0, the first apply with this release
creates the worker Deployment. It starts at 1 replica and processes any
jobs already waiting on the default queue before KEDA scales it to zero.

**Webhook processors are unaffected.** This module's webhook-processor
autoscaling is a Terraform-managed `kubernetes_horizontal_pod_autoscaler_v2`
created directly in `scaling.tf`, entirely outside the chart's own
KEDA/HPA model (see `docs/helm-chart-coverage.md`'s `keda.webhookProcessor`
row). The chart's new conditional never applies to it either before or
after this bump.

The new `keda.webhookProcessor.{pause,pausedReplicaCount}` values (pausing
webhook processors and scaling them to zero) are not exposed by this
module's inputs.

**New inputs.** `n8n_worker_keda_pause` and `n8n_worker_keda_paused_replica_count`
expose the chart's `keda.worker.pause` / `pausedReplicaCount`:
`pause = true` holds the default worker Deployment at its current count for
a maintenance window. Setting `paused_replica_count` as well holds it at that
count instead: `0` scales it to zero while jobs wait in Redis. The count only
takes effect together with `pause = true`; on its own it does nothing and the
plan warns. `n8n_worker_pools` pools are not paused; they keep
scaling on their own queues. Pause needs chart `1.13.0` or newer, and a
plan-time warning fires otherwise. The key shipped in chart `1.12.0`, but
that release still sets the worker's `spec.replicas` on every Helm upgrade,
so any later apply while paused could write the floor back over the held
count. While both inputs are unset, the module sends no pause keys to the
chart, so the Helm values do not change. The chart's matching `keda.webhookProcessor.pause`
is not exposed, for the same reason `keda.webhookProcessor` itself is not:
no webhook `ScaledObject` exists here for the annotation to land on.

## Moving from chart 1.13.0 to 1.14.0

**Pin `n8n_image_tag` before upgrading if it is still null.** The fallback
moves with `appVersion`, `2.40.5` → `2.41.4`. This is a forward move, but
it still runs that release's database migrations. A pinned deployment keeps
its running application version.

The upgrade rolls every n8n pod once, because the module's env list changes
(see the `WEBHOOK_URL` item below). Nothing else changes behavior:

- The chart no longer renders `N8N_AVAILABLE_BINARY_DATA_MODES`
  (n8n-io/n8n-hosting#185). n8n ignored it and only logged a deprecation
  warning on every start, so S3 binary storage is unaffected. The module no
  longer sends `s3.storage.availableModes` to chart `1.14.0` or newer
  either. It still sends `"filesystem,s3"` to an older pinned chart, whose
  own default (`"filesystem"`) would drop S3 on n8n 1.x. `n8n_extra_env`,
  `n8n_worker_extra_env` and `n8n_worker_pools[*].extra_env` reject the name
  at plan time. **Remove it from those inputs before upgrading.**
- The chart renamed its own `WEBHOOK_URL` ConfigMap key to
  `N8N_WEBHOOK_URL` (n8n-io/n8n-hosting#184, not in the release notes). The
  module never sets the chart's `webhook.url` or enables the chart's
  Ingress, so the chart renders neither. Separately, the module stops
  sending the deprecated `WEBHOOK_URL` itself and the same three inputs
  reject it. n8n `2.30.0` is the first release that reads
  `N8N_WEBHOOK_URL`. Older releases build webhook URLs from `WEBHOOK_URL`,
  or else from `http://<n8n_domain>:5678/`. So the module drops it only
  when the tags prove the image is current:
  - `n8n_image_tag` is a version of `2.30.0` or newer. For a custom image
    (`n8n_image_repository` set) whose tag is not a version, with task
    runners enabled, `n8n_task_runner_image_tag` is read instead. A tag
    only counts as a version when it starts with a full numeric
    `MAJOR.MINOR.PATCH`, optionally preceded by a lowercase `v`, so
    `2.30.0-mypackages` and `v2.30.0` count but `2.30.mypackages` does
    not.
  - `n8n_image_tag` is null on the default chart repository at chart
    `1.12.0` or newer, whose `appVersion` is a concrete `2.39.6` or newer.

  In every other case `WEBHOOK_URL` is still sent, and n8n logs its
  deprecation warning. That includes floating tags such as `stable` or
  `latest` (the chart pulls with `IfNotPresent`, so a node can keep running
  an older cached image), a private chart mirror (`n8n_chart_repository`)
  with a null `n8n_image_tag`, and a custom image whose tags carry no
  version. To remove the warning, pin `n8n_image_tag` to a version of
  `2.30.0` or newer. For a custom image whose tag is not a version, set
  `n8n_task_runner_image_tag` to that version with task runners enabled.
  An image older than `2.30.0` keeps `WEBHOOK_URL`, because it needs it.
- Chart validation now reports every failure in one render instead of
  stopping at the first. Messages only.

The worker-only task-runner capacity accounting covers `1.14.0`.

## Moving from chart 1.14.0 to 1.15.0

**Pin `n8n_image_tag` before upgrading if it is still null.** The fallback
moves with `appVersion`, `2.41.4` → `2.42.4`. This is a forward move, but it
still runs that release's database migrations. A pinned deployment keeps its
running application version. The n8n 2.42.0 through 2.42.4 release notes list
no breaking changes.

Every n8n pod rolls once on this bump, whether or not the image is pinned:
the chart's `helm.sh/chart` and `app.kubernetes.io/version` labels and its
`checksum/config` annotation change, as on any chart bump. With the image tag pinned,
the rendered pod templates differ only in those three fields. With a null tag
the application changes too. On a live `examples/small` upgrade from `1.14.0`
with a null tag the plan was 0 to add, 2 to change and 0 to destroy (the n8n
and AWS Load Balancer Controller Helm releases), all five n8n pods were
replaced within about two minutes, and the smoke test passed afterwards. Take the RDS snapshot first, as for any
upgrade: Helm cannot roll back database migrations.

- **PostgreSQL TLS.** The chart now renders `database.ssl.enabled` as
  `DB_POSTGRESDB_SSL_ENABLED`, the name n8n reads (n8n-io/n8n-hosting#175).
  The module delivers `database.ssl.*` only with `db_postgresdb_ssl_ca_pem`,
  and sets `DB_POSTGRESDB_SSL_ENABLED` itself through `config.extraEnv`. On
  the upstream chart at a numbered `1.15.0` or newer (not a prerelease), with
  a CA delivered, it now leaves that name to the chart; in every other case it
  keeps setting it. You do not
  need to change any input. After the upgrade a container with a CA delivered
  carries the name once, from the chart's ConfigMap, and one without a CA
  carries it once, from the module. If you set `n8n_chart_repository` to a
  private mirror, the module cannot verify that mirror's version and keeps
  its own entry regardless; if that mirror's chart also renders the name
  (chart 2.0's `n8n.validateEnv` rejects any `env.shared`/`env.worker` key
  the chart itself computes), the Helm render fails outright rather than
  silently keeping either value, so a private mirror at 1.15.0 or newer with
  a CA delivered needs its own case-by-case check.
- **"Postgres TLS now applies" in the chart's release notes** concerns
  `database.ssl.enabled: true` without a CA, which this module never sends.
  Callers who manage that value in their own chart values are the audience.
- **AWS Load Balancer Controller `3.5.0` → `3.6.0`** upgrades in place in the
  same apply (`lbc_chart_version`). Helm does not apply the new CRDs; see the
  `CHANGELOG` for what changed in them and why it does not matter here.
- The chart's new `extraObjects` and `database.ssl.existingSecret` are not
  exposed by this module.

The worker-only task-runner capacity accounting covers `1.15.0`.

## Moving from chart 1.15.0 to 1.16.0

`helm_release.n8n` plans only the `version` change: the module sends `1.16.0`
the same values it sent `1.15.0`. Every n8n pod still rolls once, because the
chart version is a pod template label (`helm.sh/chart`) and also changes each
pod's `checksum/config` annotation. With `n8n_image_tag = null` (the default)
the upgrade also moves n8n from `appVersion: 2.42.4` to `2.43.5` across its
database migrations; take the RDS snapshot first, as for any upgrade. Pin
`n8n_image_tag` to upgrade the chart alone. Rendering the module's fixtures
against both charts shows two changes beyond those labels and that checksum:

- **No main PodDisruptionBudget in single-main** (n8n-io/n8n-hosting#228).
  The chart now renders the main PDB only while main can run more than one
  replica. Multi-main (`n8n_main_hpa_min_replicas` of 2 or more, the module
  default) keeps its `minAvailable: 1` budget. Single-main
  (`n8n_main_hpa_min_replicas = 1`) loses its `minAvailable: 0` budget, and
  Helm deletes `pdb/n8n-main` on the upgrade. That budget already permitted
  every voluntary eviction, so node drains and EKS upgrades behave as before.
  The module still sends `pdb.minAvailable = 0` for single-main, which older
  charts render. `tests/scripts/smoke-test.sh` now accepts either shape for
  single-main and still requires `minAvailable: 1` for multi-main.
- **Liveness probe on the worker task-runner sidecar** (n8n-io/n8n-hosting#223):
  an HTTP GET on `/healthz`, port 5680, the launcher's own health server,
  every 10 seconds; Kubernetes restarts the sidecar after 6 failures. The
  module never sets `N8N_RUNNERS_LAUNCHER_HEALTH_CHECK_PORT`, and a
  caller-managed launcher file (`n8n_task_runner_custom_config`) cannot move
  that port, because the launcher reads it from the environment only. Main
  pods carry no sidecar in queue mode, so only workers get the probe.

No change needed: the chart's new render-time guards (more than one main
requires `multiMain.enabled` and `license.enabled`, n8n-io/n8n-hosting#229)
always pass here, because `multiMain.enabled` is derived from
`n8n_main_hpa_min_replicas`, the single-main HPA is clamped to 1, and the
license is always enabled (`n8n.tf`). The task-runner sidecar moved into a
shared template helper with the same placement and resources, so `1.16.0`
joins the worker-only task-runner capacity accounting alongside `1.12.0`
through `1.15.0`.

Not exposed by this module: `editor.url` (n8n-io/n8n-hosting#243; the module
keeps rendering its own `N8N_EDITOR_BASE_URL` and manages its own Ingress
outside the chart, so neither `ingress` nor `webhook.url` reaches the chart
either), `hostAliases` (n8n-io/n8n-hosting#167), image digests and
`persistence.annotations` (n8n-io/n8n-hosting#240), per-role
`podSecurityContext` and `containerSecurityContext` (n8n-io/n8n-hosting#236;
their defaults render the same security contexts as `1.15.0`), and
`secretRefs.env.N8N_ENCRYPTION_KEY_FILE` (n8n-io/n8n-hosting#183; the module passes its key
through `secretRefs.existingSecret`). See
[docs/helm-chart-coverage.md](./helm-chart-coverage.md) for the full table.

**Check after the upgrade** (namespace `n8n` unless you changed it; replace
`<namespace>` below with yours):

1. `helm history n8n -n <namespace>`: the newest revision is `deployed` with
   chart `n8n-1.16.0`, and no `failed` or rolled-back revision came after the
   previous one.
2. `kubectl rollout status deploy/n8n-main -n <namespace> && kubectl rollout status deploy/n8n-worker -n <namespace> && kubectl rollout status deploy/n8n-webhook-processor -n <namespace>`.
3. `kubectl get deploy n8n-main -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].image}'`
   prints your image repository with tag `2.43.5` when `n8n_image_tag = null`
   (`docker.n8n.io/n8nio/n8n:2.43.5` unless you set `n8n_image_repository`),
   or your pinned tag.
4. `kubectl get pdb -n <namespace>`: multi-main lists `n8n-main` with
   `MIN AVAILABLE` 1; single-main lists no `n8n-main`. It also lists
   `n8n-webhook-processor` when `n8n_webhook_pdb_enabled` is `true` and
   `n8n-worker` when `n8n_worker_pdb_enabled` is `true`, each with
   `MAX UNAVAILABLE` 1. A listed budget is not proof of drain protection: at
   the default `n8n_worker_keda_min_replicas = 1` the worker budget still
   permits evicting the only worker, and `n8n_worker_pools` Deployments have
   no budget.
5. When `n8n_task_runners_enabled = true`, `kubectl get deploy n8n-worker -n <namespace> -o json | jq '.spec.template.spec.containers[] | select(.name == "task-runner") | .livenessProbe.httpGet'`
   prints path `/healthz` and port `5680`. Over the next few minutes the
   worker pods' restart counts stay flat and
   `kubectl get events -n <namespace> --field-selector reason=Unhealthy` lists
   no `task-runner` liveness failures.
6. `tests/scripts/smoke-test.sh` passes.

Failure signs: the Helm upgrade fails with an `n8n` values-validation error
naming `multiMain`, `replicaCount`, or `hpa.main` (not expected from any
configuration the module accepts; report it), worker `task-runner`
containers restarting on `Liveness probe failed` (read the sidecar logs for
the launcher's health server), or the apply rolling back to `1.15.0`.

The worker-only task-runner capacity accounting covers `1.16.0`.

## Moving from chart 1.16.0 to 2.0.0-rc.1

`n8n_chart_version` now defaults to `"2.0.0-rc.1"` (was `"1.16.0"`), a chart
2.0 release candidate published at the existing default
`n8n_chart_repository` (`oci://ghcr.io/n8n-io/n8n-helm-chart`; appVersion
`2.44.5`, n8n 2.x). This module's Helm values target chart 2.0's schema
([n8n-io/n8n-hosting#250](https://github.com/n8n-io/n8n-hosting/pull/250),
[#203](https://github.com/n8n-io/terraform-aws-n8n/issues/203)): env vars are
per-component maps (`env.shared`, `env.worker`, …) rather than the `1.x`
`config.extraEnv`-style lists, with no `1.x` compatibility path. As a release
candidate rather than a numbered release, `2.0.0-rc.1` sits outside the
usual chart-pin verification tiers in `docs/versioning.md` until chart 2.0
ships a stable release. On chart `2.x`, the module's
`DB_POSTGRESDB_SSL_ENABLED` entry goes through `env.shared` and is omitted
whenever the chart itself renders Postgres SSL settings (chart major `>= 2`,
regardless of repository or prerelease suffix — see
[docs/versioning.md](./versioning.md)).

**Every n8n pod rolls once**, the same as any chart version bump: the
chart's `helm.sh/chart` label and the rendered env shape both change, so
main, worker, and webhook-processor pods all get new pod templates in one
apply.

**Secret contract change.** The core Kubernetes Secret this module creates
(and the Secret `n8n_encryption_key_secret_ref` points at, if you use that
input instead) only needs to carry `N8N_ENCRYPTION_KEY` now. Chart `1.x`
also read `N8N_HOST`, `N8N_PORT`, and `N8N_PROTOCOL` from the same Secret;
chart `2.0` gets the equivalents from `editor.url` / `webhook.url` /
`service.port` instead and no longer reads them from a Secret at all. If
your `n8n_encryption_key_secret_ref` Secret still carries those three keys
from before this upgrade, leave them — the chart simply stops reading
them — but you may remove them once you've confirmed the upgrade.

**URL change.** Before this upgrade, the module set n8n's public editor and
webhook URLs as literal `N8N_EDITOR_BASE_URL` / `WEBHOOK_URL` env entries.
Chart `2.0` instead takes them as first-class `editor.url` / `webhook.url`
values, which the module now sets from the same `n8n_domain` and webhook
base URL it always computed. The effective URLs n8n hands out do not
change; only the chart value they travel through does.

**Concurrency change.** `n8n_worker_concurrency` is now nullable and
defaults to `null`: the module then omits `queueMode.workerConcurrency`
entirely and n8n's own built-in default (`10`) applies, instead of the
module always sending `10` as before. Chart `2.0` fails to render if
`queueMode.workerConcurrency` is set together with
`executions.concurrency.productionLimit` at anything other than `-1`,
because n8n honors `productionLimit` for worker job concurrency regardless
of `workerConcurrency`, so the chart rejects the pair as a conflict rather
than silently preferring one. `n8n_execution_concurrency_limit`'s default
changes from `100` to `-1` (n8n's own "unlimited" sentinel) so the pair no
longer conflicts by default; it remains an ordinary, overridable input
beyond that. Set `n8n_worker_concurrency` together with a non-`-1`
`n8n_execution_concurrency_limit` and `terraform plan` now fails.

**This changes the effective default.** Under chart `1.x` the module always
sent both values, and n8n actually ran workers at
`n8n_execution_concurrency_limit`'s old default of `100`:
`n8n_worker_concurrency`'s old default of `10` never took effect. With
`n8n_worker_concurrency` now `null` by default and
`n8n_execution_concurrency_limit`'s default now `-1`, the effective default
becomes n8n's own worker concurrency of `10` instead. If you relied on the
old effective value, set `n8n_execution_concurrency_limit = 100` (or
whatever your old deployment actually ran at) explicitly rather than
leaving both at their new defaults.
`examples/medium` and `examples/large` were both re-benchmarked on a
pre-release chart 2.0 build (the
[n8n-io/n8n-hosting#250](https://github.com/n8n-io/n8n-hosting/pull/250)
tree, before `2.0.0-rc.1` was published; not re-run on `2.0.0-rc.1`) and
set `n8n_worker_concurrency = 10`; the measured basis, and when a higher
value is right, is in each example's `main.tf`.

**`n8n_extra_env` / `n8n_worker_extra_env` users: nothing to change.**
These inputs keep the same `list(object({ name, value }))` shape and still
reach the same pods (main + worker + webhook processor for the first,
workers only for the other); only where the module places their values
inside the chart's rendered values changed, which is this module's problem
to get right, not yours. The plan-time reserved-name guards
(`N8N_GRACEFUL_SHUTDOWN_TIMEOUT` and the other chart-managed names) are
unchanged. Separately, `N8N_CONCURRENCY_PRODUCTION_LIMIT` is now rejected
in these same inputs whenever `n8n_worker_concurrency` is set or
`n8n_execution_concurrency_limit` is not `-1`, since one of those inputs
then governs the setting instead.

**License cert and extra CA users: nothing to change.** `N8N_LICENSE_CERT`
(`n8n_license_cert_secret_ref`) and `NODE_EXTRA_CA_CERTS`
(`n8n_extra_ca_pem`) now render through `env.shared` as chart 2.0
`{ secretKeyRef }` / literal map values instead of the chart 1.x
`config.extraEnv` list; the pods, mounts, and annotations they produce are
unchanged.

**Worker pool `extra_env` users: this does not reach pool pods yet.** Chart
`2.0.0-rc.1` has no `queueMode.workerGroups`, and `worker-pools.tf` still
emits a pool's `extra_env` in the pre-2.0 list shape it expects. Until
worker pools land on a chart `2.0` release (see `docs/versioning.md`'s Chart
2.0 upgrade requirements), a worker pool's `extra_env` is not wired to any
rendered value and will not reach that pool's pods. `n8n_worker_pools` also
now requires either a `preview.workerpools.*` build or
`n8n_worker_pools_chart_verified = true` against a verified private mirror:
the prerelease exemption no longer covers an upstream `-rc.<N>` release
candidate such as `2.0.0-rc.1`, which is cut from the chart's `main` branch
and does not carry `queueMode.workerGroups` either. See
`examples/worker-pools/README.md`.

**Other chart changes you will see.** Verified against the published
`2.0.0-rc.1` release (`oci://ghcr.io/n8n-io/n8n-helm-chart`), not against a
live upgrade. Each item below is a chart default this module does not set
(confirmed against `n8n.tf`/`locals.tf`), so it applies exactly as the
chart ships it:

- **Worker readiness/liveness probes default to `httpGet`** against
  `/healthz` and `/healthz/readiness` on port `5678`, because
  `redis.healthCheck.enabled` now defaults to `true` (was `false`). Chart
  `1.x` defaulted to an exec probe (`pgrep -f 'n8n worker'`) instead. A new
  `startupProbe` (also httpGet, enabled by default) gates liveness/readiness
  on the worker finishing its database/migration/Redis startup.
- **A default per-container `securityContext`** (`containerSecurityContext`
  in `values.yaml`) now applies to the main, worker, webhook-processor, and
  task-runner containers: `allowPrivilegeEscalation: false` and
  `capabilities.drop: [ALL]`. Chart `1.x` had no equivalent per-container
  key.
- **`imagePullSecrets`** is now a top-level chart value rendered directly
  onto every pod spec. This module still uses its own pre-2.0 workaround
  (`n8n_image_pull_secrets` creates and attaches secrets to a ServiceAccount
  it manages itself) rather than this new value; see
  `local.n8n_manages_service_account` in `locals.tf`.
- **`hostAliases`** is a new top-level chart value (default `[]`) for
  rendering `/etc/hosts` entries on every pod. Not set by this module.
- **`image.digest`** (and `taskRunners.image.digest`) let you pin by digest
  alongside the tag (default `""`). Not set by this module; `n8n_image_tag`
  still only sets the tag.
- **`persistence.annotations`** is a new value for the optional PVC
  (default `{}`). Not set by this module, which leaves `persistence.enabled`
  at the chart's own default and uses no PVC.
- **`webhook.timeout`** (request timeout in milliseconds, `120000` in chart
  `1.x`) is removed from chart `2.0` entirely. This module never set it, so
  there is nothing to change here, but it is gone if you referenced it in
  your own chart-values research.
- **`enableServiceLinks`** and **`httpRoute`** are new top-level chart
  values (defaults `false` and `{enabled: false, ...}`). Not set by this
  module; see [docs/helm-chart-coverage.md](./helm-chart-coverage.md).

## Before bumping

1. Read the breaking-changes doc for every major version you're crossing, not just the target: [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/), [n8n v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes) (scheduled October 2026). Jumping from, say, 1.x straight to a 3.x tag means both apply.
2. Check whether the target n8n version needs a newer chart version. If the chart's own `values.yaml` schema changed (new keys under `queueMode`, `taskRunners`, etc.), you need `n8n_chart_version` bumped too, not just `n8n_image_tag`. Compare `helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <candidate>` against the version currently pinned.
3. If you're on a multi-main deployment (`n8n_main_hpa_min_replicas > 1`, the module default), read [Multi-main crash-loops after a rolling restart](./troubleshooting.md#multi-main-crash-loops-after-a-rolling-restart-helm-stuck-in-pending-rollback) first. Any upgrade is a rolling restart of the main pods, so that failure mode is in scope even though it isn't specific to version bumps.
4. Take and verify an RDS snapshot or equivalent external-database backup. Helm cannot roll back database migrations.

## Single-main maintenance

With `n8n_main_hpa_min_replicas = 1`, the module disables multi-main and
clamps the main HPA maximum to one, even if a higher maximum is configured.
The main Deployment uses `Recreate`: an upgrade stops old main pods before
starting the replacement. This avoids upgrade overlap without leader election,
but makes the editor, REST API, and scheduled triggers unavailable until the
replacement starts. Plan a maintenance window; missed schedule times are not
promised to replay.

Chart `2.0` renders no main `PodDisruptionBudget` at all in this topology
(`templates/pdb.yaml` renders one only when a second main pod can exist),
so node drains and managed node updates can evict the only main with
nothing to block them. Such maintenance also causes downtime. Worker and
webhook rollout strategies are unchanged.

Moving from single-main back to two or more mains is not overlap-free: the
Deployment scales the existing single-main ReplicaSet up before the
multi-main pods roll in, so for a short window two mains run without leader
election (n8n logs `Detected 2 instances claiming leader role`). Do it in a
maintenance window, and only with a license carrying
`feat:multipleMainInstances`; see `docs/troubleshooting.md` for what a failed
attempt leaves behind. The reverse direction, two or more down to one, stops
every main before the single main starts and needs no special handling.

Changing the license tier is not a key swap alone. n8n stores the activated
certificate in the database and only reads `N8N_LICENSE_ACTIVATION_KEY` when
no certificate is stored, so after changing `n8n_license_key` run
`kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n license:clear`
and restart the main; otherwise the old entitlements stay in effect.

Use `kubectl rollout restart deployment/n8n-main -n <namespace>` for a planned
main restart, rather than deleting the pod. `Recreate` controls Deployment
upgrades, not manual pod deletion or node failure; it is not a general
at-most-one-process guarantee. Do not manually scale another main while
multi-main is disabled.

Before production, verify the Deployment strategy, HPA bounds, and disruption
budget on a staging cluster. Watch a main rollout to confirm the old pods stop
before the replacement starts, and verify a node drain can evict the main.
Rendering tests cannot establish controller behavior.
`tests/scripts/smoke-test.sh` detects the single-main topology from the
multi-main flag on the main Deployment and fails if the HPA is not pinned to
`1/1`, the strategy is not `Recreate`, or a main `PodDisruptionBudget` exists
at all (chart `2.0` renders none in this topology; see above).

For scale, on `examples/small` (n8n 2.37.10, `t3.xlarge` nodes) a
`kubectl rollout restart` of the main produced about 30 seconds of ALB 503
responses with no second main pod observed at any point, and a `kubectl drain`
of the main's node completed in about 15 seconds with roughly 20 seconds of
downtime. Image pulls, database migrations, and node capacity can make your
numbers longer.

## Bumping

1. Set `n8n_image_tag`, any required `n8n_chart_version`, and, when using a custom application tag, the matching `n8n_task_runner_image_tag`.
2. `terraform plan` and review the diff and warnings. `atomic = true` rolls back Kubernetes resources after a failed rollout, not PostgreSQL migrations.
3. `terraform apply`. Watch the main pods through the rollout:

   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=main -w
   ```

4. Confirm the version actually running matches what you set:

   ```bash
   kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n --version
   ```

## Rolling back

Do not only restore the old tags. If the upgrade ran database migrations, stop n8n and either run `n8n db:revert` on the current version once per reversible migration or restore the pre-upgrade database. Check release notes for irreversible migrations. Then restore the previous chart, application, and task-runner tags and apply. See n8n's [reverting an upgrade](https://docs.n8n.io/deploy/host-n8n/install-options/install-with-npm/#reverting-an-upgrade) guidance.

If the release is stuck in `pending-rollback` from a failed upgrade, you cannot `terraform apply` your way out of it directly; the release must be unstuck first. See [Recovery from a stuck `pending-rollback` release](./troubleshooting.md#recovery-from-a-stuck-pending-rollback-release).
