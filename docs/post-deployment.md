# Post-deployment setup

After `terraform apply` completes, finish setup by pointing your domain at the load balancer and activating your n8n Enterprise license.

## Point your domain at n8n

AWS provisions the ALB asynchronously after creating the Ingress, so Terraform's state doesn't have the hostname yet. Refresh state first:

```bash
terraform refresh && terraform output alb_hostname
```

If the output still shows a placeholder, check the Ingress directly:

```bash
kubectl get ingress n8n-ingress -n n8n
```

### Add a second CNAME at your DNS provider

| Type | Name | Value | TTL |
|---|---|---|---|
| CNAME | `n8n` (or your subdomain) | ALB hostname from the Terraform output | 300 |

Verify propagation:

```bash
dig +short n8n.yourdomain.com
```

## Access n8n and activate your license

Open `https://n8n.yourdomain.com` in your browser. Create your owner account, then select **Settings** > **License** and enter your activation key.
