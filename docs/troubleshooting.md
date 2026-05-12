# Troubleshooting

Issues observed in real deployments and how to resolve them. If you hit something not covered here, open an issue.

## `terraform apply`: `no cached repo found ... hashicorp-index.yaml`

**Symptom**

One or more `helm_release` resources fail at create time with:

```
Error: could not download chart: no cached repo found.
(try 'helm repo update'):
open /Users/<you>/Library/Caches/helm/repository/<repo>-index.yaml: no such file or directory
```

**Cause**

The `hashicorp/helm` Terraform provider (v2.x) embeds Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). When the system Helm CLI is **Helm 4** (released 2025), the cache layout differs slightly from the v3 SDK's expectations and the SDK fails to find the index files even though the chart URL is hard-coded in the `helm_release` block.

This is environmental, not a module bug — but anyone running Helm 4 on macOS will see it.

**Fix**

Pre-populate the v3-compatible cache once before the first apply:

```bash
helm repo add eks            https://aws.github.io/eks-charts
helm repo add kedacore       https://kedacore.github.io/charts
helm repo add autoscaler     https://kubernetes.github.io/autoscaler
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
```

Then re-run `terraform apply`. Already-created resources are skipped; only the failed `helm_release`s are retried.

If your environment supports it, downgrading to Helm 3 also resolves the issue:

```bash
brew uninstall helm
brew install helm@3
```

## `terraform apply`: KEDA install fails on AWS LBC webhook

**Symptom**

```
Error: release keda failed, and has been uninstalled due to atomic being set:
Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
no endpoints available for service "aws-load-balancer-webhook-service"
```

**Cause**

The AWS Load Balancer Controller registers a cluster-wide `MutatingWebhookConfiguration` (`mservice.elbv2.k8s.aws`) that intercepts **every** Service creation, not just ALB-targeted ones. If KEDA installs in parallel with LBC, the webhook may already be registered before LBC pods are Ready, so KEDA's metrics/admission Services are rejected.

**Fix**

The module serializes KEDA on `helm_release.lbc` (which has `wait = true`), so LBC pods are guaranteed Ready before KEDA installs. If you hit this on an older revision of the module, simply re-run `terraform apply` — by the time the second apply starts, LBC is up and KEDA installs cleanly.

## Smoke test reports `HTTP 000` after a recent destroy + re-apply

**Symptom**

`tests/scripts/smoke-test.sh` fails the HTTP health, redirect, and API checks with `HTTP 000` against the n8n URL. Direct `dig n8n.example.com` resolves correctly, but `curl https://n8n.example.com/healthz` exits with code 6 (`CURLE_COULDNT_RESOLVE_HOST`).

**Cause (macOS)**

`mDNSResponder` cached the NXDOMAIN response from the previous deployment's destroy phase and is serving it for 5–15 minutes even after Terraform re-created the Route 53 alias record. `dig` and `host` bypass `mDNSResponder`; `curl`, browsers, and anything else using `getaddrinfo()` do not.

This only reproduces when the same FQDN is reused across consecutive `apply` → `destroy` → `apply` cycles on the same workstation, which is common during iterative development of this module but unusual in production.

**Fix**

Flush the macOS DNS cache:

```bash
sudo killall -HUP mDNSResponder
```

Or wait for the negative cache to age out (typically 5–15 minutes). To avoid the issue entirely, use a fresh subdomain per deployment.

## `terraform destroy` hangs on namespace or finalizers

See [destroy-cleanup.md](./destroy-cleanup.md).
