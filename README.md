# terraform-aws-n8n

Terraform module for deploying [n8n](https://n8n.io) on AWS.

Deploys the production-grade multi-main setup: multiple n8n main instances, dedicated worker pods, external PostgreSQL (RDS), Redis (ElastiCache), and S3 for shared file storage. An **n8n Enterprise license is required**.

The module expects a pre-existing VPC. If your parent domain is hosted in Route 53, pass `route53_zone_id` and the module issues the ACM certificate and creates the DNS alias record itself. A single `terraform apply` brings up n8n end to end with no manual DNS steps. If your DNS is elsewhere, pass a pre-validated `certificate_arn` instead.

> **Pre-release module**
>
> The `terraform-aws-n8n` module is in pre-release. Expect breaking changes at any time before the first stable release.

## Architecture

![n8n on AWS architecture: users and webhook apps reach an Application Load Balancer that fronts an EKS cluster running separate main, webhook-processor, and worker pods, with RDS PostgreSQL, ElastiCache Redis, and S3 as managed backing services](docs/images/architecture.png)

Users and inbound webhooks hit an Application Load Balancer (managed by the AWS Load Balancer Controller) that fronts the EKS cluster. Inside the cluster the n8n Helm chart runs three separate deployments: main instance pods (leader election, UI/editor, REST API), webhook processor pods for inbound triggers, and worker pods that run job executions and scale on Redis queue depth via KEDA. State lives in managed services outside the cluster: RDS PostgreSQL for workflow state, ElastiCache Redis for leader election and the worker queue, and S3 for binary data. ACM issues the TLS certificate for the ALB. The cluster
also ships the EBS CSI driver and a default encrypted `gp3` StorageClass, so
PersistentVolumeClaims from workloads deployed beside n8n bind out of the box
(n8n itself needs no volumes).

In this multi-main topology, `n8n_license_detach_floating_on_shutdown`
defaults to `false`, overriding n8n's own upstream default, so a rolling
restart of the main pods cannot crash-loop the fleet by zeroing the shared
floating license cert. See
[docs/troubleshooting.md](docs/troubleshooting.md#multi-main-crash-loops-after-a-rolling-restart-helm-stuck-in-pending-rollback)
for the failure mode this avoids and how to recover if you hit it anyway.

## Usage

```hcl
module "n8n" {
  source  = "n8n-io/n8n/aws"
  version = "~> 0.2.0"

  aws_region      = "us-east-1"
  cluster_name    = "n8n-cluster"
  n8n_domain      = "n8n.example.com"
  n8n_license_key = var.n8n_license_key

  # Pre-existing VPC — bring your own.
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block

  # EKS node group autoscaling bounds (defaults shown). Driven by Cluster
  # Autoscaler — see note below; you pay for `node_min` nodes 24/7.
  node_min = 3
  node_max = 6

  # DNS — set exactly one:
  # 1. Parent domain in Route53 → module handles ACM + alias record.
  route53_zone_id = "Z0123456789ABCDEFGHIJ"
  # 2. DNS elsewhere → bring your own pre-validated cert.
  # certificate_arn = aws_acm_certificate_validation.n8n.certificate_arn
}
```

The module declares `required_providers` but does **not** configure them. Callers must configure `aws`, `kubernetes`, and `helm` providers. `kubernetes` and `helm` are configured against the cluster this module creates — see [`examples/small/providers.tf`](./examples/small/providers.tf) for the standard wiring.

`node_min` and `node_max` are the EKS node group's autoscaling bounds. `node_min` is your steady-state floor — you pay for those nodes 24/7 even when idle. `node_max` is a hard ceiling: if peak workload needs more nodes than allowed, pods stay `Pending`. Defaults fit the `small` example only; see the Examples table for production sizing.

For a full end-to-end example including the VPC, see [`examples/small/`](./examples/small/) (Route 53), [`examples/cloudflare/`](./examples/cloudflare/), or [`examples/godaddy/`](./examples/godaddy/). If `terraform apply` fails on a `helm_release` (most often due to a Helm 4 cache layout issue or a webhook race on first install), see [`docs/troubleshooting.md`](./docs/troubleshooting.md).

## Support

This module is open source software, maintained by the n8n Solutions team independently of n8n's enterprise products. While the n8n Support team provides dedicated support for the enterprise offerings, this module isn't included.

**Bug reports and feature requests:** open a [GitHub issue](https://github.com/n8n-io/terraform-aws-n8n/issues). We triage on a best-effort basis; there is no SLA.

**Security issues:** see [`SECURITY.md`](./SECURITY.md) for the disclosure process. **Do not** open public issues for security findings.

**General n8n questions** (not specific to this module): use the [n8n community forum](https://community.n8n.io/).

## Stability & versioning

This module is pre-1.0. We use minor versions (0.1, 0.2, …) as the
breaking-change boundary and patches (0.1.0, 0.1.1, …) for additive or
bug-fix changes.

| Across | What may change |
| ------ | --------------- |
| `0.MINOR.PATCH` → `0.MINOR.PATCH+1` | Bug fixes, new optional inputs, new outputs, new resources whose absence wouldn't affect existing callers. No removed or renamed inputs/outputs. No changed defaults that move infra. No changed resource addresses. |
| `0.MINOR` → `0.MINOR+1` | Anything else, including removed inputs, renamed inputs, default changes that force resource replacement, refactored resource addresses, and bumped provider version floors. Each such change is called out in [`CHANGELOG.md`](./CHANGELOG.md) with an upgrade note. |

Pin with `version = "~> 0.2.0"` to auto-receive 0.2.x patches without
accidentally crossing a 0.2 → 0.3 boundary. Note the three-component
constraint: `~> 0.2.0` resolves to `>= 0.2.0, < 0.3.0`, whereas the
two-component `~> 0.2` would resolve to `>= 0.2, < 1.0` and let you cross
minor boundaries unintentionally. To upgrade across minor lines, retype
the constraint (e.g. `version = "~> 0.3.0"`) and read the release notes.

This contract goes away at 1.0.0 in favor of standard SemVer.

### Compatibility

This module ships against specific provider majors. Notably:

- **AWS provider:** `~> 6.0`. Upgrading from a v0.1.x deployment (which
  pinned `aws ~> 5.0`) requires a one-time `terraform plan -refresh-only`
  followed by `terraform apply -refresh-only` to settle AWS provider 6.0's
  per-resource `region` attribute into state before applying other changes.
  Callers who must stay on AWS provider 5.x should pin this module to `~> 0.1.0`.
- **Helm provider:** `~> 3.0`. The 3.x release is a Plugin Framework
  rewrite; `helm_release` drift detection is stricter, so the first
  `terraform plan` after upgrading from v0.1.x may show in-place diffs on
  existing releases. Callers who must stay on Helm provider 2.x should pin
  this module to `~> 0.1.0`.
- **Kubernetes provider:** `~> 2.0`.
- **Terraform CLI:** `>= 1.9`.
- **n8n Helm chart:** default `1.10.0`. Other chart versions can be
  selected via `n8n_chart_version`.
- **n8n application image:** defaults to the chart's floating `stable` tag; production deployments should pin a  specific version via `n8n_image_tag` (e.g. `"1.2.3"`) to avoid crossing major-version boundaries on an unplanned pod reschedule.
- **EKS:** validated on Kubernetes `1.35`.
- **PostgreSQL:** validated on RDS `16.9`.

## Out of scope

v0.2.0 intentionally does not cover the following. Each item is
documented here so that issues filed against them can be triaged
quickly; several are candidates for future minor releases (see
[`ROADMAP.md`](./ROADMAP.md)).

- **VPC creation.** The module requires a pre-existing VPC with both
  public and private subnets tagged for EKS/ALB. The examples
  provision one with `terraform-aws-modules/vpc/aws`, but that VPC is
  *not* managed by this module. Rationale: VPCs are
  organization-shaped, not service-shaped.

- **Multi-region / cross-region deployments.** One module instance =
  one region = one EKS cluster = one n8n deployment. Cross-region
  replication of the database or S3 binary storage is the caller's
  problem. Rationale: pre-1.0 surface area; AWS provider 6.x's
  per-resource `region` argument is the natural foundation for this
  in a future minor.

- **GovCloud, AWS China, and Outposts.** The module uses generic AWS
  APIs that *probably* work in these partitions, but it has not been
  validated. Endpoint differences (e.g. EKS Pod Identity GA dates per
  region) may break things.

- **Air-gapped / private-image deployments.** The module pulls images
  from public registries: the n8n chart from `ghcr.io/n8n-io`, plus
  KEDA / Cluster Autoscaler / AWS Load Balancer Controller /
  metrics-server charts from their respective upstreams. Replacing
  all of these with ECR mirrors is possible but the module exposes
  no inputs for image-registry overrides today.

- **Backup/DR automation beyond RDS snapshots.** The module enables
  RDS automated backups (defaulting to RDS's own defaults). It does
  *not* automate restore drills, cross-region snapshot copy, S3
  versioning policy, or n8n encryption-key escrow. The
  `n8n_encryption_key` output is emitted exactly once at apply time;
  backing it up is the operator's job and is the single most
  important thing they will forget.

- **Bundled observability.** The module installs KEDA (for worker
  autoscaling) and metrics-server (for HPA on mains/webhooks) because
  they are load-bearing for the autoscaling story. It does *not*
  install Prometheus, Grafana, Loki, OpenSearch, Datadog Agent, or
  any log shipper. `n8n_metrics_enabled` exposes the metrics
  endpoint; scrape configuration is the caller's monitoring stack.
  Rationale: observability stacks are deeply opinionated per-org;
  bundling one is more harmful than helpful.

## Examples

Six runnable examples ship with the module: three sizing tiers (`small`, `medium`, `large`) on Route 53, two DNS-variant examples (`cloudflare`, `godaddy`) at `small` sizing, and one topology-variant example (`split-ingress`) at `small` sizing. Sizing decisions for `medium` and `large` are derived from internal load testing.

| Dimension | [small](./examples/small/) (default) | [medium](./examples/medium/) | [large](./examples/large/) |
|---|---|---|---|
| Target scale | Dev / small team | ~5–15M exec/day | ~50–60+M exec/day |
| Avg req/s | ~10–30 | ~60–175 | ~350–960 |
| Node type | t3.xlarge (4 vCPU, 16 GB) | m6i.2xlarge (8 vCPU, 32 GB) | m7i.4xlarge (16 vCPU, 64 GB) |
| Nodes desired / min / max | 3 / 3 / 6 | 5 / 5 / 15 | 10 / 10 / 50 |
| Total vCPU (desired) | 12 | 40 | 160 |
| Private subnets | 2× /24 (254 IPs each) | 2× /24 | 2× /20 (4,094 IPs each) |
| VPC CNI tuning | default | default | `WARM_ENI_TARGET=0` |
| Database | RDS db.t3.small (2 vCPU, 2 GB) | RDS db.m6g.2xlarge (8 vCPU, 32 GB) | Aurora PostgreSQL I/O-Optimized |
| DB instances | 1 writer (Multi-AZ standby) | 1 writer (Multi-AZ standby) | 1 writer + 1 reader |
| DB storage | 50 GB gp2 | 200 GB gp3 | Aurora auto-scales to 128 TB |
| DB IOPS ceiling | 150 baseline / 3,000 burst | 3,000 baseline (gp3) | None — I/O-Optimized |
| PgBouncer | No | No | Yes — 2 replicas |
| Redis | cache.t3.medium | cache.r6g.large | cache.r6g.large |
| Webhook pods min / max | 2 / 50 | 5 / 50 | 30 / 80 |
| Worker pods min / max | 1 / 10 | 5 / 40 | 20 / 160 |
| Worker concurrency | 10 | 20 | 40 |
| Execution concurrency limit | 100 | 200 | 2,000 |
| Webhook memory limit | 1 Gi | 2 Gi | 4 Gi |
| Webhook memory request | 512 Mi | 512 Mi | 1 Gi |
| Pruning retention | 10k records / 14 days | 500k records / 7 days | 5M records / 24h |
| Est. cost / month (on-demand) | ~$440 | ~$2,000 | ~$21,000+ |
| Est. cost / month (1-yr reserved) | ~$285 | ~$1,300 | ~$13,600 |

The DNS-variant examples (`cloudflare`, `godaddy`) are sizing-equivalent to `small` — they only swap the DNS provider for cert validation and the alias record.

[`split-ingress`](./examples/split-ingress/) is also sizing-equivalent to `small`. It swaps the *topology* rather than the DNS provider: `create_ingress = false`, an internet-facing ALB serving only the webhook path prefixes (optionally behind a WAF), and an internal ALB serving the editor UI and REST API. It is the runnable version of the pattern described in the next section.

## Bring your own Ingress (two-ALB split)

> A complete, runnable version of everything in this section, including the
> certificate, both alias records and a WAF hook, is at
> [`examples/split-ingress/`](./examples/split-ingress/).

By default the module creates a single internet-facing ALB Ingress that routes
`/webhook` to the webhook processors and `/` to the mains. Some deployments need
to split that: a public, internet-facing ALB for `/webhook` so external systems
can deliver triggers, and a separate **internal** ALB for the editor UI and REST
API, reachable only over VPN or a peered network, optionally behind a WAF.

Set `create_ingress = false` and the module steps out of routing entirely. It
still creates everything the Ingresses point at, and it also stops managing the
Route 53 alias A-record and the `data.aws_lb` lookup behind it, so your own DNS
records are no longer reverted on the next `terraform plan`. The ACM certificate
is still issued when `route53_zone_id` is set, and remains usable by your own
Ingresses.

Route to the Services the module exposes as outputs:

| Output | Value | Serves |
| --- | --- | --- |
| `n8n_service_name` | `n8n-main` | Editor UI, REST API |
| `n8n_webhook_service_name` | `n8n-webhook-processor` | Webhooks, forms, waiting resumptions, MCP |
| `n8n_webhook_path_prefixes` | see below | The prefixes that must reach the processors |
| `n8n_service_port` | `5678` | Both |

### Route every webhook prefix, not just `/webhook`

The module runs the chart with `disableProductionWebhooksOnMainProcess = true`,
which disables **five** endpoint families on the main pods, not one. Each
returns 404 if it reaches `n8n-main`:

| Prefix | Breaks if misrouted |
| --- | --- |
| `/webhook` | Production webhook triggers |
| `/webhook-waiting` | Wait-node resumption, Slack and Telegram human-in-the-loop callbacks |
| `/form` | Form Trigger nodes |
| `/form-waiting` | Multi-page and waiting forms |
| `/mcp` | MCP server triggers |

`n8n_webhook_path_prefixes` returns this list so your Ingress stays in step with
the module as n8n adds endpoints. Iterate over it rather than hardcoding, and
declare the prefixes **before** any catch-all `/` rule.

```hcl
module "n8n" {
  source = "n8n-io/n8n/aws"

  create_ingress = false

  # Two ALBs need two hostnames: a DNS name can alias only one load balancer.
  # Setting route53_zone_id plus n8n_additional_domains makes the module issue
  # and validate one certificate covering both, consumed below through the
  # certificate_arn output. n8n_webhook_url makes n8n hand out webhook URLs on
  # the public host rather than the internal one.
  route53_zone_id        = var.route53_zone_id
  n8n_additional_domains = [var.webhook_domain]
  n8n_webhook_url        = "https://${var.webhook_domain}"

  # ... remaining inputs
}

# Public ALB: webhooks only, on its own hostname.
resource "kubernetes_ingress_v1" "webhook" {
  metadata {
    name      = "n8n-webhook-public"
    namespace = module.n8n.namespace

    annotations = merge(
      {
        "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
        "alb.ingress.kubernetes.io/target-type" = "ip"

        # The module-issued, already-validated certificate. It covers
        # webhook_domain because that name is in n8n_additional_domains.
        "alb.ingress.kubernetes.io/certificate-arn" = module.n8n.certificate_arn
      },
      # Omit the key entirely when there is no WAF: a null annotation value
      # fails the plan.
      var.waf_acl_arn == null ? {} : {
        "alb.ingress.kubernetes.io/wafv2-acl-arn" = var.waf_acl_arn
      },
    )
  }

  spec {
    ingress_class_name = "alb"
    rule {
      host = var.webhook_domain
      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"
            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }
      }
    }
  }

  # The namespace output alone orders this after the namespace, but not after
  # the Helm release that creates the Services the ALB registers targets for.
  depends_on = [module.n8n]
}

# Internal ALB: admin UI, VPN-only. Define a second kubernetes_ingress_v1
# with scheme = "internal", on its own hostname (var.n8n_domain), routing "/"
# to module.n8n.n8n_service_name on the same port.
#
# Give that one the webhook prefixes too, ahead of its "/" rule. Otherwise
# the catch-all sends /webhook to the main pods, which serve none of it, and
# the request falls through to the editor's SPA handler and returns 200 with
# an HTML body: an in-VPC caller reads that as success while nothing ran.
```

## Customizing the module-managed Ingress

Before reaching for `create_ingress = false`, check whether the two narrower
inputs cover you. They keep the module's single-apply DNS wiring intact:

- **`ingress_scheme`**: `internet-facing` (default) or `internal`. Use this
  when the whole deployment should be private rather than split in two.
- **`ingress_annotations`**: a `map(string)` merged over the module's defaults
  (last write wins). This is the escape hatch for any AWS Load Balancer
  Controller feature the module has no opinion on, so you never need a fork to
  set one annotation:

  ```hcl
  ingress_annotations = {
    "alb.ingress.kubernetes.io/wafv2-acl-arn" = aws_wafv2_web_acl.n8n.arn
    "alb.ingress.kubernetes.io/ssl-policy"    = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/inbound-cidrs" = "203.0.113.0/24"
  }
  ```

Two caveats:

- Overriding `alb.ingress.kubernetes.io/target-group-attributes` drops the
  session stickiness that pins a browser to one main pod for 3 hours. Without
  it, WebSocket connections break as the ALB round-robins. Re-include
  `stickiness.enabled=true` if you set that key.
- Set the scheme through `ingress_scheme`, not through `ingress_annotations`.
  Doing both raises a plan-time warning, because the annotation silently wins
  and the failure mode is an admin UI that is public when you meant it to be
  internal.

## KMS key after `terraform destroy`

`aws_kms_key.db` is created with `deletion_window_in_days = 7` (the AWS
minimum), so a `terraform destroy` schedules the key for deletion 7 days out
rather than removing it immediately. Two operational consequences:

- **Cost:** ~$1/month prorated, ~$0.23 per destroy cycle. Negligible but
  non-zero.
- **Repeat applies inside the window:** `aws_kms_alias.db` uses `name_prefix`
  (not a fixed `name`), so apply → destroy → apply works cleanly within the
  7-day window — each apply gets a fresh alias suffix. If you need to recover
  the scheduled-for-deletion key for any reason, run
  `aws kms cancel-key-deletion --key-id <key-id>` and import it back into
  state with `terraform import aws_kms_key.db[0] <key-id>`.

## Execution data in S3 (Enterprise)

The module always stores n8n's **binary** data in S3. From **n8n 2.27** the
**execution** data itself can be offloaded to the same bucket instead of
PostgreSQL. Execution-data writes are usually the dominant write load on the
n8n database at volume, so this is the main lever for relieving RDS pressure in
the queue-mode topology this module deploys:

```hcl
module "n8n" {
  # ...other inputs...

  n8n_execution_data_storage_mode = "s3"   # default: "database"
  n8n_image_tag                   = "2.27.4"
}
```

The module sets `N8N_EXECUTION_DATA_STORAGE_MODE=s3` on the Helm release's
`config.extraEnv`, so it lands on **every** n8n container (main, worker, and
webhook processor), which is what the
[n8n external storage docs](https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/use-external-storage)
require in queue mode. Nothing else has to be wired up: the bucket, the IAM
policy, the Pod Identity role, and the `N8N_EXTERNAL_STORAGE_S3_*` connection
already exist for binary data and are reused as-is.

All six examples expose this as a passthrough variable, each left at `"database"`
so they still run unchanged. Volume rises with the tier, but headroom falls with
it: everything at `small` sizing (`small`, `cloudflare`, `godaddy`,
`split-ingress`) runs `db.t3.small` on 50 GB of gp2 with a 150 IOPS baseline,
where sustained execution-data writes burn burst credits and fill the volume,
while `large` runs Aurora I/O-Optimized with no IOPS ceiling. So the smallest
deployments are the ones that feel execution-data growth soonest, and reaching
for `"s3"` there is often cheaper than resizing the database.

- **Requires n8n >= 2.27.** Pin `n8n_image_tag` accordingly. The chart default
  is the floating `stable` tag, so leaving it unpinned means the version each
  pod gets is whatever is latest when it starts.
- **Requires an Enterprise license** carrying the `feat:executionDataS3`
  entitlement (the module already requires `n8n_license_key`). Note that this is
  a **different** entitlement from the `feat:binaryDataS3` one that the module's
  always-on binary data offload uses, so a license that already puts binary data
  in S3 does not necessarily cover execution data. Check before flipping the
  mode, from any running main pod:

  ```bash
  kubectl -n n8n exec deploy/n8n-main -c n8n-main -- n8n license:info | grep -o 'feat:executionDataS3":[a-z]*'
  ```

  n8n **refuses to start** in `s3` mode without the entitlement, so a license
  gap here takes every pod down, not just the feature. Verified against an
  unlicensed instance, which crash-loops on:

  ```text
  S3 execution data storage requires a valid license. Either set
  `N8N_EXECUTION_DATA_STORAGE_MODE` to something else, or upgrade to a license
  that supports this feature.
  ```

  The Helm release runs with `atomic = true` and `wait = true`, so that fails
  the apply and rolls the release back rather than degrading quietly.
  Entitlements are not visible at plan time, so no `check` block can catch this
  ahead of the apply.

  In practice you are unlikely to see that specific message first. This module
  puts **binary** data in S3 unconditionally, and that gate is checked earlier,
  so an unlicensed deployment fails on `S3 binary data storage requires a valid
  license` before execution data is ever reached. Either way the symptom is the
  same: pods do not start.

  One caveat worth knowing before you try to reproduce that: **clearing
  `n8n_license_key` does not de-license a running deployment.** n8n caches the
  activation result in the database (`settings.license.cert`) and loads it at
  startup, so blanking the input applies cleanly, leaves every pod licensed, and
  keeps writing execution data to S3. The startup gate is therefore reached on a
  deployment with no cached cert, not on one you de-key after the fact.
- **No backfill.** Only new executions are written to S3, under
  `workflows/{workflowId}/executions/{executionId}/execution_data/bundle.json`.
  n8n records the destination per execution, in `execution_entity.storedAt`
  (`db` or `s3`), so switching modes is non-destructive in both directions:
  existing executions stay readable in PostgreSQL, and executions already in S3
  stay readable after switching back, as long as the bucket stays configured.
- **The payload leaves the database entirely.** In `s3` mode n8n writes no
  `execution_data` row at all, rather than a row holding a pointer, so the write
  it saves is the whole bundle. `execution_entity` still gets its row (status,
  timings, `jsonSizeBytes`), which is what the executions list reads, so the UI
  stays responsive without touching S3.
- **Pruning stays with n8n.** The executions hard-delete path removes the S3
  bundle together with the database record, driven by the same
  `n8n_pruning_max_age` / `n8n_pruning_max_count` settings.

### Durability: this weakens the backup posture of execution data

Worth deciding on deliberately, because the two stores are not equivalent:

| | Execution data in `database` | Execution data in `s3` |
| --- | --- | --- |
| Backups | RDS automated backups, `db_backup_retention_period` (default **7 days**) | **None.** The module creates no `aws_s3_bucket_versioning` and no replication |
| Point-in-time recovery | Yes, within the retention window | No |
| Survives `terraform destroy` | Only via a manual snapshot taken beforehand: the instance sets `skip_final_snapshot = true` and `delete_automated_backups = true` | **No.** `force_destroy = true` on the bucket deletes the objects |

So `s3` mode trades RDS write pressure for execution history that has no
recovery path: an accidental `terraform destroy`, or a lifecycle rule that
reaches `execution_data/` (see below), loses it outright. This was already the
posture for binary attachments; `s3` mode extends it to execution history.

If execution history matters to you, close the gap yourself on the bucket
exported as the `s3_bucket_name` output: enable versioning, add
[S3 Versioning + MFA delete](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
or a replication rule, or take periodic copies. Note that versioning interacts
with `force_destroy` (Terraform must delete every version to drop the bucket)
and with any lifecycle rule you add, which then needs
`noncurrent_version_expiration` to keep old versions from accumulating.

### S3 lifecycle rules on the shared bucket

The module creates **no** lifecycle configuration on its bucket. If you add one
of your own (the bucket name is exported as the `s3_bucket_name` output), read
this first, because the two data types have **opposite** requirements:

| Data type      | Object keys                                                  | Who prunes                                       |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------ |
| Binary data    | `workflows/{wf}/executions/{exec}/binary_data/{fileId}`       | **S3.** n8n delegates it, so a lifecycle rule is the only thing that ever deletes these |
| Execution data | `workflows/{wf}/executions/{exec}/execution_data/bundle.json` | **n8n.** A lifecycle rule can delete bundles n8n still references |

That split is observed behaviour, not inference. On a live deployment (n8n
2.33.1, this module's defaults), deleting two executions removed their
`execution_data/bundle.json` objects straight away and left both
`binary_data/` objects sitting in the bucket. **Orphaned binary data is the
normal steady state**, not an edge case, which is what makes a lifecycle rule
worth having in the first place.

A bucket-wide expiration rule therefore does the right thing for binary data
and the wrong thing for execution data. **It cannot be narrowed to only binary
data on a shared bucket:** S3 lifecycle filters match on a literal key
**prefix** (no wildcards), both key layouts share the same
`workflows/{wf}/executions/{exec}/` prefix, and the segment that tells them
apart comes *after* the two variable IDs. n8n tags neither object, so a tag
filter is not an option either.

So, with `n8n_execution_data_storage_mode = "s3"`, pick deliberately:

- **No lifecycle rule** (safe for execution data). Binary data then accumulates
  indefinitely and its storage cost grows without bound, so budget for it or
  reclaim it with an out-of-band job that deletes only `binary_data/` keys.
- **A lifecycle rule long enough to be harmless.** Set the expiration well
  beyond the retention n8n itself enforces (`n8n_pruning_max_age`, default 336h
  / 14 days) so n8n has already hard-deleted an execution before S3 could reach
  its bundle. This is a bound on the *worst* case, not a guarantee: pruning is
  also capped by `n8n_pruning_max_count`, and anything that stalls the prune
  loop widens the window.

With the default `n8n_execution_data_storage_mode = "database"` no
`execution_data/` objects exist, and a bucket-wide lifecycle rule for binary
data is unambiguously the right thing to add.

## Prometheus metrics

Set `n8n_metrics_enabled = true` to expose n8n's built-in Prometheus endpoint.
When on, the module appends `N8N_METRICS=true` to the main pod's `extraEnv`;
n8n serves metrics on its existing HTTP listener — path **`/metrics`** on
**port `5678`** (the same port and `n8n-main` Service the chart already
publishes for the UI/API), so no additional ports or Services are needed.

The pinned n8n Helm chart version (see `n8n_chart_version`) exposes no
top-level `metrics` or `serviceMonitor` block of its own — verified via
`helm show values oci://ghcr.io/n8n-io/n8n-helm-chart/n8n --version <ver>` —
so this toggle is intentionally env-var-only. Wiring the actual scrape is
left to your monitoring stack: add Prometheus scrape annotations to the
`n8n-main` Service via your own Kubernetes resource, or create a
`ServiceMonitor` CR if you run the Prometheus Operator.

## OpenTelemetry tracing

Set `n8n_otel_enabled = true` to turn on n8n's built-in workflow and node
tracing. The module wires the `N8N_OTEL_*` environment variables onto the
Helm release's `config.extraEnv` block, which the chart applies to **every**
n8n container — main, worker, and webhook processor. This matches the
queue-mode requirement in the
[n8n OpenTelemetry docs](https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/):
the env vars must be set on every instance for trace context to propagate
between them.

The **collector** (e.g. an OpenTelemetry Collector deployment, or Jaeger's
OTLP receiver) is intentionally **out of scope** for this module. Deploy
one separately — either with a sibling Terraform module, the upstream
`open-telemetry/opentelemetry-collector` Helm chart, or your existing
observability platform — then point `n8n_otel_exporter_otlp_endpoint` at
its base URL (n8n appends `/v1/traces` itself, so don't include it).

Minimal opt-in:

```hcl
module "n8n" {
  # ...other inputs...

  n8n_otel_enabled                = true
  n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
}
```

Individual tuning variables (`n8n_otel_exporter_otlp_headers`,
`n8n_otel_exporter_service_name`, `n8n_otel_traces_sample_rate`,
`n8n_otel_traces_include_node_spans`, `n8n_otel_traces_inject_outbound`,
`n8n_otel_traces_production_only`) all default to `null`. When an individual value is `null` the corresponding
env var is omitted entirely and n8n's own default applies — only set the
values you actually need to override.

When `n8n_otel_enabled = false` (the default), none of the `N8N_OTEL_*`
env vars are emitted and n8n's OpenTelemetry SDK is not loaded.
`n8n_otel_exporter_otlp_headers` is marked `sensitive` because it typically
carries collector authentication tokens.

## Log streaming (Enterprise)

Set `n8n_log_streaming_managed_by_env = true` to provision n8n's
[log streaming](https://docs.n8n.io/log-streaming/) destinations
declaratively from Terraform instead of the UI. The module JSON-encodes
`n8n_log_streaming_destinations` into `N8N_LOG_STREAMING_DESTINATIONS` and
sets `N8N_LOG_STREAMING_MANAGED_BY_ENV=true` on every n8n container. n8n
then reapplies the destinations on **every startup** and locks the Log
Streaming UI controls read-only — Terraform becomes the source of truth.

Requires **n8n >= 2.19.0** and an Enterprise license that includes the log
streaming entitlement (the module already requires `n8n_license_key`).

```hcl
module "n8n" {
  # ...other inputs...

  n8n_log_streaming_managed_by_env = true
  n8n_log_streaming_destinations = [
    {
      type             = "webhook"
      label            = "Audit events"
      enabled          = true
      subscribedEvents = ["n8n.audit", "n8n.workflow"]
      url              = "https://hooks.example.com/n8n"
      method           = "POST"
    },
  ]
}
```

Each destination is an object with `type` set to `webhook`, `syslog`, or
`sentry` plus the type-specific fields from the
[n8n docs](https://docs.n8n.io/log-streaming/#configure-using-environment-variables).
The variable is marked `sensitive` (webhook headers and Sentry DSNs
typically carry credentials), but the rendered value still lands in
Terraform state and the pod environment in plaintext — restrict access
accordingly. Setting `n8n_log_streaming_managed_by_env` back to `false`
keeps the last applied destinations but restores UI write access.

## Reference

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.12 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_time"></a> [time](#provider\_time) | ~> 0.12 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_cloudwatch_log_group.rds_postgresql](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_instance.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_eks_addon.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.pod_identity_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_eks_pod_identity_association.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.lbc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_elasticache_cluster.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_cluster) | resource |
| [aws_elasticache_subnet_group.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_subnet_group) | resource |
| [aws_iam_policy.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.lbc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lbc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lbc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.nodes_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.nodes_ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.nodes_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_record.cert_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.n8n_alias](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.n8n_alias_additional](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_public_access_block.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_security_group.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [helm_release.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.lbc](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.metrics_server](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.n8n](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/horizontal_pod_autoscaler_v2) | resource |
| [kubernetes_ingress_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [kubernetes_namespace.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.n8n_db](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class_v1.gp3](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |
| [random_id.n8n_encryption_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_password.db_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.task_runner_token](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [time_sleep.wait_for_alb_cleanup](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.lbc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_lb.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_alb_ssl_policy"></a> [alb\_ssl\_policy](#input\_alb\_ssl\_policy) | TLS negotiation policy for the ALB HTTPS listener, wired to alb.ingress.kubernetes.io/ssl-policy. Defaults to a current, modern policy (ELBSecurityPolicy-TLS13-1-2-2021-06) so the negotiated policy is explicit and pinned in Terraform rather than left to whatever the ALB defaults to, which AWS can change without notice. Set this to any AWS-published ELB security policy name (e.g. one of the ELBSecurityPolicy-TLS13-1-2-* or ELBSecurityPolicy-FS-1-2-* families) to match a compliance baseline such as TLS 1.2 minimum or TLS 1.3-only. Ignored when create\_ingress = false, or when ingress\_annotations sets alb.ingress.kubernetes.io/ssl-policy directly (last write wins; the module warns when that happens). | `string` | `"ELBSecurityPolicy-TLS13-1-2-2021-06"` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). Must match the region the AWS provider is configured for. | `string` | n/a | yes |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ARN of a pre-validated ACM certificate for n8n\_domain. Use this for Cloudflare, GoDaddy, or any DNS provider other than Route53 — the respective examples (examples/cloudflare, examples/godaddy) issue the certificate and pass its ARN here. Set exactly one of certificate\_arn or route53\_zone\_id. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_create_database"></a> [create\_database](#input\_create\_database) | When true (the default), the module creates and manages an Amazon RDS PostgreSQL instance. Set to false to use an external database (e.g. Amazon Aurora created by the caller) — db\_host and db\_password must then be supplied. Kept as a static boolean rather than `db_host == null` because count expressions cannot depend on values computed at apply time. | `bool` | `true` | no |
| <a name="input_create_ingress"></a> [create\_ingress](#input\_create\_ingress) | When true (the default), the module creates the ALB Ingress that fronts n8n: a single internet-facing ALB routing /webhook to the webhook processors and / to the mains. Set to false to bring your own Ingress resources, for example the two-ALB split where an internet-facing ALB serves /webhook and a separate internal (VPN-only) ALB serves the admin UI. When false the module also skips the Route 53 alias A-record and the ALB lookup behind it, since there is no module-owned ALB to point at; the ACM certificate is still issued when route53\_zone\_id is set. Point your own Ingresses at the module-created Services n8n\_service\_name and n8n\_webhook\_service\_name, both on port 5678. Kept as a static boolean because count expressions cannot depend on values computed at apply time. | `bool` | `true` | no |
| <a name="input_db_allocated_storage"></a> [db\_allocated\_storage](#input\_db\_allocated\_storage) | Allocated storage for RDS in GB | `number` | `50` | no |
| <a name="input_db_allowed_cidr_blocks"></a> [db\_allowed\_cidr\_blocks](#input\_db\_allowed\_cidr\_blocks) | Additional CIDR blocks allowed to reach the module-managed RDS instance on port 5432, appended to the VPC CIDR (which is always allowed so nodes and pods can connect). Use this for a corporate network, VPN pool, or peered VPC rather than attaching a standalone aws\_security\_group\_rule at the root, because a root-level rule is not tracked by the module's inline ingress block and gets stripped on the next plan. Duplicates, including a repeat of the VPC CIDR, are collapsed. With create\_database = false the security group is still created and carries these rules, but nothing is attached to it. | `list(string)` | `[]` | no |
| <a name="input_db_allowed_security_group_ids"></a> [db\_allowed\_security\_group\_ids](#input\_db\_allowed\_security\_group\_ids) | Security group IDs allowed to reach the module-managed RDS instance on port 5432, in addition to the always-allowed VPC CIDR. Preferred over db\_allowed\_cidr\_blocks for sources inside the VPC: membership follows the instances rather than their addresses, so the rule survives subnet changes and IP reuse. Use it for a bastion, a migration runner, or an app tier that already has its own group. No rule is created when the list is empty. With create\_database = false the security group is still created and carries this rule, but nothing is attached to it. | `list(string)` | `[]` | no |
| <a name="input_db_backup_retention_period"></a> [db\_backup\_retention\_period](#input\_db\_backup\_retention\_period) | Number of days to retain automated RDS backups. 0 disables automated backups (not recommended, and it also disables point-in-time recovery). AWS allows up to 35 days. Ignored when create\_database = false. | `number` | `7` | no |
| <a name="input_db_engine_version"></a> [db\_engine\_version](#input\_db\_engine\_version) | PostgreSQL engine version for the RDS instance. Must be a version available from `aws rds describe-db-engine-versions --engine postgres` in the target region — RDS deprecates and removes minor versions over time, and supported versions vary by region. Bump as needed without forking. | `string` | `"16.9"` | no |
| <a name="input_db_host"></a> [db\_host](#input\_db\_host) | External database host. Required when create\_database = false. Ignored otherwise. Use this to pass in an Amazon Aurora cluster endpoint or any external PostgreSQL host. | `string` | `null` | no |
| <a name="input_db_instance_class"></a> [db\_instance\_class](#input\_db\_instance\_class) | RDS instance class (db.t3.small ~$25/month, db.t3.medium for higher load) | `string` | `"db.t3.small"` | no |
| <a name="input_db_multi_az"></a> [db\_multi\_az](#input\_db\_multi\_az) | Deploy RDS in Multi-AZ mode for automatic failover (recommended for production) | `bool` | `true` | no |
| <a name="input_db_password"></a> [db\_password](#input\_db\_password) | Password for the external database specified by db\_host. Required when create\_database = false. Ignored otherwise (the module generates a random password for its managed RDS instance). | `string` | `null` | no |
| <a name="input_db_postgresdb_pool_size"></a> [db\_postgresdb\_pool\_size](#input\_db\_postgresdb\_pool\_size) | Number of TypeORM connection pool slots per n8n pod. Each pod holds this many persistent PostgreSQL connections. Rule of thumb: pool\_size >= worker\_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20). | `number` | `10` | no |
| <a name="input_db_postgresdb_ssl_enabled"></a> [db\_postgresdb\_ssl\_enabled](#input\_db\_postgresdb\_ssl\_enabled) | Whether n8n connects to the database over SSL. Set to true (the default) for direct connections to RDS or Aurora — they use the AWS CA which Node.js doesn't trust by default, so the connection still negotiates SSL but skips certificate verification. Set to false when n8n connects to an in-cluster connection pooler (e.g. PgBouncer) that handles SSL on its upstream leg — the pod-to-pod traffic stays inside the cluster network. | `bool` | `true` | no |
| <a name="input_db_storage_encrypted"></a> [db\_storage\_encrypted](#input\_db\_storage\_encrypted) | When true (the default), encrypt the RDS instance's storage, Performance Insights data, and the postgresql CloudWatch log group with a module-created Customer Managed KMS Key (aws\_kms\_key.db). Clears Checkov findings CKV\_AWS\_16, CKV\_AWS\_354, and CKV\_AWS\_158. Flipping this from false to true on an existing RDS instance forces a replacement — AWS does not support enabling storage encryption in place, so the upgrade path is snapshot → restore into a new encrypted instance. Set to false in your tfvars to preserve current behavior on pre-existing unencrypted deployments. The CMK rotates annually and uses a 7-day deletion window (AWS minimum). Ignored when create\_database = false. | `bool` | `true` | no |
| <a name="input_ingress_annotations"></a> [ingress\_annotations](#input\_ingress\_annotations) | Extra annotations for the module-managed Ingress, merged over the module's defaults (last write wins). Use this for AWS Load Balancer Controller features the module has no opinion on: alb.ingress.kubernetes.io/wafv2-acl-arn, subnets, security-groups, inbound-cidrs, load-balancer-name, group.name, access log settings. Overriding alb.ingress.kubernetes.io/target-group-attributes drops the session stickiness that keeps WebSocket connections pinned to one main pod; re-include stickiness.enabled=true if you set it. Prefer ingress\_scheme over setting alb.ingress.kubernetes.io/scheme here, and alb\_ssl\_policy over setting alb.ingress.kubernetes.io/ssl-policy here, because setting both raises a plan-time warning. Ignored when create\_ingress = false. | `map(string)` | `{}` | no |
| <a name="input_ingress_scheme"></a> [ingress\_scheme](#input\_ingress\_scheme) | ALB scheme for the module-managed Ingress: internet-facing (the default) or internal. Use internal to keep n8n reachable only from within the VPC and any peered/VPN networks. Ignored when create\_ingress = false. An internal scheme makes the Route 53 alias record resolve to private addresses, which is the intended behavior for a private deployment. | `string` | `"internet-facing"` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version for the EKS cluster | `string` | `"1.35"` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra fully-qualified hostnames n8n should answer on, beyond n8n\_domain. Added to the module-issued ACM certificate as subject alternative names and given a Route 53 validation record each. Requires the Route 53 path (route53\_zone\_id set); with a caller-supplied certificate\_arn the module cannot add names to a certificate it did not issue, and a plan-time warning says so. With create\_ingress = true each name also gets an alias A-record and an Ingress rule, so the module routes it end to end. With create\_ingress = false the certificate still covers every name and every name is still validated: consume it through the certificate\_arn output and attach it to your own Ingress resources, as examples/split-ingress does. n8n\_domain stays canonical: it is what n8n advertises as WEBHOOK\_URL and N8N\_HOST. Every name must live in the hosted zone given by route53\_zone\_id, since that is the zone all validation and alias records are written to. A name outside it fails the apply when Route 53 rejects the record as not permitted in the zone. Names in a second hosted zone need their own certificate and records, which the caller owns. Names are normalized to lowercase before use: ACM and Kubernetes both store them that way, and DNS is case-insensitive. | `list(string)` | `[]` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy | `string` | `"1.10.0"` | no |
| <a name="input_n8n_community_packages_prevent_loading"></a> [n8n\_community\_packages\_prevent\_loading](#input\_n8n\_community\_packages\_prevent\_loading) | Prevent installed community packages from being loaded at runtime. Maps to N8N\_COMMUNITY\_PACKAGES\_PREVENT\_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. | `bool` | `false` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the CN / SAN on the certificate provided via certificate\_arn. | `string` | n/a | yes |
| <a name="input_n8n_execution_concurrency_limit"></a> [n8n\_execution\_concurrency\_limit](#input\_n8n\_execution\_concurrency\_limit) | Maximum concurrent production executions (-1 to disable) | `number` | `100` | no |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Maps to N8N\_EXECUTION\_DATA\_STORAGE\_MODE. "database" (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. "s3" offloads it to the module's S3 bucket, reusing the same bucket and N8N\_EXTERNAL\_STORAGE\_S3\_* connection that binary data mode already uses, so no extra bucket, IAM policy, or credentials are needed. Execution-data writes are usually the dominant write load on the n8n database at volume, so s3 is the main lever for relieving RDS pressure. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is a different entitlement from the feat:binaryDataS3 one the always-on binary data offload uses: n8n refuses to start in s3 mode without it. There is no backfill: existing executions stay readable where they were written, and only new executions go to S3, under workflows/{workflowId}/executions/{executionId}/execution\_data/bundle.json. n8n prunes those objects itself as part of the executions hard-delete path (see n8n\_pruning\_max\_age / n8n\_pruning\_max\_count), so do NOT add an S3 lifecycle rule that can reach execution\_data/ objects (see the S3 lifecycle section in the README). Note the durability trade-off: RDS gets automated backups and point-in-time recovery (db\_backup\_retention\_period, default 7 days) while the bucket has no versioning, no backups, and force\_destroy = true, so in s3 mode a terraform destroy takes execution history with it. See the durability section in the README. "filesystem" is deliberately not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology, so execution data written there would be lost on reschedule and invisible to the other pods. See https://docs.n8n.io/deploy/host-n8n/configure-n8n/scaling/use-external-storage. | `string` | `"database"` | no |
| <a name="input_n8n_execution_timeout"></a> [n8n\_execution\_timeout](#input\_n8n\_execution\_timeout) | Default execution timeout in seconds (-1 to disable) | `number` | `7200` | no |
| <a name="input_n8n_execution_timeout_max"></a> [n8n\_execution\_timeout\_max](#input\_n8n\_execution\_timeout\_max) | Maximum execution timeout users can configure in seconds | `number` | `7200` | no |
| <a name="input_n8n_extra_env"></a> [n8n\_extra\_env](#input\_n8n\_extra\_env) | Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, license, or topology variable the module manages: any name starting with DB\_, QUEUE\_, N8N\_RUNNERS\_, N8N\_EXTERNAL\_STORAGE\_S3\_, N8N\_MULTI\_MAIN\_, or AWS\_, plus names like N8N\_ENCRYPTION\_KEY, N8N\_LICENSE\_ACTIVATION\_KEY, N8N\_HOST, WEBHOOK\_URL, and EXECUTIONS\_MODE. Use the dedicated module inputs for those. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *\_FILE companion (e.g. a name ending in \_FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = "N8N\_DEFAULT\_LOCALE", value = "de"}]. | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_helm_timeout"></a> [n8n\_helm\_timeout](#input\_n8n\_helm\_timeout) | Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s. | `number` | `600` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). When it is null (the default), the Helm chart's own default applies — currently the floating `stable` tag, which resolves to whatever n8n version is latest at the time each pod starts. Pin this to a concrete version for reproducible, incremental upgrades and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on an unplanned pod reschedule. See https://docs.n8n.io/2-0-breaking-changes/ for the n8n 2.x migration guide. | `string` | `null` | no |
| <a name="input_n8n_license_detach_floating_on_shutdown"></a> [n8n\_license\_detach\_floating\_on\_shutdown](#input\_n8n\_license\_detach\_floating\_on\_shutdown) | Whether n8n main pods detach their floating license entitlement on shutdown. Maps to N8N\_LICENSE\_DETACH\_FLOATING\_ON\_SHUTDOWN. n8n's upstream default is true, which is safe for a single main but breaks multi-main (n8n\_main\_hpa\_min\_replicas > 1, the module default): the leader main detaches on shutdown and zeroes the shared floating cert in the database, so any fresh main pod that starts as a follower reads the zeroed cert, fails the init-time license gate, and crash-loops — which can push a Helm release with atomic = true into a stuck pending-rollback state (see docs/troubleshooting.md and https://github.com/n8n-io/terraform-aws-n8n/issues/49). The module defaults this to false, overriding n8n's own default, because all mains share the same device fingerprint: a single floating seat is reused across restarts and nothing leaks. Set to true only to restore n8n's upstream behavior, and only for single-main deployments. | `bool` | `false` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_log_level"></a> [n8n\_log\_level](#input\_n8n\_log\_level) | n8n log level. Maps to the N8N\_LOG\_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose. | `string` | `"info"` | no |
| <a name="input_n8n_log_output"></a> [n8n\_log\_output](#input\_n8n\_log\_output) | n8n log output destination(s). Maps to the N8N\_LOG\_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. "console", "file", "console,file"). Note: this variable does NOT control log *format* — setting an invalid value (e.g. "json") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations. | `string` | `"console"` | no |
| <a name="input_n8n_log_streaming_destinations"></a> [n8n\_log\_streaming\_destinations](#input\_n8n\_log\_streaming\_destinations) | List of log streaming destination objects, JSON-encoded into N8N\_LOG\_STREAMING\_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at https://docs.n8n.io/log-streaming/#configure-using-environment-variables (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials — note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n\_log\_streaming\_managed\_by\_env = false. | `any` | `[]` | no |
| <a name="input_n8n_log_streaming_managed_by_env"></a> [n8n\_log\_streaming\_managed\_by\_env](#input\_n8n\_log\_streaming\_managed\_by\_env) | Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N\_LOG\_STREAMING\_MANAGED\_BY\_ENV. When true, n8n applies n8n\_log\_streaming\_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See https://docs.n8n.io/log-streaming/ for the underlying n8n contract. | `bool` | `false` | no |
| <a name="input_n8n_main_cpu_limit"></a> [n8n\_main\_cpu\_limit](#input\_n8n\_main\_cpu\_limit) | CPU limit for n8n main pods (e.g. 2000m, 1000m) | `string` | `"2000m"` | no |
| <a name="input_n8n_main_cpu_request"></a> [n8n\_main\_cpu\_request](#input\_n8n\_main\_cpu\_request) | CPU request for n8n main pods (e.g. 1000m, 500m) | `string` | `"1000m"` | no |
| <a name="input_n8n_main_hpa_cpu_threshold"></a> [n8n\_main\_hpa\_cpu\_threshold](#input\_n8n\_main\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n main pods. | `number` | `60` | no |
| <a name="input_n8n_main_hpa_max_replicas"></a> [n8n\_main\_hpa\_max\_replicas](#input\_n8n\_main\_hpa\_max\_replicas) | Maximum replicas for n8n main pods. HPA will not scale above this. The default of 6 is sized to the default node group (node\_max × node\_instance\_type): at the default CPU requests, 6 main pods plus their task runner sidecars, the worker ceiling, and the webhook ceiling all fit in what 6 t3.xlarge nodes can schedule. Raise this together with node\_max or node\_instance\_type. An HPA ceiling the node group cannot hold leaves pods Pending with "Insufficient cpu" once the Cluster Autoscaler reaches node\_max, which also slows rollouts. The module warns at plan time when the three groups are out of step; see README.md → "Sizing autoscaling against node capacity". | `number` | `6` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replicas for n8n main pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Keep at 2 or more for availability: mains serve the editor and REST API, and the module's PodDisruptionBudget only guarantees one during a node drain. | `number` | `2` | no |
| <a name="input_n8n_main_memory_limit"></a> [n8n\_main\_memory\_limit](#input\_n8n\_main\_memory\_limit) | Memory limit for n8n main pods (e.g. 4Gi, 2Gi) | `string` | `"4Gi"` | no |
| <a name="input_n8n_main_memory_request"></a> [n8n\_main\_memory\_request](#input\_n8n\_main\_memory\_request) | Memory request for n8n main pods (e.g. 2Gi, 1Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_metrics_enabled"></a> [n8n\_metrics\_enabled](#input\_n8n\_metrics\_enabled) | Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends N8N\_METRICS=true to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor). n8n exposes /metrics on its existing HTTP port (5678) — the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n\_chart\_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack — in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply. | `bool` | `false` | no |
| <a name="input_n8n_otel_enabled"></a> [n8n\_otel\_enabled](#input\_n8n\_otel\_enabled) | Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N\_OTEL\_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module — deploy it separately and point n8n\_otel\_exporter\_otlp\_endpoint at it. See https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/ for the underlying n8n contract. | `bool` | `false` | no |
| <a name="input_n8n_otel_exporter_otlp_endpoint"></a> [n8n\_otel\_exporter\_otlp\_endpoint](#input\_n8n\_otel\_exporter\_otlp\_endpoint) | Base URL of the OTLP HTTP endpoint to export traces to (e.g. http://otel-collector.observability.svc.cluster.local:4318 for an in-cluster collector). When set, maps to N8N\_OTEL\_EXPORTER\_OTLP\_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (http://localhost:4318), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_exporter_otlp_headers"></a> [n8n\_otel\_exporter\_otlp\_headers](#input\_n8n\_otel\_exporter\_otlp\_headers) | Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. 'authorization=Bearer <token>,x-tenant=acme'). Use this for collector authentication or multi-tenant routing. Maps to N8N\_OTEL\_EXPORTER\_OTLP\_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_exporter_service_name"></a> [n8n\_otel\_exporter\_service\_name](#input\_n8n\_otel\_exporter\_service\_name) | Value of the service.name resource attribute on exported spans. Maps to N8N\_OTEL\_EXPORTER\_SERVICE\_NAME. Leave null to use n8n's default ('n8n'). Set this to differentiate multiple n8n deployments sending traces to the same collector (e.g. 'n8n-prod', 'n8n-staging'). Ignored when n8n\_otel\_enabled = false. | `string` | `null` | no |
| <a name="input_n8n_otel_traces_include_node_spans"></a> [n8n\_otel\_traces\_include\_node\_spans](#input\_n8n\_otel\_traces\_include\_node\_spans) | Whether to emit a node.execute span for each node execution. Maps to N8N\_OTEL\_TRACES\_INCLUDE\_NODE\_SPANS. Leave null to use n8n's default (true — one span per node per execution). Set to false to export workflow-level spans only — a common volume-reduction lever for workflows with many small nodes. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_inject_outbound"></a> [n8n\_otel\_traces\_inject\_outbound](#input\_n8n\_otel\_traces\_inject\_outbound) | Whether n8n's HTTP-helper-based nodes (HTTP Request and similar) inject W3C traceparent / tracestate headers into outbound requests. Maps to N8N\_OTEL\_TRACES\_INJECT\_OUTBOUND. Leave null to use n8n's default (true — propagate context to downstream services). Set to false when calling external systems that misbehave on unexpected headers, or when you don't want trace context leaving your boundary. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_production_only"></a> [n8n\_otel\_traces\_production\_only](#input\_n8n\_otel\_traces\_production\_only) | Whether to export traces for production workflow executions only. Maps to N8N\_OTEL\_TRACES\_PRODUCTION\_ONLY. Leave null to use n8n's default (true — only production executions are traced). Set to false to also trace manual/test executions run from the editor, which helps while developing instrumentation but is noisy in production. Ignored when n8n\_otel\_enabled = false. | `bool` | `null` | no |
| <a name="input_n8n_otel_traces_sample_rate"></a> [n8n\_otel\_traces\_sample\_rate](#input\_n8n\_otel\_traces\_sample\_rate) | Fraction of traces to export, between 0 and 1 inclusive. Maps to N8N\_OTEL\_TRACES\_SAMPLE\_RATE. n8n uses a trace-ID-ratio sampler, so the same trace ID is either fully sampled or fully dropped across all spans. Leave null to use n8n's default (1.0 — every trace exported). Lower for high-volume installs where the collector or backend can't handle every workflow execution as a trace. Ignored when n8n\_otel\_enabled = false. | `number` | `null` | no |
| <a name="input_n8n_personalization_enabled"></a> [n8n\_personalization\_enabled](#input\_n8n\_personalization\_enabled) | Whether n8n asks users personalization survey questions and tailors content/recommendations based on the answers. Maps to N8N\_PERSONALIZATION\_ENABLED. When false, sets N8N\_PERSONALIZATION\_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default — note that explicitly setting true emits no env var (n8n's default already applies). Set to false to skip the personalization survey, e.g. on shared or ephemeral instances. | `bool` | `true` | no |
| <a name="input_n8n_prestop_sleep"></a> [n8n\_prestop\_sleep](#input\_n8n\_prestop\_sleep) | Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM — do not lower below 10. | `number` | `10` | no |
| <a name="input_n8n_pruning_max_age"></a> [n8n\_pruning\_max\_age](#input\_n8n\_pruning\_max\_age) | Maximum age of execution records to retain, in hours (336 = 14 days) | `number` | `336` | no |
| <a name="input_n8n_pruning_max_count"></a> [n8n\_pruning\_max\_count](#input\_n8n\_pruning\_max\_count) | Maximum number of execution records to retain (0 = no limit) | `number` | `10000` | no |
| <a name="input_n8n_reinstall_missing_packages"></a> [n8n\_reinstall\_missing\_packages](#input\_n8n\_reinstall\_missing\_packages) | Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N\_REINSTALL\_MISSING\_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral in EKS, so a rescheduled or newly scaled-up worker comes up without them and nodes installed via the UI fail to load on that pod. Enabling this makes every pod (main, worker, and webhook-processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies. When true, size the webhook processor above this module's defaults: every pod runs npm installs at boot and n8n rebroadcasts installs to all pods via pubsub, so a rolling restart makes every webhook pod install repeatedly at once. Against low CPU/memory this causes CPU-based HPA thrash and OOMKilled crash loops; see n8n\_webhook\_cpu\_request, n8n\_webhook\_memory\_limit, and docs/troubleshooting.md. | `bool` | `false` | no |
| <a name="input_n8n_task_runner_auto_shutdown_timeout"></a> [n8n\_task\_runner\_auto\_shutdown\_timeout](#input\_n8n\_task\_runner\_auto\_shutdown\_timeout) | Seconds of inactivity before the runner process shuts down. Set to 0 to disable. | `number` | `15` | no |
| <a name="input_n8n_task_runner_cpu_limit"></a> [n8n\_task\_runner\_cpu\_limit](#input\_n8n\_task\_runner\_cpu\_limit) | CPU limit for task runner sidecar containers (e.g. 1, 2000m) | `string` | `"1"` | no |
| <a name="input_n8n_task_runner_cpu_request"></a> [n8n\_task\_runner\_cpu\_request](#input\_n8n\_task\_runner\_cpu\_request) | CPU request for task runner sidecar containers (e.g. 200m, 500m) | `string` | `"200m"` | no |
| <a name="input_n8n_task_runner_memory_limit"></a> [n8n\_task\_runner\_memory\_limit](#input\_n8n\_task\_runner\_memory\_limit) | Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_n8n_task_runner_memory_request"></a> [n8n\_task\_runner\_memory\_request](#input\_n8n\_task\_runner\_memory\_request) | Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi) | `string` | `"512Mi"` | no |
| <a name="input_n8n_task_runner_python_enabled"></a> [n8n\_task\_runner\_python\_enabled](#input\_n8n\_task\_runner\_python\_enabled) | Enable the native Python runner (beta). Required for Python code execution in workflows. | `bool` | `true` | no |
| <a name="input_n8n_task_runner_request_timeout"></a> [n8n\_task\_runner\_request\_timeout](#input\_n8n\_task\_runner\_request\_timeout) | Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N\_RUNNERS\_TASK\_REQUEST\_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar). | `number` | `300` | no |
| <a name="input_n8n_task_runners_enabled"></a> [n8n\_task\_runners\_enabled](#input\_n8n\_task\_runners\_enabled) | Enable task runner sidecars for isolated JavaScript and Python code execution | `bool` | `true` | no |
| <a name="input_n8n_templates_enabled"></a> [n8n\_templates\_enabled](#input\_n8n\_templates\_enabled) | Enable n8n's workflow templates and template suggestions. Maps to N8N\_TEMPLATES\_ENABLED. When false, sets N8N\_TEMPLATES\_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default — note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows. | `bool` | `true` | no |
| <a name="input_n8n_termination_grace_period"></a> [n8n\_termination\_grace\_period](#input\_n8n\_termination\_grace\_period) | Seconds Kubernetes waits after SIGTERM before force-killing pods. MINIMUM — do not lower below 60. Workers need time to finish in-flight executions before being terminated. | `number` | `60` | no |
| <a name="input_n8n_timezone"></a> [n8n\_timezone](#input\_n8n\_timezone) | Timezone for n8n (e.g. UTC, America/New\_York, Europe/London) | `string` | `"UTC"` | no |
| <a name="input_n8n_webhook_cpu_limit"></a> [n8n\_webhook\_cpu\_limit](#input\_n8n\_webhook\_cpu\_limit) | CPU limit for n8n webhook processor pods (e.g. 800m, 1000m). Raise to at least 1500m when n8n\_reinstall\_missing\_packages = true; see that variable and docs/troubleshooting.md. | `string` | `"800m"` | no |
| <a name="input_n8n_webhook_cpu_request"></a> [n8n\_webhook\_cpu\_request](#input\_n8n\_webhook\_cpu\_request) | CPU request for n8n webhook processor pods (e.g. 300m, 500m). This default is sized for typical webhook traffic, not for n8n\_reinstall\_missing\_packages = true: a low request against an npm-install CPU spike is what drives the CPU-based HPA into a scale-up-on-every-rollout loop. Raise to at least 800m when that toggle is on; see n8n\_reinstall\_missing\_packages and docs/troubleshooting.md. | `string` | `"300m"` | no |
| <a name="input_n8n_webhook_hpa_cpu_threshold"></a> [n8n\_webhook\_hpa\_cpu\_threshold](#input\_n8n\_webhook\_hpa\_cpu\_threshold) | Target average CPU utilization (%) that triggers scaling of n8n webhook pods. | `number` | `65` | no |
| <a name="input_n8n_webhook_hpa_max_replicas"></a> [n8n\_webhook\_hpa\_max\_replicas](#input\_n8n\_webhook\_hpa\_max\_replicas) | Maximum replicas for n8n webhook processor pods. HPA will not scale above this. The default of 8 is sized to the default node group (node\_max × node\_instance\_type), alongside the main and worker ceilings. Webhook processors are the cheapest pod family to scale (no task runner sidecar, 300m by default), so this is usually the first ceiling to raise once node\_max goes up. See n8n\_main\_hpa\_max\_replicas and README.md → "Sizing autoscaling against node capacity". | `number` | `8` | no |
| <a name="input_n8n_webhook_hpa_min_replicas"></a> [n8n\_webhook\_hpa\_min\_replicas](#input\_n8n\_webhook\_hpa\_min\_replicas) | Minimum replicas for n8n webhook processor pods. HPA will not scale below this. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. Webhook processors take production webhook traffic, so a warm floor is what keeps a traffic ramp from queueing behind pod startup. | `number` | `2` | no |
| <a name="input_n8n_webhook_hpa_scale_up_stabilization_window_seconds"></a> [n8n\_webhook\_hpa\_scale\_up\_stabilization\_window\_seconds](#input\_n8n\_webhook\_hpa\_scale\_up\_stabilization\_window\_seconds) | Seconds the webhook processor HPA looks back before scaling up, via the HPA's behavior.scaleUp.stabilizationWindowSeconds. Kubernetes' own default is 0 (scale up immediately), which this module preserves by default. A short CPU spike right after a pod boots (e.g. from N8N\_REINSTALL\_MISSING\_PACKAGES=true reinstalling community packages, see n8n\_reinstall\_missing\_packages) can read as sustained high utilization and trigger a scale-up that a slightly longer window would absorb. Raise this (e.g. to 300) to require CPU to stay above threshold for that long before adding pods. Must be between 0 and 3600, the range the Kubernetes API enforces. | `number` | `0` | no |
| <a name="input_n8n_webhook_memory_limit"></a> [n8n\_webhook\_memory\_limit](#input\_n8n\_webhook\_memory\_limit) | Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi). This default is too low for n8n\_reinstall\_missing\_packages = true: concurrent npm installs plus the n8n baseline can exceed it and OOMKill the pod mid-install into a reinstall/broadcast crash loop. Raise to at least 2Gi when that toggle is on; see that variable and docs/troubleshooting.md. | `string` | `"1Gi"` | no |
| <a name="input_n8n_webhook_memory_request"></a> [n8n\_webhook\_memory\_request](#input\_n8n\_webhook\_memory\_request) | Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi). Raise to at least 1Gi when n8n\_reinstall\_missing\_packages = true; see that variable and docs/troubleshooting.md. | `string` | `"512Mi"` | no |
| <a name="input_n8n_webhook_url"></a> [n8n\_webhook\_url](#input\_n8n\_webhook\_url) | Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com). Defaults to https://<n8n\_domain> when not set. Override when webhooks are served from a different host than the n8n UI. | `string` | `null` | no |
| <a name="input_n8n_worker_concurrency"></a> [n8n\_worker\_concurrency](#input\_n8n\_worker\_concurrency) | Number of jobs each worker pod can process simultaneously | `number` | `10` | no |
| <a name="input_n8n_worker_cpu_limit"></a> [n8n\_worker\_cpu\_limit](#input\_n8n\_worker\_cpu\_limit) | CPU limit for n8n worker pods (e.g. 1000m, 2000m) | `string` | `"1000m"` | no |
| <a name="input_n8n_worker_cpu_request"></a> [n8n\_worker\_cpu\_request](#input\_n8n\_worker\_cpu\_request) | CPU request for n8n worker pods (e.g. 500m, 1000m) | `string` | `"500m"` | no |
| <a name="input_n8n_worker_keda_jobs_per_replica"></a> [n8n\_worker\_keda\_jobs\_per\_replica](#input\_n8n\_worker\_keda\_jobs\_per\_replica) | Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue\_depth / jobs\_per\_replica) replicas. | `number` | `5` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum worker replicas KEDA may scale to. Workers compete for the same nodes as the main and webhook pods, and each carries a task runner sidecar, so this ceiling counts against the same node group budget as the two HPA maxima. See README.md → "Sizing autoscaling against node capacity". | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty. Also becomes the deployment's own replica count: the Helm chart renders spec.replicas unconditionally, so leaving it below the autoscaler floor would make every helm upgrade scale down and then wait for the autoscaler to climb back. | `number` | `1` | no |
| <a name="input_n8n_worker_memory_limit"></a> [n8n\_worker\_memory\_limit](#input\_n8n\_worker\_memory\_limit) | Memory limit for n8n worker pods (e.g. 2Gi, 4Gi) | `string` | `"2Gi"` | no |
| <a name="input_n8n_worker_memory_request"></a> [n8n\_worker\_memory\_request](#input\_n8n\_worker\_memory\_request) | Memory request for n8n worker pods (e.g. 1Gi, 2Gi) | `string` | `"1Gi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace to deploy n8n into | `string` | `"n8n"` | no |
| <a name="input_node_desired"></a> [node\_desired](#input\_node\_desired) | Initial number of worker nodes. Only applies at creation: the node group's desired\_size ignores changes afterward so the Cluster Autoscaler can own it without fighting plans/applies. | `number` | `3` | no |
| <a name="input_node_instance_type"></a> [node\_instance\_type](#input\_node\_instance\_type) | EC2 instance type for EKS worker nodes. t3.xlarge (4 vCPU, 16GB) is the recommended minimum for multi-main — the 6 n8n pods (main × 2, worker × 2, webhook × 2) request ~3,600m CPU at minimum replicas, leaving t3.medium nodes with insufficient headroom for HPA to scale. | `string` | `"t3.xlarge"` | no |
| <a name="input_node_max"></a> [node\_max](#input\_node\_max) | Maximum number of worker nodes. This is the ceiling the Cluster Autoscaler scales to, so node\_max × node\_instance\_type is the hard cap on schedulable CPU: the autoscaler maxima (n8n\_main\_hpa\_max\_replicas, n8n\_webhook\_hpa\_max\_replicas, n8n\_worker\_keda\_max\_replicas) and the per-pod CPU requests have to fit inside it. The module warns at plan time when they do not; see README.md → "Sizing autoscaling against node capacity". | `number` | `6` | no |
| <a name="input_node_min"></a> [node\_min](#input\_node\_min) | Minimum number of worker nodes | `number` | `3` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | IDs of private subnets (one per AZ, minimum two AZs). RDS, ElastiCache, and EKS nodes attach here. | `list(string)` | n/a | yes |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | IDs of public subnets (one per AZ, minimum two AZs). The ALB attaches here. | `list(string)` | n/a | yes |
| <a name="input_redis_node_type"></a> [redis\_node\_type](#input\_redis\_node\_type) | ElastiCache node type (cache.t3.medium ~$25/month) | `string` | `"cache.t3.medium"` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain (e.g. the zone for example.com if n8n\_domain = n8n.example.com). When set, the module issues a DNS-validated ACM certificate and creates the alias A-record automatically — single terraform apply, no manual DNS steps. Leave null and pass certificate\_arn instead. Set exactly one of certificate\_arn or route53\_zone\_id. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to all resources this module creates. Merged on top of the built-in ManagedBy/Project tags. | `map(string)` | `{}` | no |
| <a name="input_vpc_cidr_block"></a> [vpc\_cidr\_block](#input\_vpc\_cidr\_block) | CIDR block of the VPC — used by the RDS and Redis security groups to allow intra-VPC traffic. | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC n8n will deploy into. Must contain both public and private subnets with the EKS/ALB subnet tags applied. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname of the module-managed Ingress. When route53\_zone\_id is set, the module already creates the alias record, so this output is informational. When certificate\_arn is used, create a CNAME: your domain → this value. Null when create\_ingress = false, since the caller then owns the load balancers. |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | AWS region |
| <a name="output_certificate_arn"></a> [certificate\_arn](#output\_certificate\_arn) | ARN of the ACM certificate n8n is served with. When route53\_zone\_id is set this is the module-issued certificate, already validated, covering n8n\_domain plus every entry in n8n\_additional\_domains. When certificate\_arn is supplied instead, it is echoed back unchanged. A caller owning its own Ingress resources (create\_ingress = false) attaches this to their alb.ingress.kubernetes.io/certificate-arn annotation, which lets the module issue and validate a multi-name certificate on their behalf rather than the caller hand-rolling one. Sourced from aws\_acm\_certificate\_validation, so consuming it orders the caller's resources after validation completes. |
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Base64-encoded EKS cluster CA certificate — pass to kubernetes/helm providers as cluster\_ca\_certificate (after base64decode). |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | EKS cluster API endpoint — pass to the kubernetes/helm providers as host. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | EKS cluster name |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | Database password — module-managed when create\_database = true, or the value of var.db\_password when using an external database. Retrieve with: terraform output -raw db\_password |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key — back this up in a password manager. Losing it makes all stored credentials unreadable. |
| <a name="output_n8n_service_name"></a> [n8n\_service\_name](#output\_n8n\_service\_name) | Name of the Kubernetes Service fronting the n8n main pods (the editor UI and REST API), on port 5678. Point a bring-your-own Ingress at this when create\_ingress = false. |
| <a name="output_n8n_service_port"></a> [n8n\_service\_port](#output\_n8n\_service\_port) | Port both n8n Services listen on. Use with n8n\_service\_name / n8n\_webhook\_service\_name when building your own Ingress. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once DNS propagates |
| <a name="output_n8n_webhook_path_prefixes"></a> [n8n\_webhook\_path\_prefixes](#output\_n8n\_webhook\_path\_prefixes) | Path prefixes that must be routed to n8n\_webhook\_service\_name rather than n8n\_service\_name. The main pods run with production webhooks disabled, so every one of these returns 404 if it reaches them: /webhook, /webhook-waiting (also carries the Slack and Telegram human-in-the-loop callbacks), /form, /form-waiting, and /mcp. Route all of them when building your own Ingress with create\_ingress = false. |
| <a name="output_n8n_webhook_service_name"></a> [n8n\_webhook\_service\_name](#output\_n8n\_webhook\_service\_name) | Name of the Kubernetes Service fronting the n8n webhook processors, on port 5678. Production webhooks are disabled on the main pods, so a bring-your-own Ingress must route /webhook here. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
| <a name="output_rds_endpoint"></a> [rds\_endpoint](#output\_rds\_endpoint) | Database endpoint — module-managed RDS when create\_database = true, or the value of var.db\_host when using an external database (e.g. Aurora). |
| <a name="output_redis_endpoint"></a> [redis\_endpoint](#output\_redis\_endpoint) | ElastiCache Redis endpoint |
| <a name="output_s3_bucket_name"></a> [s3\_bucket\_name](#output\_s3\_bucket\_name) | S3 bucket used for n8n binary storage, and for execution data when n8n\_execution\_data\_storage\_mode = "s3". The module attaches no lifecycle configuration: binary data is pruned only by S3 while execution data is pruned by n8n itself, and the two cannot be separated by a prefix filter. Read the S3 lifecycle section of the README before attaching one. |
<!-- END_TF_DOCS -->

