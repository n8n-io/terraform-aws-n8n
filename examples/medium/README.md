# n8n on AWS — Medium Deployment

Production-grade n8n for **~5–15M executions per day** (~60–175 req/s average). Uses Route53 for automated DNS and certificate management.

## Architecture

```
Route 53 (alias A-record)
    └─► ALB (AWS LBC) ──► EKS (5–15 × m6i.2xlarge)
                               ├─► n8n main pods (HPA, min=3 / max=24)
                               ├─► n8n webhook processors (HPA, min=5 / max=50)
                               └─► n8n workers (KEDA, min=5 / max=40)
                                        ├─► RDS PostgreSQL db.m6g.2xlarge (Multi-AZ)
                                        └─► ElastiCache Redis cache.r6g.large
```

## Key sizing decisions

| Resource | Value | Rationale |
|---|---|---|
| Node type | m6i.2xlarge (8 vCPU, 32 GB) | ~3× the starter; 5 nodes = 40 vCPU cluster headroom |
| Node count | desired=5, min=5, max=15 | Warm floor prevents cold-start delays on traffic spikes |
| DB class | db.m6g.2xlarge | Memory-optimized; keeps execution_entity working set in shared_buffers |
| DB storage | 200 GB gp3 | 3,000 baseline IOPS (vs gp2 burst); no IOPS ceiling at this throughput |
| Redis | cache.r6g.large | ~4× the memory of cache.t3.medium; comfortable headroom at 175 req/s |
| Main pods | min=3, max=24 | Mains serve the editor and REST API only, not webhooks or manual executions, so the ceiling tracks concurrent users rather than executions/day; 4× the module default, matching how the worker ceiling scales. Floor of 3 keeps two serving the editor through a node drain |
| Webhook pods | min=5, max=50 | Floor of 5 is warm; 50 ceiling raises both the floor and the ceiling over the module default of 2/8 |
| Worker pods | min=5, max=40 | Queue-driven via KEDA; floor ensures fast queue drain at any time |
| Worker concurrency | 20 | Doubles throughput per pod vs default; pool_size=10 matches |
| Pruning | 7 days / 500k records | Keeps execution_entity at manageable size without losing debug history |
| Webhook memory | 2 Gi limit | 1 Gi limit is tight under sustained concurrent webhook load |

## Estimated cost (us-east-1, on-demand)

| Resource | Monthly |
|---|---|
| EKS nodes (5 × m6i.2xlarge) | ~$1,402 |
| RDS db.m6g.2xlarge (Multi-AZ) | ~$560 |
| ElastiCache cache.r6g.large | ~$121 |
| EKS control plane | ~$73 |
| NAT Gateway | ~$35 |
| **Total** | **~$2,200** |

1-year Reserved Instances reduce compute ~35% → ~$1,430/month.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform apply
```

After apply, retrieve credentials:

```bash
terraform output -raw db_password
terraform output -raw n8n_encryption_key
```

Configure kubectl:

```bash
$(terraform output -raw kubectl_config_command)
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

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
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
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-medium"` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra hostnames n8n should answer on, beyond n8n\_domain. Each is added to the module-issued ACM certificate as a subject alternative name, given a Route 53 validation record and alias A-record, and routed by the module's Ingress. Leave empty for a single hostname. | `list(string)` | `[]` | no |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data, which is the main lever for relieving write pressure on the database at this tier's volume. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. Read the execution data section of the root README before enabling it, in particular the durability trade-off and the S3 lifecycle constraint. | `string` | `"database"` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff. | `string` | `null` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname. The alias A-record for n8n\_domain is already created in Route53 — this output is informational. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password — back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key — back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
<!-- END_TF_DOCS -->
