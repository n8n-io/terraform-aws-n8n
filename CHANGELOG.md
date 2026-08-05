# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md → Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Fixed

- `aws_eks_node_group.n8n` no longer fights the Cluster Autoscaler over
  `desired_size`. The node group is tagged for autoscaler auto-discovery
  (`k8s.io/cluster-autoscaler/enabled`), but Terraform still tracked
  `desired_size` as authoritative. Once the autoscaler moved the live count
  away from `var.node_desired`, every subsequent plan proposed resetting it
  back down, and applying that drains live nodes: reported in
  [#50](https://github.com/n8n-io/terraform-aws-n8n/issues/50) on module
  0.2.0, an apply
  during an HPA scale-up event reset `desired_size` from 6 to 3, draining 3
  nodes mid-rollout and evicting n8n pods. `scaling_config[0].desired_size`
  is now in the node group's `lifecycle.ignore_changes`, the standard pattern
  for autoscaler-managed node groups. `node_desired` now only sets the size at
  creation; its description was updated to say so.

- The module-managed Ingress routed only `/webhook` to the webhook processors.
  n8n disables five endpoint families on the main pods when
  `disableProductionWebhooksOnMainProcess` is set, which this module always
  sets, so `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp` reached
  `n8n-main`, where no handler is registered for them. The request then falls
  through to the editor's single-page-app handler, which answers `200` with the
  editor HTML, so the caller logs a success and nothing runs. In practice that
  broke Wait-node resumption, Slack and Telegram human-in-the-loop callbacks,
  Form Trigger nodes, and MCP Server Triggers. All five prefixes now route to
  `n8n-webhook-processor`.

  Four of them match `templates/ingress-webhook.yaml` in the upstream Helm
  chart. `/mcp` does not: the chart omits it, even though n8n registers the live
  MCP handler in the same block the flag disables
  (`packages/cli/src/abstract-server.ts`). That looks like a gap in the chart
  and is worth raising upstream. Upgrade is in place: the plan shows added
  Ingress paths, no ALB replacement.

  Verified by upgrading a real 0.2.0 deployment rather than by inspection. A
  0.2.0 cluster was applied, then repointed at this version: the `moved` block
  reported `kubernetes_ingress_v1.n8n[0]` as `(moved from
  kubernetes_ingress_v1.n8n)` and `Plan: 0 to add, 2 to change, 0 to destroy`.
  The Ingress kept its identity and the ALB was not replaced. The two in-place
  changes are the added path prefixes and the alias record re-reading its ALB
  target. No other resource planned a replacement across the upgrade.

  This resolves [#54](https://github.com/n8n-io/terraform-aws-n8n/issues/54).
  The MCP session affinity concern reported alongside the routing gap does not
  apply to any n8n version this module deploys: n8n stores MCP session IDs in
  Redis ([n8n#25147](https://github.com/n8n-io/n8n/pull/25147)) and any webhook
  replica can serve any session. The stale known-limitation notes were removed
  from README.md and docs/troubleshooting.md, and the split-ingress example's
  `mcp_single_replica` workaround variable was removed with them.

- Every `helm upgrade` scaled the main, worker and webhook deployments down to 2
  replicas before their autoscalers climbed back. The chart renders
  `spec.replicas` unconditionally on all three deployments, from
  `multiMain.replicas`, `queueMode.workerReplicaCount` and
  `webhookProcessor.replicaCount`, with no regard for whether an HPA or a KEDA
  ScaledObject also owns the field. The module passed a constant `2` for all
  three, so Helm and the autoscaler disagreed on every apply.

  It reset any scale-up, not only a configured floor: a deployment the HPA had
  taken to 8 under load went back to 2 and had to climb again. It cost most where
  the floor was highest, since `examples/large` runs a webhook floor of 30 and a
  worker floor of 20, both of which collapsed to 2 on each apply and then had to
  be re-scaled while traffic was already arriving. Same class of defect as
  [#51](https://github.com/n8n-io/terraform-aws-n8n/issues/51): pod count driven
  by two sources that disagree.

  All three are now wired to their autoscaler's floor
  (`n8n_main_hpa_min_replicas`, `n8n_worker_keda_min_replicas`,
  `n8n_webhook_hpa_min_replicas`), so the manifest agrees with the autoscaler on
  where the deployment rests. Helm's write is a no-op while the deployment sits
  at its floor.

  This bounds the drop rather than eliminating it, and the distinction matters if
  you upgrade under load. A deployment the autoscaler has taken above its floor
  is still written back down to the floor, and still has to climb again: for
  `examples/large` that is a webhook deployment at 80 dropping to 30 instead of
  to 2. Bounding it at the floor is the most a caller of this chart can do, since
  the field is rendered unconditionally and no value omits it, and reading the
  live replica count back into the plan would make every plan depend on current
  cluster state. Eliminating it needs the chart to guard `spec.replicas` on
  whether an autoscaler owns the deployment, which is an upstream change.
  Deployments resting on the default floors see no change, since those already
  matched the constant.

  Verified on a live cluster rather than by inspection, because no plan-time test
  can observe a `helm upgrade`. A 3-node cluster was applied from the previous
  version with a webhook floor of 5 and a worker floor of 3, then given one
  unrelated config change to trigger an upgrade. Sampling `spec.replicas` every
  two seconds through it:

  ```
     5 samples  webhook=5 worker=3   <- steady state at the configured floors
     2 samples  webhook=2 worker=2   <- Helm re-asserts spec.replicas=2
    41 samples  webhook=5 worker=3   <- HPA and KEDA climb back
  ```

  Webhook capacity dropped 60% and worker 33% mid-upgrade, and `helm get manifest`
  confirmed the release's stored desired state read `replicas: 2` for all three
  while the cluster ran 5 and 3. Repointing at this version planned `Plan: 0 to
  add, 1 to change, 0 to destroy`, an in-place `helm_release` update with no
  replacement of the ALB, RDS instance, KMS key or any PVC, and moved the stored
  manifest to 5 and 3. A second, pod-churning upgrade of the same duration as the
  one that collapsed (1m45s) held every one of 48 samples steady. Both runs had
  the deployments resting at their floors, which is the case the fix closes; the
  above-the-floor case described above was not exercised on the cluster.

  A no-op re-apply does **not** show the defect, since Terraform only runs
  `helm upgrade` when the values change. It takes a real config change or version
  bump, which is also when it surfaces in practice.

- `db_allowed_cidr_blocks` is now de-duplicated against the always-allowed VPC
  CIDR. Passing the VPC CIDR explicitly, or repeating an entry, previously
  produced a security group rule with the same permission twice, which AWS
  rejects at apply with `InvalidParameterValue: The same permission must not
  appear multiple times` while the plan looked clean. Verified against the live
  API before fixing.

### Added

- Plan-time warning when the autoscaler ceilings, the per-pod CPU requests, and
  the node group are out of step. `scaling.tf` models the CPU arithmetic and the
  `autoscaling_maxima_fit_node_group_capacity` check reports the numbers when the
  three pod families at their maxima cannot fit in `node_max` ×
  `node_instance_type`. The demand side sums the main, worker and webhook
  ceilings, counting task runner sidecars on main and worker pods only, since the
  chart adds no sidecar to webhook processors. The supply side discounts each
  node's vCPU by the EKS kubelet reservation, the `aws-node` and `kube-proxy`
  DaemonSets, and this module's cluster add-ons.

  A `check` block, so it never fails a plan: the model is an approximation, and
  staging higher ceilings before raising `node_max` is legitimate. vCPU is
  derived from the instance size rather than read from
  `data.aws_ec2_instance_type`, because a `check` whose condition is unknown at
  plan is a hard error rather than a warning and a data source read is exactly
  what Terraform can defer to apply. An advisory hint must not be able to break
  a plan. Verified against `ec2:DescribeInstanceTypes` across all 1,150 types
  offered in eu-west-1: exact for 995, silent for the 104 bare-metal sizes,
  over-counted on 48 (which costs a warning rather than raising a false one), and
  under-counted on 3 legacy types that can warn a hair early. New section in
  README.md, "Sizing autoscaling against node capacity", documents the
  arithmetic.

  The supply-side constants are the requests these workloads declare on a cluster
  this module builds, not the figures the upstream charts document: 180m per node
  for the `aws-node`, `kube-proxy` and `ebs-csi-node` DaemonSets, and 720m once
  for CoreDNS, metrics-server, KEDA and `ebs-csi-controller`.
  `ebs-csi-node-windows` is excluded because it reports
  `desiredNumberScheduled = 0` on a Linux node group. The EKS kubelet reservation
  is modelled from the AMI's own curve, with t3.xlarge reporting 3,920m
  allocatable.

  Checked against the real scheduler rather than by inspection, by driving a
  webhook HPA past capacity on a 3-node cluster. The model predicted 10,500m
  available; the scheduler placed 10,200m and left 21 pods `Pending` with `0/3
  nodes are available: 3 Insufficient cpu` while the Cluster Autoscaler sat at
  `node_max`, which is the failure #51 reports. The 300m residue is bin-packing
  fragmentation, which no request-based model can represent, so read the warning
  as a bound rather than a prediction.

- Validation rejecting an autoscaler floor above its own ceiling, for all three
  pod families. Kubernetes rejects an HPA whose `minReplicas` exceeds its
  `maxReplicas` and KEDA does the same for a ScaledObject, so this previously
  failed partway through an apply. Lowering the two default ceilings above makes
  the combination reachable for a caller who changes nothing, which is why the
  check is at the variable boundary: the error names both inputs and their values
  before anything is sent to the cluster. A floor equal to its ceiling stays
  valid, since that is how you pin a fixed-size deployment.

- `n8n_webhook_hpa_scale_up_stabilization_window_seconds` input (default `0`,
  matching the Kubernetes API's own default) exposes
  `behavior.scaleUp.stabilizationWindowSeconds` on the module-managed
  `kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook`. Lets a caller absorb a
  short boot-time CPU spike (for example from
  `n8n_reinstall_missing_packages = true`) without an immediate scale-up. A new
  `webhook_resources_sized_for_reinstall_missing_packages` plan-time check warns
  when `n8n_reinstall_missing_packages = true` and the webhook processor's
  CPU/memory requests and limits are below the values known to survive it in
  production. See [issue #52](https://github.com/n8n-io/terraform-aws-n8n/issues/52)
  and `docs/troubleshooting.md`.
- `n8n_license_detach_floating_on_shutdown` input (default `false`) maps to
  `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN`, overriding n8n's own upstream
  default of `true`. In multi-main (the module default), the leader main
  detaching its floating license entitlement on shutdown zeroes the shared
  cert in the database, so a fresh main pod starting as a follower fails the
  init-time license gate and crash-loops, pushing an `atomic = true` Helm
  release into a stuck `pending-rollback` state. All mains share the same
  device fingerprint, so keeping this `false` safely reuses a single floating
  seat across restarts. See
  [issue #49](https://github.com/n8n-io/terraform-aws-n8n/issues/49) and
  `docs/troubleshooting.md`.

  Upgrade note: this changes runtime behavior for existing deployments.
  Single-main deployments that rely on n8n's upstream detach-on-shutdown
  behavior must now set `n8n_license_detach_floating_on_shutdown = true`
  explicitly. The env var name is also reserved: an existing `n8n_extra_env`
  entry named `N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN` is now rejected at
  plan time and must be moved to the new input.
- Vendored two agent skills from
  [hashicorp/agent-skills](https://github.com/hashicorp/agent-skills) into
  `.agents/skills/` via the skills CLI, pinned by `skills-lock.json`:
  `terraform-style-guide` and `terraform-test`. Coding agents working in this
  repo pick them up automatically; module consumers are unaffected.
- All five examples (`small`, `medium`, `large`, `cloudflare`, `godaddy`) now
  expose the module's `n8n_image_tag` input as a passthrough variable
  (default `null`, same tag-format validation as the module), so callers can
  pin the n8n image version without editing the example source.
- `db_allowed_security_group_ids` input allows sources to reach RDS by security
  group rather than by address. Preferred over `db_allowed_cidr_blocks` inside
  the VPC, since membership follows the instances and the rule survives subnet
  changes and IP reuse. Emits no rule at all when empty, so it is a no-op diff
  for existing deployments. Note that `aws_security_group.rds` is created
  regardless of `create_database`, so with an external database the rules are
  still written but front nothing; the variable descriptions now say so.
- Three plan-time `check` blocks for configurations that are accepted but
  probably not intended: `ingress_scheme` or `ingress_annotations` set while
  `create_ingress = false` (silently inert), `ingress_annotations` replacing
  `target-group-attributes` without `stickiness.enabled=true` (drops the
  stickiness that keeps editor WebSockets alive, surfacing as a flaky network
  rather than a config error), and `db_backup_retention_period = 0` (also
  disables point-in-time recovery, which the variable name does not suggest).
  All warn rather than fail, since each is legitimate in some deployment.
- Two further `check` blocks guarding the external-database inputs in the
  direction the module did not cover. `db_host` or `db_password` set while
  `create_database = true` is the consequential one: the module builds its own
  RDS instance and points n8n at that, so the apply succeeds and the workflows
  land in a database the caller is not watching. The second warns when RDS
  sizing or hardening inputs are tuned while `create_database = false`, where
  no RDS instance exists for them to reach. Both cover the direction the module
  did not: an input that is silently ignored rather than rejected.
- `refactoring.tf` collects every `moved` block in one place instead of leaving
  each beside the resource it renames. The blocks are unchanged and
  position-independent, so this is purely organisational: the upgrade surface
  is now reviewable in a single file.
- `create_ingress` input (default `true`, so existing deployments are
  unaffected) gates the module-managed ALB Ingress. Set it to `false` to bring
  your own Ingress resources, for example the two-ALB split where an
  internet-facing ALB serves `/webhook` and a separate internal, VPN-only ALB
  serves the admin UI. When `false` the module also skips the Route 53 alias
  A-record and the `data.aws_lb` lookup behind it, so a caller-owned DNS record
  is no longer reverted on every plan; the ACM certificate is still issued when
  `route53_zone_id` is set.
- `ingress_scheme` input (default `internet-facing`, validated against
  `internet-facing` / `internal`) replaces the hardcoded ALB scheme on the
  module-managed Ingress.
- `examples/split-ingress/`: a runnable reference for the two-ALB split at
  `small` sizing: `create_ingress = false`, an internet-facing ALB serving only
  the webhook path prefixes with an optional WAFv2 ACL, and an internal ALB
  serving the editor UI and REST API. Issues one ACM certificate covering both
  hostnames, writes both Route 53 alias records, and wires `n8n_webhook_url` so
  n8n hands out webhook URLs on the public host. The split is asymmetric: the
  public ALB carries the webhook prefixes and no catch-all, while the internal
  one carries the prefixes plus the catch-all, so in-VPC callers can deliver
  webhooks without egressing and never get the editor's SPA handler answering
  200 to a webhook. Added to every CI matrix with 13 plan-time tests, including
  assertions that the public ALB never gains a catch-all and that both ALBs
  route every prefix to the webhook processors.

  Validated against a live EKS deployment: both ALB target groups verified to
  contain exactly the intended pods with no overlap, all five prefixes
  confirmed reaching n8n on both ALBs, the admin host confirmed unreachable
  from the internet, and the editor confirmed absent from the public ALB.
- `ingress_annotations` input (`map(string)`, merged over the module defaults,
  last write wins) for AWS Load Balancer Controller features the module has no
  opinion on: WAF ACL, SSL policy, subnet pinning, security groups, inbound
  CIDRs, ALB group sharing, access logs. This is the escape hatch that keeps a
  one-annotation change from requiring a fork or a full bring-your-own Ingress.
  A `check` block warns at plan time when it also sets
  `alb.ingress.kubernetes.io/scheme`, since that silently overrides
  `ingress_scheme` and the failure mode is a publicly exposed admin UI.
- `n8n_service_name`, `n8n_webhook_service_name`, `n8n_webhook_path_prefixes`,
  and `n8n_service_port` outputs expose everything a bring-your-own Ingress
  needs to route correctly. Iterate `n8n_webhook_path_prefixes` rather than
  hardcoding paths, so caller-owned Ingresses stay in step as n8n adds
  endpoints.
- `db_backup_retention_period` input (default `7`, validated 0–35) replaces the
  hardcoded RDS `backup_retention_period`, so an out-of-band retention change
  is no longer reverted on the next plan.
- `db_allowed_cidr_blocks` input (default `[]`) appends CIDR blocks to the RDS
  security group's inbound rule alongside the always-allowed VPC CIDR. A
  standalone `aws_security_group_rule` attached at the root is not tracked by
  the module's inline `ingress` block and gets stripped on every plan; this
  input is the supported way to allow a corporate network, VPN pool, or peered
  VPC.
- `n8n_additional_domains` input (`list(string)`, default `[]`) for serving n8n
  on more than one hostname. Each entry is added to the module-issued ACM
  certificate as a subject alternative name, gets its own Route 53 validation
  record and alias A-record, and gets its own Ingress rule so the ALB actually
  routes it. Every host carries the full path set, webhook prefixes included, so
  an additional hostname is not editor-only. `n8n_domain` stays canonical: it is
  what n8n advertises as `WEBHOOK_URL` and `N8N_HOST`.

  Validated for malformed hostnames, duplicates, repetition of `n8n_domain`, and
  the ACM quota of 10 names per certificate. Names (including `n8n_domain`) are
  normalized to lowercase before use: ACM stores certificate names in lowercase,
  so a mixed-case input would never match its own entry in
  `domain_validation_options` and the apply would fail pointing at the
  validation record rather than the casing. Kubernetes also rejects uppercase
  Ingress hosts, and DNS is case-insensitive, so the normalization is not
  observable by callers. Two `check` blocks cover the cases
  validation cannot: setting additional domains alongside a caller-supplied
  `certificate_arn`, where the module cannot add names to a certificate it did
  not issue and TLS fails with a name mismatch, and setting them alongside
  `create_ingress = false`, where the names reach the certificate but the module
  writes no Ingress rules or alias records for them. Both plan cleanly and fail
  only at runtime, which is what made them worth a warning.

  A `precondition` on `aws_acm_certificate_validation` catches the worst version
  of this: a certificate name with no Route 53 validation record. That does not
  fail a plan, it makes the apply hang until the validation times out, tens of
  minutes later, reporting a resource that is not the cause. A precondition
  rather than a `check` because `domain_validation_options` is computed, so the
  comparison is unknown at plan; a precondition defers quietly and then fails
  fast at apply, before the wait begins.

  Surfaced in the `small` and `medium` examples, which use the Route 53 path.
  Not applicable to `cloudflare` or `godaddy`, which issue their own
  certificates through a non-AWS DNS provider.
- `certificate_arn` output exposing the ACM certificate n8n is served with: the
  module-issued and validated one when `route53_zone_id` is set, or the
  caller-supplied ARN echoed back. This is what makes
  `n8n_additional_domains` useful to a caller that owns its own Ingress
  resources. It is sourced from `aws_acm_certificate_validation`, so consuming
  it orders the caller's resources after validation completes.

  `examples/split-ingress` now uses it. That example needs one certificate
  covering two hostnames and previously hand-rolled the whole thing: the
  certificate, a validation-record loop keyed off a statically known domain set,
  and the validation resource, all duplicating what the module now does. It sets
  `route53_zone_id` and `n8n_additional_domains` instead and attaches
  `module.n8n.certificate_arn` to both Ingresses, cutting `dns.tf` from 103
  lines to 67. The alias records stay in the example, because there are two
  ALBs and each hostname points at a different one.

  Consequently `n8n_additional_domains` with `create_ingress = false` is a
  supported pattern rather than a suspicious one, and emits no warning: the
  certificate still covers every name and every name still gets a validation
  record, while routing and DNS remain the caller's, which is what
  `create_ingress = false` means.

  `subject_alternative_names` is passed as `null` rather than `[]` when the list
  is empty, so deployments predating this input see no diff on what is a
  ForceNew attribute. The additional alias records live in a separate resource
  from `aws_route53_record.n8n_alias` deliberately: converting that resource
  from `count` to `for_each` would move it from `[0]` to `["<domain>"]`, and a
  `moved` block cannot express that because its addresses must be static, so
  every existing deployment would destroy and recreate its alias record.

### Changed

- **Default HPA maxima now fit the default node group.**
  `n8n_main_hpa_max_replicas` drops from `20` to `6` and
  `n8n_webhook_hpa_max_replicas` from `50` to `8`. The old defaults were
  unschedulable by construction: 20 main pods plus their task runner sidecars
  request 24,000m CPU on their own, more than the entire default node group
  (`node_max = 6` × t3.xlarge = 24 vCPU) can ever provide, before the worker and
  webhook ceilings are counted at all.

  The failure mode is not a plan error but a slow one. During a rollout with
  elevated CPU the HPAs scale toward their maxima, the Cluster Autoscaler hits
  `node_max`, and the pods that do not fit sit `Pending` with `Insufficient cpu`
  (15 of them in the deployment that surfaced this). The surging ReplicaSet then
  competes for the same exhausted CPU, which stretches out the rollout until the
  HPAs are capped by hand.

  At the new defaults the three pod families request 16,600m against roughly
  21,720m schedulable, leaving headroom for a rolling-update surge.

  Upgrade note: an explicit ceiling is untouched. Both HPAs update in place, with
  no resource replacement, but a cluster currently running more than 6 main or 8
  webhook pods will be scaled back to the new ceiling on the next apply. If you
  rely on the old ceilings, set them explicitly and size `node_max` /
  `node_instance_type` to match.

  One case fails the plan outright: an explicit floor above the new ceiling, which
  a caller could reach without changing anything. `n8n_main_hpa_min_replicas = 8`
  or `n8n_webhook_hpa_min_replicas = 10` was valid against the old ceilings of 20
  and 50, and against the new ones is not:

  ```
  Error: Invalid value for variable
    │ var.n8n_main_hpa_max_replicas is 6
    │ var.n8n_main_hpa_min_replicas is 8
  n8n_main_hpa_min_replicas must not exceed n8n_main_hpa_max_replicas
  ```

  Raise the matching ceiling explicitly, and `node_max` /
  `node_instance_type` with it. The new validation below is what makes this a
  plan-time error naming both inputs, rather than a Kubernetes rejection partway
  through `helm upgrade`.

  `examples/medium` and `examples/large` now pin the main pod range explicitly
  (3/24 and 6/60) rather than inheriting it, so it is tied to each tier's node
  group instead of to the starter default, and both tiers' sizing tables gained a
  main-pod row. The raised floors match the warm-floor approach both tiers already
  take for webhook and worker pods: n8n pods take tens of seconds to boot, so a
  floor of 2 puts an editor or API burst behind pod startup. Main pods carry
  neither production webhooks (the module sets
  `disableProductionWebhooksOnMainProcess`) nor manual executions (the chart sets
  `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS`), so a main ceiling tracks concurrent
  editor and REST API users, not a tier's executions/day. Resolves
  [#51](https://github.com/n8n-io/terraform-aws-n8n/issues/51).

- `node_instance_type`, `node_max`, `n8n_task_runners_enabled`, and the six
  autoscaler floor and ceiling inputs now declare `nullable = false`. A caller
  passing an explicit `null` for one of these previously propagated it into
  the module instead of falling back to the default, and once the capacity
  check existed that null aborted the plan from inside the check's
  interpolations (see the AGENTS.md note on null and `nullable = false`).
  With `nullable = false`, Terraform substitutes the declared default at the
  variable boundary. Only callers writing a literal `null` for one of these
  nine inputs observe any change: they now get the default silently rather
  than an error partway through the plan.

- `aws_route53_record.cert_validation` keys its `for_each` off
  `local.acm_domain_names` instead of the certificate's computed
  `domain_validation_options`, and selects each record's values by matching
  `domain_name` rather than assuming a single validation option. For a
  deployment with no additional domains the key is unchanged and there is no
  state churn: verified on a live 0.2.0 deployment, where the existing record
  refreshed in place with no move and no replacement.

  The original motivation was testability rather than correctness, since the
  real AWS provider populates `domain_validation_options` with known keys at
  plan time while the mock provider leaves the whole attribute unknown, which
  made every test that sets `route53_zone_id` unplannable. That was why the
  Route 53 path had no coverage at all; both directions of the `create_ingress`
  alias gate are now asserted. Sourcing the keys from `local.acm_domain_names`
  is also what makes `n8n_additional_domains` work, since the record set and the
  certificate's name list now come from the same place and cannot drift.

## [0.2.0] - 2026-07-15

Minor release per the [stability contract](./README.md#stability--versioning):
the AWS and Helm provider floor bumps below are breaking for callers pinned
to the previous majors. Pin this module to `~> 0.1.0` to stay on the old
providers, or retype your constraint to `~> 0.2.0` and read the upgrade notes
under **Changed**.

### Added

- `n8n_reinstall_missing_packages` input variable: sets
  `N8N_REINSTALL_MISSING_PACKAGES` on all n8n pods so workers reinstall
  UI-installed community packages after being rescheduled onto a fresh
  filesystem. Defaults to false (env var omitted).
- `n8n_community_packages_prevent_loading` input variable: sets
  `N8N_COMMUNITY_PACKAGES_PREVENT_LOADING` on all n8n pods to stop installed
  community packages from loading at runtime. Defaults to false (env var
  omitted).
- OpenTelemetry tracing toggles: `n8n_otel_enabled` (master switch, default
  off) plus null-default tuning inputs `n8n_otel_exporter_otlp_endpoint`,
  `n8n_otel_exporter_otlp_headers` (sensitive), `n8n_otel_exporter_service_name`,
  `n8n_otel_traces_sample_rate` (validated 0–1), `n8n_otel_traces_include_node_spans`,
  `n8n_otel_traces_inject_outbound`, and `n8n_otel_traces_production_only`. Wired
  to the `N8N_OTEL_*` env vars on the Helm release's `config.extraEnv` so they
  apply to every n8n container (main, worker, webhook processor). A `check` block
  warns at plan time when a tuning var is set while `n8n_otel_enabled = false`.
  When disabled (the default) no `N8N_OTEL_*` env vars are emitted.
- `n8n_templates_enabled` input variable: defaults to true. When false, sets
  `N8N_TEMPLATES_ENABLED=false` on all n8n pods to disable workflow templates
  and template suggestions for deployments that enforce consistent workflows.
- `n8n_personalization_enabled` input variable: defaults to true. When false,
  sets `N8N_PERSONALIZATION_ENABLED=false` on all n8n pods to skip n8n's
  personalization survey questions and tailored content/recommendations,
  e.g. on shared or ephemeral instances.
- Log streaming (Enterprise) managed via env vars: `n8n_log_streaming_managed_by_env`
  (master switch, default off) and `n8n_log_streaming_destinations` (sensitive list of
  webhook/syslog/sentry destination objects, JSON-encoded into
  `N8N_LOG_STREAMING_DESTINATIONS`). Uses n8n's settings-env-vars activation pattern
  (requires n8n >= 2.19.0): destinations are reapplied on every startup and the Log
  Streaming UI becomes read-only. A `check` block warns at plan time when destinations
  are set while the master switch is off. When disabled (the default) no
  `N8N_LOG_STREAMING_*` env vars are emitted.
- `n8n_image_tag` input variable: optional string (default `null`) that pins the n8n
  application image to a specific version (e.g. `"1.2.3"`). When `null`, the Helm
  chart's own default applies — currently the floating `stable` tag — so existing
  deployments see no change. Validated at plan time against Docker tag rules
  (`^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$`) to catch malformed or whitespace-padded
  values before deployment. Pinning a concrete version is recommended for production
  to avoid crossing major-version boundaries (e.g. n8n 2.0 breaking changes) on an
  unplanned pod reschedule.
- `n8n_extra_env` input variable: accepts a list of `{name, value}` objects appended
  to the Helm chart's `config.extraEnv` after all module-managed env vars, letting
  callers inject arbitrary n8n environment variables without forking the module.
  Validated at plan time to reject empty or whitespace-padded names, duplicate
  names, and any connection/identity/storage/license/topology variable the
  module or chart manages: names starting with `DB_`, `QUEUE_`, `N8N_RUNNERS_`,
  `N8N_EXTERNAL_STORAGE_S3_`, `N8N_MULTI_MAIN_`, or `AWS_`, plus exact names like
  `N8N_ENCRYPTION_KEY`, `N8N_LICENSE_ACTIVATION_KEY`, `WEBHOOK_URL`, and
  `EXECUTIONS_MODE`. `config.extraEnv` is appended last, so without this guard a
  caller could silently override those (Kubernetes last-wins) and break the
  deployment. Not intended for secrets: values are stored in plaintext in
  Terraform state; pass a `*_FILE` companion pointing at a mounted secret instead.
- EBS CSI driver (EKS managed addon) and a default encrypted `gp3` StorageClass
  (`storage.tf`), so PersistentVolumeClaims without an explicit `storageClassName`
  bind out of the box instead of staying `Pending` forever
  ([#22](https://github.com/n8n-io/terraform-aws-n8n/issues/22)). The CSI
  controller authenticates via EKS Pod Identity (no IRSA/OIDC), scoped to the
  AWS-managed `AmazonEBSCSIDriverPolicy`; volumes are encrypted with the default
  `aws/ebs` key. Additive for existing deployments: the next apply installs the
  addon and the StorageClass without cycling any n8n pods. The EKS-created legacy
  `gp2` class is left untouched (not Terraform-managed, carries no default
  annotation on current EKS). Decision record: solutions-catalog ADR-0041.

### Changed

- **AWS provider requirement bumped to `~> 6.0`** (was `~> 5.0`). No module
  resource required a configuration change: the module surface uses none of the
  attributes removed in AWS provider 6.0, and `terraform validate` passes
  against 6.x. Upgrade note: AWS provider 6.0 adds a per-resource `region`
  attribute, so existing v0.1.x deployments should run
  `terraform plan -refresh-only` followed by `terraform apply -refresh-only` to
  settle state before applying further changes. Callers who must remain on AWS
  provider 5.x should pin this module to `~> 0.1.0`.
- **Helm provider requirement bumped to `~> 3.0`** (was `~> 2.12`). Helm
  provider 3.0 is a Plugin Framework rewrite. The `set` blocks on the bundled
  controller releases (AWS Load Balancer Controller, Cluster Autoscaler,
  metrics-server) were converted to the new `set = [...]` list syntax, and the
  example `provider "helm"` blocks now use the `kubernetes = { ... }` object
  form. Upgrade note: drift detection is stricter in 3.x, so the first
  `terraform plan` after upgrading may show in-place diffs on existing
  `helm_release` resources. Callers who must remain on Helm provider 2.x should
  pin this module to `~> 0.1.0`.
- **Default `n8n_chart_version` bumped to `1.10.0`** (was `1.4.0`). Applying
  this default change cycles the n8n pods. Pin `n8n_chart_version` to stay on a
  specific chart release. Validated by a real apply of examples/small plus the
  post-deploy smoke test.

### Compatibility

- **AWS provider:** `~> 6.0` (see upgrade note under **Changed**).
- **Helm provider:** `~> 3.0` (see upgrade note under **Changed**).
- **Kubernetes provider:** `~> 2.0`.
- **Terraform CLI:** `>= 1.9`.
- **n8n Helm chart:** validated against `1.10.0` (the current default) via a
  real apply of `examples/small` plus the post-deploy smoke test. Newer chart
  versions can be selected via `n8n_chart_version` but are not part of the
  v0.2.0 test matrix.
- **Kubernetes:** validated on EKS 1.35.
- **PostgreSQL:** validated on RDS `16.9`.

### Known limitations

- Checkov still runs in `soft_fail` mode; findings are surfaced but do not
  block CI. The curated suppressions and flip to hard-fail announced in
  v0.1.0 are deferred to a later release.
- See [README.md → Out of scope](./README.md#out-of-scope) for what this
  release explicitly does not cover.

## [0.1.0] - 2026-06-04

Initial release on the Terraform Registry as `n8n-io/n8n/aws`.

### Added

- Production-grade multi-main n8n Enterprise deployment on AWS: EKS
  cluster with managed node group; multiple n8n main pods, dedicated
  worker pods (queue mode), and webhook-processor pods; RDS for
  PostgreSQL; ElastiCache for Redis; S3 wired via EKS Pod Identity for
  shared binary storage.
- AWS Load Balancer Controller, Cluster Autoscaler, KEDA (queue-driven
  worker scaling), and metrics-server installed via Helm.
- Route 53 path: end-to-end automation — pass `route53_zone_id` and the
  module issues the ACM certificate and creates the DNS alias record
  itself.
- Cloudflare and GoDaddy paths via the respective examples, which issue
  the certificate themselves and pass the validated `certificate_arn`
  to the module.
- Five runnable examples: `small` (defaults), `medium`, `large` (adds
  Aurora, PgBouncer, dual-NAT-GW HA, VPC CNI tuning), `cloudflare`,
  `godaddy`.
- Prometheus metrics endpoint toggle via `n8n_metrics_enabled` (off by
  default; scrape configuration left to the caller's monitoring stack).
- Plan-time `terraform test` suites at the module root and on each
  example, with mocked providers so the suite runs without AWS
  credentials.

### Compatibility

- **AWS provider:** `~> 5.0` (does not yet support `~> 6.0`; tracked for
  v0.2.0).
- **Helm provider:** `~> 2.12` (does not yet support `~> 3.0`; tracked
  for v0.2.0).
- **Kubernetes provider:** `~> 2.0`.
- **Terraform CLI:** `>= 1.9`.
- **n8n Helm chart:** validated against `1.4.0` (the current default).
  Newer chart versions can be selected via `n8n_chart_version` but are
  not part of the v0.1.0 test matrix; bump tracked for v0.2.0.
- **Kubernetes:** validated on EKS 1.35.
- **PostgreSQL:** validated on RDS `16.9`.

### Known limitations

- See [README.md → Out of scope](./README.md#out-of-scope) for what this
  release explicitly does not cover (VPC creation, multi-region,
  GovCloud, air-gapped, backup/DR automation beyond RDS snapshots,
  bundled observability).
- v0.1.0's AWS infrastructure creation path was validated against
  `examples/small` (a full `terraform apply` provisioned EKS, RDS with
  CMK encryption, ElastiCache, S3, ACM, Route 53, IAM, KMS, the LBC /
  Cluster Autoscaler / metrics-server / KEDA controllers, and the n8n
  Helm release reached the licensing layer; AWS resources destroyed
  cleanly with no orphans). The end-to-end smoke test in
  `tests/scripts/smoke-test.sh` was not run against a fully Ready n8n
  install for this release. Other examples pass plan-time mocked tests
  but were not real-applied. A full end-to-end validation cycle
  including the smoke test is tracked for v0.2.0.
- Checkov runs in `soft_fail` mode; findings are surfaced but do not
  block CI. Curated suppressions and a flip to hard-fail are tracked
  for v0.2.0.

[Unreleased]: https://github.com/n8n-io/terraform-aws-n8n/compare/0.2.0...HEAD
[0.2.0]: https://github.com/n8n-io/terraform-aws-n8n/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/n8n-io/terraform-aws-n8n/releases/tag/0.1.0
