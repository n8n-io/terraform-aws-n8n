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

If you deployed with `var.n8n_license_cert_secret_ref` instead of `var.n8n_license_key` (an air-gapped or egress-restricted cluster; see ["Offline license activation"](../README.md#offline-license-activation) in the root README), there is no key to paste in **Settings** > **License**: the certificate in your caller-managed Secret already activated the license as `N8N_LICENSE_CERT` at pod startup, with no round trip to n8n's license server. Confirm activation from **Settings** > **License** instead of the key-entry flow, or with `kubectl -n n8n exec deploy/n8n-main -- n8n license:info`. Rotating the certificate means updating the caller-managed Secret's payload and restarting the `n8n-main`, `n8n-worker`, and `n8n-webhook-processor` deployments.

