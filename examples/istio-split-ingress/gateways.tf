# ── Two Istio ingress gateways, one per trust zone ────────────────────────────
# The security boundary split-ingress gets from two ALBs comes here from two
# PHYSICALLY SEPARATE Envoy deployments, each with its own Service/NLB and its
# own Gateway resource (routes.tf) carrying only the routes appropriate to its
# trust zone. A single gateway serving two hostnames would not give the same
# guarantee: any client that could reach the pod on the right port could send
# any Host header it wanted. Two gateways means the public one's Envoy config
# has no route to the admin Service at all, not merely a Kubernetes-level
# firewall in front of one that does.
#
# NOTE (verify before a live apply): the exact annotation keys below, in
# particular the healthcheck-* trio and the ssl-* pair's interaction, must be
# checked against the AWS Load Balancer Controller version helm_release.lbc
# (module root controllers.tf) resolves to: these keys have shifted across
# LBC minor versions. See the README's "Open verification items" section.

locals {
  nlb_annotations_common = {
    "service.beta.kubernetes.io/aws-load-balancer-type"                 = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"      = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTP"
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "15021"
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/healthz/ready"
  }

  # TLS termination annotations only apply in "nlb" mode. In "gateway" mode
  # Envoy negotiates TLS itself (gateway-tls.tf), and the NLB is a plain TCP
  # passthrough on 443.
  nlb_tls_annotations = var.istio_tls_mode == "nlb" ? {
    "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"               = module.n8n.certificate_arn
    "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"              = "443"
    "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = var.nlb_ssl_negotiation_policy
  } : {}

  nlb_annotations_public = merge(local.nlb_annotations_common, local.nlb_tls_annotations, {
    "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
  })

  nlb_annotations_internal = merge(local.nlb_annotations_common, local.nlb_tls_annotations, {
    "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internal"
    "service.beta.kubernetes.io/aws-load-balancer-security-groups" = aws_security_group.internal_gateway.id
  })

  # Which containerPort Envoy's Service forwards port 443 traffic to. In "nlb"
  # mode the NLB already terminated TLS and hands Envoy plain HTTP, so 443
  # must land on Envoy's HTTP listener (8080), not its default HTTPS listener
  # (8443) which expects a TLS handshake it would never receive. In "gateway"
  # mode the NLB is a TCP passthrough, so 443 lands on 8443 where Envoy
  # terminates TLS itself (gateway-tls.tf). charts/split-routes/templates/
  # {public,internal}.yaml declare their Gateway server on the matching port
  # number; keep the three in sync if either ever changes.
  gateway_service_ports = var.istio_tls_mode == "nlb" ? [
    { name = "status-port", port = 15021, targetPort = 15021, protocol = "TCP" },
    { name = "http", port = 443, targetPort = 8080, protocol = "TCP" },
    ] : [
    { name = "status-port", port = 15021, targetPort = 15021, protocol = "TCP" },
    { name = "https", port = 443, targetPort = 8443, protocol = "TCP" },
  ]
}

# ── Public gateway: webhooks only ─────────────────────────────────────────────

resource "helm_release" "istio_ingress_public" {
  name             = "istio-ingressgateway-public"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_chart_version
  namespace        = "istio-ingress-public"
  create_namespace = true

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    labels = {
      # Selected by the Gateway resource's spec.selector in
      # charts/split-routes/templates/public.yaml.
      istio = "ingressgateway-public"
    }
    service = {
      type        = "LoadBalancer"
      annotations = local.nlb_annotations_public
      ports       = local.gateway_service_ports
    }
  })]

  depends_on = [helm_release.istiod]
}

# ── Internal gateway: webhooks + editor UI / REST API, VPN-only ──────────────

resource "helm_release" "istio_ingress_internal" {
  name             = "istio-ingressgateway-internal"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_chart_version
  namespace        = "istio-ingress-internal"
  create_namespace = true

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    labels = {
      istio = "ingressgateway-internal"
    }
    service = {
      type        = "LoadBalancer"
      annotations = local.nlb_annotations_internal
      ports       = local.gateway_service_ports
    }
  })]

  depends_on = [helm_release.istiod]
}
