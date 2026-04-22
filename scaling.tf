# ── HPA: n8n webhook processor pods (CPU-based) ───────────────────────────────
# The n8n Helm chart skips creating the webhook-processor HPA when keda.enabled
# is true. Since we always use KEDA for workers, this external HPA is always
# required to cover webhook processor scaling.

resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  metadata {
    name      = "n8n-webhook-processor"
    namespace = var.namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "n8n-webhook-processor"
    }

    min_replicas = var.n8n_webhook_hpa_min_replicas
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.n8n_webhook_hpa_cpu_threshold
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}
