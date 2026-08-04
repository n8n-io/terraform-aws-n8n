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

The `hashicorp/helm` Terraform provider embeds the Helm SDK v3 and reuses the local Helm CLI's repository cache (`$HELM_REPOSITORY_CACHE`). This is still true on the `~> 3.0` provider line this module pins: provider 3.x is a Plugin Framework rewrite, but it continues to vendor `helm.sh/helm/v3` (v3.18.5 as of provider v3.2.0), so the embedded SDK is unchanged from the 2.x era. When the system Helm CLI is **Helm 4** (released 2025), the cache layout differs slightly from the v3 SDK's expectations and the SDK fails to find the index files even though the chart URL is hard-coded in the `helm_release` block.

This is environmental, not a module bug — but anyone running Helm 4 on macOS will see it. The workaround below is unchanged under provider 3.x. (Note: if the repository cache is already populated — for example from earlier `helm repo add`/`helm repo update` runs — the apply succeeds without intervention; the failure only appears against an empty or Helm-4-only cache.)

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

## Webhooks return HTTP 200 with an HTML body and never execute

**Symptom**

A production webhook, Form Trigger, Wait-node resumption, or MCP Server Trigger URL returns `200` and a chunk of HTML instead of running the workflow. Nothing appears in the executions list. The caller logs a success, so the failure is silent on both ends.

Most often seen on `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`, while plain `/webhook` works.

**Cause**

The request reached the **main** pods rather than the webhook processors. This module runs the chart with `disableProductionWebhooksOnMainProcess = true`, which disables five endpoint families on the mains: `/webhook`, `/webhook-waiting`, `/form`, `/form-waiting`, and `/mcp`. When one of those paths hits a main pod, no handler is registered, so the request falls through to the editor's single-page-app handler, which answers `200` with the editor HTML.

Two ways to end up here:

- **Module version `0.2.0` or earlier**, where the built-in Ingress routed only `/webhook` and the other four fell through to the catch-all. Upgrade; all five are routed now.
- **A bring-your-own Ingress** (`create_ingress = false`) whose catch-all rule precedes or replaces the webhook prefixes. This bites the internal ALB of a two-ALB split especially easily, because it is natural to give it only a `/` rule.

**Fix**

Route every prefix in `n8n_webhook_path_prefixes` to `n8n_webhook_service_name`, declared **before** any catch-all, on *every* Ingress that fronts n8n, internal ones included. Iterate the output rather than hardcoding:

```hcl
dynamic "path" {
  for_each = module.n8n.n8n_webhook_path_prefixes
  content {
    path      = path.value
    path_type = "Prefix"
    backend {
      service {
        name = module.n8n.n8n_webhook_service_name
        port { number = module.n8n.n8n_service_port }
      }
    }
  }
}
```

To confirm which pods are actually behind a listener, compare the target group members with the pod IPs:

```bash
aws elbv2 describe-target-health --target-group-arn <arn> \
  --query 'TargetHealthDescriptions[].Target.Id' --output text
kubectl get pods -n n8n -o custom-columns='NAME:.metadata.name,IP:.status.podIP' --no-headers
```

A correctly routed webhook prefix returns `application/json` from n8n (for example `404 {"code":404,"message":"The requested webhook ... is not registered."}`), never `text/html`. The content type is the quickest discriminator.

See [examples/split-ingress](../examples/split-ingress/) for a worked two-ALB configuration.

## MCP Server Trigger returns `404 Session not found` intermittently

**Symptom**

An MCP client connects, initialises successfully, then a share of follow-up requests fail with `404 Session not found`. Retrying sometimes works. The failure rate is roughly `1 - 1/N` for `N` webhook processor replicas, so about half the requests with the default 2.

**Cause**

n8n keeps each MCP session's live transport in the memory of the replica that handled the `initialize` call. Redis stores only a session validity marker, not the transport itself, so a request landing on any other replica passes validation and then finds no transport to hand it to.

The ALB's `lb_cookie` stickiness does not help: MCP clients are generally not browsers and do not return the cookie.

**Fix**

Pin the webhook processors to a single replica:

```hcl
n8n_webhook_hpa_min_replicas = 1
n8n_webhook_hpa_max_replicas = 1
```

This costs webhook throughput and HA, so apply it only when MCP matters more. `examples/split-ingress` exposes it as `mcp_single_replica`.

The alternative is a dedicated single-replica webhook Deployment serving `/mcp` alone, with the main pool left scaled for throughput. That needs `create_ingress = false` and Kubernetes resources you manage yourself.

Tracked in [issue #59](https://github.com/n8n-io/terraform-aws-n8n/issues/59), which also lists what still needs investigating. A durable fix may belong upstream in n8n, by routing a session to its owning replica or making the transport reconstructible from Redis.

## Caller-owned Ingress fails with `namespaces "n8n" not found`

**Symptom**

On the first `terraform apply` with `create_ingress = false`, your own `kubernetes_ingress_v1` (or any other namespaced resource) fails:

```
Error: Failed to create Ingress 'n8n/my-ingress' because: namespaces "n8n" not found
```

A re-apply then succeeds, because the namespace exists by that point.

**Cause**

Your resource had no dependency edge to the namespace, so Terraform scheduled it concurrently with the module rather than after it. In module versions where `output "namespace"` returned `var.namespace`, the output was a plan-time constant and consuming it created no ordering at all.

**Fix**

Upgrade: `namespace` is now sourced from `kubernetes_namespace.n8n`, so consuming it orders your resources implicitly.

Also add an explicit dependency on the whole module for anything an ALB registers targets for:

```hcl
resource "kubernetes_ingress_v1" "mine" {
  # ...
  depends_on = [module.n8n]
}
```

The namespace edge alone is not sufficient. With `wait_for_load_balancer = true`, the Ingress can otherwise be created before the Helm release has produced the Services, leaving the load balancer controller with nothing to register.

## `terraform destroy` hangs on namespace or finalizers

See [destroy-cleanup.md](./destroy-cleanup.md).
