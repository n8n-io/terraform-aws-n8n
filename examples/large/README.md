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

## Reference

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
