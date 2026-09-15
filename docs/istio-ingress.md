# Istio ingress routing

This module has no Istio-specific input and ships no Istio example. If your
platform already runs Istio as its ingress/service-mesh layer, this page is
the Istio equivalent of the [README's "Customer-managed Ingress (two-ALB
split)"](../README.md#customer-managed-ingress-two-alb-split) section: the
same trust-boundary split, expressed as `Gateway`/`VirtualService` instead of
`kubernetes_ingress_v1`. For the runnable, ALB-based version of this split,
see [`examples/split-ingress/`](../examples/split-ingress/).

This is deliberately a reference, not a module: an Istio install, its chart
version, its ingress-gateway Service annotations, and its own TLS story are
all things your platform team already owns and are out of scope here. A
prior draft of this page shipped as a full runnable `examples/istio-split-ingress`
(two `helm_release` ingress gateways, a hand-authored routing chart, version
pins, CI wiring). It was cut before merging: nearly all of that surface was
Istio operational detail unrelated to calling this module, each pin and
annotation breaks on Istio's own schedule rather than n8n's, and the target
audience already runs Istio and its own gateway/TLS conventions, so they will
copy the `VirtualService` below rather than stand up a second Istio control
plane alongside their own. What is worth keeping is the routing knowledge itself,
which does not change whether it is applied via `helm_release` or `kubectl
apply`.

## The module-facing contract

Exactly what `create_ingress = false` hands you in the ALB case, unchanged
for Istio: the module still builds the `n8n-main` and `n8n-webhook-processor`
Services and the workloads behind them, issues the ACM certificate if
`route53_zone_id` is set, and stops managing an Ingress or alias record.

```hcl
module "n8n" {
  source = "n8n-io/n8n/aws"

  create_ingress = false

  # Two gateways need two hostnames: a DNS name resolves to one thing. Set
  # this the same way the ALB split does if you want the module to issue one
  # certificate covering both names.
  route53_zone_id        = var.route53_zone_id
  n8n_additional_domains = [var.webhook_domain]
  n8n_webhook_url        = "https://${var.webhook_domain}"

  # ... remaining inputs
}
```

| Output | Value | Serves |
| --- | --- | --- |
| `n8n_service_name` | `n8n-main` | Editor UI, REST API |
| `n8n_webhook_service_name` | `n8n-webhook-processor` | Webhooks, forms, waiting resumptions, MCP |
| `n8n_webhook_path_prefixes` | see below | The prefixes that must reach the processors |
| `n8n_service_port` | `5678` | Both |
| `namespace` | Kubernetes namespace n8n runs in | Needed to address the Services above |
| `certificate_arn` | Validated module-issued ACM ARN when `route53_zone_id` is set; otherwise the caller-supplied `certificate_arn` | For an AWS load balancer terminating TLS; does not supply Envoy's TLS Secret |

## The route rules

Two physically separate gateways, not one gateway serving two hostnames: the
trust boundary comes from the public Envoy's routing table having no route
to the editor at all, not from a firewall rule sitting in front of one that
does. Route every prefix `n8n_webhook_path_prefixes` returns, not just
`/webhook`: the module runs the chart with
`disableProductionWebhooksOnMainProcess = true`, which disables five endpoint
families on the main pods, not one (`/webhook`, `/webhook-waiting`, `/form`,
`/form-waiting`, `/mcp`). Iterate over the output rather than hardcoding the
list, so routing stays in step as n8n adds endpoints.

Replace `<namespace>` in the backend Service addresses with
`module.n8n.namespace`. Keep each Gateway and its VirtualService in the same
namespace so the unqualified `gateways` reference resolves correctly.

For the HTTPS servers below, create each `credentialName` Secret in the
namespace of the **selected ingress-gateway workload**: the public gateway's
namespace for `n8n-gateway-tls-public`, and the internal gateway's namespace
for `n8n-gateway-tls-internal`. These may differ from both the Gateway
resource's namespace and the n8n namespace. See
[Istio's credential namespace requirement](https://istio.io/latest/docs/reference/config/analysis/ist0161/).

**Public gateway (webhook prefixes only, no catch-all):**

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: n8n-public
spec:
  selector:
    istio: ingressgateway-public # your public ingress gateway's workload selector
  servers:
    # If an upstream load balancer already terminates TLS and hands Envoy
    # plain HTTP, use this server instead of the HTTPS one below.
    # - hosts:
    #     - hooks.example.com
    #   port:
    #     number: 8080
    #     name: http
    #     protocol: HTTP
    - hosts:
        - hooks.example.com
      port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: n8n-gateway-tls-public
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: n8n-public
spec:
  hosts:
    - hooks.example.com
  gateways:
    - n8n-public
  http:
    # The only route. There is deliberately no second, catch-all http entry:
    # a request outside these prefixes matches nothing and Envoy returns its
    # own 404, so the editor UI is not merely firewalled from this gateway,
    # it is simply absent from its routing table.
    - match:
        - uri:
            exact: /webhook
        - uri:
            prefix: /webhook/
        - uri:
            exact: /webhook-waiting
        - uri:
            prefix: /webhook-waiting/
        - uri:
            exact: /form
        - uri:
            prefix: /form/
        - uri:
            exact: /form-waiting
        - uri:
            prefix: /form-waiting/
        - uri:
            exact: /mcp
        - uri:
            prefix: /mcp/
      route:
        - destination:
            host: n8n-webhook-processor.<namespace>.svc.cluster.local
            port:
              number: 5678
```

Match each prefix with both an `exact` and a `prefix` ending in `/`, not a
bare `prefix: /webhook`: a bare prefix match also matches `/webhookfoo`,
sending an unrelated path to the webhook processors.

**Internal gateway (webhook prefixes plus a catch-all, VPN-only):**

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: n8n-internal
spec:
  selector:
    istio: ingressgateway-internal # your internal ingress gateway's workload selector
  servers:
    - hosts:
        - n8n.example.com
      port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: n8n-gateway-tls-internal
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: n8n-internal
spec:
  hosts:
    - n8n.example.com
  gateways:
    - n8n-internal
  http:
    # Webhook prefixes as their OWN entry, declared first so Istio's in-order
    # route evaluation matches them before the catch-all below. Without this,
    # the catch-all would hand /webhook to n8n-main, which runs with
    # production webhooks disabled, so the request falls through to the
    # editor's SPA handler and returns 200 with an HTML body: an in-VPC
    # caller delivering a webhook would read that as success while nothing
    # executed.
    - match:
        - uri:
            exact: /webhook
        - uri:
            prefix: /webhook/
        - uri:
            exact: /webhook-waiting
        - uri:
            prefix: /webhook-waiting/
        - uri:
            exact: /form
        - uri:
            prefix: /form/
        - uri:
            exact: /form-waiting
        - uri:
            prefix: /form-waiting/
        - uri:
            exact: /mcp
        - uri:
            prefix: /mcp/
      route:
        - destination:
            host: n8n-webhook-processor.<namespace>.svc.cluster.local
            port:
              number: 5678
    # Catch-all last: editor UI and REST API. An http entry with no `match`
    # field matches every remaining request, which is why this one has none.
    - route:
        - destination:
            host: n8n-main.<namespace>.svc.cluster.local
            port:
              number: 5678
```

## Two hostnames, not one

Same reasoning as the ALB split: a DNS record aliases exactly one endpoint,
so serving a public webhook host and a VPN-only admin host from separate
gateways needs two names. Set `n8n_webhook_url` to the public host so n8n
hands out webhook URLs on it rather than the admin host; otherwise every
external delivery targets an address that isn't reachable from outside the
VPN and fails with no obvious cause.

## TLS termination is your call

Choose the termination point to match your platform:

- **AWS load balancer terminates TLS:** attach `module.n8n.certificate_arn`
  to its TLS listener. The output contains the module-issued certificate
  when `route53_zone_id` is set, or the caller-supplied ARN otherwise.
  Configure both Gateways to accept the plaintext HTTP forwarded by the
  load balancer, using ports that match your gateway Services. No Envoy TLS
  Secret is needed for this path.
- **Envoy terminates TLS:** use `tls.mode: SIMPLE` as shown above. Provision
  the certificate chain and matching unencrypted private key separately in
  Kubernetes TLS Secrets, in the gateway workload namespaces described
  above. This module does not create those Secrets or export private keys;
  an ACM ARN alone cannot configure Envoy TLS. Decrypt an encrypted key
  before loading it into the Secret, because this configuration supplies no
  decryption password to Envoy.

The module still requires exactly one of `route53_zone_id` or
`certificate_arn`, even when Envoy terminates TLS and does not use the ACM
certificate.

## What this module does not solve

- **WAF**: AWS WAFv2 web ACLs attach to Application Load Balancers (and
  CloudFront, API Gateway, and a few other L7 services), not to Network
  Load Balancers or a Kubernetes Service directly. Whether your Istio
  ingress gateway's fronting load balancer can carry one depends on
  whether that load balancer is an ALB, which depends on your own
  platform's setup and is outside this module's or this page's scope.
- **Chart/version pins, Service annotations, and gateway install**: entirely
  your platform team's existing conventions. Nothing here assumes a
  particular Istio chart, version, or cloud-provider LB annotation set.
