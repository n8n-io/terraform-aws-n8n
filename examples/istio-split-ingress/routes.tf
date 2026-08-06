# ── Gateway / VirtualService CRD instances ────────────────────────────────────
# Installed via a small local Helm chart (charts/split-routes) rather than
# kubernetes_manifest: that resource type validates a manifest against its
# CRD's OpenAPI schema at PLAN time, and that schema does not exist until
# istio_base (istio.tf) has applied, which is the same CRD-ordering problem
# AGENTS.md documents for other reasons elsewhere in this repo. helm_release
# only needs the CRDs to exist by APPLY time of this release, which
# depends_on guarantees.
#
# This is a new pattern for this repo: every other helm_release here and in
# the module root pulls from a remote chart repo or OCI registry. A local
# chart is the tradeoff that avoids both the CRD-timing problem above and
# pulling in a second Terraform provider just to apply raw CRD-typed YAML.

resource "helm_release" "split_routes" {
  name      = "n8n-split-routes"
  chart     = "${path.module}/charts/split-routes"
  namespace = module.n8n.namespace

  wait            = true
  timeout         = 120
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    tlsMode = var.istio_tls_mode

    public = {
      host                 = local.webhook_domain
      gatewaySelector      = "ingressgateway-public"
      credentialSecretName = var.istio_tls_mode == "gateway" ? kubernetes_secret.gateway_tls_public[0].metadata[0].name : null
    }
    internal = {
      host                 = var.n8n_domain
      gatewaySelector      = "ingressgateway-internal"
      credentialSecretName = var.istio_tls_mode == "gateway" ? kubernetes_secret.gateway_tls_internal[0].metadata[0].name : null
    }

    # Sourced from the module so this chart cannot drift from what n8n
    # actually serves, the same reasoning examples/split-ingress/ingress.tf
    # uses for its dynamic path blocks.
    webhookPrefixes = module.n8n.n8n_webhook_path_prefixes
    webhookService = {
      name = module.n8n.n8n_webhook_service_name
      port = module.n8n.n8n_service_port
    }
    mainService = {
      name = module.n8n.n8n_service_name
      port = module.n8n.n8n_service_port
    }
  })]

  depends_on = [
    helm_release.istio_ingress_public,
    helm_release.istio_ingress_internal,
    kubernetes_secret.gateway_tls_public,
    kubernetes_secret.gateway_tls_internal,
    module.n8n,
  ]
}
