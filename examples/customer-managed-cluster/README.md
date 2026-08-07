# Customer-managed cluster example

Points `terraform-aws-n8n` at an EKS cluster it does not own, instead of letting it create one.

Use this when a platform team already provisions and runs EKS clusters company-wide, and n8n should deploy onto shared infrastructure rather than getting its own dedicated cluster.

## What it creates

This example is two things layered together:

1. **A stand-in for infrastructure a platform team already has.** `main.tf`'s "Customer-managed EKS cluster (stand-in)" section provisions an `aws_eks_cluster`, its node group, both IAM roles, and the `eks-pod-identity-agent` addon, with plain Terraform resources, entirely independent of the `terraform-aws-n8n` module. In a real deployment this section would not exist: the cluster would already be running, owned by whatever created it (a platform team's own Terraform, Karpenter, eksctl, the console). Sized the same as [`examples/small`](../small/)'s module-created cluster (`t3.xlarge` nodes, desired/min 3, max 6), not a cheaper demo tier, because the module's own `node_instance_type` description warns that anything smaller leaves insufficient headroom for HPA to scale the full multi-main n8n workload.
2. **Everything the `terraform-aws-n8n` module creates, except the EKS cluster itself** (`create_eks = false`): RDS PostgreSQL, ElastiCache Redis, S3 bucket, the AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, the EBS CSI driver, and the n8n Helm release. The module is wired at the stand-in cluster's name exactly as it would be at a real customer-managed cluster.

## The four things you have to confirm yourself

`existing_eks_cluster_prerequisites_confirmed = true` is an explicit attestation, not a rubber stamp: setting it is a claim that four specific things hold, none of them checkable at plan time the way the cluster's Kubernetes version and VPC already are (see the root module's `existing_eks_cluster_prerequisites_confirmed` variable for the full description). Here is how this example's own stand-in cluster satisfies each one, so the attestation in `main.tf` isn't asserted blind:

1. **Node capacity.** Sized identically to `examples/small`'s module-created cluster, so the same HPA/KEDA maxima the module computes fit the same way they do there.
2. **Cluster Autoscaler auto-discovery tags.** Set explicitly on `aws_eks_node_group.customer_managed` in `main.tf` (`k8s.io/cluster-autoscaler/<cluster>=owned` and `k8s.io/cluster-autoscaler/enabled=true`), since the module cannot tag infrastructure it doesn't own.
3. **API server reachability.** The stand-in cluster's endpoint is public, and this example applies from wherever `terraform apply` runs, same as `examples/small`.
4. **Naming and identity collisions.** This is a fresh, single-purpose cluster created only for this example, so there is nothing else on it for the module's IAM role names, `ServiceAccount` names, or Pod Identity associations to collide with.

On a **real** shared cluster, you would need to verify these yourself instead of relying on this example's answers: check actual schedulable capacity (especially if the cluster runs Karpenter, self-managed ASGs, or Fargate rather than a plain EKS-managed node group), confirm the existing node group already carries the Cluster Autoscaler tags, confirm the API endpoint is reachable from wherever you run `terraform apply`, and check for name collisions with whatever else already runs on that cluster.

## The hard prerequisite: Pod Identity agent

Unlike the four attestation items above, the `eks-pod-identity-agent` addon is not something you merely attest to: the AWS provider itself fails the plan (a `ResourceNotFoundException`) if the named cluster doesn't already have it installed, before any Pod Identity association is attempted. This example's stand-in cluster installs it itself (`aws_eks_addon.customer_managed_pod_identity`), named and versioned the same way the module installs it on the `create_eks = true` path. A real customer-managed cluster needs this addon already present; if it isn't, the fix is to install it there first (outside this module), not to work around the plan failure.

## Adapting to your real infrastructure

To point this at a cluster you actually run instead of the stand-in:

1. Delete the entire "Customer-managed EKS cluster (stand-in)" section from `main.tf` (both IAM roles and their policy attachments, the `aws_eks_cluster`, `aws_eks_node_group`, and `aws_eks_addon` resources), and the `kubernetes_version` / `customer_managed_node_*` variables it used.
2. In `module "n8n"`, replace the values wired to those deleted resources with your own cluster's identity:
   ```hcl
   create_eks                                   = false
   existing_eks_cluster_name                    = "your-existing-cluster-name"
   existing_eks_cluster_prerequisites_confirmed = true # only after you've verified the four items above yourself
   ```
3. Confirm the `eks-pod-identity-agent` addon is already installed on that cluster; the plan fails outright if it isn't.
4. Confirm your cluster's node group already carries the Cluster Autoscaler auto-discovery tags, or that you're intentionally leaving `install_cluster_autoscaler = false` because a platform-managed autoscaler already runs there.
5. Your cluster must be in the same VPC as `vpc_id`; the module hard-fails the plan on a mismatch, rather than producing infrastructure that looks correct and silently can't reach it.

See the root [README.md → "Customer-managed infrastructure"](../../README.md#customer-managed-infrastructure) for the full state matrix, and [`docs/customer-managed-infrastructure.md`](../../docs/customer-managed-infrastructure.md) for the convention behind every toggle like this one.

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

Unlike [`customer-managed-redis`](../customer-managed-redis/) and [`customer-managed-s3`](../customer-managed-s3/), this example's `tests/defaults.tftest.hcl` cannot assert a normal, successful plan of its own wiring. The module's own `create_eks = false` path reads the existing cluster through `data.aws_eks_cluster.existing`, and that data source's result is unresolvable under `command = plan` with mocked providers once nested inside this example's `module "n8n"` call, a limitation confirmed by direct experimentation rather than assumed; see the comment at the top of that test file for the full writeup, including why one `run` block (`cluster_name` length validation) passes anyway: its failure cascades widely enough through the config to block the unresolvable check blocks from ever being reached, which most other variables' validations don't. The module's own `create_eks = false` logic is already covered by 400+ run blocks in the repo root's `tests/defaults.tftest.hcl`, tested directly rather than through an example wrapper. `terraform validate`, `terraform fmt`, and `tflint` all pass against this example; exercising it end to end needs real AWS credentials.

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
| [aws_eks_addon.customer_managed_pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.customer_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_iam_role.customer_managed_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.customer_managed_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.customer_managed_cluster_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.customer_managed_nodes_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer: the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_customer_managed_node_desired"></a> [customer\_managed\_node\_desired](#input\_customer\_managed\_node\_desired) | Initial number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node\_desired default). Only applies at creation: the node group's desired\_size ignores changes afterward so the Cluster Autoscaler this example installs can own it without fighting plans/applies. | `number` | `3` | no |
| <a name="input_customer_managed_node_instance_type"></a> [customer\_managed\_node\_instance\_type](#input\_customer\_managed\_node\_instance\_type) | EC2 instance type for the stand-in cluster's node group. Matches the module's own node\_instance\_type default (t3.xlarge), not a cheaper demo size: the module's own variable description warns that a full multi-main n8n workload (main x2, worker x2, webhook x2 pods at minimum replicas) needs at least this much headroom for HPA to have room to scale. A real customer-managed cluster would be sized for its own broader workload, which may already be larger than this. | `string` | `"t3.xlarge"` | no |
| <a name="input_customer_managed_node_max"></a> [customer\_managed\_node\_max](#input\_customer\_managed\_node\_max) | Maximum number of worker nodes the Cluster Autoscaler can scale the stand-in node group to. Matches examples/small's implicit sizing (the module's own node\_max default). | `number` | `6` | no |
| <a name="input_customer_managed_node_min"></a> [customer\_managed\_node\_min](#input\_customer\_managed\_node\_min) | Minimum number of worker nodes in the stand-in node group. Matches examples/small's implicit sizing (the module's own node\_min default). | `number` | `3` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version for the stand-in cluster this example creates, and the value passed to the module's own kubernetes\_version input (which the module uses only to warn if it does not match the existing cluster's actual version on the create\_eks = false path). Matches the module's own default so the two agree with no extra configuration. | `string` | `"1.35"` | no |
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
| <a name="output_customer_managed_cluster_name"></a> [customer\_managed\_cluster\_name](#output\_customer\_managed\_cluster\_name) | Name of the stand-in EKS cluster this example creates, playing the part of a platform team's already-existing cluster. This is the value that fills module.n8n's existing\_eks\_cluster\_name in this example; in a real deployment it would be your own cluster's name instead. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password. Back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key. Back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
<!-- END_TF_DOCS -->
