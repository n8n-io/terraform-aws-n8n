# ── DNS ───────────────────────────────────────────────────────────────────────
# The certificate is issued by the module, not here, exactly as in
# examples/split-ingress: route53_zone_id plus n8n_additional_domains makes
# the module issue one certificate covering both hostnames, write a
# validation record for each, and validate it. gateways.tf attaches it
# through the module's certificate_arn output when istio_tls_mode = "nlb".
#
# The module writes no alias records for this example: create_ingress = false
# means it owns no load balancer to point them at. There are two NLBs here
# and each hostname resolves to a different one, so the alias records below
# are the example's to own.

# ── NLB provisioning delay ─────────────────────────────────────────────────
# kubernetes_ingress_v1 (examples/split-ingress) has wait_for_load_balancer,
# a deterministic signal that the ALB it created now exists. helm_release has
# no equivalent: wait = true on the gateway releases (gateways.tf) only waits
# for POD readiness, not for the cloud NLB to be provisioned and tagged. A
# fixed delay is an honest, documented tradeoff rather than a guess dressed up
# as precision: this repo already tolerates fixed async-provisioning waits
# for the same class of "AWS eventual consistency" problem (see the ALB
# Ingress's 20-minute delete timeout in the module root). If 90s proves too
# short or flaky against a live cluster, replace with a null_resource +
# local-exec poll loop against `kubectl get svc -o jsonpath=
# '{.status.loadBalancer}'` instead of lengthening this blindly.

resource "time_sleep" "wait_for_nlb_public" {
  create_duration = "90s"
  depends_on      = [helm_release.istio_ingress_public]
}

resource "time_sleep" "wait_for_nlb_internal" {
  create_duration = "90s"
  depends_on      = [helm_release.istio_ingress_internal]
}

# ── NLB lookups ───────────────────────────────────────────────────────────────
# Looked up by the tags the AWS Load Balancer Controller applies to a
# Service-provisioned NLB. These differ from the Ingress-stack tag
# examples/split-ingress's data.aws_lb blocks key off
# (ingress.k8s.aws/stack): a Service-type LoadBalancer is tagged
# service.k8s.aws/stack instead. Verify this tag key against the LBC version
# helm_release.lbc (module root controllers.tf) resolves to before a live
# apply; it is the Service-reconciler analogue of the Ingress tag, not
# independently re-derived here.

data "aws_lb" "webhook_public" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "service.k8s.aws/stack" = "istio-ingress-public/istio-ingressgateway-public"
  }

  depends_on = [time_sleep.wait_for_nlb_public]
}

data "aws_lb" "admin_internal" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "service.k8s.aws/stack" = "istio-ingress-internal/istio-ingressgateway-internal"
  }

  depends_on = [time_sleep.wait_for_nlb_internal]
}

# ── Alias records ─────────────────────────────────────────────────────────────

resource "aws_route53_record" "webhook_public" {
  zone_id = var.route53_zone_id
  name    = local.webhook_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.webhook_public.dns_name
    zone_id                = data.aws_lb.webhook_public.zone_id
    evaluate_target_health = false
  }
}

# Public record, private addresses. Anyone can resolve this name; only
# clients inside the VPC or on the VPN can open a connection to what it
# points at. If even the name should stay hidden, move this record to a
# private hosted zone attached to the VPC.
resource "aws_route53_record" "admin_internal" {
  zone_id = var.route53_zone_id
  name    = var.n8n_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.admin_internal.dns_name
    zone_id                = data.aws_lb.admin_internal.zone_id
    evaluate_target_health = false
  }
}
