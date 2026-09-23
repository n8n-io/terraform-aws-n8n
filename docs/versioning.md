# Version currency policy

This module pins a lot of versions: the n8n chart and image, four controller
charts, five Terraform providers, the Terraform CLI floor, `kubernetes_version`,
two database engines, and the CI toolchain that gates every PR. Each pin was
deliberate at the time it was set, and each one can go stale the moment
upstream ships a new release. This doc is the inventory of every pin, where it
lives, and the bump policy for keeping it current on a cadence instead of
waiting for a user to report a version nobody re-checked.

## Inventory

| Pin | Lives in | Tier |
| --- | --- | --- |
| `aws` provider constraint | `versions.tf`/`providers.tf` (root, `modules/controllers`, every `examples/*`; `examples/cloudflare` and `examples/godaddy` declare it in `providers.tf`, the rest in `versions.tf`) | Patch-safe |
| `kubernetes` provider constraint | same 12 files | Verification-required |
| `helm` provider constraint | same 12 files | Verification-required |
| `random` provider constraint | `versions.tf` (root, `examples/large`) | Patch-safe |
| `time` provider constraint | `versions.tf` (root only) | Patch-safe |
| `required_version` (Terraform CLI floor) | same 12 `versions.tf`/`providers.tf` files | Verification-required |
| `n8n_chart_version` default | `variables.tf` | Minor-required |
| `lbc_chart_version`, `cluster_autoscaler_chart_version`, `metrics_server_chart_version`, `keda_chart_version` defaults | `variables.tf` | Minor-required |
| `kubernetes_version` default | `variables.tf`, and independently in `examples/customer-managed-cluster` and `examples/customer-managed-everything` | Verification-required (stays `1.35`; see below for why `1.36` isn't a currency gap) |
| `db_engine_version` default | `variables.tf` | Minor-required |
| `customer_managed_db_engine_version` default | `examples/customer-managed-everything/variables.tf` | Minor-required (follows the root default) |
| `aurora_engine_version` local | `examples/large/aurora.tf` | Verification-required (Aurora's supported-version list is not the same list as RDS instance Postgres; confirmed current at `18.4`, see below) |
| Redis engine version (`redis.tf`, hardcoded `"7.1"`) | `redis.tf` | Verification-required (`7.1` is the ceiling for Redis OSS on ElastiCache; anything newer is Valkey-only, a different engine family, out of scope for a version-currency pass) |
| EKS add-on versions (Pod Identity Agent, EBS CSI) | `eks.tf`, `modules/controllers/storage.tf` | Not pinned at all: `aws_eks_addon` omits `addon_version`, so AWS resolves the current default on every apply. This is a deliberate design choice, not an oversight, and there is nothing to bump |
| `TF_VERSION`, `TFLINT_VERSION`, `CHECKOV_VERSION` | `.github/workflows/terraform-tests.yml` | Verification-required (`CHECKOV_VERSION` doubles as the pin `tests/scripts/check-checkov.sh` enforces locally) |
| `MARKDOWNLINT_VERSION` (markdownlint job) | `.github/workflows/terraform-tests.yml` | Patch-safe, but keep in step with the `brew install markdownlint-cli` default contributors use locally, for the same reason as `TERRAFORM_DOCS_VERSION` |
| `TERRAFORM_DOCS_VERSION` (docs job) | `.github/workflows/terraform-tests.yml` | Patch-safe, but keep in step with the `brew install terraform-docs` default contributors use locally (see `AGENTS.md`) |
| `azure/setup-helm` version (chart job) | `.github/workflows/terraform-tests.yml` | Patch-safe |
| `docs/helm-chart-coverage.md`'s declared chart version | `docs/helm-chart-coverage.md` | Must equal `n8n_chart_version`'s default; CI-gated by `tests/scripts/check-helm-chart-coverage.sh` |

## Bump tiers

**Patch-safe.** A newer patch/minor release with no known breaking change and
no plan-time diff for existing deployments. Bump in the same PR as any other
change, or standalone with a one-line CHANGELOG entry. No re-verification
beyond the normal `terraform test`/`tflint`/`checkov` loop.

**Minor-required.** Moves a default that changes what `terraform apply`
deploys. A caller that never set the corresponding variable in their own
`module` block is not shielded by that omission: Terraform resolves the
variable to the module's new default on that caller's very next apply, with
no config change of their own. For a chart version that means an in-place
`helm upgrade` that rolls the release's pods. For `db_engine_version` it
does not move the running instance: `aws_db_instance.n8n` ignores changes to
`engine_version` (`auto_minor_version_upgrade` owns the live minor), so only
a fresh database and the opt-in parameter group's `family` read it. Only a
caller that explicitly pins the variable in their own configuration is
unaffected either way. This
module is still pre-1.0 either way, and the [stability
contract](../README.md#stability--versioning) treats a changed default as a
minor-version-boundary change regardless. Needs: a CHANGELOG entry under
**Changed** naming the old and new value and stating plainly that unpinned
callers move too, a `docs/helm-chart-coverage.md` re-verification when it's
the n8n chart (see that doc's own instructions; `task chart-diff
CANDIDATE=<version>` prints the `values.yaml` diff that re-verification
starts from), and a passing
`tests/scripts/check-main-chart.sh` when it's a chart this module templates
against. For a controller chart, also compare the new `appVersion`'s
supported Kubernetes range against every `kubernetes_version` this module
accepts, not only the default: metrics-server chart `3.14.0` moved the
floor from `1.31` to `1.34` in a chart minor, which the CHANGELOG has to
say and the variable description has to carry.

**Verification-required.** A provider major, the Terraform CLI floor, or
`kubernetes_version`. These carry real breaking-change risk (see the Kubernetes
provider 3.0 entry in `README.md`'s Compatibility section for a worked
example) and are release-sized work in their own right, matching this
project's past provider bumps (see `CHANGELOG.md`'s `v0.2.0` entry). Needs, at
minimum: the upstream release's own upgrade guide read in full, a plan-time
diff against every affected resource, an updated `README.md` Compatibility
entry with an upgrade note, and a CHANGELOG entry. A resource-type rename this
provider bump exposes (e.g. an unversioned-to-`_v1` Kubernetes resource) is
**not** bumped reflexively: check first whether the provider supports a
`moved` block across that specific rename (it does not, as of Kubernetes
provider 3.2.1, for the unversioned-to-`_v1` family: see
`terraform-provider-kubernetes` issue #2812). Without one, renaming the
resource type in source forces every existing deployment to destroy and
recreate whatever the module already manages under that address (a namespace,
in this module's case, taking everything inside it down too), which is worse
than living with the provider's deprecation warning until it ships that
support.

## Chart 1.12.0 upgrade requirements

The default moves from `1.11.0` to `1.12.0`, so this belongs in a minor
module release. `n8n_image_tag = null` still delegates to the selected chart,
whose fallback changes from floating `stable` to `appVersion: 2.39.6`.
An existing deployment may already run a newer application. Inspect and pin
its running version before changing the chart; see
[Upgrading n8n](./upgrading-n8n.md#moving-from-chart-1110-to-1120).

Rendering tests cover fallback and explicit image tags, custom repositories,
and worker-only task runners in queue mode. The capacity model removes main
runner requests for upstream `1.12.0` and `1.13.0`, ignoring build metadata
but not prerelease suffixes. Verify topology before extending that
exception to any other release or repository. Worker pools still require
their separate preview or verified custom chart.

## Chart 1.13.0 upgrade requirements

The default moves from `1.12.0` to `1.13.0`. `n8n_image_tag = null` still
delegates to the selected chart, whose fallback moves from `appVersion:
2.39.6` to `appVersion: 2.40.5`; inspect and pin the running application
version first if it is not already pinned. See
[Upgrading n8n](./upgrading-n8n.md#moving-from-chart-1120-to-1130).

Upstream leaves worker (and, where applicable, webhook-processor) replica
counts to the autoscaler once one is actually configured
(n8n-io/n8n-hosting#201) rather than templating `replicas` unconditionally.
This module's worker deployment always configures `keda.worker.triggers`
non-empty, so it is affected: the first `helm upgrade` to `1.13.0` drops
`spec.replicas` from the worker Deployment, Kubernetes defaults it to 1 on
that one apply. The reset target is a hard-coded 1, not this module's
configured floor, so this is a real capacity dip whenever the pre-upgrade
replica count exceeds 1, including a deployment sitting exactly at a
configured floor above 1 (the default floor is 1, so a default deployment
sees no dip); recovery is HPA-driven (the native HPA KEDA manages behind
the `ScaledObject`), not bounded by `keda.worker.pollingInterval`, which
only governs how often KEDA refreshes the external metric rather than the
HPA's own reconciliation cadence. No Terraform input
changes. Webhook processors are unaffected: their autoscaling is a
Terraform-managed HPA in `scaling.tf`, outside the chart's KEDA/HPA model
entirely (`keda.webhookProcessor.enabled` is never set by this module).
`tests/scripts/check-main-chart.sh` renders the worker Deployment with real
(non-empty) KEDA triggers and asserts `replicas` is omitted, matching this
module's actual shape rather than the chart's bare default.

The new `keda.webhookProcessor.{pause,pausedReplicaCount,pollingInterval,
cooldownPeriod,minReplicaCount,maxReplicaCount,triggers}` values (pausing
webhook processors, including scale-to-zero) are not exposed by this
module. Worker pools still require their separate preview or verified
custom chart; this release carries no worker-pools change either way.

## What this policy deliberately does not force

- **Redis → Valkey.** AWS steers new ElastiCache deployments toward Valkey
  over Redis OSS (see `redis.tf`'s comment on `engine_version`); as of Valkey
  9.0 (May 2026) AWS's own guidance is "use Valkey unless you have a specific
  reason not to," citing lower cost and higher throughput. That is an
  engine-family change, not a version bump: `redis.tf` hardcodes
  `engine = "redis"`, and Valkey is a distinct `engine` value with its own
  version range, not a newer `"7.x"`. It needs its own migration path for
  anyone already running this module's Redis engine (AWS's online migration
  or a blue/green cutover, not a plan-time `engine_version` bump), a docs
  rewrite, and a decision on whether the default changes for new deployments
  or only becomes an option. Tracked as a separate, demand-driven issue
  rather than folded into a version-currency PR.
- **Aurora engine version in `examples/large`.** `aurora_engine_version` is
  independent of the root module's `db_engine_version` (Aurora and RDS
  instance Postgres are different engines with different supported-version
  lists and different release cadences: Aurora typically lags upstream
  PostgreSQL, and this repo's own history shows its exact minor has been
  hand-verified against a live `aws rds describe-db-engine-versions --engine
  aurora-postgresql` call, not inferred from a public announcement).
  Confirmed still current as of this PR: AWS's own August 2026 announcement
  ("Amazon Aurora now supports PostgreSQL 18.4, 17.10, 16.14, 15.18, and
  14.23") lists `18.4` as the newest Aurora PostgreSQL 18 minor, so the
  pinned value is not behind. Re-verify with the live `describe-*` call
  before bumping past it rather than inferring the next minor from a blog
  post; the account/region-scoped API is still the only source that proves
  a specific minor is actually creatable, and public announcements lag or
  stagger regional availability.
- **`kubernetes_version` stays `1.35`, not `1.36`.** EKS made `1.36` generally
  available June 2, 2026 (see AWS's own "what's new" announcement and
  `docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html`), so
  this is not a currency gap in the sense the other rows in this doc mean
  it. It is a gate-compatibility gap instead: the pinned `checkov` 3.3.19
  still hardcodes `CKV_AWS_339`'s allow-list at `["1.29", …, "1.35"]` with
  no `1.36` entry (verified in that release's
  [check source](https://github.com/bridgecrewio/checkov/blob/3.3.19/checkov/terraform/checks/resource/aws/EKSPlatformVersion.py)), so bumping today would
  add a curated-finding suppression for a version this repo's own security
  gate cannot yet vouch for, while `1.35` remains inside AWS's 14-month
  standard-support window. Revisit once a `checkov` release adds `1.36` to
  that list.

## Provider locks and toolchain updates

The provider rows in the drift report compare constraints with upstream
versions, not with the versions selected in `.terraform.lock.hcl`. Check
all 13 tracked lock files: the root, eleven examples, and
`modules/controllers`. A compatible provider update normally changes only
its lock entries, not the module's constraints. Preserve checksums for
`linux_amd64`, `linux_arm64`, and `darwin_arm64`, and leave unrelated
providers unchanged. Consumers of the published module use their own root
lock file, not this repository's locks.

Checkov `3.3.19` adds `CKV_AWS_394`, which requires a `zone-name` or
`zone-id` filter on `aws_availability_zones`. All eleven examples retain
dynamic discovery so they remain runnable across regions without changing
existing subnet placement in a toolchain update. Each data source carries
a scoped exception, not a repository-wide suppression. This accepts a
real risk: `slice(..., 0, 2)` limits the number of zones but does not pin
their identities. Changes to the returned list can replace subnets. For a
long-lived deployment, pin the existing zone identities in the VPC
configuration and review the plan before applying. The published n8n
module itself consumes a pre-existing VPC and performs no zone discovery.

## What the automated drift report cannot see

`tests/scripts/check-version-drift.sh` (run weekly by
`.github/workflows/version-drift.yml`, and on demand via `task
version-drift`) checks every pin reachable from a public API without AWS
credentials: the five Terraform providers (registry.terraform.io), the CI
toolchain (GitHub releases, including `markdownlint-cli`), the four controller charts this module installs
(their own chart repositories' `index.yaml`), the n8n chart (`n8n-io/n8n-hosting`'s
latest Git tag, not its `oci://ghcr.io` registry, which has no equivalent
public index; the chart's own `Chart.yaml` is release-please-automated to
match that tag exactly, confirmed at `1.11.0` as of this PR, so the tag is a
reliable proxy for the published chart version rather than a literal registry
query), and `kubernetes_version` against EKS's supported-version list via
`endoflife.date`'s public JSON API (an aggregator over AWS's own
release-calendar docs; AWS itself does not publish this behind an API). It
always exits 0: it is a report, not a gate, and everything it would flag is
release-sized work per the tiers above, not an auto-bump.

Even the EKS check only proves a version exists and its support window,
not that it is creatable in one specific account and region right now;
only `aws eks describe-cluster-versions`, run with credentials this repo's
CI does not hold (see `AGENTS.md`: never apply from CI, no AWS secrets
configured for any job here), answers that.

It cannot see, and does not attempt to check, two things with no
comparable public aggregator at the minor-version granularity that
matters here:

- **RDS PostgreSQL and ElastiCache Redis supported engine versions.**
  AWS's release-notes pages and "what's new" posts are a reliable public
  signal (this doc's `db_engine_version` and Redis entries above cite
  them), but the account/region-scoped confirmation is
  `aws rds describe-db-engine-versions` /
  `aws elasticache describe-cache-engine-versions`, which need credentials
  this repo does not carry in CI.
- **Aurora's own PostgreSQL version list**, for the same reason, and
  doubly so given it does not track RDS instance Postgres's list (see
  above; this doc's `aurora_engine_version` entry above was confirmed via
  AWS's public announcement, not the live API).

These two still need a human with AWS credentials to run the `describe-*`
call against your own account and region before an account-specific bump
(a live cluster/instance create, not "does this version exist anywhere"),
on the same cadence as the automated report. Between reports, the public
announcement pages are good enough to catch the case this doc's own
history shows actually bites: a config pointing at a minor that has not
released at all yet. Record the result the way `examples/large/aurora.tf`'s
comments already do: the exact command (or announcement) checked, not a
paraphrase.

## Cadence

Review the weekly drift report every time it lands. A patch-safe pin behind
latest: bump it in the next PR that touches that file anyway, no separate
ticket needed. A minor- or verification-required pin behind latest: file an
issue using this doc's tiers to scope the work, the same way issue #124 scoped
this one.
