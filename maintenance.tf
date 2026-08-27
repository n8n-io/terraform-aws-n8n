# ── Webhook-tier scheduled rolling restart (opt-in) ───────────────────────────
# Mitigation for an upstream n8n defect, not a feature anyone should want.
#
# n8n's webhook-processor tier leaks heap on every job-finished broadcast: the
# leak rate on any given pod scales with FLEET-WIDE execution completion rate,
# not with that pod's own traffic (measured: pods receiving zero requests grew
# at the same rate as loaded ones). Unpatched 2.35.7 killed a 160-pod webhook
# fleet in 2h26m of sustained load, every pod dying at V8's default ~2,033 MB
# heap ceiling with half its 4 GiB container limit unused. The patched build
# (jobResults bounded) holds flat for 88.1 minutes and then resumes leaking at
# +0.73 MB/min per pod. Until the fix lands upstream, a scheduled rolling
# restart is the only way the tier survives sustained load indefinitely.
#
# A rolling restart is the graceful kind: `kubectl rollout restart` stamps the
# pod template, and the Deployment's own rolling-update strategy replaces pods
# behind readiness probes, so capacity stays up throughout. This is NOT a
# fleet bounce.
#
# Everything here is gated on n8n_webhook_restart_schedule being set; the
# default (null) creates none of it.

locals {
  webhook_restart_enabled = var.n8n_webhook_restart_schedule != null

  # kubectl's version-skew policy allows +/- one minor against the API server,
  # so the cluster's own minor is always a valid choice. registry.k8s.io
  # publishes a vX.Y.0 tag for every supported minor.
  webhook_restart_image = coalesce(
    var.n8n_webhook_restart_image,
    "registry.k8s.io/kubectl:v${var.kubernetes_version}.0"
  )
}

resource "kubernetes_service_account_v1" "webhook_restart" {
  count = local.webhook_restart_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-restart"
    namespace = local.namespace_name
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# `kubectl rollout restart` is a PATCH on the Deployment (it stamps
# kubectl.kubernetes.io/restartedAt into the pod template), so get + patch on
# the one named Deployment is the entire required surface.
resource "kubernetes_role_v1" "webhook_restart" {
  count = local.webhook_restart_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-restart"
    namespace = local.namespace_name
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = [local.n8n_webhook_service_name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "webhook_restart" {
  count = local.webhook_restart_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-restart"
    namespace = local.namespace_name
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.webhook_restart[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.webhook_restart[0].metadata[0].name
    namespace = local.namespace_name
  }
}

resource "kubernetes_cron_job_v1" "webhook_restart" {
  count = local.webhook_restart_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-restart"
    namespace = local.namespace_name
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  spec {
    schedule           = var.n8n_webhook_restart_schedule
    concurrency_policy = "Forbid"

    # Pins schedule interpretation to UTC regardless of where the
    # kube-controller-manager runs (CronJob spec.timeZone, stable since
    # Kubernetes 1.27; every EKS version this module supports carries it).
    # The provider attribute is `timezone`, not `time_zone`; an earlier
    # attempt used the latter name and misread the resulting "Unsupported
    # argument" as a provider limitation.
    timezone = "Etc/UTC"

    # A missed window (suspended cluster, controller downtime) should fire
    # once when possible again, not stack up: one restart is idempotent and a
    # stale one is still the mitigation working.
    starting_deadline_seconds     = 300
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}

      spec {
        backoff_limit           = 2
        active_deadline_seconds = 120

        template {
          metadata {}

          spec {
            service_account_name = kubernetes_service_account_v1.webhook_restart[0].metadata[0].name
            restart_policy       = "Never"

            container {
              name  = "kubectl"
              image = local.webhook_restart_image
              command = [
                "kubectl", "rollout", "restart",
                "deployment/${local.n8n_webhook_service_name}",
                "--namespace", local.namespace_name,
              ]

              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                run_as_user                = 65534
                capabilities {
                  drop = ["ALL"]
                }
              }
            }
          }
        }
      }
    }
  }
}
