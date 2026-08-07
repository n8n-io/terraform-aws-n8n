# Customer-managed S3 bucket example

Points `terraform-aws-n8n` at an S3 bucket it does not own, instead of letting it create one.

Use this when binary storage (and optionally execution data) needs to land in a bucket your organization already manages, for example one with an existing lifecycle policy, replication configuration, or compliance-mandated bucket naming convention this module doesn't drive.

## What it creates

This example is two things layered together:

1. **A stand-in for infrastructure a customer already has.** `main.tf`'s "Customer-managed S3 bucket (stand-in)" section provisions an `aws_s3_bucket`, with its own public-access block and SSE-S3 encryption configuration, using plain Terraform resources entirely independent of the `terraform-aws-n8n` module. In a real deployment this section would not exist: your bucket would already exist, secured however its owner already configured it.
2. **Everything the `terraform-aws-n8n` module creates, except its S3 tier** (`create_s3_bucket = false`): VPC, EKS cluster, node group, RDS PostgreSQL, ElastiCache Redis, AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, and the n8n Helm release. The module attaches its IAM policy and Pod Identity role to the stand-in bucket, exactly as it would to a real customer-managed bucket.

## Why the stand-in bucket configures its own security

The module does not manage a public-access block or an encryption configuration on a bucket you supply via `existing_s3_bucket_name`: how a bucket you own is secured is your decision, not the module's (see `s3.tf` in the repo root, and `docs/customer-managed-infrastructure.md` for why this module doesn't add a plan-time check for it either: a data-source lookup like that hard-fails for anyone whose Terraform credentials can't read that specific bucket). This example's stand-in bucket configures both explicitly, itself, to model what a real customer-managed bucket's owner is expected to have already done.

## Adapting to your real infrastructure

To point this at a bucket you actually run instead of the stand-in:

1. Delete the entire "Customer-managed S3 bucket (stand-in)" section from `main.tf` (the `aws_s3_bucket`, `aws_s3_bucket_public_access_block`, and `aws_s3_bucket_server_side_encryption_configuration` resources), and the `data "aws_caller_identity" "current"` block if nothing else in your configuration needs it.
2. In `module "n8n"`, replace `existing_s3_bucket_name` with your own bucket's name:
   ```hcl
   create_s3_bucket        = false
   existing_s3_bucket_name = "your-existing-bucket-name"
   ```
3. If your bucket is encrypted with a Customer Managed KMS Key (SSE-KMS), also set `s3_kms_key_arn` to that key's ARN. The pod role needs `kms:Decrypt`/`kms:GenerateDataKey` permissions on that key to read and write the bucket at all; the module cannot see the bucket's encryption configuration to infer them.

See the root [README.md → "Customer-managed infrastructure"](../../README.md#customer-managed-infrastructure) and the `existing_s3_bucket_name` / `s3_kms_key_arn` entries in the Inputs table for the full details on this toggle.

## Prerequisites

- A Route53 hosted zone for the parent domain (e.g. `example.com` if `n8n_domain = n8n.example.com`). Note its zone ID.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, route53_zone_id, n8n_license_key

terraform init
terraform apply
```

After apply, see the root [`docs/post-deployment.md`](../../docs/post-deployment.md) for DNS propagation and license activation.

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
| [aws_s3_bucket.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_public_access_block.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer: the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_customer_managed_s3_force_destroy"></a> [customer\_managed\_s3\_force\_destroy](#input\_customer\_managed\_s3\_force\_destroy) | Whether the stand-in bucket this example creates can be destroyed while it still holds objects. true here only so `terraform destroy` doesn't fail on a demo bucket; a real customer-managed bucket's lifecycle, including whether it can be force-destroyed, is that bucket owner's decision, not this module's or this example's. | `bool` | `true` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra hostnames n8n should answer on, beyond n8n\_domain. Each is added to the module-issued ACM certificate as a subject alternative name, given a Route 53 validation record and alias A-record, and routed by the module's Ingress. Leave empty for a single hostname. | `list(string)` | `[]` | no |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. | `string` | `"database"` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff. | `string` | `null` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain (e.g. the zone for example.com if n8n\_domain = n8n.example.com). The module creates the ACM certificate, validation records, and alias A-record inside this zone. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname. The alias A-record for n8n\_domain is already created in Route53. This output is informational. |
| <a name="output_customer_managed_s3_bucket_name"></a> [customer\_managed\_s3\_bucket\_name](#output\_customer\_managed\_s3\_bucket\_name) | Name of the stand-in bucket this example creates, playing the part of a customer's existing S3 bucket. This is the value that fills module.n8n's existing\_s3\_bucket\_name in this example; in a real deployment it would be your own bucket's name instead. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password. Back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
<!-- END_TF_DOCS -->
