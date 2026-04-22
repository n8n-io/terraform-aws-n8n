# Prerequisites workspace

The prerequisites workspace provisions the VPC and ACM certificate the root module depends on. Apply it before the root module.

## Apply flow

Copy the example variables file and set `n8n_domain`:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Initialize and apply:

```bash
terraform init
terraform apply
```

Terraform requests the certificate, starts building the VPC, then blocks on `aws_acm_certificate_validation.n8n` for up to 15 minutes. While it's blocked, open a second shell and fetch the validation CNAME:

```bash
terraform output -raw acm_validation_cname_name
terraform output -raw acm_validation_cname_value
```

### Add the validation CNAME at your DNS provider

| Type | Name | Value | TTL |
|---|---|---|---|
| CNAME | Value from `acm_validation_cname_name` | Value from `acm_validation_cname_value` | 300 |

Once the record propagates, the in-flight `apply` completes on its own.

## Teardown

Destroy the root module first because it depends on these outputs. Then run `terraform destroy` in this workspace and remove the validation CNAME at your DNS provider.
