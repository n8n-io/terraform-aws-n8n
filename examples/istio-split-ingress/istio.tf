# ── Istio control plane ───────────────────────────────────────────────────────
# Installed by this example, not by the module: the module owns the AWS Load
# Balancer Controller (controllers.tf, module root) because create_ingress
# defaults to true and needs it. Istio is only ever needed by callers who
# opt into this example instead, so it lives here.
#
# istio-base installs Istio's CRDs (Gateway, VirtualService, and friends)
# before istiod or anything that depends on those CRDs runs. helm_release
# does not validate a chart's manifests against CRD schemas the way
# kubernetes_manifest does, so unlike that resource type this ordering only
# has to hold by apply time of the dependent release, which depends_on
# guarantees, not by plan time of every resource that will eventually use
# those CRDs.

resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_chart_version
  namespace        = "istio-system"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true
  cleanup_on_fail  = true

  depends_on = [module.n8n]
}

# istiod is the control plane: xDS server, certificate authority, and the
# validating/mutating webhooks Gateway and VirtualService objects go through.
# Both ingress gateways (gateways.tf) and the split-routes chart (routes.tf)
# depend on this being up.

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_chart_version
  namespace  = "istio-system"

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  depends_on = [helm_release.istio_base]
}
