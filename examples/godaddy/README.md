# GoDaddy DNS example

End-to-end deployment of the `terraform-aws-n8n` module, including the VPC it depends on, using GoDaddy for DNS and ACM certificate validation. Use this example when your domain is registered and managed in GoDaddy rather than Route53.

## What it creates

- VPC with public and private subnets across two AZs, NAT gateway, EKS/ALB subnet tags (via `terraform-aws-modules/vpc/aws`)
- Everything the `terraform-aws-n8n` module creates: the ACM certificate (DNS-validated via GoDaddy), the CNAME record for `n8n_domain` pointing at the ALB, EKS cluster, managed node group, RDS PostgreSQL, ElastiCache Redis, S3 bucket, AWS Load Balancer Controller, Cluster Autoscaler, metrics-server, KEDA, and the n8n Helm release

## Prerequisites

- A domain registered in GoDaddy (e.g. `example.com` if `n8n_domain = n8n.example.com`).
- A GoDaddy API key and secret with DNS write permissions. Create one at https://developer.godaddy.com/keys. Note that GoDaddy restricts API access to accounts with 10 or more registered domains or an active Discount Domain Club Premier membership.

> **Why are credentials plain variables, not secrets management?** The `veksh/godaddy-dns` provider reads credentials directly from its provider block (or from `GODADDY_API_KEY` / `GODADDY_API_SECRET` environment variables). Terraform provider configuration cannot reference dynamic data sources, so there is no way to inject a value from AWS Secrets Manager at provider-init time. The variables are marked `sensitive = true`, which prevents them from appearing in plan/apply output or state. For production use, supply them via environment variables rather than storing them in `terraform.tfvars`.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set n8n_domain, godaddy_domain, godaddy_api_key,
# godaddy_api_secret, and n8n_license_key

terraform init
terraform apply
```

Terraform provisions the VPC, issues the ACM certificate (validating it automatically via GoDaddy DNS records), stands up EKS and everything on top, and creates the CNAME pointing `n8n_domain` at the ALB. Allow ~5 minutes after apply for the ALB to become reachable.

## Post-deployment

See [../../docs/post-deployment.md](../../docs/post-deployment.md) for activating your n8n Enterprise license.

## Teardown

```bash
terraform destroy
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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_godaddy-dns"></a> [godaddy-dns](#requirement\_godaddy-dns) | ~> 0.3 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.12 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_godaddy-dns"></a> [godaddy-dns](#provider\_godaddy-dns) | ~> 0.3 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.n8n](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [godaddy-dns_record.cert_validation](https://registry.terraform.io/providers/veksh/godaddy-dns/latest/docs/resources/record) | resource |
| [godaddy-dns_record.n8n_cname](https://registry.terraform.io/providers/veksh/godaddy-dns/latest/docs/resources/record) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into (e.g. us-east-1, eu-west-1, ap-southeast-1). | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the EKS cluster. Keep to 14 characters or fewer — the module derives an ElastiCache cluster ID of `<cluster_name>-redis`, and AWS caps ElastiCache IDs at 20 chars. | `string` | `"n8n-cluster"` | no |
| <a name="input_godaddy_api_key"></a> [godaddy\_api\_key](#input\_godaddy\_api\_key) | GoDaddy API key with DNS write permissions. Create one at https://developer.godaddy.com/keys. Can also be supplied via the GODADDY\_API\_KEY environment variable. | `string` | n/a | yes |
| <a name="input_godaddy_api_secret"></a> [godaddy\_api\_secret](#input\_godaddy\_api\_secret) | GoDaddy API secret corresponding to godaddy\_api\_key. Can also be supplied via the GODADDY\_API\_SECRET environment variable. | `string` | n/a | yes |
| <a name="input_godaddy_domain"></a> [godaddy\_domain](#input\_godaddy\_domain) | GoDaddy domain name that contains n8n\_domain (e.g. example.com if n8n\_domain = n8n.example.com). The module creates ACM certificate validation records and a CNAME record in this domain. | `string` | n/a | yes |
| <a name="input_n8n_domain"></a> [n8n\_domain](#input\_n8n\_domain) | Fully-qualified domain name for n8n (e.g. n8n.example.com). Must be a single label below godaddy\_domain (e.g. 'n8n' below 'example.com'). Deeper nesting like 'n8n.prod.example.com' under 'example.com' is not supported by this example's name-stripping logic — host such records under godaddy\_domain = 'prod.example.com' instead. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key. Get one at https://n8n.io/pricing | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional AWS tags to apply to all resources this example creates. Merged on top of the built-in ManagedBy/Project tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_hostname"></a> [alb\_hostname](#output\_alb\_hostname) | ALB hostname. The CNAME for n8n\_domain is already created in GoDaddy — this output is informational. |
| <a name="output_db_password"></a> [db\_password](#output\_db\_password) | RDS PostgreSQL password — back this up in a password manager. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl for this cluster. |
| <a name="output_n8n_encryption_key"></a> [n8n\_encryption\_key](#output\_n8n\_encryption\_key) | n8n encryption key — back this up in a password manager. |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | URL to access n8n once the ALB finishes provisioning (~5 min after apply). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace n8n is deployed into. Read by tests/scripts/smoke-test.sh. |
<!-- END_TF_DOCS -->