# Plan-time tests for the istio-split-ingress example using mocked providers.
#
# Run: terraform test
#   (from examples/istio-split-ingress/, mocks require terraform >= 1.7)
#
# IMPORTANT GAP, DOCUMENTED RATHER THAN PAPERED OVER: examples/split-ingress's
# own test file can assert directly on kubernetes_ingress_v1.*.spec attributes
# (no catch-all on the public Ingress, prefix-before-catch-all ordering on the
# internal one) because that routing logic lives in literal Terraform resource
# blocks. Here the equivalent routing logic (charts/split-routes/templates/
# {public,internal}.yaml) is rendered by Helm and consumed as a
# helm_release.values argument, which AGENTS.md's "Known mock provider
# limitations" section already documents as unknown at plan time under mocks
# (the same reason the module's own n8n helm_release.values can't be asserted
# on today). This file therefore only asserts what's provable at the
# variable-contract level. The chart's actual routing behavior (no catch-all
# on public, ordering on internal) has to be verified by rendering the chart
# directly: `helm template charts/split-routes` and inspect the output, or a
# future tests/scripts/verify-routes.sh (not implemented in this example's v1).

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # security.tf reads the cluster security group id directly (no module
  # output carries it), so the mock needs a non-empty vpc_config to index into.
  override_data {
    target = data.aws_eks_cluster.n8n
    values = {
      vpc_config = [
        {
          cluster_security_group_id = "sg-0123456789abcdef0"
          security_group_ids        = []
          subnet_ids                = []
          vpc_id                    = "vpc-0123456789abcdef0"
        }
      ]
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "time" {}

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

run "admin_cidr_validation_rejects_host_bits" {
  command = plan

  variables {
    admin_allowed_cidr_blocks = ["10.20.0.5/16"]
  }

  expect_failures = [var.admin_allowed_cidr_blocks]
}

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

run "n8n_custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "Example must not set a custom extensions path by default."
  }
}

run "n8n_custom_extensions_path_rejects_the_chart_mounted_data_dir" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/custom"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "n8n_image_pull_secrets_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "Example must not attach image pull secrets by default."
  }
}

run "n8n_image_pull_secrets_rejects_a_non_dns_name" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["Not_A_Secret_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
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

# ── Istio-specific contract ────────────────────────────────────────────────────

run "istio_tls_mode_defaults_to_nlb" {
  command = plan

  assert {
    condition     = var.istio_tls_mode == "nlb"
    error_message = "Example must default to NLB-terminated TLS, the closest mirror of examples/split-ingress's ALB behavior."
  }
}

run "istio_tls_mode_rejects_unknown_value" {
  command = plan

  variables {
    istio_tls_mode = "alb"
  }

  expect_failures = [var.istio_tls_mode]
}

# The one run that's stronger than split-ingress's equivalent input: this
# variable is supposed to always fail when set at all, since AWS WAFv2 cannot
# attach to a Network Load Balancer.
run "waf_acl_arn_always_rejected" {
  command = plan

  variables {
    waf_acl_arn = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/n8n/abc123"
  }

  expect_failures = [var.waf_acl_arn]
}

run "waf_acl_arn_defaults_to_null" {
  command = plan

  assert {
    condition     = var.waf_acl_arn == null
    error_message = "waf_acl_arn must default to null; it can never be set in this example."
  }
}

# Gateway TLS mode requires all four PEM variables together. Missing any one
# must fail fast rather than reach a live apply with a half-configured
# credential.
run "gateway_tls_mode_requires_all_four_pem_variables" {
  command = plan

  variables {
    istio_tls_mode = "gateway"
  }

  expect_failures = [var.istio_tls_mode]
}

run "gateway_tls_mode_accepts_all_four_pem_variables" {
  command = plan

  variables {
    istio_tls_mode                = "gateway"
    gateway_tls_public_cert_pem   = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----"
    gateway_tls_public_key_pem    = "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----"
    gateway_tls_internal_cert_pem = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----"
    gateway_tls_internal_key_pem  = "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----"
  }

  assert {
    condition     = var.istio_tls_mode == "gateway"
    error_message = "gateway mode must be accepted once all four PEM variables are supplied."
  }
}

run "nlb_ssl_negotiation_policy_has_a_modern_default" {
  command = plan

  assert {
    condition     = var.nlb_ssl_negotiation_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "Default NLB SSL negotiation policy should be TLS 1.3 with a 1.2 fallback, matching examples/split-ingress's ssl_policy default."
  }
}

# ── The split itself, at the level provable under mocks ───────────────────────
# module.n8n.alb_hostname must be null with create_ingress = false, since the
# module then owns no load balancer: the two NLBs here are the only load
# balancers in play. Full route-level assertions (no catch-all on public,
# ordering on internal) cannot run under the mock helm provider; see the file
# header.

run "module_ingress_is_disabled" {
  command = plan

  assert {
    condition     = length(module.n8n.n8n_webhook_path_prefixes) == 5
    error_message = "The module should expose all five webhook prefixes for the split-routes chart to route."
  }

  assert {
    condition     = module.n8n.alb_hostname == null
    error_message = "module.n8n.alb_hostname must be null when create_ingress = false."
  }
}

# ── Hostnames ─────────────────────────────────────────────────────────────────

run "webhook_subdomain_flows_through_to_the_base_url" {
  command = plan

  variables {
    webhook_subdomain = "callbacks"
  }

  assert {
    condition     = output.webhook_base_url == "https://callbacks.n8n.test.example.com"
    error_message = "webhook_base_url must track webhook_subdomain, which is what n8n hands out as WEBHOOK_URL."
  }
}
