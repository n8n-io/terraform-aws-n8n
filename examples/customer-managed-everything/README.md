# Customer-managed everything example

Every layer `terraform-aws-n8n` can create, instead handed a customer-managed one: EKS cluster, RDS PostgreSQL, ElastiCache Redis, S3 bucket, and every cluster controller (AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, EBS CSI driver). n8n is layered on top, consuming all of it, owning none of it.

Use this as the comprehensive reference for a platform team that already runs everything: a shared EKS cluster, a shared database and cache tier, a shared bucket convention, and its own controller installs, who want n8n deployed onto that estate rather than getting a dedicated stack. It is also a demonstration of why `modules/controllers` was extracted from the root module: this example invokes that submodule directly, exactly the pattern that extraction exists for.

For the single-layer version of this same pattern, see [`examples/customer-managed-cluster`](../customer-managed-cluster/), [`examples/customer-managed-redis`](../customer-managed-redis/), and [`examples/customer-managed-s3`](../customer-managed-s3/). This example combines all three, plus the controllers.

## What it creates

This example is two things layered together, same shape as the single-layer examples, just with every layer at once:

1. **Stand-ins for infrastructure a platform team already has**, all plain Terraform, entirely independent of the `terraform-aws-n8n` module:
   - An `aws_eks_cluster` with its own node group, IAM roles, and `eks-pod-identity-agent` addon (same as `examples/customer-managed-cluster`).
   - An `aws_db_instance` (RDS PostgreSQL) with its own subnet group and security group.
   - An `aws_elasticache_replication_group` with transit encryption required and an AUTH token (same as `examples/customer-managed-redis`).
   - An `aws_s3_bucket` with its own public-access block and SSE-S3 configuration (same as `examples/customer-managed-s3`).
   - A `kubernetes_ingress_v1` and its Route53 alias record, since `create_ingress = false` means the module itself owns none of that either; see "Why this example owns its own Ingress" below.
2. **A direct `module "controllers"` call** (`source = "../../modules/controllers"`), installing the AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, and the EBS CSI driver against the stand-in cluster, standing in for whatever a platform team's own GitOps or IaC would install onto its shared cluster.
3. **`module "n8n"`**, with every layer wired to the stand-ins above and every controller toggle set to `false`, since `module.controllers` above is installing them instead:

   | Layer | Toggle | Wired to |
   |---|---|---|
   | EKS cluster | `create_eks = false` | `aws_eks_cluster.customer_managed.name` |
   | RDS PostgreSQL | `create_database = false` | `aws_db_instance.customer_managed.address` |
   | ElastiCache Redis | `create_elasticache = false` | `aws_elasticache_replication_group.customer_managed.primary_endpoint_address` |
   | S3 bucket | `create_s3_bucket = false` | `aws_s3_bucket.customer_managed.id` |
   | LBC | `install_lbc = false` | installed by `module.controllers` instead |
   | Cluster Autoscaler | `install_cluster_autoscaler = false` | installed by `module.controllers` instead |
   | metrics-server | `install_metrics_server = false` | installed by `module.controllers` instead |
   | KEDA | `install_keda = false` | installed by `module.controllers` instead |
   | EBS CSI driver | `create_ebs_csi = false` | installed by `module.controllers` instead |
   | Ingress | `create_ingress = false` | this example's own `kubernetes_ingress_v1.n8n` (`ingress.tf`) |

## Why this example owns its own Ingress

`install_lbc = false` carries a hard plan-time validation: it's incompatible with `create_ingress = true`, because the module's own Ingress waits for an ALB (`wait_for_load_balancer = true`) from an LBC it thinks it never installed, and that wait times out the apply. The validation's own error message names the fix: set `create_ingress = false` and point your own Ingress resources at an LBC you install another way. That's exactly what `ingress.tf` and `dns.tf` do here: a single ALB Ingress, routed the same way the module's own would be (webhook path prefixes to the webhook processors, everything else to the mains), pointed at the ALB that the directly-invoked `module.controllers`' LBC provisions, with this example owning the Route53 alias record the module would otherwise have created.

## A note on the provider/dependency ordering

`providers.tf` configures the `kubernetes`/`helm` providers against `module.n8n`'s `cluster_endpoint`/`cluster_certificate_authority_data` outputs, the same as every other example. `module.controllers` uses those same providers (it has its own `helm_release` and `kubernetes_storage_class_v1` resources), which means `module.controllers` already depends on `module.n8n` implicitly, through the provider configuration, before any explicit `depends_on` is written. `module.n8n` deliberately has no `depends_on module.controllers`: adding one creates a genuine dependency cycle (confirmed directly: `terraform validate` reports one). `ingress.tf`'s own Ingress depends on both modules explicitly instead, since it needs the Services `module.n8n` creates and the LBC `module.controllers` installs.

## Adapting to your real infrastructure

To point this at infrastructure you actually run instead of the stand-ins, layer by layer:

- **Cluster**: delete the "Customer-managed EKS cluster (stand-in)" section of `main.tf` and the `kubernetes_version`/`customer_managed_node_*` variables it used; set `existing_eks_cluster_name` to your cluster's name. See `examples/customer-managed-cluster`'s README for the four `existing_eks_cluster_prerequisites_confirmed` items you need to verify yourself on a real shared cluster, and for the `eks-pod-identity-agent` hard prerequisite.
- **Database**: delete the "Customer-managed RDS" section and `customer_managed_db_*` variables; set `db_host`/`db_password` to your own database's endpoint and password.
- **Redis**: delete the "Customer-managed Redis" section and `customer_managed_redis_*` variables; set `redis_host`/`redis_auth_token`/`redis_transit_encryption_enabled` to your own Redis's coordinates. See `examples/customer-managed-redis`'s README for the AUTH/TLS specifics.
- **S3**: delete the "Customer-managed S3" section and `customer_managed_s3_force_destroy`; set `existing_s3_bucket_name` to your own bucket's name.
- **Controllers**: if your platform team's own GitOps already installs LBC/Cluster Autoscaler/metrics-server/KEDA/EBS CSI, delete the `module "controllers"` call entirely; the IAM roles and Pod Identity associations those controllers need still have to exist somewhere, though, so either keep invoking `modules/controllers` (with only the toggles you actually need, `install_*` per-controller) for the IAM wiring alone, or otherwise make sure each ServiceAccount's Pod Identity binding is provisioned another way.
- **Ingress**: if your platform team fronts everything with its own Ingress/ALB convention, delete `ingress.tf`/`dns.tf` and set `create_ingress = false` with no replacement Ingress here, wiring your own routing to `module.n8n`'s `n8n_service_name`/`n8n_webhook_service_name` outputs instead.

See the root [README.md → "Customer-managed infrastructure"](../../README.md#customer-managed-infrastructure) for the full state matrix, and [`docs/customer-managed-infrastructure.md`](../../docs/customer-managed-infrastructure.md) for the convention behind every toggle used here.

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

## A note on test coverage

Same structural limitation as [`examples/customer-managed-cluster`](../customer-managed-cluster/), and worse here: this example adds more check blocks that hit the same `data.aws_eks_cluster.existing`-under-mocking problem once `create_database` and `create_elasticache` are also `false`. A normal, successful-plan assertion of this example's own wiring is not achievable under `command = plan` with mocked providers. Three `expect_failures` run blocks do pass, on `cluster_name`, `customer_managed_redis_auth_token`, and `customer_managed_db_password`: each feeds a root-level stand-in resource's argument directly, which cascades widely enough to keep Terraform from reaching the unresolvable check blocks. See the comment at the top of `tests/defaults.tftest.hcl` for the full writeup, including which variables were tested and found NOT to have this property. `terraform validate`, `terraform fmt`, and `tflint` all pass against this example; exercising it end to end needs real AWS credentials.

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
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_controllers"></a> [controllers](#module\_controllers) | ../../modules/controllers | n/a |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_db_instance.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_eks_addon.customer_managed_pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_elasticache_replication_group.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group) | resource |
| [aws_elasticache_subnet_group.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_subnet_group) | resource |
| [aws_iam_role.customer_managed_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.customer_managed_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.customer_managed_cluster_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_route53_record.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_public_access_block.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_security_group.customer_managed_rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.customer_managed_redis](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [kubernetes_ingress_v1.n8n](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_lb.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/lb) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer: the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_customer_managed_db_engine_version"></a> [customer\_managed\_db\_engine\_version](#input\_customer\_managed\_db\_engine\_version) | PostgreSQL engine version for the stand-in database this example creates. Matches the module's own db\_engine\_version default. | `string` | `"18.4"` | no |
| <a name="input_customer_managed_db_instance_class"></a> [customer\_managed\_db\_instance\_class](#input\_customer\_managed\_db\_instance\_class) | RDS instance class for the stand-in database this example creates. Matches the module's own db\_instance\_class default (db.t3.small); a real customer-managed database would be sized for its own workload. | `string` | `"db.t3.small"` | no |
| <a name="input_customer_managed_db_password"></a> [customer\_managed\_db\_password](#input\_customer\_managed\_db\_password) | Master password for the stand-in database this example creates. Deliberately a plain variable, not a generated random\_password: this value is wired both into the stand-in's own password argument and into the module's db\_password, and a fresh random\_password.result is unknown until apply, which this example's Redis stand-in already ran into once (see customer\_managed\_redis\_auth\_token below and examples/customer-managed-redis's README for the full explanation of why that breaks a plan). A real customer-managed database's password is already a known secret the caller holds, not something Terraform generates in the same apply. The default below is fine for a disposable demo stack; generate and manage your own for anything that outlives one terraform destroy. | `string` | `"customer-managed-demo-db-password-change-me-1234"` | no |
| <a name="input_customer_managed_node_desired"></a> [customer\_managed\_node\_desired](#input\_customer\_managed\_node\_desired) | Initial number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node\_desired default). Only applies at creation: the node group's desired\_size ignores changes afterward so the Cluster Autoscaler this example installs directly (via module.controllers) can own it without fighting plans/applies. | `number` | `3` | no |
| <a name="input_customer_managed_node_instance_type"></a> [customer\_managed\_node\_instance\_type](#input\_customer\_managed\_node\_instance\_type) | EC2 instance type for the stand-in cluster's node group. Matches the module's own node\_instance\_type default (t3.xlarge), not a cheaper demo size: the module's own variable description warns that a full multi-main n8n workload (main x2, worker x2, webhook x2 pods at minimum replicas) needs at least this much headroom for HPA to have room to scale. | `string` | `"t3.xlarge"` | no |
| <a name="input_customer_managed_node_max"></a> [customer\_managed\_node\_max](#input\_customer\_managed\_node\_max) | Maximum number of worker nodes the Cluster Autoscaler can scale the stand-in node group to. Matches examples/small's implicit sizing (the module's own node\_max default). | `number` | `6` | no |
| <a name="input_customer_managed_node_min"></a> [customer\_managed\_node\_min](#input\_customer\_managed\_node\_min) | Minimum number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node\_min default). | `number` | `3` | no |
| <a name="input_customer_managed_redis_auth_token"></a> [customer\_managed\_redis\_auth\_token](#input\_customer\_managed\_redis\_auth\_token) | AUTH token for the stand-in replication group this example creates. Deliberately a plain variable, not a generated random\_password: a real customer-managed Redis's AUTH token is already a known secret the caller holds, not something Terraform generates in the same apply. That distinction is load-bearing here, not stylistic: this value is wired both into the stand-in's own auth\_token argument and into the module's redis\_auth\_token, and the module gates a resource count on whether redis\_auth\_token is null. A count expression can never depend on a value unknown until apply, which a fresh random\_password.result always is on its first create; wiring one in here would break terraform apply for every user of this example, not just its tests. The default below is fine for a disposable demo stack; generate and manage your own token for anything that outlives one terraform destroy. Must satisfy ElastiCache's AUTH constraints: 16-128 printable characters, and the only permitted non-alphanumerics are ! & # $ ^ < > -. https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/auth.html | `string` | `"customer-managed-demo-auth-token-change-me-1234"` | no |
| <a name="input_customer_managed_redis_node_type"></a> [customer\_managed\_redis\_node\_type](#input\_customer\_managed\_redis\_node\_type) | ElastiCache node type for the stand-in replication group this example creates. cache.t3.micro is the cheapest node type that supports encryption in transit; a real customer-managed Redis would be sized for its own workload, not this example's. | `string` | `"cache.t3.micro"` | no |
| <a name="input_customer_managed_s3_force_destroy"></a> [customer\_managed\_s3\_force\_destroy](#input\_customer\_managed\_s3\_force\_destroy) | Whether the stand-in bucket this example creates can be destroyed while it still holds objects. true here only so `terraform destroy` doesn't fail on a demo bucket; a real customer-managed bucket's lifecycle, including whether it can be force-destroyed, is that bucket owner's decision, not this module's or this example's. | `bool` | `true` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version for the stand-in cluster this example creates, and the value passed to the module's own kubernetes\_version input (which the module uses only to warn if it does not match the existing cluster's actual version on the create\_eks = false path). Matches the module's own default so the two agree with no extra configuration. | `string` | `"1.35"` | no |
| <a name="input_n8n_additional_domains"></a> [n8n\_additional\_domains](#input\_n8n\_additional\_domains) | Extra hostnames n8n should answer on, beyond n8n\_domain. Each is added to the module-issued ACM certificate as a subject alternative name. Leave empty for a single hostname: this example's own ingress.tf routes one hostname only, so an entry here would be issued a certificate name with no Ingress rule serving it. | `list(string)` | `[]` | no |
| <a name="input_n8n_custom_extensions_path"></a> [n8n\_custom\_extensions\_path](#input\_n8n\_custom\_extensions\_path) | Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. "/opt/n8n-nodes"). Maps to N8N\_CUSTOM\_EXTENSIONS, and is set on main, worker and webhook processor pods alike. Set this alongside n8n\_image\_repository when the custom image bakes community packages in: since n8n 1.0 the loader no longer reads the image's global node\_modules, so a plain npm install into the image is never scanned and the packages ship but never load. Nodes found here register under the package name CUSTOM, so a node installed from npm as n8n-nodes-example.myNode becomes CUSTOM.myNode and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var. | `string` | `null` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_execution_data_storage_mode"></a> [n8n\_execution\_data\_storage\_mode](#input\_n8n\_execution\_data\_storage\_mode) | Where n8n stores the data of each new execution. Passed to the module's n8n\_execution\_data\_storage\_mode. "database" keeps execution data in PostgreSQL; "s3" offloads it to the S3 bucket the module already creates for binary data. Requires n8n >= 2.27 (pin n8n\_image\_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, which is not the same one binary data offload uses. There is no backfill: existing executions stay readable where they were written. | `string` | `"database"` | no |
| <a name="input_n8n_image_pull_secrets"></a> [n8n\_image\_pull\_secrets](#input\_n8n\_image\_pull\_secrets) | Names of existing Kubernetes secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n\_image\_repository points somewhere the node group's IAM role cannot already reach: a public registry and an ECR repository in this account both pull without credentials. Setting it hands ownership of the n8n ServiceAccount from the Helm chart to the module, which is how the secrets reach the pods at all, since the pinned chart renders imagePullSecrets nowhere. Create and rotate the secrets yourself; the module takes names, not credentials, so none of them land in Terraform state. Cross-account ECR is the exception and should not use this: its authorization tokens expire after 12 hours, so add the node group role to the source repository's policy instead. | `list(string)` | `[]` | no |
| <a name="input_n8n_image_repository"></a> [n8n\_image\_repository](#input\_n8n\_image\_repository) | Container image repository for the n8n application, without a tag (e.g. "123456789012.dkr.ecr.eu-west-1.amazonaws.com/n8n"). Leave null to use the Helm chart's own repository (docker.n8n.io/n8nio/n8n). Set this to run a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable by the node group's IAM role (ECR in the same account is) or be public, otherwise name a dockerconfigjson secret in n8n\_image\_pull\_secrets, and n8n\_task\_runner\_image\_tag usually has to be set alongside it. | `string` | `null` | no |
| <a name="input_n8n_image_tag"></a> [n8n\_image\_tag](#input\_n8n\_image\_tag) | n8n application image tag to deploy (e.g. "2.27.4"). Leave null to use the Helm chart's floating `stable` tag. Pin a concrete version for reproducible upgrades and to avoid crossing major-version boundaries on an unplanned pod reschedule. | `string` | `null` | no |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_n8n_task_runner_image_tag"></a> [n8n\_task\_runner\_image\_tag](#input\_n8n\_task\_runner\_image\_tag) | Image tag for the task runner sidecar (`n8nio/runners`). Leave null to inherit the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set it to the underlying n8n version when running a custom image whose tag is not one (e.g. n8n\_image\_tag = "2.27.4-mypackages" together with n8n\_task\_runner\_image\_tag = "2.27.4"); otherwise the sidecar image cannot be pulled and every main and worker pod stays in ImagePullBackOff. | `string` | `null` | no |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain (e.g. the zone for example.com if n8n\_domain = n8n.example.com). The module creates the ACM certificate and validation records inside this zone; this example's own dns.tf creates the alias A-record, since create\_ingress = false means the module owns no load balancer to point one at. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | Hostname of the ALB this example's own Ingress provisions, via the directly-invoked module.controllers' Load Balancer Controller. The alias A-record for n8n\_domain already points at it. |
| <a name="output_customer_managed_cluster_name"></a> [customer\_managed\_cluster\_name](#output\_customer\_managed\_cluster\_name) | Name of the stand-in EKS cluster this example creates, playing the part of a platform team's already-existing cluster. This is the value that fills module.n8n's existing\_eks\_cluster\_name in this example. |
| <a name="output_customer_managed_rds_endpoint"></a> [customer\_managed\_rds\_endpoint](#output\_customer\_managed\_rds\_endpoint) | Address of the stand-in RDS instance this example creates, playing the part of a customer's already-existing database. This is the value that fills module.n8n's db\_host in this example. |
| <a name="output_customer_managed_redis_endpoint"></a> [customer\_managed\_redis\_endpoint](#output\_customer\_managed\_redis\_endpoint) | Primary endpoint of the stand-in replication group this example creates, playing the part of a customer's existing Redis. This is the value that fills module.n8n's redis\_host in this example. |
| <a name="output_customer_managed_s3_bucket_name"></a> [customer\_managed\_s3\_bucket\_name](#output\_customer\_managed\_s3\_bucket\_name) | Name of the stand-in bucket this example creates, playing the part of a customer's existing S3 bucket. This is the value that fills module.n8n's existing\_s3\_bucket\_name in this example. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password in effect. Echoes customer\_managed\_db\_password back in this example, since create\_database = false. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
<!-- END_TF_DOCS -->
