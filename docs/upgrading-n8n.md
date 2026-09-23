# Upgrading n8n

This covers bumping the deployed n8n version on an existing deployment. It does not cover upgrading this module or its providers; see [Stability & versioning](../README.md#stability--versioning) and [Compatibility](../README.md#compatibility) for those, and [docs/versioning.md](./versioning.md) for the full inventory of every version this module pins (providers, engines, controller charts, CI toolchain) and how each is bumped.

## Version inputs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.12.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `null`, meaning the selected chart's default applies (`appVersion: 2.39.6` in chart `1.12.0`) |
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
or verified custom chart for `n8n_worker_pools`. The chart's new KEDA pause
settings remain at their defaults and are not exposed by this module.

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

The main PodDisruptionBudget uses `minAvailable = 0` in this topology so node
drains and managed node updates can evict the only main. Such maintenance also
causes downtime. Worker and webhook rollout strategies are unchanged.

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
`1/1`, the strategy is not `Recreate`, or the disruption budget is not
`minAvailable = 0`.

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
