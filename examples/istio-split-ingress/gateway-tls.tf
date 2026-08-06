# ── Gateway-terminated TLS secrets ────────────────────────────────────────────
# Only created when istio_tls_mode = "gateway". An ACM public certificate's
# private key cannot be exported, so this mode cannot reuse
# module.n8n.certificate_arn the way istio_tls_mode = "nlb" does; the caller
# supplies raw PEM material instead (variables.tf), analogous to examples/
# cloudflare and examples/godaddy's BYO-cert precedent but as a Kubernetes
# Secret rather than an ACM ARN.
#
# Istio's SIMPLE TLS mode reads the credential from a Secret in the SAME
# namespace as the gateway workload that references it (the "credentialName"
# field on a Gateway resource's server.tls block resolves relative to the
# gateway's own namespace, not the mesh-wide default), so these live in
# istio-ingress-public / istio-ingress-internal, not in module.n8n.namespace.

resource "kubernetes_secret" "gateway_tls_public" {
  count = var.istio_tls_mode == "gateway" ? 1 : 0

  metadata {
    name      = "n8n-gateway-tls-public"
    namespace = "istio-ingress-public"
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = var.gateway_tls_public_cert_pem
    "tls.key" = var.gateway_tls_public_key_pem
  }

  depends_on = [helm_release.istio_ingress_public]
}

resource "kubernetes_secret" "gateway_tls_internal" {
  count = var.istio_tls_mode == "gateway" ? 1 : 0

  metadata {
    name      = "n8n-gateway-tls-internal"
    namespace = "istio-ingress-internal"
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = var.gateway_tls_internal_cert_pem
    "tls.key" = var.gateway_tls_internal_key_pem
  }

  depends_on = [helm_release.istio_ingress_internal]
}
