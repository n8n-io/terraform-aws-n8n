# Worker pools example

Sizing-equivalent to [`small`](../small/) apart from `node_max`, with one topology change: three labelled **worker pools** run beside the chart's own unlabelled worker deployment, each with its own replica bounds, sizing and autoscaler.

`node_max` goes from small's 6 to 8. Pools are additional autoscalers on the same node group rather than a redistribution of the ceilings already there, so their pods have to fit alongside the main, default-worker and webhook maxima. See the comment on `node_max` in `main.tf` for the arithmetic.

> **Budget database connections before raising these ceilings.** Node capacity is not the only thing extra pools consume. Every n8n process opens up to `db_postgresdb_pool_size` connections (default 10), so the ceiling here is roughly 6 main + 10 default worker + 8 webhook + 10 pool pods, about 34 processes, or ~340 connections against a `db.t3.small` whose `max_connections` is around 225. That budget is already tight in [`small`](../small/) before any pool is added, and pools make it tighter rather than causing it. The module does not manage a connection pooler, so if you intend to run near these maxima rather than at the floors, raise `db_instance_class`, lower `db_postgresdb_pool_size`, or put PgBouncer in front. At the replica floors this example actually runs at, the draw is a small fraction of that.

n8n's worker pools pin a project's executions to a named set of workers. A worker started with `N8N_WORKER_POOL_NAME=<name>` stops consuming the default `jobs` Bull queue and consumes `jobs-<name>` instead; a project assigned to that pool has its executions enqueued there. Assign a project to a pool in the n8n UI under **Project, Settings, Worker Pools**.

Use this example when some executions need different hardware or isolation: heavier jobs on bigger workers, or one team's projects kept off the shared pool.

> **Worker pools are an alpha n8n feature, and the chart side is not released yet.** This example is kept as a draft until both ship. What it needs today:
>
> - **n8n 2.39.0 or later** on the image. That is the first release that reads `N8N_WORKER_POOLS_ENABLED` and `N8N_WORKER_POOL_NAME`; an older image accepts both and ignores them. At the time of writing 2.39.0 is on the `next` tag and `stable` is still 2.38.x, so pin `n8n_image_tag` rather than trusting the chart's floating default.
> - **A licence carrying `feat:workerPools`**, which gates the pool settings API and the routing itself. Without it every project resolves to the default queue, silently.
> - **A Helm chart that renders `queueMode.workerGroups`.** No published chart version does (the newest, 1.11.0, does not); the feature is [n8n-io/n8n-hosting#189](https://github.com/n8n-io/n8n-hosting/pull/189), open against a `preview/worker-pools` branch. Until it is released you package a preview build yourself and push it to a registry you control, which is why `n8n_chart_version` is a required input of this example and the module warns at plan when the pinned chart predates the feature. See "Getting a chart that renders pools" below.
>
> Treat this example as non-production until all three are released.

## What it creates

- Everything [`small`](../small/) creates: VPC, ACM certificate with Route53 validation, EKS, RDS PostgreSQL, ElastiCache Redis, S3, the controllers, and the n8n Helm release
- Three additional worker Deployments (`n8n-worker-gpu`, `n8n-worker-secteam`, `n8n-worker-itop`), each with its own KEDA `ScaledObject` of the same name watching that pool's own `jobs-<name>` queue. **Only with a chart that renders `queueMode.workerGroups`**; an older chart accepts the key and renders none of this, which is the failure [`verify-worker-pools.sh`](../../tests/scripts/verify-worker-pools.sh) exists to catch.
- `N8N_WORKER_POOLS_ENABLED` across mains, workers and webhook pods, emitted automatically because pools are declared

## The pool topology

Defined in [`main.tf`](./main.tf) as a local rather than a variable, since the topology is the point of the example rather than a knob (a local is also reachable from the example's tests, where a literal at the module call site would not be):

| Pool | Replicas | Concurrency | Sizing | Why |
|---|---|---|---|---|
| *(unlabelled)* | 1 to 10 | module default | module default | Serves the default `jobs` queue for every unpinned project |
| `gpu` | 1 to 4 | 5 | 1-2 vCPU, 2-4 GiB | Heavier executions, fewer jobs per worker |
| `secteam` | 1 to 3 | module default | module default | Isolation for one team's projects |
| `itop` | 0 to 3 | module default | module default | Scales to zero when idle |

A pool with no live workers is not an error. Projects pinned to it fall back to the default queue until KEDA scales it back up, so `itop` costs nothing while idle.

Pool names are lowercase letters, digits and hyphens, 1 to 43 characters, starting and ending alphanumeric. The 43 comes from KEDA by way of the chart: the pool's ScaledObject is named `n8n-worker-<name>`, KEDA caps that at 54 characters because it doubles as a label value and as part of the generated HPA's name, and the chart fails the render past it. The chart's own schema allows 53, but that only holds for a shorter release name than the module's fixed `n8n`, so the module enforces the tighter figure and a name cannot pass plan and fail at apply. The module rejects anything else at plan time, because n8n itself only logs a warning for a bad name and then starts the worker on the default queue, which leaves a Ready pod quietly serving the wrong jobs. `default` is rejected too: it would mean a queue named `jobs-default`, which is not the real default queue.

## Prerequisites

- A Route53 hosted zone for the parent domain (e.g. `example.com` if `n8n_domain = n8n.example.com`). Note its zone ID.
- An n8n Enterprise licence carrying `feat:workerPools`. For a multi-main deployment (the default) it also needs `feat:multipleMainInstances`; set `n8n_main_hpa_min_replicas = 1` to run single-main on a Business-tier licence, as `small` allows.
- A chart that renders `queueMode.workerGroups`, pushed to a registry the cluster and your workstation can both reach. See the next section.
- `helm` 3.8+ and the AWS CLI on your workstation, for packaging and pushing that chart.

## Getting a chart that renders pools

Skip this section once a released chart carries `queueMode.workerGroups`: pin that version in `n8n_chart_version`, leave `n8n_chart_repository` at its default, and apply.

Until then, package the chart from the feature PR and push it to an ECR repository in the account you deploy to. The node group's IAM role pulls from same-account ECR without any extra configuration, and the Helm provider on your workstation authenticates with the usual `helm registry login`.

```bash
AWS_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
CHART_VERSION="1.11.0-preview.workerpools.1"   # base version of the PR's Chart.yaml, plus a prerelease suffix

# 1. Check out the PR. gh resolves the fork; plain git needs the fork's URL.
git clone https://github.com/n8n-io/n8n-hosting.git /tmp/n8n-hosting
cd /tmp/n8n-hosting
gh pr checkout 189

# 2. Lint and render once locally, with this example's values shape, before pushing.
helm lint charts/n8n -f charts/n8n/ci/workerGroups-values.yaml
helm template n8n charts/n8n -f charts/n8n/ci/workerGroups-values.yaml \
  | grep -E '^kind: (Deployment|ScaledObject)$' | sort | uniq -c

# 3. Package with a prerelease version. Helm never picks a prerelease up by
#    accident, and the module's chart-version check takes one at your word.
helm package charts/n8n --version "$CHART_VERSION" --destination /tmp/chart-pkg

# 4. Push to ECR. The OCI path is <registry>/<repo>/<chart name>, so the ECR
#    repository is named n8n-helm-chart/n8n and the module is pointed at the
#    parent path, exactly as it is for the public ghcr.io default.
aws ecr create-repository --repository-name n8n-helm-chart/n8n --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ecr get-login-password --region "$AWS_REGION" | helm registry login --username AWS --password-stdin "$REGISTRY"
helm push "/tmp/chart-pkg/n8n-$CHART_VERSION.tgz" "oci://$REGISTRY/n8n-helm-chart"

# 5. Confirm the module will find it.
helm show chart "oci://$REGISTRY/n8n-helm-chart/n8n" --version "$CHART_VERSION" | head -5
```

Then in `terraform.tfvars`:

```hcl
n8n_chart_version    = "1.11.0-preview.workerpools.1"
n8n_chart_repository = "oci://123456789012.dkr.ecr.us-east-1.amazonaws.com/n8n-helm-chart"
n8n_image_tag        = "2.39.0"
```

The `helm registry login` is per workstation session; if a later `terraform apply` fails with `unauthorized` on the chart pull, run step 4's login line again. ECR tokens last 12 hours.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, route53_zone_id, n8n_license_key,
# n8n_chart_version, n8n_chart_repository and n8n_image_tag.

terraform init
terraform plan    # expect no "worker_pools_require_*" warnings; if one appears, fix the pin before applying
terraform apply
```

## Verifying the pools

Run the scripted check first. It reads `worker_pool_names` and `namespace` from this example's outputs and counts what the cluster actually has against them, which is the one check that catches a chart that ignored `queueMode.workerGroups`:

```bash
../../tests/scripts/verify-worker-pools.sh
```

It asserts, per pool: the `n8n-worker-<pool>` Deployment and ScaledObject exist and carry the `n8n.io/worker-pool` label; the ScaledObject is `READY=True` and its triggers watch `bull:jobs-<pool>:wait` / `:active` with the same TLS and AUTH metadata the default worker's triggers carry; running pool pods have `N8N_WORKER_POOL_NAME` set; the main Deployment has `N8N_WORKER_POOLS_ENABLED=true`; and KEDA's external metric for the pool's queue resolves. It also fails if the cluster has pool Deployments the outputs do not list.

By hand, the same thing:

```bash
eval "$(terraform output -raw kubectl_config_command)"

# One Deployment and one ScaledObject per pool. The chart labels them
# component=worker-group (not worker: the default worker's selector is
# immutable and must not match pool pods) and n8n.io/worker-pool=<name>.
kubectl -n n8n get deploy,scaledobject -l app.kubernetes.io/component=worker-group

# The pool name reached the pods.
kubectl -n n8n get pods -l n8n.io/worker-pool=gpu \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="n8n-worker")].env[?(@.name=="N8N_WORKER_POOL_NAME")].value}{"\n"}{end}'
```

The pools also appear in the n8n UI under **Settings, Workers**, which shows each worker's pool and queue, and in a project's **Worker Pools** settings once a worker for that pool is running.

### An end-to-end execution on a pool

The scripted check proves the topology exists; this proves routing. Nothing in the module can do it for you because assigning a project to a pool is a UI (or internal API) action, not a Terraform one.

1. In n8n, open a project, then **Settings, Worker Pools**, and assign it to `gpu`.
2. Create a trivial workflow in that project (Manual Trigger, then a Wait node of ~20 seconds so it stays visible) and run it.
3. While it runs, the execution should be on a `gpu` pod and nowhere else:

   ```bash
   # The gpu pool picked it up: one of these pods logs the execution id.
   kubectl -n n8n logs -l n8n.io/worker-pool=gpu -c n8n-worker --since=2m | grep -i 'execution'

   # The default workers did not.
   kubectl -n n8n logs -l app.kubernetes.io/component=worker -c n8n-worker --since=2m | grep -i 'execution' || echo "default workers idle, as expected"

   # The queue depth KEDA scales gpu on (0 once the worker has taken the job).
   kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/s0-redis-bull-jobs-gpu-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-gpu"
   ```

4. Scale-to-zero, which is the case most worth testing because two claims in this repo depend on it and neither has been verified against a running n8n. The comments in `main.tf` and the module say a project pinned to a pool with **no live workers** falls back to the default queue. If that is literally true, a pool parked at 0 never accumulates queue depth, KEDA never sees a reason to scale it up, and `min_replicas = 0` is a trap rather than a saving. Assign a second project to `itop`, run a workflow in it, and watch both at once:

   ```bash
   kubectl -n n8n get deploy n8n-worker-itop -w &
   kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/s0-redis-bull-jobs-itop-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-itop"
   ```

   Three outcomes are possible, and the README and module comments need correcting for whichever you see: (a) the job waits on `jobs-itop`, the metric goes to 1, KEDA scales the Deployment to 1 within a polling interval (15 s) and the job runs on the new pod, then the pool returns to 0 after the cooldown (60 s): scale-to-zero works as documented; (b) the job runs immediately on a default worker and the metric stays 0: the fallback is real and `min_replicas = 0` should be documented as "parked pools receive nothing", not as a saving; (c) the job sits in `jobs-itop` and nothing scales: a KEDA or trigger problem, look at `kubectl -n n8n describe scaledobject n8n-worker-itop`.
5. Negative control: unassign the project from `gpu`, run again, and confirm the execution now lands on a default worker.

### Checking a pool's autoscaler

A pool that cannot reach Redis does not crash. It sits at its `min_replicas` and the queue simply never drains, so it is worth knowing which signal actually tells you.

```bash
# READY=True is the one to trust. A scaler that cannot reach Redis reads False.
kubectl -n n8n get scaledobject

# Queue depth as KEDA sees it, per pool.
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/n8n/\
s0-redis-bull-jobs-gpu-wait?labelSelector=scaledobject.keda.sh/name=n8n-worker-gpu"
```

Do not read `kubectl get hpa` for this. Its TARGETS column shows `<unknown>` for a KEDA-backed worker HPA whether the scaler is healthy or broken, so it gives a false alarm either way. When something is genuinely wrong, `kubectl -n keda logs -l app=keda-operator` says so in as many words, usually `connection to redis failed: i/o timeout`.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for activating your n8n Enterprise license.

## Teardown


```bash
terraform destroy
```

## Production considerations

This example is a reference deployment optimized for clean `apply` / `destroy` cycles during evaluation. The module ships with teardown-friendly defaults that you should review before promoting to production:

| Where (in the module) | Setting | Current | Production |
|---|---|---|---|
| `database.tf` | `aws_db_instance.n8n.deletion_protection` | `false` (provider default; not set) | `true` |
| `database.tf` | `aws_db_instance.n8n.skip_final_snapshot` | `true` | `false`, plus set `final_snapshot_identifier` |
| `database.tf` | `aws_db_instance.n8n.delete_automated_backups` | `true` | `false` |
| `s3.tf` | `aws_s3_bucket.n8n.force_destroy` | `true` | `false` |

These settings live in the module's `database.tf` and `s3.tf` and are not currently exposed as variables. To override them you would wrap or fork the module.

<!-- The block below is auto-generated by terraform-docs. Run `terraform-docs markdown table --output-file README.md --output-mode inject .` to refresh it. -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer, because the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra hostnames n8n should answer on, beyond n8n\_domain. Each is added to the module-issued ACM certificate as a subject alternative name, given a Route 53 validation record and alias A-record, and routed by the module's Ingress. Leave empty for a single hostname. | `list(string)` | `[]` | no |
| <a name="input_n8n_chart_repository"></a> [n8n\_chart\_repository](#input\_n8n\_chart\_repository) | Helm chart repository the module pulls the n8n chart from, passed to the module's n8n\_chart\_repository. The default is the module's own default, the public upstream registry, which is right once a released chart renders pools. Until then, point it at a registry you pushed a preview build to, e.g. oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n-helm-chart. The node group's IAM role can pull from ECR in the same account without extra configuration; the Helm provider on your workstation needs `aws ecr get-login-password | helm registry login` first. | `string` | `"oci://ghcr.io/n8n-io/n8n-helm-chart"` | no |
| <a name="input_n8n_chart_version"></a> [n8n\_chart\_version](#input\_n8n\_chart\_version) | n8n Helm chart version to deploy, passed to the module's n8n\_chart\_version. Required by this example because the module default predates queueMode.workerGroups and would render no pools. Pin the first release that carries the feature once it exists, or a preview build (e.g. 1.11.0-preview.workerpools.1) pushed to the registry named by n8n\_chart\_repository. | `string` | n/a | yes |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data. This example runs the module's default database (db.t3.small on 50 GB of gp2, a 150 IOPS baseline), which has the least room of any sizing this module ships to absorb execution-data growth, so reaching for this is often cheaper than resizing the database. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint. | `string` | `"database"` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum (and therefore default) replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main, needs an Enterprise/Startup license carrying feat:multipleMainInstances). Set to 1 to run a single main pod in plain queue mode instead, which only needs a Business-tier license: n8n's multi-main leader-election gate never engages at 1 replica. Worker pools need feat:workerPools on top of either. | `number` | `null` | no |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff. | `string` | `null` | no |
| <a name="input_n8n_worker_keda_max_replicas"></a> [n8n\_worker\_keda\_max\_replicas](#input\_n8n\_worker\_keda\_max\_replicas) | Maximum worker replicas KEDA may scale the default (unlabelled) worker deployment to. | `number` | `10` | no |
| <a name="input_n8n_worker_keda_min_replicas"></a> [n8n\_worker\_keda\_min\_replicas](#input\_n8n\_worker\_keda\_min\_replicas) | Minimum worker replicas KEDA keeps running for the default (unlabelled) worker deployment. | `number` | `1` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain (e.g. the zone for example.com if n8n\_domain = n8n.example.com). The module creates the ACM certificate, validation records, and alias A-record inside this zone. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname. The alias A-record for n8n\_domain is already created in Route53, so this output is informational. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password. Back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. Read by tests/scripts/smoke-test.sh. |
| <a name="output_worker_pool_names"></a> [worker\_pool\_names](#output\_worker\_pool\_names) | Names of the worker pools this example declares, in declaration order. Read by tests/scripts/verify-worker-pools.sh, which counts the rendered pool Deployments and ScaledObjects against this list: the chart-predates-pools failure leaves this list non-empty and the cluster with nothing behind it, and only a live count can see that. |
<!-- END_TF_DOCS -->
