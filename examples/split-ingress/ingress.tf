# ── Split Ingress ─────────────────────────────────────────────────────────────
# Two ALBs instead of the module's single internet-facing one:
#
#   public ALB   → n8n-webhook-processor   webhook/form/waiting/MCP traffic
#   internal ALB → n8n-main                editor UI and REST API, VPN-only
#
# The point is blast radius. Only the endpoints that must accept unauthenticated
# internet traffic are exposed, and the admin surface never leaves the VPC.

locals {
  # Annotations both ALBs share. Each Ingress adds its own scheme, target group
  # tuning and (for the public one) WAF.
  common_ingress_annotations = {
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/certificate-arn" = module.n8n.certificate_arn
    "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/ssl-policy"      = var.ssl_policy
  }
}

# ── Public ALB: webhooks, plus the agents callback prefix ─────────────────────
# Routes the prefixes n8n disables on the main pods, taken from the module
# output rather than hardcoded so this example cannot drift as n8n adds
# endpoints, plus /rest/projects, which goes to the mains instead. There is
# deliberately no catch-all rule: a request to any other path gets the ALB's
# default 404 and never reaches the editor UI.
#
# /rest/projects is on this hostname for a reason that is not obvious. See the
# note on the rule itself.

resource "kubernetes_ingress_v1" "webhook_public" {
  metadata {
    name      = "n8n-webhook-public"
    namespace = module.n8n.namespace

    annotations = merge(
      local.common_ingress_annotations,
      {
        "alb.ingress.kubernetes.io/scheme" = "internet-facing"

        # Webhook senders are machines, not browsers: no stickiness needed, and
        # a short deregistration delay keeps scale-in responsive.
        "alb.ingress.kubernetes.io/target-group-attributes" = "deregistration_delay.timeout_seconds=30"
        "alb.ingress.kubernetes.io/healthcheck-path"        = "/healthz"
      },
      # Attaching a WAF ACL is the main reason to isolate this ALB: rate
      # limiting and managed rule groups apply to untrusted traffic only.
      var.waf_acl_arn == null ? {} : {
        "alb.ingress.kubernetes.io/wafv2-acl-arn" = var.waf_acl_arn
      },
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = local.webhook_domain
      http {
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

        # Agents chat integrations, and the reason this hostname serves
        # anything that is not a webhook. n8n builds the Slack app-install URL
        # and the platform event callbacks by appending
        # /rest/projects/<id>/agents/... onto getWebhookBaseUrl(), which is
        # WEBHOOK_URL, which is this hostname. Those are main-pod routes: the
        # webhook processors register no /rest handlers at all. Without this
        # rule, connecting a Slack agent 404s at the end of the OAuth flow,
        # after the admin has already granted consent, and nothing in n8n logs
        # it.
        #
        # This is upstream n8n's construction, not a module or chart setting,
        # so N8N_EDITOR_BASE_URL does not move it: the path has to be routed
        # here for those OAuth flows to complete at all. It also has to be
        # reachable from the internet rather than only in-VPC, because the
        # platform event webhooks are server-to-server POSTs from Slack and
        # Telegram.
        #
        # Scoped to /rest/projects rather than all of /rest, because that is
        # the whole surface those constructions use. Note this still routes the
        # entire authenticated Projects API (project CRUD and project-scoped
        # resources under /rest/projects/<id>/...) to the mains from the
        # internet, not only the agents sub-routes: ALB prefix matching cannot
        # narrow to /rest/projects/<id>/agents/*, so that auth-gated surface is
        # accepted alongside the callbacks. /rest/login, /rest/credentials and
        # the rest of the authenticated REST API stay off this hostname, which
        # is what the missing catch-all above is for. A literal prefix, so it
        # needs no regex and no ALB-specific annotation. Delete this block if
        # you do not use Agents chat integrations, and the public surface goes
        # back to webhooks only; also remove the
        # public_alb_routes_agent_callbacks_to_the_main_service run and the
        # /rest/projects exclusion in tests/defaults.tftest.hcl, which pin this
        # block's presence.
        #
        # Hardcoded rather than read from a module output: unlike the webhook
        # prefixes, which the mains genuinely cannot serve, this is one path
        # family on one topology, and the module has no equivalent list to
        # expose. Kept here so the exposure decision stays visible in the
        # example that makes it.
        path {
          path      = "/rest/projects"
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

  # See the module's Ingress for why delete is 20m: ELBv2 reports a target group
  # as still in use for minutes after its ALB is deleted, and LBC holds the
  # finalizer until it can remove it. Two ALBs make the wait more likely, not
  # less.
  timeouts {
    create = "10m"
    delete = "20m"
  }

  # Waits for the whole module, not just the namespace. wait_for_load_balancer
  # blocks until the LBC provisions the ALB, and the ALB has no targets to
  # register until the Helm release has created the Services.
  depends_on = [module.n8n]
}

# ── Internal ALB: everything, for in-VPC clients ──────────────────────────────
# scheme = internal places the ALB in the private subnets, so it is reachable
# only from inside the VPC and whatever is peered or VPN-attached to it. The
# alias record in dns.tf is public, but resolves to private addresses, and a
# lookup from the internet succeeds and then connects to nothing.
#
# This ALB carries the webhook prefixes as well as the catch-all. The split is
# asymmetric on purpose: the public ALB is narrowed to webhooks only to minimise
# what is exposed, while the internal one serves the full surface because
# everything reaching it is already inside the trust boundary.
#
# Routing the prefixes here is not cosmetic. Without them the catch-all sends
# /webhook to the main pods, which run with production webhooks disabled, so the
# request falls through to the editor's SPA handler and returns 200 with an HTML
# body. An internal system delivering a webhook would read that as success while
# nothing executed. Verified against the live deployment before this was added.
# It also means in-VPC callers deliver webhooks over the private path instead of
# having to egress to the public ALB.

resource "kubernetes_ingress_v1" "admin_internal" {
  metadata {
    name      = "n8n-admin-internal"
    namespace = module.n8n.namespace

    annotations = merge(
      local.common_ingress_annotations,
      {
        "alb.ingress.kubernetes.io/scheme" = "internal"

        # Editor sessions are browsers holding WebSocket connections. Stickiness
        # pins each to one main pod; without it the ALB round-robins and the
        # connection drops. The idle timeout must outlast an idle editor tab.
        "alb.ingress.kubernetes.io/target-group-attributes"  = "stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=10800,deregistration_delay.timeout_seconds=30"
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=300"
        "alb.ingress.kubernetes.io/healthcheck-path"         = "/healthz"
      },
      # Defence in depth: even inside the VPC, restrict to known admin ranges.
      length(var.admin_allowed_cidr_blocks) == 0 ? {} : {
        "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.admin_allowed_cidr_blocks)
      },
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.n8n_domain
      http {
        # Same prefixes as the public ALB, same reason: the mains serve none of
        # them. Declared before the catch-all so the specific paths win.
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

  # See the module's Ingress for why delete is 20m: ELBv2 reports a target group
  # as still in use for minutes after its ALB is deleted, and LBC holds the
  # finalizer until it can remove it. Two ALBs make the wait more likely, not
  # less.
  timeouts {
    create = "10m"
    delete = "20m"
  }

  depends_on = [module.n8n]
}
