# ── Customer-managed Ingress ──────────────────────────────────────────────────
# create_ingress = false on module.n8n means the module creates no Ingress of
# its own. This example owns one instead, routed at the ALB the
# directly-invoked module.controllers' Load Balancer Controller provisions
# (main.tf), exactly the pattern install_lbc's own validation error message
# points at: "set create_ingress = false and point your own Ingress resources
# at an LBC you install another way."
#
# Single ALB, not the two-ALB split examples/split-ingress demonstrates: this
# example is about customer-managed backing infrastructure and controllers,
# not about Ingress topology, so it reuses the same routing shape the module's
# own create_ingress = true path renders (ingress.tf's kubernetes_ingress_v1.n8n
# in the repo root), just as a caller-owned resource instead of a module-owned
# one.

resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n-ingress"
    namespace = module.n8n.namespace

    annotations = {
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/certificate-arn" = module.n8n.certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      # Matches the module's own alb_ssl_policy default (variables.tf), so this
      # customer-managed Ingress negotiates the same TLS policy the
      # module-managed one would have.
      "alb.ingress.kubernetes.io/ssl-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.n8n_domain
      http {
        # Webhook, form, waiting and MCP traffic must reach the dedicated
        # webhook processors, taken from the module output rather than
        # hardcoded so this example cannot drift as n8n adds endpoints.
        # Declared before the catch-all so the more specific prefixes win.
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

        # Editor UI and REST API.
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = module.n8n.n8n_service_name
              port { number = module.n8n.n8n_service_port }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true

  # See the module's own Ingress (repo root n8n.tf) for why delete is
  # generous: ELBv2 reports a target group as still in use for several
  # minutes after its ALB is deleted, and LBC holds the finalizer until it
  # can remove it.
  timeouts {
    create = "10m"
    delete = "20m"
  }

  # module.n8n: wait_for_load_balancer blocks until the LBC provisions the
  # ALB, and the ALB has no targets to register until the Helm release has
  # created the Services this Ingress routes to. module.controllers: the LBC
  # itself lives there, not in module.n8n (install_lbc = false on that
  # module), so this Ingress has nothing to provision an ALB with until that
  # Helm release exists.
  depends_on = [module.n8n, module.controllers]
}
