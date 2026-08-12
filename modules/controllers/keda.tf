# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling — scales n8n workers based on Redis queue
# depth rather than CPU, so workers appear only when there is work to do.
#
# Ordering contract for direct callers: whatever deploys n8n must be ordered
# AFTER this module, in both directions. The root module already does this
# (helm_release.n8n depends_on module.controllers), so a caller going through
# module "n8n" gets it for free and can stop reading here. A caller invoking
# modules/controllers directly (examples/customer-managed-everything) owns
# that edge itself and must declare depends_on = [module.controllers] on its
# own n8n call. Both halves of the contract need it:
#
#   Install: the n8n chart renders its worker ScaledObject unconditionally,
#   with no regard for who installed KEDA. Applied before this release, it
#   fails outright with `no matches for kind "ScaledObject" in version
#   "keda.sh/v1alpha1"`, because the CRD this chart owns does not exist yet.
#   Nothing infers that edge: an n8n module told install_keda = false creates
#   no KEDA resources to depend on, so without an explicit depends_on the two
#   Helm releases are unordered and Terraform is free to apply them in either
#   order.
#
#   Destroy: the n8n release (and its ScaledObjects) must be deleted FIRST,
#   while the KEDA operator is still running, so KEDA can process the
#   deletions and remove its own "finalizer.keda.sh" finalizer. KEDA is then
#   uninstalled only after all ScaledObjects are gone, leaving no orphaned
#   finalizers. Terraform reverses depends_on edges on destroy, so the same
#   declaration covers this case.
#
# A caller who wires providers for this submodule from their n8n module's own
# outputs cannot declare that edge without creating a cycle. Configure the
# kubernetes/helm providers against the cluster resource (or data source)
# directly instead; examples/customer-managed-everything/providers.tf shows
# the shape.
#
# Install ordering: depends_on helm_release.lbc. The AWS Load Balancer
# Controller registers a cluster-wide MutatingWebhookConfiguration
# (mservice.elbv2.k8s.aws) that intercepts Service creations everywhere — not
# just for ALB-targeted services. If KEDA runs in parallel with the LBC chart,
# the LBC webhook may already be registered while LBC pods aren't yet Ready,
# causing KEDA's metrics/admission Services to fail with:
#   "failed calling webhook ... no endpoints available for service
#    aws-load-balancer-webhook-service".
# Serializing on lbc (which has wait = true) guarantees LBC pods are Ready
# before any KEDA Service hits the webhook.
#
# Toggling install_keda off on a LIVE stack (var.install_keda: true -> false,
# not a full terraform destroy) is not covered by either dependency above and
# can hang: this resource has no dependency relationship with helm_release.n8n
# in that direction, so n8n's ScaledObject (rendered unconditionally, see
# install_keda's variable description) is never removed first. Helm's own
# uninstall of this chart deletes the keda-operator pods before the
# scaledobjects.keda.sh CRD it also owns; CRD deletion blocks until every
# existing instance of that kind is gone, and with the operator already
# deleted, nothing is left running to clear the live ScaledObject's
# finalizer.keda.sh. Confirmed live: the apply hangs until
# "context deadline exceeded", recoverable only by deleting the n8n-rendered
# ScaledObject(s) by hand (or clearing their finalizers) before, or during,
# the hang. A genuine terraform destroy does not hit this: helm_release.n8n
# depends_on this release (see below), so it is destroyed, and its
# ScaledObject with it, before this release is touched.

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  repository       = var.keda_chart_repository
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true
  cleanup_on_fail  = true

  depends_on = [
    helm_release.lbc,
  ]
}
