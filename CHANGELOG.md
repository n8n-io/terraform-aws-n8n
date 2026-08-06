# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to the stability contract in
[README.md → Stability & versioning](./README.md#stability--versioning).

## [Unreleased]

### Added

- **Support for n8n's own External Secrets feature**, via four new variables.
  This is the roadmap's "Bring your own Secrets Manager" item, at the scope it
  was narrowed to on 2026-08-05, and it concerns *workflow credential* values
  resolved from a vault at runtime. The module's own secrets (DB password,
  Redis AUTH token, encryption key, task runner token, licence key) are
  unaffected and stay Kubernetes Secrets.

  `n8n_external_secrets_enabled` (default `true`) is an opt-*out*: setting it
  to `false` appends `external-secrets` to `N8N_DISABLED_MODULES`, removing the
  feature and its Settings UI even under a licence that includes it. Left at
  the default, no env var is emitted at all and n8n's own behavior applies, so
  Community deployments, where the feature is inert without the
  `feat:externalSecrets` entitlement, need not set it.
  `n8n_external_secrets_update_interval` (default `null`) maps to
  `N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL`.

  `n8n_external_secrets_aws_enabled` (default `false`) is a separate, opt-in
  IAM layer: it grants the n8n pod's existing Pod Identity role
  (`aws_iam_role.s3`) read access to AWS Secrets Manager, so an admin
  connecting n8n's AWS provider in the UI can choose `authMethod = autoDetect`
  instead of pasting static IAM user keys. It does nothing for n8n's five other
  vault providers.

  `n8n_external_secrets_aws_secret_names` is **required and non-empty** when
  that grant is on, and rejects wildcards. This is deliberate rather than
  fussy: n8n's AWS provider calls `secretsmanager:ListSecrets` with no name,
  path, or tag filter and then reads every name it finds, so IAM is the only
  boundary on what a vault connection can read. An empty list or a `*` would be
  a silent full-account grant. A `check` block additionally warns when a named
  secret carries this module's own `ManagedBy = terraform` tag.

  Connecting the vault provider itself remains a manual step in the n8n UI in
  every case; Terraform cannot create that connection.

- **New `redis_key_prefix` variable** (default `null`) namespaces every Redis
  key a deployment uses, so two n8n deployments can share one external Redis
  without interfering with each other. Left at `null`, nothing changes: n8n
  keeps its own defaults on both prefixes, exactly today's behavior.

  n8n has *two* independent Redis key prefixes, and both have to move together
  or the split is incomplete. `N8N_REDIS_KEY_PREFIX` (n8n's default `"n8n"`)
  scopes the scaling-mode pub/sub command channel, `<prefix>:n8n.commands`;
  `QUEUE_BULL_PREFIX` (n8n's default `"bull"`) scopes Bull's own job-queue
  keys. This one input sets both. The n8n Helm chart exposes only the second,
  as `redis.prefix`, so the first is set as a literal `extraEnv` entry.

  The failure this fixes was confirmed live, not inferred: with two
  deployments pointed at the same `redis_host` (`create_elasticache = false`),
  activating a workflow on one produced `webhook not registered` on the other,
  because both were publishing to and consuming from the same unscoped
  `<prefix>:n8n.commands` channel. Subscribing to that channel directly and
  matching the `senderId` against pod names confirmed the crossed wires.

  Changing the queue prefix also moves the Redis list KEDA watches, so
  `scaling.tf`'s worker `ScaledObject` `listName` metadata now tracks it
  (`"<prefix>:jobs:wait"` / `"<prefix>:jobs:active"`) instead of being
  hardcoded to `bull:jobs:*`. Without that, setting a prefix would have left
  KEDA polling an empty list and silently frozen worker autoscaling at its
  minimum. **Changing this on a live deployment abandons whatever is already
  queued under the old prefix**: drain the queue first, the same way the Redis
  topology variables are treated.

- **New `redis_kms_encryption_enabled` variable** (default `false`) encrypts
  the ElastiCache Redis tier at rest with a module-created Customer Managed
  KMS Key (`aws_kms_key.redis`). Clears Checkov finding `CKV_AWS_191`.

  Defaults to `false` to preserve the existing standalone
  `aws_elasticache_cluster`, which Redis OSS cannot encrypt at rest. HA- or
  TLS-selected replication groups are encrypted with the ElastiCache-managed
  key; enabling this toggle selects the replication-group topology and uses the
  module CMK instead.

  `kms_key_id` only exists on `aws_elasticache_replication_group`, not on the
  default single-node `aws_elasticache_cluster`, so this is a third variable
  (alongside `redis_high_availability_enabled` and
  `redis_transit_encryption_enabled`) that independently selects the
  replication group. Enabling it on a deployment that asks for neither HA nor
  TLS moves Redis onto the replication group at the same one-node cost, just a
  different resource type. `kms_key_id` is `ForceNew`, so **flipping this on
  an existing deployment replaces Redis and drops the queue**, the same trap
  the other two Redis topology variables document; treat it as a
  maintenance-window operation and drain the queue first. See README →
  "Redis in-transit encryption and AUTH" for the full three-variable
  interaction table.

<!--
  The entry below is slated for 0.4.0, not this 0.3.0-bound Unreleased batch.
  A few other PRs land ahead of it and close out 0.3.0 first; whoever cuts
  the 0.3.0 release notes should leave this entry behind in [Unreleased]
  rather than moving it up. Tracked as a draft PR: held on version sequencing,
  and may need further refinement even after 0.3.0 ships and it's ready to
  come off draft.
-->

- **`examples/istio-split-ingress`** (targeted for 0.4.0): an Istio-native
  equivalent of `examples/split-ingress` for callers running Istio instead of
  an ALB Ingress Controller. Two physically separate Istio ingress gateways,
  each behind its own Network Load Balancer, split public webhook traffic
  from an internal-only editor UI and REST API, routed via a local `Gateway`/
  `VirtualService` Helm chart rather than `kubernetes_ingress_v1` resources.
  Supports both NLB-terminated (default) and Gateway-terminated TLS via the
  new `istio_tls_mode` variable. AWS WAFv2 cannot attach to a Network Load
  Balancer, so this example has no WAF equivalent; see its README for the
  gap. See [#87](https://github.com/n8n-io/terraform-aws-n8n/issues/87).

### Changed

- **`examples/customer-managed-everything` orders n8n after the controllers it
  installs directly.** The n8n chart renders a KEDA `ScaledObject`
  unconditionally, and with `install_keda = false` on `module "n8n"` there was
  no resource for Terraform to infer an ordering edge from, so the release
  could be applied before KEDA's CRDs existed. The example's `kubernetes` and
  `helm` providers now read the stand-in cluster resource directly instead of
  `module.n8n`'s outputs, which is what makes `depends_on = [module.controllers]`
  declarable rather than a cycle. `modules/controllers/keda.tf` states the
  contract for anyone else invoking that submodule directly.

- **`N8N_REDIS_KEY_PREFIX` is reserved in `n8n_extra_env`.** `redis_key_prefix`
  is documented as the single source of truth for the Redis namespace, setting
  n8n's own prefix, Bull's (`QUEUE_BULL_PREFIX`, already reserved via the
  `QUEUE_` family) and the KEDA trigger's `listName` together. Without the
  reservation an `n8n_extra_env` entry could move one of the three on its own,
  leaving KEDA watching a list nothing writes to.

- **`create_db_kms_key`, `db_logs_kms_key_enabled` and `create_s3_kms_key`
  replace inferring "bring your own key" from an ARN being null.** The three
  KMS ARN inputs were each compared against null inside a `count`, which meant
  `db_kms_key_arn = aws_kms_key.mine.arn`, a key created in the same
  configuration, failed the plan outright with "The count value depends on
  resource attributes that cannot be determined until apply". A `string`
  variable with a static default still arrives unknown if the caller wires a
  resource attribute into it, so nullness was never safe to gate on. The
  module now gates on a boolean the caller writes as a literal, leaving the ARN
  beside it free to be computed. Each boolean carries a `validation` rejecting
  the incomplete half and a `check` warning on the ignored half, the same
  three-part shape as every other customer-managed toggle. All three ARN inputs
  are new in this same unreleased range, so no released configuration is
  affected; `docs/customer-managed-infrastructure.md` uses the episode as the
  worked example under "Why a static boolean, not `x == null` inference".

- **Documentation only, no behavior change: three limitations found during
  live validation of the customer-managed paths are now written down instead
  of being discovered at apply time.**

  `docs/troubleshooting.md` gains two entries. The first covers the AWS Load
  Balancer Controller failing with `couldn't auto-discover subnets: ... are
  tagged for other clusters` when a second n8n stack is deployed into a VPC
  another deployment already uses: LBC treats another cluster's
  `kubernetes.io/cluster/<name>=shared` subnet tag as disqualifying rather
  than shareable, and the fix is to name the subnets explicitly through
  `ingress_annotations`. The second covers two deployments sharing one
  external Redis interfering with each other's workflow activation, now
  fixable with the new `redis_key_prefix` above.

  `docs/customer-managed-infrastructure.md` gains a section on `create_eks =
  false` + `create_ingress = true`, which today has exactly two paths and not
  the third one most callers on a shared cluster would reach for: `install_lbc
  = false` is hard-rejected whenever `create_ingress = true`, with no
  exception for an existing cluster that already runs a healthy LBC. Recorded
  as a known limitation with the reasoning, rather than fixed in the same pass
  as the Pod Identity gating above, since relaxing it changes the module's
  plan-time validation contract.

  `db_host`'s description now states that `create_database = false` shares the
  exact database and tables, not just the host: there is no `db_name` input, so
  the database name is fixed at `n8n_enterprise`. Two deployments pointed at
  one customer-managed Postgres share one n8n instance's data. The
  migration/cutover case works; true multi-tenant sharing does not.

  A third `docs/troubleshooting.md` entry, also from live validation: on the
  `create_eks = false` path, a `terraform plan` with any change pending
  upstream of the existing cluster defers `data.aws_eks_cluster.existing` to
  apply time, which leaves the kubernetes provider's `host` unknown and makes
  it dial `localhost` while refreshing resources already in state, failing
  the plan with `connect: connection refused`. The entry gives the recovery
  (apply the upstream change on its own first) and warns explicitly against
  `-refresh=false`, which defers every data source including
  `aws_caller_identity` and turns the generated S3 bucket name unknown,
  planning a destroy and recreate of the bucket holding binary execution
  data.

- **`db_engine_version` now defaults to `18.4` instead of `16.9`.** n8n's
  Postgres version policy supports the latest two actively-maintained majors
  (17 and 18, as of this writing) plus one older, time-limited compatibility
  major (16); the old default sat in that deprecating compatibility tier
  rather than on an actively-maintained major. See
  [#84](https://github.com/n8n-io/terraform-aws-n8n/issues/84).

  An in-place module upgrade leaves existing deployments unchanged:
  `aws_db_instance.n8n` carries `lifecycle.ignore_changes = [engine_version]`
  (added so `auto_minor_version_upgrade` drift doesn't get reset on every
  apply), and that same setting means a new default in the variable does not by
  itself produce a plan diff on state created under the old default. The new
  default applies to instances created after this change, including replacement
  instances. Existing instances stay on whatever `engine_version` is already
  in state until upgraded deliberately out-of-band. Follow
  [AWS's major-version upgrade process](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.PostgreSQL.MajorVersion.Process.html):
  validate extensions and application compatibility first, plan for downtime
  or use a blue/green deployment, and pass `--allow-major-version-upgrade` when
  using `aws rds modify-db-instance`. Omit `--apply-immediately` to schedule the
  change for the next maintenance window. After the upgrade, `ignore_changes`
  means Terraform picks up the new value on refresh rather than fighting it.

- **`db_engine_version` now declares `nullable = false`.** Passing `null`
  falls back to the default instead of failing the format validation with a
  misleading "must be of the form MAJOR.MINOR" error.

- **`examples/large`'s Aurora PostgreSQL cluster now pins `engine_version =
  "18.4"` instead of `16.4`,** for the same reason as the RDS default above.
  Aurora and other Postgres-compatible derivatives are explicitly out of
  n8n's official support scope per policy; the example's README and
  `aurora.tf` now say so. The example is kept for its I/O-Optimized
  throughput characteristics, which are unrelated to the engine version bump.
  Same `ignore_changes` caveat applies: this only affects newly-created
  clusters.

- `create_eks` input (default `true`). Set to `false` to deploy onto an
  existing EKS cluster (`existing_eks_cluster_name`) instead of the module
  creating its own cluster, node group, node IAM role, and Pod Identity Agent
  addon. RDS, ElastiCache, S3, the namespace, and the IAM roles and Pod
  Identity associations for n8n and any `install_*` controller stay exactly as
  they were either way; only the cluster and node group underneath them stop
  being module-managed. Two facts about the existing cluster are checked at
  plan time: it must be in `vpc_id` (a hard failure, since every security
  group, subnet, and route this module writes assumes the cluster's ENIs live
  there), and it must already have the `eks-pod-identity-agent` addon
  installed (the AWS provider itself fails the plan if it does not, via
  `data.aws_eks_addon`). A Kubernetes-version mismatch against
  `kubernetes_version` only warns
  (`check.existing_eks_cluster_kubernetes_version_matches`), since a control
  plane one release ahead of or behind is frequently still fine. Everything
  else, node capacity for the HPA/KEDA maxima, Cluster Autoscaler
  auto-discovery tags, API server reachability, and naming/identity
  collisions on a shared cluster, cannot be validated on infrastructure this
  module does not own, so `existing_eks_cluster_prerequisites_confirmed` is a
  required, explicit attestation enumerating each one rather than a silent
  assumption. The EBS CSI addon and default `gp3` `StorageClass` are gated
  separately, on their own `create_ebs_csi` input (see below), rather than
  folded into this one. See README.md → "Bring your own EKS cluster".

- `create_ebs_csi` input (default `true`). Set to `false` to skip installing
  `aws_eks_addon.ebs_csi` and the default `gp3` `StorageClass` (`storage.tf`),
  e.g. when `create_eks = false` and the existing cluster you are deploying
  onto already runs its own CSI driver and default StorageClass: a second
  `aws-ebs-csi-driver` addon install on a cluster that already has one fails
  outright rather than degrading gracefully. Independent of `create_eks`,
  since a freshly created cluster never has a CSI driver of its own and
  should normally leave this at its default.
  `check.existing_eks_cluster_needs_its_own_storage_toggle` now warns
  specifically when `create_eks = false` and this is still left at its
  default, rather than firing on every `create_eks = false` deployment
  regardless of whether the caller has already opted out. Gated with `count`
  and a `moved` block, same pattern as `create_eks` itself. This resolves the
  storage open question the original `create_eks` proposal left undecided.

### Fixed

- **`examples/customer-managed-cluster` tagged its subnets for the wrong
  cluster name, so the Ingress apply timed out waiting for an ALB.** The
  example's VPC tagged subnets `kubernetes.io/cluster/<cluster_name>=shared`
  while the stand-in cluster it creates is named `<cluster_name>-cm`. The AWS
  Load Balancer Controller auto-discovers subnets by the cluster's real name
  and treats a subnet tagged for any other name as ineligible ("2 are tagged
  for other clusters"), so no ALB was ever provisioned and
  `kubernetes_ingress_v1.n8n`'s `wait_for_load_balancer` failed the apply.
  Found on a live deployment of the example; the mocked test suite cannot see
  LBC's server-side discovery. Fixed the same way
  `examples/customer-managed-everything` already handles it: a
  `customer_managed_cluster_name` local is now the single source for the
  cluster's name and both subnet tag keys, so the two cannot drift apart.

- **The stand-in clusters in `examples/customer-managed-cluster` and
  `examples/customer-managed-everything` no longer orphan a Never-expire
  control-plane log group on destroy.** Both enable all five
  `enabled_cluster_log_types` but owned no log group, so EKS auto-created
  `/aws/eks/<name>-cm/cluster` with "Never expire" retention outside
  Terraform, and `terraform destroy` left it behind, confirmed live on a
  destroy of `customer-managed-cluster`. Each example now creates the log
  group explicitly (365-day retention, `depends_on` from the cluster so EKS
  cannot race it into existence first), mirroring the module's own
  `aws_cloudwatch_log_group.eks_cluster` pattern.

- **State migration for every newly `count`-gated resource.** `create_eks`,
  `create_s3_bucket`, `create_ebs_csi`, `n8n_encryption_key_secret_ref` and
  `db_password_secret_ref` each put a `count` on resources that were
  unconditional in every released version, moving them from `.n8n` to
  `.n8n[0]`, and the `modules/controllers` extraction moved four more into a
  child module. Eighteen addresses had no `moved` block covering that change,
  so an upgrade would have planned a destroy and recreate of, among others,
  the live EKS cluster and node group, the S3 bucket holding n8n's binary
  execution data, and the Kubernetes Secrets the running pods are mounted
  against. Four existing blocks were also unreachable, sourcing the EBS CSI
  addon, IAM role, policy attachment and gp3 StorageClass from a `[0]` index
  that no released version ever wrote. All of it now resolves from a released
  state to its current address (`refactoring.tf`).

- **The Load Balancer Controller and Cluster Autoscaler IAM roles and policies
  are gated with their associations**, on the same `create_eks || install_<x>`
  predicate, instead of being created unconditionally. Left unconditional they
  were, on the `create_eks = false` plus `install_<x> = false` path, roles
  carrying `AWSLoadBalancerControllerIAMPolicy` and the cluster-autoscaler
  policy that nothing could assume, since the association that binds them to a
  ServiceAccount is skipped there. Their names are derived from `cluster_name`
  alone, so two `modules/controllers` calls sharing a cluster also collided on
  `EntityAlreadyExists` at apply time: `examples/customer-managed-everything`
  invokes the submodule directly *and* calls `module "n8n"`, whose own
  controllers call is always instantiated, and is exactly that shape.

- **The Cluster Autoscaler's IAM condition keys on the real cluster name.** The
  `autoscaling:ResourceTag/k8s.io/cluster-autoscaler/<name>` condition on
  `SetDesiredCapacity` and `TerminateInstanceInAutoScalingGroup` was built from
  `cluster_name`, while the chart auto-discovers node group ASGs by
  `eks_cluster_name`. The two are the same string when the module creates the
  cluster, and differ on `create_eks = false`, where the autoscaler would come
  up healthy and silently hold no write permission on any ASG it could see.

- **The AWS Load Balancer Controller webhook failure policy is actually
  applied.** The module set `webhookConfig.failurePolicy`, which chart 3.5.0
  does not read; Helm accepts unknown `--set` paths silently, so the webhook
  stayed on its chart default of `Fail` and could still block Ingress deletion
  during teardown when LBC pods are unhealthy. The key the chart reads is
  `webhookConfig.ingressValdationFailurePolicy`, upstream's typo and all.

- **`n8n_external_secrets_aws_enabled` grants `kms:Decrypt`.** An allow-listed
  secret encrypted with a customer managed KMS key was unreadable: Secrets
  Manager decrypts as the calling principal, so `GetSecretValue` returned
  `AccessDenied` no matter how the secret's own policy read. Scoped by a
  `kms:ViaService` condition rather than a key ARN list, because
  `DescribeSecret` returns the key as an ID, an alias, an alias ARN or nothing
  at all, and only one of those is usable in an IAM `Resource`.

- **Minimum Terraform version raised to `>= 1.11`**, from `>= 1.9`, in every
  `versions.tf`: the module root, `modules/controllers`, and all ten examples.
  This is a breaking change for anyone pinned below 1.11. Two things forced it.
  `override_resource`'s `override_during` attribute, which three of the
  customer-managed examples' test suites need, arrived in 1.11 and is silently
  ignored before it. And CI had already moved to a single 1.15.8 pin, which
  left `>= 1.9` as a claim nothing exercised, on a repo that has been bitten
  before by exactly that kind of untested floor (`check` blocks did not
  short-circuit `&&`/`||` before Terraform 1.10, a hazard invisible on any
  newer local CLI). The floor and the CI pin are now consistent, and 1.15.8
  sits above both. The `check` blocks keep their `guard ? body : true` shape,
  which is now a consistency convention rather than a correctness requirement;
  `AGENTS.md` records why, so nobody "simplifies" one back into the form that
  used to break.

  **Upgrade note.** Per the stability contract in
  [README.md → Stability & versioning](README.md#stability--versioning), a
  raised version floor is a minor-boundary change. Nothing in your
  configuration needs editing: upgrade the Terraform CLI to 1.11 or newer and
  re-run `terraform init`. On an older CLI, `init` fails immediately with an
  unsupported-version error rather than planning anything, so there is no
  half-applied state to recover from. There is no state migration, no resource
  replacement, and no input or output changed by this.

- **`examples/customer-managed-redis`, `-s3` and `-cluster` declare the
  Terraform floor their own test suites need.** All three use
  `override_resource`'s `override_during`, which arrived in Terraform 1.11 and
  is silently ignored before it, so the documented `terraform test` command
  failed with a confusing assertion error rather than a version error on any
  1.9 or 1.10 their `versions.tf` claimed to support.

- **The Load Balancer Controller and Cluster Autoscaler Pod Identity
  associations are now gated, so `create_eks = false` no longer collides with
  an association the existing cluster already carries.** Both associations
  (`modules/controllers/iam.tf`) were fully unconditional, on the deliberate
  and, for a freshly created cluster, correct reasoning that an
  externally-installed controller still needs its IAM binding. That reasoning
  does not survive `create_eks = false`: pointed at an existing cluster whose
  `aws-load-balancer-controller` ServiceAccount is already bound, e.g. by a
  previous invocation of this exact module against the same cluster, EKS
  rejects the second association with `409 ResourceInUseException` and the
  apply fails. Confirmed live, not inferred.

  The gate is `count = var.create_eks || var.install_<x> ? 1 : 0`, not a bare
  `var.install_<x>`, which keeps the original fresh-cluster behavior intact:
  on `create_eks = true` nothing can already be bound, so the association is
  still created regardless of the toggle. On `create_eks = false`,
  `install_lbc = false` / `install_cluster_autoscaler = false` is now read as
  an attestation that the binding already exists there. Existing deployments
  are unaffected: every one of them has `create_eks = true` or the matching
  `install_*` toggle at its default `true`, so the gate evaluates true and the
  association stays exactly where it is. `refactoring.tf`'s `moved` blocks
  target the new `[0]` addresses.

  `modules/controllers` takes a new `create_eks` input for this, defaulting to
  `true`. The default matters: that submodule is a documented direct-invocation
  point for advanced callers (see `examples/customer-managed-everything`), and
  `true` reproduces its original unconditional behavior, so the new input is
  additive rather than a breaking change to its contract.

- **`Taskfile.yml`'s `EXAMPLES` list, and the per-example command blocks in
  `AGENTS.md` and `CONTRIBUTING.md`, had drifted four examples behind the CI
  matrix.** All three still enumerated only `small`, `medium`, `large`,
  `cloudflare`, `godaddy` and `split-ingress`, while
  `.github/workflows/terraform-tests.yml` also runs `customer-managed-redis`,
  `customer-managed-s3`, `customer-managed-cluster` and
  `customer-managed-everything`. `task ci` therefore reported green on changes
  it had never validated, and `CONTRIBUTING.md`'s claim that the documented
  loop "mirrors the CI matrix exactly" was false. This is not hypothetical: it
  is how a change to `modules/controllers`' input contract passed a full local
  run while breaking `examples/customer-managed-everything`, the one root
  module that invokes that submodule directly. All three lists now match the
  CI matrix, and `AGENTS.md`'s block is a loop over that list rather than
  hand-maintained per-example lines (which also fixes a latent bug in it: the
  lines chained bare `cd examples/<x>` commands that were relative to the
  previous example's directory, so only the first could ever have run).

- `create_elasticache`, `redis_host`, and `README.md`'s "Bring your own
  Redis" (now "Customer-managed Redis") section all incorrectly stated that
  an external Redis requiring AUTH or TLS was "not supported yet." AUTH
  (`redis_auth_token` / `redis_auth_token_secret_ref`) and TLS
  (`redis_transit_encryption_enabled`) have both worked on the
  `create_elasticache = false` path for some time (`local.redis_auth_active`
  and `local.redis_tls_active` in `locals.tf` are not gated on
  `create_elasticache`); the docs were simply never updated when that
  support landed. Corrected in both variable descriptions and the README
  section, which now also carries a worked example.

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

- **A caller-supplied `db_kms_key_arn` no longer encrypts the `postgresql` log
  group.** CloudWatch Logs cannot use a CMK unless that key's policy grants
  `logs.<region>.amazonaws.com` the `kms:Encrypt`, `kms:Decrypt`,
  `kms:ReEncrypt*`, `kms:GenerateDataKey*` and `kms:DescribeKey` actions. A
  centrally-owned key, which is the whole use case for the input, will not
  carry that statement by default, so `CreateLogGroup` failed with
  `InvalidParameterException` before the RDS instance was created, leaving a
  half-built stack. Worse, no AWS provider data source returns a key policy
  (`data.aws_kms_key` has no `policy` attribute and there is no
  `aws_kms_key_policy` data source), so the prerequisite cannot be verified at
  plan time and the failure could not be predicted.

  The log group now resolves through its own local. On the module-managed path
  nothing changes: the module wrote the CloudWatch Logs statement onto the CMK
  it created, so the log group stays on that key. On the bring-your-own path
  the log group falls back to CloudWatch's AWS-managed encryption unless
  `db_logs_kms_key_arn` is set. A `check` block discloses that fallback on
  every plan, because "I gave the module my CMK" and "everything the module
  creates uses my CMK" are different claims and a reviewer will ask which is
  true. Setting `db_logs_kms_key_arn` silences it.

  Three things about a supplied key *are* checkable and are now checked, for
  both `db_kms_key_arn` and `db_logs_kms_key_arn`: `key_state` is `Enabled`,
  `key_usage` is `ENCRYPT_DECRYPT`, and `key_spec` is `SYMMETRIC_DEFAULT`.
  That covers a mistyped, deleted, disabled, pending-deletion, asymmetric or
  sign-only key. The describe adds no IAM requirement, since creating an
  encrypted RDS instance already requires `kms:DescribeKey` and
  `kms:CreateGrant` of the caller. The key's region is asserted from the ARN
  string with no API call, so it holds even on paths where the key is unused.
  `s3_kms_key_arn` deliberately gets no such probe: the module needs no
  permission on that key, and describing it would invent an IAM requirement
  that does not otherwise exist.

### Added

- **Customer-managed infrastructure**, consolidated. Every layer this module
  can provision (EKS, RDS, ElastiCache Redis, S3, the cluster controllers) can
  also be pointed at infrastructure the caller already runs, following the
  same `create_<x>` / reference-variable / `validation` shape throughout.
  Most of these toggles already shipped individually across earlier releases;
  what's new here is making the pattern discoverable as one thing:

  - A new [`README.md` → "Customer-managed infrastructure"](./README.md#customer-managed-infrastructure)
    section with a single state-matrix table (layer, toggle, reference
    inputs) instead of the pattern being scattered across per-variable docs.
  - A new [`docs/customer-managed-infrastructure.md`](./docs/customer-managed-infrastructure.md)
    for contributors, documenting the convention itself: why a static
    boolean rather than `x == null` inference, the checklist for adding a
    new customer-managed layer, and why the module deliberately does not
    add `data`-source checks of a caller-supplied resource's security
    configuration (an AWS API call at plan time that hard-fails for anyone
    whose credentials can't read that specific resource).
  - Four new runnable examples,
    [`examples/customer-managed-redis`](./examples/customer-managed-redis/),
    [`examples/customer-managed-s3`](./examples/customer-managed-s3/),
    [`examples/customer-managed-cluster`](./examples/customer-managed-cluster/),
    and [`examples/customer-managed-everything`](./examples/customer-managed-everything/).
    The first three each provision a plain-Terraform stand-in for one piece
    of infrastructure a customer would already have and point the module at
    it with `create_elasticache = false` / `create_s3_bucket = false` /
    `create_eks = false`. `customer-managed-redis` also doubles as a
    runnable demonstration that AUTH and TLS work on the customer-managed
    Redis path (`redis_auth_token`, `redis_transit_encryption_enabled`),
    which the module's own docs incorrectly described as unsupported until
    this release (see Fixed, below). `customer-managed-everything` combines
    all three stand-ins plus a direct `modules/controllers` invocation, so
    every layer the module can create is customer-managed at once.
    `customer-managed-cluster` and `customer-managed-everything` have no
    full-plan `terraform test` coverage, unlike the other two: the module's
    own `data.aws_eks_cluster.existing` read cannot be resolved to a known
    value under `command = plan` with mocked providers once nested inside
    an example's own `module "n8n"` call, confirmed by direct
    experimentation rather than assumed. See each example's own
    `tests/defaults.tftest.hcl` for the full writeup; the module's own
    `create_eks = false` logic is unaffected and remains covered by the
    repo root's own test suite.
  - Terminology: user-facing docs now say "customer-managed" rather than
    "bring your own"/"BYO" throughout (`create_ingress`, `redis_host`, the
    two `n8n_*_service_name` outputs, the "Bring your own Redis" and "Bring
    your own Ingress" `README.md` sections, now "Customer-managed Redis" and
    "Customer-managed Ingress").

  No variable names, defaults, or behavior changed as part of this: this is
  a documentation and discoverability consolidation over toggles that
  already existed. Tracked in [#88](https://github.com/n8n-io/terraform-aws-n8n/issues/88).

- `modules/controllers` submodule. The AWS Load Balancer Controller,
  Cluster Autoscaler, metrics-server, KEDA and the EBS CSI driver, previously
  flat root-level resources, now live in a nested submodule that the root
  module calls by default (`controllers.tf`), so every existing deployment's
  plan is unchanged: same `install_*`/`create_ebs_csi` variables, same
  names, same defaults, at the same `module "n8n" { ... }` call site. The
  point of the extraction is for an advanced caller deploying onto an
  existing cluster (`create_eks = false`) to be able to invoke
  `modules/controllers` directly with only the controllers they actually
  need, instead of the root module's five toggles being the only way in.
  State-safe: every relocated resource has a `moved` block in
  `refactoring.tf` chaining from its prior address, so upgrading is a no-op
  plan for every existing deployment, not a destroy-and-recreate of live
  Helm releases and IAM roles. The Load Balancer Controller's and Cluster
  Autoscaler's IAM role, policy and Pod Identity association are all gated
  together on `create_eks || install_<x>`, rather than on the `install_<x>`
  toggle alone: a freshly created cluster (`create_eks = true`, the default)
  gets all three regardless of the toggle, so an externally installed
  controller still receives its IAM binding, and an existing cluster with the
  toggle off gets none of them, so nothing collides with an association that
  cluster may already carry. See the "Cluster controllers" comment above
  `install_lbc` in `variables.tf`, and the "Fixed" entry below.

- `n8n_encryption_key` input (default `null`, sensitive) overrides the
  module-generated `N8N_ENCRYPTION_KEY`. Every deployment before this input
  existed got a fresh `random_id` with no way to supply one, which silently
  blocked disaster recovery: n8n encrypts stored credentials under this key,
  so restoring an RDS snapshot into a new stack (a rebuilt cluster, a
  cross-region standby, any fresh `terraform apply` against the same
  database) generated a brand-new random key, leaving every credential the
  restored database already held permanently undecryptable under it. Set this
  to the original deployment's key, retrieved beforehand with
  `terraform output -raw n8n_encryption_key`, to keep decrypting the same
  database's credentials across a restore, a rebuild, or an adoption of this
  input by a deployment that already has a `random_id`-generated key. Must be
  exactly 64 hexadecimal characters (32 bytes), the shape `random_id` with
  `byte_length = 32` has always produced; anything else is rejected at plan
  time.

  Left `null` (the default), behavior is unchanged: the module generates the
  key exactly as it always has. Gating `random_id.n8n_encryption_key`'s
  `count` on this input changes its resource address from `.n8n_encryption_key`
  to `.n8n_encryption_key[0]`; a `moved` block in `refactoring.tf` absorbs
  that, so upgrading onto this input without setting it is a no-op, verified
  by `terraform plan` rather than by inspection.

  **This is not a rotation mechanism.** n8n's own docs describe
  `N8N_ENCRYPTION_KEY` as an instance master key that is set once and never
  changes; a separate data encryption key, stored in the database and itself
  encrypted by this one, is what n8n's own key-rotation feature
  (`N8N_ENV_FEAT_ENCRYPTION_KEY_ROTATION`, a one-way operation with no
  rollback) actually rotates. Setting this variable to a value other than the
  one a database's existing credentials were encrypted under does not migrate
  or re-encrypt anything: it just makes every one of those credentials
  permanently unreadable, with no recovery path on n8n's side. The only
  supported uses are a first deployment against an empty database, or
  restoring the *exact original* key into a rebuilt stack pointed at a
  database that already holds credentials encrypted under that same key.

  There is deliberately no `check` block for this input. What separates the safe
  uses from the destructive one is what the target database already holds, which
  no Terraform expression can read, and the one plan-time proxy available turned
  out to be backwards: warning whenever the input met `create_database = false`
  fired on the *documented* use (`aws_db_instance.n8n` takes no
  `snapshot_identifier`, so restoring a database into a rebuilt stack means
  restoring outside the module and pointing at it) while staying silent on the
  likeliest real mistake (editing the value on a live `create_database = true`
  deployment whose credentials are already encrypted under the generated key,
  which plans clean and destroys all of them). The guidance is on the variable,
  the `n8n_encryption_key` output, and in README.md instead.

- `redis_transit_encryption_enabled` and the new `redis_auth_token` input now
  also apply on the external-Redis path (`create_elasticache = false`),
  closing a gap left by the Redis BYO hook: that path previously required an
  unauthenticated, plaintext endpoint outright, rejected at plan time if
  `redis_transit_encryption_enabled` was set alongside it. Both inputs now
  describe properties of the caller's own Redis instead of a migration lever
  on infrastructure the module manages: `redis_transit_encryption_enabled =
  true` declares that the supplied `redis_host` speaks TLS (the module does
  not verify this: getting it backwards either way is a connection failure,
  not a security hole), and `redis_auth_token` (sensitive, default `null`)
  supplies the AUTH credential for a Redis that requires one. Either, both,
  or neither may be set independently, since a plain external Redis can
  require AUTH without TLS, unlike ElastiCache. Both are wired into n8n and
  KEDA identically to the module-managed path: a Kubernetes Secret referenced
  by name, never inlined into the Helm release values or the ScaledObject
  manifest.

  `redis_transit_encryption_mode` and `redis_apply_immediately` remain
  properties of the module-managed replication group specifically and do not
  reach the external path; the existing
  `redis_tuning_requires_module_managed_elasticache` check now also warns on
  `redis_transit_encryption_mode`, and a new
  `redis_auth_token_requires_external_redis` check warns when
  `redis_auth_token` is set while `create_elasticache = true` (ignored, the
  module generates and manages its own token there and cannot substitute a
  caller-supplied one on infrastructure it owns).

  On the module-managed path, nothing changes: `redis_tls_active` still
  requires `create_elasticache = true` to mean anything, the module still
  generates and rotates its own AUTH token, and `redis_transit_encryption_mode`
  /`redis_apply_immediately` still drive the same three-apply migration.
  Verified at plan time across every combination (TLS only, AUTH only, both,
  neither) on the external path, and that the full existing module-managed
  test suite (HA, TLS, AUTH, and the staged migration) still passes unchanged.

- `n8n_image_repository` input (default `null`) points the Helm release at a
  custom n8n application image instead of the chart's
  `docker.n8n.io/n8nio/n8n`. The motivating case is community packages: n8n
  installs them onto the pod's ephemeral filesystem, so keeping UI-installed
  nodes across reschedules currently means
  `n8n_reinstall_missing_packages = true`, an npm install on every pod boot that
  a large dependency tree turns into a CPU- and memory-heavy rollout
  ([issue #52](https://github.com/n8n-io/terraform-aws-n8n/issues/52)). Baking
  the packages into the image removes boot-time installs entirely. Repository
  and tag stay separate inputs, merged into the Helm values key by key, so
  setting one leaves the other on the chart default; a tag or digest inlined
  into the repository is rejected at plan time, since the chart appends the tag
  itself. See
  [issue #53](https://github.com/n8n-io/terraform-aws-n8n/issues/53) and
  README → Custom n8n images.

  With `n8n_image_pull_secrets` left empty, the image has to be pullable by the
  node group's IAM role (ECR in the same account is, via the
  `AmazonEC2ContainerRegistryReadOnly` policy the module already attaches) or
  be public. See `n8n_image_pull_secrets` below for anything else.
- `n8n_task_runner_image_tag` input (default `null`) pins the tag of the task
  runner sidecar image (`n8nio/runners`). The chart derives that tag from the
  n8n application image's tag, which breaks as soon as the application tag is
  not a published n8n version: with `n8n_image_tag = "2.27.4-mypackages"` the
  sidecar resolves to `n8nio/runners:2.27.4-mypackages`, which does not exist,
  and every main and worker pod stays in `ImagePullBackOff`. Task runners are
  enabled by default, so a custom image is effectively unusable without this.
  Leave it `null` to keep the chart's inheritance.
- `n8n_custom_extensions_path` input (default `null`) maps to
  `N8N_CUSTOM_EXTENSIONS` on all three pod types, which is what makes nodes
  baked into a custom image load at all. A plain `npm install` into the image's
  `node_modules` does not: n8n dropped global `node_modules` loading in 1.0 (v10
  migration guide), and `packages/cli/src/load-nodes-and-credentials.ts` scans
  only `n8n-nodes-base`, `@n8n/n8n-nodes-langchain`, and the custom directories
  at startup. Without this input, `n8n_image_repository` alone gets a custom
  image onto the pods but leaves its nodes invisible.

  Two validations encode failure modes found in the n8n `2.34.0` loader and the
  pinned chart. A path under `/home/node/.n8n` is rejected: the chart mounts a
  volume there on the main deployment only, and the module leaves
  `persistence.enabled` at the chart default, so an `emptyDir` hides whatever
  the image baked in on mains while workers and webhook processors still see it.
  A path containing `;` is rejected: n8n splits the variable on it, and since
  every custom directory is registered under the same `CUSTOM` key with each
  overwriting the last, extra directories are silently dropped rather than
  merged. A path must also be canonical, since both of those rules are string
  comparisons and `/home/node//.n8n/custom` would otherwise slip past them. A
  `check` block warns when the path has nothing behind it: neither a custom
  image nor an `n8n_extra_volume_mounts` entry covering it.

  Known limitation, documented rather than fixed: nodes loaded this way are
  registered as `CUSTOM.<node>` instead of `<npm-package>.<node>`, because
  `postProcessLoaders` qualifies every type with the loader's package name and
  the custom loader's is the literal `CUSTOM`. Workflows built against a
  UI-installed copy of the same package will not resolve, so this suits new
  deployments rather than migrating an instance already using community nodes.
- Three plan-time `check` blocks for image and tag combinations that are
  accepted but almost certainly not intended: `n8n_image_repository` without
  `n8n_image_tag` (the chart appends its own `stable`, which private registries
  rarely publish), a custom repository and tag with task runners enabled but no
  `n8n_task_runner_image_tag` (the ImagePullBackOff case above), and
  `n8n_task_runner_image_tag` set while `n8n_task_runners_enabled = false`
  (silently inert). All warn rather than fail, since none can be decided with
  certainty from the inputs alone. Pinning only `n8n_image_tag`, the common
  case, trips none of them.
- `n8n_image_pull_secrets` input (default `[]`) names existing
  `kubernetes.io/dockerconfigjson` secrets in the namespace, so a custom image
  can come from a private registry rather than only a public one or
  same-account ECR. The pinned chart renders `imagePullSecrets` nowhere, not on
  the pod spec and not on the ServiceAccount, so the module reaches them the
  way the chart itself documents: a non-empty list makes it create the
  ServiceAccount with the secrets attached and pass
  `serviceAccount.create = false`. That account is named `n8n-enterprise-pull`
  rather than the chart's `n8n-enterprise`, so turning the input on for a live
  deployment creates it alongside the one Helm still owns instead of colliding
  with it; the S3 Pod Identity association follows whichever name is in play.
  Reverting to `[]` hands the account back to the chart in one apply. The
  module takes secret names, never credentials, so no registry password lands
  in Terraform state. A `check` block warns when secrets are set without
  `n8n_image_repository`, since the chart's own images need none.

  Cross-account ECR should not use this: its authorization tokens expire after
  12 hours, so a pull secret holding one is stale before the next apply. Add
  the node group role to the source registry's repository policy instead. The
  new `node_group_role_arn` output is the principal to name there.
- `n8n_extra_volumes` and `n8n_extra_volume_mounts` inputs (both default `[]`)
  map to the chart's `extraVolumes` and `extraVolumeMounts` on main, worker and
  webhook-processor pods, which makes a ConfigMap, Secret or ReadWriteMany
  claim an alternative to rebuilding an image for every community-package
  change. A volume takes a name and exactly one source (`config_map`, `secret`
  or `persistent_volume_claim`), and the inputs are typed rather than raw chart
  YAML so that plan time can reject what Kubernetes would refuse at admission:
  a mount naming a volume that was never declared, the chart's reserved `data`
  and `task-runner-config` names, a mount at `/home/node/.n8n` (where the chart
  already mounts `data`), repeated names or paths, and a non-canonical or
  trailing-slash path. `default_mode` is an octal string rather than a number,
  because Terraform reads `0644` as decimal `644`, which is octal `1204`. A
  `check` block warns about a declared volume that nothing mounts, which
  Kubernetes accepts silently.

  `persistence` is deliberately not exposed. Its PVC defaults to
  `ReadWriteOnce`, which cannot serve the two main replicas this module runs
  (let alone the HPA above them), and it never reaches workers or webhook
  processors, so nodes kept there would load on some pod types and not others.
- `n8n_community_packages_registry` input (default `null`) maps to
  `N8N_COMMUNITY_PACKAGES_REGISTRY`, so community packages can be installed
  from a private npm mirror rather than `registry.npmjs.org`, which helps when
  egress to public npm is blocked or packages are vendored internally. When
  `null` the env var is omitted entirely and n8n's own default applies. Confirm
  the entitlement before setting this: n8n gates a non-default registry on the
  `COMMUNITY_NODES_CUSTOM_REGISTRY` feature rather than on holding a license
  key, so an instance licensed without it has community-package installs throw
  `FeatureNotLicensedError` instead of falling back to the public registry.

  Upgrade note: the env var name is now reserved. An existing `n8n_extra_env`
  entry named `N8N_COMMUNITY_PACKAGES_REGISTRY` is rejected at plan time and
  must move to the new input. The companion
  `N8N_COMMUNITY_PACKAGES_AUTH_TOKEN` is deliberately left unmanaged (it is a
  credential, and `config.extraEnv` renders into the Helm release and Terraform
  state in plaintext) and stays settable through `n8n_extra_env`.
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

- `alb_ssl_policy` input (default `"ELBSecurityPolicy-TLS13-1-2-2021-06"`) maps
  to the `alb.ingress.kubernetes.io/ssl-policy` annotation on the
  module-managed Ingress. Previously the HTTPS listener's TLS negotiation
  policy fell back to the AWS Load Balancer Controller's own default, which is
  not pinned by the module and can drift as AWS changes it. Operators with a
  compliance baseline (TLS 1.2 minimum, or TLS 1.3-only) can now set any
  AWS-published ELB security policy name without forking the module; the
  default pins a current, modern policy so the negotiated policy is explicit
  rather than implicit. Ignored when `create_ingress = false`, or when
  `ingress_annotations` sets the same annotation directly (last write wins;
  the module now warns when that happens, mirroring the existing
  `ingress_scheme` conflict check). See
  [issue #43](https://github.com/n8n-io/terraform-aws-n8n/issues/43).

  Upgrade note: this changes runtime behavior for existing deployments. The
  AWS Load Balancer Controller's own default when the annotation is unset is
  `ELBSecurityPolicy-2016-08`, which permits TLS 1.0/1.1 and weaker ciphers.
  The first apply after upgrading sets the annotation explicitly and raises
  the ALB's negotiated floor to TLS 1.2 (with TLS 1.3 preferred) via
  `ELBSecurityPolicy-TLS13-1-2-2021-06`. This is an in-place annotation update
  on the existing Ingress/ALB (no replacement), but it can reject handshakes
  from clients that only speak TLS 1.0/1.1. Set `alb_ssl_policy` to your
  current effective policy (or to `ELBSecurityPolicy-2016-08` to keep prior
  behavior verbatim) if you need to defer this change.
- `alb_inbound_cidrs` and `alb_inbound_prefix_list_ids` inputs (both default
  `[]`) restrict which sources reach the module-managed ALB, rendered into
  `alb.ingress.kubernetes.io/inbound-cidrs` and
  `alb.ingress.kubernetes.io/security-group-prefix-lists`. Empty lists omit the
  annotations entirely, so the AWS Load Balancer Controller default of
  `0.0.0.0/0` still applies and no existing deployment sees a plan diff. Use
  them to reach the editor UI and REST API only from known networks (corporate
  egress ranges, a VPN pool, partner prefixes) while still terminating on a
  public ALB. This narrows a public ALB and is not equivalent to
  `ingress_scheme = "internal"`, which moves the ALB off the public internet
  entirely; the two compose. See
  [issue #42](https://github.com/n8n-io/terraform-aws-n8n/issues/42).

  The restriction covers the whole ALB rather than individual paths, and the
  module-managed ALB serves the webhook prefixes alongside the editor UI, so it
  blocks inbound production webhooks from third-party senders too. Use these
  inputs when nothing external calls in, or when every sender sits on a known
  range; to lock down the editor while keeping webhooks public, run the two-ALB
  topology in `examples/split-ingress` instead. Both inputs are documented with
  that blast radius spelled out.

  `alb_inbound_cidrs` is IPv4 only, matching the ALB the module builds: it
  leaves the controller's default `ipv4` address type in place, so an IPv6 rule
  could never match a client, and a dualstack ALB needs IPv6 subnet CIDRs this
  module does not create. It also rejects an IPv4 block with host bits set
  (`203.0.113.5/24`), which Terraform and the controller both accept and EC2
  rejects when the security group rule is built, well after a clean apply. Three
  plan-time warnings cover the ways a restriction can silently not exist:
  setting the same annotation through `ingress_annotations`, which is merged
  last and still wins; setting `alb.ingress.kubernetes.io/security-groups`,
  which makes the controller ignore both restrictions because the caller then
  owns the security group; and setting either input alongside
  `create_ingress = false`, where the module has no Ingress to annotate.

  A fourth override path gets documentation rather than a warning: an
  `IngressClassParams` that sets `spec.inboundCIDRs` or `spec.prefixListsIDs`
  replaces the annotation outright, per field. It cannot reach the
  module-managed Ingress, which carries the legacy `kubernetes.io/ingress.class`
  annotation; the controller matches that first and never loads the IngressClass
  or its params. Caller-owned Ingresses that set only `spec.ingressClassName`,
  including both in `examples/split-ingress`, are exposed.
  `docs/troubleshooting.md` gains an entry with the `kubectl` and `aws` commands
  to diagnose an ALB that answers everyone despite a clean apply, and to verify
  against the security group the controller owns rather than against the
  annotation.

  Live verification also surfaced a quota hazard on
  `alb_inbound_prefix_list_ids`: a security group rule referencing a managed
  prefix list counts against the rules-per-security-group quota (default 60,
  `L-0EA8095F`) by the list's max-entries weight, once per listen port, and the
  module's ALB listens on 80 and 443. A list too heavy to fit (the AWS-managed
  CloudFront origin-facing list weighs 55, needing 110 rules by itself) takes
  the ALB
  offline for every source after a clean apply: the controller revokes the
  existing rules first, fails with `RulesPerSecurityGroupLimitExceeded`, and
  leaves the security group with no ingress rules at all. The input's
  description spells out the arithmetic instead of suggesting AWS-managed
  lists, and `docs/troubleshooting.md` gains an entry with the diagnosis and
  recovery.

  Behaviour above was verified against a live deployment on LBC v3.5.0 rather
  than from the controller source alone, including that the restriction covers
  port 80 as well as 443, that CIDRs and prefix lists are a union, that the
  controller reverts hand-edits to the security group it manages so recovery
  from a lockout is an apply rather than a console fix, and that a caller-owned
  `security-groups` annotation leaves the restriction unapplied.

  `alb.ingress.kubernetes.io/inbound-cidrs` set through `ingress_annotations`
  keeps working and keeps winning: it was the documented way to do this before
  these inputs existed. Delete the annotation when migrating, or the stale value
  continues to apply.

  `examples/split-ingress` predates these inputs and restricts its internal
  admin ALB with its own `admin_allowed_cidr_blocks`, since it owns its
  Ingresses and the module inputs do not reach them. It now enforces the same
  no-host-bits guard, which it was missing: it accepted `10.20.0.5/16` and left
  EC2 to reject the rule after a clean apply. Its exposure to the
  `IngressClassParams` override is the reverse of the module's, so the
  troubleshooting entry covers both call sites in one place rather than
  repeating the explanation per variable.

- `n8n_execution_data_storage_mode` input (default `"database"`, accepts
  `"s3"`) maps to `N8N_EXECUTION_DATA_STORAGE_MODE`, the second S3 offload mode
  n8n added in 2.27 ([n8n#32226](https://github.com/n8n-io/n8n/pull/32226)).
  With `"s3"` the data of each new execution is written to the module's existing
  S3 bucket as
  `workflows/{workflowId}/executions/{executionId}/execution_data/bundle.json`
  instead of into PostgreSQL. Execution-data writes are usually the dominant
  write load on the n8n database at volume, so this is the main lever for
  relieving RDS pressure in the queue-mode topology this module deploys.

  Nothing new is provisioned: the bucket, IAM policy, Pod Identity role, and
  `N8N_EXTERNAL_STORAGE_S3_*` connection already exist for binary data and are
  reused as-is. The pinned Helm chart has no value for this (its `s3.storage`
  block covers binary data only), so the env var goes through
  `config.extraEnv`, which reaches main, worker, and webhook-processor pods, as
  the n8n docs require in queue mode. Requires n8n >= 2.27 (pin
  `n8n_image_tag`) and an Enterprise license carrying `feat:executionDataS3`,
  which is a distinct entitlement from the `feat:binaryDataS3` the module's
  always-on binary data offload relies on; n8n refuses to start in `s3` mode
  without it. There is no
  backfill, and switching modes is non-destructive in both directions.
  `"filesystem"`, valid in n8n itself, is rejected: pod filesystems are
  ephemeral and unshared here. Default `"database"` emits no env var at all, so
  this is a no-op diff for existing deployments. Resolves
  [issue #47](https://github.com/n8n-io/terraform-aws-n8n/issues/47).

  **Upgrade note (breaking):** the env var name is now reserved. Unlike the
  other names the module took over, this one was *not* previously blocked by the
  `n8n_extra_env` guard: it matches none of the guard prefixes and was absent
  from the exact-match list, so callers could and did opt into `s3` mode through
  the escape hatch. Those configurations now fail variable validation at plan
  time and must move the value to `n8n_execution_data_storage_mode`. The
  behaviour is identical once moved, and the error message names the input, but
  this makes the change a minor-version boundary under
  [Stability & versioning](./README.md#stability--versioning), not a patch.

  A plan-time `check` block warns when the mode is `"s3"` while `n8n_image_tag`
  is pinned below 2.27. Older versions ignore the env var outright: pods start
  clean and execution data silently keeps going to PostgreSQL.

  Note the durability trade-off, documented in the README: `"s3"` moves
  execution data off RDS, which this module gives 7 days of automated backups
  and point-in-time recovery by default (`db_backup_retention_period`), and onto
  a bucket with no versioning, no backups, and `force_destroy = true`. A
  `terraform destroy` therefore takes execution history with it, and there is no
  recovery path. That was already true of binary attachments; `"s3"` extends it
  to execution history.

  Documented alongside it: the module still creates **no** S3 lifecycle
  configuration, and once execution data shares the bucket it cannot safely
  create one. Binary data (`.../binary_data/{fileId}`) is pruned *only* by S3,
  because n8n delegates it; execution data (`.../execution_data/bundle.json`)
  is pruned by n8n itself and a lifecycle rule can delete bundles it still
  references. The two cannot be separated by a rule, either: S3 lifecycle
  filters match a literal key prefix with no wildcards, both layouts share
  `workflows/{wf}/executions/{exec}/`, and n8n tags neither object. See the new
  "Execution data in S3" section in `README.md` for the trade-off a caller has
  to pick between.

  All six examples expose the input as a passthrough, each left at `"database"`
  so they apply unchanged. `large` has the most execution-data volume, but the
  least room for it is at the bottom: `small`, `cloudflare`, `godaddy` and
  `split-ingress` all run `db.t3.small` on 50 GB of gp2 with a 150 IOPS
  baseline, against Aurora I/O-Optimized with no IOPS ceiling at the top tier.
  Every example gains a test rejecting `"filesystem"`; the three that can run a
  full mocked plan (`cloudflare`, `godaddy`, `split-ingress`) also assert the
  `"database"` default.
- `n8n_redis_timeout_threshold` input (default `null`) exposes
  `QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD`, the budget n8n spends trying to reach
  Redis before calling `process.exit`. `null` leaves the chart's 10000 in place
  and emits no `redis.timeout` key at all, so existing releases see no Helm
  diff. Raise it when running `redis_high_availability_enabled = true` and you
  would rather n8n rode a failover out than restarted.

  This closes out the open question from the high availability work, where
  raising the threshold to 30s appeared to do nothing but delay the exit. It was
  not a stale-address bug in ioredis, which re-resolves DNS on every reconnect
  attempt and was confirmed recovering on a different IP without restarting.
  n8n simply never sets ioredis's `connectTimeout`, so it stays at 10s, and a
  connect to a demoted primary hangs for that full 10s before failing. Each
  failed attempt spends ~11.1s of the budget, making the threshold effectively
  quantized to 11.1s / 33.2s / 66.4s for settings of 10s / 30s / 60s.

  Against a 25 second outage, a 30s threshold fires at 43.4s and the connection
  would have returned at 44.5s: it exits **1.1 seconds early**.

  Confirmed against a real ElastiCache failover at `60000`: no container
  terminated, and every pod logged `Recovered Redis connection` instead of
  exiting. n8n's own counter showed the predicted quantum on live AWS (samples
  18.1s, 29.1s, 40.1s, gaps of 11.1s and 11.0s), so a 30s threshold would have
  exited about 11 seconds before recovery. The real endpoint stayed stale for
  **48 seconds**, roughly double the worst case modelled locally, because
  CoreDNS caching and the endpoint TTL stretch the window past the promotion
  itself. 60000 cleared that with ~20s of headroom, from one observed failover,
  so the README presents it as a good default rather than a guarantee.

- `redis_transit_encryption_enabled` input (default `false`) puts the
  ElastiCache queue backend behind TLS and an AUTH token. The default preserves
  the module's network-trust posture, Redis in private subnets behind a
  VPC-only security group, so callers who leave it alone get no plan diff at
  all. Callers who want credential-based Redis security flip one switch instead
  of forking the module. Resolves
  [#41](https://github.com/n8n-io/terraform-aws-n8n/issues/41).

  It shares the `aws_elasticache_replication_group` that
  `redis_high_availability_enabled` introduced, for an unrelated reason:
  `auth_token` does not exist on `aws_elasticache_cluster`, and AWS further
  requires transit encryption to be on before AUTH can be enabled at all. So
  **either** variable alone is enough to move a deployment off the default
  cluster resource, and the two are independent once there: encryption leaves
  the cache single-node, and availability leaves the endpoint plaintext. All
  four combinations are pinned by tests, and the both-on combination is
  confirmed on a live cluster.

  Because both features land on one resource with one identifier
  (`<cluster_name>-redis-rg`), enabling the second one later plans as a
  modification of the replication group already in place rather than a
  replacement. The encrypted-to-HA direction was verified live and exposed a
  staged provider workflow: the first apply raises the node count through
  `IncreaseReplicaCount` and returns with automatic failover still disabled. A
  fresh plan and apply enables failover; with `redis_apply_immediately = false`
  that second change waits for the maintenance window, while `true` activates
  it immediately. The README now documents the full sequence. After activation,
  a forced failover promoted the replica in 22 seconds, authenticated Redis
  probes recovered after approximately 26 to 31 seconds, `/healthz` stayed
  available, and all n8n pods kept their UIDs with zero restarts at a 60,000 ms
  reconnect threshold.

- `redis_transit_encryption_mode` (default `"required"`) and
  `redis_apply_immediately` (default `false`) make **adding TLS to an existing
  replication group** a supported migration rather than a failed apply. AWS
  refuses a direct plaintext-to-encrypted transition and refuses an AUTH token
  until the mode is `required`, so `redis_transit_encryption_enabled` on its own
  plans clean and then fails. `preferred` accepts TLS and plaintext on the same
  endpoint, which is what makes the transition rideable.

  Both defaults preserve existing behaviour exactly. `apply_immediately` is
  written as `null` rather than `false` so no deployment already on a
  replication group sees a plan diff, and `"required"` is what a first-time
  create wants, so TLS and the token still arrive together in one apply.

  The three-step migration was run end to end against a live ElastiCache
  replication group with a client connection held open throughout, and **no step
  interrupted service**: `preferred` took 17m27s with 1198 consecutive replies
  on the held-open plaintext connection and zero errors; `required` took 8m18s
  in a single Terraform apply, closing plaintext 131 seconds in, by which point
  the pods were already on TLS; the final token rotation took seconds. Step
  three is not optional, because ElastiCache introduces a first token with its
  `ROTATE` strategy and that keeps the previous credential valid, which for a
  group that had no token means unauthenticated connections keep working until a
  second rotation. See README → "Adding TLS to an existing replication group"
  for the sequence and the measurements.

  The module generates no AUTH token, publishes no Secret and sets no
  `passwordFromEnv` on the KEDA triggers while the mode is `preferred`, matching
  what AWS will accept. A `check` block warns on every apply for as long as a
  deployment stays there, since `preferred` leaves Redis reachable unencrypted
  and unauthenticated from anywhere in the VPC.

  **Enabling this on a default deployment replaces Redis**, since the cluster
  and the replication group are different resource types. Every job queued at
  that moment is lost. Drain workers and pick a maintenance window. Upgrading
  the module *without* touching the variable does **not** replace anything: the
  `moved` block in `refactoring.tf` absorbs the `count` on
  `aws_elasticache_cluster.n8n`.

  The generated token respects ElastiCache's constraints (16-128 chars, with
  `! & # $ ^ < > -` the only permitted non-alphanumerics) and is published two
  ways: as a Kubernetes secret the chart mounts as `QUEUE_BULL_REDIS_PASSWORD`
  on main, worker and webhook processor, and as a new sensitive
  `redis_auth_token` output (`terraform output -raw redis_auth_token`).

  Everything above describes the module-managed path. `create_elasticache =
  false` was initially rejected outright alongside this flag, on the grounds that
  the module cannot put a token on a Redis it does not manage: true, but it left
  a caller with their own TLS-only or authenticated Redis unable to use the BYO
  hook at all. Later in this same release the external path gained its own
  meaning for this flag plus a `redis_auth_token` input; see the
  `redis_transit_encryption_enabled` / `redis_auth_token` entry above for what it
  does there.

- **Worker autoscaling follows the encryption flag.** Both KEDA Redis triggers
  gain `enableTLS` and `passwordFromEnv: QUEUE_BULL_REDIS_PASSWORD` when
  `redis_transit_encryption_enabled` is on, so queue-depth scaling keeps working
  against the encrypted backend. TLS is the half that has to land: without it
  KEDA opens a plaintext connection to a TLS-only endpoint and hangs on
  `connection to redis failed: i/o timeout` before authentication is ever
  attempted, so credentials alone would read as no fix at all. Nothing crashes
  to announce it either, the HPA just reports `<unknown>` and workers freeze at
  their current replica count. `passwordFromEnv` names an environment variable
  rather than carrying the token, and KEDA resolves it against the worker pod's
  first container (`n8n-worker`), which the chart already gives the token to via
  `secretKeyRef`. So nothing sensitive is written into the ScaledObject and no
  `TriggerAuthentication` resource is required. This relies on KEDA being
  permitted to read Secrets outside its own namespace, which its chart allows by
  default; installing KEDA with `KEDA_RESTRICT_SECRET_ACCESS=true` would stall
  queue-depth scaling. Resolves
  [#66](https://github.com/n8n-io/terraform-aws-n8n/issues/66).

  Verified on a live cluster against KEDA 2.20.2, since none of this is visible
  to a plan-time test. The ScaledObject reported `READY=True` with the HPA
  reading a numeric `0/2 (avg), 0/2 (avg)` where the same deployment previously
  reported `READY=False` and `<unknown>`, and the operator log carried no
  timeout or auth errors. Driving the queue to 20 scaled workers from 2 to the
  maximum of 6 in about 55 seconds, and clearing it returned them to 2. The AUTH
  token appeared nowhere in the rendered ScaledObject.

- `redis_high_availability_enabled` input (default `false`) provisions Redis as
  a two-node `aws_elasticache_replication_group` (one primary, one replica,
  `automatic_failover_enabled` and `multi_az_enabled`) instead of the
  single-node `aws_elasticache_cluster` the module has always created. Redis
  backs the Bull queue that distributes executions across workers and the
  multi-main leader election, so the default single node is a single point of
  failure for both: a node or AZ event stalls executions and leader election
  until ElastiCache replaces it. Both nodes use `redis_node_type`, so the Redis
  cost roughly doubles.

  What this buys is durability of the queue, not an invisible failover, and the
  distinction was measured rather than assumed. A forced failover on a live
  cluster promoted the replica in about 20 seconds and left the queued
  executions intact on the promoted node, but **every main, worker and webhook
  pod exited and restarted** while it happened: n8n's `RedisClientService`
  calls `process.exit` once Redis has been unreachable for
  `QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD`. Raising that threshold to 30s was tried
  and still fell short of this failover, so this release leaves n8n's default
  alone; a larger reconnect budget can ride the failover out, and wiring the
  threshold up is the follow-up in
  [#77](https://github.com/n8n-io/terraform-aws-n8n/pull/77). Recovery is
  automatic and completed inside a minute. Compare with the
  single-node default, where losing the node means waiting for AWS to build a
  replacement and the queue is gone with it.

  Upgrade note: **flipping this on an existing deployment replaces Redis.** The
  two topologies are different resource types, so no `moved` block can bridge
  them; Terraform destroys the cluster and creates the replication group, and
  everything queued or in flight goes with it. The replication group also
  carries a deliberately distinct identifier (`<cluster_name>-redis-rg`),
  because ElastiCache shares one identifier namespace between cache clusters
  and replication groups and rejects a second resource reusing the name. With
  a shared name the flip would destroy the old cache and then fail to create
  the replacement, leaving no queue backend at all. See README → "Redis high
  availability" for the drain-first procedure. Resolves part of
  [issue #44](https://github.com/n8n-io/terraform-aws-n8n/issues/44).

- `create_elasticache` (default `true`), `redis_host`, and `redis_port` inputs
  mirror the existing `create_database` / `db_host` hook for the Redis tier.
  With `create_elasticache = false` the module creates no ElastiCache cluster,
  replication group, subnet group, or security group, and wires n8n and the
  KEDA queue-depth triggers at the supplied endpoint instead. This is the hook
  the cross-region HA/DR design presumes, so both regions can point at one
  shared, replication-capable Redis.

  As first written this hook wired host and port only, leaving an external Redis
  that required AUTH or TLS unsupported. That gap is closed later in this same
  release: `redis_transit_encryption_enabled` and `redis_auth_token` both apply on
  this path now (see their entry above), so a TLS-only or authenticated external
  Redis works. Two `check` blocks warn when the inputs and the toggle disagree,
  rather than silently discarding what was asked for.

  Still unsupported on this path: Redis 6+ ACL usernames. `redis_auth_token` is a
  password only, which is all ElastiCache AUTH tokens ever are, but a self-hosted
  Redis authenticating against a named ACL user needs a username too. The chart
  exposes `redis.username` for exactly this, so surfacing it would be a small
  additive input if someone needs it.

  Upgrade note: gating the Redis tier on `create_elasticache` adds `count` to
  `aws_elasticache_cluster.n8n`, `aws_elasticache_subnet_group.n8n`, and
  `aws_security_group.redis`, changing their addresses from `.n8n` to
  `.n8n[0]`. `moved` blocks in `refactoring.tf` absorb this, so upgrading on
  the default path is an in-place no-op, verified against a live 0.2.x
  deployment, not by inspection.

- `redis_port` output, paired with the existing `redis_endpoint`, so a caller
  wiring its own queue-depth scaler or a debug pod does not have to assume the
  port. `redis_endpoint` now reports the replication group's primary endpoint
  on the HA path and `var.redis_host` on the external path.

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
- All six examples also expose `n8n_image_repository`,
  `n8n_task_runner_image_tag`, `n8n_custom_extensions_path`, and
  `n8n_image_pull_secrets` as passthrough variables (defaults matching the
  module, same validation), so a custom image with baked-in nodes can be
  deployed from an example without editing its source. The image inputs travel
  together: a custom repository normally comes with a custom tag, a custom tag
  normally needs the runner tag pinned, and baked-in nodes need the extensions
  path set.
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
- `db_kms_key_arn` input (default `null`) lets a caller supply the ARN of an
  existing KMS key for RDS storage encryption, Performance Insights data, and
  the postgresql CloudWatch log group, instead of the module minting its own
  Customer Managed Key (`aws_kms_key.db`). For organizations with a security
  team that centrally owns all KMS keys and does not permit Terraform modules
  to create new ones, this was previously a hard blocker: the module's CMK was
  unconditional whenever `db_storage_encrypted = true` (the default), with no
  escape hatch.

  `aws_kms_key.db` and `aws_kms_alias.db` now gate on
  `var.create_database && var.db_storage_encrypted && var.db_kms_key_arn == null`,
  one more static, plan-time-known condition added to the ternary that was
  already there, not a change from an unconditional resource to a conditional
  one. `local.db_kms_key_arn` prefers `var.db_kms_key_arn` over
  `aws_kms_key.db[0].arn` when both could apply, and feeds `kms_key_id` on
  `aws_db_instance.n8n`, `performance_insights_kms_key_id`, and
  `aws_cloudwatch_log_group.rds_postgresql.kms_key_id` exactly as before. It is
  also gated on `var.db_storage_encrypted`, which keeps that flag the single
  switch deciding whether this module encrypts anything with a CMK: without the
  gate a supplied key still reached the log group while
  `db_storage_encrypted = false`, contradicting both that resource's
  null-passthrough contract and the `check` block below. A `validation` block
  requires the value to look like a KMS key ARN
  (`arn:aws:kms:<region>:<account-id>:key/<key-id>`), rejecting an alias ARN or
  a malformed string at plan time. A new `check` block,
  `db_kms_key_arn_requires_module_managed_encrypted_database`, warns (does not
  fail) when `db_kms_key_arn` is set alongside `create_database = false` or
  `db_storage_encrypted = false`, where it would be silently ignored.

  **The supplied key's policy must grant the regional CloudWatch Logs service
  principal `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`,
  `kms:GenerateDataKey*` and `kms:DescribeKey`, or the apply fails.** RDS reaches
  the key through a grant, so storage and Performance Insights need nothing
  beyond the default root statement, but CloudWatch Logs rejects
  `CreateLogGroup` against a key it cannot use, with
  `InvalidParameterException`, and it fails there, before the RDS instance is
  created, leaving a half-built stack. This cannot be caught at plan time: no
  AWS provider data source returns a key policy, so there is no `check` block to
  write. README.md → "Bring your own KMS key for RDS" carries the exact
  statement to add, which is the `AllowCloudWatchLogsEncrypt` statement the
  module puts on its own CMK.

  Left at its default `null`, behavior is unchanged: the module still creates
  its own CMK exactly as before. No `moved` block was needed: verified by
  planning both the pre-change and post-change code against identical default
  variables (mock providers, `terraform test`) and confirming both plans
  propose creating `aws_kms_key.db[0]` and `aws_kms_alias.db[0]` at the same
  addresses with the same action; the added condition only changes the
  expression's value when `db_kms_key_arn` is actually set, which no existing
  deployment can do since the input did not previously exist. This was
  validated at plan time only, against mocked providers; no real AWS apply was
  performed.

- **Default S3 server-side encryption.** `aws_s3_bucket_server_side_encryption_configuration.n8n`
  is a genuinely new resource: the module-managed bucket previously had no
  server-side encryption configuration at all (`grep -rn
  server_side_encryption` across the repo turned up nothing before this
  change). Defaults to SSE-KMS (`aws:kms`) with a module-created Customer
  Managed Key, driven by the new `s3_kms_encryption_enabled` input, which
  defaults to `true`. Set that input to `false` to fall back to SSE-S3
  (`AES256`, AWS-managed key) instead. `s3_kms_key_arn` is a separate input
  and does not choose the algorithm: it swaps a key you already own in for
  the module-created CMK on a bucket that is SSE-KMS either way. Supplying it
  skips `aws_kms_key.s3`, not this encryption configuration, which is still
  written and simply names your key.

  `s3_kms_key_arn` also adds a second statement to `aws_iam_policy.s3` granting
  the n8n Pod Identity role `kms:Decrypt`, `kms:GenerateDataKey` and
  `kms:DescribeKey`, scoped to that one key. SSE-KMS requires this of the
  *requesting* principal: S3 performs the crypto as the caller, so a `GetObject`
  needs `kms:Decrypt` and a `PutObject` needs `kms:GenerateDataKey`, and without
  it every n8n binary-data read and write returns `AccessDenied` while the
  bucket, its encryption configuration and the S3 half of the IAM policy all read
  as correct. Because of that grant the input is meaningful on **both** bucket
  paths, including `create_s3_bucket = false`: the module does not encrypt a
  bucket it did not create, but it does have to be told which key that bucket is
  already encrypted with, and it cannot read the bucket's configuration to infer
  it. Anyone supplying an SSE-KMS bucket via `existing_s3_bucket_name` must set
  `s3_kms_key_arn` too. The `validation` block accepts key ARNs only, not alias
  ARNs, since an IAM policy `Resource` element cannot reference a KMS alias and a
  grant written against one would silently match nothing. Not verified against a real upgrade of a live
  deployment (no live cluster was available for this change); the plan-time
  test suite confirms the resource plans cleanly and that no other S3 resource
  changes shape as a result of adding it. Since the resource is new rather than
  a change to an existing one's arguments, it should attach without touching
  the existing bucket, but treat that as reasoning rather than a measured
  upgrade result until verified on a real cluster.

- **Bring your own S3 bucket.** `create_s3_bucket` input (default `true`,
  mirroring `create_database`) and `existing_s3_bucket_name` input (required
  when `create_s3_bucket = false`) let a caller point n8n at an S3 bucket they
  already manage instead of the module creating one. With
  `create_s3_bucket = false` the module creates no `aws_s3_bucket`, no
  `aws_s3_bucket_public_access_block`, and no server-side encryption
  configuration (the supplied bucket is the caller's to secure) but still
  attaches `aws_iam_policy.s3` and the `aws_iam_role.s3` Pod Identity
  association to the bucket's ARN, so the `n8n-enterprise` service account can
  read and write it exactly as it would a module-managed bucket. The
  `s3_bucket_name` output and `local.s3_bucket_name` (consumed by the Helm
  release's `s3.bucket.name` value in `n8n.tf`) both resolve to whichever
  bucket is actually in play.

  The input is named `existing_s3_bucket_name` rather than `s3_bucket_name` to
  avoid reading as the same name as the pre-existing `s3_bucket_name` output:
  Terraform's input and output namespaces don't collide, but the two would be
  easy to confuse in a caller's `tfvars`, the same reasoning that keeps
  `db_host` distinct from the `rds_endpoint` output.

  `aws_s3_bucket.n8n` and `aws_s3_bucket_public_access_block.n8n` moved from
  unconditional to `count`-gated, changing their state address from `.n8n` to
  `.n8n[0]` for every deployment left at the default `create_s3_bucket = true`.
  `moved` blocks in `refactoring.tf` cover both, following the same pattern as
  `create_database`'s existing blocks for `aws_db_subnet_group.n8n` and
  `aws_db_instance.n8n`.

  A plan-time `check` block,
  `existing_s3_bucket_name_requires_create_s3_bucket_false`, warns (without
  failing) when `existing_s3_bucket_name` is set while `create_s3_bucket = true`,
  where the module creates its own bucket and the supplied name is ignored. There
  is deliberately no equivalent check for `s3_kms_key_arn` alongside
  `create_s3_bucket = false`: that combination is now the supported way to use a
  caller-supplied SSE-KMS bucket, so warning on it would steer people away from
  the one setting that makes their deployment work. The inverse (an SSE-KMS
  bucket supplied with no `s3_kms_key_arn`) is the remaining footgun and is not
  checkable, since the module would have to read the bucket's encryption
  configuration through a data source, adding an AWS call at plan time and a hard
  failure for anyone whose credentials cannot read it.

- `iam_permissions_boundary_arn` input (default `null`) sets
  `permissions_boundary` on every IAM role this module creates:
  `aws_iam_role.cluster` and `aws_iam_role.nodes` (`eks.tf`),
  `aws_iam_role.s3` (`s3.tf`), `aws_iam_role.lbc`,
  `aws_iam_role.cluster_autoscaler`, `aws_iam_role.ebs_csi` (`iam.tf`), and
  `aws_iam_role.rds_enhanced_monitoring` (`database.tf`, which exists only when
  `create_database = true`). Seven roles in total; in an account whose SCP
  enforces a boundary, missing any single one is enough to fail the whole apply.
  Many organizations enforce an SCP or IAM policy requiring every role created
  in-account to carry a permissions boundary, and without this input those
  accounts could not use the module at all. Validated against the shape of an
  IAM policy ARN (`arn:aws:iam::<account-id>:policy/...`) so a typo fails at
  plan time rather than surfacing as an opaque `AccessDenied` on `CreateRole`.

  `permissions_boundary = null` is a documented no-op in the AWS provider (the
  argument is simply omitted from the API call), so every role takes the
  argument unconditionally with no `count` or conditional gating, and the
  default leaves every role exactly as boundary-less as before this input
  existed: no diff for existing deployments.

  Verified at plan time only: `terraform test` asserts
  `permissions_boundary` is `null` on all seven roles by default and equal to a
  supplied ARN on all seven when set, and that an ARN failing the regex is
  rejected by the variable's `validation` block. Those runs enumerate the roles by
  hand, which is a known weakness: Terraform's test language cannot enumerate
  resources, so a role added later and left unwired would keep the suite green.
  `grep -c 'resource "aws_iam_role"' *.tf` is the manual check, and it must equal
  seven. This has **not** been
  applied against a real AWS account with an enforced permissions-boundary
  SCP; that is the one behavior a mocked plan cannot exercise (the mock `aws`
  provider does not model boundary enforcement or denial), so treat this as
  confirmed wiring rather than a confirmed unblock. Anyone adopting this in an
  SCP-enforced account should run a real `terraform plan`/`apply` against that
  account before relying on it.

- `db_logs_kms_key_arn` input (default `null`) encrypts the `postgresql`
  CloudWatch log group when `db_kms_key_arn` is supplied. It exists because
  the module cannot verify that a caller-supplied key's policy lets
  CloudWatch Logs use it; setting this input is the caller asserting that it
  does, and it can name a different key their organization has already
  blessed for logs. Ignored, with a `check` block saying so, whenever
  `db_kms_key_arn` is `null`, because on that path the module created the CMK
  and wrote the CloudWatch Logs statement onto it itself. See the
  corresponding entry under Fixed.

- `redis_username` input (default `null`) authenticates against a named
  Redis 6+ ACL user on an external Redis, passed through to the chart's
  `redis.username`. `redis_auth_token` supplies a password only, which is all
  an ElastiCache AUTH token ever is, so a self-hosted Redis that
  authenticates against a named user could not be reached through the
  bring-your-own hook even with the token input available. Relevant only when
  `create_elasticache = false`; a `check` block warns when it is set on the
  module-managed path, where ElastiCache AUTH has no username concept.

  Queue-depth autoscaling survives it. KEDA's Redis scaler declares its
  `Username` field with
  `keda:"name=username, order=triggerMetadata;resolvedEnv;authParams"`, so
  the module wires the username into the `ScaledObject` trigger metadata
  alongside the existing TLS and password-from-env settings. n8n reads
  `QUEUE_BULL_REDIS_USERNAME` in
  `packages/@n8n/config/src/configs/scaling-mode.config.ts`, which notes that
  Redis 6.0 or higher is required.

- `db_snapshot_identifier` input (default `null`) stands the module-managed
  database up from an existing RDS snapshot instead of creating an empty one.
  It is the other half of `n8n_encryption_key`: that input exists so a
  rebuilt stack can decrypt the credentials an existing database already
  holds, yet the only way to reach that state was
  `create_database = false`, which gives up the module's management of the
  subnet group, security group, CMK, log group retention, Enhanced
  Monitoring and Performance Insights. Ignored, with a `check` block, when
  `create_database = false`.

  Four behaviours govern whether a restore works, three verified against the
  `RestoreDBInstanceFromDBSnapshot` API reference and one against the
  provider source, and all but the last are now checked at plan time by
  describing the snapshot with `data.aws_db_snapshot`:

  - **`snapshot_identifier` is `ForceNew`.** Setting it on a deployment that
    already has a database destroys that database and restores the snapshot
    in its place. It is for standing up a fresh stack around existing data,
    not for reloading a running one.
  - **Encryption comes from the snapshot and cannot be set while restoring**,
    and both `storage_encrypted` and `kms_key_id` are `ForceNew`. A
    configuration that disagrees does not fail once: Terraform wants to
    replace the instance on every apply and can never reconcile. So the
    inputs have to describe the snapshot. An unencrypted snapshot needs
    `db_storage_encrypted = false`; an encrypted one needs `db_kms_key_arn`
    set to the snapshot's own key, since a module-created CMK can never match
    a snapshot that predates it. The key is compared on its UUID rather than
    by whole-string equality, because a snapshot's `kms_key_id` can come back
    as either the full ARN or the bare ID and a false mismatch would be worse
    than no check.
  - **The engine must be `postgres`** and `db_allocated_storage` must be at
    least the snapshot's size, which AWS requires or the restore fails.
  - **RDS ignores `DBName` when restoring PostgreSQL** ("This parameter only
    applies to RDS for Oracle and RDS for SQL Server DB instances"), so the
    restored database keeps its own name while this module sets
    `n8n_enterprise`, and `db_name` is `ForceNew` too. No data source exposes
    a snapshot's database name, so this one is documented rather than
    checked: restore from a snapshot taken of a module-managed instance.

  The master password does apply, despite the restore API taking no password
  parameter: the AWS provider issues a `ModifyDBInstance` with
  `MasterUserPassword` immediately afterwards. Worth re-checking on a
  provider major bump, because n8n silently cannot connect if that ever
  changes.

  A further `check` warns when `db_snapshot_identifier` is set and
  `n8n_encryption_key` is not. That combination is the one restore mistake
  neither Terraform nor AWS can see: the apply succeeds, the workflows come
  back, and every credential in them is unreadable, because n8n encrypted
  them under the key of the instance the snapshot was taken from. It stays a
  warning rather than an error, since restoring for the workflow data while
  treating the credentials as disposable is a legitimate thing to want.

- **Four inputs for the n8n defaults that are scheduled to change.** n8n prints
  a deprecation warning on every pod start for four settings whose defaults it
  intends to move in a future version. The warnings fire because nothing sets
  them, not because setting them is wrong: n8n is asking operators to pin
  today's value before it changes.

  `n8n_task_runner_timeout` (default `300`) maps to
  `N8N_RUNNERS_TASK_TIMEOUT` and is **emitted unconditionally**, which is the
  one place this group departs from the module's usual omit-when-null
  convention. n8n has announced this default drops from 300 seconds to 60, and
  that change is a pure functional regression: nothing about a Code node task
  that runs for four minutes becomes unsafe when the ceiling drops, it simply
  starts failing, in a deployment where nothing changed but the n8n version.
  Since 300 is n8n's current default, pinning it changes nothing today. Set it
  to `60` to adopt n8n's future default early. Not to be confused with the
  existing `n8n_task_runner_request_timeout`, which governs how long n8n waits
  for a runner to *accept* a task rather than how long the task may then run;
  both descriptions now say so.

  `n8n_unverified_packages_enabled`,
  `n8n_compression_max_decompressed_size_bytes` and
  `n8n_compression_max_zip_entries` (all default `null`, env var omitted) map
  to the remaining three. These are deliberately **not** pinned. Each is n8n
  tightening a security posture rather than changing behaviour arbitrarily:
  unverified community packages, and two limits bounding what the Compression
  node will expand a hostile archive into. Freezing the permissive value on
  every deployment's behalf is not a decision this module should make, so it
  leaves them to n8n and exposes the lever for callers whose workflows
  genuinely need the larger limit.

  All four names are reserved against `n8n_extra_env`
  (`N8N_RUNNERS_TASK_TIMEOUT` via the existing `N8N_RUNNERS_` prefix, the other
  three by name), so an override there is rejected at plan time rather than
  silently unpinning the timeout or moving a limit with no input to show for
  it.

  Two other warnings on n8n's list are not the module's to fix, and are
  documented as expected rather than chased: `WEBHOOK_URL` is superseded by
  `N8N_WEBHOOK_URL`, but the chart writes `WEBHOOK_URL` itself from the ingress
  host and has no support for the successor, so the warning survives anything
  the module does; `N8N_AVAILABLE_BINARY_DATA_MODES` comes from the chart too.
  Both need an upstream chart change. Two further deprecations in that file do
  not fire here at all: the chart sets
  `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`, and
  `N8N_DEFAULT_BINARY_DATA_MODE` only warns on the literal value `default`,
  which this module never sets.

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

- **The licence key no longer reaches n8n through Helm values.**
  `license.activationKey` was set inline to `var.n8n_license_key`, so it was
  rendered into the Helm release values and stored in the release Secret
  in-cluster, on top of Terraform state. Every other credential the module
  handles (database password, Redis token, encryption key) already went
  through a `kubernetes_secret` and an `existingSecret` chart value; the
  license key was the exception. It is now a key in the existing
  `kubernetes_secret.n8n`, referenced by name. The task runner auth token
  stays a literal `taskRunners.authToken.value`, unchanged: it encrypts
  nothing, so moving it into a Secret would add a resource for no security
  benefit.

  The chart template is `if .Values.license.activationKey / else if
  .Values.license.existingSecret.name`, so `activationKey` had to be dropped
  rather than merely supplemented: sending both silently keeps the inline
  path.

  Verified by rendering chart 1.10.0, the version this module pins, with the
  exact value shape the module sends: `n8n-main`, `n8n-worker` and
  `n8n-webhook-processor` all resolve `N8N_LICENSE_ACTIVATION_KEY` through
  `secretKeyRef`, and no literal renders anywhere in the manifests.

  This does not remove the licence key from Terraform state: it is a module
  input either way, so it is in state regardless; what changes is that it
  stops being copied into the Helm release as well. Callers see a pod
  restart on the next apply.

### Security

- checkov now runs with `soft_fail: false` in CI (`.github/workflows/terraform-tests.yml`):
  every finding is curated instead of silently absorbed. Resolves
  [#27](https://github.com/n8n-io/terraform-aws-n8n/issues/27). Highlights:

  - EKS control-plane logging is now enabled for all five log types
    (`aws_eks_cluster.n8n.enabled_cluster_log_types`), writing to an
    explicit, retained CloudWatch log group instead of nothing.
  - EKS Kubernetes Secrets are now envelope-encrypted with a module-created
    KMS CMK by default (new `var.eks_secrets_encryption_enabled`, defaults
    `true`). This is a real infrastructure change with an ongoing KMS cost;
    set the variable to `false` to preserve unencrypted behavior on an
    existing cluster before the first apply. The supported AWS provider adds
    encryption to a live unencrypted cluster in place; disabling it afterwards
    forces replacement because EKS cannot disassociate an encryption config.
  - EKS API endpoint access is now configurable (new
    `var.cluster_endpoint_public_access`,
    `var.cluster_endpoint_public_access_cidrs`,
    `var.cluster_endpoint_private_access`). Defaults preserve the existing
    public-endpoint, unrestricted-CIDR posture.
  - The Cluster Autoscaler IAM policy's write actions
    (`SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup`) are now
    scoped with a `ResourceTag` condition to this cluster's own node group
    ASGs, instead of an unconditional `Resource = "*"`.
  - ElastiCache Redis now takes a daily automatic snapshot by default (new
    `var.redis_snapshot_retention_limit`, defaults `1`). Set on both Redis
    topologies, so opting into `redis_high_availability_enabled` or
    `redis_transit_encryption_enabled` or `redis_kms_encryption_enabled` does
    not silently drop the snapshot the default single-node cluster takes.
  - The S3 bucket's default encryption is now SSE-KMS with a module-created
    CMK, with S3 Bucket Keys enabled so KMS is called per bucket rather than
    per object (new `var.s3_kms_encryption_enabled`, defaults `true`). The n8n
    pod role gains `kms:Decrypt` / `kms:GenerateDataKey` on that key, which
    SSE-KMS requires for every read and write. This selects which key
    encrypts objects, not whether they are encrypted: S3 encrypts everything
    regardless, and `false` leaves the bucket on SSE-S3. It applies to objects
    written afterwards, so existing objects keep the encryption they were
    written with. The bucket encryption resource waits for the pod role's KMS
    policy update before activating, avoiding an upgrade-time read/write race.
    Changing the toggle from `true` to `false` while old objects still use the
    CMK makes them immediately unreadable when KMS schedules key deletion.
  - The module can optionally attach a module-managed parameter group
    (`aws_db_parameter_group.n8n`) that logs DDL statements and queries slower
    than 1s, and sets `rds.force_ssl = 1` (`db_query_logging_enabled`, default
    `false`). Deliberately not
    `log_statement = all`, which would copy workflow and execution payloads
    into CloudWatch Logs. `rds.force_ssl = 1` is already the RDS default on
    PostgreSQL 15 and later, and n8n connects over TLS by default, so it
    changes nothing at the module's default `db_engine_version`. It defaults
    off because `engine_version` is ignored on existing state: a live
    PostgreSQL 16 instance may coexist with the configured 18.4 value, and RDS
    rejects a postgres18 parameter group on that instance. Enable it for a new
    deployment or after confirming the live major matches. Note that
    moving an existing instance from the default parameter group to a custom
    one takes effect only after a reboot, so these settings land in the next
    maintenance window rather than at apply time.
  - `examples/large` gains equivalent opt-in query logging for Aurora
    (`aurora_query_logging_enabled`, default `false`), split
    across two parameter groups because Aurora PostgreSQL requires it:
    `rds.force_ssl` exists only in the DB *cluster* parameter family, and
    `log_statement` / `log_min_duration_statement` only in the DB *instance*
    family (verified with
    `aws rds describe-engine-default-cluster-parameters --db-parameter-group-family aurora-postgresql18`,
    which lists neither of the latter two among its 142 parameters; the same
    holds for `aurora-postgresql16`). The opt-in default prevents an existing
    Aurora 16 cluster retained by `ignore_changes` from receiving incompatible
    Aurora 18 groups. When enabled, the example carries an
    `aws_rds_cluster_parameter_group` for the TLS setting and an
    `aws_db_parameter_group` attached to the writer and reader for the logging
    settings. Checkov's `CKV2_AWS_27` asks for the log parameters on the
    cluster group specifically, which is a configuration AWS rejects at apply
    with "Could not find parameter with name: log_statement", so that finding
    carries an annotated skip rather than a fix.
  - Security group egress rules (RDS, Redis, `examples/large` Aurora) now
    carry an explicit description.
  - `examples/large`'s `kubernetes_deployment.pgbouncer` now sets container
    resource requests/limits and a security context (dropped Linux
    capabilities, no privilege escalation).

  Findings that are intentional for this module's getting-started posture
  (permissive security group egress, the public EKS endpoint by default,
  the upstream-verbatim AWS Load Balancer Controller IAM policy, Terraform
  Registry module sources carrying a `version` constraint rather than a
  commit hash, S3 bucket versioning and lifecycle rules that would defeat
  n8n's own data pruning, cross-region replication and access logging that
  need buckets this module does not create, AWS Backup for the `examples/large`
  Aurora cluster and Multi-AZ automatic failover on the replication group's
  TLS-only shape)
  each carry an inline `checkov:skip=<ID>:<reason>` annotation at the resource
  that causes them. Two more are annotated because checkov reports them against
  a resource that is in fact configured correctly: it builds no graph edge
  between two `count`-expanded resources, so it cannot see the RDS instance's
  parameter group (`CKV2_AWS_30`) or the Redis security group's attachment to
  whichever cache topology is active (`CKV2_AWS_5`). Both skips record the
  experiment that isolated the artifact, which in each case is that deleting
  `count` from the one resource makes the finding disappear with nothing else
  changed. No check is suppressed repo-wide: the new `.checkov.yaml` sets only
  a `skip-path` for the `tests/` directories, so every check stays live on code
  added later. See the annotations themselves for the reasoning behind each
  one.

- The checkov version is now pinned (`CHECKOV_VERSION` in
  `.github/workflows/terraform-tests.yml`) and CI runs
  `tests/scripts/check-checkov.sh`, the same script contributors run, instead
  of `bridgecrewio/checkov-action`. The action bakes the checkov version into
  its own image, so its `@v12` tag moved to a newer checkov on its own
  schedule. That is not theoretical: 3.3.9 evaluates whole check families
  (every `aws_s3_bucket` check, several `CKV2_*` graph checks) against
  resources reached through a local module source that 3.3.0 skipped silently,
  which is how a clean local run became ten CI failures. The script now
  refuses to run against a version other than the pinned one, so a local pass
  and a CI pass mean the same thing. Bumping the pin is a deliberate change
  that curates whatever the new release reports. `task checkov` runs the same
  script, and the `task ci` description no longer claims checkov is
  soft-failed.

  The `terraform-docs` pin in the same workflow had drifted the same way: it
  sat at `v0.22.0` while the `brew` default its comment tracks had moved to
  `v0.24.0`. It is now realigned. That drift happened to be harmless, because
  the two versions render this repo's tables identically, but it was the same
  trap one release away from producing spurious README diffs.

- New `var.cluster_endpoint_public_access_cidrs` rejects a malformed CIDR and
  an empty list at plan time, and `var.cluster_endpoint_private_access`
  rejects the both-endpoints-disabled combination that EKS would refuse
  minutes into an apply.

- `variables.tf` gains two banner sections, `EKS cluster` (API server endpoint
  access and Secrets encryption) and `S3` (bucket encryption), both recorded in
  AGENTS.md's banner table. The four EKS inputs sit in their own section rather
  than under `Foundation inputs`, which covers infrastructure the caller
  supplies rather than control-plane properties the module owns.

### Added

- `n8n_license_key_secret_ref`, `db_password_secret_ref`,
  `redis_auth_token_secret_ref` and `n8n_encryption_key_secret_ref` inputs.
  Each is its value-input counterpart plus `_secret_ref`, and takes
  `{name, key}` (key optional, defaulting per credential) naming a Kubernetes
  Secret the caller already manages, e.g. one synced by External Secrets
  Operator, instead of a raw value the module has to put in Terraform state on
  the way through. The module never reads the referenced Secret's contents: it
  only wires the chart's `existingSecret` / `passwordSecret` value at the name
  and key given, so the credential never reaches Terraform state through this
  path. Null by default on all four, so leaving them unset is a no-op for
  every existing deployment. The task runner auth token has no equivalent
  input: it encrypts nothing and matches no external system, so there is
  nothing a caller-supplied value or Secret reference would add; the module
  always generates it, unchanged from before this release.

  The mechanism differs by credential, and getting it backwards was the
  likeliest way to break this on a first pass. `db_password_secret_ref` and
  `redis_auth_token_secret_ref` gate `kubernetes_secret.n8n_db` /
  `kubernetes_secret.n8n_redis` to zero; both are rejected at plan time with
  `create_database = true` / `create_elasticache = true`, since
  `aws_db_instance.n8n` (`database.tf:374`) and
  `aws_elasticache_replication_group.n8n` (`redis.tf:190`) need the
  credential's actual value to provision that infrastructure, which a Secret
  name cannot supply. `kubernetes_secret.n8n` is shared with configuration the
  module still computes (`N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`, `WEBHOOK_URL`),
  so `n8n_license_key_secret_ref` drops its one key from that Secret's `data`
  instead of gating the resource; the Secret itself keeps existing on that
  path.

  `n8n_encryption_key_secret_ref` is the exception to that: the chart's
  `secretRefs.existingSecret` names a single Secret that `n8n.coreSecretsEnv`
  reads all four of `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT` and
  `N8N_PROTOCOL` from, so setting it replaces `kubernetes_secret.n8n` entirely.
  That leaves the license key with nowhere to live unless it is also supplied
  through `n8n_license_key_secret_ref`, so the module requires it whenever
  `n8n_encryption_key_secret_ref` is set, and rejects the plan otherwise. The
  task runner auth token is unaffected, since it never lived in
  `kubernetes_secret.n8n` to begin with. See README.md → "Consuming a Secret
  you already manage instead" for the full mechanism and a worked
  `ExternalSecret` example covering the four-key contract.

  Setting a `*_secret_ref` input alongside its value counterpart is rejected at
  plan time, naming both inputs, rather than one silently winning the way the
  chart's `license.activationKey` precedence rule already did once before (see
  Finding 1 above). `db_password_secret_ref` and `redis_auth_token_secret_ref`
  gained `moved` blocks in `refactoring.tf` for `kubernetes_secret.n8n_db` and
  `kubernetes_secret.n8n`, both of which carried no `count` before this change
  and therefore change address for every deployment that leaves both inputs
  null; `kubernetes_secret.n8n_redis` needed no equivalent block, since it was
  already `count`-gated on `local.redis_auth_active` and only gained a second,
  narrower condition.

  The module does not verify that a referenced Secret exists or carries the
  expected key: reading it to check would put the credential back in Terraform
  state, which defeats the reason this input exists. A typo surfaces only as a
  pod stuck in `CreateContainerConfigError`, not as a Terraform error.

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
  chart's own default applies (currently the floating `stable` tag), so existing
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
- Route 53 path: end-to-end automation, pass `route53_zone_id` and the
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
