# n8n on AWS — Large Deployment

Production-grade n8n for **~50–60M executions per day** (~350–960 req/s average). Uses Amazon Aurora PostgreSQL with I/O-Optimized storage, PgBouncer for connection pooling, and Route53 for automated DNS and certificate management.

## Architecture

```
Route 53 (alias A-record)
    └─► ALB (AWS LBC) ──► EKS (10–50 × m7i.4xlarge)
                               ├─► n8n main pods (HPA)
                               ├─► n8n webhook processors (HPA, min=30 / max=80)
                               └─► n8n workers (KEDA, min=20 / max=160)
                                        ├─► PgBouncer (2 replicas, transaction mode)
                                        │        └─► Aurora PostgreSQL (writer + reader)
                                        └─► ElastiCache Redis cache.r6g.large
```

## Key sizing decisions

| Resource | Value | Rationale |
|---|---|---|
| Node type | m7i.4xlarge (16 vCPU, 64 GB) | x86_64 required with AL2023_x86_64_STANDARD AMI; Graviton requires separate AMI type |
| Node count | desired=10, min=10, max=50 | Warm floor of 10; 50 max covers 2,400 req/s peaks |
| VPC private subnets | 2× /20 (4,094 IPs each) | /24s exhausted by default VPC CNI warm-IP pools at 20+ large nodes |
| VPC CNI tuning | WARM_ENI_TARGET=0, WARM_IP_TARGET=2 | Reduces pre-warmed IPs from ~2,400 to 20 across 10 nodes |
| Database | Aurora PostgreSQL I/O-Optimized | Removes IOPS ceiling; 14,000–15,000 TPS sustained vs ~600 req/s ceiling on RDS gp3 |
| Aurora instances | 1 writer + 1 reader | Automatic failover; reader offloads reporting queries |
| PgBouncer | 2 replicas, transaction mode | 80 webhook + 160 worker + 2 main = 1,210 connections without pooling; transaction mode confirmed compatible with n8n TypeORM |
| Redis | cache.r6g.large | 77% peak memory at 856 req/s with no evictions or rejected connections |
| Webhook pods | min=30, max=80 | 10 pods saturated at ~960 req/s; 30 pod floor handles 500 concurrent VUs cleanly |
| Worker pods | min=20, max=160 | 856 req/s ÷ concurrency=40 = 22 workers at steady state; 160 max for 2,400 req/s burst |
| Worker concurrency | 40 | Doubles throughput per pod vs 20; pool_size=5 is sufficient with PgBouncer |
| Execution concurrency limit | 2,000 | Default 100 throttles workers before any infrastructure bottleneck |
| Pruning | 24h / 5M records | 14-day retention at this throughput rapidly accumulates hundreds of millions of rows; autovacuum cannot sustain concurrent writes at that size |
| Webhook memory | 4 Gi limit / 1 Gi request | 2 Gi caused memory-pressure 503s under 500 VU load; 4 Gi halved failure rate |

## Estimated cost (us-east-1, on-demand)

| Resource | Monthly |
|---|---|
| EKS nodes (10 × m7i.4xlarge, desired) | ~$5,887 |
| EKS nodes (50 × m7i.4xlarge, at max) | ~$29,434 |
| Aurora writer db.r6g.8xlarge | ~$5,606 |
| Aurora reader db.r6g.8xlarge | ~$5,606 |
| ElastiCache cache.r6g.large | ~$121 |
| EKS control plane | ~$73 |
| NAT Gateways (2× HA) | ~$70 |
| **Total (10 nodes steady-state)** | **~$17,300** |
| **Total (50 nodes peak)** | **~$41,000** |

1-year Reserved Instances reduce compute ~35%. If load is concentrated in business hours, KEDA/HPA autoscaling (rather than fixed min=desired) reduces average node spend by 30–40%.

## Apply order

Aurora must be provisioned before n8n starts — n8n pods attempt a database connection on startup. The `depends_on = [aws_rds_cluster_instance.writer]` in `main.tf` enforces this within a single `terraform apply`.

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform apply   # ~30 min: Aurora provisioning dominates
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

## Operational notes

**Before each benchmark or high-load test:**
```bash
NS=$(terraform output -raw namespace)

# 1. Flush Redis (stale Bull state causes worker errors after pod restarts)
kubectl run redis-flush --rm -it --restart=Never --image=redis:7-alpine -n "$NS" \
  -- redis-cli -h <redis-host> FLUSHALL

# 2. Restart all pods for clean connection pools
kubectl rollout restart deployment/n8n-worker deployment/n8n-webhook-processor \
  deployment/n8n-main deployment/pgbouncer -n "$NS"
kubectl rollout status deployment/n8n-worker deployment/n8n-webhook-processor \
  deployment/n8n-main deployment/pgbouncer -n "$NS" --timeout=300s

# 3. Wait for Aurora active connections to return to baseline before starting load
```

**If "Database is not ready!" errors persist after config changes:**
1. Check for stale Bull jobs: flush all `bull:*` Redis keys.
2. Restart PgBouncer once (`kubectl rollout restart deployment/pgbouncer`) to drop ghost Aurora connections.
3. If still stuck: scale all n8n pods to 0, wait for Aurora to show <10 connections, then scale back up.

**KMS key after `terraform destroy`:**

The Aurora cluster's CMK (`alias/${cluster_name}-aurora-<auto-generated suffix>`) enters a mandatory 7-day `PendingDeletion` window on `terraform destroy`. The key continues to bill ~$0.03/day during the window — negligible (~$0.21 per cycle), but the keys accumulate in the AWS console if you cycle `apply`/`destroy` repeatedly. Because the alias uses `name_prefix`, the alias name is unique per apply: **re-applying with the same `cluster_name` works immediately** without waiting for the window to expire or running `cancel-key-deletion` workarounds.

**Upgrading from a pre-CMK apply.** If you applied an earlier revision of this example (before this PR) where the Aurora cluster was created with `storage_encrypted = true` plus the AWS-managed `aws/rds` key, the first `terraform plan` after pulling this change will show `aws_rds_cluster.n8n` being **destroyed and recreated**. Aurora does not support re-encryption in place — snapshot the cluster first if you need to preserve data, then restore from the snapshot post-apply.

## Production considerations

This example is a reference deployment optimized for clean `apply` / `destroy` cycles during evaluation and load testing. Before promoting it to production, review and flip the teardown-friendly defaults baked into both this example and the underlying module:

| Where | Setting | Current | Production |
|---|---|---|---|
| `examples/large/aurora.tf` | `aws_rds_cluster.n8n.deletion_protection` | `false` | `true` |
| `examples/large/aurora.tf` | `aws_rds_cluster.n8n.skip_final_snapshot` | `true` | `false`, plus set `final_snapshot_identifier` |
| Module `database.tf` (unused here; Aurora replaces it) | `aws_db_instance.n8n.skip_final_snapshot` | `true` | `false` |
| Module `s3.tf` | `aws_s3_bucket.n8n.force_destroy` | `true` | `false` |

The Aurora cluster also carries a `# checkov:skip=CKV_AWS_139` annotation that should be removed once `deletion_protection = true` is set. The annotation exists specifically because flipping the default would break this example's documented `terraform destroy` flow, not because the underlying check is wrong.

The S3 `force_destroy` setting lives in the module and is not currently exposed as a variable; for production you would wrap or fork the module to override it.

## Reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.aurora_postgresql](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_subnet_group.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_eks_addon.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_iam_role.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.rds_enhanced_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_rds_cluster.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster) | resource |
| [aws_rds_cluster_instance.reader](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [aws_rds_cluster_instance.writer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [aws_security_group.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [kubernetes_deployment.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment) | resource |
| [kubernetes_namespace.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_pod_disruption_budget_v1.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/pod_disruption_budget_v1) | resource |
| [kubernetes_secret.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service.pgbouncer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service) | resource |
| [random_password.aurora](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aurora_instance_class"></a> [aurora\_instance\_class](#input\_aurora\_instance\_class) | Aurora PostgreSQL instance class for both the writer and reader. db.r6g.8xlarge (32 vCPU, 256 GB) is validated for this example's target throughput of ~50–60+M executions/day. Scale down for lower throughput targets or Reserved Instance pricing. | `string` | `"db.r6g.8xlarge"` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-large"` | no |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). The parent zone must be hosted in Route53 (pass its ID via route53\_zone\_id). | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_route53_zone_id"></a> [route53\_zone\_id](#input\_route53\_zone\_id) | Route53 hosted zone ID for the parent of n8n\_domain. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to every resource this example creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname. The alias A-record for n8n\_domain is already created in Route53 — this output is informational. |
| <a name="output_aurora_reader_endpoint"></a> [aurora\_reader\_endpoint](#output\_aurora\_reader\_endpoint) | Aurora cluster reader endpoint — use this for read-only reporting queries. |
| <a name="output_aurora_writer_endpoint"></a> [aurora\_writer\_endpoint](#output\_aurora\_writer\_endpoint) | Aurora cluster writer endpoint — used by PgBouncer to connect to the primary instance. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | Aurora PostgreSQL password — back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key — back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. |
<!-- END_TF_DOCS -->
