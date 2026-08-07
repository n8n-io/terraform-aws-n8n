# Upgrading n8n

This covers bumping the deployed n8n version on an existing deployment: `n8n_chart_version` and `n8n_image_tag`. It does not cover upgrading this module itself, or the AWS/Kubernetes/Helm provider versions the module depends on; see [Stability & versioning](../README.md#stability--versioning) and [Compatibility](../README.md#compatibility) in the README for those.

## Two independent knobs

| Variable | Controls | Default |
| --- | --- | --- |
| `n8n_chart_version` | The [n8n Helm chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) version, which determines the chart's templates, defaults, and which values it accepts. | `"1.10.0"`, pinned |
| `n8n_image_tag` | The n8n application image tag actually running inside the pods. | `null`, meaning the chart's own default applies (currently the floating `stable` tag) |

Bumping the image tag alone gets you a new n8n version without changing the chart's templates or value schema. Bumping the chart version can also change what values the chart accepts, so treat it as the larger-blast-radius change of the two.

Production deployments should pin `n8n_image_tag` to a concrete version rather than relying on the floating `stable` tag: with `null`, every pod that happens to reschedule (a node rotation, an unrelated `terraform apply`, a rolling restart) pulls whatever `stable` resolves to *at that moment*, which can silently cross a major version boundary.

## Before bumping

1. Read the breaking-changes doc for every major version you're crossing, not just the target: [n8n v2.0 breaking changes](https://docs.n8n.io/2-0-breaking-changes/), [n8n v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes) (scheduled October 2026). Jumping from, say, 1.x straight to a 3.x tag means both apply.
2. Check whether the target n8n version needs a newer chart version. If the chart's own `values.yaml` schema changed (new keys under `queueMode`, `taskRunners`, etc.), you need `n8n_chart_version` bumped too, not just `n8n_image_tag`. Compare `helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <candidate>` against the version currently pinned.
3. If you're on a multi-main deployment (`n8n_main_hpa_min_replicas > 1`, the module default), read [Multi-main crash-loops after a rolling restart](./troubleshooting.md#multi-main-crash-loops-after-a-rolling-restart-helm-stuck-in-pending-rollback) first. Any upgrade is a rolling restart of the main pods, so that failure mode is in scope even though it isn't specific to version bumps.

## Bumping

1. Set the new `n8n_image_tag` (and `n8n_chart_version` if step 2 above says you need it) in your `.tfvars`.
2. `terraform plan` and review the diff. Because `helm_release.n8n` is deployed with `atomic = true`, a failed rollout automatically rolls back rather than leaving pods in a half-upgraded state, but the rollback itself can time out and get stuck (see the recovery steps in the troubleshooting doc linked above).
3. `terraform apply`. Watch the main pods through the rollout:

   ```bash
   kubectl get pods -n <namespace> -l app.kubernetes.io/component=main -w
   ```

4. Confirm the version actually running matches what you set:

   ```bash
   kubectl exec -n <namespace> <main-pod> -c n8n-main -- n8n --version
   ```

## Rolling back

Set `n8n_image_tag` (and `n8n_chart_version`, if you changed it) back to the previous known-good value and re-apply. There is no separate rollback mechanism: a version bump and a version rollback are the same operation in opposite directions.

If the release is stuck in `pending-rollback` from a failed upgrade, you cannot `terraform apply` your way out of it directly; the release must be unstuck first. See [Recovery from a stuck `pending-rollback` release](./troubleshooting.md#recovery-from-a-stuck-pending-rollback-release).
