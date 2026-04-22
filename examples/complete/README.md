# Complete example

End-to-end deployment of the `terraform-aws-n8n` module, including the VPC and ACM certificate it depends on. Use this example as your starting point for a fresh AWS account.

## What it creates

- VPC with public and private subnets across two AZs, NAT gateway, EKS/ALB subnet tags (via `terraform-aws-modules/vpc/aws`)
- ACM certificate for `n8n_domain` with DNS validation
- Everything the `terraform-aws-n8n` module creates: EKS cluster, managed node group, RDS PostgreSQL, ElastiCache Redis, S3 bucket, AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, and the n8n Helm release

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain + n8n_license_key

terraform init
terraform apply
```

Terraform requests the ACM certificate, starts building the VPC, then blocks on `aws_acm_certificate_validation.n8n` for up to 15 minutes. While it blocks, open a second shell and fetch the validation CNAME:

```bash
terraform output -raw acm_validation_cname_name
terraform output -raw acm_validation_cname_value
```

Add it at your DNS provider:

| Type  | Name                                         | Value                                         | TTL |
| ----- | -------------------------------------------- | --------------------------------------------- | --- |
| CNAME | Value from `acm_validation_cname_name`       | Value from `acm_validation_cname_value`       | 300 |

Once the record propagates, the apply finishes on its own.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for pointing your domain at the load balancer and activating your n8n Enterprise license.

## Teardown

```bash
terraform destroy
```

Remove the ACM validation CNAME at your DNS provider after destroy.
