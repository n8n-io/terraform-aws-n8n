# Plan-time tests for the small example using mocked providers.
#
# Exercises the VPC + ACM + module wiring without contacting AWS.
#
# Run: terraform test
#   (from examples/small/, mocks require terraform >= 1.7)

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
# Only variable-validation tests run here today. Architecture asserts that
# would require a full `command = plan` over the example are doable via the
# same BYO-cert workaround used by examples/large/tests/defaults.tftest.hcl
# (plumb certificate_arn through, set it to a stub in tests, leave
# route53_zone_id null so the module's dns.tf for_each over
# domain_validation_options never instantiates), tracked as a separate
# follow-up. The module itself is already exercised by tests/defaults.tftest.hcl
# at the repo root, which mocks the lower-level resources directly.

run "cluster_name_length_validation_rejects_long_names" {
  command = plan

  variables {
    cluster_name = "this-cluster-name-is-definitely-too-long"
  }

  expect_failures = [var.cluster_name]
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
