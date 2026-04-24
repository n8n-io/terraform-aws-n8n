# Complete example

End-to-end deployment of the `terraform-aws-n8n` module, including the VPC it depends on. Use this example as your starting point for a fresh AWS account. Assumes the parent zone for `n8n_domain` is hosted in Route53.

## What it creates

- VPC with public and private subnets across two AZs, NAT gateway, EKS/ALB subnet tags (via `terraform-aws-modules/vpc/aws`)
- Everything the `terraform-aws-n8n` module creates: the ACM certificate (with automated Route53 validation), the alias A-record for `n8n_domain`, EKS cluster, managed node group, RDS PostgreSQL, ElastiCache Redis, S3 bucket, AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, and the n8n Helm release

## Prerequisites

- A Route53 hosted zone for the parent domain (e.g. `example.com` if `n8n_domain = n8n.example.com`). Note its zone ID.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, route53_zone_id, n8n_license_key

terraform init
terraform apply
```

That's it. Terraform provisions the VPC, issues the ACM certificate (validating it automatically via Route53), stands up EKS and everything on top, and creates the alias record pointing `n8n_domain` at the ALB. Allow ~5 minutes after apply for the ALB to become reachable.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for activating your n8n Enterprise license.

## Teardown

```bash
terraform destroy
```
