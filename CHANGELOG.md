# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md → Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Added

- `n8n_reinstall_missing_packages` input variable: sets
  `N8N_REINSTALL_MISSING_PACKAGES` on all n8n pods so workers reinstall
  UI-installed community packages after being rescheduled onto a fresh
  filesystem. Defaults to false (env var omitted).
- `n8n_community_packages_prevent_loading` input variable: sets
  `N8N_COMMUNITY_PACKAGES_PREVENT_LOADING` on all n8n pods to stop installed
  community packages from loading at runtime. Defaults to false (env var
  omitted).

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

[Unreleased]: https://github.com/n8n-io/terraform-aws-n8n/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/n8n-io/terraform-aws-n8n/releases/tag/v0.1.0
