# Worker pools example

Sizing-equivalent to [`small`](../small/) apart from `node_max`, with one topology change: three labelled **worker pools** run beside the chart's own unlabelled worker deployment, each with its own replica bounds, sizing and autoscaler.

`node_max` goes from small's 6 to 8. Pools are additional autoscalers on the same node group rather than a redistribution of the ceilings already there, so their pods have to fit alongside the main, default-worker and webhook maxima. See the comment on `node_max` in `main.tf` for the arithmetic.

n8n's worker pools pin a project's executions to a named set of workers. A worker started with `N8N_WORKER_POOL_NAME=<name>` stops consuming the default `jobs` Bull queue and consumes `jobs-<name>` instead; a project assigned to that pool has its executions enqueued there. Assign a project to a pool in the n8n UI under **Project, Settings, Worker Pools**.

Use this example when some executions need different hardware or isolation: heavier jobs on bigger workers, or one team's projects kept off the shared pool.

> **Worker pools are an alpha n8n feature.** They need an n8n version that ships them and a licence with the entitlement that gates the pool settings API. Treat this example as non-production until that changes.

## What it creates

- Everything [`small`](../small/) creates: VPC, ACM certificate with Route53 validation, EKS, RDS PostgreSQL, ElastiCache Redis, S3, the controllers, and the n8n Helm release
- Three additional worker Deployments (`gpu`, `secteam`, `itop`), each with its own KEDA `ScaledObject` watching that pool's own `jobs-<name>` queue
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

Pool names are lowercase letters, digits and hyphens, 1 to 53 characters, starting and ending alphanumeric. The 53 comes from the chart, which uses the name for both the worker group (capped at 53) and the pool (63); the module enforces the tighter of the two so a name cannot pass plan and fail at apply. The module rejects anything else at plan time, because n8n itself only logs a warning for a bad name and then starts the worker on the default queue, which leaves a Ready pod quietly serving the wrong jobs. `default` is rejected too: it would mean a queue named `jobs-default`, which is not the real default queue.

## Prerequisites

- A Route53 hosted zone for the parent domain (e.g. `example.com` if `n8n_domain = n8n.example.com`). Note its zone ID.
- An n8n Enterprise licence whose entitlements include the workers view, which gates the pool settings API.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, route53_zone_id, n8n_license_key

terraform init
terraform apply
```

## Verifying the pools

```bash
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" --region us-east-1

# One Deployment and one ScaledObject per pool, plus the unlabelled default.
kubectl -n n8n get deploy,scaledobject -l app.kubernetes.io/component=worker

# Each pooled worker reports its pool and queue on startup.
kubectl -n n8n logs -l n8n.io/pool=gpu -c n8n-worker | grep -E '^ \* (Pool|Queue)'
```

The pools also appear in the n8n UI under **Settings, Workers**, which shows each worker's pool and queue, and in a project's **Worker Pools** settings once a worker for that pool is running.

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
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data. This example runs the module's default database (db.t3.small on 50 GB of gp2, a 150 IOPS baseline), which has the least room of any sizing this module ships to absorb execution-data growth, so reaching for this is often cheaper than resizing the database. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint. | `string` | `"database"` | no |
| <a name="input_n8n_extra_env"></a> [n8n\_extra\_env](#input\_n8n\_extra\_env) | Additional environment variables injected into all n8n pods via the chart's config.extraEnv list. | <pre>list(object({<br/>    name  = string<br/>    value = string<br/>  }))</pre> | `[]` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
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
<!-- END_TF_DOCS -->
