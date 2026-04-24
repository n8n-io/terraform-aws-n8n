# Post-deployment setup

After `terraform apply` completes, finish setup by activating your n8n Enterprise license.

## Wait for the ALB

The ALB is provisioned asynchronously after the Ingress resource is created. Allow ~5 minutes after apply for it to become reachable. Verify:

```bash
terraform refresh
terraform output -raw alb_hostname
kubectl get ingress n8n-ingress -n n8n
```

## Point your domain at n8n

**If you used `route53_zone_id`:** nothing to do — the alias A-record was created during apply. Verify propagation:

```bash
dig +short n8n.yourdomain.com
```

**If you supplied your own `certificate_arn`:** add a CNAME at your DNS provider.

| Type  | Name                      | Value                                                  | TTL |
| ----- | ------------------------- | ------------------------------------------------------ | --- |
| CNAME | `n8n` (or your subdomain) | ALB hostname from `terraform output -raw alb_hostname` | 300 |

## Access n8n and activate your license

Open `https://n8n.yourdomain.com` in your browser. Create your owner account, then select **Settings** > **License** and enter your activation key.
