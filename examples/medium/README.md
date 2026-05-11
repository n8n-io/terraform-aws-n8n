# n8n on AWS — Medium Deployment

Production-grade n8n for **~5–15M executions per day** (~60–175 req/s average). Uses Route53 for automated DNS and certificate management.

## Architecture

```
Route 53 (alias A-record)
    └─► ALB (AWS LBC) ──► EKS (5–15 × m6i.2xlarge)
                               ├─► n8n main pods (HPA)
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
| Webhook pods | min=5, max=50 | Floor of 5 is warm; 50 ceiling differentiates from the default example's 2/50 floor while keeping the same headroom |
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

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

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
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
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
