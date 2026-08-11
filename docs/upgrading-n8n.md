# Upgrading n8n

This covers bumping the deployed n8n version on an existing deployment. It does not cover upgrading this module or its providers; see [Stability & versioning](../README.md#stability--versioning) and [Compatibility](../README.md#compatibility).

## Version inputs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.10.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `null`, meaning the chart's own default applies (currently the floating `stable` tag) |
| `n8n_task_runner_image_tag` | Task runner image tag; keep aligned with the underlying n8n version when using a custom application tag. | `null`, meaning the application image tag |

Bumping the image tag alone gets you a new n8n version without changing the chart's templates or value schema. Bumping the chart version can also change what values the chart accepts, so treat it as the larger-blast-radius change of the two.

Production deployments should pin `n8n_image_tag`. The chart uses `IfNotPresent`, so floating `stable` can resolve differently across nodes and create a mixed-version deployment.

## Before bumping

1. Read the breaking-changes doc for every major version you're crossing, not just the target: [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/), [n8n v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes) (scheduled October 2026). Jumping from, say, 1.x straight to a 3.x tag means both apply.
2. Check whether the target n8n version needs a newer chart version. If the chart's own `values.yaml` schema changed (new keys under `queueMode`, `taskRunners`, etc.), you need `n8n_chart_version` bumped too, not just `n8n_image_tag`. Compare `helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <candidate>` against the version currently pinned.
3. If you're on a multi-main deployment (`n8n_main_hpa_min_replicas > 1`, the module default), read [Multi-main crash-loops after a rolling restart](./troubleshooting.md#multi-main-crash-loops-after-a-rolling-restart-helm-stuck-in-pending-rollback) first. Any upgrade is a rolling restart of the main pods, so that failure mode is in scope even though it isn't specific to version bumps.
4. Take and verify an RDS snapshot or equivalent external-database backup. Helm cannot roll back database migrations.

## Bumping

1. Set `n8n_image_tag`, any required `n8n_chart_version`, and—when using a custom application tag—the matching `n8n_task_runner_image_tag`.
2. `terraform plan` and review the diff. `atomic = true` rolls back Kubernetes resources after a failed rollout, not PostgreSQL migrations.
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
