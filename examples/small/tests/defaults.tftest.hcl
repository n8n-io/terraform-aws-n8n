# Plan-time tests for the small example using mocked providers.
#
# Exercises the VPC + ACM + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/small/ — mocks require terraform >= 1.7)

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

# NOTE on test coverage:
#
# Most runs here are variable-validation only, but a full `command = plan`
# over this example already succeeds without the BYO-cert workaround: dns.tf's
# aws_route53_record.cert_validation for_each is keyed off
# local.acm_domain_names (input-derived), not the certificate's own
# domain_validation_options, so the for_each itself is known at plan time even
# with route53_zone_id set (see dns.tf's own comment on that resource). That
# is enough to plan cleanly and assert on plain input variables, like the run
# below. Asserting on the values dns.tf computes from domain_validation_options
# (the validation record's name, type, and value) still needs the BYO-cert
# workaround used by examples/large/tests/defaults.tftest.hcl, because those
# individual attributes stay unknown at plan time regardless of the for_each
# keys, tracked as a separate follow-up. The module itself is already
# exercised by tests/defaults.tftest.hcl at the repo root, which mocks the
# lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
}

run "n8n_main_hpa_min_replicas_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_main_hpa_min_replicas == null
    error_message = "Example must not override the main-replica count by default; the module's own default of 2 should apply."
  }
}

# The custom-image inputs added alongside n8n_image_tag (n8n_image_repository,
# n8n_task_runner_image_tag, n8n_custom_extensions_path,
# n8n_image_pull_secrets) are intentionally untested here; their variable
# contracts (default, format validation) are covered by
# tests/defaults.tftest.hcl at the repo root, and the passthrough is verified
# manually with a real `terraform plan`.

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

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}
