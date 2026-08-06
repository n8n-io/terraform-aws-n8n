# Plan-time tests for the split-ingress example using mocked providers.
#
# Run: terraform test
#   (from examples/split-ingress/, mocks require terraform >= 1.7)
#
# Unlike examples/small and examples/large, this example can run full
# architecture asserts on the Route53 path. The certificate is issued by the
# module, whose aws_route53_record.cert_validation keys its for_each off
# local.acm_domain_names (var.n8n_domain plus n8n_additional_domains, both
# statically known here) and looks the unknown validation values up by key.
# Only the *values* of domain_validation_options are unknown at plan time, so
# the plan stays valid.

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  n8n_domain      = "n8n.test.example.com"
  n8n_license_key = "test-license-key-not-real"
  route53_zone_id = "Z00000000000000000000"
}

# ── Variable contract ─────────────────────────────────────────────────────────

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "webhook_subdomain_validation_rejects_non_dns_label" {
  command = plan

  variables {
    webhook_subdomain = "not_a_label"
  }

  expect_failures = [var.webhook_subdomain]
}

run "admin_cidr_validation_rejects_non_cidr" {
  command = plan

  variables {
    admin_allowed_cidr_blocks = ["10.20.0.0"]
  }

  expect_failures = [var.admin_allowed_cidr_blocks]
}

# Host bits pass cidrnetmask and pass LBC's own parser, so without this guard
# the first thing to reject the range is EC2, when it builds the security group
# rule, long after the apply reported success. Mirrors the module's
# alb_inbound_cidrs_rejects_host_bits.
run "admin_cidr_validation_rejects_host_bits" {
  command = plan

  variables {
    admin_allowed_cidr_blocks = ["10.20.0.5/16"]
  }

  expect_failures = [var.admin_allowed_cidr_blocks]
}

# The n8n image inputs are passthroughs, so what is worth pinning here is that
# this example adds no opinion of its own: each one keeps its inert default so
# the chart's own settings apply, and each one's validation reaches the caller
# rather than being swallowed. Same runs as examples/cloudflare and
# examples/godaddy; examples/small and examples/medium document why they cannot
# host them.

run "n8n_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "Example must not pin an image tag by default; the module's chart default (stable) should apply."
  }
}

run "n8n_image_tag_rejects_whitespace" {
  command = plan

  variables {
    n8n_image_tag = " 1.2.3 "
  }

  expect_failures = [var.n8n_image_tag]
}

run "n8n_image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "Example must not pin an image repository by default; the module's chart default (docker.n8n.io/n8nio/n8n) should apply."
  }
}

run "n8n_image_repository_rejects_inline_tag" {
  command = plan

  variables {
    n8n_image_repository = "myregistry.example.com/n8n:2.27.4"
  }

  expect_failures = [var.n8n_image_repository]
}

run "n8n_task_runner_image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_tag == null
    error_message = "Example must not pin a task runner image tag by default; the chart should keep inheriting the n8n application image's tag."
  }
}

run "n8n_task_runner_image_tag_rejects_whitespace" {
  command = plan

  variables {
    n8n_task_runner_image_tag = " 2.27.4 "
  }

  expect_failures = [var.n8n_task_runner_image_tag]
}

run "n8n_custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "Example must not set a custom extensions path by default; N8N_CUSTOM_EXTENSIONS should be omitted unless a custom image supplies nodes at that path."
  }
}

run "n8n_custom_extensions_path_rejects_a_relative_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "opt/n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_custom_extensions_path_rejects_the_chart_mounted_data_dir" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_custom_extensions_path_rejects_a_non_canonical_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/./.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_image_pull_secrets_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "Example must not attach image pull secrets by default; the Helm chart should keep creating the n8n ServiceAccount."
  }
}

run "n8n_image_pull_secrets_rejects_a_non_dns_name" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["Not_A_Secret_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

# ── The split itself ──────────────────────────────────────────────────────────
# The whole point of this example: two ALBs with opposite schemes, each serving
# a disjoint slice of traffic.

run "two_albs_with_opposite_schemes" {
  command = plan

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internet-facing"
    error_message = "The webhook ALB must be internet-facing so external systems can reach it"
  }

  assert {
    condition     = kubernetes_ingress_v1.admin_internal.metadata[0].annotations["alb.ingress.kubernetes.io/scheme"] == "internal"
    error_message = "The admin ALB must be internal. Exposing the editor UI is what this example exists to prevent"
  }
}

run "module_ingress_is_disabled" {
  command = plan

  assert {
    condition     = length(module.n8n.n8n_webhook_path_prefixes) == 5
    error_message = "The module should expose all five webhook prefixes for this example to route"
  }

  # With create_ingress = false the module owns no Ingress, so alb_hostname is
  # null and the two ALBs here are the only load balancers in play.
  assert {
    condition     = module.n8n.alb_hostname == null
    error_message = "module.n8n.alb_hostname must be null when create_ingress = false"
  }
}

# Every prefix n8n disables on the main pods must be on the public ALB. Missing
# one is silent until a Form Trigger or a Wait node fails in production.

run "public_alb_routes_every_webhook_prefix" {
  command = plan

  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      contains([for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path : p.path], prefix)
    ])
    error_message = "The public ALB must route all five webhook prefixes"
  }

  assert {
    condition = alltrue([
      for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name == "n8n-webhook-processor"
    ])
    error_message = "Every path on the public ALB must target the webhook processor Service"
  }

  # No catch-all: the editor UI must not be reachable from the internet even by
  # accident. This is the assertion that would catch someone "helpfully" adding
  # a "/" rule to the public Ingress later.
  assert {
    condition = !contains(
      [for p in kubernetes_ingress_v1.webhook_public.spec[0].rule[0].http[0].path : p.path],
      "/"
    )
    error_message = "The public ALB must NOT have a catch-all / rule, which would expose the editor UI"
  }
}

# The internal ALB carries the webhook prefixes too, not just the catch-all.
# Without them the catch-all hands /webhook to the main pods, which run with
# production webhooks disabled, so the request falls through to the editor's SPA
# handler and returns 200 with an HTML body. An internal caller reads that as
# success while nothing ran. Confirmed against a live deployment, which is why
# these asserts exist.

run "internal_alb_routes_webhooks_and_ui_to_the_right_services" {
  command = plan

  assert {
    condition = alltrue([
      for prefix in ["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp"] :
      length([
        for p in kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path :
        p if p.path == prefix && p.backend[0].service[0].name == "n8n-webhook-processor"
      ]) == 1
    ])
    error_message = "The internal ALB must route the webhook prefixes to the webhook processor, or in-VPC webhook deliveries silently return the editor SPA with HTTP 200"
  }

  assert {
    condition = one([
      for p in kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path :
      p.backend[0].service[0].name if p.path == "/"
    ]) == "n8n-main"
    error_message = "The internal ALB must send the catch-all to the main Service"
  }

  # Catch-all last, so the webhook prefixes take precedence.
  assert {
    condition     = kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path[length(kubernetes_ingress_v1.admin_internal.spec[0].rule[0].http[0].path) - 1].path == "/"
    error_message = "The catch-all must be declared after the webhook prefixes"
  }

  assert {
    condition     = strcontains(kubernetes_ingress_v1.admin_internal.metadata[0].annotations["alb.ingress.kubernetes.io/target-group-attributes"], "stickiness.enabled=true")
    error_message = "The admin ALB needs stickiness, or editor WebSocket connections break"
  }
}

# ── Hostnames ─────────────────────────────────────────────────────────────────
# Each ALB answers on its own name, because one DNS record cannot alias two load
# balancers. Getting the webhook host wrong means n8n hands out URLs pointing at
# the internal ALB, and every external delivery silently fails.

run "hostnames_are_split_and_certificate_covers_both" {
  command = plan

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.spec[0].rule[0].host == "hooks.n8n.test.example.com"
    error_message = "The public Ingress must answer on the webhook hostname"
  }

  assert {
    condition     = kubernetes_ingress_v1.admin_internal.spec[0].rule[0].host == "n8n.test.example.com"
    error_message = "The internal Ingress must answer on the admin hostname"
  }

  # The certificate itself belongs to the module now: this example passes
  # route53_zone_id and n8n_additional_domains and consumes the result. That the
  # certificate covers every name, and that every name gets a validation record,
  # is asserted in the module's own tests/additional-domains.tftest.hcl. What
  # matters here is the wiring: both ALBs must present that one certificate. If
  # they diverged, one hostname would serve a certificate that does not cover it.
  # Only key presence is assertable: the value is the module's validated
  # certificate ARN, which is unknown until apply. Both ALBs must terminate TLS,
  # and both read the same module output, so a missing key is the failure worth
  # catching here.
  assert {
    condition = alltrue([
      for i in [kubernetes_ingress_v1.webhook_public, kubernetes_ingress_v1.admin_internal] :
      contains(keys(i.metadata[0].annotations), "alb.ingress.kubernetes.io/certificate-arn")
    ])
    error_message = "Both ALBs must carry a certificate-arn annotation, sourced from the module's certificate_arn output"
  }

  # Each hostname resolves to its own ALB. Crossing these would send editor
  # traffic to the public ALB, which has no catch-all, or webhook traffic to the
  # internal one, which is unreachable from the internet.
  assert {
    condition     = aws_route53_record.webhook_public.name == "hooks.n8n.test.example.com"
    error_message = "The webhook hostname must alias the public ALB"
  }

  assert {
    condition     = aws_route53_record.admin_internal.name == "n8n.test.example.com"
    error_message = "The admin hostname must alias the internal ALB"
  }
}

run "webhook_subdomain_flows_through_to_every_consumer" {
  command = plan

  variables {
    webhook_subdomain = "callbacks"
  }

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.spec[0].rule[0].host == "callbacks.n8n.test.example.com"
    error_message = "webhook_subdomain must drive the public Ingress host"
  }

  # The SAN itself is the module's to carry; what this example must get right is
  # that the same derived hostname reaches the alias record as reaches the
  # Ingress and the webhook base URL.
  assert {
    condition     = aws_route53_record.webhook_public.name == "callbacks.n8n.test.example.com"
    error_message = "webhook_subdomain must drive the public alias record"
  }

  assert {
    condition     = output.webhook_base_url == "https://callbacks.n8n.test.example.com"
    error_message = "webhook_base_url must track webhook_subdomain, which is what n8n hands out as WEBHOOK_URL"
  }
}

# ── Optional hardening ────────────────────────────────────────────────────────

run "waf_is_omitted_by_default" {
  command = plan

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.webhook_public.metadata[0].annotations), "alb.ingress.kubernetes.io/wafv2-acl-arn")
    error_message = "No WAF annotation should be emitted when waf_acl_arn is null"
  }
}

run "waf_attaches_to_the_public_alb_only" {
  command = plan

  variables {
    waf_acl_arn = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
  }

  assert {
    condition     = kubernetes_ingress_v1.webhook_public.metadata[0].annotations["alb.ingress.kubernetes.io/wafv2-acl-arn"] == "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
    error_message = "waf_acl_arn must attach to the public webhook ALB"
  }

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.admin_internal.metadata[0].annotations), "alb.ingress.kubernetes.io/wafv2-acl-arn")
    error_message = "The WAF belongs on the untrusted ALB only. Attaching it to the internal one just adds cost"
  }
}

run "admin_inbound_cidrs_apply_to_the_internal_alb_only" {
  command = plan

  variables {
    admin_allowed_cidr_blocks = ["10.20.0.0/16", "192.168.100.0/24"]
  }

  assert {
    condition     = kubernetes_ingress_v1.admin_internal.metadata[0].annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "10.20.0.0/16,192.168.100.0/24"
    error_message = "admin_allowed_cidr_blocks must render as a comma-separated inbound-cidrs annotation"
  }

  assert {
    condition     = !contains(keys(kubernetes_ingress_v1.webhook_public.metadata[0].annotations), "alb.ingress.kubernetes.io/inbound-cidrs")
    error_message = "Webhook senders come from arbitrary addresses, so the public ALB must not be CIDR-restricted"
  }
}

run "execution_data_storage_mode_defaults_to_database" {
  command = plan

  assert {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "Example must default to database storage; s3 needs an n8n >= 2.27 image and the feat:executionDataS3 entitlement, so it cannot be the default."
  }
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}
