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
<!-- END_TF_DOCS -->
