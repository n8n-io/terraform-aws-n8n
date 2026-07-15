# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md → Stability & versioning](./README.md#stability--versioning).

## [0.2.0] - 2026-07-15

Minor release per the [stability contract](./README.md#stability--versioning):
the AWS and Helm provider floor bumps below are breaking for callers pinned
to the previous majors. Pin this module to `~> 0.1` to stay on the old
providers, or retype your constraint to `~> 0.2` and read the upgrade notes
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
  provider 5.x should pin this module to `~> 0.1`.
- **Helm provider requirement bumped to `~> 3.0`** (was `~> 2.12`). Helm
  provider 3.0 is a Plugin Framework rewrite. The `set` blocks on the bundled
  controller releases (AWS Load Balancer Controller, Cluster Autoscaler,
  metrics-server) were converted to the new `set = [...]` list syntax, and the
  example `provider "helm"` blocks now use the `kubernetes = { ... }` object
  form. Upgrade note: drift detection is stricter in 3.x, so the first
  `terraform plan` after upgrading may show in-place diffs on existing
  `helm_release` resources. Callers who must remain on Helm provider 2.x should
  pin this module to `~> 0.1`.
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
